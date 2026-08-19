#include "serein/remote/desktop_capture.h"
#include "serein/remote/h264_encoder.h"
#include "serein/remote/host_service.h"

#include <Windows.h>
#include <objbase.h>

#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cwchar>
#include <iostream>
#include <limits>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

namespace {

using serein::remote::CaptureStatus;
using serein::remote::DesktopCapture;
using serein::remote::DesktopFrame;
using serein::remote::H264EncoderConfig;
using serein::remote::MfH264Encoder;
using serein::remote::MonitorInfo;
using serein::remote::NormalizeBgraFrame;
using serein::remote::ValidateH264Decode;

struct Options {
  std::size_t monitor_index = 0;
  std::uint32_t fps = 15;
  std::uint64_t frame_limit = 0;
  std::uint32_t duration_seconds = 0;
  bool list_monitors = false;
  bool capabilities = false;
  bool self_test = false;
  bool encoder_self_test = false;
  bool service = false;
  bool service_self_test = false;
  bool preview = true;
  bool help = false;
};

std::string WideToUtf8(const std::wstring& value) {
  if (value.empty()) return {};
  const int size = WideCharToMultiByte(
      CP_UTF8, 0, value.data(), static_cast<int>(value.size()),
      nullptr, 0, nullptr, nullptr);
  if (size <= 0) return {};
  std::string result(static_cast<std::size_t>(size), '\0');
  WideCharToMultiByte(
      CP_UTF8, 0, value.data(), static_cast<int>(value.size()),
      result.data(), size, nullptr, nullptr);
  return result;
}

std::string JsonEscape(const std::string& value) {
  std::ostringstream out;
  for (const unsigned char ch : value) {
    switch (ch) {
      case '"': out << "\\\""; break;
      case '\\': out << "\\\\"; break;
      case '\b': out << "\\b"; break;
      case '\f': out << "\\f"; break;
      case '\n': out << "\\n"; break;
      case '\r': out << "\\r"; break;
      case '\t': out << "\\t"; break;
      default:
        if (ch < 0x20) {
          constexpr char hex[] = "0123456789abcdef";
          out << "\\u00" << hex[(ch >> 4) & 0x0f] << hex[ch & 0x0f];
        } else {
          out << static_cast<char>(ch);
        }
    }
  }
  return out.str();
}

bool ParseUnsigned(const wchar_t* value, std::uint64_t* parsed) {
  if (value == nullptr || *value == L'\0') return false;
  for (const wchar_t* cursor = value; *cursor != L'\0'; ++cursor) {
    if (*cursor < L'0' || *cursor > L'9') return false;
  }
  wchar_t* end = nullptr;
  errno = 0;
  const unsigned long long result = std::wcstoull(value, &end, 10);
  if (errno != 0 || end == value || *end != L'\0') return false;
  *parsed = static_cast<std::uint64_t>(result);
  return true;
}

bool ParseOptions(int argc, wchar_t** argv, Options* options, std::wstring* error) {
  for (int index = 1; index < argc; ++index) {
    const std::wstring arg = argv[index];
    if (arg == L"--help" || arg == L"-h") {
      options->help = true;
    } else if (arg == L"--list-monitors") {
      options->list_monitors = true;
    } else if (arg == L"--capabilities") {
      options->capabilities = true;
    } else if (arg == L"--self-test") {
      options->self_test = true;
    } else if (arg == L"--encoder-self-test") {
      options->encoder_self_test = true;
    } else if (arg == L"--service") {
      options->service = true;
    } else if (arg == L"--service-self-test") {
      options->service_self_test = true;
    } else if (arg == L"--no-preview") {
      options->preview = false;
    } else if (arg == L"--monitor" || arg == L"--fps" ||
               arg == L"--frames" || arg == L"--duration-seconds") {
      if (index + 1 >= argc) {
        *error = L"Missing value after " + arg;
        return false;
      }
      std::uint64_t value = 0;
      if (!ParseUnsigned(argv[++index], &value)) {
        *error = L"Invalid unsigned integer for " + arg;
        return false;
      }
      if (arg == L"--monitor") {
        if (value > std::numeric_limits<std::size_t>::max()) return false;
        options->monitor_index = static_cast<std::size_t>(value);
      } else if (arg == L"--fps") {
        if (value < 1 || value > 60) {
          *error = L"--fps must be between 1 and 60";
          return false;
        }
        options->fps = static_cast<std::uint32_t>(value);
      } else if (arg == L"--frames") {
        options->frame_limit = value;
      } else {
        if (value > 86400) {
          *error = L"--duration-seconds must not exceed 86400";
          return false;
        }
        options->duration_seconds = static_cast<std::uint32_t>(value);
      }
    } else {
      *error = L"Unknown option: " + arg;
      return false;
    }
  }

  if (!options->preview && options->frame_limit == 0 &&
      options->duration_seconds == 0 && !options->list_monitors) {
    options->frame_limit = options->fps * 10;
  }
  return true;
}

void PrintUsage() {
  std::cout
      << "Serein Remote Host - local DXGI capture PoC\n\n"
      << "Usage:\n"
      << "  serein-remote-host --self-test\n"
      << "  serein-remote-host --encoder-self-test\n"
      << "  serein-remote-host --service-self-test\n"
      << "  serein-remote-host --service\n"
      << "  serein-remote-host --capabilities\n"
      << "  serein-remote-host --list-monitors\n"
      << "  serein-remote-host [--monitor N] [--fps N] [--frames N]\n"
      << "                     [--duration-seconds N] [--no-preview]\n\n"
      << "This PoC has no network, input injection, unattended mode, or token access.\n";
}

std::vector<std::uint8_t> PixelLabels(const DesktopFrame& frame) {
  std::vector<std::uint8_t> labels;
  labels.reserve(static_cast<std::size_t>(frame.width) * frame.height);
  for (std::uint32_t y = 0; y < frame.height; ++y) {
    for (std::uint32_t x = 0; x < frame.width; ++x) {
      labels.push_back(frame.bgra[static_cast<std::size_t>(y) * frame.stride + x * 4]);
    }
  }
  return labels;
}

bool CheckRotation(
    const std::vector<std::uint8_t>& source,
    std::uint32_t rotation,
    std::uint32_t expected_width,
    std::uint32_t expected_height,
    const std::vector<std::uint8_t>& expected_labels) {
  DesktopFrame frame;
  if (!NormalizeBgraFrame(source.data(), 2, 3, 8, rotation, &frame)) return false;
  return frame.width == expected_width && frame.height == expected_height &&
      frame.stride == expected_width * 4 && PixelLabels(frame) == expected_labels;
}

int RunSyntheticSelfTest() {
  std::vector<std::uint8_t> source(2 * 3 * 4, 0);
  for (std::size_t pixel = 0; pixel < 6; ++pixel) {
    source[pixel * 4] = static_cast<std::uint8_t>(pixel + 1);
    source[pixel * 4 + 3] = 255;
  }

  const bool passed =
      CheckRotation(source, 1, 2, 3, {1, 2, 3, 4, 5, 6}) &&
      CheckRotation(source, 2, 3, 2, {5, 3, 1, 6, 4, 2}) &&
      CheckRotation(source, 3, 2, 3, {6, 5, 4, 3, 2, 1}) &&
      CheckRotation(source, 4, 3, 2, {2, 4, 6, 1, 3, 5});

  std::cout << "{\"protocol_version\":1,\"self_test\":\"bgra_rotation\",\"passed\":"
            << (passed ? "true" : "false")
            << ",\"desktop_pixels_read\":false}\n";
  return passed ? 0 : 3;
}

DesktopFrame BuildSyntheticFrame(
    std::uint32_t width,
    std::uint32_t height,
    std::uint32_t phase) {
  DesktopFrame frame;
  frame.width = width;
  frame.height = height;
  frame.stride = width * 4;
  frame.bgra.resize(static_cast<std::size_t>(frame.stride) * height);
  for (std::uint32_t y = 0; y < height; ++y) {
    for (std::uint32_t x = 0; x < width; ++x) {
      auto* pixel = frame.bgra.data() +
          static_cast<std::size_t>(y) * frame.stride + x * 4;
      pixel[0] = static_cast<std::uint8_t>((x + phase * 7) & 0xff);
      pixel[1] = static_cast<std::uint8_t>((y + phase * 5) & 0xff);
      pixel[2] = static_cast<std::uint8_t>(
          ((x / 4) + (y / 3) + phase * 11) & 0xff);
      pixel[3] = 255;
    }
  }
  return frame;
}

int RunEncoderSelfTest() {
  const HRESULT com_result = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  const bool uninitialize_com = SUCCEEDED(com_result);
  if (FAILED(com_result) && com_result != RPC_E_CHANGED_MODE) {
    std::cerr << "CoInitializeEx failed\n";
    return 3;
  }

  H264EncoderConfig config;
  config.width = 640;
  config.height = 360;
  config.fps = 15;
  config.bitrate = 800'000;
  MfH264Encoder encoder;
  std::wstring error;
  if (!encoder.Initialize(config, &error)) {
    std::cerr << WideToUtf8(error) << "\n";
    if (uninitialize_com) CoUninitialize();
    return 3;
  }

  std::vector<serein::remote::EncodedH264Frame> output;
  const std::int64_t duration = 10'000'000LL / config.fps;
  for (std::uint32_t index = 0; index < config.fps; ++index) {
    const DesktopFrame frame =
        BuildSyntheticFrame(config.width, config.height, index);
    if (!encoder.EncodeBgra(frame, duration * index, &output, &error)) {
      std::cerr << WideToUtf8(error) << "\n";
      encoder.Reset();
      if (uninitialize_com) CoUninitialize();
      return 3;
    }
  }
  if (!encoder.Drain(&output, &error)) {
    std::cerr << WideToUtf8(error) << "\n";
    encoder.Reset();
    if (uninitialize_com) CoUninitialize();
    return 3;
  }

  std::uint64_t total_bytes = 0;
  std::uint64_t key_frames = 0;
  bool annex_b_start_code = false;
  for (const auto& frame : output) {
    total_bytes += frame.bytes.size();
    if (frame.key_frame) ++key_frames;
    if (frame.bytes.size() >= 4 && frame.bytes[0] == 0 && frame.bytes[1] == 0 &&
        (frame.bytes[2] == 1 || (frame.bytes[2] == 0 && frame.bytes[3] == 1))) {
      annex_b_start_code = true;
    }
  }
  const bool passed = !output.empty() && total_bytes > 0;
  std::uint64_t decoded_frames = 0;
  const bool decode_passed = passed &&
      ValidateH264Decode(config, output, &decoded_frames, &error);
  if (!decode_passed && !error.empty()) std::cerr << WideToUtf8(error) << "\n";
  std::cout << "{\"protocol_version\":1,\"self_test\":\"mf_h264\""
            << ",\"encoder\":\""
            << JsonEscape(WideToUtf8(encoder.encoder_name())) << '"'
            << ",\"input_frames\":" << config.fps
            << ",\"output_samples\":" << output.size()
            << ",\"output_bytes\":" << total_bytes
            << ",\"key_frames\":" << key_frames
            << ",\"annex_b_start_code\":"
            << (annex_b_start_code ? "true" : "false")
            << ",\"decoded_frames\":" << decoded_frames
            << ",\"decode_passed\":" << (decode_passed ? "true" : "false")
            << ",\"desktop_pixels_read\":false"
            << ",\"passed\":" << (passed && decode_passed ? "true" : "false") << "}\n";
  encoder.Reset();
  if (uninitialize_com) CoUninitialize();
  return passed && decode_passed ? 0 : 3;
}

int RunServiceSelfTest() {
  serein::remote::HostServiceCommand command;
  std::wstring error;
  const bool passed =
      serein::remote::ParseHostServiceCommand(L"PING", &command, &error) &&
      command.type == serein::remote::HostServiceCommand::Type::kPing &&
      serein::remote::ParseHostServiceCommand(
          L"CONSENT session-0001 My Phone", &command, &error) &&
      command.type == serein::remote::HostServiceCommand::Type::kConsent &&
      command.session_id == L"session-0001" && command.controller_label == L"My Phone" &&
      serein::remote::ParseHostServiceCommand(
          L"AUTHORIZE session-0001 2 4102444800 "
          L"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
          &command, &error) &&
      command.type == serein::remote::HostServiceCommand::Type::kAuthorize &&
      command.revision == 2 && command.ticket_expires_at == 4102444800ULL &&
      command.session_ticket.size() == 73 &&
      serein::remote::ParseHostServiceCommand(
          L"STREAM_START session-0001 0 15 2000000", &command, &error) &&
      command.type == serein::remote::HostServiceCommand::Type::kStreamStart &&
      command.session_id == L"session-0001" && command.stream_monitor == 0 &&
      command.stream_fps == 15 && command.stream_bitrate == 2000000 &&
      serein::remote::ParseHostServiceCommand(
          L"STREAM_STOP session-0001", &command, &error) &&
      command.type == serein::remote::HostServiceCommand::Type::kStreamStop &&
      command.session_id == L"session-0001" &&
      !serein::remote::ParseHostServiceCommand(
          L"STREAM_START session-0001 0 0 2000000", &command, &error) &&
      !serein::remote::ParseHostServiceCommand(
          L"STREAM_START session-0001 0 15 99999", &command, &error) &&
      !serein::remote::ParseHostServiceCommand(
          L"CONSENT bad\nvalue attacker", &command, &error) &&
      !serein::remote::ParseHostServiceCommand(
          L"AUTHORIZE session-0001 2 4102444800 invalid-ticket-without-dot",
          &command, &error) &&
      !serein::remote::ParseHostServiceCommand(
          L"AUTHORIZE session-0001 -2 4102444800 "
          L"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
          &command, &error) &&
      !serein::remote::ParseHostServiceCommand(
          L"SHELL powershell.exe", &command, &error) &&
      serein::remote::RunHostServiceExpirySelfTest();
  std::cout << "{\"protocol_version\":1,\"self_test\":\"host_service_ipc\""
            << ",\"desktop_pixels_read\":false,\"input_enabled\":true,\"passed\":"
            << (passed ? "true" : "false") << "}\n";
  return passed ? 0 : 3;
}

void PrintMonitors(const std::vector<MonitorInfo>& monitors) {
  std::cout << "{\"protocol_version\":1,\"capture\":\"dxgi-duplication\",\"monitors\":[";
  for (std::size_t index = 0; index < monitors.size(); ++index) {
    if (index != 0) std::cout << ',';
    const auto& monitor = monitors[index];
    std::cout
        << "{\"index\":" << monitor.index
        << ",\"device_name\":\"" << JsonEscape(WideToUtf8(monitor.device_name)) << '"'
        << ",\"adapter_name\":\"" << JsonEscape(WideToUtf8(monitor.adapter_name)) << '"'
        << ",\"left\":" << monitor.left
        << ",\"top\":" << monitor.top
        << ",\"width\":" << monitor.width
        << ",\"height\":" << monitor.height
        << ",\"rotation\":" << monitor.rotation
        << ",\"attached\":" << (monitor.attached_to_desktop ? "true" : "false")
        << '}';
  }
  std::cout << "]}\n";
}

int RunCapabilitiesProbe() {
  std::wstring monitor_error;
  const auto monitors = DesktopCapture::EnumerateMonitors(&monitor_error);
  const HRESULT com_result = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  const bool uninitialize_com = SUCCEEDED(com_result);
  bool h264_available = false;
  std::string encoder_name;
  if (SUCCEEDED(com_result) || com_result == RPC_E_CHANGED_MODE) {
    H264EncoderConfig config;
    config.width = 640;
    config.height = 360;
    config.fps = 15;
    config.bitrate = 800'000;
    MfH264Encoder encoder;
    std::wstring encoder_error;
    h264_available = encoder.Initialize(config, &encoder_error);
    if (h264_available) encoder_name = WideToUtf8(encoder.encoder_name());
    encoder.Reset();
  }
  if (uninitialize_com) CoUninitialize();

  std::cout << "{\"protocol_version\":1,\"capture\":"
            << (monitors.empty() ? "[]" : "[\"dxgi-duplication\"]")
            << ",\"video_codecs\":" << (h264_available ? "[\"h264\"]" : "[]")
            << ",\"transports\":[]"
            << ",\"hardware_encoder\":false,\"input\":[],\"monitors\":" << monitors.size()
            << ",\"unattended_enabled\":false,\"secure_desktop\":false"
            << ",\"encoder_name\":\"" << JsonEscape(encoder_name) << "\""
            << ",\"desktop_pixels_read\":false}\n";
  return 0;
}

LRESULT CALLBACK PreviewWindowProc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
  switch (message) {
    case WM_CLOSE:
      DestroyWindow(window);
      return 0;
    case WM_DESTROY:
      PostQuitMessage(0);
      return 0;
    case WM_ERASEBKGND:
      return 1;
    default:
      return DefWindowProcW(window, message, wparam, lparam);
  }
}

