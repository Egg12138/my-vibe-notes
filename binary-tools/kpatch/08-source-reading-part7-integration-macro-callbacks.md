# kpatch 源码走读（第 7 段）：integration 案例 `macro-callbacks`

**主题:** 用 `macro-callbacks.patch` 解释补丁生命周期回调如何进入 build-time 和 runtime
**适用读者:** 已理解普通函数补丁，想看 callback 补丁的人
**来源:** `/home/egg/source/kpatch/test/integration/rhel-8.3/macro-callbacks.patch`、`/home/egg/source/kpatch/kpatch-build/create-diff-object.c`、`/home/egg/source/kpatch/kmod/patch/livepatch-patch-hook.c`、`/home/egg/source/kpatch/kmod/core/core.c`

## [toc]

- [这段要学什么](#这段要学什么)
- [案例是什么](#案例是什么)
- [patch 原文在做什么](#patch-原文在做什么)
- [build-time 会识别什么](#build-time-会识别什么)
- [runtime 会把什么接到哪里](#runtime-会把什么接到哪里)
- [为什么 callback 补丁仍然需要 patchability 检查](#为什么-callback-补丁仍然需要-patchability-检查)
- [初学者版总结](#初学者版总结)
- [专家版总结](#专家版总结)
- [下一步怎么继续](#下一步怎么继续)

## 这段要学什么

这段要解决的问题是：**一个不改业务函数逻辑、只加生命周期回调的补丁，为什么也算 kpatch 的有效补丁？**

它帮助你理解：

- callback 不是装饰品，而是补丁状态切换的一部分
- callback section 不是随便留着的，它会被 build-time 和 runtime 共同消费

## 案例是什么

我用的是 `rhel-8.3/macro-callbacks.patch`。

它在多个目标文件里都做了相同模式的改动：

- `joydev.c`
- `pcspkr.c`
- `aio.c`

每个文件里都加了：

- `KPATCH_PRE_PATCH_CALLBACK(...)`
- `KPATCH_POST_PATCH_CALLBACK(...)`
- `KPATCH_PRE_UNPATCH_CALLBACK(...)`
- `KPATCH_POST_UNPATCH_CALLBACK(...)`

## patch 原文在做什么

这个 patch 的业务逻辑很简单：它定义了一个 `callback_info()`，在四个生命周期点打印当前对象状态。

关键不在打印，而在这些宏：

- `KPATCH_PRE_PATCH_CALLBACK`
- `KPATCH_POST_PATCH_CALLBACK`
- `KPATCH_PRE_UNPATCH_CALLBACK`
- `KPATCH_POST_UNPATCH_CALLBACK`

它们把函数指针和对象名打进专用 section，之后由 kpatch 工具链识别。

## build-time 会识别什么

`create-diff-object` 对 callback 的处理不是“忽略”，而是“显式保留并接线”。

它会做几件事：

1. 识别 callback section
   - `.kpatch.callbacks.pre_patch`
   - `.kpatch.callbacks.post_patch`
   - `.kpatch.callbacks.pre_unpatch`
   - `.kpatch.callbacks.post_unpatch`

2. 把 callback section 以及它依赖的符号加入输出
   - 也就是让 callback 函数本身和它引用到的符号进入最终补丁对象

3. 通过 `.rela.kpatch.callbacks.*` 给 callback 结构补 `objname`
   - 这样 runtime 才知道这个 callback 属于哪个 `patch_object`

换句话说，build-time 做的事不是“把回调删掉”，而是“把回调变成 livepatch 能理解的元数据”。

## runtime 会把什么接到哪里

`livepatch-patch-hook.c` 会从专用的 callback section 中读取这些回调结构：

- `__kpatch_callbacks_pre_patch`
- `__kpatch_callbacks_post_patch`
- `__kpatch_callbacks_pre_unpatch`
- `__kpatch_callbacks_post_unpatch`

然后它会：

1. 按 `objname` 找到对应的 `patch_object`
2. 把回调函数指针挂到 `object->callbacks`
3. 在构造 `struct klp_patch` 时把这些回调复制到 `klp_object`

这就形成了完整链路：

```text
patch 宏
  → callback section
  → create-diff-object 保留并补 objname
  → livepatch-patch-hook.c 组装 patch_object
  → core.c 在 patch/unpatch 时调用
```

## 为什么 callback 补丁仍然需要 patchability 检查

虽然这个 patch 主要是在加回调，但它依然要经过 patchability 检查，因为：

- 回调只是补丁生命周期的一部分
- 它并不自动让被 patch 的函数变得安全
- 真实补丁可能同时包含函数修改、全局状态变化和 callback

`create-diff-object` 仍然要确认：

- 变更函数是否可 patch
- 是否有 patchable entry
- 有没有 unsupported control flow
- 有没有会破坏 livepatch 一致性的 section 变化

所以 callback 补丁能通过，不是因为“只有回调”，而是因为它的整体补丁形态仍然合法。

## 初学者版总结

这类补丁可以记成一句话：

**回调不是附带说明，而是 livepatch 生命周期的正式入口。**

## 专家版总结

更准确地说，`macro-callbacks.patch` 证明了两件事：

1. `create-diff-object` 会把 callback section 当成一等公民处理，而不是丢掉
2. runtime 会把 callback 映射到 `patch_object`，从而在 patch/unpatch 过程中执行用户自定义逻辑

这也是为什么 callback 补丁在语义上很重要：

- 它允许在 patch 切换前后显式地处理状态
- 它是解决数据语义变化和资源收尾问题的关键机制之一

## 下一步怎么继续

下一步建议继续看 `shadow-newpid.patch`。

它能把“回调解决生命周期问题”推进到“shadow variable 如何解决对象语义变化”。

<!-- vibenotes-version: branch main @ 46552a0, 2026-04-13 00:41:24 CST -->
