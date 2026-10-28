package core

import (
	"bytes"
	"context"
	"encoding/base64"
	"errors"
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"

	"github.com/beilunyang/openhongguo/sdk"
)

func pngBytes(t *testing.T) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, 2, 2))
	img.Set(0, 0, color.RGBA{R: 255, A: 255})
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func TestSniffMime(t *testing.T) {
	cases := []struct {
		name string
		data []byte
		want string
	}{
		{"jpeg", []byte{0xFF, 0xD8, 0xFF, 0xE0}, "image/jpeg"},
		{"png", pngBytes(t), "image/png"},
		{"gif87a", []byte("GIF87a-rest"), "image/gif"},
		{"gif89a", []byte("GIF89a-rest"), "image/gif"},
		{"bmp", []byte("BMxx"), "image/bmp"},
		{"webp", []byte("RIFF\x24\x08\x00\x00WEBPVP8 "), "image/webp"},
		// 真实封面的 ftyp major brand。
		{"heic-mif1", append([]byte("\x00\x00\x00\x18ftypmif1\x00\x00\x00\x00"), make([]byte, 8)...), "image/heic"},
		{"heic-heic", append([]byte("\x00\x00\x00\x18ftypheic\x00\x00\x00\x00"), make([]byte, 8)...), "image/heic"},
		{"unknown", []byte("not an image"), ""},
		{"short", []byte{0x00, 0x01}, ""},
	}
	for _, c := range cases {
		if got := sniffMime(c.data); got != c.want {
			t.Errorf("%s: sniffMime = %q, want %q", c.name, got, c.want)
		}
	}
}

func TestConvertImagePassthrough(t *testing.T) {
	raw := pngBytes(t)
	out, mime, converted, err := convertImage(raw)
	if err != nil {
		t.Fatal(err)
	}
	if converted || mime != "image/png" || !bytes.Equal(out, raw) {
		t.Fatalf("PNG 应原样透传: converted=%v mime=%q", converted, mime)
	}
}

func TestConvertImageRejectsUnknown(t *testing.T) {
	if _, _, _, err := convertImage([]byte("garbage")); err == nil {
		t.Fatal("未知格式应报错")
	}
}

func TestConvertImageHeic(t *testing.T) {
	// 用真实 HEIC 样张走完整转码路径（样张是线上封面的本地副本，不入库，
	// 存在时才执行）。
	raw, err := os.ReadFile("../testdata/cover.heic")
	if err != nil {
		t.Skip("无本地 cover.heic 样张，跳过转码用例")
	}
	out, mime, converted, err := convertImage(raw)
	if err != nil {
		t.Fatal(err)
	}
	if !converted || mime != "image/jpeg" {
		t.Fatalf("HEIC 应转码为 JPEG: converted=%v mime=%q", converted, mime)
	}
	cfg, err := jpeg.DecodeConfig(bytes.NewReader(out))
	if err != nil || cfg.Width == 0 {
		t.Fatalf("转码结果不是合法 JPEG: %v", err)
	}
}

func TestFetchImageRejectsEmptyURL(t *testing.T) {
	env := decode(t, Call(mustCreateClient(t), "fetchImage", `[""]`))
	if env.Error == nil || env.Error["code"] != "PARAM_INVALID" {
		t.Fatalf("空 URL 应返回 PARAM_INVALID，得到 %v", env.Error)
	}
}

func TestFetchImageHTTPStatus(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusForbidden)
	}))
	defer srv.Close()
	env := decode(t, Call(mustCreateClient(t), "fetchImage", `["`+srv.URL+`"]`))
	if env.Error == nil {
		t.Fatal("403 应返回错误信封")
	}
	if msg, _ := env.Error["message"].(string); !bytes.Contains([]byte(msg), []byte("403")) {
		t.Fatalf("错误信息应保留 HTTP 状态码: %v", env.Error)
	}
}

