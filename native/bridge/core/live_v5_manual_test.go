package core

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/beilunyang/openhongguo/adapters"
	"github.com/beilunyang/openhongguo/sdk"
)

// 实网手工验收：默认跳过，显式设 AQUAN_LIVE_V5=1 才跑。
//
//	AQUAN_LIVE_V5=1 AQUAN_LIVE_V5_PROFILE=<已注册档案> AQUAN_LIVE_V5_EP=<分集ID> \
//	  go test -mod=vendor ./core -run TestLiveResolveViaV5 -v
//
// 用途：服务端改签名/改端点后，一条命令确认「解析链首级单集 POST 还能出流」，
// 不依赖 app、不消耗额外设备注册（复用给定档案）。
func TestLiveResolveViaV5(t *testing.T) {
	if os.Getenv("AQUAN_LIVE_V5") != "1" {
		t.Skip("set AQUAN_LIVE_V5=1 to run the live playback check")
	}
	profile := os.Getenv("AQUAN_LIVE_V5_PROFILE")
	episode := os.Getenv("AQUAN_LIVE_V5_EP")
	if profile == "" || episode == "" {
		t.Fatal("AQUAN_LIVE_V5_PROFILE / AQUAN_LIVE_V5_EP are required")
	}
	c, err := adapters.NewClient(profile, sdk.Options{DeviceResets: sdk.Int(0)})
	if err != nil {
		t.Fatal(err)
	}
	// 生产路径由 core.New 记住档案路径；测试直接建客户端，需要补记，否则
	// 原生 / 侧车两级拿不到 dataDir。
	rememberProfilePath(c, profile)
	v5ResetForTest()
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	pb, key, source, err := resolveViaV5(ctx, c, episode)
	if err != nil || pb == nil {
		t.Fatalf("resolveViaV5: pb=%v source=%s err=%v", pb, source, err)
	}
	if len(pb.Streams) < 3 {
		t.Fatalf("streams=%d, want >=3", len(pb.Streams))
	}
	if pb.Protected && key.Hex == "" {
		t.Fatal("protected model without content key")
	}
	defs := make([]string, 0, len(pb.Streams))
	for _, s := range pb.Streams {
		defs = append(defs, s.Definition+"/"+s.Codec)
	}
	if !strings.HasPrefix(source, "single") && !strings.HasPrefix(source, "native") &&
		!strings.HasPrefix(source, "pure") && !strings.HasPrefix(source, "sidecar") {
		t.Fatalf("unexpected source %q", source)
	}
	t.Logf("source=%s streams=%d defs=%s key=%v", source, len(pb.Streams), strings.Join(defs, " "), key.Hex != "")
}
