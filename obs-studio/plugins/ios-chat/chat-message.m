/* iOS port: chat message model and the cleaning of untrusted chat data (see chat.h). */

#include <obs-module.h>

#include "chat.h"

#define MAX_TEXT_CHARACTERS 500
#define MAX_NAME_CHARACTERS 60
#define MAX_ALT_CHARACTERS 60
#define MAX_AMOUNT_CHARACTERS 30
#define MAX_COMBINING_MARKS 4
#define MAX_DATA_URL_LENGTH (64 * 1024)

/* Hosts the platforms serve emotes, emoji and badges from */
static NSSet<NSString *> *allowed_image_hosts(void)
{
    static NSSet<NSString *> *hosts;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        hosts = [NSSet setWithArray:@[
            @"static-cdn.jtvnw.net", /* Twitch emotes and badges */
            @"yt3.ggpht.com",        /* YouTube custom emoji, member badges */
            @"yt4.ggpht.com",
            @"www.gstatic.com", /* YouTube standard emoji */
            @"fonts.gstatic.com",
        ]];
    });
    return hosts;
}

BOOL chat_image_url_allowed(NSString *url)
{
    if (url.length == 0) {
        return NO;
    }

    if ([url hasPrefix:@"data:"]) {
        static NSRegularExpression *pattern;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            pattern = [NSRegularExpression regularExpressionWithPattern:@"^data:image/(png|gif|jpeg|webp);base64,[A-Za-z0-9+/]+={0,2}$"
                                                                options:0
                                                                  error:nil];
        });
        return url.length <= MAX_DATA_URL_LENGTH &&
               [pattern numberOfMatchesInString:url options:0 range:NSMakeRange(0, url.length)] == 1;
    }

    NSURLComponents *components = [NSURLComponents componentsWithString:url];
    return components && [components.scheme isEqualToString:@"https"] && components.user == nil &&
           components.password == nil && components.port == nil &&
           [allowed_image_hosts() containsObject:components.host.lowercaseString ?: @""];
}

/* One message is one paragraph: line breaks become spaces */
static BOOL is_line_break(UTF32Char c)
{
    return c == 0x0A || c == 0x0D || c == 0x0B || c == 0x0C || c == 0x85 || c == 0x2028 || c == 0x2029;
}

static BOOL is_removed_character(UTF32Char c)
{
    /* control characters */
    if (c < 0x20 || (c >= 0x7F && c < 0xA0)) {
        return YES;
    }
    /* direction embeddings, overrides and isolates: a name could reverse the text after it */
    if ((c >= 0x202A && c <= 0x202E) || (c >= 0x2066 && c <= 0x2069)) {
        return YES;
    }
    /* byte order mark, interlinear annotation */
    return c == 0xFEFF || (c >= 0xFFF9 && c <= 0xFFFB);
}

NSString *chat_clean_text(NSString *text, NSUInteger maxCharacters)
{
    if (text.length == 0) {
        return @"";
    }

    NSCharacterSet *marks = NSCharacterSet.nonBaseCharacterSet;
    NSMutableString *result = [NSMutableString stringWithCapacity:MIN(text.length, maxCharacters * 2)];
    __block NSUInteger characters = 0;

    [text enumerateSubstringsInRange:NSMakeRange(0, text.length)
                             options:NSStringEnumerationByComposedCharacterSequences
                          usingBlock:^(NSString *character, NSRange range, NSRange enclosing, BOOL *stop) {
                              (void) range;
                              (void) enclosing;
                              if (characters >= maxCharacters) {
                                  *stop = YES;
                                  return;
                              }

                              NSUInteger keptMarks = 0;
                              NSMutableString *kept = [NSMutableString string];
                              for (NSUInteger i = 0; i < character.length;) {
                                  UTF32Char c = [character characterAtIndex:i];
                                  NSUInteger units = 1;
                                  if (CFStringIsSurrogateHighCharacter((UniChar) c) && i + 1 < character.length) {
                                      c = CFStringGetLongCharacterForSurrogatePair(
                                          (UniChar) c, [character characterAtIndex:i + 1]);
                                      units = 2;
                                  }

                                  if (is_line_break(c)) {
                                      [kept appendString:@" "];
                                  } else if (!is_removed_character(c)) {
                                      const BOOL mark = [marks longCharacterIsMember:c];
                                      if (!mark || keptMarks++ < MAX_COMBINING_MARKS) {
                                          [kept appendString:[character substringWithRange:NSMakeRange(i, units)]];
                                      }
                                  }
                                  i += units;
                              }

                              if (kept.length > 0) {
                                  [result appendString:kept];
                                  characters++;
                              }
                          }];

    return result;
}

