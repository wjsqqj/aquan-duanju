package sign

// P8（2026-11-17）：导出真 Argus/Ladon 的最小签名面，供 appchain 包复刻
// 2026-11 现行 App 匿名取流配方。为什么必须放 vendor：签名实现在
// internal/protocol/sign，Go 的 internal 规则不允许 aquan-core/* 导入
// （与 P2 同理）。
//
// 为什么不直接用导出的 SignPlaybackPOST：它按 PR#7 形状组装头集合（x-gorgon
// /x-helios/x-tt-dt 等六神全家桶减 medusa）。2026-11-10 起播放接口的风控
// 对多余签名头敏感——qist/tvbox 同机对照实测（海阔五件套能播、六神全家桶
// 空响应），现行活配方只带五件套（x-ss-req-ticket/x-khronos/x-ladon/x-argus/
// x-ss-stub）。这里只暴露算法本身，头集合由调用方按配方组装。
//
// 上游版本：openhongguo v0.2.0（本文件为本地新增，go mod vendor 会覆盖丢失）。
// golden vectors 与 playback.go 共用（TestArgusGoldenVectors* / TestLadonGoldenVectors）。

// PlaybackArgus 构造 x-argus：query 是实际发送的完整 query 串（逐字节参与
// 签名）；bodyMD5 是请求体原始 MD5（无体传零值）；aid/deviceID/installID 进
// Argus bean（现行配方 installID 传查询串里的 iid 或空串，与配方保持一致）。
// 导出名供 sdk 包 signplay.go 再导出（internal 不可被外部模块直接导入）。
func PlaybackArgus(query string, bodyMD5 [16]byte, ts, nonce uint32, aid, deviceID, installID string) string {
	return argusHeader(query, bodyMD5, ts, nonce, aid, deviceID, installID)
}

// PlaybackLadon 构造 x-ladon：ts 为 x-khronos 秒，nonce 为 32 位随机数，
// aid 与 license（1611921764）进 Ladon 信封。由 sdk 包 signplay.go 再导出。
func PlaybackLadon(ts, nonce uint32, aid string) string {
	return ladonHeader(ts, nonce, aid)
}
