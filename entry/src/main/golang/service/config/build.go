// Package config implements ConfigService.Generate:它把 ArkTS 侧的节点 JSON
// 变成一份 Xray-core 能直接加载的 config.json。
//
// 为什么生成放在 Go 侧（而不是 core.md §7 提到的 ArkTS 侧 CoreConfigManager）：
//
//  1. 只有 Go 侧能链接 Xray 自己的 loader（infra/conf + registry），因此可以
//     在**同一个测试**里完成「生成 -> 用内核的 loader 验收」的闭环。在 OHOS
//     工具链打通之前，go test 是唯一的自动化验证手段，这个闭环的价值高于
//     "ArkTS 侧写字符串更省事"。
//  2. 内核删了哪些特性（h2/quic/allowInsecure/kcp seed）只有它自己的源码知道；
//     把这些判断放在 Go 侧，出错时能给出精确原因，而不是让用户看到一个
//     "failed to create outbound"。
//
// 生成结果是**文本**，不落盘：沙箱路径（filesDir）只有 ArkTS 知道，
// 而且保持本函数纯粹才能在没有临时目录的情况下测试。
//
// 与 ArkTS 侧的契约：输入是 entry/src/main/ets/model/ServerNode.ets 的
// NodeJson（由 nodeToJsonText 产生），字段名一一对应，改字段必须两边同时改。
package config

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"
)

// 本地入站端口。与 ArkTS MockBridgeImpl 里的 socksPort/httpPort 保持一致，
// 避免 Mock 与真实实现给出不同的端口让上层逻辑出现分叉。
const (
	DefaultSocksPort = 10808
	DefaultHTTPPort  = 10809

	// tun 入站的网卡名与 MTU。fd 不在这里配置：它由 CoreService.Start 通过
	// xray.tun.fd 环境变量传给 proxy/tun（见 infra/conf/tun.go 与
	// proxy/tun/tun_android.go）。
	TunName    = "xray0"
	DefaultMTU = 1500
)

// 出站 tag。顺序即 Xray 的默认出站优先级（outbounds[0] 为默认）。
const (
	TagProxy  = "proxy"
	TagDirect = "direct"
	TagBlock  = "block"

	// DnsTag 是 dns 配置的 tag，让 routing 能用 inboundTag 命中
	// "由内核 DNS 模块发出的查询"。对齐 v2rayN 的 Global.DnsTag
	// （V2rayDnsService.cs:111）与 Sample/dns_v2ray_normal 里 dnsObj["tag"]。
	DnsTag = "dns-module"

	// DomainDirectDNS / DomainRemoteDNS / remoteDoH 取自 v2rayN
	// `Global.DomainDirectDNSAddress` / `Global.DomainRemoteDNSAddress` 的首项
	// 以及 Sample/dns_v2ray_normal 的兜底列表。
	DomainDirectDNS = "223.5.5.5"
	DomainRemoteDNS = "1.1.1.1"
	remoteDoH       = "https://dns.google/dns-query"
)

// 降级提示。geo 资源缺位时规则会退化成"聊胜于无"的形态，必须让用户知道。
const (
	msgNoGeoDNS = "dns: 未打包 geoip.dat / geosite.dat，无法生成「国内域名走国内 DNS」" +
		"的定向解析器，已降级为纯国外 DNS；补齐资源后才会启用国内外分流（见 docs/design/core.md）"

	msgNoGeoRule = "routing=rule: 未打包 geoip.dat / geosite.dat，规则里所有 " +
		"geoip:/geosite: 条目已整体跳过（缺文件时内核会拒绝整份配置）；" +
		"当前只能保证「私有网段 + 中国公共 DNS」直连与协议层面的兜底"
)

// Node 是 ArkTS 侧 NodeJson 的镜像。json tag 必须与 ServerNode.ets#nodeToJson 完全一致。
type Node struct {
	ID            string `json:"id"`
	Remarks       string `json:"remarks"`
	Protocol      string `json:"protocol"`
	Address       string `json:"address"`
	Port          int    `json:"port"`
	Transport     string `json:"transport"`
	Security      string `json:"security"`
	Host          string `json:"host"`
	Path          string `json:"path"`
	ServiceName   string `json:"serviceName"`
	RawHeaderType string `json:"rawHeaderType"`
	KCPHeaderType string `json:"kcpHeaderType"`
	XHTTPMode     string `json:"xhttpMode"`
	XHTTPExtra    string `json:"xhttpExtra"`
	GRPCMode      string `json:"grpcMode"`
	FinalMask     string `json:"finalmask"`
	SNI           string `json:"sni"`
	Fingerprint   string `json:"fingerprint"`
	ALPN          string `json:"alpn"`
	AllowInsecure bool   `json:"allowInsecure"`
	// allowInsecure 的三个替代字段（v2rayN 面板与分享链接 pcs/vcn 都指向它们）。
	PinnedPeerCertSha256 string `json:"pinnedPeerCertSha256"`
	VerifyPeerCertByName string `json:"verifyPeerCertByName"`
	DisableSystemRoot    bool   `json:"disableSystemRoot"`
	ECHConfigList        string `json:"echConfigList"`
	// TLSCertificates 是 certificates[] 的 JSON 文本（形状见内核 TLSCertConfig）。
	TLSCertificates string `json:"tlsCertificates"`
	PublicKey       string `json:"publicKey"`
	ShortID         string `json:"shortId"`
	SpiderX         string `json:"spiderX"`
	UserID          string `json:"userId"`
	AlterID         int    `json:"alterId"`
	SecurityCipher  string `json:"securityCipher"`
	Password        string `json:"password"`
	Flow            string `json:"flow"`
	MuxEnabled      bool   `json:"muxEnabled"`
}

