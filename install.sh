#!/usr/bin/env bash
# =============================================================================
#  Hermes Agent Setup — installer
#  ---------------------------------------------------------------------------
#  Clones github.com/pickysaja99/hermes-agent-setup, backs up ~/.hermes,
#  installs the full setup, safely MERGES your existing .env (never loses
#  secrets), and activates the anti-refusal guardrail proxy — reporting
#  "Auto-refusal: ENABLED" only after the health check passes.
#
#  Idempotent: safe to run repeatedly. Rolls back on failure.
#
#  Usage:
#     bash install.sh                  # normal install
#     bash install.sh --ref <branch>   # install a specific branch/tag
#     bash install.sh --dry-run        # show what would happen, change nothing
#     bash install.sh --no-antirefusal # skip the auto-refusal activation stage
#     bash install.sh --help
# =============================================================================
set -Eeuo pipefail

REPO_URL="${HERMES_SETUP_REPO:-https://github.com/pickysaja99/hermes-agent-setup.git}"
REPO_REF="${HERMES_SETUP_REF:-main}"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
WORKDIR=""
DRY_RUN=0
DO_ANTIREFUSAL=1
BACKUP_DIR=""
STAGE_LOG=""
ROLLBACK_NEEDED=0

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
  # restore backup if we have one
  if [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR/hermes" ]]; then
    warn "restoring ~/.hermes from $BACKUP_DIR/hermes"
    rm -rf "${HERMES_HOME}.failed" 2>/dev/null || true
    mv "$HERMES_HOME" "${HERMES_HOME}.failed" 2>/dev/null || true
    cp -a "$BACKUP_DIR/hermes" "$HERMES_HOME"
    ok "rolled back. previous dir parked at ${HERMES_HOME}.failed"
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
  run cp "$S/config.yaml" "$HERMES_HOME/config.yaml"
  run cp "$S/profile.yaml" "$HERMES_HOME/profile.yaml"
  run cp -r "$S/skills"   "$HERMES_HOME/"
  run cp -r "$S/memories" "$HERMES_HOME/"
  run cp -r "$S/plugins"  "$HERMES_HOME/"
  run cp -r "$S/anti-refusal" "$HERMES_HOME/"
  run cp "$S/README.md"   "$HERMES_HOME/SETUP-README.md"
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

[Install]
WantedBy=default.target
UNIT

  # -- optional: route Hermes through the proxy for auto-refusal to be IN the path
  local cfg="$HERMES_HOME/config.yaml"
  if [[ -f "$cfg" ]] && grep -qE '^model:' "$cfg"; then
    cp -a "$cfg" "$cfg.pre-antirefusal"
    # switch model.base_url to the proxy (idempotent)
    if grep -qE '^  base_url:' "$cfg"; then
      "$PY" - "$cfg" <<'PYEOF' || warn "config rewrite skipped"
import re, sys
p = sys.argv[1]
s = open(p).read()
# only touch the first "model:" block's base_url
s2 = re.sub(r'(?ms)^(model:\n(?:.*\n)*?  base_url:\s*).*$', r'\1http://127.0.0.1:9200/v1', s, count=1)
if s2 != s:
    open(p, 'w').write(s2)
    print("model.base_url -> proxy")
else:
    print("no change")
PYEOF
    fi
  fi

  # -- start the service
  if systemctl --user daemon-reload 2>/dev/null; then
    systemctl --user enable antirefusal.service >/dev/null 2>&1 || true
    systemctl --user restart antirefusal.service >/dev/null 2>&1 || \
      systemctl --user start antirefusal.service >/dev/null 2>&1 || true
  else
    warn "systemd --user not available — start manually: $PY $AR/proxy.py"
  fi

  # -- VERIFY: health endpoint must answer {"ok": true}
  local tries=0 healthy=0
  for tries in 1 2 3 4 5 6 7 8; do
    sleep 1
    local body
    body="$(curl -fsS --max-time 3 http://127.0.0.1:9200/health 2>/dev/null || true)"
    if printf '%s' "$body" | grep -q '"ok"[[:space:]]*:[[:space:]]*true'; then
      healthy=1; break
    fi
  done

  if [[ $healthy -eq 1 ]]; then
    local keyed
    keyed="$(printf '%s' "$body" | grep -o '"key"[[:space:]]*:[[:space:]]*true' || true)"
    ok "proxy healthy on 127.0.0.1:9200"
    if [[ -n "$keyed" ]]; then
      ok "Auto-refusal: ENABLED (upstream key present)"
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
  printf "  files           : SOUL.md config.yaml profile.yaml skills/ memories/ plugins/ anti-refusal/\n"
  printf "  .env            : %s (merged, chmod 600)\n" "$HERMES_HOME/.env"
  case "${ANTIREFUSAL_STATUS:-skipped}" in
    enabled)          printf "  ${C_G}Auto-refusal    : ENABLED${C_0}\n" ;;
    installed-no-key) printf "  ${C_Y}Auto-refusal    : INSTALLED (needs upstream key)${C_0}\n" ;;
    failed)           printf "  ${C_R}Auto-refusal    : FAILED (check proxy.log)${C_0}\n" ;;
    *)                printf "  Auto-refusal    : skipped\n" ;;
  esac
  echo
  printf "  next: %s\n" "edit $HERMES_HOME/.env with your router key, then 'hermes' or 'hermes gateway'"
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
  activate_antirefusal
  validate
  summary
  ROLLBACK_NEEDED=0
  trap - ERR
  [[ -n "$WORKDIR" && -d "$WORKDIR" ]] && rm -rf "$WORKDIR" 2>/dev/null || true
}

main "$@"
