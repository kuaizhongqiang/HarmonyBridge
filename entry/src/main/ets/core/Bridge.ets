/**
 * Bridge.ets
 * 与原生内核通信的唯一出口（core 层）。
 *
 * 设计约束：
 * 1) 只有本文件允许接触原生 NAPI 模块；其它层只调用 Bridge 的 typed API。
 * 2) 原生模块 libbridge.so 由 `cpp/` 工作流实现，**已经是构建产物**（见下方 §0），
 *    但 `MOCK_BRIDGE` 仍为 true，所以 UI 默认走 MockBridgeImpl —— 理由不是
 *    "原生没实现"，而是本阶段无法验证真实链路（没有真机、libcore.so 尚未产出），
 *    见 `MOCK_BRIDGE` 的注释。
 * 3) 原生契约（由 libbridge.so 提供）：
 *      export const Invoke: (service: string, paramsJson: string) => string;
 *    返回 JSON 信封：{ "success": boolean, "result": object, "error": string }
 * 4) 启动 VPN 走 Ability 层（vpnExtension.startVpnExtensionAbility +
 *    context.connectServiceExtensionAbility），这部分是纯 SDK 调用，不属于原生契约。
 */
import { bundleManager, common, Want } from '@kit.AbilityKit';
import { vpnExtension } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import {
  APP_BUNDLE_NAME,
  CORE_HTTP_PORT,
  CORE_SOCKS_PORT,
  MOCK_CORE_VERSION,
  VPN_ABILITY_NAME,
  WANT_KEY_ASSET_PATH,
  WANT_KEY_CONFIG_PATH,
  WANT_KEY_HTTP_PORT,
  WANT_KEY_SOCKS_PORT
} from '../constants/Common';
import { Logger } from '../utils/Logger';
import { ConfigStore, CorePaths } from './ConfigStore';
import { GeoAssetService, GeoAssetStatus } from '../service/GeoAssetService';
// 关于下面这一行（2026-10-11 起启用）：
//   `import ... from 'libbridge.so'` 是**静态导入**。它此前被注释，理由是"cpp
//   工作流尚未完成、产物是 gitignore 的外部文件"。这个理由现在**不再成立**：
//   `entry/src/main/cpp/CMakeLists.txt` 已经是 hvigor 的构建输入
//   （entry/build-profile.json5 的 externalNativeOptions.path），libbridge.so 是
//   构建产物的一部分，不需要手工放置。
//
//   ArkTS 硬规则：**所有 `import` 必须位于其它语句之前**
//   （arkts-no-misplaced-imports）。它最初被放在本文件第 57 行（`const TAG` 之后），
//   真编译直接报错，已上移到此处。这也是本仓库"`.ets` 只有真编译才算数"的又一例证
//   （AGENT.md §3.1）。
//
//   ⚠️ 导入它**不改变 UI 行为**：MOCK_BRIDGE 仍为 true，UI 走 MockBridgeImpl
//   （它保持 true 的**真实理由**见下方 MOCK_BRIDGE 的注释，不再是"原生没实现"）。
//   NativeBridgeImpl 也**仍然**返回 'native-bridge-not-linked'，本次没有动它。
//
//   目前使用这个导入的只有文件末尾的 DataPlane（tun2socks 数据面）：它是 VPN
//   扩展进程的生命周期组件，与 UI 的 MOCK 开关无关，所以直接走原生。
import bridgeNative from 'libbridge.so';

const TAG: string = 'Bridge';

// ===========================================================================
// 0) 原生模块接入点
// ---------------------------------------------------------------------------
// 原生侧（另一工作流）已经就绪：
//   * 构建产物：libbridge.so（entry/src/main/cpp/CMakeLists.txt 里 add_library(bridge ...)）
//   * 类型声明：entry/src/main/cpp/types/libbridge/Index.d.ts
//       export const Invoke: (service: string, paramsJson: string) => string;
//   * 额外诊断接口：CoreAvailable(): string
//       ''        = 尝试加载过 libcore.so 但失败
//       'unknown' = 尚未触发过惰性 dlopen
//       其它      = libcore.so 的绝对路径
//
// 关于 `import bridgeNative from 'libbridge.so'`（2026-10-11 起启用）：
//   该 import 因为 ArkTS「所有 import 必须位于其它语句之前」的硬规则
//   （arkts-no-misplaced-imports），已搬去文件顶部的 import 区，
//   完整解释也一并搬到了那里 —— 请见文件开头，不要在此处重复。
// ===========================================================================

/**
 * MOCK 总开关：true = 内存实现（不触发任何原生调用）；false = 走 NativeBridgeImpl。
 *
 * ⚠️ **本阶段必须保持 true，但理由与以前不同。**
 *
 * 过时的旧理由（**已不成立**）："契约 §5 的原生侧待收敛清单还没做完，RuntimeInfo /
 * SpeedTest / ConfigService.Generate 尚未实现"。这四项**本轮已由 Go 侧实现**，
 * 详见 `BridgeService` 的 §实现状态。
 *
 * 现在保持 true 的真实理由：
 *   1. **没有鸿蒙真机**（AGENT.md §1 / §7 B3）。VPN 授权弹窗、`vpn-tun` 网卡、
 *      内核在本机进程里的加载，全部只能在真机上验证；模拟器大概率不支持 VPN，
 *      不能当验证手段。此时把 UI 切到原生，只会把界面变成一条**无法验证**的路径。
 *   2. **`libcore.so` 尚未产出**（AGENT.md §7 B2：Go→OHOS 工具链被 `socklen_t`
 *      冲突与 cgo TLS 墙阻塞）。`libbridge.so` 能加载，但它 `dlopen("libcore.so")`
 *      必然失败，任何服务调用都只会拿到错误信封。
 *   3. **真实链路无法验证**，因此不得让 UI 表现为"已经连通真链路"。
 *
 * 若把它改成 false：UI 的**每一次**调用都会走 `NativeBridgeImpl`，而它当前**恒返回**
 * `failure('native-bridge-not-linked')` —— 于是版本、连接、延迟、配置生成全部报错，
 * 而这不是"更真实"，只是把"可控的 MOCK 提示"换成"全面失败"。
 * 契约 §5 末尾与 AGENT.md §7 B3 都要求在此之前保持 true。
 */
