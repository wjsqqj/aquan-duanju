// Package webplay 实现红果官网 protected/play-info 取流通道。
//
// 背景：自 2026-10-15 起，fqnovel 域名下的 App 播放接口（video_model /
// multi_video_model）对第三方客户端整体封死：合法与非法签名都返回 200 空 body
// 或 110001，服务端在验签前就短路。现行可用通道是官网自己的 play-info，
// 不需要 App 签名，但要求站点 Origin/Referer，且 series_id 与 item_id 必须配套。
// 老剧（无加密资源）另返回 legacy_play_info 形态：纯明文 720p MP4
// （avc1+mp4a 音轨内嵌，无 CENC、无 access_key），本包同样解析并组装成
// 明文 Playback；play_info 与 legacy 同时存在时 play_info 优先。
//
// 本包只做「取播放信息 + 派生内容密钥 + 组装成 model.Playback」，
// 不负责 CENC 分片解密（播放器侧已有 mpv decryption_key 与 Go ffmpeg 中继）。
package webplay

import (
	"context"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/bits"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/beilunyang/openhongguo/sdk/model"
)

const (
	siteBase = "https://hongguoduanju.com"
	ua       = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 " +
		"(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
)

// endpoint 是包变量，测试可覆盖为 httptest 地址；生产恒为官网地址。
var endpoint = siteBase + "/api/video/protected/play-info"

// fallbackEndpoint 是官网自身的回退取流接口（2026-11-17 从站点前端 chunk 枚举
// 发现）：body 只要 {"item_id":...}，对可访问集返回**明文整集 MP4**（无 CENC、
// 无时长字段，实测 ep1 mvhd 146.838s 完整片）；与 play-info 同受游客墙管制，
// 墙外集返回 public_fallback_unavailable。作为 play-info 可救援失败时的第二源。
var fallbackEndpoint = siteBase + "/api/video/protected/fallback-play-info"

var (
	// ErrLoginRequired 表示官网游客墙：未登录只能看前 5 集，第 6 集起 play-info
	// 返回 403 protected_playback_unavailable。这不是本机故障、换设备/重试无效。
	ErrLoginRequired = errors.New("webplay: login required for this episode")
	// ErrEmptyPlayback 表示上游偶发返回空 body（限流/抖动），可短暂重试。
	ErrEmptyPlayback = errors.New("webplay: empty playback url")
	// ErrNoEncryptedLadder 表示上游 502 encrypted_resource_unavailable：
	// 老剧没有加密资源梯子，请求 480p 等加密档位时返回；降级 720p 可取到
	// legacy 明文流。
	ErrNoEncryptedLadder = errors.New("webplay: encrypted resource unavailable")
)

// flexString 兼容上游把同一字段时而编码成 JSON 数字、时而编码成字符串的做法
// （play-info 的 width/height/bitrate/size/expires_at 实测为字符串）。
type flexString string

func (f *flexString) UnmarshalJSON(b []byte) error {
	s := strings.TrimSpace(string(b))
	if s == "null" || s == `""` {
		*f = ""
		return nil
	}
	if len(s) > 0 && s[0] == '"' {
		var v string
		if err := json.Unmarshal(b, &v); err != nil {
			return err
		}
		*f = flexString(v)
		return nil
	}
	*f = flexString(s)
	return nil
}

func (f flexString) String() string { return string(f) }

// playInfoResponse 是 play-info 的响应；只声明我们会用到的字段，
// 未知字段由 json 解码忽略，避免上游加字段就解析失败。
type playInfoResponse struct {
	BaseResp struct {
		StatusCode    int    `json:"StatusCode"`
		StatusMessage string `json:"StatusMessage"`
	} `json:"base_resp"`
	PlayInfo *struct {
		Vid             string     `json:"vid"`
		Kid             string     `json:"kid"`
		MainURL         string     `json:"main_url"`
		BackupURL       string     `json:"backup_url"`
		CodecType       string     `json:"codec_type"`
		Format          string     `json:"format"`
		Duration        flexString `json:"duration"`
		Size            flexString `json:"size"`
		Bitrate         flexString `json:"bitrate"`
		Width           flexString `json:"width"`
		Height          flexString `json:"height"`
		Definition      string     `json:"definition"`
		PlayerAccessKey string     `json:"player_access_key"`
		ExpiresAt       flexString `json:"expires_at"`
		Audio           *struct {
			MainURL         string `json:"main_url"`
			BackupURL       string `json:"backup_url"`
			CodecType       string `json:"codec_type"`
			PlayerAccessKey string `json:"player_access_key"`
		} `json:"audio"`
	} `json:"play_info"`
	// legacy_play_info 是老剧（无加密资源）的明文形态：720p MP4，音轨内嵌，
	// 无 kid / player_access_key / expires_at，无需解密即可播。
	LegacyPlayInfo *struct {
		MainURL  string     `json:"main_url"`
		Width    flexString `json:"width"`
		Height   flexString `json:"height"`
		Duration flexString `json:"duration"`
	} `json:"legacy_play_info"`
}

