package core

// 漫画：一话的图片清单 + 单页图片解密。
//
// 实测（2026-10-29）：`chapterText` 返回的 JSON 形如
//   {"itemId":…, "encrypt":true,
//    "encrypt_key":"<64 hex>",
//    "picInfos":[{"picUrl":…,"width":1000,"height":1777,"md5":…}],
//    "lowPicInfos":[…]}
// 图片本体是 AES-256-GCM：前 12 字节 nonce、末 16 字节 tag、AAD 为空，
// 解密后是普通 JPEG。密钥是整话共用的一把。

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/beilunyang/openhongguo/sdk"
)

const (
	mangaNonceSize = 12
	mangaTagSize   = 16
	mangaKeySize   = 32
)

type mangaPageOut struct {
	URL    string `json:"url"`
	Width  int    `json:"width"`
	Height int    `json:"height"`
}

type mangaChapterOut struct {
	ItemID string         `json:"item_id"`
	Key    string         `json:"key"`
	Pages  []mangaPageOut `json:"pages"`
}

// chapterPages 取一话的图片清单；正文不是漫画结构时按内容不可用处理。
func chapterPages(ctx context.Context, c *sdk.Client, a []json.RawMessage) (any, error) {
	var itemID string
	if err := arg(a, 0, &itemID); err != nil {
		return nil, err
	}
	raw, err := decryptedChapter(ctx, c, itemID)
	if err != nil {
		return nil, err
	}
	if strings.TrimSpace(raw) == "" {
		return nil, fmt.Errorf("%w: 该话没有图片", sdk.ErrContentUnavailable)
	}
	// width/height 实测有 null 值，按 RawMessage 收再转。
	var env struct {
		ItemID json.RawMessage `json:"itemId"`
		Key    string          `json:"encrypt_key"`
		Pics   []struct {
			URL    string          `json:"picUrl"`
			Width  json.RawMessage `json:"width"`
			Height json.RawMessage `json:"height"`
		} `json:"picInfos"`
	}
	if err := json.Unmarshal([]byte(raw), &env); err != nil {
		head := raw
		if r := []rune(head); len(r) > 80 {
			head = string(r[:80])
		}
		return nil, fmt.Errorf("%w: 该章节不是漫画（head=%q）: %v", sdk.ErrContentUnavailable, head, err)
	}
	out := mangaChapterOut{
		ItemID: rawString(env.ItemID),
		Key:    strings.TrimSpace(env.Key),
		Pages:  make([]mangaPageOut, 0, len(env.Pics)),
	}
	for _, p := range env.Pics {
		url := strings.TrimSpace(p.URL)
		if url == "" {
			continue
		}
		out.Pages = append(out.Pages, mangaPageOut{
			URL:    url,
			Width:  int(rawInt64(p.Width)),
			Height: int(rawInt64(p.Height)),
		})
	}
	if len(out.Pages) == 0 {
		return nil, fmt.Errorf("%w: 该话没有图片", sdk.ErrContentUnavailable)
	}
	return out, nil
}

// fetchMangaPage 下载一页并解密，再按需转码（HEIC → JPEG）。
func fetchMangaPage(ctx context.Context, _ *sdk.Client, a []json.RawMessage) (any, error) {
	var pageURL, keyHex string
	if err := arg(a, 0, &pageURL); err != nil {
		return nil, err
	}
	if err := arg(a, 1, &keyHex); err != nil {
		return nil, err
	}
	if pageURL == "" {
		return nil, fmt.Errorf("%w: 图片地址为空", sdk.ErrParamInvalid)
	}
	data, err := downloadImage(ctx, pageURL)
	if err != nil {
		return nil, err
	}
	if strings.TrimSpace(keyHex) != "" {
		data, err = decryptMangaPage(keyHex, data)
		if err != nil {
			return nil, err
		}
	}
	out, mime, converted, err := convertImage(data)
	if err != nil {
		return nil, fmt.Errorf("%w: fetchMangaPage: %v", sdk.ErrContentUnavailable, err)
	}
	return imageResult{
		Data:      base64.StdEncoding.EncodeToString(out),
		Mime:      mime,
		Converted: converted,
	}, nil
}

// decryptMangaPage 还原一页图片。
func decryptMangaPage(keyHex string, body []byte) ([]byte, error) {
	key, err := hex.DecodeString(strings.TrimSpace(keyHex))
	if err != nil || len(key) != mangaKeySize {
		return nil, fmt.Errorf("%w: 图片密钥必须是 %d 字节 hex", sdk.ErrContentUnavailable, mangaKeySize)
	}
	if len(body) <= mangaNonceSize+mangaTagSize {
		return nil, fmt.Errorf("%w: 图片数据过短", sdk.ErrContentUnavailable)
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", sdk.ErrContentUnavailable, err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", sdk.ErrContentUnavailable, err)
	}
	// gcm.Open 需要 ciphertext‖tag 连续，这里的载荷是 nonce‖ct‖tag。
	sealed := make([]byte, 0, len(body)-mangaNonceSize)
	sealed = append(sealed, body[mangaNonceSize:]...)
	plain, err := gcm.Open(nil, body[:mangaNonceSize], sealed, nil)
	if err != nil {
		return nil, fmt.Errorf("%w: 图片解密失败", sdk.ErrContentUnavailable)
	}
	return plain, nil
}
