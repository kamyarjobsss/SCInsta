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

	"github.com/xtls/xray-core/common/log"
	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/features/stats"
	"github.com/xtls/xray-core/infra/conf/serial"
	_ "github.com/xtls/xray-core/main/distro/all"
)

var (
	mu   sync.Mutex
	inst *core.Instance
)

const logLimit = 80

var (
	logMu    sync.Mutex
	logLines []string
)

type ringHandler struct{}

func (ringHandler) Handle(msg log.Message) {
	if msg == nil {
		return
	}
	line := strings.TrimSpace(msg.String())
	if line == "" {
		return
	}
	logMu.Lock()
	defer logMu.Unlock()
	logLines = append(logLines, line)
	if len(logLines) > logLimit {
		logLines = logLines[len(logLines)-logLimit:]
	}
}

func enableLog() {
	// Xray keeps a single handler. Register after Start so this ring replaces
	// the stdout handler the core installs from the config.
	log.RegisterHandler(ringHandler{})
}

func counterValue(name string) int64 {
	mu.Lock()
	s := inst
	mu.Unlock()
	if s == nil {
		return 0
	}
	feature := s.GetFeature(stats.ManagerType())
	mgr, ok := feature.(stats.Manager)
	if !ok || mgr == nil {
		return 0
	}
	counter := mgr.GetCounter(name)
	if counter == nil {
		return 0
	}
	return counter.Value()
}

var gcOnce sync.Once

func startGC() {
	// libXray does this on iOS: a periodic GC keeps the embedded runtime from
	// holding onto freed connection buffers inside a long-lived app process.
	// Started from ixray_start so dlopen itself does not spawn the ticker.
	gcOnce.Do(func() {
		go func() {
			t := time.NewTicker(10 * time.Second)
			defer t.Stop()
			for range t.C {
				runtime.GC()
			}
		}()
	})
}

//export ixray_start
func ixray_start(configJSON *C.char) *C.char {
	startGC()
	if configJSON == nil {
		return C.CString("empty xray config")
	}
	jsonText := C.GoString(configJSON)

	mu.Lock()
	defer mu.Unlock()

	if inst != nil {
		_ = inst.Close()
		inst = nil
		// The previous listeners release the ports after Close returns.
		time.Sleep(50 * time.Millisecond)
	}

	var last error
	for attempt := 0; attempt < 5; attempt++ {
		cfg, err := serial.LoadJSONConfig(strings.NewReader(jsonText))
		if err != nil {
			return C.CString(err.Error())
		}
		server, err := core.New(cfg)
		if err != nil {
			return C.CString(err.Error())
		}
		if err = server.Start(); err != nil {
			_ = server.Close()
			last = err
			msg := err.Error()
			if strings.Contains(msg, "address already in use") || strings.Contains(msg, "bind") {
				time.Sleep(80 * time.Millisecond)
				continue
			}
			return C.CString(msg)
		}
		inst = server
		enableLog()
		return nil
	}
	if last == nil {
		return C.CString("xray did not start")
	}
	return C.CString(last.Error())
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

//export ixray_copy_log
func ixray_copy_log() *C.char {
	logMu.Lock()
	defer logMu.Unlock()
	if len(logLines) == 0 {
		return C.CString("")
	}
	return C.CString(strings.Join(logLines, "\n"))
}

//export ixray_traffic
func ixray_traffic(up *C.uint64_t, down *C.uint64_t) {
	var uplink int64
	var downlink int64
	for _, tag := range []string{"socks-in", "http-in"} {
		uplink += counterValue("inbound>>>" + tag + ">>>traffic>>>uplink")
		downlink += counterValue("inbound>>>" + tag + ">>>traffic>>>downlink")
	}
	if uplink < 0 {
		uplink = 0
	}
	if downlink < 0 {
		downlink = 0
	}
	if up != nil {
		*up = C.uint64_t(uplink)
	}
	if down != nil {
		*down = C.uint64_t(downlink)
	}
}

// Silence unused in case the compiler drops the header import path.
var _ = unsafe.Sizeof(0)

// c-archive still requires a main function. The exported C symbols are the API.
func main() {}
