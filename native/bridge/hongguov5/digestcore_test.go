//go:build cgo

package hongguov5

// digestcore_test.go — AC2：Unicorn 摘要核心与 Python harness 黄金矩阵逐字节对拍
// （16 selector × 2 秒值，真实 libmetasec_ml.so）。素材走 go:embed（APK 内自带）。

import (
	"testing"
)

func loadSDKImage(t *testing.T) []byte {
	t.Helper()
	raw, err := embeddedAssets.ReadFile("assets/libmetasec_ml.so")
	if err != nil {
		t.Skipf("素材不可用（%v）", err)
	}
	return raw
}

func TestGoldenDigestMatrix(t *testing.T) {
	g := loadGolden(t)
	core, err := newSDKDigestCore(loadSDKImage(t))
	if err != nil {
		t.Fatalf("newSDKDigestCore: %v", err)
	}
	defer core.Close()
	for i, row := range g.DigestMatrix {
		payload := mustHex(t, row[0].(string))
		mode := int(row[1].(float64))
		seconds := uint32(row[2].(float64))
		want := row[3].(string)
		got, err := core.digest(payload, mode, seconds)
		if err != nil {
			t.Fatalf("digest[%d] mode=%d seconds=%d: %v", i, mode, seconds, err)
		}
		if hexEncode(got) != want {
			t.Fatalf("digest[%d] mode=%d seconds=%d: got %s want %s", i, mode, seconds, hexEncode(got), want)
		}
	}
}
