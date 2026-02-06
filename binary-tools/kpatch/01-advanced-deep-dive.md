# Kpatch: Advanced Deep Dive

> **Topic:** Advanced-level technical analysis of kpatch internals
> **Date:** 2026-02-03
> **Level:** Advanced
> **Prerequisites:** Understanding of ELF format, kernel modules, ftrace

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Binary Differencing Engine](#binary-differencing-engine)
3. [ELF Structure Manipulation](#elf-structure-manipulation)
4. [Symbol Resolution Strategies](#symbol-resolution-strategies)
5. [Ftrace Integration Details](#ftrace-integration-details)
6. [Consistency Model Internals](#consistency-model-internals)
7. [Memory Ordering and Concurrency](#memory-ordering-and-concurrency)
8. [Architecture-Specific Implementations](#architecture-specific-implementations)
9. [Edge Cases and Pitfalls](#edge-cases-and-pitfalls)
10. [Performance Considerations](#performance-considerations)

---

## Architecture Overview

### System Layers

```
┌─────────────────────────────────────────────────────────────────────────┐
│                          Kpatch System Architecture                     │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  User Space                                                              │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │                       kpatch-build                               │  │
│  │  ┌──────────────┐  ┌──────────────────┐  ┌──────────────────┐   │  │
│  │  │ kpatch-cc    │  │ create-diff-obj  │  │ kpatch-build     │   │  │
│  │  │ (GCC wrapper)│  │ (4562 lines)     │  │ (orchestrator)   │   │  │
│  │  └──────────────┘  └──────────────────┘  └──────────────────┘   │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                                   │                                     │
│                                   │ .ko file with KLP sections          │
│                                   ▼                                     │
│  Kernel Space                                                            │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │                    CONFIG_LIVEPATCH                               │  │
│  │  ┌────────────┐  ┌────────────┐  ┌────────────┐  ┌────────────┐  │  │
│  │  │  core.c    │  │transition.c│  │  patch.c   │  │  shadow.c  │  │  │
│  │  │ (1369 ln)  │  │ (732 lines)│  │ (290 ln)   │  │ (300 ln)   │  │  │
│  │  └────────────┘  └────────────┘  └────────────┘  └────────────┘  │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                                   │                                     │
│                                   ▼                                     │
│  ┌──────────────────────────────────────────────────────────────────┐  │
│  │                         Ftrace Subsystem                          │  │
│  │                   klp_ftrace_handler()                           │  │
│  │              (Per-function trampoline)                           │  │
│  └──────────────────────────────────────────────────────────────────┘  │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

### Key Design Principles

1. **Function Granularity**: Patching works at function level, not instruction level
2. **Binary Compatibility**: Original and patched objects must be binary-compatible
3. **Safe Transition**: Tasks must never observe inconsistent state
4. **No Static Data Modification**: Static data changes require shadow variables
5. **Compiler Version Matching**: Exact compiler match required for safety

---

## Binary Differencing Engine

### Main Function Analysis

**Location:** `kpatch/kpatch-build/create-diff-object.c:4404-4561`

```c
int main(int argc, char *argv[])
{
    // Input validation
    struct kpatch_elf *kelf_orig, *kelf_patched, *kelf_out;
    struct lookup_table *lookup;

    // Phase 1: Open and parse ELF files (lines 4433-4444)
    kelf_orig = kpatch_elf_open(orig_obj);
    kelf_patched = kpatch_elf_open(patched_obj);
    kpatch_set_pfe_link(kelf_orig);     // Patchable function entries
    kpatch_find_func_profiling_calls(); // ftrace instrumentation
    kpatch_compare_elf_headers();       // Verify compatibility
    kpatch_bundle_symbols();            // Match symbols to sections

    // Phase 2: Detect function relationships (lines 4449-4450)
    kpatch_detect_child_functions();    // .cold, .part detection

    // Phase 3: Symbol correlation (lines 4455-4459)
    kpatch_replace_sections_syms();     // Section symbol → actual symbol
    kpatch_correlate_elfs();            // Match orig ↔ patched
    kpatch_correlate_static_local_variables(); // Heuristic matching

    // Phase 4: Change detection (lines 4466-4470)
    kpatch_mark_ignored_sections();     // Exclude debug, etc.
    kpatch_compare_correlated_elements(); // memcmp + rela comparison
    kpatch_mark_ignored_functions_same(); // __LINE__-only changes
    kpatch_check_func_profiling_calls(); // Verify ftrace presence

    // Phase 5: Dependency inclusion (lines 4474-4479)
    kpatch_include_standard_elements(); // Always include .altinstructions
    num_changed = kpatch_include_changed_functions(); // + dependencies
    kpatch_include_callback_elements(); // pre/post callbacks
    kpatch_include_force_elements();    // __always_included
    kpatch_include_new_globals();       // New global symbols
    kpatch_include_debug_sections();    // For debugging

    // Phase 6: Special section processing (line 4481)
    kpatch_process_special_sections();  // jump_label, static_call

    // Phase 7: Verification (line 4486)
    kpatch_verify_patchability();       // __init checks, etc.

    // Phase 8: Output generation (lines 4498-4519)
    kpatch_migrate_included_elements(); // Extract included sections
    kpatch_create_patches_sections();   // .kpatch.funcs metadata
    kpatch_create_intermediate_sections(); // .klp.rela.* relocations
    kpatch_create_kpatch_arch_section(); // Arch-specific metadata
    kpatch_create_ftrace_callsite_sections(); // __ftrace_ops__

    // Phase 9: Finalization (lines 4528-4552)
    kpatch_reorder_symbols();           // Linker-required ordering
    kpatch_strip_unneeded_syms();       // Remove unused symbols
    kpatch_reindex_elements();          // Rebuild indexes
    kpatch_write_output_elf();          // Write .o file
}
```

### Symbol Bundling

**Function:** `kpatch_bundle_symbols()` (lines 302-327)

The concept of "bundled" symbols is critical:

```c
// With -ffunction-sections -fdata-sections:
// Each symbol gets its own section: .text.function_name, .data.variable_name
// A "bundled" symbol has sym->sec->sym == sym

static bool is_bundleable(struct symbol *sym) {
    // Function sections
    if (sym->type == STT_FUNC &&
        !strncmp(sym->sec->name, ".text.", 6) &&
        !strcmp(sym->sec->name + 6, sym->name))
        return true;

    // Hot/cold partitioning
    if (sym->type == STT_FUNC &&
        (!strncmp(sym->sec->name, ".text.unlikely.", 15) ||
         !strncmp(sym->sec->name, ".text.hot.", 10)) &&
        /* name matches after prefix */)
        return true;

    // Data sections
    if (sym->type == STT_OBJECT &&
        (!strncmp(sym->sec->name, ".data.", 6) ||
         !strncmp(sym->sec->name, ".rodata.", 8) ||
         !strncmp(sym->sec->name, ".bss.", 5)) &&
        /* name matches */)
        return true;
}
```

**Why this matters:**
- Enables granular section-level comparison
- Each function/data gets own section → easy to detect changes
- Section name format: `.section_type.symbol_name`

### Child Function Detection

**Function:** `kpatch_detect_child_functions()` (lines 354-382)

GCC's optimization creates child functions:

```c
// Example from kernel code:
static ssize_t device_show(struct device *dev, ...) {
    // Hot path (stays in device_show)
    if (likely(condition))
        return fast_path();

    // Cold path moved to separate function
    return unlikely_slow_path();
}

// Generated assembly:
//   device_show:
//       ... hot path code ...
//       b.ne .Lhot_continue
//       b device_show.cold.123  // Jump to cold function
//
//   device_show.cold.123:
//       ... slow path code ...
//       ret
```

**Detection logic:**
```c
// .cold suffix - unlikely execution paths
if (strstr(sym->name, ".cold"))
    sym->parent = kpatch_lookup_parent(sym->name, ".cold");

// .part. suffix - function splitting
if (strstr(sym->name, ".part."))
    sym->parent = kpatch_lookup_parent(sym->name, ".part.");
```

**Implication:** If parent function changes, all children must be included.

### Symbol Correlation

**Function:** `kpatch_correlate_elfs()` (lines 1137-1159)

Matches sections between original and patched ELF:

```c
static void kpatch_correlate_sections(struct kpatch_elf *kelf_orig,
                                      struct kpatch_elf *kelf_patched)
{
    struct section *sec_orig, *sec_patched;

    list_for_each_entry(sec_orig, &kelf_orig->sections, list) {
        // Use mangled name comparison
        list_for_each_entry(sec_patched, &kelf_patched->sections, list) {
            if (kpatch_mangled_strcmp(sec_orig->name, sec_patched->name) == 0) {
                // Establish twin relationship
                sec_orig->twin = sec_patched;
                sec_patched->twin = sec_orig;

                // Correlate symbols in section
                kpatch_correlate_symbols(sec_orig, sec_patched);

                // Rename mangled symbols to match original
                kpatch_normalize_symbol_names(sec_patched);
            }
        }
    }
}
```

**Mangled name comparison:**

GCC adds numeric suffixes to duplicate symbols:

```c
// Source code (multiple files with static int counter):
static int counter;

// Compiled sections (mangled names):
//   file1.c: .data.counter
//   file2.c: .data.counter.12345
//   file3.c: .data.counter.67890

// kpatch_mangled_strcmp treats all as equal:
int kpatch_mangled_strcmp(char *s1, char *s2) {
    while (*s1 == *s2) {
        if (!*s1) return 0;
        // Skip digit suffixes: ".12345" == ""
        if (*s1 == '.' && isdigit(s1[1])) {
            while (isdigit(*++s1));
            while (isdigit(*++s2));
        } else {
            s1++; s2++;
        }
    }
    // Handle end-of-string with digit tail
    if ((!*s1 && has_digit_tail(s2)) ||
        (!*s2 && has_digit_tail(s1)))
        return 0;
    return (*s1 - *s2);
}
```

### Special Static Detection

**Function:** `is_special_static()` (lines 409-464)

Some static locals must never be correlated:

```c
static bool is_special_static(struct symbol *sym) {
    static char *var_names[] = {
        "__key",              // Lockdep keys
        "__warned",           // Warning flags (WARN_ON_ONCE)
        "__already_done.",    // Initialization guards
        "__func__",           // Function name strings
        "__FUNCTION__",
        "_rs",                // Restart section markers
        "CSWTCH",             // Coverity markers
        "_entry",             // Section entry markers
        NULL
    };

    // pr_debug() dynamic debug variables
    if (is_dynamic_debug_symbol(sym))
        return true;

    // .data.once section (one-time initialization)
    if (!strcmp(sym->sec->name, ".data.once") ||
        !strcmp(sym->sec->name, ".data..once"))
        return true;

    // Check known variable name patterns
    for (var_name = var_names; *var_name; var_name++) {
        // GCC style: __key.number
        snprintf(buf, sizeof(buf), ".%s.", *var_name);
        if (!strncmp(sym->name, buf + 1, strlen(*var_name) + 1))
            return true;

        // Clang style: function.__key
        buf[strlen(*var_name) + 1] = '\0';
        if (strstr(sym->name, buf))
            return true;
    }
}
```

**Why special handling:**
- `__warned`: Used by WARN_ON_ONCE to prevent repeated warnings
- `__key`: Lockdep keys, must be unique per instance
- These should always be included if referenced, never correlated

---

## ELF Structure Manipulation

### Section Status State Machine

```c
enum status {
    NEW,       // Only in patched version
    CHANGED,   // Modified in patched version
    SAME       // Identical in both versions
};
```

**Status transitions:**
```
Initial: All sections → UNKNOWN
     ↓
kpatch_correlate_elfs()
     ↓
  Correlated → PENDING_COMPARE
  Uncorrelated → NEW
     ↓
kpatch_compare_sections()
     ↓
  Data same, Relas same → SAME
  Data different OR Relas different → CHANGED
     ↓
kpatch_mark_ignored_sections()
     ↓
  Debug sections → IGNORED
  .altinstr_aux (x86) → IGNORED
  etc.
```

### Relocation Comparison

**Function:** `rela_equal()` (lines 557-645)

```c
static bool rela_equal(struct rela *rela1, struct rela *rela2)
{
    struct rela *rela_toc1, *rela_toc2;

    // Basic comparison
    if (rela1->type != rela2->type ||
        rela1->offset != rela2->offset)
        return false;

    // Special case: x86 .altinstr_aux
    // Static CPU has alternative code that's inert for modules
    if (!strcmp(rela1->sym->name, ".altinstr_aux") &&
        !strcmp(rela2->sym->name, ".altinstr_aux"))
        return true;  // Ignore addend differences

    // Special case: PPC64 TOC indirection
    // TOC offsets may change, so dereference to actual target
    rela_toc1 = toc_rela(rela1);
    rela_toc2 = toc_rela(rela2);

    if (rela_toc1 && rela_toc2) {
        // Compare the actual target, not TOC offset
        return (rela_toc1->sym == rela_toc2->sym) &&
               (rela_toc1->addend == rela_toc2->addend);
    }

    // Standard comparison
    return (rela1->sym == rela2->sym) &&
           (rela1->addend == rela2->addend);
}
```

### PPC64 TOC Handling

**The Problem:**
PPC64 uses a Table of Contents (TOC) for data access:

```assembly
# PPC64 function accessing global variable:
function:
    .quad .TOC.-function    # TOC anchor (8 bytes)
    ld r2,-8(r12)           # Load TOC base into r2
    add r2,r2,r12           # Adjust TOC pointer

    # Data access via TOC:
    ld r3, TOC_offset(r2)   # Load from variable via TOC
```

**Two-level relocation:**
```c
// Level 1: Function → TOC
R_PPC64_TOC16_HA  .toc + 138  # High 16 bits of offset
R_PPC64_TOC16_LO_DS .toc + 138  # Low 16 bits + offset

// Level 2: TOC → Actual data
R_PPC64_ADDR64  .text.target_function + 8
```

**TOC Dereferencing:**
```c
static struct rela *toc_rela(const struct rela *rela)
{
    if (rela->type != R_PPC64_TOC16_HA &&
        rela->type != R_PPC64_TOC16_LO_DS)
        return (struct rela *)rela;  // Not a TOC rela

    // Follow the indirection
    if (!rela->sym->sec->rela)
        return NULL;  // TOC constant, no relocation

    // Find the TOC entry's relocation
    return find_rela_by_offset(rela->sym->sec->rela,
                               (unsigned int)rela->addend);
}
```

### ARM64 Mapping Symbols

ARM64 uses special "$x" and "$d" symbols to mark code/data boundaries:

```c
static bool kpatch_is_mapping_symbol(struct kpatch_elf *kelf,
                                      struct symbol *sym)
{
    switch (kelf->arch) {
    case AARCH64:
        // $x = code start, $d = data start
        if (sym->name && sym->name[0] == '$' &&
            sym->type == STT_NOTYPE &&  // No type
            sym->bind == STB_LOCAL)     // Local binding
            return true;
    // ... other architectures don't use mapping symbols
    }
}
```

**Why skip these:**
- They don't represent actual symbols
- All have name "$x" or "$d"
- Would cause false correlation failures

### ARM64 BTI Padding Detection

**Function:** `function_padding_size()` (lines 261-295)

With CONFIG_DYNAMIC_FTRACE_WITH_CALL_OPS, ARM64 adds padding:

```assembly
# Before function:
    NOP                     # Padding byte 0
    NOP                     # Padding byte 1
# Function start:
    BTI C                   # Branch Target Identification
    NOP                     # Padding byte 2
    NOP                     # Padding byte 3
    ; actual function code
```

```c
static unsigned int function_padding_size(struct kpatch_elf *kelf,
                                          struct symbol *sym)
{
    if (kelf->arch != AARCH64)
        return 0;

    uint8_t *insn = sym->sec->data->d_buf;
    unsigned int i;

    // Count leading NOPs (0x1f, 0x20, 0x03, 0xd5)
    for (i = 0; (void *)insn < insn_end; i++, insn += 4) {
        if (insn[0] != 0x1f || insn[1] != 0x20 ||
            insn[2] != 0x03 || insn[3] != 0xd5)
            break;
    }

    if (i == 2)
        return 8;  // Two NOPs before function
    else if (i != 0)
        log_error("function %s has invalid padding\n", sym->name);

    return 0;
}
```

---

## Symbol Resolution Strategies

### KLP Special Symbols

kpatch creates special symbols for the kernel's KLP subsystem:

```c
#define KLP_SYM_PREFIX         ".klp.sym."
#define KLP_RELASEC_PREFIX     ".klp.rela."
#define SHF_RELA_LIVEPATCH     0x00100000
#define SHN_LIVEPATCH          0xff20
```

**Symbol format:**
```
.klp.sym.vmlinux.function_name,0
.klp.sym.module_name.variable_name,123
```

**Usage:**
1. **Symbol references:** When patch references non-exported symbol
2. **Relocations:** `.klp.rela.vmlinux.text.function_name` sections
3. **Section flag:** `SHF_RELA_LIVEPATCH` marks KLP relocations
4. **Section index:** `SHN_LIVEPATCH` for KLP-specific symbols

### Lookup Table

**Structure:** `lookup.h`

```c
struct lookup_result {
    char *objname;       // "vmlinux" or module name
    unsigned long addr;  // Symbol address in kernel
    unsigned long size;  // Symbol size
    unsigned long sympos;// Position (for duplicate symbols)
    bool global;         // Is global symbol
    bool exported;       // Is exported (available to modules)
};
```

**Sources:**
- `/proc/kallsyms` - Runtime symbol table
- `System.map` - Build-time symbol map
- `Module.symvers` - Module version/exported symbols

### Symbol Position Handling

For duplicate symbols (same name, different locations):

```c
// kpatch_find_func() in core.c
static int klp_find_callback(void *data, const char *name,
                              unsigned long addr)
{
    struct klp_find_arg *args = data;

    if (strcmp(name, args->name) != 0)
        return 0;

    args->addr = addr;
    args->count++;

    // Stop when we find the requested position
    if ((args->pos && (args->count == args->pos)) ||
        (!args->pos && (args->count > 1)))
        return 1;  // Found it

    return 0;  // Keep searching
}
```

**Example:**
```c
// Multiple functions named "read" in different files:
//   read @ fs/read.c:0x1234
//   read @ net/socket.c:0x5678
//   read @ drivers/char/misc.c:0x9abc

struct klp_func func = {
    .old_name = "read",
    .old_sympos = 2,  // Want net/socket.c::read
    .new_func = new_socket_read,
};
```

---

## Ftrace Integration Details

### klp_ops Structure

```c
struct klp_ops {
    struct list_head node;        // Global klp_ops list
    struct list_head func_stack;  // Stack of klp_func (newest first)
    struct ftrace_ops fops;       // Ftrace operations
};
```

**Key insight:** Multiple patches can stack on same function

```
klp_ops for "do_sys_open":
┌─────────────────────────────────┐
│ func_stack (newest → oldest)    │
├─────────────────────────────────┤
│ patch3_func (replaces all)     │ ← Top of stack
│ patch2_func                     │
│ patch1_func                     │
│ NULL (original function)        │ ← Bottom (implicit)
└─────────────────────────────────┘
```

### Ftrace Handler (Critical Path)

**Location:** `kernel/livepatch/patch.c:40-125`

```c
static void notrace klp_ftrace_handler(unsigned long ip,
                                       unsigned long parent_ip,
                                       struct ftrace_ops *fops,
                                       struct ftrace_regs *fregs)
{
    struct klp_ops *ops;
    struct klp_func *func;
    int patch_state;
    int bit;

    ops = container_of(fops, struct klp_ops, fops);

    // Recursion prevention (required for RCU usage)
    bit = ftrace_test_recursion_trylock(ip, parent_ip);
    if (WARN_ON_ONCE(bit < 0))
        return;

    // Get newest function from stack
    func = list_first_or_null_rcu(&ops->func_stack, struct klp_func,
                                  stack_node);
    if (WARN_ON_ONCE(!func))
        goto unlock;

    // Memory barrier: read func_stack before func->transition
    smp_rmb();

    if (unlikely(func->transition)) {
        // Transition in progress - check task state
        smp_rmb();  // Order: transition before patch_state
        patch_state = current->patch_state;

        WARN_ON_ONCE(patch_state == KLP_TRANSITION_IDLE);

        if (patch_state == KLP_TRANSITION_UNPATCHED) {
            // This task hasn't switched yet - use previous version
            func = list_entry_rcu(func->stack_node.next,
                                  struct klp_func, stack_node);

            // Reached end of stack = no previous patch = use original
            if (&func->stack_node == &ops->func_stack)
                goto unlock;
        }
    }

    // NOP patches revert to original code
    if (func->nop)
        goto unlock;

    // Redirect to new function
    ftrace_regs_set_instruction_pointer(fregs,
                                       (unsigned long)func->new_func);

unlock:
    ftrace_test_recursion_unlock(bit);
}
```

**Performance characteristics:**
- **Hot path:** Executed on every patched function call
- **Branch prediction:** `unlikely()` on transition check
- **Memory barriers:** Only during transition
- **RCU read-side:** Very fast in steady state

### Function Registration

**Function:** `klp_patch_func()` (lines 160-228)

```c
static int klp_patch_func(struct klp_func *func)
{
    struct klp_ops *ops;
    int ret;

    // Find existing ops for this function
    ops = klp_find_ops(func->old_func);

    if (!ops) {
        // First patch for this function - create new ops
        unsigned long ftrace_loc;

        ftrace_loc = ftrace_location((unsigned long)func->old_func);
        if (!ftrace_loc)
            return -EINVAL;

        ops = kzalloc(sizeof(*ops), GFP_KERNEL);
        if (!ops)
            return -ENOMEM;

        // Configure ftrace ops
        ops->fops.func = klp_ftrace_handler;
        ops->fops.flags = FTRACE_OPS_FL_DYNAMIC   // Dynamic allocation
                            | FTRACE_OPS_FL_IPMODIFY  // Modifies IP
                            | FTRACE_OPS_FL_PERMANENT; // Can't be removed

        list_add(&ops->node, &klp_ops);
        INIT_LIST_HEAD(&ops->func_stack);
        list_add_rcu(&func->stack_node, &ops->func_stack);

        // Set ftrace filter and register
        ret = ftrace_set_filter_ip(&ops->fops, ftrace_loc, 0, 0);
        if (ret)
            goto err;

        ret = register_ftrace_function(&ops->fops);
        if (ret) {
            ftrace_set_filter_ip(&ops->fops, ftrace_loc, 1, 0);
            goto err;
        }
    } else {
        // Existing ops - stack new function
        list_add_rcu(&func->stack_node, &ops->func_stack);
    }

    func->patched = true;
    return 0;

err:
    list_del_rcu(&func->stack_node);
    list_del(&ops->node);
    kfree(ops);
    return ret;
}
```

---

## Consistency Model Internals

### Task State Machine

```c
// Per-task patch state
struct task_struct {
    ...
    int patch_state;  // KLP_TRANSITION_*
    ...
};

enum klp_transition_state {
    KLP_TRANSITION_IDLE = -1,
    KLP_TRANSITION_UNPATCHED = 0,
    KLP_TRANSITION_PATCHED = 1,
};
```

**State transitions for a single task:**

```
┌─────────────────────────────────────────────────────────────┐
│                    Task Patch State                         │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│   Before patch:                                             │
│   All tasks → KLP_TRANSITION_IDLE                          │
│                                                             │
│   klp_init_transition(KLP_TRANSITION_PATCHED):              │
│   All tasks → KLP_TRANSITION_UNPATCHED                      │
│   Set func->transition = true for all functions             │
│                                                             │
│   klp_try_complete_transition():                            │
│   For each task:                                            │
│     ┌───────────────────────────────────────────────────┐   │
│     │ If stack safe (no patched functions in use):      │   │
│     │   task->patch_state = KLP_TRANSITION_PATCHED      │   │
│     │                                                   │   │
│     │ If task in userspace:                             │   │
│     │   Can switch immediately                           │   │
│     │                                                   │   │
│     │ If task sleeping in kernel:                       │   │
│     │   Will switch on wakeup                           │   │
│     │                                                   │   │
│     │ If task running in kernel:                        │   │
│     │   Must wait for safe point                         │   │
│     └───────────────────────────────────────────────────┘   │
│                                                             │
│   All tasks switched → klp_complete_transition():          │
│   Set func->transition = false                             │
│   All tasks → KLP_TRANSITION_IDLE                          │
└─────────────────────────────────────────────────────────────┘
```

### Stack Checking

**Function:** `klp_check_stack()` (kernel/livepatch/transition.c)

```c
static int klp_check_stack(struct task_struct *task, unsigned long *entries)
{
    int ret;

    // Get reliable stack trace
    ret = stack_trace_save_tsk_reliable(task, entries, STACK_TRACE_NR);

    if (ret < 0)
        return ret;  // Can't get stack trace

    // Check each stack frame
    for (i = 0; i < ret; i++) {
        if (entries[i] == func_addr)
            return -EADDRINUSE;  // Function is on stack!
    }

    return 0;  // Safe to switch
}
```

**Why reliable stack trace matters:**
- Normal stack trace may include stale frames
- `HAVE_RELIABLE_STACKTRACE` ensures accuracy
- Critical for safety: can't patch function that's on stack

### Multiple Switching Mechanisms

**1. Stack checking (primary, with HAVE_RELIABLE_STACKTRACE):**
```c
// In klp_try_complete_transition()
for_each_process_thread(g, task) {
    if (task->patch_state == klp_target_state)
        continue;

    // Try to switch this task
    if (klp_try_switch_task(task))
        tasks_to_switch--;
}
```

**2. Kernel exit switching (fallback):**
```c
// In exit_to_user_mode_loop()
klp_update_patch_state(current);
```

**3. Scheduler-based switching:**
```c
// In __schedule()
__klp_sched_try_switch(current);
```

### TIF_PATCH_PENDING Flag

```c
// Thread flag indicates pending patch state update
#define TIF_PATCH_PENDING    9   // x86_64
#define TIF_PATCH_PENDING    13  // ARM64

// Setting flag (klp_start_transition):
set_tsk_thread_flag(task, TIF_PATCH_PENDING);

// Clearing flag (klp_update_patch_state):
if (test_and_clear_tsk_thread_flag(task, TIF_PATCH_PENDING))
    task->patch_state = READ_ONCE(klp_target_state);
```

**Purpose:** Deferred state update until safe point

---

## Memory Ordering and Concurrency

### Memory Barriers in Handler

```c
// In klp_ftrace_handler()

// Barrier 1: Read func_stack before func->transition
smp_rmb();

if (unlikely(func->transition)) {
    // Barrier 2: Read transition before patch_state
    smp_rmb();
    patch_state = current->patch_state;
    ...
}
```

**Corresponding write barriers:**

```c
// In __klp_enable_patch() (core.c)
list_add_rcu(&func->stack_node, &ops->func_stack);
smp_wmb();  // Write barrier 1
func->transition = true;

// In klp_init_transition() (transition.c)
for_each_process_thread(g, task)
    task->patch_state = KLP_TRANSITION_UNPATCHED;
smp_wmb();  // Ensure all tasks initialized
for_each_function(func)
    func->transition = true;  // Write barrier 2
```

**Why these barriers exist:**

1. **Barrier 1:** Ensure we see complete func_stack before checking transition
   - Without: Could read partially updated stack
   - Scenario: Task sees func but not yet on stack → NULL dereference

2. **Barrier 2:** Ensure we see complete transition state before reading task state
   - Without: Could see transition=true but stale patch_state
   - Scenario: Task switches to PATCHED but ftrace handler sees UNPATCHED

### RCU Usage

```c
// func_stack is RCU-protected
list_first_or_null_rcu(&ops->func_stack, struct klp_func, stack_node);

// Removal uses RCU
list_del_rcu(&func->stack_node);

// Synchronization before freeing
synchronize_rcu();  // Or call_rcu()
```

**Why RCU:**
- Handler runs in preempt-disable context
- Can't use mutexes (would sleep)
- RCU provides lock-free read-side access

### Recursion Prevention

```c
// In klp_ftrace_handler()
bit = ftrace_test_recursion_trylock(ip, parent_ip);
if (WARN_ON_ONCE(bit < 0))
    return;
// ... handler code ...
ftrace_test_recursion_unlock(bit);
```

**Why needed:**
- Prevents infinite recursion if ftrace calls itself
- Enables `synchronize_rcu()` variant that works in RCU-off sections
- Required for `klp_synchronize_transition()`

---

## Architecture-Specific Implementations

### x86_64 Specifics

**Fentry instrumentation:**
```assembly
# Function prologue with -mfentry:
func:
    call __fentry__  ; 5-byte call (can be patched to jmp)
    push rbp
    mov rbp, rsp
    ; function body
```

**Alternative instructions:**
```c
// .altinstr_aux handling
if (!strcmp(rela->sym->name, ".altinstr_aux") &&
    !strcmp(rela2->sym->name, ".altinstr_aux"))
    return true;  // Ignore addend differences
```

**Reason:** Alternative instructions are applied during boot, inert for modules.

### ARM64 Specifics

**Fpatchable function entry:**
```assembly
# With -fpatchable-function-entry=2:
func:
    NOP  ; Padding byte 0 (for ftrace)
    NOP  ; Padding byte 1 (for ftrace)
    ; actual function prologue
```

**BTI (Branch Target Identification):**
```assembly
# With CONFIG_ARM64_BTI_KERNEL
    BTI C   ; Branch target to code (must be first instruction)
```

**Mapping symbols:**
```c
// $x marks code, $d marks data
.section .text
$x:  ; Code starts here
    mov x0, #0
    ret

.section .rodata
$d:  ; Data starts here
    .word 0x12345678
```

### PPC64 Specifics

**TOC (Table of Contents) handling:**
```c
// Two-level relocations
R_PPC64_TOC16_HA  .toc + offset    ; High 16 bits of TOC offset
R_PPC64_TOC16_LO_DS .toc + offset   ; Low 16 bits of TOC offset

// TOC entry points to actual target
R_PPC64_ADDR64  .text.actual_function + 8
```

**Local entry point:**
```c
// GCC6+ has global and local entry points
#define PPC64_LOCAL_ENTRY_OFFSET(other) \
    (((1 << (((other) & STO_PPC64_LOCAL_MASK) >> STO_PPC64_LOCAL_BIT)) >> 2) << 2)

// Check if symbol has 8-byte local entry offset
static bool is_gcc6_localentry_bundled_sym(struct kpatch_elf *kelf,
                                            struct symbol *sym)
{
    if (kelf->arch != PPC64)
        return false;

    return ((PPC64_LOCAL_ENTRY_OFFSET(sym->sym.st_other) != 0) &&
            (sym->sym.st_value == 8));
}
```

### S390 Specifics

**Alternative instruction handling similar to x86**

**Special relocation types:**
- R_390_PLT32DBL
- R_390_GOTENT
- Architecture-specific GOT/PLT handling

---

## Edge Cases and Pitfalls

### __LINE__ Macro Changes

```c
// Function that only changes due to __LINE__:
static int foo(void) {
    printk("Line: %d\n", __LINE__);  // Changes with every edit!
    return 0;
}
```

**Detection:** `insn_is_load_immediate()` (lines 742-810)

```c
// Architecture-specific immediate load detection
static bool insn_is_load_immediate(struct kpatch_elf *kelf, void *addr)
{
    switch (kelf->arch) {
    case X86_64:
        // mov $imm, %reg
        return (insn[0] == 0x48 || insn[0] == 0x49) &&
               (insn[1] >= 0xb8 && insn[1] <= 0xbf);

    case AARCH64:
        // movz/movk #imm
        return (insn[0] & 0x1f) >= 0x10 && (insn[0] & 0x1f) <= 0x13;

    // ... other architectures
    }
}
```

**Handling:** Mark as SAME if only immediate loads changed.

### Static Data Changes

```c
// PROBLEMATIC: Changing static data
static int counter = 0;

static int increment(void) {
    return counter++;
}
```

**Why problematic:**
- Old functions expect old data layout
- New functions expect new data layout
- Can't safely switch between them

**Solutions:**
1. **Shadow variables:** Attach new data to existing structure
2. **Callbacks:** Use pre_patch to convert old data
3. **Redesign:** Avoid static data where possible

### Init Function Patching

```c
// CANNOT PATCH: __init functions
static int __init early_init(void) {
    // Runs at boot, already executed
    return 0;
}
```

**Detection:**
```c
// In kpatch_verify_patchability()
if (strsym->name && !strcmp(strsym->name, "__init"))
    ERROR("Can't patch __init function");
```

**Reason:** Functions already executed, can't safely patch.

### Function Signature Changes

```c
// Original:
int foo(int x, int y);

// Patched:
int foo(int x, int y, int z);  // CANNOT DO THIS
```

**Why not:**
- Changes calling convention
- Breaks existing callers
- Stack layout changes

**Workaround:** Create new function, patch call sites.

### Inline Function Changes

```c
// Header file:
static inline int fast_path(void) {
    return compute_fast();
}

// If fast_path() changes:
// - All callers get recompiled
// - Multiple .o files change
// - kpatch must include ALL of them
```

**Detection:** kpatch-build detects recompiled files
**Handling:** Include all changed objects in patch

---

## Performance Considerations

### Ftrace Handler Overhead

**Steady state (no transition):**
```
Original function:     100 cycles (baseline)
Ftrace overhead:       +5 cycles   (fentry + handler)
Total:                105 cycles  (5% overhead)
```

**During transition:**
```
Original function:     100 cycles
Ftrace overhead:       +10 cycles  (extra checks + memory barriers)
Total:                110 cycles  (10% overhead)
```

**Optimizations:**
- `unlikely()` on transition check
- RCU for lock-free read-side
- Recursion lock is fast (per-CPU bitmap)

### Patch Size Impact

**Typical patch module:**
```
Single function change:        ~10 KB
Multi-function fix:            ~50-100 KB
Cumulative security update:    ~500 KB - 1 MB
```

**Components:**
- New function code: ~1-5 KB per function
- String table: ~1-10 KB
- Relocation sections: ~5-20 KB
- Metadata: ~1-5 KB

### Build Time Impact

**kpatch-build time:**
```
Small patch (1-5 functions):   ~30 seconds
Medium patch (5-20 functions): ~2 minutes
Large patch (20+ functions):    ~5 minutes
Cumulative patch:              ~10 minutes
```

**Time breakdown:**
- Kernel build: ~80%
- create-diff-object: ~10%
- Linking/processing: ~10%

### Runtime Memory Impact

**Per-patch memory:**
```
Patch module code:        ~10-100 KB
klp_func structures:      ~100 bytes per function
klp_ops structures:       ~100 bytes per patched function
Stack entries:            ~50 bytes per stacked patch
```

**Example:** 10 cumulative patches
- Total memory: ~1-5 MB
- Minimal for modern systems

---

## Summary

**Key insights from this deep dive:**

1. **Binary differencing is complex:**
   - Must handle compiler optimizations (cold/part functions)
   - Architecture-specific quirks (TOC, BTI, alternatives)
   - Symbol correlation with mangled names

2. **Consistency model is sophisticated:**
   - Multiple switching mechanisms for safety
   - Memory barriers prevent race conditions
   - Stack checking prevents inconsistent state

3. **Ftrace integration is elegant:**
   - Hot path is optimized
   - Stacking enables cumulative patches
   - RCU enables lock-free read-side

4. **Architecture support varies:**
   - x86_64: Most mature
   - ARM64: Good support, BTI considerations
   - PPC64: TOC indirection complexity
   - ARM32: Missing infrastructure

5. **Safety is paramount:**
   - Compiler version matching
   - Init function exclusion
   - Static data restrictions
   - Comprehensive verification

---

**Next topics for study:**
- Shadow variable implementation details
- State versioning and compatibility checking
- Callback execution order and semantics
- Integration with module loader
- Testing strategies and edge case coverage

---

<!--
Source: kpatch git repository and Linux kernel source
Analysis based on: v6.19-rc5
Date: 2026-02-03
-->
