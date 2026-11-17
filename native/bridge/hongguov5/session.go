package hongguov5

// session.go — v5 会话与播放签名（移植自 sidecar v5session.py）：
// mssdk get_token 交换（XTEA 链 + AES-CBC + CRC16 + zlib）→ 会话持久化 →
// 播放请求 v5 签名（stub argus/ladon + gorgon_v5 + helios(646637794) +
// envelope_v5）→ multi_video_model/player/v1。查询串/JSON 键序手工保序。

import (
	"bytes"
	"compress/gzip"
	"crypto/aes"
	"crypto/cipher"
	"crypto/sha256"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"hash/crc64"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const (
	sdkVersion    = "v04.10.03-ml-android"
	sdkCode       = uint32(0x040A0300)
	bootstrapHost = "mssdk.zijieapi.com"
	bootstrapPath = "/sdi/get_token"
	playbackHost  = "api5-normal-sinfonlineb.fqnovel.com"
	playbackPath  = "/novel/player/multi_video_model/player/v1"
	maxPlain      = 65536
	licenseHelios = int64(646637794)
)

const xteaDelta = 0x9E3779B9

var (
	errSession = errors.New("hongguov5: session")
	httpClient = &http.Client{
		Transport: &http.Transport{Proxy: nil}, // 直连（sidecar 语义：不走系统代理）
		Timeout:   30 * time.Second,
	}
)

// ---- XTEA 链（自定义块长/轮数/链式反馈） ----

func xteaChain(data, key, nonce []byte, decrypt bool) ([]byte, error) {
	if len(data) == 0 || len(data)%8 != 0 || len(data) > maxPlain*2 {
		return nil, fmt.Errorf("%w: invalid-xtea-blocks", errSession)
	}
	if len(key) != 16 || len(nonce) != 4 {
		return nil, fmt.Errorf("%w: invalid-xtea-materials", errSession)
	}
	var keyWords [4]uint32
	for i := 0; i < 4; i++ {
		keyWords[i] = binary.BigEndian.Uint32(key[i*4 : i*4+4])
	}
	nonceLo := uint64(binary.LittleEndian.Uint32(nonce))
	cycles := 32 + 8*(int(nonceLo)%5)
	// python: previous = nonce + struct.pack("<I", 0x20200427)（LE 小端拼接）
	previous := make([]byte, 8)
	copy(previous, nonce)
	binary.LittleEndian.PutUint32(previous[4:], 0x20200427)

	out := make([]byte, 0, len(data))
	for offset := 0; offset < len(data); offset += 8 {
		source := data[offset : offset+8]
		var block [8]byte
		if decrypt {
			copy(block[:], source)
		} else {
			for i := 0; i < 8; i++ {
				block[i] = source[i] ^ previous[i]
			}
		}
		w0 := binary.BigEndian.Uint32(block[0:4])
		w1 := binary.BigEndian.Uint32(block[4:8])
		words := [2]uint32{w0, w1}
		if decrypt {
			for step := cycles*2 - 1; step >= 0; step-- {
				target := step & 1
				total := uint32((uint64(step+1)/2)*xteaDelta) & 0xFFFFFFFF
				other := words[1-target]
				keyIndex := (total >> (11 * target)) & 3
				mix := (((other << 4) ^ (other >> 5)) + other) ^ (total + keyWords[keyIndex])
				words[target] = words[target] - mix
			}
		} else {
			for step := 0; step < cycles*2; step++ {
				target := step & 1
				total := uint32((uint64(step+1)/2)*xteaDelta) & 0xFFFFFFFF
				other := words[1-target]
				keyIndex := (total >> (11 * target)) & 3
				mix := (((other << 4) ^ (other >> 5)) + other) ^ (total + keyWords[keyIndex])
				words[target] = words[target] + mix
			}
		}
		transformed := make([]byte, 8)
		binary.BigEndian.PutUint32(transformed[0:], words[0])
		binary.BigEndian.PutUint32(transformed[4:], words[1])
		if decrypt {
			for i := 0; i < 8; i++ {
				transformed[i] ^= previous[i]
			}
			out = append(out, transformed...)
			previous = append([]byte(nil), source...)
		} else {
			out = append(out, transformed...)
			previous = transformed
		}
	}
	return out, nil
}

// ---- payload 加解密（zlib 容器 + XTEA + AES-CBC 外层） ----

func encryptPayload(plaintext, common, inner, nonce []byte, entropyByte byte) ([]byte, error) {
	if len(common) != 32 || len(inner) != 16 {
		return nil, fmt.Errorf("%w: invalid-exchange-materials", errSession)
	}
	if len(plaintext) > maxPlain {
		return nil, fmt.Errorf("%w: invalid-plaintext", errSession)
	}
	compressed, err := zlibCompress(plaintext)
	if err != nil {
		return nil, err
	}
	// python: b"\x78\x01" + compressed[2:] —— 改写 CMF/FLG 为压缩级 1 标记。
	if len(compressed) >= 2 {
		compressed[0], compressed[1] = 0x78, 0x01
	}
	container := make([]byte, 0, 4+len(compressed))
	container = append(container, le32pack(uint32(len(plaintext)))...)
	container = append(container, compressed...)

	extra := (8 - len(container)%8) % 8
	position := 1 + pyMod(extra-1, 4)
	frame := make([]byte, len(container)+8+extra)
	frame[0] = (entropyByte & 0xF8) | byte(extra)
	copy(frame[position:], container)
	// python: crc_offset = 1 if position >= 3 else position + len(container)
	crcOffset := 1
	if position < 3 {
		crcOffset = position + len(container)
	}
	binary.BigEndian.PutUint16(frame[crcOffset:], crc16CCITT(container))

	encrypted, err := xteaChain(frame, inner, nonce, false)
	if err != nil {
		return nil, err
	}
	// python: bytes([encrypted[0] ^ 3]) + encrypted + nonce（前置一字节标记）。
	wrapped := make([]byte, 0, 1+len(encrypted)+len(nonce))
	wrapped = append(wrapped, encrypted[0]^3)
	wrapped = append(wrapped, encrypted...)
	wrapped = append(wrapped, nonce...)
	block, err := aes.NewCipher(common[:16])
	if err != nil {
		return nil, err
	}
	padded := pkcs7Pad16(wrapped)
	out := make([]byte, len(padded))
	mode := cipher.NewCBCEncrypter(block, common[16:])
	mode.CryptBlocks(out, padded)
	return out, nil
}

func decryptPayload(ciphertext, common, inner []byte) ([]byte, error) {
	if len(common) != 32 || len(inner) != 16 {
		return nil, fmt.Errorf("%w: invalid-exchange-materials", errSession)
	}
	if len(ciphertext) == 0 || len(ciphertext)%16 != 0 || len(ciphertext) > maxPlain*2 {
		return nil, fmt.Errorf("%w: invalid-ciphertext", errSession)
	}
	block, err := aes.NewCipher(common[:16])
	if err != nil {
		return nil, err
	}
	decrypted := make([]byte, len(ciphertext))
	mode := cipher.NewCBCDecrypter(block, common[16:])
	mode.CryptBlocks(decrypted, ciphertext)
	wrapped, err := pkcs7Unpad16(decrypted)
	if err != nil {
		return nil, err
	}
	if len(wrapped) < 13 || (len(wrapped)-5)%8 != 0 || wrapped[0]^wrapped[1] != 3 {
		return nil, fmt.Errorf("%w: invalid-outer-frame", errSession)
	}
	frame, err := xteaChain(wrapped[1:len(wrapped)-4], inner, wrapped[len(wrapped)-4:], true)
	if err != nil {
		return nil, err
	}
	extra := frame[0] & 7
	length := len(frame) - 8 - int(extra)
	position := 1 + pyMod(int(extra)-1, 4)
	if position+length > len(frame) || length < 4 {
		return nil, fmt.Errorf("%w: invalid-inner-frame", errSession)
	}
	container := frame[position : position+length]
	expectedSize := binary.LittleEndian.Uint32(container[:4])
	if expectedSize > maxPlain {
		return nil, fmt.Errorf("%w: response-too-large", errSession)
	}
	value, err := zlibDecompress(container[4:], int(expectedSize))
	if err != nil {
		return nil, err
	}
	if len(value) != int(expectedSize) {
		return nil, fmt.Errorf("%w: invalid-decoded-size", errSession)
	}
	return value, nil
}

func exchangeRequest(plaintext []byte, milliseconds int64, common, inner, nonce []byte, entropyByte byte) ([]byte, error) {
	ciphertext, err := encryptPayload(plaintext, common, inner, nonce, entropyByte)
	if err != nil {
		return nil, err
	}
	return pbEncode([]PBField{
		pbInt(1, 0x20200422*2), pbInt(2, 2), pbInt(3, 2),
		pbBytes(4, ciphertext), pbInt(5, milliseconds*2),
	}), nil
}

func exchangeResponse(packet, common, inner []byte) (token string, status int, err error) {
	rows, err := pbDecodeLimit(packet, maxPlain*2)
	if err != nil {
		return "", 0, err
	}
	var cipherText []byte
	hasCipher := false
	header1, header2 := uint64(0), uint64(0)
	code := uint64(0)
	hasCode := false
	for _, row := range rows {
		switch row.Number {
		case 1, 2:
			if row.Kind != 0 {
				return "", 0, fmt.Errorf("%w: invalid-response-header", errSession)
			}
			if row.Number == 1 {
				header1 = row.Int
			} else {
				header2 = row.Int
			}
		case 3:
			if row.Kind != 0 {
				return "", 0, fmt.Errorf("%w: invalid-response-status", errSession)
			}
			code = row.Int
			hasCode = true
		case 6:
			if row.Kind != 2 {
				return "", 0, fmt.Errorf("%w: invalid-response-ciphertext", errSession)
			}
			cipherText = row.Bytes
			hasCipher = true
		}
	}
	if header1 != 0x20120312*2 || header2 != 2 {
		return "", 0, fmt.Errorf("%w: invalid-response-header", errSession)
	}
	if !hasCipher {
		if hasCode {
			return "", 0, fmt.Errorf("%w: exchange-refused-%d", errSession, int64(code>>1)^-(int64(code)&1))
		}
		return "", 0, fmt.Errorf("%w: missing-response-ciphertext", errSession)
	}
	decoded, err := decryptPayload(cipherText, common, inner)
	if err != nil {
		return "", 0, err
	}
	rows, err = pbDecode(decoded)
	if err != nil {
		return "", 0, err
	}
	var tokenBytes []byte
	statusZig := uint64(0)
	hasToken, hasStatus := false, false
	for _, row := range rows {
		if row.Number != 1 && row.Number != 2 {
			continue
		}
		if row.Number == 1 {
			if row.Kind != 2 || hasToken {
				return "", 0, fmt.Errorf("%w: invalid-session-fields", errSession)
			}
			tokenBytes, hasToken = row.Bytes, true
		} else {
			if row.Kind != 0 || hasStatus {
				return "", 0, fmt.Errorf("%w: invalid-session-fields", errSession)
			}
			statusZig, hasStatus = row.Int, true
		}
	}
	if !hasToken || !hasStatus {
		return "", 0, fmt.Errorf("%w: incomplete-session", errSession)
	}
	status = int(int64(statusZig)>>1) ^ -(int(int64(statusZig) & 1))
	if status != 200 && status != 202 {
		return "", 0, fmt.Errorf("%w: session-status-%d", errSession, status)
	}
	token = string(tokenBytes)
	if token == "" || len(tokenBytes) > 256 {
		return "", 0, fmt.Errorf("%w: invalid-session-token", errSession)
	}
	for _, r := range token {
		if r < 33 || r > 126 {
			return "", 0, fmt.Errorf("%w: invalid-session-token", errSession)
		}
	}
	return token, status, nil
}

// ---- 设备负载（pb 构造） ----

func deviceProof(deviceID string) []byte {
	return pbEncode([]PBField{
		pbInt(1, 2), pbInt(2, 4), pbStr(3, "8662"), pbStr(4, deviceID),
		pbStr(5, "Ai6svO3PyrwDOUSmO6ZcResxu"), pbStr(6, "!noperm!"),
		pbInt(7, 1777775), pbInt(8, 1777775), pbInt(9, 6), pbInt(10, 1777775),
		pbStr(11, "!notset!"), pbStr(12, "Asia/Shanghai,8"), pbStr(13, "zh_CN"), pbInt(14, 8),
		pbFloat(16, 255.24993896484375), pbFloat(17, 35.58599090576172),
		pbFloat(18, 3.467449188232422), pbFloat(19, 3.467449188232422),
		pbFloat(20, 255.1754913330078), pbFloat(21, 42.17544174194336),
		pbStr(22, "16"), pbInt(23, 82), pbInt(24, 72),
		pbInt(25, 3456776033270), pbInt(26, 3456776033270),
		pbInt(27, 3456776033270), pbInt(28, 3456776033274), pbInt(29, 1),
		pbStr(30, "25053RT47C"), pbStr(31, "Redmi"), pbStr(32, "25053RT47C"),
		pbStr(33, "25053RT47C"), pbStr(34, "Xiaomi"), pbStr(35, "Redmi"),
		pbStr(36, "Redmi"), pbInt(38, 62),
	})
}

func devicePayload(params map[string]string, marker string, token []byte) []byte {
	stringFields := []int{1, 19, 20, 23, 28, 31, 32, 38, 39, 50, 53, 93, 94, 95, 96,
		109, 110, 111, 115, 135, 2000, 2001}
	numberFields := []int{13, 29, 30, 36, 37, 41, 42, 43, 49, 51, 52, 56, 57, 58, 59,
		60, 61, 62, 63, 64, 66, 67, 69, 70, 71, 72, 73, 74, 75, 76,
		77, 78, 79, 80, 81, 82, 83, 84, 85, 86, 87, 88, 97, 98, 99,
		100, 101, 102, 103, 104, 105, 113, 114, 116, 117, 118}
	values := map[int]PBField{}
	for _, index := range stringFields {
		values[index] = pbStr(index, marker)
	}
	for _, index := range numberFields {
		values[index] = pbInt(index, int64(signed(-999999)))
	}
	for _, pair := range []struct {
		index int
		key   string
	}{{2, "device_brand"}, {3, "device_type"}, {6, "os_version"},
		{7, "resolution"}, {9, "rom_version"}} {
		if v, ok := params[pair.key]; ok && v != "" {
			values[pair.index] = pbStr(pair.index, v)
		} else {
			values[pair.index] = pbStr(pair.index, marker)
		}
	}
	values[5] = pbStr(5, "Android")
	values[12] = pbStr(12, "Asia/Shanghai,8")
	for _, pair := range []struct {
		index int
		key   string
	}{{8, "dpi"}, {48, "os_api"}} {
		raw := params[pair.key]
		if isAllDigits(raw) {
			n, _ := strconv.ParseInt(raw, 10, 64)
			values[pair.index] = pbInt(pair.index, int64(signed(n)))
		} else {
			values[pair.index] = pbInt(pair.index, int64(signed(-999999)))
		}
	}
	// (1, pb_encode(sorted(values.items()))) —— 按字段号排序的内层消息。
	inner := make([]PBField, 0, len(values))
	for _, index := range sortedIntKeys(values) {
		inner = append(inner, values[index])
	}
	// python: fields.insert(1, (2, token)) —— token 紧跟字段 1，不是置顶。
	fields := []PBField{pbBytes(1, pbEncode(inner))}
	if token != nil {
		fields = append(fields, pbBytes(2, token))
	}
	fields = append(fields,
		pbStr(3, "android"), pbStr(4, sdkVersion),
		pbInt(5, int64(signed(int64(sdkCode)))), pbStr(6, params["aid"]),
		pbStr(7, params["version_name"]), pbStr(8, params["device_id"]),
		pbInt(11, int64(signed(-999999))), pbInt(16, int64(signed(-999999))),
		pbStr(17, marker),
	)
	return pbEncode(fields)
}

func boundDeviceProof(params map[string]string) []byte {
	replacements := map[int]string{
		3: params["aid"], 4: params["device_id"], 5: params["cdid"],
		22: params["os_version"], 30: params["device_type"],
		31: params["device_brand"], 32: params["device_type"],
		33: params["device_type"], 34: params["device_brand"],
		35: params["device_brand"], 36: params["device_brand"],
	}
	rows, err := pbDecode(deviceProof(params["device_id"]))
	if err != nil {
		return nil
	}
	fields := make([]PBField, 0, len(rows))
	for _, row := range rows {
		if v, ok := replacements[row.Number]; ok {
			fields = append(fields, pbStr(row.Number, v))
			continue
		}
		switch row.Kind {
		case 0:
			fields = append(fields, pbInt(row.Number, int64(row.Int)))
		case 2:
			fields = append(fields, pbBytes(row.Number, row.Bytes))
		case 5:
			fields = append(fields, pbFloat(row.Number, float32FromLE(row.Bytes)))
		default:
			fields = append(fields, pbInt(row.Number, int64(row.Int)))
		}
	}
	return pbEncode(fields)
}

func advanceLadon(previous uint32, allocation uint64, seconds uint32) uint32 {
	// checksum: b"646637794" 的 CRC 变体（多项式 0x95AC9329AC4BC9B5）。
	checksum := uint64(0)
	for _, b := range []byte("646637794") {
		checksum ^= uint64(b)
		for i := 0; i < 8; i++ {
			if checksum&1 != 0 {
				checksum = checksum>>1 ^ 0x95AC9329AC4BC9B5
			} else {
				checksum >>= 1
			}
		}
	}
	mixed := allocation ^ checksum ^ uint64(seconds)
	rotated := mixed<<4 | mixed>>60
	return previous ^ uint32(rotated&0xFFFFFFFF)
}

// bootstrapQuery 查询串构造（python urlencode 保序 + quote safe="*"）。
func bootstrapQuery(params map[string]string, milliseconds int64) []byte {
	fields := []([2]string){
		{"lc_id", "646637794"}, {"platform", "android"}, {"device_platform", "android"},
		{"sdk_ver", sdkVersion}, {"sdk_ver_code", strconv.FormatUint(uint64(sdkCode), 10)},
		{"app_ver", params["version_name"]}, {"version_code", params["version_code"]},
		{"aid", params["aid"]}, {"sdkid", params["sdkid"]},
		{"subaid", params["subaid"]}, {"iid", params["iid"]},
		{"did", params["device_id"]}, {"bd_did", params["bd_did"]},
		{"client_type", "inhouse"}, {"region_type", "ml"}, {"mode", "2"},
		{"full_update_version_code", params["update_version_code"]},
	}
	for _, key := range []string{"os", "ssmix", "_rticket", "cdid", "channel", "app_name",
		"version_name", "manifest_version_code", "update_version_code", "resolution", "dpi",
		"device_type", "device_brand", "language", "os_api", "os_version", "ac", "host_abi",
		"dragon_device_type", "pv_player", "compliance_status", "need_personal_recommend",
		"player_so_load", "is_android_pad_screen", "rom_version", "device_id", "klink_egdi"} {
		value := params[key]
		if key == "_rticket" {
			value = strconv.FormatInt(milliseconds, 10)
		} else if key == "need_personal_recommend" {
			value = "1"
		}
		fields = append(fields, [2]string{key, value})
	}
	var buf strings.Builder
	for i, kv := range fields {
		if i > 0 {
			buf.WriteByte('&')
		}
		buf.WriteString(pyQuote(kv[0]))
		buf.WriteByte('=')
		buf.WriteString(pyQuote(kv[1]))
	}
	return []byte(buf.String())
}

// pyQuote 对齐 urllib.parse.quote(s, safe="*")：unreserved = 字母数字 + -_.~*。
func pyQuote(s string) string {
	const hexDigits = "0123456789ABCDEF"
	var buf strings.Builder
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' ||
			c == '_' || c == '.' || c == '-' || c == '~' || c == '*' {
			buf.WriteByte(c)
		} else {
			buf.WriteByte('%')
			buf.WriteByte(hexDigits[c>>4])
			buf.WriteByte(hexDigits[c&15])
		}
	}
	return buf.String()
}

