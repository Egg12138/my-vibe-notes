# SMMU V3 Deferred Probe Replay Mechanism

## Table of Contents

- [Overview](#overview)
- [What is Deferred Probe?](#what-is-deferred-probe)
- [Why Deferred Probe Matters for SMMU?](#why-deferred-probe-matters-for-smmu)
- [Part 1: How Device Gets Deferred](#part-1-how-device-gets-deferred)
- [Part 2: SMMU Module Loads and Triggers Replay](#part-2-smmu-module-loads-and-triggers-replay)
- [Part 3: IOMMU Bus Notifier Triggers Device Replay](#part-3-iommu-bus-notifier-triggers-device-replay)
- [Part 4: Deferred Probe Work Function - The Replay](#part-4-deferred-probe-work-function---the-replay)
- [Complete Replay Sequence](#complete-replay-sequence)
- [Key Data Structures](#key-data-structures)
- [Debug Tips](#debug-tips)

---

## Overview

When `CONFIG_ARM_SMMU_V3=m` and a device depends on SMMU but the module isn't loaded yet, the device probe is **deferred**. When the SMMU module is later loaded, it triggers a **replay** of all deferred probes.

This document shows the actual kernel source code for this mechanism, with detailed explanations of each step.

---

## What is Deferred Probe?

**Deferred probe** is a Linux kernel mechanism that allows device drivers to postpone their initialization when a required dependency is not yet available. Instead of failing permanently, the driver is added to a **deferred probe list** and retried later.

### Why Deferred Probe Exists

Modern systems have complex device dependencies:
- A network controller needs its PHY to be ready
- A PCIe endpoint needs the root complex initialized
- A device needs its IOMMU (SMMU) to be available for DMA

Deferred probe solves the **probe ordering problem** without hardcoding initcall order.

---

## Why Deferred Probe Matters for SMMU?

When SMMU is built as a module (`CONFIG_ARM_SMMU_V3=m`):

1. **Module not loaded at boot** - SMMU driver is not available during early boot
2. **Devices need IOMMU** - Devices described in IORT/Device Tree need SMMU for DMA
3. **Probe must wait** - Device drivers return `-EPROBE_DEFER` until SMMU is ready
4. **Automatic replay** - When SMMU module loads, all deferred devices are retried

This ensures devices work correctly regardless of when the SMMU module is loaded.

---

## Part 1: How Device Gets Deferred

### 1.1 Driver Probe Returns -EPROBE_DEFER

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

    iort_dma_setup(dev, &dma_addr, &size);

    iommu = iort_iommu_configure_id(dev, input_id);
    //    ^^^^^^^^^^^^^^^^^^^^^^^^^^^^
    //    Returns ERR_PTR(-EPROBE_DEFER) when SMMU not ready

    // KEY CHECK: If IOMMU configuration returned -EPROBE_DEFER, propagate it
    if (PTR_ERR(iommu) == -EPROBE_DEFER)
        return -EPROBE_DEFER;  // ← DEFER HERE!

    arch_setup_dma_ops(dev, dma_addr, size,
                       iommu, attr == DEV_DMA_COHERENT);

    return 0;
}
```

### 1.2 Driver Probe Function Returns -EPROBE_DEFER

```c
// [drivers/base/dd.c:494-655]

static int really_probe(struct device *dev, struct device_driver *drv)
{
    int ret = -EPROBE_DEFER;
    int local_trigger_count = atomic_read(&deferred_trigger_count);

    // ... link checking ...

re_probe:
    dev->driver = drv;

    // Call DMA configure which may return -EPROBE_DEFER
    if (dev->bus->dma_configure) {
        ret = dev->bus->dma_configure(dev);  // ← Calls acpi_dma_configure_id
        if (ret)
            goto probe_failed;  // ret = -EPROBE_DEFER
    }

    // ... sysfs, pm_domain, probe calls ...

    if (dev->bus->probe) {
        ret = dev->bus->probe(dev);
        if (ret)
            goto probe_failed;
    } else if (drv->probe) {
        ret = drv->probe(dev);
        if (ret)
            goto probe_failed;
    }

    // ... success path ...

probe_failed:
    if (ret == -EPROBE_DEFER)
        driver_deferred_probe_add_trigger(dev, local_trigger_count);
        // ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
        // ADD TO DEFERRED LIST
    // ... error handling ...
}
```

### 1.3 Device Added to Deferred List

```c
// [drivers/base/dd.c:124-144]

void driver_deferred_probe_add(struct device *dev)
{
    mutex_lock(&deferred_probe_mutex);
    if (list_empty(&dev->p->deferred_probe)) {
        dev_dbg(dev, "Added to deferred list\n");
        list_add_tail(&dev->p->deferred_probe, &deferred_probe_pending_list);
        //                                                    ^^^^^^^^^^^^^^^^^^^^^
        //                                                    Device queued here!
    }
    mutex_unlock(&deferred_probe_mutex);
}
```

### Deferred List Data Structures

```c
// [drivers/base/dd.c]

static LIST_HEAD(deferred_probe_pending_list);   // Devices waiting to be retried
static LIST_HEAD(deferred_probe_active_list);     // Devices currently being retried
static DEFINE_MUTEX(deferred_probe_mutex);
```

### Deferred Probe Flow Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                    DEFERRED PROBE ADD                       │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  your_driver_probe()                                        │
│    │                                                        │
│    └─→ dev->bus->dma_configure(dev)                        │
│        │                                                    │
│        └─→ acpi_dma_configure_id()                         │
│            │                                                │
│            └─→ iort_iommu_configure_id()                   │
│                │                                            │
│                └─→ iort_iommu_xlate()                      │
│                    │                                        │
│                    ├─→ ops = iommu_ops_from_fwnode()       │
│                    │   └─→ returns NULL (SMMU not ready)   │
│                    │                                        │
│                    └─→ return -EPROBE_DEFER                │
│                        (because IS_ENABLED(CONFIG=y/m))    │
│                                                            │
│  really_probe()                                            │
│    │                                                        │
│    └─→ if (ret == -EPROBE_DEFER)                          │
│        └─→ driver_deferred_probe_add(dev)                 │
│            └─→ list_add_tail(dev->p->deferred_probe,      │
│                             &deferred_probe_pending_list)  │
│                                                            │
│  Result: Device is in deferred_probe_pending_list          │
│                                                            │
└─────────────────────────────────────────────────────────────┘
```

---

## Part 2: SMMU Module Loads and Triggers Replay

### 2.1 SMMU Driver Module Init

```c
// [drivers/iommu/arm/arm-smmu-v3/arm-smmu-v3.c]

static int __init arm_smmu_v3_init(void)
{
    return pci_register_driver(&arm_smmu_v3_driver);
    // Or platform_driver_register() for platform devices
}
module_init(arm_smmu_v3_init);
```

### 2.2 SMMU Device Probe

```c
// [drivers/iommu/arm/arm-smmu-v3/arm-smmu-v3.c]

static int arm_smmu_v3_probe(struct platform_device *pdev)
{
    struct arm_smmu_device *smmu;

    smmu = devm_kzalloc(dev, sizeof(*smmu), GFP_KERNEL);

    // Parse resources, initialize queues, etc.

    // KEY: Register IOMMU device - this triggers replay!
    ret = iommu_device_register(&smmu->iommu);

    return 0;
}
```

### 2.3 IOMMU Device Registration

```c
// [drivers/iommu/iommu.c:153-160]

int iommu_device_register(struct iommu_device *iommu)
{
    spin_lock(&iommu_device_lock);
    list_add_tail(&iommu->list, &iommu_device_list);
    //                         ^^^^^^^^^^^^^^^^^^^
    //                         Add to global IOMMU device list
    spin_unlock(&iommu_device_lock);
    return 0;
}
EXPORT_SYMBOL_GPL(iommu_device_register);
```

### Side Note: bus_set_iommu() (Alternative Path)

Some IOMMU drivers also call `bus_set_iommu()` which triggers a more comprehensive probe:

```c
// [drivers/iommu/iommu.c:1741-1783]

int bus_iommu_probe(struct bus_type *bus)
{
    struct iommu_group *group, *next;
    LIST_HEAD(group_list);
    int ret;

    // Probe all devices on this bus for IOMMU
    ret = bus_for_each_dev(bus, NULL, &group_list, probe_iommu_group);
    //     ^^^^^^^^^^^^^^^
    //     This iterates ALL devices on the bus!

    list_for_each_entry_safe(group, next, &group_list, entry) {
        list_del_init(&group->entry);
        mutex_lock(&group->mutex);

        probe_alloc_default_domain(bus, group);

        if (!group->default_domain) {
            mutex_unlock(&group->mutex);
            continue;
        }

        iommu_group_create_direct_mappings(group);

        ret = __iommu_group_dma_attach(group);

        mutex_unlock(&group->mutex);

        if (ret)
            break;

        __iommu_group_dma_finalize(group);
    }

    return ret;
}
```

---

## Part 3: IOMMU Bus Notifier Triggers Device Replay

### 3.1 IOMMU Bus Notifier

```c
// [drivers/iommu/iommu.c:1591-1610]

static int iommu_bus_notifier(struct notifier_block *nb,
                              unsigned long action, void *data)
{
    unsigned long group_action = 0;
    struct device *dev = data;
    struct iommu_group *group;

    /*
     * ADD/DEL call into iommu driver ops if provided, which may
     * result in ADD/DEL notifiers to group->notifier
     */
    if (action == BUS_NOTIFY_ADD_DEVICE) {
        int ret;

        // KEY: Probe this device for IOMMU!
        ret = iommu_probe_device(dev);
        //    ^^^^^^^^^^^^^^^^^^^^
        //    This is where deferred devices get replayed!

        return (ret) ? NOTIFY_DONE : NOTIFY_OK;
    } else if (action == BUS_NOTIFY_REMOVED_DEVICE) {
        iommu_release_device(dev);
        return NOTIFY_OK;
    }

    // ... other actions ...
}
```

### 3.2 IOMMU Probe Device

```c
// [drivers/iommu/iommu.c:245-285]

int iommu_probe_device(struct device *dev)
{
    const struct iommu_ops *ops = dev->bus->iommu_ops;
    struct iommu_group *group;
    int ret;

    // Probe the device and attach to IOMMU
    ret = __iommu_probe_device(dev, NULL);
    if (ret)
        goto err_out;

    group = iommu_group_get(dev);
    if (!group)
        goto err_release;

    // Try to allocate default domain
    iommu_alloc_default_domain(group, dev);

    if (group->default_domain) {
        ret = __iommu_attach_device(group->default_domain, dev);
        if (ret) {
            iommu_group_put(group);
            goto err_release;
        }
    }

    iommu_create_device_direct_mappings(group, dev);

    iommu_group_put(group);

    if (ops->probe_finalize)
        ops->probe_finalize(dev);

    return 0;

err_release:
    iommu_release_device(dev);
err_out:
    return ret;
}
```

### 3.3 __iommu_probe_device - Gets IOMMU Ops

```c
// [drivers/iommu/iommu.c]

int __iommu_probe_device(struct device *dev, void *data)
{
    const struct iommu_ops *ops = NULL;
    struct iommu_device *iommu_dev;
    int ret;

    // Get fwnode
    if (!dev->fwnode)
        return -ENODEV;

    // Find IOMMU ops from fwnode
    ops = iommu_ops_from_fwnode(dev->fwnode);
    //   ^^^^^^^^^^^^^^^^^^^^^^^^^^^^
    //   NOW SUCCEEDS because SMMU registered its ops!

    if (!ops)
        return -ENODEV;

    if (!ops->probe_device)
        return -ENODEV;

    // Call IOMMU driver's probe_device
    group = ops->probe_device(dev);
    if (IS_ERR(group))
        return PTR_ERR(group);

    // ... attach to group ...

    return 0;
}
```

### iommu_ops_from_fwnode - Now Finds SMMU Ops

```c
// [drivers/iommu/iommu.c]

const struct iommu_ops *iommu_ops_from_fwnode(struct fwnode_handle *fwnode)
{
    struct iommu_device *iommu;

    // Check cache first
    iommu = fwnode_iommu_ops_cache_get(fwnode);
    if (iommu)
        return iommu->ops;

    // Search global IOMMU device list
    spin_lock(&iommu_device_lock);

    list_for_each_entry(iommu, &iommu_device_list, list) {
        //    ^^^^^^^^^^^^^^^^^^^^^^^^
        //    Iterate through all registered IOMMUs
        //    (including the newly loaded SMMUv3!)

        if (iommu->fwnode == fwnode) {
            spin_unlock(&iommu_device_lock);
            return iommu->ops;  // ← FOUND!
            //                    Returns arm_smmu_ops
        }
    }

    spin_unlock(&iommu_device_lock);
    return NULL;
}
```

---

## Part 4: Deferred Probe Work Function - The Replay

### 4.1 Trigger Point - Driver Bound

```c
// [drivers/base/dd.c:357-385]

static void driver_bound(struct device *dev)
{
    if (device_is_bound(dev)) {
        pr_warn("%s: device %s already bound\n",
                __func__, kobject_name(&dev->kobj));
        return;
    }

    pr_debug("driver: '%s': %s: bound to device '%s'\n", dev->driver->name,
             __func__, dev_name(dev));

    klist_add_tail(&dev->p->knode_driver, &dev->driver->p->klist_devices);
    device_links_driver_bound(dev);

    device_pm_check_callbacks(dev);

    /*
     * Make sure the device is no longer in one of the deferred lists and
     * kick off retrying all pending devices
     */
    driver_deferred_probe_del(dev);
    driver_deferred_probe_trigger();
    // ^^^^^^^^^^^^^^^^^^^^^^^^
    // TRIGGER REPLAY OF ALL DEFERRED DEVICES!

    if (dev->bus)
        blocking_notifier_call_chain(&dev->bus->p->bus_notifier,
                                     BUS_NOTIFY_BOUND_DRIVER, dev);

    kobject_uevent(&dev->kobj, KOBJ_BIND);
}
```

**This is called whenever ANY driver successfully binds to a device, including the SMMU driver!**

### 4.2 Deferred Probe Trigger

```c
// [drivers/base/dd.c:165-186]

static void driver_deferred_probe_trigger(void)
{
    if (!driver_deferred_probe_enable)
        return;

    /*
     * A successful probe means that all the devices in the pending list
     * should be triggered to be reprobed. Move all the deferred devices
     * into the active list so they can be retried by the workqueue
     */
    mutex_lock(&deferred_probe_mutex);
    atomic_inc(&deferred_trigger_count);
    list_splice_tail_init(&deferred_probe_pending_list,
                          &deferred_probe_active_list);
    //  ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
    //  Move all pending devices to active list
    mutex_unlock(&deferred_probe_mutex);

    /*
     * Kick the re-probe thread. It may already be scheduled, but it is
     * safe to kick it again.
     */
    schedule_work(&deferred_probe_work);
    // ^^^^^^^^^^^^^^^^^^^^^^^^
    // Schedule work function to replay probes!
}
```

### 4.3 Deferred Probe Work Function - THE REPLAY

```c
// [drivers/base/dd.c:75-122]

static void deferred_probe_work_func(struct work_struct *work)
{
    struct device *dev;
    struct device_private *private;

    /*
     * This block processes every device in the deferred 'active' list.
     * Each device is removed from the active list and passed to
     * bus_probe_device() to re-attempt the probe.
     */
    mutex_lock(&deferred_probe_mutex);

    while (!list_empty(&deferred_probe_active_list)) {
        //          ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
        //          Process all deferred devices!

        private = list_first_entry(&deferred_probe_active_list,
                                   typeof(*dev->p), deferred_probe);
        dev = private->device;
        list_del_init(&private->deferred_probe);
        //  ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
        //  Remove from deferred list

        get_device(dev);

        /*
         * Drop the mutex while probing each device; the probe path may
         * manipulate the deferred list
         */
        mutex_unlock(&deferred_probe_mutex);

        /*
         * Force the device to the end of the dpm_list since
         * the PM code assumes that the order we add things to
         * the list is a good order for suspend but deferred
         * probe makes that very unsafe.
         */
        device_pm_move_to_tail(dev);

        dev_dbg(dev, "Retrying from deferred list\n");
        bus_probe_device(dev);
        // ^^^^^^^^^^^^^^^^^^^^
        // RE-ATTEMPT PROBE!
        // This will call:
        //   → __device_attach()
        //     → driver_probe_device()
        //       → really_probe()
        //         → dev->bus->dma_configure()
        //           → acpi_dma_configure_id()
        //             → iort_iommu_configure_id()
        //               → iort_iommu_xlate()
        //                 → ops = iommu_ops_from_fwnode()  ← NOW SUCCEEDS!

        mutex_lock(&deferred_probe_mutex);

        put_device(dev);
    }

    mutex_unlock(&deferred_probe_mutex);
}
static DECLARE_WORK(deferred_probe_work, deferred_probe_work_func);
```

---

## Complete Replay Sequence

```
┌─────────────────────────────────────────────────────────────────────────┐
│                    DEFERRED PROBE REPLAY SEQUENCE                       │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  PHASE 1: INITIAL DEFER (SMMU not loaded)                               │
│  ────────────────────────────────────────                               │
│                                                                         │
│  your_driver_probe()                                                    │
│    └─→ acpi_dma_configure_id()                                          │
│        └─→ iort_iommu_configure_id()                                    │
│            └─→ iort_iommu_xlate()                                       │
│                └─→ return -EPROBE_DEFER  (ops = NULL, CONFIG enabled)   │
│        └─→ return -EPROBE_DEFER                                        │
│    └─→ return -EPROBE_DEFER                                            │
│                                                                         │
│  really_probe()                                                         │
│    └─→ driver_deferred_probe_add(dev)                                  │
│        └─→ list_add_tail(dev->p->deferred_probe,                       │
│                         &deferred_probe_pending_list)                   │
│                                                                         │
│  Result: Device is in deferred_probe_pending_list                      │
│                                                                         │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  PHASE 2: SMMU MODULE LOADS                                            │
│  ─────────────────────────                                             │
│                                                                         │
│  modprobe arm-smmu-v3                                                   │
│    └─→ arm_smmu_v3_init()                                              │
│        └─→ pci_register_driver(&arm_smmu_v3_driver)                    │
│                                                                         │
│  Platform device registers (SMMU device itself)                        │
│    └─→ arm_smmu_v3_probe(pdev)                                         │
│        └─→ arm_smmu_device_probe(smmu)                                  │
│            └─→ iommu_device_register(&smmu->iommu)                     │
│                └─→ list_add_tail(&iommu->list,                         │
│                                 &iommu_device_list)                    │
│                                                                         │
│  SMMU driver bound to SMMU device                                       │
│    └─→ driver_bound(smmu_device)                                       │
│        └─→ driver_deferred_probe_trigger()                             │
│            └─→ list_splice_tail_init(&deferred_probe_pending_list,     │
│                                     &deferred_probe_active_list)        │
│            └─→ schedule_work(&deferred_probe_work)                     │
│                                                                         │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  PHASE 3: REPLAY (Work Queue Executes)                                 │
│  ─────────────────────────────────────                                 │
│                                                                         │
│  deferred_probe_work_func()                                             │
│    └─→ while (!list_empty(&deferred_probe_active_list))                │
│        │                                                                │
│        ├─→ dev = get first deferred device                              │
│        ├─→ list_del_init(&dev->p->deferred_probe)                       │
│        │                                                                │
│        ├─→ bus_probe_device(dev)  ← RE-ATTEMPT PROBE!                  │
│        │    │                                                           │
│        │    └─→ __device_attach()                                       │
│        │        └─→ driver_probe_device(drv, dev)                       │
│        │            └─→ really_probe(dev, drv)  ← SECOND CALL          │
│        │                │                                                │
│        │                └─→ dev->bus->dma_configure(dev)                │
│        │                    │                                           │
│        │                    └─→ acpi_dma_configure_id(dev, attr, id)    │
│        │                        │                                       │
│        │                        ├─→ iort_dma_setup(...)                  │
│        │                        │                                       │
│        │                        └─→ iommu = iort_iommu_configure_id()   │
│        │                            │                                   │
│        │                            └─→ iort_iommu_xlate()             │
│        │                                │                               │
│        │                                ├─→ ops = iommu_ops_from_fwnode()│
│        │                                │   │                          │
│        │                                │   └─→ list_for_each_entry(iommu,│
│        │                                │            &iommu_device_list,  │
│        │                                │            list)               │
│        │                                │       │                      │
│        │                                │       └─→ if (iommu->fwnode == │
│        │                                │               fwnode)          │
│        │                                │           └─→ return iommu->ops│
│        │                                │               ;  ← SUCCESS!  │
│        │                                │                              │
│        │                                ├─→ if (!ops)  ← FALSE!       │
│        │                                │                              │
│        │                                └─→ return arm_smmu_iort_xlate()│
│        │                                    └─→ return 0;  ← SUCCESS │
│        │                            │                                   │
│        │                            └─→ return ops;  ← valid pointer  │
│        │                        │                                       │
│        │                        ├─→ if (PTR_ERR(iommu) == -EPROBE_DEFER)│
│        │                        │   └─→ [SKIP - iommu is valid!]        │
│        │                        │                                       │
│        │                        └─→ arch_setup_dma_ops(dev, ..., iommu) │
│        │                            └─→ Configure IOMMU DMA ops        │
│        │                                                                │
│        └─→ [Continue with rest of driver probe...]                     │
│            └─→ device_property_read_u32(dev, "bdmax", &val)           │
│                └─→ Now executes with IOMMU configured!                 │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
```

---

## Key Data Structures

### Deferred Probe Lists

```c
// [drivers/base/dd.c]

// Devices waiting to be probed (newly deferred)
static LIST_HEAD(deferred_probe_pending_list);

// Devices currently being probed (active retry)
static LIST_HEAD(deferred_probe_active_list);

// Protects deferred probe lists
static DEFINE_MUTEX(deferred_probe_mutex);

// Work queue for deferred probe processing
static DECLARE_WORK(deferred_probe_work, deferred_probe_work_func);

// Enable deferred probe mechanism (set at late_initcall)
static bool driver_deferred_probe_enable = false;
```

### IOMMU Device List

```c
// [drivers/iommu/iommu.c]

// Global list of all registered IOMMU devices
static LIST_HEAD(iommu_device_list);
static DEFINE_SPINLOCK(iommu_device_lock);
```

### Device Private Structure

```c
// [include/linux/device_private.h]

struct device_private {
    struct device *device;
    struct list_head deferred_probe;  // ← Node in deferred probe list
    char *deferred_probe_reason;
    // ...
};
```

---

## Debug Tips

### Check Deferred Devices

```bash
# Check which devices are deferred
cat /sys/kernel/debug/devices_deferred

# Or use dmesg
dmesg | grep "Added to deferred list"
dmesg | grep "Retrying from deferred list"
```

### Check IOMMU Device List

```bash
# Check registered IOMMU devices
cat /sys/kernel/iommu_groups/*

# Check which devices are in IOMMU groups
ls -R /sys/kernel/iommu_groups/
```

### Enable Deferred Probe Debug

```bash
# Enable deferred probe debug messages
echo 8 > /proc/sys/kernel/printk
# or add to kernel command line: loglevel=8
```

---

## Timeline Summary

| Time | Event |
|------|-------|
| t0 | System boot, drivers probe |
| t1 | Consumer driver probes, returns -EPROBE_DEFER, added to `deferred_probe_pending_list` |
| t2 | `modprobe arm-smmu-v3` |
| t3 | SMMU driver probes, calls `iommu_device_register()` |
| t4 | SMMU driver binds, `driver_bound()` calls `driver_deferred_probe_trigger()` |
| t5 | Devices moved from `deferred_probe_pending_list` to `deferred_probe_active_list` |
| t6 | Work queue scheduled: `schedule_work(&deferred_probe_work)` |
| t7 | `deferred_probe_work_func()` executes |
| t8 | Each deferred device replayed via `bus_probe_device()` |
| t9 | Consumer driver probes again, `iommu_ops_from_fwnode()` succeeds |
| t10 | Consumer driver completes probe successfully |

---

## Critical Code Paths Summary

### When Driver Returns -EPROBE_DEFER

```c
really_probe()
    ├─→ dev->bus->dma_configure(dev)
    │   └─→ acpi_dma_configure_id()
    │       └─→ iommu = iort_iommu_configure_id()
    │           └─→ return ERR_PTR(-EPROBE_DEFER)
    ├─→ if (ret == -EPROBE_DEFER)
    │   └─→ driver_deferred_probe_add_trigger(dev, count)
    │       └─→ driver_deferred_probe_add(dev)
    │           └─→ list_add_tail(dev->p->deferred_probe,
    │                            &deferred_probe_pending_list)
```

### When SMMU Loads and Triggers Replay

```c
arm_smmu_v3_probe()
    └─→ iommu_device_register(&smmu->iommu)
        └─→ list_add_tail(&iommu->list, &iommu_device_list)

SMMU driver binds
    └─→ driver_bound(smmu_device)
        └─→ driver_deferred_probe_trigger()
            ├─→ list_splice_tail_init(&deferred_probe_pending_list,
            │                      &deferred_probe_active_list)
            └─→ schedule_work(&deferred_probe_work)
```

### The Replay (Work Function)

```c
deferred_probe_work_func()
    └─→ while (!list_empty(&deferred_probe_active_list))
        ├─→ dev = first_entry(deferred_probe_active_list)
        ├─→ list_del_init(&dev->p->deferred_probe)
        └─→ bus_probe_device(dev)
            └─→ __device_attach()
                └─→ really_probe()  ← SECOND ATTEMPT
                    └─→ This time iommu_ops_from_fwnode() finds SMMU ops!
```

---

## Key Takeaway

**The replay happens through TWO mechanisms:**

1. **Primary: `driver_deferred_probe_trigger()`** - Called when ANY driver successfully binds (including SMMU driver). This moves all deferred devices to active list and schedules work function.

2. **Secondary: `iommu_bus_notifier()`** - Bus notifier that calls `iommu_probe_device()` when `BUS_NOTIFY_ADD_DEVICE` event occurs. This can also trigger device probing for IOMMU.

Both mechanisms work together to ensure deferred devices get replayed when their dependencies (like SMMU) become available.

---

<!--
Repository: linux
Tag: v5.10-rc7
Commit: 0477e92881850d44910a7e94fc2c46f96faa131f
Generated: 2026-03-13
-->
