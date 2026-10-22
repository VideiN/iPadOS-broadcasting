/* iOS port: chat source, shared declarations.
 *
 * Chat messages come from viewers, so everything in them (names, text, image URLs, colours) is untrusted. They are
 * cleaned here (ChatMessage -payload) and the page builds its elements with DOM calls only (chat.js), never by
 * parsing HTML. See chat-renderer.m for the WebKit side. */

#pragma once

@import Foundation;
@import CoreGraphics;

#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

#define CHAT_LOG(level, format, ...) blog(level, "[ios-chat] " format, ##__VA_ARGS__)

typedef NS_OPTIONS(NSUInteger, ChatRoles) {
    ChatRoleOwner = 1 << 0,
    ChatRoleModerator = 1 << 1,
    ChatRoleMember = 1 << 2,
    ChatRoleVerified = 1 << 3,
};

typedef NS_ENUM(NSInteger, ChatKind) {
    ChatKindText,
    ChatKindSuperChat,
    ChatKindMembership,
    ChatKindSystem,
};

/* Text, or an image (emote, badge) with the text to show instead when the image is not allowed */
@interface ChatFragment : NSObject
@property (nonatomic, copy) NSString *text;
@property (nonatomic, copy, nullable) NSString *imageURL;
+ (instancetype)text:(NSString *)text;
+ (instancetype)image:(NSString *)url alt:(NSString *)alt;
@end

@interface ChatMessage : NSObject
@property (nonatomic, copy) NSString *messageID;
@property (nonatomic, copy) NSString *platform; /* "youtube", "test" */
@property (nonatomic, copy) NSString *author;
@property (nonatomic, copy, nullable) NSString *authorID;    /* the platform's channel / user id (for bans) */
@property (nonatomic, copy, nullable) NSString *authorColor; /* "#rrggbb" from the platform */
@property (nonatomic, copy, nullable) NSString *accentColor; /* "#rrggbb", e.g. the Super Chat tier colour */
@property (nonatomic) ChatRoles roles;
@property (nonatomic) ChatKind kind;
@property (nonatomic, copy, nullable) NSString *amount; /* Super Chat amount as the platform writes it */
@property (nonatomic, copy) NSArray<ChatFragment *> *badges;
@property (nonatomic, copy) NSArray<ChatFragment *> *fragments;
@property (nonatomic) double receivedAt; /* CFAbsoluteTime, for removals that arrive while it is being drawn */

/* The cleaned values the page gets: only fixed class names, checked colour and image URLs, length-limited text.
 * imageCount is set to the number of images the page should show. */
- (NSDictionary<NSString *, id> *)payloadWithImageCount:(NSUInteger *)imageCount;
@end

/* A message from the app's chat clients ("add" event of ios_chat_push, see ios-chat.m). Only takes values of the
 * expected types; the cleaning happens in -payloadWithImageCount: like for every other message. */
ChatMessage *_Nullable chat_message_from_json(NSDictionary *json);

/* Image URLs the page may load: https on the platforms' image hosts, or small inline data:image URLs */
BOOL chat_image_url_allowed(NSString *url);

/* Removes control and direction-override characters, keeps at most a few combining marks per character (stacked
 * "zalgo" text) and at most maxCharacters characters. */
NSString *chat_clean_text(NSString *text, NSUInteger maxCharacters);

/* One rendered message: premultiplied RGBA, first row at the top */
@interface ChatImage : NSObject
@property (nonatomic, strong) NSData *pixels;
@property (nonatomic) uint32_t cx;
@property (nonatomic) uint32_t cy;
@property (nonatomic) float displayCX; /* size on the canvas (CSS pixels) */
@property (nonatomic) float displayCY;
@property (nonatomic, copy) NSString *messageID;
@property (nonatomic, copy, nullable) NSString *authorID;
@property (nonatomic) double receivedAt;
@end

/* Batch statistics for the log and the CI checks */
struct chat_batch_stats {
    NSUInteger messages;
    NSUInteger unsafe_elements;  /* script, iframe, event handler attributes ... found in the batch (must be 0) */
    NSUInteger image_mismatches; /* messages whose image count differs from what -payload allowed */
    double render_ms;
    double snapshot_ms;
};

/* Page template and script from the module's data folder (read in obs_module_load) */
extern NSString *chat_page_html;
extern NSString *chat_page_script;

/* Draws messages with WebKit: HTML built from the payload + the user's CSS, one snapshot per batch, cut into one
 * image per message. Main thread only. */
@interface ChatRenderer : NSObject
@property (nonatomic, copy, nullable) void (^rendered)(NSArray<ChatImage *> *images, struct chat_batch_stats stats);
@property (nonatomic, readonly) NSString *alphaMode; /* "unknown", "preserved", "dual" */

- (instancetype)initWithWidth:(uint32_t)width css:(NSString *)css;
- (void)setWidth:(uint32_t)width css:(NSString *)css;
- (void)enqueue:(ChatMessage *)message;
/* Drops waiting messages that were deleted (by id, or everything from those authors) */
- (void)discardIDs:(NSSet<NSString *> *)ids authors:(NSSet<NSString *> *)authors;
- (void)stop;
@end

/* Fake messages for checking the look and the safety measures (and for CI). Main thread only. */
@interface ChatTestGenerator : NSObject
@property (nonatomic, readonly) NSUInteger roundLength;
- (ChatMessage *)next;
@end

NS_ASSUME_NONNULL_END
