package sdk

// 听书：专辑详情与播放地址的传输层。
//
// 参数来源：fqapp `rust/src/endpoints/audio.rs:59-120,225-313`。专辑详情用本
// 设备家族参数（与目录接口一致）；播放地址走 novelfm 域名与客户端固定参数。

import (
	"context"
	"encoding/json"
	"strings"

	"github.com/beilunyang/openhongguo/internal/drm"
	"github.com/beilunyang/openhongguo/internal/protocol"
	"github.com/beilunyang/openhongguo/internal/protocol/sign"
)

// DeriveAudioKey 从 encrypt_info.spade_a 还原 CENC 内容密钥（hex）。
// drm 包是 internal，外部模块拿不到，所以在这里开一个口子。
func DeriveAudioKey(spadeA string) (string, bool) {
	key, err := drm.Derive(spadeA)
	if err != nil || key.Hex == "" {
		return "", false
	}
	return key.Hex, true
}

const (
	// PathAudioDetail 是听书专辑详情。
	PathAudioDetail = "/reading/bookapi/audio/detail/"
	// AudioPlayHost 与 PathAudioPlay 是播放地址接口（novelfm，与 apiOrigin 不同）。
	AudioPlayHost = "https://api5-sinfonlineb.novelfm.com"
	PathAudioPlay = "/novelfm/playerapi/video_model/mget/v1"
)

// AudioDetailRaw 返回专辑详情的原始 JSON。
func (c *Client) AudioDetailRaw(ctx context.Context, bookID string) ([]byte, error) {
	if !validID(bookID) {
		return nil, ErrInvalidOptions
	}
	p, err := c.ensureSearchGuest(ctx)
	if err != nil {
		return nil, err
	}
	pairs := append(protocol.DeviceQueryPairs(c.identity(p)),
		[2]string{"version", "v3"},
		[2]string{"book_id", bookID},
	)
	ticket := c.clock().UnixMilli()
	signed, headers := sign.SignPOST(PathAudioDetail, pairs, ticket, p.DeviceID, protocol.VersionName, nil, nil)
	headers = anonymousHeaders(c, p, ticket, headers)
	raw, _, err := c.doRaw(ctx, "GET", c.apiOrigin+PathAudioDetail+"?"+signed, headers, nil)
	if err != nil {
		return nil, err
	}
	return raw, nil
}

// AudioPlayRaw 取音轨的播放地址（直链 mp4，可能带 CENC 加密信息）。
func (c *Client) AudioPlayRaw(ctx context.Context, bookID string, itemIDs []string, toneID string) ([]byte, error) {
	if !validID(bookID) || len(itemIDs) == 0 {
		return nil, ErrInvalidOptions
	}
	p, err := c.ensureSearchGuest(ctx)
	if err != nil {
		return nil, err
	}
	if toneID == "" {
		toneID = "0"
	}
	// novelfm 的查询参数集，但 aid/版本必须换成**本设备家族**的值：照抄
	// fqapp 的 aid=3040 会返回 403 invalid aid（实测）。
	pairs := [][2]string{
		{"os", "android"},
		{"aid", protocol.AID},
		{"ssmix", "a"},
		{"app_name", protocol.AppName},
		{"version_code", protocol.VersionCode},
		{"manifest_version_code", protocol.VersionCode},
		{"dpi", "440"},
		{"device_brand", "Redmi"},
		{"language", "zh"},
		{"os_api", "35"},
		{"comment_tag_c", "5"},
		{"vip_state", "0"},
		{"host_abi", "arm64-v8a"},
		{"category_style", "1"},
		{"need_personal_recommend", "1"},
		{"device_id", p.DeviceID},
		{"iid", p.InstallID},
	}
	body, err := json.Marshal(map[string]any{
		"audio_type":               0,
		"bgm_used":                 0,
		"book_id":                  bookID,
		"device_score":             0,
		"item_ids":                 itemIDs,
		"multi_shift":              false,
		"source":                   "default",
		"tone_id":                  toneID,
		"user_select_start_para":   0,
		"user_select_start_para_off": 0,
	})
	if err != nil {
		return nil, err
	}
	ticket := c.clock().UnixMilli()
	signed, headers := sign.SignPOST(PathAudioPlay, pairs, ticket, p.DeviceID, protocol.VersionName, body, nil)
	headers["Content-Type"] = "application/json"
	headers["User-Agent"] = "com.dragon.read"
	raw, _, err := c.doRaw(ctx, "POST", AudioPlayHost+PathAudioPlay+"?"+signed, headers, body)
	if err != nil {
		return nil, err
	}
	return raw, nil
}

// splitItemIDs 兼容 "a,b" 与 "a, b"。
func splitItemIDs(raw string) []string {
	var out []string
	for _, part := range strings.Split(raw, ",") {
		part = strings.TrimSpace(part)
		if part != "" {
			out = append(out, part)
		}
	}
	return out
}
