/*
 * rdp_bridge — Android 프레임 싱크 (설계 4장).
 * Flutter SurfaceProducer의 Surface를 ANativeWindow로 잠가 픽셀을 직접 씁니다.
 * Kotlin 쪽: com.aha645.remotedesktop.NativeSink
 */
#include <jni.h>
#include <pthread.h>
#include <stdlib.h>

#include <android/native_window.h>
#include <android/native_window_jni.h>

#include "../rdp_bridge.h"

/* WinPR(정적 링크)이 시간대 조회 등에 쓰는 JavaVM 포인터. 보통 WinPR의 JNI_OnLoad가 채우지만,
 * 라이브러리를 dart:ffi가 먼저 열었을 때를 대비해 nativeInit에서도 채운다. */
extern JavaVM* jniVm __attribute__((weak));

typedef struct
{
	rdpb_frame_sink base; /* 반드시 첫 필드: sinkPtr == 이 구조체의 주소 */
	pthread_mutex_t lock;
	ANativeWindow* window;
	int32_t width, height; /* 마지막으로 설정한 버퍼 크기 */
	int full;              /* 다음 프레임은 전체를 그려야 함 (새 Surface) */
} android_sink;

static int32_t sink_begin(void* user, int32_t width, int32_t height, rdpb_rect* dirty,
                          uint8_t** pixels, int32_t* stride)
{
	android_sink* sink = user;
	pthread_mutex_lock(&sink->lock);

	if (!sink->window)
		goto skip;

	if (sink->width != width || sink->height != height)
	{
		if (ANativeWindow_setBuffersGeometry(sink->window, width, height,
		                                     WINDOW_FORMAT_RGBX_8888) != 0)
			goto skip;
		sink->width = width;
		sink->height = height;
		sink->full = 1;
	}

	/* 잠글 때 바뀔 영역을 알려 주면, 나머지 영역은 시스템이 이전 프레임에서 복사해 준다.
	 * 복사할 수 없으면(첫 프레임 등) 시스템이 영역을 전체로 넓혀서 돌려준다. */
	ARect bounds = { dirty->x, dirty->y, dirty->x + dirty->w, dirty->y + dirty->h };
	if (sink->full)
		bounds = (ARect){ 0, 0, width, height };

	ANativeWindow_Buffer buffer;
	if (ANativeWindow_lock(sink->window, &buffer, &bounds) != 0)
		goto skip;

	if (buffer.width != width || buffer.height != height)
	{
		/* 크기 변경이 아직 반영되지 않은 버퍼: 이번 프레임은 버리고 다음에 전체를 그린다 */
		ANativeWindow_unlockAndPost(sink->window);
		sink->full = 1;
		goto skip;
	}

	sink->full = 0;
	dirty->x = bounds.left;
	dirty->y = bounds.top;
	dirty->w = bounds.right - bounds.left;
	dirty->h = bounds.bottom - bounds.top;
	*pixels = buffer.bits;
	*stride = buffer.stride * 4;
	return 1; /* 잠금은 sink_end에서 푼다 */

skip:
	pthread_mutex_unlock(&sink->lock);
	return 0;
}

static void sink_end(void* user)
{
	android_sink* sink = user;
	ANativeWindow_unlockAndPost(sink->window);
	pthread_mutex_unlock(&sink->lock);
}

JNIEXPORT void JNICALL Java_com_aha645_remotedesktop_NativeSink_nativeInit(JNIEnv* env, jclass clazz,
                                                                          jstring home)
{
	(void)clazz;
	if (&jniVm && !jniVm)
		(*env)->GetJavaVM(env, &jniVm);

	/* FreeRDP는 $HOME/.config/freerdp에 알려진 인증서를 저장한다. Android에는 HOME이 없다. */
	const char* path = (*env)->GetStringUTFChars(env, home, NULL);
	if (path)
	{
		setenv("HOME", path, 0);
		(*env)->ReleaseStringUTFChars(env, home, path);
	}
}

JNIEXPORT jlong JNICALL Java_com_aha645_remotedesktop_NativeSink_nativeCreate(JNIEnv* env,
                                                                             jclass clazz)
{
	(void)env;
	(void)clazz;
	android_sink* sink = calloc(1, sizeof(android_sink));
	if (!sink)
		return 0;
	pthread_mutex_init(&sink->lock, NULL);
	sink->base.begin = sink_begin;
	sink->base.end = sink_end;
	sink->base.user = sink;
	return (jlong)(intptr_t)sink;
}

/* surface가 null이면 그리기를 멈춘다 */
JNIEXPORT void JNICALL Java_com_aha645_remotedesktop_NativeSink_nativeSetSurface(JNIEnv* env,
                                                                                jclass clazz,
                                                                                jlong handle,
                                                                                jobject surface)
{
	(void)clazz;
	android_sink* sink = (android_sink*)(intptr_t)handle;
	if (!sink)
		return;
	ANativeWindow* window = surface ? ANativeWindow_fromSurface(env, surface) : NULL;

	pthread_mutex_lock(&sink->lock);
	ANativeWindow* old = sink->window;
	sink->window = window;
	sink->width = sink->height = 0;
	sink->full = 1;
	pthread_mutex_unlock(&sink->lock);

	if (old)
		ANativeWindow_release(old);
}

/* 호출 전에 반드시 rdpb_attach_sink(session, NULL)로 세션에서 떼어야 한다 */
JNIEXPORT void JNICALL Java_com_aha645_remotedesktop_NativeSink_nativeDestroy(JNIEnv* env,
                                                                             jclass clazz,
                                                                             jlong handle)
{
	(void)env;
	(void)clazz;
	android_sink* sink = (android_sink*)(intptr_t)handle;
	if (!sink)
		return;
	if (sink->window)
		ANativeWindow_release(sink->window);
	pthread_mutex_destroy(&sink->lock);
	free(sink);
}
