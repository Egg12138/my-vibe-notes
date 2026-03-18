# IOMMU Learning Lab - Beginner Notes

[TOC]

## What is IOMMU?

**IOMMU** (Input/Output Memory Management Unit) is a hardware component that:

- **Translates DMA addresses**: Devices see virtual addresses (IOVA), IOMMU translates to physical RAM
- **Protects memory**: Prevents devices from accessing memory they haven't been granted
- **Isolates devices**: Each device/group can only access its mapped buffers
- **Reports faults**: Catches and reports illegal DMA attempts

### Real-World Analogy

Think of IOMMU as a **security guard for DMA**:
- Without IOMMU: Devices can access any physical memory (dangerous!)
- With IOMMU: Devices must have explicit "permission slips" (mappings) to access memory

---

## Key Concepts

### 1. IOVA (IO Virtual Address)

```
Device sees: IOVA 0x1000 -> IOMMU translates -> Physical RAM 0x80001000
```

Benefits:
- Devices don't need to know physical memory layout
- Memory can be remapped without device reconfiguration
- Gaps in physical memory can appear contiguous to devices

### 2. DMA Remapping

```
Without IOMMU:
  Device DMA -> Physical Address (direct, unprotected)

With IOMMU:
  Device DMA -> IOVA -> IOMMU Translation -> Physical Address (protected)
```

### 3. IOMMU Groups

Devices are grouped for isolation purposes. Devices in the **same group** share IOMMU protection. Devices in **different groups** are isolated from each other.

```bash
# Check IOMMU groups in Linux
ls /sys/kernel/iommu_groups/
```

---

## Arm SMMU Family

**SMMU** (System MMU) is Arm's IOMMU implementation:

| Generation | Typical Use | Key Features |
|------------|-------------|--------------|
| SMMU v1/v2 | Older SoCs, mobile | Register-based, context banks |
| SMMU v3 | Modern servers, PCIe | Queue-based, better scalability |

### Why SMMUv3 Matters

- **Command Queue**: Software writes commands to a queue, hardware processes them
- **Event Queue**: Hardware reports faults/events via a queue
- **Better PCIe support**: Designed for modern virtualization workloads

---

## Lab Scenarios Explained

### Scenario A: No IOMMU (`iommu.passthrough=1`)

```
Kernel cmdline: iommu.passthrough=1
Result: DMA bypasses translation (no protection)
```

**What you see in dmesg:**
```
iommu: Default domain type: Passthrough (set via kernel command line)
```

No SMMU driver initialization = devices can DMA directly to physical memory.

### Scenario B: SMMUv3 Enabled (`iommu.passthrough=0`)

```
Kernel cmdline: iommu.passthrough=0 iommu.strict=1
QEMU: -machine virt,iommu=smmuv3
Result: Full IOMMU translation and protection
```

**What you see in dmesg:**
```
arm-smmu-v3 9050000.smmuv3: ias 44-bit, oas 44-bit
arm-smmu-v3 9050000.smmuv3: allocated 65536 entries for cmdq
arm-smmu-v3 9050000.smmuv3: allocated 32768 entries for evtq
iommu: Default domain type: Translated
```

- `ias 44-bit`: Input Address Size (IOVA width)
- `oas 44-bit`: Output Address Size (physical address width)
- `cmdq`: Command Queue for IOMMU operations
- `evtq`: Event Queue for fault reporting

### Scenario C: virtio-iommu

```
QEMU: -device virtio-iommu-pci
Result: Paravirtualized IOMMU for VMs
```

**Key point:** Guest needs `CONFIG_VIRTIO_IOMMU=y` for driver to load.

---

## Kernel Parameters

| Parameter | Values | Meaning |
|-----------|--------|---------|
| `iommu.passthrough` | 0 or 1 | 0 = translate, 1 = bypass |
| `iommu.strict` | 0 or 1 | 1 = synchronous unmap (safer), 0 = lazy (faster) |

---

## Quick Reference

### Check IOMMU Status (in guest)

```bash
# See IOMMU initialization
dmesg | grep -Ei 'iommu|smmu'

# List IOMMU groups
ls /sys/kernel/iommu_groups/

# See which devices are in which groups
find /sys/kernel/iommu_groups -type l
```

### Expected Differences

| Check | No IOMMU | SMMUv3 Enabled |
|-------|----------|----------------|
| Default domain | Passthrough | Translated |
| SMMU messages | None | `arm-smmu-v3 ...` init logs |
| IOMMU groups | Empty or minimal | Populated with devices |

---

*Generated from lab session on Linux 5.10.0-rc7*
*Git: 0477e9288185 | Date: 2026-03-16*
