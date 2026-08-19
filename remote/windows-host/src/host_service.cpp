#include "serein/remote/host_service.h"
#include "serein/remote/desktop_capture.h"
#include "serein/remote/h264_encoder.h"

#include <objbase.h>
#include <sddl.h>

#include <algorithm>
#include <chrono>
#include <cerrno>
#include <cwctype>
#include <filesystem>
#include <fstream>
#include <limits>
#include <sstream>
#include <thread>
#include <vector>

namespace serein::remote {
namespace {

constexpr wchar_t kMutexName[] = L"Local\\SereinRemoteHostV1";
constexpr wchar_t kPipeName[] = L"\\\\.\\pipe\\serein-remote-host-v1";
constexpr wchar_t kStreamPipeName[] = L"\\\\.\\pipe\\serein-remote-host-stream-v1";
constexpr DWORD kMaxPipeMessage = 16384;
constexpr DWORD kStreamPipeBuffer = 4 * 1024 * 1024;
constexpr std::uint32_t kStreamMinFps = 1;
constexpr std::uint32_t kStreamMaxFps = 60;
constexpr std::uint32_t kStreamMinBitrate = 100'000;
constexpr std::uint32_t kStreamMaxBitrate = 12'000'000;

void SecureClear(std::wstring* value) {
  if (value == nullptr || value->empty()) return;
  SecureZeroMemory(value->data(), value->size() * sizeof(wchar_t));
  value->clear();
}

std::uint64_t UnixNow() {
  return static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::seconds>(
      std::chrono::system_clock::now().time_since_epoch()).count());
}

// Capture/encoder errors happen outside the Go bridge. Keep a compact local
// diagnostic record without storing screen pixels, credentials, SDP or input.
void LogStreamDiagnostic(const std::wstring& message) {
  wchar_t local_app_data[MAX_PATH]{};
  const DWORD length = GetEnvironmentVariableW(
      L"LOCALAPPDATA", local_app_data, static_cast<DWORD>(std::size(local_app_data)));
  if (length == 0 || length >= std::size(local_app_data)) return;
  std::error_code error;
  const std::filesystem::path directory =
      std::filesystem::path(local_app_data) / L"Serein";
  std::filesystem::create_directories(directory, error);
  std::wofstream output(directory / L"remote-host-stream.log", std::ios::app);
  if (!output) return;
  output << L"[" << UnixNow() << L"] " << message << L"\n";
}

bool IsSafeIdentifier(const std::wstring& value) {
  if (value.size() < 8 || value.size() > 128) return false;
  return std::all_of(value.begin(), value.end(), [](wchar_t ch) {
    return std::iswalnum(ch) != 0 || ch == L'.' || ch == L'_' ||
        ch == L':' || ch == L'-';
  });
}

bool IsSafeLabel(const std::wstring& value) {
  if (value.empty() || value.size() > 80) return false;
  return std::all_of(value.begin(), value.end(), [](wchar_t ch) {
    return ch >= 0x20 && ch != 0x7f && ch != L'\r' && ch != L'\n';
  });
}

bool IsSafeTicket(const std::wstring& value) {
  if (value.size() < 32 || value.size() > 4096 ||
      std::count(value.begin(), value.end(), L'.') != 1) return false;
  return std::all_of(value.begin(), value.end(), [](wchar_t ch) {
    return (ch >= L'a' && ch <= L'z') || (ch >= L'A' && ch <= L'Z') ||
        (ch >= L'0' && ch <= L'9') || ch == L'.' || ch == L'_' || ch == L'-';
  });
}

bool ParseUnsigned(const std::wstring& value, std::uint64_t* parsed) {
  if (parsed == nullptr || value.empty()) return false;
  if (!std::all_of(value.begin(), value.end(), [](wchar_t ch) {
        return ch >= L'0' && ch <= L'9';
      })) return false;
  wchar_t* end = nullptr;
  errno = 0;
  const unsigned long long result = std::wcstoull(value.c_str(), &end, 10);
  if (errno != 0 || end == value.c_str() || *end != L'\0' ||
      result > std::numeric_limits<std::uint64_t>::max()) return false;
  *parsed = static_cast<std::uint64_t>(result);
  return true;
}

std::vector<std::wstring> Split(const std::wstring& value) {
  std::wistringstream input(value);
  std::vector<std::wstring> parts;
  std::wstring part;
  while (input >> part) parts.push_back(part);
  return parts;
}

std::wstring JsonEscape(const std::wstring& value) {
  std::wostringstream output;
  for (const wchar_t ch : value) {
    switch (ch) {
      case L'"': output << L"\\\""; break;
      case L'\\': output << L"\\\\"; break;
      case L'\r': output << L"\\r"; break;
      case L'\n': output << L"\\n"; break;
      case L'\t': output << L"\\t"; break;
      default: output << ch; break;
    }
  }
  return output.str();
}

}  // namespace

