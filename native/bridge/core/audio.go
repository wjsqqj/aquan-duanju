package core

// 听书：专辑详情与音轨播放地址。
//
// 播放地址接口的响应里，音轨模型是**嵌在字符串里的 JSON**：
// data.video_model_datas[].video_model → video_list[].main_url（直链 mp4）、
// video_duration（秒）、encrypt_info{encrypt,kid,spade_a}。
// 加密音轨的 CENC 密钥用仓库里已有的 drm.Derive 还原。

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/beilunyang/openhongguo/sdk"
)

type audioAlbumOut struct {
	ID        string `json:"id"`
	Title     string `json:"title"`
	Author    string `json:"author"`
	Abstract  string `json:"abstract"`
	CoverURL  string `json:"cover_url"`
	ItemCount int    `json:"item_count"`
}

type audioPlayOut struct {
	URL        string `json:"url"`
	BackupURL  string `json:"backup_url"`
	KeyHex     string `json:"key"`
	DurationMs int64  `json:"duration_ms"`
	Encrypted  bool   `json:"encrypted"`
}

// audioAlbum 取专辑详情。
func audioAlbum(ctx context.Context, c *sdk.Client, a []json.RawMessage) (any, error) {
	var bookID string
	if err := arg(a, 0, &bookID); err != nil {
		return nil, err
	}
	raw, err := c.AudioDetailRaw(ctx, bookID)
	if err != nil {
		return nil, err
	}
	var env struct {
		Data struct {
			BookID     json.RawMessage `json:"book_id"`
			BookName   string          `json:"book_name"`
			Title      string          `json:"title"`
			Author     string          `json:"author"`
			Abstract   string          `json:"abstract"`
			ThumbURL   string          `json:"thumb_url"`
			ItemCount  json.RawMessage `json:"item_count"`
			SerialCnt  json.RawMessage `json:"serial_count"`
			TotalCount json.RawMessage `json:"total_item_count"`
		} `json:"data"`
	}
	if err := json.Unmarshal(raw, &env); err != nil {
		return nil, fmt.Errorf("%w: audio detail: %v", sdk.ErrTransport, err)
	}
	d := env.Data
	id := rawString(d.BookID)
	if id == "" {
		id = bookID
	}
	title := strings.TrimSpace(d.BookName)
	if title == "" {
		title = strings.TrimSpace(d.Title)
	}
	count := rawInt64(d.ItemCount)
	if count == 0 {
		count = rawInt64(d.SerialCnt)
	}
	if count == 0 {
		count = rawInt64(d.TotalCount)
	}
	if id == "" {
		return nil, fmt.Errorf("%w: audio detail is empty", sdk.ErrContentUnavailable)
	}
	return audioAlbumOut{
		ID:        id,
		Title:     title,
		Author:    strings.TrimSpace(d.Author),
		Abstract:  strings.TrimSpace(d.Abstract),
		CoverURL:  d.ThumbURL,
		ItemCount: int(count),
	}, nil
}

// audioPlay 取音轨播放地址与（若有）内容密钥。
func audioPlay(ctx context.Context, c *sdk.Client, a []json.RawMessage) (any, error) {
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
	itemID = strings.TrimSpace(itemID)
	if itemID == "" {
		return nil, fmt.Errorf("%w: empty audio item id", sdk.ErrInvalidOptions)
	}
	raw, err := c.AudioPlayRaw(ctx, bookID, []string{itemID}, toneID)
	if err != nil {
		return nil, err
	}
	// 上游封套有两层写法（data / video_info.data），都试一遍。
	var env struct {
		Data      *audioPlayPayload `json:"data"`
		VideoInfo *struct {
			Data *audioPlayPayload `json:"data"`
		} `json:"video_info"`
	}
	if err := json.Unmarshal(raw, &env); err != nil {
		return nil, fmt.Errorf("%w: audio play: %v", sdk.ErrTransport, err)
	}
	payload := env.Data
	if payload == nil && env.VideoInfo != nil {
		payload = env.VideoInfo.Data
	}
	if payload == nil || len(payload.Datas) == 0 {
		return nil, fmt.Errorf("%w: audio play returned no track", sdk.ErrContentUnavailable)
	}
	model, err := parseVideoModel(payload.Datas[0].VideoModel)
	if err != nil {
		return nil, err
	}
	return model, nil
}

type audioPlayPayload struct {
	Datas []struct {
		VideoModel string `json:"video_model"`
	} `json:"video_model_datas"`
}

// parseVideoModel 解出音轨里的直链、时长与密钥。
func parseVideoModel(raw string) (audioPlayOut, error) {
	if strings.TrimSpace(raw) == "" {
		return audioPlayOut{}, fmt.Errorf("%w: audio track model is empty", sdk.ErrContentUnavailable)
	}
	var model struct {
		VideoList []struct {
			MainURL   string `json:"main_url"`
			BackupURL string `json:"backup_url"`
		} `json:"video_list"`
		Duration  json.RawMessage `json:"video_duration"`
		EncryptIt *struct {
			Encrypt bool             `json:"encrypt"`
			SpadeA  string          `json:"spade_a"`
			Method  json.RawMessage `json:"encryption_method"`
		} `json:"encrypt_info"`
	}
	if err := json.Unmarshal([]byte(raw), &model); err != nil {
		return audioPlayOut{}, fmt.Errorf("%w: audio track model: %v", sdk.ErrContentUnavailable, err)
	}
	if len(model.VideoList) == 0 {
		return audioPlayOut{}, fmt.Errorf("%w: audio track has no stream", sdk.ErrContentUnavailable)
	}
	out := audioPlayOut{
		URL:        model.VideoList[0].MainURL,
		BackupURL:  model.VideoList[0].BackupURL,
		DurationMs: rawInt64(model.Duration) * 1000,
	}
	if model.EncryptIt != nil && model.EncryptIt.Encrypt {
		// 取不到密钥时仍然给直链，由播放器决定是否可播。
		if key, ok := sdk.DeriveAudioKey(model.EncryptIt.SpadeA); ok {
			out.KeyHex = key
			out.Encrypted = true
		}
	}
	if out.URL == "" {
		return audioPlayOut{}, fmt.Errorf("%w: audio track has no url", sdk.ErrContentUnavailable)
	}
	return out, nil
}
