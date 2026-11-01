package domain

import (
	"sort"
	"testing"
	"time"
)

func TestHLCRoundTripAndOrder(t *testing.T) {
	in := []string{"1730380000000:0003:dev_8f2a", "1730380000000:0002:dev_9", "1730379999999:9999:z", "1730380000000:0003:dev_8f2b"}
	var stamps []HLC
	for _, s := range in {
		h, err := ParseHLC(s)
		if err != nil {
			t.Fatal(err)
		}
		stamps = append(stamps, h)
	}
	if stamps[0].String() != "1730380000000:0003:dev_8f2a" {
		t.Errorf("String() = %q", stamps[0].String())
	}
	if MustHLC("5:1:d").String() != "0000000000005:0001:d" {
		t.Errorf("padding: %q", MustHLC("5:1:d").String())
	}
	sort.Slice(stamps, func(i, j int) bool { return stamps[i].Less(stamps[j]) })
	want := []string{"1730379999999:9999:z", "1730380000000:0002:dev_9", "1730380000000:0003:dev_8f2a", "1730380000000:0003:dev_8f2b"}
	for i, w := range want {
		if stamps[i].String() != MustHLC(w).String() {
			t.Errorf("order[%d] = %s, want %s", i, stamps[i], w)
		}
	}
	// lexical order of the padded form agrees with Less
	strs := make([]string, len(stamps))
	for i, h := range stamps {
		strs[i] = h.String()
	}
	if !sort.StringsAreSorted(strs) {
		t.Errorf("padded strings are not lexically sorted: %v", strs)
	}
	for _, bad := range []string{"", "1:2", "a:1:d", "1:x:d", "1:1:", "1:1:a:b", "1:10000:d", "-1:0:d"} {
		if _, err := ParseHLC(bad); err == nil {
			t.Errorf("ParseHLC(%q) accepted", bad)
		}
	}
}

func TestClock(t *testing.T) {
	now := time.UnixMilli(1000)
	c, err := NewClock("dev", func() time.Time { return now })
	if err != nil {
		t.Fatal(err)
	}
	a := c.Next()
	b := c.Next()
	if !a.Less(b) || a.Wall != 1000 || b.Counter != 1 {
		t.Errorf("a=%s b=%s", a, b)
	}
	now = time.UnixMilli(2000)
	cc := c.Next()
	if cc.Wall != 2000 || cc.Counter != 0 {
		t.Errorf("wall advance: %s", cc)
	}
	c.Observe(MustHLC("9000:7:other"))
	d := c.Next()
	if d.Wall != 9000 || d.Counter != 8 || d.Device != "dev" {
		t.Errorf("after observe: %s", d)
	}
	now = time.UnixMilli(500)
	e := c.Next()
	if !d.Less(e) {
		t.Errorf("clock went backwards: %s then %s", d, e)
	}
	if _, err := NewClock("a:b", nil); err == nil {
		t.Error("device with colon accepted")
	}
}

func TestClockCounterOverflow(t *testing.T) {
	c, _ := NewClock("d", func() time.Time { return time.UnixMilli(1) })
	c.Observe(HLC{Wall: 1, Counter: hlcMaxCounter, Device: "x"})
	h := c.Next()
	if h.Wall != 2 || h.Counter != 0 {
		t.Errorf("overflow: %s", h)
	}
}
