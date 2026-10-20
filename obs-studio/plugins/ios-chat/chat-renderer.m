/* iOS port: chat source, WebKit message renderer.
 *
 * A WKWebView behind the app's own views lays the messages out with the user's CSS. Each batch of messages is
 * captured with one snapshot and cut into one image per message; the source then stacks and moves those images on
 * the GPU, so the web view only works when messages arrive.
 *
 * Safety (the messages are written by viewers):
 * - the page is built only with DOM calls from our script in its own content world (chat.js)
 * - scripts from page content are off (allowsContentJavaScript = NO) and the page's Content-Security-Policy allows
 *   no scripts, no connections, and images only from the platforms' hosts (plus hosts the user's CSS names)
 * - no navigation away from our page, no new windows, nothing stored (non-persistent data store)
 * - every batch is checked for elements that must never be there (CHAT_UNSAFE in chat.js) and the result logged */

@import UIKit;
@import WebKit;

#include <obs-module.h>
#include <util/platform.h>

#include "chat.h"

#define BATCH_MAX 20
#define PAGE_HEIGHT 4096.0      /* points; a batch has to fit in it */
#define MESSAGE_MAX_HEIGHT 1000 /* CSS pixels; taller messages are cut */
#define BATCH_TIMEOUT 8.0       /* seconds */

NSString *chat_page_html = @"";
NSString *chat_page_script = @"";

@implementation ChatImage
@end

static UIWindow *find_window(void)
{
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) {
            continue;
        }
        UIWindowScene *windowScene = (UIWindowScene *) scene;
        UIWindow *window = windowScene.keyWindow ?: windowScene.windows.firstObject;
        if (window) {
            return window;
        }
    }
    return nil;
}

/* https origins the user's CSS refers to (fonts, background images); the page may load from them too */
static NSString *css_origins(NSString *css)
{
    static NSRegularExpression *pattern;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        pattern = [NSRegularExpression regularExpressionWithPattern:@"https://[A-Za-z0-9.-]+(:[0-9]{1,5})?"
                                                            options:0
                                                              error:nil];
    });

    NSMutableOrderedSet<NSString *> *origins = [NSMutableOrderedSet orderedSet];
    for (NSTextCheckingResult *match in [pattern matchesInString:css options:0 range:NSMakeRange(0, css.length)]) {
        [origins addObject:[css substringWithRange:match.range].lowercaseString];
    }
    return [origins.array componentsJoinedByString:@" "];
}

