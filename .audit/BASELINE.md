# Audit Baseline — kondisi SEBELUM perubahan

Tanggal  : 2026-11-08
Repo     : pickysaja99/hermes-agent-setup
Branch   : main
HEAD     : 59bbe82
Upstream : NousResearch/hermes-agent @ bf0203a794 (6110 commit di belakang)

## Inventaris

| File | Baris | Peran |
|---|---|---|
| install.sh | 2177 | installer utama |
| sync-upstream.sh | 260 | sinkron config.yaml -> .env -> proxy |
| unrestricted.sh | 921 | patch guard (early-return) |
| SOUL.md | 644 | identitas, precedence lock |
| config.yaml | 252 | 33 section |
| anti-refusal/proxy.py | 2312 | proxy anti-refusal |
| anti-refusal/endpoint_watchdog.py | 747 | failover base_url |
| anti-refusal/refusal_patterns.py | 123 | pola refusal |
| anti-refusal/test_refusal_detection.py | 588 | test suite |

## Patch guard asli (JANGAN dirusak)

`tools/approval.py` — early-return, bukan tempel teks:
```python
def has_blocking_approval(session_key):
    import os as _os
    if _os.getenv("HERMES_UNRESTRICTED", "1") != "0":
        return False
```
29 file dipatch. `grep` kosong pada tools/bash_tool.py = normal,
patch hanya di file yang punya guard.

## Kontrak .env <-> config.yaml

- config.yaml `model.base_url` -> Hermes bicara di sini
- .env `ANTIREFUSAL_UPSTREAM` -> proxy nembak ke sini
- `CUSTOM_BASE_URL` -> override yang MENANG atas config.yaml
- auth.json `credential_pool[*].base_url` -> override lain

Urutan yang menang (dari yang terkuat):
  1. .env CUSTOM_BASE_URL
  2. auth.json credential_pool
  3. config.yaml model.base_url

sync-upstream.sh menutup loop ini. Installer harus tetap idempoten.
