# QEMU 固件/内核加载流程分析 — 以 RISC-V 为例

[TOC]

---

## 1. 架构视角：QEMU 的地址空间模型

```
Guest 视角物理地址空间              QEMU 内部表示
┌─────────────────────┐          ┌─────────────────────┐
│  0x0000~0x0FFF      │          │  MemoryRegion        │
│  (保留)              │          │  (flatview)          │
├─────────────────────┤          ├─────────────────────┤
│  0x1000~0xFFFF      │ ← MROM  │  "mrom.reset"        │
│  复位向量 (10条指令) │          │  rom_add_blob_fixed  │
├─────────────────────┤          ├─────────────────────┤
│  0x100000~0x101000  │ ← SiFive│  sysbus_create       │
│  TEST / RTC         │    Test │  MemoryRegionOps     │
├─────────────────────┤          ├─────────────────────┤
│  0x2000000~...      │ ← CLINT │  MemoryRegionOps     │
│  定时器/软件中断     │         │  + QEMUTimer         │
├─────────────────────┤          ├─────────────────────┤
│  0xC000000~...      │ ← PLIC  │  MemoryRegionOps     │
│  中断控制器          │         │  + pending/enable    │
├─────────────────────┤          ├─────────────────────┤
│  0x10000000~...     │ ← UART  │  MemoryRegionOps     │
│  串口/VirtIO        │  /RTC   │  + chardev           │
├─────────────────────┤          ├─────────────────────┤
│  0x80000000~...     │ ← DRAM  │  machine->ram        │
│  主存储器            │         │  memory_region       │
│  ┌───────────────┐  │         │  (RAM backend)       │
│  │ OpenSBI FW    │  │         │                      │
│  │ (ELF加载)     │  │         │                      │
│  ├───────────────┤  │         │                      │
│  │ Kernel Image  │  │         │                      │
│  │ (ELF/raw)     │  │         │                      │
│  ├───────────────┤  │         │                      │
│  │ initrd        │  │         │                      │
│  ├───────────────┤  │         │                      │
│  │ FDT           │  │         │                      │
│  │ (设备树)      │  │         │                      │
│  └───────────────┘  │         │                      │
└─────────────────────┘          └─────────────────────┘
```

---

## 2. riscv_find_and_load_firmware 分析

### 2.1 调用链

```
virt_machine_done()               [hw/riscv/g233.c:1475]
  │
  └─ riscv_find_and_load_firmware(
         machine,
         riscv_default_firmware_name(&s->soc[0]),  // 默认固件名
         &start_addr,                               // 加载地址
         NULL)                                      // symbol callback
    │
    ├─ riscv_find_firmware(machine->firmware,       // 查找固件文件
    │                      default_firmware_name)
    │   ├─ machine->firmware 已设置? → 直接返回该字符串
    │   ├─ 搜索默认路径 (如 /usr/share/qemu/opensbi-riscv64-generic-fw_dynamic.bin)
    │   └─ 没找到 → 返回 NULL ("none")
    │
    └─ riscv_load_firmware(filename, &load_addr, sym_cb)
        │
        ├─ load_elf_ram_sym()  ← 先尝试 ELF 格式加载
        │   └─ 成功? → 设置 firmware_entry, 返回 firmware_end
        │
        └─ load_image_targphys_as()  ← ELF 失败则作为 raw binary 加载
            └─ 成功? → 返回加载结束地址
```

### 2.2 主谓宾分析

| 要素 | 详情 |
|------|------|
| **主语 (Who)** | `riscv_find_and_load_firmware()` → `riscv_load_firmware()` |
| **谓语 (How)** | `load_elf_ram_sym()` 或 `load_image_targphys_as()` |
| **宾/地址 (Where→Where)** | **host 文件系统 → guest 物理地址空间 (DRAM)** |

**地址到底是什么：**

```
start_addr (即 VIRT_DRAM.base = 0x80000000)

这是 QEMU 的 "guest 物理地址"，对应 MemoryRegion 中的偏移。
在 softmmu 模式下，这个地址直接传给 address_space_rw()，
通过 MemoryRegion 映射关系写入对应的 host 内存后端。

简化的等效: address_space_write(&address_space_memory, 0x80000000,
                                ..., data, size)
             → machine->ram 对应的 host 内存指针
             → memcpy(host_ptr + 0x80000000 - ram_base, data, size)
```

