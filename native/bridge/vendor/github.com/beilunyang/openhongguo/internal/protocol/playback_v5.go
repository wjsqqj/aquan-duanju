package protocol

import (
	"bytes"
	"compress/gzip"
	"fmt"
	"strconv"

	"github.com/beilunyang/openhongguo/sdk/model"
)

// PathPlaybackV5 是 7.4.3.32 客户端的 V5 取流端点（上游 v0.3.1 起）。
//
// 它与旧的 PathPlayback（/novel/player/multi_video_model/v1）不是同一个
// 端点，签名头也不同：V5 用 x-khronos + x-helios + x-medusa（有 body 时
// x-ss-stub）；旧端点在签名正确时必须去掉 x-medusa，否则返回 200 + 空 body
// （见 .trellis/spec/backend/vendor-patches.md 的 P7）。两套头不要互换。
const PathPlaybackV5 = "/novel/player/multi_video_model/player/v1"

// PlaybackV5Pairs 是 V5 取流的 query，顺序与 7.4.3.32 客户端一致。
// 空的 _rticket 标出签名器填写票据的位置：顺序参与签名，不能重排。
func PlaybackV5Pairs(id SearchIdentity) [][2]string {
	d := id.Device.OrDefault()
	kind, pad := "phone", "0"
	if d.Pad {
		kind, pad = "pad", "1"
	}
	return [][2]string{
		{"device_platform", DevicePlatform},
		{"os", "android"},
		{"ssmix", "a"},
		{"_rticket", ""},
		{"cdid", id.CDID},
		{"channel", d.Channel},
		{"aid", AID},
		{"app_name", AppName},
		{"version_code", PlaybackVersionCode},
		{"version_name", PlaybackVersionName},
		{"manifest_version_code", PlaybackVersionCode},
		{"update_version_code", PlaybackVersionCode},
		{"resolution", d.Resolution},
		{"dpi", strconv.Itoa(d.DPI)},
		{"device_type", d.Model},
		{"device_brand", d.Brand},
		{"language", "zh"},
		{"os_api", strconv.Itoa(d.OSAPI)},
		{"os_version", d.OSVersion},
		{"ac", "wifi"},
		{"host_abi", "arm64-v8a"},
		{"dragon_device_type", kind},
		{"pv_player", PlaybackVersionCode},
		{"compliance_status", "0"},
		{"need_personal_recommend", "1"},
		{"player_so_load", "1"},
		{"is_android_pad_screen", pad},
		{"iid", id.InstallID},
		{"device_id", id.DeviceID},
	}
}

// PlaybackV5Body 只压缩一次：调用方把返回的原始字节同时用于签名和发送。
//
// device_level 保持 1（与上游一致）。上游注释称 3 会让服务端把 1080p 以下
// 的码流换成 bytevc2（ffmpeg/mpv 解不了）；2026-11-18 实测 1 与 4 都返回
// bytevc1，这里沿用上游默认值以减少变量。
func PlaybackV5Body(episodeID string) ([]byte, error) {
	body, err := jsonMarshal(map[string]any{
		"biz_param": map[string]any{
			"detail_page_version": 0, "device_level": 1, "disable_digg_stat": false,
			"disable_video_relate_book": false, "need_all_video_definition": true,
			"need_mp4_align": false, "use_os_player": false, "use_server_dns": false, "video_platform": 1024,
		},
		"mixed_video_id_map": map[string][]string{"1004": {episodeID}},
		"dr_scene":           "player",
	})
	if err != nil {
		return nil, err
	}
	var output bytes.Buffer
	writer := gzip.NewWriter(&output)
	if _, err = writer.Write(body); err != nil {
		return nil, err
	}
	if err = writer.Close(); err != nil {
		return nil, err
	}
	return output.Bytes(), nil
}

// PlaybackV5UserAgent 是 V5 取流请求的 Cronet UA：沿用 7.4.3.32 的版本号
// 与上游抓包的 TTNet/Quic 版本，机型段跟随设备档案。
func PlaybackV5UserAgent(d model.Device) string {
	d = d.OrDefault()
	return fmt.Sprintf("%s/%s (Linux; U; Android %s; zh_CN; %s; Build/%s; Cronet/TTNetVersion:8d40f833 2026-03-03 QuicVersion:21ac1950 2025-11-18)",
		Package, PlaybackVersionCode, d.OSVersion, d.Model, d.Build)
}
