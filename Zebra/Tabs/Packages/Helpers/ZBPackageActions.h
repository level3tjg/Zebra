//
//  ZBPackageActions.h
//  Zebra
//
//  Created by Thatchapon Unprasert on 13/5/2019
//  Copyright © 2019 Wilson Styres. All rights reserved.
//

@class ZBPackage;
@class PLPackage;
#import <UIKit/UIKit.h>

#import <Queue/ZBQueueType.h>
#import <Extensions/UIBarButtonItem+blocks.h>

typedef NS_OPTIONS(NSUInteger, ZBPackageActionType) {
    ZBPackageActionInstall = 1 << 1,
    ZBPackageActionUpgrade = 1 << 2,
    ZBPackageActionRemove = 1 << 3,
    ZBPackageActionReinstall = 1 << 4,
    ZBPackageActionDowngrade = 1 << 5,
    ZBPackageActionSelectVersion = 1 << 6,
};

typedef enum : NSUInteger {
    ZBPackageExtraActionShowUpdates,
    ZBPackageExtraActionHideUpdates,
    ZBPackageExtraActionAddFavorite,
    ZBPackageExtraActionRemoveFavorite,
    ZBPackageExtraActionBlockAuthor,
    ZBPackageExtraActionUnblockAuthor,
    ZBPackageExtraActionShare,
} ZBPackageExtraActionType;

NS_ASSUME_NONNULL_BEGIN

@interface ZBPackageActions : NSObject
+ (void)performAction:(ZBPackageActionType)action forPackages:(NSArray <ZBPackage *> *)package completion:(void (^)(void))completion;
+ (void)buttonTitleForPackage:(PLPackage *)package completion:(void (^)(NSString * _Nullable title))completion;
+ (void (^)(void))buttonActionForPackage:(PLPackage *)package completion:(nullable void(^)(void))completion;
+ (UISwipeActionsConfiguration *)swipeActionsForPackage:(ZBPackage *)package inTableView:(UITableView *)tableView;
+ (NSArray <UIAlertAction *> *)alertActionsForPackage:(PLPackage *)package completion:(nullable void(^)(void))completion;
+ (NSArray <UIAlertAction *> *)extraAlertActionsForPackage:(ZBPackage *)package selectionCallback:(void (^)(ZBPackageExtraActionType action))callback;
+ (NSArray <UIPreviewAction *> *)previewActionsForPackage:(ZBPackage *)package inTableView:(UITableView *_Nullable)tableView;
+ (NSArray <UIAction *> *)menuElementsForPackage:(ZBPackage *)package inTableView:(UITableView *_Nullable)tableView API_AVAILABLE(ios(13.0));
@end

NS_ASSUME_NONNULL_END
