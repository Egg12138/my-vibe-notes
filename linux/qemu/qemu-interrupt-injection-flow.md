# QEMU 中断控制器与中断注入流程

[TOC]

---

## 1. 中断基础设施：IRQState 与 GPIO 机制

### 1.1 IRQState 结构

`include/hw/core/irq.h:11`

```c
struct IRQState {
    Object parent_obj;           // QOM 对象
    qemu_irq_handler handler;    // 回调函数指针
    void *opaque;               // 回调上下文（通常是设备状态）
    int n;                      // 中断编号
};
```

**`qemu_irq` 本质上是一个指向 `IRQState` 的指针：** `typedef struct IRQState *qemu_irq;`

### 1.2 qemu_set_irq — 中断传递的核心

`hw/core/irq.c:29`

```c
void qemu_set_irq(qemu_irq irq, int level)
{
    if (!irq) return;                       // 未连接时静默忽略
    irq->handler(irq->opaque, irq->n, level); // 调用目标 handler
}
```

**这是整个 QEMU 中断传递的最底层机制。** 无论什么中断控制器（PLIC、GIC、IOAPIC），最终都通过这个函数传递信号。

辅助宏：
```c
qemu_irq_raise(irq)  → qemu_set_irq(irq, 1)    // 电平升高
qemu_irq_lower(irq)  → qemu_set_irq(irq, 0)    // 电平降低
qemu_irq_pulse(irq)  → raise + lower            // 脉冲信号
```

### 1.3 GPIO 连接机制

每个 DeviceState 维护一个 GPIO 命名列表：

```c
// hw/core/gpio.c
// 设备声明输入端
qdev_init_gpio_in(dev, handler, num);       // 声明 num 个输入引脚
// 设备声明输出端
qdev_init_gpio_out(dev, pins, num);         // 声明 num 个输出引脚

// 连接输入和输出
qdev_connect_gpio_out(src_dev, out_n,       // 源设备的第 out_n 个输出
    qdev_get_gpio_in(dst_dev, in_n));       // → 目标设备的第 in_n 个输入
```

引脚的物理表示：
- **输入引脚** (`gpio_list->in[]`)：`IRQState*` 数组，直接存储
- **输出引脚** (`gpio_list->out[]`)：`qemu_irq*` 数组，通过 QOM link property 连接到目标设备的输入

连接的本质：
```
设备A的输出引脚[n]  ──link property──→  设备B的输入引脚[n] (IRQState*)
                                                │
设备A: qemu_set_irq(out[n], level) ───────────→ handler(opaque, n, level)
```

---

## 2. 完整的连线示例：PLIC 创建过程

```
  外部设备 (UART/RTC/virtio)     PLIC 中断控制器                RISC-V CPU
  ─────────────────────         ──────────────────          ───────────
  
  pl011_create(addr, irq):        qdev_init_gpio_in(         qemu_set_irq(
      ↓                             sifive_plic_irq_request,    m_external_irqs[n],
  qdev_get_gpio_in(plic, uart_irq)  num_sources)                 level)
                    │                     │                          │
                    │                ┌─────┴──────┐                  │
                    ▼                ▼            ▼                  ▼
              sifive_plic_       pending[]     enable[]          CPU核心的
              irq_request()    位图数组       位图数组           中断输入
  
  sifive_plic_create() 中最后的连线:
    qdev_connect_gpio_out(plic, cpu_num - base + num_harts,       ← M-mode 输出
        qdev_get_gpio_in(DEVICE(cpu), IRQ_M_EXT))                  → CPU 输入
    qdev_connect_gpio_out(plic, cpu_num - base,                    ← S-mode 输出
        qdev_get_gpio_in(DEVICE(cpu), IRQ_S_EXT))                  → CPU 输入
```

### 来自 virt_machine_init 的典型调用：