export const MOCK_BRIDGE: boolean = true;

/** 模拟调用耗时（毫秒），用于让 UI 的连接过程可见 */
const MOCK_LATENCY_MS: number = 350;

/**
 * 原生 Invoke 的 service 名。
 *
 * 契约已冻结，权威定义在 `docs/design/ipc-contract.md`，禁止随意改名。
 * 形式必须是 `Group.Method`：原生侧的 `ipc.SplitService` 用最后一个 `.` 拆分服务名与
 * 方法名，**无点的名字会被直接判为非法服务名**并返回错误信封。
 *
 * 曾经的教训：本文件早期使用无点驼峰名（'version'、'startCore' …），
 * 与原生侧完全对不上，导致 UI 的每一次调用都必然失败。
 *
 * §实现状态（2026-10-11 更新，✅ 与契约 §5 的《原生侧待收敛清单》对齐）：
 * 契约 §5 要求的四项**已由 Go 侧实现**（本文件不再把它们当作"MOCK 的理由"）：
 *   * `CoreService.Start`：参数新增可选 `socksPort` / `httpPort`，结果新增
 *     `socksPort` / `httpPort`；`wired` 的语义改为"**本地 SOCKS/HTTP 入站已监听**"
 *     （不再是"tun 入站已挂载"）；不再返回 `fd`。
 *   * 新增 `CoreService.RuntimeInfo`（`{socksPort, httpPort, configLocation?}`）。
 *   * 新增 `PingService.SpeedTest`（`{speedBps, notes[]}`；本阶段 `speedBps` 恒为 0，
 *     **不伪造测量值**）。
 *   * `PingService.Tcping` 结果字段 `delayMs` → `latencyMs`（ArkTS 侧本来就按
 *     `latencyMs` 读，见 `Bridge.testLatency`，所以这次改名修的是一个潜在的静默 bug）。
 *
 * ⚠️ 但 `MOCK_BRIDGE` **仍然是 true** —— 真实理由（没有真机、`libcore.so` 尚未产出、
 * 真实链路无法验证）见 `MOCK_BRIDGE` 的注释。契约文档 §4 的"实现"列**已同步为 ✅**
 * （2026-10-11 收尾），所以现在没有任何地方再声称这四项"待实现"。
 */
export class BridgeService {
  static readonly VERSION: string = 'VersionService.GetVersion';
  static readonly START_CORE: string = 'CoreService.Start';
  static readonly STOP_CORE: string = 'CoreService.Stop';
  /** 内核是否在运行（用于冷启动恢复状态） */
  static readonly CORE_STATUS: string = 'CoreService.Status';
  static readonly TEST_LATENCY: string = 'PingService.Tcping';
  static readonly TEST_SPEED: string = 'PingService.SpeedTest';
  /** 生成内核运行配置（config.json）并返回其沙箱路径 */
  static readonly GENERATE_CONFIG: string = 'ConfigService.Generate';
  /** 读取内核运行信息（入站端口、日志路径等） */
  static readonly RUNTIME_INFO: string = 'CoreService.RuntimeInfo';
  /** 校验一个节点是否可用（内核侧预检） */
  static readonly VALIDATE_NODE: string = 'ValidatorService.ValidateConfig';
}

/** 原生返回的 JSON 信封 */
export interface NativeEnvelope {
  success: boolean;
  /**
   * 结果对象。声明为 Record 而不是 Object：ArkTS 禁止对 Object 做下标访问
   * （arkts-no-props-by-index），而 UI 侧必须按 key 读取结果字段。
   * 字段名与冻结契约 docs/design/ipc-contract.md 完全一致，未做任何改名。
   */
  result: Record<string, Object>;
  error: string;
}

/** 空结果（最小可索引对象） */
function emptyResult(): Record<string, Object> {
  const result: Record<string, Object> = {};
  return result;
}

/**
 * 把未知形状的 JSON 对象（Object）收窄成可索引的 Record。
 * 原生信封的 result 字段在失败信封里可能缺失，因此这里同时兜底 undefined/null。
 */
function asFields(value: Object | undefined): Record<string, Object> {
  if (value === undefined || value === null) {
    return emptyResult();
  }
  return value as Record<string, Object>;
}

/** 从信封结果里取字符串字段（类型不符时返回空串） */
function stringField(result: Record<string, Object>, key: string): string {
  const value: Object | undefined = result[key];
  return typeof value === 'string' ? value as string : '';
}

/** 从信封结果里取布尔字段（类型不符时返回 false） */
function boolField(result: Record<string, Object>, key: string): boolean {
  const value: Object | undefined = result[key];
  return typeof value === 'boolean' ? value as boolean : false;
}