// ParseNode 解析 ArkTS 传来的节点 JSON。
func ParseNode(extra string) (*Node, error) {
	if strings.TrimSpace(extra) == "" {
		return nil, errors.New("node json is empty (the ArkTS side must send ServerNode#nodeToJsonText)")
	}
	var node Node
	if err := json.Unmarshal([]byte(extra), &node); err != nil {
		return nil, fmt.Errorf("decode node json: %w", err)
	}
	return &node, nil
}

// ---------------------------------------------------------------------------
// 生成的 config 结构。字段名全部来自 infra/conf，不是自创。
// ---------------------------------------------------------------------------

// Config 对应 infra/conf/config.go 的 Config。
type Config struct {
	Log       *LogConfig     `json:"log,omitempty"`
	DNS       *DNSConfig     `json:"dns,omitempty"`
	Inbounds  []Inbound      `json:"inbounds"`
	Outbounds []Outbound     `json:"outbounds"`
	Routing   *RoutingConfig `json:"routing,omitempty"`
}

// LogConfig 对应 infra/conf/log.go 的 LogConfig。
type LogConfig struct {
	LogLevel string `json:"loglevel"`
	Access   string `json:"access,omitempty"`
	Error    string `json:"error,omitempty"`
}

// DNSConfig 对应 infra/conf/dns.go 的 DNSConfig。
//
// 形态对齐 v2rayN 的 DNS 分流（Sample/dns_v2ray_normal + V2rayDnsService.cs）：
//
//   - Servers 是**异构数组**：既可以是纯地址字符串，也可以是带
//     domains / expectIPs 的定向服务器对象。所以类型是 []any 而不是 []string。
//   - Tag 让 routing 能命中内核 DNS 模块发出的查询（见 DnsTag）。
//   - Hosts 是 DoH 域名的静态映射，缺了它解析 dns.google 会形成引导环。
type DNSConfig struct {
	Tag           string              `json:"tag,omitempty"`
	Hosts         map[string][]string `json:"hosts,omitempty"`
	Servers       []any               `json:"servers"`
	QueryStrategy string              `json:"queryStrategy,omitempty"`
}

// DNSServer 对应 infra/conf/dns.go 的 NameServer（对象形态）。
//
// 字段名以 v2rayN 实际写出的为准：注意是 `expectIPs`。
// 内核两种拼法都接受（infra/conf/dns.go:24-25 同时存在 expectedIPs 与 expectIPs），
// 这里跟着 v2rayN 走，便于两边对照。
type DNSServer struct {
	Address      string   `json:"address"`
	SkipFallback bool     `json:"skipFallback,omitempty"`
	Domains      []string `json:"domains,omitempty"`
	ExpectIPs    []string `json:"expectIPs,omitempty"`
}

// Inbound 对应 infra/conf/xray.go 的 InboundDetourConfig（取我们用到的那几个字段）。
type Inbound struct {
	Tag      string          `json:"tag"`
	Protocol string          `json:"protocol"`
	Listen   string          `json:"listen,omitempty"`
	Port     int             `json:"port,omitempty"`
	Settings any             `json:"settings,omitempty"`
	Sniffing *SniffingConfig `json:"sniffing,omitempty"`
}

// SniffingConfig 对应 infra/conf/xray.go 的 SniffingConfig。
type SniffingConfig struct {
	Enabled      bool     `json:"enabled"`
	DestOverride []string `json:"destOverride,omitempty"`
	RouteOnly    bool     `json:"routeOnly,omitempty"`
}

// Outbound 对应 infra/conf/xray.go 的 OutboundDetourConfig。
type Outbound struct {
	Tag            string          `json:"tag"`
	Protocol       string          `json:"protocol"`
	Settings       any             `json:"settings,omitempty"`
	StreamSettings *StreamSettings `json:"streamSettings,omitempty"`
	Mux            *MuxConfig      `json:"mux,omitempty"`
}

// MuxConfig 对应 infra/conf/xray.go 的 MuxConfig（Xray 没有 "MuxEnabled" 这个字段名）。
type MuxConfig struct {
	Enabled     bool `json:"enabled"`
	Concurrency int  `json:"concurrency,omitempty"`
}

// StreamSettings 对应 infra/conf/transport_internet.go 的 StreamConfig。
//
// 注意这里**故意没有** TLS 的 allowInsecure：该版本内核已把它删掉
// （infra/conf/transport_internet.go:711 PrintRemovedFeatureError），
// 写进去会让整个配置被 loader 拒绝。替代手段是 TLSSettings 里的
// pinnedPeerCertSha256 / verifyPeerCertByName / disableSystemRoot / certificates。
// 见 notes 里的提示。
type StreamSettings struct {
	Network             string             `json:"network,omitempty"`
	Security            string             `json:"security,omitempty"`
	TLSSettings         *TLSSettings       `json:"tlsSettings,omitempty"`
	RealitySettings     *RealitySettings   `json:"realitySettings,omitempty"`
	WSSettings          *WebSocketSettings `json:"wsSettings,omitempty"`
	HTTPUpgradeSettings *WebSocketSettings `json:"httpupgradeSettings,omitempty"`
	GRPCSettings        *GRPCSettings      `json:"grpcSettings,omitempty"`
	XHTTPSettings       map[string]any     `json:"xhttpSettings,omitempty"`
	KCPSettings         map[string]any     `json:"kcpSettings,omitempty"`
	RawSettings         *RawSettings       `json:"rawSettings,omitempty"`
	FinalMask           any                `json:"finalmask,omitempty"`
}

