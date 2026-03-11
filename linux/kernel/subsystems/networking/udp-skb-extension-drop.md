# UDP SKB Extension Drop Mechanism

[TOC]

## Version Info
- **Kernel Version**: Linux 5.10-rc7 (commit: 0477e9288185)
- **Created**: 2026-03-02

---

## Summary

This note documents the complete function call chain for how the Linux kernel UDP receive path handles and drops skb (socket buffer) extensions. SKB extensions are optional metadata attached to network packets for features like connection tracking (conntrack), security paths (secpath), and netfilter tracking. Understanding when and how these extensions are released is crucial for kernel networking debugging and performance analysis.

Key findings:
1. Extensions are dropped at **two distinct points**: early conntrack drop during queue, and full extension release during skb consumption
2. An optimization path (`udp_try_make_stateless`) clears extensions early when no security path exists
3. The drop mechanism uses reference counting for safe shared skb handling

---

## Beginner Section: What are SKB Extensions?

### Overview

In the Linux networking stack, an `sk_buff` (skb) is the fundamental data structure representing a network packet. **SKB extensions** are optional metadata blocks that can be attached to skbs to store additional information needed by various kernel subsystems.

### Common SKB Extension Types

| Extension ID | Purpose | Used By |
|--------------|---------|---------|
| `SKB_EXT_CONNTRACK` | Connection tracking state | Netfilter/iptables |
| `SKB_EXT_SEC_PATH` | IPsec security path | XFRM/IPsec |
| `SKB_EXT_BRIDGE_NETFILTER` | Bridge netfilter info | Bridge + netfilter |
| `SKB_EXT_CT_END` | Conntrack end marker | Netfilter |

### Why Drop Extensions?

Extensions consume memory and may contain namespace-specific or connection-specific state. They must be dropped:
- **Security**: Prevent leakage of connection state across namespace boundaries
- **Memory**: Free resources when no longer needed
- **Correctness**: Avoid stale state affecting future packet processing

### Basic Lifecycle

```
Packet arrives → Extensions added (by netfilter) → Processing → Extensions dropped → skb freed
```

---

## Expert Section: Complete Function Call Chain

### Receive Entry Points

UDP packets enter the receive path through multiple entry points:

```
ip_local_deliver()
    └── udp_rcv()
        └── __udp_queue_rcv_skb()   # Socket found, queue packet
        └── __udp4_lib_mcast_deliver() # Multicast
        └── (no socket path)         # No listening socket
```

### Path 1: Normal Receive (Socket Found)

```c
// File: net/ipv4/udp.c
// Function: udp_queue_rcv_one_skb()

int udp_queue_rcv_one_skb(struct sock *sk, struct sk_buff *skb)
{
    // ... validation ...

    // STEP 1: Early conntrack drop (line 2068)
    if (!xfrm4_policy_check(sk, XFRM_POLICY_IN, skb))
        goto drop;
    nf_reset_ct(skb);  // <-- Drops SKB_EXT_CONNTRACK only

    // ... encapsulation handling ...

    // STEP 2: Queue to receive queue
    __skb_queue_tail(&sk->sk_receive_queue, skb);

    // Notify application
    sk->sk_data_ready(sk);
}
```

**Call chain for `nf_reset_ct()`:**
```
nf_reset_ct(skb)
├── nf_conntrack_put(skb_nfct(skb))   // Decrement conntrack refcount
└── skb->_nfct = 0                     // Clear pointer
```

### Path 2: No Socket Found

```c
// File: net/ipv4/udp.c
// Function: __udp4_lib_lookup_skb()

if (!xfrm4_policy_check(NULL, XFRM_POLICY_IN, skb))
    goto drop;
nf_reset_ct(skb);  // <-- Line 2398: Early conntrack drop

// No socket, checksum complete, send ICMP error
icmp_send(skb, ICMP_DEST_UNREACH, ICMP_PORT_UNREACH, 0);
kfree_skb(skb);  // <-- Full extension drop via skb_release_all()
```

### Path 3: Stateless Optimization

When queuing packets, UDP attempts to make skbs "stateless" by removing unnecessary extensions:

```c
// File: net/ipv4/udp.c
// Function: udp_try_make_stateless()

static bool udp_try_make_stateless(struct sk_buff *skb)
{
    if (!skb_has_extensions(skb))
        return true;

    if (!secpath_exists(skb)) {
        skb_ext_reset(skb);  // <-- Clear ALL extensions
        return true;
    }

    return false;  // Keep extensions (secpath needed for recvmsg)
}
```

**Why preserve secpath?** The security path may be needed for `IP_CMSG_PASSSEC` at `recvmsg()` time.

**Call chain for `skb_ext_reset()`:**
```
skb_ext_reset(skb)
├── if (skb->active_extensions)
│   └── __skb_ext_put(skb->extensions)
│       ├── if refcount == 1: kfree(ext)  // Fast path
│       └── else: refcount_dec_and_test() // Slow path
```

### Path 4: User Consumption (recvmsg)

When the application calls `recvmsg()`, the skb is consumed:

```c
// File: net/ipv4/udp.c
// Function: udp_recvmsg()

int udp_recvmsg(struct sock *sk, struct msghdr *msg, size_t len, ...)
{
    // Get skb from receive queue
    skb = __skb_recv_udp(sk, flags, noblock, &off, &err);

    // Copy data to user buffer
    err = skb_copy_datagram_msg(skb, off, msg, copied);

    // Consume skb after successful copy
    skb_consume_udp(sk, skb, err);
}
```

