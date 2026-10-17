# Redmi Note 9 5G / Cannon KernelSU-Next

使用 GitHub Actions 为 Redmi Note 9 5G（`cannon`）编译 Linux 4.14.336 内核，并通过设备专用 AnyKernel3 模板生成刷机 ZIP。模板同时保留上游的 `cannong` 设备别名检查。

默认构建 **KernelSU-Next legacy 内置版**：`CONFIG_KSU=y`、`CONFIG_KSU_MANUAL_HOOK=y`。它不是 GKI 通用镜像，也不是需要额外加载 `kernelsu.ko` 的 LKM 包。

## 使用 GitHub Actions

1. 打开仓库的 **Actions → Cannon KernelSU-Next → Run workflow**。
2. `build_stock=false`：只编译需要的 KernelSU-Next 版本，减少等待。设为 `true` 时先额外构建未集成 KSU 的版本。
3. `publish_release=true`：验证成功后创建 GitHub Release。设为 `false` 时仍可从该次运行的 Artifacts 下载产物。
4. 构建完成后，下载 `Cannon-KernelSU-Next-legacy-built-in-by-GinHalion.zip` 和配套 `KernelSU-Next-Manager-v3.4.2.apk`。

工作流默认只由手动操作触发；推送代码不会自动开始耗时的内核构建。仓库需要允许工作流的 `GITHUB_TOKEN` 写入 Release，工作流已声明 `contents: write`。

## 版本及配置

所有源码提交、工具链下载位置和管理器 APK 的 SHA-256 都放在 [sources.env](sources.env)。本次检查采用：

| 组成 | 固定版本 |
| --- | --- |
| 内核 | `GinHalion/android_kernel_xiaomi_cannon`，`264a38bb945bbcc00fdeece291ea21c122ce9363` |
| defconfig | `arch/arm64/configs/cannon_defconfig` |
| KernelSU-Next legacy | `d51ca52c6d370d8e9d62aabde10e41f17ff3ae94` |
| AnyKernel3 cannon | `e8ec21bd3fc36e4c638486567536bb1ce7de3b77` |
| 编译器 | Android Clang r450784d / 14.0.6，配 Android GCC 4.9 binutils |
| 管理器 | 官方 KernelSU-Next v3.4.2 / 33355，标准签名版 |

官方非 GKI 集成命令如下：

```bash
curl -LSs "https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/next/kernel/setup.sh" | bash -s legacy
```

`next` 指安装脚本所在分支，`legacy` 指安装脚本选择的驱动版本。为避免上游分支变化导致不可复现，项目下载已检查提交中的同一安装脚本，并传入固定的 legacy 提交；执行后再次核对实际检出的 SHA。

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

Hook 根据固定 legacy 的真实函数签名接入，避免直接套用旧文档中已经发生变化的接口。更新内核或 KernelSU 提交时，必须重新检查补丁能否应用、接口是否兼容，以及设备能否启动。

## 构建检查与故障排查

- 编译前执行 Bash 语法检查、ShellCheck、源码提交校验和 `git apply --check`。
- `olddefconfig` 后核对 `CONFIG_KSU=y`、手动 Hook、SELinux、OverlayFS、Kallsyms 等实际配置，防止配置被依赖条件静默取消。
- 并行编译前先执行上游 Kbuild 的兼容补丁阶段，提前完成 `path_umount`、seccomp 和 SELinux 等回移，避免源码/共享头文件在部分对象编译完毕后才被修改。完整源码差异保存为 `ksu-effective-source.patch`。
- `Image.gz` 生成后检查 gzip 完整性，并在 `vmlinux` 中检查 KSU 初始化、管理器通信和各手动 Hook 的符号。
- 每次从固定提交导出干净的 AnyKernel3 模板，校验设备检查与安装入口；压缩后再检查 ZIP 完整性、内部镜像与编译镜像的 SHA-256 一致性。
- 使用分离的工具链缓存和 3 GiB ccache；编译失败后也尝试保存 ccache，避免下一次全部重编。
- 无论成功或失败，都上传 `Cannon-diagnostics-<run_id>-<attempt>`，包含完整准备/编译日志、最终配置和可用的符号检查结果。

之前日志中的 `make: *** ... Error 2` 是汇总错误。实际失败原因是 `KernelSU-Next: No hooks were defined`：原脚本未提供适配的手动 Hook。日志检索应优先查看 `No hooks`、`error:`、`fatal:` 和 `undefined reference` 等信息。

完整链接验证还暴露了 `undefined symbol: path_umount`：上游驱动 Kbuild 的自动回移晚于 `fs/namespace.o` 编译。提前执行兼容阶段后，再启动内核编译，消除这一并发时序问题。

## 产物

Release / 成功运行的 Artifact 包含内核 ZIP、配套管理器 APK、`SHA256SUMS`、`sources.env`、手动 Hook 补丁和构建信息。启用 `build_stock` 后，额外提供 `Cannon-Stock-by-GinHalion.zip`。

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

默认工作目录为 `work/`，产物位于 `dist/`；可通过 `WORK_DIR`、`DIST_DIR`、`CCACHE_DIR`、`JOBS` 覆盖。源码或输出目录已存在时脚本会停止，重新构建请选择新的工作/产物目录，避免覆盖已有构建。

## 刷入边界

仅供 `cannon/cannong` 对应设备；不是其他 Redmi Note 9 机型的通用内核。相同的 `4.14.x` 版本号不能证明所有第三方 ROM 的驱动 ABI、设备树和启动格式一致。AnyKernel3 基于现有 boot 镜像替换内核，保留 ROM 的原有 ramdisk，但仍需设备实测确认启动、触摸、网络、相机及 KernelSU 功能。

刷入前请保存**当前 ROM 自己的原始 boot 镜像**和可恢复手段；编译成功只证明构建与打包检查通过，不等于已经完成真机启动验证。

官方参考：[KernelSU-Next](https://github.com/KernelSU-Next/KernelSU-Next)、[非 GKI 集成指南](https://github.com/KernelSU-Next/webpage/blob/main/docs/pages/how-to-integrate-for-non-gki.md)。
