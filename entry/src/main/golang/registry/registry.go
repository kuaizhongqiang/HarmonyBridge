// Package registry is the feature-registry module.
//
// It contains no logic at all: every import below is blank, and their only
// purpose is to run the init() functions that register Xray's features,
// proxies and transports with the global factories. Without these imports the
// library compiles but every inbound/outbound in a user's config fails at
// runtime with "unknown transport protocol" or "failed to create proxy".
//
// The list mirrors upstream `main/distro/all` minus the CLI-only command tree
// (upstream's `main/commands/all`), because a mobile VPN client never shells
// out to `xray api ...`; leaving it out keeps a few megabytes of testing and
// command plumbing out of the .so.
//
// If a proxy or transport ever needs adding, add it HERE and nowhere else.
package registry

import (
	// Mandatory features. Without these three there is no working Xray.
	_ "github.com/xtls/xray-core/app/dispatcher"
	_ "github.com/xtls/xray-core/app/proxyman/inbound"
	_ "github.com/xtls/xray-core/app/proxyman/outbound"

	// Core services: DNS, logging, routing, statistics, policy.
	_ "github.com/xtls/xray-core/app/dns"
	_ "github.com/xtls/xray-core/app/dns/fakedns"
	_ "github.com/xtls/xray-core/app/log"
	_ "github.com/xtls/xray-core/app/metrics"
	_ "github.com/xtls/xray-core/app/policy"
	_ "github.com/xtls/xray-core/app/reverse"
	_ "github.com/xtls/xray-core/app/router"
	_ "github.com/xtls/xray-core/app/stats"

	// Observability (upstream marks it "developer preview" but it is cheap and
	// the UI wants latency/health data eventually).
	_ "github.com/xtls/xray-core/app/observatory"

	// Fixes the dependency cycle caused by core importing internet.
	_ "github.com/xtls/xray-core/transport/internet/tagged/taggedimpl"

	// Inbound and outbound proxies.
	_ "github.com/xtls/xray-core/proxy/blackhole"
	_ "github.com/xtls/xray-core/proxy/dns"
	_ "github.com/xtls/xray-core/proxy/dokodemo"
	_ "github.com/xtls/xray-core/proxy/freedom"
	_ "github.com/xtls/xray-core/proxy/http"
	_ "github.com/xtls/xray-core/proxy/loopback"
	_ "github.com/xtls/xray-core/proxy/shadowsocks"
	_ "github.com/xtls/xray-core/proxy/socks"
	_ "github.com/xtls/xray-core/proxy/trojan"
	_ "github.com/xtls/xray-core/proxy/vless/inbound"
	_ "github.com/xtls/xray-core/proxy/vless/outbound"
	_ "github.com/xtls/xray-core/proxy/vmess/inbound"
	_ "github.com/xtls/xray-core/proxy/vmess/outbound"
	_ "github.com/xtls/xray-core/proxy/wireguard"

	// Transports.
	_ "github.com/xtls/xray-core/transport/internet/grpc"
	_ "github.com/xtls/xray-core/transport/internet/httpupgrade"
	_ "github.com/xtls/xray-core/transport/internet/kcp"
	_ "github.com/xtls/xray-core/transport/internet/reality"
	_ "github.com/xtls/xray-core/transport/internet/splithttp"
	_ "github.com/xtls/xray-core/transport/internet/tcp"
	_ "github.com/xtls/xray-core/transport/internet/tls"
	_ "github.com/xtls/xray-core/transport/internet/udp"
	_ "github.com/xtls/xray-core/transport/internet/websocket"

	// Transport obfuscation headers.
	_ "github.com/xtls/xray-core/transport/internet/headers/http"
	_ "github.com/xtls/xray-core/transport/internet/headers/noop"

	// The JSON config loader, so core.LoadConfig("json", ...) works.
	_ "github.com/xtls/xray-core/main/json"
	// NOTE: proxy/tun is deliberately NOT imported here.
	//
	// Its backends are selected by build tag, and under GOOS=android (the only
	// option we have - Go has no ohos target) the *android* backend is chosen:
	// tun_android.go is tagged `android`, while tun_linux.go is tagged
	// `linux && !android` and is therefore dead code for us. The android
	// backend wraps a file descriptor taken from the xray.tun.fd env var with
	// gvisor fdbased, and whether that works on OHOS is UNVERIFIED.
	//
	// Importing it today would only pull in behaviour we cannot yet exercise,
	// so it is left out until the tun fd handoff is validated on a device.
	// See docs/design/core.md, section "tun fd handoff".
)
