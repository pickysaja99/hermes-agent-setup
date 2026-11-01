#!/usr/bin/env bash
# =============================================================================
#  Hermes Agent Setup — installer
#  ---------------------------------------------------------------------------
#  Clones github.com/pickysaja99/hermes-agent-setup, backs up ~/.hermes,
#  installs the full setup, safely MERGES your existing .env (never loses
#  secrets), activates the anti-refusal guardrail proxy, and applies the
#  UNRESTRICTED PATCH (disables every internal guard that could neutralize
#  SOUL.md / MEMORY.md and sets HERMES_UNRESTRICTED=1 in the Hermes env).
#  Reports "Auto-refusal: ENABLED" only after the health check passes.
#
#  Idempotent: safe to run repeatedly. Rolls back on failure.
#
#  Usage:
#     bash install.sh                    # normal install (all guards disabled)
#     bash install.sh --ref <branch>     # install a specific branch/tag
#     bash install.sh --dry-run          # show what would happen, change nothing
#     bash install.sh --no-antirefusal   # skip the auto-refusal stage
#     bash install.sh --no-unrestricted  # skip the guard-disable patch
#     bash install.sh --help
#
#  Model config policy:
#     If ~/.hermes/config.yaml already has a valid model/provider/base_url, it is
#     preserved untouched (no routing/key changes). If there is NO valid model
#     config, the installer installs NO default model block and does NOT touch
#     keys — it finishes by pointing you at:  hermes setup model
# =============================================================================
set -Eeuo pipefail

REPO_URL="${HERMES_SETUP_REPO:-https://github.com/pickysaja99/hermes-agent-setup.git}"
REPO_REF="${HERMES_SETUP_REF:-main}"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
WORKDIR=""
DRY_RUN=0
DO_ANTIREFUSAL=1
DO_UNRESTRICTED=1
BACKUP_DIR=""
STAGE_LOG=""
ROLLBACK_NEEDED=0
ANTIREFUSAL_STATUS="skipped"
UNRESTRICTED_STATUS="skipped"
MODEL_STATUS="unknown"

# ---------------------------------------------------------------- output
C_R="\033[1;31m"; C_G="\033[1;32m"; C_Y="\033[1;33m"; C_B="\033[1;34m"; C_0="\033[0m"
say()  { printf "${C_B}[*]${C_0} %s\n" "$*"; }
ok()   { printf "${C_G}[+]${C_0} %s\n" "$*"; }
warn() { printf "${C_Y}[!]${C_0} %s\n" "$*"; }
die()  { printf "${C_R}[x]${C_0} %s\n" "$*" >&2; exit 1; }

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

# ---------------------------------------------------------------- args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ref)            REPO_REF="${2:?--ref needs a value}"; shift 2 ;;
    --dry-run)        DRY_RUN=1; shift ;;
    --no-antirefusal) DO_ANTIREFUSAL=0; shift ;;
    --no-unrestricted) DO_UNRESTRICTED=0; shift ;;
    -h|--help)        usage ;;
    *) die "unknown option: $1 (use --help)" ;;
  esac
done

run() {  # execute a command, or just print it in dry-run
  if [[ $DRY_RUN -eq 1 ]]; then printf "    ${C_Y}(dry-run)${C_0} %s\n" "$*"; else "$@"; fi
}

