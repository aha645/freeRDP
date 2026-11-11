/*
 * rdp_bridge — 세션, 이벤트, 입력 큐, 화면 복사, 인증·인증서 질문, 해상도 변경.
 * FreeRDP 3.24.x 기준. 설계: docs/plugin-design.md 2장
 */
#include <stdlib.h>
#include <string.h>

#include <freerdp/gdi/gdi.h>
#include <freerdp/gdi/gfx.h>
#include <freerdp/channels/channels.h>
#include <freerdp/channels/cliprdr.h>
#include <freerdp/channels/disp.h>
#include <freerdp/client/channels.h>
#include <freerdp/input.h>
#include <freerdp/settings.h>

#include <winpr/crt.h>
#include <winpr/thread.h>

#include "rdp_bridge_internal.h"

/* 싱크 버퍼의 바이트 순서: Android Surface는 R,G,B,X / 그 밖은 B,G,R,X */
#if defined(__ANDROID__)
#define RDPB_PIXEL_FORMAT PIXEL_FORMAT_RGBX32
#else
#define RDPB_PIXEL_FORMAT PIXEL_FORMAT_BGRX32
#endif

static rdpb_session* session_of(rdpContext* context)
{
	return ((rdpb_context*)context)->session;
}

/* ------------------------------------------------------------------ 이벤트 */

void rdpb_emit(rdpb_session* s, int32_t type, int32_t code, int32_t a, int32_t b, const char* text)
{
	if (!s->cb)
		return;
	const size_t len = text ? strlen(text) + 1 : 0;
	rdpb_event* ev = calloc(1, sizeof(rdpb_event) + len);
	if (!ev)
		return;
	ev->type = type;
	ev->code = code;
	ev->a = a;
	ev->b = b;
	if (text)
	{
		char* copy = (char*)(ev + 1);
		memcpy(copy, text, len);
		ev->text = copy;
	}
	s->cb(s->user, ev);
}

void rdpb_event_free(rdpb_event* ev)
{
	free(ev);
}

/* ------------------------------------------------------------------ 화면 */

/* gdi 버퍼의 지정 영역을 싱크에 복사한다. 세션 스레드에서만 호출. */
static void present(rdpb_session* s, int32_t x, int32_t y, int32_t w, int32_t h)
{
	rdpGdi* gdi = s->context->gdi;
	if (!gdi || !gdi->primary_buffer || gdi->width <= 0 || gdi->height <= 0)
		return;

	EnterCriticalSection(&s->sink_lock);
	const rdpb_frame_sink* sink = s->sink;
	if (sink)
	{
		rdpb_rect d = { x, y, w, h };
		uint8_t* pixels = NULL;
		int32_t stride = 0;
		if (sink->begin(sink->user, gdi->width, gdi->height, &d, &pixels, &stride))
		{
			/* 싱크가 넓혀 준 영역을 화면 안으로 자른다 */
			int32_t x0 = d.x < 0 ? 0 : d.x;
			int32_t y0 = d.y < 0 ? 0 : d.y;
			int32_t x1 = d.x + d.w > gdi->width ? gdi->width : d.x + d.w;
			int32_t y1 = d.y + d.h > gdi->height ? gdi->height : d.y + d.h;
			if (pixels && x1 > x0 && y1 > y0)
			{
				const size_t bytes = (size_t)(x1 - x0) * 4;
				for (int32_t row = y0; row < y1; row++)
				{
					memcpy(pixels + (size_t)row * (size_t)stride + (size_t)x0 * 4,
					       gdi->primary_buffer + (size_t)row * gdi->stride + (size_t)x0 * 4, bytes);
				}
			}
			sink->end(sink->user);
		}
	}
	LeaveCriticalSection(&s->sink_lock);
}

static BOOL on_begin_paint(rdpContext* context)
{
	rdpGdi* gdi = context->gdi;
	if (gdi && gdi->primary && gdi->primary->hdc && gdi->primary->hdc->hwnd)
	{
		HGDI_WND hwnd = gdi->primary->hdc->hwnd;
		hwnd->invalid->null = TRUE;
		hwnd->ninvalid = 0;
	}
	return TRUE;
}

