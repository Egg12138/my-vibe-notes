# 从 OpenAI SDK 工具调用到 MCP：Agent 基础设施入门与进阶笔记

[toc]

**日期**: 2026-04-13  
**来源**: `/home/egg/playground/agents` 教学项目实践  
**类型**: 学习笔记 / 架构理解  
**相关技术**: OpenAI SDK, Tool Calling, DeepSeek OpenAI-compatible API, MCP, JSON-RPC, stdio transport, 状态管理

## 一句话总结

如果你刚开始学 agent，最容易混淆的是两件事：

1. **模型如何提出工具调用请求**
2. **工具如何以标准协议暴露给外部客户端**

前者是 `tool calling/function calling`，后者是 `MCP`。它们经常一起出现，但并不是一层东西。

## 给初学者的理解框架

### 1. Tool calling 到底是什么

很多人会误以为“模型会调用函数”。这句话不准确。

更准确的说法是：

- 你的应用先把工具定义告诉模型
- 模型输出一个结构化请求，说明它想调用哪个工具、参数是什么
- 真正执行工具的是你的应用
- 你的应用把结果再发回模型
- 模型基于工具结果继续推理或回复

所以，`tool calling` 本质上是：

**模型负责生成意图，应用负责执行意图。**

### 2. 为什么要先学本地工具调用，再学 MCP

因为 MCP 会引入额外复杂度：

- 协议
- 传输层
- capability negotiation
- tools/resources/prompts 分类
- 客户端与服务端的角色划分

如果还没理解最简单的本地闭环：

`模型请求 -> 本地执行 -> 结果回传`

那直接看 MCP，基本会把“协议问题”和“agent 控制流问题”混为一谈。

### 3. MCP 到底是什么

MCP 不是模型，也不是 agent 本身。

MCP 更像一个标准接口层，解决的是：

- 一个服务端如何暴露工具
- 一个客户端如何枚举和调用这些工具
- 如何暴露只读资源
- 如何暴露可复用 prompt 模板

所以可以把它理解成：

- `tool calling` 是应用和模型之间的约定
- `MCP` 是工具提供方和工具消费方之间的约定

## 这次实践做了什么

### 第一步：最小 OpenAI SDK 工具调用闭环

项目里实现了一个最小闭环：

1. 应用向模型发送请求
2. 模型先请求 `run_bash`
3. 本地代码解析请求并执行白名单 Bash 命令
4. 应用把 Bash 输出作为 `tool` 消息发回模型
5. 模型再请求 `read_file`
6. 本地代码读取文件并把内容回传
7. 模型基于两次工具结果给出最终说明

这里有几个关键工程点：

- 工具 schema 要清晰
- 参数必须解析和校验
- 工具执行必须有权限边界
- 工具返回值应该统一结构
- 整个流程应该设计成循环，而不是单次 if/else

### 第二步：本地 MCP Server

项目里又实现了一个本地 MCP Server，支持：

- `tools`
- `resources`
- `resource templates`
- `prompts`
- 本地 JSON 持久化状态
- 事件日志与统计信息

这个设计比“计算器 demo”更接近真实服务，因为它有状态，也有读写分离：

- `tools` 负责修改状态
- `resources` 负责读取状态
- `prompts` 负责把状态组织成更适合模型消费的输入

## 给进阶读者的架构拆解

### 1. 为什么第一步选 `chat.completions + tools`

从抽象上说，Responses API 更统一；但在 OpenAI-compatible 场景里，`chat.completions + tools` 的兼容性往往更稳。这个实践里使用 DeepSeek endpoint 跑通了 OpenAI SDK，所以第一阶段选择了兼容路径，而不是追求接口“新旧”的表面先进性。

这个决策说明一个重要工程原则：

**教学项目的第一优先级是建立稳定、可验证的最小闭环。**

### 2. 为什么 MCP Server 要单独做状态层

很多教程把业务逻辑直接塞在 MCP handler 里，这会导致：

- 协议层和业务层强耦合
- 难测
- 难迁移 transport
- 难做本地演示和未来扩展

这里把状态层独立为 `state/store.js`，再把它映射到 MCP 暴露层，这样你能得到：

- 更明确的边界
- 更稳定的测试对象
- 更容易扩展到 HTTP transport 或远程部署

### 3. 为什么 resources 和 tools 要区分

一个常见错误是把“读状态”也做成 tool。

这当然能工作，但语义不够清楚。

更合理的边界通常是：

- `tools`: 需要执行动作、可能有副作用
- `resources`: 暴露只读上下文
- `prompts`: 暴露模板化的高层输入组织

这样客户端在发现能力时，能更清楚地决定怎么用这些能力。

### 4. 为什么 demo 同时保留 stdio server 和 in-memory transport

真实本地 MCP 集成场景通常使用 `stdio`，所以服务端入口仍然应该保留。  
但在教学和自动验证时，`InMemoryTransport` 更稳定，因为它能把注意力集中在：

- 注册了什么能力
- 调用链是否正确
- 状态是否被正确修改和暴露

而不是卡在子进程生命周期或宿主环境 I/O 差异上。

这不是“偷懒”，而是把**协议验证**和**宿主环境验证**分层处理。

## 初学者最该记住的 5 件事

1. 模型不会真的执行工具，执行者永远是你的应用。
2. tool calling 是控制流问题，MCP 是协议问题。
3. 真正可扩展的 agent 系统，一定要有明确的权限边界。
4. tool、resource、prompt 三者职责不同，不要乱混。
5. 状态管理不是协议免费送你的能力，需要你自己设计。

## 推荐学习顺序

1. 先自己手写一个本地 tool loop
2. 再加入第二个工具，理解多轮循环
3. 再把工具抽象成统一 dispatcher
4. 再实现一个最小 MCP server
5. 再做“本地 tool + 远端 MCP tool”的统一 agent

最后这一步，才是真正开始接近可扩展 agent runtime。

## 这份笔记对应的项目产物

- `src/stage1/`: OpenAI SDK 工具调用闭环
- `src/mcp/`: 本地 MCP Server、状态层、SDK demo client
- `docs/teaching-plan.md`: 教学路线
- `docs/explanations/stage1-openai-tool-loop.md`: 第一阶段原理
- `docs/explanations/stage2-mcp-server.md`: 第二阶段原理

## 后续最值得做的第三步

把“应用内本地工具”和“MCP 动态发现的远端工具”统一到同一个 agent loop 中。  
一旦做完这一步，你就真正理解了现代 agent runtime 的核心骨架：

- 模型只产生结构化动作意图
- 应用统一调度多来源工具
- MCP 只是外部能力接入标准之一
- 本地 tool 和 MCP tool 在调度层应被统一对待

<!-- vibenotes-meta: repo=/home/egg/source/vibenotes branch=main commit=46552a0 generated_at=2026-04-13 00:36:00 CST -->
