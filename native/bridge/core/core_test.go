package core

import (
	"encoding/json"
	"path/filepath"
	"strings"
	"testing"
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
