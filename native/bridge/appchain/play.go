package appchain

// 取流：双路径轮换（multi 五集群优先 → shortplay 三 host 降级）+ 五件套签名头
// + 响应解析（inline video_list / fallback_api 二次请求）。
// 配方证据：zfdang/hongguo-open-player app-source.js playbackRequest/shortplayRequest/
// buildPlaybackSteps（11-16 版），签名语义与 vendor playback.go golden vectors 同源。

import (
	"bytes"
	"context"
	"crypto/md5"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/beilunyang/openhongguo/sdk"
	"github.com/beilunyang/openhongguo/sdk/model"
)

// 集群与路径均为包变量，测试可覆盖。
var multiHosts = []string{
	"https://reading.snssdk.com",
	"https://api5-normal-sinfonlinea.fqnovel.com",
	"https://api5-normal-lq.fqnovel.com",
	"https://is.snssdk.com",
	"https://api5-normal-hl.fqnovel.com",
}
var shortHosts = []string{
	"https://api3-normal-sinfonlinea.fqnovel.com",
	"https://api5-normal-lq.fqnovel.com",
	"https://reading.snssdk.com",
}
const (
	multiPath  = "/novel/player/multi_video_model/player/v1"
	singlePath = "/novel/player/video_model/v1/"

	// videoUA71332 是 fallback_api 二次请求的 UA（免签名，zfdang 同款）。
	videoUA71332 = "com.phoenix.read/71332 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)"
	dragonUA     = "com.dragon.read"

	aidHongguo = "8662"
	aidDragon  = "1967"
)

type step struct {
	multi bool
	host  string
}

// steps 复刻 zfdang buildPlaybackSteps：multi 五集群全部先试，全空降级 shortplay。
func steps() []step {
	out := make([]step, 0, len(multiHosts)+len(shortHosts))
	for _, h := range multiHosts {
		out = append(out, step{multi: true, host: h})
	}
	for _, h := range shortHosts {
		out = append(out, step{multi: false, host: h})
	}
	return out
}

// resolveWithDevice 对固定设备跑全部步骤；每步网络失败/空响应/解析失败都换下一步。
func resolveWithDevice(ctx context.Context, client *http.Client, d *device, episodeID string) (*model.Playback, error) {
	for _, s := range steps() {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		raw, err := playRequest(ctx, client, d, s, episodeID)
		if err != nil || len(raw) == 0 {
			continue // 网络失败/空响应（生态故障的主症状）→ 下一步
		}
		pb, perr := parseResponse(ctx, client, raw, episodeID)
		if perr != nil || pb == nil || len(pb.Streams) == 0 {
			continue
		}
		return pb, nil
	}
	return nil, ErrUnavailable
}

// playRequest 构造并发送一次取流请求，返回原始响应字节。
func playRequest(ctx context.Context, client *http.Client, d *device, s step, episodeID string) ([]byte, error) {
	var query string
	var body []byte
	aid := aidHongguo
	if s.multi {
		query = multiQuery(d)
		body = gzipBytes(multiPayload(episodeID))
	} else {
		query = shortQuery(d)
		body = shortPayload(episodeID)
		aid = aidDragon
	}
	ts := uint32(time.Now().Unix())
	nonce := randUint32()
	sum := md5.Sum(body)

	hdrs := map[string]string{"Cookie": d.Cookie}
	if s.multi {
		hdrs["User-Agent"] = playUA74332
		hdrs["Accept"] = "application/json; charset=utf-8,application/x-protobuf"
		hdrs["Content-Type"] = "application/json; charset=UTF-8"
		hdrs["Content-Encoding"] = "gzip"
		hdrs["sdk-version"] = "2"
		hdrs["passport-sdk-version"] = "5051452"
		hdrs["x-xs-from-web"] = "0"
		hdrs["x-ss-dp"] = aidHongguo
	} else {
		// zfdang shortplayRequest：UA com.dragon.read + Content-Type + 签名，其余不带。
		hdrs["User-Agent"] = dragonUA
		hdrs["Content-Type"] = "application/json; charset=utf-8"
	}
	hdrs["x-ss-req-ticket"] = strconv.FormatInt(time.Now().UnixMilli(), 10)
	hdrs["x-khronos"] = strconv.FormatUint(uint64(ts), 10)
	hdrs["x-ladon"] = sdk.PlaybackLadon(ts, nonce, aid)
	hdrs["x-argus"] = sdk.PlaybackArgus(query, sum, ts, nonce, aid, d.DeviceID, d.InstallID)
	if len(body) > 0 {
		hdrs["x-ss-stub"] = upperMD5(body)
	}

	rctx, rcancel := context.WithTimeout(ctx, requestTimeout)
	defer rcancel()
	req, err := http.NewRequestWithContext(rctx, http.MethodPost, s.host+pathOf(s)+"?"+query, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	for k, v := range hdrs {
		req.Header.Set(k, v)
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 1<<22))
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("appchain: HTTP %d: %.120s", resp.StatusCode, raw)
	}
	return raw, nil
}

