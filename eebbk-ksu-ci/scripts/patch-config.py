#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""按 KernelSU / 本设备的需要，调整一份内核 .config。

用法: patch-config.py <path/to/.config>

为什么是这几个开关：
  CONFIG_KSU=y             KernelSU 必须 built-in。这个树的 defconfig 开了
                           CONFIG_MODULE_SIG_FORCE，编成 .ko 加载不进来。
  CONFIG_OVERLAY_FS=y      KernelSU v0.9.5 的 Kconfig 有 `depends on OVERLAY_FS`，
                           不改这个 CONFIG_KSU 会被 kconfig 静默丢掉。
  CONFIG_KPROBES=n         手动 hook 模式必须关掉 kprobe，否则 KSU 会同时走
                           kprobe 路径，误触发安全模式（开机按音量下就进安全模式）。
  CONFIG_MODULE_SIG_FORCE=n  原厂 .ko（wlan 等）不是用我们这次编出来的 key 签的，
                           FORCE 开着它们会全部加载失败。关掉后照常加载。
  CONFIG_DEBUG_INFO=n      只为缩短编译时间、减小产物；不影响运行时行为，
                           也不影响 vermagic。
"""

import re
import sys

# key -> 期望值（"y" 或 "n"）
SETTINGS = {
    "CONFIG_KSU": "y",
    "CONFIG_KSU_DEBUG": "n",
    "CONFIG_OVERLAY_FS": "y",
    "CONFIG_KPROBES": "n",
    "CONFIG_MODULE_SIG_FORCE": "n",
    "CONFIG_DEBUG_INFO": "n",
}

LINE_RE = re.compile(r"^\s*(?:#\s*)?(CONFIG_[A-Za-z0-9_]+)\s*(?:=.*|is not set)?\s*$")


def render(key, value):
    if value == "y":
        return "%s=y" % key
    return "# %s is not set" % key


def main():
    if len(sys.argv) != 2:
        print("usage: patch-config.py <path/to/.config>", file=sys.stderr)
        return 2

    path = sys.argv[1]
    with open(path, "r", encoding="utf-8-sig", errors="replace") as f:
        lines = f.read().splitlines()

    kept = []
    for line in lines:
        m = LINE_RE.match(line)
        if m and m.group(1) in SETTINGS:
            continue
        kept.append(line)

    while kept and not kept[-1].strip():
        kept.pop()

    kept.append("")
    kept.append("# --- eebbk-ksu-ci: KernelSU / build overrides ---")
    for key in SETTINGS:
        kept.append(render(key, SETTINGS[key]))

    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(kept) + "\n")

    print("cached .config: 已写入 %d 个 KSU 相关开关 -> %s" % (len(SETTINGS), path))
    for key in SETTINGS:
        print("  %s" % render(key, SETTINGS[key]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
