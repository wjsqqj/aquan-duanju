package hongguov5

// device.go — 匿名设备注册（移植自 sidecar v5register.py）：
// snssdk + TTEncrypt（ssovit MIT 表达）+ 小米14/73932 姿势。上下文持久化为
// 明文 JSON（设备标识，无凭据；与 aquan_device.json 同级敏感度）。

import (
	"bytes"
	"compress/gzip"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/cookiejar"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const (
	registerURL = "https://log.snssdk.com/service/2/device_register/"
	versionCode = "73932"
	versionName = "7.3.9.32"
	deviceUA    = "com.phoenix.read/73932 (Linux; U; Android 14; zh_CN; Xiaomi 14; " +
		"Build/UKQ1.230804.001; Cronet/TTNetVersion:8d40f833 " +
		"QuicVersion:462f352c 2026-08-31)"
	cookieNames   = "odin_tt|ttreq|store-region|store-region-src"
	maxRegisterRR = 2 * 1024 * 1024
)

var cookieNameRE = regexp.MustCompile(`^(` + cookieNames + `)$`)
var validIDRE = regexp.MustCompile(`^[0-9]{5,30}$`)

// registerParams 注册请求的查询参数（与 python params dict 一致，全字符串）。
func registerParams(ms int64, cdid, openudid string) map[string]string {
	return map[string]string{
		"aid": "8662", "app_name": "novelread", "channel": "xiaomi_8662_64",
		"version_code": versionCode, "version_name": versionName,
		"manifest_version_code": versionCode, "update_version_code": versionCode,
		"device_platform": "android", "os": "android", "ssmix": "a",
		"device_type": "23127PN0CC", "device_brand": "xiaomi", "os_api": "34",
		"os_version": "14", "resolution": "1200*2670", "dpi": "460", "ac": "wifi",
		"language": "zh", "openudid": openudid, "cdid": cdid, "tt_data": "a",
		"_rticket": strconv.FormatInt(ms, 10), "ts": strconv.FormatInt(ms/1000, 10),
		"package": "com.phoenix.read", "first_launch_timestamp": strconv.FormatInt(ms/1000, 10),
		"last_deeplink_update_version_code": "0", "cpu_support64": "true",
		"host_abi": "arm64-v8a", "is_guest_mode": "0", "app_type": "normal",
		"minor_status": "0", "appTheme": "light", "is_preinstall": "0",
		"need_personal_recommend": "1", "is_android_pad": "0", "is_android_fold": "0",
		"md": "0", "cronet_version": "8d40f833_2026-03-03", "ttnet_version": "4.2.243.31-douyin",
		"use_store_region_cookie": "1",
	}
}

// registerPayloadJSON 手工保序组装（python json.dumps ensure_ascii=False 插入序）。
func registerPayloadJSON(headerJSON string, ms int64) string {
	return `{"magic_tag":"ss_app_log","header":` + headerJSON +
		`,"_gen_time":` + strconv.FormatInt(ms, 10) + `}`
}

// registerHeaderJSON header dict 的保序 JSON（类型按 python：int/bool/str/list）。
func registerHeaderJSON(ms int64, cdid, openudid, clientudid, reqID string) string {
	return `{"access":"wifi","aid":8662,"app_version":"` + versionName + `","app_version_minor":"",` +
		`"apk_first_install_time":` + strconv.FormatInt(ms, 10) + `,"cdid":"` + cdid + `",` +
		`"channel":"xiaomi_8662_64","clientudid":"` + clientudid + `","cpu_abi":"arm64-v8a",` +
		`"density_dpi":460,"device_brand":"xiaomi","device_category":"phone",` +
		`"device_manufacturer":"Xiaomi","device_model":"Xiaomi 14","device_platform":"android",` +
		`"display_density":"xxhdpi","display_name":"红果短剧","git_hash":"fe95b95",` +
		`"guest_mode":0,"ipv6_list":[],"is_system_app":0,"language":"zh",` +
		`"manifest_version_code":` + versionCode + `,"not_request_sender":0,` +
		`"oaid_may_support":true,"openudid":"` + openudid + `","os":"Android",` +
		`"os_api":34,"os_version":"14","package":"com.phoenix.read","region":"CN",` +
		`"release_build":"UKQ1.230804.001_1701234567","req_id":"` + reqID + `",` +
		`"resolution":"2670x1200","rom":"hyperos","rom_version":"OS1.0.32.0.UNCCNXM",` +
		`"sdk_flavor":"china","sdk_target_version":29,"sdk_version":"3.7.3-rc.116-douyin",` +
		`"sig_hash":"aea615ab910015038f73c47e45d21466","sim_serial_number":[],` +
		`"timezone":8,"tz_name":"Asia/Shanghai","tz_offset":28800,` +
		`"update_version_code":` + versionCode + `,"version_code":` + versionCode + `,` +
		`"custom":{"is_android_fold":0,"filter_warn":0,"is_android_pad":0,` +
		`"client_ipv4":"0.0.0.0","web_ua":"Mozilla/5.0 (Linux; Android 14; Xiaomi 14 ` +
		`Build/UKQ1.230804.001; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 ` +
		`Chrome/120.0.0.0 Mobile Safari/537.36"}}`
}

