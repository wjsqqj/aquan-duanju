package core

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/beilunyang/openhongguo/sdk"
	"github.com/beilunyang/openhongguo/sdk/model"
)

// 本文件离线复现 11-26 实测问题：播放页进页时「首集预热」与「正片取流」几乎
// 同时对同一集发起解析，Go 侧原先让后到者立刻拿到 ErrV5Unavailable，解析链
// 随即静默回落 720p 封顶的 webplay——第 1-5 集每次进去只有 720p。

const v5TestProfile = `C:\Users\t\AppData\aquan_device.json`

const v5TestEpisode = "7695629314057849880"

// v5ResetForTest 清空 v5 的缓存 / 在途 / 熔断状态（包级共享，逐用例隔离）。
func v5ResetForTest() {
	v5mu.Lock()
	defer v5mu.Unlock()
	v5cache = map[string]v5cacheEntry{}
	v5inFlight = nil
	v5failStreak = 0
	v5openUntil = time.Time{}
}

// fakeV5Model 是离线替身返回的 v5 模型：5 轨（360p-1080p）+ 内容密钥。
func fakeV5Model(ep string) (*model.Playback, model.ContentKey, string, error) {
	pb := &model.Playback{EpisodeID: ep, Protected: true}
	for _, def := range []string{"360p", "480p", "540p", "720p", "1080p"} {
		pb.Streams = append(pb.Streams, model.Stream{
			Definition: def,
			URL:        "https://cdn.example/" + def + ".mp4",
		})
	}
	return pb, model.ContentKey{Hex: "00112233445566778899aabbccddeeff"}, v5SourceNative, nil
}

type v5Outcome struct {
	pb     *model.Playback
	key    model.ContentKey
	source string
	err    error
}

// waitingCtx 的 Done() 只会在 v5JoinFlight 的 select 里被求值（Go 规范：进入
// select 时按源码顺序对 channel 操作数求值恰好一次）。用它拿「后到者已进入
// 等待」的确定性信号，用例不靠 sleep 赌时序。
type waitingCtx struct {
	context.Context
	seen chan struct{}
}

func (c *waitingCtx) Done() <-chan struct{} {
	select {
	case c.seen <- struct{}{}:
	default:
	}
	return c.Context.Done()
}

// goV5Resolve 在后台 goroutine 发起一次解析，结果经 channel 交回。
func goV5Resolve(ctx context.Context, resolve v5Resolver) <-chan v5Outcome {
	out := make(chan v5Outcome, 1)
	go func() {
		pb, key, source, err := v5Resolve(ctx, nil, v5TestProfile, v5TestEpisode, resolve)
		out <- v5Outcome{pb, key, source, err}
	}()
	return out
}

func awaitV5(t *testing.T, who string, out <-chan v5Outcome) v5Outcome {
	t.Helper()
	select {
	case r := <-out:
		return r
	case <-time.After(5 * time.Second):
		t.Fatalf("%s 5s 内未返回", who)
		return v5Outcome{}
	}
}

// assertV5Model 断言拿到的是完整 v5 模型（5 轨 + 密钥 + 实现来源）。
func assertV5Model(t *testing.T, who string, r v5Outcome) {
	t.Helper()
	if r.err != nil {
		t.Fatalf("%s 应拿到 v5 模型，实际错误: %v", who, r.err)
	}
	if r.pb == nil || len(r.pb.Streams) != 5 || r.key.Hex == "" || r.source != v5SourceNative {
		t.Fatalf("%s 结果不完整: %+v", who, r)
	}
}

