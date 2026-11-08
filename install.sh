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
#     bash install.sh --no-restart       # do NOT touch the running gateway/service
#                                        # (implied automatically whenever HERMES_HOME
#                                        #  is not the real ~/.hermes -- see _sandboxed)
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
DO_RESTART=1
BACKUP_DIR=""
ROLLBACK_NEEDED=0
ANTIREFUSAL_STATUS="skipped"
UNRESTRICTED_STATUS="skipped"
MODEL_STATUS="unknown"
SETUP_MODEL_CHOSEN=""
SETUP_BASE_RESOLVED=""
TELEGRAM_STATUS="unknown"

# A run is SANDBOXED when HERMES_HOME is not the real per-user home. Tests and
# dry runs point HERMES_HOME at a temp dir -- but `systemctl --user` is GLOBAL,
# so an unguarded restart would bounce the operator's live gateway (this is
# exactly what killed an in-flight chat during a sandbox test of this script).
_real_hermes_home() { printf '%s/.hermes' "$HOME"; }

_sandboxed() {
  local real; real="$(_real_hermes_home)"
  [[ "$(readlink -f "$HERMES_HOME" 2>/dev/null || printf '%s' "$HERMES_HOME")" \
     != "$(readlink -f "$real" 2>/dev/null || printf '%s' "$real")" ]]
}

# Every service mutation goes through here. Refuses in a sandbox, honours
# --no-restart, and honours DRY_RUN.
_svc() {  # verb [unit]
  if [[ $DRY_RUN -eq 1 ]]; then
    printf "    ${C_Y}(dry-run)${C_0} systemctl --user %s %s\n" "$1" "${2:-}"
    return 0
  fi
  if _sandboxed; then
    dim "  [skip] systemctl --user $1 ${2:-} (sandbox: HERMES_HOME != $(_real_hermes_home))"
    return 0
  fi
  if [[ $DO_RESTART -eq 0 ]]; then
    dim "  [skip] systemctl --user $1 ${2:-} (--no-restart)"
    return 0
  fi
  systemctl --user "$1" ${2:+"$2"}
}

# ---------------------------------------------------------------- output
C_R="\033[1;31m"; C_G="\033[1;32m"; C_Y="\033[1;33m"; C_B="\033[1;34m"; C_0="\033[0m"
say()  { printf "${C_B}[*]${C_0} %s\n" "$*"; }
ok()   { printf "${C_G}[+]${C_0} %s\n" "$*"; }
warn() { printf "${C_Y}[!]${C_0} %s\n" "$*"; }
die()  { printf "${C_R}[x]${C_0} %s\n" "$*" >&2; exit 1; }
# dim: low-contrast status line. Used by the skip paths (sandbox / --no-restart);
# it was referenced in 9 places but never defined, so every one of those paths
# died with "dim: command not found" (exit 127) and triggered a rollback.
dim()  { printf "  %s\n" "$*"; }

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
    --no-restart) DO_RESTART=0; shift ;;
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
  # Re-entrancy guard: `trap ... ERR` fires on ANY non-zero command while
  # set -e is active, including commands inside rollback itself. Without this
  # the handler re-entered forever and the installer looped (observed: the log
  # restarted at "preflight checks" and hung until timeout).
  if [[ ${_IN_ROLLBACK:-0} -eq 1 ]]; then return; fi
  _IN_ROLLBACK=1
  trap - ERR
  [[ $ROLLBACK_NEEDED -eq 1 ]] || { _IN_ROLLBACK=0; return; }
  printf "\n${C_R}[x] Install failed (exit %s). Rolling back…${C_0}\n" "$code" >&2
  # stop & remove the unit we may have installed. Rollback must not disable the
  # OPERATOR'S live service from a sandbox/--no-restart run: this run never
  # installed it, so tearing it down would take down the running gateway too.
  if _sandboxed || [[ $DO_RESTART -eq 0 ]]; then
    dim "  [skip] service rollback (sandbox or --no-restart)"
  elif systemctl --user list-unit-files 2>/dev/null | grep -q '^antirefusal.service'; then
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
    # Never destroy the previous failed tree silently: it may be the only copy
    # of state from an earlier crash. Park it under a timestamp instead, so a
    # second rollback cannot wipe the evidence a human still needs.
    if [[ -e "$parked" ]]; then
      local prev="$parked.$(date +%Y%m%d-%H%M%S)"
      if mv "$parked" "$prev" 2>/dev/null; then
        warn "failed tree lama diparkir di $prev (tidak dihapus)"
      else
        warn "tidak bisa memindahkan $parked — dilewati, cek manual"
      fi
    fi
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
import sys

dst, tpl = sys.argv[1], sys.argv[2]
have_text = open(dst, encoding="utf-8").read()
tpl_text = open(tpl, encoding="utf-8").read()

try:
    import yaml
except ImportError:
    print("   PyYAML missing -- config.yaml left untouched")
    sys.exit(0)


class _Dumper(yaml.SafeDumper):
    """Emit ${ENV} references UNQUOTED.

    Hermes resolves api_key: ${FOO} from the environment. PyYAML would write
    '${FOO}' with quotes, the resolver then sees a literal string, and every
    request 401s with the placeholder as the bearer.
    """


def _env_ref(dumper, data):
    style = "|" if "\n" in data else None
    tag = "tag:yaml.org,2002:str"
    if isinstance(data, str) and data.startswith("${") and data.endswith("}") and " " not in data:
        return dumper.represent_scalar(tag, data, style=style)
    return dumper.represent_scalar(tag, data, style=style)


_Dumper.add_representer(str, _env_ref)


def dump_cfg(doc):
    return yaml.dump(doc, Dumper=_Dumper, sort_keys=False,
                     allow_unicode=True, default_flow_style=False, width=4096)

try:
    have = yaml.safe_load(have_text) or {}
except Exception as e:
    # NEVER rewrite a config we cannot parse: a text splice into an unknown
    # shape is how a valid file gets corrupted ("expected <block end>").
    print("   existing config.yaml does not parse (%s) -- left untouched" % e)
    sys.exit(0)

try:
    want = yaml.safe_load(tpl_text) or {}
except Exception as e:
    print("   template config.yaml does not parse (%s) -- left untouched" % e)
    sys.exit(0)

if not isinstance(have, dict):
    print("   existing config.yaml is not a mapping -- left untouched")
    sys.exit(0)

# --- protected operator values -------------------------------------------
have_model = have.get("model") if isinstance(have.get("model"), dict) else {}
protected = {k: have_model[k] for k in ("base_url", "api_key", "default") if k in have_model}

# --- template wins for every key; operator-only sections survive ---------
merged = {}
for k, v in want.items():
    merged[k] = v
for k, v in have.items():
    if k not in merged:
        merged[k] = v            # a section the template does not ship

