/* iOS port: obs-ffmpeg is reduced to the native mpegts output for SRT (obs-ffmpeg-mpegts.c). Encoders, the media
 * source and ffmpeg-mux need FFmpeg codecs or a helper process, which this port does not use (plan D6-D8). */

#include <obs-module.h>

OBS_DECLARE_MODULE()
OBS_MODULE_USE_DEFAULT_LOCALE("obs-ffmpeg", "en-US")

MODULE_EXPORT const char *obs_module_description(void)
{
	return "FFmpeg based mpegts output for SRT (iOS)";
}

extern struct obs_output_info ffmpeg_mpegts_muxer;

bool obs_module_load(void)
{
	obs_register_output(&ffmpeg_mpegts_muxer);
	return true;
}
