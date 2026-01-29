module main

import net.http
import json
import os
import time
import readline
import regex

// --- Qwen OAuth 凭证结构 ---

struct QwenCredentials {
pub mut:
	access_token  string @[json: 'access_token']
	refresh_token string @[json: 'refresh_token']
	token_type    string @[json: 'token_type']
	resource_url  string @[json: 'resource_url']
	expiry_date   i64    @[json: 'expiry_date']
}

fn get_qwen_creds_path() string {
	return os.join_path(os.home_dir(), '.qwen', 'oauth_creds.json')
}

fn load_qwen_creds() !QwenCredentials {
	path := get_qwen_creds_path()
	if !os.exists(path) {
		return error('未找到 Qwen 凭证文件: ${path}。请先使用 qwen-code 登录。')
	}
	content := os.read_file(path)!
	creds := json.decode(QwenCredentials, content) or {
		return error('解析凭证文件失败: ${err.msg()}')
	}
	return creds
}

// --- OpenAI / DashScope 兼容接口结构 ---

struct Property {
pub:
	type_       string @[json: 'type']
	description string @[json: 'description']
}

struct Schema {
pub:
	type_      string              @[json: 'type']
	properties map[string]Property @[json: 'properties']
	required   []string            @[json: 'required']
}

struct FunctionDeclaration {
pub:
	name        string @[json: 'name']
	description string @[json: 'description']
	parameters  Schema @[json: 'parameters']
}

struct Tool {
pub:
	type_    string              = 'function' @[json: 'type']
	function FunctionDeclaration @[json: 'function']
}

struct ToolFunction {
pub:
	name      string @[json: 'name']
	arguments string @[json: 'arguments']
}

struct ToolCall {
pub:
	id       string       @[json: 'id']
	type_    string       @[json: 'type']
	function ToolFunction @[json: 'function']
}

struct ChatMessage {
pub mut:
	role         string      @[json: 'role']
	content      ?string     @[json: 'content']
	tool_calls   ?[]ToolCall @[json: 'tool_calls']
	tool_call_id ?string     @[json: 'tool_call_id']
}

struct ChatRequest {
pub mut:
	model    string        @[json: 'model']
	messages []ChatMessage @[json: 'messages']
	stream   bool          @[json: 'stream']
	tools    []Tool        @[json: 'tools'; optional]
}

struct ChatChoice {
pub:
	message ChatMessage @[json: 'message']
}

struct ChatResponse {
pub:
	choices []ChatChoice @[json: 'choices']
}

struct CommandResult {
pub:
	exit_code int    @[json: 'exit_code']
	stdout    string @[json: 'stdout']
	stderr    string @[json: 'stderr']
}

// --- 工具实现：辅助函数 ---

fn normalize_path(path string) string {
	mut p := path.replace('\\', '/')
	if p.starts_with('./') {
		p = p[2..]
	}
	return p
}

fn truncate_tool_output(s string, max_len int, tail_len int) string {
	if s.len <= max_len {
		return s
	}
	if tail_len > 0 && max_len > tail_len + 50 {
		return s[..max_len - tail_len - 30] + '\n... [Truncated ${s.len - max_len} bytes] ...\n' + s[s.len - tail_len..]
	}
	return s[..max_len] + '\n... [Content Truncated]'
}

// --- 具体工具逻辑 ---

fn glob_files(pattern string) []string {
	mut re_p := pattern.replace('\\', '/').replace('.', '\\.')
	if re_p.contains('**') {
		re_p = re_p.replace('**', '.*')
	} else {
		re_p = re_p.replace('*', '[^/]*')
	}
	if !re_p.starts_with('^') { re_p = '.*' + re_p }
	if !re_p.ends_with('$') { re_p = re_p + '$' }

	mut re := regex.regex_opt(re_p) or { return ['Error: Invalid pattern'] }
	mut results := []string{}
	os.walk('.', fn [mut results, mut re] (file string) {
		f := normalize_path(file)
		if f.contains('.git/') || f.contains('node_modules/') { return }
		if re.matches_string(f) { results << f }
	})
	return results
}

// --- Qwen Settings 结构 ---

struct MCPServerConfig {
pub:
	command string            @[json: 'command']
	args    []string          @[json: 'args']
	env     map[string]string @[json: 'env']
}

