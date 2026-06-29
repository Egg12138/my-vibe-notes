# QEMU TCG 动态二进制翻译：完整工作流程

[TOC]

---

## 1. TB (TranslationBlock) 基本概念

TranslationBlock 是 QEMU 翻译的基本单元——一段连续的 guest 指令翻译后形成的 host 机器码片段。

**核心结构体** (`include/exec/translation-block.h:46`)：

```c
struct TranslationBlock {
    vaddr pc;                     // 第一条 guest 指令的地址
    uint64_t cs_base;             // 目标架构特定数据 (如 x86 CS 基址)
    uint32_t flags;               // CPU 状态标志 (如 MMU 模式)
    uint32_t cflags;              // 编译标志

    struct {
        const void *ptr;          // host 可执行代码指针
        size_t size;              // host 代码大小
    } tc;
    uint16_t icount;              // 包含的 guest 指令条数

    /* 跳转链接 (chaining) */
    uintptr_t jmp_list_head;      // 链入当前 TB 的其他 TB 列表
    uintptr_t jmp_dest[2];        // 当前 TB 的两个出口目标 TB
    uint16_t jmp_reset_offset[2]; // host 代码中 jmp 指令的偏移

    tb_page_addr_t page_addr[2];   // 该 TB 涉及的物理页面 (最多跨 2 页)
    struct TranslationBlock *page_next[2]; // 同一物理页上的 TB 链表
};
```

---

## 2. 翻译是如何开始的？

### 入口调用链

```
cpu_exec()                                   ← accel/tcg/cpu-exec.c:1019
  └─ cpu_exec_setjmp()                       ← :1009
       └─ cpu_exec_loop()                    ← :932
            └─ 两层 while 循环
```

### cpu_exec_loop 核心逻辑

**`accel/tcg/cpu-exec.c:932`**：

```c
static int cpu_exec_loop(CPUState *cpu, SyncClocks *sc)
{
    int ret;
    while (!cpu_handle_exception(cpu, &ret)) {
        TranslationBlock *last_tb = NULL;
        int tb_exit = 0;

        while (!cpu_handle_interrupt(cpu, &last_tb)) {
            TranslationBlock *tb;
            // (1) 从 CPU 寄存器读取当前 PC 和状态
            TCGTBCPUState s = cpu->cc->tcg_ops->get_tb_cpu_state(cpu);
            s.cflags = cpu->cflags_next_tb;
            if (s.cflags == -1) {
                s.cflags = curr_cflags(cpu);
            }

            // (2) 检查断点
            if (check_for_breakpoints(cpu, s.pc, &s.cflags)) break;

            // (3) 查缓存
            tb = tb_lookup(cpu, s);
            if (tb == NULL) {
                // (4) 缓存未命中 → 开始翻译！
                CPUJumpCache *jc;
                uint32_t h;
                mmap_lock();
                tb = tb_gen_code(cpu, s);       // ← 核心翻译入口
                mmap_unlock();
                // 写入 L1 快速缓存
                h = tb_jmp_cache_hash_func(s.pc);
                jc = cpu->tb_jmp_cache;
                jc->array[h].pc = s.pc;
                qatomic_set(&jc->array[h].tb, tb);
            }

            // (5) TB 链（patch 上一个 TB 的跳转目标）
            if (last_tb) {
                tb_add_jump(last_tb, tb_exit, tb);
            }

            // (6) 执行这个 TB
            cpu_loop_exec_tb(cpu, tb, s.pc, &last_tb, &tb_exit);
        }
    }
    return ret;
}
```

### tb_gen_code — 完整的翻译管线

**`accel/tcg/translate-all.c:261`**

