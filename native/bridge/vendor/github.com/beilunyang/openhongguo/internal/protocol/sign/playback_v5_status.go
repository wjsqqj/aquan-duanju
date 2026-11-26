package sign

import (
	"os"
	"strconv"
)

// v5DeviceStatus 是 x-medusa 明文字段 21（客户端设备状态）。2026-11-23 起
// 服务端会拒绝模拟器状态值 377（HTTP 200 + 0 字节），实测可用值 312 / 369。
// 默认取 312（与本项目旧 medusa 实现一致，且 2026-11-26 单集取流实网验证通过）；
// 诊断时可用环境变量 HONGGUO_V5_STATUS 覆盖，便于服务端再次变更时逐值验证。
func v5DeviceStatus() int {
	if raw := os.Getenv("HONGGUO_V5_STATUS"); raw != "" {
		if v, err := strconv.Atoi(raw); err == nil && v > 0 {
			return v
		}
	}
	return 312
}
