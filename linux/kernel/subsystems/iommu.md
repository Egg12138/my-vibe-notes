# IOMMU (I/O Memory Management Unit)

## Overview

An **IOMMU** is a hardware component that manages device access to system memory. It's the DMA equivalent of the CPU's MMU, providing:

- **Address translation** - Device-visible addresses (IOVA) → Physical addresses (PA)
- **Access control** - Enforce what memory regions a device can access
- **Isolation** - Prevent devices from interfering with each other

## Table of Contents

- [Why IOMMU is Needed](#why-iommu-is-needed)
  - [The Problem: Direct Memory Access (DMA)](#the-problem-direct-memory-access-dma)
  - [Real-world Threats](#real-world-threats)
  - [The Solution: IOMMU](#the-solution-iommu)
- [Major Hardware Implementations](#major-hardware-implementations)
- [Use Cases](#use-cases)
  - [1. Device Assignment (VFIO / PCI Passthrough)](#1-device-assignment-vfio--pci-passthrough)
  - [2. DMA Protection for Security](#2-dma-protection-for-security)
  - [3. 64-bit Devices on 32-bit Systems](#3-64-bit-devices-on-32-bit-systems)
  - [4. Scatter-Gather List Simplification](#4-scatter-gather-list-simplification)
  - [5. Kernel Runtime Integrity](#5-kernel-runtime-integrity)
- [Memory-Mapped Registers](#memory-mapped-registers)
- [Data Structure Hierarchy](#data-structure-hierarchy)
- [Root Entry Structure](#root-entry-structure)
- [Context Entry Structure](#context-entry-structure)
- [Translation Flow Example](#translation-flow-example)
- [Domain IDs and Isolation](#domain-ids-and-isolation)
- [Extended Capabilities (ECAP_REG)](#extended-capabilities-ecap_reg)
- [PASID - Process Address Space ID](#pasid---process-address-space-id)
- [Scalable Mode (SVM)](#scalable-mode-svm)
- [Page Request Interface (PRI)](#page-request-interface-pri)
- [Nested Translation](#nested-translation)
- [Interrupt Remapping](#interrupt-remapping)
- [Architecture Overview](#architecture-overview)
- [Core Data Structures](#core-data-structures)
  - [struct iommu_ops](#struct-iommu_ops)
  - [struct iommu_domain](#struct-iommu_domain)
  - [struct iommu_group](#struct-iommu_group)
  - [struct iommu_domain_ops](#struct-iommu_domain_ops)
- [Key APIs](#key-apis)
  - [Device Registration](#device-registration)
  - [Domain Allocation](#domain-allocation)
  - [Device Attachment](#device-attachment)
  - [Page Mapping](#page-mapping)
- [DMA-IOMMU Integration](#dma-iommu-integration)
  - [struct iommu_dma_cookie](#struct-iommu_dma_cookie)
- [Reserved Regions](#reserved-regions)
- [Performance Bottlenecks](#performance-bottlenecks)
  - [1. TLB Invalidation Overhead](#1-tlb-invalidation-overhead)
  - [2. Translation Latency](#2-translation-latency)
  - [3. Cache Coherency](#3-cache-coherency)
- [Linux Performance Optimizations](#linux-performance-optimizations)
  - [1. Flush Queue (Deferred TLB Invalidation)](#1-flush-queue-deferred-tlb-invalidation)
  - [2. IOTLB Gather API](#2-iotlb-gather-api)
  - [3. Superpage Mapping](#3-superpage-mapping)
  - [4. Interrupt Aggregation](#4-interrupt-aggregation)
- [Performance Tuning Parameters](#performance-tuning-parameters)
  - [1. Flush Queue Timeout](#1-flush-queue-timeout)
  - [2. Queue Size](#2-queue-size)
  - [3. Domain Type Selection](#3-domain-type-selection)
  - [4. Large Page Usage](#4-large-page-usage)
- [Performance Best Practices](#performance-best-practices)
- [Intel VT-d](#intel-vt-d)
- [AMD-Vi](#amd-vi)
- [ARM SMMU-v3](#arm-smmu-v3)
- [Core Concepts](#core-concepts)
- [Key Use Cases](#key-use-cases)
- [Key APIs](#key-apis)
- [File Locations](#file-locations)
- [Configuration](#configuration)
- [Debugging](#debugging)

---

## Why IOMMU is Needed

### The Problem: Direct Memory Access (DMA)

Without protection, devices with DMA capabilities can read/write **any** physical memory address. A malicious or buggy device could:

- Read sensitive data (encryption keys, passwords)
- Corrupt kernel memory
- Bypass security mechanisms

### Real-world Threats

- **Thunderclap** exploit (2018) - DMA over Thunderbolt ports
- **PCILeech** - DMA attack using FPGA cards
- **FireWire/PCIe attacks** - Direct memory access attacks

### The Solution: IOMMU

The IOMMU sits between devices and system memory, providing:
- Hardware-enforced memory isolation
- Per-device address spaces
- Protection against malicious/buggy devices

## Major Hardware Implementations

| Vendor | Name | Common Use |
|--------|------|------------|
| **Intel** | VT-d (Virtualization Technology for Directed I/O) | Server & desktop PCs |
| **AMD** | AMD-Vi / IOMMU | Server & desktop PCs |
| **ARM** | SMMU (System Memory Management Unit) | Mobile, embedded, SoCs |
| **RISC-V** | RISC-V IOMMU | RISC-V systems |

## Use Cases

### 1. Device Assignment (VFIO / PCI Passthrough)

**Scenario:** Pass a physical device (e.g., GPU, NIC) directly to a virtual machine.

**Without IOMMU:** The device could DMA anywhere, corrupting host memory or other VMs.

**With IOMMU:** Each VM gets its own IO address space. The IOMMU ensures:
- VM1's GPU can only access VM1's guest memory
- Host memory remains protected
- Devices are isolated between VMs

### 2. DMA Protection for Security

**Scenario:** A compromised or malicious device (external Thunderbolt, USB controller).

**Threats mitigated:**
- DMA attacks against system memory
- Reading encryption keys from RAM
- Overwriting kernel code to escalate privileges

**Implementation:** Untrusted devices are blocked from accessing sensitive memory regions.

### 3. 64-bit Devices on 32-bit Systems

**Scenario:** A device with 64-bit DMA addressing needs to operate on a system with limited physical memory.

**Problem:** Device can only address memory above 4GB, but system wants to use low memory.

**Solution:** IOMMU creates a contiguous 64-bit view that maps to fragmented physical pages.

### 4. Scatter-Gather List Simplification

**Scenario:** A device needs a buffer, but memory is fragmented.

**Without IOMMU:** Device must support scatter-gather lists (multiple physical addresses).

**With IOMMU:** Kernel maps scattered pages into a contiguous device-visible range.

### 5. Kernel Runtime Integrity

**Scenario:** Protect kernel text and critical data structures from accidental DMA corruption.

**Implementation:** Linux marks kernel regions as privileged; IOMMU blocks device access even for buggy drivers.

---

# Intel VT-d Architecture

## Memory-Mapped Registers

| Register Offset | Name | Purpose |
|-----------------|------|---------|
| `0x0` | VER_REG | Architecture version |
| `0x8` | CAP_REG | Hardware capabilities |
| `0x10` | ECAP_REG | Extended capabilities |
| `0x18` | GCMD_REG | Global command (enable/disable) |
| `0x1c` | GSTS_REG | Global status |
| `0x20` | RTADDR_REG | Root table address |
| `0x28` | CCMD_REG | Context command |
| `0x80` | IQH_REG | Invalidation Queue Head |
| `0x88` | IQT_REG | Invalidation Queue Tail |

Source: `drivers/iommu/intel/iommu.h:68-99`

## Data Structure Hierarchy

```
┌─────────────────────────────────────────────────────────────────┐
│                    Root Entry Table                             │
│  (One entry per PCI Bus, indexed by Bus Number)                 │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
                    ┌─────────────────────┐
                    │   Root Entry        │
                    ├─────────────────────┤
                    │ lo: LCTP (Context)  │──┐
                    │ hi: UCTP (Context)  │  │
                    └─────────────────────┘  │
                                             │
                              ┌──────────────┘
                              │
                              ▼
                    ┌─────────────────────┐
                    │  Context Table      │
                    │  (256 entries)      │
                    │  [Device:Function]  │
                    └─────────────────────┘
                              │
                              ▼
                    ┌─────────────────────┐
                    │   Context Entry     │
                    ├─────────────────────┤
                    │ Present (bit 0)     │
                    │ FPD (bit 1)         │
                    │ Translation Type    │
                    │ Page Table Pointer  │──► 4-level or 5-level Page Table
                    │ Address Width       │
                    │ Domain ID           │
                    └─────────────────────┘
                              │
                              ▼
                    ┌─────────────────────┐
                    │   Page Tables       │
                    │   (EPT format)      │
                    └─────────────────────┘
```

## Root Entry Structure

Source: `drivers/iommu/intel/iommu.h:555-558`

```c
struct root_entry {
    u64 lo;  // Lower Context Table Pointer (LCTP)
    u64 hi;  // Upper Context Table Pointer (UCTP)
};
```

**Fields:**
- **Bit 0**: Present (P) - Entry is valid
- **Bit 1**: Fault Processing Disable (FPD)
- **Bits 12-63**: Context table pointer (4KB aligned)

## Context Entry Structure

Source: `drivers/iommu/intel/iommu.h:571-574`

```c
struct context_entry {
    u64 lo;  // Lower 64 bits
    u64 hi;  // Upper 64 bits
};
```

**Lower 64 bits:**
| Bits | Field | Description |
|------|-------|-------------|
| 0 | Present | Entry valid |
| 1 | FPD | Fault processing disable |
| 2-3 | Translation Type | 10=Page Table, 11=Pass-through |
| 12-63 | Address Space Root | Page table pointer |

**Upper 64 bits:**
| Bits | Field | Description |
|------|-------|-------------|
| 0-2 | Address Width | AGAW (Adjusted Guest Address Width) |
| 8-23 | Domain ID | Domain identifier |

## Translation Flow Example

Trace a DMA request from `0000:01:00.0` (Bus 1, Device 0, Function 0):

```
1. Device requests DMA to IOVA 0x1234_5000
   │
2. IOMMU extracts Bus Number = 1
   │
3. Root Entry[1] → Context Table at 0xABCD_0000
   │
4. Context Entry[0x00] (Dev:Func 0:0) → Page Table at 0xFEDC_1000
   │
5. Page Table Walk:
   PML4[0x1] → PDPT at 0x...
   PDPT[0x2]  → PD at 0x...
   PD[0x34]   → PT at 0x...
   PT[0x500]  → Physical Page 0xDEAD_B000
   │
6. IOMMU checks permissions (R/W)
   │
7. Translation complete: IOVA 0x1234_5000 → PA 0xDEAD_B000
   │
8. DMA proceeds to physical address
```

## Domain IDs and Isolation

Source: `drivers/iommu/intel/iommu.h:578-581`

```c
u16 did;  // Domain ids per IOMMU. Use u16 since domain ids are
          // 16 bit wide according to VT-d spec, section 9.3
```

Each **Domain ID** represents an isolated address space:
- Different VMs get different Domain IDs
- Devices can only access memory mapped to their domain
- The IOMMU enforces isolation in hardware

---

# Advanced Intel VT-d Features

## Extended Capabilities (ECAP_REG)

Source: `drivers/iommu/intel/iommu.h:194-223`

| Feature | Bit | Description |
|---------|-----|-------------|
| **PASID** | 40 | Process Address Space ID - SVA support |
| **PSS** | 35-39 | PASID size - max PASID values |
| **PRR** | 29 | Page Request Reporting |
| **ERS** | 30 | Extended Range Register |
| **SRS** | 31 | Supervisor Request |
| **EAFS** | 34 | Extended Access Flag |
| **NWFS** | 33 | No Write Flag |
| **NEST** | 26 | Nested translation |
| **MTS** | 25 | Migration |
| **DT** | 41 | Device-TLB Invalidation |
| **SC** | 7 | Snooping Control |
| **IR** | 3 | Interrupt Remapping |
| **EIM** | 4 | Extended Interrupt Mode |
| **PT** | 6 | Pass-through mode |

## PASID - Process Address Space ID

**What is PASID?**

PASID enables **Shared Virtual Memory (SVM)**, allowing devices to directly access the process's virtual address space. A single device can have multiple address spaces (one per PASID).

Source: `drivers/iommu/intel/pasid.h:35-51`

```c
struct pasid_dir_entry {
    u64 val;
};

struct pasid_entry {
    u64 val[8];  // 512 bits per entry
};
```

**PASID Table Hierarchy:**

```
┌──────────────────────────────────────────────────────────────┐
│                   Context Entry (Device)                     │
│  ┌────────────────────────────────────────────────────────┐  │
│  │ Bit 3: PASID Enable                                    │  │
│  │ Bits 12-63: PASID Table Pointer                        │  │
│  └────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌──────────────────────────────────────────────────────────────┐
│                   PASID Directory                            │
│            (Up to 2^6 = 64 entries)                         │
└──────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌──────────────────────────────────────────────────────────────┐
│                   PASID Table                                │
│         (Up to 2^20 = 1,048,576 entries per dir)             │
│                    indexed by PASID                          │
└──────────────────────────────────────────────────────────────┘
                            │
                            ▼
                    ┌───────────────┐
                    │  PASID Entry  │
                    ├───────────────┤
                    │ Domain ID     │
                    │ PGTT (Type)   │───► FLPT-only (First Level)
                    │ FLPT Pointer  │───► SLPT-only (Second Level)
                    │ SLPT Pointer  │───► Nested (Both levels)
                    │              │───► Passthrough
                    │ Permissions  │
                    │ Snoop bit    │
                    └───────────────┘
```

**PASID Entry Types** Source: `drivers/iommu/intel/pasid.h:43-46`

| Type | Value | Description |
|------|-------|-------------|
| `FL_ONLY` | 1 | First-level only (process page tables) |
| `SL_ONLY` | 2 | Second-level only (IOMMU-managed) |
| `NESTED` | 3 | Two-stage translation |
| `PT` | 4 | Passthrough (no translation) |

**PASID Use Cases:**

1. **SVA (Shared Virtual Addressing)**: Device uses CPU page tables directly
   - Zero-copy I/O
   - Unified address space between CPU and device

2. **Multiple Processes per Device**: Each process gets its own PASID
   - GPU rendering multiple applications simultaneously
   - NIC handling connections from different processes

3. **SR-IOV with Multiple VFs**: Each VF can have multiple PASIDs

## Scalable Mode (SVM)

Source: `drivers/iommu/intel/iommu.h:536-537`

```c
#define sm_supported(iommu) (intel_iommu_sm && ecap_smts((iommu)->ecap))
```

Scalable mode introduces:
- **PASID** for process-specific address spaces
- **Page Request Interface** for demand paging
- **Nested translation** for VM device assignment with SVA

## Page Request Interface (PRI)

**Purpose**: Devices can request pages on-demand, similar to CPU page faults.

**Flow:**
```
1. Device attempts DMA to unmapped address
   │
2. IOMMU blocks access and sends Page Request
   │
3. Handler allocates/faults in the page
   │
4. IOMMU updates translation
   │
5. Device retries DMA successfully
```

## Nested Translation

**Purpose**: Used for VMs with SVA - two-stage translation:

```
┌─────────────────────────────────────────────────────────────┐
│              Device DMA Request (gIOVA)                     │
└─────────────────────────────────────────────────────────────┘
                          │
                          ▼
        ┌─────────────────────────────────────────┐
        │   Stage 1: Guest Page Tables (gPA)      │  Guest-controlled
        │   (First Level Translation)             │
        └─────────────────────────────────────────┘
                          │
                          ▼
        ┌─────────────────────────────────────────┐
        │   Stage 2: Host Page Tables (hPA)       │  Host-controlled
        │   (Second Level Translation)            │
        └─────────────────────────────────────────┘
                          │
                          ▼
                    Physical Memory
```

**Why Nested Translation?**

- **VM with device assignment**: Guest manages its own mappings
- **SVA in VMs**: Guest processes get device passthrough
- **Security**: Host controls final physical access

## Interrupt Remapping

**Purpose**: Extend IOMMU protection to interrupt handling, preventing:

- MSIs from corrupting memory
- Malicious devices injecting interrupts

**Interrupt Remapping Table (IRTA):**

```
MSI Request from Device
        │
        ▼
   IOMMU IR Table Lookup
        │
        ▼
   Remapped to System Interrupt
```

---

# Linux IOMMU Implementation

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                      Device Drivers                             │
│                  (use DMA API: dma_map_* etc.)                  │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    DMA Mapping Layer                            │
│              drivers/iommu/dma-iommu.c                          │
│      (IOVA allocation, scatter-gather, flush queue)             │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                      IOMMU Core Framework                       │
│                   drivers/iommu/iommu.c                         │
│           (domain/group management, API routing)                │
└─────────────────────────────────────────────────────────────────┘
                              │
              ┌───────────────┼───────────────┐
              ▼               ▼               ▼
     ┌──────────────┐ ┌──────────────┐ ┌──────────────┐
     │  Intel VT-d  │ │   AMD-Vi     │ │  ARM SMMU    │
     │ intel/iommu.c│ │ amd/iommu.c  │ │ arm-smmu-*   │
     └──────────────┘ └──────────────┘ └──────────────┘
              │               │               │
              └───────────────┴───────────────┘
                              ▼
                    ┌──────────────────┐
                    │  Hardware IOMMU  │
                    └──────────────────┘
```

## Core Data Structures

### struct iommu_ops

Source: `include/linux/iommu.h:602-713`

The **operations interface** that each hardware driver must implement:

```c
struct iommu_ops {
    // Capability queries
    bool (*capable)(struct device *dev, enum iommu_cap);
    void *(*hw_info)(struct device *dev, u32 *length, enum iommu_hw_info_type *type);

    // Domain allocation (multiple variants)
    struct iommu_domain *(*domain_alloc_paging)(struct device *dev);
    struct iommu_domain *(*domain_alloc_sva)(struct device *dev, struct mm_struct *mm);
    struct iommu_domain *(*domain_alloc_nested)(struct device *dev,
                                                 struct iommu_domain *parent,
                                                 u32 flags, ...);

    // Device lifecycle
    struct iommu_device *(*probe_device)(struct device *dev);
    void (*release_device)(struct device *dev);

    // Device grouping
    struct iommu_group *(*device_group)(struct device *dev);

    // Reserved regions (MSI, RMRR)
    void (*get_resv_regions)(struct device *dev, struct list_head *list);

    // Pre-allocated special domains
    struct iommu_domain *identity_domain;  // Passthrough
    struct iommu_domain *blocked_domain;   // Block all DMA
    struct iommu_domain *default_domain;   // Default DMA domain
};
```

### struct iommu_domain

Source: `include/linux/iommu.h:223-251`

Represents an **IOMMU address space** (translation domain):

```c
struct iommu_domain {
    unsigned type;                          // Domain type
    const struct iommu_domain_ops *ops;     // Page table operations
    const struct iommu_ops *owner;          // Creating driver
    unsigned long pgsize_bitmap;            // Supported page sizes
    struct iommu_domain_geometry geometry;  // Address range

    union {
        struct iommu_dma_cookie *iova_cookie;  // DMA allocator
        struct iommu_dma_msi_cookie *msi_cookie; // MSI remapping
        struct {  // Fault handler
            iommu_fault_handler_t handler;
            void *handler_token;
        };
        struct {  // SVA
            struct mm_struct *mm;
            int users;
        };
    };
};
```

**Domain Types:**

| Type | Purpose |
|------|---------|
| `IOMMU_DOMAIN_BLOCKED` | Block all DMA (for isolation) |
| `IOMMU_DOMAIN_IDENTITY` | Passthrough (IOVA == PA) |
| `IOMMU_DOMAIN_UNMANAGED` | User-managed (VFIO, VMs) |
| `IOMMU_DOMAIN_DMA` | Kernel DMA API managed |
| `IOMMU_DOMAIN_DMA_FQ` | DMA with flush queue optimization |
| `IOMMU_DOMAIN_SVA` | Shared Virtual Addressing |
| `IOMMU_DOMAIN_NESTED` | Nested translation (for virtualization) |

### struct iommu_group

Source: `drivers/iommu/iommu.c:52-68`

**Device isolation groups** - devices that share address translation:

```c
struct iommu_group {
    struct kobject kobj;
    struct list_head devices;           // Devices in group
    struct xarray pasid_array;          // PASID mappings
    struct mutex mutex;
    int id;

    struct iommu_domain *default_domain;  // DMA domain
    struct iommu_domain *domain;          // Current domain

    unsigned int owner_cnt;              // External ownership (VFIO)
    void *owner;
};
```

**Why Groups?** Devices in a group cannot be isolated from each other at hardware level - they can DMA to each other's memory. The IOMMU enforces that all devices in a group share the same translations.

### struct iommu_domain_ops

Source: `include/linux/iommu.h:715-782`

**Domain-specific operations** for page table manipulation:

```c
struct iommu_domain_ops {
    // Attach/detach
    int (*attach_dev)(struct iommu_domain *domain, struct device *dev, ...);
    int (*set_dev_pasid)(struct iommu_domain *domain, struct device *dev,
                        ioasid_t pasid, ...);

    // Page table manipulation
    int (*map_pages)(struct iommu_domain *domain, unsigned long iova,
                    phys_addr_t paddr, size_t pgsize, size_t pgcount,
                    int prot, gfp_t gfp, size_t *mapped);
    size_t (*unmap_pages)(struct iommu_domain *domain, unsigned long iova,
                         size_t pgsize, size_t pgcount, ...);

    // TLB flushing
    void (*flush_iotlb_all)(struct iommu_domain *domain);
    void (*iotlb_sync)(struct iommu_domain *domain, ...);

    // Queries
    phys_addr_t (*iova_to_phys)(struct iommu_domain *domain, dma_addr_t iova);

    // Cleanup
    void (*free)(struct iommu_domain *domain);
};
```

## Key APIs

### Device Registration

Source: `drivers/iommu/iommu.c:260-284`

```c
int iommu_device_register(struct iommu_device *iommu,
                         const struct iommu_ops *ops,
                         struct device *hwdev)
```

Called by hardware drivers during initialization:
1. Validates ops has owner set (for modular drivers)
2. Associates ops with the IOMMU device
3. Adds to global `iommu_device_list`
4. Triggers bus probing for IOMMU-capable buses

### Domain Allocation

Source: `drivers/iommu/iommu.c:2048-2094`

```c
struct iommu_domain *iommu_paging_domain_alloc(struct device *dev)
```

Flow:
1. Gets driver's `iommu_ops` from device
2. Calls driver's `domain_alloc_paging()` op
3. Initializes domain with type and ops
4. Returns domain or ERR_PTR

### Device Attachment

Source: `drivers/iommu/iommu.c:2160-2184`

```c
int iommu_attach_device(struct iommu_domain *domain, struct device *dev)
```

Flow:
1. Gets device's IOMMU group
2. **Requires group has exactly 1 device**
3. Calls `__iommu_attach_group()` for entire group
4. Domain's `attach_dev()` programs hardware

**Important:** IOMMU operates at **group granularity**, not device granularity.

### Page Mapping

Source: `drivers/iommu/iommu.c:2582-2597`

```c
int iommu_map(struct iommu_domain *domain, unsigned long iova,
             phys_addr_t paddr, size_t size, int prot, gfp_t gfp)
```

Flow:
1. Validates alignment with minimum page size
2. Calls `domain->ops->map_pages()`
3. Syncs TLB if needed
4. On error, unrolls partial mappings

## DMA-IOMMU Integration

Source: `drivers/iommu/dma-iommu.c`

### struct iommu_dma_cookie

Source: `drivers/iommu/dma-iommu.c:57-77`

```c
struct iommu_dma_cookie {
    struct iova_domain iovad;          // IOVA allocator
    struct list_head msi_page_list;    // MSI remapping pages

    // Flush queue (deferred TLB invalidation)
    union {
        struct iova_fq *single_fq;
        struct iova_fq __percpu *percpu_fq;
    };

    struct timer_list fq_timer;        // Flush timer
    struct iommu_domain *fq_domain;    // Associated domain
};
```

## Reserved Regions

Critical memory ranges that must be handled specially:

| Type | Description |
|------|-------------|
| `IOMMU_RESV_DIRECT` | Must be 1:1 mapped (boot resources) |
| `IOMMU_RESV_DIRECT_RELAXABLE` | Usually 1:1, relaxable for some cases |
| `IOMMU_RESV_RESERVED` | Never map these ranges |
| `IOMMU_RESV_MSI` | Hardware MSI window (untranslated) |
| `IOMMU_RESV_SW_MSI` | Software-managed MSI translation |

IOMMU drivers expose these via `get_resv_regions()` op, and the DMA layer ensures proper mapping.

---

# IOMMU Performance Deep Dive

## Performance Bottlenecks

### 1. TLB Invalidation Overhead

**The Problem:** Every `unmap()` operation requires invalidating cached translations in:
- **IOTLB** (IOMMU TLB) - Inside the IOMMU hardware
- **DevTLB** (Device TLB) - On devices with ATS (Address Translation Services)

**Why it's expensive:**
- TLB invalidations are MMIO writes to hardware registers
- May require waiting for completion (especially for DevTLB)
- Unmapping scattered pages = many individual invalidations

### 2. Translation Latency

**Address Translation Path:**

```
DMA Request
    │
    ├─> IOTLB Lookup (L1 cache)
    │       │ Hit → Return PA (~10-50 cycles)
    │       │ Miss →
    │       │
    │       └─> Page Table Walk (memory reads)
    │               ├─> Root Entry
    │               ├─> Context Entry
    │               ├─> PML4
    │               ├─> PDPT
    │               ├─> PD
    │               └─> PT (~200-500 cycles for full walk)
    │
    └─> Permission Check
            └─> Caching in IOTLB
```

**Performance Impact:**
- TLB miss with full walk: 100-1000x slower than hit
- Critical for high-throughput devices (NICs, storage)
- Larger page sizes reduce walks but waste memory

### 3. Cache Coherency

**When hardware doesn't maintain coherency:**
- Software must flush CPU caches before device DMA
- Requires CLFLUSH or memory barriers
- Can cost thousands of cycles per operation

## Linux Performance Optimizations

### 1. Flush Queue (Deferred TLB Invalidation)

Source: `drivers/iommu/dma-iommu.c:97-247`

**The key optimization for DMA domains:**

```c
struct iommu_dma_cookie {
    struct iova_domain iovad;

    // Flush queue (deferred TLB invalidation)
    union {
        struct iova_fq *single_fq;
        struct iova_fq __percpu *percpu_fq;
    };

    atomic64_t fq_flush_start_cnt;
    atomic64_t fq_flush_finish_cnt;
    struct timer_list fq_timer;
    atomic_t fq_timer_on;
    struct iommu_domain *fq_domain;
};
```

**How it works:**

```
Without Flush Queue:
    unmap() → TLB flush → unmap() → TLB flush → unmap() → TLB flush
    (3 TLB flushes)

With Flush Queue:
    unmap() → queue
    unmap() → queue
    unmap() → queue
    [timer expires or queue full]
    → single TLB flush for all
    (1 TLB flush)
```

**Implementation details:**

1. **Per-CPU or single queue** (configurable)
2. **Counter-based synchronization**
3. **Timer-based flushing** (dma-iommu.c:101-103):
```c
#define IOVA_DEFAULT_FQ_TIMEOUT  10
#define IOVA_SINGLE_FQ_TIMEOUT   1000
```

4. **Queue-full handling**

**Performance benefits:**
- Reduces TLB flushes by 10-100x for high-frequency unmapping
- Per-CPU queues avoid lock contention
- Safe due to counter synchronization

**When it's used:**
- `IOMMU_DOMAIN_DMA_FQ` (kernel DMA API)
- Not for VFIO/unmanaged domains (need immediate invalidation)

### 2. IOTLB Gather API

Source: `include/linux/iommu.h:343-364`

**Batching invalidations for unmap operations:**

```c
struct iommu_iotlb_gather {
    unsigned long   start;      // Range start
    unsigned long   end;        // Range end (inclusive)
    size_t          pgsize;     // Granule size
    struct iommu_pages_list freelist;  // Pages to free after sync
    bool            queued;     // Will queue the flush
};
```

**Usage pattern:**

```c
// Batch multiple unmaps
struct iommu_iotlb_gather gather;
iommu_iotlb_gather_init(&gather);

iommu_unmap_pages(domain, iova1, size, &gather);
iommu_unmap_pages(domain, iova2, size, &gather);
iommu_unmap_pages(domain, iova3, size, &gather);

// Single flush for all
iommu_iotlb_sync(domain, &gather);
```

**Benefits:**
- Coalesces adjacent ranges
- Single large invalidation instead of many small ones
- Reduced MMIO overhead

### 3. Superpage Mapping

**Using larger pages reduces TLB pressure:**

| Page Size | Coverage | TLB Efficiency |
|-----------|----------|----------------|
| 4KB | 1 page | Poor |
| 64KB | 16 pages | Better |
| 2MB | 512 pages | Good |
| 1GB | 262,144 pages | Excellent |

**Trade-offs:**
- **Pros:** Fewer TLB entries, faster walks, smaller page tables
- **Cons:** Memory fragmentation, allocation overhead

**Implementation:** Drivers advertise supported page sizes via `pgsize_bitmap`

### 4. Interrupt Aggregation

**ARM SMMU interrupt handling:**

```c
[CMDQ_ERR_CERROR_ATC_INV_IDX] = "ATC invalidate timeout",
```

**Benefits:**
- Batch multiple events per interrupt
- Reduces interrupt handler overhead
- Event queue instead of per-fault interrupts

## Performance Tuning Parameters

### 1. Flush Queue Timeout

| Setting | Use Case | Trade-off |
|---------|----------|-----------|
| 10ms (default) | High throughput | Lower latency |
| 100ms+ | Low traffic | Higher throughput |

**Kernel parameter:** `iommu_dma_fq_timeout`

### 2. Queue Size

| Size | Use Case |
|------|----------|
| Single queue | Low-core systems |
| Per-CPU queue | High-core systems |

**Trade-offs:**
- Single: Less memory, possible contention
- Per-CPU: More memory, better scaling

### 3. Domain Type Selection

| Domain Type | Performance | Use Case |
|-------------|-------------|----------|
| `IOMMU_DOMAIN_DMA_FQ` | Best | Kernel DMA API |
| `IOMMU_DOMAIN_DMA` | Good | Simple devices |
| `IOMMU_DOMAIN_IDENTITY` | Best (no translation) | Trusted devices |

### 4. Large Page Usage

```c
// Check if domain supports superpages
if (domain->pgsize_bitmap & SZ_2M)
    // Use 2MB pages for large mappings
```

## Performance Best Practices

1. **Use appropriate domain type:**
   - DMA_FQ for most kernel drivers
   - Identity for trusted legacy devices

2. **Prefer large mappings:**
   - Use `dma_alloc_coherent()` for buffers > PAGE_SIZE
   - Consider `vmalloc` backed by contiguous pages

3. **Batch operations:**
   - Use scatter-gather for multiple buffers
   - Avoid many small map/unmap cycles

4. **Cache coherency:**
   - Check `IOMMU_CAP_CACHE_COHERENCY` capability
   - Use `dma_sync_*` APIs appropriately

5. **Device grouping:**
   - Minimize devices per IOMMU group
   - Consider PCIe ACS enablement

6. **NUMA awareness:**
   - Allocate DMA memory near the IOMMU
   - Consider node-local memory for high-throughput

---

# Hardware Driver Registration Examples

## Intel VT-d

Source: `drivers/iommu/intel/iommu.c:3911-3928`

```c
const struct iommu_ops intel_iommu_ops = {
    .blocked_domain         = &blocking_domain,
    .identity_domain        = &identity_domain,
    .domain_alloc_paging_flags = intel_iommu_domain_alloc_paging_flags,
    .domain_alloc_sva       = intel_svm_domain_alloc,
    .domain_alloc_nested    = intel_iommu_domain_alloc_nested,
    .probe_device           = intel_iommu_probe_device,
    .release_device         = intel_iommu_release_device,
    .device_group           = intel_iommu_device_group,
    .get_resv_regions       = intel_iommu_get_resv_regions,
    .page_response          = intel_iommu_page_response,
};
```

## AMD-Vi

Source: `drivers/iommu/amd/iommu.c:3080-3094`

```c
const struct iommu_ops amd_iommu_ops = {
    .blocked_domain         = &blocked_domain,
    .identity_domain        = &identity_domain.domain,
    .domain_alloc_paging_flags = amd_iommu_domain_alloc_paging_flags,
    .domain_alloc_sva       = amd_iommu_domain_alloc_sva,
    .probe_device           = amd_iommu_probe_device,
    .release_device         = amd_iommu_release_device,
    .device_group           = amd_iommu_device_group,
    .get_resv_regions       = amd_iommu_get_resv_regions,
};
```

## ARM SMMU-v3

Source: `drivers/iommu/arm/arm-smmu-v3/arm-smmu-v3.c:3678-3708`

```c
static const struct iommu_ops arm_smmu_ops = {
    .identity_domain        = &arm_smmu_identity_domain,
    .blocked_domain         = &arm_smmu_blocked_domain,
    .domain_alloc_paging_flags = arm_smmu_domain_alloc_paging_flags,
    .probe_device           = arm_smmu_probe_device,
    .device_group           = arm_smmu_device_group,
    .of_xlate               = arm_smmu_of_xlate,
    .default_domain_ops = &(const struct iommu_domain_ops) {
        .attach_dev     = arm_smmu_attach_dev,
        .map_pages      = arm_smmu_map_pages,
        .unmap_pages    = arm_smmu_unmap_pages,
        .flush_iotlb_all = arm_smmu_flush_iotlb_all,
        .iova_to_phys   = arm_smmu_iova_to_phys,
        .free           = arm_smmu_domain_free_paging,
    }
};
```

---

# Quick Reference

## Core Concepts

| Concept | Description |
|---------|-------------|
| **IOMMU** | I/O Memory Management Unit - hardware for device DMA address translation and isolation |
| **IOVA** | I/O Virtual Address - device-side address |
| **PA** | Physical Address - system memory address |
| **Domain** | IOMMU address space with isolated translations |
| **PASID** | Process Address Space ID - enables SVA (multiple address spaces per device) |
| **IOTLB** | IOMMU Translation Lookaside Buffer - hardware cache |
| **ACS** | Access Control Services - PCIe P2P isolation |

## Key Use Cases

| Use Case | IOMMU Feature |
|----------|---------------|
| VM device assignment | Domain isolation, nested translation |
| DMA protection | Blocked/identity domains |
| SVA (Shared Virtual Memory) | PASID, page request interface |
| 64-bit device on 32-bit system | Address translation |
| Scatter-gather simplification | Contiguous IOVA mapping |

## Key APIs

```c
// IOMMU device registration
int iommu_device_register(struct iommu_device *iommu,
                         const struct iommu_ops *ops,
                         struct device *hwdev);

// Domain allocation
struct iommu_domain *iommu_paging_domain_alloc(struct device *dev);
struct iommu_domain *iommu_domain_alloc_sva(struct device *dev, struct mm_struct *mm);

// Device attachment
int iommu_attach_device(struct iommu_domain *domain, struct device *dev);
void iommu_detach_device(struct iommu_domain *domain, struct device *dev);

// Page table manipulation
int iommu_map(struct iommu_domain *domain, unsigned long iova,
             phys_addr_t paddr, size_t size, int prot, gfp_t gfp);
size_t iommu_unmap(struct iommu_domain *domain, unsigned long iova, size_t size);

// TLB operations
void iommu_flush_iotlb_all(struct iommu_domain *domain);
void iommu_iotlb_sync(struct iommu_domain *domain,
                     struct iommu_iotlb_gather *iotlb_gather);

// IOMMU group
struct iommu_group *iommu_group_alloc(void);
int iommu_attach_group(struct iommu_domain *domain, struct iommu_group *group);
```

## File Locations

| Component | Path |
|-----------|------|
| Core framework | `drivers/iommu/iommu.c` |
| DMA layer | `drivers/iommu/dma-iommu.c` |
| IOMMU headers | `include/linux/iommu.h` |
| Intel VT-d | `drivers/iommu/intel/` |
| AMD-Vi | `drivers/iommu/amd/` |
| ARM SMMU-v3 | `drivers/iommu/arm/arm-smmu-v3/` |
| Page tables | `drivers/iommu/io-pgtable.c` |
| Fault handling | `drivers/iommu/io-pgfault.c` |

## Configuration

| Kernel Parameter | Purpose |
|------------------|---------|
| `intel_iommu=on` | Enable Intel VT-d |
| `amd_iommu=on` | Enable AMD-Vi |
| `iommu.passthrough` | Use identity domains |
| `iommu.strict` | Disable flush queue |
| `iommu_dma_fq_timeout` | Flush queue timeout (ms) |

## Debugging

```bash
# Check IOMMU status
dmesg | grep -i iommu
cat /sys/kernel/iommu_groups/*/

# Trace IOMMU operations
trace-cmd record -e iommu:*
trace-cmd report

# Check performance
perf stat -e iommu:* ./app
```

---

# Performance Optimization Summary

| Optimization | Mechanism | Benefit |
|--------------|-----------|---------|
| **Flush Queue** | Deferred TLB invalidation | 10-100x fewer flushes |
| **IOTLB Gather** | Batch invalidations | Single flush per operation |
| **Superpages** | Larger page sizes | Fewer TLB misses |
| **Per-CPU Queues** | Avoid lock contention | Better scaling |
| **Command Queues** | Async operations | Higher throughput |

---

*Notes generated from Linux kernel source at commit: 944aacb68baf*
*Repository: git://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git*
