//
//  WTGuard.m  ·  v3（去掉 DNS interpose + 分阶段自诊断）
//
//  v1 的实测结果：键盘扩展正常（胶囊显示已拦 187 次），但主 App 一开就闪退。
//  主 App 是我们第一次注入的进程，所以先把「注入本身」和「拦截逻辑」分开验证。
//
//  v2 的做法：所有拦截按 stage 分级，主 App 默认 stage 0（只写日志，不做任何事）。
//  键盘上那个胶囊就是控制台：
//      单击  → 把 wtguard.log 的最后 15 行直接插进当前输入框（不用文件管理器）
//      长按  → 主 App 的 stage +1（0→1→2→3→0），下次启动 App 生效
//
//  分阶段含义：
//      S0  只加载、只写 PROBE 日志（验证注入与签名）
//      S1  + ObjC 层埋点 hook（KBIMEMgr / WBBusinessMgr / 各 SDK）
//      S2  + NSURLProtocol 域名/路径拦截
//      S3  + NSURLProtocol（v3 起不再有 DNS interpose，见下方说明）
//
//  另外两处加固：
//      · 所有 hook 与构造逻辑都包了 @try
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <netdb.h>
#import <dlfcn.h>
#import <stdatomic.h>
#import <QuartzCore/QuartzCore.h>

static NSString *const kGroupID        = @"group.com.tencent.wetype";
static NSString *const kKeyEnabled     = @"wtguard_enabled";
static NSString *const kKeyAllowCrash  = @"wtguard_allow_crash";
static NSString *const kKeyAllowUpload = @"wtguard_allow_uploads";
static NSString *const kKeyAppStage    = @"wtguard_app_stage";

static atomic_int  g_enabled = 1;
static atomic_int  g_stage   = 0;
static atomic_bool g_isApp   = false;

#pragma mark - 日志

static NSString *WTGLogPath(void) {
    static NSString *path = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURL *group = [[NSFileManager defaultManager]
                        containerURLForSecurityApplicationGroupIdentifier:kGroupID];
        if (group) path = [[group URLByAppendingPathComponent:@"wtguard.log"] path];
        if (!path) path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"wtguard.log"];
    });
    return path;
}

static NSMutableSet<NSString *> *WTGSeen(void) {
    static NSMutableSet *set = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ set = [NSMutableSet set]; });
    return set;
}

static void WTGLog(NSString *fmt, ...) {
    @autoreleasepool {
        va_list args; va_start(args, fmt);
        NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
        va_end(args);
        NSDateFormatter *f = [NSDateFormatter new];
        f.dateFormat = @"HH:mm:ss.SSS";
        NSString *line = [NSString stringWithFormat:@"%@ [%@] %@\n",
                          [f stringFromDate:[NSDate date]],
                          atomic_load(&g_isApp) ? @"app" : @"kb", msg];
        FILE *fp = fopen(WTGLogPath().UTF8String, "a");
        if (fp) { fputs(line.UTF8String, fp); fclose(fp); }
    }
}

static NSString *WTGLogTail(NSUInteger lines) {
    NSString *all = [NSString stringWithContentsOfFile:WTGLogPath()
                                              encoding:NSUTF8StringEncoding
                                                 error:NULL];
    if (all.length == 0) return @"(空日志)";
    NSArray *ls = [all componentsSeparatedByString:@"\n"];
    if (ls.count <= lines) return all;
    NSArray *tail = [ls subarrayWithRange:NSMakeRange(ls.count - lines, lines)];
    return [tail componentsJoinedByString:@"\n"];
}

#pragma mark - 状态

static void WTGLoadState(void) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    id en = [d objectForKey:kKeyEnabled];
    atomic_store(&g_enabled, en ? ([en boolValue] ? 1 : 0) : 1);
    id st = [d objectForKey:kKeyAppStage];
    int s = st ? [st intValue] : 0;
    atomic_store(&g_stage, MAX(0, MIN(3, s)));
}

static BOOL WTGOn(void)      { return atomic_load(&g_enabled) != 0; }
static int  WTGStage(void)   { return atomic_load(&g_stage); }
static BOOL WTGAllowUploads(void) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:kKeyAllowUpload];
    return v ? [v boolValue] : NO;
}
static BOOL WTGAllowCrash(void) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:kKeyAllowCrash];
    return v ? [v boolValue] : NO;
}

