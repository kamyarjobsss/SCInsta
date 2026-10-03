// Instagram X in-process Xray core.
// Built on macOS CI as an iOS arm64 c-archive and linked into the tweak.
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"runtime"
	"strings"
	"sync"
	"time"
	"unsafe"

	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/infra/conf/serial"
	_ "github.com/xtls/xray-core/main/distro/all"
)

var (
	mu   sync.Mutex
	inst *core.Instance
)

func init() {
	// libXray does this on iOS: a periodic GC keeps the embedded runtime from
	// holding onto freed connection buffers inside a long-lived app process.
	go func() {
		t := time.NewTicker(10 * time.Second)
		defer t.Stop()
		for range t.C {
			runtime.GC()
		}
	}()
}

//export ixray_start
func ixray_start(configJSON *C.char) *C.char {
	if configJSON == nil {
		return C.CString("empty xray config")
	}
	jsonText := C.GoString(configJSON)

	mu.Lock()
	defer mu.Unlock()

	if inst != nil {
		_ = inst.Close()
		inst = nil
	}

	cfg, err := serial.LoadJSONConfig(strings.NewReader(jsonText))
	if err != nil {
		return C.CString(err.Error())
	}
	server, err := core.New(cfg)
	if err != nil {
		return C.CString(err.Error())
	}
	if err := server.Start(); err != nil {
		_ = server.Close()
		return C.CString(err.Error())
	}
	inst = server
	return nil
}

//export ixray_stop
func ixray_stop() {
	mu.Lock()
	defer mu.Unlock()
	if inst != nil {
		_ = inst.Close()
		inst = nil
	}
}

//export ixray_version
func ixray_version() *C.char {
	return C.CString(core.Version())
}

// Silence unused in case the compiler drops the header import path.
var _ = unsafe.Sizeof(0)

// c-archive still requires a main function. The exported C symbols are the API.
func main() {}
