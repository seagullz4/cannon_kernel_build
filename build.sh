#!/bin/bash
set -o pipefail

TOOLCHAIN="/cannon"
KERNEL="$TOOLCHAIN/kernel"
OUT_DIR="$TOOLCHAIN/out"
AK_DIR="$TOOLCHAIN/Anykernel3"
TARGET_IMAGE="$OUT_DIR/arch/arm64/boot/Image.gz"
PLAIN_ZIP="$TOOLCHAIN/Cannon-Stock-by-GinHalion.zip"
KSU_LKM_ZIP="$TOOLCHAIN/Cannon-KSU-LKM-by-GinHalion.zip"

export PATH="$TOOLCHAIN/clang/bin:$TOOLCHAIN/gcc64/bin:$TOOLCHAIN/gcc32/bin:$PATH"
export CCACHE_DIR="$TOOLCHAIN/.ccache"
GCC64="aarch64-linux-android-"
GCC32="arm-linux-androideabi-"
export USE_CCACHE=1
COMMON_ARGS="ARCH=arm64 CLANG_TRIPLE=aarch64-linux-gnu- CROSS_COMPILE=$GCC64"
BUILD_ARGS="CROSS_COMPILE_ARM32=$GCC32 LD=ld.lld KCFLAGS=-Wno-error LOCALVERSION=-GinHalion"

mkdir -p "$OUT_DIR" "$CCACHE_DIR"
ccache -z > /dev/null 2>&1 || true
ccache -M 50G > /dev/null 2>&1 || true

# ============================================
# 清理 SukiSU 残留
# ============================================
clean_sukisu() {
    cd "$KERNEL"
    rm -rf SukiSU-Ultra KernelSU
    [ -L drivers/kernelsu ] && rm drivers/kernelsu
    grep -q "kernelsu" drivers/Makefile 2>/dev/null && sed -i '/kernelsu/d' drivers/Makefile || true
    grep -q "kernelsu" drivers/Kconfig 2>/dev/null && sed -i '/kernelsu/d' drivers/Kconfig || true
}

# ============================================
# 编译内核
# ============================================
build_kernel() {
    local OUTPUT_ZIP=$1
    local LABEL=$2
    local SUKI_MODE=$3

    echo ""
    echo "=========================================="
    echo "  编译: $LABEL"
    echo "  输出: $OUTPUT_ZIP"
    echo "=========================================="

    cd "$KERNEL"
    if git rev-parse --git-dir > /dev/null 2>&1; then
        echo "[debug] git checkout ."
        git checkout .
    fi
    clean_sukisu

    if [ -n "$SUKI_MODE" ]; then
        echo "设置 KernelSU (v0.9.5)..."
        curl -LSs "https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/dev/kernel/setup.sh" | bash -s legacy
        echo "✅ KernelSU 设置完成"
    fi

    rm -rf "$OUT_DIR"
    mkdir -p "$OUT_DIR"

    echo "配置内核..."
    if ! make -C "$KERNEL" O="$OUT_DIR" $COMMON_ARGS CC="ccache clang" cannon_defconfig; then
        echo "❌ defconfig 失败"
        exit 1
    fi
    if [ -n "$SUKI_MODE" ] && grep -q "CONFIG_KSU" "$OUT_DIR/.config" 2>/dev/null; then
        "$KERNEL/scripts/config" --file "$OUT_DIR/.config" --enable KPROBES
        "$KERNEL/scripts/config" --file "$OUT_DIR/.config" --enable OVERLAY_FS
        "$KERNEL/scripts/config" --file "$OUT_DIR/.config" --enable KALLSYMS
        "$KERNEL/scripts/config" --file "$OUT_DIR/.config" --enable KALLSYMS_ALL
        "$KERNEL/scripts/config" --file "$OUT_DIR/.config" --enable KSU
        echo "✅ CONFIG_KSU=y + KPROBES + OVERLAY_FS + KALLSYMS_ALL 已确认"
    fi
    if ! make -C "$KERNEL" O="$OUT_DIR" $COMMON_ARGS CC="ccache clang" olddefconfig > /dev/null; then
        echo "❌ olddefconfig 失败"
        exit 1
    fi

    echo "开始编译..."
    START_TIME=$(date +%s)

    if make -C "$KERNEL" O="$OUT_DIR" $COMMON_ARGS CC="ccache clang" $BUILD_ARGS -j$(nproc) Image.gz 2>&1 | tee "/tmp/build_${LABEL}.log"; then
        END_TIME=$(date +%s)
        echo "✅ 编译成功 (耗时: $((END_TIME - START_TIME))s)"
        # LKM 模式下编译 KernelSU 模块
        if [ -n "$SUKI_MODE" ]; then
            echo "编译 KernelSU 模块..."
            make -C "$KERNEL" O="$OUT_DIR" $COMMON_ARGS CC="ccache clang" $BUILD_ARGS -j$(nproc) modules 2>&1 | tee -a "/tmp/build_${LABEL}.log" || echo "⚠️ 模块编译失败（不影响内核）"
        fi
    else
        echo "❌ 编译失败"
        echo "=== 编译日志中的错误 ==="
        grep -n -i "error" "/tmp/build_${LABEL}.log" | tail -n 30 || true
        echo "=== 日志末尾 20 行 ==="
        tail -n 20 "/tmp/build_${LABEL}.log" || true
        if [ -n "$SUKI_MODE" ]; then clean_sukisu; fi
        exit 1
    fi

    if [ ! -f "$TARGET_IMAGE" ]; then
        echo "❌ 内核镜像不存在"
        if [ -n "$SUKI_MODE" ]; then clean_sukisu; fi
        exit 1
    fi

    ls -lh "$TARGET_IMAGE"

    echo "打包中..."
    cd "$AK_DIR"
    rm -f Image.gz *.zip
    cp "$TARGET_IMAGE" "$AK_DIR/Image.gz"
    # 如果存在 KernelSU 模块则一并打包
    local KSU_KO="$OUT_DIR/drivers/kernelsu/kernelsu.ko"
    [ -f "$KSU_KO" ] && cp "$KSU_KO" "$AK_DIR/" && echo "✅ 已包含 kernelsu.ko"
    zip -r9 "$OUTPUT_ZIP" . -x ".git/*" "*.git*" "README.md" "LICENSE" "*.zip" > /dev/null

    echo "✅ 完成: $OUTPUT_ZIP"
    ls -lh "$OUTPUT_ZIP"

    rm -f "$AK_DIR/Image.gz"
    if [ -n "$SUKI_MODE" ]; then clean_sukisu; fi
}

# ============================================
# 主流程
# ============================================
echo "=========================================="
echo "  Cannon Kernel by GinHalion"
echo "=========================================="
echo "时间: $(date)  |  CPU: $(nproc)"

build_kernel "$PLAIN_ZIP"     "Stock"      "" || exit 1
build_kernel "$KSU_LKM_ZIP" "KernelSU LKM" "lkm" || exit 1

echo ""
echo "=========================================="
echo "  All builds completed!"
echo "=========================================="
echo "  Stock:      $PLAIN_ZIP"
echo "  KernelSU LKM: $KSU_LKM_ZIP"
echo "=========================================="
