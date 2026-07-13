# QOM

TODO

关键宏：

```c
/**
 * OBJECT_DECLARE_TYPE:
 * @InstanceType: instance struct name
 * @ClassType: class struct name
 * @MODULE_OBJ_NAME: the object name in uppercase with underscore separators
 *
 * This macro is typically used in a header file, and will:
 *
 *   - create the typedefs for the object and class structs
 *   - register the type for use with g_autoptr
 *   - provide three standard type cast functions
 *
 * The object struct and class struct need to be declared manually.
 */
#define OBJECT_DECLARE_TYPE(InstanceType, ClassType, MODULE_OBJ_NAME) \
    typedef struct InstanceType InstanceType; \
    typedef struct ClassType ClassType; \
    \
    G_DEFINE_AUTOPTR_CLEANUP_FUNC(InstanceType, object_unref) \
    \
    DECLARE_OBJ_CHECKERS(InstanceType, ClassType, \
                         MODULE_OBJ_NAME, TYPE_##MODULE_OBJ_NAME)
```

会定义 

* `typedef struct #InstanceType #InstanceType`
* `typedef struct #ClassType #ClassType`
* `object checkers`
* `g_autoptr_cleanup_func: object_unref`

其中

autoptr:

有一个通用的 Deref(unref) 函数：

```c
void object_unref(void *objptr)
{
    Object *obj = OBJECT(objptr);
    if (!obj) {
        return;
    }
    g_assert(obj->ref > 0);

    /* parent always holds a reference to its children */
    if (qatomic_fetch_dec(&obj->ref) == 1) {
        object_finalize(obj);
    }
}
```

```c

#define G_DEFINE_AUTOPTR_CLEANUP_FUNC(TypeName, cleanup_func) \
  _GLIB_DEFINE_AUTOPTR_CLEANUP_FUNCS(TypeName, TypeName, cleanup_func)
#define _GLIB_DEFINE_AUTOPTR_CLEANUPS(TypeName, ParentName, cleanup_func) \
  typedef TypeName *_GLIB_AUTOPTR_TYPENAME(TypeName);                                                           \
  typedef GList *_GLIB_AUTOPTR_LIST_TYPENAME(TypeName);                                                         \
  typedef GSList *_GLIB_AUTOPTR_SLIST_TYPENAME(TypeName);                                                       \
  typedef GQueue *_GLIB_AUTOPTR_QUEUE_TYPENAME(TypeName);                                                       \
  G_GNUC_BEGIN_IGNORE_DEPRECATIONS                                                                              \
  static G_GNUC_UNUSED inline void _GLIB_AUTOPTR_CLEAR_FUNC_NAME(TypeName) (TypeName *_ptr)                     \
    { if (_ptr) (cleanup) ((ParentName *) _ptr); }                                                              \
  static G_GNUC_UNUSED inline void _GLIB_AUTOPTR_FUNC_NAME(TypeName) (TypeName **_ptr)                          \
    { _GLIB_AUTOPTR_CLEAR_FUNC_NAME(TypeName) (*_ptr); }                                                        \
  static G_GNUC_UNUSED inline void _GLIB_AUTOPTR_LIST_FUNC_NAME(TypeName) (GList **_l)                          \
    { g_list_free_full (*_l, (GDestroyNotify) (void(*)(void)) cleanup); }                                       \
  static G_GNUC_UNUSED inline void _GLIB_AUTOPTR_SLIST_FUNC_NAME(TypeName) (GSList **_l)                        \
    { g_slist_free_full (*_l, (GDestroyNotify) (void(*)(void)) cleanup); }                                      \
  static G_GNUC_UNUSED inline void _GLIB_AUTOPTR_QUEUE_FUNC_NAME(TypeName) (GQueue **_q)                        \
    { if (*_q) g_queue_free_full (*_q, (GDestroyNotify) (void(*)(void)) cleanup); }                             \
  G_GNUC_END_IGNORE_DEPRECATIONS
```




# TCGTB

## TB 到底是啥

> TCG = Tiny Code Generator，QEMU 的动态二进制翻译引擎。
> 工作流：guest code → TCG IR（中间表示）→ host 机器码

**TB = Translation Block**，TCG 的核心抽象。
**是一段 guest 指令被翻译成 host 机器码之后的缓存单元。** QEMU 不逐条翻译指令，而是以"基本块"为单位——一段顺序执行、没有分支的指令序列——整块翻译、整块缓存、整块执行。

所以核心三板斧就是：

1. **翻译** guest asm → TCG IR → host asm
2. **缓存** 把翻译结果存在 code_gen_buffer 里，下次直接用
3. **复用** 走到同一个 PC 时，查表命中就直接跑缓存里的 host 码

---

## 七大核心操作

### 1. tb_lookup — 查找已有 TB

查一下这个 PC 有没有翻译过。


为了快，QEMU 搞了两层缓存：

```
CPUJumpCache (per-CPU 小哈希，无锁)
    └─ 命中？→ 直接返回 TB
    └─ 未命中 → tb_htable_lookup() 查全局 QHT（无锁并发哈希表）
                  └─ 命中？→ 写回 CPUJumpCache，下次走快速路径
                  └─ 未命中 → 返回 NULL，准备翻译
```


> lookup 的检索目标是什么
> `PC --> hash`, 转换就是 `pc ^ (pc >> TB_JUMP_CACHE_BITS) & (TB_JUMP_CACHE_SIZE - 1)`
> `cpu->tb_jmp_cache->array[hash].tb`

> `tb_htable_lookup` 的匹配条件是五元组：`phys_pc + pc + cs_base + flags + cflags`，其中 `phys_pc` 是物理页地址。这意味着即使虚拟地址不同，只要物理页 + 上下文一致，就能命中同一个 TB——尤其 CF_PCREL 模式下跑得更欢。

### 2. tb_gen_code — 翻译生成新 TB

`tb_lookup` 返回 NULL 时触发：

```
guest PC
    │
    ▼
cpu->cc->tcg_ops->translate_code()  ← guest 指令 → TCG IR
    │
    ▼
tcg_gen_code()                       ← TCG IR → host 机器码
    │
    ▼
code_gen_buffer（可执行内存段）
```

同时也初始化 TB 的跳转链表（`jmp_list_head`、`jmp_dest[2]`），为后面的 chaining 做准备。

注意 `tb_gen_code` 里面用了 `setjmp`/`longjmp` 处理各种翻车：
- **-1**：code_gen_buffer 溢出 → flush 后重试
- **-2**：生成的代码太大 → guest 指令数砍半重试
- **-3**：页锁冲突 → 解锁后重试

### 3. tb_link_page — 注册到全局

翻译好了不能白干，得注册到系统里让后面能查到：

```
tb_link_page(tb)
    ├── tb_record(tb)              → 挂到对应物理页的 PageDesc 链表
    └── qht_insert(&tb_ctx.htable) → 插入全局哈希表
```

如果插入时发现别人已经插了一样的 TB（并发场景），就丢掉自己新生成的，用现有的。

### 4. tb_add_jump — TB 链接（chaining）

这是 QEMU 性能最关键的优化。没有它的话，每个 TB 执行完都要退回到 QEMU 调度器，再查下一个 TB，再跳过去——全是开销。

有了 chaining：**TB_A 末尾直接 patch 一条 `jmp` host 指令，指向 TB_B 的 host 码**。CPU 从 TB_A 到 TB_B 就是一条 native jump，零软件开销。

```
tb_add_jump(tb, n, tb_next):
  1. 检查 tb_next 没有被 invalidate
  2. CAS 抢占 tb->jmp_dest[n] 槽位（每个 TB 有两个外出跳槽位）
  3. patch native jmp 指令（tb_set_jmp_target）
  4. 把自己加入 tb_next 的入跳链表（方便后面做失效反向遍历）
```

### 5. cpu_tb_exec — 执行

就是把 `tb->tc.ptr` 指向的那段 host 机器码当成函数来调用。执行完返回一个 `exit_reason`，告诉上层是正常结束、中断 pending、还是单步调试。

### 6. tb_invalidate — 失效

当 guest 自修改代码、插入断点、或跨页映射变化时，受影响范围的 TB 必须失效。

```
tb_phys_invalidate__locked(tb):
  1. tb->cflags |= CF_INVALID       → 标记无效
  2. 遍历 jmp_list_head             → 把所有跳进来的 caller 的 jump 都 patch 成 no-op
  3. 从 PageDesc 链表和 QHT 中移除
```

### 7. tb_flush — 全量清空

code_gen_buffer 用满了或遇到重大上下文切换时，全部推倒重来：

```
do_tb_flush:
  ├── 清 per-CPU 的 jmp_cache
  ├── 清全局 QHT（qht_reset_size）
  ├── 清 PageDesc 链表（tb_remove_all）
  └── 重置 code_gen_buffer（tcg_region_reset_all）
```

---

## 执行主循环

把这些操作串起来就是 TB 的完整生命流程：

```
tb_find_fast(cpu, s):
    │
    ├─ tb_lookup(cpu, s)          ← 查缓存
    │   └─ 命中 → 跳到执行
    │
    └─ 未命中：
        ├─ tb_gen_code(cpu, s)    ← 翻译
        ├─ tb_link_page(tb)       ← 注册
        |
        ├─ tb_add_jump(last_tb, n, tb)  ← 尝试链到前一 TB
        └─ cpu_tb_exec(cpu, tb)   ← 执行
```

每次 TB 执行完返回的 exit_reason 决定下一轮是继续链式执行、还是退回到外层调度器处理中断/异常。

**TCG 非抢占**——中断在 TB 边界才被采样，不会在 TB 中间打断。所以同步异常（ECALL、缺页）比异步中断贵得多，因为它们会在 TB 中间截断，之前翻译的工作白干了。

# memory regions

## layout

`info mtree` 打出来长这样：

MTree 整个挂在 System 这个根节点下面，每个 Address Space 就是 System 的一个子节点。然后每个 Address Space 下面有一堆映射，把地址空间切成一小块一小块，每一块指向一个 MemoryRegion，顺带标上：

1. 优先级
2. 类型（RAM 还是 I/O）
3. 名字

