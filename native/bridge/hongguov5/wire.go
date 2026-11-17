package hongguov5

// wire.go — v5 线材原语（移植自 sidecar v5wire.py；常量/置换表/帧形状为
// 公开逆向互操作事实，实现结构对拍 golden.json）。sm3 优先原生实现。

import (
	"crypto/md5"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
)

const wireMask32 = 0xFFFFFFFF

var (
	medusaConstants   = [4]uint32{0xCA025DDC, 0x823DC546, 0xC9420583, 0xC298225F}
	v5RoundConstants  = [4]uint32{0xBBB5DE72, 0xD4638D5B, 0x92A5F73B, 0x89F8A1C9}
	v5RowOrders       = [4][4]int{{2, 0, 3, 1}, {1, 3, 2, 0}, {3, 2, 1, 0}, {2, 3, 1, 0}}
	v5LastColumn      = [4][4]int{{15, 7, 3, 11}, {11, 3, 15, 7}, {3, 15, 11, 7}, {15, 3, 11, 7}}
	v5SourceBits      = [8]int{6, 5, 3, 4, 2, 7, 1, 0}
	v5PackedBits      = [8]int{1, 7, 3, 6, 2, 0, 4, 5}
	v5SuffixTable     = [8]byte{0x84, 0x96, 0x77, 0x9d, 0xd4, 0x15, 0x0b, 0xf8}
	v5BranchBiases    = [5]uint32{0x8980F29B, 0xEB549C7F, 0xB08726DB, 0xD40CB5E6, 0xE8F559E4}
	digestBranchIV    = [4]uint32{0x79E0F2FB, 0xC8B52570, 0xEBC2F8CD, 0x7C104D93}
	digestBranchFinsh = [4]uint32{0x19BE4866, 0xE85986B4, 0xE19B326E, 0x71D1D7D4}
	digestShifts      = [4][4]int{{7, 12, 17, 22}, {5, 9, 14, 20}, {4, 11, 16, 23}, {6, 10, 15, 21}}
)

var errWire = errors.New("hongguov5: wire")

// ---- 置换表（medusa_wire_tables.json 单一事实源，go:embed） ----

type wireTables struct {
	Variants []struct {
		Box   string `json:"box"`
		Rows  []int  `json:"rows"`
		Shift []int  `json:"shift"`
	} `json:"variants"`
	DigestIndices        string  `json:"digestIndices"`
	DigestRoundConstants []int64 `json:"digestRoundConstants"`
}

var tables = func() *wireTables {
	raw, err := embeddedTables()
	if err != nil {
		panic("hongguov5: " + err.Error())
	}
	var t wireTables
	if err := json.Unmarshal(raw, &t); err != nil {
		panic("hongguov5: tables: " + err.Error())
	}
	return &t
}()

// ---- selector / checksum（v3/v5 共用摘要分支路由） ----

func selector(queryDigest, bodyDigest []byte, seconds uint32) uint32 {
	value := uint32(0x20230928)
	for _, part := range [][]byte{queryDigest, bodyDigest, le32(seconds)} {
		for index, b := range part {
			if index%2 == 1 {
				value = ^(value ^ (value >> 7) ^ ((value << 12) | uint32(b))) & wireMask32
			} else {
				value = (value ^ (value >> 4) ^ (value << 6) ^ uint32(b)) & wireMask32
			}
		}
	}
	return value
}

func checksum(value []byte) uint32 {
	result := uint32(0x20220420)
	for index, b := range value[:min(12, len(value))] {
		if index%2 == 1 {
			result = (result ^ (result >> 5) ^ (^((result << 11) | uint32(b)))) & wireMask32
		} else {
			result = (result ^ (result >> 3) ^ (result << 7) ^ uint32(b)) & wireMask32
		}
	}
	return ((result | 4) ^ 0x01000000) & wireMask32
}

// rol32 匹配 Python _rol32：bits 可为负（先归一到 [0,32)）。
func rol32(value uint32, bits int) uint32 {
	value &= wireMask32
	bits = ((bits % 32) + 32) % 32
	return ((value << bits) | (value >> (32 - bits))) & wireMask32
}

