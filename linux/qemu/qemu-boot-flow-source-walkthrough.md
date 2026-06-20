# QEMU 启动主流程源码导读

[TOC]

---

## 1. 执行流总览

```
main()                              [system/main.c:69]
  │
  └─ qemu_init()                    [system/vl.c:2842]
      │  解析命令行，注册 QEMU 选项
      │  创建 Machine 实例
      │  初始化加速器 (TCG/KVM)
      │
      └─ qmp_x_exit_preconfig()     [system/vl.c:2802]
           │
           ├─ qemu_init_board()     [system/vl.c:2707]
           │   └─ machine_run_board_init()  [hw/core/machine.c:1668]
           │       └─ machine_class->init(machine)
           │           └─ virt_machine_init()  [hw/riscv/g233.c:1532]
           │               ├─ 创建 CPU Hart 数组
           │               │   └─ 每个 Hart: qemu_init_vcpu() → 创建 vCPU 线程
           │               ├─ 创建外设、中断控制器、PCIe、Flash
           │               └─ 注册 virt_machine_done 通知器
           │
           ├─ qemu_create_cli_devices()  [system/vl.c:2735]
           │   └─ "-device" 命令行设备
           │
           └─ qemu_machine_creation_done()  [system/vl.c:2762]
               └─ qdev_machine_creation_done()  [hw/core/machine.c:1790]
                   ├─ cpu_synchronize_all_post_init()
                   ├─ phase_advance(PHASE_MACHINE_READY)
                   └─ notifier_list_notify(&machine_init_done_notifiers)
                       └─ virt_machine_done()  [hw/riscv/g233.c:1438]
                           ├─ finalize_fdt()         ← 生成设备树
                           ├─ riscv_find_and_load_firmware()  ← 加载 OpenSBI
                           ├─ riscv_load_kernel()             ← 加载内核
                           ├─ riscv_load_fdt()                ← 加载 FDT
                           └─ riscv_setup_rom_reset_vec()     ← 写入复位向量到 MROM

           └─ (autostart) qmp_cont() → vm_start() → resume_all_vcpus()
                                                    (vCPU 线程开始执行)

  └─ qemu_default_main()               [system/main.c:44]
      └─ qemu_main_loop()              [system/runstate.c:938]
          └─ main_loop_wait()          [util/main-loop.c:563]
              ├─ 收集 poll fds
              ├─ 阻塞在 select/poll
              └─ 分发事件 + 运行定时器
```

---

## 2. main() 入口

`system/main.c:69`

```c
int main(int argc, char **argv)
{
    qemu_init(argc, argv);                          // ← 整个初始化都在这里

    bql_unlock();                                   // 释放 BQL (初始化时持有)
    replay_mutex_unlock();                          // 释放 replay 锁

    if (qemu_main) {                                // macOS: UI 需在主线程
        QemuThread t;
        qemu_thread_create(&t, "qemu_main",
            qemu_default_main, NULL, QEMU_THREAD_DETACHED);
        return qemu_main();                         // 返回 CFRunLoop
    } else {
        qemu_default_main(NULL);                    // Linux: 直接运行
    }
}
```

`qemu_default_main` → `qemu_main_loop()` → 进入 I/O 事件循环。

---

## 3. qemu_init() — 初始化的大熔炉

`system/vl.c:2842`

### 3.1 阶段划分

```
qemu_init() 内的阶段:

 ① 注册所有命令行选项到 QemuOpts
     qemu_add_opts(&qemu_drive_opts)
     qemu_add_opts(&qemu_device_opts)
     ...

 ② module_call_init(MODULE_INIT_QOM) +
    通过 constructor 属性自动注册所有 QOM 类型

 ③ 解析命令行 (2 轮)
    第 1 轮: 扫描 -nouserconfig
    第 2 轮: 解析所有选项 (-M, -cpu, -smp, -m, -device, ...)

 ④ qemu_init_main_loop()            [util/main-loop.c:160]
    创建 qemu_aio_context + gpollfds

 ⑤ qemu_create_machine()            [system/vl.c:2190]
    → select_machine()              按 -M 参数选择 MachineClass
    → object_new_with_class()       创建 MachineState 实例
    → cpu_exec_init_all()           初始化内存管理

 ⑥ configure_accelerators()         ← 初始化 TCG/KVM

 ⑦ qmp_x_exit_preconfig()           ← 启动板级初始化
    ├─ qemu_init_board()             ← machine_class->init()
    ├─ qemu_create_cli_devices()     ← -device 创建设备
    ├─ qdev_machine_creation_done()  ← 触发 machine_done 通知器
    └─ qmp_cont()                    ← 启动 vCPU
```

