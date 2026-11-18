package sdk

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"time"

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

// ResolvePlaybackV5 用纯 Go 的 V5 签名（x-khronos + x-helios + x-medusa）
// 请求 7.4.3.32 客户端的取流端点，是 ResolvePlayback 之外的独立通道，
// 供对照验证使用；不改变 ResolvePlayback 的现有链路。
//
// 受保护的模型与 ErrDRMProtected 一起返回，可继续交给 ContentKey。
func (c *Client) ResolvePlaybackV5(ctx context.Context, episodeID string) (*model.Playback, error) {
	if !validID(episodeID) {
		return nil, fmt.Errorf("invalid episode ID")
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	body, err := protocol.PlaybackV5Body(episodeID)
	if err != nil {
		return nil, err
	}
	return withFreshDevice(ctx, c, true, func(ctx context.Context) (*model.Playback, error) {
		p, err := c.ensureSearchGuest(ctx)
		if err != nil {
			return nil, err
		}
		var raw []byte
		for attempt := 0; attempt < 2; attempt++ {
			if err = ctx.Err(); err != nil {
				return nil, err
			}
			var query string
			var headers map[string]string
			query, headers, err = c.playbackSigner.Sign(protocol.PlaybackV5Pairs(c.identity(p)), c.clock().UnixMilli(), body, nil)
			if err != nil {
				return nil, err
			}
			headers = anonymousHeaders(c, p, c.clock().UnixMilli(), headers)
			headers["User-Agent"] = protocol.PlaybackV5UserAgent(c.deviceOf(p))
			headers["Accept"] = "application/json; charset=utf-8,application/x-protobuf"
			headers["x-xs-from-web"] = "0"
			headers["Content-Encoding"] = "gzip"
			raw, _, err = c.doRaw(ctx, "POST", c.apiOrigin+protocol.PathPlaybackV5+"?"+query, headers, body)
			if ctxErr := ctx.Err(); ctxErr != nil {
				return nil, ctxErr
			}
			if !errors.Is(err, ErrAnonymousLimited) || attempt == 1 {
				break
			}
			if err = sleepContext(ctx, 300*time.Millisecond); err != nil {
				return nil, err
			}
		}
		if err != nil {
			return nil, err
		}
		playback, err := protocol.ParsePlayback(raw, episodeID)
		if err != nil {
			return nil, err
		}
		if playback.Protected {
			return playback, ErrDRMProtected
		}
		return playback, nil
	})
}

// ParsePlaybackJSON 解析一次取流响应（纯函数，不发请求）。调用方拿到的
// raw 可以是 video_model / multi_video_model / video_tab 三种外层之一；
// 主要用于离线诊断与契约测试。
func ParsePlaybackJSON(raw []byte, episodeID string) (*model.Playback, error) {
	return protocol.ParsePlayback(raw, episodeID)
}

// ResolvePlaybackRaw 是 ResolvePlayback 的诊断变体：链路与语义一致
// （ErrDRMProtected 时模型照样返回），但把成功那一段的原始响应字节一并
// 带回——解析层只挑字段，原始 JSON 里可能有被丢掉的编码/清晰度变体，
// 供 cmd/diag 离线分析服务端到底下发了什么。
func (c *Client) ResolvePlaybackRaw(ctx context.Context, episodeID string) (raw []byte, pb *model.Playback, err error) {
	pb, err = withFreshDevice(ctx, c, true, func(ctx context.Context) (*model.Playback, error) {
		if !validID(episodeID) {
			return nil, fmt.Errorf("invalid episode ID")
		}
		p, err := c.ensureSearchGuest(ctx)
		if err != nil {
			return nil, err
		}
		getRaw, playback, getErr := c.playbackVideoTabRaw(ctx, p, episodeID)
		if getErr == nil {
			raw = getRaw
			return playbackOrDRM(playback)
		}
		if !errors.Is(getErr, ErrAnonymousLimited) {
			return nil, getErr
		}
		postRaw, playback2, postErr := c.playbackPostRaw(ctx, p, episodeID)
		if postErr == nil {
			raw = postRaw
			return playbackOrDRM(playback2)
		}
		if errors.Is(postErr, ErrAnonymousLimited) || errors.Is(postErr, ErrPlaybackUnavailable) {
			return nil, fmt.Errorf("%w: %v", ErrPlaybackUnavailable, postErr)
		}
		return nil, postErr
	})
	return raw, pb, err
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
	_, pb, err := c.playbackPostRaw(ctx, p, episodeID)
	return pb, err
}

// playbackPostRaw 是 playbackPost 的诊断变体：额外带回原始响应字节。
func (c *Client) playbackPostRaw(ctx context.Context, p *DeviceProfile, episodeID string) ([]byte, *model.Playback, error) {
	return c.playbackPostWithVersion(ctx, p, episodeID, protocol.PlaybackVersionCode, protocol.PlaybackVersionName)
}

// playbackPostWithVersion 是 playbackPost 的档位参数化变体：版本三件套与
// UA 按给定档位请求（编码协商降档用）；诊断变体带回原始响应字节。
func (c *Client) playbackPostWithVersion(ctx context.Context, p *DeviceProfile, episodeID, versionCode, versionName string) ([]byte, *model.Playback, error) {
	body, err := protocol.PlaybackBody(episodeID)
	if err != nil {
		return nil, nil, err
	}
	gz := gzipBytes(body)
	ticket := c.clock().UnixMilli()
	rawQuery, headers := sign.SignPlaybackPOST(protocol.PathMultiPlayback, playbackDevicePairs(versionCode, versionName), ticket, p.DeviceID, versionName, gz, nil)
	headers["Content-Encoding"] = "gzip"
	headers["Connection"] = "close"
	hdr := anonymousHeaders(c, p, ticket, headers)
	hdr["User-Agent"] = fmt.Sprintf("%s/%s (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)",
		protocol.Package, versionCode)
	hdr["x-tt-store-region"] = "cn"
	hdr["x-tt-store-region-src"] = "did"
	raw, _, err := c.doRaw(ctx, "POST", c.apiOrigin+protocol.PathMultiPlayback+"?"+rawQuery, hdr, gz)
	if err != nil {
		return nil, nil, err
	}
	pb, err := protocol.ParsePlayback(raw, episodeID)
	return raw, pb, err
}

// playbackVideoTab 是官方 App 的签名 GET：无正文，签名不带 x-ss-stub。
func (c *Client) playbackVideoTab(ctx context.Context, p *DeviceProfile, episodeID string) (*model.Playback, error) {
	_, pb, err := c.playbackVideoTabRaw(ctx, p, episodeID)
	return pb, err
}

// LegacyPlaybackVersionCode / LegacyPlaybackVersionName 是「兼容转码档位」：
// 服务端按客户端版本下发编码——当前版本（73932+）对部分新剧集只给 bytevc2
//（字节自研编码，开源内核无解码器），而 6.0.1 档位会返回 bytevc1（HEVC，
// 可正常播放）。2026-11-14 对固定失效集实测：73932/65000 → bytevc2，
// 60100 → bytevc1；探测链路见 sdk.PlaybackProbe。
const (
	LegacyPlaybackVersionCode = "60100"
	LegacyPlaybackVersionName = "6.0.1.0"
)

// ResolvePlaybackWithVersion 是 ResolvePlayback 的版本档位变体：video_tab
// GET 的版本三件套与 UA 全部按给定档位请求（取流链路不带 x-medusa，签名
// 覆盖 query，档位一致即可通过）。其余语义与 ResolvePlayback 一致——
// 包括双段链路：GET 空响应（ErrAnonymousLimited，风控间歇性下发）时，
// 按同一档位走 POST multi 兜底，两段都失败才报错。
func (c *Client) ResolvePlaybackWithVersion(ctx context.Context, episodeID, versionCode, versionName string) (*model.Playback, error) {
	return withFreshDevice(ctx, c, true, func(ctx context.Context) (*model.Playback, error) {
		if !validID(episodeID) {
			return nil, fmt.Errorf("invalid episode ID")
		}
		p, err := c.ensureSearchGuest(ctx)
		if err != nil {
			return nil, err
		}
		getRaw, playback, getErr := c.playbackVideoTabWithVersion(ctx, p, episodeID, versionCode, versionName)
		if getErr == nil {
			_ = getRaw
			return playbackOrDRM(playback)
		}
		if !errors.Is(getErr, ErrAnonymousLimited) {
			return nil, getErr
		}
		_, playback2, postErr := c.playbackPostWithVersion(ctx, p, episodeID, versionCode, versionName)
		if postErr == nil {
			return playbackOrDRM(playback2)
		}
		if errors.Is(postErr, ErrAnonymousLimited) || errors.Is(postErr, ErrPlaybackUnavailable) {
			return nil, fmt.Errorf("%w: %v", ErrPlaybackUnavailable, postErr)
		}
		return nil, postErr
	})
}

// playbackVideoTabRaw 是 playbackVideoTab 的诊断变体：额外带回原始响应字节。
func (c *Client) playbackVideoTabRaw(ctx context.Context, p *DeviceProfile, episodeID string) ([]byte, *model.Playback, error) {
	return c.playbackVideoTabWithVersion(ctx, p, episodeID, protocol.VideoTabVersionCode, protocol.VideoTabVersionName)
}

// playbackVideoTabWithVersion 是 playbackVideoTab 的档位参数化变体。
func (c *Client) playbackVideoTabWithVersion(ctx context.Context, p *DeviceProfile, episodeID, versionCode, versionName string) ([]byte, *model.Playback, error) {
	ticket := c.clock().UnixMilli()
	rawQuery, headers := sign.SignPlaybackGET(protocol.PathVideoTabPlayback, videoTabPairsWithVersion(p, episodeID, versionCode, versionName), ticket, p.DeviceID, versionName, nil)
	headers["x-tt-request-tag"] = "t=0;n=0"
	hdr := anonymousHeaders(c, p, ticket, headers)
	hdr["User-Agent"] = fmt.Sprintf("%s/%s (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)",
		protocol.Package, versionCode)
	hdr["x-tt-store-region"] = "cn"
	hdr["x-tt-store-region-src"] = "did"
	raw, _, err := c.doRaw(ctx, "GET", c.apiOrigin+protocol.PathVideoTabPlayback+"?"+rawQuery, hdr, nil)
	if err != nil {
		return nil, nil, err
	}
	pb, err := protocol.ParsePlayback(raw, episodeID)
	return raw, pb, err
}

// PlaybackProbe 是诊断专用：以给定版本档位与额外 query 参数请求 video_tab
// 取流，返回各流的 codec_type 集合。用于编码协商实验（版本降级 / 参数探测），
// 不进正常播放链路。签名覆盖全部 query 参数，探测参数合法参与签名。
func (c *Client) PlaybackProbe(ctx context.Context, episodeID string, versionCode, versionName string, extra [][2]string) ([]string, error) {
	return withFreshDevice(ctx, c, true, func(ctx context.Context) ([]string, error) {
		p, err := c.ensureSearchGuest(ctx)
		if err != nil {
			return nil, err
		}
		// 末尾的 ts / _rticket 由签名器追加；探测参数合法参与签名。
		pairs := videoTabPairsWithVersion(p, episodeID, versionCode, versionName)
		pairs = append(pairs, extra...)
		ticket := c.clock().UnixMilli()
		rawQuery, headers := sign.SignPlaybackGET(protocol.PathVideoTabPlayback, pairs, ticket, p.DeviceID, versionName, nil)
		headers["x-tt-request-tag"] = "t=0;n=0"
		hdr := anonymousHeaders(c, p, ticket, headers)
		hdr["User-Agent"] = fmt.Sprintf("%s/%s (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)",
			protocol.Package, versionCode)
		hdr["x-tt-store-region"] = "cn"
		hdr["x-tt-store-region-src"] = "did"
		raw, _, err := c.doRaw(ctx, "GET", c.apiOrigin+protocol.PathVideoTabPlayback+"?"+rawQuery, hdr, nil)
		if err != nil {
			return nil, err
		}
		pb, err := protocol.ParsePlayback(raw, episodeID)
		if err != nil {
			return nil, err
		}
		codecs := map[string]bool{}
		for _, s := range pb.Streams {
			codecs[s.Codec] = true
		}
		out := make([]string, 0, len(codecs))
		for k := range codecs {
			out = append(out, k)
		}
		sort.Strings(out)
		return out, nil
	})
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
	return videoTabPairsWithVersion(p, episodeID, protocol.VideoTabVersionCode, protocol.VideoTabVersionName)
}

// videoTabPairsWithVersion 是 videoTabPairs 的档位参数化变体。
func videoTabPairsWithVersion(p *DeviceProfile, episodeID, versionCode, versionName string) [][2]string {
	pairs := playbackDevicePairs(versionCode, versionName)
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
