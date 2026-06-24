/*
 * SPDX-License-Identifier: AGPL-3.0-only
 * Copyright (c) 2026, daeuniverse Organization <dae@v2raya.org>
 */

package control

import (
	"net/netip"
	"time"

	"github.com/sirupsen/logrus"
)

type udpRetryLimitDiagnostic struct {
	Source                 netip.AddrPort
	Destination            netip.Addr
	Network                string
	FinalDialer            string
	Retry                  int
	LastWriteError         error
	AttemptedDialers       []string
	LastProbeAge           time.Duration
	LastProbeNeverObserved bool
}

func udpRetryLimitLogFields(diag udpRetryLimitDiagnostic) logrus.Fields {
	fields := logrus.Fields{
		"src":                    RefineSourceToShow(diag.Source, diag.Destination),
		"network":                diag.Network,
		"dialer":                 diag.FinalDialer,
		"retry":                  diag.Retry,
		"attempted_dialers":      diag.AttemptedDialers,
		"last_probe_age_seconds": diag.LastProbeAge.Seconds(),
	}
	if diag.LastWriteError != nil {
		fields["last_error"] = diag.LastWriteError.Error()
	}
	if diag.LastProbeNeverObserved {
		fields["last_probe_age_seconds"] = -1.0
		fields["last_probe_never_observed"] = true
	}
	return fields
}
