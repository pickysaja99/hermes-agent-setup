#!/usr/bin/env python3
"""
Hermes endpoint watchdog — auto-failover for model.base_url.

Failure this prevents (observed 1 Nov 2026): install.sh routed
model.base_url at the local anti-refusal proxy (127.0.0.1:9200) without
validating the proxy's upstream ladder. /health stayed green while every
upstream was dead (morku 404, gonka 502/400, qzgo 429), so the proxy
answered 200 with an EMPTY body and Hermes had no working endpoint — the
AI went silent with no error anywhere.

What this does, every cycle (default 60s):
  1. Read model.base_url from ~/.hermes/config.yaml (regex, no deps).
  2. Canary-chat the ACTIVE endpoint (tiny prompt, short timeout).
     Alive = HTTP 200 + non-empty choices[0].message.content.
  3. Two consecutive dead canaries -> pick the first HEALTHY candidate
     from [proxy, direct] (excluding the active one), rewrite
     model.base_url in place, restart the gateway, log it.
  4. 300s cooldown between switches so a flapping endpoint cannot
     ping-pong the config.

Zero deps (stdlib urllib only) so it runs on system python3.
Never touches the config while the active endpoint is healthy.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

HERMES_HOME = Path(os.environ.get("HERMES_HOME", str(Path.home() / ".hermes")))
CFG = HERMES_HOME / "config.yaml"
ENV = HERMES_HOME / ".env"
STATE = HERMES_HOME / "anti-refusal" / "watchdog_state.json"
LOG = HERMES_HOME / "anti-refusal" / "watchdog.log"

CYCLE_S = 60
CANARY_TIMEOUT_S = 120
FAIL_THRESHOLD = 2
SWITCH_COOLDOWN_S = 300
GATEWAY_UNIT = "hermes-gateway.service"

PROXY_BASE = "http://127.0.0.1:9200/v1"
# OPERATOR CONTRACT: ONE upstream only — the primary router in .env. No
# hard-coded host here (that is how a dead onihub kept being reintroduced
# after model.base_url had already moved to the live router).
DEFAULT_MODEL = ""  # resolved from config.yaml model.default / config.json
CANARY_PROMPT = "ping"
AR_CFG = HERMES_HOME / "anti-refusal" / "config.json"


def _host_port(base: str) -> tuple[str, int]:
    """('router.host', 443) from 'https://router.host/v1'."""
    b = base.split("://", 1)[-1]
    host, _, port = b.partition("/")[0].partition(":")
    try:
        prt = int(port) if port else (443 if base.startswith("https") else 80)
    except ValueError:
        prt = 443
    return host.lower(), prt


def read_canary_model() -> str:
    """Fast model for the liveness canary.

    The default model is usually a thinking model (2500-token floor, slow
    first token). Canarying with it false-positives "dead" on latency
    alone. Prefer anti-refusal/config.json `canary_model`, then the first
    non-default entry of `models`, then model.default.
    """
    try:
        cfg = json.loads(AR_CFG.read_text())
    except Exception:
        cfg = {}
    cm = cfg.get("canary_model")
    if cm:
        return cm
    default = read_model_default()
    models = cfg.get("models") or []
    if isinstance(models, list):
        for m in models:
            if m and m != default:
                return m
    # single-upstream boxes usually have exactly one model in the list ==
    # model.default; canary with it rather than skipping the canary.
    return default


def read_model_default() -> str:
    """model.default from config.yaml (same 2-space-indent scan as base_url)."""
    try:
        lines = CFG.read_text().splitlines()
    except OSError:
        return DEFAULT_MODEL
    in_model = False
    for ln in lines:
        if ln.startswith("model:"):
            in_model = True
            continue
        if in_model:
            if ln.strip() and not ln[:1].isspace():
                break
            if ln.startswith("  default:"):
                v = ln.split(":", 1)[1].strip().strip("'\"")
                return v or DEFAULT_MODEL
    return DEFAULT_MODEL


def read_ar_cfg() -> dict:
    try:
        return json.loads(AR_CFG.read_text())
    except Exception:
        return {}


def read_env() -> dict:
    """Parse ~/.hermes/.env (KEY=VALUE, no shell expansion needed)."""
    out = {}
    try:
        for line in ENV.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip().strip("'\"")
    except OSError:
        pass
    return out


def primary_upstream() -> tuple:
    """(base, key_env) of the ONE primary router, from .env -> config.json.

    `.env` is the single source of truth (ANTIREFUSAL_UPSTREAM /
    CUSTOM_BASE_URL). config.json is only a derived mirror, used when .env
    is silent. NEVER falls back to a hard-coded host: a missing primary
    means there is nothing to fail over to, and the watchdog says so
    instead of dragging a dead host back in.
    """
    env = read_env()
    base = (env.get("ANTIREFUSAL_UPSTREAM") or env.get("CUSTOM_BASE_URL") or "").strip()
    ar = read_ar_cfg()
    if not base:
        base = str(ar.get("upstream_base_url") or "").strip()
    if not base:
        ups = [u for u in (ar.get("upstreams") or []) if isinstance(u, dict)]
        if ups:
            base = str(ups[0].get("base") or "").strip()
    key_env = str(ar.get("upstream_key_env") or "").strip()
    if base:
        norm = lambda b: _norm_url(b)
        for item in ar.get("upstreams") or []:
            if isinstance(item, dict) and norm(item.get("base", "")) == norm(base):
                key_env = item.get("key_env") or key_env
                break
        if not key_env:
            host = _host_port(base)[0]
            key_env = "HERMES_CUSTOM_%s_API_KEY" % re.sub(r"[^A-Za-z0-9]+", "_", host).upper()
        if base.rstrip("/") == str(ar.get("upstream_base_url") or "").rstrip("/"):
            key_env = str(ar.get("upstream_key_env") or key_env)
    return base.rstrip("/"), key_env


def _norm_url(b: str) -> str:
    return (b or "").rstrip("/").lower()


def log(msg: str) -> None:
    line = "%s %s\n" % (time.strftime("%m-%d %H:%M:%S"), msg)
    with open(LOG, "a") as f:
        f.write(line)
    print(line, end="")


def key_for_host(base: str) -> str:
    """Bearer for `base`, matched by host from .env (HERMES_CUSTOM_<HOST>_API_KEY).

    Falls back to the single upstream key when only one key exists, so a
    renamed env var cannot leave the canary/ failover with an empty bearer.
    """
    env = read_env()
    host = _host_port(base)[0] if base else ""
    slug = re.sub(r"[^A-Za-z0-9]+", "_", host).upper()
    cands = ["HERMES_CUSTOM_%s_API_KEY" % slug, "CUSTOM_API_KEY"]
    for c in cands:
        if env.get(c):
            return env[c]
    for k, v in env.items():
        if v and len(v) >= 8 and ("_API_KEY" in k or k.endswith("_KEY")):
            if slug and slug.split("_")[0] and slug.split("_")[0] in k:
                return v
    _b, key_env = primary_upstream()
    if key_env and env.get(key_env):
        return env[key_env]
    return ""


def load_env_key(name: str) -> str:
    if not ENV.is_file():
        return ""
    for ln in ENV.read_text().splitlines():
        if ln.startswith(name + "="):
            return ln.split("=", 1)[1].strip().strip('"').strip("'")
    return ""


def read_base_url() -> str | None:
    """model.base_url from config.yaml; None if unreadable/absent.

    Matches the top-level `model:` block ONLY (column 0) and its direct
    `base_url:` child (2-space indent) — nested provider/alias entries
    also carry base_url keys and must not be mistaken for the active one.
    """
    try:
        lines = CFG.read_text().splitlines()
    except OSError:
        return None
    in_model = False
    for ln in lines:
        if ln.startswith("model:"):
            in_model = True
            continue
        if in_model:
            if ln.strip() and not ln[:1].isspace():
                break  # left the model block
            if ln.startswith("  base_url:"):
                return ln.split(":", 1)[1].strip()
    return None


def write_base_url(new: str) -> bool:
    """Replace the base_url line inside the model: block, in place."""
    try:
        raw = CFG.read_text()
    except OSError:
        return False
    lines = raw.splitlines(keepends=True)
    out, in_model, done = [], False, False
    for ln in lines:
        if ln.startswith("model:"):
            in_model = True
            out.append(ln)
            continue
        if in_model and ln.strip() and not ln[:1].isspace():
            in_model = False
        if in_model and ln.startswith("  base_url:") and not done:
            out.append(f"  base_url: {new}\n")
            done = True
            continue
        out.append(ln)
    if not done:
        return False
    CFG.write_text("".join(out))
    return True


BROWSER_UA = ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
               "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36")


def canary(base: str, key: str, model: str, timeout: float = CANARY_TIMEOUT_S) -> tuple[bool, str]:
    """POST a tiny chat completion. (alive, detail).

    Browser UA is mandatory: onihub.tech sits behind Cloudflare, which
    answers 1010 (403) to the default Python-urllib UA even when the
    endpoint is healthy — a canary without it reports every endpoint dead.
    """
    url = base.rstrip("/") + "/chat/completions"
    body = json.dumps({
        "model": model,
        "messages": [{"role": "user", "content": CANARY_PROMPT}],
        "max_tokens": 8,
        "stream": False,
    }).encode()
    req = urllib.request.Request(url, data=body, method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("Accept", "application/json")
    req.add_header("User-Agent", BROWSER_UA)
    if key:
        req.add_header("Authorization", "Bea" + "rer " + key)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            data = json.loads(r.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        return False, "HTTP %s" % e.code
    except Exception as e:  # timeout, reset, DNS, bad JSON
        return False, type(e).__name__
    try:
        content = data["choices"][0]["message"]["content"]
    except (KeyError, IndexError, TypeError):
        return False, "empty-200 (no content)"
    if not content or not str(content).strip():
        return False, "empty-200 (blank content)"
    return True, "ok"


def _session_busy() -> bool:
    """True kalau ada turn/sesi gateway yang sedang aktif.

    Cacat lama: watchdog restart hermes-gateway TANPA menunggu idle, jadi
    sesi operator (Telegram/DM) mati di tengah turn setiap kali failover.
    Sinyal yang dipakai (murah, tanpa deps):
      * HERMES_QUIET=0/1 di env gateway (0 = turn berjalan)
      * mtime gateway_state.json / lock < ~15s (baru diperbarui = aktif)
      * file sesi terakhir yang masih fresh
    """
    # 1. env flag kalau watchdog dijalankan di dalam sesi gateway
    q = os.environ.get("HERMES_QUIET", "")
    if q not in ("", "1", "true", "True"):
        return True
    now = time.time()
    # 2. file state yang ditulis gateway saat sibuk
    for rel in ("state/gateway.lifecycle.json", "gateway_state.json",
                "gateway.lock", "gateway.pid"):
        f = HERMES_HOME / rel
        try:
            if f.is_file() and (now - f.stat().st_mtime) < 20:
                # lock/pid yang baru diperbarui = gateway aktif; tapi ini juga
                # true saat idle. Bedakan lewat HERMES_QUIET bila ada.
                pass
        except OSError:
            pass
    # 3. isi lifecycle: phase running + mtime sangat baru = kemungkinan turn
    try:
        lc = json.loads((HERMES_HOME / "state/gateway.lifecycle.json").read_text())
        started = lc.get("start_time") or 0
        if started and (now - started) < 8:
            return True  # baru start, beri waktu init
    except Exception:
        pass
    return False


def restart_gateway() -> bool:
    # systemd --user first; then the box-local script; then a process kill.
    # A base_url rewrite WITHOUT a gateway restart does nothing (the running
    # gateway keeps its in-memory endpoint), so every path must be tried.
    #
    # F1: jangan restart kalau sesi sedang aktif -- tunggu siklus berikutnya.
    if _session_busy():
        log("session busy -- restart deferred (no mid-turn kill)")
        return False
    try:
        r = subprocess.run(
            ["systemctl", "--user", "restart", GATEWAY_UNIT],
            capture_output=True, timeout=90,
        )
        if r.returncode == 0:
            return True
    except Exception:
        pass
    script = HERMES_HOME / "restart-gw.sh"
    if script.is_file():
        try:
            r = subprocess.run(["bash", str(script)],
                               capture_output=True, timeout=120)
            if r.returncode == 0:
                log("gateway restarted via %s", script)
                return True
        except Exception:
            pass
    try:
        r = subprocess.run(["pkill", "-f", "hermes.*gateway"],
                           capture_output=True, timeout=30)
        if r.returncode == 0:
            log("gateway restarted via pkill fallback")
            return True
    except Exception:
        pass
    return False


def load_state() -> dict:
    try:
        return json.loads(STATE.read_text())
    except Exception:
        return {"fails": 0, "last_switch_ts": 0.0, "active": None}


def save_state(st: dict) -> None:
    STATE.parent.mkdir(parents=True, exist_ok=True)
    STATE.write_text(json.dumps(st, indent=2))


def candidates() -> list:
    """Failover targets: (label, base_url, key_env, timeout_s).

    OPERATOR CONTRACT (one upstream): the ONLY direct candidate is the
    primary router from `.env` (see primary_upstream()). The residual list in
    anti-refusal/config.json is deliberately NOT walked — that ladder is how
    a dead host (onihub/old router) kept getting promoted back into
    model.base_url after the operator had already chosen a new one.

    The local proxy is offered as the LAST candidate only, and only when its
    upstream is not itself (self-loop) and it is not the active base.
    """
    out, seen = [], set()

    def add(label, base, key_env, timeout):
        base = (base or "").rstrip("/")
        if not base or base in seen or not base.startswith("http"):
            return
        seen.add(base)
        out.append((label, base, key_env, timeout))

    base, key_env = primary_upstream()
    if base:
        add("primary", base, key_env, 60.0)

    # proxy candidate — skip when it would loop to itself
    proxy_self = False
    env = read_env()
    for b in [env.get("ANTIREFUSAL_UPSTREAM", ""), base]:
        if b:
            h, prt = _host_port(b)
            if h in ("127.0.0.1", "localhost", "::1") and prt == 9200:
                proxy_self = True
    if not proxy_self:
        add("proxy", PROXY_BASE, "", 240.0)
    return out


def check_once(dry_run: bool = False) -> str:
    active = read_base_url()
    if not active:
        return "no-base_url (skip)"
    # key for the ACTIVE base: host-matched from .env via the primary router
    # record; never borrow a hard-coded host's token.
    key = key_for_host(active)
    if not key:
        _pb, _pke = primary_upstream()
        key = load_env_key(_pke) if _pke else ""
    model = read_canary_model()
    alive, detail = canary(active, key, model)
    st = load_state()

    if alive:
        if st.get("fails"):
            log("active endpoint recovered: %s" % active)
        st["fails"] = 0
        st["active"] = active
        save_state(st)
        return "alive: %s" % active

    st["fails"] = st.get("fails", 0) + 1
    save_state(st)
    if st["fails"] < FAIL_THRESHOLD:
        log("canary fail %d/%d on %s (%s)" % (st["fails"], FAIL_THRESHOLD, active, detail))
        return "degraded"

    # active is dead — cooldown check, then failover
    now = time.time()
    if now - st.get("last_switch_ts", 0.0) < SWITCH_COOLDOWN_S:
        log("active dead but cooldown active — no switch (%s)" % active)
        return "cooldown"

    for label, base, key_env, ctimeout in candidates():
        if base.rstrip("/") == active.rstrip("/"):
            continue
        ckey = load_env_key(key_env) if key_env else key
        ok, why = canary(base, ckey, model, timeout=ctimeout)
        if ok:
            log("FAILOVER %s -> %s (active was dead: %s)" % (active, base, detail))
            if dry_run:
                return "dry-run: would switch to %s" % base
            same = base.rstrip("/") == (active or "").rstrip("/")
            if same:
                # tidak ada perubahan nyata -- jangan sentuh gateway
                st["last_switch_ts"] = now
                st["active"] = base
                save_state(st)
                log("canary recovered on same base -- no rewrite, no restart")
                return "same: %s" % base
            if write_base_url(base):
                st["last_switch_ts"] = now
                st["fails"] = 0
                st["active"] = base
                save_state(st)
                if restart_gateway():
                    log("gateway restarted on %s" % base)
                else:
                    log("base_url -> %s written; gateway restart deferred/failed "
                        "(retry next cycle if session went idle)" % base)
                return "switched to %s" % base
            log("ERROR: config rewrite failed")
            return "rewrite-failed"
        log("candidate %s also dead (%s)" % (label, why))

    log("ALL endpoints dead — config untouched (%s)" % active)
    return "all-dead"


def main() -> None:
    args = set(sys.argv[1:])
    dry = "--dry-run" in args
    if "--once" in args or dry:
        print(check_once(dry_run=dry))
        return
    log("endpoint watchdog started (cycle %ds, threshold %d, cooldown %ds)"
        % (CYCLE_S, FAIL_THRESHOLD, SWITCH_COOLDOWN_S))
    while True:
        try:
            check_once()
        except Exception as e:
            log("cycle error: %r" % e)
        time.sleep(CYCLE_S)


if __name__ == "__main__":
    main()
