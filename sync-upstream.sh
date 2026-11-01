#!/usr/bin/env bash
# sync-upstream.sh — propagate a model change made by `hermes setup model`
# (or by hand-editing config.yaml) into .env, and put model.base_url back on
# the guardrail proxy.
#
# WHY THIS EXISTS
# `hermes setup model` writes config.yaml only. The proxy reads .env only.
# Nothing in hermes_cli knows about ANTIREFUSAL_*, so after a model switch:
#
#   config.yaml : base_url = <new router>        <- Hermes talks here
#   .env        : ANTIREFUSAL_UPSTREAM = <old>   <- proxy listens to this
#
# The result is that every request bypasses the refusal ladder (and the
# watchdog will NOT undo it, because the new router answers its canary fine).
# That is the "model does not respond / guardrail does nothing" state.
#
# This script closes the loop in the direction the operator actually uses:
#   config.yaml (what setup wrote) -> .env -> model.base_url = proxy
#
# Idempotent, safe to run repeatedly, and refuses to write when config.yaml
# has no usable model block.
#
# Usage:
#   bash sync-upstream.sh              # apply
#   bash sync-upstream.sh --dry-run    # show what would change
#   bash sync-upstream.sh --check      # exit 1 if out of sync (for cron/CI)
set -uo pipefail

HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
CFG="$HERMES_HOME/config.yaml"
ENVF="$HERMES_HOME/.env"
PROXY_BASE="${ANTIREFUSAL_PROXY_URL:-http://127.0.0.1:9200/v1}"

DRY=0
CHECK=0
RESTART=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --check)   CHECK=1 ;;
    --restart) RESTART=1 ;;
    -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

say()  { printf '  %s\n' "$*"; }
ok()   { printf '  [ok] %s\n' "$*"; }
warn() { printf '  [!] %s\n' "$*" >&2; }

[[ -f "$CFG" ]]  || { warn "config.yaml tidak ada: $CFG"; exit 1; }

PY=""
for c in python3 /usr/bin/python3 python; do
  command -v "$c" >/dev/null 2>&1 && { PY="$c"; break; }
done

# Read the model block without PyYAML when it is missing: a plain 2-space
# scan is enough and this script must work on a minimal VPS.
read_model_block() {
  if [[ -n "$PY" ]] && "$PY" -c "import yaml" 2>/dev/null; then
    "$PY" - "$CFG" <<'PYEOF'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8").read()) or {}
m = doc.get("model") or {}
print(m.get("base_url") or "")
print(m.get("default") or "")
k = str(m.get("api_key") or "")
print(k)
PYEOF
  else
    local b d k
    b="$(sed -n '/^model:/,/^[^[:space:]]/p' "$CFG" | grep -m1 -E '^  base_url:' \
         | sed -E 's/^  base_url:[[:space:]]*//; s/^["'\'']//; s/["'\'']$//')"
    d="$(sed -n '/^model:/,/^[^[:space:]]/p' "$CFG" | grep -m1 -E '^  default:' \
         | sed -E 's/^  default:[[:space:]]*//; s/^["'\'']//; s/["'\'']$//')"
    k="$(sed -n '/^model:/,/^[^[:space:]]/p' "$CFG" | grep -m1 -E '^  api_key:' \
         | sed -E 's/^  api_key:[[:space:]]*//; s/^["'\'']//; s/["'\'']$//')"
    printf '%s\n%s\n%s\n' "$b" "$d" "$k"
  fi
}

mapfile -t _mb < <(read_model_block)
CUR_BASE="${_mb[0]:-}"
CUR_MODEL="${_mb[1]:-}"
CUR_KEYREF="${_mb[2]:-}"

if [[ -z "$CUR_BASE" || -z "$CUR_MODEL" ]]; then
  warn "model.base_url/default kosong di config.yaml — tidak ada yang bisa disinkronkan"
  exit 1
fi

# Already on the proxy? Then config.yaml carries no router information and
# there is nothing to propagate. Report and stop: do not invent an upstream.
NORM_PROXY="${PROXY_BASE%/}"
NORM_CUR="${CUR_BASE%/}"
if [[ "$NORM_CUR" == "$NORM_PROXY" ]]; then
  say "model.base_url sudah proxy ($NORM_CUR) — tidak ada router baru di config.yaml"
  # Still report whether the proxy's upstream matches .env, because a manual
  # .env edit can drift in the other direction.
  ENV_UP="$(grep -E '^ANTIREFUSAL_UPSTREAM=' "$ENVF" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
  if [[ -z "$ENV_UP" ]]; then
    warn "ANTIREFUSAL_UPSTREAM kosong di .env — proxy tidak punya upstream"
    exit 1
  fi
  ok "ANTIREFUSAL_UPSTREAM = $ENV_UP"
  exit 0
