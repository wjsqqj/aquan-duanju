package hongguov5

// compress.go — zlib/gzip 助手（python zlib.compress / gzip.compress 对应物）。

import (
	"bytes"
	"compress/zlib"
	"fmt"
	"io"
	"math"
)

// zlibCompress 默认级压缩（python zlib.compress(plaintext)）。
func zlibCompress(data []byte) ([]byte, error) {
	var buf bytes.Buffer
	zw, err := zlib.NewWriterLevel(&buf, zlib.DefaultCompression)
	if err != nil {
		return nil, err
	}
	if _, err := zw.Write(data); err != nil {
		return nil, err
	}
	if err := zw.Close(); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

func zlibDecompress(data []byte, limit int) ([]byte, error) {
	zr, err := zlib.NewReader(bytes.NewReader(data))
	if err != nil {
		return nil, fmt.Errorf("%w: compression-invalid", errSession)
	}
	defer zr.Close()
	out := make([]byte, 0, limit+1)
	chunk := make([]byte, 4096)
	for {
		n, err := zr.Read(chunk)
		out = append(out, chunk[:n]...)
		if len(out) > limit {
			return nil, fmt.Errorf("%w: response-too-large", errSession)
		}
		if err != nil {
			if err == io.EOF {
				break
			}
			return nil, fmt.Errorf("%w: compression-invalid", errSession)
		}
	}
	return out, nil
}

func float32frombits(bits uint32) float32 {
	return math.Float32frombits(bits)
}
