"""Smoke tests for the stdio MCP server's public tool surface."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SERVER = Path(__file__).resolve().parents[1] / "bin" / "emacs-mcp"
EDITOR_TOOLS = {
    "emacs_laya_submit",
    "emacs_laya_result",
    "emacs_laya_cancel",
    "emacs_context",
    "emacs_open_file",
    "emacs_edit_file",
    "emacs_create_file",
    "emacs_diagnostics",
    "emacs_symbols",
    "emacs_selection_context",
    "emacs_xref_definitions",
    "emacs_xref_references",
    "emacs_documentation_at_point",
}


def request(messages, env=None):
    completed = subprocess.run(
        [str(SERVER)],
        input="".join(json.dumps(message) + "\n" for message in messages),
        text=True,
        capture_output=True,
        env=env,
        check=True,
    )
    return [json.loads(line) for line in completed.stdout.splitlines()]


class EmacsMcpServerTest(unittest.TestCase):
    def test_lists_only_editor_tools_and_describes_passive_follow(self):
        initialized, listed = request(
            [{"jsonrpc": "2.0", "id": 1, "method": "initialize"},
             {"jsonrpc": "2.0", "id": 2, "method": "tools/list"}]
        )
        self.assertEqual(
            {tool["name"] for tool in listed["result"]["tools"]}, EDITOR_TOOLS
        )
        instructions = initialized["result"]["instructions"]
        self.assertIn("independently of MCP tool use", instructions)
        self.assertNotIn("follow window", instructions)

    def test_removed_tool_is_rejected_but_editor_tool_reaches_emacs(self):
        with tempfile.TemporaryDirectory() as workspace:
            fake_client = Path(workspace) / "emacsclient"
            fake_client.write_text(
                "#!/usr/bin/env python3\n"
                "import json, sys\n"
                "print(json.dumps(json.dumps({'expression': sys.argv[-1]})))\n"
            )
            fake_client.chmod(0o755)
            env = dict(os.environ, EMACSCLIENT=str(fake_client),
                       EMACS_MCP_WORKSPACE_ROOT=workspace)
            removed, accepted = request(
                [{"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                  "params": {"name": "emacs_read_file", "arguments": {"path": "x"}}},
                 {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                  "params": {"name": "emacs_context", "arguments": {}}}], env
            )
            self.assertEqual(removed["error"]["code"], -32602)
            payload = json.loads(accepted["result"]["content"][0]["text"])
            self.assertIn('(emacs-mcp-dispatch "context"', payload["expression"])


if __name__ == "__main__":
    unittest.main()