static BOOL on_end_paint(rdpContext* context)
{
	rdpb_session* s = session_of(context);
	rdpGdi* gdi = context->gdi;
	if (!gdi || !gdi->primary || !gdi->primary->hdc || !gdi->primary->hdc->hwnd)
		return TRUE;

	HGDI_WND hwnd = gdi->primary->hdc->hwnd;
	if (gdi->suppressOutput || hwnd->invalid->null || hwnd->ninvalid < 1)
		return TRUE;

	/* 바뀐 영역들을 하나의 사각형으로 묶는다 */
	int32_t x0 = gdi->width, y0 = gdi->height, x1 = 0, y1 = 0;
	for (INT32 i = 0; i < hwnd->ninvalid; i++)
	{
		const GDI_RGN* r = &hwnd->cinvalid[i];
		if (r->x < x0)
			x0 = r->x;
		if (r->y < y0)
			y0 = r->y;
		if (r->x + r->w > x1)
			x1 = r->x + r->w;
		if (r->y + r->h > y1)
			y1 = r->y + r->h;
	}
	if (x0 < 0)
		x0 = 0;
	if (y0 < 0)
		y0 = 0;
	if (x1 > gdi->width)
		x1 = gdi->width;
	if (y1 > gdi->height)
		y1 = gdi->height;
	if (x1 > x0 && y1 > y0)
		present(s, x0, y0, x1 - x0, y1 - y0);
	return TRUE;
}

static BOOL on_desktop_resize(rdpContext* context)
{
	rdpb_session* s = session_of(context);
	rdpSettings* settings = context->settings;
	const UINT32 w = freerdp_settings_get_uint32(settings, FreeRDP_DesktopWidth);
	const UINT32 h = freerdp_settings_get_uint32(settings, FreeRDP_DesktopHeight);
	if (!gdi_resize(context->gdi, w, h))
		return FALSE;
	rdpb_emit(s, RDPB_EV_DESKTOP_SIZE, 0, (int32_t)w, (int32_t)h, NULL);
	return TRUE;
}

/* ------------------------------------------------------------------ 질문과 응답 */

/* 응답(rdpb_answer_*)이 오면 TRUE, 접속 중단이면 FALSE */
static BOOL wait_answer(rdpb_session* s)
{
	HANDLE handles[3] = { s->answer_event, s->stop_event, freerdp_abort_event(s->context) };
	const DWORD rc = WaitForMultipleObjects(3, handles, FALSE, INFINITE);
	return rc == WAIT_OBJECT_0;
}

static BOOL on_authenticate(freerdp* instance, char** username, char** password, char** domain,
                            rdp_auth_reason reason)
{
	rdpb_session* s = session_of(instance->context);
	WINPR_UNUSED(domain);

	(void)ResetEvent(s->answer_event);
	rdpb_emit(s, RDPB_EV_AUTH_REQUEST, (int32_t)reason, 0, 0, username ? *username : NULL);
	if (!wait_answer(s))
		return FALSE;

	BOOL ok = FALSE;
	EnterCriticalSection(&s->lock);
	if (s->answer_ok && s->answer_password)
	{
		char* copy = _strdup(s->answer_password);
		if (copy)
		{
			free(*password);
			*password = copy;
			ok = TRUE;
		}
	}
	if (s->answer_password)
	{
		memset(s->answer_password, 0, strlen(s->answer_password));
		free(s->answer_password);
		s->answer_password = NULL;
	}
	LeaveCriticalSection(&s->lock);
	return ok;
}

/* FreeRDP 반환값: 1 = 수락하고 저장, 2 = 이번만 수락, 0 = 거부 */
static DWORD ask_certificate(rdpb_session* s, const char* host, UINT16 port, const char* common_name,
                             const char* subject, const char* issuer, const char* fingerprint,
                             const char* old_fingerprint, DWORD flags)
{
	int32_t code = 0;
	if (flags & VERIFY_CERT_FLAG_CHANGED)
		code |= RDPB_CERT_FLAG_CHANGED;
	if (flags & VERIFY_CERT_FLAG_MISMATCH)
		code |= RDPB_CERT_FLAG_MISMATCH;

	const char* parts[6] = { host, common_name, subject, issuer, fingerprint, old_fingerprint };
	const size_t count = old_fingerprint ? 6 : 5;
	size_t len = 1;
	for (size_t i = 0; i < count; i++)
		len += (parts[i] ? strlen(parts[i]) : 0) + 1;
	char* text = calloc(1, len);
	if (!text)
		return 0;
	for (size_t i = 0; i < count; i++)
	{
		if (i > 0)
			strcat(text, "\n");
		if (parts[i])
			strcat(text, parts[i]);
	}

	(void)ResetEvent(s->answer_event);
	rdpb_emit(s, RDPB_EV_CERT_VERIFY, code, port, 0, text);
	free(text);
	if (!wait_answer(s))
		return 0;

	EnterCriticalSection(&s->lock);
	const DWORD rc = !s->answer_ok ? 0 : (s->answer_remember ? 1 : 2);
	LeaveCriticalSection(&s->lock);
	return rc;
}

