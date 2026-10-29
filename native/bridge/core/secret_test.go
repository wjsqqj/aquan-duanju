package core

import (
	"bytes"
	"compress/gzip"
	"encoding/base64"
	"encoding/hex"
	"strings"
	"testing"
)

func TestReverseHexDeviceID(t *testing.T) {
	got, err := reverseHexDeviceID("12345")
	if err != nil {
		t.Fatalf("reverse: %v", err)
	}
	// 12345 = 0x3039 → 32 位 hex 补零后按字节对反转：39 30 00 …
	want := "3930" + strings.Repeat("00", 14)
	if got != want {
		t.Fatalf("reverseHexDeviceID = %q, want %q", got, want)
	}

	for _, bad := range []string{"", "  ", "abc", "-1", "1.5"} {
		if _, err := reverseHexDeviceID(bad); err == nil {
			t.Fatalf("reverseHexDeviceID(%q) 应当报错", bad)
		}
	}
}

func TestPKCS7RoundTrip(t *testing.T) {
	for _, size := range []int{0, 1, 15, 16, 17, 64} {
		raw := bytes.Repeat([]byte{0x41}, size)
		padded := pkcs7Pad(raw, aesBlock)
		if len(padded)%aesBlock != 0 {
			t.Fatalf("size %d: padded length %d not aligned", size, len(padded))
		}
		got, err := pkcs7Unpad(padded, aesBlock)
		if err != nil {
			t.Fatalf("size %d: unpad: %v", size, err)
		}
		if !bytes.Equal(got, raw) {
			t.Fatalf("size %d: round trip mismatch", size)
		}
	}
	if _, err := pkcs7Unpad([]byte{1, 2, 3}, aesBlock); err == nil {
		t.Fatal("未对齐的块应当报错")
	}
	if _, err := pkcs7Unpad(bytes.Repeat([]byte{0}, aesBlock), aesBlock); err == nil {
		t.Fatal("零填充应当报错")
	}
}

func TestRegisterKeyRoundTrip(t *testing.T) {
	// 用主密钥加密一段伪密钥，再用 decryptSecretKeyResponse 解回来。
	master, err := hex.DecodeString(secretKeyMasterHex)
	if err != nil {
		t.Fatalf("master: %v", err)
	}
	rawKey := []byte("0123456789abcdef")
	iv := bytes.Repeat([]byte{0x5a}, aesBlock)
	enc, err := aesCBCEncrypt(master, iv, pkcs7Pad(rawKey, aesBlock))
	if err != nil {
		t.Fatalf("encrypt: %v", err)
	}
	payload := base64.StdEncoding.EncodeToString(append(iv, enc...))

	got, err := decryptSecretKeyResponse(payload)
	if err != nil {
		t.Fatalf("decrypt: %v", err)
	}
	if want := strings.ToUpper(hex.EncodeToString(rawKey)); got != want {
		t.Fatalf("secret key = %q, want %q", got, want)
	}

	if _, err := decryptSecretKeyResponse("not-base64!!"); err == nil {
		t.Fatal("非法 base64 应当报错")
	}
	if _, err := decryptSecretKeyResponse(base64.StdEncoding.EncodeToString([]byte("short"))); err == nil {
		t.Fatal("过短的载荷应当报错")
	}
}

func TestEncryptSecretKeyRequest(t *testing.T) {
	content, err := encryptSecretKeyRequest("12345")
	if err != nil {
		t.Fatalf("encrypt request: %v", err)
	}
	blob, err := base64.StdEncoding.DecodeString(content)
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(blob) <= aesBlock || len(blob)%aesBlock != 0 {
		t.Fatalf("blob length %d 不符合 iv+ciphertext 结构", len(blob))
	}
	// 还原出的明文必须是 reverseHex 后的 device_id 字节。
	key, _ := base64.StdEncoding.DecodeString(secretKeyRequestKeyB64)
	plain, err := aesCBCDecrypt(key, blob[:aesBlock], blob[aesBlock:])
	if err != nil {
		t.Fatalf("decrypt: %v", err)
	}
	raw, err := pkcs7Unpad(plain, aesBlock)
	if err != nil {
		t.Fatalf("unpad: %v", err)
	}
	hexID, err := reverseHexDeviceID("12345")
	if err != nil {
		t.Fatalf("reverse: %v", err)
	}
	want, _ := hex.DecodeString(hexID)
	if !bytes.Equal(raw, want) {
		t.Fatalf("请求明文 = %x, want %x", raw, want)
	}
}

func TestDecryptChapterContent(t *testing.T) {
	keyHex := "00112233445566778899aabbccddeeff"
	key, _ := hex.DecodeString(keyHex)
	iv := bytes.Repeat([]byte{0x11}, aesBlock)

	seal := func(plain []byte) string {
		enc, err := aesCBCEncrypt(key, iv, pkcs7Pad(plain, aesBlock))
		if err != nil {
			t.Fatalf("encrypt: %v", err)
		}
		return base64.StdEncoding.EncodeToString(append(append([]byte{}, iv...), enc...))
	}

	text := []byte("第一章 测试内容")
	got, err := decryptChapterContent(keyHex, seal(text))
	if err != nil {
		t.Fatalf("decrypt: %v", err)
	}
	if !bytes.Equal(got, text) {
		t.Fatalf("明文 = %q, want %q", got, text)
	}

	// gzip 分支
	var buf bytes.Buffer
	zw := gzip.NewWriter(&buf)
	_, _ = zw.Write(text)
	_ = zw.Close()
	got, err = decryptChapterContent(keyHex, seal(buf.Bytes()))
	if err != nil {
		t.Fatalf("decrypt gzip: %v", err)
	}
	if !bytes.Equal(got, text) {
		t.Fatalf("gzip 明文 = %q, want %q", got, text)
	}

	// 错密钥
	if _, err := decryptChapterContent("ffeeddccbbaa99887766554433221100", seal(text)); err == nil {
		t.Fatal("错误密钥应当报错")
	}
	// 非法输入
	if _, err := decryptChapterContent("zz", seal(text)); err == nil {
		t.Fatal("非法密钥应当报错")
	}
	if _, err := decryptChapterContent(keyHex, "not-base64!!"); err == nil {
		t.Fatal("非法正文应当报错")
	}
}

func TestGunzipIfNeeded(t *testing.T) {
	plain := []byte("plain text")
	if got := gunzipIfNeeded(plain); !bytes.Equal(got, plain) {
		t.Fatalf("非 gzip 数据不应被改动: %q", got)
	}
	var buf bytes.Buffer
	zw := gzip.NewWriter(&buf)
	_, _ = zw.Write(plain)
	_ = zw.Close()
	if got := gunzipIfNeeded(buf.Bytes()); !bytes.Equal(got, plain) {
		t.Fatalf("gzip 解压结果 = %q", got)
	}
	if got := gunzipIfNeeded([]byte{0x1f, 0x8b, 0x00}); len(got) != 3 {
		t.Fatalf("坏 gzip 应原样返回，得到 %d 字节", len(got))
	}
}
