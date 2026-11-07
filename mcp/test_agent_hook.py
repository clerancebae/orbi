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
        return dict(os.environ, TMPDIR=self.tmp, ORBI_ANSWERS_DIR=self.answers, ORBI_HOOK_DRY_RUN="1", **extra)

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
        self.assertEqual(self.run_hook("claude", "prompt", S1), (0, "{}", []))
        self.assertEqual(self.run_hook("claude", "stop", S1, "--reply"), (0, "{}", []))
        self.run_hook("gemini", "prompt", S1)
        code, out, urls = self.run_hook("gemini", "stop", S1, ORBI_AGENT_MIN_SECONDS="0")
        self.assertEqual(urls, ["orbi://notify?title=Gemini%20finished%20%E2%9C%93&message=Orbi%20%C2%B7%201%20min"])

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
        for kind in ["idle_prompt", "auth_success"]:
            self.assertEqual(self.run_hook("claude", "wait", dict(S1, notification_type=kind))[2], [])
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


if __name__ == "__main__":
    unittest.main()