// TLSSettings 对应 infra/conf/transport_internet.go 的 TLSConfig（客户端相关字段）。
//
// 这里对齐的是 v2rayN TLS 面板真正写出的字段集（`Models/CoreConfigs/V2rayConfig.cs:342-346`）：
// serverName / alpn / fingerprint / certificates / verifyPeerCertByName /
// pinnedPeerCertSha256 / disableSystemRoot / echConfigList。
// **不含 allowInsecure** —— 见下方字段注释。
type TLSSettings struct {
	ServerName  string   `json:"serverName,omitempty"`
	ALPN        []string `json:"alpn,omitempty"`
	Fingerprint string   `json:"fingerprint,omitempty"`
	// PinnedPeerCertSha256 是 allowInsecure 的官方替代之一（内核又称 "pcs"）。
	// 内核会校验：逗号分隔的每一项必须是 32 字节（64 位十六进制）sha256，
	// 否则整份配置被拒（infra/conf/transport_internet.go:717-733）。
	PinnedPeerCertSha256 string `json:"pinnedPeerCertSha256,omitempty"`
	// VerifyPeerCertByName 是另一个替代（"vcn"），按证书名验证，逗号分隔。
	VerifyPeerCertByName string `json:"verifyPeerCertByName,omitempty"`
	// DisableSystemRoot 不信任系统根证书（内核 line 698 直接赋值，无额外校验）。
	DisableSystemRoot bool `json:"disableSystemRoot,omitempty"`
	// ECHConfigList 是 ECH 配置（内核 line 762 直接赋值，无额外校验）。
	ECHConfigList string `json:"echConfigList,omitempty"`
	// Certificates 是透传的 certificates[]：字段形状由内核 TLSCertConfig 定义
	// （usage / certificate / key / ...）。我们只做严格 JSON 解析、不做字段级建模，
	// 与 xhttpExtra / finalmask 同一套策略。
	Certificates []any `json:"certificates,omitempty"`
}

// RealitySettings 对应 infra/conf/transport_internet.go 的 REALITYConfig（客户端字段）。
type RealitySettings struct {
	ServerName  string `json:"serverName,omitempty"`
	Fingerprint string `json:"fingerprint,omitempty"`
	PublicKey   string `json:"publicKey"`
	ShortID     string `json:"shortId,omitempty"`
	SpiderX     string `json:"spiderX,omitempty"`
	Show        bool   `json:"show"`
}

// WebSocketSettings 对应 infra/conf/transport_internet.go 的 WebSocketConfig。
type WebSocketSettings struct {
	Host string `json:"host,omitempty"`
	Path string `json:"path,omitempty"`
}

// GRPCSettings 对应 infra/conf/grpc.go 的 GRPCConfig。
type GRPCSettings struct {
	ServiceName string `json:"serviceName,omitempty"`
	MultiMode   bool   `json:"multiMode"`
}

// RawSettings 对应 infra/conf/transport_internet.go 的 TCPConfig。
// raw/tcp 的伪装类型只有 none / http 两种，key 名是 type
// （见该文件里的 tcpHeaderLoader）。
type RawSettings struct {
	Header map[string]any `json:"header,omitempty"`
}

// RoutingConfig 对应 infra/conf/router.go 的 RouterConfig。
type RoutingConfig struct {
	DomainStrategy string        `json:"domainStrategy,omitempty"`
	Rules          []RoutingRule `json:"rules"`
}

// RoutingRule 对应 infra/conf/router.go 的 Rule（字段名见该文件 531-551 行的
// RawFieldRule：domain / ip / port / network / inboundTag / protocol / outboundTag）。
type RoutingRule struct {
	Type        string   `json:"type"`
	OutboundTag string   `json:"outboundTag"`
	Domain      []string `json:"domain,omitempty"`
	IP          []string `json:"ip,omitempty"`
	Port        string   `json:"port,omitempty"`
	Network     string   `json:"network,omitempty"`
	// InboundTag 用于命中"由内核 DNS 模块发出的查询"（值为 DnsTag）。
	InboundTag []string `json:"inboundTag,omitempty"`
	// Protocol 是按嗅探结果匹配的协议名（当前只用到 "bittorrent"）。
	// 本版内核的嗅探器是内建的，不看 destOverride，见 blacklistRules 的说明。
	Protocol []string `json:"protocol,omitempty"`
}

// ---------------------------------------------------------------------------
// 出站 settings（每个协议一份，字段名取自 infra/conf/<protocol>.go）
// ---------------------------------------------------------------------------

type vnextUser struct {
	ID         string `json:"id"`
	AlterID    int    `json:"alterId,omitempty"`
	Encryption string `json:"encryption,omitempty"`
	Flow       string `json:"flow,omitempty"`
	Security   string `json:"security,omitempty"`
	Level      int    `json:"level"`
}

type vnextServer struct {
	Address string      `json:"address"`
	Port    int         `json:"port"`
	Users   []vnextUser `json:"users"`
}

type vnextSettings struct {
	Vnext []vnextServer `json:"vnext"`
}

type serverEntry struct {
	Address  string `json:"address"`
	Port     int    `json:"port"`
	Password string `json:"password,omitempty"`
	Method   string `json:"method,omitempty"`
	Level    int    `json:"level"`
	Uot      bool   `json:"uot,omitempty"`
}

type serversSettings struct {
	Servers []serverEntry `json:"servers"`
}

type userEntry struct {
	User string `json:"user"`
	Pass string `json:"pass"`
}

type socksServerEntry struct {
	Address string      `json:"address"`
	Port    int         `json:"port"`
	Users   []userEntry `json:"users,omitempty"`
}

