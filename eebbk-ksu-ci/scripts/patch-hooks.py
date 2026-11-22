#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 KernelSU 的手动 hook 插进 4.4 内核源码树。

用法:
    patch-hooks.py <内核根目录> <KernelSU 根目录>

设计要点:
  * v0.9.5 支持 kprobe 与手动 hook 两种模式。4.4 的 kprobe 不可靠，这里走手动。
  * 不同 KernelSU 版本导出的函数名略有差异（ksu_handle_execveat vs
    ksu_handle_execveat_ksud），所以先扫描 KernelSU 源码里真实存在的符号，
    再决定插哪一版，避免链接期 undefined reference。
  * 每个插入点都幂等：已经插过就跳过。
  * execve / faccessat / stat 是必需的（没有它们拿不到 root）；
    vfs_read / input / devpts 是加分项（模块注入、安全模式、pm），失败只告警。
"""

import os
import re
import sys


# ---------------------------------------------------------------- 工具函数

def read(path):
    # utf-8-sig: 顺手吃掉可能存在的 BOM，否则会破坏 ^ 行首锚点
    with open(path, "r", encoding="utf-8-sig", errors="replace") as f:
        return f.read()


def write(path, text):
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)


def collect_ksu_symbols(ksu_root):
    blob = []
    for dirpath, _dirnames, names in os.walk(ksu_root):
        for name in names:
            if name.endswith((".c", ".h")):
                blob.append(read(os.path.join(dirpath, name)))
    return "\n".join(blob)


def insert_into_function(path, sig_pattern, snippet, marker):
    """在匹配 sig_pattern 的函数体最前面插入 snippet。

    返回 (status, detail)：
      ok / already / signature-not-found / body-not-found / file-missing
    """
    if not os.path.isfile(path):
        return "file-missing", path

    src = read(path)
    if marker in src:
        return "already", path

    m = re.search(sig_pattern, src, re.MULTILINE)
    if not m:
        return "signature-not-found", path

    brace = src.find("{", m.end())
    if brace < 0:
        return "body-not-found", path

    new_src = src[: brace + 1] + "\n" + snippet + src[brace + 1 :]
    if marker not in new_src:  # 理论上不会发生，保险
        return "body-not-found", path

    write(path, new_src)
    return "ok", path


def run_hook(results, label, required, path, sig, snippet, marker,
             alt_sig=None, alt_snippet=None):
    status, detail = insert_into_function(path, sig, snippet, marker)
    if status == "signature-not-found" and alt_sig and alt_snippet:
        status, detail = insert_into_function(path, alt_sig, alt_snippet, marker)
    results.append((label, required, status, detail))


def block(lines):
    """把 C 代码行整理成可插入函数体开头的字符串。

    预处理指令（#ifdef / #endif）保持顶格，其余行整体缩进一级；
    模板里已经带 \\t 的嵌套行会自然再多一级。
    """
    out = []
    for ln in lines:
        if not ln or ln.startswith("#"):
            out.append(ln)
        else:
            out.append("\t" + ln)
    return "\n".join(out) + "\n"


# ---------------------------------------------------------------- 函数签名

EXEC_SIG = r"^static int do_execveat_common\([^;\n]*$"

FACCESSAT_SIG_DO = r"^long do_faccessat\([^;\n]*$"
FACCESSAT_SIG_SYSCALL = r"^SYSCALL_DEFINE3\(faccessat,[^;\n]*$"

STAT_SIG_VFS_FSTATAT = r"^int vfs_fstatat\([^;\n]*$"
STAT_SIG_VFS_STATX = r"^int vfs_statx\([^;\n]*$"

VFS_READ_SIG = r"^ssize_t vfs_read\([^;\n]*$"

INPUT_SIG = r"^static void input_handle_event\([^;\n]*$"

DEVPTS_SIG = r"^void \*devpts_get_priv\([^;\n]*$"


# ---------------------------------------------------------------- hook 模板

def exec_snippet(symbols):
    """execveat：优先官方 v0.9.5 的 ksu_handle_execveat + ksu_execveat_hook 组合。"""
    if "ksu_handle_execveat(" in symbols and "ksu_execveat_hook" in symbols:
        return block(
            [
                "#ifdef CONFIG_KSU",
                "{",
                "\textern bool ksu_execveat_hook;",
                "\textern int ksu_handle_execveat(int *fd,",
                "\t\t\tstruct filename **filename_ptr,",
                "\t\t\tvoid *argv, void *envp, int *flags);",
                "\textern int ksu_handle_execveat_sucompat(int *fd,",
                "\t\t\tstruct filename **filename_ptr,",
                "\t\t\tvoid *argv, void *envp, int *flags);",
                "",
                "\tif (unlikely(ksu_execveat_hook))",
                "\t\tksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);",
                "\telse",
                "\t\tksu_handle_execveat_sucompat(&fd, &filename, &argv, &envp, &flags);",
                "}",
                "#endif",
            ]
        )
    # 备选 1：社区/早期分支把它拆成 sucompat + ksud 两个入口
    if "ksu_handle_execveat_ksud" in symbols:
        return block(
            [
                "#ifdef CONFIG_KSU",
                "{",
                "\textern int ksu_handle_execveat_sucompat(int *fd,",
                "\t\t\tstruct filename **filename_ptr,",
                "\t\t\tvoid *argv, void *envp, int *flags);",
                "\textern int ksu_handle_execveat_ksud(int *fd,",
                "\t\t\tstruct filename **filename_ptr,",
                "\t\t\tvoid *argv, void *envp, int *flags);",
                "",
                "\tksu_handle_execveat_sucompat(&fd, &filename, &argv, &envp, &flags);",
                "\tksu_handle_execveat_ksud(&fd, &filename, &argv, &envp, &flags);",
                "}",
                "#endif",
            ]
        )

    # 备选 2：只有 sucompat，没有 ksud 入口 —— root 能用，模块注入会退化
    return block(
        [
            "#ifdef CONFIG_KSU",
            "{",
            "\textern int ksu_handle_execveat_sucompat(int *fd,",
            "\t\t\tstruct filename **filename_ptr,",
            "\t\t\tvoid *argv, void *envp, int *flags);",
            "",
            "\tksu_handle_execveat_sucompat(&fd, &filename, &argv, &envp, &flags);",
            "}",
            "#endif",
        ]
    )


FACCESSAT_SNIPPET = block(
    [
        "#ifdef CONFIG_KSU",
        "{",
        "\textern int ksu_handle_faccessat(int *dfd,",
        "\t\t\tconst char __user **filename_user,",
        "\t\t\tint *mode, int *flags);",
        "",
        "\tksu_handle_faccessat(&dfd, &filename, &mode, NULL);",
        "}",
        "#endif",
    ]
)

STAT_SNIPPET_FSTATAT = block(
    [
        "#ifdef CONFIG_KSU",
        "{",
        "\textern int ksu_handle_stat(int *dfd,",
        "\t\t\tconst char __user **filename_user,",
        "\t\t\tint *flags);",
        "",
        "\tksu_handle_stat(&dfd, &filename, &flag);",
        "}",
        "#endif",
    ]
)

STAT_SNIPPET_STATX = block(
    [
        "#ifdef CONFIG_KSU",
        "{",
        "\textern int ksu_handle_stat(int *dfd,",
        "\t\t\tconst char __user **filename_user,",
        "\t\t\tint *flags);",
        "",
        "\tksu_handle_stat(&dfd, &filename, &flags);",
        "}",
        "#endif",
    ]
)

VFS_READ_SNIPPET = block(
    [
        "#ifdef CONFIG_KSU",
        "{",
        "\textern bool ksu_vfs_read_hook;",
        "\textern int ksu_handle_vfs_read(struct file **file_ptr,",
        "\t\t\tchar __user **buf_ptr, size_t *count_ptr,",
        "\t\t\tloff_t **pos);",
        "",
        "\tif (unlikely(ksu_vfs_read_hook))",
        "\t\tksu_handle_vfs_read(&file, &buf, &count, &pos);",
        "}",
        "#endif",
    ]
)

INPUT_SNIPPET = block(
    [
        "#ifdef CONFIG_KSU",
        "{",
        "\textern bool ksu_input_hook;",
        "\textern int ksu_handle_input_handle_event(unsigned int *type,",
        "\t\t\tunsigned int *code, int *value);",
        "",
        "\tif (unlikely(ksu_input_hook))",
        "\t\tksu_handle_input_handle_event(&type, &code, &value);",
        "}",
        "#endif",
    ]
)

DEVPTS_SNIPPET = block(
    [
        "#ifdef CONFIG_KSU",
        "{",
        "\textern int ksu_handle_devpts(struct inode *);",
        "",
        "\tksu_handle_devpts(dentry->d_inode);",
        "}",
        "#endif",
    ]
)


# ---------------------------------------------------------------- 主流程

def main():
    if len(sys.argv) != 3:
        print("usage: patch-hooks.py <kernel_root> <KernelSU_root>", file=sys.stderr)
        return 2

    root = os.path.abspath(sys.argv[1])
    ksu_root = os.path.abspath(sys.argv[2])
    symbols = collect_ksu_symbols(ksu_root)

    print("=== KernelSU hooks: %s ===" % root)
    results = []

    # ---- 必需：没有它们拿不到 root
    if "ksu_handle_execveat_sucompat" in symbols:
        run_hook(results, "fs/exec.c (do_execveat_common)", True,
                 os.path.join(root, "fs/exec.c"), EXEC_SIG, exec_snippet(symbols),
                 "ksu_handle_execveat_sucompat")
    else:
        results.append(("fs/exec.c (do_execveat_common)", True, "skipped",
                        "KernelSU 里没有 ksu_handle_execveat_sucompat"))

    if "ksu_handle_faccessat" in symbols:
        run_hook(results, "fs/open.c (faccessat)", True,
                 os.path.join(root, "fs/open.c"), FACCESSAT_SIG_DO, FACCESSAT_SNIPPET,
                 "ksu_handle_faccessat", FACCESSAT_SIG_SYSCALL, FACCESSAT_SNIPPET)
    else:
        results.append(("fs/open.c (faccessat)", True, "skipped", "symbol not found"))

    if "ksu_handle_stat" in symbols:
        run_hook(results, "fs/stat.c (vfs_fstatat/vfs_statx)", True,
                 os.path.join(root, "fs/stat.c"), STAT_SIG_VFS_FSTATAT, STAT_SNIPPET_FSTATAT,
                 "ksu_handle_stat", STAT_SIG_VFS_STATX, STAT_SNIPPET_STATX)
    else:
        results.append(("fs/stat.c", True, "skipped", "symbol not found"))

    # ---- 可选：模块注入 / 安全模式 / pm
    if "ksu_handle_vfs_read" in symbols and "ksu_vfs_read_hook" in symbols:
        run_hook(results, "fs/read_write.c (vfs_read)", False,
                 os.path.join(root, "fs/read_write.c"), VFS_READ_SIG, VFS_READ_SNIPPET,
                 "ksu_handle_vfs_read")
    else:
        results.append(("fs/read_write.c (vfs_read)", False, "skipped", "symbol not found"))

    if "ksu_handle_input_handle_event" in symbols:
        run_hook(results, "drivers/input/input.c (safe mode)", False,
                 os.path.join(root, "drivers/input/input.c"), INPUT_SIG, INPUT_SNIPPET,
                 "ksu_handle_input_handle_event")
    else:
        results.append(("drivers/input/input.c", False, "skipped", "symbol not found"))

    if "ksu_handle_devpts" in symbols:
        run_hook(results, "fs/devpts/inode.c (devpts_get_priv)", False,
                 os.path.join(root, "fs/devpts/inode.c"), DEVPTS_SIG, DEVPTS_SNIPPET,
                 "ksu_handle_devpts")
    else:
        results.append(("fs/devpts/inode.c", False, "skipped", "symbol not found"))

    failed_required = 0
    warned = 0
    for label, required, status, detail in results:
        note = "" if status in ("ok", "already") else detail
        print("  %-44s %-16s %s" % (label, status, note))
        if status in ("ok", "already"):
            continue
        if required:
            failed_required += 1
        else:
            warned += 1

    if failed_required:
        print("\n%d 个必需 hook 没插上（signature-not-found = 函数签名和预期不符）。" % failed_required)
        return 1
    if warned:
        print("\n有 %d 个可选 hook 没插上：root 能用，但模块注入/安全模式可能受影响。" % warned)
    print("\n必需 hook 已就位。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
