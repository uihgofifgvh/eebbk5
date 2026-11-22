#!/usr/bin/env bash
#
# 编译 EEBBK sdm660 内核（4.4，non-GKI），可选集成 KernelSU，并打包 AnyKernel3
# 刷机 zip。整个流程跑在 Linux 上（GitHub Actions 的 ubuntu-22.04 就行）。
#
# 环境变量（都有默认值）：
#   BRANCH          内核分支：android-p(4.4.153，配你给的 config) / lineage-18.1(4.4.302)
#   KSU             1=集成 KernelSU v0.9.5，0=不集成
#   USE_DEFCONFIG   1=用内核树自带的 sdm660-perf_defconfig，0=用 config/ 里那份 .config
#   CONFIG_FILE     相对仓库根目录的 .config 路径
#   DEFCONFIG       内核 defconfig 名
#   JOBS            并行度
#   WORK            工作目录（默认 ./build）
#   TC              GCC 9.3 工具链目录（默认 ~/.toolchains/gcc-9.3，方便 CI 缓存）
#
# 产物：build/artifacts/
#   Image.gz-dtb                    裸内核（含 dtb）
#   EEBBK-<branch>-KSU-<date>.zip   AnyKernel3 刷机包（TWRP 刷）
#   config-used.txt                 实际生效的 .config，出问题先看它
#
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)