func pathOf(s step) string {
	if s.multi {
		return multiPath
	}
	return singlePath
}

// ===== query / payload（键序敏感，逐字复刻配方） =====

// pythonQuote 复刻 urllib.parse.quote 默认行为（zfdang 签名对 query 字节级敏感）。
func pythonQuote(s string) string {
	var out strings.Builder
	for i := 0; i < len(s); i++ {
		c := s[i]
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
			c == '_' || c == '.' || c == '-' || c == '~' {
			out.WriteByte(c)
		} else {
			fmt.Fprintf(&out, "%%%02X", c)
		}
	}
	return out.String()
}

func encodePairs(pairs [][2]string) string {
	parts := make([]string, 0, len(pairs))
	for _, p := range pairs {
		parts = append(parts, pythonQuote(p[0])+"="+pythonQuote(p[1]))
	}
	return strings.Join(parts, "&")
}

// multiQuery 复刻 zfdang PLAYBACK_DEVICE（71332 基准 + 74332 播放覆盖）+ 身份段 + _rticket。
func multiQuery(d *device) string {
	pairs := [][2]string{
		{"ac", "wifi"}, {"channel", "update_64"}, {"aid", aidHongguo}, {"app_name", "novelread"},
		{"version_code", "74332"}, {"version_name", "7.4.3.32"}, {"device_platform", "android"},
		{"os", "android"}, {"ssmix", "a"}, {"device_type", "25053RT47C"}, {"device_brand", "Redmi"},
		{"language", "zh"}, {"os_api", "36"}, {"os_version", "16"}, {"manifest_version_code", "74332"},
		{"resolution", "1280*2772"}, {"dpi", "520"}, {"update_version_code", "74332"},
		{"host_abi", "arm64-v8a"}, {"dragon_device_type", "phone"}, {"pv_player", "74332"},
		{"compliance_status", "0"}, {"need_personal_recommend", "1"}, {"player_so_load", "1"},
		{"is_android_pad_screen", "0"},
		{"device_id", d.DeviceID}, {"iid", d.InstallID}, {"cdid", d.CDID},
		{"_rticket", strconv.FormatInt(time.Now().UnixMilli(), 10)},
	}
	return encodePairs(pairs)
}

// multiPayload 复刻 zfdang 批量体（dr_scene=player + mixed_video_id_map 内容类型 1004）。
func multiPayload(episodeID string) []byte {
	return []byte(`{"dr_scene":"player","biz_param":{"detail_page_version":0,"device_level":3,` +
		`"disable_digg_stat":false,"need_all_video_definition":true,"need_mp4_align":false,` +
		`"use_os_player":false,"use_server_dns":false,"video_platform":1024},` +
		`"mixed_video_id_map":{"1004":["` + episodeID + `"]}}`)
}

// shortQuery 复刻 zfdang shortplayRequest（番茄短剧画像：aid 1967/novelapp/72132）。
func shortQuery(d *device) string {
	pairs := [][2]string{
		{"iid", d.InstallID}, {"device_id", d.DeviceID}, {"aid", aidDragon},
		{"app_name", "novelapp"}, {"version_code", "72132"}, {"version_name", "7.2.1.32"},
		{"device_platform", "android"}, {"device_brand", "Xiaomi"}, {"os_version", "13"},
		{"cdid", d.CDID},
	}
	return encodePairs(pairs)
}

// shortPayload 复刻 zfdang shortplayRequest 体（顶层 video_id + content_type 1004
// + video_platform 3 的 biz_param）。
func shortPayload(episodeID string) []byte {
	return []byte(`{"video_id":"` + episodeID + `","content_type":1004,` +
		`"biz_param":{"detail_page_version":0,"device_level":3,"disable_digg_stat":false,` +
		`"disable_video_relate_book":false,"from_video_id":"","need_all_video_definition":true,` +
		`"need_mp4_align":false,"source":4,"use_os_player":false,"use_server_dns":false,` +
		`"video_platform":3}}`)
}

// ===== 响应解析 =====

// parseResponse 解析取流响应：先走 SDK 全形态解析（data[vid].video_model /
// data.video_model / video_tab 三外层，string/object video_model，video_list 与
// dynamic_video DASH 都认）；解析不出流时按 zfdang 语义跟进 fallback_api 二次
// 请求（免签名，仅 UA），拿到 video_info.data 再包一层解析。
func parseResponse(ctx context.Context, client *http.Client, raw []byte, episodeID string) (*model.Playback, error) {
	pb, perr := sdk.ParsePlaybackJSON(raw, episodeID)
	if perr == nil && pb != nil && len(pb.Streams) > 0 {
		return pb, nil
	}
	modelRaw, fbURL, ok := extractEntry(raw, episodeID)
	if !ok || len(modelRaw) == 0 {
		return nil, perr
	}
	if fbURL == "" {
		return nil, perr
	}
	dataRaw, oerr := fetchFallback(ctx, client, fbURL)
	if oerr != nil {
		return nil, oerr
	}
	wrapped := []byte(`{"code":"0","data":{"video_model":` + string(dataRaw) + `}}`)
	return sdk.ParsePlaybackJSON(wrapped, episodeID)
}

