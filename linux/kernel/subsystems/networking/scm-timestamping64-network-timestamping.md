# Linux Kernel Network Timestamping - scm_timestamping64

[TOC]

## Version Info
- **Kernel Version**: Linux v5.10-rc7
- **Created**: 2026-03-21

---

## Summary

The `scm_timestamping64` structure is the Y2038-safe variant of the Linux kernel's network timestamping interface. It allows applications to receive precise timestamps for network packets via socket control messages (cmsg). This mechanism is essential for applications requiring accurate timing information, such as PTP (Precision Time Protocol) implementations, financial trading systems, and network performance measurement tools.

Key concepts:
- Timestamps are delivered via `recvmsg()` with `MSG_ERRQUEUE` flag
- Three timestamp slots accommodate software, deprecated, and hardware timestamps
- The structure is part of the errqueue mechanism for out-of-band data delivery

---

## Beginner Section: Understanding Network Timestamping

### What is Network Timestamping?

Network timestamping is the process of recording precise time values when network packets are sent or received. This is different from simply calling `gettimeofday()` in your application because:

1. **Accuracy**: Kernel/hardware timestamps are taken closer to the actual wire time
2. **Precision**: Hardware timestamps can achieve nanosecond precision
3. **Consistency**: Timestamps are taken at consistent points in the network stack

### Why Use errqueue?

The error queue (`MSG_ERRQUEUE`) provides a way to receive out-of-band data alongside normal socket operations. For transmit timestamps, this mechanism is used because:

- The original packet has already been sent
- The timestamp is generated asynchronously (sometimes by hardware)
- The error queue allows the timestamp to be "attached" to a reference of the original packet

### Basic Structure

```c
// From include/uapi/linux/errqueue.h
struct scm_timestamping64 {
    struct __kernel_timespec ts[3];
};

struct __kernel_timespec {
    __kernel_time64_t tv_sec;   /* seconds */
    long long         tv_nsec;  /* nanoseconds */
};
```

### The Three Timestamp Fields

| Index | Name | Purpose |
|-------|------|---------|
| `ts[0]` | Software timestamp | Most timestamps go here. Software-generated timestamps from the kernel network stack. |
| `ts[1]` | Deprecated | Previously held hardware timestamps converted to system time. Now unused. |
| `ts[2]` | Hardware timestamp | Raw timestamps from NIC hardware (e.g., PTP hardware clock). |

---

## Expert Section: Deep Dive

### Structure Definitions

#### scm_timestamping64 vs scm_timestamping

There are two variants for Y2038 compatibility:

```c
// Y2038-safe version (64-bit time)
struct scm_timestamping64 {
    struct __kernel_timespec ts[3];
};

// Legacy version (32-bit time on 32-bit systems)
struct scm_timestamping {
#ifdef __KERNEL__
    struct __kernel_old_timespec ts[3];
#else
    struct timespec ts[3];
#endif
};
```

Use `SO_TIMESTAMPING_NEW` socket option to get the 64-bit version.

#### Related Structures

```c
// From include/uapi/linux/errqueue.h

// Extended error structure accompanying timestamps
struct sock_extended_err {
    __u32   ee_errno;     /* error number (ENOMSG for timestamps) */
    __u8    ee_origin;    /* origin (SO_EE_ORIGIN_TIMESTAMPING) */
    __u8    ee_type;
    __u8    ee_code;
    __u8    ee_pad;
    __u32   ee_info;      /* SCM_TSTAMP_* type */
    union {
        __u32   ee_data;  /* unique ID if SOF_TIMESTAMPING_OPT_ID set */
        struct sock_ee_data_rfc4884 ee_rfc4884;
    };
};

// Timestamp types in ee_info
enum {
    SCM_TSTAMP_SND,     /* driver passed skb to NIC, or HW */
    SCM_TSTAMP_SCHED,   /* data entered packet scheduler */
    SCM_TSTAMP_ACK,     /* data acknowledged by peer (TCP) */
};
```

