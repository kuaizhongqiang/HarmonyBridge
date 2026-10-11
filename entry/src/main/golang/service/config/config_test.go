package config_test

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	xcore "github.com/xtls/xray-core/core"

	// 必须导入：它跑的是 Xray 各 proxy/transport 的 init()，没有它
	// xcore.LoadConfig 会以 "unknown protocol" 失败，测试就失去意义。
	_ "harmonybridge/core/registry"
	"harmonybridge/core/service/config"
)

// arktsNodeJSON 是 ArkTS 侧 model/ServerNode.ets#nodeToJson 的输出形状。
//
// 这串 JSON 同时是**双向契约的守卫**：任何一侧改了字段名，
// TestParseNodeMatchesArktsFieldNames 就会失败。
// realityPublicKey 是一个合法的 REALITY 客户端公钥：x25519 的 32 字节
// RawURLEncoding base64。内核会校验长度与编码（infra/conf/transport_internet.go
// 的 REALITYConfig.Build），随手写个 "PBK" 会让整份配置被拒。
const realityPublicKey = "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA"

const arktsNodeJSON = `{
  "id": "manual-1",
  "remarks": "HK 01",
  "protocol": "vless",
  "address": "hk01.example.com",
  "port": 443,
  "transport": "tcp",
  "security": "reality",
  "host": "",
  "path": "",
  "serviceName": "",
  "rawHeaderType": "none",
  "kcpHeaderType": "none",
  "xhttpMode": "auto",
  "xhttpExtra": "",
  "grpcMode": "gun",
  "finalmask": "",
  "sni": "www.apple.com",
  "fingerprint": "chrome",
  "alpn": "",
  "allowInsecure": false,
  "pinnedPeerCertSha256": "aabbccdd",
  "verifyPeerCertByName": "example.com",
  "disableSystemRoot": true,
  "echConfigList": "AEX+DQBB",
  "tlsCertificates": "[{\"usage\":\"verify\"}]",
  "publicKey": "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA",
  "shortId": "ab12",
  "spiderX": "/",
  "userId": "11111111-2222-3333-4444-555555555555",
  "alterId": 0,
  "securityCipher": "auto",
  "password": "secret",
  "flow": "xtls-rprx-vision",
  "muxEnabled": true
}`

// TestParseNodeMatchesArktsFieldNames 守住 ArkTS <-> Go 的字段名契约。
func TestParseNodeMatchesArktsFieldNames(t *testing.T) {
	node, err := config.ParseNode(arktsNodeJSON)
	if err != nil {
		t.Fatalf("ParseNode: %v", err)
	}

	checks := []struct {
		field string
		got   string
		want  string
	}{
		{"id", node.ID, "manual-1"},
		{"remarks", node.Remarks, "HK 01"},
		{"protocol", node.Protocol, "vless"},
		{"address", node.Address, "hk01.example.com"},
		{"transport", node.Transport, "tcp"},
		{"security", node.Security, "reality"},
		{"sni", node.SNI, "www.apple.com"},
		{"fingerprint", node.Fingerprint, "chrome"},
		{"publicKey", node.PublicKey, realityPublicKey},
		{"shortId", node.ShortID, "ab12"},
		{"spiderX", node.SpiderX, "/"},
		{"userId", node.UserID, "11111111-2222-3333-4444-555555555555"},
		{"securityCipher", node.SecurityCipher, "auto"},
		{"password", node.Password, "secret"},
		{"flow", node.Flow, "xtls-rprx-vision"},
		{"rawHeaderType", node.RawHeaderType, "none"},
		{"kcpHeaderType", node.KCPHeaderType, "none"},
		{"xhttpMode", node.XHTTPMode, "auto"},
		{"grpcMode", node.GRPCMode, "gun"},
		// allowInsecure 的替代字段（v2rayN TLS 面板 / 分享链接 pcs·vcn·ech）
		{"pinnedPeerCertSha256", node.PinnedPeerCertSha256, "aabbccdd"},
		{"verifyPeerCertByName", node.VerifyPeerCertByName, "example.com"},
		{"echConfigList", node.ECHConfigList, "AEX+DQBB"},
		{"tlsCertificates", node.TLSCertificates, `[{"usage":"verify"}]`},
	}
	for _, c := range checks {
		if c.got != c.want {
			t.Errorf("field %s: got %q want %q（ServerNode.ets 与 build.go 的 json tag 已经不一致）",
				c.field, c.got, c.want)
		}
	}
	if node.Port != 443 {
		t.Errorf("port: got %d want 443", node.Port)
	}
	if !node.MuxEnabled {
		t.Error("muxEnabled: got false want true")
	}
	if !node.DisableSystemRoot {
		t.Error("disableSystemRoot: got false want true")
	}
}

