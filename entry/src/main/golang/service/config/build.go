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
)

// Node 是 ArkTS 侧 NodeJson 的镜像。json tag 必须与 ServerNode.ets#nodeToJson 完全一致。
type Node struct {
	ID             string `json:"id"`
	Remarks        string `json:"remarks"`
	Protocol       string `json:"protocol"`
	Address        string `json:"address"`
	Port           int    `json:"port"`
	Transport      string `json:"transport"`
	Security       string `json:"security"`
	Host           string `json:"host"`
	Path           string `json:"path"`
	ServiceName    string `json:"serviceName"`
	RawHeaderType  string `json:"rawHeaderType"`
	KCPHeaderType  string `json:"kcpHeaderType"`
	XHTTPMode      string `json:"xhttpMode"`
	XHTTPExtra     string `json:"xhttpExtra"`
	GRPCMode       string `json:"grpcMode"`
	FinalMask      string `json:"finalmask"`
	SNI            string `json:"sni"`
	Fingerprint    string `json:"fingerprint"`
	ALPN           string `json:"alpn"`
	AllowInsecure  bool   `json:"allowInsecure"`
	PublicKey      string `json:"publicKey"`
	ShortID        string `json:"shortId"`
	SpiderX        string `json:"spiderX"`
	UserID         string `json:"userId"`
	AlterID        int    `json:"alterId"`
	SecurityCipher string `json:"securityCipher"`
	Password       string `json:"password"`
	Flow           string `json:"flow"`
	MuxEnabled     bool   `json:"muxEnabled"`
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

// DNSConfig 对应 infra/conf/dns.go。这里只给最保守的形态：一组公共 DNS +
// IPv4 优先。真正的 DNS 分流（按域名走国内/国外解析器）依赖 geosite 资源，
// 属于后续工作流，见 docs/design/core.md。
type DNSConfig struct {
	Servers       []string `json:"servers"`
	QueryStrategy string   `json:"queryStrategy,omitempty"`
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
// 写进去会让整个配置被 loader 拒绝。见 notes 里的提示。
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
type TLSSettings struct {
	ServerName  string   `json:"serverName,omitempty"`
	ALPN        []string `json:"alpn,omitempty"`
	Fingerprint string   `json:"fingerprint,omitempty"`
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

// RoutingRule 对应 infra/conf/router.go 的 Rule。
type RoutingRule struct {
	Type        string   `json:"type"`
	OutboundTag string   `json:"outboundTag"`
	Domain      []string `json:"domain,omitempty"`
	IP          []string `json:"ip,omitempty"`
	Port        string   `json:"port,omitempty"`
	Network     string   `json:"network,omitempty"`
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
		DNS: &DNSConfig{
			Servers:       []string{"1.1.1.1", "8.8.8.8"},
			QueryStrategy: "UseIPv4",
		},
		Inbounds: []Inbound{
			{
				Tag:      "tun-in",
				Protocol: "tun",
				Settings: map[string]any{
					"name": TunName,
					"MTU":  DefaultMTU,
				},
				Sniffing: &SniffingConfig{
					Enabled:      true,
					DestOverride: []string{"http", "tls"},
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
	cfg.Routing = buildRouting(opts.RoutingMode, opts.GeoAssets, &notes)
	return cfg, notes, nil
}

// privateCIDRs 是不需要 geoip.dat 就能表达的私有/保留网段。
//
// 之所以自己列 CIDR 而不用 `geoip:private`：后者同样需要 geoip.dat，
// 缺文件时内核直接报错（见 Options.GeoAssets 的说明）。
var privateCIDRs = []string{
	"127.0.0.0/8",
	"10.0.0.0/8",
	"172.16.0.0/12",
	"192.168.0.0/16",
	"169.254.0.0/16",
	"100.64.0.0/10",
	"::1/128",
	"fc00::/7",
	"fe80::/10",
}

// buildRouting 按路由模式生成规则。
//
// rule 模式分两档：
//   - 私有网段直连：用显式 CIDR，任何情况下都能用；
//   - 按国家分流：需要 geoip.dat / geosite.dat，只有 opts.GeoAssets 为真时才写，
//     否则配置会被内核拒绝。
func buildRouting(mode string, geoAssets bool, notes *[]string) *RoutingConfig {
	switch strings.ToLower(strings.TrimSpace(mode)) {
	case "direct":
		return &RoutingConfig{
			DomainStrategy: "AsIs",
			Rules: []RoutingRule{
				{Type: "field", Network: "tcp,udp", OutboundTag: TagDirect},
			},
		}
	case "rule":
		rules := []RoutingRule{
			{Type: "field", IP: privateCIDRs, OutboundTag: TagDirect},
			{Type: "field", Port: "53", OutboundTag: TagProxy},
		}
		if geoAssets {
			rules = append(rules,
				RoutingRule{Type: "field", Domain: []string{"geosite:private", "geosite:cn"}, OutboundTag: TagDirect},
				RoutingRule{Type: "field", IP: []string{"geoip:cn"}, OutboundTag: TagDirect},
			)
		} else {
			*notes = append(*notes,
				"routing=rule: 未打包 geoip.dat / geosite.dat，已降级为「私有网段直连 + 其余走代理」；"+
					"补齐资源后才会启用按国家分流（见 docs/design/core.md）")
		}
		return &RoutingConfig{DomainStrategy: "IPIfNonMatch", Rules: rules}
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
		tls := &TLSSettings{
			ServerName:  firstNonEmpty(node.SNI, node.Host),
			ALPN:        splitList(node.ALPN),
			Fingerprint: node.Fingerprint,
		}
		stream.TLSSettings = tls
		if node.AllowInsecure {
			*notes = append(*notes,
				"allowInsecure 已被内核删除（改为 pinnedPeerCertSha256），本次未写入")
		}
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
