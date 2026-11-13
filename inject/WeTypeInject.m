//
//  WeTypeInject.m  ·  v8
//
//  阶段 3：把「剪贴板 + 重写」做进微信输入法键盘。
//
//  已验证的前置（v5/v6）：
//    dylib 能加载 → UI 能加 → window 级手势能收到点击 → insertText 能写字
//    → 完全访问打开后能读剪贴板
//
//  v7 的问题（实测）：菜单能弹出，但点条目没反应。
//  根因不是坐标，而是状态分裂 —— 按钮的 target 和 window 手势各自持有一个
//  WTTapHandler 实例，按钮那条路把面板打开了，手势那条路的 _clipText 还是 nil，
//  于是 applyOption: 一进函数就 return，表现就是「点了没反应」。
//
//  v8 的改法：
//    1. 状态收拢到单例 WTMenu —— 按钮、容器手势、面板手势全部打到同一个对象上
//    2. 同一个动作 0.35s 内只执行一次（按钮与手势会同时触发）
//    3. 命中表由 WTPanelView 在 reload 时生成，绘制与命中同源
//    4. 菜单按 POC 风格重做（分区 / 双行 / 翻页脚 / 点按高亮）
//    5. 去掉「分词」项 —— 微信输入法自带
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>
#import "WTClipEngine.h"
#import "WTPanelView.h"

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

#pragma mark - 颜色 / 关联键

static const void *kButtonKey  = &kButtonKey;
static const void *kGestureKey = &kGestureKey;

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

static void WTFlash(UIButton *btn, NSString *title, UIColor *bg) {
    WTSetState(btn, title, bg);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ WTSetState(btn, @"重写", WTGreen()); });
}

#pragma mark - 剪贴板 / 输入

static NSString *WTClipboardText(void) {
    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    NSString *s = pb.string;
    if (s.length == 0) s = [pb.strings firstObject];
    return s.length ? s : nil;
}

static BOOL WTInsert(UIViewController *vc, NSString *text) {
    if (![vc isKindOfClass:[UIInputViewController class]]) return NO;
    if (text.length == 0) return NO;
    id proxy = [(UIInputViewController *)vc textDocumentProxy];
    if (![proxy respondsToSelector:@selector(insertText:)]) return NO;
    [proxy insertText:text];
    WTLog(@"插入 %lu 字", (unsigned long)text.length);
    return YES;
}

#pragma mark - 排序：推荐 → 编码 → 文本 → 哈希（去掉分词）

static NSArray<WTClipOption *> *WTSortedOptions(NSString *text) {
    NSArray<WTClipOption *> *all = [WTClipEngine optionsForText:text];
    NSArray<NSNumber *> *recommended = [WTClipEngine recommendedOpsForText:text];

    NSMutableArray<WTClipOption *> *out = [NSMutableArray array];
    NSMutableSet<NSNumber *> *used = [NSMutableSet set];

    for (NSNumber *op in recommended) {
        if (op.integerValue == WTRewriteOpTokenize) continue;
        for (WTClipOption *o in all) {
            if (o.op == (WTRewriteOp)op.integerValue && ![used containsObject:@(o.op)]) {
                WTClipOption *copy = [WTClipOption new];
                copy.op = o.op;
                copy.title = [@"★ " stringByAppendingString:o.title];
                copy.detail = o.detail;
                copy.section = @"推荐";
                [out addObject:copy];
                [used addObject:@(o.op)];
                break;
            }
        }
    }
    for (NSString *sec in @[@"编码", @"文本", @"哈希"]) {
        for (WTClipOption *o in all) {
            if (o.op == WTRewriteOpTokenize) continue;
            if ([o.section isEqualToString:sec] && ![used containsObject:@(o.op)]) {
                [out addObject:o];
                [used addObject:@(o.op)];
            }
        }
    }
    return out;
}

#pragma mark - 菜单（单例：按钮 / 容器手势 / 面板手势共用同一份状态）

