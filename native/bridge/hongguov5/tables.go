package hongguov5

import (
	"embed"
	"fmt"
)

// medusa_wire_tables.json 单一事实源（原 sidecar v5wire.py 引用同一文件，
// 现移入本包，Python 侧反向引用 ../hongguov5/ 路径）。
//
//go:embed medusa_wire_tables.json
var tablesFS embed.FS

func embeddedTables() ([]byte, error) {
	raw, err := tablesFS.ReadFile("medusa_wire_tables.json")
	if err != nil {
		return nil, fmt.Errorf("tables: %w", err)
	}
	return raw, nil
}
