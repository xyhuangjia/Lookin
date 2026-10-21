//
//  LKHierarchyDataSource.m
//  Lookin
//
//  Created by Li Kai on 2019/5/6.
//  https://lookin.work
//

#import "LKHierarchyDataSource.h"
#import "LookinHierarchyInfo.h"
#import "LookinDisplayItem.h"
#import "LKPreferenceManager.h"
#import "LKUserActionManager.h"
#import "LookinDisplayItem+LookinClient.h"
#import "LKDanceUIAttrMaker.h"
#import "LKStaticAsyncUpdateManager.h"
#import "LKHierarchyColorMenuBuilder.h"
@import AppCenter;
@import AppCenterAnalytics;

@interface LookinDisplayItem (LKHierarchyDataSource)

/// 记录搜索之前的 isExpanded 的值，用来在结束搜索后恢复
@property(nonatomic, assign) BOOL isExpandedBeforeSearchOrFocus;

@end

@implementation LookinDisplayItem (LKHierarchyDataSource)

- (void)setIsExpandedBeforeSearchOrFocus:(BOOL)isExpandedBeforeSearching {
    [self lookin_bindBOOL:isExpandedBeforeSearching forKey:@"isExpandedBeforeSearching"];
}

- (BOOL)isExpandedBeforeSearchOrFocus {
    return [self lookin_getBindBOOLForKey:@"isExpandedBeforeSearching"];
}

@end

@interface LKHierarchyDataSource ()
@property(nonatomic, assign) LKHierarchyDataSourceState state;

@property(nonatomic, strong, readwrite) LookinHierarchyInfo *rawHierarchyInfo;

/// displayingFlatItems 是 flatItems 的子集，仅包含用户可以看到的 items，而那些被折叠的 items 会被剔除。换句话说，当用户展开或收起 item 时，displayingFlatItems 属性会被 buildDisplayingFlatItems 方法不断更新
@property(nonatomic, copy, readwrite) NSArray<LookinDisplayItem *> *displayingFlatItems;

@property(nonatomic, strong, readwrite) NSMenu *selectColorMenu;
@property(nonatomic, copy) NSDictionary<NSNumber *, LookinDisplayItem *> *oidToDisplayItemMap;

/// 取色菜单与颜色别名的解析、构建委托给该 builder（原实现内联在本类，见 LKHierarchyColorMenuBuilder）
@property(nonatomic, strong) LKHierarchyColorMenuBuilder *colorMenuBuilder;

@end

@implementation LKHierarchyDataSource

- (instancetype)init {
    if (self = [super init]) {
        _itemDidChangeHiddenAlphaValue = [RACSubject subject];
        _itemDidChangeAttrGroup = [RACSubject subject];
        _itemDidChangeNoPreview = [RACSubject subject];
        _didReloadHierarchyInfo = [RACSubject subject];
        _willReloadHierarchyInfo = [RACSubject subject];
        _didReloadFlatItemsWithSearchOrFocus = [RACSubject subject];
        
        @weakify(self);
        [[[RACObserve([LKPreferenceManager mainManager], rgbaFormat) skip:1] distinctUntilChanged] subscribeNext:^(id  _Nullable x) {
            @strongify(self);
            [self _setUpColors];
        }];
    }
    return self;
}

