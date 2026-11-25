//! A tour of the Workers API from Zig: each route does one thing and
//! replies in plain text or JSON. The bindings (build/gen/bindings.zig) are
//! generated from workers-types by zig-bindgen; nothing here is
//! hand-written glue.
const std = @import("std");
const w = @import("build/gen/bindings.zig");
const Allocator = std.mem.Allocator;
const eql = std.mem.eql;

pub const panic = w.panic;
comptime {
    w.exports(@This());
}

/// The default export's `fetch`. The allocator is the request's arena:
/// what it and the bindings allocate is freed when the request ends.
pub fn fetch(a: Allocator, request: w.Request, env: w.Env) !w.Response {
    const url = try w.URL.init(.{ .str = request.url() });
    const path = url.pathname();
    if (eql(u8, path, "/")) {
        return text(try std.fmt.allocPrint(a, "{s}\nroutes: /echo /url /json /rewrite /errors /fetch /counter\n", .{env.greeting()}));
    } else if (eql(u8, path, "/echo")) {
        // A `str?` (a header), and a future awaited in place (the body).
        const from = try request.headers().get("x-zig") orelse "nobody";
        return text(try std.fmt.allocPrint(a, "{s} from {s}: {s}\n", .{ request.method(), from, try request.text() }));
    } else if (eql(u8, path, "/url")) {
        // `arr<str>` as a slice.
        const params = url.searchParams();
        const tags = try params.getAll("tag");
        return text(try std.fmt.allocPrint(a, "path {s}, q={s}, tags {s}\n", .{ path, try params.get("q") orelse "", try std.mem.join(a, ",", tags) }));
    } else if (eql(u8, path, "/json")) {
        // `json<T>()` decoded as a Zig struct, and a struct encoded back.
        const order = request.json(Order) catch |e| switch (e) {
            error.TypeError, error.Error => return status(400, w.JsError.last().?.message()),
        };
        var total: u32 = 0;
        for (order.tags) |t| total += @intCast(t.len);
        return w.Response.json(.{ .item = order.item, .quantity = order.quantity, .tags = order.tags.len, .letters = total });
    } else if (eql(u8, path, "/rewrite")) {
        // A Zig function with its context as HTMLRewriter's element handler.
        var seen = Links{ .a = a };
        const page = try w.Response.initWithBody(.{ .str = "<a href=\"/x\">x</a> <a href=\"/y\">y</a>" });
        const rewriter = try (try w.HTMLRewriter.init()).on("a", .init(.{ .element = .init(&seen, Links.onElement) }));
        const html = try (try rewriter.transform(page)).text();
        return text(try std.fmt.allocPrint(a, "{s}\nlinks: {s}\n", .{ html, seen.hrefs.items }));
    } else if (eql(u8, path, "/errors")) {
        // `@throws {DOMException}` as a Zig error, its payload after it; a
        // constructor's TypeError the same way.
        const decoded = w.atob("not base64!") catch |e| switch (e) {
            error.DOMException => w.DOMExceptionErr.last().?.message(),
            else => return e,
        };
        const bad = if (w.URL.init(.{ .str = "not a url" })) |_| "parsed" else |e| @errorName(e);
        return text(try std.fmt.allocPrint(a, "atob: {s}\nURL: {s}: {s}\n", .{ decoded, bad, w.JsError.last().?.message() }));
    } else if (eql(u8, path, "/fetch")) {
        const reply = try env.backend().fetch(.{ .str = "http://backend/hello" });
        return text(try std.fmt.allocPrint(a, "{d}: {s}\n", .{ reply.status(), try reply.text() }));
    } else if (eql(u8, path, "/counter")) {
        const ns = env.counter();
        return (try ns.get(try ns.idFromName("tour"))).fetch(.{ .request = request });
    }
    return status(404, "not found");
}

const Order = struct {
    item: []const u8,
    quantity: u32,
    tags: []const []const u8 = &.{},
};

/// The `/rewrite` handler's state: the links it has seen.
const Links = struct {
    a: Allocator,
    hrefs: std.ArrayList(u8) = .empty,

    fn onElement(self: *Links, el: w.Element) void {
        const href = (el.getAttribute("href") catch null) orelse return;
        if (self.hrefs.items.len > 0) self.hrefs.append(self.a, ' ') catch return;
        self.hrefs.appendSlice(self.a, href) catch return;
        _ = el.setAttribute("data-seen", "zig") catch {};
    }
};

/// The Durable Object: a count in KV storage and visits in SQL. JS
/// constructs it with `init` and drops it with `deinit`.
pub const Counter = struct {
    state: w.DurableObjectState,

    pub fn init(ctx: w.DurableObjectState) Counter {
        return .{ .state = ctx };
    }

    pub fn deinit(self: *Counter) void {
        self.state.deinit();
    }

    pub fn fetch(self: *Counter, a: Allocator) !w.Response {
        const storage = self.state.storage();
        const n = (try storage.get(u32, "n") orelse 0) + 1;
        try storage.put("n", n);
        const sql = storage.sql();
        _ = try sql.exec("CREATE TABLE IF NOT EXISTS visits (n INTEGER)", .{});
        _ = try sql.exec("INSERT INTO visits VALUES (?)", .{n});
        const visits = try (try sql.exec("SELECT COUNT(*) AS c, MAX(n) AS last FROM visits", .{})).one(struct { c: u32, last: u32 });
        return text(try std.fmt.allocPrint(a, "count {d}, {d} visits, last {d}\n", .{ n, visits.c, visits.last }));
    }
};

fn text(body: []const u8) !w.Response {
    return w.Response.initWithBody(.{ .str = body });
}

fn status(code: u16, body: []const u8) !w.Response {
    return w.Response.initWithBodyAndInit(.{ .str = body }, .init(.{ .status = code }));
}
