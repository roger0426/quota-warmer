#!/usr/bin/env python3
"""Fails when the app's Swift sources name a host that is not on the list below.

Run it after merging upstream changes (`python3 scripts/check-egress-hosts.py`):
a new host means new code talks to somewhere new, and that deserves a look
before the build is used. It only reads files; no network, no Xcode needed.
"""
import pathlib
import re
import sys

# host -> why the app may name it
ALLOWED = {
    "api.anthropic.com": "Claude quota (sends the Claude OAuth token)",
    "chatgpt.com": "Codex quota and reset credits (sends the Codex token)",
    "raw.githubusercontent.com": "remote model catalog (disabled: remoteRefreshEnabled = false)",
    "api.github.com": "update check (disabled: UpdateChecker.isEnabled = false)",
    "github.com": "links opened in the browser on a click (issues page, Codex docs)",
    "docs.anthropic.com": "link opened in the browser on a click (Claude Code docs)",
}

# These must stay off for the two GitHub hosts above to be unreachable.
REQUIRED_LINES = {
    "Sources/QuotaWarmer/Services/ModelCatalog.swift": "var remoteRefreshEnabled = false",
    "Sources/QuotaWarmer/Services/UpdateChecker.swift": "static let isEnabled = false",
}

root = pathlib.Path(__file__).resolve().parent.parent
url = re.compile(r"\b(?:https?|wss?)://([A-Za-z0-9.-]+)")
problems = []

for path in sorted((root / "Sources").rglob("*.swift")):
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        for host in url.findall(line):
            if host.lower() not in ALLOWED:
                problems.append(f"{path.relative_to(root)}:{number}: unlisted host {host}")

for name, needle in REQUIRED_LINES.items():
    if needle not in (root / name).read_text(encoding="utf-8"):
        problems.append(f"{name}: expected `{needle}`")

if problems:
    print("\n".join(problems))
    sys.exit(1)
print(f"ok: {len(ALLOWED)} allowed hosts, both remote features off")
