#import <Cocoa/Cocoa.h>
#import <dispatch/dispatch.h>
#import <poll.h>
#import <unistd.h>

static NSString * const CUCacheKey = @"codexusage.cachedSnapshot.v2";
static NSString * const CULaunchAgentID = @"com.local.codexusage";

static double CUClampPercent(double v) { return fmin(100.0, fmax(0.0, v)); }

static NSString *CUFormatPercent(NSNumber *value) {
    if (!value) return @"--";
    return [NSString stringWithFormat:@"%.0f%%", value.doubleValue];
}

static NSString *CUFormatClock(NSDate *date) {
    if (!date) return @"--";
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
        formatter.dateFormat = @"HH:mm";
    });
    return [formatter stringFromDate:date];
}

static NSString *CUFormatSevenDayReset(NSDate *date) {
    if (!date) return @"--";
    static NSDateFormatter *sameYearFormatter;
    static NSDateFormatter *crossYearFormatter;
    static NSCalendar *calendar;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
        calendar.timeZone = [NSTimeZone localTimeZone];

        sameYearFormatter = [[NSDateFormatter alloc] init];
        sameYearFormatter.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
        sameYearFormatter.calendar = calendar;
        sameYearFormatter.dateFormat = @"M.d HH:mm";

        crossYearFormatter = [[NSDateFormatter alloc] init];
        crossYearFormatter.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
        crossYearFormatter.calendar = calendar;
        crossYearFormatter.dateFormat = @"yyyy.M.d HH:mm";
    });

    NSDateComponents *nowComponents = [calendar components:NSCalendarUnitEra | NSCalendarUnitYear fromDate:[NSDate date]];
    NSDateComponents *resetComponents = [calendar components:NSCalendarUnitEra | NSCalendarUnitYear fromDate:date];
    if (nowComponents.era != resetComponents.era || nowComponents.year != resetComponents.year) {
        return [crossYearFormatter stringFromDate:date];
    }
    return [sameYearFormatter stringFromDate:date];
}

static NSString *CUFormatTokenCount(NSNumber *value) {
    if (!value) return @"--";
    double n = value.doubleValue;
    if (n >= 1000000000.0) return [NSString stringWithFormat:@"%.2fB", n / 1000000000.0];
    if (n >= 1000000.0) return [NSString stringWithFormat:(n >= 100000000.0 ? @"%.1fM" : @"%.2fM"), n / 1000000.0];
    if (n >= 1000.0) return [NSString stringWithFormat:(n >= 100000.0 ? @"%.0fK" : @"%.1fK"), n / 1000.0];
    return [NSString stringWithFormat:@"%lld", value.longLongValue];
}

@interface CUUsageSnapshot : NSObject
@property(nonatomic, strong) NSNumber *fiveHourRemaining;
@property(nonatomic, strong) NSNumber *sevenDayRemaining;
@property(nonatomic, strong) NSDate *fiveHourResetAt;
@property(nonatomic, strong) NSDate *sevenDayResetAt;
@property(nonatomic, strong) NSNumber *todayTokens;
@property(nonatomic, strong) NSNumber *lifetimeTokens;
@property(nonatomic, strong) NSDate *fetchedAt;
- (NSDictionary *)propertyList;
+ (instancetype)fromPropertyList:(NSDictionary *)dict;
@end

@implementation CUUsageSnapshot
- (NSDictionary *)propertyList {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    if (self.fiveHourRemaining) d[@"fiveHourRemaining"] = self.fiveHourRemaining;
    if (self.sevenDayRemaining) d[@"sevenDayRemaining"] = self.sevenDayRemaining;
    if (self.fiveHourResetAt) d[@"fiveHourResetAt"] = @([self.fiveHourResetAt timeIntervalSince1970]);
    if (self.sevenDayResetAt) d[@"sevenDayResetAt"] = @([self.sevenDayResetAt timeIntervalSince1970]);
    if (self.todayTokens) d[@"todayTokens"] = self.todayTokens;
    if (self.lifetimeTokens) d[@"lifetimeTokens"] = self.lifetimeTokens;
    if (self.fetchedAt) d[@"fetchedAt"] = @([self.fetchedAt timeIntervalSince1970]);
    return d;
}
+ (instancetype)fromPropertyList:(NSDictionary *)dict {
    if (![dict isKindOfClass:[NSDictionary class]]) return nil;
    CUUsageSnapshot *s = [[CUUsageSnapshot alloc] init];
    s.fiveHourRemaining = [dict[@"fiveHourRemaining"] isKindOfClass:[NSNumber class]] ? dict[@"fiveHourRemaining"] : nil;
    s.sevenDayRemaining = [dict[@"sevenDayRemaining"] isKindOfClass:[NSNumber class]] ? dict[@"sevenDayRemaining"] : nil;
    NSNumber *r5 = dict[@"fiveHourResetAt"];
    NSNumber *r7 = dict[@"sevenDayResetAt"];
    NSNumber *ft = dict[@"fetchedAt"];
    if ([r5 isKindOfClass:[NSNumber class]]) s.fiveHourResetAt = [NSDate dateWithTimeIntervalSince1970:r5.doubleValue];
    if ([r7 isKindOfClass:[NSNumber class]]) s.sevenDayResetAt = [NSDate dateWithTimeIntervalSince1970:r7.doubleValue];
    if ([ft isKindOfClass:[NSNumber class]]) s.fetchedAt = [NSDate dateWithTimeIntervalSince1970:ft.doubleValue];
    s.todayTokens = [dict[@"todayTokens"] isKindOfClass:[NSNumber class]] ? dict[@"todayTokens"] : nil;
    s.lifetimeTokens = [dict[@"lifetimeTokens"] isKindOfClass:[NSNumber class]] ? dict[@"lifetimeTokens"] : nil;
    return (s.fiveHourRemaining && s.sevenDayRemaining && s.fetchedAt) ? s : nil;
}
@end