/**
 * 从信封结果里取字符串数组。
 *
 * 这里不用 `Array.isArray`（仓库里没有先例，ArkTS 的可用性未经验证），
 * 而是直接按 `Object[]` 收窄后逐个判断元素类型：字段缺失时 `length` 为
 * undefined，循环自然不会执行，等价于返回空数组。
 */
function stringArrayField(result: Record<string, Object>, key: string): string[] {
  const out: string[] = [];
  const value: Object | undefined = result[key];
  if (value === undefined || value === null) {
    return out;
  }
  const items: Object[] = value as Object[];
  for (let i = 0; i < items.length; i++) {
    const item: Object | undefined = items[i];
    if (typeof item === 'string') {
      out.push(item as string);
    }
  }
  return out;
}

/** 组装失败信封 */
function failure(error: string): NativeEnvelope {
  const envelope: NativeEnvelope = { success: false, result: emptyResult(), error: error };
  return envelope;
}

/** 组装成功信封 */
function success(result: Object): NativeEnvelope {
  const envelope: NativeEnvelope = { success: true, result: asFields(result), error: '' };
  return envelope;
}

/**
 * 把原生返回的 JSON 文本收窄成 NativeEnvelope。
 *
 * 注意：原生（cpp/napi_init.cpp 的 makeErrorEnvelope）在失败时只返回
 * `{"success":false,"error":"..."}`，**不带 result 字段**，因此这里必须补默认值，
 * 否则后续 `envelope.result['xxx']` 会拿到 undefined 而抛异常。
 */
export function decodeEnvelope(raw: string): NativeEnvelope {
  let parsed: NativeEnvelope | undefined = undefined;
  try {
    parsed = JSON.parse(raw) as NativeEnvelope;
  } catch (error) {
    return failure('invalid-envelope-json');
  }
  if (parsed === undefined || parsed === null) {
    return failure('empty-envelope');
  }
  const resultValue: Object | undefined = parsed.result;
  const envelope: NativeEnvelope = {
    success: parsed.success === true,
    result: asFields(resultValue),
    error: typeof parsed.error === 'string' ? parsed.error as string : ''
  };
  return envelope;
}

/** 延时（Mock 用；真实实现里不存在） */
function delay(ms: number): Promise<void> {
  const promise: Promise<void> = new Promise<void>((resolve: () => void) => {
    setTimeout(() => {
      resolve();
    }, ms);
  });
  return promise;
}

/**
 * `CoreService.Start` 的原生**线上形状**（契约 §4）。
 *
 * 为什么要单独声明一个 raw 形状：ArkTS 禁止"对象字面量直接当接口用"
 * （arkts-no-untyped-obj-literals），Mock 实现必须挂到一个显式类型上才能造出
 * **与原生同形**的结果。Mock 若返回另一种形状，就失去了"用 Mock 验证调用方解析
 * 逻辑"的价值 —— 而这次的缺陷恰恰是"解析逻辑判错了成功"。
 */
interface StartCoreRawResult {
  started: boolean;
  wired: boolean;
  socksPort: number;
  httpPort: number;
  notes: string[];
}

/** 启动内核的结果（ArkTS 侧对外形状） */
export interface StartCoreResult {
  /**
   * **启动是否成功的唯一判据** = `envelope.success === true && result.started === true`。
   *
   * 为什么用布尔字段而不是"失败时抛错"：Bridge 层的既有约定是"**永不抛异常**，
   * 失败编码进返回值"（契约 §3.3、`DataPlane` 的注释），`Bridge.invoke` 的 catch
   * 留给 NAPI/JSON 这类**真异常**。若把业务失败也做成异常，调用方就无法区分
   * "内核没启动"与"桥断了"，而**这正是本接口此前那个缺陷的根源**：
   * 旧代码用 `pid <= 0` 判成功，而 `pid` 被契约定义为恒 0，于是**每次成功的启动
   * 都被 UI 判成失败**。判据必须是语义明确的布尔值，而不是一个"恰好为 0"的数字。
   */
  ok: boolean;
  /**
   * 失败原因（成功时为空串）。区分"信封失败"（如原生 error 文本）与
   * "原生说没启动"，供调用方填进 `lastError` 时定位原因。
   */
  error: string;
  /**
   * 进程号。**当前恒为 0，且不再从原生结果里读**：冻结契约下核心以动态库形式跑在
   * VPN 扩展进程内，不是独立进程，契约的 Start 结果里**根本没有 `pid` 字段**
   * （§4：`{started, configLoaded, configBytes, wired, socksPort, httpPort, version, notes[]}`）。
   * 保留字段只为将来若改走 childProcessManager 独立进程时不再改动上层调用点。
   * ⚠️ 它**不是**成功判据 —— 判据是 `ok`。
   */
  pid: number;
  /** 本地 socks 入站端口（0 已被回落为 `CORE_SOCKS_PORT`） */
  socksPort: number;
  /** 本地 http 入站端口（0 已被回落为 `CORE_HTTP_PORT`） */
  httpPort: number;
  /**
   * 出站是否可路由 = 本地 SOCKS/HTTP 入站**是否真的在监听**（契约 §4.1 的新语义，
   * 不再表示"tun 入站已挂载"）。
   *
   * **本阶段恒为 false**：契约 §5.1 已把语义改过来，但"真的有监听"要等真机验证。
   * UI 不得据此宣称"已连通"（见 `ConnectionViewModel.coreWired`）。
   */
  wired: boolean;
  /** 原生侧的诚实提示（"实例起来了但入站没接线"之类），UI/日志应展示 */
  notes: string[];
}

