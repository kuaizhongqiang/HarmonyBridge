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
