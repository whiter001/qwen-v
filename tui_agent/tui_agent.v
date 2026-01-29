module tui_agent

import term.ui as tui
import core

pub struct TuiApp {
pub mut:
	ctx          &tui.Context = unsafe { nil }
	input        []rune
	agent        &core.QwenAgent = unsafe { nil }
	is_loading   bool
	scroll_y     int
}

fn frame(x voidptr) {
	mut app := unsafe { &TuiApp(x) }
	app.ctx.clear()
	w, h := app.ctx.window_width, app.ctx.window_height

	// 1. 标题
	app.ctx.set_bg_color(r: 0, g: 80, b: 200)
	title := " Qwen-V Agent TUI | Model: ${app.agent.model} "
	app.ctx.draw_text(1, 1, title + " ".repeat(if w > title.len { w - title.len } else { 0 }))
	app.ctx.reset()

	// 2. 对话历史区
	mut current_row := 3
	history_limit := h - 4
	
	mut start_msg := 0
	if app.agent.history.len > 10 {
		start_msg = app.agent.history.len - 10
	}

	for i := start_msg; i < app.agent.history.len; i++ {
		msg := app.agent.history[i]
		if msg.role == "system" { continue }

		if msg.role == "user" {
			app.ctx.set_color(r: 0, g: 255, b: 0)
		} else if msg.role == "tool" {
			app.ctx.set_color(r: 100, g: 100, b: 255)
		} else {
			app.ctx.set_color(r: 0, g: 255, b: 255)
		}

		app.ctx.draw_text(1, current_row, "[${msg.role.to_upper()}]")
		app.ctx.reset()

		raw_content := msg.content or { 
			if msg.tool_calls != none { "调用工具中..." } else { "" } 
		}
		
		txt_lines := raw_content.split_into_lines()
		for line in txt_lines {
			if current_row < history_limit {
				display := if line.len > w - 4 { line[..w-4] } else { line }
				app.ctx.draw_text(3, current_row + 1, display)
				current_row++
			}
		}
		current_row += 2
	}

	// 3. 状态提示
	if app.is_loading {
		app.ctx.set_color(r: 255, g: 255, b: 0)
		app.ctx.draw_text(1, h - 2, "Qwen 正在执行计算/工具使用...")
		app.ctx.reset()
	}

	// 4. 输入框
	app.ctx.set_bg_color(r: 40, g: 40, b: 40)
	prefix := " You > "
	input_text := app.input.string()
	app.ctx.draw_text(1, h - 1, prefix + input_text + " ".repeat(if w > prefix.len + input_text.len { w - prefix.len - input_text.len } else { 0 }))
	app.ctx.reset()
	app.ctx.set_cursor_position(prefix.len + app.input.len + 1, h - 1)

	app.ctx.flush()
}

fn event(e &tui.Event, x voidptr) {
	mut app := unsafe { &TuiApp(x) }
	if e.typ == .key_down {
		match e.code {
			.escape { exit(0) }
			.enter { 
				if app.input.len > 0 && !app.is_loading {
					prompt := app.input.string()
					app.input = []
					app.is_loading = true
					// 在后台执行
					go fn (mut a TuiApp, p string) {
						a.agent.chat(p) or {}
						a.is_loading = false
					}(mut app, prompt)
				}
			}
			.backspace { if app.input.len > 0 { app.input.delete_last() } }
			else {
				if e.ascii >= 32 && e.ascii <= 126 {
					app.input << rune(e.ascii)
				}
			}
		}
	}
}

pub fn start_tui(agent &core.QwenAgent) {
	mut app := &TuiApp{}
	unsafe {
		app.agent = agent
	}
	app.ctx = tui.init(
		user_data: app
		frame_fn: frame
		event_fn: event
		window_title: 'Qwen-V TUI'
	)
	app.ctx.run() or { panic(err) }
}