/** 内核状态结果 */
export interface CoreStatusResult {
  running: boolean;
  pid: number;
  version: string;
}

/** 延迟测试结果 */
export interface LatencyResult {
  latencyMs: number;
  /** 是否超时 */
  timeout: boolean;
}

/** 内核配置生成结果 */
export interface ConfigPathResult {
  /** 内核配置文件路径（真实模式下由 ArkTS 落盘得到） */
  configPath: string;
  /** 分流资源目录（geoip.dat / geosite.dat 放这里） */
  assetPath: string;
  /** 生成器的诚实提示：被内核删除的特性、分流失效降级等，UI 应展示 */
  notes: string[];
  /** geoip.dat / geosite.dat 是否就位（决定 rule 模式能否按国家分流） */
  geoAssets: boolean;
  /**
   * 内核本地 SOCKS 入站端口，取自 `ConfigService.Generate` 的**结果**
   * （契约 §4 的结果字段），原生没给时回落为 `CORE_SOCKS_PORT`。
   *
   * ⚠️ 它不能由 ArkTS 自己"决定"：生成出来的 config.json 里的 inbound 端口是
   * Go 侧 `config.DefaultSocksPort` 写死的，ArkTS 只是把同一次生成的结果回显值
   * 传给 `CoreService.Start` 与 VPN 扩展（tun2socks 要连的端口）。三方必须同一个数。
   */
  socksPort: number;
  /** 内核本地 HTTP 入站端口（同上） */
  httpPort: number;
}

/** 内核实现接口：MockBridge 与 NativeBridge 都实现它 */
export interface IBridge {
  invoke(service: string, params: Record<string, Object>): Promise<NativeEnvelope>;
}

// ---------------------------------------------------------------------------
// Mock 实现：内存态，不触碰原生模块
// ---------------------------------------------------------------------------
class MockBridgeImpl implements IBridge {
  private coreRunning: boolean = false;
  private corePid: number = 0;
  private readonly coreVersion: string = MOCK_CORE_VERSION;

  async invoke(service: string, params: Record<string, Object>): Promise<NativeEnvelope> {
    await delay(MOCK_LATENCY_MS);
    Logger.debug(TAG, 'mock invoke ' + service);
    if (service === BridgeService.VERSION) {
      const result: Record<string, string> = { 'version': this.coreVersion };
      return success(result);
    }
    if (service === BridgeService.START_CORE) {
      this.coreRunning = true;
      this.corePid = 4242;
      // 造一份**与原生同形**的结果（StartCoreRawResult），而不是直接造 ArkTS 侧
      // 的 StartCoreResult：这样 Bridge.startCore 的解析逻辑（含 ok 的判定与端口
      // 回落）在 MOCK 下也会被真实执行，不至于"Mock 永远成功、真机才暴露"。
      //
      // wired 故意是 false —— 本阶段原生侧也恒为 false（没有真实监听），
      // Mock 若报 true 就是在教 UI 相信一件不成立的事。
      const result: StartCoreRawResult = {
        started: true,
        wired: false,
        socksPort: CORE_SOCKS_PORT,
        httpPort: CORE_HTTP_PORT,
        notes: ['mock: core not really started; wired is always false in this phase']
      };
      return success(result);
    }
    if (service === BridgeService.STOP_CORE) {
      this.coreRunning = false;
      this.corePid = 0;
      return success(emptyResult());
    }
    if (service === BridgeService.CORE_STATUS) {
      const result: CoreStatusResult = {
        running: this.coreRunning,
        pid: this.corePid,
        version: this.coreVersion
      };
      return success(result);
    }
    if (service === BridgeService.TEST_LATENCY) {
      // 由节点地址派生一个稳定的伪延迟，保证排序与「测试延迟」行为可观察
      const address: Object | undefined = params['host'];
      let seed: number = 11;
      if (typeof address === 'string') {
        const text: string = address as string;
        for (let i = 0; i < text.length; i++) {
          seed = (seed * 31 + text.charCodeAt(i)) % 997;
        }
      }
      const latencyMs: number = 40 + (seed % 460);
      const result: LatencyResult = { latencyMs: latencyMs, timeout: false };
      return success(result);
    }
    if (service === BridgeService.TEST_SPEED) {
      const result: Record<string, number> = { 'speedBps': 0 };
      return success(result);
    }
    if (service === BridgeService.GENERATE_CONFIG) {
      // MOCK 故意不返回 configJson：Bridge 只在拿到配置文本时才落盘，
      // 这样在预览器里点"连接"不会产生任何文件系统副作用。
      //
      // 但 geoAssets 必须报**真实探测结果**：Mock 模式下用户仍然可以在设置页
      // 下载分流资源，如果这里恒为 false，UI 会永远显示"资源缺失"，
      // 与用户在设置页看到的下载成功自相矛盾。
      const assetDirValue: Object | undefined = params['assetDir'];
      const assetDir: string = typeof assetDirValue === 'string' ? assetDirValue as string : '';
      const geoStatus: GeoAssetStatus = GeoAssetService.statusOf(assetDir);
      const result: ConfigPathResult = {
        configPath: '/data/storage/el2/base/haps/entry/files/core/config.json',
        assetPath: assetDir,
        notes: [],
        geoAssets: geoStatus.present,
        // 端口取自同一份 CORE_SOCKS_PORT 回落值：真实模式下这里回显的是
        // ConfigService.Generate 的结果字段（Go 侧 DefaultSocksPort/DefaultHTTPPort）。
        socksPort: CORE_SOCKS_PORT,
        httpPort: CORE_HTTP_PORT
      };
      return success(result);
    }
    if (service === BridgeService.RUNTIME_INFO) {
      const result: Record<string, number> = {
        'socksPort': CORE_SOCKS_PORT,
        'httpPort': CORE_HTTP_PORT
      };
      return success(result);
    }
    if (service === BridgeService.VALIDATE_NODE) {
      const result: Record<string, boolean> = { 'valid': true };
      return success(result);
    }
    return failure('unknown-service: ' + service);
  }
}

