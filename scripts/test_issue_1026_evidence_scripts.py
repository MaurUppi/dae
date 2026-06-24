#!/usr/bin/env python3

import importlib.util
import json
import pathlib
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


def load_script(name):
    path = ROOT / "scripts" / name
    spec = importlib.util.spec_from_file_location(path.stem, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class HealthcheckMetricsSnapshotTest(unittest.TestCase):
    def test_classifies_block_b_from_metrics_text(self):
        mod = load_script("healthcheck_metrics_snapshot.py")
        metrics = """
dae_healthcheck_check_activated{dialer="node-a"} 1
dae_healthcheck_goroutine_generation{dialer="node-a"} 2
dae_healthcheck_loop_advanced_age_seconds{dialer="node-a"} 1
dae_healthcheck_probe_done_age_seconds{dialer="node-a"} 120
dae_healthcheck_inflight_probes{dialer="node-a"} 1
dae_healthcheck_last_probe_attempt_age_seconds{dialer="node-a",networktype="tcp4"} 121
dae_healthcheck_last_probe_success_age_seconds{dialer="node-a",networktype="tcp4"} 600
dae_healthcheck_alive_set_refcount{dialer="node-a",collection="tcp4"} 1
"""

        snapshots = mod.parse_prometheus_text(metrics)
        event = mod.classify_snapshot("node-a", snapshots["node-a"], heartbeat_threshold_seconds=90)

        self.assertEqual(event["candidate"], "H2_BLOCK_B")
        self.assertEqual(event["dialer"], "node-a")
        self.assertEqual(event["inflightProbes"], 1)


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


if __name__ == "__main__":
    unittest.main()
