package webplay

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestDeriveAccessKeyUpstreamVectors(t *testing.T) {
	vectors := []struct {
		in   string
		want string
	}{
		{"z+Yb/ASySvhVqE63UKsd5laqGLMErU6NWa9BjwySFIsCkBi6ug==", "d06dea7f2663eedbe045b80908f51201"},
		{"zeYZxQfeTZMDsRqrBLRN/gWxTvoD4E/8V7NNk1bfG8gF0h///w==", "b951adf80166abaebbe1d41f284df080"},
	}
	for _, v := range vectors {
		got, err := DeriveAccessKey(v.in)
		if err != nil {
			t.Fatalf("DeriveAccessKey(%q): %v", v.in, err)
		}
		if got != v.want {
			t.Errorf("DeriveAccessKey(%q) = %s, want %s", v.in, got, v.want)
		}
	}
}

func TestDeriveAccessKeyFailsClosed(t *testing.T) {
	for _, in := range []string{"", "AAAA", "not base64!!!"} {
		if _, err := DeriveAccessKey(in); err == nil {
			t.Errorf("DeriveAccessKey(%q) unexpectedly succeeded", in)
		}
	}
}

// 成功结果在 TTL 内复用，重复打开不再打上游（防 IP 限流/判重的关键）。
func TestResolveCachesSuccess(t *testing.T) {
	const body = `{"base_resp":{"StatusCode":0},"play_info":{"vid":"v1","main_url":"https://cdn.test/v.mp4","codec_type":"h264","format":"dash","definition":"720p","width":"1280","height":"720","size":"100","duration":"150","player_access_key":"z+Yb/ASySvhVqE63UKsd5laqGLMErU6NWa9BjwySFIsCkBi6ug==","audio":{"main_url":"https://cdn.test/a.mp4"}}}`
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		fmt.Fprint(w, body)
	}))
	defer srv.Close()

	old := endpoint
	endpoint = srv.URL
	defer func() { endpoint = old }()
	// 用唯一 key 避免与其它测试的缓存串味。
	sid, eid := "cache-test-s", "cache-test-e"

	for i := 0; i < 3; i++ {
		pb, key, err := Resolve(context.Background(), srv.Client(), sid, eid, "720p")
		if err != nil || pb == nil || len(pb.Streams) != 1 || key.Hex == "" {
			t.Fatalf("call %d: pb=%v key=%v err=%v", i, pb, key, err)
		}
	}
	if calls != 1 {
		t.Errorf("upstream calls = %d, want 1 (cache should serve 2nd/3rd)", calls)
	}
}

// 403 游客墙映射为 ErrLoginRequired，便于 UI 明确提示，不回落不重试。
func TestResolveLoginRequired(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusForbidden)
		fmt.Fprint(w, `{"error":"protected_playback_unavailable"}`)
	}))
	defer srv.Close()
	old := endpoint
	endpoint = srv.URL
	defer func() { endpoint = old }()

	_, _, err := Resolve(context.Background(), srv.Client(), "login-s", "login-e", "720p")
	if err == nil {
		t.Fatal("expected error")
	}
	if !errors.Is(err, ErrLoginRequired) {
		t.Errorf("err = %v, want ErrLoginRequired", err)
	}
}

// 老剧（无加密资源）只返回 legacy_play_info：解析成明文 Playback，
// 无内容密钥、非 DASH、非加密，音轨内嵌（AudioURL 留空）。
func TestResolveLegacyFallback(t *testing.T) {
	const body = `{"base_resp":{"StatusCode":0},"legacy_play_info":{"main_url":"https://cdn.test/legacy.mp4","width":"1280","height":"720","duration":138.856}}`
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, body)
	}))
	defer srv.Close()
	old := endpoint
	endpoint = srv.URL
	defer func() { endpoint = old }()
	// 用唯一 key 避免与其它测试的缓存串味。
	sid, eid := "legacy-fb-s", "legacy-fb-e"

	pb, key, err := Resolve(context.Background(), srv.Client(), sid, eid, "720p")
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	if pb == nil || pb.Protected {
		t.Fatalf("pb = %+v, want plaintext playback (Protected=false)", pb)
	}
	if len(pb.Streams) != 1 {
		t.Fatalf("streams = %d, want 1", len(pb.Streams))
	}
	st := pb.Streams[0]
	if st.URL != "https://cdn.test/legacy.mp4" || st.Dash || st.Codec != "h264" {
		t.Errorf("stream = %+v, want plaintext h264 legacy URL", st)
	}
	if key.Hex != "" {
		t.Errorf("key.Hex = %q, want empty (legacy needs no key)", key.Hex)
	}
	if pb.DurationSeconds != 138 {
		t.Errorf("DurationSeconds = %d, want 138", pb.DurationSeconds)
	}
}

