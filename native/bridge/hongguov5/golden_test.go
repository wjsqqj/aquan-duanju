package hongguov5

// golden_test.go — AC1 全量黄金对拍：testdata/golden.json 由
// scripts/v5_golden.py 从 Python sidecar（基准实现）产出，固定 entropy/nonce。

import (
	"bytes"
	"encoding/json"
	"testing"
)

type goldenFixture struct {
	Sm3              [][2]string `json:"sm3"`
	PBEncodeInt      string      `json:"pb_encode_int"`
	PBDecodeInt      [][]any     `json:"pb_decode_int"`
	PBEncodeMix      string      `json:"pb_encode_mix"`
	PBDecodeMix      [][]any     `json:"pb_decode_mix"`
	Signed           [][]int64   `json:"signed"`
	Xtea             [][]string  `json:"xtea"`
	PayloadEncrypt   [][]any     `json:"payload_encrypt"`
	DeviceProof      string      `json:"device_proof"`
	DevicePayload    string      `json:"device_payload"`
	DevicePayloadTok string      `json:"device_payload_token"`
	BoundDeviceProof string      `json:"bound_device_proof"`
	BootstrapQuery   string      `json:"bootstrap_query"`
	AdvanceLadon     [][]int64   `json:"advance_ladon"`
	DigestMatrix     [][]any     `json:"digest_matrix"`
	DigestV5         [][]any     `json:"digest_v5"`
	Selector         [][]any     `json:"selector"`
	Checksum         [][]any     `json:"checksum"`
	MedusaBlock      [][]any     `json:"medusa_block"`
	V5Block          [][]any     `json:"v5_block"`
	ScrambleKey      [][]any     `json:"scramble_key"`
	Scramble         [][]string  `json:"scramble"`
	XgorgonHandle    [][]string  `json:"xgorgon_handle"`
	GorgonV5         [][]any     `json:"gorgon_v5"`
	EnvelopeV5       [][]any     `json:"envelope_v5"`
	Ladon            [][]any     `json:"ladon"`
	TTEncrypt        [][]string  `json:"tt_encrypt"`
	RegisterRequest  struct {
		URL     string            `json:"url"`
		Body    string            `json:"body"`
		Headers map[string]string `json:"headers"`
	} `json:"register_request"`
	SignBootstrap struct {
		URL       string            `json:"url"`
		Headers   map[string]string `json:"headers"`
		Body      string            `json:"body"`
		NextLadon int64             `json:"next_ladon"`
	} `json:"sign_bootstrap"`
	SignPlayback struct {
		URL       string            `json:"url"`
		Headers   map[string]string `json:"headers"`
		Body      string            `json:"body"`
		NextLadon int64             `json:"next_ladon"`
	} `json:"sign_playback"`
	Materials struct {
		SigningKey       string `json:"signing_key"`
		ExchangeKey      string `json:"exchange_key"`
		Frame            string `json:"frame"`
		Substitutions    string `json:"substitutions"`
		ExchangeInnerKey string `json:"exchange_inner_key"`
		Unavailable      string `json:"unavailable"`
	} `json:"materials"`
}

func loadGolden(t *testing.T) *goldenFixture {
	t.Helper()
	raw, err := testdataFS.ReadFile("testdata/golden.json")
	if err != nil {
		t.Fatalf("golden.json: %v", err)
	}
	fixture := &goldenFixture{}
	if err := json.Unmarshal(raw, fixture); err != nil {
		t.Fatalf("golden decode: %v", err)
	}
	return fixture
}

func TestGoldenSM3(t *testing.T) {
	g := loadGolden(t)
	for i, pair := range g.Sm3 {
		got := sm3(mustHex(t, pair[0]))
		if got := hexEncode(got); got != pair[1] {
			t.Fatalf("sm3[%d]: got %s want %s", i, got, pair[1])
		}
	}
}