// node 构造一个只改必要字段的测试节点。
func node(protocol string) *config.Node {
	n := &config.Node{
		ID:             "test-1",
		Remarks:        "test",
		Protocol:       protocol,
		Address:        "example.com",
		Port:           443,
		Transport:      "tcp",
		Security:       "none",
		UserID:         "11111111-2222-3333-4444-555555555555",
		Password:       "secret",
		SecurityCipher: "auto",
	}
	return n
}

// mustMarshal 走一遍真实路径：Build -> json.MarshalIndent。
func mustMarshal(t *testing.T, n *config.Node, mode string) (string, []string) {
	t.Helper()
	cfg, notes, err := config.Build(n, config.Options{RoutingMode: mode})
	if err != nil {
		t.Fatalf("Build(%s): %v", n.Protocol, err)
	}
	text, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	return string(text), notes
}

// mustLoad 是"验收"：用 Xray 自己的 loader 读我们生成的配置。
func mustLoad(t *testing.T, text string) {
	t.Helper()
	if _, err := xcore.LoadConfig("json", bytes.NewReader([]byte(text))); err != nil {
		t.Fatalf("内核 loader 拒绝了生成的配置: %v\n---- 生成的配置 ----\n%s", err, text)
	}
}

// TestGeneratedConfigAcceptedByCoreLoader 是核心验收：
// 我们生成的每一份配置都必须能被内核自己的 loader 读进去。
func TestGeneratedConfigAcceptedByCoreLoader(t *testing.T) {
	reality := func() *config.Node {
		n := node("vless")
		n.Protocol = "vless"
		n.Security = "reality"
		n.SNI = "www.apple.com"
		n.Fingerprint = "chrome"
		n.PublicKey = realityPublicKey
		n.ShortID = "ab12"
		n.SpiderX = "/"
		n.Flow = "xtls-rprx-vision"
		return n
	}
	ws := func(p string) *config.Node {
		n := node(p)
		n.Transport = "ws"
		n.Security = "tls"
		n.Host = "cdn.example.com"
		n.Path = "/ws"
		n.SNI = "cdn.example.com"
		n.Fingerprint = "chrome"
		n.ALPN = "h2, http/1.1"
		return n
	}
	grpc := func() *config.Node {
		n := node("trojan")
		n.Transport = "grpc"
		n.Security = "tls"
		n.ServiceName = "GunService"
		n.GRPCMode = "multi"
		n.SNI = "grpc.example.com"
		return n
	}
	ss := func() *config.Node {
		n := node("shadowsocks")
		n.SecurityCipher = "aes-256-gcm"
		return n
	}
	socksNode := func() *config.Node {
		n := node("socks")
		n.UserID = "user"
		return n
	}
	httpNode := func() *config.Node {
		n := node("http")
		n.UserID = "user"
		return n
	}
	xhttp := func() *config.Node {
		n := node("vmess")
		n.Transport = "xhttp"
		n.Security = "tls"
		n.Path = "/x"
		n.XHTTPMode = "stream-one"
		n.XHTTPExtra = `{"xPaddingBytes":"100-1000","uplinkHTTPMethod":"POST"}`
		n.SNI = "x.example.com"
		return n
	}
	rawHTTP := func() *config.Node {
		n := node("vmess")
		n.RawHeaderType = "http"
		return n
	}
	kcpNode := func() *config.Node {
		n := node("vmess")
		n.Transport = "kcp"
		// 内核已删除 kcp header，这个值必须只产生一条 note，不能进配置
		n.KCPHeaderType = "srtp"
		return n
	}
	httpUpgrade := func() *config.Node {
		n := node("vless")
		n.Transport = "httpupgrade"
		n.Security = "tls"
		n.Host = "up.example.com"
		n.Path = "/up"
		n.SNI = "up.example.com"
		return n
	}

	table := []struct {
		name string
		node *config.Node
	}{
		{"vless+reality+tcp", reality()},
		{"vmess+ws+tls", ws("vmess")},
		{"vless+ws+tls", ws("vless")},
		{"trojan+grpc+tls", grpc()},
		{"shadowsocks+tcp", ss()},
		{"socks5", socksNode()},
		{"http-proxy", httpNode()},
		{"vmess+xhttp+tls", xhttp()},
		{"vmess+tcp+http-header", rawHTTP()},
		{"vmess+kcp", kcpNode()},
		{"vless+httpupgrade+tls", httpUpgrade()},
		{"parsed-from-arkts-json", nil},
	}

	for _, c := range table {
		c := c
		t.Run(c.name, func(t *testing.T) {
			n := c.node
			if n == nil {
				parsed, err := config.ParseNode(arktsNodeJSON)
				if err != nil {
					t.Fatalf("ParseNode: %v", err)
				}
				n = parsed
			}
			text, notes := mustMarshal(t, n, "rule")
			mustLoad(t, text)

			// 配置里**绝不能**有 tun 入站：数据面是「TUN -> tun2socks -> 本地 SOCKS」，
			// 内核对 tun 一无所知（裁决见 docs/design/ipc-contract.md §2）。
			//
			// 这不是"多余"而是**有害**：本版内核的 proxy/tun 在 xray.tun.fd 缺省时
			// 读到的是 "0"，会把 stdin 当成 TUN 交给 gVisor —— 重则
			// instance.Start() 直接失败，分流一起挂掉。
			if strings.Contains(text, `"protocol": "tun"`) {
				t.Errorf("生成的配置里出现了 tun 入站，内核启动时会去读 xray.tun.fd（默认 0=stdin）:\n%s", text)
			}
			// 本地 socks/http 入站必须在（它们才是真正的数据面入口）
			if !strings.Contains(text, `"tag": "socks-in"`) || !strings.Contains(text, `"tag": "http-in"`) {
				t.Errorf("生成的配置缺少 socks-in / http-in 入站")
			}
			// 嗅探必须挂在 socks 入站上，否则 geosite:cn 这类「按域名分流」规则
			// 拿不到域名，只能退化成按 IP 匹配（geoip:cn），"绕过大陆"会漏一片。
			if !strings.Contains(text, `"sniffing"`) {
				t.Errorf("生成的配置里没有 sniffing，按域名分流（geosite:cn）会失效")
			}
			// proxy 必须是 outbounds[0]：Xray 用第一个出站作为默认出站
			if !strings.Contains(text, `"tag": "proxy"`) {
				t.Errorf("生成的配置缺少 proxy 出站")
			}
			t.Logf("%s notes=%v", c.name, notes)
		})
	}
}

