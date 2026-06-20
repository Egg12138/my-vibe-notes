# QEMU 架构与组件扩展机制

[TOC]

---

## 1. QOM 类型系统 —— QEMU 的核心基石

QEMU Object Model (QOM) 是 QEMU 中一切组件的基础，它是一个基于 C 语言实现的面向对象类型系统。

### 1.1 核心概念

| 概念 | C 结构体 | 作用 |
|------|---------|------|
| **TypeInfo** | `struct TypeInfo` | 类型的元数据描述（名称、父类、大小、回调） |
| **ObjectClass** | `struct ObjectClass` | 类对象（单例），存放虚函数表、属性表 |
| **Object** | `struct Object` | 实例对象，第一个成员指向 ObjectClass |
| **TypeImpl** | `struct TypeImpl` | 内部类型表示，由 TypeInfo 构造 |

### 1.2 类型注册流程

```
TypeInfo (元数据) → type_register_static() → TypeImpl → type_table_add() → 全局类型表
                                                                              │
                                                   type_init(fn) ────────────┘
                                                  (constructor 属性，main() 前自动调用)
```

**关键源码：**

- `include/qom/object.h:276` — `DO_OBJECT_DEFINE_TYPE_EXTENDED` 宏，是所有注册宏的底层实现
- `qom/object.c:163` — `type_register_internal`，将类型加入哈希表
- `qom/object.c:178` — `type_register_static`，对外接口

### 1.3 类型注册宏体系

```c
// 底层: 完整控制
DO_OBJECT_DEFINE_TYPE_EXTENDED(ModuleObjName, module_obj_name,
    MODULE_OBJ_NAME, PARENT_MODULE_OBJ_NAME,
    ABSTRACT, CLASS_SIZE, ...interfaces...)

// 标准设备类型:
OBJECT_DEFINE_TYPE(ModuleObjName, module_obj_name,
    MODULE_OBJ_NAME, PARENT_MODULE_OBJ_NAME)

// 不需要自定义 class 的简单设备:
OBJECT_DEFINE_SIMPLE_TYPE(ModuleObjName, module_obj_name,
    MODULE_OBJ_NAME)

// CPU 专用:
OBJECT_DEFINE_CPU_TYPE(CpuInstanceType, CpuClassType, CPU_MODULE_OBJ_NAME)
```

### 1.4 实例/类的访问与转换

```c
// 类型安全的向下转换
#define OBJECT_CHECK(type, obj, name)    // Object → 具体类型
#define OBJECT_CLASS_CHECK(type, obj, name)  // ObjectClass → 具体 Class

// 常用封装宏
OBJECT_DECLARE_TYPE(InstanceType, ClassType, MODULE_OBJ_NAME)  // 生成:
    InstanceType *MODULE_OBJ_NAME(const void *obj);           //   obj → Instance
    ClassType *MODULE_OBJ_NAME##_GET_CLASS(const void *obj);  //   obj → Class
    ClassType *MODULE_OBJ_NAME##_CLASS(const void *klass);     //   class → Class
```

---

## 2. QOM 完整类型继承树

