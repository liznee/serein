#include "serein/remote/desktop_capture.h"

#include <Windows.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <wrl/client.h>

#include <algorithm>
#include <chrono>
#include <cstring>
#include <iomanip>
#include <iterator>
#include <sstream>
#include <utility>

namespace serein::remote {
namespace {

using Microsoft::WRL::ComPtr;

struct OutputSelection {
  ComPtr<IDXGIAdapter1> adapter;
  ComPtr<IDXGIOutput> output;
  MonitorInfo info;
};

std::wstring HResultMessage(HRESULT hr) {
  wchar_t* buffer = nullptr;
  const DWORD flags = FORMAT_MESSAGE_ALLOCATE_BUFFER |
                      FORMAT_MESSAGE_FROM_SYSTEM |
                      FORMAT_MESSAGE_IGNORE_INSERTS;
  const DWORD length = FormatMessageW(
      flags,
      nullptr,
      static_cast<DWORD>(hr),
      MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
      reinterpret_cast<wchar_t*>(&buffer),
      0,
      nullptr);

  std::wostringstream out;
  out << L"HRESULT 0x" << std::hex << std::uppercase
      << static_cast<unsigned long>(hr);
  if (length != 0 && buffer != nullptr) {
    std::wstring message(buffer, length);
    while (!message.empty() &&
           (message.back() == L'\r' || message.back() == L'\n' ||
            message.back() == L' ')) {
      message.pop_back();
    }
    out << L" (" << message << L")";
  }
  if (buffer != nullptr) LocalFree(buffer);
  return out.str();
}

std::vector<OutputSelection> EnumerateOutputs(std::wstring* error) {
  std::vector<OutputSelection> outputs;
  ComPtr<IDXGIFactory1> factory;
  HRESULT hr = CreateDXGIFactory1(IID_PPV_ARGS(&factory));
  if (FAILED(hr)) {
    if (error != nullptr) *error = L"CreateDXGIFactory1 failed: " + HResultMessage(hr);
    return outputs;
  }

  std::size_t monitor_index = 0;
  for (UINT adapter_index = 0;; ++adapter_index) {
    ComPtr<IDXGIAdapter1> adapter;
    hr = factory->EnumAdapters1(adapter_index, &adapter);
    if (hr == DXGI_ERROR_NOT_FOUND) break;
    if (FAILED(hr)) {
      if (error != nullptr) *error = L"EnumAdapters1 failed: " + HResultMessage(hr);
      return {};
    }

    DXGI_ADAPTER_DESC1 adapter_desc{};
    adapter->GetDesc1(&adapter_desc);

    for (UINT output_index = 0;; ++output_index) {
      ComPtr<IDXGIOutput> output;
      hr = adapter->EnumOutputs(output_index, &output);
      if (hr == DXGI_ERROR_NOT_FOUND) break;
      if (FAILED(hr)) {
        if (error != nullptr) *error = L"EnumOutputs failed: " + HResultMessage(hr);
        return {};
      }

      DXGI_OUTPUT_DESC desc{};
      hr = output->GetDesc(&desc);
      if (FAILED(hr)) continue;

      const LONG width = desc.DesktopCoordinates.right - desc.DesktopCoordinates.left;
      const LONG height = desc.DesktopCoordinates.bottom - desc.DesktopCoordinates.top;
      if (width <= 0 || height <= 0) continue;

      MonitorInfo info;
      info.index = monitor_index++;
      info.device_name = desc.DeviceName;
      info.adapter_name = adapter_desc.Description;
      info.left = desc.DesktopCoordinates.left;
      info.top = desc.DesktopCoordinates.top;
      info.width = static_cast<std::uint32_t>(width);
      info.height = static_cast<std::uint32_t>(height);
      info.rotation = static_cast<std::uint32_t>(desc.Rotation);
      info.attached_to_desktop = desc.AttachedToDesktop != FALSE;
      outputs.push_back(OutputSelection{adapter, output, std::move(info)});
    }
  }

  if (outputs.empty() && error != nullptr) {
    *error = L"No attached DXGI outputs were found in the interactive session";
  }
  return outputs;
}

void RotateBgra(
    const std::uint8_t* source,
    std::uint32_t source_width,
    std::uint32_t source_height,
    std::uint32_t source_stride,
    DXGI_MODE_ROTATION rotation,
    DesktopFrame* frame) {
  if (rotation == DXGI_MODE_ROTATION_UNSPECIFIED ||
      rotation == DXGI_MODE_ROTATION_IDENTITY) {
    frame->width = source_width;
    frame->height = source_height;
    frame->stride = source_width * 4;
    frame->bgra.resize(static_cast<std::size_t>(frame->stride) * frame->height);
    for (std::uint32_t y = 0; y < source_height; ++y) {
      std::memcpy(
          frame->bgra.data() + static_cast<std::size_t>(y) * frame->stride,
          source + static_cast<std::size_t>(y) * source_stride,
          frame->stride);
    }
    return;
  }

  if (rotation == DXGI_MODE_ROTATION_ROTATE90 ||
      rotation == DXGI_MODE_ROTATION_ROTATE270) {
    frame->width = source_height;
    frame->height = source_width;
  } else {
    frame->width = source_width;
    frame->height = source_height;
  }
  frame->stride = frame->width * 4;
  frame->bgra.assign(static_cast<std::size_t>(frame->stride) * frame->height, 0);

  for (std::uint32_t source_y = 0; source_y < source_height; ++source_y) {
    for (std::uint32_t source_x = 0; source_x < source_width; ++source_x) {
      std::uint32_t dest_x = source_x;
      std::uint32_t dest_y = source_y;
      switch (rotation) {
        case DXGI_MODE_ROTATION_ROTATE90:
          dest_x = source_height - 1 - source_y;
          dest_y = source_x;
          break;
        case DXGI_MODE_ROTATION_ROTATE180:
          dest_x = source_width - 1 - source_x;
          dest_y = source_height - 1 - source_y;
          break;
        case DXGI_MODE_ROTATION_ROTATE270:
          dest_x = source_y;
          dest_y = source_width - 1 - source_x;
          break;
        default:
          break;
      }

      const auto* source_pixel = source +
          static_cast<std::size_t>(source_y) * source_stride + source_x * 4;
      auto* dest_pixel = frame->bgra.data() +
          static_cast<std::size_t>(dest_y) * frame->stride + dest_x * 4;
      std::memcpy(dest_pixel, source_pixel, 4);
    }
  }
}

class FrameReleaseGuard final {
 public:
  explicit FrameReleaseGuard(IDXGIOutputDuplication* duplication)
      : duplication_(duplication) {}
  ~FrameReleaseGuard() {
    if (duplication_ != nullptr) duplication_->ReleaseFrame();
  }