- (void)reloadWithHierarchyInfo:(LookinHierarchyInfo *)info keepState:(BOOL)keepState {
    self.rawHierarchyInfo = info;
    
    [self.willReloadHierarchyInfo sendNext:nil];

    if (info.colorAlias.count) {
        [LKPreferenceManager mainManager].receivingConfigTime_Color = [[NSDate date] timeIntervalSince1970];
    }
    if (info.collapsedClassList.count) {
        [LKPreferenceManager mainManager].receivingConfigTime_Class = [[NSDate date] timeIntervalSince1970];
    }
    
    unsigned long prevSelectedOid = 0;
    NSMutableDictionary *prevExpansionMap = nil;
    if (keepState) {
        prevSelectedOid = self.selectedItem.layerObject.oid;
        
        prevExpansionMap = [NSMutableDictionary dictionary];
        [self.flatItems enumerateObjectsUsingBlock:^(LookinDisplayItem * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
            prevExpansionMap[@(obj.layerObject.oid)] = @(obj.isExpanded);
        }];
    }
    
    // 设置 color alias 和 select color menu
    [self _setUpColors];
    
    // 根据 subitems 属性打平为二维数组，同时给每个 item 设置 indentLevel
    self.rawFlatItems = [LookinDisplayItem flatItemsFromHierarchicalItems:info.displayItems];
    NSArray<LookinDisplayItem *> *flatItems = self.rawFlatItems.copy;
    
    // 设置 preferToBeCollapsed 属性
    NSSet<NSString *> *classesPreferredToCollapse = [NSSet setWithObjects:@"UILabel", @"UIPickerView", @"UIProgressView", @"UIActivityIndicatorView", @"UIAlertView", @"UIActionSheet", @"UISearchBar", @"UIButton", @"UITextView", @"UIDatePicker", @"UIPageControl", @"UISegmentedControl", @"UITextField", @"UISlider", @"UISwitch", @"UIVisualEffectView", @"UIImageView", @"WKCommonWebView", @"UITextEffectsWindow", nil];
    if (info.collapsedClassList.count) {
        classesPreferredToCollapse = [classesPreferredToCollapse setByAddingObjectsFromArray:info.collapsedClassList];
    }
    // no preview
    NSSet<NSString *> *classesWithNoPreview = [NSSet setWithArray:@[@"UITextEffectsWindow", @"UIRemoteKeyboardWindow"]];
    
    __block BOOL hasCustomSubviews = NO;
    __block BOOL hasCustomAttrs = NO;
    [flatItems enumerateObjectsUsingBlock:^(LookinDisplayItem * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        if ([obj itemIsKindOfClassesWithNames:classesPreferredToCollapse]) {
            [obj enumerateSelfAndChildren:^(LookinDisplayItem *item) {
                item.preferToBeCollapsed = YES;
            }];
        }
        
        if (obj.indentLevel == 0) {
            if ([obj itemIsKindOfClassesWithNames:classesWithNoPreview]) {
                obj.noPreview = YES;
            }
        }
        
        if (!obj.isUserCustom && !obj.shouldCaptureImage) {
            [obj enumerateSelfAndChildren:^(LookinDisplayItem *item) {
                item.noPreview = YES;
                item.doNotFetchScreenshotReason = LookinDoNotFetchScreenshotForUserConfig;
            }];
        }
//        } else if ([LKPreferenceManager mainManager].showHiddenItems.currentBOOLValue == NO && obj.inHiddenHierarchy) {
//            [obj enumerateSelfAndChildren:^(LookinDisplayItem *item) {
//                item.noPreview = YES;
//                item.doNotFetchScreenshotReason = LookinDoNotFetchScreenshotForHidden;
//            }];
//        }
        
        if (!self.serverSideIsSwiftProject) {
            if ([obj.displayingObject.lk_completedDemangledClassName containsString:@"."]) {
                _serverSideIsSwiftProject = YES;
            }
        }
        
        if (obj.customInfo.danceuiSource.length > 0) {
            [LKDanceUIAttrMaker makeDanceUIJumpAttribute:obj danceSource:obj.customInfo.danceuiSource];
        }
        
        if (obj.isUserCustom) {
            hasCustomSubviews = YES;
        }
        if (obj.customAttrGroupList.count > 0) {
            hasCustomAttrs = YES;
        }
    }];
    [MSACAnalytics trackEvent:@"CustomSubview" withProperties:@{@"Has": hasCustomSubviews ? @"True" : @"False"}];
    [MSACAnalytics trackEvent:@"CustomAttrs" withProperties:@{@"Has": hasCustomAttrs ? @"True" : @"False"}];
    
    self.flatItems = flatItems;
    
    // 设置选中
    LookinDisplayItem *shouldSelectedItem = nil;
    if (keepState) {
        LookinDisplayItem *prevSelectedItem = [self displayItemWithOid:prevSelectedOid];
        if (prevSelectedItem) {
            shouldSelectedItem = prevSelectedItem;
        }
    }

    // 设置展开和折叠
    NSInteger expansionIndex = self.preferenceManager.expansionIndex;
    if (self.flatItems.count > 300) {
        if (expansionIndex > 2) {
            expansionIndex = 2;
        }
    }
    [self adjustExpansionByIndex:expansionIndex referenceDict:(keepState ? prevExpansionMap : nil) selectedItem:(shouldSelectedItem ? nil : &shouldSelectedItem)];
    
    if (self.flatItems.count > 20 && self.displayingFlatItems.count < 10 && expansionIndex > 1) {
        // 被展开的图层太少了，所以忽略 referDict 重新调整。通常是由于 iOS App 重新编译或者界面改变了导致之前被展开的图层都被释放掉了
        NSLog(@"adjust expansion again");
        [self adjustExpansionByIndex:expansionIndex referenceDict:nil selectedItem:nil];
    }
    
    if (!shouldSelectedItem) {
        shouldSelectedItem = self.flatItems.firstObject;
    }
    self.selectedItem = shouldSelectedItem;

    if (self.state != LKHierarchyDataSourceStateNormal) {
        // 可能在 search 或 focus 状态，要退出
        self.state = LKHierarchyDataSourceStateNormal;
    }
    
    [self.didReloadHierarchyInfo sendNext:nil];
}