static NSUInteger WTGCount = 0;
static void WTGHit(NSString *what) {
    WTGCount++;
    WTGLog(@"拦截 %@ (累计 %lu)", what, (unsigned long)WTGCount);
}

#pragma mark - hook 工具

static void WTGHook(Class cls, SEL sel, IMP newImp, IMP *orig) {
    if (!cls || !sel) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    if (orig) *orig = method_getImplementation(m);
    method_setImplementation(m, newImp);
}

#pragma mark - S1：键盘扩展 KBIMEMgr

typedef void (*two_id_t)(id, SEL, id, id);
static two_id_t o_kb_report_pb, o_kb_report_b64, o_kb_report_inst, o_kb_report_sa;

static void g_kb_report_pb(id s, SEL c, id rid, id pb) {
    if (WTGOn()) { WTGHit([NSString stringWithFormat:@"KBIMEMgr reportID:pb: %@", rid]); return; }
    if (o_kb_report_pb) o_kb_report_pb(s, c, rid, pb);
}
static void g_kb_report_b64(id s, SEL c, id rid, id d) {
    if (WTGOn()) { WTGHit([NSString stringWithFormat:@"KBIMEMgr reportID:pbBase64Content: %@", rid]); return; }
    if (o_kb_report_b64) o_kb_report_b64(s, c, rid, d);
}
static void g_kb_report_inst(id s, SEL c, id rid, id pb) {
    if (WTGOn()) { WTGHit([NSString stringWithFormat:@"KBIMEMgr reportInstance:pb: %@", rid]); return; }
    if (o_kb_report_inst) o_kb_report_inst(s, c, rid, pb);
}
static void g_kb_report_sa(id s, SEL c, id rid, id pb) {
    if (WTGOn()) { WTGHit([NSString stringWithFormat:@"KBIMEMgr reportForStandAloneMode:pb: %@", rid]); return; }
    if (o_kb_report_sa) o_kb_report_sa(s, c, rid, pb);
}
static void g_kb_keystroke(id s, SEL c, id a, unsigned char t, id kc, id content) {
    if (WTGOn()) WTGHit(@"reportKeystroke(含 keyContent)");
}
static void g_kb_keystroke_end(id s, SEL c, id a, unsigned char t, id finalText) {
    if (WTGOn()) WTGHit(@"reportKeystrokeSessionEnd(含 sessionFinalText)");
}
static void g_kb_emoji(id s, SEL c, id a, id b, unsigned long long t, id text) {
    if (WTGOn()) WTGHit(@"reportEmojiEvent(含 beforeText)");
}
static void g_kb_sticker(id s, SEL c, id a, id b, id cand, id last) {
    if (WTGOn()) WTGHit(@"reportStickerEvent");
}
static void g_kb_candclick(id s, SEL c, id a, id b, id cands,
                           long long v, long long idx, long long src, long long panel,
                           unsigned long long n) {
    if (WTGOn()) WTGHit(@"reportCandidateClick(含候选词)");
}
static void g_kb_noarg(id s, SEL c) {
    if (WTGOn()) WTGHit([NSString stringWithFormat:@"KBIMEMgr %@", NSStringFromSelector(c)]);
}

#pragma mark - S1：主 App WBBusinessMgr

static two_id_t o_bb_rid_c, o_bb_rid_b, o_bb_dorid_b, o_bb_inst_c, o_bb_inst_b;

static void g_bb_rid_c(id s, SEL c, id rid, id v) {
    if (WTGOn()) { WTGHit([NSString stringWithFormat:@"WBBusinessMgr reportID:content: %@", rid]); return; }
    if (o_bb_rid_c) o_bb_rid_c(s, c, rid, v);
}
static void g_bb_rid_b(id s, SEL c, id rid, id v) {
    if (WTGOn()) { WTGHit([NSString stringWithFormat:@"WBBusinessMgr reportID:base64Content: %@", rid]); return; }
    if (o_bb_rid_b) o_bb_rid_b(s, c, rid, v);
}
static void g_bb_dorid_b(id s, SEL c, id rid, id v) {
    if (WTGOn()) { WTGHit([NSString stringWithFormat:@"WBBusinessMgr doReportID:base64Content: %@", rid]); return; }
    if (o_bb_dorid_b) o_bb_dorid_b(s, c, rid, v);
}
static void g_bb_inst_c(id s, SEL c, id rid, id v) {
    if (WTGOn()) { WTGHit([NSString stringWithFormat:@"WBBusinessMgr reportInstantID:content: %@", rid]); return; }
    if (o_bb_inst_c) o_bb_inst_c(s, c, rid, v);
}
static void g_bb_inst_b(id s, SEL c, id rid, id v) {
    if (WTGOn()) { WTGHit([NSString stringWithFormat:@"WBBusinessMgr reportInstantID:base64Content: %@", rid]); return; }
    if (o_bb_inst_b) o_bb_inst_b(s, c, rid, v);
}
static void g_bb_bugly(id s, SEL c, unsigned long long uin) {
    if (WTGOn()) WTGHit(@"WBBusinessMgr updateBuglyUserId");
}

