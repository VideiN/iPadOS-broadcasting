/* iOS port: chat source.
 *
 * Shows a live chat in a box of fixed size. Each message is drawn once by WebKit with the user's CSS
 * (chat-renderer.m) and becomes a texture; new messages appear at the bottom and push the older ones up with a short
 * slide, all on the GPU. Messages come from the platform clients (later steps) or from the test generator.
 *
 * Threads: the controller (renderer, test timer) lives on the main thread. Rendered images go through the sink to
 * video_tick, which turns them into textures; video_render only draws. */

@import UIKit;

#include <obs-module.h>
#include <graphics/graphics.h>
#include <util/darray.h>
#include <util/platform.h>

#include <math.h>

#include "chat.h"

OBS_DECLARE_MODULE()
OBS_MODULE_USE_DEFAULT_LOCALE("ios-chat", "en-US")

#define MAX_ITEMS 200
#define MIN_BOX_SIZE 50
#define MAX_BOX_SIZE 4096
#define REPLAY_COUNT 30 /* messages drawn again when the CSS or the width changes */

static NSString *default_css = @"";

#pragma mark - Sink: rendered images on their way to the graphics thread

@interface ChatSink : NSObject
- (void)push:(NSArray<ChatImage *> *)images;
- (void)reset;
- (NSArray<ChatImage *> *)takeReset:(BOOL *)reset;
@end

@implementation ChatSink {
    NSMutableArray<ChatImage *> *_pending;
    BOOL _reset;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _pending = [NSMutableArray array];
    }
    return self;
}

- (void)push:(NSArray<ChatImage *> *)images
{
    @synchronized(self) {
        [_pending addObjectsFromArray:images];
        if (_pending.count > MAX_ITEMS) {
            [_pending removeObjectsInRange:NSMakeRange(0, _pending.count - MAX_ITEMS)];
        }
    }
}

- (void)reset
{
    @synchronized(self) {
        [_pending removeAllObjects];
        _reset = YES;
    }
}

- (NSArray<ChatImage *> *)takeReset:(BOOL *)reset
{
    @synchronized(self) {
        *reset = _reset;
        _reset = NO;
        if (_pending.count == 0) {
            return nil;
        }
        NSArray<ChatImage *> *images = [_pending copy];
        [_pending removeAllObjects];
        return images;
    }
}

@end

#pragma mark - Controller (main thread)

@interface ChatController : NSObject
- (instancetype)initWithSink:(ChatSink *)sink;
- (void)applyWidth:(uint32_t)width css:(NSString *)css platform:(NSString *)platform testInterval:(double)interval;
- (void)stop;
@end

@implementation ChatController {
    ChatSink *_sink;
    ChatRenderer *_renderer;
    ChatTestGenerator *_test;
    NSTimer *_testTimer;
    double _testInterval;
    NSString *_platform;
    uint32_t _width;
    NSString *_css;
    NSMutableArray<ChatMessage *> *_recent;
    BOOL _stopped;

    /* test round statistics (log and CI) */
    NSUInteger _rendered;
    NSUInteger _unsafe;
    NSUInteger _mismatches;
    double _renderMs;
    double _snapshotMs;
    NSUInteger _batches;
    NSUInteger _rounds;
}

- (instancetype)initWithSink:(ChatSink *)sink
{
    if ((self = [super init])) {
        _sink = sink;
        _recent = [NSMutableArray array];
        _platform = @"";
    }
    return self;
}

- (void)applyWidth:(uint32_t)width css:(NSString *)css platform:(NSString *)platform testInterval:(double)interval
{
    if (_stopped) {
        return;
    }

    if (!_renderer) {
        _renderer = [[ChatRenderer alloc] initWithWidth:width css:css];
        __weak ChatController *weakSelf = self;
        _renderer.rendered = ^(NSArray<ChatImage *> *images, struct chat_batch_stats stats) {
            [weakSelf rendered:images stats:stats];
        };
    } else if (width != _width || ![css isEqualToString:_css]) {
        /* Draw the recent messages again so a CSS change shows right away */
        [_renderer setWidth:width css:css];
        [_sink reset];
        for (ChatMessage *message in _recent) {
            [_renderer enqueue:message];
        }
    }
    _width = width;
    _css = [css copy];

    if (![platform isEqualToString:_platform] || interval != _testInterval) {
        _platform = [platform copy];
        _testInterval = interval;
        [_testTimer invalidate];
        _testTimer = nil;

        if ([platform isEqualToString:@"test"]) {
            _test = _test ?: [[ChatTestGenerator alloc] init];
            __weak ChatController *weakSelf = self;
            _testTimer = [NSTimer scheduledTimerWithTimeInterval:MAX(interval, 0.1)
                                                         repeats:YES
                                                           block:^(NSTimer *timer) {
                                                               (void) timer;
                                                               [weakSelf receive:[weakSelf nextTestMessage]];
                                                           }];
        }
    }
}