```c
TranslationBlock *tb_gen_code(CPUState *cpu, TCGTBCPUState s)
{
    // (1) 解析虚拟地址 → 物理地址，拿到 host 内存指针
    phys_pc = get_page_addr_code_hostp(env, s.pc, &host_pc);

    // (2) MMIO 页只翻译 1 条指令（不做缓存持久化）
    if (phys_pc == -1) {
        s.cflags = (s.cflags & ~CF_COUNT_MASK) | 1;
    }

    // (3) 确定最多翻译多少条指令（默认 512）
    max_insns = s.cflags & CF_COUNT_MASK;
    if (max_insns == 0) max_insns = TCG_MAX_INSNS;  // 512

    // (4) 分配 TB
    tb = tcg_tb_alloc(tcg_ctx);
    gen_code_buf = tcg_ctx->code_gen_ptr;
    tb->tc.ptr = tcg_splitwx_to_rx(gen_code_buf);

    // (5) 调用 setjmp_gen_code → 真正的翻译
    gen_code_size = setjmp_gen_code(env, tb, s.pc, host_pc,
                                     &max_insns, &ti);
    // ... 处理溢出情况（-1 buffer full / -2 TB too large / -3 deadlock）

    // (6) 编码搜索（用于异常恢复时找 PC）
    search_size = encode_search(tb, (void *)gen_code_buf + gen_code_size);
    tb->tc.size = gen_code_size;

    // (7) 插入全局缓存
    existing_tb = tb_link_page(tb);
    if (existing_tb != tb) {
        // 已有相同 TB → 丢弃新翻译的
        return existing_tb;
    }
    return tb;
}
```

### setjmp_gen_code — 隔离翻译与异常

**`accel/tcg/translate-all.c:238`**：

```c
static int setjmp_gen_code(CPUArchState *env, TranslationBlock *tb, ...)
{
    int ret = sigsetjmp(tcg_ctx->jmp_trans, 0);
    if (unlikely(ret != 0)) return ret;  // 翻译异常时 longjmp 回到这里

    tcg_func_start(tcg_ctx);
    CPUState *cs = env_cpu(env);
    tcg_ctx->cpu = cs;

    // (1) 调用目标架构的翻译器
    cs->cc->tcg_ops->translate_code(cs, tb, max_insns, pc, host_pc);

    // (2) TCG IR → host 机器码
    return tcg_gen_code(tcg_ctx, tb, pc);
}
```

### translate_code — 以 x86 为例

**`target/i386/tcg/translate.c:3613`**：

```c
void x86_translate_code(CPUState *cpu, TranslationBlock *tb,
                        int *max_insns, vaddr pc, void *host_pc)
{
    DisasContext dc;
    translator_loop(cpu, tb, max_insns, pc, host_pc, &i386_tr_ops, &dc.base);
}
```

调用通用的 `translator_loop`，每个目标架构要提供 `TranslatorOps` vtable（x86 是 `i386_tr_ops`）。

---

## 3. 翻译到什么程度认为这个 TB 可以结束？

### translator_loop 主循环

**`accel/tcg/translator.c:122`**：

```c
void translator_loop(CPUState *cpu, TranslationBlock *tb, int *max_insns,
                     vaddr pc, void *host_pc, const TranslatorOps *ops,
                     DisasContextBase *db)
{
    // 初始化 DisasContext
    db->tb = tb;
    db->pc_first = pc;
    db->pc_next = pc;
    db->is_jmp = DISAS_NEXT;
    db->num_insns = 0;
    db->max_insns = *max_insns;

    ops->init_disas_context(db, cpu);

    // TB 起始处理（icount 检查等）
    gen_tb_start(db, cflags);
    ops->tb_start(db, cpu);

    // 逐条翻译指令
    while (true) {
        *max_insns = ++db->num_insns;
        ops->insn_start(db, cpu);           // 标记指令开始
        ops->translate_insn(db, cpu);       // 翻译一条 guest 指令 → TCG IR

        /* 终止条件 1：目标架构主动要求停止 */
        if (db->is_jmp != DISAS_NEXT) {
            break;
        }

        /* 终止条件 2：TCG 输出缓冲区满 或 达到最大指令数上限 */
        if (tcg_op_buf_full() || db->num_insns >= db->max_insns) {
            db->is_jmp = DISAS_TOO_MANY;
            break;
        }
    }

    // 收尾：emit 退出 TB 的代码
    ops->tb_stop(db, cpu);
    gen_tb_end(tb, cflags, icount_start_insn, db->num_insns);

    // 设置 I/O 权限：只有最后一条指令可以做 I/O
    tb->size = db->pc_next - db->pc_first;
    tb->icount = db->num_insns;
}
```