// play_info 与 legacy_play_info 同时存在时 play_info 优先（走派生密钥路径）。
func TestResolvePrefersPlayInfo(t *testing.T) {
	const body = `{"base_resp":{"StatusCode":0},"play_info":{"vid":"v1","main_url":"https://cdn.test/v.mp4","codec_type":"h264","format":"dash","definition":"720p","width":"1280","height":"720","size":"100","duration":"150","player_access_key":"z+Yb/ASySvhVqE63UKsd5laqGLMErU6NWa9BjwySFIsCkBi6ug==","audio":{"main_url":"https://cdn.test/a.mp4"}},"legacy_play_info":{"main_url":"https://cdn.test/legacy.mp4","width":"1280","height":"720","duration":138.856}}`
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, body)
	}))
	defer srv.Close()
	old := endpoint
	endpoint = srv.URL
	defer func() { endpoint = old }()
	sid, eid := "prefer-pi-s", "prefer-pi-e"

	pb, key, err := Resolve(context.Background(), srv.Client(), sid, eid, "720p")
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	if key.Hex == "" {
		t.Error("key.Hex empty, want derived key (play_info path)")
	}
	if len(pb.Streams) != 1 || !pb.Streams[0].Dash {
		t.Errorf("streams = %+v, want play_info DASH stream", pb.Streams)
	}
	if pb.Streams[0].URL != "https://cdn.test/v.mp4" {
		t.Errorf("stream URL = %q, want play_info main_url", pb.Streams[0].URL)
	}
}

// 480p 请求遇 403 游客墙：不降级、不重试，直接报 ErrLoginRequired
// （ep6+ 老剧必须明确提示登录，而不是降级 720p 空跑一次）。
func TestResolveLoginRequiredPrecedesDowngrade(t *testing.T) {
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		w.WriteHeader(http.StatusForbidden)
		fmt.Fprint(w, `{"error":"protected_playback_unavailable"}`)
	}))
	defer srv.Close()
	old := endpoint
	endpoint = srv.URL
	defer func() { endpoint = old }()
	sid, eid := "login-480p-s", "login-480p-e"

	_, _, err := Resolve(context.Background(), srv.Client(), sid, eid, "480p")
	if !errors.Is(err, ErrLoginRequired) {
		t.Fatalf("err = %v, want ErrLoginRequired", err)
	}
	if calls != 1 {
		t.Errorf("upstream calls = %d, want 1 (403 must not trigger 720p downgrade)", calls)
	}
}

// play_info 存在但 main_url 为空、legacy_play_info 同时存在：回落 legacy 明文
// （空 URL 的 play_info 不可播，legacy 是唯一可播形态），不报 empty playback。
func TestResolveLegacyFallbackWhenPlayInfoURLBlank(t *testing.T) {
	const body = `{"base_resp":{"StatusCode":0},"play_info":{"vid":"v1","kid":"k1","main_url":"","player_access_key":"z+Yb/ASySvhVqE63UKsd5laqGLMErU6NWa9BjwySFIsCkBi6ug=="},"legacy_play_info":{"main_url":"https://cdn.test/legacy.mp4","width":"1280","height":"720","duration":138.856}}`
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		fmt.Fprint(w, body)
	}))
	defer srv.Close()
	old := endpoint
	endpoint = srv.URL
	defer func() { endpoint = old }()
	sid, eid := "legacy-blank-pi-s", "legacy-blank-pi-e"

	pb, key, err := Resolve(context.Background(), srv.Client(), sid, eid, "720p")
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	if pb == nil || pb.Protected || len(pb.Streams) != 1 || pb.Streams[0].URL != "https://cdn.test/legacy.mp4" {
		t.Fatalf("pb = %+v, want legacy plaintext stream", pb)
	}
	if key.Hex != "" {
		t.Errorf("key.Hex = %q, want empty (legacy needs no key)", key.Hex)
	}
	if calls != 1 {
		t.Errorf("upstream calls = %d, want 1", calls)
	}
}