type socksSettings struct {
	Servers []socksServerEntry `json:"servers"`
}

type freedomSettings struct {
	DomainStrategy string `json:"domainStrategy,omitempty"`
}

type blackholeSettings struct {
	Response map[string]any `json:"response,omitempty"`
}

// ---------------------------------------------------------------------------
// 构建
// ---------------------------------------------------------------------------

// Options 是生成的开关。
type Options struct {
	// RoutingMode 取值 global / rule / direct（ArkTS 的 RoutingMode 枚举）。
	RoutingMode string
	// SocksPort / HTTPPort 为 0 时用默认值。
	SocksPort int
	HTTPPort  int
	// LogLevel 缺省 warning。
	LogLevel string
	// GeoAssets 表示 geoip.dat 与 geosite.dat 是否已经就位。
	//
	// 这个开关不是"优化"，而是**必须**的：内核装载 geoip:/geosite: 规则时会去
	// 打开这两个文件，缺文件是**硬失败**（infra/conf: failed to open file:
	// geoip.dat），整个配置会被拒，而不是忽略那条规则。所以资源没打包时必须
	// 不生成 geo 规则，否则 CoreService.Start 会直接失败。
	GeoAssets bool

	// BypassChina 只在 RoutingMode == "rule" 时起作用：
	//
	//	true  -> 白名单「绕过大陆」：大陆直连、其余走代理
	//	         （v2rayN ServiceLib/Sample/custom_routing_white）
	//	false -> 黑名单：已知被墙的走代理、其余直连
	//	         （v2rayN ServiceLib/Sample/custom_routing_black）
	//
	// 这个字段此前在 ArkTS 侧存在（AppSettings.bypassChina，默认 true）
	// 但**从未传到这里**，所以那个开关拨动时行为完全不变。现在接上了。
	BypassChina bool
}

// Build 把节点编译成一份完整的 Xray 配置，并返回需要让用户知道的提示。
func Build(node *Node, opts Options) (*Config, []string, error) {
	if node == nil {
		return nil, nil, errors.New("nil node")
	}
	notes := make([]string, 0, 4)

	proxyOut, err := buildProxyOutbound(node, &notes)
	if err != nil {
		return nil, notes, err
	}

	socksPort := opts.SocksPort
	if socksPort == 0 {
		socksPort = DefaultSocksPort
	}
	httpPort := opts.HTTPPort
	if httpPort == 0 {
		httpPort = DefaultHTTPPort
	}
	logLevel := opts.LogLevel
	if logLevel == "" {
		logLevel = "warning"
	}

	cfg := &Config{
		Log: &LogConfig{LogLevel: logLevel},
		DNS: buildDNS(opts, &notes),
		Inbounds: []Inbound{
			{
				Tag:      "tun-in",
				Protocol: "tun",
				Settings: map[string]any{
					"name": TunName,
					"MTU":  DefaultMTU,
				},
				Sniffing: &SniffingConfig{
					Enabled: true,
					// destOverride 只能写 http / tls / quic / fakedns
					// （infra/conf/xray.go:75-86，写别的会报 "unknown protocol"）；
					// bittorrent 的嗅探是本版内核**内建**的，不在这里声明，
					// 见 app/dispatcher/sniffer.go:39-44 与 blacklistRules 的说明。
					DestOverride: []string{"http", "tls"},
					// routeOnly=true：嗅探出的域名**只用于路由匹配**，不改写实际目的地。
					// 对齐 v2rayN 对 TUN 入站的处理（V2rayInboundService.cs:90）。
					// 这对"按域名分流"是关键：否则嗅探会改写目标域名，
					// 让 geosite:cn 命中的后果扩散到连接本身。
					RouteOnly: true,
				},
			},
			{
				Tag:      "socks-in",
				Protocol: "socks",
				Listen:   "127.0.0.1",
				Port:     socksPort,
				Settings: map[string]any{"udp": true, "auth": "noauth"},
			},
			{
				Tag:      "http-in",
				Protocol: "http",
				Listen:   "127.0.0.1",
				Port:     httpPort,
			},
		},
		Outbounds: []Outbound{
			*proxyOut,
			{Tag: TagDirect, Protocol: "freedom", Settings: freedomSettings{DomainStrategy: "UseIP"}},
			{Tag: TagBlock, Protocol: "blackhole", Settings: blackholeSettings{}},
		},
	}

	// routing：proxy 永远是 outbounds[0]（Xray 的默认出站），
	// 所以"直连模式"必须靠一条全量规则把流量改派给 direct，而不是调整顺序。
	cfg.Routing = buildRouting(opts, &notes)
	return cfg, notes, nil
}

