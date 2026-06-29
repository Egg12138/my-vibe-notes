# cpu modeling

# memory regions

## layout

如下输出是我们 QEMU info mtree 所打印出来的 Memory Region 布局图。

我们可以看到，整个 MTree 其实都在一个 System 的根节点下面，而每一个 Address Space 就是 System 下的一个子节点。每个 Address Space 下面有一片（若干个）内存区域的映射，它们把这一片区域划成小块，每一块会映射到一个语义。

这些语义包含：
1. Priority（优先级）
2. 类型选择（RAM 或者是 I/O）
3. 描述

最后，这些语义会对应到它的具体描述。

这个映射的完整语义是：

> QEMU 在 GPA 上把一个地址区间映射到某个 MemoryRegion（设备或内存后端）。这是一个地址区间 → 资源（RAM/ROM/设备寄存器/别名）的映射表
> 告诉 VM 当 CPU 访问该地址时，哪一段后端会响应以及以什么方式响应。

```
(qemu) info mtree
address-space: I/O
  0000000000000000-000000000000ffff (prio 0, i/o): io

address-space: gpex-root
  0000000000000000-ffffffffffffffff (prio 0, i/o): bus master container

address-space: cpu-memory-0
address-space: memory
  0000000000000000-ffffffffffffffff (prio 0, i/o): system
    0000000000001000-000000000000ffff (prio 0, rom): riscv_virt_board.mrom
    0000000000100000-0000000000100fff (prio 0, i/o): riscv.sifive.test
```

* `addA -- addB` 
物理地址区间（包含端点），单位是 64 位地址空间的十六进制或十进制表示。表示 guest 物理地址从 addA 到 addB 被某个 MemoryRegion 占用/拦截。

* `(prio N, TYPE)`

  - prio N：优先级（priority）。当多个 region 有重叠时，优先级高的 region 会先处理访问。优先级用于解决重叠或 alias 的冲突。

  - TYPE：表示该 region 的属性，常见值有：

    - ram：真实的可读写内存（DRAM 后端）。

    - i/o：MMIO/设备寄存器（不是普通 RAM，访问会被设备回调处理）。

    - rom / romd：只读固件或 flash（ROM 映射，romd 表示 ROM device）。


* name（例如 virtio-mmio、serial、riscv_virt_board.mrom）
该地址区间对应的 MemoryRegion 名称或设备标识，通常能告诉你后端是什么（platform device、virtio、flash、PLIC、serial 等）。

* alias ... @xxx  
表示这是一个 别名映射：该区间并不直接有独立后端，而是把访问转发/别名到另一个 MemoryRegion（例如把高位的 pcie-mmio alias 到 gpex_mmio_window）。alias 常用于把同一段物理窗口在不同地址范围呈现给 guest。

例子：

> 写xx 到一个 MMIO 外设寄存器：Guest 内核通过写一个物理地址（例如 0x10001000）向 QEMU 中的 virtio‑mmio 设备发送控制命令或数据，触发设备状态变化并可能产生中断。

1. CPU 计算并发出访存请求

> 内核或驱动执行一条写指令，目标是物理地址 0x10001000（假设该地址在 QEMU 的 virtio‑mmio 区间内）。QEMU CPU 将地址与写数据放到地址/数据总线上并发出写控制信号。

2. QEMU 地址解码（FlatView 路由）

> QEMU 使用事先生成的FlatView，通过二分查找或缓存快速定位哪个 MemoryRegion 负责该地址。FlatView 是由 MemoryRegion 树降维并按地址/优先级整理得到的高性能路由表。QEMU 找到 0x10001000 属于 virtio‑mmio 的 MemoryRegion。

3. MemoryRegion 调用对应的读写回调

> 找到对应的 MemoryRegion 后，QEMU 调用该 region 的 write 回调（MemoryRegionOps），把写入的数据传递给设备模拟代码（例如 virtio‑mmio 的实现）。设备模拟代码根据寄存器偏移解析命令并更新内部状态或环形队列。

4. 设备产生副作用（例如触发中断或通知后端）

