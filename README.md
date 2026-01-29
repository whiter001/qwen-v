# Qwen-V Agent (Vlang)

一个基于 Vlang 开发的高性能 AI 智能体，支持 DashScope (Qwen) 模型及其原生的工具调用（Tool Use）能力，并集成了 MCP (Model Context Protocol) 协议以支持 Playwright 浏览器自动化。

## 特性

- **轻量高效**：使用 V 语言开发，编译速度极快，运行时内存占用极低。
- **工具集成**：
  - 文件系统：`read_file`, `write_file`, `list_directory`, `glob`。
  - 命令执行：`run_command`。
  - **Playwright 浏览器自动化**：通过 MCP 协议支持导航、快照、点击、输入、后退及自定义 JS 执行。
- **双模式运行**：
  - **CLI 模式**：标准的命令行交互界面。
  - **TUI 模式**：基于 `term.ui` 的终端图形界面，体验更佳。
- **智能重试与流控**：针对 DashScope 的 API 限制进行了优化，支持多轮工具调用。

## 安装与编译

### 前提条件

1.  安装 [V 语言](https://vlang.io/) 编译器。
2.  确保系统中已配置好 `qwen-code` 的 OAuth 登录凭证（位于 `~/.qwen/oauth_creds.json`）。

### 编译

在项目根目录下运行：

```bash
v . -o qwen_agent
```

## 使用说明

### 启动交互模式 (CLI)

```bash
./qwen_agent
```

### 启动终端图形模式 (TUI)

```bash
./qwen_agent --tui
```

### 单次任务模式

```bash
./qwen_agent -p "帮我列出当前目录下的所有 V 文件，并简要说明它们的功能。"
```

### 调试模式

如果需要查看 MCP 通信细节或 API 请求，可以添加 `--debug` 参数：

```bash
./qwen_agent --tui --debug
```

## 项目结构

- `qwen_agent.v`: 程序入口，负责命令行参数解析模式分发。
- `core/`: 核心逻辑包，包含模型通信、MCP 客户端实现、工具执行器。
- `tui_agent/`: 终端 UI 实现。
- `test_tools.vsh`: 工具集成测试脚本。

## 配置 MCP 工具

本项目支持读取 `~/.qwen/settings.json` 中的 MCP 服务器配置。例如，要启用 Playwright 支持，请确保配置文件中包含：

```json
{
  "mcpServers": {
    "playwright": {
      "command": "npx",
      "args": ["-y", "@playwright/mcp", "--browser", "chromium"],
      "env": {}
    }
  }
}
```

## 许可证

MIT License
