# Session format

Switchpanel's app doesn't talk to Claude Code. It only reads JSON files in `~/.switchpanel/sessions/` (or `$SWITCHPANEL_DIR/sessions/`). Anything that writes files in this format shows up in the panel, so supporting another coding agent means writing an adapter for its hooks or plugin system. No app changes are needed.

`hooks/switchpanel.py` is the Claude Code adapter and the reference implementation.

## Files

- One file per session: `sessions/<session_id>.json`.
- Write atomically: write to a temporary file in the same folder, then rename it over the target.
- While updating a session, hold an exclusive `flock` on `locks/<session_id>.lock`. The app takes the same lock when it changes the label.
- `config.json` (accounts and projects) uses `locks/config.lock`.
- Timestamps are local time with offset: `2026-10-22T16:42:55-0300` (`strftime("%Y-%m-%dT%H:%M:%S%z")`).

## Fields

Only `session_id` is required. Everything else is optional, and the app tolerates missing fields.

| Field | Type | Meaning |
|---|---|---|
| `session_id` | string | Unique id; also the file name. |
| `agent` | string | Which agent wrote it: `claude-code`. Missing means `claude-code`. |
| `account` | string | Account key, used to group sessions and to look up `accounts` in `config.json`. Claude Code uses the config folder name (`.claude`, `.claude-work`). |
| `project` | string | Absolute path of the project (git root when there is one). Key into `projects` in `config.json`. |
| `cwd` | string | Working directory, used when `project` is missing. |
| `tty` | string | The session's terminal, e.g. `/dev/ttys004`. Used to jump to the Terminal tab and to set its title. |
| `pid` | number | A process that lives as long as the session. When it's gone, the app hides the session. |
| `status` | string | See below. |
| `attention` | string | What the agent is asking for, shown in "Needs you" (e.g. the permission prompt). |
| `attention_at` | timestamp | When it started waiting for a permission. |
| `label` | string \| null | Name set by the user (`/label` or the panel). Takes priority over `title`. |
| `title` | string | Name the agent gave the conversation, if any. |
| `last_prompt` | string | The user's last message, up to 400 characters. |
| `prompt_at` | timestamp | When `last_prompt` was sent. |
| `last_message` | string | The end of the agent's last reply. |
| `turns` | number | Completed turns. Used to tell whether `summary` is current. |
| `summary` | object | `task`, `text`, `next_steps` (array of strings), `waiting_for`, `at`. |
| `summary_turn` | number | The `turns` value the summary was written for. |
| `started_at`, `done_at`, `ended_at`, `updated_at` | timestamp | Lifecycle times. |
| `ended_reason` | string | Why the session ended, as reported by the agent. |

## Status

| `status` | Meaning | Shown as |
|---|---|---|
| `idle` | Started, no prompt yet | 💤 |
| `working` | The agent is working | ⚙️ |
| `waiting_permission` | Blocked on a permission | ⏳, in "Needs you" |
| `waiting_input` | Finished and idle, waiting for the user | ✅ |
| `done` | Finished the turn | ✅ |
| `ended` | Session closed; the app hides it | — |

A `done` or `waiting_input` session counts as waiting (⏳, in "Needs you") when `summary.waiting_for` is non-empty and `summary_turn == turns`, which means the latest summary says the agent asked the user something.

When several live sessions share a `tty` (for example after `/clear`), the app shows only the most recently updated one.
