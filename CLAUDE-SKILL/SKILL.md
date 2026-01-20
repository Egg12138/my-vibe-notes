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
2. **Check AND Reorgnize** - According to summary, find what directory current topic belongs to, if not, design a big category, and current topic should be under this category. If there is some files about current topic, consider is it needed to relocate them:
>> if previous notes are a single file, try to mkdir to store new notes and the previous notes with the same topic
3. **File Handling**: create directory, or touch file if needed
4. **Write** - Write output to target file, extension is .md
> each markdown needs a [toc]
> If current source code workspace is a git repo, add footer comment about current  version (priority tag > remote branch > commit hash) and timestamp


## Flag

`--org`: this is an option toggle vibenote skill to check vibenotes structure:
1. make sure files of same topic are not spread everywhere, assemble them in a directory
2. try to rename some directory or file, to make their name more exact 
3. notice, you need only read [toc] of each .md, for saving token and efficiency

`--dir: default to be ~/source/vibenotes`

