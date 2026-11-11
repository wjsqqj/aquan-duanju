package sdk

import (
	"context"
	"errors"
	"fmt"

	"github.com/beilunyang/openhongguo/internal/drm"
	"github.com/beilunyang/openhongguo/internal/protocol"
	"github.com/beilunyang/openhongguo/internal/protocol/sign"
	"github.com/beilunyang/openhongguo/sdk/model"
)

// PlaybackOptions 预留给码流规格或接口的选择。
// 第二阶段按服务端下发的原样解析模型，由调用方挑选流。
type PlaybackOptions struct{}

// ResolvePlayback 加载一集的播放模型：各清晰度的地址、编码和码率。
//
// 请求形态跟随官方 6.7 的两段链路，两段都用真实的 551 Argus / Ladon 签名
// （占位签名会被上游静默丢弃，返回 HTTP 200 + 0 字节）：
//  1. GET /reading/bookapi/video_tab/multi_video_model/v1/：无正文，73932 版本；
//  2. 若第 1 段拿到空 body，改走 6.6 的 POST
//     /novel/player/multi_video_model/v1/（gzip 批量体，74332 版本）。
//
// 两段都拿不到模型时返回 ErrPlaybackUnavailable：这只说明「取流接口没给数据」，
// 不宣称设备配额用尽（上游返回空 body 的原因未公开）。
// 受保护的模型会和 ErrDRMProtected 一起返回；把它传给 ContentKey 取得密钥。
func (c *Client) ResolvePlayback(ctx context.Context, episodeID string, _ PlaybackOptions) (*model.Playback, error) {
	return withFreshDevice(ctx, c, true, func(ctx context.Context) (*model.Playback, error) {
		if !validID(episodeID) {
			return nil, fmt.Errorf("invalid episode ID")
		}
		p, err := c.ensureSearchGuest(ctx)
		if err != nil {
			return nil, err
		}
		playback, getErr := c.playbackVideoTab(ctx, p, episodeID)
		if getErr == nil {
			return playbackOrDRM(playback)
		}
		if !errors.Is(getErr, ErrAnonymousLimited) {
			return nil, getErr
		}
		playback, postErr := c.playbackPost(ctx, p, episodeID)
		if postErr == nil {
			return playbackOrDRM(playback)
		}
		if errors.Is(postErr, ErrAnonymousLimited) || errors.Is(postErr, ErrPlaybackUnavailable) {
			return nil, fmt.Errorf("%w: %v", ErrPlaybackUnavailable, postErr)
		}
		return nil, postErr
	})
}

// ParsePlaybackJSON 解析一次取流响应（纯函数，不发请求）。调用方拿到的
// raw 可以是 video_model / multi_video_model / video_tab 三种外层之一；
// 主要用于离线诊断与契约测试。
func ParsePlaybackJSON(raw []byte, episodeID string) (*model.Playback, error) {
	return protocol.ParsePlayback(raw, episodeID)
}

func playbackOrDRM(playback *model.Playback) (*model.Playback, error) {
	if playback != nil && playback.Protected {
		return playback, ErrDRMProtected
	}
	return playback, nil
}

// playbackPost 是上游 6.6 的批量取流：body 以 gzip 发送，签名与 x-ss-stub
// 都对压缩后的同一份字节计算。
func (c *Client) playbackPost(ctx context.Context, p *DeviceProfile, episodeID string) (*model.Playback, error) {
	body, err := protocol.PlaybackBody(episodeID)
	if err != nil {
		return nil, err
	}
	gz := gzipBytes(body)
	ticket := c.clock().UnixMilli()
	rawQuery, headers := sign.SignPlaybackPOST(protocol.PathMultiPlayback, playbackPairs(p), ticket, p.DeviceID, protocol.PlaybackVersionName, gz, nil)
	headers["Content-Encoding"] = "gzip"
	headers["Connection"] = "close"
	hdr := anonymousHeaders(c, p, ticket, headers)
	hdr["User-Agent"] = protocol.PlaybackUserAgent
	hdr["x-tt-store-region"] = "cn"
	hdr["x-tt-store-region-src"] = "did"
	raw, _, err := c.doRaw(ctx, "POST", c.apiOrigin+protocol.PathMultiPlayback+"?"+rawQuery, hdr, gz)
	if err != nil {
		return nil, err
	}
	return protocol.ParsePlayback(raw, episodeID)
}

