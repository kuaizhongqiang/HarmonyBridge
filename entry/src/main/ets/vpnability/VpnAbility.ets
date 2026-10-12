/**
 * VpnAbility.ets
 * HarmonyOS 第三方 VPN 扩展（VpnExtensionAbility）骨架。
 *
 * 它在 module.json5 里声明为：{ name: "VpnAbility", srcEntry: "./ets/vpnability/VpnAbility.ets", type: "vpn" }，
 * 只需要 ohos.permission.INTERNET，不需要（也拿不到）ohos.permission.MANAGE_VPN。
 *
 * 生命周期 —— 只以 SDK 契约里声明的回调为准：
 *   onCreate(want)   -> 建立 VpnConnection，并**立即 create(config) 拿到虚拟网卡 fd**；
 *                       同时从 want.parameters 取出配置路径 / 资源目录。
 *                       这个 fd 之后交给 **tun2socks**（不是内核的 tun 入站）；
 *                       内核只做本地 SOCKS/HTTP 入站（裁决见
 *                       docs/design/ipc-contract.md §2）。
 *   onDestroy()      -> 清理定时器 + process.ProcessManager().exit(0) 退出扩展进程
 *
 * 关于 onConnect / onDisconnected（2026-10-12 真机修正）：
 *   本机 SDK 的 @ohos.app.ability.VpnExtensionAbility.d.ts 只声明了
 *   onCreate(want) 与 onDestroy()，**没有**声明 onConnect。此前据此推断
 *   "运行时可能不回调它们"。
 *
 *   🧪 真机日志（华为 TYR-AL00 / HarmonyOS 6.1.0.145）证明 **`onConnect` 确实会被回调**：
 *       VpnAbility onCreate config= asset= socksPort=10808 httpPort=10809
 *       onRequest, want:VpnAbility, startId:1
 *       VpnAbility onConnect (non-contract, idempotent fallback)
 *   但**网卡的创建仍然留在 onCreate**：那是 SDK 契约保证的入口，
 *   依赖一个未写进 .d.ts 的回调去建网卡，一旦某个版本不回调就是
 *   "扩展起来了、却没有任何网卡"，VPN 完全不生效。
 *   onConnect / onDisconnected 继续只作为幂等兜底与额外可观测点保留。
 *
 * 说明：数据面通过 core/Bridge 的 `DataPlane` 门面调用原生 tun2socks
 * （libhevsocks5tun.so，构建见 scripts/build-tun2socks.*）。内核 libcore.so 的
 * 拉起不在本文件里（CoreService.Start 负责），本文件只负责"把 fd 交给数据面"。
 */
import { VpnExtensionAbility } from '@kit.NetworkKit';
import { vpnExtension } from '@kit.NetworkKit';
import { connection } from '@kit.NetworkKit';
import { statistics } from '@kit.NetworkKit';
import { commonEventManager } from '@kit.BasicServicesKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Want } from '@kit.AbilityKit';
import { process } from '@kit.ArkTS';
import {
  APP_BUNDLE_NAME,
  CORE_HTTP_PORT,
  CORE_SOCKS_PORT,
  CORE_STATE_ERROR,
  CORE_STATE_HTTP_PORT,
  CORE_STATE_SOCKS_PORT,
  CORE_STATE_STARTED,
  CORE_STATE_VERSION,
  CORE_STATE_WIRED,
  VPN_CORE_STATE_EVENT,
  VPN_IFACE_NAME,
  VPN_TRAFFIC_EVENT,
  VPN_TUN_ADDRESS,
  VPN_TUN_DNS,
  VPN_TUN_PREFIX_LENGTH,
  WANT_KEY_ASSET_PATH,
  WANT_KEY_CONFIG_PATH,
  WANT_KEY_HTTP_PORT,
  WANT_KEY_SOCKS_PORT
} from '../constants/Common';
import { Bridge, DataPlane, DataPlaneStartResult, StartCoreResult } from '../core/Bridge';
import { ConfigStore } from '../core/ConfigStore';

/** 日志域 / 标签（扩展进程独立打日志，便于 hdc 过滤） */
const DOMAIN: number = 0x0000;
const TAG: string = 'VpnAbility';

