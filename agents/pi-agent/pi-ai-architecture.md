# PI AI Multi-Provider Architecture

## Table of Contents

- [Overview](#overview)
- [Core Design Principle: Unified Type System](#core-design-principle-unified-type-system)
- [Architecture Layers](#architecture-layers)
  - [1. Type System Layer](#1-type-system-layer)
  - [2. API Registry Layer](#2-api-registry-layer)
  - [3. Provider Implementation Layer](#3-provider-implementation-layer)
  - [4. Message Transformation Middleware](#4-message-transformation-middleware)
  - [5. Model Registry](#5-model-registry)
  - [6. Compatibility Layer](#6-compatibility-layer)
  - [7. Environment Variable Discovery](#7-environment-variable-discovery)
  - [8. Unified Reasoning (SimpleStream)](#8-unified-reasoning-simplestream)
- [Request Lifecycle (Deep Dive)](#request-lifecycle-deep-dive)
- [Cross-Provider Handoff Mechanism](#cross-provider-handoff-mechanism)
- [Compatibility Auto-Detection](#compatibility-auto-detection)
- [Adding a New Provider](#adding-a-new-provider)
- [Key Design Decisions](#key-design-decisions)
- [For Beginners: High-Level Analogy](#for-beginners-high-level-analogy)
- [For Experts: Architecture Tradeoffs](#for-experts-architecture-tradeoffs)

## Overview

`@earendil-works/pi-ai` is a **unified multi-provider LLM API** that abstracts across 20+ LLM providers (OpenAI, Anthropic, Google, xAI, Groq, DeepSeek, Mistral, Amazon Bedrock, etc.) behind a single, consistent interface. It handles:

- Request routing to the correct provider SDK/API
- Message format conversion (each provider has different wire formats)
- Streaming normalization (each provider emits different event shapes)
- Cross-provider context handoff (replay conversations across providers)
- Model discovery and cost tracking
- Authentication (env vars, OAuth, AWS/ADC)
- Reasoning/thinking level abstraction

The package lives in `packages/ai/` in the pi-mono repo and is used by both `@earendil-works/pi-agent-core` and the coding agent CLI.

## Core Design Principle: Unified Type System

The entire architecture is built around a **pi-native type system** that is provider-agnostic. Every provider:

1. **Reads** pi-native types (Model, Context, Message)
2. **Converts internally** to the provider's API format
3. **Streams back** pi-native event protocol (AssistantMessageEventStream)
4. **Returns** pi-native AssistantMessage

This means higher-level code (agent loop, CLI, tools) never touches provider-specific types.

## Architecture Layers

### 1. Type System Layer

**File**: `packages/ai/src/types.ts`

The foundational types that everything else builds on:

```typescript
// A model carries its API type (which determines routing)
interface Model<TApi extends Api> {
  id: string;          // "claude-sonnet-4-20250514"
  api: TApi;           // "anthropic-messages" ← THIS determines routing
  provider: Provider;  // "anthropic"
  baseUrl: string;     // API endpoint
  reasoning: boolean;  // Supports thinking/reasoning
  compat?: OpenAICompletionsCompat | OpenAIResponsesCompat | AnthropicMessagesCompat;
  cost: { input, output, cacheRead, cacheWrite };
  contextWindow: number;
  maxTokens: number;
}

// Context is the conversation container
interface Context {
  systemPrompt?: string;
  messages: Message[];  // UserMessage | AssistantMessage | ToolResultMessage
  tools?: Tool[];
}

// Messages use content blocks (text, thinking, toolCall, image)
type Message = UserMessage | AssistantMessage | ToolResultMessage;

// Streaming protocol with 12 event types
type AssistantMessageEvent =
  | { type: "start" }
  | { type: "text_delta"; delta: string; contentIndex: number }
  | { type: "thinking_delta"; delta: string; contentIndex: number }
  | { type: "toolcall_delta"; delta: string; contentIndex: number; partial: ... }
  | { type: "toolcall_end"; toolCall: ToolCall }
  | { type: "done"; reason: "stop" | "length" | "toolUse"; message: AssistantMessage }
  | { type: "error"; reason: "error" | "aborted"; error: AssistantMessage }
  // ... plus text_start, text_end, thinking_start, thinking_end, toolcall_start
```

The key insight: **the `api` field on `Model` is the routing key**. It's a discriminated union — the Model is generic over `TApi extends Api`, so TypeScript knows which stream options are valid for each model.

The `Api` type is an open union:

```typescript
type KnownApi =
  | "openai-completions"
  | "anthropic-messages"
  | "google-generative-ai"
  | "google-vertex"
  | "bedrock-converse-stream"
  | "mistral-conversations"
  | "openai-responses"
  | "azure-openai-responses"
  | "openai-codex-responses";
type Api = KnownApi | (string & {});  // Extensible
```

The `Provider` type (e.g. `"anthropic"`, `"xai"`, `"deepseek"`) is separate from `Api` because **different providers can share the same API protocol**. xAI, Groq, Cerebras, DeepSeek, Together AI all use `"openai-completions"`. This is a critical abstraction: the API determines the *wire format*, the provider determines the *brand/configuration*.

### 2. API Registry Layer

**File**: `packages/ai/src/api-registry.ts`

A simple global `Map<string, RegisteredApiProvider>` mapping API identifiers to their stream implementations:

```typescript
const apiProviderRegistry = new Map<string, RegisteredApiProvider>();

interface ApiProviderInternal {
  api: Api;
  stream: (model, context, options?) => AssistantMessageEventStream;
  streamSimple: (model, context, options?) => AssistantMessageEventStream;
}

export function registerApiProvider(provider, sourceId?) { ... }
export function getApiProvider(api): ApiProviderInternal | undefined { ... }
```

Registration happens at module load time in `register-builtins.ts`:

```typescript
registerApiProvider({ api: "anthropic-messages", stream: streamAnthropic, streamSimple: streamSimpleAnthropic });
registerApiProvider({ api: "openai-completions",  stream: streamOpenAICompletions, streamSimple: streamSimpleOpenAICompletions });
registerApiProvider({ api: "google-generative-ai", stream: streamGoogle, streamSimple: streamSimpleGoogle });
// ... 6 more
```

**Lazy loading**: Provider modules use dynamic `import()` so they're never loaded until first use. Each exported function is wrapped in `createLazyStream()` which catches load errors and emits them as stream errors.

### 3. Provider Implementation Layer

**Files**: `packages/ai/src/providers/{anthropic,openai-completions,google,mistral,...}.ts`

Each provider implementation exports two functions:

```typescript
export const streamAnthropic: StreamFunction<"anthropic-messages", AnthropicOptions> = (model, context, options?) => {
  // 1. Resolve API key
  // 2. Build provider-specific params (via convertMessages())
  // 3. Call SDK / HTTP
  // 4. Parse streaming response → emit pi-native events
  // 5. Return AssistantMessageEventStream
};
```

Each provider's `convertMessages()` is the **adaptation layer** — it translates pi-native `Message[]` into the provider's wire format. For example:

**Anthropic** (`anthropic.ts`):
- User messages with images → `{ type: "image", source: { type: "base64", media_type, data } }`
- Thinking blocks → `{ type: "thinking", thinking, signature }`
- Tool calls → `{ type: "tool_use", id, name, input }`
- Tool results → wrapped inside a `role: "user"` message with `{ type: "tool_result", tool_use_id, content }`
- Cache control added to last user message and system prompt

**OpenAI Completions** (`openai-completions.ts`):
- User messages → `role: "user"` with content (string or array)
- Images → `{ type: "image_url", image_url: { url: "data:...;base64,..." } }`
- Thinking blocks → mapped to `reasoning_content` or `reasoning` delta fields (or `requiresThinkingAsText`)
- Tool calls → `role: "assistant"` with `tool_calls: [{ id, type: "function", function: { name, arguments } }]`
- Tool results → `role: "tool"` with `tool_call_id` and `content`
- Tool results with images → extra `role: "user"` message with image attachments
- System prompt → `role: "developer"` (for reasoning models) or `role: "system"`
- Numerous `compat` switches for provider-specific behavior

**Google** (`google.ts`):
- Different content structure entirely (parts-based)
- Function declarations for tools
- Different streaming event format

All providers **share the same streaming normalization** — the event protocol maps each provider's specific events to pi-native events:
- Provider "text chunk" → `text_delta`
- Provider "reasoning chunk" → `thinking_delta`
- Provider "function_call chunk" → `toolcall_delta`
- Provider "stop" → `done`
- Provider "error" → `error`

### 4. Message Transformation Middleware

**File**: `packages/ai/src/providers/transform-messages.ts`

This is the **cross-cutting concern layer** that runs inside every provider's `convertMessages()`. It handles scenarios that occur when messages cross provider boundaries:

```
Input: Message[] (from any provider)
  │
  ├─ downgradeUnsupportedImages()  — Replace images with text for non-vision models
  │
  ├─ Thinking → text conversion    — Cross-provider: convert thinking blocks to <thinking> tags
  │
  ├─ Tool call ID normalization    — OpenAI's 450-char IDs → Anthropic-safe ^[a-zA-Z0-9_-]{1,64}$
  │
  ├─ Orphaned tool call handling   — Insert synthetic tool results for dangling calls
  │
  └─ Skip errored/aborted messages — Don't replay incomplete turns
  │
Output: Message[] (cleaned for target provider)
```

Key decisions per message block type:

| Source Block | Same Provider (replay) | Different Provider |
|---|---|---|
| `thinking` (with signature) | Keep as-is with signature | Convert to `{ type: "text", text: thinkingContent }` |
| `thinking` (redacted) | Keep with encrypted payload | Drop entirely |
| `toolCall` | Keep as-is | Normalize ID, strip thoughtSignature |
| `text` | Keep as-is | Keep as-is |

### 5. Model Registry

**File**: `packages/ai/src/models.ts` + `models.generated.ts`

A static two-level map populated from an auto-generated file:

```typescript
const modelRegistry = new Map<provider, Map<modelId, Model>>();

export function getModel(provider, modelId)    // "anthropic" + "claude-sonnet-4-20250514" → Model
export function getModels(provider)            // All models from a provider
export function getProviders()                 // All known provider names
```

The generated file contains ~200+ models with their api, pricing, context window, capabilities, and compat settings. The type system infers the API type from the model entry, giving IDE autocompletion:

```typescript
// TypeScript knows this is Model<"anthropic-messages">
const model = getModel("anthropic", "claude-sonnet-4-20250514");
// TypeScript knows this is Model<"openai-completions">
const deepseek = getModel("deepseek", "deepseek-chat");
```

Cost calculation is unified — all providers use the same `calculateCost(model, usage)` function.

### 6. Compatibility Layer

This is PI's answer to the fact that not all providers implement the same API the same way. Each model can carry `compat` settings:

**For OpenAI-compatible APIs** (`OpenAICompletionsCompat`):

| Field | Problem It Solves |
|---|---|
| `supportsStore` | Chutes/Cerebras reject `store: false` |
| `supportsDeveloperRole` | Some providers don't know `role: "developer"` |
| `supportsReasoningEffort` | xAI doesn't support `reasoning_effort` |
| `thinkingFormat` | DeepSeek uses `{thinking: {type}}`, zAI uses `{enable_thinking}`, OpenRouter uses `{reasoning: {effort}}`, Together uses `{reasoning: {enabled}}` |
| `maxTokensField` | Some use `max_tokens`, others use `max_completion_tokens` |
| `requiresToolResultName` | Some need `name` on tool results |
| `requiresAssistantAfterToolResult` | Some need an assistant message between tool results and user |
| `requiresThinkingAsText` | Convert thinking blocks to plain text |
| `cacheControlFormat` | Anthropic-style `cache_control` on OpenAI-compatible endpoints |
| `sendSessionAffinityHeaders` | Session affinity for cache routing |

**For Anthropic-compatible APIs** (`AnthropicMessagesCompat`):

| Field | Problem It Solves |
|---|---|
| `supportsEagerToolInputStreaming` | Fireworks doesn't support this beta |
| `supportsLongCacheRetention` | Fireworks doesn't support 1h cache TTL |
| `sendSessionAffinityHeaders` | Fireworks needs `x-session-affinity` for cache hits |
| `supportsTemperature` | Claude Opus 4.7+ rejects temperature when thinking is enabled |
| `forceAdaptiveThinking` | Some models require `{type: "adaptive"}` thinking format |

**Auto-detection** (`detectCompat` in `openai-completions.ts`): Checks `baseUrl` for known patterns:

```typescript
const isZai = baseUrl.includes("api.z.ai") || baseUrl.includes("open.bigmodel.cn");
const isTogether = baseUrl.includes("api.together.ai") || baseUrl.includes("api.together.xyz");
const isDeepSeek = baseUrl.includes("deepseek.com");
const isGrok = baseUrl.includes("api.x.ai");
// ...

// Then merges with explicit model.compat (if set)
return {
  supportsStore: !isNonStandard,
  thinkingFormat: isDeepSeek ? "deepseek" : isZai ? "zai" : isTogether ? "together" : isAntLing ? "ant-ling" : isOpenRouter ? "openrouter" : "openai",
  // ...
};
```

Explicit `model.compat` always overrides auto-detection, enabling custom proxies to declare their quirks.

### 7. Environment Variable Discovery

**File**: `packages/ai/src/env-api-keys.ts`

Maps every known provider to its authentication sources:

```typescript
const envMap = {
  openai: "OPENAI_API_KEY",
  anthropic: "ANTHROPIC_OAUTH_TOKEN" | "ANTHROPIC_API_KEY",  // OAuth takes precedence
  deepseek: "DEEPSEEK_API_KEY",
  xai: "XAI_API_KEY",
  "google-vertex": "GOOGLE_CLOUD_API_KEY" (+ ADC fallback: gcloud auth, service account JSON),
  "amazon-bedrock": AWS credential chain (profile, env vars, ECS, IRSA, bearer token),
  // ... 25+ more
};
```

The `env` option in stream/complete overrides `process.env` per-request — useful when one process needs different credentials per request.

### 8. Unified Reasoning (SimpleStream)

The `streamSimple` / `completeSimple` functions provide a **unified reasoning interface**:

```typescript
const response = await completeSimple(model, context, {
  reasoning: "medium"  // "minimal" | "low" | "medium" | "high" | "xhigh"
});
```

Each provider's `streamSimple` maps this to provider-specific params:

| Provider | reasoning: "high" maps to... |
|---|---|
| **Anthropic** (adaptive models) | `{ thinkingEnabled: true, effort: "high" }` |
| **Anthropic** (budget models) | `{ thinkingEnabled: true, thinkingBudgetTokens: 16384 }` |
| **OpenAI** | `{ reasoningEffort: "high" }` |
| **OpenRouter** | `{ reasoning: { effort: "high" } }` |
| **DeepSeek** | `{ thinking: { type: "enabled" }, reasoning_effort: "high" }` |
| **zAI** | `{ thinking: { type: "enabled" } }` |
| **Qwen** | `{ enable_thinking: true }` |
| **Together** | `{ reasoning: { enabled: true }, reasoning_effort: "high" }` |
| **Ant Ling** | `{ reasoning: { effort: "high" } }` (only if mapped) |

The model's `thinkingLevelMap` can override or disable specific levels per model:

```typescript
thinkingLevelMap: {
  minimal: null,    // disabled
  medium: "medium",
  high: "high",
  xhigh: "xhigh",   // mapped
}
```

## Request Lifecycle (Deep Dive)

Here's what happens when you call `stream(model, context)`:

```
1. stream.ts: getApiProvider(model.api)
   → Looks up "anthropic-messages" in the global registry
   → Returns { stream: streamAnthropic, streamSimple: streamSimpleAnthropic }

2. stream.ts: withEnvApiKey(model, options)
   → If no explicit apiKey, checks env vars: ANTHROPIC_OAUTH_TOKEN → ANTHROPIC_API_KEY
   → Also checks options.env for per-request overrides

3. register-builtins.ts: createLazyStream(loadAnthropicProviderModule)
   → First call: dynamic import("./anthropic.ts")
   → Returns outer AssistantMessageEventStream immediately
   → Provider loads in background

4. anthropic.ts: streamAnthropic(model, context, options)
   a. Create Anthropic SDK client (with auth, beta headers, session affinity)
   b. Build params:
      - convertMessages(context.messages)  ← calls transformMessages() first
      - Build system prompt with cache control
      - Build tools array
      - Configure thinking (adaptive or budget-based)
   c. Call client.messages.create(..., { stream: true })
   d. Iterate over SSE events:
      - message_start → capture usage, responseId
      - content_block_start → text/thinking/tool_use → emit text_start/thinking_start/toolcall_start
      - content_block_delta → text_delta/thinking_delta/input_json_delta → emit corresponding events
      - content_block_stop → emit text_end/thinking_end/toolcall_end
      - message_delta → update usage, stop reason
   e. Emit done or error event
   f. Return AssistantMessageEventStream

5. Consumer iterates over AssistantMessageEventStream
   → Gets unified text_delta, thinking_delta, toolcall_delta, done, error
   → Never touches Anthropic-specific types
```

## Cross-Provider Handoff Mechanism

PI supports **seamless mid-conversation provider switches**. The magic is in `transformMessages()`:

```typescript
// Start with Claude
const claude = getModel("anthropic", "claude-sonnet-4-20250514");
const r1 = await complete(claude, context, { thinkingEnabled: true });
context.messages.push(r1);

// Switch to GPT-5 — it sees Claude's thinking as <thinking> tagged text
const gpt = getModel("openai", "gpt-5-mini");
context.messages.push({ role: "user", content: "Continue..." });
const r2 = await complete(gpt, context);
```

What happens during the handoff:

1. Claude's `AssistantMessage` has `api: "anthropic-messages"`, `provider: "anthropic"`
2. When routed to OpenAI, `transformMessages()` sees `provider !== model.provider`
3. Thinking blocks → converted to `{ type: "text", text: thinkingContent }`
4. Tool call IDs → normalized from OpenAI format to Anthropic-safe format (if going the other way)
5. Redacted thinking → dropped (encrypted payload is provider-specific)
6. Errored/aborted messages → skipped entirely

**Tool call ID normalization** is bidirectional:

```
OpenAI Responses: "call_abc|def...450chars...=="
  → Anthropic (via normalizeToolCallId): "call_abc_def..." (max 64 chars, only [a-zA-Z0-9_-])

Anthropic: "toolu_abc123"
  → OpenAI: passed through (already compatible)
```

## Compatibility Auto-Detection

The `detectCompat()` function in `openai-completions.ts` handles the messy reality of "OpenAI-compatible" being a spectrum:

| baseUrl Pattern | Behavior Changes |
|---|---|
| `api.x.ai` (xAI/Grok) | No `supportsReasoningEffort`, no `developer` role |
| `api.deepseek.com` | Uses `thinking: {type}` format, requires empty `reasoning_content` on replayed assistants |
| `api.z.ai` / `open.bigmodel.cn` (zAI) | Uses `thinking: {type}` format, different tool stream behavior |
| `api.together.ai` | Uses `reasoning: {enabled}` format, `max_tokens` field, limited cache |
| `integrate.api.nvidia.com` | Uses `max_tokens`, limited cache, no `developer` role |
| `api.moonshot.` | Uses `max_tokens`, no reasoning |
| `api.ant-ling.com` | Uses `max_tokens`, no reasoning effort, `ant-ling` thinking format |
| `api.cloudflare.com` (Workers AI) | Limited cache |
| `gateway.ai.cloudflare.com` | Limited cache, no `developer` role |
| OpenRouter `anthropic/` models | Anthropic cache control format on OpenAI-compatible API |
| Custom/LiteLLM proxy | Falls back to conservative defaults unless `model.compat` is set |

## Adding a New Provider

The codebase has a documented checklist in `packages/ai/README.md` under "Development → Adding a New Provider". The key steps:

1. **types.ts**: Add API identifier to `KnownApi`, provider name to `KnownProvider`
2. **providers/**: Create file with `stream()` and `streamSimple()` functions
3. **register-builtins.ts**: Register with `registerApiProvider()`, add lazy loader
4. **env-api-keys.ts**: Map provider to env var name
5. **generate-models.ts**: Add model data fetching logic
6. **Tests**: Add provider to stream, tokens, abort, cross-provider-handoff tests
7. **Changelog**: Document the addition

## Key Design Decisions

1. **API as routing key, not provider**: Multiple providers share the same API type (`openai-completions` serves xAI, Groq, DeepSeek, etc.). This maximizes code reuse.

2. **Lazy loading**: Provider modules are `import()`-ed on first use. Keeps startup fast and enables tree-shaking.

3. **Stream events as discriminated union**: The 12-event protocol gives consumers fine-grained control (progressive rendering of tool arguments, real-time thinking display) while being fully typed.

4. **`streamSimple` as convenience layer**: Separates the complexity of provider-specific options from the common case of "I just want reasoning at this level."

5. **Compatibility as data, not code**: Each model carries its `compat` settings. No if/else chains per provider — just data-driven behavior. Auto-detection with explicit override.

6. **Messages carry their provenance**: `AssistantMessage.api` and `AssistantMessage.provider` enable the cross-provider transformation logic to make smart decisions about what to keep vs. convert vs. drop.

## For Beginners: High-Level Analogy

Think of `@earendil-works/pi-ai` as a **universal power adapter** for LLM providers:

- **Each LLM provider** (OpenAI, Anthropic, Google) is like a different country's electrical socket — different shapes, voltages, frequencies
- **The pi-native types** are like a universal plug shape — your device (agent, CLI) only needs one interface
- **Each provider implementation** is an adapter that converts between the universal plug and the local socket
- **The API registry** is the panel where you plug in your adapters
- **`compat` settings** handle regional quirks (like a switch for 110V vs 220V)
- **`transformMessages()`** is like a signal converter — when replaying a recording made in one country on another country's equipment

You plug your device into the universal plug (`stream(model, context)`), and PI automatically routes it through the right adapter to the right socket.

## For Experts: Architecture Tradeoffs

**Type-safe generics vs. Runtime flexibility**: The `Model<TApi>` generic provides excellent TypeScript DX (autocomplete for provider-specific options) but requires careful type gymnastics in the registry layer where types are erased. The `wrapStream()`/`wrapStreamSimple()` wrappers in `api-registry.ts` perform runtime type assertions (`model.api !== api`) to catch mismatches.

**Static model registry vs. Dynamic discovery**: Models are statically defined in `models.generated.ts`. This enables full tree-shaking and excellent autocomplete, but models can't be discovered at runtime from the provider's API. For most use cases (known model IDs) this is fine; custom models can be defined inline.

**Stream-first design**: Everything is built around streaming, even `complete()` which just gathers stream events into a final message. This means non-streaming responses have overhead, but it ensures consistent behavior across all paths. The `toolcall_delta` with partial JSON parsing is particularly clever — consumers can render progressive UI updates before the full tool arguments arrive.

**Global mutable registry**: The `apiProviderRegistry` is a module-level mutable map. This is simple but means all tests share state (handled by `resetApiProviders()`/`clearApiProviders()`). The `sourceId` parameter on `registerApiProvider()` allows bulk unregistration for tests.

**No provider-level abstraction**: The library doesn't define a provider interface that every provider must implement. Instead, each provider exports bare functions that happen to match the `StreamFunction` type signature. This is more flexible (providers can have different internal structures) but means the registry wrapping code must normalize them.

**Compat as merged config**: Auto-detected defaults + explicit overrides = final config. This avoids both "too opinionated" (hardcoding every provider's quirks) and "too manual" (requiring every user to configure everything). The merge happens at call time, not model load time, so env-dependent settings work correctly.

---

*Note based on pi-mono commit 6d5ede31 (master branch), 2026-06-18*