```
Object (TYPE_OBJECT)
│
├─ BusState (TYPE_BUS)
│   ├─ PCIBus
│   ├─ I2CBus
│   └─ SSIBus
│
├─ MachineState (TYPE_MACHINE)
│   ├─ riscv-g233-machine       ← RISC-V G233 SoC
│   ├─ riscv-virt-machine       ← RISC-V Virt
│   ├─ sifive-u / sifive-e      ← SiFive
│   ├─ arm-virt-machine         ← ARM Virt
│   └─ pc-machine               ← x86 PC
│
├─ AccelState (TYPE_ACCEL)
│   ├─ TCG   ← Tiny Code Generator (JIT)
│   ├─ KVM   ← Kernel-based VM
│   └─ HVF   ← macOS Hypervisor.framework
│
├─ EventLoopBase
│   └─ MainLoop (TYPE_MAIN_LOOP)
│
└─ DeviceState (TYPE_DEVICE)
    │
    ├─ CPUState (TYPE_CPU)
    │   ├─ RISCVCPU          [target/riscv/cpu.c]
    │   │   ├─ rv32i / rv64i                 (基础 ISA)
    │   │   ├─ sifive-e31 / e51              (SiFive 核心)
    │   │   ├─ xiangshan-nanhu / kunminghu   (香山处理器)
    │   │   ├─ gevico-cpu-v1                (自定义教学 CPU)
    │   │   └─ thead-c906                    (玄铁)
    │   ├─ ARMCPU           [target/arm/]
    │   ├─ X86CPU           [target/i386/]
    │   ├─ PowerPCCPU       [target/ppc/]
    │   └─ ... 共 19 种架构
    │
    ├─ SysBusDevice (TYPE_SYS_BUS_DEVICE)      ← 直连系统总线
    │   ├─ RISCVHartArrayState                 ← RISC-V Hart 数组
    │   ├─ PL011 / SerialMM                   ← 串口
    │   ├─ GoldfishRTC                        ← RTC
    │   ├─ SiFivePLIC / RISCVACLINT            ← 中断控制器
    │   ├─ GPEXHost                           ← PCIe 主机桥
    │   └─ PlatformBusDevice                  ← 动态总线
    │
    └─ PCIDevice (TYPE_PCI_DEVICE)             ← 挂 PCI/PCIe 总线
        ├─ GPGPUState  (TYPE_GPGPU)            ← 教学 GPU  [hw/gpgpu/]
        ├─ NVMe / virtio-blk                   ← 存储
        ├─ virtio-net / e1000                  ← 网络
        └─ virtio-gpu                         ← 显示
```

### Class 虚函数表继承链

```
ObjectClass
  └─ DeviceClass
       ├─ .realize / .unrealize      ← 设备两阶段构造
       ├─ .props_                    ← 属性（命令行可配置）
       ├─ .categories                ← 设备分类
       └─ .vmsd                      ← 迁移描述 (VMStateDescription)
            │
            ├─ CPUClass
            │   ├─ .set_pc / .get_pc         ← 程序计数器
            │   ├─ .tcg_ops  → TCGCPUOps    ← TCG 操作表（gen_intermediate_code 等）
            │   ├─ .sysemu_ops               ← 系统模拟操作
            │   ├─ .class_by_name            ← "-cpu name" 解析
            │   └─ .gdb_read/write_register  ← GDB 调试
            │
            ├─ SysBusDeviceClass
            │   └─ .explicit_ofw_unit_address
            │
            └─ PCIDeviceClass
                ├─ .vendor_id / .device_id   ← PCI 标识符
                ├─ .class_id / .revision
                └─ .realize / .exit          ← PCI 特有生命周期
```

---

## 3. 目录结构与代码分布

```
qemu/
├── include/qom/object.h              ← QOM 类型系统核心 (对象和类定义)
├── include/hw/core/
│   ├── qdev.h                        ← DeviceState / DeviceClass
│   ├── cpu.h                         ← CPUState / CPUClass
│   ├── boards.h                      ← MachineState / MachineClass
│   └── sysbus.h                      ← SysBusDevice
├── include/exec/
│   ├── translation-block.h           ← TranslationBlock 结构
│   └── memory.h                      ← MemoryRegion / MemoryRegionOps
├── include/system/memory.h           ← address_space_rw 等
│
├── qom/object.c                      ← type_register_static / type_new
├── hw/                               ← 硬件设备实现
│   ├── core/    (bus, qdev, sysbus, machine, cpu-common, irq, loader, ...)
│   ├── pci/     (PCI 总线/桥/设备基类)
│   ├── gpgpu/   (教学 GPGPU: gpgpu.h, gpgpu.c, gpgpu_core.h, gpgpu_core.c)
│   ├── riscv/   (RISC-V 机器: virt.c, g233.c, spike.c, riscv_hart.c, ...)
│   ├── arm/, intc/, display/, net/, ...
│
├── target/                           ← 每种 CPU 架构一个子目录
│   ├── riscv/  (cpu.c, translate.c, cpu_helper.c, cpu-qom.h, csr.c, ...)
│   ├── arm/    (共 78 个文件)
│   └── ... 共 19 种架构
│
├── system/
│   ├── main.c                        ← main() + qemu_default_main()
│   ├── vl.c                          ← qemu_init() — 命令行解析, 机器创建
│   ├── runstate.c                    ← qemu_main_loop(), runstate_set()
│   └── physmem.c                     ← 物理内存管理
│
├── accel/
│   ├── tcg/cpu-exec.c                ← cpu_exec(), cpu_loop_exec_tb(), cpu_tb_exec()
│   ├── tcg/tcg-accel-ops.c           ← tcg_cpu_exec
│   └── kvm/...
│
├── util/main-loop.c                  ← main_loop_wait(), os_host_main_loop_wait()
└── fpu/softfloat.c                   ← IEEE 754 浮点模拟
```