// buildDNS 生成 DNS 配置 —— 这一块直接决定"绕过大陆"成不成立。
//
// 此前无论什么模式都只用 1.1.1.1 / 8.8.8.8，而 rule 模式里还有一条
// 「port 53 -> proxy」：等于**用国外 DNS 解析国内域名，再拿解析结果去匹配
// geoip:cn**（rule 模式的 domainStrategy 是 IPIfNonMatch，会先解析再匹配），
// 规则必然失配。这里改成 v2rayN 的做法（Sample/dns_v2ray_normal）：
//
//   - 国内域名 (geosite:cn) 交给国内 DNS 223.5.5.5，并用 expectIPs=geoip:cn 约束，
//     防止国内 DNS 返回境外 IP（CDN 场景下很常见）；
//   - 国外域名（google 等）交给 1.1.1.1，skipFallback 避免回落到国外解析器；
//   - hosts 提供 DoH 域名的静态映射，否则解析 dns.google 本身就是引导环。
//
// 前两条需要 geosite.dat / geoip.dat，因此仍然受 Options.GeoAssets 门控：
// 资源没就位时降级为纯国外 DNS 并给出 note，而不是生成一份会被拒的配置。
//
// 对于 direct 模式，DNS 走国外解析器是无害的（本来就不做分流），统一处理。
func buildDNS(opts Options, notes *[]string) *DNSConfig {
	dns := &DNSConfig{
		Tag: DnsTag,
		// v2rayN 的 BlockAAAAQuery 等价物：只查 A 记录，避免 IPv6 优先导致的
		// 绕行与连接失败（与之前的 QueryStrategy 行为一致，未改语义）。
		QueryStrategy: "UseIPv4",
		Servers:       make([]any, 0, 4),
	}
	if opts.GeoAssets {
		dns.Hosts = predefinedHosts
		dns.Servers = append(dns.Servers,
			DNSServer{
				Address:      DomainRemoteDNS,
				SkipFallback: true,
				Domains:      []string{"geosite:google"},
			},
			DNSServer{
				Address:      DomainDirectDNS,
				SkipFallback: true,
				Domains:      []string{"geosite:cn"},
				ExpectIPs:    []string{"geoip:cn"},
			},
		)
	} else {
		*notes = append(*notes, msgNoGeoDNS)
	}
	// 兜底解析器：v2rayN 的 remoteDNSAddress（Global.DomainRemoteDNSAddress 首项）
	// 加上一个 DoH。它们的域名解析靠上面的 hosts。
	dns.Servers = append(dns.Servers, DomainRemoteDNS, "8.8.8.8", remoteDoH)
	return dns
}

// buildRouting 按路由模式生成规则。
//
// direct 与 global 两种模式的语义没有变化；rule 模式现在按 opts.BypassChina
// 在白名单 / 黑名单两套预设之间切换（对齐 v2rayN 的 custom_routing_white /
// custom_routing_black），见 buildRuleRouting。
func buildRouting(opts Options, notes *[]string) *RoutingConfig {
	switch strings.ToLower(strings.TrimSpace(opts.RoutingMode)) {
	case "direct":
		return &RoutingConfig{
			DomainStrategy: "AsIs",
			Rules: []RoutingRule{
				{Type: "field", Network: "tcp,udp", OutboundTag: TagDirect},
			},
		}
	case "rule":
		return buildRuleRouting(opts, notes)
	default:
		// global：除 DNS 外全部走代理
		return &RoutingConfig{
			DomainStrategy: "AsIs",
			Rules: []RoutingRule{
				{Type: "field", Port: "53", OutboundTag: TagProxy},
			},
		}
	}
}

// buildRuleRouting 生成 rule 模式（按国家/地区分流）的规则表。
//
//	BypassChina = true  -> 白名单：大陆直连、其余走代理（v2rayN "绕过大陆"）
//	BypassChina = false -> 黑名单：已知被墙走代理、其余直连（v2rayN "绕过大陆(Blacklist)"）
//
// 两者都用 domainStrategy=IPIfNonMatch：域名先按域名规则匹配，没命中再解析成
// IP 去匹配 ip 规则 —— 这正是"大陆域名直连"能靠 geosite:cn + geoip:cn 双保险
// 生效的原因（v2rayN 的 GenDns 也是以 domainStrategy==IPIfNonMatch 为条件
// 追加 DNS 走代理的规则，见 V2rayDnsService.cs:14-17）。
func buildRuleRouting(opts Options, notes *[]string) *RoutingConfig {
	var rules []RoutingRule
	if opts.BypassChina {
		rules = whitelistRules(opts.GeoAssets, notes)
		// 白名单模式**没有**兜底直连规则，未命中任何规则的流量会落到
		// outbounds[0]（proxy）。显式写一条「DNS 模块 -> proxy」把这件事说清楚，
		// 对齐 v2rayN 的 V2rayDnsService.cs:111-118。
		//
		// 国内 DNS 的查询不会走到这条：它已经被上面的「绕过中国公共DNS IP/域名」
		// 规则先命中了，所以最终效果是「国内 DNS 直连、国外 DNS 走代理」。
		rules = append(rules, RoutingRule{
			Type:        "field",
			InboundTag:  []string{DnsTag},
			OutboundTag: TagProxy,
		})
	} else {
		rules = blacklistRules(opts.GeoAssets, notes)
		// 黑名单模式以「最终直连」收尾，任何追加的规则都不可达，因此这里
		// **刻意不追加** DNS 规则：国外 DNS 的代理已经由 "代理海外公共DNS IP/域名"
		// 两条规则在兜底之前完成，行为与 v2rayN 等价。
	}
	return &RoutingConfig{DomainStrategy: "IPIfNonMatch", Rules: rules}
}

