"""Tests for agent_hook.py. Run: /usr/bin/python3 -I mcp/test_agent_hook.py
Dry-run mode with private temp/answer folders, so nothing is sent to Orbi."""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from urllib.parse import parse_qs, urlparse

HOOK = os.path.join(os.path.dirname(os.path.abspath(__file__)), "agent_hook.py")
S1 = {"session_id": "s1", "cwd": "/x/Orbi"}


class Tests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.answers = os.path.join(self.tmp, "answers")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def env(self, **extra):
        base = dict(os.environ, TMPDIR=self.tmp, ORBI_ANSWERS_DIR=self.answers, ORBI_HOOK_DRY_RUN="1")
        base.pop("__CFBundleIdentifier", None)  # no host app unless a test sets one
        base.pop("TERM_PROGRAM", None)
        base.update(extra)
        return base

    def run_hook(self, agent, event, data, *flags, **env):
        p = subprocess.run([sys.executable, "-I", HOOK, agent, event] + list(flags), input=json.dumps(data),
                           capture_output=True, text=True, env=self.env(**env), timeout=20)
        return p.returncode, p.stdout.strip(), [l for l in p.stderr.splitlines() if l.startswith("orbi://")]

    def start_hook(self, agent, event, data, *flags, **env):
        p = subprocess.Popen([sys.executable, "-I", HOOK, agent, event] + list(flags), stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=self.env(**env))
        p.stdin.write(json.dumps(data))
        p.stdin.close()
        return p

    @staticmethod
    def finish(p):
        p.wait(timeout=10)
        out, err = p.stdout.read(), p.stderr.read()
        p.stdout.close()
        p.stderr.close()
        return out, err

    def wait_for_ask(self, proc):
        """Reads the ask URL the waiting hook printed; returns its query."""
        line = proc.stderr.readline().strip()
        while line.startswith("orbi://agent/"):
            line = proc.stderr.readline().strip()
        self.assertTrue(line.startswith("orbi://ask?"), line)
        return {k: v[0] for k, v in parse_qs(urlparse(line).query).items()}

    def answer(self, ask_id, action, text=None):
        os.makedirs(self.answers, exist_ok=True)
        with open(os.path.join(self.answers, ask_id + ".json"), "w") as f:
            json.dump({"id": ask_id, "action": action, "text": text} if text else {"id": ask_id, "action": action}, f)

    def pending(self):
        d = os.path.join(self.tmp, "orbi-agent-hook")
        return sorted(n for n in os.listdir(d) if ".pending." in n) if os.path.isdir(d) else []

    # ---------------------------------------------------------------- finished

    def test_short_turn_is_quiet_long_turn_notifies(self):
        self.assertEqual(self.run_hook("claude", "prompt", S1),
                         (0, "{}", ["orbi://agent/start?session=claude-s1&agent=Claude&project=Orbi"]))
        code, out, urls = self.run_hook("claude", "stop", S1, "--reply")
        self.assertEqual(len(urls), 1)  # no bubble, just the log entry that ends "running"
        self.assertTrue(urls[0].startswith("orbi://agent/log?title=Claude%20finished"))
        self.assertIn("session=claude-s1", urls[0])
        self.run_hook("gemini", "prompt", S1)
        code, out, urls = self.run_hook("gemini", "stop", dict(S1, prompt_response="All done."),
                                        ORBI_AGENT_MIN_SECONDS="0")
        self.assertEqual(urls[0], "orbi://notify?title=Gemini%20finished%20%E2%9C%93&message=Orbi%20%C2%B7%201%20s")
        self.assertEqual(urls[1], "orbi://agent/log?title=Gemini%20finished%20%E2%9C%93"
                                  "&subtitle=Orbi%20%C2%B7%201%20s&detail=All%20done."
                                  "&session=gemini-s1&agent=Gemini&project=Orbi&seconds=0")

    def test_turn_tokens_from_transcript(self):
        old = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(time.time() - 3600))
        def line(ts, mid, inp, cw, cr, out):
            return json.dumps({"type": "assistant", "timestamp": ts, "message": {"id": mid, "usage": {
                "input_tokens": inp, "cache_creation_input_tokens": cw, "cache_read_input_tokens": cr,
                "output_tokens": out}}})
        transcript = os.path.join(self.tmp, "t.jsonl")
        self.run_hook("claude", "prompt", S1)
        now = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(time.time() + 1))
        with open(transcript, "w") as f:
            f.write("\n".join([
                line(old, "m0", 9, 9, 9, 9000),           # previous turn: not counted
                json.dumps({"type": "user", "timestamp": now, "message": {"content": "hi"}}),
                line(now, "m1", 10, 2000, 50000, 300),     # cache reads left out
                line(now, "m1", 10, 2000, 50000, 300),     # same response on a second line: once
                line(now, "m2", 5, 0, 52000, 9685),
                "not json"]) + "\n")
        code, out, urls = self.run_hook("claude", "stop", dict(S1, transcript_path=transcript))
        self.assertIn("tokens=12000", urls[0])
        self.assertIn("subtitle=Orbi%20%C2%B7%201%20s%20%C2%B7%2012k%20tokens", urls[0])
        # No transcript → no tokens, still logged.
        self.run_hook("claude", "prompt", S1)
        code, out, urls = self.run_hook("claude", "stop", dict(S1, transcript_path="/nope"))
        self.assertNotIn("tokens", urls[0])

    def test_gemini_turn_tokens(self):
        old = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(time.time() - 3600))
        self.run_hook("gemini", "prompt", S1)
        now = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(time.time() + 1))
        transcript = os.path.join(self.tmp, "session.json")
        with open(transcript, "w") as f:
            json.dump({"sessionId": "s1", "messages": [
                {"type": "gemini", "timestamp": old, "tokens": {"input": 9000, "output": 9, "cached": 0}},
                {"type": "user", "timestamp": now, "content": "hi"},
                {"type": "gemini", "timestamp": now, "tokens": {"input": 7000, "output": 500, "cached": 4000,
                                                                "thoughts": 500, "total": 8000}},
            ]}, f, indent=2)
        code, out, urls = self.run_hook("gemini", "stop", dict(S1, transcript_path=transcript))
        self.assertIn("tokens=4000", urls[0])

    def test_statusline_prints_limits_and_sends_changes_once(self):
        data = dict(S1, rate_limits={"five_hour": {"used_percentage": 23.4, "resets_at": 1793000000},
                                     "seven_day": {"used_percentage": 41, "resets_at": "2026-11-09T09:00:00Z"}})
        code, out, urls = self.run_hook("claude", "statusline", data)
        self.assertEqual(out, "5h 23% · 7d 41%")
        self.assertEqual(urls, ["orbi://usage?five=23&five_reset=1793000000&week=41&week_reset=1794214800"])
        self.assertEqual(self.run_hook("claude", "statusline", data)[2], [])  # unchanged → not sent again
        data["rate_limits"]["five_hour"]["used_percentage"] = 24
        self.assertEqual(len(self.run_hook("claude", "statusline", data)[2]), 1)
        # API-key users have no rate_limits: empty line, nothing sent.
        self.assertEqual(self.run_hook("claude", "statusline", S1)[1:], ("", []))

    def test_host_app_and_idle(self):
        code, out, urls = self.run_hook("claude", "prompt", S1, __CFBundleIdentifier="com.microsoft.VSCode")
        self.assertIn("app=com.microsoft.VSCode", urls[0])
        code, out, urls = self.run_hook("claude", "prompt", S1, TERM_PROGRAM="iTerm.app")
        self.assertIn("app=com.googlecode.iterm2", urls[0])
        code, out, urls = self.run_hook("claude", "prompt", S1, __CFBundleIdentifier="bad id; rm")
        self.assertNotIn("app=", urls[0])
        # Idle a minute after an interrupted turn → no longer running.
        code, out, urls = self.run_hook("claude", "wait", dict(S1, notification_type="idle_prompt"))
        self.assertEqual(urls, ["orbi://agent/stop?session=claude-s1"])

    def test_short_turn_with_message_is_logged_silently(self):
        self.run_hook("claude", "prompt", S1)  # (agent/start)
        code, out, urls = self.run_hook("claude", "stop", dict(S1, last_assistant_message="Fixed it."), "--reply")
        self.assertEqual(len(urls), 1)
        self.assertTrue(urls[0].startswith("orbi://agent/log?title=Claude%20finished"))
        self.assertIn("detail=Fixed%20it.", urls[0])

    def test_reply_wakes_claude(self):
        self.run_hook("claude", "prompt", S1)
        p = self.start_hook("claude", "stop", dict(S1, last_assistant_message="Tests pass. **Push?**"),
                            "--reply", ORBI_AGENT_MIN_SECONDS="0")
        q = self.wait_for_ask(p)
        self.assertEqual((q["kind"], q["title"], q["detail"]), ("reply", "Claude finished ✓", "Tests pass. **Push?**"))
        self.answer(q["id"], "reply", "yes, push it")
        out, err = self.finish(p)
        self.assertEqual(p.returncode, 2)
        self.assertEqual(out, "")
        self.assertIn("yes, push it", err)
        self.assertEqual(self.pending(), [])

    def test_reply_done_and_new_prompt_cancel(self):
        self.run_hook("claude", "prompt", S1)
        p = self.start_hook("claude", "stop", dict(S1, last_assistant_message="Done."), "--reply",
                            ORBI_AGENT_MIN_SECONDS="0")
        q = self.wait_for_ask(p)
        self.answer(q["id"], "dismiss")
        self.assertEqual(self.finish(p)[0].strip(), "{}")
        self.assertEqual(p.returncode, 0)
        # The user typed in the terminal instead: the waiting hook ends, the bubble closes.
        self.run_hook("claude", "prompt", S1)
        p = self.start_hook("claude", "stop", dict(S1, last_assistant_message="Done."), "--reply",
                            ORBI_AGENT_MIN_SECONDS="0")
        q = self.wait_for_ask(p)
        code, out, urls = self.run_hook("claude", "prompt", S1)
        self.assertIn("orbi://ask/cancel?id=" + q["id"], urls)
        self.assertIn("orbi://agent/start?session=claude-s1&agent=Claude&project=Orbi", urls)
        self.finish(p)
        self.assertEqual(p.returncode, 0)

    def test_reply_timeout_closes_bubble(self):
        self.run_hook("claude", "prompt", S1)
        p = self.start_hook("claude", "stop", dict(S1, last_assistant_message="x"), "--reply",
                            ORBI_AGENT_MIN_SECONDS="0", ORBI_REPLY_TIMEOUT="0.5")
        q = self.wait_for_ask(p)
        out, err = self.finish(p)
        self.assertEqual(p.returncode, 0)
        self.assertIn("orbi://ask/cancel?id=" + q["id"], err)

    # ---------------------------------------------------------------- permission

    def permission(self, action):
        p = self.start_hook("claude", "permission",
                            dict(S1, tool_name="Bash", tool_input={"command": "rm -rf node_modules"}))
        q = self.wait_for_ask(p)
        self.assertEqual((q["kind"], q["title"], q["detail"]),
                         ("permission", "Claude wants to use Bash", "rm -rf node_modules"))
        if action:
            self.answer(q["id"], action)
        out, _ = self.finish(p)
        self.assertEqual(p.returncode, 0)
        return json.loads(out)

    def test_permission_allow_deny_terminal(self):
        allow = self.permission("allow")
        self.assertEqual(allow["hookSpecificOutput"]["decision"], {"behavior": "allow"})
        self.assertEqual(allow["hookSpecificOutput"]["hookEventName"], "PermissionRequest")
        deny = self.permission("deny")
        self.assertEqual(deny["hookSpecificOutput"]["decision"]["behavior"], "deny")
        self.assertEqual(self.permission("terminal"), {})
        self.assertEqual(self.pending(), [])

    def test_permission_always_applies_claudes_suggestion(self):
        suggestion = {"type": "addRules", "rules": [{"toolName": "Bash", "ruleContent": "npm test:*"}],
                      "behavior": "allow", "destination": "localSettings"}
        p = self.start_hook("claude", "permission", dict(S1, tool_name="Bash", tool_input={"command": "npm test"},
                                                         permission_suggestions=[suggestion]))
        q = self.wait_for_ask(p)
        self.assertEqual(q["always"], "Bash(npm test:*)")
        self.answer(q["id"], "always")
        out = json.loads(self.finish(p)[0])
        self.assertEqual(out["hookSpecificOutput"]["decision"],
                         {"behavior": "allow", "updatedPermissions": [suggestion]})
        # Without suggestions there's no Always button (no `always` param).
        p = self.start_hook("claude", "permission", dict(S1, tool_name="Bash", tool_input={"command": "ls"}))
        q = self.wait_for_ask(p)
        self.assertNotIn("always", q)
        self.answer(q["id"], "allow")
        self.assertEqual(json.loads(self.finish(p)[0])["hookSpecificOutput"]["decision"], {"behavior": "allow"})

    def test_permission_answered_in_terminal(self):
        p = self.start_hook("claude", "permission", dict(S1, tool_name="Edit", tool_input={"file_path": "/a.swift"}))
        q = self.wait_for_ask(p)
        self.assertEqual(len(self.pending()), 1)
        # Approved in the terminal → the tool runs → PostToolUse → resume closes the bubble.
        code, out, urls = self.run_hook("claude", "resume", S1)
        self.assertIn("orbi://ask/cancel?id=" + q["id"], urls)
        self.assertEqual(json.loads(self.finish(p)[0]), {})
        self.assertEqual(self.pending(), [])

    # ---------------------------------------------------------------- needs you

    def test_wait_bubble_and_resume(self):
        code, out, urls = self.run_hook("claude", "wait", dict(S1, notification_type="elicitation_dialog",
                                                               message="Claude has a question"))
        self.assertTrue(urls[0].startswith("orbi://notify?title=Claude%20needs%20you"))
        self.assertTrue(urls[0].endswith("&sticky=1"))
        self.assertEqual(self.run_hook("claude", "resume", {"session_id": "other"})[2], [])
        self.assertEqual(self.run_hook("claude", "resume", S1)[2], ["orbi://notify/dismiss"])
        self.assertEqual(self.run_hook("claude", "resume", S1)[2], [])

    def test_ignored_notifications_and_switch_off(self):
        self.assertEqual(self.run_hook("claude", "wait", dict(S1, notification_type="auth_success"))[2], [])
        self.assertEqual(self.run_hook("claude", "wait", dict(S1, notification_type="permission_prompt"),
                                       ORBI_AGENT_WAIT="0")[2], [])
        urls = self.run_hook("gemini", "wait", dict(S1, notification_type="ToolPermission"))[2]
        self.assertIn("Waiting%20for%20your%20answer", urls[0])

    def test_resume_guard_matches_pending_files(self):
        """The shell guard in the hook config must see a pending file exactly while one exists."""
        guard = 'set -- "${TMPDIR:-/tmp}"/orbi-agent-hook/claude-*.pending.*; [ -e "$1" ] && echo yes || echo no'
        sh = lambda: subprocess.run(["/bin/sh", "-c", guard], capture_output=True, text=True,
                                    env=self.env()).stdout.strip()
        self.assertEqual(sh(), "no")
        self.run_hook("claude", "wait", dict(S1, notification_type="elicitation_dialog"))
        self.assertEqual(sh(), "yes")
        self.run_hook("claude", "resume", S1)
        self.assertEqual(sh(), "no")

    def test_bad_input_never_fails(self):
        for event in ["prompt", "stop", "wait", "resume", "permission", "nonsense"]:
            p = subprocess.run([sys.executable, "-I", HOOK, "claude", event], input="garbage",
                               capture_output=True, text=True, env=self.env(ORBI_ASK_TIMEOUT="0.2"), timeout=10)
            self.assertEqual((p.returncode, p.stdout.strip()), (0, "{}"))

    def write_queue(self, session, text):
        qdir = os.path.join(self.tmp, "queue")
        os.makedirs(qdir, exist_ok=True)
        with open(os.path.join(qdir, session + ".txt"), "w") as f:
            f.write(text)
        return os.path.join(qdir, session + ".txt")

    def test_queued_message_wakes_claude_with_reply_flag(self):
        path = self.write_queue("claude-s1", "  run the tests too \n")
        p = subprocess.run([sys.executable, "-I", HOOK, "claude", "stop", "--reply"],
                           input=json.dumps(dict(S1, last_assistant_message="Done.")),
                           capture_output=True, text=True, env=self.env(ORBI_QUEUE_DIR=os.path.dirname(path)), timeout=20)
        self.assertEqual(p.returncode, 2)
        self.assertIn("run the tests too", p.stderr)
        self.assertFalse(os.path.exists(path))
        urls = [l for l in p.stderr.splitlines() if l.startswith("orbi://")]
        self.assertEqual(len(urls), 1)
        q = {k: v[0] for k, v in parse_qs(urlparse(urls[0]).query).items()}
        self.assertTrue(urls[0].startswith("orbi://agent/log?"))
        self.assertEqual(q["reply"], "run the tests too")
        self.assertEqual(q["session"], "claude-s1")

    def test_queued_message_blocks_stop_without_reply_flag(self):
        path = self.write_queue("claude-s1", "next step")
        code, out, _ = self.run_hook("claude", "stop", S1, ORBI_QUEUE_DIR=os.path.dirname(path))
        self.assertEqual(code, 0)
        decision = json.loads(out)
        self.assertEqual(decision["decision"], "block")
        self.assertIn("next step", decision["reason"])

    def test_queue_ignored_for_other_agents(self):
        path = self.write_queue("gemini-s1", "hi")
        code, out, urls = self.run_hook("gemini", "stop", S1, ORBI_QUEUE_DIR=os.path.dirname(path))
        self.assertEqual((code, out), (0, "{}"))
        self.assertTrue(os.path.exists(path))


if __name__ == "__main__":
    unittest.main()