@interface WTMenu : NSObject <UIGestureRecognizerDelegate>
+ (instancetype)shared;
@property (nonatomic, weak) UIViewController *host;
@property (nonatomic, weak) UIButton *button;
- (void)bindHost:(UIViewController *)vc button:(UIButton *)btn;
- (void)buttonTapped;
- (void)handleGesture:(UITapGestureRecognizer *)g;
- (void)relayout;
- (void)attachTapTo:(UIView *)view;
@end

@implementation WTMenu {
    NSString *_clipText;
    NSArray<WTClipOption *> *_allOptions;
    NSInteger _pageStart;
    WTPanelView *_panel;
    CFAbsoluteTime _lastActivate;
    CFAbsoluteTime _lastOpen;
}

+ (instancetype)shared {
    static WTMenu *menu = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ menu = [WTMenu new]; });
    return menu;
}

- (void)bindHost:(UIViewController *)vc button:(UIButton *)btn {
    if (self.host && self.host != vc) {
        WTLog(@"键盘实例换了，收起旧面板");
        [self closePanel];
    }
    self.host = vc;
    self.button = btn;
}

- (UIView *)container { return self.host.view.window ?: self.host.view; }

#pragma mark 开关

- (void)buttonTapped {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - _lastOpen < 0.30) return;   // 手势同帧也会触发，去重
    _lastOpen = now;
    if (_panel) [self closePanel];
    else [self openPanel];
}

- (void)openPanel {
    if (!self.host) return;
    NSString *text = WTClipboardText();
    if (text.length == 0) {
        UIPasteboard *pb = [UIPasteboard generalPasteboard];
        WTLog(@"剪贴板空 items=%lu hasStrings=%d cc=%ld",
              (unsigned long)pb.numberOfItems, (int)pb.hasStrings, (long)pb.changeCount);
        WTInsert(self.host, [NSString stringWithFormat:@"[诊断]items=%lu hasStrings=%d cc=%ld",
                             (unsigned long)pb.numberOfItems, (int)pb.hasStrings,
                             (long)pb.changeCount]);
        WTFlash(self.button, @"读空", WTRed());
        return;
    }

    _clipText = text;
    _allOptions = WTSortedOptions(text);
    WTLog(@"剪贴板 %lu 字，可用算子 %lu 个", (unsigned long)text.length,
          (unsigned long)_allOptions.count);
    if (_allOptions.count == 0) {
        WTLog(@"没有能生效的算子，直接插入原文");
        WTInsert(self.host, text);
        WTFlash(self.button, @"无算子", WTOrange());
        return;
    }

    UIView *container = [self container];
    if (!_panel) {
        _panel = [WTPanelView new];
        __weak typeof(self) weakSelf = self;
        _panel.onPage = ^(NSInteger start) { [weakSelf goPage:start]; };
        [self attachTapTo:_panel];
    }

    CGRect anchor = [self.host.view convertRect:self.host.view.bounds toView:container];
    CGFloat w = MIN(anchor.size.width - 24, 460);
    CGFloat maxH = MAX(160, anchor.size.height - 16);
    _panel.frame = CGRectMake(anchor.origin.x + (anchor.size.width - w) / 2,
                              anchor.origin.y + 8, w, maxH);
    _panel.maxHeight = maxH;
    _panel.sourceLength = (NSInteger)text.length;
    _panel.options = _allOptions;
    _panel.pageStart = 0;
    [_panel reload];

    if (_panel.superview != container) [container addSubview:_panel];
    [container bringSubviewToFront:_panel];

    _pageStart = 0;
    WTSetState(self.button, @"选择", WTBlue());
    WTLog(@"菜单展开 frame=%@ 首屏=%ld/%lu", NSStringFromCGRect(_panel.frame),
          (long)_panel.shownCount, (unsigned long)_allOptions.count);
}

- (void)closePanel {
    [_panel removeFromSuperview];
    _panel = nil;
    _clipText = nil;
    _allOptions = nil;
    _pageStart = 0;
    WTSetState(self.button, @"重写", WTGreen());
}