```c
// 在 g233.c 中:
// 1. 创建 PLIC
s->irqchip[i] = virt_create_plic(memmap, i, base_hartid, hart_count);

// 2. 创建设备，将中断线连接到 PLIC
sysbus_create_simple("virtio-mmio", base, 
    qdev_get_gpio_in(virtio_irqchip, VIRTIO_IRQ + i));  // ← 外设中断 → PLIC

pl011_create(memmap[VIRT_UART0].base,
    qdev_get_gpio_in(mmio_irqchip, UART0_IRQ),           // ← UART中断 → PLIC
    serial_hd(0));
```

---

## 3. PLIC (Platform Level Interrupt Controller) 实现

### 3.1 核心数据结构

```c
// include/hw/intc/sifive_plic.h:45
struct SiFivePLICState {
    SysBusDevice parent_obj;
    MemoryRegion mmio;               // MMIO 区域 (guest 通过 MEM 访问)

    // PLIC 内部状态
    uint32_t *source_priority;       // 每个中断源的优先级 (0-7)
    uint32_t *target_priority;       // 每个目标 (hart+mode) 的阈值
    uint32_t *pending;               // 挂起位图 (按源)
    uint32_t *claimed;               // 已领取位图 (避免重复分发)
    uint32_t *enable;                // 使能位图 (按目标 × 源)

    // 连线到 CPU 的输出
    qemu_irq *m_external_irqs;       // M-mode 外部中断线 × num_harts
    qemu_irq *s_external_irqs;       // S-mode 外部中断线 × num_harts
};
```

### 3.2 中断生命周期

```
阶段 1: 设备断言中断
  外设 MMIO 写入 → MemoryRegionOps → 设备内部状态变化
      ↓
  qemu_set_irq(plic_input, level)   ← 外设输出线跳变
      ↓
  sifive_plic_irq_request()         ← PLIC 的 GPIO 输入回调
  
阶段 2: PLIC 记录与裁决
  sifive_plic_irq_request() {
      sifive_plic_set_pending(plic, irq, true);  // pending[irq>>5] 置位
      sifive_plic_update(plic);                   // 重新评估
  }
  
  sifive_plic_update() {
      for (每个 addrid) {
          max_irq = sifive_plic_claimed();        // 找最高优先级未被领取的中断
          // claimed: pending & ~claimed & enable, 取优先级最高者
          qemu_set_irq(m_external_irqs[hart], level);  // → CPU
      }
  }

阶段 3: CPU 接收并处理 (见下一节)
  
阶段 4: guest 读取中断
  guest 读 claim 寄存器 (context_base + 4) → sifive_plic_read():
      max_irq = sifive_plic_claimed();           // 返回最高优先级中断
      sifive_plic_set_pending(plic, max_irq, false);  // 清除 pending
      sifive_plic_set_claimed(plic, max_irq, true);   // 标记 claimed
      return max_irq;

阶段 5: guest 完成处理
  guest 写 complete 寄存器 (context_base + 4):
      sifive_plic_set_claimed(plic, irq, false);  // 清除 claimed
      sifive_plic_update(plic);                    // 重新评估 (可能分发下一个)
```

---

## 4. 中断注入 CPU 核心

### 4.1 PLIC → CPU 的连线

```c
// hw/intc/sifive_plic.c:506-518  (sifive_plic_create)
for (i = 0; i < plic->num_addrs; i++) {
    int cpu_num = plic->addr_config[i].hartid;
    CPUState *cpu = qemu_get_cpu(cpu_num);             // 按 hart ID 找 CPU

    if (mode == PLICMode_M) {
        qdev_connect_gpio_out(dev, addr_id + num_harts,
            qdev_get_gpio_in(DEVICE(cpu), IRQ_M_EXT)); // M 模式外部中断
    }
    if (mode == PLICMode_S) {
        qdev_connect_gpio_out(dev, addr_id,
            qdev_get_gpio_in(DEVICE(cpu), IRQ_S_EXT)); // S 模式外部中断
    }
}
```

### 4.2 RISC-V CPU 中断输入处理

CPU 在 `qdev_init_gpio_in()` 中注册的处理函数是 `riscv_cpu_set_irq()`：

