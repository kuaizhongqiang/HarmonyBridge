// Package ipc implements the tiny JSON-over-C-ABI service dispatcher that sits
// between the NAPI bridge (libbridge.so) and the Go service implementations
// (libcore.so).
//
// The contract is deliberately minimal so that it can be re-implemented in any
// language on the other side of the C boundary:
//
//	invoke("CoreService.Start", `{"configLocation":"/data/.../config.json"}`)
//
// A service name is the pair <Group>.<Method>, where <Group> is the Go struct
// name of the handler receiver (e.g. "CoreService") and <Method> is one of its
// exported methods (e.g. "Start"). Handlers are discovered by reflection and
// must have the shape:
//
//	func (s *SomeService) Method(req *Request) (*Response, error)
//
// The dispatcher never panics: every failure - unknown service, unknown
// method, malformed JSON, handler error - is folded into a Response envelope
// with Success=false. That guarantee matters because the response must always
// be a valid JSON string on the other side of the C ABI.
package ipc

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"
)

// Response is the JSON envelope returned across the C ABI for every request.
//
// Success is always present. Result carries the handler payload and is omitted
// when the handler returned nothing or when Success is false. Error carries a
// human readable message and is omitted on success.
type Response struct {
	Success bool   `json:"success"`
	Result  any    `json:"result,omitempty"`
	Error   string `json:"error,omitempty"`
}

// ResponseRaw is the same envelope but with a pre-encoded result, used when a
// handler wants to forward an opaque JSON blob.
type ResponseRaw struct {
	Success bool            `json:"success"`
	Result  json.RawMessage `json:"result,omitempty"`
	Error   string          `json:"error,omitempty"`
}

// Void is the canonical "no parameters" / "no result" payload. It marshals to
// an empty JSON object, which keeps the wire format uniform.
type Void struct{}

// OK builds a success envelope around an arbitrary payload.
func OK(result any) *Response {
	return &Response{Success: true, Result: result}
}

// Fail builds a failure envelope.
func Fail(err error) *Response {
	if err == nil {
		return &Response{Success: true}
	}
	return &Response{Success: false, Error: err.Error()}
}

// Failf builds a failure envelope from a format string.
func Failf(format string, args ...any) *Response {
	return &Response{Success: false, Error: fmt.Sprintf(format, args...)}
}

// ErrVoid is returned by handlers that produced no meaningful payload.
var ErrVoid = errors.New("ipc: void")

// Handler is the function signature implemented by every service method.
type Handler func(params json.RawMessage) (any, error)

// Registry maps "<Group>.<Method>" to a Handler.
//
// It is safe for concurrent use: reads take a read lock, and registration is
// expected to happen from package init() before the library is handed to the
// UI thread.
type Registry struct {
	mu     sync.RWMutex
	routes map[string]Handler
}

// NewRegistry returns an empty registry.
func NewRegistry() *Registry {
	return &Registry{routes: make(map[string]Handler)}
}

// Default is the process-wide registry used by Register/HandleRequest.
var Default = NewRegistry()

// Register adds a named route to the default registry. It panics on a
// duplicate or malformed name: both indicate a programming error that should
// surface immediately at startup, not at runtime on a user's device.
func Register(name string, h Handler) {
	Default.Register(name, h)
}

// Register adds a named route to r.
func (r *Registry) Register(name string, h Handler) {
	group, method, err := SplitService(name)
	if err != nil {
		panic("ipc: " + err.Error())
	}
	if h == nil {
		panic("ipc: nil handler for " + name)
	}

	key := group + "." + method
	r.mu.Lock()
	defer r.mu.Unlock()
	if _, dup := r.routes[key]; dup {
		panic("ipc: duplicate handler registered for " + key)
	}
	r.routes[key] = h
}

// Lookup returns the handler registered for name, if any.
func (r *Registry) Lookup(name string) (Handler, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	h, ok := r.routes[name]
	return h, ok
}