// 老剧请求 480p（加密档位）→ 上游 502 encrypted_resource_unavailable →
// 降级 720p 重取一次，拿到 legacy 明文流。
func TestResolveDowngradesDefinitionOnNoEncryptedLadder(t *testing.T) {
	const legacyBody = `{"base_resp":{"StatusCode":0},"legacy_play_info":{"main_url":"https://cdn.test/legacy.mp4","width":"1280","height":"720","duration":138.856}}`
	bodies := []string{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		bodies = append(bodies, string(raw))
		if strings.Contains(string(raw), `"480p"`) {
			w.WriteHeader(http.StatusBadGateway)
			fmt.Fprint(w, `{"error":"encrypted_resource_unavailable"}`)
			return
		}
		fmt.Fprint(w, legacyBody)
	}))
	defer srv.Close()
	old := endpoint
	endpoint = srv.URL
	defer func() { endpoint = old }()
	sid, eid := "downgrade-s", "downgrade-e"

	pb, key, err := Resolve(context.Background(), srv.Client(), sid, eid, "480p")
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	if pb == nil || pb.Protected || len(pb.Streams) != 1 || pb.Streams[0].URL != "https://cdn.test/legacy.mp4" {
		t.Fatalf("pb = %+v, want legacy plaintext stream", pb)
	}
	if key.Hex != "" {
		t.Errorf("key.Hex = %q, want empty", key.Hex)
	}
	if len(bodies) != 2 {
		t.Fatalf("upstream calls = %d, want 2 (480p -> 502 -> 720p)", len(bodies))
	}
	if !strings.Contains(bodies[0], `"480p"`) {
		t.Errorf("1st request body = %s, want definition 480p", bodies[0])
	}
	if !strings.Contains(bodies[1], `"720p"`) {
		t.Errorf("2nd request body = %s, want definition 720p", bodies[1])
	}
}

// ===== fallback-play-info 官网回退源（2026-11-17 新契约） =====

// play-info 两种形态全缺（空响应形态）时，改打官网 fallback-play-info，
// 返回明文整集 Playback（Protected=false、无密钥、ExpiresAt=url_expire）。
func TestFallbackRescuesEmptyPlayInfo(t *testing.T) {
	primaryCalls, fbCalls := 0, 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		primaryCalls++
		fmt.Fprint(w, `{"base_resp":{"StatusCode":0}}`)
	}))
	defer srv.Close()
	fbSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fbCalls++
		raw, _ := io.ReadAll(r.Body)
		if !strings.Contains(string(raw), `"item_id":"fb-rescue-e"`) {
			t.Errorf("fallback body = %s, want item_id only", raw)
		}
		fmt.Fprint(w, `{"main_url":"https://cdn.test/fb.mp4","url_expire":"4102444800","base_resp":{"StatusCode":0}}`)
	}))
	defer fbSrv.Close()
	old, oldFB := endpoint, fallbackEndpoint
	endpoint, fallbackEndpoint = srv.URL, fbSrv.URL
	defer func() { endpoint, fallbackEndpoint = old, oldFB }()
	sid, eid := "fb-rescue-s", "fb-rescue-e"

	pb, key, err := Resolve(context.Background(), srv.Client(), sid, eid, "720p")
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	if pb == nil || pb.Protected || len(pb.Streams) != 1 {
		t.Fatalf("pb = %+v, want single plaintext stream", pb)
	}
	st := pb.Streams[0]
	if st.URL != "https://cdn.test/fb.mp4" || st.Dash || st.Codec != "h264" {
		t.Errorf("stream = %+v, want fallback plaintext h264", st)
	}
	if key.Hex != "" {
		t.Errorf("key.Hex = %q, want empty (fallback is plaintext)", key.Hex)
	}
	if pb.ExpiresAt != 4102444800 {
		t.Errorf("ExpiresAt = %d, want url_expire 4102444800", pb.ExpiresAt)
	}
	if primaryCalls != 1 || fbCalls != 1 {
		t.Errorf("calls primary=%d fallback=%d, want 1/1", primaryCalls, fbCalls)
	}
}

