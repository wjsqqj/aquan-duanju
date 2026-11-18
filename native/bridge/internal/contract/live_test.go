//go:build live

// Package contract 的 live 巡检：走一次用户真实路径，确认服务端没有改版。
// 只在 -tags live 下编译，默认 CI 不跑（避免网络抖动误报）。
//
//	go test -tags live -v ./internal/contract/...
//
// 任何一步失败都会记录并继续后面的步骤，便于一次拿到完整现场。
package contract

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/beilunyang/openhongguo/adapters"
	"github.com/beilunyang/openhongguo/sdk"
	"github.com/wjsqqj/aquan-core/core"
)

var (
	liveQueryTimeout = 60 * time.Second
	liveURLQuery     = regexp.MustCompile(`(https?://[^\s?#"]+)\?[^\s"]*`)
)

// redact 抹掉完整 URL 的查询串并截断，报告里不出现地址与密钥。
func redact(raw []byte) string {
	s := liveURLQuery.ReplaceAllString(string(raw), "$1?…")
	if len(s) > 300 {
		s = s[:300] + "…"
	}
	return s
}

func newSDKClient(t *testing.T) *sdk.Client {
	t.Helper()
	profile := filepath.Join(t.TempDir(), "sdk.json")
	c, err := adapters.NewClient(profile, sdk.Options{})
	if err != nil {
		t.Fatalf("sdk client: %v", err)
	}
	return c
}

func newCoreHandle(t *testing.T) int32 {
	t.Helper()
	profile := filepath.Join(t.TempDir(), "core.json")
	out := core.New(profile, "{}")
	var env struct {
		Result struct {
			Handle int32 `json:"handle"`
		} `json:"result"`
		Error json.RawMessage `json:"error"`
	}
	if err := json.Unmarshal([]byte(out), &env); err != nil || env.Result.Handle == 0 {
		t.Fatalf("core.New: %s", redact([]byte(out)))
	}
	return env.Result.Handle
}

func coreCall(t *testing.T, h int32, method string, args ...any) (json.RawMessage, error) {
	t.Helper()
	raw, err := json.Marshal(args)
	if err != nil {
		t.Fatal(err)
	}
	out := core.Call(h, method, string(raw))
	var env struct {
		Result json.RawMessage `json:"result"`
		Error  json.RawMessage `json:"error"`
	}
	if err := json.Unmarshal([]byte(out), &env); err != nil {
		return nil, fmt.Errorf("%s: decode: %v", method, err)
	}
	if len(env.Error) > 0 && string(env.Error) != "null" {
		return nil, fmt.Errorf("%s: %s", method, redact(env.Error))
	}
	return env.Result, nil
}

// TestLiveEndToEnd 是巡检主体：发现 → 搜索 → 分集 → 取流 → 密钥 →（可选）解帧 → 弹幕。
func TestLiveEndToEnd(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), liveQueryTimeout)
	defer cancel()

	client := newSDKClient(t)
	var failures []string
	fail := func(step string, err error) {
		if err != nil {
			failures = append(failures, fmt.Sprintf("%s: %v", step, err))
			t.Logf("FAIL %s: %v", step, err)
		}
	}

	// 1. 发现
	discover, derr := client.Discover(ctx, sdk.DiscoverOptions{})
	fail("discover", derr)
	if derr == nil && (discover == nil || len(discover.Items) == 0) {
		fail("discover", fmt.Errorf("empty item list"))
	}

	// 2. 搜索
	page, serr := client.Search(ctx, liveSearchQuery(), sdk.SearchOptions{})
	fail("search", serr)
	var seriesID string
	if serr == nil && page != nil && len(page.Items) > 0 {
		seriesID = page.Items[0].ID
	}
	if seriesID == "" {
		fail("search", fmt.Errorf("no series id"))
		t.Fatalf("巡检中断，前面的失败：%v", failures)
	}

	// 3. 分集
	eps, eerr := client.ListEpisodes(ctx, seriesID, sdk.EpisodeOptions{})
	fail("episodes", eerr)
	var episodeID string
	if eerr == nil && eps != nil && len(eps.Items) > 0 {
		episodeID = eps.Items[0].ID
	}
	if episodeID == "" {
		fail("episodes", fmt.Errorf("no episode id"))
		t.Fatalf("巡检中断，前面的失败：%v", failures)
	}

	// 4. 取流（走 app 真实链路：core 的 resolvePlaybackWeb）
	h := newCoreHandle(t)
	res, rerr := coreCall(t, h, "resolvePlaybackWeb", seriesID, episodeID, "")
	fail("playback", rerr)
	var playback struct {
		Channel    string `json:"channel"`
		ContentKey *struct {
			Key string `json:"key"`
		} `json:"contentKey"`
		Playback struct {
			Protected bool `json:"protected"`
			Streams   []struct {
				Definition string `json:"definition"`
				Codec      string `json:"codec"`
				URL        string `json:"url"`
			} `json:"streams"`
		} `json:"playback"`
	}
	if rerr == nil {
		if err := json.Unmarshal(res, &playback); err != nil {
			fail("playback", fmt.Errorf("decode: %v", err))
		} else {
			t.Logf("channel=%s protected=%v streams=%d key=%v",
				playback.Channel, playback.Playback.Protected,
				len(playback.Playback.Streams), playback.ContentKey != nil)
			if len(playback.Playback.Streams) == 0 {
				fail("playback", fmt.Errorf("no streams (channel %s)", playback.Channel))
			}
			if playback.Playback.Protected && playback.ContentKey == nil {
				fail("contentkey", fmt.Errorf("protected stream without content key"))
			}
		}
	}

	// 5. 可选：解 8 秒确认密钥与地址都能用
	if rerr == nil && playback.ContentKey != nil && len(playback.Playback.Streams) > 0 {
		if _, lookErr := exec.LookPath("ffmpeg"); lookErr != nil {
			t.Log("skip decrypt: ffmpeg not on PATH")
		} else if err := decryptProbe(playback.ContentKey.Key, playback.Playback.Streams[0].URL); err != nil {
			fail("decrypt", err)
		}
	}

	// 6. 弹幕
	dm, dmErr := client.ListDanmaku(ctx, seriesID, episodeID, sdk.DanmakuOptions{})
	fail("danmaku", dmErr)
	if dmErr == nil {
		if len(dm.Items) == 0 {
			t.Logf("WARN danmaku: page 1 empty (server sends a curated subset)")
		} else {
			t.Logf("danmaku page1 items=%d total=%d", len(dm.Items), dm.Total)
		}
	}

	if len(failures) > 0 {
		t.Fatalf("live 巡检失败 %d 项:\n%s", len(failures), strings.Join(failures, "\n"))
	}
}

func liveSearchQuery() string {
	if q := os.Getenv("OHG_LIVE_QUERY"); q != "" {
		return q
	}
	return "全球死考"
}

// decryptProbe 用 ffmpeg 拉 8 秒解到 null：证明密钥可用、地址可播。
func decryptProbe(key, url string) error {
	if key == "" || url == "" {
		return fmt.Errorf("empty key or url")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "ffmpeg", "-v", "error", "-decryption_key", key,
		"-i", url, "-t", "8", "-f", "null", "-")
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("ffmpeg: %v (%.200s)", err, redact(out))
	}
	return nil
}
