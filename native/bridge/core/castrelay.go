// castrelay 实现加密分集的局域网解密中继（方案文档 §5.4 / §7.2）：
//
//	电视(Renderer) ──GET /cast/<token>/index.m3u8──▶ Go 中继 ──ffmpeg -decryption_key──▶ 上游
//
// 设计要点（guoappxxx transcode.go 验证过的链路）：
//   - ffmpeg 子进程把「加密上游」转成明文 HLS（H.264/AAC，顺带解决 HEVC 兼容）；
//   - 中继只响应 /cast/<token>/ 前缀，token 每会话 32 位随机 hex（防局域网拖走）；
//   - 3 秒快检：进程提前退出（缺二进制/密钥错/输入不可读）立即报错，不让电视转圈；
//   - 会话回收三条路径：空闲 5 分钟 / castRelayStop / 进程退出；
//   - ffmpeg 环境强制清空代理变量（上游是签名直链，走系统代理会坏）。
package core

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// relayOptions 是 castRelayStart 的入参（Dart 侧拍平后的播放要素）。
type relayOptions struct {
	URL         string `json:"url"`
	BackupURL   string `json:"backup_url"`
	DecKey      string `json:"dec_key"` // hex 内容密钥；空 = 未加密（不必要走中继，但允许）
	UserAgent   string `json:"user_agent"`
	Referer     string `json:"referer"`
	AudioURL    string `json:"audio_url"`    // DASH 双轨上游（可选）
	Format      string `json:"format"`       // 输出档位（R2）：""/"hls"（默认）| "ts"；未知值一律按 hls
	Quality     string `json:"quality"`      // 画质档位（R2）：high|balanced|compact；空/未知 = balanced（现状）
	SubtitleURL string `json:"subtitle_url"` // 会话字幕地址（R3）：非空时媒体响应带 CaptionInfo.sec
	WorkDir     string `json:"work_dir"`     // 会话临时目录基址（11-08 真机修复）：Android 进程无 TMPDIR，os.MkdirTemp("",…) 落 /tmp 必败；空 = 现状（桌面）
	CAFile      string `json:"ca_file"`      // SSL_CERT_FILE（11-08 真机修复）：Android 无默认 CA 路径，https 上游需要显式证书包；空 = 不追加
	HostHint    string `json:"host_hint"`    // 目标设备 host（11-09 取流修复）：据此探路由源 IP 生成产物 URL；空 = 回落 lanIP()
	CodecHint   string `json:"codec_hint"`   // 源编码提示（11-09 ts 档修复）：hevc/av1 时 ts 档不能 -c copy（多数电视不支持 HEVC over TS）
	LanIP       string `json:"lan_ip"`       // 发送端已解析的本机地址（11-10）：优先于 Go 侧探测；空 = 回落原策略
}

// relaySessionInfo 是 castRelayStart/Status 的出参。
type relaySessionInfo struct {
	Session   string             `json:"session"`
	Token     string             `json:"token"`
	Port      int                `json:"port"`
	URL       string             `json:"url"`
	Format    string             `json:"format"`
	LanIP     string             `json:"lanIp"` // 本机 LAN IP（R3：会话内缓存，诊断面板防火墙指引用）
	Encrypted bool               `json:"encrypted"`
	UptimeMs  int64              `json:"uptimeMs"`
	Segments  int                `json:"segments"`
	Ready     bool               `json:"ready"`
	Recent    []relayAccessEntry `json:"recent,omitempty"` // 电视取流环形日志（M0-5）

	// 产物完成度（11-09 连播修复）：电视上报的 TrackDuration 对 live/event
	// HLS 不可靠（常态 0），连播判定与诊断改用产物自身的真实进度。
	Ended        bool  `json:"ended"`        // ffmpeg 已退出
	ExitCode     int   `json:"exitCode"`     // 0=正常收尾；非 0=异常中断；-1=未知/被 kill
	Endlisted    bool  `json:"endlisted"`    // index.m3u8 含 #EXT-X-ENDLIST
	DurationMs   int64 `json:"durationMs"`   // #EXTINF 累计（hls）；ts 档恒 0
	LastAccessMs int64 `json:"lastAccessMs"` // 距最后一次电视取流的毫秒数
	Stalled      bool  `json:"stalled"`      // 转码未结束却已 12s 无取流（播放器退出/欠载）
	LastSegIndex int   `json:"lastSegIndex"` // 电视已取到的最大分片序号；-1 = 未取过

	// 产物与取流进度（11-10）：区分「转码停滞」与「电视不拉」，ts 档没有分片
	// 序号可用，改看已送出的字节数。
	ServedBytes   int64 `json:"servedBytes"`   // 本会话写给电视的媒体字节数
	LastProduceMs int64 `json:"lastProduceMs"` // 距最新产物落盘的毫秒数；-1 = 尚无产物
}

// relayAccessEntry 是一条电视取流记录（M0-5）：时间/路径/Range/UA/状态码/字节数。
type relayAccessEntry struct {
	Seq    int64  `json:"seq"` // 单调递增：Dart 侧按它去重新增记录
	At     string `json:"at"`  // 本地时间 HH:MM:SS
	Path   string `json:"path"`
	Range  string `json:"range,omitempty"`
	UA     string `json:"ua,omitempty"`
	Status int    `json:"status"`
	Bytes  int64  `json:"bytes"`
}

type relaySession struct {
	id        string
	token     string
	port      int
	dir       string
	cmd       *exec.Cmd
	srv       *http.Server
	startedAt time.Time
	ready     bool
	encrypted bool
	format    string // 输出档位："hls"（默认）| "ts"（R2）

	// accessMu 保护 lastAccess：touch()（HTTP 每次请求）写，info()/sweeper 读。
	// 与 relayMu 的嵌套顺序固定为 relayMu → accessMu（touch 只拿后者）。
	accessMu   sync.Mutex
	lastAccess time.Time

	// ffmpeg 退出状态（11-09）：waitCh 关闭前用 [markFfmpegExit] 写入，
	// info() 据此判断「产物已转完」与「异常中断」。
	ffmpegEnded atomic.Bool
	exitCode    atomic.Int32

	// lastSegIdx 记录电视已取到的最大分片序号 +1（0 = 未取过；避免零值歧义）。
	lastSegIdx atomic.Int32

	// servedBytes 本会话写给电视的媒体字节数（11-10）：ts 档没有分片序号，
	// 诊断/连播判定用字节数确认「电视确实在拉」。
	servedBytes atomic.Int64

	subtitleURL string // 会话字幕（R3）：serveCastFile 据此带 CaptionInfo.sec
	lanIP       string // 本机 LAN IP（R3）：会话内缓存一次，info() 不重复枚举网卡

	// 电视取流环形日志（M0-5）：最近 relayAccessLogSize 条。
	// 独立小锁：info() 会在持 relayMu 的调用点（castRelayStatus）里读取，
	// sync.Mutex 不可重入，共用 relayMu 会死锁。
	logMu     sync.Mutex
	accessLog []relayAccessEntry
	logSeq    int64

	// waitCh 在 ffmpeg 退出时关闭；waitErr 记录退出原因。
	// 不依赖 cmd.ProcessState：未调用 Wait() 时它恒为 nil，快检会失效。
	waitCh  chan struct{}
	waitErr error

	// stderrLog 是 ffmpeg 的 stderr 落盘句柄（11-08 真机修复）：提前退出时
	// 读尾部拼进错误详情（去 URL）；文件随会话目录回收。nil = 创建失败（现状丢弃）。
	stderrLog *os.File
}

var (
	relayMu       sync.Mutex
	relaySessions = map[string]*relaySession{}
	relaySweeper  *time.Ticker
)

const (
	relayBasePort      = 29170
	relayIdleTimeout   = 5 * time.Minute
	relayFastWait      = 3 * time.Second
	relayAccessLogSize = 32 // 电视取流环形日志容量

	// relayStallWindow 判定「转码还在跑但电视不拉了」的静默窗口：
	// 正常跟播每 3s 至少一次取流，12s 无请求即播放器已退出/缓冲欠载。
	// 只做观测，不触发回收（回收仍按 relayIdleTimeout）。
	relayStallWindow = 12 * time.Second

	// ts 增长流的收尾参数：无新字节 30s 结束响应；文件尾轮询 200ms。
	relayTSIdle = 30 * time.Second
	relayTSPoll = 200 * time.Millisecond
)

// 中继层哨兵错误：注册进 errorCodes 表（core.go），Dart 按 code 分级文案。
var (
	ErrRelayUnavailable = errors.New("relay unavailable")
	ErrRelayInvalid     = errors.New("relay invalid options")
	ErrRelayNoSession   = errors.New("relay no session")
	ErrRelayInternal    = errors.New("relay internal")
)

// relayFail 返回携带哨兵的可读错误：fmt.Errorf("%w: detail", sentinel)。
func relayFail(sentinel error, detail string) error {
	if detail == "" {
		return sentinel
	}
	return fmt.Errorf("%w: %s", sentinel, detail)
}

