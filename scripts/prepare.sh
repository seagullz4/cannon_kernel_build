#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || die 'Use an x86_64 Linux build host'
[[ ! -e $WORK_DIR/resolved-sources.env ]] || die 'Use a fresh WORK_DIR to resolve upstream versions'
python3 "$PROJECT_DIR/scripts/resolve_sources.py" --config "$PROJECT_DIR/sources.env" \
    --output-dir "$WORK_DIR" --mode "${KSU_SOURCE_MODE:-latest}"
# shellcheck source=/dev/null
source "$WORK_DIR/resolved-sources.env"
cp "$WORK_DIR/resolved-sources.env" "$WORK_DIR/resolved-sources.json" "$DIST_DIR/"

install_toolchain() {
    local name=$1 url=$2 binary=$3
    local directory="$TOOLCHAIN_DIR/$name"
    if [[ -f $directory/.complete ]] && [[ $(<"$directory/.complete") == "$url" ]]; then
        [[ -x $directory/bin/$binary ]] || die "Incomplete toolchain cache: $name"
        return
    fi
    [[ ! -e $directory ]] || die "Unexpected/incomplete toolchain directory: $directory; invalidate the cache"
    mkdir -p "$directory"
    download "$url" "$WORK_DIR/$name.tar.gz"
    tar -xzf "$WORK_DIR/$name.tar.gz" -C "$directory"
    [[ -x $directory/bin/$binary ]] || die "Missing $name/bin/$binary"
    printf '%s\n' "$url" > "$directory/.complete"
    rm -f -- "$WORK_DIR/$name.tar.gz"
}

mkdir -p "$TOOLCHAIN_DIR"
install_toolchain clang "$CLANG_URL" clang
install_toolchain gcc64 "$GCC64_URL" aarch64-linux-android-as
install_toolchain gcc32 "$GCC32_URL" arm-linux-androideabi-as

# The Android 4.9 archives provide binutils, not necessarily a gcc executable.
for spec in 'gcc64 aarch64-linux-android' 'gcc32 arm-linux-androideabi'; do
    read -r name prefix <<< "$spec"
    tool_bin="$TOOLCHAIN_DIR/$name/bin"
    if [[ ! -x $tool_bin/$prefix-ld ]]; then
        if [[ -x $tool_bin/$prefix-ld.gold ]]; then
            ln -s "$prefix-ld.gold" "$tool_bin/$prefix-ld"
        elif [[ -x $tool_bin/$prefix-ld.bfd ]]; then
            ln -s "$prefix-ld.bfd" "$tool_bin/$prefix-ld"
        else
            die "Missing $prefix linker"
        fi
    fi
done

export PATH="$TOOLCHAIN_DIR/clang/bin:$TOOLCHAIN_DIR/gcc64/bin:$TOOLCHAIN_DIR/gcc32/bin:$PATH"
for tool in clang ld.lld aarch64-linux-android-as aarch64-linux-android-ld \
    aarch64-linux-android-nm arm-linux-androideabi-as arm-linux-androideabi-ld ccache; do
    command -v "$tool" || die "Missing executable: $tool"
done
clang --version
ld.lld --version

clone_pinned "$KERNEL_REPO" "$KERNEL_COMMIT" "$KERNEL_DIR"
clone_pinned "$ANYKERNEL_REPO" "$ANYKERNEL_COMMIT" "$WORK_DIR/AnyKernel3"
# A real Git repository with history is needed for KSU's version calculation.
git clone --filter=blob:none --no-checkout "$KSU_REPO" "$KERNEL_DIR/KernelSU-Next"
# Fetch the exact snapshot too, including known-good commits no longer at a tip.
git -C "$KERNEL_DIR/KernelSU-Next" fetch origin "$KSU_COMMIT"
git -C "$KERNEL_DIR/KernelSU-Next" -c advice.detachedHead=false checkout --detach "$KSU_COMMIT"
assert_commit "$KERNEL_DIR/KernelSU-Next" "$KSU_COMMIT"
download "https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/$KSU_SETUP_COMMIT/kernel/setup.sh" "$WORK_DIR/ksu-setup.sh"

MANAGER_APK="$DIST_DIR/KernelSU-Next-Manager-$MANAGER_VERSION.apk"
download "$MANAGER_URL" "$MANAGER_APK"
printf '%s  %s\n' "$MANAGER_SHA256" "$MANAGER_APK" | sha256sum --check --status
unzip -tq "$MANAGER_APK"

export CCACHE_DIR="${CCACHE_DIR:-$WORK_DIR/.ccache}"
ccache --max-size 3G
ccache --zero-stats
df -h "$WORK_DIR"
printf 'Sources, toolchains, installer and Manager APK are ready.\n'
