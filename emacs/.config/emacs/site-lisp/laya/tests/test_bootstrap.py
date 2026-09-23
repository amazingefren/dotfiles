"""Tests for the LAYA bootstrap with a fake mise installation."""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path


PACKAGE = Path(__file__).resolve().parents[1]
SCRIPT = PACKAGE / "bootstrap.sh"


class BootstrapTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="laya bootstrap ")
        self.root = Path(self.temp.name)
        self.mock_bin = self.root / "mock bin"
        self.mise_dir = self.root / "mise python" / "3.12.13"
        self.runtime = self.root / "runtime with spaces"
        self.log = self.root / "mise.log"
        self.python_log = self.root / "python.log"
        self.mock_bin.mkdir()
        (self.mise_dir / "bin").mkdir(parents=True)
        self._write(self.mise_dir / "bin" / "python3", self._fake_python())
        self._write(self.mock_bin / "mise", self._fake_mise())
        self._write(self.mock_bin / "uname", self._fake_uname())
        self._write(self.mock_bin / "sw_vers", self._fake_sw_vers())
        self.env = os.environ.copy()
        self.env.update(
            {
                "PATH": f"{self.mock_bin}:/usr/bin:/bin",
                "FAKE_MISE_DIR": str(self.mise_dir),
                "FAKE_MISE_LOG": str(self.log),
                "FAKE_PYTHON_LOG": str(self.python_log),
                "FAKE_PYTHON_HOME": str(self.mise_dir / "bin"),
                "FAKE_OS": "Darwin",
                "FAKE_ARCH": "arm64",
                "FAKE_MACOS_VERSION": "14.0",
            }
        )

    def tearDown(self):
        self.temp.cleanup()

    @staticmethod
    def _write(path, text):
        path.write_text(text, encoding="utf-8")
        path.chmod(0o755)

    @staticmethod
    def _fake_mise():
        return """#!/bin/sh
printf '%s\\n' \"$*\" >> \"$FAKE_MISE_LOG\"
case \"$1\" in
  install) exit 0 ;;
  where) printf '%s\\n' \"$FAKE_MISE_DIR\" ;;
  *) printf 'unexpected mise command: %s\\n' \"$*\" >&2; exit 2 ;;
esac
"""

    @staticmethod
    def _fake_uname():
        return """#!/bin/sh
case \"$1\" in
  -s) printf '%s\\n' \"$FAKE_OS\" ;;
  -m) printf '%s\\n' \"$FAKE_ARCH\" ;;
  *) exit 2 ;;
esac
"""

    @staticmethod
    def _fake_sw_vers():
        return """#!/bin/sh
[ \"$1\" = -productVersion ] || exit 2
printf '%s\\n' \"$FAKE_MACOS_VERSION\"
"""

    @staticmethod
    def _fake_python():
        return """#!/bin/sh
printf 'python=%s' \"$0\" >> \"$FAKE_PYTHON_LOG\"
for arg in \"$@\"; do printf ' <%s>' \"$arg\" >> \"$FAKE_PYTHON_LOG\"; done
printf ' HF_HOME=<%s>\\n' \"${HF_HOME-}\" >> \"$FAKE_PYTHON_LOG\"
if [ \"$1\" = -c ]; then
  case \"$2\" in
    *sys.version_info*) printf '3.12.13\\n' ;;
    *snapshot_download*) printf 'snapshot requested\\n' ;;
    *) printf 'unexpected Python code\\n' >&2; exit 3 ;;
  esac
  exit 0
fi
if [ \"$1\" = -m ] && [ \"$2\" = venv ]; then
  target=$3
  mkdir -p \"$target/bin\"
  cp \"$FAKE_MISE_DIR/bin/python3\" \"$target/bin/python\"
  cp \"$FAKE_MISE_DIR/bin/python3\" \"$target/bin/python3\"
  cat > \"$target/pyvenv.cfg\" <<EOF
home = $FAKE_PYTHON_HOME
include-system-site-packages = false
version = 3.12.13
EOF
  exit 0
fi
if [ \"$1\" = -m ] && [ \"$2\" = pip ]; then exit 0; fi
printf 'unexpected Python command\\n' >&2
exit 4
"""

    def run_bootstrap(self, *args, env=None):
        return subprocess.run(
            [str(SCRIPT), "--runtime-dir", str(self.runtime), *args],
            env=env or self.env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=15,
        )

    def test_default_uses_pinned_mise_python_private_venv_and_snapshot(self):
        result = self.run_bootstrap()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Python 3.12.13", result.stdout)
        self.assertTrue((self.runtime / "venv" / "pyvenv.cfg").is_file())
        self.assertTrue((self.runtime / "huggingface").is_dir())

        mise_calls = self.log.read_text(encoding="utf-8").splitlines()
        self.assertEqual(mise_calls, ["install python@3.12.13", "where python@3.12.13"])
        python_calls = self.python_log.read_text(encoding="utf-8")
        self.assertIn(f"python={self.mise_dir.resolve()}/bin/python3 <-c>", python_calls)
        self.assertIn(f"python={self.runtime}/venv/bin/python <-m> <pip>", python_calls)
        self.assertIn("aac6fef/laya-mlx", python_calls)
        self.assertIn(f"HF_HOME=<{self.runtime}/huggingface>", python_calls)
        self.assertIn("allow_patterns=", python_calls)
        self.assertNotIn("mise use", mise_calls)

    def test_no_model_installs_dependencies_without_snapshot(self):
        result = self.run_bootstrap("--no-model")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("no model was downloaded", result.stdout)
        self.assertIn("<pip>", self.python_log.read_text(encoding="utf-8"))
        self.assertNotIn("snapshot_download", self.python_log.read_text(encoding="utf-8"))
        self.assertFalse((self.runtime / "huggingface").exists())

    def test_jev_only_skips_mlx_and_runs_on_portable_platform(self):
        env = self.env.copy()
        env.update({"FAKE_OS": "Linux", "FAKE_ARCH": "x86_64"})
        result = self.run_bootstrap("--jev-only", env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("portable API runtime", result.stdout)
        python_calls = self.python_log.read_text(encoding="utf-8")
        self.assertNotIn("<pip>", python_calls)
        self.assertNotIn("snapshot_download", python_calls)
        self.assertEqual(self.log.read_text(encoding="utf-8").splitlines(),
                         ["install python@3.12.13", "where python@3.12.13"])

    def test_incompatible_venv_is_preserved_and_existing_backup_is_not_overwritten(self):
        old_venv = self.runtime / "venv"
        old_venv.mkdir(parents=True)
        (old_venv / "pyvenv.cfg").write_text(
            f"home = /opt/homebrew/opt/python@3.14/bin\nversion = 3.14.7\n",
            encoding="utf-8",
        )
        (old_venv / "user-data").write_text("preserve me", encoding="utf-8")
        prior_backup = self.runtime / "venv.previous"
        prior_backup.mkdir()
        (prior_backup / "marker").write_text("keep this too", encoding="utf-8")

        result = self.run_bootstrap("--no-model")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.runtime / "venv.previous" / "marker").read_text(), "keep this too")
        self.assertEqual((self.runtime / "venv.previous.1" / "user-data").read_text(), "preserve me")
        self.assertIn("moved incompatible venv", result.stdout)
        self.assertIn("version = 3.12.13", (self.runtime / "venv" / "pyvenv.cfg").read_text())

    def test_unsupported_mlx_platform_fails_before_mise_install(self):
        env = self.env.copy()
        env.update({"FAKE_OS": "Linux", "FAKE_ARCH": "x86_64"})
        result = self.run_bootstrap(env=env)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("MLX requires macOS on Apple Silicon", result.stderr)
        self.assertFalse(self.log.exists())
        self.assertFalse(self.runtime.exists())

    def test_old_backup_names_are_unique_and_setup_is_idempotent(self):
        first = self.run_bootstrap("--no-model")
        second = self.run_bootstrap("--no-model")
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(second.returncode, 0, second.stderr)
        python_calls = self.python_log.read_text(encoding="utf-8")
        self.assertEqual(python_calls.count("<-m> <venv>"), 1)
        self.assertIn("reusing venv from mise Python 3.12.13", second.stdout)

    def test_conflicting_modes_are_rejected(self):
        result = self.run_bootstrap("--no-model", "--jev-only")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("cannot be combined", result.stderr)
        self.assertFalse(self.log.exists())


if __name__ == "__main__":
    unittest.main()