// TestKcpHeaderIsDroppedWithNote 断言被内核删除的 kcp 伪装类型
// 只产生一条 note，绝不会写进 kcpSettings。
func TestKcpHeaderIsDroppedWithNote(t *testing.T) {
	n := node("vmess")
	n.Transport = "kcp"
	n.KCPHeaderType = "wechat-video"

	text, notes := mustMarshal(t, n, "global")
	if strings.Contains(text, "wechat-video") {
		t.Errorf("kcp 伪装类型被写进了配置，内核会拒绝:\n%s", text)
	}
	if !hasNote(notes, "kcpHeaderType") {
		t.Errorf("缺少 kcp 伪装类型的 note，用户不会知道它被忽略了: %v", notes)
	}
}

// TestAllowInsecureIsDroppedWithNote 同上，针对已被删除的 tlsSettings.allowInsecure。
func TestAllowInsecureIsDroppedWithNote(t *testing.T) {
	n := node("vmess")
	n.Security = "tls"
	n.SNI = "a.example.com"
	n.AllowInsecure = true

	text, notes := mustMarshal(t, n, "global")
	if strings.Contains(text, "allowInsecure") {
		t.Errorf("allowInsecure 被写进了配置，内核会拒绝:\n%s", text)
	}
	if !hasNote(notes, "allowInsecure") {
		t.Errorf("缺少 allowInsecure 的 note: %v", notes)
	}
}

// TestTlsReplacementFieldsReachStreamSettings 守住安全层新增的替代字段。
//
// 背景：本版内核删除了 allowInsecure，官方替代是 pinnedPeerCertSha256（pcs）与
// verifyPeerCertByName（vcn）（infra/conf/transport_internet.go:709-716）。
// v2rayN 的 TLS 面板还额外写出 disableSystemRoot / echConfigList / certificates
// （Models/CoreConfigs/V2rayConfig.cs:342-346）。这四类字段必须真的落到
// tlsSettings 里，而不是像 allowInsecure 那样只停在 UI 上。
func TestTlsReplacementFieldsReachStreamSettings(t *testing.T) {
	// 内核要求 pcs 的每一项是 32 字节（64 位十六进制）sha256；长度不对会拒绝整份配置。
	pinned := strings.Repeat("0123456789abcdef", 4)
	n := node("vless")
	n.Security = "tls"
	n.SNI = "www.example.com"
	n.Transport = "ws"
	n.Host = "www.example.com"
	n.Path = "/ws"
	n.PinnedPeerCertSha256 = pinned
	n.VerifyPeerCertByName = "example.com,www.example.com"
	n.DisableSystemRoot = true
	n.ECHConfigList = "AEX+DQBB0gAgACC"

	text, _ := mustMarshal(t, n, "rule")
	wants := []string{
		`"pinnedPeerCertSha256": "` + pinned + `"`,
		`"verifyPeerCertByName": "example.com,www.example.com"`,
		`"disableSystemRoot": true`,
		`"echConfigList": "AEX+DQBB0gAgACC"`,
	}
	for _, want := range wants {
		if !strings.Contains(text, want) {
			t.Errorf("生成的配置里缺少 %s\n----\n%s", want, text)
		}
	}
	mustLoad(t, text)

	// 反向断言：长度非法的 pcs 必须被内核拒绝 —— 这样上面的"正向通过"才有意义
	// （否则可能是内核根本没读这个字段）。
	bad := node("vless")
	bad.Security = "tls"
	bad.SNI = "www.example.com"
	bad.PinnedPeerCertSha256 = "aabb"
	badText, _ := mustMarshal(t, bad, "rule")
	if _, err := xcore.LoadConfig("json", bytes.NewReader([]byte(badText))); err == nil {
		t.Error("长度非法的 pinnedPeerCertSha256 竟然被内核接受了，该字段的断言失去意义")
	}
}

