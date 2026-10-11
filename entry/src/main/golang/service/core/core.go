// Package core implements CoreService: the lifecycle of the embedded
// Xray-core instance.
//
// Startup is split into two explicit phases so that the NAPI layer can tell
// the UI exactly how far it got, instead of collapsing every failure into one
// opaque error:
//
//	CoreService.Start       -> loads and validates the config; optionally boots Xray
//	CoreService.Stop        -> tears the instance down
//	CoreService.Status      -> reports what is currently running
//	CoreService.RuntimeInfo -> reports the local inbound ports and the loaded config
//
// Data plane (architecture ruling, docs/design/ipc-contract.md section 2): the
// vNIC file descriptor is NOT handed to the core. The chain is
// tun -> tun2socks -> local SOCKS/HTTP inbound -> Xray outbound, so the core
// only ever owns the local SOCKS/HTTP inbounds and knows nothing about tun.
// The "fd" request field is therefore RESERVED: it is kept for wire
// compatibility and is not read by this package.
//
// The "dry run" default (start=false) exists because a booted core with no
// reachable client cannot do anything useful yet: Start validates by default
// and only boots when the caller explicitly opts in.
package core

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"runtime/debug"
	"strings"
	"sync"

	"github.com/xtls/xray-core/common/platform"
	xcore "github.com/xtls/xray-core/core"

	"harmonybridge/core/ipc"
	// The local inbound ports are defined once, in the config package that
	// generates the config using them. They are imported from here on purpose:
	// a second copy of "10808/10809" would be free to drift away from the ports
	// actually written into config.json.
	serviceconfig "harmonybridge/core/service/config"
	// Blank import pulls in the file logging handler, which registers itself
	// with xray's app/log package and feeds the LogService ring buffer.
	_ "harmonybridge/core/service/log"
)

// Service is the CoreService handler. Exactly one instance exists per process;
// Xray itself supports only one running Server at a time.
type Service struct {
	mu       sync.Mutex
	instance *xcore.Instance

	// lastConfig is the config file most recently read and parsed by the core's
	// own loader; socksPort / httpPort are the local inbound ports most
	// recently declared by CoreService.Start. Stop clears all three so that
	// RuntimeInfo keeps describing the *current* state, not a past one.
	lastConfig string
	socksPort  int
	httpPort   int

	lastErr string
}

// StartRequest is the parameter object for CoreService.Start.
type StartRequest struct {
	// Fd is RESERVED and currently unused. It used to carry the tun file
	// descriptor owned by the ArkTS VpnExtensionAbility; per the frozen contract
	// (docs/design/ipc-contract.md sections 2 and 5.1) the vNIC fd goes to
	// tun2socks instead, and the core never reads this field. It is kept so an
	// older UI build can still send its own payload without a decode failure.
	Fd int `json:"fd"`

	// AssetLocation is the directory holding geoip.dat / geosite.dat. It is
	// exported to Xray as the xray.location.asset env var, which is the
	// variable Xray's platform package reads when resolving assets.
	AssetLocation string `json:"assetLocation"`

	// ConfigLocation is an absolute path to a JSON config file. When empty,
	// Start only performs diagnostics.
	ConfigLocation string `json:"configLocation"`

	// SocksPort / HTTPPort are the local inbound ports the generated config
	// listens on. Both are optional: 0 - or any value outside 1..65535 - falls
	// back to serviceconfig.DefaultSocksPort / DefaultHTTPPort.
	SocksPort int `json:"socksPort"`
	HTTPPort  int `json:"httpPort"`

	// Start opts in to actually booting the Xray instance. Defaults to false:
	// see the package comment for why.
	Start bool `json:"start"`
}

// StartResponse describes the outcome of CoreService.Start.
type StartResponse struct {
	// Started is true when an Xray instance is now running.
	Started bool `json:"started"`

	// ConfigLoaded is true when ConfigLocation was read and parsed by Xray's
	// own JSON loader.
	ConfigLoaded bool `json:"configLoaded"`

	// ConfigBytes is the size of the config file that was read.
	ConfigBytes int `json:"configBytes"`

	// Wired reports whether the local SOCKS/HTTP inbounds are actually
	// listening and traffic can be routed out (contract section 4.1). Nothing
	// in this build listens on a port yet - the ports below are declared and
	// echoed back, not served - so it is ALWAYS false, and Notes explains why
	// in the very same response the UI reads.
	Wired bool `json:"wired"`

	// SocksPort / HTTPPort are the local inbound ports this call declared,
	// after falling back to the config package defaults when the request
	// omitted or mangled them.
	SocksPort int `json:"socksPort"`
	HTTPPort  int `json:"httpPort"`

	// Version is the Xray-core version that is running / would run.
	Version string `json:"version"`

	// Notes carries the honest "what is still stubbed" list for the UI.
	Notes []string `json:"notes"`
}

// StatusResponse describes the current core state.
//
// There is no "fd" field: the frozen contract removed it (section 5.6) because
// the core no longer takes a tun descriptor at all.
type StatusResponse struct {
	Running bool   `json:"running"`
	Version string `json:"version"`
	LastErr string `json:"lastError,omitempty"`
}