- (void)goPage:(NSInteger)start {
    if (!_panel || _allOptions.count == 0) return;
    _pageStart = MAX(0, MIN(start, (NSInteger)_allOptions.count - 1));
    _panel.pageStart = _pageStart;
    [_panel reload];
    WTLog(@"翻页 pageStart=%ld", (long)_pageStart);
}

#pragma mark 执行

- (void)applyOption:(WTClipOption *)opt {
    if (!opt) return;
    if (_clipText.length == 0) {
        // 状态万一又错位，这里自愈一次：重读剪贴板，而不是静默失败
        WTLog(@"!! _clipText 为空，重读剪贴板自愈");
        _clipText = WTClipboardText();
        if (_clipText.length == 0) {
            WTFlash(self.button, @"读空", WTRed());
            [self closePanel];
            return;
        }
    }
    NSString *err = nil;
    NSString *result = [WTClipEngine applyOp:opt.op toText:_clipText error:&err];
    if (!result) {
        WTLog(@"算子失败 %@: %@", opt.title, err);
        WTFlash(self.button, @"失败", WTRed());
        [self closePanel];
        return;
    }
    BOOL ok = WTInsert(self.host, result);
    WTLog(@"算子 %@ → 插入 %d", opt.title, (int)ok);
    [self closePanel];
    WTFlash(self.button, ok ? @"✓" : @"✗", ok ? WTGreen() : WTRed());
}

- (void)activateHit:(WTPanelHit *)hit {
    if (!hit || hit.kind == WTPanelHitKindNone) return;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - _lastActivate < 0.35) return;   // 容器手势 + 面板手势会同一帧各来一次
    _lastActivate = now;

    [_panel flashRect:hit.rect];

    switch (hit.kind) {
        case WTPanelHitKindClose:
            WTLog(@"关闭面板");
            [self closePanel];
            break;
        case WTPanelHitKindPrev:
            [self goPage:_pageStart - 4];
            break;
        case WTPanelHitKindNext:
            [self goPage:_pageStart + MAX(1, _panel.shownCount)];
            break;
        case WTPanelHitKindRow:
            [self applyOption:hit.option];
            break;
        default:
            break;
    }
}

#pragma mark 手势