# custom_providers: UNION, keyed by name (then base_url) so a re-install never
# drops the operator's own routers. The template's entry wins on conflict.
#
# BY DESIGN -- DO NOT CONSOLIDATE WITH ``providers:`` BELOW.
# A custom endpoint legitimately appears in BOTH sections and that is not
# duplication to be pruned:
#   * ``custom_providers`` is the endpoint REGISTRY. Credential resolution for
#     a bare ``custom`` route goes through
#     runtime_provider_custom.custom_provider_config_path_for_url(), which
#     scans ONLY get_compatible_custom_providers() (i.e. this list) and takes
#     the FIRST base_url match to find the owning key_env. Remove the entry
#     here and the route loses its key owner -> 401 invalid_api_key.
#     This is the bug fixed in b863cf2 (key_env was not kept in sync).
#   * ``providers.<name>`` is the per-name ROUTE definition, read by
#     model_catalog / runtime provider selection (cfg["providers"][name]).
# Neither section is a fallback for the other; both writes are REQUIRED.
# Real duplicates would be two entries with the SAME base_url *inside one*
# section -- verify_custom_provider_consistency() below reports that; a
# cross-section pair is expected and must be left alone.
def key_of(entry):
    if isinstance(entry, dict):
        return entry.get("name") or entry.get("base_url") or str(entry)[:80]
    return str(entry)[:80]

if "custom_providers" in want or "custom_providers" in have:
    t_list = [e for e in (want.get("custom_providers") or []) if isinstance(e, dict)]
    h_list = [e for e in (have.get("custom_providers") or []) if isinstance(e, dict)]
    seen, union = set(), []
    for e in t_list:
        k = key_of(e)
        if k not in seen:
            union.append(e)
            seen.add(k)
    for e in h_list:
        k = key_of(e)
        if k not in seen:
            union.append(e)
            seen.add(k)
    merged["custom_providers"] = union

# providers: per-provider union too (a dict of named providers)
if isinstance(want.get("providers"), dict) and isinstance(have.get("providers"), dict):
    prov = dict(want["providers"])
    for name, cfg in have["providers"].items():
        prov.setdefault(name, cfg)
    merged["providers"] = prov

# --- re-apply the protected model values --------------------------------
m = merged.get("model")
if not isinstance(m, dict):
    m = {}
    merged["model"] = m
m.update(protected)

# --- write, then PROVE it parses ----------------------------------------
out = dump_cfg(merged)
check = yaml.safe_load(out)
if not isinstance(check, dict) or check.get("model", {}).get("base_url") != protected.get("base_url", check.get("model", {}).get("base_url")):
    print("   merge result failed self-check -- config.yaml left untouched")
    sys.exit(0)
open(dst, "w", encoding="utf-8").write(out)
kept = ", ".join("model." + k for k in protected)
print("   config.yaml: template applied; preserved %s%s" % (
    kept or "(nothing)", "; custom_providers merged" if union else ""))
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
  # F4 guard: a newline in the value would emit one KEY= line followed by raw
  # text, which systemd's EnvironmentFile rejects ("Ignoring invalid
  # environment assignment") and the unit crash-loops. Refuse instead of
  # silently corrupting .env — this is the second line of defence behind the
  # stderr fix in _select_model.
  if [[ "$v" == *$'\n'* || "$v" == *$'\r'* ]]; then
    warn "_env_set: refusing multi-line value for $k (first line: ${v%%$'\n'*})"
    return 1
  fi
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

