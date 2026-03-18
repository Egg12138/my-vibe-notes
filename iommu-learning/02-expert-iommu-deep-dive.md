# IOMMU Learning Lab - Expert Notes

[TOC]

## Lab Environment

- **Kernel**: Linux 5.10.0-rc7 (arm64)
- **QEMU**: `qemu-system-aarch64` with `virt` machine
- **Toolchain**: aarch64-none-linux-gnu-gcc 15.2.1

---

## Experimental Results Summary

### Scenario A: Baseline (No IOMMU Translation)

**Configuration:**
```bash
-machine virt,gic-version=3,iommu=none
-append "... iommu.passthrough=1"
```

**Key dmesg Output:**
```
iommu: Default domain type: Passthrough (set via kernel command line)
```

**Analysis:**
- No SMMU hardware probed
- IOMMU core operates in passthrough mode
- DMA addresses = physical addresses
- No isolation, no translation overhead

### Scenario B: SMMUv3 Hardware Emulation

**Configuration:**
```bash
-machine virt,gic-version=3,iommu=smmuv3
-append "... iommu.passthrough=0 iommu.strict=1"
```

**Key dmesg Output:**
```
arm-smmu-v3 9050000.smmuv3: ias 44-bit, oas 44-bit (features 0x00008705)
arm-smmu-v3 9050000.smmuv3: allocated 65536 entries for cmdq
arm-smmu-v3 9050000.smmuv3: allocated 32768 entries for evtq
iommu: Default domain type: Translated (set via kernel command line)
virtio-pci 0000:00:01.0: Adding to iommu group 0
```

**Analysis:**

1. **Address Width**: Both input/output are 44-bit (176TB address space)
   - `ias`: Input Address Size (IOVA)
   - `oas`: Output Address Size (physical)

2. **Queue Allocation**:
   - Command Queue: 65536 entries × 16 bytes = 1MB
   - Event Queue: 32768 entries × 32 bytes = 1MB
   - Queues enable lock-free driver operation

3. **Feature Flags** (`0x00008705`):
   - Bit 0: `COHACC` - Coherent access support
   - Bit 2: `ATS` - Address Translation Services
   - Bits 12-13: Priority of Stall over Terminate

4. **IOMMU Group 0**: virtio-pci device isolated in its own group

### Scenario C: virtio-iommu (Paravirtualized)

**Configuration:**
```bash
-machine virt,gic-version=3,iommu=none
-device virtio-iommu-pci,id=viommu
-device virtio-blk-pci-non-transitional,drive=vdisk,iommu_platform=on
-device virtio-net-pci-non-transitional,netdev=n0,iommu_platform=on
-append "... iommu.passthrough=0 iommu.strict=1"
```

**Key dmesg Output:**
```
iommu: Default domain type: Translated (set via kernel command line)
OF: /pcie@10000000: no iommu-map translation for id 0x8 on (null)
```

**Analysis:**

1. **Warning Message**: `CONFIG_VIRTIO_IOMMU` not enabled in kernel
   - Guest driver doesn't load
   - IOMMU core still sets "Translated" domain
   - But no paravirtual IOMMU driver to manage mappings

2. **iommu-map Error**: Device tree missing proper IOMMU mapping for PCIe devices
   - `iommu-map` property required for PCIe RID to stream ID translation
   - Without it, devices can't be added to IOMMU groups properly

3. **`iommu_platform=on`**: QEMU flag telling virtio devices to use IOMMU

---

## Driver Architecture Comparison

### SMMU v1/v2 (`drivers/iommu/arm/arm-smmu/`)

```
Programming Model: Context Banks
- Direct register writes
- One context bank per VM/group
- Limited scalability
```

### SMMU v3 (`drivers/iommu/arm/arm-smmu-v3/`)

```
Programming Model: Queue-Based
- Command Queue (CMDQ): STE creation, TLB invalidation
- Event Queue (EVTQ): Fault reporting
- PRI Queue (PRIQ): Page request interface (ATS support)
- Stream Table Entry (STE): Per-stream configuration
```

---

## Device Tree Bindings

### SMMUv3 Node

```dts
smmuv3: iommu@9050000 {
    compatible = "arm,smmu-v3";
    reg = <0x0 0x9050000 0x0 0x20000>;
    interrupts = <GIC_SPI 10 IRQ_TYPE_LEVEL_HIGH>;
    #iommu-cells = <1>;
};
```

### Client Device Reference

```dts
pcie@10000000 {
    iommu-map = <0x0 &smmuv3 0x0 0x10000>;
};
```

---

## Key Code Paths (Linux Kernel)

### IOMMU Core Initialization

```
drivers/iommu/iommu.c
  iommu_init()
    -> bus_set_iommu()
    -> iommu_group_get_for_dev()
```

### SMMUv3 Probe

```
drivers/iommu/arm/arm-smmu-v3/arm-smmu-v3.c
  arm_smmu_device_probe()
    -> arm_smmu_device_cfg_probe()  // Detect capabilities
    -> arm_smmu_write_strtab()      // Program stream table
    -> arm_smmu_rdy_for_events()    // Enable event queue
```

### Domain Attachment

```
arm_smmu_attach_dev()
  -> arm_smmu_write_ste()  // Program STE for this device
  -> arm_smmu_tlb_inv()    // Invalidate cached translations
```

---

## Performance Considerations

### Translation Overhead

| Mode | Latency | Throughput | Use Case |
|------|---------|------------|----------|
| Passthrough | Minimal | Maximum | Trusted devices, bare-metal |
| Translated | +10-50ns | Slightly reduced | Untrusted devices, VMs |
| Strict | Highest | Lowest | Debugging, safety-critical |

### `iommu.strict` Trade-offs

- **strict=1** (sync unmap):
  - TLB invalidation completes before `dma_unmap()` returns
  - Safer: device can't access unmapped memory
  - Slower: more TLB flush operations

- **strict=0** (lazy unmap):
  - Unmap deferred, TLB flushed later in batch
  - Faster: amortized invalidation cost
  - Risk: brief window where device could access freed memory

---

## Troubleshooting Guide

### No IOMMU Groups Visible

```bash
# Check kernel config
grep CONFIG_IOMMU /boot/config-$(uname -r)

# Check kernel cmdline
cat /proc/cmdline | grep iommu

# Check dmesg for IOMMU init
dmesg | grep -i iommu
```

### Devices Not in Expected Groups

```bash
# Check IOMMU mappings
find /sys/kernel/iommu_groups -type l

# Check device-tree iommu-map property
dtc -I fs /proc/device-tree > system.dts
grep iommu-map system.dts
```

### virtio-iommu Driver Not Loading

```bash
# Enable in kernel config
CONFIG_VIRTIO_IOMMU=y

# Or as module
CONFIG_VIRTIO_IOMMU=m
```

---

## Further Reading

- **DT Bindings**: `Documentation/devicetree/bindings/iommu/arm,smmu-v3.yaml`
- **Driver**: `drivers/iommu/arm/arm-smmu-v3/arm-smmu-v3.c`
- **Admin Guide**: `Documentation/admin-guide/kernel-parameters.txt`
- **Arm SMMU Architecture**: Arm IHI 0070 (SMMUv3 specification)

---

*Generated from lab session on Linux 5.10.0-rc7*
*Git: 0477e9288185 | Date: 2026-03-16*
