//
//  WTPanelView.h
//  键盘上的重写菜单（自绘，不依赖 hitTest，点击由 window 级手势按坐标分发）
//

#import <UIKit/UIKit.h>
#import "WTClipEngine.h"

@interface WTPanelView : UIView

/// 当前页展示的选项（已按推荐排序、分页截断）
- (void)setOptions:(NSArray<WTClipOption *> *)options;

/// 命中测试：返回被点中的选项；点到「更多」返回 NSNotFound 并触发 onMore
- (WTClipOption *)optionAtPoint:(CGPoint)point inView:(UIView *)view;

@property (nonatomic, copy) void (^onMore)(void);

@end