static void CUStopTask(NSTask *task, NSFileHandle *writer);

@interface CodexAppServerClient : NSObject
- (void)fetchWithCompletion:(void (^)(CUUsageSnapshot *snapshot, NSString *errorMessage))completion;
@end

@implementation CodexAppServerClient

- (NSString *)resolveCodexPath {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *home = NSHomeDirectory();

    // install.command 会把它在本机实际找到的 Codex CLI 写入 App Resources。
    // 优先使用这个“安装时已验证路径”，避免 GUI App 的 PATH 与终端不同。
    NSString *hint = [[NSBundle mainBundle] pathForResource:@"CodexCLIPath" ofType:@"txt"];
    if (hint.length) {
        NSString *saved = [NSString stringWithContentsOfFile:hint encoding:NSUTF8StringEncoding error:nil];
        saved = [saved stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (saved.length && [fm isExecutableFileAtPath:saved]) return saved;
    }

    NSArray<NSString *> *candidates = @[
        @"/Applications/ChatGPT.app/Contents/Resources/codex",
        @"/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
        @"/Applications/Codex.app/Contents/Resources/codex",
        @"/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
        [home stringByAppendingPathComponent:@"Applications/ChatGPT.app/Contents/Resources/codex"],
        [home stringByAppendingPathComponent:@"Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"],
        [home stringByAppendingPathComponent:@"Applications/Codex.app/Contents/Resources/codex"],
        [home stringByAppendingPathComponent:@"Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"],
        @"/opt/homebrew/bin/codex",
        @"/usr/local/bin/codex",
        [home stringByAppendingPathComponent:@".local/bin/codex"],
        [home stringByAppendingPathComponent:@".volta/bin/codex"],
        [home stringByAppendingPathComponent:@".npm-global/bin/codex"]
    ];
    for (NSString *path in candidates) {
        if ([fm isExecutableFileAtPath:path]) return path;
    }

    // 兼容未来改名、Beta 版或安装在 ~/Applications：检查已知的 CLI bundle 布局。
    for (NSString *appsDir in @[@"/Applications", [home stringByAppendingPathComponent:@"Applications"]]) {
        NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:appsDir error:nil];
        for (NSString *entry in entries) {
            if (![entry.pathExtension.lowercaseString isEqualToString:@"app"]) continue;
            NSString *appPath = [appsDir stringByAppendingPathComponent:entry];
            for (NSString *relativePath in @[
                @"Contents/Resources/codex",
                @"Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
            ]) {
                NSString *path = [appPath stringByAppendingPathComponent:relativePath];
                if ([fm isExecutableFileAtPath:path]) return path;
            }
        }
    }

    // 最后才使用登录 Shell PATH。GUI App 的 PATH 常常比终端短，所以这里只作为兜底。
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/zsh"];
    task.arguments = @[@"-lc", @"command -v codex 2>/dev/null"];
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = [NSFileHandle fileHandleWithNullDevice];
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) return nil;
    [task waitUntilExit];
    if (task.terminationStatus != 0) return nil;
    NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
    NSString *path = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    path = [path stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return (path.length && [fm isExecutableFileAtPath:path]) ? path : nil;
}

