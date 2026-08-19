cmake_minimum_required(VERSION 3.24)

project(serein_remote_host VERSION 0.1.0 LANGUAGES CXX)

if(NOT WIN32)
  message(FATAL_ERROR "serein-remote-host is a Windows-only target")
endif()

add_executable(serein-remote-host
  src/desktop_capture.cpp
  src/h264_encoder.cpp
  src/host_service.cpp
  src/main.cpp
)

target_include_directories(serein-remote-host PRIVATE include)
target_compile_features(serein-remote-host PRIVATE cxx_std_20)
target_compile_definitions(serein-remote-host PRIVATE
  NOMINMAX
  WIN32_LEAN_AND_MEAN
  UNICODE
  _UNICODE
)

target_link_libraries(serein-remote-host PRIVATE
  advapi32
  d3d11
  dxgi
  gdi32
  mf
  mfplat
  mfuuid
  ole32
  oleaut32
  user32
  wmcodecdspuuid
)

if(MSVC)
  target_compile_options(serein-remote-host PRIVATE /W4 /permissive- /EHsc /utf-8)
else()
  target_compile_options(serein-remote-host PRIVATE -Wall -Wextra -Wpedantic)
endif()
