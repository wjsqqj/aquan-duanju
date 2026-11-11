package core

import (
	"encoding/json"
	"errors"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/beilunyang/openhongguo/sdk"
)

func TestVersionReturnsNonEmpty(t *testing.T) {
	if Version == "" {
		t.Fatal("Version 为空")
	}
}

func TestNewReturnsHandle(t *testing.T) {
	h := mustCreateClient(t)
	if h == 0 {
		t.Fatal("New 返回了 0 句柄")
	}
}

func TestNewRejectsBadConfig(t *testing.T) {
	out := New(filepath.Join(t.TempDir(), "device.json"), "{bad json")
	env := decode(t, out)
	if env.Error == nil {
		t.Fatal("坏 config 应返回 error 信封")
	}
	if env.Error["code"] != "INVALID_OPTIONS" {
		t.Fatalf("code = %v, want INVALID_OPTIONS", env.Error["code"])
	}
}

func TestCallUnknownHandle(t *testing.T) {
	env := decode(t, Call(4242, "hotSearch", ""))
	if env.Error == nil || env.Error["code"] != "INVALID_OPTIONS" {
		t.Fatalf("未知句柄应返回 INVALID_OPTIONS，得到 %v", env)
	}
}

func TestCallUnknownMethod(t *testing.T) {
	h := mustCreateClient(t)
	env := decode(t, Call(h, "noSuchMethod", ""))
	if env.Error == nil || env.Error["code"] != "INVALID_OPTIONS" {
		t.Fatalf("未知方法应返回 INVALID_OPTIONS，得到 %v", env)
	}
}

func TestEnvelopeJSONErrorDropsResult(t *testing.T) {
	out := envelopeJSON("kept", errFake)
	if strings.Contains(out, `"result"`) {
		t.Fatalf("错误信封不应携带 result: %s", out)
	}
	if !strings.Contains(out, `"code"`) {
		t.Fatalf("错误信封缺少 code: %s", out)
	}
	if out := envelopeJSON(nil, nil); out != `{"result":null}` {
		t.Fatalf("空结果应编为 {\"result\":null}: %s", out)
	}
}

// 取流空响应必须有自己的错误码：ANONYMOUS_LIMITED 在 UI 上是「设备配额用尽，
// 去重置设备」，而取流接口返回空 body 的原因未公开，不能复用那条文案。
func TestPlaybackUnavailableHasOwnCode(t *testing.T) {
	m := errorJSON(sdk.ErrPlaybackUnavailable)
	if m["code"] != "PLAYBACK_UNAVAILABLE" {
		t.Fatalf("code = %v, want PLAYBACK_UNAVAILABLE", m["code"])
	}
	if errors.Is(sdk.ErrPlaybackUnavailable, sdk.ErrAnonymousLimited) {
		t.Fatal("取流不可用不能 wrap ErrAnonymousLimited，否则会被当成设备配额错误")
	}
	if m := errorJSON(sdk.ErrAnonymousLimited); m["code"] != "ANONYMOUS_LIMITED" {
		t.Fatalf("ANONYMOUS_LIMITED 映射被破坏: %v", m["code"])
	}
}

// 取流响应有三种外层（video_model / data[vid] / video_model_data[vid]），
// 解析必须都能定位到同一份模型，且 video_list 支持数组与对象 map。
func TestParsePlaybackOuterShapes(t *testing.T) {
	const ep = "7695629314057849880"
	inner := `{"video_id":"` + ep + `","video_list":[{"main_url":"https://v26-reading-videocdn302.qznovelvod.com/a.mp4","definition":"1080p","video_meta":{"width":1920,"height":1080,"codec_type":"h264","bitrate":1234}}]}`
	asMap := `{"video_id":"` + ep + `","video_list":{"1080p":{"main_url":"https://v26-reading-videocdn302.qznovelvod.com/a.mp4","definition":"1080p","video_meta":{"width":1920,"height":1080,"codec_type":"h264","bitrate":1234}}}}`
	quoted := strconv.Quote(inner)
	cases := map[string]string{
		"data.video_model":  `{"code":0,"data":{"video_model":` + quoted + `}}`,
		"data[vid]":         `{"code":0,"data":{"` + ep + `":{"video_model":` + quoted + `}}}`,
		"video_model_data":  `{"code":0,"data":{"video_model_data":{"` + ep + `":{"video_model":` + inner + `}}}}`,
		"video_list as map": `{"code":0,"data":{"video_model":` + strconv.Quote(asMap) + `}}`,
	}
	for name, raw := range cases {
		pb, err := sdk.ParsePlaybackJSON([]byte(raw), ep)
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if len(pb.Streams) != 1 {
			t.Fatalf("%s: streams = %d, want 1", name, len(pb.Streams))
		}
		if !strings.Contains(pb.Streams[0].URL, "qznovelvod.com") {
			t.Fatalf("%s: url = %q", name, pb.Streams[0].URL)
		}
	}
}

type fakeError struct{}

func (fakeError) Error() string { return "fake" }

var errFake = fakeError{}

// mustCreateClient 用临时设备档案创建一个真实客户端（不发起网络请求）。
func mustCreateClient(t *testing.T) int32 {
	t.Helper()
	out := New(filepath.Join(t.TempDir(), "device.json"), "")
	env := decode(t, out)
	if env.Error != nil {
		t.Fatalf("New 失败: %v", env.Error)
	}
	m, ok := env.Result.(map[string]any)
	if !ok {
		t.Fatalf("New 结果不是对象: %v", env.Result)
	}
	f, _ := m["handle"].(float64)
	return int32(f)
}

func decode(t *testing.T, out string) envelope {
	t.Helper()
	var env envelope
	if err := json.Unmarshal([]byte(out), &env); err != nil {
		t.Fatalf("响应不是合法 JSON: %v", err)
	}
	return env
}
