package hongguov5

// ttencrypt.go — TTEncrypt 编排放置（字节跳动 device_register 的 tt-data=a 信封）。
// 大方法（hex_27E/30A/CF8/0A2）由 scripts/gen_ttencrypt.py 从 pyvendor/TTEncrypt.py
// 机械转译（ttencrypt_trace.go）；本文件是手写的外壳：ARM 旗标语义助手、SHA 变体
// 压缩驱动（calculate）、AES 变体信封组装与解包。golden.json["tt_encrypt"] 对拍。

import (
	"bytes"
	"compress/gzip"
	"crypto/aes"
	"crypto/cipher"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"strconv"
	"time"
)

var errTT = errors.New("hongguov5: ttencrypt")

// ttEngine 承载 ARM 仿真旗标（CF）。
type ttEngine struct {
	CF int
}

func (t *ttEngine) check(x uint64) uint64 { return x & 0xFFFFFFFF }

func (t *ttEngine) ADDS(a, b uint64) uint64 {
	c := (a & 0xFFFFFFFF) + (b & 0xFFFFFFFF)
	if c > 0xFFFFFFFF {
		t.CF = 1
	} else {
		t.CF = 0
	}
	return c & 0xFFFFFFFF
}

func (t *ttEngine) ADC(a, b uint64) uint64 {
	c := (a & 0xFFFFFFFF) + (b & 0xFFFFFFFF)
	return (c + uint64(t.CF)) & 0xFFFFFFFF
}

func (t *ttEngine) ADCS(a, b uint64) uint64 {
	c := (a & 0xFFFFFFFF) + (b & 0xFFFFFFFF)
	carry := uint64(0)
	if c > 0xFFFFFFFF {
		carry = 1
	}
	d := (c + uint64(t.CF)) & 0xFFFFFFFF
	t.CF = int(carry)
	return d
}

func (t *ttEngine) EORS(a, b uint64) uint64 { return (a ^ b) & 0xFFFFFFFF }
func (t *ttEngine) ANDS(a, b uint64) uint64 { return (a & b) & 0xFFFFFFFF }
func (t *ttEngine) ORRS(a, b uint64) uint64 { return (a | b) & 0xFFFFFFFF }

func (t *ttEngine) LSLS(num uint64, k int) uint64 {
	x := num & 0xFFFFFFFF
	t.CF = int((x >> uint(32-k)) & 1)
	return (x << uint(k)) & 0xFFFFFFFF
}

func (t *ttEngine) LSRS(num uint64, k int) uint64 {
	x := num & 0xFFFFFFFF
	t.CF = int((x >> uint(k-1)) & 1)
	return x >> uint(k)
}

func (t *ttEngine) RRX(num uint64) uint64 {
	x := num & 0xFFFFFFFF
	return uint64(t.CF)<<31 | x>>1
}

func (t *ttEngine) UBFX(num uint64, lsb, width int) uint64 {
	return (num >> uint(lsb)) & ((1 << uint(width)) - 1)
}

func (t *ttEngine) UTFX(num uint64) uint64 { return num & 0xFF }

// dumpList 每 4 字节拼大端 u32（dump_list）。
func (t *ttEngine) dumpList(content []uint64) []uint64 {
	size := len(content) / 4
	out := make([]uint64, 0, size)
	for index := 0; index < size; index++ {
		v := uint64(0)
		for j := 0; j < 4; j++ {
			b := content[4*index+j]
			hex2 := strconv.FormatUint(b, 16)
			if len(hex2) < 2 {
				hex2 = "0" + hex2
			}
			n, _ := strconv.ParseUint(hex2, 16, 8)
			v = v<<8 | n
		}
		out = append(out, v)
	}
	return out
}

// hexList 每值取十六进制前 8 位（不足左侧补零）→ 4 个大端字节（hex_list）。
// 值超过 8 位十六进制时取**最高** 8 位——Python 字符串切片语义，勿改。
func (t *ttEngine) hexList(content []uint64) []uint64 {
	var out []uint64
	for _, value := range content {
		tmp := strconv.FormatUint(value, 16)
		for len(tmp) < 8 {
			tmp = "0" + tmp
		}
		for i := 0; i < 4; i++ {
			n, _ := strconv.ParseUint(tmp[i*2:i*2+2], 16, 8)
			out = append(out, n)
		}
	}
	return out
}