- (ChatMessage *)nextTestMessage
{
    return [_test next];
}

- (void)receive:(ChatMessage *)message
{
    if (_stopped || !message) {
        return;
    }
    [_recent addObject:message];
    if (_recent.count > REPLAY_COUNT) {
        [_recent removeObjectAtIndex:0];
    }
    [_renderer enqueue:message];
}

- (void)rendered:(NSArray<ChatImage *> *)images stats:(struct chat_batch_stats)stats
{
    if (_stopped) {
        return;
    }
    [_sink push:images];

    _rendered += stats.messages;
    _unsafe += stats.unsafe_elements;
    _mismatches += stats.image_mismatches;
    _renderMs += stats.render_ms;
    _snapshotMs += stats.snapshot_ms;
    _batches++;

    if (stats.unsafe_elements || stats.image_mismatches) {
        CHAT_LOG(LOG_WARNING, "batch of %lu: %lu unsafe element(s), %lu image mismatch(es)",
                 (unsigned long) stats.messages, (unsigned long) stats.unsafe_elements,
                 (unsigned long) stats.image_mismatches);
    }
    if (_batches <= 3) {
        CHAT_LOG(LOG_INFO, "batch of %lu: layout %.1f ms, snapshot %.1f ms (alpha %s)", (unsigned long) stats.messages,
                 stats.render_ms, stats.snapshot_ms, _renderer.alphaMode.UTF8String);
    }

    if ([_platform isEqualToString:@"test"] && _test && _rendered >= (_rounds + 1) * _test.roundLength) {
        _rounds++;
        CHAT_LOG(LOG_INFO,
                 "test round %lu done (rendered %lu, unsafe %lu, image mismatches %lu, alpha %s, "
                 "%.1f ms layout + %.1f ms snapshot per batch)",
                 (unsigned long) _rounds, (unsigned long) _rendered, (unsigned long) _unsafe,
                 (unsigned long) _mismatches, _renderer.alphaMode.UTF8String, _renderMs / _batches,
                 _snapshotMs / _batches);
    }
}

- (void)stop
{
    _stopped = YES;
    [_testTimer invalidate];
    _testTimer = nil;
    [_renderer stop];
    _renderer = nil;
}

@end

#pragma mark - Source

struct chat_item {
    gs_texture_t *texture;
    float cx; /* size on the canvas */
    float cy;
};

struct ios_chat {
    obs_source_t *source;
    void *sink;       /* ChatSink, retained */
    void *controller; /* ChatController, retained; stopped and released on the main thread */

    uint32_t width;
    uint32_t height;
    float slide_seconds;

    /* graphics thread only */
    DARRAY(struct chat_item) items; /* oldest first */
    float offset;                   /* how far the stack still sits below its place (slides to 0) */
    float offset_from;
    float elapsed;
};

static const char *ios_chat_get_name(void *unused)
{
    UNUSED_PARAMETER(unused);
    return obs_module_text("Chat");
}

static NSString *read_text_file(const char *path)
{
    if (!path || !*path) {
        return @"";
    }
    NSString *text = [NSString stringWithContentsOfFile:@(path) encoding:NSUTF8StringEncoding error:nil];
    return text ?: @"";
}

static void ios_chat_update(void *data, obs_data_t *settings)
{
    struct ios_chat *context = data;

    context->width = (uint32_t) MAX(MIN_BOX_SIZE, MIN(MAX_BOX_SIZE, obs_data_get_int(settings, "width")));
    context->height = (uint32_t) MAX(MIN_BOX_SIZE, MIN(MAX_BOX_SIZE, obs_data_get_int(settings, "height")));
    context->slide_seconds = (float) obs_data_get_int(settings, "slide_ms") / 1000.0f;

    @autoreleasepool {
        NSString *css = @(obs_data_get_string(settings, "css"));
        NSString *file = read_text_file(obs_data_get_string(settings, "css_file"));
        if (file.length > 0) {
            css = [css stringByAppendingFormat:@"\n%@", file];
        }
        NSString *platform = @(obs_data_get_string(settings, "platform"));
        const double interval = (double) obs_data_get_int(settings, "test_interval_ms") / 1000.0;
        const uint32_t width = context->width;

        ChatController *controller = (__bridge ChatController *) context->controller;
        dispatch_async(dispatch_get_main_queue(), ^{
            [controller applyWidth:width css:css platform:platform testInterval:interval];
        });
    }
}

