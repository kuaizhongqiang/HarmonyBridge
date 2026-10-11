// Command core builds libcore.so: the Go proxy core of the HarmonyOS client,
// compiled with -buildmode=c-shared for aarch64-linux-ohos.
//
// It exports exactly two C symbols:
//
//	//export GoInvoke
//	func GoInvoke(service, parameters *C.char) *C.char
//	//export GoFreeCString
//	func GoFreeCString(result *C.char)
//
// GoInvoke takes a service name ("CoreService.Start") plus a JSON parameter
// string and returns a JSON envelope
// {"success":bool,"result":object,"error":string}. The caller must hand the
// returned pointer back to GoFreeCString (or libc free) exactly once.
//
// Why the command is called `core` and the module is called harmonybridge/core
// is explained in README.md; briefly, GOPATH-style layouts make a module named
// after the artifact ("core") the least surprising choice for the build script.
//
// This package must remain importable with CGO_ENABLED=0 on the host so that
// `go build ./...` and `go vet ./...` work on a developer machine without an
// OHOS toolchain. That is what the build tag below is for: it compiles the
// pure-Go half everywhere, and the cgo half only when cgo is available.
//
//go:build cgo

package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"encoding/json"
	"unsafe"

	// Blank import wires the whole service catalogue and the Xray feature
	// registry into the binary. It must be here - removing it would produce a
	// libcore.so with no services and no proxies.
	_ "harmonybridge/core/app"
	"harmonybridge/core/assert"
	"harmonybridge/core/ipc"
)

// main is required by package main but is never called: a c-shared library
// runs its Go runtime initialisation on library load, not via main.
func main() {}

// GoInvoke dispatches one request across the C ABI and returns a malloc'd
// JSON envelope.
//
// The returned pointer is owned by the caller and must be released with
// GoFreeCString (or free(3)). This function never returns nil and never
// panics: a panic unwinding through the C ABI would abort the process with no
// way for the UI to show a message, so it is caught here and converted into an
// error envelope.
//
//export GoInvoke
func GoInvoke(service, parameters *C.char) (result *C.char) {
	defer func() {
		if rec := recover(); rec != nil {
			// Build the envelope by hand: a panic may have left the state
			// needed by the normal path unusable, and json.Marshal itself
			// could be the thing that failed.
			result = C.CString("{\"success\":false,\"error\":\"panic in native core (see libcore logs)\"}")
		}
	}()

	if service == nil {
		return C.CString(`{"success":false,"error":"service name is null"}`)
	}

	name := C.GoString(service)

	// A nil parameter pointer is the same as "no arguments".
	params := "{}"
	if parameters != nil {
		if s := C.GoString(parameters); s != "" {
			params = s
		}
	}

	return C.CString(invoke(name, params))
}

// invoke is the recover-free implementation, split out so it can be unit
// tested on the host without touching cgo types.
func invoke(service, paramsJSON string) string {
	// Reject an unparseable service name early: ipc would report it anyway,
	// but doing it here keeps the message identical to the pure-Go path.
	if _, _, err := ipc.SplitService(service); err != nil {
		return mustEnvelope(ipc.Fail(err))
	}

	// An empty parameters string means "no arguments", not "bad JSON". This has
	// to be normalised HERE, not only in the cgo wrapper: GoInvoke maps a nil or
	// empty *C.char to "{}" already, so handling it there alone made the C entry
	// point and this function disagree about the same input - something the
	// contract (docs/design/ipc-contract.md 3.3: the return value is always
	// valid JSON and the caller may omit parameters) requires them to agree on.
	// A whitespace-only string needs no special case: the json.Valid check below
	// rejects it exactly like any other non-JSON payload.
	if paramsJSON == "" {
		paramsJSON = "{}"
	}

	// Guard against a parameters string that is not JSON at all; ipc.Invoke
	// would also catch this, but failing here avoids a malformed payload
	// reaching the handler-adapters.
	if !json.Valid([]byte(paramsJSON)) {
		return mustEnvelope(ipc.Failf("parameters are not valid JSON"))
	}

	return ipc.HandleRequest(service, paramsJSON)
}

// mustEnvelope marshals a response.
//
// Marshalling a *ipc.Response cannot fail in practice, and if it ever does
// there is no sensible envelope to report it with - so this panics and lets
// GoInvoke's recover turn it into a generic error envelope. That is the entire
// reason the assert helper exists.
func mustEnvelope(resp *ipc.Response) string {
	return string(assert.Must2(json.Marshal(resp)))
}

// GoFreeCString releases a string previously returned by GoInvoke.
//
// Equivalent to free(3): the buffer was allocated by C.CString, which uses the
// system allocator. Calling it twice, or on a pointer this library did not
// return, is undefined behaviour.
//
//export GoFreeCString
func GoFreeCString(result *C.char) {
	if result == nil {
		return
	}
	C.free(unsafe.Pointer(result))
}
