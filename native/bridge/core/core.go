// Package core 是阿圈短剧 app 的 Go 数据核心逻辑，不包含 cgo：cgo 的部分只在
// native/bridge/main.go 里做字符串转换，然后调用这里。
//
// 方法表移植自 openhongguo 的 bindings/internal/dispatch（该包是 internal 的，
// 跨模块不可导入）：方法名与其保持一致，参数是一个 JSON 数组，结果是
// {"result": …} 或 {"error": {code, message, retryable, retryAfterMs}} 形式的
// JSON 信封。
//
// JSON 字段约定：结果沿用 Go SDK 的下划线风格（cover_url、has_more）；
// 查询参数的键大小写不敏感（encoding/json 对无 tag 字段的匹配规则）。
package core

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/beilunyang/openhongguo/adapters"
	"github.com/beilunyang/openhongguo/sdk"
	"github.com/beilunyang/openhongguo/sdk/model"
	"github.com/wjsqqj/aquan-core/appchain"
	"github.com/wjsqqj/aquan-core/webplay"
)

// Version 是核心版本，构建时用 -ldflags "-X github.com/wjsqqj/aquan-core/core.Version=x.y.z" 注入。
var Version = "0.0.0-dev"

// envelope 是响应信封的视图：New 和 Call 的返回值都是它的 JSON。
type envelope struct {
	Result any            `json:"result"`
	Error  map[string]any `json:"error,omitempty"`
}

// 客户端注册表：句柄 → SDK 客户端。句柄从 1 递增，0 表示非法句柄。
// 应用生命周期内通常只有一个句柄；句柄可以并存，互不影响各自的设备档案。
var (
	regMu sync.Mutex
	reg   = map[int32]*sdk.Client{}
	next  int32
)

func register(c *sdk.Client) int32 {
	regMu.Lock()
	defer regMu.Unlock()
	next++
	reg[next] = c
	return next
}

func lookup(h int32) (*sdk.Client, bool) {
	regMu.Lock()
	defer regMu.Unlock()
	c, ok := reg[h]
	return c, ok
}

// New 创建客户端。profilePath 是设备档案 JSON 的路径（目录不存在会创建）；
// configJSON 是 Config 的 JSON，可以为空。
// 返回 {"handle":N}；失败返回 {"error":{…}}，不 panic。
func New(profilePath, configJSON string) string {
	// 统一 FFI recover 护栏：panic 转成既有 error envelope，不跨边界 abort。
	return Guard(func() string { return newClient(profilePath, configJSON) })
}

func newClient(profilePath, configJSON string) string {
	cfg, err := parseConfig(configJSON)
	if err != nil {
		return envelopeJSON(nil, err)
	}
	var opts sdk.Options
	cfg.apply(&opts)
	c, err := adapters.NewClient(profilePath, opts)
	if err != nil {
		return envelopeJSON(nil, err)
	}
	// 内容密钥 sidecar 由设备档案路径推导，方法里只拿得到 client。
	rememberProfilePath(c, profilePath)
	return envelopeJSON(map[string]any{"handle": int(register(c))}, nil)
}

// Call 阻塞执行一次方法调用：handle 上的 method，argsJSON 是参数数组的
// JSON（可以为空）。返回 {"result":…} 或 {"error":{…}}。调用方负责放到后台
// 线程；取消不做：SDK 自带请求超时与重试，单次调用不悬置。
func Call(handle int32, method, argsJSON string) string {
	// 统一 FFI recover 护栏：SDK / 方法实现里的 panic 不跨边界 abort。
	return Guard(func() string { return call(handle, method, argsJSON) })
}

