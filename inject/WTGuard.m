//
//  WTGuard.m  ·  v1
//
//  隐私守卫：把微信输入法的「非必要上报」全部掐掉。
//
//  三层拦截，越往下越底层：
//    ① 业务埋点收口（最精准）
//       - KBIMEMgr  (键盘扩展)  reportID:pb: / reportKeystroke* / reportCandidateClick* …
//       - WBBusinessMgr (主 App) reportID:content: / doReportID: / reportInstantID: …
//       这些方法直接 return，包都不会被构造，更不会进队列。
//    ② 第三方 SDK 埋点
//       RDelivery / RAFTMeasure / Bugly DAU / BLYAnalytics / MetricKit 诊断包
//       + WBReportSampleRatioMgr 采样率直接返回 0（就算前面漏了也不会发）
//    ③ 网络层兜底
//       - NSURLProtocol：按域名 + 路径拦 HTTP(S)
//       - getaddrinfo interpose：按域名拦「自己实现 TCP 栈」的那部分（灯塔/RQD/配置）
//         顺便把解析过的域名写进日志 —— 这是拿来看「还有谁在连」的
//
//  只拦上报，不拦功能：云候选、语音识别、剪贴板同步、表情下载、字典更新都放行。
//  开关：App Group 里的 NSUserDefaults，键 wtguard_enabled（默认 YES）。
//  键盘上有个小胶囊「盾 N」，点一下切开关，N 是已拦次数。
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <netdb.h>
#import <dlfcn.h>
#import <sys/socket.h>
#import <QuartzCore/QuartzCore.h>

static NSString *const kGroupID      = @"group.com.tencent.wetype";
static NSString *const kKeyEnabled   = @"wtguard_enabled";
static NSString *const kKeyAllowCrash = @"wtguard_allow_crash";

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
        NSString *line = [NSString stringWithFormat:@"%@ [guard] %@\n",
                          [f stringFromDate:[NSDate date]], msg];
        NSLog(@"[wtguard] %@", msg);
        FILE *fp = fopen(WTGLogPath().UTF8String, "a");
        if (fp) { fputs(line.UTF8String, fp); fclose(fp); }
    }
}

#pragma mark - 开关 / 计数

static BOOL WTGEnabled(void) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:kKeyEnabled];
    if (!v) return YES;                 // 默认开
    return [v boolValue];
}

static BOOL WTGAllowCrash(void) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:kKeyAllowCrash];
    return v ? [v boolValue] : NO;      // 默认也拦
}

static void WTGSetEnabled(BOOL on) {
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:kKeyEnabled];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

static NSUInteger WTGCount = 0;

static void WTGHit(NSString *what) {
    WTGCount++;
    WTGLog(@"拦截 %@ (累计 %lu)", what, (unsigned long)WTGCount);
}

#pragma mark - hook 工具

static void WTGHook(Class cls, SEL sel, IMP newImp, IMP *orig) {
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    if (orig) *orig = method_getImplementation(m);
    method_setImplementation(m, newImp);
    WTGLog(@"hook %@@%@", NSStringFromClass(cls), NSStringFromSelector(sel));
}

#pragma mark - ① 键盘扩展侧：KBIMEMgr

typedef void (*kb_report_pb_t)(id, SEL, id, id);
static kb_report_pb_t orig_kb_reportID_pb;
static kb_report_pb_t orig_kb_reportID_b64;
static kb_report_pb_t orig_kb_reportInstance_pb;
static kb_report_pb_t orig_kb_reportStandalone_pb;

static void wtg_kb_reportID_pb(id self, SEL _cmd, id reportID, id pb) {
    if (WTGEnabled()) { WTGHit([NSString stringWithFormat:@"KBIMEMgr reportID:pb: %@", reportID]); return; }
    if (orig_kb_reportID_pb) orig_kb_reportID_pb(self, _cmd, reportID, pb);
}

static void wtg_kb_reportID_b64(id self, SEL _cmd, id reportID, id content) {
    if (WTGEnabled()) { WTGHit([NSString stringWithFormat:@"KBIMEMgr reportID:pbBase64Content: %@", reportID]); return; }
    if (orig_kb_reportID_b64) orig_kb_reportID_b64(self, _cmd, reportID, content);
}