### 3.2 QOM 类型注册时机

```c
// qemu_init_subsystems() 内部  [system/vl.c:965]
qemu_init_subsystems() {
    module_call_init(MODULE_INIT_TRACE);       // trace
    qemu_init_cpu_list();
    qemu_init_cpu_loop();
    module_call_init(MODULE_INIT_QOM);         // ← QOM 类型注册!
    module_call_init(MODULE_INIT_MIGRATION);   // 迁移
}
```

`type_init(fn)` 宏的本质：

```c
// util/module.c
#define type_init(fn)                                        \
    static void __attribute__((constructor)) do_##fn(void) { \
        register_module_init(fn, MODULE_INIT_QOM);           \
    }

// 然后 module_call_init(MODULE_INIT_QOM) 遍历执行所有已注册的 fn
```

所有 `.c` 文件中的 `type_init(xxx_register_types)` 在 `module_call_init` 时被批量调用。

---

## 4. Machine 初始化与类型注册路径

### 4.1 MachineClass 注册

以 RISC-V G233 板为例 (`hw/riscv/g233.c:1957`):

```c
static const TypeInfo virt_machine_typeinfo = {
    .name       = TYPE_RISCV_G233_MACHINE,    // "riscv-g233-machine"
    .parent     = TYPE_MACHINE,                // 继承 MachineState
    .class_init = virt_machine_class_init,     // 设置 mc->init
    .instance_init = virt_machine_instance_init,
    .instance_size = sizeof(RISCVG233State),
};

static void virt_machine_class_init(ObjectClass *oc, const void *data) {
    MachineClass *mc = MACHINE_CLASS(oc);
    mc->init = virt_machine_init;               // ← 板级入口
    mc->max_cpus = VIRT_CPUS_MAX;
    mc->default_cpu_type = TYPE_RISCV_CPU_GEVICO_CV1;  // 默认 CPU
    mc->default_ram_id = "riscv_virt_board.ram";
}

type_init(virt_machine_init_register_types);   // ← constructor 自动注册
```

### 4.2 机器选择与创建

```c
// system/vl.c:2190
static void qemu_create_machine(QDict *qdict)
{
    MachineClass *machine_class = select_machine(qdict, &error_fatal);
    // select_machine() 在已注册的 MachineClass 列表中按 -M 参数匹配

    current_machine = MACHINE(
        object_new_with_class(OBJECT_CLASS(machine_class)));
    // object_new_with_class → 分配内存 + instance_init

    cpu_exec_init_all();    // 初始化 TCG 内存管理
}
```

### 4.3 machine_run_board_init — 调用板级入口

```c
// hw/core/machine.c:1668
void machine_run_board_init(MachineState *machine, const char *mem_path,
                            Error **errp)
{
    // 省略 RAM 检查、NUMA 初始化...

    accel_init_interfaces(...);         // 加速器接口初始化

    machine_class->init(machine);       // ← 调用 virt_machine_init()

    phase_advance(PHASE_MACHINE_INITIALIZED);
}
```

---

## 5. virt_machine_init() — G233 板级初始化

`hw/riscv/g233.c:1532`

### 5.1 内存映射表