#pragma mark - S1：SDK 埋点

typedef int (*ratio_t)(id, SEL, id);
static ratio_t o_ratio;
static int g_ratio(id s, SEL c, id rid) {
    if (WTGOn()) { WTGHit([NSString stringWithFormat:@"采样拒绝 %@", rid]); return 0; }
    return o_ratio ? o_ratio(s, c, rid) : 100;
}

static void g_noop(id s, SEL c) {
    if (WTGOn()) WTGHit([NSString stringWithFormat:@"%@ %@", NSStringFromClass([s class]), NSStringFromSelector(c)]);
}
static void g_noop_1(id s, SEL c, id a) { g_noop(s, c); }
static void g_noop_3(id s, SEL c, id a, id b, id d) { g_noop(s, c); }
static void g_noop_b(id s, SEL c, id a, id b, BOOL v) { g_noop(s, c); }
static void g_noop_bi(id s, SEL c, id a, id b, BOOL v, int i) { g_noop(s, c); }

#pragma mark - S2：NSURLProtocol

static NSArray<NSString *> *WTGBlockedHosts(void) {
    return @[ @"trace.qq.com", @"rqd.qq.com", @"rdelivery.qq.com", @"rconfig.qq.com",
              @"tdos.vip", @"weread.qq.com", @"bugly.qq.com", @"buglybugly.qq.com",
              @"android.bugly.qq.com" ];
}

static BOOL WTGHostBlocked(NSString *host) {
    if (host.length == 0) return NO;
    NSString *h = host.lowercaseString;
    for (NSString *b in WTGBlockedHosts()) {
        if ([h isEqualToString:b] || [h hasSuffix:[@"." stringByAppendingString:b]]) return YES;
    }
    return NO;
}

static BOOL WTGPathBlocked(NSURL *url) {
    if (WTGAllowUploads()) return NO;
    NSString *p = url.path.lowercaseString;
    if (p.length == 0) return NO;
    if ([p containsString:@"/upload-file"]) return YES;
    if ([p containsString:@"/v1/"] && [p containsString:@"upload-json"]) return YES;
    return NO;
}

@interface WTGBlockProtocol : NSURLProtocol @end
@implementation WTGBlockProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    if (!WTGOn()) return NO;
    static NSString *const kH = @"WTGHandled";
    if ([NSURLProtocol propertyForKey:kH inRequest:request]) return NO;
    NSURL *u = request.URL;
    if (WTGHostBlocked(u.host)) { WTGHit([NSString stringWithFormat:@"URL 域名 %@", u.host]); return YES; }
    if (WTGPathBlocked(u)) { WTGHit([NSString stringWithFormat:@"URL 路径 %@", u.path]); return YES; }
    return NO;
}
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)r { return r; }
- (void)startLoading {
    NSError *e = [NSError errorWithDomain:@"WTGuard" code:-999
                                 userInfo:@{NSLocalizedDescriptionKey: @"blocked"}];
    [self.client URLProtocol:self didFailWithError:e];
}
- (void)stopLoading {}
@end

#pragma mark - S3：DNS 拦截已移除（v3）

// v1/v2 用 __DATA,__interpose 替换 getaddrinfo，这是主 App 闪退的头号嫌疑：
//   该 interpose 在 dylib 一被 dyld 加载时就生效（早于 constructor），
//   而替换函数里要 dlsym(RTLD_NEXT) 取原函数；进程早期解析可能拿到空/错值，
//   一旦调用就是立刻崩溃 —— 而扩展是在进程跑热之后才加载，所以扩展没事。
// v3 直接删掉这一层：埋点收口 + NSURLProtocol 已经覆盖绝大部分，
// 换取「主 App 一定能启动」这个确定性。

#pragma mark - 胶囊控制台（仅键盘扩展）

static const void *kChipKey = &kChipKey;
static const void *kTapKey  = &kTapKey;
static const void *kLongKey = &kLongKey;

