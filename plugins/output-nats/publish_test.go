package main

import "testing"

func TestValidSubjectToken(t *testing.T) {
	for _, tc := range []struct {
		value string
		valid bool
	}{
		{"default", true}, {"A_z-09", true}, {"", false},
		{"a.b", false}, {"a*b", false}, {"a>b", false},
		{"a b", false}, {"é", false}, {"a\n", false},
	} {
		if got := validSubjectToken(tc.value); got != tc.valid {
			t.Errorf("validSubjectToken(%q) = %v, want %v", tc.value, got, tc.valid)
		}
	}
}
