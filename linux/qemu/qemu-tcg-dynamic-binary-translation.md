# QEMU TCG 动态二进制翻译：TB 大小、缓存与链接

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
};
```

---

## 2. TB 大小：每次翻译多少条指令？

### 硬上限

```c
// include/exec/translation-block.h:74
#define CF_COUNT_MASK  0x000001ff   // = 511
#define TCG_MAX_INSNS  512
```

### 自然终止条件

`translator_loop()` 逐条调用 `translate_insn`，遇到以下情况之一即终止：

```c
translator_loop():
  while (true) {
      if (max_insns == 0) {          // ① 硬上限 512 条 reached
          is_jmp = DISAS_TOO_MANY;
          break;
      }
      translate_insn(dc, cpu);       // target/<arch>/translate.c
      if (is_jmp != DISAS_NEXT)      // ② 分支/跳转/异常指令
          break;
      max_insns--;
  }
```

以 RISC-V 为例 (`target/riscv/translate.c`)：

```c
static void riscv_tr_translate_insn(DisasContextBase *dcbase, CPUState *cpu)
{
    // 翻译完指令后判断：
    if (ctx->base.is_jmp == DISAS_NEXT) {
        // ③ 16字节对齐边界 —— 强制打断
        if (ctx->base.pc_next & 0xf)
            ctx->base.is_jmp = DISAS_TOO_MANY;
        // ④ 页边界 —— 强制打断 (映射可能变化)
        if (!is_same_page(&ctx->base, ctx->base.pc_next))
            ctx->base.is_jmp = DISAS_TOO_MANY;
    }
}
```

5 种终止信号：

| 信号 | 含义 | 典型触发指令 |
|------|------|-------------|
| `DISAS_NEXT` | 继续翻译下一条 | 顺序执行指令 |
| `DISAS_TOO_MANY` | 达到上限/边界 | 纯计算代码块 |
| `DISAS_JUMP` | 无条件跳转 | JAL、JALR |
| `DISAS_BRANCH` | 条件分支 | BEQ、BNE |
| `DISAS_NORETURN` | 不会返回 | ECALL、MRET、WFI |

### 实际分布

```
典型基本块大小：
┌──────────────────────────────────────────┐
│  3-8 条指令    ████████████████  ~60%     │ ← 分支密集代码
│  8-32 条指令   ████████          ~25%     │
│  32-128 条指令  ████              ~12%     │
│  128-512 条指令  █                 ~3%     │ ← 无分支循环
└──────────────────────────────────────────┘
平均 ~10-15 条 guest 指令 / TB
```

---

## 3. 缓存架构：翻译结果存在哪里？

**两级缓存：L1 每 vCPU 独立，L2 全局共享。**

```
cpu_exec_loop() 查 tb:
  │
  ├─ tb_lookup(cpu, pc, flags):
  │   │
  │   ├─ L1: tb_jmp_cache[pc_hash]       ← 每 CPU 独立，直接映射
  │   │     hash = pc & (SIZE-1)
  │   │     命中率 > 90% (5次比较，无锁)
  │   │
  │   └─ (L1 miss) L2: tb_ctx.htable     ← 全局 QHT 哈希表
  │         tb_htable_lookup(cpu, phys_pc, flags, cs_base, cflags)
  │         命中后回填 L1
  │
  └─ (miss) tb_gen_code(cpu, pc)         ← 需要翻译