// ---- 请求发送 ----

type v5Request struct {
	URL     string
	Headers map[string]string
	Body    []byte
}

func sendRequest(request v5Request) ([]byte, error) {
	if !strings.HasPrefix(request.URL, "https://"+bootstrapHost+bootstrapPath+"?") &&
		!strings.HasPrefix(request.URL, "https://"+playbackHost+playbackPath+"?") {
		return nil, fmt.Errorf("%w: invalid-route", errSession)
	}
	for name := range request.Headers {
		switch strings.ToLower(name) {
		case "authorization", "x-tt-token", "x-tt-passport-csrf-token":
			return nil, fmt.Errorf("%w: account-auth-on-sdk-route", errSession)
		}
	}
	req, err := http.NewRequest("POST", request.URL, bytes.NewReader(request.Body))
	if err != nil {
		return nil, err
	}
	for k, v := range request.Headers {
		req.Header.Set(k, v)
	}
	resp, err := httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("%w: request-http-%d", errSession, resp.StatusCode)
	}
	limit := int64(2 * 1024 * 1024)
	if parsed, perr := urlParse(request.URL); perr == nil && parsed.Path == bootstrapPath {
		limit = 131072
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > limit {
		return nil, fmt.Errorf("%w: response-limit", errSession)
	}
	if len(data) == 0 {
		return nil, fmt.Errorf("%w: response-empty", errSession)
	}
	return data, nil
}

