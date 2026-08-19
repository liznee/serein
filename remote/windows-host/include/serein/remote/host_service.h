#pragma once

#include <Windows.h>

#include <cstdint>
#include <condition_variable>
#include <mutex>
#include <string>
#include <thread>

namespace serein::remote {

struct HostServiceCommand {
  enum class Type {
    kInvalid,
    kPing,
    kStatus,
    kConsent,
    kGrant,
    kAuthorize,
    kEnd,
    kStreamStart,
    kStreamStop,
    kShutdown
  };
  ~HostServiceCommand();

  Type type = Type::kInvalid;
  std::wstring session_id;
  std::wstring controller_label;
  std::uint64_t revision = 0;
  std::uint64_t ticket_expires_at = 0;
  std::wstring session_ticket;
  std::size_t stream_monitor = 0;
  std::uint32_t stream_fps = 15;
  std::uint32_t stream_bitrate = 2'000'000;
};

bool ParseHostServiceCommand(
    const std::wstring& line,
    HostServiceCommand* command,
    std::wstring* error);
bool RunHostServiceExpirySelfTest();

class HostService final {
 public:
  HostService() = default;
  ~HostService();

  HostService(const HostService&) = delete;
  HostService& operator=(const HostService&) = delete;

  int Run(std::wstring* error);

 private:
  friend bool RunHostServiceExpirySelfTest();
  bool AcquireSingleInstance(std::wstring* error);
  bool ServeOneClient(bool* shutdown_requested, std::wstring* error);
  std::wstring Execute(const HostServiceCommand& command, bool* shutdown_requested);
  void StartExpiryWorker();
  void StopExpiryWorker();
  void ExpiryWorker();
  void ClearAuthorizationLocked();

  bool StartStreamLocked(
      const std::wstring& session_id,
      std::size_t monitor_index,
      std::uint32_t fps,
      std::uint32_t bitrate,
      std::wstring* error);
  void StopStreamLocked();
  void StreamWorker(
      std::size_t monitor_index,
      std::uint32_t fps,
      std::uint32_t bitrate);

  HANDLE mutex_ = nullptr;
  std::mutex state_mutex_;
  std::condition_variable expiry_condition_;
  std::thread expiry_thread_;
  bool expiry_stop_ = false;
  std::wstring active_session_id_;
  std::wstring session_ticket_;
  std::uint64_t active_revision_ = 0;
  std::uint64_t ticket_expires_at_ = 0;
  bool consent_granted_ = false;

  std::thread stream_thread_;
  std::condition_variable stream_condition_;
  bool stream_stop_ = true;
  bool stream_active_ = false;
  std::wstring stream_session_id_;
};

}  // namespace serein::remote
