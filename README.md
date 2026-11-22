# EEBBK sdm660 内核 + KernelSU（云端编译）

给 <https://github.com/EEBBK-QMUR-Devs/android_kernel_eebbk_sdm660> 打上 KernelSU，
用 GitHub Actions 编出可刷的内核和 AnyKernel3 刷机包。

---

## 0. 为什么不是在这台电脑上直接编

这台 Windows 机器上：

- 没有 WSL / 没有 Linux 发行版，也没有管理员权限（装不了）；
- 没有 `make` / `gcc` / `clang` / `git`；
- 沙箱把出网也掐了，`github.com` 连不上，下不了 1.3 GB 的源码和工具链。

而 4.4 内核必须在 Linux 上、用 aarch64 交叉工具链编，还要 ~15 GB 磁盘和 30～50 分钟 CPU。
所以这里做成一条**云端流水线**：代码在 GitHub 的机器上编，你只管点运行、下产物。

---

## 1. 你要做的三步

**① 建仓库**

GitHub → New repository → 名字随便（例如 `eebbk-ksu`）→ Private 也可以 → Create。

**② 把本目录传上去**

网页进仓库 → *Add file* → *Upload files* → 把 `eebbk-ksu-ci/` 里的东西全部拖进去
（**注意 `.github/`、`config/`、`scripts/` 三个目录和它们的层级要保留**）→ Commit。

> 网页上传支持拖文件夹；如果 `.github` 目录没上去，Actions 里就看不到 workflow。

**③ 跑起来**

仓库上方 *Actions* → 左边选 **Build EEBBK sdm660 kernel (KernelSU)** →
右边 *Run workflow* → 选分支 → *Run workflow*。

第一次大约 **30–50 分钟**。跑完点进这次 run，页面底部 **Artifacts** 里下载
`eebbk-kernel-<分支>.zip`。

---

## 2. 分支选哪个（这一步别选错）

| 分支 | 内核版本 | 什么时候用 |
| --- | --- | --- |
| `android-p` | **4.4.153** | 设备还在跑**原厂 Android 9**。你给我的 `config` 就是 4.4.153 的，和这个分支对得上 |
| `lineage-18.1` | **4.4.302** | 设备刷了 **LineageOS 18.1** |

确认方法（任选）：

- 设置 → 关于平板/关于手机 → **内核版本**，看是 `4.4.153-perf` 还是 `4.4.302-perf`；
- 或者 `adb shell uname -r`。

> 选错的后果不是变砖，而是内核起来了但 `wlan.ko` 等 vendor 模块的 vermagic 对不上，
> 加载失败（没 WiFi、可能没声音）。刷回备份的 boot 就恢复。
> 拿不准就先按 `android-p` 编一版。

---

## 3. 产物

`Artifacts` 里那个 zip 解开是：

| 文件 | 说明 |
| --- | --- |
| `Image.gz-dtb` | 裸内核，已把 dtb 拼进去（`CONFIG_IMG_GZ_DTB=y`） |
| `EEBBK-<分支>-KSU-<日期>.zip` | **AnyKernel3 刷机包**，TWRP 直接刷 |
| `config-used.txt` | 实际生效的 `.config`，出问题先看它 |

---

## 4. 刷机

前提：bootloader 已解锁、有 TWRP、**先备份 boot 分区**。

```sh
# TWRP 里备份：Backup → 勾选 Boot → 备份到外置 SD
# 或者有 root 时：
adb shell su -c 'dd if=/dev/block/bootdevice/by-name/boot of=/sdcard/boot-stock.img'
```

刷入：TWRP → Install → 选 `EEBBK-...zip` → 滑动确认 → Reboot System。

回滚：`fastboot flash boot boot-stock.img`（或 TWRP 还原 Boot）。

---

## 5. 验证

```sh
adb shell uname -r            # 期望 4.4.153-perf（android-p）
adb shell su -c id            # 期望 uid=0(root)
adb shell dmesg | grep -i ksu
```

再装 **KernelSU v0.9.5 的 Manager APK**（版本必须对得上 0.9.5）：
<https://github.com/tiann/KernelSU/releases/tag/v0.9.5>

打开显示 *Working / 已工作* 即成功。

---

## 6. 流水线具体做了什么

`scripts/build.sh` 的顺序：

1. **克隆源码**：`--depth=1 -b <分支>` 拉 kernel（约 1.3 GB）。
2. **工具链**：LineageOS 的 `aarch64-linux-gnu-gcc 9.3`，缓存在 `~/.toolchains`。
3. **集成 KernelSU v0.9.5**（`scripts/apply-ksu.sh`）：
   - `git clone -b v0.9.5` 到 `KernelSU/`（**不用浅克隆**，KSU 版本号靠
     `git rev-list --count` 算，浅克隆会让管理器认为内核版本过低）；
   - `drivers/kernelsu -> ../KernelSU/kernel` 软链；
   - `drivers/Makefile` 加 `obj-$(CONFIG_KSU) += kernelsu/`；
   - `drivers/Kconfig` 最后一个 `endmenu` 前 `source "drivers/kernelsu/Kconfig"`。