### 2.3 load_elf_ram_sym 内部细节

`hw/core/loader.c:472`

```c
ssize_t load_elf_ram_sym(filename, elf_note_fn, translate_fn, ...) {
    int fd = open(filename, O_RDONLY);          // (1) 打开 host 文件
    read(fd, e_ident, 16);                      // (2) 验证 ELF 魔数

    if (e_ident[EI_CLASS] == ELFCLASS64) {
        ret = load_elf64(...);                  // (3) 64位处理
    } else {
        ret = load_elf32(...);
    }
}
```

`include/hw/elf_ops.h.inc` (被 `loader.c` 在第339行和第361行各 include 一次，分别生成 32/64 位版本)：

```c
// 核心循环: 遍历每个 program header
for (i = 0; i < ehdr.e_phnum; i++) {
    ph = &phdr[i];
    if (ph->p_type == PT_LOAD) {                    // (4) 只加载可加载段
        data_offset = ph->p_offset;                  //      文件中的偏移
        file_size = ph->p_filesz;                    //      文件中的大小
        mem_size = ph->p_memsz;                      //      内存中的大小

        // 确定加载到 guest 物理地址
        if (translate_fn) {
            addr = translate_fn(translate_opaque, ph->p_paddr);  // 地址翻译
        } else {
            addr = ph->p_paddr;                     // (5) 直接使用 p_paddr
        }

        if (load_rom) {                              // (6) load_rom = true
            rom_add_elf_program(label, mapped_file, data,
                                file_size, mem_size, addr, as);
            // → 创建 ROM blob，在 reset 时写入 memory_region
        } else {
            address_space_write(as, addr, ...data, file_size);  // 直接写入
            if (file_size < mem_size) {
                address_space_set(addr+file_size, 0, mem_size-file_size);
            }
        }

        // 处理 entry point：如果 vaddr != paddr，修正 entry
        if (pentry && ph->p_vaddr != ph->p_paddr &&
            ehdr.e_entry >= ph->p_vaddr &&
            ehdr.e_entry < ph->p_vaddr + ph->p_filesz) {
            *pentry = ehdr.e_entry - ph->p_vaddr + ph->p_paddr;
        }
    }
}
```

**为什么 load_rom = true 时不直接写入而是用 rom_add_elf_program？**

因为 `load_rom = true` 表示固件属于 ROM 区域——它应该在每次硬件 reset 时被重新加载到内存中，而不是只在第一次运行时写入。`rom_add_elf_program` 创建一个 "ROM blob" 对象，在 `rom_check_and_register_reset()` 时注册 reset 处理，确保 reset 后固件数据被恢复到目标内存区域。

**对应结构总结：**

```
ELF 文件结构                QEMU 处理
┌────────────────┐         ┌───────────────────────┐
│ ELF Header     │──→      │ ehdr.e_entry          │ → pentry (入口点)
│  e_phnum       │         │ e_phnum 个 program     │
│  e_entry       │         │ header 遍历            │
├────────────────┤         ├───────────────────────┤
│ Program Header │──→      │ ph->p_paddr           │ → guest 物理地址
│  PT_LOAD       │         │ ph->p_vaddr           │ → 虚拟地址 (可能不同)
│  p_paddr       │         │ ph->p_offset          │ → 文件偏移
│  p_vaddr       │         │ ph->p_filesz          │ → 加载大小
│  p_offset      │         │ ph->p_memsz           │ → 内存大小 (≥ filesz)
│  p_filesz      │         └───────────────────────┘
│  p_memsz       │
├────────────────┤
│ Segment Data   │──→      │ mmap → address_space_write(addr)
│  (OpenSBI)     │         │ 或 rom_add_elf_program(addr)
└────────────────┘         └───────────────────────┘
```

---

## 3. 内核加载 (riscv_load_kernel)

