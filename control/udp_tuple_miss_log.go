package control

import (
	"fmt"
	"net/netip"
	"sync/atomic"
)

const shortLivedTupleMissSummaryEvery = uint64(300)

type tupleMissCounter struct {
	n atomic.Uint64
}

func isShortLivedUDPPort(port uint16) bool {
	switch port {
	case 53, 67, 68, 123, 161, 162, 1900, 5353, 51820:
		return true
	default:
		return false
	}
}

func (c *ControlPlane) recordShortLivedTupleMiss(dst netip.AddrPort) (emit bool, count uint64) {
	key := dst.String()
	v, _ := c.shortLivedTupleMissCounters.LoadOrStore(key, &tupleMissCounter{})
	counter := v.(*tupleMissCounter)
	count = counter.n.Add(1)
	if count == 1 || count%shortLivedTupleMissSummaryEvery == 0 {
		return true, count
	}
	return false, count
}

func shortLivedTupleMissSummaryMsg(total uint64) string {
	return fmt.Sprintf("UDP routing tuple missing; short-lived UDP fast path fallback (Total=%d)", total)
}
