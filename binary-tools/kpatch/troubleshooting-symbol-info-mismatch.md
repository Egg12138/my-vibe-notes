# kpatch Troubleshooting: `symbol info mismatch` Error

**Topic:** Debugging kpatch create-diff-object fatal errors
**Date:** 2026-03-07
**Level:** Advanced - Binary Analysis & Compiler Optimization

---

## Problem Description

When running `create-diff-object` with GCC14-optimized code, you may encounter:

```
ERROR: <file>.o: symbol info mismatch: <symbol_name>
unreconcilable difference
```

This error is fatal and prevents patch module generation.

---

## Root Cause Analysis

### Error Location

The error is triggered in `kpatch_compare_correlated_symbol()` (create-diff-object.c:1038-1045):

```c
static void kpatch_compare_correlated_symbol(struct symbol *sym)
{
    struct symbol *sym1 = sym, *sym2 = sym->twin;

    if (sym1->sym.st_info != sym2->sym.st_info ||
        (sym1->sec && !sym2->sec) ||
        (sym2->sec && !sym1->sec))
        DIFF_FATAL("symbol info mismatch: %s", sym1->name);
}
```

### The Real Bug: Section-Driven Symbol Correlation

**Key Insight**: The `symbol info mismatch` error does NOT come from `kpatch_correlate_symbols()`. It comes from **`kpatch_correlate_section()` cascading to symbols**.

**Correlation Flow:**

```
kpatch_correlate_sections()
  ├─ Matches sections by name via kpatch_mangled_strcmp()
  │  Example: ".text.unlikely.run.cold" == ".text.unlikely.run.cold" ✓
  │
  └─ For each matched section pair, calls kpatch_correlate_section()
       └─ __kpatch_correlate_section(sec_orig, sec_patched)  // twin = paired
       └─ kpatch_correlate_symbol(sec_orig->secsym, sec_patched->secsym)  // ← BUG HERE!
       └─ kpatch_correlate_symbol(sec_orig->sym, sec_patched->sym)        // ← BUG HERE!
```

**The Problem:**

```c
// kpatch_correlate_section() - lines 1147-1150
if (sec_orig->secsym)
    kpatch_correlate_symbol(sec_orig->secsym, sec_patched->secsym);  // No st_info check!
if (sec_orig->sym)
    kpatch_correlate_symbol(sec_orig->sym, sec_patched->sym);        // No st_info check!
```

This cascade correlation **bypasses** the `st_info` check in `kpatch_correlate_symbols()`.

### Step-by-Step Scenario

1. **Section Matching**: `.text.unlikely.run.cold` (orig) matches `.text.unlikely.run.cold` (patched)
   - `kpatch_mangled_strcmp(".text.unlikely.run.cold", ".text.unlikely.run.cold")` returns 0 (MATCH)

2. **Cascade Symbol Correlation**: `kpatch_correlate_section()` automatically correlates:
   - `sec_orig->secsym` (run.cold symbol) ↔ `sec_patched->secsym` (run.cold symbol)
   - **No `st_info` check is performed!**

3. **Verification**: Later, `kpatch_compare_correlated_symbol()` is called:
   - Original `run.cold`: `STB_LOCAL | STT_FUNC` (st_info=0x02)
   - Patched `run.cold`: `STB_WEAK | STT_FUNC` (st_info=0x22)
   - **FATAL ERROR**: `st_info` mismatch!

### Understanding `st_info`

The ELF `st_info` field is a single byte containing:

| Bits | Field | Description | Values |
|------|-------|-------------|--------|
| High 4 bits | `st_bind` | Symbol binding | `STB_LOCAL`(0), `STB_GLOBAL`(1), `STB_WEAK`(2) |
| Low 4 bits | `st_type` | Symbol type | `STT_NOTYPE`(0), `STT_OBJECT`(1), `STT_FUNC`(2) |

