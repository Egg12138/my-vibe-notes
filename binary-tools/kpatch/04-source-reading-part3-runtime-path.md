# kpatch 源码走读（第 3 段）：运行时接管、状态机与函数跳转

**主题:** 补丁模块加载后，内核如何安全地切换旧函数到新函数
**适用读者:** 已经理解 build-time 产物，想看内核如何执行的人
**来源:** `/home/egg/source/kpatch/kmod/core/core.c`、`/home/egg/source/kpatch/kmod/core/kpatch.h`、`/home/egg/source/kpatch/kmod/core/shadow.c`、`/home/egg/source/kpatch/kmod/patch/kpatch-patch-hook.c`、`/home/egg/source/kpatch/kmod/patch/livepatch-patch-hook.c`

## [toc]

- [这段要学什么](#这段要学什么)
- [一句话理解运行时](#一句话理解运行时)
- [运行时的两条路径](#运行时的两条路径)
- [core.c 的三个核心职责](#corec-的三个核心职责)
- [状态机与 activeness safety](#状态机与-activeness-safety)
- [ftrace handler 怎么工作](#ftrace-handler-怎么工作)
- [dynrela 在运行时如何被消费](#dynrela-在运行时如何被消费)
- [callbacks 和 shadow vars](#callbacks-和-shadow-vars)
- [初学者版理解](#初学者版理解)
- [专家版理解](#专家版理解)
- [下一段该怎么读](#下一段该怎么读)

## 这段要学什么

这段要解决的问题是：**补丁模块加载后，内核是怎么把旧函数切到新函数，并且尽量不把正在运行的任务打坏。**

这是 kpatch 的核心难点。build-time 只是准备材料，runtime 才决定补丁是否真的安全生效。

## 一句话理解运行时

补丁模块加载后，会把“函数映射”和“动态重定位”注册进内核；内核在安全检查通过后，通过 ftrace 把对旧函数的调用重定向到新函数。

## 运行时的两条路径

你会看到两条不同但目标一致的路径：

1. **旧式 kpatch core 路径**
   - `kmod/core/core.c`
   - `kmod/patch/kpatch-patch-hook.c`

2. **现代 livepatch 路径**
   - `kmod/patch/livepatch-patch-hook.c`

两者的差别在于“谁来接管补丁装配”：

- `core.c` 是 kpatch 自己的核心接管逻辑
- `livepatch-patch-hook.c` 是把 kpatch 的中间格式翻成 `struct klp_patch` 再交给内核 livepatch API

但无论哪条路径，最终都要完成三件事：

- 建立对象与函数映射
- 应用必要的重定位
- 让函数调用转到新实现

## core.c 的三个核心职责

### 1. 一致性检查

在真正切换前，`core.c` 会检查：

- 当前任务栈上是否有要被替换的函数
- 是否存在 NMI 期间的一致性冲突
- 补丁是否处在允许切换的状态

这就是 activeness safety 的核心。

### 2. 函数注册与 ftrace 接管

`core.c` 会把旧函数地址加入 ftrace filter，并注册 `kpatch_ftrace_handler()`。

当旧函数被调用时，ftrace 进入 handler，handler 会把返回地址改到新函数入口。

### 3. 模块生命周期管理

它还负责：

- 处理补丁加载 / 卸载
- 处理模块 notifer
- 处理补丁之间的 replace 关系
- 管理 sysfs/kobject 暴露的状态

## 状态机与 activeness safety

`core.c` 里有一个明确的状态机：

- `IDLE`
- `UPDATING`
- `SUCCESS`
- `FAILURE`

这个状态机的意义是：**让 NMI 里的读者和 stop_machine 里的写者能安全协作。**

运行流程可以粗略理解为：

1. 进入 `UPDATING`
2. 做 activeness safety 检查
3. 暂时把新函数放入全局 hash
4. 如果 NMI 期间没有冲突，进入 `SUCCESS`
5. 如果冲突，回滚到 `FAILURE`

`kpatch_verify_activeness_safety()` 的作用就是：

- 遍历所有任务栈
- 检查栈上是否命中待 patch 的函数
- 如果命中，就拒绝本次切换

这一步非常保守，但必要。它避免“函数正在执行时被换掉”。

## ftrace handler 怎么工作

`kpatch_ftrace_handler()` 是真正的跳转点。

它的逻辑可以压缩成：

1. 根据当前 IP 找到对应 `kpatch_func`
2. 如果找到，就把 `regs->ip` 改成新函数地址
3. 返回给 ftrace，CPU 继续从新函数执行

在 NMI 场景下，它还会额外检查状态机，以避免看到半更新的数据结构。

所以这里的关键不是“hook 住了函数”，而是：

- 旧函数入口仍然有效
- 但返回路径被改写了
- 这使得替换能在一致性受控的条件下完成

## dynrela 在运行时如何被消费

`dynrela` 解决的是补丁模块里那些不能在链接时直接定死的引用。

运行时，`core.c` 会：

1. 找到目标对象和目标符号
2. 解析外部符号或 patch 内部符号
3. 计算最终写入值
4. 在必要时把相关页临时改成可写
5. 用 `probe_kernel_write()` 把 relocation 写进去

你可以把它理解成：

**build-time 负责描述“哪里需要重定位”，runtime 负责真正把值写进去。**

## callbacks 和 shadow vars

`core.c` 和 `kpatch-macros.h` 让补丁作者可以在 patch/unpatch 前后挂回调。

这类回调适合处理：

- 需要临时改全局状态
- 需要准备 / 回收资源
- 需要在 patch 切换前后做额外同步

`shadow.c` 则是另一条重要路线。它解决的是“不能直接改原有结构体布局，但又想给对象附加状态”的问题。

所以你可以这样记：

- callbacks = 生命周期钩子
- shadow vars = 给旧对象外挂新状态

## 初学者版理解

把运行时想成一个三步动作：

```text
补丁模块加载
  → 建立函数映射和重定位
  → 做一致性检查
  → ftrace 接管旧函数调用
```

如果后面你读 `core.c` 觉得很绕，先回到这个三步模型。

## 专家版理解

这一段真正值得注意的点有三个：

1. **kpatch 不是无条件抢占执行流**  
   它依赖 stop_machine、任务栈检查和状态机协作，尽量让切换可验证。

2. **ftrace 不是单纯 trace，而是函数入口的重定向基础设施**  
   kpatch 用的是 IP 修改能力，不是日志能力。

3. **补丁安全性的边界在 runtime 就开始暴露**  
   不是所有 build-time 能通过的 patch 都适合 livepatch；运行时一致性才是最后关口。

## 下一段该怎么读

下一段建议回到补丁作者视角，读这些内容：

1. `doc/patch-author-guide.md`
2. `kmod/patch/kpatch-macros.h`
3. `kmod/core/shadow.c`
4. `test/integration/`

重点看这些问题：

- 哪些补丁属于“能构建但不安全”
- 为什么数据结构变化要绕开
- 为什么 callbacks / shadow vars 很关键

<!-- vibenotes-version: branch main @ 46552a0, 2026-04-13 00:25:56 CST -->
