export const Invoke: (service: string, paramsJson: string) => string;

/**
 * Native-only helper: returns the absolute path of the loaded libcore.so, an
 * empty string when the load was attempted and failed, or "unknown" before any
 * Invoke call has triggered the lazy dlopen. Useful for the about/diagnostics
 * page.
 */
export const CoreAvailable: () => string;

/**
 * Exported for C-ABI parity with the Go core. It takes a raw pointer, so it is
 * not meaningfully callable from ArkTS; `Invoke` frees its own response buffer.
 */
export const GoFreeCString: (pointer: number) => void;

// ---------------------------------------------------------------------------
// tun2socks data plane
//
// Loaded lazily from libhevsocks5tun.so (heiher/hev-socks5-tunnel, MIT), which
// is an external build artifact - see scripts/build-tun2socks.*. It is NOT part
// of the Go core: the tunnel runs in this process on the vNIC fd and reaches the
// core over 127.0.0.1:<socksPort>. Frozen contract: docs/design/ipc-contract.md §2.
//
// All three call APIs return the same JSON envelope the Go core uses:
//   { "success": true,  "result": { ... } }
//   { "success": false, "error": "..." }
// so ArkTS only needs one parsing path. When the library is absent, every call
// succeeds as a *string* but reports success:false - nothing throws.
// ---------------------------------------------------------------------------

/**
 * Start the tunnel on a vNIC file descriptor.
 *
 * `configYaml` is the hev YAML config (tunnel / socks5 / misc sections); the
 * caller owns its content because the tunnel reads it from memory. `tunFd` is
 * the descriptor returned by VpnConnection.create(); the caller must keep its own
 * copy open for as long as the tunnel runs.
 *
 * Returns immediately - the blocking hev main loop runs on its own thread.
 * result on success: { started: true, tunFd: number, libPath: string }
 */
export const Tun2socksStart: (configYaml: string, tunFd: number) => string;

/**
 * Stop the tunnel. Idempotent: stopping an idle tunnel succeeds with
 * { stopped: true, wasRunning: false }.
 */
export const Tun2socksStop: () => string;

/**
 * Packet/byte counters from the tunnel library.
 * result: { running, txPackets, txBytes, rxPackets, rxBytes }
 */
export const Tun2socksStats: () => string;

/**
 * Diagnostic mirror of `CoreAvailable` for the data plane: the absolute path of
 * the loaded libhevsocks5tun.so, an empty string when the load was attempted and
 * failed, or "unknown" before the first attempt.
 */
export const Tun2socksAvailable: () => string;