// Names returns the registered route names, sorted lexicographically. It is
// used by the doc-generation test and by diagnostics.
func (r *Registry) Names() []string {
	r.mu.RLock()
	names := make([]string, 0, len(r.routes))
	for name := range r.routes {
		names = append(names, name)
	}
	r.mu.RUnlock()
	sortStrings(names)
	return names
}

// SplitService parses "Group.Method" into its two halves.
//
// The split is on the LAST dot so that a future namespaced group such as
// "app.service.CoreService.Start" still works.
func SplitService(name string) (group, method string, err error) {
	name = strings.TrimSpace(name)
	if name == "" {
		return "", "", errors.New("empty service name")
	}
	idx := strings.LastIndex(name, ".")
	if idx <= 0 {
		return "", "", fmt.Errorf("service name %q is not of the form Group.Method", name)
	}
	if idx == len(name)-1 {
		return "", "", fmt.Errorf("service name %q has an empty method", name)
	}
	return name[:idx], name[idx+1:], nil
}

// Invoke decodes params and runs the handler registered under name.
//
// It never panics and always returns a non-nil Response. params may be nil or
// empty, in which case the handler is called with an empty JSON object.
func (r *Registry) Invoke(name string, params json.RawMessage) (resp *Response) {
	defer func() {
		if rec := recover(); rec != nil {
			resp = Failf("panic in handler %s: %v", name, rec)
		}
	}()

	h, ok := r.Lookup(name)
	if !ok {
		return Failf("service not found: %s", name)
	}

	if len(bytes.TrimSpace(params)) == 0 {
		params = json.RawMessage("{}")
	}
	// Reject malformed JSON before the handler sees it, so handler code can
	// assume well-formed input.
	if !json.Valid(params) {
		return Failf("invalid params JSON for %s", name)
	}

	result, err := h(params)
	if err != nil {
		if errors.Is(err, ErrVoid) {
			return &Response{Success: true}
		}
		return Fail(err)
	}
	if result == nil {
		return &Response{Success: true}
	}
	return OK(result)
}

// Invoke is the package-level convenience wrapper around Default.
func Invoke(name string, params json.RawMessage) *Response {
	return Default.Invoke(name, params)
}

// HandleRequest is the single entry point used by the C ABI. Given a service
// name and a JSON parameter string it returns the JSON envelope as a string.
//
// This function is guaranteed never to panic and never to return "".
func HandleRequest(service, paramsJSON string) string {
	resp := dispatch(service, paramsJSON)
	data, err := json.Marshal(resp)
	if err != nil {
		// Marshalling our own envelope failed: hand back a hand-written
		// minimal envelope rather than crashing across the C boundary.
		return `{"success":false,"error":"ipc: failed to marshal response envelope"}`
	}
	return string(data)
}

func dispatch(service, paramsJSON string) *Response {
	if _, _, err := SplitService(service); err != nil {
		return Fail(err)
	}
	return Default.Invoke(service, json.RawMessage(paramsJSON))
}

// HandleRequestWith is like HandleRequest but dispatches against r.
func HandleRequestWith(r *Registry, service, paramsJSON string) string {
	resp := r.Invoke(service, json.RawMessage(paramsJSON))
	data, err := json.Marshal(resp)
	if err != nil {
		return `{"success":false,"error":"ipc: failed to marshal response envelope"}`
	}
	return string(data)
}

// DecodeParams unmarshals params into dst, tolerating an empty payload.
func DecodeParams(params json.RawMessage, dst any) error {
	if len(bytes.TrimSpace(params)) == 0 {
		return nil
	}
	return json.Unmarshal(params, dst)
}

// sortStrings is a tiny insertion sort so the package keeps no non-stdlib
// dependency beyond encoding/json and strings.
func sortStrings(s []string) {
	for i := 1; i < len(s); i++ {
		for j := i; j > 0 && s[j] < s[j-1]; j-- {
			s[j], s[j-1] = s[j-1], s[j]
		}
	}
}
