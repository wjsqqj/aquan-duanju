package core

import (
	"io"
	"os/exec"
	"net/http"
	"runtime"
	"strings"
	"testing"
	"time"
)

// 桌面镜像端到端（真实 ffmpeg gdigrab）：启动 → 就绪 → 拉清单 → 拉分片 → 停止回收。
// 仅 Windows（gdigrab 平台限定）；ffmpeg 需在 PATH（本机 WinGet 安装）。
func TestCastDesktopStartServeStop(t *testing.T) {
	if runtime.GOOS != "windows" {
		t.Skip("gdigrab 仅 Windows")
	}
	if _, err := findFFmpeg(); err != nil {
		t.Skip("ffmpeg 不可用")
	}

	info, err := castDesktopStart(desktopOptions{FPS: 10})
	if err != nil {
		t.Fatalf("castDesktopStart: %v", err)
	}
	t.Cleanup(func() { _ = castDesktopStop(info.Session) })

	// DXGI 桌面复制只在画面变化时送帧：测试里抖动鼠标制造活动，
	// 否则静态桌面上第一段之后无帧可切（实机上用户画面天然在动）。
	stopActivity := startActivityWindow()
	t.Cleanup(stopActivity)

	// 就绪判定：5s 快检窗口内 index.m3u8 应已产出（ready 或稍后拉到清单均算）。
	if !info.Ready {
		t.Logf("快检窗口内未就绪，等待状态接口确认")
	}
	// 直连客户端：系统代理（clash）会把局域网请求 502 掉（与 castrelay_test 同坑）。
	direct := &http.Client{Transport: &http.Transport{Proxy: nil}, Timeout: 3 * time.Second}
	deadline := time.Now().Add(30 * time.Second)
	var body string
	for {
		if time.Now().After(deadline) {
			t.Fatalf("30s 内清单未就绪: %+v", info)
		}
		resp, err := direct.Get(info.URL)
		if err == nil {
			b, _ := io.ReadAll(resp.Body)
			resp.Body.Close()
			if resp.StatusCode == 200 && strings.Contains(string(b), "#EXTM3U") {
				body = string(b)
				break
			}
		}
		time.Sleep(300 * time.Millisecond)
	}
	if !strings.Contains(body, "seg_") {
		t.Fatalf("清单不含分片: %s", body)
	}

	// 拉第一个分片：200 且非空。
	segLine := ""
	for _, line := range strings.Split(body, "\n") {
		if strings.HasPrefix(line, "seg_") {
			segLine = strings.TrimSpace(line)
			break
		}
	}
	if segLine == "" {
		t.Fatalf("清单无分片行: %s", body)
	}
	segURL := strings.Replace(info.URL, "index.m3u8", segLine, 1)
	resp, err := direct.Get(segURL)
	if err != nil {
		t.Fatalf("拉分片失败: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("分片 HTTP %d", resp.StatusCode)
	}
	buf := make([]byte, 188*3)
	n, _ := io.ReadFull(resp.Body, buf)
	if n < 188 {
		t.Fatalf("分片过小: %d bytes", n)
	}
	// TS 同步字节 0x47。
	if buf[0] != 0x47 {
		t.Fatalf("非 MPEG-TS 分片（sync=%#x）", buf[0])
	}

	// token 随机性：不同会话 token 不同（防局域网拖走的语义保障）。
	info2, err := castDesktopStart(desktopOptions{FPS: 5})
	if err != nil {
		t.Fatalf("第二次 castDesktopStart: %v", err)
	}
	defer func() { _ = castDesktopStop(info2.Session) }()
	if info.Token == info2.Token {
		t.Fatalf("token 未随机化: %s", info.Token)
	}

	// 停止：状态回 ErrRelayNoSession、端口关闭。
	if err := castDesktopStop(info.Session); err != nil {
		t.Fatalf("castDesktopStop: %v", err)
	}
	if _, err := castDesktopStatus(info.Session); err == nil {
		t.Fatalf("停止后 status 仍可查")
	}
}

// 非 Windows 上 Start 必须报 CAST_DESKTOP_UNSUPPORTED（哨兵语义）。
func TestCastDesktopUnsupportedOnNonWindows(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("仅非 Windows")
	}
	if _, err := castDesktopStart(desktopOptions{FPS: 10}); err == nil ||
		!strings.Contains(err.Error(), ErrDesktopUnsupported.Error()) {
		t.Fatalf("期望 unsupported 哨兵，得到: %v", err)
	}
}

// startActivityWindow 起一个 PowerShell 自刷新置顶小窗：DXGI 桌面复制只对
// 「真实像素变化」送帧，静止桌面会让流冻结——测试需要人为制造屏幕活动。
func startActivityWindow() func() {
	script := `Add-Type -AssemblyName System.Windows.Forms
$f = New-Object Windows.Forms.Form
$f.TopMost = $true; $f.Size = New-Object System.Drawing.Size(120, 80)
$f.StartPosition = 'Manual'; $f.Location = New-Object System.Drawing.Point(8, 8)
$f.Show()
$t = New-Object Windows.Forms.Timer; $t.Interval = 150
$i = 0
$t.Add_Tick({ $i++; $f.Text = "t$i"; $f.Invalidate() })
$t.Start()
[System.Windows.Forms.Application]::Run($f)`
	cmd := exec.Command("powershell", "-NoProfile", "-NonInteractive", "-Command", script)
	if err := cmd.Start(); err != nil {
		return func() {}
	}
	return func() {
		_ = cmd.Process.Kill()
		_, _ = cmd.Process.Wait()
	}
}