// ---------------------------------------------------------------------------
// 原生实现（`MOCK_BRIDGE` 置为 false 后生效；static import 已在文件顶部启用）
// ---------------------------------------------------------------------------
class NativeBridgeImpl implements IBridge {
  async invoke(service: string, params: Record<string, Object>): Promise<NativeEnvelope> {
    // 接入后把下面的 return 删掉，改为：
    //   const paramsJson: string = JSON.stringify(params);
    //   const raw: string = bridgeNative.Invoke(service, paramsJson);
    //   return decodeEnvelope(raw);
    // decodeEnvelope 已经处理「失败信封没有 result 字段」的情况，不要直接 JSON.parse。
    //
    // ⚠️ 如实说明（2026-10-11）：这一行**仍然**是 `native-bridge-not-linked`，
    // 本轮没有把它接上真实链路 —— 因为 `libcore.so` 尚未产出、也没有真机可验证。
    // 因此 `MOCK_BRIDGE` 一旦改成 false，UI 的每一次调用都会拿到失败信封
    // （见 MOCK_BRIDGE 的注释）。这是有意为之的"未接状态"，不是遗漏。
    return failure('native-bridge-not-linked');
  }
}

/** 当前桥接实现 */
const bridgeImpl: IBridge = MOCK_BRIDGE ? new MockBridgeImpl() : new NativeBridgeImpl();

// ===========================================================================
// 对外 API
// ===========================================================================

/** 与原生内核通信的桥接门面 */
export class Bridge {
  /** 当前是否 Mock 模式（UI 顶部横幅据此展示 MOCK 提示） */
  static isMock(): boolean {
    return MOCK_BRIDGE;
  }

  /** 通用调用（自动串联原生 Invoke） */
  static async invoke(service: string, params: Record<string, Object>): Promise<NativeEnvelope> {
    try {
      return await bridgeImpl.invoke(service, params);
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      Logger.error(TAG, 'invoke ' + service + ' failed: ' + err.code.toString() + ' ' + err.message);
      return failure(err.code.toString() + ' ' + err.message);
    }
  }

  /** 查询内核版本 */
  static async version(): Promise<string> {
    const envelope: NativeEnvelope = await Bridge.invoke(BridgeService.VERSION, {});
    if (!envelope.success) {
      return '';
    }
    const value: Object | undefined = envelope.result['version'];
    if (typeof value === 'string') {
      return value as string;
    }
    return '';
  }

  /** 查询内核运行状态 */
  static async coreStatus(): Promise<CoreStatusResult> {
    const envelope: NativeEnvelope = await Bridge.invoke(BridgeService.CORE_STATUS, {});
    const result: CoreStatusResult = { running: false, pid: 0, version: '' };
    if (!envelope.success) {
      return result;
    }
    const running: Object | undefined = envelope.result['running'];
    const pid: Object | undefined = envelope.result['pid'];
    const version: Object | undefined = envelope.result['version'];
    result.running = typeof running === 'boolean' ? running as boolean : false;
    result.pid = typeof pid === 'number' ? pid as number : 0;
    result.version = typeof version === 'string' ? version as string : '';
    return result;
  }