func call(handle int32, method, argsJSON string) string {
	c, ok := lookup(handle)
	if !ok {
		err := fmt.Errorf("%w: unknown handle %d", sdk.ErrInvalidOptions, handle)
		return envelopeJSON(nil, err)
	}
	m, ok := methods[method]
	if !ok {
		err := fmt.Errorf("%w: unknown method %q", sdk.ErrInvalidOptions, method)
		return envelopeJSON(nil, err)
	}
	var a []json.RawMessage
	if argsJSON != "" {
		if err := json.Unmarshal([]byte(argsJSON), &a); err != nil {
			return envelopeJSON(nil, fmt.Errorf("%w: arguments: %v", sdk.ErrInvalidOptions, err))
		}
	}
	v, err := callWithDeviceHeal(context.Background(), c, func(ctx context.Context) (any, error) {
		return m(ctx, c, a)
	})
	return envelopeJSON(v, err)
}

// Guard 用 defer recover() 包住一次 Dart 可调的导出调用：panic 一律转成
// 既有 error envelope（已注册 code），绝不越过 c-shared 边界让进程 abort。
// C 导出层（main.go 的 AquaNew/AquaCall/AquaVersion）与 New/Call 都经由它；
// 方法表与 Dart 侧调用签名完全不变。
func Guard(fn func() string) (out string) {
	defer func() {
		if r := recover(); r != nil {
			out = envelopeJSON(nil, panicError(r))
		}
	}()
	return fn()
}

// panicError 用已注册哨兵 sdk.ErrTransport（code=TRANSPORT）包装 panic：
// UI 只按 code 显示固定文案；message 仅留脱敏摘要，抹掉 URL 查询串与常见
// 凭据字段并截断，避免完整 URL / token 跨 FFI 或落日志。
func panicError(r any) error {
	raw := fmt.Sprintf("%v", r)
	raw = urlQueryRedactor.ReplaceAllString(raw, "$1?…")
	raw = credentialRedactor.ReplaceAllString(raw, "$1…")
	if len(raw) > 256 {
		raw = raw[:256]
	}
	return fmt.Errorf("%w: core panic: %s", sdk.ErrTransport, raw)
}

var (
	urlQueryRedactor   = regexp.MustCompile(`(https?://[^\s?#"]+)\?[^\s"]*`)
	credentialRedactor = regexp.MustCompile(`(?i)(token|authorization|password|passwd|secret|decryption_key)\s*[=:]\s*[^\s,;&]+`)
)

// deviceResetter 是自愈需要的最小客户端能力；*sdk.Client 满足它。
type deviceResetter interface {
	ResetDevice(ctx context.Context) error
}

// deviceLimited 报告一个错误是否可能由「这台匿名设备」引起：被限流、被拒，
// 或取流接口没给模型（PLAYBACK_UNAVAILABLE）。这三类都换一台新注册的设备再试
// 一次——只换一次，注册接口本身有 IP 级配额。
func deviceLimited(err error) bool {
	return errors.Is(err, sdk.ErrAnonymousLimited) ||
		errors.Is(err, sdk.ErrDeviceRejected) ||
		errors.Is(err, sdk.ErrPlaybackUnavailable)
}

// callWithDeviceHeal 执行 run；遇到设备限流/被拒时重置匿名设备并把同一
// 调用再执行一次。只重试一次：重置失败或重试仍失败时返回**原始**错误
// （那才是可诊断的信息）。
func callWithDeviceHeal(ctx context.Context, c deviceResetter, run func(context.Context) (any, error)) (any, error) {
	v, err := run(ctx)
	if !deviceLimited(err) {
		return v, err
	}
	if c == nil || c.ResetDevice(ctx) != nil {
		return v, err
	}
	return run(ctx)
}

// Methods 返回全部方法名，按字母排序。导出函数统一带 recover 护栏。
func Methods() (names []string) {
	defer func() {
		if recover() != nil {
			names = nil
		}
	}()
	names = make([]string, 0, len(methods))
	for n := range methods {
		names = append(names, n)
	}
	sort.Strings(names)
	return names
}

