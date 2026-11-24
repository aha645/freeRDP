/*
 * macOS 프레임 싱크 (설계 4장). Swift plugin이 쓰는 C 함수.
 *
 * 스레드 규칙
 *  - 그리기(begin/end): FreeRDP의 세션 스레드 또는 동적 채널 스레드. rdp_bridge가 한 번에
 *    하나만 호출하도록 잠근다(sink_lock).
 *  - rdpb_apple_sink_copy_pixel_buffer: Flutter 래스터 스레드. 그리기와 동시에 불릴 수 있다.
 *  - 만들기·없애기: 메인 스레드.
 * 그리는 쪽은 매 프레임 새 버퍼에 쓰고, 다 쓴 뒤에만 "최신 프레임"으로 바꿔 건다. 한 번 넘긴
 * 버퍼에는 다시 쓰지 않으므로 엔진이 읽는 버퍼와 쓰는 버퍼가 겹치지 않는다.
 */
#ifndef RDP_APPLE_SINK_H
#define RDP_APPLE_SINK_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 새 프레임이 준비되면 그리는 스레드에서 호출된다 */
typedef void (*rdpb_apple_frame_cb)(void* user);

/* 돌려주는 포인터는 rdpb_frame_sink 구조체의 주소(= Dart에 넘기는 sinkPtr)이기도 하다 */
void* rdpb_apple_sink_create(rdpb_apple_frame_cb frame_available, void* user);

/* 최신 프레임(CVPixelBufferRef)을 +1 보유한 채 돌려준다. 아직 없으면 NULL */
void* rdpb_apple_sink_copy_pixel_buffer(void* sink);

/* 호출 전에 세션에서 싱크를 떼고(rdpb_attach_sink(s, NULL)), 다른 스레드가
 * copy_pixel_buffer를 부르지 않도록 막아야 한다 */
void rdpb_apple_sink_destroy(void* sink);

#ifdef __cplusplus
}
#endif
#endif
