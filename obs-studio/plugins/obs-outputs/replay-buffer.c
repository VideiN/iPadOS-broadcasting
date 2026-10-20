/* iOS port: replay buffer.
 *
 * OBS's replay buffer (obs-ffmpeg) hands packets to the ffmpeg-mux helper process, and iOS apps cannot start
 * processes. This output keeps the last "max_time_sec" seconds of encoded packets in memory and, when its "save"
 * procedure is called, writes them to an MP4 file with the muxer of mp4_output on a separate thread.
 *
 * The buffer always starts at a video keyframe. Saved files start at time 0: packet timestamps are shifted by the
 * first keyframe's time (audio from before that keyframe is left out).
 *
 * Procedures: "void save()", "void get_last_replay(out string path)". Signal: "saved" (string path). */

#include <obs-module.h>
#include <util/buffered-file-serializer.h>
#include <util/darray.h>
#include <util/deque.h>
#include <util/dstr.h>
#include <util/platform.h>
#include <util/threading.h>

#include <inttypes.h>

#include "mp4-mux.h"

#define do_log(level, format, ...) \
	blog(level, "[replay buffer: '%s'] " format, obs_output_get_name(rb->output), ##__VA_ARGS__)
#define info(format, ...) do_log(LOG_INFO, format, ##__VA_ARGS__)
#define warn(format, ...) do_log(LOG_WARNING, format, ##__VA_ARGS__)

struct replay_buffer {
	obs_output_t *output;

	pthread_mutex_t mutex;
	struct deque packets; /* struct encoder_packet, each holding a reference */
	size_t bytes;
	int64_t max_time_usec;
	size_t max_bytes;
	struct dstr directory;
	struct dstr last_file;

	volatile bool active;
	volatile bool saving;
	bool save_thread_valid;
	pthread_t save_thread;
};

struct save_job {
	struct replay_buffer *rb;
	DARRAY(struct encoder_packet) packets;
	char *path;
};

static const char *replay_buffer_get_name(void *type)
{
	UNUSED_PARAMETER(type);
	return "Replay Buffer (iOS)";
}

static void pop_front_packet(struct replay_buffer *rb)
{
	struct encoder_packet packet;
	deque_pop_front(&rb->packets, &packet, sizeof(packet));
	rb->bytes -= packet.size;
	obs_encoder_packet_release(&packet);
}

static void free_packets(struct replay_buffer *rb)
{
	while (rb->packets.size)
		pop_front_packet(rb);
	deque_free(&rb->packets);
	rb->bytes = 0;
}

static inline struct encoder_packet *packet_at(struct replay_buffer *rb, size_t index)
{
	return deque_data(&rb->packets, index * sizeof(struct encoder_packet));
}

static inline size_t packet_count(struct replay_buffer *rb)
{
	return rb->packets.size / sizeof(struct encoder_packet);
}

/* Drops packets older than the buffer length (or over the size limit) and anything before the first video keyframe */
static void trim_packets(struct replay_buffer *rb)
{
	if (!rb->packets.size)
		return;

	const int64_t newest = packet_at(rb, packet_count(rb) - 1)->dts_usec;

	while (rb->packets.size) {
		struct encoder_packet *first = packet_at(rb, 0);
		const bool too_old = newest - first->dts_usec > rb->max_time_usec;
		const bool too_big = rb->max_bytes && rb->bytes > rb->max_bytes;
		const bool before_keyframe = first->type != OBS_ENCODER_VIDEO || !first->keyframe;

		if (!too_old && !too_big && !before_keyframe)
			break;

		/* Keep a lone keyframe at the start while it is all there is */
		if (!too_old && !too_big && packet_count(rb) == 1)
			break;

		pop_front_packet(rb);
	}
}

static void replay_buffer_data(void *data, struct encoder_packet *packet)
{
	struct replay_buffer *rb = data;

	if (!packet) {
		obs_output_signal_stop(rb->output, OBS_OUTPUT_ENCODE_ERROR);
		return;
	}

	struct encoder_packet copy;
	obs_encoder_packet_ref(&copy, packet);

	pthread_mutex_lock(&rb->mutex);
	deque_push_back(&rb->packets, &copy, sizeof(copy));
	rb->bytes += copy.size;
	trim_packets(rb);
	pthread_mutex_unlock(&rb->mutex);
}

/* Shifts a packet so that time "start_usec" becomes 0 in its own timebase */
static void shift_packet(struct encoder_packet *packet, int64_t start_usec, int64_t video_start_dts)
{
	/* Signed: with B-frames the first keyframe's time can be slightly negative */
	int64_t shift;
	if (packet->type == OBS_ENCODER_VIDEO) {
		shift = video_start_dts;
	} else {
		shift = start_usec * (int64_t)packet->timebase_den / (1000000LL * (int64_t)packet->timebase_num);
	}

	packet->pts -= shift;
	packet->dts -= shift;
	packet->dts_usec -= start_usec;
}

static void *save_thread(void *data)
{
	struct save_job *job = data;
	struct replay_buffer *rb = job->rb;
	const uint64_t started = os_gettime_ns();
	bool ok = false;

	os_set_thread_name("replay buffer save");

	struct encoder_packet *first = job->packets.num ? &job->packets.array[0] : NULL;
	if (!first || first->type != OBS_ENCODER_VIDEO || !first->keyframe) {
		warn("Nothing to save yet");
		goto done;
	}

	const int64_t start_usec = first->dts_usec;
	const int64_t video_start_dts = first->dts;
	const int64_t length_usec = job->packets.array[job->packets.num - 1].dts_usec - start_usec;

	struct serializer serializer;
	if (!buffered_file_serializer_init_defaults(&serializer, job->path)) {
		warn("Unable to open file '%s'", job->path);
		goto done;
	}

	struct mp4_mux *muxer = mp4_mux_create(rb->output, &serializer, 0, FLAVOR_MP4);
	for (size_t i = 0; i < job->packets.num; i++) {
		struct encoder_packet packet = job->packets.array[i];
		if (packet.dts_usec < start_usec)
			continue;

		shift_packet(&packet, start_usec, video_start_dts);
		mp4_mux_submit_packet(muxer, &packet);
	}

	mp4_mux_finalise(muxer);
	buffered_file_serializer_free(&serializer);
	mp4_mux_destroy(muxer);
	ok = true;

	info("Saved %.1f s (%zu packets) to '%s' in %" PRIu64 " ms", (double)length_usec / 1000000.0, job->packets.num,
	     job->path, (os_gettime_ns() - started) / 1000000);

done:
	for (size_t i = 0; i < job->packets.num; i++)
		obs_encoder_packet_release(&job->packets.array[i]);
	da_free(job->packets);

	if (ok) {
		pthread_mutex_lock(&rb->mutex);
		dstr_copy(&rb->last_file, job->path);
		pthread_mutex_unlock(&rb->mutex);

		calldata_t cd = {0};
		calldata_set_string(&cd, "path", job->path);
		signal_handler_signal(obs_output_get_signal_handler(rb->output), "saved", &cd);
		calldata_free(&cd);
	}

	bfree(job->path);
	bfree(job);
	os_atomic_set_bool(&rb->saving, false);
	return NULL;
}

static void join_save_thread(struct replay_buffer *rb)
{
	if (rb->save_thread_valid) {
		pthread_join(rb->save_thread, NULL);
		rb->save_thread_valid = false;
	}
}

static void replay_buffer_save(void *data, calldata_t *cd)
{
	UNUSED_PARAMETER(cd);
	struct replay_buffer *rb = data;

	if (!os_atomic_load_bool(&rb->active)) {
		warn("Not running, nothing to save");
		return;
	}
	if (os_atomic_set_bool(&rb->saving, true)) {
		warn("Still saving the previous replay");
		return;
	}

	join_save_thread(rb);

	struct save_job *job = bzalloc(sizeof(*job));
	job->rb = rb;

	pthread_mutex_lock(&rb->mutex);
	da_reserve(job->packets, packet_count(rb));
	for (size_t i = 0; i < packet_count(rb); i++) {
		struct encoder_packet copy;
		obs_encoder_packet_ref(&copy, packet_at(rb, i));
		da_push_back(job->packets, &copy);
	}

	char *filename = os_generate_formatted_filename("mp4", true, "Replay %CCYY-%MM-%DD %hh-%mm-%ss");
	struct dstr path = {0};
	dstr_copy_dstr(&path, &rb->directory);
	dstr_replace(&path, "\\", "/");
	if (path.len && dstr_end(&path) != '/')
		dstr_cat_ch(&path, '/');
	dstr_cat(&path, filename);
	bfree(filename);
	pthread_mutex_unlock(&rb->mutex);

	os_mkdirs(rb->directory.array);
	job->path = path.array;

	if (pthread_create(&rb->save_thread, NULL, save_thread, job) == 0) {
		rb->save_thread_valid = true;
	} else {
		warn("Failed to start the save thread");
		for (size_t i = 0; i < job->packets.num; i++)
			obs_encoder_packet_release(&job->packets.array[i]);
		da_free(job->packets);
		bfree(job->path);
		bfree(job);
		os_atomic_set_bool(&rb->saving, false);
	}
}

static void replay_buffer_get_last_replay(void *data, calldata_t *cd)
{
	struct replay_buffer *rb = data;
	pthread_mutex_lock(&rb->mutex);
	calldata_set_string(cd, "path", rb->last_file.array ? rb->last_file.array : "");
	pthread_mutex_unlock(&rb->mutex);
}

static void replay_buffer_update(void *data, obs_data_t *settings)
{
	struct replay_buffer *rb = data;

	pthread_mutex_lock(&rb->mutex);
	rb->max_time_usec = obs_data_get_int(settings, "max_time_sec") * 1000000LL;
	rb->max_bytes = (size_t)obs_data_get_int(settings, "max_size_mb") * 1024 * 1024;
	dstr_copy(&rb->directory, obs_data_get_string(settings, "directory"));
	pthread_mutex_unlock(&rb->mutex);
}

static void *replay_buffer_create(obs_data_t *settings, obs_output_t *output)
{
	struct replay_buffer *rb = bzalloc(sizeof(*rb));
	rb->output = output;
	pthread_mutex_init(&rb->mutex, NULL);
	replay_buffer_update(rb, settings);

	proc_handler_t *ph = obs_output_get_proc_handler(output);
	proc_handler_add(ph, "void save()", replay_buffer_save, rb);
	proc_handler_add(ph, "void get_last_replay(out string path)", replay_buffer_get_last_replay, rb);

	signal_handler_t *sh = obs_output_get_signal_handler(output);
	signal_handler_add(sh, "void saved(string path)");
	return rb;
}

static void replay_buffer_destroy(void *data)
{
	struct replay_buffer *rb = data;

	join_save_thread(rb);
	free_packets(rb);
	dstr_free(&rb->directory);
	dstr_free(&rb->last_file);
	pthread_mutex_destroy(&rb->mutex);
	bfree(rb);
}

static bool replay_buffer_start(void *data)
{
	struct replay_buffer *rb = data;

	if (!obs_output_can_begin_data_capture(rb->output, 0))
		return false;
	if (!obs_output_initialize_encoders(rb->output, 0))
		return false;

	obs_data_t *settings = obs_output_get_settings(rb->output);
	replay_buffer_update(rb, settings);
	obs_data_release(settings);

	if (rb->max_time_usec <= 0) {
		warn("Buffer length must be at least 1 second");
		return false;
	}

	os_atomic_set_bool(&rb->active, true);
	obs_output_begin_data_capture(rb->output, 0);

	info("Keeping the last %" PRId64 " s (up to %zu MB) for saving to '%s'", rb->max_time_usec / 1000000,
	     rb->max_bytes / (1024 * 1024), rb->directory.array ? rb->directory.array : "");
	return true;
}

static void replay_buffer_stop(void *data, uint64_t ts)
{
	UNUSED_PARAMETER(ts);
	struct replay_buffer *rb = data;

	os_atomic_set_bool(&rb->active, false);
	obs_output_end_data_capture(rb->output);

	pthread_mutex_lock(&rb->mutex);
	free_packets(rb);
	pthread_mutex_unlock(&rb->mutex);

	info("Stopped");
}

static void replay_buffer_defaults(obs_data_t *settings)
{
	obs_data_set_default_int(settings, "max_time_sec", 30);
	obs_data_set_default_int(settings, "max_size_mb", 2048);
}

static uint64_t replay_buffer_total_bytes(void *data)
{
	struct replay_buffer *rb = data;
	pthread_mutex_lock(&rb->mutex);
	const uint64_t bytes = rb->bytes;
	pthread_mutex_unlock(&rb->mutex);
	return bytes;
}

struct obs_output_info replay_buffer_output_info = {
	.id = "ios_replay_buffer",
	.flags = OBS_OUTPUT_AV | OBS_OUTPUT_ENCODED,
	.encoded_video_codecs = "h264;hevc",
	.encoded_audio_codecs = "aac",
	.get_name = replay_buffer_get_name,
	.create = replay_buffer_create,
	.destroy = replay_buffer_destroy,
	.update = replay_buffer_update,
	.start = replay_buffer_start,
	.stop = replay_buffer_stop,
	.encoded_packet = replay_buffer_data,
	.get_defaults = replay_buffer_defaults,
	.get_total_bytes = replay_buffer_total_bytes,
};