// 同集并发只解析一次：后到者等待并共用持票方的 v5 结果（不再立刻判不可用、
// 静默回落 720p）；结果随后进进程内缓存。
func TestV5ResolveSameEpisodeInFlightJoinsResult(t *testing.T) {
	v5ResetForTest()

	entered := make(chan struct{}, 4)
	release := make(chan struct{})
	var calls int32
	resolve := func(_ context.Context, _ *sdk.Client, _, id string) (*model.Playback, model.ContentKey, string, error) {
		atomic.AddInt32(&calls, 1)
		entered <- struct{}{}
		<-release
		return fakeV5Model(id)
	}

	// 持票方（进页预热）：进入解析后卡住，模拟 v5 在途（原生通道约 3s）。
	owner := goV5Resolve(context.Background(), resolve)
	<-entered

	// 等待方（正片取流）：同集并发，确定进入等待后才放行持票方。
	joinerCtx := &waitingCtx{Context: context.Background(), seen: make(chan struct{}, 1)}
	joiner := goV5Resolve(joinerCtx, resolve)
	select {
	case r := <-joiner:
		close(release)
		t.Fatalf("同集在途时后到者不应提前返回: err=%v", r.err)
	case <-joinerCtx.seen:
	}
	if got := atomic.LoadInt32(&calls); got != 1 {
		close(release)
		t.Fatalf("同集并发只应解析一次，实际 %d 次", got)
	}

	close(release)
	a := awaitV5(t, "持票方", owner)
	b := awaitV5(t, "等待方", joiner)
	assertV5Model(t, "持票方", a)
	assertV5Model(t, "等待方", b)
	if a.pb != b.pb || a.key != b.key || a.source != b.source {
		t.Fatal("等待方应共用持票方的结果")
	}

	// 结果已入进程内缓存：再解析同集不触网。
	c := awaitV5(t, "缓存命中", goV5Resolve(context.Background(), resolve))
	assertV5Model(t, "缓存命中", c)
	if c.pb != a.pb {
		t.Fatal("缓存命中应返回同一模型")
	}
	if got := atomic.LoadInt32(&calls); got != 1 {
		t.Fatalf("缓存命中不应再解析，实际共 %d 次", got)
	}
}

// 持票方失败：等待方带回同一原因（仍属 v5 不可用，调用方照旧回落），连续
// 失败只记一次——并发撞车不把熔断提前打开；失败不入缓存。
func TestV5ResolveInFlightOwnerFailureShared(t *testing.T) {
	v5ResetForTest()

	entered := make(chan struct{}, 4)
	release := make(chan struct{})
	cause := errors.New("pure-go: signature rejected")
	var calls int32
	resolve := func(_ context.Context, _ *sdk.Client, _, _ string) (*model.Playback, model.ContentKey, string, error) {
		atomic.AddInt32(&calls, 1)
		entered <- struct{}{}
		<-release
		return nil, model.ContentKey{}, "", cause
	}

	owner := goV5Resolve(context.Background(), resolve)
	<-entered
	joinerCtx := &waitingCtx{Context: context.Background(), seen: make(chan struct{}, 1)}
	joiner := goV5Resolve(joinerCtx, resolve)
	<-joinerCtx.seen
	close(release)

	for _, r := range []v5Outcome{awaitV5(t, "持票方", owner), awaitV5(t, "等待方", joiner)} {
		if !errors.Is(r.err, ErrV5Unavailable) {
			t.Fatalf("失败应属 v5 不可用: %v", r.err)
		}
		if !strings.Contains(r.err.Error(), cause.Error()) {
			t.Fatalf("应带回持票方的失败原因: %v", r.err)
		}
		if r.pb != nil {
			t.Fatalf("失败不应返回模型: %+v", r.pb)
		}
	}
	if got := atomic.LoadInt32(&calls); got != 1 {
		t.Fatalf("同集并发只应解析一次，实际 %d 次", got)
	}
	v5mu.Lock()
	streak := v5failStreak
	v5mu.Unlock()
	if streak != 1 {
		t.Fatalf("同集并发失败只应记 1 次，实际 %d", streak)
	}

	// 失败不入缓存：之后同集解析自己重新发起。
	again := awaitV5(t, "重试", goV5Resolve(context.Background(), resolve))
	if !errors.Is(again.err, ErrV5Unavailable) {
		t.Fatalf("重试失败应属 v5 不可用: %v", again.err)
	}
	if got := atomic.LoadInt32(&calls); got != 2 {
		t.Fatalf("失败不入缓存，重试应重新解析，实际共 %d 次", got)
	}
}