static DWORD on_verify_certificate(freerdp* instance, const char* host, UINT16 port,
                                   const char* common_name, const char* subject, const char* issuer,
                                   const char* fingerprint, DWORD flags)
{
	rdpb_session* s = session_of(instance->context);
	if (s->cert_policy == RDPB_CERT_TOFU)
		return 1; /* 처음 본 인증서: 저장하고 진행 */
	return ask_certificate(s, host, port, common_name, subject, issuer, fingerprint, NULL, flags);
}

static DWORD on_verify_changed_certificate(freerdp* instance, const char* host, UINT16 port,
                                           const char* common_name, const char* subject,
                                           const char* issuer, const char* fingerprint,
                                           const char* old_subject, const char* old_issuer,
                                           const char* old_fingerprint, DWORD flags)
{
	rdpb_session* s = session_of(instance->context);
	WINPR_UNUSED(old_subject);
	WINPR_UNUSED(old_issuer);
	return ask_certificate(s, host, port, common_name, subject, issuer, fingerprint,
	                       old_fingerprint ? old_fingerprint : "", flags | VERIFY_CERT_FLAG_CHANGED);
}

void rdpb_answer_auth(rdpb_session* s, int32_t ok, const char* password)
{
	if (!s)
		return;
	EnterCriticalSection(&s->lock);
	free(s->answer_password);
	s->answer_password = (ok && password) ? _strdup(password) : NULL;
	s->answer_ok = ok;
	LeaveCriticalSection(&s->lock);
	(void)SetEvent(s->answer_event);
}

void rdpb_answer_cert(rdpb_session* s, int32_t accept, int32_t remember)
{
	if (!s)
		return;
	EnterCriticalSection(&s->lock);
	s->answer_ok = accept;
	s->answer_remember = remember;
	LeaveCriticalSection(&s->lock);
	(void)SetEvent(s->answer_event);
}

/* ------------------------------------------------------------------ 채널 */

static UINT on_disp_caps(DispClientContext* disp, UINT32 max_monitors, UINT32 factor_a,
                         UINT32 factor_b);

static void on_channel_connected(void* context, const ChannelConnectedEventArgs* e)
{
	rdpb_session* s = session_of((rdpContext*)context);
	if (strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0)
	{
		s->disp = (DispClientContext*)e->pInterface;
		s->disp->custom = s;
		s->disp->DisplayControlCaps = on_disp_caps;
	}
	else if (strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0)
		rdpb_clipboard_attach(s, (CliprdrClientContext*)e->pInterface);
	else
		freerdp_client_OnChannelConnectedEventHandler(context, e); /* rdpgfx 등 */
}

static void on_channel_disconnected(void* context, const ChannelDisconnectedEventArgs* e)
{
	rdpb_session* s = session_of((rdpContext*)context);
	if (strcmp(e->name, DISP_DVC_CHANNEL_NAME) == 0)
	{
		s->disp = NULL;
		s->disp_ready = FALSE;
	}
	else if (strcmp(e->name, CLIPRDR_SVC_CHANNEL_NAME) == 0)
		rdpb_clipboard_detach(s);
	else
		freerdp_client_OnChannelDisconnectedEventHandler(context, e);
}

/* ------------------------------------------------------------------ FreeRDP 콜백 */

static BOOL on_pre_connect(freerdp* instance)
{
	rdpContext* context = instance->context;
	if (PubSub_SubscribeChannelConnected(context->pubSub, on_channel_connected) < 0)
		return FALSE;
	if (PubSub_SubscribeChannelDisconnected(context->pubSub, on_channel_disconnected) < 0)
		return FALSE;
	return TRUE;
}

