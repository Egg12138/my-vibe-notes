# kpatch 源码走读（第 2 段）：build-time 主链路与 section 映射

**主题:** 从 `kpatch-build` 到 `.kpatch.*` / `.klp.*` 的构建流水线
**适用读者:** 已经知道 kpatch 怎么用，想理解中间产物的人
**来源:** `/home/egg/source/kpatch/kpatch-build/kpatch-build`、`/home/egg/source/kpatch/kpatch-build/kpatch-intermediate.h`、`/home/egg/source/kpatch/kpatch-build/create-kpatch-module.c`、`/home/egg/source/kpatch/kpatch-build/create-klp-module.c`

## [toc]

- [这段要学什么](#这段要学什么)
- [一句话理解 build-time](#一句话理解-build-time)
- [kpatch-build 的流水线](#kpatch-build-的流水线)
- [三个关键中间格式](#三个关键中间格式)
- [create-kpatch-module 在做什么](#create-kpatch-module-在做什么)
- [create-klp-module 在做什么](#create-klp-module-在做什么)
- [初学者版理解](#初学者版理解)
- [专家版理解](#专家版理解)
- [下一段该怎么读](#下一段该怎么读)

## 这段要学什么

这段要解决的问题是：**kpatch-build 到底如何把一个源代码 patch 变成补丁模块里可消费的 ELF 元数据。**

如果说第 1 段是在回答“怎么用”，那这一段就是在回答“为什么它能用”。

## 一句话理解 build-time

`kpatch-build` 的本质是：**对原始目标文件和打补丁后的目标文件做二进制级比较，然后抽取出函数替换信息和动态重定位信息，再封装成补丁模块。**

它不是单纯的打包工具，而是一条很重的二进制分析流水线。

## kpatch-build 的流水线

从脚本里的阶段名可以把主链路压成下面几步：

1. 读取内核配置与构建环境
2. 验证 patch 文件是否可接受
3. 构建原始源码树
4. 应用 patch 后再构建一次
5. 找出 changed objects
6. 为 changed objects 重新编译成可分析的 `.o`
7. 调 `create-diff-object` 比较原始和 patched 的对象文件
8. 生成补丁中间对象
9. 链接成最终 patch module

这里最关键的事实是：

- `kpatch-build` 不是把整个内核重编一遍给你看结果
- 它只追踪真正发生变化的对象文件
- 最终产物的核心是“能被内核 livepatch 接受的元数据”

## 三个关键中间格式

### 1. `.kpatch.symbols`

这个 section 记录的是和补丁相关的符号信息。

你可以把它理解成：

- 这个补丁改动了哪些函数
- 这些函数属于哪个 object
- 符号在符号表里的位置是什么

### 2. `.kpatch.relocations`

这个 section 记录的是补丁中的重定位关系。

它回答的问题是：

- 某个新函数代码里引用了什么
- 这个引用应该落到哪一个目标地址
- 这个符号是外部符号还是本地符号

### 3. `.kpatch.arch`

这个 section 用来承载架构相关的特殊段信息，比如：

- `.parainstructions`
- `.altinstructions`

它的作用不是“补代码”，而是给架构特殊重定位留一个可搬运的中间层。

## create-kpatch-module 在做什么

这个工具的输入可以理解成一个“带有 `.kpatch.*` 中间信息的对象文件”。

它主要做三件事：

1. 读取 `.kpatch.symbols` 和 `.kpatch.relocations`
2. 生成运行时需要的 `.kpatch.dynrelas`
3. 清理掉不该直接暴露给后续阶段的中间 section

`kpatch-intermediate.h` 里的结构体可以帮助你建立映射：

- `kpatch_symbol` = 符号元信息
- `kpatch_relocation` = 重定位元信息
- `kpatch_arch` = 架构专用 section 元信息

如果要一句话概括 `create-kpatch-module`：

**它负责把抽象的中间信息转成运行时补丁模块能理解的动态重定位描述。**

## create-klp-module 在做什么

这个工具是给现代 livepatch 路径用的。

它做的事情更像“翻译器”：

1. 读 `.kpatch.symbols` 和 `.kpatch.relocations`
2. 构造 `.klp.sym.*`
3. 构造 `.klp.rela.*`
4. 可选生成 `.klp.arch.*`
5. 删除中间 section
6. 重建符号表、字符串表和 rela 信息

它和 `create-kpatch-module` 的区别可以这样记：

- `create-kpatch-module` 更偏向 kpatch 自己的中间表示
- `create-klp-module` 更偏向内核 livepatch ABI

## 初学者版理解

你可以把这条链路想成一个翻译过程：

```text
源代码 patch
  → 原始/patched .o
  → create-diff-object
  → .kpatch.symbols / .kpatch.relocations
  → create-kpatch-module 或 create-klp-module
  → patch module (.ko)
```

最重要的不是文件名，而是层次：

- 源码层：你写的 patch
- 对象层：编译后的 `.o`
- 元数据层：函数替换与重定位描述
- 模块层：最终可加载的 `.ko`

## 专家版理解

这一段背后的核心设计是：**kpatch 把“补丁逻辑”与“补丁装配”分开了。**

`create-diff-object` 负责识别差异并生成中间元信息；`create-kpatch-module` / `create-klp-module` 负责把这些元信息转成特定 ABI 可消费的输出。

这有两个好处：

- 二进制分析逻辑和最终模块格式解耦
- kpatch 可以在不同内核版本 / 不同 livepatch ABI 下复用前半段逻辑

所以读 build-time 时不要只盯着 shell 脚本。真正值得关注的是：

- changed objects 怎么判断
- 为什么只重编 changed objects
- `.kpatch.*` 如何喂给 `.klp.*`
- 为什么一些架构还要单独处理 `.parainstructions` / `.altinstructions`

## 下一段该怎么读

下一段建议切到运行时链路，顺序是：

1. `kmod/core/kpatch.h`
2. `kmod/core/core.c`
3. `kmod/patch/kpatch-patch-hook.c`
4. `kmod/patch/livepatch-patch-hook.c`
5. `kmod/core/shadow.c`

只抓三个问题：

- 补丁模块加载后，内核怎么知道要改哪些函数
- 函数切换前为什么要做一致性检查
- `.kpatch.dynrelas` / `.klp.rela.*` 在运行时被谁消费

<!-- vibenotes-version: branch main @ 46552a0, 2026-04-13 00:25:56 CST -->