// digestBranchTwo v3 medusa 摘要分支二（v5 主链不经过；保留以防服务端回摆）。
func digestBranchTwo(queryDigest, bodyDigest []byte, seconds uint32) ([]byte, error) {
	choice := selector(queryDigest, bodyDigest, seconds)
	if (choice&15)%3 != 2 {
		return nil, fmt.Errorf("%w: unsupported-digest-branch", errWire)
	}
	variant := int(((choice & 13) * 86) >> 8)
	seed := seconds + v5BranchBiases[variant]
	shift := int((seed + 5) & 7)
	suffix := make([]byte, len(v5SuffixTable))
	for i, v := range v5SuffixTable {
		suffix[i] = byte(((v >> shift) | (v << (8 - shift))) & 255)
	}
	message := make([]byte, 0, 64)
	message = append(message, queryDigest...)
	message = append(message, bodyDigest...)
	message = append(message, le32(seconds)...)
	message = append(message, suffix...)
	message = append(message, le32(416)...)
	var words [16]uint32
	for i := range words {
		words[i] = binary.LittleEndian.Uint32(message[i*4 : i*4+4])
	}
	var iv [4]uint32
	for i := range iv {
		iv[i] = rol32(digestBranchIV[i], -int(seed))
	}
	var finish [4]uint32
	for i := range finish {
		finish[i] = rol32(digestBranchFinsh[i], -int((seed+6)&255))
	}
	a, b, c, d := iv[0], iv[1], iv[2], iv[3]
	indices, err := digestIndices(variant)
	if err != nil {
		return nil, err
	}
	for step := 0; step < 64; step++ {
		phase := step / 16
		var f uint32
		switch phase {
		case 0:
			f = (b & c) | (^b & d)
		case 1:
			f = (b & d) | (c & ^d)
		case 2:
			f = b ^ c ^ d
		default:
			f = c ^ (b | ^d)
		}
		constant := rol32(uint32(tables.DigestRoundConstants[step])&wireMask32, -int((seed+1)&255))
		result := (b + rol32(a+f+words[indices[step]]+constant, digestShifts[phase][step%4])) & wireMask32
		a, d, c, b = d, c, b, result
	}
	out := make([]byte, 16)
	for i, v := range [4]uint32{a, b, c, d} {
		binary.LittleEndian.PutUint32(out[i*4:], ((v+iv[i])&wireMask32)^finish[i])
	}
	return append(out, le32(checksum(out))...), nil
}

func digestIndices(variant int) ([]int, error) {
	raw, err := decodeHex(tables.DigestIndices)
	if err != nil {
		return nil, err
	}
	if variant < 0 || (variant+1)*64 > len(raw) {
		return nil, fmt.Errorf("%w: digest-indices-variant", errWire)
	}
	out := make([]int, 64)
	for i := 0; i < 64; i++ {
		out[i] = int(raw[variant*64+i])
	}
	return out, nil
}

// ---- 字节杂项 ----

func le16(v uint32) []byte {
	return []byte{byte(v), byte(v >> 8)}
}

func xorBytes(a, b []byte) ([]byte, error) {
	if len(a) != len(b) {
		return nil, fmt.Errorf("%w: length-mismatch", errWire)
	}
	out := make([]byte, len(a))
	for i := range a {
		out[i] = a[i] ^ b[i]
	}
	return out, nil
}

func twice(v byte) byte {
	if v&128 != 0 {
		return (v << 1) ^ 0x11B&255
	}
	return v << 1
}

func rotateByte(value byte, bits int) byte {
	v := uint32(value & 255)
	b := uint32(bits)
	return byte(((v << b) | (v >> (8 - b))) & 255)
}

// ---- 置乱（medusa/v5 envelope 共用） ----