@interface WTGChip : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, weak) UIViewController *host;
- (void)render;
@end

@implementation WTGChip

- (UILabel *)label { return objc_getAssociatedObject(self.host, kChipKey); }

- (void)render {
    UILabel *l = [self label];
    if (!l) return;
    UILabel *chip = l;
    chip.text = [NSString stringWithFormat:@"盾%lu·S%d", (unsigned long)WTGCount, WTGStage()];
    chip.backgroundColor = WTGOn() ? [UIColor colorWithRed:0.15 green:0.45 blue:0.85 alpha:0.92]
                                   : [UIColor colorWithWhite:0.4 alpha:0.8];
}

- (void)insertTail {
    NSString *tail = WTGLogTail(15);
    if (tail.length > 900) tail = [tail substringFromIndex:tail.length - 900];
    UIViewController *vc = self.host;
    if (![vc isKindOfClass:[UIInputViewController class]]) return;
    id proxy = [(UIInputViewController *)vc textDocumentProxy];
    if ([proxy respondsToSelector:@selector(insertText:)]) [proxy insertText:tail];
    WTGLog(@"日志尾已插入（15 行）");
}

- (void)tap:(UITapGestureRecognizer *)g {
    UIView *v = g.view; UILabel *chip = [self label];
    if (!v || !chip) return;
    CGPoint p = [g locationInView:v];
    CGRect f = [chip.superview convertRect:chip.frame toView:v];
    if (!CGRectContainsPoint(CGRectInset(f, -8, -8), p)) return;
    [self insertTail];
    [self render];
}

- (void)longPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    UIView *v = g.view; UILabel *chip = [self label];
    if (!v || !chip) return;
    CGPoint p = [g locationInView:v];
    CGRect f = [chip.superview convertRect:chip.frame toView:v];
    if (!CGRectContainsPoint(CGRectInset(f, -10, -10), p)) return;

    int next = (WTGStage() + 1) % 4;
    [[NSUserDefaults standardUserDefaults] setInteger:next forKey:kKeyAppStage];
    [[NSUserDefaults standardUserDefaults] synchronize];
    atomic_store(&g_stage, next);
    WTGLog(@"主 App stage → S%d（重启微信输入法后生效）", next);
    [self render];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)o { return YES; }
@end

