/*
 * libbridge.so - NAPI C++ shim between the ArkTS UI and the Go proxy core.
 *
 * Call chain:
 *
 *   ArkTS  import bridge from 'libbridge.so'
 *          bridge.Invoke("CoreService.Start", '{"fd":42,...}')
 *     |
 *     v  napi (this file)
 *   bridge.Invoke()                       [bridge_api.cpp]
 *     |
 *     v  dlopen("libcore.so") + dlsym("GoInvoke")   (lazy, cached)
 *   char* GoInvoke(char* service, char* params)     [Go, //export]
 *     |
 *     v  JSON envelope {"success":..,"result":..,"error":..}
 *   Convert to a JS string, free() the C buffer, return.
 *
 * Memory contract
 * ---------------
 * The Go side returns a buffer it allocated with C.CString (i.e. malloc). This
 * shim copies it into a V8 string and then releases it with free(). That is
 * the correct pairing for cgo: C.malloc/C.CString is the system allocator, so
 * libc free() is the right deallocator and no cross-runtime bookkeeping is
 * needed. The Go library also exports GoFreeCString for callers that want the
 * deallocation to happen on the Go side; this shim additionally forwards that
 * symbol under the name GoFreeCString so the exported ABI matches the design
 * doc, but normal use never needs it.
 */

#include <dlfcn.h>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include "napi/native_api.h"

namespace {

/**
 * C ABI exported by libcore.so (Go, -buildmode=c-shared).
 *
 * The parameter names deliberately omit `const` so the declaration matches the
 * symbol exactly as cgo emits it: `char* GoInvoke(char*, char*)`.
 */
using GoInvokeFn = char *(*)(char *service, char *parameters);
using GoFreeCStringFn = void (*)(char *result);

/** Filenames tried, in order, when locating the Go core. */
constexpr const char *kCoreNames[] = {"libcore.so"};

/** Where the successfully loaded core came from, for diagnostics. */
std::string g_corePath;
/** dlerror() text captured at the point of failure. */
std::string g_loadError;

/** Resolved once, on first Invoke. Guarded implicitly: module init and all
 *  napi callbacks run on the single JS thread that loaded the module. */
GoInvokeFn g_goInvoke = nullptr;
GoFreeCStringFn g_goFreeCString = nullptr;
bool g_resolved = false;

/** Directory containing this module, so we can look for libcore.so next to
 *  ourselves even if the loader's search path does not include it. */
std::string ownDirectory() {
    Dl_info info{};
    if (dladdr(reinterpret_cast<void *>(&ownDirectory), &info) == 0 || info.dli_fname == nullptr) {
        return {};
    }
    std::string path(info.dli_fname);
    const auto slash = path.find_last_of('/');
    if (slash == std::string::npos) {
        return {};
    }
    return path.substr(0, slash + 1);
}

/** Try to open the core and resolve both symbols. Returns true on success. */
bool ensureCoreResolved() {
    if (g_resolved) {
        return g_goInvoke != nullptr;
    }
    g_resolved = true;

    std::vector<std::string> candidates;
    for (const char *name : kCoreNames) {
        candidates.emplace_back(name);
    }
    // Also try an absolute path beside libbridge.so, which is where hvigor
    // installs everything from entry/libs/<abi>/.
    const std::string dir = ownDirectory();
    if (!dir.empty()) {
        for (const char *name : kCoreNames) {
            candidates.push_back(dir + name);
        }
    }

    void *handle = nullptr;
    for (const std::string &candidate : candidates) {
        // RTLD_NOW resolves everything up front: a half-initialised Go runtime
        // is worse than a clean failure.
        handle = dlopen(candidate.c_str(), RTLD_NOW | RTLD_LOCAL);
        if (handle != nullptr) {
            g_corePath = candidate;
            break;
        }
        const char *err = dlerror();
        g_loadError = (err != nullptr) ? err : "unknown dlopen error";
    }

    if (handle == nullptr) {
        return false;
    }

    // Clear any stale error, then probe for the two symbols.
    dlerror();
    g_goInvoke = reinterpret_cast<GoInvokeFn>(dlsym(handle, "GoInvoke"));
    if (const char *err = dlerror(); err != nullptr || g_goInvoke == nullptr) {
        g_loadError = std::string("dlsym(GoInvoke) failed: ") + (err != nullptr ? err : "symbol is null");
        g_goInvoke = nullptr;
        return false;
    }

    dlerror();
    g_goFreeCString = reinterpret_cast<GoFreeCStringFn>(dlsym(handle, "GoFreeCString"));
    // GoFreeCString is optional: this shim frees the buffer itself.
    if (dlerror() != nullptr) {
        g_goFreeCString = nullptr;
    }

    return true;
}

/** The JSON envelope returned when the core cannot be reached at all. It is
 *  shaped exactly like a Go error envelope so ArkTS needs only one code path. */
std::string coreUnavailableEnvelope() {
    std::string msg = "libcore.so is not available to libbridge.so";
    if (!g_loadError.empty()) {
        msg += ": ";
        msg += g_loadError;
    } else {
        msg += " (dlopen succeeded but GoInvoke was not found)";
    }
    // Hand-rolled rather than pulling a JSON library in: the only character
    // that can appear in msg and needs escaping is the double quote and
    // backslash, both of which come from loader error text.
    std::string escaped;
    escaped.reserve(msg.size() + 8);
    for (char c : msg) {
        if (c == '"' || c == '\\') {
            escaped.push_back('\\');
        }
        escaped.push_back(c);
    }
    return std::string("{\"success\":false,\"error\":\"") + escaped + "\"}";
}

napi_value makeString(napi_env env, const std::string &value) {
    napi_value out = nullptr;
    napi_create_string_utf8(env, value.c_str(), value.size(), &out);
    return out;
}

/**
 * Copy a JS string argument into a std::string.
 * Returns false (and leaves `out` untouched) when the value is not a string.
 */
bool readStringArg(napi_env env, napi_value value, std::string &out, const char *what, std::string &why) {
    napi_valuetype type = napi_undefined;
    if (napi_typeof(env, value, &type) != napi_ok) {
        why = std::string(what) + " could not be inspected";
        return false;
    }
    // Accept a missing/undefined argument as an empty string: the Go side
    // treats an empty payload as "{}", which is a valid request.
    if (type == napi_undefined || type == napi_null) {
        out.clear();
        return true;
    }
    if (type != napi_string) {
        why = std::string(what) + " must be a string";
        return false;
    }
    size_t length = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &length) != napi_ok) {
        why = std::string(what) + " must be valid UTF-8";
        return false;
    }
    std::vector<char> buffer(length + 1, '\0');
    size_t written = 0;
    if (napi_get_value_string_utf8(env, value, buffer.data(), buffer.size(), &written) != napi_ok) {
        why = std::string(what) + " could not be read";
        return false;
    }
    out.assign(buffer.data(), written);
    return true;
}