/** 流量上报间隔（毫秒） */
const TRAFFIC_INTERVAL_MS: number = 1000;
/**
 * 隧道 MTU（同时写入 `VpnConfig.mtu` 与 tun2socks 的 `tunnel.mtu`，两者必须是同一个值）。
 *
 * 🔴 **这里从 1500 改成 1280，是有依据的，不是随手调小**（2026-10-12 真机实测 + 官方文档）：
 *
 *   1. API 允许范围是 `[576,1500]`
 *      （`@ohos.net.vpnExtension.d.ts:322-328`），1280 合法；而官方 VPN Demo 用的是
 *      **1400**（它的数据面是裸 UDP 隧道，没有 TLS 头）。
 *   2. 本机的上行网卡 `rmnet0` 的 MTU 实测就是 **1400**（`ifconfig rmnet0`）。
 *      而我们的隧道比官方 Demo 多一层 Xray 的 REALITY/TLS：内层一个满段载荷
 *      会被包成 `载荷 + TLS 记录头(~21) + 外层 TCP(~32，含时间戳选项) + 外层 IP(20)`
 *      ≈ `载荷 + 73` 字节再上路。
 *   3. 于是"内层满段"的约束是：`MSS ≤ 1400 − 73 = 1327`，而 `MSS = MTU − 40`，
 *      ⇒ `MTU ≤ 1367`。**用 1500（MSS 1460）时，每一个满段在内层都要被外层 TCP
 *      重切成两段** —— 大流量下包数翻倍，正是"下行慢"的典型形态（上传是小包，
 *      基本不受影响，所以症状表现为"上行正常、下行几乎不动"）。
 *      取 **1280**（MSS 1240，外层 ≤ 1313）留出约 87 字节余量，避免运营商把上行
 *      MTU 降到 1400 以下时再次踩线。
 *
 * ⚠️ 后续应改由设置页的 MTU 项驱动（经 want.parameters 传给扩展进程），
 * 而不是在这里写死；设置页的 `MTU_MIN/MTU_MAX` 已经是 576/1500。
 */
const DEFAULT_MTU: number = 1280;
/**
 * `vpn.create()` 的创建超时（毫秒）。
 *
 * 🔴 **为什么必须有这条兜底**（2026-10-12 真机实测）：`vpn.create()` 曾经
 * **既不 resolve 也不 reject** —— 而系统层面 VPN 已经生效：`vpn-tun` 接口建起来了、
 * 默认路由被接管。结果是所有应用的流量进了 TUN 却没有任何进程在读它，
 * **手机直接断网**，并且从应用到自己日志里**没有任何一处报错**。
 * 超时后结束扩展进程，系统会随之撤销 VPN，用户网络自动恢复。
 */
const CREATE_TIMEOUT_MS: number = 8000;
/** 内核启动后转写到本进程日志的 Xray 日志行数（见 startCoreInProcess） */
const CORE_LOG_TAIL_LINES: number = 80;
// ⚠️ 这里**不再**有 `const SOCKS_PORT = 10808`。
// 端口由 UI 进程通过 want.parameters 传进来（WANT_KEY_SOCKS_PORT / WANT_KEY_HTTP_PORT），
// 因为扩展是**另一个进程**，拿不到 UI 的 ConfigPathResult；回落值统一取
// constants/Common.ets 的 CORE_SOCKS_PORT / CORE_HTTP_PORT（唯一 ArkTS 来源）。
// 曾经的缺陷：这个文件、Bridge 的 Start 默认值、Go 侧的 DefaultSocksPort 各自
// 写死同一个数字，一旦漂移，症状是 tun2socks 连到一个没人在听的端口 —— 静默不通。

export default class VpnAbility extends VpnExtensionAbility {
  private vpnConnection: vpnExtension.VpnConnection | undefined = undefined;
  /** 内核写入的配置路径（来自 want.parameters[CONFIG_PATH]） */
  private configPath: string = '';
  /** 资源目录（geoip / geosite 等，来自 want.parameters[ASSET_PATH]） */
  private assetPath: string = '';
  /**
   * 内核本地入站端口，来自 want.parameters（UI 进程转交的
   * `ConfigService.Generate` 结果值）。收不到时回落到 constants/Common 的常量。
   */
  private socksPort: number = CORE_SOCKS_PORT;
  private httpPort: number = CORE_HTTP_PORT;
  /**
   * 网卡创建状态。onCreate（SDK 契约保证）与 onConnect（非契约、运行时可能不被
   * 回调）都会尝试创建网卡，用这两个标志做幂等守卫，保证恰好创建一次。
   */
  private vpnCreating: boolean = false;
  private vpnCreated: boolean = false;
  /** `vpn.create()` 的看门狗定时器 id；-1 表示未启动。语义见 CREATE_TIMEOUT_MS。 */
  private createWatchdogId: number = -1;
  /** 定时器 id */
  private timerId: number = -1;
  /** 上一次采样的收发字节数，用于计算瞬时速率 */
  private lastTx: number = 0;
  private lastRx: number = 0;
  /** 内核是否已在**本进程**（扩展进程）启动 */
  private coreStarted: boolean = false;
  /** 内核版本（供状态上报） */
  private coreVersion: string = '';