static void wtg_kb_reportInstance_pb(id self, SEL _cmd, id reportID, id pb) {
    if (WTGEnabled()) { WTGHit([NSString stringWithFormat:@"KBIMEMgr reportInstance:pb: %@", reportID]); return; }
    if (orig_kb_reportInstance_pb) orig_kb_reportInstance_pb(self, _cmd, reportID, pb);
}

static void wtg_kb_reportStandalone_pb(id self, SEL _cmd, id reportID, id pb) {
    if (WTGEnabled()) { WTGHit([NSString stringWithFormat:@"KBIMEMgr reportForStandAloneMode:pb: %@", reportID]); return; }
    if (orig_kb_reportStandalone_pb) orig_kb_reportStandalone_pb(self, _cmd, reportID, pb);
}

// 按键 / 候选词 / 表情：内容类，直接丢
static void wtg_kb_keystroke(id self, SEL _cmd, id session, unsigned char keyType, id keyCode, id keyContent) {
    if (WTGEnabled()) { WTGHit(@"KBIMEMgr reportKeystroke (含 keyContent)"); return; }
}

static void wtg_kb_keystrokeEnd(id self, SEL _cmd, id session, unsigned char trigger, id finalText) {
    if (WTGEnabled()) { WTGHit(@"KBIMEMgr reportKeystrokeSessionEnd (含 sessionFinalText)"); return; }
}

static void wtg_kb_emoji(id self, SEL _cmd, id a, id b, unsigned long long c, id d) {
    if (WTGEnabled()) { WTGHit(@"KBIMEMgr reportEmojiEvent (含 beforeText)"); return; }
}

static void wtg_kb_sticker(id self, SEL _cmd, id a, id b, id c, id d) {
    if (WTGEnabled()) { WTGHit(@"KBIMEMgr reportStickerEvent"); return; }
}

static void wtg_kb_candidateClick(id self, SEL _cmd, id a, id b, id c,
                                  long long d, long long e, long long f, long long g,
                                  unsigned long long h) {
    if (WTGEnabled()) { WTGHit(@"KBIMEMgr reportCandidateClick (含候选词内容)"); return; }
}

static void wtg_kb_simple(id self, SEL _cmd) {
    if (WTGEnabled()) { WTGHit([NSString stringWithFormat:@"KBIMEMgr %@", NSStringFromSelector(_cmd)]); return; }
}

#pragma mark - ① 主 App 侧：WBBusinessMgr

typedef void (*bb_two_id_t)(id, SEL, id, id);
static bb_two_id_t orig_bb_reportID_content;
static bb_two_id_t orig_bb_reportID_b64;
static bb_two_id_t orig_bb_doReportID_b64;
static bb_two_id_t orig_bb_reportInstant_content;
static bb_two_id_t orig_bb_reportInstant_b64;

static void wtg_bb_reportID_content(id self, SEL _cmd, id reportID, id content) {
    if (WTGEnabled()) { WTGHit([NSString stringWithFormat:@"WBBusinessMgr reportID:content: %@", reportID]); return; }
    if (orig_bb_reportID_content) orig_bb_reportID_content(self, _cmd, reportID, content);
}
static void wtg_bb_reportID_b64(id self, SEL _cmd, id reportID, id content) {
    if (WTGEnabled()) { WTGHit([NSString stringWithFormat:@"WBBusinessMgr reportID:base64Content: %@", reportID]); return; }
    if (orig_bb_reportID_b64) orig_bb_reportID_b64(self, _cmd, reportID, content);
}
static void wtg_bb_doReportID_b64(id self, SEL _cmd, id reportID, id content) {
    if (WTGEnabled()) { WTGHit([NSString stringWithFormat:@"WBBusinessMgr doReportID:base64Content: %@", reportID]); return; }
    if (orig_bb_doReportID_b64) orig_bb_doReportID_b64(self, _cmd, reportID, content);
}
static void wtg_bb_reportInstant_content(id self, SEL _cmd, id reportID, id content) {
    if (WTGEnabled()) { WTGHit([NSString stringWithFormat:@"WBBusinessMgr reportInstantID:content: %@", reportID]); return; }
    if (orig_bb_reportInstant_content) orig_bb_reportInstant_content(self, _cmd, reportID, content);
}
static void wtg_bb_reportInstant_b64(id self, SEL _cmd, id reportID, id content) {
    if (WTGEnabled()) { WTGHit([NSString stringWithFormat:@"WBBusinessMgr reportInstantID:base64Content: %@", reportID]); return; }
    if (orig_bb_reportInstant_b64) orig_bb_reportInstant_b64(self, _cmd, reportID, content);
}