```c
// target/riscv/cpu_helper.c:722
void riscv_cpu_interrupt(CPURISCVState *env)
{
    CPUState *cs = env_cpu(env);
    BQL_LOCK_GUARD();

    if (env->mip | vsgein | vstip | irqf) {          // 任何待处理中断?
        cpu_interrupt(cs, CPU_INTERRUPT_HARD);        // → 设置 TCG 中断标志
    } else {
        cpu_reset_interrupt(cs, CPU_INTERRUPT_HARD);  // → 清除 TCG 中断标志
    }
}

// target/riscv/cpu_helper.c:746
uint64_t riscv_cpu_update_mip(CPURISCVState *env, uint64_t mask, uint64_t value)
{
    env->mip = (env->mip & ~mask) | (value & mask);   // 更新 mip CSR
    riscv_cpu_interrupt(env);                          // 检查是否需要注入
    return old;
}
```

**关键寄存器操作：**
| 寄存器 | 操作 | 含义 |
|--------|------|------|
| `env->mip` | 被 `riscv_cpu_update_mip` 修改 | **MIP (Machine Interrupt Pending)** — 记录哪些中断挂起 |
| `env->mie` | 被 `csr_write(mie)` 修改 | **MIE (Machine Interrupt Enable)** — 记录哪些中断使能 |
| `cpu->interrupt_request` | 被 `cpu_interrupt()` 置位 | **TCG 内部标志** — 通知 vCPU 调度器退出 TB 并检查 |
| `CPU_INTERRUPT_HARD` | 被 `cpu_interrupt()` 设置 | 表示有硬件中断需要处理 |

### 4.3 TCG 执行循环中断检查

```
vCPU 执行路径:
  mttcg_cpu_thread_fn()
    ↓
  tcg_cpu_exec() → cpu_exec() → cpu_exec_loop()
    ↓
  while (!cpu_handle_interrupt()):
    │
    ├─ cpu_interrupt_request & CPU_INTERRUPT_HARD
    │     ↓
    ├─ tcg_ops->cpu_exec_interrupt(cpu, request)
    │     ↓  (RISC-V)
    ├─ riscv_cpu_exec_interrupt()
    │     ↓
    ├─ riscv_cpu_local_irq_pending(env)    ← 查询 pending & mie
    │     ↓
    ├─ cs->exception_index = intno
    │     ↓
    ├─ riscv_cpu_do_interrupt(cs)          ← 真正注入中断
    │     ↓
    └─ return true  → 退出到主循环
```

### 4.4 中断注入到 CPU 的最后一步

```c
// target/riscv/cpu_helper.c:2153
void riscv_cpu_do_interrupt(CPUState *cs)
{
    // 1. 确定中断类型和委托级别
    bool async = cs->exception_index & RISCV_EXCP_INT_FLAG;  // 异步?
    target_ulong cause = cs->exception_index & RISCV_EXCP_INT_MASK;  // 中断号
    uint64_t deleg = async ? env->mideleg : env->medeleg;    // 委托掩码

    // 2. 决定跳转到哪个特权级 (Machine, Supervisor, VS)
    if (deleg & (1ULL << cause)) {
        // 委托 → S 模式处理
        // 保存 sepc, scause, stval, sstatus
        env->sepc = env->pc;
        env->scause = (async << (mxlen - 1)) | cause;
        env->priv = PRV_S;
    } else {
        // 不委托 → M 模式处理
        // 保存 mepc, mcause, mtval, mstatus
        env->mepc = env->pc;
        env->mcause = (async << (mxlen - 1)) | cause;
        env->priv = PRV_M;
    }

    // 3. 关闭中断 (mie → mstatus.MIE)
    // 4. 设置 PC 到 MTVEC/STVEC
    env->pc = env->stvec;  // 或 mtvec
}
```

---

## 5. 完整中断注入路径总结