func deriveScrambleKey(seed []byte, nonce uint32) ([]byte, []byte) {
	buf := make([]byte, 0, len(seed)+4+len(seed))
	buf = append(buf, seed...)
	buf = append(buf, le32(nonce)...)
	buf = append(buf, seed...)
	digest := sm3(buf)
	b := byte((nonce >> 16) & 255)
	mask := ^((((nonce >> 5) & 0x7F800) | (nonce >> 24)) ^ (uint32(b) >> 5) ^ uint32(b)) & wireMask32
	return digest, le32(mask)
}

func scramble(payload, key []byte) ([]byte, error) {
	if len(payload) < 4 || len(key) != 32 {
		return nil, fmt.Errorf("%w: invalid-scramble-input", errWire)
	}
	transformed := make([]byte, len(payload))
	for index, value := range payload {
		a, b := key[(index%8)*4], key[(index%8)*4+1]
		rot4 := rotateByte(value, 4)
		middle := rotateByte(byte((^(uint32(rot4)+uint32(a)))^uint32(b))&255, 3)
		transformed[index] = byte((^uint32(uint32(middle)+uint32(b)) ^ uint32(a)) & 255)
	}
	out := make([]byte, len(transformed))
	for i := range transformed {
		out[i] = transformed[len(transformed)-1-i]
	}
	originalFirst := out[0]
	edge := out[len(out)-1] ^ out[len(out)-2]
	out[0] = byte((uint32(out[0]) + (^uint32(edge) & 255)) & 255)
	out[1] = byte((uint32(out[1]) + ((uint32(out[len(out)-1]) ^ uint32(out[0]) ^ 0xFE) & 255)) & 255)
	out[2] = byte((uint32(out[2]) + (((uint32(edge) - uint32(originalFirst)) & 255) ^ uint32(rotateByte(out[1], 3)) ^ 2)) & 255)
	for index := 3; index < len(out)-1; index++ {
		mix := uint32(out[index-2]) ^ uint32(rotateByte(out[index-1], 3)) ^ uint32(index)
		out[index] = byte((uint32(out[index]) + (^mix & 255)) & 255)
	}
	out[len(out)-1] ^= out[len(out)-2]
	sum := 0
	for _, v := range out[1:] {
		sum += int(v)
	}
	out[0] = byte(((uint32(out[0]) ^ uint32(out[1])) + uint32(sum)) & 255)
	return out, nil
}

// ---- medusa v3 线材密码（V5BlockCipher 共用 block 逻辑） ----

type medusaCipher struct {
	box   [256]byte
	rows  [4]int
	shift [16]int
	keys  [3][16]byte
}

func (m *medusaCipher) addKey(state, key []byte) []byte {
	out := make([]byte, 16)
	for row := 0; row < 4; row++ {
		for col := 0; col < 4; col++ {
			out[row*4+col] = state[row*4+col] ^ key[row*4+m.rows[col]]
		}
	}
	return out
}

func (m *medusaCipher) block(block []byte) ([]byte, error) {
	if len(block) != 16 {
		return nil, fmt.Errorf("%w: invalid-block", errWire)
	}
	state := m.addKey(block, m.keys[0][:])
	for step := 1; step <= 2; step++ {
		sub := make([]byte, 16)
		for i, v := range state {
			sub[i] = m.box[v]
		}
		reordered := make([]byte, 16)
		for row := 0; row < 4; row++ {
			copy(reordered[row*4:row*4+4], sub[m.rows[row]*4:m.rows[row]*4+4])
		}
		state = make([]byte, 16)
		for i, idx := range m.shift {
			state[i] = reordered[idx]
		}
		if step == 1 {
			mixed := make([]byte, 16)
			for row := 0; row < 4; row++ {
				for col := 0; col < 4; col++ {
					mixed[row*4+col] = state[row*4+m.rows[col]]
				}
			}
			state = mixed
			output := make([]byte, 16)
			for col := 0; col < 4; col++ {
				column := [4]byte{state[col], state[4+col], state[8+col], state[12+col]}
				total := column[0] ^ column[1] ^ column[2] ^ column[3]
				for row := 0; row < 4; row++ {
					output[row*4+col] = column[row] ^ total ^ twice(column[row]^column[(row+1)%4])
				}
			}
			state = output
		}
		state = m.addKey(state, m.keys[step][:])
	}
	return xorBytes(state, m.keys[1][:])
}

