# PCIe BAR (Base Address Register) — 从零开始理解

> 适用于：PCIe 初学者 / Linux kernel 驱动开发者
> 目标：深入浅出讲清楚 BAR 是什么、怎么用、kernel 里怎么玩的

## [toc]

- [PCIe BAR (Base Address Register) — 从零开始理解](#pcie-bar-base-address-register--从零开始理解)
  - [1. 一句话概括](#1-一句话概括)
  - [2. 硬件上的 BAR 在哪里？](#2-硬件上的-bar-在哪里)
  - [3. BAR 寄存器的位布局](#3-bar-寄存器的位布局)
  - [4. BAR 最巧妙的设计：探测大小 (Sizing)](#4-bar-最巧妙的设计探测大小-sizing)
    - [原理比喻](#原理比喻)
    - [Kernel 代码：`__pci_size_bars()`](#kernel-代码__pci_size_bars)
    - [`pci_size()` 算出实际大小](#pci_size-算出实际大小)
  - [5. Kernel 完整执行流（核心！）](#5-kernel-完整执行流核心)
    - [第①层：枚举与初始化](#第①层枚举与初始化)
    - [第②层：资源分配](#第②层资源分配)
    - [第③层：驱动使用](#第③层驱动使用)
  - [6. 关键数据结构](#6-关键数据结构)
    - [`struct resource`](#struct-resource)
    - [`struct pci_dev` 中的 `resource[]` 数组](#struct-pci_dev-中的-resource-数组)
    - [驱动常用的宏](#驱动常用的宏)
  - [7. 实战：驱动怎么用 BAR？](#7-实战驱动怎么用-bar)
    - [标准模板](#标准模板)
    - [图解 CPU 如何访问 PCIe 设备](#图解-cpu-如何访问-pcie-设备)
  - [8. 灵魂追问](#8-灵魂追问)
  - [9. 附录：关键源码文件](#9-附录关键源码文件)

---

## 1. 一句话概括

**BAR 就是 PCIe 设备的"地址登记处"。**

每个 PCIe 设备想让 CPU 访问它的内部功能（比如网卡发 packet、显卡读写显存），就必须通过 BAR 向系统声明：

> **"我需要 XX 大小的地址空间，里面是 MMIO 寄存器 / 设备内存，你把 CPU 地址映射过来。"**

---

## 2. 硬件上的 BAR 在哪里？

每个 PCIe 设备在它的 **配置空间 (Configuration Space)** 里，从偏移 `0x10` 开始有 6 个 32 位寄存器，编号 BAR0 ~ BAR5：

```c
// include/uapi/linux/pci_regs.h
#define PCI_BASE_ADDRESS_0      0x10    /* 32 bits */
#define PCI_BASE_ADDRESS_1      0x14
#define PCI_BASE_ADDRESS_2      0x18
#define PCI_BASE_ADDRESS_3      0x1c
#define PCI_BASE_ADDRESS_4      0x20
#define PCI_BASE_ADDRESS_5      0x24
```

> 如果设备需要 **64 位地址空间**，会占用两个连续的 BAR（如 BAR0+BAR1 拼成一个 64 位寄存器）。

---

## 3. BAR 寄存器的位布局

一个 32 位的 BAR 寄存器：

```
 31                              4  3  2  1  0
┌─────────────────────────────────┬──┬──┬──┬──┐
│        Base Address             │P │Ty│  │Sp│
│       (地址基址)                │f │pe│  │  │
└─────────────────────────────────┴──┴──┴──┴──┘
                                    │  │   │
                                    │  │   └─ bit 0: Space 类型
                                    │  │       0 = Memory Space (内存空间)
                                    │  │       1 = I/O Space (I/O 空间)
                                    │  └─── bits 1-2: 地址宽度 (Memory Type)
                                    │        00 = 32 位
                                    │        01 = 保留 (曾用于 1MB 以下)
                                    │        10 = 64 位
                                    │        11 = 保留
                                    └──── bit 3: Prefetchable (可预取)
                                            0 = 不可预取
                                            1 = 可预取
```

Kernel 中的位定义：

```c
#define PCI_BASE_ADDRESS_SPACE         0x01    // bit 0: 空间类型
#define PCI_BASE_ADDRESS_SPACE_IO      0x01
#define PCI_BASE_ADDRESS_SPACE_MEMORY  0x00
#define PCI_BASE_ADDRESS_MEM_TYPE_MASK 0x06    // bits 1-2
#define PCI_BASE_ADDRESS_MEM_TYPE_32   0x00    // 32位
#define PCI_BASE_ADDRESS_MEM_TYPE_64   0x04    // 64位
#define PCI_BASE_ADDRESS_MEM_PREFETCH  0x08    // bit 3: 预取标记
#define PCI_BASE_ADDRESS_MEM_MASK     (~0x0fUL)  // 地址部分掩码
#define PCI_BASE_ADDRESS_IO_MASK      (~0x03UL)  // I/O 地址掩码
```

> **什么是 Prefetchable？**
> 可预取表示读这个地址没有副作用（side-effect），CPU 可以提前预读、合并写。寄存器通常是**不可预取**的（读一次清一次中断状态）。

---

## 4. BAR 最巧妙的设计：探测大小 (Sizing)

### 原理比喻

> 就像你在停车位前放了一排雪糕筒，管理员想知道每个筒占多宽。他**把所有筒推到最左边**，再看最右边空了多少 —— 空出来的就是筒本身的宽度。

硬件步骤：

1. **保存原始值** → 读 BAR 寄存器
2. **写入全 1**（`0xFFFFFFFF`） → 写 BAR
3. **读回** → 读 BAR
4. **恢复原始值** → 写回原值

**为什么这样能知道大小？** 因为 BAR 寄存器中"可编程"的位（低位）是可以被写入的，"硬连线"的位（高位）永远读回 0。写全 1 后读回来，低 N 位是 1，高位是 0 —— 说明地址空间大小是 `2^N`。

**举例：** 某个设备需要 1MB（2^20）空间：

- 写 `0xFFFFFFFF`
- 读回 `0xFFF00000`（低 20 位是 1，高 12 位是 0）
- 取最低的 1 所在位置 → `0x00100000` = 1MB

### Kernel 代码：`__pci_size_bars()`

```c
// drivers/pci/probe.c
static void __pci_size_bars(struct pci_dev *dev, int count,
                            unsigned int pos, u32 *sizes, bool rom)
{
    u32 orig, mask = rom ? PCI_ROM_ADDRESS_MASK : ~0;
    for (i = 0; i < count; i++, pos += 4, sizes++) {
        pci_read_config_dword(dev, pos, &orig);    // ① 保存
        pci_write_config_dword(dev, pos, mask);    // ② 写全1
        pci_read_config_dword(dev, pos, sizes);    // ③ 读回
        pci_write_config_dword(dev, pos, orig);    // ④ 恢复
    }
}
```

### `pci_size()` 算出实际大小

```c
static u64 pci_size(u64 base, u64 maxbase, u64 mask)
{
    u64 size = mask & maxbase;       // 取回读到的值（有效位）
    if (!size)
        return 0;
    size = size & ~(size-1);         // 取最低的置1位 → 就是大小！
    if (base == maxbase && ((base | (size - 1)) & mask) != mask)
        return 0;                    // 一致性校验
    return size;
}
```

---

## 5. Kernel 完整执行流（核心！）

### 第①层：枚举与初始化

```
启动 (BIOS/UEFI 或 Kernel 自身)
  │
  ▼
pci_read_bases(dev, PCI_STD_NUM_BARS, PCI_ROM_ADDRESS)    ← probe.c:2117
  │
  ├── 禁用设备 decode（防止探测时误响应）
  ├── __pci_size_stdbars() → 对所有 BAR 写全1，读出大小
  ├── 恢复 decode
  │
  └── for each BAR (0~5):
        __pci_read_base()                                    ← probe.c:201
          ├── decode_bar() → 解析类型（32/64位/I/O/可预取）
          ├── pci_size()    → 算出大小
          ├── 填充 struct resource {start, end, flags}
          └── pcibios_bus_to_resource() → 总线地址转 CPU 物理地址
```

最终结果存放在：

```c
dev->resource[0] = { start=0xFE800000, end=0xFE8FFFFF, flags=IORESOURCE_MEM }
dev->resource[1] = { start=0xFE900000, end=0xFE900FFF, flags=IORESOURCE_MEM }
...
```

### 第②层：资源分配

```
pci_assign_resource(dev, resno)                            ← setup-res.c:364
  │
  └── _pci_assign_resource()
        └── __pci_assign_resource()
              └── pci_bus_alloc_resource()                  ← bus.c:264
                    ├── 匹配 Prefetchable / 非Prefetchable窗口
                    └── allocate_resource() → 从父总线地址空间找空闲区间
                          → 找到后更新 res->start, res->end
                          → pci_update_resource()            ← setup-res.c:128
                              └── pci_write_config_dword(dev, BAR_reg, new_addr)
                                    → 真正写入硬件 BAR 寄存器！
```

分配优先级（`__pci_assign_resource`）：

1. **优先**：64 位可预取窗口（`IORESOURCE_PREFETCH | IORESOURCE_MEM_64`）
2. **次优**：32 位可预取窗口（仅当资源本身也是 64 位可预取时）
3. **兜底**：非可预取窗口（任何内存资源都能放）

### 第③层：驱动使用

```
驱动 probe:
  │
  ├── pci_enable_device(dev)     → 设置 PCI_COMMAND 的 Memory/I/O 位
  ├── pci_request_region(dev, 0) → 声明占用 BAR0 的地址区间
  │
  ├── phys = pci_resource_start(dev, 0)   → 拿 BAR 的物理地址
  ├── size = resource_size(&dev->resource[0])
  │
  └── regs = ioremap(phys, size)          → 物理地址→内核虚拟地址
        │
        ├── val = readl(regs + offset)    ← 读设备寄存器
        └── writel(val, regs + offset)    → 写设备寄存器
```

---

## 6. 关键数据结构

### `struct resource`

这是 kernel **资源管理**的核心结构，不光是 PCI 用，整个系统的地址空间都用它管理：

```c
// include/linux/ioport.h
struct resource {
    resource_size_t start;            // 起始物理地址
    resource_size_t end;              // 结束物理地址 (start + size - 1)
    const char *name;                 // 资源名
    unsigned long flags;              // 类型标记
    unsigned long desc;
    struct resource *parent, *sibling, *child;  // 树形层级结构
};
```

`flags` 关键值：

| 标志 | 含义 |
| ------ | ------ |
| `IORESOURCE_MEM` | 内存空间 (0x00000200) |
| `IORESOURCE_IO` | I/O 空间 |
| `IORESOURCE_MEM_64` | 64 位地址 (0x00100000) |
| `IORESOURCE_PREFETCH` | 可预取 |
| `IORESOURCE_UNSET` | 尚未分配有效地址 |
| `IORESOURCE_DISABLED` | 已禁用 |
| `IORESOURCE_PCI_FIXED` | 不可移动（FW 固定分配） |

### `struct pci_dev` 中的 `resource[]` 数组

```c
struct pci_dev {
    ...
    struct resource resource[DEVICE_COUNT_RESOURCE]; /* BAR 资源数组 */
    ...
};
```

数组索引约定：

```c
enum {
    PCI_STD_RESOURCES,          // 0
    PCI_STD_RESOURCE_END = PCI_STD_RESOURCES + PCI_STD_NUM_BARS - 1,  // 5 (BAR0~5)
    
    PCI_ROM_RESOURCE,           // 6 (扩展ROM)
    
#ifdef CONFIG_PCI_IOV
    PCI_IOV_RESOURCES,          // 7+ (SR-IOV 虚拟功能 BAR)
    PCI_IOV_RESOURCE_END = PCI_IOV_RESOURCES + PCI_SRIOV_NUM_BARS - 1,
#endif
};
```

### 驱动常用的宏

```c
#define pci_resource_n(dev, bar)        (&(dev)->resource[(bar)])
#define pci_resource_start(dev, bar)    (pci_resource_n(dev, bar)->start)
#define pci_resource_end(dev, bar)      (pci_resource_n(dev, bar)->end)
#define pci_resource_flags(dev, bar)    (pci_resource_n(dev, bar)->flags)

// 资源大小
resource_size_t size = resource_size(&dev->resource[bar]);
```

---

## 7. 实战：驱动怎么用 BAR？

### 标准模板

```c
static int my_pci_probe(struct pci_dev *dev, const struct pci_device_id *id)
{
    int ret;
    void __iomem *regs;

    // 1. 使能设备
    ret = pci_enable_device(dev);
    if (ret) return ret;

    // 2. 请求 BAR 0 资源
    ret = pci_request_region(dev, 0, "mydevice");
    if (ret) goto err_disable;

    // 3. 获取 BAR 0 的物理地址和大小
    unsigned long phys = pci_resource_start(dev, 0);
    unsigned long size = resource_size(&dev->resource[0]);
    unsigned long flags = pci_resource_flags(dev, 0);

    dev_info(&dev->dev, "BAR0: phys=%#lx size=%#lx flags=%#lx\n",
             phys, size, flags);

    // 4. 映射到内核虚拟地址空间
    regs = ioremap(phys, size);
    if (!regs) goto err_release;

    // 5. 使用 ioread32/iowrite32 访问设备寄存器
    u32 id = ioread32(regs + 0x00);    // 读设备 ID 寄存器
    iowrite32(0x1, regs + 0x10);       // 使能设备

    dev_set_drvdata(&dev->dev, regs);
    return 0;

err_release:
    pci_release_region(dev, 0);
err_disable:
    pci_disable_device(dev);
    return -ENOMEM;
}

static void my_pci_remove(struct pci_dev *dev)
{
    void __iomem *regs = dev_get_drvdata(&dev->dev);
    iounmap(regs);                     // 解映射
    pci_release_region(dev, 0);        // 释放资源
    pci_disable_device(dev);           // 禁用设备
}
```

### 图解 CPU 如何访问 PCIe 设备

```
CPU 核心
   │
   ▼ 虚拟地址 (ioremap 后的地址)
   ┌──────────────────┐
   │  MMU 页表        │
   └──────┬───────────┘
          ▼ 物理地址 (pci_resource_start)
   ┌──────────────────┐
   │  内存控制器      │  ← 发现这个地址不在 DRAM 范围
   └──────┬───────────┘
          ▼
   ┌──────────────────┐
   │  PCIe Host Bridge │  ← 地址落在 PCIe 域
   └──────┬───────────┘
          ▼ 总线地址 (和物理地址可能不同，取决于 Host Bridge 映射)
   ┌──────────────────┐
   │  PCIe Switch/Root│
   │  Port            │
   └──────┬───────────┘
          ▼
   ┌──────────────────┐
   │  设备端点         │  ← BAR 寄存器里登记的地址匹配
   │  (网卡/显卡/SSD)  │      → 设备响应读写请求
   └──────────────────┘
```

---

## 8. 灵魂追问

**Q: 系统里那么多 PCIe 设备，它们的 BAR 地址会不会冲突？**
A: 不会。Kernel 的 `allocate_resource()` 在全局的 `iomem_resource` 树中找空闲区间，保证不重叠。

**Q: 为什么有的 BAR 是 64 位？**
A: 当设备需要映射超过 4GB 的地址空间（比如高端显卡的显存），就需要两个连续的 BAR 拼成 64 位地址。

**Q: BIOS 分配了地址，kernel 还会重新分配吗？**
A: 默认**保留** BIOS 分配。但如果 BIOS 分配有问题（冲突/空间不足），kernel 会在 `pci_assign_resource()` 中重新分配。

**Q: `ioremap` 和 `pci_iomap` 有什么区别？**
A: `pci_iomap` 是 `ioremap` 的便捷封装，自动处理 I/O 空间（return `ioport_map`）和内存空间（return `ioremap`）两种情况。

---

## 9. 附录：关键源码文件

| 文件 | 作用 |
| ------ | ------ |
| `include/uapi/linux/pci_regs.h` | BAR 寄存器的硬件位定义 |
| `include/linux/pci.h` | `pci_dev` 结构体、`pci_resource_*` 宏 |
| `include/linux/ioport.h` | `struct resource` 定义、资源管理器 API |
| `drivers/pci/probe.c` | BAR 探测、读取、`pci_read_bases()` |
| `drivers/pci/setup-res.c` | BAR 地址分配、更新、`pci_assign_resource()` |
| `drivers/pci/setup-bus.c` | 总线级资源分配、桥窗口配置 |
| `drivers/pci/bus.c` | `pci_bus_alloc_resource()` 总线级资源分配 |

---

> 注：本文基于 Linux kernel 源码分析。
> 内核版本：`v7.1-rc4-47-g4db02a472d88`
> 写作时间：2025-07-18
