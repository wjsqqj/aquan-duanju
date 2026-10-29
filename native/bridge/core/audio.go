package core

// 听书（智能朗读）：音色表 + 音轨播放地址 + CENC 内容密钥。

import (
	"io"
	"net/http"
	"os"
	"path/filepath"
	"time"

	"context"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"

	"github.com/beilunyang/openhongguo/sdk"
)

type audioToneOut struct {
	ID    int    `json:"id"`
	Title string `json:"title"`
	Icon  string `json:"icon"`
}

type audioTonesOut struct {
	BookID       string         `json:"book_id"`
	RelateBookID string         `json:"relate_book_id"`
	GenreType    int            `json:"genre_type"`
	Tones        []audioToneOut `json:"tones"`
}

type audioTrackOut struct {
	URL        string `json:"url"`
	BackupURL  string `json:"backup_url"`
	KeyHex     string `json:"key"`
	DurationMs int64  `json:"duration_ms"`
	Encrypted  bool   `json:"encrypted"`
}

// audioTones 取音色表：智能朗读（tts_tones）与真人讲书（audio_tones）。
func audioTones(ctx context.Context, c *sdk.Client, a []json.RawMessage) (any, error) {
	var bookID string
	if err := arg(a, 0, &bookID); err != nil {
		return nil, err
	}
	raw, err := c.AudioTonesRaw(ctx, bookID)
	if err != nil {
		return nil, err
	}
	var env struct {
		Data struct {
			RelateBookID json.RawMessage `json:"relate_novel_bookid"`
			GenreType    int             `json:"req_book_genre_type"`
			TTSTones     []struct {
				ID    int    `json:"id"`
				Title string `json:"title"`
				Icon  string `json:"icon_url"`
			} `json:"tts_tones"`
			AudioTones []struct {
				ID    json.RawMessage `json:"id"`
				Title string          `json:"title"`
				Icon  string          `json:"icon_url"`
			} `json:"audio_tones"`
		} `json:"data"`
	}
	if err := json.Unmarshal(raw, &env); err != nil {
		return nil, fmt.Errorf("%w: audio tones: %v", sdk.ErrTransport, err)
	}
	d := env.Data
	out := audioTonesOut{
		BookID:       bookID,
		RelateBookID: rawString(d.RelateBookID),
		GenreType:    d.GenreType,
		Tones:        []audioToneOut{},
	}
	for _, t := range d.TTSTones {
		out.Tones = append(out.Tones, audioToneOut{ID: t.ID, Title: t.Title, Icon: t.Icon})
	}
	for _, t := range d.AudioTones {
		id := int(rawInt64(t.ID))
		if id == 0 {
			continue
		}
		out.Tones = append(out.Tones, audioToneOut{ID: id, Title: t.Title, Icon: t.Icon})
	}
	if len(out.Tones) == 0 {
		return nil, fmt.Errorf("%w: 该书没有可用音色", sdk.ErrContentUnavailable)
	}
	return out, nil
}

// audioStream 下载音轨到本地缓存并返回文件路径。
//
// mpv 的 HTTP 层未必带上阅读客户端的 UA/Referer，CDN 会直接 403（实测浏览器 UA
// 与只带 UA 都是 403，只有 UA=com.dragon.read + Referer=reading.snssdk.com 才是
// 200）。与其依赖播放器的请求头，不如由 core 用已验证的请求头把音轨取到本地，
// 播放器只负责解密与播放（CENC 密钥仍由 lavf 的 decryption_key 处理）。
func audioStream(ctx context.Context, c *sdk.Client, a []json.RawMessage) (any, error) {
	var bookID, itemID, toneID string
	if err := arg(a, 0, &bookID); err != nil {
		return nil, err
	}
	if err := arg(a, 1, &itemID); err != nil {
		return nil, err
	}
	if err := arg(a, 2, &toneID); err != nil {
		return nil, err
	}
	played, err := audioPlay(ctx, c, a)
	if err != nil {
		return nil, err
	}
	track, ok := played.(audioTrackOut)
	if !ok || track.URL == "" {
		return nil, fmt.Errorf("%w: 音轨地址为空", sdk.ErrContentUnavailable)
	}
	dir := audioCacheDir(c)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, fmt.Errorf("%w: audio cache: %v", sdk.ErrTransport, err)
	}
	path := filepath.Join(dir, fmt.Sprintf("%s-%s-%s.mp4", bookID, itemID, toneID))
	// 已缓存过就直接用，省掉重复下载。
	if st, err := os.Stat(path); err == nil && st.Size() > 0 {
		return map[string]any{
			"path":      path,
			"key":       track.KeyHex,
			"bytes":     int(st.Size()),
			"encrypted": track.Encrypted,
		}, nil
	}
	data, err := downloadAudioTrack(ctx, track.URL)
	if err != nil {
		return nil, err
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		return nil, fmt.Errorf("%w: write audio: %v", sdk.ErrTransport, err)
	}
	return map[string]any{
		"path":      path,
		"key":       track.KeyHex,
		"bytes":     len(data),
		"encrypted": track.Encrypted,
	}, nil
}

// audioCacheDir 是音轨缓存目录：与设备档案同级的 audio_cache。
func audioCacheDir(c *sdk.Client) string {
	profile := profilePathOf(c)
	if profile == "" {
		profile = os.TempDir()
	}
	return filepath.Join(filepath.Dir(profile), "audio_cache")
}

