package sdk

// UGC 帖子详情的传输层。
//
// host 与路径来自 fqapp `rust/src/endpoints/book.rs:214-215,232-282`；参数用
// 本设备家族（与书籍接口一致）。

import (
	"context"

	"github.com/beilunyang/openhongguo/internal/protocol"
	"github.com/beilunyang/openhongguo/internal/protocol/sign"
)

const (
	// PostDetailHost 是 UGC 域名（与 apiOrigin 不同）。
	PostDetailHost = "https://api3-normal-sinfonlinea.fqnovel.com"
	// PathPostDetail 是单条帖子详情。
	PathPostDetail = "/reading/ugc/postdata/detail/v"
)

// PostDetailRaw 返回帖子详情的原始 JSON。
func (c *Client) PostDetailRaw(ctx context.Context, postID string) ([]byte, error) {
	if !validID(postID) {
		return nil, ErrInvalidOptions
	}
	p, err := c.ensureSearchGuest(ctx)
	if err != nil {
		return nil, err
	}
	pairs := append(protocol.DeviceQueryPairs(c.identity(p)),
		[2]string{"post_id", postID},
		[2]string{"relative_id", "0"},
		[2]string{"source_type", "16"},
		[2]string{"relative_type", "5"},
	)
	ticket := c.clock().UnixMilli()
	signed, headers := sign.SignPOST(PathPostDetail, pairs, ticket, p.DeviceID, protocol.VersionName, nil, nil)
	headers = anonymousHeaders(c, p, ticket, headers)
	raw, _, err := c.doRaw(ctx, "GET", PostDetailHost+PathPostDetail+"?"+signed, headers, nil)
	if err != nil {
		return nil, err
	}
	return raw, nil
}