// ---- v5 签名（_sign_prepared_v5 移植；entropy 可注入做黄金对拍） ----

type entropySource struct {
	Randbits32 func() uint32
	Randbits64 func() uint64
	Randbits8  func() byte
	TokenBytes func(n int) []byte
	Randbelow  func(n int64) int64
	TokenHex   func(n int) string
	Getpid     func() int
	UUID       func() string
}

func cryptoEntropy() *entropySource {
	return &entropySource{
		Randbits32: randbits32,
		Randbits64: randbits64,
		Randbits8:  randbits8,
		TokenBytes: cryptoTokenBytes,
		Randbelow:  cryptoRandbelow,
		TokenHex:   cryptoTokenHex,
		Getpid:     os.Getpid,
		UUID:       cryptoUUID,
	}
}

func signPreparedV5(params map[string]string, cookies map[string]string,
	query, body []byte, milliseconds int64, materials map[string][]byte,
	image map[string][]byte, core digestFunc, token string, previousLadon uint32,
	origin, path string, bootstrap bool, ent *entropySource) (v5Request, uint32, error) {
	seconds := uint32(milliseconds / 1000)
	proof, err := digestV5(query, body, seconds, core)
	if err != nil {
		return v5Request{}, 0, err
	}
	prefixBytes := make([]byte, 8)
	if bootstrap {
		binary.LittleEndian.PutUint64(prefixBytes, 2)
	} else {
		binary.LittleEndian.PutUint64(prefixBytes, 0x0504)
	}
	counters := pbEncode([]PBField{pbInt(1, 2), pbInt(2, 1388734), pbInt(3, 1388734), pbInt(5, 1388734)})
	environment := pbEncode([]PBField{
		pbInt(1, 2), pbStr(6, "v04.10.03.04-bugfix"), pbInt(7, int64(ent.Getpid())*2),
		pbStr(8, params["channel"]), pbBytes(12, boundDeviceProof(params)),
		pbStr(14, params["version_name"]), pbInt(15, 4228), pbInt(19, milliseconds*2),
	})
	stateJSON := fmt.Sprintf(`{"cmr":16777216,"cmr2":16777216,"vpn":0,"kd":0,"dyn":"","do":0,"tk":%s}`,
		map[bool]string{true: "true", false: "false"}[token != ""])
	nonce0 := ent.Randbits32()
	nonce1 := ent.Randbits32()
	nonce2 := ent.Randbits32()
	message := pbEncode([]PBField{
		pbBytes(1, image["frame"]), pbInt(2, 10), pbInt(3, int64(nonce0)*2),
		pbStr(4, "8662"), pbStr(5, params["device_id"]), pbStr(6, "646637794"),
		pbStr(7, params["version_name"]), pbStr(8, sdkVersion),
		pbInt(9, int64(sdkCode)*2), pbBytes(10, prefixBytes),
		pbInt(12, int64(seconds)*2), pbBytes(13, proof),
		pbBytes(14, sm3(query)[:6]), pbBytes(15, counters),
		pbStr(16, token), pbInt(17, int64(seconds)*2), pbStr(20, "none"),
		pbInt(21, 738), pbBytes(23, environment), pbStr(24, stateJSON),
	})
	medusa, err := envelopeV5(message, sm3(query), proof, seconds, nonce1, nonce2,
		materials["signing_key"], image["frame"], prefixBytes[:8], image["substitutions"])
	if err != nil {
		return v5Request{}, 0, err
	}
	nextLadon := advanceLadon(previousLadon, ent.Randbits64()&^uint64(15), seconds)
	trace := fmt.Sprintf("00-%s-%s-01", ent.TokenHex(16), ent.TokenHex(8))
	ua := fmt.Sprintf("com.phoenix.read/74332 (Linux; U; Android %s; zh_CN; %s; Cronet/TTNetVersion:8d40f833_2026-03-03)",
		params["os_version"], params["device_type"])
	heliosRandom := ent.TokenBytes(4)
	helios, err := ladonEncrypt(int64(seconds), licenseHelios, 8662, heliosRandom)
	if err != nil {
		return v5Request{}, 0, err
	}
	headers := map[string]string{
		"Content-Type":              "application/octet-stream",
		"Accept":                    "*/*",
		"X-TT-Request-Tag":          "t=0;n=0",
		"X-SS-DP":                   "8662",
		"X-Khronos":                 strconv.FormatUint(uint64(seconds), 10),
		"X-Argus":                   b64Encode(le32pack(seconds)),
		"X-Ladon":                   b64Encode(be32pack(nextLadon)),
		"X-Gorgon":                  gorgonV5(query, body, seconds, uint16(ent.Randbelow(1<<16)), [2]byte{prefixBytes[0], prefixBytes[1]}),
		"X-Medusa":                  medusa,
		"X-Helios":                  helios,
		"X-SS-STUB":                 strings.ToUpper(hexEncode(md5Sum(body))),
		"X-VC-Bdturing-SDK-Version": "4.0.3.cn",
		"X-TT-Trace-ID":             trace,
		"User-Agent":                ua,
	}

	var cookieParts []string
	cookieParts = append(cookieParts, "install_id="+params["iid"])
	for _, name := range []string{"odin_tt", "ttreq", "store-region"} {
		value := cookies[name]
		if value != "" && len(value) <= 8192 && !strings.ContainsAny(value, "\x00-\x20;\x7f-\uffff") {
			cookieParts = append(cookieParts, name+"="+value)
		}
	}
	cookieParts = append(cookieParts, "store-region-src=did")
	headers["Cookie"] = strings.Join(cookieParts, "; ")
	return v5Request{
		URL:     origin + path + "?" + string(query),
		Headers: headers,
		Body:    body,
		// next_ladon 由调用方经返回值传递
	}, nextLadon, nil
}

