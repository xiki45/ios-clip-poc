//
//  WeTypeInject.m  ·  stage-2 v3（带自诊断）
//
//  这一版同时回答两个问题：
//    Q1 tap 到底有没有到按钮上   → 按钮标题会变（①→②→③→✓/✗）
//    Q2 insertText 到底有没有生效 → 键盘弹出来时会自动插一段 AUTO-OK
//
//  只要看到 AUTO-OK，就说明 insertText 通路是好的，问题只在按钮；
//  如果 AUTO-OK 也不出现，说明 proxy 这条路在微信输入法里不通。
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString *const kTag = @"[wtinject]";

#pragma mark - 日志

static NSString *WTLogPath(void) {
    static NSString *path = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURL *group = [[NSFileManager defaultManager]
                        containerURLForSecurityApplicationGroupIdentifier:@"group.com.tencent.wetype"];
        if (group) path = [[group URLByAppendingPathComponent:@"wtinject.log"] path];
        if (!path) path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"wtinject.log"];
    });
    return path;
}

static void WTLog(NSString *fmt, ...) {
    @try {
        va_list args; va_start(args, fmt);
        NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
        va_end(args);
        NSDateFormatter *f = [NSDateFormatter new];
        f.dateFormat = @"HH:mm:ss.SSS";
        NSString *line = [NSString stringWithFormat:@"%@ %@ %@\n",
                          [f stringFromDate:[NSDate date]], kTag, msg];
        NSLog(@"[wtinject] %@", msg);
        FILE *fp = fopen(WTLogPath().UTF8String, "a");
        if (fp) { fputs(line.UTF8String, fp); fclose(fp); }
    } @catch (NSException *e) {
        NSLog(@"[wtinject] log fail: %@", e);
    }
}

#pragma mark - 按钮（自带状态机，用标题显示进度）

static const void *kButtonKey = &kButtonKey;
static const void *kHandlerKey = &kHandlerKey;
static const void *kBubbleKey = &kBubbleKey;
static const void *kAutoDoneKey = &kAutoDoneKey;

static void WTSetState(UIButton *btn, NSString *title, UIColor *bg) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [btn setTitle:title forState:UIControlStateNormal];
        btn.backgroundColor = bg;
    });
}

static UIColor *WTGreen(void) { return [UIColor colorWithRed:0.00 green:0.62 blue:0.42 alpha:1]; }
static UIColor *WTOrange(void){ return [UIColor colorWithRed:0.95 green:0.52 blue:0.10 alpha:1]; }
static UIColor *WTRed(void)   { return [UIColor colorWithRed:0.85 green:0.20 blue:0.20 alpha:1]; }
static UIColor *WTBlue(void)  { return [UIColor colorWithRed:0.10 green:0.45 blue:0.90 alpha:1]; }

/// 用代理插字，并回读文档确认是否真的进去了
static BOOL WTInsert(UIViewController *vc, NSString *text, UIButton *btn) {
    if (![vc isKindOfClass:[UIInputViewController class]]) {
        WTLog(@"vc 不是 UIInputViewController");
        return NO;
    }
    id proxy = [(UIInputViewController *)vc textDocumentProxy];
    WTSetState(btn, @"②", WTBlue);
    WTLog(@"proxy = %@  responds insertText=%d", proxy,
          [proxy respondsToSelector:@selector(insertText:)]);
    if (![proxy respondsToSelector:@selector(insertText:)]) return NO;

    NSString *before = nil;
    if ([proxy respondsToSelector:@selector(documentContextBeforeInput)]) {
        before = [proxy documentContextBeforeInput];
    }
    [proxy insertText:text];
    WTSetState(btn, @"③", WTBlue);

    NSString *after = nil;
    if ([proxy respondsToSelector:@selector(documentContextBeforeInput)]) {
        after = [proxy documentContextBeforeInput];
    }
    BOOL ok = (after.length > before.length) || (before == nil && after != nil);
    WTLog(@"插入 \"%@\"  前后长度 %lu -> %lu  ok=%d",
          text, (unsigned long)before.length, (unsigned long)after.length, ok);
    return ok;
}

#pragma mark - 点击处理

@interface WTTapHandler : NSObject
@property (nonatomic, weak) UIViewController *host;
@property (nonatomic, weak) UIButton *button;
@end

@implementation WTTapHandler {
    BOOL _fired;
    NSUInteger _token;
}

- (void)runIfNeeded:(NSString *)reason {
    if (_fired) return;
    _fired = YES;
    WTLog(@"触发(%@)", reason);
    WTSetState(self.button, @"①", WTOrange);
    BOOL ok = WTInsert(self.host, @"INJECT-OK ", self.button);
    WTSetState(self.button, ok ? @"✓" : @"✗", ok ? WTGreen() : WTRed());
    // 1 秒后复位，方便反复试
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        self->_fired = NO;
        WTSetState(self.button, @"注入3", WTGreen());
    });
}

- (void)onDown:(id)sender {
    // 先亮橙：说明 touch 确实落到了按钮上
    WTSetState(self.button, @"①", WTOrange);
    WTLog(@"touchDown");
    _fired = NO;
    NSUInteger token = ++_token;
    // 兜底：如果上层手势 recognizer 把 tap cancel 掉，touchUpInside 不会来，
    // 0.35s 后自己触发一次
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (token == self->_token) [self runIfNeeded:@"touchDown兜底"];
    });
}