```

**L1 查找** (`accel/tcg/cpu-exec.c:227`)：

```c
static inline TranslationBlock *tb_lookup(CPUState *cpu, TCGTBCPUState s)
{
    hash = tb_jmp_cache_hash_func(s.pc);     // pc % cache_size
    jc = cpu->tb_jmp_cache;

    tb = jc->array[hash].tb;
    if (likely(tb &&
               jc->array[hash].pc == s.pc &&       // PC 匹配
               tb->cs_base == s.cs_base &&         // 段基址匹配
               tb->flags == s.flags &&             // CPU 状态匹配
               tb_cflags(tb) == s.cflags)) {        // 编译标志匹配
        return tb;    // ← 热路径：纯比较，无锁
    }

    tb = tb_htable_lookup(cpu, s);
    if (tb) {
        jc->array[hash].pc = s.pc;     // 回填 L1
        jc->array[hash].tb = tb;
    }
    return tb;
}
```

**L2 查找** (`accel/tcg/cpu-exec.c:195`)：

```c
static TranslationBlock *tb_htable_lookup(CPUState *cpu, TCGTBCPUState s)
{
    phys_pc = get_page_addr_code(env, s.pc);       // 虚拟→物理地址
    desc = { .page_addr0 = phys_pc, .flags, .cs_base, .cflags };
    h = tb_hash_func(phys_pc, s.pc, s.flags, s.cs_base, s.cflags);
    return qht_lookup_custom(&tb_ctx.htable, &desc, h, tb_lookup_cmp);
}
```

### 缓存生命周期

| 事件 | 行为 |
|------|------|
| 正常执行 | 一直缓存，持续命中 |
| SMC (Self-Modifying Code) | `tb_invalidate_phys_page()` 失效该页所有 TB |
| code_gen_buffer 溢出 | 全部 flush，从头开始 |
| 跨页 TB | `tb_add_jump()` 调用跳过（不安全），走慢路径 |

---

## 4. 如何知道要翻译哪些代码？

**按需翻译 (demand-driven) —— 只翻译 guest 实际执行到的路径。**

```
guest reset → PC = 0x80000000 (reset vector)
  │
  └─ cpu_exec_loop():
      s.pc = cpu->cc->tcg_ops->get_tb_cpu_state(cpu)   ← 从 env->pc 读取
      │
      tb = tb_lookup(cpu, s)
      │
      ├─ 命中 → 直接执行
      │
      └─ 未命中 → tb_gen_code(cpu, s.pc)              ← 从 s.pc 开始翻译
            │                                             直到分支/跳转/512上限
            │
            ├─ translator_loop()       ← target/riscv/translate.c
            │   └─ 逐条 guest 指令 → TCG IR
            ├─ tcg_gen_code()          ← TCG IR → host machine code
            ├─ tb_link_page()          ← 插入 L2 全局表
            └─ jc->array[h] = tb       ← 回填 L1 缓存
```

---

## 5. TB 链接 (Chaining)：QEMU 如何消除查找开销

```
执行中动态链接：

cpu_exec_loop() 中
  tb = tb_lookup(cpu, s);              // 当前 PC 的 TB
  if (last_tb) {
      tb_add_jump(last_tb, tb_exit, tb);  // ← hotpatch 上个 TB 的 jmp 目标
  }
  cpu_loop_exec_tb(cpu, tb, pc, &last_tb, &tb_exit);
```

`tb_add_jump` 做的事：直接修改**上一个 TB 末尾的 host 机器码**，把 `jmp` 的目标地址 patch 成新 TB 的 host 地址。

```
完整生命周期：

T=0: PC = 0x80000000
     tb_lookup → miss
     tb_gen_code(0x80000000) → TB_A (5条指令, 以 branch 结束)
     插入 L1/L2 缓存
     执行 TB_A → branch taken → PC = 0x80000100

T=1: PC = 0x80000100
     tb_lookup → miss (第一次)
     tb_gen_code(0x80000100) → TB_B
     tb_add_jump(TB_A, exit_0, TB_B)  ← patch TB_A 的 jmp → 指向 TB_B
     执行 TB_B → 跳回 0x80000000

T=2: PC = 0x80000000
     tb_lookup → L1 HIT!
     直接执行 TB_A → 末尾 jmp → TB_B (host 级跳转，不经 QEMU)
     → TB_B → 跳回 TB_A → ...
     纯 host 机器码循环，零 QEMU 介入

     ↑ 这就是 QEMU 速度快的原因
```

### 链接的例外

```c
#ifndef CONFIG_USER_ONLY
// 系统模式：跨页 TB 不链接（第二页映射可能变化）
if (tb_page_addr1(tb) != -1) {
    last_tb = NULL;
}
#endif
```

---

## 6. 一条指令的完整执行路径总结

```
guest 执行到 PC

 ① get_tb_cpu_state(cpu)           ← 从 env 读取 PC + 状态标志
 ② tb_lookup()                     ← L1 查表
  │
  ├─ HIT → 直接跳到 ③
  │
  └─ MISS → tb_gen_code()
        ├─ translator_loop()       ← guest → TCG IR (一次性)
        ├─ tcg_gen_code()          ← TCG IR → host 机器码
        ├─ tb_link_page()          ← 写入全局表
        └─ 回填 L1 缓存
 ③ cpu_tb_exec()                   ← 执行翻译后的 host 代码
 ④ tb_add_jump(last_tb, ...)       ← 链接到上一个 TB
 ⑤ 回到 ① 或处理中断/异常
```

QEMU 与解释器关键区别：

| | 解释器 | QEMU TCG |
|--|--------|----------|
| 取指 | 每次从 guest 内存取 | 翻译后不存在（已编码在 TB 元数据） |
| PC | 每条指令更新 | 只在中断/异常时物化恢复 |
| 分支 | 逐条比较判断 | host jmp 直接跳转 |
| 执行密度 | 1 guest insn / 循环 | ~10-15 guest insns / TB，TB 间 host jmp |

---

*Generated: 2026-06-21 | Source: git@github.com:gevico/qemu-camp-2026-exper-Egg12138.git branch=ai_try commit=27de27e*
