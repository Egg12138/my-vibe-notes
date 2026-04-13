# Claude Code 如何路由模型，以及 subagent 怎么工作

[toc]

## 这篇笔记先回答什么

这份代码里有两条经常被混在一起的链路：

1. **模型路由**：输入一个模型名，Claude Code 如何决定走 Anthropic、OpenAI-compatible、XAI，还是 DashScope。
2. **subagent 工作流**：`Agent` / `TeamCreate` / `/subagent` 这一套是怎么创建隔离会话、限制工具、并把结果写回主系统的。

如果你只想记一句话：

- **模型路由**靠的是 `resolve_model_alias()` + `detect_provider_kind()` + `ProviderClient::from_model_with_anthropic_auth()`
- **subagent**靠的是“单独的 `ConversationRuntime` + 独立 `Session` + 受限 `allowed_tools` + 后台线程/注册表”

## Beginner

### 1. 模型不是“直接选 API”

用户输入一个模型名时，Claude Code 先做两步：

1. **别名归一化**：把 `opus`、`sonnet`、`grok` 这种短名展开成 canonical model name
2. **提供商判定**：根据 canonical name 和环境变量，决定走哪个 provider

对应代码：

- [resolve_model_alias / detect_provider_kind](</home/egg/playground/claw-code/rust/crates/api/src/providers/mod.rs:128>)
- [ProviderClient::from_model_with_anthropic_auth](</home/egg/playground/claw-code/rust/crates/api/src/client.rs:21>)
- [CLI 启动时的 provider 选择](</home/egg/playground/claw-code/rust/crates/rusty-claude-cli/src/main.rs:6734>)

### 2. 路由规则是什么

代码里的优先级大致是：

1. 明确的模型前缀优先
2. 否则看本地/环境里的 provider 配置
3. 再不行就回退到 Anthropic

几个关键分支：

- `claude*` -> Anthropic
- `grok*` -> XAI
- `openai/*`、`gpt-*` -> OpenAI-compatible
- `qwen/*`、`qwen-*` -> DashScope 的 OpenAI-compatible 形状

代码参考：

- [metadata_for_model()](</home/egg/playground/claw-code/rust/crates/api/src/providers/mod.rs:155>)
- [detect_provider_kind()](</home/egg/playground/claw-code/rust/crates/api/src/providers/mod.rs:201>)
- [OpenAI / DashScope 分支](</home/egg/playground/claw-code/rust/crates/api/src/providers/mod.rs:174>)

### 3. subagent 不是一个模型，是一个“隔离对话”

`Agent` 工具创建的不是新的“模型”，而是一个新的运行时：

- 新的 `Session`
- 新的 `ConversationRuntime`
- 新的 `ProviderRuntimeClient`
- 新的 `SubagentToolExecutor`

也就是说，subagent 本质上是“一个受限的后台对话进程”。

代码参考：

- [execute_agent_with_spawn()](</home/egg/playground/claw-code/rust/crates/tools/src/lib.rs:3481>)
- [build_agent_runtime()](</home/egg/playground/claw-code/rust/crates/tools/src/lib.rs:3598>)
- [run_agent_job()](</home/egg/playground/claw-code/rust/crates/tools/src/lib.rs:3588>)

### 4. `/subagent` 和 `/agent` 是控制面，不是模型面

CLI 里有两组相关命令：

- `/agent`：管理 sub-agent 和 spawned sessions
- `/subagent`：控制正在运行的 sub-agent

这层主要是“看、控、杀”，不是“生成模型回复”。

代码参考：

- [slash command 定义](</home/egg/playground/claw-code/rust/crates/commands/src/lib.rs:991>)
- [slash command 定义](</home/egg/playground/claw-code/rust/crates/commands/src/lib.rs:1003>)

## Expert

### 5. 模型路由的真实入口

路由不是分散在很多地方，而是集中在三个点：

1. `resolve_model_alias()`：做别名展开
2. `detect_provider_kind()`：按前缀和环境变量判定 provider
3. `ProviderClient::from_model_with_anthropic_auth()`：按 provider 构造具体 client

其中最容易踩坑的是 `detect_provider_kind()` 的优先级：