// config 是绑定传来的客户端设置（JSON），字段名与 dispatch.Config 一致。
type config struct {
	APIOrigin          string       `json:"apiOrigin"`
	RegisterOrigin     string       `json:"registerOrigin"`
	DistributionOrigin string       `json:"distributionOrigin"`
	RetryAttempts      int          `json:"retryAttempts"`
	Device             model.Device `json:"device"`
}

func parseConfig(raw string) (config, error) {
	var cfg config
	if raw == "" {
		return cfg, nil
	}
	if err := json.Unmarshal([]byte(raw), &cfg); err != nil {
		return cfg, fmt.Errorf("%w: %v", sdk.ErrInvalidOptions, err)
	}
	return cfg, nil
}

func (cfg config) apply(opts *sdk.Options) {
	opts.APIOrigin = cfg.APIOrigin
	opts.RegisterOrigin = cfg.RegisterOrigin
	opts.DistributionOrigin = cfg.DistributionOrigin
	opts.RetryAttempts = cfg.RetryAttempts
	opts.Device = cfg.Device
	// openhongguo v0.2.0 起默认「设备失效自动换新设备」（最多 2 次）。
	// 本进程已有 callWithDeviceHeal（见 Call）：两层叠加会让一次失败消耗
	// 3~4 台匿名设备，而服务端对每台匿名设备有播放次数限制。
	// 因此显式关闭上游自动换设备，换设备策略只保留 callWithDeviceHeal 一处。
	opts.DeviceResets = sdk.Int(0)
}

// method 是一个可按名字调用的 SDK 方法：args 是参数数组的各项。
type method func(ctx context.Context, c *sdk.Client, args []json.RawMessage) (any, error)

// playbackResult 是 resolvePlayback 的结果：加密剧集同时给出内容密钥，
// 因为 Playback 里的密钥材料不会序列化，绑定的另一端拿不到。密钥推导失败时，
// 仍然返回播放模型，并在 contentKeyError 里说明原因。编码协商降档失败时
// 在 downgradeError 里说明原因（诊断用，Dart 侧不打扰用户）。
type playbackResult struct {
	Playback        *model.Playback   `json:"playback"`
	ContentKey      *model.ContentKey `json:"contentKey,omitempty"`
	ContentKeyError map[string]any    `json:"contentKeyError,omitempty"`
	DowngradeError  string            `json:"downgradeError,omitempty"`
}