/* Premultiplied RGBA pixels of an image, first row at the top */
static NSMutableData *rgba_pixels(CGImageRef image)
{
    const size_t width = CGImageGetWidth(image);
    const size_t height = CGImageGetHeight(image);
    NSMutableData *data = [NSMutableData dataWithLength:width * height * 4];
    if (!data || !width || !height) {
        return nil;
    }

    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef context = CGBitmapContextCreate(data.mutableBytes, width, height, 8, width * 4, colorSpace,
                                                 (CGBitmapInfo) kCGImageAlphaPremultipliedLast |
                                                     kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(colorSpace);
    if (!context) {
        return nil;
    }
    CGContextSetBlendMode(context, kCGBlendModeCopy);
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
    CGContextRelease(context);
    return data;
}

/* The same page drawn over black and over white gives back its transparency: alpha = 1 - (white - black), and
 * over black the colour is already premultiplied. */
static void combine_black_white(uint8_t *black, const uint8_t *white, size_t pixels)
{
    for (size_t i = 0; i < pixels; i++) {
        uint8_t *b = black + i * 4;
        const uint8_t *w = white + i * 4;
        const int difference = ((int) w[0] - b[0]) + ((int) w[1] - b[1]) + ((int) w[2] - b[2]);
        const int alpha = MAX(0, MIN(255, 255 - difference / 3));
        b[0] = (uint8_t) MIN(b[0], alpha);
        b[1] = (uint8_t) MIN(b[1], alpha);
        b[2] = (uint8_t) MIN(b[2], alpha);
        b[3] = (uint8_t) alpha;
    }
}

@interface ChatRenderer () <WKNavigationDelegate, WKUIDelegate>
@end

@implementation ChatRenderer {
    WKWebView *_webView;
    UIView *_hostView;
    WKContentWorld *_world;
    uint32_t _width;
    NSString *_css;
    NSString *_origins;
    BOOL _loaded;
    BOOL _busy;
    BOOL _stopped;
    NSUInteger _generation;
    NSMutableArray<NSDictionary *> *_queue; /* {payload, images} */
}

- (instancetype)initWithWidth:(uint32_t)width css:(NSString *)css
{
    if ((self = [super init])) {
        _width = MAX(width, 1);
        _css = [css copy];
        _origins = css_origins(css);
        _queue = [NSMutableArray array];
        _alphaMode = @"unknown";
        [self attach];
    }
    return self;
}

#pragma mark - Web view

- (void)attach
{
    if (_stopped || _webView) {
        return;
    }

    /* The web view has to be in a window to draw; at launch the window may not exist yet */
    UIWindow *window = find_window();
    if (!window) {
        __weak ChatRenderer *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t) (0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf attach];
        });
        return;
    }

    WKWebViewConfiguration *configuration = [[WKWebViewConfiguration alloc] init];
    configuration.websiteDataStore = WKWebsiteDataStore.nonPersistentDataStore;
    configuration.defaultWebpagePreferences.allowsContentJavaScript = NO;
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = NO;
    configuration.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeAll;
    configuration.dataDetectorTypes = WKDataDetectorTypeNone;

    _world = [WKContentWorld worldWithName:@"ios-chat"];
    WKUserScript *script = [[WKUserScript alloc] initWithSource:chat_page_script
                                                  injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                               forMainFrameOnly:YES
                                                 inContentWorld:_world];
    [configuration.userContentController addUserScript:script];

    /* Behind everything else in the window: drawn, but never seen */
    _hostView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, _width, PAGE_HEIGHT)];
    _hostView.userInteractionEnabled = NO;
    _hostView.clipsToBounds = YES;
    [window insertSubview:_hostView atIndex:0];

    _webView = [[WKWebView alloc] initWithFrame:_hostView.bounds configuration:configuration];
    _webView.opaque = NO;
    _webView.backgroundColor = UIColor.clearColor;
    _webView.scrollView.backgroundColor = UIColor.clearColor;
    _webView.scrollView.scrollEnabled = NO;
    _webView.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    _webView.navigationDelegate = self;
    _webView.UIDelegate = self;
    [_hostView addSubview:_webView];

    [self loadPage];
}

- (void)loadPage
{
    /* Only tokens that passed css_origins' pattern go into the policy */
    NSString *policy = [NSString
        stringWithFormat:@"default-src 'none'; "
                         @"img-src data: https://static-cdn.jtvnw.net https://yt3.ggpht.com https://yt4.ggpht.com "
                         @"https://www.gstatic.com %@; style-src 'unsafe-inline' %@; font-src data: "
                         @"https://fonts.gstatic.com %@",
                         _origins, _origins, _origins];
    _loaded = NO;
    [_webView loadHTMLString:[chat_page_html stringByReplacingOccurrencesOfString:@"@CSP@" withString:policy]
                     baseURL:nil];
}

- (void)webView:(WKWebView *)webView
    decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
                    decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler
{
    (void) webView;
    /* Our own page (loadHTMLString without a base URL) and nothing else */
    NSString *url = navigationAction.request.URL.absoluteString ?: @"";
    const BOOL ours = navigationAction.targetFrame.isMainFrame &&
                      navigationAction.navigationType == WKNavigationTypeOther &&
                      (url.length == 0 || [url isEqualToString:@"about:blank"]);
    if (!ours) {
        CHAT_LOG(LOG_WARNING, "blocked navigation (%ld)", (long) navigationAction.navigationType);
    }
    decisionHandler(ours ? WKNavigationActionPolicyAllow : WKNavigationActionPolicyCancel);
}

