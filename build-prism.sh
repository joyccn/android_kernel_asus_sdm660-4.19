#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_DIR="${RELEASE_DIR:-/root/kernel-work/releases}"
WORK_DIR="${WORK_DIR:-/root/kernel-work/tmp}"
AK3_REPO="${AK3_REPO:-https://github.com/joyccn/AnyKernel3}"
AK3_BRANCH="${AK3_BRANCH:-master}"
AK3_DIR="${AK3_DIR:-}"
JOBS="${JOBS:-$(nproc)}"

VARIANT="${VARIANT:-noksu}"
DEFCONFIG_NOKSU="${DEFCONFIG_NOKSU:-vendor/asus/X01BD_defconfig}"
DEFCONFIG_KSU="${DEFCONFIG_KSU:-vendor/asus/X01BD_ksu_defconfig}"

export ARCH=arm64
export SUBARCH=arm64
export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-BukanSuhuTelegram}"
export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-Prism-Project}"
export PATH="/usr/local/lib/ccache:$PATH"
export CCACHE_DIR="${CCACHE_DIR:-/root/.cache/ccache}"

usage() {
  cat <<USAGE
Usage: $0 [build|package|all|clean|distclean|bolt-check]

Targets:
  build       Generate a clean Prism Image.gz-dtb.
  package     Copy Image.gz-dtb into AnyKernel3 and create a flashable zip.
  all         Run build and package. This is the default target.
  clean       Clean only kernel build output.
  distclean   Remove kernel output directory.
  bolt-check  Check whether vmlinux can be post-processed by llvm-bolt.

Variants (VARIANT env var):
  noksu       Build without KernelSU (default).
  ksu         Build with KernelSU support.
  both        Build both variants sequentially.

AnyKernel3 source:
  By default the packager clones AK3_REPO/AK3_BRANCH into a fresh staging
  directory for each zip. Set AK3_DIR to package from an existing local tree.

Environment: RELEASE_DIR, WORK_DIR, AK3_REPO, AK3_BRANCH, AK3_DIR, JOBS, VARIANT.
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

make_args=()
prepare_ak3_tree() {
  local dest="$1"

  rm -rf "$dest"
  mkdir -p "$(dirname "$dest")"

  if [[ -n "$AK3_DIR" ]]; then
    test -d "$AK3_DIR" || {
      echo "AK3_DIR does not exist: $AK3_DIR" >&2
      return 1
    }
    rsync -a --delete \
      --exclude ".git" \
      --exclude "*.zip" \
      --exclude "tmp/" \
      "$AK3_DIR"/ "$dest"/
    return 0
  fi

  echo "=== Cloning AnyKernel3 ==="
  echo "  repo   : $AK3_REPO"
  echo "  branch : $AK3_BRANCH"
  echo "  dest   : $dest"
  git clone --depth=1 --branch "$AK3_BRANCH" "$AK3_REPO" "$dest"
}

build_one() {
  local variant_label="$1" defconfig="$2" out_dir="$3" stamp="$4"

  make_args=(
    O="$out_dir"
    ARCH=arm64
    LLVM=1
    LLVM_IAS=1
    CROSS_COMPILE=aarch64-linux-gnu-
    CROSS_COMPILE_ARM32=arm-linux-gnueabi-
  )

  echo "=== Building Prism ($variant_label) ==="
  echo "  defconfig : $defconfig"
  echo "  out_dir   : $out_dir"
  echo "  stamp     : $stamp"

  check_tools
  mkdir -p "$out_dir" "$RELEASE_DIR"
  make "${make_args[@]}" "$defconfig"
  make "${make_args[@]}" -j"$JOBS" Image.gz-dtb dtbs
  test -s "$out_dir/arch/arm64/boot/Image.gz-dtb"

  cp -f "$out_dir/arch/arm64/boot/Image.gz-dtb" \
    "$RELEASE_DIR/Prism-X01BD-${stamp}-Image.gz-dtb"
  cp -f "$out_dir/.config" \
    "$RELEASE_DIR/Prism-X01BD-${stamp}.config"

  package_one "$variant_label" "$out_dir" "$stamp"
}

package_one() {
  local variant_label="$1" out_dir="$2" stamp="$3"
  local img="$out_dir/arch/arm64/boot/Image.gz-dtb"
  local ak3_work="$WORK_DIR/ak3-${stamp}"

  test -s "$img" || {
    echo "Image not found: $img. Build first." >&2
    return 1
  }

  local zip_name="Prism-X01BD-${stamp}-AnyKernel3.zip"
  mkdir -p "$RELEASE_DIR" "$WORK_DIR"
  prepare_ak3_tree "$ak3_work"
  cp -f "$img" "$ak3_work/Image.gz-dtb"
  (cd "$ak3_work" && zip -r9 "$RELEASE_DIR/$zip_name" . \
    -x ".git/*" "README.md" "*.zip" "tmp/*" >/dev/null)
  sha256sum "$RELEASE_DIR/$zip_name" | tee "$RELEASE_DIR/$zip_name.sha256"
  du -h "$RELEASE_DIR/$zip_name"
}

build_kernel() {
  local stamp
  stamp="$(date -u +%Y%m%d-%H%M)"

  case "$VARIANT" in
    noksu)
      build_one "noKSU" "$DEFCONFIG_NOKSU" \
        "$ROOT_DIR/out-prism" "${stamp}-noksu"
      ;;
    ksu)
      build_one "KSU" "$DEFCONFIG_KSU" \
        "$ROOT_DIR/out-prism-ksu" "${stamp}-ksu"
      ;;
    both)
      build_one "noKSU" "$DEFCONFIG_NOKSU" \
        "$ROOT_DIR/out-prism" "${stamp}-noksu"
      build_one "KSU" "$DEFCONFIG_KSU" \
        "$ROOT_DIR/out-prism-ksu" "${stamp}-ksu"
      ;;
    *)
      echo "Unknown variant: $VARIANT (use noksu, ksu, or both)" >&2
      exit 2
      ;;
  esac
}

