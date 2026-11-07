"""Protocol tests for orbi_mcp.py. Run: /usr/bin/python3 -I mcp/test_orbi_mcp.py
Uses a fake status.json and dry-run mode, so nothing is sent to Orbi."""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from urllib.parse import unquote

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER = os.path.join(HERE, "orbi_mcp.py")

STATUS = {
    "activeTask": "API docs", "remainingMin": -4, "elapsedMin": 29, "water": 5, "waterGoal": 8,
    "waterReminderDue": False, "nextWaterReminder": "2026-11-07T11:30:00Z", "readingCount": 1,
    "nextEvent": "14:00 Standup",
    "tasks": [{"title": "API docs", "status": "active", "estimateMin": 25, "spentMin": 29},
              {"title": "Email", "status": "done", "estimateMin": None, "spentMin": 10}],
    "upcoming": [{"title": "Plan sprint", "date": "2026-11-08", "estimateMin": 60}],
    "reading": [{"title": "Swift 6", "url": "https://swift.org", "savedAt": "2026-11-01T10:00:00Z",
                 "opened": True, "snoozed": False}],
    "read": [{"title": "Old post", "url": "https://example.com", "finishedAt": "2026-11-06T10:00:00Z"}],
    "updatedAt": "2026-11-07T10:00:00Z",
}


def session(messages, status=STATUS):
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump(status, f)
        path = f.name
    env = dict(os.environ, ORBI_STATUS_FILE=path, ORBI_MCP_DRY_RUN="1")
    inp = "\n".join(json.dumps(m) for m in messages) + "\n"
    out = subprocess.run([sys.executable, "-I", SERVER], input=inp, capture_output=True, text=True,
                         env=env, timeout=20)
    os.unlink(path)
    return [json.loads(l) for l in out.stdout.splitlines() if l.strip()]


INIT = {"jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "t", "version": "1"}}}
INITIALIZED = {"jsonrpc": "2.0", "method": "notifications/initialized"}


def call(i, name, args=None):
    return {"jsonrpc": "2.0", "id": i, "method": "tools/call", "params": {"name": name, "arguments": args or {}}}


class Tests(unittest.TestCase):
    def test_handshake_and_list(self):
        r = session([INIT, INITIALIZED, {"jsonrpc": "2.0", "id": 2, "method": "tools/list"}])
        self.assertEqual(len(r), 2)  # the notification gets no reply
        self.assertEqual(r[0]["result"]["protocolVersion"], "2025-06-18")
        self.assertIn("tools", r[0]["result"]["capabilities"])
        names = [t["name"] for t in r[1]["result"]["tools"]]
        self.assertEqual(names, ["get_status", "add_tasks", "start_next_task", "complete_active_task",
                                 "log_water", "undo_water", "save_for_later", "open_next_reading", "notify"])
        for t in r[1]["result"]["tools"]:
            self.assertNotIn("handler", t)
            self.assertEqual(t["inputSchema"]["type"], "object")

    def test_unknown_protocol_falls_back_to_latest(self):
        init = json.loads(json.dumps(INIT))
        init["params"]["protocolVersion"] = "1999-01-01"
        r = session([init])
        self.assertEqual(r[0]["result"]["protocolVersion"], "2025-11-25")

    def test_status_summary(self):
        r = session([INIT, call(2, "get_status")])
        text = r[1]["result"]["content"][0]["text"]
        self.assertFalse(r[1]["result"]["isError"])
        self.assertIn("Active task: API docs (4m over the estimate)", text)
        self.assertIn("Today's tasks (1 done of 2)", text)
        self.assertIn("[>] API docs (est 25m, spent 29m)", text)
        self.assertIn("2026-11-08: Plan sprint (est 1h)", text)
        self.assertIn("Water: 5/8 glasses", text)
        self.assertIn("Next calendar event: 14:00 Standup", text)
        self.assertIn("Swift 6 <https://swift.org>", text)
        self.assertIn("opened, not finished", text)
        self.assertIn("Old post", text)

    def test_add_tasks_encodes_urls(self):
        r = session([INIT, call(2, "add_tasks", {"tasks": [
            {"title": "C++ & docs", "minutes": 25},
            {"title": "Plan sprint", "date": "tomorrow"}]})])
        text = r[1]["result"]["content"][0]["text"]
        urls = [l for l in text.splitlines() if l.startswith("orbi://")]
        self.assertEqual(urls[0], "orbi://task/add?title=C%2B%2B%20%26%20docs&min=25")
        self.assertEqual(urls[1], "orbi://task/add?title=Plan%20sprint&date=tomorrow")
        self.assertEqual(unquote(urls[0].split("title=")[1].split("&")[0]), "C++ & docs")

    def test_add_tasks_validation(self):
        r = session([INIT,
                     call(2, "add_tasks", {"tasks": []}),
                     call(3, "add_tasks", {"tasks": [{"title": "  "}]}),
                     call(4, "add_tasks", {"tasks": [{"title": "X", "minutes": 0}]}),
                     call(5, "add_tasks", {"tasks": [{"title": "X", "minutes": "abc"}]})])
        for resp in r[1:]:
            self.assertTrue(resp["result"]["isError"], resp)

    def test_save_for_later(self):
        r = session([INIT,
                     call(2, "save_for_later", {"url": "https://a.com/x?b=1&c=2", "title": "A"}),
                     call(3, "save_for_later", {"url": "file:///etc/passwd"})])
        self.assertIn("orbi://reading/save?url=https%3A%2F%2Fa.com%2Fx%3Fb%3D1%26c%3D2&title=A",
                      r[1]["result"]["content"][0]["text"])
        self.assertTrue(r[2]["result"]["isError"])

    def test_notify(self):
        r = session([INIT,
                     call(2, "notify", {"title": "Claude finished ✓", "message": "Orbi · 2 min"}),
                     call(3, "notify", {"title": "  "})])
        text = r[1]["result"]["content"][0]["text"]
        self.assertIn("orbi://notify?title=Claude%20finished%20%E2%9C%93&message=Orbi%20%C2%B7%202%20min", text)
        self.assertTrue(r[2]["result"]["isError"])

    def test_missing_status_file_is_tool_error(self):
        env = dict(os.environ, ORBI_STATUS_FILE="/nonexistent/status.json", ORBI_MCP_DRY_RUN="1")
        inp = json.dumps(INIT) + "\n" + json.dumps(call(2, "get_status")) + "\n"
        out = subprocess.run([sys.executable, "-I", SERVER], input=inp, capture_output=True, text=True, env=env)
        r = [json.loads(l) for l in out.stdout.splitlines()]
        self.assertTrue(r[1]["result"]["isError"])
        self.assertIn("not found", r[1]["result"]["content"][0]["text"])

    def test_errors_and_robustness(self):
        r = session([INIT, call(2, "nope"), {"jsonrpc": "2.0", "id": 3, "method": "bogus/method"},
                     {"jsonrpc": "2.0", "id": 4, "method": "ping"}])
        self.assertEqual(r[1]["error"]["code"], -32602)
        self.assertEqual(r[2]["error"]["code"], -32601)
        self.assertEqual(r[3]["result"], {})


if __name__ == "__main__":
    unittest.main(verbosity=1)
