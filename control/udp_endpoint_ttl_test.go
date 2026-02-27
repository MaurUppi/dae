package control

import (
	"errors"
	"io"
	"net/netip"
	"testing"
	"time"
)

type stubPacketConn struct {
	onWriteTo func()
	writeErr  error
}

func (c *stubPacketConn) Read(_ []byte) (int, error) { return 0, io.EOF }
func (c *stubPacketConn) Write(_ []byte) (int, error) {
	return 0, nil
}
func (c *stubPacketConn) ReadFrom(_ []byte) (int, netip.AddrPort, error) {
	return 0, netip.AddrPort{}, io.EOF
}
func (c *stubPacketConn) WriteTo(p []byte, _ string) (int, error) {
	if c.onWriteTo != nil {
		c.onWriteTo()
	}
	if c.writeErr != nil {
		return 0, c.writeErr
	}
	return len(p), nil
}
func (c *stubPacketConn) Close() error                       { return nil }
func (c *stubPacketConn) SetDeadline(_ time.Time) error      { return nil }
func (c *stubPacketConn) SetReadDeadline(_ time.Time) error  { return nil }
func (c *stubPacketConn) SetWriteDeadline(_ time.Time) error { return nil }

func TestUdpEndpointWriteTo_RefreshesTTLOnlyAfterSuccessfulWrite(t *testing.T) {
	natTimeout := 5 * time.Second
	initialExpiry := time.Now().Add(-time.Second).UnixNano()
	conn := &stubPacketConn{}

	ue := &UdpEndpoint{
		conn:       conn,
		NatTimeout: natTimeout,
	}
	ue.expiresAtNano.Store(initialExpiry)

	conn.onWriteTo = func() {
		if got := ue.expiresAtNano.Load(); got != initialExpiry {
			t.Fatalf("ttl refreshed before conn.WriteTo: got=%d want=%d", got, initialExpiry)
		}
	}

	n, err := ue.WriteTo([]byte("abc"), "127.0.0.1:53")
	if err != nil {
		t.Fatalf("WriteTo returned unexpected error: %v", err)
	}
	if n != 3 {
		t.Fatalf("WriteTo wrote unexpected bytes: got=%d want=3", n)
	}
	if got := ue.expiresAtNano.Load(); got <= initialExpiry {
		t.Fatalf("ttl not refreshed after successful write: got=%d initial=%d", got, initialExpiry)
	}
}

func TestUdpEndpointWriteTo_FailedWriteDoesNotRefreshTTL(t *testing.T) {
	initialExpiry := time.Now().Add(-time.Second).UnixNano()

	ue := &UdpEndpoint{
		conn:       &stubPacketConn{writeErr: errors.New("broken pipe")},
		NatTimeout: 5 * time.Second,
	}
	ue.expiresAtNano.Store(initialExpiry)

	_, err := ue.WriteTo([]byte("abc"), "127.0.0.1:53")
	if err == nil {
		t.Fatal("WriteTo should return error on failed write")
	}
	if got := ue.expiresAtNano.Load(); got != initialExpiry {
		t.Fatalf("ttl must not refresh on failed write: got=%d want=%d", got, initialExpiry)
	}
}

// TestUdpEndpointTtlRefreshOnWrite tests that WriteTo refreshes TTL
func TestUdpEndpointTtlRefreshOnWrite(t *testing.T) {
	natTimeout := 5 * time.Second

	ue := &UdpEndpoint{
		NatTimeout: natTimeout,
	}
	ue.expiresAtNano.Store(time.Now().Add(natTimeout).UnixNano())

	// Initial TTL
	initialExpiry := ue.expiresAtNano.Load()
	time.Sleep(2 * time.Second)

	// WriteTo should refresh TTL
	ue.RefreshTtl() // Simulate WriteTo behavior
	afterRefresh := ue.expiresAtNano.Load()

	// TTL should be extended
	if afterRefresh <= initialExpiry {
		t.Errorf("TTL should be extended after WriteTo, got before=%d after=%d", initialExpiry, afterRefresh)
	}

	// Check IsExpired
	nowNano := time.Now().UnixNano()
	if ue.IsExpired(nowNano) {
		t.Error("Endpoint should not be expired immediately after refresh")
	}
}