// 崩溃/日志不要绑定账号
static void wtg_bb_updateBuglyUserId(id self, SEL _cmd, unsigned long long uin) {
    if (WTGEnabled()) { WTGHit(@"WBBusinessMgr updateBuglyUserId (不上报 uin)"); return; }
}

#pragma mark - ② SDK 埋点

typedef int (*sampleRatio_t)(id, SEL, id);
static sampleRatio_t orig_sampleRatio;
static int wtg_sampleRatio(id self, SEL _cmd, id reportID) {
    if (WTGEnabled()) { WTGHit([NSString stringWithFormat:@"采样拒绝 %@", reportID]); return 0; }
    return orig_sampleRatio ? orig_sampleRatio(self, _cmd, reportID) : 100;
}

static void wtg_noop_v(id self, SEL _cmd) {
    if (WTGEnabled()) WTGHit(NSStringFromClass([self class]));
}

static void wtg_noop_2id_bool(id self, SEL _cmd, id a, id b, BOOL c) {
    if (WTGEnabled()) WTGHit([NSString stringWithFormat:@"%@ %@", NSStringFromClass([self class]),
                             NSStringFromSelector(_cmd)]);
}

static void wtg_noop_4(id self, SEL _cmd, id a, id b, BOOL c, int d) {
    if (WTGEnabled()) WTGHit([NSString stringWithFormat:@"%@ %@", NSStringFromClass([self class]),
                             NSStringFromSelector(_cmd)]);
}

static void wtg_noop_3(id self, SEL _cmd, id a, id b, id c) {
    if (WTGEnabled()) WTGHit([NSString stringWithFormat:@"%@ %@", NSStringFromClass([self class]),
                             NSStringFromSelector(_cmd)]);
}

static void wtg_noop_id(id self, SEL _cmd, id a) {
    if (WTGEnabled()) WTGHit([NSString stringWithFormat:@"%@ %@", NSStringFromClass([self class]),
                             NSStringFromSelector(_cmd)]);
}

#pragma mark - ③ 网络层：NSURLProtocol

static NSArray<NSString *> *WTGBlockedHosts(void) {
    return @[
        @"trace.qq.com",            // 灯塔
        @"rqd.qq.com",              // RQD 网络质量
        @"rdelivery.qq.com",        // RDelivery 指标
        @"rconfig.qq.com",          // 配置（上报侧）
        @"tdos.vip",                // rfix
        @"weread.qq.com",           // Sentry DSN 落点
        @"bugly.qq.com",
        @"buglybugly.qq.com",
        @"android.bugly.qq.com",
    ];
}

static BOOL WTGHostBlocked(NSString *host) {
    if (host.length == 0) return NO;
    host = host.lowercaseString;
    for (NSString *h in WTGBlockedHosts()) {
        if ([host isEqualToString:h] || [host hasSuffix:[@"." stringByAppendingString:h]]) return YES;
    }
    return NO;
}

static BOOL WTGPathBlocked(NSURL *url) {
    NSString *p = url.path.lowercaseString;
    if (p.length == 0) return NO;
    // 日志/反馈包上传（微信 CDN 上传模板）
    if ([p containsString:@"/upload-file"]) return YES;
    if ([p containsString:@"/custom/upload-file"]) return YES;
    if ([p containsString:@"/v1/" ] && [p containsString:@"upload-json"]) return YES;
    return NO;
}