struct QwenSettings {
pub:
	mcp_servers map[string]MCPServerConfig @[json: 'mcpServers']
}

// --- MCP Client/Models (从 gemini-v 迁移) ---

struct JsonRpcRequest {
	jsonrpc string = '2.0'
	id      int    @[json: 'id']
	method  string @[json: 'method']
	params  string @[json: 'params'; raw]
}

struct JsonRpcResponse {
	jsonrpc string @[json: 'jsonrpc']
	id      int    @[json: 'id']
	result  string @[json: 'result'; raw]
	error   ?JsonRpcError
}

struct JsonRpcError {
	code    int    @[json: 'code']
	message string @[json: 'message']
	data    string @[json: 'data'; raw]
}

struct Implementation {
	name    string @[json: 'name']
	version string @[json: 'version']
}

struct ClientCapabilities {
	experimental map[string]string @[json: 'experimental'; optional]
	sampling     map[string]string @[json: 'sampling'; optional]
	roots        map[string]string @[json: 'roots'; optional]
}

struct InitializeParams {
	protocol_version string             @[json: 'protocolVersion']
	capabilities     ClientCapabilities @[json: 'capabilities']
	client_info      Implementation     @[json: 'clientInfo']
}

struct McpTool {
	name         string @[json: 'name']
	description  string @[json: 'description']
	input_schema string @[json: 'inputSchema'; raw]
}

struct ListToolsResult {
	tools []McpTool @[json: 'tools']
}

struct CallToolResult {
	content  []McpContent @[json: 'content']
	is_error bool         @[json: 'isError'; optional]
}

struct McpContent {
	type_ string @[json: 'type']
	text  string @[json: 'text']
}

struct McpRpcMessage {
	jsonrpc string
	id      int
	method  string
}

fn drain_stderr(mut p os.Process) {
	for p.is_alive() {
		err_chunk := p.stderr_read()
		if err_chunk != '' {
			eprintln('[MCP DEBUG] [${time.now().format_ss_milli()}] STDERR: ${err_chunk.trim_space()}')
		} else {
			time.sleep(100 * time.millisecond)
		}
	}
}

struct McpClient {
mut:
	process      &os.Process = unsafe { nil }
	msg_id       int
	is_connected bool
	debug        bool
}

fn (mut c McpClient) connect(command string, args []string, env map[string]string) ! {
	if c.debug {
		eprintln('[MCP DEBUG] Starting: ${command} ${args.join(' ')}')
	}
	c.process = os.new_process(command)
	c.process.set_args(args)
	
	// 合并环境变量，确保 PATH 等基础变量存在
	mut final_env := os.environ().clone()
	for k, v in env {
		final_env[k] = v
	}
	c.process.set_environment(final_env)
	
	c.process.set_redirect_stdio()
	c.process.run()

	if !c.process.is_alive() {
		return error('无法启动 MCP Server: ${command}')
	}

	// 启动 stderr 读取线程，防止 stderr 写满导致进程阻塞
	if c.debug {
		mut p := c.process
		spawn drain_stderr(mut p)
	}

	c.is_connected = true
	c.initialize() or { return err }
	
	if c.debug {
		eprintln('[MCP DEBUG] Initializing tools list check...')
		list_res := c.request('tools/list', '{}') or { 'Error' }
		eprintln('[MCP DEBUG] Available Tools: ${list_res}')
	}
}

