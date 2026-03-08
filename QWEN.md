# Qwen-V Agent (Vlang) - Project Context

## 项目概述

**Qwen-V Agent** 是一个基于 [V 语言](https://vlang.io/) 开发的高性能 AI 智能体，支持 DashScope (Qwen) 模型及其原生的工具调用（Tool Use）能力，并集成了 MCP (Model Context Protocol) 协议以支持 Playwright 浏览器自动化。

### 核心特性

- **轻量高效**：使用 V 语言开发，编译速度极快，运行时内存占用极低
- **工具集成**：
  - 文件系统操作：`read_file`, `write_file`, `list_directory`, `glob`
  - 命令执行：`run_command`
  - **Playwright 浏览器自动化**：通过 MCP 协议支持导航、快照、点击、输入、后退及自定义 JS 执行
- **双模式运行**：
  - **CLI 模式**：标准的命令行交互界面
  - **TUI 模式**：基于 `term.ui` 的终端图形界面
- **智能重试与流控**：针对 DashScope 的 API 限制进行了优化，支持多轮工具调用
- **计划模式**：`--plan` 参数可拦截所有修改操作，仅用于分析和规划

## 项目结构

```text
qwen-v/
├── qwen_agent.v          # 程序入口，负责命令行参数解析和模式分发
├── core/
│   └── core.v            # 核心逻辑包：模型通信、MCP 客户端、工具执行器
├── tui_agent/
│   └── tui_agent.v       # 终端 UI 实现（基于 term.ui）
├── test_tools.vsh        # 工具集成测试脚本
├── examples/             # 示例配置文件
└── QWEN.md               # 项目上下文文档（本文件）
```

## 构建与运行

### 前提条件

1. 安装 [V 语言](https://vlang.io/) 编译器
2. 确保系统中已配置好 `qwen-code` 的 OAuth 登录凭证（位于 `~/.qwen/oauth_creds.json`）

### 编译

```bash
# 使用构建脚本（推荐）
./build.sh

# 或手动编译
v . -o qwen_agent
```

### 运行模式

| 模式     | 命令                                | 说明                         |
| -------- | ----------------------------------- | ---------------------------- |
| CLI 交互 | `./qwen_agent`                      | 标准命令行交互               |
| TUI 界面 | `./qwen_agent --tui`                | 终端图形界面                 |
| 单次任务 | `./qwen_agent -p "任务描述"`        | 执行单次任务后退出           |
| 计划模式 | `./qwen_agent --plan`               | 拦截修改操作，仅分析         |
| 调试模式 | `./qwen_agent --debug`              | 输出 MCP 通信和 API 请求细节 |
| 组合使用 | `./qwen_agent --tui --debug --plan` | 多参数组合                   |

## 开发约定

### 代码风格

- **模块组织**：每个模块放在独立目录中（如 `core/`, `tui_agent/`）
- **命名规范**：
  - 文件/模块：`snake_case.v`
  - 结构体：`PascalCase`
  - 函数：`snake_case`
  - 公开导出：使用 `pub` 关键字
- **错误处理**：使用 V 的 `!` 错误返回和 `or { }` 处理模式
- **代码格式化**：
  - **V 代码**：所有 V 代码必须通过 `v fmt` 格式化
    - 格式化单个文件：`v fmt <file.v>`
    - 格式化整个项目：`v fmt .` 或 `./fmt.sh`
  - **Markdown 文档**：所有 Markdown 文件必须通过 `oxfmt` 格式化
    - 格式化单个文件：`oxfmt <file.md>`
    - 格式化整个项目：`oxfmt .` 或 `./fmt.sh`
  - 提交前请确保代码和文档已通过格式化检查

### 工具实现规范

1. **工具定义**：在 `get_available_tools()` 中定义所有可用工具
2. **工具执行**：在 `execute_tool()` 中实现具体逻辑
3. **MCP 工具**：通过 `mcp_clients` 动态加载外部 MCP 服务器的工具

### MCP 配置

项目读取 `~/.qwen/settings.json` 中的 MCP 服务器配置。示例：

```json
{
  "mcpServers": {
    "playwright": {
      "type": "stdio",
      "command": "/Users/byf/.local/bin/pnpm",
      "args": ["dlx", "@playwright/mcp", "--extension", "--browser", "chrome"],
      "env": {
        "PLAYWRIGHT_MCP_EXTENSION_TOKEN": "your-token-here"
      }
    }
  }
}
```

### 测试实践

- 使用 `test_tools.vsh` 脚本进行工具集成测试
- 测试覆盖：`list_directory`, `read_file`, `write_file`, `delete_file` 等基础工具

## API 端点

- **默认端点**：`https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions`
- **模型**：`coder-model`
- **认证**：OAuth Bearer Token（从 `~/.qwen/oauth_creds.json` 读取）

## 支持的工具

### 内置工具

| 工具名           | 描述                     |
| ---------------- | ------------------------ |
| `read_file`      | 读取指定文件的内容       |
| `write_file`     | 写入内容到文件           |
| `list_directory` | 列出目录下的文件         |
| `glob`           | 查找匹配 glob 模式的文件 |
| `run_command`    | 执行 shell 命令          |

### Playwright 工具（通过 MCP）

| 工具名                | 描述                  |
| --------------------- | --------------------- |
| `playwright_navigate` | 导航到指定 URL        |
| `playwright_snapshot` | 获取页面屏幕快照/文本 |
| `playwright_click`    | 点击页面上的元素      |
| `playwright_type`     | 在元素中输入文本      |
| `playwright_back`     | 返回上一页            |
| `playwright_evaluate` | 执行自定义 JavaScript |

## 调试技巧

1. **启用调试模式**：添加 `--debug` 参数查看 MCP 通信细节
2. **查看 stderr 输出**：MCP 服务器的 stderr 输出会在调试模式下打印
3. **检查 OAuth 凭证**：确保 `~/.qwen/oauth_creds.json` 存在且未过期
4. **验证 MCP 配置**：检查 `~/.qwen/settings.json` 中的服务器配置

## 常见问题

### Q: 如何添加新的 MCP 服务器？

A: 在 `~/.qwen/settings.json` 中添加新的 `mcpServers` 配置项，重启 agent 即可。

### Q: Playwright 工具无法使用？

A: 确保已安装 Playwright MCP 服务器，并正确配置了 `PLAYWRIGHT_MCP_EXTENSION_TOKEN`。

### Q: 如何在计划模式下测试修改操作？

A: 计划模式会拦截所有修改操作。去掉 `--plan` 参数即可执行实际操作。

## 许可证

MIT License
