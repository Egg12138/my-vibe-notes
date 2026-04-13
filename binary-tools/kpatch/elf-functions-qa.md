# Kpatch ELF 函数 Q&A — create-diff-object 核心函数分析

> **Date:** 2026-03-15
> **Level:** Advanced
> **Source:** kpatch/kpatch-build/create-diff-object.c, kpatch-elf.c
> **Topic:** ELF 解析核心函数的行为、目的和设计规则

---

## Table of Contents

1. [kpatch_create_section_list](#1-kpatch_create_section_list)
2. [kpatch_create_symbol_list](#2-kpatch_create_symbol_list)
3. [kpatch_set_pfe_link](#3-kpatch_set_pfe_link)
4. [kpatch_find_func_profiling_calls](#4-kpatch_find_func_profiling_calls)
5. [kpatch_compare_elf_headers](#5-kpatch_compare_elf_headers)

---

## 1. kpatch_create_section_list

### 行为流程

```
elf_getshdrnum() → 获取 section 总数
    ↓
elf_getshdrstrndx() → 获取 section 名字符串表索引
    ↓
循环 elf_nextscn() → 遍历每个 section
    ↓
对每个 section:
  ├─ gelf_getshdr()      → 读取 section header
  ├─ elf_strptr()        → 解析 section 名称
  ├─ elf_getdata()       → 映射 section 数据
  ├─ elf_ndxscn()        → 记录 section 索引
  └─ 检测 SHT_SYMTAB_SHNDX → 保存扩展段索引表
```

### 核心目的

| 目标 | 说明 |
|------|------|
| **ELF 抽象化** | 将 libelf 的底层 `Elf_Scn` 转换为 kpatch 自定义的 `struct section` 链表 |
| **建立反向索引** | 为后续通过 `find_section_by_index/name` 快速查找做准备 |
| **扩展段处理** | 捕获 `symtab_shndx` 用于处理 >65535 的扩展段索引场景 |

### 关键设计规则

```c
/* 规则 1: 修正 section 计数 - elf_getshdrnum 包含索引 0，但 elf_nextscn 不返回 */
sections_nr--;

/* 规则 2: 特殊 section 识别 - 保存扩展索引表供符号解析使用 */
if (sec->sh.sh_type == SHT_SYMTAB_SHNDX)
    kelf->symtab_shndx = sec->data;

/* 规则 3: 完整性校验 - 确保遍历逻辑与 ELF 规范一致 */
if (elf_nextscn(kelf->elf, scn))
    ERROR("expected NULL");
```

### 数据结构映射

```
ELF File Layout          →    kpatch_elf 内存结构
┌─────────────────┐           ┌──────────────┐
│ ELF Header      │           │ kpatch_elf   │
├─────────────────┤           │  ┌────────┐  │
│ Section 0       │──┐        │  │section │─┼──→ [struct section] → [struct section]...
├─────────────────┤  │        │  └────────┘  │
│ Section 1       │──┼───────►│              │
├─────────────────┤  │        │  symtab_shndx│─→ [data]
│ Section 2       │──┘        └──────────────┘
└─────────────────┘
```

---

## 2. kpatch_create_symbol_list

### 行为流程

```
find_section_by_name(.symtab)
    ↓
gelf_getsym() 循环读取符号
    ↓
对每个符号:
  ├─ 解析 st_name/st_info/st_shndx
  ├─ 处理 SHN_XINDEX 扩展索引
  ├─ 关联到对应 section
  ├─ STT_SECTION 符号 → 建立 secsym 反向链接
    ↓
kpatch_link_prefixed_functions() → 链接 x86 前缀符号
```

### 核心目的

| 目标 | 说明 |
|------|------|
| **符号语义提取** | 从原始 ELF 符号表提取 name/type/bind/section 语义信息 |
| **建立双向链接** | 符号→section (`sym->sec`) 和 section→符号 (`sec->secsym`) |
| **架构适配** | 处理 x86 的 `__pfx_`/`__cfi_` 前缀符号，用于 NOP padding 场景 |

### 关键设计规则

```c
/* 规则 1: 扩展段索引处理 - 当 st_shndx == SHN_XINDEX 时查找扩展表 */
if (shndx == SHN_XINDEX &&
    !gelf_getsymshndx(symtab->data, kelf->symtab_shndx, ...))
    ERROR("couldn't find extended section index");

/* 规则 2: SECTION 符号特殊处理 - 用 section 名称覆盖空符号名 */
if (sym->type == STT_SECTION) {
    sym->sec->secsym = sym;
    sym->name = sym->sec->name;  // 覆盖原始空名
}

/* 规则 3: x86 前缀符号链接 - 仅 x86_64 架构处理 */
if (kelf->arch != X86_64)
    return;
// 查找 __pfx_/__cfi_并链接到实际函数
```

### kpatch_link_prefixed_functions 深度分析

这是处理 **x86 内核函数 NOP padding** 的关键逻辑：

```c
/* 匹配条件 */
if (func->type == STT_FUNC &&
    func->sec == pfx->sec &&
    func->sym.st_value == pfx->sym.st_value + pfx->sym.st_size) {
    /*
     * 布局示例:
     * __pfx_get_task_mm: Value=0x0, Size=16
     * get_task_mm:       Value=0x10 (= 0x0 + 16) ← 紧接在 padding 之后
     */
    pfx->is_pfx = true;
    func->pfx = pfx;
}
```

**为什么需要这个？**

1. **CONFIG_CALL_PADDING** 编译选项生成 16 字节 NOP 填充
2. **objtool** 生成 `__pfx_*` 符号标记填充区域起点
3. **kpatch 需要识别** 实际函数入口在 `pfx_value + pfx_size`

---

## 3. kpatch_set_pfe_link

### 行为流程

```
kpatch_set_pfe_link(kelf)
    │
    ├─ 检查 kelf->has_pfe → 无 PFE 则直接返回
    │
    ├─ 遍历所有 sections
    │   └─ 查找 name == "__patchable_function_entries" 的 section
    │
    ├─ 对每个 PFE section:
    │   └─ 遍历其 rela 重定位表
    │       └─ 对每个 rela: rela->sym->pfe = sec (建立反向链接)
    │
    └─ 完成符号→PFE section 的映射
```

### 核心目的

| 目标 | 说明 |
|------|------|
| **建立反向索引** | 从 `symbol→pfe_section` 的链接，用于后续 ftrace callsite 生成 |
| **多 PFE 支持** | 支持多个独立的 `__patchable_function_entries` section（每 text section 一个） |
| **ftrace 集成** | 为 `kpatch_create_ftrace_callsite_sections` 提供 PFE 定位能力 |

### 代码逻辑

```c
static void kpatch_set_pfe_link(struct kpatch_elf *kelf)
{
    struct section* sec;
    struct rela *rela;

    /* 快速路径 - 无 PFE 则跳过 */
    if (!kelf->has_pfe)
        return;

    /* 查找所有名为 __patchable_function_entries 的 section */
    list_for_each_entry(sec, &kelf->sections, list) {
        if (strcmp(sec->name, "__patchable_function_entries"))
            continue;

        if (!sec->rela)
            continue;

        /* 遍历 PFE 的 rela，建立 symbol→section 链接 */
        list_for_each_entry(rela, &sec->rela->relas, list)
            rela->sym->pfe = sec;  /* 关键赋值 */
    }
}
```

### 为什么通过 rela 建立链接？

**PFE section 的数据结构：**

```
PFE section (raw data)          .rela.PFE section
┌──────────────────┐            ┌─────────────────────────────┐
│ 0x00000000       │            │ rela[0]:                    │
│ (address value)  │            │   offset = 0                │
├──────────────────┤            │   sym = func_A ← HERE!      │
│ 0x00000004       │            ├─────────────────────────────┤
│ (address value)  │            │ rela[1]:                    │
├──────────────────┤            │   offset = 4                │
│ 0x00000008       │            │   sym = func_B ← HERE!      │
│ (address value)  │            │   type = R_ARCH_64          │
└──────────────────┘            └─────────────────────────────┘
```

**关键洞察：** PFE section 包含原始地址数据，但**符号引用只存在于 relocation 表中**。这是 ELF 格式的标准设计。

### 数据结构关系图

```
ELF 结构                           kpatch 内存结构
┌─────────────────────────┐
│ .text.foo               │
│  (函数 foo 的代码)        │
├─────────────────────────┤
│ __patchable_function_   │       struct symbol {
│ _entries (PFE)          │───┐   ...
│  [entry for foo]        │   │   struct section *pfe;  ← 指向 PFE section
└─────────────────────────┘   │   }
                              │
struct section {              │
    ...                       │
    struct section *rela; ────┘
    struct list_head relas;
}
```

---

## 4. kpatch_find_func_profiling_calls

### 核心目的

| 目标 | 说明 |
|------|------|
| **检测 ftrace 支持** | 识别哪些函数已被编译器插入 fentry/mcount 调用 |
| **标记剖析开关** | 设置 `sym->has_func_profiling = 1` 供后续 ftrace section 生成使用 |
| **架构适配** | 针对不同 CPU 架构使用不同的检测策略 |

### 架构检测策略

#### X86_64 — `__fentry__` 检查

```c
case X86_64:
    if (sym->sec->rela) {
        rela = list_first_entry(&sym->sec->rela->relas, struct rela, list);
        /* 检查第一个重定位 */
        if ((rela->type != R_X86_64_NONE &&
             rela->type != R_X86_64_PC32 &&
             rela->type != R_X86_64_PLT32) ||
            strcmp(rela->sym->name, "__fentry__"))
            continue;
        sym->has_func_profiling = 1;
    }
    break;
```

**原理：** GCC 的 `-mfentry` 选项在函数入口插入 `call __fentry__`，该调用生成第一个 relocation。

#### S390 — 指令模式匹配

```c
case S390:
    /* Check for compiler generated fentry nop - jgnop 0 */
    insn = sym->sec->data->d_buf;
    if (insn[0] == 0xc0 && insn[1] == 0x04 &&
        insn[2] == 0x00 && insn[3] == 0x00 &&
        insn[4] == 0x00 && insn[5] == 0x00)
        sym->has_func_profiling = 1;
    break;
```

**原理：** S390 使用 **jgnop 0** 作为 fentry 占位符（6 字节），机器码：`0xc00400000000`。

#### PPC64 — 双重检测

```c
case PPC64:
    if (kpatch_symbol_has_pfe_entry(kelf, sym)) {
        sym->has_func_profiling = 1;
    } else if (sym->sec->rela) {
        list_for_each_entry(rela, &sym->sec->rela->relas, list) {
            if (!strcmp(rela->sym->name, "_mcount")) {
                sym->has_func_profiling = 1;
                break;
            }
        }
    }
    break;
```

**原理：** 优先检查 PFE（现代方式），降级检查 `_mcount` 重定位（传统方式）。

#### AARCH64 / LOONGARCH64 — PFE 检查

```c
case AARCH64:
case LOONGARCH64:
    if (kpatch_symbol_has_pfe_entry(kelf, sym))
        sym->has_func_profiling = 1;
    break;
```

### kpatch_symbol_has_pfe_entry 辅助函数

```c
static bool kpatch_symbol_has_pfe_entry(struct kpatch_elf *kelf, struct symbol *sym)
{
    if (!kelf->has_pfe)
        return false;

    list_for_each_entry(sec, &kelf->sections, list) {
        if (strcmp(sec->name, "__patchable_function_entries"))
            continue;
        if (!sec->rela)
            continue;

        list_for_each_entry(rela, &sec->rela->relas, list) {
            /* 匹配条件：
             * 1. rela->sym 有 section
             * 2. sym 的 section 与 rela->sym 的 section 相同
             * 3. rela->sym 已链接到当前 PFE section
             */
            if (rela->sym->sec && sym->sec == rela->sym->sec &&
                rela->sym->pfe == sec) {
                return true;
            }
        }
    }
    return false;
}
```

### 架构对比总结

| 架构 | 检测方式 | 关键标识 |
|------|----------|----------|
| **X86_64** | 第一个 rela 符号名为 `__fentry__` | `call __fentry__` |
| **S390** | 指令前 6 字节 = `0xc00400000000` | `jgnop 0` |
| **PPC64** | PFE entry 或 `_mcount` 重定位 | 双重检测 |
| **AARCH64** | PFE entry | 仅 PFE |
| **LOONGARCH64** | PFE entry | 仅 PFE |

---

## 5. kpatch_compare_elf_headers

### 比较的字段

```c
static void kpatch_compare_elf_headers(Elf *elf_orig, Elf *elf_patched)
{
    GElf_Ehdr ehdr_orig, ehdr_patched;

    if (!gelf_getehdr(elf_orig, &ehdr_orig))
        ERROR("gelf_getehdr");

    if (!gelf_getehdr(elf_patched, &ehdr_patched))
        ERROR("gelf_getehdr");

    if (memcmp(ehdr_orig.e_ident, ehdr_patched.e_ident, EI_NIDENT) ||
        ehdr_orig.e_type != ehdr_patched.e_type ||
        ehdr_orig.e_machine != ehdr_patched.e_machine ||
        ehdr_orig.e_version != ehdr_patched.e_version ||
        ehdr_orig.e_entry != ehdr_patched.e_entry ||
        ehdr_orig.e_phoff != ehdr_patched.e_phoff ||
        ehdr_orig.e_flags != ehdr_patched.e_flags ||
        ehdr_orig.e_ehsize != ehdr_patched.e_ehsize ||
        ehdr_orig.e_phentsize != ehdr_patched.e_phentsize ||
        ehdr_orig.e_shentsize != ehdr_patched.e_shentsize)
        DIFF_FATAL("ELF headers differ");
}
```

### 比较字段清单

| 字段 | 含义 | 为什么必须相等 |
|------|------|----------------|
| **e_ident[EI_NIDENT]** | ELF 魔数和基础标识 (16 字节) | 确保都是 ELF 文件、相同比特位 (32/64 位)、相同字节序 |
| **e_type** | 文件类型 (如 ET_REL, ET_EXEC) | kpatch 处理的是 `.o` 目标文件 (ET_REL)，类型不同意味着无法兼容 |
| **e_machine** | 目标架构 (如 EM_X86_64) | 架构不同 → 指令集/ABI 不同 → 二进制补丁无法应用 |
| **e_version** | ELF 版本 | 版本不一致可能导致解析差异 |
| **e_entry** | 入口地址 | 目标文件通常都为 0；若不同说明编译模型不一致 |
| **e_phoff** | Program Header 偏移 | kpatch 要求无 Program Header |
| **e_flags** | 架构特定标志 | 如 ABI 版本、浮点约定等，不同会导致运行时行为差异 |
| **e_ehsize** | ELF Header 大小 | 结构体大小不同 → ELF 格式不兼容 |
| **e_phentsize** | Program Header Entry 大小 | 必须为 0（无 Program Header） |
| **e_shentsize** | Section Header Entry 大小 | 不同意味着 section 结构布局不同 |

### 为什么要求这些字段相等？

**根本原因：kpatch 是二进制内核补丁工具**

```
原始内核模块 (original.o)     补丁模块 (patched.o)
        │                           │
        └───────────┬───────────────┘
                    ↓
          kpatch 比较并生成 diff
                    ↓
           生成 kpatch 模块 (.ko)
                    ↓
          加载到运行中的内核
                    ↓
    原位替换 (in-place patching) 函数代码
```

**如果 ELF 头不一致的后果：**

| 场景 | 后果 |
|------|------|
| **不同架构** | 指令编码不同，补丁代码无法在目标 CPU 执行 |
| **不同比特位** | 指针大小/对齐不同，内存布局错位 |
| **不同 ABI 标志** | 调用约定/寄存器使用不同，函数调用崩溃 |
| **不同 e_type** | 链接模型不同，重定位处理方式不同 |

### 未比较的字段及原因

| 字段 | 为什么不比较 |
|------|-------------|
| **e_shoff** | Section 数量可能变化（kpatch 会添加/删除 section） |
| **e_phnum** | 通过 `kpatch_check_program_headers` 间接保证为 0 |
| **e_shnum** | section 数量在 diff 过程中会变化 |
| **e_shstrndx** | 字符串表索引可能因 section 重排而改变 |

**关键洞察：** kpatch 允许**内容变化**（section 数量、布局），但不允许**格式变化**（ELF 基本结构）。

### 与 kpatch_check_program_headers 的协作

```c
static void kpatch_check_program_headers(Elf *elf)
{
    size_t ph_nr;

    if (elf_getphdrnum(elf, &ph_nr))
        ERROR("elf_getphdrnum");

    if (ph_nr != 0)
        DIFF_FATAL("ELF contains program header");
}
```

**为什么要求无 Program Header？**

| 原因 | 说明 |
|------|------|
| **目标文件特性** | `.o` 文件用于链接，不需要加载到内存执行 |
| **kpatch 假设** | 代码只通过 section 访问，不依赖 PT_LOAD 等 Program Header |
| **简化处理** | 避免处理可加载段的虚拟地址映射问题 |

---

## 函数调用顺序

```
kpatch_elf_open()
    │
    ├─→ kpatch_create_section_list()      /* 建立 sections 链表 */
    │
    ├─→ kpatch_create_symbol_list()       /* 建立 symbols 链表 */
    │     └─→ kpatch_link_prefixed_functions()  /* x86 前缀符号链接 */
    │
    └─→ kpatch_create_rela_list()         /* 建立 relas 链表 */

create-diff-object.c (main)
    │
    ├─→ kpatch_set_pfe_link(kelf_orig)    /* PFE 链接建立 */
    ├─→ kpatch_set_pfe_link(kelf_patched)
    │
    ├─→ kpatch_find_func_profiling_calls(kelf_orig)  /* ftrace 检测 */
    ├─→ kpatch_find_func_profiling_calls(kelf_patched)
    │
    ├─→ kpatch_compare_elf_headers()      /* ELF 头比较 */
    └─→ kpatch_check_program_headers()    /* Program Header 检查 */
```

---

## 设计洞察

### 1. 架构隔离模式

```c
/* 大部分代码与架构无关 */
kpatch_create_section_list()  /* 架构无关 */
kpatch_create_symbol_list()   /* 架构无关 */
kpatch_set_pfe_link()         /* 非 x86 架构使用 */

/* 架构特定处理隔离在独立函数中 */
kpatch_link_prefixed_functions()  /* 仅 x86_64 */
kpatch_find_func_profiling_calls() /* 按架构 switch */
```

### 2. 双向链接模式

```
section ↔ symbol 互相引用
    ↓
O(1) 时间复杂度的查找
```

### 3. 防御性校验

- 每个 ELF API 调用后检查错误
- 遍历结束校验完整性
- 关键假设用 DIFF_FATAL 强制检查

### 4. Rela 驱动设计

**核心原则：** ELF 的 relocation 表是"符号关联"的唯一可靠来源。

```
Data Section (原始字节)  →  无法直接获取符号信息
       ↓
.rela.Data (重定位表)   →  包含 sym 指针，是唯一可靠来源
```

---

## 相关笔记

- `00-kpatch-comprehensive-summary.md` — Kpatch 整体架构
- `create-diff-object-workflow.md` — 二进制差异引擎工作流程
- `01-advanced-deep-dive.md` — 高级主题深入

---

## 参考

**源码位置：**
- `kpatch/kpatch-build/kpatch-elf.c` — ELF 解析基础函数
- `kpatch/kpatch-build/create-diff-object.c` — 差异比较和 ftrace 集成

**外部资源：**
- GitHub: https://github.com/dynup/kpatch
- Kernel docs: `Documentation/livepatch/`
