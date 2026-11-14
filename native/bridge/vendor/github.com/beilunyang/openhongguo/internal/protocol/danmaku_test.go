package protocol

import (
	"encoding/base64"
	"encoding/json"
	"testing"
	"time"
)

// 一窗响应的内联样本：乱序两行 + 空白文本一行（应跳过），游标带窗口边界。
const danmakuWindowFixture = `{
  "code": 0,
  "message": "请求成功",
  "data": {
    "common_list_info": {
      "cursor": "{\"start_offset_time\":0,\"end_offset_time\":30000}",
      "has_more": true
    },
    "data_list": [
      {
        "data_type": 4,
        "comment": {
          "comment_id": "7100000000002102",
          "common": {"content": {"text": "Fixture danmaku two"}, "create_timestamp": 1787839400},
          "expand": {"offset_time": 12500},
          "stat": {"digg_count": 0, "add_one_count": 2}
        }
      },
      {
        "data_type": 4,
        "comment": {
          "comment_id": "7100000000002101",
          "common": {"content": {"text": "Fixture danmaku one"}, "create_timestamp": 1787839345},
          "expand": {"offset_time": 329},
          "stat": {"digg_count": 15, "add_one_count": 7}
        }
      },
      {
        "data_type": 4,
        "comment": {
          "comment_id": "7100000000002103",
          "common": {"content": {"text": "  "}, "create_timestamp": 1787839500},
          "expand": {"offset_time": 20000},
          "stat": {"digg_count": 0, "add_one_count": 0}
        }
      }
    ],
    "extra": {"next_query_danmaku_list_time": 30000}
  }
}`

func TestParseDanmakuReadsWindow(t *testing.T) {
	res, err := ParseDanmaku([]byte(danmakuWindowFixture))
	if err != nil {
		t.Fatal(err)
	}
	// 空白行跳过，其余按播放时间排序。
	if len(res.Items) != 2 {
		t.Fatalf("items = %+v", res.Items)
	}
	first, second := res.Items[0], res.Items[1]
	if first.ID != "7100000000002101" || first.Text != "Fixture danmaku one" || first.OffsetMS != 329 ||
		first.Likes != 15 || first.PlusOnes != 7 || !first.CreatedAt.Equal(time.Unix(1787839345, 0)) {
		t.Fatalf("first = %+v", first)
	}
	if second.OffsetMS != 12500 || second.Text != "Fixture danmaku two" {
		t.Fatalf("second = %+v", second)
	}
	if res.Start != 0 || res.End != 30000 || res.Total != 0 || !res.HasMore || res.Next != 30000 {
		t.Fatalf("window = %+v", res)
	}
	var cur map[string]any
	if err := json.Unmarshal([]byte(res.Cursor), &cur); err != nil || cur["end_offset_time"] != float64(30000) {
		t.Fatalf("cursor = %q", res.Cursor)
	}
}

func TestParseDanmakuReadsTotalFromCursor(t *testing.T) {
	// 有些设备把总数与每窗条数放进游标 JSON。
	raw := `{"code":0,"data":{"data_list":[],"common_list_info":{"has_more":true,
		"cursor":"{\"start_offset_time\":30001,\"end_offset_time\":60000,\"danmaku_window_count\":{\"0\":53},\"danmaku_count\":8093,\"session_id\":\"S\"}"},
		"extra":{"next_query_danmaku_list_time":60000}}}`
	res, err := ParseDanmaku([]byte(raw))
	if err != nil {
		t.Fatal(err)
	}
	if res.Start != 30001 || res.End != 60000 || res.Total != 8093 || res.Next != 60000 || len(res.Items) != 0 {
		t.Fatalf("res = %+v", res)
	}
}

func TestParseDanmakuSkipsRowsWithoutTime(t *testing.T) {
	raw := `{"code":0,"data":{"data_list":[{"comment":{"comment_id":"1","common":{"content":{"text":"no time"}}}},{"data_type":9}],
		"common_list_info":{"cursor":"not json","has_more":false},"extra":{}}}`
	res, err := ParseDanmaku([]byte(raw))
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Items) != 0 || res.HasMore || res.Total != 0 || res.Cursor != "not json" {
		t.Fatalf("res = %+v", res)
	}
	if _, err := ParseDanmaku([]byte(`{"code":103001,"data":{}}`)); err == nil {
		t.Fatal("error code accepted")
	}
}

func TestDanmakuBodyMatchesPlayer(t *testing.T) {
	raw, err := DanmakuBody("7100000000000101", "7100000000000201", 30000, 91000, 0, `{"session_id":"x"}`)
	if err != nil {
		t.Fatal(err)
	}
	var b struct {
		AID           int    `json:"aid"`
		CommentSource int    `json:"comment_source"`
		ServerChannel int    `json:"server_channel"`
		CommentType   int    `json:"comment_type"`
		GroupID       string `json:"group_id"`
		GroupType     int    `json:"group_type"`
		Count         int    `json:"count"`
		Cursor        string `json:"cursor"`
		Param         struct {
			BookID   string `json:"book_id"`
			Start    int64  `json:"start_offset_time"`
			Duration int64  `json:"playlet_item_duration"`
		} `json:"business_param"`
	}
	if err := json.Unmarshal(raw, &b); err != nil {
		t.Fatal(err)
	}
	if b.AID != 8662 || b.CommentSource != 601 || b.ServerChannel != 1000 || b.CommentType != 20 || b.GroupType != 30 ||
		b.GroupID != "7100000000000201" || b.Count != DanmakuPageSize || b.Cursor != `{"session_id":"x"}` {
		t.Fatalf("body = %s", raw)
	}
	// 时长缺省：给一小时的兜底，保证能翻到头。
	raw2, err := DanmakuBody("s", "e", 0, 0, 5, "")
	if err != nil {
		t.Fatal(err)
	}
	var b2 struct {
		Count         int   `json:"count"`
		Param         struct{ Duration int64 `json:"playlet_item_duration"` } `json:"business_param"`
	}
	if err := json.Unmarshal(raw2, &b2); err != nil {
		t.Fatal(err)
	}
	if b2.Count != 5 || b2.Param.Duration != DanmakuFallbackDuration {
		t.Fatalf("body2 = %s", raw2)
	}
}

func TestDanmakuCursorRoundtrip(t *testing.T) {
	token, err := EncodeDanmakuCursor(DanmakuCursor{EpisodeID: "7100000000000201", Duration: 91000, Start: 30000, Next: `{"session_id":"x"}`})
	if err != nil {
		t.Fatal(err)
	}
	cur, err := DecodeDanmakuCursor(token)
	if err != nil {
		t.Fatal(err)
	}
	if cur.EpisodeID != "7100000000000201" || cur.Duration != 91000 || cur.Start != 30000 || cur.Next != `{"session_id":"x"}` {
		t.Fatalf("cur = %+v", cur)
	}
	if empty, err := DecodeDanmakuCursor(""); err != nil || empty.EpisodeID != "" {
		t.Fatalf("empty = %+v %v", empty, err)
	}
	for _, bad := range []string{"m2.abc", "m1.!!!", "m1." + base64.RawURLEncoding.EncodeToString([]byte(`{"e":0,"d":91000,"t":30000}`))} {
		if _, err := DecodeDanmakuCursor(bad); err == nil {
			t.Fatalf("bad cursor accepted: %q", bad)
		}
	}
}
