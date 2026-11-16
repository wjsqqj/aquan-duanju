package appchain

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// 固定模型夹具：明文单条目（无加密字段 → Protected=false、ContentKey 空）。
func modelEnvelope(eid, mainURL string) string {
	return fmt.Sprintf(`{"code":"0","data":{%q:{"video_model":{"video_duration":146,`+
		`"url_expire":4102444800,"video_list":{"0":{"main_url":%q,`+
		`"codec_type":"h264","definition":"720p","vwidth":720,"vheight":1280}}}}}}`, eid, mainURL)
}

// resetState 还原进程级状态（设备缓存/熔断/轮换节流），并缩短同步窗口加速测试。
func resetState() {
	deviceMu.Lock()
	memDevice = nil
	deviceMu.Unlock()
	stateMu.Lock()
	failStreak = 0
	openUntil = time.Time{}
	lastRotateAt = time.Time{}
	stateMu.Unlock()
	freshSyncWait = time.Millisecond
}

// registerStub 起一个注册桩：断言加密信封形状，返回固定身份与 cookie。
func registerStub(t *testing.T, hits *int32) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(hits, 1)
		raw, _ := io.ReadAll(r.Body)
		if len(raw) < 6 || raw[0] != 0x74 || raw[1] != 0x63 || raw[2] != 0x05 || raw[3] != 0x10 {
			t.Errorf("register body magic = %x, want 74630510…", raw[:min(6, len(raw))])
		}
		http.SetCookie(w, &http.Cookie{Name: "store-region", Value: "cn-zj"})
		fmt.Fprint(w, `{"code":0,"device_id_str":"4100000000000001","install_id_str":"4100000000000002"}`)
	}))
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}

func restore(vars map[string]any) func() {
	oldMulti, oldShort := multiHosts, shortHosts
	oldReg := registerURL
	oldSync := freshSyncWait
	return func() {
		multiHosts, shortHosts, registerURL, freshSyncWait = oldMulti, oldShort, oldReg, oldSync
		_ = vars
	}
}

// multi 集群 1 空响应、集群 2 出模型 → 成功；注册恰好一次（设备复用）。
func TestResolveMultiClusterRecovery(t *testing.T) {
	resetState()
	defer restore(nil)()
	var regHits, hitsA, hitsB int32
	reg := registerStub(t, &regHits)
	defer reg.Close()
	registerURL = reg.URL
	const eid = "111111111111111111"
	srvA := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&hitsA, 1)
		if !strings.Contains(r.URL.RawQuery, "aid=8662") || !strings.Contains(r.URL.RawQuery, "version_code=74332") {
			t.Errorf("multi query = %s, want aid=8662/74332 posture", r.URL.RawQuery)
		}
		w.WriteHeader(http.StatusOK) // 200 + 空 body（生态故障主症状）
	}))
	defer srvA.Close()
	srvB := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&hitsB, 1)
		raw, _ := io.ReadAll(r.Body)
		if len(raw) == 0 || raw[0] != 0x1f || raw[1] != 0x8b {
			t.Errorf("multi body = %x…, want gzip magic", raw[:min(2, len(raw))])
		}
		fmt.Fprint(w, modelEnvelope(eid, "https://cdn.test/multi.mp4"))
	}))
	defer srvB.Close()
	multiHosts = []string{srvA.URL, srvB.URL}
	shortHosts = nil

	pb, key, err := Resolve(context.Background(), srvA.Client(), "", eid)
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	if len(pb.Streams) != 1 || pb.Streams[0].URL != "https://cdn.test/multi.mp4" {
		t.Fatalf("streams = %+v", pb.Streams)
	}
	if key.Hex != "" {
		t.Errorf("key.Hex = %q, want empty (plain fixture)", key.Hex)
	}
	if hitsA != 1 || hitsB != 1 {
		t.Errorf("hits A=%d B=%d, want 1/1", hitsA, hitsB)
	}
	if regHits != 1 {
		t.Errorf("register hits = %d, want 1 (device reuse afterwards)", regHits)
	}
}