var methods = map[string]method{
	"syncHttp": func(ctx context.Context, c *sdk.Client, a []json.RawMessage) (any, error) {
		return syncHttp(ctx, a)
	},
	"discover": func(ctx context.Context, c *sdk.Client, a []json.RawMessage) (any, error) {
		var o sdk.DiscoverOptions
		if err := arg(a, 0, &o); err != nil {
			return nil, err
		}
		return c.Discover(ctx, o)
	},
	"search": func(ctx context.Context, c *sdk.Client, a []json.RawMessage) (any, error) {
		var q string
		var o sdk.SearchOptions
		if err := args2(a, &q, &o); err != nil {
			return nil, err
		}
		return c.Search(ctx, q, o)
	},
	"suggest": oneString(func(ctx context.Context, c *sdk.Client, s string) (any, error) {
		return c.Suggest(ctx, s)
	}),
	"hotSearch": noArgs(func(ctx context.Context, c *sdk.Client) (any, error) {
		return c.HotSearch(ctx)
	}),
	"searchCues": noArgs(func(ctx context.Context, c *sdk.Client) (any, error) {
		return c.SearchCues(ctx)
	}),
	"newReleases": func(ctx context.Context, c *sdk.Client, a []json.RawMessage) (any, error) {
		var q sdk.NewReleaseQuery
		if err := arg(a, 0, &q); err != nil {
			return nil, err
		}
		return c.NewReleases(ctx, q)
	},
	"getSeries": oneString(func(ctx context.Context, c *sdk.Client, id string) (any, error) {
		return c.GetSeries(ctx, id)
	}),
	"getSeriesBatch": arg0[[]string](func(ctx context.Context, c *sdk.Client, ids []string) (any, error) {
		return c.GetSeriesBatch(ctx, ids)
	}),
	"listEpisodes": func(ctx context.Context, c *sdk.Client, a []json.RawMessage) (any, error) {
		var id string
		var o sdk.EpisodeOptions
		if err := args2(a, &id, &o); err != nil {
			return nil, err
		}
		return c.ListEpisodes(ctx, id, o)
	},
	"seasons": oneString(func(ctx context.Context, c *sdk.Client, id string) (any, error) {
		return c.Seasons(ctx, id)
	}),
	"seriesRecommend": oneString(func(ctx context.Context, c *sdk.Client, id string) (any, error) {
		return c.SeriesRecommend(ctx, id)
	}),
	"getAlbum": oneString(func(ctx context.Context, c *sdk.Client, id string) (any, error) {
		return c.GetAlbum(ctx, id, sdk.AlbumOptions{})
	}),
	"shortRank": func(ctx context.Context, c *sdk.Client, a []json.RawMessage) (any, error) {
		var q sdk.ShortRankQuery
		if err := arg(a, 0, &q); err != nil {
			return nil, err
		}
		return c.ShortRank(ctx, q)
	},
	"shortFilterPanel": oneString(func(ctx context.Context, c *sdk.Client, genre string) (any, error) {
		return c.ShortFilterPanel(ctx, genre)
	}),
	"shortFilter": func(ctx context.Context, c *sdk.Client, a []json.RawMessage) (any, error) {
		var q sdk.ShortFilterQuery
		if err := arg(a, 0, &q); err != nil {
			return nil, err
		}
		return shortFilterPageOrEmpty(c.ShortFilter(ctx, q))
	},
	"ranking": func(ctx context.Context, c *sdk.Client, a []json.RawMessage) (any, error) {
		var activity, list string
		if err := args2(a, &activity, &list); err != nil {
			return nil, err
		}
		return c.Ranking(ctx, activity, list)
	},
	"rankRows": func(ctx context.Context, c *sdk.Client, a []json.RawMessage) (any, error) {
		var cell string
		var offset int
		if err := args2(a, &cell, &offset); err != nil {
			return nil, err
		}
		return c.RankRows(ctx, cell, offset)
	},
	"rankGroups": noArgs(func(ctx context.Context, c *sdk.Client) (any, error) {
		return c.RankGroups(ctx)
	}),
	"person": oneString(func(ctx context.Context, c *sdk.Client, id string) (any, error) {
		return c.Person(ctx, id)
	}),
	"personWorks": func(ctx context.Context, c *sdk.Client, a []json.RawMessage) (any, error) {
		var id, cursor string
		if err := args2(a, &id, &cursor); err != nil {
			return nil, err
		}
		return c.PersonWorks(ctx, id, cursor)
	},
	"categories": oneString(func(ctx context.Context, c *sdk.Client, id string) (any, error) {
		return c.Categories(ctx, id)
	}),
	"categoryLanding": func(ctx context.Context, c *sdk.Client, a []json.RawMessage) (any, error) {
		var id string
		var o sdk.LandingOptions
		if err := args2(a, &id, &o); err != nil {
			return nil, err
		}
		return c.CategoryLanding(ctx, id, o)
	},
	// CENC 加密分集的局域网解密中继（castrelay.go）：不依赖 SDK 客户端。
	"castRelayStart": oneString(func(ctx context.Context, c *sdk.Client, optsJSON string) (any, error) {
		opts, err := relayOptionsFromJSON([]byte(optsJSON))
		if err != nil {
			return nil, err
		}
		return castRelayStart(opts)
	}),
	"castRelayStop": oneString(func(ctx context.Context, c *sdk.Client, sessionID string) (any, error) {
		return nil, castRelayStop(sessionID)
	}),
	"castRelayStatus": oneString(func(ctx context.Context, c *sdk.Client, sessionID string) (any, error) {
		return castRelayStatus(sessionID)
	}),
	// 桌面屏幕镜像（castdesktop.go）：gdigrab → HLS，仅 Windows。
	"castDesktopStart": oneString(func(ctx context.Context, c *sdk.Client, optsJSON string) (any, error) {
		opts, err := desktopOptionsFromJSON([]byte(optsJSON))
		if err != nil {
			return nil, err
		}
		return castDesktopStart(opts)
	}),
	"castDesktopStop": oneString(func(ctx context.Context, c *sdk.Client, sessionID string) (any, error) {
		return nil, castDesktopStop(sessionID)
	}),
	"castDesktopStatus": oneString(func(ctx context.Context, c *sdk.Client, sessionID string) (any, error) {
		return castDesktopStatus(sessionID)
	}),
	"resolvePlayback": oneString(func(ctx context.Context, c *sdk.Client, id string) (any, error) {
		pb, err := c.ResolvePlayback(ctx, id, sdk.PlaybackOptions{})
		// 编码协商降级：服务端按客户端版本下发编码，当前档位（73932+）对
		// 部分新剧集只给 bytevc2（字节自研，开源内核无解码器）；按兼容档位
		// （60100）重取会得到 bytevc1/HEVC 可正常播放（2026-11-14 实测）。
		// 降档失败保留原模型——播放器侧有 bytevc2 拦截兜底，行为不劣化；
		// 失败原因写进 downgradeError 供诊断（不下发用户可见错误）。
		downgradeErr := ""
		if allStreamsBytevc2(pb) {
			legacy, lerr := c.ResolvePlaybackWithVersion(ctx, id,
				sdk.LegacyPlaybackVersionCode, sdk.LegacyPlaybackVersionName)
			switch {
			case lerr != nil && !errors.Is(lerr, sdk.ErrDRMProtected):
				// 真失败（网络/风控空响应等）；ErrDRMProtected 是「成功返回
				// 受保护模型」的语义，模型照用（见 default 分支）。
				downgradeErr = lerr.Error()
			case legacy == nil:
				downgradeErr = "兼容档位未返回模型"
			case allStreamsBytevc2(legacy):
				downgradeErr = "兼容档位仍返回 bytevc2"
			default:
				pb, err = legacy, lerr
			}
		}
		if errors.Is(err, sdk.ErrDRMProtected) && pb != nil {
			key, kerr := sdk.ContentKey(pb)
			if kerr != nil {
				return playbackResult{Playback: pb, ContentKeyError: errorJSON(kerr), DowngradeError: downgradeErr}, nil
			}
			return playbackResult{Playback: pb, ContentKey: &key, DowngradeError: downgradeErr}, nil
		}
		if err != nil {
			return nil, err
		}
		return playbackResult{Playback: pb, DowngradeError: downgradeErr}, nil
	}),
	// resolvePlaybackWeb 解析链（2026-11-17 翻转为 v5 主通道）：
	// ① v5 sidecar 主通道——mssdk 设备令牌 + v5 签名，匿名全目录（含第 6 集
	//    起）且一次返回 5 轨（360p-1080p；web 通道封顶 720p），会话持久化后
	//    热路径 ~1-2s；
	// ② 官网 protected/play-info（第 1-5 集快路径 + fallback 明文回退）；
	// ③ 旧 App 匿名链路（多集群轮换，生态故障期空响应、熔断自动暂停）。
	// 任一成功即返回；失败链静默丢弃、返回最后一个错误（WEB_LOGIN_REQUIRED
	// 等文案契约不变）。args = [seriesID, episodeID, definition]。
	"resolvePlaybackWeb": func(ctx context.Context, c *sdk.Client, a []json.RawMessage) (any, error) {
		var seriesID, episodeID, definition string
		if err := args3(a, &seriesID, &episodeID, &definition); err != nil {
			return nil, err
		}
		if vpb, vkey, verr := resolveViaV5(ctx, profilePathOf(c), episodeID); verr == nil {
			result := playbackResult{Playback: vpb}
			if vkey.Hex != "" {
				result.ContentKey = &vkey
			}
			return result, nil
		}
		pb, key, err := webplay.Resolve(ctx, nil, seriesID, episodeID, definition)
		// 偶发空 body（限流/抖动）短暂重试一次；403 游客墙立即返回，不重试。
		if errors.Is(err, webplay.ErrEmptyPlayback) {
			select {
			case <-ctx.Done():
			case <-time.After(400 * time.Millisecond):
			}
			pb, key, err = webplay.Resolve(ctx, nil, seriesID, episodeID, definition)
		}
		if err != nil && pb == nil {
			// 旧 App 匿名链路第三兜底：失败同样丢弃、返回 web 通道原错误。
			if apb, akey, aerr := appchain.Resolve(ctx, nil, profilePathOf(c), episodeID); aerr == nil {
				result := playbackResult{Playback: apb}
				if akey.Hex != "" {
					result.ContentKey = &akey
				}
				return result, nil
			}
			return nil, err
		}
		if pb == nil {
			return nil, fmt.Errorf("webplay: no playback model")
		}
		result := playbackResult{Playback: pb}
		if err != nil {
			result.ContentKeyError = errorJSON(err)
		} else if key.Hex != "" {
			result.ContentKey = &key
		}
		return result, nil
	},
	// 弹幕：args = [seriesID, episodeID, {startMs, cursor, pageSize}]。
	// cursor 与 startMs 只能给一个；翻页游标由 SDK 封装（含分集与时长），
	// 页空不等于到底，调用方要翻到 has_more 为假。
	"listDanmaku": func(ctx context.Context, c *sdk.Client, a []json.RawMessage) (any, error) {
		var seriesID, episodeID string
		var o sdk.DanmakuOptions
		if err := args3(a, &seriesID, &episodeID, &o); err != nil {
			return nil, err
		}
		return c.ListDanmaku(ctx, seriesID, episodeID, o)
	},
	"resetDevice": noArgs(func(ctx context.Context, c *sdk.Client) (any, error) {
		return nil, c.ResetDevice(ctx)
	}),
	// 阅读内容密钥：没有则注册并落盘 sidecar；正文按章解密。
	"secretKey": func(ctx context.Context, c *sdk.Client, _ []json.RawMessage) (any, error) {
		return contentSecretKey(ctx, c)
	},
	"chapterText": chapterText,
	// 听书：音色表与音轨播放地址（智能朗读）。
	// 临时：音频时间点原始响应，随后删除。
	"tmpTimepoints": func(ctx context.Context, c *sdk.Client, a []json.RawMessage) (any, error) {
		var bookID, itemID, toneID, reqType string
		if err := arg(a, 0, &bookID); err != nil {
			return nil, err
		}
		if err := arg(a, 1, &itemID); err != nil {
			return nil, err
		}
		if err := arg(a, 2, &toneID); err != nil {
			return nil, err
		}
		if err := arg(a, 3, &reqType); err != nil {
			return nil, err
		}
		raw, err := c.AudioTimepointsRaw(ctx, bookID, itemID, toneID, reqType)
		if err != nil {
			return nil, err
		}
		return string(raw), nil
	}, "audioTones": audioTones,
	"audioTimepoints": audioTimepoints,
	// 临时：playinfo 原始条目，随后删除。
	"tmpPlayRaw": func(ctx context.Context, c *sdk.Client, a []json.RawMessage) (any, error) {
		var bookID, itemID, toneID string
		if err := arg(a, 0, &bookID); err != nil {
			return nil, err
		}
		if err := arg(a, 1, &itemID); err != nil {
			return nil, err
		}
		if err := arg(a, 2, &toneID); err != nil {
			return nil, err
		}
		raw, err := c.AudioPlayInfoRaw(ctx, bookID, itemID, toneID)
		if err != nil {
			return nil, err
		}
		return string(raw), nil
	}, "audioPlay": audioPlay,
	"audioStream": audioStream,
	// 社区：帖子详情（正文块 + 互动数据）。
	"postDetail": postDetail,
	// 阅读：书籍详情与整本目录。
	"bookDetail":    bookDetail,
	"bookDirectory": bookDirectory,
	// 漫画：一话的图片清单 + 单页解密。
	"chapterPages":   chapterPages,
	"fetchMangaPage": fetchMangaPage,

	"fetchImage": fetchImage,
}