// castRelayStart 启动（或复用）一个解密中继会话。
// 入参：[optionsJSON]；出参：relaySessionInfo。
func castRelayStart(opts relayOptions) (*relaySessionInfo, error) {
	if opts.URL == "" {
		return nil, relayFail(ErrRelayInvalid, "缺少播放地址")
	}
	startSweeper()
	sweepOrphanDirs()

	// ffmpeg 可用性最先探（缺二进制是最常见的失败，秒回）。
	ffmpeg, err := findFFmpeg()
	if err != nil {
		return nil, relayFail(ErrRelayUnavailable,
			"未找到 ffmpeg，无法中继加密内容；请将 ffmpeg 放到应用目录或 PATH")
	}

	token, err := randomToken()
	if err != nil {
		return nil, relayFail(ErrRelayInternal, "token 生成失败")
	}
	dir, err := mkRelayTempDir(opts)
	if err != nil {
		return nil, relayFail(ErrRelayInternal, "临时目录创建失败: "+err.Error())
	}

	port, ln, err := listenOnFreePort(relayBasePort)
	if err != nil {
		os.RemoveAll(dir)
		return nil, relayFail(ErrRelayInternal, "端口监听失败")
	}
	srv := &http.Server{Handler: http.NotFoundHandler()}

	// 输出档位（R2）：空/未知值一律按 hls —— 旧调用方零改动（证据缺失回落现状）。
	if opts.Format != "ts" {
		opts.Format = "hls"
	}

	// 产物地址（11-10）：必须在起服务前算好。算不出「电视可达的地址」时宁可
	// 失败也不发布回环 URL——回环地址只有会改写来源 IP 的接收端（airpin）能播，
	// 其余设备一律「受理成功但永不取流」，用户只会看到卡住。
	lan, lanOK := resolveProductHost(opts)
	if !lanOK {
		srv.Close()
		os.RemoveAll(dir)
		return nil, relayFail(ErrRelayUnavailable,
			"无法确定电视可达的本机地址（未连 Wi-Fi / 只有回环网卡）")
	}

	sessionID := token[:16]
	session := &relaySession{
		id:          sessionID,
		token:       token,
		port:        port,
		dir:         dir,
		srv:         srv,
		startedAt:   time.Now(),
		lastAccess:  time.Now(),
		encrypted:   opts.DecKey != "",
		format:      opts.Format,
		subtitleURL: opts.SubtitleURL,
		// 会话内缓存一次：info() 高频拉取不再重复探路。地址由
		// [resolveProductHost] 在起服务前算好（Dart 传入 > 路由探测 > 同网段）。
		lanIP: lan,
	}

	args := buildFFmpegArgs(ffmpeg, opts, dir, opts.DecKey)
	cmd := exec.Command(args[0], args[1:]...)
	// 上游是签名直链：清空代理环境（guoappxxx 同款坑）。
	cmd.Env = cleanProxyEnv()
	// CA 定位（11-08 真机修复）：Android 没有默认证书路径，https 上游握手
	// 会因证书校验失败早退；Dart 把内置 CA 包落盘后经 ca_file 传入。
	// OpenSSL 构建读 SSL_CERT_FILE；schannel/gnutls 构建忽略之（桌面无影响）。
	if opts.CAFile != "" {
		cmd.Env = append(cmd.Env, "SSL_CERT_FILE="+opts.CAFile)
	}
	// ffmpeg stderr 落会话目录（castdesktop 同款做法）：体积大且含上游 URL，
	// 不全量外发；ffmpeg 提前退出时读「去 URL 的尾部」拼进错误详情可诊断。
	if stderrLog, err := os.Create(filepath.Join(dir, "ffmpeg-stderr.log")); err == nil {
		cmd.Stderr = stderrLog
		session.stderrLog = stderrLog
	}
	session.cmd = cmd
	if err := cmd.Start(); err != nil {
		srv.Close()
		os.RemoveAll(dir)
		return nil, relayFail(ErrRelayUnavailable, "ffmpeg 启动失败: "+err.Error())
	}
	// ffmpeg 挂进进程级 Job（KILL_ON_JOB_CLOSE）：app 被强杀/崩溃时子进程
	// 随父退出，不再残留孤儿转码消耗 CPU 与带宽（sweeper 只清目录不清进程）。
	assignFfmpegToJob(cmd.Process)
	session.waitCh = make(chan struct{})
	go func() {
		session.markFfmpegExit(cmd.Wait())
		if session.stderrLog != nil {
			_ = session.stderrLog.Close()
		}
		close(session.waitCh)
	}()

	mux := http.NewServeMux()
	mux.HandleFunc("/cast/"+token+"/", session.serveCastFile)
	session.srv.Handler = mux
	go func() {
		_ = srv.Serve(ln) // 端口已预先绑定，不存在二次绑定竞态
	}()

	// 产物就绪判定按档位分流（R2）：hls = 清单+分片；ts = stream.ts > 64KB
	// （对齐 hls ready 的保守口径，起步阶段的空洞文件不算就绪）。
	productReady := func() bool {
		if opts.Format == "ts" {
			return tsReady(dir)
		}
		return indexReady(dir) && hasSegments(dir)
	}

	// 3 秒快检：进程提前退出时，若已产出清单与分片则视为「转码完成」
	// （短视频/小文件秒级完成，静态服务即可），否则才是早期失败。
	deadline := time.NewTimer(relayFastWait)
	defer deadline.Stop()
	for {
		select {
		case <-session.waitCh:
			if productReady() {
				session.ready = true
				relayMu.Lock()
				relaySessions[sessionID] = session
				relayMu.Unlock()
				return session.info(), nil
			}
			// 详情先读（relayStop 会 RemoveAll 会话目录）：stderr 尾部是
			// 「证书校验失败 / 403 / 密钥错」等真因的唯一线索（11-08）。
			detail := relayStderrTail(dir)
			relayStop(sessionID)
			return nil, relayFail(ErrRelayUnavailable,
				"中继启动失败（ffmpeg 提前退出，检查密钥与播放地址）"+detail)
		case <-deadline.C:
			// 超时但进程仍存活：转码慢属正常，放行交给电视端边转边播。
			if opts.Format == "ts" {
				session.ready = tsReady(dir)
			} else {
				session.ready = indexReady(dir)
			}
			relayMu.Lock()
			relaySessions[sessionID] = session
			relayMu.Unlock()
			return session.info(), nil
		default:
			if productReady() {
				session.ready = true
				relayMu.Lock()
				relaySessions[sessionID] = session
				relayMu.Unlock()
				return session.info(), nil
			}
			time.Sleep(200 * time.Millisecond)
		}
	}
}

// castRelayStop 停止会话并回收资源。
func castRelayStop(sessionID string) error {
	relayStop(sessionID)
	return nil
}

// castRelayStatus 查询会话状态（诊断面板用）。
func castRelayStatus(sessionID string) (*relaySessionInfo, error) {
	relayMu.Lock()
	s := relaySessions[sessionID]
	relayMu.Unlock()
	if s == nil {
		return nil, relayFail(ErrRelayNoSession, "会话不存在或已回收")
	}
	return s.info(), nil
}

// ---------- 内部 ----------

func (s *relaySession) touch() {
	s.accessMu.Lock()
	s.lastAccess = time.Now()
	s.accessMu.Unlock()
}

// lastAccessAt 读最后一次取流时间（accessMu 保护；零值 = 从未访问）。
func (s *relaySession) lastAccessAt() time.Time {
	s.accessMu.Lock()
	defer s.accessMu.Unlock()
	return s.lastAccess
}

// markFfmpegExit 在 waitCh 关闭前记录 ffmpeg 退出：ended 供连播判定与诊断
// 区分「产物已转完」与「仍在转」，exitCode 区分正常收尾与异常中断
// （源 403/密钥错/被 kill）。须在 cmd.Wait() 返回后调用（ProcessState 才有值）。
func (s *relaySession) markFfmpegExit(err error) {
	s.waitErr = err
	code := -1
	if s.cmd != nil && s.cmd.ProcessState != nil {
		code = s.cmd.ProcessState.ExitCode()
	}
	s.exitCode.Store(int32(code))
	s.ffmpegEnded.Store(true)
}

