package hongguov5

// assets.go — SDK 素材获取与官方制品常量提取（移植自 sidecar v5assets.py）：
// 随应用分发的锁定素材（go:embed）最高优先，APK 分段 Range 下载仅作刷新兜底。
// 素材是官方公开分发的制品，哈希全锁定（互操作事实）。

import (
	"compress/zlib"
	"crypto/aes"
	"crypto/md5"
	cryptrc4 "crypto/rc4"
	"crypto/sha1"
	"embed"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const (
	apkURL     = "https://lf9-apk.ugapk.cn/package/apk/novelread/12267_74332/novelread_78105987a_v12267_74332_b929_1793271281.apk?v=1793271287"
	apkSize    = 112946914
	imageSHA   = "c6831ab265a0cb76dacfa3b7041e9ea0f706490106a74e12f39058671cc14fe3"
	configSHA  = "584a01183f1e6783326bff49d4f1319f33fcce678afb93ca0dc8b60a56b65855"
	imageSize  = 4501136
	configSize = 304
)

// (apk 内起始偏移, 压缩段大小, 压缩段 sha256, 解压后大小)
var apkParts = map[string][4]any{
	"libmetasec_ml.so":       {uint64(1497823), uint64(1497823), "3839797f0a1e0ef6c604d639d0054a527b99ed1fa6aa9ecd2e80a9d87c8d133f", uint64(4501136)},
	"sdk-app-config.encoded": {uint64(64901723), uint64(3915212), "46526aa656dd910e06aeedbb2b23b5b846fd029ae49841587d38fcc4f9f277e6", uint64(10417728)},
}

var errAssets = errors.New("hongguov5: assets")

// embeddedAssets 哈希锁定的官方制品（与本包同目录 assets/，go:embed）。
//
//go:embed assets
var embeddedAssets embed.FS

// loadAssets 返回两份素材（内嵌优先 → 数据目录缓存 → CDN 分段下载）。
func loadAssets(dataDir string, allowDownload bool) (map[string][]byte, error) {
	root := ""
	if dataDir != "" {
		root = filepath.Join(dataDir, "playback-sdk", "74332")
		_ = os.MkdirAll(root, 0o755)
	}
	files := map[string][2]string{
		"libmetasec_ml.so":       {strconv.Itoa(imageSize), imageSHA},
		"sdk-app-config.encoded": {strconv.Itoa(configSize), configSHA},
	}
	results := map[string][]byte{}
	for name, spec := range files {
		// 1) 内嵌素材
		if data, err := embeddedAssets.ReadFile("assets/" + name); err == nil {
			if len(data) != mustInt(spec[0]) || sha256Hex(data) != spec[1] {
				return nil, fmt.Errorf("%w: embedded-integrity-failed", errAssets)
			}
			results[name] = data
			continue
		}
		// 2) 数据目录缓存
		if root != "" {
			if data, err := os.ReadFile(filepath.Join(root, name)); err == nil {
				if len(data) != mustInt(spec[0]) || sha256Hex(data) != spec[1] {
					return nil, fmt.Errorf("%w: cache-integrity-failed", errAssets)
				}
				results[name] = data
				continue
			}
		}
		if !allowDownload {
			return nil, fmt.Errorf("%w: materials-not-installed", errAssets)
		}
		// 3) APK 分段下载
		data, err := downloadPart(name)
		if err != nil {
			return nil, err
		}
		if root != "" {
			_ = os.WriteFile(filepath.Join(root, name+".tmp"), data, 0o644)
			_ = os.Rename(filepath.Join(root, name+".tmp"), filepath.Join(root, name))
		}
		results[name] = data
	}
	return results, nil
}

func mustInt(s string) int {
	n := 0
	for i := 0; i < len(s); i++ {
		n = n*10 + int(s[i]-'0')
	}
	return n
}

func downloadPart(name string) ([]byte, error) {
	part := apkParts[name]
	start := part[0].(uint64)
	size := part[1].(uint64)
	digest := part[2].(string)
	unpacked := part[3].(uint64)
	end := start + size - 1
	current := apkURL
	visited := map[string]bool{current: true}
	client := &http.Client{
		Transport: &http.Transport{Proxy: nil},
		Timeout:   25 * time.Second,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			return http.ErrUseLastResponse // 手动校验重定向
		},
	}
	var packed []byte
	for hop := 0; hop < 3; hop++ {
		req, err := http.NewRequest("GET", current, nil)
		if err != nil {
			return nil, err
		}
		req.Header.Set("Range", fmt.Sprintf("bytes=%d-%d", start, end))
		req.Header.Set("Accept-Encoding", "identity")
		resp, err := client.Do(req)
		if err != nil {
			return nil, fmt.Errorf("%w: range-unavailable", errAssets)
		}
		code := resp.StatusCode
		if code >= 301 && code <= 308 {
			resp.Body.Close()
			if hop == 2 {
				return nil, fmt.Errorf("%w: redirect-limit", errAssets)
			}
			next, err := redirectOK(current, resp.Header.Get("Location"), visited)
			if err != nil {
				return nil, err
			}
			current = next
			continue
		}
		if code != 206 || resp.Header.Get("Content-Range") != fmt.Sprintf("bytes %d-%d/%d", start, end, apkSize) {
			resp.Body.Close()
			return nil, fmt.Errorf("%w: range-unavailable", errAssets)
		}
		if enc := resp.Header.Get("Content-Encoding"); enc != "" && enc != "identity" {
			resp.Body.Close()
			return nil, fmt.Errorf("%w: encoding-invalid", errAssets)
		}
		packed, err = io.ReadAll(io.LimitReader(resp.Body, int64(size)+1))
		resp.Body.Close()
		if err != nil {
			return nil, fmt.Errorf("%w: range-unavailable", errAssets)
		}
		break
	}
	if packed == nil || uint64(len(packed)) != size {
		return nil, fmt.Errorf("%w: transfer-limit", errAssets)
	}
	if sha256Hex(packed) != digest {
		return nil, fmt.Errorf("%w: integrity-failed", errAssets)
	}
	result, err := inflateRaw(packed, int64(unpacked))
	if err != nil {
		return nil, err
	}
	if name == "sdk-app-config.encoded" {
		if len(result) < 1936053+304 {
			return nil, fmt.Errorf("%w: size-invalid", errAssets)
		}
		result = result[1936053 : 1936053+304]
	}
	expected := map[string][2]string{
		"libmetasec_ml.so":       {"4501136", imageSHA},
		"sdk-app-config.encoded": {"304", configSHA},
	}[name]
	if strconv.Itoa(len(result)) != expected[0] || sha256Hex(result) != expected[1] {
		return nil, fmt.Errorf("%w: integrity-failed", errAssets)
	}
	return result, nil
}

