package core

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"testing"

	"github.com/beilunyang/openhongguo/sdk"
	"github.com/wjsqqj/aquan-core/webplay"
)

// 整条解析链都失败时，被丢弃的 v5 / appchain 原因要挂进错误信封的 diagnostic
// 字段；对外的 code / message / retryable 仍是 web 通道原错误。11-26：日志里
// 只剩「webplay 取流失败，回落旧接口: …403」，两次「选集先失败再成功」因此
// 判断不了 v5 为什么失败。
func TestResolvePlaybackWebChainFailureCarriesDiagnostic(t *testing.T) {
	v5ResetForTest()
	// 三级全部在发请求之前就失败：v5 无客户端、webplay 不支持的档位、
	// appchain 非法分集 ID——离线可复现，不触网，也不动 v5 / appchain 熔断计数。
	raw := func(s string) json.RawMessage {
		b, _ := json.Marshal(s)
		return b
	}
	v, err := methods["resolvePlaybackWeb"](context.Background(), nil,
		[]json.RawMessage{raw("series"), raw("not-an-id"), raw("540p")})
	if v != nil || err == nil {
		t.Fatalf("三级全失败应返回错误: v=%v err=%v", v, err)
	}

	m := errorJSON(err)
	if m["code"] != "UNKNOWN" || m["retryable"] != false {
		t.Fatalf("对外的 code / retryable 应是 web 通道原错误的: %v", m)
	}
	msg, _ := m["message"].(string)
	if !strings.Contains(msg, `unsupported definition "540p"`) || strings.Contains(msg, "v5:") {
		t.Fatalf("message 应仍是 web 通道原错误、不混入诊断: %q", msg)
	}
	const want = "v5: hongguo-v5: unavailable: client-missing · appchain: appchain: invalid episode ID"
	if got := m["diagnostic"]; got != want {
		t.Fatalf("diagnostic = %v, want %q", got, want)
	}
	if out := envelopeJSON(nil, err); !strings.Contains(out, `"diagnostic":"`+want+`"`) {
		t.Fatalf("错误信封应带 diagnostic 字段: %s", out)
	}
}

// withDiagnostic 不改变错误语义：errors.Is / code / retryable 透传，信封只在
// 诊断非空时多出 diagnostic 字段。
func TestWithDiagnosticKeepsErrorContract(t *testing.T) {
	base := fmt.Errorf("%w: HTTP 403", webplay.ErrLoginRequired)
	wrapped := withDiagnostic(base, "v5: down")
	if !errors.Is(wrapped, webplay.ErrLoginRequired) || errors.Unwrap(wrapped) != base {
		t.Fatalf("应沿 Unwrap 链保留原错误: %v", wrapped)
	}
	if wrapped.Error() != base.Error() {
		t.Fatalf("message 不应变: %q", wrapped.Error())
	}
	m := errorJSON(wrapped)
	if m["code"] != "WEB_LOGIN_REQUIRED" || m["retryable"] != false || m["diagnostic"] != "v5: down" {
		t.Fatalf("code / retryable 应透传且带 diagnostic: %v", m)
	}
	limited := withDiagnostic(fmt.Errorf("%w: later", sdk.ErrRateLimited), "v5: down")
	if m := errorJSON(limited); m["code"] != "RATE_LIMITED" || m["retryable"] != true {
		t.Fatalf("可重试的错误包装后仍应可重试: %v", m)
	}

	// 无诊断：原样返回，信封不多字段。
	if got := withDiagnostic(base, ""); got != base {
		t.Fatal("诊断为空不应包装")
	}
	if got := withDiagnostic(nil, "x"); got != nil {
		t.Fatal("nil 错误不应被包装成非 nil")
	}
	if _, ok := errorJSON(base)["diagnostic"]; ok {
		t.Fatal("无诊断不应出现 diagnostic 字段")
	}
	if out := envelopeJSON(nil, base); strings.Contains(out, "diagnostic") {
		t.Fatalf("无诊断的信封形状不变: %s", out)
	}
}

// chainFailureDiagnostic：nil 环节省略、换行压平、单环节原因按字节截断。
func TestChainFailureDiagnostic(t *testing.T) {
	if got := chainFailureDiagnostic(nil, nil); got != "" {
		t.Fatalf("没有失败环节不应产生诊断: %q", got)
	}
	v5 := errors.New("hongguo-v5: unavailable: v5: pure: rejected\nnative: response-empty")
	want := "v5: hongguo-v5: unavailable: v5: pure: rejected native: response-empty"
	if got := chainFailureDiagnostic(v5, nil); got != want {
		t.Fatalf("只有 v5 失败: got %q, want %q", got, want)
	}
	got := chainFailureDiagnostic(errors.New("v5 down"), errors.New("appchain: empty"))
	if want := "v5: v5 down · appchain: appchain: empty"; got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
	long := chainFailureDiagnostic(errors.New(strings.Repeat("x", 500)), nil)
	if len(long) != len("v5: ")+240 {
		t.Fatalf("单环节原因应截断到 240 字节，实际 %d", len(long))
	}
}
