# QEMU RISC-V 指令解码与 TCG 翻译全流程

[toc]

---

## 1. 概述

QEMU 的 TCG（Tiny Code Generator）是一个 JIT 编译器：将 Guest 指令（如 RISC-V）翻译成 Host 机器码（如 x86-64 / aarch64）后直接执行。本文梳理从一条 RISC-V 二进制指令进入 QEMU 后，经过解码、翻译到最终 Host 执行的全链路。

**示例指令**：`0000000 00111 00110 000 00101 0110011`

```
funct7  rs2   rs1  f3   rd    opcode
0000000 00111 00110 000 00101 0110011
```

→ 解码结果：`sub x5, x6, x7`（funct7=0100000 非 0000000，此处示例为 add 的编码，实际 sub funct7 为 0100000；核心机制相同）

---

## 2. 四个核心问题

### 2.1 为什么 QEMU 读的一定是 32-bit 而不是 34/38？

**RISC-V 规范内置了长度标记**，在指令的最低 2 个 bit：

```c
// target/riscv/internals.h:248-251
static inline int insn_len(uint16_t first_word)
{
    return (first_word & 3) == 3 ? 4 : 2;
}
```

- `bits[1:0] == 11` → 32-bit 标准指令
- `bits[1:0] != 11` → 16-bit 压缩指令（C/Zca 扩展）

所有 RISC-V 指令长度均为 16-bit 整数倍，不存在其他长度。QEMU 完全遵循此规范。

### 2.2 QEMU 怎么确定起点和终点？

- **起点**：`ctx->base.pc_next`（当前 PC）
- **终点**：`ctx->base.pc_next + ctx->cur_insn_len`

核心在 `decode_opc()`（translate.c:1254）：

```c
// 1. 从 PC 读指令字（4 字节或 2 字节）
if (pc_is_4byte_align) {
    opcode = translator_ldl_end(env, &ctx->base, ctx->base.pc_next, MO_LE);
} else {
    opcode = (uint32_t)translator_lduw_end(env, &ctx->base, ctx->base.pc_next, MO_LE);
}

// 2. 低 2-bit 判定长度
ctx->cur_insn_len = insn_len((uint16_t)opcode);

// 3. 32-bit 指令但 PC 非 4 字节对齐 → 补读后 2 字节
if (ctx->cur_insn_len != 2 && !pc_is_4byte_align) {
    opcode = deposit32(opcode, 16, 16,
                       translator_lduw_end(env, &ctx->base, ctx->base.pc_next + 2, MO_LE));
}
```

翻译完成后在 `riscv_tr_translate_insn()` 中：

```c
decode_opc(env, ctx);
ctx->base.pc_next += ctx->cur_insn_len;   // PC 前进
```

### 2.3 QEMU 怎么知道各 bit 段的含义？

**`.decode` 声明式定义 + `decodetree.py` 自动代码生成。**

三层抽象：**字段 → 格式 → 模式**。

#### 字段（field）——定义位位置

```
# insn32.decode
%rs2       20:5
%rs1       15:5
%rd        7:5
```

#### 格式（format）——定义位格局

```
# insn32.decode
@r   .......   ..... ..... ... ..... ....... &r   %rs2 %rs1 %rd
#    ^funct7  ^rs2  ^rs1  ^f3 ^rd   ^opcode
#    7-bit    5-bit 5-bit 3bit 5bit 7bit
```

其中 `.` 代表可变位，固定位直接写数字。格式引用了 `&r` 参数集。

#### 模式（pattern）——把固定位填进去

```
sub   0100000 ..... ..... 000 ..... 0110011 @r
```

#### decodetree.py 自动生成字段提取代码

```c
// 对应 @r 格式，自动生成
static void decode_insn32_extract_r(DisasContext *ctx, arg_r *a, uint32_t insn)
{
    a->rd  = extract32(insn, 7, 5);   // %rd
    a->rs1 = extract32(insn, 15, 5);  // %rs1
    a->rs2 = extract32(insn, 20, 5);  // %rs2
}
```

