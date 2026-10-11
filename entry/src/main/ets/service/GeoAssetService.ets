/**
 * GeoAssetService.ets
 * 分流资源（geoip.dat / geosite.dat）的**落点、探测与获取**。
 *
 * 为什么需要它：`routing=rule` 的「绕过大陆」依赖 `geoip:cn` / `geosite:cn` 这类规则，
 * 而内核在装载这些规则时会去 `assetLocation` 打开真实的 `.dat` 文件 —— 缺文件是
 * **硬失败**（整份配置被拒，不是忽略那一条）。所以：
 *
 *   1. 落点只有一个：`<filesDir>/assets`（由 ConfigStore.assetsDirPath 定义），
 *      它同时被传给 `ConfigService.Generate` 的 assetDir 与 `CoreService.Start` 的
 *      assetLocation，三处必须是同一路径；
 *   2. 没有资源时**不能**生成 geo 规则（Go 侧 hasGeoAssets 会探测，见 service/config）；
 *   3. 获取方式与 v2rayN 一致：从 `Global.GeoUrl` 指向的发布地址下载
 *      （https://github.com/Loyalsoldier/v2ray-rules-dat），而不是把 30 MB 资源
 *      塞进 HAP。
 *
 * 下载写入用的是「先写 .part 再改名」：`hasGeoAssets` 只判断文件是否存在，
 * 半个文件同样会被当成"已就位"，随后内核报出的错误会完全指不到问题所在。
 */
import { http } from '@kit.NetworkKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { ConfigStore } from '../core/ConfigStore';
import { Logger } from '../utils/Logger';

const TAG: string = 'GeoAssetService';

/** 资源文件名。必须与 Go 侧 `hasGeoAssets` 探测的文件名一致 */
export const GEOIP_FILE_NAME: string = 'geoip.dat';
export const GEOSITE_FILE_NAME: string = 'geosite.dat';

/**
 * 下载地址，与 v2rayN 的 `Global.GeoUrl` 逐字一致：
 *   https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/{0}.dat
 * 其中 {0} 是去掉扩展名的资源名（geoip / geosite）。
 */
export const GEO_URL_TEMPLATE: string =
  'https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/{0}.dat';

/** 下载中的临时后缀 */
const PART_SUFFIX: string = '.part';

/** 连接超时（毫秒） */
const CONNECT_TIMEOUT_MS: number = 20000;
/** 读取超时（毫秒）。geo 资源常见十几 MB，给足时间 */
const READ_TIMEOUT_MS: number = 300000;

/** 单个资源的探测结果 */
export interface GeoFileInfo {
  name: string;
  /** 绝对路径；assetDir 为空时是空串 */
  path: string;
  /** 字节数；0 表示不存在 */
  bytes: number;
}

/** 资源整体状态（与 Go 侧 hasGeoAssets 的判定保持一致：两个都在才算就位） */
export interface GeoAssetStatus {
  assetDir: string;
  geoip: GeoFileInfo;
  geosite: GeoFileInfo;
  present: boolean;
}

/** 下载进度回调 */
export type GeoProgressCallback = (name: string, receiveSize: number, totalSize: number) => void;

/** 下载结果 */
export interface GeoDownloadResult {
  ok: boolean;
  geoipBytes: number;
  geositeBytes: number;
  /** 失败原因；ok 为 true 时是空串 */
  error: string;
}

export class GeoAssetService {
  /** 某个资源文件的下载地址 */
  static urlFor(fileName: string): string {
    const stem: string = fileName.endsWith('.dat') ? fileName.substring(0, fileName.length - 4) : fileName;
    return GEO_URL_TEMPLATE.replace('{0}', stem);
  }

  /** 字节数转成人看的单位（UI 展示用） */
  static formatBytes(bytes: number): string {
    if (bytes <= 0) {
      return '0 B';
    }
    if (bytes < 1024) {
      return bytes.toString() + ' B';
    }
    const kb: number = bytes / 1024;
    if (kb < 1024) {
      return kb.toFixed(1) + ' KB';
    }
    return (kb / 1024).toFixed(1) + ' MB';
  }

  /** 探测单个文件 */
  static fileInfo(assetDir: string, name: string): GeoFileInfo {
    const info: GeoFileInfo = { name: name, path: '', bytes: 0 };
    if (assetDir.length === 0) {
      return info;
    }
    info.path = assetDir + '/' + name;
    try {
      const stat: fs.Stat = fs.statSync(info.path);
      info.bytes = stat.size;
    } catch (error) {
      // 文件不存在是**正常状态**，不是错误：分流资源本来就是可选的
      info.bytes = 0;
    }
    return info;
  }

  /** 探测整体状态（入参是 filesDir） */
  static status(filesDir: string): GeoAssetStatus {
    return GeoAssetService.statusOf(GeoAssetService.assetDirOf(filesDir));
  }

  /**
   * 探测整体状态（入参**已经是 assetDir**）。
   *
   * 单独开一个入口是给 MockBridge 用的：原生契约里传到的是 assetDir，
   * Mock 没有 filesDir，不该为了探测再去反推目录。
   */
  static statusOf(assetDir: string): GeoAssetStatus {
    const geoip: GeoFileInfo = GeoAssetService.fileInfo(assetDir, GEOIP_FILE_NAME);
    const geosite: GeoFileInfo = GeoAssetService.fileInfo(assetDir, GEOSITE_FILE_NAME);
    const status: GeoAssetStatus = {
      assetDir: assetDir,
      geoip: geoip,
      geosite: geosite,
      present: geoip.bytes > 0 && geosite.bytes > 0
    };
    return status;
  }

