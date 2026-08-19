#include "serein/remote/h264_encoder.h"

#include <Windows.h>
#include <codecapi.h>
#include <icodecapi.h>
#include <mfapi.h>
#include <mferror.h>
#include <mfidl.h>
#include <wrl/client.h>

#include <algorithm>
#include <sstream>
#include <utility>

namespace serein::remote {
namespace {

using Microsoft::WRL::ComPtr;

std::wstring HResultMessage(HRESULT hr) {
  wchar_t* buffer = nullptr;
  const DWORD flags = FORMAT_MESSAGE_ALLOCATE_BUFFER |
                      FORMAT_MESSAGE_FROM_SYSTEM |
                      FORMAT_MESSAGE_IGNORE_INSERTS;
  const DWORD length = FormatMessageW(
      flags, nullptr, static_cast<DWORD>(hr),
      MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
      reinterpret_cast<wchar_t*>(&buffer), 0, nullptr);
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
    out << L" (" << message << L')';
  }
  if (buffer != nullptr) LocalFree(buffer);
  return out.str();
}

std::uint8_t ClampByte(int value) {
  return static_cast<std::uint8_t>(std::clamp(value, 0, 255));
}

bool BgraToNv12(
    const DesktopFrame& frame,
    std::uint8_t* destination,
    std::uint32_t destination_size) {
  if (destination == nullptr || frame.bgra.empty() || frame.width == 0 ||
      frame.height == 0 || (frame.width & 1U) != 0 ||
      (frame.height & 1U) != 0 || frame.stride < frame.width * 4) {
    return false;
  }
  const std::uint64_t required =
      static_cast<std::uint64_t>(frame.width) * frame.height * 3 / 2;
  if (required > destination_size) return false;

  std::uint8_t* y_plane = destination;
  std::uint8_t* uv_plane = destination + frame.width * frame.height;
  for (std::uint32_t y = 0; y < frame.height; ++y) {
    const auto* row = frame.bgra.data() + static_cast<std::size_t>(y) * frame.stride;
    for (std::uint32_t x = 0; x < frame.width; ++x) {
      const int b = row[x * 4];
      const int g = row[x * 4 + 1];
      const int r = row[x * 4 + 2];
      y_plane[static_cast<std::size_t>(y) * frame.width + x] =
          ClampByte(((66 * r + 129 * g + 25 * b + 128) >> 8) + 16);
    }
  }

  for (std::uint32_t y = 0; y < frame.height; y += 2) {
    for (std::uint32_t x = 0; x < frame.width; x += 2) {
      int u_sum = 0;
      int v_sum = 0;
      for (std::uint32_t dy = 0; dy < 2; ++dy) {
        const auto* row = frame.bgra.data() +
            static_cast<std::size_t>(y + dy) * frame.stride;
        for (std::uint32_t dx = 0; dx < 2; ++dx) {
          const int b = row[(x + dx) * 4];
          const int g = row[(x + dx) * 4 + 1];
          const int r = row[(x + dx) * 4 + 2];
          u_sum += ((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128;
          v_sum += ((112 * r - 94 * g - 18 * b + 128) >> 8) + 128;
        }
      }
      const std::size_t uv_offset =
          static_cast<std::size_t>(y / 2) * frame.width + x;
      uv_plane[uv_offset] = ClampByte((u_sum + 2) / 4);
      uv_plane[uv_offset + 1] = ClampByte((v_sum + 2) / 4);
    }
  }
  return true;
}

void TrySetCodecUInt32(ICodecAPI* codec, const GUID& key, std::uint32_t value) {
  if (codec == nullptr) return;
  VARIANT variant;
  VariantInit(&variant);
  variant.vt = VT_UI4;
  variant.ulVal = value;
  codec->SetValue(&key, &variant);
  VariantClear(&variant);
}

void TrySetCodecBool(ICodecAPI* codec, const GUID& key, bool value) {
  if (codec == nullptr) return;
  VARIANT variant;
  VariantInit(&variant);
  variant.vt = VT_BOOL;
  variant.boolVal = value ? VARIANT_TRUE : VARIANT_FALSE;
  codec->SetValue(&key, &variant);
  VariantClear(&variant);
}

}  // namespace

struct MfH264Encoder::Impl {
  H264EncoderConfig config;
  ComPtr<IMFTransform> transform;
  ComPtr<IMFActivate> activation;
  std::wstring encoder_name;
  std::uint32_t input_buffer_size = 0;
  std::int64_t frame_duration_100ns = 0;
  bool mf_started = false;
  bool initialized = false;

  bool PullOutput(
      std::vector<EncodedH264Frame>* output,
      bool draining,
      std::wstring* error) {
    MFT_OUTPUT_STREAM_INFO stream_info{};
    HRESULT hr = transform->GetOutputStreamInfo(0, &stream_info);
    if (FAILED(hr)) {
      if (error != nullptr) *error = L"GetOutputStreamInfo failed: " + HResultMessage(hr);
      return false;
    }

    for (;;) {
      ComPtr<IMFSample> sample;
      if ((stream_info.dwFlags & MFT_OUTPUT_STREAM_PROVIDES_SAMPLES) == 0) {
        hr = MFCreateSample(&sample);
        if (FAILED(hr)) {
          if (error != nullptr) *error = L"MFCreateSample output failed: " + HResultMessage(hr);
          return false;
        }
        ComPtr<IMFMediaBuffer> buffer;
        const DWORD output_size = std::max<DWORD>(
            stream_info.cbSize,
            std::max<DWORD>(64 * 1024, config.width * config.height));
        hr = MFCreateMemoryBuffer(output_size, &buffer);
        if (FAILED(hr)) {
          if (error != nullptr) *error = L"MFCreateMemoryBuffer output failed: " + HResultMessage(hr);
          return false;
        }
        sample->AddBuffer(buffer.Get());
      }

      MFT_OUTPUT_DATA_BUFFER data{};
      data.dwStreamID = 0;
      data.pSample = sample.Get();
      DWORD status = 0;
      hr = transform->ProcessOutput(0, 1, &data, &status);
      if (data.pEvents != nullptr) data.pEvents->Release();
      if (hr == MF_E_TRANSFORM_NEED_MORE_INPUT) return true;
      if (hr == MF_E_TRANSFORM_STREAM_CHANGE) {
        if (error != nullptr) *error = L"H.264 encoder changed its output type unexpectedly";
        return false;
      }
      if (FAILED(hr)) {
        if (error != nullptr) *error = L"ProcessOutput failed: " + HResultMessage(hr);
        return false;
      }

      ComPtr<IMFSample> produced = data.pSample;
      if (!produced) {
        if (error != nullptr) *error = L"H.264 encoder returned no output sample";
        return false;
      }
      ComPtr<IMFMediaBuffer> contiguous;
      hr = produced->ConvertToContiguousBuffer(&contiguous);
      if (FAILED(hr)) {
        if (error != nullptr) *error = L"ConvertToContiguousBuffer failed: " + HResultMessage(hr);
        return false;
      }
      BYTE* bytes = nullptr;
      DWORD current_length = 0;
      hr = contiguous->Lock(&bytes, nullptr, &current_length);
      if (FAILED(hr)) {
        if (error != nullptr) *error = L"Lock encoded buffer failed: " + HResultMessage(hr);
        return false;
      }
      EncodedH264Frame encoded;
      encoded.bytes.assign(bytes, bytes + current_length);
      contiguous->Unlock();
      LONGLONG timestamp = 0;
      if (SUCCEEDED(produced->GetSampleTime(&timestamp))) {
        encoded.timestamp_100ns = timestamp;
      }
      UINT32 clean_point = FALSE;
      encoded.key_frame = SUCCEEDED(produced->GetUINT32(
          MFSampleExtension_CleanPoint, &clean_point)) && clean_point != FALSE;
      if (!encoded.bytes.empty()) output->push_back(std::move(encoded));

      if (!draining) return true;
    }
  }
};

MfH264Encoder::MfH264Encoder() : impl_(std::make_unique<Impl>()) {}
MfH264Encoder::~MfH264Encoder() { Reset(); }

bool MfH264Encoder::Initialize(
    const H264EncoderConfig& config,
    std::wstring* error) {
  Reset();
  if (config.width == 0 || config.height == 0 || config.fps == 0 ||
      (config.width & 1U) != 0 || (config.height & 1U) != 0) {
    if (error != nullptr) *error = L"H.264 encoder requires positive even dimensions and FPS";
    return false;
  }

  HRESULT hr = MFStartup(MF_VERSION, MFSTARTUP_FULL);
  if (FAILED(hr)) {
    if (error != nullptr) *error = L"MFStartup failed: " + HResultMessage(hr);
    return false;
  }
  impl_->mf_started = true;
  impl_->config = config;
  impl_->input_buffer_size = config.width * config.height * 3 / 2;
  impl_->frame_duration_100ns = 10'000'000LL / config.fps;

  MFT_REGISTER_TYPE_INFO input_info{MFMediaType_Video, MFVideoFormat_NV12};
  MFT_REGISTER_TYPE_INFO output_info{MFMediaType_Video, MFVideoFormat_H264};
  IMFActivate** activations = nullptr;
  UINT32 activation_count = 0;
  hr = MFTEnumEx(
      MFT_CATEGORY_VIDEO_ENCODER,
      MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_SORTANDFILTER,
      &input_info, &output_info, &activations, &activation_count);
  if (FAILED(hr) || activation_count == 0) {
    if (activations != nullptr) CoTaskMemFree(activations);
    if (error != nullptr) {
      *error = L"No synchronous NV12 to H.264 Media Foundation encoder is available";
    }
    Reset();
    return false;
  }

  impl_->activation = activations[0];
  for (UINT32 index = 1; index < activation_count; ++index) activations[index]->Release();
  CoTaskMemFree(activations);

  wchar_t* friendly_name = nullptr;
  UINT32 friendly_name_length = 0;
  if (SUCCEEDED(impl_->activation->GetAllocatedString(
          MFT_FRIENDLY_NAME_Attribute, &friendly_name, &friendly_name_length)) &&
      friendly_name != nullptr) {
    impl_->encoder_name.assign(friendly_name, friendly_name_length);
    CoTaskMemFree(friendly_name);
  } else {
    impl_->encoder_name = L"Media Foundation H.264 Encoder";
  }

  hr = impl_->activation->ActivateObject(IID_PPV_ARGS(&impl_->transform));
  if (FAILED(hr)) {
    if (error != nullptr) *error = L"Activate H.264 encoder failed: " + HResultMessage(hr);
    Reset();
    return false;
  }

  ComPtr<IMFAttributes> attributes;
  if (SUCCEEDED(impl_->transform->GetAttributes(&attributes))) {
    attributes->SetUINT32(MF_LOW_LATENCY, TRUE);
  }
  ComPtr<ICodecAPI> codec;
  if (SUCCEEDED(impl_->transform.As(&codec))) {
    TrySetCodecUInt32(codec.Get(), CODECAPI_AVEncCommonMeanBitRate, config.bitrate);
    TrySetCodecUInt32(
        codec.Get(), CODECAPI_AVEncCommonRateControlMode,
        eAVEncCommonRateControlMode_CBR);
    TrySetCodecUInt32(codec.Get(), CODECAPI_AVEncMPVGOPSize, config.fps * 2);
    TrySetCodecBool(codec.Get(), CODECAPI_AVLowLatencyMode, true);
  }

  ComPtr<IMFMediaType> output_type;
  hr = MFCreateMediaType(&output_type);
  if (SUCCEEDED(hr)) hr = output_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  if (SUCCEEDED(hr)) hr = output_type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
  if (SUCCEEDED(hr)) hr = MFSetAttributeSize(
      output_type.Get(), MF_MT_FRAME_SIZE, config.width, config.height);
  if (SUCCEEDED(hr)) hr = MFSetAttributeRatio(
      output_type.Get(), MF_MT_FRAME_RATE, config.fps, 1);
  if (SUCCEEDED(hr)) hr = MFSetAttributeRatio(
      output_type.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
  if (SUCCEEDED(hr)) hr = output_type->SetUINT32(
      MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
  if (SUCCEEDED(hr)) hr = output_type->SetUINT32(MF_MT_AVG_BITRATE, config.bitrate);
  if (SUCCEEDED(hr)) hr = output_type->SetUINT32(
      MF_MT_MPEG2_PROFILE, eAVEncH264VProfile_Main);
  if (SUCCEEDED(hr)) hr = impl_->transform->SetOutputType(0, output_type.Get(), 0);
  if (FAILED(hr)) {
    if (error != nullptr) *error = L"Set H.264 output type failed: " + HResultMessage(hr);
    Reset();
    return false;
  }

  ComPtr<IMFMediaType> input_type;
  hr = MFCreateMediaType(&input_type);
  if (SUCCEEDED(hr)) hr = input_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  if (SUCCEEDED(hr)) hr = input_type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12);
  if (SUCCEEDED(hr)) hr = MFSetAttributeSize(
      input_type.Get(), MF_MT_FRAME_SIZE, config.width, config.height);
  if (SUCCEEDED(hr)) hr = MFSetAttributeRatio(
      input_type.Get(), MF_MT_FRAME_RATE, config.fps, 1);
  if (SUCCEEDED(hr)) hr = MFSetAttributeRatio(
      input_type.Get(), MF_MT_PIXEL_ASPECT_RATIO, 1, 1);
  if (SUCCEEDED(hr)) hr = input_type->SetUINT32(
      MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
  if (SUCCEEDED(hr)) hr = input_type->SetUINT32(MF_MT_ALL_SAMPLES_INDEPENDENT, TRUE);
  if (SUCCEEDED(hr)) hr = input_type->SetUINT32(MF_MT_FIXED_SIZE_SAMPLES, TRUE);
  if (SUCCEEDED(hr)) hr = input_type->SetUINT32(MF_MT_SAMPLE_SIZE, impl_->input_buffer_size);
  if (SUCCEEDED(hr)) hr = input_type->SetUINT32(MF_MT_DEFAULT_STRIDE, config.width);
  if (SUCCEEDED(hr)) hr = impl_->transform->SetInputType(0, input_type.Get(), 0);
  if (FAILED(hr)) {
    if (error != nullptr) *error = L"Set NV12 input type failed: " + HResultMessage(hr);
    Reset();
    return false;
  }

  hr = impl_->transform->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
  if (SUCCEEDED(hr)) hr = impl_->transform->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
  if (FAILED(hr)) {
    if (error != nullptr) *error = L"Start H.264 encoder stream failed: " + HResultMessage(hr);
    Reset();
    return false;
  }

  impl_->initialized = true;
  return true;
}

bool MfH264Encoder::EncodeBgra(
    const DesktopFrame& frame,
    std::int64_t timestamp_100ns,
    std::vector<EncodedH264Frame>* output,
    std::wstring* error) {
  if (!impl_->initialized || output == nullptr ||
      frame.width != impl_->config.width || frame.height != impl_->config.height) {
    if (error != nullptr) *error = L"H.264 encoder input does not match its configuration";
    return false;
  }

  ComPtr<IMFMediaBuffer> buffer;
  HRESULT hr = MFCreateMemoryBuffer(impl_->input_buffer_size, &buffer);
  if (FAILED(hr)) {
    if (error != nullptr) *error = L"MFCreateMemoryBuffer input failed: " + HResultMessage(hr);
    return false;
  }
  BYTE* destination = nullptr;
  DWORD capacity = 0;
  hr = buffer->Lock(&destination, &capacity, nullptr);
  if (FAILED(hr)) {
    if (error != nullptr) *error = L"Lock input buffer failed: " + HResultMessage(hr);
    return false;
  }
  const bool converted = BgraToNv12(frame, destination, capacity);
  buffer->Unlock();
  if (!converted) {
    if (error != nullptr) *error = L"BGRA to NV12 conversion failed";
    return false;
  }
  buffer->SetCurrentLength(impl_->input_buffer_size);

  ComPtr<IMFSample> sample;
  hr = MFCreateSample(&sample);
  if (SUCCEEDED(hr)) hr = sample->AddBuffer(buffer.Get());
  if (SUCCEEDED(hr)) hr = sample->SetSampleTime(timestamp_100ns);
  if (SUCCEEDED(hr)) hr = sample->SetSampleDuration(impl_->frame_duration_100ns);
  if (FAILED(hr)) {
    if (error != nullptr) *error = L"Create H.264 input sample failed: " + HResultMessage(hr);
    return false;
  }

  hr = impl_->transform->ProcessInput(0, sample.Get(), 0);
  if (FAILED(hr)) {
    if (error != nullptr) *error = L"ProcessInput failed: " + HResultMessage(hr);
    return false;
  }
  return impl_->PullOutput(output, false, error);
}

bool MfH264Encoder::Drain(
    std::vector<EncodedH264Frame>* output,
    std::wstring* error) {
  if (!impl_->initialized || output == nullptr) return false;
  HRESULT hr = impl_->transform->ProcessMessage(MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0);
  if (SUCCEEDED(hr)) hr = impl_->transform->ProcessMessage(MFT_MESSAGE_COMMAND_DRAIN, 0);
  if (FAILED(hr)) {
    if (error != nullptr) *error = L"Drain H.264 encoder failed: " + HResultMessage(hr);
    return false;
  }
  return impl_->PullOutput(output, true, error);
}

void MfH264Encoder::Reset() {
  if (impl_->transform) {
    impl_->transform->ProcessMessage(MFT_MESSAGE_NOTIFY_END_STREAMING, 0);
    impl_->transform.Reset();
  }
  if (impl_->activation) {
    impl_->activation->ShutdownObject();
    impl_->activation.Reset();
  }
  if (impl_->mf_started) {
    MFShutdown();
    impl_->mf_started = false;
  }
  impl_->encoder_name.clear();
  impl_->input_buffer_size = 0;
  impl_->frame_duration_100ns = 0;
  impl_->initialized = false;
}

const std::wstring& MfH264Encoder::encoder_name() const { return impl_->encoder_name; }
bool MfH264Encoder::initialized() const { return impl_->initialized; }

bool ValidateH264Decode(
    const H264EncoderConfig& config,
    const std::vector<EncodedH264Frame>& input,
    std::uint64_t* decoded_frames,
    std::wstring* error) {
  if (decoded_frames == nullptr || input.empty()) return false;
  *decoded_frames = 0;

  MFT_REGISTER_TYPE_INFO input_info{MFMediaType_Video, MFVideoFormat_H264};
  MFT_REGISTER_TYPE_INFO output_info{MFMediaType_Video, MFVideoFormat_NV12};
  IMFActivate** activations = nullptr;
  UINT32 activation_count = 0;
  HRESULT hr = MFTEnumEx(
      MFT_CATEGORY_VIDEO_DECODER,
      MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_SORTANDFILTER,
      &input_info, &output_info, &activations, &activation_count);
  if (FAILED(hr) || activation_count == 0) {
    if (activations != nullptr) CoTaskMemFree(activations);
    if (error != nullptr) *error = L"No synchronous H.264 decoder is available";
    return false;
  }

  ComPtr<IMFActivate> activation = activations[0];
  for (UINT32 index = 1; index < activation_count; ++index) activations[index]->Release();
  CoTaskMemFree(activations);
  ComPtr<IMFTransform> decoder;
  hr = activation->ActivateObject(IID_PPV_ARGS(&decoder));
  if (FAILED(hr)) {
    if (error != nullptr) *error = L"Activate H.264 decoder failed: " + HResultMessage(hr);
    return false;
  }

  ComPtr<IMFMediaType> compressed_type;
  hr = MFCreateMediaType(&compressed_type);
  if (SUCCEEDED(hr)) hr = compressed_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  if (SUCCEEDED(hr)) hr = compressed_type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_H264);
  if (SUCCEEDED(hr)) hr = MFSetAttributeSize(
      compressed_type.Get(), MF_MT_FRAME_SIZE, config.width, config.height);
  if (SUCCEEDED(hr)) hr = MFSetAttributeRatio(
      compressed_type.Get(), MF_MT_FRAME_RATE, config.fps, 1);
  if (SUCCEEDED(hr)) hr = compressed_type->SetUINT32(
      MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
  if (SUCCEEDED(hr)) hr = decoder->SetInputType(0, compressed_type.Get(), 0);
  if (FAILED(hr)) {
    if (error != nullptr) *error = L"Set H.264 decoder input type failed: " + HResultMessage(hr);
    activation->ShutdownObject();
    return false;
  }

  ComPtr<IMFMediaType> decoded_type;
  hr = MFCreateMediaType(&decoded_type);
  if (SUCCEEDED(hr)) hr = decoded_type->SetGUID(MF_MT_MAJOR_TYPE, MFMediaType_Video);
  if (SUCCEEDED(hr)) hr = decoded_type->SetGUID(MF_MT_SUBTYPE, MFVideoFormat_NV12);
  if (SUCCEEDED(hr)) hr = MFSetAttributeSize(
      decoded_type.Get(), MF_MT_FRAME_SIZE, config.width, config.height);
  if (SUCCEEDED(hr)) hr = MFSetAttributeRatio(
      decoded_type.Get(), MF_MT_FRAME_RATE, config.fps, 1);
  if (SUCCEEDED(hr)) hr = decoded_type->SetUINT32(
      MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive);
  if (SUCCEEDED(hr)) hr = decoder->SetOutputType(0, decoded_type.Get(), 0);
  if (FAILED(hr)) {
    if (error != nullptr) *error = L"Set H.264 decoder output type failed: " + HResultMessage(hr);
    activation->ShutdownObject();
    return false;
  }

  hr = decoder->ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
  if (SUCCEEDED(hr)) hr = decoder->ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
  if (FAILED(hr)) {
    if (error != nullptr) *error = L"Start H.264 decoder failed: " + HResultMessage(hr);
    activation->ShutdownObject();
    return false;
  }

  MFT_OUTPUT_STREAM_INFO stream_info{};
  hr = decoder->GetOutputStreamInfo(0, &stream_info);
  if (FAILED(hr)) {
    if (error != nullptr) *error = L"Get H.264 decoder output info failed: " + HResultMessage(hr);
    activation->ShutdownObject();
    return false;
  }
  const DWORD raw_size = config.width * config.height * 3 / 2;
  auto pull_output = [&](bool draining) -> bool {
    for (;;) {
      ComPtr<IMFSample> sample;
      if ((stream_info.dwFlags & MFT_OUTPUT_STREAM_PROVIDES_SAMPLES) == 0) {
        HRESULT sample_hr = MFCreateSample(&sample);
        ComPtr<IMFMediaBuffer> buffer;
        if (SUCCEEDED(sample_hr)) {
          sample_hr = MFCreateMemoryBuffer(
              std::max<DWORD>(stream_info.cbSize, raw_size), &buffer);
        }
        if (SUCCEEDED(sample_hr)) sample_hr = sample->AddBuffer(buffer.Get());
        if (FAILED(sample_hr)) {
          if (error != nullptr) {
            *error = L"Create H.264 decoder output sample failed: " +
                HResultMessage(sample_hr);
          }
          return false;
        }
      }
      MFT_OUTPUT_DATA_BUFFER data{};
      data.dwStreamID = 0;
      data.pSample = sample.Get();
      DWORD status = 0;
      HRESULT output_hr = decoder->ProcessOutput(0, 1, &data, &status);
      if (data.pEvents != nullptr) data.pEvents->Release();
      if (output_hr == MF_E_TRANSFORM_NEED_MORE_INPUT) return true;
      if (output_hr == MF_E_TRANSFORM_STREAM_CHANGE) {
        ComPtr<IMFMediaType> available_type;
        HRESULT type_hr = E_FAIL;
        for (DWORD type_index = 0;; ++type_index) {
          ComPtr<IMFMediaType> candidate;
          type_hr = decoder->GetOutputAvailableType(0, type_index, &candidate);
          if (type_hr == MF_E_NO_MORE_TYPES) break;
          if (FAILED(type_hr)) break;
          GUID subtype{};
          if (SUCCEEDED(candidate->GetGUID(MF_MT_SUBTYPE, &subtype)) &&
              subtype == MFVideoFormat_NV12) {
            available_type = candidate;
            break;
          }
        }
        if (!available_type) {
          if (error != nullptr) *error = L"H.264 decoder did not offer NV12 after stream change";
          return false;
        }
        type_hr = decoder->SetOutputType(0, available_type.Get(), 0);
        if (SUCCEEDED(type_hr)) type_hr = decoder->GetOutputStreamInfo(0, &stream_info);
        if (FAILED(type_hr)) {
          if (error != nullptr) {
            *error = L"Renegotiate H.264 decoder output failed: " + HResultMessage(type_hr);
          }
          return false;
        }
        continue;
      }
      if (FAILED(output_hr)) {
        if (error != nullptr) {
          *error = L"Decode ProcessOutput failed: " + HResultMessage(output_hr);
        }
        return false;
      }
      ComPtr<IMFSample> produced = data.pSample;
      DWORD total_length = 0;
      if (!produced || FAILED(produced->GetTotalLength(&total_length)) ||
          total_length == 0) {
        if (error != nullptr) *error = L"H.264 decoder produced an empty frame";
        return false;
      }
      ++(*decoded_frames);
      if (!draining) return true;
    }
  };

  const std::int64_t duration = 10'000'000LL / config.fps;
  for (const auto& encoded : input) {
    ComPtr<IMFMediaBuffer> buffer;
    hr = MFCreateMemoryBuffer(static_cast<DWORD>(encoded.bytes.size()), &buffer);
    BYTE* destination = nullptr;
    DWORD capacity = 0;
    if (SUCCEEDED(hr)) hr = buffer->Lock(&destination, &capacity, nullptr);
    if (SUCCEEDED(hr) && encoded.bytes.size() <= capacity) {
      std::copy(encoded.bytes.begin(), encoded.bytes.end(), destination);
      buffer->Unlock();
      hr = buffer->SetCurrentLength(static_cast<DWORD>(encoded.bytes.size()));
    } else if (SUCCEEDED(hr)) {
      buffer->Unlock();
      hr = E_FAIL;
    }
    ComPtr<IMFSample> sample;
    if (SUCCEEDED(hr)) hr = MFCreateSample(&sample);
    if (SUCCEEDED(hr)) hr = sample->AddBuffer(buffer.Get());
    if (SUCCEEDED(hr)) hr = sample->SetSampleTime(encoded.timestamp_100ns);
    if (SUCCEEDED(hr)) hr = sample->SetSampleDuration(duration);
    if (SUCCEEDED(hr)) {
      sample->SetUINT32(MFSampleExtension_CleanPoint, encoded.key_frame ? TRUE : FALSE);
      hr = decoder->ProcessInput(0, sample.Get(), 0);
    }
    if (hr == MF_E_NOTACCEPTING) {
      if (!pull_output(false)) {
        decoder->ProcessMessage(MFT_MESSAGE_NOTIFY_END_STREAMING, 0);
        activation->ShutdownObject();
        return false;
      }
      hr = decoder->ProcessInput(0, sample.Get(), 0);
    }
    if (FAILED(hr) || !pull_output(false)) {
      if (FAILED(hr) && error != nullptr) {
        *error = L"Decode ProcessInput failed: " + HResultMessage(hr);
      }
      decoder->ProcessMessage(MFT_MESSAGE_NOTIFY_END_STREAMING, 0);
      activation->ShutdownObject();
      return false;
    }
  }

  hr = decoder->ProcessMessage(MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0);
  if (SUCCEEDED(hr)) hr = decoder->ProcessMessage(MFT_MESSAGE_COMMAND_DRAIN, 0);
  const bool pulled = SUCCEEDED(hr) && pull_output(true);
  decoder->ProcessMessage(MFT_MESSAGE_NOTIFY_END_STREAMING, 0);
  decoder.Reset();
  activation->ShutdownObject();
  if (!pulled && error != nullptr && error->empty()) {
    *error = L"Drain H.264 decoder failed: " + HResultMessage(hr);
  }
  return pulled && *decoded_frames > 0;
}

}  // namespace serein::remote
