package core

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"encoding/hex"
	"testing"
)

func sealMangaPage(t *testing.T, keyHex string, nonce, plain []byte) []byte {
	t.Helper()
	key, err := hex.DecodeString(keyHex)
	if err != nil {
		t.Fatalf("key: %v", err)
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		t.Fatalf("cipher: %v", err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		t.Fatalf("gcm: %v", err)
	}
	sealed := gcm.Seal(nil, nonce, plain, nil) // ciphertext‖tag
	return append(append([]byte{}, nonce...), sealed...)
}

func TestDecryptMangaPage(t *testing.T) {
	keyHex := "313936373139363731393637313936374ebdf82c7817e9b56bc2db7ba6b28ff0"
	nonce := bytes.Repeat([]byte{0x22}, mangaNonceSize)
	// JPEG 魔数开头，模拟真实载荷。
	plain := []byte{0xFF, 0xD8, 0xFF, 0xDB, 0x00, 0x84, 0x00, 0x08}

	got, err := decryptMangaPage(keyHex, sealMangaPage(t, keyHex, nonce, plain))
	if err != nil {
		t.Fatalf("decrypt: %v", err)
	}
	if !bytes.Equal(got, plain) {
		t.Fatalf("plain = % x, want % x", got, plain)
	}

	// 错误密钥
	wrong := "ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100"
	if _, err := decryptMangaPage(wrong, sealMangaPage(t, keyHex, nonce, plain)); err == nil {
		t.Fatal("错误密钥应当报错")
	}
	// 非法密钥
	if _, err := decryptMangaPage("zz", sealMangaPage(t, keyHex, nonce, plain)); err == nil {
		t.Fatal("非法密钥应当报错")
	}
	// 过短载荷
	if _, err := decryptMangaPage(keyHex, nonce); err == nil {
		t.Fatal("过短载荷应当报错")
	}
}