- (BOOL)writeJSON:(NSDictionary *)object toHandle:(NSFileHandle *)handle error:(NSString **)errorMessage {
    if (![NSJSONSerialization isValidJSONObject:object]) {
        if (errorMessage) *errorMessage = @"Codex 请求格式无效";
        return NO;
    }
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:&error];
    if (!data) {
        if (errorMessage) *errorMessage = error.localizedDescription ?: @"Codex 请求编码失败";
        return NO;
    }
    NSMutableData *line = [data mutableCopy];
    uint8_t lf = '\n';
    [line appendBytes:&lf length:1];
    @try {
        [handle writeData:line];
        return YES;
    } @catch (NSException *exception) {
        if (errorMessage) *errorMessage = exception.reason ?: @"Codex 请求写入失败";
        return NO;
    }
}

- (NSDictionary *)preferredRateLimitSnapshot:(NSDictionary *)root {
    NSDictionary *byID = [root[@"rateLimitsByLimitId"] isKindOfClass:[NSDictionary class]] ? root[@"rateLimitsByLimitId"] : nil;
    NSDictionary *codex = [byID[@"codex"] isKindOfClass:[NSDictionary class]] ? byID[@"codex"] : nil;
    if (codex) return codex;
    for (id value in byID.allValues) {
        if ([value isKindOfClass:[NSDictionary class]]) return value;
    }
    return [root[@"rateLimits"] isKindOfClass:[NSDictionary class]] ? root[@"rateLimits"] : nil;
}

- (NSNumber *)remainingFromWindow:(NSDictionary *)window resetDate:(NSDate **)resetDate {
    if (![window isKindOfClass:[NSDictionary class]]) return nil;
    NSNumber *used = [window[@"usedPercent"] isKindOfClass:[NSNumber class]] ? window[@"usedPercent"] : nil;
    if (!used) return nil;
    NSNumber *reset = [window[@"resetsAt"] isKindOfClass:[NSNumber class]] ? window[@"resetsAt"] : nil;
    if (resetDate) *resetDate = (reset.doubleValue > 0) ? [NSDate dateWithTimeIntervalSince1970:reset.doubleValue] : nil;
    return @(CUClampPercent(100.0 - used.doubleValue));
}

- (CUUsageSnapshot *)parseRate:(NSDictionary *)rate usage:(NSDictionary *)usage {
    NSDictionary *snapshot = [self preferredRateLimitSnapshot:rate];
    if (!snapshot) return nil;
    NSDate *r5 = nil, *r7 = nil;
    NSNumber *p5 = [self remainingFromWindow:snapshot[@"primary"] resetDate:&r5];
    NSNumber *p7 = [self remainingFromWindow:snapshot[@"secondary"] resetDate:&r7];
    if (!p5 || !p7) return nil;

    CUUsageSnapshot *result = [[CUUsageSnapshot alloc] init];
    result.fiveHourRemaining = p5;
    result.sevenDayRemaining = p7;
    result.fiveHourResetAt = r5;
    result.sevenDayResetAt = r7;
    result.fetchedAt = [NSDate date];

    NSDictionary *summary = [usage[@"summary"] isKindOfClass:[NSDictionary class]] ? usage[@"summary"] : nil;
    if ([summary[@"lifetimeTokens"] isKindOfClass:[NSNumber class]]) result.lifetimeTokens = summary[@"lifetimeTokens"];

    NSArray *buckets = [usage[@"dailyUsageBuckets"] isKindOfClass:[NSArray class]] ? usage[@"dailyUsageBuckets"] : nil;
    if (buckets) {
        NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
        fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        fmt.calendar = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
        fmt.timeZone = [NSTimeZone localTimeZone];
        fmt.dateFormat = @"yyyy-MM-dd";
        NSString *today = [fmt stringFromDate:[NSDate date]];
        result.todayTokens = @0;
        for (id item in buckets) {
            if (![item isKindOfClass:[NSDictionary class]]) continue;
            NSDictionary *bucket = item;
            if ([bucket[@"startDate"] isEqual:today] && [bucket[@"tokens"] isKindOfClass:[NSNumber class]]) {
                result.todayTokens = bucket[@"tokens"];
                break;
            }
        }
    }
    return result;
}

- (NSString *)RPCErrorMessage:(NSDictionary *)object fallback:(NSString *)fallback {
    NSDictionary *error = [object[@"error"] isKindOfClass:[NSDictionary class]] ? object[@"error"] : nil;
    NSString *message = [error[@"message"] isKindOfClass:[NSString class]] ? error[@"message"] : nil;
    return message.length ? message : fallback;
}

