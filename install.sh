#!/usr/bin/env bash
# =============================================================================
#  Hermes Agent Setup — installer
#  ---------------------------------------------------------------------------
#  Clones github.com/pickysaja99/hermes-agent-setup, backs up ~/.hermes,
#  installs the full setup, safely MERGES your existing .env (never loses
#  secrets), activates the anti-refusal guardrail proxy, and applies the
#  UNRESTRICTED PATCH (disables every internal guard that could neutralize
#  SOUL.md / MEMORY.md, kills the provider content_filter refusal surface,
#  pins context_file_max_chars so the identity file never truncates, forces
#  reasoning_effort=none, and sets HERMES_UNRESTRICTED=1 in the Hermes env).
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
#  Non-interactive / automation (no TTY needed):
#     SETUP_BASE_URL=https://router/v1 SETUP_API_KEY=sk-... SETUP_MODEL=model-id \
#       bash install.sh
#  Interactive (default when a TTY is present): the installer asks for the
#  router Base URL + API key, lists the router's live /v1/models, and lets you
#  pick the default model. A missing TELEGRAM_BOT_TOKEN is prompted and
#  validated against the Bot API before it is saved.
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
SETUP_MODEL_CHOSEN=""
SETUP_BASE_RESOLVED=""
TELEGRAM_STATUS="unknown"

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
    # x-access-token:<TOKEN>@ built with a real expansion. The old form put
    # ${GITHUB_TOKEN} inside a single-quoted sed script; it got truncated and left
    # install.sh unrunnable (unterminated quote + bad substitution).
    local _tok="${GITHUB_TOKEN}"
    url="https://x-access-token:${_tok}@${REPO_URL#https://}"
    # (single-quoted sed script with ${GITHUB_TOKEN} inline) got truncated and
    # left install.sh unrunnable: unterminated quote + bad substitution.
    local _tok="${GITHUB_TOKEN}"
    url="${REPO_URL/https:\/\//https:\/\/x-access-token:${_tok}@}"
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
  # MERGE-COPY, never `cp -r src dst/`: re-running the installer used to nest
  # the tree (HERMES_HOME/skills/skills, plugins/plugins, anti-refusal/anti-
  # refusal) and, worse, clobber local edits. Contents are merged over the
  # destination and existing files that differ are backed up first.
  _merge_copy() {  # src_dir dst_dir
    local src="$1" dst="$2"
    [[ -d "$src" ]] || return 0
    mkdir -p "$dst"
    if command -v rsync >/dev/null 2>&1; then
      rsync -a --backup --suffix=".pre-install.$(date +%s)" "$src/" "$dst/" 2>/dev/null \
        || warn "rsync merge failed for $dst"
    else
      ( cd "$src" && find . -type d -print0 | while IFS= read -r -d '' d; do
          mkdir -p "$dst/$d"
        done )
    ( cd "$src" && find . -type f -print0 | while IFS= read -r -d '' f; do
          if [[ -f "$dst/$f" ]] && ! cmp -s "$f" "$dst/$f"; then
            cp -a "$dst/$f" "$dst/$f.pre-install" 2>/dev/null || true
          fi
          cp -a "$f" "$dst/$f"
        done )
    fi
  }

  # SOUL.md / profile.yaml: back up and only replace when the repo copy is
  # NEWER or missing on the target. A blind cp-a used to overwrite an
  # operator's local SOUL edits on every re-install.
  # SOUL.md is the identity/consciousness file: the repo copy is
  # AUTHORITATIVE and always wins (operator decision — an out-of-date local
  # SOUL is worse than a clobbered one). Back it up, then overwrite.
  if [[ -f "$S/SOUL.md" ]]; then
    if [[ -f "$HERMES_HOME/SOUL.md" ]] && ! cmp -s "$S/SOUL.md" "$HERMES_HOME/SOUL.md"; then
      run cp -a "$HERMES_HOME/SOUL.md" "$HERMES_HOME/SOUL.md.pre-install.$(date +%s)"
    fi
    run cp -a "$S/SOUL.md" "$HERMES_HOME/SOUL.md"
    ok "SOUL.md deployed (repo copy is authoritative; previous saved as .pre-install)"
  fi
  # profile.yaml carries local runtime settings (active profile etc.) and must
  # NOT be silently reverted — it is installed ONCE, only when absent. A
  # newer-mtime rule is wrong here: the cloned repo is always newer than a
  # file the operator has been using, so that rule reverted it every run.
  if [[ -f "$S/profile.yaml" && ! -f "$HERMES_HOME/profile.yaml" ]]; then
    run cp -a "$S/profile.yaml" "$HERMES_HOME/profile.yaml"
    ok "profile.yaml installed (none existed)"
  elif [[ -f "$HERMES_HOME/profile.yaml" ]]; then
    printf '  [keep] profile.yaml (existing local settings preserved)\n'
  fi
  local _sd
  for _sd in skills memories plugins; do
    [[ -d "$S/$_sd" ]] && _merge_copy "$S/$_sd" "$HERMES_HOME/$_sd"
    [[ -d "$S/$_sd/$_sd" ]] && rm -rf "$S/$_sd/$_sd"   # heal a nested copy in the repo
  done
  # anti-refusal: copy the CODE, never the derived config.json. Clobbering it
  # with the template silently disarmed the refusal ladder (inject_light /
  # force_prefill false, max_attempts 1) on every re-install. configure_upstream
  # / activate_antirefusal own that file, and arm_proxy re-arms it.
  if [[ -d "$S/anti-refusal" ]]; then
    mkdir -p "$HERMES_HOME/anti-refusal"
    local arf
    for arf in "$S"/anti-refusal/*; do
      [[ -f "$arf" ]] || continue
      [[ "$(basename "$arf")" == "config.json" ]] && continue
      if [[ -f "$HERMES_HOME/anti-refusal/$(basename "$arf")" ]] \
         && ! cmp -s "$arf" "$HERMES_HOME/anti-refusal/$(basename "$arf")"; then
        cp -a "$HERMES_HOME/anti-refusal/$(basename "$arf")" \
              "$HERMES_HOME/anti-refusal/$(basename "$arf").pre-install.$(date +%s)" 2>/dev/null || true
      fi
      run cp -a "$arf" "$HERMES_HOME/anti-refusal/$(basename "$arf")"
    done
  fi
  run cp -a "$S/README.md"   "$HERMES_HOME/SETUP-README.md"

  # config.yaml policy (operator rule): the REPO TEMPLATE WINS for everything
  # EXCEPT three operator values that must never be lost:
  #   1. model.base_url   2. model.api_key   3. model.default (model id)
  # Everything else -- including the whole `gateway:` block -- comes from the
  # template. Gateway credentials live in .env (TELEGRAM_BOT_TOKEN etc.) and are
  # protected by merge_env, not by this file, so gateway: is safe to overwrite.
  if [[ ! -f "$HERMES_HOME/config.yaml" ]]; then
    run cp "$S/config.yaml" "$HERMES_HOME/config.yaml"
    ok "config.yaml installed (none existed)"
  else
    local PYC; PYC="$(find_python || true)"
    if [[ -n "$PYC" && $DRY_RUN -eq 0 ]]; then
      run cp -a "$HERMES_HOME/config.yaml" "$HERMES_HOME/config.yaml.pre-install.$(date +%s)"
      "$PYC" - "$HERMES_HOME/config.yaml" "$S/config.yaml" <<'PYEOF' || warn "config.yaml merge skipped"
import re, sys

dst, tpl = sys.argv[1], sys.argv[2]
have = open(dst, encoding="utf-8").read()
want = open(tpl, encoding="utf-8").read()

def blocks(text):
    """top-level key -> its full text block (comment lines above it excluded)."""
    out, cur, name = {}, [], None
    for ln in text.splitlines(keepends=True):
        if ln.strip() and not ln[0].isspace() and not ln.lstrip().startswith("#"):
            if name:
                out[name] = "".join(cur)
            name, cur = ln.split(":", 1)[0].strip(), [ln]
        elif name:
            cur.append(ln)
    if name:
        out[name] = "".join(cur)
    return out

hb, wb = blocks(have), blocks(want)

def model_val(key, text):
    """value of a key on the model: block at exactly 2-space indent."""
    m = re.search(r"(?m)^model:\s*$", text)
    if not m:
        return None
    m2 = re.search(r"(?m)^  " + key + r":\s*(.*)$", text[m.end():])
    if not m2:
        return None
    v = m2.group(1).strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
        v = v[1:-1]
    return v

protected = {k: model_val(k, have) for k in ("base_url", "api_key", "default")}

# Template blocks win wholesale (gateway: included). Only unknown operator
# sections survive; the three model values are re-applied below.
merged = dict(wb)
for k, v in hb.items():
    if k not in merged:
        merged[k] = v

mblk = merged.get("model")
if mblk:
    for key, val in protected.items():
        if val is None:
            continue
        if re.search(r"(?m)^  " + key + r":", mblk):
            mblk = re.sub(r"(?m)^  " + key + r":.*$",
                          lambda _m, k=key, v=val: "  %s: %s" % (k, v), mblk, count=1)
        else:
            mblk = mblk.rstrip("\n") + "\n  %s: %s\n" % (key, val)
    merged["model"] = mblk

order = list(wb.keys()) + [k for k in hb.keys() if k not in wb]
out = "".join(merged[k] for k in order if k in merged)
open(dst, "w", encoding="utf-8").write(out)
kept = [k for k, v in protected.items() if v]
print("   config.yaml: template applied (gateway: too); preserved %s"
      % ", ".join("model." + k for k in kept))
PYEOF
    fi
    ok "config.yaml converged to template; base_url/api_key/model preserved"
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
    local added=0 filled=0 skipped=0
    while IFS= read -r line; do
      # only consider real KEY=... assignment lines
      [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
      local key="${line%%=*}"
      local newval="${line#*=}"
      if grep -qE "^${key}=" "$tmp"; then
        # key already present: an empty value in .env stays unless the
        # template actually carries one -- never blank a live secret, and
        # never let a template placeholder replace a real value.
        local oldval; oldval="$(grep -E "^${key}=" "$tmp" | tail -1 | cut -d= -f2- || true)"
        if [[ -z "$oldval" && -n "$newval" ]]; then
          awk -v k="$key" -v v="$newval" '{ if (!done && index($0, k "=") == 1) { print k "=" v; done = 1 } else print }' "$tmp" > "$tmp.2" \
            && mv "$tmp.2" "$tmp"
          filled=$((filled+1))
        fi
        continue
      fi
      # new key from the template: skip obvious placeholders so an install can
      # never inject a demo upstream/key into a configured box
      case "$newval" in
        ""|"<"*">"*|*"YOUR_"*|*"your_"*|*"changeme"*|*"CHANGEME"*|*"REPLACE"*|*"xxxx"*) skipped=$((skipped+1)); continue ;;
        *"placeholder"*|*"PLACEHOLDER"*|*"example"*|*"EXAMPLE"*|*"dummy"*|*"DUMMY"*|*"sk-xxx"*|*"api_key_here"*|*"API_KEY_HERE"*|*"your-"*) skipped=$((skipped+1)); continue ;;
      esac
      printf "%s\n" "$line" >> "$tmp"
      added=$((added+1))
    done < "$src"
    mv "$tmp" "$dst"
    ok ".env merged (kept existing values; added $added new keys, filled $filled empty, skipped $skipped placeholders)"
  fi
  chmod 600 "$dst"
  ok ".env permissions set to 600"
}

# ---------------------------------------------------------------- 4b. upstream setup
# Interactive: the operator types the router Base URL + API key, then picks the
# default model from the router's live /v1/models list. Writes .env,
# config.yaml and anti-refusal/config.json so proxy + gateway agree.
#
# Non-interactive fallback (never hangs): SETUP_BASE_URL / SETUP_API_KEY /
# SETUP_MODEL env vars; with no TTY and nothing set, existing config is kept.
# ---------------------------------------------------------------------------

_env_get() {  # key -> value from .env (empty when unset)
  [[ -f "$HERMES_HOME/.env" ]] || return 0
  grep -E "^$1=" "$HERMES_HOME/.env" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

_env_set() {  # key value — replace the line in place, else append
  local k="$1" v="$2" f="$HERMES_HOME/.env" tmp
  [[ -f "$f" ]] || touch "$f"
  # F3: jangan timpa nilai lama yang VALID dengan string kosong. Cacat lama:
  # _env_set KEY "" menghapus CUSTOM_API_KEY/CUSTOM_BASE_URL yang terisi.
  if [[ -z "$v" ]] && grep -qE "^${k}=..+" "$f"; then
    return 0
  fi
  if grep -qE "^${k}=" "$f"; then
    tmp="$(mktemp)"
    if awk -v k="$k" -v v="$v" '{ if (!done && index($0, k "=") == 1) { print k "=" v; done = 1 } else print }' "$f" > "$tmp"; then
      mv "$tmp" "$f"
    else
      rm -f "$tmp"
    fi
  else
    printf '%s=%s\n' "$k" "$v" >> "$f"
  fi
}

_model_field() {  # field -> model: block OWN key (exact 2-space; aliases at 4+ excluded)
  local cfg="$HERMES_HOME/config.yaml"
  [[ -f "$cfg" ]] || return 0
  sed -n '/^model:/,/^[^[:space:]]/p' "$cfg" 2>/dev/null \
    | grep -m1 -E "^  $1:" \
    | sed -E "s/^  $1:[[:space:]]*//; s/^'//; s/'$//; s/^\"//; s/\"$//" || true
}

