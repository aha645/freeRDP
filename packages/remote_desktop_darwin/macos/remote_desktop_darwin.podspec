# remote_desktop의 macOS 구현.
# Libraries/ 의 정적 라이브러리는 저장소에 들어 있지 않습니다. 먼저 저장소 최상위에서
#   bash scripts/build.sh macos-x86_64    (Apple Silicon은 macos-arm64)
# 를 실행하면 Libraries/librdp_bridge.a, Libraries/libfreerdp_all.a 가 만들어집니다.
Pod::Spec.new do |s|
  s.name             = 'remote_desktop_darwin'
  s.version          = '0.1.0'
  s.summary          = 'remote_desktop의 macOS 구현 (FreeRDP + Flutter 텍스처).'
  s.description      = <<-DESC
rdp_bridge(FreeRDP)를 정적으로 포함하고, 화면을 Flutter 텍스처(CVPixelBuffer)로 넘깁니다.
                       DESC
  s.homepage         = 'https://github.com/aha645/freeRDP'
  s.license          = { :type => 'Apache-2.0' }
  s.author           = { 'aha645' => 'noreply@example.com' }

  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.public_header_files = 'Classes/RdpAppleSink.h'
  s.preserve_paths   = 'Libraries/*.a'

  s.dependency 'FlutterMacOS'
  s.platform = :osx, '11.0'
  s.swift_version = '5.0'

  # FreeRDP가 쓰는 시스템 프레임워크 (소리·마이크, 자판, 문자열 변환 등)와 zlib
  s.frameworks = 'Foundation', 'CoreFoundation', 'CoreVideo', 'Cocoa', 'Carbon', 'CoreServices',
                 'ApplicationServices', 'CoreAudio', 'AudioToolbox', 'AVFoundation', 'CoreMedia',
                 'Security', 'SystemConfiguration', 'IOKit'
  s.libraries = 'z'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    # 정적 라이브러리를 이 plugin의 프레임워크 안에 넣습니다(앱에는 따로 링크하지 않음).
    # rdp_bridge는 Swift가 아니라 dart:ffi가 이름으로 찾아 부르므로, 쓰이지 않는 것처럼 보여도
    # 빠지지 않게 -force_load로 전부 넣습니다. FreeRDP는 필요한 부분만 들어갑니다.
    'OTHER_LDFLAGS' => '$(inherited) -force_load "$(PODS_TARGET_SRCROOT)/Libraries/librdp_bridge.a" "$(PODS_TARGET_SRCROOT)/Libraries/libfreerdp_all.a"',
  }
end