### Timestamp Type Semantics

#### ts[0] - Software Timestamp

The meaning of `ts[0]` depends on the `ee_info` field:

| ee_info | Timestamp Type | Description |
|---------|---------------|-------------|
| `SCM_TSTAMP_SND` | Send timestamp | When driver passed skb to NIC (if `ts[2]==0`) |
| `SCM_TSTAMP_SCHED` | Schedule timestamp | When data entered packet scheduler |
| `SCM_TSTAMP_ACK` | ACK timestamp | When data was acknowledged by peer (TCP) |

**Special case for SCM_TSTAMP_SND**: If `ts[2]` is non-zero, it's a hardware timestamp; otherwise `ts[0]` contains the software timestamp.

#### ts[2] - Hardware Timestamp

Hardware timestamps come from:
- NIC's PTP hardware clock
- PHY layer timestamping
- DSA (Distributed Switch Architecture) switches

Hardware timestamps are in the NIC's local time domain, not system time. Applications must convert them using the PTP clock device (`/dev/ptpN`).

### Socket Options

```c
// Enable timestamping
int val = SOF_TIMESTAMPING_TX_HARDWARE |   // Request HW TX timestamps
          SOF_TIMESTAMPING_TX_SOFTWARE |   // Request SW TX timestamps
          SOF_TIMESTAMPING_RX_HARDWARE |   // Request HW RX timestamps
          SOF_TIMESTAMPING_SOFTWARE |      // Report SW timestamps
          SOF_TIMESTAMPING_RAW_HARDWARE |  // Report HW timestamps
          SOF_TIMESTAMPING_OPT_ID |        // Unique ID per packet
          SOF_TIMESTAMPING_OPT_TSONLY;     // Return timestamp only (no data)

setsockopt(fd, SOL_SOCKET, SO_TIMESTAMPING_NEW, &val, sizeof(val));
```

### Reception Flow

```
┌─────────────────────────────────────────────────────────────────┐
│                     Application Layer                           │
│   recvmsg(fd, msg, MSG_ERRQUEUE)                                │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                     Kernel: net/socket.c                        │
│   __sys_recvmsg() → sock_recvmsg()                             │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                   Error Queue Processing                        │
│   sk_receive_skb() → Check MSG_ERRQUEUE flag                   │
│   → Pull from sk->sk_error_queue                               │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    CMSG Construction                            │
│   put_cmsg() for SOL_IP/IP_RECVERR (sock_extended_err)         │
│   put_cmsg_scm_timestamping64() for SCM_TIMESTAMPING           │
└─────────────────────────────────────────────────────────────────┘
```

### Key Source Files

| File | Purpose |
|------|---------|
| `include/uapi/linux/errqueue.h` | Structure definitions |
| `include/linux/socket.h` | Internal helpers, `scm_timestamping_internal` |
| `net/core/scm.c` | `put_cmsg_scm_timestamping64()` implementation |
| `net/core/timestamping.c` | Timestamp generation logic |
| `net/socket.c` | Socket-level recvmsg handling |
| `Documentation/networking/timestamping.rst` | Official documentation |

### Code Example: Reading Transmit Timestamps