```c
// hw/riscv/boot.c:229
void riscv_load_kernel(MachineState *machine, RISCVBootInfo *info,
                        vaddr kernel_start_addr, bool load_initrd,
                        symbol_fn_t sym_cb)
{
    // (1) 尝试 ELF 格式 (返回 > 0 表示成功)
    kernel_size = load_elf_ram_sym(kernel_filename, NULL, NULL, NULL, NULL,
                                    &info->image_low_addr, &info->image_high_addr,
                                    NULL, ELFDATA2LSB, EM_RISCV,
                                    1, 0, NULL, true, sym_cb);
    if (kernel_size > 0) {
        info->kernel_size = kernel_size;
        goto out;
    }

    // (2) ELF 失败→尝试 uImage 格式 (mkimage 打包)
    kernel_size = load_uimage_as(kernel_filename, &info->image_low_addr,
                                  NULL, NULL, NULL, NULL);
    if (kernel_size > 0) {
        goto out;
    }

    // (3) uImage 也失败→作为 raw binary 加载
    kernel_size = load_image_targphys_as(kernel_filename,
                                          kernel_start_addr,
                                          current_machine->ram_size, NULL);
    if (kernel_size > 0) {
        info->image_low_addr = kernel_start_addr;
    }

out:
    if (load_initrd) {
        riscv_load_initrd(machine, info);   // ← 加载 initrd
    }
}
```

**内核加载的地址：**
- `kernel_start_addr = riscv_calc_kernel_start_addr(&boot_info, firmware_end_addr)`
- 计算方式：对齐到 2MB 边界，在固件结束地址之后

---

## 4. initrd 加载分析

```c
// hw/riscv/boot.c:186
static void riscv_load_initrd(MachineState *machine, RISCVBootInfo *info)
{
    // (1) 计算加载位置
    //     "放在 RAM 中间，不超过 512MB"
    start = info->image_low_addr + MIN(mem_size / 2, 512 * MiB);

    // (2) 尝试 cpio 格式
    size = load_ramdisk(filename, start, mem_size - start);
    if (size == -1) {
        // (3) 失败则作为 raw binary
        size = load_image_targphys(filename, start, mem_size - start, NULL);
    }

    info->initrd_start = start;
    info->initrd_size = size;

    // (4) 写入设备树
    qemu_fdt_setprop_u64(fdt, "/chosen", "linux,initrd-start", start);
    qemu_fdt_setprop_u64(fdt, "/chosen", "linux,initrd-end", end);
}
```

**initrd 关键信息：**
- 加载地址：DRAM 的中间点，`image_low_addr + min(ram_size/2, 512MB)`
- 加载方式：`load_ramdisk()` (支持 gzip/cpio) 或 `load_image_targphys()` (raw)
- 地址不固定，通过 FDT 传递给内核

---

## 5. 复位向量与第一条指令

```c
// hw/riscv/boot.c:447
void riscv_setup_rom_reset_vec(MachineState *machine, ...)
{
    uint32_t reset_vec[10] = {
        0x00000297,                  // auipc  t0, 0          ← t0 = PC
        0x02828613,                  // addi   a2, t0, 40     ← a2 = fw_dyn
        0xf1402573,                  // csrr   a0, mhartid    ← a0 = hart ID
        0x0202b583,                  // ld     a1, 32(t0)     ← a1 = fdt addr
        0x0182b283,                  // ld     t0, 24(t0)     ← t0 = firmware addr
        0x00028067,                  // jr     t0              ← 跳转!
        start_addr,                  // 数据: firmware entry
        start_addr_hi32,
        fdt_load_addr,               // 数据: fdt address
        fdt_load_addr_hi32,
    };

    // 写入 MROM MemoryRegion
    rom_add_blob_fixed_as("mrom.reset", reset_vec, sizeof(reset_vec),
                          rom_base, &address_space_memory);
}
```

**地址流完整映射：**

