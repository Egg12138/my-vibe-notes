# kpatch 源码走读（第 5 段）：create-diff-object 到底在比什么

**主题:** 解释 `create-diff-object` 的比较对象、归一化规则、可接受 diff 与不可容忍 diff
**适用读者:** 想真正理解 kpatch 二进制差异判定的人
**来源:** `/home/egg/source/kpatch/kpatch-build/create-diff-object.c`

## [toc]

- [这段要学什么](#这段要学什么)
- [一句话理解 create-diff-object](#一句话理解-create-diff-object)
- [它到底在比较什么](#它到底在比较什么)
- [哪些差异会被当成同一个东西](#哪些差异会被当成同一个东西)
- [什么是补丁 diff](#什么是补丁-diff)
- [什么是不可容忍的 diff](#什么是不可容忍的-diff)
- [为什么它不是简单的字节比较](#为什么它不是简单的字节比较)
- [初学者版结论](#初学者版结论)
- [专家版结论](#专家版结论)
- [下一段该怎么读](#下一段该怎么读)

## 这段要学什么

这段专门回答三个问题：

1. `create-diff-object` 到底在比较什么？
2. 它认为哪些差异是“补丁该有的差异”？
3. 哪些差异会直接把补丁判死？

这是理解 kpatch 的关键，因为它决定了“补丁能不能被构建出来”。

## 一句话理解 create-diff-object

`create-diff-object` 不是在找“文件内容有几处不同”，而是在找“哪些 ELF 对象差异可以被安全地解释成一个 livepatch 补丁”。

## 它到底在比较什么

它比较的是两个对象文件：

- 原始对象文件 `orig.o`
- 打补丁后的对象文件 `patched.o`

但不是单纯做 `memcmp()`。
它比较的是一整套 ELF 语义：

- ELF header 是否兼容
- section header 是否兼容
- section 内容是否变化
- relocation 是否变化
- symbol 是否还能正确对应
- 哪些变化属于补丁范围
- 哪些变化不允许出现在 livepatch 里

换句话说，它在做的是：

**“原始对象”和“patched 对象”的语义对齐与差异抽取。**

## 哪些差异会被当成同一个东西

`create-diff-object` 有大量“归一化”逻辑，目的是避免把无关差异误判成功能变化。

典型例子：

- GCC/LLVM 生成的带数字后缀的 mangled 名字
- `__UNIQUE_ID_*` 这类唯一 ID
- `.altinstr_aux` 这类对模块加载阶段无实际影响的临时代码
- ppc64le 的 `.toc` 相关重定位
- 一些 `.discard*`、`.modinfo`、`__mcount_loc`、`__patchable_function_entries` 等特殊 section

这说明它不是在追求“字节完全相等”，而是在追求“livepatch 关心的语义一致”。

## 什么是补丁 diff

一个“补丁 diff”，不是任何可见差异都行，而是满足 livepatch 语义的差异。常见可接受形态包括：

1. **函数体变化**
   - 这是最典型的补丁 diff
   - 例如修改 `meminfo_proc_show()` 的字符串

2. **新增全局符号**
   - 例如新增 `static int foo = 5;`
   - 只要是新增，不是改坏原有数据布局，通常可以作为补丁的一部分

3. **补丁需要的回调元数据**
   - `KPATCH_PRE_PATCH_CALLBACK` 这类宏引入的 callback section

4. **特殊 section 的受控变化**
   - jump label、static call、paravirt、alternatives 等
   - 这些不是普通 diff，但如果走的是它支持的重写路径，也可以被接受

## 什么是不可容忍的 diff

以下变化通常会被拒绝，或者至少需要改写补丁思路：

1. **ELF 基本结构不兼容**
   - ELF header 差异
   - program header 不为空

2. **改变了不该变化的 section 结构**
   - section header 类型 / flags / entsize / 对齐不一致
   - 新增或变化的 group section

3. **数据段直接被纳入补丁**
   - 普通 `.data.*` / `.bss.*` 直接进入输出通常不允许
   - 例外只有少数受控 section，比如 `.data.unlikely`、`.data.once`

4. **函数不可 patch**
   - 没有 patchable function entry
   - 发生了不支持的 sibling call
   - 出现不支持的 jump label 或 static call

5. **改变的是 livepatch 不能安全解释的语义**
   - 例如 init 期对象、不可安全迁移的数据语义

## 为什么它不是简单的字节比较

因为 livepatch 的目标不是“文件变了”，而是“运行中的内核是否能被安全切换”。

所以它必须回答这些问题：

- 这段变化是不是只是编译器生成的噪声？
- 这段变化会不会影响函数调用入口？
- 这段变化会不会引入新对象或新语义？
- 这段变化能不能被 ftrace 和 relocation 正确接管？

所以它先做“对齐”，再做“判定”，最后才做“抽取”。

## 初学者版结论

你可以先记住这句：

**补丁 diff = 函数级语义变化 + 少量受控的新增元数据。**

不是所有源码差异都能成为补丁。

## 专家版结论

更准确地说，`create-diff-object` 的判定流程是：

1. 对齐 orig/patched 两个 ELF 对象
2. 归一化编译器和架构噪声
3. 标记 changed section / changed symbol
4. 抽出真正可 patch 的函数、全局和元数据
5. 拒绝任何违反 livepatch 一致性约束的变化

它真正比较的不是“文本差异”，而是“补丁语义可否成立”。

## 下一段该怎么读

下一段建议用一个真实 integration patch 走一遍，直接看：

- 哪个 diff 会变成 changed function
- 哪个 diff 会变成 new global
- 哪个 diff 会被 `LOADED.test` 验证

我会用 `test/integration/rhel-8.3/data-new.patch` 作为案例。

<!-- vibenotes-version: branch main @ 46552a0, 2026-04-13 00:38:08 CST -->
