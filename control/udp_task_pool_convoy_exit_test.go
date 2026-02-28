/*
 *  SPDX-License-Identifier: AGPL-3.0-only
 *  Copyright (c) 2022-2025, daeuniverse Organization <dae@daeuniverse.org>
 */

package control

import (
	"net/netip"
	"testing"
	"time"
)

// Regression guard:
// When queue mapping is removed before convoy self-delete, the old convoy
// must exit instead of looping forever outside the queue map.
func TestConvoyExitsWhenQueueMappingDeletedBeforeSelfDelete(t *testing.T) {
	oldAging := UdpTaskPoolAgingTime
	UdpTaskPoolAgingTime = 20 * time.Millisecond
	defer func() { UdpTaskPoolAgingTime = oldAging }()

	pool := NewUdpTaskPool()
	key := netip.MustParseAddrPort("198.51.100.10:443")
	q := newTestQueue(pool, key)
	q.agingTime = UdpTaskPoolAgingTime
	pool.queues.Store(key, q)

	done := make(chan struct{})
	go func() {
		q.convoy()
		close(done)
	}()

	// Wait until convoy reaches draining state.
	deadline := time.Now().Add(2 * time.Second)
	for !q.draining.Load() && time.Now().Before(deadline) {
		time.Sleep(1 * time.Millisecond)
	}
	if !q.draining.Load() {
		t.Fatal("convoy did not enter draining state in time")
	}

	// Simulate concurrent path deleting map entry first (acquireQueue draining path).
	if !pool.tryDeleteQueue(key, q) {
		t.Fatal("expected initial delete to succeed")
	}
	if got := pool.Count(); got != 0 {
		t.Fatalf("expected queue map to be empty, got count=%d", got)
	}

	// Old convoy should exit within one cleanup cycle.
	select {
	case <-done:
		// Expected: clean exit after failed self-delete with stale/absent mapping.
	case <-time.After(UdpTaskPoolAgingTime + 120*time.Millisecond):
		// Cleanup to avoid leaking goroutine into other tests, then fail.
		pool.queues.Store(key, q)
		select {
		case <-done:
		case <-time.After(1 * time.Second):
			t.Fatal("convoy did not exit during cleanup after timeout")
		}
		t.Fatal("convoy did not exit after mapping was deleted before self-delete")
	}
}
