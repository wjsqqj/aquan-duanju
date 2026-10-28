// Command aquan-cli 是阿圈短剧的命令行入口，给 AI 助手 / 脚本使用。
//
//	aquan-cli search 持械入宋 [--limit 10] [--json]  只查列表，不打开窗口
//	aquan-cli watch  持械入宋                         搜索并挑最匹配的一部开播
//	aquan-cli series <ID>                            直接开播这一部（有历史就续播）
//
// 它复用 native/bridge/core 的方法表（/search 走 openhongguo SDK），
// 与图形界面使用同一套接口与错误码。搜到的列表只在本次输出里有效，
// 下一步请把输出里的 ID 传给 series。
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"github.com/wjsqqj/aquan-core/core"
)

const usage = `阿圈短剧命令行入口（供 AI 助手 / 脚本使用）

用法：
  aquan-cli search <关键词> [--limit 10] [--json]
      只查一次搜索列表，打印到 stdout 后退出，不打开窗口。
  aquan-cli watch <关键词>
      搜索并挑标题最匹配的一部开播（与裸参数等价）。
  aquan-cli series <剧集ID>
      打开并直接播放这一部；有观看历史时从上次那一集那一秒续播。

选项：
  --limit N   搜索结果条数，默认 10，最多 50
  --json      以 JSON 输出搜索结果（方便程序处理）
  --app PATH  指定阿圈短剧可执行文件（默认找同目录下的 aquan_duanju）
`

type item struct {
	ID           string `json:"id"`
	Title        string `json:"title"`
	EpisodeCount int    `json:"episode_count"`
}

type page struct {
	Items   []item `json:"items"`
	Cursor  string `json:"cursor"`
	HasMore bool   `json:"has_more"`
}

type envelope struct {
	Result json.RawMessage `json:"result"`
	Error  *struct {
		Code    string `json:"code"`
		Message string `json:"message"`
	} `json:"error"`
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprint(os.Stderr, usage)
		os.Exit(2)
	}
	cmd := os.Args[1]
	args := os.Args[2:]
	switch cmd {
	case "-h", "--help", "help":
		fmt.Print(usage)
		return
	case "version", "--version", "-v":
		fmt.Println(core.Version)
		return
	case "search":
		if err := runSearch(args); err != nil {
			fail(err)
		}
	case "watch":
		if err := runWatch(args); err != nil {
			fail(err)
		}
	case "series":
		if err := runSeries(args); err != nil {
			fail(err)
		}
	default:
		// 裸参数等价于 watch。
		if err := runWatch(os.Args[1:]); err != nil {
			fail(err)
		}
	}
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, "搜索失败："+err.Error())
	os.Exit(1)
}

// splitArgs 把参数分成位置参数与开关：开关可以出现在关键词前后
// （标准库 flag 遇到第一个位置参数就停止解析，`search 剧名 --limit 5` 会被误当成关键词）。
type options struct {
	positional []string
	limit      int
	json       bool
	app        string
}

func splitArgs(args []string, defaults options) options {
	out := defaults
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--limit", "-limit":
			if i+1 < len(args) {
				i++
				if n, err := strconv.Atoi(args[i]); err == nil {
					out.limit = n
				}
			}
		case "--app", "-app":
			if i+1 < len(args) {
				i++
				out.app = args[i]
			}
		case "--json", "-json":
			out.json = true
		default:
			out.positional = append(out.positional, args[i])
		}
	}
	if out.limit <= 0 {
		out.limit = 10
	}
	if out.limit > 50 {
		out.limit = 50
	}
	return out
}

func runSearch(args []string) error {
	opt := splitArgs(args, options{limit: 10})
	query := strings.TrimSpace(strings.Join(opt.positional, " "))
	if query == "" {
		return errors.New("缺少搜索关键词")
	}
	p, err := search(query, opt.limit)
	if err != nil {
		return err
	}
	if opt.json {
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		return enc.Encode(p)
	}
	printPage(query, p, opt.limit)
	return nil
}

func runWatch(args []string) error {
	opt := splitArgs(args, options{limit: 10})
	query := strings.TrimSpace(strings.Join(opt.positional, " "))
	if query == "" {
		return errors.New("缺少搜索关键词")
	}
	p, err := search(query, opt.limit)
	if err != nil {
		return err
	}
	best := bestMatch(query, p.Items)
	if best == nil {
		return fmt.Errorf("没有搜到《%s》的可用结果", query)
	}
	fmt.Printf("正在播放《%s》  ID %s\n", best.Title, best.ID)
	return launchApp(opt.app, best.ID)
}

