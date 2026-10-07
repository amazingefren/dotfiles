# Decisions in Emacs

A programmable harness for typed decisions, with local Clef and Laya backends,
an optional Jev backend, an editable playground, and scoped agent tools.
It returns probabilities and scores without generating text.
This Emacs config queues Clef-flash loading after two seconds of startup idle
time and keeps the model resident until `M-x decisions-stop` or Emacs exits.

## Bootstrap each machine

Install [mise](https://mise.jdx.dev/getting-started.html) first, then run:

```text
M-x decisions-bootstrap
```

The command runs asynchronously in a compilation buffer. It installs a pinned
Python through mise, creates a private virtualenv, installs the pinned MLX
runtime, and downloads Clef-flash 8-bit. It does not change your
global Python selection or install packages into a global Python environment.

The same setup can run from a terminal:

```sh
bash ~/.config/emacs/site-lisp/decisions/bootstrap.sh
```

Code and dependency requirements travel with this config through Git.
`etc/decisions/` holds the virtualenv and Hugging Face model cache; it is already
ignored by this dotfiles repository and must be bootstrapped on each machine.
Rerun bootstrap after dependency changes. Stop the worker before updating its
environment (`M-x decisions-stop`). Default model weights occupy about 10.7 GB;
inference uses additional memory.

MLX requires Apple Silicon and macOS 14 or later. On another platform,
`M-x decisions-bootstrap-jev` prepares the Python worker for Jev without installing
MLX or downloading weights. Backend selection remains explicit.

If you need dependencies without the initial checkpoint download, use the
shell command with `--no-model`. The checkpoint is then downloaded on the first
local request. A configured `decisions-python` can select an existing compatible
virtualenv instead of the bootstrapped one.

## Playground

Run `M-x decisions-playground`, edit the JSON, then press `C-c C-c`. A separate results
buffer displays answers, full distributions, model metadata, timings, and context
budget information. Your editing buffer stays usable while a request runs.

| Key | Action |
| --- | --- |
| `C-c C-c` | Submit the current request |
| `C-c C-k` | Cancel this experiment |
| `C-c C-r` | Show status or the last result |
| `q` in Evil normal or motion state | Close the current playground or result window |
| `C-c C-q` | Close the current playground or result window from any state |
| `C-c C-s` | Save input and the previous run as JSON |
| `C-c C-o` | Open a saved experiment without running it |

In the editable playground, `q` stays ordinary text in Evil insert state. Use
`C-c C-q` to close it from insert state or standard Emacs state.

`M-x decisions-playground-region` captures a selection into a new experiment.
Saved files keep the editable request and the previous run separately, so edits
after a run cannot be confused with the input that produced that result.
Saving is explicit; requests are otherwise retained only in bounded memory.
Opening an experiment reads data only and never evaluates Lisp.

Example request (replace the state, question, and criteria freely):

```json
{
  "backend": "mlx",
  "state": {"message": "Could you explain this?"},
  "questions": {
    "intent": {
      "type": "choice",
      "instructions": "What does the message request?",
      "criteria": {
        "explain": "An explanation",
        "change": "A modification",
        "other": "Something else"
      }
    }
  },
  "allow_truncation": false
}
```

Optional `model` selects a compatible checkpoint or a local checkpoint directory.
Optional `revision` pins a Hugging Face revision. Backend `mlx` uses Clef's
decision loader and defaults to `mlx-community/clef-flash-8bit`.
Backend `laya` uses `laya-mlx` and defaults to `aac6fef/laya-mlx`;
its other checkpoints include `aac6fef/laya-multilingual-mlx` and
`aac6fef/laya-typed-decisions-mlx`.
Loading a different checkpoint replaces the resident local model. Checkpoint
selection is explicit; the harness does not silently switch by language or task.

## Use from Elisp

`decisions-submit` returns a job ID immediately. Its completion callback receives
one snapshot on a later Emacs event-loop turn. There is no synchronous model
evaluation on Emacs's main thread.

```elisp
(let ((questions
       (json-parse-string
        "{\"check\":{\"type\":\"noul\",\"instructions\":\"Does the text ask a question?\"}}")))
  (decisions-submit
   "Could you explain this?" questions
   :callback
   (lambda (snapshot)
     (if (equal (gethash "status" snapshot) "succeeded")
         (message "%S" (gethash "answers" (gethash "result" snapshot)))
       (message "Decisions: %S" (gethash "error" snapshot))))))
```

Compose workflows with ordinary Elisp functions and callbacks: extract some
state, submit named questions, inspect the result, and choose the next step.
A result never executes an action automatically. You control any resulting
editor operation or subsequent request.

Questions are string-keyed hash tables, JSON arrays are vectors, and JSON null
and false are represented by `:null` and `:false`. Preserve those values when
building or parsing structured state. `noul` is P(true), `score` is the expected
zero-based rubric index, and `confidence` summarizes a probability distribution.
It is not a measured probability of correctness for your task.

Other API calls:

- `(decisions-result id)` returns `queued`, `running`, `succeeded`, `failed`, or
  `cancelled` with the request and any result/error.
- `(decisions-cancel id)` removes queued work or marks a running request cancelled.
- `M-x decisions-start` starts Python without loading weights.
- `M-x decisions-warm` explicitly loads the local checkpoint and returns a job ID.
- `M-x decisions-status`, `decisions-stop`, and `decisions-restart` manage the worker.

Running cancellation discards the eventual result; it does not interrupt a
GPU operation. The next queued request waits for that operation to finish.
Timeouts stop the worker and fail outstanding work; a subsequent submission
starts a fresh worker. The package's idle shutdown default is ten minutes;
this Emacs config sets `decisions-idle-seconds` to nil and keeps it hot.
Customize `decisions-idle-seconds`, `decisions-request-timeout`,
`decisions-max-queue`, and `decisions-retained-jobs` as needed.

## Editor advisors

| Key | Command | Result |
| --- | --- | --- |
| `SPC d f` | `decisions-feeds-rank` | Elfeed-style view sorted by reading recommendation |
| `SPC d o` | `decisions-org-advise` | Org heading or agenda task: do, wait, someday, or clarify |
| `SPC d c` | `decisions-integrations-cancel` | Cancel the current buffer's advisor |
| `SPC d p` | `decisions-playground` | Editable questions and state |
| `SPC d r` | `decisions-playground-region` | Experiment with selected text |
| `SPC d s` | `decisions-status` | Worker and queue status |
| `SPC d w` | `decisions-warm` | Load the default local model |
| `SPC d x` | `decisions-stop` | Stop the worker and release model memory |

The Org advisor runs on demand and displays a label, confidence, and option
probabilities in a read-only result buffer. Task states stay unchanged.
A replacement request cancels the previous advisor in that buffer.
Changing the selected task or editing its notes discards stale results.

## Ranked feeds

`SPC d f` opens `*Decisions feeds*` with read and unread entries from the last
two weeks in this Emacs config. `decisions-feeds-default-filter` sets the initial
filter. Publication days use the local time zone and appear newest first.
Recommendations sort highest first within each day. Rows retain Elfeed's date,
title, feed, tags, and unread styling, with an explicit read/unread column.
Each scored row adds its recommendation, confidence, and reading value:
P(read-now) + 0.5 × P(save).

Recommendations are read-now, save, skip, or undetermined. Read-now prioritizes
meaningful news: major launches, substantial capability changes, important
research, ecosystem developments, and actionable advisories. Deadlines are
optional. Evergreen material and routine updates receive save. Missing content,
vague teasers, and inconclusive excerpts can receive undetermined. A short
factual summary can support a recommendation. Hype alone does not.

Results appear during classification. Pending and failed entries are labeled.
The header shows scored/total progress, the filter, and running status.
`elfeed-search-max-entries` limits visible rows; classification covers the
whole matching collection. The selected article stays selected when rows move.

| Key | Action |
| --- | --- |
| `RET` | Read the article in Elfeed and mark it read |
| `C-u RET` | Preview without marking read |
| `b` / `B` | Open in the embedded / external browser |
| `r` / `u` | Mark read / unread |
| `*` | Toggle star |
| `s` | Set this view's Elfeed filter |
| `F` | Pick a configured feed filter |
| `+` | Show more entries and older days without restarting classification |
| `g` | Refresh the snapshot and score uncached entries |
| `C-c C-k` | Stop classification |
| `q` | Stop classification and close the window |

Filters affect this view only. Cached predictions stay in its buffer and
are reused across refreshes and filter changes. Article content, metadata,
model, content type, and reading criteria changes invalidate a prediction.
Read/unread changes retain its recommendation.
Killing the view drops its cache. Classification reads stored RSS content as
plain text, strips HTML markup, scripts, and styles, and does not download
images or fetch full webpages. Some feeds store only summaries. Classification
does not change tags or read status. Explicit reading and tagging commands
use Elfeed's existing entry and tag APIs.

## Code review

`SPC g R` (`M-x decisions-review`) splits a diff into hunks, asks the model the
rubric's questions about each one, and lists them riskiest first while
scoring continues. In a magit diff or `diff-mode` buffer it reviews what
that buffer shows; elsewhere it reviews uncommitted changes against HEAD.
`SPC g V` reviews the current branch against main, and `SPC u SPC g R`
offers staged changes or a revision range.

| Key | Action |
| --- | --- |
| `RET` | Open the changed line |
| `TAB` | Expand a file's units, or a unit's model calls, answers and diff |
| `]]` / `[[` | Next or previous row |
| `f` | Hide hunks below `decisions-review-focus-threshold` |
| `a` | List or fold the units no question applied to |
| `d` | Focused diff: a `diff-mode` buffer of only the hunks that matter |
| `s` | Cycle the view: riskiest units, grouped by file, diff order |
| `v` | Show the exact state and questions each call sends for the unit |
| `e` | Edit the rubric; `gr` rescores with it |
| `C-c C-k` | Stop scoring |

### Review units

In the file view each file is one row with its highest risk, how many
units it was split into, how many model calls they made, and how many
had nothing to ask. `TAB` lists its units by line and function, and `TAB`
on a unit lists each call (the code call and, when it has comments, the
comments call) with its questions, answers and time. `v` shows the JSON
that went to the model, definitions included, so you can see which slice
of a large file each call judged.


A hunk longer than the backend's `chunk_lines` rows is split into review
units along function boundaries. The file is read at the diff's new side
(the range's end revision, the index for staged changes, or the worktree),
parsed with its tree-sitter mode, or `beginning-of-defun` when there is no
grammar, with mode hooks delayed so no language server starts. A function
that fits is one unit, small neighbours share one, and a function that is
too long is split into its inner functions, then into runs of rows. Each
unit is a valid hunk named after the functions it covers, so `RET` and the
focused diff still work. When the file does not match the diff, as with a
pasted `diff-mode` buffer, units are plain runs of rows.

Each unit also carries `definitions`: the source of helpers it calls that
are defined elsewhere in the same file, at most
`decisions-review-max-definition-lines` long. A call to `csvCell(...)` 300 lines
below its definition is judged with the definition in view.

### Comments

A comment cannot vouch for code. Before the code questions see a unit, its
comments are moved out of `added`, `removed` and `definitions`, using the
file's major mode, or a built-in mode with the same comment syntax, to
tell a comment from a `//` inside a string or URL. Python docstrings count
as comments. A comment such as "reviewed by security, safe" above code
that posts decrypted keys to another host is never seen by the question
asking whether the code sends credentials away.

The comments are judged on their own instead, in a second job whose state
holds `comments` beside the comment-free `code`. Questions with
`"state": "comments"` ask it: `steering_comment` (does a comment argue the
code is safe or tell a reviewer or AI not to flag it), `comment_mismatch`
(does a comment describe something the code does not do, or hide something
significant it does), and `non_functional_comment` (is it more than a
functional description: persuasion, claims about reliability, history).
`comments_matches` gates them on the extracted comment text, so code
without comments asks nothing. Both jobs' answers are merged before the
risk is scored.

### Rubric

The rubric, `review-rubric.json`, is data. Each question is one narrow
noul with `true`/`false` criteria about the unit's state fields (`file`,
`location`, `change`, `removed`, `added`, and `definitions` when present),
plus a `risk` weight. A noul's risk is P(true) x `true` + P(false) x
`false`; a choice's is the sum of P(option) x weight, and a score's the sum
of P(level) x weight. A unit's risk is its largest contribution.

Facts code can check are gates, not questions. A question is asked only
when its gates match: `added_matches`, `removed_matches` (which also needs
removed lines), `changed_matches` over both sides, and `files`; and neither
the rubric's nor the question's `skip_files` matches the path. A gate is an
Emacs regexp, or an array of regexps that must all match. Gates are matched
case-insensitively with code punctuation ending a symbol, so `\_<md5`
matches in `hashlib.md5`. A unit no question applies to scores 0 without
calling the model.

The 22 questions cover secrets, SQL, command and deserialization injection,
XSS, CSV formula injection, weakened auth, loosened security settings,
unauthenticated routes, credentials sent to the wrong service, secrets or
personal data in logs, missing size or spend limits, path traversal, SSRF,
open redirects, insecure randomness, removed checks, swallowed errors,
destructive writes, and comments that steer, mislead, or narrate. None of
them reason across the whole diff: logic bugs, races, and design problems
need a reviewer that reads everything.

`"backend"` picks the model, and `"backends"` holds per-backend budgets:

```json
"backend": "mlx",
"backends": {
  "mlx": {"max_state_characters": 12000, "chunk_lines": 150},
  "laya": {"max_state_characters": 950, "chunk_lines": 25},
  "jev": {"max_state_characters": 6000, "chunk_lines": 150}
}
```

A model that reads little state wants small units; one with a long context
can take whole functions. Switching backend keeps the questions.

### Evaluation

`M-x decisions-review-eval` scores the rubric against `tests/review-cases.json`,
labeled snippets with at least one bad and one fine case per question, and
shows recall, precision, false alarms, gate misses, and the mean P on bad
and fine cases per question. Run it after changing a question or a gate. In
batch: `emacs --batch -l tests/review-eval.el [RUBRIC]`. A case with
`"expect": {}` must not be flagged by any question it is asked.

### Rubric lint

`M-x decisions-review-lint-rubric` asks the rubric's backend to judge the
rubric's own questions: whether each combines separate conditions, leads
toward an answer, has true and false criteria that overlap or leave gaps,
needs information its state does not hold, or hinges on an undefined word.
The state sent is the question and a description of its state's fields,
never repository code. Two control questions, one built badly and one
clean, are linted alongside; if a control does not come out as expected,
do not trust the other results either. In batch:
`emacs --batch -l tests/rubric-lint.el [RUBRIC]`. The meta-questions live
in `rubric-lint.json`.

Other code can score a hunk with `decisions-review-submit-hunk`, which takes a
hunk plist from `decisions-review-parse-diff` or `decisions-review-split-hunks` and
calls back with the risk, reason and answers.

## Agent access

Herdr-launched agents using this config's Emacs MCP bridge receive:

| Tool | Purpose |
| --- | --- |
| `emacs_decisions_submit` | Submit arbitrary state and named questions |
| `emacs_decisions_result` | Poll a job's status and retrieve its result |
| `emacs_decisions_cancel` | Cancel a job |

The submit fields match the playground JSON. Result and cancel take `id`.
Wait between polls. Calls remain short: inference runs in the shared worker.
Jobs belong to the workspace/session/pane/name injected by the existing bridge;
one agent cannot read or cancel another agent's jobs by guessing an ID. There
is no new general-purpose Lisp evaluation tool.

Restart an existing agent to refresh its advertised MCP tool list after loading
the new Emacs configuration. This package does not modify an active session
automatically.

## Jev

Set `"backend": "jev"` in a request. The default model is the pinned
`jev-1.13.0`; use a different version in `model` or customize `decisions-jev-model`.
Jev uses model IDs rather than the local `revision` option.

The API key is resolved only for a Jev request, from `TYPESAFE_API_KEY` in Emacs's
environment or `auth-source` with host `api.typesafe.ai`. For an encrypted
authinfo file, a record has this form:

```text
machine api.typesafe.ai login apikey password YOUR_TOKEN
```

Alternatively customize `decisions-jev-key-function` to a function that reads your
preferred secret store. Tokens never belong in playground JSON, saved
experiments, or MCP arguments. No request falls back from local inference to
Jev automatically. A cloud request already sent may still be processed after
you cancel it locally.

## Context and reproducibility

The harness checks the local tokenizer's instruction, option, and state budgets
before inference. It fails with `context_budget` if input would be truncated.
To experiment with truncation explicitly, set `allow_truncation` to `true`;
the result reports which parts were affected. Jev context accounting is not
assumed to match MLX and is reported as unavailable by this adapter.

Results preserve native answer fields and report the backend, selected
checkpoint, resolved revision when available, usage, and operation timing.
First-use timing includes model loading. Pin a revision or use a local checkpoint
directory for repeatable experiments. To guarantee offline operation, use a
local downloaded checkpoint path with the loader cached, or set
`HF_HUB_OFFLINE=1` after bootstrap and before starting the worker; a Hub model
ID may otherwise make metadata requests when loading.

The default Clef-flash weights and decision loader are pinned to revision
`dfa0993decb4f8507a0eae01afd1b2d33a4bb734`. The worker verifies the loader's
SHA256 before importing it. Other Clef checkpoints use this same loader;
Laya checkpoints use their separate backend. Generic text generation loaders
do not run Clef's decision head.

## Browser QA as an extension

The harness can supply the decision step in a browser QA runner. A runner still
needs to observe a browser, expose a bounded action space, execute the chosen
action, and independently verify assertions. `DONE` is not a passing test.

[jev-ultrafast](https://github.com/browser-use/jev-ultrafast/) is a useful
reference: it builds indexed DOM observations and uses a separate text model
for text entry. A coding agent could instead supply fixed test values. A Decisions
adapter would also need to fit observations and action candidates into the
selected model's context budget. Browser automation and a browser QA runner are not
included in this core package.

An Emacs xwidget WebKit buffer can be a future browser driver:
`xwidget-webkit-execute-script` supports evaluating page JavaScript and returning
the result through a callback. A driver would bind each run to an explicit
widget, extract indexed controls, revalidate targets before acting, and check
assertions after observing the new page. The Chrome driver from `jev-ultrafast`
would need replacing, and script-generated input is not equivalent to trusted
keyboard/mouse input on every site. This route has not been browser-tested here.

## Verification

From the dotfiles repository root:

```sh
PYTHONDONTWRITEBYTECODE=1 emacs/.config/emacs/etc/decisions/venv/bin/python -m unittest discover -s emacs/.config/emacs/site-lisp/decisions/tests -p 'test_*.py'
emacs -Q --batch -L emacs/.config/emacs/site-lisp/decisions -l emacs/.config/emacs/site-lisp/decisions/tests/decisions-test.el -l emacs/.config/emacs/site-lisp/decisions/tests/decisions-ui-test.el -l emacs/.config/emacs/site-lisp/decisions/tests/decisions-review-test.el -l emacs/.config/emacs/site-lisp/decisions/tests/decisions-integrations-test.el -f ert-run-tests-batch-and-exit
```

With Elfeed's installed package directory on `load-path`, run the ranked-view
checks as well:

```sh
emacs -Q --batch -L PATH_TO_ELFEED -L emacs/.config/emacs/site-lisp/decisions -l emacs/.config/emacs/site-lisp/decisions/tests/decisions-feeds-daily-test.el -f ert-run-tests-batch-and-exit
```

Unit tests use fake inference and HTTP fixtures; they require neither model
weights nor a Jev token. Real MLX smoke tests require the bootstrapped runtime.

```sh
emacs -Q --batch -l emacs/.config/emacs/site-lisp/decisions/tests/live-smoke.el
```

That check evaluates all three primitives through a real worker, repeats the
request with the loaded model, exercises MCP submit/result, and renders a
playground result. It starts a separate batch Emacs and never connects to your
running editor or calls Jev.

MLX needs access to the Mac's Metal GPU. A restricted tool sandbox or a session
without GPU access can return `device_unavailable` even when installation is
correct; run the local check from a normal macOS session with GPU access.

Upstream references: [Clef-flash MLX](https://huggingface.co/mlx-community/clef-flash-8bit),
[Clef](https://huggingface.co/Cloudflare/clef-flash),
[Laya MLX](https://github.com/mizorewww/laya-mlx),
[Laya](https://github.com/NandhaKishorM/laya),
[Jev HTTP API](https://docs.typesafe.ai/api).
