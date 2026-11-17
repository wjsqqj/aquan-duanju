//go:build windows && amd64 && cgo

package unicorn

/*
#cgo CFLAGS: -I${SRCDIR}/../../third/unicorn/prebuilt/windows-amd64/include
#cgo LDFLAGS: ${SRCDIR}/../../third/unicorn/prebuilt/windows-amd64/libunicorn.a -Wl,-Bstatic -lwinpthread -Wl,-Bdynamic -static-libgcc
*/
import "C"