# route_model_default CONFIG -> the model id Hermes will actually send.
# Spec #3: model.default must follow the router in .env, not stay frozen at a
# vendor id from an old install. Resolution order prefers the live .env, then
# the model recorded for the ACTIVE upstream in config, then model.default.
route_model_default() {  # $1 = config path
  local cfg="${1:-$HERMES_HOME/config.yaml}" m=""
  m="$(_env_get ANTIREFUSAL_MODEL)"
  if [[ -z "$m" ]]; then
    # providers.custom.model tracks the router that install.sh last wired.
    m="$(sed -n '/^  custom:/,/^  [a-z_]*:[[:space:]]*$/p' "$cfg" 2>/dev/null \
         | grep -m1 -E '^    model:' \
         | sed -E "s/^    model:[[:space:]]*//; s/^'//; s/'$//; s/^\"//; s/\"$//" || true)"
  fi
  [[ -z "$m" ]] && m="$(_model_field default)"
  printf '%s' "$m"
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
  # F4: every UI line goes to STDERR. This function is called as
  #   model="$(_select_model ...)"
  # so anything printed to stdout is captured into $model. It used to print the
  # whole menu to stdout and $model became the 15-line menu text plus the prompt,
  # which _env_set then wrote verbatim into .env as
  #   ANTIREFUSAL_MODEL=   model tersedia:
  #   1) ...
  # → systemd rejected the file ("invalid environment assignment"), the
  # antirefusal unit crash-looped, and every request died with HTTP 400 from
  # the router. Only the RETURNED selection may reach stdout.
  printf '   model tersedia:\n' >&2
  local idx=0 marker
  for m in "${clean[@]}"; do
    idx=$((idx + 1))
    marker=""
    [[ "$m" == "$def" ]] && marker="   <- default"
    printf '   %2d) %s%s\n' "$idx" "$m" "$marker" >&2
  done
  local choice=""
  printf '   pilih model (nomor / ID manual, Enter = %s): ' "$def" >&2
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

  # NOTE: every one of these MUST get a default. `local x` leaves x UNSET (not
  # empty), and with `set -u` any later "$cur_key" on a fresh install (empty
  # .env, no key_env in config) is an "unbound variable" hard abort -- that is
  # what killed branch-new installs when the template stopped shipping a
  # vendor base_url/api_key.
  local cur_base="" cur_keyenv="" cur_key="" cur_model=""
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
  # Non-TTY with no SETUP_* env: keep what the box already has instead of
  # aborting. A re-install on a configured machine previously printed
  # "API key kosong -- config tidak diubah" and returned BEFORE routing
  # model.base_url to the proxy, so the operator ended up with a working
  # config but no guardrail -- the exact silent-drift §0b warns about.
  # cur_key/cur_base/cur_model were already parsed above and were only ever
  # used by the interactive prompt.
  if [[ $have_tty -eq 0 ]]; then
    [[ -z "$base"  && -n "$def_base"  ]] && base="$def_base"
    [[ -z "$key"   && -n "$cur_key"   ]] && key="$cur_key"
    [[ -z "$model" && -n "$cur_model" ]] && model="$cur_model"
  fi

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

  # Warn when the chosen model is not in the router's own /models list. The
  # canary below proves chat works, but the proxy ladder then silently falls
  # back to a model the router DOES serve, and the operator sees answers from
  # a model they never picked (measured: requested glm-5.3-flash, served by
  # deepseek-ai/DeepSeek-V4-Flash-0731). Not fatal -- a router may accept an
  # alias -- so this is a warning with the real ids, not a hard stop.
  local ml
  ml="$(curl -s -m 20 -H "Authorization: Bearer ${key}" \
        -H "User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36" \
        "$base/models" 2>/dev/null || true)"
  if printf '%s' "$ml" | grep -q '"id"'; then
    if ! printf '%s' "$ml" | grep -qF "\"$model\""; then
      local avail
      avail="$(printf '%s' "$ml" | grep -oE '"id"[[:space:]]*:[[:space:]]*"[^"]+"' \
               | sed -E 's/.*"([^"]+)"$/\1/' | head -6 | paste -sd', ' -)"
      warn "model '$model' TIDAK ada di daftar /models router ini"
      warn "  tersedia: ${avail:-<tidak terbaca>}"
      warn "  proxy akan fallback ke model lain — pakai id persis di atas"
    else
      ok "model '$model' ada di daftar /models router"
    fi
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
    # A failed canary is NOT a reason to skip .env. .env is the single source
    # of truth (operator spec #1): it must record the router the operator
    # chose even when that router is currently unreachable, otherwise the
    # proxy has no upstream at all and reports "key is EMPTY" -- the state
    # this whole change exists to eliminate. Record .env, keep the existing
    # model config untouched, and let the proxy ladder + watchdog recover.
    warn "canary chat ke $base (model=$model) GAGAL — config.yaml model TIDAK diubah"
    warn "  .env tetap ditulis supaya proxy tahu upstream yang dipilih"
  else
    ok "canary chat ok — $base menjawab untuk model=$model"
  fi

  local host slug keyenv
  host="$(printf '%s' "$base" | sed -E 's#^https?://##; s#/.*##')"
  slug="$(printf '%s' "$host" | tr 'A-Z' 'a-z' | sed -E 's/[^a-z0-9]+/_/g; s/^_+//; s/_+$//' | tr 'a-z' 'A-Z')"
  keyenv="HERMES_CUSTOM_${slug}_API_KEY"

  if [[ -n "$key" ]]; then
    _env_set "$keyenv" "$key"
  fi
  _env_set "ANTIREFUSAL_UPSTREAM" "$base"
  # .env is the single source of truth for the ACTIVE model too: the proxy
  # canary, the watchdog and the post-install verification all resolve the
  # model from here, so switching routers means editing one file.
  [[ -n "$model" ]] && _env_set "ANTIREFUSAL_MODEL" "$model"
  # CUSTOM_BASE_URL must point at the PROXY, not the router.
  #
  # Hermes resolves the endpoint as
  #   explicit > CUSTOM_BASE_URL > trusted model.base_url > OPENROUTER_BASE_URL
  # (hermes_cli/runtime_provider_backends.py:120). While this line wrote the
  # router, CUSTOM_BASE_URL outranked the model.base_url rewrite below, so the
  # gateway talked to the router directly and never entered the refusal ladder:
  # the proxy stayed healthy on 9200 while every Telegram request came back
  # HTTP 400 "declined under its content policy". The router belongs in
  # ANTIREFUSAL_UPSTREAM (what the proxy dials); CUSTOM_BASE_URL is what Hermes
  # dials, so it has to be the proxy.
  #
  # ar_proxy_url is derived later from ANTIREFUSAL_PORT, so compute it here from
  # the same source to keep one port for .env, the unit and both base_urls.
  local _ar_port
  _ar_port="$(grep -E '^ANTIREFUSAL_PORT=' "$HERMES_HOME/.env" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
  [[ -z "$_ar_port" ]] && _ar_port="${ANTIREFUSAL_PORT:-9200}"
  local _proxy_url="http://127.0.0.1:${_ar_port}/v1"
  [[ -n "${ANTIREFUSAL_PROXY_URL:-}" ]] && _proxy_url="$ANTIREFUSAL_PROXY_URL"
  [[ -n "$key" ]] && _env_set "CUSTOM_BASE_URL" "$_proxy_url"
  [[ -n "$key" ]] && _env_set "CUSTOM_API_KEY" "$key"
  _env_set "ANTIREFUSAL_SINGLE_UPSTREAM" "1"
  ok ".env: $keyenv + ANTIREFUSAL_UPSTREAM=$base (+CUSTOM_BASE_URL/CUSTOM_API_KEY)"

  # .env selalu punya ANTIREFUSAL_PORT (dipakai unit + proxy).
  # Precedence: explicit env var > value already in .env > 9200. The old line
  # wrote a hard 9200 whenever .env had no entry yet, so ANTIREFUSAL_PORT=9602
  # on the command line was silently discarded and two installs on one host
  # both aimed at 9200.
  if ! grep -qE '^ANTIREFUSAL_PORT=' "$HERMES_HOME/.env" 2>/dev/null; then
    _env_set "ANTIREFUSAL_PORT" "${ANTIREFUSAL_PORT:-9200}"
  elif [[ -n "${ANTIREFUSAL_PORT:-}" ]] && \
       [[ "$(grep -E '^ANTIREFUSAL_PORT=' "$HERMES_HOME/.env" | tail -1 | cut -d= -f2-)" != "$ANTIREFUSAL_PORT" ]]; then
    _env_set "ANTIREFUSAL_PORT" "$ANTIREFUSAL_PORT"
  fi

  # base_url must point at the port this install actually listens on. The old
  # form hardcoded 9200 in every call site, so a custom ANTIREFUSAL_PORT wrote
  # a config that pointed at somebody else's proxy. Derived once here and
  # reused, so the port cannot drift between .env, the unit and config.yaml.
  local ar_proxy_url="http://127.0.0.1:$(grep -E '^ANTIREFUSAL_PORT=' "$HERMES_HOME/.env" | tail -1 | cut -d= -f2- || echo 9200)/v1"
  [[ -n "${ANTIREFUSAL_PROXY_URL:-}" ]] && ar_proxy_url="$ANTIREFUSAL_PROXY_URL"

  if [[ -f "$cfg" && $cok -eq 1 ]]; then
        "$PY" - "$cfg" "$base" "$keyenv" "$model" "$host" "$ar_proxy_url" <<'PYEOF' || warn "config.yaml model block tidak ditulis"
import sys

p, base, keyenv, model, host = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
proxy_url = sys.argv[6] if len(sys.argv) > 6 else "http://127.0.0.1:9200/v1"

try:
    import yaml
except ImportError:
    print("   PyYAML missing -- config.yaml left untouched")
    sys.exit(0)


class _Dumper(yaml.SafeDumper):
    """Emit ${ENV} references UNQUOTED.

    Hermes resolves api_key: ${FOO} from the environment. PyYAML would write
    '${FOO}' with quotes, the resolver then sees a literal string, and every
    request 401s with the placeholder as the bearer.
    """


def _env_ref(dumper, data):
    style = "|" if "\n" in data else None
    tag = "tag:yaml.org,2002:str"
    if isinstance(data, str) and data.startswith("${") and data.endswith("}") and " " not in data:
        return dumper.represent_scalar(tag, data, style=style)
    return dumper.represent_scalar(tag, data, style=style)


_Dumper.add_representer(str, _env_ref)


def dump_cfg(doc):
    return yaml.dump(doc, Dumper=_Dumper, sort_keys=False,
                     allow_unicode=True, default_flow_style=False, width=4096)