// fallbackResponse 是 fallback-play-info 的响应：只有明文 main_url 与绝对
// 过期时间 url_expire（秒），无时长/宽高/密钥字段（时长由播放器读真实值）。
type fallbackResponse struct {
	MainURL   string     `json:"main_url"`
	URLExpire flexString `json:"url_expire"`
	BaseResp  struct {
		StatusCode    int    `json:"StatusCode"`
		StatusMessage string `json:"StatusMessage"`
	} `json:"base_resp"`
}

// resolveUncached 真正发起请求（无缓存），由 Resolve 包一层缓存。
// 主通道 play-info（含 480p→720p 降级与 legacy_play_info 明文回落）；失败时
// 按 2026-11-17 契约救援：403 游客墙直接短路（fallback 同样被墙，不值得再打），
// 其余可救援失败（空响应 / 502 降级后仍失败 / 其他非 403）改打官网自己的
// fallback-play-info 明文回退源，仍失败才返回**主通道的原错误**（保持既有
// 重试与文案契约不变）。
func resolveUncached(ctx context.Context, client *http.Client, seriesID, episodeID, definition string) (*model.Playback, model.ContentKey, error) {
	if seriesID == "" || episodeID == "" {
		return nil, model.ContentKey{}, fmt.Errorf("webplay: series_id and item_id are required")
	}
	if definition != "480p" && definition != "720p" {
		if definition == "" {
			definition = "720p"
		} else {
			return nil, model.ContentKey{}, fmt.Errorf("webplay: unsupported definition %q", definition)
		}
	}
	if client == nil {
		client = http.DefaultClient
	}

	pb, key, err := resolveViaPlayInfo(ctx, client, seriesID, episodeID, definition)
	if err == nil {
		return pb, key, nil
	}
	if errors.Is(err, ErrLoginRequired) {
		// 游客墙是按剧静态策略：fallback 对墙外集同样 public_fallback_unavailable，
		// 不再打第二枪。UI 直接提示登录。
		return nil, model.ContentKey{}, err
	}
	if fpb, ferr := resolveViaFallback(ctx, client, seriesID, episodeID); ferr == nil {
		return fpb, model.ContentKey{}, nil
	}
	// 回退源也失败：返回主通道错误（empty/502/其他），错误语义与重试契约不变。
	return nil, model.ContentKey{}, err
}

