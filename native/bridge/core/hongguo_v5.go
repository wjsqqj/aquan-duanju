package core

// hongguo_v5.go — 红果 v5 匿名取流 sidecar 接线（2026-11-17，任务 11-16 方案 A）。
//
// 背景：2026-11-14 起播放接口要求 mssdk 设备令牌（官方 libmetasec_ml.so 设备摘要，
// ARM64 模拟计算），一切纯签名配方（argus/ladon/medusa-v03/免签名）被服务端
// 拒绝——全社区空响应的真根因。v5 路径（注册 → 官方 APK 分段取 SDK 素材 →
// Unicorn 模拟摘要 → mssdk get_token 交换 → v5 签名播放 multi_video_model/
// player/v1）实测匿名全目录出模型（含游客墙外的第 6 集起，见任务
// research-guest-wall-ep6.md 第四轮）。
//
// 实现形态：Python sidecar（native/bridge/hongguo-sidecar/hongguo_v5.py，本项目
// 自有实现）由本文件以子进程调用；会话/设备状态持久在用户数据目录。为什么
// sidecar 而不是 Go 移植：libmetasec 摘要需要 ARM64 Unicorn 模拟（Python 生态
// 现成），后续可用 unicorn cgo 转 Go 内嵌。
//
// 出错语义：sidecar 任何失败（python 缺失/超时/协议拒绝）一律静默回退，由调用方
// 返回 web 通道原错误——WEB_LOGIN_REQUIRED 文案与重试契约不变。

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"time"

	"github.com/beilunyang/openhongguo/sdk"
	"github.com/beilunyang/openhongguo/sdk/model"
	"github.com/wjsqqj/aquan-core/hongguov5"
)

const (
	sidecarTimeout    = 90 * time.Second  // 冷启动（素材缺失时含 APK 分段下载）+ 模拟 + 请求
	sidecarWarmBudget = 30 * time.Second  // 热路径预算（会话就绪时）
	sidecarFailStreak = 3                 // 连续失败 N 次 → 熔断
	sidecarBreakerFor = 10 * time.Minute  // 熔断时长（v5 是活通道，熔断窗口比旧 appchain 短）

	// v5Source* 标记这一集实际由哪一级实现取到，写进 playbackResult.Channel：
	// "v5-native" / "v5-pure" / "v5-sidecar"。成功路径也留痕，否则无法判断
	// 某一版客户端到底走的是 Unicorn、纯 Go 还是 Python。
	v5SourceNative  = "native"
	v5SourcePureGo  = "pure"
	v5SourceSidecar = "sidecar"
)

// ErrV5Unavailable 表示 v5 sidecar 通道当前不可用（仅内部信号，不外发）。
var ErrV5Unavailable = errors.New("hongguo-v5: unavailable")

var (
	v5mu         sync.Mutex
	v5failStreak int
	v5openUntil  time.Time
	v5inFlight   map[string]struct{}
	v5cache      = map[string]v5cacheEntry{}
)

type v5cacheEntry struct {
	playback *model.Playback
	key      model.ContentKey
	source   string
	expires  time.Time
}

type sidecarOutput struct {
	OK      bool             `json:"ok"`
	Error   string           `json:"error"`
	Elapsed float64          `json:"elapsed"`
	Result  *json.RawMessage `json:"result"`
}

// v5BreakerOpen / v5NoteFail / v5NoteOK 控制连续失败熔断。
func v5BreakerOpen() bool {
	v5mu.Lock()
	defer v5mu.Unlock()
	return time.Now().Before(v5openUntil)
}

func v5NoteFail() {
	v5mu.Lock()
	defer v5mu.Unlock()
	v5failStreak++
	if v5failStreak >= sidecarFailStreak {
		v5openUntil = time.Now().Add(sidecarBreakerFor)
	}
}

func v5NoteOK() {
	v5mu.Lock()
	defer v5mu.Unlock()
	v5failStreak = 0
	v5openUntil = time.Time{}
}

// findSidecarScript 定位 sidecar 脚本：环境变量覆盖 → exe 同目录 → 仓库开发路径。
func findSidecarScript() string {
	if env := os.Getenv("HONGGUO_V5_SCRIPT"); env != "" {
		if _, err := os.Stat(env); err == nil {
			return env
		}
	}
	if exe, err := os.Executable(); err == nil {
		candidate := filepath.Join(filepath.Dir(exe), "hongguo-sidecar", "hongguo_v5.py")
		if _, err := os.Stat(candidate); err == nil {
			return candidate
		}
	}
	for _, candidate := range []string{
		filepath.Join("native", "bridge", "hongguo-sidecar", "hongguo_v5.py"),
		filepath.Join("..", "..", "native", "bridge", "hongguo-sidecar", "hongguo_v5.py"),
	} {
		if _, err := os.Stat(candidate); err == nil {
			return candidate
		}
	}
	return ""
}

