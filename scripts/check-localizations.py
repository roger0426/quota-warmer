#!/usr/bin/env python3
"""Fail if the String Catalog is missing or has an unfinished translation
(Turkish and Traditional Chinese).

Checks every key in Sources/QuotaWarmer/Resources/Localizable.xcstrings:
  - each target localization (`tr`, `zh-Hant`) exists, with state "translated" and a non-empty value;
  - its value uses the same format placeholders (%@, %lld, ...) in the
    same order as the English key, so interpolation still fills every slot.

Run after `scripts/sync-localizations.py` (see CLAUDE.md, "Localization").
Exit status 0 when everything passes, 1 otherwise.
"""

import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CATALOG = os.path.join(HERE, "..", "Sources", "QuotaWarmer", "Resources", "Localizable.xcstrings")
TARGETS = ("tr", "zh-Hant")

# `%%` is a literal percent sign, not a placeholder; everything else is.
PLACEHOLDER = re.compile(r"%%|%(?:\d+\$)?l*[dfu@]")


def placeholders(text):
    return [m for m in PLACEHOLDER.findall(text) if m != "%%"]


def main():
    with open(CATALOG, encoding="utf-8") as handle:
        catalog = json.load(handle)

    strings = catalog.get("strings", {})
    if not strings:
        print("FAIL: catalog has no strings")
        return 1

    problems = []
    for key, entry in sorted(strings.items()):
        if entry.get("shouldTranslate") is False:
            continue
        for target in TARGETS:
            unit = entry.get("localizations", {}).get(target, {}).get("stringUnit")
            if unit is None:
                problems.append("missing %s: %r" % (target, key))
                continue
            state = unit.get("state")
            value = unit.get("value", "")
            if state != "translated":
                problems.append("%s state %r (want 'translated'): %r" % (target, state, key))
            if not value.strip() and key.strip():
                problems.append("empty %s value: %r" % (target, key))
            if placeholders(key) != placeholders(value):
                problems.append("%s placeholder mismatch %r -> %r" % (target, key, value))

    if problems:
        for line in problems:
            print("FAIL: " + line)
        print("FAIL: %d problem(s) across %d keys" % (len(problems), len(strings)))
        return 1

    print("OK: %d keys, all with translated %s values and matching placeholders" % (len(strings), ", ".join(TARGETS)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
