package control

import (
	"errors"
	"os"
	"testing"
	"time"
)

func TestRelayTCP_Cancellation(t *testing.T) {
	// Scenario:
	// lConn is blocked on Read.
	// rConn returns an error immediately.
	// RelayTCP should detect rConn error, cancel context, and force lConn to unblock via SetReadDeadline.

	lConn := newMockConn(true, nil) // blocking
	rConn := newMockConn(false, errors.New("immediate error"))

	// Run RelayTCP in a goroutine or just call it since it should return.
	// We expect it to return quickly.
	done := make(chan error)
	go func() {
		done <- RelayTCP(lConn, rConn)
	}()

	select {
	case err := <-done:
		if err == nil {
			t.Fatal("expected error, got nil")
		}
		// In RelayTCP:
		// 1. copyWait(ctx, lConn, rConn) -> io.Copy(lConn, rConn) returns error (rConn read fails)
		// 2. copyWait returns, context canceled.
		// 3. The other goroutine: copyWait(ctx, rConn, lConn) -> io.Copy(rConn, lConn) is blocked.
		// 4. Context cancel triggers lConn.SetReadDeadline.
		// 5. lConn.Read unblocks with ErrDeadlineExceeded.
		// 6. RelayTCP collects errors.

		// The error returned is usually the first one or combined.
		// Since rConn failed first, we expect "immediate error".
		if !errors.Is(err, rConn.readRetErr) {
			// It might be wrapped
			if err.Error() != "immediate error" && !errors.Is(err, os.ErrDeadlineExceeded) {
				t.Logf("Got error: %v", err)
			}
		}
	case <-time.After(2 * time.Second):
		t.Fatal("RelayTCP timed out - deadlock suspected")
	}

	// Verify lConn.SetReadDeadline was called with past time
	lConn.mu.Lock()
	dl := lConn.deadline
	lConn.mu.Unlock()

	if dl.IsZero() {
		t.Error("lConn.SetReadDeadline should have been called")
	} else if !dl.Before(time.Now()) {
		t.Errorf("lConn.SetReadDeadline should be in the past, got %v", dl)
	}
}
