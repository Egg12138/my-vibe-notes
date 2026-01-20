# Linux Random Number Generator - Deep Dive

> Comprehensive notes on Linux kernel random number generation architecture, entropy collection, and the cryptographic PRNG implementation.

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Entropy Sources](#entropy-sources)
- [The Three-Tier Design](#the-three-tier-design)
- [ChaCha20 PRNG](#chacha20-prng)
- [Device Interfaces](#device-interfaces)
- [getrandom() System Call](#getrandom-system-call)
- [vDSO Optimization](#vdso-optimization)
- [Key Implementation Files](#key-implementation-files)
- [Security Considerations](#security-considerations)
- [Historical Context](#historical-context)
- [Testing and Validation](#testing-and-validation)

---

## Overview

Linux random number generation is a **cryptographically secure** system that provides unpredictable random bytes for:

- Encryption key generation
- Session tokens
- Nonces for cryptographic protocols
- One-time passwords
- Secure random initialization vectors

### Core Principles

1. **Entropy from Reality**: Collects randomness from hardware timing variations
2. **Cryptographic Security**: Uses ChaCha20 stream cipher with fast key erasure
3. **Performance**: Per-CPU states, vDSO fast path
4. **Forward Secrecy**: Keys are immediately erased after use

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         ENTROPY SOURCES                                  │
├─────────────────────────────────────────────────────────────────────────┤
│  • Interrupts (keyboard, mouse, network, timers)                        │
│  • Device-specific data (MAC, serial numbers, RTC)                      │
│  • Hardware RNGs (Intel RDRAND, AMD RDSEED)                             │
│  • Disk I/O timing                                                       │
│  • Bootloader seeds                                                      │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                    PER-CPU FAST POOLS (SipHash)                         │
│  • Lockless mixing of interrupt entropy                                 │
│  • Batch mixing: 1024 IRQs or 1 second                                   │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                    INPUT POOL (BLAKE2s, 256 bits)                       │
│  • Cryptographic accumulation of all entropy                            │
│  • Seeding point for CRNG                                               │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                    BASE CRNG (Master ChaCha20 Key)                      │
│  • Reseeded every 60 seconds                                           │
│  • Generates per-CPU keys                                               │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│                    PER-CPU CRNG (ChaCha20 States)                       │
│  • Lockless fast path for random bytes                                  │
│  • One per CPU for scalability                                          │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│              OUTPUT: /dev/random, /dev/urandom, getrandom()             │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Entropy Sources

### 1. Interrupt Entropy (`add_interrupt_randomness`)

**Location**: `drivers/char/random.c:1113`

```c
void add_interrupt_randomness(int irq)
{
    unsigned long entropy = random_get_entropy();  // RDTSC on x86
    struct fast_pool *fast_pool = this_cpu_ptr(&irq_randomness);
    struct pt_regs *regs = get_irq_regs();

    fast_mix(fast_pool->pool, entropy,
             (regs ? instruction_pointer(regs) : _RET_IP_) ^ swab(irq));
    // ... batching logic
}
```

**Sources**:
- Keyboard interrupts
- Mouse interrupts
- Network packet interrupts
- Timer interrupts
- Other hardware IRQs

**Entropy Value**: ~1 bit per 64 interrupts (conservative estimate)

### 2. Input Events (`add_input_randomness`)

**Location**: `drivers/char/random.c:1218`

- Keyboard event timing
- Mouse event timing
- Excludes autorepeat events

### 3. Disk I/O (`add_disk_randomness`)

**Location**: `drivers/char/random.c:1234`

- Block device operation timing
- Per-disk state tracking

### 4. Device Randomness (`add_device_randomness`)

**Location**: `drivers/char/random.c:942`

- MAC addresses
- Serial numbers
- RTC read-out

**Important**: Does NOT credit entropy (just differentiates devices)

### 5. Hardware RNGs (`add_hwgenerator_randomness`)

**Location**: `drivers/char/random.c:959`

- Intel RDRAND
- AMD RDSEED
- Dedicated hardware RNG chips

---

## The Three-Tier Design

### Tier 1: Input Pool

```c
struct {
    struct blake2s_ctx hash;      // BLAKE2s cryptographic hash
    spinlock_t lock;
    unsigned int init_bits;        // Entropy bits collected
} input_pool;
```

- **Size**: 256 bits of entropy
- **Hash**: BLAKE2s for cryptographic mixing
- **Purpose**: Accumulate all entropy sources

### Tier 2: Base CRNG

```c
struct {
    u8 key[CHACHA_KEY_SIZE];      // 32-byte master key
    unsigned long generation;      // Reseed generation counter
    spinlock_t lock;
} base_crng;
```

- **Reseed Interval**: Every 60 seconds
- **Purpose**: Master seed for per-CPU CRNGs

### Tier 3: Per-CPU CRNG

```c
struct crng {
    u8 key[CHACHA_KEY_SIZE];
    unsigned long generation;
    local_lock_t lock;
};

static DEFINE_PER_CPU(struct crng, crngs);
```

- **One Per CPU**: Lockless, scalable
- **Automatic Updates**: Sync with base_crng generation

---

## ChaCha20 PRNG

### Why ChaCha20?

- **Fast**: Designed for speed on modern CPUs
- **Secure**: Withstood extensive cryptanalysis
- **Simple**: Easy to implement correctly
- **Stream Cipher**: Generates arbitrary-length output

### Key Properties

```
Key size:   256 bits (32 bytes)
Nonce:      96 bits (12 bytes)
Block size: 64 bytes (512 bits)
Rounds:     20 (hence "ChaCha20")
```

### Fast Key Erasure

```c
// Simplified flow
1. Use current key to generate random bytes
2. IMMEDIATELY generate a NEW key
3. Old key is gone forever (forward secrecy)
```

**Implementation**: `drivers/char/random.c:315-338`

```c
static void crng_fast_key_erasure(u8 key[CHACHA_KEY_SIZE],
                                   u8 chacha_state[CHACHA_BLOCK_SIZE * 8],
                                   u8 *dst, size_t len)
{
    // Generate ChaCha20 blocks
    // First 32 bytes become new key
    // Remaining bytes go to output
    // Original key is overwritten
}
```

---

## Device Interfaces

### `/dev/random` vs `/dev/urandom`

**In Modern Linux (5.6+)**: Both use the SAME ChaCha20 CRNG!

The only difference is **blocking behavior before initialization**:

| Device | Blocks Before Init? | After Init | Recommended |
|--------|---------------------|------------|-------------|
| `/dev/random` | Yes (waits) | Same as urandom | Legacy only |
| `/dev/urandom` | No (warns) | Same as random | ✅ Yes |

### Implementation Comparison

**`/dev/urandom`** (`drivers/char/random.c:1462`):

```c
static ssize_t urandom_read_iter(struct kiocb *kiocb, struct iov_iter *iter)
{
    if (!crng_ready())
        try_to_generate_entropy();  // Don't wait

    if (!crng_ready()) {
        pr_notice("uninitialized urandom read (%zu bytes)\n", ...);
    }

    return get_random_bytes_user(iter);  // NEVER BLOCKS
}
```

**`/dev/random`** (`drivers/char/random.c:1486`):

```c
static ssize_t random_read_iter(struct kiocb *kiocb, struct iov_iter *iter)
{
    if (!crng_ready() && (kiocb->ki_filp->f_flags & O_NONBLOCK))
        return -EAGAIN;

    ret = wait_for_random_bytes();  // BLOCK until ready
    if (ret != 0)
        return ret;

    return get_random_bytes_user(iter);  // SAME as urandom!
}
```

---

## getrandom() System Call

### Prototype

```c
ssize_t getrandom(void *buf, size_t buflen, unsigned int flags);
```

### Flags

| Flag | Value | Behavior |
|------|-------|----------|
| `GRND_NONBLOCK` | 0x0001 | Return `-EAGAIN` if not ready |
| `GRND_RANDOM` | 0x0002 | No effect (legacy compatibility) |
| `GRND_INSECURE` | 0x0004 | Return data immediately (like urandom) |

### Usage Examples

```c
// Blocking call (waits for CRNG initialization)
ssize_t ret = getrandom(buffer, 32, 0);

// Non-blocking
ssize_t ret = getrandom(buffer, 32, GRND_NONBLOCK);
if (ret < 0 && errno == EAGAIN) {
    // Not ready yet
}

// Insecure (early boot, doesn't need crypto)
ssize_t ret = getrandom(buffer, 32, GRND_INSECURE);
```

### Implementation

**Location**: `drivers/char/random.c:1394`

```c
SYSCALL_DEFINE3(getrandom, char __user *, ubuf, size_t, len, unsigned int, flags)
{
    if (!crng_ready() && !(flags & GRND_INSECURE)) {
        if (flags & GRND_NONBLOCK)
            return -EAGAIN;
        ret = wait_for_random_bytes();
        if (unlikely(ret))
            return ret;
    }
    return get_random_bytes_user(&iter);
}
```

---

## vDSO Optimization

### What is vDSO?

**Virtual Dynamic Shared Object** - A shared library mapped into every process that allows certain "syscalls" to execute entirely in userspace.

### The Performance Problem

```
Traditional System Call:
┌─────────┐     ┌─────────┐     ┌─────────┐     ┌─────────┐
│ userspace│ ──▶ │ syscall │ ──▶ │ kernel  │ ──▶ │ userspace│
└─────────┘     └─────────┘     └─────────┘     └─────────┘
   ~1000 CPU cycles (context switch overhead)
```

### The vDSO Solution

```
vDSO getrandom():
┌──────────────────────────────────────────────────────────────┐
│ userspace ChaCha20 + memory read from shared vDSO page       │
└──────────────────────────────────────────────────────────────┘
   ~50-100 CPU cycles (10-20x faster!)
```

### State Structure

**Location**: `include/vdso/getrandom.h:33`

```c
struct vgetrandom_state {
    union {
        u8 batch[96];        // 1.5 blocks of buffered output
        u32 key[8];          // 256-bit ChaCha20 key
    };
    u8  batch_key[128];      // Overwritten on each generation
    u64 generation;          // Kernel RNG generation counter
    u8  pos;                 // Current position in batch
    bool in_use;             // Reentrancy guard
};
```

### The Algorithm

1. Check if kernel generation changed → reseed if needed
2. Return bytes from batch buffer if available
3. If buffer empty → generate new ChaCha20 blocks
4. Overwrite batch_key (forward secrecy!)
5. Check generation again (fork detection)

### Memory Layout

```
┌─────────────────────────────────────────────────────────────┐
│  batch[96]  │     key[32]     │ generation │ pos │ in_use │
│  (buffered) │   (next key)    │   (u64)    │(u8) │ (bool) │
└─────────────────────────────────────────────────────────────┘
   ↑                       ↑
   └───────────────────────┴── batch_key[128] gets overwritten
                                (forward secrecy)
```

---

## Key Implementation Files

### Core Implementation

| File | Purpose |
|------|---------|
| `drivers/char/random.c` | Main RNG implementation (~1500 lines) |
| `lib/crypto/chacha.c` | ChaCha20 stream cipher |
| `include/linux/random.h` | Internal kernel API |
| `include/uapi/linux/random.h` | Userspace API |

### vDSO Implementation

| File | Purpose |
|------|---------|
| `lib/vdso/getrandom.c` | vDSO getrandom() fast path |
| `include/vdso/getrandom.h` | vDSO state structures |
| `include/vdso/datapage.h` | Shared kernel-userspace data |

### Architecture-Specific

| Path | Description |
|------|-------------|
| `arch/*/crypto/chacha*.c` | Architecture-optimized ChaCha20 |
| `arch/*/include/asm/archrandom.h` | Hardware RNG (RDRAND) access |

---

## Security Considerations

### Pre-Initialization (Early Boot)

**Scenario**: CRNG not yet ready

```
/dev/urandom read:
├─ Returns data immediately
├─ Kernel logs warning (max 10 times)
└─ ⚠️ NOT cryptographically secure!

/dev/random read:
├─ Blocks until CRNG is ready
└─ ✅ Cryptographically secure
```

### Forward Secrecy

The RNG implements **fast key erasure**:

```c
// Each generation:
1. Use current key to produce output
2. Generate NEW key from output
3. Old key is overwritten
4. Cannot recover old keys even with future state
```

### Fork Detection

After `fork()`, parent and child have identical RNG state:

```c
// Check if generation changed
if (unlikely(READ_ONCE(state->generation) != READ_ONCE(rng_info->generation))) {
    // Fork happened or kernel reseeded
    // Get new key and regenerate
}
```

The kernel increments the generation counter on reseed, forcing both processes to detect the duplication.

### Signal Handler Safety

```c
in_use = READ_ONCE(state->in_use);
if (unlikely(in_use))
    goto fallback_syscall;  // Don't corrupt state in signal handler
WRITE_ONCE(state->in_use, true);
```

Prevents reentrancy issues if a signal interrupts getrandom().

---

## Historical Context

### The Old Days (pre-5.6)

```
/dev/random:
├─ Required entropy from input pool
├─ Blocked when "entropy count" was low
└─ Could block indefinitely on servers

/dev/urandom:
├─ Used SHA-1 hash as PRNG
├─ Never blocked
└─ Considered "less secure"
```

### Modern Linux (5.6+)

```
Both devices:
├─ Same ChaCha20-based cryptographically secure PRNG
├─ Per-CPU states for performance
├─ Fast key erasure for forward secrecy
└─ Same quality output

Only difference: Blocking behavior before initialization
```

### entropy_avail Is Now Legacy

```bash
$ cat /proc/sys/kernel/random/entropy_avail
3072
# ↑ This value has NO effect on blocking anymore!
# /dev/random no longer blocks based on entropy count
```

---

## Testing and Validation

### Test Program

A comprehensive test program is available at: `/home/egg/source/linux/random_test.c`

**Features**:
- Quality tests (chi-square, byte distribution)
- Performance benchmarks
- Avalanche effect testing
- Entropy status reporting

### Compile and Run

```bash
gcc -Wall -O2 -o random_test random_test.c

# Show entropy status
./random_test -S

# Quality analysis with 1MB sample
./random_test -q -s 1000000

# Benchmark
./random_test -b -i 10000

# All tests
./random_test -S -q -s 100000 -b -i 10000 -a
```

### Quality Test Results

```
Unique byte values: 256 / 256 (100.0%)
Chi-square: 243.37 (expected: 189-325)
✓ PASS: Chi-square test indicates randomness
```

### Performance Results

```
Source              Throughput    Latency
──────────────────────────────────────────
/dev/urandom        357.26 MB/s   10.93 µs
/dev/random         366.99 MB/s   10.62 µs
getrandom(0)        367.85 MB/s   10.62 µs
getrandom(NONBLOCK) 371.89 MB/s   10.50 µs
```

All sources have nearly identical performance because they use the same underlying CRNG.

---

## References

### Kernel Documentation

- `drivers/char/random.c` - Source code with extensive comments
- `Documentation/admin-guide/sysctl/kernel.rst` - Sysctl interface

### Key Papers

- "Fast Key Erasure RNGs" - The theoretical foundation
- ChaCha20 specification - Daniel J. Bernstein
- SipHash - Jean-Philippe Aumasson

### Related Concepts

- **BLAKE2s**: Cryptographic hash for entropy mixing
- **SipHash/HSipHash**: Fast mixing for interrupt entropy
- **RDRAND/RDSEED**: Intel/AMD hardware RNG instructions

---

## Summary

| Aspect | Details |
|--------|---------|
| **Algorithm** | ChaCha20 stream cipher |
| **Entropy Sources** | Interrupts, devices, hardware RNG |
| **Security** | Forward secrecy, CSPRNG |
| **Performance** | Per-CPU states, vDSO fast path |
| **APIs** | `/dev/random`, `/dev/urandom`, `getrandom()` |
| **Best Practice** | Use `getrandom()` or `/dev/urandom` |
| **Historical Note** | `/dev/random` blocking is mostly obsolete |

---

**Source**: Linux kernel v6.19-rc5-42-g944aacb68baf
**Generated**: 2026-01-20
**Location**: `drivers/char/random.c`, `lib/crypto/chacha.c`, `lib/vdso/getrandom.c`
