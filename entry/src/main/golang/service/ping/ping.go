// Package ping implements PingService: a plain TCP connect-and-measure delay
// test for a host:port pair.
//
// Scope note: this measures raw reachability/latency of an endpoint (what
// v2rayN calls a "Tcping" test). It deliberately does NOT route the probe
// through Xray, so it says nothing about whether a proxy actually works - it
// answers "can this device open a TCP connection to this address, and how
// fast". Routing a probe through a live Xray outbound is a separate,
// instance-dependent feature (see docs/design/core.md, "unresolved").
//
// The package also implements PingService.SpeedTest, which is a stub that
// deliberately refuses to produce a number: a real measurement needs a live,
// fully wired core on the device, and this build has neither. See SpeedTest.
package ping

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"strconv"
	"sync"
	"time"

	"harmonybridge/core/ipc"
)

// DefaultTimeout bounds a single probe when the caller does not say otherwise.
const DefaultTimeout = 5 * time.Second

// minTimeout / maxTimeout clamp user-supplied values so a UI bug cannot hang
// the native thread for minutes or produce meaningless sub-millisecond bounds.
const (
	minTimeout = 200 * time.Millisecond
	maxTimeout = 30 * time.Second
)

// Service is the PingService handler.
type Service struct {
	mu sync.Mutex
}

// Request is the parameter object for PingService.Tcping.
type Request struct {
	// Host is a hostname or IP literal, e.g. "example.com" or "1.1.1.1".
	Host string `json:"host"`

	// Port is the TCP port. Port 0 is rejected.
	Port int `json:"port"`

	// TimeoutMs optionally overrides DefaultTimeout.
	TimeoutMs int `json:"timeoutMs"`
}

// Response is the payload returned by PingService.Tcping.
type Response struct {
	// LatencyMs is the measured round trip to a completed TCP handshake. The
	// field used to be called delayMs; it was renamed to match the frozen
	// contract (docs/design/ipc-contract.md section 5.3).
	LatencyMs int64 `json:"latencyMs"`

	// Reachable is false when the probe failed; LatencyMs is then -1.
	Reachable bool `json:"reachable"`

	// Address is the resolved host:port that was dialled.
	Address string `json:"address"`

	// IP is the resolved address literal.
	IP string `json:"ip"`

	// ResolveMs is the DNS lookup time (0 when Host was already an IP).
	ResolveMs int64 `json:"resolveMs"`

	// Error carries the failure reason when Reachable is false.
	Error string `json:"error,omitempty"`
}

// Tcping implements PingService.Tcping.
func (s *Service) Tcping(req *Request) (*Response, error) {
	if req == nil {
		return nil, errors.New("PingService.Tcping: missing parameters")
	}
	if req.Host == "" {
		return nil, errors.New("PingService.Tcping: host is required")
	}
	if req.Port <= 0 || req.Port > 65535 {
		return nil, fmt.Errorf("PingService.Tcping: port %d is out of range", req.Port)
	}

	timeout := DefaultTimeout
	if req.TimeoutMs > 0 {
		timeout = time.Duration(req.TimeoutMs) * time.Millisecond
	}
	if timeout < minTimeout {
		timeout = minTimeout
	}
	if timeout > maxTimeout {
		timeout = maxTimeout
	}

	// Resolve first so the DNS cost is reported separately from connect cost.
	resolveStart := time.Now()
	ip := req.Host
	if net.ParseIP(ip) == nil {
		addrs, err := net.DefaultResolver.LookupHost(context.Background(), req.Host)
		if err != nil || len(addrs) == 0 {
			return &Response{
				LatencyMs: -1,
				Reachable: false,
				Address:   net.JoinHostPort(req.Host, strconv.Itoa(req.Port)),
				Error:     "dns: " + errString(err, "no addresses returned"),
			}, nil
		}
		ip = addrs[0]
	}
	resolveMs := time.Since(resolveStart).Milliseconds()

	address := net.JoinHostPort(ip, strconv.Itoa(req.Port))

	// Probe every resolved address in turn, returning the first success. A
	// host with both an A and an AAAA record often only has one working path.
	all := []string{ip}
	if net.ParseIP(req.Host) == nil {
		if addrs, err := net.DefaultResolver.LookupHost(context.Background(), req.Host); err == nil {
			all = addrs
		}
	}

	var lastErr string
	for _, candidate := range all {
		dialAddr := net.JoinHostPort(candidate, strconv.Itoa(req.Port))

		dialer := &net.Dialer{Timeout: timeout}
		start := time.Now()
		conn, err := dialer.DialContext(context.Background(), "tcp", dialAddr)
		elapsed := time.Since(start)
		if err != nil {
			lastErr = err.Error()
			continue
		}
		_ = conn.Close()

		return &Response{
			LatencyMs: elapsed.Milliseconds(),
			Reachable: true,
			Address:   dialAddr,
			IP:        candidate,
			ResolveMs: resolveMs,
		}, nil
	}

	return &Response{
		LatencyMs: -1,
		Reachable: false,
		Address:   address,
		IP:        ip,
		ResolveMs: resolveMs,
		Error:     errString(nil, lastErr),
	}, nil
}

// SpeedTestRequest is the parameter object for PingService.SpeedTest. It is
// empty but kept as a struct so the wire format stays uniform.
type SpeedTestRequest struct{}

// SpeedTestResponse is the payload returned by PingService.SpeedTest.
type SpeedTestResponse struct {
	// SpeedBps is the measured throughput in bits per second. It is ALWAYS 0 in
	// this build: 0 means "not measured", it does NOT mean "0 bit/s". The
	// frozen contract forbids filling in a fake number (section 4.1), so a
	// caller must read Notes before showing anything to a user.
	SpeedBps int64 `json:"speedBps"`

	// Notes explains why no measurement was taken. Never empty.
	Notes []string `json:"notes"`
}

// SpeedTest implements PingService.SpeedTest.
//
// It is a stub on purpose. A real throughput measurement has to push bytes
// through a live core with a working inbound on a real device; neither exists
// yet (local SOCKS/HTTP inbounds are not listening and there is no tun2socks),
// so the only honest answer is "unknown" - never a made-up rate. The contract
// spells this out: 不得伪造测量值 (docs/design/ipc-contract.md section 4.1).
func (s *Service) SpeedTest(_ *SpeedTestRequest) (*SpeedTestResponse, error) {
	return &SpeedTestResponse{
		SpeedBps: 0,
		Notes: []string{
			"测速需要在真机上跑一个活的、本地入站已监听的 Xray 实例；本阶段未实现，" +
				"因此 speedBps 恒为 0（0 = 未测量，不是 0 bit/s）",
		},
	}, nil
}

func errString(err error, fallback string) string {
	if err != nil {
		return err.Error()
	}
	if fallback != "" {
		return fallback
	}
	return "unreachable"
}

var svc = &Service{}

func init() {
	ipc.Register("PingService.Tcping", func(params json.RawMessage) (any, error) {
		var req Request
		if err := ipc.DecodeParams(params, &req); err != nil {
			return nil, err
		}
		return svc.Tcping(&req)
	})
	ipc.Register("PingService.SpeedTest", func(params json.RawMessage) (any, error) {
		var req SpeedTestRequest
		if err := ipc.DecodeParams(params, &req); err != nil {
			return nil, err
		}
		return svc.SpeedTest(&req)
	})
}
