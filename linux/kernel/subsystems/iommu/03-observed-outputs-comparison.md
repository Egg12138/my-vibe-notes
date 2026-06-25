# IOMMU Lab - Observed Outputs Comparison

[TOC]

## Quick Reference Table

| Feature | Scenario A (none) | Scenario B (smmuv3) | Scenario C (virtio) |
|---------|-------------------|---------------------|---------------------|
| QEMU IOMMU | `iommu=none` | `iommu=smmuv3` | `iommu=none` + device |
| Kernel Param | `passthrough=1` | `passthrough=0` | `passthrough=0` |
| Default Domain | Passthrough | Translated | Translated |
| SMMU Driver | Not loaded | `arm-smmu-v3` | Not loaded* |
| IOMMU Groups | None | Populated | Limited* |
| DMA Protection | No | Yes | Partial* |

\* virtio-iommu requires `CONFIG_VIRTIO_IOMMU=y` in guest

---

## Scenario A: No IOMMU (Baseline)

### Command
```bash
./tools/iommu-play/run-qemu-aarch64.sh \
  --scenario none \
  --kernel out/arm64/arch/arm64/boot/Image \
  --initrd out/arm64/initramfs.cpio.gz
```

### Effective QEMU Arguments
```bash
-machine virt,gic-version=3,iommu=none
-append "... iommu.passthrough=1"
```

### Key dmesg Output
```
[    0.000000] Kernel command line: ... iommu.passthrough=1
[    0.343300] iommu: Default domain type: Passthrough (set via kernel command line)
```

### What This Means
- IOMMU hardware: **Absent**
- Translation: **Bypassed**
- Device DMA: **Direct to physical memory**
- Security: **No isolation**

---

## Scenario B: SMMUv3 (Hardware Emulation)

### Command
```bash
./tools/iommu-play/run-qemu-aarch64.sh \
  --scenario smmuv3 \
  --kernel out/arm64/arch/arm64/boot/Image \
  --initrd out/arm64/initramfs.cpio.gz
```

### Effective QEMU Arguments
```bash
-machine virt,gic-version=3,iommu=smmuv3
-append "... iommu.passthrough=0 iommu.strict=1"
```

### Key dmesg Output
```
[    0.000000] Kernel command line: ... iommu.passthrough=0 iommu.strict=1
[    0.279815] iommu: Default domain type: Translated (set via kernel command line)
[    0.657020] arm-smmu-v3 9050000.smmuv3: ias 44-bit, oas 44-bit (features 0x00008705)
[    0.661286] arm-smmu-v3 9050000.smmuv3: allocated 65536 entries for cmdq
[    0.663539] arm-smmu-v3 9050000.smmuv3: allocated 32768 entries for evtq
[    0.867647] virtio-pci 0000:00:01.0: Adding to iommu group 0
```

### What This Means
- IOMMU hardware: **SMMUv3 at 0x9050000**
- Translation: **Active (IOVA -> physical)**
- Device DMA: **Translated and protected**
- Security: **Full isolation**
- Queues: **CMDQ (64K), EVTQ (32K)**

### IOMMU Group Structure
```
/sys/kernel/iommu_groups/
└── 0/
    └── devices/
        └── 0000:00:01.0 -> ../../../virtio-pci
```

---

## Scenario C: virtio-iommu (Paravirtualized)

### Command
```bash
./tools/iommu-play/run-qemu-aarch64.sh \
  --scenario virtio-iommu \
  --kernel out/arm64/arch/arm64/boot/Image \
  --initrd out/arm64/initramfs.cpio.gz
```

### Effective QEMU Arguments
```bash
-machine virt,gic-version=3,iommu=none
-device virtio-iommu-pci,id=viommu
-device virtio-blk-pci-non-transitional,drive=vdisk,iommu_platform=on
-device virtio-net-pci-non-transitional,netdev=n0,iommu_platform=on
-append "... iommu.passthrough=0 iommu.strict=1"
```

### Key dmesg Output
```
[    0.000000] Kernel command line: ... iommu.passthrough=0 iommu.strict=1
[    0.328780] iommu: Default domain type: Translated (set via kernel command line)
[    0.629022] OF: /pcie@10000000: no iommu-map translation for id 0x8 on (null)
[    0.630580] virtio-pci 0000:00:01.0: enabling device (0000 -> 0002)
```

### QEMU Warning (expected)
```
[qemu] warning: CONFIG_VIRTIO_IOMMU is not enabled in guest kernel
[qemu] warning: virtio-iommu driver may not load in guest.
```

### What This Means
- IOMMU hardware: **Paravirtual device** (virtio-iommu-pci)
- Translation: **Configured but limited** (driver missing)
- Device DMA: **Depends on guest driver**
- Security: **Requires CONFIG_VIRTIO_IOMMU**

### Missing iommu-map Issue
The error `no iommu-map translation for id 0x8` indicates:
- PCIe device RID 0x8 has no stream ID mapping
- Device tree needs `iommu-map` property
- Without it, PCIe devices can't join IOMMU groups

---

## Configuration Changes Required

### Enable virtio-iommu Support

```bash
cd out/arm64
scripts/config --file .config -e VIRTIO_IOMMU
make olddefconfig
tools/iommu-play/build-kernel-arm64.sh --target Image
```

### Verify After Rebuild
```bash
zcat /proc/config.gz | grep VIRTIO_IOMMU
# Should show: CONFIG_VIRTIO_IOMMU=y
```

---

## Comparison: dmesg IOMMU Lines

| Scenario | Key dmesg Pattern |
|----------|-------------------|
| none | `Default domain type: Passthrough` |
| smmuv3 | `arm-smmu-v3 ... ias 44-bit, oas 44-bit` |
| virtio-iommu | `no iommu-map translation` (warning) |

---

## Comparison: IOMMU Groups

Run in guest:
```bash
ls -la /sys/kernel/iommu_groups/
```

| Scenario | Expected Output |
|----------|-----------------|
| none | Empty or minimal |
| smmuv3 | `0/` directory with devices |
| virtio-iommu | Depends on driver |

---

*Generated from lab session on Linux 5.10.0-rc7*
*Git: 0477e9288185 | Date: 2026-03-16*
