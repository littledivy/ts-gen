using Workerd = import "/workerd/workerd.capnp";
const config :Workerd.Config = (
  services = [
    (name = "main", worker = (
      modules = [
        (name = "loader.js", esModule = embed "loader.js"),
        (name = "bridge.js", esModule = embed "bridge.js"),
        (name = "bridge.wasm", wasm = embed "bridge.wasm"),
        (name = "worker.wasm", wasm = embed "worker.wasm"),
      ],
      bindings = [
        (name = "GREETING", text = "Hello from Zig on workerd"),
        (name = "BACKEND", service = "backend"),
        (name = "COUNTER", durableObjectNamespace = "Counter"),
      ],
      durableObjectNamespaces = [(className = "Counter", uniqueKey = "zig-worker-counter", enableSql = true)],
      durableObjectStorage = (localDisk = "storage"),
      compatibilityDate = "2026-03-17",
    )),
    (name = "storage", disk = (path = "storage", writable = true)),
    (name = "backend", worker = (
      modules = [(name = "backend.js", esModule = embed "backend.js")],
      compatibilityDate = "2026-03-17",
    )),
  ],
  sockets = [(name = "http", address = "127.0.0.1:8962", http = (), service = "main")],
);