- (NSInteger)numberOfRows {
    return self.displayingFlatItems.count;
}

- (LookinDisplayItem *)itemAtRow:(NSInteger)index {
    if (index < 0) {
        return nil;
    }
    if ([self.displayingFlatItems lookin_hasIndex:index]) {
        return self.displayingFlatItems[index];
    }
    return nil;
}

- (NSInteger)rowForItem:(LookinDisplayItem *)item {
    NSInteger row = [self.displayingFlatItems indexOfObject:item];
    return row;
}

- (void)setSelectedItem:(LookinDisplayItem *)selectedItem {
    if (_selectedItem == selectedItem) {
        return;
    }
    LookinDisplayItem *prevItem = _selectedItem;
    _selectedItem = selectedItem;
    
    [prevItem notifySelectionChangeToDelegates];
    [_selectedItem notifySelectionChangeToDelegates];

    [[LKUserActionManager sharedInstance] sendAction:LKUserActionType_SelectedItemChange];
    
    if (NSColorPanel.sharedColorPanelExists) {
        [[NSColorPanel sharedColorPanel] close];
    }

    if (!selectedItem && self.preferenceManager.measureState.currentIntegerValue != LookinMeasureState_no) {
        // 如果当前在测距，则取消
        [self.preferenceManager.measureState setIntegerValue:LookinMeasureState_no ignoreSubscriber:nil];
    }
}

- (void)setHoveredItem:(LookinDisplayItem *)hoveredItem {
    if (_hoveredItem == hoveredItem) {
        return;
    }
    LookinDisplayItem *prevItem = _hoveredItem;
    _hoveredItem = hoveredItem;
    [prevItem notifyHoverChangeToDelegates];
    [_hoveredItem notifyHoverChangeToDelegates];
}