func (s *relaySession) info() *relaySessionInfo {
	// 分片数只对 hls 档有意义；ts 档产物是单文件 stream.ts（不能把它当
	// 分片计数，诊断「电视拉到几个分片」会失真）。
	segments := 0
	durationMs := int64(0)
	endlisted := false
	if s.format != "ts" {
		if entries, err := os.ReadDir(s.dir); err == nil {
			for _, e := range entries {
				if strings.HasSuffix(e.Name(), ".ts") {
					segments++
				}
			}
		}
		durationMs, endlisted = playlistDurationMs(s.dir)
	}
	// LAN IP 会话内缓存一次（castRelayStart 时取好）；测试直建的结构体
	// 无缓存值时回落 lanIP()。
	lan := s.lanIP
	if lan == "" {
		lan = lanIP()
	}
	// 产物 URL 按档位分流（R2）：hls 指向清单；ts 指向 stream.ts——
	// Dart 侧按 URL 扩展名自动判 video/mp2t。
	url := fmt.Sprintf("http://%s:%d/cast/%s/index.m3u8", lan, s.port, s.token)
	if s.format == "ts" {
		url = fmt.Sprintf("http://%s:%d/cast/%s/stream.ts", lan, s.port, s.token)
	}
	format := s.format
	if format != "ts" {
		format = "hls"
	}
	ended := s.ffmpegEnded.Load()
	// 未退出时 exitCode 恒报 -1：原子零值 0 会被误读成「正常收尾」。
	exitCode := -1
	if ended {
		exitCode = int(s.exitCode.Load())
	}
	lastAccessMs := time.Since(s.lastAccessAt()).Milliseconds()
	if lastAccessMs < 0 {
		lastAccessMs = 0
	}
	stalled := !ended && s.ready && segments > 0 &&
		lastAccessMs > relayStallWindow.Milliseconds()
	// lastSegIdx 存的是「序号+1」，0 表示电视尚未取过任何分片。
	lastSeg := int(s.lastSegIdx.Load()) - 1
	return &relaySessionInfo{
		Session:       s.id,
		Token:         s.token,
		Port:          s.port,
		URL:           url,
		Format:        format,
		LanIP:         lan,
		Encrypted:     s.encrypted,
		UptimeMs:      time.Since(s.startedAt).Milliseconds(),
		Segments:      segments,
		Ready:         s.ready,
		Recent:        s.recentAccess(),
		Ended:         ended,
		ExitCode:      exitCode,
		Endlisted:     endlisted,
		DurationMs:    durationMs,
		LastAccessMs:  lastAccessMs,
		Stalled:       stalled,
		LastSegIndex:  lastSeg,
		ServedBytes:   s.servedBytes.Load(),
		LastProduceMs: newestProductAgeMs(s.dir),
	}
}

// newestProductAgeMs 距最新产物（seg_*.ts / stream.ts）落盘的毫秒数。
// -1 = 还没有任何产物。诊断据此区分「转码停滞」（产物不再增长）与
// 「电视不拉」（产物在长但没人取）。
func newestProductAgeMs(dir string) int64 {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return -1
	}
	age := int64(-1)
	for _, e := range entries {
		if !strings.HasSuffix(e.Name(), ".ts") {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		ms := time.Since(info.ModTime()).Milliseconds()
		if ms < 0 {
			ms = 0
		}
		if age < 0 || ms < age {
			age = ms
		}
	}
	return age
}

// playlistDurationMs 解析 HLS 清单的 #EXTINF 累计时长与 ENDLIST 标记。
//
// 连播判定不能用设备上报的 TrackDuration：中继产物是 ffmpeg 边转边写的
// event 清单，电视多数把总时长报成 0/NOT_IMPLEMENTED（真机日志实证），
// 于是「播完」永远判不出来。这里按清单自身累计，得到产物真实时长。
// 解析失败/无清单返回 (0,false)——调用方按「无证据」处理，不误判播完。
func playlistDurationMs(dir string) (int64, bool) {
	data, err := os.ReadFile(filepath.Join(dir, "index.m3u8"))
	if err != nil {
		return 0, false
	}
	text := string(data)
	var total float64
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, "#EXTINF:") {
			continue
		}
		v := strings.TrimPrefix(line, "#EXTINF:")
		if i := strings.IndexByte(v, ','); i >= 0 {
			v = v[:i]
		}
		// 单段 >600s 视为坏行（清单被截断/手工改写），不参与累计。
		if f, err := strconv.ParseFloat(strings.TrimSpace(v), 64); err == nil && f > 0 && f < 600 {
			total += f
		}
	}
	return int64(total * 1000), strings.Contains(text, "#EXT-X-ENDLIST")
}

func relayStop(sessionID string) {
	relayMu.Lock()
	s := relaySessions[sessionID]
	delete(relaySessions, sessionID)
	relayMu.Unlock()
	if s == nil {
		return
	}
	if s.cmd != nil && s.cmd.Process != nil {
		_ = s.cmd.Process.Kill()
	}
	if s.srv != nil {
		_ = s.srv.Close()
	}
	_ = os.RemoveAll(s.dir)
}

// sweepOrphanDirs 清理上次进程遗留的中继临时目录：app 强杀/退出时
// relaySessions 随内存消失，临时目录成孤儿（实测 Temp 残留 30+）。
//
// 11-10 真机修复（关键）：旧实现「活跃会话为空」只在**进程启动**时成立，
// 但本函数在每次 castRelayStart 开头都会跑——换集/重投/用户再次投屏时，
// 上一个会话的目录会被当成孤儿删掉。后果：正在播的电视拿到 404，播完已
// 缓冲的十几秒就卡住；诊断里还会出现「已产出分片：0」却「电视已取到 #14」
// 的自相矛盾数据。现在按 relaySessions 里登记的真实目录跳过活跃会话。
//
// 基址（11-08）：Android 会话目录在 Dart 传入的 workDir（应用缓存目录），
// 桌面仍走 os.TempDir()——两处都扫，覆盖旧版本残留与测试混跑。
func sweepOrphanDirs() {
	relayMu.Lock()
	live := make(map[string]bool, len(relaySessions))
	for _, s := range relaySessions {
		if s != nil && s.dir != "" {
			live[filepath.Clean(s.dir)] = true
		}
	}
	relayMu.Unlock()

	relayWorkDirMu.Lock()
	base := relayWorkDirCurrent
	relayWorkDirMu.Unlock()
	bases := []string{os.TempDir()}
	if base != "" && base != os.TempDir() {
		bases = append(bases, base)
	}
	for _, dir := range bases {
		matches, err := filepath.Glob(filepath.Join(dir, "aquan-cast-*"))
		if err != nil {
			continue
		}
		for _, match := range matches {
			if live[filepath.Clean(match)] {
				continue // 活跃会话仍在服务：删掉它等于拔掉电视正在读的盘
			}
			_ = os.RemoveAll(match)
		}
	}
}

// relayWorkDirCurrent 记录最近一次会话的临时目录基址（mkRelayTempDir 覆写），
// sweepOrphanDirs 据此找到 Android 应用缓存目录里的孤儿目录。
var (
	relayWorkDirMu      sync.Mutex
	relayWorkDirCurrent string
)

// mkRelayTempDir 按基址建会话临时目录（11-08 真机修复）：
// Android 应用进程没有 TMPDIR 环境变量，os.MkdirTemp("", …) 落 /tmp 必败
// （真机实证 CAST_RELAY_INTERNAL「临时目录创建失败」）。Dart 经 work_dir
// 传入 path_provider 临时目录；为空保持现状（桌面零回归）。
func mkRelayTempDir(opts relayOptions) (string, error) {
	relayWorkDirMu.Lock()
	relayWorkDirCurrent = opts.WorkDir
	relayWorkDirMu.Unlock()
	if opts.WorkDir != "" {
		return os.MkdirTemp(opts.WorkDir, "aquan-cast-")
	}
	return os.MkdirTemp("", "aquan-cast-")
}

// urlRedactRe 匹配 http(s) 直链：签名 URL 绝不能进错误详情（弹窗/日志可见）。
var urlRedactRe = regexp.MustCompile(`https?://\S+`)

// redactUrls 把字符串里的 http(s) 直链替换成 <url>。
func redactUrls(s string) string {
	return urlRedactRe.ReplaceAllString(s, "<url>")
}

// relayStderrTail 读会话目录 ffmpeg-stderr.log 的尾部（≤800 字节），去 URL 后
// 以 "; stderr: …" 形式返回；文件缺失/为空返回空串（不拼详情）。
func relayStderrTail(dir string) string {
	data, err := os.ReadFile(filepath.Join(dir, "ffmpeg-stderr.log"))
	if err != nil {
		return ""
	}
	s := strings.TrimSpace(string(data))
	if s == "" {
		return ""
	}
	if len(s) > 800 {
		s = s[len(s)-800:]
		// 尾切可能劈开 UTF-8 字符：跳到下一个合法起始字节。
		for len(s) > 0 && !utf8ValidPrefix(s) {
			s = s[1:]
		}
	}
	return "; stderr: " + redactUrls(s)
}

// utf8ValidPrefix 判断 s 是否从合法 UTF-8 序列开始（前导字节连续性检查）。
func utf8ValidPrefix(s string) bool {
	if s == "" {
		return true
	}
	b := s[0]
	if b < 0x80 || (b&0xC0) == 0xC0 {
		return true // ASCII 或多字节序列首字节
	}
	return false // 0x80-0xBF 是续字节：被劈开
}