---

## 4. 核心执行流

### 4.1 启动到主循环

```
main()                                    [system/main.c:69]
  │
  ├─ qemu_init(argc, argv)                [system/vl.c:2842]
  │   ├─ module_call_init(MODULE_INIT_QOM)      ← 注册所有 QOM 类型
  │   ├─ qemu_init_subsystems()                  ← QOM/迁移/加密/信号
  │   ├─ 解析命令行 → 选定 MachineClass + CPU type
  │   ├─ qemu_init_board()             ← 创建 machine 实例
  │   │   └─ machine_class->init()     ← 具体机器的 init 回调
  │   │       └─ virt_machine_init()   [hw/riscv/g233.c:1532]
  │   │           ├─ object_initialize_child()   ← 创建 CPU (harts)
  │   │           ├─ sysbus_create_simple()      ← 创建外设
  │   │           ├─ gpex_pcie_init()            ← 初始化 PCIe
  │   │           ├─ memory_region_add_subregion()← 映射内存地址空间
  │   │           └─ create_fdt()                ← 生成设备树 (guest 可见)
  │   └─ qemu_create_cli_devices()     ← 创建命令行指定的设备 (-device)
  │
  ├─ bql_unlock() / replay_mutex_unlock()
  │
  └─ qemu_default_main()               [system/main.c:44]
      ├─ bql_lock()                    ← 获取 Big QEMU Lock
      └─ qemu_main_loop()              [system/runstate.c:938]
          └─ while (!main_loop_should_exit()):
              └─ main_loop_wait()      [util/main-loop.c:563]
                  ├─ 收集所有 poll fds
                  ├─ os_host_main_loop_wait() → select/poll
                  ├─ g_main_context_dispatch()
                  └─ qemu_clock_run_all_timers()
```

### 4.2 TCG vCPU 执行路径

```
cpu_exec()                               [accel/tcg/cpu-exec.c:1019]
  └─ cpu_exec_loop()
      ├─ tb_find()                       ← 查找或生成 TranslationBlock
      │   └─ gen_intermediate_code()     ← target/<arch>/translate.c
      │       └─ 将 guest 指令翻译为 TCG IR
      │           └─ tcg_gen_code()      ← 将 TCG IR 编译为 host 机器码
      └─ cpu_loop_exec_tb()             [accel/tcg/cpu-exec.c:884]
          └─ cpu_tb_exec()              [accel/tcg/cpu-exec.c:427]
              └─ tcg_qemu_tb_exec()     ← 执行编译后的 host 代码
```

### 4.3 线程模型

| 线程 | 职责 | 锁 |
|------|------|-----|
| iothread (主线程) | 运行 `main_loop_wait()`，处理设备 I/O | BQL |
| vCPU 线程 × N | 运行 TCG/KVM 执行循环 | BQL (TCG) 或无 (KVM) |
| 工作线程 | 后台 I/O (AIO, 迁移等) | 各子系统锁 |

---

## 5. 数据注入机制

### 5.1 MMIO — 外设交互的核心通道

```c
// 1. 定义 ops
static const MemoryRegionOps gpgpu_ctrl_ops = {
    .read  = gpgpu_ctrl_read,       // guest 读时回调
    .write = gpgpu_ctrl_write,      // guest 写时回调
    .endianness = DEVICE_LITTLE_ENDIAN,
};

// 2. 初始化 MemoryRegion
memory_region_init_io(&s->ctrl_mmio, OBJECT(s), &gpgpu_ctrl_ops, s,
                      "gpgpu-ctrl", GPGPU_CTRL_BAR_SIZE);
// 3. 注册到 PCI BAR
pci_register_bar(pdev, 0, PCI_BASE_ADDRESS_SPACE_MEMORY, &s->ctrl_mmio);
```

**调用链：** guest 访存指令 → `address_space_rw()` → `memory_region_dispatch_read/write()` → `ops->read/write()`

