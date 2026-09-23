"""Protocol and boundary tests without model downloads or API calls."""

import io
import json
import subprocess
import sys
import types
import unittest
import urllib.error
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import worker


class FakeTokenizer:
    mask_token = "[MASK]"

    def __call__(self, text, add_special_tokens=False):
        return {"input_ids": list(text.encode())}


class FakeAgent:
    def __init__(self):
        self.tok = FakeTokenizer()
        self.cfg = {"max_len": 100, "head_max_len": 50}
        self.model_dir = Path("/cache/snapshots/revision123")
        self.calls = 0

    def _to_internal(self, q):
        return {"t": q["type"], "ins": q["instructions"], "crit": q.get("criteria")}

    def predict(self, state, questions):
        self.calls += 1
        print("library chatter")
        return {"model": "laya-rl-agent", "answers": {"x": {"type": "noul", "noul": 0.8}},
                "usage": {"input_tokens": 10, "output_tokens": 0}}


def fake_common():
    module = types.ModuleType("laya_mlx.common")
    module.serialize_state = lambda state: state if isinstance(state, str) else json.dumps(state, ensure_ascii=False)
    module.render_options = lambda q: ["false: no", "true: yes"] if q["t"] == "noul" else list(q["crit"])
    return module


class WorkerTests(unittest.TestCase):
    def setUp(self):
        self.agent = FakeAgent()
        self.loads = []

        def load(model, revision=None):
            self.loads.append((model, revision))
            return self.agent

        self.worker = worker.Worker(loader=load)
        self.modules = mock.patch.dict(sys.modules, {"laya_mlx": types.ModuleType("laya_mlx"),
                                                    "laya_mlx.common": fake_common()})
        self.modules.start()

    def tearDown(self):
        self.modules.stop()

    def req(self, state="hi"):
        return {"id": "1", "op": "evaluate", "backend": "mlx", "state": state,
                "questions": {"x": {"type": "noul", "instructions": "Question?"}}}

    def test_ready_does_not_import_model(self):
        path = str(Path(worker.__file__))
        process = subprocess.Popen([sys.executable, path], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        out, err = process.communicate('{"id":"s","op":"status"}\n', timeout=5)
        lines = [json.loads(line) for line in out.splitlines()]
        self.assertEqual(lines[0], {"event": "ready", "protocol": 1})
        self.assertEqual(lines[1]["result"]["loaded"], False)
        self.assertEqual(err, "")

    def test_malformed_protocol_recovers_without_leaking_content(self):
        path = str(Path(worker.__file__))
        process = subprocess.Popen([sys.executable, path], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        out, _ = process.communicate('{bad secret\n{"op":"configure","jev_api_key":"secret"}\n'
                                     '{"id":"s","op":"status"}\n', timeout=5)
        lines = [json.loads(line) for line in out.splitlines()]
        self.assertEqual(len(lines), 3)
        self.assertEqual(lines[1]["error"]["code"], "invalid_json")
        self.assertEqual(lines[2]["id"], "s")
        self.assertNotIn("secret", out)

    def test_local_cache_context_and_stdout(self):
        with mock.patch.object(sys, "stderr", io.StringIO()) as err, mock.patch.object(sys, "stdout", io.StringIO()) as out:
            first = self.worker.handle(self.req())
            second = self.worker.handle(self.req())
        self.assertTrue(first["ok"])
        self.assertEqual(first["result"]["answers"]["x"]["noul"], 0.8)
        self.assertEqual(first["result"]["revision"], "revision123")
        self.assertEqual(self.loads, [(worker.DEFAULT_MLX_MODEL, None)])
        self.assertEqual(self.agent.calls, 2)
        self.assertEqual(out.getvalue(), "")
        self.assertIn("library chatter", err.getvalue())
        self.assertEqual(second["result"]["backend"], "mlx")

    def test_context_budget_requires_opt_in(self):
        request = self.req("z" * 200)
        denied = self.worker.handle(request)
        self.assertEqual(denied["error"]["code"], "context_budget")
        self.assertIn("state", denied["error"]["details"]["x"]["truncated"])
        self.assertEqual(self.agent.calls, 0)
        request["allow_truncation"] = True
        with mock.patch.object(sys, "stderr", io.StringIO()):
            allowed = self.worker.handle(request)
        self.assertTrue(allowed["ok"])
        self.assertIn("state", allowed["result"]["context"]["x"]["truncated"])

    def test_rejects_malformed_and_nonfinite(self):
        bad = self.req()
        bad["questions"]["x"]["type"] = "choice"
        bad["questions"]["x"]["criteria"] = ["a", "a"]
        self.assertEqual(self.worker.handle(bad)["error"]["code"], "invalid_request")
        self.assertEqual(self.worker.handle(self.req({"n": float("nan")}))["error"]["code"], "invalid_request")
        self.assertEqual(self.loads, [])

    def test_explicit_cloud_no_local_load_secret_not_echoed(self):
        seen = []

        class Response:
            def __enter__(self): return self
            def __exit__(self, *args): return None
            def read(self, amount): return b'{"model":"jev-1.13.0","answers":{"x":{"type":"noul","noul":0.7}},"usage":{"input_tokens":5,"output_tokens":0}}'

        def open_url(req, timeout):
            seen.append((req, timeout))
            return Response()

        self.worker.opener = open_url
        self.assertIsNone(self.worker.handle({"op": "configure", "jev_api_key": "very-secret"}))
        req = self.req()
        req["backend"] = "jev"
        response = self.worker.handle(req)
        self.assertTrue(response["ok"])
        self.assertEqual(self.loads, [])
        self.assertEqual(response["result"]["checkpoint"], "jev-1.13.0")
        self.assertNotIn("very-secret", json.dumps(response))
        self.assertEqual(seen[0][0].full_url, worker.JEV_URL)
        self.assertEqual(seen[0][1], 30)

    def test_choice_list_normalizes_for_both_backends(self):
        req = self.req()
        req["questions"]["x"] = {"type": "choice", "instructions": "Pick", "criteria": ["a", "b"]}
        self.assertEqual(worker.validate(req)[0], "evaluate")
        self.assertEqual(req["questions"]["x"]["criteria"], {"a": None, "b": None})

    def test_bad_criteria_types_rejected_before_load(self):
        request = self.req()
        request["questions"]["x"] = {"type": "choice", "instructions": "Pick",
                                      "criteria": {"a": True, "b": None}}
        self.assertEqual(self.worker.handle(request)["error"]["code"], "invalid_request")
        self.assertEqual(self.loads, [])

    def test_load_failure_has_actionable_sanitized_code(self):
        secret_path = "/private/secret/model"

        def missing(model, revision=None):
            raise FileNotFoundError(secret_path)

        w = worker.Worker(loader=missing)
        request = {"id": "warm", "op": "warm", "backend": "mlx", "model": secret_path}
        response = w.handle(request)
        self.assertEqual(response["error"]["code"], "checkpoint_unavailable")
        self.assertNotIn(secret_path, json.dumps(response))

    def test_metal_device_import_failure_is_distinct_from_missing_dependency(self):
        def no_device(model, revision=None):
            raise ImportError("[metal::load_device] No Metal device available. private diagnostic")

        response = worker.Worker(loader=no_device).handle({"id": "w", "op": "warm"})
        self.assertEqual(response["error"]["code"], "device_unavailable")
        self.assertIn("GPU-enabled macOS session", response["error"]["message"])
        self.assertNotIn("private diagnostic", json.dumps(response))

    def test_unload_releases_model_and_mlx_cache(self):
        self.worker.handle({"id": "w", "op": "warm"})
        cleared = []
        mlx = types.ModuleType("mlx.core")
        mlx.clear_cache = lambda: cleared.append(True)
        with mock.patch.dict(sys.modules, {"mlx.core": mlx}):
            response = self.worker.handle({"id": "u", "op": "unload"})
        self.assertTrue(response["ok"])
        self.assertEqual(cleared, [True])
        self.assertIsNone(self.worker.agent)

    def test_default_jev_opener_rejects_redirects(self):
        w = worker.Worker()
        handler = next(h for h in w.opener.__self__.handlers if isinstance(h, worker._NoRedirect))
        self.assertIsNone(handler.redirect_request(
            None, None, 302, "redirect", {}, "https://elsewhere.example"))

    def test_cloud_retries_only_transient_errors(self):
        calls = []

        def open_url(req, timeout):
            calls.append(1)
            raise urllib.error.HTTPError(worker.JEV_URL, 429, "secret", {}, None)

        w = worker.Worker(opener=open_url, sleeper=lambda seconds: None)
        w.jev_api_key = "very-secret"
        req = self.req()
        req["backend"] = "jev"
        response = w.handle(req)
        self.assertEqual(len(calls), 3)
        self.assertEqual(response["error"]["details"], {"status": 429})
        self.assertNotIn("very-secret", json.dumps(response))


if __name__ == "__main__":
    unittest.main()
