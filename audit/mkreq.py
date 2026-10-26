#!/usr/bin/env python3
"""把待译清单切成给模型的请求体。"""
import json, sys

src = sys.argv[1]
out = sys.argv[2]
items = json.load(open(src, encoding='utf-8'))
zhs = [i['zh'] for i in items]

prompt = (
    "You are translating UI strings for an iOS AI-chat app called Minis.\n"
    "For each Chinese string below, produce the English UI text.\n"
    "\n"
    "Rules:\n"
    "- Keep the same meaning and the same tone. This app's UI is plain and direct, not corporate.\n"
    "- Keep every placeholder EXACTLY as-is: \\(...) and %@ and %lld. Do not translate or reorder them.\n"
    "- Keep 「」 as “”. Keep punctuation natural for English.\n"
    "- Do NOT add a trailing period unless the source has one (「。」).\n"
    "- Buttons and labels stay short (1-3 words). Explanations can be a full sentence.\n"
    "- Use sentence case, not Title Case.\n"
    "- If a string is already English or is a code/identifier, return it unchanged.\n"
    "\n"
    "Output ONLY a JSON array, no prose, no markdown fence. Each element:\n"
    '{"zh": "<the exact source string>", "en": "<the translation>"}\n'
    "\n"
    "Strings:\n"
    + json.dumps(zhs, ensure_ascii=False, indent=0)
)

body = {"messages": [{"role": "user", "content": prompt}]}
json.dump(body, open(out, 'w', encoding='utf-8'), ensure_ascii=False)
print('wrote', out, len(zhs), 'strings')