// startSweeper 启动空闲回收（30s 扫一遍，5 分钟无访问即回收）。
func startSweeper() {
	relayMu.Lock()
	defer relayMu.Unlock()
	if relaySweeper != nil {
		return
	}
	relaySweeper = time.NewTicker(30 * time.Second)
	go func(t *time.Ticker) {
		for range t.C {
			relayMu.Lock()
			var expired []string
			for id, s := range relaySessions {
				if time.Since(s.lastAccessAt()) > relayIdleTimeout {
					expired = append(expired, id)
				}
			}
			relayMu.Unlock()
			for _, id := range expired {
				relayStop(id)
			}
		}
	}(relaySweeper)
}

// buildFFmpegArgs 组装转码命令，按输出档位分流（R2）：
//
//   - hls（默认/空/未知值）：libx264+aac 转 HLS（guoappxxx 验证参数，
//     **字节级保持现状**——hls 分支的任何改动都会影响已调通的设备）；
//     x264 重编码参数按画质档位（R2）取 [x264VideoParams]，balanced 档
//     与现状逐字节一致；`-hls_flags independent_segments` 按内核版本
//     挂载（见 [ffmpegHasIndependentSegments]）；
//   - ts：Sink 只认 TS 容器时 remux（-c copy 不重编码，WMP 族不认 HLS
//     清单，TS 直流才是它们的母语；-muxdelay 0 / -muxpreload 0 降起播
//     延迟），产物单文件 stream.ts。画质档位不影响本分支（无重编码）。
func buildFFmpegArgs(ffmpeg string, opts relayOptions, dir string, decKey string) []string {
	input := opts.URL
	if decKey != "" {
		decKey = strings.ToLower(strings.TrimPrefix(decKey, "0x"))
	}
	// 输入侧容错（11-11 真机 stderr）：红果的 TS/HLS 源里有破损的 AAC/ADTS 帧
	//（`skip_data_stream_element: Input buffer exhausted`），-c copy 把它原样
	// 塞进 mpegts 时 muxer 报 -1094995529（AVERROR_INVALIDDATA）**直接退出**，
	// 于是每次 TS 降级都「中继启动失败 → 回退直投 → 电视停」。discardcorrupt
	// 让解复用层丢弃被标记损坏的包，ignore_err 让解析错误不致命。
	args := []string{
		ffmpeg, "-hide_banner", "-loglevel", "error",
		"-fflags", "+discardcorrupt", "-err_detect", "ignore_err",
	}
	var headers string
	if opts.UserAgent != "" {
		headers += "User-Agent: " + opts.UserAgent + "\r\n"
	}
	if opts.Referer != "" {
		headers += "Referer: " + opts.Referer + "\r\n"
	}
	if headers != "" {
		args = append(args, "-headers", headers)
	}
	if decKey != "" {
		args = append(args, "-decryption_key", decKey)
	}
	// 输入侧自愈（11-10）：签名直链是长连接 CDN，一次握手卡死现在会让 ffmpeg
	// 无限阻塞——已缓冲的分片播完就「卡住」（报告 B/C：产物停在 14 片 / 4 片）。
	// rw_timeout 让读写超时退出，reconnect 让瞬时断流自愈。仅 http(s) 输入挂载，
	// 其他协议不认这些选项会直接秒退。
	inputArgs := relayInputArgs(input)
	if opts.Format == "ts" {
		args = append(args, inputArgs...)
		args = append(args, "-i", input)
		// 编码兜底（11-09）：ts 档原本恒 -c copy 只做转封装——源是 HEVC/AV1 时
		// 产物仍是 HEVC/AV1，而多数 DLNA 电视只认 H.264 over TS（标准强制项），
		// 表现就是「连上了但播不出来」。这类源退回重编码；H.264 源保持 remux。
		if isHighCodecHint(opts.CodecHint) {
			args = append(args, x264VideoParams(opts.Quality)...)
			args = append(args,
				"-c:a", "aac", "-b:a", "96k", "-ac", "2",
				"-muxdelay", "0", "-muxpreload", "0",
				"-f", "mpegts",
				filepath.Join(dir, "stream.ts"),
			)
			return args
		}
		// 视频仍 copy（不重编码是 ts 档的全部意义），音频**必须重编**：
		// 源站 ADTS 帧常带破损（真机 stderr 实证），原样 copy 到 mpegts 会被
		// muxer 判为非法数据直接退出。AAC 重编码增量极小（96k/2ch）。
		args = append(args,
			"-c:v", "copy",
			"-c:a", "aac", "-b:a", "96k", "-ac", "2",
			"-muxdelay", "0", "-muxpreload", "0",
			"-f", "mpegts",
			filepath.Join(dir, "stream.ts"),
		)
		return args
	}
	// 备用地址：主地址 ffmpeg 自己会失败退出 → 上层重试时换备用。
	args = append(args, inputArgs...)
	args = append(args, "-i", input)
	args = append(args, x264VideoParams(opts.Quality)...)
	args = append(args,
		"-c:a", "aac", "-b:a", "96k", "-ac", "2",
		"-f", "hls",
		"-hls_time", "3",
		// 关键帧对齐 hls_time（11-09 连播修复，桌面镜像同款教训）：
		// 不强制 IDR 时 -hls_time 只是「最小片长」建议，源 GOP 长则切出十几秒
		// 的分片（真机日志：电视每 3s 一片是巧合，长 GOP 源会长时间无新片），
		// 弱接收端缓冲耗尽即退出。该参数 ffmpeg 1.x 起存在，无需版本门控。
		"-force_key_frames", "expr:gte(t,n_forced*3)",
		"-hls_playlist_type", "event",
	)
	// hls_flags（11-10）：
	//   - temp_file：分片先写 <name>.tmp、写完再改名。没有它，电视可能读到
	//     「清单里已出现但还在写」的半截分片（弱固件一次就读死）；
	//   - independent_segments 是 ffmpeg 4.3（2020-06）新增的 flag——内置
	//     2018 构建（4.0.x）不认识，Eval 解析报「Undefined constant」秒退
	//     （11-09 真机 stderr 实证）。按版本探测挂载：新内核保持原参数（桌面
	//     已验证链路字节级不变）；旧内核摘除——该 flag 只给播放列表加
	//     #EXT-X-INDEPENDENT-SEGMENTS 建议性标签，摘除无兼容影响。
	hlsFlags := []string{"temp_file"}
	if ffmpegHasIndependentSegments(ffmpeg) {
		hlsFlags = append(hlsFlags, "independent_segments")
	}
	// 多个 flag 用 '+' 连接：hls_flags 是带头 unit 的 flags 选项，ffmpeg 会把它
	// 整体当表达式求值，逗号形式直接报 "Invalid chars ','"（真机实测）。
	args = append(args, "-hls_flags", strings.Join(hlsFlags, "+"))
	args = append(args,
		"-hls_segment_filename", filepath.Join(dir, "seg_%05d.ts"),
		filepath.Join(dir, "index.m3u8"),
	)
	return args
}

// relayInputArgs 返回输入侧（`-i` 之前）的网络容错参数（11-10）。
//
// 只对 http(s) 输入挂载：其他协议（本地文件、concat 等）不认识这些选项，
// ffmpeg 会以「Option not found」秒退。AQUAN_RELAY_NO_RECONNECT=1 可整体
// 关闭（真机怀疑重连与签名地址交互异常时的保守开关）。
func relayInputArgs(input string) []string {
	lower := strings.ToLower(strings.TrimSpace(input))
	if !strings.HasPrefix(lower, "http://") && !strings.HasPrefix(lower, "https://") {
		return nil
	}
	if os.Getenv("AQUAN_RELAY_NO_RECONNECT") == "1" {
		return nil
	}
	return []string{
		// 15s 无读写即判超时（微秒）：CDN 卡死时让 ffmpeg 退出而不是无限挂住，
		// 上层据 exitCode 走换线/重连，用户不再对着「转码中」黑屏。
		"-rw_timeout", "15000000",
		"-reconnect", "1",
		"-reconnect_streamed", "1",
		"-reconnect_delay_max", "3",
	}
}

// ffmpeg 能力探测缓存（key = 解析到的 ffmpeg 路径）：进程内每个二进制至多
// 探一次 `ffmpeg -version`。
var (
	ffmpegCapsMu sync.Mutex
	ffmpegCaps   = map[string]bool{}
)

// ffmpegHasIndependentSegments 该 ffmpeg 是否支持 hls_flags
// independent_segments（≥4.3）。探测失败/解析失败一律按「不支持」——摘
// flag 是全版本安全侧。
func ffmpegHasIndependentSegments(ffmpeg string) bool {
	ffmpegCapsMu.Lock()
	cached, ok := ffmpegCaps[ffmpeg]
	ffmpegCapsMu.Unlock()
	if ok {
		return cached
	}
	supported := probeFfmpegIndependentSegments(ffmpeg)
	ffmpegCapsMu.Lock()
	ffmpegCaps[ffmpeg] = supported
	ffmpegCapsMu.Unlock()
	return supported
}

