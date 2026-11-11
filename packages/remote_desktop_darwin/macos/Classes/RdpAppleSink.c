/* macOS 프레임 싱크 구현. 스레드 규칙은 RdpAppleSink.h 참고. */
#include <CoreFoundation/CoreFoundation.h>
#include <CoreVideo/CoreVideo.h>
#include <pthread.h>
#include <stdlib.h>

/* 저장소의 native/rdp_bridge/rdp_bridge.h (podspec은 pod 밖의 경로를 넣을 수 없어 상대 경로로 포함) */
#include "../../../../native/rdp_bridge/rdp_bridge.h"
#include "RdpAppleSink.h"

typedef struct
{
	rdpb_frame_sink base; /* 반드시 첫 필드: sinkPtr == 이 구조체의 주소 */

	/* 그리는 스레드와 래스터 스레드가 함께 쓰는 유일한 필드. lock으로 보호 */
	pthread_mutex_t lock;
	CVPixelBufferRef current; /* 엔진에 넘길 최신 완성 프레임 */

	/* 아래는 그리는 스레드만 쓴다 (rdp_bridge의 sink_lock이 한 번에 하나만 들어오게 함) */
	CVPixelBufferPoolRef pool;
	int32_t width, height;
	CVPixelBufferRef drawing; /* begin ~ end 사이에 쓰는 중인 버퍼. 아직 아무에게도 보이지 않음 */

	/* 만든 뒤 바뀌지 않음 */
	rdpb_apple_frame_cb frame_available;
	void* user;
} apple_sink;

static void set_int(CFMutableDictionaryRef dict, CFStringRef key, int32_t value)
{
	CFNumberRef number = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &value);
	CFDictionarySetValue(dict, key, number);
	CFRelease(number);
}

static CVPixelBufferPoolRef create_pool(int32_t width, int32_t height)
{
	CFMutableDictionaryRef attrs = CFDictionaryCreateMutable(
	    kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	CFDictionaryRef surface = CFDictionaryCreate(kCFAllocatorDefault, NULL, NULL, 0,
	                                             &kCFTypeDictionaryKeyCallBacks,
	                                             &kCFTypeDictionaryValueCallBacks);
	set_int(attrs, kCVPixelBufferPixelFormatTypeKey, (int32_t)kCVPixelFormatType_32BGRA);
	set_int(attrs, kCVPixelBufferWidthKey, width);
	set_int(attrs, kCVPixelBufferHeightKey, height);
	CFDictionarySetValue(attrs, kCVPixelBufferIOSurfacePropertiesKey, surface); /* GPU와 공유 */
	CFDictionarySetValue(attrs, kCVPixelBufferMetalCompatibilityKey, kCFBooleanTrue);

	CVPixelBufferPoolRef pool = NULL;
	if (CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL, attrs, &pool) != kCVReturnSuccess)
		pool = NULL;
	CFRelease(surface);
	CFRelease(attrs);
	return pool;
}

static int32_t sink_begin(void* user, int32_t width, int32_t height, rdpb_rect* dirty,
                          uint8_t** pixels, int32_t* stride)
{
	apple_sink* sink = user;
	if (width <= 0 || height <= 0)
		return 0;

	if (!sink->pool || sink->width != width || sink->height != height)
	{
		if (sink->pool)
			CVPixelBufferPoolRelease(sink->pool);
		sink->pool = create_pool(width, height);
		sink->width = width;
		sink->height = height;
		if (!sink->pool)
			return 0;
	}

	/* 매 프레임 새 버퍼를 받는다. 엔진이 놓아준 버퍼는 풀이 다시 내준다. */
	CVPixelBufferRef buffer = NULL;
	if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, sink->pool, &buffer) !=
	        kCVReturnSuccess ||
	    !buffer)
		return 0;
	if (CVPixelBufferLockBaseAddress(buffer, 0) != kCVReturnSuccess)
	{
		CVPixelBufferRelease(buffer);
		return 0;
	}

	sink->drawing = buffer;
	*pixels = CVPixelBufferGetBaseAddress(buffer);
	*stride = (int32_t)CVPixelBufferGetBytesPerRow(buffer);
	*dirty = (rdpb_rect){ 0, 0, width, height }; /* 새 버퍼이므로 화면 전체를 채워야 함 */
	return 1;
}

static void sink_end(void* user)
{
	apple_sink* sink = user;
	CVPixelBufferRef buffer = sink->drawing;
	sink->drawing = NULL;
	if (!buffer)
		return;

	/* FreeRDP의 X(쓰지 않는 바이트)가 0이면 투명하게 보이므로 불투명으로 채운다 */
	uint8_t* base = CVPixelBufferGetBaseAddress(buffer);
	const size_t stride = CVPixelBufferGetBytesPerRow(buffer);
	for (int32_t y = 0; y < sink->height; y++)
	{
		uint8_t* alpha = base + (size_t)y * stride + 3;
		for (int32_t x = 0; x < sink->width; x++, alpha += 4)
			*alpha = 0xFF;
	}
	CVPixelBufferUnlockBaseAddress(buffer, 0);

	/* 다 쓴 버퍼를 최신 프레임으로 바꿔 건다. 이 뒤로는 이 버퍼에 쓰지 않는다. */
	pthread_mutex_lock(&sink->lock);
	CVPixelBufferRef old = sink->current;
	sink->current = buffer;
	pthread_mutex_unlock(&sink->lock);
	if (old)
		CVPixelBufferRelease(old); /* 엔진이 아직 쓰고 있으면 엔진의 보유분이 남아 있음 */

	sink->frame_available(sink->user);
}

void* rdpb_apple_sink_create(rdpb_apple_frame_cb frame_available, void* user)
{
	apple_sink* sink = calloc(1, sizeof(apple_sink));
	if (!sink)
		return NULL;
	pthread_mutex_init(&sink->lock, NULL);
	sink->frame_available = frame_available;
	sink->user = user;
	sink->base.begin = sink_begin;
	sink->base.end = sink_end;
	sink->base.user = sink;
	return sink;
}

void* rdpb_apple_sink_copy_pixel_buffer(void* handle)
{
	apple_sink* sink = handle;
	if (!sink)
		return NULL;
	pthread_mutex_lock(&sink->lock);
	CVPixelBufferRef buffer = sink->current;
	if (buffer)
		CVPixelBufferRetain(buffer); /* 잠금 안에서 보유해야 그 사이에 해제되지 않음 */
	pthread_mutex_unlock(&sink->lock);
	return buffer;
}

void rdpb_apple_sink_destroy(void* handle)
{
	apple_sink* sink = handle;
	if (!sink)
		return;
	if (sink->drawing)
	{
		CVPixelBufferUnlockBaseAddress(sink->drawing, 0);
		CVPixelBufferRelease(sink->drawing);
	}
	if (sink->current)
		CVPixelBufferRelease(sink->current);
	if (sink->pool)
		CVPixelBufferPoolRelease(sink->pool);
	pthread_mutex_destroy(&sink->lock);
	free(sink);
}
