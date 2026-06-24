#!/usr/bin/env python3
"""Poll dae health-check metrics and emit diagnostic snapshots."""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
import urllib.request
from collections import defaultdict


SAMPLE_RE = re.compile(r"^([a-zA-Z_:][a-zA-Z0-9_:]*)(?:\{([^}]*)\})?\s+([-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?)$")
LABEL_RE = re.compile(r'([a-zA-Z_][a-zA-Z0-9_]*)="((?:\\.|[^"])*)"')


def parse_labels(raw: str | None) -> dict[str, str]:
    if not raw:
        return {}
    labels: dict[str, str] = {}
    for key, value in LABEL_RE.findall(raw):
        labels[key] = value.replace(r"\"", '"').replace(r"\\", "\\")
    return labels


def parse_prometheus_text(text: str) -> dict[str, dict[str, object]]:
    snapshots: dict[str, dict[str, object]] = defaultdict(
        lambda: {
            "lastProbeAttemptAgeSeconds": {},
            "lastProbeSuccessAgeSeconds": {},
            "aliveSetRefCount": {},
        }
    )
    scalar_map = {
        "dae_healthcheck_check_activated": "checkActivated",
        "dae_healthcheck_goroutine_generation": "goroutineGeneration",
        "dae_healthcheck_loop_advanced_age_seconds": "loopAdvancedAgeSeconds",
        "dae_healthcheck_probe_done_age_seconds": "probeDoneAgeSeconds",
        "dae_healthcheck_inflight_probes": "inflightProbes",
    }
    per_type_map = {
        "dae_healthcheck_last_probe_attempt_age_seconds": ("networktype", "lastProbeAttemptAgeSeconds"),
        "dae_healthcheck_last_probe_success_age_seconds": ("networktype", "lastProbeSuccessAgeSeconds"),
        "dae_healthcheck_alive_set_refcount": ("collection", "aliveSetRefCount"),
    }

    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        match = SAMPLE_RE.match(line)
        if not match:
            continue
        name, raw_labels, raw_value = match.groups()
        labels = parse_labels(raw_labels)
        dialer = labels.get("dialer")
        if not dialer:
            continue
        value = float(raw_value)
        snapshot = snapshots[dialer]
        if name in scalar_map:
            key = scalar_map[name]
            snapshot[key] = int(value) if key in {"goroutineGeneration", "inflightProbes"} else value
        elif name in per_type_map:
            label_name, key = per_type_map[name]
            label_value = labels.get(label_name, "")
            snapshot[key][label_value] = value
    return dict(snapshots)


def classify_snapshot(dialer: str, snapshot: dict[str, object], heartbeat_threshold_seconds: float) -> dict[str, object] | None:
    attempts = snapshot.get("lastProbeAttemptAgeSeconds", {})
    successes = snapshot.get("lastProbeSuccessAgeSeconds", {})
    probe_heartbeat_age = max(
        [v for v in list(attempts.values()) + list(successes.values()) if isinstance(v, (int, float))],
        default=-1,
    )
    if probe_heartbeat_age < heartbeat_threshold_seconds:
        return None

    check_activated = bool(snapshot.get("checkActivated", 0))
    inflight = int(snapshot.get("inflightProbes", 0))
    loop_age = float(snapshot.get("loopAdvancedAgeSeconds", -1))
    done_age = float(snapshot.get("probeDoneAgeSeconds", -1))
    candidate = "UNKNOWN"
    if not check_activated:
        candidate = "H1_OR_H3"
    elif inflight > 0 and done_age >= heartbeat_threshold_seconds:
        candidate = "H2_BLOCK_B"
    elif inflight == 0 and loop_age >= heartbeat_threshold_seconds and done_age >= heartbeat_threshold_seconds:
        candidate = "H2_BLOCK_A"
    elif check_activated:
        candidate = "NON_LIFECYCLE_FAILURE"

    return {
        "ts": time.time(),
        "dialer": dialer,
        "candidate": candidate,
        "probeHeartbeatAgeSeconds": probe_heartbeat_age,
        "checkActivated": check_activated,
        "loopAdvancedAgeSeconds": loop_age,
        "probeDoneAgeSeconds": done_age,
        "inflightProbes": inflight,
        "lastProbeAttemptAgeSeconds": attempts,
        "lastProbeSuccessAgeSeconds": successes,
        "aliveSetRefCount": snapshot.get("aliveSetRefCount", {}),
        "goroutineGeneration": snapshot.get("goroutineGeneration", 0),
    }


def fetch_metrics(url: str, timeout: float) -> str:
    with urllib.request.urlopen(url, timeout=timeout) as response:
        return response.read().decode("utf-8", errors="replace")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", required=True, help="Prometheus metrics URL, for example http://127.0.0.1:2023/metrics")
    parser.add_argument("--interval", type=float, default=10.0, help="Polling interval in seconds")
    parser.add_argument("--threshold", type=float, required=True, help="Heartbeat age threshold in seconds")
    parser.add_argument("--timeout", type=float, default=5.0, help="HTTP timeout in seconds")
    parser.add_argument("--once", action="store_true", help="Poll once and exit")
    args = parser.parse_args(argv)

    while True:
        snapshots = parse_prometheus_text(fetch_metrics(args.url, args.timeout))
        for dialer, snapshot in snapshots.items():
            event = classify_snapshot(dialer, snapshot, args.threshold)
            if event is not None:
                print(json.dumps(event, sort_keys=True), flush=True)
        if args.once:
            return 0
        time.sleep(args.interval)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
