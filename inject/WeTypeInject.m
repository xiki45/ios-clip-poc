//
//  WeTypeInject.m  ·  v5
//
//  v4 已经证明两件事：
//    1) insertText 通路是通的（AUTO-OK 插进了输入框，按钮显示 auto✓）
//    2) 按钮能创建、能更新标题
//  唯一没解决的：点击命中不到按钮。
//
//  v5 换成不依赖 hitTest 的触发方式：
//    在 window 上挂一个 UITapGestureRecognizer（cancelsTouchesInView=NO），
//    点击位置落在按钮 frame 内就触发。window 级手势能看到所有触摸，
//    即使按钮被上层视图或手势吃掉也一样。
//    按钮自己的 target-action 和 touchDown 兜底都保留，三条路谁先到算谁。
//
//  功能也从「插固定字符串」升级成「插当前剪贴板内容」，点一次就有真实用途。
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
    } @catch (NSException *e) { NSLog(@"[wtinject] log fail: %@", e); }
}

#pragma mark - 状态与颜色

static const void *kButtonKey  = &kButtonKey;
static const void *kHandlerKey = &kHandlerKey;
static const void *kGestureKey = &kGestureKey;
static const void *kAutoDoneKey = &kAutoDoneKey;

static UIColor *WTGreen(void) { return [UIColor colorWithRed:0.00 green:0.62 blue:0.42 alpha:1]; }
static UIColor *WTOrange(void){ return [UIColor colorWithRed:0.95 green:0.52 blue:0.10 alpha:1]; }
static UIColor *WTRed(void)   { return [UIColor colorWithRed:0.85 green:0.20 blue:0.20 alpha:1]; }
static UIColor *WTBlue(void)  { return [UIColor colorWithRed:0.10 green:0.45 blue:0.90 alpha:1]; }

static void WTSetState(UIButton *btn, NSString *title, UIColor *bg) {
    if (!btn) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [btn setTitle:title forState:UIControlStateNormal];
        btn.backgroundColor = bg;
    });
}

#pragma mark - 插入

/// 读剪贴板，同时把诊断信息带出来（读不到时用户能一眼看出原因）
static NSString *WTPayload(NSString **diagOut) {
    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    NSUInteger items = pb.numberOfItems;
    BOOL hasStrings = pb.hasStrings;
    NSInteger changeCount = pb.changeCount;
    NSString *s = pb.string;
    NSArray *strings = pb.strings;

    NSURL *group = [[NSFileManager defaultManager]
                    containerURLForSecurityApplicationGroupIdentifier:@"group.com.tencent.wetype"];
    BOOL groupOK = (group != nil);

    NSString *diag = [NSString stringWithFormat:
                      @"items=%lu hasStrings=%d len=%lu strings=%lu cc=%ld appGroup=%d",
                      (unsigned long)items, (int)hasStrings,
                      (unsigned long)(s.length), (unsigned long)strings.count,
                      (long)changeCount, (int)groupOK];
    if (diagOut) *diagOut = diag;
    WTLog(@"剪贴板诊断: %@", diag);

    if (s.length > 0) return s.length > 1000 ? [s substringToIndex:1000] : s;
    if (strings.count > 0) return [strings firstObject];
    return nil;
}

static BOOL WTInsert(UIViewController *vc, NSString *text, UIButton *btn) {
    if (![vc isKindOfClass:[UIInputViewController class]]) return NO;
    id proxy = [(UIInputViewController *)vc textDocumentProxy];
    if (![proxy respondsToSelector:@selector(insertText:)]) {
        WTLog(@"proxy 不支持 insertText");
        return NO;
    }
    NSString *before = [proxy respondsToSelector:@selector(documentContextBeforeInput)]
                       ? [proxy documentContextBeforeInput] : nil;
    [proxy insertText:text];
    NSString *after = [proxy respondsToSelector:@selector(documentContextBeforeInput)]
                      ? [proxy documentContextBeforeInput] : nil;
    BOOL ok = (after.length > before.length) || (before == nil && after != nil);
    WTLog(@"插入 %lu 字，前后 %lu→%lu，ok=%d", (unsigned long)text.length,
          (unsigned long)before.length, (unsigned long)after.length, ok);
    return ok;
}

#pragma mark - 点击处理

@interface WTTapHandler : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, weak) UIViewController *host;
@property (nonatomic, weak) UIButton *button;
@property (nonatomic, weak) UIView *gestureHost;
@end

@implementation WTTapHandler {
    BOOL _fired;
    NSUInteger _token;
}

- (void)fire:(NSString *)reason {
    if (_fired) return;
    _fired = YES;
    WTLog(@"触发(%@)", reason);
    WTSetState(self.button, @"①", WTOrange());

    NSString *diag = nil;
    NSString *payload = WTPayload(&diag);
    if (payload.length == 0) {
        // 读不到就把诊断直接写进输入框，肉眼可见，不用连电脑
        NSString *msg = [NSString stringWithFormat:@"[诊断]%@", diag];
        WTInsert(self.host, msg, self.button);
        WTSetState(self.button, @"读空", WTRed());
    } else {
        BOOL ok = WTInsert(self.host, payload, self.button);
        WTSetState(self.button, ok ? @"✓" : @"✗", ok ? WTGreen() : WTRed());
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        self->_fired = NO;
        WTSetState(self.button, @"粘贴", WTGreen());
    });
}