func TestGoldenPB(t *testing.T) {
	g := loadGolden(t)
	fields := []PBField{pbInt(1, 2), pbInt(3, 8662), pbInt(7, 1777775), pbInt(16, 255)}
	if got := hexEncode(pbEncode(fields)); got != g.PBEncodeInt {
		t.Fatalf("pb_encode_int: got %s want %s", got, g.PBEncodeInt)
	}
	rows, err := pbDecode(mustHex(t, g.PBEncodeInt))
	if err != nil {
		t.Fatal(err)
	}
	if len(rows) != len(g.PBDecodeInt) {
		t.Fatalf("pb_decode_int rows: %d", len(rows))
	}
	for i, row := range rows {
		want := g.PBDecodeInt[i]
		if row.Number != int(want[0].(float64)) || row.Kind != int(want[1].(float64)) {
			t.Fatalf("pb_decode_int[%d]: got %d/%d want %v", i, row.Number, row.Kind, want)
		}
		if row.Int != uint64(want[2].(float64)) {
			t.Fatalf("pb_decode_int[%d] value: got %d want %v", i, row.Int, want[2])
		}
	}

	mixFields := []PBField{
		pbStr(1, "8662"), pbStr(4, "7399254569531119116"), pbInt(14, 8),
		pbFloat(16, 255.25), pbBytes(17, []byte{1, 2, 0, 3}),
	}
	if got := hexEncode(pbEncode(mixFields)); got != g.PBEncodeMix {
		t.Fatalf("pb_encode_mix: got %s want %s", got, g.PBEncodeMix)
	}
	mixRows, err := pbDecode(mustHex(t, g.PBEncodeMix))
	if err != nil {
		t.Fatal(err)
	}
	if len(mixRows) != len(g.PBDecodeMix) {
		t.Fatalf("pb_decode_mix rows: %d", len(mixRows))
	}
	for i, row := range mixRows {
		want := g.PBDecodeMix[i]
		if row.Kind == 2 {
			if hexEncode(row.Bytes) != want[2].(string) {
				t.Fatalf("pb_decode_mix[%d] bytes: got %s want %v", i, hexEncode(row.Bytes), want[2])
			}
		}
	}
}

func TestGoldenSigned(t *testing.T) {
	g := loadGolden(t)
	for _, pair := range g.Signed {
		if got := int64(signed(pair[0])); got != pair[1] {
			t.Fatalf("signed(%d): got %d want %d", pair[0], got, pair[1])
		}
	}
}

func TestGoldenXtea(t *testing.T) {
	g := loadGolden(t)
	// golden 的 xtea 用 image["exchange_inner_key"]（materials 提供）。
	inner := mustHex(t, g.Materials.ExchangeInnerKey)
	for i, row := range g.Xtea {
		data, nonce := mustHex(t, row[0]), mustHex(t, row[1])
		out, err := xteaChain(data, inner, nonce, false)
		if err != nil {
			t.Fatal(err)
		}
		if hexEncode(out) != row[2] {
			t.Fatalf("xtea[%d]: got %s want %s", i, hexEncode(out), row[2])
		}
		back, err := xteaChain(out, inner, nonce, true)
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(back, data) {
			t.Fatalf("xtea[%d] roundtrip mismatch", i)
		}
	}
}

func TestGoldenPayloadEncrypt(t *testing.T) {
	g := loadGolden(t)
	common := mustHex(t, g.Materials.ExchangeKey)
	inner := mustHex(t, g.Materials.ExchangeInnerKey)
	for i, row := range g.PayloadEncrypt {
		plaintext := mustHex(t, row[0].(string))
		nonce := mustHex(t, row[1].(string))
		entropy := byte(row[2].(float64))
		// 密文字节不要求与 Python 一致：Go compress/flate 与 zlib 的压缩
		// 字节流不同（服务端只解压，不比对密文）。跨实现解密 + 自加密
		// round-trip 才是协议正确性的判据。
		pyPlain, err := decryptPayload(mustHex(t, row[3].(string)), common, inner)
		if err != nil {
			t.Fatalf("payload_encrypt[%d] decrypt python frame: %v", i, err)
		}
		if !bytes.Equal(pyPlain, plaintext) {
			t.Fatalf("payload_encrypt[%d] python frame plaintext mismatch", i)
		}
		cipher, err := encryptPayload(plaintext, common, inner, nonce, entropy)
		if err != nil {
			t.Fatal(err)
		}
		back, err := decryptPayload(cipher, common, inner)
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(back, plaintext) {
			t.Fatalf("payload_encrypt[%d] roundtrip mismatch", i)
		}
	}
}

func TestGoldenAdvanceLadon(t *testing.T) {
	g := loadGolden(t)
	for i, row := range g.AdvanceLadon {
		got := advanceLadon(uint32(row[0]), uint64(row[1]), uint32(row[2]))
		if int64(got) != row[3] {
			t.Fatalf("advance_ladon[%d]: got %d want %d", i, got, row[3])
		}
	}
}

func TestGoldenLadon(t *testing.T) {
	g := loadGolden(t)
	for i, row := range g.Ladon {
		got, err := ladonEncrypt(parseI64(row[0]), parseI64(row[1]), parseI64(row[2]), mustHex(t, row[3].(string)))
		if err != nil {
			t.Fatal(err)
		}
		if got != row[4].(string) {
			t.Fatalf("ladon[%d]: got %s want %v", i, got, row[4])
		}
	}
}

func TestGoldenXgorgon(t *testing.T) {
	g := loadGolden(t)
	for i, row := range g.XgorgonHandle {
		got := xgorgonHandle(mustHex(t, row[0]))
		if hexEncode(got) != row[1] {
			t.Fatalf("xgorgon_handle[%d]: got %s want %s", i, hexEncode(got), row[1])
		}
	}
}

