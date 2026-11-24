// The probe's Go side: each export exercises part of the binding, and
// test.mjs checks what they return.
package main

import (
	"errors"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"

	"app/probe"
)

type Counter struct{ n uint32 }

func NewCounter(start uint32) (*Counter, error) { return &Counter{start}, nil }

func (c *Counter) N() uint32    { return c.n }
func (c *Counter) Bump() uint32 { c.n++; return c.n }

// ProbeCheck returns n doubled, and a declared error for 0.
func ProbeCheck(n uint32) (uint32, error) {
	if n == 0 {
		return 0, &probe.ProbeError{Kind: probe.ProbeErrorBusy, Message: "zero"}
	}
	return n * 2, nil
}

type row struct {
	ID   int    `json:"id"`
	Body string `json:"body"`
}

// ProbeRun calls each kind of import and reports what came back.
func ProbeRun() (string, error) {
	var out []string
	add := func(k, v string) { out = append(out, k+"="+v) }

	add("shelf", probe.First[string](probe.ExtShelf()))
	s, err := probe.ExtStock(7)
	if err != nil {
		return "", err
	}
	add("stock", strconv.Itoa(probe.First[int](s)))
	add("apply", strconv.Itoa(int(probe.ExtApply(func(x uint32) uint32 { return x * 3 }, 5))))
	v, err := probe.ExtDelay(5, "late")
	if err != nil {
		return "", err
	}
	add("delay", v)

	// A declared rejection, as a typed error.
	_, err = probe.ExtFail("busy")
	var pe *probe.ProbeError
	add("fail", strconv.FormatBool(errors.As(err, &pe) && pe.Kind == probe.ProbeErrorBusy)+":"+messageOf(pe))

	// Any other JS exception, as an Exception with its name.
	err = probe.ExtBoom()
	var je *probe.JSError
	var ex *probe.Exception
	switch {
	case errors.As(err, &je):
		add("boom", je.Kind.String()+":"+je.Message)
	case errors.As(err, &ex):
		add("boom", "exception:"+ex.Error())
	default:
		add("boom", "none")
	}

	add("bytes", string(probe.ExtBytes([]byte("abc"))))
	add("words", strings.Join(probe.ExtWords([]string{"a", "b"}), ","))
	add("join", probe.ExtJoin("-", "x", "y", "z"))
	p := probe.ExtNorm(probe.Point{X: 2, Label: "p"})
	add("norm", strconv.FormatFloat(p.X, 'f', -1, 64)+":"+p.Label)
	rv, err := probe.ExtRow()
	if err != nil {
		return "", err
	}
	r, err := probe.Decode[row](rv)
	if err != nil {
		return "", err
	}
	add("row", strconv.Itoa(r.ID)+":"+r.Body)
	held := []*probe.Shelf{probe.ExtShelf(), probe.ExtShelf(), probe.ExtShelf()}
	add("held", strconv.FormatBool(probe.ExtLive() >= uint32(len(held))))
	runtime.KeepAlive(held)
	return strings.Join(out, " "), nil
}

func messageOf(e *probe.ProbeError) string {
	if e == nil {
		return ""
	}
	return e.Message
}

// ProbeParallel awaits three delays from three goroutines at once: they
// overlap, so the whole takes about one delay.
func ProbeParallel() (string, error) {
	start := time.Now()
	var wg sync.WaitGroup
	got := make([]string, 3)
	for i := range got {
		wg.Add(1)
		go func() {
			defer wg.Done()
			got[i], _ = probe.ExtDelay(60, strconv.Itoa(i))
		}()
	}
	wg.Wait()
	overlapped := time.Since(start) < 150*time.Millisecond
	return strings.Join(got, ",") + " overlapped=" + strconv.FormatBool(overlapped), nil
}

// ProbeRelease drops JS objects without Close: their cleanups free the
// slots once Go collects them. It returns how many the JS side still sees.
func ProbeRelease() (uint32, error) {
	for range 50 {
		_ = probe.ExtShelf()
	}
	for range 3 {
		runtime.GC()
		runtime.Gosched()
	}
	return probe.ExtLive(), nil
}
