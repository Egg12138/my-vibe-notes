# Linux Kernel CPU Context Switch & Virtualization I/O Performance

[toc]

---

## 1. Overview

This note covers four layers of "context switching" in Linux, from ordinary
process scheduling to VM-level mode transitions, and analyzes how different
I/O virtualization strategies reduce overhead (measured in VM Exits).

| Layer | What Switches | Approximate Cost |
|---|---|---|
| Process context switch | registers, stack, MM (CR3) | ~1-2 μs |
| VM Exit (KVM) | full CPU mode + VMCS state | ~5-50+ μs |
| Virtio (with vhost + suppression) | batched notification (VM Exit) | N:1 ratio |
| VFIO passthrough (DMA) | **none** — IOMMU handles it | 0 VM Exits on data path |

---

## 2. Process Context Switch (Normal)

### 2.1 Two-Layer Design

A process context switch always involves two parts: **MM switch** and
**register/stack switch**.

#### Layer 1: MM (Memory Context) Switch

In `context_switch()` (`kernel/sched/core.c:5328-5392`), the kernel decides
whether to do a full `switch_mm()` (swap CR3 / page table root) or use lazy
TLB mode, depending on the prev/next task types:

```c
// kernel/sched/core.c:5342-5375
/*
 * kernel -> kernel   lazy + transfer active
 *   user -> kernel   lazy + mmgrab_lazy_tlb() active
 * kernel ->   user   switch + mmdrop_lazy_tlb() active
 *   user ->   user   switch
 */
if (!next->mm) {                // to kernel thread
    enter_lazy_tlb(prev->active_mm, next);
    next->active_mm = prev->active_mm;
} else {                        // to user process
    switch_mm_irqs_off(prev->active_mm, next->mm, next);
}
```

Four modes:

| from → to | MM Action | Cost |
|---|---|---|
| user → user | Full `switch_mm` (swap CR3) | Heavy |
| user → kernel | Lazy TLB (reuse active_mm) | Light |
| kernel → user | Full `switch_mm` | Heavy |
| kernel → kernel | Lazy TLB | Light |

#### Layer 2: Register / Stack Switch

`switch_to(prev, next, last)` (`arch/x86/include/asm/switch_to.h:49-52`)
expands to a call to `__switch_to_asm()`, which is the **only place** where
the kernel stack actually changes.

##### Assembly Phase: `__switch_to_asm`

(`arch/x86/entry/entry_64.S:177-217`)

```asm
SYM_FUNC_START(__switch_to_asm)
    ; Save callee-saved registers onto current stack
    pushq %rbp
    pushq %rbx
    pushq %r12 / %r13 / %r14 / %r15

    ; Swap stacks — THIS is the actual "context switch"
    movq %rsp, TASK_threadsp(%rdi)   ; prev->thread.sp = current RSP
    movq TASK_threadsp(%rsi), %rsp   ; RSP = next->thread.sp

    ; Security: fill RSB to prevent speculation attacks
    FILL_RETURN_BUFFER ...

    ; Restore next's callee-saved regs from its stack
    popq %r15 / %r14 / %r13 / %r12 / %rbx / %rbp

    jmp __switch_to               ; tail-call to C handler
SYM_FUNC_END(__switch_to_asm)
```

The stack frame layout is defined by `struct inactive_task_frame`
(`switch_to.h:23-42`):

```c
struct inactive_task_frame {
    unsigned long r15, r14, r13, r12;  // x86-64 callee-saved
    unsigned long bx;
    unsigned long bp;      // frame pointer
    unsigned long ret_addr; // return address → __switch_to
};
```

##### C Phase: `__switch_to()`

(`arch/x86/kernel/process_64.c:609-713`)

The C handler saves/restores everything the assembly didn't cover:

1. **FPU (lazy save)** — `switch_fpu()` (`arch/x86/include/asm/fpu/sched.h:32-53`):

   ```c
   static inline void switch_fpu(struct task_struct *old, int cpu)
   {
       if (!test_tsk_thread_flag(old, TIF_NEED_FPU_LOAD) &&
           cpu_feature_enabled(X86_FEATURE_FPU) &&
           !(old->flags & (PF_KTHREAD | PF_USER_WORKER))) {
           set_tsk_thread_flag(old, TIF_NEED_FPU_LOAD);
           save_fpregs_to_fpstate(old_fpu);  // save AVX/SSE/FPU to memory
           old_fpu->last_cpu = cpu;
       }
   }
   ```

   FPU is **lazy**: save on switch-out, but **delay restore** until the
   process returns to userspace (via `#NM` exception trap). Kernel threads
   (`PF_KTHREAD`) skip FPU handling entirely.

