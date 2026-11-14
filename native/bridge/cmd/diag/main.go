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
)

func main() {
	dir := flag.String("dir", filepath.Join("build", "diag-profile", "diag.json"), "设备档案 JSON 文件路径")
	search := flag.String("search", "", "按剧名搜索，打印命中与 series ID")
	episodes := flag.String("episodes", "", "列出该 series 的分集（编号 + 集 ID）")
	resolve := flag.String("resolve", "", "解析该集的播放模型并做密钥诊断")
	urlMode := flag.String("url", "", "解析该集并打印最高清晰度 URL 与解密密钥")
	rawMode := flag.String("raw", "", "解析该集并落盘原始响应 JSON（供分析服务端下发全量字段）")
	probe := flag.String("probe", "", "对该集跑编码协商探测矩阵（版本降级/参数猜测），打印各方案的 codec 集")
	verCode := flag.String("vercode", "", "取流版本档位（配合 -url）：如 60100=兼容转码档位")
	verName := flag.String("vername", "", "取流版本名（配合 -url）：如 6.0.1.0")
	flag.Parse()

	if *search == "" && *episodes == "" && *resolve == "" && *urlMode == "" && *rawMode == "" && *probe == "" {
		fmt.Fprintln(os.Stderr, "需要一个动作：-search / -episodes / -resolve / -url / -raw / -probe")
		os.Exit(2)
	}
	c, err := adapters.NewClient(*dir, sdk.Options{})
	if err != nil {
		fmt.Fprintln(os.Stderr, "创建客户端失败:", err)
		os.Exit(1)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()

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
	}
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