static BOOL on_post_connect(freerdp* instance)
{
	rdpContext* context = instance->context;
	rdpb_session* s = session_of(context);

	if (!gdi_init(instance, RDPB_PIXEL_FORMAT))
		return FALSE;

	context->update->BeginPaint = on_begin_paint;
	context->update->EndPaint = on_end_paint;
	context->update->DesktopResize = on_desktop_resize;

	s->active = TRUE;
	rdpb_emit(s, RDPB_EV_DESKTOP_SIZE, 0, context->gdi->width, context->gdi->height, NULL);
	return TRUE;
}

static void on_post_disconnect(freerdp* instance)
{
	rdpContext* context = instance->context;
	rdpb_session* s = session_of(context);

	s->active = FALSE;
	(void)PubSub_UnsubscribeChannelConnected(context->pubSub, on_channel_connected);
	(void)PubSub_UnsubscribeChannelDisconnected(context->pubSub, on_channel_disconnected);
	gdi_free(instance);
}

static int on_logon_error_info(freerdp* instance, UINT32 data, UINT32 type)
{
	WINPR_UNUSED(instance);
	WINPR_UNUSED(data);
	WINPR_UNUSED(type);
	return 1;
}

static BOOL client_new(freerdp* instance, rdpContext* context)
{
	WINPR_UNUSED(context);
	instance->PreConnect = on_pre_connect;
	instance->PostConnect = on_post_connect;
	instance->PostDisconnect = on_post_disconnect;
	instance->AuthenticateEx = on_authenticate;
	instance->VerifyCertificateEx = on_verify_certificate;
	instance->VerifyChangedCertificateEx = on_verify_changed_certificate;
	instance->LogonErrorInfo = on_logon_error_info;
	return TRUE;
}

/* ------------------------------------------------------------------ 명령 큐 */

static void push_cmd(rdpb_session* s, rdpb_cmd_type type, int32_t a, int32_t b, int32_t c)
{
	if (!s)
		return;
	EnterCriticalSection(&s->lock);
	if (s->cmd_count == s->cmd_cap)
	{
		const size_t cap = s->cmd_cap ? s->cmd_cap * 2 : 64;
		rdpb_cmd* grown = realloc(s->cmds, cap * sizeof(rdpb_cmd));
		if (!grown)
		{
			LeaveCriticalSection(&s->lock);
			return;
		}
		s->cmds = grown;
		s->cmd_cap = cap;
	}
	s->cmds[s->cmd_count++] = (rdpb_cmd){ type, a, b, c };
	LeaveCriticalSection(&s->lock);
	(void)SetEvent(s->cmd_event);
}

static UINT16 clamp_u16(int32_t v)
{
	return (UINT16)(v < 0 ? 0 : (v > 0xFFFF ? 0xFFFF : v));
}

/* 요청받은 해상도를 서버에 보낸다. 채널이 준비되기 전이면 준비된 뒤(on_disp_caps)에 보낸다. */
static void send_layout(rdpb_session* s)
{
	if (!s->disp || !s->disp_ready || s->want_w <= 0 || s->want_h <= 0)
		return;

	int32_t w = s->want_w & ~1; /* 너비는 짝수여야 함 */
	int32_t h = s->want_h;
	if (w < DISPLAY_CONTROL_MIN_MONITOR_WIDTH)
		w = DISPLAY_CONTROL_MIN_MONITOR_WIDTH;
	if (w > DISPLAY_CONTROL_MAX_MONITOR_WIDTH)
		w = DISPLAY_CONTROL_MAX_MONITOR_WIDTH;
	if (h < DISPLAY_CONTROL_MIN_MONITOR_HEIGHT)
		h = DISPLAY_CONTROL_MIN_MONITOR_HEIGHT;
	if (h > DISPLAY_CONTROL_MAX_MONITOR_HEIGHT)
		h = DISPLAY_CONTROL_MAX_MONITOR_HEIGHT;

	rdpGdi* gdi = s->context->gdi;
	if (gdi && gdi->width == w && gdi->height == h)
		return; /* 이미 그 크기 */

	DISPLAY_CONTROL_MONITOR_LAYOUT layout = { 0 };
	layout.Flags = DISPLAY_CONTROL_MONITOR_PRIMARY;
	layout.Width = (UINT32)w;
	layout.Height = (UINT32)h;
	layout.DesktopScaleFactor = 100;
	layout.DeviceScaleFactor = 100;
	(void)s->disp->SendMonitorLayout(s->disp, 1, &layout);
}