func probeFfmpegIndependentSegments(ffmpeg string) bool {
	out, err := execCommand([]string{ffmpeg, "-version"}).Output()
	if err != nil {
		return false
	}
	return ffmpegVersionAtLeast43(string(out))
}

// ffmpegVersionAtLeast43 解析 `ffmpeg -version` 输出的首行
// "ffmpeg version X.Y…"：
//   - 剥离 n/v 前缀（n4.3.1 / v4.0.2 拼写）；
//   - '-'/'+/' 截断：git 日期构建（2024-05-05-git-…）按年份判=新；
//     master 缩写（N-109483-g…）截成 "N" 解析失败按旧=安全侧；
//   - 4.3（2020-06）起支持 independent_segments。
func ffmpegVersionAtLeast43(versionOut string) bool {
	const marker = "version "
	i := strings.Index(versionOut, marker)
	if i < 0 {
		return false
	}
	fields := strings.Fields(versionOut[i+len(marker):])
	if len(fields) == 0 {
		return false
	}
	v := strings.TrimPrefix(strings.TrimPrefix(fields[0], "n"), "v")
	if j := strings.IndexAny(v, "-+"); j >= 0 {
		v = v[:j]
	}
	majorMinor := strings.Split(v, ".")
	major, err := strconv.Atoi(majorMinor[0])
	if err != nil || major <= 0 {
		return false
	}
	minor := 0
	if len(majorMinor) > 1 {
		minor, _ = strconv.Atoi(majorMinor[1])
	}
	return major > 4 || (major == 4 && minor >= 3)
}

// x264VideoParams 按画质档位返回 x264 重编码参数（R2 画质三档）：
//
//   - high：crf 20 + preset fast（画质优先，CPU 占用更高）；
//   - balanced（含空/未知值）：crf 25 + preset veryfast —— **现状参数逐字节
//     不动**，旧调用方（未传 quality）零回归；
//   - compact：crf 30 + preset veryfast + maxrate 2M / bufsize 4M（省流档，
//     给低配发送机与窄带宽）。
//
// 仅影响 x264 重编码分支；`-c copy` 的 TS 档不受影响。前四段
// （-c:v/-preset/-crf/-pix_fmt）三档形状一致，便于测试与 diff。
// isHighCodecHint 判断源编码提示是否属于「DLNA 电视普遍不认」的高压缩编码：
// HEVC/H.265 与 AV1。空串/H.264/未知一律 false（走 -c copy，保持低 CPU）。
func isHighCodecHint(hint string) bool {
	switch strings.ToLower(strings.TrimSpace(hint)) {
	case "hevc", "h265", "h.265", "av1":
		return true
	default:
		return false
	}
}

func x264VideoParams(quality string) []string {
	switch quality {
	case "high":
		return []string{
			"-c:v", "libx264", "-preset", "fast", "-crf", "20", "-pix_fmt", "yuv420p",
		}
	case "compact":
		return []string{
			"-c:v", "libx264", "-preset", "veryfast", "-crf", "30", "-pix_fmt", "yuv420p",
			"-maxrate", "2M", "-bufsize", "4M",
		}
	default:
		// balanced / 空 / 未知值：现状参数（字节级保持，证据缺失回落现状）。
		return []string{
			"-c:v", "libx264", "-preset", "veryfast", "-crf", "25", "-pix_fmt", "yuv420p",
		}
	}
}

// findFFmpeg 按优先级定位可执行的 ffmpeg。
//
// Android 上没有 PATH 里的 ffmpeg，也没有「exe 同目录」的概念：二进制由
// jniLibs 打包、系统解压到 nativeLibraryDir，文件名 libffmpeg.so（是 PIE
// 可执行文件而不是共享库，改名只是为了让它进 nativeLibraryDir）。
// 因此额外两跳：环境变量 AQUAN_FFMPEG → nativeLibraryDir。
func findFFmpeg() (string, error) {
	if p := os.Getenv("AQUAN_FFMPEG"); isExecutableFile(p) {
		return p, nil
	}
	if dir := nativeLibraryDir(); dir != "" {
		for _, name := range []string{"libffmpeg.so", "ffmpeg"} {
			p := filepath.Join(dir, name)
			if isExecutableFile(p) {
				return p, nil
			}
		}
	}
	if exe, err := os.Executable(); err == nil {
		for _, name := range []string{"ffmpeg.exe", "ffmpeg"} {
			p := filepath.Join(filepath.Dir(exe), name)
			if isExecutableFile(p) {
				return p, nil
			}
		}
	}
	return exec.LookPath("ffmpeg")
}

// isExecutableFile 要求路径存在、是普通文件、且有任一执行位。
//
// Windows 不看权限位（os.Stat 在那里的 perm 不反映 ACL），只看存在性——
// 桌面端原本就是「exe 旁有 ffmpeg.exe 就用」，不能因为权限位判断退化。
func isExecutableFile(path string) bool {
	if path == "" {
		return false
	}
	info, err := os.Stat(path)
	if err != nil || !info.Mode().IsRegular() {
		return false
	}
	if runtime.GOOS == "windows" {
		return true
	}
	return info.Mode().Perm()&0o111 != 0
}

// nativeLibraryDir 在 Android 上定位应用的原生库目录。
//
// Go 侧拿不到 Java 的 ApplicationInfo，但进程 maps 里一定有 libaquan_core.so，
// 它所在目录就是 nativeLibraryDir。非 Android 直接返回空串。
func nativeLibraryDir() string {
	if runtime.GOOS != "android" {
		return ""
	}
	data, err := os.ReadFile("/proc/self/maps")
	if err != nil {
		return ""
	}
	return parseNativeLibDir(string(data))
}

// parseNativeLibDir 从 /proc/self/maps 内容里取出 libaquan_core.so 所在目录。
//
// 行格式：`7f... r-xp 00000000 fd:01 1234 /data/app/.../lib/arm64/libaquan_core.so`
// 第 6 列是映射文件路径。
func parseNativeLibDir(maps string) string {
	for _, line := range strings.Split(maps, "\n") {
		if !strings.Contains(line, "libaquan_core.so") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 6 {
			continue
		}
		mapped := fields[5]
		if !strings.HasPrefix(mapped, "/") {
			continue
		}
		// maps 里的路径永远是 POSIX 形式：必须用 path 而不是 filepath，
		// 否则在 Windows 上跑单测会被改写成反斜杠。
		return path.Dir(mapped)
	}
	return ""
}

// cleanProxyEnv 清空全部代理变量（上游是签名直链）。
func cleanProxyEnv() []string {
	out := make([]string, 0, len(os.Environ()))
	for _, e := range os.Environ() {
		upper := strings.ToUpper(e)
		if strings.HasPrefix(upper, "HTTP_PROXY=") ||
			strings.HasPrefix(upper, "HTTPS_PROXY=") ||
			strings.HasPrefix(upper, "ALL_PROXY=") ||
			strings.HasPrefix(upper, "NO_PROXY=") {
			continue
		}
		out = append(out, e)
	}
	return out
}

func randomToken() (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

// listenOnFreePort 从 base 起顺延探测可用端口并**预绑定**监听（消除二次绑定竞态）。
func listenOnFreePort(base int) (int, net.Listener, error) {
	for port := base; port < base+50; port++ {
		ln, err := net.Listen("tcp", fmt.Sprintf("0.0.0.0:%d", port))
		if err != nil {
			continue
		}
		return port, ln, nil
	}
	return 0, nil, fmt.Errorf("no free port from %d", base)
}

func indexReady(dir string) bool {
	_, err := os.Stat(filepath.Join(dir, "index.m3u8"))
	return err == nil
}

// tsReady 判定 TS 直流产物就绪（R2）：stream.ts 存在且 > 64KB——对齐 hls
// ready 的保守口径（起步阶段的空洞/极小文件不算就绪，避免把启动瞬间当
// 「转码完成」）。
func tsReady(dir string) bool {
	info, err := os.Stat(filepath.Join(dir, "stream.ts"))
	return err == nil && info.Size() > 64*1024
}

func hasSegments(dir string) bool {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return false
	}
	for _, e := range entries {
		if strings.HasSuffix(e.Name(), ".ts") {
			return true
		}
	}
	return false
}

// isUsableLanIPv4 判断地址能否写进投屏 URL：必须是 IPv4 且非回环/未指定/
// 链路本地。空串与域名一律 false（域名不能直接拼进 URL 的主机段）。
func isUsableLanIPv4(raw string) bool {
	ip := net.ParseIP(strings.TrimSpace(raw))
	if ip == nil {
		return false
	}
	v4 := ip.To4()
	if v4 == nil {
		return false
	}
	return !v4.IsLoopback() && !v4.IsUnspecified() && !v4.IsLinkLocalUnicast()
}

