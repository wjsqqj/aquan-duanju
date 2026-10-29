package sdk

// 书籍详情与目录的传输层。参数照旧用**本设备家族**（DeviceQueryPairs +
// apiOrigin）：fqapp 里那套 novelapp 固定参数配 hongguo 设备会得到 200 空响应。

import (
	"context"

	"github.com/beilunyang/openhongguo/internal/protocol"
	"github.com/beilunyang/openhongguo/internal/protocol/sign"
)

const (
	// PathBookDetail 是书籍详情。
	PathBookDetail = "/reading/bookapi/detail/v"
	// PathBookDirectory 是完整章节目录（不分页）。
	PathBookDirectory = "/reading/bookapi/directory/all_items/v"
)

// BookDetailRaw 返回详情接口的原始 JSON。
func (c *Client) BookDetailRaw(ctx context.Context, bookID string) ([]byte, error) {
	if !validID(bookID) {
		return nil, ErrInvalidOptions
	}
	p, err := c.ensureSearchGuest(ctx)
	if err != nil {
		return nil, err
	}
	pairs := append(protocol.DeviceQueryPairs(c.identity(p)), [2]string{"book_id", bookID})
	ticket := c.clock().UnixMilli()
	signed, headers := sign.SignPOST(PathBookDetail, pairs, ticket, p.DeviceID, protocol.VersionName, nil, nil)
	headers = anonymousHeaders(c, p, ticket, headers)
	raw, _, err := c.doRaw(ctx, "GET", c.apiOrigin+PathBookDetail+"?"+signed, headers, nil)
	if err != nil {
		return nil, err
	}
	return raw, nil
}

// BookDirectoryRaw 返回目录接口的原始 JSON（整本，可能上千章）。
func (c *Client) BookDirectoryRaw(ctx context.Context, bookID string) ([]byte, error) {
	if !validID(bookID) {
		return nil, ErrInvalidOptions
	}
	p, err := c.ensureSearchGuest(ctx)
	if err != nil {
		return nil, err
	}
	pairs := append(protocol.DeviceQueryPairs(c.identity(p)),
		[2]string{"book_type", "0"},
		[2]string{"book_id", bookID},
		[2]string{"need_version", "true"},
	)
	ticket := c.clock().UnixMilli()
	signed, headers := sign.SignPOST(PathBookDirectory, pairs, ticket, p.DeviceID, protocol.VersionName, nil, nil)
	headers = anonymousHeaders(c, p, ticket, headers)
	raw, _, err := c.doRaw(ctx, "GET", c.apiOrigin+PathBookDirectory+"?"+signed, headers, nil)
	if err != nil {
		return nil, err
	}
	return raw, nil
}
