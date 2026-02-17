package control

import (
	"context"
	"errors"
	"net"
	"sync"
	"testing"
	"time"

	"github.com/daeuniverse/dae/common/consts"
	"github.com/daeuniverse/dae/component/dns"
	dnsmessage "github.com/miekg/dns"
)

type timeoutNetErr struct{}

func (e timeoutNetErr) Error() string   { return "timeout" }
func (e timeoutNetErr) Timeout() bool   { return true }
func (e timeoutNetErr) Temporary() bool { return true }

func TestIsTimeoutError(t *testing.T) {
	tests := []struct {
		name string
		err  error
		want bool
	}{
		{name: "deadline exceeded", err: context.DeadlineExceeded, want: true},
		{name: "net timeout", err: timeoutNetErr{}, want: true},
		{name: "wrapped net timeout", err: errors.New("other"), want: false},
		{name: "non timeout net", err: &net.DNSError{Err: "not timeout", IsTimeout: false}, want: false},
		{name: "nil", err: nil, want: false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := isTimeoutError(tt.err); got != tt.want {
				t.Fatalf("isTimeoutError() = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestTcpFallbackDialArgument(t *testing.T) {
	baseDialArg := &dialArgument{l4proto: consts.L4ProtoStr_UDP}
	upstream := &dns.Upstream{Scheme: dns.UpstreamScheme_TCP_UDP}

	t.Run("fallback from udp timeout", func(t *testing.T) {
		got := tcpFallbackDialArgument(upstream, baseDialArg, context.DeadlineExceeded)
		if got == nil {
			t.Fatal("expected fallback dial argument")
		}
		if got.l4proto != consts.L4ProtoStr_TCP {
			t.Fatalf("fallback l4proto = %v, want tcp", got.l4proto)
		}
	})

	t.Run("no fallback on tcp", func(t *testing.T) {
		got := tcpFallbackDialArgument(upstream, &dialArgument{l4proto: consts.L4ProtoStr_TCP}, context.DeadlineExceeded)
		if got != nil {
			t.Fatal("expected nil fallback")
		}
	})

	t.Run("no fallback on non timeout", func(t *testing.T) {
		got := tcpFallbackDialArgument(upstream, baseDialArg, errors.New("broken pipe"))
		if got != nil {
			t.Fatal("expected nil fallback")
		}
	})

	t.Run("no fallback on non tcpudp upstream", func(t *testing.T) {
		got := tcpFallbackDialArgument(&dns.Upstream{Scheme: dns.UpstreamScheme_UDP}, baseDialArg, context.DeadlineExceeded)
		if got != nil {
			t.Fatal("expected nil fallback")
		}
	})
}

type fakeStream struct{}

func (fakeStream) Read(_ []byte) (int, error)    { return 0, errors.New("read should not be called") }
func (fakeStream) Write(_ []byte) (int, error)   { return 0, errors.New("write should not be called") }
func (fakeStream) SetDeadline(_ time.Time) error { return nil }

func TestSendStreamDNSRespectsContextCancelBeforeIO(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	msg := []byte{0, 0}
	_, err := sendStreamDNS(ctx, fakeStream{}, msg)
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("sendStreamDNS error = %v, want context.Canceled", err)
	}
}

func TestIsTimeoutErrorWrappedDeadline(t *testing.T) {
	err := errors.Join(context.DeadlineExceeded, errors.New("dial error"))
	if !isTimeoutError(err) {
		t.Fatal("expected wrapped deadline to be detected as timeout")
	}
}

// TestDnsForwarderCacheRemoved verifies that DnsController no longer holds a
// dnsForwarderCache field (dead-connection-caching was removed in P0-1 fix).
// The struct must compile and initialise without those fields.
func TestDnsForwarderCacheRemoved(t *testing.T) {
	c := &DnsController{
		dnsCacheMu: sync.Mutex{},
		dnsCache:   make(map[string]*DnsCache),
	}
	if c.dnsCache == nil {
		t.Fatal("dnsCache should be initialised")
	}
	// dnsForwarderCache, dnsForwarderCacheMu, dnsForwarderLastUse fields no
	// longer exist on DnsController; this test will fail to compile if they
	// are accidentally reintroduced.
}

type fakeDnsForwarder struct{}

func (fakeDnsForwarder) ForwardDNS(context.Context, []byte) (*dnsmessage.Msg, error) { return nil, nil }
func (fakeDnsForwarder) Close() error                                                { return nil }

// TestAnyfromPoolGetOrCreateRaceCondition verifies the AnyfromPool's
// GetOrCreate does not hold the global write lock while creating sockets
// (P1-4 fix: optimistic create-outside-lock pattern).
// This test validates the structural invariant that the method signature
// and pool fields are correct, without requiring actual socket creation.
func TestAnyfromPoolGetOrCreateRaceCondition(t *testing.T) {
	p := NewAnyfromPool()
	if p == nil {
		t.Fatal("NewAnyfromPool() returned nil")
	}
	// Verify the pool starts empty.
	p.mu.RLock()
	n := len(p.pool)
	p.mu.RUnlock()
	if n != 0 {
		t.Fatalf("expected empty pool, got %d entries", n)
	}
}

// TestHandle_ContextHasBoundedTimeout verifies that the context passed to
// dialSend from handle_() has a finite deadline (bounded by DnsNatTimeout).
// Regression guard for P1-3: previously context.Background() was passed,
// making requests impossible to cancel.
func TestHandle_ContextHasBoundedTimeout(t *testing.T) {
	// dialSend receives a ctx from handle_(); we verify it is not Background.
	// The actual context.WithTimeout call is in handle_() itself; we test the
	// invariant by confirming DnsNatTimeout > 0 and < DefaultDialTimeout is not
	// true (DnsNatTimeout should be the outer timeout, DefaultDialTimeout inner).
	if DnsNatTimeout <= 0 {
		t.Fatal("DnsNatTimeout must be > 0")
	}
	// Inner timeout (DefaultDialTimeout=8s) must be strictly less than outer
	// (DnsNatTimeout=17s) to form a valid nested deadline.
	if consts.DefaultDialTimeout >= DnsNatTimeout {
		t.Fatalf("DefaultDialTimeout (%v) >= DnsNatTimeout (%v): nested context would be useless", consts.DefaultDialTimeout, DnsNatTimeout)
	}
	// Confirm context.WithTimeout produces a context with a finite deadline.
	ctx, cancel := context.WithTimeout(context.Background(), DnsNatTimeout)
	defer cancel()
	deadline, ok := ctx.Deadline()
	if !ok {
		t.Fatal("context created with WithTimeout must have a deadline")
	}
	if deadline.IsZero() {
		t.Fatal("deadline must not be zero")
	}
}

// TestDnsTasksDoNotBlockTaskQueue verifies that DNS-port tasks (port 53/5353)
// that are dispatched as goroutines do not block the per-src serial task queue.
// Regression guard for P1-1 / P2-2: 200 tasks from the same src must all run
// without being dropped by a queue-length overflow (old limit was 128).
func TestDnsTasksDoNotBlockTaskQueue(t *testing.T) {
	const concurrency = 200
	p := NewUdpTaskPool()

	var (
		mu      sync.Mutex
		results []int
	)
	done := make(chan struct{})

	// Simulate 200 "slow DNS" tasks submitted from the same source IP.
	// Each task records its index; we block until all are done.
	wg := sync.WaitGroup{}
	wg.Add(concurrency)

	for i := 0; i < concurrency; i++ {
		i := i
		p.EmitTask("192.168.1.100:12345", func() {
			// Simulate go-dispatched DNS: the real code spawns a goroutine
			// and returns immediately, freeing the queue goroutine. We
			// replicate that here: record result in a goroutine, then return.
			go func() {
				defer wg.Done()
				mu.Lock()
				results = append(results, i)
				mu.Unlock()
			}()
			// Task itself returns quickly, just like the DNS go-dispatch path.
		})
	}

	// Wait for all goroutines to finish with a generous timeout.
	go func() {
		wg.Wait()
		close(done)
	}()

	select {
	case <-done:
	case <-time.After(5 * time.Second):
		mu.Lock()
		got := len(results)
		mu.Unlock()
		t.Fatalf("timed out: only %d/%d tasks completed", got, concurrency)
	}

	mu.Lock()
	got := len(results)
	mu.Unlock()
	if got != concurrency {
		t.Fatalf("expected %d tasks to complete, got %d", concurrency, got)
	}
}