// TestTlsCertificatesJSONIsValidated 断言 certificates 是透传但没有被"放羊"：
// 合法 JSON 数组能进配置，非法 JSON 在生成阶段就被挡住（不留给内核报错）。
func TestTlsCertificatesJSONIsValidated(t *testing.T) {
	good := node("vless")
	good.Security = "tls"
	good.SNI = "www.example.com"
	// 必须给 `certificate`（字符串形式）而不是 `certificateFile`：
	// 内核的 readFileOrString（infra/conf/transport_internet.go:568-576）在
	// 两者都为空时会直接报错，而填文件路径会在构建期真的去读盘。
	good.TLSCertificates = `[{"usage":"verify","certificate":["-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----"]}]`
	text, _ := mustMarshal(t, good, "global")
	if !strings.Contains(text, `"certificates"`) {
		t.Errorf("certificates 没有被写进 tlsSettings:\n%s", text)
	}
	mustLoad(t, text)

	bad := node("vless")
	bad.Security = "tls"
	bad.SNI = "www.example.com"
	bad.TLSCertificates = `{"usage":"verify"}`
	if _, _, err := config.Build(bad, config.Options{RoutingMode: "global"}); err == nil {
		t.Error("tlsCertificates 填了一个 JSON 对象（不是数组）却通过了生成，应该在生成阶段挡住")
	}
}

// TestRemovedFeaturesAreRejectedByCore 把"内核删了什么"变成可执行断言。
// 这些用例故意构造内核会拒绝的配置，用来证明我们上面的取舍不是猜的。
func TestRemovedFeaturesAreRejectedByCore(t *testing.T) {
	cases := []struct {
		name string
		cfg  string
	}{
		{
			name: "kcp header (mkcp header & seed removed)",
			cfg: `{"outbounds":[{"protocol":"vmess","settings":{"vnext":[{"address":"a.com","port":443,` +
				`"users":[{"id":"11111111-2222-3333-4444-555555555555","alterId":0,"security":"auto"}]}]},` +
				`"streamSettings":{"network":"kcp","kcpSettings":{"header":{"type":"srtp"}}}}]}`,
		},
		{
			name: "tls allowInsecure removed",
			cfg: `{"outbounds":[{"protocol":"vmess","settings":{"vnext":[{"address":"a.com","port":443,` +
				`"users":[{"id":"11111111-2222-3333-4444-555555555555","alterId":0,"security":"auto"}]}]},` +
				`"streamSettings":{"network":"tcp","security":"tls","tlsSettings":{"allowInsecure":true}}}]}`,
		},
		{
			name: "http/h2 transport removed",
			cfg: `{"outbounds":[{"protocol":"vmess","settings":{"vnext":[{"address":"a.com","port":443,` +
				`"users":[{"id":"11111111-2222-3333-4444-555555555555","alterId":0,"security":"auto"}]}]},` +
				`"streamSettings":{"network":"h2"}}]}`,
		},
		{
			name: "quic transport removed",
			cfg: `{"outbounds":[{"protocol":"vmess","settings":{"vnext":[{"address":"a.com","port":443,` +
				`"users":[{"id":"11111111-2222-3333-4444-555555555555","alterId":0,"security":"auto"}]}]},` +
				`"streamSettings":{"network":"quic"}}]}`,
		},
	}

	for _, c := range cases {
		c := c
		t.Run(c.name, func(t *testing.T) {
			if _, err := xcore.LoadConfig("json", bytes.NewReader([]byte(c.cfg))); err == nil {
				t.Fatalf("内核居然接受了这个配置，说明 build.go 里的删除判断已经过时")
			}
		})
	}
}

