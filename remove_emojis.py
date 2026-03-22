#!/usr/bin/env python3
"""Remove emojis from markdown files"""
import re
from pathlib import Path

# Common emojis to remove
EMOJIS = [
    '✅', '❌', '⚠️', '🔬', '📊', '📘', '📕', '🎯', '⚡', '🎓',
    '📖', '🆓', '🚀', '✨', '📝', '🛡️', '🏷️', '🟢', '🔵',
    '→', '←', '↔️', '✓', '×'
]

def remove_emojis(text):
    """Remove all emojis from text"""
    for emoji in EMOJIS:
        text = text.replace(emoji, '')
    # Remove extra spaces left by emoji removal
    text = re.sub(r' +', ' ', text)
    text = re.sub(r'^ ', '', text, flags=re.MULTILINE)
    return text

def main():
    files = [
        'README.md',
        'BENCHMARKS.md',
        'COMPARISON.md',
        'FEATURES.md',
        'VALIDATION_SUMMARY.md'
    ]

    for filename in files:
        path = Path(filename)
        if not path.exists():
            continue

        content = path.read_text(encoding='utf-8')
        cleaned = remove_emojis(content)

        if content != cleaned:
            path.write_text(cleaned, encoding='utf-8')
            print(f'Cleaned: {filename}')

if __name__ == '__main__':
    main()