换句话说，它就是一张表——GPA 地址区间 → MemoryRegion（设备或内存后端）。VM 里 CPU 访问某个地址的时候，QEMU 就查这张表，决定谁来响应、怎么响应。

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

* `起始地址 -- 结束地址`：guest 物理地址区间（闭区间），十六进制。表示这一段 GPA 被某个 MemoryRegion 占用了。

* `(prio N, TYPE)`：
  - prio N：优先级。多个 region 重叠时，优先级高的先响应。
  - TYPE：region 的类型：
    - ram：普通可读写内存（DRAM 后端）
    - i/o：MMIO / 设备寄存器，访问会走设备回调
    - rom / romd：只读固件或 flash

* name（如 virtio-mmio、serial、riscv_virt_board.mrom）：MemoryRegion 的名字，通常能看出后端是什么设备。

* alias ... @xxx：别名映射。这一段不直接对应后端，而是把访问转发到另一个 MemoryRegion（比如把高位的 pcie-mmio alias 到 gpex_mmio_window）。常用于让同一段物理窗口在不同地址范围可见。

举个例子，Guest 往 virtio-mmio 设备寄存器写个值（地址比如 `0x10001000`），整个过程是：

1. Guest 驱动执行一条 store 指令，目标物理地址 `0x10001000`。QEMU 的虚拟 CPU 把地址和数据丢到总线上，发写信号。

2. QEMU 拿 FlatView 解码地址——FlatView 就是把前面那棵 MemoryRegion 树按地址和优先级拍扁、排好序的一维数组，二分查找（或者 cache 命中）就能定位到 `0x10001000` 落在 virtio-mmio 的 region 里。

3. 找到 region 就调它的 write 回调（`MemoryRegionOps` 里注册的 write），数据丢给设备模拟代码。设备这边按寄存器偏移解析，更新内部状态或者 ring queue。

4. 如果这次写是 “提交描述符” 或者 “写 doorbell” 这种，virtio 模拟层会转发给宿主机侧的 virtio 后端，并且可能需要往 Guest CPU 注中断——中断控制器在 RISC-V 上是 PLIC，x86 上是 APIC。

5. Guest 中断处理程序跑起来，驱动再读寄存器（又走一遍 MMIO 读），把完成的数据往上层交——串口字符进 tty buffer，文件系统数据给 VFS。内核里 MMIO 访问一般走 `ioremap()`，PCI 驱动的话 BAR 自动映射好了。


---

对于 prio 字段，看这个图就明白了：

```
地址递增 →
0       0x10000 0x20000 0x30000 0x40000 0x50000 0x60000 0x70000 0x80000
|--------|--------|--------|--------|--------|--------|--------|--------|
A:[-----------------------------------------------------------------------] prio:0
B:[-----------------------------------------------------] prio:1
C:[-----------------------------------] prio:2
D:[-----------------] prio:3

对于 mr A 来说，它的实际可见范围会被高优先级的 B/C/D 覆盖，最终效果是：

0       0x10000 0x20000 0x30000 0x40000 0x50000 0x60000 0x70000 0x80000
|--------|--------|--------|--------|--------|--------|--------|--------|
A:[AAAAAAAAAAAAAAAAA|BBBBBBBBBBBBBBBBB|CCCCCCCCCCCCCCCCC|DDDDDDDDDDDDDDDDD]
                     [B-overrides]      [C-overrides]      [D-overrides]
```

也就是说，如果 CPU 访问 `0x70000` 到 `0x80000` 这一段，在没有 B/C/D 的时候会访问到设备 A。但因为 D 的优先级最高，它的范围也覆盖了这一段，所以实际访问的是 D。同理，`0x50000` 到 `0x60000` 落在 C 的范围，访问的是 C，依此类推。

QEMU 用 alias 来描述 mr 之间的重叠关系，类似于 mmap——可以把一个 mr 的某段窗口映射到另一个 mr 上，避免重复模拟同一段物理内存。

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

所以整体 DataFlow 就是这样：

1. MR 树有变动 → 标记 pending
2. Transaction commit → 调 `generate_memory_topology` 重新把 MR 树拍扁成 FlatView
3. 地址空间切到新视图 → 两遍 pass 把新旧差异通知给 MemoryListener
4. RCU 切指针 → 读者原子看到新 FlatView，旧的引用归零后 RCU 延迟释放
5. 之后每次访存路径：`as->current_map → dispatch → 多级页表 → MemoryRegionSection → MR 操作`

---

这里顺便提一句 qom-tree，它可以跟 mr 对应起来看：

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


# decode

TCG ops 和 HELPER，两种路子都能扩展指令。那能不能两个一起用？我们来走一遍验证：从教程里那个立方计算指令开始。


## HELPER APPROACH

当前 `cube` 是 Helper 版，`cube_ops` 是 TCG ops 版。两者语义保持一致，都是从 `rs1` 指向的地址读 64-bit 值，再把立方写回目标寄存器。

```text
// target/riscv/insn32.decode
%eggr      7:5        # 搞个eggr,跟 rd 是一样的
&r_cube    eggr rs1
@r_cube    ....... ..... ..... ... ..... ....... &r_cube %rs1 %eggr
cube       0000110 00000 ..... 110 ..... 1111011 @r_cube # HELPER用的operator
cube_ops   0000111 00000 ..... 110 ..... 1111011 @r_cube # TCG ops用的operator
```

要点：`%xxx` 抽 bit，`&xxx` 定义 C 参数结构体，`@xxx` 定义 format，真正生成 `trans_xxx()` 入口的是 pattern 行。`bits left unspecified (0x00000f80)` 说的就是 bit `[11:7]`，也就是这里被 `%eggr 7:5` 覆盖的目标寄存器字段。

这一部分的改动是两个模式都通用的，因为我们是在规定 decode 的格式，这个 bit layout 是一致的。

---


Helper translator 只把寄存器编号传给 C helper：

```c
static bool trans_cube(DisasContext *ctx, arg_r_cube *a)
{
    gen_helper_r_cube(tcg_env, tcg_constant_tl(a->eggr),
                      tcg_constant_tl(a->rs1));
    return true;
}
```

Helper 里自己读写 `env->gpr[]`。为了同时支持 linux-user 和 softmmu，helper 不能放在 `#ifndef CONFIG_USER_ONLY` 内；做数据 load 时也要用当前 data MMU index。

```c
void helper_r_cube(CPURISCVState *env, target_ulong rd, target_ulong rs1)
{
    MemOpIdx oi = make_memop_idx(MO_TEUQ, cpu_mmu_index(env_cpu(env), false));
    target_ulong val = cpu_ldq_mmu(env, env->gpr[rs1], oi, GETPC());
    env->gpr[rd] = val * val * val;
}
```

decodetree.py codegen:

```c
typedef struct {
    int eggr;
    int rs1;
} arg_r_cube;

static bool decode_insn32(DisasContext *ctx, uint32_t insn)
{
  union {
    arg_atomic f_atomic;
    arg_b f_b;
    arg_decode_insn3219 f_decode_insn3219;
    //...
    arg_i f_i;
    arg_j f_j;
    //...
    arg_r_cube f_r_cube;
  } u;
  
  switch ()
}

static void decode_insn32_extract_r_cube(DisasContext *ctx, arg_r_cube *a, uint32_t insn)
{
    a->rs1 = extract32(insn, 15, 5);
    a->eggr = extract32(insn, 15, 5);
}
```

### TCG Ops Approach

`cube_ops` 直接在 translator 里生成 TCG IR，避免 helper call，通常更快。这里仍然是内存语义，不是纯寄存器 `rs1^3`。

```c
static bool trans_cube_ops(DisasContext *ctx, arg_r_cube *a)
{
    TCGv value = tcg_temp_new();
    TCGv dest = dest_gpr(ctx, a->eggr); // eggr,也就是Rd，是最终存下结果的寄存器

    tcg_gen_qemu_ld_tl(value, get_gpr(ctx, a->rs1, EXT_NONE),
                       ctx->mem_idx, MO_TEUQ);
    tcg_gen_mul_tl(dest, value, value);
    tcg_gen_mul_tl(dest, dest, value);
    gen_set_gpr(ctx, a->eggr, dest);
    return true;
}
```

在我们编写代码的时候，其实是有告警提醒:
如果使用讲义中提到的 get_underline_gpr 方式，可能会导致 X0 寄存器出现问题以及其他方法的隐患。

所以我们在这里将其改成了使用 dest_gpr 方式:

```c
/*
 * Wrappers for getting reg values.
 *
 * The $zero register does not have cpu_gpr[0] allocated -- we supply the
 * constant zero as a source, and an uninitialized sink as destination.
 *
 * Further, we may provide an extension for word operations.
 */
static TCGv get_gpr(DisasContext *ctx, int reg_num, DisasExtend ext){}

static TCGv dest_gpr(DisasContext *ctx, int reg_num)
{
    if (reg_num == 0 || get_olen(ctx) < TARGET_LONG_BITS) {
        return tcg_temp_new();
    }
    return cpu_gpr[reg_num];
}
```

get_gpr(..,.., EXT_NONE) 效果就是

```c
reg_num = a->rd; //a->eggr
switch (get_ol(ctx)) {
  case EXT_NONE: break;
}
return cpu_gpr[reg_num];
// return cpu_gpr[a->rd];
```

因此

- `get_gpr(ctx, reg, EXT_NONE)`
    - 如果 reg != 0，直接返回 cpu_gpr[reg]
    - 如果 reg == 0，返回 ctx->zero
    - 它的语义是：“把这个寄存器当源值来读”


- `dest_gpr(ctx, reg)`
    - 如果 reg != 0 且目标宽度合适，返回 cpu_gpr[reg]
    - 如果 reg == 0，返回一个新的临时变量 tcg_temp_new()
    - 它的语义是：“给这个寄存器准备一个写结果的位置”
    
在 rd = x0 (a->rd=0) 时，它们不一样：

```
  get_gpr(ctx, 0, EXT_NONE)  -> ctx->zero
  dest_gpr(ctx, 0)           -> tcg_temp_new()
```


