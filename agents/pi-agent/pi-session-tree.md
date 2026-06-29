# pi 会话树机制：分支式对话的数据结构、持久化与状态机

## Table of Contents

- [概述](#概述)
- [一、数据模型：9 种 Entry 组成的 append-only 树](#一数据模型9-种-entry-组成的-append-only-树)
  - [1.1 Entry 类型全景](#11-entry-类型全景)
  - [1.2 树结构的隐式表达](#12-树结构的隐式表达)
  - [1.3 内存索引层](#13-内存索引层)
- [二、JSONL 持久化：lazy flush + 追加写](#二jsonl-持久化lazy-flush--追加写)
  - [2.1 文件格式](#21-文件格式)
  - [2.2 延迟刷盘策略](#22-延迟刷盘策略)
  - [2.3 版本迁移](#23-版本迁移)
- [三、Leaf 指针状态机：分支与追加](#三leaf-指针状态机分支与追加)
  - [3.1 追加（append）—— 时间向前走](#31-追加append--时间向前走)
  - [3.2 分支（branch）—— 指针回跳，历史不改](#32-分支branch--指针回跳历史不改)
  - [3.3 带摘要的分支（branchWithSummary）](#33-带摘要的分支branchwithsummary)
  - [3.4 操作矩阵](#34-操作矩阵)
- [四、AgentSession：事件驱动的响应粒度管理](#四agentsession事件驱动的响应粒度管理)
  - [4.1 事件管线](#41-事件管线)
  - [4.2 持久化触发点](#42-持久化触发点)
  - [4.3 一次 turn 的粒度拆分](#43-一次-turn-的粒度拆分)
- [五、LLM Context 构建：路径化上下文组装](#五llm-context-构建路径化上下文组装)
  - [5.1 buildSessionContext 逻辑](#51-buildsessioncontext-逻辑)
  - [5.2 Compaction 后的 context 重构](#52-compaction-后的-context-重构)
- [六、collectEntriesForBranchSummary：分支导航中的祖先计算](#六collectentriesforbranchsummary分支导航中的祖先计算)
- [七、`/tree` TUI 组件的渲染层](#七tree-tui-组件的渲染层)
  - [7.1 触发入口](#71-触发入口)
  - [7.2 组件树](#72-组件树)
  - [7.3 核心渲染算法](#73-核心渲染算法)
  - [7.4 过滤与搜索](#74-过滤与搜索)
  - [7.5 Fold 机制](#75-fold-机制)
- [八、完整闭合链路](#八完整闭合链路)
- [关键文件索引](#关键文件索引)

## 概述

pi 的会话不是线性聊天历史，而是一个**可分支的树状结构**。用户可以回到会话中的任意节点，发起新的对话分支，同时保留原有路径。这套机制由三部分组成：

1. **SessionManager**：树状数据模型 + append-only 持久化 + leaf 指针状态机
2. **AgentSession**：事件驱动的消息粒度追踪，每个 LLM response 原子化保存
3. **TreeSelectorComponent**：TUI 树形选择器，渲染 ASCII 树、支持过滤/搜索/fold

核心设计原则：**历史不可变（append-only），只变 leaf 指针**。

---

## 一、数据模型：9 种 Entry 组成的 append-only 树

### 1.1 Entry 类型全景

所有 Entry 共享基类，通过 `parentId` 构成树：

```typescript
interface SessionEntryBase {
  type: string;
  id: string;              // 8 位 hex，全局唯一
  parentId: string | null; // null = 根节点
  timestamp: string;
}
```

9 种具体类型：

| # | type 字段 | 对应接口 | 含义 | 参与 LLM context? |
|---|-----------|---------|------|-------------------|
| 1 | `"message"` | `SessionMessageEntry` | user / assistant / toolResult / bashExecution | **是** |
| 2 | `"custom_message"` | `CustomMessageEntry` | 扩展注入的消息 | **是** |
| 3 | `"compaction"` | `CompactionEntry` | 上下文压缩摘要 | 摘要部分参与 |
| 4 | `"branch_summary"` | `BranchSummaryEntry` | 分支导航时的对话摘要 | **是**（作为系统消息） |
| 5 | `"model_change"` | `ModelChangeEntry` | 模型切换 | 否 |
| 6 | `"thinking_level_change"` | `ThinkingLevelChangeEntry` | thinking 级别变更 | 否 |
| 7 | `"custom"` | `CustomEntry` | 扩展私有数据存储 | 否 |
| 8 | `"label"` | `LabelEntry` | 用户书签（/tree 中可见） | 否 |
| 9 | `"session_info"` | `SessionInfoEntry` | 会话标题 | 否 |

### 1.2 树结构的隐式表达

pi 不存储显式的 N-ary tree 结构。树是**隐式编码在 `parentId` 字段中**的。

```
root (null)
├── user: "hello"        (parentId=null)
│   └── asst: "hi!"      (parentId=user)
│       ├── user: "edit"  (parentId=asst)
│       │   └── asst: "ok" (parentId=user-edit)
│       └── label: "greet" (parentId=asst)
└── (无)
```

`getTree()` 方法在内存中重建为 `SessionTreeNode[]`：

```typescript
interface SessionTreeNode {
  entry: SessionEntry;
  children: SessionTreeNode[];
  label?: string;          // 解析后的标签
  labelTimestamp?: string; // 标签时间戳
}
```

Label 的解析是独立的：扫描所有 `LabelEntry`，构建 `labelsById: Map<entryId, label>`，在构建树时附加到每个节点上。

### 1.3 内存索引层

```typescript
class SessionManager {
  private fileEntries: FileEntry[] = [];     // 全量序列（含 header），append-only
  private byId: Map<string, SessionEntry>;   // O(1) 随机访问
  private leafId: string | null = null;      // 当前分支位置
  private labelsById: Map<string, string>;   // entryId → label
  private labelTimestampsById: Map<string, string>;
}
```

- `fileEntries` 是 JSONL 文件的完整内存镜像
- `byId` 提供 key-value 查找
- `leafId` 是**唯一可变的状态**，决定 "现在在哪"

---

## 二、JSONL 持久化：lazy flush + 追加写

### 2.1 文件格式

每行一个 JSON 对象，第一行是 `SessionHeader`：

```
{"type":"session","version":3,"id":"019b...","timestamp":"2026-...","cwd":"/home/user/proj"}
{"type":"message","id":"a1b2c3d4","parentId":null,"timestamp":"...","message":{"role":"user","content":"hello"}}
{"type":"model_change","id":"..." ...}
{"type":"message","id":"..." ...}
```

管理位置：`~/.pi/agent/sessions/--home-user-proj--/2026-06-25T..._uuid.jsonl`

### 2.2 延迟刷盘策略

`_persist()` 方法的核心逻辑：

```
if 还没有 assistant 消息:
    if 已刷盘:
        逐行追加到文件
    else:
        标记未刷，暂不写 // 防止半截会话文件
    return

if 未刷盘:
    全量 dump 所有积累的 entries 到文件（open+write+close）
    标记已刷
else:
    逐行追加一行
```

**设计意图**：新会话在第一个 assistant 响应到达前不写文件。如果用户 Ctrl+C 退出，不会留下只有 user 消息的残缺 JSONL。第一个 assistant 到达时，批量 dump 此前所有积累（header + user + model_change + ...），之后切换到逐行追加模式。

### 2.3 版本迁移

会话格式有版本号（`SessionHeader.version`），当前为 v3：

| 版本 | 变更 |
|------|------|
| v1→v2 | 添加 `id`/`parentId` 树结构字段 |
| v2→v3 | `hookMessage` role 重命名为 `custom` |

加载时自动运行，迁移后 `_rewriteFile()` 全量重写。

---

## 三、Leaf 指针状态机：分支与追加

### 3.1 追加（append）—— 时间向前走

```typescript
private _appendEntry(entry: SessionEntry): void {
    this.fileEntries.push(entry);
    this.byId.set(entry.id, entry);
    this.leafId = entry.id;  // 指针前移
    this._persist(entry);
}
```

每次 `appendMessage()` / `appendModelChange()` / `appendCompaction()` 等调用：
1. 新 entry 的 `parentId` = `this.leafId`
2. 写入 `fileEntries` + `byId`
3. **leaf 前移** → 新 entry 成为 leaf

```
leaf = A  →  appendMessage(userMsg)  →  leaf = B (parentId = A)
         →  appendMessage(asstMsg)   →  leaf = C (parentId = B)
```

### 3.2 分支（branch）—— 指针回跳，历史不改

```typescript
branch(branchFromId: string): void {
    this.leafId = branchFromId;  // 只移动指针
}
```

**不修改任何已有 entry**。下一次 `appendXXX()` 时，新 entry 的 `parentId` = `branchFromId`。因为 `branchFromId` 已有 child（原有路径），新 child 形成**兄弟节点** → 分支产生。

```
        user1 (root)
       /          \
    asst_a       asst_b  ← 新分支（从 user1 branch 后追加）
    /    \
  user2  user3
```

### 3.3 带摘要的分支（branchWithSummary）

```typescript
branchWithSummary(branchFromId, summary, details?, fromHook?): string {
    this.leafId = branchFromId;
    const entry: BranchSummaryEntry = {
        parentId: branchFromId, summary,
        fromId: branchFromId ?? "root",  // 记录从哪个分支跳来
    };
    this._appendEntry(entry);  // leaf 移到 summary entry
    return entry.id;
}
```

在分支点插入一个 `branch_summary` entry，记录被放弃路径的摘要。下一次 append 将在摘要之后。

### 3.4 操作矩阵

| 操作 | 修改历史 | leaf 变化 | 磁盘写入 |
|------|---------|----------|---------|
| `appendMessage()` | 否（追加） | 前移 | 是 |
| `branch(id)` | 否 | 回跳 | **否** |
| `branchWithSummary(id)` | 否 | 回跳 + 追加 summary | 是 |
| `resetLeaf()` | 否 | 设为 null | 否 |

---

## 四、AgentSession：事件驱动的响应粒度管理

### 4.1 事件管线

AgentSession 通过 `agent.subscribe()` 监听 agent-core 的 AgentEvent 流：

```
agent-core (LLM 调用)
    ↓ AgentEvent 流
_handleAgentEvent()          ← AgentSession
    ├─ message_start        → 清理 steering/followUp 队列
    ├─ message_end          → 持久化 + auto-compaction 检查
    ├─ agent_end            → retry 判断 + compaction 触发
    └─ 所有事件             → 转发给 ExtensionRunner + TUI listeners
```

### 4.2 持久化触发点

**唯一的持久化时机是 `message_end`**。chunk 和 message_start 不持久化。

```
message_end:
  role === "user"      → sessionManager.appendMessage()
  role === "assistant" → sessionManager.appendMessage()
  role === "toolResult"→ sessionManager.appendMessage()
  role === "custom"    → sessionManager.appendCustomMessageEntry()
  bashExecution        → 在其他位置独立持久化
  compactionSummary    → 在其他位置独立持久化
```

### 4.3 一次 turn 的粒度拆分

一次典型的用户交互（"edit foo.ts"）的持久化粒度：

```
用户输入 "edit foo.ts"
  → appendMessage → entry(user, id=U1, parentId=prevLeaf)

LLM 第一轮（流式 chunks 不持久化，最终 message_end 持久化）:
  → appendMessage → entry(assistant, id=A1, parentId=U1)
     # 包含 content 数组 + toolCall: read foo.ts

LLM 第二轮:
  → appendMessage → entry(assistant, id=A2, parentId=A1)
     # toolCall: edit foo.ts

Tool 执行:
  → appendMessage → entry(toolResult, id=T1, parentId=A2)

LLM 第三轮:
  → appendMessage → entry(assistant, id=A3, parentId=T1)
     # text: "Done!"
```

最终 JSONL 中的树片段：

```json
{"id":"U1","parentId":"...","type":"message","message":{"role":"user","content":"edit foo.ts"}}
{"id":"A1","parentId":"U1","type":"message","message":{"role":"assistant","content":[...read toolCall...]}}
{"id":"A2","parentId":"A1","type":"message","message":{"role":"assistant","content":[...edit toolCall...]}}
{"id":"T1","parentId":"A2","type":"message","message":{"role":"toolResult",...}}
{"id":"A3","parentId":"T1","type":"message","message":{"role":"assistant","content":"Done!"}}
```

**每个 tool call 对应一个独立的 assistant message entry**。这意味着可以在任意 tool call 边界做 branch。

---

## 五、LLM Context 构建：路径化上下文组装

### 5.1 buildSessionContext 逻辑

```
1. 从 leafId 回溯到 root，收集 path 上的所有 entry
2. 遍历 path:
   - thinking_level_change → 提取 thinkingLevel
   - model_change / assistant.message → 提取当前 model
   - compaction → 记录压缩点
3. 构建 messages:
   - 如果有 compaction:
     a. 先 emit CompactionSummaryMessage（摘要作为系统消息）
     b. 从 firstKeptEntryId 开始保留 messages
     c. 继续 emit compaction 之后的 messages
   - 无 compaction → 顺序 emit 所有 messages
4. 同时处理 custom_message 和 branch_summary
```

**关键**：每次 branch 到不同节点后，LLM 上下文自动跟随该路径的状态（thinking 级别、model、压缩状态）。

### 5.2 Compaction 后的 context 重构

```
compaction 触发:
  ├─ 生成 summary
  ├─ sessionManager.appendCompaction(summary, firstKeptEntryId, tokensBefore)
  ├─ 重新 buildSessionContext()
  └─ agent.state.messages = sessionContext.messages
```

压缩后的 context = `[compactionSummary] + [firstKeptEntryId 之后的 messages]`

---

## 六、collectEntriesForBranchSummary：分支导航中的祖先计算

当用户导航到树中不同节点时，需要决定哪些 entries 需要摘要：

```typescript
function collectEntriesForBranchSummary(session, oldLeafId, targetId) {
  // 1. 构建 oldPath 和 targetPath
  // 2. 从 targetPath 末尾向前找 deepest common ancestor
  // 3. 从 oldLeafId 回溯到 commonAncestor，收集被放弃的 entries
  // 4. reverse 得到时间顺序
  return { entries, commonAncestorId };
}
```

被放弃路径的 entries 被送入 `generateBranchSummary()` → LLM 摘要 → `branchWithSummary()` → 成为新分支的第一个 child。

---

## 七、`/tree` TUI 组件的渲染层

### 7.1 触发入口

| 方式 | 代码路径 |
|------|---------|
| 输入 `/tree` + Enter | `onSubmit` 检测 `text === "/tree"` → `showTreeSelector()` |
| 双击 Escape（500ms 内） | `doubleEscapeAction === "tree"` → `showTreeSelector()` |
| keybinding `app.session.tree` | 可配置快捷键（默认无绑定） |
| navigateTree 回调中取消 | 重新 `showTreeSelector(previousSelectedId)` |

`doubleEscapeAction` 默认为 `"tree"`，可在 settings 中改为 `"fork"` 或 `"none"`。

默认 filter 为 `"default"`，可通过 `treeFilterMode` 设置变更。

### 7.2 组件树

```
TreeSelectorComponent (Container)
├── DynamicBorder      → 边框
├── TreeHelp           → 底部帮助栏（keybindings 提示）
├── SearchLine         → "Type to search: <query>"
├── TreeList           → 核心树组件
│   ├── 5 种过滤模式
│   ├── 实时搜索（逐字过滤）
│   ├── Fold/Unfold（⊞/⊟ 节点折叠）
│   └── 水平 viewport 滚动
└── LabelInput         → 标签编辑弹层（按需显示）
```

### 7.3 核心渲染算法

`TreeList` 的工作流程：

```
flattenTree(roots) → FlatNode[]
    ↓  (indent, showConnector, isLast, gutters, isVirtualRootChild)
applyFilter() → filteredNodes
    ↓  (过滤 + 搜索 + fold)
recalculateVisualStructure()
    ↓  (基于可见节点重建 indent/connector/gutter)
renderHorizontalViewport()
    ↓  (水平滚动：保持 gutter 可见 + 足够内容上下文)
输出: 每行包含 cursor(›/ ) + gutter(│├└) + fold 标记(⊞/⊟) + active path(•) + label + content
```

**flattenTree 的缩进规则**：
- 根级别：indent 0
- 单子链：不增加缩进（flat chains）
- 分支点（多子节点）及其第一代子节点：+1 indentation

这个规则使兄弟分支视觉上归组在一起，长链不会过度缩进。

### 7.4 过滤与搜索

| 模式 | 显示内容 | keybinding |
|------|---------|------------|
| `default` | 隐藏 settings/bookkeeping entries | `app.tree.filter.default` |
| `no-tools` | default 减去 toolResult | `app.tree.filter.noTools` |
| `user-only` | 仅 user messages | `app.tree.filter.userOnly` |
| `labeled-only` | 仅带 label 的 entries | `app.tree.filter.labeledOnly` |
| `all` | 全部 | `app.tree.filter.all` |

搜索：**增量式**——每键入一个字即过滤，`getSearchableText()` 提取每个 entry 的可搜索文本（role + content + label）。

### 7.5 Fold 机制

`foldedNodes: Set<string>`。一个节点可折叠的条件（`isFoldable`）：
- 在可见树中有 children
- 是根节点 **或** 其父节点有多个可见子节点（即它是 segment start）

折叠后子节点被过滤掉，视觉结构重新计算。默认不折叠任何节点。

---

## 八、完整闭合链路

```
触发 → showTreeSelector()
    │
    ├─ sessionManager.getTree() → SessionTreeNode[]
    ├─ settingsManager.getTreeFilterMode() → 初始 filter
    │
    ▼
TreeSelectorComponent
  └─ TreeList
      ├─ flattenTree() → FlatNode[]
      ├─ applyFilter() → filteredNodes
      ├─ buildActivePath() → 高亮当前路径
      └─ render() → 用户交互
           │
           ▼ 用户选中某个 entry
      onSelect(entryId)
           │
           ├─ 同 leaf → no-op
           └─ 不同 leaf:
               ├─ 询问 "Summarize?" (No/Yes/Custom prompt)
               │    └─ 取消 → 重新 showTreeSelector
               │
               ▼
          session.navigateTree(targetId, {summarize, customInstructions})
               │
               ├─ collectEntriesForBranchSummary(oldLeaf, target)
               │    └─ 计算被放弃分支 entries + commonAncestor
               ├─ 触发 session_before_tree 事件（扩展 hook）
               ├─ 可选: generateBranchSummary() via LLM
               ├─ sessionManager.branchWithSummary() 或 branch()
               │    └─ leaf 指针移动
               ├─ 可选: sessionManager.resetLeaf()（导航到根前）
               ├─ 触发 session_tree 事件
               ├─ agent.state.messages = buildSessionContext()
               │    └─ context 跟随新路径重建
               │
               ▼
          UI 刷新:
               ├─ chatContainer.clear()
               ├─ renderInitialMessages()
               └─ editor.setText()（如果是 user message）
```

---

## 关键文件索引

| 文件 | 职责 |
|------|------|
| `packages/coding-agent/src/core/session-manager.ts` | 数据模型、持久化、leaf 状态机、`getTree()`、`buildSessionContext()` |
| `packages/coding-agent/src/core/agent-session.ts` | 事件驱动管线、`_handleAgentEvent()`、`navigateTree()`、compaction 触发 |
| `packages/coding-agent/src/core/compaction/branch-summarization.ts` | `collectEntriesForBranchSummary()`、`generateBranchSummary()` |
| `packages/coding-agent/src/core/slash-commands.ts` | `/tree` 命令注册（第 32 行） |
| `packages/coding-agent/src/core/settings-manager.ts` | `doubleEscapeAction`、`treeFilterMode` 设置 |
| `packages/coding-agent/src/core/keybindings.ts` | `app.session.tree` action 定义（第 252 行） |
| `packages/coding-agent/src/modes/interactive/interactive-mode.ts` | `showTreeSelector()`、`/tree` onSubmit 处理、tree 组件生命周期管理 |
| `packages/coding-agent/src/modes/interactive/components/tree-selector.ts` | `TreeSelectorComponent`、`TreeList`、`flattenTree()`、过滤/搜索/fold/渲染 (~1387 行) |

---

<!-- Generated at 2026-06-25, repo: pi-earendil-works/pi-mono, branch: main, commit: b1cb85c840d4749b8effcf694e8a2c6a4e127ea0 -->