HostServiceCommand::~HostServiceCommand() {
  SecureClear(&session_ticket);
}

bool ParseHostServiceCommand(
    const std::wstring& line,
    HostServiceCommand* command,
    std::wstring* error) {
  if (command == nullptr) return false;
  SecureClear(&command->session_ticket);
  *command = HostServiceCommand{};
  if (line.empty() || line.size() > 8192 || line.find_first_of(L"\r\n") != std::wstring::npos ||
      line.find(L'\0') != std::wstring::npos) {
    if (error != nullptr) *error = L"invalid command length or control character";
    return false;
  }
  const auto parts = Split(line);
  if (parts.empty()) return false;
  if (parts[0] == L"PING" && parts.size() == 1) {
    command->type = HostServiceCommand::Type::kPing;
    return true;
  }
  if (parts[0] == L"STATUS" && parts.size() == 1) {
    command->type = HostServiceCommand::Type::kStatus;
    return true;
  }
  if (parts[0] == L"END" && parts.size() == 2 && IsSafeIdentifier(parts[1])) {
    command->type = HostServiceCommand::Type::kEnd;
    command->session_id = parts[1];
    return true;
  }
  if (parts[0] == L"AUTHORIZE" && parts.size() == 5 && IsSafeIdentifier(parts[1]) &&
      ParseUnsigned(parts[2], &command->revision) && command->revision > 0 &&
      ParseUnsigned(parts[3], &command->ticket_expires_at) &&
      IsSafeTicket(parts[4])) {
    command->type = HostServiceCommand::Type::kAuthorize;
    command->session_id = parts[1];
    command->session_ticket = parts[4];
    return true;
  }
  if (parts[0] == L"SHUTDOWN" && parts.size() == 1) {
    command->type = HostServiceCommand::Type::kShutdown;
    return true;
  }
  if (parts[0] == L"STREAM_START" && parts.size() == 5 && IsSafeIdentifier(parts[1])) {
    std::uint64_t monitor = 0;
    std::uint64_t fps = 0;
    std::uint64_t bitrate = 0;
    if (ParseUnsigned(parts[2], &monitor) && monitor <= 32 &&
        ParseUnsigned(parts[3], &fps) && fps >= kStreamMinFps && fps <= kStreamMaxFps &&
        ParseUnsigned(parts[4], &bitrate) &&
        bitrate >= kStreamMinBitrate && bitrate <= kStreamMaxBitrate) {
      command->type = HostServiceCommand::Type::kStreamStart;
      command->session_id = parts[1];
      command->stream_monitor = static_cast<std::size_t>(monitor);
      command->stream_fps = static_cast<std::uint32_t>(fps);
      command->stream_bitrate = static_cast<std::uint32_t>(bitrate);
      return true;
    }
  }
  if (parts[0] == L"STREAM_STOP" && parts.size() == 2 && IsSafeIdentifier(parts[1])) {
    command->type = HostServiceCommand::Type::kStreamStop;
    command->session_id = parts[1];
    return true;
  }
  if (parts[0] == L"CONSENT" && parts.size() >= 3 && IsSafeIdentifier(parts[1])) {
    const std::size_t label_at = line.find(parts[2], line.find(parts[1]) + parts[1].size());
    const std::wstring label = label_at == std::wstring::npos ? L"" : line.substr(label_at);
    if (IsSafeLabel(label)) {
      command->type = HostServiceCommand::Type::kConsent;
      command->session_id = parts[1];
      command->controller_label = label;
      return true;
    }
  }
  if (parts[0] == L"GRANT" && parts.size() == 2 && IsSafeIdentifier(parts[1])) {
    command->type = HostServiceCommand::Type::kGrant;
    command->session_id = parts[1];
    return true;
  }
  if (error != nullptr) *error = L"unsupported or malformed command";
  return false;
}

HostService::~HostService() {
  StopExpiryWorker();
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    StopStreamLocked();
    ClearAuthorizationLocked();
  }
  if (mutex_ != nullptr) CloseHandle(mutex_);
}

