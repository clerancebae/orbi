<p align="center">
  <img src="docs/assets/icon.png" width="128" height="128" alt="Orbi icon">
</p>

<h1 align="center">Orbi</h1>

<p align="center">
  <b>The menu bar companion for people who work with AI agents.</b><br>
  Hand a long task to Claude Code, Codex or Gemini, walk away, and Orbi pings you when it's done.
</p>

<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-black">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-orange">
  <img alt="MCP" src="https://img.shields.io/badge/MCP-ready-8A2BE2">
  <img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-blue">
</p>

## Why

Working with agents means a lot of waiting. You start a run, switch to something else, and either keep checking the terminal or forget about it for 20 minutes. Orbi sits in the menu bar and fixes both:

1. **It tells you when the agent is done**, so you can stop watching the terminal.
2. **It fills the wait with what matters**: your next task, a glass of water, that article you saved.
3. **Your agent can see your day too.** Ask it to plan your tasks, log water or tell you what you read this week. Orbi speaks MCP.

## Features

### For your AI agents
- **Approve from the menu bar.** When Claude Code asks "may I run this?", a bubble shows the exact command with **Allow / Deny / Terminal**. No more switching windows to press Enter.
- **Read and reply without the terminal.** When a long turn ends, the bubble shows what Claude said. Type your next instruction right there (or hit **Continue**) and Claude picks it up.
- **"Agent finished" bubble.** A small bubble under the menu bar icon when Claude Code, Gemini CLI or Codex finishes a turn longer than a minute: *"Claude finished ✓ · my-project · 7 min"*. Short replies stay quiet.
- **MCP server.** Claude (Desktop and Code), Gemini CLI, Cursor, VS Code and any other MCP client can read your day and act on it: "plan my day: API docs 45m, review PR 20m", "start the next task", "save this link for later".
- **Ping on request.** In chats without hooks (Claude Desktop), say "notify me on Orbi when you're done" and the agent calls the `notify` tool.
- **Zero-setup server.** One Python file, standard library only, runs on the macOS system Python. It starts only when the agent needs it.

### For you, while the agent works
- **Tasks with a timer.** One active task with a countdown in the menu bar. Type `Write report 25m` to set an estimate. Tasks can be planned for later days.
- **Water and breaks.** Quiet reminders toward a daily goal. They skip calendar meetings.
- **Read later.** Save a link, close the tab, and get one gentle nudge a day to actually read it. Finished items are kept, so you can look back at what you read.
- **Scriptable.** Everything is reachable through `orbi://` URLs (Shortcuts, shell scripts, CI). The current state is written to a `status.json` file.

**Private by design:** a sandboxed SwiftUI + SwiftData app with no network access, no accounts and no analytics. It uses almost nothing while idle.

## Install

Requirements: macOS 14+, Xcode 26+, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
git clone https://github.com/clerancebae/orbi.git
cd orbi
# Use your own signing team and bundle prefix:
#   edit DEVELOPMENT_TEAM and bundleIdPrefix / com.berke.* in project.yml
scripts/install.sh   # Release build → /Applications/Orbi.app → launch
```

## Connect your AI assistant

The MCP server is a single Python file. It uses only the standard library and runs on the macOS system Python.

```sh
# Claude Code
claude mcp add --scope user orbi -- /usr/bin/python3 -I /path/to/orbi/mcp/orbi_mcp.py
```

Other clients (Claude Desktop, Gemini CLI, Cursor, VS Code, …):

```json
{ "mcpServers": { "orbi": { "command": "/usr/bin/python3", "args": ["-I", "/path/to/orbi/mcp/orbi_mcp.py"] } } }
```

Tools: `get_status`, `add_tasks`, `start_next_task`, `complete_active_task`, `log_water`, `undo_water`, `save_for_later`, `open_next_reading`, `notify`.

To get the "agent finished" bubble, wire `mcp/agent_hook.py` into your agent's hooks. For Claude Code, add this to `~/.claude/settings.json`:

```json
"hooks": {
  "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "/usr/bin/python3 -I /path/to/orbi/mcp/agent_hook.py claude prompt" }] }],
  "Stop":             [{ "hooks": [{ "type": "command", "command": "/usr/bin/python3 -I /path/to/orbi/mcp/agent_hook.py claude stop" }] }]
}
```

Setup for Gemini CLI and Codex is in [mcp/README.md](mcp/README.md).

## URL scheme

```sh
open -g "orbi://task/add?title=Review+PR&min=30&date=tomorrow"
open -g "orbi://task/start-next"
open -g "orbi://water/add"
open -g "orbi://reading/save?url=https%3A%2F%2Fexample.com"
open -g "orbi://notify?title=Build+done&message=All+green"
```

The full list is in [docs/DECISIONS.md](docs/DECISIONS.md).

## Development

See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for build, test and debugging notes, and [docs/DECISIONS.md](docs/DECISIONS.md) for why things are the way they are. The app icon is drawn in code: `swift scripts/make_icon.swift icon.png`.

## License

[MIT](LICENSE)