- (void)adjustExpansionByIndex:(NSInteger)index referenceDict:(NSDictionary<NSNumber *, NSNumber *> *)referenceDict selectedItem:(LookinDisplayItem **)selectedItem {
    if (index < 0 || index > 4) {
        NSAssert(NO, @"adjustExpansionByIndex, index 为 %@", @(index));
        index = MAX(MIN(index, 4), 0);
    }
    
    self.preferenceManager.expansionIndex = index;
    
    __block NSUInteger expandedCount = self.flatItems.count;
    [self.flatItems enumerateObjectsUsingBlock:^(LookinDisplayItem * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        obj.hasDeterminedExpansion = NO;

        if (!obj.isExpandable) {
            obj.hasDeterminedExpansion = YES;
            expandedCount--;
            return;
        }
        
        if (referenceDict) {
            NSNumber *prevState = referenceDict[@(obj.layerObject.oid)];
            if (prevState != nil) {
                // 旧的对象，直接维持之前的状态
                obj.isExpanded = [prevState boolValue];
                obj.hasDeterminedExpansion = YES;
                if (!obj.isExpanded) {
                    expandedCount--;
                }
            }
        }
    }];
    
    if (index == 0) {
        // 全部折叠，只剩下最顶层的 UIWindow
        
        __block LookinDisplayItem *preferedSelectedItem = nil;
        [self.flatItems enumerateObjectsUsingBlock:^(LookinDisplayItem * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
            if (obj.hasDeterminedExpansion) {
                return;
            }
            obj.isExpanded = NO;
            
            if (obj.representedAsKeyWindow) {
                preferedSelectedItem = obj;
            }
        }];
            
        if (selectedItem) {
            *selectedItem = preferedSelectedItem;
        }
        
    } else if (index == 4) {
        // 全部展开，包括 UIButton、UITabBar、UINavigationBar 等等，全部展开
        [self.flatItems enumerateObjectsUsingBlock:^(LookinDisplayItem * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
            if (obj.hasDeterminedExpansion) {
                return;
            }
            if (obj.inNoPreviewHierarchy) {
                obj.isExpanded = NO;
                return;
            }
            obj.isExpanded = YES;
        }];
        
        if (selectedItem) {
            __block LookinDisplayItem *preferedSelectedItem = nil;
            LookinDisplayItem *keyWindowRootItem = [self.rawHierarchyInfo.displayItems lookin_firstFiltered:^BOOL(LookinDisplayItem *obj) {
                return obj.representedAsKeyWindow;
            }];
            [[LookinDisplayItem flatItemsFromHierarchicalItems:@[keyWindowRootItem]] enumerateObjectsWithOptions:NSEnumerationReverse usingBlock:^(LookinDisplayItem * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
                if (!!obj.hostViewControllerObject) {
                    preferedSelectedItem = obj;
                    *stop = YES;
                }
            }];
            *selectedItem = preferedSelectedItem;
        }
        
    } else {
        LookinDisplayItem *keyWindowItem = [self.rawHierarchyInfo.displayItems lookin_firstFiltered:^BOOL(LookinDisplayItem *windowItem) {
            return windowItem.representedAsKeyWindow;
        }];
        if (!keyWindowItem) {
            keyWindowItem = self.rawHierarchyInfo.displayItems.firstObject;
        }
        [self.rawHierarchyInfo.displayItems enumerateObjectsUsingBlock:^(LookinDisplayItem * _Nonnull windowItem, NSUInteger idx, BOOL * _Nonnull stop) {
            if (windowItem == keyWindowItem) {
                return;
            }
            // 非 keyWindow 上的都折叠起来
            [[LookinDisplayItem flatItemsFromHierarchicalItems:@[windowItem]] enumerateObjectsUsingBlock:^(LookinDisplayItem * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
                if (obj.hasDeterminedExpansion) {
                    return;
                }
                obj.isExpanded = NO;
                obj.hasDeterminedExpansion = YES;
            }];
        }];
        
        NSArray<LookinDisplayItem *> *UITransitionViewItems = [keyWindowItem.subitems lookin_filter:^BOOL(LookinDisplayItem *obj) {
            return [obj.title isEqualToString:@"UITransitionView"];
        }];
        [UITransitionViewItems enumerateObjectsUsingBlock:^(LookinDisplayItem * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
            if (obj.hasDeterminedExpansion) {
                return;
            }
            if (idx == (UITransitionViewItems.count - 1)) {
                // 展开最后一个 UITransitionView
                obj.isExpanded = YES;
            } else {
                // 折叠前几个 UITransitionView
                obj.isExpanded = NO;
            }
            obj.hasDeterminedExpansion = YES;
        }];
        
        NSMutableArray<LookinDisplayItem *> *viewControllerItems = [NSMutableArray array];
        [[LookinDisplayItem flatItemsFromHierarchicalItems:@[keyWindowItem]] enumerateObjectsUsingBlock:^(LookinDisplayItem * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
            if (!!obj.hostViewControllerObject) {
                [viewControllerItems addObject:obj];
                return;
            }
            if (obj.hasDeterminedExpansion) {
                return;
            }
            if (obj.inNoPreviewHierarchy || obj.preferToBeCollapsed || (![LKPreferenceManager mainManager].showHiddenItems && obj.inHiddenHierarchy)) {
                // 把 noPreview 和 UIButton 之类常用控件叠起来
                obj.isExpanded = NO;
                obj.hasDeterminedExpansion = YES;
                return;
            }
            if ([obj itemIsKindOfClassesWithNames:[NSSet setWithObjects:@"UINavigationBar", @"UITabBar", nil]]) {
                // 把 NavigationBar 和 TabBar 折叠起来
                [obj enumerateSelfAndChildren:^(LookinDisplayItem *item) {
                    if (item.hasDeterminedExpansion) {
                        return;
                    }
                    item.isExpanded = NO;
                    item.hasDeterminedExpansion = YES;
                }];
                return;
            }
        }];
        
        if (selectedItem) {
            *selectedItem = viewControllerItems.lastObject;
        }
        
        if (index == 1) {
            // 恰好把 viewController 显示出来
            // 倒序，以确保多个 viewController 在同一条树上时，只有最 leaf 的那一个是被折叠的
            [viewControllerItems enumerateObjectsWithOptions:NSEnumerationReverse usingBlock:^(LookinDisplayItem * _Nonnull viewControllerItem, NSUInteger idx, BOOL * _Nonnull stop) {
                [viewControllerItem enumerateSelfAndAncestors:^(LookinDisplayItem *item, BOOL *stop) {
                    // 把 viewController 的 ancestors 都展开
                    if (item.hasDeterminedExpansion) {
                        return;
                    }
                    item.isExpanded = (item != viewControllerItem);
                    item.hasDeterminedExpansion = YES;
                }];
            }];
            
            // 剩下未处理的都折叠
            [self.flatItems enumerateObjectsUsingBlock:^(LookinDisplayItem * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
                if (obj.hasDeterminedExpansion) {
                    return;
                }
                obj.isExpanded = NO;
            }];
        
        } else if (index == 2) {
            // 从 viewController 开始算向 leaf 多推 3 层
            [viewControllerItems enumerateObjectsWithOptions:NSEnumerationReverse usingBlock:^(LookinDisplayItem * _Nonnull viewControllerItem, NSUInteger idx, BOOL * _Nonnull stop) {
                [viewControllerItem enumerateAncestors:^(LookinDisplayItem *item, BOOL *stop) {
                    // 把 viewController 的 ancestors 都展开
                    if (item.hasDeterminedExpansion) {
                        return;
                    }
                    item.isExpanded = YES;
                    item.hasDeterminedExpansion = YES;
                }];
                
                BOOL hasTableOrCollectionView = [viewControllerItem.subitems.firstObject itemIsKindOfClassesWithNames:[NSSet setWithObjects:@"UITableView", @"UICollectionView", nil]];
                // 如果是那种典型的 UITableView 或 UICollectionView 的话，则向 leaf 方向推进 2 层（这样就可以让 cell 恰好露出来而不露出来 cell 的 contentView），否则就推 3 层
                NSUInteger indentsForward = hasTableOrCollectionView ? 2 : 3;

                [viewControllerItem enumerateSelfAndChildren:^(LookinDisplayItem *item) {
                    if (item.hasDeterminedExpansion) {
                        return;
                    }
                    if (item.indentLevel < viewControllerItem.indentLevel + indentsForward) {
                        item.isExpanded = YES;
                        item.hasDeterminedExpansion = YES;
                    }
                }];
            }];
            
            // 剩下未处理的都折叠
            [self.flatItems enumerateObjectsUsingBlock:^(LookinDisplayItem * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
                if (obj.hasDeterminedExpansion) {
                    return;
                }
                obj.isExpanded = NO;
            }];
            
        } else if (index == 3) {
            // 展开大部分
            [self.flatItems enumerateObjectsUsingBlock:^(LookinDisplayItem * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
                if (obj.hasDeterminedExpansion) {
                    return;
                }
                obj.isExpanded = YES;
                obj.hasDeterminedExpansion = YES;
            }];
        }
    }
    
    [self buildDisplayingFlatItems];
}

