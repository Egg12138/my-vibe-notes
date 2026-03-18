# Linux Kernel Networking Data Flow - v5.10-rc7
## Comprehensive Analysis with Detailed Call Chains, Abbreviations, and Technical Terms

**by Analysis based on Linux 5.10-rc7 kernel source**

---

# Table of Contents

1. [Abbreviations and Glossary](#abbreviations-and-glossary)
2. [Technical Terms Explained](#technical-terms-explained)
3. [Core Data Structures](#core-data-structures)
4. [Transmission Path - Detailed Call Chain](#transmission-path---detailed-call-chain)
   - [Layer 5: Session Layer (System Call Entry)](#layer-5-session-layer-system-call-entry)
   - [Layer 4: Transport Layer (TCP Transmission)](#layer-4-transport-layer-tcp-transmission)
   - [Layer 3: Network Layer (IPv4 Transmission)](#layer-3-network-layer-ipv4-transmission)
   - [Layer 2: Link Layer (Ethernet Transmission)](#layer-2-link-layer-ethernet-transmission)
5. [Receive Flow - Detailed Call Chain](#receive-flow---detailed-call-chain)
   - [Driver Layer and XDP](#driver-layer-and-xdp)
   - [Layer 2: Link Layer (NAPI and GRO)](#layer-2-link-layer-napi-and-gro)
   - [Layer 3: Network Layer (IPv4 Reception)](#layer-3-network-layer-ipv4-reception)
   - [Layer 4: Transport Layer (TCP Reception)](#layer-4-transport-layer-tcp-reception)
   - [Layer 5: Session Layer (System Call Exit)](#layer-5-session-layer-system-call-exit)
6. [Advanced Features](#advanced-features)
7. [Function Reference Index](#function-reference-index)

---

# Abbreviations and Glossary

## Networking Abbreviations

| Abbreviation | Full Name | Description |
|--------------|-----------|-------------|
| **ACK** | Acknowledgment | TCP segment acknowledging received data |
| **AF** | Address Family | Socket address family (e.g., AF_INET, AF_INET6) |
| **AF_XDP** | Address Family XDP | XDP sockets for zero-copy to userspace |
| **API** | Application Programming Interface | Programming interface for applications |
| **ARP** | Address Resolution Protocol | Maps IP addresses to MAC addresses |
| **BPF** | Berkeley Packet Filter | Original filtering language |
| **eBPF** | Extended Berkeley Packet Filter | Extended BPF with more capabilities |
| **BSD** | Berkeley Software Distribution | Unix variant, socket API origin |
| **cgroups** | Control Groups | Linux kernel feature for limiting and accounting resources |
| **CPU** | Central Processing Unit | Processor core |
| **CWR** | Congestion Window Reduced | TCP flag indicating congestion |
| **DMA** | Direct Memory Access | Memory access without CPU intervention |
| **DSACK** | Duplicate Selective Acknowledgment | TCP extension for duplicate reporting |
| **ECE** | ECN-Echo | TCP flag for ECN support |
| **ECN** | Explicit Congestion Notification | Network congestion notification mechanism |
| **EINPROGRESS** | Error IN PROGRESS | Operation in progress (non-blocking) |
| **EAGAIN** | Error AGAIN | Try again (non-blocking would block) |
| **FIB** | Forwarding Information Base | Kernel routing table |
| **FIN** | Finish | TCP connection termination flag |
| **GRO** | Generic Receive Offload | Coalescing receive packets |
| **GSO** | Generic Segmentation Offload | Deferring segmentation to hardware |
| **HTCP** | Hamilton TCP | TCP congestion control algorithm |
| **ICMP** | Internet Control Message Protocol | Error and control messages |
| **ICSK** | INet Connection Sock | Internet connection socket structure |
| **IGMP** | Internet Group Management Protocol | Multicast group management |
| **INET** | Internet | Internet protocol family |
| **IP** | Internet Protocol | Network layer protocol |
| **IPSec** | Internet Protocol Security | IP security protocol suite |
| **ISR** | Interrupt Service Routine | Hardware interrupt handler |
| **L2** | Layer 2 | Data Link Layer (OSI model) |
| **L3** | Layer 3 | Network Layer (OSI model) |
| **L4** | Layer 4 | Transport Layer (OSI model) |
| **L5** | Layer 5 | Session Layer (OSI model) |
| **LLC** | Logical Link Control | IEEE 802.2 sublayer |
| **LRO** | Large Receive Offload | Hardware receive coalescing |
| **MAC** | Media Access Control | Hardware address |
| **md5** | Message Digest 5 | Cryptographic hash function |
| **MIB** | Management Information Base | SNMP statistics counters |
| **MPTCP** | Multipath TCP | TCP extension for multiple paths |
| **MSL** | Maximum Segment Lifetime | TCP time parameter |
| **MSS** | Maximum Segment Size | Maximum TCP data size |
| **MTU** | Maximum Transmission Unit | Maximum packet size |
| **NAPI** | New API | New polling API for drivers |
| **NEIGH** | NEIGHbor | Neighbor/ARP cache |
| **NETIF** | NETwork InterFace | Network interface |
| **NIC** | Network Interface Card | Network hardware |
| **OFO** | Out of Order | Queue for out-of-order TCP segments |
| **OOB** | Out of Band | Urgent TCP data |
| **OSI** | Open Systems Interconnection | Network reference model |
| **PF** | Protocol Family | Protocol family identifier |
| **pkt** | packet | Network data unit |
| **PSH** | PuSH | TCP push flag |
| **Qdisc** | Queueing Discipline | Traffic control queue |
| **RCU** | Read-Copy-Update | Lock-free synchronization mechanism |
| **recv** | receive | Receive operation |
| **RFS** | Receive Flow Steering | Flow-based packet steering |
| **RST** | ReSeT | TCP reset flag |
| **RTO** | Retransmission TimeOut | TCP retransmission timer |
| **RPS** | Receive Packet Steering | Software packet steering |
| **RSS** | Receive Side Scaling | Hardware packet distribution |
| **RTT** | Round Trip Time | Network latency measurement |
| **RX** | Receive | Receive path/direction |
| **SACK** | Selective ACKnowledgment | TCP selective acknowledgment option |
| **SDN** | Software Defined Networking | Network management paradigm |
| **send** | send | Send operation |
| **SG** | Scatter Gather | I/O vector operations |
| **skb** | SK Buff | Socket buffer (kernel packet structure) |
| **sk** | Sock | Socket structure |
| **SMB** | Server Message Block | File sharing protocol |
| **SNMP** | Simple Network Management Protocol | Network management protocol |
| **sock** | socket | Socket |
| **softirq** | software interrupt | Deferred interrupt handling |
| **SYN** | SYNchronize | TCP connection initiation flag |
| **TCP** | Transmission Control Protocol | Reliable transport protocol |
| **TC** | Traffic Control | Linux traffic control system |
| **TLS** | Transport Layer Security | Secure communication protocol |
| **TSO** | TCP Segmentation Offload | Hardware TCP segmentation |
| **TTL** | Time To Live | IP hop limit |
| **TX** | Transmit | Transmit path/direction |
| **UDP** | User Datagram Protocol | Unreliable transport protocol |
| **URG** | URGent | TCP urgent data flag |
| **VLAN** | Virtual LAN | Virtual local area network |
| **XDP** | eXpress Data Path | Early packet processing framework |
| **XPS** | Transmit Packet Steering | Transmit queue selection |

## Kernel-Specific Abbreviations

| Abbreviation | Full Name | Description |
|--------------|-----------|-------------|
| **BH** | Bottom Half | Deferrable work in Linux |
| **cpy** | copy | Copy operation |
| **ent** | entry | Function entry point |
| **evt** | event | Event occurrence |
| **f** | function | Function |
| **hdr** | header | Protocol header |
| **hw** | hardware | Hardware-related |
| **info** | information | Information structure |
| **lock** | lock | Synchronization primitive |
| **mib** | Management Information Base | Statistics counter |
| **msg** | message | Message structure |
| **ops** | operations | Virtual method table |
| **priv** | private | Private data |
| **ptr** | pointer | Memory pointer |
| **rcv** | receive | Receive operation |
| **snd** | send | Send operation |
| **src** | source | Source address |
| **stats** | statistics | Statistical counters |
| **tbl** | table | Data table |
| **xmit** | transmit | Transmit operation |

---

# Technical Terms Explained

## Socket Buffer (sk_buff / skb)

The **socket buffer** (`struct sk_buff`) is the fundamental data structure for network packet handling in Linux. It represents a network packet as it traverses the protocol stack.

**Key characteristics:**
- **Zero-copy design**: Minimizes data copying through header/data pointer manipulation
- **Dynamic headers**: Protocol headers are added by adjusting pointers, not copying data
- **Fragment support**: Can represent both linear and fragmented (paged) data
- **Reference counting**: Shared buffers via `skb->users` reference count

**Structure layout:**
```
+------------------+  <-- head (start of allocated memory)
|   headroom       |     Space for headers (L2, L3, L4)
+------------------+  <-- data (start of actual packet data)
|   packet data    |     Network packet (L2 header, L3, L4, payload)
+------------------+  <-- tail (end of packet data)
|   tailroom       |     Space for expansion
+------------------+  <-- end (end of allocated memory)
```

**Key fields:**
- `data`: Pointer to current packet data start
- `tail`: Pointer to current packet data end
- `head`: Start of allocated buffer
- `end`: End of allocated buffer
- `len`: Length of packet data
- `data_len`: Length of paged (non-linear) data
- `mac_len`: Length of MAC header
- `protocol**: Layer 3 protocol (ETH_P_IP, ETH_P_IPV6, etc.)
- `transport_header`: Offset to transport layer header
- `network_header`: Offset to network layer header
- `mac_header`: Offset to link layer header
- `skb_shared_info`: Fragment and page information

---

## Virtual Methods

Linux networking uses **virtual methods** extensively for polymorphism. These are function pointers stored in data structures that allow different implementations to be selected at runtime.

**Example structures:**
```c
struct proto_ops {          // Socket operations
    int     (*sendmsg)(struct socket *, struct msghdr *, size_t);
    int     (*recvmsg)(struct socket *, struct msghdr *, size_t, int);
    ...
};

struct proto {              // Protocol operations
    int     (*connect)(struct sock *, struct sockaddr *, int);
    int     (*sendmsg)(struct sock *, struct msghdr *, size_t);
    int     (*recvmsg)(struct sock *, struct msghdr *, size_t, int);
    ...
};

struct net_device_ops {     // Network device operations
    netdev_tx_t (*ndo_start_xmit)(struct sk_buff *, struct net_device *);
    ...
};
```

**How it works:**
1. Socket creation sets appropriate virtual method tables
2. Protocol handler calls through function pointers
3. Correct implementation is invoked based on socket type

**Benefits:**
- Protocol-agnostic core code
- Easy addition of new protocols
- Clean separation of concerns

---

## NAPI (New API)

**NAPI** (New API) is a hybrid interrupt/polling mechanism for high-performance network packet reception.

**Key concepts:**
1. **Interrupt-driven initially**: Device interrupts on first packet
2. **Polling mode**: After interrupt, driver switches to polling
3. **Bulk processing**: Process multiple packets per poll
4. **Interrupt mitigation**: Reduces interrupt overhead

**NAPI lifecycle:**
```
Device RX interrupt
    |
    v
napi_schedule(&napi)
    |
    v
raise_softirq(NET_RX_SOFTIRQ)
    |
    v
ksoftirqd/net_rx_action()
    |
    v
napi->poll()  <-- Driver's poll function
    |
    +-- Process RX ring
    +-- Call netif_receive_skb() for each packet
    +-- Refill RX buffers
    |
    v
napi_complete_done()  <-- Complete polling
```

**NAPI structure:**
```c
struct napi_struct {
    struct list_head    poll_list;      // List of NAPI instances
    unsigned long       state;          // NAPI state
    int                 weight;         // Budget (packets per poll)
    int                 (*poll)(struct napi_struct *, int);  // Poll function
    ...
};
```

---

## GRO (Generic Receive Offload)

**GRO** (Generic Receive Offload) is a software technique to coalesce multiple packets into larger ones, reducing processing overhead.

**How GRO works:**
1. Driver calls `napi_gro_receive()` for each packet
2. GRO attempts to coalesce with existing packets in `napi->gro_list`
3. Coalescing checks:
   - Same flow (source/dest IP/port, protocol)
   - Sequential TCP sequence numbers
   - Matching TCP flags/options
   - Compatible packet attributes
4. On flush, coalesced packet goes to normal stack

**GRO benefits:**
- Fewer packets to process
- Better cache utilization
- Reduced per-packet overhead
- Compatible with LRO (hardware offload)

---

## GSO (Generic Segmentation Offload)

**GSO** (Generic Segmentation Offload) delays packet segmentation as late as possible, potentially to hardware.

**How GSO works:**
1. Upper layers create large "super-packets"
2. Packet marked with GSO metadata (gso_size, gso_type)
3. Segmentation happens at:
   - Hardware (if TSO-capable)
   - Software fallback (if hardware lacks support)

**GSO types:**
- `SKB_GSO_TCPV4`: TCP over IPv4
- `SKB_GSO_TCPV6`: TCP over IPv6
- `SKB_GSO_UDP`: UDP tunneling
- `SKB_GSO_GRE`: GRE tunneling
- `SKB_GSO_IPXIP4/IPXIP6`: IP-in-IP tunneling

---

## XDP (eXpress Data Path)

**XDP** (eXpress Data Path) provides early, programmable packet processing before SKB allocation.

**XDP processing levels:**
1. **Native XDP**: Driver-integrated, highest performance
2. **Generic XDP**: SKB-based, works on any device
3. **Offloaded XDP**: Runs on NIC hardware/firmware

**XDP return actions:**
- `XDP_PASS`: Pass packet to normal stack
- `XDP_DROP`: Drop packet (free immediately)
- `XDP_TX`: Transmit out same interface
- `XDP_REDIRECT`: Redirect to another interface or AF_XDP socket
- `XDP_ABORTED`: Error occurred

**XDP benefits:**
- Earliest processing point
- No SKB allocation cost for drops
- Programmable via eBPF
- Foundation for high-performance networking

---

## RPS/RFS/XPS (Packet Steering)

### RPS (Receive Packet Steering)
**Software** packet steering to distribute receive processing across CPUs.

**Configuration:**
```
/sys/class/net/<dev>/queues/rx-<n>/rps_cpus
```

**How it works:**
1. Calculate flow hash from packet headers
2. Map hash to target CPU
3. Enqueue to target CPU's backlog
4. Target CPU processes from backlog

### RFS (Receive Flow Steering)
**Enhanced RPS** that steers flows to the CPU running the application.

**Configuration:**
```
/proc/sys/net/core/rps_sock_flow_entries
/sys/class/net/<dev>/queues/rx-<n>/rps_flow_cnt
```

**How it works:**
1. RPS calculates target CPU
2. RFS tracks which CPU owns the socket
3. If mismatched, updates flow table
4. Future packets go to correct CPU

### XPS (Transmit Packet Steering)
**Controls** which CPU's packets go to which TX queue.

**Configuration:**
```
/sys/class/net/<dev>/queues/tx-<n>/xps_cpus
/sys/class/net/<dev>/queues/tx-<n>/xps_rxqs
```

**Benefits:**
- Better cache locality
- Reduced lock contention
- Hardware queue optimization

---

## eBPF (Extended Berkeley Packet Filter)

**eBPF** is a kernel technology that allows safe, efficient in-kernel programmability.

**eBPF program types for networking:**
- `BPF_PROG_TYPE_XDP`: XDP programs
- `BPF_PROG_TYPE_SCHED_CLS`: Traffic control (TC) classifiers
- `BPF_PROG_TYPE_SOCKET_FILTER`: Socket filtering (classic BPF)
- `BPF_PROG_TYPE_SK_SKB`: Socket-level programs
- `BPF_PROG_TYPE_CGROUP_SKB`: Per-container filtering

**eBPF workflow:**
1. Write eBPF program in C
2. Compile with LLVM/clang
3. Load via `bpf()` syscall
4. Attach to hook point
5. Kernel JIT-compiles to native code
6. Program runs on packet/events

**eBPF advantages:**
- Safety verified by kernel verifier
- Near-native performance (JIT)
- No kernel module required
- Forward compatible

---

## TLS Offload

**TLS offload** moves TLS encryption/decryption from userspace to kernel or hardware.

**Types:**
1. **Software TLS offload** (`tls_sw`):
   - Kernel encrypts/decrypts
   - Uses crypto API
   - CPU-based

2. **Hardware TLS offload** (`tls_device` / TLS_TOE):
   - NIC handles crypto
   - Minimal CPU overhead
   - Requires NIC support

**TLS offload benefits:**
- Reduced userspace/kernelspace transitions
- Better crypto performance (hardware acceleration)
- Transparent to applications
- Improved security (crypto offload to secure hardware)

---

# Core Data Structures

## struct sock (Socket)

The core socket structure representing a network endpoint.

```c
struct sock {
    struct sock_common __sk_common;  // Shared layout with inet_timewait_sock

    // Socket state
    unsigned int        sk_shutdown : 2;
    unsigned char       sk_state;

    // Protocol operations
    struct proto        *sk_prot;

    // Buffers
    struct sk_buff_head sk_receive_queue;   // Receive queue
    struct sk_buff_head sk_write_queue;     // Send queue

    // Memory management
    int                 sk_rcvbuf;          // Receive buffer size
    int                 sk_sndbuf;          // Send buffer size
    atomic_t            sk_rmem_alloc;      // Receive memory allocated
    atomic_t            sk_wmem_alloc;      // Send memory allocated

    // Synchronization
    spinlock_t          sk_lock;
    atomic_t            sk_drops;           // Dropped packets

    // Callbacks
    void                (*sk_state_change)(struct sock *);
    void                (*sk_data_ready)(struct sock *);
    void                (*sk_write_space)(struct sock *);
    void                (*sk_error_report)(struct sock *);

    ...
};
```

## struct sk_buff (Socket Buffer)

```c
struct sk_buff {
    // These two pointers must be first for efficient skb_copy()
    struct sk_buff      *next;
    struct sk_buff      *prev;

    // Buffer layout
    char                *data;          // Start of packet data
    unsigned int        len;            // Length of packet data
    unsigned int        data_len;       // Length of paged data
    __u16               mac_len;        // MAC header length
    __u16               hdr_len;        // Header length

    // Pointers to buffer boundaries
    char                *head;
    char                *tail;
    char                *end;

    // Protocol headers
    __u16               transport_header; // Transport header offset
    __u16               network_header;   // Network header offset
    __u16               mac_header;       // MAC header offset

    // Packet information
    __u32               priority;
    __u8                pkt_type;
    __u8                ignore_df;
    __u8                nfctinfo;
    __u8                cloned;

    // Protocol
    __be16              protocol;

    // Device
    struct net_device   *dev;

    // Destination
    struct dst_entry    *dst;

    // Checksum
    __u8                ip_summed;
    __u32               csum;

    // Hash for steering
    __u32               hash;
    __u16               queue_mapping;

    // Timestamps
    ktime_t             tstamp;
    u64                 skb_mstamp_ns;

    ...
};
```

## struct tcp_sock (TCP Socket)

```c
struct tcp_sock {
    struct inet_connection_sock inet_conn;

    // TCP sequence numbers
    u32                 rcv_nxt;        // Next expected sequence
    u32                 snd_nxt;        // Next sequence to send
    u32                 snd_una;        // Oldest unacknowledged

    // Congestion control
    u32                 snd_cwnd;       // Sending congestion window
    u32                 snd_ssthresh;   // Slow start threshold

    // RTT measurement
    u32                 srtt_us;        // Smoothed RTT
    u32                 rttvar_us;      // RTT variance
    u32                 rtt_seq;        // RTT measurement sequence

    // Receive window
    u32                 rcv_wnd;        // Receive window
    u32                 rcv_wup;        // Window update

    // Options
    u8                  rcv_wscale;     // Window scaling
    u8                  snd_wscale;
    u8                  nonagle;

    // State
    u32                 snd_up;         // Urgent pointer
    u32                 copied_seq;     // Bytes copied to userspace

    // Queues
    struct sk_buff_head out_of_order_queue;
    struct sk_buff      *highest_sack;

    // Timers
    struct timer_list   retransmit_timer;
    struct timer_list   delack_timer;
    struct timer_list   probe_timer;

    ...
};
```

## struct net_device (Network Device)

```c
struct net_device {
    char                name[IFNAMSIZ]; // Device name
    struct hlist_node   name_hlist;

    // Hardware info
    unsigned long       mem_end;
    unsigned long       mem_start;
    unsigned long       base_addr;
    unsigned int        irq;
    unsigned int        state;

    // Operations
    const struct net_device_ops *netdev_ops;
    const struct ethtool_ops *ethtool_ops;

    // Header operations
    const struct header_ops *header_ops;

    // Queues
    unsigned int        real_num_rx_queues;
    unsigned int        real_num_tx_queues;
    struct netdev_queue *tx;

    // Features
    netdev_features_t   features;

    // MTU
    unsigned int        mtu;

    // Protocol
    unsigned short      type;
    unsigned short      hard_header_len;

    // Address
    unsigned char       *dev_addr;
    unsigned char       broadcast[MAX_ADDR_LEN];
    unsigned char       perm_addr[MAX_ADDR_LEN];

    // Statistics
    struct rtnl_link_stats64 stats;

    // Phony
    struct phy_device   *phydev;

    ...
};
```

---

# Transmission Path - Detailed Call Chain

## Layer 5: Session Layer (System Call Entry)

### System Call Entry Points

```
User Space Application
    |
    | write(fd, buf, len)
    | sendto(fd, buf, len, flags, dest_addr, addrlen)
    | sendmsg(fd, msg, flags)
    | sendmmsg(fd, msgvec, vlen, flags)
    v
```

### syscall_enter_from_user_mode()

**Purpose:** Transition from user mode to kernel mode, save user state

**Location:** `kernel/entry/common.c`

```c
syscall_enter_from_user_mode()
    -> syscall_enter_from_user_mode_prepare()
        -> lockdep_hardirqs_on()
        -> lockdep_sys_exit()
        -> ct_state()
    -> syscall_enter_from_user_work()
        -> syscall_exit_to_user_mode_work()
    -> instrumentation_begin()
```

---

### __sys_sendto() / __sys_sendmsg() / __sys_sendmmsg()

**Purpose:** System call handler for send operations

**Location:** `net/socket.c`

```
__sys_sendto(sockfd, buf, len, flags, dest_addr, addrlen)
    |
    +-> sockfd_lookup_light()           // Lookup socket fd
    |     |
    |     +-> fdget()                   // Get file descriptor
    |     |
    |     +-> sock_from_file()          // Extract socket from file
    |
    +-> import_iovec() / import_single_range()
    |     |
    |     +-> _import_iovec()           // Import user buffer
    |         |
    |         +-> iov_iter_init()       // Initialize iovec iterator
    |
    +-> sock_sendmsg(sock, msg)
    |
    +-> fput_light()                     // Release file descriptor
    |
    v
return copied_bytes
```

---

### sock_sendmsg()

**Purpose:** Generic socket send message handler

**Location:** `net/socket.c:664`

```c
int sock_sendmsg(struct socket *sock, struct msghdr *msg)
{
    struct sockaddr_storage *addr = NULL;
    int ret;

    // Security hook for SELinux/AppArmor
    ret = security_socket_sendmsg(sock, msg, msg_data_left(msg));
    if (ret)
        return ret;

    // Call socket's sendmsg operation
    return sock->ops->sendmsg(sock, msg, msg_data_left(msg));
}
```

**Flow:**
```
sock_sendmsg()
    |
    +-> security_socket_sendmsg()        // SELinux/AppArmor check
    |
    +-> sock->ops->sendmsg()
    |     |
    |     +-> inet_sendmsg()             // For AF_INET sockets
    |
    v
return bytes_sent
```

---

### inet_sendmsg()

**Purpose:** Internet protocol family send message handler

**Location:** `net/ipv4/af_inet.c:817`

```c
int inet_sendmsg(struct socket *sock, struct msghdr *msg, size_t size)
{
    struct sock *sk = sock->sk;

    // Fast path for established TCP connections
    if (unlikely(inet_test_bit(CONNECTED, sk)))
        sock->sk->sk_prot->sendmsg(sk, msg, size);

    return INDIRECT_CALL_2(sk->sk_prot->sendmsg,
                          tcp_sendmsg, udp_sendmsg,
                          sk, msg, size);
}
```

**Flow:**
```
inet_sendmsg()
    |
    +-> sock->sk->sk_prot->sendmsg()
    |     |
    |     +-> tcp_sendmsg()              // For TCP sockets
    |     |
    |     +-> udp_sendmsg()              // For UDP sockets
    |
    v
return bytes_sent
```

---

## Layer 4: Transport Layer (TCP Transmission)

### tcp_sendmsg() - Main Entry

**Purpose:** Send data via TCP socket

**Location:** `net/ipv4/tcp.c:1439`

**Function signature:**
```c
int tcp_sendmsg(struct sock *sk, struct msghdr *msg, size_t size)
{
    int ret;

    // Lock the socket
    lock_sock(sk);

    // Call locked version
    ret = tcp_sendmsg_locked(sk, msg, size);

    // Release the socket
    release_sock(sk);

    return ret;
}
```

---

### tcp_sendmsg_locked() - Core Implementation

**Purpose:** Core TCP send logic (socket must be locked)

**Location:** `net/ipv4/tcp.c:1189`

**Detailed flow:**

```c
int tcp_sendmsg_locked(struct sock *sk, struct msghdr *msg, size_t size)
{
    struct tcp_sock *tp = tcp_sk(sk);
    struct sk_buff *skb;
    int flags, err, copied = 0;
    int mss_now = 0, size_goal;
    long timeo;

    // Step 1: Extract flags from message
    flags = msg->msg_flags;

    // Step 2: Handle zero-copy send (MSG_ZEROCOPY)
    if (flags & MSG_ZEROCOPY && size && sock_flag(sk, SOCK_ZEROCOPY)) {
        // Allocate zero-copy notification structure
        uarg = sock_zerocopy_realloc(sk, size, skb_zcopy(skb));
        // Check if device supports scatter-gather
        zc = sk->sk_route_caps & NETIF_F_SG;
    }

    // Step 3: Handle TCP Fast Open
    if (unlikely(flags & MSG_FASTOPEN || inet_sk(sk)->defer_connect) &&
        !tp->repair) {
        err = tcp_sendmsg_fastopen(sk, msg, &copied_syn, size, uarg);
        // ... handle Fast Open
    }

    // Step 4: Get timeout (blocking vs non-blocking)
    timeo = sock_sndtimeo(sk, flags & MSG_DONTWAIT);

    // Step 5: Check if application is sending slowly
    tcp_rate_check_app_limited(sk);

    // Step 6: Wait for connection if not established
    if (((1 << sk->sk_state) & ~(TCPF_ESTABLISHED | TCPF_CLOSE_WAIT)) &&
        !tcp_passive_fastopen(sk)) {
        err = sk_stream_wait_connect(sk, &timeo);
        if (err != 0)
            goto do_error;
    }

    // Step 7: Initialize socket cmsg data
    sockcm_init(&sockc, sk);
    if (msg->msg_controllen) {
        err = sock_cmsg_send(sk, msg, &sockc);
        if (unlikely(err))
            goto do_error;
    }

    // Step 8: Clear async no-space flag
    sk_clear_bit(SOCKWQ_ASYNC_NOSPACE, sk);

    // Step 9: Main sending loop
    copied = 0;

restart:
    // Get current MSS and size goal
    mss_now = tcp_send_mss(sk, &size_goal, flags);

    // Check for errors
    err = -EPIPE;
    if (sk->sk_err || (sk->sk_shutdown & SEND_SHUTDOWN))
        goto do_error;

    // Process all data in message
    while (msg_data_left(msg)) {
        int copy = 0;

        // Step 9a: Try to use existing skb tail
        skb = tcp_write_queue_tail(sk);
        if (skb)
            copy = size_goal - skb->len;

        // Step 9b: Need new segment?
        if (copy <= 0 || !tcp_skb_can_collapse_to(skb)) {
new_segment:
            // Check if we have memory
            if (!sk_stream_memory_free(sk))
                goto wait_for_space;

            // Allocate new skb
            skb = sk_stream_alloc_skb(sk, 0, sk->sk_allocation, true);
            if (!skb)
                goto wait_for_space;

            // Mark for partial checksum (hardware offload)
            skb->ip_summed = CHECKSUM_PARTIAL;

            // Add to write queue
            skb_entail(sk, skb);
            copy = size_goal;
        }

        // Step 9c: How much to copy?
        if (copy > msg_data_left(msg))
            copy = msg_data_left(msg);

        // Step 9d: Copy data to skb
        if (skb_availroom(skb) > 0 && !zc) {
            // Copy to skb linear area
            err = skb_add_data_nocache(sk, skb, &msg->msg_iter, copy);
        } else if (!zc) {
            // Copy to paged data (fragments)
            merge = true;
            i = skb_shinfo(skb)->nr_frags;
            pfrag = sk_page_frag(sk);

            // Refill page fragment if needed
            if (!sk_page_frag_refill(sk, pfrag))
                goto wait_for_space;

            // Copy to page fragment
            err = skb_add_to_page(skb, pfrag, &msg->msg_iter, copy);
        } else {
            // Zero-copy
            err = skb_zerocopy(skb, &msg->msg_iter, copy);
        }

        if (err)
            goto do_fault;

        // Step 9e: Update counters
        copied += copy;

        // Step 9f: Check if we should send now
        if (!tcp_rate_check_application_limited(sk)) {
            // Force send if we have full segment
            tcp_push(sk, flags);
        } else if (skb && tcp_skb_is_last(sk, skb)) {
            // Last skb, push it
            tcp_push(sk, flags);
        }
    }

out:
    // Step 10: Final push if needed
    if (copied)
        tcp_push(sk, flags);

    // Step 11: Cleanup
out_nopush:
    sock_zerocopy_put(uarg);
    return copied;

do_error:
    // Handle error cases
    ...
}
```

**Detailed call chain:**

```
tcp_sendmsg()
    |
    +-> lock_sock(sk)                      // Acquire socket lock
    |
    +-> tcp_sendmsg_locked(sk, msg, size)
    |     |
    |     +-> tcp_sendmsg_fastopen()       // Handle TCP Fast Open (if needed)
    |     |     |
    |     |     +-> tcp_fastopen_send_child()
    |     |     |
    |     |     +-> tcp_transmit_skb()     // Send SYN with data
    |     |
    |     +-> sk_stream_wait_connect()     // Wait for connection (if needed)
    |     |     |
    |     |     +-> tcp_write_timer_handler()  // Wait for timer
    |     |
    |     +-> sock_cmsg_send()             // Process socket control messages
    |     |     |
    |     |     +-> ip_cmsg_send()         // IP options
    |     |     |
    |     |     +-> ipv6_cmsg_send()       // IPv6 options
    |     |
    |     +-> tcp_send_mss()               // Get MSS
    |     |     |
    |     |     +-> tcp_mtu_to_mss()       // Convert MTU to MSS
    |     |     |
    |     |     +-> tcp_current_mss()      // Get current MSS (considering PMTU)
    |     |
    |     +-> [MAIN LOOP]                  // Process each segment
    |     |     |
    |     |     +-> tcp_write_queue_tail() // Get last skb in write queue
    |     |     |
    |     |     +-> tcp_skb_can_collapse_to()  // Check if can merge
    |     |     |
    |     |     +-> sk_stream_alloc_skb()      // Allocate new skb (if needed)
    |     |     |     |
    |     |     |     +-> alloc_skb_with_frags()
    |     |     |     |
    |     |     |     +-> skb_reserve()        // Reserve header space
    |     |     |     |
    |     |     |     +-> skb_put()            // Allocate data area
    |     |     |
    |     |     +-> skb_entail()                // Add skb to write queue
    |     |     |
    |     |     +-> skb_add_data_nocache()      // Copy data to skb
    |     |     |     |
    |     |     |     +-> copy_page_from_iter() // Copy from user iovec
    |     |     |
    |     |     +-> skb_zerocopy()              // Zero-copy (if MSG_ZEROCOPY)
    |     |     |
    |     |     +-> skb_add_to_page()           // Add to page fragments
    |     |     |
    |     |     +-> tcp_rate_check_application_limited()  // Rate check
    |     |     |
    |     |     +-> tcp_push(sk, flags)        // Push data out
    |     |           |
    |     |           +-> tcp_push_pending_frames()
    |     |           |
    |     |           +-> tcp_write_xmit()
    |     |                 |
    |     |                 +-> tcp_transmit_skb()  // Transmit skb
    |     |
    |     +-> sock_zerocopy_put()            // Release zero-copy refs
    |
    +-> release_sock(sk)                    // Release socket lock
    |
    v
return copied
```

---

### tcp_push() - Push Data to Network

**Purpose:** Push pending data to network layer

**Location:** `include/net/tcp.h`

```c
static inline void tcp_push(struct sock *sk, int flags)
{
    // If MSG_MORE is not set, send immediately
    if (tcp_should_push(sk, flags))
        tcp_push_pending_frames(sk);
}

static inline bool tcp_should_push(struct sock *sk, int flags)
{
    return !(flags & MSG_MORE) || tcp_sk(sk)->timers;
}
```

---

### tcp_write_xmit() - Core Transmission

**Purpose:** Transmit queued segments

**Location:** `net/ipv4/tcp_output.c`

**Flow:**
```
tcp_write_xmit(sk, mss_now, nonagle, push_one, gfp)
    |
    +-> tcp_may_send_now()               // Check if can send
    |
    +-> tso_segs()                       // Calculate TSO segment count
    |
    +-> tcp_transmit_skb(sk, skb, 1, gfp)
    |
    +-> tcp_event_new_data_sent()        // Update state
    |
    +-> tcp_rearm_rto()                  // Rearm retransmit timer
    |
    v
return sent
```

---

### tcp_transmit_skb() - Build and Transmit

**Purpose:** Build TCP header and transmit packet

**Location:** `net/ipv4/tcp_output.c:1224`

**Detailed flow:**

```c
static int tcp_transmit_skb(struct sock *sk, struct sk_buff *skb,
                            int clone_it, gfp_t gfp_mask)
{
    struct inet_sock *inet = inet_sk(sk);
    struct tcp_sock *tp = tcp_sk(sk);
    struct ip_options_rcu *inet_opt;
    struct tcphdr *th;
    int err;

    // Step 1: Clone skb if needed (for retransmission)
    if (clone_it) {
        skb = skb_clone(skb, gfp_mask);
        if (unlikely(!skb))
            return -ENOBUFS;
    }

    // Step 2: Reserve space for TCP header
    skb_push(skb, tcp_header_size);
    skb_reset_transport_header(skb);

    // Step 3: Get TCP header pointer
    th = tcp_hdr(skb);

    // Step 4: Build TCP header
    th->source      = inet->inet_sport;
    th->dest        = inet->inet_dport;
    th->seq         = htonl(tcb->seq);
    th->ack_seq     = htonl(tp->rcv_nxt);

    // TCP flags
    *(((__be16 *)th) + 6) = htons(tcphdr_flags);

    // Window size
    th->window      = htons(tcp_select_window(sk));

    // Checksum (if not offloaded)
    th->check       = 0;
    th->urg_ptr     = 0;

    // Step 5: TCP options
    tcp_options_write(th, tp, &opts);

    // Step 6: MD5 signature (if enabled)
    tcp_v4_md5_hash_skb()

    // Step 7: Set checksum for hardware offload
    skb->ip_summed = CHECKSUM_PARTIAL;
    skb->csum_start = skb_transport_header(skb) - skb->head;
    skb->csum_offset = offsetof(struct tcphdr, check);

    // Step 8: Set GSO info
    skb_shinfo(skb)->gso_size = mss_now;
    skb_shinfo(skb)->gso_segs = tcp_skb_pcount(skb);
    skb_shinfo(skb)->gso_type = SKB_GSO_TCPV4;

    // Step 9: Mark TSO ECN
    if (tcp_ecn_send(sk, skb))
        INET_ECN_xmit(sk);

    // Step 10: Update counters
    icsk->icsk_af_ops->send_check(sk, skb);

    // Step 11: Call network layer
    err = icsk->icsk_af_ops->queue_xmit(sk, skb, &inet->cork.fl);

    return err;
}
```

**Flow:**
```
tcp_transmit_skb(sk, skb, clone_it, gfp_mask)
    |
    +-> skb_clone()                      // Clone skb if needed
    |
    +-> skb_push()                       // Push TCP header
    |
    +-> skb_reset_transport_header()
    |
    +-> tcp_header_size                  // Get header size
    |     |
    |     +-> tcp_options_size()         // Include options
    |
    +-> [BUILD TCP HEADER]
    |     |
    |     +-> th->source = inet->inet_sport
    |     +-> th->dest = inet->inet_dport
    |     +-> th->seq = tcb->seq
    |     +-> th->ack_seq = tp->rcv_nxt
    |     +-> th->doff = data_offset
    |     +-> th->res1 = 0
    |     +-> th->flags = flags
    |     +-> th->window = tcp_select_window()
    |     +-> th->check = 0
    |     +-> th->urg_ptr = 0
    |
    +-> tcp_options_write()              // Write TCP options
    |     |
    |     +-> tcp_write_options()        // Write each option
    |     |
    |     +-> tcp_write_mss()            // MSS option
    |     |
    |     +-> tcp_write_timestamp()      // Timestamp option
    |     |
    |     +-> tcp_write_window_scaling() // Window scale option
    |     |
    |     +-> tcp_write_sack_permitted() // SACK permitted option
    |
    +-> tcp_v4_md5_hash_skb()           // MD5 signature (if enabled)
    |
    +-> [SETUP CHECKSUM]
    |     |
    |     +-> skb->ip_summed = CHECKSUM_PARTIAL
    |     +-> skb->csum_start = offset
    |     +-> skb->csum_offset = offsetof(tcphdr, check)
    |
    +-> [SETUP GSO]
    |     |
    |     +-> skb_shinfo(skb)->gso_size = mss
    |     +-> skb_shinfo(skb)->gso_segs = segments
    |     +-> skb_shinfo(skb)->gso_type = SKB_GSO_TCPV4
    |
    +-> tcp_ecn_send()                  // ECN marking
    |
    +-> icsk->icsk_af_ops->send_check()
    |     |
    |     +-> tcp_v4_send_check()        // IPv4
    |     |
    |     +-> tcp_v6_send_check()        // IPv6
    |
    +-> icsk->icsk_af_ops->queue_xmit() // Send to IP layer
    |     |
    |     +-> ip_queue_xmit()            // IPv4
    |     |
    |     +-> ip6_xmit()                 // IPv6
    |
    v
return NET_XMIT_SUCCESS
```

---

## Layer 3: Network Layer (IPv4 Transmission)

### ip_queue_xmit() - Main Entry

**Purpose:** Queue packet for IP transmission

**Location:** `net/ipv4/ip_output.c:544`

```c
int ip_queue_xmit(struct sock *sk, struct sk_buff *skb, struct flowi *fl)
{
    return __ip_queue_xmit(sk, skb, fl, inet_sk(sk)->tos);
}
```

---

### __ip_queue_xmit() - Core Implementation

**Purpose:** Core IP queue transmit logic

**Location:** `net/ipv4/ip_output.c:453`

**Detailed flow:**

```
__ip_queue_xmit(sk, skb, fl, tos)
    |
    +-> [ROUTE LOOKUP]
    |     |
    |     +-> sk_dst_check()              // Check cached route
    |     |     |
    |     |     +-> dst_check()           // Validate dst_entry
    |     |
    |     +-> ip_route_output_ports()     // Lookup route (if not cached)
    |     |     |
    |     |     +-> ip_route_output_flow()
    |     |           |
    |     |           +-> fib_lookup()    // FIB lookup
    |     |           |
    |     |           +-> fib_select_path()  // Path selection
    |     |           |
    |     |           +-> __mkroute_input()  // Create route
    |     |
    |     +-> sk_setup_caps()             // Setup route capabilities
    |
    +-> [BUILD IP HEADER]
    |     |
    |     +-> skb_push(skb, sizeof(struct iphdr))
    |     |
    |     +-> skb_reset_network_header()
    |     |
    |     +-> iph = ip_hdr(skb)
    |     |
    |     +-> iph->version = 4
    |     +-> iph->ihl = 5
    |     +-> iph->tos = tos
    |     +-> iph->tot_len = htons(skb->len)
    |     +-> iph->id = htons(ip_idents_reserve())
    |     +-> iph->frag_off = 0
    |     +-> iph->ttl = ip_select_ttl(inet, rt->dst)
    |     +-> iph->protocol = sk->sk_protocol
    |     +-> iph->saddr = fl4->saddr
    |     +-> iph->daddr = fl4->daddr
    |     +-> ip_send_check(iph)          // Calculate checksum
    |
    +-> [SETUP CHECKSUM]
    |     |
    |     +-> skb->ip_summed = CHECKSUM_NONE
    |
    +-> [RESERVE HEADER SPACE]
    |     |
    |     +-> skb->transport_header = skb->network_header
    |
    +-> [SETUP FRAGMENTATION]
    |     |
    |     +-> skb->ignore_df = 0
    |     +-> IPCB(skb)->frag_max_size = rt->dst.pmtu
    |
    +-> [SETUP DST]
    |     |
    |     +-> skb_dst_set(skb, dst_clone(&rt->dst))
    |
    +-> [NETFILTER HOOK]
    |     |
    |     +-> nf_hook(NFPROTO_IPV4, NF_INET_LOCAL_OUT, ...)
    |           |
    |           +-> [Various netfilter hooks]
    |           |
    |           +-> dst_output()
    |
    v
return NET_XMIT_SUCCESS
```

---

### ip_output() - IP Output Handler

**Purpose:** Handle IP packet output

**Location:** `net/ipv4/ip_output.c`

```c
int ip_output(struct net *net, struct sock *sk, struct sk_buff *skb)
{
    // Final output hook before transmission
    return NF_HOOK_COND(NFPROTO_IPV4, NF_INET_POST_ROUTING,
                       net, sk, skb, NULL, skb->dev,
                       ip_finish_output,
                       !(IPCB(skb)->flags & IPSKB_REROUTED));
}
```

---

### ip_finish_output() - Final Output Processing

**Purpose:** Final processing before sending to device

**Location:** `net/ipv4/ip_output.c`

```
ip_finish_output(net, sk, skb)
    |
    +-> [MTU CHECK]
    |     |
    |     +-> skb_is_gso(skb)            // GSO packet?
    |     |
    |     +-> skb->len > mtu && !skb_is_gso()
    |           |
    |           +-> ip_do_fragment()      // Fragment if needed
    |                 |
    |                 +-> ip_fragment()    // Create fragments
    |
    +-> [NETFILTER HOOK]
    |     |
    |     +-> nf_hook(NF_INET_POST_ROUTING)
    |
    +-> [SEND TO NEIGHBOR]
    |     |
    |     +-> ip_finish_output2()
    |           |
    |           +-> hh_output()           // Use cached header
    |           |     |
    |           |     +-> dev_queue_xmit()
    |           |
    |           +-> neigh_output()        // Use neighbor
    |                 |
    |                 +-> neigh_resolve_output()
    |                 |
    |                 +-> neigh_connected_output()
    |                       |
    |                       +-> dev_queue_xmit()
    |
    v
return NET_XMIT_SUCCESS
```

---

### ip_fragment() - IP Fragmentation

**Purpose:** Fragment oversized IP packets

**Location:** `net/ipv4/ip_output.c:87`

**Flow:**
```
ip_fragment(net, sk, skb, mtu, output)
    |
    +-> [CHECK IF CAN FRAGMENT]
    |     |
    |     +-> IPCB(skb)->frag_max_size = 0
    |           |
    |           +-> icmp_send()           // Send "Fragmentation Needed"
    |           |
    |           +-> kfree_skb()           // Drop packet
    |
    +-> [FAST PATH: REUSE EXISTING]
    |     |
    |     +-> skb_has_frag_list()        // Has fragment list?
    |           |
    |           +-> [Iterate fragments]
    |                 |
    |                 +-> output()        // Send each fragment
    |
    +-> [SLOW PATH: CREATE NEW FRAGMENTS]
    |     |
    |     +-> skb_split()                 // Split skb
    |     |
    |     +-> ip_copy_metadata()          // Copy metadata
    |     |
    |     +-> ip_fragment_get_frag()      // Get fragment
    |     |
    |     +-> output()                    // Send fragment
    |
    v
return consumed
```

---

## Layer 2: Link Layer (Ethernet Transmission)

### dev_queue_xmit() - Queue for Transmission

**Purpose:** Queue packet for device transmission

**Location:** `net/core/dev.c:3957`

**Detailed flow:**

```
dev_queue_xmit(skb)
    |
    +-> [PREFETCH]
    |     |
    |     +-> prefetch()                  // Prefetch next packet
    |
    +-> [GET DEVICE]
    |     |
    |     +-> dev = skb->dev
    |
    +-> [CHECK RECursion]
    |     |
    |     +-> dev->flags & IFF_LOOPBACK   // Loopback?
    |           |
    |           +-> [Handle loopback]
    |
    +-> [GET CPU]
    |     |
    |     +-> get_cpu()                   // Get current CPU
    |
    +-> [SELECT QUEUE]
    |     |
    |     +-> skb_get_queue_mapping()     // Get queue from skb
    |     |
    |     +-> netdev_cap_txqueue()        // Validate queue
    |     |
    |     +-> txq = netdev_get_tx_queue(dev, queue_index)
    |
    +-> [QDISC CHECK]
    |     |
    |     +-> qdisc = txq->qdisc           // Get queueing discipline
    |     |
    |     +-> qdisc_is_empty(qdisc)       // Is queue empty?
    |           |
    |           +-> [Fast path]
    |                 |
    |                 +-> if (qdisc_is_running(qdisc))
    |                 |     |
    |                 |     +-> __dev_xmit_skb()
    |                 |
    |                 +-> if (dev->flags & IFF_UP)
    |                       |
    |                       +-> __dev_xmit_skb()
    |
    +-> [NORMAL PATH]
    |     |
    |     +-> rcu_read_lock()
    |     |
    |     +-> __dev_xmit_skb()
    |     |
    |     +-> rcu_read_unlock()
    |
    +-> put_cpu()
    |
    v
return rc
```

---

### __dev_xmit_skb() - Core Transmit

**Purpose:** Core device transmit logic

**Location:** `net/core/dev.c`

```
__dev_xmit_skb(skb, txq, dev)
    |
    +-> [GET QDISC]
    |     |
    |     +-> q = txq->qdisc
    |
    +-> [CHECK QDISC STATE]
    |     |
    |     +-> q->flags & TCQ_F_CAN_BYPASS  // Can bypass?
    |           |
    |           +-> [CHECK IF EMPTY]
    |                 |
    |                 +-> qdisc_is_empty(q)
    |                       |
    |                       +-> [FAST PATH]
    |                             |
    |                             +-> validate_xmit_skb()
    |                             |
    |                             +-> netdev_start_xmit()
    |
    +-> [SLOW PATH - ENQUEUE]
    |     |
    |     +-> HARD_TX_LOCK()           // Acquire TX lock
    |     |
    |     +-> [CHECK IF RUNNING]
    |           |
    |           +-> test_bit(__QUEUE_STATE_DRV_XOFF_FROZEN)
    |                 |
    |                 +-> [QUEUE FROZEN]
    |                 |     |
    |                 |     +-> return NET_XMIT_DROP
    |                 |
    |                 +-> [ENQUEUE]
    |                       |
    |                       +-> q->enqueue(skb, q)
    |                             |
    |                             +-> sch_generic_enqueue()
    |                             |
    |                             +-> pfifo_fast_enqueue()
    |                             |
    |                             +-> qdisc_run(txq)
    |
    v
return NET_XMIT_SUCCESS
```

---

### qdisc_run() - Run Queueing Discipline

**Purpose:** Process queued packets

**Location:** `net/sched/sch_generic.c`

```
qdisc_run(txq)
    |
    +-> [CHECK IF RUNNING]
    |     |
    |     +-> test_and_set_bit(__QDISC_STATE_SCHED)
    |           |
    |           +-> [Already running]
    |                 |
    |                 +-> return
    |
    +-> [SET STATE]
    |     |
    |     +-> set_bit(__QDISC_STATE_RUNNING)
    |
    +-> [WHILE QUEUE NOT EMPTY]
    |     |
    |     +-> qdisc_restart(txq)
    |     |     |
    |     |     +-> [GET QDISC]
    |     |     |     |
    |     |     |     +-> q = txq->qdisc
    |     |     |
    |     |     +-> [DEQUEUE]
    |     |     |     |
    |     |     |     +-> skb = q->dequeue(q)
    |     |     |
    |     |     +-> [VALIDATE]
    |     |     |     |
    |     |     |     +-> validate_xmit_skb(skb, dev)
    |     |     |           |
    |     |     |           +-> [CHECKSUM OFFLOAD]
    |     |     |           |
    |     |     |           +-> [FEATURE CHECK]
    |     |     |
    |     |     +-> [TRANSMIT]
    |     |           |
    |     |           +-> netdev_start_xmit(skb, dev)
    |     |
    |     +-> [CHECK ERROR]
    |           |
    |           +-> if (dev_xmit_complete(rc))
    |                 |
    |                 +-> continue
    |           |
    |           +-> if (rc == NETDEV_TX_OK)
    |                 |
    |                 +-> break  // Done
    |           |
    |           +-> [REQUEUE]
    |                 |
    |                 +-> dev_requeue_skb(skb, q)
    |                 |
    |                 +-> netif_schedule()
    |
    +-> [CLEAR STATE]
    |     |
    |     +-> clear_bit(__QDISC_STATE_RUNNING)
    |
    v
return
```

---

### netdev_start_xmit() - Start Device Transmission

**Purpose:** Call driver's transmit function

**Location:** `include/linux/netdevice.h`

```
netdev_start_xmit(skb, dev)
    |
    +-> [GET DRIVER]
    |     |
    |     +-> ops = dev->netdev_ops
    |
    +-> [VALIDATE]
    |     |
    |     +-> validate_xmit_skb(skb, dev)
    |
    +-> [CALL DRIVER]
    |     |
    |     +-> ops->ndo_start_xmit(skb, dev)
    |           |
    |           +-> [DRIVER SPECIFIC]
    |           |     |
    |           |     +-> [Map DMA]
    |           |     |
    |           |     +-> [Post to TX ring]
    |           |     |
    |           |     +-> [Notify device]
    |           |
    |           +-> return NETDEV_TX_OK
    |
    v
return rc
```

---

### validate_xmit_skb() - Validate Before Transmission

**Purpose:** Validate and prepare skb for transmission

**Location:** `net/core/dev.c`

```
validate_xmit_skb(skb, dev)
    |
    +-> [CHECK FEATURES]
    |     |
    |     +-> features = netif_skb_features(skb)
    |
    +-> [CHECKSUM HELP]
    |     |
    |     +-> skb_needs_linearize(skb, features)
    |           |
    |           +-> skb_linearize()      // Linearize if needed
    |
    +-> [CHECKSUM OFFLOAD]
    |     |
    |     +-> skb_checksum_help(skb)     // Calculate if needed
    |
    +-> [VLAN TAG]
    |     |
    |     +-> __vlan_put_tag()           // Add VLAN tag
    |
    +-> [BRIDGE]
    |     |
    |     +-> br_forward()               // Forward to bridge
    |
    v
return skb
```

---

# Receive Flow - Detailed Call Chain

## Driver Layer and XDP

### Driver RX Interrupt

**Purpose:** Hardware signals packet arrival

```
Hardware RX Interrupt
    |
    v
[Driver ISR]
    |
    +-> [ACKNOWLEDGE INTERRUPT]
    |     |
    |     +-> [Device specific]
    |
    +-> [SCHEDULE NAPI]
    |     |
    |     +-> napi_schedule(&napi)
    |           |
    |           +-> [ADD TO POLL LIST]
    |                 |
    |                 +-> list_add_tail(&napi->poll_list, &sd->poll_list)
    |           |
    |           +-> [RAISE SOFTIRQ]
    |                 |
    |                 +-> raise_softirq_irqoff(NET_RX_SOFTIRQ)
    |
    +-> [RETURN FROM INTERRUPT]
    |
    v
IRQ_HANDLED
```

---

### net_rx_action() - SoftIRQ Handler

**Purpose:** Process received packets in softirq context

**Location:** `net/core/dev.c:6220`

```
net_rx_action()
    |
    +-> [GET SOFTNET DATA]
    |     |
    |     +-> sd = this_cpu_ptr(&softnet_data)
    |
    +-> [WHILE WORK TO DO]
    |     |
    |     +-> [LIMIT ITERATIONS]
    |           |
    |           +-> budget = netdev_budget
    |           |
    |           +-> time_limit = jiffies + usecs_to_jiffies(netdev_budget_usecs)
    |
    |     +-> [GET NEXT NAPI]
    |           |
    |           +-> napi = list_first_entry(&sd->poll_list)
    |
    |     +-> [CALL POLL]
    |           |
    |           +-> work = napi->poll(napi, budget)
    |                 |
    |                 +-> [DRIVER POLL FUNCTION]
    |                 |     |
    |                 |     +-> [Process RX ring]
    |                 |     |
    |                 |     +-> [For each descriptor]
    |                 |           |
    |                 |           +-> [GET PACKET]
    |                 |           |
    |                 |           +-> [ALLOCATE OR REUSE BUFFER]
    |                 |           |
    |                 |           +-> [BUILD XDP BUFF]
    |                 |           |
    |                 |           +-> [RUN XDP PROGRAM]
    |                 |                 |
    |                 |                 +-> bpf_prog_run_xdp()
    |                 |                       |
    |                 |                       +-> [Handle XDP actions]
    |                 |                             |
    |                 |                             +-> XDP_PASS:  -> netif_receive_skb()
    |                 |                             +-> XDP_DROP:  -> xdp_return_buff()
    |                 |                             +-> XDP_TX:    -> xdp_do_xmit()
    |                 |                             +-> XDP_REDIRECT: -> xdp_do_redirect()
    |                 |
    |                 +-> [REFILL RX RING]
    |                 |
    |                 +-> return work_done
    |
    |     +-> [UPDATE BUDGET]
    |           |
    |           +-> budget -= work
    |
    |     +-> [COMPLETE NAPI]
    |           |
    |           +-> if (work == 0)
    |                 |
    |                 +-> napi_complete_done(napi, work)
    |                       |
    |                       +-> [REMOVE FROM POLL LIST]
    |                       |
    |                       +-> [ENABLE INTERRUPTS]
    |
    +-> [FLUSH GRO]
    |     |
    |     +-> gro_normal_list()
    |           |
    |           +-> netif_receive_skb_list()
    |
    +-> [SCHEDULE MORE WORK]
    |     |
    |     +-> if (!list_empty(&sd->poll_list))
    |           |
    |           +-> raise_softirq_irqoff(NET_RX_SOFTIRQ)
    |
    v
return
```

---

## Layer 2: Link Layer (NAPI and GRO)

### napi_gro_receive() - GRO Entry Point

**Purpose:** Pass packet to GRO for coalescing

**Location:** `net/core/dev.c:6081`

```
napi_gro_receive(napi, skb)
    |
    +-> [TRACING]
    |     |
    |     +-> trace_napi_gro_receive_entry(skb)
    |
    +-> [VALIDATE]
    |     |
    |     +-> skb_gro_reset(skb)
    |
    +-> [GRO PROCESSING]
    |     |
    |     +-> dev_gro_receive(napi, skb)
    |           |
    |           +-> [FIND PROTOCOL]
    |                 |
    |                 +-> gro_find_protocol_by_type(skb->protocol)
    |                       |
    |                       +-> [GET GRO CALLBACKS]
    |                             |
    |                             +-> gro_func = pt->gro_receive
    |
    |           +-> [ATTEMPT COALESCING]
    |                 |
    |                 +-> [ITERATE GRO LIST]
    |                       |
    |                       +-> list_for_each_entry(skb2, &napi->gro_list, list)
    |                             |
    |                             +-> [CHECK IF CAN COALESCE]
    |                                   |
    |                                   +-> NAPI_GRO_CB(skb2)->same_flow
    |                                   |
    |                                   +-> [CALL PROTOCOL GRO]
    |                                         |
    |                                         +-> tcp4_gro_receive()
    |                                         |       |
    |                                         |       +-> [Check sequence]
    |                                         |       |
    |                                         |       +-> [Check ACK]
    |                                         |       |
    |                                         |       +-> [Check flags]
    |                                         |       |
    |                                         |       +-> [Coalesce data]
    |                                         |
    |                                         +-> udp4_gro_receive()
    |
    |           +-> [IF COALESCED]
    |                 |
    |                 +-> return GRO_CONSUMED
    |
    |           +-> [ADD TO GRO LIST]
    |                 |
    |                 +-> skb_shinfo(skb)->gso_size = gro_size
    |                 |
    |                 +-> list_add(&skb->list, &napi->gro_list)
    |                 |
    |                 +-> napi->gro_count++
    |                 |
    |                 +-> return GRO_HELD
    |
    +-> [FLUSH IF NEEDED]
    |     |
    |     +-> if (napi->gro_count >= MAX_GRO_SKBS)
    |           |
    |           +-> gro_flush()
    |
    +-> [TRACING]
    |     |
    |     +-> trace_napi_gro_receive_exit(ret)
    |
    v
return ret
```

---

### netif_receive_skb() - Main Receive Entry

**Purpose:** Main receive processing function

**Location:** `net/core/dev.c:5583`

```
netif_receive_skb(skb)
    |
    +-> [TRACING]
    |     |
    |     +-> trace_netif_receive_skb_entry(skb)
    |
    +-> [TIMESTAMP]
    |     |
    |     +-> net_timestamp_check()
    |
    +-> [DEFER TIMESTAMP]
    |     |
    |     +-> skb_defer_rx_timestamp(skb)
    |
    +-> [RCU LOCK]
    |     |
    |     +-> rcu_read_lock()
    |
    +-> [RPS - RECEIVE PACKET STEERING]
    |     |
    |     +-> get_rps_cpu(skb->dev, skb, &rflow)
    |           |
    |           +-> [CALCULATE HASH]
    |                 |
    |                 +-> skb_get_hash()
    |                       |
    |                       +-> [Flow dissector]
    |                             |
    |                             +-> skb_flow_dissect()
    |                                   |
    |                                   +-> [Extract L3/L4 headers]
    |                                   |
    |                                   +-> [Calculate hash]
    |
    |           +-> [FIND TARGET CPU]
    |                 |
    |                 +-> rps_map = rps_dev_flow_table->map[hash]
    |
    |           +-> [IF DIFFERENT CPU]
    |                 |
    |                 +-> enqueue_to_backlog(skb, cpu, &rflow->last_qtail)
    |                       |
    |                       +-> [ENQUEUE TO TARGET CPU]
    |                             |
    |                             +-> input_queue_head_incr()
    |
    +-> [NORMAL PROCESSING]
    |     |
    |     +-> __netif_receive_skb(skb)
    |
    +-> [RCU UNLOCK]
    |     |
    |     +-> rcu_read_unlock()
    |
    +-> [TRACING]
    |     |
    |     +-> trace_netif_receive_skb_exit(ret)
    |
    v
return NET_RX_SUCCESS
```

---

### __netif_receive_skb() - Core Receive Processing

**Purpose:** Core receive packet processing

**Location:** `net/core/dev.c:5405`

```
__netif_receive_skb(skb)
    |
    +-> [CHECK PFMEMALLOC]
    |     |
    |     +-> if (skb_pfmemalloc_protocol(skb))
    |           |
    |           +-> __netif_receive_skb_one_core(skb, true)
    |
    +-> [NORMAL PATH]
    |     |
    |     +-> __netif_receive_skb_one_core(skb, false)
    |
    v
return ret
```

---

### __netif_receive_skb_core() - Core Protocol Processing

**Purpose:** Core protocol processing and dispatch

**Location:** `net/core/dev.c:5099`

**Detailed flow:**

```
__netif_receive_skb_core(pskb, pfmemalloc, ppt_prev)
    |
    +-> [TIMESTAMP]
    |     |
    |     +-> net_timestamp_check()
    |
    +-> [TRACE]
    |     |
    |     +-> trace_netif_receive_skb(skb)
    |
    +-> [SAVE DEVICE]
    |     |
    |     +-> orig_dev = skb->dev
    |
    +-> [RESET HEADERS]
    |     |
    |     +-> skb_reset_network_header(skb)
    |     |
    |     +-> skb_reset_transport_header(skb)
    |     |
    |     +-> skb_reset_mac_len(skb)
    |
    +-> [GENERIC XDP]
    |     |
    |     +-> do_xdp_generic(xdp_prog, skb)
    |           |
    |           +-> bpf_prog_run_xdp()
    |                 |
    |                 +-> [Handle XDP result]
    |                       |
    |                       +-> XDP_PASS:  -> continue
    |                       +-> XDP_DROP:  -> kfree_skb()
    |
    +-> [VLAN UNTAG]
    |     |
    |     +-> skb_vlan_untag(skb)
    |
    +-> [PROMISCUOUS TAPS]
    |     |
    |     +-> list_for_each_entry_rcu(ptype, &ptype_all, list)
    |           |
    |           +-> deliver_skb(skb, pt_prev, orig_dev)
    |
    +-> [DEVICE TAPS]
    |     |
    |     +-> list_for_each_entry_rcu(ptype, &skb->dev->ptype_all, list)
    |           |
    |           +-> deliver_skb(skb, pt_prev, orig_dev)
    |
    +-> [INGRESS QDISC]
    |     |
    |     +-> sch_handle_ingress(skb, &pt_prev, &ret, orig_dev)
    |           |
    |           +-> [TC BPF PROGRAM]
    |                 |
    |                 +-> cls_bpf_classify()
    |                       |
    |                       +-> bpf_prog_run_save_cb()
    |                             |
    |                             +-> [Handle TC actions]
    |                                   |
    |                                   +-> TC_ACT_OK:       -> continue
    |                                   +-> TC_ACT_SHOT:     -> kfree_skb()
    |                                   +-> TC_ACT_REDIRECT: -> dev_forward_skb()
    |                                   +-> TC_ACT_PIPE:     -> continue
    |
    +-> [VLAN PROCESSING]
    |     |
    |     +-> if (skb_vlan_tag_present(skb))
    |           |
    |           +-> vlan_do_receive(&skb)
    |
    +-> [RX HANDLER]
    |     |
    |     +-> rx_handler = rcu_dereference(skb->dev->rx_handler)
    |           |
    |           +-> [CALL HANDLER]
    |                 |
    |                 +-> rx_handler(&skb)
    |                       |
    |                       +-> [Handle return]
    |                             |
    |                             +-> RX_HANDLER_CONSUMED: -> done
    |                             +-> RX_HANDLER_ANOTHER:  -> goto another_round
    |                             +-> RX_HANDLER_EXACT:    -> deliver_exact = true
    |                             +-> RX_HANDLER_PASS:     -> continue
    |
    +-> [DELIVER TO L3]
    |     |
    |     +-> [FIND L3 HANDLER]
    |           |
    |           +-> ptype = __ptype_lookup(skb->protocol)
    |
    |     +-> [CALL HANDLER]
    |           |
    |           +-> deliver_skb(skb, pt_prev, orig_dev)
    |                 |
    |                 +-> pt_prev->func(skb, skb->dev, orig_dev)
    |                       |
    |                       +-> ip_rcv()        // IPv4
    |                       +-> ip6_rcv()       // IPv6
    |                       +-> arp_rcv()       // ARP
    |
    v
return NET_RX_SUCCESS
```

---

## Layer 3: Network Layer (IPv4 Reception)

### ip_rcv() - Main IPv4 Receive Handler

**Purpose:** Receive and process IPv4 packets

**Location:** `net/ipv4/ip_input.c:497`

```
ip_rcv(skb, dev, pt)
    |
    +-> [HEADER VALIDATION]
    |     |
    |     +-> [CHECK MINIMUM SIZE]
    |           |
    |           +-> if (!pskb_may_pull(skb, sizeof(struct iphdr)))
    |                 |
    |                 +-> goto drop
    |
    |     +-> [GET IP HEADER]
    |           |
    |           +-> iph = ip_hdr(skb)
    |
    |     +-> [CHECK VERSION]
    |           |
    |           +-> if (iph->ihl < 5 || iph->version != 4)
    |                 |
    |                 +-> goto drop
    |
    |     +-> [CHECK HEADER LENGTH]
    |           |
    |           +-> if (!pskb_may_pull(skb, iph->ihl * 4))
    |                 |
    |                 +-> goto drop
    |
    +-> [CHECKSUM VALIDATION]
    |     |
    |     +-> [IF NOT CHECKSUMMED]
    |           |
    |           +-> if (skb->ip_summed != CHECKSUM_UNNECESSARY)
    |                 |
    |                 +-> skb->csum = csum_fold(skb_checksum(skb, 0, skb->len, 0))
    |                 |
    |                 +-> if (ip_summed(iph, skb->csum))
    |                       |
    |                       +-> goto csum_error
    |
    +-> [NETFILTER HOOK - PRE_ROUTING]
    |     |
    |     +-> NF_HOOK(NFPROTO_IPV4, NF_INET_PRE_ROUTING, ...)
    |           |
    |           +-> [Handle netfilter actions]
    |                 |
    |                 +-> NF_DROP:     -> kfree_skb()
    |                 +-> NF_STOLEN:   -> consumed
    |                 +-> NF_QUEUE:    -> queued
    |                 +-> NF_ACCEPT:   -> continue
    |
    +-> [IP OPTIONS PROCESSING]
    |     |
    |     +-> ip_rcv_options(skb)
    |           |
    |           +-> [Process options]
    |
    +-> [ROUTE LOOKUP]
    |     |
    |     +-> ip_route_input_noref(skb, iph->daddr, iph->saddr, ...)
    |           |
    |           +-> [FIB LOOKUP]
    |                 |
    |                 +-> fib_lookup()
    |                       |
    |                       +-> [Find route]
    |
    +-> [SET DST]
    |     |
    |     +-> skb_dst_set_noref(skb, &res.dst)
    |
    +-> [DELIVERY DECISION]
    |     |
    |     +-> [CHECK DESTINATION]
    |           |
    |           +-> if (ipv4_is_multicast(iph->daddr))
    |                 |
    |                 +-> ip_mr_input()       // Multicast
    |
    |     +-> [CHECK LOCAL DELIVERY]
    |           |
    |           +-> if (res.r->rt_type == RTN_LOCAL)
    |                 |
    |                 +-> ip_local_deliver(skb)
    |
    |     +-> [FORWARDING]
    |           |
    |           +-> ip_forward(skb)
    |
    v
return NET_RX_SUCCESS
```

---

### ip_local_deliver() - Local Delivery Handler

**Purpose:** Deliver packet to local protocols

**Location:** `net/ipv4/ip_input.c:297`

```
ip_local_deliver(skb)
    |
    +-> [DEFRAGMENTATION]
    |     |
    |     +-> if (ip_is_fragment(ip_hdr(skb)))
    |           |
    |           +-> ip_defrag(net, skb, IP_DEFRAG_LOCAL_DELIVER)
    |                 |
    |                 +-> [Reassemble fragments]
    |
    +-> [NETFILTER HOOK - LOCAL_IN]
    |     |
    |     +-> NF_HOOK(NFPROTO_IPV4, NF_INET_LOCAL_IN, ...)
    |
    +-> [RAW SOCKET DELIVERY]
    |     |
    |     +-> raw_local_deliver(skb, protocol)
    |           |
    |           +-> [Deliver to raw sockets]
    |
    +-> [PROTOCOL DELIVERY]
    |     |
    |     +-> ip_protocol_deliver_rcu(skb, protocol)
    |           |
    |           +-> [GET PROTOCOL HANDLER]
    |                 |
    |                 +-> ipprot = rcu_dereference(inet_protos[protocol])
    |
    |           +-> [CALL HANDLER]
    |                 |
    |                 +-> ret = ipprot->handler(skb)
    |                       |
    |                       +-> tcp_v4_rcv()     // TCP
    |                       +-> udp_rcv()       // UDP
    |                       +-> icmp_rcv()      // ICMP
    |                       +-> ...
    |
    v
return ret
```

---

## Layer 4: Transport Layer (TCP Reception)

### tcp_v4_rcv() - TCP Receive Handler

**Purpose:** Receive and process TCP packets

**Location:** `net/ipv4/tcp_ipv4.c:1912`

**Detailed flow:**

```
tcp_v4_rcv(skb)
    |
    +-> [HEADER VALIDATION]
    |     |
    |     +-> [CHECK PACKET TYPE]
    |           |
    |           +-> if (skb->pkt_type != PACKET_HOST)
    |                 |
    |                 +-> goto discard_it
    |
    |     +-> [STATISTICS]
    |           |
    |           +-> __TCP_INC_STATS(net, TCP_MIB_INSEGS)
    |
    |     +-> [PULL TCP HEADER]
    |           |
    |           +-> if (!pskb_may_pull(skb, sizeof(struct tcphdr)))
    |                 |
    |                 +-> goto discard_it
    |
    |     +-> [GET TCP HEADER]
    |           |
    |           +-> th = tcp_hdr(skb)
    |
    |     +-> [VALIDATE DOFF]
    |           |
    |           +-> if (unlikely(th->doff < sizeof(struct tcphdr) / 4))
    |                 |
    |                 +-> goto bad_packet
    |
    |     +-> [PULL OPTIONS]
    |           |
    |           +-> if (!pskb_may_pull(skb, th->doff * 4))
    |                 |
    |                 +-> goto discard_it
    |
    +-> [CHECKSUM VALIDATION]
    |     |
    |     +-> skb_checksum_init(skb, IPPROTO_TCP, inet_compute_pseudo)
    |           |
    |           +-> if (error)
    |                 |
    |                 +-> goto csum_error
    |
    +-> [SOCKET LOOKUP]
    |     |
    |     +-> [GET HEADERS]
    |           |
    |           +-> iph = ip_hdr(skb)
    |           |
    |           +-> th = tcp_hdr(skb)
    |
    |     +-> [LOOKUP SOCKET]
    |           |
    |           +-> sk = __inet_lookup_skb(&tcp_hashinfo, skb, ...)
    |                 |
    |                 +-> [Hash lookup]
    |                 |     |
    |                 |     +-> __inet_lookup_established()
    |                 |     |
    |                 |     +-> __inet_lookup_listener()
    |                 |
    |                 +-> if (!sk)
    |                       |
    |                       +-> goto no_tcp_socket
    |
    +-> [PROCESS BASED ON STATE]
    |     |
    |     +-> [TIME_WAIT]
    |           |
    |           +-> if (sk->sk_state == TCP_TIME_WAIT)
    |                 |
    |                 +-> tcp_timewait_state_process()
    |
    |     +-> [NEW SYN RECEIVE]
    |           |
    |           +-> if (sk->sk_state == TCP_NEW_SYN_RECV)
    |                 |
    |                 +-> [GET REQUEST SOCK]
    |                       |
    |                       +-> req = inet_reqsk(sk)
    |
    |                 +-> [GET LISTENER]
    |                       |
    |                       +-> sk = req->rsk_listener
    |
    |                 +-> [MD5 CHECK]
    |                       |
    |                       +-> tcp_v4_inbound_md5_hash()
    |
    |                 +-> [CHECKSUM COMPLETE]
    |                       |
    |                       +-> tcp_checksum_complete(skb)
    |
    |                 +-> [CHECK REQ]
    |                       |
    |                       +-> tcp_check_req(sk, skb, req, ...)
    |                             |
    |                             +-> tcp_v4_do_rcv(sk, skb)
    |                             |
    |                             +-> tcp_child_process(sk, nsk, skb)
    |
    |     +-> [TTL CHECK]
    |           |
    |           +-> if (iph->ttl < inet_sk(sk)->min_ttl)
    |                 |
    |                 +-> goto discard_and_relse
    |
    |     +-> [XFRM POLICY CHECK]
    |           |
    |           +-> xfrm4_policy_check(sk, XFRM_POLICY_IN, skb)
    |
    |     +-> [MD5 HASH CHECK]
    |           |
    |           +-> tcp_v4_inbound_md5_hash(sk, skb, ...)
    |
    |     +-> [RESET CT]
    |           |
    |           +-> nf_reset_ct(skb)
    |
    |     +-> [SOCKET FILTER]
    |           |
    |           +-> tcp_filter(sk, skb)
    |
    |     +-> [FILL CB]
    |           |
    |           +-> tcp_v4_fill_cb(skb, iph, th)
    |
    |     +-> [LISTEN STATE]
    |           |
    |           +-> if (sk->sk_state == TCP_LISTEN)
    |                 |
    |                 +-> ret = tcp_v4_do_rcv(sk, skb)
    |
    |     +-> [LOCK SOCKET]
    |           |
    |           +-> bh_lock_sock_nested(sk)
    |
    |     +-> [UPDATE STATS]
    |           |
    |           +-> tcp_segs_in(tcp_sk(sk), skb)
    |
    |     +-> [CHECK IF OWNED]
    |           |
    |           +-> if (!sock_owned_by_user(sk))
    |                 |
    |                 +-> [FAST PATH]
    |                       |
    |                       +-> tcp_v4_do_rcv(sk, skb)
    |
    |           +-> else
    |                 |
    |                 +-> [SLOW PATH - ADD BACKLOG]
    |                       |
    |                       +-> tcp_add_backlog(sk, skb)
    |
    |     +-> [UNLOCK SOCKET]
    |           |
    |           +-> bh_unlock_sock(sk)
    |
    v
return 0
```

---

### tcp_v4_do_rcv() - Core TCP Processing

**Purpose:** Core TCP packet processing

**Location:** `net/ipv4/tcp_ipv4.c:1686`

```
tcp_v4_do_rcv(sk, skb)
    |
    +-> [CHECK STATE]
    |     |
    |     +-> TCP_SKB_CB(skb)->seq != tp->rcv_nxt
    |           |
    |           +-> [OUT OF ORDER]
    |                 |
    |                 +-> tcp_data_queue_ofo(sk, skb)
    |
    |     +-> [ESTABLISHED STATE]
    |           |
    |           +-> if (sk->sk_state == TCP_ESTABLISHED)
    |                 |
    |                 +-> tcp_rcv_established(sk, skb)
    |                       |
    |                       +-> [FAST PATH]
    |                             |
    |                             +-> if (tcp_fast_path_check(sk))
    |                                   |
    |                                   +-> [Process data]
    |                                         |
    |                                         +-> [Copy to receive queue]
    |                                         |
    |                                         +-> [Send ACK]
    |                             |
    |                             +-> [SLOW PATH]
    |                                   |
    |                                   +-> tcp_data_queue(sk, skb)
    |                                         |
    |                                         +-> [Queue data]
    |                                         |
    |                                         +-> [Process ACK]
    |                                         |
    |                                         +-> [Send ACK]
    |
    |     +-> [LISTEN STATE]
    |           |
    |           +-> if (sk->sk_state == TCP_LISTEN)
    |                 |
    |                 +-> tcp_v4_conn_request()
    |                       |
    |                       +-> [Handle SYN]
    |                       |
    |                       +-> [Create request sock]
    |                       |
    |                       +-> [Send SYN-ACK]
    |
    |     +-> [OTHER STATES]
    |           |
    |           +-> tcp_rcv_state_process(sk, skb)
    |                 |
    |                 +-> [Process based on state]
    |
    v
return 0
```

---

### tcp_rcv_established() - Established Connection Processing

**Purpose:** Process packets on established connections

**Location:** `net/ipv4/tcp_input.c:5395`

```
tcp_rcv_established(sk, skb)
    |
    +-> [IP HEADER]
    |     |
    |     +-> th = tcp_hdr(skb)
    |
    +-> [FAST PATH CHECK]
    |     |
    |     +-> tcp_fast_path_check(sk)
    |           |
    |           +-> [Check if can use fast path]
    |                 |
    |                 +-> [No SACK]
    |                 |
    |                 +-> [No timestamps out of order]
    |                 |
    |                 +-> [Data in sequence]
    |
    +-> [FAST PATH]
    |     |
    |     +-> [CHECK SEQUENCE]
    |           |
    |           +-> if (TCP_SKB_CB(skb)->seq == tp->rcv_nxt)
    |                 |
    |                 +-> [IN SEQUENCE]
    |                       |
    |                       +-> [CHECK HEADER PREDICTION]
    |                             |
    |                             +-> if ((tcp_flag_word(th) & TCP_HP_BITS) == tp->pred_flags)
    |                                   |
    |                                   +-> tcp_ack(sk, skb, FLAG_DATA)
    |                                         |
    |                                         +-> [Process ACK]
    |                                         |
    |                                         +-> [Update congestion window]
    |                                         |
    |                                         +-> [Check if need to send more]
    |
    |                       +-> [QUEUE DATA]
    |                             |
    |                             +-> skb_copy_datagram_msg()
    |                                   |
    |                                   +-> [Copy to socket buffer]
    |
    |                       +-> [UPDATE STATE]
    |                             |
    |                             +-> tp->rcv_nxt += skb->len
    |
    |                       +-> [NOTIFY USER]
    |                             |
    |                             +-> sk->sk_data_ready(sk)
    |
    +-> [SLOW PATH]
    |     |
    |     +-> tcp_data_queue(sk, skb)
    |           |
    |           +-> [CHECK SEQUENCE]
    |                 |
    |                 +-> if (before(TCP_SKB_CB(skb)->seq, tp->rcv_nxt))
    |                       |
    |                       +-> [OLD DATA - DROP]
    |
    |                 +-> if (tcp_checksum_complete_user(sk, skb))
    |                       |
    |                       +-> goto csum_error
    |
    |                 +-> [CHECK IF OUT OF ORDER]
    |                       |
    |                       +-> if (tcp_data_queue_ofo(sk, skb))
    |                             |
    |                             +-> [Queue to out_of_order_queue]
    |
    |                 +-> [QUEUE DATA]
    |                       |
    |                       +-> __skb_queue_tail(&sk->sk_receive_queue, skb)
    |
    |                 +-> [PROCESS ACK]
    |                       |
    |                       +-> tcp_event_data_recv(sk, skb)
    |
    |                 +-> [SEND ACK IF NEEDED]
    |                       |
    |                       +-> tcp_ack_snd_check(sk)
    |
    v
return 0
```

---

## Layer 5: Session Layer (System Call Exit)

### System Call Exit Points

```
Kernel Space
    |
    | tcp_recvmsg()
    | recvmsg()
    | recvfrom()
    | read()
    v
```

---

### __sys_recvmsg() - System Call Handler

**Purpose:** Receive message system call

**Location:** `net/socket.c`

```
__sys_recvmsg(fd, msg, flags)
    |
    +-> [LOOKUP SOCKET]
    |     |
    |     +-> sockfd_lookup_light()
    |           |
    |           +-> fdget()
    |           |
    |           +-> sock_from_file()
    |
    +-> [INITIALIZE MSG]
    |     |
    |     +-> msg_sys = *msg
    |
    +-> [SET I/OVEC]
    |     |
    |     +-> msg_sys.msg_iov = &iov
    |     |
    |     +-> msg_sys.msg_iovlen = 1
    |
    +-> [RECEIVE MESSAGE]
    |     |
    |     +-> sock_recvmsg(sock, &msg_sys, msg_sys.msg_flags)
    |           |
    |           +-> sock->ops->recvmsg()
    |                 |
    |                 +-> inet_recvmsg()
    |                       |
    |                       +-> sk->sk_prot->recvmsg()
    |                             |
    |                             +-> tcp_recvmsg()
    |
    +-> [COPY RESULT]
    |     |
    |     +-> [Copy back to user]
    |
    +-> [RELEASE SOCKET]
    |     |
    |     +-> fput_light()
    |
    v
return bytes_received
```

---

### sock_recvmsg() - Generic Receive Handler

**Purpose:** Generic socket receive message handler

**Location:** `net/socket.c:719`

```c
int sock_recvmsg(struct socket *sock, struct msghdr *msg, int flags)
{
    // Security hook
    int err = security_socket_recvmsg(sock, msg, msg_data_left(msg), flags);
    if (err)
        return err;

    // Call socket's recvmsg operation
    return sock->ops->recvmsg(sock, msg, msg_data_left(msg), flags);
}
```

---

### inet_recvmsg() - Internet Protocol Receive Handler

**Purpose:** Internet protocol family receive handler

**Location:** `net/ipv4/af_inet.c:848`

```c
int inet_recvmsg(struct socket *sock, struct msghdr *msg, size_t size,
                 int flags)
{
    struct sock *sk = sock->sk;

    // Call protocol's recvmsg
    return INDIRECT_CALL_2(sk->sk_prot->recvmsg,
                          tcp_recvmsg, udp_recvmsg,
                          sk, msg, size, flags);
}
```

---

### tcp_recvmsg() - TCP Receive Handler

**Purpose:** Receive data from TCP socket

**Location:** `net/ipv4/tcp.c:2016`

**Detailed flow:**

```
tcp_recvmsg(sk, msg, len, nonblock, flags, addr_len)
    |
    +-> [ERROR QUEUE CHECK]
    |     |
    |     +-> if (flags & MSG_ERRQUEUE)
    |           |
    |           +-> inet_recv_error(sk, msg, len, addr_len)
    |
    +-> [BUSY POLL]
    |     |
    |     +-> if (sk_can_busy_loop(sk))
    |           |
    |           +-> sk_busy_loop(sk, nonblock)
    |                 |
    |                 +-> [Spin in NAPI poll]
    |
    +-> [LOCK SOCKET]
    |     |
    |     +-> lock_sock(sk)
    |
    +-> [STATE CHECK]
    |     |
    |     +-> if (sk->sk_state == TCP_LISTEN)
    |           |
    |           +-> goto out
    |
    +-> [GET TIMEOUT]
    |     |
    |     +-> timeo = sock_rcvtimeo(sk, nonblock)
    |
    +-> [URGENT DATA CHECK]
    |     |
    |     +-> if (flags & MSG_OOB)
    |           |
    |           +-> goto recv_urg
    |
    +-> [REPAIR MODE CHECK]
    |     |
    |     +-> if (tp->repair)
    |           |
    |           +-> [Handle repair mode]
    |
    +-> [SET SEQ POINTER]
    |     |
    |     +-> seq = &tp->copied_seq
    |     |
    |     +-> if (flags & MSG_PEEK)
    |           |
    |           +-> peek_seq = tp->copied_seq
    |           |
    |           +-> seq = &peek_seq
    |
    +-> [SET TARGET]
    |     |
    |     +-> target = sock_rcvlowat(sk, flags & MSG_WAITALL, len)
    |
    +-> [MAIN RECEIVE LOOP]
    |     |
    |     +-> do {
    |     |     |
    |     |     +-> [FIND SKB WITH DATA]
    |     |     |     |
    |     |     |     +-> skb_queue_walk(&sk->sk_receive_queue, skb)
    |     |     |           |
    |     |     |           +-> [CHECK SEQUENCE]
    |     |     |                 |
    |     |     |                 +-> offset = *seq - TCP_SKB_CB(skb)->seq
    |     |     |                 |
    |     |     |                 +-> if (offset < skb->len)
    |     |     |                       |
    |     |     |                       +-> goto found_ok_skb
    |     |     |
    |     |     +-> [CHECK BACKLOG]
    |     |           |
    |     |           +-> if (copied >= target && !READ_ONCE(sk->sk_backlog.tail))
    |     |                 |
    |     |                 +-> break
    |     |
    |     |     +-> [WAIT FOR DATA]
    |     |           |
    |     |           +-> if (copied) {
    |     |           |     |
    |     |           |     +-> if ([error conditions])
    |     |           |           |
    |     |           |           +-> break
    |     |           |     }
    |     |           |
    |     |           +-> else {
    |     |           |     |
    |     |           |     +-> if ([socket done])
    |     |           |           |
    |     |           |           +-> break
    |     |           |     |
    |     |           |     +-> if ([error])
    |     |           |           |
    |     |           |           +-> break
    |     |           |     |
    |     |           |     +-> if ([no timeout])
    |     |           |           |
    |     |           |           +-> copied = -EAGAIN
    |     |           |     |
    |     |           |     +-> break
    |     |           |     }
    |     |           |
    |     |           +-> [CLEANUP BUFFER]
    |     |                 |
    |     |                 +-> tcp_cleanup_rbuf(sk, copied)
    |     |                 |
    |     |                 +-> [WAIT FOR DATA]
    |     |                       |
    |     |                       +-> sk_wait_data(sk, &timeo)
    |     |                             |
    |     |                             +-> [Sleep until data available]
    |     |                             |
    |     |                             +-> [Woken by sk->sk_data_ready()]
    |     |     |
    |     |     +-> continue
    |     |
    |     +-> found_ok_skb:
    |     |     |
    |     |     +-> [CALCULATE COPY LENGTH]
    |     |           |
    |     |           +-> used = skb->len - offset
    |     |           |
    |     |           +-> if (len < used)
    |     |           |     |
    |     |           |     +-> used = len
    |     |           |
    |     |           +-> [CHECK MSG_PEEK]
    |     |                 |
    |     |                 +-> if (!(flags & MSG_PEEK))
    |     |                       |
    |     |                       +-> [EAT DATA]
    |     |                             |
    |     |                             +-> [Consume data]
    |     |
    |     +-> [COPY DATA TO USER]
    |           |
    |           +-> skb_copy_datagram_msg(skb, offset, msg, used)
    |                 |
    |                 +-> [Copy from skb to user buffer]
    |
    |     +-> [UPDATE COUNTERS]
    |           |
    |           +-> copied += used
    |           |
    |           +-> len -= used
    |
    |     +-> [UPDATE SEQUENCE]
    |           |
    |           +-> if (!(flags & MSG_PEEK))
    |                 |
    |                 +-> *seq += used
    |
    |     +-> [HANDLE TCP CLOSING]
    |           |
    |           +-> if (TCP_SKB_CB(skb)->tcp_flags & TCPHDR_FIN)
    |                 |
    |                 +-> [Handle FIN]
    |
    |     +-> [HANDLE URGENT DATA]
    |           |
    |           +-> if (tp->urg_data && tp->urg_seq == *seq)
    |                 |
    |                 +-> [Handle urgent data]
    |
    |     +-> [CHECK IF DONE]
    |           |
    |           +-> if (copied >= target)
    |                 |
    |                 +-> break
    |     |
    |     } while (len > 0);
    |
    +-> [RECEIVE ERROR QUEUE]
    |     |
    |     +-> [Handle timestamps]
    |     |
    |     +-> [Handle rx timestamps]
    |
    +-> [UNLOCK SOCKET]
    |     |
    |     +-> release_sock(sk)
    |
    v
return copied
```

---

# Advanced Features

## XDP (eXpress Data Path) Detailed Flow

```
[DRIVER RX]
    |
    +-> [ALLOCATE BUFFER]
    |     |
    |     +-> page_pool_alloc()
    |
    +-> [SETUP XDP BUFF]
    |     |
    |     +-> xdp->data = buffer_start + headroom
    |     |
    |     +-> xdp->data_end = buffer_start + headroom + packet_len
    |     |
    |     +-> xdp->data_hard_start = buffer_start
    |     |
    |     +-> xdp->rxq_info = &rxq
    |
    +-> [RUN XDP PROGRAM]
    |     |
    |     +-> bpf_prog_run_xdp(xdp_prog, xdp)
    |           |
    |           +-> [Execute eBPF program]
    |                 |
    |                 +-> [Parse headers]
    |                 |
    |                 +-> [Make decision]
    |
    +-> [HANDLE XDP RESULT]
          |
          +-> XDP_ABORTED
          |     |
          |     +-> [Error handling]
          |     |
          |     +-> trace_xdp_exception()
          |
          +-> XDP_DROP
          |     |
          |     +-> xdp_return_buff()
          |           |
          |           +-> page_pool_put()
          |
          +-> XDP_PASS
          |     |
          |     +-> [Convert to skb]
          |           |
          |           +-> __netif_receive_skb()
          |
          +-> XDP_TX
          |     |
          |     +-> xdp_do_xmit()
          |           |
          |     +-> [Map to TX ring]
          |     |
          |     +-> [Send out same interface]
          |
          +-> XDP_REDIRECT
                |
                +-> xdp_do_redirect()
                      |
                      +-> [TO ANOTHER DEVICE]
                      |     |
                      |     +-> dev_map_enqueue()
                      |
                      +-> [TO AF_XDP SOCKET]
                            |
                            +-> xsk_rcv()
                                  |
                                  +-> [Enqueue to userspace ring]
```

---

## GRO (Generic Receive Offload) Detailed Flow

```
[PACKET ARRIVES]
    |
    +-> napi_gro_receive()
          |
          +-> [GET GRO LIST]
          |
          +-> [ITERATE PACKETS IN LIST]
                |
                +-> [CHECK IF CAN COALESCE]
                      |
                      +-> [PROTOCOL SPECIFIC CHECKS]
                            |
                            +-> tcp4_gro_receive()
                            |     |
                            |     +-> [Check IP addresses]
                            |     |
                            |     +-> [Check ports]
                            |     |
                            |     +-> [Check sequence numbers]
                            |     |
                            |     +-> [Check TCP flags]
                            |     |
                            |     +-> [Check options]
                            |
                      +-> [IF CAN COALESCE]
                            |
                            +-> [Merge data]
                            |
                            +-> [Update metadata]
                            |
                            +-> return GRO_CONSUMED
                |
          +-> [IF NOT COALESCED]
                |
                +-> [ADD TO GRO LIST]
                      |
                      +-> list_add()
                      |
                      +-> napi->gro_count++
                      |
                      +-> return GRO_HELD
```

---

## TLS Kernel Offload

### TLS TX Offload (Encryption)

```
tcp_sendmsg()
    |
    +-> [CHECK TLS SOCKET]
          |
          +-> if (tls_is_tx_ready(sk))
                |
                +-> tls_sw_sendmsg() / tls_device_sendmsg()
                      |
                      +-> [GET TLS CONTEXT]
                            |
                            +-> tls_get_ctx(sk)
                      |
                      +-> [PROCESS DATA]
                            |
                            +-> tls_push_record()
                                  |
                                  +-> [ENCRYPT RECORD]
                                        |
                                        +-> [SOFTWARE]
                                        |     |
                                        |     +-> tls_enc_record()
                                        |           |
                                        |           +-> crypto API
                                        |
                                        +-> [HARDWARE]
                                              |
                                              +-> tls_device_push()
                                                    |
                                                    +-> [Setup offload]
                                                    |
                                                    +-> dev->netdev_ops->ndo_tx()
```

### TLS RX Offload (Decryption)

```
tcp_v4_rcv()
    |
    +-> [CHECK TLS SOCKET]
          |
          +-> if (tls_is_rx_ready(sk))
                |
                +-> tls_device_decrypted()
                |     |
                |     +-> [Check if device decrypted]
                |
                +-> tls_strp_msg()
                      |
                      +-> [Process TLS record]
                            |
                            +-> [DECRYPT IF NEEDED]
                                  |
                                  +-> [SOFTWARE]
                                  |     |
                                  |     +-> tls_dec_record()
                                  |
                                  +-> [HARDWARE]
                                        |
                                        +-> [Already decrypted]
```

---

## Flow Steering

### RPS (Receive Packet Steering)

```
netif_receive_skb()
    |
    +-> get_rps_cpu(skb->dev, skb, &rflow)
          |
          +-> [CALCULATE FLOW HASH]
                |
                +-> skb_get_hash()
                      |
                      +-> skb_flow_dissect()
                            |
                            +-> [Extract L3/L4 headers]
                            |
                            +-> __flow_hash()
          |
          +-> [MAP HASH TO CPU]
                |
                +-> rps_map = sock_flow_table->map[hash % table_size]
                |
                +-> target_cpu = rps_map->cpu[hash % map_size]
          |
          +-> if (target_cpu != smp_processor_id())
                |
                +-> enqueue_to_backlog(skb, target_cpu)
                      |
                      +-> [Add to target CPU's input_queue]
```

### RFS (Receive Flow Steering)

```
[SOCKET BOUND TO CPU]
    |
    +-> sock_set_socket(sk)
          |
          +-> sk_rx_queue_set(sk, cpu)
                |
                +-> [Record CPU for flow]

[PACKET ARRIVES]
    |
    +-> get_rps_cpu()
          |
          +-> [GET RFS TABLE]
                |
                +-> rps_dev_flow_table
          |
          +-> [LOOKUP FLOW]
                |
                +-> rflow = &rps_dev_flow_table->flows[hash]
          |
          +-> [CHECK CPU]
                |
                +-> if (rflow->cpu != target_cpu)
                      |
                      +-> [UPDATE RFS ENTRY]
                            |
                            +-> rflow->cpu = target_cpu
```

### XPS (Transmit Packet Steering)

```
[SELECT TX QUEUE]
    |
    +-> dev_queue_xmit()
          |
          +-> skb_get_queue_mapping()
                |
                +-> [GET QUEUE FROM skb]
                      |
                      +-> if (queue_mapping == 0)
                            |
                            +-> [SELECT QUEUE]
                                  |
                                  +-> get_xps_queue(dev, skb)
                                        |
                                        +-> [CPU TO QUEUE MAP]
                                        |     |
                                        |     +-> xps_cpus_map[cpu]
                                        |
                                        +-> [RX QUEUE TO TX QUEUE MAP]
                                              |
                                              +-> xps_rxqs_map[rxq]
```

---

## Zero-Copy Mechanisms

### MSG_ZEROCOPY

```
sendmsg(fd, msg, MSG_ZEROCOPY)
    |
    +-> tcp_sendmsg()
          |
          +-> [CHECK ZEROCOPY SUPPORT]
                |
                +-> sock_flag(sk, SOCK_ZEROCOPY)
                |
                +-> if (sk->sk_route_caps & NETIF_F_SG)
          |
          +-> [ALLOCATE UARG]
                |
                +-> uarg = sock_zerocopy_realloc()
          |
          +-> [PIN USER PAGES]
                |
                +-> pin_user_pages()
          |
          +-> [BUILD SKB WITH PAGES]
                |
                +-> skb_zerocopy()
                      |
                      +-> [Add pages to skb frags]
          |
          +-> [SEND]
                |
                +-> tcp_transmit_skb()
                      |
                      +-> [DMA MAP PAGES]
```

### AF_XDP

```
[USER SPACE SETUP]
    |
    +-> socket(AF_XDP, SOCK_RAW, 0)
          |
          +-> [SETUP BUFFERS]
                |
                +-> mmap(XDP_UMEM_REG)
          |
          +-> [SETUP RINGS]
                |
                +-> mmap(XDP_RX_RING)
                |
                +-> mmap(XDP_TX_RING)
                |
                +-> mmap(XDP_FILL_RING)
                |
                +-> mmap(XDP_COMPLETION_RING)

[PACKET ARRIVES]
    |
    +-> XDP_REDIRECT
          |
          +-> xsk_rcv()
                |
                +-> [PRODUCE TO RX RING]
                      |
                      +-> xsk_queue_prod()
                            |
                            +-> [Userspace can see packet]
```

---

# Function Reference Index

## Transmission Functions

| Function | Location | Description |
|----------|----------|-------------|
| `__sys_sendto()` | net/socket.c | System call handler |
| `sock_sendmsg()` | net/socket.c:664 | Generic socket send |
| `inet_sendmsg()` | net/ipv4/af_inet.c:817 | AF_INET send handler |
| `tcp_sendmsg()` | net/ipv4/tcp.c:1439 | TCP send entry |
| `tcp_sendmsg_locked()` | net/ipv4/tcp.c:1189 | TCP send (locked) |
| `tcp_push()` | include/net/tcp.h | Push pending data |
| `tcp_write_xmit()` | net/ipv4/tcp_output.c | Core transmit |
| `tcp_transmit_skb()` | net/ipv4/tcp_output.c:1224 | Build and send |
| `ip_queue_xmit()` | net/ipv4/ip_output.c:544 | IP queue transmit |
| `__ip_queue_xmit()` | net/ipv4/ip_output.c:453 | IP queue transmit (core) |
| `ip_output()` | net/ipv4/ip_output.c | IP output handler |
| `ip_finish_output()` | net/ipv4/ip_output.c | Final output processing |
| `ip_fragment()` | net/ipv4/ip_output.c:87 | IP fragmentation |
| `dev_queue_xmit()` | net/core/dev.c:3957 | Device queue transmit |
| `__dev_xmit_skb()` | net/core/dev.c | Core device transmit |
| `qdisc_run()` | net/sched/sch_generic.c | Run queueing discipline |
| `netdev_start_xmit()` | include/linux/netdevice.h | Call driver transmit |
| `validate_xmit_skb()` | net/core/dev.c | Validate before transmit |

## Receive Functions

| Function | Location | Description |
|----------|----------|-------------|
| `net_rx_action()` | net/core/dev.c:6220 | RX softirq handler |
| `napi_gro_receive()` | net/core/dev.c:6081 | GRO receive entry |
| `netif_receive_skb()` | net/core/dev.c:5583 | Main receive entry |
| `__netif_receive_skb()` | net/core/dev.c:5405 | Core receive |
| `__netif_receive_skb_core()` | net/core/dev.c:5099 | Core protocol processing |
| `ip_rcv()` | net/ipv4/ip_input.c:497 | IPv4 receive handler |
| `ip_local_deliver()` | net/ipv4/ip_input.c:297 | Local delivery |
| `tcp_v4_rcv()` | net/ipv4/tcp_ipv4.c:1912 | TCP receive handler |
| `tcp_v4_do_rcv()` | net/ipv4/tcp_ipv4.c:1686 | Core TCP processing |
| `tcp_rcv_established()` | net/ipv4/tcp_input.c:5395 | Established connection |
| `__sys_recvmsg()` | net/socket.c | System call handler |
| `sock_recvmsg()` | net/socket.c:719 | Generic socket receive |
| `inet_recvmsg()` | net/ipv4/af_inet.c:848 | AF_INET receive handler |
| `tcp_recvmsg()` | net/ipv4/tcp.c:2016 | TCP receive handler |

---

# Summary

This comprehensive analysis of Linux kernel networking flow for v5.10-rc7 covers:

1. **Abbreviations and Glossary**: Extensive list of networking and kernel abbreviations
2. **Technical Terms**: Detailed explanations of key concepts (sk_buff, virtual methods, NAPI, GRO, XDP, etc.)
3. **Core Data Structures**: In-depth look at struct sock, sk_buff, tcp_sock, net_device
4. **Transmission Path**: Complete call chain from system call to driver
5. **Receive Flow**: Complete call chain from driver to system call
6. **Advanced Features**: XDP, GRO, TLS offload, flow steering, zero-copy

The key architectural changes from 2.6.20 to 5.10-rc7 include:
- **XDP**: Earliest programmable packet processing
- **GRO/GSO**: Generic receive/segmentation offload
- **eBPF**: Extensible in-kernel programmability
- **Multi-queue**: Multiple TX/RX queues with steering
- **TLS offload**: Kernel/hardware TLS acceleration
- **Zero-copy**: Multiple mechanisms for avoiding copies

---

**Document Version:** 1.0
**Kernel Version:** 5.10-rc7
**Date:** 2026-03-12


---

*Document created: 2026-03-12*  
*Based on: Linux 5.10-rc7 (commit: 0477e9288185)*
