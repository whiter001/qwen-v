module main

import net.http
import json
import os
import time
import readline

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

// --- OpenAI 兼容接口结构 ---

struct Message {
pub mut:
	role    string @[json: 'role']
	content string @[json: 'content']
}

struct ChatRequest {
pub mut:
	model    string    @[json: 'model']
	messages []Message @[json: 'messages']
	stream   bool      @[json: 'stream']
}

struct ChatChoice {
pub:
	message Message @[json: 'message']
}

struct ChatResponse {
pub:
	choices []ChatChoice @[json: 'choices']
}

// --- Qwen Agent 实现 ---

struct QwenAgent {
pub mut:
	creds    QwenCredentials
	endpoint string
	model    string
}

fn new_qwen_agent() !&QwenAgent {
	creds := load_qwen_creds()!
	
	// 检查 Token 是否过期 (expiry_date 是毫秒)
	now := time.now().unix_milli()
	if creds.expiry_date > 0 && now > creds.expiry_date {
		eprintln('警告: Token 似乎已过期，请在 qwen-code 中执行任一操作以刷新 Token。')
	}

	// 默认使用 coder-model，这也是 qwen-code 的默认配置
	model := 'coder-model'
	
	// 构造终点 URL
	mut base_url := if creds.resource_url != '' { 
		creds.resource_url 
	} else { 
		'dashscope.aliyuncs.com/compatible-mode' 
	}
	
	if !base_url.starts_with('http') {
		base_url = 'https://' + base_url
	}
	
	if !base_url.ends_with('/v1') {
		base_url = base_url.trim_right('/') + '/v1'
	}

	return &QwenAgent{
		creds: creds
		endpoint: base_url + '/chat/completions'
		model: model
	}
}

fn (mut a QwenAgent) chat(text string) !string {
	req_body := ChatRequest{
		model: a.model
		messages: [
			Message{
				role: 'system'
				content: 'You are Qwen-V Agent, a helpful assistant implemented in Vlang.'
			},
			Message{
				role: 'user'
				content: text
			}
		]
		stream: false
	}
	
	data := json.encode(req_body)
	
	mut req := http.new_request(.post, a.endpoint, data)
	req.add_header(.authorization, 'Bearer ' + a.creds.access_token)
	req.add_header(.content_type, 'application/json')
	
	resp := req.do() or {
		return error('请求失败: ${err.msg()}')
	}
	
	if resp.status_code != 200 {
		return error('服务器返回错误 (${resp.status_code}): ${resp.body}')
	}
	
	chat_resp := json.decode(ChatResponse, resp.body) or {
		return error('解析响应失败: ${err.msg()}\nBody: ${resp.body}')
	}
	
	if chat_resp.choices.len > 0 {
		return chat_resp.choices[0].message.content
	}
	
	return error('响应中没有内容')
}

fn main() {
	println('正在初始化 Qwen Agent...')
	mut agent := new_qwen_agent() or {
		eprintln('错误: ${err.msg()}')
		return
	}
	
	println('使用模型: ${agent.model}')
	println('API 终点: ${agent.endpoint}')
	println('欢迎使用 Qwen-V Agent! (输入 "exit" 退出)')
	
	mut r := readline.Readline{}
	for {
		line := r.read_line('User > ') or { break }
		if line == '' || line == 'exit' || line == 'quit' {
			break
		}
		
		println('Qwen 正在思考...')
		response := agent.chat(line) or {
			eprintln('API 错误: ${err.msg()}')
			continue
		}
		
		println('\nQwen > ${response}\n')
	}
}
