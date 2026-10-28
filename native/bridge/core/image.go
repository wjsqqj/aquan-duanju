package core

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"image/jpeg"
	"io"
	"net/http"
	"time"

	heic "github.com/gen2brain/heic"

	"github.com/beilunyang/openhongguo/sdk"
)

// 服务端返回的封面 URL 签名里固定了 .heic 模板（x-signature 覆盖整个
// tplv 模板，改扩展名即失效），而 Flutter 引擎不解码 HEIC，所以由核心
// 下载并转成 JPEG 再交给 UI。转码用 gen2brain/heic（wazero 运行 WASM，
// 纯 Go 无 cgo，各平台构建脚本不变）；wazero 的模块编译缓存是进程级的，
// 进程内只有第一张图承担编译开销。

const (
	// fetchImageMaxBytes 是单张图片的下载上限，防异常大图占满内存。
	fetchImageMaxBytes = 20 << 20

	// jpegQuality 在清晰度与体积之间取平衡：1200px 封面约 60–150KB。
	jpegQuality = 88
)

var imageClient = &http.Client{Timeout: 30 * time.Second}

// imageResult 是 fetchImage 的返回值。data 是图片字节的 base64；mime 是
// 可直接交给图片解码器的类型（HEIC 一律转成 image/jpeg）。
type imageResult struct {
	Data      string `json:"data"`
	Mime      string `json:"mime"`
	Converted bool   `json:"converted"`
}

// fetchImage 下载一张封面图；HEIC/HEIF 转码为 JPEG，其余支持的格式
// （JPEG/PNG/GIF/WebP/BMP）原样透传。失败返回错误信封，HTTP 状态码
// 保留在 message 里供 UI 提示（403 = 签名过期）。
func fetchImage(ctx context.Context, _ *sdk.Client, a []json.RawMessage) (any, error) {
	var rawURL string
	if err := arg(a, 0, &rawURL); err != nil {
		return nil, err
	}
	if rawURL == "" {
		return nil, fmt.Errorf("%w: fetchImage: url is empty", sdk.ErrParamInvalid)
	}
	data, err := downloadImage(ctx, rawURL)
	if err != nil {
		return nil, err
	}
	out, mime, converted, err := convertImage(data)
	if err != nil {
		return nil, fmt.Errorf("%w: fetchImage: %v", sdk.ErrContentUnavailable, err)
	}
	return imageResult{
		Data:      base64.StdEncoding.EncodeToString(out),
		Mime:      mime,
		Converted: converted,
	}, nil
}

// downloadImage 取回图片字节。
func downloadImage(ctx context.Context, rawURL string) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil {
		return nil, fmt.Errorf("%w: fetchImage: %v", sdk.ErrParamInvalid, err)
	}
	resp, err := imageClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("%w: fetchImage: %v", sdk.ErrTransport, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("%w: fetchImage: HTTP %d", sdk.ErrContentUnavailable, resp.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, fetchImageMaxBytes+1))
	if err != nil {
		return nil, fmt.Errorf("%w: fetchImage: %v", sdk.ErrTransport, err)
	}
	if len(data) > fetchImageMaxBytes {
		return nil, fmt.Errorf("%w: fetchImage: image exceeds %d bytes", sdk.ErrContentUnavailable, fetchImageMaxBytes)
	}
	return data, nil
}

// convertImage 依字节魔数判断格式：Flutter 解码器支持的格式透传，
// HEIC/HEIF 解码后重编为 JPEG。返回 (字节, mime, 是否转码, 错误)。
func convertImage(data []byte) ([]byte, string, bool, error) {
	mime := sniffMime(data)
	switch mime {
	case "image/heic":
		img, err := heic.Decode(bytes.NewReader(data))
		if err != nil {
			return nil, "", false, fmt.Errorf("decode heic: %v", err)
		}
		var out bytes.Buffer
		if err := jpeg.Encode(&out, img, &jpeg.Options{Quality: jpegQuality}); err != nil {
			return nil, "", false, fmt.Errorf("encode jpeg: %v", err)
		}
		return out.Bytes(), "image/jpeg", true, nil
	case "":
		return nil, "", false, fmt.Errorf("unsupported image format")
	default:
		return data, mime, false, nil
	}
}

// sniffMime 依字节魔数识别图片格式，不信任 Content-Type（签名 CDN 对
// HEIC 一律返回 image/heic，其余格式魔数判定足够）。无法识别返回空串。
func sniffMime(data []byte) string {
	switch {
	case bytes.HasPrefix(data, []byte{0xFF, 0xD8, 0xFF}):
		return "image/jpeg"
	case bytes.HasPrefix(data, []byte{0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A}):
		return "image/png"
	case bytes.HasPrefix(data, []byte("GIF87a")), bytes.HasPrefix(data, []byte("GIF89a")):
		return "image/gif"
	case bytes.HasPrefix(data, []byte("BM")):
		return "image/bmp"
	case len(data) >= 12 && bytes.Equal(data[0:4], []byte("RIFF")) && bytes.Equal(data[8:12], []byte("WEBP")):
		return "image/webp"
	case isHEIF(data):
		return "image/heic"
	}
	return ""
}

// isHEIF 识别 ISO-BMFF 容器：ftyp box 的 major brand 属于 HEIF 家族
// （heic/heix/hevc/heif/mif1/msf1）。真实封面常见 mif1 与 heic。
func isHEIF(data []byte) bool {
	if len(data) < 12 || !bytes.Equal(data[4:8], []byte("ftyp")) {
		return false
	}
	switch string(data[8:12]) {
	case "heic", "heix", "hevc", "heif", "mif1", "msf1":
		return true
	}
	return false
}
