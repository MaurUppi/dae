//go:build ignore

/*
 * SPDX-License-Identifier: AGPL-3.0-only
 * Copyright (c) 2022-2026, daeuniverse Organization <dae@v2raya.org>
 */

package control

import (
	"net/netip"
	"testing"
	"time"

	dnsmessage "github.com/miekg/dns"
)

var benchDnsCacheBytesSink []byte

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

func BenchmarkDnsCache_FillIntoWithTTL(b *testing.B) {
	cache := benchmarkDnsCache()
	req := benchmarkDnsRequest()
	now := time.Now()
	if _, err := cache.FillIntoWithTTL(req, now); err != nil {
		b.Fatal(err)
	}
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		packed, err := cache.FillIntoWithTTL(req, now)
		if err != nil {
			b.Fatal(err)
		}
		benchDnsCacheBytesSink = packed
	}
}
