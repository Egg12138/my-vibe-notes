# ACPI IORT Complete Call Chain Analysis

## Table of Contents

- [Overview](#overview)
- [What is ACPI IORT?](#what-is-acpi-iort)
- [Why IORT Matters for SMMU?](#why-iort-matters-for-smmu)
- [Stage 0: ACPI _DSD Property Parsing](#stage-0-acpi-_dsd-property-parsing)
- [Stage 1: CONFIG_ARM_SMMU_V3=n - No SMMU Driver](#stage-1-config_arm_smmu_v3n---no-smmu-driver)
- [Stage 2: CONFIG_ARM_SMMU_V3=m - Module Not Yet Loaded](#stage-2-config_arm_smmu_v3m---module-not-yet-loaded)
- [Key Decision Point: iort_iommu_xlate()](#key-decision-point-iort_iommu_xlate)
- [Timeline Comparison](#timeline-comparison)
- [Code Locations Reference](#code-locations-reference)

---

## Overview

This document traces the complete function calling chain for device probe on ARM64 ACPI platforms, comparing `CONFIG_ARM_SMMU_V3=n` vs `CONFIG_ARM_SMMU_V3=m` configurations. The analysis reveals how ACPI IORT (IO Remapping Table) guides the kernel in configuring IOMMU for devices.

**Key Finding:** The CONFIG setting affects **probe timing**, not **property content**. The `_DSD` (Device Specific Data) is parsed at boot regardless of SMMU driver configuration.

---

## What is ACPI IORT?

**IORT (IO Remapping Table)** is an ACPI table that describes the platform's I/O topology, specifically:

1. **Device hierarchy** - How devices are connected through IOMMU
2. **Stream ID mapping** - How device transactions are identified to the IOMMU
3. **IOMMU node references** - Which IOMMU handles which devices

### IORT Node Types

```c
// [include/linux/acpi/iort.h]

#define ACPI_IORT_NODE_ITS_GROUP           0x00  // Interrupt Translation Service
#define ACPI_IORT_NODE_NAMED_COMPONENT     0x00  // Named components (platform devices)
#define ACPI_IORT_NODE_PCI_ROOT_COMPLEX    0x01  // PCIe root complexes
#define ACPI_IORT_NODE_SMMU                0x02  // SMMUv2
#define ACPI_IORT_NODE_SMMU_V3             0x03  // SMMUv3
#define ACPI_IORT_NODE_PMCG                0x04  // Performance Monitoring
```

### IORT Structure

```
┌─────────────────────────────────────────────────────────┐
│                    IORT Table                            │
├─────────────────────────────────────────────────────────┤
│  Header                                                  │
│  └─→ table_offset, node_count, node_offset              │
│                                                          │
│  Node 0: PCI Root Complex                               │
│  ┌─────────────────────────────────────────┐            │
│  │ type: PCI_ROOT_COMPLEX                  │            │
│  │ mapping_count: 2                        │            │
│  │ mapping_offset: → ID Mapping Array      │────────┐   │
│  └─────────────────────────────────────────┘        │   │
│                                                     │   │
│  ID Mapping Array                                   │   │
│  ┌─────────────────────────────────────────┐        │   │
│  │ input_base: 0x0000                      │        │   │
│  │ id_count: 0x100                         │        │   │
│  │ output_reference: → Node 2 (SMMUv3)     │────────┼───┘
│  │ output_base: 0x0000                     │        │
│  └─────────────────────────────────────────┘        │
│                                                     │
│  Node 2: SMMUv3                                     │
│  ┌─────────────────────────────────────────┐        │
│  │ type: SMMU_V3                           │←───────┘
│  │ base_address: 0x10000000                │
│  │ global_irq: 45                          │
│  │ context_irq: 46                         │
│  └─────────────────────────────────────────┘
└─────────────────────────────────────────────────────────┘
```

---

## Why IORT Matters for SMMU?

When a device driver probes on an ARM64 ACPI platform, the kernel must:

1. **Find the IOMMU** - Which SMMU handles this device?
2. **Configure DMA** - Set up proper address translation
3. **Assign Stream IDs** - Identify the device's transactions

IORT provides this information in a platform-agnostic way, similar to how Device Tree works for DT-based systems.

### The Critical Function: `acpi_dma_configure_id()`

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

    // Step 2: Configure IOMMU - THIS IS WHERE THE MAGIC HAPPENS
    iommu = iort_iommu_configure_id(dev, input_id);

    // Step 3: Handle deferred probe
    if (PTR_ERR(iommu) == -EPROBE_DEFER)
        return -EPROBE_DEFER;  // SMMU not ready yet

    // Step 4: Setup DMA operations with IOMMU
    arch_setup_dma_ops(dev, dma_addr, size, iommu, attr == DEV_DMA_COHERENT);

    return 0;
}
```

---

## Stage 0: ACPI _DSD Property Parsing

### Executed During System Boot - Before Any Driver Probe

```c
acpi_bus_scan()
    │   [drivers/acpi/scan.c - ACPI namespace enumeration]
    │
    └─→ acpi_add_single_object(handle, type, sta)
        │   [drivers/acpi/scan.c:1570-1620]
        │
        ├─→ acpi_init_device_object(adev, handle, type, sta)
        │   │
        │   ├─→ acpi_device_set_context(adev)
        │   │   └─→ acpi_evaluate_late(adev)
        │   │
        │   ├─→ acpi_device_get_power(adev)
        │   │
        │   └─→ acpi_device_get_gsi(adev)
        │
        └─→ acpi_init_properties(adev)  ← KEY FUNCTION
            │   [drivers/acpi/property.c:364-425]
            │   Parse _DSD and store in adev->data.properties
            │
            └─→ acpi_extract_properties(adev->handle, &adev->data)
                │   [drivers/acpi/property.c:384-413]
                │
                ├─→ acpi_get_data(ACPI_NAME_DSD, &dsd)
                │   │   Get _DSD (Device Specific Data) from ACPI
                │   │
                │   └─→ if (ACPI_FAILURE(status)) return;
                │
                └─→ acpi_data_add_props(&adev->data, dsd)
                    │   [drivers/acpi/property.c:364-382]
                    │
                    ├─→ acpi_data_get_property(&adev->data, "device-property", ...)
                    │   │   [drivers/acpi/property.c:485-522]
                    │   │
                    │   └─→ list_for_each_entry(props, &data->properties, list)
                    │       │   Iterate through all properties
                    │       │
                    │       └─→ for each property in package:
                    │           └─→ acpi_add_property(&adev->data, propname, propvalue)
                    │               │
                    │               ├─→ property = kzalloc(sizeof(*property), ...);
                    │               ├─→ property->name = propname;
                    │               ├─→ property->value = propvalue;
                    │               │
                    │               └─→ list_add(&property->list, &adev->data.properties);
                    │
                    └─→ Result: adev->data.properties linked list populated
```

### Result: Device Properties Structure

```
adev->data.properties linked list:
┌─────────────────────────────────────────────────────┐
│  acpi_device_properties.properties                  │
│    └─→ property_1: {name: "dma-coherent", value: 1}│
│    └─→ property_2: {name: "bdmax", value: 64}      │ ← May or may not exist
│    └─→ property_3: {name: "iort-id", value: 0x100} │
│    └─→ ...                                          │
└─────────────────────────────────────────────────────┘

This data structure is used later by device_property_read_u32()
```

---

## Stage 1: CONFIG_ARM_SMMU_V3=n - No SMMU Driver

### No SMMU V3 Driver Available (Built-out)

```
your_driver_probe(struct device *dev)
    │
    └─→ acpi_dma_configure_id(dev, attr, input_id)
        │   [drivers/acpi/scan.c:1461-1482]
        │
        ├─→ iort_dma_setup(dev, &dma_addr, &size)
        │   │   [drivers/acpi/arm64/iort.c:1142-1186]
        │   │   Get DMA address range from IORT
        │   │
        │   └─→ ret = acpi_dma_get_range(dev, &dmaaddr, &offset, &size)
        │       │   [drivers/acpi/scan.c:1397-1453]
        │       │
        │       ├─→ if (ret == -ENODEV)
        │       │   │
        │       │   ├─→ if (dev_is_pci(dev))
        │       │   │   └─→ rc_dma_get_range(dev, &size)
        │       │   │       └─→ Get memory_address_limit from RC node
        │       │   │
        │       │   └─→ nc_dma_get_range(dev, &size)
        │       │       └─→ Get memory_address_limit from NC node
        │       │
        │       └─→ dma_direct_set_offset(dev, dmaaddr + offset, ...)
        │
        └─→ iommu = iort_iommu_configure_id(dev, input_id)
            │   [drivers/acpi/arm64/iort.c:1025-1088]
            │
            ├─→ ops = iort_fwspec_iommu_ops(dev)
            │   │   [iort.c:809-814]
            │   │
            │   └─→ return NULL;  // No fwspec yet
            │
            ├─→ if (ops) return ops;  // Skip if configured
            │
            ├─→ [PCI or Platform path to find IORT node]
            │   └─→ iort_scan_node(ACPI_IORT_NODE_SMMU_V3, ...)
            │       └─→ Returns IORT node for SMMU
            │
            └─→ iort_iommu_xlate(dev, node, streamid)
                │   [iort.c:923-950] - THE KEY FUNCTION
                │
                ├─→ iort_fwnode = iort_get_fwnode(node)
                │   │   [iort.c:81-97]
                │   │   Get fwnode from IORT node
                │   │
                │   └─→ return fwnode;  // Valid fwnode
                │
                ├─→ if (!iort_fwnode)
                │   └─→ return -ENODEV;
                │
                ├─→ ops = iommu_ops_from_fwnode(iort_fwnode)
                │   │   [drivers/iommu/iommu.c]
                │   │   Look up iommu_ops from fwnode
                │   │
                │   └─→ return NULL;  // No SMMUv3 driver loaded
                │
                ├─→ if (!ops)  ← TRUE
                │   │
                │   └─→ return iort_iommu_driver_enabled(node->type) ?
                │                  -EPROBE_DEFER : -ENODEV;  [line 946-947]
                │
                │       └─→ iort_iommu_driver_enabled(ACPI_IORT_NODE_SMMU_V3)
                │           │   [iort.c:890-901]
                │           │
                │           ├─→ case ACPI_IORT_NODE_SMMU_V3:
                │           │   └─→ return IS_ENABLED(CONFIG_ARM_SMMU_V3);
                │           │       │
                │           │       └─→ For CONFIG=n:
                │           │           IS_BUILTIN(n) = 0
                │           │           IS_MODULE(n) = 0
                │           │           IS_ENABLED() = 0 ← FALSE
                │           │
                │           └─→ return false;
                │
                └─→ return -ENODEV;  ← Returns ENODEV, not DEFER

        │
        ├─→ if (PTR_ERR(iommu) == -EPROBE_DEFER)  ← FALSE
        │   │   PTR_ERR(NULL) = 0, condition is FALSE
        │   │
        │   └─→ [SKIP - do not return]
        │
        └─→ arch_setup_dma_ops(dev, dma_addr, size, iommu, ...)
            │   iommu = NULL (no IOMMU configured)
            │
            ├─→ if (iommu)
            │   └─→ Configure IOMMU DMA ops
            │
            └─→ dev->dma_ops = &dma_direct_ops;  // Direct DMA
            └─→ return 0;

│
├─→ [Driver probe continues execution immediately]
│
└─→ device_property_read_u32(dev, "bdmax", &val)
    │   [include/linux/property.h:141-145]
    │
    └─→ Returns: 0 if bdmax exists, -EINVAL if not
```

### Result for CONFIG_ARM_SMMU_V3=n

```
┌────────────────────────────────────────────────────────┐
│ CONFIG_ARM_SMMU_V3=n Execution Flow                    │
├────────────────────────────────────────────────────────┤
│                                                        │
│  1. acpi_dma_configure_id() executes                  │
│  2. iort_iommu_xlate() returns -ENODEV                │
│     (because IS_ENABLED(CONFIG_ARM_SMMU_V3) = false)  │
│  3. acpi_dma_configure_id() IGNORES -ENODEV, continues│
│  4. arch_setup_dma_ops() with iommu=NULL              │
│  5. Driver probe continues immediately                │
│  6. device_property_read_u32("bdmax") executes        │
│  7. Returns: 0 if exists, -EINVAL if not              │
│                                                        │
│ Key Point: Probe is NOT delayed, executes to completion│
└────────────────────────────────────────────────────────┘
```

---

## Stage 2: CONFIG_ARM_SMMU_V3=m - Module Not Yet Loaded

### SMMU V3 Driver Built as Module, Not Yet Loaded

```
your_driver_probe(struct device *dev)
    │
    └─→ acpi_dma_configure_id(dev, attr, input_id)
        │   [drivers/acpi/scan.c:1461-1482]
        │
        ├─→ iort_dma_setup(dev, &dma_addr, &size)
        │   [Same as CONFIG=n case]
        │
        └─→ iommu = iort_iommu_configure_id(dev, input_id)
            │   [drivers/acpi/arm64/iort.c:1025-1088]
            │
            └─→ iort_iommu_xlate(dev, node, streamid)
                │   [iort.c:923-950]
                │
                ├─→ iort_fwnode = iort_get_fwnode(node)
                │   └─→ return fwnode;  // Valid fwnode
                │
                ├─→ ops = iommu_ops_from_fwnode(iort_fwnode)
                │   └─→ return NULL;  // arm-smmu-v3.ko not loaded
                │
                ├─→ if (!ops)  ← TRUE
                │   │
                │   └─→ return iort_iommu_driver_enabled(node->type) ?
                │                  -EPROBE_DEFER : -ENODEV;
                │
                │       └─→ IS_ENABLED(CONFIG_ARM_SMMU_V3)
                │           │   For CONFIG=m:
                │           │   IS_BUILTIN(m) = 0
                │           │   IS_MODULE(m) = 1
                │           │   IS_ENABLED() = 1 ← TRUE
                │           │
                │           └─→ return true;
                │
                └─→ return -EPROBE_DEFER;  ← DEFERRED!

        │
        ├─→ iommu = ERR_PTR(-EPROBE_DEFER);
        │
        ├─→ if (PTR_ERR(iommu) == -EPROBE_DEFER)  ← TRUE
        │   │   PTR_ERR(ERR_PTR(-EPROBE_DEFER)) = -EPROBE_DEFER
        │   │
        │   ├─→ return -EPROBE_DEFER;  [line 1476]
        │   │
        │   └─→ [FUNCTION EXITS EARLY]
        │
        └─→ [Driver probe DEFERRED]

│
└─→ return -EPROBE_DEFER;  // your_driver_probe() returns
    │
    └─→ [Added to deferred probe list]
```

### Deferred Probe Timeline

```
t0: Device probe DEFERRED (SMMU module not loaded)
    ↓
t1: [TIME PASSES - System waits for SMMUv3 driver]
    ↓
t2: User runs: modprobe arm-smmu-v3
    ↓
t3: arm_smmu_v3_init() executes
    └─→ pci_register_driver(&arm_smmu_driver)
        └─→ arm_smmu_v3_probe(pdev)
            └─→ iommu_device_register(&smmu->iommu)
                └─→ ops registered with fwnode
                    └─→ Triggers IORT replay
                        └─→ iort_add_device_replay(dev)
                            └─→ iommu_probe_device(dev)
                                └─→ __iommu_probe_device(dev)
                                    └─→ ops = iommu_ops_from_fwnode()
                                        └─→ NOW SUCCEEDS!
    ↓
t4: driver_deferred_probe_trigger() called
    └─→ schedule_work(&deferred_probe_work)
        └─→ deferred_probe_work_func()
            └─→ bus_probe_device(dev)  ← RE-ATTEMPT
                └─→ really_probe(dev, drv)  ← SECOND CALL
                    └─→ acpi_dma_configure_id()
                        └─→ iort_iommu_xlate()
                            └─→ ops = iommu_ops_from_fwnode()
                                └─→ SUCCESS! Returns arm_smmu_ops
    ↓
t5: Driver probe completes successfully with IOMMU
```

---

## Key Decision Point: iort_iommu_xlate()

### The Critical Code Path

```c
// [drivers/acpi/arm64/iort.c:923-950]

static const struct iommu_ops *iort_iommu_xlate(struct device *dev,
                                                 struct acpi_iort_node *node,
                                                 u32 streamid)
{
    const struct iommu_ops *ops;
    struct fwnode_handle *iort_fwnode;

    if (!node)
        return -ENODEV;

    // Get fwnode from IORT node
    iort_fwnode = iort_get_fwnode(node);
    if (!iort_fwnode)
        return -ENODEV;

    // Get IOMMU ops from fwnode
    ops = iommu_ops_from_fwnode(iort_fwnode);

    // KEY DECISION POINT:
    if (!ops)
        return iort_iommu_driver_enabled(node->type) ?
               -EPROBE_DEFER : -ENODEV;  // Line 946-947

    // Continue with translation...
    return arm_smmu_iort_xlate(dev, streamid, iort_fwnode, ops);
}
```

### Decision Tree

```
┌─────────────────────────────────────────────────────────┐
│                    DECISION TREE                        │
├─────────────────────────────────────────────────────────┤
│                                                         │
│  ops = iommu_ops_from_fwnode(iort_fwnode)              │
│         │                                                │
│         └─→ NULL (SMMU driver not probed yet)           │
│                                                         │
│  iort_iommu_driver_enabled(node->type)                  │
│    │                                                    │
│    ├─→ return IS_ENABLED(CONFIG_ARM_SMMU_V3);          │
│    │                                                    │
│    └─→ For ACPI_IORT_NODE_SMMU_V3:                     │
│        │                                                │
│        ├─→ CONFIG=n: IS_ENABLED() = false              │
│        │   └─→ return -ENODEV                          │
│        │                                                │
│        └─→ CONFIG=y/m: IS_ENABLED() = true             │
│            └─→ return -EPROBE_DEFER                    │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

### IS_ENABLED() Macro Behavior

```c
// [include/linux/kconfig.h:69-73]

#define IS_ENABLED(option) __or(IS_BUILTIN(option), IS_MODULE(option))
#define IS_BUILTIN(option) __is_defined(option)
#define IS_MODULE(option) __is_defined(option##_MODULE)
```

| CONFIG value | IS_BUILTIN() | IS_MODULE() | IS_ENABLED() |
|--------------|--------------|-------------|--------------|
| n (not set)  | 0 (false)    | 0 (false)   | 0 (false)    |
| y (builtin)  | 1 (true)     | 0 (false)   | 1 (true)     |
| m (module)   | 0 (false)    | 1 (true)    | 1 (true)     |

---

## Timeline Comparison

### CONFIG_ARM_SMMU_V3=n Timeline

```
TIME  EVENT
─────────────────────────────────────────────────────────
t0    System boot
      ├─ ACPI enumerates devices
      └─ _DSD parsed into adev->data.properties

t1    Device probe starts
      ├─ acpi_dma_configure_id()
      ├─ iort_iommu_configure_id()
      ├─ iort_iommu_xlate() → returns -ENODEV
      ├─ acpi_dma_configure_id() ignores -ENODEV, continues
      ├─ arch_setup_dma_ops() with iommu=NULL
      └─ Driver probe continues

t2    Driver reads properties
      ├─ device_property_read_u32(dev, "bdmax", &val)
      └─ Returns: 0 (success) or -EINVAL (not found)

t3    Driver probe completes
      └─ Device is operational (with direct DMA, no IOMMU)
```

### CONFIG_ARM_SMMU_V3=m Timeline

```
TIME  EVENT
─────────────────────────────────────────────────────────
t0    System boot
      ├─ ACPI enumerates devices
      └─ _DSD parsed into adev->data.properties

t1    Device probe starts (FIRST ATTEMPT)
      ├─ acpi_dma_configure_id()
      ├─ iort_iommu_configure_id()
      ├─ iort_iommu_xlate() → returns -EPROBE_DEFER
      ├─ acpi_dma_configure_id() returns -EPROBE_DEFER
      └─ Driver probe DEFERRED (added to deferred list)

t2    [SMMUv3 module not loaded - waiting...]

t3    arm-smmu-v3.ko loaded (modprobe)
      ├─ arm_smmu_v3_init()
      ├─ arm_smmu_v3_probe()
      ├─ iommu_device_register(&smmu->iommu)
      │   └─→ Ops registered with fwnode
      └─→ Triggers IORT replay

t4    IORT replay for deferred devices
      ├─ iort_add_device_replay(dev)
      ├─ iommu_probe_device(dev)
      └─ ops = iommu_ops_from_fwnode() → SUCCESS

t5    Device probe restarts (SECOND ATTEMPT)
      ├─ acpi_dma_configure_id()
      ├─ iort_iommu_xlate() → SUCCESS (ops valid)
      ├─ arch_setup_dma_ops() with iommu=arm_smmu_ops
      └─ Driver probe continues

t6    Driver reads properties
      ├─ device_property_read_u32(dev, "bdmax", &val)
      └─ Returns: 0 (success) or -EINVAL (not found)
         ^ Same result as CONFIG=n case!

t7    Driver probe completes
      └─ Device is operational with IOMMU
```

---

## Code Locations Reference

### ACPI Property Parsing

| File | Function | Line Range |
|------|----------|------------|
| `drivers/acpi/scan.c` | `acpi_bus_scan()` | - |
| `drivers/acpi/scan.c` | `acpi_add_single_object()` | 1570-1620 |
| `drivers/acpi/property.c` | `acpi_init_properties()` | 364-425 |
| `drivers/acpi/property.c` | `acpi_extract_properties()` | 384-413 |
| `drivers/acpi/property.c` | `acpi_data_get_property()` | 485-522 |

### IORT IOMMU Configuration

| File | Function | Line Range |
|------|----------|------------|
| `drivers/acpi/scan.c` | `acpi_dma_configure_id()` | 1461-1482 |
| `drivers/acpi/arm64/iort.c` | `iort_iommu_configure_id()` | 1025-1088 |
| `drivers/acpi/arm64/iort.c` | `iort_iommu_xlate()` | 923-950 |
| `drivers/acpi/arm64/iort.c` | `iort_iommu_driver_enabled()` | 890-901 |
| `drivers/acpi/arm64/iort.c` | `iort_get_fwnode()` | 81-97 |
| `drivers/iommu/iommu.c` | `iommu_ops_from_fwnode()` | - |

### Deferred Probe Mechanism

| File | Function | Line Range |
|------|----------|------------|
| `drivers/base/dd.c` | `driver_deferred_probe_add()` | 124-132 |
| `drivers/base/dd.c` | `driver_deferred_probe_trigger()` | 165-186 |
| `drivers/base/dd.c` | `deferred_probe_work_func()` | 75-122 |
| `drivers/base/dd.c` | `really_probe()` | 494-655 |

---

## Key Takeaways

1. **_DSD content is independent of CONFIG**
   - _DSD is parsed at boot time (`acpi_init_properties`)
   - Properties stored in `adev->data.properties` before any driver probe
   - CONFIG change does NOT affect _DSD parsing

2. **CONFIG affects PROBE ORDERING, not property content**
   - CONFIG=n: Probe continues immediately (no IOMMU)
   - CONFIG=m: Probe is deferred until SMMU driver loads
   - The bdmax read happens at different times, but reads the same data

3. **-EINVAL from property read means property is missing**
   - `acpi_data_get_property()` returns -EINVAL when property not found
   - This is a firmware issue, not a driver timing issue

4. **Probe deferral mechanism**
   - -EPROBE_DEFER causes driver probe to exit early
   - Deferred devices are retried when dependencies register
   - When arm-smmu-v3.ko loads, it triggers replay of deferred probes

5. **The property read result is the SAME in both configs**
   - If bdmax exists in _DSD: returns 0 in both cases
   - If bdmax doesn't exist in _DSD: returns -EINVAL in both cases
   - The CONFIG only changes WHEN the read happens, not WHAT it returns

---

<!--
Repository: linux
Tag: v5.10-rc7
Commit: 0477e92881850d44910a7e94fc2c46f96faa131f
Generated: 2026-03-13
-->
