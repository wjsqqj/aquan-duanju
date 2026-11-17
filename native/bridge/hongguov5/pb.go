package hongguov5

// pb.go — 严格有界 protobuf 线材编解码（移植自 v5wire.pb_*；写入序即字节序）。
// 空字符串/空字节按上游惯例省略；保留重复字段与原始 wire type。

import (
	"errors"
	"math"
)

var errPB = errors.New("hongguov5: protobuf wire")

// PBField 编码输入：int64 走 varint（含 zigzag 后的值）、Float32 走 fixed32、
// Str/Bytes 走 LEN。
type PBField struct {
	Number  int
	Int     int64
	Float32 float32
	Str     string
	Bytes   []byte
	Kind    PBKind
}

type PBKind int

const (
	PBInt PBKind = iota
	PBFloat32
	PBStr
	PBBytes
)

func pbInt(number int, value int64) PBField {
	return PBField{Number: number, Kind: PBInt, Int: value}
}

func pbFloat(number int, value float32) PBField {
	return PBField{Number: number, Kind: PBFloat32, Float32: value}
}

func pbStr(number int, value string) PBField {
	return PBField{Number: number, Kind: PBStr, Str: value}
}

func pbBytes(number int, value []byte) PBField {
	return PBField{Number: number, Kind: PBBytes, Bytes: value}
}

func pbVarint(value uint64) []byte {
	out := make([]byte, 0, 10)
	for value > 127 {
		out = append(out, byte(value&127)|128)
		value >>= 7
	}
	return append(out, byte(value))
}

// pbEncode 按调用方给出的字段顺序编码（顺序即线材字节序，不得重排）。
func pbEncode(fields []PBField) []byte {
	var out []byte
	for _, f := range fields {
		switch f.Kind {
		case PBInt:
			out = append(out, pbVarint(uint64(f.Number)<<3)...)
			out = append(out, pbVarint(uint64(f.Int))...)
		case PBFloat32:
			out = append(out, pbVarint(uint64(f.Number)<<3|5)...)
			out = append(out, float32BitsLE(f.Float32)...)
		default:
			value := f.Bytes
			if f.Kind == PBStr {
				value = []byte(f.Str)
			}
			if len(value) == 0 {
				continue
			}
			out = append(out, pbVarint(uint64(f.Number)<<3|2)...)
			out = append(out, pbVarint(uint64(len(value)))...)
			out = append(out, value...)
		}
	}
	return out
}

// PBRow 解码结果：Kind 0 → Int；1/2/5 → Bytes（保留原始定长字节）。
type PBRow struct {
	Number int
	Kind   int
	Int    uint64
	Bytes  []byte
}

const pbMaxData = 1 << 16

func pbDecode(data []byte) ([]PBRow, error) {
	if len(data) > pbMaxData {
		return nil, errPB
	}
	var rows []PBRow
	cursor := 0
	for cursor < len(data) {
		tag, next, err := pbReadInt(data, cursor)
		if err != nil {
			return nil, err
		}
		cursor = next
		number := int(tag >> 3)
		kind := int(tag & 7)
		if number < 1 || number >= 1<<29 {
			return nil, errPB
		}
		row := PBRow{Number: number, Kind: kind}
		switch kind {
		case 0:
			value, next, err := pbReadInt(data, cursor)
			if err != nil {
				return nil, err
			}
			row.Int = value
			cursor = next
		case 1, 2, 5:
			size := 0
			switch kind {
			case 1:
				size = 8
			case 5:
				size = 4
			case 2:
				value, next, e := pbReadIntLimit(data, cursor)
				if e != nil {
					return nil, e
				}
				size = int(value)
				cursor = next
			}
			if size > len(data)-cursor {
				return nil, errPB
			}
			row.Bytes = data[cursor : cursor+size]
			cursor += size
		default:
			return nil, errPB
		}
		rows = append(rows, row)
		if len(rows) > 512 {
			return nil, errPB
		}
	}
	return rows, nil
}

// pbReadInt 严格有界 varint 读取（最多 10 字节，第 10 字节 >1 视为溢出）。
func pbReadInt(data []byte, cursor int) (uint64, int, error) {
	var result uint64
	for part := 0; part < 10; part++ {
		if cursor >= len(data) {
			return 0, 0, errPB
		}
		b := data[cursor]
		cursor++
		if part == 9 && b > 1 {
			return 0, 0, errPB
		}
		result |= uint64(b&127) << (7 * part)
		if b < 128 {
			return result, cursor, nil
		}
	}
	return 0, 0, errPB
}

// pbReadIntLimit 宽松版（v5assets 的配置帧解码用它：无第 10 字节约束）。
func pbReadIntLimit(data []byte, cursor int) (uint64, int, error) {
	var result uint64
	for part := 0; part < 10; part++ {
		if cursor >= len(data) {
			return 0, 0, errPB
		}
		b := data[cursor]
		cursor++
		result |= uint64(b&127) << (7 * part)
		if b < 128 {
			return result, cursor, nil
		}
	}
	return 0, 0, errPB
}

// signed 即上游 zigzag（Python 任意精度语义在 int64 内等价）。
func signed(value int64) uint64 {
	return uint64((value << 1) ^ (value >> 63))
}

func float32BitsLE(v float32) []byte {
	bits := math.Float32bits(v)
	return []byte{byte(bits), byte(bits >> 8), byte(bits >> 16), byte(bits >> 24)}
}