### 5.2 中断注入

```c
msi_notify(pdev, vector);               // MSI/MSI-X 中断
qemu_set_irq(irq_line, level);          // 线中断
```

### 5.3 Timer 注入 (虚拟时钟事件)

```c
s->timer = timer_new_ms(QEMU_CLOCK_VIRTUAL, callback, s);
timer_mod(s->timer, qemu_clock_get_ms(QEMU_CLOCK_VIRTUAL) + delay);
```

### 5.4 DMA 注入

```c
address_space_write(&address_space_memory, dma_addr,
                    MEMTXATTRS_UNSPECIFIED, buf, size);
```

---

## 6. 元数据 (Metadata) 体系

| 元数据类型 | 数据结构 | 文件位置 | 用途 |
|-----------|---------|---------|------|
| **QOM 类型注册** | `TypeInfo` | 各 `*.c` 文件 | 类型名称、父类、大小、回调 |
| **QMP 接口 Schema** | QAPI JSON | `qapi/*.json` | 定义 QMP 命令和类型的 schema，编译时生成 C 代码 |
| **迁移状态** | `VMStateDescription` | 设备 `*.c` 文件 | 声明需要保存/恢复的字段，支持版本化 |
| **设备属性** | `Property` 数组 | 设备 `*.c` 文件 | 命令行可配置的参数（如 `num_cus=8`） |
| **设备树 (FDT)** | 动态生成 | `hw/<arch>/<machine>.c` | guest OS 可见的硬件描述 |
| **PCI 标识** | PCIDeviceClass 字段 | 设备 `class_init` | vendor_id, device_id, class_id, revision |

### VMStateDescription 示例

```c
static const VMStateDescription vmstate_gpgpu = {
    .name = "gpgpu",
    .version_id = 1,
    .minimum_version_id = 1,
    .fields = (const VMStateField[]) {
        VMSTATE_PCI_DEVICE(parent_obj, GPGPUState),  // 继承父类字段
        VMSTATE_UINT32(global_ctrl, GPGPUState),
        VMSTATE_UINT32(global_status, GPGPUState),
        VMSTATE_UINT32(irq_enable, GPGPUState),
        VMSTATE_END_OF_LIST()
    }
};
```

### Property 示例

```c
static const Property gpgpu_properties[] = {
    DEFINE_PROP_UINT32("num_cus", GPGPUState, num_cus, 4),
    DEFINE_PROP_UINT32("warps_per_cu", GPGPUState, warps_per_cu, 4),
    DEFINE_PROP_UINT64("vram_size", GPGPUState, vram_size, 64 * MiB),
};
// 命令行: -device gpgpu,num_cus=8,vram_size=128M
```

---

## 7. 四种场景的扩展改动点

### 7.1 扩展新的 CPU

**涉及文件：**

| 文件 | 角色 |
|------|------|
| `target/<arch>/cpu-qom.h` | 定义 TYPE_RISCV_CPU_MY_NEW 等 QOM 类型名 |
| `target/<arch>/cpu.c` | CPUClass 实现 (class_init, instance_init, realize) |
| `target/<arch>/cpu.h` | CPUArchState, RISCVCPU 结构体定义 |
| `target/<arch>/cpu_cfg.h` | ISA 扩展配置位 |
| `target/<arch>/translate.c` | 指令翻译 (guest ISA → TCG IR) |
| `target/<arch>/cpu_helper.c` | TCG helper 函数 |

**关键步骤：**

```
1. 定义 QOM typename → 2. 实现 class_init (设置 tcg_ops, sysemu_ops)
→ 3. 实现 translate.c (gen_intermediate_code)
→ 4. 注册 TypeInfo[] → type_init() 自动注册
```

### 7.2 扩展新的外设 (以 PCI 设备为例)

**每个设备遵循相同的 QOM 模式：**

```
1. 头文件 (gpgpu.h):
   - #define TYPE_GPGPU "gpgpu"
   - OBJECT_DECLARE_SIMPLE_TYPE(GPGPUState, GPGPU)
   - struct GPGPUState { PCIDevice parent_obj; /* 状态字段 */ };
   - 寄存器偏移量 / 位域宏定义

2. 实现文件 (gpgpu.c):
   - MMIO ops → MemoryRegionOps
   - realize() → memory_region_init_io + pci_register_bar + msix_init
   - class_init() → 设置 vendor_id/device_id/class_id
   - TypeInfo → type_init() 自动注册

3. 构建文件 (meson.build):
   - 将 .c 加入编译目标
```