func sidecarPython() string {
	if env := os.Getenv("HONGGUO_V5_PYTHON"); env != "" {
		return env
	}
	// 内嵌运行时优先（exe 同目录 runtime/，随发布分发；python.exe 在根）。
	if exe, err := os.Executable(); err == nil {
		for _, candidate := range []string{
			filepath.Join(filepath.Dir(exe), "runtime", "python.exe"),
			filepath.Join(filepath.Dir(exe), "runtime", "python", "python.exe"),
		} {
			if _, err := os.Stat(candidate); err == nil {
				return candidate
			}
		}
	}
	for _, name := range []string{"python", "python3", "py"} {
		if path, err := exec.LookPath(name); err == nil {
			return path
		}
	}
	return ""
}

func v5DataDir(profilePath string) string {
	if profilePath == "" {
		return ""
	}
	return filepath.Join(filepath.Dir(profilePath), "hongguo-v5")
}

// resolveNativeV5 跑 Go 原生 v5 解析。c-shared（DLL/so）宿主里不另起 goroutine：
// 子 goroutine 内跑 Unicorn cgo + hook 回 Go 在部分宿主（Python/ctypes 验收实证）
// 会触发堆破坏；原生调用内部 HTTP 已限时 30s，整体耗时可控。
func resolveNativeV5(ctx context.Context, dataDir, episodeID string) ([]byte, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	return hongguov5.Resolve(dataDir, episodeID)
}

// resolveViaV5 解析一集（带进程内缓存与熔断），并返回实际取流的实现来源
// （v5SourceNative / v5SourcePureGo / v5SourceSidecar）。
// 返回 ErrV5Unavailable 表示本通道当前不可用（调用方回退）。
func resolveViaV5(ctx context.Context, c *sdk.Client, episodeID string) (*model.Playback, model.ContentKey, string, error) {
	if c == nil {
		return nil, model.ContentKey{}, "", fmt.Errorf("%w: client-missing", ErrV5Unavailable)
	}
	profilePath := profilePathOf(c)
	if v5BreakerOpen() {
		return nil, model.ContentKey{}, "", ErrV5Unavailable
	}
	v5mu.Lock()
	cacheKey := profilePath + "|" + episodeID
	if hit, ok := v5cache[cacheKey]; ok && time.Now().Before(hit.expires) {
		v5mu.Unlock()
		return hit.playback, hit.key, hit.source, nil
	}
	if v5inFlight == nil {
		v5inFlight = map[string]struct{}{}
	}
	if _, busy := v5inFlight[cacheKey]; busy {
		v5mu.Unlock()
		return nil, model.ContentKey{}, "", ErrV5Unavailable
	}
	v5inFlight[cacheKey] = struct{}{}
	v5mu.Unlock()
	defer func() {
		v5mu.Lock()
		delete(v5inFlight, cacheKey)
		v5mu.Unlock()
	}()

	pb, key, source, err := resolveViaV5Uncached(ctx, c, profilePath, episodeID)
	if err != nil {
		v5NoteFail()
		return nil, model.ContentKey{}, "", fmt.Errorf("%w: %v", ErrV5Unavailable, err)
	}
	v5NoteOK()
	ttl := 10 * time.Minute
	if pb.ExpiresAt > 0 {
		if left := time.Until(time.Unix(pb.ExpiresAt, 0)) - 60*time.Second; left > 0 && left < ttl {
			ttl = left
		}
	}
	v5mu.Lock()
	v5cache[cacheKey] = v5cacheEntry{playback: pb, key: key, source: source, expires: time.Now().Add(ttl)}
	v5mu.Unlock()
	return pb, key, source, nil
}

