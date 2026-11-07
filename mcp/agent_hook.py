#!/usr/bin/env python3
"""AI agent hook → Orbi bubbles, so you can follow and steer an agent from the menu bar.

Works with any agent whose hooks send JSON on stdin (session_id, cwd):

  agent_hook.py <agent> prompt          turn started   (Claude: UserPromptSubmit, Gemini: BeforeAgent)
  agent_hook.py <agent> stop [--reply]  turn finished  (Claude: Stop,             Gemini: AfterAgent)
  agent_hook.py <agent> permission      may I run X?   (Claude: PermissionRequest)
  agent_hook.py <agent> wait            needs the user (Claude: Notification,     Gemini: Notification)
  agent_hook.py <agent> resume          agent went on  (Claude: PostToolUse,      Gemini: AfterTool)
  agent_hook.py <agent> statusline      status line    (Claude: statusLine command)

<agent> is a short name shown in the bubble: claude, gemini, codex, … (unknown names are capitalized).

- stop: every turn is logged in Orbi's Agents list (`orbi://agent/log`, no bubble). Turns
  ≥ ORBI_AGENT_MIN_SECONDS (default 60) also get a "finished" bubble that closes itself.
  With --reply (Claude, hook set to `asyncRewake`): the bubble shows the agent's last message with a
  reply field. A reply is written to stderr and the hook exits 2, which wakes Claude with it.
- permission: an Allow / Deny / Terminal bubble (plus Always when Claude suggests a "don't ask again"
  rule; it applies those rules via `updatedPermissions`). Allow or Deny is returned as the hook decision;
  Terminal, ✕ or a timeout returns nothing, so the normal terminal prompt applies.
- prompt: marks the session as running (menu bar 🤖) and closes this session's open bubbles.
- wait: a sticky "needs you" bubble until the agent continues. `idle_prompt` instead ends the running
  state (covers turns interrupted with Esc, where Stop doesn't fire). Auth notices are ignored.
- stop also counts the turn's tokens from the transcript (Claude: input + cache writes + output; Gemini:
  input − cached + output + thoughts; cache reads left out, they'd dwarf the rest) for the bubble and
  Orbi's day total.
- stop (Claude): a message queued in Orbi while the turn ran (queue/<session>.txt) is sent as the next
  prompt right away (exit 2 with --reply, else a blocking Stop decision) and logged as a reply.
- statusline: prints "5h 23% · 7d 41%" for Claude's status line and sends the plan limits (rate_limits,
  Claude.ai plans only) to Orbi as `orbi://usage`, only when a rounded value changes.
- The host app (`__CFBundleIdentifier` / `TERM_PROGRAM`) is passed along, so Orbi's ↗ brings it forward.
- prompt / resume close this session's open bubbles (answered in the terminal). resume runs after every
  tool call, so its hook command first checks for a pending file in pure shell; Python only starts then.

Answers come back from Orbi as ~/Library/Application Support/Orbi/answers/<id>.json.
Never breaks the agent: on any error it exits 0 with "{}" on stdout (Gemini parses stdout as JSON).
Env: ORBI_AGENT_MIN_SECONDS, ORBI_AGENT_WAIT=0 (no "needs you"), ORBI_ASK_TIMEOUT (permission, s, 590),
     ORBI_REPLY_TIMEOUT (s, 3500), ORBI_ANSWERS_DIR, ORBI_QUEUE_DIR, ORBI_HOOK_DRY_RUN=1 (print URLs to stderr; tests).
"""
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import uuid
from urllib.parse import quote

MIN_SECONDS = int(os.environ.get("ORBI_AGENT_MIN_SECONDS") or "60")
WAIT_ENABLED = os.environ.get("ORBI_AGENT_WAIT", "1") != "0"
ASK_TIMEOUT = float(os.environ.get("ORBI_ASK_TIMEOUT") or "590")
REPLY_TIMEOUT = float(os.environ.get("ORBI_REPLY_TIMEOUT") or "3500")
DRY_RUN = os.environ.get("ORBI_HOOK_DRY_RUN") == "1"
STATE_DIR = os.path.join(tempfile.gettempdir(), "orbi-agent-hook")
ANSWERS_DIR = os.environ.get("ORBI_ANSWERS_DIR") or os.path.expanduser(
    "~/Library/Application Support/Orbi/answers")
