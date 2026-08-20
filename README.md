# skill-darwin

An agent skill that makes TDD *verifiable*. Tests that pass prove nothing; a test
earns its place only when someone can show the code change that makes it fail.

darwin runs a task through an **implementer** agent that must write tests before
code and then mutate its own production code to prove each test can fail, a
**reviewer** agent that replays those mutations independently and attacks the
gaps, and an **orchestrator** that verifies both mechanically and decides whether
the work is done, needs another round, or needs a human.

Provider-agnostic (Claude, Codex, Gemini, Cursor, opencode, amp, or any CLI you
configure), language-agnostic (anything with a test command), and dependency-free
beyond `git` and Python 3.8+.

```
orchestrator ──spawn──> implementer  (own worktree: red → green → mutate → report)
      │                     │
      │<────── report ──────┘
      ├── darwin verify   replays every mutant patch; the report is a claim, this is the fact
      ├──spawn──> reviewer (own worktree: replay + adversarial mutants + test audit)
      │<────── review ──────┘
      └── judge: PASS / REVISE (another round) / ESCALATE (human review)
```

## Why mutation, and not coverage

Coverage says a line ran. It does not say anyone would notice if that line were
wrong. A mutant answers the question that matters: *if someone shipped this bug,
would the suite catch it?* A test that survives its mutant is decoration, and a
suite of decorations will not catch tomorrow's regression either.

Because a mutation is stored as a patch, the claim "my test catches this" is
reproducible by anyone, at any later point. That is what turns a report into
evidence, and what lets an orchestrator tell an honest mistake from a fabricated
result instead of taking an agent's word for it.

## Install

```bash
git clone https://github.com/<you>/skill-darwin ~/.claude/skills/darwin
```

Or from an existing clone, for one project:

```bash
mkdir -p .claude/skills && ln -s /path/to/skill-darwin .claude/skills/darwin
```

Then, in Claude Code, `/darwin` — or just ask for a feature "with enforced TDD".
The skill is a plain directory of Markdown plus one Python script, so any harness
that can read `SKILL.md` and run a command can drive it.

## Quickstart

```bash
DARWIN="python3 ~/.claude/skills/darwin/scripts/darwin.py"

$DARWIN doctor                                   # environment check first
$DARWIN init --task "Reject empty slugs with a ValueError"
$DARWIN worktree add --role implementer
$DARWIN spawn  --role implementer --round 1
$DARWIN verify --role implementer --round 1 --verifier orchestrator
$DARWIN worktree add --role reviewer
$DARWIN spawn  --role reviewer --round 1
$DARWIN judge  --round 1
```

`judge` prints the blocking findings and a recommendation; record the verdict
with `--record PASS|REVISE|ESCALATE --reason "..."`. On `REVISE`, run round 2
with `--feedback-file`. When it passes, `land --strategy patch` writes
`RESULT.patch` and `clean` removes the worktrees. The evidence stays behind in
`.darwin/runs/<run-id>/`.

## Isolation

Each role works in its own git worktree on its own branch, so the implementer
cannot quietly patch what the reviewer found, and the reviewer cannot "help".

If [herdr](https://herdr.dev/) is running, worktrees become herdr workspaces and
each agent runs in a persistent pane: it survives a closed laptop, you can watch
it live, and role state (`working` / `idle` / `blocked`) shows up in the herdr UI.
Without herdr it is plain `git worktree` and a subprocess. Messages are files
either way — an append-only `messages.jsonl` plus per-role inboxes — with herdr
adding notifications on top. Nothing requires a daemon, and a herdr failure falls
back rather than losing a round.

## Configuration

Copy `darwin.config.example.json` to `darwin.config.json` in your repository.
The essentials:

```json
{
  "test": { "command": "npm test --silent",
            "single_command": "npm test --silent -- -t {selector}" },
  "max_rounds": 3,
  "mutation": { "min_mutants": 5 },
  "agents": {
    "implementer": { "provider": "claude", "model": "claude-opus-5" },
    "reviewer":    { "provider": "codex",  "model": "gpt-5" }
  }
}
```

`test.env` injects environment variables into every test run — it defaults to
`PYTHONDONTWRITEBYTECODE=1`, since a stale bytecode cache is the classic way for a
mutate-and-revert cycle to produce a result that is not reproducible.

`single_command` is worth setting: it lets the verifier run the specific test the
report names as the killer, so "the suite went red somewhere" cannot pass for
proof. Environment variables (`DARWIN_TEST_CMD`, `DARWIN_IMPL_MODEL`, …) and CLI
flags override the file; `doctor` shows what resolved.

Give the two roles different models. A reviewer that shares the implementer's
blind spots agrees for the wrong reasons.

## What is checked mechanically

Not by an agent reading prose, but by replaying patches and diffing outcomes:

- every mutant re-applied and re-run, its outcome compared with what was claimed
  (`fabricated_kill` = claimed killed, actually survives)
- the named killer test run on its own, and required to be the one that fails
- the baseline suite green on the unmutated tree
- tests added, never deleted, renamed away, skipped or made trivially true
- test and build configuration unchanged
- mutants that touch test files, or no longer apply, rejected
- the report's `head_commit` matching the worktree, and the worktree clean

## Layout

```
SKILL.md                   the orchestrator's playbook
agents/implementer.md      the brief: red → green → mutate → report
agents/reviewer.md         the brief: replay → grade → attack → report
scripts/darwin.py          the whole CLI (stdlib only)
references/protocol.md     run layout, message bus, command reference
references/mutation-catalog.md   operators worth using, and what does not count
references/report-schema.md      MUTATION-REPORT.json, verify.json, REVIEW.json
references/judging.md      guard codes, discrepancy kinds, escalation triggers
references/providers.md    models, providers, custom CLIs, inline mode
```

## Checking it works

```bash
scripts/selftest.sh          # builds a throwaway repo and runs the whole loop
```

17 assertions covering isolation, capture/revert, the refusal to mutate tests,
deterministic replay, the guards, both verdict paths, escalation and cleanup.

## Requirements

`git` (worktrees), Python 3.8+, a test command that exits non-zero on failure,
and at least one agent CLI on `PATH` — or `"provider": "inline"` to drive the
roles from your own harness.

## License

See [LICENSE](LICENSE).