2. **Segment registers** — FS, GS, DS, ES selectors and bases
3. **TLS (Thread-Local Storage)** descriptors in GDT
4. **PKRU** (Protection Key Rights for Userspace)
5. **CPU-local variables** — `current_task`, `cpu_current_top_of_stack`
6. **TSS sp0** — update RSP0 so the next kernel entry uses the correct stack
7. **Intel CAT / AMD workload class** — PQR MSR / HRST MSR
8. **AMD SS workaround** — null SS selector fixup

### 2.2 New Process Entry (`ret_from_fork`)

A newly forked process "context switches in" at `ret_from_fork_asm`
(`arch/x86/entry/entry_64.S:228-260`), not through `__switch_to_asm`. The
fork setup in `copy_thread()` places a synthetic `inactive_task_frame` on the
new task's stack so that when the scheduler picks it, the `popq` sequence in
`__switch_to_asm` produces the right register state.

---

## 3. VM Exit Context Switch (KVM)

A **VM Exit** is a CPU-enforced mode transition triggered by hardware when
the guest executes a privileged instruction, accesses a trapped MMIO region,
or receives an interrupt. It is fundamentally heavier than a process context
switch.

### 3.1 The VM Exit Path (End to End)

#### Phase 1: Preparation — `vcpu_enter_guest()`

(`arch/x86/kvm/x86.c:11167`)

```c
static int vcpu_enter_guest(struct kvm_vcpu *vcpu)
{
    // Process pending requests (TLB flush, MMU sync, timers, IRQs...)
    kvm_x86_call(prepare_switch_to_guest)(vcpu);  // save host FS/GS/GS_BASE
    local_irq_disable();         // CRITICAL: no interrupts during transition
    vcpu->mode = IN_GUEST_MODE;  // memory barrier for posted interrupts

    switch_fpu_return();         // flush host FPU
    kvm_load_xfeatures(vcpu, true);  // XRSTOR guest XSAVE area
    // Configure debug registers, PKRU, PMU...

    exit_fastpath = kvm_x86_call(vcpu_run)(vcpu, run_flags);
    // ===== CPU returns here after VM Exit =====

    vcpu->mode = OUTSIDE_GUEST_MODE;
    kvm_load_xfeatures(vcpu, false);        // XRSTOR host XSAVE area
    kvm_x86_call(handle_exit_irqoff)(vcpu); // dispatch exit reason
}
```

`vmx_prepare_switch_to_guest()` (`arch/x86/kvm/vmx/vmx.c:1316-1387`):

- Saves host FS/GS selectors and bases into `vmcs_host_state`
- Sets guest `GS_BASE` MSR
- Loads "uret MSRs" (MSRs that must differ guest vs host but are
  auto-restored by CPU on VM Exit: `LSTAR`, `CSTAR`, `SF_MASK`, etc.)

#### Phase 2: Assembly VM Entry — `__vmx_vcpu_run`

(`arch/x86/kvm/vmx/vmenter.S:79-270`)

```asm
SYM_FUNC_START(__vmx_vcpu_run)
    push %rbp / push %r15..%r12 / push %rbx   ; save host callee-saved
    push %rdi  ; @vmx
    push %r8   ; @flags
    push %rsi  ; @regs

    ; SPEC_CTRL MSR switch (Spectre v2 mitigation)
    mov VMX_spec_ctrl(%rdi), %rdx
    wrmsr MSR_IA32_SPEC_CTRL

    ; Load all guest general-purpose registers from vcpu->arch.regs
    mov VCPU_RCX(%rax), %rcx
    mov VCPU_RDX(%rax), %rdx
    ; ... r8-r15, rbp, rsi, rdi, rax ...

    VERW      ; clear CPU buffers (MMIO stale data mitigation)

    vmresume / vmlaunch
    ; ================================================
    ; CPU HARDWARE performs (in microcode):
    ;   VM Entry: load guest CR0/CR3/CR4/RSP/RIP/RFLAGS/
    ;             segments/EFER from VMCS
    ;   ... guest runs ...
    ;   VM Exit:  save guest CR0/CR3/CR4/RSP/RIP/RFLAGS/
    ;             segments/EFER to VMCS
    ;             load host CR0/CR3/CR4/RSP/RIP from VMCS
    ;             write exit reason + qualification to VMCS
    ; ================================================

SYM_INNER_LABEL_ALIGN(vmx_vmexit, SYM_L_GLOBAL)
    ; Save all guest GP registers back to vcpu->arch.regs
    push %rax
    mov (%rsp), %rax    ; reload @regs pointer
    pop VCPU_RAX(%rax)
    mov %rcx, VCPU_RCX(%rax)
    ; ... save all guest registers ...

    ; Clear all GP registers (security: prevent speculative
    ; use of guest-controlled values in host context)
    xor %eax,%eax / xor %ecx,%ecx / ... / xor %r15d,%r15d
    ret
```