Benchmark 只跑 `qemu-riscv64` user mode，不跑 system mode，避免机器模型和裸机环境带来的额外噪声。当前一次 user-mode 结果：helper 约 `2.84M` cycles，TCG ops 约 `2.13M` cycles。

### 对比

HELPER 的改动：

1. `<target>/helper.h`里面声明 helper; `DEF_HELPER_...`
1. `trans_rvi.c.inc`里面让 trans_cube 的行为完全由 helper 来做, 这里有一个开销, 但不大
1. `<target>/op_helper.c` 里面来实现 helper

TCG ops 对应的 `trans_` + fname 是 `trans_cube_ops`:

1. `trans_rvi.c.inc`里面让 trans_cube_ops 的行为完全由自身做


```c

gen_helper_r_cube
static bool trans_cube(DisasContext *ctx, arg_r_cube *a)                    {                                                                               gen_helper_r_cube(tcg_env,                                                                    tcg_constant_tl(a->eggr),
                     tcg_constant_tl(a->rs1));
   return true;
}

static bool trans_cube_ops(DisasContext *ctx, arg_r_cube *a)
{
   TCGv value = tcg_temp_new();
   TCGv dest = dest_gpr(ctx, a->eggr);

   tcg_gen_qemu_ld_tl(value, get_gpr(ctx, a->rs1, EXT_NONE),
                      ctx->mem_idx, MO_TEUQ);
   tcg_gen_mul_tl(dest, value, value);
   tcg_gen_mul_tl(dest, dest, value);
   gen_set_gpr(ctx, a->eggr, dest);
   return true;
 }
```


```c
// assembly:
static inline uint64_t custom_cube(uint64_t *addr)
{
   uint64_t cube;

   asm volatile(
       ".insn r 0x7b, 6, 6, %0, %1, x0"
       : "=r"(cube)
       : "r"(addr)
       : "memory"
   );
   return cube;
}

static inline uint64_t custom_cube_ops(uint64_t *addr)
{
   uint64_t cube;

   asm volatile(
       ".insn r 0x7b, 6, 7, %0, %1, x0"
       : "=r"(cube)
       : "r"(addr)
       : "memory"
   );
   return cube;
}

// defines:
static uint64_t run_cube_helper(void)
{
     uint64_t acc = 0;

     for (int i = 0; i < BENCH_ITERS; i++) {
         acc ^= custom_cube((uint64_t *)&bench_value);
     }
     return acc;
 }

static uint64_t run_cube_ops(void)
{
     uint64_t acc = 0;

     for (int i = 0; i < BENCH_ITERS; i++) {
         acc ^= custom_cube_ops((uint64_t *)&bench_value);
     }
     return acc;
}

// bench test:

uint64_t expected = bench_value * bench_value * bench_value;
uint64_t start, mid, end;
uint64_t helper_acc, ops_acc;

crt_assert(custom_cube((uint64_t *)&bench_value) == expected);
crt_assert(custom_cube_ops((uint64_t *)&bench_value) == expected);

start = rdcycle();
helper_acc = run_cube_helper();
mid = rdcycle();
ops_acc = run_cube_ops();
end = rdcycle();
```


另外，如果同时实现这两个机制的 cube，decode 那边生成的 switch case 长这样：

```c 
  switch (insn & 0x0000007f) { // 01111111  ===> opcode
  case 0x0000007b:
        switch (insn & 0xfe007000u) {
        case 0x0c006000:
            /* 0000110. ........ .110.... .1111011 */
            decode_extract_r_cube(ctx, &u.f_r_cube, insn);
            switch ((insn >> 20) & 0x1f) {
            case 0x0:
                /* 00001100 0000.... .110.... .1111011 */
                /* insn32.decode:129 */
                if (trans_cube(ctx, &u.f_r_cube)) return true;
                break;
            }
            break;
        case 0x0e006000:
            /* 0000111. ........ .110.... .1111011 */
            decode_extract_r_cube(ctx, &u.f_r_cube, insn);
            switch ((insn >> 20) & 0x1f) {
            case 0x0:
                /* 00001110 0000.... .110.... .1111011 */
                /* insn32.decode:130 */
                if (trans_cube_ops(ctx, &u.f_r_cube)) return true;
                break;
            }
            break;
        }
  }

```

虽然他们的 switch case 都走到了同一个 decode 的 extract 函数，但是实际上不会有冲突，因为我们设置成了两条指令: (funct7不同)

```
                            opcode (insn & 0x7f)
                                  |
                          case 0x7b (1111011)
                                  |
                      funct7 + bit20 + funct3
                      (insn & 0xfe007000)
                     /        |         |      \
              0x00000000  0x0c006000  0x0e006000  ...
               (addd)      (cube)     (cube_ops)
                               |           |
                         rs2 检查       rs2 检查
                    ((insn>>20)&0x1f) ((insn>>20)&0x1f)
                              |            |
                         case 0x0     case 0x0
                         (00000)      (00000)

```

<!-- source: qemu-camp-2026-exper-Egg12138 27de27e-dirty, written: 2026-06-30 15:34:34 +0800 -->


# softMMU

## softTLB

根据TLB语义模拟:

```c
struct TLBEntry {
    bool valid;

    // 核心4个字段
    uint64_t asid;
    uint64_t vpn;
    uint64_t ppn;
    uint8_t page_shift;
    
    bool readable;
    bool writable;
    bool executable;
    bool user;
    
}
```

但以上只是 GVA→GPA 的视角。QEMU 实际要的是 `GVA→GPA→QEMU_AS→MRSection→...`，所以它的 TLB entry 除了缓存 VA→PA，还得缓存后续访存执行需要的信息（比如直接算 host 地址用的 addend）。

硬件那边的语义是 VPN→PPN，QEMU 这边更关心 GVA→MRSection→HVA，fast path 直接 `host_ptr = gva + addend` 一把算出来。

```c
/* include/exec/tlb-common.h */
typedef union CPUTLBEntry {
    struct {
        uintptr_t addr_read;
        uintptr_t addr_write;
        uintptr_t addr_code;
        uintptr_t addend;
    };
    /*
     * Padding to get a power of two size, as well as index
     * access to addr_{read,write,code}.
     */
    uintptr_t addr_idx[(1 << CPU_TLB_ENTRY_BITS) / sizeof(uintptr_t)];
} CPUTLBEntry;

/* include/hw/core/cpu.h */
// full TLB entry 不被 generated TCG code 访问，所以 layout 没有 CPUTLBEntry 那么关键；这也是为什么不把两个 struct 合并。
struct CPUTLBEntryFull {
    // xlat_offset + VA = ram_addr_t of the target-RAM
    // OR xlat_offset + VA = offset within the target memory region
    hwaddr xlat_offset;
    MemoryRegionSection *section;
    /*
    * @phys_addr contains the physical address in the address space
    * given by cpu_asidx_from_attrs(cpu, @attrs).
    */
    hwaddr phys_addr;
    MemTxAttrs attrs;
    uint8_t prot;
    uint8_t lg_pwge_size;
    // ISA-spefics flags
    uint8_t tlb_fill_flags;
    uint8_t slow_flags[MMU_ACCESS_COUNT];
    /* ... */
};
```

先看 `CPUTLBEntryFull`, 为什么它要维护的fields是 `xlat_offset`等

```
标准 TLB:
  PA = PPN << page_shift | offset

QEMU TLB:
  host_or_region_offset = VA + (xlat_offset OR addend)
```


因为 `xlat_offset` 的意涵取决于对应 MRSection是RAM,MMIO还是啥,所以必须要再存`*section`
字段（当然不止一个原因）来了解这个 MRSection 的类型，访问上有没有callback云云。

`phys_addr` 是某个AS里的PA(依然是GPA), 因为 slow path / MMIO / fault / tracing / device access 仍然需要 GPA:
- MMIO callback 需要知道 guest PA
- IOMMU / memory listener 需要知道 PA
- 异常和调试可能要报告 PA
- dirty logging 可能按 PA/RAM 地址处理


`uint8_t prot` 就对应着toy model中的 prots: bool r,w,x,u;当然，不只是guest PTE的 `R/W/X`,

所以说，硬件 TLB 里的 VPN/ASID/PPN 三个字段，在 QEMU 的 TLB full entry 里已经被拆成别的形式了。

QEMU 的 fast path 不是这样查的：

```c
if (entry.vpn == va >> page_shift)
```

而是用 `addr_read` / `addr_write` / `addr_code` 这些字段进行页匹配。

源码里可以看到 `tlb_hit_page_mask_anyprot()` 会拿 page 和 entry 的 addr_read、addr_write、addr_code 做匹配。

```c
static bool tlb_hit_page_mask_anyprot(CPUTLBEntry *tlb_entry,
                                      vaddr page, vaddr mask)
{
    page &= mask;
    mask &= TARGET_PAGE_MASK | TLB_INVALID_MASK;

    return (page == (tlb_entry->addr_read & mask) ||
            page == (tlb_addr_write(tlb_entry) & mask) ||
            page == (tlb_entry->addr_code & mask));
}
```

所以 VPN 编码在 fast comparator 需要的地址字段中。

而`PPN` 被 `phys_addr / xlat_offset / addend` 取代,从

```c
  PA = PPN << page_shift | offset // 变为
  host_or_region_offset = VA + (xlat_offset OR addend)
```

而 `ASID` 通常不直接放在 TLBEntry 里, 首先我们知道，ASID是为了确保找VPN时，使用正确的AS里的cache entry
Kernel维护页表时会根据ISA不同，实现不同的 `#define ASID()`， 比如 arm64写到 `TTBR0/1` 特定位。

```
PPN = pgtbl_walk(mm->pgd, vpn)
TLB[(ASID,VPN)] = PPN
```

因为 ASID 的作用就是区分不同地址空间的同号 VPN——同一个 VPN 在不同 ASID 下对应不同 PPN，这样就不用每次上下文切换都刷 TLB。所以理论上，如果你的 TLB 不需要区分不同地址空间的 VPN（比如通过 flush 来保证不会串），那你就不需要在 entry 里存 ASID。

QEMU 不想让 fast path 每次访存都多读 current_asid、多比较 entry.asid。
通过 per-vCPU/per-mmu_idx TLB 和上下文变化时 flush/refill 来处理地址空间切换，从而避免 fast path 增加 ASID 比较。

