/*
 * tun2socks_bridge.cpp - loads and drives the optional tun2socks data plane.
 *
 * Position in the data path (frozen contract: docs/design/ipc-contract.md §2):
 *
 *   TUN fd  (from VpnConnection.create, see VpnAbility.ets)
 *     -> tun2socks            <- this file loads and runs it
 *     -> 127.0.0.1:<socksPort>
 *     -> libcore.so (Xray-core local SOCKS inbound, routing rules apply here)
 *
 * The implementation is heiher/hev-socks5-tunnel: a pure-C, MIT-licensed
 * tun2socks. It is NOT linked here. Like libcore.so it is an external build
 * artifact (scripts/build-tun2socks.*) loaded with dlopen/dlsym, so a clone
 * that has not built it still compiles, still starts, and reports a precise
 * error instead of failing at link time.
 *
 * Why hev and not the Go (gVisor) tun2socks:
 *   * pure C -> needs no Go toolchain fork, so it sidesteps the whole B2
 *               question (Go has no GOOS=ohos target; see the header of
 *               scripts/build-core.ps1 for what that costs today);
 *   * MIT    -> the repository stays MIT + Xray-core (MPL-2.0). A GPL-licensed
 *               tun2socks would have broken that boundary
 *               (docs/00-技术路线可行性.md §9 step 3).
 *
 * Threading: hev_socks5_tunnel_main_from_str() blocks until
 * hev_socks5_tunnel_quit() is called or an error occurs, so Start() runs it on
 * a dedicated std::thread and returns immediately. Every entry point below is
 * called from the single JS thread, so Start/Stop/Stats are serialised by
 * construction; the mutex only guards the fields that the tunnel thread also
 * writes.
 *
 * UNVERIFIED: none of this has run on a device. Whether hev's backend works
 * against an OHOS vNIC fd is the open question U3.
 */
#include "tun2socks_bridge.h"

#include <dlfcn.h>

#include <cstddef>
#include <exception>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "native_util.h"

namespace {

// ---------------------------------------------------------------------------
// hev-socks5-tunnel public C ABI (its README, "C API" section):
//
//   int  hev_socks5_tunnel_main_from_str(const unsigned char *config_str,
//                                        unsigned int config_len, int tun_fd);
//   void hev_socks5_tunnel_quit(void);
//   void hev_socks5_tunnel_stats(size_t *tx_packets, size_t *tx_bytes,
//                                size_t *rx_packets, size_t *rx_bytes);
//
// main_from_str BLOCKS until quit() is called or an error occurs; it returns
// 0 on success and -1 on failure. quit()/stats() are loaded as optional
// symbols: a build without them still tunnels, it just cannot be stopped
// gracefully or report counters.
// ---------------------------------------------------------------------------
using MainFromStrFn = int (*)(const unsigned char *, unsigned int, int);
using QuitFn = void (*)(void);
using StatsFn = void (*)(size_t *, size_t *, size_t *, size_t *);

constexpr const char *kLibName = "libhevsocks5tun.so";

MainFromStrFn g_mainFromStr = nullptr;
QuitFn g_quit = nullptr;
StatsFn g_stats = nullptr;

bool g_resolved = false;
std::string g_libPath;    // the candidate dlopen succeeded on
std::string g_loadError;  // last dlerror() text, for diagnostics

/** Idle = no tunnel thread is alive. Running = main_from_str is on the wire. */
enum class State { Idle, Running };

State g_state = State::Idle;
std::thread g_thread;
int g_lastExitCode = 0;
std::string g_lastError;

/** Guards the mutable fields above that the tunnel thread also touches. */
std::mutex g_mutex;

std::string okEnvelope(const std::string &resultObject) {
    return std::string("{\"success\":true,\"result\":") + resultObject + "}";
}

std::string failEnvelope(const std::string &message) {
    return std::string("{\"success\":false,\"error\":\"") +
           bridgeutil::escapeJsonString(message) + "\"}";
}

std::string notAvailableError() {
    if (g_loadError.empty()) {
        return "libhevsocks5tun.so is not available to libbridge.so "
               "(build it with scripts/build-tun2socks.*)";
    }
    return std::string("libhevsocks5tun.so is not available: ") + g_loadError;
}

/**
 * Lazy one-shot dlopen + dlsym, mirroring the way napi_init.cpp loads
 * libcore.so. Not guarded by the mutex: only the JS thread calls in, exactly
 * as with the core loader.
 */
bool ensureResolved() {
    if (g_resolved) {
        return g_mainFromStr != nullptr;
    }
    g_resolved = true;

    std::vector<std::string> candidates{kLibName};
    const std::string dir = bridgeutil::ownDirectory();
    if (!dir.empty()) {
        candidates.push_back(dir + kLibName);
    }

    void *handle = nullptr;
    for (const std::string &candidate : candidates) {
        // RTLD_NOW: a half-initialised tunnel library is worse than a clean
        // failure with a precise message.
        handle = dlopen(candidate.c_str(), RTLD_NOW | RTLD_LOCAL);
        if (handle != nullptr) {
            g_libPath = candidate;
            break;
        }
        const char *err = dlerror();
        g_loadError = (err != nullptr) ? err : "unknown dlopen error";
    }
    if (handle == nullptr) {
        return false;
    }

    dlerror();
    g_mainFromStr = reinterpret_cast<MainFromStrFn>(dlsym(handle, "hev_socks5_tunnel_main_from_str"));
    if (const char *err = dlerror(); err != nullptr || g_mainFromStr == nullptr) {
        g_loadError = std::string("dlsym(hev_socks5_tunnel_main_from_str) failed: ") +
                      (err != nullptr ? err : "symbol is null");
        g_mainFromStr = nullptr;
        return false;
    }

    dlerror();
    g_quit = reinterpret_cast<QuitFn>(dlsym(handle, "hev_socks5_tunnel_quit"));
    if (dlerror() != nullptr) {
        g_quit = nullptr;
    }

    dlerror();
    g_stats = reinterpret_cast<StatsFn>(dlsym(handle, "hev_socks5_tunnel_stats"));
    if (dlerror() != nullptr) {
        g_stats = nullptr;
    }

    return true;
}

}  // namespace

