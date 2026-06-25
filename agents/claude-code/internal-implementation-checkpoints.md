# claw-code 内部实现细节检查

[toc]

## 这个检查点覆盖什么

本次分析覆盖 claw-code Rust 代码库中几个关键子系统的当前实现状态和限制。与前两篇侧重"架构"和"路由"不同，这篇关注的是：

1. API 请求中的 `reasoning_effort` 怎么填的
2. 文件工具（Read/Write/Edit）的 diff 和 whitespace 处理
3. 对话 token 怎么算的
5. Settings.json 的 `env` 字段实际上不起作用
6. Model context window 限制硬编码在哪里

---

## 1. reasoning_effort：只走 OpenAI，值硬编码 low/medium/high

**定义位置**：`rust/crates/api/src/types.rs:33` — `Option<String>`，不是 enum
**发送位置**：`rust/crates/api/src/providers/openai_compat.rs:921-924`
**Anthropic 路径**：根本不发这个字段（`None` 时 `skip_serializing_if` 跳过）

### 当前限制

- 值的集合 `"low" | "medium" | "high"` 在 CLI flag 解析处硬编码验证（`main.rs:714-728`）
- 不做任何模型 → effort 值映射
- 比如某个模型只接受 `"xHigh"` / `"Max"`，当前代码不会做转换，只能透传
- Agent TOML 配置可通过 `model_reasoning_effort` 字段设置，但**不做值校验**

---

## 2. Token 估算：三种机制，精度不同

| 方式 | 公式 | 位置 | 用途 |
|------|------|-----|------|
| 启发式估算 | `byte_len / 4 + 1` | `compact.rs:36` | `/status` 显示、是否触发 compact |
| 预检估算 | 序列化 JSON 的 `byte_len / 4 + 1` | `providers/mod.rs:322` | 发请求前检查是否超限 |
| API 实际值 | 来自 API 响应 `Usage` 字段 | `types.rs:167` | cumulative 累计 |

**没有使用任何模型的真实 tokenizer。** `byte/4` 只是一个粗略近似。

---

## 4. Model context window 阈值：硬编码只有 4 个系列

**仅有的注册表**：`rust/crates/api/src/providers/mod.rs:277-299`

| 模型 | context_window_tokens | max_output_tokens |
|-----|---------------------|------------------|
| claude-opus-4-6 | 200,000 | 32,000 |
| claude-sonnet-4-6 | 200,000 | 64,000 |
| claude-haiku-4-5-20251213 | 200,000 | 64,000 |
| grok-3 / grok-3-mini | 131,072 | 64,000 |
| kimi-k2.5 / kimi-k1.5 | 256,000 | 16,384 |
| 所有其他模型 | **None（跳过检查）** | opus 含 → 32k / else → 64k |

### 核心问题

对于第三方模型（如 deepseek、qwen、本地模型），`model_token_limit()` 返回 `None`，`preflight_message_request()` 在 `mod.rs:303` 直接 `return Ok(())` 跳过全部检查。所以：
- 没有上下文窗口限制
- 没有超限报错
- max_output_tokens 回退到 64k 硬编码

**没有配置驱动的方式添加模型上下文窗口值。** 必须改源码。

---

## 5. Settings.json 的 `env` 字段：只存不用

**加载**：`env` 作为普通 JSON 对象读入 `RuntimeConfig.merged`（`BTreeMap<String, JsonValue>`），与其他字段做 deep merge
**使用**：**从未被注入到进程环境变量**。没有任何代码遍历 `env` 的 k-v 并调用 `std::env::set_var()`

### 验证

- `RuntimeFeatureConfig` 结构体（`config.rs:56`）没有 `env` 字段
- `env` 的唯一用途是 `claw config env` 的纯展示性输出（`main.rs:5943`）
- `ANTHROPIC_BASE_URL` 的真正来源：`std::env::var("ANTHROPIC_BASE_URL")`（`anthropic.rs:766`）
- 同理 `ANTHROPIC_MODEL`：从 `std::env::var()` 读，或从 settings.json 的顶层 `"model"` 字段读（不是 `env` 里）

### 实际效果

```json
// settings.json 里写这个 → 没效果
{ "env": { "ANTHROPIC_BASE_URL": "https://..." } }

// 必须设 OS 环境变量或通过顶层字段
{ "model": "claude-opus-4-6" }  // ← 这个有效
```

---

## 6. Model 选择优先级链

`main.rs:116-147`：

