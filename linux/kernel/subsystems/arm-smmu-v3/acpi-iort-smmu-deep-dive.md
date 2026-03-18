# ACPI IORT and ARM SMMUv3: A Comprehensive Deep-Dive

## Table of Contents

- [Executive Summary](#executive-summary)
- [Part I: Understanding the Basics](#part-i-understanding-the-basics)
  - [What is IOMMU?](#what-is-iommu)
  - [What is ARM SMMU?](#what-is-arm-smmu)
  - [What is ACPI IORT?](#what-is-acpi-iort)
- [Part II: Why These Technologies Matter](#part-ii-why-these-technologies-matter)
  - [Why IOMMU is Needed](#why-iommu-is-needed)
  - [Why SMMUv3 Specifically?](#why-smmuv3-specifically)
  - [Why ACPI IORT for ARM Servers?](#why-acpi-iort-for-arm-servers)
- [Part III: How It All Works](#part-iii-how-it-all-works)
  - [How ACPI IORT Describes Platform Topology](#how-acpi-iort-describes-platform-topology)
  - [How SMMUv3 Translates Addresses](#how-smmuv3-translates-addresses)
  - [How Linux Discovers and Configures SMMU](#how-linux-discovers-and-configures-smmu)
  - [How DMA Works with SMMU](#how-dma-works-with-smmu)
  - [How Deferred Probe Handles Module Loading](#how-deferred-probe-handles-module-loading)
- [Part IV: Code Deep-Dive](#part-iv-code-deep-dive)
  - [ACPI _DSD Property Parsing](#acpi-_dsd-property-parsing)
  - [IORT IOMMU Configuration](#iort-iommu-configuration)
  - [The Critical Decision: iort_iommu_xlate()](#the-critical-decision-iort_iommu_xlate)
  - [Deferred Probe Mechanism](#deferred-probe-mechanism)
- [Appendix: Configuration and Debugging](#appendix-configuration-and-debugging)

---

## Executive Summary

This document provides a complete understanding of ACPI IORT and ARM SMMUv3 in Linux kernel, explaining:

- **What** these technologies are and their purpose
- **Why** they exist and what problems they solve
- **How** they work together with detailed code analysis

**Key Insights:**

1. **IOMMU is the DMA equivalent of MMU** - It translates device-visible addresses (IOVA) to physical addresses (PA), providing isolation and security.

2. **SMMUv3 is ARM's IOMMU implementation** - It supports advanced features like SVA (Shared Virtual Addressing), ATS (Address Translation Services), and PRI (Page Request Interface).

3. **ACPI IORT describes platform I/O topology** - It tells the OS which IOMMU handles which devices, enabling plug-and-play on ARM servers.

4. **Deferred probe handles dependency ordering** - When SMMU is a module, devices automatically defer their probe until SMMU is loaded.

---

## Part I: Understanding the Basics

### What is IOMMU?

**IOMMU (I/O Memory Management Unit)** is a hardware component that sits between DMA-capable devices and system memory. It performs address translation for device-initiated memory accesses.

```
┌─────────────┐         ┌─────────────┐         ┌─────────────┐
│   Device    │ ──────▶ │   IOMMU     │ ──────▶ │   Memory    │
│  (PCIe/NIC) │  IOVA   │ (Address    │   PA    │  (Physical) │
│             │         │ Translation)│         │             │
└─────────────┘         └─────────────┘         └─────────────┘
```

**Key Functions:**

1. **Address Translation** - IOVA → PA mapping (like MMU for devices)
2. **Access Control** - Enforce memory access permissions per device
3. **Isolation** - Prevent devices from accessing unauthorized memory
4. **Scatter-Gather** - Map non-contiguous physical memory to contiguous IOVA

### What is ARM SMMU?

**SMMU (System MMU)** is ARM's implementation of an IOMMU. SMMUv3 is the third generation, featuring:

- **Stream Table** - Per-device context configuration (replaces global TTBR)
- **Context Descriptors** - Stage 1 and Stage 2 translation configurations
- **Command Queue** - Hardware command interface for TLB invalidation
- **Event Queue** - Hardware event reporting (faults, translations)
- **PRI Support** - Page Request Interface for on-demand paging

**SMMUv3 Architecture:**

```
                            ┌─────────────────────────┐
                            │      SMMUv3 Hardware     │
                            │  ┌───────────────────┐  │
         ┌──────────────┐   │  │  Stream Table     │  │
         │  Device 0    │───┼─▶│  (STR TAB)        │  │
         │  (StreamID=0)│   │  │  ┌─────────────┐  │  │
         └──────────────┘   │  │  │ CD (TTBR0)  │  │  │
                            │  │  └──────┬──────┘  │  │
         ┌──────────────┐   │  │         │          │  │
         │  Device 1    │───┼─▶│  ┌──────▼──────┐  │  │
         │  (StreamID=1)│   │  │  │ Page Table  │  │  │
         └──────────────┘   │  │  │   Walk      │  │  │
                            │  │  └──────┬──────┘  │  │
                            │  └─────────┼─────────┘  │
                            │            │            │
                            │            ▼            │
                            │      Physical Address   │
                            └─────────────────────────┘
```

### What is ACPI IORT?

**IORT (I/O Remapping Table)** is an ACPI specification table that describes the platform's I/O device topology and IOMMU relationships.

**Purpose:** Tell the OS which IOMMU handles which devices, and how to translate Stream IDs.

**IORT Table Structure:**

```
┌────────────────────────────────────────────────────┐
│                  ACPI IORT Table                    │
├────────────────────────────────────────────────────┤
│  Header                                            │
│    - Signature: "IORT"                             │
│    - Length, Revision, Checksum                    │
│    - Node Count, Node Offset                       │
├────────────────────────────────────────────────────┤
│  Node Array                                        │
│    ┌──────────────────────────────────┐            │
│    │ Node 0: PCI Root Complex         │            │
│    │   - Type: 0x01                   │            │
│    │   - Memory Address Limit         │            │
│    │   - ID Mapping Array ────────────┼───┐        │
│    └──────────────────────────────────┘   │        │
│                                            │        │
│    ┌──────────────────────────────────┐   │        │
│    │ Node 1: Named Component          │   │        │
│    │   - Type: 0x00                   │   │        │
│    │   - Device Name                  │   │        │
│    │   - ID Mapping Array ────────────┼───┤        │
│    └──────────────────────────────────┘   │        │
│                                            │        │
│    ┌──────────────────────────────────┐   │        │
│    │ Node 2: SMMUv3                   │◀──┘        │
│    │   - Type: 0x03                   │            │
│    │   - Base Address                 │            │
│    │   - Global IRQ, Context IRQ      │            │
│    └──────────────────────────────────┘            │
└────────────────────────────────────────────────────┘
```

---

## Part II: Why These Technologies Matter

### Why IOMMU is Needed?

#### Problem 1: DMA Without Protection

Without IOMMU, devices can DMA to **any physical address**:

```c
// Device driver requests DMA buffer
dma_addr = dma_alloc_coherent(dev, size, &dma_handle, GFP_KERNEL);

// Without IOMMU: dma_addr = physical address
// Device can potentially access ANY physical memory!
```

**Security Risk:** A malicious or buggy device could:
- Read sensitive kernel data
- Corrupt other processes' memory
- Compromise system integrity

#### Problem 2: 32-bit Devices on 64-bit Systems

A 32-bit PCIe device can only address 4GB, but the system has 64GB RAM:

```
Device (32-bit DMA) ──▶ Cannot address memory above 4GB
                         System has 64GB!
```

**Solution:** IOMMU provides **IOVA aliasing** - device sees 32-bit IOVA, IOMMU translates to 64-bit PA.

#### Problem 3: Scatter-Gather Complexity

Driver needs to gather data from multiple non-contiguous buffers:

```c
// Without IOMMU: Device must handle scatter-gather lists
// Complex DMA descriptor chains required

// With IOMMU: Map all buffers to contiguous IOVA
// Device sees simple, contiguous DMA buffer
```

### Why SMMUv3 Specifically?

#### Evolution from SMMUv2

| Feature | SMMUv2 | SMMUv3 |
|---------|--------|--------|
| Context Banks | Fixed, limited | Dynamic via Stream Table |
| VM Support | Limited | Full virtualization |
| SVA Support | No | Yes (Shared Virtual Addressing) |
| PRI/ATS | Optional | Standard |
| CMDQ/EVTQ | No | Yes (Command/Event Queues) |

#### SVA (Shared Virtual Addressing)

SMMUv3 supports **SVA** - devices can use process virtual addresses directly:

```c
// Traditional DMA: explicit map/unmap
void *cpu_ptr = kmalloc(size, GFP_KERNEL);
dma_addr_t iova = dma_map_single(dev, cpu_ptr, size, DMA_TO_DEVICE);
// ... device DMA ...
dma_unmap_single(dev, iova, size, DMA_TO_DEVICE);

// With SVA: device uses CPU virtual addresses directly
iommu_sva_bind_device(dev, mm, mm->pasid);
// Device can access mm->pgd virtual addresses!
// No dma_map/dma_unmap needed
```

**Benefits:**
- Zero-copy data sharing between CPU and device
- Simplified programming model
- On-demand paging support

### Why ACPI IORT for ARM Servers?

#### ARM Server Ecosystem

Unlike x86 (which has standardized ACPI), ARM servers use either:
- **Device Tree (DT)** - Embedded/mobile platforms
- **ACPI** - Server platforms (for standardization)

**IORT enables ARM servers to be plug-and-play:**

```
┌────────────────────────────────────────────────────────┐
│                  ARM Server Platform                    │
│                                                         │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐                 │
│  │  NIC 0  │  │  NIC 1  │  │  NVMe   │                 │
│  └────┬────┘  └────┬────┘  └────┬────┘                 │
│       │           │           │                         │
│       └───────────┼───────────┘                         │
│                   │                                     │
│            ┌──────▼──────┐                             │
│            │   SMMUv3    │  ← IORT tells OS about this │
│            └──────┬──────┘                             │
│                   │                                     │
│            ┌──────▼──────┐                             │
│            │   Memory    │                             │
│            └─────────────┘                             │
└────────────────────────────────────────────────────────┘
```

Without IORT, the OS would need platform-specific code to discover SMMU topology.

---

## Part III: How It All Works

### How ACPI IORT Describes Platform Topology

#### IORT Node Types

```c
// [include/linux/acpi/iort.h]

#define ACPI_IORT_NODE_ITS_GROUP           0x00  // Interrupt Translation Service
#define ACPI_IORT_NODE_NAMED_COMPONENT     0x00  // Named components (platform devices)
#define ACPI_IORT_NODE_PCI_ROOT_COMPLEX    0x01  // PCIe root complexes
#define ACPI_IORT_NODE_SMMU                0x02  // SMMUv2
#define ACPI_IORT_NODE_SMMU_V3             0x03  // SMMUv3
#define ACPI_IORT_NODE_PMCG                0x04  // Performance Monitoring
```

#### ID Mapping

Each device node has an **ID Mapping Array** that translates device IDs (Stream IDs for PCIe, Requester IDs) to SMMU Stream IDs:

```c
struct acpi_iort_id_mapping {
    u32 input_base;      // Starting input ID
    u32 id_count;        // Number of IDs
    u32 output_base;     // Starting output ID (Stream ID)
    u32 output_reference; // Offset to target IORT node (SMMU)
};
```

**Example Mapping:**

```
PCIe Device with BDF 01:00.0 (Requester ID = 0x0800)
    │
    └─→ IORT Mapping:
        input_base = 0x0000
        id_count   = 0x1000
        output_base = 0x0000
        output_reference → SMMUv3 Node

    └─→ Stream ID = 0x0800 (identity mapped)
        SMMU uses Stream ID to look up context in Stream Table
```

### How SMMUv3 Translates Addresses

#### Translation Flow

```
Device DMA Request (IOVA)
    │
    ▼
┌─────────────────────────────────────────┐
│  Stream Table Lookup                    │
│    - Index by Stream ID                 │
│    - Get Context Descriptor (CD)        │
└─────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────┐
│  Stage 1 Translation (if enabled)       │
│    - TTBR0 from CD                      │
│    - VA → IPA                           │
└─────────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────────┐
│  Stage 2 Translation (if enabled)       │
│    - TTBR1 from CD                      │
│    - IPA → PA                           │
└─────────────────────────────────────────┘
    │
    ▼
Physical Address → Memory Access
```

#### Context Descriptor

```c
// Simplified Context Descriptor structure
struct arm_smmu_ctx_desc {
    u64 ttbr;   // Translation Table Base Register
    u64 tcr;    // Translation Control Register
    u64 mair;   // Memory Attribute Indirection Register
    u32 asid;   // Address Space ID
    u32 ssid;   // Sub-Stream ID (for SVA)
};
```

### How Linux Discovers and Configures SMMU

#### Boot-Time Discovery

```
acpi_bus_scan()
    │
    └─→ Parse ACPI tables (including IORT)
        │
        └─→ acpi_iort_init()
            │
            └─→ iort_init_platform_devices()
                │
                └─→ For each SMMUv3 node in IORT:
                    ├─→ Allocate platform_device
                    ├─→ Set up resources (MMIO, IRQs)
                    └─→ Add to platform device list
```

#### SMMU Driver Probe

When `arm-smmu-v3.ko` loads:

```
arm_smmu_v3_init()
    │
    └─→ platform_driver_register(&arm_smmu_driver)
        │
        └─→ arm_smmu_v3_probe(pdev)
            │
            ├─→ ioremap MMIO registers
            ├─→ Get IRQs
            ├─→ Probe hardware capabilities
            │   └─→ Read IDR registers
            │       └─→ smmu->features, smmu->ias, smmu->oas
            │
            ├─→ Initialize structures
            │   ├─→ Stream Table (2-level or linear)
            │   ├─→ Command Queue (CMDQ)
            │   ├─→ Event Queue (EVTQ)
            │   └─→ Page Request Queue (PRIQ)
            │
            ├─→ Reset and enable SMMU
            │   └─→ Write CR0.SMMUEN = 1
            │
            └─→ Register with IOMMU core
                └─→ iommu_device_register(&smmu->iommu)
                    └─→ ops registered with fwnode
```

### How DMA Works with SMMU

#### DMA Mapping Flow

```c
// Device driver calls
dma_addr_t dma_map_single(struct device *dev, void *ptr, size_t size,
                          enum dma_data_direction dir)
    │
    └─→ dma_map_page_attrs()
        │
        ├─→ ops = get_dma_ops(dev)
        │   └─→ Returns &iommu_dma_ops (if IOMMU configured)
        │
        └─→ iommu_dma_map_page()
            │
            ├─→ iova = iommu_dma_alloc_iova(domain, size, dma_mask, dev)
            │   └─→ Allocate IOVA from IOVA domain
            │
            ├─→ phys = virt_to_phys(ptr)
            │
            └─→ iommu_map(domain, iova, phys, size, prot)
                │
                └─→ arm_smmu_map()
                    │
                    └─→ arm_lpae_map()
                        │
                        └─→ __arm_lpae_map()
                            │
                            ├─→ Walk page table levels
                            ├─→ Allocate intermediate tables
                            └─→ Write PTEs
```

#### DMA Unmapping Flow

```c
dma_unmap_single(struct device *dev, dma_addr_t dma_addr, size_t size,
                 enum dma_data_direction dir)
    │
    └─→ iommu_dma_unmap_page()
        │
        ├─→ iommu_unmap(domain, iova, size)
        │   └─→ arm_smmu_unmap()
        │       └─→ arm_lpae_unmap()
        │
        └─→ iommu_dma_free_iova(domain, iova)
```

### How Deferred Probe Handles Module Loading

#### The Problem

When SMMU is built as a module (`CONFIG_ARM_SMMU_V3=m`):

1. **Boot:** SMMU driver not loaded
2. **Device probes:** Needs IOMMU for DMA
3. **IOMMU not ready:** What to do?

#### The Solution: Deferred Probe

```
Device probe (FIRST ATTEMPT)
    │
    └─→ acpi_dma_configure_id()
        │
        └─→ iort_iommu_configure_id()
            │
            └─→ iort_iommu_xlate()
                │
                ├─→ ops = iommu_ops_from_fwnode()
                │   └─→ returns NULL (SMMU not loaded)
                │
                └─→ return -EPROBE_DEFER
                    (because IS_ENABLED(CONFIG_ARM_SMMU_V3) = true)

really_probe()
    │
    └─→ if (ret == -EPROBE_DEFER)
        └─→ driver_deferred_probe_add(dev)
            └─→ Add to deferred_probe_pending_list
```

#### Replay When SMMU Loads

```
modprobe arm-smmu-v3
    │
    └─→ arm_smmu_v3_probe()
        │
        └─→ iommu_device_register(&smmu->iommu)
            │
            └─→ SMMU driver binds
                │
                └─→ driver_bound(smmu_device)
                    │
                    └─→ driver_deferred_probe_trigger()
                        │
                        ├─→ Move deferred_probe_pending_list
                        │   to deferred_probe_active_list
                        │
                        └─→ schedule_work(&deferred_probe_work)
                            │
                            └─→ deferred_probe_work_func()
                                │
                                └─→ For each deferred device:
                                    └─→ bus_probe_device(dev)
                                        └─→ RE-ATTEMPT PROBE!
                                            └─→ This time IOMMU ops found!
```

---

## Part IV: Code Deep-Dive

### ACPI _DSD Property Parsing

#### acpi_init_properties()

```c
// [drivers/acpi/property.c:364-425]

static void acpi_init_properties(struct acpi_device *adev)
{
    struct acpi_hardware_id *hwid;
    acpi_status status;
    struct acpi_device_properties *props;

    // Extract _DSD (Device Specific Data)
    status = acpi_extract_properties(adev->handle, &adev->data);
    if (ACPI_FAILURE(status))
        return;

    // Properties stored in adev->data.properties linked list
    // Later used by device_property_read_u32(), etc.
}
```

#### acpi_extract_properties()

```c
// [drivers/acpi/property.c:384-413]

static acpi_status acpi_extract_properties(acpi_handle handle,
                                           struct acpi_device_data *data)
{
    struct acpi_object_list *dsd;

    // Get _DSD package
    status = acpi_get_data(ACPI_NAME_DSD, &dsd);
    if (ACPI_FAILURE(status))
        return status;

    // Extract properties from _DSD
    acpi_data_add_props(data, dsd);

    return AE_OK;
}
```

#### acpi_data_add_props()

```c
// [drivers/acpi/property.c:364-382]

static void acpi_data_add_props(struct acpi_device_data *data,
                                struct acpi_object_list *dsd)
{
    const union acpi_object *properties;

    // Get "device-property" from _DSD
    ret = acpi_data_get_property(data, "device-property",
                                  ACPI_TYPE_PACKAGE, &properties);
    if (ret)
        return;

    // Iterate through properties
    for (i = 0; i < properties->package.count; i++) {
        property = &properties->package.elements[i];
        propname = &property->package.elements[0];
        propvalue = &property->package.elements[1];

        // Add to linked list
        acpi_add_property(data, propname, propvalue);
    }
}
```

### IORT IOMMU Configuration

#### acpi_dma_configure_id()

```c
// [drivers/acpi/scan.c:1461-1482]

int acpi_dma_configure_id(struct device *dev, enum dev_dma_attr attr,
                          const u32 *input_id)
{
    const struct iommu_ops *iommu;
    u64 dma_addr = 0, size = 0;

    if (attr == DEV_DMA_NOT_SUPPORTED) {
        set_dma_ops(dev, &dma_dummy_ops);
        return 0;
    }

    // Step 1: Setup DMA addressing from IORT
    iort_dma_setup(dev, &dma_addr, &size);

    // Step 2: Configure IOMMU
    iommu = iort_iommu_configure_id(dev, input_id);

    // Step 3: Handle deferred probe
    if (PTR_ERR(iommu) == -EPROBE_DEFER)
        return -EPROBE_DEFER;  // Propagate defer

    // Step 4: Setup DMA operations
    arch_setup_dma_ops(dev, dma_addr, size, iommu, attr == DEV_DMA_COHERENT);

    return 0;
}
```

### The Critical Decision: iort_iommu_xlate()

#### Full Function

```c
// [drivers/acpi/arm64/iort.c:923-950]

static const struct iommu_ops *iort_iommu_xlate(struct device *dev,
                                                 struct acpi_iort_node *node,
                                                 u32 streamid)
{
    const struct iommu_ops *ops;
    struct fwnode_handle *iort_fwnode;

    if (!node)
        return ERR_PTR(-ENODEV);

    // Get fwnode from IORT node
    iort_fwnode = iort_get_fwnode(node);
    if (!iort_fwnode)
        return ERR_PTR(-ENODEV);

    // Get IOMMU ops from fwnode
    ops = iommu_ops_from_fwnode(iort_fwnode);

    // KEY DECISION POINT
    if (!ops)
        return ERR_PTR(iort_iommu_driver_enabled(node->type) ?
                       -EPROBE_DEFER : -ENODEV);

    // Continue with translation
    return arm_smmu_iort_xlate(dev, streamid, iort_fwnode, ops);
}
```

#### iort_iommu_driver_enabled()

```c
// [drivers/acpi/arm64/iort.c:890-901]

static int iort_iommu_driver_enabled(u8 type)
{
    switch (type) {
    case ACPI_IORT_NODE_SMMU_V3:
        return IS_ENABLED(CONFIG_ARM_SMMU_V3);
        // For CONFIG=n: returns 0 (false)
        // For CONFIG=y/m: returns 1 (true)
    default:
        return 0;
    }
}
```

#### IS_ENABLED() Macro

```c
// [include/linux/kconfig.h:69-73]

#define IS_ENABLED(option) __or(IS_BUILTIN(option), IS_MODULE(option))
#define IS_BUILTIN(option) __is_defined(option)
#define IS_MODULE(option) __is_defined(option##_MODULE)
```

| CONFIG value | IS_BUILTIN | IS_MODULE | IS_ENABLED |
|--------------|------------|-----------|------------|
| n            | 0          | 0         | 0 (false)  |
| y            | 1          | 0         | 1 (true)   |
| m            | 0          | 1         | 1 (true)   |

### Deferred Probe Mechanism

#### driver_deferred_probe_add()

```c
// [drivers/base/dd.c:124-144]

void driver_deferred_probe_add(struct device *dev)
{
    mutex_lock(&deferred_probe_mutex);
    if (list_empty(&dev->p->deferred_probe)) {
        dev_dbg(dev, "Added to deferred list\n");
        list_add_tail(&dev->p->deferred_probe, &deferred_probe_pending_list);
    }
    mutex_unlock(&deferred_probe_mutex);
}
```

#### driver_deferred_probe_trigger()

```c
// [drivers/base/dd.c:165-186]

static void driver_deferred_probe_trigger(void)
{
    if (!driver_deferred_probe_enable)
        return;

    mutex_lock(&deferred_probe_mutex);
    atomic_inc(&deferred_trigger_count);

    // Move all pending devices to active list
    list_splice_tail_init(&deferred_probe_pending_list,
                          &deferred_probe_active_list);

    mutex_unlock(&deferred_probe_mutex);

    // Schedule work function
    schedule_work(&deferred_probe_work);
}
```

#### deferred_probe_work_func()

```c
// [drivers/base/dd.c:75-122]

static void deferred_probe_work_func(struct work_struct *work)
{
    mutex_lock(&deferred_probe_mutex);

    while (!list_empty(&deferred_probe_active_list)) {
        private = list_first_entry(&deferred_probe_active_list,
                                   typeof(*dev->p), deferred_probe);
        dev = private->device;
        list_del_init(&private->deferred_probe);

        mutex_unlock(&deferred_probe_mutex);

        dev_dbg(dev, "Retrying from deferred list\n");
        bus_probe_device(dev);  // Re-attempt probe!

        mutex_lock(&deferred_probe_mutex);
        put_device(dev);
    }

    mutex_unlock(&deferred_probe_mutex);
}
```

---

## Appendix: Configuration and Debugging

### Kconfig Options

```kconfig
# drivers/iommu/Kconfig

config IOMMU_SUPPORT
    bool "IOMMU Hardware Support"
    depends on MMU
    default y

config ARM_SMMU_V3
    tristate "ARM Ltd. System MMU Version 3 (SMMUv3) Support"
    depends on ARM64
    select IOMMU_API
    select IOMMU_IO_PGTABLE_LPAE
    select GENERIC_MSI_IRQ_DOMAIN

config ARM_SMMU_V3_SVA
    bool "Shared Virtual Addressing support for the ARM SMMUv3"
    depends on ARM_SMMU_V3
```

### Debug Commands

```bash
# Check deferred devices
cat /sys/kernel/debug/devices_deferred

# Check IOMMU groups
ls -R /sys/kernel/iommu_groups/

# Check SMMU driver status
lsmod | grep arm_smmu
dmesg | grep -i smmu

# Enable debug logging
echo 8 > /proc/sys/kernel/printk
```

### Common Issues

#### Issue 1: Device Stuck in Deferred Probe

**Symptom:** Device never probes, stuck in `deferred_probe_pending_list`

**Cause:** SMMU driver not loaded or not matching IORT node

**Debug:**
```bash
dmesg | grep "Added to deferred list"
dmesg | grep "Retrying from deferred list"
cat /sys/kernel/debug/devices_deferred
```

**Solution:**
```bash
# Load SMMU driver manually
modprobe arm-smmu-v3

# Or enable in kernel config
CONFIG_ARM_SMMU_V3=y  # Built-in instead of module
```

#### Issue 2: IORT Parsing Errors

**Symptom:** `iort_iommu_xlate()` returns -ENODEV

**Cause:** IORT table malformed or missing SMMU node

**Debug:**
```bash
dmesg | grep -i iort
```

**Solution:** Fix ACPI IORT table in firmware

---

<!--
Repository: linux
Tag: v5.10-rc7
Commit: 0477e92881850d44910a7e94fc2c46f96faa131f
Generated: 2026-03-13
-->