### TB 终止条件一览

| 终止条件 | 触发机制 | 典型场景 |
|----------|---------|---------|
| `db->is_jmp != DISAS_NEXT` | target 的 `translate_insn()` 设置 | jmp、br、call、ret、syscall |
| `tcg_op_buf_full()` | TCG backend 的 op buffer 满了 | 指令生成太多 host ops |
| `db->num_insns >= db->max_insns` | 计数器达到上限 | 默认 512 条，MMIO 页则为 1 |
| `DISAS_TOO_MANY` | 上述溢出条件触发的被动终止 | 纯计算代码块 |

**`max_insns` 决定因素**：
- 正常情况：`TCG_MAX_INSNS = 512`
- MMIO 页面：**强制为 1**（一锤子买卖，不缓存）
- icount 模式：受剩余指令预算限制

---

## 4. 缓存架构：翻译结果存在哪里？

### 两级缓存架构

```
tb_lookup(cpu, s):
  │
  ├─ L1: tb_jmp_cache (per-CPU, 4096 槽)
  │     hash = tb_jmp_cache_hash_func(virt_pc)
  │     比较: pc + cs_base + flags + cflags
  │     命中率 > 90%, 无锁
  │
  └─ L2: tb_ctx.htable (全局 QHT)
        tb_htable_lookup(cpu, s)
        key = xxhash(phys_pc, pc, flags, cs_base, cflags)
        命中后回填 L1

  └─ miss → tb_gen_code(cpu, s)
```

### L1 快速缓存 (tb_jmp_cache)

**`accel/tcg/tb-jmp-cache.h`**：per-CPU，4096 个槽的直接映射缓存。

```c
#define TB_JMP_CACHE_BITS 12
#define TB_JMP_CACHE_SIZE (1 << TB_JMP_CACHE_BITS)  // 4096

typedef struct CPUJumpCache {
    struct rcu_head rcu;
    struct {
        TranslationBlock *tb;
        vaddr pc;
    } array[TB_JMP_CACHE_SIZE];
} CPUJumpCache;
```

**Hash 函数**（`accel/tcg/tb-hash.h:46`）：

```c
static inline unsigned int tb_jmp_cache_hash_func(vaddr pc)
{
    vaddr tmp;
    tmp = pc ^ (pc >> (TARGET_PAGE_BITS - TB_JMP_PAGE_BITS));
    return (((tmp >> (TARGET_PAGE_BITS - TB_JMP_PAGE_BITS)) & TB_JMP_PAGE_MASK)
           | (tmp & TB_JMP_ADDR_MASK));
}
```

含义：
- `TB_JMP_CACHE_BITS = 12` → 4096 个槽
- `TB_JMP_PAGE_BITS = 6` → 高位 6 位来自页号（TLB flush 时快速清除整个页面的条目）
- `TB_JMP_ADDR_BITS = 6` → 低位 6 位来自页内偏移

**创建**：在 `tcg_exec_realizefn()` (`cpu-exec.c:1048`) 中为每个 CPU 分配。

### L2 全局哈希表 (tb_ctx.htable)

**`accel/tcg/tb-context.h`**：

```c
typedef struct TBContext {
    struct qht htable;           // 全局哈希表
    // ...
} TBContext;
```

Key 组成：`tb_hash_func(phys_pc, pc_or_zero, cs_base, flags, cf_mask)`
使用 `qemu_xxhash8`（8 元 xxhash）做散列。

### tb_lookup — 完整查找路径

**`accel/tcg/cpu-exec.c:227`**：

