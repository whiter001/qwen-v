module core

import net.http
import json
import os
import time
import regex

// --- Qwen OAuth 凭证结构 ---

pub struct QwenCredentials {
pub mut:
	access_token  string @[json: 'access_token']
	refresh_token string @[json: 'refresh_token']
	token_type    string @[json: 'token_type']
	resource_url  string @[json: 'resource_url']
	expiry_date   i64    @[json: 'expiry_date']
}

pub fn get_qwen_creds_path() string {
	return os.join_path(os.home_dir(), '.qwen', 'oauth_creds.json')
}

pub fn load_qwen_creds() !QwenCredentials {
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

pub struct Property {
pub:
	type_       string @[json: 'type']
	description string @[json: 'description']
}

pub struct Schema {
pub:
	type_      string              @[json: 'type']
	properties map[string]Property @[json: 'properties']
	required   []string            @[json: 'required']
}

pub struct FunctionDeclaration {
pub:
	name        string @[json: 'name']
	description string @[json: 'description']
	parameters  Schema @[json: 'parameters']
}

pub struct Tool {
pub:
	type_    string              = 'function' @[json: 'type']
	function FunctionDeclaration @[json: 'function']
}

pub struct ToolFunction {
pub:
	name      string @[json: 'name']
	arguments string @[json: 'arguments']
}

pub struct ToolCall {
pub:
	id       string       @[json: 'id']
	type_    string       @[json: 'type']
	function ToolFunction @[json: 'function']
}

pub struct ChatMessage {
pub mut:
	role         string      @[json: 'role']
	content      ?string     @[json: 'content']
	tool_calls   ?[]ToolCall @[json: 'tool_calls']
	tool_call_id ?string     @[json: 'tool_call_id']
}

pub struct ChatRequest {
pub mut:
	model    string        @[json: 'model']
	messages []ChatMessage @[json: 'messages']
	stream   bool          @[json: 'stream']
	tools    []Tool        @[json: 'tools'; optional]
}

pub struct ChatChoice {
pub:
	message ChatMessage @[json: 'message']
}

pub struct ChatResponse {
pub:
	choices []ChatChoice @[json: 'choices']
}

pub struct CommandResult {
pub:
	exit_code int    @[json: 'exit_code']
	stdout    string @[json: 'stdout']
	stderr    string @[json: 'stderr']
}

// --- 工具实现：辅助函数 ---

pub fn normalize_path(path string) string {
	mut p := path.replace('\\', '/')
	if p.starts_with('./') {
		p = p[2..]
	}
	return p
}

// --- 安全边界：路径验证 ---

// 检查路径是否在工作区内
pub fn is_path_in_workspace(workspace string, target_path string) bool {
	if workspace == '' {
		return true // 未设置工作区则不限制
	}

	// 获取绝对路径
	abs_workspace := os.abs_path(workspace)
	abs_target := os.abs_path(target_path)

	// 检查目标路径是否以工作区路径开头
	return abs_target.starts_with(abs_workspace)
}

// 验证并返回路径，如果不在工作区内则返回错误
pub fn validate_workspace_path(workspace string, target_path string) !string {
	if workspace == '' {
		return normalize_path(target_path) // 未设置工作区则不限制
	}

	normalized := normalize_path(target_path)

	// 处理相对路径
	mut abs_target := normalized
	if !normalized.starts_with('/') {
		abs_target = os.abs_path(normalized)
	} else {
		abs_target = os.abs_path(normalized)
	}

	if !is_path_in_workspace(workspace, abs_target) {
		return error('安全限制：路径 "${target_path}" 超出工作区 "${workspace}"')
	}

	return normalized
}

pub fn truncate_tool_output(s string, max_len int, tail_len int) string {
	if s.len <= max_len {
		return s
	}
	if tail_len > 0 && max_len > tail_len + 50 {
		return s[..max_len - tail_len - 30] + '\n... [Truncated ${s.len - max_len} bytes] ...\n' + s[s.len - tail_len..]
	}
	return s[..max_len] + '\n... [Content Truncated]'
}

pub fn glob_files(pattern string) []string {
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

pub struct MCPServerConfig {
pub:
	command string            @[json: 'command'; optional]
	args    []string          @[json: 'args'; optional]
	env     map[string]string @[json: 'env'; optional]
	url     string            @[json: 'url'; optional]
}

pub struct QwenSettings {
pub:
	mcp_servers            map[string]MCPServerConfig @[json: 'mcpServers']
	restrict_to_workspace  bool                        @[json: 'restrictToWorkspace']
}

// --- MCP Client/Models ---

pub struct JsonRpcRequest {
	jsonrpc string = '2.0'
	id      int    @[json: 'id']
	method  string @[json: 'method']
	params  string @[json: 'params'; raw]
}

pub struct JsonRpcResponse {
	jsonrpc string @[json: 'jsonrpc']
	id      int    @[json: 'id']
	result  string @[json: 'result'; raw]
	error   ?JsonRpcError
}

pub struct JsonRpcError {
	code    int    @[json: 'code']
	message string @[json: 'message']
	data    string @[json: 'data'; raw]
}

pub struct Implementation {
	name    string @[json: 'name']
	version string @[json: 'version']
}

pub struct ClientCapabilities {
	experimental map[string]string @[json: 'experimental'; optional]
	sampling     map[string]string @[json: 'sampling'; optional]
	roots        map[string]string @[json: 'roots'; optional]
}

pub struct InitializeParams {
	protocol_version string             @[json: 'protocolVersion']
	capabilities     ClientCapabilities @[json: 'capabilities']
	client_info      Implementation     @[json: 'clientInfo']
}

pub struct McpTool {
	name         string @[json: 'name']
	description  string @[json: 'description']
	input_schema string @[json: 'inputSchema'; raw]
}

pub struct ListToolsResult {
	tools []McpTool @[json: 'tools']
}

pub struct CallToolResult {
	content  []McpContent @[json: 'content']
	is_error bool         @[json: 'isError'; optional]
}

pub struct McpContent {
	type_ string @[json: 'type']
	text  string @[json: 'text']
}

pub struct McpRpcMessage {
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

pub struct McpClient {
pub mut:
	process      &os.Process = unsafe { nil }
	msg_id       int
	is_connected bool
	debug        bool
}

pub fn (mut c McpClient) connect(command string, args []string, env map[string]string) ! {
	if c.debug {
		eprintln('[MCP DEBUG] Starting: ${command} ${args.join(' ')}')
	}
	c.process = os.new_process(command)
	c.process.set_args(args)
	
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

	if c.debug {
		mut p := c.process
		spawn drain_stderr(mut p)
	}

	c.is_connected = true
	c.initialize() or { return err }
}

pub fn (mut c McpClient) request(method string, params_json string) !string {
	c.msg_id++
	id := c.msg_id
	payload := '{"jsonrpc":"2.0","id":${id},"method":"${method}","params":${params_json}}'
	if c.debug {
		eprintln('[MCP DEBUG] [${time.now().format_ss_milli()}] >>> SEND: ${payload}')
	}
	c.process.stdin_write(payload + '\n')

	mut response_buffer := ''
	start_time := time.ticks()
	timeout_ms := 5000 // 5秒超时
	
	for {
		if time.ticks() - start_time > timeout_ms {
			return error('MCP 请求超时 (${method})')
		}

		out_chunk := c.process.stdout_read()
		if out_chunk == '' {
			time.sleep(50 * time.millisecond)
			continue
		}

		response_buffer += out_chunk
		if response_buffer.contains('\n') {
			lines := response_buffer.split('\n')
			response_buffer = lines[lines.len - 1]
			for i := 0; i < lines.len - 1; i++ {
				line := lines[i].trim_space()
				if line == '' { continue }
				msg := json.decode(McpRpcMessage, line) or { continue }
				if msg.id == id && msg.method == '' {
					return line
				}
				if msg.method != '' {
					if line.contains('"id":') {
						mut auto_resp := ''
						if msg.method == 'roots/list' {
							auto_resp = '{"jsonrpc":"2.0","id":${msg.id},"result":{"roots":[]}}\n'
						} else if msg.method == 'sampling/createMessage' {
							auto_resp = '{"jsonrpc":"2.0","id":${msg.id},"result":{"content":[]}}\n'
						} else {
							auto_resp = '{"jsonrpc":"2.0","id":${msg.id},"result":{}}\n'
						}
						c.process.stdin_write(auto_resp)
					}
				}
			}
		}
		if response_buffer.contains('"id":${id}') && (response_buffer.contains('"result":') || response_buffer.contains('"error":')) {
			if response_buffer.starts_with('{') && (response_buffer.ends_with('}') || response_buffer.contains('}\n')) {
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
	c.process.stdin_write(notify + '\n')
}

pub fn (mut c McpClient) call_tool(name string, args map[string]string) !string {
	args_json := json.encode(args)
	params_json := '{"name":"${name}","arguments":${args_json}}'
	res_json := c.request('tools/call', params_json)!
	resp := json.decode(JsonRpcResponse, res_json) or { return error('响应解析失败') }
	result := json.decode(CallToolResult, resp.result) or { return error('结果解析失败') }
	mut out := []string{}
	for item in result.content { out << item.text }
	return out.join('\n')
}

pub fn load_qwen_settings() !QwenSettings {
	path := os.join_path(os.home_dir(), '.qwen', 'settings.json')
	if !os.exists(path) { return QwenSettings{} }
	content := os.read_file(path)!
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

pub fn get_available_tools() []Tool {
	return [
		Tool{
			function: FunctionDeclaration{
				name:        'read_file'
				description: '读取指定文件的内容。'
				parameters:  Schema{
					type_:      'object'
					properties: { 'path': Property{'string', '文件路径'} }
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
					properties: { 'path': Property{'string', '目录路径'} }
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
					properties: { 'command': Property{'string', '要运行的命令'} }
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
					properties: { 'pattern': Property{'string', 'glob 模式'} }
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
					properties: { 'url': Property{'string', '目标 URL'} }
					required:   ['url']
				}
			}
		},
		Tool{
			function: FunctionDeclaration{
				name:        'playwright_snapshot'
				description: '获取当前页面的屏幕快照/文本。'
				parameters:  Schema{ type_: 'object', properties: {}, required: [] }
			}
		},
		Tool{
			function: FunctionDeclaration{
				name:        'playwright_click'
				description: '点击页面上的元素。'
				parameters:  Schema{
					type_:      'object'
					properties: { 'ref': Property{'string', '元素引用 ID (来自快照)'} }
					required:   ['ref']
				}
			}
		},
		Tool{
			function: FunctionDeclaration{
				name:        'playwright_type'
				description: '在页面元素中输入文本并提交。'
				parameters:  Schema{
					type_:      'object'
					properties: {
						'ref':  Property{'string', '元素引用 ID (来自快照)'}
						'text': Property{'string', '要输入的文本'}
					}
					required:   ['ref', 'text']
				}
			}
		},
		Tool{
			function: FunctionDeclaration{
				name:        'playwright_back'
				description: '返回上一页。'
				parameters:  Schema{ type_: 'object', properties: {}, required: [] }
			}
		},
		Tool{
			function: FunctionDeclaration{
				name:        'playwright_evaluate'
				description: '在浏览器中执行自定义 JavaScript。'
				parameters:  Schema{
					type_:      'object'
					properties: { 'code': Property{'string', '要执行的代码'} }
					required:   ['code']
				}
			}
		}
	]
}

pub struct QwenAgent {
pub mut:
	creds                QwenCredentials
	endpoint             string
	model                string
	history              []ChatMessage
	mcp_clients          map[string]&McpClient
	extra_tools          []Tool
	settings             QwenSettings
	debug                bool
	status_text          string
	is_plan_mode         bool
	workspace            string // 工作区根目录，用于安全边界限制
}

pub fn new_qwen_agent() !&QwenAgent {
	creds := load_qwen_creds()!
	settings := load_qwen_settings() or { QwenSettings{} }
	model := 'coder-model'
	mut base_url := if creds.resource_url != '' { creds.resource_url } else { 'dashscope.aliyuncs.com/compatible-mode' }
	if !base_url.starts_with('http') { base_url = 'https://' + base_url }
	if !base_url.ends_with('/v1') { base_url = base_url.trim_right('/') + '/v1' }

	// 获取工作区路径，默认为当前工作目录
	workspace := os.getwd()

	mut agent := &QwenAgent{
		creds: creds
		endpoint: base_url + '/chat/completions'
		model: model
		history: [] // 稍后延迟初始化 history
		mcp_clients: map[string]&McpClient{}
		extra_tools: []Tool{}
		settings: settings
		debug: false
		workspace: workspace
	}

	agent.init_mcp_tools()
	return agent
}

pub fn (mut a QwenAgent) init_history() {
	mut sys_prompt := 'You are Qwen-V Agent, a powerful coding assistant with tool use capabilities. Current OS: ' + os.user_os()
	if a.is_plan_mode {
		sys_prompt += '\nIMPORTANT: You are currently in PLAN MODE. You can read files and explore codebases, but you CANNOT modify files or run commands that change the system. Your goal is to analyze and plan.'
	}
	a.history = [
		ChatMessage{
			role: 'system'
			content: sys_prompt
		}
	]
}

pub fn (mut a QwenAgent) init_mcp_tools() {
	for name, config in a.settings.mcp_servers {
		if name == 'playwright' { continue } 
		if config.command == '' {
			if a.debug { eprint('Skipping non-stdio MCP Server: ${name}\n') }
			continue
		}
		
		if a.debug { eprint('Initializing MCP Server: ${name}\n') }
		mut client := &McpClient{ debug: a.debug }
		client.connect(config.command, config.args, config.env) or {
			if a.debug { eprint('Failed to connect to ${name}: ${err}\n') }
			continue
		}
		a.mcp_clients[name] = client
		
		// 尝试获取工具列表
		tools_json := client.request('tools/list', '{}') or { continue }
		resp := json.decode(JsonRpcResponse, tools_json) or { continue }
		tools_res := json.decode(ListToolsResult, resp.result) or { continue }
		
		for mcp_tool in tools_res.tools {
			// 将 MCP 工具转换为 OpenAI 格式
			// 注意：这里需要更复杂的参数转换，目前简单处理
			a.extra_tools << Tool{
				function: FunctionDeclaration{
					name: '${name}__${mcp_tool.name}'
					description: mcp_tool.description
					parameters: Schema{
						type_: 'object'
						properties: map[string]Property{} // 简单化处理
						required: []string{}
					}
				}
			}
		}
	}
}

pub fn (mut a QwenAgent) execute_tool(name string, args map[string]string) string {
	// Plan 模式逻辑：拦截写操作和执行操作
	if a.is_plan_mode {
		dangerous_tools := ['write_file', 'run_command', 'playwright_click', 'playwright_type', 'playwright_evaluate']
		if name in dangerous_tools || name.contains('browser_click') || name.contains('browser_type') {
			return "Error: [PLAN MODE] 拒绝执行修改类操作 '${name}'。请切换到普通模式或仅进行读取。"
		}
	}

	// 安全边界：工作区限制检查
	restrict_workspace := a.settings.restrict_to_workspace
	workspace_path := a.workspace

	if name.contains('__') {
		parts := name.split('__')
		server_name := parts[0]
		tool_name := parts[1]
		if mut client := a.mcp_clients[server_name] {
			return client.call_tool(tool_name, args) or { 'Error: ${err}' }
		}
		return 'Error: MCP server ${server_name} not found'
	}

	match name {
		'list_directory' {
			if restrict_workspace {
				path := args['path'] or { '.' }
				validated_path := validate_workspace_path(workspace_path, path) or { return 'Error: ${err}' }
				normalized := normalize_path(validated_path)
				items := os.ls(normalized) or { return 'Error: directory not found' }
				return items.join('\n')
			}
			path := normalize_path(args['path'] or { '.' })
			items := os.ls(path) or { return 'Error: directory not found' }
			return items.join('\n')
		}
		'read_file' {
			if restrict_workspace {
				path := args['path'] or { '' }
				validated_path := validate_workspace_path(workspace_path, path) or { return 'Error: ${err}' }
				normalized := normalize_path(validated_path)
				content := os.read_file(normalized) or { return 'Error: file not found' }
				return truncate_tool_output(content, 16384, 512)
			}
			path := normalize_path(args['path'] or { '' })
			content := os.read_file(path) or { return 'Error: file not found' }
			return truncate_tool_output(content, 16384, 512)
		}
		'write_file' {
			if restrict_workspace {
				path := args['path'] or { '' }
				validated_path := validate_workspace_path(workspace_path, path) or { return 'Error: ${err}' }
				normalized := normalize_path(validated_path)
				content := args['content'] or { '' }
				os.write_file(normalized, content) or { return 'Error: write failed' }
				return 'Done'
			}
			path := normalize_path(args['path'] or { '' })
			content := args['content'] or { '' }
			os.write_file(path, content) or { return 'Error: write failed' }
			return 'Done'
		}
		'run_command' {
			if restrict_workspace {
				cmd := args['command'] or { '' }
				// 检查命令是否包含 cd 或其他目录切换命令
				if cmd.contains('cd ') || cmd.starts_with('cd ') {
					return 'Error: 安全限制：不允许使用 cd 命令切换目录'
				}
				// 检查命令是否尝试访问工作区外路径
				allowed_patterns := ['git', 'npm', 'pnpm', 'node', 'python', 'make', 'go ', 'cargo', 'curl', 'wget']
				mut is_safe := false
				for pattern in allowed_patterns {
					if cmd.starts_with(pattern) || cmd.contains(' ${pattern}') {
						is_safe = true
						break
					}
				}
				if !is_safe && (cmd.contains('/') || cmd.contains('..')) {
					return 'Error: 安全限制：不允许访问工作区外的路径'
				}
				res := os.execute(cmd)
				return json.encode(CommandResult{
					exit_code: res.exit_code
					stdout:    res.output
					stderr:    ''
				})
			}
			cmd := args['command'] or { '' }
			res := os.execute(cmd)
			return json.encode(CommandResult{
				exit_code: res.exit_code
				stdout:    res.output
				stderr:    ''
			})
		}
		'glob' {
			if restrict_workspace {
				pattern := args['pattern'] or { '' }
				// 验证 glob 模式在工作区内
				if pattern.contains('..') || (!pattern.starts_with('.') && !pattern.starts_with('/')) {
					// 相对模式，基于工作区
					full_pattern := normalize_path(workspace_path + '/' + pattern)
					return glob_files(full_pattern).join('\n')
				}
				return glob_files(pattern).join('\n')
			}
			pattern := args['pattern'] or { '' }
			return glob_files(pattern).join('\n')
		}
		'playwright_snapshot', 'playwright_click', 'playwright_type', 'playwright_navigate', 'playwright_back', 'playwright_evaluate' {
			pw_config := a.settings.mcp_servers['playwright'] or { return 'Error: playwright MCP not configured' }
			
			mut client := a.mcp_clients['playwright'] or {
				mut c := &McpClient{ debug: a.debug }
				c.connect(pw_config.command, pw_config.args, pw_config.env) or { return 'Error: MCP connect failed: ${err}' }
				a.mcp_clients['playwright'] = c
				c
			}

			mut mcp_tool_name := name.replace('playwright_', '')
			if mcp_tool_name == 'back' {
				mcp_tool_name = 'browser_navigate_back'
			} else if !mcp_tool_name.starts_with('browser_') {
				mcp_tool_name = 'browser_' + mcp_tool_name
			}
			return client.call_tool(mcp_tool_name, args) or { 'Error: MCP call failed: ${err}' }
		}
		else {
			return 'Tool ${name} not implemented yet'
		}
	}
}

pub fn (mut a QwenAgent) chat(text string) !string {
	a.history << ChatMessage{
		role: 'user'
		content: text
	}
	
	for {
		mut tools := get_available_tools()
		tools << a.extra_tools

		req_body := ChatRequest{
			model: a.model
			messages: a.history
			stream: false
			tools: tools
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
		if tcs := msg.tool_calls {
			if tcs.len > 0 {
				msg.content = none
			}
		}
		
		a.history << msg 
		
		if tcs := msg.tool_calls {
			if tcs.len > 0 {
				for tool_call in tcs {
					tname := tool_call.function.name
					a.status_text = "执行工具: ${tname}"
					args := json.decode(map[string]string, tool_call.function.arguments) or { map[string]string{} }
					result := a.execute_tool(tname, args)
					
					a.history << ChatMessage{
						role:         'tool'
						tool_call_id: tool_call.id
						content:      result
					}
				}
				a.status_text = ""
				continue
			}
		}
		
		a.status_text = ""
		return if c := msg.content {
			if c != '' { c } else { '执行完毕。' }
		} else {
			'执行完毕。'
		}
	}
	return 'Error'
}
