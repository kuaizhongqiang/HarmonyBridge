// 本文件是「绕过大陆」所需的静态数据表，**只放数据不放逻辑**。
//
// 逐条转录自 v2rayN 的两份预设路由与全局常量，出处写在每一段的注释里。
// 之所以单独放一个文件：这些是"抄来的事实"，改错了很难从代码里看出来，
// 集中在一处便于和上游对照审查。
//
// 全部是**不依赖 geoip.dat / geosite.dat** 的普通 IP / 域名，
// 因此即使分流资源没就位也能生成（`geoip:` / `geosite:` 规则则必须等资源就位）。
package config

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

// chinaPublicDNSIPs 是中国公共 DNS 的 IP 列表（35 条，含 IPv6）。
//
// 出处：v2rayN `ServiceLib/Sample/custom_routing_white` 第 29-69 行的
// "绕过中国公共DNSIP" 规则。
//
// 为什么这条对"绕过大陆"是**必须**的而不是锦上添花：内核 DNS 模块发出的查询
// 也要经过 routing，只有这些地址被显式直连，国内域名才会由国内 DNS 解析；
// 配合 expectIPs=geoip:cn 才谈得上"解析出来的确实是国内 IP"。
var chinaPublicDNSIPs = []string{
	"223.5.5.5",
	"223.6.6.6",
	"2400:3200::1",
	"2400:3200:baba::1",
	"119.29.29.29",
	"1.12.12.12",
	"120.53.53.53",
	"2402:4e00::",
	"2402:4e00:1::",
	"180.76.76.76",
	"2400:da00::6666",
	"114.114.114.114",
	"114.114.115.115",
	"114.114.114.119",
	"114.114.115.119",
	"114.114.114.110",
	"114.114.115.110",
	"180.184.1.1",
	"180.184.2.2",
	"101.226.4.6",
	"218.30.118.6",
	"123.125.81.6",
	"140.207.198.6",
	"1.2.4.8",
	"210.2.4.8",
	"52.80.66.66",
	"117.50.22.22",
	"2400:7fc0:849e:200::4",
	"2404:c2c0:85d8:901::4",
	"117.50.10.10",
	"52.80.52.52",
	"2400:7fc0:849e:200::8",
	"2404:c2c0:85d8:901::8",
	"117.50.60.30",
	"52.80.60.30",
}

// chinaPublicDNSDomains 是中国公共 DNS 的 DoH/DoT 域名（5 条）。
//
// 出处：v2rayN `ServiceLib/Sample/custom_routing_white` 第 70-80 行的
// "绕过中国公共DNS域名" 规则。前缀 `domain:` 是内核的匹配方式（子域名也命中）。
var chinaPublicDNSDomains = []string{
	"domain:alidns.com",
	"domain:doh.pub",
	"domain:dot.pub",
	"domain:360.cn",
	"domain:onedns.net",
}

// overseasPublicDNSIPs 是海外公共 DNS 的 IP 列表（60 条，含 IPv6）。
//
// 出处：v2rayN `ServiceLib/Sample/custom_routing_black` 第 43-108 行的
// "代理海外公共DNSIP" 规则。
//
// 只在**黑名单模式**（BypassChina=false）用得到：黑名单默认直连，
// 不显式把这些地址派给代理，DNS 查询就会明文直连出去。
var overseasPublicDNSIPs = []string{
	"1.1.1.1",
	"1.0.0.1",
	"2606:4700:4700::1111",
	"2606:4700:4700::1001",
	"1.1.1.2",
	"1.0.0.2",
	"2606:4700:4700::1112",
	"2606:4700:4700::1002",
	"1.1.1.3",
	"1.0.0.3",
	"2606:4700:4700::1113",
	"2606:4700:4700::1003",
	"8.8.8.8",
	"8.8.4.4",
	"2001:4860:4860::8888",
	"2001:4860:4860::8844",
	"94.140.14.14",
	"94.140.15.15",
	"2a10:50c0::ad1:ff",
	"2a10:50c0::ad2:ff",
	"94.140.14.15",
	"94.140.15.16",
	"2a10:50c0::bad1:ff",
	"2a10:50c0::bad2:ff",
	"94.140.14.140",
	"94.140.14.141",
	"2a10:50c0::1:ff",
	"2a10:50c0::2:ff",
	"208.67.222.222",
	"208.67.220.220",
	"2620:119:35::35",
	"2620:119:53::53",
	"208.67.222.123",
	"208.67.220.123",
	"2620:119:35::123",
	"2620:119:53::123",
	"9.9.9.9",
	"149.112.112.112",
	"2620:fe::9",
	"2620:fe::fe",
	"9.9.9.11",
	"149.112.112.11",
	"2620:fe::11",
	"2620:fe::fe:11",
	"9.9.9.10",
	"149.112.112.10",
	"2620:fe::10",
	"2620:fe::fe:10",
	"77.88.8.8",
	"77.88.8.1",
	"2a02:6b8::feed:0ff",
	"2a02:6b8:0:1::feed:0ff",
	"77.88.8.88",
	"77.88.8.2",
	"2a02:6b8::feed:bad",
	"2a02:6b8:0:1::feed:bad",
	"77.88.8.7",
	"77.88.8.3",
	"2a02:6b8::feed:a11",
	"2a02:6b8:0:1::feed:a11",
}