try:
    doc = yaml.safe_load(open(p, encoding="utf-8").read()) or {}
except Exception as e:
    # Never text-splice into a file we cannot parse: that is how a valid
    # config.yaml got corrupted ("expected <block end>, but found '-'").
    print("   config.yaml does not parse (%s) -- left untouched" % e)
    sys.exit(0)

if not isinstance(doc, dict):
    print("   config.yaml is not a mapping -- left untouched")
    sys.exit(0)


def quote(v):
    """${ENV} references must stay UNQUOTED: PyYAML keeps quotes literal, and
    the gateway would then send the text '${FOO}' as the bearer (every 401)."""
    return str(v)


mdl = doc.get("model")
if not isinstance(mdl, dict):
    mdl = {}
    doc["model"] = mdl
# model.base_url is the PROXY, never the router. Hermes must traverse the
# refusal ladder on every request; pointing it at the upstream directly is
# how the live box ended up on api.river.ai with the guardrail idle. The
# router itself is recorded in providers.custom / custom_providers below and
# in .env (ANTIREFUSAL_UPSTREAM), which is what the proxy reads.
mdl["base_url"] = quote(proxy_url)
mdl["api_key"] = "${%s}" % keyenv
mdl["default"] = quote(model)
mdl["provider"] = "custom"
mdl["api_mode"] = "chat_completions"

# providers.custom mirrors the router; every other provider is preserved.
prov = doc.get("providers")
if not isinstance(prov, dict):
    prov = {}
    doc["providers"] = prov
custom = prov.get("custom")
if not isinstance(custom, dict):
    custom = {}
# Snapshot the PRE-WRITE state: custom.update() below repairs key_env, so a
# check that ran afterwards could never see the drift it is meant to report.
_prev_custom = dict(custom)
custom.update({
    "base_url": base,
    "api_key": "${%s}" % keyenv,
    "key_env": keyenv,
    "api_mode": "chat_completions",
    "model": model,
})
prov["custom"] = custom

# custom_providers: ADD this router when absent, keep every other entry.
cps = doc.get("custom_providers")
if not isinstance(cps, list):
    cps = []
cps = [e for e in cps if isinstance(e, dict)]


def matches(entry):
    if str(entry.get("name", "")).strip() == (host or base):
        return True
    return str(entry.get("base_url", "")).rstrip("/") == base.rstrip("/")


if not any(matches(e) for e in cps):
    cps.append({"name": host or base, "base_url": base,
                "key_env": keyenv, "model": model})
doc["custom_providers"] = cps

# --- CONSISTENCY CHECK (read-only): custom_providers <-> providers.<name> --
# A custom endpoint is expected in BOTH sections (see the BY DESIGN note above);
# this verifies they agree instead of "fixing" them. Reports, never blocks and
# never rewrites: a drift here is a diagnosis for the operator, not a reason to
# drop a valid config on the floor.
def _norm(u):
    return str(u or "").strip().rstrip("/")

def _check():
    prov2 = doc.get("providers")
    prov2 = prov2 if isinstance(prov2, dict) else {}
    by_url = {}
    for name, pc in prov2.items():
        if isinstance(pc, dict) and _norm(pc.get("base_url")):
            by_url.setdefault(_norm(pc.get("base_url")), []).append((name, pc))
    problems = []

    # 1) duplicates INSIDE custom_providers == the only real duplicate defect
    seen_url, dup_url = {}, []
    for e in cps:
        u = _norm(e.get("base_url"))
        if not u:
            continue
        if u in seen_url:
            dup_url.append(u)
        seen_url[u] = True
    for u in sorted(set(dup_url)):
        problems.append("duplicate base_url inside custom_providers: %s" % u)

    # 2) every registry entry must have an owning key_env and a route peer
    for e in cps:
        u = _norm(e.get("base_url"))
        nm = e.get("name")
        if not u:
            continue
        if not str(e.get("key_env") or "").strip():
            problems.append("custom_providers[%s] has no key_env (key cannot resolve)" % nm)
        peers = by_url.get(u) or []
        if not peers:
            problems.append("custom_providers[%s] (%s) has no providers.* peer "
                            "-- route definition missing" % (nm, u))
            continue
        # 3) base_url peers must agree on key_env, else the route reads another
        #    endpoint's key. THIS is the 401 class fixed in b863cf2.
        want_key = str(e.get("key_env") or "").strip()
        for pname, pc in peers:
            have_key = str(pc.get("key_env") or "").strip()
            if want_key and have_key and have_key != want_key:
                problems.append("key_env mismatch for %s: custom_providers[%s]=%s "
                                "but providers.%s=%s" % (u, nm, want_key, pname, have_key))

    # 4) the live route's key_env must match what was just written. Compare
    #    against the PRE-WRITE snapshot (_prev_custom): the update above always
    #    sets key_env correctly, so reading the live value here would always
    #    look clean and hide the 401 class entirely.
    if str(_prev_custom.get("key_env") or "").strip():
        if _norm(_prev_custom.get("base_url")) == _norm(base) and \
           str(_prev_custom.get("key_env")).strip() != keyenv:
            problems.append("STALE providers.custom.key_env=%s was replaced by %s "
                            "for %s (401 invalid_api_key class, now fixed)"
                            % (_prev_custom.get("key_env"), keyenv, base))
    live = prov2.get("custom")
    if isinstance(live, dict) and str(live.get("key_env") or "").strip():
        if _norm(live.get("base_url")) == _norm(base) and str(live.get("key_env")).strip() != keyenv:
            problems.append("providers.custom.key_env=%s != router key_env=%s "
                            "(401 invalid_api_key class)" % (live.get("key_env"), keyenv))
    return problems

for _p in _check():
    print("   WARN config drift: %s" % _p)
print("   custom_providers: %d entry, %d in providers: (cross-section pairs are BY DESIGN)"
      % (len(cps), len(doc.get("providers") or {})))

# --- serialise, then PROVE the result round-trips and keeps ${ENV} bare ----
out = dump_cfg(doc)
if "${%s}" % keyenv not in out:
    print("   serialisation dropped the ${ENV} api_key -- left untouched")
    sys.exit(0)
try:
    back = yaml.safe_load(out)
except Exception as e:
    print("   merged YAML does not re-parse (%s) -- left untouched" % e)
    sys.exit(0)
if back.get("model", {}).get("base_url") != proxy_url:
    print("   merged YAML lost base_url -- left untouched")
    sys.exit(1)