func prepareBootstrap(params map[string]string, cookies map[string]string, milliseconds int64,
	materials map[string][]byte, image map[string][]byte, unavailable string,
	core digestFunc, token string, previousLadon uint32, ent *entropySource) (v5Request, uint32, error) {
	merged := make(map[string]string, len(params)+6)
	for k, v := range params {
		merged[k] = v
	}
	merged["version_name"] = "7.4.3.32"
	merged["version_code"] = "74332"
	merged["manifest_version_code"] = "74332"
	merged["update_version_code"] = "74332"
	merged["device_platform"] = "android"
	merged["os"] = "android"
	query := bootstrapQuery(merged, milliseconds)
	// python: token=None 时不插字段 2；202 重试时带待确认 token。
	var tokenBytes []byte
	if token != "" {
		tokenBytes = []byte(token)
	}
	plaintext := devicePayload(merged, unavailable, tokenBytes)
	nonce := ent.TokenBytes(4)
	body, err := exchangeRequest(plaintext, milliseconds, materials["exchange_key"],
		image["exchange_inner_key"], nonce, ent.Randbits8())
	if err != nil {
		return v5Request{}, 0, err
	}
	return signPreparedV5(merged, cookies, query, body, milliseconds, materials, image,
		core, token, previousLadon, "https://"+bootstrapHost, bootstrapPath, true, ent)
}