// overseasPublicDNSDomains 是海外公共 DNS 的 DoH/DoT 域名（8 条）。
//
// 出处：v2rayN `ServiceLib/Sample/custom_routing_black` 第 109-122 行的
// "代理海外公共DNS域名" 规则。
var overseasPublicDNSDomains = []string{
	"domain:cloudflare-dns.com",
	"domain:one.one.one.one",
	"domain:dns.google",
	"domain:adguard-dns.com",
	"domain:opendns.com",
	"domain:umbrella.com",
	"domain:quad9.net",
	"domain:yandex.net",
}

// blockedGeoIPRegions 是黑名单模式下需要走代理的 geoip 区域。
//
// 出处：v2rayN `ServiceLib/Sample/custom_routing_black` 第 123-134 行的
// "代理IP" 规则。需要 geoip.dat。
var blockedGeoIPRegions = []string{
	"geoip:facebook",
	"geoip:fastly",
	"geoip:google",
	"geoip:netflix",
	"geoip:telegram",
	"geoip:twitter",
}

// apiIPCheckDomains 是出口 IP 查询站点，黑名单模式下必须显式走代理。
//
// 出处：v2rayN `ServiceLib/Sample/custom_routing_black` 第 9-15 行的
// "api.ip.sb" 规则。黑名单默认直连，不显式指定就会测出直连 IP，
// 让用户误判"代理没生效"。
var apiIPCheckDomains = []string{
	"api.ip.sb",
}

// blockedGeoSites 是黑名单模式下需要走代理的 geosite 分类。
//
// 出处：v2rayN `ServiceLib/Sample/custom_routing_black` 第 135-142 行的
// "代理GFW" 规则。需要 geosite.dat。
var blockedGeoSites = []string{
	"geosite:gfw",
	"geosite:greatfire",
}

// predefinedHosts 是 DNS 静态映射，转录自 v2rayN `ServiceLib/Global.cs` 的
// `PredefinedHosts`（14 条）。
//
// 为什么必须要有：我们的 DNS 里包含 `https://dns.google/dns-query` 这类 DoH
// 地址，而解析 `dns.google` 本身就需要 DNS —— 不给静态映射就形成引导环。
var predefinedHosts = map[string][]string{
	"dns.google":                       {"8.8.8.8", "8.8.4.4", "2001:4860:4860::8888", "2001:4860:4860::8844"},
	"dns.alidns.com":                   {"223.5.5.5", "223.6.6.6", "2400:3200::1", "2400:3200:baba::1"},
	"one.one.one.one":                  {"1.1.1.1", "1.0.0.1", "2606:4700:4700::1111", "2606:4700:4700::1001"},
	"1dot1dot1dot1.cloudflare-dns.com": {"1.1.1.1", "1.0.0.1", "2606:4700:4700::1111", "2606:4700:4700::1001"},
	"cloudflare-dns.com":               {"104.16.249.249", "104.16.248.249", "2606:4700::6810:f8f9", "2606:4700::6810:f9f9"},
	"dns.cloudflare.com":               {"162.159.61.8", "172.64.41.8", "2a06:98c1:52::8", "2803:f800:53::8"},
	"dot.pub":                          {"1.12.12.12", "120.53.53.53"},
	"doh.pub":                          {"1.12.12.12", "120.53.53.53"},
	"dns.quad9.net":                    {"9.9.9.9", "149.112.112.112", "2620:fe::fe", "2620:fe::9"},
	"dns.yandex.net":                   {"77.88.8.8", "77.88.8.1", "2a02:6b8::feed:0ff", "2a02:6b8:0:1::feed:0ff"},
	"dns.sb":                           {"45.11.45.11", "185.222.222.222", "2a09::", "2a11::"},
	"dns.umbrella.com":                 {"208.67.220.220", "208.67.222.222", "2620:119:35::35", "2620:119:53::53"},
	"dns.sse.cisco.com":                {"208.67.220.220", "208.67.222.222", "2620:119:35::35", "2620:119:53::53"},
	"engage.cloudflareclient.com":      {"162.159.192.1", "2606:4700:d0::a29f:c001"},
}