// 等待期间调用方取消：立即返回 v5 不可用，不再等持票方。
func TestV5ResolveInFlightWaiterHonorsContext(t *testing.T) {
	v5ResetForTest()

	entered := make(chan struct{}, 1)
	release := make(chan struct{})
	// 持票方不随等待方取消：用例结束时才放行，顺便验证等待方确实提前返回。
	defer close(release)
	blocking := func(context.Context, *sdk.Client, string, string) (*model.Playback, model.ContentKey, string, error) {
		entered <- struct{}{}
		<-release
		return nil, model.ContentKey{}, "", errors.New("cancelled-owner")
	}
	go goV5Resolve(context.Background(), blocking)
	<-entered

	base, cancel := context.WithCancel(context.Background())
	joinerCtx := &waitingCtx{Context: base, seen: make(chan struct{}, 1)}
	joiner := goV5Resolve(joinerCtx, blocking)
	<-joinerCtx.seen
	cancel()

	r := awaitV5(t, "等待方", joiner)
	// 原因只进文案（与解析失败同一包装口径），不参与 errors.Is 匹配。
	if !errors.Is(r.err, ErrV5Unavailable) || !strings.Contains(r.err.Error(), context.Canceled.Error()) {
		t.Fatalf("取消后应按 v5 不可用返回并保留原因: %v", r.err)
	}
}

// 熔断打开：不进入解析，直接按 v5 不可用返回并带 breaker-open 标记。
func TestV5ResolveBreakerOpenShortCircuits(t *testing.T) {
	v5ResetForTest()
	v5mu.Lock()
	v5openUntil = time.Now().Add(time.Minute)
	v5mu.Unlock()

	var calls int32
	_, _, _, err := v5Resolve(context.Background(), nil, v5TestProfile, v5TestEpisode,
		func(context.Context, *sdk.Client, string, string) (*model.Playback, model.ContentKey, string, error) {
			atomic.AddInt32(&calls, 1)
			return nil, model.ContentKey{}, "", errors.New("unreachable")
		})
	if !errors.Is(err, ErrV5Unavailable) || !strings.Contains(err.Error(), "breaker-open") {
		t.Fatalf("熔断打开应返回 breaker-open: %v", err)
	}
	if got := atomic.LoadInt32(&calls); got != 0 {
		t.Fatalf("熔断打开不应解析，实际 %d 次", got)
	}
}

// v5JoinFlight 的四条出口：成功共用、持票方失败、超时回退、空结果回退。
// 超时与熔断在降级摘要里可区分——此前三种「不可用」是同一句裸文本，日志
// 无法判断到底是哪一种。
func TestV5JoinFlightOutcomes(t *testing.T) {
	t.Run("success", func(t *testing.T) {
		pb, key, source, _ := fakeV5Model(v5TestEpisode)
		fl := &v5Flight{done: make(chan struct{}), playback: pb, key: key, source: source}
		close(fl.done)
		gotPB, gotKey, gotSource, gotErr := v5JoinFlight(context.Background(), fl, time.Minute)
		if gotErr != nil || gotPB != pb || gotKey != key || gotSource != source {
			t.Fatalf("应原样共用持票方结果: err=%v", gotErr)
		}
	})

	t.Run("owner failure", func(t *testing.T) {
		cause := fmt.Errorf("%w: pure-go: rejected", ErrV5Unavailable)
		fl := &v5Flight{done: make(chan struct{}), err: cause}
		close(fl.done)
		if _, _, _, err := v5JoinFlight(context.Background(), fl, time.Minute); err != cause {
			t.Fatalf("应带回持票方的错误: %v", err)
		}
	})

	t.Run("no result", func(t *testing.T) {
		fl := &v5Flight{done: make(chan struct{})}
		close(fl.done)
		_, _, _, err := v5JoinFlight(context.Background(), fl, time.Minute)
		if !errors.Is(err, ErrV5Unavailable) || !strings.Contains(err.Error(), "in-flight-no-result") {
			t.Fatalf("空结果应按 v5 不可用返回: %v", err)
		}
	})

	t.Run("timeout", func(t *testing.T) {
		fl := &v5Flight{done: make(chan struct{})}
		start := time.Now()
		_, _, _, err := v5JoinFlight(context.Background(), fl, 20*time.Millisecond)
		if !errors.Is(err, ErrV5Unavailable) || !strings.Contains(err.Error(), "in-flight-wait-timeout") {
			t.Fatalf("超时应按 v5 不可用返回: %v", err)
		}
		if elapsed := time.Since(start); elapsed > 5*time.Second {
			t.Fatalf("超时后应立即返回，实际等了 %v", elapsed)
		}
		if note := v5DowngradeNote(err); !strings.Contains(note, "in-flight-wait-timeout") {
			t.Fatalf("降级摘要应保留超时原因: %q", note)
		}
	})
}
