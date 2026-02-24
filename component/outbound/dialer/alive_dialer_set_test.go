/*
 * SPDX-License-Identifier: AGPL-3.0-only
 * Copyright (c) 2022-2025, daeuniverse Organization <dae@v2raya.org>
 */

package dialer

import (
	"testing"
	"time"

	"github.com/daeuniverse/dae/common/consts"
)

func newSmartTestNetworkType() *NetworkType {
	return &NetworkType{
		L4Proto:   consts.L4ProtoStr_TCP,
		IpVersion: consts.IpVersionStr_4,
		IsDns:     false,
	}
}

func TestAliveDialerSet_GetSmartBest_PrefersLowerEffectiveLatency(t *testing.T) {
	networkType := newSmartTestNetworkType()
	d1 := newNamedTestDialer(t, "smart-d1")
	d2 := newNamedTestDialer(t, "smart-d2")

	set := NewAliveDialerSet(
		d1.Log,
		"smart-group",
		networkType,
		0,
		consts.DialerSelectionPolicy_Smart,
		[]*Dialer{d1, d2},
		[]*Annotation{{}, {}},
		func(bool) {},
		true,
	)

	col1 := d1.mustGetCollection(networkType)
	col1.MovingAverage = 100 * time.Millisecond
	col1.PenaltyPoints = 4.0 // effective = 500ms
	set.NotifyLatencyChange(d1, true)

	col2 := d2.mustGetCollection(networkType)
	col2.MovingAverage = 130 * time.Millisecond
	col2.PenaltyPoints = 0.0 // effective = 130ms
	set.NotifyLatencyChange(d2, true)

	best, score := set.GetSmartBest()
	if best == nil {
		t.Fatal("expected non-nil best dialer")
	}
	if best != d2 {
		t.Fatalf("unexpected best dialer: got=%s want=%s", best.Property().Name, d2.Property().Name)
	}
	if score != 130*time.Millisecond {
		t.Fatalf("unexpected best score: got=%v want=%v", score, 130*time.Millisecond)
	}
}

func TestAliveDialerSet_GetSmartBest_EffectiveLatencyOverflowBoundary(t *testing.T) {
	networkType := newSmartTestNetworkType()
	d := newNamedTestDialer(t, "smart-overflow")

	set := NewAliveDialerSet(
		d.Log,
		"smart-group",
		networkType,
		0,
		consts.DialerSelectionPolicy_Smart,
		[]*Dialer{d},
		[]*Annotation{{}},
		func(bool) {},
		true,
	)

	col := d.mustGetCollection(networkType)
	col.MovingAverage = Timeout
	col.PenaltyPoints = maxPenaltyPoints
	set.NotifyLatencyChange(d, true)

	best, score := set.GetSmartBest()
	if best != d {
		t.Fatal("expected the only dialer to be selected")
	}
	want := time.Duration(float64(Timeout) * (1 + maxPenaltyPoints))
	if score != want {
		t.Fatalf("unexpected effective latency: got=%v want=%v", score, want)
	}
	if score <= 0 {
		t.Fatalf("effective latency should be positive, got=%v", score)
	}
}