static void WTGLayoutChip(UIViewController *vc) {
    UIView *container = vc.view.window ?: vc.view;
    UILabel *chip = objc_getAssociatedObject(vc, kChipKey);
    if (!chip) {
        chip = [UILabel new];
        chip.font = [UIFont systemFontOfSize:10 weight:UIFontWeightSemibold];
        chip.textColor = [UIColor whiteColor];
        chip.textAlignment = NSTextAlignmentCenter;
        chip.layer.cornerRadius = 7;
        chip.layer.masksToBounds = YES;
        objc_setAssociatedObject(vc, kChipKey, chip, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        WTGChip *h = [WTGChip new];
        h.host = vc;

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:h action:@selector(tap:)];
        tap.delegate = h; tap.cancelsTouchesInView = NO;
        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
                                            initWithTarget:h action:@selector(longPress:)];
        lp.minimumPressDuration = 0.6; lp.delegate = h; lp.cancelsTouchesInView = NO;

        if (!objc_getAssociatedObject(container, kTapKey)) {
            [container addGestureRecognizer:tap];
            [container addGestureRecognizer:lp];
            objc_setAssociatedObject(container, kTapKey, h, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(container, kLongKey, h, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        WTGLog(@"胶囊控制台已装");
    }
    if (chip.superview != container) [container addSubview:chip];

    CGRect anchor = [vc.view convertRect:vc.view.bounds toView:container];
    chip.frame = CGRectMake(anchor.origin.x + 6, anchor.origin.y + 4, 64, 19);
    [chip.superview bringSubviewToFront:chip];

    WTGChip *h = objc_getAssociatedObject(container, kTapKey);
    [h render];
}

#pragma mark - 安装

static void (*o_viewDidLoad)(id, SEL);
static void (*o_viewDidLayout)(id, SEL);

static void g_viewDidLoad(id self, SEL c) {
    if (o_viewDidLoad) o_viewDidLoad(self, c);
    @try { WTGLayoutChip((UIViewController *)self); } @catch (NSException *e) {}
}
static void g_viewDidLayout(id self, SEL c) {
    if (o_viewDidLayout) o_viewDidLayout(self, c);
    @try { WTGLayoutChip((UIViewController *)self); } @catch (NSException *e) {}
}

static void WTGInstallAppHooks(int stage) {
    Class bb = objc_getClass("WBBusinessMgr");
    if (bb) {
        WTGHook(bb, @selector(reportID:content:), (IMP)g_bb_rid_c, (IMP *)&o_bb_rid_c);
        WTGHook(bb, @selector(reportID:base64Content:), (IMP)g_bb_rid_b, (IMP *)&o_bb_rid_b);
        WTGHook(bb, @selector(doReportID:base64Content:), (IMP)g_bb_dorid_b, (IMP *)&o_bb_dorid_b);
        WTGHook(bb, @selector(reportInstantID:content:), (IMP)g_bb_inst_c, (IMP *)&o_bb_inst_c);
        WTGHook(bb, @selector(reportInstantID:base64Content:), (IMP)g_bb_inst_b, (IMP *)&o_bb_inst_b);
        WTGHook(bb, @selector(updateBuglyUserId:), (IMP)g_bb_bugly, NULL);
    }
    WTGLog(@"S%d 业务收口 hook 完成", stage);
    if (stage < 2) return;

    Class rd = objc_getClass("RDeliveyDataReporter");
    if (rd) WTGHook(rd, @selector(reportEvent:params:forceReport:), (IMP)g_noop_b, NULL);
    Class raft = objc_getClass("RAFTMeasureService");
    if (raft) {
        WTGHook(raft, @selector(reportSuccess:key:success:), (IMP)g_noop_b, NULL);
        WTGHook(raft, @selector(reportSuccess:key:success:samplingRate:), (IMP)g_noop_bi, NULL);
        WTGHook(raft, @selector(reportDistribution:key:sValue:), (IMP)g_noop_3, NULL);
        WTGHook(raft, @selector(reportStartup:), (IMP)g_noop_1, NULL);
    }
    if (!WTGAllowCrash()) {
        Class dau = objc_getClass("BuglyDAUReporter");
        if (dau) {
            WTGHook(dau, @selector(reportDAUEvent), (IMP)g_noop, NULL);
            WTGHook(dau, @selector(reportDAUWithActivateModules:), (IMP)g_noop_1, NULL);
        }
        Class bly = objc_getClass("BLYAnalyticsManager");
        if (bly) WTGHook(bly, @selector(reportAnalyticsEvent), (IMP)g_noop, NULL);
        Class mt = objc_getClass("WBMetrics");
        if (mt) WTGHook(mt, @selector(uploadDiagnosticZipFile), (IMP)g_noop, NULL);
    }
    WTGLog(@"S%d SDK 埋点 hook 完成", stage);
}

static void WTGInstallHooks(void) {
    Class kbi = objc_getClass("KBIMEMgr");
    if (kbi) {
        WTGHook(kbi, @selector(reportID:pb:), (IMP)g_kb_report_pb, (IMP *)&o_kb_report_pb);
        WTGHook(kbi, @selector(reportID:pbBase64Content:), (IMP)g_kb_report_b64, (IMP *)&o_kb_report_b64);
        WTGHook(kbi, @selector(reportInstance:pb:), (IMP)g_kb_report_inst, (IMP *)&o_kb_report_inst);
        WTGHook(kbi, @selector(reportForStandAloneMode:pb:), (IMP)g_kb_report_sa, (IMP *)&o_kb_report_sa);
        WTGHook(kbi, @selector(reportKeystrokeForSession:keyType:keyCode:keyContent:), (IMP)g_kb_keystroke, NULL);
        WTGHook(kbi, @selector(reportKeystrokeSessionEndForSession:triggerType:sessionFinalText:), (IMP)g_kb_keystroke_end, NULL);
        WTGHook(kbi, @selector(reportEmojiEvent:session:emojiType:beforeText:), (IMP)g_kb_emoji, NULL);
        WTGHook(kbi, @selector(reportStickerEvent:session:sourceCandidate:lastDisplayCandidate:), (IMP)g_kb_sticker, NULL);
        WTGHook(kbi, @selector(reportCandidateClick:session:candidates:cloudServiceVersion:firstScreenFullVisibleLastCellIndex:hwClickSource:currentPanelType:typingNum:), (IMP)g_kb_candclick, NULL);
        WTGHook(kbi, @selector(reportProcessInfo), (IMP)g_kb_noarg, NULL);
        WTGHook(kbi, @selector(reportFullAccessStat), (IMP)g_kb_noarg, NULL);
    }

    Class bb = objc_getClass("WBBusinessMgr");
    if (bb) {
        WTGHook(bb, @selector(reportID:content:), (IMP)g_bb_rid_c, (IMP *)&o_bb_rid_c);
        WTGHook(bb, @selector(reportID:base64Content:), (IMP)g_bb_rid_b, (IMP *)&o_bb_rid_b);
        WTGHook(bb, @selector(doReportID:base64Content:), (IMP)g_bb_dorid_b, (IMP *)&o_bb_dorid_b);
        WTGHook(bb, @selector(reportInstantID:content:), (IMP)g_bb_inst_c, (IMP *)&o_bb_inst_c);
        WTGHook(bb, @selector(reportInstantID:base64Content:), (IMP)g_bb_inst_b, (IMP *)&o_bb_inst_b);
        WTGHook(bb, @selector(updateBuglyUserId:), (IMP)g_bb_bugly, NULL);
    }

    // 注：v1 曾把 sampleRatioForReportID: 改成返回 0，怀疑正是主 App 闪退的原因之一
    // （调用方若把它当除数 / 取模基数就会 SIGFPE）。这里不再动它，靠上面的收口拦就够了。
    Class rd = objc_getClass("RDeliveyDataReporter");
    if (rd) WTGHook(rd, @selector(reportEvent:params:forceReport:), (IMP)g_noop_b, NULL);
    Class raft = objc_getClass("RAFTMeasureService");
    if (raft) {
        WTGHook(raft, @selector(reportSuccess:key:success:), (IMP)g_noop_b, NULL);
        WTGHook(raft, @selector(reportSuccess:key:success:samplingRate:), (IMP)g_noop_bi, NULL);
        WTGHook(raft, @selector(reportDistribution:key:sValue:), (IMP)g_noop_3, NULL);
        WTGHook(raft, @selector(reportStartup:), (IMP)g_noop_1, NULL);
    }
    if (!WTGAllowCrash()) {
        Class dau = objc_getClass("BuglyDAUReporter");
        if (dau) {
            WTGHook(dau, @selector(reportDAUEvent), (IMP)g_noop, NULL);
            WTGHook(dau, @selector(reportDAUWithActivateModules:), (IMP)g_noop_1, NULL);
        }
        Class bly = objc_getClass("BLYAnalyticsManager");
        if (bly) WTGHook(bly, @selector(reportAnalyticsEvent), (IMP)g_noop, NULL);
        Class mt = objc_getClass("WBMetrics");
        if (mt) WTGHook(mt, @selector(uploadDiagnosticZipFile), (IMP)g_noop, NULL);
    }
    WTGLog(@"S1 hook 完成");
}

__attribute__((constructor)) static void wtg_init(void) {
    @autoreleasepool {
        NSString *bundle = [[NSBundle mainBundle] bundlePath];
        BOOL inApp = [bundle hasSuffix:@".app"];
        atomic_store(&g_isApp, inApp);
        WTGLoadState();

        WTGLog(@"===== PROBE-1 loaded stage=S%d app=%d path=%@ =====",
               WTGStage(), (int)inApp, bundle.lastPathComponent);

        @try {
            if (!inApp) {
                // 键盘扩展：一直全开（上一版已验证可用）
                atomic_store(&g_stage, 3);
                WTGInstallHooks();
                [NSURLProtocol registerClass:[WTGBlockProtocol class]];
                Class vc = objc_getClass("WBInputViewController");
                WTGHook(vc, @selector(viewDidLoad), (IMP)g_viewDidLoad, (IMP *)&o_viewDidLoad);
                WTGHook(vc, @selector(viewDidLayoutSubviews), (IMP)g_viewDidLayout, (IMP *)&o_viewDidLayout);
                WTGLog(@"键盘扩展：S3 全量拦截已启用");
            } else {
                int s = WTGStage();
                if (s >= 1) { WTGInstallAppHooks(s); }
                if (s >= 3) { [NSURLProtocol registerClass:[WTGBlockProtocol class]]; }
                // 注意：主 App 的 S3 不再包含 DNS 层（v3 已移除 interpose）
                WTGLog(@"主 App：S%d 已启用（S0=只观测 S1=埋点 S2=URL S3=DNS）", s);
            }
        } @catch (NSException *e) {
            WTGLog(@"init 异常 %@", e);
        }

        WTGLog(@"===== PROBE-2 init done =====");
    }
}
