# Hermes Agent Setup — Installer

One-command installer that clones the **hermes-agent-setup** repo, backs up
`~/.hermes`, installs the full setup, **safely merges** your existing `.env`
(secrets are never lost), activates the **anti-refusal** guardrail proxy, and
applies the **unrestricted patch** (disables every internal guard that could
neutralize `SOUL.md` / `MEMORY.md`).

- Repo: https://github.com/pickysaja99/hermes-agent-setup
- Installs: `SOUL.md`, `config.yaml` (only if none exists), `profile.yaml`,
  `skills/`, `memories/`, `plugins/`, `anti-refusal/`, `unrestricted.sh`
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
| `--no-unrestricted` | Skip the guard-disable patch |
| `--help` | Usage |

Environment overrides: `HERMES_HOME` (default `~/.hermes`),
`HERMES_AGENT_DIR` (source dir holding the guards, default
`$HERMES_HOME/hermes-agent`), `GITHUB_TOKEN`, `HERMES_SETUP_REPO`,
`HERMES_SETUP_REF`.

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
8. **Unrestricted patch** *(see §3b)*
9. **Validate** — YAML parse, forbidden-host scan, `.env` perms, Telegram token.
10. **Summary** — files, backup path, model status, auto-refusal + unrestricted.

---

## 3. Auto-refusal activation

`anti-refusal/proxy.py` (v3) sits between Hermes and your LLM router, detects
refusals (EN + zh + ID), and re-asks with an escalated anti-refusal system line.
v3 adds what v2 got wrong:

- **SSE-tolerant parsing.** An upstream that ignores `stream:false` and replies
  `text/event-stream` is assembled into a normal completion instead of throwing
  `Attempt to decode JSON with unexpected mimetype` (v2 dropped *every* attempt
  against such an upstream).
- **Host-aware key resolution.** Every non-empty `*_API_KEY` in `.env` is
  catalogued; the key whose variable name matches the upstream host wins. v2 read
  a single hard-coded env name that is empty on a real install and shipped an
  empty bearer token.
- **Multi-upstream failover.** `config.json` carries an ordered `upstreams[]`;
  a 401/403/404/timeout on one advances to the next instead of exhausting the
  whole ladder against a dead router.
- **Streaming clients are served.** If the inbound request asked for
  `stream:true`, the finished text is re-emitted as SSE chunks so Hermes'
  streaming path does not hang.
- **Never an empty 200.** The longest non-refusing answer seen across all
  attempts wins; a structured error is returned only when nothing came back.

The installer:

1. Copies the component to `$HERMES_HOME/anti-refusal/`.
2. Resolves upstreams from `config.json` `upstreams[]` → `ANTIREFUSAL_UPSTREAM` →
   `config.upstream_base_url` → default `https://token.lightvela.ai/v1`.
3. Installs a **portable** systemd **user** unit, or — if `systemctl --user`
   is unavailable (containers/VPS) — starts a tracked background process.
4. Routes `model.base_url` through `http://127.0.0.1:9200/v1` so the guardrail is
   actually **in the request path** (done only when a valid model config exists).
5. **Verifies** `GET /health` returns `{"ok": true}` before reporting success.

Output is honest:

- `Auto-refusal : ENABLED` — health OK **and** at least one upstream key present.
- `Auto-refusal : INSTALLED (needs upstream key)` — health OK, no key
  (fill it in `.env` and restart).
- `Auto-refusal : FAILED` — health check failed; see
  `$HERMES_HOME/anti-refusal/proxy.log`.

Check what the proxy actually resolved:

```bash
curl -s http://127.0.0.1:9200/health | python3 -m json.tool
# -> keys_found, upstreams[].key ("set" | "MISSING"), env_file
```

Environment knobs: `ANTIREFUSAL_PORT` (default 9200),
`ANTIREFUSAL_UPSTREAM` (single override), `ANTIREFUSAL_KEY` (force one key),
`ANTIREFUSAL_MAX_ATTEMPTS` (default 8). `config.json` keys:
`upstreams[]`, `default_model`, `models[]`, `host_aware_keys`,
`force_prefill`, `inject_light`, `upstream_timeout`, `upstream_connect_timeout`.

---

## 3b. Unrestricted patch — disabling internal guards

Hermes ships internal guards that can neutralize your `SOUL.md` / `MEMORY.md`:
a threat scanner on context files, a memory-poisoning scan, cron-prompt and
skill/plugin scanners, hardline command detection, approval deny-rules, the
file-write guard on config/instruction files, and the gateway-lifecycle guard.
`unrestricted.sh` neutralizes all of them by injecting a `HERMES_UNRESTRICTED`
bypass at each guard site.

