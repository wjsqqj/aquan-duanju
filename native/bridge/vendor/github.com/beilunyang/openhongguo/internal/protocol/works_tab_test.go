package protocol

import (
	"os"
	"path/filepath"
	"testing"
)

func worksFixture(t *testing.T, name string) []byte {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("testdata", name))
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

// TestParseWorksTabReadsBothLayouts 覆盖两种设备布局：匿名设备拿到的
// 剧作 8 › 全部 100，以及 作品 23 › 剧作 22。
func TestParseWorksTabReadsBothLayouts(t *testing.T) {
	for name, want := range map[string]WorksTab{
		"person-tabs.json":       {Tab: 8, Sub: 100},
		"person-tabs-works.json": {Tab: 23, Sub: 22},
	} {
		got, ok, err := ParseWorksTab(worksFixture(t, name))
		if err != nil || !ok || got != want {
			t.Fatalf("%s: tab = %+v ok %v err %v, want %+v", name, got, ok, err, want)
		}
	}
	if _, ok, err := ParseWorksTab([]byte(`{"code":0,"data":{"tabs":[{"name":"红果圈","tab_type":7,"sub_tabs":[]}]}}`)); err != nil || ok {
		t.Fatalf("a page without 剧作: ok %v err %v", ok, err)
	}
	// tabs 为空时回落到高亮项；字段名是服务端的 hightlight（拼写如此）。
	if got, ok, err := ParseWorksTab([]byte(`{"code":0,"data":{"tabs":[],"hightlight":{"name":"剧作","tab_type":8,"sub_tabs":[{"name":"全部","tab_type":100}]}}}`)); err != nil || !ok || got != (WorksTab{Tab: 8, Sub: 100}) {
		t.Fatalf("hightlight fallback: tab = %+v ok %v err %v", got, ok, err)
	}
	if _, _, err := ParseWorksTab([]byte(`{"code":1001,"data":{}}`)); err == nil {
		t.Fatal("error code accepted")
	}
}

func TestWorksCursorKeepsTab(t *testing.T) {
	token, err := EncodeWorksCursor(WorksCursor{UserID: "7100000000001701", Next: "n1", Tab: &WorksTab{Tab: 23, Sub: 22}})
	if err != nil {
		t.Fatal(err)
	}
	got, err := DecodeWorksCursor(token)
	if err != nil {
		t.Fatal(err)
	}
	if got.UserID != "7100000000001701" || got.Next != "n1" || got.Tab == nil || *got.Tab != (WorksTab{Tab: 23, Sub: 22}) {
		t.Fatalf("cursor = %+v", got)
	}

	// 旧游标没有 tab 字段：解码后 Tab 为 nil，调用方重新探测一次。
	legacy, err := EncodeWorksCursor(WorksCursor{UserID: "7100000000001701", Next: "n2"})
	if err != nil {
		t.Fatal(err)
	}
	got, err = DecodeWorksCursor(legacy)
	if err != nil {
		t.Fatal(err)
	}
	if got.Tab != nil {
		t.Fatalf("legacy cursor tab = %+v, want nil", got.Tab)
	}
}
