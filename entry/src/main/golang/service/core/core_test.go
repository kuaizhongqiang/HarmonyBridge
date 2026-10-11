// Package core_test tests CoreService through its exported API only.
//
// It is an external test package (`package core_test`, not `package core`) for
// one reason: the catalogue guard below has to blank-import
// `harmonybridge/core/app`, and `app` imports this package. An internal test
// file could not do that without an import cycle.
//
// Everything here must run with CGO_ENABLED=0: main_test.go - which owns the
// cgo-only golden list - cannot be compiled on a Windows host without a C
// toolchain, and `go test ./...` on such a host is the only automated
// verification this repository has (see AGENT.md section 1).
package core_test

import (
	"encoding/json"
	"strings"
	"testing"

	// Blank import pulls in the whole service catalogue plus the Xray feature
	// registry, exactly like the real libcore.so. Without it the registry would
	// only contain the routes of the packages imported below.
	_ "harmonybridge/core/app"

	"harmonybridge/core/ipc"
	"harmonybridge/core/service/config"
	"harmonybridge/core/service/core"
)

// contractRoutes is the frozen catalogue of `docs/design/ipc-contract.md`
// section 4, in the lexicographic order `ipc.Registry.Names()` guarantees.
//
// It deliberately duplicates `expectedRoutes` in main_test.go: that file is
// behind `//go:build cgo` and therefore never runs on this host, while a
// missing or renamed route must fail *here* rather than on a device as an
// opaque "service not found". Keep both lists in sync when the contract moves.
var contractRoutes = []string{
	"ConfigService.Generate",
	"CoreService.RuntimeInfo",
	"CoreService.Start",
	"CoreService.Status",
	"CoreService.Stop",
	"LogService.Clear",
	"LogService.Tail",
	"PingService.SpeedTest",
	"PingService.Tcping",
	"ValidatorService.ValidateConfig",
	"VersionService.GetVersion",
}

// TestRegisteredCatalogueMatchesContract pins the registry to the contract.
// ipc.Default.Names() is sorted, so comparing element by element also proves
// the list above is in the right order.
func TestRegisteredCatalogueMatchesContract(t *testing.T) {
	got := ipc.Default.Names()
	want := contractRoutes

	if len(got) != len(want) {
		t.Fatalf("registered %d routes, want %d\n got: %v\nwant: %v", len(got), len(want), got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("route %d: got %q, want %q", i, got[i], want[i])
		}
	}
}

// TestContractRoutesAreSorted guards the list above itself: if someone appends
// a name in the wrong place, the failure above would be confusing.
func TestContractRoutesAreSorted(t *testing.T) {
	for i := 1; i < len(contractRoutes); i++ {
		if contractRoutes[i-1] >= contractRoutes[i] {
			t.Fatalf("contractRoutes is not sorted: %q >= %q at index %d",
				contractRoutes[i-1], contractRoutes[i], i)
		}
	}
}

// newService returns a Service that has never seen a Start call. Tests build
// their own instance instead of using the process-wide one so that they do not
// depend on the order the test binary happens to run them in.
func newService() *core.Service { return &core.Service{} }

func TestRuntimeInfoBeforeAnyStart(t *testing.T) {
	resp, err := newService().RuntimeInfo(&core.RuntimeInfoRequest{})
	if err != nil {
		t.Fatalf("RuntimeInfo failed: %v", err)
	}
	if resp.SocksPort != config.DefaultSocksPort {
		t.Errorf("socksPort = %d, want the config default %d", resp.SocksPort, config.DefaultSocksPort)
	}
	if resp.HTTPPort != config.DefaultHTTPPort {
		t.Errorf("httpPort = %d, want the config default %d", resp.HTTPPort, config.DefaultHTTPPort)
	}
	if resp.ConfigLocation != "" {
		t.Errorf("configLocation = %q, want empty: nothing has been loaded", resp.ConfigLocation)
	}
	if resp.Note == "" {
		t.Error("RuntimeInfo must explain the state instead of returning bare numbers")
	}
	// The UI keys "is it running" off this note, so it has to say so explicitly.
	if !strings.Contains(resp.Note, "尚未启动") {
		t.Errorf("note does not say the core is not running: %q", resp.Note)
	}
}

func TestRuntimeInfoAfterStartWithNoConfig(t *testing.T) {
	s := newService()
	if _, err := s.Start(&core.StartRequest{SocksPort: 12080, HTTPPort: 12081}); err != nil {
		t.Fatalf("diagnostic Start failed: %v", err)
	}

	resp, err := s.RuntimeInfo(&core.RuntimeInfoRequest{})
	if err != nil {
		t.Fatalf("RuntimeInfo failed: %v", err)
	}
	if resp.SocksPort != 12080 || resp.HTTPPort != 12081 {
		t.Errorf("ports = %d/%d, want the declared 12080/12081", resp.SocksPort, resp.HTTPPort)
	}
	if resp.ConfigLocation != "" {
		t.Errorf("configLocation = %q, want empty: no config was loaded", resp.ConfigLocation)
	}
	if !strings.Contains(resp.Note, "尚未加载过任何配置文件") {
		t.Errorf("note does not mention that no config was loaded: %q", resp.Note)
	}
}