// whitelistRules 是「绕过大陆」白名单的规则表。
//
// 逐条对齐 v2rayN `ServiceLib/Sample/custom_routing_white`（1..94 行），
// 顺序也保持一致（内核取首个命中，顺序有意义）：
//
//  1. block  / port=443, network=udp   阻断 QUIC，防"看起来走代理其实没走"
//  2. proxy  / geosite:google          白名单下的保险（google 不在 cn 内）
//  3. direct / geoip:private           局域网直连
//  4. direct / geosite:private         局域网域名直连
//  5. direct / 中国公共 DNS IP（35）    国内 DNS 直连 —— 分流的前提
//  6. direct / 中国公共 DNS 域名（5）
//  7. direct / geoip:cn                大陆 IP 直连
//  8. direct / geosite:cn              大陆域名直连
//
// 需要 geoip.dat / geosite.dat 的条目（2/3/4/7/8）受 geoAssets 门控；
// 5/6 是普通 IP 与域名，任何情况下都会生成。
func whitelistRules(geoAssets bool, notes *[]string) []RoutingRule {
	rules := make([]RoutingRule, 0, 9)
	rules = append(rules, RoutingRule{
		Type: "field", Port: "443", Network: "udp", OutboundTag: TagBlock,
	})
	if geoAssets {
		rules = append(rules, RoutingRule{
			Type: "field", Domain: []string{"geosite:google"}, OutboundTag: TagProxy,
		})
	}
	rules = append(rules, RoutingRule{
		Type: "field", IP: privateIPRule(geoAssets), OutboundTag: TagDirect,
	})
	if geoAssets {
		rules = append(rules, RoutingRule{
			Type: "field", Domain: []string{"geosite:private"}, OutboundTag: TagDirect,
		})
	}
	rules = append(rules,
		RoutingRule{Type: "field", IP: chinaPublicDNSIPs, OutboundTag: TagDirect},
		RoutingRule{Type: "field", Domain: chinaPublicDNSDomains, OutboundTag: TagDirect},
	)
	if geoAssets {
		rules = append(rules,
			RoutingRule{Type: "field", IP: []string{"geoip:cn"}, OutboundTag: TagDirect},
			RoutingRule{Type: "field", Domain: []string{"geosite:cn"}, OutboundTag: TagDirect},
		)
	} else {
		*notes = append(*notes, msgNoGeoRule)
	}
	return rules
}

// blacklistRules 是「绕过大陆」黑名单的规则表。
//
// 逐条对齐 v2rayN `ServiceLib/Sample/custom_routing_black`（1..148 行）：
//
//  1. direct / protocol=bittorrent      无嗅探即无此协议；见下方说明
//  2. proxy  / domain:api.ip.sb         出口 IP 查询必须走代理
//  3. block  / port=443, network=udp    阻断 QUIC
//  4. proxy  / geosite:google
//  5. direct / geoip:private
//  6. direct / geosite:private
//  7. proxy  / 海外公共 DNS IP（60）     默认直连，不显式代理就会漏 DNS
//  8. proxy  / 海外公共 DNS 域名（8）
//  9. proxy  / geoip:facebook|fastly|google|netflix|telegram|twitter
//  10. proxy / geosite:gfw, geosite:greatfire
//  11. direct / port=0-65535            最终直连（黑名单的兜底）
//
// 关于 bittorrent：本版内核的嗅探器是**内建**的，不看 destOverride
// （app/dispatcher/sniffer.go:39-44 固定注册 http/tls/bittorrent/quic/utp），
// 所以只要 sniffing.enabled 为真，`protocol: ["bittorrent"]` 规则就会生效。
// 注意 destOverride **不能**写 bittorrent —— infra/conf/xray.go:75-86 只接受
// http/tls/quic/fakedns，写别的会直接报 "unknown protocol"。
func blacklistRules(geoAssets bool, notes *[]string) []RoutingRule {
	rules := make([]RoutingRule, 0, 12)
	rules = append(rules,
		RoutingRule{Type: "field", Protocol: []string{"bittorrent"}, OutboundTag: TagDirect},
		RoutingRule{Type: "field", Domain: apiIPCheckDomains, OutboundTag: TagProxy},
		RoutingRule{Type: "field", Port: "443", Network: "udp", OutboundTag: TagBlock},
	)
	if geoAssets {
		rules = append(rules, RoutingRule{
			Type: "field", Domain: []string{"geosite:google"}, OutboundTag: TagProxy,
		})
	}
	rules = append(rules, RoutingRule{
		Type: "field", IP: privateIPRule(geoAssets), OutboundTag: TagDirect,
	})
	if geoAssets {
		rules = append(rules, RoutingRule{
			Type: "field", Domain: []string{"geosite:private"}, OutboundTag: TagDirect,
		})
	}
	rules = append(rules,
		RoutingRule{Type: "field", IP: overseasPublicDNSIPs, OutboundTag: TagProxy},
		RoutingRule{Type: "field", Domain: overseasPublicDNSDomains, OutboundTag: TagProxy},
	)
	if geoAssets {
		rules = append(rules,
			RoutingRule{Type: "field", IP: blockedGeoIPRegions, OutboundTag: TagProxy},
			RoutingRule{Type: "field", Domain: blockedGeoSites, OutboundTag: TagProxy},
		)
	} else {
		*notes = append(*notes, msgNoGeoRule)
	}
	// 黑名单的兜底：其余全部直连。
	rules = append(rules, RoutingRule{Type: "field", Port: "0-65535", OutboundTag: TagDirect})
	return rules
}

// privateIPRule 返回"局域网直连"用的 ip 列表。
//
// 有 geoip.dat 时用 `geoip:private`：网段由数据文件维护，不会随 RFC 变化而失效；
// 没有资源时退回显式 CIDR，保证这条规则在任何情况下都能生成。
func privateIPRule(geoAssets bool) []string {
	if geoAssets {
		return []string{"geoip:private"}
	}
	return privateCIDRs
}

