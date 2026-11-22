# 给 EEBBK H7000（sdm660 / 4.4.302）加 KernelSU 并编译

- 内核仓库：<https://github.com/EEBBK-QMUR-Devs/android_kernel_eebbk_sdm660>
- 分支：`lineage-18.1`，内核 **4.4.302**（non-GKI）
- 设备树：`EEBBK-QMUR-Devs/android_device_eebbk_H7000`（`TARGET_BOARD_PLATFORM := sdm660`）
- 设备实际 defconfig：`vendor/sdm660-perf_defconfig` → 内容只有一行 `../sdm660-perf_defconfig`
  → 真正要改的是 **`arch/arm64/configs/sdm660-perf_defconfig`**

---

## 0. 先搞清楚三件事

1. **这是非 GKI 内核。** 官方 KernelSU 从 **v1.0 起不再支持 non-GKI**，4.4 能用的最后一个官方版本是 **v0.9.5**。
   想更新一点可以用社区分支 **SukiSU-Ultra**（官方说 4.4+ 也支持，但要手动 hook）。
2. **KSU 只能 built-in（`=y`）。** 这个 defconfig 开了 `CONFIG_MODULE_SIG_FORCE=y`，编成 `.ko` 加载不了；
   而且 4.4 没有 GKI 的 LKM 方案。
3. **先能编出一个能开机的原版内核，再加 KSU。** 否则出问题分不清是 KSU 还是编译/打包的锅。

---

## 1. 方案 A：KernelSU v0.9.5 + kprobe（推荐先试，改动最少）

### 1.1 把 KernelSU 放进内核树

在**内核根目录**执行：

```sh
curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/v0.9.5/kernel/setup.sh" | bash -s v0.9.5
```

它会：

- 把 KernelSU clone 到 `KernelSU/`
- 建软链接 `drivers/kernelsu -> ../KernelSU/kernel`
- 在 `drivers/Makefile` 追加 `obj-$(CONFIG_KSU) += kernelsu/`
- 在 `drivers/Kconfig` 的 `endmenu` 前加 `source "drivers/kernelsu/Kconfig"`

> 不想用脚本就手动做上面四步，效果一样。

### 1.2 改 defconfig

编辑 `arch/arm64/configs/sdm660-perf_defconfig`，在文件末尾加：

```text
# KernelSU
CONFIG_KSU=y
CONFIG_OVERLAY_FS=y
CONFIG_KPROBES=y
CONFIG_KPROBE_EVENTS=y
```

要点：

- `CONFIG_OVERLAY_FS=y` **必须有**。v0.9.5 的 `CONFIG_KSU` 依赖 `OVERLAY_FS`，没有它 KSU 会被 kconfig 静默丢掉。
- `CONFIG_HAVE_KPROBES` 是 arm64 架构 `select` 的，不要手写；如果 `KPROBES` 还是开不了，先确认 `CONFIG_MODULES=y`（这个 defconfig 已经是 y）。
- 不要写 `CONFIG_KSU=m`。

确认配置真的生效：

```sh
# 单独编（O=out）：
grep -E 'CONFIG_(KSU|OVERLAY_FS|KPROBES)=' out/.config
# 在 LineageOS 树里编：
grep -E 'CONFIG_(KSU|OVERLAY_FS|KPROBES)=' out/target/product/H7000/obj/KERNEL_OBJ/.config
```

### 1.3 编译（见第 2 节）

### 1.4 如果开机卡第一屏 / 无限重启

说明这个 4.4 内核的 kprobe 不可靠（官方文档也提示 4.8 以前的内核 kprobe 可能有问题）。
两条路：

- **A2：改用手动 hook**（见 1.5，KernelSU 0.9.5 专用写法）；
- 或换 **SukiSU-Ultra builtin**（见第 3 节），它的 hook 接口就是为手动插桩设计的。

先确认不是别的原因：把 `CONFIG_KSU` 关掉编一版，确认内核本身能正常开机，再回来折腾 KSU。

### 1.5 A2：手动 hook（KernelSU 0.9.5 专用）

> 官方 non-GKI 文档里的手动 patch 是给 1.0 之前另一个中间版本的，用的是 5 参数的
> `ksu_handle_execveat()`——**v0.9.5 里没有这个函数**。
> v0.9.5 实际导出的是下面这些（来自 `kernel/sucompat.c`、`kernel/ksud.c`）。

先把 `CONFIG_KPROBES` 关掉（手动 hook 模式下必须关，否则会重复 hook，且可能误触发安全模式）：

```text
# CONFIG_KPROBES is not set
```

#### (1) `fs/exec.c` —— `do_execveat_common()`

在函数体最前面插入：