具体说,它改用：

1. 每个 vCPU 有自己的 TLB 状态；
2. 按 mmu_idx 分不同 MMU mode；
3. guest 页表根 / ASID / MMU 状态变化时，target 代码触发 TLB flush；
4. miss 后重新 refill 出当前上下文对应的 addend / section / phys_addr。

假设 guest 从进程 A 切换到进程 B。

硬件可以这样：

1. 保留 A 的 TLB entry
1. 保留 B 的 TLB entry
1. 靠 ASID 区分, VPN->PPN(A), VPN->PPN(B)

QEMU 可以这样：

1. 发现 guest MMU context 变了
1. flush 对应 QEMU softTLB
1. 之后 B 的访问重新 refill

这就是 QEMU 为什么不需要在每个 entry 里携带`entry.asid`了

### 代码证据

**① CPUTLBEntry 不含 ASID** — fast path 每访存都读这个结构体，只有 tag + addend：

```c
/* include/exec/tlb-common.h:25-41 */
typedef union CPUTLBEntry {
    struct {
        uintptr_t addr_read;   // tag 字段（VPN + flags bits）
        uintptr_t addr_write;
        uintptr_t addr_code;
        uintptr_t addend;      // host_addr = vaddr + addend
    };
    // ...
};
```

**② TCG 生成的 fast path 无需 ASID 比较** — `tcg/x86_64/tcg-target.c.inc:1940-1999`，`prepare_host_addr()` 生成的代码逻辑：

```asm
; L0 = (vaddr >> (PAGE_BITS - CPU_TLB_ENTRY_BITS))  ; 提取 VPN 索引
; L0 &= fast[mmu_idx].mask                           ; AND 上 TLB size mask
; L0 += fast[mmu_idx].table                          ; + TLB table 基址

; L1 = vaddr & (PAGE_MASK | align_mask)               ; 构造 tag

; cmp [L0].addr_read, L1                              ; 比较 entry tag
; jne  slow_path                                      ; miss → 走 tlb_fill

; TLB hit: L0 = [L0].addend                           ; host_addr = vaddr + addend
```

mmu_idx 在 translation time 已确定（`tcg/tcg.c:418-423`），每个 mmu_idx 有独立 TLB 数组：

```c
static int tlb_mask_table_ofs(TCGContext *s, int which)
{
    int fi = mmuidx_to_fast_index(which);
    return (offsetof(CPUNegativeOffsetState, tlb.f[fi]) -
            sizeof(CPUNegativeOffsetState));
}
```

**③ ARM PTW 注释直接承认** — `target/arm/ptw.c:1946-1948`：

```c
/*
 * ... TTBCR:A1 selects whether we get the ASID from TTBR0 or TTBR1,
 * but QEMU's TLB doesn't currently implement any ASID-like capability
 * so we can ignore it (instead we will always flush the TLB any time
 * the ASID is changed).
 */
```

**④ RISC-V SATP 变化触发全刷** — `target/riscv/csr.c:1925-1938`：

```c
mask = (val ^ old_xatp) & (SATP32_MODE | SATP32_ASID | SATP32_PPN);
// MODE / ASID / PPN 任意一位变化 →
if (vm && mask) {
    tlb_flush(env_cpu(env));        // 全量 flush
}
```

**⑤ x86 CR3 变化触发全刷** — `target/i386/helper.c:177-185`：

```c
void cpu_x86_update_cr3(CPUX86State *env, target_ulong new_cr3)
{
    env->cr[3] = new_cr3;
    if (env->cr[0] & CR0_PG_MASK) {
        tlb_flush(env_cpu(env));    // CR3 变化 → 全刷
    }
}
```

一句话：fast path 结构体里没有 ASID，fast path 代码也不比 ASID。guest 那边页表根/ASID/MMU 模式一旦变了，target 代码就调 `tlb_flush()` 全刷，后续访问走 `tlb_fill` 用新上下文重新填。

```c

typedef struct CPUTLB {
    CPUTLBCommon c;
    CPUTLBDesc d[NB_MMU_MODES];
    CPUTLBDescFast f[NB_MMU_MODES];
} CPUTLB;
```


```c
/* include/hw/core/cpu.h */
typedef struct CPUTLB {
    CPUTLBCommon c;
    CPUTLBDesc d[NB_MMU_MODES];
    CPUTLBDescFast f[NB_MMU_MODES];
} CPUTLB;

/* include/exec/tlb-common.h */
typedef struct CPUTLBDescFast {
    uintptr_t mask;
    CPUTLBEntry *table;
} CPUTLBDescFast;

```

让 GPT 帮忙捋了个对照表：

| toy TLB 字段 | QEMU 里怎么搞的 | 为啥 |
|---|---|---|
| `valid` | `addr_read/write/code == -1` 之类的编码 | fast path 少一个字段少一次分支 |
| `asid` | 基本靠 `mmu_idx` + flush 语义消化掉了 | QEMU 是 per-CPU/per-MMU-mode TLB，不走 ASID tag 比较那条路 |
| `vpn` | 编码在 `addr_read/write/code` 里做 page match | fast comparator 直接用 |
| `ppn` | 拆成 `phys_addr` / `xlat_offset` / `addend` | QEMU 既要 guest PA，也要 region offset，还要 host pointer |
| `page_shift` | `lg_page_size` | 支持大页 |
| `r/w/x` | `prot` + `addr_read/write/code` + `slow_flags` | 三种访问走不同路径 |
| `attrs` | `MemTxAttrs attrs` | memory transaction 要用 |
| `memory type` | `section` + `attrs` + flags | RAM/MMIO/ROM/dirty/device 要区分 |
| `slow path flag` | `slow_flags[MMU_ACCESS_COUNT]` | load/store/fetch 可能各自 slow |

对比一下 slowpath fastpath calling chains:
```
tcg_gen_qemu_ld_i64(addr, memop, mmu_idx)
  │
  ├─ make_memop_idx(memop, mmu_idx) → oi
  │
  └─ TCG IR → JIT
       │
       ├─ [快路径] tcg_out_qemu_ld
       │     ├─ 从 oi 提取 mmu_idx → cpu_tlb_fast(cpu, mmu_idx)
       │     ├─ tlb_hit(entry->addr_read, addr) ?   ← 直接在生成的汇编中
       │     ├─ 命中 → haddr = addr + entry->addend → 访存
       │     └─ 未命中 → 跳转到慢路径
       │
       └─ [慢路径] tcg_out_qemu_ld_slow_path
             └─ call qemu_ld_helpers[opc & MO_SIZE]  (e.g. helper_ldq_mmu)
                  │
                  └─ do_ld8_mmu(cpu, addr, oi, ra, MMU_DATA_LOAD)
                       │
                       └─ mmu_lookup(cpu, addr, oi, ra, MMU_DATA_LOAD, &locals)
                            │
                            ├─ locals.mmu_idx = get_mmuidx(oi)   // 解出 mmu_idx
                            │
                            └─ mmu_lookup1(cpu, &page, memop, mmu_idx, MMU_DATA_LOAD, ra)
                                 │
                                 ├─ tlb_index(cpu, mmu_idx, addr)
                                 │   → (addr >> TARGET_PAGE_BITS) & (f[mmu_idx].mask >> CPU_TLB_ENTRY_BITS)
                                 │
                                 ├─ tlb_entry(cpu, mmu_idx, addr)
                                 │   → &f[mmu_idx].table[index]
                                 │
                                 ├─ tlb_hit(entry->addr_read, addr)?
                                 │   ├─ 命中 → data->full = &d[mmu_idx].fulltlb[index]
                                 │   │           data->haddr = addr + entry->addend
                                 │   │           data->flags = tlb_addr & TLB_FLAGS_MASK
                                 │   └─ 未命中 → tlb_fill_align() → 重新填充 TLB → 重试
                                 │
                                 └─ return maybe_resized (是否因 resize 导致指针失效)

```

---

### slowpath

> **TLB hit**：TCG JIT fast path，在生成的汇编中直接访问 `cpu->neg.tlb.f[mmu_idx].table[index]`，用 `entry->addend` 计算宿主机地址后直接访存返回。
>
> **TLB miss**：slow path → `qemu_ld_helpers[mop]` → `do_ld8_mmu` → `mmu_lookup1`（C 代码再次查 `f[mmu_idx].table[index]`，仍然 miss 则 `tlb_fill_align` 做页表遍历填充 TLB）→ 用 `d[mmu_idx].fulltlb[index]` 获取完整元数据 → `do_ld_8` 根据 `flags` 决定走 MMIO（`data->full`）还是 RAM（`data->haddr`）。

细节看代码证据（见上）

```c
tci_qemu_ld()
swtich (mop & MO_SSIZE) {
    case MO_UQ:
        return helper_ldq_mmu(env, taddr, oi, ra);
}

// ldst_common.c.inc
uint64_t helper_ldq_mmu(CPUArchState *env, uint64_t addr,
                        MemOpIdx oi, uintptr_t retaddr)
{
    tcg_debug_assert((get_memop(oi) & MO_SIZE) == MO_64);
    return do_ld8_mmu(env_cpu(env), addr, oi, retaddr, MMU_DATA_LOAD);
}
```

`MO_` 在此处是 `Memory Operation`

`ld` 在此处是 `load`

关于这里，有如下调用

```c

// 全平台通用抽象
static void * const qemu_ld_helpers[MO_SSIZE + 1] __attribute__((unused)) = {
    [MO_UB] = helper_ldub_mmu,
    [MO_SB] = helper_ldsb_mmu,
    [MO_UW] = helper_lduw_mmu,
    [MO_SW] = helper_ldsw_mmu,
    [MO_UL] = helper_ldul_mmu,
    [MO_UQ] = helper_ldq_mmu,
    [MO_SL] = helper_ldsl_mmu,
    [MO_128] = helper_ld16_mmu,
};

```