// StopRequest is the parameter object for CoreService.Stop. It is currently
// empty but kept as a struct so the wire format stays uniform.
type StopRequest struct{}

// StopResponse reports the state after teardown.
type StopResponse struct {
	Stopped bool `json:"stopped"`
}

// RuntimeInfoRequest is the parameter object for CoreService.RuntimeInfo. It is
// empty but kept as a struct so the wire format stays uniform, exactly like
// StopRequest.
type RuntimeInfoRequest struct{}

// RuntimeInfoResponse is the payload returned by CoreService.RuntimeInfo. Every
// field describes the current state of this Service, never a wished-for one.
type RuntimeInfoResponse struct {
	// SocksPort / HTTPPort are the local inbound ports declared by the most
	// recent CoreService.Start call, or the config package defaults when Start
	// has never run (or when the core was stopped).
	SocksPort int `json:"socksPort"`
	HTTPPort  int `json:"httpPort"`

	// ConfigLocation is the config file that was last read and parsed
	// successfully by the core's own loader. Empty when that never happened.
	ConfigLocation string `json:"configLocation,omitempty"`

	// Note states what the ports above do and do not mean right now, so that a
	// UI cannot mistake "declared" for "listening".
	Note string `json:"note,omitempty"`
}

// normalizePort returns port when it is a usable TCP port, otherwise def. The
// second result reports whether a caller-supplied value had to be rejected, so
// Start can tell the user instead of silently changing their settings.
func normalizePort(port, def int) (value int, fellBack bool) {
	if port >= 1 && port <= 65535 {
		return port, false
	}
	if port == 0 {
		return def, false
	}
	return def, true
}

// Start implements CoreService.Start.
func (s *Service) Start(req *StartRequest) (*StartResponse, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	if req == nil {
		return nil, errors.New("CoreService.Start: missing parameters")
	}

	// A previous instance cannot be reused: Xray instances are single-shot.
	if s.instance != nil {
		_ = s.instance.Close()
		s.instance = nil
		runtime.GC()
	}

	socksPort, socksFellBack := normalizePort(req.SocksPort, serviceconfig.DefaultSocksPort)
	httpPort, httpFellBack := normalizePort(req.HTTPPort, serviceconfig.DefaultHTTPPort)

	resp := &StartResponse{
		SocksPort: socksPort,
		HTTPPort:  httpPort,
		Version:   xcore.Version(),
		// Wired stays false: see the field comment. It is written out
		// explicitly so nobody "helpfully" flips it when Start succeeds.
		Wired: false,
	}

	s.socksPort = socksPort
	s.httpPort = httpPort

	// Say what the declared ports do and do not mean in *every* response,
	// including the diagnostic one: this is the field the UI keys its
	// "is traffic flowing" message off.
	resp.Notes = append(resp.Notes, fmt.Sprintf(
		"本地 SOCKS/HTTP 入站声明为 %d/%d，但本阶段没有任何进程真的在监听"+
			"（tun→tun2socks→SOCKS 尚未实现），wired 恒为 false", socksPort, httpPort))
	if socksFellBack {
		resp.Notes = append(resp.Notes, fmt.Sprintf(
			"socksPort %d 非法（需 1~65535）：已回落到默认端口 %d", req.SocksPort, socksPort))
	}
	if httpFellBack {
		resp.Notes = append(resp.Notes, fmt.Sprintf(
			"httpPort %d 非法（需 1~65535）：已回落到默认端口 %d", req.HTTPPort, httpPort))
	}
	if socksPort == httpPort {
		resp.Notes = append(resp.Notes, fmt.Sprintf(
			"socksPort 与 httpPort 都是 %d：两个本地入站无法共用同一端口", socksPort))
	}

	// 1. Export the asset location.
	if req.AssetLocation != "" {
		if err := os.Setenv(platform.AssetLocation, req.AssetLocation); err != nil {
			return nil, fmt.Errorf("set %s: %w", platform.AssetLocation, err)
		}
	} else {
		resp.Notes = append(resp.Notes,
			"assetLocation 为空：geoip.dat/geosite.dat 将无法解析")
	}

	// 2. Report - do not export - the reserved fd.
	//
	//    Handing a tun fd to the core is exactly the model the frozen contract
	//    rejected (section 2): the vNIC fd belongs to tun2socks, which is not
	//    implemented yet. Exporting it into the environment would only suggest
	//    to a future reader that the handoff exists.
	if req.Fd != 0 {
		resp.Notes = append(resp.Notes, fmt.Sprintf(
			"fd=%d 是保留字段、当前未使用：vNIC fd 交给 tun2socks，内核只做本地 SOCKS/HTTP 入站（契约 §2）",
			req.Fd))
	}

	if req.ConfigLocation == "" {
		resp.Notes = append(resp.Notes,
			"configLocation 为空：没有加载任何配置（纯诊断调用）")
		return resp, nil
	}

	// 3. Load and validate the config through Xray's own loader, so the config
	//    is checked by exactly the code that will later consume it.
	clean := filepath.Clean(req.ConfigLocation)
	data, err := os.ReadFile(clean)
	if err != nil {
		s.lastErr = err.Error()
		return nil, fmt.Errorf("read config %s: %w", clean, err)
	}
	resp.ConfigBytes = len(data)

	config, err := xcore.LoadConfig("json", bytes.NewReader(data))
	if err != nil {
		s.lastErr = err.Error()
		return nil, fmt.Errorf("parse config %s: %w", clean, err)
	}
	resp.ConfigLoaded = true
	s.lastConfig = clean

	// 4. Boot only on explicit request.
	if !req.Start {
		resp.Notes = append(resp.Notes,
			"配置已通过内核 loader 校验；start=false，未启动内核")
		return resp, nil
	}

	instance, err := xcore.New(config)
	if err != nil {
		s.lastErr = err.Error()
		return nil, fmt.Errorf("create xray instance: %w", err)
	}
	if err := instance.Start(); err != nil {
		_ = instance.Close()
		s.lastErr = err.Error()
		return nil, fmt.Errorf("start xray instance: %w", err)
	}

	s.instance = instance
	s.lastErr = ""
	resp.Started = true
	resp.Notes = append(resp.Notes,
		"内核实例已启动，但没有任何入站真的在监听（本地 SOCKS/HTTP 监听与 tun2socks 均未实现），wired=false")

	runtime.GC()
	debug.FreeOSMemory()
	return resp, nil
}

