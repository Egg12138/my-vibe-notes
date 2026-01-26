# kpatch-build 用户指南 (中文版)

**主题:** Linux 内核动态热补丁构建工具完整指南
**日期:** 2025-01-23
**级别:** 中高级 - 内核热补丁用户指南

---

## 概述

`kpatch-build` 是 kpatch 项目的核心构建工具，用于将源代码级别的补丁转换为内核可加载的热补丁模块。本文档详细介绍 `kpatch-build` 的所有命令行选项及其使用方法。

### kpatch 工具链概览

```
源码补丁 (.patch) → kpatch-build → 热补丁模块 (.ko) → kpatch load → 运行时打补丁
```

---

## 目录 (Table of Contents)

- [基本语法](#基本语法)
- [命令行选项详解](#命令行选项详解)
  - [帮助和版本选项](#帮助和版本选项)
  - [内核源码相关选项](#内核源码相关选项)
  - [构建相关选项](#构建相关选项)
  - [输出相关选项](#输出相关选项)
  - [调试选项](#调试选项)
  - [模块补丁选项](#模块补丁选项)
  - [功能控制选项](#功能控制选项)
- [位置参数](#位置参数)
- [使用示例](#使用示例)
- [完整构建流程](#完整构建流程)
- [常见使用场景](#常见使用场景)
- [常见问题](#常见问题)
- [支持的发行版](#支持的发行版)

---

## 基本语法

```bash
kpatch-build [选项] <补丁文件1 ... 补丁文件N>
```

### 最简单的用法

```bash
kpatch-build my-patch.patch
```

这会自动使用当前运行的内核版本信息来构建补丁模块。

---

## 命令行选项详解

### 帮助和版本选项

#### `-h, --help`

**说明:** 显示帮助信息并退出

**示例:**
```bash
kpatch-build --help
```

#### `--version`

**说明:** 显示 kpatch-build 版本号

**示例:**
```bash
kpatch-build --version
# 输出: Version : 0.9.11
```

---

### 内核源码相关选项

#### `-a, --archversion <版本号>`

**说明:** 指定内核架构版本

**详细说明:**
- 用于指定要打补丁的内核版本
- 格式示例: `5.10.0-xyz`, `4.18.0-372.el8`
- 如果不指定，默认使用 `uname -r` 的输出

**不指定时的影响:**
- kpatch-build 会尝试从多个来源自动检测:
  1. vmlinux 文件中的版本字符串
  2. 当前运行的内核版本 (`uname -r`)
  3. 源码 RPM 包名称

**示例:**
```bash
kpatch-build -a 5.10.0-136.el8.x86_64 patch.patch

# 指定 RHEL 内核版本
kpatch-build --archversion 4.18.0-372.el8.x86_64 my-patch.patch

# 指定 Ubuntu 内核版本
kpatch-build -a 5.15.0-72-generic patch.patch
```

#### `-r, --sourcerpm <RPM文件路径>`

**说明:** 指定内核源码 RPM 包

**详细说明:**
- 用于提供内核源码的 RPM 包
- kpatch-build 会自动解压并准备源码
- 与 `--archversion` 选项互斥

**不指定时的影响:**
- 对于 RPM 系发行版 (RHEL/CentOS/Fedora)，kpatch-build 会:
  1. 检查 `~/.kpatch/src` 缓存目录
  2. 尝试从官方仓库下载对应版本的源码 RPM
  3. 使用 yumdownloader/dnf-utils 下载

**示例:**
```bash
# 使用指定的源码 RPM
kpatch-build -r /path/to/kernel-5.10.0-136.el8.src.rpm patch.patch

# 与 --archversion 冲突
kpatch-build -a 5.10.0-136 -r kernel.src.rpm patch.patch  # 错误!
```

#### `-s, --sourcedir <目录路径>`

**说明:** 指定内核源码目录

**详细说明:**
- 直接使用已准备好的内核源码目录
- 目录必须包含完整的内核源码，包括 `.config` 文件
- 这是最快的方式，不需要下载和解压

**不指定时的影响:**
```bash
# 自动查找顺序:
1. 检查 ~/.kpatch/src 缓存
2. 尝试下载源码包 (RPM 系) 或使用 dget (DEB 系)
3. 失败则报错
```

**示例:**
```bash
# 使用父目录作为内核源码
kpatch-build -s .. -v vmlinux patch.patch

# 使用指定路径的源码
kpatch-build --sourcedir /usr/src/kernels/5.10.0-136.el8.x86_64 patch.patch

# 指定 vmlinux 位置（源码目录中的 vmlinux）
kpatch-build -s /path/to/kernel/src -v vmlinux patch.patch
```

#### `-c, --config <配置文件路径>`

**说明:** 指定内核配置文件

**详细说明:**
- 指定要使用的内核配置文件 (`.config`)
- 配置文件会被复制到内核源码目录
- 必须启用了 `CONFIG_DEBUG_INFO` 和 `CONFIG_LIVEPATCH`

**不指定时的影响:**
```bash
# 自动查找顺序:
# RPM 系:
1. /boot/config-$(uname -r)
2. kernel源码目录/configs/kernel-<version>-<arch>.config

# DEB 系:
1. /boot/config-$(uname -r)

# 树外模块:
1. /boot/config-$(modinfo -F vermagic module.ko)
```

**示例:**
```bash
kpatch-build -c /boot/config-5.10.0-136.el8.x86_64 patch.patch

# 使用自定义配置
kpatch-build --config /path/to/custom.config patch.patch
```

#### `-v, --vmlinux <vmlinux文件路径>`

**说明:** 指定原始 vmlinux 文件

**详细说明:**
- vmlinux 是未压缩的内核可执行文件，包含完整调试符号
- 这是 kpatch-build 工作的核心依赖
- 必须与目标内核版本完全匹配

**不指定时的影响:**
```bash
# 自动查找顺序:
# RPM 系 (RHEL/CentOS/Fedora):
/usr/lib/debug/lib/modules/$(uname -r)/vmlinux

# DEB 系:
# Ubuntu:
/usr/lib/debug/boot/vmlinux-$(uname -r)
# Debian:
/usr/lib/debug/boot/vmlinux-$(uname -r)
```

**示例:**
```bash
# 使用当前目录的 vmlinux
kpatch-build -v . patch.patch

# 指定完整路径
kpatch-build --vmlinux /usr/lib/debug/lib/modules/5.10.0-136.el8.x86_64/vmlinux patch.patch

# 与源码目录配合使用
kpatch-build -s .. -v vmlinux patch.patch
```

---

### 构建相关选项

#### `-j, --jobs <数字>`

**说明:** 指定 make 并行任务数

**详细说明:**
- 控制 `make` 命令的并行编译任务数
- 默认值为 CPU 核心数 (`getconf _NPROCESSORS_ONLN`)
- 增加数值可以加快编译速度，但消耗更多内存

**不指定时的影响:**
```bash
# 默认使用 CPU 核心数
# 例如 8 核 CPU 等价于: make -j8
```

**示例:**
```bash
# 使用 4 个并行任务
kpatch-build -j 4 patch.patch

# 单线程编译 (调试时有用)
kpatch-build --jobs 1 patch.patch

# 最大并行 (适合高性能服务器)
kpatch-build -j 16 patch.patch
```

#### `-t, --target <目标名称>`

**说明:** 指定自定义内核构建目标

**详细说明:**
- 覆盖默认的内核构建目标
- 默认值为: `vmlinux modules`
- 可以多次指定以添加多个目标

**不指定时的影响:**
```bash
# 等价于: make vmlinux modules
```

**示例:**
```bash
# 只构建特定模块
kpatch-build -t fs/proc/proc.o patch.patch

# 构建多个目标
kpatch-build -t vmlinux -t modules patch.patch

# 树外模块示例
kpatch-build --target default --oot-module-src ~/test/ patch.patch
```

---

### 输出相关选项

#### `-n, --name <模块名称>`

**说明:** 指定 kpatch 模块名称

**详细说明:**
- 设置最终生成的 `.ko` 模块名称
- 名称会自动添加前缀:
  - 使用 KLP (内核原生 livepatch): `livepatch-<name>`
  - 使用旧版 kpatch: `kpatch-<name>`
- 名称会被截断到 55 个字符
- 只允许字母、数字、下划线和连字符

**不指定时的影响:**
```bash
# 单个补丁文件: 使用补丁文件名
# 例如: kpatch-build bugfix.patch → kpatch-bugfix.ko

# 多个补丁文件: 使用 "patch" 作为名称
# 例如: kpatch-build p1.patch p2.patch → kpatch-patch.ko
```

**示例:**
```bash
# 指定模块名称
kpatch-build -n my-hotfix patch.patch
# 输出: livepatch-my-hotfix.ko

# 使用描述性名称
kpatch-build --name cve-2023-1234-fix security-patch.patch
```

#### `-o, --output <目录路径>`

**说明:** 指定输出文件夹

**详细说明:**
- 设置最终 `.ko` 文件的输出目录
- 默认为当前工作目录

**不指定时的影响:**
```bash
# 输出到当前目录
# 最终文件: ./livepatch-xxx.ko
```

**示例:**
```bash
# 输出到指定目录
kpatch-build -o /tmp/kpatch-output patch.patch

# 输出到用户主目录
kpatch-build --output ~/kpatches patch.patch
```

---

### 调试选项

#### `-d, --debug`

**说明:** 启用 xtrace 并保留临时文件

**详细说明:**
- 启用 bash xtrace 模式，打印每条执行的命令
- 临时文件保留在 `$CACHEDIR/tmp` (默认 `~/.kpatch/tmp`)
- 可以多次指定以增加调试级别:
  - `-d`: 调试级别 1，启用 xtrace，构建后删除临时文件
  - `-dd`: 调试级别 2，额外输出到 stdout
  - `-ddd`: 调试级别 3，xtrace 持续启用
  * `-dddd`: 调试级别 4，启用 kpatch-gcc 调试

**不指定时的影响:**
```bash
# 构建完成后自动删除临时文件
# 只记录日志到 ~/.kpatch/build.log
```

**示例:**
```bash
# 基本调试
kpatch-build -d patch.patch

# 详细调试 (输出到 stdout)
kpatch-build -d -d patch.patch

# 最详细调试
kpatch-build -d -d -d -d patch.patch

# 调试后检查临时文件
ls ~/.kpatch/tmp/
```

---

### 模块补丁选项

#### `--oot-module <.ko文件路径>`

**说明:** 启用树外 (Out-of-Tree) 模块补丁，指定当前运行的模块版本

**详细说明:**
- 用于补丁第三方内核模块，非内核树内模块
- 必须配合 `--oot-module-src` 使用
- 参数是当前加载的 `.ko` 文件路径

**不指定时的影响:**
```bash
# 默认只补丁内核树内代码 (vmlinux)
```

**示例:**
```bash
# 补丁树外模块
kpatch-build \
  --oot-module /lib/modules/$(uname -r)/extra/test.ko \
  --oot-module-src ~/test-module-src/ \
  test.patch

# 获取模块信息
modinfo -F vermagic /lib/modules/$(uname -r)/extra/test.ko
```

#### `--oot-module-src <目录路径>`

**说明:** 指定树外模块源码目录

**详细说明:**
- 树外模块的源代码目录
- 必须包含模块的 Makefile 和源码
- 与 `--oot-module` 配合使用

**不指定时的影响:**
```bash
# 如果指定了 --oot-module 但没指定此选项，会报错:
# ERROR: --oot-module requires --oot-module-src
```

**示例:**
```bash
kpatch-build \
  --oot-module /lib/modules/5.10.0-136.el8.x86_64/extra/nvidia.ko \
  --oot-module-src /usr/src/nvidia-515.65.01/ \
  nvidia-fix.patch
```

---

### 功能控制选项

#### `-R, --non-replace`

**说明:** 禁用 KLP replace 标志 (默认启用 replace)

**详细说明:**
- 控制补丁模块的替换行为
- **默认 (replace 模式):** 新补丁会完全替换旧补丁
- **non-replace 模式:** 多个补丁可以同时生效，叠加工作

**不指定时的影响:**
```bash
# 默认启用 replace 模式 (内核 5.1+)
# insmod patch1.ko
# insmod patch2.ko  # patch1 被 replace，不再生效
```

**示例:**
```bash
# 禁用 replace，补丁可以叠加
kpatch-build --non-replace patch.patch

# 加载行为:
# insmod patch1.ko
# insmod patch2.ko  # patch1 和 patch2 同时生效
```

**内核版本要求:**
- RHEL: 4.18.0-193.el8+
- 上游内核: 5.1.0+

#### `--skip-cleanup`

**说明:** 跳过构建后清理

**详细说明:**
- 构建完成后保留所有临时文件
- 相当于自动设置了 `-d` 但不会删除文件
- 便于调试和检查中间结果

**不指定时的影响:**
```bash
# 构建完成后自动清理:
# - 删除 $TEMPDIR 临时文件
# - 删除 $RPMTOPDIR 构建目录
# - 恢复内核源码的修改
```

**示例:**
```bash
kpatch-build --skip-cleanup patch.patch

# 检查构建产物:
ls ~/.kpatch/tmp/
ls ~/.kpatch/buildroot/
```

#### `--skip-compiler-check`

**说明:** 跳过编译器版本匹配检查 (不推荐)

**详细说明:**
- kpatch-build 默认严格检查当前编译器版本与编译内核时使用的版本
- 使用不同版本的编译器可能导致:
  - 结构体对齐差异
  - 内联函数展开不同
  - 符号版本不匹配
  - 补丁无法加载或系统崩溃

**不指定时的影响:**
```bash
# 默认行为: 严格检查
# 如果版本不匹配:
# ERROR: gcc/kernel version mismatch
# gcc version:    GCC: (GNU) 11.3.0
# kernel version: GCC: (GNU) 10.3.0
```

**示例:**
```bash
# 跳过检查 (不推荐!)
kpatch-build --skip-compiler-check patch.patch

# 推荐做法: 安装匹配的编译器版本
# CentOS/RHEL:
yum install gcc-$(uname -r | sed 's/\.el.*//')

# Ubuntu:
apt install gcc-$(uname -r | cut -d- -f1)
```

**警告:** 此选项可能导致补丁不兼容，仅在充分理解风险时使用。

#### `--skip-gcc-check`

**说明:** 已弃用，使用 `--skip-compiler-check` 替代

**示例:**
```bash
# 旧版用法 (已弃用)
kpatch-build --skip-gcc-check patch.patch

# 新版用法
kpatch-build --skip-compiler-check patch.patch
```

---

## 位置参数

### 补丁文件

**说明:** 输入的补丁文件 (支持多个)

**格式:** 标准 unified diff 格式 (.patch 或 .diff)

**示例:**
```bash
# 单个补丁
kpatch-build bugfix.patch

# 多个补丁 (会按顺序应用)
kpatch-build 001-fix.patch 002-enhance.patch 003-refactor.patch

# 使用 git 生成的补丁
git format-patch -1
kpatch-build 0001-my-fix.patch
```

---

## 使用示例

### 基础示例

#### 1. 最简单的用法 (使用当前内核)

```bash
kpatch-build my-fix.patch
# 输出: livepatch-my-fix.ko
```

#### 2. 指定内核源码和 vmlinux

```bash
kpatch-build -s .. -v vmlinux my-fix.patch
```

#### 3. 为特定内核版本构建

```bash
# RHEL/CentOS
kpatch-build -a 5.10.0-136.el8.x86_64 my-fix.patch

# Ubuntu
kpatch-build -a 5.15.0-72-generic my-fix.patch
```

### 高级示例

#### 1. 完整指定所有参数

```bash
kpatch-build \
  --sourcedir /usr/src/kernels/5.10.0-136.el8.x86_64 \
  --vmlinux /usr/lib/debug/lib/modules/5.10.0-136.el8.x86_64/vmlinux \
  --config /boot/config-5.10.0-136.el8.x86_64 \
  --name security-fix \
  --output /tmp/kpatches \
  --jobs 8 \
  my-security-fix.patch
```

#### 2. 树外模块补丁

```bash
kpatch-build \
  --oot-module /lib/modules/$(uname -r)/extra/my-driver.ko \
  --oot-module-src ~/src/my-driver/ \
  --target default \
  driver-fix.patch
```

#### 3. 调试模式构建

```bash
kpatch-build -d -d -d patch.patch
# 检查日志
cat ~/.kpatch/build.log
# 检查临时文件
ls ~/.kpatch/tmp/
```

#### 4. 跳过编译器检查 (不推荐)

```bash
# 当无法获得匹配的编译器版本时
kpatch-build --skip-compiler-check patch.patch
```

#### 5. 非 replace 模式 (补丁叠加)

```bash
kpatch-build --non-replace feature-a.patch
kpatch-build --non-replace feature-b.patch

# 加载后两者同时生效
sudo insmod livepatch-feature-a.ko
sudo insmod livepatch-feature-b.ko
```

---

## 完整构建流程

### kpatch-build 工作流程

```
┌─────────────────────────────────────────────────────────────┐
│ 1. 初始化阶段                                                │
│    - 解析命令行参数                                          │
│    - 检查依赖工具 (gcc, cpio, awk, etc.)                    │
│    - 设置缓存目录 (~/.kpatch)                               │
└─────────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────┐
│ 2. 环境准备阶段                                              │
│    - 验证内核源码目录                                        │
│    - 验证 vmlinux 文件                                       │
│    - 解析内核版本                                            │
└─────────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────┐
│ 3. 补丁解析阶段                                              │
│    - 解析 patch 文件格式                                     │
│    - 识别修改的文件和函数                                    │
│    - 构建补丁元数据                                          │
└─────────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────┐
│ 4. 符号解析阶段                                              │
│    - 读取 vmlinux 符号表                                     │
│    - 提取 DWARF 调试信息                                    │
│    - 生成 klp.sym 表                                         │
└─────────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────┐
│ 5. 编译原始内核                                              │
│    - 编译未打补丁的内核                                      │
│    - 保存原始 .o 文件                                        │
└─────────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────┐
│ 6. 应用补丁并编译                                            │
│    - 应用补丁到源码                                          │
│    - 编译打补丁后的内核                                      │
│    - 识别变化的 .o 文件                                      │
└─────────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────┐
│ 7. 差异分析 (create-diff-object)                            │
│    - 比较原始和补丁的 .o 文件                                │
│    - 提取变化的函数和数据                                    │
│    - 生成元数据                                              │
└─────────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────┐
│ 8. 后处理和链接                                              │
│    - 链接所有补丁对象                                        │
│    - KLP 转换 (klp-convert)                                 │
│    - 生成最终 .ko 模块                                       │
└─────────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────┐
│ 9. 输出                                                      │
│    - livepatch-xxx.ko 或 kpatch-xxx.ko                     │
│    - 清理临时文件 (除非使用 --skip-cleanup)                 │
└─────────────────────────────────────────────────────────────┘
```

---

## 常见使用场景

### 场景 1: 开发环境内核补丁

```bash
# 在内核源码树的父目录构建
cd /usr/src/linux-5.10.0/
kpatch-build -s . -v vmlinux my-fix.patch
```

### 场景 2: 生产环境内核补丁

```bash
# 使用调试信息包
kpatch-build \
  -a 5.10.0-136.el8.x86_64 \
  my-fix.patch

# 需要提前安装:
# yum install kernel-debuginfo-5.10.0-136.el8.x86_64
```

### 场景 3: 多个补丁组合

```bash
# 将多个补丁合并为一个模块
kpatch-build \
  -n combined-fixes \
  patch1.patch patch2.patch patch3.patch
```

### 场景 4: 交叉编译

```bash
# 为不同架构编译
export CROSS_COMPILE=aarch64-linux-gnu-
kpatch-build \
  -s /path/to/arm64/src \
  -v /path/to/arm64/vmlinux \
  patch.patch
```

---

## 常见问题

### Q1: 为什么需要 vmlinux?

**A:** vmlinux 包含:
- 完整的符号表 (函数地址、变量地址)
- DWARF 调试信息 (类型定义、结构体布局)
- 函数大小和位置信息

没有 vmlinux，kpatch 无法知道要替换哪些函数。

### Q2: 编译器版本不匹配怎么办?

**A:** 三种解决方案:

1. **推荐:** 安装匹配的编译器
```bash
# CentOS/RHEL
yum install gcc-$(uname -r | sed 's/\.el.*//')

# Ubuntu
apt install gcc-$(uname -r | cut -d- -f1)
```

2. **不推荐:** 跳过检查
```bash
kpatch-build --skip-compiler-check patch.patch
```

3. **最佳:** 使用内核源码目录
```bash
kpatch-build -s /path/to/kernel/src -v vmlinux patch.patch
```

### Q3: 如何找到 vmlinux?

**A:**
```bash
# RPM 系
/usr/lib/debug/lib/modules/$(uname -r)/vmlinux

# DEB 系
/usr/lib/debug/boot/vmlinux-$(uname -r)

# 从源码编译
# 在内核源码目录
ls -l vmlinux
```

### Q4: replace 和 non-replace 模式的区别?

**A:**

| 模式 | 行为 | 用途 |
|------|------|------|
| replace (默认) | 新补丁替换旧补丁 | 功能更新、bug 修复 |
| non-replace | 补丁可以叠加 | 独立功能、测试场景 |

### Q5: 临时文件在哪里?

**A:**
```bash
# 缓存目录
~/.kpatch/

# 临时构建文件
~/.kpatch/tmp/

# 构建日志
~/.kpatch/build.log
```

### Q6: 如何清理缓存?

**A:**
```bash
# 清理所有缓存
rm -rf ~/.kpatch/*

# 或者使用 kpatch-build 重建时自动清理
```

---

## 支持的发行版

### RPM 系

| 发行版 | 支持状态 |
|--------|---------|
| Fedora | ✓ |
| RHEL / CentOS / Rocky / AlmaLinux | ✓ |
| Oracle Linux | ✓ |
| OpenEuler | ✓ |
| OpenCloudOS | ✓ |
| Amazon Linux | ✓ |
| Photon OS | ✓ |

### DEB 系

| 发行版 | 支持状态 |
|--------|---------|
| Ubuntu | ✓ |
| Debian | ✓ |

### 其他

| 发行版 | 支持状态 |
|--------|---------|
| Gentoo | ✓ |

---

## 相关文档

- **create-diff-object 工作流程:** `create-diff-object-workflow.md`
- **kpatch README:** `linux/kernel/subsystems/kpatch-README.md`
- **Livepatch 子系统:** `linux/kernel/subsystems/livepatch.md`
- **QEMU 端到端示例:** `qemu-end-to-end-example.md`

---

## 参考资料

- **项目主页:** https://github.com/dynup/kpatch
- **内核文档:** Documentation/livepatch/
- **补丁作者指南:** kpatch/doc/patch-author-guide.md

---

<!--
Source: kpatch git repository
Version: v0.9.11-23-g8a927e7
Date: 2026-01-23
-->
