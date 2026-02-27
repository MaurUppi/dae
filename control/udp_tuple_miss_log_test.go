package control

import (
	"net/netip"
	"testing"
)

func TestIsShortLivedUDPPort(t *testing.T) {
	cases := []struct {
		port uint16
		want bool
	}{
		{port: 53, want: true},
		{port: 123, want: true},
		{port: 161, want: true},
		{port: 5353, want: true},
		{port: 51820, want: true},
		{port: 443, want: false},
		{port: 9999, want: false},
	}

	for _, tt := range cases {
		got := isShortLivedUDPPort(tt.port)
		if got != tt.want {
			t.Fatalf("port %d: got %v, want %v", tt.port, got, tt.want)
		}
	}
}

func TestRecordShortLivedTupleMiss_SummaryEveryConfiguredInterval(t *testing.T) {
	cp := &ControlPlane{}
	dst := netip.MustParseAddrPort("192.168.1.15:53")

	emit, count := cp.recordShortLivedTupleMiss(dst)
	if !emit || count != 1 {
		t.Fatalf("first miss should emit with count=1, got emit=%v count=%d", emit, count)
	}

	for i := 2; i < int(shortLivedTupleMissSummaryEvery); i++ {
		emit, count = cp.recordShortLivedTupleMiss(dst)
		if emit {
			t.Fatalf("miss #%d should be suppressed, got emit=%v count=%d", i, emit, count)
		}
	}

	emit, count = cp.recordShortLivedTupleMiss(dst)
	if !emit || count != shortLivedTupleMissSummaryEvery {
		t.Fatalf("miss #%d should emit summary, got emit=%v count=%d", shortLivedTupleMissSummaryEvery, emit, count)
	}

	emit, count = cp.recordShortLivedTupleMiss(dst)
	if emit || count != shortLivedTupleMissSummaryEvery+1 {
		t.Fatalf("miss #%d should be suppressed, got emit=%v count=%d", shortLivedTupleMissSummaryEvery+1, emit, count)
	}
}

func TestRecordShortLivedTupleMiss_DstScoped(t *testing.T) {
	cp := &ControlPlane{}
	dnsDst := netip.MustParseAddrPort("192.168.1.15:53")
	ntpDst := netip.MustParseAddrPort("122.248.201.177:123")

	emit, count := cp.recordShortLivedTupleMiss(dnsDst)
	if !emit || count != 1 {
		t.Fatalf("dns first miss should emit count=1, got emit=%v count=%d", emit, count)
	}

	emit, count = cp.recordShortLivedTupleMiss(ntpDst)
	if !emit || count != 1 {
		t.Fatalf("ntp first miss should emit count=1, got emit=%v count=%d", emit, count)
	}
}

func TestShortLivedTupleMissSummaryEvery_Is300(t *testing.T) {
	if shortLivedTupleMissSummaryEvery != 300 {
		t.Fatalf("shortLivedTupleMissSummaryEvery = %d, want 300", shortLivedTupleMissSummaryEvery)
	}
}

func TestShortLivedTupleMissSummaryMsg(t *testing.T) {
	got := shortLivedTupleMissSummaryMsg(600)
	want := "UDP routing tuple missing; short-lived UDP fast path fallback (Total=600)"
	if got != want {
		t.Fatalf("summary msg = %q, want %q", got, want)
	}
}