`MO_UB` = `MO_8` (无符号字节，0 扩展)
- `MO_SB` = `MO_SIGN | MO_8` (有符号字节，符号扩展)
- `MO_UW` = `MO_16`, `MO_SW` = `MO_SIGN | MO_16`
- `MO_UL` = `MO_32`, `MO_SL` = `MO_SIGN | MO_32`
- `MO_UQ` = `MO_64` (Quad word)
- `MO_SSIZE` = `MO_SIZE | MO_SIGN` (掩码，提取"带符号的大小"字段—即 `MO_UB`~`MO_SL` 的索引范围)

当走slowpath时，才会跳转到如下处理，其中我们会看到 `qemu_ld_helpers`被访问； `opc & MO_SIZE` 得到 index;


```c
/*
 * Generate code for the slow path for a load at the end of block
 */
static bool tcg_out_qemu_ld_slow_path(TCGContext *s, TCGLabelQemuLdst *l)
{
   MemOp opc = get_memop(l->oi);
   /* resolve label address 这一块，ISA不同, SKIP*/
   tcg_out_ld_helper_args(s, l, &ldst_helper_param);
   tcg_out_branch(s, 1, qemu_ld_helpers[opc & MO_SIZE]); // ISA实现的
   tcg_out_ld_helper_ret(s, l, false, &ldst_helper_param);
   tcg_out_jmp(s, l->raddr);
   return true;
}

// riscv:
static bool tcg_out_qemu_ld_slow_path(TCGContext *s, TCGLabelQemuLdst *l)
{
    MemOp opc = get_memop(l->oi);

    /* resolve label address 这一块，ISA不同, SKIP*/
    /* call load helper */
    tcg_out_ld_helper_args(s, l, &ldst_helper_param);
    tcg_out_call_int(s, qemu_ld_helpers[opc & MO_SSIZE], false); // ISA实现的
    tcg_out_ld_helper_ret(s, l, true, &ldst_helper_param);

    tcg_out_goto(s, l->raddr);
    return true;
}
```

这里的两个 `tcg_out_xxx` 都是ISA自己实现的，但内部核心逻辑基本一致，只不过要对各自的跳转做专门的处理: 


最后走到 `do_ld8_mmu`, 也是通用实现：

```c
static uint64_t do_ld8_mmu(CPUState *cpu, vaddr addr, MemOpIdx oi,
                            uintptr_t retaddr, MMUAccessType access_type)
{
    haddr = cpu_mmu_lookup(cpu, addr, mop, retaddr, access_type);
    ret = load_atom_8(cpu, retaddr, haddr, mop); // READ 8 bytes from `haddr`
}

// mmu_lookup1
```

`mmu_lookup1` 具体不说了，讲义说的清楚；主看下参数:

```c
/**
 * mmu_lookup1: translate one page
 * @cpu: generic cpu state
 * @data: lookup parameters
 * @memop: memory operation for the access, or 0
 * @mmu_idx: virtual address context
 * @access_type: load/store/code
 * @ra: return address into tcg generated code, or 0 JIT 生成的代码中 call 指令的下一条指令地址。
 *
 * Resolve the translation for the one page at @data.addr, filling in
 * the rest of @data with the results.  If the translation fails,
 * tlb_fill_align will longjmp out.  Return true if the softmmu tlb for
 * @mmu_idx may have resized.
 */
 {

     // CPUState.CPUNegativeOffsetState.CPUTLB.f[mmu_idx] 就是 fastpath `F`ast data.
     // CPUState.CPUNegativeOffsetState.CPUTLB.d[mmu_idx] 就是 slowpath `D`ata
        full = &cpu->neg.tlb.d[mmu_idx].fulltlb[index]; 
 }

```

有一些细节值得注意：

TLB 数组的下标: `mmu_idx` 决定：

1. 查哪个 MMU 模式下的 TLB 表（EL0？EL1？Secure？...）
2. 用这块 TLB 里的 `addend` 计算宿主机地址
3. 用这块 TLB 里的 `fulltlb[].prot` 检查权限

其取值范围是 `[0, NB_MMU_MODES)`，直接作为 `d[]` 和 `f[]` 的下标。** 但注意 QEMU 为了内存布局优化，访问 `f[]` 时做了反转：

```c
// cpu.h:614
static inline int mmuidx_to_fast_index(int mmu_idx)
{
    return NB_MMU_MODES - 1 - mmu_idx;   // 反转：mmu_idx=0 => 索引 21
}

static inline CPUTLBDescFast *cpu_tlb_fast(CPUState *cpu, int mmu_idx)
{
    return &cpu->neg.tlb.f[mmuidx_to_fast_index(mmu_idx)];
}
```

这么做的原因写在注释里——`CPUNegativeOffsetState` 中偏移值越小（越负）的成员放在结构体末尾，反转后高频访问的 `mmu_idx=0`（通常是用户态）对应 `f[21]`（偏移量最小），让 TCG 生成的代码能用更短的指令编码来访问它。

## IOMMU

```c
flatview_do_translate()
{
    something();
    iommu_mr = memory_region_get_iommu(section->mr);
    if (unlikely(iommu_mr)) {
        return address_space_translate_iommu(...);
    }
}
static inline IOMMUMemoryRegion *memory_region_get_iommu(MemoryRegion *mr)
{
    if (mr->alias) {
        return memory_region_get_iommu(mr->alias);
    }
    if (mr->is_iommu) {
        return (IOMMUMemoryRegion *)mr;
    }
    return NULL;
}


```

> 对于 `xlate`, 我们在kernel和qemu代码看到了大量的 `xlate`，实际上 "xlat(e)" 是 "translate" 缩写

IOMMU的内容之后填坑；

# 中断

## 常识

真实硬件上的 trap

trap 开销的核心不是指令本身，是 cache miss。

| 事件 | trap 本身 | 额外 | 总开销 |
|------|-----------|------|--------|
| Timer | ~30 cycles | cache miss | ~100-200 cycles |
| 设备中断 | ~30 cycles | 2x MMIO | ~200-500 cycles |
| ECALL | ~30 cycles | 几乎没有 | ~50-100 cycles |
| Page Fault | ~60 cycles | 页表 walk | ~几千 cycles |

**反直觉的点**：ECALL（系统调用）在真实硬件上反而是**最便宜的 trap**，因为没有 cache miss 惩罚。Timer 虽然最频繁，但单次也最轻。

## 补充：QEMU TCG 中断全链路

### 0. 接线：设备 → CPU GPIO

board init 时，PLIC、CLINT 的中断输出线连到 CPU 的 GPIO 输入。

```c
// hw/riscv/virt.c
qdev_connect_gpio_out(dev, cpu_num, qdev_get_gpio_in(DEVICE(cpu), IRQ_S_EXT));
qdev_connect_gpio_out(dev, i,     qdev_get_gpio_in(DEVICE(cpu), IRQ_M_SOFT));

// CPU 自己注册 GPIO 输入端口
qdev_init_gpio_in(DEVICE(obj), riscv_cpu_set_irq, IRQ_LOCAL_MAX + ...);
```

### 1. riscv_cpu_set_irq — 设备敲门

```c
static void riscv_cpu_set_irq(void *opaque, int irq, int level)
{
    if (kvm_enabled())
        kvm_riscv_set_irq(cpu, irq, level);          // ioctl 直通
    else
        riscv_cpu_update_mip(env, 1 << irq, BOOL_TO_MASK(level)); // TCG
}
```

### 2. riscv_cpu_update_mip → riscv_cpu_interrupt — 更新 mip，决定是否举手

```c
// 更新 mip CSR 的对应位
env->mip = (env->mip & ~mask) | (value & mask);

// 有 pending 就设 CPU_INTERRUPT_HARD，否则清掉
void riscv_cpu_interrupt(CPURISCVState *env)
{
    if (env->mip | ...)
        cpu_interrupt(cs, CPU_INTERRUPT_HARD);
    else
        cpu_reset_interrupt(cs, CPU_INTERRUPT_HARD);
}
```

### 3. tcg_handle_interrupt — 设标志，踢 vCPU

```c
void tcg_handle_interrupt(CPUState *cpu, int mask)
{
    cpu_set_interrupt(cpu, mask);             // atomic OR interrupt_request
    if (!qemu_cpu_is_self(cpu))
        qemu_cpu_kick(cpu);                   // 跨线程唤醒
    else
        qatomic_set(&cpu->neg.icount_decr.u16.high, -1);  // 强制当前 TB 退出
}
```

### 4. cpu_exec_loop — TB 边界检查

```c
// 外层：异常优先，内层：中断检查 → 执行 TB
while (!cpu_handle_exception(cpu, &ret)) {
    while (!cpu_handle_interrupt(cpu, &last_tb)) {
        tb = tb_lookup / tb_gen_code(cpu, s);
        cpu_loop_exec_tb(cpu, tb, ...);
    }
}
```

**TCG 非抢占**——中断只在 TB 边界被识别，不会在 TB 中间打断。TB 边界就是天然的检查点。

### 5. cpu_handle_interrupt — 通用层回调架构代码

```c
// 关键注释：
// target hook 有 3 种退出方式：
//   False — 没处理，继续执行
//   True — 处理了，下次须重新查 TB（*last_tb = NULL）
//   longjmp — 异常场景
if (tcg_ops->cpu_exec_interrupt(cpu, interrupt_request)) {
    cpu->exception_index = -1;
    *last_tb = NULL;         // 禁用 TB 链优化，因为 PC 已跳到 stvec
}
```

### 6. riscv_cpu_exec_interrupt — RISC-V 中断优先级裁决

```c
bool riscv_cpu_exec_interrupt(CPUState *cs, int interrupt_request)
{
    int interruptno = riscv_cpu_local_irq_pending(env);
    if (interruptno >= 0) {
        cs->exception_index = RISCV_EXCP_INT_FLAG | interruptno;
        riscv_cpu_do_interrupt(cs);
        return true;
    }
    return false;
}
```

优先级顺序：**M > HS > VS**，靠 `mideleg`/`hideleg` 控制谁有资格处理：

```c
static int riscv_cpu_local_irq_pending(CPURISCVState *env)
{
    // 1. RNMI 不可屏蔽中断
    if (env->rnmip) return ctz64(env->rnmip);
    // 2. M-mode 中断（未委派给 S）
    irqs = pending & ~env->mideleg & -mie;
    // 3. HS-mode 中断（委派给 S 但未再委派给 VS）
    irqs = (pending & env->mideleg & ~env->hideleg) & -hsie;
    // 4. VS-mode 中断（二次委派）
    irqs = (irq_delegated | irqs_f_vs) & -vsie;
}
```

