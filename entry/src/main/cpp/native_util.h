/*
 * native_util.h - tiny helpers shared by libbridge.so's translation units.
 *
 * Header-only on purpose: libbridge.so is the project's only native module and
 * these two helpers are all it needs. Keeping them inline avoids inventing a
 * third build artifact for ~30 lines of code.
 */
#ifndef HARMONYBRIDGE_NATIVE_UTIL_H
#define HARMONYBRIDGE_NATIVE_UTIL_H

#include <dlfcn.h>

#include <string>

namespace bridgeutil {

/**
 * Directory containing the currently executing shared object, with a trailing
 * slash; an empty string when it cannot be determined.
 *
 * Used to look for sibling .so files (libcore.so, libhevsocks5tun.so) next to
 * libbridge.so even when the loader's default search path does not include it.
 * hvigor installs every native library from entry/libs/<abi>/, so the sibling
 * lookup is the reliable one.
 */
inline std::string ownDirectory() {
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

/**
 * Escape a string for embedding in a hand-rolled JSON envelope.
 *
 * The native shim deliberately avoids pulling in a JSON library: every value it
 * emits is either a fixed literal or text that originates from the loader
 * (dlerror) or from Go. The characters handled below are the ones that can
 * actually occur in that text; everything else is passed through unchanged.
 */
inline std::string escapeJsonString(const std::string &value) {
    std::string escaped;
    escaped.reserve(value.size() + 8);
    for (char c : value) {
        switch (c) {
            case '"':  escaped += "\\\""; break;
            case '\\': escaped += "\\\\"; break;
            case '\n': escaped += "\\n";  break;
            case '\r': escaped += "\\r";  break;
            case '\t': escaped += "\\t";  break;
            default:   escaped.push_back(c);   break;
        }
    }
    return escaped;
}

}  // namespace bridgeutil

#endif  // HARMONYBRIDGE_NATIVE_UTIL_H
