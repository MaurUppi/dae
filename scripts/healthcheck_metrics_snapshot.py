#!/usr/bin/env python3
"""Poll dae health-check metrics: log every dialer's loop trajectory and flag stalls.

Two outputs are produced each run:

1. RAW time-series (``--raw-output``, on by default) -- one record per dialer per
   scrape: ``loopAdvancedAgeSeconds``, ``loopAdvancedAt``, ``inflightProbes``,
   ``maxProbeAttemptAgeSeconds``, ``goroutineGeneration``. This is the decisive
   #1026 §7.5 signal: a frozen loop keeps a CONSTANT ``loopAdvancedAt`` while its
   age climbs monotonically; a healthy loop's ``loopAdvancedAt`` jumps every
   ``check_interval``. The trajectory -- not a single reading -- tells single vs
   monotonic apart, and ``inflightProbes`` tells the subclass apart.

2. STALL events (``--output``) -- emitted only when a dialer trips one of two
   INDEPENDENT detectors (a single ``N x check_interval`` threshold is wrong --
   see issue-1026 §7):

   * BLOCK-A (loop frozen): ``loop_advanced_at`` unchanged across consecutive
     scrapes AND ``inflightProbes == 0`` AND ``loopAdvancedAge`` exceeds
     ``check_interval + probe_duration_ceiling``. The loop is wedged at the top
     select / tail, no probe in flight.
   * BLOCK-B (hung probe): ``inflightProbes > 0`` AND the probe PHASE has been
     open for longer than ``probe_duration_ceiling x probe_stall_multiplier``.
     Detection keys on probe elapsed (``last_probe_attempt_age``), NOT
     ``loopAdvancedAge`` -- during a healthy slow cycle inflight>0 and
     ``loopAdvancedAge`` is SUPPOSED to be high (that is §7's whole lesson; do
     not re-flag it).

     CAVEAT (untested -- pending raw data): probes for a dialer batch-submit at
     the start of the phase, so ``max(last_probe_attempt_age)`` measures the
     whole PHASE's elapsed time, NOT a single probe's. The threshold therefore
     has to exceed a healthy phase ceiling, not a single probe timeout (a 30s
     probe deadline x3 = 90s would re-flag every healthy mid-phase scrape whose
     phase legitimately runs ~220-300s -- the very §7 confound). To isolate ONE
     stuck probe the better signal is the attempt-age SPREAD (max-min) rather
     than the max; left as a follow-up because the current capture (all
     inflight==0 by censoring) cannot validate it.

   A healthy slow cycle (inflight>0, loopAdvancedAge just past check_interval,
   probe phase within its ceiling) is NOT emitted.
"""

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

# A scrape whose loop_advanced_at moved less than this (seconds) since the
# previous scrape is treated as "not advanced" (loop frozen). check_tolerance is
# 50ms by default, so a couple of seconds of slack is ample.
FREEZE_EPSILON_SECONDS = 2.0


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


def _max_age(*maps: dict[str, object]) -> float:
    values = [
        v
        for mapping in maps
        for v in mapping.values()
        if isinstance(v, (int, float))
    ]
    return max(values, default=-1.0)


def raw_record(dialer: str, snapshot: dict[str, object], *, now: float) -> dict[str, object]:
    """One time-series row for ANY dialer (healthy or not).

    ``loopAdvancedAt = now - loopAdvancedAge`` is the key derived field: it stays
    CONSTANT while a loop is frozen (age climbing) and jumps when the loop ticks.
    """
    loop_age = float(snapshot.get("loopAdvancedAgeSeconds", -1))
    attempts = snapshot.get("lastProbeAttemptAgeSeconds", {})
    return {
        "kind": "raw",
        "ts": now,
        "dialer": dialer,
        "loopAdvancedAgeSeconds": loop_age,
        "loopAdvancedAt": round(now - loop_age, 3) if loop_age >= 0 else None,
        "probeDoneAgeSeconds": float(snapshot.get("probeDoneAgeSeconds", -1)),
        "inflightProbes": int(snapshot.get("inflightProbes", 0)),
        "maxProbeAttemptAgeSeconds": _max_age(attempts),
        "checkActivated": bool(snapshot.get("checkActivated", 0)),
        "goroutineGeneration": int(snapshot.get("goroutineGeneration", 0)),
    }


