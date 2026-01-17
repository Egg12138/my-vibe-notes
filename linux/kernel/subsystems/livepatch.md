# Linux Kernel Livepatch Subsystem

> Comprehensive analysis of kernel live patching architecture, implementation, and architecture-specific support

---

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Data Structures](#data-structures)
4. [Workflow and Dataflow](#workflow-and-dataflow)
5. [Consistency Model](#consistency-model)
6. [Function Redirection](#function-redirection)
7. [Special Features](#special-features)
8. [Architecture Comparison](#architecture-comparison)
9. [Key Functions Reference](#key-functions-reference)

---

## Overview

**Livepatch** enables runtime patching of kernel functions without rebooting. It uses ftrace to redirect function calls to new implementations while maintaining system consistency through a sophisticated transition model.

### Key Benefits
- Zero-downtime security patches
- No system reboot required
- Safe per-task transition mechanism
- Cumulative patch support

### Directory Structure
```
kernel/livepatch/
├── core.c          - Main orchestration (1369 lines)
├── transition.c    - Consistency model (732 lines)
├── patch.c         - Ftrace integration (290 lines)
├── state.c         - State tracking (120 lines)
└── shadow.c        - Shadow variables (300 lines)
```

---

## Architecture

### Component Diagram

```
┌─────────────────────────────────────────────────────────┐
│                    Livepatch Architecture                │
├─────────────────────────────────────────────────────────┤
│                                                          │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐          │
│  │ Core     │◄───┤Transition│◄───┤  State   │          │
│  │          │───►│          │───►│          │          │
│  └────┬─────┘    └────┬─────┘    └──────────┘          │
│       │               │                                   │
│       ▼               ▼                                   │
│  ┌──────────┐    ┌──────────┐                            │
│  │  Patch   │───►│  Shadow  │                            │
│  │          │    │          │                            │
│  └────┬─────┘    └──────────┘                            │
│       │                                                    │
│       ▼                                                    │
│  ┌──────────────────────────────────────┐                │
│  │         Ftrace Subsystem             │                │
│  │  ┌────────────────────────────────┐ │                │
│  │  │ klp_ftrace_handler()            │ │                │
│  │  └────────────────────────────────┘ │                │
│  └──────────────────────────────────────┘                │
│                       │                                    │
│                       ▼                                    │
│  ┌──────────────────────────────────────┐                │
│  │    Task State Management             │                │
│  │  • task->patch_state                 │                │
│  │  • TIF_PATCH_PENDING                 │                │
│  │  • klp_update_patch_state()          │                │
│  └──────────────────────────────────────┘                │
│                                                          │
└─────────────────────────────────────────────────────────┘
```

### Global State

```c
// kernel/livepatch/core.c
DEFINE_MUTEX(klp_mutex);              // Serializes all klp operations
LIST_HEAD(klp_patches);               // Active patches list
struct klp_patch *klp_transition_patch; // Current transitioning patch
int klp_target_state;                 // Target state for transition
```

---

## Data Structures

### Hierarchy

```
klp_patch (Top-level patch container)
    │
    ├── klp_object[] (Kernel objects: vmlinux or modules)
    │       │
    │       ├── klp_func[] (Functions to patch)
    │       │
    │       └── callbacks (pre/post patch hooks)
    │
    └── klp_state[] (System state modifications)
```

### struct klp_patch

**Location**: `include/linux/livepatch.h:135-150`

```c
struct klp_patch {
    /* External fields (user-defined) */
    struct module *mod;              // Livepatch module reference
    struct klp_object *objs;         // Array of objects to patch
    struct klp_state *states;        // System state modifications
    bool replace;                    // Atomic replace flag

    /* Internal fields (kernel-managed) */
    struct list_head list;           // Global patch list node
    struct kobject kobj;             // Sysfs integration
    struct list_head obj_list;       // Dynamic object list
    bool enabled;                    // Patch enabled state
    bool forced;                     // Was forced transition used
    struct work_struct free_work;    // Async cleanup work
    struct completion finish;        // Completion for cleanup
};
```

### struct klp_object

**Location**: `include/linux/livepatch.h:94-107`

```c
struct klp_object {
    /* External fields */
    const char *name;                // Module name (NULL = vmlinux)
    struct klp_func *funcs;          // Functions to patch
    struct klp_callbacks callbacks;  // Pre/post (un)patch callbacks

    /* Internal fields */
    struct kobject kobj;
    struct list_head func_list;      // Dynamic function list
    struct list_head node;
    struct module *mod;              // Target module (if loaded)
    bool dynamic;                    // Dynamically allocated (for NOPs)
    bool patched;                    // Object patching state
};
```

### struct klp_func

**Location**: `include/linux/livepatch.h:57-79`

```c
struct klp_func {
    /* External fields */
    const char *old_name;            // Original function name
    void *new_func;                  // New function pointer
    unsigned long old_sympos;        // Symbol position (for duplicates)

    /* Internal fields */
    void *old_func;                  // Resolved old function address
    struct kobject kobj;
    struct list_head node;
    struct list_head stack_node;     // For klp_ops func_stack
    unsigned long old_size, new_size;
    bool nop;                        // NOP patch (revert to original)
    bool patched;                    // Function patching state
    bool transition;                 // In transition state
};
```

### struct klp_state

**Location**: `include/linux/livepatch.h:115-119`

```c
struct klp_state {
    unsigned long id;                // State identifier
    unsigned int version;            // Version of the change
    void *data;                      // Custom state data
};
```

### struct klp_ops (Internal)

**Location**: `kernel/livepatch/patch.h:22-26`

```c
struct klp_ops {
    struct list_head node;           // Global klp_ops list
    struct list_head func_stack;     // Stack of klp_func (newest on top)
    struct ftrace_ops fops;          // Ftrace ops structure
};
```

---

## Workflow and Dataflow

### Enable Patch Flow

```
┌─────────────────────────────────────────────────────────────┐
│                    klp_enable_patch()                       │
│                    (kernel/livepatch/core.c:1108)          │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│  1. VALIDATION                                              │
│  ├─── Validate patch structure (mod, objs exist)           │
│  ├─── Check module is marked as livepatch                  │
│  └─── Check patch compatibility with existing patches      │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│  2. INITIALIZATION                                          │
│  ├─── klp_init_patch_early() - Initialize kobjects         │
│  ├─── klp_init_patch() - Set up sysfs, resolve symbols    │
│  └─── If replace=true: Add NOP functions for old patches  │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│  3. TRANSITION START                                        │
│  ├─── klp_init_transition(KLP_TRANSITION_PATCHED)         │
│  │       ├─── Set klp_target_state = PATCHED               │
│  │       └─── Initialize all tasks to UNPATCHED            │
│  │                                                         │
│  ├─── klp_patch_object() - Register ftrace handlers       │
│  │       └─── klp_patch_func()                             │
│  │           ├─── Find/create klp_ops                      │
│  │           ├─── Set up ftrace_ops                        │
│  │           └─── register_ftrace_function()               │
│  │                                                         │
│  └─── klp_start_transition()                               │
│      └─── Set TIF_PATCH_PENDING on all tasks              │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│  4. TASK SWITCHING (periodic)                               │
│  ┌───────────────────────────────────────────────────────┐ │
│  │ klp_try_complete_transition()                         │ │
│  │       │                                               │ │
│  │       └─── For each task: klp_try_switch_task()       │ │
│  │              │                                        │ │
│  │              ├─── klp_check_stack()                   │ │
│  │              │       └─── stack_trace_save_tsk_reliable() │
│  │              │                                        │ │
│  │              └─── If safe: set task->patch_state     │ │
│  └───────────────────────────────────────────────────────┘ │
│      │                                                      │
│      └─── Retry every second until all tasks switched      │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│  5. COMPLETE                                                │
│  ┌───────────────────────────────────────────────────────┐ │
│  │ klp_complete_transition()                             │ │
│  │       ├─── If replace=true: Unpatch old patches      │ │
│  │       ├─── Clear func->transition for all funcs      │ │
│  │       ├─── Reset all tasks to KLP_TRANSITION_IDLE    │ │
│  │       └─── Call post_patch callbacks                 │ │
│  └───────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

### Ftrace Handler Flow

```
┌─────────────────────────────────────────────────────────────┐
│          When patched function is called                    │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  caller()                                                  │
│     │                                                       │
│     │  call old_function   ────────┐                       │
│     │                          │  Original function        │
│     ▼                          ▼  entry point             │
│  old_function:                  │                         │
│     │                          │                         │
│     │  [ftrace hook]            │                         │
│     │     │                     │                         │
│     │     ▼                     │                         │
│     │  klp_ftrace_handler() ────┘                         │
│     │     │                                                  │
│     │     ├──► Get func from top of ops->func_stack         │
│     │     │                                                  │
│     │     ├──► If func->transition == true:                 │
│     │     │       │                                          │
│     │     │       └──► Check current->patch_state          │
│     │     │               │                                  │
│     │     │               ├──► UNPATCHED: use next func     │
│     │     │               └──► PATCHED: use this func      │
│     │     │                                                  │
│     │     ├──► If func->nop == true: do nothing            │
│     │     │                                                  │
│     │     └──► ftrace_regs_set_ip(fregs, func->new_func)   │
│     │                   │                                    │
│     └───────────────────┘                                    │
│                          │                                    │
│                          ▼                                    │
│                     new_function()                            │
│                          │                                    │
│                          └──► return to caller               │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

---

## Consistency Model

### Overview

Livepatch uses a **hybrid consistency model** combining:
- **kGraft's** per-task consistency
- **kpatch's** stack trace checking

### Task Patch States

| State | Value | Description |
|-------|-------|-------------|
| `KLP_TRANSITION_IDLE` | -1 | No transition in progress |
| `KLP_TRANSITION_UNPATCHED` | 0 | Task uses old code |
| `KLP_TRANSITION_PATCHED` | 1 | Task uses new code |

### Transition Mechanisms

```
┌─────────────────────────────────────────────────────────────┐
│                    Task Switching Mechanisms                │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  1. STACK CHECKING (Primary - HAVE_RELIABLE_STACKTRACE)    │
│  ┌───────────────────────────────────────────────────────┐ │
│  │ klp_try_switch_task()                                 │ │
│  │       │                                               │ │
│  │       └──► klp_check_stack(task)                      │ │
│  │               │                                       │ │
│  │               └──► stack_trace_save_tsk_reliable()    │ │
│  │                       │                               │ │
│  │                       └──► Check if any patched       │ │
│  │                           function is on stack        │ │
│  │                                                             │
│  │  If safe: set task->patch_state = target               │ │
│  └───────────────────────────────────────────────────────┘ │
│                                                             │
│  2. KERNEL EXIT SWITCHING (Fallback)                        │
│  ┌───────────────────────────────────────────────────────┐ │
│  │ exit_to_user_mode_loop()                              │ │
│  │       │                                               │ │
│  │       └──► klp_update_patch_state(current)            │ │
│  │               │                                       │ │
│  │               └──► test_and_clear_tsk_thread_flag(    │ │
│  │                       TIF_PATCH_PENDING)              │ │
│  │                   │                                   │ │
│  │                   └──► task->patch_state = target     │ │
│  └───────────────────────────────────────────────────────┘ │
│                                                             │
│  3. SCHEDULER-BASED SWITCHING                               │
│  ┌───────────────────────────────────────────────────────┐ │
│  │ __schedule()                                          │ │
│  │       │                                               │ │
│  │       └──► __klp_sched_try_switch()                   │ │
│  │               │                                       │ │
│  │               └──► klp_try_switch_task(current)       │ │
│  └───────────────────────────────────────────────────────┘ │
│                                                             │
│  4. IDLE TASK SWITCHING                                     │
│  ┌───────────────────────────────────────────────────────┐ │
│  │ Idle loop includes klp_update_patch_state() call     │ │
│  └───────────────────────────────────────────────────────┘ │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### Transition State Machine

```
Enable Transition (Patching):
All Tasks: UNPATCHED ──────────────────────────────► PATCHED
                   │                                    │
                   │  klp_init_transition(KLP_PATCHED)   │
                   │  klp_start_transition()             │
                   │  Set TIF_PATCH_PENDING              │
                   │                                    │
                   └───► klp_try_complete_transition() ──┘
                            │                            │
                            │  For each task:            │
                            │  Check stack, switch       │
                            │  if safe                    │
                            │                            │
                            └───► All tasks switched ────┘
                                                    │
                                                    ▼
                                         klp_complete_transition()
                                                    │
                                                    └──► All tasks: IDLE

Disable Transition (Unpatching):
Same process in reverse: PATCHED ──► UNPATCHED
```

### Special Cases

**Forked Tasks**: Inherit parent's patch_state and TIF_PATCH_PENDING flag

**Interrupt Handlers**: Inherit the patched state of the task they interrupt

**Force Transition**:
- Sysfs interface: `/sys/kernel/livepatch/<patch>/force`
- Immediately switches all tasks to target state
- Sets `patch->forced = true`
- **Permanently disables module removal**

---

## Function Redirection

### klp_ftrace_handler()

**Location**: `kernel/livepatch/patch.c:40-125`

**Critical path**: Called on every patched function invocation

```c
static void notrace klp_ftrace_handler(unsigned long ip,
                                       unsigned long parent_ip,
                                       struct ftrace_ops *fops,
                                       struct ftrace_regs *fregs)
{
    struct klp_ops *ops = container_of(fops, struct klp_ops, fops);
    struct klp_func *func;

    // Get first (newest) function from stack
    func = list_first_entry(&ops->func_stack, struct klp_func, stack_node);

    // Memory barrier - ensure we see latest state
    smp_rmb();

    // If in transition, check task's patch state
    if (func->transition) {
        smp_rmb();

        // If task is unpatched, use next function in stack
        if (current->patch_state == KLP_TRANSITION_UNPATCHED) {
            if (list_is_last(&func->stack_node, &ops->func_stack))
                return; // No more functions, run original
            func = list_next_entry(func, stack_node);
        }
    }

    // If NOP, do nothing (run original code)
    if (func->nop)
        return;

    // Redirect to new function
    ftrace_regs_set_instruction_pointer(fregs, func->new_func);
}
```

### Registering Functions

**klp_patch_func()** - `kernel/livepatch/patch.c:160-228`

```c
int klp_patch_func(struct klp_func *func)
{
    struct klp_ops *ops;

    // Find existing ops for this function
    ops = klp_find_ops(func->old_func);

    if (ops) {
        // Add to existing stack
        list_add_rcu(&func->stack_node, &ops->func_stack);
        return 0;
    }

    // Create new ops for first-time patch
    ops = kzalloc(sizeof(*ops), GFP_KERNEL);
    ops->fops.func = klp_ftrace_handler;
    ops->fops.flags = FTRACE_OPS_FL_DYNAMIC |
                      FTRACE_OPS_FL_IPMODIFY |
                      FTRACE_OPS_FL_PERMANENT;

    list_add(&ops->node, &klp_ops);
    list_add_rcu(&func->stack_node, &ops->func_stack);

    return register_ftrace_function(&ops->fops);
}
```

---

## Special Features

### Shadow Variables

**Purpose**: Attach additional data to existing kernel structures at runtime

**API**:

| Function | Purpose |
|----------|---------|
| `klp_shadow_get(obj, id)` | Retrieve shadow variable data |
| `klp_shadow_alloc(obj, id, size, gfp, ctor, data)` | Allocate new |
| `klp_shadow_get_or_alloc(obj, id, size, gfp, ctor, data)` | Get or allocate |
| `klp_shadow_free(obj, id, dtor)` | Free specific variable |
| `klp_shadow_free_all(id, dtor)` | Free all with ID |

**Use Cases**:
- Add new fields to patched structures without changing layout
- Maintain per-object state across patches
- Handle data structure expansion

### System State Tracking

**Purpose**: Track system-wide state changes across patches

**Compatibility Rules**:
- Non-cumulative patches: May have higher or missing version for each state
- Cumulative patches (replace=true): Must have all states with version >= previous

**API**:
- `klp_get_state(patch, id)` - Get state from specific patch
- `klp_get_prev_state(patch, id)` - Get state from previous patches
- `klp_is_patch_compatible(patch)` - Check version compatibility

### Atomic Replace (Cumulative Patches)

**Flag**: `patch->replace = true`

**Process**:
1. Enable new patch normally
2. During completion:
   - Unpatch all replaced patches
   - Create NOP functions for functions no longer patched
3. Remove old patches from system

**Benefits**:
- Simplifies patch management
- Reduces patch stack depth
- Cleaner state management

### ELF Relocation Handling

**Special sections**:
- `.klp.rela.vmlinux.*` - Relocations for vmlinux symbols
- `.klp.rela.{module}.*` - Relocations for module symbols

**Special symbols**:
- `.klp.sym.{objname}.{symname},{sympos}` - Symbol references

**Flags**:
- `SHF_RELA_LIVEPATCH` - Marks livepatch relocation sections
- `SHN_LIVEPATCH` - Marks livepatch symbols

### Callbacks

```c
struct klp_callbacks {
    klp_pre_patch_t pre_patch;         // Before patching
    klp_post_patch_t post_patch;       // After patching complete
    klp_pre_unpatch_t pre_unpatch;     // Before unpatching
    klp_post_unpatch_t post_unpatch;   // After unpatching complete
    bool post_unpatch_enabled;
};
```

**Order**:
- Enable: `pre_patch` → (transition) → `post_patch`
- Disable: `pre_unpatch` → (transition) → `post_unpatch`

### Sysfs Interface

```
/sys/kernel/livepatch/
├── <patch>/
│   ├── enabled           (RW: 0/1 to disable/enable)
│   ├── transition        (RO: 1 if in transition)
│   ├── force             (WO: write 1 to force transition)
│   ├── replace           (RO: 1 if cumulative patch)
│   ├── stack_order       (RO: position in patch stack)
│   └── <object>/         (vmlinux or module name)
│       ├── patched       (RO: 1 if object patched)
│       └── <func,sympos>/ (function directory)
```

---

## Architecture Comparison

### Support Matrix

| Architecture | HAVE_LIVEPATCH | DYNAMIC_FTRACE_WITH_* | HAVE_RELIABLE_STACKTRACE | Status |
|--------------|----------------|----------------------|--------------------------|--------|
| **ARM64** | Yes (unconditional) | WITH_ARGS | Yes | ✅ Fully Supported |
| **x86_64** | Yes | WITH_ARGS | Conditional* | ✅ Fully Supported |
| **PowerPC** | Yes | WITH_REGS | Yes | ✅ Fully Supported |
| **s390** | Yes | WITH_REGS | Yes | ✅ Fully Supported |
| **LoongArch** | Yes | WITH_ARGS | Yes | ✅ Fully Supported |
| **ARM32** | ❌ No | WITH_REGS | ❌ No | ❌ Not Supported |

*Requires `UNWINDER_ORC` or `STACK_VALIDATION` on x86_64

### TIF_PATCH_PENDING Flag Position

| Architecture | Bit Position | Header |
|--------------|--------------|--------|
| **ARM64** | `13` | `arch/arm64/include/asm/thread_info.h` |
| **x86_64** | `9` (generic) | `include/asm-generic/thread_info_tif.h` |
| **PowerPC** | `6` | `arch/powerpc/include/asm/thread_info.h` |
| **s390** | `31` | `arch/s390/include/asm/thread_info.h` |
| **LoongArch** | `5` | `arch/loongarch/include/asm/thread_info.h` |
| **ARM32** | ❌ Not defined | N/A |

### Architecture-Specific Files

| Architecture | Ftrace Implementation | Stack Unwinding | Livepatch Integration |
|--------------|----------------------|-----------------|----------------------|
| **ARM64** | `arch/arm64/kernel/ftrace.c` | `arch/arm64/kernel/stacktrace.c` | Generic (no dedicated livepatch.c) |
| **x86_64** | `arch/x86/kernel/ftrace.c` | `arch/x86/kernel/unwind_orc.c` | Generic (no dedicated livepatch.c) |

> **Key Insight**: Neither ARM64 nor x86_64 has a dedicated `livepatch.c` file. All livepatch logic is architecture-independent in `kernel/livepatch/`, with only ftrace integration being architecture-specific.

---

## ARM64 Deep Dive

### Why ARM64 Doesn't Need Dedicated livepatch.c

```
┌─────────────────────────────────────────────────────────────┐
│              ARM64 Livepatch Architecture                   │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌─────────────────────────────────────────────────────┐   │
│  │         kernel/livepatch/ (Generic Code)            │   │
│  │  ├── core.c      - Main orchestration               │   │
│  │  ├── transition.c - Consistency model               │   │
│  │  ├── patch.c     - Ftrace handler registration      │   │
│  │  ├── shadow.c    - Shadow variables                 │   │
│  │  └── state.c     - State tracking                   │   │
│  └─────────────────────────────────────────────────────┘   │
│                          │                                  │
│                          │ Uses standard ftrace API        │
│                          ▼                                  │
│  ┌─────────────────────────────────────────────────────┐   │
│  │       arch/arm64/kernel/ftrace.c                     │   │
│  │  • FTRACE_WITH_ARGS implementation                   │   │
│  │  • ftrace_caller assembly                           │   │
│  │  • Register saving (x0-x8 only)                      │   │
│  │  • Frame record creation                            │   │
│  └─────────────────────────────────────────────────────┘   │
│                          │                                  │
│                          ▼                                  │
│  ┌─────────────────────────────────────────────────────┐   │
│  │    arch/arm64/kernel/stacktrace.c                    │   │
│  │  • Frame-pointer based unwinding                    │   │
│  │  • Reliable stacktrace for klp_check_stack()        │   │
│  │  • Stack bounds validation                          │   │
│  └─────────────────────────────────────────────────────┘   │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### ARM64 FTRACE_WITH_ARGS Implementation

#### Register Context Structure

```c
// arch/arm64/include/asm/ftrace.h
struct __arch_ftrace_regs {
    /* x0 - x8: Function arguments and return value */
    unsigned long regs[9];

    #ifdef CONFIG_DYNAMIC_FTRACE_WITH_DIRECT_CALLS
    unsigned long direct_tramp;
    #else
    unsigned long __unused;
    #endif

    unsigned long fp;    // Frame pointer (x29)
    unsigned long lr;    // Link register (x30)
    unsigned long sp;    // Stack pointer
    unsigned long pc;    // Program counter
};
```

**Design Rationale**: ARM64 calling convention (AAPCS64):
- x0-x7: Argument registers
- x8: Indirect result / return value
- x9-x18: Temporary caller-save registers (safe to clobber)
- x19-x28: Callee-saved registers (preserved by compiler)
- x29: Frame pointer
- x30: Link register

For livepatch, only x0-x8 needed since:
1. Arguments must be preserved for inspection/modification
2. x9-x18 can be clobbered (caller-save)
3. x19-x29 are preserved by compiler
4. x30 (LR) is explicitly saved

#### Function Entry Patching Mechanism

```
┌─────────────────────────────────────────────────────────────┐
│              ARM64 Function Entry Patching                  │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  1. COMPILER OUTPUT (with -fpatchable-function-entry=2)    │
│     ┌─────────────────────────────────────────────────┐    │
│     │ func+00:  NOP        // 4 bytes                  │    │
│     │ func+04:  NOP        // 4 bytes                  │    │
│     │ func+08:  <actual function code>                │    │
│     └─────────────────────────────────────────────────┘    │
│                                                             │
│  2. AFTER ftrace_init_nop() (kernel initialization)        │
│     ┌─────────────────────────────────────────────────┐    │
│     │ func+00:  MOV X9, LR  // Save link register      │    │
│     │ func+04:  NOP                                    │    │
│     │ func+08:  <actual function code>                │    │
│     └─────────────────────────────────────────────────┘    │
│                                                             │
│  3. AFTER register_ftrace_function() (livepatch enabled)   │
│     ┌─────────────────────────────────────────────────┐    │
│     │ func+00:  MOV X9, LR  // Save link register      │    │
│     │ func+04:  BL ftrace_caller                      │    │
│     │ func+08:  <actual function code>                │    │
│     └─────────────────────────────────────────────────┘    │
│                                                             │
│  4. WITH BTI (Branch Target Identification)                │
│     ┌─────────────────────────────────────────────────┐    │
│     │ func-04:  BTI C       // Branch target ID        │    │
│     │ func+00:  MOV X9, LR                            │    │
│     │ func+04:  BL ftrace_caller                      │    │
│     │ func+08:  <actual function code>                │    │
│     └─────────────────────────────────────────────────┘    │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

#### ftrace_caller Assembly Analysis

```assembly
// arch/arm64/kernel/entry-ftrace.S
SYM_CODE_START(ftrace_caller)
    bti c                        // [1] BTI protection

    // [2] Save original SP
    mov x10, sp

    // [3] Allocate stack space
    //     FREGS_SIZE = 96 bytes (12 * 8)
    //     + 32 bytes for 2 frame records
    sub sp, sp, #(FREGS_SIZE + 32)

    // [4] Save function arguments (x0-x8)
    stp x0, x1, [sp, #FREGS_X0]
    stp x2, x3, [sp, #FREGS_X2]
    stp x4, x5, [sp, #FREGS_X4]
    stp x6, x7, [sp, #FREGS_X6]
    str x8,     [sp, #FREGS_X8]

    // [5] Save FP, LR, SP, PC
    str x29, [sp, #FREGS_FP]
    str x9,  [sp, #FREGS_LR]  // x9 contains saved LR
    str x10, [sp, #FREGS_SP]  // x10 contains saved SP
    str x30, [sp, #FREGS_PC]  // x30 is return address

    // [6] Create frame records for proper stack unwinding
    //     Frame record = {fp, lr}
    stp x29, x9, [sp, #FREGS_SIZE + 16]    // Frame record 2
    add x29, sp, #FREGS_SIZE + 16          // Update FP

    stp x29, x30, [sp, #FREGS_SIZE]        // Frame record 1
    add x29, sp, #FREGS_SIZE              // Update FP again

    // [7] Call tracer function
    sub x0, x30, #AARCH64_INSN_SIZE  // ip: current function
    mov x1, x9                         // parent_ip: caller
    mov x2, x28                        // op: ftrace_ops
    mov x3, sp                         // regs: ftrace_regs pointer
    bl ftrace_stub

    // [8] Restore registers and return
    ldp x0, x1, [sp, #FREGS_X0]
    ldp x2, x3, [sp, #FREGS_X2]
    ldp x4, x5, [sp, #FREGS_X4]
    ldp x6, x7, [sp, #FREGS_X6]
    ldr x8,     [sp, #FREGS_X8]
    ldr x29, [sp, #FREGS_FP]
    ldr x30, [sp, #FREGS_LR]
    ldr x9,  [sp, #FREGS_PC]
    add sp, sp, #FREGS_SIZE + 32
    ret x9
SYM_CODE_END(ftrace_caller)
```

**Key Points**:
1. **BTI protection**: Branch Target Identification for security
2. **Stack frame**: 96 + 32 = 128 bytes total
3. **Frame records**: Enable reliable stack unwinding
4. **Register preservation**: Only x0-x8 saved (minimal overhead)

#### ARM64 Stack Frame Layout

```
High Address
┌─────────────────────────────────────────┐
│  Original SP (saved in x10)             │
├─────────────────────────────────────────┤
│  Frame Record 2 (ftrace_caller's frame) │
│  ┌───────────────────────────────────┐  │
│  │ FP (saved x29)                    │  │
│  │ LR (saved x9)                     │  │
│  └───────────────────────────────────┘  │
├─────────────────────────────────────────┤
│  Frame Record 1 (instrumented function) │
│  ┌───────────────────────────────────┐  │
│  │ FP (saved x29)                    │  │  <- x29 points here
│  │ LR (saved x30)                    │  │
│  └───────────────────────────────────┘  │
├─────────────────────────────────────────┤
│  FTRACE_REGS structure                  │
│  ┌───────────────────────────────────┐  │
│  │ x8                               │  │
│  │ x7, x6                           │  │
│  │ x5, x4                           │  │
│  │ x3, x2                           │  │
│  │ x1, x0                           │  │
│  │ direct_tramp (if enabled)        │  │
│  │ PC                               │  │
│  │ SP                               │  │
│  │ LR                               │  │
│  │ FP                               │  │
│  └───────────────────────────────────┘  │  <- SP points here
└─────────────────────────────────────────┘
Low Address
```

### ARM64 Stack Unwinding

#### Frame Record Structure

```c
struct frame_record {
    unsigned long fp;    // Pointer to previous frame record
    unsigned long lr;    // Return address
};
```

#### Unwinding Process

```c
// arch/arm64/kernel/stacktrace.c
static inline bool notrace unwind_next(struct kunwind_state *state)
{
    struct frame_record *rec;

    // [1] Read frame record from current FP
    rec = (struct frame_record *)state->fp;

    // [2] Check stack bounds
    if (kunwind_is_unbounds_frame(state))
        return false;

    // [3] Handle special cases
    if (kunwind_is_kretprobe_trampoline(state->fp))
        // Handle kretprobe trampoline
        return kunwind_unwind_kretprobe(state);

    if (kunwind_is_fgraph_trampoline(state->fp))
        // Handle ftrace_graph trampoline
        return kunwind_unwind_fgraph(state);

    // [4] Move to next frame
    state->fp = rec->fp;
    state->pc = rec->lr;

    return true;
}
```

**Special Trampoline Handling**:
- `kretprobe_trampoline`: kretprobe return hook
- `ftrace_graph_trampoline`: ftrace function graph tracer
- `ftrace_regs_caller`: ftrace with regs

### ARM64 Configuration

```kconfig
# arch/arm64/Kconfig
config ARM64
    select HAVE_DYNAMIC_FTRACE
    select HAVE_DYNAMIC_FTRACE_WITH_ARGS \
        if (GCC_SUPPORTS_DYNAMIC_FTRACE_WITH_ARGS || \
            CLANG_SUPPORTS_DYNAMIC_FTRACE_WITH_ARGS)
    select HAVE_DYNAMIC_FTRACE_WITH_DIRECT_CALLS \
        if DYNAMIC_FTRACE_WITH_ARGS && DYNAMIC_FTRACE_WITH_CALL_OPS
    select HAVE_DYNAMIC_FTRACE_WITH_CALL_OPS \
        if (DYNAMIC_FTRACE_WITH_ARGS && !CFI && \
            (CC_IS_CLANG || !CC_OPTIMIZE_FOR_SIZE))
    select FTRACE_MCOUNT_USE_PATCHABLE_FUNCTION_ENTRY \
        if DYNAMIC_FTRACE_WITH_ARGS

    select HAVE_LIVEPATCH
    select HAVE_RELIABLE_STACKTRACE
    select FRAME_POINTER          # MANDATORY for livepatch
```

**Key Features**:
- **FTRACE_WITH_ARGS**: Primary feature (not WITH_REGS)
- **CALL_OPS**: Per-callsite ftrace_ops pointer support
- **PATCHABLE_FUNCTION_ENTRY**: Uses compiler feature
- **FRAME_POINTER**: Always enabled (mandatory)
- **BTI**: Branch Target Identification support

---

## x86_64 Comparison

### x86_64 FTRACE_WITH_ARGS

```c
// arch/x86/include/asm/ftrace.h
// Uses generic ftrace_regs structure
// HAVE_FTRACE_REGS_HAVING_PT_REGS is defined
```

#### Function Entry

```assembly
// Compiler generates:
call __fentry__   // 5 bytes at function entry

// Can be patched to:
nop; nop; nop; nop; nop  // 5 bytes
jmp ftrace_caller        // Direct jump (5 bytes)
```

#### Trampolines

| Trampoline | Purpose |
|------------|---------|
| `ftrace_caller` | Basic tracing (minimal register save) |
| `ftrace_regs_caller` | Full pt_regs save (for livepatch) |

#### Stack Unwinding

x86_64 uses **ORC (Oops Rewind Capability)** unwinder:

```c
// arch/x86/kernel/unwind_orc.c
struct orc_entry {
    s16 sp_offset;
    s16 bp_offset;
    unsigned sp_reg:4;
    unsigned bp_reg:4;
    unsigned type:2;
    unsigned signal:1;
};
```

**ORC Advantages**:
- More sophisticated than frame pointers
- Better performance (no fp chaining)
- Build-time validation via objtool
- Handles optimized code better

---

## ARM64 vs x86_64: Key Differences

### Function Entry Instrumentation

| Aspect | ARM64 | x86_64 |
|--------|-------|--------|
| Compiler Flag | `-fpatchable-function-entry=2` | `-mfentry` |
| Entry Size | 2 NOPs (8 bytes) | 1 CALL (5 bytes) |
| Patching | NOP → MOV + BL | CALL → NOP or JMP |
| BTI Support | ✓ Yes | ✗ No |
| Instructions | 2 independent patches | Single instruction |

### Register State

| Aspect | ARM64 | x86_64 |
|--------|-------|--------|
| Saved Registers | x0-x8, fp, lr, sp, pc (12 total) | Full pt_regs (all registers) |
| Structure | `__arch_ftrace_regs` | `ftrace_regs` containing `pt_regs` |
| Size | ~96 bytes | ~200+ bytes |
| Overhead | Lower | Higher |
| Debug Capability | Basic | Complete |

### Trampolines

| Aspect | ARM64 | x86_64 |
|--------|-------|--------|
| Trampolines | Single `ftrace_caller` | Two: `ftrace_caller` + `ftrace_regs_caller` |
| Selection | Always `ftrace_caller` | Based on `FTRACE_OPS_FL_SAVE_REGS` |
| Dynamic Alloc | No | Yes (CREATE_DYNAMIC) |
| Direct Call | Via `direct_tramp` field | Via `orig_ax` in pt_regs |

### Stack Unwinding

| Aspect | ARM64 | x86_64 |
|--------|-------|--------|
| Method | Frame pointer (mandatory) | ORC tables (default) |
| Data | Frame records {fp, lr} | ORC entries + .orc_unwind section |
| Build Tools | Not needed | objtool required |
| Reliability | High | Very High |
| Performance | Good | Better (no fp overhead) |
| Special Handling | ftrace_graph, kretprobe | Same + ORC lookup |

### Memory and Performance

| Metric | ARM64 | x86_64 |
|--------|-------|--------|
| Stack Usage | ~128 bytes | ~280+ bytes |
| Register Save | 12 registers | 15+ registers |
| Frame Records | 2 (16 bytes) | Variable |
| Unwind Speed | O(stack_depth) | O(stack_depth) but faster |
| Binary Size | Smaller | Larger (ORC data) |

### Security Features

| Feature | ARM64 | x86_64 |
|---------|-------|--------|
| BTI | ✓ Branch Target Identification | ✗ Not applicable |
| PAC | ✓ Pointer Authentication (optional) | ✗ Not applicable |
| RETPOLINE | Software emulation | Hardware support |
| RETHPOLINE | Needed for spectre-v2 | Needed for spectre-v2 |

### ARM32: Why No Livepatch?

**Missing Components**:
- ❌ No `HAVE_LIVEPATCH` selection in Kconfig
- ❌ No `TIF_PATCH_PENDING` flag in thread_info.h
- ❌ No `HAVE_RELIABLE_STACKTRACE`
- ❌ No architecture integration points

**To Add Support Would Require**:
1. Add `select HAVE_LIVEPATCH` to arch/arm/Kconfig
2. Add `TIF_PATCH_PENDING` to thread_info.h (find free bit)
3. Implement reliable stack unwinder OR add `klp_update_patch_state()` in all kthreads
4. Verify `DYNAMIC_FTRACE_WITH_REGS` works for livepatch
5. Add entry/exit path integration in arch/arm/kernel/entry-*

---

## Key Functions Reference

### Core Functions (core.c)

| Function | Location | Purpose |
|----------|----------|---------|
| `klp_enable_patch()` | :1108-1173 | Main entry point from module_init() |
| `klp_init_patch_early()` | :960-980 | Initialize patch structures |
| `klp_init_patch()` | :982-1006 | Complete initialization, sysfs setup |
| `klp_init_object()` | :914-943 | Initialize an object (vmlinux/module) |
| `klp_init_object_loaded()` | :866-912 | Initialize when target loaded |
| `klp_module_coming()` | :1259-1338 | Called when target module loads |
| `klp_module_going()` | :1340-1357 | Called when target module unloads |

### Transition Functions (transition.c)

| Function | Location | Purpose |
|----------|----------|---------|
| `klp_init_transition()` | :552-619 | Initialize transition state |
| `klp_start_transition()` | :509-545 | Start transition (set flags) |
| `klp_try_complete_transition()` | :430-503 | Try to complete transition |
| `klp_try_switch_task()` | :305-355 | Try to switch a task |
| `klp_check_stack()` | :254-282 | Check if safe to switch |
| `klp_update_patch_state()` | :175-199 | Update task state at exit |
| `klp_complete_transition()` | :81-148 | Clean up after transition |
| `klp_copy_process()` | :676-695 | Inherit state on fork |

### Patch Functions (patch.c)

| Function | Location | Purpose |
|----------|----------|---------|
| `klp_ftrace_handler()` | :40-125 | Ftrace handler (hot path) |
| `klp_patch_func()` | :160-228 | Register function for patching |
| `klp_unpatch_func()` | :127-158 | Remove function from patching |
| `klp_patch_object()` | - | Patch all functions in object |
| `klp_unpatch_object()` | - | Unpatch all functions in object |

### State Functions (state.c)

| Function | Location | Purpose |
|----------|----------|---------|
| `klp_get_state()` | :31-42 | Get state from specific patch |
| `klp_get_prev_state()` | :64-84 | Get state from previous patches |
| `klp_is_patch_compatible()` | :106-119 | Check version compatibility |

### Shadow Functions (shadow.c)

| Function | Location | Purpose |
|----------|----------|---------|
| `klp_shadow_get()` | :83-102 | Get shadow variable |
| `klp_shadow_alloc()` | :196-203 | Allocate new shadow variable |
| `klp_shadow_get_or_alloc()` | :225-232 | Get or allocate |
| `klp_shadow_free()` | :253-272 | Free specific variable |
| `klp_shadow_free_all()` | :283-299 | Free all with ID |

---

## Summary

### Key Takeaways

1. **Architecture**: Modular design with core, transition, patch, shadow, and state components

2. **Consistency**: Hybrid model using stack checking, kernel exit switching, and scheduler-based switching

3. **Function Redirection**: Ftrace-based with per-task state awareness

4. **Architecture Support**: ARM64 and x86_64 are primary supported architectures

5. **Special Features**: Shadow variables, state tracking, cumulative patches

### Livepatch Life Cycle

```
LOAD → ENABLE → TRANSITION → COMPLETE → [RUNTIME] → DISABLE → TRANSITION → COMPLETE → REMOVE
```

### Limitations

- Only functions traceable by ftrace can be patched
- Kretprobes conflict with patched functions
- Force transition prevents module unload
- Architecture support varies (ARM32 not supported)

---

## References

- **Main Documentation**: `Documentation/livepatch/livepatch.rst`
- **Callbacks**: `Documentation/livepatch/callbacks.rst`
- **Shadow Variables**: `Documentation/livepatch/shadow-vars.rst`
- **System State**: `Documentation/livepatch/system-state.rst`
- **Cumulative Patches**: `Documentation/livepatch/cumulative-patches.rst`
- **Samples**: `samples/livepatch/`
- **Tests**: `tools/testing/selftests/livepatch/`
