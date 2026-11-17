package hongguov5

// xgorgon.go — Gorgon 载荷字节变换（移植自 pyvendor/XGorgon.__handle；
// v5 只使用该变换，calculate 旧路径不移植）。

// xgorgonHandle 对 20 字节载荷做逐位变换，输出 20 字节。
func xgorgonHandle(input []byte) []byte {
	const length = 20
	if len(input) != length {
		panic("hongguov5: xgorgon-handle-size")
	}
	out := append([]byte(nil), input...)
	for i := 0; i < length; i++ {
		a := out[i]
		b := reverseNibble(a)
		c := out[(i+1)%length]
		d := b ^ c
		e := rbit8(d)
		f := e ^ length
		g := ^uint32(f) & 0xFFFFFFFF
		// Python int(hex(G)[-2:], 16)：G ≥ 0xFFFFFF00（f ≤ 255）恒成立，
		// 尾两位即低字节十六进制。
		out[i] = byte(g & 0xFF)
	}
	return out
}

// reverseNibble 等价 __reverse：交换高低半字节（hex 字符串往返）。
func reverseNibble(num byte) byte {
	return (num<<4)&0xF0 | (num>>4)&0x0F
}

// rbit8 等价 __RBIT：8 位内按位反转。
func rbit8(num byte) byte {
	var result byte
	for i := 0; i < 8; i++ {
		result |= (num >> i & 1) << (7 - i)
	}
	return result
}