// shortFilterPageOrEmpty 把筛选「首页 0 条」收敛成空页。
//
// SDK 对 ShortFilter 第一页空结果返回裸哨兵 ErrContentUnavailable，但筛选组合
// 本身就可能没有匹配内容（实测「真人剧 + 魔幻」）。对筛选页这是合法空态：应让
// UI 显示「没有符合筛选的短剧」，而不是错误页 + 自动重试（还会白耗匿名配额）。
//
// 只收敛裸哨兵：带业务码的 CodeError（101001/101115 等下架或无权限）仍按错误
// 返回，保留日志与诊断；面板为空不走这里——ShortFilterPanel 仍报错，那是接口异常。
func shortFilterPageOrEmpty(page *model.ShortFilterPage, err error) (*model.ShortFilterPage, error) {
	if errors.Is(err, sdk.ErrContentUnavailable) {
		var codeErr *sdk.CodeError
		if !errors.As(err, &codeErr) {
			return &model.ShortFilterPage{Items: []model.SeriesSummary{}}, nil
		}
	}
	return page, err
}

// arg 把第 i 个参数解码到 v；参数缺省或为 null 时保留 v 的零值。
func arg(a []json.RawMessage, i int, v any) error {
	if i >= len(a) || string(a[i]) == "null" {
		return nil
	}
	if err := json.Unmarshal(a[i], v); err != nil {
		return fmt.Errorf("%w: argument %d: %v", sdk.ErrInvalidOptions, i+1, err)
	}
	return nil
}