```c
// Encoding (from gelf.h)
#define GELF_ST_INFO(bind, type) (((bind) << 4) + (type))

// Extraction (from kpatch-elf.c)
sym->type = GELF_ST_TYPE(sym->sym.st_info);   // Low 4 bits
sym->bind = GELF_ST_BIND(sym->sym.st_info);   // High 4 bits
```

**Example values:**
- `STB_LOCAL | STT_FUNC` = `(0 << 4) + 2` = `0x02`
- `STB_WEAK | STT_FUNC` = `(2 << 4) + 2` = `0x22`

### The Bug: Validation Gap

There are **TWO** validation gaps:

| Phase | Function | Validation Check |
|-------|----------|------------------|
| **Direct Symbol Correlation** | `kpatch_correlate_symbols()` (line 1207) | Only checks `type` |
| **Section-Driven Symbol Correlation** | `kpatch_correlate_section()` (lines 1147-1150) | **NO check at all!** |
| **Verification** | `kpatch_compare_correlated_symbol()` (line 1042) | Checks full `st_info` |

**The Section-Driven Gap (PRIMARY BUG):**

```c
// kpatch_correlate_section() - lines 1147-1150
if (sec_orig->secsym)
    kpatch_correlate_symbol(sec_orig->secsym, sec_patched->secsym);  // No st_info check!
if (sec_orig->sym)
    kpatch_correlate_symbol(sec_orig->sym, sec_patched->sym);        // No st_info check!
```

When sections are correlated by name, their bundled symbols are automatically correlated **without any validation**. This is the primary source of `symbol info mismatch` errors.

**The Direct Symbol Correlation Gap (SECONDARY BUG):**

```c
// kpatch_correlate_symbols() - line 1207
if (kpatch_mangled_strcmp(sym_orig->name, sym_patched->name) ||
    sym_orig->type != sym_patched->type ||  // ← Only type, not full st_info!
    sym_patched->twin)
    continue;
```

---

## GCC14 Cold Function Separation

### What is Cold Code Separation?

GCC14 (and earlier with `-fcold-section`) can split functions into:
- **Hot path**: Frequently executed code
- **Cold path**: Rarely executed code (`.cold` suffix)

### Symbol Changes

When GCC applies cold splitting, it may change symbol properties:

| Scenario | Original ELF | Patched ELF |
|----------|--------------|-------------|
| **Before optimization** | `run` (STB_LOCAL \| STT_FUNC) | `run` (STB_LOCAL \| STT_FUNC) |
| **After GCC14 optimization** | `run` (STB_LOCAL \| STT_FUNC) | `run` (STB_WEAK \| STT_FUNC) + `run.cold` (STB_LOCAL \| STT_FUNC) |

### Why Binding Changes

GCC may change binding from `STB_LOCAL` to `STB_WEAK` when:
1. Function is split into hot/cold paths
2. Function is inlined but referenced externally
3. LTO (Link-Time Optimization) is enabled
4. Function attributes change (e.g., `__attribute__((weak))` added)

---

## Verification: `kpatch_mangled_strcmp` Behavior

A common misconception is that `kpatch_mangled_strcmp` incorrectly matches `run` with `run.cold`.

**Test Results:**

```c
kpatch_mangled_strcmp("run", "run.cold")      // Returns: 1 (DIFFERENT)
kpatch_mangled_strcmp("run.cold", "run")      // Returns: 1 (DIFFERENT)
kpatch_mangled_strcmp("func.123", "func.124") // Returns: 0 (MATCH)
kpatch_mangled_strcmp("func.123", "func")     // Returns: 0 (MATCH)
```

**Conclusion:** `kpatch_mangled_strcmp` correctly distinguishes `run` from `run.cold`. The `.cold` suffix is NOT treated like a digit suffix.

The error comes from **binding mismatch**, not name matching.

---

## Test Verification

Three test programs were implemented to verify the root cause hypothesis.

### Test Program 1: Section Name Matching (`test-section-match.c`)

Verified that section names are matched correctly:

```
kpatch_mangled_strcmp(".text.run", ".text.run")           = 0 (MATCH)
kpatch_mangled_strcmp(".text.run", ".text.run.cold")      = 1 (DIFFER)
kpatch_mangled_strcmp(".text.run.cold", ".text.run.cold") = 0 (MATCH)
```

**Finding**: `.text.run.cold` sections in orig/patched WILL be correlated as twins.

### Test Program 2: Section-Driven Symbol Correlation (`test-section-cascade.c`)

Simulated the cascade correlation in `kpatch_correlate_section()`:

```
Step 1: Section correlation (kpatch_correlate_sections)
  [CORRELATE] section .text.run               <-> .text.run
  [CORRELATE] section .text.unlikely.run.cold <-> .text.unlikely.run.cold
    [CORRELATE] symbol run.cold <-> run.cold (via section cascade!)

Step 2: Symbol verification
  run      : SAME
  [FATAL] run.cold : symbol info mismatch!
```

**Finding**: The cascade correlation bypasses `st_info` check!

### Test Results Summary

| Test | Scenario | Result |
|------|----------|--------|
| Section name matching | `.text.run.cold` vs `.text.run.cold` | MATCH |
| Cascade symbol correlation | `run.cold` (LOCAL) vs `run.cold` (WEAK) | FATAL |

### Key Findings

1. **Section names match, so sections become twins**
   - `.text.unlikely.run.cold` (orig) ↔ `.text.unlikely.run.cold` (patched)

2. **Cascade correlation automatically twins the symbols**
   - Via `kpatch_correlate_section()` lines 1147-1150
   - No `st_info` check is performed

3. **Verification fails because binding differs**
   - Original: `STB_LOCAL | STT_FUNC`
   - Patched: `STB_WEAK | STT_FUNC`

### Test Output Excerpt (Test Case 2: run.cold binding change)

```
=== BUG Version ===
  Correlating symbols (BUG version - type only)...
    [TWIN] run        <-> run
    [TWIN] run.cold   <-> run.cold

  Verifying correlated symbols...
    run                 : SAME (st_info=0x02 matches)
    [FATAL] run.cold    : symbol info mismatch!
        orig:  bind=0 (LOCAL), type=2 (FUNC), st_info=0x02
        patch: bind=2 (WEAK),   type=2 (FUNC), st_info=0x22

=== FIXED Version ===
  Correlating symbols (FIXED version - full st_info)...
    [TWIN] run        <-> run
    [SKIP] run.cold   vs run.cold: st_info mismatch (0x02 vs 0x22)

  Verifying correlated symbols...
    run      : SAME (st_info=0x02 matches)
    run.cold : NEW (no twin)
```

---

## Diagnostic Steps

### Step 1: Check Symbol Tables

Compare symbols between original and patched object files:

```bash
# Extract symbol info
readelf -sW orig.o | grep " run$"
readelf -sW patched.o | grep " run$"
```

### Step 2: Compare `st_info`

Look for differences in the `Bind` column:

```
# Original
   Num:    Value          Size Type    Bind   Vis      Ndx Name
    42: 0000000000000000    96 FUNC    LOCAL  DEFAULT   15 run

# Patched
   Num:    Value          Size Type    Bind   Vis      Ndx Name
    58: 0000000000000000    48 FUNC    WEAK   DEFAULT   15 run    # ← WEAK instead of LOCAL
    59: 000000000000000030    48 FUNC    LOCAL  DEFAULT   16 run.cold
```

### Step 3: Check for `.cold` Functions

```bash
# List all .cold functions
readelf -sW patched.o | grep "\.cold"
```

---

## Solution Approaches

### Recommended Fix: Add `st_info` Check to `kpatch_correlate_section()` (PRIMARY FIX)

**Location:** `create-diff-object.c:1147-1150`