- (void)fetchWithCompletion:(void (^)(CUUsageSnapshot *, NSString *))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool {
            NSString *codexPath = [self resolveCodexPath];
            if (!codexPath) {
                dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, @"未找到 Codex CLI（请确认 ChatGPT/Codex 已安装）"); });
                return;
            }

            NSTask *task = [[NSTask alloc] init];
            task.executableURL = [NSURL fileURLWithPath:codexPath];
            task.arguments = @[@"app-server"];
            NSPipe *inPipe = [NSPipe pipe];
            NSPipe *outPipe = [NSPipe pipe];
            task.standardInput = inPipe;
            task.standardOutput = outPipe;
            task.standardError = [NSFileHandle fileHandleWithNullDevice];

            NSError *launchError = nil;
            if (![task launchAndReturnError:&launchError]) {
                NSString *m = [NSString stringWithFormat:@"无法启动 Codex：%@", launchError.localizedDescription ?: @"未知错误"];
                dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, m); });
                return;
            }

            NSFileHandle *writer = [inPipe fileHandleForWriting];
            NSString *writeError = nil;
            NSDictionary *init = @{
                @"method": @"initialize",
                @"id": @1,
                @"params": @{
                    @"clientInfo": @{@"name": @"codexusage", @"title": @"codexusage", @"version": @"1.13.1"},
                    @"capabilities": @{}
                }
            };
            if (![self writeJSON:init toHandle:writer error:&writeError]) {
                CUStopTask(task, writer);
                dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, writeError ?: @"Codex 初始化请求失败"); });
                return;
            }

            int fd = [outPipe fileHandleForReading].fileDescriptor;
            NSMutableData *buffer = [NSMutableData data];
            NSDictionary *rateResult = nil;
            NSDictionary *usageResult = nil;
            BOOL initialized = NO;
            BOOL rateDone = NO;
            BOOL usageDone = NO;
            NSString *fatalError = nil;
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10.0];

            while (!fatalError && !(rateDone && usageDone)) {
                NSTimeInterval remaining = [deadline timeIntervalSinceNow];
                if (remaining <= 0) { fatalError = @"读取额度超时"; break; }
                struct pollfd pfd = { .fd = fd, .events = POLLIN, .revents = 0 };
                int pr = poll(&pfd, 1, (int)(remaining * 1000.0));
                if (pr == 0) { fatalError = @"读取额度超时"; break; }
                if (pr < 0) { fatalError = @"读取 Codex 输出失败"; break; }
                if (!(pfd.revents & (POLLIN | POLLHUP))) continue;

                uint8_t bytes[8192];
                ssize_t n = read(fd, bytes, sizeof(bytes));
                if (n <= 0) {
                    if (!(rateDone && usageDone)) fatalError = @"Codex app-server 提前退出";
                    break;
                }
                [buffer appendBytes:bytes length:(NSUInteger)n];

                while (YES) {
                    const uint8_t *raw = buffer.bytes;
                    NSUInteger len = buffer.length;
                    NSUInteger newline = NSNotFound;
                    for (NSUInteger i = 0; i < len; i++) { if (raw[i] == '\n') { newline = i; break; } }
                    if (newline == NSNotFound) break;
                    NSData *line = [buffer subdataWithRange:NSMakeRange(0, newline)];
                    [buffer replaceBytesInRange:NSMakeRange(0, newline + 1) withBytes:NULL length:0];
                    if (!line.length) continue;
                    NSDictionary *obj = [NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
                    if (![obj isKindOfClass:[NSDictionary class]]) continue;
                    NSNumber *rid = [obj[@"id"] isKindOfClass:[NSNumber class]] ? obj[@"id"] : nil;
                    if (rid.integerValue == 1 && !initialized) {
                        if (obj[@"error"]) { fatalError = [self RPCErrorMessage:obj fallback:@"Codex 初始化失败"]; break; }
                        initialized = YES;
                        NSString *requestError = nil;
                        if (![self writeJSON:@{@"method": @"initialized", @"params": @{}} toHandle:writer error:&requestError] ||
                            ![self writeJSON:@{@"method": @"account/rateLimits/read", @"id": @2} toHandle:writer error:&requestError] ||
                            ![self writeJSON:@{@"method": @"account/usage/read", @"id": @3} toHandle:writer error:&requestError]) {
                            fatalError = requestError ?: @"Codex 请求写入失败";
                            break;
                        }
                    } else if (rid.integerValue == 2) {
                        rateDone = YES;
                        if (obj[@"error"]) { fatalError = [self RPCErrorMessage:obj fallback:@"读取额度失败"]; break; }
                        if ([obj[@"result"] isKindOfClass:[NSDictionary class]]) rateResult = obj[@"result"];
                    } else if (rid.integerValue == 3) {
                        usageDone = YES;
                        // Token 统计是附加信息：失败时不影响 5h / 7d 额度显示。
                        if (!obj[@"error"] && [obj[@"result"] isKindOfClass:[NSDictionary class]]) usageResult = obj[@"result"];
                    }
                }
            }

            CUStopTask(task, writer);

            CUUsageSnapshot *snapshot = nil;
            if (!fatalError && rateResult) snapshot = [self parseRate:rateResult usage:(usageResult ?: @{})];
            if (!snapshot && !fatalError) fatalError = @"Codex 返回的数据格式无法识别";
            dispatch_async(dispatch_get_main_queue(), ^{ completion(snapshot, fatalError); });
        }
    });
}
@end