// sameSubnet24 两个 IPv4 是否同 /24（同网段地址最可能就是电视可达的网卡）。
func sameSubnet24(a, b net.IP) bool {
	a4, b4 := a.To4(), b.To4()
	if a4 == nil || b4 == nil {
		return false
	}
	return a4[0] == b4[0] && a4[1] == b4[1] && a4[2] == b4[2]
}

// lanIPOnTargetSubnet 枚举网卡里与 host 同 /24 的地址。host 只接受 IP 字面量：
// 域名解析可能卡住，投屏主链路（FFI 同步调用）不能等。
func lanIPOnTargetSubnet(host string) string {
	target := net.ParseIP(strings.TrimSpace(host))
	if target == nil || target.To4() == nil {
		return ""
	}
	addrs, err := net.InterfaceAddrs()
	if err != nil {
		return ""
	}
	for _, addr := range addrs {
		ipnet, ok := addr.(*net.IPNet)
		if !ok || ipnet.IP.IsLoopback() || ipnet.IP.To4() == nil {
			continue
		}
		if !isUsableLanIPv4(ipnet.IP.String()) {
			continue
		}
		if sameSubnet24(ipnet.IP, target) {
			return ipnet.IP.To4().String()
		}
	}
	return ""
}

// isLoopbackHost 目标就是本机（同机接收端：桌面端 airpin/WaxRain、WMP。
// 这类目标只能走回环地址，不算「探测失败」）。
func isLoopbackHost(host string) bool {
	h := strings.TrimSpace(strings.ToLower(host))
	if h == "" {
		return false
	}
	if h == "localhost" {
		return true
	}
	ip := net.ParseIP(h)
	return ip != nil && ip.IsLoopback()
}

// resolveProductHost 选一个**目标设备可达**的本机地址（11-10 真机修复）。
//
// 优先级：
//  1. opts.LanIP —— 发送端（Dart）自己解析的地址。Windows 侧用 iphlpapi 查
//     到目标的最优路由，比 Go 的 UDP connect 更准；且预起中继时还没有目标
//     设备（host_hint 为空），只有它能给出正确地址。
//  2. 到 host_hint 的路由源 IP（11-09 策略）。
//  3. 与 host_hint 同 /24 的网卡地址（路由探测失败但网段已知时的兜底）。
//  4. lanIP() 枚举（192.168 > 10 > 172.16-31 > 任意）。
//
// 全部落到回环/未指定时返回 false：调用方据此失败，**绝不**把 127.0.0.1
// 写进投屏 URL（除目标本身是本机接收端）。这是报告 A「本机 IP：127.0.0.1
// + 电视 0 取流」的直接成因。
func resolveProductHost(opts relayOptions) (string, bool) {
	if isUsableLanIPv4(opts.LanIP) {
		return strings.TrimSpace(opts.LanIP), true
	}
	if ip := relayRouteSourceIP(opts.HostHint); ip != "" {
		return ip, true
	}
	if ip := lanIPOnTargetSubnet(opts.HostHint); ip != "" {
		return ip, true
	}
	ip := relayLanIP()
	if isUsableLanIPv4(ip) {
		return ip, true
	}
	if isLoopbackHost(opts.HostHint) {
		return ip, true
	}
	return "", false
}

// 探测函数做成变量：单测替换成固定值，避免依赖跑测试那台机器的网卡。
var (
	relayRouteSourceIP = routeSourceIPv4
	relayLanIP         = lanIP
)

// lanIPFor 取一个**目标设备可达**的本机地址（11-09 取流修复）。
//
// 优先用 UDP connect 探到目标主机的路由源地址（不实际发包）：多网卡
// （WSL/Hyper-V/VPN/运营商 NAT）下「枚举第一个私网地址」经常不是电视能回的
// 那张网卡。探不到再回落 [lanIP] 的枚举策略。
//
// 历史坑（真机日志实证）：旧实现只用 ip.IsPrivate() 过滤，PC 拿到 100.64/10
// （CGNAT）或公网地址时被全部丢弃 → 回退 127.0.0.1 写进投屏 URL。只有会把
// loopback 改写成来源 IP 的接收端（airpin）还能播，其余设备一律取流失败。
func lanIPFor(hostHint string) string {
	if ip := routeSourceIPv4(hostHint); ip != "" {
		return ip
	}
	return lanIP()
}

// routeSourceIPv4 用 UDP connect 探「到 host 的路由源 IPv4」（不发送数据包）。
// host 可为 IP 或域名；空/失败/回环/链路本地一律返回空串（由调用方回落）。
func routeSourceIPv4(host string) string {
	host = strings.TrimSpace(host)
	if host == "" {
		return ""
	}
	// DialTimeout：host 可能是用户手输的主机名，DNS 卡住不能在投屏主链路上
	// 同步等待（castRelayStart 是 FFI 调用，卡住会表现为「投屏没反应」）。
	conn, err := net.DialTimeout("udp4", net.JoinHostPort(host, "1900"),
		500*time.Millisecond)
	if err != nil {
		return ""
	}
	defer conn.Close()
	addr, ok := conn.LocalAddr().(*net.UDPAddr)
	if !ok || addr.IP == nil {
		return ""
	}
	ip := addr.IP.To4()
	if ip == nil || ip.IsLoopback() || ip.IsLinkLocalUnicast() || ip.IsUnspecified() {
		return ""
	}
	return ip.String()
}

// lanIP 取一个电视可达的局域网地址：偏好 192.168.* > 10.* > 172.16-31 >
// 其余任意 IPv4，跳过回环/169.254 链路本地（Windows 上按字典序选会踩坑）。
//
// 11-09 修订：去掉 ip.IsPrivate() 硬过滤。该过滤会把 100.64/10（运营商 NAT）
// 与公网段一起丢弃，多网卡或特殊网络下直接落到 127.0.0.1 回退值——投屏 URL
// 变成 loopback，除 airpin 外所有接收端都取不到流。现在把「非首选的私网外
// 地址」留作最后兜底，宁可给出一个真实网卡地址也不回 loopback。
func lanIP() string {
	addrs, err := net.InterfaceAddrs()
	if err != nil {
		return "127.0.0.1"
	}
	var prefer192, prefer10, prefer172, fallback string
	for _, addr := range addrs {
		ipnet, ok := addr.(*net.IPNet)
		if !ok || ipnet.IP.IsLoopback() || ipnet.IP.To4() == nil {
			continue
		}
		ip := ipnet.IP.To4()
		if ip.IsLinkLocalUnicast() || ip.IsUnspecified() {
			continue
		}
		s := ip.String()
		switch {
		case strings.HasPrefix(s, "192.168."):
			prefer192 = s
		case strings.HasPrefix(s, "10."):
			if prefer10 == "" {
				prefer10 = s
			}
		case isPrivate172(s):
			if prefer172 == "" {
				prefer172 = s
			}
		default:
			if fallback == "" {
				fallback = s
			}
		}
	}
	if prefer192 != "" {
		return prefer192
	}
	if prefer10 != "" {
		return prefer10
	}
	if prefer172 != "" {
		return prefer172
	}
	if fallback != "" {
		return fallback
	}
	return "127.0.0.1"
}

// isPrivate172 判断 172.16.0.0/12（第二段 16–31）：注释一直这么写，旧实现
// 只按 "172." 前缀放行，会把 172.0/172.32 误当私网。
func isPrivate172(ip string) bool {
	parts := strings.Split(ip, ".")
	if len(parts) != 4 || parts[0] != "172" {
		return false
	}
	second, err := strconv.Atoi(parts[1])
	if err != nil {
		return false
	}
	return second >= 16 && second <= 31
}

// relayOptionsFromJSON 解析 Dart 传来的 options JSON。
func relayOptionsFromJSON(raw []byte) (relayOptions, error) {
	var opts relayOptions
	if err := json.Unmarshal(raw, &opts); err != nil {
		return opts, relayFail(ErrRelayInvalid, "options 解析失败")
	}
	if opts.URL == "" {
		return opts, relayFail(ErrRelayInvalid, "缺少播放地址")
	}
	return opts, nil
}

// ---------- 投屏会话共享助手（castrelay / castdesktop 共用） ----------

func mkCastTempDir(prefix string) (string, error) { return os.MkdirTemp("", prefix) }

func removeCastDir(dir string) { _ = os.RemoveAll(dir) }

func execCommand(args []string) *exec.Cmd { return exec.Command(args[0], args[1:]...) }

func newCastServer() *http.Server { return &http.Server{Handler: http.NotFoundHandler()} }

// stopAndRemove 停进程/服务并清理临时目录（启动失败快路径）。
func stopAndRemove(s *relaySession) {
	relayStop(s.id)
}

// putRelaySession 登记会话（relayMu 保护）。
func putRelaySession(s *relaySession) {
	relayMu.Lock()
	relaySessions[s.id] = s
	relayMu.Unlock()
}

// relayStatus 按会话 ID 查状态（castRelayStatus/castDesktopStatus 共用）。
func relayStatus(sessionID string) (*relaySessionInfo, error) {
	relayMu.Lock()
	s := relaySessions[sessionID]
	relayMu.Unlock()
	if s == nil {
		return nil, relayFail(ErrRelayNoSession, "会话不存在或已回收")
	}
	return s.info(), nil
}

