---
name: rdma-learning-series
description: RDMA (Remote Direct Memory Access) 六讲渐进式课程 + 九页速查参考手册 + 实验指南
---

# RDMA Learning Series

RDMA（远程直接内存访问）技术允许应用程序在不经过操作系统内核的情况下，直接访问远程服务器的内存，实现高吞吐、低延迟的数据传输。

## Content Structure

### Lessons | 渐进式课程 (6 Lectures)

| # | Topic | Description |
|---|-------|-------------|
| 0001 | [DMA to RDMA](lessons/0001-dma-to-rdma.html) | From DMA to RDMA — motivation & evolution |
| 0002 | [Device and Env](lessons/0002-device-and-env.html) | RDMA device model & environment setup |
| 0003 | [Core Objects](lessons/0003-core-objects.html) | PD, MR, CQ, QP — the four core verbs objects |
| 0004 | [Data Path](lessons/0004-data-path.html) | Send/Recv & RDMA Read/Write operations |
| 0005 | [Connection Models](lessons/0005-connection-models.html) | RC / UC / UD / SRQ / xRC |
| 0006 | [To Production](lessons/0006-to-production.html) | Deployment, tuning & production readiness |

### Reference | 速查参考 (9 Pages + Lab Guide)

| # | Topic | Description |
|---|-------|-------------|
| 00 | [Glossary](reference/00-glossary.html) | Key terms & abbreviations |
| 01 | [RDMA Data Path](reference/01-rdma-data-path.html) | Data path deep dive |
| 02 | [Verbs Object Lifecycle](reference/02-verbs-object-lifecycle.html) | Object creation/destruction flow |
| 03 | [QP State & Completion](reference/03-qp-state-and-completion.html) | QP state machine & completion handling |
| 04 | [Memory Registration & rkey](reference/04-memory-registration-and-rkey.html) | MR types, rkey/lkey semantics |
| 05 | [RDMA CM State Machine](reference/05-rdma-cm-state-machine.html) | Connection Manager states |
| 06 | [Performance Methodology](reference/06-performance-methodology.html) | Benchmarking & tuning methodology |
| 07 | [Production Ecosystem](reference/07-production-ecosystem.html) | Ecosystem tools & production deployment |
| 08 | [Troubleshooting](reference/08-troubleshooting.html) | Debugging & issue resolution |
| LG | [Lab Guide](reference/lab-guide.html) | Hands-on experiment guide |

## Relationship

- **Lessons** are meant to be read sequentially — they build up understanding from first principles
- **Reference** pages are standalone — jump to any page for a specific topic
- **Lab Guide** bridges the two: apply lesson knowledge in practical experiments

---

*Generated from [rdma-playground](https://github.com/egg12138/rdma-playground) @ man (ded4410) · 2026-07-19*
