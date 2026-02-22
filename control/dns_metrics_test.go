/*
 * SPDX-License-Identifier: AGPL-3.0-only
 * Copyright (c) 2022-2025, daeuniverse Organization <dae@v2raya.org>
 */

package control

import (
	"context"
	"errors"
	"math"
	"net"
	"testing"

	componentdns "github.com/daeuniverse/dae/component/dns"
	dnsmessage "github.com/miekg/dns"
	"github.com/sirupsen/logrus"
)

type noopDNSResponseWriter struct{}

func (w *noopDNSResponseWriter) LocalAddr() net.Addr  { return nil }
func (w *noopDNSResponseWriter) RemoteAddr() net.Addr { return nil }
func (w *noopDNSResponseWriter) WriteMsg(*dnsmessage.Msg) error {
	return nil
}
func (w *noopDNSResponseWriter) Write(b []byte) (int, error) { return len(b), nil }
func (w *noopDNSResponseWriter) Close() error                { return nil }
func (w *noopDNSResponseWriter) TsigStatus() error           { return nil }
func (w *noopDNSResponseWriter) TsigTimersOnly(bool)         {}
func (w *noopDNSResponseWriter) Hijack()                     {}

type testForwarder struct {
	calls int
}

func (f *testForwarder) ForwardDNS(context.Context, []byte) (*dnsmessage.Msg, error) {
	f.calls++
	if f.calls == 2 {
		return nil, errors.New("upstream failure")
	}
	return &dnsmessage.Msg{}, nil
}

func (f *testForwarder) Close() error { return nil }

func TestDnsLatencyHistogramSnapshotMonotonic(t *testing.T) {
	h := newDnsLatencyHistogram()
	h.Observe(0.001)
	h.Observe(0.2)
	h.Observe(6)

	snapshot := h.Snapshot()
	if snapshot.Count != 3 {
		t.Fatalf("unexpected histogram count: got=%d want=3", snapshot.Count)
	}
	expectedSum := 6.201
	if diff := math.Abs(snapshot.Sum - expectedSum); diff > 1e-9 {
		t.Fatalf("unexpected histogram sum: got=%f want=%f diff=%f", snapshot.Sum, expectedSum, diff)
	}

	var prev uint64
	for i, bound := range dnsLatencyHistogramBounds {
		cur := snapshot.Buckets[bound]
		if i > 0 && cur < prev {
			t.Fatalf("histogram cumulative buckets must be monotonic: bound=%f cur=%d prev=%d", bound, cur, prev)
		}
		prev = cur
	}
	lastBound := dnsLatencyHistogramBounds[len(dnsLatencyHistogramBounds)-1]
	if got := snapshot.Buckets[lastBound]; got != 2 {
		t.Fatalf("unexpected last finite bucket count: got=%d want=2", got)
	}
}

func TestDnsController_RejectAndRefusedCounters(t *testing.T) {
	c := &DnsController{}
	writer := &noopDNSResponseWriter{}

	rejectMsg := new(dnsmessage.Msg)
	rejectMsg.SetQuestion("reject.example.", dnsmessage.TypeA)
	if err := c.sendRejectWithResponseWriter_(rejectMsg, nil, writer); err != nil {
		t.Fatalf("sendRejectWithResponseWriter_: %v", err)
	}

	refuseMsg := new(dnsmessage.Msg)
	refuseMsg.SetQuestion("refuse.example.", dnsmessage.TypeA)
	if err := c.sendRefusedWithResponseWriter_(refuseMsg, nil, writer); err != nil {
		t.Fatalf("sendRefusedWithResponseWriter_: %v", err)
	}

	counters := c.DnsCountersSnapshot()
	if counters.RejectedTotal != 1 {
		t.Fatalf("unexpected rejected counter: got=%d want=1", counters.RejectedTotal)
	}
	if counters.RefusedTotal != 1 {
		t.Fatalf("unexpected refused counter: got=%d want=1", counters.RefusedTotal)
	}
}

func TestDnsController_ForwardWithDialArgMetrics(t *testing.T) {
	origFactory := dnsForwarderFactory
	defer func() {
		dnsForwarderFactory = origFactory
	}()

	forwarder := &testForwarder{}
	dnsForwarderFactory = func(*componentdns.Upstream, dialArgument, *logrus.Logger) (DnsForwarder, error) {
		return forwarder, nil
	}

	c := &DnsController{}
	upstream := &componentdns.Upstream{
		Scheme:   componentdns.UpstreamScheme_UDP,
		Hostname: "1.1.1.1",
		Port:     53,
	}
	dialArg := &dialArgument{}

	if _, err := c.forwardWithDialArg(context.Background(), upstream, dialArg, []byte("q1")); err != nil {
		t.Fatalf("first forwardWithDialArg should succeed: %v", err)
	}
	if _, err := c.forwardWithDialArg(context.Background(), upstream, dialArg, []byte("q2")); err == nil {
		t.Fatal("second forwardWithDialArg should fail")
	}

	upstreamSnapshot := c.DnsUpstreamSnapshot()
	entry, ok := upstreamSnapshot[upstream.String()]
	if !ok {
		t.Fatalf("missing upstream snapshot for %q", upstream.String())
	}
	if entry.QueryTotal != 2 {
		t.Fatalf("unexpected upstream query total: got=%d want=2", entry.QueryTotal)
	}
	if entry.ErrTotal != 1 {
		t.Fatalf("unexpected upstream err total: got=%d want=1", entry.ErrTotal)
	}
	if entry.Latency.Count != 2 {
		t.Fatalf("unexpected upstream latency count: got=%d want=2", entry.Latency.Count)
	}

	counters := c.DnsCountersSnapshot()
	if counters.UpstreamQueryTotal != 2 {
		t.Fatalf("unexpected total upstream query counter: got=%d want=2", counters.UpstreamQueryTotal)
	}
	if counters.UpstreamErrTotal != 1 {
		t.Fatalf("unexpected total upstream error counter: got=%d want=1", counters.UpstreamErrTotal)
	}
}

func TestDnsController_HandleWithResponseWriterCountsQuery(t *testing.T) {
	c := &DnsController{}
	msg := new(dnsmessage.Msg)
	msg.SetQuestion("query.example.", dnsmessage.TypeA)

	if err := c.HandleWithResponseWriter_(context.Background(), msg, nil, nil); err == nil {
		t.Fatal("expected error when routing is nil")
	}

	counters := c.DnsCountersSnapshot()
	if counters.QueryTotal != 1 {
		t.Fatalf("unexpected query total: got=%d want=1", counters.QueryTotal)
	}
	latency := c.DnsResponseLatencySnapshot()
	if latency.Count != 1 {
		t.Fatalf("unexpected response latency count: got=%d want=1", latency.Count)
	}
}
