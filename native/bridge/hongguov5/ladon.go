package hongguov5

// ladon.go — X-Ladon/Helios 头加密（移植自 pyvendor/XLadon.py + pkcs7_padding.py）。

import (
	"encoding/base64"
	"encoding/binary"
	"fmt"
)

func ror64(value uint64, count uint) uint64 {
	count %= 64
	return value>>count | value<<(64-count)
}

func ladonEncryptInput(hashTable []byte, input []byte) []byte {
	data0 := binary.LittleEndian.Uint64(input[:8])
	data1 := binary.LittleEndian.Uint64(input[8:])
	for i := 0; i < 0x22; i++ {
		hash := binary.LittleEndian.Uint64(hashTable[i*8 : i*8+8])
		data1 = hash ^ (data0 + ror64(data1, 8))
		data0 = data1 ^ ror64(data0, 0x3D)
	}
	out := make([]byte, 16)
	binary.LittleEndian.PutUint64(out[:8], data0)
	binary.LittleEndian.PutUint64(out[8:], data1)
	return out
}

func encryptLadon(md5hexChars string, data []byte) []byte {
	// Python 语义：hash_table[:32] = md5hex（64 字符）触发切片扩展——
	// 结果布局是 [0:64)=hex 字符串、[64:)=零，总长 320。
	hashTable := make([]byte, 272+16)
	copy(hashTable, md5hexChars)

	bufferB0 := binary.LittleEndian.Uint64(hashTable[0:8])
	bufferB8 := binary.LittleEndian.Uint64(hashTable[8:16])
	// temp 初始队列：4 个字读入后弹出前两个 → 余 [words[2], words[3]]。
	queue := []uint64{
		binary.LittleEndian.Uint64(hashTable[16:24]),
		binary.LittleEndian.Uint64(hashTable[24:32]),
	}
	for i := 0; i < 0x22; i++ {
		x9 := bufferB0
		x8 := ror64(bufferB8, 8)
		x8 = x8 + x9
		x8 = x8 ^ uint64(i)
		queue = append(queue, x8)
		x8 = x8 ^ ror64(x9, 61)
		binary.LittleEndian.PutUint64(hashTable[(i+1)*8:(i+1)*8+8], x8)
		bufferB0 = x8
		bufferB8 = queue[0]
		queue = queue[1:]
	}

	newSize := pkcs7PaddingSize(len(data), 16)
	input := make([]byte, newSize)
	copy(input, data)
	pkcs7PadBuffer(input, len(data), newSize, 16)

	output := make([]byte, newSize)
	for i := 0; i < newSize/16; i++ {
		copy(output[i*16:(i+1)*16], ladonEncryptInput(hashTable, input[i*16:(i+1)*16]))
	}
	return output
}

// ladonEncrypt 生成 X-Ladon / X-Helios 头（randomBytes 固定 4 字节）。
func ladonEncrypt(timestamp int64, licenseID, aid int64, randomBytes []byte) (string, error) {
	if len(randomBytes) != 4 {
		return "", fmt.Errorf("%w: ladon-random-size", errWire)
	}
	data := fmt.Sprintf("%d-%d-%d", timestamp, licenseID, aid)
	keygen := make([]byte, 0, len(randomBytes)+12)
	keygen = append(keygen, randomBytes...)
	keygen = append(keygen, fmt.Sprintf("%d", aid)...)
	// Python md5bytes 返回 hexdigest 字符串（64 ASCII 字符），不是原始字节。
	md5hex := hexEncode(md5Sum(keygen))

	output := make([]byte, pkcs7PaddingSize(len(data), 16)+4)
	copy(output[:4], randomBytes)
	copy(output[4:], encryptLadon(md5hex, []byte(data)))
	return base64.StdEncoding.EncodeToString(output), nil
}

// ---- pkcs7_padding.py ----

func pkcs7PaddingSize(size, blockSize int) int {
	remainder := size % blockSize
	if remainder == 0 {
		return size
	}
	return size + (blockSize - remainder)
}

func pkcs7PadBuffer(buffer []byte, size, bufferSize, blockSize int) error {
	paddingSize := pkcs7PaddingSize(size, blockSize)
	if paddingSize > bufferSize {
		return fmt.Errorf("%w: pkcs7-overflow", errWire)
	}
	for i := size; i < paddingSize; i++ {
		buffer[i] = byte(paddingSize - size)
	}
	return nil
}