// buildProxyOutbound 把一个节点变成协议出站。这是"协议搬运"真正落地的地方。
func buildProxyOutbound(node *Node, notes *[]string) (*Outbound, error) {
	if strings.TrimSpace(node.Address) == "" {
		return nil, errors.New("node has no address")
	}
	if node.Port <= 0 || node.Port > 65535 {
		return nil, fmt.Errorf("node port %d is out of range", node.Port)
	}

	stream, err := buildStreamSettings(node, notes)
	if err != nil {
		return nil, err
	}

	out := &Outbound{Tag: TagProxy, StreamSettings: stream}
	switch strings.ToLower(node.Protocol) {
	case "vmess":
		if node.UserID == "" {
			return nil, errors.New("vmess requires userId")
		}
		// security 在 vmess 里是"加密方式"，缺省 auto（内核侧会再兜底一次）
		cipher := node.SecurityCipher
		if cipher == "" {
			cipher = "auto"
		}
		out.Protocol = "vmess"
		out.Settings = vnextSettings{Vnext: []vnextServer{{
			Address: node.Address,
			Port:    node.Port,
			Users:   []vnextUser{{ID: node.UserID, AlterID: node.AlterID, Security: cipher, Level: 0}},
		}}}
	case "vless":
		if node.UserID == "" {
			return nil, errors.New("vless requires userId")
		}
		flow := node.Flow
		// 该版本内核已删除 legacy XTLS（infra/conf/transport_internet.go:1792），
		// 只接受 xtls-rprx-vision，且必须配 TLS / REALITY。不满足就丢掉 flow 而不是
		// 生成一份会被拒的配置。
		if flow != "" {
			if flow != "xtls-rprx-vision" && flow != "xtls-rprx-vision-udp443" {
				*notes = append(*notes, "flow="+flow+" 已被内核删除（legacy XTLS），已忽略")
				flow = ""
			} else if stream.Security != "tls" && stream.Security != "reality" {
				*notes = append(*notes, "flow="+flow+" 需要 TLS 或 REALITY，当前 security="+
					stream.Security+"，已忽略 flow")
				flow = ""
			}
		}
		out.Protocol = "vless"
		out.Settings = vnextSettings{Vnext: []vnextServer{{
			Address: node.Address,
			Port:    node.Port,
			Users:   []vnextUser{{ID: node.UserID, Encryption: "none", Flow: flow, Level: 0}},
		}}}
	case "trojan":
		if node.Password == "" {
			return nil, errors.New("trojan requires password")
		}
		out.Protocol = "trojan"
		out.Settings = serversSettings{Servers: []serverEntry{{
			Address: node.Address, Port: node.Port, Password: node.Password,
		}}}
	case "shadowsocks", "ss":
		if node.Password == "" {
			return nil, errors.New("shadowsocks requires password")
		}
		method := node.SecurityCipher
		if method == "" {
			return nil, errors.New("shadowsocks requires securityCipher (method)")
		}
		out.Protocol = "shadowsocks"
		out.Settings = serversSettings{Servers: []serverEntry{{
			Address: node.Address, Port: node.Port, Password: node.Password, Method: method, Uot: true,
		}}}
	case "socks":
		out.Protocol = "socks"
		users := make([]userEntry, 0, 1)
		if node.UserID != "" || node.Password != "" {
			users = append(users, userEntry{User: node.UserID, Pass: node.Password})
		}
		out.Settings = socksSettings{Servers: []socksServerEntry{{
			Address: node.Address, Port: node.Port, Users: users,
		}}}
	case "http":
		out.Protocol = "http"
		users := make([]userEntry, 0, 1)
		if node.UserID != "" || node.Password != "" {
			users = append(users, userEntry{User: node.UserID, Pass: node.Password})
		}
		out.Settings = socksSettings{Servers: []socksServerEntry{{
			Address: node.Address, Port: node.Port, Users: users,
		}}}
	case "hysteria2", "hysteria":
		return nil, errors.New("hysteria2: 该版本内核的 hysteria 出站配置形状尚未在本项目建模，" +
			"请先用 vmess/vless/trojan/shadowsocks")
	default:
		return nil, fmt.Errorf("unsupported protocol %q", node.Protocol)
	}

	if node.MuxEnabled {
		out.Mux = &MuxConfig{Enabled: true, Concurrency: 8}
	}
	return out, nil
}

