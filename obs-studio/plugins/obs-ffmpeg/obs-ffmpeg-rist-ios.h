/* iOS port: librist is not built for iOS. Only SRT is supported by the mpegts output; RIST URLs fail with a message. */

#pragma once

#include <obs-module.h>
#include "obs-ffmpeg-url.h"

#define RIST_MAX_PAYLOAD_SIZE (10000 - 28)

/* Only the fields obs-ffmpeg-mpegts.c sets */
typedef struct RISTContext {
	char *secret;
	char *username;
	char *password;
} RISTContext;

static int librist_open(URLContext *h, const char *uri)
{
	UNUSED_PARAMETER(h);
	UNUSED_PARAMETER(uri);
	blog(LOG_ERROR, "[obs-ffmpeg mpegts muxer / librist]: RIST is not supported on iOS");
	return AVERROR(ENOSYS);
}

static int librist_close(URLContext *h)
{
	RISTContext *s = h ? h->priv_data : NULL;
	if (s) {
		bfree(s->secret);
		bfree(s->username);
		bfree(s->password);
		s->secret = s->username = s->password = NULL;
	}
	return 0;
}

static int librist_write(URLContext *h, const uint8_t *buf, int size)
{
	UNUSED_PARAMETER(h);
	UNUSED_PARAMETER(buf);
	UNUSED_PARAMETER(size);
	return AVERROR(ENOSYS);
}
