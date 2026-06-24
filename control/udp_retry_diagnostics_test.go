/*
 * SPDX-License-Identifier: AGPL-3.0-only
 * Copyright (c) 2026, daeuniverse Organization <dae@v2raya.org>
 */

package control

import (
	"errors"
	"net/netip"
	"testing"
	"time"
)

func TestUdpRetryLimitLogFieldsIncludeEvidence(t *testing.T) {
	src := netip.MustParseAddrPort("192.0.2.10:54321")
	dst := netip.MustParseAddrPort("198.51.100.20:443")
	fields := udpRetryLimitLogFields(udpRetryLimitDiagnostic{
		Source:                 src,
		Destination:            dst.Addr(),
		Network:                "udp4",
		FinalDialer:            "dead-a",
		Retry:                  3,
		LastWriteError:         errors.New("write udp: network unreachable"),
		AttemptedDialers:       []string{"dead-a", "dead-b", "dead-a"},
		LastProbeAge:           17 * time.Minute,
		LastProbeNeverObserved: false,
	})

	if fields["src"] != RefineSourceToShow(src, dst.Addr()) {
		t.Fatalf("src = %v, want refined source", fields["src"])
	}
	if fields["network"] != "udp4" {
		t.Fatalf("network = %v, want udp4", fields["network"])
	}
	if fields["dialer"] != "dead-a" {
		t.Fatalf("dialer = %v, want dead-a", fields["dialer"])
	}
	if fields["retry"] != 3 {
		t.Fatalf("retry = %v, want 3", fields["retry"])
	}
	if fields["last_error"] != "write udp: network unreachable" {
		t.Fatalf("last_error = %v", fields["last_error"])
	}
	if got := fields["attempted_dialers"]; got == nil {
		t.Fatal("attempted_dialers field missing")
	}
	if fields["last_probe_age_seconds"] != float64((17 * time.Minute).Seconds()) {
		t.Fatalf("last_probe_age_seconds = %v", fields["last_probe_age_seconds"])
	}
}

func TestUdpRetryLimitLogFieldsMarkNeverProbed(t *testing.T) {
	fields := udpRetryLimitLogFields(udpRetryLimitDiagnostic{
		Source:                 netip.MustParseAddrPort("192.0.2.10:54321"),
		Destination:            netip.MustParseAddr("198.51.100.20"),
		Network:                "udp4",
		FinalDialer:            "dead-a",
		Retry:                  3,
		LastProbeNeverObserved: true,
	})

	if fields["last_probe_age_seconds"] != -1.0 {
		t.Fatalf("last_probe_age_seconds = %v, want -1", fields["last_probe_age_seconds"])
	}
	if fields["last_probe_never_observed"] != true {
		t.Fatalf("last_probe_never_observed = %v, want true", fields["last_probe_never_observed"])
	}
}