```c
static const MemMapEntry virt_memmap[] = {
    [VIRT_DEBUG]    = {        0x0,         0x100 },
    [VIRT_MROM]     = {     0x1000,        0xf000 },   // 开机复位向量
    [VIRT_TEST]     = {   0x100000,        0x1000 },
    [VIRT_CLINT]    = {  0x2000000,       0x10000 },   // 定时器
    [VIRT_PLIC]     = {  0xc000000,     0x4000000 },   // 中断控制器
    [VIRT_UART0]    = { 0x10000000,         0x100 },   // 串口
    [VIRT_DRAM]     = { 0x80000000,           0x0 },   // 主存
};
```

### 5.2 初始化流程

```c
static void virt_machine_init(MachineState *machine)
{
    RISCVG233State *s = RISCV_G233_MACHINE(machine);
    MemoryRegion *system_memory = get_system_memory();

    // (1) 创建 CPU Hart 数组
    for (i = 0; i < socket_count; i++) {
        object_initialize_child(OBJECT(machine), soc_name,
                                &s->soc[i], TYPE_RISCV_HART_ARRAY);
        object_property_set_str(OBJECT(&s->soc[i]), "cpu-type",
                                machine->cpu_type, ...);
        sysbus_realize(SYS_BUS_DEVICE(&s->soc[i]), ...);
        // → riscv_harts_realize()
        //    → for each hart: riscv_hart_realize()
        //       → object_initialize_child(..."harts[*]", ..., cpu_type)
        //       → qdev_realize()
        //          → riscv_cpu_realize()    [target/riscv/cpu.c]
        //             → cpu_exec_realizefn()
        //             → qemu_init_vcpu()    → 创建 vCPU 线程!

        // (2) 创建外设
        create_fdt_socket_aclint(...);    // 定时器
        s->irqchip[i] = virt_create_plic/aia(...);  // 中断控制器
    }

    // (3) 注册主存 + MROM
    memory_region_add_subregion(system_memory,
        s->memmap[VIRT_DRAM].base, machine->ram);
    memory_region_init_rom(mask_rom, NULL, "mrom",
                           s->memmap[VIRT_MROM].size, ...);
    memory_region_add_subregion(system_memory,
        s->memmap[VIRT_MROM].base, mask_rom);

    // (4) 创建 PCIe、VirtIO、UART、RTC
    gpex_pcie_init(system_memory, pcie_irqchip, s);
    sysbus_create_simple("virtio-mmio", base, irq);
    pl011_create(...);    // PL011 UART

    // (5) 注册 machine_done 通知器
    s->machine_done.notify = virt_machine_done;
    qemu_add_machine_init_done_notifier(&s->machine_done);
    // ← virt_machine_done 在 qdev_machine_creation_done() 时被调用
}
```

### 5.3 CPU Hart 创建详情

```c
// hw/riscv/riscv_hart.c:148
static void riscv_harts_realize(DeviceState *dev, Error **errp)
{
    RISCVHartArrayState *s = RISCV_HART_ARRAY(dev);
    s->harts = g_new0(RISCVCPU, s->num_harts);

    for (n = 0; n < s->num_harts; n++) {
        // 阶段 1: 对象实例化 (不可失败)
        object_initialize_child(OBJECT(s), "harts[*]",
                                &s->harts[n], cpu_type);
        s->harts[n].env.mhartid = s->hartid_base + n;

        // 阶段 2: realize (可失败)
        qdev_realize(DEVICE(&s->harts[n]), NULL, errp);
        // → riscv_cpu_realize()
        //   → cpu_exec_realizefn()
        //     → accel_cpu_common_realize()
        //     → cpu_list_add()          ← 加入全局 cpus_queue
        //     → cpu_vmstate_register()
        //   → qemu_init_vcpu()          ← 创建 vCPU 线程!
    }
}
```

---

## 6. 加载 OpenSBI 与客户机程序的完整路径

固件加载发生在 `virt_machine_done()` 回调中——这是在 `qdev_machine_creation_done()` 触发 `machine_init_done_notifiers` 时执行的。

