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

## Agent bubbles (`agent_hook.py`)
One hook script for every agent CLI: `/usr/bin/python3 -I /path/to/Orbi/mcp/agent_hook.py <agent> <event>`.

| Event | What you see | Claude Code | Gemini CLI |
|---|---|---|---|
| `prompt` | (remembers the start, closes open bubbles) | `UserPromptSubmit` | `BeforeAgent` |
| `stop` | "finished ✓" after turns ≥ 60 s (`ORBI_AGENT_MIN_SECONDS`) | `Stop` | `AfterAgent` |
| `stop --reply` | the same, plus Claude's last message and a reply field | `Stop` with `"asyncRewake": true` | – |
| `permission` | the command with Allow / Deny / Terminal | `PermissionRequest` | – |
| `wait` | sticky "needs you" until the agent continues | `Notification` (`elicitation_dialog\|agent_needs_input`) | `Notification` |
| `resume` | closes bubbles answered in the terminal | `PostToolUse` (behind a shell guard) | `AfterTool` |

How it works: the hook opens `orbi://ask?id=…`, Orbi shows the bubble and writes the answer to `~/Library/Application Support/Orbi/answers/<id>.json`, and the waiting hook returns it. A permission answer becomes the hook's `allow`/`deny` decision; ✕, **Terminal** or a 10-minute timeout fall back to the normal terminal prompt. A reply makes the async `Stop` hook exit 2 with the text, which wakes Claude.

Claude Code (`~/.claude/settings.json`), with `H` = `/usr/bin/python3 -I /path/to/Orbi/mcp/agent_hook.py claude`:
```json
"hooks": {
  "UserPromptSubmit":  [{ "hooks": [{ "type": "command", "command": "H prompt", "timeout": 10 }] }],
  "Stop":              [{ "hooks": [{ "type": "command", "command": "H stop --reply", "asyncRewake": true, "timeout": 3600 }] }],
  "PermissionRequest": [{ "hooks": [{ "type": "command", "command": "H permission", "timeout": 600 }] }],
  "Notification":      [{ "matcher": "elicitation_dialog|agent_needs_input", "hooks": [{ "type": "command", "command": "H wait", "timeout": 10 }] }],
  "PostToolUse":       [{ "hooks": [{ "type": "command", "command": "set -- \"${TMPDIR:-/tmp}\"/orbi-agent-hook/claude-*.pending.*; [ -e \"$1\" ] && exec H resume; echo \"{}\"", "timeout": 10 }] }]
}
```
The `PostToolUse` guard is plain shell, so Python only starts while a bubble is open.

Gemini CLI uses `prompt`, `stop`, `wait` and `resume` (`BeforeAgent`, `AfterAgent`, `Notification`, `AfterTool`; timeouts in ms). Codex: same as Claude's `UserPromptSubmit`/`Stop` in `~/.codex/hooks.json`, agent name `codex`. Tests: `/usr/bin/python3 -I mcp/test_agent_hook.py`.
