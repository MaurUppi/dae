/*
 *  SPDX-License-Identifier: AGPL-3.0-only
 *  Copyright (c) 2022-2025, daeuniverse Organization <dae@daeuniverse.org>
 */

package control

import (
	"net/netip"
	"testing"
)

func newTestQueue(p *UdpTaskPool, key netip.AddrPort) *UdpTaskQueue {
	return &UdpTaskQueue{
		key:       key,
		p:         p,
		ch:        make(chan UdpTask, 1),
		wake:      make(chan struct{}, 1),
		agingTime: UdpTaskPoolAgingTime,
	}
}

// Regression: tryDeleteQueue must not delete a recreated queue for the same key.
func TestUdpTaskPoolTryDeleteQueue_DoesNotDeleteRecreatedQueue(t *testing.T) {
	p := NewUdpTaskPool()
	key := netip.MustParseAddrPort("192.0.2.1:443")

	oldQ := newTestQueue(p, key)
	newQ := newTestQueue(p, key)
	p.queues.Store(key, newQ)

	if p.tryDeleteQueue(key, oldQ) {
		t.Fatal("tryDeleteQueue should return false for stale queue pointer")
	}
	got, ok := p.queues.Load(key)
	if !ok {
		t.Fatal("recreated queue was deleted unexpectedly")
	}
	if got != newQ {
		t.Fatalf("queue pointer mismatch: got=%p want=%p", got, newQ)
	}
}

// Regression: when acquireQueue sees a draining queue, it must only delete if mapping is unchanged.
func TestUdpTaskPoolAcquireQueueDrainingDeletePath_UsesCASDelete(t *testing.T) {
	p := NewUdpTaskPool()
	key := netip.MustParseAddrPort("192.0.2.2:443")

	drainingQ := newTestQueue(p, key)
	drainingQ.draining.Store(true)
	recreatedQ := newTestQueue(p, key)
	p.queues.Store(key, recreatedQ)

	// This models the acquireQueue draining path deletion semantic.
	p.tryDeleteQueue(key, drainingQ)

	got, ok := p.queues.Load(key)
	if !ok {
		t.Fatal("recreated queue was deleted unexpectedly")
	}
	if got != recreatedQ {
		t.Fatalf("queue pointer mismatch: got=%p want=%p", got, recreatedQ)
	}
}