### 7. riscv_cpu_do_interrupt — 真正 trap：保存状态 + 跳 handler

```c
// 判断目标特权级
mode = (deleg >> cause) & 1 ? PRV_S : PRV_M;

if (mode == PRV_S) {
    env->scause = cause | (async << (sxlen - 1));
    env->sepc = env->pc;
    env->stval = tval;
    // 关中断，保存状态（SPIE ← SIE, SPP ← priv）
    env->mstatus = set_field(s, MSTATUS_SIE, 0);
    // PC ← stvec（direct 模式固定地址，vectored 模式 cause*4）
    env->pc = (env->stvec >> 2 << 2) + ...;
    riscv_cpu_set_mode(env, PRV_S, virt);
} else {
    // M-mode 同理：mcause/mepc/mtval/mtvec
}
```

### 执行流的本质

走完代码回头想，核心就一句话：**QEMU 里没有"跳转"，所有"跳转"就是改 `env->pc`，然后靠循环重新查 TB**。

设备敲中断 → 经过几层标志传递 → 改 PC → 循环帮你找到新地址去执行。回来也一样。

```
设备置位中断线
  → riscv_cpu_set_irq
    → riscv_cpu_update_mip    // env->mip 相应位置 1
      → riscv_cpu_interrupt   // 有 pending → cpu_interrupt(HARD)
        → tcg_handle_interrupt // cpu->interrupt_request 设位
          → TB 边界 ← 当前 TB 结束
            → cpu_handle_interrupt // 检查 interrupt_request，回调
              → riscv_cpu_exec_interrupt // 裁决：M > HS > VS
                → riscv_cpu_do_interrupt
                    env->sepc = env->pc;   ← 保存旧 PC
                    env->pc   = stvec;     ← "跳"到 handler ← 就这
                  → return 到 cpu_exec_loop
                    → tb_lookup: PC 变了！查不到
                      → tb_gen_code: 生成 stvec 处 TB
                        → 执行 handler (guest 代码)
```

`env->pc = stvec` 就是整个"中断跳转"的全部。之前那些 GPIO→mip→interrupt_request→cpu_handle_interrupt→裁决 的所有工作，都是**为了走到这一行赋值**。

回来也一样：handler 里执行 `sret` 指令 → QEMU 翻译时处理 → `env->pc = env->sepc` → 循环发现 PC 变回原址 → 查旧 TB → 接着跑。

```
sret:
    env->pc   = env->sepc;    ← "跳"回原处 ← 也是改 PC
    riscv_cpu_set_mode(old_priv);   // 恢复特权级
  → return 到 cpu_exec_loop
    → tb_lookup: PC 变回去了 → 查到旧 TB (或重新生成)
      → 继续执行
```

**执行流传递：设标志 → 改 PC → 等循环。**

### 为什么在 TB 边界？— Peter Maydell 的解释

中断不在 TB 中间处理，不是因为做不到，是因为**特意不做**。

QEMU 做了一次取舍：与其每条指令都检查中断（慢），不如在 TB 边界统一检查（快）。代价就是"有中断来了，得等当前 TB 跑完"。

具体机制是这样的：

1. **每个 TB 生成时，开头塞了一段检查代码**——检查 `interrupt_request` 标志。如果被设了，TB 的第一条指令就直接退出回到 C 循环，不执行 TB 主体。

2. **所以中断实际上在 TB 之间处理**：前一个 TB 执行完 → 回到 `cpu_exec_loop` 内层 while → `cpu_handle_interrupt()` 看 `interrupt_request` → 如果设了，不走 `tb_find`/`cpu_loop_exec_tb`，直接回调 `cpu_exec_interrupt`。没设？正常进入下一个 TB。而下一个 TB 开头会再检查一次。

3. **不会因为中断重翻译 TB**：如果某个 TB 开头发现标志被设了、直接退出了，QEMU **不会重新翻译它**。只是等 guest 从中断返回后（sret 把 PC 设回原址），下次 `tb_lookup` 如果还能查到缓存的 TB，直接执行。

PMM 把三类异常的分发路径说得很清楚：

| 类型 | 例子 | 路径 |
|------|------|------|
| **异步中断** | 设备中断、Timer | `interrupt_request` → TB 边界检查 → `cpu_exec_interrupt` |
| **"预期"异常** | syscall、undefined insn | 翻译时直接在代码里生成"抛异常"——helper 调 `cpu_loop_exit` → siglongjmp 回 `cpu_exec` → `cpu_handle_exception` → `do_interrupt` |
| **"非预期"异常** | load/store fault | 同上，但多了 `cpu_restore_state()`——从 host PC 反查 guest PC，因为 fast path 跳过了 PC 更新 |

第三类的细节：load/store 太频繁了，QEMU 特意不在 fast path 里更新 `env->pc`（省指令）。只有触发 fault 时才用 TB 翻译时记录的元数据，从触发 fault 的 host PC 反推出 guest PC，然后 `cpu_loop_exit`。

### KVM 对比

| TCG | KVM |
|-----|-----|
| TB 边界检查中断 | ioctl(KVM_RUN) 返回时处理 |
| interrupt_request 位 + 轮询 | ioctl(KVM_INTERRUPT) 直注入 |
| 软件模拟 CSR | 硬件真实执行 |
| ECALL → helper + do_interrupt | KVM_EXIT_RISCV_SBI → handle_sbi |
| RISC-V pre_run/post_run 是空函数（x86 才需要 IRQ window 逻辑） |

KVM 路径短得多，本质上中断注入就是一次 `ioctl`。

### 对"系统调用开销大"的再讨论

有了上面的代码，可以精确说：**这说法只在 TCG 下成立，且原因和你想的不一样**。

TCG 下 ECALL 不是"开销大"而是"浪费大"——它在 TB 中间截断，之前翻译执行的工作全白干了。Timer 中断在 TB 边界被采样，几乎零浪费。这和真实硬件正相反（硬件上 ECALL 是所有 trap 里最便宜的）。

TCG 用 TB 边界做检查点换性能，代价就是同步异常（ECALL、缺页）的开销被放大了。

```
TCG 开销排序（轻→重）：
  Timer ≈ IPI            ← TB 边界检查，轻
  设备中断                ← + MMIO claim/complete
  ECALL                  ← 截断 TB，前功尽弃
  Page Fault             ← + softmmu + 页表 walk + 指令重执行
```

<!-- source: qemu-camp-2026-exper-Egg12138 2c9ed1c, written: 2026-07-05 +0800 -->
<!-- chapter 1 (TB) expanded with core operations detail, 2026-07-05 -->


# SMP,(N)UMA

```
Machine
  └── SMP topology (sockets/cores/threads)
        └── vCPU (CPUState) x N
              └── vCPU thread(s)
```


一颗 8 核 16 线程的 x86 处理器装入双路服务器：

- sockets=2（两颗物理芯片）
- cores=8（每颗芯片 8 个物理核心）
- threads=2（每核心 2 个 SMT 线程）
- maxcpus = 2 × 8 × 2 = 32(32 个 vCPU)

```c
total_cpus = drawers * books * sockets * dies * clusters * modules * cores * threads;
maxcpus = maxcpus > 0 ? maxcpus : total_cpus;
cpus = cpus > 0 ? cpus : maxcpus;

ms->smp.cpus = cpus;
ms->smp.drawers = drawers;
ms->smp.books = books;
ms->smp.sockets = sockets;
ms->smp.dies = dies;
ms->smp.clusters = clusters;
ms->smp.modules = modules;
ms->smp.cores = cores;
ms->smp.threads = threads;
ms->smp.max_cpus = maxcpus;
```


mttcg: multi-thread tcg, vs single thread

> 下方 cpu->thread 都是 host cpu的 thread,对应vcpu

```
void mttcg_start_vcpu_thread(CPUState *cpu)
{
    char thread_name[VCPU_THREAD_NAME_SIZE];
    snprintf(thread_name, VCPU_THREAD_NAME_SIZE, "CPU %d/TCG",
             cpu->cpu_index);
    qemu_thread_create(cpu->thread, thread_name, mttcg_cpu_thread_fn, cpu, QEMU_THREAD_JOINABLE);
}

void rr_start_vcpu_thread(CPUState *cpu)
{
    char thread_name[VCPU_THREAD_NAME_SIZE];
    // 在单个线程跑多个vcpu, !single_tcg_cpu_thread => 初始化
    static QemuThread *single_tcg_cpu_thread;
    static QemuCond *single_tcg_halt_cond;

    
    if (!single_tcg_cpu_thread) {
        single_tcg_halt_cond = cpu->halt_cond;
        single_tcg_cpu_thread = cpu->thread;
        snprintf(thread_name, VCPU_THREAD_NAME_SIZE, "ALL CPUs/TCG");
        qemu_thread_create(cpu->thread, thread_name,
                           rr_cpu_thread_fn,
                           cpu, QEMU_THREAD_JOINABLE);
    } else {
        qemu_cond_destroy(cpu->halt_cond);
        cpu->thread = single_tcg_cpu_thread;
        cpu->halt_cond = single_tcg_halt_cond;
        cpu->thread_id = first_cpu->thread_id;
        cpu->neg.can_do_io = 1;
        cpu->created = true;
    }
}

```


ops钩子对应的核心行为差异：

mttcg每个 vCPU 在自己的线程中独立运行：

```c
  do {
    qemu_process_cpu_events(cpu)
    if cpu_can_run(cpu):
      bql_unlock()
      tcg_cpu_exec(cpu)
      bql_lock()
  } while (!cpu->unplug || cpu_can_run(cpu))
```

- 各 vCPU 线程并行执行，通过 BQL（大锁） 同步对设备模型的访问
- tcg_cpu_exec 时释放 BQL，允许其他 vCPU 的 IO 操作并发执行
- 线程退出条件：cpu->unplug 且 !cpu_can_run(cpu)

单一线程轮转所有 vCPU：

