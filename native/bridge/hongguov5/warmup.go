package hongguov5

// warmup.go — V5 会话预热：只做「注册设备 → 素材就绪 → 交换 mssdk 令牌」，
// 不请求播放接口。
//
// 为什么单独做：V5 取流的热启动约 6 秒，冷启动还要加上注册、官方素材
// 下载/校验与令牌交换。这些都不依赖具体分集，可以提前做掉；而播放模型
// 本身受「每台匿名设备基本只给一次」的配额限制，**绝不能**在预热时请求。

import (
	"fmt"
	"os"
	"path/filepath"
)

// Warmup 预热 V5 通道，幂等：设备/素材/会话都已就绪时只做本地校验并快速返回。
//
// 不发送播放请求，因此不消耗服务端的播放模型配额。
func Warmup(dataDir string) error {
	// 与 Resolve 共用运行时回滚开关：强制回落 sidecar 时预热也无意义。
	if os.Getenv("HONGGUO_V5_NATIVE") == "0" {
		return ErrNativeUnavailable
	}
	abs, err := filepath.Abs(dataDir)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(abs, 0o755); err != nil {
		return err
	}
	ent := cryptoEntropy()
	state, err := ensureDevice(abs, ent)
	if err != nil {
		return fmt.Errorf("%w: register: %v", ErrProtocol, err)
	}
	assets, err := loadAssets(abs, true)
	if err != nil {
		return fmt.Errorf("%w: assets: %v", ErrProtocol, err)
	}
	signingKey, exchangeKey, err := decodeAppConfig(assets["sdk-app-config.encoded"])
	if err != nil {
		return fmt.Errorf("%w: config: %v", ErrProtocol, err)
	}
	image, unavailable, err := readSDKImage(assets["libmetasec_ml.so"])
	if err != nil {
		return err
	}
	materials := map[string][]byte{
		"signing_key":  signingKey,
		"exchange_key": exchangeKey,
	}
	engine, err := acquireDigestCore(assets["libmetasec_ml.so"])
	if err != nil {
		return fmt.Errorf("%w: %v", ErrNativeUnavailable, err)
	}
	coreFn := digestForResolver(engine)
	if _, err := ensureSession(abs, state.Params, state.Cookies,
		materials, image, unavailable, coreFn, ent); err != nil {
		return fmt.Errorf("%w: exchange: %v", ErrProtocol, err)
	}
	return nil
}