4. **手动插 hook**（`scripts/patch-hooks.py`，4.4 的 kprobe 不可靠，走 manual）：

   | 文件 | 函数 | 作用 |
   | --- | --- | --- |
   | `fs/exec.c` | `do_execveat_common` | `su` → `ksud`，KSud 启动流程 |
   | `fs/open.c` | `SYSCALL_DEFINE3(faccessat,...)` | root 检测 |
   | `fs/stat.c` | `vfs_fstatat` | root 检测（stat 系） |
   | `fs/read_write.c` | `vfs_read` | ksud.rc / 模块注入 |
   | `drivers/input/input.c` | `input_handle_event` | 安全模式（开机按音量下不进 KSU） |
   | `fs/devpts/inode.c` | `devpts_get_priv` | `pm` 等命令的 pts 标签 |

   脚本会先扫 KernelSU 源码里**真实存在**的符号再决定插哪版
   （`ksu_handle_execveat` vs `ksu_handle_execveat_ksud`），避免链接期 undefined reference；
   插入是幂等的，重复跑不会插两遍。
5. **改 config**（`scripts/patch-config.py`）——这几个不是随便加的：

   | 开关 | 值 | 原因 |
   | --- | --- | --- |
   | `CONFIG_KSU` | `y` | 必须 built-in。这个树 `CONFIG_MODULE_SIG_FORCE=y`，`.ko` 加载不进来 |
   | `CONFIG_OVERLAY_FS` | `y` | KSU 0.9.5 的 Kconfig 有 `depends on OVERLAY_FS`，不开 KSU 会被**静默丢掉** |
   | `CONFIG_KPROBES` | `n` | 手动 hook 模式必须关；开着会误触安全模式（开机按音量下就进安全模式） |
   | `CONFIG_MODULE_SIG_FORCE` | `n` | 原厂 `wlan.ko` 不是用这次编出的 key 签的，FORCE 开着会全部加载失败 |
   | `CONFIG_DEBUG_INFO` | `n` | 只为缩短编译时间、减小体积；不影响运行行为，也不影响 vermagic |

6. **编译**：`make O=out ARCH=arm64 Image.gz-dtb`（先试 `Image.gz-dtb`，失败退回 `Image.gz`）。
7. **打包**：AnyKernel3，`do.modules=0`（只换 kernel，保留原 ramdisk/cmdline/dtb）。

---

## 7. 出问题看这里

| 现象 | 原因 / 处理 |
| --- | --- |
| Actions 页面没有 workflow | `.github/workflows/build.yml` 没传上去，或目录层级不对 |
| 编译报 `Sorry, your version of GCC is too old` | 工具链没下成功，看日志里 `CC =` 那行 |
| `CONFIG_OVERLAY_FS 没打开` | `.config` 里被覆盖了，把 `config-used.txt` 发我 |
| 编译到一半 `No space left on device` | 磁盘清理步骤没生效，或分支选成了 lineage-18.1 又把模块也编了 |
| 开机卡第一屏 / 无限重启 | 分支选错 / 原厂模块对不上。进 TWRP 刷回备份 boot；能进系统的话按音量下进安全模式 |
| `su` 有 root 但模块不生效 | `vfs_read` hook 没插上，看日志里 `fs/read_write.c` 那行是不是 `ok` |
| Manager 提示版本不支持 | 内核是 0.9.5，Manager 也必须用 0.9.5 的 APK |
| 想重新来一版 | Actions → 同一个 workflow → Run workflow，改分支即可；工具链有缓存，第二次快很多 |

跑挂了别急，把 **run 页面链接**或下载的 `build-log-<分支>` 发我，我按报错改。

---

## 8. 目录结构

```
eebbk-ksu-ci/
├─ .github/workflows/build.yml   # GitHub Actions 流水线
├─ config/eebbk-sdm660.config    # 你给的那份 4.4.153 .config，原样放进来
├─ scripts/
│  ├─ build.sh                   # 主流程：源码 → 工具链 → KSU → 配置 → 编译 → AK3
│  ├─ apply-ksu.sh               # 把 KernelSU 挂进内核树
│  ├─ patch-hooks.py             # 6 处手动 hook（幂等、自适应符号名）
│  └─ patch-config.py            # 改 .config 里的 KSU 相关开关
└─ README.md
```

本地 Linux / WSL2 想手动跑也行：

```bash
BRANCH=android-p KSU=1 bash scripts/build.sh
# 产物在 build/artifacts/
```

---

## 9. 参考

- 内核仓库：<https://github.com/EEBBK-QMUR-Devs/android_kernel_eebbk_sdm660>
- KernelSU 非 GKI 官方集成文档（归档，4.4 的手动 hook 说明仍适用）：
  <https://kernelsu.org/guide/how-to-integrate-for-non-gki.html>
- KernelSU v0.9.5（最后一个支持 non-GKI 的官方版本）：
  <https://github.com/tiann/KernelSU/releases/tag/v0.9.5>
- AnyKernel3：<https://github.com/osm0sis/AnyKernel3>