def classify_snapshot(
    dialer: str,
    snapshot: dict[str, object],
    *,
    check_interval_seconds: float,
    probe_duration_ceiling_seconds: float,
    probe_stall_multiplier: float,
    history: dict[str, dict[str, float]],
    now: float,
) -> dict[str, object] | None:
    """Emit a snapshot only when a dialer trips one of two independent detectors.

    A healthy dialer -- including one in a healthy SLOW cycle (inflight>0,
    loopAdvancedAge just past check_interval, probe phase within its ceiling) --
    is NOT emitted.
    """
    attempts = snapshot.get("lastProbeAttemptAgeSeconds", {})
    successes = snapshot.get("lastProbeSuccessAgeSeconds", {})
    probe_heartbeat_age = _max_age(attempts, successes)
    # When a probe is in flight nothing rewrites lastProbeAttemptNs, so this is a
    # faithful proxy for the CURRENT probe's elapsed time.
    probe_elapsed_age = _max_age(attempts)

    loop_age = float(snapshot.get("loopAdvancedAgeSeconds", -1))
    done_age = float(snapshot.get("probeDoneAgeSeconds", -1))
    check_activated = bool(snapshot.get("checkActivated", 0))
    inflight = int(snapshot.get("inflightProbes", 0))
    generation = int(snapshot.get("goroutineGeneration", 0))

    # The healthy ceiling for the LOOP is check_interval + probe_duration, NOT
    # N x check_interval (issue-1026 §7). BLOCK-B keys on the probe PHASE, so its
    # threshold is the same probe-phase ceiling x a margin -- NOT a single 30s
    # probe deadline (max(attempt_age) ~= phase elapsed; see module CAVEAT).
    loop_health_ceiling = check_interval_seconds + probe_duration_ceiling_seconds
    probe_stall_threshold = probe_duration_ceiling_seconds * probe_stall_multiplier

    # Track loop_advanced_at wall time to confirm the loop is frozen (not advancing).
    loop_advanced_at = round(now - loop_age, 3) if loop_age >= 0 else None
    prev = history.get(dialer) or {}
    prev_loop_advanced_at = prev.get("loop_advanced_at")
    if loop_advanced_at is None or prev_loop_advanced_at is None or prev_loop_advanced_at < 0:
        loop_frozen_since_prev: bool | None = None
    else:
        loop_frozen_since_prev = (loop_advanced_at - prev_loop_advanced_at) <= FREEZE_EPSILON_SECONDS
    history[dialer] = {"loop_advanced_at": loop_advanced_at if loop_advanced_at is not None else -1.0}

    if not check_activated and generation >= 1:
        candidate = "H1_OR_H3"  # goroutine exited / never re-activated after running
    elif inflight > 0 and probe_stall_threshold > 0 and probe_elapsed_age > probe_stall_threshold:
        candidate = "H2_PROBE_INFLIGHT"  # hung probe (BLOCK-B): probe outlived its own timeout
    elif inflight == 0 and loop_frozen_since_prev is True and loop_age > loop_health_ceiling:
        candidate = "H2_LOOP_STALLED"  # BLOCK-A: loop frozen, no probe in flight
    else:
        return None  # healthy (incl. healthy-slow cycle)

    return {
        "kind": "stall",
        "ts": now,
        "dialer": dialer,
        "candidate": candidate,
        "checkIntervalSeconds": check_interval_seconds,
        "loopHealthCeilingSeconds": loop_health_ceiling,
        "probeStallThresholdSeconds": probe_stall_threshold,
        "loopAdvancedAgeSeconds": loop_age,
        "loopAdvancedRatioToInterval": round(loop_age / check_interval_seconds, 3)
        if check_interval_seconds > 0 and loop_age >= 0
        else None,
        "loopFrozenSincePrevScrape": loop_frozen_since_prev,
        "probeDoneAgeSeconds": done_age,
        "probeElapsedAgeSeconds": probe_elapsed_age,
        "probeHeartbeatAgeSeconds": probe_heartbeat_age,
        "checkActivated": check_activated,
        "inflightProbes": inflight,
        "lastProbeAttemptAgeSeconds": attempts,
        "lastProbeSuccessAgeSeconds": successes,
        "aliveSetRefCount": snapshot.get("aliveSetRefCount", {}),
        "goroutineGeneration": generation,
    }


def fetch_metrics(url: str, timeout: float) -> str:
    with urllib.request.urlopen(url, timeout=timeout) as response:
        return response.read().decode("utf-8", errors="replace")


def default_output_path() -> str:
    return time.strftime("healthcheck_metrics_snapshot_%Y%m%dT%H%M%S.jsonl", time.localtime())


