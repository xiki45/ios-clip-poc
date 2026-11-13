//
//  WTPanelView.m  ·  v8
//

#import "WTPanelView.h"

static const CGFloat kHeaderH = 40.0;
static const CGFloat kSecH    = 22.0;
static const CGFloat kRowH    = 52.0;
static const CGFloat kFooterH = 40.0;
static const CGFloat kPadB    = 8.0;
static const CGFloat kPadX    = 16.0;

static UIColor *WTWhite(CGFloat a) { return [UIColor colorWithWhite:1 alpha:a]; }

@implementation WTPanelHit
+ (instancetype)kind:(WTPanelHitKind)kind rect:(CGRect)rect option:(WTClipOption *)option {
    WTPanelHit *h = [WTPanelHit new];
    h.kind = kind;
    h.rect = rect;
    h.option = option;
    return h;
}
@end

@implementation WTPanelView {
    UIVisualEffectView *_bg;
    NSMutableArray<WTPanelHit *> *_hits;
    NSInteger _shownStart;
    NSInteger _shownCount;
    BOOL _hasPrev;
    BOOL _hasNext;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithWhite:0.09 alpha:0.94];
        self.layer.cornerRadius = 14;
        self.layer.masksToBounds = YES;
        self.layer.borderWidth = 0.5;
        self.layer.borderColor = WTWhite(0.14).CGColor;

        _bg = [[UIVisualEffectView alloc]
               initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark]];
        _bg.userInteractionEnabled = NO;
        [self addSubview:_bg];

        _hits = [NSMutableArray array];
        _pageStart = 0;
        // 面板自身也挂手势，避免容器上的手势被第三方视图吞掉
        self.userInteractionEnabled = YES;
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _bg.frame = self.bounds;
}

#pragma mark - 内容

- (void)reload {
    for (UIView *v in self.subviews) {
        if (v != _bg) [v removeFromSuperview];
    }
    [_hits removeAllObjects];

    const CGFloat w = self.bounds.size.width;
    const CGFloat budget = self.maxHeight > 0 ? self.maxHeight : 320.0;
    const NSInteger total = (NSInteger)self.options.count;
    const NSInteger start = MAX(0, MIN(self.pageStart, total));

    // —— 头部 ——
    UILabel *title = [UILabel new];
    title.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    title.textColor = WTWhite(0.95);
    title.text = @"重写剪贴板";
    [title sizeToFit];
    title.frame = CGRectMake(kPadX, 0, title.frame.size.width, kHeaderH);
    [self addSubview:title];

    if (self.sourceLength > 0) {
        UILabel *sub = [UILabel new];
        sub.font = [UIFont systemFontOfSize:11];
        sub.textColor = WTWhite(0.45);
        sub.text = [NSString stringWithFormat:@"%ld 字", (long)self.sourceLength];
        [sub sizeToFit];
        sub.frame = CGRectMake(CGRectGetMaxX(title.frame) + 8,
                              (kHeaderH - sub.frame.size.height) / 2.0,
                              sub.frame.size.width, sub.frame.size.height);
        [self addSubview:sub];
    }

    UILabel *close = [UILabel new];
    close.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    close.textColor = WTWhite(0.55);
    close.text = @"✕";
    close.textAlignment = NSTextAlignmentCenter;
    close.frame = CGRectMake(w - 44, 0, 44, kHeaderH);
    [self addSubview:close];
    [_hits addObject:[WTPanelHit kind:WTPanelHitKindClose
                                 rect:close.frame
                               option:nil]];

    UIView *sep = [[UIView alloc] initWithFrame:CGRectMake(0, kHeaderH - 0.5, w, 0.5)];
    sep.backgroundColor = WTWhite(0.10);
    [self addSubview:sep];

    CGFloat y = kHeaderH;
    NSString *lastSection = nil;
    NSInteger i = start;

    while (i < total) {
        WTClipOption *o = self.options[i];
        BOOL newSection = ![o.section isEqualToString:lastSection];
        BOOL moreAfter = (i + 1 < total);
        CGFloat need = y + (newSection ? kSecH : 0) + kRowH
                     + (moreAfter || start > 0 ? kFooterH : 0) + kPadB;
        if (need > budget && i > start) break;

        if (newSection) {
            UILabel *sec = [UILabel new];
            sec.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
            sec.textColor = WTWhite(0.40);
            sec.text = o.section.length ? o.section : @"其他";
            sec.frame = CGRectMake(kPadX, y, w - kPadX * 2, kSecH);
            [self addSubview:sec];
            y += kSecH;
            lastSection = o.section;
        }

        CGRect rowRect = CGRectMake(0, y, w, kRowH);
        [self addRow:o rect:rowRect];
        [_hits addObject:[WTPanelHit kind:WTPanelHitKindRow rect:rowRect option:o]];
        y += kRowH;
        i++;
    }

    _shownStart = start;
    _shownCount = i - start;
    _hasNext = i < total;
    _hasPrev = start > 0;

    if (_hasPrev || _hasNext) {
        UIView *fsep = [[UIView alloc] initWithFrame:CGRectMake(0, y, w, 0.5)];
        fsep.backgroundColor = WTWhite(0.10);
        [self addSubview:fsep];

        if (_hasPrev) {
            UILabel *prev = [UILabel new];
            prev.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
            prev.textColor = WTWhite(0.70);
            prev.text = @"◂ 上一页";
            prev.frame = CGRectMake(kPadX, y, w / 2 - kPadX, kFooterH);
            [self addSubview:prev];
            [_hits addObject:[WTPanelHit kind:WTPanelHitKindPrev rect:prev.frame option:nil]];
        }
        if (_hasNext) {
            UILabel *next = [UILabel new];
            next.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
            next.textColor = [UIColor colorWithRed:0.35 green:0.72 blue:1.0 alpha:1];
            next.textAlignment = NSTextAlignmentRight;
            next.text = [NSString stringWithFormat:@"更多 ▸  %ld/%ld",
                         (long)MIN(i + 1, total), (long)total];
            next.frame = CGRectMake(w / 2, y, w / 2 - kPadX, kFooterH);
            [self addSubview:next];
            [_hits addObject:[WTPanelHit kind:WTPanelHitKindNext rect:next.frame option:nil]];
        }
        y += kFooterH;
    }

    y += kPadB;

    CGRect f = self.frame;
    f.size.height = MIN(y, budget);
    self.frame = f;
    _bg.frame = self.bounds;
}

