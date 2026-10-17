# Redmi Note 9 5G / Cannon KernelSU-Next

使用 GitHub Actions 为 Redmi Note 9 5G（`cannon`）编译 Linux 4.14.336 内核，并通过设备专用 AnyKernel3 模板生成刷机 ZIP。模板同时保留上游的 `cannong` 设备别名检查。

默认构建 **KernelSU-Next legacy 内置版**：`CONFIG_KSU=y`、`CONFIG_KSU_MANUAL_HOOK=y`。它不是 GKI 通用镜像，也不是需要额外加载 `kernelsu.ko` 的 LKM 包。

## 使用 GitHub Actions

1. 打开仓库的 **Actions → Cannon KernelSU-Next → Run workflow**。
2. `ksu_source=latest`（默认）：每次构建自动获取官方 `legacy` 最新提交、`next` 安装脚本，以及 GitHub 最新正式 Release 中的标准签名管理器 APK。`pinned` 使用之前已验证的固定驱动与 v3.4.2 管理器，便于回退。
3. `build_stock=false`：只编译需要的 KernelSU-Next 版本，减少等待。设为 `true` 时先额外构建未集成 KSU 的版本。
4. `publish_release=true`：验证成功后创建 GitHub Release。设为 `false` 时仍可从该次运行的 Artifacts 下载产物。
5. 构建完成后，下载 `Cannon-KernelSU-Next-legacy-built-in-by-GinHalion.zip` 和该次 Release 配套的 `KernelSU-Next-Manager-<版本>.apk`。

工作流默认只由手动操作触发；推送代码不会自动开始耗时的内核构建。仓库需要允许工作流的 `GITHUB_TOKEN` 写入 Release，工作流已声明 `contents: write`。

## 版本及配置

设备内核、工具链和回退配置放在 [sources.env](sources.env)。默认自动更新范围仅为 KernelSU-Next 驱动、安装脚本和管理器；设备内核与工具链保持已验证配置：

| 组成 | 默认选择 |
| --- | --- |
| 内核 | `GinHalion/android_kernel_xiaomi_cannon`，`264a38bb945bbcc00fdeece291ea21c122ce9363` |
| defconfig | `arch/arm64/configs/cannon_defconfig` |
| KernelSU-Next 驱动 | 官方 `legacy` 分支最新提交；回退模式为 `d51ca52c6d370d8e9d62aabde10e41f17ff3ae94` |
| AnyKernel3 cannon | `e8ec21bd3fc36e4c638486567536bb1ce7de3b77` |
| 编译器 | Android Clang r450784d / 14.0.6，配 Android GCC 4.9 binutils |
| 管理器 | 官方最新正式 Release 的标准签名版；回退模式为 v3.4.2 / 33355 |

`latest` 是“每次触发时选择最新版”，不是在同一次构建中反复换版本。准备阶段把分支解析为实际 SHA、记录 APK URL 与官方资产 SHA-256，并生成 `resolved-sources.env/json`；本轮后续步骤只使用这份快照。上游在编译期间推送新提交，不会改变本轮源码。

驱动和管理器分别更新，最新版不一定彼此适配。解析阶段检查双方 UAPI 是否相同；驱动 Kbuild 准备完成后检查版本号是否达到管理器的最低要求。正式版中不存在唯一标准 APK、官方校验值缺失、接口格式改变或 UAPI 不同，都会明确失败，不会静默选用其他分支或旧版。`pinned` 同样保留兼容检查。

官方非 GKI 集成命令如下：

```bash
curl -LSs "https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/next/kernel/setup.sh" | bash -s legacy
```

`next` 指安装脚本位置，`legacy` 指驱动分支。项目默认解析本轮最新提交，再下载该提交中的安装脚本并传入本轮已解析的 legacy SHA；执行后再次核对实际检出的 SHA。GitHub 分支 API 会处理上游分支更名的重定向。

当前 legacy 动态 Kprobes Hook 的说明不建议在 5.10 以下使用，Syscall Table Hook 要求至少 4.17。因此这个 4.14 项目采用手动 Hook，不会强制开启不适配的动态 Hook。

[patches/cannon-ksu-manual-hooks.patch](patches/cannon-ksu-manual-hooks.patch) 对固定的内核源码增加：

| 文件 | 接入点 |
| --- | --- |
| `fs/exec.c` | 公共 execve/execveat 路径，覆盖 native/compat 启动；调用 ksud 和 sucompat |
| `fs/open.c` | faccessat，支持 su 路径兼容 |
| `fs/read_write.c` | vfs_read，接入当前 legacy 的 init.rc 读取代理 |
| `fs/stat.c` | newfstatat、newfstat/fstat64，包含 init.rc 扩展长度处理 |
| `kernel/reboot.c` | 管理器与驱动之间的 supercall 通信 |
| `drivers/input/input.c` | 音量减键事件，用于 KernelSU 安全模式 |