bool HostService::AcquireSingleInstance(std::wstring* error) {
  mutex_ = CreateMutexW(nullptr, FALSE, kMutexName);
  if (mutex_ == nullptr) {
    if (error != nullptr) *error = L"failed to create single-instance mutex";
    return false;
  }
  if (GetLastError() == ERROR_ALREADY_EXISTS) {
    if (error != nullptr) *error = L"remote host service is already running";
    return false;
  }
  return true;
}

int HostService::Run(std::wstring* error) {
  if (!AcquireSingleInstance(error)) return 10;
  StartExpiryWorker();
  bool shutdown_requested = false;
  while (!shutdown_requested) {
    if (!ServeOneClient(&shutdown_requested, error)) {
      StopExpiryWorker();
      return 2;
    }
  }
  StopExpiryWorker();
  return 0;
}

void HostService::StartExpiryWorker() {
  std::lock_guard<std::mutex> lock(state_mutex_);
  if (expiry_thread_.joinable()) return;
  expiry_stop_ = false;
  expiry_thread_ = std::thread(&HostService::ExpiryWorker, this);
}

void HostService::StopExpiryWorker() {
  {
    std::lock_guard<std::mutex> lock(state_mutex_);
    expiry_stop_ = true;
  }
  expiry_condition_.notify_all();
  if (expiry_thread_.joinable()) expiry_thread_.join();
}

void HostService::ExpiryWorker() {
  std::unique_lock<std::mutex> lock(state_mutex_);
  while (!expiry_stop_) {
    expiry_condition_.wait_for(lock, std::chrono::seconds(1), [this] {
      return expiry_stop_;
    });
    // The short-lived ticket authorizes startup only. Once a stream is active,
    // its peer connection has already consumed that ticket; expiring it must
    // never stop an established remote session.
    if (!expiry_stop_ && !stream_active_ && ticket_expires_at_ > 0 &&
        ticket_expires_at_ <= UnixNow()) {
      ClearAuthorizationLocked();
    }
  }
}

void HostService::ClearAuthorizationLocked() {
  StopStreamLocked();
  SecureClear(&session_ticket_);
  active_session_id_.clear();
  active_revision_ = 0;
  ticket_expires_at_ = 0;
  consent_granted_ = false;
}

bool RunHostServiceExpirySelfTest() {
  HostService service;
  {
    std::lock_guard<std::mutex> lock(service.state_mutex_);
    service.active_session_id_ = L"session-self-test";
    service.session_ticket_ =
        L"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    service.active_revision_ = 2;
    service.ticket_expires_at_ = UnixNow() - 1;
    service.consent_granted_ = true;
  }
  service.StartExpiryWorker();
  std::this_thread::sleep_for(std::chrono::milliseconds(1250));
  service.StopExpiryWorker();
  std::lock_guard<std::mutex> lock(service.state_mutex_);
  const bool expired_authorization_cleared =
      service.active_session_id_.empty() && service.session_ticket_.empty() &&
      service.active_revision_ == 0 && service.ticket_expires_at_ == 0 &&
      !service.consent_granted_;

  HostService active_stream;
  {
    std::lock_guard<std::mutex> lock(active_stream.state_mutex_);
    active_stream.active_session_id_ = L"session-active-stream";
    active_stream.session_ticket_ =
        L"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    active_stream.active_revision_ = 2;
    active_stream.ticket_expires_at_ = UnixNow() - 1;
    active_stream.consent_granted_ = true;
    active_stream.stream_active_ = true;
  }
  active_stream.StartExpiryWorker();
  std::this_thread::sleep_for(std::chrono::milliseconds(1250));
  active_stream.StopExpiryWorker();
  std::lock_guard<std::mutex> active_lock(active_stream.state_mutex_);
  const bool active_stream_survives_ticket_expiry =
      active_stream.active_session_id_ == L"session-active-stream" &&
      !active_stream.session_ticket_.empty() && active_stream.consent_granted_;
  active_stream.stream_active_ = false;
  active_stream.ClearAuthorizationLocked();
  return expired_authorization_cleared && active_stream_survives_ticket_expiry;
}

