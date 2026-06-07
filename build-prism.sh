#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/out-prism}"
RELEASE_DIR="${RELEASE_DIR:-/root/kernel-work/releases}"
AK3_DIR="${AK3_DIR:-/root/kernel-work/AnyKernel3}"
DEFCONFIG="${DEFCONFIG:-vendor/asus/X01BD_defconfig}"
JOBS="${JOBS:-$(nproc)}"
STAMP="${STAMP:-$(date -u +%Y%m%d-%H%M)}"
ZIP_NAME="${ZIP_NAME:-Prism-X01BD-${STAMP}-AnyKernel3.zip}"

export ARCH=arm64
export SUBARCH=arm64
export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-BukanSuhuTelegram}"
export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-Prism-Project}"
export PATH="/usr/local/lib/ccache:$PATH"
export CCACHE_DIR="${CCACHE_DIR:-/root/.cache/ccache}"

make_args=(
  O="$OUT_DIR"
  ARCH=arm64
  LLVM=1
  LLVM_IAS=1
  CROSS_COMPILE=aarch64-linux-gnu-
  CROSS_COMPILE_ARM32=arm-linux-gnueabi-
)

usage() {
  cat <<USAGE
Usage: $0 [build|package|all|clean|distclean|bolt-check]

Targets:
  build       Generate a clean Prism Image.gz-dtb in out-prism.
  package     Copy Image.gz-dtb into AnyKernel3 and create a flashable zip.
  all         Run build and package. This is the default target.
  clean       Clean only kernel build output.
  distclean   Remove the kernel output directory.
  bolt-check  Check whether vmlinux can be post-processed by llvm-bolt.

Environment overrides: OUT_DIR, RELEASE_DIR, AK3_DIR, JOBS, STAMP, ZIP_NAME.
USAGE
}

require_tool() {
  command -v "$1" >/dev/null || {
    echo "Missing required tool: $1" >&2
    exit 1
  }
}

check_tools() {
  require_tool make
  require_tool clang
  require_tool ld.lld
  require_tool llvm-profdata
  require_tool aarch64-linux-gnu-gcc
  require_tool arm-linux-gnueabi-gcc
  require_tool ccache
  if ! clang -Werror -mllvm -polly -x c -c /dev/null -o /tmp/prism-polly.o >/tmp/prism-polly.log 2>&1; then
    cat /tmp/prism-polly.log >&2
    echo "This toolchain does not support Polly; disable CONFIG_LLVM_POLLY before building." >&2
    exit 1
  fi
}

build_kernel() {
  check_tools
  mkdir -p "$OUT_DIR" "$RELEASE_DIR"
  make "${make_args[@]}" "$DEFCONFIG"
  make "${make_args[@]}" -j"$JOBS" Image.gz-dtb dtbs
  test -s "$OUT_DIR/arch/arm64/boot/Image.gz-dtb"
  cp -f "$OUT_DIR/arch/arm64/boot/Image.gz-dtb" "$RELEASE_DIR/Prism-X01BD-Image.gz-dtb"
  cp -f "$OUT_DIR/.config" "$RELEASE_DIR/Prism-X01BD-${STAMP}.config"
}

package_kernel() {
  test -s "$OUT_DIR/arch/arm64/boot/Image.gz-dtb" || build_kernel
  test -d "$AK3_DIR" || {
    echo "AnyKernel3 directory not found: $AK3_DIR" >&2
    exit 1
  }
  mkdir -p "$RELEASE_DIR"
  cp -f "$OUT_DIR/arch/arm64/boot/Image.gz-dtb" "$AK3_DIR/Image.gz-dtb"
  (cd "$AK3_DIR" && zip -r9 "$RELEASE_DIR/$ZIP_NAME" . \
    -x ".git/*" "README.md" "*.zip" "tmp/*" >/dev/null)
  sha256sum "$RELEASE_DIR/$ZIP_NAME" | tee "$RELEASE_DIR/$ZIP_NAME.sha256"
}

bolt_check() {
  require_tool llvm-bolt
  test -s "$OUT_DIR/vmlinux" || build_kernel
  llvm-bolt "$OUT_DIR/vmlinux" -o /tmp/prism-vmlinux.bolt --print-profile-stats \
    >/tmp/prism-bolt.log 2>&1 || {
    cat /tmp/prism-bolt.log
    echo "BOLT is available, but this kernel vmlinux cannot be safely optimized without a valid runtime profile." >&2
    return 1
  }
}

target="${1:-all}"
case "$target" in
  build) build_kernel ;;
  package) package_kernel ;;
  all) build_kernel; package_kernel ;;
  clean) make "${make_args[@]}" clean ;;
  distclean) rm -rf "$OUT_DIR" ;;
  bolt-check) bolt_check ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
