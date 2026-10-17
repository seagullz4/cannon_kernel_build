#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/scripts/common.sh"

VARIANT=${1:-ksu}
[[ $VARIANT == ksu || $VARIANT == stock ]] || die 'Usage: bash build.sh [ksu|stock]'
OUT_DIR="$WORK_DIR/out-$VARIANT"
export PATH="$TOOLCHAIN_DIR/clang/bin:$TOOLCHAIN_DIR/gcc64/bin:$TOOLCHAIN_DIR/gcc32/bin:$PATH"
export CCACHE_DIR="${CCACHE_DIR:-$WORK_DIR/.ccache}"
export CCACHE_BASEDIR="$KERNEL_DIR"
export KBUILD_BUILD_USER=GinHalion KBUILD_BUILD_HOST=github-actions
export KBUILD_BUILD_TIMESTAMP
KBUILD_BUILD_TIMESTAMP=$(git -C "$KERNEL_DIR" show -s --format=%cD HEAD)

assert_commit "$KERNEL_DIR" "$KERNEL_COMMIT"
assert_commit "$WORK_DIR/AnyKernel3" "$ANYKERNEL_COMMIT"
[[ ! -e $OUT_DIR/.config ]] || die 'Use a fresh output directory for each variant'
mkdir -p "$OUT_DIR"

make_args=(
    -C "$KERNEL_DIR" "O=$OUT_DIR" ARCH=arm64
    CLANG_TRIPLE=aarch64-linux-gnu- CROSS_COMPILE=aarch64-linux-android-
    CROSS_COMPILE_ARM32=arm-linux-androideabi- 'CC=ccache clang' HOSTCC=gcc
    LD=ld.lld KCFLAGS=-Wno-error LOCALVERSION=-GinHalion
)

if [[ $VARIANT == ksu ]]; then
    assert_commit "$KERNEL_DIR/KernelSU-Next" "$KSU_COMMIT"
    # Equivalent to the official next installer with legacy selected, pinned to
    # the reviewed legacy commit. Verify checkout because setup.sh can fall back.
    (cd "$KERNEL_DIR" && bash "$WORK_DIR/ksu-setup.sh" "$KSU_COMMIT") 2>&1 | tee "$LOG_DIR/ksu-setup.log"
    assert_commit "$KERNEL_DIR/KernelSU-Next" "$KSU_COMMIT"
    [[ -L $KERNEL_DIR/drivers/kernelsu ]] || die 'KernelSU driver link was not created'
    git -C "$KERNEL_DIR" apply --check "$PROJECT_DIR/patches/cannon-ksu-manual-hooks.patch"
    git -C "$KERNEL_DIR" apply "$PROJECT_DIR/patches/cannon-ksu-manual-hooks.patch"
else
    [[ ! -e $KERNEL_DIR/drivers/kernelsu ]] || die 'Build stock before integrating KernelSU'
fi

make "${make_args[@]}" "$KERNEL_DEFCONFIG" 2>&1 | tee "$LOG_DIR/$VARIANT-config.log"
if [[ $VARIANT == ksu ]]; then
    "$KERNEL_DIR/scripts/config" --file "$OUT_DIR/.config" \
        --enable KSU --enable KSU_MANUAL_HOOK \
        --disable KSU_KPROBES_HOOK --disable KSU_SYSCALL_TABLE_HOOK \
        --disable KSU_DEBUG --enable OVERLAY_FS --enable KALLSYMS \
        --enable KALLSYMS_ALL --enable SECURITY --enable SECURITY_SELINUX
fi
make "${make_args[@]}" olddefconfig 2>&1 | tee -a "$LOG_DIR/$VARIANT-config.log"
cp "$OUT_DIR/.config" "$LOG_DIR/$VARIANT.config"
if [[ $VARIANT == ksu ]]; then
    for config in KSU KSU_MANUAL_HOOK OVERLAY_FS KALLSYMS KALLSYMS_ALL SECURITY SECURITY_SELINUX; do
        grep -qx "CONFIG_$config=y" "$OUT_DIR/.config" || die "CONFIG_$config=y did not survive olddefconfig"
    done
    for config in KSU_KPROBES_HOOK KSU_SYSCALL_TABLE_HOOK KSU_DEBUG; do
        if grep -q "^CONFIG_$config=" "$OUT_DIR/.config"; then
            die "Unexpected CONFIG_$config in manual built-in configuration"
        fi
    done
fi