  onCreate(want: Want): void {
    this.configPath = readWantString(want, WANT_KEY_CONFIG_PATH);
    this.assetPath = readWantString(want, WANT_KEY_ASSET_PATH);
    // ⚠️ SDK 注明 `want.parameters` **只在首次启动 VPN 时传递**
    // （`@ohos.net.vpnExtension.d.ts:78`）—— 第二次连接起上面两个都会是空串。
    // 而内核现在**由本进程拉起**，路径不能靠碰运气：沙箱布局是确定的，自己算。
    // 曾经的隐患：CoreService.Start 拿到空 configLocation 会退化成"纯诊断调用"，
    // **静默不启动内核**，而日志上看起来一切正常。
    if (this.configPath.length === 0) {
      const filesDir: string = this.context.filesDir;
      this.configPath = ConfigStore.configFilePath(filesDir);
      this.assetPath = ConfigStore.assetsDirPath(filesDir);
      console.info(`${TAG} want carried no paths; derived from filesDir=${filesDir}`);
    }
    // 端口从 want 收；收不到就用常量回落。两者都会打印，方便在真机上一条日志就
    // 看出"tun2socks 要连的端口"与"内核该监听的端口"是否一致。
    this.socksPort = readWantPort(want, WANT_KEY_SOCKS_PORT, CORE_SOCKS_PORT);
    this.httpPort = readWantPort(want, WANT_KEY_HTTP_PORT, CORE_HTTP_PORT);
    console.info(`${TAG} onCreate config=${this.configPath} asset=${this.assetPath} `
      + `socksPort=${this.socksPort} httpPort=${this.httpPort}`);

    // 注册「用户授权结果」观察者（API 26 起可用）。
    // 只为一件事：让日志能区分**授权被拒**与**扩展起来了但网卡没建成** ——
    // 没有它，这两种情况在 hilog 里完全一样（都只有一句 onCreate），
    // 而它们的排查方向相反。
    try {
      const observer: vpnExtension.VpnObserver = vpnExtension.createVpnObserver();
      observer.onAuthorizationResult((granted: boolean) => {
        console.info(`${TAG} user authorization result: ${granted}`);
      });
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      console.warn(`${TAG} createVpnObserver unavailable: ${err.code} ${err.message}`);
    }

    try {
      this.vpnConnection = vpnExtension.createVpnConnection(this.context);
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      console.error(`${TAG} createVpnConnection failed: ${err.code} ${err.message}`);
      return;
    }

    // onCreate 是 SDK 契约里唯一**保证**会被调用的入口，网卡必须在这里创建。
    // 若等 onConnect（非契约、运行时可能根本不回调）才创建，结果就是
    // "扩展起来了、却没有任何网卡"，VPN 完全不生效。
    this.ensureVpnCreated();
  }

  /**
   * ⚠️ 非 SDK 契约：本机 SDK 的 @ohos.app.ability.VpnExtensionAbility.d.ts
   * 只声明了 onCreate / onDestroy，**没有** onConnect。
   *
   * 保留它的原因：某些系统版本可能额外回调它，此时作为幂等兜底 ——
   * 与 onCreate 共享守卫，绝不会重复建网卡。
   */
  onConnect(): void {
    console.info(`${TAG} onConnect (non-contract, idempotent fallback)`);
    this.ensureVpnCreated();
  }

  /**
   * ⚠️ 非 SDK 契约（同 onConnect）。保留为"若被回调则提前释放网卡"；
   * 真正的释放由 onDestroy 负责。
   */
  onDisconnected(): void {
    console.info(`${TAG} onDisconnected (non-contract)`);
    this.stopTrafficReporting();
    this.destroyVpn();
  }

  onDestroy(): void {
    console.info(`${TAG} onDestroy`);
    this.stopTrafficReporting();
    this.destroyVpn();
    // 扩展结束后主动退出进程，避免残留（否则系统会再次拉起上一次的 VPN 扩展）
    const processManager: process.ProcessManager = new process.ProcessManager();
    processManager.exit(0);
  }

