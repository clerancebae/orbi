#!/usr/bin/env python3
"""Orbi MCP server (stdio, Python standard library only).

Lets Claude Desktop / Claude Code read Orbi's state (status.json) and act on it through
the app's orbi:// URL scheme. Claude starts this process when it needs it; it uses no
resources otherwise. Runs on the macOS system Python (3.9), so no 3.10+ syntax.

Env:
  ORBI_STATUS_FILE   override status.json path (tests)
  ORBI_MCP_DRY_RUN=1 don't open URLs, just report them (tests)
"""
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone
from urllib.parse import urlencode, quote

SERVER_NAME = "orbi"
SERVER_VERSION = "0.1.0"
SUPPORTED_PROTOCOLS = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

# Outside the App Group container on purpose: macOS 15+ blocks other apps from reading it.
STATUS_FILE = os.environ.get(
    "ORBI_STATUS_FILE",
    os.path.expanduser("~/Library/Application Support/Orbi/status.json"),
)
DRY_RUN = os.environ.get("ORBI_MCP_DRY_RUN") == "1"


# ---------------------------------------------------------------- Orbi access

def read_status():
    try:
        with open(STATUS_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        raise ToolError("Orbi's status file was not found. Is Orbi installed and has it run once?")
    except (OSError, ValueError) as e:
        raise ToolError("Could not read Orbi's status: %s" % e)


def open_url(url):
    """Sends a orbi:// URL to the app in the background (-g: don't bring anything forward).
    Returns the status after the app has applied it (or None in dry-run)."""
    if DRY_RUN:
        return None
    before = status_stamp()
    result = subprocess.run(["/usr/bin/open", "-g", url], capture_output=True, text=True, timeout=10)
    if result.returncode != 0:
        raise ToolError("Could not reach Orbi: %s" % (result.stderr.strip() or "open failed"))
    # Wait briefly for Orbi to write the new status, so we can confirm the result.
    deadline = time.time() + 2.5
    while time.time() < deadline:
        time.sleep(0.15)
        if status_stamp() != before:
            break
    try:
        return read_status()
    except ToolError:
        return None


def status_stamp():
    try:
        return os.stat(STATUS_FILE).st_mtime_ns
    except OSError:
        return None


def orbi_url(route, **params):
    params = {k: v for k, v in params.items() if v is not None and v != ""}
    query = urlencode(params, quote_via=quote)
    return "orbi://%s%s" % (route, ("?" + query) if query else "")


class ToolError(Exception):
    pass


# ---------------------------------------------------------------- formatting

def minutes_text(m):
    if m is None:
        return ""
    sign = "-" if m < 0 else ""
    m = abs(int(m))
    if m < 60:
        return "%s%dm" % (sign, m)
    return "%s%dh %02dm" % (sign, m // 60, m % 60) if m % 60 else "%s%dh" % (sign, m // 60)


def age_text(iso):
    try:
        then = datetime.strptime(iso, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except (TypeError, ValueError):
        return ""
    seconds = (datetime.now(timezone.utc) - then).total_seconds()
    if seconds < 90:
        return "just now"
    if seconds < 3600:
        return "%d min ago" % (seconds // 60)
    if seconds < 86400:
        return "%d h ago" % (seconds // 3600)
    return "%d days ago" % (seconds // 86400)


def local_time(iso):
    try:
        then = datetime.strptime(iso, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except (TypeError, ValueError):
        return None
    return then.astimezone().strftime("%H:%M")


def summarize(s):
    lines = []
    if s.get("activeTask"):
        rem = s.get("remainingMin")
        if rem is None:
            timing = "%s elapsed, no estimate" % minutes_text(s.get("elapsedMin") or 0)
        elif rem >= 0:
            timing = "%s left" % minutes_text(rem)
        else:
            timing = "%s over the estimate" % minutes_text(-rem)
        lines.append("Active task: %s (%s)" % (s["activeTask"], timing))
    else:
        lines.append("Active task: none")

    tasks = s.get("tasks") or []
    done = [t for t in tasks if t.get("status") == "done"]
    lines.append("")
    lines.append("Today's tasks (%d done of %d):" % (len(done), len(tasks)))
    if not tasks:
        lines.append("  (none)")
    for t in tasks:
        mark = {"done": "[x]", "active": "[>]"}.get(t.get("status"), "[ ]")
        extra = []
        if t.get("estimateMin"):
            extra.append("est %s" % minutes_text(t["estimateMin"]))
        if t.get("spentMin"):
            extra.append("spent %s" % minutes_text(t["spentMin"]))
        lines.append("  %s %s%s" % (mark, t.get("title", ""), (" (" + ", ".join(extra) + ")") if extra else ""))

    upcoming = s.get("upcoming") or []
    if upcoming:
        lines.append("")
        lines.append("Planned for later days:")
        for t in upcoming:
            est = (" (est %s)" % minutes_text(t["estimateMin"])) if t.get("estimateMin") else ""
            lines.append("  %s: %s%s" % (t.get("date", "?"), t.get("title", ""), est))

    lines.append("")
    water = "Water: %s/%s glasses" % (s.get("water", 0), s.get("waterGoal", 0))
    if s.get("waterReminderDue"):
        water += " (reminder waiting)"
    elif s.get("nextWaterReminder"):
        t = local_time(s["nextWaterReminder"])
        if t:
            water += ", next reminder %s" % t
    lines.append(water)
    if s.get("nextEvent"):
        lines.append("Next calendar event: %s" % s["nextEvent"])

    reading = s.get("reading") or []
    lines.append("")
    lines.append("Read later (%d waiting):" % len(reading))
    if not reading:
        lines.append("  (none)")
    for r in reading:
        flags = [age_text(r.get("savedAt"))]
        if r.get("opened"):
            flags.append("opened, not finished")
        if r.get("snoozed"):
            flags.append("snoozed")
        lines.append("  - %s <%s> (%s)" % (r.get("title", ""), r.get("url", ""), ", ".join(f for f in flags if f)))

    read = s.get("read") or []
    if read:
        lines.append("")
        lines.append("Recently read:")
        for r in read[:10]:
            lines.append("  - %s (%s)" % (r.get("title", ""), age_text(r.get("finishedAt"))))

    lines.append("")
    lines.append("(Orbi status updated %s)" % (age_text(s.get("updatedAt")) or "unknown"))
    return "\n".join(lines)


# ---------------------------------------------------------------- tools

def tool_get_status(args):
    return summarize(read_status())


def validate_task(t):
    title = (t.get("title") or "").strip()
    if not title:
        raise ToolError("Each task needs a non-empty title.")
    minutes = t.get("minutes")
    if minutes is not None:
        try:
            minutes = int(minutes)
        except (TypeError, ValueError):
            raise ToolError("minutes must be a whole number (got %r)." % (minutes,))
        if not 1 <= minutes <= 1440:
            raise ToolError("minutes must be between 1 and 1440.")
    date = (t.get("date") or "").strip().lower() or None
    return title, minutes, date


def tool_add_tasks(args):
    tasks = args.get("tasks")
    if not isinstance(tasks, list) or not tasks:
        raise ToolError("Provide a non-empty list of tasks.")
    if len(tasks) > 30:
        raise ToolError("At most 30 tasks at once.")
    validated = [validate_task(t if isinstance(t, dict) else {}) for t in tasks]
    urls = [orbi_url("task/add", title=title, min=minutes, date=date) for title, minutes, date in validated]
    status = None
    for url in urls:
        status = open_url(url)
    if DRY_RUN:
        return "Dry run, would open:\n" + "\n".join(urls)
    added = ", ".join(
        "%s%s%s" % (title, (" (%s)" % minutes_text(minutes)) if minutes else "", (" for %s" % date) if date else "")
        for title, minutes, date in validated)
    return "Added: %s\n\n%s" % (added, summarize(status) if status else "")


def simple_action(route, done_text):
    def run(args):
        status = open_url(orbi_url(route))
        if DRY_RUN:
            return "Dry run, would open: " + orbi_url(route)
        return "%s\n\n%s" % (done_text, summarize(status) if status else "")
    return run


def tool_save_for_later(args):
    url = (args.get("url") or "").strip()
    if not (url.startswith("http://") or url.startswith("https://")):
        raise ToolError("url must start with http:// or https://")
    target = orbi_url("reading/save", url=url, title=(args.get("title") or "").strip() or None)
    status = open_url(target)
    if DRY_RUN:
        return "Dry run, would open: " + target
    return "Saved for later: %s\n\n%s" % (url, summarize(status) if status else "")


TASK_ITEM_SCHEMA = {
    "type": "object",
    "properties": {
        "title": {"type": "string", "description": "Task title, short."},
        "minutes": {"type": "integer", "minimum": 1, "maximum": 1440,
                    "description": "Optional time estimate in minutes."},
        "date": {"type": "string",
                 "description": "Optional day: 'today' (default), 'tomorrow', or YYYY-MM-DD. Past dates become today."},
    },
    "required": ["title"],
    "additionalProperties": False,
}

TOOLS = [
    {
        "name": "get_status",
        "description": "Read the user's Orbi state: today's tasks (with estimates and time spent), the active "
                       "task and its remaining time, tasks planned for later days, water intake vs goal, next "
                       "calendar event, read-later list and recently read items. Read-only.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
        "annotations": {"readOnlyHint": True, "title": "Get Orbi status"},
        "handler": tool_get_status,
    },
    {
        "name": "add_tasks",
        "description": "Add one or more tasks to the user's Orbi planner, for today or a later day. Use when the "
                       "user asks to plan, add, or transfer tasks. Keep titles short; put estimates in 'minutes'.",
        "inputSchema": {
            "type": "object",
            "properties": {"tasks": {"type": "array", "items": TASK_ITEM_SCHEMA, "minItems": 1, "maxItems": 30}},
            "required": ["tasks"],
            "additionalProperties": False,
        },
        "annotations": {"title": "Add tasks", "destructiveHint": False},
        "handler": tool_add_tasks,
    },
    {
        "name": "start_next_task",
        "description": "Start the first not-yet-started task of today (pauses any other active task).",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
        "annotations": {"title": "Start next task", "destructiveHint": False},
        "handler": simple_action("task/start-next", "Started the next task."),
    },
    {
        "name": "complete_active_task",
        "description": "Mark the currently active task as done.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
        "annotations": {"title": "Complete active task", "destructiveHint": False},
        "handler": simple_action("task/complete", "Completed the active task."),
    },
    {
        "name": "log_water",
        "description": "Log one glass of water (also resets the water reminder).",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
        "annotations": {"title": "Log a glass of water", "destructiveHint": False},
        "handler": simple_action("water/add", "Logged a glass of water."),
    },
    {
        "name": "undo_water",
        "description": "Remove the most recent glass of water logged today.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
        "annotations": {"title": "Undo last glass", "destructiveHint": True},
        "handler": simple_action("water/undo", "Removed the last glass."),
    },
    {
        "name": "save_for_later",
        "description": "Save a web link to the user's Orbi read-later list.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "url": {"type": "string", "description": "http(s) URL"},
                "title": {"type": "string", "description": "Optional title"},
            },
            "required": ["url"],
            "additionalProperties": False,
        },
        "annotations": {"title": "Save for later", "destructiveHint": False},
        "handler": tool_save_for_later,
    },
    {
        "name": "open_next_reading",
        "description": "Open the oldest unfinished read-later item in the user's browser.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
        "annotations": {"title": "Open next read-later item", "destructiveHint": False},
        "handler": simple_action("reading/open-next", "Opened the next read-later item."),
    },
]
TOOLS_BY_NAME = {t["name"]: t for t in TOOLS}


# ---------------------------------------------------------------- JSON-RPC over stdio

def respond(msg_id, result=None, error=None):
    msg = {"jsonrpc": "2.0", "id": msg_id}
    if error is not None:
        msg["error"] = error
    else:
        msg["result"] = result
    sys.stdout.write(json.dumps(msg, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def handle(msg):
    method = msg.get("method")
    msg_id = msg.get("id")
    params = msg.get("params") or {}
    is_request = "id" in msg

    if method == "initialize":
        requested = params.get("protocolVersion")
        version = requested if requested in SUPPORTED_PROTOCOLS else SUPPORTED_PROTOCOLS[0]
        respond(msg_id, {
            "protocolVersion": version,
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
            "instructions": "Orbi is the user's macOS menu bar planner (tasks with timers, water, read-later). "
                            "Call get_status before answering questions about their day.",
        })
    elif method == "ping":
        respond(msg_id, {})
    elif method == "tools/list":
        respond(msg_id, {"tools": [{k: v for k, v in t.items() if k != "handler"} for t in TOOLS]})
    elif method == "tools/call":
        tool = TOOLS_BY_NAME.get(params.get("name"))
        if tool is None:
            respond(msg_id, error={"code": -32602, "message": "Unknown tool: %s" % params.get("name")})
            return
        try:
            text = tool["handler"](params.get("arguments") or {})
            respond(msg_id, {"content": [{"type": "text", "text": text}], "isError": False})
        except ToolError as e:
            respond(msg_id, {"content": [{"type": "text", "text": str(e)}], "isError": True})
        except Exception as e:  # never let one bad call kill the server
            respond(msg_id, {"content": [{"type": "text", "text": "Orbi tool failed: %s" % e}], "isError": True})
    elif method in ("resources/list", "prompts/list"):
        respond(msg_id, {method.split("/")[0]: []})
    elif not is_request:
        pass  # notifications (initialized, cancelled, ...) need no reply
    else:
        respond(msg_id, error={"code": -32601, "message": "Method not found: %s" % method})


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            respond(None, error={"code": -32700, "message": "Parse error"})
            continue
        if isinstance(msg, list):  # batch (older protocol versions)
            for m in msg:
                handle(m)
        else:
            handle(msg)


if __name__ == "__main__":
    main()