func runSeries(args []string) error {
	opt := splitArgs(args, options{limit: 10})
	if len(opt.positional) == 0 || strings.TrimSpace(opt.positional[0]) == "" {
		return errors.New("缺少剧集 ID")
	}
	return launchApp(opt.app, strings.TrimSpace(opt.positional[0]))
}

func search(query string, limit int) (*page, error) {
	profile := filepath.Join(configDir(), "aquan-cli-device.json")
	envRaw := core.New(profile, "")
	var env envelope
	if err := json.Unmarshal([]byte(envRaw), &env); err != nil {
		return nil, fmt.Errorf("核心返回无法解析：%v", err)
	}
	if env.Error != nil {
		return nil, errors.New(env.Error.Message)
	}
	var created struct {
		Handle int32 `json:"handle"`
	}
	if err := json.Unmarshal(env.Result, &created); err != nil {
		return nil, err
	}
	argsJSON, _ := json.Marshal([]any{
		query,
		map[string]any{"cursor": "", "tab": "", "filters": []string{}, "pageSize": limit},
	})
	raw := core.Call(created.Handle, "search", string(argsJSON))
	var out envelope
	if err := json.Unmarshal([]byte(raw), &out); err != nil {
		return nil, fmt.Errorf("核心返回无法解析：%v", err)
	}
	if out.Error != nil {
		return nil, errors.New(out.Error.Message)
	}
	var p page
	if err := json.Unmarshal(out.Result, &p); err != nil {
		return nil, err
	}
	if len(p.Items) > limit {
		p.Items = p.Items[:limit]
	}
	return &p, nil
}

func printPage(query string, p *page, limit int) {
	if len(p.Items) == 0 {
		fmt.Printf("没搜到《%s》的结果\n", query)
		return
	}
	exact := false
	for _, it := range p.Items {
		if norm(it.Title) == norm(query) {
			exact = true
			break
		}
	}
	if exact {
		fmt.Printf("%s · %d 条结果，显示前 %d 条\n", query, len(p.Items), limit)
	} else {
		fmt.Printf("没搜到精确匹配的《%s》，以下是接近的结果（%d 条，显示前 %d 条）\n",
			query, len(p.Items), limit)
	}
	for i, it := range p.Items {
		fmt.Printf("%2d  %s  ID %s  %d集\n", i+1, it.Title, it.ID, it.EpisodeCount)
	}
}

func bestMatch(query string, items []item) *item {
	if len(items) == 0 {
		return nil
	}
	type scored struct {
		it    item
		score int
	}
	list := make([]scored, 0, len(items))
	for _, it := range items {
		list = append(list, scored{it, score(query, it.Title)})
	}
	sort.SliceStable(list, func(i, j int) bool { return list[i].score > list[j].score })
	if list[0].score == 0 {
		// 没有字面相近的，仍按接口返回的第一条（站点推荐位）。
		return &items[0]
	}
	return &list[0].it
}

func score(query, title string) int {
	q, t := norm(query), norm(title)
	switch {
	case q == t:
		return 100
	case strings.HasPrefix(t, q):
		return 80
	case strings.Contains(t, q):
		return 60
	}
	// 关键词被拆成多段（如「持械 入宋」）时按命中字数打分。
	hit := 0
	for _, r := range q {
		if strings.ContainsRune(t, r) {
			hit++
		}
	}
	if hit == 0 {
		return 0
	}
	return 20 + hit*10/len([]rune(q))
}

func norm(s string) string {
	return strings.ToLower(strings.Join(strings.Fields(s), ""))
}

func configDir() string {
	dir, err := os.UserConfigDir()
	if err != nil || dir == "" {
		home, _ := os.UserHomeDir()
		dir = filepath.Join(home, ".config")
	}
	return filepath.Join(dir, "aquan-duanju")
}

func launchApp(explicit, seriesID string) error {
	app := explicit
	if app == "" {
		exe, err := os.Executable()
		if err != nil {
			return err
		}
		dir := filepath.Dir(exe)
		name := "aquan_duanju"
		if filepath.Ext(exe) == ".exe" {
			name += ".exe"
		}
		app = filepath.Join(dir, name)
	}
	if _, err := os.Stat(app); err != nil {
		return fmt.Errorf("找不到阿圈短剧主程序：%s（可用 --app 指定）", app)
	}
	cmd := exec.Command(app, "--series", seriesID)
	cmd.Stdout = nil
	cmd.Stderr = nil
	if err := cmd.Start(); err != nil {
		return err
	}
	return nil
}
