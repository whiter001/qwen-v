#!/usr/bin/env v
import os

struct ToolTest {
	name   string
	prompt string
}

// 获取 qwen_agent.v 的绝对路径
agent_path := os.real_path('qwen_agent.v')
println('开始测试 Qwen Agent 工具集成...')
println('Agent 路径: ${agent_path}')

tests := [
	ToolTest{
		name: 'list_directory'
		prompt: '列出当前目录下的文件'
	},
	ToolTest{
		name: 'read_file'
		prompt: '读取当前目录下的 README.md 文件内容'
	},
	ToolTest{
		name: 'write_file'
		prompt: '在当前目录下创建一个名为 test_qwen.txt 的文件，内容为 "Hello from Qwen Agent"'
	},
	ToolTest{
		name: 'delete_file'
		prompt: '删除刚才创建的 test_qwen.txt 文件'
	},
]

for test in tests {
	println('\n${'='.repeat(20)}')
	println('正在测试工具: ${test.name}')
	println('Prompt: ${test.prompt}')
	println('${'='.repeat(20)}')
	
	// 执行命令并获取输出
	result := os.execute('v run "${agent_path}" -p "${test.prompt}"')
	
	if result.exit_code != 0 {
		println('测试失败！')
		println('错误输出: ${result.output}')
	} else {
		println('测试输出:\n${result.output}')
		if result.output.contains('调用工具') || result.output.contains('执行') {
			println('\n✅ 工具识别与调用似乎正常。')
		} else {
			println('\n⚠️ 未在输出中检测到明确的工具调用日志，请检查模型回复。')
		}
	}
}

println('\n所有测试完成！')