# Messages queued in Orbi while a turn runs: queue/<session>.txt, sent when the turn ends.
QUEUE_DIR = os.environ.get("ORBI_QUEUE_DIR") or os.path.join(os.path.dirname(ANSWERS_DIR), "queue")
MAX_QUEUED = 4000
NAMES = {"claude": "Claude", "gemini": "Gemini", "codex": "Codex", "antigravity": "Antigravity",
         "cursor": "Cursor", "opencode": "OpenCode"}
# Notification types that don't mean "blocked on you right now".
IGNORED_NOTIFICATIONS = {"idle_prompt", "auth_success"}
POLL_SECONDS = 0.3


def safe(text, fallback):
    return re.sub(r"[^A-Za-z0-9_-]", "", text or "")[:80] or fallback


def duration_text(seconds):
    if seconds < 60:
        return "%d s" % max(1, int(seconds))
    minutes = int(round(seconds / 60.0))
    if minutes < 60:
        return "%d min" % max(1, minutes)
    return "%d h %02d min" % (minutes // 60, minutes % 60)


def token_text(n):
    if n >= 1_000_000:
        return "%.1fM tokens" % (n / 1_000_000.0)
    if n >= 1000:
        return "%dk tokens" % int(round(n / 1000.0))
    return "%d tokens" % n


def parse_time(value):
    """Epoch seconds from a number or an ISO 8601 string, else None."""
    if isinstance(value, (int, float)) and value > 0:
        return float(value) / (1000.0 if value > 1e11 else 1.0)
    if isinstance(value, str) and value:
        from datetime import datetime
        try:
            return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
        except ValueError:
            return None
    return None


TRANSCRIPT_TAIL = 8 * 1024 * 1024


def gemini_tokens(conversation, since):
    """Gemini CLI transcript: one JSON object, `messages[].tokens` on its replies."""
    total = 0
    for message in reversed(conversation.get("messages") or []):
        if not isinstance(message, dict):
            continue
        stamp = parse_time(message.get("timestamp"))
        if stamp is not None and stamp < since - 1:
            break
        tokens = message.get("tokens")
        if message.get("type") != "gemini" or not isinstance(tokens, dict):
            continue
        n = lambda k: tokens.get(k) if isinstance(tokens.get(k), int) else 0
        total += max(0, n("input") - n("cached")) + n("output") + n("thoughts")
    return total


def turn_tokens(path, since):
    """Tokens of the replies logged at or after `since` (epoch) in a Claude (JSON lines) or Gemini
    (one JSON object) transcript. Each Claude API response is counted once (it spans several lines)."""
    if not path or since is None:
        return None
    try:
        with open(path, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - TRANSCRIPT_TAIL))
            data = f.read()
    except OSError:
        return None
    if size <= TRANSCRIPT_TAIL and data.lstrip()[:1] == b"{":
        try:
            whole = json.loads(data)
            if isinstance(whole, dict) and isinstance(whole.get("messages"), list):
                return gemini_tokens(whole, since)
        except ValueError:
            pass
    lines = data.splitlines()
    seen, total = set(), 0
    for raw in reversed(lines):
        try:
            entry = json.loads(raw)
        except ValueError:
            continue
        if not isinstance(entry, dict):
            continue
        stamp = parse_time(entry.get("timestamp"))
        if stamp is not None and stamp < since - 1:
            break
        message = entry.get("message")
        if entry.get("type") != "assistant" or not isinstance(message, dict):
            continue
        usage = message.get("usage")
        key = message.get("id") or entry.get("requestId") or entry.get("uuid")
        if not isinstance(usage, dict) or key in seen:
            continue
        seen.add(key)
        for field in ("input_tokens", "cache_creation_input_tokens", "output_tokens"):
            value = usage.get(field)
            if isinstance(value, int) and value > 0:
                total += value
    return total


