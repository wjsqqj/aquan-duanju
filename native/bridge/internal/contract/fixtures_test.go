package contract

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/beilunyang/openhongguo/sdk"
)

func fixturePaths(t *testing.T) []string {
	t.Helper()
	paths, err := filepath.Glob(filepath.Join("testdata", "protocol", "*.json"))
	if err != nil {
		t.Fatal(err)
	}
	if len(paths) == 0 {
		t.Fatal("no fixtures under testdata/protocol")
	}
	return paths
}

// TestEveryFixtureHasShape 保证每份夹具都能被解析成字段形状：
// 夹具损坏或字段被清空时，契约基线会立刻失效。
func TestEveryFixtureHasShape(t *testing.T) {
	paths := fixturePaths(t)
	if len(paths) < 20 {
		t.Fatalf("fixtures = %d, want the full 29-file snapshot", len(paths))
	}
	for _, path := range paths {
		raw, err := os.ReadFile(path)
		if err != nil {
			t.Fatalf("%s: %v", path, err)
		}
		fields, err := Shape(raw)
		if err != nil {
			t.Fatalf("%s: shape: %v", filepath.Base(path), err)
		}
		if len(fields) == 0 {
			t.Fatalf("%s: empty shape", filepath.Base(path))
		}
	}
}

// TestPlaybackFixturesParse 用项目自己的解析器回放播放夹具：
// 改动 ParsePlayback 时，这里会先报错，而不是等线上「播不了」。
func TestPlaybackFixturesParse(t *testing.T) {
	for _, name := range []string{"clear-playback.json", "drm-playback.json", "dynamic-playback.json"} {
		raw, err := os.ReadFile(filepath.Join("testdata", "protocol", name))
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		pb, err := sdk.ParsePlaybackJSON(raw, "7100000000000001")
		if pb == nil {
			t.Fatalf("%s: no playback model (%v)", name, err)
		}
		if len(pb.Streams) == 0 {
			t.Fatalf("%s: no streams", name)
		}
		if name == "drm-playback.json" && !pb.Protected {
			t.Fatalf("%s: protected flag lost", name)
		}
	}
}
