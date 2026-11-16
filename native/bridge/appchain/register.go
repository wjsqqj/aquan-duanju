package appchain

// 匿名设备注册：复刻 2026-11 现行加密注册配方（zfdang/hongguo-open-player
// playback-device.js，11-16 版）。要点：
//   - lf 注册域 + tt_data=a 等查询参数（明文注册域 snssdk 的身份不被取流接口信任）；
//   - 注册档案 74332 姿势（与取流链路版本一致，版本矛盾=风控异常点）；
//   - body 加密：JSON→gzip→(sha512(compressed)||compressed)→AES-128-CBC，
//     key/iv = sha512(sha512(random32)||KDF_SALT)[0:16]/[16:32]，
//     wire = hex"746305100000" + random32 + ciphertext；
//   - 响应 {code:0, device_id_str, install_id_str}；Set-Cookie 作会话
//     （store-region / install_id 等身份 cookie，与 zfdang device-session 一致）。

import (
	"bytes"
	"compress/gzip"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/md5"
	"crypto/rand"
	"crypto/sha512"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"strconv"
	"strings"
	"time"
)

var registerURL = "https://log5-applog-lf.fqnovel.com/service/2/device_register/?tt_data=a&cronet_version=8d40f833_2026-03-03&ttnet_version=4.2.243.31-douyin&use_store_region_cookie=1"

var kdfSalt = mustHex("4dd4c2e6b83162090e52b3c7a6733ba41cb2462b829ab58a196b39db57177524f49baf7f08e8d68d26a72e37c1a95a2f1f05a51892aef2949732b62a38aadd58")

const playUA74332 = "com.phoenix.read/74332 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)"

// device 是匿名设备身份：注册产物 + 会话 cookie，持久化复用（换新设备
// =永远零信任，容易撞风控限额——qist 实测情报）。
type device struct {
	DeviceID  string `json:"device_id"`
	InstallID string `json:"install_id"`
	CDID      string `json:"cdid"`
	Cookie    string `json:"cookie"`
	CreatedAt int64  `json:"created_at"`
}