fn (mut c McpClient) request(method string, params_json string) !string {
	c.msg_id++
	id := c.msg_id
	payload := '{"jsonrpc":"2.0","id":${id},"method":"${method}","params":${params_json}}'
	if c.debug {
		eprintln('[MCP DEBUG] [${time.now().format_ss_milli()}] >>> SEND: ${payload}')
	}
	c.process.stdin_write(payload + '\n')

	mut response_buffer := ''
	for {
		// 尝试读取 stdout
		out_chunk := c.process.stdout_read()
		if out_chunk == '' {
			time.sleep(100 * time.millisecond)
			continue
		}

		if c.debug {
			eprintln('[MCP DEBUG] [${time.now().format_ss_milli()}] STDOUT RAW: ${out_chunk.len} bytes')
		}
		response_buffer += out_chunk

		if response_buffer.contains('\n') {
			lines := response_buffer.split('\n')
			response_buffer = lines[lines.len - 1]
			for i := 0; i < lines.len - 1; i++ {
				line := lines[i].trim_space()
				if line == '' { continue }
				
				// 使用 JSON 解码处理请求和响应
				msg := json.decode(McpRpcMessage, line) or {
					continue
				}

				// 如果 ID 匹配且没有 method，说明是响应
				if msg.id == id && msg.method == '' {
					if c.debug {
						eprintln('[MCP DEBUG] [${time.now().format_ss_milli()}] <<< RESPONSE: ${line}')
					}
					return line
				}

				// 自动响应服务器发起的请求，防止死锁
				if msg.method != '' {
					// 即使 id 为 0 也要响应（Playwright 经常发送 id: 0 的 roots/list）
					if line.contains('"id":') {
						mut auto_resp := ''
						if msg.method == 'roots/list' {
							auto_resp = '{"jsonrpc":"2.0","id":${msg.id},"result":{"roots":[]}}\n'
						} else if msg.method == 'sampling/createMessage' {
							auto_resp = '{"jsonrpc":"2.0","id":${msg.id},"result":{"content":[]}}\n'
						} else {
							auto_resp = '{"jsonrpc":"2.0","id":${msg.id},"result":{}}\n'
						}
						
						if c.debug {
							eprintln('[MCP DEBUG] [${time.now().format_ss_milli()}] >>> AUTO-REPLY: ${auto_resp.trim_space()}')
						}
						c.process.stdin_write(auto_resp)
					} else {
						if c.debug {
							eprintln('[MCP DEBUG] [${time.now().format_ss_milli()}] IGNORED NOTIF: ${line}')
						}
					}
				}
			}
		}

		// 改进：大数据包（可能没有换行符）的处理逻辑
		if response_buffer.contains('"id":${id}') && (response_buffer.contains('"result":') || response_buffer.contains('"error":')) {
			if response_buffer.starts_with('{') && (response_buffer.ends_with('}') || response_buffer.contains('}\n') || response_buffer.contains('}\r')) {
				return response_buffer.trim_space()
			}
		}
	}
	return error('请求超时')
}

fn (mut c McpClient) initialize() ! {
	params := InitializeParams{
		protocol_version: '2024-11-05'
		capabilities:     ClientCapabilities{}
		client_info:      Implementation{ name: 'qwen-mcp', version: '0.1.0' }
	}
	_ := c.request('initialize', json.encode(params))!
	
	notify := '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}'
	if c.debug {
		eprintln('[MCP DEBUG] >>> NOTIFY: ${notify}')
	}
	c.process.stdin_write(notify + '\n')
}

fn (mut c McpClient) call_tool(name string, args map[string]string) !string {
	args_json := json.encode(args)
	params_json := '{"name":"${name}","arguments":${args_json}}'
	res_json := c.request('tools/call', params_json)!
	resp := json.decode(JsonRpcResponse, res_json) or { return error('响应解析失败') }
	result := json.decode(CallToolResult, resp.result) or { return error('结果解析失败') }
	mut out := []string{}
	for item in result.content { out << item.text }
	return out.join('\n')
}

fn load_qwen_settings() !QwenSettings {
	path := os.join_path(os.home_dir(), '.qwen', 'settings.json')
	if !os.exists(path) {
		return QwenSettings{}
	}
	content := os.read_file(path)!
	// 简单的 jsonc 建议处理：去掉注释（虽然 json.decode 可能不支持 jsonc，但在 mac/linux 下常用这种方式）
	mut clean_content := []string{}
	for line in content.split_into_lines() {
		trimmed := line.trim_space()
		if trimmed.starts_with('//') || trimmed.starts_with('#') { continue }
		clean_content << line
	}
	settings := json.decode(QwenSettings, clean_content.join('\n')) or {
		return error('解析 settings.json 失败: ${err.msg()}')
	}
	return settings
}

