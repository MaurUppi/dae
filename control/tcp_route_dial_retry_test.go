/*
 * SPDX-License-Identifier: AGPL-3.0-only
 * Copyright (c) 2022-2025, daeuniverse Organization <dae@v2raya.org>
 */

package control

import (
	"context"
	"errors"
	"io"
	"net/netip"
	"sync"
	"testing"
	"time"

	"github.com/daeuniverse/dae/common/consts"
	"github.com/daeuniverse/dae/component/outbound"
	"github.com/daeuniverse/dae/component/outbound/dialer"
	odialer "github.com/daeuniverse/outbound/dialer"
	"github.com/daeuniverse/outbound/netproxy"
	"github.com/sirupsen/logrus"
)

type scriptedDialer struct {
	mu    sync.Mutex
	conn  netproxy.Conn
	err   error
	calls int
}

func (d *scriptedDialer) DialContext(context.Context, string, string) (netproxy.Conn, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.calls++
	if d.err != nil {
		return nil, d.err
	}
	if d.conn != nil {
		return d.conn, nil
	}
	return newMockConn(false, nil), nil
}

func (d *scriptedDialer) CallCount() int {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.calls
}

func newTestRouteDialer(t *testing.T, name string, impl netproxy.Dialer) *dialer.Dialer {
	t.Helper()
	log := logrus.New()
	log.SetOutput(io.Discard)
	d := dialer.NewDialer(
		impl,
		&dialer.GlobalOption{
			Log:            log,
			CheckInterval:  time.Minute,
			CheckTolerance: 0,
		},
		dialer.InstanceOption{DisableCheck: true},
		&dialer.Property{Property: odialer.Property{Name: name}},
	)
	t.Cleanup(func() {
		_ = d.Close()
	})
	return d
}

func newTestControlPlaneWithGroup(policy consts.DialerSelectionPolicy, dialers []*dialer.Dialer) *ControlPlane {
	log := logrus.New()
	log.SetOutput(io.Discard)
	group := outbound.NewDialerGroup(
		&dialer.GlobalOption{
			Log:            log,
			CheckInterval:  time.Minute,
			CheckTolerance: 0,
		},
		"test-group",
		dialers,
		func() []*dialer.Annotation {
			annotations := make([]*dialer.Annotation, len(dialers))
			for i := range annotations {
				annotations[i] = &dialer.Annotation{}
			}
			return annotations
		}(),
		outbound.DialerSelectionPolicy{Policy: policy},
		func(bool, *dialer.NetworkType, bool) {},
	)

	cp := &ControlPlane{
		log:           log,
		outbounds:     make([]*outbound.DialerGroup, int(consts.OutboundUserDefinedMin)+1),
		soMarkFromDae: 1,
		mptcp:         false,
	}
	cp.outbounds[consts.OutboundUserDefinedMin] = group
	return cp
}

func newTestRouteDialParam() *RouteDialParam {
	return &RouteDialParam{
		Outbound: consts.OutboundUserDefinedMin,
		Src:      netip.MustParseAddrPort("10.0.0.2:23456"),
		Dest:     netip.MustParseAddrPort("1.1.1.1:443"),
	}
}

func TestContainsDialer(t *testing.T) {
	d1 := &dialer.Dialer{}
	d2 := &dialer.Dialer{}
	if !containsDialer([]*dialer.Dialer{d1, d2}, d2) {
		t.Fatal("expected target dialer to be found")
	}
	if containsDialer([]*dialer.Dialer{d1}, d2) {
		t.Fatal("did not expect target dialer to be found")
	}
}

func TestRouteDialTcpRetry_Fallback(t *testing.T) {
	errD1 := errors.New("dialer-1 failed")
	impl1 := &scriptedDialer{err: errD1}
	impl2 := &scriptedDialer{conn: newMockConn(false, nil)}
	d1 := newTestRouteDialer(t, "d1", impl1)
	d2 := newTestRouteDialer(t, "d2", impl2)

	cp := newTestControlPlaneWithGroup(consts.DialerSelectionPolicy_MinLastLatency, []*dialer.Dialer{d1, d2})
	networkType := &dialer.NetworkType{L4Proto: consts.L4ProtoStr_TCP, IpVersion: consts.IpVersionStr_4, IsDns: false}
	d1.MustGetLatencies10(networkType).AppendLatency(10 * time.Millisecond)
	d2.MustGetLatencies10(networkType).AppendLatency(20 * time.Millisecond)
	group := cp.outbounds[consts.OutboundUserDefinedMin]
	group.MustGetAliveDialerSet(networkType).NotifyLatencyChange(d1, true)
	group.MustGetAliveDialerSet(networkType).NotifyLatencyChange(d2, true)

	conn, err := cp.RouteDialTcp(context.Background(), newTestRouteDialParam())
	if err != nil {
		t.Fatalf("expected fallback dial success, got error: %v", err)
	}
	if conn == nil {
		t.Fatal("expected non-nil connection")
	}
	_ = conn.Close()
	if impl1.CallCount() != 1 {
		t.Fatalf("unexpected dialer-1 call count: got=%d want=1", impl1.CallCount())
	}
	if impl2.CallCount() != 1 {
		t.Fatalf("unexpected dialer-2 call count: got=%d want=1", impl2.CallCount())
	}
}