**Call chain for `skb_consume_udp()`:**
```
skb_consume_udp(sk, skb, len)
├── sk_peek_offset_bwd()  // Update peek offset
├── if (!skb_unref(skb)) return  // Still has references
├── if (udp_skb_has_head_state(skb))
│   └── skb_release_head_state(skb)  <-- Full extension drop
│       ├── skb_dst_drop()
│       ├── skb->destructor()
│       ├── nf_conntrack_put()
│       └── skb_ext_put(skb)         <-- Extensions freed
└── __consume_stateless_skb(skb)
    ├── skb_release_data()  // Free packet data
    └── kfree_skbmem(skb)   // Free skb struct
```

### Path 5: Error/Drop Path

When packets are dropped due to errors:

```c
// File: net/core/skbuff.c

void kfree_skb(struct sk_buff *skb)
{
    if (!skb_unref(skb))
        return;

    trace_kfree_skb(skb, __builtin_return_address(0));
    __kfree_skb(skb);
}

void __kfree_skb(struct sk_buff *skb)
{
    skb_release_all(skb);  // <-- Release everything
    kfree_skbmem(skb);
}

static void skb_release_all(struct sk_buff *skb)
{
    skb_release_head_state(skb);  // Extensions dropped here
    if (likely(skb->head))
        skb_release_data(skb);
}
```

---

## Function Reference Table

| Function | File:Line | Extensions Dropped | When Called |
|----------|-----------|-------------------|-------------|
| `nf_reset_ct()` | include/linux/skbuff.h:4254 | Conntrack only | Early in receive, before queue |
| `skb_ext_reset()` | include/linux/skbuff.h:4233 | All extensions | Stateless optimization |
| `skb_ext_put()` | include/linux/skbuff.h:4181 | All (refcounted) | Final release |
| `__skb_ext_put()` | net/core/skbuff.c:6304 | All (actual free) | When refcount reaches 0 |
| `skb_release_head_state()` | net/core/skbuff.c:646 | All | Part of skb free path |
| `skb_consume_udp()` | net/ipv4/udp.c:1604 | Conditional | After successful recvmsg |

---

## Memory Layout

### SKB Extension Structure

```c
// include/linux/skbuff.h

struct skb_ext {
    refcount_t refcnt;
    u8 active_extensions;  // Bitmap of active extension IDs
    u8 offset[SKB_EXT_NUM]; // Offset to each extension (8-byte chunks)
    u8 chunks;              // Total allocated chunks
    char data[] __aligned(8); // Extension data
};
```

### Extension Release Logic

```c
// include/linux/skbuff.h

static inline void skb_ext_put(struct sk_buff *skb)
{
    if (skb->active_extensions)
        __skb_ext_put(skb->extensions);
}

// net/core/skbuff.c

void __skb_ext_put(struct skb_ext *ext)
{
    // Fast path: last user, free immediately
    if (refcount_read(&ext->refcnt) == 1)
        goto free_now;

    // Slow path: shared, decrement and check
    if (!refcount_dec_and_test(&ext->refcnt))
        return;

free_now:
    kfree(ext);
}
```

---

## Timing Diagram

```
Time →

[Kernel]  ip_local_deliver()
              │
              ▼
          udp_rcv()
              │
              ▼
      __udp_queue_rcv_skb()
              │
              ├─→ nf_reset_ct(skb)  ....... [Conntrack dropped]
              │
              └─→ udp_try_make_stateless()
                    │
                    ├─→ [no secpath] → skb_ext_reset() → [All extensions dropped]
                    └─→ [has secpath] → keep for recvmsg
              │
              ▼
      Queue to sk_receive_queue
              │
              │  (packet waits for application)
              │
              ▼
      [Userspace] recvmsg()
              │
              ▼
          udp_recvmsg()
              │
              ├─→ __skb_recv_udp()
              │     └─→ udp_skb_destructor()  [Memory release only]
              │
              ├─→ Copy data to user
              │
              └─→ skb_consume_udp()
                    │
                    ├─→ [stateless] → __consume_stateless_skb()
                    │                 [Extensions already dropped]
                    │
                    └─→ [stateful] → skb_release_head_state()
                                     └─→ skb_ext_put()  [Extensions dropped]
```

---

## Key Insights

1. **Two-phase drop**: Conntrack is dropped early (before queue), other extensions may be kept until consumption
2. **Secpath preservation**: Security paths are preserved through the receive path for `IP_CMSG_PASSSEC`
3. **Reference counting**: Extensions use refcounting to handle shared skbs safely
4. **Stateless optimization**: When possible, extensions are cleared early to reduce memory pressure and cache misses
5. **Error path handling**: All error paths eventually call `kfree_skb()` which ensures complete extension cleanup

---

## Related Files

- `net/ipv4/udp.c` - Main UDP receive logic
- `net/core/skbuff.c` - SKB extension management
- `include/linux/skbuff.h` - SKB extension structures and inline functions
- `include/net/udp.h` - UDP header definitions
- `net/netfilter/nf_conntrack_core.c` - Conntrack implementation

---

## See Also

- [[iommu]] - IOMMU subsystem notes (similar memory management patterns)
- [[livepatch]] - Kernel live patching (affects running code paths)
