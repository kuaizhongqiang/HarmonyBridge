/**
 * Bridge.ets
 * 与原生内核通信的唯一出口（core 层）。
 *
 * 设计约束：
 * 1) 只有本文件允许接触原生 NAPI 模块；其它层只调用 Bridge 的 typed API。
 * 2) 原生模块 libbridge.so 由另一个并行工作流实现，当前**尚不存在**，
 *    因此这里只保留一行被注释掉的 import，并提供 MockBridge 作为等价实现。
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
  MOCK_CORE_VERSION,
  VPN_ABILITY_NAME,
  WANT_KEY_ASSET_PATH,
  WANT_KEY_CONFIG_PATH
} from '../constants/Common';
import { Logger } from '../utils/Logger';

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
// 为什么这一行仍然是注释：
//   `import ... from 'libbridge.so'` 是**静态导入**，产物 libbridge.so 属于
//   gitignore 的构建产物；本阶段（UI 脚手架）要求零外部依赖风险，因此默认不引入。
//   需要真机联调时按下面两步切换到真实桥接：
//     1. 取消下一行注释；
//     2. 把 MOCK_BRIDGE 置为 false（NativeBridgeImpl 即生效）。
//   NativeBridgeImpl 已按上面的契约写好，无需再改代码。
// import bridgeNative from 'libbridge.so';
// ===========================================================================

/** MOCK 总开关：true = 内存实现（不触发任何原生调用）；false = 走 NativeBridgeImpl */
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
 * §实现状态：`CoreService.Start` 目前原生侧仍是 tun-fd 模型，且
 * `CoreService.RuntimeInfo` / `ConfigService.Generate` / `PingService.SpeedTest`
 * 三个服务尚未实现 —— 因此 MOCK_BRIDGE 必须保持 true。详见契约文档 §4/§5。
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
  result: Object;
  error: string;
}

/** 空结果（Object 的最小实现） */
function emptyResult(): Object {
  const result: Record<string, string> = {};
  return result;
}

/** 组装失败信封 */
function failure(error: string): NativeEnvelope {
  const envelope: NativeEnvelope = { success: false, result: emptyResult(), error: error };
  return envelope;
}

/** 组装成功信封 */
function success(result: Object): NativeEnvelope {
  const envelope: NativeEnvelope = { success: true, result: result, error: '' };
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
    result: (resultValue === undefined || resultValue === null) ? emptyResult() : resultValue,
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

/** 启动内核的结果 */
export interface StartCoreResult {
  /**
   * 进程号。**当前恒为 0**：冻结契约下核心以动态库形式跑在 VPN 扩展进程内，
   * 不是独立进程，因此原生侧没有 pid 可回报。保留字段是为了将来若改走
   * childProcessManager 独立进程时不再改动上层调用点。
   */
  pid: number;
  /** 本地 socks 入站端口 */
  socksPort: number;
  /** 本地 http 入站端口 */
  httpPort: number;
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
  configPath: string;
  assetPath: string;
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
      const result: Record<string, string> = { version: this.coreVersion };
      return success(result);
    }
    if (service === BridgeService.START_CORE) {
      this.coreRunning = true;
      this.corePid = 4242;
      const result: StartCoreResult = { pid: this.corePid, socksPort: 10808, httpPort: 10809 };
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
      const result: Record<string, number> = { speedBps: 0 };
      return success(result);
    }
    if (service === BridgeService.GENERATE_CONFIG) {
      const result: ConfigPathResult = {
        configPath: '/data/storage/el2/base/haps/entry/files/config.json',
        assetPath: '/data/storage/el2/base/haps/entry/files/assets'
      };
      return success(result);
    }
    if (service === BridgeService.RUNTIME_INFO) {
      const result: Record<string, number> = { socksPort: 10808, httpPort: 10809 };
      return success(result);
    }
    if (service === BridgeService.VALIDATE_NODE) {
      const result: Record<string, boolean> = { valid: true };
      return success(result);
    }
    return failure('unknown-service: ' + service);
  }
}

// ---------------------------------------------------------------------------
// 原生实现（把顶部 import 取消注释、并把 MOCK_BRIDGE 置为 false 后生效）
// ---------------------------------------------------------------------------
class NativeBridgeImpl implements IBridge {
  async invoke(service: string, params: Record<string, Object>): Promise<NativeEnvelope> {
    // 接入后把下面的 return 删掉，改为：
    //   const paramsJson: string = JSON.stringify(params);
    //   const raw: string = bridgeNative.Invoke(service, paramsJson);
    //   return decodeEnvelope(raw);
    // decodeEnvelope 已经处理「失败信封没有 result 字段」的情况，不要直接 JSON.parse。
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

  /** 生成内核配置并返回路径 */
  static async generateConfig(
    nodeId: string,
    routingMode: string,
    extra: string
  ): Promise<ConfigPathResult> {
    const params: Record<string, Object> = {
      'nodeId': nodeId,
      'routingMode': routingMode,
      'extra': extra
    };
    const envelope: NativeEnvelope = await Bridge.invoke(BridgeService.GENERATE_CONFIG, params);
    const result: ConfigPathResult = { configPath: '', assetPath: '' };
    if (!envelope.success) {
      return result;
    }
    const configPath: Object | undefined = envelope.result['configPath'];
    const assetPath: Object | undefined = envelope.result['assetPath'];
    result.configPath = typeof configPath === 'string' ? configPath as string : '';
    result.assetPath = typeof assetPath === 'string' ? assetPath as string : '';
    return result;
  }

  /** 启动内核 */
  static async startCore(configPath: string, assetPath: string): Promise<StartCoreResult> {
    // 契约参数名为 configLocation / assetLocation；start:true 表示真正启动
    // （缺省 false 的行为是"只读配置 + 校验，不启动"，见契约文档 §4.1）。
    const params: Record<string, Object> = {
      'configLocation': configPath,
      'assetLocation': assetPath,
      'start': true
    };
    const envelope: NativeEnvelope = await Bridge.invoke(BridgeService.START_CORE, params);
    const result: StartCoreResult = { pid: 0, socksPort: 0, httpPort: 0 };
    if (!envelope.success) {
      Logger.error(TAG, 'startCore failed: ' + envelope.error);
      return result;
    }
    // 原生当前不返回 pid（见 StartCoreResult 注释）
    const pid: Object | undefined = envelope.result['pid'];
    const socksPort: Object | undefined = envelope.result['socksPort'];
    const httpPort: Object | undefined = envelope.result['httpPort'];
    result.pid = typeof pid === 'number' ? pid as number : 0;
    result.socksPort = typeof socksPort === 'number' ? socksPort as number : 0;
    result.httpPort = typeof httpPort === 'number' ? httpPort as number : 0;
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
   * @returns 连接 id；失败返回 -1
   */
  static async connectVpn(
    context: common.UIAbilityContext,
    configPath: string,
    assetPath: string
  ): Promise<number> {
    const params: Record<string, Object> = {};
    params[WANT_KEY_CONFIG_PATH] = configPath;
    params[WANT_KEY_ASSET_PATH] = assetPath;

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
