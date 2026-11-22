#!/usr/bin/env bash
#
# 把 KernelSU 集成进 4.4 内核树（非 GKI / 手动 hook 模式）。
#
# 用法：apply-ksu.sh <内核源码根目录>
#
# 做的事跟 KernelSU 官方的 kernel/setup.sh 一样，只是把每一步写死、可审计：
#   1. git clone KernelSU（指定 tag，保留完整历史，KSU 版本号靠 rev-list 计算）
#   2. drivers/kernelsu -> ../KernelSU/kernel 软链
#   3. drivers/Makefile 追加 obj-$(CONFIG_KSU) += kernelsu/
#   4. drivers/Kconfig 最后一个 endmenu 之前 source "drivers/kernelsu/Kconfig"
#   5. patch-hooks.py 手动插 hook（execve / faccessat / stat / vfs_read /
#      input / devpts）
#
set -euo pipefail

SRC=${1:-}
KSU_TAG=${KSU_TAG:-v0.9.5}
KSU_REPO=${KSU_REPO:-https://github.com/tiann/KernelSU}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

if [ -z "$SRC" ] || [ ! -d "$SRC" ]; then
    echo "usage: apply-ksu.sh <kernel_root>" >&2
    exit 2
fi
SRC=$(cd "$SRC" && pwd)

say() { printf '\n--- %s\n' "$*"; }

# ---------------------------------------------------------------- 1. 源码
if [ ! -d "$SRC/KernelSU/.git" ]; then
    say "克隆 KernelSU $KSU_TAG"
    # 不要 --depth=1：drivers/kernelsu 的 Makefile 用
    # `git rev-list --count HEAD` 推 KSU 版本号，浅克隆会得到 1，
    # 管理器那边会认为内核版本过低而拒绝连接。
    git clone --single-branch -b "$KSU_TAG" "$KSU_REPO" "$SRC/KernelSU"
else
    say "KernelSU 已存在，跳过克隆"
fi

# ---------------------------------------------------------------- 2. 软链
say "挂载 drivers/kernelsu"
ln -sfn ../KernelSU/kernel "$SRC/drivers/kernelsu"
ls -l "$SRC/drivers/kernelsu" | sed 's/^/    /'

# ---------------------------------------------------------------- 3. Makefile
if grep -q 'kernelsu/' "$SRC/drivers/Makefile"; then
    say "drivers/Makefile 已包含 kernelsu/"
else
    say "drivers/Makefile 追加 kernelsu/"
    printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> "$SRC/drivers/Makefile"
fi

# ---------------------------------------------------------------- 4. Kconfig
say "drivers/Kconfig 挂上 kernelsu/Kconfig"
python3 - "$SRC/drivers/Kconfig" <<'PY'
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8", errors="replace") as f:
    text = f.read()

if "drivers/kernelsu/Kconfig" in text:
    print("    已经挂过了，跳过")
    sys.exit(0)

pos = text.rfind("endmenu")
if pos < 0:
    print("    ERROR: drivers/Kconfig 里找不到 endmenu", file=sys.stderr)
    sys.exit(1)

text = text[:pos] + 'source "drivers/kernelsu/Kconfig"\n\n' + text[pos:]
with open(path, "w", encoding="utf-8", newline="\n") as f:
    f.write(text)
print("    已插入 source \"drivers/kernelsu/Kconfig\"")
PY

# ---------------------------------------------------------------- 5. hooks
say "插入手动 hook"
python3 "$HERE/patch-hooks.py" "$SRC" "$SRC/KernelSU/kernel"

# ---------------------------------------------------------------- 版本
say "KernelSU 版本"
KSV=$(cd "$SRC/KernelSU" && git rev-list --count HEAD 2>/dev/null || echo 0)
echo "    git commits = $KSV  =>  KSU_VERSION = $((10000 + KSV + 200))"
echo "    对应管理器：KernelSU v0.9.5 的 Manager APK"
