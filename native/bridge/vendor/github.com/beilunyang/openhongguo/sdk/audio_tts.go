package sdk

// 听书（智能朗读）传输层。
//
// 端点都在 fqnovel 家族（不是被应用家族校验挡住的 novelfm），用本设备家族参数
// 即可。实测：tone_id 必须是音色表里真实存在的 id，传 0 会报 101019 NO_THIS_TONE。

import (
	"context"

	"github.com/beilunyang/openhongguo/internal/drm"
	"github.com/beilunyang/openhongguo/internal/protocol"
	"github.com/beilunyang/openhongguo/internal/protocol/sign"
)

// AudioHost 是听书端点所在域名。
const AudioHost = "https://api5-normal-sinfonlineb.fqnovel.com"

// PathAudioTones 是音色表；PathAudioPlayInfo 是音轨播放信息。
const (
	PathAudioTones    = "/reading/bookapi/audio/toneinfo/"
	PathAudioPlayInfo = "/reading/reader/audio/playinfo/"
)

// DeriveAudioKey 从 encrypt_info.spade_a 还原 CENC 内容密钥（hex）。
// drm 包是 internal，外部模块导入不了，所以在这里开一个口子。
func DeriveAudioKey(spadeA string) (string, bool) {
	key, err := drm.Derive(spadeA)
	if err != nil || key.Hex == "" {
		return "", false
	}
	return key.Hex, true
}

func (c *Client) audioGet(ctx context.Context, path string, extra [][2]string) ([]byte, error) {
	p, err := c.ensureSearchGuest(ctx)
	if err != nil {
		return nil, err
	}
	pairs := append(protocol.DeviceQueryPairs(c.identity(p)), extra...)
	ticket := c.clock().UnixMilli()
	signed, headers := sign.SignPOST(path, pairs, ticket, p.DeviceID, protocol.VersionName, nil, nil)
	headers = anonymousHeaders(c, p, ticket, headers)
	raw, _, err := c.doRaw(ctx, "GET", AudioHost+path+"?"+signed, headers, nil)
	if err != nil {
		return nil, err
	}
	return raw, nil
}

// AudioTonesRaw 取音色表。
func (c *Client) AudioTonesRaw(ctx context.Context, bookID string) ([]byte, error) {
	if !validID(bookID) {
		return nil, ErrInvalidOptions
	}
	return c.audioGet(ctx, PathAudioTones, [][2]string{
		{"book_id", bookID},
		{"is_exempt", "false"},
		{"is_local_book", "false"},
	})
}

// AudioPlayInfoRaw 取音轨播放信息。
func (c *Client) AudioPlayInfoRaw(ctx context.Context, bookID, itemID, toneID string) ([]byte, error) {
	if !validID(bookID) || !validID(itemID) {
		return nil, ErrInvalidOptions
	}
	if toneID == "" {
		toneID = "0"
	}
	return c.audioGet(ctx, PathAudioPlayInfo, [][2]string{
		{"book_id", bookID},
		{"item_ids", itemID},
		{"tone_id", toneID},
		{"req_type", "0"},
		{"is_local_book", "false"},
	})
}