func preparePlaybackV5(params map[string]string, cookies map[string]string, video string,
	milliseconds int64, token string, previousLadon uint32, materials map[string][]byte,
	image map[string][]byte, core digestFunc, ent *entropySource) (v5Request, uint32, error) {
	if params["aid"] != "8662" {
		return v5Request{}, 0, fmt.Errorf("%w: invalid-application", errSession)
	}
	merged := make(map[string]string, len(params)+8)
	for k, v := range params {
		merged[k] = v
	}
	merged["version_code"] = "74332"
	merged["version_name"] = "7.4.3.32"
	merged["update_version_code"] = "74332"
	merged["manifest_version_code"] = "74332"
	merged["device_platform"] = "android"
	merged["os"] = "android"
	merged["_rticket"] = strconv.FormatInt(milliseconds, 10)
	names := []string{"device_platform", "os", "ssmix", "_rticket", "cdid", "channel", "aid",
		"app_name", "version_code", "version_name", "manifest_version_code",
		"update_version_code", "resolution", "dpi", "device_type", "device_brand",
		"language", "os_api", "os_version", "ac", "host_abi", "dragon_device_type",
		"pv_player", "compliance_status", "need_personal_recommend", "player_so_load",
		"is_android_pad_screen", "rom_version", "device_id", "iid", "klink_egdi"}
	var query strings.Builder
	first := true
	for _, name := range names {
		value, ok := merged[name]
		if !ok || value == "" {
			continue
		}
		if !first {
			query.WriteByte('&')
		}
		first = false
		query.WriteString(pyQuote(name))
		query.WriteByte('=')
		query.WriteString(pyQuote(value))
	}
	queryBytes := []byte(query.String())
	payload := fmt.Sprintf(`{"dr_scene":"player","mixed_video_id_map":{"1004":[%s]},"biz_param":{`+
		`"detail_page_version":0,"device_level":4,"disable_digg_stat":false,`+
		`"need_all_video_definition":true,"need_mp4_align":false,"use_os_player":false,`+
		`"use_server_dns":false,"video_platform":1024}}`, strconv.Quote(video))
	var gzipBuf bytes.Buffer
	gw, _ := gzip.NewWriterLevel(&gzipBuf, gzip.BestCompression)
	gw.Header.ModTime = time.Time{}
	if _, err := gw.Write([]byte(payload)); err != nil {
		return v5Request{}, 0, err
	}
	if err := gw.Close(); err != nil {
		return v5Request{}, 0, err
	}
	request, nextLadon, err := signPreparedV5(merged, cookies, queryBytes, gzipBuf.Bytes(),
		milliseconds, materials, image, core, token, previousLadon,
		"https://"+playbackHost, playbackPath, false, ent)
	if err != nil {
		return v5Request{}, 0, err
	}
	request.Headers["Content-Type"] = "application/json; charset=utf-8"
	request.Headers["Content-Encoding"] = "gzip"
	request.Headers["Accept"] = "application/json"
	request.Headers["X-Reading-Request"] = fmt.Sprintf("%d-%d", milliseconds,
		100000000+ent.Randbelow(900000000))
	request.Headers["X-TT-Store-Region"] = orDefault(cookies["store-region"], "cn")
	request.Headers["X-TT-Store-Region-Src"] = "did"
	request.Headers["X-SS-REQ-TICKET"] = strconv.FormatInt(milliseconds, 10)
	return request, nextLadon, nil
}