### 3.2 Why VM Exit Is Heavier

| Dimension | Process Switch | VM Exit |
|---|---|---|
| **GP registers** | 6 callee-saved (push/pop) | 16 GP regs fully saved (guest → struct) |
| **Control registers** | Only CR3 (if switch_mm) | CR0/CR3/CR4 auto-saved/loaded by CPU |
| **Segments** | FS/GS (2 selectors + bases) | CS/SS/DS/ES/FS/GS + GDT/LDT → fully switched via VMCS |
| **MSRs** | ~1 (PQR MSR for CAT) | EFER, SPEC_CTRL, SYSENTER, STAR, LSTAR, CSTAR, SF_MASK, PAT, etc. |
| **FPU/XSAVE** | Lazy save (no restore until userspace) | Full XSAVE on entry, full XRSTOR on exit |
| **TLB effects** | PCID mitigates CR3 flush | VPID mitigates but EPT TLB may partially invalidate |
| **Security** | RSB fill | RSB fill + VERW (buffer clear) + possible IBPB |
| **Hardware assist** | None | CPU microcode-assisted VMCS read/write (4KB+) |
| **Typical latency** | ~1-2 μs | ~5-50+ μs |

**Root cause**: VM Exit is not a "design choice" — it is the **hardware
guarantee of isolation**. The CPU must ensure zero guest state leaks into
host context. The VMCS data structure (~4 KB) holds all state the CPU
auto-saves/restores during the transition.

---

## 4. VFIO / IOMMU Device Passthrough

### 4.1 Core Idea

> Let the IOMMU translate guest-physical DMA addresses to host-physical
> addresses **in hardware**, eliminating the hypervisor from the data path.

### 4.2 How It Works (Code Trail)

#### Step 1: User Space Requests DMA Mapping

QEMU calls `VFIO_IOMMU_MAP_DMA` ioctl → `vfio_dma_do_map()`
(`drivers/vfio/vfio_iommu_type1.c:1680-1789`):

```c
static int vfio_dma_do_map(struct vfio_iommu *iommu,
                           struct vfio_iommu_type1_dma_map *map)
{
    dma_addr_t iova = map->iova;     // guest physical address (IOVA)
    unsigned long vaddr = map->vaddr; // host virtual address
    size_t size = map->size;

    while (size) {
        // Pin host pages (prevent swap-out)
        npage = vfio_pin_pages_remote(dma, vaddr + dma->size,
                                      size >> PAGE_SHIFT, &pfn, limit, &batch);
        // Program IOMMU page table: IOVA → HPA
        ret = vfio_iommu_map(iommu, iova + dma->size, pfn, npage, dma->prot);
    }
}
```

**Key operation**: This maps the **guest-physical address range** (`iova`)
to the **host-physical page frames** (`pfn`) directly in the IOMMU hardware
page table.

#### Step 2: IOMMU Context Entry Programming (Intel VT-d)

`intel_iommu_attach_device()` → `dmar_domain_attach_device()` →
`domain_context_mapping()` → `domain_context_mapping_one()`
(`drivers/iommu/intel/iommu.c:1142-1195`):

```c
static int domain_context_mapping_one(struct dmar_domain *domain,
                                      struct intel_iommu *iommu,
                                      u8 bus, u8 devfn)
{
    struct context_entry *context;
    u16 did = domain_id_iommu(domain, iommu);

    context = iommu_context_addr(iommu, bus, devfn, 1);
    context_set_domain_id(context, did);
    context_set_address_root(context, pt_info.ssptptr);  // page table root
    context_set_translation_type(context, translation);  // MULTI_LEVEL or DEV_IOTLB
    context_set_present(context);                         // activate!
}
```