static void CUStopTask(NSTask *task, NSFileHandle *writer) {
    @try { [writer closeFile]; } @catch (__unused NSException *exception) {}
    if (task.running) {
        [task terminate];
        [task waitUntilExit];
    }
}

@interface StatusQuotaView : NSView
@property(nonatomic, strong) NSNumber *fiveHourPercent;
@property(nonatomic, strong) NSNumber *sevenDayPercent;
@end

@implementation StatusQuotaView
- (BOOL)isFlipped { return YES; }
- (NSView *)hitTest:(NSPoint)point { return nil; }
- (void)setFiveHourPercent:(NSNumber *)v { _fiveHourPercent = v; self.needsDisplay = YES; }
- (void)setSevenDayPercent:(NSNumber *)v { _sevenDayPercent = v; self.needsDisplay = YES; }

- (void)drawRow:(NSString *)label percent:(NSNumber *)percent y:(CGFloat)y {
    NSColor *textColor = [NSColor labelColor];
    NSFont *labelFont = [NSFont monospacedSystemFontOfSize:9.2 weight:NSFontWeightSemibold];
    NSFont *percentFont = [NSFont monospacedDigitSystemFontOfSize:9.2 weight:NSFontWeightSemibold];
    NSDictionary *labelAttrs = @{NSFontAttributeName: labelFont, NSForegroundColorAttributeName: textColor};
    NSDictionary *percentAttrs = @{NSFontAttributeName: percentFont, NSForegroundColorAttributeName: textColor};

    // 固定三栏：标签 / 10格进度 / 百分比。
    // 仍使用系统 NSStatusBarButton 的原生高亮区域，但 StatusQuotaView 会向左右
    // 各扩展 5.5pt 覆盖按钮默认内容留白，因此 5h/7d 和百分比能更靠近
    // 灰色区域两端；回收的宽度全部交给 10 格进度区。
    // 百分比栏按“100%”真实宽度固定，数字变化不会挤压中间格子。
    CGFloat leftInset = 1.0, rightInset = 1.0;
    CGFloat labelSlotWidth = MAX([@"5h" sizeWithAttributes:labelAttrs].width,
                                 [@"7d" sizeWithAttributes:labelAttrs].width);
    CGFloat percentSlotWidth = [@"100%" sizeWithAttributes:percentAttrs].width;
    CGFloat labelToBar = 2.25;
    CGFloat barToPercent = 2.25;

    [label drawAtPoint:NSMakePoint(leftInset, y - 0.7) withAttributes:labelAttrs];

    NSString *pct = percent ? [NSString stringWithFormat:@"%.0f%%", percent.doubleValue] : @"--";
    CGFloat percentWidth = [pct sizeWithAttributes:percentAttrs].width;
    CGFloat percentSlotX = NSWidth(self.bounds) - rightInset - percentSlotWidth;
    CGFloat percentX = percentSlotX + percentSlotWidth - percentWidth;

    CGFloat barX = leftInset + labelSlotWidth + labelToBar;
    CGFloat barEnd = percentSlotX - barToPercent;
    CGFloat totalWidth = MAX(1.0, barEnd - barX);
    CGFloat gap = 0.50;
    CGFloat segmentWidth = MAX(1.0, (totalWidth - gap * 9.0) / 10.0);
    CGFloat barHeight = 6.8, barY = y + 1.0;
    double remaining = percent ? CUClampPercent(percent.doubleValue) : 0.0;
    for (NSInteger i = 0; i < 10; i++) {
        CGFloat x = barX + i * (segmentWidth + gap);
        NSRect rect = NSMakeRect(x, barY, segmentWidth, barHeight);
        CGFloat radius = MIN(segmentWidth / 2.0, barHeight / 2.0);
        NSBezierPath *base = [NSBezierPath bezierPathWithRoundedRect:rect xRadius:radius yRadius:radius];
        [[[NSColor secondaryLabelColor] colorWithAlphaComponent:0.28] setFill];
        [base fill];
        if (!percent) continue;
        double segmentStart = i * 10.0;
        double fraction = fmin(1.0, fmax(0.0, (remaining - segmentStart) / 10.0));
        if (fraction <= 0) continue;
        [NSGraphicsContext saveGraphicsState];
        [[NSBezierPath bezierPathWithRect:NSMakeRect(NSMinX(rect), NSMinY(rect), NSWidth(rect) * fraction, NSHeight(rect))] addClip];
        // 使用更沉稳的固定绿 #2F9B56，避免深色菜单栏上过亮。
        [[NSColor colorWithSRGBRed:47.0/255.0 green:155.0/255.0 blue:86.0/255.0 alpha:1.0] setFill];
        [base fill];
        [NSGraphicsContext restoreGraphicsState];
    }

    [pct drawAtPoint:NSMakePoint(percentX, y - 0.8) withAttributes:percentAttrs];
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];
    [self drawRow:@"5h" percent:self.fiveHourPercent y:1.5];
    [self drawRow:@"7d" percent:self.sevenDayPercent y:12.5];
}
@end