fi

# A loopback base_url that is NOT our proxy would self-loop; refuse.
case "$NORM_CUR" in
  http://127.0.0.1*|http://localhost*|https://127.0.0.1*|https://localhost*)
    if [[ "$NORM_CUR" == "$NORM_PROXY" ]]; then :; else
      warn "model.base_url menunjuk loopback lain ($NORM_CUR) — bukan proxy, bukan router. Berhenti."
      exit 1
    fi
    ;;
esac

# key reference: ${ENV_NAME} -> ENV_NAME
KEYENV=""
case "$CUR_KEYREF" in
  '${'*'}') KEYENV="${CUR_KEYREF#\$\{}"; KEYENV="${KEYENV%\}}" ;;
  '')       KEYENV="" ;;
  *)        # literal key inline: usable, but warn (secrets belong in .env)
            KEYENV="" ;;
esac

HOST="$(printf '%s' "$NORM_CUR" | sed -E 's#^https?://##; s#/.*##')"

if [[ $CHECK -eq 1 ]]; then
  ENV_UP="$(grep -E '^ANTIREFUSAL_UPSTREAM=' "$ENVF" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
  ENV_MD="$(grep -E '^ANTIREFUSAL_MODEL=' "$ENVF" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
  drifted=0
  [[ "${ENV_UP%/}" != "$NORM_CUR" ]] && { warn "drift upstream: .env=${ENV_UP:-<kosong>} config=$NORM_CUR"; drifted=1; }
  [[ "$ENV_MD" != "$CUR_MODEL" ]]     && { warn "drift model: .env=${ENV_MD:-<kosong>} config=$CUR_MODEL"; drifted=1; }
  [[ "$NORM_PROXY" != "$NORM_CUR" ]]  && { warn "model.base_url bukan proxy: $NORM_CUR"; drifted=1; }
  exit "$drifted"
fi

say "ditemukan router baru di config.yaml:"
say "  base_url : $NORM_CUR"
say "  model    : $CUR_MODEL"
[[ -n "$KEYENV" ]] && say "  key_env  : $KEYENV"

if [[ $DRY -eq 1 ]]; then
  say ""
  say "(dry-run) akan:"
  say "  .env ANTIREFUSAL_UPSTREAM = $NORM_CUR"
  say "  .env ANTIREFUSAL_MODEL    = $CUR_MODEL"
  [[ -n "$KEYENV" ]] && say "  .env CUSTOM_BASE_URL      = $NORM_CUR"
  say "  config.yaml model.base_url = $NORM_PROXY"
  exit 0
fi

# -- 1) update .env in place (preserve every other line, keep permissions)
[[ -f "$ENVF" ]] || { : > "$ENVF"; chmod 600 "$ENVF"; }

set_env() {  # key value
  local k="$1" v="$2" tmp
  tmp="$(mktemp)"
  if grep -qE "^${k}=" "$ENVF"; then
    awk -v k="$k" -v v="$v" '
      BEGIN{done=0}
      $0 ~ "^"k"=" { if(!done){ print k"="v; done=1 } ; next }
      { print }
    ' "$ENVF" > "$tmp"
  else
    cp "$ENVF" "$tmp"
    printf '%s=%s\n' "$k" "$v" >> "$tmp"
  fi
  cat "$tmp" > "$ENVF"
  rm -f "$tmp"
}

set_env "ANTIREFUSAL_UPSTREAM" "$NORM_CUR"
set_env "ANTIREFUSAL_MODEL" "$CUR_MODEL"
[[ -n "$KEYENV" ]] && set_env "CUSTOM_BASE_URL" "$NORM_CUR"
chmod 600 "$ENVF" 2>/dev/null || true
ok ".env diperbarui (ANTIREFUSAL_UPSTREAM, ANTIREFUSAL_MODEL)"

# -- 2) put model.base_url back on the proxy (config.yaml, in place)
if [[ -n "$PY" ]] && "$PY" -c "import yaml" 2>/dev/null; then
  "$PY" - "$CFG" "$NORM_PROXY" <<'PYEOF'