REPO=${REPO:-https://github.com/EEBBK-QMUR-Devs/android_kernel_eebbk_sdm660}
BRANCH=${BRANCH:-android-p}
KSU=${KSU:-1}
USE_DEFCONFIG=${USE_DEFCONFIG:-0}
CONFIG_FILE=${CONFIG_FILE:-config/eebbk-sdm660.config}
DEFCONFIG=${DEFCONFIG:-sdm660-perf_defconfig}
JOBS=${JOBS:-$(nproc)}
WORK=${WORK:-$PWD/build}
TC=${TC:-$HOME/.toolchains/gcc-9.3}
TC_REPO=${TC_REPO:-https://github.com/LineageOS/android_prebuilts_gcc_linux-x86_aarch64_aarch64-linux-gnu-9.3}
AK3_REPO=${AK3_REPO:-https://github.com/osm0sis/AnyKernel3}

SRC=$WORK/kernel
OUT=$WORK/out
ART=$WORK/artifacts

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[warn] %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

mkdir -p "$WORK" "$ART"

step "环境"
echo "    branch        = $BRANCH"
echo "    KernelSU      = $KSU"
echo "    use_defconfig = $USE_DEFCONFIG"
echo "    jobs          = $JOBS"
echo "    workdir       = $WORK"
df -h "$WORK" | sed 's/^/    /'

# ---------------------------------------------------------------- 1. 源码
step "内核源码"
if [ ! -d "$SRC/.git" ]; then
    git clone --depth=1 --single-branch -b "$BRANCH" "$REPO" "$SRC" \
        || die "克隆 $BRANCH 失败，分支名写错了？(可选: android-p / lineage-18.1)"
else
    echo "    源码已存在，跳过克隆"
fi

KVER=$(sed -n 's/^VERSION = //p;' "$SRC/Makefile" | head -n1)
KPATCH=$(sed -n 's/^PATCHLEVEL = //p' "$SRC/Makefile" | head -n1)
KSUB=$(sed -n 's/^SUBLEVEL = //p' "$SRC/Makefile" | head -n1)
echo "    内核版本 = ${KVER}.${KPATCH}.${KSUB}  分支 = $BRANCH"

# ---------------------------------------------------------------- 2. 工具链
step "交叉工具链 (GCC 9.3)"
if ! ls "$TC"/bin/*gcc >/dev/null 2>&1; then
    mkdir -p "$(dirname "$TC")"
    ok=0
    for br in lineage-19.1 lineage-20.0 lineage-18.1 master main; do
        echo "    尝试分支 $br ..."
        if git clone --depth=1 -b "$br" "$TC_REPO" "$TC"; then
            ok=1
            break
        fi
        rm -rf "$TC"
    done
    [ "$ok" = 1 ] || die "下载 GCC 9.3 工具链失败"
else
    echo "    工具链已缓存"
fi

GCC_BIN=""
for cand in "$TC"/bin/aarch64-linux-gnu-gcc \
            "$TC"/bin/aarch64-linux-android-gcc \
            "$TC"/bin/aarch64-buildroot-linux-gnu-gcc \
            "$TC"/bin/aarch64-linux-gcc; do
    if [ -x "$cand" ]; then GCC_BIN=$cand; break; fi
done
if [ -z "$GCC_BIN" ]; then
    GCC_BIN=$(ls "$TC"/bin/*-gcc 2>/dev/null | head -n1 || true)
fi
[ -n "$GCC_BIN" ] || die "工具链里找不到 *-gcc（$TC/bin 内容不对）"

CROSS_COMPILE=$(basename "$GCC_BIN")
CROSS_COMPILE=${CROSS_COMPILE%%gcc*}
CC=$GCC_BIN
export PATH="$TC/bin:$PATH"
export ARCH=arm64 SUBARCH=arm64 CROSS_COMPILE CC
export KBUILD_BUILD_USER=${KBUILD_BUILD_USER:-builder}
export KBUILD_BUILD_HOST=${KBUILD_BUILD_HOST:-eebbk-ci}

echo "    CROSS_COMPILE = $CROSS_COMPILE"
echo "    CC            = $CC"
"$CC" --version | head -n1 | sed 's/^/    /'

# ---------------------------------------------------------------- 3. KernelSU
if [ "$KSU" = "1" ]; then
    step "集成 KernelSU"
    bash "$HERE/apply-ksu.sh" "$SRC"
else
    warn "KSU=0，跳过 KernelSU 集成"
fi

# ---------------------------------------------------------------- 4. 配置
step "生成 .config"
mkdir -p "$OUT"

if [ "$USE_DEFCONFIG" = "1" ]; then
    echo "    使用内核树自带 defconfig: $DEFCONFIG"
    make -C "$SRC" O="$OUT" ARCH=arm64 "$DEFCONFIG"
else
    echo "    使用配置: $CONFIG_FILE"
    [ -f "$ROOT/$CONFIG_FILE" ] || die "找不到 $ROOT/$CONFIG_FILE"
    cp "$ROOT/$CONFIG_FILE" "$OUT/.config"
    if [ "$KSU" = "1" ]; then
        python3 "$HERE/patch-config.py" "$OUT/.config"
    else
        warn "KSU=0，没有改写 OVERLAY_FS 等开关"
    fi
fi

make -C "$SRC" O="$OUT" ARCH=arm64 olddefconfig

echo "    关键开关："
grep -E '^CONFIG_(KSU|OVERLAY_FS|KPROBES|MODULE_SIG_FORCE|DEBUG_INFO|LOCALVERSION|IMG_GZ_DTB|BUILD_ARM64_APPENDED_KERNEL_IMAGE_NAME)' \
    "$OUT/.config" | sed 's/^/      /' || true
grep -qE '^# CONFIG_OVERLAY_FS is not set' "$OUT/.config" \
    && die "CONFIG_OVERLAY_FS 没打开，KSU 会被静默丢掉"
[ "$KSU" = "1" ] && { grep -q '^CONFIG_KSU=y' "$OUT/.config" || die "CONFIG_KSU=y 没生效"; }

# ---------------------------------------------------------------- 5. 编译
step "编译内核 (-j$JOBS)"
BUILD_LOG=$WORK/build.log
TARGET=Image.gz-dtb
set +e
make -C "$SRC" O="$OUT" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" CC="$CC" \
     HOSTCFLAGS="-fcommon" -j"$JOBS" "$TARGET" 2>&1 | tee "$BUILD_LOG"
rc=${PIPESTATUS[0]}
set -e

if [ "$rc" != "0" ] && [ "$TARGET" = "Image.gz-dtb" ]; then
    warn "Image.gz-dtb 目标失败，退回只编 Image.gz（dtb 会用 boot.img 里原有的）"
    set +e
    make -C "$SRC" O="$OUT" ARCH=arm64 CROSS_COMPILE="$CROSS_COMPILE" CC="$CC" \
         HOSTCFLAGS="-fcommon" -j"$JOBS" Image.gz 2>&1 | tee -a "$BUILD_LOG"
    rc=${PIPESTATUS[0]}
    set -e
    TARGET=Image.gz
fi
[ "$rc" = "0" ] || die "编译失败，看上面的报错（日志也在 $BUILD_LOG）"

IMG=$OUT/arch/arm64/boot/$TARGET
[ -f "$IMG" ] || die "编译结束了但找不到 $IMG"

# ---------------------------------------------------------------- 6. 校验
step "校验"
ls -lh "$IMG" | sed 's/^/    /'
if [ "$KSU" = "1" ]; then
    if nm "$OUT/vmlinux" 2>/dev/null | grep -q ' [tT] ksu_'; then
        echo "    vmlinux 里找到 ksu_ 符号："
        nm "$OUT/vmlinux" | grep ' [tT] ksu_' | head -n5 | sed 's/^/      /'
    else
        die "vmlinux 里没有 ksu_ 符号，KSU 没编进去"
    fi
fi

cp -f "$IMG" "$ART/"
cp -f "$OUT/.config" "$ART/config-used.txt"

# ---------------------------------------------------------------- 7. AK3
step "打包 AnyKernel3"
if [ ! -d "$WORK/ak3/.git" ]; then
    git clone --depth=1 "$AK3_REPO" "$WORK/ak3"
fi
cd "$WORK/ak3"
rm -rf .git README.md patch ramdisk modules split_img boot.img boot-new.img
rm -f Image Image.gz Image-dtb Image.gz-dtb zImage zImage-dtb
cp -f "$IMG" "."

cat > anykernel.sh <<'EOF'
### AnyKernel3 Ramdisk Mod Script
### 只替换 kernel，保留原 ramdisk / cmdline / dtb
properties() { '
kernel.string=EEBBK sdm660 Kernel (KernelSU)
do.devicecheck=0
do.modules=0
do.systemless=0
do.cleanup=1
do.cleanuponabort=0
device.name1=H7000
device.name2=eebbk
device.name3=sdm660
supported.versions=
supported.patchlevels=
'; } # end properties

BLOCK=boot;
IS_SLOT_DEVICE=0;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;

. tools/ak3-core.sh;

dump_boot;
write_boot;
EOF

ZIP=$ART/EEBBK-${BRANCH}-KSU-$(date +%Y%m%d).zip
rm -f "$ZIP"
zip -r9 "$ZIP" . -x '*.git*' >/dev/null
cd "$ROOT"

step "完成"
ls -lh "$ART" | sed 's/^/    /'
cat <<EOF

产物在 $ART
  - $TARGET（裸内核）
  - $(basename "$ZIP")（TWRP 刷机包）
  - config-used.txt

刷之前一定先备份 boot：
  adb shell su -c 'dd if=/dev/block/bootdevice/by-name/boot of=/sdcard/boot-stock.img'   # 有 root 时
  或 TWRP -> Backup -> Boot
EOF