- (LookinDisplayItem *)displayItemWithOid:(unsigned long)oid {
    LookinDisplayItem *item = self.oidToDisplayItemMap[@(oid)];
    return item;
}

- (void)setRawFlatItems:(NSArray<LookinDisplayItem *> *)rawFlatItems {
    _rawFlatItems = rawFlatItems.copy;
    
    NSMutableDictionary<NSNumber *, LookinDisplayItem *> *map = [NSMutableDictionary dictionaryWithCapacity:rawFlatItems.count * 2];
    [rawFlatItems enumerateObjectsUsingBlock:^(LookinDisplayItem * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        if (obj.viewObject.oid) {
            map[@(obj.viewObject.oid)] = obj;
        }
        if (obj.layerObject.oid) {
            map[@(obj.layerObject.oid)] = obj;
        }
        if (obj.windowObject.oid) {
            map[@(obj.windowObject.oid)] = obj;
        }
    }];
    self.oidToDisplayItemMap = map;
}

- (void)buildDisplayingFlatItems {
    NSMutableArray<LookinDisplayItem *> *displayingItems = [NSMutableArray array];
    [self.flatItems enumerateObjectsUsingBlock:^(LookinDisplayItem * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        if (obj.displayingInHierarchy) {
            [displayingItems addObject:obj];
        }
    }];
    self.displayingFlatItems = displayingItems;
}

