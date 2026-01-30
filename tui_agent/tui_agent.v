module tui_agent

import term.ui as tui
import core

pub struct TuiLine {
pub:
	role  string
	text  string
	color tui.Color
}

pub struct TuiApp {
pub mut:
	ctx          &tui.Context = unsafe { nil }
	input        []rune
	agent        &core.QwenAgent = unsafe { nil }
	is_loading   bool
	current_tool string
	scroll_y     int
}

fn word_wrap(text string, width int) []string {
	if text.len <= width { return [text] }
	mut lines := []string{}
	mut start := 0
	for start < text.len {
		mut end := start + width
		if end > text.len { end = text.len }
		lines << text[start..end]
		start = end
	}
	return lines
}

fn frame(x voidptr) {
	mut app := unsafe { &TuiApp(x) }
	app.ctx.clear()
	w, h := app.ctx.window_width, app.ctx.window_height

	// 1. 标题
	app.ctx.set_bg_color(r: 0, g: 80, b: 200)
	mut title := " Qwen-V Agent | Model: ${app.agent.model} "
	if app.agent.is_plan_mode {
		title += "| [PLAN MODE] "
	}
	app.ctx.draw_text(1, 1, title + " ".repeat(if w > title.len { w - title.len } else { 0 }))
	app.ctx.reset()

	// 2. 对话历史区
	mut current_row := 3
	history_limit := h - 4
	
	// 计算需要显示的最后几条消息，并进行自动折行
	mut display_lines := []TuiLine{}
	
	for i := 0; i < app.agent.history.len; i++ {
		msg := app.agent.history[i]
		if msg.role == "system" { continue }
		
		color := if msg.role == "user" { tui.Color{r: 0, g: 255, b: 0} } 
				else if msg.role == "tool" { tui.Color{r: 100, g: 100, b: 255} }
				else { tui.Color{r: 0, g: 255, b: 255} }

		raw_content := msg.content or { 
			if msg.tool_calls != none { "Calling tools..." } else { "" } 
		}
		
		wrapped := word_wrap(raw_content, w - 6)
		for line_idx, line in wrapped {
			display_lines << TuiLine{role: if line_idx == 0 { msg.role } else { "" }, text: line, color: color}
		}
	}

	start_idx := if display_lines.len > history_limit { display_lines.len - history_limit } else { 0 }
	for i := start_idx; i < display_lines.len; i++ {
		line := display_lines[i]
		if line.role != "" {
			app.ctx.set_color(line.color)
			app.ctx.draw_text(1, current_row, "[${line.role.to_upper()}]")
			app.ctx.reset()
		}
		app.ctx.draw_text(3, current_row, line.text)
		current_row++
	}

	// 3. 状态提示
	if app.is_loading {
		app.ctx.set_color(r: 255, g: 255, b: 0)
		status_text := if app.agent.status_text != "" { app.agent.status_text } else { "Qwen 正在思考中..." }
		app.ctx.draw_text(1, h - 2, status_text)
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