func TestRuntimeInfoJSONFieldNames(t *testing.T) {
	blob, err := json.Marshal(&core.RuntimeInfoResponse{SocksPort: 10808, HTTPPort: 10809})
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	text := string(blob)
	for _, want := range []string{`"socksPort"`, `"httpPort"`} {
		if !strings.Contains(text, want) {
			t.Errorf("marshalled RuntimeInfo lacks %s: %s", want, text)
		}
	}
}

func TestStatusBeforeAnyStartHasNoFd(t *testing.T) {
	resp, err := newService().Status(&ipc.Void{})
	if err != nil {
		t.Fatalf("Status failed: %v", err)
	}
	if resp.Running {
		t.Error("a fresh Service reports a running core")
	}
	if resp.Version == "" {
		t.Error("Status did not report the core version")
	}

	// Section 5.6 removed the fd field; decoding into a struct cannot notice an
	// extra field coming back, so check the wire form directly.
	blob, err := json.Marshal(resp)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if strings.Contains(string(blob), `"fd"`) {
		t.Errorf("Status still reports a removed fd field: %s", blob)
	}
}

func TestStartWithEmptyConfigIsADiagnosticSuccess(t *testing.T) {
	resp, err := newService().Start(&core.StartRequest{Start: false})
	if err != nil {
		t.Fatalf("diagnostic Start returned an error: %v", err)
	}
	if resp.Started {
		t.Error("nothing can start without a config")
	}
	if resp.Wired {
		t.Error("wired must stay false: no local inbound is listening yet")
	}
	if resp.SocksPort != config.DefaultSocksPort || resp.HTTPPort != config.DefaultHTTPPort {
		t.Errorf("ports = %d/%d, want defaults %d/%d",
			resp.SocksPort, resp.HTTPPort, config.DefaultSocksPort, config.DefaultHTTPPort)
	}
	if len(resp.Notes) == 0 {
		t.Error("expected the response to explain what was skipped")
	}
	if !notesContain(resp.Notes, "wired") {
		t.Errorf("notes do not explain the wired=false, got %v", resp.Notes)
	}
}

func TestStartHonoursRequestedPortsAndIgnoresReservedFd(t *testing.T) {
	resp, err := newService().Start(&core.StartRequest{
		Fd:        42, // reserved: must be reported, never exported
		SocksPort: 11080,
		HTTPPort:  11081,
	})
	if err != nil {
		t.Fatalf("diagnostic Start returned an error: %v", err)
	}
	if resp.SocksPort != 11080 || resp.HTTPPort != 11081 {
		t.Errorf("ports = %d/%d, want the requested 11080/11081", resp.SocksPort, resp.HTTPPort)
	}
	if resp.Wired {
		t.Error("wired must stay false even when ports were supplied")
	}
	if !notesContain(resp.Notes, "保留字段") {
		t.Errorf("a caller that still sends fd must be told it is unused, got %v", resp.Notes)
	}
}

func TestStartRejectsInvalidPorts(t *testing.T) {
	resp, err := newService().Start(&core.StartRequest{SocksPort: -1, HTTPPort: 70000})
	if err != nil {
		t.Fatalf("diagnostic Start returned an error: %v", err)
	}
	if resp.SocksPort != config.DefaultSocksPort {
		t.Errorf("invalid socksPort was not replaced by the default: got %d", resp.SocksPort)
	}
	if resp.HTTPPort != config.DefaultHTTPPort {
		t.Errorf("invalid httpPort was not replaced by the default: got %d", resp.HTTPPort)
	}
	if len(resp.Notes) == 0 {
		t.Error("silently changing the caller's ports is exactly what must not happen")
	}
}

func TestStopResetsRuntimeInfo(t *testing.T) {
	s := newService()
	if _, err := s.Start(&core.StartRequest{SocksPort: 12080, HTTPPort: 12081}); err != nil {
		t.Fatalf("diagnostic Start failed: %v", err)
	}
	if _, err := s.Stop(&core.StopRequest{}); err != nil {
		t.Fatalf("Stop failed: %v", err)
	}

	resp, err := s.RuntimeInfo(&core.RuntimeInfoRequest{})
	if err != nil {
		t.Fatalf("RuntimeInfo failed: %v", err)
	}
	if resp.SocksPort != config.DefaultSocksPort || resp.HTTPPort != config.DefaultHTTPPort {
		t.Errorf("ports = %d/%d after Stop, want the defaults %d/%d",
			resp.SocksPort, resp.HTTPPort, config.DefaultSocksPort, config.DefaultHTTPPort)
	}
	if resp.ConfigLocation != "" {
		t.Errorf("configLocation = %q after Stop, want empty", resp.ConfigLocation)
	}
	if !strings.Contains(resp.Note, "尚未启动") {
		t.Errorf("note does not say the core is not running after Stop: %q", resp.Note)
	}
}

func notesContain(notes []string, want string) bool {
	for _, note := range notes {
		if strings.Contains(note, want) {
			return true
		}
	}
	return false
}
