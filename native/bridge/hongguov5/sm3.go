// Package hongguov5 是红果 v5 匿名取流协议的 Go 原生实现（移植自
// native/bridge/hongguo-sidecar/ 的 Python sidecar，黄金对拍基准见
// testdata/golden.json 与 scripts/v5_golden.py）。移植动机：安卓运行时没有
// Python，v5 sidecar 在安卓上必然静默失败（403 回退 web）。
package hongguov5

// sm3.go — 纯 Go SM3（GB/T 32905-2016），移植自 sidecar v5wire._sm3_pure；
// 标准向量与多长度样本在 golden.json["sm3"] 对拍。

import "encoding/binary"

var sm3IV = [8]uint32{
	0x7380166F, 0x4914B2B9, 0x172442D7, 0xDA8A0600,
	0xA96F30BC, 0x163138AA, 0xE38DEE4D, 0xB0FB0E4E,
}

func sm3rol(x, n uint32) uint32 {
	n %= 32
	return (x << n) | (x >> (32 - n))
}

func sm3ff(a, b, c uint32, i int) uint32 {
	if i < 16 {
		return a ^ b ^ c
	}
	return (a & b) | (a & c) | (b & c)
}

func sm3gg(a, b, c uint32, i int) uint32 {
	if i < 16 {
		return a ^ b ^ c
	}
	return (a & b) | (^a & c)
}

func sm3p0(x uint32) uint32 { return x ^ sm3rol(x, 9) ^ sm3rol(x, 17) }
func sm3p1(x uint32) uint32 { return x ^ sm3rol(x, 15) ^ sm3rol(x, 23) }

// sm3 计算摘要；与 hashlib.new("sm3") 逐字节一致（golden 对拍）。
func sm3(data []byte) []byte {
	const digestSize = 32
	bitlen := uint64(len(data)) * 8
	msg := make([]byte, 0, len(data)+72)
	msg = append(msg, data...)
	msg = append(msg, 0x80)
	for len(msg)%64 != 56 {
		msg = append(msg, 0)
	}
	var lenBuf [8]byte
	binary.BigEndian.PutUint64(lenBuf[:], bitlen)
	msg = append(msg, lenBuf[:]...)

	t := make([]uint32, 64)
	for i := range t {
		if i < 16 {
			t[i] = 0x79CC4519
		} else {
			t[i] = 0x7A879D8A
		}
	}

	var w [132]uint32
	v := sm3IV
	for off := 0; off < len(msg); off += 64 {
		for i := 0; i < 16; i++ {
			w[i] = binary.BigEndian.Uint32(msg[off+i*4 : off+i*4+4])
		}
		for i := 16; i < 68; i++ {
			a := w[i-16] ^ w[i-9] ^ sm3rol(w[i-3], 15)
			a ^= sm3rol(a, 15) ^ sm3rol(a, 23)
			w[i] = a ^ sm3rol(w[i-13], 7) ^ w[i-6]
		}
		for i := 0; i < 64; i++ {
			w[68+i] = w[i] ^ w[i+4]
		}
		a, b, c, d, e, f, g, h := v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7]
		for i := 0; i < 64; i++ {
			ss1 := sm3rol(sm3rol(a, 12)+e+sm3rol(t[i], uint32(i)), 7)
			ss2 := ss1 ^ sm3rol(a, 12)
			tt1 := sm3ff(a, b, c, i) + d + ss2 + w[68+i]
			tt2 := sm3gg(e, f, g, i) + h + ss1 + w[i]
			d = c
			c = sm3rol(b, 9)
			b = a
			a = tt1
			h = g
			g = sm3rol(f, 19)
			f = e
			e = sm3p0(tt2)
		}
		v[0] ^= a
		v[1] ^= b
		v[2] ^= c
		v[3] ^= d
		v[4] ^= e
		v[5] ^= f
		v[6] ^= g
		v[7] ^= h
	}
	out := make([]byte, 0, digestSize)
	for _, x := range v {
		var buf [4]byte
		binary.BigEndian.PutUint32(buf[:], x)
		out = append(out, buf[:]...)
	}
	return out
}