```
设备 MMIO 写入                  Guest 内存地址空间
      │                              │
      ▼                              │
  device_ops->write()                │
      │                              │
      ▼                              │
  qemu_set_irq(irq, 1)              │
      │                              │
      ▼                              │
  sifive_plic_irq_request()          │  ← PLIC GPIO in handler
      │                              │
      ├─ pending[irq] = 1           │
      └─ sifive_plic_update()        │
            │                        │
            ▼                        │
        找出最高优先级中断            │
            │                        │
            ▼                        │
        qemu_set_irq(m_external, 1)  │  ← PLIC GPIO out → CPU GPIO in
            │                        │
            ▼                        │
        riscv_cpu_interrupt()        │  ← CPU GPIO in handler
            │                        │
            ├─ env->mip 已更新       │
            └─ cpu_interrupt(CPU_INTERRUPT_HARD)
                  │                  │
                  ▼                  │
              TCG 退出当前 TB        │
                  │                  │
                  ▼                  │
            cpu_exec_loop()          │
              detects interrupt      │
                  │                  │
                  ▼                  │
            riscv_cpu_exec_interrupt()│
                  │                  │
                  ├─ riscv_cpu_local_irq_pending()
                  ├─ cs->exception_index = cause
                  └─ riscv_cpu_do_interrupt()
                        │
                        ├─ 保存 mepc = env->pc
                        ├─ mcause = cause
                        ├─ 关闭中断 (MIE)
                        ├─ env->priv = PRV_M
                        └─ env->pc = mtvec
                              │
                              ▼
                    内核的 trap handler 开始执行
                        (Linux: handle_arch_irq)
                              │
                              │ 读 claim 寄存器 (MMIO)
                              ▼
                        sifive_plic_read(claim)
                          → 返回中断号 max_irq
                          → 清除 pending
                          → 写 complete (MMIO)
```

---

## 6. RISC-V AIA (APLIC + IMSIC) 简介

G233 板级支持三种中断架构：

| 模式 | 中断控制器 | 描述 |
|------|-----------|------|
| `aia=none` | **PLIC** | 传统线中断聚合 |
| `aia=aplic` | **APLIC** | 可升级的中断控制器（PLIC 的替代） |
| `aia=aplic-imsic` | **APLIC + IMSIC** | 完整的 MSI 中断架构 |

**APLIC** 负责线中断聚合（类似 PLIC），支持两种模式：
- **Direct mode**：类似 PLIC，直接分发到 hart
- **MSI mode**：将线中断转换为 MSI，通过 IMSIC 发送

**IMSIC** (Incoming MSI Controller) 负责 MSI 中断：
- 每个 hart 有独立的 MMIO 页面
- 通过 PCIe MSI/MSI-X 写入门铃地址触发
- 支持一级 guest (S 模式) 中断虚拟化

---

## 7. 关键源码位置速查

| 组件 | 文件 | 行号 |
|------|------|------|
| `IRQState` 结构 | `include/hw/core/irq.h` | 11 |
| `qemu_set_irq()` | `hw/core/irq.c` | 29 |
| GPIO 输入/输出声明 | `hw/core/gpio.c` | 43-102 |
| GPIO 连接/获取 | `hw/core/gpio.c` | 112-172 |
| SiFive PLIC 连接 | `hw/intc/sifive_plic.c` | 476-521 |
| 中断输入回调 | `hw/intc/sifive_plic.c` | 353-361 |
| PLIC 裁决 update | `hw/intc/sifive_plic.c` | 115-136 |
| `riscv_cpu_interrupt()` | `target/riscv/cpu_helper.c` | 722-744 |
| `riscv_cpu_update_mip()` | `target/riscv/cpu_helper.c` | 746-760 |
| `riscv_cpu_exec_interrupt()` | `target/riscv/cpu_helper.c` | 547-562 |
| `riscv_cpu_do_interrupt()` | `target/riscv/cpu_helper.c` | 2153 |
| `cpu_handle_interrupt()` | `accel/tcg/cpu-exec.c` | 777-882 |
| `cpu_exec_interrupt` (TCG ops) | `target/riscv/tcg/tcg-cpu.c` | 280 |

---

*Generated: 2026-06-21 | Source: git@github.com:gevico/qemu-camp-2026-exper-Egg12138.git branch=ai_try commit=27de27e*
