#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""精确修复第46-47行: 去掉错误续行符，合并为单行"""

FILE = "system/modules/time_mgmt.sh"
with open(FILE, 'r', encoding='utf-8') as f:
    lines = f.readlines()

print(f"Total lines: {len(lines)}")

# 找到有问题的行（printf 行末有多余反斜杠，下一行是孤立 ||）
fixed = False
new_lines = []
i = 0
while i < len(lines):
    line = lines[i]
    # 检测: printf '\x1b\x00...' >&9 ... 行末有多余的 \\\n 或 \\\\\n
    if "printf '" in line and ">&9" in line and i + 1 < len(lines):
        next_line = lines[i+1]
        # 如果下一行以 "        ||" 开头，说明续行符出错了
        if next_line.strip().startswith("|| {") or next_line.strip().startswith("||"):
            # 合并两行：去掉当前行末的续行符，把 || 合并进来
            # 清理当前行末的 \\ 和换行
            stripped = line.rstrip()
            # 去掉末尾的 \\ 
            while stripped.endswith('\\'):
                stripped = stripped[:-1]
            stripped = stripped.rstrip()
            # 取下一行的内容
            next_stripped = next_line.strip()
            merged = stripped + " " + next_stripped + "\n"
            print(f"Merging lines {i+1} and {i+2}:")
            print(f"  Was: {repr(line[:60])}")
            print(f"  +  : {repr(next_line[:60])}")
            print(f"  Now: {repr(merged[:80])}")
            new_lines.append(merged)
            i += 2  # skip both lines
            fixed = True
            continue
    new_lines.append(line)
    i += 1

if not fixed:
    print("No broken continuation found, checking manually...")
    for idx, l in enumerate(lines[43:50], 44):
        print(f"  {idx}: {repr(l)}")

with open(FILE, 'w', encoding='utf-8') as f:
    f.writelines(new_lines)

print(f"Done. Lines: {len(lines)} -> {len(new_lines)}")