// extractEntry 从响应里取该集条目的 video_model 原始 JSON 与 fallback_api。
// fallback_api 可能出现在条目层或模型层，形态可为 URL 字符串 / 数组 / 含
// fallback_api 字段的对象（zfdang parseFallback 语义）。
func extractEntry(raw []byte, episodeID string) (modelRaw []byte, fbURL string, ok bool) {
	var env struct {
		Data json.RawMessage `json:"data"`
	}
	if json.Unmarshal(raw, &env) != nil || len(env.Data) == 0 {
		return nil, "", false
	}
	var entries map[string]json.RawMessage
	if json.Unmarshal(env.Data, &entries) != nil {
		return nil, "", false
	}
	var entryRaw json.RawMessage
	if e, hit := entries[episodeID]; hit {
		entryRaw = e
	} else {
		for _, e := range entries {
			entryRaw = e
			break
		}
	}
	if len(entryRaw) == 0 {
		return nil, "", false
	}
	var entry struct {
		VideoModel  json.RawMessage `json:"video_model"`
		FallbackAPI json.RawMessage `json:"fallback_api"`
	}
	if json.Unmarshal(entryRaw, &entry) != nil {
		return nil, "", false
	}
	model := unwrapJSONString(entry.VideoModel)
	fb := normalizeFallback(entry.FallbackAPI)
	if fb == "" && len(model) > 0 {
		var mobj struct {
			FallbackAPI json.RawMessage `json:"fallback_api"`
		}
		if json.Unmarshal(model, &mobj) == nil {
			fb = normalizeFallback(mobj.FallbackAPI)
		}
	}
	return model, fb, true
}

// unwrapJSONString 把 "…JSON 文本…" 形态的值还原成对象字节（其余原样返回）。
func unwrapJSONString(raw json.RawMessage) []byte {
	b := bytes.TrimSpace(raw)
	if len(b) > 0 && b[0] == '"' {
		var s string
		if json.Unmarshal(b, &s) == nil {
			return []byte(s)
		}
	}
	return b
}

// normalizeFallback 按 zfdang parseFallback 语义提取 URL。
func normalizeFallback(raw json.RawMessage) string {
	b := bytes.TrimSpace(raw)
	if len(b) == 0 || string(b) == "null" {
		return ""
	}
	if b[0] == '"' {
		var s string
		if json.Unmarshal(b, &s) != nil {
			return ""
		}
		s = strings.TrimSpace(s)
		if strings.HasPrefix(s, "{") {
			return fallbackFromObj([]byte(s))
		}
		return s
	}
	if b[0] == '[' {
		var arr []string
		if json.Unmarshal(b, &arr) == nil && len(arr) > 0 {
			return strings.TrimSpace(arr[0])
		}
		return ""
	}
	return fallbackFromObj(b)
}

func fallbackFromObj(b []byte) string {
	var obj struct {
		FallbackAPI string `json:"fallback_api"`
	}
	if json.Unmarshal(b, &obj) == nil {
		return strings.TrimSpace(obj.FallbackAPI)
	}
	return ""
}

// fetchFallback 跟进 fallback_api 二次请求（免签名，仅 UA；zfdang 同款）。
// 响应外层 {code:0, video_info:{data:{…video_list…}}}，返回 video_info.data 原始字节。
func fetchFallback(ctx context.Context, client *http.Client, url string) ([]byte, error) {
	rctx, rcancel := context.WithTimeout(ctx, requestTimeout)
	defer rcancel()
	req, err := http.NewRequestWithContext(rctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", videoUA71332)
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 1<<23))
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("appchain: fallback HTTP %d", resp.StatusCode)
	}
	var outer struct {
		Code      int `json:"code"`
		CodeUpper int `json:"Code"`
		VideoInfo *struct {
			Code int             `json:"code"`
			Data json.RawMessage `json:"data"`
		} `json:"video_info"`
	}
	if json.Unmarshal(raw, &outer) != nil {
		return nil, errors.New("appchain: fallback decode")
	}
	if outer.Code != 0 || outer.CodeUpper != 0 || outer.VideoInfo == nil || outer.VideoInfo.Code != 0 || len(outer.VideoInfo.Data) == 0 {
		return nil, errors.New("appchain: fallback business rejected")
	}
	return outer.VideoInfo.Data, nil
}