```c
while (1):
    rr_wait_io_event()           // 全部空闲则休眠
    rr_deal_with_unplugged_cpus()
    cpu = first_cpu
while (cpu && work_list_empty(cpu)):
    rr_current_cpu = cpu
    if exit_request: break
    if cpu_can_run(cpu):
        bql_unlock()
        tcg_cpu_exec(cpu)
        bql_lock()
    cpu = CPU_NEXT(cpu)       // exec一个cpu，然后切到下一个cpu，在这里实现轮转
rr_current_cpu = NULL
```

```c
#define QTAILQ_FIRST_RCU(elm, field) qatomic_rcu_read(&(elm)->field.tqe_next)
#define CPU_NEXT(cpu) QTAILQ_FIRST_RCU(cpu, node) ==> qatomic_rcu_read(&cpu->node.tqe_next)
```

- vCPU 之间串行执行，通过 kick timer（rr_kick_vcpu_timer）周期性地触发切换，防止一个 vCPU 饿死其他 vCPU（rr.c:53-61）
- 当所有 vCPU 都空闲（WFI）时，停止 kick timer 并休眠在 halt_cond 上，被唤醒后再重新启动 kick timer（rr_wait_io_event, rr.c:108-122）
- 外部 kick（rr_kick_vcpu_thread）会 kick 所有 vCPU（遍历 CPU_FOREACH，rr.c:41-4

# 主板建模

MachineClass

主板就是 `board`, 主要是 `Machine`

`-machine` 决定了board的组织结构

> 代码：`include/hw/core/boards.h`

QEMU 里每台"虚拟机型号"（virt、sifive_u 这些）都由 `MachineClass` 描述。它就是一张"这台机器长什么样"的配置表——有几个 CPU、默认用什么 CPU、初始化时干什么、内存多大、用不用 NUMA……全在这里声明。

讲义内容之外，我们看代码，可以补充如下字段说明(选择性):

### 1. 你是谁

```
family / name / alias / desc / is_default
```

- `desc`: 给人看的描述，比如 `"RISC-V VirtIO board"`
- `alias`: 简短别名，比如 `"virt"` 指向最新版（ARM 用得多，RISC-V 基本不搞版本号这套）
- `is_default`: 如果用户没指定 `-M`，就用这台

### 2. 初始化 — 最重要的一个

```c
void (*init)(MachineState *state);
```

这个函数指针就是**机器的入口**。QEMU 启动时会调它，它负责：创建 bus、映射内存、实例化外设……整台机器的"骨架"都在这里搭起来。

- RISC-V virt: `virt_machine_init` (hw/riscv/virt.c)
- ARM virt: `machvirt_init` (hw/arm/virt.c)

### 3. CPU 相关

```
default_cpu_type / max_cpus / possible_cpu_arch_ids / cpu_index_to_instance_props
```

- `max_cpus`: 这台机器最多搞几个 CPU。RISC-V 和 ARM 的 virt 都是 512
- `default_cpu_type`: 用户没指定 CPU 型号时用啥
  - RISC-V 是**静态字符串** `"rv64"`（编译时就定死了 rv64 或 rv32）
  - ARM 是**函数指针** `get_default_cpu_type`，运行时看你是 TCG 还是 KVM，返回 `cortex-a15` 或 `"max"`（host passthrough）
- `possible_cpu_arch_ids`: 告诉你哪些 CPU 槽位是可用的（已插 + 可热插的），返回 `CPUArchIdList`
- `cpu_index_to_instance_props`: cpu_index → 拓扑（socket/core/thread）的映射

### 4. 内存 / NUMA

```
default_ram_id / default_ram_size / numa_mem_supported / auto_enable_numa_with_memhp
```

- `default_ram_id`: 默认 RAM MemoryRegion 的名字；**设了这个字段，`-m` 才能用**
- `numa_mem_supported`: 允不允许 `--numa node.mem`
- `auto_enable_numa_with_memhp`: 用了内存热插拔就自动开 NUMA（ARM 设了，RISC-V 没设）

### 5. 设备 / 总线

```
block_default_type / no_serial, no_parallel, no_floppy, no_cdrom / pci_allow_0_address / default_nic
```

- `block_default_type = IF_VIRTIO`: 两个 virt 都默认 VirtIO 块设备
- `no_cdrom = 1`: 禁用默认 CD-ROM 设备
- `pci_allow_0_address = true`: 允许 PCI 设备地址为 0（virtio 需要）
- `default_nic`: 默认网卡类型，ARM 设成了 `"virtio-net-pci"`，RISC-V 留空

### 6. 加速器相关

```
kvm_type / minimum_page_bits
```

- `kvm_type`: ARM 特有，根据 KVM 参数选 GIC 版本（GICv2/GICv3）；RISC-V 没设
- `minimum_page_bits`: ARM 设了 12（4K page），保证可以用大页优化。RISC-V 不存在需要 1K page 的老 CPU，不用设

---

RISC-V virt vs ARM virt：一眼对比

| 字段 | RISC-V virt | ARM virt |
|------|:----------:|:--------:|
| `init` | `virt_machine_init` | `machvirt_init` |
| `max_cpus` | 512 | 512 |
| `default_cpu_type` | 静态 `"rv64"` | **动态函数** (TCG→a15 / KVM→max) |
| `kvm_type` | 无 | ✅ GIC 版本选择 |
| `minimum_page_bits` | 无 | 12 (4K) |
| `nvdimm_supported` | 无 | ✅ |
| `auto_enable_numa_with_memhp` | 无 | ✅ |
| `default_nic` | 无 | `"virtio-net-pci"` |
| `default_ram_id` | `"riscv_virt_board.ram"` | `"mach-virt.ram"` |
| 版本化机型 | 无（单层 class） | ✅ 通过宏生成多个版本子类 |

QEMU **ARM 的 virt 更"成熟"**——KVM 集成、NUMA 自动化、NVDIMM、热插拔回调、多版本机型兼容属性，全挂上了。RISC-V 的 virt 就是个精简版，只把核心路径上必不可少的字段填了。


# 外设建模

```c
#define TYPE_DEVICE "device"
OBJECT_DECLARE_TYPE(DeviceState, DeviceClass, DEVICE)
```

`qdev_new(name)->DEVICE(object_new(name))->...`

什么时候 create 被调用？ 为什么 create要 `prop_set_chr()`, `sysbus_realize_and_unref()` , ...等？
```c
DeviceState *pl011_create(hwaddr addr, qemu_irq irq, Chardev *chr)
{
    DeviceState *dev = qdev_new("pl011");
    SysBusDevice *s = SYS_BUS_DEVICE(dev);
    qdev_prop_set_chr(dev, "chardev", chr);
    sysbus_realize_and_unref(s, &error_fatal);
    sysbus_mmio_map(s, 0, addr);
    sysbus_connect_irq(s, 0, irq);
    return dev;
}
```

## pl011_create 拆解

`pl011_create` 被谁调？**板级初始化代码**。在 RISC-V g233 板里（`hw/riscv/g233.c:1711`）：

```c
pl011_create(s->memmap[VIRT_UART0].base,
             qdev_get_gpio_in(mmio_irqchip, UART0_IRQ),
             serial_hd(0));
```

对应真实硬件行为：**SoC 设计阶段把 UART 外设焊到总线上**，基地址和中断号是硬件设计决定的。

每步对应什么硬件行为：

| `pl011_create` 里的调用 | 对应真实硬件 |
|---|---|
| `qdev_prop_set_chr(dev, "chardev", chr)` | 把串口线（chardev 后端）接到 UART 上 |
| `sysbus_realize_and_unref(s, &error_fatal)` | 设备通电，内部逻辑就绪（注册回调、绑定 chardev） |
| `sysbus_mmio_map(s, 0, addr)` | 地址总线解码器把 addr 窗口指向 UART |
| `sysbus_connect_irq(s, 0, irq)` | UART 的中断引脚焊到中断控制器的某个槽 |

为什么 `realize` 必须在 `mmio_map` 和 `connect_irq` 之前？因为 MMIO 映射和中断连接要求设备**已经完全初始化**——寄存器有默认值、后端回调已注册。否则 guest 一碰 MMIO 或中断触发，设备可能还没准备好。反过来，不先把 chardev 接上，realize 里也没法绑定回调。

> **QEMU SysBus 设备遵循"创建 → 注入依赖 → realize → 连到总线"的生命周期**，pl011_create 只是把这个流程打包成一个函数。

## 流程


```c
/* hw/char/pl011.c */
static const TypeInfo pl011_arm_info = {
    .name          = TYPE_PL011,
    .parent        = TYPE_SYS_BUS_DEVICE,
    .instance_size = sizeof(PL011State),
    .instance_init = pl011_init,
    .class_init    = pl011_class_init,
};

static const TypeInfo pl011_luminary_info = {
    .name          = TYPE_PL011_LUMINARY,
    .parent        = TYPE_PL011,
    .instance_init = pl011_luminary_init,
};

static void pl011_register_types(void)
{
    type_register_static(&pl011_arm_info);
    type_register_static(&pl011_luminary_info);
}

type_init(pl011_register_types)
```


这里的类型注册流程是第一步；

`PL011State` 的字段的角色是怎样的，以 `RX FIFO` 为例，

我们用真实硬件中的 RX-FIFO 和这里的 RX-FIFO 做一个对应来看一看:

```c
struct PL011State {
    //...
    uint32_t read_fifo[PL011_FIFO_DEPTH];
    int read_ops;
    int read_count;
    int read_trigger;
    //...
}
```

真实硬件中，

UART 收发是按位、按字节串行完成的，速度通常远慢于 CPU，也和软件响应速度不对齐。没有 RX FIFO 时，路径大致是：

> 串口线上来 1 个字节 → 放进 RDR（Receive Data Register）→ 立刻要靠 CPU 读走
> 若 CPU 稍晚才读，下一个字节会覆盖上一个 → 丢数据（overrun）。

有 RX FIFO 后：

> 串口线 → 移位寄存器拼成字节 → 推进 RX FIFO（最多 16 项）→ CPU 从 UARTDR 按序弹出

也就是说，可以不需要对位轮询了，可以一次一批;

PL011 规格里：FIFO 使能时深度通常是 16；关闭 FIFO 时深度退化为 1（只有 holding register）。

