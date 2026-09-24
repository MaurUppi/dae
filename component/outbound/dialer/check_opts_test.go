/*
 * SPDX-License-Identifier: AGPL-3.0-only
 * Copyright (c) 2022-2026, daeuniverse Organization <dae@v2raya.org>
 */

package dialer

import (
	"context"
	"testing"

	"github.com/daeuniverse/dae/common/consts"
)

func testCheckOption(proto consts.L4ProtoStr, ip consts.IpVersionStr) *CheckOption {
	return &CheckOption{
		networkType: &NetworkType{
			L4Proto:   proto,
			IpVersion: ip,
		},
	}
}

func TestBuildCheckOpts(t *testing.T) {
	tcp4 := testCheckOption(consts.L4ProtoStr_TCP, consts.IpVersionStr_4)
	tcp6 := testCheckOption(consts.L4ProtoStr_TCP, consts.IpVersionStr_6)
	udp4 := testCheckOption(consts.L4ProtoStr_UDP, consts.IpVersionStr_4)
	udp6 := testCheckOption(consts.L4ProtoStr_UDP, consts.IpVersionStr_6)

	t.Run("udp configured includes four probes in order", func(t *testing.T) {
		got := buildCheckOpts(true, tcp4, tcp6, udp4, udp6)
		want := []*CheckOption{tcp4, tcp6, udp4, udp6}
		if len(got) != len(want) {
			t.Fatalf("len = %d, want %d", len(got), len(want))
		}
		for i := range want {
			if got[i] != want[i] {
				t.Fatalf("opt[%d] = %p, want %p", i, got[i], want[i])
			}
		}
	})

	t.Run("udp disabled keeps only tcp4 and tcp6", func(t *testing.T) {
		got := buildCheckOpts(false, tcp4, tcp6, udp4, udp6)
		if len(got) != 2 || got[0] != tcp4 || got[1] != tcp6 {
			t.Fatalf("opts=%v, want tcp4 then tcp6", got)
		}
	})
}

func TestCheck_ErrNoApplicableIPMarksTcp6Unavailable(t *testing.T) {
	d := newNamedTestDialer(t, "v4-only-node")
	typ := &NetworkType{
		L4Proto:   consts.L4ProtoStr_TCP,
		IpVersion: consts.IpVersionStr_6,
	}
	if !d.MustGetAlive(typ) {
		t.Fatal("setup: tcp6 starts alive")
	}

	opts := &CheckOption{
		networkType: typ,
		CheckFunc: func(context.Context, *NetworkType) (bool, error) {
			return false, ErrNoApplicableIP
		},
	}
	if _, err := d.check(opts, false, nil); err == nil {
		t.Fatal("expected ErrNoApplicableIP to propagate")
	}
	if d.MustGetAlive(typ) {
		t.Fatal("tcp6 with no applicable IP must be marked unavailable")
	}
	alive, _, _, _, _ := d.GetCollectionState(typ)
	if alive {
		t.Fatal("GetCollectionState alive=true, want false")
	}
}
