package sdk

// 本文件是本仓库的 vendor 补丁（见 .trellis/spec/backend/vendor-patches.md P12）。
//
// 背景：2026-11-23 起，原先唯一可用的 V5 POST（multi_video_model/player/v1）
// 也开始对第三方客户端返回 200 + 空 body；社区（hongguo-android-cast 11-24、
// hongguoTV 11-26）实测仍有应答的形态是：
//   - 无正文 GET /reading/bookapi/video_tab/multi_video_model/v1/，同一套
//     x-khronos / x-helios / x-medusa 三头；
//   - 单集 POST /novel/player/video_model/v1/（video_id + biz_param），
//     部分主机/档位有应答。
//
// 这些形态无法由 sdk 之外的包拼出来：签名器在 internal/protocol/sign，
// 身份在 *Client 内。因此以「新增可选通道」的形式放在 vendor，旧链路不动。

import (
	"bytes"
	"compress/gzip"
	"context"
	"errors"
	"fmt"
	"strconv"

	"github.com/beilunyang/openhongguo/internal/protocol"
	"github.com/beilunyang/openhongguo/sdk/model"
)

type v5ShapeResult struct {
	raw []byte
	pb  *model.Playback
}

// V5Shape 是一次 V5 取流请求的形态。
type V5Shape struct {
	// Name 只用于诊断输出。
	Name string
	// Method 是 GET 或 POST；空值按 POST。
	Method string
	// Host 形如 https://host；空值按 APIHost。
	Host string
	// Path 是请求路径；空值按形态默认。
	Path string
	// VersionCode / VersionName 同时写进 query、UA 与 x-medusa。
	VersionCode string
	VersionName string
	// DeviceLevel 写进 biz_param（默认 1）。
	DeviceLevel int
	// VideoPlatform 写进 biz_param 与 query（默认 1024）。
	VideoPlatform int
	// Extra 是追加在 query 末尾的额外参数（编码协商等诊断用）。
	Extra [][2]string
	// PlainBody 为真时不 gzip（单集接口有明文形态）。
	PlainBody bool
	// SignEmptyBody 只对无正文 GET 有意义：真 = 用 MD5("") 参与签名，
	// 假 = 用 16 个零字节（官方 bodyless 请求的两种实现都有）。
	SignEmptyBody bool
}

// V5ShapeTabGET 是 11-23 之后社区实测仍应答的第一形态：无正文 video_tab GET。
func V5ShapeTabGET() V5Shape {
	return V5Shape{
		Name: "tab-get-v5", Method: "GET",
		Path:        protocol.PathVideoTabPlayback,
		VersionCode: protocol.PlaybackVersionCode,
		VersionName: protocol.PlaybackVersionName,
		DeviceLevel: 1,
	}
}

// V5ShapeSinglePOST 是单集 video_model POST（hongguoTV-fyworld 0.1.40 形态）。
// device_level 取 1：2026-11-26 实测 level=2 时 720p 以下下发 bytevc2（开源
// 内核解不了），level=1/4 时 5 档全 bytevc1，因此固定 1 以保证可播档位齐全。
func V5ShapeSinglePOST() V5Shape {
	return V5Shape{
		Name: "single-post-v5", Method: "POST",
		Host:        "https://reading.snssdk.com",
		Path:        protocol.PathPlayback,
		VersionCode: protocol.PlaybackVersionCode,
		VersionName: protocol.PlaybackVersionName,
		DeviceLevel: 1,
	}
}

// V5ShapeMultiPOST 是现有 V5 批量 POST（保留作对照/兜底）。
func V5ShapeMultiPOST() V5Shape {
	return V5Shape{
		Name: "multi-post-v5", Method: "POST",
		Path:        protocol.PathPlaybackV5,
		VersionCode: protocol.PlaybackVersionCode,
		VersionName: protocol.PlaybackVersionName,
		DeviceLevel: 1,
	}
}

// ResolvePlaybackV5Shape 用给定形态取一集的播放模型。返回原始响应字节，
// 便于诊断；受保护模型与 ErrDRMProtected 一起返回（与 ResolvePlayback 一致）。
func (c *Client) ResolvePlaybackV5Shape(ctx context.Context, episodeID string, shape V5Shape) ([]byte, *model.Playback, error) {
	if !validID(episodeID) {
		return nil, nil, fmt.Errorf("invalid episode ID")
	}
	if err := ctx.Err(); err != nil {
		return nil, nil, err
	}
	shape = shape.withDefaults()
	body, err := v5ShapeBody(episodeID, shape)
	if err != nil {
		return nil, nil, err
	}
	res, err := withFreshDevice(ctx, c, true, func(ctx context.Context) (v5ShapeResult, error) {
		p, perr := c.ensureSearchGuest(ctx)
		if perr != nil {
			return v5ShapeResult{}, perr
		}
		signBody := body
		if shape.Method == "GET" {
			if shape.SignEmptyBody {
				signBody = []byte{}
			} else {
				// nil → 签名器按 16 个零字节计算摘要，且不写 x-ss-stub。
				signBody = nil
			}
		}
		query, headers, serr := c.playbackSigner.Sign(v5ShapePairs(c.identity(p), episodeID, shape), c.clock().UnixMilli(), signBody, nil)
		if serr != nil {
			return v5ShapeResult{}, serr
		}
		headers["User-Agent"] = shape.userAgent(c.deviceOf(p))
		headers["Accept"] = "application/json; charset=utf-8,application/x-protobuf"
		headers["x-xs-from-web"] = "0"
		headers["x-tt-store-region"] = "cn"
		headers["x-tt-store-region-src"] = "did"
		if shape.Method == "GET" {
			headers["x-tt-request-tag"] = "t=0;n=0"
		}
		if shape.Method != "GET" {
			headers["Content-Type"] = "application/json; charset=UTF-8"
			if !shape.PlainBody {
				headers["Content-Encoding"] = "gzip"
			}
		}
		raw, _, doErr := c.doRaw(ctx, shape.Method, shape.Host+shape.Path+"?"+query, headers, body)
		if doErr != nil {
			return v5ShapeResult{raw: raw}, doErr
		}
		pb, parseErr := protocol.ParsePlayback(raw, episodeID)
		return v5ShapeResult{raw: raw, pb: pb}, parseErr
	})
	raw, playback := res.raw, res.pb
	if err != nil {
		return raw, playback, err
	}
	if playback != nil && playback.Protected {
		return raw, playback, ErrDRMProtected
	}
	return raw, playback, nil
}

