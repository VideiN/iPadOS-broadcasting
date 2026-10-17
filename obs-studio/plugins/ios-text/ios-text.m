/* iOS port: text source drawn with UIKit/CoreText.
 *
 * text-freetype2 needs font files, and iOS apps cannot read the system font files. UIKit draws with the system fonts
 * directly (Korean included, with the system's font fallback). The text is drawn once per settings change into a
 * premultiplied RGBA bitmap that becomes the source's texture, drawn like the image source. */

@import UIKit;

#include <obs-module.h>
#include <graphics/graphics.h>

#include <math.h>

OBS_DECLARE_MODULE()
OBS_MODULE_USE_DEFAULT_LOCALE("ios-text", "en-US")

#define LOG(level, format, ...) blog(level, "[ios-text] " format, ##__VA_ARGS__)

/* Largest texture side the text may take (Metal on M-series iPads allows 16384) */
#define MAX_TEXTURE_SIZE 8192

struct ios_text {
    obs_source_t *source;
    gs_texture_t *texture;
    uint32_t width;
    uint32_t height;
};

static const char *ios_text_get_name(void *unused)
{
    UNUSED_PARAMETER(unused);
    return obs_module_text("Text");
}

/* OBS colors are 0xAABBGGRR */
static UIColor *color_from_obs(long long value)
{
    const uint32_t color = (uint32_t) value;
    return [UIColor colorWithRed:(color & 0xFF) / 255.0
                           green:((color >> 8) & 0xFF) / 255.0
                            blue:((color >> 16) & 0xFF) / 255.0
                           alpha:((color >> 24) & 0xFF) / 255.0];
}

static UIFont *make_font(NSString *family, CGFloat size, bool bold, bool italic)
{
    UIFont *font = nil;

    if (family.length > 0) {
        UIFontDescriptor *descriptor =
            [UIFontDescriptor fontDescriptorWithFontAttributes:@{UIFontDescriptorFamilyAttribute: family}];
        font = [UIFont fontWithDescriptor:descriptor size:size];
    }
    if (!font) {
        font = [UIFont systemFontOfSize:size];
    }

    UIFontDescriptorSymbolicTraits traits = 0;
    if (bold) {
        traits |= UIFontDescriptorTraitBold;
    }
    if (italic) {
        traits |= UIFontDescriptorTraitItalic;
    }
    if (traits) {
        UIFontDescriptor *styled = [font.fontDescriptor fontDescriptorWithSymbolicTraits:traits];
        if (styled) {
            font = [UIFont fontWithDescriptor:styled size:size];
        }
    }

    return font;
}

static void ios_text_update(void *data, obs_data_t *settings)
{
    struct ios_text *context = data;

    @autoreleasepool {
        NSString *text = @(obs_data_get_string(settings, "text"));
        NSString *family = @(obs_data_get_string(settings, "font"));
        const CGFloat size = (CGFloat) obs_data_get_int(settings, "size");
        const bool outline = obs_data_get_bool(settings, "outline");
        const CGFloat outlineSize = outline ? (CGFloat) obs_data_get_int(settings, "outline_size") : 0;

        NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
        switch (obs_data_get_int(settings, "align")) {
            case 1:
                paragraph.alignment = NSTextAlignmentCenter;
                break;
            case 2:
                paragraph.alignment = NSTextAlignmentRight;
                break;
            default:
                paragraph.alignment = NSTextAlignmentLeft;
                break;
        }

        UIFont *font = make_font(family, MAX(size, 1), obs_data_get_bool(settings, "bold"),
                                 obs_data_get_bool(settings, "italic"));
        NSMutableDictionary *attributes = [@{
            NSFontAttributeName: font,
            NSForegroundColorAttributeName: color_from_obs(obs_data_get_int(settings, "color")),
            NSParagraphStyleAttributeName: paragraph,
        } mutableCopy];

        if (outline && outlineSize > 0) {
            // A negative stroke width fills and strokes. The stroke is centred on the glyph outline and its width is
            // a percentage of the font size, so twice the outline size is needed for it to show outside the glyph.
            attributes[NSStrokeWidthAttributeName] = @(-200.0 * outlineSize / MAX(size, 1));
            attributes[NSStrokeColorAttributeName] = color_from_obs(obs_data_get_int(settings, "outline_color"));
        }

        NSAttributedString *string = [[NSAttributedString alloc] initWithString:text attributes:attributes];
        const CGRect bounds = [string boundingRectWithSize:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)
                                                   options:NSStringDrawingUsesLineFragmentOrigin
                                                   context:nil];

        const CGFloat padding = ceil(outlineSize) + 2;
        uint32_t width = (uint32_t) MIN(ceil(bounds.size.width) + 2 * padding, MAX_TEXTURE_SIZE);
        uint32_t height = (uint32_t) MIN(ceil(bounds.size.height) + 2 * padding, MAX_TEXTURE_SIZE);
        if (text.length == 0) {
            width = 0;
            height = 0;
        }

        uint8_t *pixels = width && height ? bzalloc((size_t) width * height * 4) : NULL;
        if (pixels) {
            CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
            CGContextRef bitmap =
                CGBitmapContextCreate(pixels, width, height, 8, (size_t) width * 4, colorSpace,
                                      (CGBitmapInfo) kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
            CGColorSpaceRelease(colorSpace);

            if (bitmap) {
                // UIKit draws with the origin at the top left; the first row in memory is the top of the image
                CGContextTranslateCTM(bitmap, 0, height);
                CGContextScaleCTM(bitmap, 1, -1);

                UIGraphicsPushContext(bitmap);
                [string drawWithRect:CGRectMake(padding, padding, width - 2 * padding, height - 2 * padding)
                             options:NSStringDrawingUsesLineFragmentOrigin
                             context:nil];
                UIGraphicsPopContext();
                CGContextRelease(bitmap);
            }
        }

        obs_enter_graphics();
        gs_texture_destroy(context->texture);
        context->texture = pixels ? gs_texture_create(width, height, GS_RGBA, 1, (const uint8_t **) &pixels, 0)
                                  : NULL;
        obs_leave_graphics();
        bfree(pixels);

        context->width = context->texture ? width : 0;
        context->height = context->texture ? height : 0;
    }
}