```c
// hw/riscv/g233.c:1438
static void virt_machine_done(Notifier *notifier, void *data)
{
    // (1) 生成设备树 (FDT)
    if (machine->dtb == NULL)
        finalize_fdt(s);

    // (2) 加载 OpenSBI 固件
    firmware_end_addr = riscv_find_and_load_firmware(
        machine, firmware_name, &start_addr, NULL);

    // (3) 如果使用 pflash，设置固件启动
    pflash_blk0 = pflash_cfi01_get_blk(s->flash[0]);
    if (pflash_blk0) { ... }

    // (4) 加载内核 (如果指定了 -kernel)
    riscv_boot_info_init(&boot_info, &s->soc[0]);
    if (machine->kernel_filename && !kernel_entry) {
        kernel_start_addr = riscv_calc_kernel_addr(...);
        riscv_load_kernel(machine, &boot_info,
                          kernel_start_addr, true, NULL);
        kernel_entry = boot_info.image_low_addr;
    }

    // (5) 加载 FDT 到内存
    fdt_load_addr = riscv_compute_fdt_addr(...);
    riscv_load_fdt(fdt_load_addr, machine->fdt);

    // (6) 写入复位向量到 MROM
    riscv_setup_rom_reset_vec(machine, &s->soc[0], start_addr,
                              VIRT_MROM.base, VIRT_MROM.size,
                              kernel_entry, fdt_load_addr);
}
```

### 6.1 固件加载 `riscv_find_and_load_firmware()`

```c
// hw/riscv/boot.c:136
hwaddr riscv_find_and_load_firmware(MachineState *machine,
                                    const char *default_fw, ...)
{
    // 搜索固件文件路径
    firmware_filename = riscv_find_firmware(machine->firmware,
                                            default_fw);

    // 使用 load_elf_ram_sym 加载 ELF 格式的 OpenSBI
    firmware_end_addr = riscv_load_firmware(firmware_filename,
                                            firmware_load_addr, sym_cb);
    // → load_elf_ram_sym()           ← 将 OpenSBI 读到 guest 物理内存
    // → 或 load_image_targphys_as()  ← 二进制格式
    return firmware_end_addr;
}
```

`load_elf_ram_sym` 最终调用 `address_space_write()` 将 ELF 段写入 guest 物理地址空间，即直接写入了 `memory_region`。

### 6.2 复位向量 `riscv_setup_rom_reset_vec()`

QEMU 写入 MROM 的代码（硬件复位后 CPU 最先执行的指令）：

```c
// hw/riscv/boot.c:447
uint32_t reset_vec[10] = {
    0x00000297,             // auipc  t0, 0          ← t0 = 当前 PC
    0x02828613,             // addi   a2, t0, 40     ← a2 = fw_dyn 地址
    0xf1402573,             // csrr   a0, mhartid    ← a0 = hart ID
    // (下面两条根据 32/64 位不同)
    0x0202b583,             // ld     a1, 32(t0)     ← a1 = fdt_addr
    0x0182b283,             // ld     t0, 24(t0)     ← t0 = start_addr
    0x00028067,             // jr     t0              ← 跳转到 OpenSBI!
    // 内嵌的数据 (在 t0 + 24, t0 + 32):
    start_addr,             // OpenSBI 的入口地址
    start_addr_hi32,
    fdt_load_addr,          // DTB 的地址
    fdt_load_addr_hi32,
};

// 写入 MROM
rom_add_blob_fixed_as("mrom.reset", reset_vec, sizeof(reset_vec),
                      rom_base, &address_space_memory);
```

**这就是 vCPU 第一条指令的源头：**
- 系统上电 → vCPU PC = `env->resetvec`（由 `riscv_cpu_reset_hold()` 设置）
- 默认 `resetvec = DEFAULT_RSTVEC`（即 `VIRT_MROM.base = 0x1000`）
- 执行 MROM 中的 `auipc + ld + jr` 序列 → 跳转到 OpenSBI
- OpenSBI 初始化 SBI 服务 → 跳转到 kernel 入口

---

## 7. vCPU 第一条指令的执行路径

### 7.1 vCPU 线程被创建（但暂停）

