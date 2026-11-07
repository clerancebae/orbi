<p align="center">
  <img src="docs/assets/icon.png" width="128" height="128" alt="Orbi icon">
</p>

<h1 align="center">Orbi</h1>

<p align="center">
  A small macOS menu bar companion that keeps your day in orbit:<br>
  focused tasks, water breaks, read-later links, and a ping when your AI agent is done.
</p>

<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-black">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-orange">
  <img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-blue">
</p>

## Features

- **Tasks with a timer.** Plan today, start one task, and see the countdown in the menu bar. Type `Write report 25m` to set an estimate. Tasks can be planned for later days.
- **Water and breaks.** Quiet reminders toward a daily goal. They skip calendar meetings.
- **Read later.** Save a link, close the tab, and get one gentle nudge a day to actually read it. Finished items are kept, so you can look back at what you read.
- **Talks to AI assistants (MCP).** Claude, Gemini CLI, Cursor and any other MCP client can read your day and act on it: "plan my day", "log a glass of water", "what did I read this week?"
- **"Agent finished" bubble.** Start a long task in Claude Code, Gemini CLI or Codex, switch away, and Orbi pops a small bubble when the turn is done (only for turns over a minute).
- **Scriptable.** Everything is reachable through `orbi://` URLs (Touch Bar tools, Shortcuts, shell scripts). The current state is written to a `status.json` file.

Orbi is light by design. It's a sandboxed SwiftUI + SwiftData app with no network access, no accounts and no analytics. It uses almost nothing while idle.

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

Tools: `get_status`, `add_tasks`, `start_next_task`, `complete_active_task`, `log_water`, `undo_water`, `save_for_later`, `open_next_reading`.

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