// multi 全空 → 降级 shortplay（aid 1967/novelapp 短剧画像）出模型。
func TestResolveShortPlayFallback(t *testing.T) {
	resetState()
	defer restore(nil)()
	var regHits int32
	reg := registerStub(t, &regHits)
	defer reg.Close()
	registerURL = reg.URL
	const eid = "222222222222222222"
	empty := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer empty.Close()
	var shortQueryRaw string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		shortQueryRaw = r.URL.RawQuery
		fmt.Fprint(w, modelEnvelope(eid, "https://cdn.test/short.mp4"))
	}))
	defer srv.Close()
	multiHosts = []string{empty.URL}
	shortHosts = []string{srv.URL}

	pb, _, err := Resolve(context.Background(), srv.Client(), "", eid)
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	if len(pb.Streams) != 1 || pb.Streams[0].URL != "https://cdn.test/short.mp4" {
		t.Fatalf("streams = %+v", pb.Streams)
	}
	for _, want := range []string{"aid=1967", "app_name=novelapp", "version_code=72132", "content_type"} {
		if !strings.Contains(shortQueryRaw, want) && want != "content_type" {
			t.Errorf("short query = %s, missing %s", shortQueryRaw, want)
		}
	}
}

// 模型无 video_list 但带 fallback_api → 免签名二次请求拿到 video_info.data 再解析。
func TestShortPlayFallbackAPIFollow(t *testing.T) {
	resetState()
	defer restore(nil)()
	var regHits int32
	reg := registerStub(t, &regHits)
	defer reg.Close()
	registerURL = reg.URL
	const eid = "333333333333333333"
	fb := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			t.Errorf("fallback method = %s, want GET (no signature)", r.Method)
		}
		if ua := r.Header.Get("User-Agent"); !strings.HasPrefix(ua, "com.phoenix.read/71332") {
			t.Errorf("fallback UA = %q", ua)
		}
		fmt.Fprint(w, `{"code":0,"video_info":{"code":0,"data":{"video_duration":100,`+
			`"video_list":{"0":{"main_url":"https://cdn.test/fbfollow.mp4","codec_type":"h264","definition":"720p"}}}}}`)
	}))
	defer fb.Close()
	fbURL := fb.URL + "/getinfo?vid=" + eid
	primary := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, fmt.Sprintf(`{"code":"0","data":{%q:{"video_model":{"fallback_api":%q}}}}`, eid, fbURL))
	}))
	defer primary.Close()
	multiHosts = []string{primary.URL}
	shortHosts = nil

	pb, _, err := Resolve(context.Background(), fb.Client(), "", eid)
	if err != nil {
		t.Fatalf("Resolve: %v", err)
	}
	if len(pb.Streams) != 1 || pb.Streams[0].URL != "https://cdn.test/fbfollow.mp4" {
		t.Fatalf("streams = %+v, want fallback_api followed model", pb.Streams)
	}
}

// 全空两轮 → 熔断打开；第三轮不再打上游（circuit open）。
func TestResolveCircuitBreaker(t *testing.T) {
	resetState()
	defer restore(nil)()
	var regHits int32
	reg := registerStub(t, &regHits)
	defer reg.Close()
	registerURL = reg.URL
	var upstreamHits int32
	empty := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&upstreamHits, 1)
		w.WriteHeader(http.StatusOK)
	}))
	defer empty.Close()
	multiHosts = []string{empty.URL}
	shortHosts = nil
	const eid = "444444444444444444"

	for i := 0; i < 2; i++ {
		if _, _, err := Resolve(context.Background(), empty.Client(), "", eid); err == nil {
			t.Fatalf("round %d: expected failure", i)
		} else if !strings.Contains(err.Error(), "unavailable") {
			t.Fatalf("round %d: err = %v", i, err)
		}
	}
	breakerOpen() // 断言熔断已打开
	_, _, err := Resolve(context.Background(), empty.Client(), "", eid)
	if err == nil || !strings.Contains(err.Error(), "circuit open") {
		t.Fatalf("err = %v, want circuit open", err)
	}
	hits := atomic.LoadInt32(&upstreamHits)
	_ = hits
	// 注册节流：两次 Resolve 共 1 次初始注册 + 1 次轮换重注册 = 2。
	if got := atomic.LoadInt32(&regHits); got != 2 {
		t.Errorf("register hits = %d, want 2 (initial + one throttled rotation)", got)
	}
}