bool HostService::ServeOneClient(bool* shutdown_requested, std::wstring* error) {
  PSECURITY_DESCRIPTOR descriptor = nullptr;
  if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
          L"D:P(A;;GA;;;OW)(A;;GA;;;SY)(A;;GA;;;BA)",
          SDDL_REVISION_1, &descriptor, nullptr)) {
    if (error != nullptr) *error = L"failed to create local pipe security descriptor";
    return false;
  }
  SECURITY_ATTRIBUTES security{};
  security.nLength = sizeof(security);
  security.lpSecurityDescriptor = descriptor;
  security.bInheritHandle = FALSE;
  HANDLE pipe = CreateNamedPipeW(
      kPipeName,
      PIPE_ACCESS_DUPLEX | FILE_FLAG_FIRST_PIPE_INSTANCE,
      PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
      1,
      kMaxPipeMessage,
      kMaxPipeMessage,
      0,
      &security);
  if (pipe == INVALID_HANDLE_VALUE) {
    // FILE_FLAG_FIRST_PIPE_INSTANCE is only needed for the first pipe object.
    pipe = CreateNamedPipeW(
        kPipeName, PIPE_ACCESS_DUPLEX,
        PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
        1, kMaxPipeMessage, kMaxPipeMessage, 0, &security);
  }
  LocalFree(descriptor);
  if (pipe == INVALID_HANDLE_VALUE) {
    if (error != nullptr) *error = L"failed to create local control pipe";
    return false;
  }
  const BOOL connected = ConnectNamedPipe(pipe, nullptr) ? TRUE : GetLastError() == ERROR_PIPE_CONNECTED;
  if (!connected) {
    CloseHandle(pipe);
    return true;
  }
  wchar_t buffer[kMaxPipeMessage / sizeof(wchar_t)]{};
  DWORD bytes_read = 0;
  const BOOL read_ok = ReadFile(pipe, buffer, sizeof(buffer) - sizeof(wchar_t), &bytes_read, nullptr);
  std::wstring response = L"{\"ok\":false,\"error\":\"REMOTE_IPC_INVALID\"}";
  if (read_ok && bytes_read % sizeof(wchar_t) == 0) {
    const std::wstring line(buffer, bytes_read / sizeof(wchar_t));
    HostServiceCommand command;
    std::wstring parse_error;
    if (ParseHostServiceCommand(line, &command, &parse_error)) {
      response = Execute(command, shutdown_requested);
    }
  }
  DWORD bytes_written = 0;
  WriteFile(pipe, response.data(), static_cast<DWORD>(response.size() * sizeof(wchar_t)), &bytes_written, nullptr);
  FlushFileBuffers(pipe);
  DisconnectNamedPipe(pipe);
  CloseHandle(pipe);
  return true;
}