// ---- 会话持久化 ----

func sessionBinding(params map[string]string) string {
	part := fmt.Sprintf(`{"aid":%s,"cdid":%s,"device_id":%s,"iid":%s}`,
		jsonStr(params["aid"]), jsonStr(params["cdid"]),
		jsonStr(params["device_id"]), jsonStr(params["iid"]))
	sum := sha256.Sum256([]byte(part))
	return hexEncode(sum[:])
}

type sessionState struct {
	Schema        int    `json:"schema"`
	SDKVersion    string `json:"sdkVersion"`
	Status        int    `json:"status"`
	DeviceBinding string `json:"deviceBinding"`
	Token         string `json:"token"`
	Ladon         uint32 `json:"ladon"`
	CreatedAt     int64  `json:"createdAt"`
}

func validateSession(raw []byte, binding string) (*sessionState, error) {
	var state sessionState
	if err := json.Unmarshal(raw, &state); err != nil {
		return nil, err
	}
	if state.Schema != 1 || state.SDKVersion != sdkVersion || state.Status != 200 {
		return nil, fmt.Errorf("%w: invalid-session", errSession)
	}
	if state.DeviceBinding != binding {
		return nil, fmt.Errorf("%w: session-device-mismatch", errSession)
	}
	if state.Token == "" || len(state.Token) > 256 {
		return nil, fmt.Errorf("%w: invalid-token", errSession)
	}
	for _, r := range state.Token {
		if r < 33 || r > 126 {
			return nil, fmt.Errorf("%w: invalid-token", errSession)
		}
	}
	return &state, nil
}

