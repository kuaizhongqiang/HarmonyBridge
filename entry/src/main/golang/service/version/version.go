// Package version implements VersionService: it reports which Xray-core the
// native library was built against.
//
// This is the single most useful diagnostic in the whole bridge. The UI shows
// it in the about page, and it is what you check first when a config that
// works on desktop is rejected on device - a mismatch here explains almost
// every "unsupported protocol" surprise.
package version

import (
	"encoding/json"
	"runtime"
	"strings"

	xcore "github.com/xtls/xray-core/core"

	"harmonybridge/core/ipc"
)

// BridgeVersion is the version of the JSON/IPC bridge contract itself. Bump it
// when the envelope format or a service signature changes incompatibly, so the
// ArkTS layer can detect a stale libcore.so shipped alongside a newer UI.
const BridgeVersion = "1"

// Service is the VersionService handler.
type Service struct{}

// GetVersionRequest is empty; the service takes no parameters.
type GetVersionRequest struct{}

// Response is the payload returned by VersionService.GetVersion.
type Response struct {
	// Version is the raw Xray version string, e.g. "1.260327.0".
	Version string `json:"version"`

	// Semver is Version with any leading vendor prefix stripped.
	Semver string `json:"semver"`

	// Bridge is the IPC contract version.
	Bridge string `json:"bridge"`

	// Go is the Go runtime version the .so was compiled with. Useful when
	// diagnosing cross-compile problems.
	Go string `json:"go"`
}

// GetVersion implements VersionService.GetVersion.
func (s *Service) GetVersion(_ *GetVersionRequest) (*Response, error) {
	raw := xcore.Version()
	return &Response{
		Version: raw,
		Semver:  semver(raw),
		Bridge:  BridgeVersion,
		Go:      goVersion(),
	}, nil
}

// CoreVersion is a convenience accessor used by other services and by the
// design doc's diagnostics.
func CoreVersion() string { return xcore.Version() }

// goVersion reports the Go runtime the library was compiled with.
func goVersion() string { return runtime.Version() }

// semver strips a leading "v" or a vendor prefix such as "Xray ".
func semver(raw string) string {
	s := strings.TrimSpace(raw)
	if i := strings.LastIndex(s, " "); i >= 0 {
		s = s[i+1:]
	}
	return strings.TrimPrefix(s, "v")
}

var svc = &Service{}

func init() {
	ipc.Register("VersionService.GetVersion", func(params json.RawMessage) (any, error) {
		var req GetVersionRequest
		if err := ipc.DecodeParams(params, &req); err != nil {
			return nil, err
		}
		return svc.GetVersion(&req)
	})
}