fn get_available_tools() []Tool {
	return [
		Tool{
			function: FunctionDeclaration{
				name:        'read_file'
				description: '读取指定文件的内容。'
				parameters:  Schema{
					type_:      'object'
					properties: {
						'path': Property{'string', '文件路径'}
					}
					required:   ['path']
				}
			}
		},
		Tool{
			function: FunctionDeclaration{
				name:        'list_directory'
				description: '列出目录下的文件。'
				parameters:  Schema{
					type_:      'object'
					properties: {
						'path': Property{'string', '目录路径'}
					}
					required:   ['path']
				}
			}
		},
		Tool{
			function: FunctionDeclaration{
				name:        'write_file'
				description: '写入内容到文件。'
				parameters:  Schema{
					type_:      'object'
					properties: {
						'path':    Property{'string', '文件路径'}
						'content': Property{'string', '要写入的内容'}
					}
					required:   ['path', 'content']
				}
			}
		},
		Tool{
			function: FunctionDeclaration{
				name:        'run_command'
				description: '执行 shell 命令。'
				parameters:  Schema{
					type_:      'object'
					properties: {
						'command': Property{'string', '要运行的命令'}
					}
					required:   ['command']
				}
			}
		},
		Tool{
			function: FunctionDeclaration{
				name:        'glob'
				description: '查找匹配 glob 模式的文件。'
				parameters:  Schema{
					type_:      'object'
					properties: {
						'pattern': Property{'string', 'glob 模式'}
					}
					required:   ['pattern']
				}
			}
		},
		Tool{
			function: FunctionDeclaration{
				name:        'playwright_navigate'
				description: '使用 Playwright 导航到 URL。'
				parameters:  Schema{
					type_:      'object'
					properties: {
						'url': Property{'string', '目标 URL'}
					}
					required:   ['url']
				}
			}
		},
		Tool{
			function: FunctionDeclaration{
				name:        'playwright_snapshot'
				description: '获取当前页面的屏幕快照/文本。'
				parameters:  Schema{
					type_:      'object'
					properties: {}
					required:   []
				}
			}
		},
	]
}

// --- Qwen Agent 核心 ---

struct QwenAgent {
pub mut:
	creds       QwenCredentials
	endpoint    string
	model       string
	history     []ChatMessage
	mcp_clients map[string]&McpClient
	debug       bool
}

fn new_qwen_agent() !&QwenAgent {
	creds := load_qwen_creds()!
	
	now := time.now().unix_milli()
	if creds.expiry_date > 0 && now > creds.expiry_date {
		eprintln('警告: Token 似乎已过期，请在 qwen-code 中刷新。')
	}

	model := 'coder-model'
	mut base_url := if creds.resource_url != '' { creds.resource_url } else { 'dashscope.aliyuncs.com/compatible-mode' }
	if !base_url.starts_with('http') { base_url = 'https://' + base_url }
	if !base_url.ends_with('/v1') { base_url = base_url.trim_right('/') + '/v1' }

	return &QwenAgent{
		creds: creds
		endpoint: base_url + '/chat/completions'
		model: model
		history: [
			ChatMessage{
				role: 'system'
				content: 'You are Qwen-V Agent, a powerful coding assistant with tool use capabilities. Current OS: ' + os.user_os()
			}
		]
		mcp_clients: map[string]&McpClient{}
		debug: false
	}
}

fn (mut a QwenAgent) execute_tool(name string, args map[string]string) string {
	match name {
		'list_directory' {
			path := normalize_path(args['path'] or { '.' })
			items := os.ls(path) or { return 'Error: directory not found' }
			return items.join('\n')
		}
		'read_file' {
			path := normalize_path(args['path'] or { '' })
			content := os.read_file(path) or { return 'Error: file not found' }
			return truncate_tool_output(content, 16384, 512)
		}
		'write_file' {
			path := normalize_path(args['path'] or { '' })
			content := args['content'] or { '' }
			os.write_file(path, content) or { return 'Error: write failed' }
			return 'Done'
		}
		'run_command' {
			cmd := args['command'] or { '' }
			res := os.execute(cmd)
			return json.encode(CommandResult{
				exit_code: res.exit_code
				stdout:    res.output
				stderr:    ''
			})
		}
		'glob' {
			pattern := args['pattern'] or { '' }
			return glob_files(pattern).join('\n')
		}
		'playwright_snapshot', 'playwright_click', 'playwright_type', 'playwright_navigate' {
			settings := load_qwen_settings() or { return 'Error: failed to load settings' }
			pw_config := settings.mcp_servers['playwright'] or { return 'Error: playwright MCP not configured' }
			
			// 获取或创建 MCP Client
			mut client := a.mcp_clients['playwright'] or {
				mut c := &McpClient{
					debug: a.debug
				}
				c.connect(pw_config.command, pw_config.args, pw_config.env) or { return 'Error: MCP connect failed: ${err}' }
				a.mcp_clients['playwright'] = c
				c
			}

			// 移除 playwright_ 并映射到 Playwright MCP 的实际工具名 (browser_*)
			mut mcp_tool_name := name.replace('playwright_', '')
			if !mcp_tool_name.starts_with('browser_') {
				mcp_tool_name = 'browser_' + mcp_tool_name
			}
			return client.call_tool(mcp_tool_name, args) or { 'Error: MCP call failed: ${err}' }
		}
		else {
			return 'Tool ${name} not implemented yet'
		}
	}
}

