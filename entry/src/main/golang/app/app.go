// Package app is the single place where every service and feature bundle is
// pulled into the binary.
//
// It exists so that the dependency graph is visible at a glance and so that
// the import ORDER is pinned:
//
//  1. harmonybridge/core/registry - the blank imports inside it run Xray's
//     feature/proxy/transport init() functions.
//  2. the service packages - their init() functions call ipc.Register, which
//     must not run before the Xray factories are available.
//
// Go guarantees that an imported package is fully initialised before the
// importer's init() runs, and within a file imports are initialised in the
// order they appear... for distinct packages. Relying on that ordering is
// fragile, so the blank import of registry is written FIRST and the reason is
// documented here rather than assumed.
//
// main.go blank-imports this package; nothing else should need to.
package app

import (
	// Step 1: Xray features, proxies and transports.
	_ "harmonybridge/core/registry"

	// Step 2: the service catalogue. Each of these registers one or more
	// "<Group>.<Method>" routes with the ipc registry.
	//
	// service/config comes first: unlike the others it links Xray's own config
	// loader (infra/conf) to build a full config.json from a node, so it must
	// be initialised after every protocol/transport factory is registered.
	_ "harmonybridge/core/service/config"
	_ "harmonybridge/core/service/core"
	_ "harmonybridge/core/service/log"
	_ "harmonybridge/core/service/ping"
	_ "harmonybridge/core/service/validator"
	_ "harmonybridge/core/service/version"
)
