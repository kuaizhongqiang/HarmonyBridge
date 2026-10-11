// Package core implements CoreService: the lifecycle of the embedded
// Xray-core instance.
//
// Startup is split into two explicit phases so that the NAPI layer can tell
// the UI exactly how far it got, instead of collapsing every failure into one
// opaque error:
//
//	CoreService.Start  -> loads and validates the config; optionally boots Xray
//	CoreService.Stop   -> tears the instance down and drops the tun fd env var
//	CoreService.Status -> reports what is currently running
//
// The "dry run" default (start=false) exists because the OHOS port cannot yet
// hand a tun file descriptor to Xray - see docs/design/core.md, section
// "tun fd handoff". Until that is solved, booting the core would produce a
// process with no working inbound, so Start validates by default and only
// boots when the caller explicitly opts in.
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
	"strconv"
	"sync"

	"github.com/xtls/xray-core/common/platform"
	xcore "github.com/xtls/xray-core/core"

	"harmonybridge/core/ipc"
	// Blank import pulls in the file logging handler, which registers itself
	// with xray's app/log package and feeds the LogService ring buffer.
	_ "harmonybridge/core/service/log"
)

// Service is the CoreService handler. Exactly one instance exists per process;
// Xray itself supports only one running Server at a time.
type Service struct {
	mu       sync.Mutex
	instance *xcore.Instance
	lastFd   int
	lastErr  string
}

// StartRequest is the parameter object for CoreService.Start.
type StartRequest struct {
	// Fd is the tun file descriptor owned by the ArkTS VpnExtensionAbility.
	// The UI must keep its own copy open.
	Fd int `json:"fd"`

	// AssetLocation is the directory holding geoip.dat / geosite.dat. It is
	// exported to Xray as the xray.location.asset env var, which is the
	// variable Xray's platform package reads when resolving assets.
	AssetLocation string `json:"assetLocation"`

	// ConfigLocation is an absolute path to a JSON config file. When empty,
	// Start only performs diagnostics.
	ConfigLocation string `json:"configLocation"`

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

	// Wired reports whether the tun file descriptor was handed to the core in
	// a way that can actually carry traffic. It is false until the tun-fd
	// problem is solved on OHOS.
	Wired bool `json:"wired"`

	// Fd is the descriptor number that was exported to the core.
	Fd int `json:"fd"`

	// Version is the Xray-core version that is running / would run.
	Version string `json:"version"`

	// Notes carries the honest "what is still stubbed" list for the UI.
	Notes []string `json:"notes"`
}

// StatusResponse describes the current core state.
type StatusResponse struct {
	Running bool   `json:"running"`
	Version string `json:"version"`
	Fd      int    `json:"fd"`
	LastErr string `json:"lastError,omitempty"`
}

// StopRequest is the parameter object for CoreService.Stop. It is currently
// empty but kept as a struct so the wire format stays uniform.
type StopRequest struct{}

// StopResponse reports the state after teardown.
type StopResponse struct {
	Stopped bool `json:"stopped"`
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

	resp := &StartResponse{
		Fd:      req.Fd,
		Version: xcore.Version(),
	}

	// 1. Export the asset location.
	if req.AssetLocation != "" {
		if err := os.Setenv(platform.AssetLocation, req.AssetLocation); err != nil {
			return nil, fmt.Errorf("set %s: %w", platform.AssetLocation, err)
		}
	} else {
		resp.Notes = append(resp.Notes,
			"assetLocation is empty: geoip.dat/geosite.dat will not resolve")
	}

	// 2. Export the tun fd.
	//
	//    This mirrors the reference HarmonyOS client and what Xray's
	//    proxy/tun inbound expects on android/darwin: the fd is passed via the
	//    xray.tun.fd environment variable and the inbound wraps it with gvisor
	//    fdbased. Under GOOS=android the *android* backend is compiled in.
	//    Whether that backend is correct on OHOS musl is UNVERIFIED, which is
	//    why Wired stays false and the caller must opt in to Start.
	if req.Fd > 0 {
		if err := os.Setenv(platform.TunFdKey, strconv.Itoa(req.Fd)); err != nil {
			return nil, fmt.Errorf("set %s: %w", platform.TunFdKey, err)
		}
	} else {
		resp.Notes = append(resp.Notes, "fd is not set: no tun inbound can be created")
	}

	if req.ConfigLocation == "" {
		resp.Notes = append(resp.Notes,
			"configLocation is empty: nothing was loaded (diagnostic call only)")
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

	// 4. Boot only on explicit request.
	if !req.Start {
		resp.Notes = append(resp.Notes,
			"config validated; core not started because \"start\" was false",
			"TODO(ohos): tun fd handoff is not implemented - see docs/design/core.md")
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
	s.lastFd = req.Fd
	s.lastErr = ""
	resp.Started = true
	resp.Wired = false
	resp.Notes = append(resp.Notes,
		"instance started, but no tun inbound is wired: traffic cannot flow yet")

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

	// Drop the fd from the environment so a later Start cannot accidentally
	// reuse a descriptor the VpnExtensionAbility has already closed.
	_ = os.Unsetenv(platform.TunFdKey)

	s.lastFd = 0
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
		Fd:      s.lastFd,
		LastErr: s.lastErr,
	}, nil
}

// Shutdown closes any running instance without touching the env. It is called
// from the ArkTS ability's onDestroy path via CoreService.Stop in practice,
// but is exported for tests.
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
}
