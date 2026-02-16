package control

import (
	"context"
	"errors"
	"net"
	"testing"
	"time"

	"github.com/daeuniverse/dae/common/consts"
	"github.com/daeuniverse/dae/component/dns"
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