@interface WTGBlockProtocol : NSURLProtocol @end

@implementation WTGBlockProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    if (!WTGEnabled()) return NO;
    static NSString *const kHandled = @"WTGHandled";
    if ([NSURLProtocol propertyForKey:kHandled inRequest:request]) return NO;
    NSURL *url = request.URL;
    if (WTGHostBlocked(url.host)) {
        WTGHit([NSString stringWithFormat:@"URL 域名 %@", url.host]);
        return YES;
    }
    if (WTGPathBlocked(url)) {
        WTGHit([NSString stringWithFormat:@"URL 路径 %@", url.path]);
        return YES;
    }
    return NO;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }

- (void)startLoading {
    NSError *err = [NSError errorWithDomain:@"WTGuard" code:-999
                                   userInfo:@{NSLocalizedDescriptionKey: @"blocked by WTGuard"}];
    [self.client URLProtocol:self didFailWithError:err];
}

- (void)stopLoading {}

@end

#pragma mark - ③ 网络层：getaddrinfo interpose

typedef int (*getaddrinfo_t)(const char *, const char *, const struct addrinfo *, struct addrinfo **);
static getaddrinfo_t WTGRealGetAddrInfo;

static int wtg_getaddrinfo(const char *node, const char *service,
                           const struct addrinfo *hints, struct addrinfo **res) {
    if (!WTGRealGetAddrInfo) WTGRealGetAddrInfo = (getaddrinfo_t)dlsym(RTLD_NEXT, "getaddrinfo");
    if (node && WTGEnabled()) {
        NSString *host = [NSString stringWithUTF8String:node];
        BOOL fresh = NO;
        @synchronized (WTGSeen()) {
            if (![WTGSeen() containsObject:host]) {
                [WTGSeen() addObject:host];
                fresh = YES;
            }
        }
        if (fresh) WTGLog(@"DNS %@", host);   // 顺带留一份「还有谁在连」的清单
        if (WTGHostBlocked(host)) {
            WTGHit([NSString stringWithFormat:@"DNS 拦截 %@", host]);
            return EAI_NONAME;
        }
    }
    return WTGRealGetAddrInfo ? WTGRealGetAddrInfo(node, service, hints, res) : EAI_FAIL;
}

__attribute__((used, section("__DATA,__interpose")))
static struct { const void *replacement; const void *replacee; } _wtg_interpose_getaddrinfo = {
    (const void *)(uintptr_t)&wtg_getaddrinfo,
    (const void *)(uintptr_t)&getaddrinfo,
};

#pragma mark - 键盘上的小胶囊

static const void *kChipKey    = &kChipKey;
static const void *kChipGestureKey = &kChipGestureKey;

@interface WTGChipHandler : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, weak) UIViewController *host;
@end

@implementation WTGChipHandler

- (void)render {
    UILabel *chip = objc_getAssociatedObject(self.host, kChipKey);
    if (!chip) return;
    BOOL on = WTGEnabled();
    chip.text = [NSString stringWithFormat:@"盾 %lu", (unsigned long)WTGCount];
    chip.backgroundColor = on ? [UIColor colorWithRed:0.15 green:0.45 blue:0.85 alpha:0.92]
                              : [UIColor colorWithWhite:0.35 alpha:0.85];
    chip.alpha = on ? 1.0 : 0.65;
}

- (void)tap:(UITapGestureRecognizer *)g {
    UIView *v = g.view;
    UILabel *chip = objc_getAssociatedObject(self.host, kChipKey);
    if (!v || !chip) return;
    CGPoint p = [g locationInView:v];
    CGRect f = [chip.superview convertRect:chip.frame toView:v];
    if (!CGRectContainsPoint(CGRectInset(f, -8, -8), p)) return;
    WTGSetEnabled(!WTGEnabled());
    WTGLog(@"守卫开关 → %@", WTGEnabled() ? @"开" : @"关");
    [self render];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)o {
    return YES;
}
@end

