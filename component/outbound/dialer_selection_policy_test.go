/*
 * SPDX-License-Identifier: AGPL-3.0-only
 * Copyright (c) 2022-2025, daeuniverse Organization <dae@v2raya.org>
 */

package outbound

import (
	"testing"

	"github.com/daeuniverse/dae/common/consts"
	"github.com/daeuniverse/dae/config"
)

func TestNewDialerSelectionPolicyFromGroupParam_Smart(t *testing.T) {
	policy, err := NewDialerSelectionPolicyFromGroupParam(&config.Group{
		Policy: "smart",
	})
	if err != nil {
		t.Fatalf("unexpected parse error: %v", err)
	}
	if policy.Policy != consts.DialerSelectionPolicy_Smart {
		t.Fatalf("unexpected policy: got=%v want=%v", policy.Policy, consts.DialerSelectionPolicy_Smart)
	}
}
