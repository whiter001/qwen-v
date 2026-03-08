#!/bin/bash
# Qwen-V Agent Build Script

set -e

echo "Building Qwen-V Agent..."

# 格式化代码
echo "Formatting V code..."
v fmt .

# 编译
echo "Compiling..."
v . -o qwen_agent

# 格式化 Markdown 文档 (如果 oxfmt 可用)
if command -v oxfmt &> /dev/null; then
    echo "Formatting Markdown files..."
    oxfmt .
fi

echo "Build complete: ./qwen_agent"