```c
static inline TranslationBlock *tb_lookup(CPUState *cpu, TCGTBCPUState s)
{
    // L1: per-CPU 快速缓存
    hash = tb_jmp_cache_hash_func(s.pc);
    jc = cpu->tb_jmp_cache;

    tb = qatomic_read(&jc->array[hash].tb);
    if (likely(tb &&
               jc->array[hash].pc == s.pc &&        // 虚拟 PC 匹配
               tb->cs_base == s.cs_base &&            // 段基址匹配
               tb->flags == s.flags &&                // CPU 状态匹配
               tb_cflags(tb) == s.cflags)) {          // 编译标志匹配
        goto hit;  // ← 热路径，纯比较无锁
    }

    // L1 miss → 查全局 QHT
    tb = tb_htable_lookup(cpu, s);
    if (tb == NULL) {
        return NULL;  // 两级的都没命中
    }

    // 从全局表找到后回填 L1
    jc->array[hash].pc = s.pc;
    qatomic_set(&jc->array[hash].tb, tb);

hit:
    return tb;
}
```

### tb_htable_lookup — 全局表精确查找

**`accel/tcg/cpu-exec.c:195`**：

```c
static TranslationBlock *tb_htable_lookup(CPUState *cpu, TCGTBCPUState s)
{
    // 虚拟地址 → 物理地址（这是关键：相同虚地址不同进程下物理地址不同）
    phys_pc = get_page_addr_code(desc.env, s.pc);
    if (phys_pc == -1) return NULL;  // MMIO 不缓存

    h = tb_hash_func(phys_pc, (s.cflags & CF_PCREL ? 0 : s.pc),
                     s.flags, s.cs_base, s.cflags);
    return qht_lookup_custom(&tb_ctx.htable, &desc, h, tb_lookup_cmp);
}
```

**比较函数 `tb_lookup_cmp`** (`:158`) 做全面匹配：

```c
static bool tb_lookup_cmp(const void *p, const void *d)
{
    const TranslationBlock *tb = p;
    const struct tb_desc *desc = d;

    if ((tb_cflags(tb) & CF_PCREL || tb->pc == desc->s.pc) &&
        tb_page_addr0(tb) == desc->page_addr0 &&    // 物理页匹配
        tb->cs_base == desc->s.cs_base &&            // 架构状态匹配
        tb->flags == desc->s.flags &&                // flags 匹配
        tb_cflags(tb) == desc->s.cflags) {           // cflags 匹配
        // 跨页 TB 还需要检查第二页
        tb_page_addr_t tb_phys_page1 = tb_page_addr1(tb);
        if (tb_phys_page1 == -1) return true;
        phys_page1 = get_page_addr_code(desc->env, TARGET_PAGE_ALIGN(desc->s.pc));
        if (tb_phys_page1 == phys_page1) return true;
    }
    return false;
}
```

### 写缓存 — tb_link_page

**`accel/tcg/translate-all.c:992`**：

```c
TranslationBlock *tb_link_page(TranslationBlock *tb)
{
    // (1) 注册到物理页面的 TB 链表 + 区间树
    tb_record(tb);

    // (2) 插入全局 QHT
    h = tb_hash_func(tb_page_addr0(tb),
                     (tb->cflags & CF_PCREL ? 0 : tb->pc),
                     tb->flags, tb->cs_base, tb->cflags);
    qht_insert(&tb_ctx.htable, tb, h, &existing_tb);

    // (3) 如果在全局表中已经存在 → 丢弃新翻译的，返回已有的
    if (unlikely(existing_tb)) {
        tb_remove(tb);
        return existing_tb;
    }
    return tb;
}
```

其中 `tb_record` 还做了一件重要的事：把 TB 注册到**物理页面的 `PageDesc`** 结构的链表中，用于 SMC 检测时快速查找该页的所有 TB。

### 缓存生命周期

| 事件 | 行为 |
|------|------|
| 正常执行 | 一直缓存，持续命中 |
| SMC (Self-Modifying Code) | `tb_invalidate_phys_page_range__locked()` 失效该页所有 TB |
| code_gen_buffer 溢出 | `tb_flush()` 全部 flush，从头开始 |
| 跨页 TB | 系统模式下 `tb_add_jump()` 跳过（第二页映射可能变化） |

---

