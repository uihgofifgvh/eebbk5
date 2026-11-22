#!/usr/bin/env bash
#
# 把编好的 EEBBK H7000 内核打成 AnyKernel3 刷机包
#
# 用法:
#   SRC=~/kernel-eebbk bash make-ak3-eebbk.sh
#
# 可覆盖的变量:
#   SRC      内核源码/构建目录 (默认 ./kernel-eebbk)
#   OUT      构建输出目录 (默认 $SRC/out)
#   MODOUT   modules_install 临时目录 (默认 $SRC/../modout)
#   AK3      AnyKernel3 工作目录 (默认 ./ak3)
#   ZIP      输出 zip (默认 ./H7000-KSU-<日期>.zip)
#   SKIP_MODULES=1  不带模块（内核里模块都是 =y 时才用）
#
set -euo pipefail

SRC="${SRC:-$PWD/kernel-eebbk}"
OUT="${OUT:-$SRC/out}"
MODOUT="${MODOUT:-$SRC/../modout}"
AK3="${AK3:-$PWD/ak3}"
ZIP="${ZIP:-$PWD/H7000-KSU-$(date +%Y%m%d).zip}"

say() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ -f "$OUT/arch/arm64/boot/Image.gz-dtb" ]] || die "找不到 $OUT/arch/arm64/boot/Image.gz-dtb，先编内核"
command -v zip >/dev/null || die "需要 zip（apt install zip）"

# ---------------------------------------------------------------- AK3 模板
if [[ ! -d "$AK3" ]]; then
    say "获取 AnyKernel3 模板"
    git clone --depth=1 https://github.com/osm0sis/AnyKernel3 "$AK3"
fi

cd "$AK3"
rm -rf .git README.md patch ramdisk modules split_img boot.img boot-new.img
rm -f Image Image.gz Image-dtb Image.gz-dtb zImage zImage-dtb

say "放入内核"
cp -f "$OUT/arch/arm64/boot/Image.gz-dtb" .

# ---------------------------------------------------------------- 模块
# CONFIG_MODULE_SIG_FORCE=y：内核和 .ko 必须同一次编译，所以模块必须随包刷入
if [[ -z "${SKIP_MODULES:-}" ]]; then
    say "收集模块（modules_install，带签名、strip 过）"
    rm -rf "$MODOUT"
    make -C "$SRC" O="$OUT" ARCH=arm64 \
        INSTALL_MOD_PATH="$MODOUT" INSTALL_MOD_STRIP=1 \
        modules_install >/dev/null

    rm -rf modules
    mkdir -p modules/vendor/lib/modules
    find "$MODOUT" -name '*.ko' -exec cp -f {} modules/vendor/lib/modules/ \;

    # qcacld 在部分树上产物叫 wlan.ko，但 ROM 里叫 qca_cld3_wlan.ko
    if [[ -f modules/vendor/lib/modules/wlan.ko && \
          ! -f modules/vendor/lib/modules/qca_cld3_wlan.ko ]]; then
        mv modules/vendor/lib/modules/wlan.ko modules/vendor/lib/modules/qca_cld3_wlan.ko
    fi
    ls -1 modules/vendor/lib/modules
fi

# ---------------------------------------------------------------- anykernel.sh
say "写入 anykernel.sh"
cat > anykernel.sh <<'EOF'
### AnyKernel3 Ramdisk Mod Script
properties() { '
kernel.string=EEBBK H7000 Kernel (KSU)
do.devicecheck=0
do.modules=1
do.systemless=0
do.cleanup=1
do.cleanuponabort=0
device.name1=H7000
supported.versions=
supported.patchlevels=
'; } # end properties

# A-only 机器，boot 分区
BLOCK=boot;
IS_SLOT_DEVICE=0;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=auto;

. tools/ak3-core.sh;

dump_boot;
write_boot;
EOF
[[ -z "${SKIP_MODULES:-}" ]] || sed -i 's/^do.modules=1/do.modules=0/' anykernel.sh

# ---------------------------------------------------------------- 打包
say "打包"
rm -f "$ZIP"
zip -r9 "$ZIP" * -x 'README.md' '*placeholder' >/dev/null

say "完成"
ls -lh "$ZIP"
unzip -l "$ZIP" | sed -n '1,20p'
cat <<'EOF'

刷入:
  TWRP -> Install -> 选这个 zip（先备份 boot 分区）
回滚:
  fastboot flash boot boot-stock.img

验证:
  adb shell uname -r
  adb shell su -c id
  adb shell lsmod | head
  adb shell dmesg | grep -i 'module.*verif'
EOF