> 如果写操作是“提交一个描述符”或“写入通知寄存器”，virtio 模拟层会把事件转发给后端（宿主侧的 virtio 后端），并可能通过 QEMU 模拟的中断控制器（在 RISC‑V 是 PLIC，在 x86 是 APIC）向 Guest CPU 发起中断。QEMU 会通过相应的中断 MemoryRegion/IRQ 路径把中断注入到虚拟 CPU。

5. Guest 内核响应中断并处理设备事件

> Guest 内核中断处理程序运行，驱动读取设备寄存器（再次通过 MMIO 读），处理完成的描述符或读取返回数据，最终把数据交给上层（例如把串口字符放入 tty 缓冲区或把文件系统数据交给 VFS）。驱动对 MMIO 的访问在内核中通常通过 ioremap()（或 PCI 驱动通过 BAR 自动映射）完成


---

对于prio字段，

```
0x80000   0x70000  0x60000  0x50000  0x40000  0x30000  0x20000  0x10000    0
  |--------|--------|--------|--------|--------|--------|--------|--------|
A:[-----------------------------------------------------------------------] prio:0
B:[-----------------------------------------------------] prio:1
C:[-----------------------------------] prio:2
D:[-----------------] prio:3
对于 mr A 来说，它的地址范围可以看成：


0x80000   0x70000  0x60000  0x50000  0x40000  0x30000  0x20000  0x10000    0
  |--------|--------|--------|--------|--------|--------|--------|--------|
A:[DDDDDDDDDDDDDDDDD|CCCCCCCCCCCCCCCCC|BBBBBBBBBBBBBBBBB|AAAAAAAAAAAAAAAAA]
[A-only] | [B-overrides] | [C-overrides] | [D-overrides] | [C-overrides] | [B-overrides] | [A-only]

```

> QEMU 使用 alias 来描述 mr 中重叠的部分，使用 alias 可以将一个 mr 的一部分放到另外一个 mr 上，以此来简化内存模拟的复杂度（可以类比 mmap）。

这里的语义是说，如果我访问了 0x8000 到 0x7000 这一段，在没有 BCD 的情况下，访问到的是设备 A。但由于 BCD 的优先级都比 A 高，所以当访问这片区域时，就会访问 BCD 中优先级最高的 D

## flow

```
main -> qemu_init -> qemu_create_machine -> cpu_exec_init_all -> {io_mem_init();memory_map_init();}

|--io_mem_init()
|  |--memory_region_init_io(&io_mem_unassigned, NULL, &unassigned_mem_ops, NULL, NULL, UINT64_MAX)
|  |--memory_map_init()
|  |  |--memory_region_init(system_memory, NULL, "system", UINT64_MAX)
|  |  |--address_space_init(&address_space_memory, system_memory, "memory")
|  |  |--memory_region_init_io(system_io, NULL, &unassigned_io_ops, NULL, "io", 65536)
|  |  |--address_space_init(&address_space_io, system_io, "I/O")
```

address-space 内有一个 root 字段，指向 memory-region 的根节点，这样就实现了一个 address-space 对应一个 memory-region 树，如下：


```
                        AddressSpace
                   +-------------------------+
                   |name                     |
                   |   (char *)              |
                   |                         |     MemoryRegion(system_memory/system_io)
                   +-------------------------+          +------------------------+
                   |root                     |          |subregions              |
                   |   (MemoryRegion *)      | -------->|    QTAILQ_HEAD()       |
                   +-------------------------+          +------------------------+
                                                                     |
                                                                     |
                                                 +-------------------+---------------------+
                                                 |                                         |
                                      struct MemoryRegion                          struct MemoryRegion
                                      +------------------------+                   +------------------------+
                                      |subregions              |                   |subregions              |
                                      |    QTAILQ_HEAD()       |                   |    QTAILQ_HEAD()       |
                                      +------------------------+                   +------------------------+
```
每个 mr 会对应到具体的内存块 RAMBlock（QEMU 内部用于管理一段宿主机内存的数据结构，通常通过 mmap 分配，记录了大小、偏移和宿主机虚拟地址等信息），这个内存块从 Host 申请，作为 Guest 外围设备的存储。

那么，这个tree又是怎样变成flatview的？

