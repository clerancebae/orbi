#!/usr/bin/env python3
"""AI agent hook → Orbi bubbles, so you can follow and steer an agent from the menu bar.

Works with any agent whose hooks send JSON on stdin (session_id, cwd):

  agent_hook.py <agent> prompt          turn started   (Claude: UserPromptSubmit, Gemini: BeforeAgent)
  agent_hook.py <agent> stop [--reply]  turn finished  (Claude: Stop,             Gemini: AfterAgent)
  agent_hook.py <agent> permission      may I run X?   (Claude: PermissionRequest)
  agent_hook.py <agent> wait            needs the user (Claude: Notification,     Gemini: Notification)
  agent_hook.py <agent> resume          agent went on  (Claude: PostToolUse,      Gemini: AfterTool)

<agent> is a short name shown in the bubble: claude, gemini, codex, … (unknown names are capitalized).

- stop: for turns ≥ ORBI_AGENT_MIN_SECONDS (default 60). Plain: a "finished" bubble that closes itself.
  With --reply (Claude, hook set to `asyncRewake`): the bubble shows the agent's last message with a
  reply field. A reply is written to stderr and the hook exits 2, which wakes Claude with it.
- permission: an Allow / Deny / Terminal bubble. Allow or Deny is returned as the hook decision;
  Terminal, ✕ or a timeout returns nothing, so the normal terminal prompt applies.
- wait: a sticky "needs you" bubble until the agent continues. Idle reminders and auth notices are ignored.
- prompt / resume close this session's open bubbles (answered in the terminal). resume runs after every
  tool call, so its hook command first checks for a pending file in pure shell; Python only starts then.

Answers come back from Orbi as ~/Library/Application Support/Orbi/answers/<id>.json.
Never breaks the agent: on any error it exits 0 with "{}" on stdout (Gemini parses stdout as JSON).
Env: ORBI_AGENT_MIN_SECONDS, ORBI_AGENT_WAIT=0 (no "needs you"), ORBI_ASK_TIMEOUT (permission, s, 590),
     ORBI_REPLY_TIMEOUT (s, 3500), ORBI_ANSWERS_DIR, ORBI_HOOK_DRY_RUN=1 (print URLs to stderr; tests).
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
NAMES = {"claude": "Claude", "gemini": "Gemini", "codex": "Codex", "antigravity": "Antigravity",
         "cursor": "Cursor"}
# Notification types that don't mean "blocked on you right now".
IGNORED_NOTIFICATIONS = {"idle_prompt", "auth_success"}
POLL_SECONDS = 0.3


def safe(text, fallback):
    return re.sub(r"[^A-Za-z0-9_-]", "", text or "")[:80] or fallback


def duration_text(seconds):
    minutes = int(round(seconds / 60.0))
    if minutes < 60:
        return "%d min" % max(1, minutes)
    return "%d h %02d min" % (minutes // 60, minutes % 60)


def open_url(url):
    if DRY_RUN:
        sys.stderr.write(url + "\n")
        return
    subprocess.Popen(["/usr/bin/open", "-g", url], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def build_url(route, **params):
    query = "&".join("%s=%s" % (k, quote(str(v), safe="")) for k, v in params.items() if v)
    return "orbi://%s%s" % (route, ("?" + query) if query else "")


class Session:
    def __init__(self, agent, data):
        self.agent = safe(agent, "agent")
        self.id = safe(data.get("session_id"), "default")
        self.name = NAMES.get(agent.lower(), agent[:20].capitalize() or "Agent")
        self.project = os.path.basename((data.get("cwd") or os.getcwd()).rstrip("/")) or self.name

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


def ask(s, kind, title, message, detail, timeout):
    """Shows an interactive bubble and waits for the answer (None if it timed out)."""
    ask_id = uuid.uuid4().hex[:16]
    pending = s.add_pending(kind, ask_id)
    open_url(build_url("ask", id=ask_id, kind=kind, title=title, message=message, detail=detail))
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
    return 0, {}


def on_resume(s, data, flags):
    s.close_pending()
    return 0, {}


def on_wait(s, data, flags):
    kind = str(data.get("notification_type") or "")
    if not WAIT_ENABLED or kind in IGNORED_NOTIFICATIONS:
        return 0, {}
    detail = str(data.get("message") or "Waiting for your answer").strip()
    s.add_pending("wait")
    open_url(build_url("notify", title="%s needs you" % s.name,
                       message="%s · %s" % (s.project, detail[:200]), sticky=1))
    return 0, {}


def on_permission(s, data, flags):
    tool = str(data.get("tool_name") or "a tool")
    detail = describe_tool(tool, data.get("tool_input"))
    answer = ask(s, "permission", "%s wants to use %s" % (s.name, tool), s.project, detail[:3000], ASK_TIMEOUT)
    action = (answer or {}).get("action")
    if action == "allow":
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
    if started is None or time.time() - started < MIN_SECONDS:
        return 0, {}
    elapsed = duration_text(time.time() - started)
    title = "%s finished ✓" % s.name
    message = "%s · %s" % (s.project, elapsed)
    last = str(data.get("last_assistant_message") or "").strip()
    if "--reply" not in flags or not last:
        open_url(build_url("notify", title=title, message=message))
        return 0, {}
    answer = ask(s, "reply", title, message, last[:3000], REPLY_TIMEOUT)
    text = str((answer or {}).get("text") or "").strip()
    if (answer or {}).get("action") == "reply" and text:
        # asyncRewake: exit 2 wakes Claude and shows stderr to it.
        sys.stderr.write("The user replied from Orbi (menu bar), treat it as their next message:\n%s\n" % text)
        return 2, None
    return 0, {}


EVENTS = {"prompt": on_prompt, "resume": on_resume, "wait": on_wait,
          "permission": on_permission, "stop": on_stop}


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
    if out is not None:
        sys.stdout.write(json.dumps(out) + "\n")
    sys.stdout.flush()
    sys.exit(code)