 private:
  IDXGIOutputDuplication* duplication_;
};

}  // namespace

bool NormalizeBgraFrame(
    const std::uint8_t* source,
    std::uint32_t source_width,
    std::uint32_t source_height,
    std::uint32_t source_stride,
    std::uint32_t rotation,
    DesktopFrame* frame) {
  if (source == nullptr || frame == nullptr || source_width == 0 ||
      source_height == 0 || source_stride < source_width * 4 || rotation > 4) {
    return false;
  }
  RotateBgra(
      source,
      source_width,
      source_height,
      source_stride,
      static_cast<DXGI_MODE_ROTATION>(rotation),
      frame);
  return frame->width > 0 && frame->height > 0 && !frame->bgra.empty();
}

struct DesktopCapture::Impl {
  MonitorInfo monitor;
  ComPtr<ID3D11Device> device;
  ComPtr<ID3D11DeviceContext> context;
  ComPtr<IDXGIOutputDuplication> duplication;
  ComPtr<ID3D11Texture2D> staging;
  D3D11_TEXTURE2D_DESC staging_desc{};
  std::uint64_t sequence = 0;
  bool initialized = false;
};

DesktopCapture::DesktopCapture() : impl_(std::make_unique<Impl>()) {}

DesktopCapture::~DesktopCapture() = default;

std::vector<MonitorInfo> DesktopCapture::EnumerateMonitors(std::wstring* error) {
  const auto selections = EnumerateOutputs(error);
  std::vector<MonitorInfo> monitors;
  monitors.reserve(selections.size());
  for (const auto& selection : selections) monitors.push_back(selection.info);
  return monitors;
}

bool DesktopCapture::Initialize(std::size_t monitor_index, std::wstring* error) {
  Reset();
  auto selections = EnumerateOutputs(error);
  if (monitor_index >= selections.size()) {
    if (error != nullptr) *error = L"Monitor index is outside the enumerated output list";
    return false;
  }

  auto& selected = selections[monitor_index];
  UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
  const D3D_FEATURE_LEVEL levels[] = {
      D3D_FEATURE_LEVEL_11_1,
      D3D_FEATURE_LEVEL_11_0,
      D3D_FEATURE_LEVEL_10_1,
      D3D_FEATURE_LEVEL_10_0,
  };
  D3D_FEATURE_LEVEL selected_level{};
  HRESULT hr = D3D11CreateDevice(
      selected.adapter.Get(),
      D3D_DRIVER_TYPE_UNKNOWN,
      nullptr,
      flags,
      levels,
      static_cast<UINT>(std::size(levels)),
      D3D11_SDK_VERSION,
      &impl_->device,
      &selected_level,
      &impl_->context);
  if (hr == E_INVALIDARG) {
    hr = D3D11CreateDevice(
        selected.adapter.Get(),
        D3D_DRIVER_TYPE_UNKNOWN,
        nullptr,
        flags,
        levels + 1,
        static_cast<UINT>(std::size(levels) - 1),
        D3D11_SDK_VERSION,
        &impl_->device,
        &selected_level,
        &impl_->context);
  }
  if (FAILED(hr)) {
    if (error != nullptr) *error = L"D3D11CreateDevice failed: " + HResultMessage(hr);
    Reset();
    return false;
  }

  ComPtr<IDXGIOutput1> output1;
  hr = selected.output.As(&output1);
  if (FAILED(hr)) {
    if (error != nullptr) *error = L"IDXGIOutput1 is unavailable: " + HResultMessage(hr);
    Reset();
    return false;
  }

  hr = output1->DuplicateOutput(impl_->device.Get(), &impl_->duplication);
  if (FAILED(hr)) {
    if (error != nullptr) {
      *error = L"DuplicateOutput failed: " + HResultMessage(hr) +
          L". Run inside an unlocked interactive Windows session.";
    }
    Reset();
    return false;
  }

  impl_->monitor = selected.info;
  impl_->sequence = 0;
  impl_->initialized = true;
  return true;
}

CaptureStatus DesktopCapture::CaptureNextFrame(
    DesktopFrame* frame,
    std::uint32_t timeout_ms,
    std::wstring* error) {
  if (!impl_->initialized || frame == nullptr) {
    if (error != nullptr) *error = L"DesktopCapture is not initialized";
    return CaptureStatus::kFatal;
  }

  DXGI_OUTDUPL_FRAME_INFO frame_info{};
  ComPtr<IDXGIResource> resource;
  HRESULT hr = impl_->duplication->AcquireNextFrame(
      timeout_ms, &frame_info, &resource);
  if (hr == DXGI_ERROR_WAIT_TIMEOUT) return CaptureStatus::kTimeout;
  if (hr == DXGI_ERROR_ACCESS_LOST) {
    if (error != nullptr) *error = L"DXGI duplication access was lost";
    return CaptureStatus::kAccessLost;
  }
  if (FAILED(hr)) {
    if (error != nullptr) *error = L"AcquireNextFrame failed: " + HResultMessage(hr);
    return CaptureStatus::kFatal;
  }
  FrameReleaseGuard release_guard(impl_->duplication.Get());

  ComPtr<ID3D11Texture2D> texture;
  hr = resource.As(&texture);
  if (FAILED(hr)) {
    if (error != nullptr) *error = L"Captured resource is not a texture: " + HResultMessage(hr);
    return CaptureStatus::kFatal;
  }

  D3D11_TEXTURE2D_DESC desc{};
  texture->GetDesc(&desc);
  if (desc.Format != DXGI_FORMAT_B8G8R8A8_UNORM) {
    if (error != nullptr) *error = L"Unexpected desktop duplication pixel format";
    return CaptureStatus::kFatal;
  }

  const bool recreate_staging = !impl_->staging ||
      impl_->staging_desc.Width != desc.Width ||
      impl_->staging_desc.Height != desc.Height ||
      impl_->staging_desc.Format != desc.Format;
  if (recreate_staging) {
    D3D11_TEXTURE2D_DESC staging_desc = desc;
    staging_desc.BindFlags = 0;
    staging_desc.MiscFlags = 0;
    staging_desc.Usage = D3D11_USAGE_STAGING;
    staging_desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    staging_desc.MipLevels = 1;
    staging_desc.ArraySize = 1;
    staging_desc.SampleDesc.Count = 1;
    staging_desc.SampleDesc.Quality = 0;

    impl_->staging.Reset();
    hr = impl_->device->CreateTexture2D(
        &staging_desc, nullptr, &impl_->staging);
    if (FAILED(hr)) {
      if (error != nullptr) *error = L"CreateTexture2D staging failed: " + HResultMessage(hr);
      return CaptureStatus::kFatal;
    }
    impl_->staging_desc = staging_desc;
  }

  impl_->context->CopyResource(impl_->staging.Get(), texture.Get());
  D3D11_MAPPED_SUBRESOURCE mapped{};
  hr = impl_->context->Map(
      impl_->staging.Get(), 0, D3D11_MAP_READ, 0, &mapped);
  if (FAILED(hr)) {
    if (error != nullptr) *error = L"Map captured frame failed: " + HResultMessage(hr);
    return CaptureStatus::kFatal;
  }

  const bool normalized = NormalizeBgraFrame(
      static_cast<const std::uint8_t*>(mapped.pData),
      desc.Width,
      desc.Height,
      mapped.RowPitch,
      impl_->monitor.rotation,
      frame);
  impl_->context->Unmap(impl_->staging.Get(), 0);
  if (!normalized) {
    if (error != nullptr) *error = L"Failed to normalize the captured BGRA frame";
    return CaptureStatus::kFatal;
  }

  frame->sequence = ++impl_->sequence;
  frame->captured_at_us = std::chrono::duration_cast<std::chrono::microseconds>(
      std::chrono::steady_clock::now().time_since_epoch()).count();
  return CaptureStatus::kFrame;
}

void DesktopCapture::Reset() {
  impl_->staging.Reset();
  impl_->duplication.Reset();
  impl_->context.Reset();
  impl_->device.Reset();
  impl_->staging_desc = {};
  impl_->monitor = {};
  impl_->sequence = 0;
  impl_->initialized = false;
}

const MonitorInfo& DesktopCapture::monitor() const {
  return impl_->monitor;
}

bool DesktopCapture::initialized() const {
  return impl_->initialized;
}

}  // namespace serein::remote
