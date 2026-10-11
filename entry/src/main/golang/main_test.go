//go:build cgo

package main

import (
	"encoding/json"
	"strings"
	"testing"

	// Blank import pulls in the full service catalogue plus the Xray feature
	// registry, exactly as the real libcore.so does. If a service forgets to
	// call ipc.Register, the golden-list test below fails.
	_ "harmonybridge/core/app"
	"harmonybridge/core/ipc"
	// The local inbound ports live in the config package; the contract pins the
	// defaults, so the tests below assert against that single definition.
	serviceconfig "harmonybridge/core/service/config"
)

// expectedRoutes is the public contract of libcore.so. Adding or removing a
// route is a breaking change for the ArkTS layer, so it must be a deliberate
// edit to this list - which is the point of the test.
//
// ipc.Registry.Names() sorts lexicographically, so this slice must already be
// in that order; TestExpectedRoutesAreSorted proves it.
//
// The same list lives in service/core/core_test.go (contractRoutes), which is
// the copy that actually runs on a host without cgo. Keep them in sync.
var expectedRoutes = []string{
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

func TestExpectedRoutesAreSorted(t *testing.T) {
	for i := 1; i < len(expectedRoutes); i++ {
		if expectedRoutes[i-1] >= expectedRoutes[i] {
			t.Fatalf("expectedRoutes is not in lexicographic order: %q >= %q at index %d",
				expectedRoutes[i-1], expectedRoutes[i], i)
		}
	}
}

func TestServiceCatalogueIsComplete(t *testing.T) {
	got := ipc.Default.Names()
	want := append([]string(nil), expectedRoutes...)

	if len(got) != len(want) {
		t.Fatalf("registered %d routes, want %d\n got: %v\nwant: %v", len(got), len(want), got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("route %d: got %q, want %q", i, got[i], want[i])
		}
	}
}

func TestUnknownServiceReturnsErrorEnvelope(t *testing.T) {
	cases := []string{
		"",
		"   ",
		"NoSuchService.DoThing",
		"CoreService.NoSuchMethod",
		"NotAQualifiedName",
		"TrailingDot.",
		".LeadingDot",
	}

	for _, service := range cases {
		raw := invoke(service, "{}")

		var env struct {
			Success bool   `json:"success"`
			Error   string `json:"error"`
		}
		if err := json.Unmarshal([]byte(raw), &env); err != nil {
			t.Fatalf("invoke(%q) returned non-JSON %q: %v", service, raw, err)
		}
		if env.Success {
			t.Errorf("invoke(%q) unexpectedly succeeded: %s", service, raw)
		}
		if env.Error == "" {
			t.Errorf("invoke(%q) failed without an error message: %s", service, raw)
		}
	}
}

func TestMalformedParamsAreRejected(t *testing.T) {
	for _, params := range []string{"", "not json", "{unclosed", "[1,2"} {
		raw := invoke("VersionService.GetVersion", params)

		var env struct {
			Success bool            `json:"success"`
			Result  json.RawMessage `json:"result"`
			Error   string          `json:"error"`
		}
		if err := json.Unmarshal([]byte(raw), &env); err != nil {
			t.Fatalf("invoke with params %q returned non-JSON %q: %v", params, raw, err)
		}
		// "" must be accepted as "no parameters" so the UI can omit them.
		if params == "" {
			if !env.Success {
				t.Errorf(`invoke with empty params should succeed, got %s`, raw)
			}
			continue
		}
		if env.Success {
			t.Errorf("invoke with params %q should have failed, got %s", params, raw)
		}
	}
}

func TestVersionServiceReportsXrayVersion(t *testing.T) {
	raw := invoke("VersionService.GetVersion", "{}")

	var env struct {
		Success bool `json:"success"`
		Result  struct {
			Version string `json:"version"`
			Semver  string `json:"semver"`
			Bridge  string `json:"bridge"`
			Go      string `json:"go"`
		} `json:"result"`
		Error string `json:"error"`
	}
	if err := json.Unmarshal([]byte(raw), &env); err != nil {
		t.Fatalf("non-JSON response %q: %v", raw, err)
	}
	if !env.Success {
		t.Fatalf("GetVersion failed: %s", env.Error)
	}
	if env.Result.Version == "" {
		t.Error("version is empty: xray-core did not link correctly")
	}
	if env.Result.Bridge == "" {
		t.Error("bridge contract version is empty")
	}
	if !strings.HasPrefix(env.Result.Go, "go1.") {
		t.Errorf("go runtime version looks wrong: %q", env.Result.Go)
	}
	t.Logf("xray-core=%s semver=%s bridge=%s go=%s",
		env.Result.Version, env.Result.Semver, env.Result.Bridge, env.Result.Go)
}

func TestValidatorAcceptsMinimalConfig(t *testing.T) {
	// The smallest config Xray will accept: one freedom outbound.
	cfg := `{"outbounds":[{"protocol":"freedom","settings":{}}]}`

	raw := invoke("ValidatorService.ValidateConfig",
		`{"config":`+jsonString(cfg)+`,"configPath":"test.json"}`)

	var env struct {
		Success bool `json:"success"`
		Result  struct {
			Valid  bool     `json:"valid"`
			Errors []string `json:"errors"`
		} `json:"result"`
		Error string `json:"error"`
	}
	if err := json.Unmarshal([]byte(raw), &env); err != nil {
		t.Fatalf("non-JSON response %q: %v", raw, err)
	}
	if !env.Success {
		t.Fatalf("ValidateConfig failed: %s", env.Error)
	}
	if !env.Result.Valid {
		t.Fatalf("minimal freedom config rejected: %v", env.Result.Errors)
	}
}

func TestValidatorRejectsGarbage(t *testing.T) {
	raw := invoke("ValidatorService.ValidateConfig",
		`{"config":"this is not json","configPath":"bad.json"}`)

	var env struct {
		Success bool `json:"success"`
		Result  struct {
			Valid  bool     `json:"valid"`
			Errors []string `json:"errors"`
		} `json:"result"`
	}
	if err := json.Unmarshal([]byte(raw), &env); err != nil {
		t.Fatalf("non-JSON response %q: %v", raw, err)
	}
	if !env.Success {
		t.Fatalf("ValidateConfig should report invalidity, not fail: %s", raw)
	}
	if env.Result.Valid {
		t.Fatal("garbage config was reported as valid")
	}
	if len(env.Result.Errors) == 0 {
		t.Fatal("invalid config produced no error messages")
	}
}

func TestValidatorRejectsUnknownProtocol(t *testing.T) {
	cfg := `{"outbounds":[{"protocol":"definitely-not-a-protocol","settings":{}}]}`
	raw := invoke("ValidatorService.ValidateConfig", `{"config":`+jsonString(cfg)+`}`)

	var env struct {
		Success bool `json:"success"`
		Result  struct {
			Valid  bool     `json:"valid"`
			Errors []string `json:"errors"`
		} `json:"result"`
	}
	if err := json.Unmarshal([]byte(raw), &env); err != nil {
		t.Fatalf("non-JSON response %q: %v", raw, err)
	}
	if env.Result.Valid {
		t.Fatal("unknown protocol was reported as valid: the feature registry is not wired up")
	}
}

func TestCoreStatusDoesNotPanic(t *testing.T) {
	raw := invoke("CoreService.Status", "{}")

	var env struct {
		Success bool `json:"success"`
		Result  struct {
			Running bool   `json:"running"`
			Version string `json:"version"`
		} `json:"result"`
	}
	if err := json.Unmarshal([]byte(raw), &env); err != nil {
		t.Fatalf("non-JSON response %q: %v", raw, err)
	}
	if !env.Success {
		t.Fatalf("CoreService.Status failed: %s", raw)
	}
	if env.Result.Running {
		t.Error("a freshly loaded library reports a running core")
	}
	if env.Result.Version == "" {
		t.Error("status did not report the core version")
	}

	// Contract section 5.6 removed "fd" from Status; a struct decode cannot
	// notice an extra field, so check the wire form.
	assertNoJSONKey(t, raw, "fd")
}

func TestCoreRuntimeInfoReportsPortsWithoutPretendingToListen(t *testing.T) {
	// svc is process-wide, so normalise the state first: this test asserts the
	// pre-Start defaults and must not depend on which test ran before it.
	stopCore(t)

	raw := invoke("CoreService.RuntimeInfo", "{}")

	var env struct {
		Success bool `json:"success"`
		Result  struct {
			SocksPort      int    `json:"socksPort"`
			HTTPPort       int    `json:"httpPort"`
			ConfigLocation string `json:"configLocation"`
			Note           string `json:"note"`
		} `json:"result"`
		Error string `json:"error"`
	}
	if err := json.Unmarshal([]byte(raw), &env); err != nil {
		t.Fatalf("non-JSON response %q: %v", raw, err)
	}
	if !env.Success {
		t.Fatalf("CoreService.RuntimeInfo failed: %s", env.Error)
	}
	if env.Result.SocksPort != serviceconfig.DefaultSocksPort {
		t.Errorf("socksPort = %d, want %d", env.Result.SocksPort, serviceconfig.DefaultSocksPort)
	}
	if env.Result.HTTPPort != serviceconfig.DefaultHTTPPort {
		t.Errorf("httpPort = %d, want %d", env.Result.HTTPPort, serviceconfig.DefaultHTTPPort)
	}
	if env.Result.ConfigLocation != "" {
		t.Errorf("configLocation = %q, want empty before any Start", env.Result.ConfigLocation)
	}
	if env.Result.Note == "" {
		t.Error("RuntimeInfo returned bare numbers without explaining that nothing is listening")
	}
}

func TestCoreStartWithNoConfigIsADiagnosticSuccess(t *testing.T) {
	// See the note in the RuntimeInfo test: svc is process-wide, so start from a
	// stopped state before asserting the defaults.
	stopCore(t)

	raw := invoke("CoreService.Start", `{"fd":0}`)

	var env struct {
		Success bool `json:"success"`
		Result  struct {
			Started   bool     `json:"started"`
			Wired     bool     `json:"wired"`
			SocksPort int      `json:"socksPort"`
			HTTPPort  int      `json:"httpPort"`
			Notes     []string `json:"notes"`
		} `json:"result"`
		Error string `json:"error"`
	}
	if err := json.Unmarshal([]byte(raw), &env); err != nil {
		t.Fatalf("non-JSON response %q: %v", raw, err)
	}
	if !env.Success {
		t.Fatalf("CoreService.Start with no config should succeed as a diagnostic: %s", env.Error)
	}
	if env.Result.Started {
		t.Error("nothing should have started without a config")
	}
	if env.Result.Wired {
		t.Error("Wired must never be true: no local SOCKS/HTTP inbound is listening yet")
	}
	if env.Result.SocksPort != serviceconfig.DefaultSocksPort {
		t.Errorf("socksPort = %d, want the default %d", env.Result.SocksPort, serviceconfig.DefaultSocksPort)
	}
	if env.Result.HTTPPort != serviceconfig.DefaultHTTPPort {
		t.Errorf("httpPort = %d, want the default %d", env.Result.HTTPPort, serviceconfig.DefaultHTTPPort)
	}
	if len(env.Result.Notes) == 0 {
		t.Error("expected the response to explain what was skipped")
	}

	// Contract section 5.1 removed "fd" from the Start result.
	assertNoJSONKey(t, raw, "fd")
}

// assertNoJSONKey fails when the response envelope's result object still
// carries key. Decoding into a struct cannot detect an unexpected extra field,
// which is exactly how a removed contract field creeps back in.
func assertNoJSONKey(t *testing.T, raw, key string) {
	t.Helper()

	var env struct {
		Result map[string]json.RawMessage `json:"result"`
	}
	if err := json.Unmarshal([]byte(raw), &env); err != nil {
		t.Fatalf("non-JSON response %q: %v", raw, err)
	}
	if _, ok := env.Result[key]; ok {
		t.Errorf("result still contains the removed field %q: %s", key, raw)
	}
}

// stopCore clears the process-wide CoreService state, failing the test when
// Stop itself reports failure. svc is shared by every test in this package, so
// tests that assert defaults must call it first.
func stopCore(t *testing.T) {
	t.Helper()

	raw := invoke("CoreService.Stop", "{}")
	var env struct {
		Success bool   `json:"success"`
		Error   string `json:"error"`
	}
	if err := json.Unmarshal([]byte(raw), &env); err != nil {
		t.Fatalf("non-JSON response %q: %v", raw, err)
	}
	if !env.Success {
		t.Fatalf("CoreService.Stop failed: %s", env.Error)
	}
}

func TestCoreStopIsIdempotent(t *testing.T) {
	for i := 0; i < 3; i++ {
		raw := invoke("CoreService.Stop", "{}")
		var env struct {
			Success bool `json:"success"`
		}
		if err := json.Unmarshal([]byte(raw), &env); err != nil {
			t.Fatalf("non-JSON response %q: %v", raw, err)
		}
		if !env.Success {
			t.Fatalf("Stop call %d failed: %s", i+1, raw)
		}
	}
}

// jsonString encodes s as a JSON string literal so table tests can build
// request payloads without escaping mistakes.
func jsonString(s string) string {
	b, err := json.Marshal(s)
	if err != nil {
		panic(err)
	}
	return string(b)
}