// playbackVideoTab 是官方 App 的签名 GET：无正文，签名不带 x-ss-stub。
func (c *Client) playbackVideoTab(ctx context.Context, p *DeviceProfile, episodeID string) (*model.Playback, error) {
	ticket := c.clock().UnixMilli()
	rawQuery, headers := sign.SignPlaybackGET(protocol.PathVideoTabPlayback, videoTabPairs(p, episodeID), ticket, p.DeviceID, protocol.VideoTabVersionName, nil)
	headers["x-tt-request-tag"] = "t=0;n=0"
	hdr := anonymousHeaders(c, p, ticket, headers)
	hdr["User-Agent"] = protocol.VideoTabUserAgent
	hdr["x-tt-store-region"] = "cn"
	hdr["x-tt-store-region-src"] = "did"
	raw, _, err := c.doRaw(ctx, "GET", c.apiOrigin+protocol.PathVideoTabPlayback+"?"+rawQuery, hdr, nil)
	if err != nil {
		return nil, err
	}
	return protocol.ParsePlayback(raw, episodeID)
}

// playbackDevicePairs 是取流 query 的设备段：25 个键按官方 App 的书写顺序，
// 版本三件套（version_code / manifest_version_code / update_version_code /
// pv_player）与 UA、x-medusa 内的版本必须同为 GET 或 POST 的档位。
func playbackDevicePairs(versionCode, versionName string) [][2]string {
	return [][2]string{
		{"ac", "wifi"},
		{"channel", "update_64"},
		{"aid", protocol.AID},
		{"app_name", protocol.AppName},
		{"version_code", versionCode},
		{"version_name", versionName},
		{"device_platform", protocol.DevicePlatform},
		{"os", "android"},
		{"ssmix", "a"},
		{"device_type", "25053RT47C"},
		{"device_brand", "Redmi"},
		{"language", "zh"},
		{"os_api", "36"},
		{"os_version", "16"},
		{"manifest_version_code", versionCode},
		{"resolution", "1280*2772"},
		{"dpi", "520"},
		{"update_version_code", versionCode},
		{"host_abi", "arm64-v8a"},
		{"dragon_device_type", "phone"},
		{"pv_player", versionCode},
		{"compliance_status", "0"},
		{"need_personal_recommend", "1"},
		{"player_so_load", "1"},
		{"is_android_pad_screen", "0"},
	}
}

// playbackIdentityPairs 是注册得到的身份段。
func playbackIdentityPairs(p *DeviceProfile) [][2]string {
	return [][2]string{
		{"device_id", p.DeviceID},
		{"iid", p.InstallID},
		{"cdid", p.CDID},
	}
}

// playbackPairs 是 POST 取流的 query：设备段（74332）+ 身份段。
func playbackPairs(p *DeviceProfile) [][2]string {
	pairs := playbackDevicePairs(protocol.PlaybackVersionCode, protocol.PlaybackVersionName)
	return append(pairs, playbackIdentityPairs(p)...)
}

// videoTabPairs 是 GET 取流的 query：设备段（73932）+ 身份段 + 业务段；
// 末尾的 ts / _rticket 由签名器追加。
func videoTabPairs(p *DeviceProfile, episodeID string) [][2]string {
	pairs := playbackDevicePairs(protocol.VideoTabVersionCode, protocol.VideoTabVersionName)
	pairs = append(pairs, playbackIdentityPairs(p)...)
	return append(pairs,
		[2]string{"video_id", episodeID},
		[2]string{"video_id_type", "0"},
		[2]string{"device_level", "1"},
		[2]string{"need_all_video_definition", "1"},
		[2]string{"need_mp4_align", "0"},
		[2]string{"use_os_player", "0"},
		[2]string{"video_platform", "1024"},
		[2]string{"source", "0"},
		[2]string{"from_video_id", ""},
	)
}

// ContentKey 从播放模型算出加密分集的内容密钥。
// 播放模型就是 ResolvePlayback 连同 ErrDRMProtected 一起返回的那个。这是纯本地计算：
// 按官方播放器的方式从模型的 KeyMaterial 解包出密钥，不再发出任何请求。
// 模型的所有流共用这个密钥（同一集的每种清晰度都带有相同的 spade_a 和 kid，
// 2026-10-24 观察）。
//
// 未加密的模型返回 ErrNotProtected；当前版本无法解包的密钥材料返回
// ErrDRMProtected。
func ContentKey(pb *model.Playback) (model.ContentKey, error) {
	if pb == nil {
		return model.ContentKey{}, fmt.Errorf("playback model is missing")
	}
	if !pb.Protected {
		return model.ContentKey{}, ErrNotProtected
	}
	k, err := drm.Derive(pb.KeyMaterial)
	if err != nil {
		return model.ContentKey{}, fmt.Errorf("%w: %v", ErrDRMProtected, err)
	}
	return model.ContentKey{Hex: k.Hex, Version: k.Version}, nil
}