func args2(a []json.RawMessage, v0, v1 any) error {
	if err := arg(a, 0, v0); err != nil {
		return err
	}
	return arg(a, 1, v1)
}

func args3(a []json.RawMessage, v0, v1, v2 any) error {
	if err := arg(a, 0, v0); err != nil {
		return err
	}
	if err := arg(a, 1, v1); err != nil {
		return err
	}
	return arg(a, 2, v2)
}

func oneString(f func(context.Context, *sdk.Client, string) (any, error)) method {
	return func(ctx context.Context, c *sdk.Client, a []json.RawMessage) (any, error) {
		var s string
		if err := arg(a, 0, &s); err != nil {
			return nil, err
		}
		return f(ctx, c, s)
	}
}

func noArgs(f func(context.Context, *sdk.Client) (any, error)) method {
	return func(ctx context.Context, c *sdk.Client, _ []json.RawMessage) (any, error) {
		return f(ctx, c)
	}
}

func arg0[T any](f func(context.Context, *sdk.Client, T) (any, error)) method {
	return func(ctx context.Context, c *sdk.Client, a []json.RawMessage) (any, error) {
		var v T
		if err := arg(a, 0, &v); err != nil {
			return nil, err
		}
		return f(ctx, c, v)
	}
}

// errorCode 是一个错误码，以及它对应的哨兵错误。移植自 dispatch.ErrorCodes。
var errorCodes = []struct {
	Err  error
	Code string
}{
	// 取消排在最前：取消导致的失败可能同时包装了其他哨兵错误。
	{context.Canceled, "CANCELLED"},
	{sdk.ErrInvalidOptions, "INVALID_OPTIONS"},
	{sdk.ErrProfileNotFound, "PROFILE_NOT_FOUND"},
	{sdk.ErrSignerUnavailable, "SIGNER_UNAVAILABLE"},
	{sdk.ErrAuthenticationRequired, "AUTHENTICATION_REQUIRED"},
	{sdk.ErrNotProtected, "NOT_PROTECTED"},
	{sdk.ErrDRMProtected, "DRM_PROTECTED"},
	{sdk.ErrAnonymousLimited, "ANONYMOUS_LIMITED"},
	// 取流接口（POST + video_tab 兜底）都没给模型。与 ANONYMOUS_LIMITED 分开：
	// 前者是「这条链路没数据」，后者才用于列表空结果/设备受限。
	{sdk.ErrPlaybackUnavailable, "PLAYBACK_UNAVAILABLE"},
	{sdk.ErrRateLimited, "RATE_LIMITED"},
	{sdk.ErrTransport, "TRANSPORT"},
	{sdk.ErrSignatureRejected, "SIGNATURE_REJECTED"},
	{sdk.ErrContentUnavailable, "CONTENT_UNAVAILABLE"},
	{sdk.ErrParamInvalid, "PARAM_INVALID"},
	{sdk.ErrChallengeRequired, "CHALLENGE_REQUIRED"},
	{sdk.ErrDeviceRejected, "DEVICE_REJECTED"},
	{sdk.ErrEndOfList, "END_OF_LIST"},
	{sdk.ErrAlbumUnavailable, "ALBUM_UNAVAILABLE"},
	{ErrRelayUnavailable, "CAST_RELAY_UNAVAILABLE"},
	{ErrRelayInvalid, "CAST_RELAY_INVALID"},
	{ErrRelayNoSession, "CAST_RELAY_NO_SESSION"},
	{ErrRelayInternal, "CAST_RELAY_INTERNAL"},
	{ErrDesktopUnsupported, "CAST_DESKTOP_UNSUPPORTED"},
	// 官网 play-info 游客墙：未登录仅前 5 集可看，后段返回 403。
	{webplay.ErrLoginRequired, "WEB_LOGIN_REQUIRED"},
}

