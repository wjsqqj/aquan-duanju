//go:build !cgo

package hongguov5

import "errors"

// digestcore_nocgo.go — CGO_ENABLED=0（aquan-cli 纯 Go 构建）下摘要核心不可用；
// resolver 报 ErrNativeUnavailable → core 层回落 Python sidecar（桌面端）。

type sdkDigestCore struct{}

func newSDKDigestCore(image []byte) (*sdkDigestCore, error) {
	return nil, errNativeUnavailable
}

func (c *sdkDigestCore) digest(payload []byte, selector int, seconds uint32) ([]byte, error) {
	return nil, errNativeUnavailable
}

func (c *sdkDigestCore) Close() {}

var errNativeUnavailable = errors.New("hongguov5: native digest unavailable (no cgo)")