```c
// BEFORE (BUG):
if (sec_orig->secsym)
    kpatch_correlate_symbol(sec_orig->secsym, sec_patched->secsym);  // No check!
if (sec_orig->sym)
    kpatch_correlate_symbol(sec_orig->sym, sec_patched->sym);        // No check!

// AFTER (FIX):
/*
 * Check st_info before correlating symbols to avoid false matches
 * when GCC changes symbol binding (e.g., STB_LOCAL to STB_WEAK
 * with cold function separation in GCC14+).
 */
if (sec_orig->secsym && sec_patched->secsym) {
    if (sec_orig->secsym->sym.st_info == sec_patched->secsym->sym.st_info)
        kpatch_correlate_symbol(sec_orig->secsym, sec_patched->secsym);
}
if (sec_orig->sym && sec_patched->sym) {
    if (sec_orig->sym->sym.st_info == sec_patched->sym->sym.st_info)
        kpatch_correlate_symbol(sec_orig->sym, sec_patched->sym);
}
```

**Impact:** Prevents section-driven symbol correlation from creating invalid twins when `st_info` differs.

### Secondary Fix: Full `st_info` Check in `kpatch_correlate_symbols()`

**Location:** `create-diff-object.c:1207`

```c
// BEFORE (BUG):
if (kpatch_mangled_strcmp(sym_orig->name, sym_patched->name) ||
    sym_orig->type != sym_patched->type ||
    sym_patched->twin)
    continue;

// AFTER (FIX):
if (kpatch_mangled_strcmp(sym_orig->name, sym_patched->name) ||
    sym_orig->sym.st_info != sym_patched->sym.st_info ||  // ← Check full st_info
    sym_patched->twin)
    continue;
```

**Impact:** Prevents direct symbol correlation from creating invalid twins.

---

## Hypothesis: `-freorder-functions` and Symbol Ordering

### User Observation

In the failing test scenario, adding `-fno-reorder-functions` **prevents the error from occurring**. This suggests that GCC's function reordering may play a role in triggering the bug.

### What `-freorder-functions` Does

**GCC Option:** `-freorder-functions` (enabled by default at `-O2` and higher)

**Purpose:** Reorders functions to improve cache locality and branch prediction by:
- Placing "hot" functions together
- Separating hot and cold code paths
- Optimizing call graph layout

**Related Options:**
| Option | Description |
|--------|-------------|
| `-freorder-functions` | Reorder functions for better performance |
| `-fno-reorder-functions` | Disable function reordering |
| `-fschedule-insns2` | Second instruction scheduling pass |
| `-fgcse-after-reload` | GCSE after register allocation |

### Test Results: `-freorder-functions` Impact

**Test Environment:**
- GCC 13.3.0 (Ubuntu 13.3.0-6ubuntu2~24.04.1)
- Test file: `test-cold-section.c` with `__attribute__((cold, noinline))` functions

**Test 1: Default -O2 (with `-freorder-functions`)**

```
Sections created:
  [ 5] .text.unlikely.cold_path_helper
  [ 8] .text.cold_error_handler
  [10] .text.unlikely.process
  [12] .text.process
  [14] .text.unlikely.run
  [16] .text.run
  [19] .text.unlikely.main

Symbols:
  cold_path_helper:   GLOBAL (st_info=0x12)
  cold_error_handler: GLOBAL  (st_info=0x12)
  run:                GLOBAL (st_info=0x12)
  run.cold:           LOCAL  (st_info=0x02)
  process.cold:       LOCAL  (st_info=0x02)
```

**Test 2: -O2 -fno-reorder-functions**

```
Sections created:
  [ 5] .text.cold_path_helper      (NO .unlikely prefix!)
  [ 8] .text.cold_error_handler
  [10] .text.process
  [12] .text.run
  [15] .text.main

Symbols:
  cold_path_helper:   GLOBAL (st_info=0x12)
  cold_error_handler: GLOBAL  (st_info=0x12)
  run:                GLOBAL (st_info=0x12)
  run.cold:           LOCAL  (st_info=0x02)
  process.cold:       LOCAL  (st_info=0x02)
```

**Key Findings:**

| Aspect | Default (-freorder-functions) | -fno-reorder-functions |
|--------|------------------------------|------------------------|
| `.text.unlikely.*` sections | **Yes** (5 sections) | **No** (0 sections) |
| Section count | 15 PROGBITS | 13 PROGBITS |
| Symbol bindings | LOCAL/GLOBAL unchanged | LOCAL/GLOBAL unchanged |
| `st_info` values | No change | No change |

