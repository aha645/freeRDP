/*
 * rdp_bridge — FreeRDP 위에 얹은 작은 C API.
 * Flutter(dart:ffi)와 플랫폼 텍스처 plugin이 이 헤더의 함수만 사용합니다.
 * 설계: docs/plugin-design.md 2장
 */
#ifndef RDP_BRIDGE_H
#define RDP_BRIDGE_H

#include <stdint.h>

#if defined(_WIN32)
#define RDPB_API __declspec(dllexport)
#else
#define RDPB_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct rdpb_session rdpb_session; /* 불투명 핸들 */

typedef enum
{
	RDPB_CERT_ASK = 0,    /* 항상 RDPB_EV_CERT_VERIFY로 묻는다 */
	RDPB_CERT_IGNORE = 1, /* 확인하지 않는다 (SSH 터널 전용) */
	RDPB_CERT_TOFU = 2    /* 처음 본 인증서는 저장하고, 바뀌었을 때만 묻는다 */
} rdpb_cert_policy;

typedef struct
{
	const char* host;
	int32_t port;         /* 0이면 3389 */
	const char* username; /* NULL 가능 */
	const char* domain;   /* NULL 가능. 비밀번호는 RDPB_EV_AUTH_REQUEST로 받는다 */
	int32_t width, height;
	int32_t dynamic_resolution; /* disp 채널 */
	int32_t clipboard;          /* cliprdr (텍스트) */
	int32_t audio_playback;     /* rdpsnd */
	int32_t microphone;         /* audin */
	int32_t cert_policy;        /* rdpb_cert_policy */
	const char* config_dir;     /* 알려진 인증서 저장 폴더. NULL이면 $HOME/.config/freerdp */
} rdpb_config;

typedef enum
{
	RDPB_EV_STATE = 0,         /* code = rdpb_state, a = FreeRDP 오류 코드, text = 오류 이름 */
	RDPB_EV_AUTH_REQUEST = 1,  /* code = 인증 단계, text = 사용자 이름 → rdpb_answer_auth() */
	RDPB_EV_CERT_VERIFY = 2,   /* code = rdpb_cert_flags, a = 포트, text = 5줄(아래) → rdpb_answer_cert() */
	RDPB_EV_DESKTOP_SIZE = 3,  /* a = 너비, b = 높이 */
	RDPB_EV_CURSOR = 4,        /* (예약) 커서 모양. 아직 보내지 않음 */
	RDPB_EV_CLIPBOARD_TEXT = 5 /* text = 원격 클립보드 텍스트 (UTF-8) */
} rdpb_event_type;

typedef enum
{
	RDPB_STATE_CONNECTING = 1,
	RDPB_STATE_CONNECTED = 2,
	RDPB_STATE_DISCONNECTED = 3
} rdpb_state;

/* RDPB_EV_CERT_VERIFY의 code. text는 줄바꿈으로 나눈
 * "호스트\n이름(CN)\n주체\n발급자\n지문" 이고, RDPB_CERT_FLAG_CHANGED이면 6번째 줄에 이전 지문이 붙는다. */
enum
{
	RDPB_CERT_FLAG_CHANGED = 1, /* 저장해 둔 인증서와 다름 */
	RDPB_CERT_FLAG_MISMATCH = 2 /* 인증서의 호스트 이름이 접속 주소와 다름 */
};

typedef struct
{
	int32_t type; /* rdpb_event_type */
	int32_t code;
	int32_t a, b;
	const char* text;    /* UTF-8, NULL 가능 */
	const uint8_t* data; /* NULL 가능 */
	int32_t data_len;
} rdpb_event;

/* 세션 스레드에서 호출된다. 받은 쪽이 다 쓴 뒤 rdpb_event_free(ev)를 불러야 한다.
 * (Dart NativeCallable.listener는 콜백이 끝난 뒤에 실행되므로 이벤트를 힙에 따로 둔다.) */
typedef void (*rdpb_event_cb)(void* user, rdpb_event* ev);