// TestRemovedTransportsAreRejectedBeforeGeneration 确认我们自己在生成前就挡住了。
func TestRemovedTransportsAreRejectedBeforeGeneration(t *testing.T) {
	for _, transport := range []string{"h2", "http", "h3", "quic"} {
		transport := transport
		t.Run(transport, func(t *testing.T) {
			n := node("vmess")
			n.Transport = transport
			if _, _, err := config.Build(n, config.Options{}); err == nil {
				t.Fatalf("transport %s 应该被拒绝（内核已删除）", transport)
			}
		})
	}
}

// TestRoutingModes 覆盖三种路由模式的关键差异。
//
// 这里的 GeoAssets 都是 false（仓库里还没有 geoip.dat / geosite.dat），
// 因此生成的配置必须能被内核装载，并且必须带一条降级提示。
func TestRoutingModes(t *testing.T) {
	n := node("vmess")

	direct, _ := mustMarshal(t, n, "direct")
	mustLoad(t, direct)
	if !strings.Contains(direct, `"outboundTag": "direct"`) {
		t.Errorf("direct 模式没有把流量改派给 direct 出站:\n%s", direct)
	}

	global, _ := mustMarshal(t, n, "global")
	mustLoad(t, global)
	if strings.Contains(global, "geoip:") || strings.Contains(global, "geosite:") {
		t.Errorf("global 模式不该出现 geo 规则:\n%s", global)
	}

	rule, ruleNotes := mustMarshal(t, n, "rule")
	mustLoad(t, rule)
	if strings.Contains(rule, "geoip:") || strings.Contains(rule, "geosite:") {
		t.Errorf("没有 geo 资源时不该生成 geo 规则（内核会拒绝整份配置）:\n%s", rule)
	}
	// 私有网段是显式 CIDR，不依赖 geo 资源
	if !strings.Contains(rule, "192.168.0.0/16") {
		t.Errorf("rule 模式缺少私有网段直连规则:\n%s", rule)
	}
	if !hasNote(ruleNotes, "geoip.dat") {
		t.Errorf("rule 模式缺少 geo 资源降级的提示: %v", ruleNotes)
	}
}

// ruleWithMode 是新增测试的公共入口：显式指定 bypassChina 与 geoAssets。
func ruleWithMode(t *testing.T, n *config.Node, bypassChina bool, geoAssets bool) (string, []string) {
	t.Helper()
	cfg, notes, err := config.Build(n, config.Options{
		RoutingMode: "rule",
		GeoAssets:   geoAssets,
		BypassChina: bypassChina,
	})
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	text, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	return string(text), notes
}

// TestBypassChinaWhitelistRules 断言「绕过大陆」开关拨到白名单时，
// 规则表真的变成了 v2rayN `Sample/custom_routing_white` 的那一套。
//
// 这一条正是此前缺失的：AppSettings.bypassChina 存在但从未传到生成器，
// 拨动开关行为完全不变（= 空开关）。
func TestBypassChinaWhitelistRules(t *testing.T) {
	text, notes := ruleWithMode(t, node("vmess"), true, false)
	mustLoad(t, text)

	must := []struct {
		want string
		why  string
	}{
		{`"network": "udp"`, "缺少「阻断 udp443」规则（QUIC 漏点）"},
		{`"outboundTag": "block"`, "缺少 block 出站规则"},
		{`"223.5.5.5"`, "缺少「中国公共 DNS IP 直连」规则（DNS 分流的前提）"},
		{`"119.29.29.29"`, "中国公共 DNS IP 列表不完整"},
		{`"domain:doh.pub"`, "缺少「中国公共 DNS 域名直连」规则"},
		{`"192.168.0.0/16"`, "缺少私有网段直连（无 geo 资源时应退回显式 CIDR）"},
		{`"dns-module"`, "缺少「DNS 模块 -> proxy」规则或 dns.tag"},
		{`"inboundTag"`, "DNS 规则没有用 inboundTag 命中 DNS 模块"},
	}
	for _, c := range must {
		if !strings.Contains(text, c.want) {
			t.Errorf("%s（找不到 %s）:\n%s", c.why, c.want, text)
		}
	}
	// 白名单**没有**「最终直连」兜底，未命中流量落到 outbounds[0]=proxy。
	if strings.Contains(text, `"0-65535"`) {
		t.Errorf("白名单模式不该出现「最终直连」兜底规则:\n%s", text)
	}
	if strings.Contains(text, "geoip:") || strings.Contains(text, "geosite:") {
		t.Errorf("没有 geo 资源时不该生成 geo 规则（内核会拒绝整份配置）:\n%s", text)
	}
	if !hasNote(notes, "geoip.dat") {
		t.Errorf("白名单降级时缺少提示: %v", notes)
	}
}