func TestFetchImageLive(t *testing.T) {
	// 真实封面冒烟：AQUA_LIVE_SMOKE=1 AQUA_LIVE_COVER_URL=<url> go test ./core/
	if os.Getenv("AQUA_LIVE_SMOKE") == "" {
		t.Skip("设置 AQUA_LIVE_SMOKE=1 后对真实封面 URL 冒烟")
	}
	url := os.Getenv("AQUA_LIVE_COVER_URL")
	if url == "" {
		t.Skip("未设置 AQUA_LIVE_COVER_URL")
	}
	env := decode(t, Call(mustCreateClient(t), "fetchImage", `["`+url+`"]`))
	if env.Error != nil {
		t.Fatalf("fetchImage 失败: %v", env.Error)
	}
	res := env.Result.(map[string]any)
	if res["mime"] != "image/jpeg" {
		t.Fatalf("mime = %v, want image/jpeg", res["mime"])
	}
	data, err := base64.StdEncoding.DecodeString(res["data"].(string))
	if err != nil {
		t.Fatal(err)
	}
	cfg, err := jpeg.DecodeConfig(bytes.NewReader(data))
	if err != nil || cfg.Width == 0 {
		t.Fatalf("结果不是合法 JPEG: %v", err)
	}
}

// fakeResetter 记录重置次数，可编程返回重置失败。
type fakeResetter struct {
	resets    int
	failReset bool
}

func (f *fakeResetter) ResetDevice(context.Context) error {
	f.resets++
	if f.failReset {
		return sdk.ErrTransport
	}
	return nil
}

func TestDeviceHealRetriesOnce(t *testing.T) {
	calls := 0
	run := func(context.Context) (any, error) {
		calls++
		if calls == 1 {
			return nil, sdk.ErrAnonymousLimited
		}
		return "ok", nil
	}
	c := &fakeResetter{}
	v, err := callWithDeviceHeal(context.Background(), c, run)
	if err != nil || v != "ok" {
		t.Fatalf("限流后自愈应成功: v=%v err=%v", v, err)
	}
	if calls != 2 || c.resets != 1 {
		t.Fatalf("应恰好重试一次: calls=%d resets=%d", calls, c.resets)
	}
}

func TestDeviceHealNoRetryOnOtherErrors(t *testing.T) {
	calls := 0
	run := func(context.Context) (any, error) {
		calls++
		return nil, sdk.ErrRateLimited
	}
	c := &fakeResetter{}
	if _, err := callWithDeviceHeal(context.Background(), c, run); err == nil {
		t.Fatal("非限流错误应原样返回")
	}
	if calls != 1 || c.resets != 0 {
		t.Fatalf("非限流错误不应重试: calls=%d resets=%d", calls, c.resets)
	}
}

func TestDeviceHealFailingResetKeepsOriginalError(t *testing.T) {
	calls := 0
	run := func(context.Context) (any, error) {
		calls++
		return nil, sdk.ErrDeviceRejected
	}
	c := &fakeResetter{failReset: true}
	_, err := callWithDeviceHeal(context.Background(), c, run)
	if !errors.Is(err, sdk.ErrDeviceRejected) {
		t.Fatalf("应保留原始错误: %v", err)
	}
	if calls != 1 || c.resets != 1 {
		t.Fatalf("重置失败不应重试: calls=%d resets=%d", calls, c.resets)
	}
}

func TestDeviceHealSecondFailureReturnsOriginal(t *testing.T) {
	calls := 0
	run := func(context.Context) (any, error) {
		calls++
		return nil, sdk.ErrAnonymousLimited
	}
	c := &fakeResetter{}
	_, err := callWithDeviceHeal(context.Background(), c, run)
	if err == nil {
		t.Fatal("重试仍失败应返回错误")
	}
	if calls != 2 {
		t.Fatalf("应恰好执行两次: calls=%d", calls)
	}
}
