// Package main 是 openhongguo 取流链路的离线诊断命令：不进 app 包，
// 用独立的匿名设备档案在 PC 上复现 search → 集列表 → resolvePlayback，
// 对加密分集现场跑密钥解包并打印结论。用于排查「加密剧集播放失败」时
// 拿到第一手样本（protected / encryption / Derive 是否失败），配合
// ParsePlaybackJSON 的「离线诊断」定位。
//
// 用法：
//
//	go run ./cmd/diag -dir <档案文件> -search <剧名>       # 拿 series ID
//	go run ./cmd/diag -dir <档案文件> -episodes <seriesID> # 拿集 ID
//	go run ./cmd/diag -dir <档案文件> -resolve <episodeID> # 取流 + 密钥诊断
//	go run ./cmd/diag -dir <档案文件> -url <episodeID>     # 打印最高清晰度 URL 与密钥（喂给 mpv 复现）
//
// -dir 指向设备档案 JSON 文件；缺省落到 ./build/diag-profile/diag.json
// （独立于 app 的设备档案，互不影响）。要复现 app 的 CDN 分配时，把
// app 的 aquan_device.json 拷一份再 -dir 指向副本。
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"time"

	"github.com/beilunyang/openhongguo/adapters"
	"github.com/beilunyang/openhongguo/sdk"
	"github.com/beilunyang/openhongguo/sdk/model"
	"github.com/wjsqqj/aquan-core/appchain"
	"github.com/wjsqqj/aquan-core/webplay"
)