  /**
   * 生成内核配置并返回可用的配置文件路径。
   *
   * 分工（契约见 docs/design/ipc-contract.md §4「ConfigService.Generate」）：
   *   * **生成**在原生侧（Go 的 service/config）：只有它能链接 Xray 自己的
   *     loader，从而在生成本身就完成一次自检；
   *   * **落盘**在这里：沙箱布局（filesDir）只有 ArkTS 知道，原生侧不应该知道。
   *
   * @param bypassChina 是否「绕过大陆」（`AppSettings.bypassChina`）。**只在
   *                    routingMode=rule 时有意义**：true = 白名单（大陆直连、
   *                    其余走代理），false = 黑名单（已知被墙走代理、其余直连），
   *                    对应 v2rayN 的两份预设路由。此前这个开关在 UI 上存在
   *                    但从未传到这里，拨动时不产生任何行为差异。
   * @param paths CorePaths（filesDir + assetDir）。assetDir 会被传给原生用于
   *              探测 geoip.dat / geosite.dat 是否就位 —— 缺文件时内核会
   *              拒绝含 geoip:/geosite: 规则的**整份**配置，不是忽略那一条。
   */
  static async generateConfig(
    nodeId: string,
    routingMode: string,
    bypassChina: boolean,
    extra: string,
    paths: CorePaths
  ): Promise<ConfigPathResult> {
    const params: Record<string, Object> = {
      'nodeId': nodeId,
      'routingMode': routingMode,
      'bypassChina': bypassChina,
      'extra': extra,
      'assetDir': paths.assetDir
    };
    const envelope: NativeEnvelope = await Bridge.invoke(BridgeService.GENERATE_CONFIG, params);
    const result: ConfigPathResult = {
      configPath: '',
      assetPath: paths.assetDir,
      notes: [],
      geoAssets: false,
      socksPort: CORE_SOCKS_PORT,
      httpPort: CORE_HTTP_PORT
    };
    if (!envelope.success) {
      Logger.error(TAG, 'generateConfig failed: ' + envelope.error);
      return result;
    }

    result.notes = stringArrayField(envelope.result, 'notes');
    result.geoAssets = boolField(envelope.result, 'geoAssets');

    // 端口以原生结果为准；原生漏给（0/缺失）时**回落到唯一常量**，绝不把 0 传下去
    // —— 0 会让 Start 与 tun2socks 都拿到一个非法端口。
    //
    // ⚠️ 为什么端口是"读结果"而不是"当参数传进去"：契约 §4 的 ConfigService.Generate
    // **参数表里没有** socksPort/httpPort（只有 nodeId/routingMode/extra/assetDir/bypassChina），
    // Go 的 GenerateRequest 也没有这两个字段、端口由 config.DefaultSocksPort 决定并回显。
    // 若在这里多传两个字段，Go 会**静默忽略**（encoding/json 忽略未知字段），
    // 于是 ArkTS 会以为自己能覆盖端口 —— 那是比重复字面量更危险的假象。
    // 权威值只有一份（Go），ArkTS 负责把它转交给 Start 与 VPN 扩展。
    result.socksPort = numberField(envelope.result, 'socksPort');
    result.httpPort = numberField(envelope.result, 'httpPort');
    if (result.socksPort <= 0) {
      result.socksPort = CORE_SOCKS_PORT;
    }
    if (result.httpPort <= 0) {
      result.httpPort = CORE_HTTP_PORT;
    }

    const configJson: string = stringField(envelope.result, 'configJson');
    if (configJson.length > 0) {
      result.configPath = ConfigStore.writeConfig(paths.filesDir, configJson);
    }
    if (result.configPath.length === 0) {
      // Mock 实现直接给路径；真实实现落盘失败时也走这里，避免把空路径交给 Start
      result.configPath = stringField(envelope.result, 'configPath');
    }
    return result;
  }

  /**
   * 启动内核。
   *
   * @param socksPort / httpPort **必须来自 `ConfigPathResult`**（即
   *        `ConfigService.Generate` 的结果），不要各自写死：同一批端口要同时给
   *        内核的本地入站（契约 §5.1 的 Start 参数）与 VPN 扩展里的 tun2socks。
   *        传 0 或负数时回落到 `CORE_SOCKS_PORT` / `CORE_HTTP_PORT`。
   * @returns `StartCoreResult`；**判成功看 `ok`，不要看 `pid`**（pid 恒为 0）。
   */
  static async startCore(
    configPath: string,
    assetPath: string,
    socksPort: number,
    httpPort: number
  ): Promise<StartCoreResult> {
    const wantedSocks: number = socksPort > 0 ? socksPort : CORE_SOCKS_PORT;
    const wantedHttp: number = httpPort > 0 ? httpPort : CORE_HTTP_PORT;
    // 契约参数名为 configLocation / assetLocation；start:true 表示真正启动
    // （缺省 false 的行为是"只读配置 + 校验，不启动"，见契约文档 §4.1）。
    // socksPort/httpPort 是契约 §5.1 新增的可选参数，用于让原生知道"我们期望的入站端口"。
    const params: Record<string, Object> = {
      'configLocation': configPath,
      'assetLocation': assetPath,
      'socksPort': wantedSocks,
      'httpPort': wantedHttp,
      'start': true
    };
    const envelope: NativeEnvelope = await Bridge.invoke(BridgeService.START_CORE, params);
    const result: StartCoreResult = {
      ok: false,
      error: '',
      pid: 0,
      socksPort: wantedSocks,
      httpPort: wantedHttp,
      wired: false,
      notes: []
    };
    if (!envelope.success) {
      // 契约 §5 的参数没变、但服务本身失败（如配置读不到、Xray 起不来）。
      // 把原生 error 原文带出去：调用方要能区分"原生拒绝了"与"原生说没启动"。
      result.error = envelope.error.length > 0 ? envelope.error : 'start-core-envelope-failed';
      Logger.error(TAG, 'startCore failed: ' + result.error);
      return result;
    }
    // ⚠️ pid 不读原生了：契约的 Start 结果里没有 pid 字段（见 StartCoreResult 注释）。
    const started: boolean = boolField(envelope.result, 'started');
    result.wired = boolField(envelope.result, 'wired');
    result.notes = stringArrayField(envelope.result, 'notes');
    // 成功判据（唯一）：信封成功 **且** 原生明确回报 started=true。
    // 绝不能再用 pid <= 0 —— 那正是此前"原生启动成功、UI 却必然判失败"的缺陷。
    result.ok = started;
    if (!result.ok) {
      result.error = 'start-core-not-started';
    }
    const reportedSocks: number = numberField(envelope.result, 'socksPort');
    const reportedHttp: number = numberField(envelope.result, 'httpPort');
    if (reportedSocks > 0) {
      result.socksPort = reportedSocks;
    }
    if (reportedHttp > 0) {
      result.httpPort = reportedHttp;
    }
    return result;
  }

  /** 停止内核 */
  static async stopCore(): Promise<boolean> {
    const envelope: NativeEnvelope = await Bridge.invoke(BridgeService.STOP_CORE, {});
    return envelope.success;
  }