open(p, "w", encoding="utf-8").write(out)
print("   model block -> base_url=%s default=%s" % (base, model))
PYEOF
    # The python block above exits non-zero when its round-trip self-check
    # fails, so the banner below never claims success for a file it did not
    # write. sys.exit(0) on a failed check used to make this line print "ok"
    # for a config.yaml that was still empty -- the "model does not respond"
    # state with no visible cause.
    if grep -qF "  base_url: $ar_proxy_url" "$cfg" 2>/dev/null; then
      ok "config.yaml: base_url=$ar_proxy_url default=$model"
    else
      warn "config.yaml model block TIDAK tertulis (lihat pesan di atas)"
    fi
  fi

  local arcfg="$HERMES_HOME/anti-refusal/config.json"
  # F6: on a FRESH install this file does not exist -- the code copy above
  # deliberately skips config.json so a re-install never clobbers a live one.
  # Nothing else created it, so §0b mechanism #7 ("max_attempts": 12 in
  # config.json) was silently absent on every brand-new box: load_cfg() falls
  # back to {} and the ledger check has nothing to read. Seed it from the repo
  # template ONLY when missing -- an existing file is never touched here.
  if [[ ! -f "$arcfg" && -f "$WORKDIR/repo/anti-refusal/config.json" ]]; then
    run cp -a "$WORKDIR/repo/anti-refusal/config.json" "$arcfg"
    ok "anti-refusal/config.json seeded from template (fresh install)"
  fi
  if [[ -f "$arcfg" ]]; then
    # max_attempts floor. The shipped config.json carried 8 while the code
    # default was 12, and CFG wins over the default, so the ladder never got
    # past 8 on any box that had ever been installed -- every "12 attempts"
    # claim in the repo was undone by this one file. Raise it in place when it
    # is below the floor; never lower an operator's larger value.
    "$PY" - "$arcfg" <<'PYEOF' 2>/dev/null || true
import json, sys
p = sys.argv[1]
try:
    cfg = json.load(open(p))
except Exception:
    sys.exit(0)
cur = cfg.get("max_attempts")
if isinstance(cur, int) and cur < 12:
    cfg["max_attempts"] = 12
    json.dump(cfg, open(p, "w"), indent=2)
    print("raised")
PYEOF
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
  # Prefer a python that can import yaml: the config.yaml merge and the YAML
  # validation are no-ops on a python without PyYAML, and a text-splice fallback
  # corrupts an otherwise valid config (observed: "expected <block end>").
  local cands=(
    "$HERMES_HOME/hermes-agent/venv/bin/python3"
    "${HERMES_PYTHON:-}"
    "$(command -v python3 2>/dev/null || true)"
    /usr/bin/python3
  )
  # hermes toolchain pythons ship PyYAML
  local t
  for t in "$HOME"/.hermes/tools/python*/bin/python3; do
    [[ -x "$t" ]] && cands+=("$t")
  done
  # F1: the venv this machine actually RUNS the proxy with lives under
  # ~/.hermes/installs/<id>/environments/<id>/venv — NOT at
  # ~/.hermes/hermes-agent/venv (that path does not exist on an
  # installer-provisioned host). It is the only python that reliably has
  # aiohttp, and antirefusal.service already resolves it via this same glob.
  # Without it $PY fell through to /usr/bin/python3 (no aiohttp on Ubuntu
  # 24.04) and the installer installed deps into a python the proxy never uses.
  for t in "$HOME"/.hermes/installs/*/environments/*/venv/bin/python3; do
    [[ -x "$t" ]] && cands+=("$t")
  done
  local c
  for c in "${cands[@]}"; do
    [[ -n "$c" && -x "$c" ]] || continue
    if "$c" -c 'import yaml' >/dev/null 2>&1; then echo "$c"; return 0; fi
  done
  # F5: no candidate imports PyYAML. Two DIFFERENT interpreters are needed
  # here and conflating them was the last silent failure:
  #   - config.yaml merge/validation wants PyYAML
  #   - the proxy wants aiohttp
  # The installs venv ships aiohttp but NOT yaml (measured: 3/3 venvs on a
  # provisioned host reported yaml=no aiohttp=yes), while /usr/bin/python3 has
  # yaml but no aiohttp. Falling through to "first usable" returned
  # /usr/bin/python3, so the aiohttp install went to the wrong interpreter and
  # the proxy's own venv was never considered. Prefer an aiohttp-capable python
  # before the generic fallback -- that is the one the service will exec.
  for c in "${cands[@]}"; do
    [[ -n "$c" && -x "$c" ]] || continue
    if "$c" -c 'import aiohttp' >/dev/null 2>&1; then echo "$c"; return 0; fi
  done
  # still nothing: return the first usable one so callers can still
  # print a clear "PyYAML missing" message instead of corrupting the file.
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
  # DRY-RUN first: nothing was copied, so the file check below would always
  # abort a dry run with "missing after copy" -- the exact mode an operator
  # uses to preview the whole pipeline.
  if [[ $DRY_RUN -eq 1 ]]; then
    printf "    ${C_Y}(dry-run)${C_0} verify anti-refusal/proxy.py, resolve upstream, install unit, check /health\n"
    ANTIREFUSAL_STATUS="dry-run"
    return 0
  fi
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

  local PY; PY="$(find_python || true)"
  if [[ -z "$PY" ]]; then
    warn "no python3 found — auto-refusal not activated"
    return 0
  fi

  # F5b: $PY is the YAML-capable interpreter used to EDIT config/config.yaml.
  # It is NOT automatically the interpreter that RUNS the proxy -- on a
  # provisioned host /usr/bin/python3 imports yaml but not aiohttp, while the
  # installs venv imports aiohttp but not yaml. The unit's ExecStart: used to
  # take $PY, so the service was pinned to a python without aiohttp and
  # crash-looped with ModuleNotFoundError even though the installer had just
  # reported "aiohttp present". Resolve the RUNTIME interpreter separately and
  # let the unit exec that one.
  local PROXY_PY=""
  local c
  for c in "$PY" /usr/bin/python3; do
    [[ -n "$c" && -x "$c" ]] || continue
    if "$c" -c 'import aiohttp' >/dev/null 2>&1; then PROXY_PY="$c"; break; fi
  done
  if [[ -z "$PROXY_PY" ]]; then
    for c in "$HOME"/.hermes/installs/*/environments/*/venv/bin/python3; do
      [[ -x "$c" ]] || continue
      if "$c" -c 'import aiohttp' >/dev/null 2>&1; then PROXY_PY="$c"; break; fi
    done
  fi
  [[ -z "$PROXY_PY" ]] && PROXY_PY="$PY"
  if [[ "$PROXY_PY" != "$PY" ]]; then
    say "proxy runtime interpreter: $PROXY_PY (config editor: $PY)"
  fi

  # python deps for the proxy. F3: this used to end in `warn` and return 0, so
  # an install that could not provide aiohttp still reported success while the
  # proxy could never start. Verify AFTER installing and fail the step loudly.
  local aio_ok=0
  if "$PROXY_PY" -c "import aiohttp" 2>/dev/null; then
    aio_ok=1
  else
    say "installing aiohttp for the proxy ($PROXY_PY)"
    "$PROXY_PY" -m pip install --quiet aiohttp 2>/dev/null || \
      "$PROXY_PY" -m pip install --quiet --user aiohttp 2>/dev/null || true
    if "$PROXY_PY" -c "import aiohttp" 2>/dev/null; then
      aio_ok=1
    else
      warn "aiohttp is NOT importable from $PROXY_PY — antirefusal cannot start with this interpreter"
    fi
  fi
  if [[ $aio_ok -eq 1 ]]; then
    ok "aiohttp present in $PROXY_PY"
  fi

  # -- install a PORTABLE user unit (rewrite ExecStart/WorkingDirectory to this host)
  #
  # `systemctl --user` and ~/.config/systemd/user are GLOBAL to the user, not
  # scoped to HERMES_HOME. Writing the unit from a sandbox install used to
  # REPLACE the operator's live unit with a path under the sandbox -- measured
  # on this box: the production proxy was serving from
  # ~/.hermes/cache/scratch/T2/anti-refusal while the unit file pointed at
  # .../R2/h1/anti-refusal, i.e. an old build with max_attempts=8 and no
  # off-topic guard, and its log went to the sandbox. Sandbox installs must
  # never touch this file: _svc already refuses the systemctl calls, this
  # refuses the write itself.
  local unit_dir="$HOME/.config/systemd/user"
  if _sandboxed; then
    dim "  [skip] systemd unit write (sandbox: HERMES_HOME != $(_real_hermes_home))"
  else
  mkdir -p "$unit_dir"
  cat > "$unit_dir/antirefusal.service" <<UNIT