- (void)onTap:(id)sender {
    WTLog(@"touchUpInside");
    [self runIfNeeded:@"touchUpInside"];
}
@end

#pragma mark - 按钮安装

/// 优先挂到 window：键盘扩展里 vc.view 之上常被后加的全屏视图盖住，
/// 挂在 window 上既不会被盖，也不影响命中测试。
static UIView *WTContainer(UIViewController *vc) {
    return vc.view.window ?: vc.view;
}

static void WTLayoutButton(UIViewController *vc) {
    UIButton *btn = objc_getAssociatedObject(vc, kButtonKey);
    if (!btn) return;
    UIView *container = WTContainer(vc);
    if (btn.superview != container) {
        [container addSubview:btn];
        WTLog(@"按钮挂到 %@", NSStringFromClass([container class]));
    }
    CGRect anchor = [vc.view convertRect:vc.view.bounds toView:container];
    CGFloat x = anchor.origin.x + anchor.size.width - 52;
    CGFloat y = anchor.origin.y + 5;
    btn.frame = CGRectMake(x, y, 46, 30);
}

static void WTInstallButton(UIViewController *vc) {
    if (objc_getAssociatedObject(vc, kButtonKey)) { WTLayoutButton(vc); return; }

    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    [btn setTitle:@"注入3" forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    btn.backgroundColor = WTGreen();
    btn.layer.cornerRadius = 8;
    btn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;
    // 保证按钮在最上层，不被后加的视图盖住
    btn.layer.zPosition = 10000;

    WTTapHandler *handler = [WTTapHandler new];
    handler.host = vc;
    handler.button = btn;
    [btn addTarget:handler action:@selector(onDown:) forControlEvents:UIControlEventTouchDown];
    [btn addTarget:handler action:@selector(onTap:) forControlEvents:UIControlEventTouchUpInside];
    objc_setAssociatedObject(btn, kHandlerKey, handler, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    objc_setAssociatedObject(vc, kButtonKey, btn, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    WTLayoutButton(vc);
    WTLog(@"按钮已挂上 window=%@ bounds=%@",
          vc.view.window ? @"yes" : @"nil", NSStringFromCGRect(vc.view.bounds));
}

#pragma mark - hook

static void (*orig_viewDidLoad)(id, SEL);
static void (*orig_viewDidLayoutSubviews)(id, SEL);
static void (*orig_viewDidAppear)(id, SEL, BOOL);

static void wt_viewDidLoad(id self, SEL _cmd) {
    orig_viewDidLoad(self, _cmd);
    @try {
        WTLog(@"viewDidLoad");
        WTInstallButton((UIViewController *)self);
    } @catch (NSException *e) { WTLog(@"viewDidLoad 异常: %@", e); }
}

static void wt_viewDidLayoutSubviews(id self, SEL _cmd) {
    orig_viewDidLayoutSubviews(self, _cmd);
    @try {
        UIViewController *vc = (UIViewController *)self;
        UIButton *btn = objc_getAssociatedObject(vc, kButtonKey);
        if (!btn) return;
        WTLayoutButton(vc);
        [btn.superview bringSubviewToFront:btn];
    } @catch (NSException *e) { WTLog(@"layout 异常: %@", e); }
}

static void wt_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    orig_viewDidAppear(self, _cmd, animated);
    @try {
        UIViewController *vc = (UIViewController *)self;
        NSNumber *done = objc_getAssociatedObject(vc, kAutoDoneKey);
        if (done.boolValue) return;
        objc_setAssociatedObject(vc, kAutoDoneKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        // 自动插一段：不用点按钮就能验证 insertText 通路
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIButton *btn = objc_getAssociatedObject(vc, kButtonKey);
            @try {
                WTLog(@"自动插入测试");
                BOOL ok = WTInsert(vc, @"AUTO-OK ", btn);
                WTSetState(btn, ok ? @"auto✓" : @"auto✗", ok ? WTGreen() : WTRed());
            } @catch (NSException *e) { WTLog(@"auto 异常: %@", e); }
        });
    } @catch (NSException *e) { WTLog(@"viewDidAppear 异常: %@", e); }
}

static void WTSwizzle(Class cls, SEL sel, void *replacement, void **original) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { WTLog(@"方法不存在: %@", NSStringFromSelector(sel)); return; }
    *original = (void *)method_getImplementation(m);
    method_setImplementation(m, (IMP)replacement);
    WTLog(@"已 hook %@", NSStringFromSelector(sel));
}

static void WTInitInner(void) {
    WTLog(@"===== dylib v3 loaded =====");
    WTLog(@"log: %@", WTLogPath());
    Class cls = objc_getClass("WBInputViewController");
    if (!cls) { WTLog(@"!! 找不到 WBInputViewController"); return; }
    WTSwizzle(cls, @selector(viewDidLoad), (void *)wt_viewDidLoad, (void **)&orig_viewDidLoad);
    WTSwizzle(cls, @selector(viewDidLayoutSubviews), (void *)wt_viewDidLayoutSubviews,
              (void **)&orig_viewDidLayoutSubviews);
    WTSwizzle(cls, @selector(viewDidAppear:), (void *)wt_viewDidAppear, (void **)&orig_viewDidAppear);
}

__attribute__((constructor)) static void wt_init(void) {
    @try { WTInitInner(); } @catch (NSException *e) { WTLog(@"init 异常: %@", e); }
}
