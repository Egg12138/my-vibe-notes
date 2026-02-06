# ARM SMMUv3 Kconfig Symbol Analysis

## Table of Contents

- [Configuration Summary](#configuration-summary)
- [Kconfig Definitions & Dependencies](#kconfig-definitions--dependencies)
- [Symbol Analysis by Kconfig](#symbol-analysis-by-kconfig)
- [Function Call Chain Analysis](#function-call-chain-analysis)
- [Complete Symbol List](#complete-symbol-list)
- [Build Evidence](#build-evidence)

---

## Configuration Summary

```
CONFIG_IOMMU_SUPPORT      = y  (top-level menu)
CONFIG_ARM_SMMU_V3        = m  (module)
CONFIG_ARM_SMMU_V3_SVA    = y  (SVA support)
CONFIG_IOASID             = y  (IOASID allocator)
CONFIG_IOMMU_IO_PGTABLE   = y  (selected by LPAE)
CONFIG_IOMMU_IO_PGTABLE_LPAE = y
CONFIG_IOMMU_SVA          = y
```

---

## Kconfig Definitions & Dependencies

### 1. CONFIG_IOMMU_SUPPORT

**Location:** `drivers/iommu/Kconfig:14-23`

```kconfig
menuconfig IOMMU_SUPPORT
    bool "IOMMU Hardware Support"
    depends on MMU
    default y
```

**Impact:** Enables entire IOMMU subsystem menu (lines 24-404)

---

### 2. CONFIG_ARM_SMMU_V3

**Location:** `drivers/iommu/Kconfig:298-309`

```kconfig
config ARM_SMMU_V3
    tristate "ARM Ltd. System MMU Version 3 (SMMUv3) Support"
    depends on ARM64
    select IOMMU_API
    select IOMMU_IO_PGTABLE_LPAE
    select GENERIC_MSI_IRQ_DOMAIN
```

**Build Integration:** `drivers/iommu/arm/arm-smmu-v3/Makefile:2-5`

```makefile
obj-$(CONFIG_ARM_SMMU_V3) += arm_smmu_v3.o
arm_smmu_v3-objs-y += arm-smmu-v3.o
arm_smmu_v3-objs-$(CONFIG_ARM_SMMU_V3_SVA) += arm-smmu-v3-sva.o
```

---

### 3. CONFIG_ARM_SMMU_V3_SVA

**Location:** `drivers/iommu/Kconfig:311-319`

```kconfig
config ARM_SMMU_V3_SVA
    bool "Shared Virtual Addressing support for the ARM SMMUv3"
    depends on ARM_SMMU_V3
```

**Impact:** Adds `arm-smmu-v3-sva.o` to module build

---

### 4. CONFIG_IOASID

**Location:** `drivers/iommu/Kconfig:6-8`

```kconfig
config IOASID
    tristate
```

**Build Integration:** `drivers/iommu/Makefile:11`

```makefile
obj-$(CONFIG_IOASID) += ioasid.o
```

---

### 5. CONFIG_IOMMU_IO_PGTABLE_LPAE

**Location:** `drivers/iommu/Kconfig:32-40`

```kconfig
config IOMMU_IO_PGTABLE_LPAE
    bool "ARMv7/v8 Long Descriptor Format"
    select IOMMU_IO_PGTABLE
    depends on ARM || ARM64 || (COMPILE_TEST && !GENERIC_ATOMIC64)
```

**Build Integration:** `drivers/iommu/Makefile:10`

```makefile
obj-$(CONFIG_IOMMU_IO_PGTABLE_LPAE) += io-pgtable-arm.o
```

---

## Symbol Analysis by Kconfig

### Symbols Affected by CONFIG_ARM_SMMU_V3

#### A. Data Structures

| Symbol | Type | Location | Description |
|--------|------|----------|-------------|
| `struct arm_smmu_device` | struct | arm-smmu-v3.h:584-639 | Main SMMU device structure |
| `struct arm_smmu_master` | struct | arm-smmu-v3.h:642-653 | Per-master device data |
| `struct arm_smmu_domain` | struct | arm-smmu-v3.h:663-680 | IOMMU domain data |
| `struct arm_smmu_ctx_desc` | struct | arm-smmu-v3.h:~ | Context descriptor |
| `struct arm_smmu_strtab_cfg` | struct | arm-smmu-v3.h:571-581 | Stream table config |
| `struct arm_smmu_cmdq` | struct | arm-smmu-v3.h:~ | Command queue |
| `struct arm_smmu_evtq` | struct | arm-smmu-v3.h:~ | Event queue |
| `struct arm_smmu_priq` | struct | arm-smmu-v3.h:~ | Page Request Queue |

**Feature Flags** (arm-smmu-v3.h:589-606):

```c
#define ARM_SMMU_FEAT_2_LVL_STRTAB    (1 << 0)
#define ARM_SMMU_FEAT_2_LVL_CDTAB     (1 << 1)
#define ARM_SMMU_FEAT_PRI             (1 << 4)  // Page Request Interface
#define ARM_SMMU_FEAT_ATS             (1 << 5)  // Address Translation Services
#define ARM_SMMU_FEAT_COHERENCY       (1 << 8)
#define ARM_SMMU_FEAT_TRANS_S1        (1 << 9)
#define ARM_SMMU_FEAT_TRANS_S2        (1 << 10)
#define ARM_SMMU_FEAT_VAX             (1 << 14) // Virtual Address Extension
#define ARM_SMMU_FEAT_RANGE_INV       (1 << 15)
#define ARM_SMMU_FEAT_BTM             (1 << 16) // Broadcast TLB Maintenance
#define ARM_SMMU_FEAT_SVA             (1 << 17) // Shared Virtual Addressing
```

#### B. Global Variables

| Symbol | Type | Location | Purpose |
|--------|------|----------|---------|
| `arm_smmu_asid_xa` | xarray | arm-smmu-v3.c:76 | ASID tracking |
| `arm_smmu_asid_lock` | mutex | arm-smmu-v3.c:77 | ASID mutex |

#### C. Key Functions

| Function | Location | Purpose |
|----------|----------|---------|
| `arm_smmu_device_probe()` | arm-smmu-v3.c:~ | Platform driver probe |
| `arm_smmu_device_remove()` | arm-smmu-v3.c:~ | Platform driver remove |
| `arm_smmu_device_reset()` | arm-smmu-v3.c:3019 | Reset SMMU hardware |
| `arm_smmu_init_structures()` | arm-smmu-v3.c:~ | Initialize queues/tables |
| `arm_smmu_init_queues()` | arm-smmu-v3.c:~ | Initialize CMDQ/EVTQ/PRIQ |
| `arm_smmu_init_strtab()` | arm-smmu-v3.c:~ | Initialize stream table |
| `arm_smmu_setup_irqs()` | arm-smmu-v3.c:~ | Configure interrupts |
| `arm_smmu_domain_alloc()` | arm-smmu-v3.c:~ | Allocate IOMMU domain |
| `arm_smmu_domain_free()` | arm-smmu-v3.c:~ | Free domain |
| `arm_smmu_attach_dev()` | arm-smmu-v3.c:2164 | Attach device to domain |
| `arm_smmu_detach_dev()` | arm-smmu-v3.c:~ | Detach device |
| `arm_smmu_map()` | arm-smmu-v3.c:2234 | Map IOVA to PA |
| `arm_smmu_unmap()` | arm-smmu-v3.c:2234 | Unmap IOVA |
| `arm_smmu_write_ctx_desc()` | arm-smmu-v3.h:686 | Write context descriptor |
| `arm_smmu_write_strtab_ent()` | arm-smmu-v3.c:1176 | Write stream table entry |
| `arm_smmu_tlb_inv_asid()` | arm-smmu-v3.h:688 | Invalidate by ASID |
| `arm_smmu_free_asid()` | arm-smmu-v3.h:689 | Free ASID |
| `arm_smmu_cmdq_issue_cmd()` | arm-smmu-v3.c:847 | Issue command |
| `arm_smmu_cmdq_issue_sync()` | arm-smmu-v3.c:861 | Sync command queue |
| `arm_smmu_cmdq_batch_submit()` | arm-smmu-v3.c:878 | Batch commands |

#### D. IOMMU Operations Structure

**Location:** `arm-smmu-v3.c:2588-2593`

```c
static struct iommu_ops arm_smmu_ops = {
    // ... basic operations ...
    .dev_has_feat      = arm_smmu_dev_has_feature,      // Line 2588
    .dev_feat_enabled  = arm_smmu_dev_feature_enabled,  // Line 2589
    .dev_enable_feat   = arm_smmu_dev_enable_feature,   // Line 2590
    .dev_disable_feat  = arm_smmu_dev_disable_feature,  // Line 2591
};
```

---

### Symbols Affected by CONFIG_ARM_SMMU_V3_SVA

**Conditional Compilation:** `arm-smmu-v3.h:691-722`

```c
#ifdef CONFIG_ARM_SMMU_V3_SVA
bool arm_smmu_sva_supported(struct arm_smmu_device *smmu);
bool arm_smmu_master_sva_supported(struct arm_smmu_master *master);
bool arm_smmu_master_sva_enabled(struct arm_smmu_master *master);
int arm_smmu_master_enable_sva(struct arm_smmu_master *master);
int arm_smmu_master_disable_sva(struct arm_smmu_master *master);
#else
static inline bool arm_smmu_sva_supported(struct arm_smmu_device *smmu)
    { return false; }
static inline bool arm_smmu_master_sva_supported(struct arm_smmu_master *master)
    { return false; }
static inline bool arm_smmu_master_sva_enabled(struct arm_smmu_master *master)
    { return false; }
static inline int arm_smmu_master_enable_sva(struct arm_smmu_master *master)
    { return -ENODEV; }
static inline int arm_smmu_master_disable_sva(struct arm_smmu_master *master)
    { return -ENODEV; }
#endif
```

#### A. SVA Implementation Functions

**File:** `arm-smmu-v3-sva.c`

| Function | Location | Purpose |
|----------|----------|---------|
| `arm_smmu_share_asid()` | arm-smmu-v3-sva.c:20-65 | Share ASID between contexts |
| `arm_smmu_alloc_shared_cd()` | arm-smmu-v3-sva.c:68-146 | Allocate shared context descriptor |
| `arm_smmu_free_shared_cd()` | arm-smmu-v3-sva.c:149-156 | Free shared context descriptor |
| `arm_smmu_sva_supported()` | arm-smmu-v3-sva.c:158-201 | Check hardware SVA support |
| `arm_smmu_iopf_supported()` | arm-smmu-v3-sva.c:203-206 | Check IOPF support |
| `arm_smmu_master_sva_supported()` | arm-smmu-v3-sva.c:208-215 | Check device SVA support |
| `arm_smmu_master_sva_enabled()` | arm-smmu-v3-sva.c:217-225 | Check if SVA enabled |
| `arm_smmu_master_enable_sva()` | arm-smmu-v3-sva.c:227-234 | Enable SVA |
| `arm_smmu_master_disable_sva()` | arm-smmu-v3-sva.c:236-248 | Disable SVA |

#### B. SVA Data Fields in arm_smmu_master

**Location:** `arm-smmu-v3.h:650-652`

```c
struct arm_smmu_master {
    // ...
    bool                sva_enabled;    // Line 650
    struct list_head     bonds;          // Line 651 - SVA device-mm bonds
    unsigned int        ssid_bits;      // Line 652 - Sub-Stream ID bits
};
```

---

### Symbols Affected by CONFIG_IOASID

**File:** `include/linux/ioasid.h`

#### A. API Functions (when CONFIG_IOASID=y)

| Function | Location | Purpose | Return when disabled |
|----------|----------|---------|---------------------|
| `ioasid_alloc()` | ioasid.h:35-36 | Allocate IOASID | INVALID_IOASID |
| `ioasid_free()` | ioasid.h:37 | Free IOASID | (no-op) |
| `ioasid_find()` | ioasid.h:38-39 | Find IOASID data | NULL |
| `ioasid_set_data()` | ioasid.h:42 | Set private data | -ENOTSUPP |
| `ioasid_register_allocator()` | ioasid.h:40 | Register allocator | -ENOTSUPP |
| `ioasid_unregister_allocator()` | ioasid.h:41 | Unregister allocator | (no-op) |

#### B. Data Structures

| Symbol | Type | Location |
|--------|------|----------|
| `ioasid_t` | typedef | ioasid.h:9 |
| `ioasid_alloc_fn_t` | typedef | ioasid.h:10 |
| `ioasid_free_fn_t` | typedef | ioasid.h:11 |
| `struct ioasid_set` | struct | ioasid.h:13-15 |
| `struct ioasid_allocator_ops` | struct | ioasid.h:25-30 |

---

### Symbols Affected by CONFIG_IOMMU_IO_PGTABLE_LPAE

**File:** `drivers/iommu/io-pgtable-arm.c`

#### A. Page Table Format Init Functions

| Symbol | Type | Location | Format |
|--------|------|----------|--------|
| `io_pgtable_arm_32_lpae_s1_init_fns` | extern | io-pgtable.h | ARM32 S1 |
| `io_pgtable_arm_32_lpae_s2_init_fns` | extern | io-pgtable.h | ARM32 S2 |
| `io_pgtable_arm_64_lpae_s1_init_fns` | extern | io-pgtable.h | **ARM64 S1** |
| `io_pgtable_arm_64_lpae_s2_init_fns` | extern | io-pgtable.h | ARM64 S2 |
| `io_pgtable_arm_mali_lpae_init_fns` | extern | io-pgtable.h | Mali LPAE |

#### B. Core Page Table API

| Function | Location | Purpose |
|----------|----------|---------|
| `alloc_io_pgtable_ops()` | io-pgtable.c:29-52 | Allocate page table ops |
| `free_io_pgtable_ops()` | io-pgtable.c:59-70 | Free page table ops |

#### C. Operations Structure

**io_pgtable_cfg** (io-pgtable.h):

```c
struct io_pgtable_cfg {
    unsigned long       pgsize_bitmap;
    unsigned int        ias;           // Input address size
    unsigned int        oas;           // Output address size
    struct {
        u64     ttbr;
        u64     tcr;
        u64     mair;
    } arm_lpae_s1_cfg;
    // ...
};
```

---

## Function Call Chain Analysis

### SVA Enable Flow

```
iommu_dev_enable_feature(dev, IOMMU_DEV_FEAT_SVA)
    │
    └─> [drivers/iommu/iommu.c]
        │
        └─> ops->dev_enable_feat(dev, feat)
                │
                └─> arm_smmu_dev_enable_feature()  [arm-smmu-v3.c:2539]
                        │
                        ├─> arm_smmu_dev_has_feature()
                        │       │
                        │       └─> arm_smmu_master_sva_supported()  [arm-smmu-v3-sva.c:208]
                        │               ├─> Check: (smmu->features & ARM_SMMU_FEAT_SVA)
                        │               ├─> Check: master->ssid_bits
                        │               └─> Check: arm_smmu_iopf_supported()
                        │
                        └─> arm_smmu_master_enable_sva()  [arm-smmu-v3-sva.c:227]
                                └─> master->sva_enabled = true
```

### Domain Initialization with Page Tables

```
arm_smmu_domain_alloc(IOMMU_DOMAIN_DMA)
    │
    └─> [arm-smmu-v3.c]
        │
        └─> arm_smmu_domain_finalise()  [arm-smmu-v3.c:1929]
                │
                └─> arm_smmu_domain_finalise_s1()  [arm-smmu-v3.c:1846]
                        │
                        ├─> Configure io_pgtable_cfg:
                        │   ├─> cfg.ias = smmu->ias
                        │   ├─> cfg.oas = smmu->oas
                        │   ├─> cfg.pgsize_bitmap = smmu->pgsize_bitmap
                        │   └─> cfg.tlb = &arm_smmu_flush_ops
                        │
                        └─> alloc_io_pgtable_ops(ARM_64_LPAE_S1, cfg, cookie)
                                │
                                └─> [drivers/iommu/io-pgtable.c:29]
                                    │
                                    └─> io_pgtable_init_table[ARM_64_LPAE_S1]->alloc()
                                            │
                                            └─> arm64_lpae_s1_init_fns.alloc()  [io-pgtable-arm.c]
                                                    │
                                                    ├─> Allocate page tables
                                                    ├─> Setup pgtable_ops
                                                    └─> Return ops
```

---

## Complete Symbol List

### New Symbols Summary

| Category | CONFIG_ARM_SMMU_V3 | CONFIG_ARM_SMMU_V3_SVA | CONFIG_IOASID |
|----------|-------------------|----------------------|---------------|
| **Structs** | arm_smmu_device<br>arm_smmu_master<br>arm_smmu_domain<br>arm_smmu_ctx_desc<br>arm_smmu_strtab_cfg | (uses arm_smmu_master) | ioasid_set<br>ioasid_allocator_ops |
| **Functions** | 30+ initialization/domain/queue functions | 9 SVA-specific functions | 6 IOASID API functions |
| **Global Variables** | arm_smmu_asid_xa<br>arm_smmu_asid_lock | sva_lock | (internal xarray) |

### Conditional Compilation Summary

```
#ifdef CONFIG_ARM_SMMU_V3_SVA:
├── arm_smmu_sva_supported()
├── arm_smmu_master_sva_supported()
├── arm_smmu_master_sva_enabled()
├── arm_smmu_master_enable_sva()
└── arm_smmu_master_disable_sva()

#if IS_ENABLED(CONFIG_IOASID):
├── ioasid_alloc()
├── ioasid_free()
├── ioasid_find()
├── ioasid_set_data()
├── ioasid_register_allocator()
└── ioasid_unregister_allocator()

#ifdef CONFIG_IOMMU_IO_PGTABLE_LPAE:
├── io_pgtable_arm_32_lpae_s1_init_fns
├── io_pgtable_arm_32_lpae_s2_init_fns
├── io_pgtable_arm_64_lpae_s1_init_fns  ← Used by SMMUv3
├── io_pgtable_arm_64_lpae_s2_init_fns
└── io_pgtable_arm_mali_lpae_init_fns
```

---

## Build Evidence

**drivers/iommu/Makefile:**

```makefile
obj-$(CONFIG_IOMMU_API) += iommu.o
obj-$(CONFIG_IOMMU_API) += iommu-traces.o
obj-$(CONFIG_IOMMU_API) += iommu-sysfs.o
obj-$(CONFIG_IOMMU_IO_PGTABLE) += io-pgtable.o
obj-$(CONFIG_IOMMU_IO_PGTABLE_LPAE) += io-pgtable-arm.o
obj-$(CONFIG_IOASID) += ioasid.o
```

**drivers/iommu/arm/arm-smmu-v3/Makefile:**

```makefile
obj-$(CONFIG_ARM_SMMU_V3) += arm_smmu_v3.o
arm_smmu_v3-objs-y += arm-smmu-v3.o
arm_smmu_v3-objs-$(CONFIG_ARM_SMMU_V3_SVA) += arm-smmu-v3-sva.o
```

---

<!--
Repository: linux
Tag: v5.10-rc7
Commit: 0477e92881850d44910a7e94fc2c46f96faa131f
Generated: 2026-02-06
-->