std::wstring HostService::Execute(const HostServiceCommand& command, bool* shutdown_requested) {
  std::lock_guard<std::mutex> lock(state_mutex_);
  switch (command.type) {
    case HostServiceCommand::Type::kPing:
      return L"{\"ok\":true,\"service\":\"serein-remote-host\",\"protocol_version\":1}";
    case HostServiceCommand::Type::kStatus: {
      if (!stream_active_ && ticket_expires_at_ > 0 && ticket_expires_at_ <= UnixNow()) {
        ClearAuthorizationLocked();
      }
      std::wostringstream output;
      output << L"{\"ok\":true,\"capture_active\":" << (stream_active_ ? L"true" : L"false")
             << L",\"input_enabled\":true,\"unattended_enabled\":false";
      if (!active_session_id_.empty()) {
        output << L",\"session_id\":\"" << JsonEscape(active_session_id_) << L"\""
               << L",\"consent_granted\":" << (consent_granted_ ? L"true" : L"false")
               << L",\"transport_authorized\":" << (!session_ticket_.empty() ? L"true" : L"false")
               << L",\"revision\":" << active_revision_;
      }
      if (stream_active_ && !stream_session_id_.empty()) {
        output << L",\"stream_session_id\":\"" << JsonEscape(stream_session_id_) << L"\"";
      }
      output << L"}";
      return output.str();
    }
    case HostServiceCommand::Type::kConsent: {
      SecureClear(&session_ticket_);
      active_revision_ = 0;
      ticket_expires_at_ = 0;
      active_session_id_ = command.session_id;
      consent_granted_ = false;
      const std::wstring message =
          L"设备 “" + command.controller_label +
          L"” 请求远程控制此电脑。\n\n将允许查看画面和触控操作（鼠标、键盘）。\n拒绝后不会采集任何画面。";
      const int decision = MessageBoxW(
          nullptr, message.c_str(), L"Serein 远程桌面请求",
          MB_ICONQUESTION | MB_YESNO | MB_DEFBUTTON2 | MB_SETFOREGROUND);
      consent_granted_ = decision == IDYES;
      if (!consent_granted_) active_session_id_.clear();
      return consent_granted_
          ? L"{\"ok\":true,\"decision\":\"allow\",\"capabilities\":[\"view\",\"input\"]}"
          : L"{\"ok\":true,\"decision\":\"deny\"}";
    }
    case HostServiceCommand::Type::kGrant:
      SecureClear(&session_ticket_);
      active_revision_ = 0;
      ticket_expires_at_ = 0;
      active_session_id_ = command.session_id;
      consent_granted_ = true;
      return L"{\"ok\":true,\"consent_granted\":true}";
    case HostServiceCommand::Type::kAuthorize:
      if (!consent_granted_ || active_session_id_ != command.session_id ||
          command.ticket_expires_at <= UnixNow()) {
        return L"{\"ok\":false,\"error\":\"REMOTE_IPC_NOT_CONSENTED\"}";
      }
      SecureClear(&session_ticket_);
      session_ticket_ = command.session_ticket;
      active_revision_ = command.revision;
      ticket_expires_at_ = command.ticket_expires_at;
      return L"{\"ok\":true,\"transport_authorized\":true}";
    case HostServiceCommand::Type::kStreamStart: {
      if (!consent_granted_ || active_session_id_ != command.session_id ||
          session_ticket_.empty()) {
        return L"{\"ok\":false,\"error\":\"REMOTE_IPC_NOT_AUTHORIZED\"}";
      }
      std::wstring stream_error;
      if (!StartStreamLocked(command.session_id, command.stream_monitor,
                             command.stream_fps, command.stream_bitrate, &stream_error)) {
        return L"{\"ok\":false,\"error\":\"REMOTE_STREAM_FAILED\"}";
      }
      // The bridge has its own short-lived ticket for its WebRTC join. The
      // native host no longer needs its copy once the capture pipe is live.
      SecureClear(&session_ticket_);
      ticket_expires_at_ = 0;
      return L"{\"ok\":true,\"streaming\":true}";
    }
    case HostServiceCommand::Type::kStreamStop:
      StopStreamLocked();
      return L"{\"ok\":true,\"streaming\":false}";
    case HostServiceCommand::Type::kEnd:
      if (active_session_id_ == command.session_id) {
        ClearAuthorizationLocked();
      }
      return L"{\"ok\":true,\"ended\":true}";
    case HostServiceCommand::Type::kShutdown:
      *shutdown_requested = true;
      ClearAuthorizationLocked();
      return L"{\"ok\":true,\"shutdown\":true}";
    default:
      return L"{\"ok\":false,\"error\":\"REMOTE_IPC_INVALID\"}";
  }
}

bool HostService::StartStreamLocked(
    const std::wstring& session_id,
    std::size_t monitor_index,
    std::uint32_t fps,
    std::uint32_t bitrate,
    std::wstring* error) {
  if (fps < kStreamMinFps || fps > kStreamMaxFps ||
      bitrate < kStreamMinBitrate || bitrate > kStreamMaxBitrate) {
    if (error != nullptr) *error = L"invalid stream parameters";
    return false;
  }
  StopStreamLocked();
  stream_stop_ = false;
  stream_active_ = true;
  stream_session_id_ = session_id;
  stream_thread_ = std::thread(
      &HostService::StreamWorker, this,
      monitor_index, fps, bitrate);
  return true;
}

void HostService::StopStreamLocked() {
  stream_stop_ = true;
  stream_condition_.notify_all();
  if (stream_thread_.joinable()) {
    stream_thread_.join();
  }
  stream_active_ = false;
  stream_session_id_.clear();
}