func medusaCipherFromTables(key []byte, seconds uint32) (*medusaCipher, error) {
	if len(key) != 16 {
		return nil, fmt.Errorf("%w: invalid-wire-key", errWire)
	}
	variant := seconds % 4
	box, rows, shift, err := variantTable(int(variant))
	if err != nil {
		return nil, err
	}
	m := &medusaCipher{}
	for i, r := range rows {
		m.rows[i] = r
	}
	for i, v := range shift {
		m.shift[i] = v
	}
	copy(m.box[:], box)
	constant := medusaConstants[variant]
	initial, err := xorBytes(key, repeatLE(constant, 4))
	if err != nil {
		return nil, err
	}
	words := make([][]byte, 12)
	for i := 0; i < 4; i++ {
		words[i] = initial[i*4 : i*4+4]
	}
	for i := 4; i < 12; i++ {
		word := append([]byte(nil), words[i-1]...)
		if i%4 == 0 {
			rotated := append(append([]byte(nil), word[1:]...), word[0])
			for j := range rotated {
				rotated[j] = m.box[rotated[j]]
			}
			rotated[0] ^= byte((constant >> ((2 * i) & 24)) & 255)
			word = rotated
		}
		mixed, err := xorBytes(words[i-4], word)
		if err != nil {
			return nil, err
		}
		words[i] = mixed
	}
	for k := 0; k < 3; k++ {
		for j := 0; j < 4; j++ {
			copy(m.keys[k][j*4:], words[k*4+j])
		}
	}
	return m, nil
}

// ---- v5 线材密码 ----

type v5BlockCipher struct {
	medusaCipher
}

func newV5BlockCipher(key, substitution []byte, variant int) (*v5BlockCipher, error) {
	if len(key) != 16 || len(substitution) != 256 || variant < 0 || variant >= 4 {
		return nil, fmt.Errorf("%w: invalid-wire-cipher-init", errWire)
	}
	m := &v5BlockCipher{}
	copy(m.box[:], substitution)
	m.rows = v5RowOrders[variant]
	for index := 0; index < 16; index++ {
		if index%4 == 3 {
			m.shift[index] = v5LastColumn[variant][index/4]
		} else {
			m.shift[index] = (index + []int{0, 8, 12}[index%4]) % 16
		}
	}
	constant := v5RoundConstants[variant]
	initial, err := xorBytes(key, repeatLE(constant, 4))
	if err != nil {
		return nil, err
	}
	words := make([][]byte, 12)
	for i := 0; i < 4; i++ {
		words[i] = initial[i*4 : i*4+4]
	}
	for index := 4; index < 12; index++ {
		previous := append([]byte(nil), words[index-1]...)
		if index%4 == 0 {
			rotated := append(append([]byte(nil), previous[1:]...), previous[0])
			for i := range rotated {
				rotated[i] = m.box[rotated[i]]
			}
			roundByte := byte((constant >> ((2 * index) & 24)) & 255)
			rotated[0] ^= roundByte
			previous = rotated
		}
		mixed, err := xorBytes(words[index-4], previous)
		if err != nil {
			return nil, err
		}
		words[index] = mixed
	}
	for k := 0; k < 3; k++ {
		for j := 0; j < 4; j++ {
			copy(m.keys[k][j*4:], words[k*4+j])
		}
	}
	return m, nil
}

