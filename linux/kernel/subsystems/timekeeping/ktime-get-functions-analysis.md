# Linux Kernel ktime_get_*() Functions - Complete Analysis

## Table of Contents

- [Overview](#overview)
- [Summary of Functions](#summary-of-functions)
- [Call Chain Overview](#call-chain-overview)
- [Detailed Call Chains by Category](#detailed-call-chains-by-category)
  - [1. Monotonic Time (CLOCK_MONOTONIC)](#1-monotonic-time-clock_monotonic)
  - [2. Realtime (CLOCK_REALTIME)](#2-realtime-clock_realtime)
  - [3. Boottime (CLOCK_BOOTTIME)](#3-boottime-clock_boottime)
  - [4. TAI (International Atomic Time)](#4-tai-international-atomic-time)
  - [5. Raw Monotonic (CLOCK_MONOTONIC_RAW)](#5-raw-monotonic-clock_monotonic_raw)
  - [6. Fast NMI-Safe Functions](#6-fast-nmi-safe-functions)
  - [7. Snapshot Functions](#7-snapshot-functions)
- [Key Data Structures](#key-data-structures)
- [Clock Source Types](#clock-source-types)
- [Reference Locations](#reference-locations)

---

## Overview

This document provides a comprehensive analysis of all `ktime_get_*()` functions in the Linux kernel timekeeping subsystem. These functions provide various interfaces for reading time from different clock sources, with different precision, performance, and safety characteristics.

**Kernel Version Analyzed:** Linux v5.10-rc7

---

## Summary of Functions

The Linux kernel provides **43 distinct `ktime_get_*()` functions** organized into 9 categories:

| Category | Count | Clock Source Base | Description |
|----------|-------|-------------------|-------------|
| Standard Monotonic | 6 | `tkr_mono` | Monotonic time since boot (excluding suspend) |
| Realtime | 7 | `tkr_mono` + `offs_real` | Wall clock time |
| Boottime | 6 | `tkr_mono` + `offs_boot` | Monotonic time including suspend |
| TAI (Atomic Time) | 6 | `tkr_mono` + `offs_tai` | International Atomic Time (UTC + leap seconds) |
| Raw Monotonic | 3 | `tkr_raw` (no NTP) | Raw monotonic (unadjusted by NTP) |
| Fast/NMI-Safe | 4 | seqcount latch | NMI-safe access using seqcount latch |
| Snapshot | 2 | All clocks | Simultaneous snapshot of multiple clocks |
| Generic/Conversion | 5 | Utility | Generic offset-based and conversion functions |
| Resolution/Utility | 4 | Metadata | Clock resolution and seconds-only access |

---

## Call Chain Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        ktime_get_*() Interface Layer                        │
│  ktime_get() │ ktime_get_real() │ ktime_get_boottime() │ ktime_get_raw()    │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                      Generic / Offset Functions                             │
│  ktime_get_with_offset() │ timekeeping_get_ns()                            │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         Core Timekeeping                                    │
│  read_seqcount_begin() │ tk->tkr_*.base │ ktime_add_ns()                   │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                      Cycle to Nanosecond Conversion                        │
│  timekeeping_delta_to_ns()                                                 │
│    ├─> delta * tkr->mult + tkr->xtime_nsec                                 │
│    └─> nsec >>= tkr->shift                                                 │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                        Clock Source Read                                    │
│  timekeeping_get_delta()                                                   │
│    ├─> tk_clock_read(&tk->tkr_mono)                                        │
│    │    └─> clock->read(clock)  ───────────────────┐                       │
│    └─> clocksource_delta(now, last, mask)          │                       │
└─────────────────────────────────────────────────────────────────────────────┘
                                                           │
                                                           ▼
                                              ┌─────────────────────────────┐
                                              │   HARDWARE CLOCKSOURCE      │
                                              │   TSC, ARM_ARCH_timer,      │
                                              │   ACPI_PM, HPET, etc.       │
                                              └─────────────────────────────┘
```

---

## Detailed Call Chains by Category

### 1. Monotonic Time (CLOCK_MONOTONIC)

#### ktime_get()
**Location:** `kernel/time/timekeeping.c:821`
**Purpose:** Get monotonic time in ktime_t format (nanoseconds since boot, excluding suspend)

```
ktime_get()
  └─> read_seqcount_begin(&tk_core.seq)
  └─> base = tk->tkr_mono.base
  └─> nsecs = timekeeping_get_ns(&tk->tkr_mono)
       └─> delta = timekeeping_get_delta(&tk->tkr_mono)
            └─> now = tk_clock_read(&tk->tkr_mono)
                 └─> clock->read(clock)                    ◄─── HARDWARE
            └─> clocksource_delta(now, last, mask)
       └─> timekeeping_delta_to_ns(tkr, delta)
            └─> (delta * mult + xtime_nsec) >> shift
  └─> ktime_add_ns(base, nsecs)
```

#### ktime_get_ns()
**Location:** `include/linux/timekeeping.h:152`
**Purpose:** Get monotonic time in nanoseconds

```
ktime_get_ns()
  └─> ktime_to_ns(ktime_get())
```

#### ktime_get_coarse()
**Location:** `include/linux/timekeeping.h:116`
**Purpose:** Get coarse monotonic time (faster, lower precision)

```
ktime_get_coarse()
  └─> ktime_get_coarse_ts64()
       └─> tk_xtime(tk) + tk->wall_to_monotonic
```

#### ktime_get_ts64()
**Location:** `kernel/time/timekeeping.c:954`
**Purpose:** Get monotonic time in timespec64 format

```
ktime_get_ts64()
  └─> tk->xtime_sec + tk->wall_to_monotonic.tv_sec
  └─> timekeeping_get_ns(&tk->tkr_mono)
```

#### ktime_get_seconds()
**Location:** `kernel/time/timekeeping.c:986`
**Purpose:** Get seconds portion of monotonic time (direct read, non-serialized)

```
ktime_get_seconds()
  └─> tk->ktime_sec  (direct read)
```

#### ktime_get_coarse_ns()
**Location:** `include/linux/timekeeping.h:124`

---

### 2. Realtime (CLOCK_REALTIME)

#### ktime_get_real()
**Location:** `include/linux/timekeeping.h:77`
**Purpose:** Get wall clock (real) time in ktime_t format

```
ktime_get_real()
  └─> ktime_get_with_offset(TK_OFFS_REAL)
       └─> base = ktime_add(tk->tkr_mono.base, tk->offs_real)
       └─> nsecs = timekeeping_get_ns(&tk->tkr_mono)
       └─> ktime_add_ns(base, nsecs)
```

#### ktime_get_real_ns()
**Location:** `include/linux/timekeeping.h:157`

```
ktime_get_real_ns()
  └─> ktime_to_ns(ktime_get_real())
```

#### ktime_get_real_ts64()
**Location:** `kernel/time/timekeeping.c:800`

```
ktime_get_real_ts64()
  └─> tk->xtime_sec
  └─> timekeeping_get_ns(&tk->tkr_mono)
```

#### ktime_get_real_seconds()
**Location:** `kernel/time/timekeeping.c:1006`

```
ktime_get_real_seconds()
  └─> tk->xtime_sec
```

#### ktime_get_coarse_real()
**Location:** `include/linux/timekeeping.h:82`

#### ktime_get_coarse_real_ns()
**Location:** `include/linux/timekeeping.h:129`

#### ktime_get_coarse_real_ts64()
**Location:** `kernel/time/timekeeping.c:2233`

---

### 3. Boottime (CLOCK_BOOTTIME)

#### ktime_get_boottime()
**Location:** `include/linux/timekeeping.h:93`
**Purpose:** Get monotonic time including time spent in suspend

```
ktime_get_boottime()
  └─> ktime_get_with_offset(TK_OFFS_BOOT)
       └─> base = ktime_add(tk->tkr_mono.base, tk->offs_boot)
       └─> nsecs = timekeeping_get_ns(&tk->tkr_mono)
```

#### ktime_get_boottime_ns()
**Location:** `include/linux/timekeeping.h:162`

#### ktime_get_boottime_ts64()
**Location:** `include/linux/timekeeping.h:187`

#### ktime_get_boottime_seconds()
**Location:** `include/linux/timekeeping.h:197`

#### ktime_get_coarse_boottime()
**Location:** `include/linux/timekeeping.h:98`

#### ktime_get_coarse_boottime_ns()
**Location:** `include/linux/timekeeping.h:134`

#### ktime_get_coarse_boottime_ts64()
**Location:** `include/linux/timekeeping.h:192`

---

### 4. TAI (International Atomic Time)

#### ktime_get_clocktai()
**Location:** `include/linux/timekeeping.h:106`
**Purpose:** Get TAI time (UTC + leap seconds)

```
ktime_get_clocktai()
  └─> ktime_get_with_offset(TK_OFFS_TAI)
       └─> base = ktime_add(tk->tkr_mono.base, tk->offs_tai)
```

#### ktime_get_clocktai_ns()
**Location:** `include/linux/timekeeping.h:167`

#### ktime_get_clocktai_ts64()
**Location:** `include/linux/timekeeping.h:202`

#### ktime_get_clocktai_seconds()
**Location:** `include/linux/timekeeping.h:212`

#### ktime_get_coarse_clocktai()
**Location:** `include/linux/timekeeping.h:111`

#### ktime_get_coarse_clocktai_ns()
**Location:** `include/linux/timekeeping.h:139`

#### ktime_get_coarse_clocktai_ts64()
**Location:** `include/linux/timekeeping.h:207`

---

### 5. Raw Monotonic (CLOCK_MONOTONIC_RAW)

#### ktime_get_raw()
**Location:** `kernel/time/timekeeping.c:928`
**Purpose:** Get raw (unadjusted) monotonic time

```
ktime_get_raw()
  └─> base = tk->tkr_raw.base  (no NTP adjustment)
  └─> nsecs = timekeeping_get_ns(&tk->tkr_raw)
       └─> [same conversion path, but uses tkr_raw]
```

#### ktime_get_raw_ns()
**Location:** `include/linux/timekeeping.h:172`

#### ktime_get_raw_ts64()
**Location:** `kernel/time/timekeeping.c:1492`

```
ktime_get_raw_ts64()
  └─> tk->raw_sec
  └─> timekeeping_get_ns(&tk->tkr_raw)
```

---

### 6. Fast NMI-Safe Functions

These functions use seqcount latch protection for NMI-safe access.

#### ktime_get_mono_fast_ns()
**Location:** `kernel/time/timekeeping.c:492`
**Purpose:** NMI-safe monotonic time access

```
ktime_get_mono_fast_ns()
  └─> __ktime_get_fast_ns(&tk_fast_mono)
       └─> raw_read_seqcount_latch(&tkf->seq)
       └─> tkr = tkf->base + (seq & 0x01)  ◄────── Dual-buffer latch
       └─> base_ns = ktime_to_ns(tkr->base)
       └─> delta = timekeeping_delta_to_ns(tkr,
            └─> clocksource_delta(tk_clock_read(tkr), tkr->cycle_last, tkr->mask))
       └─> base_ns + delta
```

#### ktime_get_raw_fast_ns()
**Location:** `kernel/time/timekeeping.c:498`

```
ktime_get_raw_fast_ns()
  └─> __ktime_get_fast_ns(&tk_fast_raw)
```

#### ktime_get_boot_fast_ns()
**Location:** `kernel/time/timekeeping.c:525`

```
ktime_get_boot_fast_ns()
  └─> ktime_get_mono_fast_ns() + ktime_to_ns(tk->offs_boot)
```

#### ktime_get_real_fast_ns()
**Location:** `kernel/time/timekeeping.c:561`

```
ktime_get_real_fast_ns()
  └─> __ktime_get_real_fast(&tk_fast_mono, NULL)
       └─> baser = ktime_to_ns(tkr->base_real)
       └─> delta = timekeeping_delta_to_ns(...)
       └─> baser + delta
```

---

### 7. Snapshot Functions

#### ktime_get_snapshot()
**Location:** `kernel/time/timekeeping.c:1041`
**Purpose:** Simultaneous snapshot of multiple clock sources with cycle counter

```
ktime_get_snapshot()
  └─> read_seqcount_begin(&tk_core.seq)
  └─> cycles = tk_clock_read(&tk->tkr_mono)
  └─> base_real = ktime_add(tk->tkr_mono.base, tk->offs_real)
  └─> base_raw = tk->tkr_raw.base
  └─> nsec_real = timekeeping_cycles_to_ns(&tk->tkr_mono, cycles)
  └─> nsec_raw = timekeeping_cycles_to_ns(&tk->tkr_raw, cycles)
  └─> return {
         .cycles = cycles,
         .real = base_real + nsec_real,
         .raw = base_raw + nsec_raw,
         ...
       }
```

#### ktime_get_fast_timestamps()
**Location:** `kernel/time/timekeeping.c:613`
**Purpose:** NMI-safe simultaneous mono/boot/real timestamps

```
ktime_get_fast_timestamps()
  └─> __ktime_get_real_fast(&tk_fast_mono, &snapshot->mono)
  └─> snapshot->boot = snapshot->mono + ktime_to_ns(tk->offs_boot)
```

---

## Key Data Structures

### struct timekeeper
**Location:** `include/linux/timekeeper_internal.h`

```c
struct timekeeper {
    struct tk_read_base tkr_mono;      // CLOCK_MONOTONIC base
    struct tk_read_base tkr_raw;       // CLOCK_MONOTONIC_RAW (no NTP)
    u64 xtime_sec;                     // CLOCK_REALTIME seconds
    unsigned long ktime_sec;           // CLOCK_MONOTONIC seconds
    struct timespec64 wall_to_monotonic;
    ktime_t offs_real;                 // Monotonic → Realtime offset
    ktime_t offs_boot;                 // Monotonic → Boottime offset
    ktime_t offs_tai;                  // Monotonic → TAI offset
    s32 tai_offset;                    // UTC to TAI offset (leap seconds)
    u64 raw_sec;                       // CLOCK_MONOTONIC_RAW seconds
    struct timespec64 monotonic_to_boot;
    // ... additional fields
};
```

### struct tk_read_base
**Location:** `include/linux/timekeeper_internal.h`

```c
struct tk_read_base {
    struct clocksource *clock;         // Hardware clocksource
    u64 mask;                          // Cycle mask for wrapping
    u64 cycle_last;                    // Last read cycle count
    u32 mult;                          // NTP-adjusted multiplier
    u32 shift;                         // Right shift value
    u64 xtime_nsec;                    // Fractional nanoseconds
    ktime_t base;                      // Base time (ktime_t)
    u64 base_real;                     // For fast realtime access
};
```

---

## Clock Source Types

From `include/uapi/linux/time.h`:

| Constant | Value | Description |
|----------|-------|-------------|
| `CLOCK_REALTIME` | 0 | Wall clock time |
| `CLOCK_MONOTONIC` | 1 | Monotonic time since boot (not counting suspend) |
| `CLOCK_MONOTONIC_RAW` | 4 | Raw monotonic time (unadjusted by NTP) |
| `CLOCK_REALTIME_COARSE` | 5 | Coarse realtime (faster, lower precision) |
| `CLOCK_MONOTONIC_COARSE` | 6 | Coarse monotonic |
| `CLOCK_BOOTTIME` | 7 | Monotonic including suspend time |
| `CLOCK_TAI` | 11 | TAI (International Atomic Time) |

From `include/linux/timekeeping.h`:

```c
enum tk_offsets {
    TK_OFFS_REAL,      // Maps to CLOCK_REALTIME
    TK_OFFS_BOOT,      // Maps to CLOCK_BOOTTIME
    TK_OFFS_TAI,       // Maps to CLOCK_TAI
    TK_OFFS_MAX,
};
```

Offset array definition from `kernel/time/timekeeping.c:858-862`:

```c
static ktime_t *offsets[TK_OFFS_MAX] = {
    [TK_OFFS_REAL]   = &tk_core.timekeeper.offs_real,
    [TK_OFFS_BOOT]   = &tk_core.timekeeper.offs_boot,
    [TK_OFFS_TAI]    = &tk_core.timekeeper.offs_tai,
};
```

---

## Reference Locations

| File | Description |
|------|-------------|
| `include/linux/timekeeping.h` | Public API definitions (inline functions) |
| `kernel/time/timekeeping.c` | Core implementation |
| `include/linux/timekeeper_internal.h` | Internal data structures |
| `include/uapi/linux/time.h` | CLOCK_* constants |
| `kernel/time/timekeeping.h` | Internal declarations |

---

<!--
Generated from Linux kernel source
Repository: /home/egg/source/linux
Version: v5.10-rc7
Generated: 2026-02-25 01:55:56 UTC
-->
