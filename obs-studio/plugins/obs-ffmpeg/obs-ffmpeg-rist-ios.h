/* iOS port: librist is not built for iOS. Only SRT is supported by the mpegts output; RIST URLs fail with a message. */

#pragma once

#include <obs-module.h>
#include "obs-ffmpeg-url.h"

#define RIST_MAX_PAYLOAD_SIZE (10000 - 28)

typedef struct RISTContext {
	int unused;
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
	UNUSED_PARAMETER(h);
	return 0;
}

static int librist_write(URLContext *h, const uint8_t *buf, int size)
{
	UNUSED_PARAMETER(h);
	UNUSED_PARAMETER(buf);
	UNUSED_PARAMETER(size);
	return AVERROR(ENOSYS);
}
