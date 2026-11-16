// Package appchain 实现 App 匿名取流兜底链路（任务 11-16 方案 A 后半，2026-11-17）。
//
// 背景：官网 web 通道对游客只放 accessible_episode_cnt（按剧配置，第 6 集起
// 403）。App 匿名设备链路是唯一的「全集匿名」路径，但 2026-11-10 起服务端多轮
// 收紧：argus/ladon 真验（11-10，社区 11-11 修复）、multi_video_model/v1 停服
// （11-11，现行端点 video_model/v1 + multi_video_model/player/v1）、11-14~16
// 生态性空响应（zfdang/hongguo-open-player #105 仍 open）。
//
// 本包按 2026-11-16 公开活配方复刻（证据：qist/tvbox py/红果短剧.py、
// zfdang/hongguo-open-player src/server/native/{app-source,argus,playback-device}.js，
// 详见任务 research-guest-wall-ep6.md）：
//   - lf 加密设备注册（KDF_SALT AES-128-CBC 信封，74332 姿势）+ 会话 cookie；
//   - multi_video_model/player/v1 × 5 集群（gzip dr_scene 批量体）优先；
//   - video_model/v1 × 3 host（aid 1967 novelapp 短剧画像）降级；
//   - 五件套签名头（x-ss-req-ticket/x-khronos/x-ladon/x-argus/x-ss-stub，
//     经 vendor P8 导出），不带 gorgon/helios/medusa（11-10 对照实测多余头=空响应）；
//   - 设备持久化复用（换新设备=撞风控限额）+ 空响应节流轮换 + 新设备同步窗口。
//
// 生态故障期本链路会持续空响应（预期行为）：熔断器连续全空 2 轮后暂停 30 分钟，
// 到点自动恢复尝试——不阻塞 web 主通道（webplay），坏时零伤害，服务端放风时
// 自动获得全集。
package appchain

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"sync"
	"time"

	"github.com/beilunyang/openhongguo/sdk"
	"github.com/beilunyang/openhongguo/sdk/model"
)

// ErrUnavailable 表示匿名链路整体不可用（全集群空响应/注册失败/熔断中）。
// 调用方（core.resolvePlaybackWeb）把它丢弃并返回 web 通道原错误，保持
// WEB_LOGIN_REQUIRED 等既有文案契约。
var ErrUnavailable = errors.New("appchain: anonymous playback unavailable")

const (
	resolveBudget   = 20 * time.Second // 单次 Resolve 总预算
	requestTimeout  = 8 * time.Second  // 单请求超时
	rotateCooldown  = 10 * time.Minute // 两次重注册最小间隔（防注册风暴）
	breakerOpenFor  = 30 * time.Minute // 连续全空后的熔断时长
	breakerFailures = 2                // 触发熔断的连续全空轮数
)

// freshSyncWait 是新注册设备的跨集群同步等待（var 仅为测试可缩）。
var freshSyncWait = 1500 * time.Millisecond

// 进程级熔断与轮换节流状态（跨重启重置无妨：重新尝试的成本可控）。
var (
	stateMu      sync.Mutex
	failStreak   int
	openUntil    time.Time
	lastRotateAt time.Time
)

func breakerOpen() bool {
	stateMu.Lock()
	defer stateMu.Unlock()
	return time.Now().Before(openUntil)
}

func noteFailure() {
	stateMu.Lock()
	defer stateMu.Unlock()
	failStreak++
	if failStreak >= breakerFailures {
		openUntil = time.Now().Add(breakerOpenFor)
	}
}

func noteSuccess() {
	stateMu.Lock()
	defer stateMu.Unlock()
	failStreak = 0
	openUntil = time.Time{}
}

func rotateAllowed() bool {
	stateMu.Lock()
	defer stateMu.Unlock()
	return time.Now().Sub(lastRotateAt) >= rotateCooldown
}

func noteRotate() {
	stateMu.Lock()
	defer stateMu.Unlock()
	lastRotateAt = time.Now()
}

// Resolve 用 App 匿名链路解析一集的播放模型。
// profilePath 是 SDK 设备档案路径（本包设备文件落同目录 aquan_appchain_device.json；
// 空串=仅进程内缓存，测试/diag 用）。成功返回模型与内容密钥（明文模型密钥为空、
// 无错误）；派生密钥失败时返回模型 + 错误（core 层写 ContentKeyError，与 webplay
// 语义一致）；链路整体不可用返回 ErrUnavailable。
func Resolve(ctx context.Context, client *http.Client, profilePath, episodeID string) (*model.Playback, model.ContentKey, error) {
	if !validID(episodeID) {
		return nil, model.ContentKey{}, fmt.Errorf("appchain: invalid episode ID")
	}
	if breakerOpen() {
		return nil, model.ContentKey{}, fmt.Errorf("%w: circuit open (recent all-empty)", ErrUnavailable)
	}
	if client == nil {
		client = http.DefaultClient
	}
	if ctx == nil {
		ctx = context.Background()
	}
	var cancel context.CancelFunc
	ctx, cancel = context.WithTimeout(ctx, resolveBudget)
	defer cancel()

	dev, fresh, derr := currentDevice(ctx, client, profilePath)
	if derr != nil {
		noteFailure()
		return nil, model.ContentKey{}, fmt.Errorf("%w: %v", ErrUnavailable, derr)
	}
	if fresh {
		// 新注册设备跨集群同步窗口（zfdang 实测：注册后立刻打播放会空）。
		sleepCtx(ctx, freshSyncWait)
	}
	pb, perr := resolveWithDevice(ctx, client, dev, episodeID)
	if perr == nil {
		noteSuccess()
		return finalizeKey(pb)
	}
	// 空响应轮换：重注册一台设备再试一轮（节流，防注册风暴）。
	if rotateAllowed() {
		noteRotate()
		if dev2, rerr := rotateDevice(ctx, client, profilePath); rerr == nil {
			sleepCtx(ctx, freshSyncWait)
			if pb2, err2 := resolveWithDevice(ctx, client, dev2, episodeID); err2 == nil {
				noteSuccess()
				return finalizeKey(pb2)
			}
		}
	}
	noteFailure()
	return nil, model.ContentKey{}, fmt.Errorf("%w: %v", ErrUnavailable, perr)
}

// finalizeKey 从播放模型派生内容密钥；明文模型（ErrNotProtected）返回空密钥
// 且不算错误；真实派生失败返回模型+错误，由调用方写 ContentKeyError。
func finalizeKey(pb *model.Playback) (*model.Playback, model.ContentKey, error) {
	key, kerr := sdk.ContentKey(pb)
	if errors.Is(kerr, sdk.ErrNotProtected) {
		return pb, model.ContentKey{}, nil
	}
	if kerr != nil {
		return pb, model.ContentKey{}, kerr
	}
	return pb, key, nil
}

func sleepCtx(ctx context.Context, d time.Duration) {
	if ctx.Err() != nil {
		return
	}
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
	case <-t.C:
	}
}

func validID(s string) bool {
	if len(s) < 1 || len(s) > 30 {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}
