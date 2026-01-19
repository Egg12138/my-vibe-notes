---
name: vibenotes
description: according to previous talkings, write learning notes for both beginer and experts into target location
allowed-tools: Read,Find,Write,Grep,Edit,Bash
---

# Code & Concept Explanation Skill

Educational explanations with adaptive depth and format.

## Quick Start

```bash
# vibenote with specifying note target location
/vibenote  --dir ~/source/vibenotes
```

## Behavioral Flow

1. **Summary** - Based on memory, summary a theme
2. **Locate** - According to summary, find what directory current topic belongs to, if not, design a big category, and current topic should be under this category
3. **File Handling**: create directory, or touch file if needed
4. **WRite** - Write output to target file, extension is .md
> If current source code workspace is a git repo, add footer comment about current  version (priority tag > remote branch > commit hash)


## Flag

`--dir: default to be ~/source/vibenotes`

