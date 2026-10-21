# Notes — AGENTS.md

Read `GEMINI.md` and `CLAUDE.md` first. Communicate with the user in concise Turkish.

## Subagent Routing Contract

The active chat session is the **Coordinator**. All development is performed through the four subagents below:

| Role | Native Antigravity (`.agents/agents/`) | Codex (`.codex/agents/`) | Model Tier |
| :--- | :--- | :--- | :--- |
| **`explorer`** | `explorer.md` | `explorer.toml` | `flash` (Gemini 3.8 Flash) |
| **`coder`** | `coder.md` | `coder.toml` | `flash` (Gemini 3.8 Flash) |
| **`architect`** | `architect.md` | `architect.toml` | `pro` (Gemini 4 Argon) |
| **`reviewer`** | `reviewer.md` | `reviewer.toml` | `pro` (Gemini 4 Argon) |

- When running in Antigravity, use `invoke_subagent` with explicit `Model: "flash"` (`explorer`, `coder`) or `Model: "pro"` (`architect`, `reviewer`).
- When running in Codex or another CLI environment, use `.claude/progress/lib.sh` (`run_subagent <role> <task> <prompt_file>`) or `.codex/agents/<role>.toml`.
- Subagents never run Git write operations (`add`, `commit`, `branch`, `checkout`, `merge`, `push`).
- Every implementation task by `coder` must be verified with `cargo check` / `cargo test` and reviewed by `reviewer` (`pro` / Argon) before acceptance.
