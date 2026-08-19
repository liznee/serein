#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace serein::remote {

enum class CaptureStatus {
  kFrame,
  kTimeout,
  kAccessLost,
  kFatal,
};

struct MonitorInfo {
  std::size_t index = 0;
  std::wstring device_name;
  std::wstring adapter_name;
  std::int32_t left = 0;
  std::int32_t top = 0;
  std::uint32_t width = 0;
  std::uint32_t height = 0;
  std::uint32_t rotation = 0;
  bool attached_to_desktop = false;
};

struct DesktopFrame {
  std::uint32_t width = 0;
  std::uint32_t height = 0;
  std::uint32_t stride = 0;
  std::uint64_t sequence = 0;
  std::int64_t captured_at_us = 0;
  std::vector<std::uint8_t> bgra;
};

// Normalizes a BGRA frame to top-left orientation. The rotation values match
// DXGI_MODE_ROTATION (0=unspecified, 1=identity, 2=90, 3=180, 4=270).
// This helper is public so the pixel transform can be tested without reading
// the user's desktop.
bool NormalizeBgraFrame(
    const std::uint8_t* source,
    std::uint32_t source_width,
    std::uint32_t source_height,
    std::uint32_t source_stride,
    std::uint32_t rotation,
    DesktopFrame* frame);

class DesktopCapture final {
 public:
  DesktopCapture();
  ~DesktopCapture();

  DesktopCapture(const DesktopCapture&) = delete;
  DesktopCapture& operator=(const DesktopCapture&) = delete;

  static std::vector<MonitorInfo> EnumerateMonitors(std::wstring* error);

  bool Initialize(std::size_t monitor_index, std::wstring* error);
  CaptureStatus CaptureNextFrame(
      DesktopFrame* frame,
      std::uint32_t timeout_ms,
      std::wstring* error);
  void Reset();

  const MonitorInfo& monitor() const;
  bool initialized() const;

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace serein::remote