static BOOL is_color(NSString *value)
{
    static NSRegularExpression *pattern;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        pattern = [NSRegularExpression regularExpressionWithPattern:@"^#[0-9A-Fa-f]{6}$" options:0 error:nil];
    });
    return value && [pattern numberOfMatchesInString:value options:0 range:NSMakeRange(0, value.length)] == 1;
}

@implementation ChatFragment

+ (instancetype)text:(NSString *)text
{
    ChatFragment *fragment = [[ChatFragment alloc] init];
    fragment.text = text ?: @"";
    return fragment;
}

+ (instancetype)image:(NSString *)url alt:(NSString *)alt
{
    ChatFragment *fragment = [ChatFragment text:alt];
    fragment.imageURL = url;
    return fragment;
}

@end

@implementation ChatMessage

- (instancetype)init
{
    if ((self = [super init])) {
        _messageID = @"";
        _platform = @"test";
        _author = @"";
        _badges = @[];
        _fragments = @[];
    }
    return self;
}

- (NSDictionary<NSString *, id> *)payloadWithImageCount:(NSUInteger *)imageCount
{
    NSUInteger images = 0;

    /* Class names come from fixed lists only, never from the message */
    NSMutableArray<NSString *> *classes = [NSMutableArray array];
    NSString *platform = [@[@"youtube", @"twitch", @"test"] containsObject:self.platform] ? self.platform : @"other";
    [classes addObject:[@"platform-" stringByAppendingString:platform]];
    if (self.roles & ChatRoleOwner) {
        [classes addObject:@"role-owner"];
    }
    if (self.roles & ChatRoleModerator) {
        [classes addObject:@"role-moderator"];
    }
    if (self.roles & ChatRoleMember) {
        [classes addObject:@"role-member"];
    }
    if (self.roles & ChatRoleVerified) {
        [classes addObject:@"role-verified"];
    }
    switch (self.kind) {
        case ChatKindSuperChat:
            [classes addObject:@"kind-superchat"];
            break;
        case ChatKindMembership:
            [classes addObject:@"kind-membership"];
            break;
        case ChatKindSystem:
            [classes addObject:@"kind-system"];
            break;
        default:
            [classes addObject:@"kind-text"];
            break;
    }

    NSMutableArray *badges = [NSMutableArray array];
    for (ChatFragment *badge in self.badges) {
        /* A badge that may not be shown is left out (its text would only clutter the name) */
        if (chat_image_url_allowed(badge.imageURL)) {
            [badges addObject:@{@"src": badge.imageURL, @"alt": chat_clean_text(badge.text, MAX_ALT_CHARACTERS)}];
            images++;
        }
    }

    NSMutableArray *parts = [NSMutableArray array];
    NSUInteger textLeft = MAX_TEXT_CHARACTERS;
    for (ChatFragment *fragment in self.fragments) {
        if (textLeft == 0) {
            break;
        }
        if (fragment.imageURL && chat_image_url_allowed(fragment.imageURL)) {
            [parts addObject:@{@"src": fragment.imageURL, @"alt": chat_clean_text(fragment.text, MAX_ALT_CHARACTERS)}];
            images++;
            textLeft--;
        } else {
            /* plain text, or an image that may not be loaded: shown as its text */
            NSString *text = chat_clean_text(fragment.text, textLeft);
            if (text.length > 0) {
                [parts addObject:@{@"text": text}];
                /* UTF-16 length is at least the character count, so this never lets more through */
                textLeft -= MIN(textLeft, text.length);
            }
        }
    }

    NSMutableDictionary *payload = [@{
        @"classes": classes,
        @"author": chat_clean_text(self.author, MAX_NAME_CHARACTERS),
        @"badges": badges,
        @"parts": parts,
    } mutableCopy];
    if (is_color(self.authorColor)) {
        payload[@"authorColor"] = self.authorColor;
    }
    if (self.amount.length > 0) {
        payload[@"amount"] = chat_clean_text(self.amount, MAX_AMOUNT_CHARACTERS);
    }

    if (imageCount) {
        *imageCount = images;
    }
    return payload;
}

@end
