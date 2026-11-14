// 弹幕协议：请求体、一窗解析、翻页游标。移植自上游 openhongguo v0.3.0
//（internal/protocol/danmaku.go），行为语义保持一致。
package protocol

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/beilunyang/openhongguo/sdk/model"
)

// DanmakuPageSize 是官方播放器一次窗口请求的条数。
const DanmakuPageSize = 90

// DanmakuFallbackDuration 替代拿不到时长的分集（一小时，保证能翻到头）。
const DanmakuFallbackDuration = 60 * 60 * 1000

// DanmakuBody 按起点 startMS（播放时间毫秒）请求一集弹幕。
// comment_type 20 + comment_source 601 + server_channel 1000 选中的是
// 定时弹幕列表（2026-11-11 实测）。
//
// durationMS 是分集时长，作为 playlet_item_duration 下发：服务端按它划
// 固定窗口，有的设备会自己跳过片尾空窗，有的不会（2026-11-11：135s 的
// 一集配一小时时长，会一直翻到空的 30s 窗），所以要给真实时长。
// cursor 是上一窗返回的服务端游标字符串；空即第一窗。
func DanmakuBody(seriesID, episodeID string, startMS, durationMS int64, count int, cursor string) ([]byte, error) {
	if count <= 0 {
		count = DanmakuPageSize
	}
	if durationMS <= 0 {
		durationMS = DanmakuFallbackDuration
	}
	return jsonMarshal(map[string]any{
		"aid":               json.Number(AID),
		"comment_source":    601,
		"server_channel":    1000,
		"comment_type":      20,
		"compliance_status": 0,
		"count":             count,
		"cursor":            cursor,
		"group_id":          episodeID,
		"group_type":        30,
		"sort":              1,
		"business_param": map[string]any{
			"book_id":                 seriesID,
			"start_offset_time":       startMS,
			"playlet_item_duration":   durationMS,
			"need_danmaku_guide_type": []int{1, 3, 4, 2},
		},
	})
}

// DanmakuResult 是一集弹幕的一个窗口。
type DanmakuResult struct {
	// Items 按播放时间排序。
	Items []model.Danmaku
	// Start / End 是窗口边界（播放时间毫秒）。
	Start, End int64
	// Total 是服务端统计的本集弹幕总数；它只下发其中一部分。
	Total int64
	// HasMore 表示还有下一窗。Next 是下一窗起点，Cursor 是要原样带回的
	// 服务端游标字符串。
	HasMore bool
	Next    int64
	Cursor  string
}

// ParseDanmaku 解析一窗弹幕响应。没有文本或播放时间的行跳过；
// 不读发送者身份。
func ParseDanmaku(raw []byte) (*DanmakuResult, error) {
	var env struct {
		Code flexString `json:"code"`
		Data struct {
			List []struct {
				Comment *struct {
					ID     flexString `json:"comment_id"`
					Common struct {
						Content struct {
							Text string `json:"text"`
						} `json:"content"`
						Created flexInt64 `json:"create_timestamp"`
					} `json:"common"`
					Expand struct {
						Offset *flexInt64 `json:"offset_time"`
					} `json:"expand"`
					Stat struct {
						Diggs    flexInt64 `json:"digg_count"`
						PlusOnes flexInt64 `json:"add_one_count"`
					} `json:"stat"`
				} `json:"comment"`
			} `json:"data_list"`
			Info struct {
				Cursor  string `json:"cursor"`
				HasMore bool   `json:"has_more"`
			} `json:"common_list_info"`
			Extra struct {
				Next flexInt64 `json:"next_query_danmaku_list_time"`
			} `json:"extra"`
		} `json:"data"`
	}
	if err := json.Unmarshal(raw, &env); err != nil {
		return nil, err
	}
	if env.Code.String() != "" && env.Code.String() != "0" {
		return nil, fmt.Errorf("danmaku code %s", env.Code.String())
	}
	out := &DanmakuResult{
		Items:   []model.Danmaku{},
		HasMore: env.Data.Info.HasMore,
		Next:    int64(env.Data.Extra.Next),
		Cursor:  env.Data.Info.Cursor,
	}
	// 服务端游标本身是一段 JSON，顺带描述了这一窗的边界与总数。
	var window struct {
		Start flexInt64 `json:"start_offset_time"`
		End   flexInt64 `json:"end_offset_time"`
		Total flexInt64 `json:"danmaku_count"`
	}
	if json.Unmarshal([]byte(out.Cursor), &window) == nil {
		out.Start, out.End, out.Total = int64(window.Start), int64(window.End), int64(window.Total)
	}
	for _, row := range env.Data.List {
		c := row.Comment
		if c == nil || c.Expand.Offset == nil || *c.Expand.Offset < 0 {
			continue
		}
		text := strings.TrimSpace(c.Common.Content.Text)
		if text == "" {
			continue
		}
		d := model.Danmaku{
			ID: c.ID.String(), Text: text, OffsetMS: int64(*c.Expand.Offset),
			Likes: int64(c.Stat.Diggs), PlusOnes: int64(c.Stat.PlusOnes),
		}
		if c.Common.Created > 0 {
			d.CreatedAt = time.Unix(int64(c.Common.Created), 0).UTC()
		}
		out.Items = append(out.Items, d)
	}
	sort.SliceStable(out.Items, func(i, j int) bool { return out.Items[i].OffsetMS < out.Items[j].OffsetMS })
	return out, nil
}

// DanmakuCursor 是一集弹幕的翻页游标：分集与时长、下一窗起点、服务端
// 游标字符串。
type DanmakuCursor struct {
	EpisodeID string `json:"e"`
	Duration  int64  `json:"d"`
	Start     int64  `json:"t"`
	Next      string `json:"n,omitempty"`
}

// EncodeDanmakuCursor 把游标打包成不透明 token。
func EncodeDanmakuCursor(c DanmakuCursor) (string, error) {
	raw, err := json.Marshal(c)
	if err != nil {
		return "", err
	}
	return "m1." + base64.RawURLEncoding.EncodeToString(raw), nil
}

// DecodeDanmakuCursor 解开 EncodeDanmakuCursor 的 token。空 token 即第一窗。
func DecodeDanmakuCursor(token string) (DanmakuCursor, error) {
	if token == "" {
		return DanmakuCursor{}, nil
	}
	bad := fmt.Errorf("danmaku cursor is not valid")
	payload, ok := strings.CutPrefix(token, "m1.")
	if !ok {
		return DanmakuCursor{}, bad
	}
	raw, err := base64.RawURLEncoding.DecodeString(payload)
	if err != nil {
		return DanmakuCursor{}, bad
	}
	var c DanmakuCursor
	if err := json.Unmarshal(raw, &c); err != nil || !digits(c.EpisodeID) || c.Start <= 0 || c.Duration <= 0 {
		return DanmakuCursor{}, bad
	}
	return c, nil
}
