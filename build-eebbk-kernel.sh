#!/usr/bin/env bash
#
# 编译 EEBBK sdm660 内核 (android_kernel_eebbk_sdm660, lineage-18.1, Linux 4.4.302)
#
# 默认目标机型: EEBBK S5 (H7000)。其它 sdm660 机型改 FRAGMENTS。
#
# 用法:
#   bash build-eebbk-kernel.sh
#
# 可覆盖的环境变量:
#   WORK        工作目录 (默认 ./eebbk-kernel-build)
#   JOBS        并行数 (默认 8；4.4 链接很吃内存，别盲用 nproc)
#   CLANG_DIR   已有的 clang 目录 (例如 LineageOS 树里的
#               prebuilts/clang/host/linux-x86/clang-r353983c)
#   GCC_DIR     已有的 aarch64 gcc 4.9 目录
#   DEFCONFIG   defconfig (默认 vendor/sdm660-perf_defconfig)
#   FRAGMENTS   config 片段 (默认 sdm660-common + H7000)
#
# 产物:
#   $OUT/arch/arm64/boot/Image.gz-dtb   <- 内核 + appended dtb
#   $OUT/arch/arm64/boot/dts/qcom/*.dtb
#   $MODOUT/lib/modules/4.4.302*/       <- 内核模块 (.ko)
#
set -euo pipefail

KERNEL_REPO="${KERNEL_REPO:-https://github.com/EEBBK-QMUR-Devs/android_kernel_eebbk_sdm660}"
BRANCH="${BRANCH:-lineage-18.1}"
WORK="${WORK:-$PWD/eebbk-kernel-build}"
SRC="$WORK/kernel"
TC="$WORK/toolchains"
OUT="${OUT:-$WORK/out}"
MODOUT="${MODOUT:-$WORK/modules_out}"
JOBS="${JOBS:-8}"
DEFCONFIG="${DEFCONFIG:-vendor/sdm660-perf_defconfig}"
FRAGMENTS="${FRAGMENTS:-arch/arm64/configs/vendor/eebbk/sdm660-common.config arch/arm64/configs/vendor/eebbk/H7000.config}"

say() { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

command -v git >/dev/null || die "需要 git"
command -v make >/dev/null || die "需要 make / build-essential"
[[ "$(uname -s)" == "Linux" ]] || die "请在 Linux 或 WSL2 里运行（仓库里 arch/arm64/configs/vendor/* 和 boot/dts/qcom 都是符号链接，Windows 下 clone 会坏掉）"

mkdir -p "$WORK" "$TC"

# ---------------------------------------------------------------- 源码
if [[ ! -d "$SRC/.git" ]]; then
    say "克隆内核源码 ($BRANCH)"
    git clone --depth=1 -b "$BRANCH" "$KERNEL_REPO" "$SRC"
else
    say "复用已有源码 $SRC"
fi

# ---------------------------------------------------------------- toolchain
# clang: 4.4 内核请用老 clang (r353983c / clang 9~12)。clang 14+ 基本编不过。
if [[ -z "${CLANG_DIR:-}" ]]; then
    CLANG_DIR="$TC/clang"
    if [[ ! -x "$CLANG_DIR/bin/clang" ]]; then
        say "下载 proton-clang (clang 12 + binutils)"
        git clone --depth=1 https://github.com/kdrag0n/proton-clang "$CLANG_DIR"
    fi
fi
[[ -x "$CLANG_DIR/bin/clang" ]] || die "CLANG_DIR=$CLANG_DIR 里没有 bin/clang"

if [[ -z "${GCC_DIR:-}" ]]; then
    GCC_DIR="$TC/gcc64"
fi
if [[ ! -x "$GCC_DIR/bin/aarch64-linux-android-gcc" ]]; then
    say "下载 aarch64-linux-android-4.9"
    git clone --depth=1 -b lineage-18.1 \
        https://github.com/LineageOS/android_prebuilts_gcc_linux-x86_aarch64_aarch64-linux-android-4.9 \
        "$GCC_DIR"
fi
[[ -x "$GCC_DIR/bin/aarch64-linux-android-gcc" ]] || die "GCC_DIR=$GCC_DIR 不是有效的 gcc 4.9 目录"

export PATH="$CLANG_DIR/bin:$GCC_DIR/bin:$PATH"
export ARCH=arm64
export SUBARCH=arm64
export CROSS_COMPILE="$GCC_DIR/bin/aarch64-linux-android-"
export CC=clang
export CLANG_TRIPLE=aarch64-linux-gnu-

# ---------------------------------------------------------------- 配置
cd "$SRC"
mkdir -p "$OUT"

say "生成 .config: $DEFCONFIG"
make O="$OUT" ARCH=arm64 "$DEFCONFIG"

if [[ -n "$FRAGMENTS" ]]; then
    say "叠加 config 片段: $FRAGMENTS"
    for f in $FRAGMENTS; do
        [[ -f "$f" ]] || die "找不到片段 $f"
        cat "$f" >> "$OUT/.config"
    done
    make O="$OUT" ARCH=arm64 olddefconfig
fi

grep -q '^CONFIG_MACH_EEBBK_H7000=y' "$OUT/.config" \
    || warn "out/.config 里没有 CONFIG_MACH_EEBBK_H7000=y，机型片段可能没叠上"

# ---------------------------------------------------------------- 编译
say "编译内核 (-j$JOBS)"
make O="$OUT" ARCH=arm64 -j"$JOBS"

say "安装模块到 $MODOUT"
rm -rf "$MODOUT"
make O="$OUT" ARCH=arm64 \
    INSTALL_MOD_PATH="$MODOUT" \
    INSTALL_MOD_STRIP=1 \
    modules_install

# ---------------------------------------------------------------- 结果
say "产物"
ls -lh "$OUT/arch/arm64/boot/Image.gz-dtb"
if compgen -G "$OUT/arch/arm64/boot/dts/qcom/*.dtb" >/dev/null; then
    echo "dtb:"; ls -1 "$OUT/arch/arm64/boot/dts/qcom/"*.dtb | sed 's/^/  /'
fi
echo "modules:"
find "$MODOUT/lib/modules" -mindepth 1 -maxdepth 1 -type d | sed 's/^/  /'

cat <<'EOF'

下一步（二选一）:

A. 出 LineageOS 整包 (device tree 里 TARGET_FORCE_PREBUILT_KERNEL := true,
   brunch 不会编内核, 只会用 prebuilt):
     cp  out/arch/arm64/boot/Image.gz-dtb \
         ~/android/lineage/device/eebbk/H7000/prebuilts/Image.gz-dtb
     rm -rf ~/android/lineage/device/eebbk/H7000/prebuilts/modules/*
     cp -a modules_out/lib/modules/*/kernel/drivers/. \
         ~/android/lineage/device/eebbk/H7000/prebuilts/modules/   # 保持 .ko 相对路径
     source build/envsetup.sh && brunch H7000

B. 只换 boot.img:
     magiskboot unpack boot.img
     cp out/arch/arm64/boot/Image.gz-dtb kernel
     magiskboot repack boot.img new-boot.img
     fastboot flash boot new-boot.img

注意: defconfig 里 CONFIG_MODULE_SIG_FORCE=y，内核和 .ko 必须同一次编译，
      否则模块会被拒绝加载 (wifi/触摸等直接没了)。
EOF