  /** 测试单个节点延迟（裸 TCP 握手，不经过 Xray —— 见契约文档 §4.1） */
  static async testLatency(address: string, port: number, timeoutMs: number): Promise<LatencyResult> {
    // 契约参数名为 host（不是 address）
    const params: Record<string, Object> = {
      'host': address,
      'port': port,
      'timeoutMs': timeoutMs
    };
    const envelope: NativeEnvelope = await Bridge.invoke(BridgeService.TEST_LATENCY, params);
    const result: LatencyResult = { latencyMs: 0, timeout: true };
    if (!envelope.success) {
      return result;
    }
    const latencyMs: Object | undefined = envelope.result['latencyMs'];
    // 契约用 reachable 表达可达性，UI 用 timeout 表达，这里做一次映射
    const reachable: Object | undefined = envelope.result['reachable'];
    result.latencyMs = typeof latencyMs === 'number' ? latencyMs as number : 0;
    result.timeout = typeof reachable === 'boolean' ? !(reachable as boolean) : result.latencyMs <= 0;
    return result;
  }

  // -------------------------------------------------------------------------
  // VPN 生命周期（SDK 调用，非原生模块）
  // -------------------------------------------------------------------------

  /**
   * 拉起 VPN 扩展并与其 ServiceExtension 建立连接。
   * @param context 调用方 UIAbilityContext（页面里通过 getContext(this) 取得）
   * @param configPath 内核配置文件路径（写入 want.parameters）
   * @param assetPath 资源目录路径（写入 want.parameters）
   * @param socksPort / httpPort 内核本地入站端口（写入 want.parameters）。
   *        扩展进程是**另一个进程**，拿不到 UI 进程的 `ConfigPathResult`，
   *        而它要用 SOCKS 端口去生成 tun2socks 的 YAML —— 不传的话扩展就只能自己
   *        猜一个数字，两侧一漂移就是"tun2socks 连到没人在听的端口"，静默不通。
   * @returns 连接 id；失败返回 -1
   */
  static async connectVpn(
    context: common.UIAbilityContext,
    configPath: string,
    assetPath: string,
    socksPort: number,
    httpPort: number
  ): Promise<number> {
    const params: Record<string, Object> = {};
    params[WANT_KEY_CONFIG_PATH] = configPath;
    params[WANT_KEY_ASSET_PATH] = assetPath;
    params[WANT_KEY_SOCKS_PORT] = socksPort > 0 ? socksPort : CORE_SOCKS_PORT;
    params[WANT_KEY_HTTP_PORT] = httpPort > 0 ? httpPort : CORE_HTTP_PORT;

    const want: Want = {
      bundleName: APP_BUNDLE_NAME,
      abilityName: VPN_ABILITY_NAME,
      parameters: params
    };

    try {
      await vpnExtension.startVpnExtensionAbility(want);
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      Logger.error(TAG, 'startVpnExtensionAbility failed: ' + err.code.toString() + ' ' + err.message);
      return -1;
    }

    try {
      const options: common.ConnectOptions = {
        onConnect: (elementName: bundleManager.ElementName, remote: Object) => {
          Logger.info(TAG, 'vpn extension connected: ' + elementName.abilityName);
        },
        onDisconnect: (elementName: bundleManager.ElementName) => {
          Logger.warn(TAG, 'vpn extension disconnected: ' + elementName.abilityName);
        },
        onFailed: (code: number) => {
          Logger.error(TAG, 'vpn extension connect failed: ' + code.toString());
        }
      };
      const connectionId: number = context.connectServiceExtensionAbility(want, options);
      return connectionId;
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      Logger.error(TAG, 'connectServiceExtensionAbility failed: ' + err.code.toString() + ' ' + err.message);
      return -1;
    }
  }

  /** 断开与 VPN 扩展的连接，并通知系统关闭扩展 */
  static async disconnectVpn(context: common.UIAbilityContext, connectionId: number): Promise<boolean> {
    let ok: boolean = true;
    if (connectionId >= 0) {
      try {
        await context.disconnectServiceExtensionAbility(connectionId);
      } catch (error) {
        const err: BusinessError = error as BusinessError;
        Logger.warn(TAG, 'disconnectServiceExtensionAbility failed: ' + err.code.toString() + ' ' + err.message);
        ok = false;
      }
    }
    const want: Want = { bundleName: APP_BUNDLE_NAME, abilityName: VPN_ABILITY_NAME };
    try {
      await vpnExtension.stopVpnExtensionAbility(want);
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      Logger.warn(TAG, 'stopVpnExtensionAbility failed: ' + err.code.toString() + ' ' + err.message);
      ok = false;
    }
    return ok;
  }
}

// ===========================================================================
// 数据面：TUN fd -> tun2socks -> 本地 SOCKS
// ---------------------------------------------------------------------------
// 位置（冻结契约：docs/design/ipc-contract.md §2）：
//
//   VpnConnection.create() 返回的 vNIC fd
//     -> tun2socks（libhevsocks5tun.so，heiher/hev-socks5-tunnel，MIT）
//     -> 127.0.0.1:<socksPort>
//     -> libcore.so（Xray-core 的本地 SOCKS 入站，分流规则在这一层生效）
//
// 为什么不把 fd 直接交给内核：见契约 §2 —— HarmonyOS 的 VPN fd 拒绝 Fstat，
// 且现役 libXray 不再导出 CGoSetTunFd。先例（x4h/Hey/Karing/etohos）可验证的
// 数据面也都是 tun2socks。
//
// 为什么选 hev 而不是 Go(gVisor) 版 tun2socks：
//   * 纯 C -> 不需要 Go 工具链 fork，绕开 B2（Go 没有 GOOS=ohos 目标）；
//   * MIT -> 仓库保持 MIT + Xray-core(MPL-2.0) 的边界，GPL 版会失守（§9 第 3 条）。
//
// 未验证：本门面与那个 .so 都没有在真机上跑过。hev 的后端能否处理 OHOS 的
// vNIC fd，就是公开问题 U3。
// ===========================================================================