// allStreamsBytevc2 报告播放模型的所有流是否都是 bytevc2（字节自研编码，
// 开源内核无解码器，fourcc 为私有 bvc2/bv2C）。该编码按客户端版本档位
// 下发，降档重取可得 bytevc1/HEVC——见 resolvePlayback 的编码协商降级。
// nil 模型或无流时返回 false（不触发降档）。
func allStreamsBytevc2(pb *model.Playback) bool {
	if pb == nil || len(pb.Streams) == 0 {
		return false
	}
	for _, s := range pb.Streams {
		codec := strings.ToLower(strings.TrimSpace(s.Codec))
		if codec != "bytevc2" && codec != "bvc2" {
			return false
		}
	}
	return true
}

// errorJSON 把 err 转成 {code, message, retryable, retryAfterMs}。
// 不对应任何哨兵错误时，code 是 "UNKNOWN"。
func errorJSON(err error) map[string]any {
	code := "UNKNOWN"
	for _, e := range errorCodes {
		if errors.Is(err, e.Err) {
			code = e.Code
			break
		}
	}
	return map[string]any{
		"code":         code,
		"message":      err.Error(),
		"retryable":    sdk.Retryable(err),
		"retryAfterMs": sdk.RetryAfter(err, 0).Milliseconds(),
	}
}

// envelopeJSON 编码一次调用的结果；err 非 nil 时编成错误信封，result 不出现。
func envelopeJSON(v any, err error) string {
	if err != nil {
		b, mErr := json.Marshal(map[string]any{"error": errorJSON(err)})
		if mErr != nil {
			b = []byte(`{"error":{"code":"UNKNOWN","message":"marshal error","retryable":false}}`)
		}
		return string(b)
	}
	b, mErr := json.Marshal(map[string]any{"result": v})
	if mErr != nil {
		// dispatch 的返回值都来自 SDK 的静态模型，这里只为兜底。
		return envelopeJSON(nil, fmt.Errorf("marshal result: %w", mErr))
	}
	return string(b)
}
