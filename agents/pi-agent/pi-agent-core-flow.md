# PI Agent Core 核心流程

## Table of Contents

- [Overview](#overview)
- [Architecture Layers](#architecture-layers)
- [核心循环：双重嵌套循环设计](#核心循环双重嵌套循环设计)
- [完整请求生命周期](#完整请求生命周期)
- [关键转换边界：AgentMessage → Message](#关键转换边界agentmessage--message)
- [流式响应处理](#流式响应处理)
- [工具执行机制](#工具执行机制)
- [Hooks 系统](#hooks-系统)
- [队列系统：Steering 与 Follow-up](#队列系统steering-与-follow-up)
- [状态管理](#状态管理)
- [事件系统](#事件系统)
- [For Beginners：类比理解](#for-beginners类比理解)
- [For Experts：设计权衡](#for-experts设计权衡)

## Overview

`@earendil-works/pi-agent-core` 是 PI 的 agent 运行时，位于 `packages/agent/`。它构建在 `@earendil-works/pi-ai` 之上，提供：

- **有状态的 Agent 类** — 管理 transcript、工具注册、事件订阅
- **工具调用循环** — 自动处理 LLM → tool call → tool result → LLM 的迭代
- **事件系统** — 流式输出、工具执行进度、生命周期变化的统一事件接口
- **队列系统** — 运行时注入消息（steering）和后续任务（follow-up）
- **可扩展消息类型** — 通过 declaration merging 支持自定义消息

package 只有三个核心源文件：

| 文件 | 行数 | 职责 |
|---|---|---|
| `src/types.ts` | 423 | 所有类型定义 |
| `src/agent.ts` | 557 | Agent 类（状态封装） |
| `src/agent-loop.ts` | 748 | 循环逻辑（无状态） |

## Architecture Layers

```
┌─────────────────────────────────────────────────────────┐
│                    Agent Class (agent.ts)                 │
│  状态管理 / 事件订阅 / prompt/continue / steer/followUp  │
├─────────────────────────────────────────────────────────┤
│                  Agent Loop (agent-loop.ts)               │
│  双重嵌套循环 / 工具调度 / 流式处理 / 队列 drain         │
├─────────────────────────────────────────────────────────┤
│              @earendil-works/pi-ai (外部依赖)              │
│  stream/complete / Model / Context / Message 类型         │
└─────────────────────────────────────────────────────────┘
```

## 核心循环：双重嵌套循环设计

`runLoop()` 是 agent 的心脏，采用**双重嵌套循环**结构：

```
OUTER LOOP: while(true)
  │
  ├─ 作用：处理 follow-up 消息
  │  当 agent 自然停止时，检查是否有 follow-up 需继续
  │
  └─ INNER LOOP: while(hasMoreToolCalls || pendingMessages.length > 0)
       │
       ├─ 作用：处理工具调用链
       │  只要 LLM 返回 tool call 就去执行，然后继续调 LLM
       │
       ├─ turn_start
       ├─ 注入 steering messages（如果有）
       ├─ streamAssistantResponse() ← 调 LLM
       ├─ 如果有 tool calls → executeToolCalls()
       ├─ turn_end
       ├─ shouldStopAfterTurn? → 提前退出
       └─ 检查 steering messages → 有则注入，继续内层循环
  │
  ├─ 检查 follow-up messages
  │   有 → 设为 pending，外层循环继续
  └─ 没有 → break → agent_end
```

**关键判断：内层循环在以下情况停止：**
- LLM 返回的 response 没有 tool call（自然结束）
- 所有 tool 返回了 `terminate: true`（工具要求停止）
- `shouldStopAfterTurn` 返回 `true`
- 出现 error/abort

**外层循环在以下情况继续：**
- 有 follow-up 消息在队列中

## 完整请求生命周期

### `agent.prompt("Hello")` 的事件序列

```
Agent.prompt("Hello")
│
├─ agent_start
│
├─ turn_start
│
├─ message_start  { role: "user", content: "Hello" }
├─ message_end    { role: "user", content: "Hello" }
│
├─ message_start  { role: "assistant", partial, content: [] }  ← LLM 开始回复
├─ message_update { assistantMessageEvent: text_delta, "Hello" }
├─ message_update { assistantMessageEvent: text_delta, "! How" }
├─ message_update { assistantMessageEvent: text_delta, " can I help?" }
├─ message_end    { role: "assistant", content: "Hello! How can I help?" }
│
├─ turn_end       { message, toolResults: [] }
└─ agent_end      { messages: [...] }
```

### 带工具调用的生命周期

```
agent.prompt("Read config.json and summarize")
│
├─ agent_start, turn_start, message_start/end (user)
│
├─ message_start  { assistant, content: [toolCall] }     ← LLM 要调工具
├─ message_end    { assistant, content: [toolCall] }
│
├─ tool_execution_start  { toolCallId, toolName: "read_file", args: {path: "config.json"} }
│    若工具支持进度：tool_execution_update { partialResult }
├─ tool_execution_end    { toolCallId, result: {content: "..."} }
├─ message_start  { role: "toolResult", toolCallId, content: "..." }
├─ message_end    { role: "toolResult", toolCallId, content: "..." }
│
├─ turn_end       { message, toolResults: [toolResult] }
│
├─ turn_start     ← 自动下一轮（因为还有 tool call 要处理）
│
├─ message_start  { assistant, content: [text] }         ← LLM 对结果总结
├─ message_update { text_delta, "The config contains..." }
├─ message_end
│
├─ turn_end
└─ agent_end
```

### `agent.continue()` 的事件序列

`continue()` 不从新消息开始，而是从现有 context 继续。要求 context 中最后一条消息必须是 `user` 或 `toolResult`（不能是 `assistant`）：

```
// 场景：上轮出错，重试
agent.continue()
│
├─ 校验 messages 非空且最后一条不是 assistant
├─ 检查 steering/follow-up queue
│   └─ 如果有队列消息，走 runPromptMessages（注入队列消息后启动新循环）
│   └─ 如果都没有，抛错（assistant 后面没东西可继续）
│
└─ runAgentLoopContinue → runLoop（不添加 prompt 消息，直接进入循环）
```

## 关键转换边界：AgentMessage → Message

这是最重要的设计决策之一。Agent 内部使用 `AgentMessage`，只在 LLM 调用边界才转为 `Message[]`：

```
AgentMessage[]  ──→  transformContext()  ──→  AgentMessage[]  ──→  convertToLlm()  ──→  Message[]  ──→  LLM
  灵活的内部格式       可选：裁剪/注入              过滤/转换              pi-ai 标准格式
```

**`AgentMessage` 的定义：**

```typescript
// 基础 = pi-ai 的 Message union（user | assistant | toolResult）
// + 通过 declaration merging 扩展的自定义类型
export type AgentMessage = Message | CustomAgentMessages[keyof CustomAgentMessages];

// 扩展方式：declaration merging
declare module "@earendil-works/pi-agent-core" {
  interface CustomAgentMessages {
    notification: { role: "notification"; text: string; timestamp: number };
    artifact: { role: "artifact"; content: string; language: string };
  }
}
```

**`convertToLlm` 的职责：**
- 过滤掉 UI-only 消息（notification、status 等）
- 将自定义消息类型转换为 LLM 能理解的格式
- 默认实现：只保留 `user`、`assistant`、`toolResult` 三种角色

```typescript
// 自定义 convertToLlm
const agent = new Agent({
  convertToLlm: (messages) => messages.flatMap(m => {
    if (m.role === "notification") return [];        // 过滤掉
    if (m.role === "artifact") {
      return [{ role: "user", content: m.content, timestamp: m.timestamp }]; // 转为 user 消息
    }
    return [m];  // 标准消息透传
  }),
});
```

**`transformContext` 的职责：**
- Context window 管理（裁剪旧消息）
- 注入外部上下文（RAG 结果、系统状态）
- 在 convertToLlm 之前运行，操作的是 `AgentMessage[]`

## 流式响应处理

`streamAssistantResponse()` 的实现细节：

```typescript
async function streamAssistantResponse(context, config, signal, emit): Promise<AssistantMessage> {
  // 1. 应用 transformContext（可选）
  let messages = context.messages;
  if (config.transformContext) { messages = await config.transformContext(messages, signal); }

  // 2. 转换为 LLM 格式
  const llmMessages = await config.convertToLlm(messages);

  // 3. 调 LLM
  const response = await streamFunction(config.model, { systemPrompt, messages: llmMessages, tools }, { ... });

  // 4. 流事件处理
  let partialMessage = null;
  let addedPartial = false;

  for await (const event of response) {
    switch (event.type) {
      case "start":
        partialMessage = event.partial;
        context.messages.push(partialMessage);  // ← 推入空的 AssistantMessage 占位
        emit message_start({ ...partialMessage });
        break;

      case "text_delta":
      case "thinking_delta":
      case "toolcall_delta":
        // 原地更新 context.messages 中的最后一个消息
        partialMessage = event.partial;
        context.messages[context.messages.length - 1] = partialMessage;
        emit message_update({ assistantMessageEvent: event, message: partialMessage });
        break;

      case "done":
      case "error":
        const finalMessage = await response.result();
        context.messages[context.messages.length - 1] = finalMessage;  // 替换为最终版本
        emit message_end(finalMessage);
        return finalMessage;
    }
  }
}
```

**关键设计点：** `context.messages` 中的 `AssistantMessage` 是**原地更新的**。从 `start` 事件推入一个空壳，后续每个 delta 都替换引用，保证消费者的状态视图始终反映最新。

## 工具执行机制

### 调度策略

```typescript
async function executeToolCalls(context, assistantMessage, config, signal, emit) {
  const toolCalls = assistantMessage.content.filter(c => c.type === "toolCall");

  // 检查是否有 sequential 工具 → 整个 batch 走顺序
  const hasSequential = toolCalls.some(tc =>
    context.tools?.find(t => t.name === tc.name)?.executionMode === "sequential"
  );

  if (config.toolExecution === "sequential" || hasSequential) {
    return executeSequential(context, assistantMessage, toolCalls, config, signal, emit);
  }
  return executeParallel(context, assistantMessage, toolCalls, config, signal, emit);
}
```

全局可配置：`agent.toolExecution = "parallel"`（默认）或 `"sequential"`。
单个工具可覆盖：`AgentTool.executionMode = "sequential"`。
**只要 batch 中有一个工具是 sequential，整个 batch 都走顺序模式。**

### 顺序模式

```
对每个 tool call：
  1. emit tool_execution_start
  2. preflight（找工具、校验参数、beforeToolCall 钩子）
  3. execute（等前一个完成）
  4. finalize（afterToolCall 钩子）
  5. emit tool_execution_end
  6. emit message_start/end（toolResult）
  7. 如果 signal.aborted → break
```

### 并行模式

```
Phase 1 — Preflight（顺序执行，不执行工具）：
  对每个 tool call：
    1. emit tool_execution_start
    2. preflight → 校验、beforeToolCall
    3. 如果通过 → 存入准备好的任务列表
    4. 如果 blocked/immediate error → 立即 emit tool_execution_end

Phase 2 — 并发执行：
  Promise.all(
    准备好的任务.map(task => {
      1. execute
      2. finalize
      3. emit tool_execution_end  ← 按完成顺序，不等其他
    })
  )

Phase 3 — 按原始顺序 emit toolResult message：
  for (按照 assistant 中 tool call 的顺序):
    emit message_start/end（toolResult）
```

**并行模式的要点：** `tool_execution_end` 按工具完成顺序 emit（流式 UI 友好），但 `ToolResultMessage` 按 assistant 中 tool call 的原始顺序 emit（LLM 兼容性要求）。

### 每个工具调用的完整生命周期

```
preflight:
  ├─ 查找同名 AgentTool
  ├─ 找不到 → 立即返回 error（kind: "immediate"）
  ├─ prepareArguments（可选参数转换）
  ├─ validateToolArguments（TypeBox schema 校验）
  └─ beforeToolCall 钩子
       ├─ 返回 { block: true } → 立即返回 error（kind: "immediate"）
       └─ 返回 undefined → 继续（kind: "prepared"）

execute:
  └─ tool.execute(toolCallId, validatedArgs, signal, onUpdate)
       ├─ 成功 → { result, isError: false }
       ├─ 抛错 → catch → { result: error message, isError: true }
       └─ onUpdate（可选进度回调）→ tool_execution_update 事件

finalize:
  └─ afterToolCall 钩子
       ├─ 可以覆盖 content / details / isError / terminate
       └─ 返回 undefined → 保持原始结果
```

### terminate 机制

工具或 `afterToolCall` 可以返回 `terminate: true`，表示建议 agent 停止。但只有**当 batch 中所有工具都设置了 true** 时，agent 才会跳过下一轮 LLM 调用：

```typescript
function shouldTerminateToolBatch(finalizedCalls): boolean {
  return finalizedCalls.length > 0
    && finalizedCalls.every(f => f.result.terminate === true);
}
```

## Hooks 系统

### beforeToolCall

在参数校验之后、工具执行之前调用。可以阻止工具执行：

```typescript
beforeToolCall: async ({ assistantMessage, toolCall, args, context }, signal) => {
  if (toolCall.name === "bash" && args.command.includes("rm -rf")) {
    return { block: true, reason: "Dangerous command blocked" };
  }
  // return undefined → 放行
}
```

### afterToolCall

在工具执行之后、`tool_execution_end` 事件发送之前调用。可以修改结果：

```typescript
afterToolCall: async ({ toolCall, result, isError, context }, signal) => {
  return {
    content: result.content,      // 替换 content（整体替换，非 merge）
    details: { audited: true },   // 替换 details
    isError: false,               // 覆盖 isError
    terminate: true,              // 建议停止
  };
}
```

**merge 语义：字段级别替换** — 提供就覆盖，不提供就保留原始值。没有 deep merge。

### prepareNextTurn

在 turn 结束之后、下一轮 LLM 调用之前调用。支持运行时替换 model、reasoning level、context：

```typescript
prepareNextTurn: async (signal) => {
  if (needsDeepThinking(context)) {
    return {
      model: getModel("anthropic", "claude-sonnet-4-20250514"),
      thinkingLevel: "high",
    };
  }
  // return undefined → 保持当前配置
}
```

### shouldStopAfterTurn

在 `turn_end` 之后调用，返回 `true` 则 agent 优雅停止（不调 LLM、不取消正在执行的工具）：

```typescript
shouldStopAfterTurn: async ({ message, toolResults, context, newMessages }) => {
  return estimateTokens(context.messages) > MAX_TOKENS;
}
```

## 队列系统：Steering 与 Follow-up

### Steering Messages（运行时注入）

当 agent 正在运行时，可以注入消息打断当前思路：

```typescript
agent.steer({ role: "user", content: "等等，换个方向", timestamp: Date.now() });

// 注入时机：每轮 tool call 完成后，下一轮 LLM 调用之前
// drain 模式：默认 "one-at-a-time"（每次取最早一条）
//           "all"（一次性全部取出）
```

**Steering 的触发点**（在内层循环中）：

```
turn_end → shouldStopAfterTurn? → getSteeringMessages()
                                   如果有消息 → 注入 context → 继续内层循环
                                   如果没有 → 检查 follow-up
```

### Follow-up Messages（自然停止后执行）

当 agent 将要自然停止时，可以追加后续任务：

```typescript
agent.followUp({ role: "user", content: "把结果存到文件", timestamp: Date.now() });

// 触发点：在外层循环中，内层循环结束后
// 检查 getFollowUpMessages() → 有则设为 pending → 外层循环继续
```

### 队列 drain 机制

```
agent.steer(msg1) → [msg1]
agent.steer(msg2) → [msg1, msg2]

// 第一次 drain（one-at-a-time）→ [msg1]
// 第二次 drain → [msg2]
// 第三次 drain → []

agent.steeringMode = "all";
agent.steer(msg1), agent.steer(msg2)
// 第一次 drain → [msg1, msg2]（一次性全部）
```

## 状态管理

### Agent.state 的完整定义

```typescript
interface AgentState {
  systemPrompt: string;
  model: Model<any>;
  thinkingLevel: ThinkingLevel;      // "off" | "minimal" | "low" | "medium" | "high" | "xhigh"
  tools: AgentTool<any>[];           // assign 时复制顶层数组
  messages: AgentMessage[];          // assign 时复制顶层数组
  readonly isStreaming: boolean;     // 是否正在处理（含 agent_end listener 等待）
  readonly streamingMessage?: AgentMessage;  // 当前 partial assistant message
  readonly pendingToolCalls: ReadonlySet<string>;  // 正在执行的 tool call ID
  readonly errorMessage?: string;    // 最近一次出错信息
}
```

### 状态变更路径

```
状态变更                触发方式
───────────            ──────────
systemPrompt           agent.state.systemPrompt = "..."
model                  agent.state.model = getModel(...)
tools                  agent.state.tools = [tool1, tool2]
messages               agent.state.messages.push(msg) 或 agent.reset()
isStreaming            自动管理（prompt/continue 期间为 true）
streamingMessage       自动管理（流式输出期间更新）
pendingToolCalls       自动管理（工具执行期间更新）
errorMessage           自动管理（assistant turn 出错时设置）
```

### reset() 的行为

```typescript
agent.reset()
  ├─ messages = []
  ├─ isStreaming = false
  ├─ streamingMessage = undefined
  ├─ pendingToolCalls = new Set()
  ├─ errorMessage = undefined
  ├─ clearFollowUpQueue()
  └─ clearSteeringQueue()
```

**不重置：** systemPrompt、model、thinkingLevel、tools、hooks

## 事件系统

### 事件类型一览

```
Agent 生命周期:
  agent_start                     → agent 开始处理
  agent_end { messages }          → agent 处理完成

Turn 生命周期（一轮 LLM 调用 + 工具执行）:
  turn_start                      → 新的一轮开始
  turn_end { message, toolResults } → 一轮结束

消息生命周期:
  message_start { message }       → 任何消息开始（user/assistant/toolResult）
  message_update { message, assistantMessageEvent }  → 仅 assistant 流式更新
  message_end { message }         → 消息完成

工具执行生命周期:
  tool_execution_start { toolCallId, toolName, args }   → 工具开始
  tool_execution_update { partialResult }               → 工具进度（可选）
  tool_execution_end { toolCallId, result, isError }    → 工具完成
```

### 订阅机制

```typescript
const unsubscribe = agent.subscribe(async (event, signal) => {
  if (event.type === "message_update" && event.assistantMessageEvent.type === "text_delta") {
    process.stdout.write(event.assistantMessageEvent.delta);
  }
  if (event.type === "agent_end") {
    // agent_end 是最后一个事件，但 agent 在等所有 subscriber 完成才 idle
    await flushSession(signal);
  }
});

// 取消订阅
unsubscribe();
```

**关键行为：** subscriber 按注册顺序 await，`agent_end` listener 完成后 agent 才变为 idle。`agent.waitForIdle()` 等待所有 subscriber 完成。

### 事件与状态的一致性

```
┌──────────────┐     message_start     ┌────────────────┐
│              │ ──────────────────→   │                │
│  Agent Loop  │     message_update    │  Event Stream  │
│  (产生事件)   │ ──────────────────→   │  (事件流)       │
│              │     message_end       │                │
│              │ ──────────────────→   │                │
│              │     tool_execution_*  │                │
│              │ ──────────────────→   │                │
└──────────────┘                       └────────────────┘
       │                                      │
       │ 同时更新                               │
       ▼                                      ▼
┌──────────────────┐                  ┌──────────────────┐
│  Agent.state      │                  │  UI / Logger     │
│  (内部状态)       │                  │  (外部消费者)     │
└──────────────────┘                  └──────────────────┘
```

`Agent.state` 和事件流是同步更新的——`processEvents()` 先更新 state，再 emit 事件给 subscriber。

## For Beginners：类比理解

**Agent 就像一个智能体的决策循环：**

- **Agent 类** — 人的大脑，记住对话历史、知道有哪些工具可用、知道当前状态
- **Agent Loop** — 人的思考循环：想（调 LLM）→ 做（调工具）→ 看结果 → 再想
- **AgentMessage** — 人的内部笔记格式，可以记录各种信息（对话、通知、代码片段）
- **convertToLlm** — 把内部笔记转换成 LLM 能理解的格式（就像你要跟外国人说话前先翻译）
- **streamAssistantResponse** — LLM 边想边说，每说一句你都听到（流式输出）
- **Tool execution** — 调用工具就像你使用计算器、查词典，用完之后把结果记下来
- **Steering messages** — 就像别人在做事的时候喊一声"等等，先做这个"
- **Follow-up messages** — 就像别人做完事后你追加一句"对了，顺便..."

**双重嵌套循环的类比：**

内层循环 = "做一步想一步"——LLM 说要用工具 → 执行工具 → 把结果给 LLM 看 → LLM 决定下一步
外层循环 = "做完后还有事儿吗"——agent 自然停后，检查有没有 follow-up 要处理

## For Experts：设计权衡

**为什么用双重嵌套循环而不是递归？**
- 递归的深度 = 工具调用链长度，可能 stack overflow
- 循环模型更容易实现中断（abort signal 在每次迭代中检查）
- 状态在每次迭代末尾可以快照（prepareNextTurn 机制）

**AgentMessage = Message | Custom 的设计意图：**
- pi-ai 的 `Message` union 已经是 `user | assistant | toolResult`，覆盖了 LLM 需要的所有角色
- Declaration merging 允许应用层添加自定义类型（artifact、notification、progress 等），无需修改核心包
- 代价：convertToLlm 必须由调用方实现，增加了一点配置成本

**为什么并行工具执行默认用 preflight 串行 + execute 并发？**
- Preflight 串行：保证 beforeToolCall 钩子按顺序执行，避免竞态条件（一个工具的结果影响另一个工具的执行决策）
- Execute 并发：IO 密集型工具（读文件、调 API）可以同时跑，显著减少总延迟
- 如果工具间有依赖，用 `executionMode: "sequential"` 标记即可

**event loop 的 await 语义：**
- 每个 subscriber 的 promise 被 await，保证了事件处理的顺序性
- `agent_end` 事件后 agent 不立即 idle，而是等所有 subscriber 完成
- 这意味着 subscriber 中的异步操作（写数据库、发通知）可以作为 run 的一部分
- 代价：慢 subscriber 会阻塞整个 run 的完成

**context.messages 的原地更新策略：**
- 流式输出期间，`context.messages` 中的最后一个 assistant message 被反复替换
- 好处：任何时候访问 `agent.state.messages` 都能拿到最新状态
- 好处：事件消费者不需要手动维护 partial message 的累计状态
- 代价：消息对象的引用在流式期间会变（每个 delta 事件都替换）

**terminate 的 all-or-nothing 语义（不是 any）：**
- 设计考量：防止单个工具意外终止整个 agent 流程
- 只有所有工具一致同意停止时（如 `notify_done` + 其他都返回了 terminate），才跳过下一轮
- 混合 batch（有的 terminate=true，有的 false/undefined）正常继续

---

*Based on pi-mono commit 6d5ede31 (master branch), 2026-06-18*