- (void)collapseItem:(LookinDisplayItem *)item {
    if (!item.isExpandable) {
        return;
    }
    if (!item.isExpanded) {
        return;
    }
    item.isExpanded = NO;
    [self buildDisplayingFlatItems];
}

- (void)expandItem:(LookinDisplayItem *)item {
    if (!item.isExpandable) {
        return;
    }
    if (item.isExpanded) {
        return;
    }
    item.isExpanded = YES;
    [self buildDisplayingFlatItems];
}

- (void)expandToShowItem:(LookinDisplayItem *)item {
    [item enumerateAncestors:^(LookinDisplayItem *targetItem, BOOL *stop) {
        if (!targetItem.isExpanded) {
            targetItem.isExpanded = YES;
        }
    }];
    
    [self buildDisplayingFlatItems];
}

- (void)expandItemsRootedByItem:(LookinDisplayItem *)item {
    if (item.preferToBeCollapsed) {
        [item enumerateSelfAndChildren:^(LookinDisplayItem *targetItem) {
            if (targetItem.isExpandable && !targetItem.isExpanded) {
                targetItem.isExpanded = YES;
            }
        }];
    } else {
        [item enumerateSelfAndChildren:^(LookinDisplayItem *targetItem) {
            if (targetItem.isExpandable && !targetItem.isExpanded && ![targetItem preferToBeCollapsed]) {
                targetItem.isExpanded = YES;
            }
        }];
    }
    
    [self buildDisplayingFlatItems];
}

- (void)collapseAllChildrenOfItem:(LookinDisplayItem *)item {
    [item enumerateSelfAndChildren:^(LookinDisplayItem *enumeratedItem) {
        if (enumeratedItem == item) {
            return;
        }
        if (!enumeratedItem.isExpandable) {
            return;
        }
        if (!enumeratedItem.isExpanded) {
            return;
        }
        enumeratedItem.isExpanded = NO;
    }];
    [self buildDisplayingFlatItems];
}

#pragma mark - Search

- (void)searchWithString:(NSString *)string {
    if (string.length == 0) {
        NSAssert(NO, @"");
        return;
    }
    
    if (self.state != LKHierarchyDataSourceStateSearch) {
        [self.rawFlatItems enumerateObjectsUsingBlock:^(LookinDisplayItem * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
            obj.isExpandedBeforeSearchOrFocus = obj.isExpanded;
        }];
        self.state = LKHierarchyDataSourceStateSearch;
    }
    
    self.selectedItem = nil;
    
    /// 被打上这个标记的都是本次搜索需要在界面中显示出来的（尽管可能会被折叠）
    NSString *Key_ShouldShow = @"show";
    [self.rawFlatItems enumerateObjectsUsingBlock:^(LookinDisplayItem * _Nonnull displayItem, NSUInteger idx, BOOL * _Nonnull stop) {
        // 先
        [displayItem lookin_bindBOOL:NO forKey:Key_ShouldShow];
        displayItem.highlightedSearchString = nil;
    }];
    [self.rawFlatItems enumerateObjectsUsingBlock:^(LookinDisplayItem * _Nonnull displayItem, NSUInteger idx, BOOL * _Nonnull stop) {
        BOOL isMatched = [displayItem isMatchedWithSearchString:string];
        if (isMatched) {
            displayItem.highlightedSearchString = string;
            [displayItem enumerateAncestors:^(LookinDisplayItem *ancestor, BOOL *stop) {
                // 上级元素都显示且展开
                ancestor.isExpanded = YES;
                [ancestor lookin_bindBOOL:YES forKey:Key_ShouldShow];
            }];
            [displayItem enumerateSelfAndChildren:^(LookinDisplayItem *selfOrChild) {
                // 自身和下级元素都显示但折叠，允许用户手动展开
                selfOrChild.isExpanded = NO;
                [selfOrChild lookin_bindBOOL:YES forKey:Key_ShouldShow];
            }];
        }
    }];
    
    NSArray<LookinDisplayItem *> *flatItems = [self.rawFlatItems lookin_filter:^BOOL(LookinDisplayItem *displayItem) {
        BOOL shouldShow = [displayItem lookin_getBindBOOLForKey:Key_ShouldShow];
        if (shouldShow) {
            displayItem.isInSearch = YES;
        }
        return shouldShow;
    }];
    self.flatItems = flatItems;
    [self.didReloadFlatItemsWithSearchOrFocus sendNext:nil];
    
    [self buildDisplayingFlatItems];
}

