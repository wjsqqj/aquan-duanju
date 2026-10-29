package core

// 书籍详情与目录：把上游的大 JSON 收成 Dart 真正要用的字段，避免把 28KB/300KB
// 的原始响应整块穿过 FFI。
//
// 字段形态来自实测（bookapi/detail/v 的 data 是扁平的；directory 的章节在
// data.item_data_list[]，volume_name 为空表示不分卷）。

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/beilunyang/openhongguo/sdk"
)

type bookDetailOut struct {
	ID               string `json:"id"`
	Title            string `json:"title"`
	Author           string `json:"author"`
	Abstract         string `json:"abstract"`
	CoverURL         string `json:"cover_url"`
	WordCount        int64  `json:"word_count"`
	ChapterCount     int    `json:"chapter_count"`
	LastChapterTitle string `json:"last_chapter_title"`
	Category         string `json:"category"`
	Score            string `json:"score"`
	ReadCount        int64  `json:"read_count"`
	Finished         bool   `json:"finished"`
}

type bookChapterOut struct {
	ID     string `json:"id"`
	Title  string `json:"title"`
	Volume string `json:"volume"`
	Index  int    `json:"index"`
}

type bookDirectoryOut struct {
	Total    int              `json:"total"`
	Chapters []bookChapterOut `json:"chapters"`
}

// bookDetail 取书籍详情。
func bookDetail(ctx context.Context, c *sdk.Client, a []json.RawMessage) (any, error) {
	var bookID string
	if err := arg(a, 0, &bookID); err != nil {
		return nil, err
	}
	raw, err := c.BookDetailRaw(ctx, bookID)
	if err != nil {
		return nil, err
	}
	// 上游把数值也常写成字符串（serial_count 实测就是 "930"），统一按 RawMessage 收。
	var env struct {
		Data struct {
			BookID           json.RawMessage `json:"book_id"`
			BookName         string          `json:"book_name"`
			Author           string          `json:"author"`
			Abstract         string          `json:"abstract"`
			ThumbURL         string          `json:"thumb_url"`
			WordNumber       json.RawMessage `json:"word_number"`
			SerialCount      json.RawMessage `json:"serial_count"`
			LastChapterTitle string          `json:"last_chapter_title"`
			Category         string          `json:"category"`
			Score            json.RawMessage `json:"score"`
			ReadCount        json.RawMessage `json:"read_count"`
			CreationStatus   json.RawMessage `json:"creation_status"`
		} `json:"data"`
	}
	if err := json.Unmarshal(raw, &env); err != nil {
		return nil, fmt.Errorf("%w: book detail: %v", sdk.ErrTransport, err)
	}
	d := env.Data
	id := rawString(d.BookID)
	if id == "" || strings.TrimSpace(d.BookName) == "" {
		return nil, fmt.Errorf("%w: book detail is empty", sdk.ErrContentUnavailable)
	}
	return bookDetailOut{
		ID:               id,
		Title:            strings.TrimSpace(d.BookName),
		Author:           strings.TrimSpace(d.Author),
		Abstract:         strings.TrimSpace(d.Abstract),
		CoverURL:         d.ThumbURL,
		WordCount:        rawInt64(d.WordNumber),
		ChapterCount:     int(rawInt64(d.SerialCount)),
		LastChapterTitle: strings.TrimSpace(d.LastChapterTitle),
		Category:         strings.TrimSpace(d.Category),
		Score:            rawString(d.Score),
		ReadCount:        rawInt64(d.ReadCount),
		Finished:         rawInt64(d.CreationStatus) == 1,
	}, nil
}

// bookDirectory 取整本目录；不做分页，章节顺序即服务端顺序。
func bookDirectory(ctx context.Context, c *sdk.Client, a []json.RawMessage) (any, error) {
	var bookID string
	if err := arg(a, 0, &bookID); err != nil {
		return nil, err
	}
	raw, err := c.BookDirectoryRaw(ctx, bookID)
	if err != nil {
		return nil, err
	}
	var env struct {
		Data struct {
			Items []struct {
				ItemID     json.RawMessage `json:"item_id"`
				Title      string          `json:"title"`
				VolumeName string          `json:"volume_name"`
			} `json:"item_data_list"`
		} `json:"data"`
	}
	if err := json.Unmarshal(raw, &env); err != nil {
		return nil, fmt.Errorf("%w: book directory: %v", sdk.ErrTransport, err)
	}
	out := bookDirectoryOut{Chapters: make([]bookChapterOut, 0, len(env.Data.Items))}
	for _, it := range env.Data.Items {
		id := strings.Trim(string(it.ItemID), `"`)
		title := strings.TrimSpace(it.Title)
		if id == "" || title == "" {
			continue
		}
		out.Chapters = append(out.Chapters, bookChapterOut{
			ID:     id,
			Title:  title,
			Volume: strings.TrimSpace(it.VolumeName),
			Index:  len(out.Chapters),
		})
	}
	out.Total = len(out.Chapters)
	if out.Total == 0 {
		return nil, fmt.Errorf("%w: book directory is empty", sdk.ErrContentUnavailable)
	}
	return out, nil
}

// rawString 兼容字段既可能是字符串也可能是数字。
func rawString(raw json.RawMessage) string {
	s := strings.TrimSpace(string(raw))
	if s == "" || s == "null" {
		return ""
	}
	return strings.Trim(s, `"`)
}

// rawInt64 兼容 "930" 与 930 两种写法；解析不出来按 0。
func rawInt64(raw json.RawMessage) int64 {
	s := rawString(raw)
	if s == "" {
		return 0
	}
	var n int64
	if _, err := fmt.Sscanf(s, "%d", &n); err != nil {
		return 0
	}
	return n
}