```
1. --model CLI 参数          → ModelSource::Flag
2. ANTHROPIC_MODEL 环境变量  → ModelSource::Env
3. settings.json 的 model 字段 → ModelSource::Config
4. 编译默认值 "claude-opus-4-6" → ModelSource::Default
```

Provider 判定后续 `detect_provider_kind()`（`mod.rs:223`）：模型名前缀匹配 → env 变量 → 最终回退 Anthropic。

---

## 7. Read/Write/Edit 工具实现分析

### input_schema（定义在 `tools/src/lib.rs:409-452`）

| 工具 | 参数 |
|-----|------|
| read_file | path(必填), offset(可选行号), limit(可选行数) |
| write_file | path(必填), content(必填) |
| edit_file | path(必填), old_string(必填), new_string(必填), replace_all(可选bool) |

### 执行链路

```
模型 ToolUse
  → CliToolExecutor::execute()          (allowed_tools 过滤)
    → GlobalToolRegistry::execute()     (路由到内置工具)
      → execute_tool_with_enforcer()    (权限检查 + 大 match)
        → run_read_file / run_write_file / run_edit_file
          → file_ops.rs 核心逻辑
          → to_pretty_json 序列化为 JSON 字符串返回
```

### diff/make_patch 目前是占位实现

**`file_ops.rs:518-534`** 的 `make_patch()`：

```rust
fn make_patch(original: &str, updated: &str) -> Vec<StructuredPatchHunk> {
    // 只是把所有旧行加 -，所有新行加 +，然后放一个 hunk 里
    // 不是真正的 diff 算法
}
```

- **不是真正的 diff**：没有 Myers diff 或任何差异比较，只是拼接全部旧行+全部新行
- 行号：`old_start=1, new_start=1`（永远是 1）
- `git_diff` 字段始终是 `None`
- 数据结构 `StructuredPatchHunk` 正确（`old_start, old_lines, new_start, new_lines, lines`），但填充数据不对

### Whitespace 处理

`edit_file` 的匹配（`file_ops.rs:272`）：

```rust
if !original_file.contains(old_string) {  // 精确字节匹配
    return Err("old_string not found in file");
}
```

- 使用 `str::contains()` + `str::replacen()`：字节级精确匹配
- 空格 vs Tab → 必须完全一致
- 行尾空格 → 必须完全一致
- 换行符 `\n` vs `\r\n` → 必须完全一致
- 模型从 JSON read_file 输出中解析内容时若有细微偏差，edit 就会失败

### 结果以 JSON 字符串形式返回

所有工具输出通过 `to_pretty_json()` 序列化为 JSON，然后作为 `ToolResult { content: [Text { text }], is_error }` 送回 API。serde_json 自动处理特殊字符转义，不存在 JSON 注入风险。

---

## 8. Subagent/Agent 机制

### Tool 定义（`tools/src/lib.rs:571`）

```rust
input_schema: {
    "description": "string (必填)",
    "prompt":       "string (必填)",
    "subagent_type":"string (可选，决定工具集)",
    "name":         "string (可选)",
    "model":        "string (可选，默认 opus)"
}
```

### 执行模型

1. 主模型调用 `Agent` 工具
2. 系统构建独立的 `ConversationRuntime` + 独立 `Session` + 裁剪的 `allowed_tools`
3. 在**新 OS 线程**中 `catch_unwind` 运行
4. 固定 `ToolChoice::Auto`，最多 32 轮对话
5. 写回 `.clawd-agents/` 目录的 manifest.json + result.md

### 工具权限

- `Explore`：只读（read, glob, grep, web）
- `Plan`：只读 + TodoWrite, SendUserMessage
- `Verification`：读写 + bash
- `general-purpose`（默认）：全部工具
- **所有类型都不能递归创建 subagent**（`Agent` 工具不在 allowed_tools 中）

---

## 关于代码位置

- `rust/crates/tools/src/lib.rs` — 工具定义、dispatch、权限
- `rust/crates/runtime/src/file_ops.rs` — Read/Write/Edit 核心逻辑
- `rust/crates/runtime/src/compact.rs` — 对话压缩
- `rust/crates/runtime/src/config.rs` — 设置加载和 deep merge
- `rust/crates/runtime/src/conversation.rs` — ConversationRuntime 和 tool 执行循环
- `rust/crates/api/src/providers/mod.rs` — 模型注册表和 preflight 检查
- `rust/crates/api/src/types.rs` — API 请求/响应类型
- `rust/crates/rusty-claude-cli/src/main.rs` — CLI 入口，slash commands，token 计算

---

*Version: main@a389f8d | 2026-04-27*