This writes a **context entry** into the IOMMU root table. The entry tells
the IOMMU: "for this PCI device (bus:dev.func), use this page table to
translate all DMA addresses."

#### Step 3: DMA Path After Passthrough

```
Guest driver: programs DMA address = GPA (guest-physical address)
    ↓
PCI device: issues DMA transaction with address = GPA
    ↓
IOMMU (VT-d): intercepts DMA on the bus
    → walks IOMMU page table: GPA → HPA
    → forwards DMA to host physical memory
    ↓
DMA completes — NO VM EXIT, NO HYPERVISOR INVOLVEMENT
```

### 4.3 Why It Reduces Overhead

| Operation | Emulated Device | VFIO Passthrough |
|---|---|---|
| DMA data transfer | VM Exit per buffer → QEMU copies data | **0 VM Exits** (IOMMU translates in HW) |
| MMIO config access | VM Exit → QEMU emulates | Passthrough BAR: 0 exits; config space: 1 exit |
| Interrupt delivery | VM Exit → QEMU injects IRQ | Posted Interrupt / APICv → direct delivery |

**Important caveat**: Passthrough eliminates VM Exits on the **data path**
(DMA). Control-path operations (PCI config space, MSI-X table setup) may
still trap depending on hardware support (SR-IOV, ACS, etc.).

---

## 5. Virtio Paravirtualized I/O

### 5.1 The virtqueue: Shared Memory Ring

Virtio replaces hardware emulation with a **shared memory ring buffer**
between guest and host. The data structures are defined in
`include/uapi/linux/virtio_ring.h`:

```
┌─────────────────────────────────────────────────────┐
│  Descriptor Table (array of vring_desc)              │
│  ┌────────┬──────┬───────┬──────┐                    │
│  │ addr   │ len  │ flags │ next │  ← buffer metadata │
│  └────────┴──────┴───────┴──────┘                    │
├─────────────────────────────────────────────────────┤
│  Available Ring (guest → host)                       │
│  ┌───────┬─────┬────────────────────────┐           │
│  │ flags │ idx │ ring[] (descriptor IDs)│           │
│  └───────┴─────┴────────────────────────┘           │
├─────────────────────────────────────────────────────┤
│  Used Ring (host → guest)                            │
│  ┌───────┬─────┬──────────────────────────────┐     │
│  │ flags │ idx │ ring[] (used elem: id + len) │     │
│  └───────┴─────┴──────────────────────────────┘     │
└─────────────────────────────────────────────────────┘
```

```c
struct vring_desc {
    __virtio64 addr;   // guest-physical buffer address
    __virtio32 len;
    __virtio16 flags;  // VRING_DESC_F_NEXT | F_WRITE | F_INDIRECT
    __virtio16 next;
};

struct vring_avail {
    __virtio16 flags;
    __virtio16 idx;    // guest increments this to "publish" new buffers
    __virtio16 ring[];
};

struct vring_used {
    __virtio16 flags;
    __virtio16 idx;    // host increments this to signal completion
    struct vring_used_elem ring[];  // {id, len}
};
```

### 5.2 The Key Optimization: Notification Suppression

The "kick" (VM Exit on the PCI doorbell) is the expensive part. Virtio has
two mechanisms to suppress unnecessary kicks:

#### Mechanism 1: Flag-Based Suppression

```c
// include/uapi/linux/virtio_ring.h:54
#define VRING_USED_F_NO_NOTIFY  1
// Host sets this in used->flags → "don't kick me, I'll poll"
```

#### Mechanism 2: Event Index Suppression (VIRTIO_RING_F_EVENT_IDX)

```c
// include/uapi/linux/virtio_ring.h:84
#define VIRTIO_RING_F_EVENT_IDX  29
// Host publishes: "I've consumed up to index X"
// Guest only kicks when avail_idx passes X
```

The guest-side implementation in `virtqueue_kick_prepare_split()`
(`drivers/virtio/virtio_ring.c:794-822`):