```c
#ifdef CONFIG_KSU
	{
		extern int ksu_handle_execveat_sucompat(int *fd,
				struct filename **filename_ptr,
				void *argv, void *envp, int *flags);
		extern int ksu_handle_execveat_ksud(int *fd,
				struct filename **filename_ptr,
				void *argv, void *envp, int *flags);

		ksu_handle_execveat_sucompat(&fd, &filename, NULL, NULL, NULL);
		ksu_handle_execveat_ksud(&fd, &filename, &argv, &envp, &flags);
	}
#endif
```

- `ksu_handle_execveat_sucompat()` 负责 `su` → `ksud` 的替换（root）。
- `ksu_handle_execveat_ksud()` 负责 init second stage 的 SELinux 规则、`app_process` 触发 post-fs-data；
  **不加它模块和 ksud 的启动流程会不完整。**

#### (2) `fs/open.c` —— `SYSCALL_DEFINE3(faccessat, ...)`

在函数体最前面插入：

```c
#ifdef CONFIG_KSU
	{
		extern int ksu_handle_faccessat(int *dfd,
				const char __user **filename_user,
				int *mode, int *flags);
		ksu_handle_faccessat(&dfd, &filename, &mode, NULL);
	}
#endif
```

> 如果你的树里 4.4 已经 backport 了 `do_faccessat()`，就放到 `do_faccessat()` 开头。

#### (3) `fs/stat.c` —— `SYSCALL_DEFINE4(newfstatat, ...)`

```c
#ifdef CONFIG_KSU
	{
		extern int ksu_handle_stat(int *dfd,
				const char __user **filename_user,
				int *flags);
		ksu_handle_stat(&dfd, &filename, &flag);
	}
#endif
```

需要支持 32 位 su 的话，`SYSCALL_DEFINE4(fstatat64, ...)` 里也加一份。

#### (4) `fs/read_write.c` —— `vfs_read()`（模块 ksud.rc 注入用）

```c
#ifdef CONFIG_KSU
	{
		extern bool ksu_vfs_read_hook;
		extern int ksu_handle_vfs_read(struct file **file_ptr,
				char __user **buf_ptr, size_t *count_ptr,
				loff_t **pos);
		if (unlikely(ksu_vfs_read_hook))
			ksu_handle_vfs_read(&file, &buf, &count, &pos);
	}
#endif
```

#### (5) `drivers/input/input.c` —— `input_handle_event()`（安全模式，建议）

```c
#ifdef CONFIG_KSU
	{
		extern bool ksu_input_hook;
		extern int ksu_handle_input_handle_event(unsigned int *type,
				unsigned int *code, int *value);
		if (unlikely(ksu_input_hook))
			ksu_handle_input_handle_event(&type, &code, &value);
	}
#endif
```

#### (6) `fs/devpts/inode.c` —— `devpts_get_priv()`（`pm` 等命令的 pts 标签，可选）

```c
#ifdef CONFIG_KSU
	{
		extern int ksu_handle_devpts(struct inode *);
		ksu_handle_devpts(dentry->d_inode);
	}
#endif
```

#### (7) 模块卸载（可选）

4.4 没有 `path_umount`，KSU 的“卸载模块”功能需要把 5.9 的 `path_umount()` backport 到 `fs/namespace.c`；
不 backport 只是这个功能不可用，不影响 root。

---

## 2. 编译

### 2.1 方式一：在 LineageOS 18.1 源码树里编（推荐，自动打包 boot.img）

设备树现在是**用预编译内核**的：

```make
# device/eebbk/H7000/BoardConfig.mk
TARGET_KERNEL_SOURCE := $(DEVICE_PATH)/prebuilts/kernel-headers
TARGET_KERNEL_CONFIG := vendor/sdm660-perf_defconfig
TARGET_FORCE_PREBUILT_KERNEL := true
```

改成从源码编：

```make
TARGET_KERNEL_SOURCE := kernel/eebbk/sdm660
TARGET_KERNEL_CONFIG := sdm660-perf_defconfig
TARGET_FORCE_PREBUILT_KERNEL := false
```

> 注意这里把 `vendor/sdm660-perf_defconfig` 改成了 `sdm660-perf_defconfig`：
> 那个 vendor 文件只有一行 `../sdm660-perf_defconfig`，kbuild 不认这种“包含”，
> 设备之前又一直用 prebuilt，所以它大概率从来没被真正用来编过内核。

把内核放进树里：

```sh
mkdir -p kernel/eebbk
git clone -b lineage-18.1 https://github.com/EEBBK-QMUR-Devs/android_kernel_eebbk_sdm660.git kernel/eebbk/sdm660
# 进内核目录做第 1 节的 KSU 修改
```

编译：

```sh
source build/envsetup.sh
lunch lineage_H7000-userdebug
m bootimage -j"$(nproc)"
```

