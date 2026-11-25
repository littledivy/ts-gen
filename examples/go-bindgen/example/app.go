// A Worker in Go over workers-types, through go-bindgen: each route shows
// one part of the binding, and replies in plain text or JSON.
package main

import (
	"errors"
	"strconv"
	"strings"
	"sync"
	"time"

	w "example/workers"
)

// Fetch is the default export's fetch handler.
func Fetch(req *w.Request, env w.Env, ctx *w.ExecutionContext) (*w.Response, error) {
	url, err := w.NewURL(w.Str(req.URL()))
	if err != nil {
		return nil, err
	}
	switch path := url.Pathname(); {
	case path == "/":
		return text(env.Greeting + " from Go!\nroutes: /echo /json /rewrite /errors /parallel /counter/<name>")
	case path == "/echo":
		return echo(req)
	case path == "/json":
		return order(req)
	case path == "/rewrite":
		return rewrite()
	case path == "/errors":
		return errorsRoute()
	case path == "/parallel":
		return parallel(env.Backend)
	case strings.HasPrefix(path, "/counter/"):
		id, err := env.Counter.IDFromName(strings.TrimPrefix(path, "/counter/"))
		if err != nil {
			return nil, err
		}
		stub, err := env.Counter.Get(id)
		if err != nil {
			return nil, err
		}
		return stub.Fetch(w.Str(req.URL()))
	}
	return w.NewResponseWithBodyAndInit(w.Str("not found"), w.ResponseInit{Status: 404})
}

// echo: a request's method, a header (a nullable string) and its body (a
// future, awaited in place).
func echo(req *w.Request) (*w.Response, error) {
	h, err := req.Headers().Get("x-go")
	if err != nil {
		return nil, err
	}
	body, err := req.Text()
	if err != nil {
		return nil, err
	}
	header := "(none)"
	if h != nil {
		header = *h
	}
	return text(req.Method() + " x-go=" + header + " body=" + body)
}

// Order is what /json reads its body as.
type Order struct {
	Item     string   `json:"item"`
	Quantity int      `json:"quantity"`
	Tags     []string `json:"tags"`
}

// order: an erased result (`json<T>()`) decoded into a Go struct, and a
// rejected future as an error.
func order(req *w.Request) (*w.Response, error) {
	o, err := w.JSON[Order](req)
	if err != nil {
		return text("not an order: " + err.Error())
	}
	return w.ResponseJSON(map[string]any{"item": o.Item, "total": o.Quantity * 3, "tags": len(o.Tags)})
}

// rewrite: a Go func as HTMLRewriter's element handler, called back from
// JS while the transformed body is read.
func rewrite() (*w.Response, error) {
	links := 0
	page, err := w.NewResponseWithBody(w.Str(`<a href="/x">x</a><a href="/y">y</a>`))
	if err != nil {
		return nil, err
	}
	rw, err := w.NewHTMLRewriter()
	if err != nil {
		return nil, err
	}
	rw, err = rw.On("a", w.HTMLRewriterElementContentHandlers{Element: func(el *w.Element) {
		links++
		el.SetAttribute("data-n", strconv.Itoa(links))
	}})
	if err != nil {
		return nil, err
	}
	out, err := rw.Transform(page)
	if err != nil {
		return nil, err
	}
	html, err := out.Text()
	if err != nil {
		return nil, err
	}
	return text(strconv.Itoa(links) + " links: " + html)
}

// errorsRoute: a declared error (`@throws {DOMException}`) and an
// undeclared TypeError, each caught with errors.As.
func errorsRoute() (*w.Response, error) {
	var lines []string
	_, err := w.Atob("not base64!")
	var de *w.DOMExceptionErr
	lines = append(lines, "atob: DOMException="+strconv.FormatBool(errors.As(err, &de)))
	_, err = w.NewURL(w.Str("not a url"))
	var te *w.JSError
	if errors.As(err, &te) {
		lines = append(lines, "URL: "+te.Kind.String())
	} else {
		lines = append(lines, "URL: "+describe(err))
	}
	return text(strings.Join(lines, "\n"))
}

func describe(err error) string {
	if err == nil {
		return "no error"
	}
	return err.Error()
}

// parallel: three goroutines each await a fetch; they overlap, so the
// whole takes about one.
func parallel(backend *w.Fetcher) (*w.Response, error) {
	start := time.Now()
	var wg sync.WaitGroup
	got := make([]string, 3)
	for i := range got {
		wg.Add(1)
		go func() {
			defer wg.Done()
			r, err := backend.Fetch(w.Str("http://backend/" + strconv.Itoa(i) + "?ms=100"))
			if err != nil {
				got[i] = err.Error()
				return
			}
			got[i], _ = r.Text()
		}()
	}
	wg.Wait()
	return text(strings.Join(got, ", ") + " overlapped=" + strconv.FormatBool(time.Since(start) < 250*time.Millisecond))
}

// Counter is a Durable Object: JS constructs it through NewCounter.
type Counter struct{ state *w.DurableObjectState }

func NewCounter(state *w.DurableObjectState, env w.Env) (*Counter, error) {
	return &Counter{state}, nil
}

// Fetch counts in storage (a typed get) and in SQL (a typed row).
func (c *Counter) Fetch(req *w.Request) (*w.Response, error) {
	storage := c.state.Storage()
	n, err := w.DurableObjectStorageGet[int](storage, "n")
	if err != nil {
		return nil, err
	}
	n++
	if err := storage.Put("n", n); err != nil {
		return nil, err
	}
	sql := storage.SQL()
	if _, err := sql.Exec("CREATE TABLE IF NOT EXISTS hits (n INTEGER)"); err != nil {
		return nil, err
	}
	if _, err := sql.Exec("INSERT INTO hits VALUES (?1)", n); err != nil {
		return nil, err
	}
	cur, err := sql.Exec("SELECT COUNT(*) AS hits, MAX(n) AS top FROM hits")
	if err != nil {
		return nil, err
	}
	row, err := w.One[struct{ Hits, Top int }](cur)
	if err != nil {
		return nil, err
	}
	return text("count=" + strconv.Itoa(n) + " hits=" + strconv.Itoa(row.Hits) + " top=" + strconv.Itoa(row.Top))
}

func text(s string) (*w.Response, error) {
	return w.NewResponseWithBody(w.Str(s))
}