fn (mut a QwenAgent) chat(text string) !string {
	a.history << ChatMessage{
		role: 'user'
		content: text
	}
	
	for {
		// 为了满足 DashScope 的严格校验：
		// 1. 对于包含 tool_calls 的消息，content 必须为 null 或不传（V 的 ?string 配合 json 序列化会处理这一点）。
		// 2. 消息历史中不能有连续的同角色消息（除 tool 外）。
		
		req_body := ChatRequest{
			model: a.model
			messages: a.history
			stream: false
			tools: get_available_tools()
		}
		
		msg_data := json.encode(req_body)
		mut req := http.new_request(.post, a.endpoint, msg_data)
		req.add_header(.authorization, 'Bearer ' + a.creds.access_token)
		req.add_header(.content_type, 'application/json')
		
		resp := req.do() or { return error('请求失败: ${err.msg()}') }
		if resp.status_code != 200 { return error('API 错误 (${resp.status_code}): ${resp.body}') }
		
		chat_resp := json.decode(ChatResponse, resp.body) or { return error('解析响应失败: ${err.msg()}\nBody: ${resp.body}') }
		if chat_resp.choices.len == 0 { return error('响应无内容') }
		
		mut msg := chat_resp.choices[0].message
		
		// 修正：如果返回的消息包含 tool_calls 但 content 为空字符串，
		// DashScope 将其序列化回请求时会报错。我们需要确保 content 在有 tool_calls 时设为 none (null)。
		if tcs := msg.tool_calls {
			if tcs.len > 0 {
				msg.content = none
			}
		}
		
		a.history << msg 
		
		if tcs := msg.tool_calls {
			if tcs.len > 0 {
				println('  > Qwen 正在调用工具: ${tcs.len} 个')
				for tool_call in tcs {
					tname := tool_call.function.name
					args := json.decode(map[string]string, tool_call.function.arguments) or { map[string]string{} }
					
					println('    - 执行 ${tname}(${tool_call.function.arguments})')
					result := a.execute_tool(tname, args)
					
					a.history << ChatMessage{
						role:         'tool'
						tool_call_id: tool_call.id
						content:      result
					}
				}
				continue
			}
		}
		
		return if c := msg.content {
			if c != '' { c } else { '执行完毕。' }
		} else {
			'执行完毕。'
		}
	}
	return 'Error'
}

fn main() {
	args := os.args
	mut p_mode := false
	mut prompt := ''
	mut debug_mode := false
	
	for i := 0; i < args.len; i++ {
		if args[i] == '-p' && i + 1 < args.len {
			p_mode = true
			prompt = args[i + 1]
		}
		if args[i] == '--debug' {
			debug_mode = true
		}
	}

	if !p_mode {
		println('正在初始化支持工具的 Qwen Agent...')
	}
	
	mut agent := new_qwen_agent() or {
		eprintln('错误: ${err.msg()}')
		return
	}
	agent.debug = debug_mode
	
	if p_mode {
		response := agent.chat(prompt) or {
			eprintln('API 错误: ${err.msg()}')
			return
		}
		println(response)
		return
	}
	
	println('模型: ${agent.model} | 工具: 已就绪')
	println('欢迎使用 Qwen-V Agent! 输入 "exit" 退出。')
	
	mut r := readline.Readline{}
	for {
		line := r.read_line('\nYou > ') or { break }
		if line == '' || line == 'exit' || line == 'quit' { break }
		
		println('Qwen 正在思考/执行工具...')
		response := agent.chat(line) or {
			eprintln('API 错误: ${err.msg()}')
			continue
		}
		
		println('\nQwen > ${response}\n')
	}
}