package_kernel() {
  local stamp
  stamp="$(date -u +%Y%m%d-%H%M)"

  case "$VARIANT" in
    noksu)
      package_one "noKSU" "$ROOT_DIR/out-prism" "${stamp}-noksu"
      ;;
    ksu)
      package_one "KSU" "$ROOT_DIR/out-prism-ksu" "${stamp}-ksu"
      ;;
    both)
      package_one "noKSU" "$ROOT_DIR/out-prism" "${stamp}-noksu"
      package_one "KSU" "$ROOT_DIR/out-prism-ksu" "${stamp}-ksu"
      ;;
  esac
}

bolt_check() {
  require_tool llvm-bolt
  local out_dir="${OUT_DIR:-$ROOT_DIR/out-prism}"
  test -s "$out_dir/vmlinux" || {
    echo "No vmlinux found in $out_dir. Run build first." >&2
    exit 1
  }
  llvm-bolt "$out_dir/vmlinux" -o /tmp/prism-vmlinux.bolt --print-profile-stats \
    >/tmp/prism-bolt.log 2>&1 || {
    cat /tmp/prism-bolt.log
    echo "BOLT is available, but this vmlinux cannot be safely optimized without a valid runtime profile." >&2
    return 1
  }
}

target="${1:-all}"
case "$target" in
  build) build_kernel ;;
  package) package_kernel ;;
  all) build_kernel ;;
  clean)
    make -C "$ROOT_DIR" O="$ROOT_DIR/out-prism" ARCH=arm64 clean 2>/dev/null || true
    make -C "$ROOT_DIR" O="$ROOT_DIR/out-prism-ksu" ARCH=arm64 clean 2>/dev/null || true
    ;;
  distclean)
    rm -rf "$ROOT_DIR/out-prism" "$ROOT_DIR/out-prism-ksu"
    ;;
  bolt-check) bolt_check ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
