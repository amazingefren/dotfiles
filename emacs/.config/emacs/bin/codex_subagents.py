"""Read Codex's local session metadata for the Herdr overview.

Only session metadata and recent lifecycle events are read. Prompts and
conversation content stay out of the overview and its subprocess output.
"""

import json
import os
from pathlib import Path
import sys


def sessions():
    root = Path(os.environ.get("CODEX_HOME", Path.home() / ".codex")) / "sessions"
    for path in root.glob("*/*/*/*.jsonl"):
        try:
            with path.open(encoding="utf-8") as stream:
                record = json.loads(stream.readline())
            if record.get("type") == "session_meta":
                yield record["payload"], path
        except (OSError, UnicodeError, ValueError, KeyError):
            continue


def metadata(thread_id):
    for entry, _path in sessions():
        if entry.get("id") == thread_id:
            return entry
    return None


def recent_status(path):
    """Read only the log tail to distinguish a completed from a running turn."""
    try:
        with path.open("rb") as stream:
            stream.seek(0, os.SEEK_END)
            stream.seek(max(0, stream.tell() - 65536))
            lines = stream.read().splitlines()
        for line in reversed(lines):
            try:
                event = json.loads(line)
            except ValueError:
                continue
            if event.get("type") == "event_msg":
                kind = event.get("payload", {}).get("type")
                if kind in ("task_complete", "task_started", "turn_aborted"):
                    return {"task_complete": "done", "task_started": "working",
                            "turn_aborted": "interrupted"}[kind]
    except OSError:
        pass
    return ""


def descendants(roots):
    roots = set(roots)
    children = {}
    for entry, path in sessions():
        parent = entry.get("parent_thread_id")
        if parent and entry.get("id"):
            children.setdefault(parent, []).append((entry, path))
    found = []
    seen = set(roots)
    queue = [(root, root) for root in roots]
    while queue:
        parent, visible_parent = queue.pop(0)
        for entry, path in children.get(parent, []):
            thread_id = entry["id"]
            if thread_id not in seen:
                seen.add(thread_id)
                status = recent_status(path)
                if status == "done":
                    queue.append((thread_id, visible_parent))
                    continue
                source = entry.get("source", {}).get("subagent", {})
                role = source.get("other") or source.get("thread_spawn", {}).get("agent_role")
                # Codex creates unnamed guardian threads for its subagents.
                # They are internal helpers, not separate work in the overview.
                if role == "guardian" and not (entry.get("agent_nickname") or
                                                entry.get("agent_path")):
                    queue.append((thread_id, visible_parent))
                    continue
                item = {key: entry.get(key) for key in
                        ("id", "agent_nickname", "agent_path")}
                item.update(parent_thread_id=visible_parent, role=role, status=status)
                found.append(item)
                queue.append((thread_id, thread_id))
    return found


if __name__ == "__main__":
    print(json.dumps(descendants(sys.argv[1:])))
