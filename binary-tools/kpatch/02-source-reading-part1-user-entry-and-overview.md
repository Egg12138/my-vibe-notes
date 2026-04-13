# kpatch 源码走读（第 1 段）：用户入口与整体工作流

**主题:** 从“怎么用”开始，建立 kpatch 的第一层心智模型
**适用读者:** 初学者 + 想快速定位主链路的内核开发者
**来源:** `/home/egg/source/kpatch/README.md`、`/home/egg/source/kpatch/doc/INSTALL.md`、`/home/egg/source/kpatch/kpatch/kpatch`、`/home/egg/source/kpatch/kpatch-build/kpatch-build`

## [toc]

- [这段要学什么](#这段要学什么)
- [先建立一句话理解](#先建立一句话理解)
- [用户视角：kpatch 到底在做什么](#用户视角kpatch-到底在做什么)
- [从 README 看主流程](#从-readme-看主流程)
- [从脚本看入口](#从脚本看入口)
- [初学者版心智模型](#初学者版心智模型)
- [专家版补充理解](#专家版补充理解)
- [下一段该怎么读](#下一段该怎么读)

## 这段要学什么

这段只解决一个问题：**kpatch 的用户侧入口和总流程是什么。**

先不要急着啃 `create-diff-object.c`。如果没有先把用户视角串起来，后面你会看见很多 section、relocation、sysfs、ftrace 名词，但不知道它们在整条链路里处于哪一层。

## 先建立一句话理解

`kpatch-build` 负责把源码补丁变成可加载的补丁模块，`kpatch` 负责管理这个模块的安装、加载、卸载和状态查看。

换句话说：

- `kpatch-build` = 生成器
- `kpatch` = 管理器
- `patch module (.ko)` = 真正被内核加载的补丁载体

## 用户视角：kpatch 到底在做什么

从 `README.md` 可以先抓住三件事：

1. kpatch 的目标是给运行中的 Linux 内核打补丁，不重启、不踢业务进程。
2. 它的核心不是“修改源代码”，而是“把源代码 patch 转成内核能加载的 livepatch 模块”。
3. 它是按函数粒度工作的，旧函数会被新函数替换。

这意味着，用户真正关心的不是“补丁文件怎么写”，而是：

- 我怎么把一个 `.patch` 变成 `.ko`
- 我怎么把这个 `.ko` 加载到当前内核
- 我怎么确认补丁已经生效
- 出问题时怎么卸载恢复

## 从 README 看主流程

README 里的 quick start 可以压成 4 步：

1. 准备一个针对内核源码树的 diff patch。
2. 用 `kpatch-build` 构建补丁模块。
3. 用 `kpatch load` 把模块加载进正在运行的内核。
4. 用 `/proc`、`sysfs` 或行为变化验证补丁是否生效。

这里最重要的不是命令本身，而是中间状态：

- 源码 patch
- 变成补丁模块
- 再进入运行中的内核

这条路径决定了后面你必须同时理解构建链路和运行时链路。

## 从脚本看入口

### `kpatch/kpatch`

这个脚本是用户态管理入口。你可以先盯住几个关键函数：

- `usage()`：有哪些子命令
- `find_module()`：怎么定位补丁模块
- `init_sysfs_var()`：怎么判断当前系统使用哪套 livepatch/sysfs ABI
- `wait_for_patch_transition()`：怎么等待补丁切换完成

它的职责不是生成补丁，而是围绕已有补丁模块做管理动作。

### `kpatch-build/kpatch-build`

这个脚本是构建入口。先看它的顶层注释和阶段划分就够了：

- 先找内核源码与缓存目录
- 再验证 patch 文件是否合法
- 然后对原始源码和打 patch 后的源码分别构建
- 再找 changed objects
- 再调用 `create-diff-object`
- 最后封装成最终模块

你可以先把它理解成一个“流水线编排器”。

## 初学者版心智模型

你可以把 kpatch 想成三层：

1. **输入层**
   - 一个源代码 patch
   - 一个匹配的内核源码树

2. **转换层**
   - `kpatch-build` 对比原始/打补丁后的目标文件
   - 生成带元数据的 patch module

3. **执行层**
   - `kpatch` 把模块加载进内核
   - 内核 livepatch/ftrace 接管函数跳转

如果你能把这三层说顺，后面读源码就不会散。

## 专家版补充理解

从工程上看，kpatch 的核心约束是：

- 不是任意源码修改都适合 live patch
- 补丁必须考虑运行时一致性
- 用户态构建只是“发现和封装差异”

所以 `README.md` 里那句 “works at a function granularity” 非常关键。它说明了整个系统的抽象边界：

- 不是文件级替换
- 不是对象级热更新
- 而是函数级重定向

这会直接影响后面你读 `create-diff-object.c` 时的判断方式。

## 下一段该怎么读

下一段建议直接读构建链路，顺序是：

1. `kpatch-build/kpatch-build`
2. `kpatch-build/kpatch-intermediate.h`
3. `kpatch-build/create-kpatch-module.c`
4. `kpatch-build/create-klp-module.c`
5. `kpatch-build/create-diff-object.c`

读的时候只抓两个问题：

- 它在什么阶段生成什么中间产物
- 这些中间产物最后如何喂给内核 livepatch

<!-- vibenotes-version: branch main @ 46552a0, 2026-04-13 00:25:56 CST -->
