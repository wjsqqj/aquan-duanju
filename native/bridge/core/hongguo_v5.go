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
	"strings"
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

	// v5JoinBudget 是同集在途解析的等待上限：持票方迟迟不出结果时，等待方到点
	// 仍按「v5 不可用」回退，不无限期挡住开播。取值覆盖纯 Go 热路径（0.3-0.5s）
	// 与原生通道冷启动（约 3s，会话自愈时更久）。
	v5JoinBudget = 15 * time.Second

	// v5Source* 标记这一集实际由哪一级实现取到，写进 playbackResult.Channel：
	// "v5-native" / "v5-pure" / "v5-sidecar"。成功路径也留痕，否则无法判断
	// 某一版客户端到底走的是 Unicorn、纯 Go 还是 Python。
	v5SourceNative  = "native"
	v5SourcePureGo  = "pure"
	v5SourceSidecar = "sidecar"
)

// ErrV5Unavailable 表示 v5 sidecar 通道当前不可用（仅内部信号，不外发）。
var ErrV5Unavailable = errors.New("hongguo-v5: unavailable")

// oneLineReason 把错误压成一行短摘要：换行压平、按字节截断到 max——截断可能
// 切断 UTF-8 尾部字符，摘要只供日志对账，可接受。nil 返回空串。
func oneLineReason(err error, max int) string {
	if err == nil {
		return ""
	}
	s := strings.ReplaceAll(err.Error(), "\n", " ")
	if len(s) > max {
		s = s[:max]
	}
	return s
}

// v5DowngradeNote 把被丢弃的 v5 失败原因压成一行短摘要，供回退结果标注
// DowngradeError（诊断「为什么只有 720p」）；nil 返回空串不标注。
func v5DowngradeNote(err error) string {
	if err == nil {
		return ""
	}
	return "v5 unavailable: " + oneLineReason(err, 160)
}

// chainFailureDiagnostic 汇总整条解析链都失败时被静默丢弃的中间环节原因
// （v5、旧 appchain），挂进错误信封的 diagnostic 字段（见 withDiagnostic）。
// 主错误（web 通道原错误）已在 message 里，这里不重复。
//
// 背景（11-26）：整条链都失败时只对外返回 web 通道原错误，v5 为什么失败无从
// 得知——日志里只剩「webplay 取流失败，回落旧接口: …403」，两次「选集先失败
// 再成功」因此判断不了原因。
func chainFailureDiagnostic(vErr, aErr error) string {
	var b strings.Builder
	for _, leg := range []struct {
		name string
		err  error
	}{{"v5", vErr}, {"appchain", aErr}} {
		if leg.err == nil {
			continue
		}
		if b.Len() > 0 {
			b.WriteString(" · ")
		}
		b.WriteString(leg.name)
		b.WriteString(": ")
		b.WriteString(oneLineReason(leg.err, 240))
	}
	return b.String()
}

var (
	v5mu         sync.Mutex
	v5failStreak int
	v5openUntil  time.Time
	v5inFlight   map[string]*v5Flight
	v5cache      = map[string]v5cacheEntry{}
)

// v5Flight 是一次在途的 v5 解析：先到者持票，同集后到者等它的结果并共用。
//
// 原实现里后到者立刻拿到 ErrV5Unavailable，解析链随即静默回落 720p 封顶的
// webplay——而持票方几秒后其实解析成功。播放页进页时「首集预热」与「正片
// 取流」几乎同时发起，必然撞车；第 1-5 集 webplay 快路径出流成功，就停在
// 720p（11-26 实测，移动端与 PC 均复现）。
type v5Flight struct {
	// done 在持票方收尾时关闭；结果字段先写完再关闭，等待方在 done 关闭后
	// 读取（channel close 提供同步）。
	done     chan struct{}
	playback *model.Playback
	key      model.ContentKey
	source   string
	err      error
}

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
	return v5Resolve(ctx, c, profilePathOf(c), episodeID, resolveViaV5Uncached)
}

// v5Resolver 是一次未缓存的 v5 解析（实现见 resolveViaV5Uncached）。
type v5Resolver func(ctx context.Context, c *sdk.Client, profilePath, episodeID string) (*model.Playback, model.ContentKey, string, error)

