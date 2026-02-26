package control

import (
	"io"
	"os"
	"sync"
	"time"

	"github.com/daeuniverse/outbound/netproxy"
)

// Ensure mockConn implements netproxy.Conn.
var _ netproxy.Conn = (*mockConn)(nil)

// mockConn implements netproxy.Conn for control package tests.
type mockConn struct {
	readBlock  chan struct{}
	readRetErr error
	deadline   time.Time
	mu         sync.Mutex
	once       sync.Once
	closed     bool
}

func newMockConn(block bool, retErr error) *mockConn {
	m := &mockConn{
		readBlock:  make(chan struct{}),
		readRetErr: retErr,
	}
	if !block {
		m.once.Do(func() {
			close(m.readBlock)
		})
	}
	return m
}

func (m *mockConn) Read(b []byte) (n int, err error) {
	if m.closed {
		return 0, io.EOF
	}
	<-m.readBlock

	m.mu.Lock()
	defer m.mu.Unlock()

	if !m.deadline.IsZero() && m.deadline.Before(time.Now()) {
		return 0, os.ErrDeadlineExceeded
	}
	if m.readRetErr != nil {
		return 0, m.readRetErr
	}
	return 0, io.EOF
}

func (m *mockConn) Write(b []byte) (n int, err error) {
	return len(b), nil
}

func (m *mockConn) Close() error {
	m.closed = true
	return nil
}

func (m *mockConn) SetDeadline(t time.Time) error {
	return m.SetReadDeadline(t)
}

func (m *mockConn) SetReadDeadline(t time.Time) error {
	m.mu.Lock()
	m.deadline = t
	m.mu.Unlock()

	if !t.IsZero() && t.Before(time.Now()) {
		m.once.Do(func() {
			close(m.readBlock)
		})
	}
	return nil
}

func (m *mockConn) SetWriteDeadline(time.Time) error {
	return nil
}

func (m *mockConn) CloseWrite() error {
	return nil
}