// Stop implements CoreService.Stop.
func (s *Service) Stop(_ *StopRequest) (*StopResponse, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	var closeErr error
	if s.instance != nil {
		closeErr = s.instance.Close()
		s.instance = nil
		runtime.GC()
	}

	// Forget the declared inbounds and the loaded config: after teardown there
	// is no live core, so RuntimeInfo must stop describing the previous one.
	s.socksPort = 0
	s.httpPort = 0
	s.lastConfig = ""

	if closeErr != nil {
		s.lastErr = closeErr.Error()
		return &StopResponse{Stopped: true}, fmt.Errorf("close xray instance: %w", closeErr)
	}
	s.lastErr = ""
	return &StopResponse{Stopped: true}, nil
}

// Status implements CoreService.Status.
func (s *Service) Status(_ *ipc.Void) (*StatusResponse, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	return &StatusResponse{
		Running: s.instance != nil && s.instance.IsRunning(),
		Version: xcore.Version(),
		LastErr: s.lastErr,
	}, nil
}

// RuntimeInfo implements CoreService.RuntimeInfo: the ports and config the
// service is currently holding, with a note that says plainly that nothing is
// listening on those ports yet.
//
// It never guesses: before the first Start it reports the same defaults the
// generator would use plus an empty configLocation.
func (s *Service) RuntimeInfo(_ *RuntimeInfoRequest) (*RuntimeInfoResponse, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	socksPort := s.socksPort
	if socksPort == 0 {
		socksPort = serviceconfig.DefaultSocksPort
	}
	httpPort := s.httpPort
	if httpPort == 0 {
		httpPort = serviceconfig.DefaultHTTPPort
	}

	resp := &RuntimeInfoResponse{
		SocksPort:      socksPort,
		HTTPPort:       httpPort,
		ConfigLocation: s.lastConfig,
	}

	var parts []string
	if s.instance == nil {
		parts = append(parts, "内核尚未启动（没有正在运行的 Xray 实例）")
	} else {
		parts = append(parts, "内核实例正在运行")
	}
	if s.lastConfig == "" {
		parts = append(parts, "尚未加载过任何配置文件")
	}
	parts = append(parts, "socksPort/httpPort 是最近一次 CoreService.Start 声明的本地入站端口，"+
		"本阶段没有任何进程真的在监听，CoreService.Start 的 wired 恒为 false")
	resp.Note = strings.Join(parts, "；")

	return resp, nil
}

// Shutdown closes any running instance without clearing the recorded ports and
// config. It is called from the ArkTS ability's onDestroy path via
// CoreService.Stop in practice, but is exported for tests.
func (s *Service) Shutdown(ctx context.Context) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.instance == nil {
		return nil
	}
	err := s.instance.Close()
	s.instance = nil
	_ = ctx
	return err
}

// svc is the process-wide CoreService.
var svc = &Service{}

func init() {
	ipc.Register("CoreService.Start", func(params json.RawMessage) (any, error) {
		var req StartRequest
		if err := ipc.DecodeParams(params, &req); err != nil {
			return nil, err
		}
		return svc.Start(&req)
	})
	ipc.Register("CoreService.Stop", func(params json.RawMessage) (any, error) {
		var req StopRequest
		if err := ipc.DecodeParams(params, &req); err != nil {
			return nil, err
		}
		return svc.Stop(&req)
	})
	ipc.Register("CoreService.Status", func(params json.RawMessage) (any, error) {
		return svc.Status(&ipc.Void{})
	})
	ipc.Register("CoreService.RuntimeInfo", func(params json.RawMessage) (any, error) {
		var req RuntimeInfoRequest
		if err := ipc.DecodeParams(params, &req); err != nil {
			return nil, err
		}
		return svc.RuntimeInfo(&req)
	})
}
