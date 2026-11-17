//go:build darwin && cgo

package unicorn

/*
#cgo darwin,arm64 CFLAGS: -I${SRCDIR}/../../third/unicorn/prebuilt/macos-arm64/include
#cgo darwin,arm64 LDFLAGS: ${SRCDIR}/../../third/unicorn/prebuilt/macos-arm64/libunicorn.a
#cgo darwin,amd64 CFLAGS: -I${SRCDIR}/../../third/unicorn/prebuilt/macos-x86_64/include
#cgo darwin,amd64 LDFLAGS: ${SRCDIR}/../../third/unicorn/prebuilt/macos-x86_64/libunicorn.a
*/
import "C"