func registerQuery(params map[string]string) string {
	// python: "&".join(f"{k}={v}" for k, v in sorted(params.items())) —— 无转义、按 key 排序。
	keys := make([]string, 0, len(params))
	for k := range params {
		keys = append(keys, k)
	}
	sortStrings(keys)
	parts := make([]string, 0, len(keys))
	for _, k := range keys {
		parts = append(parts, k+"="+params[k])
	}
	return strings.Join(parts, "&")
}

func sortStrings(list []string) {
	for i := 1; i < len(list); i++ {
		for j := i; j > 0 && list[j] < list[j-1]; j-- {
			list[j], list[j-1] = list[j-1], list[j]
		}
	}
}

// prepareRegistration 产出注册请求（body = TT(payload)；golden 对拍覆盖）。
func prepareRegistration(ms int64, ent *entropySource) (string, []byte, map[string]string, map[string]string, error) {
	cdid := ent.UUID()
	openudid := ent.TokenHex(8)
	params := registerParams(ms, cdid, openudid)
	clientudid := ent.UUID()
	reqID := ent.UUID()
	payload := registerPayloadJSON(registerHeaderJSON(ms, cdid, openudid, clientudid, reqID), ms)
	body, err := ttEncrypt([]byte(payload), ent.TokenBytes(32))
	if err != nil {
		return "", nil, nil, nil, err
	}
	seconds := ms / 1000
	stubSum := md5Sum(body)
	headers := map[string]string{
		"Content-Type":              "application/octet-stream;tt-data=a",
		"Content-Encoding":          "gzip",
		"Accept-Encoding":           "gzip",
		"User-Agent":                deviceUA,
		"Accept":                    "application/json; charset=utf-8,application/x-protobuf",
		"X-SS-STUB":                 strings.ToUpper(hexEncode(stubSum)),
		"X-SS-DP":                   "8662",
		"X-SS-REQ-TICKET":           strconv.FormatInt(ms, 10),
		"X-Khronos":                 strconv.FormatInt(seconds, 10),
		"X-Argus":                   b64Encode(le32pack(uint32(seconds))),
		"X-TT-Request-Tag":          "t=0;n=1",
		"Log-Encode-Type":           "gzip",
		"Passport-SDK-Version":      "60755",
		"Passport-SDK-Settings":     "device_transfer_s_0,device_transfer_ab_1",
		"Sdk-Version":               "2",
		"lc":                        "102",
		"X-TT-Store-Region":         "cn",
		"X-TT-Store-Region-Src":     "did",
		"X-VC-Bdturing-SDK-Version": "4.0.3.cn",
	}
	return registerURL + "?" + registerQuery(params), body, headers, params, nil
}

// parseIdentity 解析注册响应（明文 JSON 或 tt 帧）。
func parseIdentity(payload []byte) (deviceID, iid, deviceToken string, err error) {
	raw := payload
	if len(payload) > 4 && payload[0] == 't' && payload[1] == 'c' &&
		payload[2] == 0x05 && payload[3] == 0x10 {
		text, derr := ttDecrypt(payload)
		if derr != nil {
			return "", "", "", derr
		}
		raw = []byte(text)
	}
	var value struct {
		DeviceID     any `json:"device_id_str"`
		DeviceIDNum  any `json:"device_id"`
		InstallID    any `json:"install_id_str"`
		InstallIDNum any `json:"install_id"`
		DeviceToken  any `json:"device_token"`
	}
	if err := json.Unmarshal(raw, &value); err != nil {
		return "", "", "", err
	}
	deviceID = anyToID(value.DeviceID, value.DeviceIDNum)
	iid = anyToID(value.InstallID, value.InstallIDNum)
	if !validIDRE.MatchString(deviceID) || !validIDRE.MatchString(iid) {
		return "", "", "", fmt.Errorf("%w: device-not-issued", errSession)
	}
	deviceToken, _ = value.DeviceToken.(string)
	if len(deviceToken) > 8192 {
		return "", "", "", fmt.Errorf("%w: invalid-device-token", errSession)
	}
	return deviceID, iid, deviceToken, nil
}