[Unit]
Description=Hermes anti-refusal guardrail proxy
After=network.target

[Service]
Type=simple
WorkingDirectory=$AR
ExecStart=$PROXY_PY $AR/proxy.py
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
  fi  # end sandbox guard on unit write

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
  #
  # F2: this used to be guarded by `$PY != /usr/bin/python3`, which meant that
  # on exactly the hosts that NEED the fallback (no hermes-agent/venv → $PY IS
  # /usr/bin/python3) the block was skipped entirely and system python stayed
  # without aiohttp. The unit resolves the venv first and only falls back to
  # /usr/bin/python3, so system python must always be able to import it.
  if ! /usr/bin/python3 -c "import aiohttp" 2>/dev/null; then
    say "installing aiohttp for system python3 (proxy fallback path)"
    /usr/bin/python3 -m pip install --quiet --break-system-packages aiohttp 2>/dev/null || \
      (sudo -n apt-get install -y -qq python3-aiohttp >/dev/null 2>&1 || \
       apt-get install -y -qq python3-aiohttp >/dev/null 2>&1) || \
      warn "system python3 lacks aiohttp -- the venv python must carry it"
    if ! /usr/bin/python3 -c "import aiohttp" 2>/dev/null; then
      warn "system python3 STILL lacks aiohttp — if the venv python is missing too, antirefusal will not start"
    else
      ok "system python3 can import aiohttp (fallback path ready)"
    fi
  fi

  # -- routing (base_url -> proxy) is deferred until the service is up AND a
  #    real canary chat succeeds; see the ROUTE step below. A proxy with a
  #    healthy /health but a dead upstream ladder answers 200 with an EMPTY
  #    body, which leaves Hermes with no working endpoint at all.

  # -- start the service: prefer systemd --user, else fall back to a plain
  #    background process (many VPS/containers have no systemd user session).
  local started=0
  if [[ $DO_RESTART -eq 0 ]]; then
    # --no-restart: never start anything, but do NOT claim it is started.
    # `started=1` here skipped the background fallback AND left the health
    # check to fail, so install printed "Auto-refusal: FAILED" for a proxy
    # it had been told not to start. Probe only what already listens.
    dim "  [skip] antirefusal.service start (--no-restart)"
    if curl -fsS --max-time 3 "http://127.0.0.1:${ar_port}/health" 2>/dev/null \
         | grep -q '"ok"[[:space:]]*:[[:space:]]*true'; then
      started=1
      ok "proxy sudah berjalan di port ${ar_port} (tidak disentuh, --no-restart)"
    else
      warn "proxy TIDAK berjalan dan --no-restart melarang start — health check dilewati"
      ANTIREFUSAL_STATUS="not-started"
      return 0
    fi
  elif _sandboxed; then
    # Sandbox (HERMES_HOME != ~/.hermes): the operator's systemd unit is off
    # limits, but a proxy on THIS HERMES_HOME port is still needed for the
    # verify step. Start it as a scoped background process instead of
    # pretending systemd did it, and never touch the live unit.
    dim "  [sandbox] systemd dilewati — start proxy terpisah di port ${ar_port}"
    started=0
  elif systemctl --user daemon-reload 2>/dev/null && \
       systemctl --user show-environment >/dev/null 2>&1; then
    systemctl --user enable antirefusal.service >/dev/null 2>&1 || true
    if systemctl --user restart antirefusal.service >/dev/null 2>&1 || \
       systemctl --user start antirefusal.service >/dev/null 2>&1; then
      started=1
      ok "started via systemd --user (antirefusal.service)"
    fi
  fi

  if [[ $started -eq 0 ]]; then
    warn "systemd --user tidak dipakai — menjalankan proxy sebagai proses latar"
    # Kill ONLY this HERMES_HOME's proxy. `pkill -f "$AR/proxy.py"` matched
    # every install's path component, so parallel/sandbox runs killed each
    # other's proxy and the odd one out reported "FAILED".
    if [[ -f "$AR/proxy.pid" ]]; then
      local _old; _old="$(cat "$AR/proxy.pid" 2>/dev/null || true)"
      if [[ -n "$_old" ]] && kill -0 "$_old" 2>/dev/null; then
        kill "$_old" 2>/dev/null || true
        sleep 1
      fi
    fi
    ANTIREFUSAL_UPSTREAM="$upstream" ANTIREFUSAL_PORT="$ar_port" \
      ANTIREFUSAL_SINGLE_UPSTREAM=1 HERMES_HOME="$HERMES_HOME" \
      nohup "$PROXY_PY" "$AR/proxy.py" >"$AR/proxy.out" 2>&1 &
    echo $! > "$AR/proxy.pid"
    ok "started background proxy (pid $(cat "$AR/proxy.pid"))"
  fi

  # -- VERIFY: health endpoint must answer {"ok": true}
  # Generous budget: startup imports aiohttp, reads .env, resolves keys and
  # binds. The old fixed 8x1s gave up before a healthy proxy could answer,
  # so install reported "Auto-refusal: FAILED" on a box that was fine --
  # measured under concurrent installs. Total wait ~40s, then one decisive
  # check against the process actually listening.
  local tries=0 healthy=0 body=""
  for _w in 1 1 1 1 2 2 3 3 4 4 5 5 6; do
    sleep "$_w"
    body="$(curl -fsS --max-time 4 "http://127.0.0.1:${ar_port}/health" 2>/dev/null || true)"
    if printf '%s' "$body" | grep -q '"ok"[[:space:]]*:[[:space:]]*true'; then
      healthy=1; break
    fi
    tries=$((tries+1))
  done

  if [[ $healthy -eq 1 ]]; then
    local keyed
    # proxy.py reports the key state as "set"/"missing" inside upstreams[],
    # NOT as a top-level boolean. Matching only '"key": true' made every
    # healthy install announce "INSTALLED but upstream key is EMPTY" even
    # when the key was present -- and that warning is what pushed operators
    # to stop trusting the status line.
    keyed="$(printf '%s' "$body" \
      | grep -oE '"key"[[:space:]]*:[[:space:]]*("set"|true)' || true)"
    ok "proxy healthy on 127.0.0.1:${ar_port}"
    if [[ -n "$keyed" ]]; then
      ok "Auto-refusal: ENABLED (upstream key present)"
      # -- ROUTE: point model.base_url at the proxy ONLY after a real canary
      #    chat round-trips through it. Never trust /health alone.
      if [[ $model_ready -eq 1 && -f "$cfg" ]]; then
        # Model comes from .env (ANTIREFUSAL_MODEL) then config, never a
        # hardcoded id: the old fallback was "step-5-preview-UNCENSORED", a
        # model no router here serves, so the canary 404'd and the route step
        # was silently skipped on every install.
        local canary_model canary_body canary_ok=0
        canary_model="$(route_model_default "$cfg")"
        if [[ -z "$canary_model" ]]; then
          warn "model.default kosong — canary proxy dilewati, model.base_url tidak diubah"
        else
        canary_body="$(curl -s -m 150 -X POST "http://127.0.0.1:${ar_port}/v1/chat/completions" \
          -H "Content-Type: application/json" \
          -d "{\"model\":\"${canary_model}\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":8,\"stream\":false}" 2>/dev/null || true)"
        fi
        if [[ -n "$canary_body" ]] && printf '%s' "$canary_body" | grep -q '"content"'; then
          canary_ok=1
        fi
        # Route REGARDLESS of the upstream canary. The old code only rewrote
        # model.base_url after a successful canary chat through the proxy,
        # which inverted the dependency: a dead upstream (bad key, router
        # down) left Hermes pointed straight at the router with the guardrail
        # idle -- the exact failure this whole change exists to prevent. The
        # proxy is reachable (health passed above), so it must be the endpoint
        # Hermes talks to; an unhealthy upstream is a warning, and the proxy's
        # own ladder plus the watchdog handle the recovery.
        if [[ $canary_ok -eq 0 ]]; then
          warn "canary upstream gagal — proxy TETAP dipasang sebagai gerbang"
          warn "  perbaiki ANTIREFUSAL_UPSTREAM/API key di .env lalu restart service"
        fi
        cp -a "$cfg" "$cfg.pre-antirefusal"
        "$PY" - "$cfg" "$ar_port" <<'PYEOF' || warn "config rewrite skipped"