func (s V5Shape) withDefaults() V5Shape {
	if s.Method == "" {
		s.Method = "POST"
	}
	if s.Host == "" {
		s.Host = "https://" + protocol.APIHost
	}
	if s.VersionCode == "" {
		s.VersionCode = protocol.PlaybackVersionCode
	}
	if s.VersionName == "" {
		s.VersionName = protocol.PlaybackVersionName
	}
	if s.DeviceLevel == 0 {
		s.DeviceLevel = 1
	}
	if s.VideoPlatform == 0 {
		s.VideoPlatform = 1024
	}
	if s.Path == "" {
		s.Path = protocol.PathPlaybackV5
	}
	if s.Name == "" {
		s.Name = s.Method + " " + s.Path
	}
	return s
}

func (s V5Shape) userAgent(d model.Device) string {
	d = d.OrDefault()
	return fmt.Sprintf("%s/%s (Linux; U; Android %s; zh_CN; %s; Build/%s; Cronet/TTNetVersion:8d40f833 2026-03-03 QuicVersion:21ac1950 2025-11-18)",
		protocol.Package, s.VersionCode, d.OSVersion, d.Model, d.Build)
}

// v5ShapePairs 采用 hongguo-android-cast 11-24 的最小 query 集：只保留
// x-medusa 明文回写的身份/设备字段与取流业务字段。顺序参与签名。
func v5ShapePairs(id protocol.SearchIdentity, episodeID string, shape V5Shape) [][2]string {
	d := id.Device.OrDefault()
	kind, pad := "phone", "0"
	if d.Pad {
		kind, pad = "pad", "1"
	}
	pairs := [][2]string{
		{"device_platform", protocol.DevicePlatform},
		{"os", "android"},
		{"ssmix", "a"},
		{"_rticket", ""},
		{"cdid", id.CDID},
		{"channel", d.Channel},
		{"aid", protocol.AID},
		{"app_name", protocol.AppName},
		{"version_code", shape.VersionCode},
		{"version_name", shape.VersionName},
		{"manifest_version_code", shape.VersionCode},
		{"update_version_code", shape.VersionCode},
		{"resolution", d.Resolution},
		{"dpi", strconv.Itoa(d.DPI)},
		{"device_type", d.Model},
		{"language", "zh"},
		{"os_api", strconv.Itoa(d.OSAPI)},
		{"os_version", d.OSVersion},
		{"ac", "wifi"},
		{"host_abi", "arm64-v8a"},
		{"dragon_device_type", kind},
		{"pv_player", shape.VersionCode},
		{"compliance_status", "0"},
		{"need_personal_recommend", "1"},
		{"player_so_load", "1"},
		{"is_android_pad_screen", pad},
		{"iid", id.InstallID},
		{"device_id", id.DeviceID},
		{"video_id", episodeID},
		{"video_id_type", "0"},
		{"device_level", strconv.Itoa(shape.DeviceLevel)},
		{"need_all_video_definition", "1"},
		{"need_mp4_align", "0"},
		{"use_os_player", "0"},
		{"video_platform", strconv.Itoa(shape.VideoPlatform)},
		{"source", "0"},
		{"from_video_id", ""},
	}
	return append(pairs, shape.Extra...)
}

// v5ShapeBody 按形态组装请求体；GET 返回 nil（无正文）。
func v5ShapeBody(episodeID string, shape V5Shape) ([]byte, error) {
	if shape.Method == "GET" {
		return nil, nil
	}
	var payload []byte
	switch shape.Path {
	case protocol.PathPlayback: // 单集 video_model
		payload = []byte(`{"video_id":"` + episodeID + `","content_type":1,"biz_param":{` +
			`"detail_page_version":0,"device_level":` + strconv.Itoa(shape.DeviceLevel) + `,` +
			`"disable_digg_stat":false,"need_all_video_definition":true,"need_mp4_align":false,` +
			`"use_os_player":false,"use_server_dns":false,"video_platform":` + strconv.Itoa(shape.VideoPlatform) + `}}`)
	default:
		payload = []byte(`{"biz_param":{"detail_page_version":0,"device_level":` + strconv.Itoa(shape.DeviceLevel) + `,` +
			`"disable_digg_stat":false,"disable_video_relate_book":false,"need_all_video_definition":true,` +
			`"need_mp4_align":false,"use_os_player":false,"use_server_dns":false,"video_platform":` + strconv.Itoa(shape.VideoPlatform) + `},` +
			`"mixed_video_id_map":{"1004":["` + episodeID + `"]},"dr_scene":"player"}`)
	}
	if shape.PlainBody {
		return payload, nil
	}
	var buf bytes.Buffer
	zw := gzip.NewWriter(&buf)
	if _, err := zw.Write(payload); err != nil {
		return nil, err
	}
	if err := zw.Close(); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// ErrV5ShapeUnavailable 预留给调用方区分「这种形态当前不可用」。
var ErrV5ShapeUnavailable = errors.New("openhongguo: v5 shape unavailable")
