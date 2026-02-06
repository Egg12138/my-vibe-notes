# ARM SMMUv3 DMA Execution Flow Analysis

## Table of Contents

- [Kconfig Dependency Chain for DMA](#kconfig-dependency-chain-for-dma)
- [DMA Ops Assignment Flow](#dma-ops-assignment-flow)
- [DMA Flow Comparison](#dma-flow-comparison)
  - [WITHOUT ARM_SMMU_V3 Module Loaded](#without-arm_smmu_v3-module-loaded)
  - [WITH ARM_SMMU_V3 Module Loaded](#with-arm_smmu_v3-module-loaded)
- [Detailed Function Locations](#detailed-function-locations)
- [SVA Shared Virtual Addressing DMA Flow](#sva-shared-virtual-addressing-dma-flow)
- [Key Differences Summary](#key-differences-summary)

---

## Kconfig Dependency Chain for DMA

### CONFIG_IOMMU_DMA

**Location:** `drivers/iommu/Kconfig:98-104`

```kconfig
config IOMMU_DMA
    bool
    select DMA_OPS
    select IOMMU_API
    select IOMMU_IOVA
    select IRQ_MSI_IOMMU
    select NEED_SG_DMA_LENGTH
```

**Impact:** Enables dma-iommu.c - the glue layer between DMA API and IOMMU

---

## DMA Ops Assignment Flow

### Device Initialization Chain

```
of_platform_device_create() / pci_device_add()
    │
    └─> of_dma_configure_id()  [drivers/of/device.c:91-182]
            │
            ├─> iommu = of_iommu_configure(dev, np, id)  [Line 173]
            │       └─> Returns iommu_ops if IOMMU present in DT
            │
            └─> arch_setup_dma_ops(dev, dma_base, size, iommu, coherent)  [Line 182]
                    │
                    └─> [arch/arm64/mm/dma-mapping.c:40-59]
                            │
                            ├─> if (iommu)
                            │       └─> iommu_setup_dma_ops(dev, dma_base, size)  [Line 52-53]
                            │               │
                            │               └─> [drivers/iommu/dma-iommu.c:1176-1197]
                            │                       │
                            │                       ├─> domain = iommu_get_domain_for_dev(dev)
                            │                       │
                            │                       ├─> if (domain->type == IOMMU_DOMAIN_DMA)
                            │                       │       └─> dev->dma_ops = &iommu_dma_ops;  [Line 1190]
                            │                       │
                            │                       └─> iommu_dma_init_domain(domain, ...)
                            │
                            └─> else: dev->dma_ops = NULL (uses direct mapping)
```

---

## DMA Flow Comparison

### WITHOUT ARM_SMMU_V3 Module Loaded

**When:** ARM_SMMU_V3.ko not inserted or no IOMMU hardware

```
Device Driver DMA Call:
    dma_map_page(dev, page, offset, size, DMA_TO_DEVICE)
        │
        └─> dma_map_page_attrs()  [kernel/dma/mapping.c:140-159]
                │
                ├─> ops = get_dma_ops(dev)
                │   └─> Returns: NULL (no IOMMU)
                │
                ├─> dma_map_direct(dev, ops)
                │   └─> Returns: true (NULL ops means direct)
                │
                └─> dma_direct_map_page(dev, page, offset, size, dir, attrs)
                        │
                        ├─> phys = page_to_phys(page) + offset
                        ├─> dma_addr = phys_to_dma(dev, phys)  [Simple offset]
                        └─> Return dma_addr (Physical Address or PA+offset)
```

**Result:** Device gets physical address directly

**Hardware path:** Device DMA with physical address → Memory directly

---

### WITH ARM_SMMU_V3 Module Loaded

**When:** ARM_SMMU_V3.ko inserted and device attached to IOMMU domain

```
Device Driver DMA Call:
    dma_map_page(dev, page, offset, size, DMA_TO_DEVICE)
        │
        └─> dma_map_page_attrs()  [kernel/dma/mapping.c:140-159]
                │
                ├─> ops = get_dma_ops(dev)
                │   └─> Returns: &iommu_dma_ops
                │
                ├─> dma_map_direct(dev, ops)
                │   └─> Returns: false (iommu_dma_ops present)
                │
                └─> ops->map_page() == iommu_dma_map_page()  [drivers/iommu/dma-iommu.c:725-739]
                        │
                        ├─> phys = page_to_phys(page) + offset
                        ├─> prot = dma_info_to_prot(dir, coherent, attrs)
                        │
                        └─> __iommu_dma_map(dev, phys, size, prot, dma_mask)  [Lines 480-503]
                                │
                                ├─> domain = iommu_get_dma_domain(dev)
                                ├─> iommu_dma_deferred_attach()  [Line 489]
                                ├─> size = iova_align(iovad, size)  [Line 492]
                                │
                                ├─> iommu_dma_alloc_iova(domain, size, dma_mask, dev)  [Line 494]
                                │       │
                                │       └─> alloc_iova_fast()  [Allocate IOVA]
                                │           └─> Return: IOVA (Virtual Address)
                                │
                                └─> iommu_map_atomic(domain, iova, phys, size, prot)  [Line 498]
                                        │
                                        └─> __iommu_map()  [drivers/iommu/iommu.c:2364-2430]
                                                │
                                                └─> domain->ops->map()
                                                        │
                                                        └─> arm_smmu_map()  [arm-smmu-v3.c:2234-2243]
                                                                │
                                                                └─> ops->map(ops, iova, paddr, size, prot, gfp)
                                                                        │
                                                                        └─> arm_lpae_map()  [io-pgtable-arm.c:437-468]
                                                                                │
                                                                                ├─> __arm_lpae_map()  [Lines 333-377]
                                                                                │       │
                                                                                │       ├─> Walk page table levels
                                                                                │       ├─> Allocate intermediate tables
                                                                                │       └─> arm_lpae_init_pte()  [Lines 272-300]
                                                                                │               │
                                                                                │               └─> __arm_lpae_init_pte()  [Lines 256-270]
                                                                                │                       │
                                                                                │                       ├─> pte |= paddr_to_iopte(paddr)
                                                                                │                       └─> __arm_lpae_set_pte(ptep, pte)
                                                                                │                           └─> Write PTE to memory
                                                                                │
                                                                                └─> wmb()  [Line 465]
                                                                                        └─> Memory barrier
```

**Result:** Device gets IOVA, SMMU hardware translates IOVA -> PA

**Hardware path:** Device DMA with IOVA → SMMUv3 translates → Physical address → Memory

---

## Detailed Function Locations

### DMA Entry Points

| Function | File | Line |
|----------|------|------|
| `dma_map_page_attrs()` | kernel/dma/mapping.c | 140-159 |
| `dma_direct_map_page()` | kernel/dma/direct.c | ~558-577 |
| `dma_map_direct()` | include/linux/dma-mapping.h | (inline) |

### IOMMU DMA Layer

| Function | File | Line |
|----------|------|------|
| `iommu_dma_ops` | drivers/iommu/dma-iommu.c | 1150-1170 |
| `iommu_setup_dma_ops()` | drivers/iommu/dma-iommu.c | 1176-1197 |
| `iommu_dma_map_page()` | drivers/iommu/dma-iommu.c | 725-739 |
| `__iommu_dma_map()` | drivers/iommu/dma-iommu.c | 480-503 |
| `iommu_dma_alloc_iova()` | drivers/iommu/dma-iommu.c | 402-440 |
| `iommu_dma_init_domain()` | drivers/iommu/dma-iommu.c | 301-356 |

### IOMMU Core

| Function | File | Line |
|----------|------|------|
| `iommu_map_atomic()` | drivers/iommu/iommu.c | 2432-2437 |
| `__iommu_map()` | drivers/iommu/iommu.c | 2364-2430 |

### SMMUv3 Driver

| Function | File | Line |
|----------|------|------|
| `arm_smmu_ops` | arm-smmu-v3.c | 2570-2593 |
| `arm_smmu_map()` | arm-smmu-v3.c | 2234-2243 |
| `arm_smmu_unmap()` | arm-smmu-v3.c | ~2245-2256 |
| `arm_smmu_domain_alloc()` | arm-smmu-v3.c | 1770-1799 |

### IO Pagetable (LPAE)

| Function | File | Line |
|----------|------|------|
| `arm_lpae_map()` | io-pgtable-arm.c | 437-468 |
| `__arm_lpae_map()` | io-pgtable-arm.c | 333-377 |
| `arm_lpae_init_pte()` | io-pgtable-arm.c | 272-300 |
| `__arm_lpae_init_pte()` | io-pgtable-arm.c | 256-270 |

### Device Configuration

| Function | File | Line |
|----------|------|------|
| `of_dma_configure_id()` | drivers/of/device.c | 91-182 |
| `arch_setup_dma_ops()` | arch/arm64/mm/dma-mapping.c | 40-59 |
| `of_iommu_configure()` | drivers/of/iommu.c | ~ |

---

## SVA (Shared Virtual Addressing) DMA Flow

### With CONFIG_ARM_SMMU_V3_SVA=y

**Key Difference:** SVA allows devices to use CPU process virtual addresses directly

```
iommu_sva_bind_device(dev, mm, drvdata)
    │
    └─> ops->sva_bind(dev, mm, drvdata)
            │
            └─> arm_smmu_alloc_shared_cd(mm)  [arm-smmu-v3-sva.c:68-146]
                    │
                    ├─> asid = arm64_mm_context_get(mm)  [Get CPU ASID]
                    ├─> arm_smmu_share_asid(mm, asid)  [Line 89]
                    ├─> xa_insert(&arm_smmu_asid_xa, asid, cd)  [Line 95]
                    │
                    ├─> tcr = ...  [Configure Translation Control]
                    ├─> cd->ttbr = virt_to_phys(mm->pgd)  [Line 127 - KEY!]
                    ├─> cd->mair = read_sysreg(mair_el1)  [Line 133]
                    └─> cd->mm = mm  [Line 135]
```

**SVA DMA Operation:**
- Device uses process virtual address directly
- No dma_map_page()/dma_unmap_page() needed
- SMMU walks CPU page tables (mm->pgd)
- Page faults propagate to CPU for on-demand paging

---

## Key Differences Summary

| Aspect | NO Module | Module Loaded |
|--------|-----------|---------------|
| **DMA Address Type** | Physical Address | IOVA (Virtual) |
| **dev->dma_ops** | NULL | &iommu_dma_ops |
| **Map Function** | dma_direct_map_page() | iommu_dma_map_page() |
| **Address Translation** | phys_to_dma() (offset) | SMMU hardware page walk |
| **Page Tables** | None | IOMMU page tables (LPAE) |
| **IOVA Allocation** | None | alloc_iova_fast() |
| **TLB Management** | CPU only | CPU + IOMMU TLB |
| **Memory Isolation** | None | IOMMU enforces bounds |

---

<!--
Repository: linux
Tag: v5.10-rc7
Commit: 0477e92881850d44910a7e94fc2c46f96faa131f
Generated: 2026-02-06
-->