JOBS=${JOBS:-$(nproc)}
[[ $JOBS =~ ^[1-9][0-9]*$ ]] || die 'JOBS must be a positive integer'
if ! make "${make_args[@]}" -j"$JOBS" Image.gz 2>&1 | tee "$LOG_DIR/$VARIANT-build.log"; then
    grep -nEi 'error:|fatal:|undefined reference|No hooks|\*\*\*' "$LOG_DIR/$VARIANT-build.log" | tail -60 || true
    die "$VARIANT build failed; full log and final .config are preserved"
fi
IMAGE="$OUT_DIR/arch/arm64/boot/Image.gz"
[[ -s $IMAGE ]] || die 'Image.gz is missing or empty'
gzip -t "$IMAGE"
if [[ $VARIANT == ksu ]]; then
    aarch64-linux-android-nm "$OUT_DIR/vmlinux" > "$LOG_DIR/ksu-symbols.txt"
    for symbol in kernelsu_init ksu_handle_sys_reboot ksu_handle_execveat_ksud \
        ksu_handle_execveat_sucompat ksu_handle_vfs_read ksu_handle_newfstat_ret \
        ksu_handle_stat ksu_handle_faccessat ksu_handle_input_handle_event; do
        grep -qE " [Tt] $symbol$" "$LOG_DIR/ksu-symbols.txt" || die "Missing built-in KSU symbol: $symbol"
    done
fi

STAGE=$(mktemp -d "$WORK_DIR/package-$VARIANT.XXXXXX")
trap 'rm -rf -- "$STAGE"' EXIT
# Export only tracked template files, never cached images, modules, or .git.
git -C "$WORK_DIR/AnyKernel3" archive HEAD | tar -x -C "$STAGE"
cp "$IMAGE" "$STAGE/Image.gz"
[[ -f $STAGE/META-INF/com/google/android/update-binary && -f $STAGE/tools/ak3-core.sh ]] || die 'Incomplete AnyKernel3 template'
grep -qx 'device.name1=cannon' "$STAGE/anykernel.sh" || die 'Wrong AnyKernel3 device configuration'
grep -qx 'device.name2=cannong' "$STAGE/anykernel.sh" || die 'Wrong AnyKernel3 device alias'
grep -qx 'do.devicecheck=1' "$STAGE/anykernel.sh" || die 'AnyKernel3 device check must be enabled'
if [[ $VARIANT == ksu ]]; then
    NAME=Cannon-KernelSU-Next-legacy-built-in-by-GinHalion
else
    NAME=Cannon-Stock-by-GinHalion
fi
sed -i "s/^kernel.string=.*/kernel.string=$NAME/" "$STAGE/anykernel.sh"
{
    printf 'device=cannon,cannong\nvariant=%s\n' "$VARIANT"
    printf 'integration=%s\n' "$([[ $VARIANT == ksu ]] && echo built-in-manual || echo stock)"
    printf 'kernel=%s\nanykernel=%s\n' "$KERNEL_COMMIT" "$ANYKERNEL_COMMIT"
    if [[ $VARIANT == ksu ]]; then printf 'kernelsu_next=%s\n' "$KSU_COMMIT"; fi
    printf 'build_repository_commit=%s\n' "$(git -C "$PROJECT_DIR" rev-parse HEAD)"
    printf 'clang=%s\n' "$(clang --version | sed -n '1p')"
    printf 'image_sha256=%s\n' "$(sha256sum "$IMAGE" | cut -d ' ' -f 1)"
} > "$STAGE/build-info.txt"
cp "$STAGE/build-info.txt" "$DIST_DIR/$VARIANT-build-info.txt"
[[ ! -e $DIST_DIR/$NAME.zip ]] || die 'Refusing to update an existing output ZIP'
(cd "$STAGE" && zip -r9 "$DIST_DIR/$NAME.zip" . -x '.git/*' 'README.md' 'LICENSE' '*.zip') > "$LOG_DIR/$VARIANT-package.log"
unzip -tq "$DIST_DIR/$NAME.zip"
unzip -Z1 "$DIST_DIR/$NAME.zip" > "$LOG_DIR/$VARIANT-package-contents.txt"
grep -qx Image.gz "$LOG_DIR/$VARIANT-package-contents.txt" || die 'Packaged kernel image is missing'
[[ $(unzip -p "$DIST_DIR/$NAME.zip" Image.gz | sha256sum | cut -d ' ' -f 1) == "$(sha256sum "$IMAGE" | cut -d ' ' -f 1)" ]] || die 'Packaged image checksum mismatch'
ccache --show-stats
ls -lh "$DIST_DIR/$NAME.zip"