```c
#include <linux/errqueue.h>
#include <sys/socket.h>

int read_tx_timestamp(int fd) {
    char ctrl_buf[512];
    struct msghdr msg = {0};
    struct iovec iov;
    char data_buf[1];

    iov.iov_base = data_buf;
    iov.iov_len = sizeof(data_buf);
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = ctrl_buf;
    msg.msg_controllen = sizeof(ctrl_buf);

    int ret = recvmsg(fd, &msg, MSG_ERRQUEUE);
    if (ret < 0) {
        perror("recvmsg");
        return -1;
    }

    struct cmsghdr *cmsg;
    for (cmsg = CMSG_FIRSTHDR(&msg); cmsg; cmsg = CMSG_NXTHDR(&msg, cmsg)) {
        if (cmsg->cmsg_level == SOL_SOCKET &&
            cmsg->cmsg_type == SCM_TIMESTAMPING) {
            struct scm_timestamping64 *tss =
                (struct scm_timestamping64 *)CMSG_DATA(cmsg);

            printf("Software timestamp: %lld.%09lld\n",
                   (long long)tss->ts[0].tv_sec,
                   (long long)tss->ts[0].tv_nsec);

            if (tss->ts[2].tv_sec || tss->ts[2].tv_nsec) {
                printf("Hardware timestamp: %lld.%09lld\n",
                       (long long)tss->ts[2].tv_sec,
                       (long long)tss->ts[2].tv_nsec);
            }
        }

        if (cmsg->cmsg_level == SOL_IP && cmsg->cmsg_type == IP_RECVERR) {
            struct sock_extended_err *ee =
                (struct sock_extended_err *)CMSG_DATA(cmsg);

            const char *type;
            switch (ee->ee_info) {
                case SCM_TSTAMP_SND:  type = "SEND"; break;
                case SCM_TSTAMP_SCHED: type = "SCHED"; break;
                case SCM_TSTAMP_ACK:  type = "ACK"; break;
                default: type = "UNKNOWN";
            }
            printf("Timestamp type: %s, ID: %u\n", type, ee->ee_data);
        }
    }

    return 0;
}
```

### Y2038 Considerations

On 32-bit systems, `struct timespec` has a 32-bit `tv_sec` field, which overflows in year 2038. The `scm_timestamping64` structure uses 64-bit time fields:

```c
// Always use the NEW variants for Y2038 safety
setsockopt(fd, SOL_SOCKET, SO_TIMESTAMPING_NEW, &val, sizeof(val));
```

### Integration with Other Subsystems

| Subsystem | Integration |
|-----------|-------------|
| **PTP** | Hardware timestamps from PHC (PTP Hardware Clock) |
| **Netfilter** | May add metadata via SKB extensions |
| **ethtool** | Hardware timestamp configuration via `SIOCSHWTSTAMP` |
| **NAPI** | Busy polling can affect timestamp accuracy |
| **XDP** | XDP programs see packets before timestamping |

---

## Quick Reference

### When to Use Which ts[] Field

```
Check ts[2] first:
├── ts[2] != 0  →  Hardware timestamp available in ts[2]
└── ts[2] == 0  →  Software timestamp in ts[0]

ts[1] is always deprecated/unused
```

### Socket Option Flags Summary

| Flag | Purpose |
|------|---------|
| `SOF_TIMESTAMPING_TX_HARDWARE` | Request hardware TX timestamps |
| `SOF_TIMESTAMPING_TX_SOFTWARE` | Request software TX timestamps |
| `SOF_TIMESTAMPING_TX_SCHED` | Request scheduler entry timestamps |
| `SOF_TIMESTAMPING_TX_ACK` | Request ACK timestamps (TCP) |
| `SOF_TIMESTAMPING_RX_HARDWARE` | Request hardware RX timestamps |
| `SOF_TIMESTAMPING_RX_SOFTWARE` | Request software RX timestamps |
| `SOF_TIMESTAMPING_SOFTWARE` | Report software timestamps |
| `SOF_TIMESTAMPING_RAW_HARDWARE` | Report raw hardware timestamps |
| `SOF_TIMESTAMPING_OPT_ID` | Include unique packet ID |
| `SOF_TIMESTAMPING_OPT_TSONLY` | Timestamp only (no payload) |

---

## References

- `Documentation/networking/timestamping.rst` - Official kernel documentation
- `include/uapi/linux/errqueue.h` - Structure definitions
- `include/uapi/linux/net_tstamp.h` - Timestamping constants
- RFC 4884 - ICMP extension structure

---
*Kernel Version: Linux v5.10-rc7 | Generated: 2026-03-21*