在 `sysbus_realize()` 过程中，每个 hart 会调用 `qemu_init_vcpu()`:

```c
// system/cpus.c:709
void qemu_init_vcpu(CPUState *cpu)
{
    cpu->stopped = true;                              // ← 初始为暂停状态
    cpu_address_space_init(cpu, 0, "cpu-memory", ...);

    cpus_accel->create_vcpu_thread(cpu);               // ← MTTCG: mttcg_start_vcpu_thread

    while (!cpu->created) {                            // 等待线程启动
        qemu_cond_wait(&qemu_cpu_cond, &bql);
    }
}
```

### 7.2 vCPU 线程函数

```c
// accel/tcg/tcg-accel-ops-mttcg.c:65
static void *mttcg_cpu_thread_fn(void *arg)
{
    CPUState *cpu = arg;

    tcg_register_thread();
    bql_lock();
    cpu_thread_signal_created(cpu);     // ← 通知 qemu_init_vcpu 线程已创建

    do {
        qemu_process_cpu_events(cpu);

        if (cpu_can_run(cpu)) {         // ← cpu->stopped 被 resume_all_vcpus 清除
            bql_unlock();
            r = tcg_cpu_exec(cpu);      // ← 进入执行循环!
            bql_lock();
            // 处理 EXCP_DEBUG, EXCP_HALTED, EXCP_ATOMIC
        }
    } while (!cpu->unplug || cpu_can_run(cpu));
}
```

### 7.3 vCPU 何时开始运行

```c
// system/cpus.c:800
void vm_start(void)
{
    if (!vm_prepare_start(false)) {
        resume_all_vcpus();             // ← 唤醒所有 vCPU
    }
}

// system/cpus.c:669
void resume_all_vcpus(void)
{
    CPU_FOREACH(cpu) {
        cpu_resume(cpu);                // ← cpu->stopped = false
    }
    // → vCPU 线程的 cpu_can_run() 返回 true
    // → 进入 tcg_cpu_exec() → cpu_exec()
}
```

`vm_start()` 的调用路径：

```
qmp_x_exit_preconfig()                  [system/vl.c:2837]
  └─ (autostart) qmp_cont(NULL)
      └─ qmp_cont()
          └─ vm_start()                 [system/cpus.c:800]
              └─ resume_all_vcpus()     [system/cpus.c:669]
                  └─ CPU_FOREACH: cpu_resume(cpu)
```

### 7.4 vCPU 指令执行循环

```c
// accel/tcg/tcg-accel-ops-mttcg.c:92
r = tcg_cpu_exec(cpu);      // → cpu_exec() → cpu_exec_loop()

// accel/tcg/cpu-exec.c:932
cpu_exec_loop(CPUState *cpu, SyncClocks *sc) {
    while (!cpu_handle_exception(cpu, &ret)) {
        while (!cpu_handle_interrupt(cpu, &last_tb)) {
            s.pc = cpu->cc->tcg_ops->get_tb_cpu_state(cpu).pc;
            // ← 第一次: env->pc = env->resetvec = 0x1000 (MROM)

            tb = tb_lookup(cpu, pc, flags, ...);
            if (tb == NULL) {
                tb = tb_gen_code(cpu, pc);
                // ← 从 0x1000 开始翻译 MROM 中的复位向量
            }
            cpu_loop_exec_tb(cpu, tb, pc, &last_tb, &tb_exit);
            // ← 执行: auipc → csrr → ld → ld → jr 0x80000000(OpenSBI)
        }
    }
}
```

完整的第一条指令路径：

