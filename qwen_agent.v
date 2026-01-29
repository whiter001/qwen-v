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

// --- 工具执行分发 ---

fn execute_tool(name string, args map[string]string) string {
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
		else {
			return 'Tool ${name} not implemented yet'
		}
	}
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
	]
}

// --- Qwen Agent 核心 ---

struct QwenAgent {
pub mut:
	creds    QwenCredentials
	endpoint string
	model    string
	history  []ChatMessage
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
					name := tool_call.function.name
					args := json.decode(map[string]string, tool_call.function.arguments) or { map[string]string{} }
					
					println('    - 执行 ${name}(${tool_call.function.arguments})')
					result := execute_tool(name, args)
					
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
	
	for i := 0; i < args.len; i++ {
		if args[i] == '-p' && i + 1 < args.len {
			p_mode = true
			prompt = args[i + 1]
			break
		}
	}

	if !p_mode {
		println('正在初始化支持工具的 Qwen Agent...')
	}
	
	mut agent := new_qwen_agent() or {
		eprintln('错误: ${err.msg()}')
		return
	}
	
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
