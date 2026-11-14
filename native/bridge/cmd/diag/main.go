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
	"context"
	"errors"
	"flag"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"time"

	"github.com/beilunyang/openhongguo/adapters"
	"github.com/beilunyang/openhongguo/sdk"
)

func main() {
	dir := flag.String("dir", filepath.Join("build", "diag-profile", "diag.json"), "设备档案 JSON 文件路径")
	search := flag.String("search", "", "按剧名搜索，打印命中与 series ID")
	episodes := flag.String("episodes", "", "列出该 series 的分集（编号 + 集 ID）")
	resolve := flag.String("resolve", "", "解析该集的播放模型并做密钥诊断")
	urlMode := flag.String("url", "", "解析该集并打印最高清晰度 URL 与解密密钥")
	flag.Parse()

	if *search == "" && *episodes == "" && *resolve == "" && *urlMode == "" {
		fmt.Fprintln(os.Stderr, "需要一个动作：-search / -episodes / -resolve / -url")
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
		runURL(ctx, c, *urlMode)
	}
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

func runURL(ctx context.Context, c *sdk.Client, episodeID string) {
	pb, err := c.ResolvePlayback(ctx, episodeID, sdk.PlaybackOptions{})
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