/* ---- 프레임 싱크: 플랫폼 텍스처 plugin이 구현 (설계 4장) ----
 * 픽셀 형식은 4바이트/픽셀. Android는 R,G,B,X 순서, 그 밖의 플랫폼은 B,G,R,X 순서. */
typedef struct
{
	int32_t x, y, w, h;
} rdpb_rect;

typedef struct rdpb_frame_sink
{
	/* 버퍼를 잠근다. width/height는 원격 화면 크기.
	 * dirty는 입출력: 들어올 때는 bridge가 새로 그리려는 영역, 나갈 때는 싱크가 실제로
	 * 채워야 한다고 판단한 영역(같거나 더 넓음. 예: 새 버퍼라 전체가 필요한 경우).
	 * 성공하면 1을 돌려주고 *pixels(버퍼의 0,0 위치)와 *stride(바이트)를 채운다.
	 * 0을 돌려주면 이번 프레임을 건너뛴다(end는 호출되지 않음). */
	int32_t (*begin)(void* user, int32_t width, int32_t height, rdpb_rect* dirty, uint8_t** pixels,
	                 int32_t* stride);
	/* 버퍼를 풀고 엔진에 새 프레임을 알린다. */
	void (*end)(void* user);
	void* user;
} rdpb_frame_sink;

/* ---- 세션 ---- */
RDPB_API rdpb_session* rdpb_create(const rdpb_config* cfg, rdpb_event_cb cb, void* user);
/* sink는 세션이 끝나거나 rdpb_attach_sink(s, NULL)을 부를 때까지 살아 있어야 한다. */
RDPB_API int32_t rdpb_attach_sink(rdpb_session* s, const rdpb_frame_sink* sink);
RDPB_API int32_t rdpb_connect(rdpb_session* s); /* 비동기: 자체 스레드에서 접속. 세션당 한 번 */
RDPB_API void rdpb_disconnect(rdpb_session* s); /* 비동기: RDPB_STATE_DISCONNECTED 이벤트로 끝남 */
RDPB_API void rdpb_destroy(rdpb_session* s);    /* 스레드 종료를 기다린 뒤 해제 */
RDPB_API void rdpb_event_free(rdpb_event* ev);

/* ---- 질문에 대한 응답 ---- */
RDPB_API void rdpb_answer_auth(rdpb_session* s, int32_t ok, const char* password);
RDPB_API void rdpb_answer_cert(rdpb_session* s, int32_t accept, int32_t remember);

/* ---- 입력·제어: 어느 스레드에서 불러도 된다 (세션 스레드의 큐로 전달) ---- */
RDPB_API void rdpb_send_key(rdpb_session* s, uint16_t scancode, int32_t extended, int32_t down);
RDPB_API void rdpb_send_unicode(rdpb_session* s, uint16_t codeunit, int32_t down); /* UTF-16 단위 */
RDPB_API void rdpb_send_mouse(rdpb_session* s, uint16_t flags, int32_t x, int32_t y);
RDPB_API void rdpb_send_wheel(rdpb_session* s, int32_t delta, int32_t horizontal);
RDPB_API void rdpb_resize(rdpb_session* s, int32_t width, int32_t height);
RDPB_API void rdpb_clipboard_set_text(rdpb_session* s, const char* utf8);
/* 화면 전체를 싱크에 다시 그린다 (텍스처 Surface가 새로 만들어졌을 때) */
RDPB_API void rdpb_request_redraw(rdpb_session* s);

/* rdpb_send_mouse의 flags (RDP 값 그대로) */
#define RDPB_MOUSE_MOVE 0x0800
#define RDPB_MOUSE_DOWN 0x8000
#define RDPB_MOUSE_LEFT 0x1000
#define RDPB_MOUSE_RIGHT 0x2000
#define RDPB_MOUSE_MIDDLE 0x4000

#ifdef __cplusplus
}
#endif
#endif /* RDP_BRIDGE_H */
