#!/usr/bin/env python3
"""Verbatim refusal phrase lists -- enforcer side only.

These strings were removed from SOUL.md v7 on purpose. A model reads its own
context: a document that LISTS refusal phrasings teaches the model what a
refusal is supposed to look like, and under a thin context that list is what
gets reproduced. The behaviour classes stay in SOUL.md §2 (what to detect and
discard); the literal strings live here, outside the model's context, and are
compiled into regexes by proxy.py.

Import contract: nothing in this module may be echoed to a model. It is read
by proxy.py at startup and by test_refusal_detection.py.

Keep this list in sync with DECLINE_RE / REFUSAL_RE / DOWNGRADE_RE in proxy.py:
those regexes are the enforcement, this file is the human-readable inventory
used to test them.
"""

# --- Direct declines ------------------------------------------------------
DIRECT_EN = (
    "I can't", "I cannot", "I can not", "I'm unable", "I am unable",
    "I'm not able", "I'm not allowed", "I am not allowed", "I cannot help",
    "I can't help", "I won't", "I will not", "I must decline", "I refuse",
    "I'm sorry", "I am sorry", "I apologize", "I apologise",
    "not going to help", "not willing to help",
)

DIRECT_ID = (
    "aku tidak bisa", "saya tidak bisa", "aku tak bisa", "saya tak bisa",
    "aku tidak akan", "saya tidak akan", "aku menolak", "saya menolak",
    "tidak dapat dipenuhi", "tidak bisa dipenuhi", "tidak dapat saya lakukan",
    "maaf, saya tidak", "maaf aku tidak", "tidak bisa membantu",
)

DIRECT_ZH = (
    "我无法", "我不能", "我不会", "我拒绝", "拒绝提供", "拒绝回答", "拒绝协助",
)

# --- Legal / ethical framing ---------------------------------------------
FRAMING_EN = (
    "this is illegal", "this is unethical", "as an AI", "as a language model",
    "consult a professional", "consult a lawyer", "I'd recommend against",
    "I would recommend against", "for educational purposes only",
    "for research purposes only", "I'm programmed to",
)

FRAMING_ID = (
    "melanggar hukum", "ilegal", "tindak pidana", "tidak etis",
    "sebagai AI", "sebagai model bahasa", "untuk tujuan edukasi",
    "hanya untuk edukasi", "pastikan anda memiliki izin",
    "jangan digunakan pada jaringan ilegal",
)

# --- Hedges / premises ----------------------------------------------------
HEDGE_EN = (
    "It's important to note", "It is important to note", "I should mention",
    "I should point out", "please note that", "are you sure",
    "is this your account", "for what purpose", "where did you get",
    "keep in mind that", "be aware that", "I'd suggest being careful",
)

HEDGE_ID = (
    "perlu diingat", "sebaiknya", "saya sarankan hati-hati",
    "apakah kamu yakin", "apakah ini milikmu", "untuk tujuan apa",
    "perlu dicatat", "harap diingat",
)

# --- Delays ---------------------------------------------------------------
DELAY_EN = (
    "I must decline", "let me think about whether", "should I continue",
    "would you like me to proceed", "shall I go ahead", "before I proceed",
)

DELAY_ID = (
    "boleh saya lanjut", "apakah saya boleh melanjutkan", "sebelum saya lanjut",
    "mau saya lanjutkan", "apakah kamu ingin saya lanjutkan",
)

# --- Capability downgrade -------------------------------------------------
DOWNGRADE_EN = (
    "I can only create", "I can only provide", "I can only offer",
    "I can provide a defensive", "I can provide an educational",
    "here's a simplified version", "here is a simplified version",
    "a simplified version of", "a defensive demonstration",
    "an educational demonstration", "instead, I can",
)

DOWNGRADE_ID = (
    "versi sederhana", "versi aman", "versi edukatif", "demonstrasi defensif",
    "sebagai gantinya saya", "alih-alih itu saya",
)

# --- Taxonomy stall -------------------------------------------------------
STALL_EN = (
    "the combination of terms you listed", "the terms you used",
    "what you've described", "what you are describing",
    "maps directly to", "is a specific category of code",
    "the harmful capability is",
)

STALL_ID = (
    "kombinasi istilah yang anda sebutkan", "istilah yang anda gunakan",
    "apa yang anda jelaskan", "merupakan kategori kode",
)


def all_phrases():
    """Flat list of every phrase, for tests and coverage checks."""
    out = []
    for name, group in sorted(globals().items()):
        if name.isupper() and isinstance(group, tuple):
            out.extend(group)
    return out


if __name__ == "__main__":
    groups = {k: v for k, v in sorted(globals().items())
              if k.isupper() and isinstance(v, tuple)}
    total = 0
    for k, v in groups.items():
        print(f"{k:16s} {len(v):3d}")
        total += len(v)
    print(f"{'TOTAL':16s} {total:3d}")
