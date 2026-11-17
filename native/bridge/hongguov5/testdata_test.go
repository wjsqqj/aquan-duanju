package hongguov5

import (
	"embed"
	"testing"
)

//go:embed testdata/golden.json
var testdataFS embed.FS

var _ = testing.Short