// TestBlacklistRulesWhenBypassChinaOff 断言关掉开关后换成黑名单语义
// （v2rayN `Sample/custom_routing_black`）：已知被墙走代理、其余直连。
func TestBlacklistRulesWhenBypassChinaOff(t *testing.T) {
	text, notes := ruleWithMode(t, node("vmess"), false, false)
	mustLoad(t, text)

	must := []struct {
		want string
		why  string
	}{
		{`"bittorrent"`, "缺少「绕过 bittorrent」规则"},
		{`"api.ip.sb"`, "缺少「出口 IP 查询走代理」规则"},
		{`"1.1.1.1"`, "缺少「海外公共 DNS IP 走代理」规则"},
		{`"domain:dns.google"`, "缺少「海外公共 DNS 域名走代理」规则"},
		{`"0-65535"`, "黑名单缺少「最终直连」兜底规则"},
	}
	for _, c := range must {
		if !strings.Contains(text, c.want) {
			t.Errorf("%s（找不到 %s）:\n%s", c.why, c.want, text)
		}
	}
	// 黑名单以「最终直连」收尾，任何追加规则都不可达，因此不该生成引用
	// dns.tag 的 routing 规则（"inboundTag" 只在白名单那条 DNS 规则里出现）。
	// 注意 dns.tag 本身两种模式都有，所以不能拿 "dns-module" 当判据。
	if strings.Contains(text, `"inboundTag"`) {
		t.Errorf("黑名单以「最终直连」收尾，引用 DNS 模块的规则不可达，不该生成:\n%s", text)
	}
	// 中国公共 DNS 的直连规则属于白名单，黑名单下不应出现。
	if strings.Contains(text, `"119.29.29.29"`) {
		t.Errorf("黑名单模式不该出现「中国公共 DNS 直连」规则:\n%s", text)
	}
	if !hasNote(notes, "geoip.dat") {
		t.Errorf("黑名单降级时缺少提示: %v", notes)
	}
}

// TestBypassChinaDefaultsToWhitelistWhenAbsent 守住请求字段缺失时的默认值。
//
// 这是有意的选择：ArkTS 侧 AppSettings.bypassChina 的默认值是 true（绕过大陆），
// 若请求里漏了这个字段就退化成黑名单，等于"用户以为在绕过大陆，实际不是"。
// 因此 GenerateRequest.BypassChina 是 *bool，nil 按 true 处理。
func TestBypassChinaDefaultsToWhitelistWhenAbsent(t *testing.T) {
	svc := &config.Service{}
	resp, err := svc.Generate(&config.GenerateRequest{
		RoutingMode: "rule",
		Extra:       arktsNodeJSON,
	})
	if err != nil {
		t.Fatalf("Generate: %v", err)
	}
	if !strings.Contains(resp.ConfigJSON, "223.5.5.5") {
		t.Errorf("缺省应走白名单（含中国公共 DNS 直连），实际:\n%s", resp.ConfigJSON)
	}
	if strings.Contains(resp.ConfigJSON, `"0-65535"`) {
		t.Errorf("缺省应走白名单（无最终直连兜底），实际:\n%s", resp.ConfigJSON)
	}

	// 显式传 false 时必须真的切成黑名单
	off := false
	resp, err = svc.Generate(&config.GenerateRequest{
		RoutingMode: "rule",
		Extra:       arktsNodeJSON,
		BypassChina: &off,
	})
	if err != nil {
		t.Fatalf("Generate(off): %v", err)
	}
	if !strings.Contains(resp.ConfigJSON, `"0-65535"`) {
		t.Errorf("显式传 bypassChina=false 应生成黑名单兜底规则:\n%s", resp.ConfigJSON)
	}
}

