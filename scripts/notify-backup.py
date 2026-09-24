#!/usr/bin/env python3
"""Send a Vaultwarden database backup result to Telegram via the Bot API."""

from __future__ import annotations

import os
import socket
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime
from html import escape
from typing import NamedTuple

TELEGRAM_API_BASE = "https://api.telegram.org"
REQUEST_TIMEOUT_SECONDS = 20


class StatusTheme(NamedTuple):
    """Presentation values for a backup result."""

    icon: str
    label: str
    summary: str


STATUS_THEMES: dict[str, StatusTheme] = {
    "success": StatusTheme(
        "✅",
        "Bitwarden: Backup Succeeded",
        "The Vaultwarden archive was created and synchronized to GCS successfully.",
    ),
    "failure": StatusTheme(
        "❌",
        "Bitwarden: Backup Failed",
        "The backup did not complete. Review the reason below and check the server log.",
    ),
}


def get_env_var(keys: list[str]) -> str:
    """Check a list of environment variable names and return the first non-empty value."""
    for key in keys:
        val = os.environ.get(key, "").strip()
        if val:
            return val
    return ""


def required_env(keys: list[str]) -> str:
    """Read a required non-empty environment variable from alternative keys."""
    val = get_env_var(keys)
    if not val:
        raise ValueError(f"Required environment variable missing: {', '.join(keys)}")
    return val


def detail_rows(detail: str) -> list[tuple[str, str]]:
    """Convert newline-delimited Label: Value details into display rows."""
    rows: list[tuple[str, str]] = []
    for line in detail.splitlines():
        line = line.strip()
        if not line:
            continue
        label, separator, value = line.partition(":")
        rows.append((label.strip() if separator else "Detail", value.strip() or label))
    return rows


def build_message(status: str, detail: str) -> str:
    """Build a Telegram HTML message for a backup result."""
    normalized_status = status.strip().lower()
    if normalized_status not in STATUS_THEMES:
        raise ValueError(f"Unknown backup notification status: {status}")

    host_name = socket.gethostname()
    occurred_at = datetime.now().astimezone()
    theme = STATUS_THEMES[normalized_status]

    rows = [
        ("Server", host_name),
        ("Time", f"{occurred_at:%Y-%m-%d %H:%M:%S %Z}"),
    ]
    rows.extend(detail_rows(detail))

    body_lines = [
        f"<b>{theme.icon} {escape(theme.label)}</b>",
        "",
        escape(theme.summary),
        "",
    ]
    body_lines.extend(f"<b>{escape(label)}:</b> {escape(value)}" for label, value in rows)
    body_lines.append("")
    body_lines.append("<i>Automated message from the Bitwarden backup service.</i>")
    return "\n".join(body_lines)


def send_message(text: str) -> None:
    """Deliver a message through the Telegram Bot API sendMessage endpoint."""
    token = required_env([
        "TELEGRAM_BOT_TOKEN",
        "BITWARDEN_TELEGRAM_BOT_TOKEN",
        "DOKAN_TELEGRAM_BOT_TOKEN",
        "TL_TELEGRAM_BOT_TOKEN",
    ])
    chat_id = required_env([
        "TELEGRAM_CHAT_ID",
        "BITWARDEN_TELEGRAM_CHAT_ID",
        "DOKAN_TELEGRAM_CHAT_ID",
        "TL_TELEGRAM_CHAT_ID",
    ])

    url = f"{TELEGRAM_API_BASE}/bot{token}/sendMessage"
    payload = urllib.parse.urlencode({
        "chat_id": chat_id,
        "text": text,
        "parse_mode": "HTML",
    }).encode("utf-8")

    request = urllib.request.Request(url, data=payload, method="POST")
    with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT_SECONDS) as response:
        if response.status != 200:
            raise RuntimeError(f"Telegram API returned HTTP {response.status}")


def main() -> int:
    """Validate arguments and send one backup notification."""
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <success|failure> <detail>", file=sys.stderr)
        return 2
    try:
        send_message(build_message(sys.argv[1], sys.argv[2]))
    except (urllib.error.URLError, RuntimeError, ValueError) as exc:
        print(f"Failed to send Telegram notification: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