## 5. TB 链 (Chaining)：消除查找开销

### 代码路径

```c
cpu_exec_loop() 中:
    // 执行完 TB 后
    if (last_tb) {
        tb_add_jump(last_tb, tb_exit, tb);  // ← hotpatch
    }
```

### tb_add_jump 做了什么

**`accel/tcg/cpu-exec.c:616`**：

```c
static inline void tb_add_jump(TranslationBlock *tb, int n,
                               TranslationBlock *tb_next)
{
    // 原子地声明跳转目标槽位
    old = qatomic_cmpxchg(&tb->jmp_dest[n], NULL, (uintptr_t)tb_next);
    if (old) goto out;  // 已经被占用

    // 直接 patch host 机器码：修改 TB 末尾 jmp 指令的目标地址
    tb_set_jmp_target(tb, n, (uintptr_t)tb_next->tc.ptr);

    // 注册反向链接（用于失效时追溯）
    tb->jmp_list_next[n] = tb_next->jmp_list_head;
    tb_next->jmp_list_head = (uintptr_t)tb | n;
}
```

### 效果

```
T=0: tb_lookup → miss → tb_gen_code(TB_A, TB_B)
     tb_add_jump(TB_A, TB_B)  patch TB_A 末尾的 jmp 指向 TB_B

T=1: tb_lookup → L1 HIT
     执行 TB_A → 末尾 jmp → TB_B (纯 host 跳转)
     → TB_B → ... → TB_A → ...
     零 QEMU 主循环介入！
```

### 不链接的特殊情况

```c
// 系统模式下：跨页 TB 不链接（第二页虚拟→物理映射可能变）
if (tb_page_addr1(tb) != -1) {
    last_tb = NULL;
}
```

---

## 6. 缓存的颗粒度

### L1 快速缓存

- **结构**：per-CPU 固定大小 4096 槽，无冲突处理（后写入覆盖之前的）
- **Key**：虚拟 PC 的 12-bit hash
- **失效颗粒度**：**按虚拟页面**。TLB flush 时用 `tb_jmp_cache_hash_page()` 清除该页所有条目

### L2 全局 QHT

- **结构**：可伸缩并发哈希表
- **Key**：`xxhash8(phys_pc, pc, flags, cs_base, cf_mask)` — 6 个维度
- **颗粒度**：**一个 TB**。同一物理地址 + 同一组状态标志只对应一个条目

### 物理页反向索引

每个物理页面有一个 `PageDesc`，维护了该页上所有 TB 的链表：

```c
// tb_record() 内部：往物理页的 TB 链表中添加
tb_page_add(page_find_alloc(pindex), tb, 0);
```

- **用途**：SMC 检测时作废该页所有 TB
- **颗粒度**：**物理页级别**

### TB 内部

- 每个 TB 包含 **1~512** 条 guest 指令
- 平均约 **10-15** 条（受分支密集度影响）
- 最多跨 **2 个物理页**

---

## 7. 完整执行路径总结

```
guest 执行到 PC
  │
 ① get_tb_cpu_state(cpu)           ← 从 env 读取 PC + flags
 ② tb_lookup(cpu, s)
  │   ├─ L1: tb_jmp_cache[hash(virt_pc)]
  │   └─ L2: tb_htable_lookup(phys_pc, flags, ...)
  │
  ├─ HIT → 跳到 ④
  │
  └─ MISS → tb_gen_code(cpu, s)
        ├─ setjmp_gen_code()
        │    ├─ translate_code()      ← translator_loop()
        │    │    └─ 逐条: translate_insn → TCG IR
        │    └─ tcg_gen_code()        ← TCG IR → host 机器码
        ├─ tb_link_page()             ← 写入全局 QHT
        └─ jc->array[h] = tb          ← 回填 L1
  │
 ③ tb_add_jump(last_tb, tb)         ← patch host jmp 目标
 ④ cpu_tb_exec()                     ← 执行翻译后的 host 代码
    └─ tcg_qemu_tb_exec(env, tb_ptr)
 ⑤ 回到 ① 或处理中断/异常
```

