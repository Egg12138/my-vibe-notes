# BFD Target Matching: Why `elf32-big` Instead of `elf32-bigaarch64`

## Table of Contents

- [Problem Statement](#problem-statement)
- [Root Cause](#root-cause)
- [BFD Architecture Overview](#bfd-architecture-overview)
  - [Key Components](#key-components)
  - [Target Vector Structure](#target-vector-structure)
- [The Two Targets in Question](#the-two-targets-in-question)
  - [`elf32-bigaarch64` (Architecture-Specific)](#elf32-bigaarch64-architecture-specific)
  - [`elf32-big` (Generic Fallback)](#elf32-big-generic-fallback)
- [Match Priority Algorithm](#match-priority-algorithm)
- [Target Selection Flow](#target-selection-flow)
- [ELF Machine Validation](#elf-machine-validation)
- [Diagnosis Steps](#diagnosis-steps)
  - [1. Check ELF Header](#1-check-elf-header)
  - [2. Verify AArch64 ILP32 Support](#2-verify-aarch64-ilp32-support)
  - [3. Check Build Configuration](#3-check-build-configuration)
- [Common Scenarios](#common-scenarios)
- [Key Code References](#key-code-references)
- [Solutions](#solutions)
- [Related Concepts](#related-concepts)

---

## Problem Statement

When running `strip --verbose *.so` on an AArch64 ILP32 (AArch32) shared library, the output shows:

```
copy from `input.so' [elf32-big] to `output.so' [elf32-big]
```

Instead of the expected:

```
copy from `input.so' [elf32-bigaarch64] to `output.so' [elf32-bigaarch64]
```

## Root Cause

The `elf32-big` BFD target is selected instead of `elf32-bigaarch64` when **BFD cannot match the file to a specific architecture backend**. This happens when:

1. **Unknown or corrupted `e_machine` field** - The ELF header's `e_machine` field doesn't contain `EM_AARCH64` (183)
2. **AArch64 ILP32 backend not available** - The binutils build was configured without AArch64 ILP32 support
3. **ELF header mismatch** - The file's `EI_CLASS`, `EI_DATA`, or OSABI doesn't match expectations

## BFD Architecture Overview

### Key Components

- **BFD (Binary File Descriptor)**: GNU binutils library for unified binary file handling
- **Target Vector (`xvec`)**: Structure defining file format operations and properties
- **Match Priority**: Integer value where **lower = better match** (0 = best, 2 = fallback)

### Target Vector Structure

```c
// bfd/targets.c:595-598
static inline const char *bfd_get_target(const bfd *abfd) {
    return abfd->xvec->name;  // Returns target name string
}
```

## The Two Targets in Question

### `elf32-bigaarch64` (Architecture-Specific)

Location: `bfd/elfnn-aarch64.c`

```c
#define TARGET_BIG_NAME    "elfNN-bigaarch64"
#define ELF_ARCH           bfd_arch_aarch64
#define ELF_MACHINE_CODE   EM_AARCH64  // 183
```

**Requirements:**
- `e_ident[EI_CLASS] == ELFCLASS32`
- `e_ident[EI_DATA] == ELFDATA2MSB` (big-endian)
- `e_machine == EM_AARCH64` (183)
- `match_priority = 1` (or 0 with exact OSABI match)

### `elf32-big` (Generic Fallback)

Location: `bfd/elf32-gen.c`

```c
#define TARGET_BIG_NAME    "elf32-big"
#define ELF_ARCH           bfd_arch_unknown
#define ELF_MACHINE_CODE   EM_NONE
```

**Characteristics:**
- Accepts **any 32-bit big-endian ELF file**
- `match_priority = 2` (lowest priority, acts as fallback)
- Always available in BFD builds

## Match Priority Algorithm

Location: `bfd/elfxx-target.h:804-808`

```c
#ifndef elf_match_priority
#define elf_match_priority \
  (ELF_ARCH == bfd_arch_unknown ? 2 \    // elf32-big: priority 2 (fallback)
   : ELF_OSABI == ELFOSABI_NONE || !ELF_OSABI_EXACT ? 1 \   // Most targets: priority 1
   : 0)   // Exact OSABI match: priority 0 (best)
```

**Lower priority value = better match**

## Target Selection Flow

```
strip --verbose *.so
        │
        ▼
bfd_openr() → bfd_check_format_matches()
        │
        ▼
┌─────────────────────────────────────────────────────┐
│ Iterate through bfd_target_vector:                   │
│   [..., aarch64_elf32_be_vec, ..., elf32_be_vec]    │
└─────────────────────────────────────────────────────┘
        │
        ├──► Try aarch64_elf32_be_vec (elf32-bigaarch64)
        │    ├─ Check e_machine == EM_AARCH64
        │    ├─ Check EI_CLASS == ELFCLASS32
        │    ├─ Check EI_DATA == ELFDATA2MSB
        │    └─ If ANY check fails → REJECT
        │
        └──► Try elf32_be_vec (elf32-big)
             ├─ ELF_MACHINE = EM_NONE (accepts any)
             ├─ Only checks basic ELF structure
             └─ ACCEPT as fallback
```

## ELF Machine Validation

Location: `bfd/elfcode.h:606-614`

```c
/* Check that the ELF e_machine field matches */
if (ebd->elf_machine_code != i_ehdrp->e_machine
    && (ebd->elf_machine_alt1 == 0
        || i_ehdrp->e_machine != ebd->elf_machine_alt1)
    && (ebd->elf_machine_alt2 == 0
        || i_ehdrp->e_machine != ebd->elf_machine_alt2)
    && ebd->elf_machine_code != EM_NONE)  // EM_NONE allows any machine
    goto got_wrong_format_error;
```

## Diagnosis Steps

### 1. Check ELF Header

```bash
# Check machine type (should be: Machine: AArch64)
readelf -h your.so | grep Machine

# Full header details
readelf -h your.so

# Check what BFD recognizes
file your.so
```

### 2. Verify AArch64 ILP32 Support

```bash
# List available targets in your BFD
objdump -i | grep aarch64
```

Expected output should include `elf32-bigaarch64` if support is compiled in.

### 3. Check Build Configuration

If building binutils from source, ensure AArch64 targets are enabled:

```bash
# List all configured targets
../binutils-gdb/configure --help | grep aarch64

# Enable AArch64 ILP32 explicitly
../binutils-gdb/configure --enable-targets=aarch64-linux-gnu_ilp32
```

## Common Scenarios

| Scenario | Why `elf32-bigaarch64` Fails | Why `elf32-big` Matches |
|----------|----------------------------|------------------------|
| **Corrupted `e_machine`** | `e_machine ≠ 183` | `EM_NONE` accepts any value |
| **ILP32 Backend Not Built** | `aarch64_elf32_be_vec` not in vector list | Generic fallback always available |
| **Wrong ELF Class** | `EI_CLASS ≠ ELFCLASS32` | Would fail basic ELF checks |
| **Wrong Endianness** | `EI_DATA ≠ ELFDATA2MSB` | Would show `elf32-little` instead |

## Key Code References

| File | Lines | Description |
|------|-------|-------------|
| `binutils/objcopy.c` | 2764-2766 | `--verbose` output calls `bfd_get_target()` |
| `bfd/targets.c` | 595-598 | `bfd_get_target()` returns `xvec->name` |
| `bfd/format.c` | 614-665 | Target matching loop with priority selection |
| `bfd/elfxx-target.h` | 804-808 | Match priority calculation macro |
| `bfd/elfcode.h` | 606-614 | ELF `e_machine` validation |
| `bfd/elf32-gen.c` | 92-98 | `elf32-big` target definition |
| `bfd/elfnn-aarch64.c` | 2349-2357, 10655-10657 | `elf32-bigaarch64` target definition |

## Solutions

1. **If file is corrupted**: Rebuild the `.so` from source with proper toolchain
2. **If backend missing**: Rebuild binutils with AArch64 ILP32 support enabled
3. **If wrong toolchain**: Use `aarch64-linux-gnu-gcc -mabi=ilp32` for ILP32 builds

## Related Concepts

- **ILP32 vs LP64**: AArch64 can run in 32-bit (ILP32) or 64-bit (LP64) ABI
- **BFD target vectors**: Each architecture has separate vectors for different configurations
- **Match priority system**: Ensures specific backends take precedence over generic fallbacks

---

*Source: Analyzed from binutils-gdb @ c4b575f3b54*