func TestGoldenGorgonV5(t *testing.T) {
	g := loadGolden(t)
	for i, row := range g.GorgonV5 {
		var flags [2]byte
		fl := mustHex(t, row[4].(string))
		flags[0], flags[1] = fl[0], fl[1]
		got := gorgonV5(mustHex(t, row[0].(string)), mustHex(t, row[1].(string)),
			uint32(parseI64(row[2])), uint16(parseI64(row[3])), flags)
		if got != row[5].(string) {
			t.Fatalf("gorgon_v5[%d]: got %s want %s", i, got, row[5].(string))
		}
	}
}

func TestGoldenMedusaAndV5Block(t *testing.T) {
	g := loadGolden(t)
	for i, row := range g.MedusaBlock {
		key := mustHex(t, row[0].(string))
		secs := uint32(parseI64(row[1]))
		block := mustHex(t, row[2].(string))
		cipher, err := medusaCipherFromTables(key, secs)
		if err != nil {
			t.Fatal(err)
		}
		out, err := cipher.block(block)
		if err != nil {
			t.Fatal(err)
		}
		if hexEncode(out) != row[3].(string) {
			t.Fatalf("medusa_block[%d]: got %s want %s", i, hexEncode(out), row[3].(string))
		}
	}
	subst := mustHex(t, g.Materials.Substitutions)
	for i, row := range g.V5Block {
		key := mustHex(t, row[0].(string))
		block := mustHex(t, row[2].(string))
		variant0, err := newV5BlockCipher(key, subst[0:256], 0)
		if err != nil {
			t.Fatal(err)
		}
		out, err := variant0.block(block)
		if err != nil {
			t.Fatal(err)
		}
		if hexEncode(out) != row[3].(string) {
			t.Fatalf("v5_block[%d] variant0: got %s want %s", i, hexEncode(out), row[3].(string))
		}
		variant1, err := newV5BlockCipher(key, subst[256:512], 1)
		if err != nil {
			t.Fatal(err)
		}
		out, err = variant1.block(block)
		if err != nil {
			t.Fatal(err)
		}
		if hexEncode(out) != row[4].(string) {
			t.Fatalf("v5_block[%d] variant1: got %s want %s", i, hexEncode(out), row[4].(string))
		}
	}
}

func TestGoldenScramble(t *testing.T) {
	g := loadGolden(t)
	for i, row := range g.ScrambleKey {
		key := mustHex(t, row[0].(string))
		digest, mask := deriveScrambleKey(key, uint32(parseI64(row[1])))
		if hexEncode(digest) != row[2].(string) {
			t.Fatalf("scramble_key[%d] digest: got %s want %s", i, hexEncode(digest), row[2].(string))
		}
		if hexEncode(mask) != row[3].(string) {
			t.Fatalf("scramble_key[%d] mask: got %s want %s", i, hexEncode(mask), row[3].(string))
		}
	}
	for i, row := range g.Scramble {
		key := mustHex(t, row[1])
		out, err := scramble(mustHex(t, row[0]), key)
		if err != nil {
			t.Fatal(err)
		}
		if hexEncode(out) != row[2] {
			t.Fatalf("scramble[%d]: got %s want %s", i, hexEncode(out), row[2])
		}
	}
}

func TestGoldenTTEncrypt(t *testing.T) {
	g := loadGolden(t)
	nonce := bytes.Repeat([]byte{0x61}, 32)
	for i, row := range g.TTEncrypt {
		payload := []byte(row[0])
		content := mustHex(t, row[1])
		wantFrame := row[2]
		// 帧核心（同 content 字节）必须逐字节一致。
		got, err := ttEncryptWithContent(content, nonce)
		if err != nil {
			t.Fatal(err)
		}
		if hexEncode(got) != wantFrame {
			t.Fatalf("tt_encrypt[%d] frame: got %s want %s", i, hexEncode(got), wantFrame)
		}
		// Go 自产 gzip 全链路：encrypt→decrypt round-trip。
		mine, err := ttEncrypt(payload, nonce)
		if err != nil {
			t.Fatal(err)
		}
		back, err := ttDecrypt(mine)
		if err != nil {
			t.Fatalf("tt_decrypt[%d]: %v", i, err)
		}
		if back != row[0] {
			t.Fatalf("tt roundtrip[%d] mismatch", i)
		}
		// Python 帧解包（AES-CBC/gzip 路径对拍）。
		backPy, err := ttDecrypt(mustHex(t, wantFrame))
		if err != nil {
			t.Fatalf("tt_decrypt golden[%d]: %v", i, err)
		}
		if backPy != row[0] {
			t.Fatalf("tt_decrypt golden[%d] mismatch", i)
		}
	}
}

func mustHex(t *testing.T, s string) []byte {
	t.Helper()
	out, err := decodeHex(s)
	if err != nil {
		t.Fatalf("bad hex %q: %v", s, err)
	}
	return out
}

func parseI64(v any) int64 {
	switch n := v.(type) {
	case float64:
		return int64(n)
	case int64:
		return n
	case int:
		return int64(n)
	}
	panic("bad int")
}