### QEMU TCG vs 解释器

| | 解释器 | QEMU TCG |
|--|--------|----------|
| 取指 | 每次从 guest 内存取 | 翻译后不存在（已编码在 TB 元数据） |
| PC | 每条指令更新 | 只在中断/异常时物化恢复 |
| 分支 | 逐条比较判断 | host jmp 直接跳转 |
| 执行密度 | 1 guest insn / 循环 | ~10-15 guest insns / TB |

---

## 8. TCG IR：从 guest 指令到 host 机器码的中间表示

### 三阶段管线

```
┌─────────────────────────────────────────────────────────────┐
│  Phase 1:  guest → TCG IR （translator_loop）               │
│  target/riscv/translate.c + insn_trans/trans_rvi.c.inc      │
│      ↓  emit tcg_gen_*() → TCGOp 链表                       │
├─────────────────────────────────────────────────────────────┤
│  Phase 2:  TCG IR 优化 （tcg_gen_code 前半段）               │
│  tcg_optimize → reachable_code_pass → liveness_pass         │
├─────────────────────────────────────────────────────────────┤
│  Phase 3:  TCG IR → host 机器码 （tcg_gen_code 后半段）      │
│  tcg_reg_alloc_op → tcg_out_op → flush_idcache              │
└─────────────────────────────────────────────────────────────┘
```

### 核心数据结构

**TCGOp**（`include/tcg/tcg.h:310`）——每个 TCG 指令对应一个：

```c
struct TCGOp {
    TCGOpcode opc   : 8;    // 操作码，如 INDEX_op_add
    unsigned nargs  : 8;    // 参数总数
    TCGLifeData life;       // 活跃性信息
    TCGArg args[];          // 变长参数数组
};
```

所有 TCGOp 以**双向链表**形式串在 `TCGContext.ops` 上。

### TCG 操作码定义

**`include/tcg/tcg-opc.h`** 用 `DEF` 宏声明每个 IR 指令的原型：

```c
// DEF(name, oargs, iargs, cargs, flags)
DEF(add,    1, 2, 0, TCG_OPF_INT)                         // 1出2入
DEF(brcond, 0, 2, 2, TCG_OPF_BB_END | TCG_OPF_COND_BRANCH) // 条件分支
DEF(exit_tb, 0, 0, 1, TCG_OPF_BB_EXIT | TCG_OPF_BB_END)   // 退出TB
DEF(goto_tb, 0, 0, 1, TCG_OPF_BB_EXIT | TCG_OPF_BB_END)   // 链式跳转
DEF(qemu_ld, 1, 1, 1, TCG_OPF_CALL_CLOBBER | TCG_OPF_SIDE_EFFECTS)
DEF(qemu_st, 0, 2, 1, TCG_OPF_CALL_CLOBBER | TCG_OPF_SIDE_EFFECTS)
```

编译时通过 X-macro 展开为：
- `TCGOpcode` 枚举（`include/tcg/tcg.h`）
- `tcg_op_defs[]` 数组（`tcg/tcg-common.c`），包含每个 opcode 的名字、参数个数、flag

### TCG 变量类型

文档中定义的 5 种变量（`include/tcg/tcg.h` `TCGTemp`）：

| 变量类型 | 作用域 | 位置 | 例子 |
|----------|--------|------|------|
| `TEMP_FIXED` | 所有 TB | host 寄存器 | `cpu_env`（指向 CPUArchState） |
| `TEMP_GLOBAL` | 所有 TB | `CPUArchState` 偏移 | `cpu_gpr[0..31]` |
| `TEMP_CONST` | 整个 TB | 哈希去重 | `tcg_constant_i32(42)` |
| `TEMP_TB` | 整个 TB，出口死亡 | 临时寄存器 | 翻译中间结果 |
| `TEMP_EBB` | 扩展基本块，出口死亡 | 临时寄存器 | 分支间临时变量 |

### 具体实例分析

---

#### 实例 1：RISC-V ADDI（立即数加法）

