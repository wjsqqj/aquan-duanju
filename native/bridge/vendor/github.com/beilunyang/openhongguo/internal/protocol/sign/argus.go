package sign

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/md5"
	"crypto/rand"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"math/bits"
	"strconv"
)

// 551 Argus / Ladon：取流接口（multi_video_model、video_tab）要求真实签名。
//
// 上游 2026-11 收紧后，x-argus / x-ladon 只发「时间戳的 base64 占位」时，
// 接口统一返回 HTTP 200 + 0 字节；列表/搜索接口仍接受占位签名。这里移植
// 官方客户端的两个签名器，仅供播放链路使用。
//
// 常量全部是客户端公开协议常量，不是账号凭据。
const (
	argusLicenseID = 1611921764
	argusProtoVer  = "v04.04.05-ov-android"
	argusAID       = 8662
)

var (
	// SIGN_KEY 按小端拆成 4 个轮密钥字。
	argusRoundKey = [4]uint64{
		0x740c7a65a9e078fc,
		0x03cf3c905915e58c,
		0xd732f2cfd3510e51,
		0x04531c328ae84313,
	}
	argusAESKey = mustHexBytes("d31e3718288a1027baab59f146a09a9c")
	argusAESIV  = mustHexBytes("ea180a0336ed352fcd24e4d50018ae54")
	argusMagic  = mustHexBytes("f2f7fcfff2f7fcff")
	argusSeal   = mustHexBytes("eafb2cfe8568519154")
)

// argusRandomInt32 是 protobuf tag3 的有符号随机字段。
func argusRandomInt32() int32 {
	var b [4]byte
	_, _ = rand.Read(b[:])
	return int32(binary.LittleEndian.Uint32(b[:]))
}

func mustHexBytes(s string) []byte {
	b, err := hex.DecodeString(s)
	if err != nil {
		panic("sign: bad constant " + s)
	}
	return b
}

// argusSign 生成 x-argus。
//
// query 是最终 query 原文（不含 '?'），stubHex 是实际发送 body 的 md5 十六进制
// （GET 传空串），ts 为秒级时间戳。
func argusSign(query, stubHex string, ts int64, deviceID string, randField int32) string {
	plain := argusProto(query, stubHex, ts, deviceID, randField)
	padded := pad16(plain)
	keys := simonKeySchedule(argusRoundKey)

	framed := make([]byte, 0, len(argusMagic)+len(padded)+len(argusSeal))
	framed = append(framed, argusMagic...)
	for at := 0; at < len(padded); at += 16 {
		left := binary.LittleEndian.Uint64(padded[at:])
		right := binary.LittleEndian.Uint64(padded[at+8:])
		x, y := simonEncrypt(left, right, keys)
		var out [16]byte
		binary.LittleEndian.PutUint64(out[:8], x)
		binary.LittleEndian.PutUint64(out[8:], y)
		framed = append(framed, out[:]...)
	}
	framed = append(framed, argusSeal...)
	// MAGIC 自身不参与异或，从第 9 个字节开始以 8 为周期回写。
	for i := 8; i < len(framed); i++ {
		framed[i] ^= argusMagic[i%8]
	}
	reverseBytes(framed)
	framed = append(framed, 'a', 'o')

	block, err := aes.NewCipher(argusAESKey)
	if err != nil {
		return ""
	}
	padded = pad16(framed)
	ct := make([]byte, len(padded))
	cipher.NewCBCEncrypter(block, argusAESIV).CryptBlocks(ct, padded)

	out := make([]byte, 0, 2+len(ct))
	out = append(out, 0xF2, 0x81)
	out = append(out, ct...)
	return base64.StdEncoding.EncodeToString(out)
}

// argusProto 按官方 schema 顺序写 25 个字段。
func argusProto(query, stubHex string, ts int64, deviceID string, randField int32) []byte {
	out := make([]byte, 0, 256)
	out = append(out, pbVarint(1, 1077940818)...)
	out = append(out, pbVarint(2, 2)...)
	out = append(out, pbVarint(3, uint64(uint32(randField)))...)
	out = append(out, pbBytes(4, []byte(strconv.Itoa(argusAID)))...)
	out = append(out, pbBytes(5, []byte(deviceID))...)
	out = append(out, pbBytes(6, []byte(strconv.Itoa(argusLicenseID)))...)
	out = append(out, pbBytes(7, []byte(queryValue(query, "version_name")))...)
	out = append(out, pbBytes(8, []byte(argusProtoVer))...)
	out = append(out, pbVarint(9, 134744640)...)
	out = append(out, pbBytes(10, make([]byte, 8))...)
	out = append(out, pbVarint(11, 0)...)
	out = append(out, pbVarint(12, uint64(ts)<<1)...)
	out = append(out, pbBytes(13, argusBodyHash(stubHex))...)
	out = append(out, pbBytes(14, argusQueryHash(query))...)

	inner15 := make([]byte, 0, 16)
	inner15 = append(inner15, pbVarint(1, 1)...)
	inner15 = append(inner15, pbVarint(2, 1)...)
	inner15 = append(inner15, pbVarint(3, 1)...)
	inner15 = append(inner15, pbVarint(7, 0xc792eccc)...)
	out = append(out, pbBytes(15, inner15)...)

	// 播放路径的 install_id 恒为空串，但字段必须存在（0 长度）。
	out = append(out, pbBytes(16, nil)...)
	out = append(out, pbBytes(20, []byte("none"))...)
	out = append(out, pbVarint(21, 738)...)

	inner23 := make([]byte, 0, 24)
	inner23 = append(inner23, pbBytes(1, []byte("NX551J"))...)
	inner23 = append(inner23, pbVarint(2, 8196)...)
	inner23 = append(inner23, pbVarint(4, 0x80e0d800)...)
	out = append(out, pbBytes(23, inner23)...)
	out = append(out, pbVarint(25, 2)...)
	return out
}

