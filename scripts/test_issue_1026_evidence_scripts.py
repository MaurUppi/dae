#!/usr/bin/env python3

import importlib.util
import json
import os
import pathlib
import subprocess
import tempfile
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[1]


def load_script(name):
    path = ROOT / "scripts" / name
    spec = importlib.util.spec_from_file_location(path.stem, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _metrics(
    *,
    dialer="node-a",
    activated=1,
    generation=1,
    loop_age,
    probe_done_age=120,
    inflight=0,
    attempt_age=10,
    success_age=600,
):
    return f"""
dae_healthcheck_check_activated{{dialer="{dialer}"}} {activated}
dae_healthcheck_goroutine_generation{{dialer="{dialer}"}} {generation}
dae_healthcheck_loop_advanced_age_seconds{{dialer="{dialer}"}} {loop_age}
dae_healthcheck_probe_done_age_seconds{{dialer="{dialer}"}} {probe_done_age}
dae_healthcheck_inflight_probes{{dialer="{dialer}"}} {inflight}
dae_healthcheck_last_probe_attempt_age_seconds{{dialer="{dialer}",networktype="tcp4"}} {attempt_age}
dae_healthcheck_last_probe_success_age_seconds{{dialer="{dialer}",networktype="tcp4"}} {success_age}
dae_healthcheck_alive_set_refcount{{dialer="{dialer}",collection="tcp4"}} 1
"""


# Calibration shared by the classifier tests. The whole §7 lesson is that the
# healthy ceiling for the LOOP is check_interval + probe_duration, NOT N x CI.
CI = 900.0
PROBE_CEILING = 240.0          # observed probe-phase upper bound
PROBE_STALL_MULT = 2.0         # BLOCK-B fires past probe_ceiling x k (phase-relative)
# Derived: loop ceiling = 1140s; probe-phase stall threshold = 480s.


def _classify(mod, snapshot, *, history, now, **over):
    kwargs = dict(
        check_interval_seconds=CI,
        probe_duration_ceiling_seconds=PROBE_CEILING,
        probe_stall_multiplier=PROBE_STALL_MULT,
        history=history,
        now=now,
    )
    kwargs.update(over)
    return mod.classify_snapshot("node-a", snapshot, **kwargs)


class RawTimeSeriesTest(unittest.TestCase):
    """The decisive §7.5 signal -- single-reading vs monotonic climb -- is the
    raw loopAdvancedAge trajectory of EVERY dialer EVERY scrape, not just stalls."""

    def test_raw_record_carries_loop_trajectory_for_any_dialer(self):
        mod = load_script("healthcheck_metrics_snapshot.py")
        snap = mod.parse_prometheus_text(_metrics(loop_age=1020, inflight=1, attempt_age=121))["node-a"]
        rec = mod.raw_record("node-a", snap, now=10_000.0)

        self.assertEqual(rec["dialer"], "node-a")
        self.assertEqual(rec["kind"], "raw")
        self.assertEqual(rec["loopAdvancedAgeSeconds"], 1020.0)
        # loopAdvancedAt = now - age, so a frozen loop keeps a CONSTANT value
        # across scrapes (monotonic age) while a healthy loop's value jumps.
        self.assertEqual(rec["loopAdvancedAt"], round(10_000.0 - 1020.0, 3))
        self.assertEqual(rec["inflightProbes"], 1)
        self.assertEqual(rec["maxProbeAttemptAgeSeconds"], 121.0)


class ClassifierTwoDetectorTest(unittest.TestCase):
    def test_healthy_slow_cycle_is_not_flagged(self):
        """inflight>0 with loopAdvancedAge just past CI is a healthy slow cycle
        (§7.3 'slow not dead'), NOT a stall -- must return None."""
        mod = load_script("healthcheck_metrics_snapshot.py")
        snap = mod.parse_prometheus_text(
            _metrics(loop_age=CI * 1.1, inflight=1, attempt_age=20)
        )["node-a"]
        event = _classify(mod, snap, history={}, now=10_000.0)
        self.assertIsNone(event)

    def test_block_a_requires_frozen_and_no_inflight(self):
        """BLOCK-A: loop frozen across scrapes, no probe in flight, age beyond
        CI + probe ceiling."""
        mod = load_script("healthcheck_metrics_snapshot.py")
        history = {}
        # First scrape primes history (frozen is unknowable yet -> not flagged).
        snap1 = mod.parse_prometheus_text(_metrics(loop_age=1200, inflight=0, attempt_age=1200))["node-a"]
        self.assertIsNone(_classify(mod, snap1, history=history, now=10_000.0))
        # Second scrape 10s later: loop_advanced_at unchanged -> frozen.
        snap2 = mod.parse_prometheus_text(_metrics(loop_age=1210, inflight=0, attempt_age=1210))["node-a"]
        event = _classify(mod, snap2, history=history, now=10_010.0)
        self.assertIsNotNone(event)
        self.assertEqual(event["candidate"], "H2_LOOP_STALLED")
        self.assertTrue(event["loopFrozenSincePrevScrape"])
        self.assertEqual(event["inflightProbes"], 0)

    def test_hung_probe_flagged_by_probe_phase_not_loop_age(self):
        """Hung probe (BLOCK-B): inflight>0 AND the probe PHASE has outrun
        probe_ceiling x multiplier (480s here). Detection keys on probe-phase
        elapsed, NOT loopAge -- so a modest loop_age still trips it."""
        mod = load_script("healthcheck_metrics_snapshot.py")
        # attempt_age 500 > 240*2=480 -> hung; loop_age deliberately modest.
        snap = mod.parse_prometheus_text(
            _metrics(loop_age=210, inflight=1, attempt_age=500)
        )["node-a"]
        event = _classify(mod, snap, history={}, now=10_000.0)
        self.assertIsNotNone(event)
        self.assertEqual(event["candidate"], "H2_PROBE_INFLIGHT")
        self.assertEqual(event["inflightProbes"], 1)

    def test_healthy_long_probe_phase_is_not_flagged_as_hung(self):
        """The §7 confound guard: a healthy phase running ~300s (inflight>0,
        attempt_age below probe_ceiling x k) must NOT be mistaken for a hung
        probe. max(attempt_age) ~= phase elapsed, not a single probe."""
        mod = load_script("healthcheck_metrics_snapshot.py")
        snap = mod.parse_prometheus_text(
            _metrics(loop_age=300, inflight=1, attempt_age=300)
        )["node-a"]
        self.assertIsNone(_classify(mod, snap, history={}, now=10_000.0))

    def test_inactive_loop_flagged_only_after_generation(self):
        mod = load_script("healthcheck_metrics_snapshot.py")
        snap = mod.parse_prometheus_text(
            _metrics(activated=0, generation=1, loop_age=-1, inflight=0)
        )["node-a"]
        event = _classify(mod, snap, history={}, now=10_000.0)
        self.assertIsNotNone(event)
        self.assertEqual(event["candidate"], "H1_OR_H3")


class UdpRetryLogCorrelateTest(unittest.TestCase):
    def test_parses_enriched_warning_json(self):
        mod = load_script("udp_retry_log_correlate.py")
        line = json.dumps(
            {
                "time": "2026-06-24T10:00:00Z",
                "level": "warning",
                "msg": "Touch max retry limit.",
                "src": "192.0.2.10:54321",
                "network": "udp4",
                "dialer": "dead-a",
                "retry": 3,
                "last_error": "write udp: network unreachable",
                "attempted_dialers": ["dead-a", "dead-b", "dead-a"],
                "last_probe_age_seconds": 1020,
            }
        )

        with tempfile.NamedTemporaryFile("w+", encoding="utf-8") as fh:
            fh.write(line + "\n")
            fh.flush()
            records = list(mod.parse_log_file(pathlib.Path(fh.name)))

        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]["attempted_dialers"], ["dead-a", "dead-b", "dead-a"])
        self.assertEqual(records[0]["last_error"], "write udp: network unreachable")

    def test_cli_reads_dae_journal_with_short_iso(self):
        mod = load_script("udp_retry_log_correlate.py")
        line = json.dumps(
            {
                "msg": "Touch max retry limit.",
                "src": "192.0.2.20:54321",
                "network": "udp4",
                "dialer": "dead-b",
                "retry": 2,
                "attempted_dialers": ["dead-a", "dead-b"],
            }
        )
        completed = mock.Mock(stdout=line + "\n")

        old_cwd = pathlib.Path.cwd()
        with tempfile.TemporaryDirectory() as tmpdir:
            os.chdir(tmpdir)
            try:
                with mock.patch.object(subprocess, "run", return_value=completed) as run, mock.patch("builtins.print"):
                    exit_code = mod.main(["2026-06-24 20:16:44"])
            finally:
                os.chdir(old_cwd)

        self.assertEqual(exit_code, 0)
        # dae embeds no timestamp -> journald's -o short-iso is the only ts source.
        run.assert_called_once_with(
            ["journalctl", "-u", "dae.service", "--no-pager", "-o", "short-iso", "--since", "2026-06-24 20:16:44"],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )


if __name__ == "__main__":
    unittest.main()