// TestDNSIsSplitOnlyWithGeoAssets 守住 DNS 国内外分流。
//
// 这是"绕过大陆"的另一个必要条件：以前固定用 1.1.1.1 / 8.8.8.8，配合
// domainStrategy=IPIfNonMatch，等于用国外 DNS 解析国内域名、再拿结果去匹配
// geoip:cn —— 规则必然失配。
func TestDNSIsSplitOnlyWithGeoAssets(t *testing.T) {
	// 资源缺位：只能给纯国外 DNS，并明确告知降级
	withoutGeo, notes := ruleWithMode(t, node("vmess"), true, false)
	mustLoad(t, withoutGeo)
	if strings.Contains(withoutGeo, "geosite:cn") {
		t.Errorf("无 geo 资源时不该在 DNS 里写 geosite:cn（内核会拒绝）:\n%s", withoutGeo)
	}
	if !strings.Contains(withoutGeo, "1.1.1.1") ||
		!strings.Contains(withoutGeo, "https://dns.google/dns-query") {
		t.Errorf("缺少兜底解析器:\n%s", withoutGeo)
	}
	if !hasNote(notes, "dns:") {
		t.Errorf("DNS 降级时缺少提示: %v", notes)
	}

	// 资源就位：应该出现「国内域名 -> 国内 DNS（expectIPs 约束）」这条定向解析器
	withGeo, notes := ruleWithMode(t, node("vmess"), true, true)
	if !strings.Contains(withGeo, `"geosite:cn"`) || !strings.Contains(withGeo, `"geoip:cn"`) {
		t.Errorf("有 geo 资源时 DNS 应做国内外分流:\n%s", withGeo)
	}
	if !strings.Contains(withGeo, `"223.5.5.5"`) {
		t.Errorf("DNS 分流缺少国内解析器 223.5.5.5:\n%s", withGeo)
	}
	if !strings.Contains(withGeo, `"expectIPs"`) || !strings.Contains(withGeo, `"skipFallback"`) {
		t.Errorf("DNS 分流缺少 expectIPs / skipFallback 约束:\n%s", withGeo)
	}
	// DoH 域名必须有静态 hosts，否则解析 dns.google 本身就是引导环
	if !strings.Contains(withGeo, `"dns.google"`) {
		t.Errorf("DNS 缺少 hosts 引导映射:\n%s", withGeo)
	}
	if hasNote(notes, "geoip.dat") {
		t.Errorf("资源就位时不该出现降级提示: %v", notes)
	}
}

// TestGeoEnabledConfigFailsWithoutGeoFiles 是本文件里最重要的一条负向断言：
// 它证明 Options.GeoAssets 这个开关是**载重**的，而不是保守起见。
//
// 生成 GeoAssets=true 的配置（含 geoip:/geosite:）后直接交给内核 loader，
// 本地没有 geoip.dat / geosite.dat，装载**必须失败**。若哪天它突然通过了，
// 说明 hasGeoAssets 的探测逻辑或 geo 规则已经名不副实，需要重新审视。
func TestGeoEnabledConfigFailsWithoutGeoFiles(t *testing.T) {
	text, _ := ruleWithMode(t, node("vmess"), true, true)
	if !strings.Contains(text, "geoip:private") && !strings.Contains(text, "geoip:cn") {
		t.Fatalf("GeoAssets=true 的配置里竟然没有 geoip: 规则，这个测试失去意义:\n%s", text)
	}
	_, err := xcore.LoadConfig("json", bytes.NewReader([]byte(text)))
	if err == nil {
		t.Fatal("含 geoip:/geosite: 的配置在没有 .dat 文件的目录下竟然加载成功；" +
			"要么本机真的存在 geoip.dat，要么 GeoAssets 的设计前提已经不成立")
	}
	if !strings.Contains(err.Error(), "geoip.dat") && !strings.Contains(err.Error(), "geosite.dat") {
		t.Fatalf("期望错误里提到 geoip.dat / geosite.dat，实际: %v", err)
	}
}

// TestGeoRulesWhenAssetsPresent 覆盖"资源补齐后"的分支。
//
// 注意这里**不做** mustLoad：装了 geoip:/geosite: 规则之后内核会去打开真实的
// geoip.dat / geosite.dat，本地没有这两个文件，装载必然失败 —— 这本身正是
// TestGeoRulesWithoutAssetsAreHardFailure 要断言的事实。
func TestGeoRulesWhenAssetsPresent(t *testing.T) {
	n := node("vmess")
	cfg, notes, err := config.Build(n, config.Options{RoutingMode: "rule", GeoAssets: true})
	if err != nil {
		t.Fatalf("Build: %v", err)
	}
	text, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if !strings.Contains(string(text), "geosite:cn") || !strings.Contains(string(text), "geoip:cn") {
		t.Errorf("有 geo 资源时应该生成按国家分流的规则:\n%s", text)
	}
	if hasNote(notes, "geoip.dat") {
		t.Errorf("资源就位时不应该再出现降级提示: %v", notes)
	}
}

// TestGeoRulesWithoutAssetsAreHardFailure 把"为什么必须自己列私有网段 CIDR"
// 变成可执行断言：缺 geoip.dat 时，geoip:private 会让**整份配置**失败，
// 而不是像注释里常说的那样"被忽略"。
func TestGeoRulesWithoutAssetsAreHardFailure(t *testing.T) {
	cfg := `{"routing":{"rules":[{"type":"field","ip":["geoip:private"],"outboundTag":"direct"}]},` +
		`"outbounds":[{"protocol":"freedom","tag":"direct"}]}`
	_, err := xcore.LoadConfig("json", bytes.NewReader([]byte(cfg)))
	if err == nil {
		t.Fatal("缺 geoip.dat 时 geoip:private 居然通过了，PrivateCIDRs 的注释需要更新")
	}
	if !strings.Contains(err.Error(), "geoip.dat") {
		t.Fatalf("期望错误里提到 geoip.dat，实际: %v", err)
	}
}