**funct7/funct3/opcode 这些固定位不存变量**——它们在自动生成的 switch-case 树中直接参与匹配。

### 2.4 Decode 流程

#### 启动时：动态组装解码器列表

```c
// target/riscv/tcg/tcg-cpu.c:1213
void riscv_tcg_cpu_finalize_dynamic_decoder(RISCVCPU *cpu) {
    GPtrArray *dynamic_decoders = g_ptr_array_sized_new(decoder_table_size);
    for (size_t i = 0; i < decoder_table_size; ++i) {
        if (decoder_table[i].guard_func(&cpu->cfg))     // 扩展已启用？
            g_ptr_array_add(dynamic_decoders,
                            decoder_table[i].riscv_cpu_decode_fn);
    }
    cpu->decoders = dynamic_decoders;
}
```

解码器表（translate.c:1244）：

```c
const RISCVDecoder decoder_table[] = {
    { always_true_p,           decode_insn32 },            // 基础 ISA
    { has_xmips_p,             decode_xmips },
    { has_xthead_p,            decode_xthead },
    { has_XVentanaCondOps_p,   decode_XVentanaCodeOps },
    { has_xlrbr_p,             decode_xlrbr },
};
```

每个解码器由一个 guard 函数（判断该扩展是否启用）和一个 decode 函数组成。

#### 运行时：每条指令的解码

```c
// decode_opc() 中
if (ctx->cur_insn_len == 2) {
    if (decode_insn16(ctx, opcode)) return;    // 16-bit 解码树
} else {
    for (guint i = 0; i < ctx->decoders->len; ++i) {
        riscv_cpu_decode_fn func = g_ptr_array_index(ctx->decoders, i);
        if (func(ctx, opcode)) return;          // 匹配成功即返回
    }
}
gen_exception_illegal(ctx);  // 都不匹配 → 非法指令异常
```

`decode_insn32()` 是 decodetree.py 从 `insn32.decode` 自动生成的嵌套 switch-case：

```c
bool decode_insn32(DisasContext *ctx, uint32_t insn) {
    union { arg_r f_r; arg_i f_i; /* ... */ } u;

    switch (insn & 0x7f) {          // 低 7-bit opcode 分发
    case 0x33:                       // 0110011 → OP 类
        decode_insn32_extract_r(ctx, &u.f_r, insn);
        switch ((insn >> 12) & 0x7f07f) {
        case 0x0000000:  if (trans_add(ctx, &u.f_r)) return true; break;
        case 0x4000000:  if (trans_sub(ctx, &u.f_r)) return true; break;
        // ...
        }
        break;
    case 0x13:  /* OP-IMM */ ...
    case 0x03:  /* LOAD */   ...
    case 0x23:  /* STORE */  ...
    // ...
    }
    return false;
}
```

---

## 3. 翻译函数：从 decode 到 TCG IR

每条指令对应的翻译函数（`trans_*`）负责生成 TCG 中间表示：

```c
// trans_rvi.c.inc:709
static bool trans_add(DisasContext *ctx, arg_add *a) {
    return gen_arith(ctx, a, EXT_NONE, tcg_gen_add_tl, tcg_gen_add2_tl);
}

// translate.c:967
static bool gen_arith(DisasContext *ctx, arg_r *a, DisasExtend ext,
                      void (*func)(TCGv, TCGv, TCGv), ...) {
    TCGv dest = dest_gpr(ctx, a->rd);       // 分配目标 TCG 变量 x5
    TCGv src1 = get_gpr(ctx, a->rs1, ext);  // 读取 x6
    TCGv src2 = get_gpr(ctx, a->rs2, ext);  // 读取 x7
    func(dest, src1, src2);                 // ★ 写入 TCG op: dest = src1 - src2
    gen_set_gpr(ctx, a->rd, dest);          // 写回 x5
    return true;
}
```