那QEMU中如何对这个RX FIFO建模的？这几个字段有啥作用，大概如下：

chardev 有数据：
1. pl011_can_receive ?  还能塞多少bytes -- read_count
2. pl011_receive:
    foreach Byte:
    1. pl011_fifo_rx_put
    2. read_count++
    3. read_trigger ? --> 更新IRQ


## 集成到machine

arm/virt.c中 `create_uart` 使用的是 pl011:

```c
static void create_uart(const VirtMachineState *vms, int uart,
                        MemoryRegion *mem, Chardev *chr, bool secure)
{
    //...
    DeviceState *dev = qdev_new(TYPE_PL011);
    SysBusDevice *s = SYS_BUS_DEVICE(dev);

    qdev_prop_set_chr(dev, "chardev", chr);
    sysbus_realize_and_unref(s, &error_fatal);
    memory_region_add_subregion(mem, base, sysbus_mmio_get_region(s, 0));
    sysbus_connect_irq(s, 0, qdev_get_gpio_in(vms->gic, irq));
    //...
}
```

## summary

1. QOM: type_init / type_register
   → QEMU 知道有 TYPE_PL011 及其继承关系（尚无实例）

2. pl011_class_init（首次用类型时）
   → 规定 realize / reset / vmstate / 属性 schema

3. machine create_uart 开始：
   qdev_new → pl011_init(instance_init)
   → 建 MMIO 区+绑 ops、声明 IRQ 脚、clock、id
   （此时寄存器/FIFO 的“硬件复位语义”还没靠 reset 收尾）

4. 仍在 create_uart：
   prop_set_chr → realize(pl011_realize 挂 chardev 回调)
                → reset(pl011_reset 寄存器/FIFO 进默认态)
   → map MMIO 基址、connect_irq 到 GIC、写 DT

5. 运行时 · Guest 访存
   → Memory 命中已 map 的 region → pl011_read/write
   → 改状态 → pl011_update → qemu_set_irq

6. 运行时 · IRQ
   → 设备维护 int_level/int_enabled，经 irq[] 输出到 GIC → CPU → Guest

7. 运行时 · chardev
   → Host 输入走 can_receive/receive；Guest 输出走 write_all

8. Guest
   → 发现设备、访问寄存器、处理中断；与 Host 经 UART 模型交换字节


展开为树状过程：

```
[进程启动]
   │
   ├─① type_init → type_register_static     ← 只有“说明书进目录”
   │     class_init（首次用到类型时）        ← 填 DeviceClass 虚表/属性
   │
[用户: qemu-system-aarch64 -M virt -serial mon:stdio ...]
   │
   ├─② 机型 board init → create_uart()
   │     qdev_new(TYPE_PL011)               ← 分配 PL011State
   │       └─ instance_init (pl011_init)    ← 焊好 MMIO 区域、IRQ 插针、时钟输入
   │     qdev_prop_set_chr(...)             ← 把“第 0 路串口后端”塞进属性
   │     sysbus_realize_and_unref()         ← 调用 pl011_realize：挂 chardev 回调
   │       └─ (框架) device reset           ← pl011_reset：寄存器进上电默认
   │     memory_region_add_subregion()      ← 把 4KB MMIO 窗口贴到物理地址
   │     sysbus_connect_irq(..., gic)       ← 把组合中断脚接到 GIC SPI
   │     FDT 写节点                         ←  这里已经到软件测进行dt描述了，告诉 Guest “这里有个 arm,pl011”
   │
[Guest 跑起来]
   │
   ├─③ Guest 读/写 UART 寄存器
   │     Memory 层 → pl011_read / pl011_write
   │       └─ 改 flags/FIFO/int_* → pl011_update → qemu_set_irq
   │            └─ GIC → CPU → Guest ISR
   │
   ├─④ Host 有输入 (键盘/pty)
   │     Chardev → can_receive / receive / event
   │       └─ 进 RX FIFO → 可能拉 INT_RX → 同③的 IRQ 路径
   │
   ├─⑤ Guest 输出
   │     写 UARTDR → pl011_write_txdata → qemu_chr_fe_write_all → Host 终端
   │
[可选: migrate]
   │
   └─⑥ vmstate_pl011 保存/恢复寄存器与 FIFO（时钟 subsection 可选）

```

## VM热迁移迁移时钟

> 虚拟机热迁移时，要不要把 PL011 这根输入时钟（Clock）的状态一起存进迁移镜像、到目标机再恢复?

迁移时要带走的是 设备状态快照(guest不感知)，例如：

• 寄存器：lcr、cr、ibrd…
• RX FIFO 里还没读的字节
• 中断 mask / pending

这些在 vmstate_pl011 主表里.

> Clock state is not migrated automatically.Every device must handle its clock migration.

```c
PL011 的做法是：单独开一个 subsection，由开关控制：

/* 只有 migrate_clk == true 时才发送/接收这块 */
static bool pl011_clock_needed(void *opaque) {
    return s->migrate_clk;
}

vmstate_pl011_clock = {
    .needed = pl011_clock_needed,
    .fields = { VMSTATE_CLOCK(clk, PL011State), ... }
};

DEFINE_PROP_BOOL("migrate-clk", PL011State, migrate_clk, true);
```

## 通用外设建模流程


> 以 SysBus + MMIO 平台设备为准（串口 / GPIO / 定时器这一路）。PL011 是样板，下面是**可复用的套路**，不是再抄一遍 PL011。

### 先记住三层分工

```text
① 设备模型（芯片 IP）  →  状态长什么样、被摸到时怎么办
② 构建配置（进编译）  →  文件能链进 QEMU
③ 机型集成（焊到板）  →  地址 / IRQ / 后端 / DT
```

设备代码**不知道**自己挂在 `0x09000000` 还是别的地方；基址和接哪根 GIC，是机型的事。

### 建模流程（when）

| 顺序 | 做什么 | 别搞混 |
|------|--------|--------|
| 1 | `type_register` | 只进类型目录，没有实例 |
| 2 | `class_init` | 钉 realize / reset / props / vmsd（一类一份） |
| 3 | `qdev_new` → `instance_init` | 焊盘：MMIO 区 + 绑 ops、声明 IRQ 脚 |
| 4 | `prop_set_*` | 板级配置（如 chardev） |
| 5 | `realize` | 绑可能失败的资源（chardev handlers…） |
| 6 | `reset` | 寄存器 / FIFO **硬件复位语义**（不是 init 干的） |
| 7 | 机型 map + `connect_irq` +（可选）FDT | Guest 看得见、打断得了、驱动找得到 |
| 8 | 跑起来 | MMIO / IRQ / chardev 三条线事件驱动 |

**硬顺序：** type → new/init → prop → realize → map/connect。  
**常见坑：** 把 `instance_init` 当成「寄存器都 init 完了」——那是 `reset`。

### 代码改动落点（改哪些文件）

| 文件 | 干什么 |
|------|--------|
| `include/hw/<子系统>/foo.h` | `TYPE_FOO`、`FooState`、对外 API（可选） |
| `hw/<子系统>/foo.c` | 设备全部逻辑 + `type_init` |
| `hw/<子系统>/meson.build` | `files('foo.c')` 编进去 |
| `hw/<子系统>/Kconfig` + 机型 `select FOO` | 配置项，别漏 select |
| 机型（如 `hw/arm/virt.c` / G233） | new → prop → realize → map → irq → DT |

按需再动：trace-events、qtest、时钟接线、迁移 subsection。

### `.h` 里状态结构要装什么

```c
struct FooState {
    SysBusDevice parent_obj;   /* 必须第一个 */
    MemoryRegion iomem;        /* MMIO 窗口 */
    qemu_irq irq;              /* 或 irq[N] */
    /* 寄存器 + 内部状态（FIFO 指针等） */
    /* 可选：CharFrontend chr; Clock *clk; */
};
```

一句话：`FooState` = 这块芯片内部，Guest 可见寄存器 + 实现需要的隐藏场。

### `.c` 里该出现的代码块（按职责，不按行号）

| 块 | 职责 |
|----|------|
| 位域 / 偏移宏 | 规格对照表 |
| `foo_read` / `foo_write` + `MemoryRegionOps` | Guest 访存入口 |
| `foo_update` | `int_level & int_enabled` → `qemu_set_irq` |
| 核心行为函数 | FIFO 入出、写后端……给 MMIO 和 chardev 共用 |
| `instance_init` | `memory_region_init_io` + `sysbus_init_mmio/irq` |
| `realize` | 例如 `qemu_chr_fe_set_handlers` |
| `reset` | 上电默认值 |
| `Property[]` | 暴露 chardev 等 |
| `VMStateDescription` | 要热迁移就写；后加字段用 subsection |
| `class_init` | 挂 realize/reset/props/vmsd |
| `TypeInfo` + `type_init` | 注册进 QOM |

串口类多一条：**Host 字节走 chardev，不走 MMIO**；两边改同一份 state，再汇合到 `update` 拉中断。

### 机型侧最小胶水

```c
dev = qdev_new(TYPE_FOO);
qdev_prop_set_chr(dev, "chardev", serial_hd(0));  /* 有后端才要 */
sysbus_realize_and_unref(sbd, &error_fatal);
memory_region_add_subregion(mem, base, sysbus_mmio_get_region(sbd, 0));
sysbus_connect_irq(sbd, 0, qdev_get_gpio_in(gic, irq));
/* 可选：FDT compatible/reg/interrupts */
```

### 运行时就三张图

```text
Guest MMIO  ──► read/write ──► 改 state ──► update ──► IRQ ──► GIC
Host 输入   ──► can_receive / receive ──► FIFO ──► 同上
Guest 输出  ──► 写数据寄存器 ──► chr_fe_write ──► Host
```

### 自检清单

- [ ] type / class / instance / realize / reset 职责没混
- [ ] MMIO ops 在 init 绑好，**map 之后** Guest 才能踩到
- [ ] IRQ：init 声明脚 → 机型接线 → 运行时 `qemu_set_irq`
- [ ] meson + Kconfig + 机型 select
- [ ] 该迁的状态进了 vmstate（时钟默认不自动迁）

### 一句话
