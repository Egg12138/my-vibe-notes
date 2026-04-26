# Claude Code 扩展机制：Skills、Plugins 与 Slash Commands

## [toc]

- [概述](#概述)
- [Beginner](#beginner)
  - [Skill 是什么？](#skill-是什么)
  - [Plugin 是什么？](#plugin-是什么)
  - [Slash Command 是什么？](#slash-command-是什么)
  - [三者的关系](#三者的关系)
- [Expert](#expert)
  - [Skill 的预加载与触发机制](#skill-的预加载与触发机制)
  - [Plugin 的内部结构](#plugin-的内部结构)
  - [命名空间与冲突避免](#命名空间与冲突避免)
  - [加载优先级与覆盖规则](#加载优先级与覆盖规则)
  - [Skill 类型：Bundled vs Custom vs Plugin](#skill-类型bundled-vs-custom-vs-plugin)
  - [配置字段对触发行为的影响](#配置字段对触发行为的影响)

## 概述

Claude Code 提供了一套多层扩展体系，允许用户和第三方开发者通过 **Skills（技能）**、**Plugins（插件）** 和 **Slash Commands（斜杠命令）** 来定制和扩展 CLI 功能。理解这些概念的区分与协作方式是有效使用 Claude Code 的前提。

## Beginner

### Skill 是什么？

Skill 是一个由 `SKILL.md` 文件定义的**提示词扩展**。它包含 YAML 格式的元信息（frontmatter）和 Markdown 格式的指令文本。Claude 加载 Skill 后按照指令执行任务。

Skill 的本质是一份**剧本（playbook）**，告诉 Claude 如何完成特定任务。

你可以把 Skill 理解为一个"可复用的指令模板"——写好一次，以后通过 `/name` 随时调用。

### Plugin 是什么？

Plugin 是一个**分发包（distribution package）**，用 `plugin.json` 清单文件描述。它不是单一功能，而是**多种组件的容器**。一个 Plugin 可以包含 Skills、Agents、Hooks、MCP Servers 等。

Plugin 的目录结构：

```
my-plugin/
  .claude-plugin/
    plugin.json          # 清单文件
  skills/                # → /my-plugin:skill-name
  agents/                # 自定义子代理
  hooks/                 # 事件驱动自动化
  .mcp.json              # MCP 服务器配置
  settings.json          # 默认设置
```

### Slash Command 是什么？

Slash Command 是你在 Claude Code 中输入 `/name` 时触发的任何东西。它是**用户入口的统一名称**。根据底层实现，Slash Command 可以分为：

- **内置命令**：`/help`、`/clear`、`/compact`、`/model` —— 硬编码行为，不调用 Claude 智能
- **Bundled Skill 命令**：`/simplify`、`/batch`、`/debug` —— 随 Claude Code 发布的基于提示词的 Skill
- **自定义 Skill 命令**：`.claude/skills/` 或 `~/.claude/skills/` 中定义的 Skill

### 三者的关系

```
Slash Command (/name or /plugin:name)
    ├── 内置硬编码如 /help、/clear
    └── Prompt-based (Skill)
         ├── Bundled：/simplify、/batch、/debug
         └── Custom
              ├── 独立（项目/个人目录）→ /name
              └── 插件内              → /plugin:name
```

**区别一句话总结**：
- **Slash Command** 是用户视角的入口名称，是个统称
- **Skill** 是底层实现机制（SKILL.md）
- **Plugin** 是分发包，作为一个容器分发多个组件

## Expert

### Skill 的预加载与触发机制

Skill 不是一次性全部加载到 LLM 上下文中的。Claude Code 在启动时扫描文件系统发现 Skill，但只加载**描述**到系统提示词中（description + when_to_use，截断到约 1536 字符）。完整内容仅在激活时才注入对话。

三种触发方式：

1. **Skill 工具（模型自主调用）**：系统提示词的描述列表中，Claude 根据请求判断匹配后调用 `Skill` 工具
2. **斜杠命令（用户手动调用）**：输入 `/name` 立即触发，支持参数传递
3. **动态上下文注入**：Skill 文本中的 `` !`command` `` 代码块在激活前执行，输出预渲染到 Skill 文本中

上下文生命周期：
- **激活时**：渲染后的 `SKILL.md` 作为单条消息注入对话
- **压缩时**：按 token 预算（激活中的 Skill 5000 token，总上限 25000）携带 Skill 前进，最早调用的最早被丢弃

### Plugin 的内部结构

一个完整的 Plugin 可以包含：

| 组件 | 路径 | 入口方式 |
|------|------|----------|
| Skills | `skills/` | `/plugin:skill` 斜杠命令或模型自动触发 |
| Commands（旧格式） | `commands/` | `/plugin:command` 斜杠命令 |
| Agents | `agents/` | 子代理自动调用或 `/agent` |
| Hooks | `hooks/hooks.json` | 事件驱动，无斜杠入口 |
| MCP 服务器 | `.mcp.json` | 通过 MCP 协议注入工具 |
| LSP 服务器 | `.lsp.json` | 语言智能支持 |
| 默认设置 | `settings.json` | 启用 Plugin 时自动应用 |
| 二进制脚本 | `bin/` | 添加到 PATH |

### 命名空间与冲突避免

Plugin 提供的 Skill 使用冒号语法 `/plugin-name:skill-name` 避免命名冲突：

- 独立 Skill：`/deploy`
- Plugin Skill：`/my-plugin:deploy`

这一机制使多个 Plugin 可以定义同名 Skill（如 `deploy`）而不会冲突。

Claude Code Skills 来源层级（从高到低）：

| 层级 | 路径 | 说明 |
|------|------|------|
| 企业 | 托管设置管理 | 全组织范围 |
| 个人 | `~/.claude/skills/<name>/SKILL.md` | 跨项目 |
| 项目 | `.claude/skills/<name>/SKILL.md` | 当前项目 |
| 插件 | `<plugin>/skills/<name>/SKILL.md` | 启用插件后可用 |
| 嵌套目录 | `packages/frontend/.claude/skills/` | monorepo 子目录 |

同名 Skill 高优先级覆盖低优先级。

### Skill 类型：Bundled vs Custom vs Plugin

| 特征 | Bundled | Custom（独立） | Custom（插件内） |
|------|---------|---------------|-----------------|
| 来源 | 随 Claude Code 发布 | 用户编写 | 插件提供 |
| 存放位置 | 内置 | `.claude/skills/` 或 `~/.claude/skills/` | `<plugin>/skills/` |
| 调用方式 | `/name` | `/name` | `/plugin:name` |
| 模型自动调用 | 是 | 是（除非 disable-model-invocation） | 是 |

### 配置字段对触发行为的影响

Skill 的 YAML frontmatter 中有几个关键字段控制触发：

- `disable-model-invocation: true`：Claude 不会自主加载此 Skill，仅限 `/name` 手动调用。描述不会出现在系统提示词中
- `user-invocable: false`：从 `/` 菜单隐藏，仅限模型自动调用
- `paths`：仅当 Claude 正在处理匹配这些 glob 模式的文件时才会触发
- `allowed-tools`：Skill 激活后可直接使用的工具，无需用户审批
- `context: fork`：在隔离的子代理中执行 Skill 内容，与主会话历史隔离

---

*Version: main@a389f8d | 2026-04-27*