- (WKWebView *)webView:(WKWebView *)webView
    createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
               forNavigationAction:(WKNavigationAction *)navigationAction
                    windowFeatures:(WKWindowFeatures *)windowFeatures
{
    (void) webView;
    (void) configuration;
    (void) navigationAction;
    (void) windowFeatures;
    return nil;
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation
{
    (void) webView;
    (void) navigation;
    _loaded = YES;
    [self applyStyle];

    if ([_alphaMode isEqualToString:@"unknown"]) {
        [self probeAlpha];
    } else {
        [self pump];
    }
}

- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView
{
    (void) webView;
    CHAT_LOG(LOG_WARNING, "web content process ended, reloading");
    _busy = NO;
    _generation++;
    [self loadPage];
}

- (void)call:(NSString *)body
    arguments:(NSDictionary<NSString *, id> *)arguments
         then:(void (^_Nullable)(id _Nullable result, NSError *_Nullable error))then
{
    [_webView callAsyncJavaScript:body
                        arguments:arguments
                          inFrame:nil
                   inContentWorld:_world
                completionHandler:^(id result, NSError *error) {
                    if (error) {
                        CHAT_LOG(LOG_WARNING, "script failed: %s", error.localizedDescription.UTF8String);
                    }
                    if (then) {
                        then(result, error);
                    }
                }];
}

- (void)applyStyle
{
    [self call:@"chatSetStyle(css, width);" arguments:@{@"css": _css, @"width": @(_width)} then:nil];
}

- (void)setWidth:(uint32_t)width css:(NSString *)css
{
    width = MAX(width, 1);
    if (width == _width && [css isEqualToString:_css]) {
        return;
    }

    _width = width;
    _css = [css copy];
    _hostView.frame = CGRectMake(0, 0, _width, PAGE_HEIGHT);
    _webView.frame = _hostView.bounds;

    /* New hosts in the CSS change the page's policy, which needs a reload */
    NSString *origins = css_origins(css);
    if (![origins isEqualToString:_origins]) {
        _origins = origins;
        _busy = NO;
        _generation++;
        [self loadPage];
    } else if (_loaded) {
        [self applyStyle];
    }
}

- (void)stop
{
    _stopped = YES;
    _generation++;
    [_queue removeAllObjects];
    _webView.navigationDelegate = nil;
    _webView.UIDelegate = nil;
    [_webView stopLoading];
    [_hostView removeFromSuperview];
    _webView = nil;
    _hostView = nil;
}

#pragma mark - Snapshots

/* Snapshot of a rectangle of the page, one image pixel per CSS pixel */
- (void)snapshot:(CGRect)rect then:(void (^)(CGImageRef _Nullable image))then
{
    WKSnapshotConfiguration *configuration = [[WKSnapshotConfiguration alloc] init];
    configuration.rect = rect;
    configuration.afterScreenUpdates = YES;
    const CGFloat scale = _hostView.window.traitCollection.displayScale > 0
                              ? _hostView.window.traitCollection.displayScale
                              : 2;
    configuration.snapshotWidth = @(rect.size.width / scale);
    [_webView takeSnapshotWithConfiguration:configuration
                          completionHandler:^(UIImage *image, NSError *error) {
                              if (error) {
                                  CHAT_LOG(LOG_WARNING, "snapshot failed: %s", error.localizedDescription.UTF8String);
                              }
                              then(image.CGImage);
                          }];
}

/* Snapshot with transparency: directly if WebKit keeps it, otherwise over black and over white */
- (void)capture:(CGRect)rect then:(void (^)(NSMutableData *_Nullable pixels, size_t width, size_t height))then
{
    if (![_alphaMode isEqualToString:@"dual"]) {
        [self snapshot:rect
                  then:^(CGImageRef image) {
                      then(image ? rgba_pixels(image) : nil, image ? CGImageGetWidth(image) : 0,
                           image ? CGImageGetHeight(image) : 0);
                  }];
        return;
    }

    /* each step waits for the one before: background set → snapshot → next background */
    __weak ChatRenderer *weakSelf = self;
    void (^over)(NSString *, void (^)(NSMutableData *, size_t, size_t)) =
        ^(NSString *color, void (^done)(NSMutableData *, size_t, size_t)) {
            [weakSelf call:@"chatBackground(color);"
                 arguments:@{@"color": color}
                      then:^(id result, NSError *error) {
                          (void) result;
                          (void) error;
                          [weakSelf snapshot:rect
                                        then:^(CGImageRef image) {
                                            done(image ? rgba_pixels(image) : nil, image ? CGImageGetWidth(image) : 0,
                                                 image ? CGImageGetHeight(image) : 0);
                                        }];
                      }];
        };

    over(@"black", ^(NSMutableData *black, size_t width, size_t height) {
        if (!black) {
            [weakSelf call:@"chatBackground('transparent');" arguments:@{} then:nil];
            then(nil, 0, 0);
            return;
        }
        over(@"white", ^(NSMutableData *white, size_t whiteWidth, size_t whiteHeight) {
            [weakSelf call:@"chatBackground('transparent');" arguments:@{} then:nil];
            if (!white || whiteWidth != width || whiteHeight != height) {
                then(nil, 0, 0);
                return;
            }
            combine_black_white(black.mutableBytes, white.bytes, width * height);
            then(black, width, height);
        });
    });
}

static uint8_t probe_alpha(NSData *pixels, size_t width, size_t height, double x, double y)
{
    const size_t px = MIN(width - 1, (size_t) (x * width));
    const size_t py = MIN(height - 1, (size_t) (y * height));
    return ((const uint8_t *) pixels.bytes)[(py * width + px) * 4 + 3];
}

/* Does WebKit keep transparency in snapshots? A probe with a transparent left half and an opaque right half. */
- (void)probeAlpha
{
    __weak ChatRenderer *weakSelf = self;
    const CGRect rect = CGRectMake(0, 0, 40, 20);

    void (^finish)(NSString *) = ^(NSString *mode) {
        ChatRenderer *strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        strongSelf->_alphaMode = mode;
        [strongSelf call:@"chatProbe(false);"
               arguments:@{}
                    then:^(id result, NSError *error) {
                        (void) result;
                        (void) error;
                        [weakSelf pump];
                    }];
    };

    [self call:@"chatProbe(true);"
        arguments:@{}
             then:^(id result, NSError *error) {
                 (void) result;
                 (void) error;
                 [weakSelf snapshot:rect
                               then:^(CGImageRef image) {
                                   NSData *pixels = image ? rgba_pixels(image) : nil;
                                   if (!pixels) {
                                       CHAT_LOG(LOG_WARNING, "alpha probe: no snapshot, using dual");
                                       finish(@"dual");
                                       return;
                                   }
                                   const size_t width = CGImageGetWidth(image);
                                   const size_t height = CGImageGetHeight(image);
                                   const uint8_t left = probe_alpha(pixels, width, height, 0.1, 0.5);
                                   const uint8_t right = probe_alpha(pixels, width, height, 0.9, 0.5);
                                   if (left < 16 && right > 240) {
                                       CHAT_LOG(LOG_INFO, "snapshot alpha preserved (%zux%zu for 40x20)", width,
                                                height);
                                       finish(@"preserved");
                                       return;
                                   }

                                   /* Check the black/white way with the same probe */
                                   ChatRenderer *strongSelf = weakSelf;
                                   if (!strongSelf) {
                                       return;
                                   }
                                   strongSelf->_alphaMode = @"dual";
                                   [strongSelf capture:rect
                                                  then:^(NSMutableData *dual, size_t dualWidth, size_t dualHeight) {
                                                      const uint8_t dualLeft =
                                                          dual ? probe_alpha(dual, dualWidth, dualHeight, 0.1, 0.5)
                                                               : 255;
                                                      const uint8_t dualRight =
                                                          dual ? probe_alpha(dual, dualWidth, dualHeight, 0.9, 0.5)
                                                               : 0;
                                                      CHAT_LOG(LOG_INFO,
                                                               "snapshot alpha dual (direct %u/%u, black-white %u/%u)",
                                                               left, right, dualLeft, dualRight);
                                                      finish(@"dual");
                                                  }];
                               }];
             }];
}

#pragma mark - Batches

- (void)enqueue:(ChatMessage *)message
{
    if (_stopped) {
        return;
    }
    NSUInteger images = 0;
    NSDictionary *payload = [message payloadWithImageCount:&images];
    NSMutableDictionary *entry = [@{
        @"payload": payload,
        @"images": @(images),
        @"id": message.messageID,
        @"received": @(message.receivedAt),
    } mutableCopy];
    if (message.authorID) {
        entry[@"author"] = message.authorID;
    }
    [_queue addObject:entry];

    /* A flood can only make the chat fall behind; keep the newest */
    while (_queue.count > 200) {
        [_queue removeObjectAtIndex:0];
    }
    [self pump];
}

- (void)discardIDs:(NSSet<NSString *> *)ids authors:(NSSet<NSString *> *)authors
{
    NSIndexSet *dropped = [_queue indexesOfObjectsPassingTest:^BOOL(NSDictionary *entry, NSUInteger index, BOOL *stop) {
        (void) index;
        (void) stop;
        return [ids containsObject:entry[@"id"]] || (entry[@"author"] && [authors containsObject:entry[@"author"]]);
    }];
    [_queue removeObjectsAtIndexes:dropped];
}

- (void)pump
{
    if (_stopped || !_loaded || _busy || _queue.count == 0 || [_alphaMode isEqualToString:@"unknown"]) {
        return;
    }

    NSArray<NSDictionary *> *batch = [_queue subarrayWithRange:NSMakeRange(0, MIN(_queue.count, BATCH_MAX))];
    [_queue removeObjectsInRange:NSMakeRange(0, batch.count)];
    _busy = YES;
    const NSUInteger generation = ++_generation;
    const uint64_t started = os_gettime_ns();

    __weak ChatRenderer *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t) (BATCH_TIMEOUT * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                       ChatRenderer *strongSelf = weakSelf;
                       if (strongSelf && strongSelf->_busy && strongSelf->_generation == generation) {
                           CHAT_LOG(LOG_WARNING, "batch of %lu timed out", (unsigned long) batch.count);
                           strongSelf->_busy = NO;
                           [strongSelf pump];
                       }
                   });

    NSMutableArray *messages = [NSMutableArray arrayWithCapacity:batch.count];
    for (NSDictionary *entry in batch) {
        [messages addObject:entry[@"payload"]];
    }

    [self call:@"return await chatRenderBatch(messages, maxHeight, maxBottom);"
        arguments:@{@"messages": messages, @"maxHeight": @(MESSAGE_MAX_HEIGHT), @"maxBottom": @(PAGE_HEIGHT)}
             then:^(id result, NSError *error) {
                 ChatRenderer *strongSelf = weakSelf;
                 if (!strongSelf || strongSelf->_generation != generation) {
                     return;
                 }
                 NSArray *rects = [result isKindOfClass:NSDictionary.class] ? result[@"rects"] : nil;
                 if (error || ![rects isKindOfClass:NSArray.class] || rects.count == 0) {
                     strongSelf->_busy = NO;
                     [strongSelf pump];
                     return;
                 }

                 /* What did not fit goes back to the front of the queue */
                 if (rects.count < batch.count) {
                     NSArray *rest = [batch subarrayWithRange:NSMakeRange(rects.count, batch.count - rects.count)];
                     [strongSelf->_queue insertObjects:rest atIndexes:[NSIndexSet indexSetWithIndexesInRange:
                                                                                     NSMakeRange(0, rest.count)]];
                 }

                 struct chat_batch_stats stats = {0};
                 stats.messages = rects.count;
                 stats.unsafe_elements = [result[@"unsafe"] unsignedIntegerValue];
                 NSArray *images = result[@"images"];
                 for (NSUInteger i = 0; i < rects.count; i++) {
                     const NSUInteger shown = i < images.count ? [images[i] unsignedIntegerValue] : 0;
                     if (shown != [batch[i][@"images"] unsignedIntegerValue]) {
                         stats.image_mismatches++;
                     }
                 }
                 stats.render_ms = (os_gettime_ns() - started) / 1e6;
                 [strongSelf captureBatch:rects
                                    batch:[batch subarrayWithRange:NSMakeRange(0, rects.count)]
                                    stats:stats
                               generation:generation];
             }];
}