// resolveViaPlayInfo 是 play-info 主通道（原 resolveUncached 逻辑原样下沉）。
// definition 只接受 "480p"/"720p"（其余值上游返回 400），空值按 720p。
// 老剧（无加密资源）在 play_info 缺失/空 URL 时回落 legacy_play_info 明文
// MP4；请求 480p 等加密档位遇 502 encrypted_resource_unavailable 时自动
// 降级 720p 重取一次。
func resolveViaPlayInfo(ctx context.Context, client *http.Client, seriesID, episodeID, definition string) (*model.Playback, model.ContentKey, error) {
	if seriesID == "" || episodeID == "" {
		return nil, model.ContentKey{}, fmt.Errorf("webplay: series_id and item_id are required")
	}
	if definition != "480p" && definition != "720p" {
		if definition == "" {
			definition = "720p"
		} else {
			return nil, model.ContentKey{}, fmt.Errorf("webplay: unsupported definition %q", definition)
		}
	}
	if client == nil {
		client = http.DefaultClient
	}

	parsed, err := requestPlayInfo(ctx, client, seriesID, episodeID, definition)
	if errors.Is(err, ErrNoEncryptedLadder) && definition != "720p" {
		// 老剧没有加密梯子：降级 720p 重取一次。条件 definition != "720p"
		// 天然防住二次降级（720p 已是最低可用档）。
		parsed, err = requestPlayInfo(ctx, client, seriesID, episodeID, "720p")
	}
	if err != nil {
		return nil, model.ContentKey{}, err
	}

	info := parsed.PlayInfo
	if info == nil || strings.TrimSpace(info.MainURL) == "" {
		// 老剧没有加密资源：回落 legacy_play_info 明文 MP4。Protected/Dash/
		// Encryption 零值即明文语义；AudioURL 留空——音轨内嵌在 MP4 里，
		// Flutter 侧 audioUrl 为空会清空 audio-files 播内嵌音轨。
		if leg := parsed.LegacyPlayInfo; leg != nil && strings.TrimSpace(leg.MainURL) != "" {
			return &model.Playback{
				EpisodeID:       episodeID,
				DurationSeconds: int(parseFloat(leg.Duration.String())),
				Streams: []model.Stream{{
					Definition: "720p",
					Codec:      "h264",
					Width:      int(parseInt64(leg.Width.String())),
					Height:     int(parseInt64(leg.Height.String())),
					URL:        leg.MainURL,
				}},
			}, model.ContentKey{}, nil
		}
		// 两者都没有（play_info 空、legacy 也空）：保持 "url missing" 文案
		// 与既有 400ms 重试语义。
		return nil, model.ContentKey{}, fmt.Errorf("%w: url missing", ErrEmptyPlayback)
	}

	duration := parseFloat(info.Duration.String())
	expires := parseInt64(info.ExpiresAt.String())
	audioURL := ""
	if info.Audio != nil {
		audioURL = info.Audio.MainURL
	}
	pb := &model.Playback{
		EpisodeID:       episodeID,
		VideoID:         info.Vid,
		DurationSeconds: duration,
		ExpiresAt:       expires,
		Protected:       true,
		AudioURL:        audioURL,
		Streams: []model.Stream{{
			Definition: info.Definition,
			Codec:      info.CodecType,
			Width:      int(parseInt64(info.Width.String())),
			Height:     int(parseInt64(info.Height.String())),
			Bitrate:    parseInt64(info.Bitrate.String()),
			Size:       parseInt64(info.Size.String()),
			URL:        info.MainURL,
			BackupURL:  info.BackupURL,
			Dash:       strings.EqualFold(info.Format, "dash"),
			Protected:  true,
			Encryption: "cenc-aes-ctr",
		}},
	}

	key, err := DeriveAccessKey(info.PlayerAccessKey)
	if err != nil {
		// 密钥派生失败仍返回模型，让调用方决定如何提示（与 SDK ContentKey 的语义一致）。
		return pb, model.ContentKey{}, fmt.Errorf("webplay: derive key: %w", err)
	}
	return pb, model.ContentKey{Hex: key, Version: "web-access-v1"}, nil
}

// requestPlayInfo 发起一次 play-info HTTP 请求并解码原始响应；只做传输与
// 错误映射（游客墙 403 / 加密梯子缺失 502 / 其他非 200），不做降级与组装
// 决策，便于 resolveUncached 按 definition 降级重试。
func requestPlayInfo(ctx context.Context, client *http.Client, seriesID, episodeID, definition string) (*playInfoResponse, error) {
	payload := fmt.Sprintf(`{"series_id":%s,"item_id":%s,"definition":%s}`,
		jsonQuote(seriesID), jsonQuote(episodeID), jsonQuote(definition))
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, endpoint, strings.NewReader(payload))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Origin", siteBase)
	req.Header.Set("Referer", siteBase+"/player/"+seriesID+"/"+episodeID)
	req.Header.Set("User-Agent", ua)
	req.Header.Set("Content-Type", "application/json")

	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("webplay: request: %w", err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, fmt.Errorf("webplay: read body: %w", err)
	}
	if resp.StatusCode == http.StatusForbidden {
		// 官网游客墙：未登录只能看前 5 集，第 6 集起返回
		// 403 protected_playback_unavailable。换设备/重试都无效，需明确告知用户。
		return nil, fmt.Errorf("%w: HTTP 403 %s", ErrLoginRequired, snippet(body))
	}
	if resp.StatusCode == http.StatusBadGateway {
		// 老剧没有加密资源梯子：请求 480p 等加密档位时上游回 502
		// encrypted_resource_unavailable；调用方应降级 720p 重取 legacy 明文流。
		return nil, fmt.Errorf("%w: HTTP 502 %s", ErrNoEncryptedLadder, snippet(body))
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("webplay: HTTP %d: %s", resp.StatusCode, snippet(body))
	}

	var parsed playInfoResponse
	if err := json.Unmarshal(body, &parsed); err != nil {
		return nil, fmt.Errorf("webplay: decode: %w", err)
	}
	if parsed.BaseResp.StatusCode != 0 {
		return nil, fmt.Errorf("webplay: code=%d %s",
			parsed.BaseResp.StatusCode, parsed.BaseResp.StatusMessage)
	}
	return &parsed, nil
}