// serveCastFiles 挂 /cast/<token>/ 静态清单与分片服务并开始监听
// （端口已由 listenOnFreePort 预绑定，不存在二次绑定竞态）。
func serveCastFiles(s *relaySession, ln net.Listener) {
	mux := http.NewServeMux()
	mux.HandleFunc("/cast/"+s.token+"/", s.serveCastFile)
	s.srv.Handler = mux
	go func() {
		_ = s.srv.Serve(ln)
	}()
}

// serveCastFile 伺服单个清单/分片并记录电视取流日志（M0-5）。
// http.ServeFile 自己处理 Range/206/416：用 accessRecorder 包一层拿状态码
// 与字节数，并按 M1-9 条件化规则附加 DLNA 响应头。
//
// ts 档（R2）：token 根路径（无清单可给）301 到 stream.ts——部分接收端只
// 拼 token 前缀取流，重定向保证拿得到产物；stream.ts **走增长流**（见
// [serveGrowingTS]）——它是 ffmpeg 边写边长的单文件，ServeFile 会按打开瞬间
// 的 Content-Length 一次性发完，电视播到该长度就结束（WMP 族「播一会就停」）。
//
// hls 档根路径不再 ServeFile(dir)：那会直接回目录列表（暴露分片清单与 token
// 生命周期），按 404 处理，与「无此资源」语义一致。
func (s *relaySession) serveCastFile(w http.ResponseWriter, r *http.Request) {
	s.touch()
	name := strings.TrimPrefix(r.URL.Path, "/cast/"+s.token+"/")
	if name == "" || name == "/" {
		rec := s.newAccessRecorder(w, r, "")
		if s.format == "ts" {
			http.Redirect(rec, r, "stream.ts", http.StatusMovedPermanently)
			s.recordAccess(r, rec.status, rec.bytes)
			return
		}
		http.NotFound(rec, r)
		s.recordAccess(r, rec.status, rec.bytes)
		return
	}
	name = filepath.Base(name) // 防 ../ 穿越
	lower := strings.ToLower(name)
	if s.format == "ts" && strings.HasSuffix(lower, ".ts") {
		s.serveGrowingTS(w, r, name)
		return
	}
	path := filepath.Join(s.dir, name)
	if strings.HasSuffix(lower, ".m3u8") {
		// ts 档没有清单：固定回 301 到 stream.ts（部分接收端只拼 index.m3u8）。
		if s.format == "ts" {
			rec := s.newAccessRecorder(w, r, name)
			http.Redirect(rec, r, "stream.ts", http.StatusMovedPermanently)
			s.recordAccess(r, rec.status, rec.bytes)
			return
		}
		// 清单走「快照」而不是 ServeFile（11-10）：ffmpeg 是原地 truncate+重写
		// 清单，ServeFile 按 Stat 出来的长度直读，撞上重写窗口就会把半截清单
		// 发给电视（弱固件直接停播）。
		s.servePlaylistSnapshot(w, r, name, path)
		return
	}
	if strings.HasPrefix(lower, "seg_") && strings.HasSuffix(lower, ".ts") {
		// 分片抢跑容错（11-10）：部分固件会先按序号猜下一个分片再回头拉清单，
		// 此时文件还没落盘。短暂等一拍再 404，避免一次「猜空」就退出播放。
		waitForRelayProduct(path, s.ffmpegEnded.Load)
	}
	rec := s.newAccessRecorder(w, r, name)
	http.ServeFile(rec, r, path)
	s.recordAccess(r, rec.status, rec.bytes)
}

// relayPlaylistWait 是清单/分片「还没落盘」时的最长等待：弱固件抢跑一拍
// （≤2s）能救回来，长时间挂着会白占电视的连接池。
const (
	relayPlaylistWait = 300 * time.Millisecond
	relaySegmentWait  = 2 * time.Second
	relayProductPoll  = 100 * time.Millisecond
)

// servePlaylistSnapshot 把 HLS 清单整份读进内存后一次写出（11-10）。
//
// 契约：200 + application/vnd.apple.mpegurl + Content-Length + Cache-Control:
// no-store；忽略 Range / If-Modified-Since（清单是活文档，304 会让电视永远
// 停在旧版本）。内容不完整（未以换行结尾）时短暂重试，超时仍返回最后一次
// 快照——返回空体比返回半行更糟。
func (s *relaySession) servePlaylistSnapshot(w http.ResponseWriter, r *http.Request, name, path string) {
	rec := s.newAccessRecorder(w, r, name)
	data, ok := readPlaylistSnapshot(path, relayPlaylistWait, s.ffmpegEnded.Load)
	if !ok {
		http.NotFound(rec, r)
		s.recordAccess(r, rec.status, rec.bytes)
		return
	}
	h := rec.Header()
	h.Set("Content-Type", "application/vnd.apple.mpegurl")
	h.Set("Cache-Control", "no-store")
	h.Set("Content-Length", strconv.Itoa(len(data)))
	rec.WriteHeader(http.StatusOK)
	_, _ = rec.Write(data)
	s.recordAccess(r, rec.status, rec.bytes)
}

// readPlaylistSnapshot 读取一份「完整」的清单快照。
//
// 完整性判据：首行是 #EXTM3U 且内容以 '\n' 结尾（ffmpeg 每写一行都带换行，
// 半行/空文件说明正好撞上重写窗口）。ffmpeg 已退出时不再重试——产物定稿。
func readPlaylistSnapshot(path string, wait time.Duration, ffmpegDone func() bool) ([]byte, bool) {
	deadline := time.Now().Add(wait)
	var last []byte
	for {
		data, err := os.ReadFile(path)
		if err != nil {
			if time.Now().Before(deadline) && !ffmpegDone() {
				time.Sleep(relayProductPoll)
				continue
			}
			return nil, false
		}
		last = data
		if playlistLooksComplete(data) {
			return data, true
		}
		if time.Now().After(deadline) || ffmpegDone() {
			if len(last) == 0 {
				return nil, false
			}
			return last, true
		}
		time.Sleep(relayProductPoll)
	}
}

// playlistLooksComplete 判定清单快照是否写到行边界。
func playlistLooksComplete(data []byte) bool {
	if len(data) < 7 || !strings.HasPrefix(string(data), "#EXTM3U") {
		return false
	}
	return data[len(data)-1] == '\n'
}

// waitForRelayProduct 等产物文件落盘（≤relaySegmentWait）。ffmpeg 已退出时
// 不再等——不会再有新文件。
func waitForRelayProduct(path string, ffmpegDone func() bool) {
	deadline := time.Now().Add(relaySegmentWait)
	for {
		if info, err := os.Stat(path); err == nil && info.Size() > 0 {
			return
		}
		if time.Now().After(deadline) || ffmpegDone() {
			return
		}
		time.Sleep(relayProductPoll)
	}
}