func anyToID(primary, fallback any) string {
	switch v := primary.(type) {
	case string:
		return v
	case float64:
		return strconv.FormatInt(int64(v), 10)
	}
	switch v := fallback.(type) {
	case string:
		return v
	case float64:
		return strconv.FormatInt(int64(v), 10)
	}
	return ""
}

// deviceState 持久化上下文。
type deviceState struct {
	Params      map[string]string `json:"params"`
	DeviceToken string            `json:"device_token"`
	Cookies     map[string]string `json:"cookies"`
	UserAgent   string            `json:"user_agent"`
	CreatedAt   int64             `json:"created_at"`
}

// ensureDevice 读缓存或注册新设备。
func ensureDevice(dataDir string, ent *entropySource) (*deviceState, error) {
	path := filepath.Join(dataDir, "hongguo-device.json")
	if raw, err := os.ReadFile(path); err == nil {
		var state deviceState
		if err := json.Unmarshal(raw, &state); err == nil &&
			state.Params != nil && state.Params["device_id"] != "" && state.Params["iid"] != "" {
			return &state, nil
		}
	}
	url, body, headers, params, err := prepareRegistration(timeNowMS(), ent)
	if err != nil {
		return nil, err
	}
	jar, _ := cookiejar.New(nil)
	client := &http.Client{
		Transport: &http.Transport{Proxy: nil},
		Timeout:   30 * time.Second,
		Jar:       jar,
	}
	req, err := http.NewRequest("POST", url, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("%w: register-http-%d", errSession, resp.StatusCode)
	}
	payload, err := io.ReadAll(io.LimitReader(resp.Body, maxRegisterRR+1))
	if err != nil {
		return nil, err
	}
	if int64(len(payload)) > maxRegisterRR {
		return nil, fmt.Errorf("%w: response-too-large", errSession)
	}
	if len(payload) >= 2 && payload[0] == 0x1f && payload[1] == 0x8b {
		gz, gerr := gzip.NewReader(bytes.NewReader(payload))
		if gerr != nil {
			return nil, gerr
		}
		payload, err = io.ReadAll(io.LimitReader(gz, maxRegisterRR+1))
		if err != nil {
			return nil, err
		}
		if int64(len(payload)) > maxRegisterRR {
			return nil, fmt.Errorf("%w: response-too-large", errSession)
		}
	}
	deviceID, iid, deviceToken, err := parseIdentity(payload)
	if err != nil {
		return nil, err
	}
	cookies := map[string]string{}
	for _, c := range resp.Cookies() {
		if cookieNameRE.MatchString(c.Name) && c.Value != "" && len(c.Value) < 8192 &&
			isPrintableASCII(c.Value) {
			cookies[c.Name] = c.Value
		}
	}
	// python 侧 store-region-src 由服务端 Set-Cookie 或默认 did；注册响应通常无此键。
	state := &deviceState{
		Params:      withDevice(params, deviceID, iid),
		DeviceToken: deviceToken,
		Cookies:     cookies,
		UserAgent:   deviceUA,
		CreatedAt:   time.Now().Unix(),
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

func withDevice(params map[string]string, deviceID, iid string) map[string]string {
	out := make(map[string]string, len(params)+2)
	for k, v := range params {
		out[k] = v
	}
	out["device_id"] = deviceID
	out["iid"] = iid
	out["sdkid"] = ""
	out["subaid"] = ""
	out["bd_did"] = ""
	out["klink_egdi"] = ""
	return out
}

func isPrintableASCII(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] < 32 || s[i] > 126 {
			return false
		}
	}
	return true
}

// newUUID 生成 RFC4122 v4 风格字符串（python uuid4 等价）。
func newUUID() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic(err)
	}
	b[6] = (b[6] & 0x0F) | 0x40
	b[8] = (b[8] & 0x3F) | 0x80
	const hexDigits = "0123456789abcdef"
	out := make([]byte, 0, 36)
	for i, v := range b {
		if i == 4 || i == 6 || i == 8 || i == 10 {
			out = append(out, '-')
		}
		out = append(out, hexDigits[v>>4], hexDigits[v&15])
	}
	return string(out)
}