static UINT on_disp_caps(DispClientContext* disp, UINT32 max_monitors, UINT32 factor_a,
                         UINT32 factor_b)
{
	rdpb_session* s = disp->custom;
	WINPR_UNUSED(max_monitors);
	WINPR_UNUSED(factor_a);
	WINPR_UNUSED(factor_b);
	s->disp_ready = TRUE;
	send_layout(s);
	return CHANNEL_RC_OK;
}

static void run_cmd(rdpb_session* s, const rdpb_cmd* cmd)
{
	rdpContext* context = s->context;
	rdpInput* input = context->input;

	switch (cmd->type)
	{
		case RDPB_CMD_KEY:
			(void)freerdp_input_send_keyboard_event_ex(
			    input, cmd->c != 0, FALSE, (UINT32)(cmd->a & 0xFF) | (cmd->b ? KBDEXT : 0));
			break;
		case RDPB_CMD_UNICODE:
			(void)freerdp_input_send_unicode_keyboard_event(
			    input, cmd->b ? 0 : KBD_FLAGS_RELEASE, (UINT16)cmd->a);
			break;
		case RDPB_CMD_MOUSE:
			s->mouse_x = cmd->b;
			s->mouse_y = cmd->c;
			(void)freerdp_input_send_mouse_event(input, (UINT16)cmd->a, clamp_u16(cmd->b),
			                                     clamp_u16(cmd->c));
			break;
		case RDPB_CMD_WHEEL:
		{
			/* 회전량은 9비트 2의 보수 (부호 비트 = PTR_FLAGS_WHEEL_NEGATIVE) */
			int32_t delta = cmd->a;
			if (delta > 0xFF)
				delta = 0xFF;
			if (delta < -0xFF)
				delta = -0xFF;
			if (delta == 0)
				break;
			UINT16 flags = cmd->b ? PTR_FLAGS_HWHEEL : PTR_FLAGS_WHEEL;
			if (delta < 0)
				flags |= PTR_FLAGS_WHEEL_NEGATIVE | (UINT16)((0x100 + delta) & 0xFF);
			else
				flags |= (UINT16)delta;
			(void)freerdp_input_send_mouse_event(input, flags, clamp_u16(s->mouse_x),
			                                     clamp_u16(s->mouse_y));
			break;
		}
		case RDPB_CMD_RESIZE:
			s->want_w = cmd->a;
			s->want_h = cmd->b;
			send_layout(s);
			break;
		case RDPB_CMD_CLIPBOARD:
			rdpb_clipboard_announce(s);
			break;
		case RDPB_CMD_REDRAW:
			if (context->gdi)
				present(s, 0, 0, context->gdi->width, context->gdi->height);
			break;
	}
}

/* 큐를 비운다. 접속이 끝나기 전에 들어온 명령은 버린다. */
static void drain_cmds(rdpb_session* s)
{
	EnterCriticalSection(&s->lock);
	rdpb_cmd* cmds = s->cmds;
	const size_t count = s->cmd_count;
	s->cmds = NULL;
	s->cmd_count = s->cmd_cap = 0;
	(void)ResetEvent(s->cmd_event);
	LeaveCriticalSection(&s->lock);

	if (s->active)
	{
		for (size_t i = 0; i < count; i++)
			run_cmd(s, &cmds[i]);
	}
	free(cmds);
}

/* ------------------------------------------------------------------ 세션 스레드 */

static void emit_state(rdpb_session* s, rdpb_state state, UINT32 error)
{
	rdpb_emit(s, RDPB_EV_STATE, state, (int32_t)error, 0,
	          error ? freerdp_get_last_error_name(error) : NULL);
}