- 如果模型名已经带前缀，优先按前缀走
- 如果用户显式设置了 `OPENAI_BASE_URL`，会优先走 OpenAI-compatible
- 否则才看 Anthropic / XAI 的 auth 状态

这解释了为什么某些本地模型名不规范时，Claude Code 仍然能被配置成走 OpenAI-compatible endpoint。

### 6. provider fallback 不是模型 fallback

这里还有一层容易混淆的东西：**provider fallback chain**。

它不是“一个请求里自动换模型”，而是 `ProviderRuntimeClient` 在失败时按顺序尝试多个 provider entry：

1. 先构造 primary model
2. 再把 `settings.providerFallbacks.fallbacks` 里的模型按顺序加入 chain
3. 只要遇到 retryable error，就尝试下一个 provider

代码参考：

- [ProviderRuntimeClient::new_with_fallback_config()](</home/egg/playground/claw-code/rust/crates/tools/src/lib.rs:4107>)
- [build_provider_entry()](</home/egg/playground/claw-code/rust/crates/tools/src/lib.rs:4134>)
- [load_provider_fallback_config()](</home/egg/playground/claw-code/rust/crates/tools/src/lib.rs:4142>)

这里要分清两件事：

- **模型路由**：决定“这个请求先发给谁”
- **provider fallback**：决定“当前 provider 挂了以后再试谁”

### 7. subagent 的执行模型

`execute_agent_with_spawn()` 会做这些事：

1. 校验 prompt / description
2. 生成 `agent_id`
3. 在 agent store 里写 manifest 文件
4. 计算 `subagent_type`
5. 生成系统提示
6. 生成允许工具集合 `allowed_tools`
7. 创建 `AgentJob`
8. 放到后台线程里跑

核心点在这里：

- `run_agent_job()` 会新建一个独立 `ConversationRuntime`
- 这个 runtime 的 `Session::new()` 是新的，不共享主会话
- `run_turn()` 跑完后，把最终文本写回 agent 的 terminal state

代码参考：

- [execute_agent_with_spawn()](</home/egg/playground/claw-code/rust/crates/tools/src/lib.rs:3481>)
- [spawn_agent_job()](</home/egg/playground/claw-code/rust/crates/tools/src/lib.rs:3561>)
- [build_agent_system_prompt()](</home/egg/playground/claw-code/rust/crates/tools/src/lib.rs:3619>)
- [allowed_tools_for_subagent()](</home/egg/playground/claw-code/rust/crates/tools/src/lib.rs:3642>)

### 8. subagent 之所以“隔离”，是因为工具集被硬编码裁剪了

`allowed_tools_for_subagent()` 会按类型返回不同工具白名单。

例如：

- `Explore` 偏读操作
- `Plan` 允许 `TodoWrite`
- `Verification` 允许 `bash`、`PowerShell`
- 默认类型允许更宽的工具集

这意味着 subagent 不是“主模型的完整复制”，而是一个**受限任务执行器**。

代码参考：

- [allowed_tools_for_subagent()](</home/egg/playground/claw-code/rust/crates/tools/src/lib.rs:3642>)

### 9. `Agent`、`TeamCreate`、`/parallel` 的关系

这三个名字很像，但职责不同：

- `Agent`：创建单个 subagent
- `TeamCreate`：创建一组 sub-agents，面向并行任务执行
- `/parallel`：CLI 层的“并行 subagents”入口

`TeamCreate` 主要做的是把多个任务放进 team registry，并把 task 绑定到 team 上，而不是直接替代 `Agent`。

代码参考：

- [TeamCreate tool](</home/egg/playground/claw-code/rust/crates/tools/src/lib.rs:997>)
- [run_team_create()](</home/egg/playground/claw-code/rust/crates/tools/src/lib.rs:1571>)
- [slash command `/parallel`](</home/egg/playground/claw-code/rust/crates/commands/src/lib.rs:991>)

## A simple mental model

可以把它记成下面这条线：

```text
用户输入模型名
  -> resolve_model_alias()
  -> detect_provider_kind()
  -> ProviderClient::from_model_with_anthropic_auth()
  -> provider 请求 / 流式响应

用户触发 Agent / TeamCreate
  -> 生成新的 AgentJob
  -> 新 Session + 新 ConversationRuntime
  -> allowed_tools 裁剪
  -> 后台线程执行 run_turn()
  -> 结果写回 agent store / registry
```