/** tun2socks 的启动结果 */
export interface DataPlaneStartResult {
  /** 隧道是否已开始运行 */
  started: boolean;
  /** 实际加载到的 libhevsocks5tun.so 路径；未加载时为空串 */
  libPath: string;
  /** 失败原因；成功时为空串 */
  error: string;
}

/** tun2socks 的收发计数（来自 hev_socks5_tunnel_stats） */
export interface DataPlaneStats {
  running: boolean;
  txPackets: number;
  txBytes: number;
  rxPackets: number;
  rxBytes: number;
}

/**
 * tun2socks 数据面门面。
 *
 * 与 `Bridge` 一样，这里是接触原生 NAPI 的出口（另一处是 `Bridge.invoke`）。
 * 不同点：数据面不走 `Invoke` 的 JSON 服务路由，而是直接调 libbridge.so 上另外
 * 四个符号（Tun2socksStart/Stop/Stats/Available）—— 隧道跑在本进程、通过
 * 127.0.0.1:<socksPort> 与内核对话，不经过 C ABI。
 *
 * 所有调用都返回字符串信封，**永不抛异常**；缺少 .so 时拿到的是
 * `{"success":false,"error":"libhevsocks5tun.so is not available: <dlerror>"}`
 * 这种可读错误，而不是崩溃 —— 这正是真机排查需要的信号。
 */
export class DataPlane {
  /** libhevsocks5tun.so 是否可加载：路径 / ''（加载失败）/ 'unknown'（尚未尝试） */
  static available(): string {
    try {
      return bridgeNative.Tun2socksAvailable();
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      Logger.error(TAG, 'Tun2socksAvailable failed: ' + err.code.toString() + ' ' + err.message);
      return '';
    }
  }

  /**
   * 在 vNIC fd 上启动隧道。
   *
   * `configYaml` 是 hev 的 YAML 配置（tunnel / socks5 / misc 段），由调用方生成 ——
   * 因为 tun 地址、MTU、socks 端口都是 ArkTS 侧已经定义好的量。
   * `tunFd` 是 VpnConnection.create() 返回的 fd；调用方必须自己保留这份 fd，
   * 直到隧道停止。
   *
   * 立即返回：阻塞的 hev 主循环跑在原生侧的独立线程上。
   */
  static async start(configYaml: string, tunFd: number): Promise<DataPlaneStartResult> {
    const result: DataPlaneStartResult = { started: false, libPath: '', error: '' };
    let raw: string = '';
    try {
      raw = bridgeNative.Tun2socksStart(configYaml, tunFd);
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      result.error = 'Tun2socksStart threw: ' + err.code.toString() + ' ' + err.message;
      Logger.error(TAG, result.error);
      return result;
    }
    const envelope: NativeEnvelope = decodeEnvelope(raw);
    if (!envelope.success) {
      result.error = envelope.error;
      return result;
    }
    result.started = boolField(envelope.result, 'started');
    result.libPath = stringField(envelope.result, 'libPath');
    if (!result.started) {
      result.error = 'tun2socks reported started=false';
    }
    return result;
  }

  /** 停止隧道。幂等：停止一个空闲的隧道也算成功。 */
  static async stop(): Promise<boolean> {
    let raw: string = '';
    try {
      raw = bridgeNative.Tun2socksStop();
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      Logger.error(TAG, 'Tun2socksStop threw: ' + err.code.toString() + ' ' + err.message);
      return false;
    }
    const envelope: NativeEnvelope = decodeEnvelope(raw);
    if (!envelope.success) {
      Logger.warn(TAG, 'Tun2socksStop: ' + envelope.error);
      return false;
    }
    // 隧道线程的退出信息在这里回传：真机据此区分"我们停的"与"它自己挂了"。
    const lastError: string = stringField(envelope.result, 'lastError');
    if (lastError.length > 0) {
      Logger.warn(TAG, 'tun2socks exited with: ' + lastError);
    }
    return true;
  }

  /** 读取隧道计数；失败时返回全零且 running=false。 */
  static async stats(): Promise<DataPlaneStats> {
    const stats: DataPlaneStats = { running: false, txPackets: 0, txBytes: 0, rxPackets: 0, rxBytes: 0 };
    let raw: string = '';
    try {
      raw = bridgeNative.Tun2socksStats();
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      Logger.warn(TAG, 'Tun2socksStats failed: ' + err.code.toString() + ' ' + err.message);
      return stats;
    }
    const envelope: NativeEnvelope = decodeEnvelope(raw);
    if (!envelope.success) {
      Logger.warn(TAG, 'Tun2socksStats: ' + envelope.error);
      return stats;
    }
    stats.running = boolField(envelope.result, 'running');
    stats.txPackets = numberField(envelope.result, 'txPackets');
    stats.txBytes = numberField(envelope.result, 'txBytes');
    stats.rxPackets = numberField(envelope.result, 'rxPackets');
    stats.rxBytes = numberField(envelope.result, 'rxBytes');
    return stats;
  }
}

/** 从信封结果里取数字字段（类型不符时返回 0） */
function numberField(result: Record<string, Object>, key: string): number {
  const value: Object | undefined = result[key];
  return typeof value === 'number' ? value as number : 0;
}
