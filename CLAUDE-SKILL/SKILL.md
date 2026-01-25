---
name: vibenotes
description: according to previous talkings, write learning notes for both beginner and experts into target location
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

1. **Summary** – Recall the current theme from the user or repo context. Shape it into a short working title plus a few high-level points. If you need more detail, pull it from the closest relevant files before writing the note.
2. **Locate** – Match the theme to an existing directory (e.g., `/linux/kernel/security`). If no good category exists, invent one that reflects the domain and treat it as the parent for this note.
3. **File Handling** – Create the directory tree if missing, pick a concise file name (use dashed lowercase words). Touch the file if it does not exist, but do not overwrite existing content without a reason.
4. **Write** – Append or replace the note content so it reflects the latest view. Keep the file extension `.md` and preserve any existing notes if you are adding a new topic.
> each markdown needs a [toc]
> If current source code workspace is a git repo, add footer comment about current  version (priority tag > remote branch > commit hash) and timestamp

## Note Structure

Each note should serve both beginners and experts:

- `### Beginner` – Explain the concept in approachable language, include simple analogies, and define key acronyms.
- `### Expert` – Summarize nuanced behavior, configuration flags, entropy considerations, or relevant code paths.
- `### Key takeaways` – Highlight actionable insights, warnings, or follow-ups the user should remember.
- `### References` – Mention the files or commands you used to gather context (for example, `/linux/kernel/security/kaslr-analysis.md`).

If the topic lends itself to examples, embed a short command snippet or reference path in the appropriate section.

## Quality and Resilience

- Before writing, confirm the directory path is accurate; default to `~/source/vibenotes` when `--dir` is omitted.
- Handle existing directories/files by reusing them; only create new ones when the topic truly needs a new container.
- If there is ambiguity about the scope, clarify with the user instead of guessing wildly.
- Balance the beginner and expert sections so both audiences get value without duplicating content.
- Mention or link the inputs (filesystem paths, commands, or documentation) you consulted when generating the note.

## Flag

`--org`: this is an option toggle vibenote skill to check vibenotes structure:
1. make sure files of same topic are not spread everywhere, assemble them in a directory
2. try to rename some directory or file, to make their name more exact 
3. notice, you need only read [toc] of each .md, for saving token and efficiency

`--dir: default to be ~/source/vibenotes`
