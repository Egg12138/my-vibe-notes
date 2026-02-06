# Kpatch: Comprehensive Knowledge Summary

> **Topic:** Complete knowledge recap of kpatch - Linux dynamic kernel patching infrastructure
> **Date:** 2026-02-03
> **Level:** Beginner to Advanced
> **Related:** Livepatch kernel subsystem (see `linux/kernel/subsystems/livepatch.md`)

---

## Table of Contents

1. [Overview](#overview)
2. [What We've Learned](#what-weve-learned)
3. [Kpatch vs Livepatch: Relationship](#kpatch-vs-livepatch-relationship)
4. [Key Concepts](#key-concepts)
5. [Existing Notes Index](#existing-notes-index)
6. [Quick Reference](#quick-reference)
7. [Learning Path](#learning-path)

---

## Overview

**Kpatch** is a user-space toolchain that builds kernel livepatch modules. It converts source-level patches into loadable kernel modules that use the kernel's built-in **Livepatch subsystem** (CONFIG_LIVEPATCH) to patch a running kernel without rebooting.

```
┌─────────────────────────────────────────────────────────────────┐
│                    Kpatch Ecosystem                             │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│   User Space Tools                Kernel Subsystem              │
│   ┌───────────────┐               ┌─────────────────────────┐   │
│   │ kpatch-build │ ──── .ko ───► │ CONFIG_LIVEPATCH        │   │
│   │ (toolchain)  │               │ (kernel/livepatch/)     │   │
│   └───────────────┘               └─────────────────────────┘   │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## What We've Learned

### 1. Core Architecture

**Three Main Components:**

| Component | Location | Purpose |
|-----------|----------|---------|
| **kpatch-build** | User space | Converts source diff to patch module |
| **Patch module** | `.ko` file | Contains replacement functions + metadata |
| **kpatch utility** | CLI tool | Manages patch modules (load/unload) |

### 2. Build Process

**kpatch-build workflow:**

```
source.patch → kpatch-build → livepatch-xxx.ko
                          │
                          ├─── Build original kernel
                          ├─── Apply patch & rebuild
                          ├─── Compare objects (create-diff-object)
                          ├─── Extract changes + dependencies
                          └─── Link into patch module
```

**Key tool: `create-diff-object`**

- **Location:** `kpatch/kpatch-build/create-diff-object.c` (4562 lines)
- **Purpose:** Binary differencing engine
- **Input:** Original `.o` vs Patched `.o`
- **Output:** Object with `.kpatch.funcs`, `.kpatch.dynrelas` sections

### 3. Kernel Livepatch Subsystem

**Location:** `kernel/livepatch/`

| File | Purpose |
|------|---------|
| `core.c` | Main orchestration, patch enable/disable |
| `transition.c` | Consistency model, task state management |
| `patch.c` | Ftrace registration, function redirection |
| `shadow.c` | Shadow variables for runtime data |
| `state.c` | System-wide state versioning |

**Data Structure Hierarchy:**

```
klp_patch (top-level patch)
    │
    ├── klp_object[] (vmlinux or modules)
    │       │
    │       ├── klp_func[] (individual functions)
    │       └── callbacks (pre/post patch)
    │
    └── klp_state[] (system state modifications)
```

### 4. How Runtime Patching Works

**Ftrace-based function redirection:**

```
Original function call:
  caller() → old_function()
              │
              └─ fentry hook point
                  │
                  ├─ klp_ftrace_handler() checks task->patch_state
                  │   │
                  │   ├─ UNPATCHED: return to old_function
                  │   └─ PATCHED: redirect to new_function
                  │
                  └─ ftrace_regs_set_ip(fregs, new_func)
```

**Consistency Model:**

- Tasks switch from UNPATCHED → PATCHED gradually
- Stack checking ensures no task is mid-function when switching
- Three switching mechanisms:
  1. Stack checking (primary, with HAVE_RELIABLE_STACKTRACE)
  2. Kernel exit switching
  3. Scheduler-based switching

### 5. Architecture Support

| Architecture | Status | Notes |
|--------------|--------|-------|
| x86_64 | ✅ Full | Most mature, ORC unwinder |
| ARM64 | ✅ Full | Unconditional support |
| ppc64le | ✅ Full | TOC handling |
| s390 | ✅ Full | Special relocation types |
| loongarch64 | ✅ Partial | Conditional stacktrace |
| ARM32 | ❌ No | Missing infrastructure |

**Key differences:**
- **x86_64:** `__fentry__` call (5 bytes)
- **ARM64:** 2 NOPs with `-fpatchable-function-entry=2` (8 bytes)
- Both use `DYNAMIC_FTRACE_WITH_ARGS`

### 6. Special Features

**Shadow Variables:**
- Attach runtime data to existing kernel objects
- Use case: Add fields to structures without changing layout
- API: `klp_shadow_alloc()`, `klp_shadow_get()`, `klp_shadow_free()`

**Cumulative Patches (atomic replace):**
- New patch replaces all previous patches
- Creates NOP functions for reverted changes
- Simplifies patch management

**Callbacks:**
- `pre_patch`: Before patching starts
- `post_patch`: After all tasks switched
- `pre_unpatch`: Before unpatching
- `post_unpatch`: After cleanup

### 7. Limitations

What **cannot** be patched:
- ❌ `__init` functions (already executed at boot)
- ❌ Static data structures (use callbacks/shadow vars)
- ❌ Functions without ftrace support
- ❌ vdso functions (run in userspace)
- ❌ lib-y targets (archived into lib.a)

---

## Kpatch vs Livepatch: Relationship

```
┌─────────────────────────────────────────────────────────────────┐
│                   Clear Distinction                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  KPATCH (User Space Tool)                                       │
│  ├── GitHub: https://github.com/dynup/kpatch                    │
│  ├── Language: Shell scripts + C                               │
│  ├── Purpose: BUILD patch modules                              │
│  └── Product: .ko file                                         │
│                                                                  │
│  LIVEPATCH (Kernel Subsystem)                                   │
│  ├── Location: kernel/livepatch/                               │
│  ├── Language: C (kernel code)                                 │
│  ├── Purpose: APPLY patch modules at runtime                   │
│  └── Config: CONFIG_LIVEPATCH                                   │
│                                                                  │
│  Relationship:                                                   │
│  kpatch ──builds──▶ .ko module ──loads into──▶ Livepatch        │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

**Historical context:**
- **kpatch** was originally a Red Hat project with its own kernel module
- **Kernel Livepatch** was upstreamed in Linux 4.0
- Modern kpatch uses kernel's built-in Livepatch (KLP API)

---

## Key Concepts

### 1. Function Granularity

Kpatch works at **function level** - entire functions are replaced, not individual instructions.

### 2. Binary Differencing

The `create-diff-object` tool:
- Compiles with `-ffunction-sections -fdata-sections`
- Compares ELF sections byte-by-byte
- Tracks dependency chains (functions → strings → relocations)

### 3. Symbol Resolution

**KLP special symbols:**
- `.klp.sym.vmlinux.function_name,0` - Symbol references
- `.klp.rela.vmlinux.text.function_name` - Relocations
- `SHF_RELA_LIVEPATCH` - Section flag
- `SHN_LIVEPATCH` - Symbol section index

### 4. Safety Verification

**Compiler version check:**
- kpatch-build requires exact compiler match
- Different compilers = different code generation = unsafe patch

**Patchability checks:**
- No init function modifications
- No static data changes
- Function size compatible
- All dependencies resolvable

---

## Existing Notes Index

### Main Documentation Files

| File | Topic | Level |
|------|-------|-------|
| `kpatch-README.md` | Project overview, FAQ | Beginner |
| `kpatch-build-user-guide-cn.md` | Complete CLI reference | Intermediate |
| `create-diff-object-workflow.md` | Binary differencing engine | Advanced |
| `qemu-end-to-end-example.md` | Hands-on tutorial | Beginner |

### Kernel Documentation

| File | Topic |
|------|-------|
| `livepatch.md` | Kernel Livepatch subsystem (architecture, data structures, workflow) |
| `kpatch-README.md` | Duplicated in kernel subsystems for reference |

### Topics Covered

1. **Build System**
   - kpatch-build script workflow
   - create-diff-object detailed analysis
   - GCC wrapper (kpatch-cc)

2. **Kernel Integration**
   - Livepatch architecture
   - Data structures (klp_patch, klp_object, klp_func)
   - Function-level analysis
   - Consistency model

3. **Architecture Differences**
   - x86_64 vs ARM64 vs ARM32
   - Ftrace implementation differences
   - Stack trace reliability

4. **Practical Usage**
   - QEMU-based testing
   - Sample modules
   - Troubleshooting

---

## Quick Reference

### Basic Commands

```bash
# Build patch module
kpatch-build my-fix.patch
# Output: livepatch-my-fix.ko

# Load patch
sudo kpatch load livepatch-my-fix.ko

# List loaded patches
sudo kpatch list

# Unload patch
sudo kpatch unload livepatch-my-fix

# Check patch status
cat /sys/kernel/livepatch/livepatch_my_fix/enabled
```

### kpatch-build Options

```bash
# Most common options
kpatch-build \
  --sourcedir /path/to/kernel/src \
  --vmlinux /path/to/vmlinux \
  --config /boot/config-$(uname -r) \
  --name my-patch \
  my-fix.patch

# Debug mode
kpatch-build -d -d -d patch.patch

# Non-replace mode (patches stack)
kpatch-build --non-replace patch.patch
```

### Kernel Requirements

```bash
# Check livepatch support
cat /boot/config-$(uname -r) | grep LIVEPATCH
# Should show: CONFIG_LIVEPATCH=y

# Check reliable stack trace
cat /boot/config-$(uname -r) | grep HAVE_RELIABLE_STACKTRACE

# Check ftrace support
cat /boot/config-$(uname -r) | grep FUNCTION_TRACER
```

### Directory Structure

```
kpatch/
├── kpatch-build/           # Build tools
│   ├── kpatch-build        # Main script
│   ├── create-diff-object.c # Binary differencer
│   └── kpatch-cc           # GCC wrapper
├── kpatch/                 # Runtime utility
│   └── kpatch.c
├── doc/                    # Documentation
│   ├── patch-author-guide.md
│   └── INSTALL.md
└── test/                   # Tests
    └── integration/
```

---

## Learning Path

### For Beginners

1. Start with `qemu-end-to-end-example.md`
   - Safe VM environment
   - Hands-on experience
   - No risk to host system

2. Read `kpatch-README.md`
   - Understand the project
   - Learn limitations
   - Read FAQ

3. Try kernel samples
   - `samples/livepatch/livepatch-sample.c`
   - See actual code structure

### For Intermediate Users

1. Study `kpatch-build-user-guide-cn.md`
   - Complete CLI reference
   - All command-line options
   - Build configuration

2. Understand the relationship
   - kpatch (tool) vs Livepatch (kernel)
   - Read `livepatch.md` for kernel side

3. Practice with real patches
   - Create your own fix
   - Test thoroughly in VM

### For Advanced Users

1. Deep dive into `create-diff-object-workflow.md`
   - Binary analysis techniques
   - ELF manipulation
   - Architecture-specific handling

2. Study kernel source
   - `kernel/livepatch/*.c`
   - Understand consistency model
   - Learn shadow variables

3. Contribute
   - Add architecture support
   - Improve documentation
   - Submit patches

---

## Related Topics

### Prerequisites

1. **ELF Format**
   - Sections, symbols, relocations
   - See: `binary-tools/bfd/` notes

2. **Ftrace**
   - Function tracer infrastructure
   - fentry/mcount instrumentation

3. **Kernel Modules**
   - Module loading
   - Symbol resolution
   - Module.symvers

### Advanced Topics

1. **Shadow Variables**
   - Runtime data attachment
   - Hash table implementation
   - RCU-safe operations

2. **Consistency Models**
   - kGraft-style per-task consistency
   - kpatch-style stack checking
   - Hybrid approach (current)

3. **Alternative Implementations**
   - kpatch (Red Hat/Fedora)
   - kgraft (SUSE)
   - ksplice (Oracle)

---

## Summary

**What kpatch is:**
- User-space toolchain for building kernel livepatch modules
- Converts source patches to loadable `.ko` files
- Uses kernel's CONFIG_LIVEPATCH subsystem

**Key tools:**
- `kpatch-build`: Main build script
- `create-diff-object`: Binary differencing engine
- `kpatch`: Runtime management utility

**Key kernel components:**
- `kernel/livepatch/core.c`: Main orchestration
- `kernel/livepatch/transition.c`: Consistency model
- `kernel/livepatch/patch.c`: Ftrace integration

**Supported architectures:**
- x86_64, ARM64, ppc64le, s390, loongarch64
- NOT ARM32 (missing infrastructure)

**Our notes cover:**
1. Complete build system workflow
2. Kernel subsystem architecture
3. Architecture-specific differences
4. Practical hands-on tutorials
5. Troubleshooting and best practices

---

## References

**Source locations:**
- Kpatch source: `/home/egg/source/linux/kpatch/`
- Kernel livepatch: `/home/egg/source/linux/kernel/livepatch/`
- Kernel samples: `/home/egg/source/linux/samples/livepatch/`

**External resources:**
- GitHub: https://github.com/dynup/kpatch
- Kernel docs: `Documentation/livepatch/`

---

<!--
Summary of kpatch knowledge accumulated through study sessions.
Source: kpatch git repository and Linux kernel source (v6.19-rc5)
Version: 1.0
Date: 2026-02-03
-->