- (void)attachTapTo:(UIView *)view {
    if (!view) return;
    if (objc_getAssociatedObject(view, kGestureKey)) return;
    UITapGestureRecognizer *g = [[UITapGestureRecognizer alloc] initWithTarget:self
                                                                     action:@selector(handleGesture:)];
    g.delegate = self;
    g.cancelsTouchesInView = NO;
    g.delaysTouchesBegan = NO;
    g.delaysTouchesEnded = NO;
    [view addGestureRecognizer:g];
    objc_setAssociatedObject(view, kGestureKey, @(YES), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    WTLog(@"手势挂到 %@", NSStringFromClass([view class]));
}

- (void)handleGesture:(UITapGestureRecognizer *)g {
    UIView *view = g.view;
    if (!view) return;
    CGPoint p = [g locationInView:view];

    if (_panel && _panel.superview) {
        CGPoint pp = [_panel convertPoint:p fromView:view];
        WTPanelHit *hit = [_panel hitAtPoint:pp];
        if (hit) {
            WTLog(@"命中 %ld @%@", (long)hit.kind, NSStringFromCGPoint(pp));
            [self activateHit:hit];
            return;
        }
        CGRect pf = [_panel convertRect:_panel.bounds toView:view];
        if (CGRectContainsPoint(pf, p)) return;   // 面板内空白，不动
        if (p.x >= 0 && p.y >= 0 && p.x <= view.bounds.size.width && p.y <= view.bounds.size.height) {
            WTLog(@"面板外点击，收起");
            [self closePanel];
        }
        return;
    }

    UIButton *btn = self.button;
    if (!btn || !btn.superview) return;
    CGRect bf = [btn.superview convertRect:btn.frame toView:view];
    if (CGRectContainsPoint(CGRectInset(bf, -6, -6), p)) {
        WTLog(@"命中按钮");
        [self buttonTapped];
    }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g
    shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}

- (void)relayout {
    if (!_panel || !self.host) return;
    UIView *container = [self container];
    if (_panel.superview != container) return;
    CGRect anchor = [self.host.view convertRect:self.host.view.bounds toView:container];
    CGFloat w = MIN(anchor.size.width - 24, 460);
    CGFloat maxH = MAX(160, anchor.size.height - 16);
    CGRect f = _panel.frame;
    f.origin.x = anchor.origin.x + (anchor.size.width - w) / 2;
    f.origin.y = anchor.origin.y + 8;
    f.size.width = w;
    _panel.maxHeight = maxH;
    _panel.frame = f;
    [_panel reload];
    [container bringSubviewToFront:_panel];
}

@end

#pragma mark - 安装 / hook

static void WTLayoutButton(UIViewController *vc) {
    UIButton *btn = objc_getAssociatedObject(vc, kButtonKey);
    if (!btn) return;
    WTMenu *menu = [WTMenu shared];
    [menu bindHost:vc button:btn];

    UIView *container = vc.view.window ?: vc.view;
    if (btn.superview != container) [container addSubview:btn];
    CGRect anchor = [vc.view convertRect:vc.view.bounds toView:container];
    btn.frame = CGRectMake(anchor.origin.x + anchor.size.width - 56,
                           anchor.origin.y + 5, 50, 30);
    [btn.superview bringSubviewToFront:btn];

    [menu attachTapTo:container];
    [menu relayout];
}

static void WTInstallButton(UIViewController *vc) {
    UIButton *btn = objc_getAssociatedObject(vc, kButtonKey);
    if (!btn) {
        btn = [UIButton buttonWithType:UIButtonTypeSystem];
        [btn setTitle:@"重写" forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        btn.backgroundColor = WTGreen();
        btn.layer.cornerRadius = 8;
        btn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleBottomMargin;

        WTMenu *menu = [WTMenu shared];
        [menu bindHost:vc button:btn];
        [btn addTarget:menu action:@selector(buttonTapped) forControlEvents:UIControlEventTouchUpInside];
        objc_setAssociatedObject(vc, kButtonKey, btn, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        WTLog(@"按钮已装");
    }
    WTLayoutButton(vc);
}

static void (*orig_viewDidLoad)(id, SEL);
static void (*orig_viewDidLayoutSubviews)(id, SEL);

static void wt_viewDidLoad(id self, SEL _cmd) {
    orig_viewDidLoad(self, _cmd);
    @try { WTInstallButton((UIViewController *)self); }
    @catch (NSException *e) { WTLog(@"viewDidLoad 异常: %@", e); }
}

static void wt_viewDidLayoutSubviews(id self, SEL _cmd) {
    orig_viewDidLayoutSubviews(self, _cmd);
    @try { WTLayoutButton((UIViewController *)self); }
    @catch (NSException *e) { WTLog(@"layout 异常: %@", e); }
}

static void WTSwizzle(Class cls, SEL sel, void *replacement, void **original) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { WTLog(@"方法不存在: %@", NSStringFromSelector(sel)); return; }
    *original = (void *)method_getImplementation(m);
    method_setImplementation(m, (IMP)replacement);
    WTLog(@"已 hook %@", NSStringFromSelector(sel));
}

static void WTInitInner(void) {
    WTLog(@"===== dylib v8 loaded =====");
    Class cls = objc_getClass("WBInputViewController");
    if (!cls) { WTLog(@"!! 找不到 WBInputViewController"); return; }
    WTSwizzle(cls, @selector(viewDidLoad), (void *)wt_viewDidLoad, (void **)&orig_viewDidLoad);
    WTSwizzle(cls, @selector(viewDidLayoutSubviews), (void *)wt_viewDidLayoutSubviews,
              (void **)&orig_viewDidLayoutSubviews);
}

__attribute__((constructor)) static void wt_init(void) {
    @try { WTInitInner(); } @catch (NSException *e) { WTLog(@"init 异常: %@", e); }
}
