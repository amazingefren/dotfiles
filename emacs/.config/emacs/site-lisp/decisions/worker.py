#!/usr/bin/env python3
"""Serial JSONL bridge for local decision models and explicitly selected Jev calls."""

import contextlib
import gc
import hashlib
import importlib.util
import json
import os
import re
import sys
import time
import traceback
from pathlib import Path
import urllib.error
import urllib.request

MAX_REQUEST_BYTES = 1024 * 1024
DEFAULT_MLX_MODEL = "mlx-community/clef-flash-8bit"
DEFAULT_LAYA_MODEL = "aac6fef/laya-mlx"
CLEF_REVISION = "dfa0993decb4f8507a0eae01afd1b2d33a4bb734"
CLEF_LOADER_SHA256 = "852223c944819a32fad5cf798d9d1dff30419820eaf5ad1f10cb9698afec97d5"
CLEF_MAX_TOKENS = 16384
DEFAULT_JEV_MODEL = "jev-1.13.0"
JEV_URL = "https://api.typesafe.ai/v1/systemone"
# MLX keeps freed Metal buffers for reuse, and each distinct input length
# allocates new ones, so an uncapped cache grows to many GiB across requests.
MLX_CACHE_LIMIT_BYTES = 256 * 1024 * 1024


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Rejects redirects from the authenticated Jev endpoint."""
    def redirect_request(self, request, fp, code, msg, headers, newurl):
        """Returns no redirect request; credentials remain at the configured endpoint."""
        return None


class WorkerError(Exception):
    """Carries a protocol error code, message, and optional diagnostics."""
    def __init__(self, code, message, details=None):
        """Creates a protocol error with CODE, MESSAGE, and optional DETAILS."""
        super().__init__(message)
        self.code, self.message, self.details = code, message, details


def _finite_constant(value):
    """Rejects non-finite JSON constants with ValueError."""
    raise ValueError("non-finite JSON number")


def _json(value):
    """Returns compact finite JSON for VALUE; raises on invalid values."""
    return json.dumps(value, ensure_ascii=False, allow_nan=False, separators=(",", ":"))


def _validate_json(value):
    """Rejects values outside finite JSON with WorkerError."""
    try:
        _json(value)
    except (TypeError, ValueError, OverflowError) as exc:
        raise WorkerError("invalid_request", "Request must contain finite JSON values") from exc


def validate(request):
    """Validates REQUEST and returns its routing fields; raises WorkerError."""
    if not isinstance(request, dict):
        raise WorkerError("invalid_request", "Request must be an object")
    if not isinstance(request.get("id"), str) or not request["id"] or len(request["id"]) > 128:
        raise WorkerError("invalid_request", "id must be a nonempty string of at most 128 characters")
    op = request.get("op")
    if op not in ("evaluate", "warm", "status", "unload"):
        raise WorkerError("invalid_request", "Unknown operation")
    backend = request.get("backend", "mlx")
    if backend not in ("mlx", "laya", "jev"):
        raise WorkerError("invalid_request", "backend must be mlx, laya, or jev")
    model = request.get("model", {"mlx": DEFAULT_MLX_MODEL, "laya": DEFAULT_LAYA_MODEL, "jev": DEFAULT_JEV_MODEL}[backend])
    if not isinstance(model, str) or not model or len(model) > 256:
        raise WorkerError("invalid_request", "model must be a nonempty string")
    revision = request.get("revision")
    if revision is None and backend == "mlx" and model == DEFAULT_MLX_MODEL:
        revision = CLEF_REVISION
    if revision is not None and (not isinstance(revision, str) or not revision or len(revision) > 128):
        raise WorkerError("invalid_request", "revision must be a nonempty string")
    if backend == "jev" and revision is not None:
        raise WorkerError("invalid_request", "Jev uses a versioned model ID, not revision")
    if op == "evaluate":
        state = request.get("state")
        if not isinstance(state, (str, dict, list)):
            raise WorkerError("invalid_request", "state must be a string, object, or array")
        questions = request.get("questions")
        if not isinstance(questions, dict) or not 1 <= len(questions) <= 64:
            raise WorkerError("invalid_request", "questions must contain 1 to 64 named questions")
        for name, q in questions.items():
            if not isinstance(name, str) or not name or not isinstance(q, dict):
                raise WorkerError("invalid_request", "Each question needs a nonempty name and object definition")
            if q.get("type") not in ("noul", "choice", "score") or not isinstance(q.get("instructions"), (str, dict, list)):
                raise WorkerError("invalid_request", "Question type or instructions are invalid")
            criteria = q.get("criteria")
            if q["type"] == "choice":
                if isinstance(criteria, list):
                    if not 2 <= len(criteria) <= 255 or not all(isinstance(x, str) and x for x in criteria) or len(set(criteria)) != len(criteria):
                        raise WorkerError("invalid_request", "Choice needs 2 to 255 unique labels")
                    q["criteria"] = dict.fromkeys(criteria)
                elif not isinstance(criteria, dict) or not 2 <= len(criteria) <= 255 or not all(isinstance(x, str) and x for x in criteria):
                    raise WorkerError("invalid_request", "Choice needs 2 to 255 options")
                if not all(value is None or isinstance(value, (str, dict, list)) for value in q["criteria"].values()):
                    raise WorkerError("invalid_request", "Choice descriptions must be text, objects, arrays, or null")
            elif q["type"] == "score" and (not isinstance(criteria, list) or not 2 <= len(criteria) <= 10):
                raise WorkerError("invalid_request", "Score needs 2 to 10 levels")
            elif q["type"] == "score" and not all(isinstance(value, (str, dict, list)) for value in criteria):
                raise WorkerError("invalid_request", "Score levels must be text, objects, or arrays")
            elif q["type"] == "noul" and criteria is not None and (not isinstance(criteria, dict) or any(x not in ("true", "false") for x in criteria)):
                raise WorkerError("invalid_request", "Noul needs true/false criteria")
            elif q["type"] == "noul" and criteria is not None and not all(isinstance(value, (str, dict, list)) for value in criteria.values()):
                raise WorkerError("invalid_request", "Noul descriptions must be text, objects, or arrays")
        if not isinstance(request.get("allow_truncation", False), bool):
            raise WorkerError("invalid_request", "allow_truncation must be boolean")
    _validate_json(request)
    return op, backend, model, revision


def _token_ids(tok, text):
    """Returns token IDs for TEXT with mask markers replaced."""
    return tok(text.replace(tok.mask_token, " "), add_special_tokens=False)["input_ids"]


def mlx_context(agent, state, questions):
    """Mirror laya_mlx.common.build_prefix/build_sequence token budgets."""
    from laya_mlx.common import render_options, serialize_state

    tok = agent.tok
    max_len = agent.cfg.get("max_len", 512)
    head_max_len = agent.cfg.get("head_max_len", 192)
    state_tokens = len(_token_ids(tok, serialize_state(state)))
    diagnostics = {}
    for name, definition in questions.items():
        q = agent._to_internal(definition)
        options = render_options(q)
        head = len(_token_ids(tok, f'{q["t"]} question: {q["ins"]}'))
        option_lengths = [len(_token_ids(tok, " " + option)) for option in options]
        capped = [1 + min(48, size) for size in option_lengths]
        budget = head_max_len - sum(capped)
        per = max(4, (head_max_len - 16) // max(1, len(capped))) if budget < 16 else None
        used_options = [min(size, per) for size in capped] if per is not None else capped
        budget = head_max_len - sum(used_options)
        used_head = min(head, max(8, budget))
        prefix = 3 + used_head + sum(used_options)
        room = max(0, max_len - prefix - 1)
        issues = []
        if used_head < head:
            issues.append("instructions")
        if any(raw > 48 for raw in option_lengths) or any(used < capped for used, capped in zip(used_options, capped)):
            issues.append("options")
        if state_tokens > room:
            issues.append("state")
        if prefix + 1 > max_len:
            issues.append("markers")
        diagnostics[name] = {
            "max_tokens": max_len, "head_max_tokens": head_max_len,
            "state_tokens": state_tokens, "state_tokens_available": room,
            "instruction_tokens": head, "instruction_tokens_used": used_head,
            "option_tokens": option_lengths, "option_tokens_used": [size - 1 for size in used_options],
            "truncated": issues,
        }
    return diagnostics


class ClefAgent:
    """Loads the reviewed Clef decision head and returns SystemOne answers."""

    def __init__(self, model, revision):
        """Loads MODEL at REVISION; raises on unavailable files or loader mismatch."""
        from huggingface_hub import hf_hub_download, snapshot_download

        loader_path = Path(hf_hub_download(DEFAULT_MLX_MODEL, "clef_mlx.py", revision=CLEF_REVISION))
        if hashlib.sha256(loader_path.read_bytes()).hexdigest() != CLEF_LOADER_SHA256:
            raise ValueError(f"Clef loader checksum mismatch: {loader_path}")
        specification = importlib.util.spec_from_file_location("decisions_clef_mlx", loader_path)
        if specification is None or specification.loader is None:
            raise ImportError(f"Clef loader is unavailable: {loader_path}")
        self.module = importlib.util.module_from_spec(specification)
        sys.modules[specification.name] = self.module
        specification.loader.exec_module(self.module)
        self.model_dir = Path(model) if Path(model).is_dir() else Path(snapshot_download(
            model, revision=revision,
            allow_patterns=["*.safetensors", "*.json", "*.jinja", "*.txt", "*.model"],
        ))
        self.agent = self.module.load(self.model_dir)
        self.model = model

    def context(self, state, questions):
        """Returns exact text token budgets; raises when the schema exceeds 16K."""
        record = {"questions": questions, "state": state}
        state_tokens = len(self.agent.tokenizer(self.module.render(state), add_special_tokens=False).input_ids)
        empty = self.module.encode_record(self.agent.tokenizer, {**record, "state": ""},
                                          max_length=CLEF_MAX_TOKENS, truncate=False)
        available = CLEF_MAX_TOKENS - len(empty.input_ids)
        return {name: {"max_tokens": CLEF_MAX_TOKENS, "state_tokens": state_tokens,
                       "state_tokens_available": available,
                       "truncated": ["state"] if state_tokens > available else []}
                for name in questions}

    def predict(self, state, questions, allow_truncation=False):
        """Returns typed probabilities; rejects oversized input unless explicitly allowed."""
        result = self.agent.systemone({"model": self.model, "questions": questions, "state": state},
                                     max_length=CLEF_MAX_TOKENS, truncate=allow_truncation)
        for answer in result["answers"].values():
            if answer["type"] == "noul":
                answer["confidence"] = max(answer["noul"], 1 - answer["noul"])
        return result


class Worker:
    """Processes serial requests and retains one local model between calls."""
    def __init__(self, *, loader=None, opener=None, sleeper=None):
        """Creates a worker with optional model, HTTP, and retry dependencies."""
        self.loader = loader
        self.opener = opener or urllib.request.build_opener(_NoRedirect()).open
        self.sleeper = sleeper or time.sleep
        self.agent = None
        self.loaded_key = None
        self.jev_api_key = None

    def _trim_cache(self):
        """Releases cached Metal allocations from an imported runtime."""
        # The loaded runtime already imported MLX; avoid importing it for status/unload.
        mlx = sys.modules.get("mlx.core")
        if mlx is not None:
            try:
                mlx.clear_cache()
            except RuntimeError:
                pass

    def _release(self):
        """Unloads the retained model and releases unused cache allocations."""
        self.agent, self.loaded_key = None, None
        gc.collect()
        self._trim_cache()

    def _load(self, backend, model, revision):
        """Loads BACKEND, MODEL, and REVISION; raises a structured load error."""
        key = (backend, model, revision)
        if self.agent is not None and key == self.loaded_key:
            return self.agent
        self._release()
        try:
            with contextlib.redirect_stdout(sys.stderr):
                if self.loader is None:
                    if backend == "mlx":
                        agent = ClefAgent(model, revision)
                    else:
                        import laya_mlx
                        agent = laya_mlx.load(model, revision=revision)
                else:
                    agent = self.loader(model, revision=revision)
        except (ImportError, ModuleNotFoundError) as exc:
            if "[metal::load_device] No Metal device available" in str(exc):
                raise WorkerError("device_unavailable", "MLX cannot access a Metal GPU in this session; run the worker in a GPU-enabled macOS session") from exc
            raise WorkerError("dependency_unavailable", "Decision runtime or a native dependency is unavailable in the worker Python") from exc
        except FileNotFoundError as exc:
            raise WorkerError("checkpoint_unavailable", "Checkpoint files are unavailable; verify the model path or cache") from exc
        except MemoryError as exc:
            raise WorkerError("insufficient_memory", "Insufficient memory to load the local model") from exc
        except (ValueError, OSError, RuntimeError) as exc:
            raise WorkerError("model_load_failed", "Local model load failed; verify checkpoint, device, and cache setup",
                              {"exception": type(exc).__name__}) from exc
        self.agent, self.loaded_key = agent, key
        mlx = sys.modules.get("mlx.core")
        if mlx is not None and hasattr(mlx, "set_cache_limit"):
            mlx.set_cache_limit(MLX_CACHE_LIMIT_BYTES)
        return agent

    def _resolved_revision(self, agent, revision):
        """Returns the snapshot commit or an explicitly requested commit."""
        model_dir = getattr(agent, "model_dir", None)
        if model_dir is not None:
            path = os.fspath(model_dir)
            parts = path.split(os.sep)
            if "snapshots" in parts:
                index = parts.index("snapshots")
                if index + 1 < len(parts):
                    return parts[index + 1]
        # A symbolic revision such as "main" is a request, not a resolved commit.
        return revision if revision and re.fullmatch(r"[0-9a-fA-F]{40}", revision) else None

    def _jev(self, model, state, questions):
        """Returns Jev answers; raises WorkerError on HTTP or response errors."""
        key = self.jev_api_key or os.environ.get("TYPESAFE_API_KEY")
        if not key:
            raise WorkerError("not_configured", "Jev API key is unavailable")
        body = _json({"model": model, "state": state, "questions": questions}).encode("utf-8")
        for attempt in range(3):
            req = urllib.request.Request(JEV_URL, data=body, method="POST", headers={
                "Authorization": "Bearer " + key, "Content-Type": "application/json",
            })
            try:
                with self.opener(req, timeout=30) as response:
                    data = response.read(MAX_REQUEST_BYTES + 1)
                if len(data) > MAX_REQUEST_BYTES:
                    raise WorkerError("response_too_large", "Jev response exceeded 1 MiB")
                result = json.loads(data, parse_constant=_finite_constant)
                if not isinstance(result, dict) or not isinstance(result.get("answers"), dict):
                    raise WorkerError("upstream_error", "Jev returned an invalid response")
                return result
            except urllib.error.HTTPError as exc:
                exc.close()
                if exc.code in (429, 529) and attempt < 2:
                    delay = min(4, 0.5 * 2**attempt)
                    retry_after = exc.headers.get("Retry-After") if exc.headers else None
                    if retry_after:
                        try:
                            delay = min(5, max(delay, float(retry_after)))
                        except ValueError:
                            pass
                    self.sleeper(delay)
                    continue
                raise WorkerError("upstream_http", f"Jev returned HTTP {exc.code}", {"status": exc.code}) from None
            except (urllib.error.URLError, TimeoutError, OSError):
                raise WorkerError("upstream_network", "Jev request failed or timed out") from None
            except (ValueError, UnicodeError):
                raise WorkerError("upstream_error", "Jev returned invalid JSON") from None
        raise WorkerError("upstream_error", "Jev retry limit reached")

    def handle(self, request):
        """Returns a protocol response for REQUEST or a structured error."""
        if isinstance(request, dict) and request.get("op") == "configure":
            key = request.get("jev_api_key")
            if isinstance(key, str) and key:
                self.jev_api_key = key
            return None
        request_id = request.get("id") if isinstance(request, dict) else None
        try:
            op, backend, model, revision = validate(request)
            start = time.monotonic()
            if op == "status":
                result = {"backend": self.loaded_key[0] if self.loaded_key else backend, "checkpoint": self.loaded_key[1] if self.loaded_key else None,
                          "revision": self._resolved_revision(self.agent, self.loaded_key[2]) if self.agent else None,
                          "loaded": self.agent is not None}
            elif op == "unload":
                self._release()
                result = {"backend": backend, "checkpoint": None, "revision": None, "loaded": False}
            elif backend in ("mlx", "laya"):
                agent = self._load(backend, model, revision)
                actual_revision = self._resolved_revision(agent, revision)
                if op == "warm":
                    result = {"backend": backend, "checkpoint": model, "revision": actual_revision,
                              "loaded": True, "context": None}
                else:
                    try:
                        context = (agent.context(request["state"], request["questions"]) if backend == "mlx"
                                   else mlx_context(agent, request["state"], request["questions"]))
                    except (ValueError, TypeError, KeyError) as exc:
                        raise WorkerError("context_budget", "Local schema exceeds the context budget",
                                          {"exception": type(exc).__name__}) from exc
                    if any(x["truncated"] for x in context.values()) and not request.get("allow_truncation", False):
                        raise WorkerError("context_budget", "Local model would truncate input", context)
                    try:
                        with contextlib.redirect_stdout(sys.stderr):
                            native = (agent.predict(request["state"], request["questions"],
                                                    allow_truncation=request.get("allow_truncation", False))
                                      if backend == "mlx" else agent.predict(request["state"], request["questions"]))
                    except MemoryError as exc:
                        raise WorkerError("insufficient_memory", "Insufficient memory for local inference") from exc
                    except FloatingPointError as exc:
                        raise WorkerError("numerical_error", "Local inference produced non-finite values") from exc
                    except (ValueError, RuntimeError) as exc:
                        raise WorkerError("inference_failed", "Local inference failed; check question schema and model limits",
                                          {"exception": type(exc).__name__}) from exc
                    finally:
                        self._trim_cache()
                    result = dict(native)
                    result.update(backend=backend, checkpoint=model, revision=actual_revision, context=context)
            elif op == "warm":
                raise WorkerError("invalid_request", "Jev does not support warm")
            else:
                if op != "evaluate":
                    raise WorkerError("invalid_request", "Operation requires the MLX backend")
                native = self._jev(model, request["state"], request["questions"])
                result = dict(native)
                result.update(backend="jev", checkpoint=native.get("model"), revision=None, context=None)
            result["timing_ms"] = round((time.monotonic() - start) * 1000, 2)
            _validate_json(result)
            if len(_json(result).encode("utf-8")) > MAX_REQUEST_BYTES:
                raise WorkerError("response_too_large", "Decision response exceeded 1 MiB")
            return {"id": request_id, "ok": True, "result": result}
        except WorkerError as exc:
            error = {"code": exc.code, "message": exc.message}
            if exc.details is not None:
                error["details"] = exc.details
            return {"id": request_id, "ok": False, "error": error}
        except Exception as exc:
            for frame in traceback.extract_tb(exc.__traceback__):
                print(f"  {frame.filename}:{frame.lineno} in {frame.name}", file=sys.stderr)
            print(f"Decision worker failed: {type(exc).__name__}", file=sys.stderr)
            return {"id": request_id, "ok": False, "error": {"code": "worker_error", "message": "Decision worker failed"}}


def main():
    """Reads JSONL requests and writes one response for each request."""
    worker = Worker()
    sys.stdout.write('{"event":"ready","protocol":1}\n')
    sys.stdout.flush()
    source = sys.stdin.buffer
    while True:
        line = source.readline(MAX_REQUEST_BYTES + 2)
        if not line:
            break
        if len(line) > MAX_REQUEST_BYTES + 1:
            while line and not line.endswith(b"\n"):
                line = source.readline(MAX_REQUEST_BYTES + 2)
            response = {"id": None, "ok": False, "error": {"code": "request_too_large", "message": "Request exceeded 1 MiB"}}
        else:
            try:
                request = json.loads(line, parse_constant=_finite_constant)
                with contextlib.redirect_stdout(sys.stderr):
                    response = worker.handle(request)
            except (ValueError, UnicodeError):
                response = {"id": None, "ok": False, "error": {"code": "invalid_json", "message": "Malformed JSON request"}}
        if response is not None:
            sys.stdout.write(_json(response) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    main()