// 403 游客墙直接短路：绝不触发 fallback（墙对 fallback 同样生效）。
func TestFallbackNotTriedOnLoginWall(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusForbidden)
		fmt.Fprint(w, `{"error":"protected_playback_unavailable"}`)
	}))
	defer srv.Close()
	fbCalls := 0
	fbSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fbCalls++
		fmt.Fprint(w, `{"main_url":"https://cdn.test/fb.mp4"}`)
	}))
	defer fbSrv.Close()
	old, oldFB := endpoint, fallbackEndpoint
	endpoint, fallbackEndpoint = srv.URL, fbSrv.URL
	defer func() { endpoint, fallbackEndpoint = old, oldFB }()
	sid, eid := "fb-wall-s", "fb-wall-e"

	_, _, err := Resolve(context.Background(), srv.Client(), sid, eid, "720p")
	if !errors.Is(err, ErrLoginRequired) {
		t.Fatalf("err = %v, want ErrLoginRequired", err)
	}
	if fbCalls != 0 {
		t.Errorf("fallback calls = %d, want 0 (wall short-circuits)", fbCalls)
	}
}

// fallback 也失败时返回主通道原错误（empty），而不是 fallback 的错误。
func TestFallbackFailureKeepsPrimaryError(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, `{"base_resp":{"StatusCode":0}}`)
	}))
	defer srv.Close()
	fbSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusForbidden)
		fmt.Fprint(w, `{"error":"public_fallback_unavailable"}`)
	}))
	defer fbSrv.Close()
	old, oldFB := endpoint, fallbackEndpoint
	endpoint, fallbackEndpoint = srv.URL, fbSrv.URL
	defer func() { endpoint, fallbackEndpoint = old, oldFB }()
	sid, eid := "fb-keep-err-s", "fb-keep-err-e"

	_, _, err := Resolve(context.Background(), srv.Client(), sid, eid, "720p")
	if err == nil {
		t.Fatal("expected error")
	}
	if !errors.Is(err, ErrEmptyPlayback) {
		t.Errorf("err = %v, want primary ErrEmptyPlayback", err)
	}
	if errors.Is(err, ErrLoginRequired) {
		t.Errorf("err = %v, must not surface fallback's wall error", err)
	}
}

// play-info 成功（含 legacy 回落）时绝不打 fallback。
func TestFallbackSkippedWhenPlayInfoSucceeds(t *testing.T) {
	const body = `{"base_resp":{"StatusCode":0},"play_info":{"vid":"v1","main_url":"https://cdn.test/v.mp4","codec_type":"h264","format":"dash","definition":"720p","width":"1280","height":"720","size":"100","duration":"150","player_access_key":"z+Yb/ASySvhVqE63UKsd5laqGLMErU6NWa9BjwySFIsCkBi6ug==","audio":{"main_url":"https://cdn.test/a.mp4"}}}`
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, body)
	}))
	defer srv.Close()
	fbCalls := 0
	fbSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fbCalls++
		fmt.Fprint(w, `{"main_url":"https://cdn.test/fb.mp4"}`)
	}))
	defer fbSrv.Close()
	old, oldFB := endpoint, fallbackEndpoint
	endpoint, fallbackEndpoint = srv.URL, fbSrv.URL
	defer func() { endpoint, fallbackEndpoint = old, oldFB }()
	sid, eid := "fb-skip-s", "fb-skip-e"

	pb, key, err := Resolve(context.Background(), srv.Client(), sid, eid, "720p")
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	if key.Hex == "" || len(pb.Streams) != 1 || !pb.Streams[0].Dash {
		t.Fatalf("pb=%v key=%v, want play_info DASH success", pb, key)
	}
	if fbCalls != 0 {
		t.Errorf("fallback calls = %d, want 0", fbCalls)
	}
}