// resolveViaFallback 走官网 fallback-play-info 明文回退源（body 只要 item_id）。
// 成功返回明文 Playback（Protected=false、无 ContentKey、无音轨外挂、时长未知
// 置 0 由播放器读真实值）；403 映射 ErrLoginRequired 供上层区分墙/其他失败。
// seriesID 仅用于构造 Referer，不参与请求体。
func resolveViaFallback(ctx context.Context, client *http.Client, seriesID, episodeID string) (*model.Playback, error) {
	payload := `{"item_id":` + jsonQuote(episodeID) + `}`
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, fallbackEndpoint, strings.NewReader(payload))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Origin", siteBase)
	req.Header.Set("Referer", siteBase+"/player/"+seriesID+"/"+episodeID)
	req.Header.Set("User-Agent", ua)
	req.Header.Set("Content-Type", "application/json")

	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("webplay: fallback request: %w", err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, fmt.Errorf("webplay: fallback read body: %w", err)
	}
	if resp.StatusCode == http.StatusForbidden {
		return nil, fmt.Errorf("%w: fallback HTTP 403 %s", ErrLoginRequired, snippet(body))
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("webplay: fallback HTTP %d: %s", resp.StatusCode, snippet(body))
	}
	var parsed fallbackResponse
	if err := json.Unmarshal(body, &parsed); err != nil {
		return nil, fmt.Errorf("webplay: fallback decode: %w", err)
	}
	if parsed.BaseResp.StatusCode != 0 {
		return nil, fmt.Errorf("webplay: fallback code=%d %s",
			parsed.BaseResp.StatusCode, parsed.BaseResp.StatusMessage)
	}
	if strings.TrimSpace(parsed.MainURL) == "" {
		return nil, fmt.Errorf("webplay: fallback url missing")
	}
	return &model.Playback{
		EpisodeID: episodeID,
		ExpiresAt: parseInt64(parsed.URLExpire.String()),
		Protected: false,
		Streams: []model.Stream{{
			Definition: "720p",
			Codec:      "h264",
			URL:        parsed.MainURL,
		}},
	}, nil
}

// 进程内缓存：红果 play-info 按 IP 限流，短时间重复取同一集会返回空 body。
// 缓存成功结果可让"再次打开/历史记录/自动重试"秒开且不再打上游；
// 失败（空响应/限流）短缓存，避免在限流期反复打接口雪上加霜。
const (
	successCacheTTL = 30 * time.Minute       // 远小于 URL 的 ~1h 有效期，留足余量
	failureCacheTTL = 300 * time.Millisecond // 极短冷却：短于 core 的 400ms 重试，让重试能真正再取一次
)

type cacheEntry struct {
	pb      *model.Playback
	key     model.ContentKey
	expires time.Time
	failed  bool
	err     error
}

var (
	cacheMu    sync.Mutex
	cacheItems = make(map[string]cacheEntry)
)

func cacheKeyOf(seriesID, episodeID, definition string) string {
	return seriesID + "|" + episodeID + "|" + definition
}

func clonePlayback(pb *model.Playback) *model.Playback {
	if pb == nil {
		return nil
	}
	cp := *pb
	cp.Streams = append([]model.Stream(nil), pb.Streams...)
	return &cp
}