**注意：`tcg_gen_sub_tl(dest, src1, src2)` 不是立即执行减法**——它在 TCG 的 op 缓冲区中记录一个 `INDEX_op_sub_i64` 操作，将 TCG 临时变量之间建立依赖关系。此时只是**构建 IR 图**。

---

## 4. 完整运行时流水线

```
┌──────────────────────────────────────────────────────────────┐
│                  QEMU TCG 完整执行流水线                       │
├──────────────────────────────────────────────────────────────┤
│                                                               │
│  [1] cpu_exec()                      accel/tcg/cpu-exec.c     │
│       │  主执行循环，反复取 TB 执行                            │
│       ▼                                                       │
│  [2] tb_lookup() / tb_gen_code()                               │
│       │  查 TB 缓存（QHT 哈希表）                              │
│       │  ├─ 命中 → 直接跳到 [6] 执行（零开销）                  │
│       │  └─ 未命中 → 进入翻译阶段                              │
│       ▼                                                       │
│  [3] tb_gen_code()                   translate-all.c:261      │
│       │  分配 TB 结构体，准备翻译                              │
│       ▼                                                       │
│  [4] riscv_translate_code()          translate.c:1452          │
│       │  调用 translator_loop()                                │
│       ▼                                                       │
│  [5] translator_loop()                translator.c:122         │
│       │  ┌───────────────────────────────────────────┐        │
│       │  │ while (true) {                             │        │
│       │  │   insn_start()    → tcg_gen_insn_start()  │        │
│       │  │   translate_insn()→ decode_opc()            │        │
│       │  │     └→ trans_xxx() → tcg_gen_xxx_tl()     │        │
│       │  │   if (is_jmp != DISAS_NEXT) break;        │        │
│       │  │ }                                         │        │
│       │  │ tb_stop()                                  │        │
│       │  └───────────────────────────────────────────┘        │
│       │  → tcg_gen_code(): TCG IR → host 机器码               │
│       ▼                                                       │
│  [6] cpu_tb_exec()                   cpu-exec.c:428          │
│       │  tcg_qemu_tb_exec() → 间接跳转到 host 机器码          │
│       │  Host CPU 直接执行翻译后的代码                        │
│       ▼                                                       │
│  [7] TB 链式执行 (goto_tb)                                    │
│       │  TB 间直接跳转，不经过 QEMU C 代码                    │
│       │  直到：中断 / IO / 页边界 / 缓存未命中                │
│       ▼                                                       │
│  [8] 返回 cpu_tb_exec() → 循环到 [1]                         │
│                                                               │
└──────────────────────────────────────────────────────────────┘
```

### 逐阶段关键代码

#### [2] TB 查找（cpu-exec.c）

```c
tb = tb_gen_code(cpu, s);                    // 编译新 TB
// ...
cpu_loop_exec_tb(cpu, tb, s.pc, &last_tb, &tb_exit);
```

TB 命中时通过 `QHT` 哈希表快速查找，**无需重新翻译**。

#### [3] TB 分配 & 翻译入口（translate-all.c:261）

```c
TranslationBlock *tb_gen_code(CPUState *cpu, TCGTBCPUState s) {
    tb = tcg_tb_alloc(tcg_ctx);              // 分配 TB
    tb->tc.ptr = tcg_splitwx_to_rx(gen_code_buf);  // 预留 host 代码缓冲区
    // ...
    gen_code_size = setjmp_gen_code(...);    // → 调用 riscv_translate_code
    // ...
    tcg_gen_code(tcg_ctx, tb);               // ★ TCG IR → host 机器码
}
```

#### [4] 翻译回调注册（tcg/tcg-cpu.c:276）

```c
const TCGCPUOps riscv_tcg_ops = {
    // ...
    .translate_code = riscv_translate_code,    // ★ TCG 翻译入口
    .get_tb_cpu_state = riscv_get_tb_cpu_state,
    // ...
};
```