// 有可能从 normal 状态或 search 状态进入该状态
- (void)focusDisplayItem:(LookinDisplayItem *)item {
    [MSACAnalytics trackEvent:@"Focus"];

    if (!item) {
        NSAssert(NO, @"");
        return;
    }

    if (self.state == LKHierarchyDataSourceStateNormal) {
        [self.rawFlatItems enumerateObjectsUsingBlock:^(LookinDisplayItem * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
            obj.isExpandedBeforeSearchOrFocus = obj.isExpanded;
        }];
    } else if (self.state == LKHierarchyDataSourceStateSearch) {
        [self.rawFlatItems enumerateObjectsUsingBlock:^(LookinDisplayItem * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
            obj.isInSearch = NO;
            obj.highlightedSearchString = nil;
        }];
    }
    self.state = LKHierarchyDataSourceStateFocus;

    NSMutableArray *newFlatItems = [NSMutableArray array];
    [item enumerateSelfAndChildren:^(LookinDisplayItem *currItem) {
        [newFlatItems addObject:currItem];
    }];
    self.flatItems = newFlatItems;
    [self.didReloadFlatItemsWithSearchOrFocus sendNext:nil];
    [self buildDisplayingFlatItems];
}

- (void)endFocus {
    if (self.state == LKHierarchyDataSourceStateNormal) {
        return;
    }
    self.state = LKHierarchyDataSourceStateNormal;
    
    [self.rawFlatItems enumerateObjectsUsingBlock:^(LookinDisplayItem * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        obj.isExpanded = obj.isExpandedBeforeSearchOrFocus;
    }];
    
    self.flatItems = self.rawFlatItems;
    [self.didReloadFlatItemsWithSearchOrFocus sendNext:nil];
    [self buildDisplayingFlatItems];
}

- (void)endSearch {
    if (self.state == LKHierarchyDataSourceStateNormal) {
        return;
    }
    self.state = LKHierarchyDataSourceStateNormal;
    
    [self.rawFlatItems enumerateObjectsUsingBlock:^(LookinDisplayItem * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
        obj.isInSearch = NO;
        obj.highlightedSearchString = nil;
        obj.isExpanded = obj.isExpandedBeforeSearchOrFocus;
    }];
    /// 搜索时被选中的 item，在结束搜索后也应该处于被选中且可见的状态
    [self.selectedItem enumerateAncestors:^(LookinDisplayItem *item, BOOL *stop) {
        item.isExpanded = YES;
    }];
    
    self.flatItems = self.rawFlatItems;
    [self.didReloadFlatItemsWithSearchOrFocus sendNext:nil];
    
    [self buildDisplayingFlatItems];
}

#pragma mark - Colors

- (NSArray<NSString *> *)aliasForColor:(NSColor *)color {
    if (!color) {
        return nil;
    }
    return self.colorMenuBuilder.colorToAliasMap[color.rgbaString];
}

- (void)_setUpColors {
    self.selectColorMenu = [self.colorMenuBuilder menuWithColorAlias:self.rawHierarchyInfo.colorAlias
                                                          rgbaFormat:[LKPreferenceManager mainManager].rgbaFormat];
}

- (LKHierarchyColorMenuBuilder *)colorMenuBuilder {
    if (!_colorMenuBuilder) {
        _colorMenuBuilder = [LKHierarchyColorMenuBuilder new];
    }
    return _colorMenuBuilder;
}

#pragma mark - Others

/// 子类实现该方法
- (LKPreferenceManager *)preferenceManager {
    NSAssert(NO, @"should implement by subclass");
    return nil;
}

- (void)dealloc {
    NSLog(@"%@ dealloc", self.class);
}

- (BOOL)isReadOnly {
    return YES;
}

@end
