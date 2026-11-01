# Hermes Agent Setup — Installer

One-command installer that clones the **hermes-agent-setup** repo, backs up
`~/.hermes`, installs the full setup, **safely merges** your existing `.env`
(secrets are never lost), and activates the **anti-refusal** guardrail proxy.

- Repo: https://github.com/pickysaja99/hermes-agent-setup
- Installs: `SOUL.md`, `config.yaml` (only if none exists), `profile.yaml`,
  `skills/`, `memories/`, `plugins/`, `anti-refusal/`
- Idempotent — safe to run repeatedly
- Rolls back automatically on failure

---

## 1. Quick start (one command)

```bash
git clone https://github.com/pickysaja99/hermes-agent-setup.git \
  && bash hermes-agent-setup/install.sh
```

Or from a downloaded ZIP:

```bash
unzip hermes-agent-setup-installer.zip && bash install.sh
```

> The repo is **private**. To clone it the installer needs access:
> - run `gh auth login` first (recommended), **or**
> - export a token: `export GITHUB_TOKEN=ghp_xxx && bash install.sh`

### Options

| Flag | Effect |
|---|---|
| `--dry-run` | Show every action, change nothing |
| `--ref <branch\|tag>` | Install a specific branch/tag (default `main`) |
| `--no-antirefusal` | Skip the auto-refusal activation stage |
| `--help` | Usage |

Environment overrides: `HERMES_HOME` (default `~/.hermes`),
`GITHUB_TOKEN`, `HERMES_SETUP_REPO`, `HERMES_SETUP_REF`.

---

## 2. What the installer does

1. **Preflight** — checks `git`/`bash`, resolves `HERMES_HOME`.
2. **Clone** — shallow-clones the repo (uses `GITHUB_TOKEN` or the `gh` helper
   for private access).
3. **Backup** — full copy of `~/.hermes` into
   `~/.hermes/backups/install-<timestamp>/hermes` (keeps the 5 newest).
4. **Install files** — `SOUL.md`, `profile.yaml`, `skills/`, `memories/`,
   `plugins/`, `anti-refusal/`. `config.yaml` is installed **only if none
   exists** — an existing config is never overwritten.
5. **Merge `.env`** — starts from your existing `.env` and adds only the keys
   that are missing from the template. **Existing values are kept.**
   Then `chmod 600`. (A timestamped `.env.pre-merge.*` copy is kept.)
6. **Model config policy** *(see §4)*
7. **Activate auto-refusal** *(see §3)*
8. **Validate** — YAML parse, forbidden-host scan, `.env` perms, Telegram token.
9. **Summary** — files, backup path, model status, auto-refusal status.

---

## 3. Auto-refusal activation

`anti-refusal/proxy.py` sits between Hermes and your LLM router, detects refusals
(EN + zh), and re-asks with an escalated anti-refusal system line. The installer:

1. Copies the component to `$HERMES_HOME/anti-refusal/`.
2. Resolves the upstream from `.env` (`ANTIREFUSAL_UPSTREAM` → `CUSTOM_BASE_URL`
   → default `https://token.lightvela.ai/v1`).
3. Installs a **portable** systemd **user** unit, or — if `systemctl --user`
   is unavailable (containers/VPS) — starts a tracked background process.
4. Routes `model.base_url` through `http://127.0.0.1:9200/v1` so the guardrail is
   actually **in the request path** (done only when a valid model config exists).
5. **Verifies** `GET /health` returns `{"ok": true}` before reporting success.

Output is honest:

- `Auto-refusal : ENABLED` — health OK **and** the upstream key is present.
- `Auto-refusal : INSTALLED (needs upstream key)` — health OK, key empty
  (fill it in `.env` and restart).
- `Auto-refusal : FAILED` — health check failed; see
  `$HERMES_HOME/anti-refusal/proxy.log`.

Environment knobs: `ANTIREFUSAL_PORT` (default 9200),
`ANTIREFUSAL_UPSTREAM`, `ANTIREFUSAL_KEY` (in `.env`).

---

## 4. Model configuration policy

The installer **never** writes a default model provider or touches your API
keys:

- **Valid model config already present** (a `model.default`, a `provider`, and a
  real `base_url` / provider block) → **preserved unchanged**.
- **No valid model config** → the installer installs no default model block and
  changes no keys. It finishes by pointing you at:

  ```bash
  hermes setup model
  ```

  There you choose **provider**, **Base URL**, **API key**, and **model**.

This keeps `hermes-agent-setup` safe to apply over an existing, working install.

---

## 5. After installing

```bash
hermes              # start the CLI session
hermes gateway      # start messaging platforms (telegram, etc.)
hermes setup model  # (re)configure provider / base URL / key / model
```

Check the anti-refusal proxy:

```bash
curl -s http://127.0.0.1:9200/health
systemctl --user status antirefusal   # if installed as a unit
```

---

## 6. Safety notes

- **No secrets are shipped** in the repo — `.env.example` contains placeholders
  only.
- Your existing `.env`, tokens, and API keys are preserved across installs.
- Every run makes a full backup first; a failed run rolls back automatically.
- To recover a rolled-back install, the pre-failure tree is parked at
  `~/.hermes.failed`.

## Files in this ZIP

| File | Description |
|---|---|
| `install.sh` | The installer (this is the one-command entry point) |
| `README-INSTALLER.md` | This document |
| `LICENSE` | License |