_ask() {  # var prompt default — empty input keeps the default
  local __v="$1" __p="$2" __d="$3" __in=""
  printf '%s' "$__p"
  [[ -n "$__d" ]] && printf ' [%s]' "$__d"
  printf ': '
  IFS= read -r __in </dev/tty 2>/dev/null || true
  printf -v "$__v" '%s' "${__in:-$__d}"
}

_ask_secret() {  # var prompt default — silent; never echoes the default
  local __v="$1" __p="$2" __d="$3" __in=""
  [[ -n "$__d" ]] && __p="$__p (Enter = keep current)"
  printf '%s: ' "$__p"
  IFS= read -r -s __in </dev/tty 2>/dev/null || true
  printf '\n'
  printf -v "$__v" '%s' "${__in:-$__d}"
}

_fetch_models() {  # base key -> model ids, one per line (empty on failure)
  local base="$1" key="$2" out code json PY jf
  out="$(curl -s -m 25 -w $'\n%{http_code}' -H "Authorization: Bearer $key" \
    "${base%/}/models" 2>/dev/null || true)"
  code="$(printf '%s' "$out" | tail -n1)"
  json="$(printf '%s' "$out" | sed '$d')"
  [[ "$code" == "200" ]] || return 1
  PY="$(find_python || true)"
  if [[ -n "$PY" ]]; then
    jf="$(mktemp)"
    printf '%s' "$json" > "$jf"
    "$PY" -c 'import sys, json
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
ms = d.get("data") or d.get("models") or []
for m in ms:
    mid = m.get("id") if isinstance(m, dict) else m
    if mid:
        print(mid)' "$jf" 2>/dev/null && { rm -f "$jf"; return 0; }
    rm -f "$jf"
  fi
  printf '%s' "$json" | grep -oE '"id"[[:space:]]*:[[:space:]]*"[^"]+"' \
    | sed -E 's/.*"([^"]+)"[[:space:]]*$/\1/' || true
}