func registerDevice(ctx context.Context, client *http.Client) (*device, error) {
	now := time.Now().UnixMilli()
	cdid := uuidV4()
	openudid := randHex(16)
	// header 字段序复刻 zfdang createRegistrationRequest（JSON 字节级形状入信封）。
	header := `{` +
		`"display_name":"红果免费短剧",` +
		`"update_version_code":74332,` +
		`"manifest_version_code":74332,` +
		`"app_version_minor":"7.4.3.32",` +
		`"aid":8662,` +
		`"channel":"update_64",` +
		`"package":"com.phoenix.read",` +
		`"app_version":"7.4.3.32",` +
		`"version_code":74332,` +
		`"sdk_version":"3.7.0-rc.34-fanqie-xiaoshuo",` +
		`"sdk_target_version":29,` +
		`"git_hash":"3a88f4e",` +
		`"os":"Android",` +
		`"os_version":"16",` +
		`"os_api":36,` +
		`"device_model":"25053RT47C",` +
		`"device_brand":"Redmi",` +
		`"device_manufacturer":"Redmi",` +
		`"cpu_abi":"arm64-v8a",` +
		`"release_build":"b5e187f",` +
		`"density_dpi":520,` +
		`"display_density":"mdpi",` +
		`"resolution":"1280x2772",` +
		`"language":"zh",` +
		`"timezone":8,` +
		`"access":"wifi",` +
		`"not_request_sender":0,` +
		`"carrier":"CHINA MOBILE",` +
		`"mcc_mnc":"46000",` +
		`"rom":"eng.root.20231116.160340",` +
		`"rom_version":"W528JS release-keys",` +
		`"cdid":"` + cdid + `",` +
		`"sig_hash":"56a962410c494bbaf0b58dba20cae56f",` +
		`"openudid":"` + openudid + `",` +
		`"clientudid":"` + uuidV4() + `",` +
		`"ipv6_list":[],` +
		`"region":"CN",` +
		`"tz_name":"Asia/Shanghai",` +
		`"tz_offset":28800,` +
		`"sim_region":"cn",` +
		`"sim_serial_number":[],` +
		`"oaid_may_support":false,` +
		`"req_id":"` + uuidV4() + `",` +
		`"device_platform":"android",` +
		`"custom":{"account_region_src":"fallback","account_region":"cn","host_bit":64,"dragon_device_type":"phone"},` +
		`"pre_installed_channel":"",` +
		`"apk_first_install_time":` + strconv.FormatInt(now, 10) + `,` +
		`"is_system_app":0,` +
		`"sdk_flavor":"china",` +
		`"guest_mode":0}`
	envelope := `{"magic_tag":"ss_app_log","header":` + header + `,"_gen_time":` + strconv.FormatInt(now, 10) + `}`

	compressed := gzipBytes([]byte(envelope))
	random := make([]byte, 32)
	if _, err := rand.Read(random); err != nil {
		return nil, fmt.Errorf("appchain: register rand: %w", err)
	}
	inner := sha512.Sum512(random)
	salted := append(inner[:], kdfSalt...)
	derived := sha512.Sum512(salted)
	block, err := aes.NewCipher(derived[:16])
	if err != nil {
		return nil, fmt.Errorf("appchain: register cipher: %w", err)
	}
	sum512 := sha512.Sum512(compressed)
	plaintext := append(sum512[:], compressed...)
	padded := pkcs7Pad(plaintext, 16)
	ct := make([]byte, len(padded))
	cipher.NewCBCEncrypter(block, derived[16:32]).CryptBlocks(ct, padded)
	data := append([]byte{0x74, 0x63, 0x05, 0x10, 0x00, 0x00}, random...)
	data = append(data, ct...)

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, registerURL, bytes.NewReader(data))
	if err != nil {
		return nil, fmt.Errorf("appchain: register request: %w", err)
	}
	req.Header.Set("User-Agent", playUA74332)
	req.Header.Set("Accept", "application/json")
	req.Header.Set("Content-Type", "application/octet-stream;tt-data=a")
	req.Header.Set("log-encode-type", "gzip")
	req.Header.Set("x-ss-dp", "8662")
	req.Header.Set("x-ss-req-ticket", strconv.FormatInt(now, 10))
	req.Header.Set("x-vc-bdturing-sdk-version", "4.0.3.cn")
	req.Header.Set("lc", "101")
	req.Header.Set("sdk-version", "2")
	req.Header.Set("passport-sdk-version", "5051452")
	req.Header.Set("x-neptune", "-8|50:51:59:30:40:47:49:39")
	req.Header.Set("x-ss-stub", upperMD5(data))

	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("appchain: register http: %w", err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	var parsed struct {
		Code              int    `json:"code"`
		CodeUpper         int    `json:"Code"`
		Message           string `json:"message"`
		DeviceID          string `json:"device_id_str"`
		DeviceIDNum       uint64 `json:"device_id"`
		InstallID         string `json:"install_id_str"`
		InstallIDNum      uint64 `json:"install_id"`
		Data              *struct {
			DeviceID     string `json:"device_id_str"`
			DeviceIDNum  uint64 `json:"device_id"`
			InstallID    string `json:"install_id_str"`
			InstallIDNum uint64 `json:"install_id"`
		} `json:"data"`
	}
	if err := json.Unmarshal(raw, &parsed); err != nil {
		return nil, fmt.Errorf("appchain: register decode: %w (http %d)", err, resp.StatusCode)
	}
	if parsed.Code != 0 || parsed.CodeUpper != 0 {
		return nil, fmt.Errorf("appchain: register rejected code=%d msg=%q", parsed.Code+parsed.CodeUpper, parsed.Message)
	}
	d := &device{CDID: cdid, CreatedAt: time.Now().UnixMilli()}
	d.DeviceID = firstNonEmpty(parsed.DeviceID, u64str(parsed.DeviceIDNum))
	d.InstallID = firstNonEmpty(parsed.InstallID, u64str(parsed.InstallIDNum))
	if d.DeviceID == "" && parsed.Data != nil {
		d.DeviceID = firstNonEmpty(parsed.Data.DeviceID, u64str(parsed.Data.DeviceIDNum))
		d.InstallID = firstNonEmpty(parsed.Data.InstallID, u64str(parsed.Data.InstallIDNum))
	}
	if d.DeviceID == "" || d.InstallID == "" {
		return nil, fmt.Errorf("appchain: register incomplete: body %.200s", raw)
	}
	var cookies []string
	for _, c := range resp.Cookies() {
		if c.Value == "" {
			continue
		}
		cookies = append(cookies, c.Name+"="+c.Value)
	}
	d.Cookie = strings.Join(cookies, "; ")
	return d, nil
}

func u64str(v uint64) string {
	if v == 0 {
		return ""
	}
	return strconv.FormatUint(v, 10)
}

func firstNonEmpty(vals ...string) string {
	for _, v := range vals {
		if v != "" && v != "0" {
			return v
		}
	}
	return ""
}

func mustHex(s string) []byte {
	b, err := hex.DecodeString(s)
	if err != nil {
		panic(err)
	}
	return b
}

func randUint32() uint32 {
	n, _ := rand.Int(rand.Reader, big.NewInt(1<<32-1))
	return uint32(n.Int64())
}

func randHex(n int) string {
	const digits = "0123456789abcdef"
	b := make([]byte, n)
	for i := range b {
		c, _ := rand.Int(rand.Reader, big.NewInt(16))
		b[i] = digits[c.Int64()]
	}
	return string(b)
}

func uuidV4() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	h := hex.EncodeToString(b)
	return h[0:8] + "-" + h[8:12] + "-" + h[12:16] + "-" + h[16:20] + "-" + h[20:32]
}

func upperMD5(b []byte) string {
	sum := md5.Sum(b)
	return strings.ToUpper(fmt.Sprintf("%x", sum))
}

func pkcs7Pad(b []byte, size int) []byte {
	pad := size - len(b)%size
	return append(b, bytes.Repeat([]byte{byte(pad)}, pad)...)
}

func gzipBytes(b []byte) []byte {
	var buf bytes.Buffer
	w := gzip.NewWriter(&buf)
	_, _ = w.Write(b)
	_ = w.Close()
	return buf.Bytes()
}
