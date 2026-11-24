// A tour of the Workers API from Swift, through bindings swift-bindgen
// generates from workers-types: each route does one thing and replies in
// plain text.

enum App: WorkerExport {
  static func fetch(_ request: Request, env: Env, ctx: ExecutionContext) async throws -> Response {
    let url = try URL(.str(request.url))
    switch url.pathname {
    case "/":
      return try text("""
        \(env.greeting)!
        routes: /echo /url /json /crypto /timers /rewrite /errors /fetch /counter

        """)
    case "/echo":
      // `str?` as an optional, `future<str>` as an async call.
      let header = try request.headers.get("x-swift") ?? "none"
      return try text("\(request.method) with x-swift: \(header), body: \(try await request.text())\n")
    case "/url":
      // Getters, and `arr<str>` as an array.
      let params = url.searchParams
      let tags = try params.getAll("tag").joined(separator: ",")
      return try text("path \(url.pathname), q = \(try params.get("q") ?? ""), tags = \(tags)\n")
    case "/json":
      // An erased generic (`json<T>`) decoded through Codable.
      do {
        let order = try await request.json(as: Order.self)
        return try text("\(order.quantity) x \(order.item) (\(order.tags.joined(separator: ", ")))\n")
      } catch let e as DecodingError {
        return try text("not an order: \(missing(e))\n", status: 400)
      }
    case "/crypto":
      let id = try crypto.randomUUID()
      return try text("a UUID of \(id.count) characters, version \(id.dropFirst(14).prefix(1))\n")
    case "/timers":
      // Tasks wait on JS promises at once: the module suspends until one
      // settles, and the shorter wait finishes first.
      let log = Log()
      try await withThrowingTaskGroup(of: Void.self) { group in
        for ms in [30.0, 10.0] {
          group.addTask {
            try await scheduler.wait(ms)
            log.add("\(Int(ms)) ms")
          }
        }
        try await group.waitForAll()
      }
      return try text("done: \(log.items.joined(separator: ", then "))\n")
    case "/rewrite":
      // A Swift closure as an element handler, called once per match.
      var links = 0
      let page = try Response(.str(#"<a href="/x">x</a><a href="/y">y</a>"#))
      let rewritten = try HTMLRewriter()
        .on("a", handlers: ElementHandlers(element: { el in
          links += 1
          _ = try? el.setAttribute("data-n", value: String(links))
        }))
        .transform(page)
      let html = try await rewritten.text()
      return try text("\(links) links: \(html)\n")
    case "/errors":
      // A declared error (`@throws {DOMException}`) as a typed throw, and
      // the built-in `err` of a constructor that throws.
      var lines: [String] = []
      do {
        _ = try atob("not base64!")
      } catch DOMExceptionErr.domException(let message) {
        lines.append("atob: DOMException: \(message.prefix(28))")
      } catch {
        lines.append("atob: \(error)")
      }
      do {
        _ = try URL(.str("not a url"))
      } catch .typeError(let message) {
        lines.append("URL: TypeError: \(message)")
      } catch {
        lines.append("URL: \(error)")
      }
      return try text(lines.joined(separator: "\n") + "\n")
    case "/fetch":
      // A service binding.
      let reply = try await env.backend.fetch(.str("http://backend/hello"))
      return try text("\(reply.status): \(try await reply.text())\n")
    case "/counter":
      // A Durable Object, by name.
      let ns = env.counter
      return try await ns.get(try ns.idFromName("tour")).fetch(.request(request))
    default:
      return try text("not found\n", status: 404)
    }
  }
}

/// A Durable Object: a count in its key-value storage, and a row per
/// visit in its SQL storage.
final class Counter: CounterExport {
  let state: DurableObjectState

  init(_ ctx: DurableObjectState, env: Env) throws { state = ctx }

  func fetch(_ request: Request) async throws -> Response {
    let storage = state.storage
    let n = (try await storage.get("n", as: Int.self) ?? 0) + 1
    try await storage.put("n", value: n)
    let sql = storage.sql
    _ = try sql.exec("CREATE TABLE IF NOT EXISTS visits (n INTEGER)")
    _ = try sql.exec("INSERT INTO visits VALUES (?1)", bindings: n)
    let rows = try sql.exec("SELECT COUNT(*) AS c FROM visits").one(as: Rows.self).c
    return try text("count \(n), \(rows) rows\n")
  }
}

struct Order: Decodable {
  let item: String
  let quantity: Int
  let tags: [String]
}

struct Rows: Decodable { let c: Int }

final class Log {
  var items: [String] = []
  func add(_ item: String) { items.append(item) }
}

func text(_ body: String, status: UInt16 = 200) throws -> Response {
  try Response(.str(body), init: ResponseInit(status: status))
}

/// The field a decoding error is about.
func missing(_ e: DecodingError) -> String {
  switch e {
  case .keyNotFound(let key, _): return "no \(key.stringValue)"
  case .typeMismatch(_, let c), .valueNotFound(_, let c): return "no \(c.codingPath.last?.stringValue ?? "value")"
  default: return "\(e)"
  }
}
