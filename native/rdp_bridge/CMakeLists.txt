# rdp_bridge: FreeRDP·OpenSSL 정적 라이브러리를 묶어 공유 라이브러리 하나로 만듭니다.
#   Android: Flutter plugin(packages/remote_desktop_android)의 Gradle이 이 파일을 부릅니다.
#   그 밖:   cmake -S native/rdp_bridge -B <빌드 폴더> -DRDPB_FREERDP_DIR=<include, lib가 있는 폴더>
cmake_minimum_required(VERSION 3.22)
project(rdp_bridge C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

if(ANDROID)
  # scripts/build.sh가 만든 dist/android-<arch> 폴더
  if(ANDROID_ABI STREQUAL "arm64-v8a")
    set(_rdpb_target android-arm64)
  elseif(ANDROID_ABI STREQUAL "x86_64")
    set(_rdpb_target android-x86_64)
  else()
    message(FATAL_ERROR "지원하지 않는 ABI: ${ANDROID_ABI} (arm64-v8a, x86_64만 지원)")
  endif()
  set(RDPB_FREERDP_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../dist/${_rdpb_target}"
      CACHE PATH "FreeRDP include·lib 폴더"
  )
  if(NOT EXISTS "${RDPB_FREERDP_DIR}/lib/libfreerdp3.a")
    message(FATAL_ERROR "FreeRDP 라이브러리가 없습니다: ${RDPB_FREERDP_DIR}\n"
                        "먼저 저장소 최상위에서 실행하세요: bash scripts/build.sh ${_rdpb_target}"
    )
  endif()
else()
  set(RDPB_FREERDP_DIR "" CACHE PATH "FreeRDP include·lib 폴더")
  if(NOT EXISTS "${RDPB_FREERDP_DIR}/lib/libfreerdp3.a")
    message(FATAL_ERROR "-DRDPB_FREERDP_DIR=<FreeRDP 설치 폴더>를 지정하세요.")
  endif()
endif()

set(_sources rdp_bridge.c rdp_bridge_clipboard.c)
if(ANDROID)
  list(APPEND _sources android/rdp_bridge_android.c)
endif()

add_library(rdp_bridge SHARED ${_sources})
target_compile_options(rdp_bridge PRIVATE -Wall -Wextra -fvisibility=hidden)
target_include_directories(
  rdp_bridge SYSTEM PRIVATE "${RDPB_FREERDP_DIR}/include/freerdp3" "${RDPB_FREERDP_DIR}/include/winpr3"
                            "${RDPB_FREERDP_DIR}/include"
)

# 정적 라이브러리끼리 서로 참조하므로 그룹으로 묶어 링크합니다.
#   libfreerdp-client3 → 채널 내부 라이브러리(*-common) → libfreerdp3 → libwinpr3 → OpenSSL
file(GLOB _channel_libs "${RDPB_FREERDP_DIR}/lib/lib*-common.a")
set(_static_libs "${RDPB_FREERDP_DIR}/lib/libfreerdp-client3.a" ${_channel_libs}
                 "${RDPB_FREERDP_DIR}/lib/libfreerdp3.a" "${RDPB_FREERDP_DIR}/lib/libwinpr3.a"
)
foreach(_ssl ssl crypto)
  if(EXISTS "${RDPB_FREERDP_DIR}/lib/lib${_ssl}.a")
    list(APPEND _static_libs "${RDPB_FREERDP_DIR}/lib/lib${_ssl}.a")
  else()
    list(APPEND _static_libs ${_ssl}) # 시스템 OpenSSL (호스트 테스트용)
  endif()
endforeach()
target_link_libraries(rdp_bridge PRIVATE -Wl,--start-group ${_static_libs} -Wl,--end-group)

if(ANDROID)
  # log: 로그캣, android: ANativeWindow, OpenSLES: 소리·마이크, z: zlib
  target_link_libraries(rdp_bridge PRIVATE log android OpenSLES z m dl)
  # Android 15 이상의 16KB 페이지 기기 지원 (NDK r27은 직접 지정해야 함)
  target_link_options(rdp_bridge PRIVATE -Wl,-z,max-page-size=16384)
else()
  find_package(ZLIB REQUIRED)
  find_package(Threads REQUIRED)
  target_link_libraries(rdp_bridge PRIVATE ZLIB::ZLIB Threads::Threads m ${CMAKE_DL_LIBS})
  # 호스트 테스트: FreeRDP 예제 서버 등에 접속해 프레임이 도착하는지 확인
  add_executable(rdp_bridge_test test/bridge_test.c)
  target_link_libraries(rdp_bridge_test PRIVATE rdp_bridge Threads::Threads)
endif()