// argusBodyHash 是 sm3(md5(body) 的十六进制文本) 的前 6 字节；
// 空 body 用 16 个零字节做输入（不是空串）。
func argusBodyHash(stubHex string) []byte {
	in := make([]byte, 16)
	if stubHex != "" {
		if raw, err := hex.DecodeString(stubHex); err == nil && len(raw) > 0 {
			in = raw
		} else {
			in = nil
		}
	}
	sum := sm3Sum(in)
	return sum[:6]
}

func argusQueryHash(query string) []byte {
	in := make([]byte, 16)
	if query != "" {
		in = []byte(query)
	}
	sum := sm3Sum(in)
	return sum[:6]
}

// ladonSign 生成 x-ladon：base64(4 字节随机 || 34 轮 Feistel 密文)。
func ladonSign(ts int64, random [4]byte) string {
	aid := strconv.Itoa(argusAID)
	seed := append(append([]byte{}, random[:]...), []byte(aid)...)
	sum := md5.Sum(seed)
	hexText := []byte(hex.EncodeToString(sum[:]))

	w0 := binary.LittleEndian.Uint64(hexText[0:8])
	w1 := binary.LittleEndian.Uint64(hexText[8:16])
	w2 := binary.LittleEndian.Uint64(hexText[16:24])
	w3 := binary.LittleEndian.Uint64(hexText[24:32])

	table := make([]uint64, 0, 35)
	table = append(table, w0)
	queue := []uint64{w2, w3}
	b0, b8 := w0, w1
	for i := 0; i < 34; i++ {
		x8 := (bits.RotateLeft64(b8, -8) + b0) ^ uint64(i)
		queue = append(queue, x8)
		x8 ^= bits.RotateLeft64(b0, 3)
		table = append(table, x8)
		b0 = x8
		b8 = queue[0]
		queue = queue[1:]
	}

	input := pad16([]byte(fmt.Sprintf("%d-%d-%s", ts, argusLicenseID, aid)))
	out := make([]byte, len(input))
	for at := 0; at < len(input); at += 16 {
		a := binary.LittleEndian.Uint64(input[at:])
		b := binary.LittleEndian.Uint64(input[at+8:])
		for i := 0; i < 34; i++ {
			b = table[i] ^ (a + bits.RotateLeft64(b, -8))
			a = b ^ bits.RotateLeft64(a, 3)
		}
		binary.LittleEndian.PutUint64(out[at:], a)
		binary.LittleEndian.PutUint64(out[at+8:], b)
	}
	return base64.StdEncoding.EncodeToString(append(append([]byte{}, random[:]...), out...))
}

// simonKeySchedule 由 4 个种子字扩展出 72 个轮密钥。
func simonKeySchedule(seed [4]uint64) [72]uint64 {
	var k [72]uint64
	copy(k[:4], seed[:])
	for i := 4; i < 72; i++ {
		tmp := bits.RotateLeft64(k[i-1], -3) ^ k[i-3]
		tmp ^= bits.RotateLeft64(tmp, -1)
		bit := (uint64(0x3dc94c3a046d678b) >> uint((i-4)%62)) & 1
		k[i] = ^k[i-4] ^ tmp ^ bit ^ 3
	}
	return k
}

func simonEncrypt(left, right uint64, k [72]uint64) (uint64, uint64) {
	x, y := left, right
	for i := 0; i < 72; i++ {
		previous := y
		y = x ^ (bits.RotateLeft64(y, 1) & bits.RotateLeft64(y, 8)) ^ bits.RotateLeft64(y, 2) ^ k[i]
		x = previous
	}
	return x, y
}

func reverseBytes(b []byte) {
	for i, j := 0, len(b)-1; i < j; i, j = i+1, j-1 {
		b[i], b[j] = b[j], b[i]
	}
}

// pad16 是 PKCS#7 填充；整除时补满 16 个 0x10。
func pad16(data []byte) []byte {
	pad := 16 - len(data)%16
	out := make([]byte, 0, len(data)+pad)
	out = append(out, data...)
	for i := 0; i < pad; i++ {
		out = append(out, byte(pad))
	}
	return out
}

func pbVarint(tag uint32, value uint64) []byte {
	out := protoKey(tag, 0)
	return append(out, varint(value)...)
}

// pbBytes 写 length-delimited 字段；长度 0 也要写（与官方 schema 一致）。
func pbBytes(tag uint32, body []byte) []byte {
	out := protoKey(tag, 2)
	out = append(out, varint(uint64(len(body)))...)
	return append(out, body...)
}

// queryValue 取 query 里第一个 name 的值（不做解码，签名按原始字节算）。
func queryValue(query, name string) string {
	for _, part := range splitAmp(query) {
		key, value, hasEq := cutEq(part)
		if key != name {
			continue
		}
		if !hasEq {
			return ""
		}
		return value
	}
	return ""
}

func splitAmp(s string) []string {
	out := make([]string, 0, 32)
	start := 0
	for i := 0; i < len(s); i++ {
		if s[i] == '&' {
			out = append(out, s[start:i])
			start = i + 1
		}
	}
	return append(out, s[start:])
}

func cutEq(s string) (key, value string, ok bool) {
	for i := 0; i < len(s); i++ {
		if s[i] == '=' {
			return s[:i], s[i+1:], true
		}
	}
	return s, "", false
}
