package hongguov5

// resolver.go — v5 取流编排（移植自 sidecar hongguo_v5.py resolve 流程）：
// 设备注册 → 素材 → 会话 → prepare_playback_v5 → 发送 → {"code":0,"data":…} 信封。
// unicorn 摘要引擎进程级缓存（历史无关性已验证），digest 调用互斥。

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

var (
	// ErrNativeUnavailable 表示 Go 原生 v5 通道不可用（no-cgo 构建/引擎初始化失败）。
	ErrNativeUnavailable = errors.New("hongguov5: native unavailable")
	// ErrProtocol 协议层被拒（注册/交换/播放 code 非 0 等）。
	ErrProtocol = errors.New("hongguov5: protocol")
)

// Resolve 解析一集，返回播放信封原始 JSON（{"code":0,"data":{"video_model":…}}），
// 交由 sdk.ParsePlaybackJSON 解析。dataDir 存设备/会话状态。
func Resolve(dataDir, episodeID string) ([]byte, error) {
	// 环境开关：HONGGUO_V5_NATIVE=0 强制回落 sidecar（运行时回滚开关）。
	if os.Getenv("HONGGUO_V5_NATIVE") == "0" {
		return nil, ErrNativeUnavailable
	}
	if !isEpisodeID(episodeID) {
		return nil, fmt.Errorf("%w: invalid-episode-id", ErrProtocol)
	}
	abs, err := filepath.Abs(dataDir)
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(abs, 0o755); err != nil {
		return nil, err
	}
	var lastErr error
	sessionFile := filepath.Join(abs, "hongguo-sdk-session.json")
	for attempt := 0; attempt < 2; attempt++ {
		result, err := resolveOnce(abs, episodeID)
		if err == nil {
			return result, nil
		}
		lastErr = err
		if attempt > 0 {
			break
		}
		// 会话自愈：令牌过期/失效时重交换一次。新会话（<5min）失败不刷新。
		if info, err := os.Stat(sessionFile); err == nil &&
			time.Since(info.ModTime()) < 300*time.Second {
			break
		}
		_ = os.Remove(sessionFile)
	}
	return nil, lastErr
}

func resolveOnce(dataDir, episodeID string) ([]byte, error) {
	ent := cryptoEntropy()
	state, err := ensureDevice(dataDir, ent)
	if err != nil {
		return nil, fmt.Errorf("%w: register: %v", ErrProtocol, err)
	}
	assets, err := loadAssets(dataDir, true)
	if err != nil {
		return nil, fmt.Errorf("%w: assets: %v", ErrProtocol, err)
	}
	signingKey, exchangeKey, err := decodeAppConfig(assets["sdk-app-config.encoded"])
	if err != nil {
		return nil, fmt.Errorf("%w: config: %v", ErrProtocol, err)
	}
	image, unavailable, err := readSDKImage(assets["libmetasec_ml.so"])
	if err != nil {
		return nil, err
	}
	materials := map[string][]byte{"signing_key": signingKey, "exchange_key": exchangeKey}

	core, err := acquireDigestCore(assets["libmetasec_ml.so"])
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrNativeUnavailable, err)
	}
	coreFn := digestForResolver(core)
	session, err := ensureSession(dataDir, state.Params, state.Cookies,
		materials, image, unavailable, coreFn, ent)
	if err != nil {
		return nil, fmt.Errorf("%w: exchange: %v", ErrProtocol, err)
	}
	request, _, err := preparePlaybackV5(state.Params, state.Cookies, episodeID,
		timeNowMS(), session.Token, session.Ladon, materials, image, coreFn, ent)
	if err != nil {
		return nil, fmt.Errorf("%w: sign: %v", ErrProtocol, err)
	}
	raw, err := sendRequest(request)
	if err != nil {
		return nil, fmt.Errorf("%w: send: %v", ErrProtocol, err)
	}
	var value struct {
		Code int            `json:"code"`
		Data map[string]any `json:"data"`
	}
	if err := json.Unmarshal(raw, &value); err != nil {
		return nil, fmt.Errorf("%w: decode: %v", ErrProtocol, err)
	}
	if value.Code != 0 {
		return nil, fmt.Errorf("%w: playback-code-%d", ErrProtocol, value.Code)
	}
	entry, ok := value.Data[episodeID].(map[string]any)
	if !ok {
		return nil, fmt.Errorf("%w: invalid-model", ErrProtocol)
	}
	modelRaw, ok := entry["video_model"]
	if !ok {
		return nil, fmt.Errorf("%w: invalid-model", ErrProtocol)
	}
	var model any
	if s, isStr := modelRaw.(string); isStr {
		if err := json.Unmarshal([]byte(s), &model); err != nil {
			return nil, fmt.Errorf("%w: model-decode: %v", ErrProtocol, err)
		}
	} else {
		model = modelRaw
	}
	envelope, err := json.Marshal(map[string]any{"code": 0, "data": map[string]any{"video_model": model}})
	if err != nil {
		return nil, err
	}
	return envelope, nil
}

// isEpisodeID 对齐 python：纯数字 8..24 位。
func isEpisodeID(id string) bool {
	if len(id) < 8 || len(id) > 24 {
		return false
	}
	return isAllDigits(id)
}

// ---- 摘要引擎缓存（进程级） ----

var (
	coreMu       sync.Mutex
	coreInstance *sdkDigestCore
	coreImageSum string
)

func acquireDigestCore(image []byte) (*sdkDigestCore, error) {
	sum := sha256Hex(image)
	coreMu.Lock()
	defer coreMu.Unlock()
	if coreInstance != nil && coreImageSum == sum {
		return coreInstance, nil
	}
	if coreInstance != nil {
		coreInstance.Close()
		coreInstance = nil
	}
	core, err := newSDKDigestCore(image)
	if err != nil {
		return nil, err
	}
	coreInstance = core
	coreImageSum = sum
	return core, nil
}

// digestOnce 包装 digest 调用（引擎状态互斥：同一实例不允许并发模拟）。
func (c *sdkDigestCore) digestLocked(payload []byte, mode int, seconds uint32) ([]byte, error) {
	coreMu.Lock()
	defer coreMu.Unlock()
	return c.digest(payload, mode, seconds)
}

// digestForResolver 供 digestFunc 使用：加锁 + 失败时丢弃引擎（python 语义）。
func digestForResolver(c *sdkDigestCore) digestFunc {
	return func(payload []byte, mode int, seconds uint32) ([]byte, error) {
		out, err := c.digestLocked(payload[:len(payload):len(payload)], mode, seconds)
		if err != nil {
			coreMu.Lock()
			if coreInstance == c {
				c.Close()
				coreInstance = nil
				coreImageSum = ""
			}
			coreMu.Unlock()
			return nil, err
		}
		if len(out) != 20 {
			return nil, fmt.Errorf("%w: digest-size", ErrProtocol)
		}
		// python core() 取前 16 字节。
		return out[:16], nil
	}
}

var _ = strings.TrimSpace
var _ = strconv.Itoa