// buildStreamSettings 组装传输层。这是与"内核删了哪些传输"正面相关的一段。
func buildStreamSettings(node *Node, notes *[]string) (*StreamSettings, error) {
	stream := &StreamSettings{}

	// 1. 传输方式。h2 / http / h3 / quic 在本版本内核里已被移除
	//    （infra/conf/transport_internet.go:1015-1018），必须在这里挡住，
	//    否则用户只会看到一句 "failed to create outbound"。
	switch strings.ToLower(strings.TrimSpace(node.Transport)) {
	case "", "tcp", "raw":
		stream.Network = "tcp"
	case "ws":
		stream.Network = "ws"
	case "grpc":
		stream.Network = "grpc"
	case "httpupgrade":
		stream.Network = "httpupgrade"
	case "xhttp", "splithttp":
		stream.Network = "xhttp"
	case "kcp":
		stream.Network = "kcp"
	case "h2", "http", "h3":
		return nil, fmt.Errorf("transport %q 已被内核删除（改用 XHTTP stream-one H2/H3）", node.Transport)
	case "quic":
		return nil, errors.New("transport \"quic\" 已被内核删除（改用 XHTTP stream-one H3）")
	default:
		return nil, fmt.Errorf("unsupported transport %q", node.Transport)
	}

	// 2. 传输层安全 + 各传输的专属参数
	switch strings.ToLower(strings.TrimSpace(node.Security)) {
	case "", "none":
		stream.Security = "none"
	case "tls":
		stream.Security = "tls"
		tlsSettings := &TLSSettings{
			ServerName:  firstNonEmpty(node.SNI, node.Host),
			ALPN:        splitList(node.ALPN),
			Fingerprint: node.Fingerprint,
		}
		// allowInsecure 在本版内核里是**硬失败**（不是"被忽略"）：2026-06-01 之后
		// 写入它会让 loader 拒绝整份配置（infra/conf/transport_internet.go:709-716
		// 的 PrintRemovedFeatureError）。所以一律不写、只告警，并指引到替代字段。
		if node.AllowInsecure {
			*notes = append(*notes,
				"allowInsecure 已被内核删除，本次未写入；请改用 pinnedPeerCertSha256（pcs）"+
					"或 verifyPeerCertByName（vcn）")
		}
		tlsSettings.PinnedPeerCertSha256 = strings.TrimSpace(node.PinnedPeerCertSha256)
		tlsSettings.VerifyPeerCertByName = strings.TrimSpace(node.VerifyPeerCertByName)
		tlsSettings.DisableSystemRoot = node.DisableSystemRoot
		tlsSettings.ECHConfigList = strings.TrimSpace(node.ECHConfigList)
		if certificatesText := strings.TrimSpace(node.TLSCertificates); certificatesText != "" {
			var certificates []any
			if err := json.Unmarshal([]byte(certificatesText), &certificates); err != nil {
				return nil, fmt.Errorf("tlsCertificates 不是合法的 JSON 数组: %w", err)
			}
			tlsSettings.Certificates = certificates
		}
		stream.TLSSettings = tlsSettings
	case "reality":
		if strings.TrimSpace(node.PublicKey) == "" {
			return nil, errors.New("reality requires publicKey")
		}
		stream.Security = "reality"
		stream.RealitySettings = &RealitySettings{
			ServerName:  firstNonEmpty(node.SNI, node.Host),
			Fingerprint: node.Fingerprint,
			PublicKey:   node.PublicKey,
			ShortID:     node.ShortID,
			SpiderX:     node.SpiderX,
			Show:        false,
		}
	default:
		return nil, fmt.Errorf("unsupported security %q", node.Security)
	}

	// 3. 传输专属 settings
	switch stream.Network {
	case "ws":
		stream.WSSettings = &WebSocketSettings{Host: node.Host, Path: node.Path}
	case "httpupgrade":
		// 字段形状与 ws 相同，但 JSON key 是 httpupgradeSettings
		// （infra/conf/transport_internet.go 的 HttpUpgradeConfig）
		stream.HTTPUpgradeSettings = &WebSocketSettings{Host: node.Host, Path: node.Path}
	case "grpc":
		gs := &GRPCSettings{ServiceName: node.ServiceName}
		switch strings.ToLower(strings.TrimSpace(node.GRPCMode)) {
		case "multi":
			gs.MultiMode = true
		case "", "gun":
			gs.MultiMode = false
		default:
			return nil, fmt.Errorf("unsupported grpc mode %q", node.GRPCMode)
		}
		stream.GRPCSettings = gs
	case "xhttp":
		settings := map[string]any{}
		if node.Host != "" {
			settings["host"] = node.Host
		}
		if node.Path != "" {
			settings["path"] = node.Path
		}
		if node.XHTTPMode != "" {
			settings["mode"] = node.XHTTPMode
		}
		// xhttpExtra 在 v2rayN 里是一段 JSON 文本，内核侧没有单一 "extra" 字段，
		// 而是拆成 xPaddingBytes / uplinkHTTPMethod / sessionPlacement 等具体键。
		// 所以这里按"JSON 对象合并"处理：任何一个 SplitHTTPConfig 字段名都可用。
		if strings.TrimSpace(node.XHTTPExtra) != "" {
			var extra map[string]any
			if err := json.Unmarshal([]byte(node.XHTTPExtra), &extra); err != nil {
				return nil, fmt.Errorf("xhttpExtra 不是合法的 JSON 对象: %w", err)
			}
			for k, v := range extra {
				settings[k] = v
			}
		}
		stream.XHTTPSettings = settings
	case "kcp":
		// 该版本内核删除了 kcp 的 header 与 seed
		// （infra/conf/transport_internet.go:111），伪装类型已搬到 finalmask。
		// 因此这里**不能**写 kcpSettings.header，只留一个空对象避免歧义。
		stream.KCPSettings = map[string]any{}
		if header := strings.TrimSpace(node.KCPHeaderType); header != "" && header != "none" {
			*notes = append(*notes,
				"kcpHeaderType="+header+" 已被内核删除（kcp header & seed -> finalmask），已忽略")
		}
	case "tcp":
		// raw 伪装类型只有 none / http 两种
		switch strings.ToLower(strings.TrimSpace(node.RawHeaderType)) {
		case "", "none":
			// 缺省即 none，不写字段
		case "http":
			stream.RawSettings = &RawSettings{Header: map[string]any{"type": "http"}}
		default:
			return nil, fmt.Errorf("raw 伪装类型 %q 无效（内核只认 none / http）", node.RawHeaderType)
		}
	}

	// 4. finalmask。它在本版本内核里是 streamSettings.finalmask（对象），
	//    我们的模型存的是 JSON 文本，这里做一次严格解析。
	if strings.TrimSpace(node.FinalMask) != "" {
		var mask any
		if err := json.Unmarshal([]byte(node.FinalMask), &mask); err != nil {
			return nil, fmt.Errorf("finalmask 不是合法的 JSON: %w", err)
		}
		stream.FinalMask = mask
	}

	return stream, nil
}

// ---------------------------------------------------------------------------
// 小工具
// ---------------------------------------------------------------------------

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if strings.TrimSpace(v) != "" {
			return v
		}
	}
	return ""
}

func splitList(value string) []string {
	if strings.TrimSpace(value) == "" {
		return nil
	}
	parts := strings.Split(value, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		if trimmed := strings.TrimSpace(p); trimmed != "" {
			out = append(out, trimmed)
		}
	}
	return out
}
