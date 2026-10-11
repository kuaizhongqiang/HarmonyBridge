// Package config implements ConfigService.Generate —— 契约里那个"生成内核运行配置"
// 的服务，它把 ArkTS 侧选中的节点变成一份 Xray 能直接加载的 config.json。
//
// 契约（docs/design/ipc-contract.md §4）：
//
//	ConfigService.Generate
//	  参数 {nodeId:string, routingMode:string, extra:string}
//	  结果 {configJson, socksPort, httpPort, outboundTag, protocol, transport,
//	        security, notes[]}
//
// `extra` 是 ArkTS 侧 ServerNode#nodeToJsonText 的结果（节点完整字段的 JSON），
// `nodeId` 只用于日志与回显：Go 侧没有节点表，也不应该有。
//
// 为什么结果返回**文本**而不是落盘路径：沙箱路径（filesDir）只有 ArkTS 知道；
// 由 ArkTS 写盘再交给 CoreService.Start 的 configLocation，可以让本函数保持纯粹，
// 测试不需要临时目录，也不需要让 Go 侧知道应用的目录布局。
package config

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	xcore "github.com/xtls/xray-core/core"

	"harmonybridge/core/ipc"
)

// GenerateRequest 是 ConfigService.Generate 的参数对象。
type GenerateRequest struct {
	// NodeID 仅用于日志与回显。
	NodeID string `json:"nodeId"`

	// RoutingMode 取值 global / rule / direct（ArkTS 的 RoutingMode 枚举）。
	RoutingMode string `json:"routingMode"`

	// Extra 是节点 JSON（ServerNode#nodeToJsonText 的输出）。
	Extra string `json:"extra"`

	// AssetDir 是 geoip.dat / geosite.dat 所在目录（ArkTS 侧的 filesDir/assets）。
	// 它决定 rule 模式能否生成按国家分流的规则：内核在装载 geoip:/geosite:
	// 规则时缺文件是**硬失败**，所以这里必须先探测。
	AssetDir string `json:"assetDir"`
}

// GenerateResponse 是 ConfigService.Generate 的结果对象。
type GenerateResponse struct {
	// ConfigJSON 是完整的 config.json 文本，由 ArkTS 侧写入沙箱。
	ConfigJSON string `json:"configJson"`

	// SocksPort / HTTPPort 是本地入站端口，CoreService.RuntimeInfo 也会用到。
	SocksPort int `json:"socksPort"`
	HTTPPort  int `json:"httpPort"`

	// OutboundTag 恒为 "proxy"；Protocol / Transport / Security 是回显，
	// 方便 UI 确认"到底按什么连"。
	OutboundTag string `json:"outboundTag"`
	Protocol    string `json:"protocol"`
	Transport   string `json:"transport"`
	Security    string `json:"security"`

	// GeoAssets 表示生成时 geoip.dat / geosite.dat 是否真的就位。
	GeoAssets bool `json:"geoAssets"`

	// Notes 是"我们做了什么妥协"的诚实清单（被内核删除的特性、降级的分流等），UI 应展示。
	Notes []string `json:"notes"`
}

// hasGeoAssets 探测两种 geo 资源是否都在。内核装载 geoip:/geosite: 规则时
// 缺文件会直接让整份配置失败，因此这里要求两个文件同时存在。
func hasGeoAssets(dir string) bool {
	if strings.TrimSpace(dir) == "" {
		return false
	}
	for _, name := range []string{"geoip.dat", "geosite.dat"} {
		info, err := os.Stat(filepath.Join(dir, name))
		if err != nil || info.IsDir() {
			return false
		}
	}
	return true
}

// Service 是 ConfigService 的实现。它无状态。
type Service struct{}

// Generate 实现 ConfigService.Generate。
//
// 生成后会**用内核自己的 loader 自检一遍**：只要 LoadConfig 失败就直接返回错误，
// 保证 ArkTS 侧拿不到一份内核不认的配置。
func (s *Service) Generate(req *GenerateRequest) (*GenerateResponse, error) {
	if req == nil {
		return nil, errors.New("ConfigService.Generate: missing parameters")
	}

	node, err := ParseNode(req.Extra)
	if err != nil {
		return nil, fmt.Errorf("ConfigService.Generate: %w", err)
	}

	geoAssets := hasGeoAssets(req.AssetDir)
	cfg, notes, err := Build(node, Options{RoutingMode: req.RoutingMode, GeoAssets: geoAssets})
	if err != nil {
		return nil, fmt.Errorf("ConfigService.Generate: %w", err)
	}

	text, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return nil, fmt.Errorf("ConfigService.Generate: marshal config: %w", err)
	}

	if _, err := xcore.LoadConfig("json", bytes.NewReader(text)); err != nil {
		return nil, fmt.Errorf("ConfigService.Generate: 生成结果未通过内核自检: %w", err)
	}

	return &GenerateResponse{
		ConfigJSON:  string(text),
		SocksPort:   DefaultSocksPort,
		HTTPPort:    DefaultHTTPPort,
		OutboundTag: TagProxy,
		Protocol:    strings.ToLower(node.Protocol),
		Transport:   strings.ToLower(node.Transport),
		Security:    strings.ToLower(node.Security),
		GeoAssets:   geoAssets,
		Notes:       notes,
	}, nil
}

// svc 是进程内的唯一实例。
var svc = &Service{}

func init() {
	ipc.Register("ConfigService.Generate", func(params json.RawMessage) (any, error) {
		var req GenerateRequest
		if err := ipc.DecodeParams(params, &req); err != nil {
			return nil, err
		}
		return svc.Generate(&req)
	})
}