**Conclusion:** `-freorder-functions` does **NOT** directly cause `st_info` changes. However, it:
1. Creates more `.text.unlikely.*` sections (aggressive cold code separation)
2. Increases the number of sections that must be correlated
3. **Increases the probability of triggering the cascade correlation bug** when GCC14+ changes bindings

### Mechanism: How `-freorder-functions` Exposes the Bug

```
Step 1: -freorder-functions creates more .unlikely sections
        ↓
Step 2: GCC14 cold separation may change binding (LOCAL → WEAK)
        ↓
Step 3: kpatch matches sections by name (.text.unlikely.run matches)
        ↓
Step 4: Cascade correlation (kpatch_correlate_section) correlates symbols
        ↓
Step 5: NO st_info check in cascade! Symbol twins created incorrectly
        ↓
Step 6: kpatch_compare_correlated_symbol detects mismatch → FATAL ERROR
```

**Why `-fno-reorder-functions` helps:**
- Fewer `.unlikely` sections = fewer opportunities for mismatch
- Simpler section layout = less correlation complexity
- **But:** This is a workaround, not a fix. The bug still exists!

### Simulated Bug Test

A test program (`test-correlation-bug.c`) was created to simulate the exact scenario:

**Test Case:** `cold_helper` binding change (GLOBAL → WEAK)

**BUG Version Output:**
```
Step 1: Section correlation
  [CORRELATE] section .text.unlikely.cold_helper <-> .text.unlikely.cold_helper
  [TWIN] cold_helper <-> cold_helper  ← Incorrectly correlated!

Step 2: Symbol verification
  [FATAL] cold_helper : symbol info mismatch!
          orig:  bind=1 (GLOBAL), type=2 (FUNC), st_info=0x12
          patch: bind=2 (WEAK), type=2 (FUNC), st_info=0x22
```

**FIXED Version Output (with st_info check):**
```
Step 1: Section correlation (with st_info check)
  [CORRELATE] section .text.unlikely.cold_helper <-> .text.unlikely.cold_helper
  [SKIP] cascade for cold_helper: st_info mismatch

Step 2: Symbol verification
  cold_helper : NEW (no twin)  ← Correctly handled!
```

### Final Conclusion

**`-freorder-functions` is an EXPOSURE FACTOR, not a ROOT CAUSE:**

| Factor | Role |
|--------|------|
| **Root Cause** | Cascade correlation without `st_info` check in `kpatch_correlate_section()` |
| **Trigger** | GCC14+ cold separation changing symbol binding (LOCAL ↔ WEAK) |
| **Exposure Factor** | `-freorder-functions` increases `.unlikely` section creation |

**Recommendation:**
1. **Fix:** Add `st_info` check to `kpatch_correlate_section()` (primary fix)
2. **Workaround:** Use `-fno-reorder-functions` to reduce bug triggers (not a fix!)
3. **Future:** Consider defaulting kpatch-build to `-fno-reorder-functions` for stability

---

## Related Code Locations

| File | Function | Line | Purpose |
|------|----------|------|---------|
| `create-diff-object.c` | `kpatch_correlate_symbols()` | 1197-1238 | Symbol correlation |
| `create-diff-object.c` | `kpatch_compare_correlated_symbol()` | 1038-1073 | Symbol verification |
| `create-diff-object.c` | `kpatch_mangled_strcmp()` | 529-571 | Name comparison |
| `create-diff-object.c` | `kpatch_correlate_section()` | 1134-1151 | Section correlation (CASCADE BUG!) |
| `create-diff-object.c` | `kpatch_detect_child_functions()` | 354-382 | Child function detection |
| `kpatch-elf.c` | `kpatch_create_symbol_list()` | 527-580 | Symbol list creation |

---

## Deep Dive: Why Does Cascade Correlation Exist?