def default_raw_output_path() -> str:
    return time.strftime("healthcheck_metrics_raw_%Y%m%dT%H%M%S.jsonl", time.localtime())


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--url", required=True, help="Prometheus metrics URL, for example http://127.0.0.1:2023/metrics")
    parser.add_argument(
        "--interval",
        type=float,
        default=10.0,
        help=(
            "Script polling cadence in seconds (how often /metrics is scraped). "
            "This is the SAMPLING rate only and is unrelated to dae's check_interval. "
            "Keep it well below check_interval (e.g. <= check_interval/4) so loop "
            "advancement is not missed. Default: 10."
        ),
    )
    parser.add_argument(
        "--check-interval",
        type=float,
        required=True,
        help=(
            "dae's configured check_interval in SECONDS -- MUST match the running "
            "dae config (global, or the per-group override for these dialers). The "
            "health-check loop advances once per check_interval. Example: 900."
        ),
    )
    parser.add_argument(
        "--probe-duration-ceiling",
        type=float,
        default=240.0,
        help=(
            "Upper bound (seconds) of a healthy probe PHASE. The loop's healthy "
            "ceiling is check_interval + this value, because ticker.Reset fires "
            "only AFTER wg.Wait (issue-1026 §7.1). MUST be calibrated PER DEPLOYMENT "
            "from the observed phase in the raw time-series (max loopAdvancedAge - "
            "check_interval): e.g. the 2026-06-24 CI=180s capture shows a ~304s "
            "phase, so 240 (a CI=900 default) would still false-flag -- use >=305 "
            "there. Default: 240 (a STARTING point, not a universal constant)."
        ),
    )
    parser.add_argument(
        "--probe-stall-multiplier",
        type=float,
        default=2.0,
        help=(
            "Hung-probe (BLOCK-B) margin k (default 2.0). Flagged when the in-flight "
            "probe PHASE elapsed exceeds probe_duration_ceiling x k. NOTE: keyed on "
            "the phase ceiling, not a single 30s probe deadline -- max(attempt_age) "
            "measures the whole phase (see module CAVEAT); BLOCK-B is untested "
            "pending a real inflight>0 capture."
        ),
    )
    parser.add_argument(
        "--output",
        default=None,
        help=(
            "Stall-event JSONL file. Default: healthcheck_metrics_snapshot_<ts>.jsonl. "
            "Only flagged (BLOCK-A / BLOCK-B / inactive) snapshots are appended."
        ),
    )
    parser.add_argument(
        "--raw-output",
        default=None,
        help=(
            "Raw time-series JSONL file (one row per dialer per scrape). Default: "
            "healthcheck_metrics_raw_<ts>.jsonl. Use --no-raw to disable."
        ),
    )
    parser.add_argument("--no-raw", action="store_true", help="Disable the raw time-series output")
    parser.add_argument("--timeout", type=float, default=5.0, help="HTTP timeout in seconds")
    parser.add_argument("--once", action="store_true", help="Poll once and exit")
    args = parser.parse_args(argv)

    if args.check_interval <= 0:
        parser.error("--check-interval must be positive (seconds)")

    output_path = args.output or default_output_path()
    raw_path = None if args.no_raw else (args.raw_output or default_raw_output_path())

    print(
        f"[healthcheck-snapshot] stall_output={output_path} raw_output={raw_path or '(disabled)'} "
        f"check_interval={args.check_interval}s loop_ceiling={args.check_interval + args.probe_duration_ceiling}s "
        f"probe_stall={args.probe_duration_ceiling * args.probe_stall_multiplier}s poll={args.interval}s",
        file=sys.stderr,
        flush=True,
    )

    history: dict[str, dict[str, float]] = {}
    raw_out = open(raw_path, "a", encoding="utf-8") if raw_path else None
    try:
        with open(output_path, "a", encoding="utf-8") as out:
            while True:
                now = time.time()
                snapshots = parse_prometheus_text(fetch_metrics(args.url, args.timeout))
                for dialer, snapshot in snapshots.items():
                    if raw_out is not None:
                        raw_out.write(json.dumps(raw_record(dialer, snapshot, now=now), sort_keys=True) + "\n")
                    event = classify_snapshot(
                        dialer,
                        snapshot,
                        check_interval_seconds=args.check_interval,
                        probe_duration_ceiling_seconds=args.probe_duration_ceiling,
                        probe_stall_multiplier=args.probe_stall_multiplier,
                        history=history,
                        now=now,
                    )
                    if event is not None:
                        out.write(json.dumps(event, sort_keys=True) + "\n")
                        out.flush()
                if raw_out is not None:
                    raw_out.flush()
                if args.once:
                    return 0
                time.sleep(args.interval)
    finally:
        if raw_out is not None:
            raw_out.close()


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
