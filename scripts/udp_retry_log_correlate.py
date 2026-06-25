#!/usr/bin/env python3
"""Extract UDP retry-limit evidence from dae logs.

dae emits the level and message only -- NO embedded timestamp (logrus prefixed
formatter with the timestamp disabled), e.g. a real captured line:

    WARN Touch max retry limit. attempted_dialers=[...] dialer=... network=udp4 ...

Because the message carries no timestamp, the only timestamp available comes from
journald's own envelope. ``read_dae_journal`` therefore requests ``-o short-iso``
(NOT ``-o cat``, which strips that timestamp), and ``parse_plain_log_line`` strips
the ``<iso-ts> <host> <ident>[<pid>]:`` prefix and keeps the captured timestamp.
A ``--file`` capture made with ``-o cat`` (no prefix) still parses -- every field
except ``ts`` survives.

That formatter does NOT quote field values containing spaces, and dae dialer
names contain spaces (e.g. "香港高级 IEPL 专线 1"). A space-joined Go slice such
as attempted_dialers=[香港高级 IEPL 专线 1 香港标准 IEPL 专线 2] is therefore
NOT recoverable into individual names from the text log -- the boundary parser
below recovers the full RAW value (so last_error, timestamps, etc. survive), but
attempted_dialers stays an opaque string and is surfaced as
``attempted_dialers_raw`` with ``attempted_dialers_parseable=false``.

To reliably reconstruct the attempted-dialer SEQUENCE (needed for #1029 B-1),
dae must emit a structured field: either switch logging to JSON, or join
attempted_dialers with a delimiter that cannot appear in a dialer name. Until
then B-1 cannot be proven from these logs. JSON input (one object per line) is
parsed directly and is fully faithful.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import subprocess
import sys
import time


# Known dae fields on the "Touch max retry limit." warning. Restricting the
# boundary parser to these keys avoids mis-splitting on a "key=" sequence that
# happens to appear inside a value (e.g. an error message).
KNOWN_KEYS = (
    "src",
    "network",
    "dialer",
    "retry",
    "last_error",
    "attempted_dialers",
    "last_probe_age_seconds",
    "last_probe_never_observed",
)
KEY_BOUNDARY_RE = re.compile(r"(?:^|\s)(" + "|".join(KNOWN_KEYS) + r")=")
ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")
# logrus-prefixed-formatter prefix: LEVEL[2006-01-02 15:04:05] message ...
# (kept as a fallback in case dae is ever reconfigured to embed a timestamp).
PREFIX_TS_RE = re.compile(r"^\s*[A-Za-z]+\[([^\]]+)\]")
# journald `-o short-iso` envelope prefix:
#   2026-06-24T22:17:33+0800 <hostname> <ident>[<pid>]: <dae message>
# The captured ISO timestamp is the only timestamp dae lines carry.
JOURNAL_PREFIX_RE = re.compile(
    r"^(?P<ts>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+\-]\d{2}:?\d{2})?)"
    r"\s+\S+\s+\S+?:\s"
)


def _strip_quotes(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {'"', "'"}:
        return value[1:-1]
    return value


def parse_plain_log_line(line: str) -> dict[str, object] | None:
    clean = ANSI_RE.sub("", line)

    # Strip the journald `-o short-iso` envelope, keeping its timestamp. dae's own
    # message has no timestamp, so this is the only ts source. A `-o cat` capture
    # has no such prefix and simply falls through (ts stays null).
    journal_ts: str | None = None
    journal_match = JOURNAL_PREFIX_RE.match(clean)
    if journal_match:
        journal_ts = journal_match.group("ts")
        clean = clean[journal_match.end():]

    if "Touch max retry limit." not in clean:
        return None
    record: dict[str, object] = {"msg": "Touch max retry limit."}

    # Prefer an embedded logrus timestamp if present; otherwise use journald's.
    ts_match = PREFIX_TS_RE.match(clean)
    if ts_match:
        record["time"] = ts_match.group(1).strip()
    elif journal_ts:
        record["time"] = journal_ts

    # Boundary parse: locate each known key and take its value as everything up
    # to the next known key. This recovers values that contain spaces, which the
    # prefixed formatter leaves unquoted.
    matches = list(KEY_BOUNDARY_RE.finditer(clean))
    for idx, match in enumerate(matches):
        key = match.group(1)
        value_start = match.end()
        value_end = matches[idx + 1].start() if idx + 1 < len(matches) else len(clean)
        record[key] = _strip_quotes(clean[value_start:value_end])
    return record


def parse_log_line(line: str) -> dict[str, object] | None:
    line = line.strip()
    if not line:
        return None
    try:
        record = json.loads(line)
        from_json = True
    except json.JSONDecodeError:
        record = parse_plain_log_line(line)
        from_json = False
    if not isinstance(record, dict):
        return None
    if record.get("msg") != "Touch max retry limit.":
        return None
    return normalize_record(record, from_json=from_json)


def normalize_record(record: dict[str, object], *, from_json: bool) -> dict[str, object]:
    attempted_raw = record.get("attempted_dialers", [])
    attempted: list[str] = []
    attempted_parseable = True
    if isinstance(attempted_raw, list):
        attempted = [str(item) for item in attempted_raw]
    elif isinstance(attempted_raw, str):
        stripped = attempted_raw.strip()
        if stripped.startswith("[") and " " in stripped:
            # Space-joined Go slice from the text formatter: opaque because dialer
            # names themselves contain spaces. Keep raw, do not guess a split.
            attempted_parseable = False
        elif stripped:
            # Best effort for delimited single-value or comma-joined strings.
            attempted = [item.strip() for item in stripped.strip("[]").split(",") if item.strip()]

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
        "attempted_dialers_raw": attempted_raw if not attempted_parseable else None,
        "attempted_dialers_parseable": attempted_parseable,
        "source_format": "json" if from_json else "text",
        "last_probe_age_seconds": record.get("last_probe_age_seconds"),
        "last_probe_never_observed": _coerce_bool(record.get("last_probe_never_observed", False)),
    }


def _coerce_bool(value: object) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        return value.strip().lower() in {"true", "1", "yes"}
    return bool(value)


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
    # `-o short-iso` keeps journald's timestamp (dae embeds none); `-o cat` drops it.
    command = ["journalctl", "-u", "dae.service", "--no-pager", "-o", "short-iso"]
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


def _sanitize_since(since: str | None) -> str:
    if not since:
        return time.strftime("%Y%m%dT%H%M%S", time.localtime())
    digits = re.sub(r"[^0-9]", "", since)
    # "2026-06-24 20:16:44" -> "20260624" + "T" + "201644"
    if len(digits) >= 14:
        return f"{digits[:8]}T{digits[8:14]}"
    return digits or time.strftime("%Y%m%dT%H%M%S", time.localtime())


def default_output_path(since: str | None) -> str:
    return f"udp_retry_log_{_sanitize_since(since)}.log"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("since_arg", nargs="*", help='Journal start time, for example "2026-06-24 20:16:44"')
    parser.add_argument("--since", help='Journal start time, for example "2026-06-24 20:16:44"')
    parser.add_argument("--file", type=pathlib.Path, help="Read logs from a file instead of journalctl")
    parser.add_argument(
        "--output",
        default=None,
        help=(
            "Output JSONL file. Default: udp_retry_log_<since>.log where <since> is "
            "the sanitized journal start time (e.g. udp_retry_log_20260624T201644.log), "
            "or the run start time when no --since is given."
        ),
    )
    args = parser.parse_args(argv)

    since_arg = " ".join(args.since_arg) if args.since_arg else None
    if since_arg and args.since:
        parser.error("provide either positional time or --since, not both")
    since = args.since or since_arg

    if args.file is not None:
        records = parse_log_file(args.file)
    else:
        records = parse_log_text(read_dae_journal(since))

    output_path = args.output or default_output_path(since)
    print(f"[udp-retry-correlate] output={output_path} since={since or '(journal default)'}", file=sys.stderr, flush=True)

    count = 0
    with open(output_path, "w", encoding="utf-8") as out:
        for record in records:
            out.write(json.dumps(record, sort_keys=True) + "\n")
            count += 1
    print(f"[udp-retry-correlate] wrote {count} record(s) to {output_path}", file=sys.stderr, flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
