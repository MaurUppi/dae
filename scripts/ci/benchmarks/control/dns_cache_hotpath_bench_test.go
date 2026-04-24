package control

import (
	"net/netip"
	"testing"
	"time"

	dnsmessage "github.com/miekg/dns"
)

var (
	benchDnsCacheMsgSink  dnsmessage.Msg
	benchDnsCacheBoolSink bool
)

func benchmarkDnsCache() *DnsCache {
	return &DnsCache{
		Answer: []dnsmessage.RR{
			&dnsmessage.A{
				Hdr: dnsmessage.RR_Header{
					Name:   "example.org.",
					Rrtype: dnsmessage.TypeA,
					Class:  dnsmessage.ClassINET,
					Ttl:    60,
				},
				A: []byte{192, 0, 2, 1},
			},
			&dnsmessage.AAAA{
				Hdr: dnsmessage.RR_Header{
					Name:   "example.org.",
					Rrtype: dnsmessage.TypeAAAA,
					Class:  dnsmessage.ClassINET,
					Ttl:    60,
				},
				AAAA: netip.MustParseAddr("2001:db8::1").AsSlice(),
			},
		},
		Deadline:         time.Now().Add(time.Minute),
		OriginalDeadline: time.Now().Add(time.Minute),
	}
}

func benchmarkDnsRequest() *dnsmessage.Msg {
	msg := new(dnsmessage.Msg)
	msg.SetQuestion("example.org.", dnsmessage.TypeA)
	return msg
}

func BenchmarkDnsCache_FillInto(b *testing.B) {
	cache := benchmarkDnsCache()
	req := benchmarkDnsRequest()
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		msg := *req
		cache.FillInto(&msg)
		benchDnsCacheMsgSink = msg
	}
}

func BenchmarkDnsCache_IncludeAnyIp(b *testing.B) {
	cache := benchmarkDnsCache()
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		benchDnsCacheBoolSink = cache.IncludeAnyIp()
	}
}

func BenchmarkDnsCache_IncludeIp(b *testing.B) {
	cache := benchmarkDnsCache()
	ip := netip.MustParseAddr("192.0.2.1")
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		benchDnsCacheBoolSink = cache.IncludeIp(ip)
	}
}
