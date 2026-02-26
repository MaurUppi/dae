/*
 * SPDX-License-Identifier: AGPL-3.0-only
 * Copyright (c) 2022-2025, daeuniverse Organization <dae@daeuniverse.org>
 */

package control

import (
	"errors"
	"net/netip"
	"testing"
	"time"

	"github.com/sirupsen/logrus"
	"github.com/stretchr/testify/require"
)

func TestHandleFastPathWriteFailure_RemovesEndpoint(t *testing.T) {
	origPool := DefaultUdpEndpointPool
	pool := NewUdpEndpointPool()
	DefaultUdpEndpointPool = pool
	t.Cleanup(func() {
		DefaultUdpEndpointPool = origPool
	})

	realSrc := netip.MustParseAddrPort("10.0.0.2:5353")
	realDst := netip.MustParseAddrPort("1.1.1.1:443")

	ue := &UdpEndpoint{
		conn:       &stubPacketConn{},
		NatTimeout: time.Minute,
	}
	ue.RefreshTtl()
	pool.pool.Store(realSrc, ue)

	c := &ControlPlane{log: logrus.New()}
	err := c.handleFastPathWriteFailure(realSrc, realDst, ue, "example.com", errors.New("broken pipe"))
	require.Error(t, err)
	require.Contains(t, err.Error(), "quic-fp: write udp packet request")

	_, ok := pool.Get(realSrc)
	require.False(t, ok, "fast-path write failure should remove cached udp endpoint")
}