static DWORD WINAPI session_thread(LPVOID arg)
{
	rdpb_session* s = arg;
	rdpContext* context = s->context;
	freerdp* instance = context->instance;
	UINT32 error = 0;

	emit_state(s, RDPB_STATE_CONNECTING, 0);

	if (WaitForSingleObject(s->stop_event, 0) == WAIT_OBJECT_0 || !freerdp_connect(instance))
	{
		error = freerdp_get_last_error(context);
		emit_state(s, RDPB_STATE_DISCONNECTED, error);
		return 0;
	}

	emit_state(s, RDPB_STATE_CONNECTED, 0);

	while (!freerdp_shall_disconnect_context(context))
	{
		HANDLE handles[MAXIMUM_WAIT_OBJECTS] = { s->stop_event, s->cmd_event };
		const DWORD count =
		    freerdp_get_event_handles(context, &handles[2], MAXIMUM_WAIT_OBJECTS - 2);
		if (count == 0)
			break;
		if (WaitForMultipleObjects(count + 2, handles, FALSE, INFINITE) == WAIT_FAILED)
			break;
		if (WaitForSingleObject(s->stop_event, 0) == WAIT_OBJECT_0)
			break;
		drain_cmds(s);
		if (!freerdp_check_event_handles(context))
			break;
	}

	/* 사용자가 끊은 경우(rdpb_disconnect)는 오류가 아니다 */
	if (WaitForSingleObject(s->stop_event, 0) != WAIT_OBJECT_0)
		error = freerdp_get_last_error(context);
	(void)freerdp_disconnect(instance);
	emit_state(s, RDPB_STATE_DISCONNECTED, error);
	return 0;
}

/* ------------------------------------------------------------------ 공개 API */

static BOOL apply_config(rdpSettings* st, const rdpb_config* cfg)
{
#define SET_BOOL(key, value)                     \
	if (!freerdp_settings_set_bool(st, key, value)) \
		return FALSE
#define SET_U32(key, value)                        \
	if (!freerdp_settings_set_uint32(st, key, value)) \
		return FALSE
#define SET_STR(key, value)                        \
	if (!freerdp_settings_set_string(st, key, value)) \
		return FALSE

	SET_STR(FreeRDP_ServerHostname, cfg->host);
	SET_U32(FreeRDP_ServerPort, cfg->port > 0 ? (UINT32)cfg->port : 3389);
	if (cfg->username)
		SET_STR(FreeRDP_Username, cfg->username);
	if (cfg->domain)
		SET_STR(FreeRDP_Domain, cfg->domain);
	if (cfg->config_dir)
		SET_STR(FreeRDP_ConfigPath, cfg->config_dir);

	SET_U32(FreeRDP_DesktopWidth, cfg->width > 0 ? (UINT32)cfg->width : 1280);
	SET_U32(FreeRDP_DesktopHeight, cfg->height > 0 ? (UINT32)cfg->height : 720);
	SET_U32(FreeRDP_ColorDepth, 32);

	/* 화면: 그래픽 파이프라인(gnome-remote-desktop 필수) + RemoteFX. H.264는 빌드에서 꺼져 있음 */
	SET_BOOL(FreeRDP_SupportGraphicsPipeline, TRUE);
	SET_BOOL(FreeRDP_RemoteFxCodec, TRUE);
	SET_BOOL(FreeRDP_FastPathOutput, TRUE);
	SET_BOOL(FreeRDP_FrameMarkerCommandEnabled, TRUE);
	SET_BOOL(FreeRDP_GfxH264, FALSE);
	SET_BOOL(FreeRDP_GfxAVC444, FALSE);

	SET_BOOL(FreeRDP_SupportDisplayControl, cfg->dynamic_resolution != 0);
	SET_BOOL(FreeRDP_DynamicResolutionUpdate, cfg->dynamic_resolution != 0);
	SET_BOOL(FreeRDP_RedirectClipboard, cfg->clipboard != 0);
	SET_BOOL(FreeRDP_AudioPlayback, cfg->audio_playback != 0);
	SET_BOOL(FreeRDP_AudioCapture, cfg->microphone != 0);

	SET_BOOL(FreeRDP_IgnoreCertificate, cfg->cert_policy == RDPB_CERT_IGNORE);
	SET_BOOL(FreeRDP_CertificateCallbackPreferPEM, FALSE); /* 지문 문자열로 받는다 */
	SET_BOOL(FreeRDP_UseCommonStdioCallbacks, FALSE);      /* 터미널 질문 금지 */
	SET_BOOL(FreeRDP_AutoReconnectionEnabled, FALSE);
	return TRUE;

#undef SET_BOOL
#undef SET_U32
#undef SET_STR
}