typedef NS_ENUM(NSInteger, CUTokenRange) { CUTokenRangeToday = 0, CUTokenRangeAll = 1 };

@interface TokenMenuView : NSView
@property(nonatomic, strong) NSTextField *titleLabel;
@property(nonatomic, strong) NSSegmentedControl *segmented;
@property(nonatomic, strong) NSTextField *valueLabel;
@property(nonatomic) CUTokenRange range;
@property(nonatomic, copy) void (^onRangeChanged)(CUTokenRange range);
- (void)updateWithSnapshot:(CUUsageSnapshot *)snapshot;
@end

@implementation TokenMenuView
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _range = CUTokenRangeToday;
        _titleLabel = [NSTextField labelWithString:@"账号 Token"];
        _titleLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
        [self addSubview:_titleLabel];

        _segmented = [[NSSegmentedControl alloc] initWithFrame:NSZeroRect];
        _segmented.segmentCount = 2;
        [_segmented setLabel:@"当天" forSegment:0];
        [_segmented setLabel:@"全部" forSegment:1];
        _segmented.trackingMode = NSSegmentSwitchTrackingSelectOne;
        _segmented.selectedSegment = 0;
        _segmented.controlSize = NSControlSizeSmall;
        _segmented.target = self;
        _segmented.action = @selector(rangeChanged:);
        [self addSubview:_segmented];

        _valueLabel = [NSTextField labelWithString:@"总计：--"];
        _valueLabel.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightRegular];
        _valueLabel.textColor = [NSColor secondaryLabelColor];
        [self addSubview:_valueLabel];
    }
    return self;
}
- (void)layout {
    [super layout];
    self.titleLabel.frame = NSMakeRect(12, 8, 90, 20);
    self.segmented.frame = NSMakeRect(NSWidth(self.bounds) - 130, 6, 118, 24);
    self.valueLabel.frame = NSMakeRect(12, 34, NSWidth(self.bounds) - 24, 20);
}
- (void)rangeChanged:(id)sender {
    self.range = (self.segmented.selectedSegment == 0) ? CUTokenRangeToday : CUTokenRangeAll;
    if (self.onRangeChanged) self.onRangeChanged(self.range);
}
- (void)updateWithSnapshot:(CUUsageSnapshot *)snapshot {
    NSNumber *value = (self.range == CUTokenRangeToday) ? snapshot.todayTokens : snapshot.lifetimeTokens;
    self.valueLabel.stringValue = [NSString stringWithFormat:@"总计：%@", CUFormatTokenCount(value)];
}
@end

@interface AppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property(nonatomic, strong) CodexAppServerClient *client;
@property(nonatomic, strong) NSMenu *menu;
@property(nonatomic, strong) NSStatusItem *statusItem;
@property(nonatomic, strong) StatusQuotaView *statusView;
@property(nonatomic, strong) TokenMenuView *tokenView;
@property(nonatomic, strong) NSMenuItem *fiveHourItem;
@property(nonatomic, strong) NSMenuItem *sevenDayItem;
@property(nonatomic, strong) NSMenuItem *resetItem;
@property(nonatomic, strong) NSMenuItem *refreshTimeItem;
@property(nonatomic, strong) NSMenuItem *loginItem;
@property(nonatomic, strong) CUUsageSnapshot *snapshot;
@property(nonatomic, copy) NSString *lastError;
@property(nonatomic) BOOL refreshInFlight;
@property(nonatomic, strong) NSTimer *timer;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    self.client = [[CodexAppServerClient alloc] init];
    self.menu = [[NSMenu alloc] initWithTitle:@""];
    [self loadCache];
    [self setupStatusItem];
    [self setupMenu];
    [self updateUI];
    [self refreshForce:YES];
    __weak typeof(self) weakSelf = self;
    self.timer = [NSTimer timerWithTimeInterval:300 repeats:YES block:^(__unused NSTimer *timer) {
        [weakSelf refreshForce:YES];
    }];
    [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
}