/**
 * Invoke(service: string, paramsJson: string): string
 *
 * Always returns a string. Any failure - bad arguments, missing core, a Go
 * panic - comes back as a JSON envelope with success:false, so the ArkTS side
 * never has to handle a thrown exception or a C-level crash.
 */
napi_value Invoke(napi_env env, napi_callback_info info) {
    constexpr size_t kMaxArgs = 2;
    napi_value argv[kMaxArgs] = {nullptr, nullptr};
    size_t argc = kMaxArgs;
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    std::string service;
    std::string params;
    std::string why;

    if (argc > 0 && !readStringArg(env, argv[0], service, "the service name", why)) {
        return makeString(env, std::string("{\"success\":false,\"error\":\"") + why + "\"}");
    }
    if (argc > 1 && !readStringArg(env, argv[1], params, "the params JSON", why)) {
        return makeString(env, std::string("{\"success\":false,\"error\":\"") + why + "\"}");
    }

    if (service.empty()) {
        return makeString(env, R"({"success":false,"error":"the service name must not be empty"})");
    }

    if (!ensureCoreResolved()) {
        return makeString(env, coreUnavailableEnvelope());
    }

    // GoInvoke takes char*, matching the cgo-generated prototype. The vectors
    // are guaranteed to be NUL-terminated by std::string::c_str().
    std::vector<char> serviceBuf(service.begin(), service.end());
    serviceBuf.push_back('\0');
    std::vector<char> paramsBuf(params.begin(), params.end());
    paramsBuf.push_back('\0');
    // An empty JSON payload is normalised to "{}" so Go always sees valid JSON.
    if (params.empty()) {
        paramsBuf.clear();
        paramsBuf.push_back('{');
        paramsBuf.push_back('}');
        paramsBuf.push_back('\0');
    }

    char *result = nullptr;
    result = g_goInvoke(serviceBuf.data(), paramsBuf.data());

    if (result == nullptr) {
        return makeString(env, R"({"success":false,"error":"libcore.so returned a null response"})");
    }

    napi_value out = makeString(env, std::string(result));

    // Hand the buffer back before returning: either the Go-side deallocator or
    // libc free, whichever the core exported.
    if (g_goFreeCString != nullptr) {
        g_goFreeCString(result);
    } else {
        std::free(result);
    }
    return out;
}

/**
 * GoFreeCString(ptr: number): void
 *
 * Exported so the module's C ABI mirrors the design doc. It is not usable from
 * ArkTS (a JS number cannot hold a native pointer without BigInt gymnastics),
 * and Invoke already frees its own buffer; this exists for native callers and
 * for parity with the Go ABI.
 */
napi_value GoFreeCString(napi_env env, napi_callback_info info) {
    (void)env;
    (void)info;
    // Intentionally a no-op from ArkTS: see the doc comment above.
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

/** Expose whether the core loaded, without attempting to load it. */
napi_value CoreAvailable(napi_env env, napi_callback_info info) {
    (void)info;
    if (!g_resolved) {
        return makeString(env, "unknown");
    }
    if (g_goInvoke != nullptr) {
        return makeString(env, g_corePath);
    }
    return makeString(env, "");
}

}  // namespace

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"Invoke", nullptr, Invoke, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"GoFreeCString", nullptr, GoFreeCString, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"CoreAvailable", nullptr, CoreAvailable, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module bridgeModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "bridge",
    .nm_priv = ((void *)0),
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterBridgeModule(void) {
    napi_module_register(&bridgeModule);
}