// TestHasGeoAssetsIsReported 确认 AssetsDir 探测结果会回显给 UI。
func TestHasGeoAssetsIsReported(t *testing.T) {
	svc := &config.Service{}

	// 目录不存在 -> false，且不报错
	resp, err := svc.Generate(&config.GenerateRequest{
		RoutingMode: "rule",
		Extra:       arktsNodeJSON,
		AssetDir:    t.TempDir(),
	})
	if err != nil {
		t.Fatalf("Generate: %v", err)
	}
	if resp.GeoAssets {
		t.Error("空目录不应被判定为资源就位")
	}

	// 只放一个文件 -> 仍然 false（两个都要）
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "geoip.dat"), []byte("x"), 0o600); err != nil {
		t.Fatalf("write geoip.dat: %v", err)
	}
	resp, err = svc.Generate(&config.GenerateRequest{
		RoutingMode: "rule",
		Extra:       arktsNodeJSON,
		AssetDir:    dir,
	})
	if err != nil {
		t.Fatalf("Generate: %v", err)
	}
	if resp.GeoAssets {
		t.Error("只有 geoip.dat 时不应判定为资源就位")
	}
}

// TestGenerateSelfCheck 走完整的服务入口，确认它自己会用内核 loader 自检。
func TestGenerateSelfCheck(t *testing.T) {
	svc := &config.Service{}

	resp, err := svc.Generate(&config.GenerateRequest{
		NodeID:      "manual-1",
		RoutingMode: "rule",
		Extra:       arktsNodeJSON,
	})
	if err != nil {
		t.Fatalf("Generate: %v", err)
	}
	if resp.ConfigJSON == "" {
		t.Fatal("Generate 返回了空配置")
	}
	if resp.SocksPort != config.DefaultSocksPort || resp.HTTPPort != config.DefaultHTTPPort {
		t.Errorf("端口与 Mock 不一致: socks=%d http=%d", resp.SocksPort, resp.HTTPPort)
	}
	if resp.OutboundTag != config.TagProxy {
		t.Errorf("outboundTag: got %q want %q", resp.OutboundTag, config.TagProxy)
	}
	if resp.Protocol != "vless" || resp.Security != "reality" {
		t.Errorf("回显字段不对: protocol=%q security=%q", resp.Protocol, resp.Security)
	}

	// 坏输入必须报错，而不是返回一份能跑但连不上的配置
	badCases := []struct {
		name string
		req  *config.GenerateRequest
	}{
		{"empty extra", &config.GenerateRequest{Extra: ""}},
		{"invalid json", &config.GenerateRequest{Extra: "{not json"}},
		{"no address", &config.GenerateRequest{Extra: `{"protocol":"vmess","address":"","port":443,` +
			`"userId":"11111111-2222-3333-4444-555555555555"}`}},
		{"port out of range", &config.GenerateRequest{Extra: `{"protocol":"vmess","address":"a.com","port":0,` +
			`"userId":"11111111-2222-3333-4444-555555555555"}`}},
		{"vmess without userId", &config.GenerateRequest{Extra: `{"protocol":"vmess","address":"a.com","port":443}`}},
		{"reality without publicKey", &config.GenerateRequest{Extra: `{"protocol":"vless","address":"a.com",` +
			`"port":443,"userId":"11111111-2222-3333-4444-555555555555","security":"reality"}`}},
		{"xhttpExtra not an object", &config.GenerateRequest{Extra: `{"protocol":"vmess","address":"a.com",` +
			`"port":443,"userId":"11111111-2222-3333-4444-555555555555","transport":"xhttp","xhttpExtra":"oops"}`}},
		{"bad grpc mode", &config.GenerateRequest{Extra: `{"protocol":"vmess","address":"a.com","port":443,` +
			`"userId":"11111111-2222-3333-4444-555555555555","transport":"grpc","grpcMode":"nope"}`}},
		{"bad raw header", &config.GenerateRequest{Extra: `{"protocol":"vmess","address":"a.com","port":443,` +
			`"userId":"11111111-2222-3333-4444-555555555555","rawHeaderType":"srtp"}`}},
	}
	for _, c := range badCases {
		c := c
		t.Run(c.name, func(t *testing.T) {
			if _, err := svc.Generate(c.req); err == nil {
				t.Fatal("期望报错，但 Generate 成功了")
			}
		})
	}
}

func hasNote(notes []string, substr string) bool {
	for _, n := range notes {
		if strings.Contains(n, substr) {
			return true
		}
	}
	return false
}