// Resolve 通过官网 play-info 通道解析一集的播放模型，带进程内缓存。
// 命中成功缓存直接返回；命中失败冷却期内返回上次的错误；否则实际请求并写入缓存。
func Resolve(ctx context.Context, client *http.Client, seriesID, episodeID, definition string) (*model.Playback, model.ContentKey, error) {
	if definition == "" {
		definition = "720p"
	}
	ck := cacheKeyOf(seriesID, episodeID, definition)
	now := time.Now()

	cacheMu.Lock()
	if hit, ok := cacheItems[ck]; ok && now.Before(hit.expires) {
		cacheMu.Unlock()
		if hit.failed {
			return nil, model.ContentKey{}, hit.err
		}
		return clonePlayback(hit.pb), hit.key, nil
	}
	cacheMu.Unlock()

	pb, key, err := resolveUncached(ctx, client, seriesID, episodeID, definition)

	// 403 游客墙不入缓存（它是稳定的，但由 UI 直接提示，缓存与否都不再请求）。
	// 空响应/其他失败短缓存；成功按 URL 有效期缓存。
	ttl := time.Duration(0)
	if err == nil && pb != nil {
		ttl = successCacheTTL
		// 若服务端给了 expires_at，取更早的失效点（留 60s 余量）。
		if pb.ExpiresAt > 0 {
			left := time.Until(time.Unix(pb.ExpiresAt, 0)) - 60*time.Second
			if left > 0 && left < ttl {
				ttl = left
			}
		}
	} else if err != nil && !errors.Is(err, ErrLoginRequired) {
		ttl = failureCacheTTL
	}
	if ttl > 0 {
		cacheMu.Lock()
		cacheItems[ck] = cacheEntry{
			pb: clonePlayback(pb), key: key, expires: time.Now().Add(ttl),
			failed: err != nil, err: err,
		}
		cacheMu.Unlock()
	}

	return pb, key, err
}

// DeriveAccessKey 把 play-info 的 player_access_key（base64）派生为
// 16 字节 CENC 内容密钥的 hex。算法取自站点内嵌 wasm，已与上游对拍：
//
//	z+Yb/ASySvhVqE63UKsd5laqGLMErU6NWa9BjwySFIsCkBi6ug== -> d06dea7f2663eedbe045b80908f51201
//	zeYZxQfeTZMDsRqrBLRN/gWxTvoD4E/8V7NNk1bfG8gF0h///w== -> b951adf80166abaebbe1d41f284df080
//
// 与旧 spade_a 派生的差异：seed b=250（旧 246），末步 `old^prev + popcount + 21`
// （旧 `-21 - popcount`）。
func DeriveAccessKey(value string) (string, error) {
	raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(value))
	if err != nil || len(raw) < 3 {
		return "", fmt.Errorf("webplay: invalid access key")
	}
	span := int64(len(raw)) - int64(raw[0]^raw[1]^raw[2]) + 47
	length := span
	if max := int64(len(raw)) - 1; length > max {
		length = max
	}
	if length < 34 {
		return "", fmt.Errorf("webplay: access key too short")
	}
	work := append([]byte(nil), raw[1:1+length]...)
	var a, b uint32 = 85, 250
	for i := range work {
		old := work[i]
		previous := b
		if i%2 != 0 {
			previous = a
		}
		if i%2 != 0 {
			a = uint32(old)
		} else {
			b = uint32(old)
		}
		work[i] = byte((uint32(old) ^ previous) + uint32(bits.OnesCount(uint(i))) + 21)
	}
	if len(work) < 33 {
		return "", fmt.Errorf("webplay: access key material short")
	}
	hexText := string(work[1:33])
	key, err := hex.DecodeString(hexText)
	if err != nil || len(key) != 16 {
		return "", fmt.Errorf("webplay: access key material is not hex")
	}
	return hex.EncodeToString(key), nil
}

// jsonQuote 用标准库做字符串 JSON 转义，避免手拼 body 时注入。
func jsonQuote(s string) string {
	b, _ := json.Marshal(s)
	return string(b)
}

func parseFloat(s string) int {
	v, _ := strconv.ParseFloat(strings.TrimSpace(s), 64)
	return int(v)
}

func parseInt64(s string) int64 {
	v, _ := strconv.ParseInt(strings.TrimSpace(s), 10, 64)
	return v
}

func snippet(b []byte) string {
	s := string(b)
	if len(s) > 200 {
		return s[:200]
	}
	return s
}