#### [5] translator_loop（translator.c:122）

```c
void translator_loop(CPUState *cpu, TranslationBlock *tb, int *max_insns,
                     vaddr pc, void *host_pc, const TranslatorOps *ops,
                     DisasContextBase *db, TCGType addr_type) {
    gen_tb_start(db, cflags);          // TB 序言（icount 递减等）

    while (true) {
        ops->insn_start(db, cpu);      // → riscv_tr_insn_start → tcg_gen_insn_start(pc)
        ops->translate_insn(db, cpu);  // → riscv_tr_translate_insn → decode_opc()
        if (db->is_jmp != DISAS_NEXT) break;
        if (tcg_op_buf_full() || db->num_insns >= db->max_insns) {
            db->is_jmp = DISAS_TOO_MANY;
            break;
        }
    }

    ops->tb_stop(db, cpu);             // 生成退出逻辑（goto_tb / exit_tb）
    gen_tb_end(tb, cflags, ...);
}
```

translator_loop 返回后，`tb_gen_code` 调用 `tcg_gen_code()` 进行：

1. **寄存器分配**：将 TCG 临时变量映射到 host 寄存器或栈
2. **指令选择**：将 `INDEX_op_sub_i64` 翻译成 `sub rdi, rsi, rdx`（x86-64）或 `sub x0, x1, x2`（aarch64）
3. **二进制编码**：写入 `tb->tc.ptr`

#### [6] Host 执行（cpu-exec.c:428）

```c
static inline TranslationBlock *
cpu_tb_exec(CPUState *cpu, TranslationBlock *itb, int *tb_exit) {
    const void *tb_ptr = itb->tc.ptr;                // host 机器码地址
    qemu_thread_jit_execute();                        // JIT 写屏障
    ret = tcg_qemu_tb_exec(cpu_env(cpu), tb_ptr);   // ★ 间接跳转进 JIT 代码
    // ...
}
```

`tcg_qemu_tb_exec` 是一个 **间接函数调用**——跳转到 `tb->tc.ptr` 所在的内存页（通过 `mprotect` 映射为 RX 可执行）。

#### [7] TB 链式执行

TB 末尾的 `goto_tb` 直接将控制流转到下一个 TB 的 host 代码入口，**不经过 QEMU C 代码**。这是 QEMU TCG 接近原生性能的核心机制。

TB 链在以下情况断裂：I/O 操作、中断、页边界、间接跳转目标未编译。

---

## 5. 扩展机制：如何加一条自定义指令

以 `xlrbr`（CRC32）扩展为例，最小改动：

**① 写 .decode 文件**（`xlrbr.decode`）：

```
%rs1       15:5
%rd        7:5
&r2        rd rs1              !extern
@r2        .......  ..... ..... ... ..... ....... &r2 %rs1 %rd

crc32_w    0110000  10010 ..... 001 ..... 0010011 @r2
```

**② 写翻译函数**（`insn_trans/trans_xlrbr.c.inc`）：

```c
static bool trans_crc32_w(DisasContext *ctx, arg_r2 *a) {
    REQUIRE_XLRBR(ctx);
    TCGv dest = dest_gpr(ctx, a->rd);
    TCGv src1 = get_gpr(ctx, a->rs1, EXT_NONE);
    gen_helper_crc32(dest, src1, tcg_constant_tl(4));
    gen_set_gpr(ctx, a->rd, dest);
    return true;
}
```

**③ 注册解码器**（`translate.c`）：

```c
const RISCVDecoder decoder_table[] = {
    // ...
    { has_xlrbr_p, decode_xlrbr },
};
```

**④ 注册 guard 函数**（`cpu_cfg.h`）：

```c
#define MATERIALISE_EXT_PREDICATE(xlrbr)
```

**⑤ 构建系统**（`meson.build`）：

```python
decodetree.process('xlrbr.decode', extra_args: '--static-decode=decode_xlrbr'),
```

