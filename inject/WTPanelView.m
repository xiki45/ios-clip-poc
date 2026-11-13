#import "WTPanelView.h"

static const CGFloat kRowH = 30.0;
static const CGFloat kPadX = 10.0;
static const CGFloat kPadY = 6.0;

@implementation WTPanelView {
    NSMutableArray<UILabel *> *_rows;
    NSMutableArray<UIView *> *_seps;
    UILabel *_moreLabel;
    NSArray<WTClipOption *> *_options;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.92];
        self.layer.cornerRadius = 10;
        self.layer.masksToBounds = YES;
        _rows = [NSMutableArray array];
        _seps = [NSMutableArray array];
    }
    return self;
}

- (void)setOptions:(NSArray<WTClipOption *> *)options {
    _options = options;
    for (UILabel *l in _rows) [l removeFromSuperview];
    for (UIView *v in _seps) [v removeFromSuperview];
    [_rows removeAllObjects];
    [_seps removeAllObjects];
    if (_moreLabel) { [_moreLabel removeFromSuperview]; _moreLabel = nil; }

    NSInteger maxRows = [self maxVisibleRows];
    NSInteger shown = MIN((NSInteger)options.count, maxRows);
    BOOL needMore = (NSInteger)options.count > maxRows;

    for (NSInteger i = 0; i < shown; i++) {
        WTClipOption *o = options[i];
        UILabel *l = [UILabel new];
        l.font = [UIFont systemFontOfSize:13];
        l.textColor = [UIColor whiteColor];
        l.text = [NSString stringWithFormat:@"%@   %@", o.title, o.detail];
        l.lineBreakMode = NSLineBreakByTruncatingTail;
        [self addSubview:l];
        [_rows addObject:l];
    }
    if (needMore) {
        _moreLabel = [UILabel new];
        _moreLabel.font = [UIFont systemFontOfSize:12];
        _moreLabel.textColor = [UIColor colorWithRed:0.4 green:0.8 blue:1.0 alpha:1];
        _moreLabel.text = @"▼ 还有更多…";
        [self addSubview:_moreLabel];
    }
    [self setNeedsLayout];
}

- (NSInteger)maxVisibleRows {
    // 预留最后一行给「更多」
    return MAX(1, (NSInteger)((self.bounds.size.height - kPadY * 2) / kRowH) - 1);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width - kPadX * 2;
    CGFloat y = kPadY;
    for (UILabel *l in _rows) {
        l.frame = CGRectMake(kPadX, y, w, kRowH);
        y += kRowH;
    }
    if (_moreLabel) _moreLabel.frame = CGRectMake(kPadX, y, w, kRowH);
}

- (WTClipOption *)optionAtPoint:(CGPoint)point inView:(UIView *)view {
    CGPoint p = [self convertPoint:point fromView:view];
    if (!CGRectContainsPoint(self.bounds, p)) return nil;
    NSInteger idx = (NSInteger)((p.y - kPadY) / kRowH);
    if (idx < 0) return nil;
    if (idx < (NSInteger)_rows.count && idx < (NSInteger)_options.count) return _options[idx];
    if (_moreLabel && idx >= (NSInteger)_rows.count) {
        if (self.onMore) self.onMore();
    }
    return nil;
}

@end