> 这棵memory region多叉树会通过 QEMU 的 generate_memory_topology 等一系列算法，根据节点的绝对地址范围和优先级进行动态的计算与裁剪，最终被拍扁成一个一维的平坦视图


```c
/* Flattened global view of current active memory hierarchy.  Kept in sorted
 * order.
 */
struct FlatView {
    struct rcu_head rcu; // head is a RCU!
    unsigned ref;
    FlatRange *ranges;
    unsigned nr;
    unsigned nr_allocated;
    struct AddressSpaceDispatch *dispatch;
    MemoryRegion *root;
};


typedef struct FlatView FlatView
/* Render a memory topology into a list of disjoint absolute ranges. */
static FlatView *generate_memory_topology(MemoryRegion *mr)
{
    int i;
    FlatView *view;

    view = flatview_new(mr);

    if (mr) {
        render_memory_region(view, mr, int128_zero(),
                             addrrange_make(int128_zero(), int128_2_64()),
                             false, false, false);
    }
    flatview_simplify(view);

    view->dispatch = address_space_dispatch_new(view);
    for (i = 0; i < view->nr; i++) {
        MemoryRegionSection mrs =
            section_from_flat_range(&view->ranges[i], view);
        flatview_add_to_dispatch(view, &mrs);
    }
    address_space_dispatch_compact(view->dispatch);
    g_hash_table_replace(flat_views, mr, view);

    return view;
}
```

整体生命周期 DataFlow 图

```
   MemoryRegion 树变化
     │
     ├─ memory_region_transaction_begin()  // 开始批量修改
     │
     ├─ memory_region_add_subregion / set_enabled / set_size / etc.
     │      └─ 设置 memory_region_update_pending = true
     │
     └─ memory_region_transaction_commit()
            │
            ├─ flatviews_reset()
            │      ├─ 重建 flat_views 哈希表
            │      └─ 为每个 AddressSpace 的 physmr 调用 generate_memory_topology()
            │             └─ 构造新的 FlatView (含 dispatch)
            │
            ├─ MEMORY_LISTENER_CALL_GLOBAL(begin)
            │
            ├─ 对每个 AddressSpace:
            │      └─ address_space_set_flatview(as)
            │             ├─ address_space_update_topology_pass(old, new, del)  // 删旧
            │             ├─ address_space_update_topology_pass(old, new, add)  // 加新
            │             └─ qatomic_rcu_set(&as->current_map, new_view)        // 原子切换
            │
            ├─ address_space_update_ioeventfds(as)
            │
            └─ MEMORY_LISTENER_CALL_GLOBAL(commit)

```

整体 DataFlow 总结：
1. MR 树变更 → 标记 pending
2. Transaction commit → 重新 generate_memory_topology 渲染所有物理 MR 树为 FlatView
3. 地址空间切换 → 通过两遍 pass 通知 MemoryListener 新旧差异
4. RCU 切换 → 读者原子看到新 FlatView，旧 FlatView 在引用归零后 RCU 延迟释放
5. 访问路径 → as->current_map → dispatch → 多级页表 → MemoryRegionSection → MR 操作


这是细枝末节了；

我们看qom-tree,它可以可mr对应起来：

```

(qemu) info qom-tree
/machine (virt-machine)
  /fw_cfg (fw_cfg_mem)
    /\x2from@etc\x2facpi\x2frsdp[0] (memory-region)
    /\x2from@etc\x2facpi\x2ftables[0] (memory-region)
    /\x2from@etc\x2ftable-loader[0] (memory-region)
    /fwcfg.ctl[0] (memory-region)
    /fwcfg.data[0] (memory-region)
    /fwcfg.dma[0] (memory-region) ### 都只有一个, hence index=0
    #####
    0000000010100000-0000000010100007 (prio 0, i/o): fwcfg.data
    0000000010100008-0000000010100009 (prio 0, i/o): fwcfg.ctl
    0000000010100010-0000000010100017 (prio 0, i/o): fwcfg.dma
    #####
  /peripheral (container)
  /peripheral-anon (container)
  /soc0 (riscv.hart_array)
    /harts[0] (rv64-riscv-cpu)



```