- (void)addRow:(WTClipOption *)o rect:(CGRect)rect {
    BOOL star = [o.title hasPrefix:@"★"];
    UILabel *t = [UILabel new];
    t.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    t.textColor = star ? [UIColor colorWithRed:1.0 green:0.72 blue:0.30 alpha:1] : WTWhite(0.95);
    t.text = o.title;
    t.lineBreakMode = NSLineBreakByTruncatingTail;
    t.frame = CGRectMake(kPadX, rect.origin.y + 8, rect.size.width - kPadX - 34, 20);
    [self addSubview:t];

    UILabel *d = [UILabel new];
    d.font = [UIFont systemFontOfSize:12];
    d.textColor = WTWhite(0.50);
    d.text = o.detail.length ? o.detail : @" ";
    d.lineBreakMode = NSLineBreakByTruncatingTail;
    d.frame = CGRectMake(kPadX, rect.origin.y + 27, rect.size.width - kPadX - 34, 16);
    [self addSubview:d];

    UILabel *chev = [UILabel new];
    chev.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    chev.textColor = WTWhite(0.28);
    chev.text = @"▸";
    chev.textAlignment = NSTextAlignmentCenter;
    chev.frame = CGRectMake(rect.size.width - 32, rect.origin.y, 24, kRowH);
    [self addSubview:chev];

    UIView *sep = [[UIView alloc]
                   initWithFrame:CGRectMake(kPadX, CGRectGetMaxY(rect) - 0.5,
                                            rect.size.width - kPadX, 0.5)];
    sep.backgroundColor = WTWhite(0.07);
    [self addSubview:sep];
}

#pragma mark - 命中 / 反馈

- (WTPanelHit *)hitAtPoint:(CGPoint)point {
    for (WTPanelHit *h in [_hits reverseObjectEnumerator]) {
        if (CGRectContainsPoint(CGRectInset(h.rect, 0, 0), point)) return h;
    }
    return nil;
}

- (void)flashRect:(CGRect)rect {
    UIView *hl = [[UIView alloc] initWithFrame:rect];
    hl.backgroundColor = WTWhite(0.16);
    hl.userInteractionEnabled = NO;
    [self addSubview:hl];
    [UIView animateWithDuration:0.18 animations:^{
        hl.alpha = 0;
    } completion:^(BOOL done) {
        [hl removeFromSuperview];
    }];
}

@end