rdpb_session* rdpb_create(const rdpb_config* cfg, rdpb_event_cb cb, void* user)
{
	if (!cfg || !cfg->host)
		return NULL;

	rdpb_session* s = calloc(1, sizeof(rdpb_session));
	if (!s)
		return NULL;
	s->cb = cb;
	s->user = user;
	s->cert_policy = cfg->cert_policy;
	InitializeCriticalSection(&s->lock);
	InitializeCriticalSection(&s->sink_lock);
	s->stop_event = CreateEvent(NULL, TRUE, FALSE, NULL);
	s->cmd_event = CreateEvent(NULL, TRUE, FALSE, NULL);
	s->answer_event = CreateEvent(NULL, TRUE, FALSE, NULL);

	RDP_CLIENT_ENTRY_POINTS entry = { 0 };
	entry.Version = RDP_CLIENT_INTERFACE_VERSION;
	entry.Size = sizeof(RDP_CLIENT_ENTRY_POINTS_V1);
	entry.ContextSize = sizeof(rdpb_context);
	entry.ClientNew = client_new;

	if (s->stop_event && s->cmd_event && s->answer_event)
		s->context = freerdp_client_context_new(&entry);
	if (!s->context)
	{
		rdpb_destroy(s);
		return NULL;
	}
	((rdpb_context*)s->context)->session = s;

	if (!apply_config(s->context->settings, cfg))
	{
		rdpb_destroy(s);
		return NULL;
	}
	return s;
}

int32_t rdpb_attach_sink(rdpb_session* s, const rdpb_frame_sink* sink)
{
	if (!s)
		return -1;
	EnterCriticalSection(&s->sink_lock);
	s->sink = sink;
	LeaveCriticalSection(&s->sink_lock);
	if (sink)
		rdpb_request_redraw(s);
	return 0;
}

int32_t rdpb_connect(rdpb_session* s)
{
	if (!s || s->thread)
		return -1;
	if (freerdp_client_start(s->context) != 0)
		return -1;
	s->thread = CreateThread(NULL, 0, session_thread, s, 0, NULL);
	return s->thread ? 0 : -1;
}

void rdpb_disconnect(rdpb_session* s)
{
	if (!s)
		return;
	(void)SetEvent(s->stop_event);
	if (s->context)
		(void)freerdp_abort_connect_context(s->context);
}

void rdpb_destroy(rdpb_session* s)
{
	if (!s)
		return;
	rdpb_disconnect(s);
	if (s->thread)
	{
		(void)WaitForSingleObject(s->thread, INFINITE);
		(void)CloseHandle(s->thread);
		(void)freerdp_client_stop(s->context);
	}
	if (s->context)
		freerdp_client_context_free(s->context);
	if (s->stop_event)
		(void)CloseHandle(s->stop_event);
	if (s->cmd_event)
		(void)CloseHandle(s->cmd_event);
	if (s->answer_event)
		(void)CloseHandle(s->answer_event);
	DeleteCriticalSection(&s->lock);
	DeleteCriticalSection(&s->sink_lock);
	free(s->cmds);
	free(s->answer_password);
	free(s->clip_text);
	free(s);
}

void rdpb_send_key(rdpb_session* s, uint16_t scancode, int32_t extended, int32_t down)
{
	push_cmd(s, RDPB_CMD_KEY, scancode, extended, down);
}

void rdpb_send_unicode(rdpb_session* s, uint16_t codeunit, int32_t down)
{
	push_cmd(s, RDPB_CMD_UNICODE, codeunit, down, 0);
}

void rdpb_send_mouse(rdpb_session* s, uint16_t flags, int32_t x, int32_t y)
{
	push_cmd(s, RDPB_CMD_MOUSE, flags, x, y);
}

void rdpb_send_wheel(rdpb_session* s, int32_t delta, int32_t horizontal)
{
	push_cmd(s, RDPB_CMD_WHEEL, delta, horizontal, 0);
}

void rdpb_resize(rdpb_session* s, int32_t width, int32_t height)
{
	push_cmd(s, RDPB_CMD_RESIZE, width, height, 0);
}

void rdpb_clipboard_set_text(rdpb_session* s, const char* utf8)
{
	if (!s)
		return;
	char* copy = utf8 ? _strdup(utf8) : NULL;
	EnterCriticalSection(&s->lock);
	free(s->clip_text);
	s->clip_text = copy;
	LeaveCriticalSection(&s->lock);
	push_cmd(s, RDPB_CMD_CLIPBOARD, 0, 0, 0);
}

void rdpb_request_redraw(rdpb_session* s)
{
	push_cmd(s, RDPB_CMD_REDRAW, 0, 0, 0);
}
