#!/bin/bash
# Qwen-V Agent Format Script

set -e

echo "Formatting project files..."

# 格式化 V 代码
echo "Formatting V code..."
v fmt .

# 格式化 Markdown 文档 (如果 oxfmt 可用)
if command -v oxfmt &> /dev/null; then
    echo "Formatting Markdown files..."
    oxfmt .
else
    echo "Warning: oxfmt not found. Install it for Markdown formatting."
fi

echo "Formatting complete!"
