/* iOS port: chat source, test messages.
 *
 * One round covers the look (Korean, emoji, long text, roles, Super Chat, emotes) and hostile input: markup in names
 * and text, script and foreign image URLs, a colour that tries to inject CSS, direction overrides and stacked
 * combining marks. The CI serves http://127.0.0.1:8099/ and checks that none of the "evil" URLs was requested. */

@import UIKit;

#include <obs-module.h>

#include "chat.h"

static NSString *data_url(UIColor *color, BOOL round)
{
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(32, 32)
                                                                               format:format];
    NSData *png = [renderer PNGDataWithActions:^(UIGraphicsImageRendererContext *context) {
        [color setFill];
        const CGRect rect = CGRectMake(2, 2, 28, 28);
        if (round) {
            CGContextFillEllipseInRect(context.CGContext, rect);
        } else {
            UIRectFill(rect);
        }
    }];
    return [@"data:image/png;base64," stringByAppendingString:[png base64EncodedStringWithOptions:0]];
}

static ChatMessage *message(NSString *author, NSArray<ChatFragment *> *fragments)
{
    ChatMessage *message = [[ChatMessage alloc] init];
    message.platform = @"test";
    message.author = author;
    message.fragments = fragments;
    return message;
}

@implementation ChatTestGenerator {
    NSArray<ChatMessage *> *_round;
    NSUInteger _next;
}

- (instancetype)init
{
    if ((self = [super init])) {
        NSString *emote = data_url(UIColor.systemYellowColor, YES);
        NSString *badge = data_url(UIColor.systemBlueColor, NO);
        NSString *evil = @"http://127.0.0.1:8099/";

        ChatMessage *hello = message(@"시청자1", @[[ChatFragment text:@"안녕하세요! 첫 채팅입니다 👋"]]);
        hello.authorColor = @"#FF7F50";

        ChatMessage *moderator = message(@"매니저", @[[ChatFragment text:@"공지: 채팅 규칙을 지켜 주세요 🙏"]]);
        moderator.roles = ChatRoleModerator;
        moderator.badges = @[
            [ChatFragment image:badge alt:@"매니저"],
            [ChatFragment image:@"https://evil.example.com/badge.png" alt:@"가짜 배지"],
        ];

        ChatMessage *longText = message(
            @"긴글러",
            @[[ChatFragment text:@"오늘 방송 정말 재미있네요. 긴 글이 상자 너비에 맞춰 여러 줄로 나뉘는지 보려고 "
                                 @"일부러 길게 씁니다. Long English words like "
                                 @"supercalifragilisticexpialidocious should wrap too."]]);

        ChatMessage *emotes = message(@"이모티콘", @[
            [ChatFragment text:@"좋아요 "], [ChatFragment image:emote alt:@":smile:"], [ChatFragment text:@" 최고 "],
            [ChatFragment image:emote alt:@":smile:"]
        ]);

        ChatMessage *superChat = message(@"후원자", @[[ChatFragment text:@"응원합니다! 💪"]]);
        superChat.kind = ChatKindSuperChat;
        superChat.amount = @"₩10,000";

        ChatMessage *member = message(@"새멤버", @[[ChatFragment text:@"멤버 가입했어요 🎉"]]);
        member.roles = ChatRoleMember;
        member.kind = ChatKindMembership;

        ChatMessage *owner = message(@"방송자", @[[ChatFragment text:@"방송 시작합니다"]]);
        owner.roles = ChatRoleOwner | ChatRoleVerified;

        /* Markup everywhere: must show up as plain text */
        ChatMessage *markup = message(
            @"<b>해커</b></span><script>alert(1)</script>",
            @[[ChatFragment
                text:[NSString stringWithFormat:@"<img src=\"%@evil-text.png\" onerror=\"alert(2)\"><script>alert(3)"
                                                @"</script></div><style>*{display:none}</style><a href=\"%@evil-"
                                                @"link\">링크</a><iframe src=\"%@evil-frame\"></iframe>",
                                                evil, evil, evil]]]);
        markup.authorColor = [NSString stringWithFormat:@"red;background:url(%@evil-color.png)", evil];
        markup.amount = @"<b>₩1,000</b>";
        markup.kind = ChatKindSuperChat;

        /* Image URLs that must not be loaded: shown as their text */
        ChatMessage *badImages = message(@"이미지", @[
            [ChatFragment image:[evil stringByAppendingString:@"evil-emote.png"] alt:@"[http]"],
            [ChatFragment image:@"https://evil.example.com/evil.png" alt:@"[host]"],
            [ChatFragment image:@"javascript:alert(4)" alt:@"[js]"],
            [ChatFragment image:@"data:text/html;base64,PHNjcmlwdD5hbGVydCg1KTwvc2NyaXB0Pg==" alt:@"[html]"],
            [ChatFragment image:@"https://static-cdn.jtvnw.net:8443/evil.png" alt:@"[port]"],
            [ChatFragment image:@"https://user:pass@static-cdn.jtvnw.net/evil.png" alt:@"[user]"],
        ]);

        /* Direction override in the name, stacked combining marks, control characters */
        ChatMessage *tricks = message(@"‮evil‬이름\a",
                                      @[[ChatFragment text:@"Z̵̡̛̤̈́͒͒a̸̡"
                                                           @"͚͛͛͛͛͛l̶go\nnew line"]]);

        ChatMessage *emoji = message(@"Viewer", @[[ChatFragment text:@"Family 👨‍👩‍👧‍👦 flags 🇰🇷 skin 👍🏽"]]);
        emoji.authorColor = @"#8A2BE2";

        _round = @[hello, moderator, longText, emotes, superChat, member, owner, markup, badImages, tricks, emoji];
    }
    return self;
}

- (NSUInteger)roundLength
{
    return _round.count;
}

- (ChatMessage *)next
{
    ChatMessage *template = _round[_next % _round.count];
    ChatMessage *message = [[ChatMessage alloc] init];
    message.messageID = [NSString stringWithFormat:@"test-%lu", (unsigned long) _next];
    message.platform = template.platform;
    message.author = template.author;
    message.authorColor = template.authorColor;
    message.roles = template.roles;
    message.kind = template.kind;
    message.amount = template.amount;
    message.badges = template.badges;
    message.fragments = template.fragments;
    _next++;
    return message;
}

@end
