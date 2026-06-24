#!/usr/bin/env python3
"""Extract UDP retry-limit evidence from dae logs."""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import subprocess
import sys


KEY_VALUE_RE = re.compile(r'(\w+)=("[^"]*"|\S+)')


def parse_plain_log_line(line: str) -> dict[str, object] | None:
    if "Touch max retry limit." not in line:
        return None
    record: dict[str, object] = {"msg": "Touch max retry limit."}
    for key, raw_value in KEY_VALUE_RE.findall(line):
        value = raw_value[1:-1] if raw_value.startswith('"') and raw_value.endswith('"') else raw_value
        record[key] = value
    return record


def parse_log_line(line: str) -> dict[str, object] | None:
    line = line.strip()
    if not line:
        return None
    try:
        record = json.loads(line)
    except json.JSONDecodeError:
        record = parse_plain_log_line(line)
    if not isinstance(record, dict):
        return None
    if record.get("msg") != "Touch max retry limit.":
        return None
    return normalize_record(record)


def normalize_record(record: dict[str, object]) -> dict[str, object]:
    attempted = record.get("attempted_dialers", [])
    if isinstance(attempted, str):
        attempted = [item for item in attempted.split(",") if item]
    retry = record.get("retry", 0)
    try:
        retry = int(retry)
    except (TypeError, ValueError):
        retry = 0
    return {
        "ts": record.get("time") or record.get("ts"),
        "src": record.get("src", ""),
        "network": record.get("network", ""),
        "final_dialer": record.get("dialer", ""),
        "retry": retry,
        "last_error": record.get("last_error", ""),
        "attempted_dialers": attempted,
        "last_probe_age_seconds": record.get("last_probe_age_seconds"),
        "last_probe_never_observed": bool(record.get("last_probe_never_observed", False)),
    }


def parse_log_file(path: pathlib.Path):
    with path.open("r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            record = parse_log_line(line)
            if record is not None:
                yield record


def parse_log_text(text: str):
    for line in text.splitlines():
        record = parse_log_line(line)
        if record is not None:
            yield record


def read_dae_journal(since: str | None = None) -> str:
    command = ["journalctl", "-u", "dae.service", "--no-pager", "-o", "cat"]
    if since:
        command.extend(["--since", since])
    completed = subprocess.run(
        command,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    return completed.stdout


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("since_arg", nargs="*", help='Journal start time, for example "2026-06-24 20:16:44"')
    parser.add_argument("--since", help='Journal start time, for example "2026-06-24 20:16:44"')
    parser.add_argument("--file", type=pathlib.Path, help="Read logs from a file instead of journalctl")
    args = parser.parse_args(argv)

    since_arg = " ".join(args.since_arg) if args.since_arg else None
    if since_arg and args.since:
        parser.error("provide either positional time or --since, not both")

    if args.file is not None:
        records = parse_log_file(args.file)
    else:
        records = parse_log_text(read_dae_journal(args.since or since_arg))

    for record in records:
        print(json.dumps(record, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