func resolveViaV5Uncached(ctx context.Context, c *sdk.Client, profilePath, episodeID string) (*model.Playback, model.ContentKey, string, error) {
	dataDir := v5DataDir(profilePath)
	if dataDir == "" {
		return nil, model.ContentKey{}, "", errors.New("sidecar-datadir-missing")
	}
	if err := os.MkdirAll(dataDir, 0o755); err != nil {
		return nil, model.ContentKey{}, "", err
	}

	// ① Go 原生通道（安卓关键：无 Python，Unicorn 内嵌 ARM64 模拟）。
	// 只有「native 不可用」类错误才回落下一级；协议/网络失败不翻倍重试。
	debugV5 := os.Getenv("HONGGUO_V5_DEBUG") == "1"
	if debugV5 {
		fmt.Fprintf(os.Stderr, "[v5] native start ep=%s dir=%s\n", episodeID, dataDir)
	}
	raw, nerr := resolveNativeV5(ctx, dataDir, episodeID)
	if debugV5 {
		fmt.Fprintf(os.Stderr, "[v5] native done err=%v len=%d\n", nerr, len(raw))
	}
	if nerr == nil {
		pb, err := sdk.ParsePlaybackJSON(raw, episodeID)
		if err != nil {
			return nil, model.ContentKey{}, "", fmt.Errorf("native-model: %w", err)
		}
		key, kerr := sdk.ContentKey(pb)
		if errors.Is(kerr, sdk.ErrNotProtected) {
			return pb, model.ContentKey{}, v5SourceNative, nil
		}
		if kerr != nil {
			return pb, model.ContentKey{}, v5SourceNative, kerr
		}
		return pb, key, v5SourceNative, nil
	}
	if !errors.Is(nerr, hongguov5.ErrNativeUnavailable) {
		return nil, model.ContentKey{}, "", fmt.Errorf("native: %v", nerr)
	}

	// ② 纯 Go V5 签名（v0.4.0 移植，无 cgo / 无 Python / 无 .so）。
	// 无 C 工具链的构建里 ① 会立刻返回 ErrNativeUnavailable，这里接管；
	// 成功即返回，不再启动 Python 子进程。
	purePB, pureKey, pureErr := resolvePureGoV5(ctx, c, episodeID)
	if pureErr == nil {
		if debugV5 {
			fmt.Fprintf(os.Stderr, "[v5] pure-go ok ep=%s\n", episodeID)
		}
		return purePB, pureKey, v5SourcePureGo, nil
	}
	if purePB != nil {
		// 拿到了模型但密钥解不开：与 ① 的处理一致，带着模型冒泡，不重复请求。
		return purePB, pureKey, v5SourcePureGo, pureErr
	}
	if ctx.Err() != nil {
		return nil, model.ContentKey{}, "", ctx.Err()
	}
	if debugV5 {
		fmt.Fprintf(os.Stderr, "[v5] pure-go failed err=%v；回落 sidecar\n", pureErr)
	}

	// ③ Python sidecar 兜底（桌面端：内嵌运行时；安卓必然不可用）。
	script := findSidecarScript()
	if script == "" {
		return nil, model.ContentKey{}, "", fmt.Errorf("v5: native unavailable; pure: %v; sidecar-script-missing", pureErr)
	}
	python := sidecarPython()
	if python == "" {
		return nil, model.ContentKey{}, "", fmt.Errorf("v5: native unavailable; pure: %v; sidecar-python-missing", pureErr)
	}

	runCtx, cancel := context.WithTimeout(ctx, sidecarTimeout)
	defer cancel()
	cmd := exec.CommandContext(runCtx, python, script, "resolve", episodeID, dataDir)
	cmd.Env = append(os.Environ(), "PYTHONIOENCODING=utf-8", "PYTHONUTF8=1")
	// 网络直连由 sidecar 内部保证（urllib + ProxyHandler({})）；这里剥代理环境变量。
	for _, name := range []string{"HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"} {
		cmd.Env = append(cmd.Env, name+"=")
	}
	out, err := cmd.Output()
	if err != nil {
		return nil, model.ContentKey{}, "", fmt.Errorf("v5: native unavailable; pure: %v; sidecar-run: %v (%.200s)", pureErr, err, out)
	}
	var parsed sidecarOutput
	if err := json.Unmarshal(out, &parsed); err != nil {
		return nil, model.ContentKey{}, "", fmt.Errorf("v5: native unavailable; pure: %v; sidecar-decode: %w (%.200s)", pureErr, err, out)
	}
	if !parsed.OK || parsed.Result == nil {
		return nil, model.ContentKey{}, "", fmt.Errorf("v5: native unavailable; pure: %v; sidecar-failed: %s", pureErr, parsed.Error)
	}
	// 包成 SDK 解析器认识的信封：{"code":0,"data":{"video_model":…}}
	pb, err := sdk.ParsePlaybackJSON([]byte(*parsed.Result), episodeID)
	if err != nil {
		return nil, model.ContentKey{}, "", fmt.Errorf("sidecar-model: %w", err)
	}
	key, kerr := sdk.ContentKey(pb)
	if errors.Is(kerr, sdk.ErrNotProtected) {
		return pb, model.ContentKey{}, v5SourceSidecar, nil
	}
	if kerr != nil {
		return pb, model.ContentKey{}, v5SourceSidecar, kerr
	}
	return pb, key, v5SourceSidecar, nil
}

// resolvePureGoV5 用纯 Go 的 V5 签名取流（vendor 的 sdk.ResolvePlaybackV5）。
// 与 ① 的产物处理一致：受保护分集返回模型与内容密钥；明文分集返回模型与空密钥。
// 只返回模型但没有模型内容（pb == nil）时，调用方才继续回落 sidecar。
func resolvePureGoV5(ctx context.Context, c *sdk.Client, episodeID string) (*model.Playback, model.ContentKey, error) {
	pb, err := c.ResolvePlaybackV5(ctx, episodeID)
	if pb == nil {
		if err == nil {
			err = errors.New("pure-go: no playback model")
		}
		return nil, model.ContentKey{}, err
	}
	key, kerr := sdk.ContentKey(pb)
	if errors.Is(kerr, sdk.ErrNotProtected) {
		return pb, model.ContentKey{}, nil
	}
	if kerr != nil {
		return pb, model.ContentKey{}, kerr
	}
	return pb, key, nil
}
