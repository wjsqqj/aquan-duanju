package protocol

// playback_url.go — 播放地址解码（吸收自 openhongguo PR #13）：
// 明文直接通过；Base64 文本直接解；0xa8 信封用模型 key_seed 派生密钥做
// AES-128-CBC 解密。只处理地址，不触碰内容密钥与媒体数据。

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/sha512"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strings"
)

// playbackURLSeedConstants 是信封密钥派生用的固定常量块（互操作事实）。
var playbackURLSeedConstants = []byte{
	0x4d, 0xd4, 0xc2, 0xe6, 0xb8, 0x31, 0x62, 0x09, 0x0e, 0x52, 0xb3, 0xc7, 0xa6, 0x73, 0x3b, 0xa4,
	0x1c, 0xb2, 0x46, 0x2b, 0x82, 0x9a, 0xb5, 0x8a, 0x19, 0x6b, 0x39, 0xdb, 0x57, 0x17, 0x75, 0x24,
	0xf4, 0x9b, 0xaf, 0x7f, 0x08, 0xe8, 0xd6, 0x8d, 0x26, 0xa7, 0x2e, 0x37, 0xc1, 0xa9, 0x5a, 0x2f,
	0x1f, 0x05, 0xa5, 0x18, 0x92, 0xae, 0xf2, 0x94, 0x97, 0x32, 0xb6, 0x2a, 0x38, 0xaa, 0xdd, 0x58,
}

// playbackURL 统一处理明文、Base64 与模型 key_seed 保护的地址。
func playbackURL(value, seed string) (string, error) {
	value = strings.TrimSpace(value)
	if value == "" {
		return "", fmt.Errorf("playback URL is empty")
	}
	if isHTTPAddress(value) {
		return value, nil
	}
	raw, err := decodePlaybackBase64(value)
	if err != nil || len(raw) == 0 {
		return "", fmt.Errorf("playback URL is not encoded data")
	}
	if raw[0] == 0xa8 {
		if len(raw) < 20 || raw[2] != 1 || raw[3] != 0 || (len(raw)-4)%aes.BlockSize != 0 {
			return "", fmt.Errorf("playback URL envelope is invalid")
		}
		seedBytes, err := decodePlaybackBase64(seed)
		if err != nil || len(seedBytes) == 0 {
			return "", fmt.Errorf("playback URL seed is missing or invalid")
		}
		first := sha512.Sum512(seedBytes)
		key := sha512.Sum512(append(first[:], playbackURLSeedConstants...))
		block, err := aes.NewCipher(key[:16])
		if err != nil {
			return "", err
		}
		plaintext := make([]byte, len(raw)-4)
		cipher.NewCBCDecrypter(block, key[16:32]).CryptBlocks(plaintext, raw[4:])
		padding := int(plaintext[len(plaintext)-1])
		if padding > 0 && padding <= aes.BlockSize {
			plaintext = plaintext[:len(plaintext)-padding]
		}
		raw = plaintext
	}
	decoded := strings.TrimSpace(strings.TrimRight(string(raw), "\x00"))
	if !isHTTPAddress(decoded) {
		return "", fmt.Errorf("playback URL has no HTTP(S) address")
	}
	return decoded, nil
}

// decodePlaybackBase64 接受 URL 安全与标准两种 Base64，允许缺失补位。
func decodePlaybackBase64(value string) ([]byte, error) {
	value = strings.NewReplacer("+", "-", "/", "_").Replace(strings.TrimSpace(value))
	value = strings.TrimRight(value, "=")
	return base64.RawURLEncoding.DecodeString(value)
}

// playbackURLOrRaw 解码失败时退回既有语义（maybeDecodeURL），行为不劣化。
func playbackURLOrRaw(value, seed string) string {
	if strings.TrimSpace(value) == "" {
		return ""
	}
	if decoded, err := playbackURL(value, seed); err == nil {
		return decoded
	}
	return maybeDecodeURL(value)
}

func isHTTPAddress(value string) bool {
	return strings.HasPrefix(value, "https://") || strings.HasPrefix(value, "http://")
}

// envelopeExpiry 取信封层的过期时间：优先顶层，其次该集条目（含 V5 的 1004 分组）。
func envelopeExpiry(data map[string]json.RawMessage, episodeID string) int64 {
	if expiry := expiryFields(data); expiry > 0 {
		return expiry
	}
	entry := data[episodeID]
	if raw, ok := data["1004"]; ok && len(raw) > 0 {
		var grouped map[string]json.RawMessage
		if json.Unmarshal(raw, &grouped) == nil {
			if selected, hit := grouped[episodeID]; hit {
				entry = selected
			}
		}
	}
	if len(entry) == 0 {
		return 0
	}
	var fields map[string]json.RawMessage
	if json.Unmarshal(entry, &fields) != nil {
		return 0
	}
	return expiryFields(fields)
}

func expiryFields(fields map[string]json.RawMessage) int64 {
	for _, name := range []string{"url_expire", "expire_time"} {
		raw, ok := fields[name]
		if !ok || len(raw) == 0 {
			continue
		}
		var value flexInt64
		if json.Unmarshal(raw, &value) == nil && value > 0 {
			return int64(value)
		}
	}
	return 0
}
