/*
 * rdp_bridge 호스트 테스트 (Android 기기 없이 bridge 동작을 확인).
 *   rdp_bridge_test <호스트> <포트> <사용자> <비밀번호> [초]
 * 메모리 싱크로 프레임을 받고, 키·마우스·해상도 변경·클립보드 명령을 보낸 뒤 종료합니다.
 * 프레임을 하나 이상 받고 정상 종료하면 0을 돌려줍니다.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "../rdp_bridge.h"

static rdpb_session* session;
static const char* password;
static volatile int state, frames, desktop_w, desktop_h, last_error;
static volatile long long dirty_pixels;

static uint8_t* buffer;
static int buffer_w, buffer_h;

static int32_t sink_begin(void* user, int32_t w, int32_t h, rdpb_rect* dirty, uint8_t** pixels,
                          int32_t* stride)
{
	(void)user;
	if (w != buffer_w || h != buffer_h)
	{
		free(buffer);
		buffer = calloc((size_t)w * (size_t)h, 4);
		buffer_w = w;
		buffer_h = h;
		*dirty = (rdpb_rect){ 0, 0, w, h }; /* 새 버퍼: 전체를 요청 */
	}
	if (!buffer)
		return 0;
	dirty_pixels += (long long)dirty->w * dirty->h;
	*pixels = buffer;
	*stride = w * 4;
	return 1;
}

static void sink_end(void* user)
{
	(void)user;
	frames++;
}

static void on_event(void* user, rdpb_event* ev)
{
	(void)user;
	switch (ev->type)
	{
		case RDPB_EV_STATE:
			state = ev->code;
			last_error = ev->a;
			printf("[state] %d error=0x%08x %s\n", ev->code, (unsigned)ev->a, ev->text ? ev->text : "");
			break;
		case RDPB_EV_AUTH_REQUEST:
			printf("[auth] reason=%d user=%s\n", ev->code, ev->text ? ev->text : "");
			rdpb_answer_auth(session, 1, password);
			break;
		case RDPB_EV_CERT_VERIFY:
			printf("[cert] flags=%d port=%d\n%s\n", ev->code, ev->a, ev->text ? ev->text : "");
			rdpb_answer_cert(session, 1, 0);
			break;
		case RDPB_EV_DESKTOP_SIZE:
			desktop_w = ev->a;
			desktop_h = ev->b;
			printf("[size] %dx%d\n", ev->a, ev->b);
			break;
		case RDPB_EV_CLIPBOARD_TEXT:
			printf("[clipboard] %s\n", ev->text ? ev->text : "");
			break;
		default:
			break;
	}
	fflush(stdout);
	rdpb_event_free(ev);
}

int main(int argc, char** argv)
{
	if (argc < 5)
	{
		fprintf(stderr, "사용법: %s <호스트> <포트> <사용자> <비밀번호> [초]\n", argv[0]);
		return 2;
	}
	password = argv[4];
	const int seconds = argc > 5 ? atoi(argv[5]) : 5;

	rdpb_config cfg = { 0 };
	cfg.host = argv[1];
	cfg.port = atoi(argv[2]);
	cfg.username = argv[3];
	cfg.width = 1024;
	cfg.height = 768;
	cfg.dynamic_resolution = 1;
	cfg.clipboard = 1;
	cfg.cert_policy = RDPB_CERT_ASK;

	rdpb_frame_sink sink = { sink_begin, sink_end, NULL };

	session = rdpb_create(&cfg, on_event, NULL);
	if (!session)
	{
		fprintf(stderr, "rdpb_create 실패\n");
		return 1;
	}
	rdpb_attach_sink(session, &sink);
	if (rdpb_connect(session) != 0)
	{
		fprintf(stderr, "rdpb_connect 실패\n");
		return 1;
	}

	for (int i = 0; i < seconds * 10 && state != RDPB_STATE_DISCONNECTED; i++)
	{
		usleep(100 * 1000);
		if (state != RDPB_STATE_CONNECTED)
			continue;
		if (i % 10 == 0)
		{
			rdpb_send_mouse(session, RDPB_MOUSE_MOVE, 100 + i, 100 + i);
			rdpb_send_mouse(session, RDPB_MOUSE_DOWN | RDPB_MOUSE_LEFT, 100 + i, 100 + i);
			rdpb_send_mouse(session, RDPB_MOUSE_LEFT, 100 + i, 100 + i);
			rdpb_send_key(session, 0x1E, 0, 1); /* A */
			rdpb_send_key(session, 0x1E, 0, 0);
			rdpb_send_unicode(session, 0xD55C, 1); /* 한 */
			rdpb_send_unicode(session, 0xD55C, 0);
			rdpb_send_wheel(session, -120, 0);
			rdpb_clipboard_set_text(session, "rdp_bridge 테스트");
			rdpb_request_redraw(session);
		}
		if (i == 25)
			rdpb_resize(session, 800, 600);
	}

	const int was_connected = state == RDPB_STATE_CONNECTED;
	rdpb_disconnect(session);
	rdpb_attach_sink(session, NULL);
	rdpb_destroy(session);

	unsigned checksum = 0;
	for (size_t i = 0; buffer && i < (size_t)buffer_w * buffer_h * 4; i++)
		checksum = checksum * 31 + buffer[i];
	printf("결과: 연결=%d 프레임=%d 그린 픽셀=%lld 화면=%dx%d 체크섬=%08x 오류=0x%08x\n",
	       was_connected, frames, dirty_pixels, desktop_w, desktop_h, checksum, (unsigned)last_error);
	free(buffer);
	return (was_connected && frames > 0) ? 0 : 1;
}