static void *ios_text_create(obs_data_t *settings, obs_source_t *source)
{
    struct ios_text *context = bzalloc(sizeof(struct ios_text));
    context->source = source;
    ios_text_update(context, settings);
    return context;
}

static void ios_text_destroy(void *data)
{
    struct ios_text *context = data;

    obs_enter_graphics();
    gs_texture_destroy(context->texture);
    obs_leave_graphics();

    bfree(context);
}

static uint32_t ios_text_get_width(void *data)
{
    return ((struct ios_text *) data)->width;
}

static uint32_t ios_text_get_height(void *data)
{
    return ((struct ios_text *) data)->height;
}

static void ios_text_render(void *data, gs_effect_t *effect)
{
    struct ios_text *context = data;
    if (!context->texture) {
        return;
    }

    const bool previous = gs_framebuffer_srgb_enabled();
    gs_enable_framebuffer_srgb(true);

    // The bitmap has premultiplied alpha
    gs_blend_state_push();
    gs_blend_function(GS_BLEND_ONE, GS_BLEND_INVSRCALPHA);

    gs_eparam_t *const param = gs_effect_get_param_by_name(effect, "image");
    gs_effect_set_texture_srgb(param, context->texture);
    gs_draw_sprite(context->texture, 0, context->width, context->height);

    gs_blend_state_pop();
    gs_enable_framebuffer_srgb(previous);
}

static void ios_text_get_defaults(obs_data_t *settings)
{
    obs_data_set_default_string(settings, "text", obs_module_text("DefaultText"));
    obs_data_set_default_string(settings, "font", "");
    obs_data_set_default_int(settings, "size", 96);
    obs_data_set_default_int(settings, "color", 0xFFFFFFFF);
    obs_data_set_default_int(settings, "align", 0);
    obs_data_set_default_int(settings, "outline_size", 4);
    obs_data_set_default_int(settings, "outline_color", 0xFF000000);
}

static obs_properties_t *ios_text_get_properties(void *data)
{
    UNUSED_PARAMETER(data);
    obs_properties_t *props = obs_properties_create();

    obs_properties_add_text(props, "text", obs_module_text("Text"), OBS_TEXT_MULTILINE);

    obs_property_t *fonts = obs_properties_add_list(props, "font", obs_module_text("Font"), OBS_COMBO_TYPE_LIST,
                                                    OBS_COMBO_FORMAT_STRING);
    obs_property_list_add_string(fonts, obs_module_text("Font.System"), "");
    @autoreleasepool {
        for (NSString *family in [UIFont.familyNames sortedArrayUsingSelector:@selector(localizedCompare:)]) {
            obs_property_list_add_string(fonts, family.UTF8String, family.UTF8String);
        }
    }

    obs_properties_add_int(props, "size", obs_module_text("Size"), 8, 1024, 1);
    obs_properties_add_bool(props, "bold", obs_module_text("Bold"));
    obs_properties_add_bool(props, "italic", obs_module_text("Italic"));
    obs_properties_add_color_alpha(props, "color", obs_module_text("Color"));

    obs_property_t *align = obs_properties_add_list(props, "align", obs_module_text("Align"), OBS_COMBO_TYPE_LIST,
                                                    OBS_COMBO_FORMAT_INT);
    obs_property_list_add_int(align, obs_module_text("Align.Left"), 0);
    obs_property_list_add_int(align, obs_module_text("Align.Center"), 1);
    obs_property_list_add_int(align, obs_module_text("Align.Right"), 2);

    obs_properties_add_bool(props, "outline", obs_module_text("Outline"));
    obs_properties_add_int(props, "outline_size", obs_module_text("Outline.Size"), 1, 50, 1);
    obs_properties_add_color_alpha(props, "outline_color", obs_module_text("Outline.Color"));

    return props;
}

static struct obs_source_info ios_text_info = {
    .id = "ios_text_source",
    .type = OBS_SOURCE_TYPE_INPUT,
    .output_flags = OBS_SOURCE_VIDEO | OBS_SOURCE_SRGB,
    .icon_type = OBS_ICON_TYPE_TEXT,
    .get_name = ios_text_get_name,
    .create = ios_text_create,
    .destroy = ios_text_destroy,
    .update = ios_text_update,
    .get_width = ios_text_get_width,
    .get_height = ios_text_get_height,
    .video_render = ios_text_render,
    .get_defaults = ios_text_get_defaults,
    .get_properties = ios_text_get_properties,
};

bool obs_module_load(void)
{
    obs_register_source(&ios_text_info);
    return true;
}
