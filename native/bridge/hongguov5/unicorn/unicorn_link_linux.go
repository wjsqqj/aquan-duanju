//go:build linux && !android && amd64 && cgo

package unicorn

/*
#cgo CFLAGS: -I${SRCDIR}/../../third/unicorn/prebuilt/linux-amd64/include
#cgo LDFLAGS: ${SRCDIR}/../../third/unicorn/prebuilt/linux-amd64/libunicorn.a -lpthread
*/
import "C"