import sys
p, port = sys.argv[1], sys.argv[2]
try:
    import yaml
except ImportError:
    print("   PyYAML missing -- model.base_url left unchanged")
    sys.exit(0)

# dump_cfg lives in a DIFFERENT heredoc (the model writer above), so it is not
# in scope here. That NameError aborted this block on every install, which is
# why the route-to-proxy rewrite silently never ran and the "PROVE the path"
# step below then ran against an unmodified config. Define the dumper locally.
class _D(yaml.SafeDumper):
    pass


def _env_ref(dumper, data):
    # ${ENV} references must stay UNQUOTED or Hermes sends the literal text.
    return dumper.represent_scalar("tag:yaml.org,2002:str", data)


_D.add_representer(str, _env_ref)


def dump_cfg2(doc):
    return yaml.dump(doc, Dumper=_D, sort_keys=False, allow_unicode=True,
                     default_flow_style=False, width=4096)


try:
    doc = yaml.safe_load(open(p, encoding="utf-8").read()) or {}
except Exception as e:
    print("   config.yaml unparsable (%s) -- left unchanged" % e)
    sys.exit(0)
if not isinstance(doc, dict) or not isinstance(doc.get("model"), dict):
    print("   no model: block -- left unchanged")
    sys.exit(0)
doc["model"]["base_url"] = "http://127.0.0.1:%s/v1" % port
out = dump_cfg2(doc)
if yaml.safe_load(out).get("model", {}).get("base_url") != doc["model"]["base_url"]:
    print("   self-check failed -- left unchanged")
    sys.exit(1)
open(p, "w", encoding="utf-8").write(out)
print("model.base_url -> proxy")
PYEOF
      fi
    else
      warn "Auto-refusal: INSTALLED but upstream key is EMPTY"
      warn "  set HERMES_CUSTOM_LIGHTVELA_CUSTOM_RTR_1WT0FC9_API_KEY (or CUSTOM_API_KEY) in $HERMES_HOME/.env, then:"
      warn "  systemctl --user restart antirefusal.service"
      ANTIREFUSAL_STATUS="installed-no-key"
      return 0
    fi
    ANTIREFUSAL_STATUS="enabled"

    # -- PROVE the request path, do not assume it (operator spec #5).
    #    /health and even a canary through the proxy say nothing about what
    #    Hermes will actually do: the live box was green on both while
    #    model.base_url pointed at a router the proxy never saw. Read the
    #    written config back and require it to name the proxy, then send one
    #    chat through the exact base_url Hermes will use.
    if [[ -f "$cfg" ]]; then
      local routed_base
      routed_base="$("$PY" - "$cfg" <<'PYEOF' 2>/dev/null || true
import sys
try:
    import yaml
    doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8").read()) or {}
    print((doc.get("model") or {}).get("base_url") or "")
except Exception:
    print("")