  /**
   * 幂等地创建虚拟网卡。
   *
   * 调用点有两个：onCreate（契约保证）与 onConnect（非契约、可选）。
   * 无论 SDK 是否回调 onConnect，网卡都恰好被创建一次。
   */
  private ensureVpnCreated(): void {
    if (this.vpnCreated || this.vpnCreating) {
      return;
    }
    const vpn: vpnExtension.VpnConnection | undefined = this.vpnConnection;
    if (vpn === undefined) {
      console.error(`${TAG} ensureVpnCreated without VpnConnection, abort`);
      return;
    }
    this.vpnCreating = true;

    const config: vpnExtension.VpnConfig = buildVpnConfig();
    // 打点在**调用之前**：真机上曾出现 create() 哑火，"调用前"这一条是
    // 区分"根本没调到"与"调了但没回来"的唯一依据。
    // （不在这里打印 config 的字段：`VpnConfig` 的数组字段都是可选的，
    //  ArkTS 严格模式下要额外做收窄，收益不抵风险 —— 配置形状由 buildVpnConfig 决定。）
    console.info(`${TAG} vpn.create() -> begin`);

    // 看门狗（理由见 CREATE_TIMEOUT_MS）：到点仍未建成，就结束扩展进程，
    // 让系统撤销 VPN，把用户的网络还回去。宁可"连接失败"，也不许"静默断网"。
    this.clearCreateWatchdog();
    this.createWatchdogId = setTimeout(() => {
      this.createWatchdogId = -1;
      if (this.vpnCreated) {
        return;
      }
      console.error(`${TAG} vpn.create() did not settle within ${CREATE_TIMEOUT_MS}ms; `
        + `exiting the extension process to release the VPN and restore connectivity`);
      const processManager: process.ProcessManager = new process.ProcessManager();
      processManager.exit(0);
    }, CREATE_TIMEOUT_MS);

    vpn.create(config).then((vfd: number) => {
      this.clearCreateWatchdog();
      this.vpnCreating = false;
      this.vpnCreated = true;
      console.info(`${TAG} vpn created, vfd=${vfd}`);
      // 必须**先**豁免本进程自己的出站，再启动内核与数据面：
      // 内核对代理服务器的那条 TCP 一旦被自己的默认路由
      // 抓回 `vpn-tun`，就是一个自我吞噬的环 —— 症状正是扩展进程 ~100% CPU 空转、
      // 上行计数照涨、下行归零。见 protectOwnProcessNet 的注释。
      this.protectOwnProcessNet();
      // 顺序有意义（2026-10-12 修正）：
      //   1. **先在扩展进程内启动内核**（本地 SOCKS/HTTP 入站）；
      //   2. 再把 fd 交给 tun2socks —— 它一起来就会去连 10808。
      // 反过来的话，首批连接会打到没人监听的口上。
      // 为什么内核要放在扩展进程：见 startCoreInProcess 的注释。
      this.startCoreInProcess().then(() => {
        this.startDataPlane(vfd);
        this.startTrafficReporting();
      });
    }).catch((error: BusinessError) => {
      this.clearCreateWatchdog();
      this.vpnCreating = false;
      // 2203002 = VPN 已存在：上一次没 destroy 干净，需要用户先断开再重试。
      console.error(`${TAG} vpn.create failed: ${error.code} ${error.message}`);
    });
  }

  /** 取消 `vpn.create()` 看门狗（幂等）。 */
  private clearCreateWatchdog(): void {
    if (this.createWatchdogId < 0) {
      return;
    }
    clearTimeout(this.createWatchdogId);
    this.createWatchdogId = -1;
  }

  /** 幂等地销毁虚拟网卡（onDisconnected 与 onDestroy 都会调用）。 */
  private destroyVpn(): void {
    const vpn: vpnExtension.VpnConnection | undefined = this.vpnConnection;
    if (vpn === undefined) {
      return;
    }
    this.vpnCreated = false;
    this.vpnCreating = false;
    this.clearCreateWatchdog();
    // 先停数据面再销毁网卡：反过来会让 tun2socks 在已经关闭的 fd 上读，
    // 日志里会出现一串 "read: bad file descriptor" 之类的噪声。
    this.stopDataPlane();
    vpn.destroy().then(() => {
      console.info(`${TAG} vpn destroyed`);
    }).catch((error: BusinessError) => {
      console.error(`${TAG} vpn.destroy failed: ${error.code} ${error.message}`);
    });
  }

  // -------------------------------------------------------------------------
  // 防环：让本应用自己的出站绕过 VPN
  // -------------------------------------------------------------------------

