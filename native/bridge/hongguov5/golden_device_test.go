package hongguov5

// golden_device_test.go — 设备负载 / 绑定证明 / bootstrap 查询串 / 注册请求对拍。
// 不含压缩器的字段才做字节级断言：gzip/zlib 输出与 Python 不同（服务端只解压），
// 因此注册 body 与 X-SS-STUB 只校验可由纯字节逻辑决定的部分。

import (
	"bytes"
	"testing"
)

const (
	goldenMS       = int64(1774000000000)
	goldenDeviceID = "7399254569531119116"
	goldenIID      = "7189224567890123456"
	goldenToken    = "Cg8IARABGAIQAQi6vK3wBQi6vK3wBQ"
)

// goldenEntropy 复刻 scripts/v5_golden.py 的 FakeSecrets 序列。
func goldenEntropy() *entropySource {
	uuids := []string{
		"5f0c8a2e-1b3d-4e5f-9a8b-7c6d5e4f3a21",
		"a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d",
		"99887766-5544-4332-2110-fedcba987654",
	}
	uuidIndex := 0
	rb32 := []uint32{0x11111111, 0x22222222, 0x33333333}
	rb32Index := 0
	return &entropySource{
		Randbits32: func() uint32 {
			if rb32Index < len(rb32) {
				v := rb32[rb32Index]
				rb32Index++
				return v
			}
			return 0x11111111
		},
		Randbits64: func() uint64 { return 0x4444444444444440 },
		Randbits8:  func() byte { return 0x5A },
		TokenBytes: func(n int) []byte {
			switch n {
			case 4:
				return []byte{0xaa, 0xbb, 0xcc, 0xdd}
			case 32:
				return bytes.Repeat([]byte{0x61}, 32)
			}
			return bytes.Repeat([]byte{0x61}, n)
		},
		Randbelow: func(n int64) int64 {
			if n == 1<<16 {
				return 0x1234
			}
			if n == 900000000 {
				return 123456789
			}
			return 0
		},
		TokenHex: func(n int) string {
			if n == 8 {
				return "c3c3c3c3c3c3c3c3"
			}
			if n == 16 {
				return "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1"
			}
			return ""
		},
		Getpid: func() int { return 12345 },
		UUID: func() string {
			v := uuids[uuidIndex%len(uuids)]
			uuidIndex++
			return v
		},
	}
}

func goldenParams(t *testing.T, g *goldenFixture) map[string]string {
	t.Helper()
	_, _, _, raw, err := prepareRegistration(goldenMS, goldenEntropy())
	if err != nil {
		t.Fatal(err)
	}
	params := make(map[string]string, len(raw)+6)
	for k, v := range raw {
		params[k] = v
	}
	params["device_id"] = goldenDeviceID
	params["iid"] = goldenIID
	params["sdkid"] = ""
	params["subaid"] = ""
	params["bd_did"] = ""
	params["klink_egdi"] = ""
	_ = g
	return params
}

func TestGoldenDeviceStructs(t *testing.T) {
	g := loadGolden(t)
	params := goldenParams(t, g)

	if got := hexEncode(deviceProof(goldenDeviceID)); got != g.DeviceProof {
		t.Fatalf("device_proof: got %s want %s", got, g.DeviceProof)
	}
	if got := hexEncode(devicePayload(params, g.Materials.Unavailable, nil)); got != g.DevicePayload {
		t.Fatalf("device_payload: got %s want %s", got, g.DevicePayload)
	}
	if got := hexEncode(devicePayload(params, g.Materials.Unavailable, []byte(goldenToken))); got != g.DevicePayloadTok {
		t.Fatalf("device_payload_token: got %s want %s", got, g.DevicePayloadTok)
	}
	if got := hexEncode(boundDeviceProof(params)); got != g.BoundDeviceProof {
		t.Fatalf("bound_device_proof: got %s want %s", got, g.BoundDeviceProof)
	}
	merged := make(map[string]string, len(params)+6)
	for k, v := range params {
		merged[k] = v
	}
	merged["version_name"] = "7.4.3.32"
	merged["version_code"] = "74332"
	merged["manifest_version_code"] = "74332"
	merged["update_version_code"] = "74332"
	merged["device_platform"] = "android"
	merged["os"] = "android"
	if got := string(bootstrapQuery(merged, goldenMS)); got != g.BootstrapQuery {
		t.Fatalf("bootstrap_query:\n got %s\nwant %s", got, g.BootstrapQuery)
	}
}

func TestGoldenRegisterRequest(t *testing.T) {
	g := loadGolden(t)
	url, body, headers, _, err := prepareRegistration(goldenMS, goldenEntropy())
	if err != nil {
		t.Fatal(err)
	}
	if url != g.RegisterRequest.URL {
		t.Fatalf("register url:\n got %s\nwant %s", url, g.RegisterRequest.URL)
	}
	// body 含 TT 帧（gzip 体由 Go flate 产出），只校验帧头与固定字段。
	wantBody := mustHex(t, g.RegisterRequest.Body)
	if len(body) < 38 || !bytes.Equal(body[:6], wantBody[:6]) {
		t.Fatalf("register body head: got %x want %x", body[:min(6, len(body))], wantBody[:6])
	}
	if !bytes.Equal(body[6:38], bytes.Repeat([]byte{0x61}, 32)) {
		t.Fatalf("register nonce mismatch")
	}
	for name, want := range g.RegisterRequest.Headers {
		got, ok := headers[name]
		if !ok {
			t.Fatalf("register header %q missing", name)
		}
		// X-SS-STUB 是 body 摘要（压缩字节不同），跳过。
		if name == "X-SS-STUB" {
			continue
		}
		if got != want {
			t.Fatalf("register header %q: got %q want %q", name, got, want)
		}
	}
}