def open_url(url):
    if DRY_RUN:
        sys.stderr.write(url + "\n")
        return
    subprocess.Popen(["/usr/bin/open", "-g", url], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def build_url(route, **params):
    query = "&".join("%s=%s" % (k, quote(str(v), safe="")) for k, v in params.items() if v not in (None, ""))
    return "orbi://%s%s" % (route, ("?" + query) if query else "")


# TERM_PROGRAM → bundle id, for terminals launched without __CFBundleIdentifier (e.g. via ssh/tmux).
TERM_APPS = {"Apple_Terminal": "com.apple.Terminal", "iTerm.app": "com.googlecode.iterm2",
             "vscode": "com.microsoft.VSCode", "ghostty": "com.mitchellh.ghostty",
             "WezTerm": "com.github.wez.wezterm", "WarpTerminal": "dev.warp.Warp-Stable"}


def host_app():
    """Bundle id of the terminal / IDE this agent runs in, for Orbi's "go to project" (↗)."""
    app = os.environ.get("__CFBundleIdentifier") or TERM_APPS.get(os.environ.get("TERM_PROGRAM", ""), "")
    return app if re.match(r"^[A-Za-z0-9.-]{1,155}$", app or "") else None


class Session:
    def __init__(self, agent, data):
        self.agent = safe(agent, "agent")
        self.id = safe(data.get("session_id"), "default")
        self.name = NAMES.get(agent.lower(), agent[:20].capitalize() or "Agent")
        self.project = os.path.basename((data.get("cwd") or os.getcwd()).rstrip("/")) or self.name
        self.app = host_app()

    def context(self, seconds=None, tokens=None):
        """Agent fields Orbi uses for the running list, "go to project" and the day summary."""
        return {"session": "%s-%s" % (self.agent, self.id), "agent": self.name, "project": self.project,
                "app": self.app, "seconds": int(seconds) if seconds is not None else None,
                "tokens": tokens}

    def path(self, ext):
        return os.path.join(STATE_DIR, "%s-%s.%s" % (self.agent, self.id, ext))

    # A turn's start time, for the "finished" bubble.
    def mark_start(self):
        os.makedirs(STATE_DIR, exist_ok=True)
        with open(self.path("start"), "w") as f:
            f.write(str(time.time()))

    def take_start(self):
        try:
            with open(self.path("start")) as f:
                started = float(f.read().strip())
            os.remove(self.path("start"))
            return started
        except (OSError, ValueError):
            return None  # no recorded start (e.g. hook added mid-session)

    def take_queued(self):
        """The message queued in Orbi for this session (removed once read), or None."""
        path = os.path.join(QUEUE_DIR, self.context()["session"] + ".txt")
        try:
            with open(path, encoding="utf-8") as f:
                text = f.read().strip()[:MAX_QUEUED]
            os.remove(path)
        except (OSError, ValueError):
            return None
        return text or None

    # Open bubbles of this session: {"kind": "wait"|"permission"|"reply", "id": ask id}.
    # File name `<agent>-<session>.pending.<n>` lets the resume guard test `<agent>-*.pending.*`.
    def add_pending(self, kind, ask_id=""):
        os.makedirs(STATE_DIR, exist_ok=True)
        path = "%s.pending.%s" % (self.path(""), ask_id or kind)
        with open(path, "w") as f:
            json.dump({"kind": kind, "id": ask_id}, f)
        return path

    def close_pending(self):
        """Closes every open bubble of this session (answered or continued elsewhere)."""
        prefix = os.path.basename(self.path("")) + ".pending."
        try:
            names = [n for n in os.listdir(STATE_DIR) if n.startswith(prefix)]
        except OSError:
            return
        for name in names:
            path = os.path.join(STATE_DIR, name)
            try:
                with open(path) as f:
                    item = json.load(f)
                os.remove(path)
            except (OSError, ValueError):
                continue
            if item.get("kind") == "wait":
                open_url("orbi://notify/dismiss")
            elif item.get("id"):
                write_answer(item["id"], "cancelled")  # wakes the hook that waits for it
                open_url(build_url("ask/cancel", id=item["id"]))


def write_answer(ask_id, action):
    try:
        os.makedirs(ANSWERS_DIR, exist_ok=True)
        tmp = os.path.join(ANSWERS_DIR, ".%s.tmp" % ask_id)
        with open(tmp, "w") as f:
            json.dump({"id": ask_id, "action": action}, f)
        os.replace(tmp, os.path.join(ANSWERS_DIR, ask_id + ".json"))
    except OSError:
        pass


def wait_answer(ask_id, timeout):
    """Polls for Orbi's answer. Returns {"action": ..., "text": ...} or None on timeout."""
    path = os.path.join(ANSWERS_DIR, ask_id + ".json")
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with open(path) as f:
                answer = json.load(f)
            os.remove(path)
            return answer if isinstance(answer, dict) else None
        except (OSError, ValueError):
            time.sleep(POLL_SECONDS)
    return None


def ask(s, kind, title, message, detail, timeout, seconds=None, always=None, tokens=None):
    """Shows an interactive bubble and waits for the answer (None if it timed out)."""
    ask_id = uuid.uuid4().hex[:16]
    pending = s.add_pending(kind, ask_id)
    open_url(build_url("ask", id=ask_id, kind=kind, title=title, message=message, detail=detail,
                       always=always, **s.context(seconds, tokens)))
    answer = wait_answer(ask_id, timeout)
    try:
        os.remove(pending)
    except OSError:
        pass
    if answer is None:
        open_url(build_url("ask/cancel", id=ask_id))
    return answer


def describe_tool(tool, tool_input):
    if not isinstance(tool_input, dict):
        return ""
    for key in ("command", "file_path", "path", "url", "pattern", "query"):
        if tool_input.get(key):
            return str(tool_input[key])
    return json.dumps(tool_input, ensure_ascii=False)[:600]


# ---------------------------------------------------------------- events
# Each returns (exit code, stdout object).

def on_prompt(s, data, flags):
    s.close_pending()
    s.mark_start()
    open_url(build_url("agent/start", **s.context()))
    return 0, {}


def on_resume(s, data, flags):
    s.close_pending()
    return 0, {}


def on_wait(s, data, flags):
    kind = str(data.get("notification_type") or "")
    if kind == "idle_prompt":
        # Idle for a minute: the turn is over even if Stop never fired (e.g. interrupted with Esc).
        open_url(build_url("agent/stop", session=s.context()["session"]))
        return 0, {}
    if not WAIT_ENABLED or kind in IGNORED_NOTIFICATIONS:
        return 0, {}
    detail = str(data.get("message") or "Waiting for your answer").strip()
    s.add_pending("wait")
    open_url(build_url("notify", title="%s needs you" % s.name,
                       message="%s · %s" % (s.project, detail[:200]), sticky=1, app=s.app))
    return 0, {}


def rule_label(suggestions):
    """`Bash(npm test:*)` from Claude's first "don't ask again" suggestion, or None."""
    for suggestion in suggestions if isinstance(suggestions, list) else []:
        if not isinstance(suggestion, dict) or suggestion.get("behavior") != "allow":
            continue
        for rule in suggestion.get("rules") or []:
            if isinstance(rule, dict) and rule.get("toolName"):
                content = rule.get("ruleContent")
                return "%s(%s)" % (rule["toolName"], content) if content else str(rule["toolName"])
    return None


def on_permission(s, data, flags):
    tool = str(data.get("tool_name") or "a tool")
    detail = describe_tool(tool, data.get("tool_input"))
    suggestions = data.get("permission_suggestions")
    always = rule_label(suggestions)
    answer = ask(s, "permission", "%s wants to use %s" % (s.name, tool), s.project, detail[:3000], ASK_TIMEOUT,
                 always=always)
    action = (answer or {}).get("action")
    if action == "always" and always:
        # Same as picking "Yes, and don't ask again" in the terminal: Claude's own suggested rules.
        return 0, {"hookSpecificOutput": {"hookEventName": "PermissionRequest",
                                          "decision": {"behavior": "allow",
                                                       "updatedPermissions": [x for x in suggestions
                                                                              if isinstance(x, dict)
                                                                              and x.get("behavior") == "allow"]}}}
    if action in ("allow", "always"):
        return 0, {"hookSpecificOutput": {"hookEventName": "PermissionRequest",
                                          "decision": {"behavior": "allow"}}}
    if action == "deny":
        return 0, {"hookSpecificOutput": {"hookEventName": "PermissionRequest",
                                          "decision": {"behavior": "deny",
                                                       "message": "The user denied this from Orbi (menu bar)."}}}
    return 0, {}  # terminal / dismissed / timed out → the normal prompt


def on_stop(s, data, flags):
    s.close_pending()
    started = s.take_start()
    elapsed = time.time() - started if started is not None else None
    long_turn = elapsed is not None and elapsed >= MIN_SECONDS
    tokens = turn_tokens(data.get("transcript_path"), started)
    title = "%s finished ✓" % s.name
    message = s.project + (" · %s" % duration_text(elapsed) if elapsed is not None else "")
    if tokens:
        message += " · %s" % token_text(tokens)
    # Claude: last_assistant_message; Gemini AfterAgent: prompt_response.
    last = str(data.get("last_assistant_message") or data.get("prompt_response") or "").strip()

    # A message queued in Orbi while the turn ran goes out now, whatever the turn's length.
    # Only Claude can be woken this way (asyncRewake exit 2, or a blocking Stop decision).
    queued = s.take_queued() if s.agent == "claude" else None
    if queued:
        open_url(build_url("agent/log", title=title, subtitle=message, detail=last[:3000], reply=queued,
                           **s.context(elapsed, tokens)))
        s.mark_start()  # the follow-up turn starts now
        text = "The user queued this in Orbi (menu bar) while you worked, treat it as their next message:\n%s" % queued
        if "--reply" in flags:
            sys.stderr.write(text + "\n")
            return 2, None
        return 0, {"decision": "block", "reason": text}

    if long_turn and "--reply" in flags and last:
        # Orbi logs the ask itself (and your reply) in its Agents list.
        answer = ask(s, "reply", title, message, last[:3000], REPLY_TIMEOUT, seconds=elapsed, tokens=tokens)
        text = str((answer or {}).get("text") or "").strip()
        if (answer or {}).get("action") == "reply" and text:
            # asyncRewake: exit 2 wakes Claude and shows stderr to it.
            sys.stderr.write("The user replied from Orbi (menu bar), treat it as their next message:\n%s\n" % text)
            s.mark_start()  # the follow-up turn starts now
            return 2, None
        return 0, {}

    if long_turn:
        open_url(build_url("notify", title=title, message=message, app=s.app))
    # Every turn lands in Orbi's Agents list (bubble or not) and ends the "running" state.
    open_url(build_url("agent/log", title=title, subtitle=message, detail=last[:3000],
                       **s.context(elapsed, tokens)))
    return 0, {}


def limit_window(limits, key):
    """(used %, reset epoch) of one rate-limit window, or (None, None)."""
    window = limits.get(key) if isinstance(limits, dict) else None
    if not isinstance(window, dict):
        return None, None
    used = window.get("used_percentage")
    if not isinstance(used, (int, float)):
        return None, None
    return max(0.0, min(100.0, float(used))), parse_time(window.get("resets_at"))


def on_statusline(s, data, flags):
    """Claude's status line: plan limits as text, and to Orbi when they change."""
    limits = data.get("rate_limits")
    five, five_reset = limit_window(limits, "five_hour")
    week, week_reset = limit_window(limits, "seven_day")
    parts = []
    if five is not None:
        parts.append("5h %d%%" % round(five))
    if week is not None:
        parts.append("7d %d%%" % round(week))
    if parts:
        url = build_url("usage", five=round(five) if five is not None else None,
                        five_reset=int(five_reset) if five_reset else None,
                        week=round(week) if week is not None else None,
                        week_reset=int(week_reset) if week_reset else None)
        last_path = os.path.join(STATE_DIR, "usage.last")
        try:
            with open(last_path) as f:
                changed = f.read() != url
        except OSError:
            changed = True
        if changed:
            try:
                os.makedirs(STATE_DIR, exist_ok=True)
                with open(last_path, "w") as f:
                    f.write(url)
            except OSError:
                pass
            open_url(url)
    return 0, " · ".join(parts)


EVENTS = {"prompt": on_prompt, "resume": on_resume, "wait": on_wait,
          "permission": on_permission, "stop": on_stop, "statusline": on_statusline}


def main(argv):
    agent = argv[0] if argv else "agent"
    event = argv[1] if len(argv) > 1 else ""
    try:
        data = json.load(sys.stdin)
    except ValueError:
        data = {}
    if not isinstance(data, dict):
        data = {}
    handler = EVENTS.get(event)
    if handler is None:
        return 0, {}
    return handler(Session(agent, data), data, argv[2:])


if __name__ == "__main__":
    code, out = 0, {}
    try:
        code, out = main(sys.argv[1:])
    except Exception:
        code, out = 0, {}  # a hook must never break the agent
    if isinstance(out, str):
        sys.stdout.write(out + "\n")  # status line text
    elif out is not None:
        sys.stdout.write(json.dumps(out) + "\n")
    sys.stdout.flush()
    sys.exit(code)