HWND CreatePreviewWindow() {
  const wchar_t* class_name = L"SereinRemoteHostPreview";
  WNDCLASSW window_class{};
  window_class.lpfnWndProc = PreviewWindowProc;
  window_class.hInstance = GetModuleHandleW(nullptr);
  window_class.lpszClassName = class_name;
  window_class.hCursor = LoadCursorW(nullptr, IDC_ARROW);
  window_class.hbrBackground = static_cast<HBRUSH>(GetStockObject(BLACK_BRUSH));
  RegisterClassW(&window_class);

  HWND window = CreateWindowExW(
      0,
      class_name,
      L"Serein Remote Host PoC",
      WS_OVERLAPPEDWINDOW,
      CW_USEDEFAULT,
      CW_USEDEFAULT,
      1100,
      700,
      nullptr,
      nullptr,
      window_class.hInstance,
      nullptr);
  if (window != nullptr) {
    ShowWindow(window, SW_SHOW);
    UpdateWindow(window);
  }
  return window;
}

bool PumpWindowMessages() {
  MSG message{};
  while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
    if (message.message == WM_QUIT) return false;
    TranslateMessage(&message);
    DispatchMessageW(&message);
  }
  return true;
}

void RenderFrame(HWND window, const DesktopFrame& frame) {
  if (window == nullptr || frame.bgra.empty()) return;

  RECT client{};
  GetClientRect(window, &client);
  const int client_width = std::max(1L, client.right - client.left);
  const int client_height = std::max(1L, client.bottom - client.top);
  const double scale = std::min(
      static_cast<double>(client_width) / frame.width,
      static_cast<double>(client_height) / frame.height);
  const int target_width = std::max(1, static_cast<int>(std::lround(frame.width * scale)));
  const int target_height = std::max(1, static_cast<int>(std::lround(frame.height * scale)));
  const int target_x = (client_width - target_width) / 2;
  const int target_y = (client_height - target_height) / 2;

  BITMAPINFO bitmap{};
  bitmap.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bitmap.bmiHeader.biWidth = static_cast<LONG>(frame.width);
  bitmap.bmiHeader.biHeight = -static_cast<LONG>(frame.height);
  bitmap.bmiHeader.biPlanes = 1;
  bitmap.bmiHeader.biBitCount = 32;
  bitmap.bmiHeader.biCompression = BI_RGB;

  HDC device_context = GetDC(window);
  FillRect(device_context, &client, static_cast<HBRUSH>(GetStockObject(BLACK_BRUSH)));
  SetStretchBltMode(device_context, HALFTONE);
  StretchDIBits(
      device_context,
      target_x,
      target_y,
      target_width,
      target_height,
      0,
      0,
      static_cast<int>(frame.width),
      static_cast<int>(frame.height),
      frame.bgra.data(),
      &bitmap,
      DIB_RGB_COLORS,
      SRCCOPY);
  ReleaseDC(window, device_context);
}

