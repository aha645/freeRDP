package com.aha645.remotedesktop

import android.view.Surface

/**
 * librdp_bridge.so 안의 Android 프레임 싱크 (native/rdp_bridge/android/rdp_bridge_android.c).
 *
 * 싱크 핸들은 네이티브 `rdpb_frame_sink` 구조체의 주소이며, Dart가 이 값을
 * `rdpb_attach_sink`에 넘깁니다.
 */
internal object NativeSink {
    init {
        // dart:ffi도 같은 라이브러리를 엽니다(DynamicLibrary.open("librdp_bridge.so")).
        System.loadLibrary("rdp_bridge")
    }

    /** [home]: FreeRDP가 알려진 인증서를 저장할 폴더의 상위 폴더 */
    @JvmStatic
    external fun nativeInit(home: String)

    @JvmStatic
    external fun nativeCreate(): Long

    /** [surface]가 null이면 그리기를 멈춥니다. */
    @JvmStatic
    external fun nativeSetSurface(handle: Long, surface: Surface?)

    /** 호출 전에 Dart에서 세션의 싱크를 떼어야 합니다. */
    @JvmStatic
    external fun nativeDestroy(handle: Long)
}