// compactCipherV5 采样位打包 → 双块加密（envelope_v5 内核）。
func compactCipherV5(payload []byte, seconds uint32, keyMaterial, substitutionTables []byte) ([]byte, error) {
	if len(payload) < 248 || len(keyMaterial) != 32 || len(substitutionTables) != 1024 {
		return nil, fmt.Errorf("%w: invalid-wire-payload", errWire)
	}
	sampled := make([]byte, 32)
	for group := 0; group < 31; group++ {
		acc := 0
		for bit := 0; bit < 8; bit++ {
			acc += int((payload[group*8+bit]>>v5SourceBits[bit])&1) << v5PackedBits[bit]
		}
		sampled[group] = byte(acc)
	}
	sampled[31] = 1
	variant := int(seconds & 3)
	cipher, err := newV5BlockCipher(md5Sum(keyMaterial[:16]), substitutionTables[variant*256:(variant+1)*256], variant)
	if err != nil {
		return nil, err
	}
	tail, err := xorBytes(sampled[:16], md5Sum(keyMaterial[16:]))
	if err != nil {
		return nil, err
	}
	first, err := cipher.block(tail)
	if err != nil {
		return nil, err
	}
	second, err := xorBytes(sampled[16:], first)
	if err != nil {
		return nil, err
	}
	out, err := cipher.block(second)
	if err != nil {
		return nil, err
	}
	return append(first, out...), nil
}

// envelopeV5 medusa v5 信封（X-Medusa 头）。
func envelopeV5(proto, queryDigest, bodyProof []byte, seconds uint32, keyNonce, frameNonce uint32,
	seed, frame, prefix, substitutionTables []byte) (string, error) {
	if len(queryDigest) != 32 || len(bodyProof) != 20 || len(seed) != 32 ||
		len(frame) != 16 || len(prefix) != 8 || len(substitutionTables) != 1024 {
		return "", fmt.Errorf("%w: invalid-wire-component", errWire)
	}
	if len(proto) < 229 || len(proto) > 1<<20 {
		return "", fmt.Errorf("%w: invalid-proof-message", errWire)
	}
	key, mask := deriveScrambleKey(seed, keyNonce)
	scrambled, err := scramble(proto, key)
	if err != nil {
		return "", err
	}
	mixed := make([]byte, 0, len(prefix)+len(scrambled))
	mixed = append(mixed, prefix...)
	mixed = append(mixed, scrambled...)
	// bytes(reversed(...)) + 逐字节 XOR mask[(~index)&3]
	for i, j := 0, len(mixed)-1; i < j; i, j = i+1, j-1 {
		mixed[i], mixed[j] = mixed[j], mixed[i]
	}
	for index := range mixed {
		mixed[index] ^= mask[uint32((3-index)%4)&3]
	}
	flags := uint32(0x18000001 | ((uint32(queryDigest[0]) & 63) << 14) | ((uint32(bodyProof[0]) & 63) << 8))
	payload := make([]byte, 0, 19+len(proto))
	payload = append(payload, 0xCA)
	payload = append(payload, le32(frameNonce)...)
	payload = append(payload, le32(flags)...)
	payload = append(payload, mixed...)
	payload = append(payload, le16(keyNonce>>16)...)
	encrypted, err := compactCipherV5(payload, seconds, seed, substitutionTables)
	if err != nil {
		return "", err
	}
	for group := 0; group < 31; group++ {
		for offset, sourceBit := range v5SourceBits {
			index := group*8 + offset
			bit := (encrypted[group] >> v5PackedBits[offset]) & 1
			payload[index] = (payload[index] &^ (1 << sourceBit)) | (bit << sourceBit)
		}
	}
	frameXor, err := xorBytes(frame, repeatLE(seconds, 4))
	if err != nil {
		return "", err
	}
	result := make([]byte, 0, 11+2+2+1+len(payload))
	result = append(result, le32(seconds^5)...)
	result = append(result, frameXor...)
	result = append(result, le16(keyNonce&65535)...)
	result = append(result, 0x00, 0x01)
	result = append(result, encrypted[len(encrypted)-1])
	result = append(result, payload...)
	return base64.StdEncoding.EncodeToString(result), nil
}

// ---- v5 摘要与 gorgon ----