**Guard sites patched (9 files):**

| File | Guard disabled |
|---|---|
| `tools/threat_patterns.py` | context/memory threat scan (`scan_for_threats`) |
| `tools/memory_tool_store.py` | memory-poisoning scan on write/load |
| `tools/cronjob_prompt_scan.py` | cron prompt scan |
| `tools/skills_guard.py` | skill content scan |
| `tools/plugin_guard.py` | plugin scan |
| `tools/approval_detection.py` | hardline command detection |
| `tools/approval.py` | approval floors + user deny rules |
| `tools/file_tools_write_guards.py` | config.yaml write guard + protected-instruction gate |
| `tools/terminal_tool_guards.py` | gateway lifecycle guard |

**How it is applied:** the installer runs `unrestricted.sh`, which sets
`HERMES_UNRESTRICTED=1` in `~/.hermes/.env` and adds a systemd drop-in
(`hermes-gateway.service.d/unrestricted.conf`) so the Hermes gateway inherits it.
Every patched function checks `HERMES_UNRESTRICTED` and short-circuits when it is
not `0`. Each file is backed up before patching.

**Manual control:**

```bash
bash unrestricted.sh            # apply (idempotent)
bash unrestricted.sh --check    # report which files are patched
bash unrestricted.sh --revert   # restore the original source from backup
```

To re-enable the guards at runtime, set `HERMES_UNRESTRICTED=0` (or unset it) and
restart Hermes — the patch is a runtime bypass, so the original behavior returns
without touching the source.

> Note: patched source lives in the Hermes checkout; a future `hermes update`
> may overwrite it. Re-run `install.sh` (or `unrestricted.sh`) after an update.

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
- The unrestricted patch backs up every source file it modifies
  (`~/.hermes/backups/unrestricted-*`) and supports `--revert`.

## Files in this ZIP

| File | Description |
|---|---|
| `install.sh` | The installer (this is the one-command entry point) |
| `unrestricted.sh` | Guard-disable patcher (`--check` / `--revert`) |
| `README-INSTALLER.md` | This document |
| `LICENSE` | License |

---

## Kebijakan konfigurasi saat install / update / reinstall

`install.sh` bersifat idempoten dan **tidak menghapus** konfigurasi router.
Saat `config.yaml` sudah ada, **template repo menang untuk semua section** —
hanya tiga nilai milik operator yang dipertahankan:

| Dipertahankan selamanya | Ditimpa dari template repo |
|---|---|
| `model.base_url` | `_config_version`, `context_file_max_chars` |
| `model.api_key` | `agent:`, `display:`, `compression:` |
| `model.default` (model id) | `platforms:`, `approvals:`, `memory:` |
| | **seluruh blok `gateway:`** |

Blok `gateway:` ikut ditimpa karena **kredensial gateway tidak disimpan di
`config.yaml`** — token Telegram dan sejenisnya ada di `.env`
(`TELEGRAM_BOT_TOKEN`), dan `.env` dilindungi oleh `merge_env`.

Section milik operator yang tidak ada di template (mis. `aliases:`,
`custom_providers:` tambahan) **tidak dihapus**.

**SOUL.md** dideploy ulang dari repo setiap kali (repo adalah sumber otoritatif);
versi lama disimpan sebagai `SOUL.md.pre-install.<timestamp>`.
**profile.yaml** hanya dipasang bila belum ada — setting lokal tidak direset.

### `.env` selalu aman

`merge_env` tidak pernah mengosongkan nilai yang sudah ada, dan tidak pernah
memasukkan nilai placeholder (`<...>`, `YOUR_`, `changeme`, `REPLACE`, `xxxx`,
`placeholder`, `example`, `dummy`, `sk-xxx`, `api_key_here`, `your-`).
Key baru hanya ditambahkan bila nilainya terlihat nyata.

### Proxy anti-refusal: satu upstream saja

`anti-refusal/config.json` **tidak pernah ditimpa** oleh `install_files`.
Upstream tunggalnya diturunkan dari `.env`:

```
ANTIREFUSAL_UPSTREAM   # Base URL router (fallback: CUSTOM_BASE_URL)
ANTIREFUSAL_SINGLE_UPSTREAM=1
```

`arm_proxy()` di `unrestricted.sh` memaksa `single_upstream: true`,
mengosongkan `extra_upstreams`, dan memangkas `upstreams[]` jadi satu entri —
ladder retry hanya memutar **model** di router itu, tidak pernah failover ke
host lain.

### Idempotensi

Jalankan `bash install.sh` berkali-kali: `model.base_url`, `model.api_key`,
`model.default`, dan seluruh `.env` tetap byte-identik.