// downloadAudioTrack 用阅读客户端的请求头取音轨字节。
func downloadAudioTrack(ctx context.Context, url string) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, fmt.Errorf("%w: audio request: %v", sdk.ErrParamInvalid, err)
	}
	// 这两个头缺一不可，否则 CDN 返回 403。
	req.Header.Set("User-Agent", "com.dragon.read")
	req.Header.Set("Referer", "https://reading.snssdk.com/")
	resp, err := audioHTTP.Do(req)
	if err != nil {
		return nil, fmt.Errorf("%w: audio download: %v", sdk.ErrTransport, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%w: 音轨下载 HTTP %d", sdk.ErrContentUnavailable, resp.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, audioMaxBytes))
	if err != nil {
		return nil, fmt.Errorf("%w: audio read: %v", sdk.ErrTransport, err)
	}
	if len(data) == 0 {
		return nil, fmt.Errorf("%w: 音轨为空", sdk.ErrContentUnavailable)
	}
	return data, nil
}

// audioMaxBytes 限制单个音轨的体积（32MB，足够一章）。
const audioMaxBytes = 32 << 20

var audioHTTP = &http.Client{Timeout: 120 * time.Second}

// audioVideoModel 是 video_model（字符串 JSON）里我们需要的字段。
type audioVideoModel struct {
	MainURL     string
	BackupURL   string
	DurationSec float64
	Encrypt     bool
	SpadeA      string
	KID         string
	Method      string
	Codec       string
}

// audioPlay 取音轨播放地址与 CENC 内容密钥。
//
// 密钥来源必须选对：**顶层 `encryption_key` 是 37 字节的素材标识，不是 AES
// key**，喂给 ffmpeg 解不开（表现为能打开但没有声音、进度不动）。真正的密钥是
// `video_model.video_list[].encrypt_info.spade_a` 经 drm.Derive 派生的 16 字节。
func audioPlay(ctx context.Context, c *sdk.Client, a []json.RawMessage) (any, error) {
	var bookID, itemID, toneID string
	if err := arg(a, 0, &bookID); err != nil {
		return nil, err
	}
	if err := arg(a, 1, &itemID); err != nil {
		return nil, err
	}
	if err := arg(a, 2, &toneID); err != nil {
		return nil, err
	}
	raw, err := c.AudioPlayInfoRaw(ctx, bookID, itemID, toneID)
	if err != nil {
		return nil, err
	}
	var env struct {
		Data []struct {
			MainURL       string `json:"main_url"`
			BackupURL     string `json:"backup_url"`
			VideoModel    string `json:"video_model"`
			IsEncrypt     bool   `json:"is_encrypt"`
			EncryptionKey string `json:"encryption_key"`
		} `json:"data"`
	}
	if err := json.Unmarshal(raw, &env); err != nil {
		return nil, fmt.Errorf("%w: audio play: %v", sdk.ErrTransport, err)
	}
	for _, item := range env.Data {
		if item.MainURL == "" {
			continue
		}
		out := audioTrackOut{
			URL:       item.MainURL,
			BackupURL: item.BackupURL,
			Encrypted: item.IsEncrypt,
		}
		if vm, verr := parseVideoModel(item.VideoModel); verr == nil {
			if vm.DurationSec > 0 {
				out.DurationMs = int64(vm.DurationSec * 1000)
			}
			if vm.Encrypt && vm.SpadeA != "" {
				if key, ok := sdk.DeriveAudioKey(vm.SpadeA); ok {
					out.KeyHex = key
					out.Encrypted = true
				}
			}
			if out.URL == "" {
				out.URL = vm.MainURL
			}
			if out.BackupURL == "" {
				out.BackupURL = vm.BackupURL
			}
		}
		if out.KeyHex == "" && item.EncryptionKey != "" {
			// 兜底：只有正好 16 字节时才当作 AES key（37 字节那种是标识，不能用）。
			if key, err := base64.StdEncoding.DecodeString(item.EncryptionKey); err == nil && len(key) == 16 {
				out.KeyHex = hex.EncodeToString(key)
				out.Encrypted = true
			}
		}
		return out, nil
	}
	return nil, fmt.Errorf("%w: 该章节没有可用音频", sdk.ErrContentUnavailable)
}

// parseVideoModel 解析 video_model（字符串形式的 JSON）。
func parseVideoModel(raw string) (audioVideoModel, error) {
	var out audioVideoModel
	if strings.TrimSpace(raw) == "" {
		return out, fmt.Errorf("empty video_model")
	}
	var vm struct {
		VideoDuration json.RawMessage `json:"video_duration"`
		VideoList     []struct {
			MainURL   string `json:"main_url"`
			BackupURL string `json:"backup_url"`
			VideoMeta struct {
				CodecType string `json:"codec_type"`
			} `json:"video_meta"`
			EncryptInfo struct {
				Encrypt bool   `json:"encrypt"`
				KID     string `json:"kid"`
				SpadeA  string `json:"spade_a"`
				Method  string `json:"encryption_method"`
			} `json:"encrypt_info"`
		} `json:"video_list"`
	}
	if err := json.Unmarshal([]byte(raw), &vm); err != nil {
		return out, err
	}
	if len(vm.VideoList) == 0 {
		return out, fmt.Errorf("video_model has no video_list")
	}
	first := vm.VideoList[0]
	out.MainURL = first.MainURL
	out.BackupURL = first.BackupURL
	if s := strings.TrimSpace(string(vm.VideoDuration)); s != "" && s != "null" {
		if f, err := strconv.ParseFloat(s, 64); err == nil {
			out.DurationSec = f
		}
	}
	out.Encrypt = first.EncryptInfo.Encrypt
	out.SpadeA = first.EncryptInfo.SpadeA
	out.KID = first.EncryptInfo.KID
	out.Method = first.EncryptInfo.Method
	out.Codec = first.VideoMeta.CodecType
	return out, nil
}