**1. 解码**（`target/riscv/insn32.decode:149`）：
```
addi  ............  ..... 000 ..... 0010011 @i
```

**2. 分发 + 翻译**（`target/riscv/insn_trans/trans_rvi.c.inc:575`）：

```c
static bool trans_addi(DisasContext *ctx, arg_addi *a)
{
    return gen_arith_imm_fn(ctx, a, EXT_NONE,
                            tcg_gen_addi_tl, gen_addi2_i128);
}
```

**3. `gen_arith_imm_fn`**（`target/riscv/translate.c:908`）：

```c
static bool gen_arith_imm_fn(DisasContext *ctx, arg_i *a, DisasExtend ext,
                             void (*func)(TCGv, TCGv, target_long), ...)
{
    TCGv dest = dest_gpr(ctx, a->rd);     // → cpu_gpr[rd] (TEMP_GLOBAL)
    TCGv src1 = get_gpr(ctx, a->rs1, ext); // → cpu_gpr[rs1]
    func(dest, src1, a->imm);             // tcg_gen_addi_tl(dest, src1, imm)
    gen_set_gpr(ctx, a->rd, dest);
    return true;
}
```

**4. TCG IR 发射**（`tcg/tcg-op.c:342`）：

```c
void tcg_gen_addi_i32(TCGv_i32 ret, TCGv_i32 arg1, int32_t arg2)
{
    if (arg2 == 0) {
        tcg_gen_mov_i32(ret, arg1);           // 加 0 → 优化为 mov
    } else {
        tcg_gen_add_i32(ret, arg1,
                        tcg_constant_i32(arg2)); // 创建 TEMP_CONST
    }
}

void tcg_gen_add_i32(TCGv_i32 ret, TCGv_i32 arg1, TCGv_i32 arg2)
{
    tcg_gen_op3_i32(INDEX_op_add, ret, arg1, arg2);  // ← 插入 TCGOp
}
```

**5. 最终生成的 TCG IR**：
```
add_i64 cpu_gpr[10], cpu_gpr[11], $0x42
```
等价于 `TCGOp { opc = INDEX_op_add, args = [gpr10, gpr11, const_0x42] }`

**6. tcg_gen_code 发 host 机器码**：
- RISC-V host → `addi x10, x11, 0x42`
- x86-64 host → `lea rdi, [rsi + 0x42]` 或 `add rdi, 0x42`

---

#### 实例 2：RISC-V BNE（条件分支）

**1. 解码**（`insn32.decode:136`）：
```
bne  ....... ..... ..... 001 ..... 1100011 @b
```

**2. 翻译函数**（`trans_rvi.c.inc:269`）：

```c
static bool gen_branch(DisasContext *ctx, arg_b *a, TCGCond cond)
{
    TCGLabel *l = gen_new_label();    // 创建 label

    tcg_gen_brcond_tl(cond, src1, src2, l);  // brcond src1, src2, NE, $L0

    gen_goto_tb(ctx, 1, 4);           // fallthrough → goto_tb slot 1
    gen_set_label(l);                  // 标记 label
    gen_goto_tb(ctx, 0, a->imm);      // taken → goto_tb slot 0
    ctx->base.is_jmp = DISAS_NORETURN;
}

static bool trans_bne(DisasContext *ctx, arg_bne *a)
{
    return gen_branch(ctx, a, TCG_COND_NE);
}
```

**3. 生成的 TCG IR 序列**：

```
          insn_start
          brcond_i64  src1, src2, NE, $L1     ← 条件跳转
          goto_tb  1                            ← fallthrough 出口
          exit_tb  tb, 1                        ← patchable to host jmp
    $L1:  set_label
          goto_tb  0                            ← taken 出口
          exit_tb  tb, 0                        ← patchable to host jmp
```

`brcond` 的 `tcg_gen_op4ii_i64(INDEX_op_brcond, ...)` 生成一个 TCGOp：
```
TCGOp { opc = INDEX_op_brcond,
        args = [src1, src2, TCG_COND_NE, label_ref] }
```