  /**
   * 让**本应用的进程**（其中承载内核出站的那条 TCP）绕过 VPN 路由，直连物理网络。
   *
   * 官方接口（本机 SDK `@ohos.net.vpnExtension.d.ts:267-275`，**@since 22**）：
   *   > Protects application processes against a VPN connection. The data sent through
   *   > the protected processes is transmitted over the physical network without
   *   > traversing the VPN.
   *
   * **为什么需要它，而不只是 `blockedApplications`**：
   *   `blockedApplications` 的语义是"列表里的应用**不**按 routes 被代理"
   *   （`:377-388`），本仓库此前据此断言"自身包名在列表里就止住了环路"——
   *   但那个断言自标 ❓ 未验证（`TODO.md` §2.2）。
   *   而 `protectProcessNet` 是官方**专门**为"保护应用进程自身出站"提供的接口：
   *   语义没有歧义，而且是**进程级**的、不需要 fd —— 这恰好解决了当初
   *   `protect(socketFd)` 走不通的问题（Go 侧没有 hook 能把自建 socket 的 fd
   *   交给 ArkTS 去保护）。
   *
   *   两个都留着：一个走官方推荐路径保证正确性，另一个继续兜住进程级以外的情形。
   *
   * ⚠️ 运行时可能不存在（本机实测 `createVpnObserver` 就是 `.d.ts` 里有、
   * 运行时 `is not callable`），所以这里必须 try/catch 并如实记日志，
   * 绝不能让防环失败把建网卡流程带崩。
   */
  private protectOwnProcessNet(): void {
    const vpn: vpnExtension.VpnConnection | undefined = this.vpnConnection;
    if (vpn === undefined) {
      return;
    }
    try {
      vpn.protectProcessNet().then(() => {
        console.info(`${TAG} protectProcessNet ok: this process bypasses the VPN`);
      }).catch((error: BusinessError) => {
        console.error(`${TAG} protectProcessNet rejected: ${error.code} ${error.message}`);
      });
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      console.warn(`${TAG} protectProcessNet unavailable: ${err.code} ${err.message}`);
    }
  }

  // -------------------------------------------------------------------------
  // 内核（Xray）：由**本进程**（扩展进程）拉起
  // -------------------------------------------------------------------------

  /**
   * 在**扩展进程内**启动 Xray 内核，并在启动后把状态上报给 UI 进程。
   *
   * 🔴 **为什么必须在这里，而不是 UI 进程**（2026-10-12 真机实测）：
   *   `CoreService.Start` 原先由 UI 进程的 `ConnectionViewModel.connect()` 调用，
   *   于是内核跑在 **UI 进程**里。而用户一切到别的应用，UI 进程就被系统冻结
   *   —— 实测 `/proc/<pid>/stat` 的 cpuTicks 在 10 秒内 delta 恰好为 0。
   *   Xray 的 accept 循环随之停摆，连锁反应是：
   *     * 扩展进程里的 tun2socks 把流量交给 `127.0.0.1:10808` → **没人应答**；
   *     * `netstat` 上出现大量 `SYN_SENT`，10808 的 accept 队列堵死
   *       （`LISTEN` 行的 Recv-Q 常年 20+）；
   *     * **上行计数照涨**（app 写进 tun），**下行归零**；
   *     * 扩展进程因为反复重试而 ~100% CPU 空转。
   *   净效果是"盯着它时能用、一切后台就废"。
   *
   *   扩展进程是系统为 VPN 保活的进程，不随前台/后台被冻结 —— 内核放这里，
   *   数据面才能持续工作。这也是 `ConnectionViewModel.ets` 头注释原本就写明的
   *   设计（"由扩展进程拉起 Xray"）—— 此前**实现与它不符**。
   */
  private async startCoreInProcess(): Promise<void> {
    let started: StartCoreResult;
    try {
      started = await Bridge.startCore(this.configPath, this.assetPath, this.socksPort, this.httpPort);
    } catch (error) {
      const err: BusinessError = error as BusinessError;
      const reason: string = 'start-core threw: ' + err.code.toString() + ' ' + err.message;
      console.error(`${TAG} ${reason}`);
      this.publishCoreState(false, false, '', reason);
      return;
    }

    for (let i = 0; i < started.notes.length; i++) {
      console.warn(`${TAG} core note: ${started.notes[i]}`);
    }
    if (!started.ok) {
      const reason: string = started.error.length > 0 ? started.error : 'start-core-failed';
      console.error(`${TAG} core start failed: ${reason}`);
      this.publishCoreState(false, false, '', reason);
      return;
    }

    this.coreStarted = true;
    // 版本也必须在**本进程**问：`libcore.so` 按进程各加载一份，
    // UI 进程问到的只是它自己那份从未启动过的空实例。
    this.coreVersion = await Bridge.version();
    console.info(`${TAG} core started in the extension process, version=${this.coreVersion}`);
    // 把内核自己的日志转写到本进程的 console（进而进 hilog）。
    // Xray 的日志只进内存环形缓冲，不落盘也不进 hilog
    // （`golang/service/log/log.go:158-178`），而**只有持有内核的那个进程**读得到它 ——
    // 现在那个进程是扩展进程，所以这里才是唯一有意义的抓取点。没有它，
    // "连上了但某个站打不开 / 下载不动"在设备侧完全不可观测。
    await Bridge.dumpCoreLog(CORE_LOG_TAIL_LINES);
    // 此刻"入站已监听"成立，但数据面还没起来 —— wired 仍为 false，
    // 等 startDataPlane 成功后再上报一次。绝不提前把 wired 说成 true。
    this.publishCoreState(true, false, this.coreVersion, '');
  }

