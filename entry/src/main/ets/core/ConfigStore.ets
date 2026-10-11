/**
 * ConfigStore.ets
 * 内核运行文件的落盘位置与写入。
 *
 * 职责边界：**配置的生成本身在 Go 侧**（`ConfigService.Generate`，它才能链接
 * Xray 自己的 loader 做自检）；Go 侧不知道应用的沙箱布局，所以由这里负责
 * 「生成结果 -> 文件路径」这一步，再把路径交给 `CoreService.Start`。
 *
 * 目录布局（都在 UIAbility 的 filesDir 下）：
 *   <filesDir>/core/config.json   内核配置
 *   <filesDir>/assets/            geoip.dat / geosite.dat（分流资源，见 docs/design/core.md）
 *
 * 注意 `coreDirPath` / `assetsDirPath` 是**纯拼接**，不创建目录：
 * MOCK 模式下不应该因为"取个路径"就在沙箱里留下文件。只有真正写配置时
 * （`writeConfig`）才创建 `<filesDir>/core`。
 */
import { fileIo as fs } from '@kit.CoreFileKit';
import { Logger } from '../utils/Logger';

const TAG: string = 'ConfigStore';

/** 内核运行目录名 */
const CORE_DIR_NAME: string = 'core';
/** 配置文件名 */
const CONFIG_FILE_NAME: string = 'config.json';
/** 分流资源目录名 */
const ASSETS_DIR_NAME: string = 'assets';

/** 内核运行所需的两个路径（传给 ConfigService.Generate 与 CoreService.Start） */
export interface CorePaths {
  /** 沙箱 filesDir；空串表示调用方拿不到 context */
  filesDir: string;
  /** geoip.dat / geosite.dat 所在目录 */
  assetDir: string;
}

export class ConfigStore {
  /** <filesDir>/core（纯拼接，不创建） */
  static coreDirPath(filesDir: string): string {
    return filesDir + '/' + CORE_DIR_NAME;
  }

  /** <filesDir>/assets（纯拼接，不创建） */
  static assetsDirPath(filesDir: string): string {
    if (filesDir.length === 0) {
      return '';
    }
    return filesDir + '/' + ASSETS_DIR_NAME;
  }

  /** 由 filesDir 构造传给内核的路径集合 */
  static pathsOf(filesDir: string): CorePaths {
    const paths: CorePaths = {
      filesDir: filesDir,
      assetDir: ConfigStore.assetsDirPath(filesDir)
    };
    return paths;
  }

  /**
   * 把内核配置写入 <filesDir>/core/config.json。
   *
   * @returns 配置文件的绝对路径；失败或入参不完整时返回空串（调用方负责记录与降级）
   */
  static writeConfig(filesDir: string, configJson: string): string {
    if (filesDir.length === 0 || configJson.length === 0) {
      return '';
    }
    const dir: string = ConfigStore.coreDirPath(filesDir);
    try {
      fs.mkdirSync(dir, true);
    } catch (error) {
      // 目录已存在时 mkdirSync 会抛错，这不是失败；真创建不了下面的 openSync 会报明确错误
      Logger.debug(TAG, 'mkdir ' + dir + ' skipped: ' + Logger.describe(error as Object));
    }

    const path: string = dir + '/' + CONFIG_FILE_NAME;
    try {
      const file: fs.File = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, configJson);
      } finally {
        fs.closeSync(file);
      }
      Logger.info(TAG, 'config written: ' + path + ' (' + configJson.length.toString() + ' bytes)');
      return path;
    } catch (error) {
      Logger.error(TAG, 'writeConfig failed: ' + Logger.describe(error as Object));
      return '';
    }
  }

  /** 读回配置文本（联调 / 排错用；读不到返回空串） */
  static readConfig(filesDir: string): string {
    if (filesDir.length === 0) {
      return '';
    }
    const path: string = ConfigStore.coreDirPath(filesDir) + '/' + CONFIG_FILE_NAME;
    try {
      return fs.readTextSync(path);
    } catch (error) {
      Logger.warn(TAG, 'readConfig failed: ' + Logger.describe(error as Object));
      return '';
    }
  }
}
