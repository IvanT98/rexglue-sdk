// Number of frames the GPU has presented (XE_SWAP packets). Exported so a game exe can
// read it through GetProcAddress (e.g. for a frame-rate counter) without a link
// dependency on the GPU plugin.

#include <atomic>
#include <cstdint>

namespace rex::graphics::swap_stats {
std::atomic<uint64_t> g_swaps{0};
}  // namespace rex::graphics::swap_stats

#ifdef _WIN32
extern "C" __declspec(dllexport) uint64_t rex_gpu_swap_count() {
  return rex::graphics::swap_stats::g_swaps.load(std::memory_order_relaxed);
}
#endif
