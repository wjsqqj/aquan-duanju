//go:build android && cgo

package unicorn

/*
#cgo android,arm64 CFLAGS: -I${SRCDIR}/../../third/unicorn/prebuilt/android-arm64-v8a/include
#cgo android,arm64 LDFLAGS: ${SRCDIR}/../../third/unicorn/prebuilt/android-arm64-v8a/libunicorn.a
#cgo android,arm CFLAGS: -I${SRCDIR}/../../third/unicorn/prebuilt/android-armeabi-v7a/include
#cgo android,arm LDFLAGS: ${SRCDIR}/../../third/unicorn/prebuilt/android-armeabi-v7a/libunicorn.a -latomic
#cgo android,amd64 CFLAGS: -I${SRCDIR}/../../third/unicorn/prebuilt/android-x86_64/include
#cgo android,amd64 LDFLAGS: ${SRCDIR}/../../third/unicorn/prebuilt/android-x86_64/libunicorn.a
*/
import "C"