static void WTGLayoutChip(UIViewController *vc) {
    UIView *container = vc.view.window ?: vc.view;
    UILabel *chip = objc_getAssociatedObject(vc, kChipKey);
    if (!chip) {
        chip = [UILabel new];
        chip.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
        chip.textColor = [UIColor whiteColor];
        chip.textAlignment = NSTextAlignmentCenter;
        chip.layer.cornerRadius = 8;
        chip.layer.masksToBounds = YES;
        objc_setAssociatedObject(vc, kChipKey, chip, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        WTGChipHandler *h = [WTGChipHandler new];
        h.host = vc;
        objc_setAssociatedObject(chip, kChipGestureKey, h, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        UITapGestureRecognizer *g = [[UITapGestureRecognizer alloc] initWithTarget:h action:@selector(tap:)];
        g.delegate = h;
        g.cancelsTouchesInView = NO;
        if (!objc_getAssociatedObject(container, kChipGestureKey)) {
            [container addGestureRecognizer:g];
            objc_setAssociatedObject(container, kChipGestureKey, @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        WTGLog(@"胶囊已装");
    }
    if (chip.superview != container) [container addSubview:chip];

    CGRect anchor = [vc.view convertRect:vc.view.bounds toView:container];
    chip.frame = CGRectMake(anchor.origin.x + 6, anchor.origin.y + 6, 54, 20);
    [chip.superview bringSubviewToFront:chip];

    WTGChipHandler *h = objc_getAssociatedObject(chip, kChipGestureKey);
    [h render];
}

#pragma mark - 安装

static void (*orig_viewDidLoad)(id, SEL);
static void (*orig_viewDidLayout)(id, SEL);

static void wtg_viewDidLoad(id self, SEL _cmd) {
    if (orig_viewDidLoad) orig_viewDidLoad(self, _cmd);
    @try { WTGLayoutChip((UIViewController *)self); }
    @catch (NSException *e) { WTGLog(@"chip 异常 %@", e); }
}

static void wtg_viewDidLayout(id self, SEL _cmd) {
    if (orig_viewDidLayout) orig_viewDidLayout(self, _cmd);
    @try { WTGLayoutChip((UIViewController *)self); }
    @catch (NSException *e) { WTGLog(@"layout 异常 %@", e); }
}

static void WTGInstallHooks(void) {
    Class kbi = objc_getClass("KBIMEMgr");
    if (kbi) {
        WTGHook(kbi, @selector(reportID:pb:), (IMP)wtg_kb_reportID_pb, (IMP *)&orig_kb_reportID_pb);
        WTGHook(kbi, @selector(reportID:pbBase64Content:), (IMP)wtg_kb_reportID_b64, (IMP *)&orig_kb_reportID_b64);
        WTGHook(kbi, @selector(reportInstance:pb:), (IMP)wtg_kb_reportInstance_pb, (IMP *)&orig_kb_reportInstance_pb);
        WTGHook(kbi, @selector(reportForStandAloneMode:pb:), (IMP)wtg_kb_reportStandalone_pb, (IMP *)&orig_kb_reportStandalone_pb);
        WTGHook(kbi, @selector(reportKeystrokeForSession:keyType:keyCode:keyContent:), (IMP)wtg_kb_keystroke, NULL);
        WTGHook(kbi, @selector(reportKeystrokeSessionEndForSession:triggerType:sessionFinalText:), (IMP)wtg_kb_keystrokeEnd, NULL);
        WTGHook(kbi, @selector(reportEmojiEvent:session:emojiType:beforeText:), (IMP)wtg_kb_emoji, NULL);
        WTGHook(kbi, @selector(reportStickerEvent:session:sourceCandidate:lastDisplayCandidate:), (IMP)wtg_kb_sticker, NULL);
        WTGHook(kbi, @selector(reportCandidateClick:session:candidates:cloudServiceVersion:firstScreenFullVisibleLastCellIndex:hwClickSource:currentPanelType:typingNum:), (IMP)wtg_kb_candidateClick, NULL);
        WTGHook(kbi, @selector(reportProcessInfo), (IMP)wtg_kb_simple, NULL);
        WTGHook(kbi, @selector(reportFullAccessStat), (IMP)wtg_kb_simple, NULL);
    }

    Class bb = objc_getClass("WBBusinessMgr");
    if (bb) {
        WTGHook(bb, @selector(reportID:content:), (IMP)wtg_bb_reportID_content, (IMP *)&orig_bb_reportID_content);
        WTGHook(bb, @selector(reportID:base64Content:), (IMP)wtg_bb_reportID_b64, (IMP *)&orig_bb_reportID_b64);
        WTGHook(bb, @selector(doReportID:base64Content:), (IMP)wtg_bb_doReportID_b64, (IMP *)&orig_bb_doReportID_b64);
        WTGHook(bb, @selector(reportInstantID:content:), (IMP)wtg_bb_reportInstant_content, (IMP *)&orig_bb_reportInstant_content);
        WTGHook(bb, @selector(reportInstantID:base64Content:), (IMP)wtg_bb_reportInstant_b64, (IMP *)&orig_bb_reportInstant_b64);
        WTGHook(bb, @selector(updateBuglyUserId:), (IMP)wtg_bb_updateBuglyUserId, NULL);
    }

    Class ratio = objc_getClass("WBReportSampleRatioMgr");
    if (ratio) {
        WTGHook(ratio, @selector(sampleRatioForReportID:), (IMP)wtg_sampleRatio, (IMP *)&orig_sampleRatio);
        WTGHook(ratio, @selector(fetchRatio), (IMP)wtg_noop_v, NULL);
    }

    Class rd = objc_getClass("RDeliveyDataReporter");
    if (rd) {
        WTGHook(rd, @selector(reportEvent:params:forceReport:), (IMP)wtg_noop_2id_bool, NULL);
    }
    Class raft = objc_getClass("RAFTMeasureService");
    if (raft) {
        WTGHook(raft, @selector(reportSuccess:key:success:), (IMP)wtg_noop_2id_bool, NULL);
        WTGHook(raft, @selector(reportSuccess:key:success:samplingRate:), (IMP)wtg_noop_4, NULL);
        WTGHook(raft, @selector(reportDistribution:key:sValue:), (IMP)wtg_noop_3, NULL);
        WTGHook(raft, @selector(reportDistribution:key:sValue:samplingRate:), (IMP)wtg_noop_4, NULL);
        WTGHook(raft, @selector(reportStartup:), (IMP)wtg_noop_id, NULL);
    }
    if (!WTGAllowCrash()) {
        Class dau = objc_getClass("BuglyDAUReporter");
        if (dau) {
            WTGHook(dau, @selector(reportDAUEvent), (IMP)wtg_noop_v, NULL);
            WTGHook(dau, @selector(reportDAUWithActivateModules:), (IMP)wtg_noop_id, NULL);
        }
        Class bly = objc_getClass("BLYAnalyticsManager");
        if (bly) WTGHook(bly, @selector(reportAnalyticsEvent), (IMP)wtg_noop_v, NULL);
        Class metrics = objc_getClass("WBMetrics");
        if (metrics) WTGHook(metrics, @selector(uploadDiagnosticZipFile), (IMP)wtg_noop_v, NULL);
    }

}

__attribute__((constructor)) static void wtg_init(void) {
    @autoreleasepool {
        WTGLog(@"===== WTGuard v1 loaded (%@) =====",
               [[NSBundle mainBundle] bundlePath].lastPathComponent);
        @try {
            [NSURLProtocol registerClass:[WTGBlockProtocol class]];
            WTGInstallHooks();
            Class vc = objc_getClass("WBInputViewController");
            if (vc) {
                WTGHook(vc, @selector(viewDidLoad), (IMP)wtg_viewDidLoad, (IMP *)&orig_viewDidLoad);
                WTGHook(vc, @selector(viewDidLayoutSubviews), (IMP)wtg_viewDidLayout, (IMP *)&orig_viewDidLayout);
            }
            WTGLog(@"启用了 %lu 处拦截", (unsigned long)WTGCount);
        } @catch (NSException *e) {
            WTGLog(@"init 异常 %@", e);
        }
    }
}