// TestUdpEndpointExpiredAfterTimeout tests that endpoint expires after timeout
func TestUdpEndpointExpiredAfterTimeout(t *testing.T) {
	natTimeout := 1 * time.Second

	ue := &UdpEndpoint{
		NatTimeout: natTimeout,
	}
	ue.RefreshTtl()

	// Should not be expired immediately
	nowNano := time.Now().UnixNano()
	if ue.IsExpired(nowNano) {
		t.Error("Endpoint should not be expired immediately after refresh")
	}

	// Wait for timeout
	time.Sleep(natTimeout + 100*time.Millisecond)

	// Should be expired now
	nowNano = time.Now().UnixNano()
	if !ue.IsExpired(nowNano) {
		t.Error("Endpoint should be expired after timeout")
	}
}

// TestUdpEndpointActiveConnectionNotExpired tests that active connections don't expire
func TestUdpEndpointActiveConnectionNotExpired(t *testing.T) {
	natTimeout := 2 * time.Second

	ue := &UdpEndpoint{
		NatTimeout: natTimeout,
	}
	ue.RefreshTtl()

	// Simulate active connection: refresh every second
	for i := 0; i < 5; i++ {
		time.Sleep(1 * time.Second)
		ue.RefreshTtl() // Simulate write or receive

		nowNano := time.Now().UnixNano()
		if ue.IsExpired(nowNano) {
			t.Errorf("Active endpoint should not expire (iteration %d)", i)
		}
	}
}

// TestUdpEndpointInactiveConnectionExpires tests that inactive connections expire
func TestUdpEndpointInactiveConnectionExpires(t *testing.T) {
	natTimeout := 1 * time.Second

	ue := &UdpEndpoint{
		NatTimeout: natTimeout,
	}
	ue.RefreshTtl()

	// Don't refresh, wait for timeout
	time.Sleep(natTimeout + 200*time.Millisecond)

	nowNano := time.Now().UnixNano()
	if !ue.IsExpired(nowNano) {
		t.Error("Inactive endpoint should expire after timeout")
	}
}

// TestUdpEndpointZeroTimeout tests that zero timeout disables expiration
func TestUdpEndpointZeroTimeout(t *testing.T) {
	ue := &UdpEndpoint{
		NatTimeout: 0,
	}
	ue.RefreshTtl() // Should be no-op

	// With zero timeout, should never expire
	nowNano := time.Now().UnixNano()
	if ue.IsExpired(nowNano) {
		t.Error("Endpoint with zero timeout should never expire")
	}

	// Even after long time
	time.Sleep(2 * time.Second)
	nowNano = time.Now().UnixNano()
	if ue.IsExpired(nowNano) {
		t.Error("Endpoint with zero timeout should never expire even after time passes")
	}
}

// BenchmarkUdpEndpointRefreshTtl benchmarks the TTL refresh operation
func BenchmarkUdpEndpointRefreshTtl(b *testing.B) {
	ue := &UdpEndpoint{
		NatTimeout: 30 * time.Second,
	}
	ue.expiresAtNano.Store(time.Now().Add(ue.NatTimeout).UnixNano())

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		ue.RefreshTtl()
	}
}

// BenchmarkUdpEndpointIsExpired benchmarks the expiration check
func BenchmarkUdpEndpointIsExpired(b *testing.B) {
	ue := &UdpEndpoint{
		NatTimeout: 30 * time.Second,
	}
	ue.RefreshTtl()

	nowNano := time.Now().UnixNano()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		ue.IsExpired(nowNano)
	}
}