std::wstring BuildWindowTitle(
    const DesktopFrame& frame,
    double fps,
    std::int64_t first_frame_ms,
    std::uint64_t access_lost_count) {
  std::wostringstream title;
  title.precision(1);
  title << std::fixed
        << L"Serein Remote Host PoC | " << frame.width << L'x' << frame.height
        << L" | " << fps << L" FPS"
        << L" | first frame " << first_frame_ms << L" ms"
        << L" | access lost " << access_lost_count;
  return title.str();
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
  SetConsoleOutputCP(CP_UTF8);

  Options options;
  std::wstring parse_error;
  if (!ParseOptions(argc, argv, &options, &parse_error)) {
    std::cerr << WideToUtf8(parse_error) << "\n";
    PrintUsage();
    return 64;
  }
  if (options.help) {
    PrintUsage();
    return 0;
  }
  if (options.self_test) return RunSyntheticSelfTest();
  if (options.encoder_self_test) return RunEncoderSelfTest();
  if (options.service_self_test) return RunServiceSelfTest();
  if (options.capabilities) return RunCapabilitiesProbe();
  if (options.service) {
    serein::remote::HostService service;
    std::wstring error;
    const int result = service.Run(&error);
    if (result != 0 && !error.empty()) std::cerr << WideToUtf8(error) << "\n";
    return result;
  }

  std::wstring error;
  const auto monitors = DesktopCapture::EnumerateMonitors(&error);
  if (monitors.empty()) {
    std::cerr << WideToUtf8(error) << "\n";
    return 2;
  }
  if (options.list_monitors) {
    PrintMonitors(monitors);
    return 0;
  }
  if (options.monitor_index >= monitors.size()) {
    std::cerr << "Monitor index " << options.monitor_index
              << " is unavailable; detected " << monitors.size() << " monitor(s)\n";
    return 64;
  }

  DesktopCapture capture;
  if (!capture.Initialize(options.monitor_index, &error)) {
    std::cerr << WideToUtf8(error) << "\n";
    return 2;
  }

  HWND preview_window = nullptr;
  if (options.preview) {
    preview_window = CreatePreviewWindow();
    if (preview_window == nullptr) {
      std::cerr << "Failed to create the local preview window\n";
      return 2;
    }
  }

  const auto started_at = std::chrono::steady_clock::now();
  const auto frame_interval = std::chrono::microseconds(1000000 / options.fps);
  auto next_frame_at = started_at;
  auto fps_window_started_at = started_at;
  std::uint64_t frame_count = 0;
  std::uint64_t fps_window_frames = 0;
  std::uint64_t access_lost_count = 0;
  double measured_fps = 0.0;
  std::int64_t first_frame_ms = -1;
  bool running = true;
  bool capture_failed = false;
  DesktopFrame frame;

  while (running) {
    if (options.preview && !PumpWindowMessages()) break;

    const auto now = std::chrono::steady_clock::now();
    if (options.duration_seconds > 0 &&
        now - started_at >= std::chrono::seconds(options.duration_seconds)) {
      break;
    }
    if (options.frame_limit > 0 && frame_count >= options.frame_limit) break;

    if (now < next_frame_at) {
      std::this_thread::sleep_for(std::min(
          std::chrono::duration_cast<std::chrono::milliseconds>(next_frame_at - now),
          std::chrono::milliseconds(5)));
      continue;
    }
    next_frame_at = now + frame_interval;

    error.clear();
    const CaptureStatus status = capture.CaptureNextFrame(&frame, 20, &error);
    if (status == CaptureStatus::kTimeout) continue;
    if (status == CaptureStatus::kAccessLost) {
      ++access_lost_count;
      std::this_thread::sleep_for(std::chrono::milliseconds(250));
      if (!capture.Initialize(options.monitor_index, &error)) {
        std::cerr << WideToUtf8(error) << "\n";
        capture_failed = true;
        break;
      }
      continue;
    }
    if (status == CaptureStatus::kFatal) {
      std::cerr << WideToUtf8(error) << "\n";
      capture_failed = true;
      break;
    }

    ++frame_count;
    ++fps_window_frames;
    const auto captured_at = std::chrono::steady_clock::now();
    if (first_frame_ms < 0) {
      first_frame_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
          captured_at - started_at).count();
    }

    const double fps_window_seconds = std::chrono::duration<double>(
        captured_at - fps_window_started_at).count();
    if (fps_window_seconds >= 1.0) {
      measured_fps = static_cast<double>(fps_window_frames) / fps_window_seconds;
      fps_window_frames = 0;
      fps_window_started_at = captured_at;
      if (preview_window != nullptr) {
        const auto title = BuildWindowTitle(
            frame, measured_fps, first_frame_ms, access_lost_count);
        SetWindowTextW(preview_window, title.c_str());
      }
    }

    if (preview_window != nullptr) RenderFrame(preview_window, frame);
  }

  if (preview_window != nullptr && IsWindow(preview_window)) DestroyWindow(preview_window);
  const auto ended_at = std::chrono::steady_clock::now();
  const auto elapsed_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
      ended_at - started_at).count();
  const double average_fps = elapsed_ms > 0
      ? static_cast<double>(frame_count) * 1000.0 / static_cast<double>(elapsed_ms)
      : 0.0;

  std::cout.precision(2);
  std::cout << std::fixed
            << "{\"protocol_version\":1"
            << ",\"capture\":\"dxgi-duplication\""
            << ",\"monitor_index\":" << options.monitor_index
            << ",\"frames\":" << frame_count
            << ",\"elapsed_ms\":" << elapsed_ms
            << ",\"first_frame_ms\":" << first_frame_ms
            << ",\"average_fps\":" << average_fps
            << ",\"access_lost_count\":" << access_lost_count
            << ",\"failed\":" << (capture_failed ? "true" : "false")
            << "}\n";
  return capture_failed || frame_count == 0 ? 2 : 0;
}
