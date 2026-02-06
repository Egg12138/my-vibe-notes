# ARM SMMUv3 Runtime Comparison: Module Not Inserted vs Inserted

## Table of Contents

- [Module Insertion Flow](#module-insertion-flow)
- [Symbol Table Comparison](#symbol-table-comparison)
- [Runtime State Comparison](#runtime-state-comparison)
- [DMA Execution Flow Comparison](#dma-execution-flow-comparison)
- [Key Runtime Decision Points](#key-runtime-decision-points)
- [Memory Allocation Comparison](#memory-allocation-comparison)
- [Summary Table](#summary-table)
- [Critical Evidence](#critical-evidence)

---

## Module Insertion Flow

```
insmod arm_smmu_v3.ko
    │
    └─> module_init() -> arm_smmu_driver (platform_driver)
            │
            └─> platform_driver_register()
                    │
                    └─> For each matching device in device tree (compatible = "arm,smmu-v3"):
                        │
                        └─> arm_smmu_device_probe(pdev)  [arm-smmu-v3.c:3485-3588]
                                │
                                ├─> [1] Allocate smmu = devm_kzalloc()  [Line 3494]
                                ├─> [2] Parse device tree/ACPI  [Lines 3501-3507]
                                ├─> [3] Map MMIO registers  [Lines 3524-3535]
                                │       ├─> smmu->base = ioremap(..., SZ_64K)
                                │       └─> smmu->page1 = ioremap(..., SZ_64K)
                                │
                                ├─> [4] Get IRQs  [Lines 3539-3554]
                                │       ├─> smmu->combined_irq
                                │       ├─> smmu->evtq.q.irq
                                │       ├─> smmu->priq.q.irq
                                │       └─> smmu->gerr_irq
                                │
                                ├─> [5] Probe hardware capabilities  [Line 3556]
                                │       └─> arm_smmu_device_hw_probe(smmu)
                                │               ├─> Read IDR registers
                                │               ├─> Set smmu->features (FEAT_SVA, etc.)
                                │               ├─> Set smmu->ias, smmu->oas
                                │               └─> Set smmu->pgsize_bitmap
                                │
                                ├─> [6] Initialize data structures  [Line 3561]
                                │       └─> arm_smmu_init_structures(smmu)
                                │               ├─> arm_smmu_init_queues()  [CMDQ, EVTQ, PRIQ]
                                │               └─> arm_smmu_init_strtab()
                                │
                                ├─> [7] Reset and enable SMMU  [Line 3569]
                                │       └─> arm_smmu_device_reset(smmu, bypass)
                                │               ├─> Write CR0, CR1, CR2
                                │               ├─> Initialize CMDQ
                                │               ├─> Issue CMD_SYNC
                                │               └─> Set CR0.SMMUEN = 1 (ENABLE)
                                │
                                ├─> [8] Register with IOMMU core  [Lines 3574-3586]
                                │       ├─> iommu_device_sysfs_add(&smmu->iommu, ...)  [Line 3574]
                                │       ├─> iommu_device_set_ops(&smmu->iommu, &arm_smmu_ops)  [Line 3579]
                                │       └─> iommu_device_register(&smmu->iommu)  [Line 3582]
                                │
                                └─> [9] Set bus IOMMU ops  [Line 3588]
                                        └─> arm_smmu_set_bus_ops(&arm_smmu_ops)
                                                │
                                                ├─> bus_set_iommu(&pci_bus_type, &arm_smmu_ops)
                                                ├─> bus_set_iommu(&platform_bus_type, &arm_smmu_ops)
                                                └─> bus_set_iommu(&amba_bustype, &arm_smmu_ops)
                                                        │
                                                        └─> [iommu.c:1831-1851]
                                                                ├─> bus->iommu_ops = &arm_smmu_ops
                                                                └─> iommu_bus_init(bus, ops)
                                                                        ├─> Register bus notifier
                                                                        └─> Re-probe existing devices!
```

---

## Symbol Table Comparison

### Before Module Insertion

```
# lsmod | grep arm_smmu
(empty)

# cat /sys/kernel/iommu_groups/
(empty or minimal)

# dmesg | grep -i smmu
(empty)
```

**Symbols available (static only):**
- All functions are in module but not loaded
- No `arm_smmu_ops` registered
- Bus `iommu_ops` == NULL

### After Module Insertion

```
# lsmod | grep arm_smmu
arm_smmu_v3              65536  0   (or with dependencies)

# cat /sys/kernel/iommu/groups/
(contains IOMMU groups for devices behind SMMU)

# dmesg | grep -i smmu
[    2.123] arm-smmu-v3 arm_smmu_v3@...: iommu: adding to iommu_groups
[    2.145] arm-smmu-v3 arm_smmu_v3@...: attached to device foo
```

**New Active Symbols:**

| Symbol | Type | Location | Status |
|--------|------|----------|--------|
| `arm_smmu_ops` | struct | arm-smmu-v3.c | Registered in `bus->iommu_ops` |
| `pci_bus_type.iommu_ops` | pointer | kernel/bus.c | Points to `&arm_smmu_ops` |
| `platform_bus_type.iommu_ops` | pointer | kernel/bus.c | Points to `&arm_smmu_ops` |

---

## Runtime State Comparison

### Global State Changes

| State | Before Insertion | After Insertion |
|-------|-----------------|-----------------|
| `pci_bus_type.iommu_ops` | NULL | `&arm_smmu_ops` |
| `platform_bus_type.iommu_ops` | NULL | `&arm_smmu_ops` |
| `amba_bustype.iommu_ops` | NULL | `&arm_smmu_ops` |
| `iommu_present(&pci_bus_type)` | false | true |
| Available IOMMU groups | 0 | N (based on devices) |

### Per-Device State Changes

**Before insertion:**

```c
struct device dev = {
    .iommu_group = NULL,
    .dma_ops = NULL,  // or dma_direct_ops
    .dma_pfn_offset = 0,
}
```

**After insertion (for devices behind SMMU):**

```c
struct device dev = {
    .iommu_group = &iommu_group_X,  // Assigned by iommu_probe_device()
    .dma_ops = &iommu_dma_ops,      // Set by iommu_setup_dma_ops()
    .dma_pfn_offset = 0,
    .iommu = &arm_smmu_master,       // Private driver data
}
```

---

## DMA Execution Flow Comparison

### Before ARM_SMMU_V3.ko Insertion

```
Device driver: dma_map_page(dev, page, offset, size, DMA_TO_DEVICE)
    │
    └─> dma_map_page_attrs()  [kernel/dma/mapping.c:140]
            │
            ├─> ops = get_dma_ops(dev)
            │   └─> Returns: NULL (bus->iommu_ops == NULL)
            │
            ├─> dma_map_direct(dev, ops)
            │   └─> Returns: true  [no IOMMU = direct]
            │
            └─> dma_direct_map_page(dev, page, offset, size, dir, attrs)
                    │
                    ├─> phys_addr = page_to_phys(page) + offset
                    ├─> dma_addr = __phys_to_dma(dev, phys_addr)  [just offset]
                    │
                    └─> return dma_addr  // Device gets physical address
```

**Hardware path:** Device DMA with physical address → Memory directly

### After ARM_SMMU_V3.ko Insertion

```
Device driver: dma_map_page(dev, page, offset, size, DMA_TO_DEVICE)
    │
    └─> dma_map_page_attrs()  [kernel/dma/mapping.c:140]
            │
            ├─> ops = get_dma_ops(dev)
            │   └─> Returns: &iommu_dma_ops  [bus->iommu_ops != NULL]
            │
            ├─> dma_map_direct(dev, ops)
            │   └─> Returns: false  [iommu_dma_ops present]
            │
            └─> ops->map_page(dev, page, offset, size, dir, attrs)
                    │
                    └─> iommu_dma_map_page()  [drivers/iommu/dma-iommu.c:725]
                            │
                            ├─> phys = page_to_phys(page) + offset
                            ├─> __iommu_dma_map(dev, phys, size, prot, dma_mask)
                            │       │
                            │       ├─> domain = iommu_get_dma_domain(dev)
                            │       ├─> iova = iommu_dma_alloc_iova(domain, size, ...)
                            │       │       └─> alloc_iova_fast()
                            │       │           └─> Return: IOVA (e.g., 0x8000_0000)
                            │       │
                            │       └─> iommu_map_atomic(domain, iova, phys, size, prot)
                            │               │
                            │               └─> __iommu_map(domain, iova, paddr, size, prot)
                            │                       │
                            │                       └─> domain->ops->map()
                            │                               │
                            │                               └─> arm_smmu_map()  [arm-smmu-v3.c:2234]
                            │                                       │
                            │                                       └─> ops->map(iova, paddr, ...)
                            │                                               │
                            │                                               └─> arm_lpae_map()
                            │                                                       │
                            │                                                       └─> __arm_lpae_map()
                            │                                                               │
                            │                                                               ├─> Walk PTEs
                            │                                                               └─> *ptep = pte
                            │                                                                   └─> Update IOMMU page tables
                            │
                            └─> return iova  // Device gets IOVA
```

**Hardware path:** Device DMA with IOVA → SMMUv3 translates → Physical address → Memory

---

## Key Runtime Decision Points

### 1. DMA Ops Selection

**Decision point:** `get_dma_ops()` in include/linux/dma-mapping.h

```c
static inline const struct dma_map_ops *get_dma_ops(struct device *dev)
{
    return dev->dma_ops;
}
```

| State | `dev->dma_ops` | Result |
|-------|----------------|--------|
| Before | NULL | `dma_map_direct()` returns true → use `dma_direct_map_page()` |
| After | `&iommu_dma_ops` | `dma_map_direct()` returns false → call `iommu_dma_map_page()` |

### 2. IOMMU Presence Check

**Decision point:** `iommu_present()` in drivers/iommu/iommu.c:1854

```c
bool iommu_present(struct bus_type *bus)
{
    return bus->iommu_ops != NULL;
}
```

| State | `bus->iommu_ops` | `iommu_present()` |
|-------|-----------------|-------------------|
| Before | NULL | false |
| After | `&arm_smmu_ops` | true |

### 3. Device Probing

**When module loads, existing devices get re-probed:**

```
iommu_bus_init() registers notifier
    │
    └─> BUS_NOTIFY_ADD_DEVICE triggered for each device
            │
            └─> iommu_probe_device(dev)
                    │
                    ├─> ops->probe_device(dev)
                    │       └─> arm_smmu_probe_device()  [arm-smmu-v3.c:~2450]
                    │               ├─> Parse device Stream IDs
                    │               ├─> Allocate arm_smmu_master
                    │               └─> Return master
                    │
                    └─> iommu_group_get_for_dev(dev)
                            └─> Create/assign iommu_group
```

---

## Memory Allocation Comparison

### Before Module Insertion

```c
/* Device allocates DMA buffer */
buf = dma_alloc_coherent(dev, size, &dma_handle, GFP_KERNEL);
    │
    └─> dma_direct_alloc()  [kernel/dma/direct.c]
            ├─> page = __dma_alloc(dev, size, ...)
            ├─> dma_handle = phys_to_dma(dev, page_to_phys(page))
            └─> return page_address(page)
```

**Result:** `dma_handle` is physical address

### After Module Insertion

```c
/* Device allocates DMA buffer */
buf = dma_alloc_coherent(dev, size, &dma_handle, GFP_KERNEL);
    │
    └─> iommu_dma_alloc()  [drivers/iommu/dma-iommu.c]
            │
            ├─> alloc_pages(size)
            ├─> phys = page_to_phys(page)
            │
            ├─> iova = iommu_dma_alloc_iova(domain, size, ...)
            │
            ├─> iommu_map_atomic(domain, iova, phys, size, prot)
            │       └─> [Full page table walk as shown above]
            │
            └─> dma_handle = iova  // Return IOVA to device
```

**Result:** `dma_handle` is IOVA, SMMU translates to physical address

---

## Summary Table

| Aspect | Before Module Load | After Module Load |
|--------|-------------------|-------------------|
| **Bus IOMMU ops** | NULL | `&arm_smmu_ops` |
| **Device dma_ops** | NULL (direct) | `&iommu_dma_ops` |
| **Device iommu_group** | NULL | Assigned |
| **DMA address type** | Physical | IOVA |
| **DMA map function** | `dma_direct_map_page()` | `iommu_dma_map_page()` |
| **Page table updates** | None | IOMMU page tables |
| **Hardware translation** | Direct (1:1) | SMMUv3 translation |
| **Memory isolation** | None | IOMMU enforced |
| **DMA validity check** | phys <= dma_mask | iova <= dma_mask |
| **Symbols active** | None (module not loaded) | All module symbols exported |
| **IRQ handlers** | None | EVTQ, PRIQ, GERR active |
| **Sysfs entries** | None | `/sys/kernel/iommu_groups/` |

---

## Critical Evidence

### 1. Module Registration Point
**File:** `arm-smmu-v3.c:3624`

```c
module_platform_driver(arm_smmu_driver);
```

### 2. Bus Ops Assignment Point
**File:** `arm-smmu-v3.c:3588`

```c
return arm_smmu_set_bus_ops(&arm_smmu_ops);
```

### 3. Bus Ops Implementation
**File:** `iommu.c:1831-1851`

```c
int bus_set_iommu(struct bus_type *bus, const struct iommu_ops *ops)
{
    ...
    bus->iommu_ops = ops;  // CRITICAL: Enables IOMMU for all devices on bus
    ...
}
```

### 4. DMA Ops Assignment Point
**File:** `dma-iommu.c:1190`

```c
if (domain->type == IOMMU_DOMAIN_DMA) {
    ...
    dev->dma_ops = &iommu_dma_ops;  // CRITICAL: Changes DMA flow
}
```

---

## Conclusion

**The fundamental difference:**

1. **Before insertion:** The kernel has CONFIG_IOMMU_SUPPORT infrastructure but no active IOMMU. Devices use direct DMA mapping (physical addresses). `bus->iommu_ops == NULL`.

2. **After insertion:** The SMMUv3 driver initializes hardware, registers `arm_smmu_ops` with the bus, assigns `&iommu_dma_ops` to device `dma_ops`, and all subsequent DMA operations go through IOVA allocation and IOMMU page table management.

**The execution flow changes from:**

```
driver → dma_map_page() → dma_direct_map_page() → phys_to_dma() → PA
```

**To:**

```
driver → dma_map_page() → iommu_dma_map_page() → IOVA alloc →
iommu_map() → arm_smmu_map() → arm_lpae_map() → PTE write → IOVA
```

---

<!--
Repository: linux
Tag: v5.10-rc7
Commit: 0477e92881850d44910a7e94fc2c46f96faa131f
Generated: 2026-02-06
-->
