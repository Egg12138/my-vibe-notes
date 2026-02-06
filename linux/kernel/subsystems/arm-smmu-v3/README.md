# ARM SMMUv3 Documentation

## Table of Contents

- [Overview](#overview)
- [Notes](#notes)
- [Key Concepts](#key-concepts)
- [File Locations](#file-locations)

---

## Overview

This directory contains comprehensive documentation about ARM SMMUv3 (System MMU Version 3) in the Linux kernel, focusing on:

- Kconfig symbol analysis and dependencies
- DMA execution flow with and without IOMMU
- Runtime behavior comparison (module loaded vs not loaded)
- SVA (Shared Virtual Addressing) implementation

---

## Notes

### 1. [Kconfig Symbol Analysis](./kconfig-symbol-analysis.md)

Covers:
- All Kconfig options related to ARM SMMUv3
- Symbol dependencies and selections
- Conditional compilation effects
- Data structures and functions added/modified
- Complete symbol list with file locations

**Key files analyzed:**
- `drivers/iommu/Kconfig`
- `drivers/iommu/arm/arm-smmu-v3/arm-smmu-v3.c`
- `drivers/iommu/arm/arm-smmu-v3/arm-smmu-v3.h`
- `drivers/iommu/arm/arm-smmu-v3/arm-smmu-v3-sva.c`
- `include/linux/ioasid.h`

### 2. [DMA Execution Flow](./dma-execution-flow.md)

Covers:
- How DMA operations work with IOMMU enabled
- Complete call chain from device driver to SMMU hardware
- Comparison with direct DMA (no IOMMU)
- Detailed function locations and line numbers
- SVA-specific DMA flow

**Key paths traced:**
- `dma_map_page()` → `iommu_dma_map_page()` → `arm_smmu_map()` → `arm_lpae_map()`

### 3. [Runtime Comparison](./runtime-comparison.md)

Covers:
- Module insertion flow and initialization
- Symbol table differences before/after module load
- Per-device state changes
- Runtime decision points
- Memory allocation differences

---

## Key Concepts

### ARM SMMUv3 Architecture

```
                    ┌─────────────────────────────────────┐
                    │         ARM SMMUv3 Hardware          │
    ┌───────────────┤                                     ├───────────────┐
    │               │  ┌─────────┐    ┌──────────────┐   │               │
    │  Device       │  │  STRTAB │───▶│     CD       │   │               │
    │  (PCIe/       │  │ Stream  │    │ Context Desc │   │               │
    │   Platform)   │  │ Table   │    │              │   │               │
    │               │  └─────────┘    └──────┬───────┘   │               │
    │               │                        │            │               │
    │  IOVA ────────┼──────────────────────▶│ PT Walk     ├────▶ PA ────▶│
    │               │                        │             │               │
    │               │                        │             │               │
    └───────────────┘                        └─────────────┘               │
                    └─────────────────────────────────────┘
```

### Key Kconfig Options

| Config | Type | Description |
|--------|------|-------------|
| `CONFIG_ARM_SMMU_V3` | tristate | Main SMMUv3 driver (can be y/m) |
| `CONFIG_ARM_SMMU_V3_SVA` | bool | Shared Virtual Addressing support |
| `CONFIG_IOASID` | tristate | IO Address Space ID allocator |
| `CONFIG_IOMMU_IO_PGTABLE_LPAE` | bool | ARM Long Descriptor Format page tables |

### Feature Flags

```c
ARM_SMMU_FEAT_SVA      (1 << 17)  // Shared Virtual Addressing
ARM_SMMU_FEAT_BTM      (1 << 16)  // Broadcast TLB Maintenance
ARM_SMMU_FEAT_VAX      (1 << 14)  // Virtual Address Extension
ARM_SMMU_FEAT_ATS      (1 << 5)   // Address Translation Services
ARM_SMMU_FEAT_PRI      (1 << 4)   // Page Request Interface
```

---

## File Locations

### Driver Files

| File | Purpose |
|------|---------|
| `drivers/iommu/arm/arm-smmu-v3/arm-smmu-v3.c` | Main driver |
| `drivers/iommu/arm/arm-smmu-v3/arm-smmu-v3.h` | Driver definitions |
| `drivers/iommu/arm/arm-smmu-v3/arm-smmu-v3-sva.c` | SVA implementation |
| `drivers/iommu/arm/arm-smmu-v3/Makefile` | Build configuration |

### Core IOMMU Files

| File | Purpose |
|------|---------|
| `drivers/iommu/iommu.c` | IOMMU core API |
| `drivers/iommu/dma-iommu.c` | DMA-IOMMU glue layer |
| `drivers/iommu/io-pgtable.c` | IO pagetable allocator |
| `drivers/iommu/io-pgtable-arm.c` | ARM LPAE implementation |
| `drivers/iommu/ioasid.c` | IOASID allocator |

### Headers

| File | Purpose |
|------|---------|
| `include/linux/iommu.h` | IOMMU public API |
| `include/linux/io-pgtable.h` | IO pagetable API |
| `include/linux/ioasid.h` | IOASID API |
| `include/linux/dma-mapping.h` | DMA mapping API |

### Configuration

| File | Purpose |
|------|---------|
| `drivers/iommu/Kconfig` | IOMMU configuration options |

### Device Configuration

| File | Purpose |
|------|---------|
| `drivers/of/device.c` | Device tree DMA configuration |
| `drivers/of/iommu.c` | OF IOMMU configuration |
| `arch/arm64/mm/dma-mapping.c` | ARM64 DMA ops setup |

---

## Related Documentation

- [General IOMMU Documentation](../iommu.md) - Covers Intel VT-d, AMD-Vi, and general IOMMU concepts

---

<!--
Repository: linux
Tag: v5.10-rc7
Commit: 0477e92881850d44910a7e94fc2c46f96faa131f
Generated: 2026-02-06
-->