Hook 根据已经验证的 legacy 接口接入，避免直接套用旧文档。上游升级后仍可能改变接口；自动解析、编译、符号检查不能代替每个新版本的真机测试。

## 构建检查与故障排查

- 编译前执行 Bash 语法检查、ShellCheck、版本解析测试、UAPI/最低版本检查、源码提交校验和 `git apply --check`。
- `olddefconfig` 后核对 `CONFIG_KSU=y`、手动 Hook、SELinux、OverlayFS、Kallsyms 等实际配置，防止配置被依赖条件静默取消。
- 并行编译前先执行上游 Kbuild 的兼容补丁阶段，提前完成 `path_umount`、seccomp 和 SELinux 等回移，避免源码/共享头文件在部分对象编译完毕后才被修改。完整源码差异保存为 `ksu-effective-source.patch`。
- `Image.gz` 生成后检查 gzip 完整性，并在 `vmlinux` 中检查 KSU 初始化、管理器通信和各手动 Hook 的符号。
- 每次从固定提交导出干净的 AnyKernel3 模板，校验设备检查与安装入口；压缩后再检查 ZIP 完整性、内部镜像与编译镜像的 SHA-256 一致性。
- 使用分离的工具链缓存和 3 GiB ccache；编译失败后也尝试保存 ccache，避免下一次全部重编。
- 无论成功或失败，都上传 `Cannon-diagnostics-<run_id>-<attempt>`，包含完整准备/编译日志、最终配置和可用的符号检查结果。

之前日志中的 `make: *** ... Error 2` 是汇总错误。实际失败原因是 `KernelSU-Next: No hooks were defined`：原脚本未提供适配的手动 Hook。日志检索应优先查看 `No hooks`、`error:`、`fatal:` 和 `undefined reference` 等信息。

完整链接验证还暴露了 `undefined symbol: path_umount`：上游驱动 Kbuild 的自动回移晚于 `fs/namespace.o` 编译。提前执行兼容阶段后，再启动内核编译，消除这一并发时序问题。

## 产物

Release / 成功运行的 Artifact 包含内核 ZIP、配套管理器 APK、`SHA256SUMS`、`sources.env`、`resolved-sources.env/json`、手动 Hook 补丁和构建信息。实际驱动提交、管理器版本及校验值以该次构建的解析快照为准。启用 `build_stock` 后，额外提供 `Cannon-Stock-by-GinHalion.zip`。

```bash
# 在产物目录中核验下载完整性
sha256sum --check SHA256SUMS
```

`Stock` 表示这里选定的开源内核未注入 KSU 的构建，并不是你手机当前 ROM 的原始 boot 备份。

## 本地构建

需要 x86_64 Linux。Ubuntu 22.04 所需软件包见工作流的依赖安装步骤。Windows 用户可使用合适的 Linux 环境；Windows 原生不能直接运行此内核工具链。

```bash
bash scripts/prepare.sh
# 可选，必须在 KSU 构建之前执行：
bash build.sh stock
bash build.sh ksu
```

需要回退模式时，在新的工作目录执行 `KSU_SOURCE_MODE=pinned bash scripts/prepare.sh`，后续 `bash build.sh ksu` 自动读取已保存的版本快照。GitHub API 访问受限时可为准备步骤提供具有公开仓库读取权限的 `GH_TOKEN`，Actions 已自动提供。

默认工作目录为 `work/`，产物位于 `dist/`；可通过 `WORK_DIR`、`DIST_DIR`、`CCACHE_DIR`、`JOBS` 覆盖。源码或输出目录已存在时脚本会停止，重新构建请选择新的工作/产物目录，避免覆盖已有构建。

## 刷入边界

仅供 `cannon/cannong` 对应设备；不是其他 Redmi Note 9 机型的通用内核。相同的 `4.14.x` 版本号不能证明所有第三方 ROM 的驱动 ABI、设备树和启动格式一致。AnyKernel3 基于现有 boot 镜像替换内核，保留 ROM 的原有 ramdisk，但仍需设备实测确认启动、触摸、网络、相机及 KernelSU 功能。

刷入前请保存**当前 ROM 自己的原始 boot 镜像**和可恢复手段；编译成功只证明构建与打包检查通过，不等于已经完成真机启动验证。

官方参考：[KernelSU-Next](https://github.com/KernelSU-Next/KernelSU-Next)、[非 GKI 集成指南](https://github.com/KernelSU-Next/webpage/blob/main/docs/pages/how-to-integrate-for-non-gki.md)。