`decodetree.py` 自动生成 `decode_xlrbr()` 函数，无需手写 switch-case。

---

## 6. 关键文件清单

### RISC-V 前端（解码 + 翻译）

| 文件 | 角色 |
|------|------|
| `target/riscv/internals.h:248` | `insn_len()` — 指令长度判定（2 行） |
| `target/riscv/insn32.decode` | 字段/格式/模式定义，所有 32-bit 标准指令 |
| `target/riscv/insn16.decode` | 16-bit 压缩指令定义 |
| `target/riscv/translate.c:1254` | `decode_opc()` — 取指→判长→解码器遍历 |
| `target/riscv/translate.c:1244` | `decoder_table[]` — 解码器注册 |
| `target/riscv/translate.c:1452` | `riscv_translate_code()` — TCG 翻译入口 |
| `target/riscv/translate.c:967` | `gen_arith()` — 算术指令通用 TCG 生成器 |
| `target/riscv/tcg/tcg-cpu.c:1213` | 按扩展动态组装解码器列表 |
| `target/riscv/tcg/tcg-cpu.c:276` | 注册 `translate_code` 到 `TCGCPUOps` |
| `target/riscv/tcg/tcg-cpu.h:33` | `RISCVDecoder` 结构体定义 |
| `target/riscv/insn_trans/trans_rvi.c.inc` | `trans_add/sub/lui...` — TCG IR 生成 |
| `target/riscv/xlrbr.decode` | 极简扩展定义示例 |
| `target/riscv/insn_trans/trans_xlrbr.c.inc` | 扩展翻译函数示例 |
| `target/riscv/cpu_cfg.h` | `always_true_p` / `has_*_p` guard 函数 |

### 代码生成器

| 文件 | 角色 |
|------|------|
| `scripts/decodetree.py:1497` | `main()` — 解析 .decode → 生成 switch-case C 代码 |
| `scripts/decodetree.py:288` | `Field.str_extract()` — 生成 `extract32(insn, pos, len)` |
| `scripts/decodetree.py:736` | `Tree.output_code()` — 生成嵌套 switch 语句 |
| `scripts/decodetree.py:541` | `Format.output_extract()` — 生成字段提取辅助函数 |

### TCG 公共层

| 文件 | 角色 |
|------|------|
| `accel/tcg/translator.c:122` | `translator_loop()` — 逐条翻译主循环 |
| `accel/tcg/translate-all.c:261` | `tb_gen_code()` — TB 分配 + 翻译 + 编译 |
| `accel/tcg/cpu-exec.c:428` | `cpu_tb_exec()` — 跳进 JIT host 代码 |
| `accel/tcg/cpu-exec.c:884` | `cpu_loop_exec_tb()` — TB 查找/执行/链式执行 |
| `include/exec/translator.h` | `TranslatorOps` / `DisasContextBase` 定义 |

---

## 7. 走读建议

1. `internals.h:248` → 理解指令长度（一行代码）
2. `decode_opc()`（translate.c:1254-1313）→ 取指→判长→遍历解码器全流程
3. `insn32.decode` 前 80 行 → 字段/格式/模式三层抽象语法
4. `trans_lui`（trans_rvi.c.inc:33）→ 最简单的翻译函数
5. `xlrbr.decode` + `trans_xlrbr.c.inc` → 完整扩展示例
6. `translator_loop()`（translator.c:122）→ 翻译主循环
7. `tb_gen_code()`（translate-all.c:261）→ TB 生命周期
8. `cpu_tb_exec()`（cpu-exec.c:428）→ JIT 代码执行
9. `decodetree.py:1497` `main()` → .decode → C 代码生成全流程

---

> **版本**: QEMU v11.0.0-578-gac0cc20ad2 (branch: master, commit: ac0cc20ad2fe0b8df2e5d9458e90a095ac711ab1)
> **时间**: 2026-06-26
