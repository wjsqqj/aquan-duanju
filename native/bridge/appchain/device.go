package appchain

// 设备存储：进程内缓存 + 与 SDK 档案同目录的 aquan_appchain_device.json 持久化。
// 复用优先（每次换新设备=永远零信任，容易撞风控限额）；只有显式轮换才重注册。

import (
	"context"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"sync"
)

var (
	deviceMu  sync.Mutex
	memDevice *device
)

// devicePath 由 SDK 档案路径推导本包设备文件；空 profilePath 返回空（不落盘）。
func devicePath(profilePath string) string {
	if profilePath == "" {
		return ""
	}
	return filepath.Join(filepath.Dir(profilePath), "aquan_appchain_device.json")
}

// currentDevice 返回可用的匿名设备：内存缓存 → 持久化文件 → 现场注册。
// fresh=true 表示本次调用刚注册（调用方须等待跨集群同步窗口）。
func currentDevice(ctx context.Context, client *http.Client, profilePath string) (*device, bool, error) {
	deviceMu.Lock()
	defer deviceMu.Unlock()
	if memDevice != nil {
		return memDevice, false, nil
	}
	if path := devicePath(profilePath); path != "" {
		if raw, err := os.ReadFile(path); err == nil {
			var d device
			if json.Unmarshal(raw, &d) == nil && d.DeviceID != "" && d.InstallID != "" && d.CDID != "" {
				memDevice = &d
				return memDevice, false, nil
			}
		}
	}
	d, err := registerDevice(ctx, client)
	if err != nil {
		return nil, false, err
	}
	memDevice = d
	persistDeviceLocked(profilePath, d)
	return memDevice, true, nil
}

// rotateDevice 强制重注册并替换缓存与落盘（空响应轮换路径，节流由调用方负责）。
func rotateDevice(ctx context.Context, client *http.Client, profilePath string) (*device, error) {
	deviceMu.Lock()
	defer deviceMu.Unlock()
	d, err := registerDevice(ctx, client)
	if err != nil {
		return nil, err
	}
	memDevice = d
	persistDeviceLocked(profilePath, d)
	return d, nil
}

// ResetDevice 丢弃缓存设备（诊断入口用；下次 Resolve 现场重注册）。
func ResetDevice(profilePath string) {
	deviceMu.Lock()
	defer deviceMu.Unlock()
	memDevice = nil
	if path := devicePath(profilePath); path != "" {
		_ = os.Remove(path)
	}
}

func persistDeviceLocked(profilePath string, d *device) {
	path := devicePath(profilePath)
	if path == "" || d == nil {
		return
	}
	raw, err := json.MarshalIndent(d, "", "  ")
	if err != nil {
		return
	}
	// 落盘失败只影响下次复用，不阻断本次取流。
	_ = os.WriteFile(path, raw, 0o600)
}
