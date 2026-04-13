# kpatch 源码走读（第 6 段）：test/integration 真实案例 `data-new`

**主题:** 用 `rhel-8.3/data-new.patch` 走一遍 kpatch 的补丁判定与输出验证
**适用读者:** 已理解 create-diff-object 的判定规则，想看真实案例的人
**来源:** `/home/egg/source/kpatch/test/integration/rhel-8.3/data-new.patch`、`/home/egg/source/kpatch/test/integration/rhel-8.3/data-new-LOADED.test`、`/home/egg/source/kpatch/kpatch-build/create-diff-object.c`

## [toc]

- [这段要学什么](#这段要学什么)
- [案例是什么](#案例是什么)
- [补丁原文在改什么](#补丁原文在改什么)
- [create-diff-object 会怎么看这个补丁](#create-diff-object-会怎么看这个补丁)
- [为什么这是一个可接受的补丁 diff](#为什么这是一个可接受的补丁-diff)
- [运行时最终会验证什么](#运行时最终会验证什么)
- [如果换成不可接受的 diff 会怎样](#如果换成不可接受的-diff-会怎样)
- [初学者版总结](#初学者版总结)
- [专家版总结](#专家版总结)
- [下一步怎么继续](#下一步怎么继续)

## 这段要学什么

这段的目标是把前面抽象的判定规则落到一个真实 patch 上，回答：

- 这个 patch 为什么能过
- 它会被抽取出什么
- 最终 test 在验证什么

## 案例是什么

我选的是 `rhel-8.3/data-new.patch`。

它对应的测试文件是 `rhel-8.3/data-new-LOADED.test`，最后只检查一件事：

```bash
grep "kpatch:         5" /proc/meminfo
```

这意味着 patch 生效后，`/proc/meminfo` 里会多出一行来自新全局变量 `foo` 的输出。

## 补丁原文在改什么

这个 patch 做了两件事：

1. 在 `meminfo_proc_show()` 之前新增一个静态全局变量：
   ```c
   static int foo = 5;
   ```

2. 在 `meminfo_proc_show()` 里新增一行输出：
   ```c
   seq_printf(m, "kpatch:         %d\n", foo);
   ```

所以它不是单纯改字符串，而是：

- 改了一个函数
- 引入了一个新的全局状态

## create-diff-object 会怎么看这个补丁

它会先把原始对象和 patched 对象做 ELF 级对比，然后得到两个核心结论：

1. `meminfo_proc_show()` 是 changed function
2. `foo` 是 new global，且可以作为补丁中新增符号被保留下来

这里最重要的是：

- 没有直接改坏现有数据结构布局
- 没有把普通 `.data/.bss` 改动强行塞进补丁的已存在对象语义里
- 没有触发明显的不可容忍变化，比如 group section 变化、init 函数修改、无 patchable entry 的函数

所以它属于 `kpatch` 想要的那类 diff：

- 函数逻辑有变化
- 新增了受控的辅助状态
- 最后仍然可以归纳成一个可加载的补丁模块

## 为什么这是一个可接受的补丁 diff

这个例子好在它非常“干净”：

- 变化集中在一个可 patch 的函数里
- 新增的全局变量只是辅助输出，不改变既有结构语义
- 运行时验证也很直接，只要 `grep` 到新输出就说明补丁已加载并生效

从 `create-diff-object` 的角度看，它会把这个补丁归入：

- changed function
- new global

而不是：

- 不可容忍的数据布局变化
- 不可 patch 的 init 代码变化
- 不可识别的特殊控制流变化

## 运行时最终会验证什么

`data-new-LOADED.test` 验证的是运行结果，而不是构建输出：

- `/proc/meminfo` 中是否出现 `kpatch:         5`

这说明至少三件事成立：

1. 补丁模块成功构建
2. 补丁模块成功加载
3. `meminfo_proc_show()` 的新版本已经接管了实际执行

## 如果换成不可接受的 diff 会怎样

如果你把这个 patch 换成下面几类变化，`create-diff-object` 就会开始拒绝：

- 修改 `__init` 代码
- 把普通 `.data/.bss` 作为运行时共享语义的一部分直接改坏
- 改变 section group 结构
- 用了没有 patchable entry 的函数
- 引入 unsupported sibling call
- 引入 unsupported jump label / static call 路径

也就是说：

**`data-new` 之所以过，不是因为它“小”，而是因为它的变化类型正好落在 kpatch 的安全范围内。**

## 初学者版总结

这个案例可以一句话记住：

**补丁改了一个函数，再新增一个全局辅助值，最后由 integration test 验证输出变化。**

## 专家版总结

更准确地说，这个 patch 展示了 `create-diff-object` 的理想处理方式：

1. 识别真正 changed 的函数
2. 允许新增全局作为补丁辅助状态
3. 不碰不该碰的数据结构语义
4. 最终让 runtime 只消费必要的函数和元数据

## 下一步怎么继续

如果你想继续深挖，下一步最值得看的是：

1. `test/integration/rhel-8.3/macro-callbacks.patch`
2. `test/integration/rhel-8.3/shadow-newpid.patch`
3. `test/integration/rhel-8.3/module.patch`

这三个案例分别对应：

- callbacks
- shadow variable
- 模块加载 / 延迟 patch 的生命周期

<!-- vibenotes-version: branch main @ 46552a0, 2026-04-13 00:38:08 CST -->
