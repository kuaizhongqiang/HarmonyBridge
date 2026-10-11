/*
 * tun2socks_bridge.h - loader / driver for the optional tun2socks data plane.
 *
 * Every function returns a JSON envelope string exactly like the Go core does:
 *   { "success": true,  "result": { ... } }
 *   { "success": false, "error": "human readable" }
 * so ArkTS has a single parsing path for both the core and the data plane.
 *
 * Available() is the exception: like CoreAvailable() it returns a bare string
 * (the loaded library path, "" when the load failed, or "unknown" before the
 * first attempt) because it is a diagnostic, not a call result.
 */
#ifndef HARMONYBRIDGE_TUN2SOCKS_BRIDGE_H
#define HARMONYBRIDGE_TUN2SOCKS_BRIDGE_H

#include <string>

namespace tun2socks {

/**
 * Start the tunnel on `tunFd`, using `configYaml` as the hev YAML config.
 *
 * Returns immediately: the blocking hev main loop runs on its own thread.
 * Fails (success:false) when the library is missing, when a tunnel is already
 * running, or when the arguments are obviously wrong.
 */
std::string Start(const std::string &configYaml, int tunFd);

/** Stop the tunnel. Idempotent: stopping an idle tunnel is a success. */
std::string Stop();

/** Read the tunnel's packet/byte counters (hev_socks5_tunnel_stats). */
std::string Stats();

/** Loaded library path, "" if the load failed, "unknown" before any attempt. */
std::string Available();

}  // namespace tun2socks

#endif  // HARMONYBRIDGE_TUN2SOCKS_BRIDGE_H
