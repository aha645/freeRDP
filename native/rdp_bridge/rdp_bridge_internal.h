/* rdp_bridge 내부 공용 정의 (rdp_bridge.c, rdp_bridge_clipboard.c) */
#ifndef RDP_BRIDGE_INTERNAL_H
#define RDP_BRIDGE_INTERNAL_H

#include <freerdp/freerdp.h>
#include <freerdp/client.h>
#include <freerdp/client/cliprdr.h>
#include <freerdp/client/disp.h>

#include <winpr/synch.h>

#include "rdp_bridge.h"

typedef enum
{
	RDPB_CMD_KEY,
	RDPB_CMD_UNICODE,
	RDPB_CMD_MOUSE,
	RDPB_CMD_WHEEL,
	RDPB_CMD_RESIZE,
	RDPB_CMD_CLIPBOARD,
	RDPB_CMD_REDRAW
} rdpb_cmd_type;

typedef struct
{
	rdpb_cmd_type type;
	int32_t a, b, c;
} rdpb_cmd;

struct rdpb_session
{
	rdpContext* context;
	rdpb_event_cb cb;
	void* user;
	int32_t cert_policy;

	HANDLE thread;
	HANDLE stop_event;   /* rdpb_disconnect가 켠다 */
	HANDLE cmd_event;    /* 명령 큐에 항목이 있음 */
	HANDLE answer_event; /* rdpb_answer_*가 켠다 */

	CRITICAL_SECTION lock; /* 아래 큐·응답·클립보드 텍스트 보호 */
	rdpb_cmd* cmds;
	size_t cmd_count, cmd_cap;
	int32_t answer_ok;
	int32_t answer_remember;
	char* answer_password;
	char* clip_text; /* 로컬 클립보드 텍스트 (UTF-8) */

	CRITICAL_SECTION sink_lock;
	const rdpb_frame_sink* sink;

	/* 세션 스레드 전용 */
	BOOL active; /* PostConnect ~ PostDisconnect */
	int32_t mouse_x, mouse_y;
	DispClientContext* disp;
	BOOL disp_ready;          /* 서버가 해상도 변경 기능(caps)을 알린 뒤 */
	int32_t want_w, want_h;   /* 요청받은 해상도. 0이면 없음 */
	CliprdrClientContext* cliprdr;
	BOOL clip_ready; /* 서버가 MonitorReady를 보낸 뒤 */
};

typedef struct
{
	rdpClientContext common;
	rdpb_session* session;
} rdpb_context;

void rdpb_emit(rdpb_session* s, int32_t type, int32_t code, int32_t a, int32_t b, const char* text);

/* rdp_bridge_clipboard.c */
void rdpb_clipboard_attach(rdpb_session* s, CliprdrClientContext* cliprdr);
void rdpb_clipboard_detach(rdpb_session* s);
void rdpb_clipboard_announce(rdpb_session* s); /* 로컬 텍스트가 바뀌었음을 서버에 알림 */

#endif
