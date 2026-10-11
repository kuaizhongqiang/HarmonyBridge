package ipc

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

func TestSplitService(t *testing.T) {
	good := map[string][2]string{
		"CoreService.Start":       {"CoreService", "Start"},
		"LogService.Tail":         {"LogService", "Tail"},
		"a.b":                     {"a", "b"},
		"app.svc.CoreService.Run": {"app.svc.CoreService", "Run"},
		"  Padded.Name  ":         {"Padded", "Name"},
	}
	for in, want := range good {
		group, method, err := SplitService(in)
		if err != nil {
			t.Errorf("SplitService(%q) errored: %v", in, err)
			continue
		}
		if group != want[0] || method != want[1] {
			t.Errorf("SplitService(%q) = (%q,%q), want (%q,%q)", in, group, method, want[0], want[1])
		}
	}

	bad := []string{"", "   ", "nodot", ".leading", "trailing.", "."}
	for _, in := range bad {
		if _, _, err := SplitService(in); err == nil {
			t.Errorf("SplitService(%q) should have failed", in)
		}
	}
}

func TestInvokeUnknownService(t *testing.T) {
	r := NewRegistry()
	resp := r.Invoke("Nope.Missing", json.RawMessage(`{}`))
	if resp == nil {
		t.Fatal("Invoke returned nil")
	}
	if resp.Success {
		t.Error("unknown service reported success")
	}
	if !strings.Contains(resp.Error, "service not found") {
		t.Errorf("unexpected error text: %q", resp.Error)
	}
}

func TestInvokeRejectsMalformedJSON(t *testing.T) {
	r := NewRegistry()
	r.Register("X.Y", func(json.RawMessage) (any, error) { return "should not run", nil })

	resp := r.Invoke("X.Y", json.RawMessage(`{oops`))
	if resp.Success {
		t.Error("malformed params reported success")
	}
	if !strings.Contains(resp.Error, "invalid params JSON") {
		t.Errorf("unexpected error text: %q", resp.Error)
	}
}

func TestInvokeEmptyParamsBecomesEmptyObject(t *testing.T) {
	r := NewRegistry()
	var seen string
	r.Register("X.Y", func(params json.RawMessage) (any, error) {
		seen = string(params)
		return map[string]int{"n": 1}, nil
	})

	for _, in := range []json.RawMessage{nil, {}, []byte("  ")} {
		seen = ""
		resp := r.Invoke("X.Y", in)
		if !resp.Success {
			t.Fatalf("params %q failed: %s", in, resp.Error)
		}
		if seen != "{}" {
			t.Errorf("params %q reached handler as %q, want {}", in, seen)
		}
	}
}

func TestInvokeConvertsHandlerError(t *testing.T) {
	r := NewRegistry()
	r.Register("X.Y", func(json.RawMessage) (any, error) { return nil, errors.New("boom") })

	resp := r.Invoke("X.Y", nil)
	if resp.Success {
		t.Error("handler error reported success")
	}
	if resp.Error != "boom" {
		t.Errorf("error = %q, want %q", resp.Error, "boom")
	}
	if resp.Result != nil {
		t.Errorf("error response carried a result: %v", resp.Result)
	}
}

func TestInvokeRecoversFromPanic(t *testing.T) {
	r := NewRegistry()
	r.Register("X.Y", func(json.RawMessage) (any, error) { panic("handler exploded") })

	resp := r.Invoke("X.Y", nil)
	if resp == nil {
		t.Fatal("Invoke returned nil after a panic: the C ABI would crash")
	}
	if resp.Success {
		t.Error("panicking handler reported success")
	}
	if !strings.Contains(resp.Error, "handler exploded") {
		t.Errorf("panic was not reported: %q", resp.Error)
	}
}

func TestInvokeErrVoidYieldsBareSuccess(t *testing.T) {
	r := NewRegistry()
	r.Register("X.Y", func(json.RawMessage) (any, error) { return nil, ErrVoid })

	resp := r.Invoke("X.Y", nil)
	if !resp.Success {
		t.Fatalf("ErrVoid should be a success: %s", resp.Error)
	}
	if resp.Result != nil {
		t.Errorf("ErrVoid carried a result: %v", resp.Result)
	}
}

func TestInvokeNilResultYieldsBareSuccess(t *testing.T) {
	r := NewRegistry()
	r.Register("X.Y", func(json.RawMessage) (any, error) { return nil, nil })

	resp := r.Invoke("X.Y", nil)
	if !resp.Success {
		t.Fatalf("nil result should be a success: %s", resp.Error)
	}
}

func TestRegisterRejectsDuplicatesAndBadNames(t *testing.T) {
	r := NewRegistry()
	r.Register("X.Y", func(json.RawMessage) (any, error) { return nil, nil })

	mustPanic(t, "duplicate route", func() {
		r.Register("X.Y", func(json.RawMessage) (any, error) { return nil, nil })
	})
	mustPanic(t, "unqualified name", func() {
		r.Register("NoDot", func(json.RawMessage) (any, error) { return nil, nil })
	})
	mustPanic(t, "nil handler", func() {
		r.Register("X.Z", nil)
	})
}

func TestNamesAreSorted(t *testing.T) {
	r := NewRegistry()
	for _, n := range []string{"Z.M", "A.M", "M.M"} {
		r.Register(n, func(json.RawMessage) (any, error) { return nil, nil })
	}
	got := r.Names()
	want := []string{"A.M", "M.M", "Z.M"}
	if len(got) != len(want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("got %v, want %v", got, want)
		}
	}
}

// TestHandleRequestAlwaysReturnsJSON is the guarantee the C ABI depends on:
// the UI must never receive an empty or non-JSON string.
func TestHandleRequestAlwaysReturnsJSON(t *testing.T) {
	r := NewRegistry()
	r.Register("X.Panic", func(json.RawMessage) (any, error) { panic("nope") })

	inputs := []struct{ service, params string }{
		{"", ""},
		{"X.Missing", "{}"},
		{"X.Panic", "{}"},
		{"X.Nope", "}{"},
	}
	for _, in := range inputs {
		out := HandleRequestWith(r, in.service, in.params)
		if out == "" {
			t.Fatalf("HandleRequestWith(%q,%q) returned an empty string", in.service, in.params)
		}
		var probe map[string]any
		if err := json.Unmarshal([]byte(out), &probe); err != nil {
			t.Fatalf("HandleRequestWith(%q,%q) returned non-JSON %q", in.service, in.params, out)
		}
		if _, ok := probe["success"]; !ok {
			t.Errorf("envelope from (%q,%q) has no success field: %s", in.service, in.params, out)
		}
	}
}

func TestDecodeParams(t *testing.T) {
	var dst struct {
		A int `json:"a"`
	}
	if err := DecodeParams(nil, &dst); err != nil {
		t.Errorf("nil params errored: %v", err)
	}
	if err := DecodeParams([]byte("  "), &dst); err != nil {
		t.Errorf("blank params errored: %v", err)
	}
	if err := DecodeParams([]byte(`{"a":7}`), &dst); err != nil {
		t.Errorf("valid params errored: %v", err)
	}
	if dst.A != 7 {
		t.Errorf("a = %d, want 7", dst.A)
	}
}

func mustPanic(t *testing.T, what string, f func()) {
	t.Helper()
	defer func() {
		if recover() == nil {
			t.Errorf("%s: expected a panic", what)
		}
	}()
	f()
}