## 压缩时序图

```text
User
  |
  v
CLI / runtime
  |
  +--> resolve_model_alias()
  +--> detect_provider_kind()
  +--> ProviderClient::from_model_with_anthropic_auth()
  |
  v
ConversationRuntime::run_turn()
  |
  +--> build ApiRequest
  +--> api_client.stream(request)
  +--> build_assistant_message(events)
  +--> collect pending_tool_uses
  |
  +-- if no tool use --> end turn
  |
  +-- if tool use
        |
        +--> permission / hook checks
        +--> tool_executor.execute()
        +--> push tool_result into session
        +--> loop again with updated messages
```

## Six-box loop

```text
[1] user input
    |
[2] build ApiRequest
    |
[3] stream assistant events
    |
[4] collect ToolUse blocks
    |\
    | \-- no ToolUse -> stop
    |
[5] execute tools + push tool_result
    |
[6] repeat with updated session
```

## Core loop: 为什么工具调用后会停

Claude Code 的“继续跑不跑”，关键不在工具本身，而在 `ConversationRuntime::run_turn()` 的外层 loop。

核心逻辑是：

1. 组装 `ApiRequest { system_prompt, messages }`
2. 调 `self.api_client.stream(request)`
3. 把流式事件拼成 `assistant_message`
4. 从 `assistant_message.blocks` 里提取所有 `ContentBlock::ToolUse`
5. 如果没有 `ToolUse`，直接 `break`
6. 如果有 `ToolUse`，逐个执行工具
7. 把每个结果包装成 `ConversationMessage::tool_result(...)`
8. 把 `tool_result` push 回 session
9. 回到 loop 顶部，重新发下一轮请求

对应代码在这里：

- [ConversationRuntime::run_turn()](</home/egg/playground/claw-code/rust/crates/runtime/src/conversation.rs:340>)

### 为什么“工具结束后突然停”

按代码路径看，通常有几类原因：

- **模型没有再发 tool use**：`pending_tool_uses.is_empty()` 直接让 loop 结束。
- **模型只给了文本或 stop**：这仍然算一个完整 assistant turn，runtime 不会自动再猜一轮。
- **post-tool continuation 超时**：Anthropic 路径对工具后的下一帧有 stall timeout，超时会报错并退出。
- **工具结果没有正确回到下一轮**：比如配对被清理、上下文被裁掉、或消息结构不合法。
- **权限 / hook / API 错误**：这些会把当前 tool_result 标成错误并写回 session，但后续是否继续仍取决于模型下一轮是否继续产出 tool use。

对应代码证据：

- [run_turn() 里 `pending_tool_uses.is_empty()` 直接 break](</home/egg/playground/claw-code/rust/crates/runtime/src/conversation.rs:392>)
- [Anthropic post-tool stall timeout](</home/egg/playground/claw-code/rust/crates/rusty-claude-cli/src/main.rs:6838>)
- [把 `tool_result` 写回 session 后再进入下一轮](</home/egg/playground/claw-code/rust/crates/runtime/src/conversation.rs:439>)

## What to remember

- 路由模型靠 **前缀 + 环境变量 + provider metadata**
- fallback 解决的是 **provider 失败**，不是自动智能换模型
- subagent 是 **隔离的对话运行时**
- subagent 的能力边界靠 **allowed_tools** 控制
- `TeamCreate` 是并行调度入口，不是单个 agent 的实现细节

## 相关源码

- [api/src/providers/mod.rs](</home/egg/playground/claw-code/rust/crates/api/src/providers/mod.rs:128>)
- [api/src/client.rs](</home/egg/playground/claw-code/rust/crates/api/src/client.rs:21>)
- [rusty-claude-cli/src/main.rs](</home/egg/playground/claw-code/rust/crates/rusty-claude-cli/src/main.rs:6734>)
- [tools/src/lib.rs](</home/egg/playground/claw-code/rust/crates/tools/src/lib.rs:3477>)
- [commands/src/lib.rs](</home/egg/playground/claw-code/rust/crates/commands/src/lib.rs:991>)

<!-- version: main @ 46552a0 | generated_at: 2026-04-13 00:55:45 CST -->