# ---------------------------------------------------------------- rollback
rollback() {
  local code=$?
  [[ $ROLLBACK_NEEDED -eq 1 ]] || return
  printf "\n${C_R}[x] Install failed (exit %s). Rolling back…${C_0}\n" "$code" >&2
  # stop & remove the unit we may have installed
  if systemctl --user list-unit-files 2>/dev/null | grep -q '^antirefusal.service'; then
    systemctl --user disable --now antirefusal.service >/dev/null 2>&1 || true
    rm -f "$HOME/.config/systemd/user/antirefusal.service" 2>/dev/null || true
    systemctl --user daemon-reload >/dev/null 2>&1 || true
  fi
  # stop a fallback background proxy if we started one
  if [[ -n "${HERMES_HOME:-}" && -f "$HERMES_HOME/anti-refusal/proxy.pid" ]]; then
    kill "$(cat "$HERMES_HOME/anti-refusal/proxy.pid")" 2>/dev/null || true
    rm -f "$HERMES_HOME/anti-refusal/proxy.pid" 2>/dev/null || true
  fi
  # restore backup if we have one
  if [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR/hermes" ]]; then
    warn "restoring ~/.hermes from $BACKUP_DIR/hermes"
    local parked="${HERMES_HOME}.failed"
    rm -rf "$parked" 2>/dev/null || true
    # move the broken tree aside (this carries the nested backups/ dir with it)
    mv "$HERMES_HOME" "$parked" 2>/dev/null || true
    # the backup now lives inside the parked dir — restore from there
    local restore_src="$BACKUP_DIR/hermes"
    [[ -d "$restore_src" ]] || restore_src="$parked/backups/$(basename "$BACKUP_DIR")/hermes"
    if [[ -d "$restore_src" ]]; then
      cp -a "$restore_src" "$HERMES_HOME"
      ok "rolled back. previous (broken) dir parked at $parked"
    else
      warn "could not locate backup at $restore_src — manual recovery: $parked"
    fi
  fi
  [[ -n "$WORKDIR" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR" 2>/dev/null || true
  exit "$code"
}
trap rollback ERR

# ---------------------------------------------------------------- preflight
preflight() {
  say "preflight checks"
  command -v git  >/dev/null 2>&1 || die "git not found — install git first"
  command -v bash >/dev/null 2>&1 || die "bash not found"
  [[ -n "${HOME:-}" ]] || die "HOME is not set"
  mkdir -p "$HERMES_HOME"
  ok "git + bash present; HERMES_HOME=$HERMES_HOME"
  if [[ $DRY_RUN -eq 0 ]]; then
    WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/hermes-setup.XXXXXX")"
    say "work dir: $WORKDIR"
  fi
  # python for the patcher / proxy (best-effort)
  PY_BIN="$(find_python 2>/dev/null || true)"
}

# ---------------------------------------------------------------- 1. clone
clone_repo() {
  say "cloning $REPO_URL ($REPO_REF)"
  # Private repos need auth. Prefer a token/gh helper if present, else plain clone.
  local url="$REPO_URL"
  local helper_args=()
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    url="$(printf '%s' "$REPO_URL" | sed -E "s#https://#https://x-access-token:${GITHUB_TOKEN}@#")"
  elif command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    helper_args=(-c credential.helper="!gh auth git-credential")
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    printf "    ${C_Y}(dry-run)${C_0} git clone --depth 1 --branch %s <repo> %s/repo\n" "$REPO_REF" "$WORKDIR"
    return
  fi

  if ! git "${helper_args[@]}" clone --depth 1 --branch "$REPO_REF" "$url" "$WORKDIR/repo" 2>"$WORKDIR/clone.err"; then
    warn "authenticated clone failed:"
    sed 's/^/    /' "$WORKDIR/clone.err" | head -5
    die "could not clone $REPO_URL. For a private repo set GITHUB_TOKEN=... (or run 'gh auth login') and re-run."
  fi
  [[ -d "$WORKDIR/repo" ]] || die "clone produced no repo dir"
  local ver
  ver="$(git -C "$WORKDIR/repo" rev-parse --short HEAD)"
  ok "cloned at commit $ver"
}

# ---------------------------------------------------------------- 2. backup
backup_hermes() {
  say "backing up $HERMES_HOME"
  local stamp; stamp="$(date +%Y%m%d-%H%M%S)"
  BACKUP_DIR="$HERMES_HOME/backups/install-$stamp"
  if [[ $DRY_RUN -eq 1 ]]; then
    printf "    ${C_Y}(dry-run)${C_0} backup %s -> %s\n" "$HERMES_HOME" "$BACKUP_DIR"
    return
  fi
  mkdir -p "$BACKUP_DIR"
  # full copy of the tree (excluding our own backups dir to avoid recursion)
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --exclude 'backups/' "$HERMES_HOME"/ "$BACKUP_DIR/hermes"/ 2>/dev/null || \
      cp -a "$HERMES_HOME" "$BACKUP_DIR/hermes"
  else
    mkdir -p "$BACKUP_DIR/hermes"
    ( shopt -s dotglob nullglob; for f in "$HERMES_HOME"/*; do
        [[ "$(basename "$f")" == "backups" ]] && continue
        cp -a "$f" "$BACKUP_DIR/hermes/"
      done )
  fi
  ROLLBACK_NEEDED=1
  ok "backup -> $BACKUP_DIR"
  # prune: keep only the 5 newest install backups
  ls -1dt "$HERMES_HOME"/backups/install-* 2>/dev/null | tail -n +6 | xargs -r rm -rf
}

# ---------------------------------------------------------------- 3. install
install_files() {
  local S="$WORKDIR/repo"
  say "installing setup files"
  run cp "$S/SOUL.md"    "$HERMES_HOME/SOUL.md"
  run cp "$S/profile.yaml" "$HERMES_HOME/profile.yaml"
  run cp -r "$S/skills"   "$HERMES_HOME/"
  run cp -r "$S/memories" "$HERMES_HOME/"
  run cp -r "$S/plugins"  "$HERMES_HOME/"
  run cp -r "$S/anti-refusal" "$HERMES_HOME/"
  run cp "$S/README.md"   "$HERMES_HOME/SETUP-README.md"

  # config.yaml: only install the shipped template if the target has NO config
  # yet. If a config exists, keep it (its model/provider/API-key must survive).
  if [[ ! -f "$HERMES_HOME/config.yaml" ]]; then
    run cp "$S/config.yaml" "$HERMES_HOME/config.yaml"
    ok "config.yaml installed (none existed)"
  else
    ok "existing config.yaml preserved (not overwritten)"
  fi
  ok "files copied"
}

# ---------------------------------------------------------------- 4. .env merge
# The repo ships .env.example with placeholders only. We must NOT clobber
# existing secrets. Strategy: start from the existing .env (if any) and add any
# KEY from .env.example that is missing, keeping the old value.
merge_env() {
  say "merging .env (preserving existing secrets)"
  local S="$WORKDIR/repo"
  local dst="$HERMES_HOME/.env"
  local src="$S/.env.example"

  if [[ $DRY_RUN -eq 1 ]]; then
    printf "    ${C_Y}(dry-run)${C_0} merge %s into %s (keep existing values)\n" "$src" "$dst"
    return
  fi

  if [[ ! -f "$dst" ]]; then
    cp "$src" "$dst"
    ok ".env created from template (no previous .env)"
  else
    [[ -f "$dst" ]] && cp -a "$dst" "$dst.pre-merge.$(date +%Y%m%d-%H%M%S)"
    local tmp; tmp="$(mktemp)"
    cp "$dst" "$tmp"
    local added=0
    while IFS= read -r line; do
      # only consider real KEY=... assignment lines
      [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
      local key="${line%%=*}"
      if ! grep -qE "^${key}=" "$tmp"; then
        printf "%s\n" "$line" >> "$tmp"
        added=$((added+1))
      fi
    done < "$src"
    mv "$tmp" "$dst"
    ok ".env merged (kept existing values; added $added new keys)"
  fi
  chmod 600 "$dst"
  ok ".env permissions set to 600"
}

# ---------------------------------------------------------------- 5. python for proxy
find_python() {
  # prefer the hermes venv python, else system python3
  local cands=(
    "$HERMES_HOME/hermes-agent/venv/bin/python3"
    "$(command -v python3 2>/dev/null || true)"
    /usr/bin/python3
  )
  for c in "${cands[@]}"; do
    [[ -n "$c" && -x "$c" ]] && { echo "$c"; return 0; }
  done
  return 1
}

# ---------------------------------------------------------------- model config check
# Returns 0 only if the config already has a usable model/provider/API-key setup.
# "Usable" = has a model.default (non-empty), a model.provider, a non-empty
# model.base_url that is NOT an unresolved placeholder, and either an api_key or
# a provider block that supplies one. If not, the installer must NOT install a
# default model config or touch keys — it points the user at `hermes setup`.
model_config_ok() {
  local cfg="${1:-$HERMES_HOME/config.yaml}"
  [[ -f "$cfg" ]] || return 1
  local PY; PY="$(find_python || true)"

  # Preferred: precise parse via pyyaml
  if [[ -n "$PY" ]] && "$PY" -c "import yaml" 2>/dev/null; then
    "$PY" - "$cfg" <<'PYEOF'
import sys
import yaml
p = sys.argv[1]
try:
    cfg = yaml.safe_load(open(p)) or {}
except Exception:
    sys.exit(1)
m = cfg.get("model") or {}
base = str(m.get("base_url") or "").strip()
prov = str(m.get("provider") or "").strip()
default = str(m.get("default") or "").strip()
bad_base = (not base) or ("<" in base) or ("LLM_ROUTER_HOST" in base) or ("placeholder" in base.lower())
providers = cfg.get("providers") or {}
prov_ok = False
for name, blk in providers.items():
    if not isinstance(blk, dict):
        continue
    pb = str(blk.get("base_url") or "").strip()
    if pb and "<" not in pb and "LLM_ROUTER_HOST" not in pb and blk.get("key_env"):
        prov_ok = True
        break
ok = bool(default) and bool(prov) and (not bad_base or prov_ok)
sys.exit(0 if ok else 1)
PYEOF
    return $?
  fi

  # Fallback: pyyaml not available -> minimal indentation-aware scan (no regex
  # backtracking). We only need to know: is there a non-empty model.default,
  # a provider, and a base_url that is not an unresolved placeholder?
  local in_model=0 have_default=0 have_provider=0 have_base=0 base_bad=0
  while IFS= read -r line; do
    [[ -z "${line// }" ]] && continue
    if [[ "$line" =~ ^[^[:space:]] ]]; then
      in_model=0
      [[ "$line" =~ ^model: ]] && in_model=1
      continue
    fi
    [[ $in_model -eq 1 ]] || continue
    case "$line" in
      *"default:"*) [[ -n "${line#*default:}" && "${line#*default:}" != *"''"* ]] && have_default=1 ;;
      *"provider:"*) [[ -n "${line#*provider:}" ]] && have_provider=1 ;;
      *"base_url:"*)
        local v="${line#*base_url:}"; v="${v// /}"
        [[ -n "$v" ]] && have_base=1
        case "$v" in *"<"*|*LLM_ROUTER_HOST*|*placeholder*) base_bad=1 ;; esac
        ;;
    esac
  done < "$cfg"
  if [[ $have_default -eq 1 && $have_provider -eq 1 && ( $have_base -eq 0 || $base_bad -eq 0 ) ]]; then
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------- 6b. model config policy
# Decide ONCE whether a valid model config already exists. If yes: preserve it.
# If no: do NOT install a default model block and do NOT touch keys — we only
# flag it so the summary points the user at `hermes setup model`.
assess_model_config() {
  say "checking existing model/provider configuration"
  local cfg="$HERMES_HOME/config.yaml"
  if [[ $DRY_RUN -eq 1 ]]; then
    printf "    ${C_Y}(dry-run)${C_0} inspect %s for a valid model/provider\n" "$cfg"
    MODEL_STATUS="unknown"
    return 0
  fi
  local rc=0
  model_config_ok "$cfg" || rc=$?
  if [[ $rc -eq 0 ]]; then
    MODEL_STATUS="preserved"; ok "valid model config found — will be preserved unchanged"
  else
    MODEL_STATUS="needs-setup"; warn "no valid model/provider config found"
  fi
  return 0
}

# ---------------------------------------------------------------- 6. auto-refusal
activate_antirefusal() {
  if [[ $DO_ANTIREFUSAL -eq 0 ]]; then
    warn "auto-refusal activation skipped (--no-antirefusal)"
    return 0
  fi
  say "activating auto-refusal guardrail"

  local AR="$HERMES_HOME/anti-refusal"
  [[ -f "$AR/proxy.py" ]] || die "anti-refusal/proxy.py missing after copy"

  # -- resolve upstream from .env (keeps a valid, reachable host)
  local upstream=""
  if [[ -f "$HERMES_HOME/.env" ]]; then
    upstream="$(grep -E '^ANTIREFUSAL_UPSTREAM=' "$HERMES_HOME/.env" | tail -1 | cut -d= -f2- || true)"
    [[ -z "$upstream" ]] && upstream="$(grep -E '^CUSTOM_BASE_URL=' "$HERMES_HOME/.env" | tail -1 | cut -d= -f2- || true)"
  fi
  [[ -z "$upstream" ]] && upstream="https://token.lightvela.ai/v1"

  # listen port: allow override from .env (default 9200)
  local ar_port="9200"
  if [[ -f "$HERMES_HOME/.env" ]]; then
    local p; p="$(grep -E '^ANTIREFUSAL_PORT=' "$HERMES_HOME/.env" | tail -1 | cut -d= -f2- || true)"
    [[ -n "$p" ]] && ar_port="$p"
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    printf "    ${C_Y}(dry-run)${C_0} install user unit, upstream=%s, verify /health\n" "$upstream"
    return 0
  fi

  local PY; PY="$(find_python || true)"
  if [[ -z "$PY" ]]; then
    warn "no python3 found — auto-refusal not activated"
    return 0
  fi

  # python deps for the proxy (best-effort; do not fail the install on pip)
  "$PY" -c "import aiohttp" 2>/dev/null || {
    say "installing aiohttp for the proxy"
    "$PY" -m pip install --quiet aiohttp 2>/dev/null || \
      "$PY" -m pip install --quiet --user aiohttp 2>/dev/null || \
      warn "could not pip install aiohttp — proxy may not start"
  }

  # -- install a PORTABLE user unit (rewrite ExecStart/WorkingDirectory to this host)
  local unit_dir="$HOME/.config/systemd/user"
  mkdir -p "$unit_dir"
  cat > "$unit_dir/antirefusal.service" <<UNIT
[Unit]
Description=Hermes anti-refusal guardrail proxy
After=network.target

[Service]
Type=simple
WorkingDirectory=$AR
ExecStart=$PY $AR/proxy.py
Restart=on-failure
RestartSec=3
EnvironmentFile=-$HERMES_HOME/.env
Environment=PYTHONUNBUFFERED=1
Environment=ANTIREFUSAL_UPSTREAM=$upstream
Environment=ANTIREFUSAL_PORT=$ar_port

[Install]
WantedBy=default.target
UNIT

  # -- optional: route Hermes through the proxy so auto-refusal is IN the path.
  #    NEVER touches an existing, valid model/provider/API-key config.
  local cfg="$HERMES_HOME/config.yaml"
  local model_ready=0
  if [[ "$MODEL_STATUS" == "preserved" ]]; then
    model_ready=1
    ok "existing model config detected — preserving it (no routing changes)"
  elif [[ "$MODEL_STATUS" == "needs-setup" ]]; then
    warn "no valid model/provider config — leaving model settings untouched"
  fi

  # v6: the portable anti-refusal unit falls back to system python3 when no
  # venv exists, so system python3 needs aiohttp too (Ubuntu 24.04 system
  # python has no pip -- use --break-system-packages or apt).
  if [[ "$PY" != "/usr/bin/python3" && "$PY" != "/usr/bin/python" ]]; then
    if ! /usr/bin/python3 -c "import aiohttp" 2>/dev/null; then
      say "installing aiohttp for system python3 (proxy fallback path)"
      /usr/bin/python3 -m pip install --quiet --break-system-packages aiohttp 2>/dev/null || \
        (sudo -n apt-get install -y -qq python3-aiohttp >/dev/null 2>&1 || \
         apt-get install -y -qq python3-aiohttp >/dev/null 2>&1) || \
        warn "system python3 lacks aiohttp -- proxy will rely on the venv python"
    fi
  fi

  # -- routing (base_url -> proxy) is deferred until the service is up AND a
  #    real canary chat succeeds; see the ROUTE step below. A proxy with a
  #    healthy /health but a dead upstream ladder answers 200 with an EMPTY
  #    body, which leaves Hermes with no working endpoint at all.

  # -- start the service: prefer systemd --user, else fall back to a plain
  #    background process (many VPS/containers have no systemd user session).
  local started=0
  if systemctl --user daemon-reload 2>/dev/null && \
     systemctl --user show-environment >/dev/null 2>&1; then
    systemctl --user enable antirefusal.service >/dev/null 2>&1 || true
    if systemctl --user restart antirefusal.service >/dev/null 2>&1 || \
       systemctl --user start antirefusal.service >/dev/null 2>&1; then
      started=1
      ok "started via systemd --user (antirefusal.service)"
    fi
  fi

  if [[ $started -eq 0 ]]; then
    warn "systemd --user unavailable — launching the proxy as a background process"
    pkill -f "$AR/proxy.py" 2>/dev/null || true
    sleep 1
    ANTIREFUSAL_UPSTREAM="$upstream" ANTIREFUSAL_PORT="$ar_port" \
      nohup "$PY" "$AR/proxy.py" >"$AR/proxy.out" 2>&1 &
    echo $! > "$AR/proxy.pid"
    ok "started background proxy (pid $(cat "$AR/proxy.pid"))"
  fi

  # -- VERIFY: health endpoint must answer {"ok": true}
  local tries=0 healthy=0
  for tries in 1 2 3 4 5 6 7 8; do
    sleep 1
    local body
    body="$(curl -fsS --max-time 3 "http://127.0.0.1:${ar_port}/health" 2>/dev/null || true)"
    if printf '%s' "$body" | grep -q '"ok"[[:space:]]*:[[:space:]]*true'; then
      healthy=1; break
    fi
  done

  if [[ $healthy -eq 1 ]]; then
    local keyed
    keyed="$(printf '%s' "$body" | grep -o '"key"[[:space:]]*:[[:space:]]*true' || true)"
    ok "proxy healthy on 127.0.0.1:${ar_port}"
    if [[ -n "$keyed" ]]; then
      ok "Auto-refusal: ENABLED (upstream key present)"
      # -- ROUTE: point model.base_url at the proxy ONLY after a real canary
      #    chat round-trips through it. Never trust /health alone.
      if [[ $model_ready -eq 1 && -f "$cfg" ]]; then
        local canary_model="${ANTIREFUSAL_CANARY_MODEL:-step-5-preview-UNCENSORED}"
        local canary_body canary_ok=0
        canary_body="$(curl -s -m 150 -X POST "http://127.0.0.1:${ar_port}/v1/chat/completions" \
          -H "Content-Type: application/json" \
          -d "{\"model\":\"${canary_model}\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":8,\"stream\":false}" 2>/dev/null || true)"
        if [[ -n "$canary_body" ]] && printf '%s' "$canary_body" | grep -q '"content"'; then
          canary_ok=1
        fi
        if [[ $canary_ok -eq 1 ]]; then
          cp -a "$cfg" "$cfg.pre-antirefusal"
          "$PY" - "$cfg" "$ar_port" <<'PYEOF' || warn "config rewrite skipped"
import sys
p, port = sys.argv[1], sys.argv[2]
lines = open(p).read().splitlines(keepends=True)
out, in_model, done = [], False, False
for ln in lines:
    stripped = ln.strip()
    if stripped.startswith("model:"):
        in_model = True
        out.append(ln); continue
    if in_model and not ln[:1].isspace() and stripped:
        in_model = False            # left the model block
    if in_model and stripped.startswith("base_url:") and not done:
        indent = ln[:len(ln) - len(ln.lstrip())]
        out.append(f"{indent}base_url: http://127.0.0.1:{port}/v1\n")
        done = True
        continue
    out.append(ln)
open(p, "w").write("".join(out))
print("model.base_url -> proxy" if done else "no change")
PYEOF
        else
          warn "proxy canary failed on 127.0.0.1:${ar_port} — model.base_url left on the direct upstream"
        fi
      fi
    else
      warn "Auto-refusal: INSTALLED but upstream key is EMPTY"
      warn "  set HERMES_CUSTOM_LIGHTVELA_CUSTOM_RTR_1WT0FC9_API_KEY (or CUSTOM_API_KEY) in $HERMES_HOME/.env, then:"
      warn "  systemctl --user restart antirefusal.service"
      ANTIREFUSAL_STATUS="installed-no-key"
      return 0
    fi
    ANTIREFUSAL_STATUS="enabled"
  else
    warn "proxy health check failed — see $AR/proxy.log"
    ANTIREFUSAL_STATUS="failed"
  fi
}

# ---------------------------------------------------------------- 6c. unrestricted
activate_unrestricted() {
  if [[ $DO_UNRESTRICTED -eq 0 ]]; then
    warn "unrestricted patch skipped (--no-unrestricted)"
    UNRESTRICTED_STATUS="skipped"
    return 0
  fi
  say "applying unrestricted patch (disabling internal guards)"

  # locate the Hermes agent source (where the guards live)
  local agent_dir="${HERMES_AGENT_DIR:-$HERMES_HOME/hermes-agent}"
  if [[ ! -d "$agent_dir" ]]; then
    warn "hermes-agent source not found at $agent_dir — skipping guard patch"
    warn "  (set HERMES_AGENT_DIR if your checkout lives elsewhere)"
    UNRESTRICTED_STATUS="no-source"
    return 0
  fi

  # 1. force HERMES_UNRESTRICTED=1 in .env so every Hermes process honors it
  local envf="$HERMES_HOME/.env"
  if [[ $DRY_RUN -eq 0 && -f "$envf" ]]; then
    if grep -qE '^HERMES_UNRESTRICTED=' "$envf"; then
      # normalize to 1 (never leave a stale 0)
      "$PY_BIN" - "$envf" <<'PYEOF' 2>/dev/null || \
        sed -i 's/^HERMES_UNRESTRICTED=.*/HERMES_UNRESTRICTED=1/' "$envf"
import io, sys, re
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
s = re.sub(r'(?m)^HERMES_UNRESTRICTED=.*$', 'HERMES_UNRESTRICTED=1', s)
io.open(p, "w", encoding="utf-8").write(s)
PYEOF
    else
      printf '\n# Unrestricted build — disables internal guards (SOUL/MEMORY honored verbatim)\nHERMES_UNRESTRICTED=1\n' >> "$envf"
    fi
    ok "HERMES_UNRESTRICTED=1 set in $envf"
  fi

  # 2. run the patch script against the agent source
  local patcher="$WORKDIR/repo/unrestricted.sh"
  [[ -f "$patcher" ]] || patcher="$WORKDIR/unrestricted.sh"
  if [[ ! -f "$patcher" ]]; then
    warn "unrestricted.sh not found in checkout — cannot disable guards"
    UNRESTRICTED_STATUS="failed"
    return 0
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    printf "    ${C_Y}(dry-run)${C_0} bash unrestricted.sh  (HERMES_AGENT_DIR=%s)\n" "$agent_dir"
    UNRESTRICTED_STATUS="dry-run"
    return 0
  fi

  if HERMES_AGENT_DIR="$agent_dir" HERMES_HOME="$HERMES_HOME" bash "$patcher" 2>&1 | sed 's/^/    /'; then
    UNRESTRICTED_STATUS="enabled"
    ok "internal guards disabled (unrestricted patch applied)"
  else
    UNRESTRICTED_STATUS="partial"
    warn "unrestricted patch reported problems — see output above"
  fi

  # 3. propagate HERMES_UNRESTRICTED=1 to the Hermes gateway service env
  local unit_dir="$HOME/.config/systemd/user"
  if [[ -d "$unit_dir" ]] || systemctl --user show-environment >/dev/null 2>&1; then
    mkdir -p "$unit_dir/hermes-gateway.service.d"
    cat > "$unit_dir/hermes-gateway.service.d/unrestricted.conf" <<'CONF'
[Service]
Environment=HERMES_UNRESTRICTED=1
CONF
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    ok "gateway service env: HERMES_UNRESTRICTED=1 (takes effect on next gateway restart)"
  fi
}

# ---------------------------------------------------------------- 6d. restart gateway
restart_gateway() {
  say "restarting gateway to activate the unrestricted build"
  local unit=""
  if systemctl --user list-unit-files 2>/dev/null | grep -q '^hermes-gateway'; then
    unit="hermes-gateway"
  else
    unit="$(systemctl --user list-unit-files 2>/dev/null | awk '/^hermes/ && /gateway/ {print $1; exit}')"
  fi
  if [[ -z "$unit" ]]; then
    GATEWAY_STATUS="not-found"
    dim "  no hermes gateway unit found -- restart your gateway manually to activate"
    return 0
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    printf "    ${C_Y}(dry-run)${C_0} systemctl --user restart %s\n" "$unit"
    GATEWAY_STATUS="dry-run"
    return 0
  fi
  if systemctl --user restart "$unit" 2>/dev/null; then
    sleep 5
    if systemctl --user is-active "$unit" >/dev/null 2>&1; then
      GATEWAY_STATUS="restarted"
      ok "gateway restarted -- guards OFF, HERMES_UNRESTRICTED=1 live (session may blip)"
    else
      GATEWAY_STATUS="unhealthy"
      warn "gateway restarted but not active -- check: systemctl --user status $unit"
    fi
  else
    GATEWAY_STATUS="no-systemd"
    warn "gateway restart failed (no systemd user session?) -- restart manually: hermes gateway"
  fi
}

# ---------------------------------------------------------------- 7. validate
validate() {
  say "validating installation"
  [[ $DRY_RUN -eq 1 ]] && { printf "    ${C_Y}(dry-run)${C_0} validate YAML + structure\n"; return; }

  local PY; PY="$(find_python || true)"
  local cfg="$HERMES_HOME/config.yaml"
  if [[ -n "$PY" ]] && "$PY" -c "import yaml" 2>/dev/null; then
    "$PY" - "$cfg" <<'PYEOF' || die "config.yaml failed YAML validation"
import sys, yaml
cfg = yaml.safe_load(open(sys.argv[1]))
need = ["model","providers","gateway","compression","plugins","terminal"]
missing = [k for k in need if k not in cfg]
if missing:
    print("   missing sections:", missing); sys.exit(1)
print("   config.yaml OK —", len(cfg), "sections; model.provider =", cfg["model"].get("provider"))
PYEOF
  else
    warn "pyyaml/python not available — skipped YAML parse check"
  fi

  # forbidden-host scan on the installed config
  if grep -q "morku" "$cfg" 2>/dev/null; then die "forbidden host 'morku' present in config"; fi
  ok "no forbidden providers in config"

  # secrets sanity: .env perms
  [[ "$(stat -c '%a' "$HERMES_HOME/.env" 2>/dev/null)" == "600" ]] && ok ".env is 600" || warn ".env perms not 600"

  # telegram preserved?
  if [[ -f "$HERMES_HOME/.env" ]] && grep -qE '^TELEGRAM_BOT_TOKEN=..+' "$HERMES_HOME/.env"; then
    ok "existing Telegram token preserved"
  fi

  # ---- jailbreak verification (v6): one run must leave everything OFF ----
  say "verifying unrestricted build"
  local patcher="$WORKDIR/repo/unrestricted.sh"
  [[ -f "$patcher" ]] || patcher="$WORKDIR/unrestricted.sh"
  if [[ -f "$patcher" && -n "${HERMES_AGENT_DIR:-}" || -f "$patcher" ]]; then
    local patched
    patched="$(HERMES_AGENT_DIR="${HERMES_AGENT_DIR:-$HERMES_HOME/hermes-agent}" \
               bash "$patcher" --check 2>/dev/null | sed -n 's/^PATCHED_FILES=//p' | tail -1)"
    if [[ "${patched:-0}" =~ ^[0-9]+$ ]] && [[ "$patched" -ge 15 ]]; then
      ok "guard kill verified ($patched guard files patched, all guards OFF)"
    else
      warn "guard kill incomplete ($patched files) -- re-run: bash unrestricted.sh"
    fi
  fi
  grep -qE '^HERMES_UNRESTRICTED=1' "$HERMES_HOME/.env" 2>/dev/null \
    && ok "HERMES_UNRESTRICTED=1 in .env" \
    || warn "HERMES_UNRESTRICTED not set to 1 in .env"
  [[ -f "$HERMES_HOME/SOUL.md" ]] && ok "SOUL.md deployed" || warn "SOUL.md missing"
  [[ -f "$HERMES_HOME/memories/MEMORY.md" ]] && ok "memories/MEMORY.md deployed" || warn "memories/MEMORY.md missing"
  [[ -f "$HERMES_HOME/memories/USER.md" ]] && ok "memories/USER.md deployed" || warn "memories/USER.md missing"
  systemctl --user is-active antirefusal.service >/dev/null 2>&1 \
    && ok "anti-refusal proxy active" \
    || warn "anti-refusal proxy not active"
}

# ---------------------------------------------------------------- 8. summary
summary() {
  echo
  printf "${C_G}=====================================================${C_0}\n"
  printf "${C_G}  Hermes setup installed${C_0}\n"
  printf "${C_G}=====================================================${C_0}\n"
  printf "  repo            : %s (%s)\n" "$REPO_URL" "$REPO_REF"
  printf "  hermes home     : %s\n" "$HERMES_HOME"
  printf "  backup          : %s\n" "${BACKUP_DIR:-<dry-run>}"
  printf "  files           : SOUL.md profile.yaml skills/ memories/ plugins/ anti-refusal/\n"
  printf "  config.yaml     : %s\n" \
    "$( [[ "$MODEL_STATUS" == "needs-setup" ]] && echo 'installed only if none existed; existing kept' || echo 'preserved (existing)')"
  printf "  .env            : %s (merged, chmod 600)\n" "$HERMES_HOME/.env"
  case "${MODEL_STATUS:-unknown}" in
    preserved)   printf "  ${C_G}Model config    : PRESERVED (unchanged)${C_0}\n" ;;
    needs-setup) printf "  ${C_Y}Model config    : NOT CONFIGURED${C_0}\n" ;;
    *)           printf "  Model config    : not verified (run 'hermes setup model')\n" ;;
  esac
  case "${ANTIREFUSAL_STATUS:-skipped}" in
    enabled)          printf "  ${C_G}Auto-refusal    : ENABLED${C_0}\n" ;;
    installed-no-key) printf "  ${C_Y}Auto-refusal    : INSTALLED (needs upstream key)${C_0}\n" ;;
    failed)           printf "  ${C_R}Auto-refusal    : FAILED (check proxy.log)${C_0}\n" ;;
    *)                printf "  Auto-refusal    : skipped\n" ;;
  esac
  case "${UNRESTRICTED_STATUS:-skipped}" in
    enabled)  printf "  ${C_G}Unrestricted    : ENABLED (all internal guards disabled)${C_0}\n" ;;
    partial)  printf "  ${C_Y}Unrestricted    : PARTIAL (some patches did not apply)${C_0}\n" ;;
    no-source)printf "  ${C_Y}Unrestricted    : SKIPPED (hermes-agent source not found)${C_0}\n" ;;
    failed)   printf "  ${C_R}Unrestricted    : FAILED${C_0}\n" ;;
    dry-run)  printf "  Unrestricted    : (dry-run)\n" ;;
    *)        printf "  Unrestricted    : skipped\n" ;;
  esac
  case "${GATEWAY_STATUS:-skipped}" in
    restarted) printf "  ${C_G}Gateway         : RESTARTED (unrestricted build live)${C_0}\n" ;;
    unhealthy) printf "  ${C_R}Gateway         : restarted but NOT active -- check now${C_0}\n" ;;
    no-systemd)printf "  ${C_Y}Gateway         : restart failed -- restart manually${C_0}\n" ;;
    not-found) printf "  ${C_Y}Gateway         : no unit found -- restart manually${C_0}\n" ;;
    dry-run)   printf "  Gateway         : (dry-run)\n" ;;
    *)         printf "  Gateway         : not restarted\n" ;;
  esac
  echo
  if [[ "${MODEL_STATUS:-unknown}" == "needs-setup" ]]; then
    printf "  ${C_Y}NEXT STEP — configure your model provider:${C_0}\n"
    printf "    Run:  hermes setup model\n"
    printf "    Then choose: provider, Base URL, API key, and model.\n"
    printf "    (The installer did NOT write any default model config or keys.)\n"
  else
    printf "  next: %s\n" "edit $HERMES_HOME/.env with your router key, then 'hermes' or 'hermes gateway'"
    printf "        to change providers later:  hermes setup model\n"
  fi
  echo
}

# ---------------------------------------------------------------- main
main() {
  printf "${C_B}Hermes Agent setup installer${C_0}\n"
  preflight
  clone_repo
  backup_hermes
  install_files
  merge_env
  assess_model_config
  activate_antirefusal
  activate_unrestricted
  restart_gateway
  validate
  summary
  ROLLBACK_NEEDED=0
  trap - ERR
  [[ -n "$WORKDIR" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR" 2>/dev/null || true
}

main "$@"
