package core

// 社区帖子：把 `postdata/detail` 的大 JSON 收成「能顺序渲染的块」。
//
// 实测结构（2026-10-29）：
//
//	data: post_id / title / content(字符串形式的 JSON) / create_time / digg_cnt /
//	      reply_cnt / favorite_cnt / user_info / tags / video_detail_list …
//	content.materials[]: {type, data:{text, web_url, datas[].web_url, series_id, title}}
//
// 已知 type：img-list（图片）、tag_topic_mention（话题标签）、series_card_id（剧集卡片）；
// 其余只要有文本就按文本块渲染。

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/beilunyang/openhongguo/sdk"
)

type postBlockOut struct {
	Type     string `json:"type"`
	Text     string `json:"text"`
	URL      string `json:"url"`
	SeriesID string `json:"series_id"`
	Title    string `json:"title"`
}

type postOut struct {
	ID            string         `json:"id"`
	Title         string         `json:"title"`
	Author        string         `json:"author"`
	CreatedAt     int64          `json:"created_at"`
	DiggCount     int64          `json:"digg_count"`
	ReplyCount    int64          `json:"reply_count"`
	FavoriteCount int64          `json:"favorite_count"`
	Tags          []string       `json:"tags"`
	Blocks        []postBlockOut `json:"blocks"`
}

// postDetail 取一条帖子的正文与互动数据。
func postDetail(ctx context.Context, c *sdk.Client, a []json.RawMessage) (any, error) {
	var postID string
	if err := arg(a, 0, &postID); err != nil {
		return nil, err
	}
	raw, err := c.PostDetailRaw(ctx, postID)
	if err != nil {
		return nil, err
	}
	var env struct {
		Data struct {
			PostID     json.RawMessage `json:"post_id"`
			Title      string          `json:"title"`
			Content    string          `json:"content"`
			CreateTime json.RawMessage `json:"create_time"`
			DiggCnt    json.RawMessage `json:"digg_cnt"`
			ReplyCnt   json.RawMessage `json:"reply_cnt"`
			Favorite   json.RawMessage `json:"favorite_cnt"`
			UserInfo   *struct {
				UserName string `json:"user_name"`
				Name     string `json:"name"`
			} `json:"user_info"`
			Tags []struct {
				Name string `json:"name"`
				Text string `json:"text"`
			} `json:"tags"`
		} `json:"data"`
	}
	if err := json.Unmarshal(raw, &env); err != nil {
		return nil, fmt.Errorf("%w: post detail: %v", sdk.ErrTransport, err)
	}
	d := env.Data
	out := postOut{
		ID:            rawString(d.PostID),
		Title:         strings.TrimSpace(d.Title),
		CreatedAt:     rawInt64(d.CreateTime),
		DiggCount:     rawInt64(d.DiggCnt),
		ReplyCount:    rawInt64(d.ReplyCnt),
		FavoriteCount: rawInt64(d.Favorite),
		Blocks:        []postBlockOut{},
	}
	if d.UserInfo != nil {
		if d.UserInfo.UserName != "" {
			out.Author = strings.TrimSpace(d.UserInfo.UserName)
		} else {
			out.Author = strings.TrimSpace(d.UserInfo.Name)
		}
	}
	for _, tag := range d.Tags {
		name := strings.TrimSpace(tag.Name)
		if name == "" {
			name = strings.TrimSpace(tag.Text)
		}
		if name != "" {
			out.Tags = append(out.Tags, name)
		}
	}
	out.Blocks = append(out.Blocks, parsePostBlocks(d.Content)...)
	if out.ID == "" {
		return nil, fmt.Errorf("%w: post detail is empty", sdk.ErrContentUnavailable)
	}
	return out, nil
}

// parsePostBlocks 把 content 里的 materials 摊平成渲染块；content 不是 JSON 时按整段文本处理。
func parsePostBlocks(content string) []postBlockOut {
	content = strings.TrimSpace(content)
	if content == "" {
		return nil
	}
	var parsed struct {
		Materials []struct {
			Type string `json:"type"`
			Data *struct {
				Text     string          `json:"text"`
				WebURL   string          `json:"web_url"`
				Datas    []struct {
					WebURL string `json:"web_url"`
					Width  json.RawMessage
					Height json.RawMessage
				} `json:"datas"`
				SeriesID json.RawMessage `json:"series_id"`
				Title    string          `json:"title"`
			} `json:"data"`
		} `json:"materials"`
	}
	if err := json.Unmarshal([]byte(content), &parsed); err != nil || len(parsed.Materials) == 0 {
		return []postBlockOut{{Type: "text", Text: content}}
	}

	var out []postBlockOut
	for _, m := range parsed.Materials {
		if m.Data == nil {
			continue
		}
		switch {
		case m.Type == "img-list":
			if m.Data.WebURL != "" {
				out = append(out, postBlockOut{Type: "image", URL: m.Data.WebURL})
			}
			for _, img := range m.Data.Datas {
				if img.WebURL == "" {
					continue
				}
				out = append(out, postBlockOut{Type: "image", URL: img.WebURL})
			}
		case m.Type == "series_card_id":
			out = append(out, postBlockOut{
				Type:     "series",
				SeriesID: rawString(m.Data.SeriesID),
				Title:    strings.TrimSpace(m.Data.Title),
				URL:      m.Data.WebURL,
			})
		case strings.HasPrefix(m.Type, "tag_"):
			out = append(out, postBlockOut{Type: "topic", Text: strings.TrimSpace(m.Data.Text)})
		default:
			text := strings.TrimSpace(m.Data.Text)
			if text == "" {
				continue
			}
			out = append(out, postBlockOut{Type: "text", Text: text})
		}
	}
	return out
}