void HostService::StreamWorker(
    std::size_t monitor_index,
    std::uint32_t fps,
    std::uint32_t bitrate) {
  const HRESULT com_result = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  const bool uninitialize_com = SUCCEEDED(com_result);
  if (FAILED(com_result) && com_result != RPC_E_CHANGED_MODE) {
    std::lock_guard<std::mutex> lock(state_mutex_);
    stream_active_ = false;
    stream_session_id_.clear();
    return;
  }

  PSECURITY_DESCRIPTOR descriptor = nullptr;
  if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(
          L"D:P(A;;GA;;;OW)(A;;GA;;;SY)(A;;GA;;;BA)",
          SDDL_REVISION_1, &descriptor, nullptr)) {
    if (uninitialize_com) CoUninitialize();
    std::lock_guard<std::mutex> lock(state_mutex_);
    stream_active_ = false;
    stream_session_id_.clear();
    return;
  }
  SECURITY_ATTRIBUTES security{};
  security.nLength = sizeof(security);
  security.lpSecurityDescriptor = descriptor;
  security.bInheritHandle = FALSE;
  HANDLE pipe = CreateNamedPipeW(
      kStreamPipeName,
      PIPE_ACCESS_OUTBOUND | FILE_FLAG_FIRST_PIPE_INSTANCE | FILE_FLAG_OVERLAPPED,
      PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
      1, kStreamPipeBuffer, kStreamPipeBuffer, 0, &security);
  LocalFree(descriptor);
  if (pipe == INVALID_HANDLE_VALUE) {
    pipe = CreateNamedPipeW(
        kStreamPipeName,
        PIPE_ACCESS_OUTBOUND | FILE_FLAG_OVERLAPPED,
        PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
        1, kStreamPipeBuffer, kStreamPipeBuffer, 0, &security);
  }
  if (pipe == INVALID_HANDLE_VALUE) {
    if (uninitialize_com) CoUninitialize();
    std::lock_guard<std::mutex> lock(state_mutex_);
    stream_active_ = false;
    stream_session_id_.clear();
    return;
  }

  OVERLAPPED overlapped{};
  overlapped.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  if (overlapped.hEvent == nullptr) {
    CloseHandle(pipe);
    if (uninitialize_com) CoUninitialize();
    std::lock_guard<std::mutex> lock(state_mutex_);
    stream_active_ = false;
    stream_session_id_.clear();
    return;
  }

  ConnectNamedPipe(pipe, &overlapped);
  DWORD connected = FALSE;
  while (!stream_stop_) {
    const DWORD wait_result = WaitForSingleObject(overlapped.hEvent, 500);
    if (wait_result == WAIT_OBJECT_0) {
      connected = TRUE;
      break;
    }
    if (wait_result == WAIT_FAILED) break;
  }
  if (!connected) {
    CancelIo(pipe);
    DWORD bytes_transferred = 0;
    GetOverlappedResult(pipe, &overlapped, &bytes_transferred, FALSE);
    CloseHandle(overlapped.hEvent);
    CloseHandle(pipe);
    if (uninitialize_com) CoUninitialize();
    std::lock_guard<std::mutex> lock(state_mutex_);
    stream_active_ = false;
    stream_session_id_.clear();
    return;
  }
  CloseHandle(overlapped.hEvent);

  DesktopCapture capture;
  std::wstring capture_error;
  if (!capture.Initialize(monitor_index, &capture_error)) {
    CloseHandle(pipe);
    if (uninitialize_com) CoUninitialize();
    LogStreamDiagnostic(L"stream stopped: capture initialization failed: " + capture_error);
    std::lock_guard<std::mutex> lock(state_mutex_);
    stream_active_ = false;
    stream_session_id_.clear();
    return;
  }

  const std::uint32_t enc_width = capture.monitor().width & ~1U;
  const std::uint32_t enc_height = capture.monitor().height & ~1U;
  if (enc_width == 0 || enc_height == 0) {
    CloseHandle(pipe);
    if (uninitialize_com) CoUninitialize();
    std::lock_guard<std::mutex> lock(state_mutex_);
    stream_active_ = false;
    stream_session_id_.clear();
    return;
  }

  H264EncoderConfig enc_config;
  enc_config.width = enc_width;
  enc_config.height = enc_height;
  enc_config.fps = fps;
  enc_config.bitrate = bitrate;
  MfH264Encoder encoder;
  std::wstring encoder_error;
  if (!encoder.Initialize(enc_config, &encoder_error)) {
    CloseHandle(pipe);
    if (uninitialize_com) CoUninitialize();
    LogStreamDiagnostic(L"stream stopped: encoder initialization failed: " + encoder_error);
    std::lock_guard<std::mutex> lock(state_mutex_);
    stream_active_ = false;
    stream_session_id_.clear();
    return;
  }

  const auto frame_interval = std::chrono::microseconds(1000000 / fps);
  auto next_frame_at = std::chrono::steady_clock::now();
  std::int64_t timestamp_100ns = 0;
  const std::int64_t frame_duration_100ns = 10'000'000LL / fps;
  std::uint64_t access_lost_count = 0;
  std::uint32_t capture_recovery_count = 0;
  std::uint32_t encoder_recovery_count = 0;
  bool pipe_broken = false;

  while (!stream_stop_ && !pipe_broken) {
    const auto now = std::chrono::steady_clock::now();
    if (now < next_frame_at) {
      std::this_thread::sleep_for(std::min(
          std::chrono::duration_cast<std::chrono::milliseconds>(next_frame_at - now),
          std::chrono::milliseconds(5)));
      continue;
    }
    next_frame_at = now + frame_interval;

    DesktopFrame frame;
    const CaptureStatus status = capture.CaptureNextFrame(&frame, 20, &capture_error);
    if (status == CaptureStatus::kTimeout) continue;
    if (status == CaptureStatus::kAccessLost) {
      ++access_lost_count;
      std::this_thread::sleep_for(std::chrono::milliseconds(250));
      if (!capture.Initialize(monitor_index, &capture_error)) {
        ++capture_recovery_count;
        LogStreamDiagnostic(L"capture recovery failed: " + capture_error);
        if (capture_recovery_count >= 3) break;
      } else {
        capture_recovery_count = 0;
        LogStreamDiagnostic(L"capture recovered after access loss");
      }
      continue;
    }
    if (status == CaptureStatus::kFatal) {
      ++capture_recovery_count;
      LogStreamDiagnostic(L"capture frame failed: " + capture_error);
      if (capture_recovery_count >= 3 || !capture.Initialize(monitor_index, &capture_error)) break;
      std::this_thread::sleep_for(std::chrono::milliseconds(120));
      continue;
    }
    capture_recovery_count = 0;

    if ((frame.width & 1U) != 0 || (frame.height & 1U) != 0) {
      frame.width = frame.width & ~1U;
      frame.height = frame.height & ~1U;
    }
    if (frame.width != enc_width || frame.height != enc_height) continue;

    std::vector<EncodedH264Frame> encoded;
    if (!encoder.EncodeBgra(frame, timestamp_100ns, &encoded, &encoder_error)) {
      ++encoder_recovery_count;
      LogStreamDiagnostic(L"encoder frame failed: " + encoder_error);
      encoder.Reset();
      if (encoder_recovery_count >= 3 || !encoder.Initialize(enc_config, &encoder_error)) {
        LogStreamDiagnostic(L"encoder recovery failed: " + encoder_error);
        break;
      }
      LogStreamDiagnostic(L"encoder recovered after frame failure");
      continue;
    }
    encoder_recovery_count = 0;
    timestamp_100ns += frame_duration_100ns;

    for (const auto& nal_frame : encoded) {
      if (nal_frame.bytes.empty()) continue;
      const std::uint32_t payload_size =
          static_cast<std::uint32_t>(nal_frame.bytes.size());
      std::uint8_t header[4];
      header[0] = static_cast<std::uint8_t>((payload_size >> 24) & 0xFF);
      header[1] = static_cast<std::uint8_t>((payload_size >> 16) & 0xFF);
      header[2] = static_cast<std::uint8_t>((payload_size >> 8) & 0xFF);
      header[3] = static_cast<std::uint8_t>(payload_size & 0xFF);
      DWORD written = 0;
      if (!WriteFile(pipe, header, sizeof(header), &written, nullptr) ||
          written != sizeof(header)) {
        LogStreamDiagnostic(L"stream pipe closed while writing a frame header");
        pipe_broken = true;
        break;
      }
      if (!WriteFile(pipe, nal_frame.bytes.data(),
                     static_cast<DWORD>(nal_frame.bytes.size()),
                     &written, nullptr) ||
          written != nal_frame.bytes.size()) {
        LogStreamDiagnostic(L"stream pipe closed while writing a frame payload");
        pipe_broken = true;
        break;
      }
    }
  }

  FlushFileBuffers(pipe);
  DisconnectNamedPipe(pipe);
  CloseHandle(pipe);
  encoder.Reset();
  if (!stream_stop_ && !pipe_broken) {
    LogStreamDiagnostic(L"stream stopped after capture or encoder recovery limit");
  }
  if (uninitialize_com) CoUninitialize();
  std::lock_guard<std::mutex> lock(state_mutex_);
  stream_active_ = false;
  stream_session_id_.clear();
}

}  // namespace serein::remote