// handle_ending：末块长度域（bitlen 低 64 位大端写入最后 8 字节）。
func (t *ttEngine) handleEnding(num uint64, r0 int) []uint64 {
	r1, r2 := num, uint64(0)
	r1 = t.ADDS(r1, uint64(r0)<<3)
	r2 = t.ADC(r2, uint64(r0)>>29)
	return t.hexList([]uint64{r2, r1})
}

// hex_C52：状态 8 对（lo,hi）→ 64 字节大端（hi 在前）。
func (t *ttEngine) hexC52(list6B0 []uint64) []uint64 {
	var out []uint64
	for i := 0; i < 8; i++ {
		out = append(out, t.hexList([]uint64{list6B0[2*i+1], list6B0[2*i]})...)
	}
	return out
}

var ttInitialState = func() []uint64 {
	out := make([]uint64, len(ttLIST6B0))
	for i, v := range ttLIST6B0 {
		out[i] = uint64(v)
	}
	return out
}()

// calculate：SHA 变体压缩（0x80 字节块；末块 8 字节长度域）。
func (t *ttEngine) calculate(content []uint64) []uint64 {
	hex6A8 := uint64(0)
	list6B0 := append([]uint64(nil), ttInitialState...)
	tmpList := append([]uint64(nil), content...)
	length := len(tmpList)
	divisible := length % 0x80
	tmp := 0x80 - divisible
	if tmp > 0x11 {
		tmpList = append(tmpList, 0x80)
		for i := 0; i < tmp-0x11; i++ {
			tmpList = append(tmpList, 0)
		}
		for j := 0; j < 16; j++ {
			tmpList = append(tmpList, 0)
		}
	} else {
		tmpList = append(tmpList, 128)
		for i := 0; i < 128-16+tmp+1; i++ {
			tmpList = append(tmpList, 0)
		}
		for j := 0; j < 16; j++ {
			tmpList = append(tmpList, 0)
		}
	}
	size := len(tmpList)
	for i := 0; i < size/0x80; i++ {
		if size/128-1 == i {
			ending := t.handleEnding(hex6A8, divisible)
			for j := 0; j < 8; j++ {
				tmpList[size-j-1] = ending[7-j]
			}
		}
		paramList := make([]uint64, 32)
		for j := 0; j < 32; j++ {
			var tmpss string
			for k := 0; k < 4; k++ {
				tmpString := strconv.FormatUint(tmpList[0x80*i+4*j+k], 16)
				if len(tmpString) < 2 {
					tmpString = "0" + tmpString
				}
				tmpss += tmpString
			}
			n, _ := strconv.ParseUint(tmpss, 16, 64)
			paramList[j] = n
		}
		list3B8 := ttHex27E(t, append([]uint64(nil), paramList...))
		list6B0 = ttHex30A(t, list6B0, list3B8)
		hex6A8 += 0x400
	}
	return t.hexC52(list6B0)
}

// ttEncryptWithContent：对已就绪的 gzip 内容（头 10 字节已被替换为规范头）+
// 32B nonce 组帧。Go 与 zlib 的 deflate 字节可以不同（服务器只解压不比对），
// 黄金对拍用 python 提供的同一 content。
func ttEncryptWithContent(content []byte, nonce []byte) ([]byte, error) {
	if len(nonce) != 32 {
		return nil, fmt.Errorf("%w: nonce-size", errTT)
	}
	engine := &ttEngine{}
	toU64 := func(b []byte) []uint64 {
		out := make([]uint64, len(b))
		for i, v := range b {
			out[i] = uint64(v)
		}
		return out
	}
	hash64 := engine.calculate(toU64(content))
	ab0 := make([]uint64, 0, len(hash64)+len(content))
	ab0 = append(ab0, hash64...)
	ab0 = append(ab0, toU64(content)...)
	differ := 0x10 - len(ab0)%0x10
	for i := 0; i < differ; i++ {
		ab0 = append(ab0, uint64(differ))
	}
	list0B0 := append(engine.calculate(toU64(nonce)), ttOrdListAsU64()...)
	list5D8 := engine.calculate(list0B0)
	list378Array := engine.dumpList(list5D8[0:0x10])
	list740 := append([]uint64(nil), list5D8[0x10:0x20]...)
	list55C := ttHexCF8(engine, append([]uint64(nil), list378Array...))
	finalList := ttHex0A2(engine, ab0, list740, list55C)

	frame := make([]byte, 0, len(ttBegining)+32+len(finalList))
	for _, v := range ttBegining {
		frame = append(frame, byte(v))
	}
	frame = append(frame, nonce...)
	for _, v := range finalList {
		frame = append(frame, byte(v%256))
	}
	return frame, nil
}