  /**
   * 下载（或更新）两个资源文件。
   *
   * 注意：本版 SDK 只提供 `dataReceiveProgress` 事件，没有增量数据回调，
   * 因此整份文件会先落在内存里再写盘（十几 MB，一次性操作可接受）。
   */
  static async download(filesDir: string, onProgress?: GeoProgressCallback): Promise<GeoDownloadResult> {
    const result: GeoDownloadResult = { ok: false, geoipBytes: 0, geositeBytes: 0, error: '' };
    const assetDir: string = GeoAssetService.ensureAssetDir(filesDir);
    if (assetDir.length === 0) {
      result.error = 'no-files-dir';
      Logger.error(TAG, 'download skipped: filesDir is empty');
      return result;
    }

    const names: string[] = [GEOIP_FILE_NAME, GEOSITE_FILE_NAME];
    for (let i = 0; i < names.length; i++) {
      const name: string = names[i];
      try {
        const bytes: number = await GeoAssetService.downloadOne(assetDir, name, onProgress);
        if (name === GEOIP_FILE_NAME) {
          result.geoipBytes = bytes;
        } else {
          result.geositeBytes = bytes;
        }
      } catch (error) {
        result.error = name + ': ' + Logger.describe(error as Object);
        Logger.error(TAG, 'download ' + name + ' failed: ' + result.error);
        return result;
      }
    }

    result.ok = result.geoipBytes > 0 && result.geositeBytes > 0;
    if (result.ok) {
      Logger.info(TAG, 'geo assets ready: geoip=' + result.geoipBytes.toString() +
        ' geosite=' + result.geositeBytes.toString());
    }
    return result;
  }

  /** 创建并返回 <filesDir>/assets；拿不到目录时返回空串 */
  static ensureAssetDir(filesDir: string): string {
    const assetDir: string = GeoAssetService.assetDirOf(filesDir);
    if (assetDir.length === 0) {
      return '';
    }
    try {
      fs.mkdirSync(assetDir, true);
    } catch (error) {
      // 目录已存在时 mkdirSync 会抛错，这不是失败；真创建不了下面的 openSync 会报明确错误
      Logger.debug(TAG, 'mkdir ' + assetDir + ' skipped: ' + Logger.describe(error as Object));
    }
    return assetDir;
  }

  /**
   * 删除已下载的资源（回到"无资源"状态）。
   * 存在的意义：资源缺失时 rule 模式会降级，用户需要能主动退回这个已知状态。
   */
  static remove(filesDir: string): void {
    const assetDir: string = GeoAssetService.assetDirOf(filesDir);
    if (assetDir.length === 0) {
      return;
    }
    const names: string[] = [GEOIP_FILE_NAME, GEOSITE_FILE_NAME];
    for (let i = 0; i < names.length; i++) {
      try {
        fs.unlinkSync(assetDir + '/' + names[i]);
      } catch (error) {
        // 本来就不存在时也算成功
        Logger.debug(TAG, 'unlink ' + names[i] + ' skipped: ' + Logger.describe(error as Object));
      }
    }
  }

  /**
   * 资源目录的唯一来源。
   *
   * 刻意复用它而不是自己拼字符串：这个路径同时被传给
   * `ConfigService.Generate` 的 assetDir 与 `CoreService.Start` 的 assetLocation，
   * 两处拼接不一致会表现为"下载了但内核说找不到文件"。
   */
  private static assetDirOf(filesDir: string): string {
    return ConfigStore.assetsDirPath(filesDir);
  }

  /** 下载单个文件：写 <name>.part -> 校验 -> 改名 */
  private static async downloadOne(
    assetDir: string,
    name: string,
    onProgress?: GeoProgressCallback
  ): Promise<number> {
    const target: string = assetDir + '/' + name;
    const part: string = target + PART_SUFFIX;
    const request: http.HttpRequest = http.createHttp();
    try {
      if (onProgress !== undefined) {
        const callback: GeoProgressCallback = onProgress;
        request.on('dataReceiveProgress', (info: http.DataReceiveProgressInfo) => {
          callback(name, info.receiveSize, info.totalSize);
        });
      }

      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: CONNECT_TIMEOUT_MS,
        readTimeout: READ_TIMEOUT_MS,
        usingCache: false
      };
      const response: http.HttpResponse =
        await request.request(GeoAssetService.urlFor(name), options);
      if (response.responseCode !== http.ResponseCode.OK) {
        throw new Error('http status ' + response.responseCode.toString());
      }

      const buffer: ArrayBuffer = response.result as ArrayBuffer;
      if (buffer.byteLength === 0) {
        throw new Error('empty body');
      }

      const file: fs.File = fs.openSync(part, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, buffer);
      } finally {
        fs.closeSync(file);
      }
      fs.renameSync(part, target);
      return buffer.byteLength;
    } catch (error) {
      // 失败时不留半截文件：否则 hasGeoAssets 会把它当成"已就位"
      try {
        fs.unlinkSync(part);
      } catch (cleanupError) {
        Logger.debug(TAG, 'cleanup ' + part + ' skipped');
      }
      throw error as Error;
    } finally {
      // SDK 文档要求：不再使用时 destroy()，否则内存泄漏
      request.destroy();
    }
  }
}