### 7.3 扩展建模新的 SoC

**核心文件：** `hw/<arch>/<machine>.c`

**关键模式：**

```
1. 定义 MachineState 子类
2. 定义 MemMapEntry[] → SoC 地址布局
3. 实现 machine_init():
   a. object_initialize_child() → 创建 CPU
   b. sysbus_create_simple()   → 创建外设 + 映射到地址空间
   c. qdev_get_gpio_in()       → 中断连线
   d. gpex_pcie_init()         → PCIe 总线
   e. memory_region_add_subregion() → 映射 RAM
   f. create_fdt()             → 生成设备树
4. MachineClass 注册 → type_init()
```

### 7.4 对 GPGPU 进行建模

**分层设计：**

```
Layer 1: PCI 设备层 (gpgpu.c)
  ├── BAR 空间 (ctrl/vram/doorbell)
  ├── MMIO 寄存器接口 (guest 驱动访问)
  ├── MSI-X 中断 (kernel done, DMA done, error)
  └── DMA 引擎、Timer 模拟

Layer 2: SIMT 核心层 (gpgpu_core.c)
  ├── Warp → 32 个 Lane (SIMT 锁步执行)
  ├── Lane → 简化的 RV32I 寄存器组 + PC
  └── Barrier 同步原语

Layer 3: 执行引擎
  └── 指令解释器 (RV32I + RV32F 子集)
```

**数据注入路径 (GPGPU 特有的完整流程)：**

```
Guest Driver                      QEMU GPGPU
    │                                │
    ├─ write MMIO (dispatch) ──────►│ gpgpu_ctrl_write()
    │                                │   ├─ 设置 grid/block 维度参数
    │                                │   └─ dispatch → kernel_timer 触发
    │                                │
    │                                │ gpgpu_kernel_complete()
    │                                │   └─ gpgpu_core_exec_kernel()
    │                                │       └─ for block: for warp: for lane:
    │                                │           └─ gpgpu_core_exec_warp()
    │                                │               └─ RV32I 解释器循环
    │                                │                   ├─ VRAM read/write
    │                                │                   └─ CTRL MMIO read (线程ID)
    │                                │
    │◄── MSI-X interrupt ───────────│ 完成通知 (KERNEL_DONE / DMA_DONE)
    │                                │
    ├─ read MMIO (status) ─────────►│ 获取执行结果
```

---

## 8. 扩展组件的通用模式 (Cheat Sheet)

无论扩展哪种组件，都遵循相同流程：

```
① 定义数据结构 (struct)
   第一个成员必须是父类型 (C 结构体继承的惯用法)
   添加自己的状态字段

② 定义 TYPE 宏 + Object cast 宏
   OBJECT_DECLARE_TYPE / OBJECT_DECLARE_SIMPLE_TYPE / OBJECT_DECLARE_CPU_TYPE

③ 实现 class_init()
   覆盖父类的虚函数指针 (回调函数表)

④ 如果是设备:
   - 实现 realize/unrealize (两阶段构造)
   - 实现 MMIO read/write 回调 (MemoryRegionOps)
   - 定义 VMStateDescription (迁移支持)
   - 定义 Property[] (命令行参数)

⑤ 注册 TypeInfo → type_init() 自动注册
```

### 各类组件的父类型速查

| 组件类型 | 父类型 QOM Name | 父类型 C Type | 关键目录 |
|---------|----------------|--------------|---------|
| CPU | TYPE_CPU | `DeviceState` | `target/<arch>/` |
| MMIO 外设 | TYPE_SYS_BUS_DEVICE | `DeviceState` | `hw/<category>/` |
| PCI 外设 | TYPE_PCI_DEVICE | `DeviceState` | `hw/<category>/` |
| Machine/SoC | TYPE_MACHINE | `Object` | `hw/<arch>/` |
| 加速器 | TYPE_ACCEL | `Object` | `accel/<name>/` |

---

*Generated: 2026-06-20 | Source: git@github.com:gevico/qemu-camp-2026-exper-Egg12138.git branch=ai_try commit=27de27e*