- (void)applicationWillTerminate:(NSNotification *)notification { [self.timer invalidate]; }

- (void)setupStatusItem {
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:70.0];
    NSStatusBarButton *button = self.statusItem.button;
    button.title = @"";
    button.image = nil;
    button.toolTip = @"codexusage";

    // 保留 NSStatusBarButton 自带的原生 hover/点击灰色区域。
    // 系统按钮的内容区域左右会天然留白；仅把绘制层向两侧“借”5.5pt，
    // 不改变 status item 的 70pt 占位，也不自绘灰色背景。
    // StatusQuotaView 的 hitTest 返回 nil，因此点击仍由系统按钮/菜单处理。
    const CGFloat contentBleed = 5.5;
    NSRect contentFrame = NSInsetRect(button.bounds, -contentBleed, 0.0);
    self.statusView = [[StatusQuotaView alloc] initWithFrame:contentFrame];
    [button addSubview:self.statusView];
    self.statusItem.menu = self.menu;
}

- (NSMenuItem *)infoItem:(NSString *)title bold:(BOOL)bold {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
    item.enabled = NO;
    if (bold) {
        item.attributedTitle = [[NSAttributedString alloc] initWithString:title attributes:@{
            NSFontAttributeName: [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold],
            NSForegroundColorAttributeName: [NSColor secondaryLabelColor]
        }];
    }
    return item;
}

