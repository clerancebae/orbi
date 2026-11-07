# Orbi MCP server

Lets Claude (Desktop and Code) read your Orbi state and act on it.
One file, Python standard library only, runs on the macOS system Python (`/usr/bin/python3`, 3.9).
Claude starts it on demand over stdio; it uses nothing while idle.

## Tools
| Tool | What it does | Under the hood |
|---|---|---|
| `get_status` | Today's tasks, active task + time left, later-day tasks, water, next event, read-later + recently read | reads `status.json` |
| `add_tasks` | Add 1–30 tasks (title, optional `minutes`, optional `date`: today / tomorrow / YYYY-MM-DD) | `orbi://task/add` |
| `start_next_task`, `complete_active_task` | Task timer control | `orbi://task/start-next`, `task/complete` |
| `log_water`, `undo_water` | Water | `orbi://water/add`, `water/undo` |
| `save_for_later`, `open_next_reading` | Read later | `orbi://reading/save`, `reading/open-next` |
| `notify` | Show a bubble under the menu bar icon (e.g. "Claude finished ✓" when asked to ping at the end) | `orbi://notify` (doesn't wait for `status.json`) |

Actions open URLs with `open -g` (nothing comes to the front), then wait up to 2.5 s for Orbi to rewrite `status.json` and return the new state, so Claude can confirm what happened.

## Registration
- **Claude Code** (user scope): `claude mcp add --scope user orbi -- /usr/bin/python3 -I /path/to/Orbi/mcp/orbi_mcp.py`
- **Gemini CLI**: `mcpServers.orbi` in `~/.gemini/settings.json`. Check with `gemini mcp list` (needs a real terminal to print).
- **Any other MCP client** (IntelliJ AI Assistant, Android Studio Gemini, Cursor, VS Code, …): add a stdio server with this JSON:
  ```json
  { "mcpServers": { "orbi": { "command": "/usr/bin/python3", "args": ["-I", "/path/to/Orbi/mcp/orbi_mcp.py"] } } }
  ```
- **Claude Desktop**: `mcpServers.orbi` in `~/Library/Application Support/Claude/claude_desktop_config.json`. Restart Claude Desktop to load it.

## "<Agent> finished" bubble (`agent_hook.py`)
One hook script for every agent CLI. It remembers when a turn starts and, if the turn took ≥ 60 s (`ORBI_AGENT_MIN_SECONDS`), shows an Orbi bubble like "Gemini finished ✓ · Orbi · 4 min".

`/usr/bin/python3 -I /path/to/Orbi/mcp/agent_hook.py <agent> prompt|stop`

| Agent | Turn start → `prompt` | Turn end → `stop` | Config |
|---|---|---|---|
| Claude Code | `UserPromptSubmit` | `Stop` | `hooks` in `~/.claude/settings.json` |
| Gemini CLI | `BeforeAgent` | `AfterAgent` | `hooks` in `~/.gemini/settings.json` (timeout is in ms) |
| Codex CLI | `UserPromptSubmit` | `Stop` | Codex hooks (`~/.codex/hooks.json`, same shape as Claude's), agent name `codex` |

Any other agent whose hooks pass JSON with `session_id`/`cwd` on stdin works the same way; the name is just shown in the bubble. Antigravity is an IDE without a documented command hook, so it isn't wired.
