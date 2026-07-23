# CLI 启动性能定位检查表

[toc]

## 目录

- [定义测量事件](#定义测量事件)
- [确认被测身份](#确认被测身份)
- [验证 Harness](#验证-harness)
- [分层观测](#分层观测)
- [差分实验](#差分实验)
- [结论门槛](#结论门槛)
- [pi 本次结论速查](#pi-本次结论速查)

## 定义测量事件

- [ ] 写下起点：shell 调用、exec 完成，还是 runtime main。
- [ ] 写下终点：首帧、输入就绪，还是资源完全可用。
- [ ] 检查 benchmark 是否包含固定 sleep 或额外清理时间。
- [ ] 冷启动和热启动分别建立基线，不混合统计。

## 确认被测身份

- [ ] 检查 `command -v` 和软链接最终目标。
- [ ] 记录程序版本、Node/Bun 版本和 commit/构建时间。
- [ ] 确认源码、仓库 `dist/` 和实际安装包是否对应。
- [ ] 记录 cwd、配置目录、环境变量和网络状态。

## 验证 Harness

- [ ] TUI 子进程的 stdin 和 stdout 都连接 PTY。
- [ ] 在子进程内部检查 `process.stdin.isTTY` 和 `process.stdout.isTTY`。
- [ ] 记住 `inherit` 只影响对应 fd；父进程是 TTY 不代表子进程所有 fd 都是。
- [ ] 记住 `ignore` 和 `pipe` 都不能提供 stdout TTY。
- [ ] 确认环境变量没有让程序进入不同模式。
- [ ] 确认成功退出对应目标事件，而不是提前退出或异常退出。
- [ ] 分开保存 stderr 和 benchmark 统计结果。

## 分层观测

| 层 | 工具 | 回答的问题 | 注意事项 |
|---|---|---|---|
| 外部 | PTY + hyperfine | 用户整体等了多久 | warmup、多轮、报告分布 |
| 应用 | performance marks / `PI_TIMING` | 哪个业务阶段慢 | main 前 import 可能不可见 |
| CPU | Node `--cpu-prof` | CPU 花在哪些函数 | 不能独立解释阻塞等待 |
| 内核 | strace | 文件、网络、进程和等待行为 | traced wall-clock 不能当基线 |

## 差分实验

- [ ] 每次只改变一个变量。
- [ ] 隔离配置 vs 项目配置：定位资源和扩展成本。
- [ ] 缓存命中 vs 未命中：定位冷启动转译成本。
- [ ] 包装入口 vs 直接 runtime：定位 wrapper 成本。
- [ ] 在线 vs 离线：定位网络和版本检查。
- [ ] 外部 wall-clock vs 内部 timing：发现未插桩区间。
- [ ] 报告样本数、mean/median、离散度与异常值。
- [ ] 将假设标记为“确认”“推翻”或“未证明”。

## 结论门槛

- [ ] 绝对计时只说明“有多慢”，对照实验才说明“谁造成”。
- [ ] 内部/外部时间差只是待解释区间，不自动成为根因。
- [ ] profiler 结果与差分实验相互支持。
- [ ] 区分 CPU 工作、I/O、用户等待和人为 sleep。
- [ ] 优化后使用同一事件边界和实验矩阵回归。
- [ ] benchmark 修复后先验证它确实进入目标代码路径。

## pi 本次结论速查

- TUI benchmark 的 `stdout: "ignore"` 会取消子进程 stdout TTY，导致进入 print 模式。
- 项目扩展热加载约 `10–14 ms`，不是热启动主瓶颈。
- jiti 缓存未命中时扩展加载约 `226 ms`，显著影响冷启动。
- 外部约 `0.87 s` 包含固定 `150 ms` 等待，不能直接解释为首帧耗时。
- CPU profile 支持 Node 静态模块加载、解析和初始化是稳定成本来源。

最短闭环：

```text
定义事件 → 验证 harness → 多次基线 → 单变量差分
→ profiler/trace 交叉验证 → 修复 → 同口径回归
```

<!-- Source workspace: pi @ origin/main; migrated: 2026-07-23 00:20:03 +0800 -->
