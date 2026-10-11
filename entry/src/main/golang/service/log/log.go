// Package log provides LogService: a bounded, in-process ring buffer of the
// most recent Xray log lines, plus the file log handler that feeds it.
//
// Why a ring buffer at all: on OHOS the native core's stdout is not attached
// to anything the UI can read, and writing every line to disk would be both
// slow and a privacy hazard (log lines contain destination addresses). A ring
// buffer lets the log page render "the last N lines" on demand and lets the
// buffer be cleared, with no unbounded growth.
package log

import (
	"encoding/json"
	"strings"
	"sync"

	appLog "github.com/xtls/xray-core/app/log"
	commonLog "github.com/xtls/xray-core/common/log"

	"harmonybridge/core/ipc"
)

// DefaultCapacity is how many log lines are retained when the UI does not say.
const DefaultCapacity = 512

// Ring is a fixed-size, concurrency-safe FIFO of log lines. Once full, the
// oldest line is overwritten.
type Ring struct {
	mu    sync.RWMutex
	lines []string
	next  int
	count int
}

// NewRing returns a ring buffer holding at most capacity lines.
func NewRing(capacity int) *Ring {
	if capacity <= 0 {
		capacity = DefaultCapacity
	}
	return &Ring{lines: make([]string, capacity)}
}

// Add appends one line, evicting the oldest when full.
func (r *Ring) Add(line string) {
	line = strings.TrimRight(line, "\r\n")
	if line == "" {
		return
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	r.lines[r.next] = line
	r.next = (r.next + 1) % len(r.lines)
	if r.count < len(r.lines) {
		r.count++
	}
}

// Tail returns up to n lines in chronological order (oldest first). A
// non-positive n returns everything currently retained.
func (r *Ring) Tail(n int) []string {
	r.mu.RLock()
	defer r.mu.RUnlock()

	if n <= 0 || n > r.count {
		n = r.count
	}
	out := make([]string, 0, n)
	// The oldest retained line sits `count` slots behind the write cursor.
	start := (r.next - r.count + len(r.lines)) % len(r.lines)
	for i := 0; i < n; i++ {
		out = append(out, r.lines[(start+i)%len(r.lines)])
	}
	return out
}

// Clear drops every retained line.
func (r *Ring) Clear() {
	r.mu.Lock()
	defer r.mu.Unlock()
	for i := range r.lines {
		r.lines[i] = ""
	}
	r.next, r.count = 0, 0
}

// Len returns how many lines are currently retained.
func (r *Ring) Len() int {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.count
}

// ring is the process-wide buffer shared with the Xray log handler.
var ring = NewRing(DefaultCapacity)

// Buffer exposes the process-wide ring buffer (used by the log handler and by
// tests).
func Buffer() *Ring { return ring }

// Handler adapts the ring buffer to xray's common/log.Handler interface.
type Handler struct {
	ring *Ring
}

// Handle implements commonLog.Handler.
func (h *Handler) Handle(msg commonLog.Message) {
	h.ring.Add(msg.String())
}

// Service is the LogService handler.
type Service struct {
	ring *Ring
}

// TailRequest is the parameter object for LogService.Tail.
type TailRequest struct {
	// Limit is the maximum number of lines to return, newest last.
	Limit int `json:"limit"`
}

// TailResponse is the payload returned by LogService.Tail.
type TailResponse struct {
	Lines []string `json:"lines"`
	Count int      `json:"count"`
}

// ClearRequest is the parameter object for LogService.Clear.
type ClearRequest struct{}

// ClearResponse reports how many lines were dropped.
type ClearResponse struct {
	Cleared int `json:"cleared"`
}

// Tail implements LogService.Tail.
func (s *Service) Tail(req *TailRequest) (*TailResponse, error) {
	limit := 0
	if req != nil {
		limit = req.Limit
	}
	lines := s.ring.Tail(limit)
	if lines == nil {
		// Marshal as [] rather than null so the ArkTS side can iterate
		// unconditionally.
		lines = []string{}
	}
	return &TailResponse{Lines: lines, Count: s.ring.Len()}, nil
}

// Clear implements LogService.Clear.
func (s *Service) Clear(_ *ClearRequest) (*ClearResponse, error) {
	n := s.ring.Len()
	s.ring.Clear()
	return &ClearResponse{Cleared: n}, nil
}

var svc = &Service{ring: ring}

// registerFileHandler installs a LogType_File handler that tees Xray's log
// stream into the ring buffer instead of to disk.
//
// Xray's own file handler is replaced, so a config asking for
// "log": {"logLevel": "info"} still produces entries - they just land in
// memory where the UI can read them.
func registerFileHandler() error {
	if err := appLog.RegisterHandlerCreator(appLog.LogType_File,
		func(_ appLog.LogType, _ appLog.HandlerCreatorOptions) (commonLog.Handler, error) {
			return &Handler{ring: ring}, nil
		}); err != nil {
		return err
	}
	// The console handler writes to stdout, which is not observable from
	// ArkTS. Point it at the ring buffer too so a config that logs to console
	// is equally visible.
	return appLog.RegisterHandlerCreator(appLog.LogType_Console,
		func(_ appLog.LogType, _ appLog.HandlerCreatorOptions) (commonLog.Handler, error) {
			return &Handler{ring: ring}, nil
		})
}

func init() {
	// Registration failure means app/log changed its API under us; surface it
	// loudly at load time rather than silently losing all logs.
	if err := registerFileHandler(); err != nil {
		panic("log: cannot register xray log handlers: " + err.Error())
	}

	ipc.Register("LogService.Tail", func(params json.RawMessage) (any, error) {
		var req TailRequest
		if err := ipc.DecodeParams(params, &req); err != nil {
			return nil, err
		}
		return svc.Tail(&req)
	})
	ipc.Register("LogService.Clear", func(params json.RawMessage) (any, error) {
		var req ClearRequest
		if err := ipc.DecodeParams(params, &req); err != nil {
			return nil, err
		}
		return svc.Clear(&req)
	})
}