static void *ios_chat_create(obs_data_t *settings, obs_source_t *source)
{
    struct ios_chat *context = bzalloc(sizeof(struct ios_chat));
    context->source = source;

    ChatSink *sink = [[ChatSink alloc] init];
    context->sink = (__bridge_retained void *) sink;
    context->controller = (__bridge_retained void *) [[ChatController alloc] initWithSink:sink];

    ios_chat_update(context, settings);
    return context;
}

static void destroy_items(struct ios_chat *context, size_t count)
{
    count = MIN(count, context->items.num);
    if (!count) {
        return;
    }
    obs_enter_graphics();
    for (size_t i = 0; i < count; i++) {
        gs_texture_destroy(context->items.array[i].texture);
    }
    obs_leave_graphics();
    da_erase_range(context->items, 0, count);
}

static void ios_chat_destroy(void *data)
{
    struct ios_chat *context = data;

    ChatController *controller = CFBridgingRelease(context->controller);
    dispatch_async(dispatch_get_main_queue(), ^{
        [controller stop];
    });
    CFBridgingRelease(context->sink);

    destroy_items(context, context->items.num);
    da_free(context->items);
    bfree(context);
}

static uint32_t ios_chat_get_width(void *data)
{
    return ((struct ios_chat *) data)->width;
}

static uint32_t ios_chat_get_height(void *data)
{
    return ((struct ios_chat *) data)->height;
}

static void ios_chat_tick(void *data, float seconds)
{
    struct ios_chat *context = data;

    @autoreleasepool {
        BOOL reset = NO;
        NSArray<ChatImage *> *images = [(__bridge ChatSink *) context->sink takeReset:&reset];

        if (reset) {
            destroy_items(context, context->items.num);
            context->offset = 0;
        }

        if (images.count) {
            float added = 0;
            obs_enter_graphics();
            for (ChatImage *image in images) {
                const uint8_t *pixels = image.pixels.bytes;
                gs_texture_t *texture = gs_texture_create(image.cx, image.cy, GS_RGBA, 1, &pixels, 0);
                if (!texture) {
                    continue;
                }
                struct chat_item item = {texture, image.displayCX, image.displayCY};
                da_push_back(context->items, &item);
                added += image.displayCY;
            }
            obs_leave_graphics();

            /* The stack starts that much lower and slides up into place */
            context->offset += added;
            context->offset_from = context->offset;
            context->elapsed = 0;
        }
    }

    if (context->offset > 0) {
        if (context->slide_seconds <= 0) {
            context->offset = 0;
        } else {
            context->elapsed += seconds;
            const float t = fminf(1.0f, context->elapsed / context->slide_seconds);
            const float eased = 1.0f - powf(1.0f - t, 3.0f);
            context->offset = context->offset_from * (1.0f - eased);
        }
    }

    /* Messages pushed out of the top are no longer needed */
    float bottom = (float) context->height + context->offset;
    size_t first_visible = 0;
    for (size_t i = context->items.num; i-- > 0;) {
        if (bottom <= 0) {
            first_visible = i + 1;
            break;
        }
        bottom -= context->items.array[i].cy;
    }
    if (context->items.num - first_visible > MAX_ITEMS) {
        first_visible = context->items.num - MAX_ITEMS;
    }
    destroy_items(context, first_visible);
}

static void ios_chat_render(void *data, gs_effect_t *effect)
{
    struct ios_chat *context = data;
    if (!context->items.num) {
        return;
    }

    const bool previous = gs_framebuffer_srgb_enabled();
    gs_enable_framebuffer_srgb(true);

    /* The images have premultiplied alpha */
    gs_blend_state_push();
    gs_blend_function(GS_BLEND_ONE, GS_BLEND_INVSRCALPHA);

    gs_eparam_t *const image = gs_effect_get_param_by_name(effect, "image");
    const float height = (float) context->height;
    float bottom = height + context->offset;

    /* Newest at the bottom; parts outside the box are cut off */
    for (size_t i = context->items.num; i-- > 0 && bottom > 0;) {
        const struct chat_item *item = &context->items.array[i];
        const float top = bottom - item->cy;

        const float clip_top = fmaxf(0, -top);
        const float clip_bottom = fmaxf(0, bottom - height);
        const float visible = item->cy - clip_top - clip_bottom;
        if (visible > 0 && item->cy > 0) {
            const uint32_t texture_cx = gs_texture_get_width(item->texture);
            const uint32_t texture_cy = gs_texture_get_height(item->texture);
            const float scale_x = item->cx / (float) texture_cx;
            const float scale_y = item->cy / (float) texture_cy;
            const long from = MIN((long) texture_cy, lroundf(clip_top / scale_y));
            const long rows = MIN((long) texture_cy - from, lroundf(visible / scale_y));

            if (rows > 0) {
                gs_effect_set_texture_srgb(image, item->texture);
                gs_matrix_push();
                gs_matrix_translate3f(0, top + clip_top, 0);
                gs_matrix_scale3f(scale_x, scale_y, 1);
                gs_draw_sprite_subregion(item->texture, 0, 0, (uint32_t) from, texture_cx, (uint32_t) rows);
                gs_matrix_pop();
            }
        }
        bottom = top;
    }

    gs_blend_state_pop();
    gs_enable_framebuffer_srgb(previous);
}

