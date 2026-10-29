package sdk

// 阅读内容密钥与正文的传输层：这两条链路在读域（reading.snssdk.com），用的是
// 「阅读客户端」的参数集（aid=1967 / app_name=novelapp / version 6.1.5.32），
// 与发现、搜索的 apiOrigin 参数不同。加密与解密都由 core 侧完成，本文件只负责
// 组参数、签名、发送、取字段。
//
// 事实来源：fqapp `rust/src/device/register.rs:431-504`、
// `rust/src/endpoints/content.rs:12-45`。

import (
	"bytes"
	"compress/gzip"
	"context"
	"encoding/json"
	"fmt"

	"github.com/beilunyang/openhongguo/internal/protocol"
	"github.com/beilunyang/openhongguo/internal/protocol/sign"
)

const (
	// PathRegisterSecretKey 注册匿名设备的阅读内容密钥。
	PathRegisterSecretKey = "/reading/crypt/registerkey"
	// PathChapterText 取单章纯文本正文（密文，交 core 解密）。
	PathChapterText = "/reading/reader/full/v/"
)

// DeviceID 返回当前匿名设备的 device_id；注册内容密钥的材料要用它。
func (c *Client) DeviceID(ctx context.Context) (string, error) {
	p, err := c.ensureGuest(ctx)
	if err != nil {
		return "", err
	}
	return p.DeviceID, nil
}

// RegisterSecretKey 提交 core 构造的加密设备材料，返回服务端下发的 data.key
// 密文（需要 core 用主密钥再解一次才是真正的密钥）。
func (c *Client) RegisterSecretKey(ctx context.Context, encryptContent string) (string, error) {
	if encryptContent == "" {
		return "", fmt.Errorf("%w: registerkey content is empty", ErrInvalidOptions)
	}
	p, err := c.ensureGuest(ctx)
	if err != nil {
		return "", err
	}
	// 用**本设备家族**的参数：device_id 是在 hongguo 家族注册的，混用
	// novelapp 的固定参数会被服务端 200 空响应吞掉（已实测）。
	pairs := protocol.DeviceQueryPairs(c.identity(p))
	payload, err := json.Marshal(map[string]string{"content": encryptContent})
	if err != nil {
		return "", err
	}
	body := gzipBytes(payload)
	ticket := c.clock().UnixMilli()
	rawQuery, headers := sign.SignPOST(PathRegisterSecretKey, pairs, ticket, p.DeviceID, protocol.VersionName, body, nil)
	headers = anonymousHeaders(c, p, ticket, headers)
	headers["Content-Encoding"] = "gzip"
	raw, _, err := c.doRaw(ctx, "POST", c.apiOrigin+PathRegisterSecretKey+"?"+rawQuery, headers, body)
	if err != nil {
		return "", err
	}
	var env struct {
		Data struct {
			Key string `json:"key"`
		} `json:"data"`
	}
	if err := json.Unmarshal(raw, &env); err != nil {
		return "", fmt.Errorf("%w: registerkey response: %v", ErrTransport, err)
	}
	if env.Data.Key == "" {
		return "", fmt.Errorf("%w: registerkey returned no key", ErrContentUnavailable)
	}
	return env.Data.Key, nil
}

// ChapterText 取一章正文的密文（base64(iv‖AES-CBC)），解密由 core 完成。
func (c *Client) ChapterText(ctx context.Context, itemID string) (string, error) {
	if !validID(itemID) {
		return "", fmt.Errorf("%w: invalid chapter id %q", ErrInvalidOptions, itemID)
	}
	p, err := c.ensureGuest(ctx)
	if err != nil {
		return "", err
	}
	pairs := append(protocol.DeviceQueryPairs(c.identity(p)),
		[2]string{"item_id", itemID},
	)
	ticket := c.clock().UnixMilli()
	// 无 body 的 GET：SignPOST 在 body 为 nil 时不生成 x-ss-stub。
	rawQuery, headers := sign.SignPOST(PathChapterText, pairs, ticket, p.DeviceID, protocol.VersionName, nil, nil)
	headers = anonymousHeaders(c, p, ticket, headers)
	raw, _, err := c.doRaw(ctx, "GET", c.apiOrigin+PathChapterText+"?"+rawQuery, headers, nil)
	if err != nil {
		return "", err
	}
	var env struct {
		Data struct {
			Content string `json:"content"`
		} `json:"data"`
	}
	if err := json.Unmarshal(raw, &env); err != nil {
		return "", fmt.Errorf("%w: chapter response: %v", ErrTransport, err)
	}
	return env.Data.Content, nil
}

func gzipBytes(raw []byte) []byte {
	var buf bytes.Buffer
	zw := gzip.NewWriter(&buf)
	_, _ = zw.Write(raw)
	_ = zw.Close()
	return buf.Bytes()
}
