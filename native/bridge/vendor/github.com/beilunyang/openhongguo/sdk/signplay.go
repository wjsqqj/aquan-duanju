package sdk

// P8（2026-11-17）：经 sdk 包再导出 Argus/Ladon 最小签名面（算法在
// internal/protocol/sign/export_playback.go，Go 的 internal 规则不允许
// aquan-core/* 直接导入该包，但同模块的 sdk 包可以）。见 vendor-patches.md P8。
//
// 用途：appchain 包按 2026-11 现行活配方组装五件套签名头（仅 x-ss-req-ticket/
// x-khronos/x-ladon/x-argus/x-ss-stub，不带 gorgon/helios/medusa——qist/tvbox
// 2026-11-10 同机对照实测多余头=播放接口空响应）。不要用于其他端点。

import "github.com/beilunyang/openhongguo/internal/protocol/sign"

func PlaybackArgus(query string, bodyMD5 [16]byte, ts, nonce uint32, aid, deviceID, installID string) string {
	return sign.PlaybackArgus(query, bodyMD5, ts, nonce, aid, deviceID, installID)
}

func PlaybackLadon(ts, nonce uint32, aid string) string {
	return sign.PlaybackLadon(ts, nonce, aid)
}