  /**
   * 把内核状态上报给 UI 进程。
   *
   * 跨进程是必须的：UI 进程里读 `CoreService.Status` 只会读到自己那份空实例。
   * 顺带这也给出了一个**诚实的 `wired`** —— Go 内核里那个字段恒为 false，
   * 是一句改不掉的假话（`golang/service/core/core.go:110-114`、`:210`；
   * 改它要重编 `.so`，而 Windows 上交叉编译不出来，见 TODO.md §1.1）。
   * 这里的定义是：「内核已启动」**且**「tun2socks 已运行」。
   */
  private publishCoreState(started: boolean, wired: boolean, version: string, error: string): void {
    const parameters: Record<string, Object> = {};
    parameters[CORE_STATE_STARTED] = started;
    parameters[CORE_STATE_WIRED] = wired;
    parameters[CORE_STATE_VERSION] = version;
    parameters[CORE_STATE_SOCKS_PORT] = this.socksPort;
    parameters[CORE_STATE_HTTP_PORT] = this.httpPort;
    parameters[CORE_STATE_ERROR] = error;
    const options: commonEventManager.CommonEventPublishData = { parameters: parameters };
    commonEventManager.publish(VPN_CORE_STATE_EVENT, options, (err: BusinessError) => {
      if (err !== undefined && err !== null && err.code !== 0) {
        console.warn(`${TAG} publish core state failed: ${err.code}`);
      }
    });
  }

  // -------------------------------------------------------------------------
  // 数据面：TUN fd -> tun2socks（libhevsocks5tun.so）-> 127.0.0.1:SOCKS
  // -------------------------------------------------------------------------

  /**
   * 把 vNIC fd 交给 tun2socks。
   *
   * 失败时只记日志、不抛异常：网卡已经建好，扩展该做的是"如实报告"，
   * 而不是把整个 VPN 拆掉。
   */
  private startDataPlane(tunFd: number): void {
    // 端口用**收进来的那一个**（UI 进程转交的 Generate 结果），不是本地常量。
    const yaml: string = buildTun2socksYaml(this.socksPort);
    console.info(`${TAG} starting tun2socks on fd=${tunFd} socksPort=${this.socksPort}`);
    DataPlane.start(yaml, tunFd).then((result: DataPlaneStartResult) => {
      if (result.started) {
        console.info(`${TAG} tun2socks running (lib=${result.libPath})`);
        // 到这一步"内核在监听 + tun2socks 在跑"才同时成立 —— 这才是真的 wired。
        this.publishCoreState(this.coreStarted, this.coreStarted, this.coreVersion, '');
      } else {
        console.error(`${TAG} tun2socks not started: ${result.error}`);
        this.publishCoreState(this.coreStarted, false, this.coreVersion, result.error);
      }
    }).catch((error: BusinessError) => {
      console.error(`${TAG} tun2socks start rejected: ${error.code} ${error.message}`);
      this.publishCoreState(this.coreStarted, false, this.coreVersion,
        'tun2socks start rejected: ' + error.code.toString());
    });
  }

  /** 停止数据面（幂等）。onDisconnected / onDestroy 都会调用。 */
  private stopDataPlane(): void {
    DataPlane.stop().then((stopped: boolean) => {
      if (stopped) {
        console.info(`${TAG} tun2socks stopped`);
      }
    }).catch((error: BusinessError) => {
      console.error(`${TAG} tun2socks stop rejected: ${error.code} ${error.message}`);
    });
  }