func ttOrdListAsU64() []uint64 {
	out := make([]uint64, len(ttOrdList))
	for i, v := range ttOrdList {
		out[i] = uint64(v)
	}
	return out
}

// ttEncrypt：gzip(level 9, mtime 0) + 规范头替换 + 组帧。nonce 取
// crypto/rand（对齐 python random 语义；测试注入固定值）。
func ttEncrypt(payload []byte, nonce []byte) ([]byte, error) {
	var buf bytes.Buffer
	gw, err := gzip.NewWriterLevel(&buf, gzip.BestCompression)
	if err != nil {
		return nil, err
	}
	// Python mtime=0：头部 MTIME/OS 与 deflate 内容随后整体被规范头覆盖前 10 字节，
	// 但 deflate 体仍是本实现输出——服务器只解压，不比对字节。
	gw.Header.ModTime = time.Time{}
	if _, err := gw.Write(payload); err != nil {
		return nil, err
	}
	if err := gw.Close(); err != nil {
		return nil, err
	}
	content := buf.Bytes()
	if len(content) < 10 {
		return nil, fmt.Errorf("%w: gzip-short", errTT)
	}
	copy(content[:10], []byte{31, 139, 8, 0, 0, 0, 0, 0, 0, 0})
	return ttEncryptWithContent(content, nonce)
}

// ttDecrypt：解 tt-data=a 帧（注册响应 tc\x05\x10 载荷）。
func ttDecrypt(frame []byte) (string, error) {
	if len(frame) < 38+16 {
		return "", fmt.Errorf("%w: frame-short", errTT)
	}
	engine := &ttEngine{}
	nonce := frame[6:38]
	body := frame[38:]
	list0B0 := append(engine.calculate(toU64Slice(nonce)), ttOrdListAsU64()...)
	list5D8 := engine.calculate(list0B0)
	keyWords := engine.dumpList(list5D8[0:0x10])
	keyBytes := engine.hexList(keyWords)
	key := make([]byte, len(keyBytes))
	for i, v := range keyBytes {
		key[i] = byte(v)
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return "", err
	}
	if len(body) < 16 || len(body)%16 != 0 {
		return "", fmt.Errorf("%w: cipher-size", errTT)
	}
	iv := make([]byte, 16)
	copy(iv, body[:16])
	mode := cipher.NewCBCDecrypter(block, iv)
	plain := make([]byte, len(body)-16)
	mode.CryptBlocks(plain, body[16:])
	// PKCS7 去尾（aes_decrypt: decoded[:-decoded[-1]]）。
	if n := len(plain); n > 0 {
		pad := int(plain[n-1])
		if pad > 0 && pad <= 16 && n-pad >= 0 {
			plain = plain[:n-pad]
		}
	}
	// ([0]*16 + decrypted)[64:] → decrypted[48:]
	if len(plain) < 48 {
		return "", fmt.Errorf("%w: plain-short", errTT)
	}
	reader, err := gzip.NewReader(bytes.NewReader(plain[48:]))
	if err != nil {
		return "", fmt.Errorf("%w: %v", errTT, err)
	}
	defer reader.Close()
	out, err := io.ReadAll(reader)
	if err != nil {
		return "", fmt.Errorf("%w: %v", errTT, err)
	}
	return string(out), nil
}

func toU64Slice(b []byte) []uint64 {
	out := make([]uint64, len(b))
	for i, v := range b {
		out[i] = uint64(v)
	}
	return out
}

var _ = binary.LittleEndian // 占位（binary 用于其他 wire 路径）
