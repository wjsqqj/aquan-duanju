package core

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/beilunyang/openhongguo/sdk"
)

// syncHttp：FongMi JS 爬虫的同步 HTTP（Spider 引擎在后台 isolate 里以阻塞
// FFI 调用本方法——阻塞发生在调用方 isolate，Go 侧 goroutine 正常并发）。
//
// 入参 {url, method?, headers?, body?}；出参 {status, headers, bodyB64}。
// body 一律 base64（图片/加密负载友好），调用方自行解码。
type syncHttpOptions struct {
	URL     string            `json:"url"`
	Method  string            `json:"method,omitempty"`
	Headers map[string]string `json:"headers,omitempty"`
	Body    string            `json:"body,omitempty"`
	// TimeoutMs：可选的单请求超时（毫秒）。0 表示用默认 20s。
	//
	// 11-19：搜索期 JS 源走本方法取流，20s 远大于编排器单源预算（5s），
	// 源在结果回来前就被掐断 → 全部误判超时、搜不出内容。搜索期由调用方
	// 传较短超时（如 3000ms）；播放链路不传，保持 20s 默认。
	TimeoutMs int `json:"timeoutMs,omitempty"`
}

func syncHttp(ctx context.Context, a []json.RawMessage) (any, error) {
	if ctx == nil {
		ctx = context.Background()
	}
	var o syncHttpOptions
	if err := arg(a, 0, &o); err != nil {
		return nil, err
	}
	if o.URL == "" {
		return nil, fmt.Errorf("%w: syncHttp: url 为空", sdk.ErrInvalidOptions)
	}
	method := strings.ToUpper(strings.TrimSpace(o.Method))
	if method == "" {
		method = http.MethodGet
	}
	var bodyReader io.Reader
	if o.Body != "" {
		bodyReader = strings.NewReader(o.Body)
	}
	req, err := http.NewRequestWithContext(ctx, method, o.URL, bodyReader)
	if err != nil {
		return nil, fmt.Errorf("%w: syncHttp: %v", sdk.ErrInvalidOptions, err)
	}
	for k, v := range o.Headers {
		req.Header.Set(k, v)
	}
	if req.Header.Get("User-Agent") == "" {
		req.Header.Set("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Gecko/20100101 Firefox/144.0")
	}
	timeout := 20 * time.Second
	if o.TimeoutMs > 0 {
		timeout = time.Duration(o.TimeoutMs) * time.Millisecond
	}
	client := &http.Client{Timeout: timeout}
	res, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("%w: syncHttp: %v", sdk.ErrTransport, err)
	}
	defer res.Body.Close()
	body, err := io.ReadAll(res.Body)
	if err != nil {
		return nil, fmt.Errorf("%w: syncHttp: %v", sdk.ErrTransport, err)
	}
	headers := map[string]string{}
	for k, v := range res.Header {
		if len(v) > 0 {
			headers[k] = v[0]
		}
	}
	return map[string]any{
		"status":  res.StatusCode,
		"headers": headers,
		"bodyB64": base64.StdEncoding.EncodeToString(body),
	}, nil
}