```
① CPU reset → env->pc = env->resetvec (= 0x1000, MROM地址)

② resume_all_vcpus() → cpu->stopped = false

③ mttcg_cpu_thread_fn → cpu_can_run() = true
    → tcg_cpu_exec() → cpu_exec() → cpu_exec_loop()

④ get_tb_cpu_state() → pc = 0x1000

⑤ tb_lookup(0x1000) → miss (第一次)
    tb_gen_code(0x1000)
      → riscv_tr_translate_insn() × 5 (MROM 中的 5 条指令)
        → auipc t0, 0        (0x1000)
        → addi  a2, t0, 40   (0x1004)
        → csrr  a0, mhartid  (0x1008)
        → ld    a1, 32(t0)   (0x100C)
        → ld    t0, 24(t0)   (0x1010)
        → jr    t0           (0x1014) ← DISAS_JUMP, TB 终止

⑥ cpu_tb_exec() → tcg_qemu_tb_exec()
    host CPU 执行翻译后的 x86_64 代码
    效果: 跳转到 OpenSBI 入口 0x80000000

⑦ OpenSBI 开始执行 (此时已完全不受 QEMU 翻译器干预
    除非遇到新代码页需要翻译)
```

---

## 8. 主循环与线程模型

### 8.1 三线程架构

```
┌───────────────────────────────────────────────────────────────────┐
│                       QEMU 进程                                    │
│                                                                   │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐        │
│  │ 主线程        │    │ vCPU 线程 0  │    │ vCPU 线程 1  │        │
│  │ (iothread)   │    │ (TCG/KVM)   │    │ (TCG/KVM)   │        │
│  │              │    │              │    │              │        │
│  │ qemu_main_   │    │ mttcg_cpu_   │    │ mttcg_cpu_   │        │
│  │ loop()       │    │ thread_fn()  │    │ thread_fn()  │        │
│  │              │    │              │    │              │        │
│  │ main_loop_   │    │ cpu_exec()   │    │ cpu_exec()   │        │
│  │ wait()       │    │  ╲          │    │  ╲          │        │
│  │  ├─ 处理 I/O │    │   ╲ TB链    │    │   ╲ TB链    │        │
│  │  ├─ 运行定时器│    │    ╲执行    │    │    ╲执行    │        │
│  │  └─ 分发事件 │    │              │    │              │        │
│  └──────┬───────┘    └──────┬───────┘    └──────┬───────┘        │
│         │                   │                   │                │
│         └───────────┬───────┴────────┬──────────┘                │
│                     │               │                            │
│              ┌──────┴──────┐  ┌──────┴──────┐                    │
│              │   BQL 锁    │  │   事件通知   │                    │
│              └─────────────┘  └─────────────┘                    │
└───────────────────────────────────────────────────────────────────┘
```

### 8.2 各线程职责

| 线程 | 代码 | 职责 |
|------|------|------|
| **主线程** | `qemu_main_loop()` | 设备 I/O 事件、定时器、QMP 命令、迁移 |
| **vCPU 线程** | `mttcg_cpu_thread_fn()` | 运行 guest 代码 |
| **工作线程** | AIO / 迁移 | 磁盘后端、网络后端、迁移数据流 |

### 8.3 主线程

```c
// system/runstate.c:938
int qemu_main_loop(void)
{
    int status = EXIT_SUCCESS;
    while (!main_loop_should_exit(&status)) {
        main_loop_wait(false);          // ← 阻塞等待事件
    }
    return status;
}

// util/main-loop.c:563
void main_loop_wait(int nonblocking)
{
    // ① 收集所有设备的 poll fds
    notifier_list_notify(&main_loop_poll_notifiers, &mlpoll);

    // ② 计算超时 (取所有定时器的最小 deadline)
    timeout = qemu_soonest_timeout(..., timerlistgroup_deadline_ns());

    // ③ 阻塞在 select/poll 上
    os_host_main_loop_wait(timeout);

    // ④ 分发就绪事件
    g_main_context_dispatch(context);

    // ⑤ 运行到期的定时器
    qemu_clock_run_all_timers();
}
```

### 8.4 vCPU 线程 (MTTCG 多线程模式)

