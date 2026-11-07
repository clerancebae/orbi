#!/usr/bin/env python3
"""AI agent hook → Orbi "<Agent> finished" bubble, only for long turns.

Works with any agent whose hooks send JSON on stdin (session_id, cwd):

  agent_hook.py <agent> prompt   turn started  (Claude/Codex: UserPromptSubmit, Gemini: BeforeAgent)
  agent_hook.py <agent> stop     turn finished (Claude/Codex: Stop,             Gemini: AfterAgent)

<agent> is a short name shown in the bubble: claude, gemini, codex, … (unknown names are capitalized).
If the turn took ≥ ORBI_AGENT_MIN_SECONDS (default 60) it opens orbi://notify in the background.

Never blocks the agent: always exits 0 quickly; stdout is only "{}" (Gemini parses stdout as JSON).
Env: ORBI_AGENT_MIN_SECONDS,
     ORBI_HOOK_DRY_RUN=1 (print the URL to stderr instead of opening it; tests).
"""
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from urllib.parse import quote

MIN_SECONDS = int(os.environ.get("ORBI_AGENT_MIN_SECONDS") or "60")
STATE_DIR = os.path.join(tempfile.gettempdir(), "orbi-agent-hook")
NAMES = {"claude": "Claude", "gemini": "Gemini", "codex": "Codex", "antigravity": "Antigravity",
         "cursor": "Cursor"}


def safe(text, fallback):
    return re.sub(r"[^A-Za-z0-9_-]", "", text or "")[:80] or fallback


def state_path(agent, session_id):
    return os.path.join(STATE_DIR, "%s-%s.start" % (safe(agent, "agent"), safe(session_id, "default")))


def duration_text(seconds):
    minutes = int(round(seconds / 60.0))
    if minutes < 60:
        return "%d min" % max(1, minutes)
    return "%d h %02d min" % (minutes // 60, minutes % 60)


def main(agent, event):
    try:
        data = json.load(sys.stdin)
    except ValueError:
        data = {}
    if not isinstance(data, dict):
        data = {}
    path = state_path(agent, data.get("session_id"))

    if event == "prompt":
        os.makedirs(STATE_DIR, exist_ok=True)
        with open(path, "w") as f:
            f.write(str(time.time()))
        return

    if event == "stop":
        try:
            with open(path) as f:
                started = float(f.read().strip())
            os.remove(path)
        except (OSError, ValueError):
            return  # no recorded start (e.g. hook added mid-session)
        elapsed = time.time() - started
        if elapsed < MIN_SECONDS:
            return
        name = NAMES.get(agent.lower(), agent[:20].capitalize() or "Agent")
        project = os.path.basename((data.get("cwd") or os.getcwd()).rstrip("/")) or name
        url = "orbi://notify?title=%s&message=%s" % (
            quote("%s finished ✓" % name, safe=""),
            quote("%s · %s" % (project, duration_text(elapsed)), safe=""))
        if os.environ.get("ORBI_HOOK_DRY_RUN") == "1":
            sys.stderr.write(url + "\n")
            return
        subprocess.Popen(["/usr/bin/open", "-g", url],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


if __name__ == "__main__":
    args = sys.argv[1:]
    try:
        main(args[0] if args else "agent", args[1] if len(args) > 1 else "")
    except Exception:
        pass  # a hook must never break the agent
    sys.stdout.write("{}\n")
    sys.exit(0)