namespace tun2socks {

std::string Start(const std::string &configYaml, int tunFd) {
    try {
        if (!ensureResolved()) {
            return failEnvelope(notAvailableError());
        }
        if (configYaml.empty()) {
            return failEnvelope("tun2socks config is empty");
        }
        if (tunFd < 0) {
            return failEnvelope("tun fd must be >= 0 (got " + std::to_string(tunFd) + ")");
        }

        {
            std::lock_guard<std::mutex> lock(g_mutex);
            if (g_state == State::Running) {
                return failEnvelope("tun2socks is already running; stop it first");
            }
        }

        // Reap the previous run's std::thread object before reusing it.
        if (g_thread.joinable()) {
            g_thread.join();
        }

        const std::string config = configYaml;  // owned by the tunnel thread
        const int fd = tunFd;

        std::lock_guard<std::mutex> lock(g_mutex);
        g_state = State::Running;
        g_lastExitCode = 0;
        g_lastError.clear();
        g_thread = std::thread([config, fd]() {
            const int rc = g_mainFromStr(
                reinterpret_cast<const unsigned char *>(config.data()),
                static_cast<unsigned int>(config.size()), fd);
            std::lock_guard<std::mutex> inner(g_mutex);
            g_lastExitCode = rc;
            if (rc != 0) {
                g_lastError = "hev_socks5_tunnel_main_from_str returned " + std::to_string(rc);
            }
            g_state = State::Idle;
        });

        return okEnvelope(std::string("{\"started\":true,\"tunFd\":") + std::to_string(tunFd) +
                          ",\"libPath\":\"" + bridgeutil::escapeJsonString(g_libPath) + "\"}");
    } catch (const std::exception &e) {
        // The lock_guard in the block above has already released the mutex by
        // the time control reaches here, so taking it again is safe.
        std::lock_guard<std::mutex> lock(g_mutex);
        g_state = State::Idle;
        return failEnvelope(std::string("could not start the tun2socks thread: ") + e.what());
    }
}

std::string Stop() {
    try {
        bool wasRunning = false;
        {
            std::lock_guard<std::mutex> lock(g_mutex);
            wasRunning = (g_state == State::Running) || g_thread.joinable();
        }
        if (!wasRunning) {
            return okEnvelope("{\"stopped\":true,\"wasRunning\":false}");
        }

        // If the library has no quit(), joining the thread would block forever.
        // Refuse instead of hanging the extension process.
        if (g_quit == nullptr) {
            return failEnvelope("libhevsocks5tun.so has no hev_socks5_tunnel_quit; "
                                "cannot stop the tunnel gracefully");
        }

        // quit() is meant to be called from another thread than the one that is
        // blocked in main_from_str - which is exactly this layout: the JS thread
        // calls quit(), the tunnel thread returns from main.
        g_quit();
        if (g_thread.joinable()) {
            g_thread.join();
        }

        // Surface why the tunnel thread returned. On a device this is the only
        // place that distinguishes "we stopped it" from "it died on its own",
        // which is the exact signal needed to debug U3.
        std::string lastError;
        int lastExitCode = 0;
        {
            std::lock_guard<std::mutex> lock(g_mutex);
            g_state = State::Idle;
            lastError = g_lastError;
            lastExitCode = g_lastExitCode;
        }
        return okEnvelope(std::string("{\"stopped\":true,\"wasRunning\":true,\"exitCode\":") +
                          std::to_string(lastExitCode) +
                          ",\"lastError\":\"" + bridgeutil::escapeJsonString(lastError) + "\"}");
    } catch (const std::exception &e) {
        return failEnvelope(std::string("stopping tun2socks failed: ") + e.what());
    }
}

std::string Stats() {
    try {
        if (!ensureResolved()) {
            return failEnvelope(notAvailableError());
        }
        if (g_stats == nullptr) {
            return failEnvelope("libhevsocks5tun.so has no hev_socks5_tunnel_stats");
        }

        size_t txPackets = 0;
        size_t txBytes = 0;
        size_t rxPackets = 0;
        size_t rxBytes = 0;
        g_stats(&txPackets, &txBytes, &rxPackets, &rxBytes);

        bool running = false;
        {
            std::lock_guard<std::mutex> lock(g_mutex);
            running = (g_state == State::Running);
        }

        // Counters are size_t emitted as JSON numbers. Past 2^53 a JS client
        // would lose precision, which is far outside any realistic traffic
        // count for this counter's lifetime.
        return okEnvelope(std::string("{\"running\":") + (running ? "true" : "false") +
                          ",\"txPackets\":" + std::to_string(txPackets) +
                          ",\"txBytes\":" + std::to_string(txBytes) +
                          ",\"rxPackets\":" + std::to_string(rxPackets) +
                          ",\"rxBytes\":" + std::to_string(rxBytes) + "}");
    } catch (const std::exception &e) {
        return failEnvelope(std::string("reading tun2socks stats failed: ") + e.what());
    }
}

std::string Available() {
    if (!g_resolved) {
        return "unknown";
    }
    if (g_mainFromStr != nullptr && !g_libPath.empty()) {
        return g_libPath;
    }
    return {};
}

}  // namespace tun2socks
