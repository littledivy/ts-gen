// std::mutex for C++ built against a libc++ without threads
// (wasm32-wasip1 has none), as a no-op: a Worker runs one thread, so it is
// never contended. libc++ still has the lock templates (lock_guard,
// unique_lock) and call_once. Force-included (-include) into libraries that guard
// shared state with them, such as GEOS's STRtree.
#pragma once
#ifdef __cplusplus
#include <mutex>
#if !_LIBCPP_HAS_THREADS
namespace std {
struct mutex {
  constexpr mutex() noexcept = default;
  mutex(const mutex&) = delete;
  mutex& operator=(const mutex&) = delete;
  void lock() {}
  bool try_lock() { return true; }
  void unlock() {}
};
}  // namespace std
#endif
#endif
