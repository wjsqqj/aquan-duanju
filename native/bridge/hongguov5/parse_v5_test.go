package hongguov5

// parse_v5_test.go — v5 响应解析契约：平铺 / 1004 分组 / 缺集直接失败 /
// key_seed 信封地址解码 / 信封过期时间。走 sdk.ParsePlaybackJSON（真实消费面）。

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/sha512"
	"encoding/base64"
	"strings"
	"testing"

	"github.com/beilunyang/openhongguo/sdk"
)

const testEpisodeID = "7678678090448374846"

// playbackURLSeedConstants 与 internal/protocol/playback_url.go 同一份互操作常量。
var playbackURLSeedConstants = []byte{
	0x4d, 0xd4, 0xc2, 0xe6, 0xb8, 0x31, 0x62, 0x09, 0x0e, 0x52, 0xb3, 0xc7, 0xa6, 0x73, 0x3b, 0xa4,
	0x1c, 0xb2, 0x46, 0x2b, 0x82, 0x9a, 0xb5, 0x8a, 0x19, 0x6b, 0x39, 0xdb, 0x57, 0x17, 0x75, 0x24,
	0xf4, 0x9b, 0xaf, 0x7f, 0x08, 0xe8, 0xd6, 0x8d, 0x26, 0xa7, 0x2e, 0x37, 0xc1, 0xa9, 0x5a, 0x2f,
	0x1f, 0x05, 0xa5, 0x18, 0x92, 0xae, 0xf2, 0x94, 0x97, 0x32, 0xb6, 0x2a, 0x38, 0xaa, 0xdd, 0x58,
}

func testModel(expiry string, items string) string {
	return `{"video_id":"v-test","video_duration":75.4` + expiry +
		`,"video_list":[` + items + `]}`
}

const plainItem = `{"main_url":"https://v/360.mp4","vwidth":640,"vheight":360,` +
	`"definition":"360p","encrypt_info":{"spade_a":"abc"}}`

func TestParsePlaybackFlatLayout(t *testing.T) {
	raw := `{"code":0,"data":{"` + testEpisodeID + `":{"video_model":` +
		testModel(`,"url_expire":1794934133`, plainItem) + `}}}`
	pb, err := sdk.ParsePlaybackJSON([]byte(raw), testEpisodeID)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if len(pb.Streams) != 1 || pb.Streams[0].URL != "https://v/360.mp4" {
		t.Fatalf("streams = %+v", pb.Streams)
	}
	if !pb.Streams[0].Protected {
		t.Fatalf("protection lost: %+v", pb.Streams[0])
	}
	if pb.ExpiresAt != 1794934133 || pb.VideoID != "v-test" {
		t.Fatalf("meta = %+v", pb)
	}
}

func TestParsePlaybackGroupedLayout(t *testing.T) {
	raw := `{"code":0,"data":{"1004":{"` + testEpisodeID + `":{"video_model":"` +
		strings.ReplaceAll(testModel(`,"url_expire":1`, plainItem), `"`, `\"`) + `"}}}}`
	pb, err := sdk.ParsePlaybackJSON([]byte(raw), testEpisodeID)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if len(pb.Streams) != 1 || pb.Streams[0].URL != "https://v/360.mp4" {
		t.Fatalf("streams = %+v", pb.Streams)
	}
}

func TestParsePlaybackGroupedMissingEpisode(t *testing.T) {
	raw := `{"code":0,"data":{"1004":{"7000000000000000001":{"video_model":` +
		testModel(`,"url_expire":1`, plainItem) + `}}}}`
	if _, err := sdk.ParsePlaybackJSON([]byte(raw), testEpisodeID); err == nil {
		t.Fatal("缺失本集时应报错，不能拿同响应其他集顶替")
	}
}

func TestParsePlaybackKeySeedURL(t *testing.T) {
	seed := base64.RawURLEncoding.EncodeToString([]byte("seed-material-for-test"))
	sealed := sealPlaybackURL(t, "https://v/secret.mp4", seed)
	item := `{"main_url":"` + sealed + `","backup_url_2":"https://v/backup.mp4",` +
		`"vwidth":1920,"vheight":1080,"definition":"1080p"}`
	raw := `{"code":0,"data":{"` + testEpisodeID + `":{"video_model":` +
		testModel(`,"url_expire":1,"key_seed":"`+seed+`"`, item) + `}}}`
	pb, err := sdk.ParsePlaybackJSON([]byte(raw), testEpisodeID)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if len(pb.Streams) != 1 {
		t.Fatalf("streams = %+v", pb.Streams)
	}
	s := pb.Streams[0]
	if s.URL != "https://v/secret.mp4" {
		t.Fatalf("main url = %q", s.URL)
	}
	if s.BackupURL != "https://v/backup.mp4" {
		t.Fatalf("backup url = %q", s.BackupURL)
	}
}

func TestParsePlaybackEnvelopeExpiry(t *testing.T) {
	raw := `{"code":0,"data":{"expire_time":"1794999999","` + testEpisodeID +
		`":{"video_model":` + testModel("", plainItem) + `}}}`
	pb, err := sdk.ParsePlaybackJSON([]byte(raw), testEpisodeID)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if pb.ExpiresAt != 1794999999 {
		t.Fatalf("expiresAt = %d", pb.ExpiresAt)
	}
}

// sealPlaybackURL 按信封格式加密地址，供解码路径对拍。
func sealPlaybackURL(t *testing.T, address, seedBase64 string) string {
	t.Helper()
	seed, err := base64.RawURLEncoding.DecodeString(strings.TrimRight(seedBase64, "="))
	if err != nil {
		t.Fatalf("seed: %v", err)
	}
	first := sha512.Sum512(seed)
	key := sha512.Sum512(append(first[:], playbackURLSeedConstants...))
	block, err := aes.NewCipher(key[:16])
	if err != nil {
		t.Fatalf("cipher: %v", err)
	}
	padding := aes.BlockSize - len(address)%aes.BlockSize
	plain := append([]byte(address), bytes.Repeat([]byte{byte(padding)}, padding)...)
	out := make([]byte, len(plain)+4)
	out[0], out[2] = 0xa8, 1
	cipher.NewCBCEncrypter(block, key[16:32]).CryptBlocks(out[4:], plain)
	return base64.RawURLEncoding.EncodeToString(out)
}