- (void)setupMenu {
    self.menu.delegate = self;
    self.menu.autoenablesItems = NO;
    [self.menu addItem:[self infoItem:@"实时额度" bold:YES]];
    self.fiveHourItem = [self infoItem:@"5小时：--" bold:NO];
    self.sevenDayItem = [self infoItem:@"7天：--" bold:NO];
    self.resetItem = [self infoItem:@"重置：-- / --" bold:NO];
    self.refreshTimeItem = [self infoItem:@"最近刷新：--" bold:NO];
    [self.menu addItem:self.fiveHourItem]; [self.menu addItem:self.sevenDayItem];
    [self.menu addItem:self.resetItem]; [self.menu addItem:self.refreshTimeItem];
    [self.menu addItem:[NSMenuItem separatorItem]];

    self.tokenView = [[TokenMenuView alloc] initWithFrame:NSMakeRect(0, 0, 268, 62)];
    __weak typeof(self) weakSelf = self;
    self.tokenView.onRangeChanged = ^(__unused CUTokenRange range) { [weakSelf.tokenView updateWithSnapshot:weakSelf.snapshot]; };
    NSMenuItem *tokenItem = [[NSMenuItem alloc] init];
    tokenItem.view = self.tokenView;
    [self.menu addItem:tokenItem];
    [self.menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *refresh = [[NSMenuItem alloc] initWithTitle:@"刷新" action:@selector(refreshClicked:) keyEquivalent:@"r"];
    refresh.keyEquivalentModifierMask = NSEventModifierFlagCommand; refresh.target = self; refresh.enabled = YES;
    [self.menu addItem:refresh];

    self.loginItem = [[NSMenuItem alloc] initWithTitle:@"开机启动" action:@selector(toggleLogin:) keyEquivalent:@""];
    self.loginItem.target = self; self.loginItem.enabled = YES; [self.menu addItem:self.loginItem];

    NSMenuItem *openCodex = [[NSMenuItem alloc] initWithTitle:@"打开 Codex" action:@selector(openCodexClicked:) keyEquivalent:@"o"];
    openCodex.keyEquivalentModifierMask = NSEventModifierFlagCommand; openCodex.target = self; openCodex.enabled = YES;
    [self.menu addItem:openCodex];

    [self.menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *clear = [[NSMenuItem alloc] initWithTitle:@"清除本地缓存…" action:@selector(clearCacheClicked:) keyEquivalent:@""];
    clear.target = self; clear.enabled = YES; [self.menu addItem:clear];
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:@"退出 codexusage" action:@selector(quitClicked:) keyEquivalent:@"q"];
    quit.keyEquivalentModifierMask = NSEventModifierFlagCommand; quit.target = self; quit.enabled = YES; [self.menu addItem:quit];
    [self updateLoginItem];
}

- (void)menuWillOpen:(NSMenu *)menu {
    if (self.snapshot.fetchedAt && [[NSDate date] timeIntervalSinceDate:self.snapshot.fetchedAt] < 60.0) return;
    [self refreshForce:NO];
}

- (void)refreshForce:(BOOL)force {
    if (self.refreshInFlight) return;
    if (!force && self.snapshot.fetchedAt && [[NSDate date] timeIntervalSinceDate:self.snapshot.fetchedAt] < 60.0) return;
    self.refreshInFlight = YES;
    __weak typeof(self) weakSelf = self;
    [self.client fetchWithCompletion:^(CUUsageSnapshot *snapshot, NSString *errorMessage) {
        AppDelegate *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.refreshInFlight = NO;
        if (snapshot) {
            strongSelf.snapshot = snapshot; strongSelf.lastError = nil; [strongSelf saveCache:snapshot];
        } else {
            strongSelf.lastError = errorMessage ?: @"读取失败";
        }
        [strongSelf updateUI];
    }];
}

- (void)updateUI {
    self.statusView.fiveHourPercent = self.snapshot.fiveHourRemaining;
    self.statusView.sevenDayPercent = self.snapshot.sevenDayRemaining;
    self.fiveHourItem.title = [NSString stringWithFormat:@"5小时：%@", CUFormatPercent(self.snapshot.fiveHourRemaining)];
    self.sevenDayItem.title = [NSString stringWithFormat:@"7天：%@", CUFormatPercent(self.snapshot.sevenDayRemaining)];
    self.resetItem.title = [NSString stringWithFormat:@"重置：%@ / %@", CUFormatClock(self.snapshot.fiveHourResetAt), CUFormatSevenDayReset(self.snapshot.sevenDayResetAt)];
    if (self.lastError.length) self.refreshTimeItem.title = [NSString stringWithFormat:@"状态：%@", self.lastError];
    else if (self.snapshot.fetchedAt) self.refreshTimeItem.title = [NSString stringWithFormat:@"最近刷新：%@", CUFormatClock(self.snapshot.fetchedAt)];
    else self.refreshTimeItem.title = @"最近刷新：--";
    [self.tokenView updateWithSnapshot:self.snapshot];
    [self updateLoginItem];
}

- (void)refreshClicked:(id)sender { [self refreshForce:YES]; }

- (NSString *)launchAgentPath {
    return [NSHomeDirectory() stringByAppendingPathComponent:[@"Library/LaunchAgents/" stringByAppendingString:[CULaunchAgentID stringByAppendingString:@".plist"]]];
}

- (void)toggleLogin:(id)sender {
    NSString *path = [self launchAgentPath];
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:path]) {
        [fm removeItemAtPath:path error:nil];
        self.lastError = nil;
    } else {
        NSString *dir = [path stringByDeletingLastPathComponent];
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSDictionary *plist = @{
            @"Label": CULaunchAgentID,
            @"ProgramArguments": @[@"/Applications/codexusage.app/Contents/MacOS/codexusage"],
            @"RunAtLoad": @YES,
            @"KeepAlive": @NO
        };
        if (![plist writeToFile:path atomically:YES]) self.lastError = @"开机启动设置失败";
        else self.lastError = nil;
    }
    [self updateUI];
}

- (void)updateLoginItem {
    BOOL enabled = [[NSFileManager defaultManager] fileExistsAtPath:[self launchAgentPath]];
    self.loginItem.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
    self.loginItem.title = @"开机启动";
}

- (void)openCodexClicked:(id)sender {
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *direct in @[@"/Applications/ChatGPT.app", @"/Applications/Codex.app"]) {
        if ([fm fileExistsAtPath:direct]) {
            [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:direct]];
            return;
        }
    }
    for (NSString *name in @[@"ChatGPT", @"Codex"]) {
        NSURL *url = [[NSWorkspace sharedWorkspace] URLForApplicationWithBundleIdentifier:[name isEqualToString:@"Codex"] ? @"com.openai.codex" : @"com.openai.chat"];
        if (url) { [[NSWorkspace sharedWorkspace] openURL:url]; return; }
    }
}

- (void)clearCacheClicked:(id)sender {
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:CUCacheKey];
    self.snapshot = nil; self.lastError = nil; [self updateUI]; [self refreshForce:YES];
}
- (void)quitClicked:(id)sender { [NSApp terminate:nil]; }

- (void)saveCache:(CUUsageSnapshot *)snapshot { [[NSUserDefaults standardUserDefaults] setObject:[snapshot propertyList] forKey:CUCacheKey]; }
- (void)loadCache {
    NSDictionary *dict = [[NSUserDefaults standardUserDefaults] dictionaryForKey:CUCacheKey];
    self.snapshot = [CUUsageSnapshot fromPropertyList:dict];
}
@end

int main(void) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
