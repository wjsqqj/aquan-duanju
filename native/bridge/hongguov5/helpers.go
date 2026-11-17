package hongguov5

// helpers.go — 字节编码小工具（构建标签无关，digestcore 两变体共用）。

import (
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
)

func le32(v uint32) []byte {
	var b [4]byte
	binary.LittleEndian.PutUint32(b[:], v)
	return b[:]
}

func le32pack(v uint32) []byte { return le32(v) }

func le64(v uint64) []byte {
	var b [8]byte
	binary.LittleEndian.PutUint64(b[:], v)
	return b[:]
}

func le64pack(v int64) []byte { return le64(uint64(v)) }

func be32pack(v uint32) []byte {
	return []byte{byte(v >> 24), byte(v >> 16), byte(v >> 8), byte(v)}
}

func sdkString(vtable uint64, capacity, length uint32, data uint64) []byte {
	out := le64(vtable)
	out = append(out, le32pack(capacity)...)
	out = append(out, le32pack(length)...)
	out = append(out, le64(data)...)
	return out
}

// pyMod 复刻 Python 的非负取模语义（Go 的 % 对负数向零截断）。
func pyMod(v, m int) int {
	r := v % m
	if r < 0 {
		r += m
	}
	return r
}

func bytesFill(v byte, n int) []byte {
	out := make([]byte, n)
	for i := range out {
		out[i] = v
	}
	return out
}

func sha256Hex(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}
