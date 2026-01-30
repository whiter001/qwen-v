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
	mut is_plan := false
	
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
		if args[i] == '--plan' {
			is_plan = true
		}
	}

	if !p_mode && !is_tui {
		print(term.green('正在初始化 Qwen Agent... '))
		os.flush()
	}
	
	mut agent := core.new_qwen_agent() or {
		println('')
		eprintln(term.red('错误: ${err.msg()}'))
		return
	}
	agent.debug = debug_mode
	agent.is_plan_mode = is_plan
	agent.init_history()
	
	if !p_mode && !is_tui {
		println(term.green('完成！'))
	}
	
	if is_plan {
		println(term.yellow('! 计划模式已启动：所有修改操作（写文件、运行命令、点击网页）将被拦截。'))
	}

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