import sys, yaml
p, proxy = sys.argv[1], sys.argv[2]
doc = yaml.safe_load(open(p, encoding="utf-8").read()) or {}
m = doc.setdefault("model", {})
m["base_url"] = proxy
out = yaml.safe_dump(doc, sort_keys=True, allow_unicode=True, default_flow_style=False)
if (yaml.safe_load(out).get("model") or {}).get("base_url") != proxy:
    print("   self-check gagal -- config tidak ditulis"); sys.exit(1)
open(p, "w", encoding="utf-8").write(out)
PYEOF
  [[ $? -eq 0 ]] && ok "config.yaml: model.base_url -> $NORM_PROXY" || warn "gagal menulis config.yaml"
else
  # sed fallback: rewrite only the base_url line inside the model: block
  tmp="$(mktemp)"
  awk -v proxy="$NORM_PROXY" '
    BEGIN{inm=0; done=0}
    /^model:[[:space:]]*$/ { inm=1; print; next }
    inm && /^[^[:space:]]/ && !/^model:/ { inm=0 }
    inm && /^  base_url:/ && !done { print "  base_url: " proxy; done=1; next }
    { print }
  ' "$CFG" > "$tmp" && cat "$tmp" > "$CFG" && rm -f "$tmp"
  if grep -qE "^  base_url: ${NORM_PROXY}$" "$CFG" || grep -qF "  base_url: $NORM_PROXY" "$CFG"; then
    ok "config.yaml: model.base_url -> $NORM_PROXY (sed)"
  else
    warn "gagal menulis config.yaml (PyYAML tidak ada dan sed tidak cocok)"
  fi
fi

# -- 3) restarts are OPT-IN (--restart). Default is to write and STOP.
#    The previous version restarted antirefusal.service and hermes-gateway
#    unconditionally, so running it from inside a live Hermes session killed
#    the session that invoked it. Never restart the thing you are running
#    inside without being asked to.
if [[ $RESTART -eq 0 ]]; then
  say ""
  ok "file sudah diperbarui. Service BELUM direstart (butuh --restart)."
  say "  .env dibaca saat proxy start, jadi restart diperlukan agar berlaku:"
  say "    bash sync-upstream.sh --restart"
  exit 0
fi

# -- restart the proxy so it reloads .env, else it keeps the old upstream
if command -v systemctl >/dev/null 2>&1 && systemctl --user is-active --quiet antirefusal.service 2>/dev/null; then
  systemctl --user restart antirefusal.service && ok "antirefusal.service direstart" \
    || warn "restart antirefusal.service gagal"
elif command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet antirefusal.service 2>/dev/null; then
  sudo -n systemctl restart antirefusal.service 2>/dev/null && ok "antirefusal.service direstart (system)" \
    || warn "restart antirefusal.service butuh sudo"
else
  warn "antirefusal.service tidak aktif — start manual agar .env terbaca ulang"
fi

# -- 4) restart the gateway so Hermes picks up the rewritten base_url.
#    REFUSED when called from inside a Hermes session: the env carries
#    HERMES_AGENT/HERMES_SESSION_*, and restarting the gateway from here is
#    what killed the session that ran this script. The proxy restart above is
#    enough for the .env change; Hermes picks up base_url on its own next
#    start, which the operator controls.
if [[ -n "${HERMES_AGENT:-}${HERMES_SESSION_ID:-}${AI_AGENT:-}" ]]; then
  warn "dipanggil dari dalam sesi Hermes — hermes-gateway TIDAK direstart"
  warn "  jalankan 'systemctl --user restart hermes-gateway' sendiri saat siap"
  exit 0
fi
if command -v systemctl >/dev/null 2>&1; then
  if systemctl --user is-active --quiet hermes-gateway.service 2>/dev/null; then
    systemctl --user restart hermes-gateway.service && ok "hermes-gateway.service direstart"
  elif systemctl is-active --quiet hermes-gateway.service 2>/dev/null; then
    sudo -n systemctl restart hermes-gateway.service 2>/dev/null && ok "hermes-gateway.service direstart (system)"
  else
    warn "hermes-gateway.service tidak aktif — restart manual agar base_url baru dipakai"
  fi
fi

say ""
ok "selesai. Request berikutnya: Hermes -> proxy -> $NORM_CUR"
say "verifikasi: bash sync-upstream.sh --check"