static bool reset_css_clicked(obs_properties_t *props, obs_property_t *property, void *data)
{
    UNUSED_PARAMETER(props);
    UNUSED_PARAMETER(property);
    struct ios_chat *context = data;

    obs_data_t *changes = obs_data_create();
    obs_data_set_string(changes, "css", default_css.UTF8String);
    obs_source_update(context->source, changes);
    obs_data_release(changes);
    return true;
}

static void ios_chat_get_defaults(obs_data_t *settings)
{
    obs_data_set_default_string(settings, "platform", "test");
    obs_data_set_default_int(settings, "width", 400);
    obs_data_set_default_int(settings, "height", 600);
    obs_data_set_default_string(settings, "css", default_css.UTF8String);
    obs_data_set_default_int(settings, "slide_ms", 250);
    obs_data_set_default_int(settings, "test_interval_ms", 1500);
}

static obs_properties_t *ios_chat_get_properties(void *data)
{
    UNUSED_PARAMETER(data);
    obs_properties_t *props = obs_properties_create();

    obs_property_t *platform = obs_properties_add_list(props, "platform", obs_module_text("Platform"),
                                                       OBS_COMBO_TYPE_LIST, OBS_COMBO_FORMAT_STRING);
    obs_property_list_add_string(platform, obs_module_text("Platform.Test"), "test");

    obs_properties_add_int(props, "width", obs_module_text("Width"), MIN_BOX_SIZE, MAX_BOX_SIZE, 1);
    obs_properties_add_int(props, "height", obs_module_text("Height"), MIN_BOX_SIZE, MAX_BOX_SIZE, 1);
    obs_property_t *slide = obs_properties_add_int(props, "slide_ms", obs_module_text("SlideTime"), 0, 2000, 10);
    obs_property_int_set_suffix(slide, " ms");

    obs_properties_add_text(props, "css", obs_module_text("CSS"), OBS_TEXT_MULTILINE);
    obs_properties_add_path(props, "css_file", obs_module_text("CSSFile"), OBS_PATH_FILE, "CSS (*.css)", NULL);
    obs_properties_add_button(props, "reset_css", obs_module_text("ResetCSS"), reset_css_clicked);

    obs_property_t *interval =
        obs_properties_add_int(props, "test_interval_ms", obs_module_text("TestInterval"), 100, 10000, 100);
    obs_property_int_set_suffix(interval, " ms");

    return props;
}

static struct obs_source_info ios_chat_info = {
    .id = "ios_chat_source",
    .type = OBS_SOURCE_TYPE_INPUT,
    .output_flags = OBS_SOURCE_VIDEO | OBS_SOURCE_SRGB,
    .icon_type = OBS_ICON_TYPE_TEXT,
    .get_name = ios_chat_get_name,
    .create = ios_chat_create,
    .destroy = ios_chat_destroy,
    .update = ios_chat_update,
    .get_width = ios_chat_get_width,
    .get_height = ios_chat_get_height,
    .video_tick = ios_chat_tick,
    .video_render = ios_chat_render,
    .get_defaults = ios_chat_get_defaults,
    .get_properties = ios_chat_get_properties,
};

static NSString *read_module_file(const char *name)
{
    char *path = obs_module_file(name);
    NSString *text = read_text_file(path);
    if (text.length == 0) {
        CHAT_LOG(LOG_ERROR, "missing data file %s", name);
    }
    bfree(path);
    return text;
}

bool obs_module_load(void)
{
    @autoreleasepool {
        chat_page_html = read_module_file("chat.html");
        chat_page_script = read_module_file("chat.js");
        default_css = read_module_file("default.css");
    }
    obs_register_source(&ios_chat_info);
    return true;
}
