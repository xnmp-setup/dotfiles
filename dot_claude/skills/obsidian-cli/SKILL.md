---
name: obsidian-cli
description: Interact with Obsidian vaults from the command line. Use when the user wants to create, read, search, move, or delete notes, manage tasks, daily notes, tags, properties, plugins, themes, sync, publish, or run eval/dev commands against an Obsidian vault.
allowed-tools: Bash(obsidian *)
---

# Obsidian CLI

Control Obsidian vaults from the terminal. Requires Obsidian desktop running (Settings > General > Command line interface > Register CLI).

## Command Reference

### Files & Folders

```bash
obsidian files                                    # list all files
obsidian files folder=Projects/Active             # files in folder
obsidian files ext=md format=json                 # filtered + JSON
obsidian files total                              # count notes
obsidian folders                                  # list folders
obsidian folders format=tree                      # tree view
obsidian read file="Note Name"                    # read by wikilink
obsidian read path="Projects/Note.md"             # read by path
obsidian create name="New Note"                   # create note
obsidian create name="S" path=Content/ template="YouTube Script"  # with template
obsidian create name="Q" content="# Idea" --silent               # silent
obsidian create name="E" content="new" --overwrite               # overwrite
obsidian append file="Research" content="New paragraph"          # append
obsidian prepend file="Inbox" content="- [ ] Item"               # prepend
obsidian append file="Log" content="Entry" --inline              # no trailing newline
obsidian move file="Draft" to=Archive/2026/       # move (updates links)
obsidian rename file="Old Name" name="New Name"   # rename
obsidian delete file="Old Note"                   # trash
obsidian delete file="Old Note" --permanent       # permanent delete
```

### Search

```bash
obsidian search query="topic"                           # full-text
obsidian search query="meeting" limit=20 format=json    # with options
obsidian search query="[tag:publish]"                   # by tag
obsidian search query="[tag:project] [tag:active]"      # multiple tags
obsidian search query="[status:active]"                 # by property
obsidian search query="[priority:>3]"                   # numeric comparison
obsidian search:open query="[tag:review]"               # open results in Obsidian
obsidian search:context query="term" limit=10           # search with context
```

### Daily Notes

```bash
obsidian daily                                    # open today's note
obsidian daily:read                               # read today's content
obsidian daily:read --copy                        # copy to clipboard
obsidian daily:append content="- [ ] Task"        # append to daily
obsidian daily:prepend content="## Morning"       # prepend to daily
obsidian daily:open date=2026-02-15               # specific date
obsidian daily:path                               # path to today's file
```

### Properties (YAML Frontmatter)

```bash
obsidian properties file="Project Alpha"                          # read all
obsidian properties:set file="Draft" status=active                # set property
obsidian properties:set file="A" published=2026-02-28 type=date   # typed
obsidian properties:set file="V" tags="pkm,obsidian" type=tags    # tags
obsidian properties:remove file="Draft" key=draft                 # remove
```

### Tags, Links & Backlinks

```bash
obsidian tags                        # all tags
obsidian tags sort=count             # sorted by frequency
obsidian tag tagname=pkm             # notes with tag
obsidian tags:rename old=mtg new=meetings  # rename across vault
obsidian links file="Note"           # outgoing links
obsidian backlinks file="Note"       # incoming links
obsidian unresolved                  # broken wikilinks
obsidian orphans                     # notes with zero links
```

### Tasks

```bash
obsidian tasks                                          # all tasks
obsidian tasks format=json                              # JSON output
obsidian tasks daily total                              # count daily tasks
obsidian task:create content="Write newsletter"         # create task
obsidian task:create content="Call" tags="work,urgent"  # with tags
obsidian task:complete task=task-id                      # complete task
```

### Plugins, Themes & Snippets

```bash
obsidian plugins                              # list plugins
obsidian plugin:enable id=dataview            # enable
obsidian plugin:disable id=calendar           # disable
obsidian plugin:reload id=my-dev-plugin       # reload (dev)
obsidian themes                               # list themes
obsidian theme:set name="Minimal"             # switch theme
obsidian snippets                             # list CSS snippets
obsidian snippet:enable name="custom-fonts"   # enable snippet
```

### Sync, Publish & History

```bash
obsidian sync:status                              # sync status
obsidian sync:history file="Note"                 # file sync history
obsidian sync:restore file="Note" version=3       # restore from sync
obsidian publish:list                             # published items
obsidian publish:add file="Ready Post"            # publish
obsidian publish:remove file="Outdated"           # unpublish
obsidian publish:status                           # publish status
obsidian history file="Note"                      # local file versions
obsidian history:read file="Note" version=2       # read version
obsidian history:restore file="Note" version=2    # restore version
```

### Developer / Eval

```bash
obsidian eval code="app.vault.getFiles().length"              # run JS
obsidian dev:screenshot path=~/Desktop/vault.png              # screenshot
obsidian dev:console limit=50                                 # console logs
obsidian dev:console level=error                              # errors only
obsidian dev:errors                                           # error monitoring
obsidian dev:css selector=".markdown-preview-view"            # CSS inspect
obsidian dev:dom selector=".workspace-leaf" total             # DOM inspect
```

### Misc

```bash
obsidian version          # CLI version
obsidian help             # help docs
obsidian                  # interactive TUI mode
```

## Global Flags

| Flag | Purpose |
|------|---------|
| `vault="Vault Name"` | Target specific vault (must be first arg) |
| `format=json\|csv\|md\|paths\|yaml\|tree\|tsv` | Output format |
| `limit=N` | Limit results |
| `--silent` | Suppress output |
| `--overwrite` | Overwrite existing files |
| `--permanent` | Permanent deletion (skip trash) |
| `--copy` | Copy output to clipboard |
| `--inline` | No trailing newline on append/prepend |

## TUI Mode Keys

Launch with bare `obsidian`. Keys: `↑↓` navigate, `Enter` open, `/` search, `Esc` clear, `n` new, `d` delete, `r` rename, `Tab` autocomplete, `q` quit.

## Guidelines

- Obsidian desktop must be running for the CLI to work.
- Use `format=json` when piping output to other tools or processing programmatically.
- Prefer `file="Name"` (wikilink) over `path=` unless the exact path matters.
- For bulk operations, combine with shell loops or pipe `obsidian files format=paths` to xargs.
- The `--overwrite` flag is destructive; confirm with the user before using it.
- `delete --permanent` is irreversible; prefer trash (default) unless explicitly asked.