产物：`out/target/product/H7000/boot.img`

**必须用 clang（或 GCC ≥ 5.1）。** 这个树的 `include/linux/compiler-gcc.h` 有一条 arm64 检查：

```c
#elif defined(CONFIG_ARM64) && GCC_VERSION < 50100 && !defined(__clang__)
# error Sorry, your version of GCC is too old - please use 5.1 or newer.
#endif
```

GCC 4.9 在 arm64 上有已知 miscompile 问题，所以被这行直接拒绝；GCC 4.9 只保留用来提供 `as`/`ld`。
在 `BoardConfig.mk` 里加：

```make
TARGET_KERNEL_CLANG_COMPILE := true
TARGET_KERNEL_CLANG_VERSION := clang-r383902b
```

> 版本号以你源码树 `prebuilts/clang/host/linux-x86/` 下实际存在的目录为准。

### 2.2 方式二：单独编内核

没有 LineageOS 源码树也可以。GCC 4.9 工具链只当 binutils 用，真正编译用 clang：

```sh
# 1) binutils / as / ld（GCC 4.9 工具链，约几百 MB）
git clone --depth 1 -b lineage-18.1 \
  https://github.com/LineageOS/android_prebuilts_gcc_linux-x86_aarch64_aarch64-linux-android-4.9.git \
  toolchain
toolchain/bin/aarch64-linux-android-gcc --version   # 能打印版本即可

# 2) clang 11（Ubuntu 20.04/22.04 可直接装；没有 clang-11 就装 clang，或下载 clang-r383902b）
sudo apt install -y clang-11
clang-11 --version
```

编译：

```sh
cd /path/to/android_kernel_eebbk_sdm660  # 内核根目录

export ARCH=arm64
export SUBARCH=arm64
export CROSS_COMPILE=$PWD/toolchain/bin/aarch64-linux-android-
export CC=clang-11

rm -rf out

# 生成 .config
make O=out ARCH=arm64 CC="$CC" CLANG_TRIPLE=aarch64-linux-gnu- \
     CROSS_COMPILE="$CROSS_COMPILE" sdm660-perf_defconfig

# 编译（Ubuntu 22.04 的 host gcc 10+ 需要 -fcommon，否则 dtc 会报 yylloc 重复定义）
make O=out ARCH=arm64 CC="$CC" CLANG_TRIPLE=aarch64-linux-gnu- \
     CROSS_COMPILE="$CROSS_COMPILE" HOSTCFLAGS="-fcommon" -j"$(nproc)"
```

> 只想先换内核、不重编模块，可以把最后的 `-j"$(nproc)"` 目标改成 `Image.gz-dtb -j"$(nproc)"`，
> 这样会跳过模块签名，快不少；设备树里现有的预编译模块一般还能继续用（内核版本号没变）。

**clang 装不上时的备选：GCC 9（≥ 5.1 即可）**

```sh
sudo apt install -y gcc-9-aarch64-linux-gnu

export CROSS_COMPILE=aarch64-linux-gnu-
export CC=aarch64-linux-gnu-gcc-9

rm -rf out
make O=out ARCH=arm64 CC="$CC" CROSS_COMPILE="$CROSS_COMPILE" sdm660-perf_defconfig
make O=out ARCH=arm64 CC="$CC" CROSS_COMPILE="$CROSS_COMPILE" HOSTCFLAGS="-fcommon" -j"$(nproc)"
```

产物：`out/arch/arm64/boot/Image.gz-dtb`
（defconfig 开了 `CONFIG_BUILD_ARM64_APPENDED_DTB_IMAGE=y`，dtb 已经拼进 Image.gz）

**确认 KSU 编进去了：**

```sh
grep -E 'CONFIG_(KSU|OVERLAY_FS)=' out/.config
nm out/vmlinux | grep -i ' ksu_' | head
```

### 2.3 打包 boot.img

最稳的办法：拿设备原来的 boot.img 当模板，只换 kernel。

用 AOSP 的 `unpack_bootimg` 解出 ramdisk 和 cmdline（文件名为准），然后：

```sh
mkbootimg \
  --kernel out/arch/arm64/boot/Image.gz-dtb \
  --ramdisk <原 ramdisk> \
  --cmdline "<原 cmdline>" \
  --base 0x00000000 \
  --pagesize 4096 \
  --header_version 1 \
  --output boot.img
```

这些参数来自设备树：

- `BOARD_KERNEL_BASE := 0x00000000`
- `BOARD_KERNEL_PAGESIZE := 4096`
- `BOARD_BOOTIMG_HEADER_VERSION := 1`
- `BOARD_KERNEL_IMAGE_NAME := Image.gz-dtb`

更省事就用 2.1 的 `m bootimage`，LineageOS 会按 BoardConfig 自动打包。

