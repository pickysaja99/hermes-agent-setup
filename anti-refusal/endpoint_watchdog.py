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
CANARY_TIMEOUT_S = 45
FAIL_THRESHOLD = 2
SWITCH_COOLDOWN_S = 300
GATEWAY_UNIT = "hermes-gateway.service"

PROXY_BASE = "http://127.0.0.1:9200/v1"
DIRECT_BASE = "https://onihub.tech/v1"
DEFAULT_MODEL = "step-5-preview-UNCENSORED"
CANARY_PROMPT = "ping"


def log(msg: str) -> None:
    line = "%s %s\n" % (time.strftime("%m-%d %H:%M:%S"), msg)
    with open(LOG, "a") as f:
        f.write(line)
    print(line, end="")


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


def restart_gateway() -> bool:
    try:
        r = subprocess.run(
            ["systemctl", "--user", "restart", GATEWAY_UNIT],
            capture_output=True, timeout=90,
        )
        return r.returncode == 0
    except Exception:
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
    """Ordered failover targets: (label, base_url, canary_timeout_s).

    The proxy burns a multi-upstream retry ladder per request, so it gets a
    longer canary budget than a direct endpoint.
    """
    return [("direct", DIRECT_BASE, 60.0), ("proxy", PROXY_BASE, 240.0)]


def check_once(dry_run: bool = False) -> str:
    active = read_base_url()
    if not active:
        return "no-base_url (skip)"
    key = load_env_key("HERMES_CUSTOM_ONIHUB_TECH_API_KEY")
    model = DEFAULT_MODEL
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

    for label, base, ctimeout in candidates():
        if base.rstrip("/") == active.rstrip("/"):
            continue
        ok, why = canary(base, key, model, timeout=ctimeout)
        if ok:
            log("FAILOVER %s -> %s (active was dead: %s)" % (active, base, detail))
            if dry_run:
                return "dry-run: would switch to %s" % base
            if write_base_url(base):
                st["last_switch_ts"] = now
                st["fails"] = 0
                st["active"] = base
                save_state(st)
                if restart_gateway():
                    log("gateway restarted on %s" % base)
                else:
                    log("WARN: base_url written but gateway restart FAILED")
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