// v5Resolve 是 resolveViaV5 的主体；resolve 可注入，供离线测试复现同集并发
// 撞车而不触网。同一集同时只解析一次：命中缓存直接返回，已有在途则等待并
// 共用其结果（见 v5Flight），否则自己持票。
func v5Resolve(ctx context.Context, c *sdk.Client, profilePath, episodeID string, resolve v5Resolver) (*model.Playback, model.ContentKey, string, error) {
	if v5BreakerOpen() {
		return nil, model.ContentKey{}, "", fmt.Errorf("%w: breaker-open", ErrV5Unavailable)
	}
	v5mu.Lock()
	cacheKey := profilePath + "|" + episodeID
	if hit, ok := v5cache[cacheKey]; ok && time.Now().Before(hit.expires) {
		v5mu.Unlock()
		return hit.playback, hit.key, hit.source, nil
	}
	if v5inFlight == nil {
		v5inFlight = map[string]*v5Flight{}
	}
	if fl, busy := v5inFlight[cacheKey]; busy {
		v5mu.Unlock()
		return v5JoinFlight(ctx, fl, v5JoinBudget)
	}
	fl := &v5Flight{done: make(chan struct{})}
	v5inFlight[cacheKey] = fl
	v5mu.Unlock()

	var (
		pb     *model.Playback
		key    model.ContentKey
		source string
		err    error
	)
	// defer 收尾：解析 panic 也要放行等待方（结果为空 → 等待方按不可用回退）。
	defer func() { v5FinishFlight(cacheKey, fl, pb, key, source, err) }()

	pb, key, source, err = resolve(ctx, c, profilePath, episodeID)
	if err != nil {
		v5NoteFail()
		err = fmt.Errorf("%w: %v", ErrV5Unavailable, err)
		return nil, model.ContentKey{}, "", err
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

// v5FinishFlight 是持票方的收尾：回填结果、摘牌、放行等待方。先摘牌再关闭
// done——此后同集的请求要么命中缓存（成功），要么自己成为新的持票方（失败）。
func v5FinishFlight(cacheKey string, fl *v5Flight, pb *model.Playback, key model.ContentKey, source string, err error) {
	fl.playback, fl.key, fl.source, fl.err = pb, key, source, err
	v5mu.Lock()
	delete(v5inFlight, cacheKey)
	v5mu.Unlock()
	close(fl.done)
}

// v5JoinFlight 等同集在途解析出结果并共用，最多等 budget；持票方失败时带
// 回同一原因（仍属 v5 不可用，调用方照旧回落，不重发——熔断只由持票方记）。
func v5JoinFlight(ctx context.Context, fl *v5Flight, budget time.Duration) (*model.Playback, model.ContentKey, string, error) {
	timer := time.NewTimer(budget)
	defer timer.Stop()
	select {
	case <-fl.done:
		if fl.err != nil {
			return nil, model.ContentKey{}, "", fl.err
		}
		if fl.playback == nil {
			return nil, model.ContentKey{}, "", fmt.Errorf("%w: in-flight-no-result", ErrV5Unavailable)
		}
		return fl.playback, fl.key, fl.source, nil
	case <-ctx.Done():
		return nil, model.ContentKey{}, "", fmt.Errorf("%w: %v", ErrV5Unavailable, ctx.Err())
	case <-timer.C:
		return nil, model.ContentKey{}, "", fmt.Errorf("%w: in-flight-wait-timeout", ErrV5Unavailable)
	}
}

func resolveViaV5Uncached(ctx context.Context, c *sdk.Client, profilePath, episodeID string) (*model.Playback, model.ContentKey, string, error) {
	dataDir := v5DataDir(profilePath)
	if dataDir == "" {
		return nil, model.ContentKey{}, "", errors.New("sidecar-datadir-missing")
	}
	if err := os.MkdirAll(dataDir, 0o755); err != nil {
		return nil, model.ContentKey{}, "", err
	}

	debugV5 := os.Getenv("HONGGUO_V5_DEBUG") == "1"

	// ① 纯 Go V5 签名（v0.4.0 移植，无 cgo / 无 Python / 无 .so）。
	// 2026-11-18 实测：同一分集 0.27–0.51s，原生 Unicorn 2.8s（后者要跑
	// mssdk 令牌 + ARM64 摘要模拟）。因此把它放在首选；连续 4 集 4/4 成功。
	// 失败时保留模型冒泡（拿到模型但密钥解不开不重复请求），无模型则落下一级。
	purePB, pureKey, pureErr := resolvePureGoV5(ctx, c, episodeID)
	if pureErr == nil {
		if debugV5 {
			fmt.Fprintf(os.Stderr, "[v5] pure-go ok ep=%s\n", episodeID)
		}
		return purePB, pureKey, v5SourcePureGo, nil
	}
	if purePB != nil {
		return purePB, pureKey, v5SourcePureGo, pureErr
	}
	if ctx.Err() != nil {
		return nil, model.ContentKey{}, "", ctx.Err()
	}
	if debugV5 {
		fmt.Fprintf(os.Stderr, "[v5] pure-go failed err=%v；回落 native\n", pureErr)
	}

	// ② Go 原生通道（官方指纹：mssdk 令牌 + Unicorn ARM64 摘要；约 2.8s）。
	// 纯 Go 签名被风控拒绝时由它兜底；只有「native 不可用」类错误才继续往下。
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
		return nil, model.ContentKey{}, "", fmt.Errorf("v5: pure: %v; native: %v", pureErr, nerr)
	}
	if debugV5 {
		fmt.Fprintf(os.Stderr, "[v5] native unavailable err=%v；回落 sidecar\n", nerr)
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

// warmupPlayback 预热 V5 通道的设备/素材/mssdk 会话，**不请求播放模型**，
// 因此不消耗「每台匿名设备基本只给一次」的播放配额。
//
// 无 cgo 时 Go 原生通道不可用；纯 Go 签名不依赖 mssdk 会话，视为无需预热，
// 直接返回成功，调用方不必区分构建形态。
func warmupPlayback(profilePath string) error {
	dataDir := v5DataDir(profilePath)
	if dataDir == "" {
		return errors.New("warmup: profile-path-missing")
	}
	err := hongguov5.Warmup(dataDir)
	if errors.Is(err, hongguov5.ErrNativeUnavailable) {
		return nil
	}
	return err
}
