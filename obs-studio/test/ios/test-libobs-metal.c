/* iOS port: renders frames with the statically linked Metal renderer and
 * reads the result back.
 *
 * A red solid-color source is set as the output source, the libobs graphics
 * thread renders it through libobs-metal, and the center pixel of the main
 * texture is checked. Exits with 77 (skipped) when there is no Metal device. */

#include <obs.h>
#include <graphics/vec4.h>
#include <util/platform.h>

#include <stdio.h>

#define SKIPPED 77
#define TEXTURE_SIZE 64

extern void *libobs_metal_get_export(const char *symbol);
extern void *MTLCreateSystemDefaultDevice(void);

static int failures = 0;

#define CHECK(expr)                                                                   \
	do {                                                                          \
		if (expr) {                                                           \
			printf("ok   - %s\n", #expr);                                 \
		} else {                                                              \
			printf("FAIL - %s (%s:%d)\n", #expr, __FILE__, __LINE__);     \
			failures++;                                                   \
		}                                                                     \
	} while (0)

static const char *solid_get_name(void *type_data)
{
	UNUSED_PARAMETER(type_data);
	return "Solid test";
}

static void *solid_create(obs_data_t *settings, obs_source_t *source)
{
	UNUSED_PARAMETER(settings);
	return source;
}

static void solid_destroy(void *data)
{
	UNUSED_PARAMETER(data);
}

static uint32_t solid_get_size(void *data)
{
	UNUSED_PARAMETER(data);
	return TEXTURE_SIZE;
}

static void solid_render(void *data, gs_effect_t *effect)
{
	UNUSED_PARAMETER(data);
	UNUSED_PARAMETER(effect);

	gs_effect_t *solid = obs_get_base_effect(OBS_EFFECT_SOLID);
	gs_eparam_t *color = gs_effect_get_param_by_name(solid, "color");

	struct vec4 red;
	vec4_set(&red, 1.0f, 0.0f, 0.0f, 1.0f);
	gs_effect_set_vec4(color, &red);

	while (gs_effect_loop(solid, "Solid"))
		gs_draw_sprite(NULL, 0, TEXTURE_SIZE, TEXTURE_SIZE);
}

static struct obs_source_info solid_source = {
	.id = "solid_test",
	.type = OBS_SOURCE_TYPE_INPUT,
	.output_flags = OBS_SOURCE_VIDEO,
	.get_name = solid_get_name,
	.create = solid_create,
	.destroy = solid_destroy,
	.get_width = solid_get_size,
	.get_height = solid_get_size,
	.video_render = solid_render,
};

static void check_main_texture(void)
{
	obs_enter_graphics();

	gs_texture_t *texture = obs_get_main_texture();
	CHECK(texture != NULL);
	if (!texture) {
		obs_leave_graphics();
		return;
	}

	enum gs_color_format format = gs_texture_get_color_format(texture);
	uint32_t width = gs_texture_get_width(texture);
	uint32_t height = gs_texture_get_height(texture);
	printf("main texture: %ux%u, format %d\n", width, height, (int)format);

	gs_stagesurf_t *stage = gs_stagesurface_create(width, height, format);
	CHECK(stage != NULL);
	if (stage) {
		gs_stage_texture(stage, texture);

		uint8_t *pixels = NULL;
		uint32_t linesize = 0;
		bool mapped = gs_stagesurface_map(stage, &pixels, &linesize);
		CHECK(mapped);

		if (mapped) {
			const uint8_t *px = pixels + (height / 2) * linesize + (width / 2) * 4;
			printf("center pixel: %u %u %u %u\n", px[0], px[1], px[2], px[3]);

			if (format == GS_BGRA)
				CHECK(px[2] > 200 && px[1] < 50 && px[0] < 50);
			else
				CHECK(format == GS_RGBA && px[0] > 200 && px[1] < 50 && px[2] < 50);

			gs_stagesurface_unmap(stage);
		}

		gs_stagesurface_destroy(stage);
	}

	obs_leave_graphics();
}

int main(void)
{
	if (!MTLCreateSystemDefaultDevice()) {
		printf("SKIPPED: no Metal device available\n");
		return SKIPPED;
	}

	CHECK(libobs_metal_get_export("device_create") != NULL);
	CHECK(libobs_metal_get_export("gs_texture_destroy") != NULL);
	CHECK(libobs_metal_get_export("no_such_export") == NULL);
	gs_register_static_module("libobs-metal", libobs_metal_get_export);

	CHECK(obs_startup("en-US", NULL, NULL));
	obs_add_data_path(LIBOBS_DATA_DIR);

	struct obs_video_info ovi = {
		.graphics_module = "libobs-metal",
		.fps_num = 30,
		.fps_den = 1,
		.base_width = TEXTURE_SIZE,
		.base_height = TEXTURE_SIZE,
		.output_width = TEXTURE_SIZE,
		.output_height = TEXTURE_SIZE,
		.output_format = VIDEO_FORMAT_NV12,
		.adapter = 0,
		.gpu_conversion = true,
		.colorspace = VIDEO_CS_709,
		.range = VIDEO_RANGE_PARTIAL,
		.scale_type = OBS_SCALE_BICUBIC,
	};

	int ret = obs_reset_video(&ovi);
	CHECK(ret == OBS_VIDEO_SUCCESS);

	if (ret == OBS_VIDEO_SUCCESS) {
		obs_register_source(&solid_source);

		obs_source_t *source = obs_source_create("solid_test", "Solid", NULL, NULL);
		CHECK(source != NULL);
		obs_set_output_source(0, source);

		/* let the graphics thread render a few frames */
		os_sleep_ms(500);

		check_main_texture();

		obs_set_output_source(0, NULL);
		obs_source_release(source);
	}

	obs_shutdown();

	if (failures) {
		printf("FAILED: %d check(s)\n", failures);
		return 1;
	}

	printf("ALL TESTS PASSED\n");
	return 0;
}
