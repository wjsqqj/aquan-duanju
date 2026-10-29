package core

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestRelayOptionsFromJSON(t *testing.T) {
	opts, err := relayOptionsFromJSON([]byte(
		`{"url":"http://up/1.m3u8","backup_url":"http://up/2.m3u8","dec_key":"ABCDEF","user_agent":"","referer":""}`))
	if err != nil {
		t.Fatalf("解析失败: %v", err)
	}
	if opts.URL != "http://up/1.m3u8" || opts.BackupURL != "http://up/2.m3u8" {
		t.Fatalf("字段不匹配: %+v", opts)
	}
	if _, err := relayOptionsFromJSON([]byte(`not json`)); err == nil {
		t.Fatal("非法 JSON 应报错")
	}
}

func TestBuildFFmpegArgs(t *testing.T) {
	dir := t.TempDir()
	args := buildFFmpegArgs("ffmpeg", relayOptions{
		URL:       "http://up/1.m3u8",
		BackupURL: "http://up/2.m3u8",
		DecKey:    "0xABCDEF12",
	}, dir, "0xABCDEF12")

	joined := strings.Join(args, " ")
	if !strings.Contains(joined, "-decryption_key abcdef12") {
		t.Fatalf("密钥应小写去前缀: %v", args)
	}
	if !strings.Contains(joined, filepath.Join(dir, "index.m3u8")) {
		t.Fatalf("清单输出路径缺失: %v", args)
	}
	if !strings.Contains(joined, "-hls_time 3") {
		t.Fatalf("HLS 分片时长缺失: %v", args)
	}
	// 无 UA/Referer 时不应有空 -headers 参数。
	for _, a := range args {
		if a == "-headers" {
			t.Fatalf("无头时不应出现 -headers: %v", args)
		}
	}
}

func TestListenOnFreePort(t *testing.T) {
	port, ln, err := listenOnFreePort(relayBasePort)
	if err != nil {
		t.Fatalf("监听失败: %v", err)
	}
	defer ln.Close()
	if port < relayBasePort || port >= relayBasePort+50 {
		t.Fatalf("端口越界: %d", port)
	}
}

func TestRandomToken(t *testing.T) {
	a, err := randomToken()
	if err != nil {
		t.Fatal(err)
	}
	b, _ := randomToken()
	if len(a) != 32 || a == b {
		t.Fatalf("token 应为 32 hex 且随机: %s", a)
	}
}

func TestCleanProxyEnv(t *testing.T) {
	t.Setenv("HTTP_PROXY", "http://127.0.0.1:7890")
	t.Setenv("HTTPS_PROXY", "http://127.0.0.1:7890")
	env := cleanProxyEnv()
	for _, e := range env {
		upper := strings.ToUpper(e)
		if strings.HasPrefix(upper, "HTTP_PROXY=") || strings.HasPrefix(upper, "HTTPS_PROXY=") {
			t.Fatalf("代理变量应被剔除: %s", e)
		}
	}
}

// TestCastRelayStartUnavailable：ffmpeg 不存在时秒回 unavailable（CI 环境通常无 ffmpeg）。
func TestCastRelayStartUnavailable(t *testing.T) {
	if _, err := findFFmpeg(); err == nil {
		t.Skip("本机有 ffmpeg，跳过不可用路径测试")
	}
	_, err := castRelayStart(relayOptions{URL: "http://up/1.m3u8", DecKey: "aa"})
	if err == nil {
		t.Fatal("无 ffmpeg 应报错")
	}
	if !errors.Is(err, ErrRelayUnavailable) {
		t.Fatalf("应返回 relay_unavailable: %v", err)
	}
}

// TestCastRelayServeFile：本地 ffmpeg 存在时走完整启动 → HTTP 拉清单 → 停止回收。
// 无加密真源，用「ffmpeg 生成测试 HLS」替代上游（testsrc 是 ffmpeg 自带滤镜）。
func TestCastRelayServeFile(t *testing.T) {
	if _, err := findFFmpeg(); err != nil {
		t.Skip("本机无 ffmpeg，跳过完整链路测试")
	}
	// 先用 ffmpeg 生成一个本地 mp4「上游」（testsrc 自带滤镜）。
	ffmpeg, err := findFFmpeg()
	if err != nil {
		t.Skip("本机无 ffmpeg")
	}
	upstream := filepath.Join(t.TempDir(), "up.mp4")
	gen := exec.Command(ffmpeg, "-hide_banner", "-loglevel", "error",
		"-f", "lavfi", "-i", "testsrc=duration=6:size=320x240:rate=10",
		"-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p", upstream)
	if out, err := gen.CombinedOutput(); err != nil {
		t.Fatalf("上游生成失败: %v (%s)", err, out)
	}
	info, err := castRelayStart(relayOptions{URL: upstream})
	if err != nil {
		t.Fatalf("启动失败: %v", err)
	}
	defer castRelayStop(info.Session)

	// 等清单与首个分片就绪（快检已等 3s，这里再放宽）。
	// 直连客户端：绕过系统代理（中继地址是局域网直连语义）。
	direct := &http.Client{Transport: &http.Transport{Proxy: nil}}
	deadline := time.Now().Add(10 * time.Second)
	var body []byte
	for time.Now().Before(deadline) {
		resp, err := direct.Get(info.URL)
		if err != nil {
			t.Logf("GET err: %v (url=%s)", err, info.URL)
		} else {
			body, _ = io.ReadAll(resp.Body)
			resp.Body.Close()
			t.Logf("GET status=%d len=%d body-head=%.60s", resp.StatusCode, len(body), string(body))
			if strings.Contains(string(body), "#EXTM3U") {
				break
			}
		}
		time.Sleep(300 * time.Millisecond)
	}
	if !strings.Contains(string(body), "#EXTM3U") {
		t.Fatalf("清单未就绪: %s", string(body))
	}

	// token 之外的路径必须 404（防拖走）。
	resp, err := direct.Get(strings.Replace(info.URL, "/cast/"+info.Token+"/", "/cast/wrongtoken/", 1))
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("错误 token 应 404: %d", resp.StatusCode)
	}

	// 停止后会话回收：Status 应报 no_session。
	castRelayStop(info.Session)
	if _, err := castRelayStatus(info.Session); err == nil {
		t.Fatal("停止后 Status 应报会话不存在")
	}
}

// TestRelayInfoJSON：出参字段名符合 FFI 契约（camelCase）。
func TestRelayInfoJSON(t *testing.T) {
	info := (&relaySession{
		id: "s", token: "tok", port: 1, startedAt: time.Now(),
		lastAccess: time.Now(), encrypted: true, ready: true,
	}).info()
	raw, err := json.Marshal(info)
	if err != nil {
		t.Fatal(err)
	}
	for _, field := range []string{`"session"`, `"token"`, `"port"`, `"url"`, `"format":"hls"`, `"encrypted"`, `"uptimeMs"`, `"segments"`, `"ready"`} {
		if !strings.Contains(string(raw), field) {
			t.Fatalf("缺少字段 %s: %s", field, raw)
		}
	}
}