var redirectHostRE = regexp.MustCompile(`^(.*\.)?(ugapk\.cn|jspcdn\.cn)$`)

func redirectOK(current, location string, visited map[string]bool) (string, error) {
	if location == "" || len(location) > 8192 {
		return "", fmt.Errorf("%w: redirect-invalid", errAssets)
	}
	parsed, err := url.Parse(current)
	if err != nil {
		return "", fmt.Errorf("%w: redirect-invalid", errAssets)
	}
	target, err := parsed.Parse(location)
	if err != nil {
		return "", fmt.Errorf("%w: redirect-invalid", errAssets)
	}
	if target.Scheme != "https" || target.User != nil || target.Fragment != "" ||
		(target.Port() != "" && target.Port() != "443" && target.Port() != "20443") ||
		!redirectHostRE.MatchString(target.Hostname()) {
		return "", fmt.Errorf("%w: redirect-invalid", errAssets)
	}
	for _, r := range target.Path + target.RawQuery {
		if r < 33 || r == 127 {
			return "", fmt.Errorf("%w: redirect-invalid", errAssets)
		}
	}
	if visited[target.String()] {
		return "", fmt.Errorf("%w: redirect-invalid", errAssets)
	}
	visited[target.String()] = true
	return target.String(), nil
}

func inflateRaw(packed []byte, limit int64) ([]byte, error) {
	zr, err := zlib.NewReader(strings.NewReader(string(packed)))
	if err != nil {
		return nil, fmt.Errorf("%w: compression-invalid", errAssets)
	}
	defer zr.Close()
	out, err := io.ReadAll(io.LimitReader(zr, limit+1))
	if err != nil {
		return nil, fmt.Errorf("%w: compression-invalid", errAssets)
	}
	if int64(len(out)) != limit {
		return nil, fmt.Errorf("%w: size-invalid", errAssets)
	}
	return out, nil
}

// ---- 官方素材内常量提取 ----

// readSDKImage 提取摘要帧/置换表/交换内钥（偏移为互操作事实）。
func readSDKImage(image []byte) (map[string][]byte, string, error) {
	if len(image) != imageSize || sha256Hex(image) != imageSHA {
		return nil, "", errors.New("hongguov5: unsupported-sdk-image")
	}
	// python: image[0x66690:0x66698] + xor(image[0x9D08C:0x9D094], image[0x9D118:0x9D120])
	inner := make([]byte, 16)
	copy(inner[:8], image[0x66690:0x66698])
	for i := 0; i < 8; i++ {
		inner[8+i] = image[0x9D08C+i] ^ image[0x9D118+i]
	}
	substitutions := make([]byte, 0x400)
	copy(substitutions, image[0xFFCF9:0x1000F9])
	unavailable := string(image[0x66C44:0x66C4C])
	return map[string][]byte{
		"frame":              append([]byte(nil), image[0x665F0:0x66600]...),
		"substitutions":      substitutions,
		"exchange_inner_key": inner,
	}, unavailable, nil
}

