#!/usr/bin/env bash
# Shared by prepare.sh and build.sh; source this file, do not execute it.
set -Eeuo pipefail

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=../sources.env
source "$PROJECT_DIR/sources.env"
WORK_DIR=$(realpath -m -- "${WORK_DIR:-$PROJECT_DIR/work}")
DIST_DIR=$(realpath -m -- "${DIST_DIR:-$PROJECT_DIR/dist}")
export KERNEL_DIR="$WORK_DIR/kernel"
export TOOLCHAIN_DIR="$WORK_DIR/toolchains"
LOG_DIR="$DIST_DIR/logs"
mkdir -p "$WORK_DIR" "$DIST_DIR" "$LOG_DIR"

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

on_error() {
    local code=$?
    printf 'ERROR: %s:%s failed (exit %s). See dist/logs.\n' "${BASH_SOURCE[1]}" "$1" "$code" >&2
    exit "$code"
}
trap 'on_error "$LINENO"' ERR

download() {
    local url=$1 destination=$2
    curl --fail --location --show-error --silent --retry 5 --retry-all-errors \
        --connect-timeout 30 --max-time 900 "$url" -o "$destination.part"
    mv -- "$destination.part" "$destination"
}

assert_commit() {
    local repo=$1 expected=$2
    [[ $(git -C "$repo" rev-parse HEAD) == "$expected" ]] || die "Unexpected source commit: $repo"
}

clone_pinned() {
    local url=$1 commit=$2 directory=$3
    [[ ! -e $directory ]] || die "Source directory already exists: $directory; use a fresh WORK_DIR"
    git init -q "$directory"
    git -C "$directory" remote add origin "$url"
    git -C "$directory" fetch --depth=1 origin "$commit"
    git -C "$directory" -c advice.detachedHead=false checkout --detach FETCH_HEAD
    assert_commit "$directory" "$commit"
}
