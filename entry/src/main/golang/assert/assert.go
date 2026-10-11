// Package assert holds the two small helpers used at the C ABI boundary.
//
// The rule the whole native core follows: a panic must never unwind through
// the C ABI, because cgo has no way to deliver a Go panic to the caller and
// the process simply dies. Panics are therefore allowed to happen deep inside
// a service (where they are cheap to write and easy to read) and are caught by
// the recovery in main.GoInvoke / ipc.Invoke, which converts them into a
// normal error envelope.
//
// Keeping the helpers here - rather than in each service - means the panic
// policy is stated in exactly one place.
package assert

import "fmt"

// Must panics if err is non-nil. Use it for conditions that can only be caused
// by a programming error (bad registration, impossible state), never for input
// validation.
func Must(err error) {
	if err != nil {
		panic(err)
	}
}

// Must2 returns v and panics if err is non-nil, so it can wrap a two-value
// call inline: `x := assert.Must2(json.Marshal(v))`.
func Must2[T any](v T, err error) T {
	Must(err)
	return v
}

// MustNoError panics with a formatted message if err is non-nil. It is the
// variant to use when the error alone lacks context.
func MustNoError(err error, format string, args ...any) {
	if err != nil {
		panic(fmt.Sprintf(format+": %v", append(args, err)...))
	}
}

// NotNil panics if v is nil. Handy for asserting that init() registration
// actually ran before the module is handed to the UI.
func NotNil(v any, what string) {
	if v == nil {
		panic("assert: " + what + " is nil")
	}
}