```c
// accel/tcg/tcg-accel-ops-mttcg.c:65
static void *mttcg_cpu_thread_fn(void *arg)
{
    CPUState *cpu = arg;
    tcg_register_thread();

    bql_lock();
    current_cpu = cpu;
    cpu_thread_signal_created(cpu);     // 通知主线程

    do {
        qemu_process_cpu_events(cpu);   // 处理待办事件

        if (cpu_can_run(cpu)) {
            bql_unlock();               // 执行时释放 BQL (MTTCG 关键!)
            r = tcg_cpu_exec(cpu);      // cpu_exec() 循环
            bql_lock();                 // 执行完重新获取 BQL
        }
    } while (!cpu->unplug);

    return NULL;
}
```

**MTTCG 关键点：vCPU 执行时释放 BQL，只有需要处理设备 I/O（MMIO 访问、中断注入）时才重新获取。** 这样多个 vCPU 线程可以并行执行 guest 代码，只在访问共享资源时同步。

### 8.5 vCPU 与主线程的同步

```
                  主线程                              vCPU 线程
          ┌──────────────────┐              ┌──────────────────────┐
          │ main_loop_wait() │              │  tcg_cpu_exec()      │
          │  阻塞在 select   │              │  ├─ TB 链执行 (无锁) │
          │                  │              │  ├─ MMIO 访存        │
          │  收到中断事件 ───┼──────────────┼──→ 触发 BQL 竞争      │
          │  (如 QMP 命令)  │              │  └─ 停住等 BQL       │
          │                  │              │                      │
          │  处理事件        │              │  获得 BQL → 继续      │
          │  例如: qmp_stop  │              │                      │
          │  → vm_stop()     │              │                      │
          │  → pause_all_    │              │  cpu_stop_current()  │
          │    vcpus()       │              │  → cpu->stop = true  │
          │                  │              │  → cpu_exit()        │
          │                  │              │  → cpu_exec() 返回    │
          └──────────────────┘              └──────────────────────┘
```

### 8.6 线程模型对比

| 模式 | 描述 | 文件 | vCPU 锁 |
|------|------|------|---------|
| **MTTCG** (默认) | 多 vCPU 线程并行 | `tcg-accel-ops-mttcg.c` | 执行时不持有 BQL |
| **RR (单线程)** | 所有 vCPU 轮流在一个线程 | `tcg-accel-ops-rr.c` | 始终持有 BQL |
| **KVM** | 每个 vCPU 一个 host 线程 | KVM ioctl | 选择性持有 |

---

## 9. 完整时间线总结