**4. host 机器码**（x86-64 后端）：
```asm
cmp   rdi, rsi       ; brcond → 比较
jne   <L1_target>     ; 条件跳转
; ... (goto_tb + exit_tb 留空给 tb_add_jump patch)
```

---

#### 实例 3：RISC-V JAL（跳转并链接）

**`target/riscv/translate.c:617`**：

```c
static void gen_jal(DisasContext *ctx, int rd, target_ulong imm)
{
    gen_pc_plus_diff(succ_pc, ctx, ctx->cur_insn_len);
    gen_set_gpr(ctx, rd, succ_pc);    // 保存返回地址
    gen_goto_tb(ctx, 0, imm);         // 跳转 + 允许链
    ctx->base.is_jmp = DISAS_NORETURN;
}
```

生成的 TCG IR：
```
          insn_start
          addi_tl  rd, pc, 4               ← 保存返回地址
          goto_tb  0                         ← 跳转（链式）
          exit_tb  tb, 0
```

### tcg_gen_code 内部优化管线

**`tcg/tcg.c:6543`**，在发射机器码前跑多趟优化：

```c
int tcg_gen_code(TCGContext *s, TranslationBlock *tb, uint64_t pc_start)
{
    // 1. 常量折叠与简化
    tcg_optimize(s);
    // 文档中的例子：
    //   add_i32 t0, t1, t2     → 可消除
    //   add_i32 t0, t0, $1     → 可消除
    //   mov_i32 t0, $1         → 仅保留此条

    // 2. 死代码消除
    reachable_code_pass(s);

    // 3. 活跃性分析
    liveness_pass_0(s);
    liveness_pass_1(s);

    // 4. 间接临时降级
    if (s->nb_indirects > 0) {
        liveness_pass_2(s);
        liveness_pass_1(s);
    }

    // 5. 遍历 ops 链表，逐条发射 host 机器码
    QTAILQ_FOREACH(op, &s->ops, link) {
        switch (op->opc) {
        case INDEX_op_mov:
            tcg_reg_alloc_mov(s, op);  break;
        case INDEX_op_insn_start:
            /* 记录 guest PC ↔ host code offset 映射 */   break;
        case INDEX_op_exit_tb:
            tcg_out_exit_tb(s, ...);   break;
        case INDEX_op_goto_tb:
            tcg_out_goto_tb(s, ...);   break;
        case INDEX_op_br:
            tcg_out_br(s, ...);        break;
        default:
            tcg_reg_alloc_op(s, op);   // ← 通用寄存器分配 + 发射
        }
    }

    // 6. 刷新 I-cache
    flush_idcache(rx_ptr, rw_ptr, size);
}
```

可用 `-d op,op_opt` 分别查看优化前后的 TCG IR：
```
# -d op 输出：
OP:
 ---- guest_addr 0x80010000
 insn_start 0x80010000
 add_i64 tmp0, x10, $42
 mov_i64 x10, tmp0
 insn_start 0x80010004
 brcond_i64 x11, x12, NE, $L0
 ...

# 优化后可能变为：
OP after optimization:
 ---- guest_addr 0x80010000
 insn_start 0x80010000
 add_i64 x10, x10, $42              ← mov 被消除
 insn_start 0x80010004
 brcond_i64 x11, x12, NE, $L0
 ...
```

### TCG 变量类型与后端约束

每个 host 后端（`tcg/<arch>/tcg-target-con-set.h`）定义寄存器约束。以 x86-64 的 add 为例：
```
// 约束："r" = 任意寄存器, "ri" = 寄存器或立即数
// add_i32: output=r, input1=r, input2=ri
```

最终 `tcg_reg_alloc_op` 根据约束分配 host 寄存器，然后调用 `tcg_out_op` 发射：

```c
// aarch64 后端发射 ADD 指令的简化为：
case INDEX_op_add_i64:
    tcg_out_arith(s, TCG_TYPE_I64, ADD, a0, a1, a2);
    break;
```

---

*Generated: 2026-06-23 | Source: git@github.com:gevico/qemu-camp-2026-exper-Egg12138.git branch=ai_try commit=27de27e*
