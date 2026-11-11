/*
 * rdp_bridge — 클립보드(cliprdr) 텍스트.
 *   원격 → 로컬: 서버가 형식 목록을 보내면 유니코드 텍스트를 바로 요청해 RDPB_EV_CLIPBOARD_TEXT로 전달
 *   로컬 → 원격: rdpb_clipboard_set_text()로 받은 텍스트를 서버가 요청할 때 보냄
 * 모든 함수는 세션 스레드에서 실행됩니다.
 */
#include <stdlib.h>
#include <string.h>

#include <freerdp/channels/cliprdr.h>

#include <winpr/crt.h>
#include <winpr/string.h>
#include <winpr/user.h>

#include "rdp_bridge_internal.h"

static UINT send_format_list(rdpb_session* s)
{
	CliprdrClientContext* cliprdr = s->cliprdr;
	if (!cliprdr || !s->clip_ready)
		return CHANNEL_RC_OK;

	EnterCriticalSection(&s->lock);
	const BOOL has_text = s->clip_text != NULL;
	LeaveCriticalSection(&s->lock);

	CLIPRDR_FORMAT format = { CF_UNICODETEXT, NULL };
	CLIPRDR_FORMAT_LIST list = { 0 };
	list.common.msgType = CB_FORMAT_LIST;
	list.numFormats = has_text ? 1 : 0;
	list.formats = has_text ? &format : NULL;
	return cliprdr->ClientFormatList(cliprdr, &list);
}

static UINT on_monitor_ready(CliprdrClientContext* cliprdr, const CLIPRDR_MONITOR_READY* ready)
{
	rdpb_session* s = cliprdr->custom;
	WINPR_UNUSED(ready);

	CLIPRDR_GENERAL_CAPABILITY_SET general = { 0 };
	general.capabilitySetType = CB_CAPSTYPE_GENERAL;
	general.capabilitySetLength = CB_CAPSTYPE_GENERAL_LEN;
	general.version = CB_CAPS_VERSION_2;
	general.generalFlags = CB_USE_LONG_FORMAT_NAMES;

	CLIPRDR_CAPABILITIES caps = { 0 };
	caps.cCapabilitiesSets = 1;
	caps.capabilitySets = (CLIPRDR_CAPABILITY_SET*)&general;

	const UINT rc = cliprdr->ClientCapabilities(cliprdr, &caps);
	if (rc != CHANNEL_RC_OK)
		return rc;
	s->clip_ready = TRUE;
	return send_format_list(s);
}

static UINT on_server_capabilities(CliprdrClientContext* cliprdr, const CLIPRDR_CAPABILITIES* caps)
{
	WINPR_UNUSED(cliprdr);
	WINPR_UNUSED(caps);
	return CHANNEL_RC_OK;
}

static UINT on_server_format_list(CliprdrClientContext* cliprdr, const CLIPRDR_FORMAT_LIST* list)
{
	CLIPRDR_FORMAT_LIST_RESPONSE response = { 0 };
	response.common.msgType = CB_FORMAT_LIST_RESPONSE;
	response.common.msgFlags = CB_RESPONSE_OK;
	const UINT rc = cliprdr->ClientFormatListResponse(cliprdr, &response);
	if (rc != CHANNEL_RC_OK)
		return rc;

	for (UINT32 i = 0; i < list->numFormats; i++)
	{
		if (list->formats[i].formatId == CF_UNICODETEXT)
		{
			CLIPRDR_FORMAT_DATA_REQUEST request = { 0 };
			request.common.msgType = CB_FORMAT_DATA_REQUEST;
			request.requestedFormatId = CF_UNICODETEXT;
			return cliprdr->ClientFormatDataRequest(cliprdr, &request);
		}
	}
	return CHANNEL_RC_OK;
}

static UINT on_server_format_list_response(CliprdrClientContext* cliprdr,
                                           const CLIPRDR_FORMAT_LIST_RESPONSE* response)
{
	WINPR_UNUSED(cliprdr);
	WINPR_UNUSED(response);
	return CHANNEL_RC_OK;
}

/* 서버가 로컬 클립보드 내용을 요청함 */
static UINT on_server_format_data_request(CliprdrClientContext* cliprdr,
                                          const CLIPRDR_FORMAT_DATA_REQUEST* request)
{
	rdpb_session* s = cliprdr->custom;
	CLIPRDR_FORMAT_DATA_RESPONSE response = { 0 };
	response.common.msgType = CB_FORMAT_DATA_RESPONSE;
	response.common.msgFlags = CB_RESPONSE_FAIL;

	WCHAR* wide = NULL;
	if (request->requestedFormatId == CF_UNICODETEXT)
	{
		size_t chars = 0;
		EnterCriticalSection(&s->lock);
		if (s->clip_text)
			wide = ConvertUtf8ToWCharAlloc(s->clip_text, &chars);
		LeaveCriticalSection(&s->lock);
		if (wide)
		{
			response.common.msgFlags = CB_RESPONSE_OK;
			response.common.dataLen = (UINT32)((chars + 1) * sizeof(WCHAR)); /* 끝의 0 포함 */
			response.requestedFormatData = (const BYTE*)wide;
		}
	}
	const UINT rc = cliprdr->ClientFormatDataResponse(cliprdr, &response);
	free(wide);
	return rc;
}

/* 요청했던 원격 클립보드 텍스트가 도착함 */
static UINT on_server_format_data_response(CliprdrClientContext* cliprdr,
                                           const CLIPRDR_FORMAT_DATA_RESPONSE* response)
{
	rdpb_session* s = cliprdr->custom;
	if (response->common.msgFlags != CB_RESPONSE_OK || !response->requestedFormatData)
		return CHANNEL_RC_OK;

	const WCHAR* wide = (const WCHAR*)response->requestedFormatData;
	size_t chars = response->common.dataLen / sizeof(WCHAR);
	while (chars > 0 && wide[chars - 1] == 0) /* 끝의 0 제거 */
		chars--;

	char* utf8 = ConvertWCharNToUtf8Alloc(wide, chars, NULL);
	if (utf8)
		rdpb_emit(s, RDPB_EV_CLIPBOARD_TEXT, 0, 0, 0, utf8);
	free(utf8);
	return CHANNEL_RC_OK;
}

void rdpb_clipboard_attach(rdpb_session* s, CliprdrClientContext* cliprdr)
{
	s->cliprdr = cliprdr;
	cliprdr->custom = s;
	cliprdr->MonitorReady = on_monitor_ready;
	cliprdr->ServerCapabilities = on_server_capabilities;
	cliprdr->ServerFormatList = on_server_format_list;
	cliprdr->ServerFormatListResponse = on_server_format_list_response;
	cliprdr->ServerFormatDataRequest = on_server_format_data_request;
	cliprdr->ServerFormatDataResponse = on_server_format_data_response;
}

void rdpb_clipboard_detach(rdpb_session* s)
{
	if (s->cliprdr)
		s->cliprdr->custom = NULL;
	s->cliprdr = NULL;
	s->clip_ready = FALSE;
}

void rdpb_clipboard_announce(rdpb_session* s)
{
	(void)send_format_list(s);
}