  // -------------------------------------------------------------------------
  // 流量上报：定时读取 vpn-tun 网卡的收发字节，换算成速率后发布公共事件
  // -------------------------------------------------------------------------

  private startTrafficReporting(): void {
    if (this.timerId >= 0) {
      return;
    }
    this.timerId = setInterval(() => {
      this.reportTrafficOnce();
    }, TRAFFIC_INTERVAL_MS);
  }

  private stopTrafficReporting(): void {
    if (this.timerId < 0) {
      return;
    }
    clearInterval(this.timerId);
    this.timerId = -1;
  }

  private reportTrafficOnce(): void {
    // statistics.getIfaceTxBytes/getIfaceRxBytes 返回的是该网卡自启动以来的累计字节数
    statistics.getIfaceTxBytes(VPN_IFACE_NAME).then((tx: number) => {
      statistics.getIfaceRxBytes(VPN_IFACE_NAME).then((rx: number) => {
        const speedUp: number = computeSpeed(tx, this.lastTx);
        const speedDown: number = computeSpeed(rx, this.lastRx);
        this.lastTx = tx;
        this.lastRx = rx;
        publishTraffic(tx, rx, speedUp, speedDown);
      }).catch((error: BusinessError) => {
        console.warn(`${TAG} getIfaceRxBytes failed: ${error.code}`);
      });
    }).catch((error: BusinessError) => {
      console.warn(`${TAG} getIfaceTxBytes failed: ${error.code}`);
    });
  }
}

/**
 * 读取 want.parameters 里的字符串。
 * want.parameters 的类型是 { [key: string]: Object }，这里做一次显式判空与类型收窄。
 */
function readWantString(want: Want, key: string): string {
  const parameters: Record<string, Object> | undefined = want.parameters;
  if (parameters === undefined) {
    return '';
  }
  const value: Object | undefined = parameters[key];
  if (value === undefined || value === null) {
    return '';
  }
  if (typeof value === 'string') {
    return value as string;
  }
  return '';
}

/**
 * 读取 want.parameters 里的端口号。
 *
 * 接受 number 与"数字字符串"两种形态：want 跨进程传递时类型理论上会被保留，
 * 但这里宁可多接一种形态 —— 若只认 number，一旦运行时把它变成字符串，
 * 扩展就会**静默**回落到常量，而那正是这条链路要消灭的"两侧各猜一个端口"。
 * 非法值（缺失 / 非数字 / <=0）一律回落 `fallback`。
 */
function readWantPort(want: Want, key: string, fallback: number): number {
  const parameters: Record<string, Object> | undefined = want.parameters;
  if (parameters === undefined) {
    return fallback;
  }
  const value: Object | undefined = parameters[key];
  if (typeof value === 'number') {
    const port: number = value as number;
    return port > 0 ? port : fallback;
  }
  if (typeof value === 'string') {
    const parsed: number = Number.parseInt(value as string, 10);
    return Number.isNaN(parsed) || parsed <= 0 ? fallback : parsed;
  }
  return fallback;
}

/**
 * 构造 VpnConfig。
 * 路由策略：默认路由（0.0.0.0/0）交给 VPN，DNS 指向 TUN 内网地址。
 *
 * 防环（关键，见冻结契约 docs/design/ipc-contract.md §2 与 AGENT.md §2.4）：
 * 把**本应用自己的包名**放进 `blockedApplications`，使本应用自己的出站流量
 * 不回到 TUN，从而**不需要** `protect()`（Go 侧没有 hook 能把自建 socket 交给
 * ArkTS 调 protect，所以那条路走不通）。
 *
 * SDK 取证（本机 `D:\Harmony\DevEco Studio\sdk\default\openharmony\ets\api\@ohos.net.vpnExtension.d.ts`，
 * `VpnConfig` 定义见 :283）：`blockedApplications?: Array<string>`（:388），
 * 语义为"**只有不在列表里的应用**才会按 routes 被 VPN 代理"（:378-381），
 * 即列表 = 被排除、直连的应用；取值是 **bundleName 字符串数组**（不是 ApplicationInfo[]）。
 * 同一份注释两处（:371 / :383）都声明它与 `trustedApplications` **互斥**，
 * 因此这里**只设 blockedApplications**，绝不两个都设。
 *
 * ⚠️ 未验证：真机上"自身包名在 blockedApplications 里是否确实止住环路"未经实测
 * （没有真机，AGENT.md §1 / §7 B3）。
 */
