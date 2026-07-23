# pi CLI 启动性能分析：从现象到证据链

[toc]

## 目录

- [结论摘要](#结论摘要)
- [Beginner：为什么启动性能容易测错](#beginner为什么启动性能容易测错)
- [案例：stdout ignore 为什么是 TUI benchmark 缺陷](#案例stdout-ignore-为什么是-tui-benchmark-缺陷)
- [先定义启动完成](#先定义启动完成)
- [完整定位流程](#完整定位流程)
- [本次实验矩阵与结果](#本次实验矩阵与结果)
- [Expert：如何解释 timing gap](#expert如何解释-timing-gap)
- [分层 profile 与 trace 方案](#分层-profile-与-trace-方案)
- [被推翻、确认和未证明的假设](#被推翻确认和未证明的假设)
- [容易误判的环境现象](#容易误判的环境现象)
- [后续观测设计](#后续观测设计)
- [自测](#自测)
- [参考资料](#参考资料)

## 结论摘要

本次分析得到四个主要结论：

1. `profile-coding-agent-node.mjs` 在 TUI benchmark 中设置 `stdout: "ignore"` 是逻辑缺陷。它让子进程失去 stdout TTY，导致 `pi` 进入 print 模式，根本没有执行目标 TUI 初始化路径。
2. 当前约 `0.87 s` 的外部 wall-clock 不是精确首帧耗时，因为 benchmark 在 `interactiveMode.init()` 后还固定等待 `150 ms`，且数据包含进程创建、模块加载、PTY harness 和退出成本。
3. 项目扩展不是热启动的主要瓶颈；热缓存下扩展只占约 `10–14 ms`。但 jiti 转译缓存未命中时，扩展加载会上升到约 `226 ms`。
4. CPU profile 将更稳定的成本指向 Node 的 ESM/CJS 模块加载、编译、包装和路径解析，以及 jiti、highlight.js 等依赖初始化。

这次分析最重要的方法论不是某个 profiler，而是：

> 先证明 benchmark 没有改变被测程序的语义，再使用单变量差分和多层观测建立证据链。

## Beginner：为什么启动性能容易测错

“执行命令到退出用了多久”不一定等于“用户等了多久”。一个 CLI 的启动可能包含：

- shell 或包装脚本启动；
- Node/Bun runtime 初始化；
- 静态模块图加载；
- 参数解析和模式选择；
- 配置、扩展、技能和提示词发现；
- TUI 初始化和首帧绘制；
- 终端协议查询；
- benchmark 为了稳定退出而增加的等待。

如果只测一个总时间，知道的是“整体有多慢”，不知道“谁造成了慢”。

更危险的是，测量脚本可能改变程序行为。例如 TUI 依赖真实终端，如果 benchmark 把 stdout 变成 pipe 或 `/dev/null`，测到的就可能是另一个运行模式。

## 案例：stdout ignore 为什么是 TUI benchmark 缺陷

### 因果链

TUI benchmark 创建子进程时使用：

```js
stdio: ["inherit", "ignore", "pipe"]
```

这会产生下面的路径：

```text
父进程 stdin/stdout 是 TTY
        ↓
子进程 stdin 继承 TTY
        ↓
子进程 stdout 被连接到 /dev/null
        ↓
process.stdout.isTTY 不再为 true
        ↓
resolveAppMode() 选择 print
        ↓
PI_STARTUP_BENCHMARK 拒绝非 interactive 模式
        ↓
子进程退出，interactiveMode.init() 从未执行
```

对应源码位置：

- `scripts/profile-coding-agent-node.mjs`：TUI 子进程的 `spawn(..., { stdio })`；
- `packages/coding-agent/src/main.ts`：`resolveAppMode()`；
- `packages/coding-agent/src/main.ts`：`PI_STARTUP_BENCHMARK` 的 interactive 模式守卫。

### 为什么父进程的 TTY 检查不够

benchmark 虽然检查了自己的 `process.stdin.isTTY` 和 `process.stdout.isTTY`，但随后创建子进程时重新配置了三个文件描述符。

父进程拥有 TTY，并不意味着子进程的每个 fd 都仍然连接 TTY。TTY 属性必须在被测子进程内部验证。

### 常见误修

| 修复方式 | 是否保留 stdout TTY | 问题 |
|---|---:|---|
| `stdout: "pipe"` | 否 | pipe 不是终端设备 |
| `stdout: "inherit"` | 是 | 简单但会污染终端，多轮运行可能互相干扰 |
| 强制 `appMode = interactive` | 不需要 | 绕过真实终端行为，benchmark 语义失真 |
| 为子进程分配 PTY | 是 | 正确方案，可在 PTY master 端捕获或丢弃输出 |

因此准确结论是：

> `ignore` 不是通用逻辑错误；它只在“需要 stdout TTY 才能进入目标路径”的 TUI benchmark 中构成缺陷。

## 先定义启动完成

下列事件是不同指标：

| 事件 | 含义 | 适合回答的问题 |
|---|---|---|
| 进程创建 | shell 已成功 exec | 包装脚本和 runtime 成本 |
| 首个可见帧 | 用户已经看到界面 | 主观上打开是否迅速 |
| 输入就绪 | 键盘输入能被正确处理 | TUI 是否可用 |
| 资源完全加载 | 扩展、技能和提示词全部可用 | 功能是否完整 |

本次 benchmark 在 `interactiveMode.init()` 完成后固定等待 `150 ms`，让终端查询回复有机会被消费。因此外部 wall-clock 包含一段有意加入的等待，不能直接当成首帧时间。

开始测量前，应该先写成一句明确约定，例如：

> 从 OS 创建 `pi` 进程开始，到 TUI 完成首帧绘制并注册 stdin handler 为止。

## 完整定位流程

### 1. 确认真正的被测对象

至少记录：

```bash
command -v pi
readlink -f "$(command -v pi)"
pi --version
node --version
```

本次最初使用了仓库中的 `dist/`，随后发现它比当前源码旧。继续分析只能得到旧构建产物的准确答案。沿软链接检查后，确认实际运行的是全局安装的 Node 版 `pi 0.80.10`，因此重新测量实际安装产物。

这一步的原则是：

> profiler 之前，先确认测到的是谁。

### 2. 建立真实 PTY 下的外部基线

TUI 必须运行在真实终端或 pseudo-terminal 中。使用 warmup 和多次重复，报告均值、离散度和异常值，而不是只报告最快的一次。

基线必须固定：

- binary 和 runtime；
- cwd；
- 配置目录；
- 网络状态；
- 缓存状态；
- 终端尺寸和 PTY 行为；
- 起止事件。

### 3. 验证 harness

在正式采样前，用最小探针确认子进程中的：

```js
console.error({
  stdinIsTTY: process.stdin.isTTY,
  stdoutIsTTY: process.stdout.isTTY,
  cwd: process.cwd(),
});
```

同时检查 benchmark 是否：

- 注入了改变程序行为的环境变量；
- 隐式切换了工作目录；
- 改变了 stdin/stdout/stderr；
- 加入了固定 sleep；
- 把失败退出误认为正常完成；
- 测量了与声明不一致的事件。

### 4. 增加应用内部阶段计时

外部 wall-clock 说明整体时间，内部 timing 用于切分大区间。典型阶段包括：

```text
main entry
  ├─ parse args
  ├─ load settings
  ├─ discover resources
  ├─ create agent session
  ├─ load extensions
  └─ interactiveMode.init
```

内部 timing 的盲区也必须写清楚：静态 import 通常发生在 `main()` 之前，因此不会出现在从 `main()` 开始的阶段计时中。

### 5. 做单变量差分实验

每轮只改变一个变量：

| 维度 | 对照 | 定位目标 |
|---|---|---|
| 配置 | 隔离 agent 目录 / 项目配置 | 扩展和资源发现 |
| 缓存 | jiti cache on / off | 扩展转译冷启动 |
| 入口 | `pi` 包装 / 直接 `node cli.js` | 包装入口成本 |
| 观测层 | 外部 wall-clock / 内部 timing | main 之外的成本 |
| 状态 | 冷启动 / 热启动 | 两种不同工作负载 |

差分比单个绝对值更容易定位。例如：

```text
项目配置 874 ms
隔离配置 865 ms
差值约 9 ms
```

这组数据不支持“项目扩展主导热启动”的假设。

### 6. 使用 profiler 和 trace 交叉验证

差分先回答“哪个变量相关”，profiler 再回答“CPU 具体执行了什么”。二者应该互相支持，而不是只看一次火焰图猜根因。

## 本次实验矩阵与结果

### 主要数据

| 观测 | 数据 | 解释边界 |
|---|---:|---|
| 真实项目热启动 | 约 `874 ms` | 含进程、模块加载、PTY harness 和固定等待 |
| 隔离配置热启动 | 约 `865 ms` | 与项目配置只差约 `10 ms` |
| 内部 main | 约 `162–173 ms` | 不含 main 前的静态模块加载 |
| `interactiveMode.init` | 约 `126–137 ms` | main 内主要阶段 |
| 扩展热加载 | 约 `10–14 ms` | 不是热启动主瓶颈 |
| 禁用 jiti 文件缓存 | 总计约 `1.09 s` | 模拟扩展转译缓存未命中 |
| 缓存未命中的扩展加载 | 约 `226 ms` | 冷启动显著放大 |

关闭 jiti 文件缓存后，扩展中的主要成本约为：

| 扩展 | 时间 |
|---|---:|
| `btw.ts` | `112 ms` |
| `import-repro.ts` | `79 ms` |
| `prompt-url-widget.ts` | `24 ms` |
| redraw/tps 等 | 约 `9 ms` |

### CPU profile 中的主要样本

隔离配置的 Node CPU profile 中，较明显的 CPU 样本包括：

| 样本 | 约耗时 |
|---|---:|
| `compileSourceTextModule` | `79.3 ms` |
| `wrapSafe` | `59.1 ms` |
| GC | `38.6 ms` |
| `parseCJS` | `21.9 ms` |
| `internalModuleStat` | `21.2 ms` |
| `realpathSync` | `20.7 ms` |
| `parseSource` | `17 ms` |
| highlight.js `registerLanguage` | `16 ms` |
| jiti webpack require | `14 ms` |

这支持以下判断：即使隔离扩展，Node 仍需要加载较大的静态模块图，执行 ESM/CJS 编译、包装、路径解析和依赖初始化。

## Expert：如何解释 timing gap

外部结果约 `874 ms`，内部 main 约 `170 ms`。不能直接得出：

```text
874 - 170 = 704 ms 模块加载
```

更准确的模型是：

```text
外部 wall-clock
= 进程创建
+ runtime 初始化
+ main 前静态模块加载
+ 已插桩 main
+ PTY/harness 成本
+ 固定 150 ms 等待
+ 退出和清理
+ 调度噪声
```

所以 timing gap 是一个“尚未解释的桶”，不是根因名称。需要继续使用：

- 更早的进程级 mark；
- V8 CPU profile；
- 入口模块裁剪实验；
- `--trace-event-categories`；
- syscall trace；
- bundle/import graph 分析。

## 分层 profile 与 trace 方案

### Layer 1：外部 wall-clock

目标：建立用户实际感知的时间分布。

工具：真实 PTY、`script`/tmux、hyperfine。

要求：

- warmup 后重复运行；
- 热启动和冷启动分别报告；
- benchmark 必须在明确事件上主动退出；
- 不使用 `strace` 运行结果作为正常基线。

### Layer 2：应用阶段计时

目标：回答哪个业务阶段增长。

工具：`performance.mark()`、`performance.measure()` 或现有 `PI_TIMING=1`。

输出建议统一为机器可读事件：

```json
{"name":"extensions.load","startMs":131.2,"durationMs":12.4}
```

不要只输出互相重叠、无法求和的文本计时。

### Layer 3：CPU profile

目标：回答启动期间 CPU 执行了哪些函数。

示意：

```bash
node --cpu-prof \
  --cpu-prof-dir=/tmp/pi-cpu-profile \
  /path/to/pi/dist/cli.js --no-session
```

CPU profile 适合发现：

- 模块解析和编译；
- JSON/配置解析；
- 语法高亮注册；
- 扩展转译；
- GC；
- 同步 CPU 热点。

它不擅长独立解释阻塞 I/O 或等待用户输入。

### Layer 4：syscall trace

目标：回答程序访问了哪些文件、启动了哪些子进程、进行了哪些网络调用以及在哪里等待。

示意：

```bash
strace -ff -ttt -T -o /tmp/pi.trace \
  /path/to/pi --no-session
```

优先观察：

- 大量重复的 `stat/openat/readlink`；
- 失败后重试的文件搜索；
- DNS、connect 或版本检查；
- 子进程创建；
- `poll/epoll_wait/futex` 等等待。

`strace -c` 可汇总 syscall 次数、错误和 traced time，但 trace 会扰动系统，因此用于定性定位，不用于性能门禁。

## 被推翻、确认和未证明的假设

| 假设 | 状态 | 证据 |
|---|---|---|
| 项目扩展主导热启动 | 推翻 | 项目与隔离配置只差约 `10 ms` |
| 扩展转译缓存未命中影响冷启动 | 确认 | 扩展阶段上升到约 `226 ms` |
| `pi` shell/shebang 包装是主要成本 | 基本推翻 | 包装入口与直接 Node 差异很小 |
| main 业务逻辑就是全部启动成本 | 推翻 | main 约 `162–173 ms`，明显小于外部时间 |
| Node 静态模块图是稳定成本来源 | 支持 | timing gap 与 CPU profile 共同指向模块加载/解析 |
| RPC benchmark 失败的确切原因 | 未证明 | 直接 RPC 请求可工作，只能先判定 harness 与产品需要分开检查 |

状态词很重要：没有证据时写“未证明”，不要为了形成故事而补齐根因。

## 容易误判的环境现象

### Trust prompt

在未受信任项目中运行时，信任确认曾造成约 `80 s` 的等待，直到发送 Escape。这是用户交互等待，不是 CPU 性能瓶颈。

它应该作为独立 UX 指标记录，例如“首次进入未信任项目的交互等待”，不能混入正常启动基线。

### Sandbox 中的 EPERM

沙箱环境里，Node `spawnSync` 可能返回 `EPERM`，从而出现 `fd`、`rg` 不可用等警告。这是观测环境的人工限制，不一定能代表用户机器。

### strace 的观察者效应

`strace -f -c` 会明显放大启动时间。trace 结果适合回答 syscall 类型和数量，不适合回答原程序正常运行需要多少毫秒。

### 失败的 benchmark 不等于产品失败

内置 RPC benchmark 曾失败，但直接 RPC 请求能够工作。正确做法是先检查 harness 的协议、退出条件和 I/O，再决定是否归因产品。

## 后续观测设计

建议把启动观测拆成三个稳定指标：

1. `process → first frame`：用户视觉启动时间；
2. `process → input ready`：TUI 可用时间；
3. `process → resources ready`：完整功能时间。

每个指标分别维护：

- 隔离配置热启动；
- 项目配置热启动；
- 扩展缓存未命中冷启动；
- Node 与 Bun 对照。

回归系统应保存：

- 原始样本；
- median、mean、标准差和 p95；
- runtime、commit、CPU、OS 和终端信息；
- 内部阶段 timing；
- 失败运行的 stderr；
- 可选 CPU profile。

最短闭环是：

```text
定义事件
→ 验证 harness
→ 多次基线
→ 单变量差分
→ profiler 交叉验证
→ 修复
→ 同口径回归
```

## 自测

### 1. 为什么将 stdout 从 `ignore` 改成 `pipe` 仍不能修复？

pipe 是管道，不是终端设备，因此子进程的 `process.stdout.isTTY` 仍不会为 true。

### 2. 为什么不能把外部时间减去 main 时间直接命名为模块加载时间？

差值还包含 runtime 初始化、固定等待、PTY harness、进程退出、调度和其他未插桩阶段。

### 3. 如何用一个实验判断扩展是否主导热启动？

保持 binary、PTY、cwd、网络和缓存状态不变，只切换隔离 agent 目录和项目配置，多次运行并比较分布。

### 4. CPU profile 和 strace 分别回答什么？

CPU profile 观察用户态 CPU 函数；strace 观察 syscall、I/O、进程和等待。两者不能相互替代。

## 参考资料

- [Node.js child_process](https://nodejs.org/download/release/v22.17.1/docs/api/child_process.html)：`stdio` 与 `ignore` 语义。
- [Node.js TTY](https://nodejs.org/download/release/v22.18.0/docs/api/tty.html)：`process.stdout.isTTY`。
- [Node.js --cpu-prof](https://nodejs.org/download/release/v22.18.0/docs/api/cli.html#--cpu-prof)：V8 CPU sampling profiler。
- [Node.js Performance Hooks](https://nodejs.org/api/perf_hooks.html)：应用内部 mark/measure。
- [hyperfine](https://github.com/sharkdp/hyperfine)：命令行多轮 benchmark。
- [strace](https://strace.io/)：Linux syscall tracing。
- [启动性能定位检查表](./startup-performance-checklist.md)：可复用的执行清单。

<!-- Source workspace: pi @ origin/main; migrated: 2026-07-23 00:20:03 +0800 -->
