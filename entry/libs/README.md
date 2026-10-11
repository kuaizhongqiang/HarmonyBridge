# entry/libs —— 原生内核产物目录

```
entry/libs/
└── arm64-v8a/
    ├── .gitkeep        ← 唯一入库的文件，用来固定目录结构
    └── libcore.so      ← 构建产物，不入库
```

## `libcore.so` 是什么

它是 `entry/src/main/golang` 用 Go 的 `-buildmode=c-shared` 交叉编译到
`aarch64-linux-ohos` 得到的 C 共享库，内嵌完整的 Xray-core。它通过两个 C ABI
符号（`GoInvoke` / `GoFreeCString`）被 `libbridge.so` 用 `dlopen` 加载。

hvigor 会把本目录下 `arm64-v8a/` 的内容一并打包进 HAP，安装后位于应用的
native 库目录，因此 `dlopen("libcore.so")` 可以直接按文件名找到它。

## 为什么不入库

* 单个 ABI 约 **32 MB**（`-s -w` 之后）。每次构建都提交，仓库会在几周内失控。
* 它内嵌 GPL/MPL 授权的第三方代码，把二进制提交进来会让许可证边界变得含糊。
* 二进制无法 review，且会与源码静默不同步——排查线上问题时会非常痛苦。

根目录 `.gitignore` 已经排除了它，并显式保留了 `.gitkeep`：

```gitignore
/entry/libs/**/*.so
/entry/libs/**/*.so.*
!/entry/libs/**/.gitkeep
```

## 怎么产出

在仓库根目录执行对应平台的脚本：

```bash
# Linux / macOS / WSL / MSYS
scripts/build-core.sh

# Windows (PowerShell)
powershell -ExecutionPolicy Bypass -File scripts\build-core.ps1
```

两个脚本都会：

1. 定位 `OHOS_NDK_HOME`（可用环境变量或第一个参数覆盖），校验
   `native/llvm/bin/clang`、`native/llvm/bin/llvm-config` 是否存在，
   缺任何一个就**立刻报错退出**，不会留下半成品。
2. `cd entry/src/main/golang`，按已验证的配方设置交叉编译环境变量。
3. 执行 `go build -buildmode=c-shared`，删除自动生成的 `libcore.h`。
4. 把 `libcore.so` 复制到 `entry/libs/arm64-v8a/`。

脚本还会打印产物的架构信息，便于确认它真的是 aarch64 而不是不小心编成了宿主架构。

## 验证产物架构

```bash
# Linux
file entry/libs/arm64-v8a/libcore.so
readelf -h entry/libs/arm64-v8a/libcore.so | grep Machine   # 期望 AArch64

# Windows（用 NDK 自带的 llvm-readelf）
& "$env:OHOS_NDK_HOME\native\llvm\bin\llvm-readelf.exe" -h entry\libs\arm64-v8a\libcore.so
```

## 当前状态

见 `docs/design/core.md` 的“风险与未决问题”。简言之：宿主侧的 Go 代码已通过
`go build` / `go vet`，**OHOS 交叉编译尚未成功**，Windows 宿主 + Windows NDK
clang + `GOOS=android` 的组合被 `-D__MUSL__` 与 cgo 的编译器探测卡住。
因此本目录目前只有 `.gitkeep`。
