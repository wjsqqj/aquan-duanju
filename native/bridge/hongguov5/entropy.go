package hongguov5

// entropy.go — 随机源收口（对齐 sidecar secrets/randbits/token_* 用法）。
// golden 测试注入固定序列；生产走 crypto/rand。

import (
	"crypto/rand"
	"encoding/binary"
)

func cryptoRead(n int) []byte {
	out := make([]byte, n)
	if _, err := rand.Read(out); err != nil {
		panic(err)
	}
	return out
}

func randbits32() uint32 {
	return binary.LittleEndian.Uint32(cryptoRead(4))
}

func randbits64() uint64 {
	return binary.LittleEndian.Uint64(cryptoRead(8))
}

func randbits8() byte {
	return cryptoRead(1)[0]
}

func cryptoTokenBytes(n int) []byte { return cryptoRead(n) }

func cryptoTokenHex(n int) string { return hexEncode(cryptoRead(n)) }

func cryptoRandbelow(n int64) int64 {
	v := int64(binary.LittleEndian.Uint64(cryptoRead(8))) % n
	if v < 0 {
		v += n
	}
	return v
}

// cryptoUUID 生成 RFC4122 v4（对齐 python uuid.uuid4 的形态）。
func cryptoUUID() string {
	raw := cryptoRead(16)
	raw[6] = raw[6]&0x0F | 0x40
	raw[8] = raw[8]&0x3F | 0x80
	hexs := hexEncode(raw)
	return hexs[0:8] + "-" + hexs[8:12] + "-" + hexs[12:16] + "-" +
		hexs[16:20] + "-" + hexs[20:32]
}