---

## 3. 方案 B：SukiSU-Ultra（builtin 分支，较新）

适合“kprobe 不行、又想要维护活跃的分支”的情况。

```sh
curl -LSs "https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/main/kernel/setup.sh" | bash -s builtin
```

defconfig 加：

```text
CONFIG_KSU=y
```

然后按官方文档 <https://sukisu.org/guide/how-to-integrate> 的 **builtin** 章节插桩。

**重要提醒：以分支里的头文件为准。** 我们看 `builtin` 分支当前代码：

- `kernel/feature/sucompat.h` 导出的是 `ksu_handle_execveat_sucompat()`，**没有**文档里写的 `ksu_handle_execveat()`；
- 4.4 对应文档里的 “3.19+ via `do_execveat_common`” 和 “4.14 and older” 的 `sys_faccessat` 写法；
- `CONFIG_KSU_SUSFS` 在 4.4 上会自动不满足依赖（它依赖 `THREAD_INFO_IN_TASK`），想要 SUSFS 得另外 backport。

所以 SukiSU 这条路建议先按文档插 4 个基础 hook（execve / faccessat / newfstatat / reboot），
编不过就对照 `kernel/feature/*.h`、`kernel/runtime/ksud.h` 改函数名和参数。

---

## 4. 刷入与验证

```sh
adb reboot bootloader
fastboot flash boot boot.img
fastboot reboot
```

如果设备有 AVB/verity 校验，还要（有 vbmeta 分区时）：

```sh
fastboot --disable-verity --disable-verification flash vbmeta vbmeta.img
```

验证：

```sh
adb shell su -c id          # 应该输出 uid=0(root)
adb shell dmesg | grep -i -E 'kernelsu|ksu'
```

再装对应版本的 Manager：

- KernelSU v0.9.5：<https://github.com/tiann/KernelSU/releases/tag/v0.9.5>
- SukiSU：<https://github.com/SukiSU-Ultra/SukiSU-Ultra/releases>

Manager 打开后显示“已工作 / Working”即成功。

> 这个设备树的 `BOARD_KERNEL_CMDLINE` 里已经有 `androidboot.selinux=permissive`，
> 对 KSU 来说环境比较宽松。

---

## 5. 常见问题

| 现象 | 原因 / 处理 |
| --- | --- |
| `.../toolchain/bin/aarch64-linux-android-gcc: No such file or directory` | 工具链没克隆成功或不在那个路径；`ls toolchain/bin/aarch64-linux-android-gcc` 确认，没有就重克隆，并先跑一次 `--version` |
| 编完 `out/.config` 里没有 `CONFIG_KSU` | 没加 `CONFIG_OVERLAY_FS=y`（0.9.5 的依赖），或 `drivers/kernelsu` 软链接/`drivers/Kconfig` 没加成功 |
| 开机卡第一屏、反复重启 | 4.4 的 kprobe 不可靠 → 改手动 hook（1.5）或换 SukiSU builtin |
| `undefined reference to ksu_*` | 手动 hook 函数名/参数和当前 KSU 分支对不上，去 `KernelSU/kernel/*.c` 里搜实际函数名 |
| Manager 提示版本不支持 | 内核是 0.9.5，Manager 也要用 0.9.5 的 APK |
| `Sorry, your version of GCC is too old - please use 5.1 or newer` | 这个树在 arm64 上禁用了 GCC < 5.1；改用 clang 11，或 GCC 9 |
| clang 编 4.4 报一堆错 | 用 clang 11（r383902b），别用 clang 17+ |
| `multiple definition of 'yylloc'` | 新版 host gcc 默认 `-fno-common`，编译时加 `HOSTCFLAGS="-fcommon"` |
| `su` 能拿到 root，但模块不生效 | 手动 hook 少了 `ksu_handle_execveat_ksud` / `ksu_handle_vfs_read`，ksud.rc 没注入 |
| “卸载模块”不可用 | 4.4 缺 `path_umount`，需要从 5.9 backport 到 `fs/namespace.c` |

---

## 6. 参考

- KernelSU 非 GKI 集成（已归档，但 4.4 的 kprobe/手动 hook 说明仍适用）：
  <https://kernelsu.org/guide/how-to-integrate-for-non-gki>
- KernelSU v0.9.5 源码：
  <https://github.com/tiann/KernelSU/tree/v0.9.5/kernel>
- SukiSU-Ultra 集成文档：
  <https://sukisu.org/guide/how-to-integrate>
- 本内核仓库：
  <https://github.com/EEBBK-QMUR-Devs/android_kernel_eebbk_sdm660>
- 设备树（BoardConfig 里的内核/打包参数）：
  <https://github.com/EEBBK-QMUR-Devs/android_device_eebbk_H7000>
