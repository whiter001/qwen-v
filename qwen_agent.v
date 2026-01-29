module main

import os
import term
import readline
import core
import tui_agent

fn main() {
	args := os.args
	mut p_mode := false
	mut prompt := ''
	mut debug_mode := false
	mut is_tui := false
	
	for i := 0; i < args.len; i++ {
		if args[i] == '-p' && i + 1 < args.len {
			p_mode = true
			prompt = args[i + 1]
		}
		if args[i] == '--debug' {
			debug_mode = true
		}
		if args[i] == '--tui' {
			is_tui = true
		}
	}

	if !p_mode && !is_tui {
		println(term.green('正在初始化支持工具的 Qwen Agent...'))
	}
	
	mut agent := core.new_qwen_agent() or {
		eprintln(term.red('错误: ${err.msg()}'))
		return
	}
	agent.debug = debug_mode
	
	if is_tui {
		tui_agent.start_tui(agent)
		return
	}

	if p_mode {
		response := agent.chat(prompt) or {
			eprintln(term.red('API 错误: ${err.msg()}'))
			return
		}
		println(response)
		return
	}
	
	println(term.header('模型: ${agent.model} | 工具: 已就绪', '-'))
	println('欢迎使用 Qwen-V Agent! 输入 "exit" 退出。')
	
	mut r := readline.Readline{}
	for {
		line := r.read_line(term.bold('\nYou > ')) or { break }
		if line == '' || line == 'exit' || line == 'quit' { break }
		
		println(term.gray('Qwen 正在思考/执行工具...'))
		response := agent.chat(line) or {
			eprintln(term.red('API 错误: ${err.msg()}'))
			continue
		}
		
		println('\n' + term.bold('Qwen > ') + response + '\n')
	}
}
