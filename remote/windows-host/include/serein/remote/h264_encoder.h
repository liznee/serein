#pragma once

#include "serein/remote/desktop_capture.h"

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace serein::remote {

struct H264EncoderConfig {
  std::uint32_t width = 1280;
  std::uint32_t height = 720;
  std::uint32_t fps = 15;
  std::uint32_t bitrate = 2'000'000;
};

struct EncodedH264Frame {
  std::int64_t timestamp_100ns = 0;
  bool key_frame = false;
  std::vector<std::uint8_t> bytes;
};

class MfH264Encoder final {
 public:
  MfH264Encoder();
  ~MfH264Encoder();

  MfH264Encoder(const MfH264Encoder&) = delete;
  MfH264Encoder& operator=(const MfH264Encoder&) = delete;

  bool Initialize(const H264EncoderConfig& config, std::wstring* error);
  bool EncodeBgra(
      const DesktopFrame& frame,
      std::int64_t timestamp_100ns,
      std::vector<EncodedH264Frame>* output,
      std::wstring* error);
  bool Drain(std::vector<EncodedH264Frame>* output, std::wstring* error);
  void Reset();

  const std::wstring& encoder_name() const;
  bool initialized() const;

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

// Decodes encoded samples entirely in memory with the system H.264 decoder.
// Intended for capability/self-tests; no file or desktop access is performed.
bool ValidateH264Decode(
    const H264EncoderConfig& config,
    const std::vector<EncodedH264Frame>& input,
    std::uint64_t* decoded_frames,
    std::wstring* error);

}  // namespace serein::remote
