//go:build cgo

package unicorn

import (
	"runtime"
	"testing"
)

func TestSmokeOpenMap(t *testing.T) {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	e, err := Open()
	if err != nil {
		t.Fatal(err)
	}
	defer e.Close()
	if err := e.MemMap(0x1000, 0x1000); err != nil {
		t.Fatal(err)
	}
	if err := e.MemWrite(0x1000, []byte{0x1f, 0x20, 0x03, 0xd5}); err != nil { // nop
		t.Fatal(err)
	}
	if err := e.RegWrite(RegPC, 0x1000); err != nil {
		t.Fatal(err)
	}
	if err := e.EmuStart(0x1000, 0x1004, 1_000_000, 1); err != nil {
		t.Fatal(err)
	}
	pc, err := e.RegRead(RegPC)
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("pc=%#x", pc)
}
