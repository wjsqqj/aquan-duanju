package hongguov5

// rc4.go — 标准 RC4（pycryptodome ARC4 等价实现，golden 对拍覆盖 gorgon/ladon 链）。

func rc4(key, data []byte) []byte {
	var s [256]byte
	for i := range s {
		s[i] = byte(i)
	}
	var j byte
	for i := 0; i < 256; i++ {
		j += s[i] + key[i%len(key)]
		s[i], s[j] = s[j], s[i]
	}
	out := make([]byte, len(data))
	var i, k byte
	for n, v := range data {
		i++
		k += s[i]
		s[i], s[k] = s[k], s[i]
		out[n] = v ^ s[byte(s[i]+s[k])]
	}
	return out
}