```c
static bool virtqueue_kick_prepare_split(struct vring_virtqueue *vq)
{
    u16 new, old;
    bool needs_kick;

    virtio_mb(vq->weak_barriers);  // ensure descriptor writes are visible

    old = vq->split.avail_idx_shadow - vq->num_added;
    new = vq->split.avail_idx_shadow;
    vq->num_added = 0;

    if (vq->event) {
        // Event-index mode: compare avail_idx against host's avail_event
        needs_kick = vring_need_event(
            virtio16_to_cpu(vring_avail_event(&vq->split.vring)),
            new, old);
    } else {
        // Flag mode: check VRING_USED_F_NO_NOTIFY
        needs_kick = !(vq->split.vring.used->flags &
                       cpu_to_virtio16(VRING_USED_F_NO_NOTIFY));
    }
    return needs_kick;
}
```

**Result**: After the first kick, the host processes available buffers and
updates `avail_event`. The guest then batches multiple new buffers **without
any VM Exit**, only kicking when the batch exceeds a threshold.

### 5.3 Usage Pattern (virtio-net)

In `drivers/net/virtio_net.c`, the typical send path:

```c
// Batch N packets into the available ring...
for (...) {
    virtqueue_add_outbuf(sq->vq, ...);
}

// One conditional kick — may be suppressed entirely
if (virtqueue_kick_prepare(sq->vq) && virtqueue_notify(sq->vq))
    // Only 1 VM Exit for N packets (or 0 if host is polling)
```

### 5.4 vhost: Kernel-Side Backend (Eliminates Userspace)

vhost moves the backend from QEMU (userspace) into the kernel. In
`drivers/vhost/net.c:1288-1360`:

```c
static void handle_tx_kick(struct vhost_work *work)
{
    struct vhost_virtqueue *vq = container_of(work, ...);
    struct vhost_net *net = container_of(vq->dev, ...);
    handle_tx(net);  // process virtqueue directly in kernel!
}

// Registration:
n->vqs[VHOST_NET_VQ_TX].vq.handle_kick = handle_tx_kick;
n->vqs[VHOST_NET_VQ_RX].vq.handle_kick = handle_rx_kick;
```

When the guest kicks:
1. VM Exit occurs (unavoidable for the kick itself)
2. KVM receives the kick → signals vhost kernel thread via eventfd
3. vhost kernel thread wakes up, reads the available ring, processes packets
   (e.g., sends to kernel network stack via TAP), writes to used ring
4. vhost signals guest via irqfd (injects interrupt)

No QEMU userspace involved → saves context switches between kernel and
userspace on the host side.

### 5.5 Performance Summary

| I/O Stack | VM Exits per N pkts | Host Userspace Involved |
|---|---|---|
| Emulated (e1000/rtl8139) | ~N (per MMIO/PIO access) | Yes (QEMU) |
| Virtio (QEMU backend) | ~1 (with suppression) | Yes (QEMU) |
| Virtio + vhost | ~1 (with suppression) | **No** (kernel only) |
| VFIO passthrough | **0** (data path) | No |

---

## 6. Putting It All Together

```
                   ┌──────────────────────────────────────┐
                   │         GUEST (VM)                    │
                   │                                      │
                   │  Process A ←──→ Process B            │
                   │      ↑ context_switch() ~1-2μs       │
                   │                                      │
                   │  virtio driver:                      │
                   │    batch N bufs → 1 kick             │
                   │    ↓                                 │
                   ═══════════════ VM Exit ~5-50μs ════════
                   │    ↑                                 │
                   │  KVM host:                           │
                   │    handle_exit() → dispatch          │
                   │    ↓                                 │
                   │  vhost kernel thread:                │
                   │    handle_tx/rx_kick()               │
                   │    process virtqueue → TAP           │
                   │                                      │
                   │    OR (VFIO passthrough):            │
                   │    DMA goes directly through IOMMU   │
                   │    GPA ──IOMMU──→ HPA                │
                   │    ZERO VM exits on data path         │
                   └──────────────────────────────────────┘
```

**Takeaway**: The progression from emulated I/O → virtio → virtio+vhost →
VFIO passthrough is a progressive elimination of VM Exits from the I/O data
path. Each step removes one more layer of software intervention, converging
toward bare-metal I/O performance.

---

<!--
  Source: Linux kernel v7.1-rc4
  Generated: 2026-06-28 15:00:51 UTC
-->