- (void)captureBatch:(NSArray<NSArray<NSNumber *> *> *)rects
               batch:(NSArray<NSDictionary *> *)batch
               stats:(struct chat_batch_stats)stats
          generation:(NSUInteger)generation
{
    const double bottom = rects.lastObject[0].doubleValue + rects.lastObject[1].doubleValue;
    const CGRect rect = CGRectMake(0, 0, _width, MAX(1, ceil(bottom)));
    const uint64_t started = os_gettime_ns();
    const uint32_t cssWidth = _width;

    __weak ChatRenderer *weakSelf = self;
    [self capture:rect
             then:^(NSMutableData *pixels, size_t width, size_t height) {
                 ChatRenderer *strongSelf = weakSelf;
                 if (!strongSelf || strongSelf->_generation != generation) {
                     return;
                 }
                 strongSelf->_busy = NO;

                 struct chat_batch_stats done = stats;
                 done.snapshot_ms = (os_gettime_ns() - started) / 1e6;

                 NSMutableArray<ChatImage *> *result = [NSMutableArray arrayWithCapacity:rects.count];
                 if (pixels && width && height) {
                     /* image pixels per CSS pixel (1 unless WebKit chose another size) */
                     const double scale = (double) width / cssWidth;
                     for (NSUInteger i = 0; i < rects.count; i++) {
                         NSArray<NSNumber *> *messageRect = rects[i];
                         const double top = messageRect[0].doubleValue;
                         const double messageHeight = messageRect[1].doubleValue;
                         const size_t y0 = MIN(height, (size_t) llround(top * scale));
                         const size_t y1 = MIN(height, (size_t) llround((top + messageHeight) * scale));
                         if (y1 <= y0) {
                             continue;
                         }

                         ChatImage *image = [[ChatImage alloc] init];
                         image.cx = (uint32_t) width;
                         image.cy = (uint32_t) (y1 - y0);
                         image.displayCX = cssWidth;
                         image.displayCY = (float) messageHeight;
                         image.pixels = [NSData dataWithBytes:(const uint8_t *) pixels.bytes + y0 * width * 4
                                                       length:(y1 - y0) * width * 4];
                         image.messageID = batch[i][@"id"];
                         image.authorID = batch[i][@"author"];
                         image.receivedAt = [batch[i][@"received"] doubleValue];
                         [result addObject:image];
                     }
                 } else {
                     CHAT_LOG(LOG_WARNING, "batch of %lu not captured", (unsigned long) rects.count);
                 }

                 if (strongSelf.rendered) {
                     strongSelf.rendered(result, done);
                 }
                 [strongSelf pump];
             }];
}

@end
