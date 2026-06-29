# PI Extension 机制：架构、扩展点与 DIY 能力

## Table of Contents

- [概述](#概述)
- [Beginner：Extension 是什么？](#beginnerextension-是什么)
  - [一个最简单的 Extension](#一个最简单的-extension)
  - [Extension 的加载方式](#extension-的加载方式)
  - [为什么需要 Extension？](#为什么需要-extension)
- [Expert：三层架构与实现](#expert三层架构与实现)
  - [Loader 层：模块发现与加载](#loader-层模块发现与加载)
  - [Wrapper 层：工具适配](#wrapper-层工具适配)
  - [Runner 层：生命周期与事件分发](#runner-层生命周期与事件分发)
- [扩展点全景](#扩展点全景)
  - [事件钩子（~30+ 个）](#事件钩子30-个)
  - [注册 API](#注册-api)
  - [UI 上下文（ctx.ui）](#ui-上下文ctxui)
  - [操作 API（pi.xxx）](#操作-apixxx)
  - [命令上下文增强（ExtensionCommandContext）](#命令上下文增强extensioncommandcontext)
- [开放给 DIY 的端口](#开放给-diy-的端口)
- [For Beginners：类比理解](#for-beginners类比理解)
- [For Experts：设计权衡](#for-experts设计权衡)

## 概述

pi 的 extension 系统是它最核心的设计哲学——**核心最小化，一切皆可替换**。pi 不内置子 agent、plan 模式、权限弹窗、MCP、todo 等功能，而是把这些都作为 extension 可以实现的 DIY 空间。

Extension 机制由 `packages/coding-agent/src/core/extensions/` 下的三个模块实现：

| 模块 | 文件 | 职责 |
|------|------|------|
| **Loader** | `loader.ts` | 发现、加载 TS 模块，注册到 ExtensionAPI |
| **Wrapper** | `wrapper.ts` | 将 extension 工具适配为 agent 内核接口 |
| **Runner** | `runner.ts` | 持所有 extension 实例，事件分发、生命周期管理 |
| **Types** | `types.ts` | 完整的类型定义（ExtensionAPI、事件、上下文等） |

## Beginner：Extension 是什么？

Extension 是一个 TypeScript 模块，默认导出一个工厂函数，接收 `ExtensionAPI` 对象。通过这个对象可以：

- **监听生命周期事件** — 在特定时刻执行自定义逻辑
- **注册工具** — 让 LLM 能调用你写的函数
- **注册命令** — 添加 `/mycommand` 斜杠命令
- **注册快捷键** — 绑定键盘动作
- **注册 CLI 标志** — 自定义 `--flag` 参数
- **与用户交互** — 弹选择框、确认框、输入框

### 一个最简单的 Extension

```typescript
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

export default function (pi: ExtensionAPI) {
  // 注册一个工具
  pi.registerTool({
    name: "greet",
    label: "Greeting",
    description: "Greet someone",
    parameters: Type.Object({
      name: Type.String({ description: "Name" }),
    }),
    async execute(toolCallId, params, signal, onUpdate, ctx) {
      return {
        content: [{ type: "text", text: `Hello ${params.name}!` }],
        details: {},
      };
    },
  });

  // 监听工具调用，阻止危险命令
  pi.on("tool_call", async (event, ctx) => {
    if (event.toolName === "bash" && event.input.command?.includes("rm -rf")) {
      const ok = await ctx.ui.confirm("危险操作", "确认执行 rm -rf？");
      if (!ok) return { block: true, reason: "用户拒绝" };
    }
  });
}
```

### Extension 的加载方式

| 方式 | 命令/路径 | 说明 |
|------|-----------|------|
| **全局自动发现** | `~/.pi/agent/extensions/*.ts` | 所有项目都生效 |
| **项目级自动发现** | `.pi/extensions/*.ts` | 仅当前项目（需 trust 确认） |
| **CLI 指定** | `pi -e ./my-ext.ts` | 临时加载，适合调试 |
| **包管理安装** | `pi install npm:@foo/pi-tools` | 分享给他人 |

核心是用 [jiti](https://github.com/unjs/jiti) 加载 TypeScript 源码，免编译直接运行。对于 Bun 编译的二进制，内置包（`@earendil-works/pi-*`, `typebox`）通过 `virtualModules` 注入；Node.js 模式通过 `alias` 映射到 workspace。

### 为什么需要 Extension？

因为 pi 的哲学是：**不内置你不一定需要的功能**。

> - 没有 MCP → 写一个 extension 加上
> - 没有子 agent → 用 tmux spawn pi，或用 extension 实现
> - 没有权限弹窗 → 用 extension 写符合你环境的确认流程
> - 没有 plan 模式 → 用 extension 自己造
> - 没有内置 todo → 用 TODO.md 或用 extension 实现
> - 没有后台 bash → 用 tmux

## Expert：三层架构与实现

### Loader 层：模块发现与加载

**文件**: `loader.ts`

**发现策略** (`discoverExtensionsInDir`)：
1. 直接 `.ts`/`.js` 文件 → 直接加载
2. 子目录下有 `index.ts`/`index.js` → 加载入口
3. 子目录下有 `package.json` 且含 `pi.extensions` 字段 → 按声明加载

**加载流程** (`loadExtension`)：
1. 用 jiti 导入模块，获取 default export
2. 创建 `Extension` 对象（空 handlers/tools/commands/flags/shortcuts Map）
3. 创建 `ExtensionAPI` 代理对象（注册方法写入 Extension 对象，操作方法委托给共享 runtime）
4. 调用工厂函数 `factory(api)`

**重点**: 操作方法在加载阶段不可用（runtime 尚未 bind），会抛 `"Extension runtime not initialized"`。`registerProvider` 在加载阶段会被排队，等 `bindCore` 后统一 flush。

```typescript
// createExtensionRuntime() 创建时所有操作方法都是 notInitialized 桩
const runtime: ExtensionRuntime = {
  sendMessage: notInitialized,
  sendUserMessage: notInitialized,
  // ...
  pendingProviderRegistrations: [], // 排队等待 bindCore
};
```

**Bun 二进制兼容**: `VIRTUAL_MODULES` 表硬编码了需要 bundled 的包路径，通过 jiti 的 `virtualModules` 选项注入，确保 Bun 编译的单一二进制也能解析这些导入。

### Wrapper 层：工具适配

**文件**: `wrapper.ts`

将 `ToolDefinition`（extension 注册的格式）转换为 `AgentTool`（agent 内核需要的格式）。关键是通过 `runner.createContext()` 注入一致的 `ExtensionContext`，使工具执行时能访问同样的 UI、会话、模型等上下文。

```typescript
export function wrapRegisteredTools(registeredTools: RegisteredTool[], runner: ExtensionRunner): AgentTool[] {
  return wrapToolDefinitions(
    registeredTools.map((t) => t.definition),
    () => runner.createContext(),
  );
}
```

### Runner 层：生命周期与事件分发

**文件**: `runner.ts`

`ExtensionRunner` 是整个系统的中枢，职责包括：

1. **bindCore** — 将内核操作（sendMessage、setActiveTools、setModel 等）注入共享 runtime，刷新加载阶段排队的 provider 注册
2. **createContext** — 为事件处理器和工具执行创建 `ExtensionContext`，所有 getter 都是懒加载的（断言激活状态），确保安全
3. **事件分发** — 每种事件类型有独立 emit 方法：
   - `emit()` — 通用事件分发（session 事件等），支持 cancel 短路
   - `emitToolCall()` — 工具调用拦截，支持 `block`
   - `emitToolResult()` — 工具结果修改
   - `emitContext()` — 消息列表修改
   - `emitBeforeAgentStart()` — system prompt 链式替换
   - `emitInput()` — 输入变换/劫持，支持链式处理
4. **工具/命令注册去重** — `getAllRegisteredTools()` 按 name 去重（先到先得），`resolveRegisteredCommands()` 处理多 extension 同名命令冲突

**Stale 安全机制**: 会话切换或 reload 后，`invalidate()` 会标记所有旧 context 为 stale，任何操作都会抛异常提示开发者使用新的 context。

## 扩展点全景

### 事件钩子（~30+ 个）

**资源事件**:
| 事件 | 说明 | 可返回值 |
|------|------|----------|
| `project_trust` | 决定是否信任项目目录 | `ProjectTrustEventResult` |
| `resources_discover` | 动态声明 skill/prompt/theme 路径 | `ResourcesDiscoverResult` |

**会话事件**:
| 事件 | 说明 | 可返回值 |
|------|------|----------|
| `session_start` | 会话启动/加载/切换后 | — |
| `session_before_switch` | 切换会话前 | `cancel?: boolean` |
| `session_before_fork` | fork 前 | `cancel?: boolean, skipConversationRestore?: boolean` |
| `session_before_compact` | 压缩前 | `cancel?: boolean, compaction?: CompactionResult` |
| `session_compact` | 压缩后 | — |
| `session_shutdown` | 销毁前（quit/reload/switch） | — |
| `session_before_tree` | 树导航前 | `cancel?, summary?, customInstructions?, label?` |
| `session_tree` | 树导航后 | — |

**Agent 事件**:
| 事件 | 说明 | 可返回值 |
|------|------|----------|
| `context` | 消息发给 LLM 前 | `messages?: AgentMessage[]` |
| `before_provider_request` | HTTP 请求发出前 | 替换 payload |
| `after_provider_response` | 收到响应后 | — |
| `before_agent_start` | agent 循环开始前 | `message?: CustomMessage, systemPrompt?: string` |
| `agent_start` / `agent_end` | agent 循环开始/结束 | — |
| `turn_start` / `turn_end` | 每轮开始/结束 | — |

**消息事件**:
| 事件 | 说明 | 可返回值 |
|------|------|----------|
| `message_start` | 消息开始 | — |
| `message_update` | 流式更新（token-by-token） | — |
| `message_end` | 消息结束 | `message?: AgentMessage`（同 role） |

**工具事件**:
| 事件 | 说明 | 可返回值 |
|------|------|----------|
| `tool_call` | 工具执行前 | `block?: boolean, reason?: string` |
| `tool_result` | 工具执行后 | `content?, details?, isError?` |
| `tool_execution_start/update/end` | 工具执行过程 | — |

**模型事件**:
| 事件 | 说明 |
|------|------|
| `model_select` | 模型切换 |
| `thinking_level_select` | thinking level 切换 |

**用户输入事件**:
| 事件 | 说明 | 可返回值 |
|------|------|----------|
| `input` | 用户输入提交时 | `continue / transform(text, images) / handled` |
| `user_bash` | 用户 `!`/`!!` 命令 | `operations?, result?` |

### 注册 API

```typescript
// 工具注册
pi.registerTool({
  name: string,           // LLM 调用的名称
  label: string,          // UI 显示名称
  description: string,    // LLM 理解用途
  promptSnippet?: string, // system prompt 中的一行简介
  promptGuidelines?: string[], // 附加使用指南
  parameters: TypeBox schema,   // 参数 Schema
  executionMode?: "sequential" | "parallel",
  prepareArguments?: (args) => TypedArgs, // 参数预处理
  renderShell?: "default" | "self",
  execute: (id, params, signal, onUpdate, ctx) => ToolResult,
  renderCall?: (args, theme, context) => Component,
  renderResult?: (result, options, theme, context) => Component,
});

// 命令注册
pi.registerCommand("name", {
  description?: string,
  getArgumentCompletions?: (prefix) => AutocompleteItem[],
  handler: (args, ctx: ExtensionCommandContext) => Promise<void>,
});

// 快捷键注册
pi.registerShortcut("ctrl+x", {
  description?: string,
  handler: (ctx: ExtensionContext) => void,
});
// 预留给内置功能的快捷键不可覆盖:
// app.interrupt, app.clear, app.exit, app.suspend, app.thinking.cycle,
// app.model.cycleForward/Backward, app.model.select, app.tools.expand,
// app.thinking.toggle, app.editor.external, app.message.followUp,
// tui.input.submit, tui.select.confirm/cancel, tui.input.copy, tui.editor.deleteToLineEnd

// CLI 标志注册
pi.registerFlag("my-flag", { type: "boolean" | "string", default? });
pi.getFlag("my-flag"); // 取值

// 消息渲染注册
pi.registerMessageRenderer("customType", (message, options, theme) => Component);

// Provider 注册
pi.registerProvider("my-provider", {
  baseUrl, api, apiKey, models, oauth?, streamSimple?, headers?,
});
pi.unregisterProvider("my-provider");
```

### UI 上下文（ctx.ui）

| 类别 | 方法 | 说明 |
|------|------|------|
| **对话框** | `select(title, options, opts?)` | 选择器 |
| | `confirm(title, message, opts?)` | 确认框 |
| | `input(title, placeholder?, opts?)` | 文本输入 |
| | `editor(title, prefill?)` | 多行编辑器 |
| **通知** | `notify(message, type?)` | info/warning/error |
| **编辑器** | `setEditorText(text)` / `getEditorText()` | 读写编辑器内容 |
| | `pasteToEditor(text)` | 粘贴（触发大内容折叠） |
| | `setEditorComponent(factory)` | 替换为自定义编辑器 |
| **UI 组件** | `setWidget(key, content, opts?)` | 编辑器上下方小组件 |
| | `setFooter(factory)` | 替换底部状态栏 |
| | `setHeader(factory)` | 替换顶部标题栏 |
| | `setTitle(title)` | 终端窗口标题 |
| | `custom(factory, opts?)` | 完整自定义交互组件 |
| **自动补全** | `addAutocompleteProvider(factory)` | 叠加自动补全 |
| **状态指示** | `setStatus(key, text)` | footer 状态文本 |
| | `setWorkingMessage(msg?)` | 流式加载文字 |
| | `setWorkingIndicator(opts?)` | 自定义加载动画帧 |
| | `setHiddenThinkingLabel(label?)` | 隐藏 thinking 块的标签 |
| **主题** | `setTheme(name\|Theme)` | 切换主题 |
| | `getTheme(name)` | 获取主题 |
| | `getAllThemes()` | 列出所有主题 |
| **终端** | `onTerminalInput(handler)` | 原始键盘输入监听 |
| **工具显示** | `getToolsExpanded()` / `setToolsExpanded(bool)` | 工具输出展开/折叠 |

`select`/`confirm`/`input` 支持 `ExtensionUIDialogOptions`：`signal?: AbortSignal`（外部关闭）、`timeout?: number`（自动关闭 + 倒计时）。

### 操作 API（pi.xxx）

```typescript
// 消息注入
pi.sendMessage(message, { triggerTurn?, deliverAs? });
pi.sendUserMessage(content, { deliverAs? });

// 持久化状态（JSONL 存储，跨重启）
pi.appendEntry(customType, data?);

// 会话元数据
pi.setSessionName(name);
pi.getSessionName();
pi.setLabel(entryId, label);

// 工具管理
pi.getActiveTools();
pi.setActiveTools(names);
pi.getAllTools(); // 含参数 schema、来源

// 模型控制
pi.setModel(model); // 返回 false 表示无 API key
pi.getThinkingLevel();
pi.setThinkingLevel(level);

// 其他
pi.exec(command, args, options?); // shell 执行
pi.getCommands(); // 获取所有斜杠命令
pi.events; // 跨 extension 事件总线
```

### 命令上下文增强（ExtensionCommandContext）

比普通 ExtensionContext 多了：

```typescript
interface ExtensionCommandContext extends ExtensionContext {
  getSystemPromptOptions(): BuildSystemPromptOptions;
  waitForIdle(): Promise<void>;                     // 等待 agent 空闲
  newSession(options?): Promise<{ cancelled }>;     // 新建会话
  fork(entryId, options?): Promise<{ cancelled }>;  // fork 会话
  navigateTree(targetId, options?): Promise<{ cancelled }>; // 树导航
  switchSession(sessionPath, options?): Promise<{ cancelled }>; // 切换会话
  reload(): Promise<void>;                          // 热重载
}
```

## 开放给 DIY 的端口

| 你想做的事 | 用什么实现 |
|------------|-----------|
| **替换内置工具** | `registerTool()` + `on("tool_call")` 拦截原工具名 |
| **远程执行** | `on("tool_call")` 返回自定义 `BashOperations` |
| **权限控制** | `on("tool_call")` → `return { block: true }` |
| **自定义 LLM provider** | `registerProvider()` 支持 OAuth、自定义流式 |
| **自定义编辑体验** | `ctx.ui.setEditorComponent()` |
| **自定义 UI 层** | `setWidget/setFooter/setHeader` + `custom({ overlay: true })` |
| **system prompt 注入** | `on("before_agent_start")` → `return { systemPrompt }` |
| **请求拦截/修改** | `on("before_provider_request")` → 修改 payload |
| **输入预处理** | `on("input")` → `return { action: "transform", text }` |
| **状态持久化** | `pi.appendEntry()` 写入 JSONL，`on("session_start")` 恢复 |
| **压缩策略** | `on("session_before_compact")` → `return { compaction }` |
| **会话事件守卫** | `on("session_before_switch/fork")` → `return { cancel: true }` |
| **跨 extension 通信** | `pi.events`（EventBus） |
| **自定义消息渲染** | `registerMessageRenderer()` |
| **工具效果自定义** | `renderCall`/`renderResult` 在 `registerTool()` 中 |
| **DOOM** | `ctx.ui.custom({ overlay: true })` 35fps 实时渲染 |

## For Beginners：类比理解

把 pi 想象成一个**插线板**：

- **pi 内核** = 插线板本身（只有最基本的供电功能）
- **Extension** = 你插入的电器（电饭煲、充电器、台灯）
- **事件监听** = 电器上的传感器（电饭煲检测到饭熟了自动跳闸）
- **工具注册** = 电器提供了新的功能（台灯提供了照明）
- **UI 上下文** = 电器的控制面板（按钮、指示灯）

pi 内核提供的是 "电"（事件循环、工具执行框架、会话管理），至于你用这些电做什么——做饭、照明、充电——全是 extension 决定的。

## For Experts：设计权衡

**为什么不用 MCP？** pi 的观点：MCP 是为服务端-客户端设计的协议，对于 CLI agent 来说，直接用 TypeScript extension 更简单、类型安全、更强大。不需要序列化/反序列化、不需要子进程、直接共享内存。

**为什么不用子 agent？** 实现方式太多（tmux spawn、fork 子进程、sandbox），pi 不替你做选择。用 extension 做最适合你的那种。

**为什么用 jiti 而不用 esbuild/wasm？** jiti 实现了 Node.js/Bun 一致的加载行为，支持 npm 依赖解析、缓存友好、与 sourcemap 兼容。编译型方案在 Bun binary 模式下反而更复杂。

**为什么用 TypeBox 而不用 Zod？** TypeBox 与 JSON Schema 兼容，Google Gemini API 要求 StringEnum 而非 Union of Literals，TypeBox 能直接支持。且 TypeBox 的 `Static<T>` 推导在交叉类型场景更稳定。

**Stale context 安全设计**: `ExtensionRunner.createContext()` 返回的所有 getter 都是运行时解析的，并且每次调用会先 `assertActive()`。当会话切换或 reload 后，`invalidate()` 方法设置 stale 标记，任何操作都会抛异常。这防止了 extension 持有过期引用导致的诡异 bug。

**事件分发的两阶段设计**: `tool_call` 事件直接修改 `event.input` 可变对象（不返回新值），后序处理器看到的是前序的修改结果；而 `before_agent_start` 的 `systemPrompt` 通过 return 值链式传递。前者适用于拦截器模式（pipeline），后者适用于累加器模式（reduce）。设计依据是：工具参数需要有序变换，system prompt 需要在全部收集后最终确定。

---

*当前版本: pi-mono monorepo, packages/coding-agent/src/core/extensions/*
*生成时间: 2026-06-18*