func ensureSession(dataDir string, params map[string]string, cookies map[string]string,
	materials map[string][]byte, image map[string][]byte, unavailable string,
	core digestFunc, ent *entropySource) (*sessionState, error) {
	path := filepath.Join(dataDir, "hongguo-sdk-session.json")
	binding := sessionBinding(params)
	if raw, err := os.ReadFile(path); err == nil {
		if state, err := validateSession(raw, binding); err == nil {
			return state, nil
		}
	}
	token := ""
	previousLadon := uint32(0)
	for attempt := 0; attempt < 2; attempt++ {
		prepared, nextLadon, err := prepareBootstrap(params, cookies, timeNowMS(),
			materials, image, unavailable, core, token, previousLadon, ent)
		if err != nil {
			return nil, err
		}
		response, err := sendRequest(prepared)
		if err != nil {
			return nil, err
		}
		respToken, status, err := exchangeResponse(response, materials["exchange_key"], image["exchange_inner_key"])
		if err != nil {
			return nil, err
		}
		if status == 200 {
			state := &sessionState{
				Schema: 1, SDKVersion: sdkVersion, Status: 200,
				DeviceBinding: binding, Token: respToken,
				Ladon: nextLadon, CreatedAt: time.Now().Unix(),
			}
			raw, err := json.Marshal(state)
			if err != nil {
				return nil, err
			}
			if err := atomicWrite(path, raw); err != nil {
				return nil, err
			}
			return state, nil
		}
		if status != 202 {
			return nil, fmt.Errorf("%w: session-status-%d", errSession, status)
		}
		// python: 202 携带待确认 token，下一次 bootstrap 带上它再换。
		token = respToken
		previousLadon = nextLadon
	}
	return nil, fmt.Errorf("%w: session-not-ready", errSession)
}

