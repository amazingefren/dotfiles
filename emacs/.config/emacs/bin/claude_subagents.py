"""Track Claude task, workflow, and subagent events for the Herdr overview.

Claude's hook input supplies session and subagent IDs.  This stores only those
IDs and short display labels; it never stores prompts or transcript content.
"""

import json
import os
from pathlib import Path
import sys
import time


def state_file():
    override = os.environ.get("HERDR_CLAUDE_STATE_FILE")
    if override:
        return Path(override)
    root = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local" / "state"))
    return root / "herdr" / "claude-agents.jsonl"


def record(event, environment=None):
    environment = environment or os.environ
    kind = event.get("hook_event_name")
    session_id = event.get("session_id")
    if kind not in ("SessionStart", "SubagentStart", "SubagentStop",
                    "TaskCreated", "TaskCompleted", "PostToolUse", "Stop",
                    "SessionEnd"):
        return
    if not isinstance(session_id, str) or not session_id:
        return
    if kind == "PostToolUse" and event.get("tool_name") != "TaskUpdate":
        return
    tool_input = event.get("tool_input") or {}
    task_id = event.get("task_id") or tool_input.get("taskId") or tool_input.get("task_id")
    item = {"event": kind, "session_id": session_id,
            "agent_id": event.get("agent_id"),
            "agent_type": event.get("agent_type"),
            "task_id": str(task_id) if task_id is not None else None,
            "task_subject": str(event.get("task_subject") or tool_input.get("subject") or "")[:120],
            "task_status": tool_input.get("status"),
            "background_tasks": [
                {"id": str(task["id"]) if task.get("id") is not None else None,
                 "status": task.get("status"),
                 "description": str(task.get("description") or "")[:160]}
                for task in event.get("background_tasks", [])
                if task.get("type") == "workflow"],
            "herdr_session": environment.get("HERDR_SESSION"),
            "pane": environment.get("HERDR_PANE_ID"),
            "time_ns": time.time_ns()}
    path = state_file()
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    try:
        os.write(descriptor, (json.dumps(item, separators=(",", ":")) + "\n").encode())
    finally:
        os.close(descriptor)


def snapshot():
    sessions = {}
    active = {}
    tasks = {}
    workflows = {}
    try:
        with state_file().open(encoding="utf-8") as stream:
            events = []
            for line in stream:
                try:
                    events.append(json.loads(line))
                except ValueError:
                    continue
    except (OSError, UnicodeError):
        return {"roots": [], "children": [], "tasks": [], "workflows": []}
    for event in sorted(events, key=lambda item: item.get("time_ns", 0)):
        session_id = event.get("session_id")
        kind = event.get("event")
        agent_id = event.get("agent_id")
        if kind == "SessionStart":
            if event.get("herdr_session") and event.get("pane"):
                sessions[session_id] = event
                for table in (active, workflows):
                    for key in list(table):
                        if key[0] == session_id:
                            del table[key]
        elif kind == "SubagentStart" and agent_id:
            active[(session_id, agent_id)] = event
        elif kind == "SubagentStop" and agent_id:
            active.pop((session_id, agent_id), None)
        elif kind == "TaskCreated" and event.get("task_id"):
            tasks[(session_id, event["task_id"])] = {
                "id": event["task_id"], "root": session_id,
                "title": event.get("task_subject") or event["task_id"],
                "status": "pending"}
        elif kind in ("TaskCompleted", "PostToolUse") and event.get("task_id"):
            key = (session_id, event["task_id"])
            if kind == "TaskCompleted" or event.get("task_status") in ("completed", "deleted"):
                tasks.pop(key, None)
            elif key in tasks:
                if event.get("task_status"):
                    tasks[key]["status"] = event["task_status"]
                if event.get("task_subject"):
                    tasks[key]["title"] = event["task_subject"]
        elif kind == "Stop":
            for key in list(workflows):
                if key[0] == session_id:
                    del workflows[key]
            for run in event.get("background_tasks", []):
                if run.get("id"):
                    workflows[(session_id, run["id"])] = {
                        "id": run["id"], "root": session_id,
                        "title": run.get("description") or "workflow",
                        "status": run.get("status") or "running"}
        elif kind == "SessionEnd":
            sessions.pop(session_id, None)
            for table in (active, tasks, workflows):
                for key in list(table):
                    if key[0] == session_id:
                        del table[key]
    roots = [{"id": session_id, "session": event["herdr_session"],
              "pane": event["pane"]} for session_id, event in sessions.items()]
    children = [{"id": agent_id, "parent_thread_id": session_id,
                 "role": event.get("agent_type") or "subagent",
                 "status": "working", "id_kind": "agent"}
                for (session_id, agent_id), event in active.items()
                if session_id in sessions]
    return {"roots": roots, "children": children,
            "tasks": [task for (session_id, _), task in tasks.items()
                      if session_id in sessions],
            "workflows": [run for (session_id, _), run in workflows.items()
                          if session_id in sessions]}


if __name__ == "__main__":
    if sys.argv[1:] == ["--record"]:
        record(json.load(sys.stdin))
    elif sys.argv[1:] == ["--list"]:
        print(json.dumps(snapshot()))
    else:
        raise SystemExit("usage: claude_subagents.py --record|--list")
