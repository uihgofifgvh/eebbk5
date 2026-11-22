#!/usr/bin/env bash
#
# 编译「带 ReSukiSU(BakaSU) 的 EEBBK sdm660 内核」(H7000)
#
# 用的是内核作者 XiKoTaSu 自己做好的 KSU 分支:
#   https://github.com/XiKoTaSu/android_kernel_eebbk_sdm660  (branch: ksu)
# 该分支已包含:
#   - BakaSU/ReSukiSU 作为 git submodule (KernelSU/)
#   - drivers/kernelsu -> ../KernelSU/kernel 软链 + drivers/{Makefile,Kconfig} 挂载
#   - fs/exec.c fs/open.c fs/stat.c kernel/reboot.c 的 manual hook
#   - H7000.config: CONFIG_KSU=y / CONFIG_KSU_MANUAL_HOOK=y
#
# 用法:
#   bash build-eebbk-ksu.sh
#
# 产物:
#   $OUT/arch/arm64/boot/Image.gz-dtb   <- 内核(含 KSU)
#   $OUT/arch/arm64/boot/dts/qcom/*.dtb
#
set -euo pipefail

REPO="${REPO:-https://github.com/XiKoTaSu/android_kernel_eebbk_sdm660}"
BRANCH="${BRANCH:-ksu}"
WORK="${WORK:-$PWD/eebbk-ksu-build}"
SRC="$WORK/kernel"
TC="$WORK/toolchains/gcc-9.3"
OUT="${OUT:-$WORK/out}"
JOBS="${JOBS:-8}"

say()  { printf '\n==> %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Linux" ]] || die "请在 Linux 或 WSL2 里跑（仓库里有 symlink / submodule）"
mkdir -p "$WORK"

# ---------------------------------------------------------------- 源码 + submodule
if [[ ! -d "$SRC/.git" ]]; then
    say "克隆内核源码 ($BRANCH, 递归取 submodule)"
    git clone --recursive -b "$BRANCH" "$REPO" "$SRC"
else
    say "更新已有源码"
    git -C "$SRC" fetch --all --tags
    git -C "$SRC" checkout "$BRANCH"
    git -C "$SRC" pull --ff-only || true
    git -C "$SRC" submodule update --init --recursive
fi

# ---------------------------------------------------------------- 工具链
# 作者 CI 用的是 gcc 9.3 (不是 clang)，见 .github/workflows/build.yml
if [[ ! -x "$TC/bin/aarch64-linux-gcc" ]]; then
    say "下载 aarch64-linux-gcc 9.3"
    mkdir -p "$(dirname "$TC")"
    git clone --depth=1 -b lineage-19.1 \
        https://github.com/LineageOS/android_prebuilts_gcc_linux-x86_aarch64_aarch64-linux-gnu-9.3 \
        "$TC"
fi
[[ -x "$TC/bin/aarch64-linux-gcc" ]] || die "$TC 不是有效的 gcc 9.3 工具链"

export PATH="$TC/bin:$PATH"
export ARCH=arm64
export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-
export KBUILD_BUILD_USER="${KBUILD_BUILD_USER:-builder}"
export KBUILD_BUILD_HOST="${KBUILD_BUILD_HOST:-localhost}"

# ---------------------------------------------------------------- 配置
cd "$SRC"
mkdir -p "$OUT"

# 注意：本树 scripts/kconfig/Makefile 里有 %.config 规则，
# 直接把片段 merge 进 .config（等价于 merge_config.sh），不要手动 cat
say "生成配置 (defconfig + 两个 eebbk 片段)"
make O="$OUT" ARCH=arm64 \
    sdm660-perf_defconfig \
    vendor/eebbk/sdm660-common.config \
    vendor/eebbk/H7000.config

say "检查 KSU 配置"
grep -E '^CONFIG_KSU(_MANUAL_HOOK)?=' "$OUT/.config" \
    || die "out/.config 里没有 CONFIG_KSU=y，片段没生效"

# ---------------------------------------------------------------- 编译
say "编译 (-j$JOBS)"
make -j"$JOBS" O="$OUT" ARCH=arm64 KCFLAGS="-Wno-error"

# ---------------------------------------------------------------- 结果
say "产物"
ls -lh "$OUT/arch/arm64/boot/Image.gz-dtb"
echo
echo "确认 KSU 编进去了:"
strings "$OUT/arch/arm64/boot/Image.gz" 2>/dev/null | grep -m1 -i 'kernelsu' || true
echo
cat <<'EOF'
下一步:
  1. 装 BakaSU / ReSukiSU 管理器 APK (https://bakasu.org 或 Baka-SU/BakaSU releases)
  2. 刷 boot:
       magiskboot unpack boot.img
       cp out/arch/arm64/boot/Image.gz-dtb kernel
       magiskboot repack boot.img new-boot.img
       fastboot flash boot new-boot.img
  3. 开机验证:
       adb shell su -c id          # 应输出 uid=0(root)
       adb shell ls /data/adb/ksu  # KSU 数据目录
EOF