// ---- 杂项 ----

type digestFunc func(payload []byte, mode int, seconds uint32) ([]byte, error)

func isAllDigits(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return len(s) > 0
}

func sortedIntKeys(m map[int]PBField) []int {
	keys := make([]int, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	for i := 1; i < len(keys); i++ {
		for j := i; j > 0 && keys[j] < keys[j-1]; j-- {
			keys[j], keys[j-1] = keys[j-1], keys[j]
		}
	}
	return keys
}

func float32FromLE(b []byte) float32 {
	bits := uint32(b[0]) | uint32(b[1])<<8 | uint32(b[2])<<16 | uint32(b[3])<<24
	return float32frombits(bits)
}

func jsonStr(s string) string {
	raw, _ := json.Marshal(s)
	return string(raw)
}

func b64Encode(data []byte) string {
	const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	var buf strings.Builder
	for i := 0; i < len(data); i += 3 {
		var b [3]byte
		n := copy(b[:], data[i:])
		v := uint32(b[0])<<16 | uint32(b[1])<<8 | uint32(b[2])
		buf.WriteByte(chars[v>>18&63])
		buf.WriteByte(chars[v>>12&63])
		if n > 1 {
			buf.WriteByte(chars[v>>6&63])
		} else {
			buf.WriteByte('=')
		}
		if n > 2 {
			buf.WriteByte(chars[v&63])
		} else {
			buf.WriteByte('=')
		}
	}
	return buf.String()
}

func orDefault(v, fallback string) string {
	if v == "" {
		return fallback
	}
	return v
}

func pkcs7Pad16(data []byte) []byte {
	pad := 16 - len(data)%16
	out := make([]byte, len(data)+pad)
	copy(out, data)
	for i := len(data); i < len(out); i++ {
		out[i] = byte(pad)
	}
	return out
}

func pkcs7Unpad16(data []byte) ([]byte, error) {
	if len(data) == 0 {
		return nil, fmt.Errorf("%w: invalid-padding", errSession)
	}
	pad := int(data[len(data)-1])
	if pad <= 0 || pad > 16 || pad > len(data) {
		return nil, fmt.Errorf("%w: invalid-padding", errSession)
	}
	for _, b := range data[len(data)-pad:] {
		if b != byte(pad) {
			return nil, fmt.Errorf("%w: invalid-padding", errSession)
		}
	}
	return data[:len(data)-pad], nil
}

func crc16CCITT(data []byte) uint16 {
	// binascii.crc_hqx(data, 0)：CRC-16/XMODEM。
	crc := uint16(0)
	for _, b := range data {
		crc ^= uint16(b) << 8
		for i := 0; i < 8; i++ {
			if crc&0x8000 != 0 {
				crc = crc<<1 ^ 0x1021
			} else {
				crc <<= 1
			}
		}
	}
	return crc
}

func atomicWrite(path string, data []byte) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func timeNowMS() int64 {
	return time.Now().UnixMilli()
}

func urlParse(raw string) (*url.URL, error) {
	return url.Parse(raw)
}

var _ = crc64.Checksum
