# kpatch: create-diff-object Binary Tool Workflow

**Topic:** Dynamic kernel patching infrastructure - ELF differencing engine
**Date:** 2025-01-20
**Level:** Advanced - Binary Analysis & Kernel Livepatching

---

## Overview

kpatch is a Linux dynamic kernel patching infrastructure that allows patching a running kernel without rebooting. The `create-diff-object` tool is the heart of the ELF differencing engine that compares two compiled object files to determine what changed at the binary level.

### Key Components

1. **kpatch-build** - Collection of tools that convert source diff to patch module
2. **create-diff-object** - Binary differencing engine (main focus)
3. **Patch module** - Kernel livepatch module (.ko file)
4. **kpatch utility** - CLI tool for managing patch modules

---

## Table of Contents

- [Architecture Overview](#architecture-overview)
  - [The Three Main Components](#the-three-main-components)
- [create-diff-object: Deep Dive](#create-diff-object-deep-dive)
  - [Function Signature](#function-signature)
  - [Input Requirements](#input-requirements)
- [Main Workflow: Step by Step](#main-workflow-step-by-step)
  - [Phase 1: Initialization and Setup](#phase-1-initialization-and-setup)
  - [Phase 2: Symbol Correlation](#phase-2-symbol-correlation)
  - [Phase 3: Symbol Replacement Optimization](#phase-3-symbol-replacement-optimization)
  - [Phase 4: Comparison and Change Detection](#phase-4-comparison-and-change-detection)
    - [1. Relocation Comparison](#1-relocation-comparison)
    - [2. Data Comparison](#2-data-comparison)
    - [3. Line Number Filtering](#3-line-number-filtering)
  - [Phase 5: Dependency Analysis and Inclusion](#phase-5-dependency-analysis-and-inclusion)
  - [Phase 6: Special Section Processing](#phase-6-special-section-processing)
  - [Phase 7: Output Generation](#phase-7-output-generation)
    - [1. `.kpatch.funcs` / `.rela.kpatch.funcs`](#1-kpatchfuncs--relakpatchfuncs)
    - [2. `.kpatch.dynrelas` / `.rela.kpatch.dynrelas`](#2-kpatchdynrelas--relakpatchdynrelas)
    - [3. `.kpatch.strings`](#3-kpatchstrings)
    - [4. `.kpatch.arch`](#4-kpatcharch)
  - [Phase 8: Finalization](#phase-8-finalization)
- [Key Data Structures](#key-data-structures)
- [Architecture-Specific Handling](#architecture-specific-handling)
  - [x86_64](#x86_64)
  - [PPC64](#ppc64)
  - [ARM64](#arm64)
  - [S390](#s390)
- [Complete kpatch-build Workflow](#complete-kpatch-build-workflow)
  - [Step 1: Environment Setup](#step-1-environment-setup)
  - [Step 2: Build Original Kernel](#step-2-build-original-kernel)
  - [Step 3: Build Patched Kernel](#step-3-build-patched-kernel)
  - [Step 4: Recompile Changed Objects](#step-4-recompile-changed-objects)
  - [Step 5: Run create-diff-object](#step-5-run-create-diff-object)
  - [Step 6: Link Patch Module](#step-6-link-patch-module)
  - [Step 7: Build Final Module](#step-7-build-final-module)
  - [Step 8: Load Patch](#step-8-load-patch)
- [Example Walkthrough](#example-walkthrough)
  - [Original Code](#original-code)
  - [Patch](#patch)
  - [Binary Analysis](#binary-analysis)
- [Verification and Safety](#verification-and-safety)
- [Exit Status Codes](#exit-status-codes)
- [Key Binary Tools Summary](#key-binary-tools-summary)
- [Related Files](#related-files)
- [Limitations](#limitations)
- [Supported Architectures](#supported-architectures)
- [References](#references)

---

## Architecture Overview

```
Source Patch → kpatch-build → Patch Module (.ko) → kpatch load → Running Kernel Patched
```

### The Three Main Components

| Component | Purpose |
|-----------|---------|
| **kpatch-build** | Converts source-level diff to kernel patch module |
| **Patch module** | Contains replacement functions and metadata |
| **kpatch utility** | Manages patch modules (load/unload/status) |

---

## create-diff-object: Deep Dive

**Location:** `kpatch/kpatch-build/create-diff-object.c` (4562 lines)

### Function Signature

```bash
create-diff-object \
    orig_obj \          # Original object file
    patched_obj \       # Patched object file
    parent_name \       # Parent kernel/module name
    parent_symtab \     # Parent symbol table
    mod_symvers \       # Module.symvers file
    patch_name \        # Name of the patch
    output_obj          # Output object file
```

### Input Requirements

Both object files must be compiled with:
- `-ffunction-sections` - Each function gets its own `.text.funcname` section
- `-fdata-sections` - Each data object gets its own `.data.varname` section

This is crucial for granular comparison at function level.

---

## Main Workflow: Step by Step

### Phase 1: Initialization and Setup

```c
// Lines 4433-4434
kelf_orig = kpatch_elf_open(orig_obj);
kelf_patched = kpatch_elf_open(patched_obj);
```

**Actions:**
1. Opens both ELF files using libelf
2. Parses ELF structure into internal `kpatch_elf` representation
3. Establishes function profiling metadata for ftrace integration
4. Compares ELF/program headers for compatibility

**Key Function:** `kpatch_bundle_symbols()` (Lines 302-327)

Identifies "bundled" symbols where `sym->sec->sym == sym` - symbols with dedicated sections due to `-ffunction-sections`. Handles architecture-specific bundling:
- **PPC64:** TOC (Table of Contents) handling
- **ARM64:** Function padding detection
- **x86_64:** Standard bundling

**Key Function:** `kpatch_detect_child_functions()` (Lines 354-382)

Detects compiler-generated child functions:
- `.cold` suffix - Unlikely execution branches
- `.part` suffix - Split functions

Links parent/child relationships because changing a parent may require including its children.

---

### Phase 2: Symbol Correlation

```c
// Lines 4458-4459
kpatch_correlate_elfs(kelf_orig, kelf_patched);
kpatch_correlate_static_local_variables(kelf_orig, kelf_patched);
```

**Key Function:** `kpatch_correlate_sections()` (Lines 1137-1159)

Matches sections between orig/patched using:
- **Mangled name comparison** via `kpatch_mangled_strcmp()` (Lines 513-555)
- Handles GCC symbol mangling (`.func.123`, `.func.124` → same function)
- Special handling for `__UNIQUE_ID_*` symbols
- Skips digit suffixes added by compiler

**Correlation Process:**
```c
// From CORRELATE_ELEMENT macro (Lines 1073-1089)
sec_orig->twin = sec_patched;
sec_patched->twin = sec_orig;
// Renames mangled symbols to match original
```

**Static Local Variables:**

`kpatch_correlate_static_local_variables()` handles tricky cases:
- Compiler-generated names may differ between compilations
- Uses heuristic matching based on usage patterns
- Detects special statics (`__warned`, `__key`) that should always be included

---

### Phase 3: Symbol Replacement Optimization

```c
// Lines 4455-4456
kpatch_replace_sections_syms(kelf_orig);
kpatch_replace_sections_syms(kelf_patched);
```

**Key Function:** `kpatch_replace_sections_syms()` (Lines 1651-1792)

**Purpose:** Compiler sometimes uses section symbols instead of actual function/variable symbols. This replaces them for proper correlation.

**Example:**
```c
// Compiler might generate:
.rela.text.my_func: R_X86_64_32 .text.my_func + 10

// This changes it to:
.rela.text.my_func: R_X86_64_32 my_func + 10
```

**Special Cases:**
- **PPC64 TOC indirection** - Two-level relocations via `.toc`
- **Special sections** - `.fixup`, `.altinstr_aux`, `__ftr_alt_*`
- **UBSAN data sections** - Taken wholesale, no replacement needed

---

### Phase 4: Comparison and Change Detection

```c
// Lines 4466-4472
kpatch_mark_ignored_sections(kelf_patched);
kpatch_compare_correlated_elements(kelf_patched);
kpatch_mark_ignored_functions_same(kelf_patched);
kpatch_mark_ignored_sections_same(kelf_patched);
```

**Key Function:** `kpatch_compare_sections()` (Lines 959-997)

For each correlated section pair:

#### 1. Relocation Comparison

```c
// Lines 557-645
static bool rela_equal(struct rela *rela1, struct rela *rela2)
```

Compares:
- Relocation type
- Offset
- Addend
- Special handling for `.altinstr_aux` (x86 alternatives)
- PPC64 TOC dereferencing for accurate comparison

#### 2. Data Comparison

```c
// Lines 673-682
memcmp(sec1->data->d_buf, sec2->data->d_buf, sec1->data->d_size)
```

#### 3. Line Number Filtering

```c
// Lines 972-979
if (kpatch_line_macro_change_only(kelf, sec))
    sec->status = SAME;  // Ignore __LINE__-only changes
```

Detects `__LINE__` macro changes using `insn_is_load_immediate()` (Lines 742-810) with architecture-specific instruction pattern matching.

**Section Status Values:**
- `SAME` - No changes
- `CHANGED` - Modified
- `NEW` - Only in patched version
- `IGNORED` - Should not be included in patch

---

### Phase 5: Dependency Analysis and Inclusion

```c
// Lines 4474-4479
kpatch_include_standard_elements(kelf_patched);
num_changed = kpatch_include_changed_functions(kelf_patched);
callbacks_exist = kpatch_include_callback_elements(kelf_patched);
kpatch_include_force_elements(kelf_patched);
new_globals_exist = kpatch_include_new_globals(kelf_patched);
```

**Dependency Traversal:**

When a function changes, must include:
1. The function itself
2. All local static variables it references
3. All local functions it calls
4. Child functions (`.cold`, `.part`)
5. String literals and constants
6. Special sections (jump labels, static calls, alternatives)

---

### Phase 6: Special Section Processing

```c
// Line 4481
kpatch_process_special_sections(kelf_patched, lookup);
```

Handles architecture-specific sections:
- **Jump Labels** (`static_call`, `jump_label`)
- **Alternatives** (`altinstructions`, `altinstr_replacement`)
- **Bug Table** (`__bug_table`)
- **SFrame** unwind info

---

### Phase 7: Output Generation

```c
// Lines 4498-4519
kpatch_migrate_included_elements(kelf_patched, &kelf_out);
kpatch_create_patches_sections(kelf_out, lookup, parent_name);
kpatch_create_intermediate_sections(kelf_out, lookup, parent_name, patch_name);
kpatch_create_kpatch_arch_section(kelf_out, parent_name);
```

**Creates Special Sections:**

#### 1. `.kpatch.funcs` / `.rela.kpatch.funcs`

List of functions to be patched. Used by kernel's ftrace subsystem to redirect calls.

```c
struct kpatch_func {
    uint64_t old_addr;      // Original function address in vmlinux
    uint64_t new_addr;      // New function address in patch module
    uint64_t old_size;      // Original function size
    uint64_t new_size;      // New function size
    uint64_t name_offset;   // Offset into .kpatch.strings
};
```

#### 2. `.kpatch.dynrelas` / `.rela.kpatch.dynrelas`

Dynamic relocations for non-exported symbols. Resolved at patch load time by kpatch core module.

#### 3. `.kpatch.strings`

String table for symbol names.

#### 4. `.kpatch.arch`

Architecture-specific metadata.

**Key Function:** `kpatch_create_ftrace_callsite_sections()` (Line 4519)

Generates ftrace-specific data for function hooking. Creates `__ftrace_ops__` and related sections.

---

### Phase 8: Finalization

```c
// Lines 4528-4553
kpatch_reorder_symbols(kelf_out);
kpatch_strip_unneeded_syms(kelf_out, lookup);
kpatch_reindex_elements(kelf_out);
kpatch_write_output_elf(kelf_out, kelf_patched->elf, output_obj, 0664);
```

**Actions:**
1. Reorders symbols per linker requirements
2. Strips symbols not needed for final output
3. Rebuilds section/symbol indexes
4. Generates final `.symtab`, `.strtab`, `.shstrtab`
5. Writes the output ELF file

---

## Key Data Structures

```c
struct kpatch_elf {
    struct list_head sections;  // All sections
    struct list_head symbols;    // All symbols
    enum architecture arch;      // X86_64, PPC64, etc.
    Elf *elf;                    // libelf handle
};

struct section {
    struct list_head list;
    char *name;
    Elf64_Shdr sh;
    struct section *twin;        // Corresponding section in other ELF
    enum status status;          // SAME, CHANGED, NEW, IGNORED
    struct section *base;        // For .rela.* sections
    struct section *rela;        // Relocation section
    struct symbol *sym;          // Bundled symbol
};

struct symbol {
    struct list_head list;
    char *name;
    Elf64_Sym sym;
    struct symbol *twin;
    enum status status;
    struct section *sec;
    struct symbol *parent;       // For child functions
    struct list_head children;   // Child functions
};

struct rela {
    struct list_head list;
    unsigned long offset;
    unsigned int type;
    struct symbol *sym;
    long addend;
    char *string;                // For string relocations
};
```

---

## Architecture-Specific Handling

### x86_64
- Alternative instruction patches
- Function padding detection
- `__LINE__` immediate load detection (Lines 748-757)

### PPC64
- TOC (Table of Contents) two-level relocations
- Local entry point handling (GCC6+ 8-byte offset)
- Special TOC constant entries (Lines 220-233)

### ARM64
- BTI (Branch Target Instruction) padding
- Mapping symbols (`$x`, `$d`) filtering
- Function padding with `CONFIG_DYNAMIC_FTRACE_WITH_CALL_OPS`

### S390
- Alternative instruction handling
- Special relocation types

---

## Complete kpatch-build Workflow

### Step 1: Environment Setup

```bash
export KCFLAGS="-I$DATADIR/patch -ffunction-sections -fdata-sections"
```

### Step 2: Build Original Kernel

```bash
make "-j$CPUS" $TARGETS
```

Compiles without patch using `kpatch-cc` wrapper to monitor compilation.

### Step 3: Build Patched Kernel

```bash
apply_patches  # Applies your patch
make "-j$CPUS" $TARGETS
```

The `kpatch-cc` wrapper detects which `.o` files were rebuilt and logs them to `$TEMPDIR/changed_objs`.

### Step 4: Recompile Changed Objects

For each changed `.o`, recompile both versions with special flags:

```bash
# Original:
gcc -ffunction-sections -fdata-sections -c file.c -o orig/file.o

# Patched:
gcc -ffunction-sections -fdata-sections -c file.c -o patched/file.o
```

### Step 5: Run create-diff-object

```bash
create-diff-object \
    orig/file.o \
    patched/file.o \
    vmlinux \
    symtab \
    Module.symvers \
    patch_name \
    output/file.o
```

### Step 6: Link Patch Module

```bash
ld -r $KPATCH_LDFLAGS -o tmp_output.o $(find output -name "*.o")
```

### Step 7: Build Final Module

```bash
make -f "$DATADIR/patch/Makefile" "output.o"
```

Creates: `livepatch-patch_name.ko`

### Step 8: Load Patch

```bash
sudo kpatch load livepatch-patch_name.ko
```

---

## Example Walkthrough

### Original Code

```c
// fs/proc/meminfo.c
static int meminfo_proc_show(struct seq_file *m, void *v)
{
    seq_printf(m, "VmallocChunk:   %8lu kB\n", ...);
    return 0;
}
```

### Patch

```diff
--- a/fs/proc/meminfo.c
+++ b/fs/proc/meminfo.c
@@ -95,7 +95,7 @@
 		"VmallocTotal:   %8lu kB\n"
 		"VmallocUsed:    %8lu kB\n"
-		"VmallocChunk:   %8lu kB\n"
+		"VMALLOCCHUNK:   %8lu kB\n"
```

### Binary Analysis

**Original `.rodata.str1.1` section:**
```
"VmallocChunk:   %8lu kB\n"
```

**Patched `.rodata.str1.1` section:**
```
"VMALLOCCHUNK:   %8lu kB\n"
```

**memcmp() detects difference → MARKED AS CHANGED**

**Dependency Traversal:**
```
meminfo_proc_show() → CHANGED
    ↓ references
.rodata.str1.1 → CHANGED (must include)
    ↓ references
.rela.text.meminfo_proc_show → SAME (only data changed)
```

**Output:**
- `.text.meminfo_proc_show` (unchanged function)
- `.rodata.str1.1` (changed string data)
- `.rela.*` sections (relocations)
- `.kpatch.funcs` (metadata)
- `.kpatch.strings` (string table)

---

## Verification and Safety

**Function:** `kpatch_verify_patchability()` (Line 4486)

Ensures the patch is safe:
- No `__init` function modifications
- No static data changes (unless using callbacks/shadow variables)
- No changes to functions without ftrace support
- Validates function size/alignment constraints

---

## Exit Status Codes

- `EXIT_STATUS_SUCCESS` (0) - Patch module created successfully
- `EXIT_STATUS_NO_CHANGE` - No changes detected (Lines 4488-4495)
- `EXIT_STATUS_DIFF_FATAL` - Unreconcilable difference detected

---

## Key Binary Tools Summary

| Tool | Purpose | What it Does |
|------|---------|--------------|
| **kpatch-cc** | GCC wrapper | Monitors which files are compiled during build |
| **create-diff-object** | Binary differencer | Compares two `.o` files, extracts changes, creates metadata |
| **create-kpatch-module** | Module builder (legacy) | Adds kpatch core module support structures |
| **ld** | Linker | Combines all patched objects into final module |

---

## Related Files

- **Main script:** `kpatch/kpatch-build/kpatch-build`
- **Differencing engine:** `kpatch/kpatch-build/create-diff-object.c`
- **GCC wrapper:** `kpatch/kpatch-build/kpatch-cc`
- **README:** `kpatch/README.md`
- **Patch author guide:** `kpatch/doc/patch-author-guide.md`

---

## Limitations

1. **`__init` functions** - Not supported, returns error
2. **Static data** - Direct changes not supported (use callbacks/shadow variables)
3. **Dynamic data changes** - Cannot verify safety automatically
4. **vdso functions** - Run in userspace, ftrace can't hook them
5. **Missing fentry** - Functions without `fentry` call not supported
6. **lib-y targets** - Archived into `lib.a`, not supported

---

## Supported Architectures

- [x] x86-64
- [x] ppc64le
- [x] arm64
- [x] s390
- [x] loongarch64

---

## References

- **Kernel requirements:** gcc >= 4.8, Linux >= 4.0
- **Detection:** Applied patches visible in `/sys/kernel/livepatch`
- **Taint flag:** `TAINT_LIVEPATCH` (32768) set after applying
- **Source location:** `/home/egg/source/linux/kpatch/`

---

<!-- Source: linux kernel git repository at tag v6.19-rc5 -->