function buildVpnConfig(): vpnExtension.VpnConfig {
  const address: connection.NetAddress = { address: VPN_TUN_ADDRESS, family: 1 };
  const linkAddress: connection.LinkAddress = { address: address, prefixLength: VPN_TUN_PREFIX_LENGTH };

  const defaultDestinationAddress: connection.NetAddress = { address: '0.0.0.0', family: 1 };
  const defaultDestination: connection.LinkAddress = { address: defaultDestinationAddress, prefixLength: 0 };
  const gateway: connection.NetAddress = { address: '0.0.0.0', family: 1 };
  const defaultRoute: connection.RouteInfo = {
    interface: VPN_IFACE_NAME,
    destination: defaultDestination,
    gateway: gateway,
    hasGateway: false,
    isDefaultRoute: true
  };

  const config: vpnExtension.VpnConfig = {
    addresses: [linkAddress],
    routes: [defaultRoute],
    dnsAddresses: [VPN_TUN_DNS],
    mtu: DEFAULT_MTU,
    isIPv4Accepted: true,
    isIPv6Accepted: false,
    isBlocking: false,
    isInternal: false,
    // 防环：只排除**本应用自己**，其余应用照常走 VPN。
    // 注意语义方向 —— blocked = "不被代理"，所以自身的出站流量因此不回到 TUN，
    // tun2socks 才能把还原出的连接交给本地 SOCKS 而不形成回路。
    // 一旦这里漏掉，真机症状是"连上即断网"。
    blockedApplications: [APP_BUNDLE_NAME]
    // ⚠️ 不要同时设置 trustedApplications：SDK 明确两者互斥（d.ts:371 / :383）。
  };
  return config;
}

/**
 * 生成 hev-socks5-tunnel 的 YAML 配置。
 *
 * 只写必要的三段：
 *   tunnel.mtu  与 VpnConfig.mtu 共用同一个常量（同一块网卡，两个数字必须对上）
 *   socks5      tun2socks 把还原出的连接交给内核的本地入站
 *   misc        warn 级日志，避免隧道内部的调试噪声灌满 hilog
 *
 * @param socksPort 内核本地 SOCKS 入站端口。**必须由调用方传入**（来自
 *        want.parameters，即 UI 进程转交的 ConfigService.Generate 结果），
 *        不能在这个文件里写死：写死就会与内核真正监听的那个端口各说各话。
 *
 * ⚠️ tunnel 段里**不写** name / ipv4：网卡由 VpnConfig 创建，fd 由系统经
 * `hev_socks5_tunnel_main_from_str(cfg, len, tun_fd)` 交给我们，这里再声明接口名
 * 与地址只会制造两份互相冲突的配置。hev 是否接受省略这两个字段**未在真机验证**，
 * 属于 U3 的一部分。
 */
function buildTun2socksYaml(socksPort: number): string {
  const port: number = socksPort > 0 ? socksPort : CORE_SOCKS_PORT;
  return 'tunnel:\n' +
    '  mtu: ' + DEFAULT_MTU.toString() + '\n' +
    'socks5:\n' +
    '  address: 127.0.0.1\n' +
    '  port: ' + port.toString() + '\n' +
    '  udp: udp\n' +
    'misc:\n' +
    '  log-level: warn\n';
}

/** 用两次采样差值估算瞬时速率（字节/秒） */
function computeSpeed(current: number, previous: number): number {
  const delta: number = current - previous;
  if (delta <= 0) {
    return 0;
  }
  return Math.floor(delta * 1000 / TRAFFIC_INTERVAL_MS);
}

/**
 * 发布 VPN_TRAFFIC 公共事件。
 * 契约（app 侧 core/TrafficMonitor.ets 按同一组 key 解析）：
 *   parameters = { TOTAL_UP, TOTAL_DOWN, SPEED_UP, SPEED_DOWN }（字节 / 字节每秒）
 */
function publishTraffic(totalUp: number, totalDown: number, speedUp: number, speedDown: number): void {
  const parameters: Record<string, number> = {
    'TOTAL_UP': totalUp,
    'TOTAL_DOWN': totalDown,
    'SPEED_UP': speedUp,
    'SPEED_DOWN': speedDown
  };
  const options: commonEventManager.CommonEventPublishData = { parameters: parameters };
  commonEventManager.publish(VPN_TRAFFIC_EVENT, options, (error: BusinessError) => {
    if (error !== undefined && error !== null && error.code !== 0) {
      console.warn(`${TAG} publish traffic failed: ${error.code}`);
    }
  });
}