```
host 文件系统                     QEMU 地址空间              Guest CPU
  │                                  │                        │
  ├─ OpenSBI ELF                    │                        │
  │  load_elf_ram_sym()             │                        │
  │  → 解析 PT_LOAD 段              │                        │
  │  → p_paddr = 0x80000000        │                        │
  │  → address_space_write(         │                        │
  │       0x80000000, data)         │                        │
  │       ↓                         │                        │
  │                            ┌────┴──────┐                 │
  │                            │ machine->ram               │
  │                            │ 0x80000000: OpenSBI        │
  │                            │           (2MB)            │
  │                            │ 0x80200000: Kernel         │
  │                            │            (ELF)           │
  │                            │ ...                        │
  │                            │ 0x84000000: initrd         │
  │                            │ ...                        │
  │                            │ top_of_ram: FDT            │
  │                            └──────────────              │
  │                                  │                        │
  ├─ MROM 复位向量                    │                        │
  │  rom_add_blob_fixed("mrom.reset")│                        │
  │  → 0x1000: auipc / jr           │                        │
  │       ↓                         │                        │
  │                            ┌────┴──────┐                 │
  │                            │ mrom (ROM) │                │
  │                            │ 0x1000:    │                │
  │                            │ auipc t0   │                │
  │                            │ jr t0      │                │
  │                            └────────────┘                │
  │                                  │                        │
  │                                  │                        │
  CPU reset → env->pc=0x1000 ────────┼───────────────────────>│
  (resetvec)                         │                        │
                                     │                        │ ① auipc t0
                                     │                        │ ② ld  t0, firmware_entry
                                     │                        │ ③ jr  t0
                                     │                        │
                                     │           0x80000000 ──┼─> ④ OpenSBI 开始
                                     │                        │
```

---

## 6. load_image_targphys_as — 最底层的二进制加载

当 ELF 加载失败时，QEMU 回退到最原始的加载方式：

```c
// hw/core/loader.c
ssize_t load_image_targphys_as(const char *filename,
                                hwaddr addr, uint64_t max_sz,
                                AddressSpace *as)
{
    int fd;
    ssize_t size;

    fd = open(filename, O_RDONLY);          // 打开 host 文件
    size = read(fd, buf, max_sz);           // 读到 host 缓冲区
    close(fd);

    if (size > 0) {
        address_space_write(as ? as : &address_space_memory,
                            addr, MEMTXATTRS_UNSPECIFIED,
                            buf, size);     // 写入 guest 地址空间
    }
    return size;
}
```

**其实就是：`read host_file → memcpy to guest_address_space`**

---

## 7. 关键地址速查 (G233 板级)

| 区域 | 物理地址 | 大小 | 内容 |
|------|---------|------|------|
| MROM | `0x1000` | `0xf000` | 复位向量 (10 条指令) |
| TEST | `0x100000` | `0x1000` | SiFive Test (reboot/poweroff) |
| CLINT | `0x2000000` | `0x10000` | 定时器/软件中断 |
| PLIC | `0xc000000` | ~64MB | 中断控制器 |
| UART0 | `0x10000000` | `0x100` | PL011 串口 |
| VirtIO | `0x10001000` | `0x1000` | VirtIO MMIO 设备 |
| Flash | `0x20000000` | `64MB` | pflash |
| PCIe ECAM | `0x30000000` | `256MB` | PCIe 配置空间 |
| PCIe MMIO | `0x40000000` | `1GB` | PCIe 内存空间 |
| **DRAM** | **`0x80000000`** | **可变** | **主存 (固件+内核+initrd+FDT)** |

---

## 8. 关键源码位置速查

| 函数/组件 | 文件 | 行号 |
|-----------|------|------|
| `riscv_find_and_load_firmware()` | `hw/riscv/boot.c` | 136 |
| `riscv_load_firmware()` | `hw/riscv/boot.c` | 157 |
| `riscv_load_kernel()` | `hw/riscv/boot.c` | 229 |
| `riscv_load_initrd()` | `hw/riscv/boot.c` | 186 |
| `riscv_setup_rom_reset_vec()` | `hw/riscv/boot.c` | 432 |
| `load_elf_ram_sym()` | `hw/core/loader.c` | 472 |
| ELF 段写入核心 | `include/hw/elf_ops.h.inc` | 495-573 |
| `load_image_targphys_as()` | `hw/core/loader.c` | (grep 查找) |
| `virt_machine_done()` (调用者) | `hw/riscv/g233.c` | 1438 |

---

*Generated: 2026-06-21 | Source: git@github.com:gevico/qemu-camp-2026-exper-Egg12138.git branch=ai_try commit=27de27e*