// decodeAppConfig 解码配置帧 → sign_key / common_key（AES-ECB 包裹 + RC4 流）。
func decodeAppConfig(encoded []byte) (signingKey, exchangeKey []byte, err error) {
	if len(encoded) != 304 {
		return nil, nil, errors.New("hongguov5: invalid-config-size")
	}
	raw, err := base64.StdEncoding.DecodeString(string(encoded))
	if err != nil {
		return nil, nil, errors.New("hongguov5: invalid-config-frame")
	}
	if len(raw) != 228 {
		return nil, nil, errors.New("hongguov5: invalid-config-frame")
	}
	application := []byte("8662")
	nonce := raw[:4]
	wrapKey := md5.Sum(append(append(append([]byte(nil), application...), nonce...), application...))
	block, err := aes.NewCipher(wrapKey[:])
	if err != nil {
		return nil, nil, err
	}
	plaintext := make([]byte, len(raw)-4)
	block.Decrypt(plaintext, raw[4:]) // ECB 逐块解密
	for i := 16; i < len(plaintext); i += 16 {
		block.Decrypt(plaintext[i:], raw[4+i:4+i+16])
	}
	padding := int(plaintext[len(plaintext)-1])
	if padding < 1 || padding > 16 {
		return nil, nil, errors.New("hongguov5: invalid-config-padding")
	}
	for _, b := range plaintext[len(plaintext)-padding:] {
		if b != byte(padding) {
			return nil, nil, errors.New("hongguov5: invalid-config-padding")
		}
	}
	plaintext = plaintext[:len(plaintext)-padding]
	if len(plaintext) < 9 {
		return nil, nil, errors.New("hongguov5: invalid-config-payload")
	}
	head, tail := plaintext[:4], plaintext[len(plaintext)-4:]
	mask := byte(0)
	for _, b := range append(append(append([]byte(nil), nonce...), head...), tail...) {
		mask ^= b
	}
	streamKey := sha1.Sum(append(append(append([]byte(nil), head...), application...), nonce...))
	cipherRC4, err := cryptrc4.NewCipher(streamKey[:])
	if err != nil {
		return nil, nil, err
	}
	payload := make([]byte, len(plaintext)-8)
	cipherRC4.XORKeyStream(payload, plaintext[4:len(plaintext)-4])
	message := make([]byte, len(payload))
	for i, b := range payload {
		message[i] = b ^ mask
	}
	for i, j := 0, len(message)-1; i < j; i, j = i+1, j-1 {
		message[i], message[j] = message[j], message[i]
	}
	found := map[string][]byte{}
	rows, err := pbDecodeLimit(message, 1<<16)
	if err != nil {
		return nil, nil, err
	}
	for _, row := range rows {
		if row.Number != 8 || row.Kind != 2 {
			continue
		}
		sub, err := pbDecode(row.Bytes)
		if err != nil {
			return nil, nil, err
		}
		entry := map[int][]byte{}
		for _, srow := range sub {
			if (srow.Number != 1 && srow.Number != 2) || srow.Kind != 2 {
				return nil, nil, errors.New("hongguov5: invalid-key-entry")
			}
			if _, dup := entry[srow.Number]; dup {
				return nil, nil, errors.New("hongguov5: invalid-key-entry")
			}
			entry[srow.Number] = srow.Bytes
		}
		if _, ok := entry[1]; !ok {
			return nil, nil, errors.New("hongguov5: incomplete-key-entry")
		}
		if _, ok := entry[2]; !ok {
			return nil, nil, errors.New("hongguov5: incomplete-key-entry")
		}
		name := string(entry[1])
		if name != "sign_key" && name != "common_key" {
			return nil, nil, errors.New("hongguov5: unexpected-key-entry")
		}
		if _, dup := found[name]; dup {
			return nil, nil, errors.New("hongguov5: unexpected-key-entry")
		}
		key, err := base64.StdEncoding.DecodeString(string(entry[2]))
		if err != nil || len(key) != 32 {
			return nil, nil, errors.New("hongguov5: invalid-key-size")
		}
		found[name] = key
	}
	signingKey, ok := found["sign_key"]
	if !ok {
		return nil, nil, errors.New("hongguov5: missing-key-entry")
	}
	exchangeKey, ok = found["common_key"]
	if !ok {
		return nil, nil, errors.New("hongguov5: missing-key-entry")
	}
	return signingKey, exchangeKey, nil
}

// pbDecodeLimit 宽松有界解码（配置帧/交换响应用）。
func pbDecodeLimit(data []byte, limit int) ([]PBRow, error) {
	if len(data) > limit {
		return nil, errPB
	}
	return pbDecode(data)
}