// serveGrowingTS 持续推送 ts 档产物（11-09 兼容修复）。
//
// 背景：ts 档是 `-c copy -f mpegts` 边写边长的 stream.ts，播放器看到的是
// 「不断变长的文件」。http.ServeFile 会按 Stat 出来的当前大小发
// Content-Length，读满即 EOF——电视播到打开时的长度就结束（WMP 族黑屏/秒停）。
//
// 契约：
//   - 200 + video/mp2t，**不写 Content-Length**（HTTP/1.1 自动 chunked）；
//   - 忽略 Range（增长流无随机访问语义），Accept-Ranges: none 明确告知；
//   - 有字节就写并 Flush；读到文件尾时：ffmpeg 已退出且无新数据 → 正常结束，
//     否则每 200ms 重试；30s 无新字节或客户端断开 → 结束；
//   - 结束时记一条取流日志（字节数 = 实际推送量），诊断与 hls 分片同口径。
func (s *relaySession) serveGrowingTS(w http.ResponseWriter, r *http.Request, name string) {
	// 转码已收尾 = 文件不再变长（11-10）：改按静态文件伺服，拿到
	// Content-Length 与 Range/206。WMP 族等「文件式」播放器对 chunked
	// 且不可 seek 的响应会直接不播或播完不能拖动；收尾后没有增长语义，
	// 静态响应对所有接收端都更友好。
	path := filepath.Join(s.dir, name)
	if s.ffmpegEnded.Load() {
		if _, err := os.Stat(path); err == nil {
			rec := s.newAccessRecorder(w, r, name)
			http.ServeFile(rec, r, path)
			s.recordAccess(r, rec.status, rec.bytes)
			return
		}
	}
	f, err := os.Open(path)
	if err != nil {
		rec := s.newAccessRecorder(w, r, name)
		http.NotFound(rec, r)
		s.recordAccess(r, rec.status, rec.bytes)
		return
	}
	defer f.Close()

	h := w.Header()
	h.Set("Content-Type", "video/mp2t")
	setDlnaHeader(h, "transferMode.dlna.org", "Streaming")
	// 增长流不支持随机 seek：设备显式索要才回，且 OP=00（不谎报 byte-seek）。
	if r.Header.Get("Getcontentfeatures.dlna.org") == "1" {
		setDlnaHeader(h, "contentFeatures.dlna.org", relayStreamContentFeatures)
	}
	setDlnaHeader(h, "realTimeInfo.dlna.org", "DLNA.ORG_TLAG=*")
	if s.subtitleURL != "" {
		setDlnaHeader(h, "CaptionInfo.sec", s.subtitleURL)
	}
	h.Set("Accept-Ranges", "none")
	h.Set("Cache-Control", "no-store")
	h.Set("Connection", "close")
	w.WriteHeader(http.StatusOK)

	// 无子进程（单测直建会话 / 旧路径）视为已结束：静态文件读到尾即收尾，
	// 不会白等 relayTSIdle。
	ffmpegDone := func() bool { return s.cmd == nil || s.ffmpegEnded.Load() }

	flusher, _ := w.(http.Flusher)
	buf := make([]byte, 64<<10)
	var off int64
	lastData := time.Now()
	for {
		n, readErr := f.ReadAt(buf, off)
		if n > 0 {
			if _, werr := w.Write(buf[:n]); werr != nil {
				break // 客户端已断开
			}
			off += int64(n)
			lastData = time.Now()
			if flusher != nil {
				flusher.Flush()
			}
		}
		if readErr == nil {
			continue
		}
		if readErr != io.EOF {
			break
		}
		// 文件尾：ffmpeg 结束且确认没有新字节才收尾（Wait 与最后 write 有竞态，
		// 多等一拍再 Stat）。
		if ffmpegDone() {
			select {
			case <-r.Context().Done():
				s.recordAccess(r, http.StatusOK, off)
				return
			case <-time.After(120 * time.Millisecond):
			}
			if st, statErr := f.Stat(); statErr != nil || st.Size() <= off {
				break
			}
			continue
		}
		if time.Since(lastData) > relayTSIdle {
			break
		}
		select {
		case <-r.Context().Done():
			s.recordAccess(r, http.StatusOK, off)
			return
		case <-time.After(relayTSPoll):
		}
	}
	s.recordAccess(r, http.StatusOK, off)
}

// newAccessRecorder 组装取流记录器（条件化 DLNA 头规则见 accessRecorder）。
func (s *relaySession) newAccessRecorder(w http.ResponseWriter, r *http.Request, name string) *accessRecorder {
	return &accessRecorder{
		ResponseWriter: w,
		status:         http.StatusOK,
		// playbridge 条件化写法：设备显式索要才回 contentFeatures。
		wantContentFeatures: r.Header.Get("Getcontentfeatures.dlna.org") == "1",
		// 清单路由不声明 byte-seek（review §8.5 诚实化）：只删 Accept-Ranges
		// 声明，Range 请求仍按 ServeFile 真实行为应答。
		suppressAcceptRanges: strings.HasSuffix(strings.ToLower(name), ".m3u8"),
		// 字幕第三通道（R3）：仅会话登记了字幕才带（与 Dart 侧
		// LocalMediaServer/CastMediaProxy 同规，未登记不产生噪声）。
		captionSec: s.subtitleURL,
	}
}

// relayContentFeatures 是 hls 档 contentFeatures.dlna.org 的值：分片是静态
// 文件，支持字节 Range 206 → OP=01；分片本身已转码但这里描述的是「传输字节」
// 的读取方式，保持 CI=0。
//
// 11-09 精简：不再带 DLNA.ORG_FLAGS。go2tv（utils/dlnatools.go）的实测口径是
// 「只描述真实能力，不伪造 PN/FLAGS」——多余声明在部分固件上会触发 stricter
// parsing，收益为零。
const relayContentFeatures = "DLNA.ORG_OP=01;DLNA.ORG_CI=0"

// relayStreamContentFeatures 是 ts 档（持续推送的单文件）contentFeatures：
// 没有随机访问语义 → OP=00；产物由 ffmpeg 重封装/重编码 → CI=1。
const relayStreamContentFeatures = "DLNA.ORG_OP=00;DLNA.ORG_CI=1"

// setDlnaHeader 直写 header map：net/http 的 Set 会把键名改写成它的规范
// 形式（首字母大写 + 其余小写，"transferMode.dlna.org" 会变成
// "Transfermode.dlna.org"）。DLNA 规范拼写是驼峰式，部分固件按名字面
// 匹配，必须原样输出。
func setDlnaHeader(h http.Header, name, value string) {
	h[name] = []string{value}
}

// accessRecorder 包装 ResponseWriter，捕获状态码与写给电视的字节数（取流日志），
// 并在首写头时附加 DLNA 响应头（M1-9，与 LocalMediaServer/CastMediaProxy 同规）：
// transferMode.dlna.org: Streaming 恒带；contentFeatures.dlna.org 仅当请求带
// getcontentFeatures.dlna.org: 1 才回；realTimeInfo.dlna.org 恒带；
// CaptionInfo.sec 仅会话登记字幕才带（R3）；HLS 清单响应删除 Accept-Ranges
// 声明（TS 分片按 ServeFile 真实现状保留）。
type accessRecorder struct {
	http.ResponseWriter
	status               int
	wroteHeader          bool
	bytes                int64
	wantContentFeatures  bool
	suppressAcceptRanges bool
	captionSec           string // 非空时媒体响应带 CaptionInfo.sec（R3）
}

func (w *accessRecorder) WriteHeader(code int) {
	if !w.wroteHeader {
		w.wroteHeader = true
		h := w.Header()
		setDlnaHeader(h, "transferMode.dlna.org", "Streaming")
		if w.wantContentFeatures {
			setDlnaHeader(h, "contentFeatures.dlna.org", relayContentFeatures)
		}
		if w.captionSec != "" {
			// 直写 header map 保留 Samsung 规范驼峰拼写（与 transferMode 同坑：
			// net/http 的 Set 会把键名改写成首字母大写形式）。
			setDlnaHeader(h, "CaptionInfo.sec", w.captionSec)
		}
		setDlnaHeader(h, "realTimeInfo.dlna.org", "DLNA.ORG_TLAG=*")
		if w.suppressAcceptRanges {
			h.Del("Accept-Ranges")
		}
		w.status = code
	}
	w.ResponseWriter.WriteHeader(code)
}

func (w *accessRecorder) Write(p []byte) (int, error) {
	if !w.wroteHeader {
		w.wroteHeader = true
		w.status = http.StatusOK
	}
	n, err := w.ResponseWriter.Write(p)
	w.bytes += int64(n)
	return n, err
}

// relaySegPathRe 从取流路径里取分片序号（seg_00014.ts → 14）。
var relaySegPathRe = regexp.MustCompile(`seg_(\d+)\.ts`)

// recordAccess 追加一条电视取流记录（环形，超过 relayAccessLogSize 淘汰最旧）。
func (s *relaySession) recordAccess(r *http.Request, status int, bytes int64) {
	ok := status >= 200 && status < 300 && bytes > 0
	if ok {
		s.servedBytes.Add(bytes)
	}
	// 记录电视实际取到的最大分片序号：连播判定「已播到产物末尾」依赖它，
	// 比设备上报的 position 更贴近真实缓冲进度。
	//
	// 11-10：只认 2xx 且有字节的请求。旧实现先自增再判状态码，404 也会显示
	// 「电视已取到 #N」，报告里出现「已产出分片：0（电视已取到 #14）」这种
	// 自相矛盾的数据，直接误导排障。
	if ok {
		if m := relaySegPathRe.FindStringSubmatch(r.URL.Path); m != nil {
			if idx, err := strconv.Atoi(m[1]); err == nil {
				if next := int32(idx) + 1; next > s.lastSegIdx.Load() {
					s.lastSegIdx.Store(next)
				}
			}
		}
	}
	s.logMu.Lock()
	defer s.logMu.Unlock()
	s.logSeq++
	s.accessLog = append(s.accessLog, relayAccessEntry{
		Seq:    s.logSeq,
		At:     time.Now().Format("15:04:05"),
		Path:   r.URL.Path,
		Range:  r.Header.Get("Range"),
		UA:     r.Header.Get("User-Agent"),
		Status: status,
		Bytes:  bytes,
	})
	if len(s.accessLog) > relayAccessLogSize {
		s.accessLog = s.accessLog[len(s.accessLog)-relayAccessLogSize:]
	}
}

// recentAccess 快照最近取流记录（供 info() 组装，避免与 relayMu 嵌套）。
func (s *relaySession) recentAccess() []relayAccessEntry {
	s.logMu.Lock()
	defer s.logMu.Unlock()
	if len(s.accessLog) == 0 {
		return nil
	}
	out := make([]relayAccessEntry, len(s.accessLog))
	copy(out, s.accessLog)
	return out
}