### 1. GCC Compilation Flags

kpatch requires `-ffunction-sections` and `-fdata-sections`:

```
Each function → independent .text.funcname section
Each data     → independent .data.varname section
```

**Result**: Almost every symbol has its own dedicated section ("bundled" symbols).

### 2. ELF Section-Symbol Relationship

```c
struct section {
    struct symbol *secsym;  // STT_SECTION type symbol (auto-generated)
    struct symbol *sym;     // "bundled" symbol (actual function/data)
};
```

- **`secsym`**: Section symbol, auto-generated by ELF parser, points to section start
- **`sym`**: Bundled symbol, the actual function/data the section contains

### 3. Design Rationale

**Original Assumption**: When two sections are twinned, their symbols should logically be the same entity.

```
Original ELF:
  .text.meminfo_proc_show → sym: meminfo_proc_show
                          → secsym: .text.meminfo_proc_show

Patched ELF:
  .text.meminfo_proc_show → sym: meminfo_proc_show (SAME!)
                          → secsym: .text.meminfo_proc_show (SAME!)
```

For **most sections**, this assumption holds true. The cascade correlation is a **reasonable optimization** that avoids redundant symbol matching.

### 4. The Broken Assumption

**GCC14 changed the game:**

```
Original:
  .text.unlikely.run.cold → sym: run.cold (STB_LOCAL|STT_FUNC)

Patched (GCC14 cold separation):
  .text.unlikely.run.cold → sym: run.cold (STB_WEAK|STT_FUNC) ← Binding changed!
```

**Why Binding Changes:**
- Cold code separation may change symbol visibility
- LTO (Link-Time Optimization) may promote LOCAL to WEAK
- Compiler heuristics for cold code placement

### 5. Why This Bug Was Hidden

| Era | Cold Separation | Binding Changes | Bug Visible? |
|-----|-----------------|-----------------|--------------|
| Pre-GCC14 | Rare | Rare | No (assumption held) |
| GCC14+ | Common | Common | **Yes** (assumption broken) |

### 6. The Fix Trade-off

**Option A: Remove cascade correlation entirely**
- Pro: Simple, eliminates the bug
- Con: Loses optimization, all symbols must be re-matched

**Option B: Add `st_info` check to cascade**
- Pro: Preserves optimization for valid cases
- Con: More complex code

**Option C: Graceful degradation on verification failure**
- Pro: No fatal errors
- Con: Hides the underlying issue

The recommended fix is **Option B**: Add `st_info` validation before cascading.

---

## Prevention

### For Patch Authors

1. **Check compiler versions**: Ensure original and patched kernels use the same GCC version
2. **Disable aggressive optimizations**: Avoid `-fcold-section` or similar flags
3. **Review symbol changes**: Run `readelf -sW` before building patch
4. **Consider `-fno-reorder-functions`**: May reduce cold section creation (workaround, not fix)

### Temporary Workaround

If you encounter `symbol info mismatch` errors with GCC14+:

```bash
# Add to KCFLAGS in kpatch-build
export KCFLAGS="-I$DATADIR/patch -ffunction-sections -fdata-sections \
                -fno-reorder-functions \
                $ARCH_KCFLAGS $DEBUG_KCFLAGS"
```

**Warning:** This is a workaround that masks the symptom, not a fix for the root cause.

### For kpatch Developers

1. **Add `st_info` check to correlation**: Prevent incorrect twin matching
2. **Improve error messages**: Include bind/type details in error output
3. **Add warning mode**: Warn about binding changes instead of fatal error
4. **Consider default `-fno-reorder-functions`**: May reduce bug triggers in production

---

## References

- ELF Specification: [System V ABI](https://refspecs.linuxfoundation.org/elf/elf.pdf)
- GCC Cold Section: [`-fcold-section` option](https://gcc.gnu.org/onlinedocs/gcc/Optimize-Options.html)
- kpatch Source: `~/source/kpatch/kpatch-build/create-diff-object.c`

---

<!-- This document is part of the kpatch vibenotes collection -->