func TestRouteDialTcpRetry_AllFailed(t *testing.T) {
	errD1 := errors.New("dialer-1 failed")
	errD2 := errors.New("dialer-2 failed")
	impl1 := &scriptedDialer{err: errD1}
	impl2 := &scriptedDialer{err: errD2}
	d1 := newTestRouteDialer(t, "d1", impl1)
	d2 := newTestRouteDialer(t, "d2", impl2)

	cp := newTestControlPlaneWithGroup(consts.DialerSelectionPolicy_MinLastLatency, []*dialer.Dialer{d1, d2})
	networkType := &dialer.NetworkType{L4Proto: consts.L4ProtoStr_TCP, IpVersion: consts.IpVersionStr_4, IsDns: false}
	d1.MustGetLatencies10(networkType).AppendLatency(10 * time.Millisecond)
	d2.MustGetLatencies10(networkType).AppendLatency(20 * time.Millisecond)
	group := cp.outbounds[consts.OutboundUserDefinedMin]
	group.MustGetAliveDialerSet(networkType).NotifyLatencyChange(d1, true)
	group.MustGetAliveDialerSet(networkType).NotifyLatencyChange(d2, true)

	_, err := cp.RouteDialTcp(context.Background(), newTestRouteDialParam())
	if !errors.Is(err, errD2) {
		t.Fatalf("expected last dial error to be returned, got: %v", err)
	}
	if impl1.CallCount() != 1 {
		t.Fatalf("unexpected dialer-1 call count: got=%d want=1", impl1.CallCount())
	}
	if impl2.CallCount() != 1 {
		t.Fatalf("unexpected dialer-2 call count: got=%d want=1", impl2.CallCount())
	}
}

func TestRouteDialTcpRetry_Dedup(t *testing.T) {
	errD1 := errors.New("dialer-1 failed")
	impl1 := &scriptedDialer{err: errD1}
	d1 := newTestRouteDialer(t, "d1", impl1)

	cp := newTestControlPlaneWithGroup(consts.DialerSelectionPolicy_Fixed, []*dialer.Dialer{d1})
	_, err := cp.RouteDialTcp(context.Background(), newTestRouteDialParam())
	if !errors.Is(err, errD1) {
		t.Fatalf("expected the first dial error to be returned, got: %v", err)
	}
	if impl1.CallCount() != 1 {
		t.Fatalf("dedup should avoid retrying the same dialer, got call count=%d", impl1.CallCount())
	}
}

func TestRouteDialTcpRetry_CanceledDoesNotPoisonDialer(t *testing.T) {
	impl1 := &scriptedDialer{err: context.Canceled}
	impl2 := &scriptedDialer{conn: newMockConn(false, nil)}
	d1 := newTestRouteDialer(t, "d1", impl1)
	d2 := newTestRouteDialer(t, "d2", impl2)

	cp := newTestControlPlaneWithGroup(consts.DialerSelectionPolicy_MinLastLatency, []*dialer.Dialer{d1, d2})
	networkType := &dialer.NetworkType{L4Proto: consts.L4ProtoStr_TCP, IpVersion: consts.IpVersionStr_4, IsDns: false}
	d1.MustGetLatencies10(networkType).AppendLatency(10 * time.Millisecond)
	d2.MustGetLatencies10(networkType).AppendLatency(20 * time.Millisecond)
	group := cp.outbounds[consts.OutboundUserDefinedMin]
	group.MustGetAliveDialerSet(networkType).NotifyLatencyChange(d1, true)
	group.MustGetAliveDialerSet(networkType).NotifyLatencyChange(d2, true)

	_, err := cp.RouteDialTcp(context.Background(), newTestRouteDialParam())
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("expected context canceled, got: %v", err)
	}
	if impl1.CallCount() != 1 {
		t.Fatalf("unexpected dialer-1 call count: got=%d want=1", impl1.CallCount())
	}
	if impl2.CallCount() != 0 {
		t.Fatalf("unexpected dialer-2 call count: got=%d want=0", impl2.CallCount())
	}
	if !d1.MustGetAlive(networkType) {
		t.Fatal("dialer should not be marked unavailable on context canceled")
	}
}