func main() {
	dir := flag.String("dir", filepath.Join("build", "diag-profile", "diag.json"), "设备档案 JSON 文件路径")
	search := flag.String("search", "", "按剧名搜索，打印命中与 series ID")
	episodes := flag.String("episodes", "", "列出该 series 的分集（编号 + 集 ID）")
	resolve := flag.String("resolve", "", "解析该集的播放模型并做密钥诊断")
	urlMode := flag.String("url", "", "解析该集并打印最高清晰度 URL 与解密密钥")
	rawMode := flag.String("raw", "", "解析该集并落盘原始响应 JSON（供分析服务端下发全量字段）")
	probe := flag.String("probe", "", "对该集跑编码协商探测矩阵（版本降级/参数猜测），打印各方案的 codec 集")
	danmakuOf := flag.String("danmaku", "", "拉该集前两页弹幕，打印条数（验收弹幕可见性前先确认服务端有货）")
	seriesFor := flag.String("series", "", "弹幕所属的剧 ID（配合 -danmaku）")
	verCode := flag.String("vercode", "", "取流版本档位（配合 -url）：如 60100=兼容转码档位")
	verName := flag.String("vername", "", "取流版本名（配合 -url）：如 6.0.1.0")
	webSeries := flag.String("webplay-sid", "", "用官网 play-info 通道取流：剧集 series_id")
	webEpisode := flag.String("webplay-eid", "", "用官网 play-info 通道取流：分集 item_id")
	webDef := flag.String("webplay-def", "720p", "play-info 清晰度：480p/720p")
	appEpisode := flag.String("appchain-eid", "", "用 App 匿名兜底链路取流：分集 item_id（设备存 -dir 同目录）")
	flag.Parse()

	if *search == "" && *episodes == "" && *resolve == "" && *urlMode == "" && *rawMode == "" && *probe == "" && *danmakuOf == "" && *webSeries == "" && *appEpisode == "" {
		fmt.Fprintln(os.Stderr, "需要一个动作：-search / -episodes / -resolve / -url / -raw / -probe / -danmaku / -webplay-sid / -appchain-eid")
		os.Exit(2)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()

	// appchain / webplay 都不需要先建 SDK client；放在 client 创建之前。
	if *appEpisode != "" {
		runAppChain(ctx, *dir, *appEpisode)
		return
	}
	if *webSeries != "" {
		runWebPlay(ctx, *webSeries, *webEpisode, *webDef)
		return
	}

	c, err := adapters.NewClient(*dir, sdk.Options{})
	if err != nil {
		fmt.Fprintln(os.Stderr, "创建客户端失败:", err)
		os.Exit(1)
	}

	switch {
	case *search != "":
		runSearch(ctx, c, *search)
	case *episodes != "":
		runEpisodes(ctx, c, *episodes)
	case *resolve != "":
		runResolve(ctx, c, *resolve)
	case *urlMode != "":
		runURL(ctx, c, *urlMode, *verCode, *verName)
	case *rawMode != "":
		runRaw(ctx, c, *rawMode)
	case *probe != "":
		runProbe(ctx, c, *probe)
	case *danmakuOf != "":
		runDanmaku(ctx, c, *seriesFor, *danmakuOf)
	}
}

// runDanmaku 拉一集的前两页弹幕：验收「开关打开但没弹幕」前，先确认
// 服务端对这个集（对这台设备）有没有下发。空窗但 hasMore=true 也要翻。
func runDanmaku(ctx context.Context, c *sdk.Client, seriesID, episodeID string) {
	if seriesID == "" {
		fmt.Fprintln(os.Stderr, "-danmaku 需要 -series <剧 ID>")
		os.Exit(2)
	}
	total := 0
	cursor := ""
	var windowEnd int64
	for page := 0; page < 2; page++ {
		p, err := c.ListDanmaku(ctx, seriesID, episodeID, sdk.DanmakuOptions{
			Cursor: cursor,
		})
		if err != nil {
			fmt.Fprintln(os.Stderr, "拉取失败:", err)
			os.Exit(1)
		}
		total += len(p.Items)
		windowEnd = p.EndMS
		fmt.Printf("第%d页: 条数=%d · 窗口=[%d,%d]ms · total=%d · hasMore=%v\n",
			page+1, len(p.Items), p.StartMS, p.EndMS, p.Total, p.HasMore)
		for _, it := range p.Items {
			fmt.Printf("  @%dms %s\n", it.OffsetMS, it.Text)
		}
		if !p.HasMore || p.Cursor == "" {
			break
		}
		cursor = p.Cursor
	}
	fmt.Printf("合计 %d 条（到 %dms）\n", total, windowEnd)
}

// probeCase 是一个协商探测方案：版本档位 + 附加 query 参数。
type probeCase struct {
	name        string
	versionCode string
	versionName string
	extra       [][2]string
}

// runProbe 对同一集按多个候选方案探测返回的编码集，判断服务端是否支持
// 编码协商（老版本客户端拿到 bytevc1/h264 的可能性）。
func runProbe(ctx context.Context, c *sdk.Client, episodeID string) {
	cases := []probeCase{
		{name: "控制组(73932)", versionCode: "73932", versionName: "7.3.9.32"},
		{name: "降级 70300", versionCode: "70300", versionName: "7.0.3.0"},
		{name: "降级 65000", versionCode: "65000", versionName: "6.5.0.0"},
		{name: "降级 60100", versionCode: "60100", versionName: "6.0.1.0"},
		{name: "参数 video_codec=h265", versionCode: "73932", versionName: "7.3.9.32",
			extra: [][2]string{{"video_codec", "h265"}}},
		{name: "参数 video_codec=h264", versionCode: "73932", versionName: "7.3.9.32",
			extra: [][2]string{{"video_codec", "h264"}}},
		{name: "参数 codec_type=h265", versionCode: "73932", versionName: "7.3.9.32",
			extra: [][2]string{{"codec_type", "h265"}}},
		{name: "参数 video_platform=3", versionCode: "73932", versionName: "7.3.9.32",
			extra: [][2]string{{"video_platform", "3"}}},
	}
	for _, tc := range cases {
		codecs, err := c.PlaybackProbe(ctx, episodeID, tc.versionCode, tc.versionName, tc.extra)
		if err != nil {
			fmt.Printf("%-24s 失败: %v\n", tc.name, err)
			continue
		}
		fmt.Printf("%-24s → %v\n", tc.name, codecs)
	}
}

// runRaw 把取流响应的原始 JSON 落盘（文件名 playback-raw-<id>.json），
// 供分析服务端下发但被解析层丢弃的字段（编码变体、清晰度列表等）。
func runRaw(ctx context.Context, c *sdk.Client, episodeID string) {
	raw, pb, err := c.ResolvePlaybackRaw(ctx, episodeID)
	if pb == nil {
		fmt.Fprintln(os.Stderr, "取流失败（无模型）:", err)
		os.Exit(1)
	}
	name := fmt.Sprintf("playback-raw-%s.json", episodeID)
	var indented bytes.Buffer
	if json.Indent(&indented, raw, "", "  ") != nil || indented.Len() == 0 {
		// 原始字节不是合法 JSON（可能是 gzip/protobuf 外层）时原样落盘。
		if werr := os.WriteFile(name, raw, 0o600); werr != nil {
			fmt.Fprintln(os.Stderr, "写盘失败:", werr)
			os.Exit(1)
		}
	} else if werr := os.WriteFile(name, indented.Bytes(), 0o600); werr != nil {
		fmt.Fprintln(os.Stderr, "写盘失败:", werr)
		os.Exit(1)
	}
	fmt.Printf("模型: protected=%v · streams=%d · 错误=%v\n原始 JSON → %s（%d 字节）\n",
		pb.Protected, len(pb.Streams), err, name, len(raw))
}

func runSearch(ctx context.Context, c *sdk.Client, query string) {
	page, err := c.Search(ctx, query, sdk.SearchOptions{PageSize: 10})
	if err != nil {
		fmt.Fprintln(os.Stderr, "搜索失败:", err)
		os.Exit(1)
	}
	for _, s := range page.Items {
		fmt.Printf("%s\t%d集\t%s\n", s.ID, s.EpisodeCount, s.Title)
	}
}

func runEpisodes(ctx context.Context, c *sdk.Client, seriesID string) {
	page, err := c.ListEpisodes(ctx, seriesID, sdk.EpisodeOptions{})
	if err != nil {
		fmt.Fprintln(os.Stderr, "取分集失败:", err)
		os.Exit(1)
	}
	for _, ep := range page.Items {
		playable := "可播"
		if !ep.Playable {
			playable = "禁播"
		}
		fmt.Printf("第%d集\t%s\t%s\n", ep.Number, ep.ID, playable)
	}
}

func runURL(ctx context.Context, c *sdk.Client, episodeID, verCode, verName string) {
	var pb *model.Playback
	var err error
	if verCode != "" && verName != "" {
		pb, err = c.ResolvePlaybackWithVersion(ctx, episodeID, verCode, verName)
	} else {
		pb, err = c.ResolvePlayback(ctx, episodeID, sdk.PlaybackOptions{})
	}
	if pb == nil {
		fmt.Fprintln(os.Stderr, "取流失败（无模型）:", err)
		os.Exit(1)
	}
	stream, serr := pb.Select("")
	if serr != nil {
		fmt.Fprintln(os.Stderr, "选流失败:", serr)
		os.Exit(1)
	}
	fmt.Printf("URL=%s\n", stream.URL)
	if pb.Protected {
		key, kerr := sdk.ContentKey(pb)
		if kerr != nil {
			fmt.Printf("KEY=（解包失败: %v）\n", kerr)
			return
		}
		fmt.Printf("KEY=%s\nKEY_VERSION=%s\n", key.Hex, key.Version)
	}
	if stream.BackupURL != "" {
		fmt.Printf("BACKUP_URL=%s\n", stream.BackupURL)
	}
}

func runResolve(ctx context.Context, c *sdk.Client, episodeID string) {
	pb, err := c.ResolvePlayback(ctx, episodeID, sdk.PlaybackOptions{})
	if pb == nil {
		fmt.Fprintln(os.Stderr, "取流失败（无模型）:", err)
		os.Exit(1)
	}
	fmt.Printf("模型: protected=%v · streams=%d · 错误=%v\n",
		pb.Protected, len(pb.Streams), err)
	for _, s := range pb.Streams {
		host := ""
		if u, perr := url.Parse(s.URL); perr == nil {
			host = u.Host
		}
		fmt.Printf("  %s · codec=%q · enc=%q · protected=%v · hls=%v dash=%v · %s\n",
			s.Definition, s.Codec, s.Encryption, s.Protected, s.HLS, s.Dash, host)
	}
	if pb.Protected || errors.Is(err, sdk.ErrDRMProtected) {
		key, kerr := sdk.ContentKey(pb)
		if kerr != nil {
			fmt.Printf("密钥解包: 失败 → %v\n", kerr)
			fmt.Println("结论: 该集的 spade_a 材料当前 Derive 方案解不开，播放器将拿不到 decryption_key。")
			return
		}
		fmt.Printf("密钥解包: 成功 → version=%s · hex 长度=%d\n",
			key.Version, len(key.Hex))
		fmt.Println("结论: 密钥能解开；播放失败另有原因（对照 encryption 方案与 mpv 日志）。")
	}
}

// runWebPlay 用官网 protected/play-info 通道取流，验证旧 App 接口空响应时
// 新通道能否拿到完整播放模型与内容密钥。只读探测，不改任何档案。
func runWebPlay(ctx context.Context, seriesID, episodeID, definition string) {
	if episodeID == "" {
		fmt.Fprintln(os.Stderr, "-webplay-sid 需要同时给 -webplay-eid <分集ID>")
		os.Exit(2)
	}
	pb, key, err := webplay.Resolve(ctx, nil, seriesID, episodeID, definition)
	if err != nil && pb == nil {
		fmt.Fprintln(os.Stderr, "webplay 取流失败:", err)
		os.Exit(1)
	}
	fmt.Printf("webplay: series=%s episode=%s def=%s\n", seriesID, episodeID, definition)
	if err != nil {
		fmt.Printf("  注意(密钥/部分解析): %v\n", err)
	}
	if pb == nil {
		fmt.Println("RESULT=EMPTY")
		return
	}
	fmt.Printf("RESULT=OK protected=%v streams=%d audio=%t duration=%ds expires=%d\n",
		pb.Protected, len(pb.Streams), pb.AudioURL != "", pb.DurationSeconds, pb.ExpiresAt)
	for _, s := range pb.Streams {
		host := ""
		if u, perr := url.Parse(s.URL); perr == nil {
			host = u.Host
		}
		fmt.Printf("  def=%q codec=%q enc=%q dash=%v size=%d · %s\n",
			s.Definition, s.Codec, s.Encryption, s.Dash, s.Size, host)
	}
	fmt.Printf("  contentKey hex=%s version=%s (len=%d)\n", key.Hex, key.Version, len(key.Hex))
}

// runAppChain 用 App 匿名兜底链路取流（2026-11-17 方案 A）：lf 加密注册 +
// multi 五集群轮换 + shortplay 降级。生态故障期返回 ErrUnavailable 属预期，
// 用于观察链路何时恢复。
func runAppChain(ctx context.Context, profilePath, episodeID string) {
	pb, key, err := appchain.Resolve(ctx, nil, profilePath, episodeID)
	if err != nil && pb == nil {
		fmt.Fprintln(os.Stderr, "appchain 取流失败:", err)
		os.Exit(1)
	}
	fmt.Printf("appchain: episode=%s\n", episodeID)
	if err != nil {
		fmt.Printf("  注意(密钥派生): %v\n", err)
	}
	if pb == nil {
		fmt.Println("RESULT=EMPTY")
		return
	}
	fmt.Printf("RESULT=OK protected=%v streams=%d audio=%t duration=%ds expires=%d\n",
		pb.Protected, len(pb.Streams), pb.AudioURL != "", pb.DurationSeconds, pb.ExpiresAt)
	for _, s := range pb.Streams {
		host := ""
		if u, perr := url.Parse(s.URL); perr == nil {
			host = u.Host
		}
		fmt.Printf("  def=%q codec=%q enc=%q dash=%v size=%d · %s\n",
			s.Definition, s.Codec, s.Encryption, s.Dash, s.Size, host)
	}
	fmt.Printf("  contentKey hex=%s version=%s (len=%d)\n", key.Hex, key.Version, len(key.Hex))
}
