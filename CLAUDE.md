# Notes — CLAUDE.md

Read `GEMINI.md` and `AGENTS.md` before starting any work. Communicate with the user in concise Turkish unless asked otherwise.

## Agentic Architecture & Strict Subagent Routing

Whichever chat environment starts the session acts as the **Coordinator**. Every development step (discovery, design, coding, code review) **must** be executed via subagents using the following strict model mapping:

| Subagent Role | Definition | Model Tier | Target Model | Responsibility |
| :--- | :--- | :--- | :--- | :--- |
| **`explorer`** | `.agents/agents/explorer.md` / `.claude/agents/explorer.md` | `flash` | Gemini 3.8 Flash | Read-only codebase discovery, symbol lookup, `file:line` digests. |
| **`coder`** | `.agents/agents/coder.md` / `.claude/agents/coder.md` | `flash` | Gemini 3.8 Flash | Code authoring, unit tests, bug fixes within assigned file scope. |
| **`architect`** | `.agents/agents/architect.md` / `.claude/agents/architect.md` | `pro` | Gemini 4 Argon | System architecture, data schemas, E2EE crypto & sync contracts (no code writing). |
| **`reviewer`** | `.agents/agents/reviewer.md` / `.claude/agents/reviewer.md` | `pro` | Gemini 4 Argon | Read-only code, security, cryptography & architecture review. |

### How to Invoke
- **In Antigravity:** Call `invoke_subagent` with `TypeName` set to `explorer`, `coder`, `architect`, or `reviewer` and `Model` explicitly set to `"flash"` or `"pro"`.
- **In Claude Code / Terminal:** Use the native subagent definitions in `.claude/agents/` or source `.claude/progress/lib.sh` and run `run_subagent <role> <task_name> <prompt_file>` to dispatch to the exact Flash/Argon model tier.

## Workflow Rules
1. **Coordinator does not author application code directly.** Always delegate implementation to `coder` (`flash`), design to `architect` (`pro`), discovery to `explorer` (`flash`), and review to `reviewer` (`pro`).
2. **Disjoint Write Scopes:** Parallel `coder` tasks must never touch the same files.
3. **Git Ownership:** Subagents never run Git write commands (`add`, `commit`, `branch`, `checkout`, `merge`, `push`). Only the Coordinator runs Git commands after `cargo check`, `cargo test`, and `reviewer` approval.