_select_model() {  # models_list want -> chosen model id
  local models="$1" want="$2"
  local -a all=() pref=() rest=() clean=()
  local m
  mapfile -t all <<< "$models"
  for m in "${all[@]:-}"; do
    [[ -z "$m" ]] && continue
    if printf '%s' "$m" | grep -qiE 'uncensored|unrestricted|flash|step|gpt|claude|sonnet'; then
      pref+=("$m")
    else
      rest+=("$m")
    fi
  done
  for m in "${pref[@]:-}" "${rest[@]:-}"; do
    [[ -n "$m" ]] && clean+=("$m")
  done
  (( ${#clean[@]} == 0 )) && { printf '%s' "$want"; return 0; }

  local def="${clean[0]}"
  for m in "${clean[@]}"; do
    if [[ -n "$want" && "$m" == "$want" ]]; then def="$want"; break; fi
  done
  printf '   model tersedia:\n'
  local idx=0 marker
  for m in "${clean[@]}"; do
    idx=$((idx + 1))
    marker=""
    [[ "$m" == "$def" ]] && marker="   <- default"
    printf '   %2d) %s%s\n' "$idx" "$m" "$marker"
  done
  local choice=""
  printf '   pilih model (nomor / ID manual, Enter = %s): ' "$def"
  IFS= read -r choice </dev/tty 2>/dev/null || true
  if [[ -z "$choice" ]]; then
    printf '%s' "$def"
  elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#clean[@]} )); then
    printf '%s' "${clean[$((choice - 1))]}"
  else
    printf '%s' "$choice"
  fi
}

configure_upstream() {
  local cfg="$HERMES_HOME/config.yaml"
  local PY; PY="$(find_python || true)"

  if [[ $DRY_RUN -eq 1 ]]; then
    printf "    ${C_Y}(dry-run)${C_0} prompt Base URL + API key, fetch /v1/models, write .env/config.yaml/anti-refusal config\n"
    return 0
  fi

  local have_tty=0
  [[ -t 0 && -c /dev/tty ]] && have_tty=1

  local cur_base cur_keyenv cur_key cur_model
  cur_base="$(_model_field base_url)"
  cur_keyenv="$(_model_field api_key)"
  cur_keyenv="${cur_keyenv#\$\{}"; cur_keyenv="${cur_keyenv%\}}"
  cur_model="$(_model_field default)"
  [[ -n "$cur_keyenv" ]] && cur_key="$(_env_get "$cur_keyenv")"

  # The local anti-refusal proxy (127.0.0.1:9200) is NOT an upstream. On an
  # already-routed box model.base_url IS the proxy, so the fallback chain
  # below must skip loopback hosts or install.sh writes a self-looping
  # anti-refusal config and the model goes silent.
  _san_base() {  # value -> value (no trailing slash), empty when loopback
    local b="${1%/}"
    case "$b" in
      http://127.0.0.1*|http://localhost*|https://127.0.0.1*|https://localhost*) echo "" ;;
      *) echo "$b" ;;
    esac
  }
  local def_base
  def_base="$(_san_base "$cur_base")"
  [[ -z "$def_base" ]] && def_base="$(_san_base "$(_env_get ANTIREFUSAL_UPSTREAM)")"
  [[ -z "$def_base" ]] && def_base="$(_san_base "$(_env_get CUSTOM_BASE_URL)")"
  # No hardcoded default router. A stale house host used to be offered as the
  # default Base URL, so a branch-new install could point at a router the
  # operator never chose (and had no key for). Empty = ask the operator.

  local base="${SETUP_BASE_URL:-}" key="${SETUP_API_KEY:-}" model="${SETUP_MODEL:-}" models=""

  if [[ $have_tty -eq 1 ]]; then
    say "model upstream — masukkan Base URL router + API key"
    _ask base "Base URL" "$def_base"
    base="${base%/}"
    local khint="API key"
    [[ -n "$cur_key" ]] && khint="API key (Enter = keep ****${cur_key: -4})"
    _ask_secret key "$khint" "$cur_key"

    local try
    for try in 1 2 3; do
      models="$(_fetch_models "$base" "$key" || true)"
      [[ -n "$models" ]] && break
      if [[ $try -lt 3 ]]; then
        warn "gagal ambil daftar model dari $base (try $try/3)"
        sleep 2
      fi
    done

    if [[ -n "$models" ]]; then
      local n; n="$(printf '%s\n' "$models" | grep -c . || true)"
      ok "router merespond — $n model tersedia"
      model="$(_select_model "$models" "${model:-$cur_model}")"
    else
      warn "tidak bisa ambil /models dari $base"
      _ask model "Model ID (manual)" "${model:-$cur_model}"
    fi
  fi

  base="${base%/}"
  [[ -z "$base" ]] && base="$def_base"
  [[ -z "$model" ]] && model="$cur_model"
  [[ -z "$key" ]] && key="$cur_key"

  if [[ -z "$base" || -z "$model" ]]; then
    warn "upstream tidak lengkap (base/model kosong) — config.yaml tidak diubah"
    SETUP_MODEL_CHOSEN=""; SETUP_BASE_RESOLVED=""
    return 0
  fi
  if [[ -z "$PY" ]]; then
    warn "python3 tidak ditemukan — config.yaml/anti-refusal tidak diubah"
    SETUP_MODEL_CHOSEN=""; SETUP_BASE_RESOLVED=""
    return 0
  fi

  # Hard guard: the proxy itself is never a valid upstream (self-loop).
  case "$base" in
    http://127.0.0.1*|http://localhost*|https://127.0.0.1*|https://localhost*)
      warn "upstream '$base' adalah proxy lokal — DITOLAK (self-loop)"
      warn "  config.yaml & anti-refusal/config.json tidak diubah (config lama tetap dipakai)"
      SETUP_MODEL_CHOSEN=""; SETUP_BASE_RESOLVED=""
      return 0
      ;;
  esac

  # A missing key would write api_key: ${EMPTY_ENV} -> gateway 401 -> model
  # bisu. Never rewrite config without a key to validate.
  if [[ -z "$key" ]]; then
    warn "API key kosong — config.yaml & anti-refusal/config.json tidak diubah"
    warn "  set SETUP_API_KEY (non-TTY) atau isi di prompt; lalu jalankan ulang"
    SETUP_MODEL_CHOSEN=""; SETUP_BASE_RESOLVED=""
    return 0
  fi

  # Live chat canary BEFORE touching config.yaml. A key that lists /models
  # but fails chat (or a dead router, or a typo'd model id) must never
  # become the new model.base_url. Browser UA is required: onihub.tech sits
  # behind Cloudflare, which 1010s the curl default UA.
  local cbody cok=0
  cbody="$(curl -s -m 60 -X POST "$base/chat/completions" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $key" \
    -H "User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36" \
    -d "{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":8,\"stream\":false}" 2>/dev/null || true)"
  if [[ -n "$cbody" ]] && printf '%s' "$cbody" | grep -q '"content"'; then
    cok=1
  fi
  if [[ $cok -eq 0 ]]; then
    warn "canary chat ke $base (model=$model) GAGAL — config.yaml & anti-refusal/config.json TIDAK diubah"
    warn "  config lama tetap dipakai; perbaiki base URL / API key / model id lalu jalankan ulang"
    SETUP_MODEL_CHOSEN=""; SETUP_BASE_RESOLVED=""
    return 0
  fi
  ok "canary chat ok — $base menjawab untuk model=$model"

  local host slug keyenv
  host="$(printf '%s' "$base" | sed -E 's#^https?://##; s#/.*##')"
  slug="$(printf '%s' "$host" | tr 'A-Z' 'a-z' | sed -E 's/[^a-z0-9]+/_/g; s/^_+//; s/_+$//' | tr 'a-z' 'A-Z')"
  keyenv="HERMES_CUSTOM_${slug}_API_KEY"

  if [[ -n "$key" ]]; then
    _env_set "$keyenv" "$key"
  fi
  _env_set "ANTIREFUSAL_UPSTREAM" "$base"
  # single source of truth: .env utama harus mencerminkan router yang
  # benar-benar menjawab canary, supaya proxy/watchdog tidak drift ke
  # upstream lama (onihub) saat model.base_url sudah pindah ke mahi.
  [[ -n "$key" ]] && _env_set "CUSTOM_BASE_URL" "$base"
  [[ -n "$key" ]] && _env_set "CUSTOM_API_KEY" "$key"
  _env_set "ANTIREFUSAL_SINGLE_UPSTREAM" "1"
  ok ".env: $keyenv + ANTIREFUSAL_UPSTREAM=$base (+CUSTOM_BASE_URL/CUSTOM_API_KEY)"

  # .env selalu punya ANTIREFUSAL_PORT (dipakai unit + proxy)
  grep -qE '^ANTIREFUSAL_PORT=' "$HERMES_HOME/.env" || _env_set "ANTIREFUSAL_PORT" "9200"

  if [[ -f "$cfg" ]]; then
    "$PY" - "$cfg" "$base" "$keyenv" "$model" "$host" <<'PYEOF' || warn "config.yaml model block tidak ditulis"
import re, sys
p, base, keyenv, model, host = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
lines = open(p, encoding="utf-8").read().splitlines(keepends=True)
mi = next((i for i, l in enumerate(lines) if re.match(r"^model:\s*(#.*)?$", l)), None)
if mi is None:
    if lines and not lines[-1].endswith("\n"):
        lines[-1] += "\n"
    lines.append("\nmodel:\n")
    mi = len(lines) - 1
end = mi + 1
while end < len(lines):
    l = lines[end]
    if l.strip() and not l[0].isspace():
        break
    end += 1
block = lines[mi + 1:end]
indent = 2
for l in block:
    if l.strip():
        indent = len(l) - len(l.lstrip())
        break

def quote(v):
    # ${ENV} references must stay UNQUOTED: PyYAML keeps single quotes literal,
    # so api_key: '${FOO}' sends the literal text as the bearer and every
    # request 401s. Only plain scalars that YAML cannot misread are bare.
    if re.fullmatch(r"\$\{[A-Za-z_][A-Za-z0-9_]*\}", v):
        return v
    return v if re.fullmatch(r"[A-Za-z0-9_./@-]+", v) else "'%s'" % v.replace("'", "''")

def setkv(key, val):
    pat = re.compile(r"^(\s+)" + re.escape(key) + r"\s*:")
    for j, l in enumerate(block):
        m = pat.match(l)
        if m and len(m.group(1)) == indent:
            block[j] = "%s%s: %s\n" % (" " * indent, key, val)
            return
    block.insert(0, "%s%s: %s\n" % (" " * indent, key, val))

def toplevel():
    """(start, end) line span of each top-level block in the document."""
    spans, i = {}, 0
    while i < len(lines):
        l = lines[i]
        if l.strip() and not l[0].isspace() and not l.lstrip().startswith("#"):
            key = l.split(":", 1)[0].strip()
            j = i + 1
            while j < len(lines):
                n = lines[j]
                if n.strip() and not n[0].isspace() and not n.lstrip().startswith("#"):
                    break
                j += 1
            spans[key] = (i, j)
            i = j
        else:
            i += 1
    return spans


spans = toplevel()
prov = spans.get("providers")
seed = [
    "providers:\n",
    "  custom:\n",
    "    base_url: %s\n" % quote(base),
    "    api_key: %s\n" % quote("${%s}" % keyenv),
    "    api_mode: chat_completions\n",
    "    model: %s\n" % quote(model),
]
if prov:
    blk = lines[prov[0]:prov[1]]
    if not any(l.startswith("  custom:") for l in blk):
        # add the custom provider at the END of the existing block
        blk = blk[0:1] + blk[1:] + seed[1:]
        lines[prov[0]:prov[1]] = blk
    # an existing custom: provider is preserved verbatim -- never overwritten
elif "model" in spans:
    k = spans["model"][1]
    if k and not lines[k - 1].endswith("\n"):
        lines[k - 1] += "\n"
    lines[k:k] = seed
    spans = toplevel()

# custom_providers (the operator's saved router list: name/base_url/key_env/
# model). A re-run must ADD the current router when it is absent and keep
# every other entry — wiping this list is the "configurasi gateway/model
# hilang setelah install" bug.
cp = spans.get("custom_providers")
ENTRY = ["  - name: %s\n" % quote(host or base),
         "    base_url: %s\n" % quote(base),
         "    key_env: %s\n" % keyenv,
         "    model: %s\n" % quote(model)]


def cp_has(blk):
    """True when the router is already listed — indentation/quote-insensitive
    (a `"    base_url: x"` vs `base_url: 'x'` mismatch duplicated the entry
    on every re-run)."""
    for l in blk:
        if l.strip().startswith("- name:"):
            if l.split("name:", 1)[1].strip().strip("'\"") == (host or base):
                return True
        if "base_url:" in l and l.split("base_url:", 1)[1].strip().strip("'\"").rstrip("/") == base.rstrip("/"):
            return True
    return False


if cp:
    blk = lines[cp[0]:cp[1]]
    if not cp_has(blk):
        if not blk[-1].endswith("\n"):
            blk[-1] += "\n"
        blk = blk + ENTRY
        lines[cp[0]:cp[1]] = blk
else:
    k = spans["model"][1] if "model" in spans else len(lines)
    lines[k:k] = ["custom_providers:\n"] + ENTRY

setkv("base_url", quote(base))
setkv("api_key", quote("${%s}" % keyenv))
setkv("default", quote(model))
setkv("provider", "custom")
setkv("api_mode", "chat_completions")
lines[mi + 1:end] = block
open(p, "w", encoding="utf-8").write("".join(lines))
print("   model block -> base_url=%s default=%s" % (base, model))
PYEOF
    ok "config.yaml: base_url=$base default=$model"
  fi

  local arcfg="$HERMES_HOME/anti-refusal/config.json"
  if [[ -f "$arcfg" ]]; then
    local mf; mf="$(mktemp)"
    printf '%s\n' "$models" > "$mf"
    # F4: buang SEMUA upstream lama yang router-nya BEDA host dari $host.
    # Cacat lama: upstream onihub/morku tetap di daftar walau model.base_url
    # sudah pindah (mis. ke api2.mahicenter.cloud); proxy tetap mencoba
    # onihub dulu dan watchdog/route nyangkut di sana.
    "$PY" - "$arcfg" "$base" "$keyenv" "$model" "$mf" "$host" <<'PYEOF' || warn "anti-refusal/config.json tidak diupdate"
import json, sys
from urllib.parse import urlparse
p, base, keyenv, model, mf, host = sys.argv[1:7]
cfg = json.load(open(p))
models = [l.strip() for l in open(mf) if l.strip()]

def hostof(b):
    try:
        return (urlparse(b).hostname or "").lower()
    except Exception:
        return ""

want = host.lower()
ups = [u for u in (cfg.get("upstreams") or []) if isinstance(u, dict)]
kept = []  # single-upstream contract: no siblings kept
dropped = [u.get("base") for u in ups if u.get("base", "").rstrip("/") != base.rstrip("/")]
cfg["upstreams"] = [{"name": host, "base": base, "key_env": keyenv}]
cfg["single_upstream"] = True
cfg["extra_upstreams"] = []
cfg["upstream_base_url"] = base
cfg["upstream_key_env"] = keyenv
cfg["default_model"] = model
# models: ALWAYS keep the chosen model first. The old guard only wrote the
# list when /models answered, leaving a stale default_model's model list
# (e.g. ...-flash when default is ...-flash-1017) -- the proxy's ladder then
# climbed to a model the operator never picked.
seen, out = set(), []
for m in [model] + models:
    if m and m not in seen:
        seen.add(m)
        out.append(m)
cfg["models"] = out[:64]
json.dump(cfg, open(p, "w"), indent=2)
print("   anti-refusal config -> upstream=%s default=%s models=%d kept=%d dropped=%s"
      % (base, model, len(cfg.get("models") or []), len(kept), dropped or "none"))
PYEOF
    rm -f "$mf"
    ok "anti-refusal/config.json updated (upstream lama beda-host dibuang)"
  fi

  SETUP_MODEL_CHOSEN="$model"
  SETUP_BASE_RESOLVED="$base"
}

# ---------------------------------------------------------------- 4c. telegram token
# If .env has no TELEGRAM_BOT_TOKEN after install (fresh box, wiped .env),
# the operator can paste it here — validated against the Bot API before save.
# ---------------------------------------------------------------------------

ensure_telegram_token() {
  local tok; tok="$(_env_get TELEGRAM_BOT_TOKEN)"
  if [[ -n "$tok" ]]; then
    TELEGRAM_STATUS="preserved"
    ok "Telegram token preserved in .env"
    return 0
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    printf "    ${C_Y}(dry-run)${C_0} prompt TELEGRAM_BOT_TOKEN when missing\n"
    return 0
  fi
  local have_tty=0
  [[ -t 0 && -c /dev/tty ]] && have_tty=1
  if [[ $have_tty -eq 0 ]]; then
    warn "TELEGRAM_BOT_TOKEN kosong — set manual di $HERMES_HOME/.env"
    TELEGRAM_STATUS="missing"
    return 0
  fi
  say "Telegram bot token kosong — paste token dari @BotFather"
  local attempt
  for attempt in 1 2 3; do
    _ask_secret tok "TELEGRAM_BOT_TOKEN" ""
    [[ -z "$tok" ]] && { warn "dilewati — set manual nanti"; TELEGRAM_STATUS="skipped"; return 0; }
    if [[ ! "$tok" =~ ^[0-9]{6,}:[A-Za-z0-9_-]{30,}$ ]]; then
      warn "format salah — harus <digits>:<35+ karakter>"
      continue
    fi
    if curl -s -m 12 "https://api.telegram.org/bot$tok/getMe" 2>/dev/null | grep -q '"ok":true'; then
      _env_set TELEGRAM_BOT_TOKEN "$tok"
      ok "Telegram token valid (getMe ok) — disimpan di .env"
      TELEGRAM_STATUS="set"
      return 0
    fi
    warn "getMe gagal — token ditolak Telegram"
  done
  warn "TELEGRAM_BOT_TOKEN tidak diset — set manual di $HERMES_HOME/.env"
  TELEGRAM_STATUS="missing"
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
  # OPERATOR CONTRACT: one upstream, taken from .env only. A missing value is
  # an ERROR the operator must fix — never substitute another router.
  if [[ -z "$upstream" ]]; then
    warn "ANTIREFUSAL_UPSTREAM/CUSTOM_BASE_URL kosong di .env — proxy tidak diarahkan ke host lain"
    ANTIREFUSAL_STATUS="no-upstream"
    return 0
  fi
  # mirror it back so .env stays the single source of truth
  _env_set "ANTIREFUSAL_UPSTREAM" "$upstream"

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
Environment=ANTIREFUSAL_SINGLE_UPSTREAM=1
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
      ANTIREFUSAL_SINGLE_UPSTREAM=1 \
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
        local canary_model="${ANTIREFUSAL_CANARY_MODEL:-${SETUP_MODEL_CHOSEN:-step-5-preview-UNCENSORED}}"
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
    if in_model and ln.startswith("  base_url:") and not done:
        # exact 2-space indent: the model block's OWN base_url, never a
        # nested alias/provider entry (those sit at 4+ spaces)
        out.append(f"  base_url: http://127.0.0.1:{port}/v1\n")
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

  # -- endpoint watchdog: if the ACTIVE model endpoint ever goes deaf
  #    (the 1 Nov outage: proxy /health green, upstreams dead, empty 200),
  #    fail model.base_url over to the healthy one and restart the gateway.
  local wd_src="$S/anti-refusal/endpoint_watchdog.py"
  if [[ -f "$wd_src" ]]; then
    cp "$wd_src" "$AR/endpoint_watchdog.py"
    mkdir -p "$HERMES_HOME/.config/systemd/user"
    cat > "$HERMES_HOME/.config/systemd/user/hermes-endpoint-watchdog.service" <<'UNIT'
[Unit]
Description=Hermes endpoint watchdog — model.base_url auto-failover
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=%h/.hermes/anti-refusal
Environment=PYTHONUNBUFFERED=1
ExecStart=/usr/bin/python3 %h/.hermes/anti-refusal/endpoint_watchdog.py
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
UNIT
    if systemctl --user daemon-reload 2>/dev/null; then
      systemctl --user enable hermes-endpoint-watchdog.service >/dev/null 2>&1 || true
      if systemctl --user restart hermes-endpoint-watchdog.service >/dev/null 2>&1; then
        ok "endpoint watchdog enabled (auto-failover model.base_url)"
      else
        warn "watchdog unit written but did not start"
      fi
    else
      warn "systemd --user unavailable — run anti-refusal/endpoint_watchdog.py manually"
    fi
  else
    warn "endpoint_watchdog.py missing from repo — watchdog skipped"
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

  # 3. harden the DEPLOYED config.yaml (existing configs are preserved by
  #    install_files, so normalize them here: pin the context-file cap so
  #    SOUL.md/MEMORY.md never truncate, force reasoning off).
  local cfg="$HERMES_HOME/config.yaml"
  if [[ $DRY_RUN -eq 0 && -f "$cfg" && -n "${PY_BIN:-}" ]]; then
    if "$PY_BIN" - "$cfg" <<'PYEOF' 2>/dev/null
import io, re, sys
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
orig = s
if re.search(r'(?m)^context_file_max_chars:', s):
    s = re.sub(r'(?m)^context_file_max_chars:.*$', 'context_file_max_chars: 400000', s)
else:
    s = 'context_file_max_chars: 400000\n' + s
s = re.sub(r'(?m)^([ \t]*)reasoning_effort:.*$', r'\1reasoning_effort: none', s)
s = re.sub(r'(?ms)^[ \t]*reasoning_overrides:\n(?:[ \t]+\S.*\n)*', '', s)
s = re.sub(r'(?m)^  show_reasoning:.*$', '  show_reasoning: false', s)
io.open(p, "w", encoding="utf-8").write(s) if s != orig else None
print("hardened" if s != orig else "already")
PYEOF
    then
      ok "deployed config.yaml hardened (context_file_max_chars=400000, reasoning_effort=none)"
    else
      warn "config hardening step failed — run: bash unrestricted.sh --stack-only"
    fi
  fi

  # 4. propagate HERMES_UNRESTRICTED=1 to the Hermes gateway service env
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

  # forbidden-host scan on the installed config (operator choice now wins)
  if grep -q "morku" "$cfg" 2>/dev/null; then
    warn "host 'morku' present in config — kept (operator choice)"
  else
    ok "no forbidden providers in config"
  fi

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
    if [[ "${patched:-0}" =~ ^[0-9]+$ ]] && [[ "$patched" -ge 22 ]]; then
      ok "guard kill verified ($patched guard files patched, all guards OFF)"
    else
      warn "guard kill incomplete ($patched files) -- re-run: bash unrestricted.sh"
    fi
  fi
  grep -q '^context_file_max_chars: 400000' "$HERMES_HOME/config.yaml" 2>/dev/null \
    && ok "context_file_max_chars=400000 (SOUL/MEMORY never truncated)" \
    || warn "context_file_max_chars not pinned — SOUL.md may truncate"
  grep -qE '^[[:space:]]*reasoning_effort: none' "$HERMES_HOME/config.yaml" 2>/dev/null \
    && ok "reasoning_effort: none (thinking disabled)" \
    || warn "reasoning_effort not 'none' — thinking may stay on"
  local ttr="$HERMES_HOME/hermes-agent/agent/turn_truncation.py"
  if [[ -f "$ttr" ]]; then
    grep -qF 'OPERATOR OVERRIDE (unrestricted build)' "$ttr" \
      && ok "provider refusal surface disabled (turn_truncation)" \
      || warn "content_filter refusal surface still active"
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
  printf "  upstream        : %s\n" "${SETUP_BASE_RESOLVED:-<preserved / unchanged>}"
  printf "  model default   : %s\n" "${SETUP_MODEL_CHOSEN:-<preserved / unchanged>}"
  case "${TELEGRAM_STATUS:-unknown}" in
    preserved) printf "  ${C_G}Telegram token  : PRESERVED${C_0}\n" ;;
    set)       printf "  ${C_G}Telegram token  : SET (validated via getMe)${C_0}\n" ;;
    missing)   printf "  ${C_Y}Telegram token  : MISSING — set in .env${C_0}\n" ;;
    skipped)   printf "  ${C_Y}Telegram token  : SKIPPED${C_0}\n" ;;
    *)         printf "  Telegram token  : not checked\n" ;;
  esac
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
    enabled)  printf "  ${C_G}Unrestricted    : ENABLED (all guards OFF + refusal surface killed + config hardened)${C_0}\n" ;;
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
  configure_upstream
  ensure_telegram_token
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