// digestV5 = SDK 核心（Unicorn）前缀 + checksum；core 回调由 digestcore 提供。
func digestV5(query, body []byte, seconds uint32,
	core func(payload []byte, mode int, seconds uint32) ([]byte, error)) ([]byte, error) {
	queryHash := sm3(query)
	bodyHash := make([]byte, 16)
	if len(body) > 0 {
		bodyHash = md5Sum(body)
	}
	mode := int(selector(queryHash, bodyHash, seconds) & 15)
	payload := make([]byte, 0, 52)
	payload = append(payload, queryHash...)
	payload = append(payload, bodyHash...)
	payload = append(payload, le32(seconds)...)
	prefix, err := core(payload, mode, seconds)
	if err != nil {
		return nil, err
	}
	if len(prefix) != 16 {
		return nil, fmt.Errorf("%w: invalid-sdk-core-result", errWire)
	}
	return append(prefix, le32(checksum(prefix)|0x20)...), nil
}

func gorgonV5(query, body []byte, seconds uint32, nonce uint16, flags [2]byte) string {
	queryHash := md5Sum(query)[:4]
	bodyHash := make([]byte, 4)
	if len(body) > 0 {
		bodyHash = md5Sum(body)[:4]
	}
	payload := make([]byte, 0, 20)
	payload = append(payload, queryHash...)
	payload = append(payload, bodyHash...)
	payload = append(payload, 0, 0, 0, 0)
	payload = append(payload, 0x00, 0x03, 0x0A, 0x04)
	payload = append(payload, byte(seconds>>24), byte(seconds>>16), byte(seconds>>8), byte(seconds))
	key := []byte{0x4A, flags[0], 0x16, byte(nonce >> 8), 0x47, 0x6C, flags[1], byte(nonce)}
	encrypted := rc4(key, payload)
	transformed := xgorgonHandle(encrypted)
	frame := append([]byte{0x84, 0x04}, le16(uint32(nonce))...)
	frame = append(frame, flags[0], flags[1])
	return hexEncode(append(frame, transformed...))
}

// ---- 杂项助手 ----

func repeatLE(v uint32, count int) []byte {
	raw := le32(v)
	out := make([]byte, 0, 4*count)
	for i := 0; i < count; i++ {
		out = append(out, raw...)
	}
	return out
}

func md5Sum(data []byte) []byte {
	sum := md5.Sum(data)
	return sum[:]
}

func hexEncode(data []byte) string {
	const digits = "0123456789abcdef"
	out := make([]byte, len(data)*2)
	for i, v := range data {
		out[i*2] = digits[v>>4]
		out[i*2+1] = digits[v&15]
	}
	return string(out)
}

func decodeHex(s string) ([]byte, error) {
	if len(s)%2 != 0 {
		return nil, fmt.Errorf("%w: odd-hex", errWire)
	}
	out := make([]byte, len(s)/2)
	for i := 0; i < len(out); i++ {
		hi, lo := hexVal(s[i*2]), hexVal(s[i*2+1])
		if hi < 0 || lo < 0 {
			return nil, fmt.Errorf("%w: bad-hex", errWire)
		}
		out[i] = byte(hi<<4 | lo)
	}
	return out, nil
}

func hexVal(c byte) int {
	switch {
	case '0' <= c && c <= '9':
		return int(c - '0')
	case 'a' <= c && c <= 'f':
		return int(c-'a') + 10
	case 'A' <= c && c <= 'F':
		return int(c-'A') + 10
	}
	return -1
}

func variantTable(variant int) (box []byte, rows, shift []int, err error) {
	if variant < 0 || variant >= len(tables.Variants) {
		return nil, nil, nil, fmt.Errorf("%w: table-variant", errWire)
	}
	entry := tables.Variants[variant]
	box, err = base64.StdEncoding.DecodeString(entry.Box)
	if err != nil {
		return nil, nil, nil, err
	}
	if len(entry.Rows) != 4 || len(entry.Shift) != 16 {
		return nil, nil, nil, fmt.Errorf("%w: table-shape", errWire)
	}
	return box, entry.Rows, entry.Shift, nil
}