- (void)onDown:(id)sender {
    WTSetState(self.button, @"①", WTOrange());
    WTLog(@"touchDown");
    _fired = NO;
    NSUInteger token = ++_token;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (token == self->_token) [self fire:@"touchDown兜底"];
    });
}

- (void)onTap:(id)sender {
    WTLog(@"touchUpInside");
    [self fire:@"touchUpInside"];
}

/// window 级手势：不依赖 hitTest，按钮被盖住也能收到
- (void)onGesture:(UITapGestureRecognizer *)g {
    UIButton *btn = self.button;
    UIView *host = g.view;
    if (!btn || !host) return;
    CGPoint p = [g locationInView:host];
    CGRect f = [btn.superview convertRect:btn.frame toView:host];
    BOOL hit = CGRectContainsPoint(CGRectInset(f, -6, -6), p);
    WTLog(@"手势 tap %@ 按钮%@", NSStringFromCGPoint(p), hit ? @"命中" : @"未命中");
    if (hit) [self fire:@"gesture"];
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}
@end

#pragma mark - 安装

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
    btn.frame = CGRectMake(anchor.origin.x + anchor.size.width - 56,
                           anchor.origin.y + 5, 50, 30);
    [btn.superview bringSubviewToFront:btn];
}

static void WTInstallGesture(UIViewController *vc, UIButton *btn) {
    UIView *container = WTContainer(vc);
    if (objc_getAssociatedObject(container, kGestureKey)) return;

    WTTapHandler *handler = [WTTapHandler new];
    handler.host = vc;
    handler.button = btn;
    handler.gestureHost = container;

    UITapGestureRecognizer *g = [[UITapGestureRecognizer alloc] initWithTarget:handler
                                                                       action:@selector(onGesture:)];
    g.delegate = handler;
    g.cancelsTouchesInView = NO;
    g.delaysTouchesBegan = NO;
    g.delaysTouchesEnded = NO;
    [container addGestureRecognizer:g];
    objc_setAssociatedObject(container, kGestureKey, handler, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    WTLog(@"手势已挂到 %@", NSStringFromClass([container class]));
}

static void WTInstallButton(UIViewController *vc) {
    UIButton *btn = objc_getAssociatedObject(vc, kButtonKey);
    if (btn) {
        WTLayoutButton(vc);
        WTInstallGesture(vc, btn);
        return;
    }

    btn = [UIButton buttonWithType:UIButtonTypeSystem];
    [btn setTitle:@"粘贴" forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    btn.backgroundColor = WTGreen();
    btn.layer.cornerRadius = 8;
    btn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;

    WTTapHandler *handler = [WTTapHandler new];
    handler.host = vc;
    handler.button = btn;
    [btn addTarget:handler action:@selector(onDown:) forControlEvents:UIControlEventTouchDown];
    [btn addTarget:handler action:@selector(onTap:) forControlEvents:UIControlEventTouchUpInside];
    objc_setAssociatedObject(btn, kHandlerKey, handler, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    objc_setAssociatedObject(vc, kButtonKey, btn, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    WTLayoutButton(vc);
    WTInstallGesture(vc, btn);
    WTLog(@"按钮已装 bounds=%@ window=%@",
          NSStringFromCGRect(vc.view.bounds), vc.view.window ? @"yes" : @"nil");
}

#pragma mark - hook

static void (*orig_viewDidLoad)(id, SEL);
static void (*orig_viewDidLayoutSubviews)(id, SEL);
static void (*orig_viewDidAppear)(id, SEL, BOOL);

static void wt_viewDidLoad(id self, SEL _cmd) {
    orig_viewDidLoad(self, _cmd);
    @try { WTLog(@"viewDidLoad"); WTInstallButton((UIViewController *)self); }
    @catch (NSException *e) { WTLog(@"viewDidLoad 异常: %@", e); }
}

static void wt_viewDidLayoutSubviews(id self, SEL _cmd) {
    orig_viewDidLayoutSubviews(self, _cmd);
    @try {
        UIViewController *vc = (UIViewController *)self;
        UIButton *btn = objc_getAssociatedObject(vc, kButtonKey);
        if (!btn) return;
        WTLayoutButton(vc);
        WTInstallGesture(vc, btn);
    } @catch (NSException *e) { WTLog(@"layout 异常: %@", e); }
}

static void wt_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    orig_viewDidAppear(self, _cmd, animated);
    @try {
        UIViewController *vc = (UIViewController *)self;
        if ([objc_getAssociatedObject(vc, kAutoDoneKey) boolValue]) return;
        objc_setAssociatedObject(vc, kAutoDoneKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            UIButton *btn = objc_getAssociatedObject(vc, kButtonKey);
            @try {
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
    WTLog(@"===== dylib v6 loaded =====");
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