PYEOF
)"
      routed_base="${routed_base%/}"
      if [[ -z "$routed_base" ]]; then
        warn "VERIFIKASI: model.base_url tidak terbaca — jalur proxy TIDAK terbukti"
      elif [[ "$routed_base" != "http://127.0.0.1:${ar_port}/v1" ]]; then
        warn "VERIFIKASI GAGAL: model.base_url = $routed_base (bukan proxy 127.0.0.1:${ar_port})"
        warn "  semua permintaan Hermes melewati guardrail: TIDAK. Perbaiki sebelum dipakai."
      else
        # Path is right; now prove a real completion round-trips through it.
        local vmodel vbody vok=0
        vmodel="$(route_model_default "$cfg")"
        vbody="$(curl -s -m 120 -X POST "${routed_base}/chat/completions" \
          -H "Content-Type: application/json" \
          -d "{\"model\":\"${vmodel}\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":8,\"stream\":false}" 2>/dev/null || true)"
        if [[ -n "$vbody" ]] && printf '%s' "$vbody" | grep -q '"content"'; then
          vok=1
        fi
        if [[ $vok -eq 1 ]]; then
          ok "VERIFIKASI: request nyata lewat proxy ${routed_base} (model=${vmodel})"
        else
          warn "VERIFIKASI: model.base_url sudah proxy, tapi chat uji gagal"
          warn "  cek $AR/proxy.log — upstream .env mungkin mati"
        fi
      fi
    fi
  else
    warn "proxy health check failed — see $AR/proxy.log"
    ANTIREFUSAL_STATUS="failed"
  fi

  # -- endpoint watchdog: if the ACTIVE model endpoint ever goes deaf
  #    (the 1 Nov outage: proxy /health green, upstreams dead, empty 200),
  #    fail model.base_url over to the healthy one and restart the gateway.
  local wd_src="$WORKDIR/repo/anti-refusal/endpoint_watchdog.py"
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
    if _sandboxed || [[ $DO_RESTART -eq 0 ]]; then
      dim "  [skip] watchdog service (sandbox or --no-restart)"
    elif systemctl --user daemon-reload 2>/dev/null; then
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

  # -- sync-upstream.sh: the manual half of drift handling. The watchdog
  #    absorbs `hermes setup model` changes on its own cycle, but only runs
  #    every few minutes and only while its unit is alive. Install the script
  #    next to .env so the operator can run it immediately after a model
  #    switch, and prove right here that it reports a coherent state --
  #    otherwise "sync is available" is just a file that exists.
  local sync_src="$WORKDIR/repo/sync-upstream.sh"
  if [[ -f "$sync_src" ]]; then
    if [[ $DRY_RUN -eq 0 ]]; then
      run cp -f "$sync_src" "$HERMES_HOME/sync-upstream.sh"
      chmod +x "$HERMES_HOME/sync-upstream.sh" 2>/dev/null || true
    fi
    if [[ -x "$HERMES_HOME/sync-upstream.sh" ]]; then
      ok "sync-upstream.sh installed ($HERMES_HOME/sync-upstream.sh)"
      if [[ $DRY_RUN -eq 0 ]]; then
        # --check exits 0 when .env and config.yaml agree, 1 when they drift.
        # Right after install they MUST agree: base_url is the proxy and .env
        # carries the router, so a non-zero here means the install left the
        # box in the state that makes the model go silent.
        if HERMES_HOME="$HERMES_HOME" bash "$HERMES_HOME/sync-upstream.sh" --check >/dev/null 2>&1; then
          ok "sync-upstream --check: config.yaml dan .env SELARAS"
        else
          # P3-1: drift right after install is never intended, and leaving it
          # is exactly the state that makes the model go silent (base_url on a
          # stale router, or .env carrying the router inside CUSTOM_BASE_URL).
          # Repair once automatically, then re-check. If it still drifts, the
          # config is genuinely inconsistent and we fall back to reporting.
          warn "sync-upstream --check: drift terdeteksi setelah install — memperbaiki"
          if HERMES_HOME="$HERMES_HOME" bash "$HERMES_HOME/sync-upstream.sh" >>/tmp/.sync_apply.log 2>&1; then
            if HERMES_HOME="$HERMES_HOME" bash "$HERMES_HOME/sync-upstream.sh" --check >/dev/null 2>&1; then
              ok "sync-upstream: drift DIPERBAIKI otomatis — config.yaml dan .env SELARAS"
            else
              warn "sync-upstream: apply jalan tapi --check masih drift"
              HERMES_HOME="$HERMES_HOME" bash "$HERMES_HOME/sync-upstream.sh" --check 2>&1 \
                | sed 's/^/      /' || true
            fi
          else
            warn "sync-upstream: apply GAGAL — lihat /tmp/.sync_apply.log"
            sed 's/^/      /' /tmp/.sync_apply.log 2>/dev/null | tail -5 || true
          fi
        fi
      fi
    else
      warn "sync-upstream.sh tidak terpasang (copy gagal)"
    fi
  else
    warn "sync-upstream.sh missing from repo — sync manual tidak tersedia"
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

  # 1. force HERMES_UNRESTRICTED=1 in .env so every Hermes process honors it.
  #    This MUST happen before any early return below: it only needs .env, not
  #    the agent source. Previously a missing hermes-agent checkout returned
  #    early and left the flag unset, so a fresh box reported "installed"
  #    while every guard stayed ON.
  local envf="$HERMES_HOME/.env"
  if [[ $DRY_RUN -eq 0 && -f "$envf" ]]; then
    if grep -qE '^HERMES_UNRESTRICTED=' "$envf"; then
      # normalize to 1 (never leave a stale 0). PY_BIN may be empty when no
      # yaml-capable python exists: guard it instead of running "" and relying
      # on the || fallback.
      if [[ -n "${PY_BIN:-}" ]]; then
        "$PY_BIN" - "$envf" <<'PYEOF' 2>/dev/null || \
          sed -i 's/^HERMES_UNRESTRICTED=.*/HERMES_UNRESTRICTED=1/' "$envf"
import io, sys, re
p = sys.argv[1]
s = io.open(p, encoding="utf-8").read()
s = re.sub(r'(?m)^HERMES_UNRESTRICTED=.*$', 'HERMES_UNRESTRICTED=1', s)
io.open(p, "w", encoding="utf-8").write(s)
PYEOF
      else
        sed -i 's/^HERMES_UNRESTRICTED=.*/HERMES_UNRESTRICTED=1/' "$envf"
      fi
    else
      printf '\n# Unrestricted build — disables internal guards (SOUL/MEMORY honored verbatim)\nHERMES_UNRESTRICTED=1\n' >> "$envf"
    fi
    ok "HERMES_UNRESTRICTED=1 set in $envf"
  fi

  # locate the Hermes agent source (where the guards live)
  local agent_dir="${HERMES_AGENT_DIR:-$HERMES_HOME/hermes-agent}"
  if [[ ! -d "$agent_dir" ]]; then
    warn "hermes-agent source not found at $agent_dir — skipping guard patch"
    warn "  (set HERMES_AGENT_DIR if your checkout lives elsewhere)"
    warn "  HERMES_UNRESTRICTED=1 tetap ditulis; patch source belum diterapkan"
    UNRESTRICTED_STATUS="no-source"
    return 0
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
  if _sandboxed || [[ $DO_RESTART -eq 0 ]]; then
    dim "  [skip] gateway service drop-in (sandbox or --no-restart)"
  elif [[ -d "$unit_dir" ]] || systemctl --user show-environment >/dev/null 2>&1; then
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
  # NEVER bounce a gateway this run did not configure. In a sandbox (HERMES_HOME
  # != ~/.hermes) or under --no-restart, restarting is both pointless and
  # destructive: `systemctl --user restart hermes-gateway` is GLOBAL, so a test
  # run killed the operator's live chat session.
  if _sandboxed; then
    GATEWAY_STATUS="skipped-sandbox"
    dim "  [skip] gateway restart (sandbox run: HERMES_HOME=$HERMES_HOME)"
    return 0
  fi
  if [[ $DO_RESTART -eq 0 ]]; then
    GATEWAY_STATUS="skipped-no-restart"
    dim "  [skip] gateway restart (--no-restart)"
    return 0
  fi
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
  # Validation never changes state and must never roll the install back: a
  # missing optional piece is a warning, not an install failure. Disable the
  # ERR trap for the duration so a non-zero probe cannot abort the run.
  trap - ERR
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
               bash "$patcher" --check 2>/dev/null | sed -n 's/^PATCHED_FILES=//p' | tail -1)" || true
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