```
时间 →
        
main()  [system/main.c:69]
  │
  ├═ qemu_init()  [system/vl.c:2842]
  │   │
  │   ├─ module_call_init(MODULE_INIT_QOM)     ← 所有 type_init 被调用
  │   ├─ 解析命令行
  │   ├─ qemu_create_machine()                 ← 创建 MachineState 实例
  │   ├─ configure_accelerators()              ← 初始化 TCG
  │   │
  │   └─ qmp_x_exit_preconfig()  [system/vl.c:2802]
  │       │
  │       ├─ qemu_init_board()
  │       │   └─ machine_run_board_init()  [hw/core/machine.c:1668]
  │       │       └─ virt_machine_init()  [hw/riscv/g233.c:1532]
  │       │           ├─ 初始化 SoC 地址映射
  │       │           ├─ 创建 Hart 数组 (CPU 实例化)
  │       │           │   └─ 每个 CPU: object_initialize_child()
  │       │           │                → qdev_realize()
  │       │           │                  → riscv_cpu_realize()
  │       │           │                    → cpu_exec_realizefn()
  │       │           │                      (cpu_list_add, VMState)
  │       │           │                    → qemu_init_vcpu()
  │       │           │                      → mttcg_start_vcpu_thread()
  │       │           │                        → 创建 vCPU 线程
  │       │           │                          (但暂停: cpu->stopped=true)
  │       │           ├─ 创建外设 (PLIC/PL011/VirtIO/PCIe)
  │       │           │   → memory_region_add_subregion()
  │       │           │   → sysbus_realize_and_unref()
  │       │           └─ 注册 virt_machine_done 通知器
  │       │
  │       ├─ qemu_create_cli_devices()         ← -device 设备
  │       │
  │       ├─ qdev_machine_creation_done()  [hw/core/machine.c:1790]
  │       │   ├─ cpu_synchronize_all_post_init()
  │       │   ├─ phase_advance(PHASE_MACHINE_READY)
  │       │   └─ notifier_list_notify(&machine_init_done_notifiers)
  │       │       └─ virt_machine_done()  [hw/riscv/g233.c:1438]
  │       │           ├─ finalize_fdt()
  │       │           ├─ riscv_find_and_load_firmware()  ← OpenSBI
  │       │           ├─ riscv_load_kernel()              ← Kernel
  │       │           ├─ riscv_load_fdt()                 ← DTB
  │       │           └─ riscv_setup_rom_reset_vec()      ← MROM
  │       │               → rom_add_blob_fixed_as()
  │       │                 (写入复位向量到 0x1000)
  │       │
  │       └─ (autostart) qmp_cont() → vm_start()
  │           → resume_all_vcpus()
  │               → cpu->stopped = false
  │               → vCPU 线程: cpu_can_run() = true!
  │
  ├═ qemu_default_main()
  │   └─ qemu_main_loop()                    ← 主线程 I/O 事件循环
  │
  │   vCPU 线程 0: mttcg_cpu_thread_fn()
  │     ├─ cpu_can_run() = true
  │     └─ tcg_cpu_exec() → cpu_exec()
  │         └─ cpu_exec_loop()
  │             ├─ get_tb_cpu_state() → pc = 0x1000
  │             ├─ tb_lookup(0x1000) → MISS
  │             ├─ tb_gen_code(0x1000)     ← 翻译复位向量
  │             │   └─ auipc / csrr / ld / jr
  │             └─ cpu_tb_exec()            ← 执行!
  │                 └─ → 跳转到 OpenSBI (0x80000000)
  │
  │   vCPU 线程 1: (与线程 0 类似的流程)
  │     ...
```

---

## 关键源码位置速查

| 功能 | 文件 | 行号 |
|------|------|------|
| `main()` | `system/main.c` | 69 |
| `qemu_init()` | `system/vl.c` | 2842 |
| `qemu_create_machine()` | `system/vl.c` | 2190 |
| `machine_run_board_init()` | `hw/core/machine.c` | 1668 |
| `qdev_machine_creation_done()` | `hw/core/machine.c` | 1790 |
| `qmp_x_exit_preconfig()` | `system/vl.c` | 2802 |
| `virt_machine_init()` | `hw/riscv/g233.c` | 1532 |
| `virt_machine_done()` | `hw/riscv/g233.c` | 1438 |
| `riscv_find_and_load_firmware()` | `hw/riscv/boot.c` | 136 |
| `riscv_setup_rom_reset_vec()` | `hw/riscv/boot.c` | 432 |
| `riscv_cpu_reset_hold()` (pc = resetvec) | `target/riscv/cpu.c` | 681 |
| `riscv_cpu_realize()` | `target/riscv/cpu.c` | 925 |
| `cpu_exec_realizefn()` | `hw/core/cpu-common.c` | 231 |
| `qemu_init_vcpu()` | `system/cpus.c` | 709 |
| `mttcg_start_vcpu_thread()` | `accel/tcg/tcg-accel-ops-mttcg.c` | 124 |
| `mttcg_cpu_thread_fn()` | `accel/tcg/tcg-accel-ops-mttcg.c` | 65 |
| `vm_start()` → `resume_all_vcpus()` | `system/cpus.c` | 800 |
| `cpu_exec()` | `accel/tcg/cpu-exec.c` | 1019 |
| `cpu_exec_loop()` | `accel/tcg/cpu-exec.c` | 932 |
| `tb_gen_code()` | `accel/tcg/translate-all.c` | 261 |
| `qemu_main_loop()` | `system/runstate.c` | 938 |
| `main_loop_wait()` | `util/main-loop.c` | 563 |

---

*Generated: 2026-06-21 | Source: git@github.com:gevico/qemu-camp-2026-exper-Egg12138.git branch=ai_try commit=27de27e*
