package core

// 听书（智能朗读）：音色表 + 音轨播放地址 + CENC 内容密钥。

import (
	"context"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"

	"github.com/beilunyang/openhongguo/sdk"
)

type audioToneOut struct {
	ID    int    `json:"id"`
	Title string `json:"title"`
	Icon  string `json:"icon"`
}

type audioTonesOut struct {
	BookID       string         `json:"book_id"`
	RelateBookID string         `json:"relate_book_id"`
	GenreType    int            `json:"genre_type"`
	Tones        []audioToneOut `json:"tones"`
}

type audioTrackOut struct {
	URL        string `json:"url"`
	BackupURL  string `json:"backup_url"`
	KeyHex     string `json:"key"`
	DurationMs int64  `json:"duration_ms"`
	Encrypted  bool   `json:"encrypted"`
}

// audioTones 取音色表：智能朗读（tts_tones）与真人讲书（audio_tones）。
func audioTones(ctx context.Context, c *sdk.Client, a []json.RawMessage) (any, error) {
	var bookID string
	if err := arg(a, 0, &bookID); err != nil {
		return nil, err
	}
	raw, err := c.AudioTonesRaw(ctx, bookID)
	if err != nil {
		return nil, err
	}
	var env struct {
		Data struct {
			RelateBookID json.RawMessage `json:"relate_novel_bookid"`
			GenreType    int             `json:"req_book_genre_type"`
			TTSTones     []struct {
				ID    int    `json:"id"`
				Title string `json:"title"`
				Icon  string `json:"icon_url"`
			} `json:"tts_tones"`
			AudioTones []struct {
				ID    json.RawMessage `json:"id"`
				Title string          `json:"title"`
				Icon  string          `json:"icon_url"`
			} `json:"audio_tones"`
		} `json:"data"`
	}
	if err := json.Unmarshal(raw, &env); err != nil {
		return nil, fmt.Errorf("%w: audio tones: %v", sdk.ErrTransport, err)
	}
	d := env.Data
	out := audioTonesOut{
		BookID:       bookID,
		RelateBookID: rawString(d.RelateBookID),
		GenreType:    d.GenreType,
		Tones:        []audioToneOut{},
	}
	for _, t := range d.TTSTones {
		out.Tones = append(out.Tones, audioToneOut{ID: t.ID, Title: t.Title, Icon: t.Icon})
	}
	for _, t := range d.AudioTones {
		id := int(rawInt64(t.ID))
		if id == 0 {
			continue
		}
		out.Tones = append(out.Tones, audioToneOut{ID: id, Title: t.Title, Icon: t.Icon})
	}
	if len(out.Tones) == 0 {
		return nil, fmt.Errorf("%w: 该书没有可用音色", sdk.ErrContentUnavailable)
	}
	return out, nil
}

// audioPlay 取音轨播放地址；加密流同时给出 CENC 内容密钥。
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
	raw, err := c.AudioPlayInfoRaw(ctx, bookID, itemID, toneID)
	if err != nil {
		return nil, err
	}
	var env struct {
		Data []struct {
			MainURL   string `json:"main_url"`
			BackupURL string `json:"backup_url"`
			Duration  json.RawMessage `json:"duration"`
			IsEncrypt bool            `json:"is_encrypt"`
			// 实测：音轨直接给 base64 的 16 字节内容密钥（不是 spade_a）。
			EncryptionKey string `json:"encryption_key"`
			EncryptInfo   *struct {
				Encrypt bool   `json:"encrypt"`
				SpadeA  string `json:"spade_a"`
			} `json:"encrypt_info"`
		} `json:"data"`
	}
	if err := json.Unmarshal(raw, &env); err != nil {
		return nil, fmt.Errorf("%w: audio play: %v", sdk.ErrTransport, err)
	}
	for _, item := range env.Data {
		if item.MainURL == "" {
			continue
		}
		encrypted := item.IsEncrypt
		key := ""
		if item.EncryptionKey != "" {
			// base64 的 16 字节密钥，转成 hex 交给 mpv 的 decryption_key。
			if raw, err := base64.StdEncoding.DecodeString(item.EncryptionKey); err == nil && len(raw) > 0 {
				key = hex.EncodeToString(raw)
				encrypted = true
			}
		}
		if item.EncryptInfo != nil {
			if item.EncryptInfo.Encrypt {
				encrypted = true
			}
			if key == "" {
				if k, ok := sdk.DeriveAudioKey(item.EncryptInfo.SpadeA); ok {
					key = k
				}
			}
		}
		return audioTrackOut{
			URL:        item.MainURL,
			BackupURL:  item.BackupURL,
			KeyHex:     key,
			DurationMs: rawInt64(item.Duration),
			Encrypted:  encrypted,
		}, nil
	}
	return nil, fmt.Errorf("%w: 该章节没有可用音频", sdk.ErrContentUnavailable)
}