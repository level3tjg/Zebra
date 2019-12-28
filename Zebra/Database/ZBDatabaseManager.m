//
//  ZBDatabaseManager.m
//  Zebra
//
//  Created by Wilson Styres on 11/30/18.
//  Copyright © 2018 Wilson Styres. All rights reserved.
//

@import Crashlytics;

#import "ZBDatabaseManager.h"
#import "ZBDependencyResolver.h"

#import <ZBLog.h>
#import <ZBDevice.h>
#import <Parsel/parsel.h>
#import <Parsel/vercmp.h>
#import <ZBAppDelegate.h>
#import <Repos/Helpers/ZBRepo.h>
#import <Packages/Helpers/ZBPackage.h>
#import <Downloads/ZBDownloadManager.h>
#import <Database/ZBColumn.h>
#import <Queue/ZBQueue.h>

@interface ZBDatabaseManager () {
    int numberOfDatabaseUsers;
    int numberOfUpdates;
    NSMutableArray *installedPackageIDs;
    NSMutableArray *upgradePackageIDs;
    BOOL databaseBeingUpdated;
    BOOL haltdDatabaseOperations;
}
@end

@implementation ZBDatabaseManager

@synthesize needsToPresentRefresh;
@synthesize database;

+ (id)sharedInstance {
    static ZBDatabaseManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [ZBDatabaseManager new];
        
        [instance openDatabase];
        
        // Checks to see if any of the databases have differing schemes and sets to update them if need be.
        [instance setNeedsToPresentRefresh:(needsMigration(instance.database, 0) != 0 || needsMigration(instance.database, 1) != 0 || needsMigration(instance.database, 2) != 0)];
        
        [instance closeDatabase];
        instance.databaseDelegates = [NSMutableArray new];
    });
    return instance;
}

+ (NSDate *)lastUpdated {
    NSDate *lastUpdatedDate = (NSDate *)[[NSUserDefaults standardUserDefaults] objectForKey:@"lastUpdatedDate"];
    return lastUpdatedDate != NULL ? lastUpdatedDate : [NSDate distantPast];
}

- (id)init {
    self = [super init];

    if (self) {
        numberOfUpdates = 0;
    }

    return self;
}

#pragma mark - Opening and Closing the Database

- (int)openDatabase {
    if (![self isDatabaseOpen] || !database) {
//        sqlite3_shutdown();
        assert(sqlite3_threadsafe());
        int result = sqlite3_open_v2([[ZBAppDelegate databaseLocation] UTF8String], &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_CREATE, NULL);
        if (result == SQLITE_OK) {
            [self increment];
        }
        return result;
    } else {
        [self increment];
        return SQLITE_OK;
    }
}

- (void)increment {
    @synchronized(self) {
        ++numberOfDatabaseUsers;
    }
}

- (void)decrement {
    @synchronized(self) {
        --numberOfDatabaseUsers;
    }
}

- (int)closeDatabase {
    @synchronized(self) {
        if (numberOfDatabaseUsers == 0) {
            return SQLITE_ERROR;
        }
    }
    
    if (--numberOfDatabaseUsers == 0 && [self isDatabaseOpen]) {
        int result = sqlite3_close(database);
        database = NULL;
        return result;
    }
    return SQLITE_OK;
}

- (BOOL)isDatabaseBeingUpdated {
    return databaseBeingUpdated;
}

- (void)setDatabaseBeingUpdated:(BOOL)updated {
    databaseBeingUpdated = updated;
}

- (BOOL)isDatabaseOpen {
    @synchronized(self) {
        return numberOfDatabaseUsers > 0 || database != NULL;
    }
}

- (void)printDatabaseError {
    databaseBeingUpdated = NO;
    const char *error = sqlite3_errmsg(database);
    if (error) {
        CLS_LOG(@"Database Error: %s", error);
        NSLog(@"[Zebra] Database Error: %s", error);
    }
}

- (void)addDatabaseDelegate:(id <ZBDatabaseDelegate>)delegate {
    if (![self.databaseDelegates containsObject:delegate]) {
        [self.databaseDelegates addObject:delegate];
    }
}

- (void)removeDatabaseDelegate:(id <ZBDatabaseDelegate>)delegate {
    [self.databaseDelegates removeObject:delegate];
}

- (void)bulkDatabaseStartedUpdate {
    for (int i = 0; i < self.databaseDelegates.count; ++i) {
        id <ZBDatabaseDelegate> delegate = self.databaseDelegates[i];
        [delegate databaseStartedUpdate];
    }
}

- (void)bulkDatabaseCompletedUpdate:(int)updates {
    databaseBeingUpdated = NO;
    for (int i = 0; i < self.databaseDelegates.count; ++i) {
        id <ZBDatabaseDelegate> delegate = self.databaseDelegates[i];
        [delegate databaseCompletedUpdate:updates];
    }
}

- (void)bulkPostStatusUpdate:(NSString *)status atLevel:(ZBLogLevel)level {
    for (int i = 0; i < self.databaseDelegates.count; ++i) {
        id <ZBDatabaseDelegate> delegate = self.databaseDelegates[i];
        if ([delegate respondsToSelector:@selector(postStatusUpdate:atLevel:)]) {
            [delegate postStatusUpdate:status atLevel:level];
        }
    }
}

- (void)bulkSetRepo:(NSString *)bfn busy:(BOOL)busy {
    for (int i = 0; i < self.databaseDelegates.count; ++i) {
        id <ZBDatabaseDelegate> delegate = self.databaseDelegates[i];
        if ([delegate respondsToSelector:@selector(setRepo:busy:)]) {
            [delegate setRepo:bfn busy:busy];
        }
    }
}

#pragma mark - Populating the database

- (void)updateDatabaseUsingCaching:(BOOL)useCaching userRequested:(BOOL)requested {
    if (databaseBeingUpdated)
        return;
    databaseBeingUpdated = YES;
    
    BOOL needsUpdate = NO;
    if (requested && haltdDatabaseOperations) {
        [self setHaltDatabaseOperations:false];
    }
    
    if (!requested) {
        NSDate *currentDate = [NSDate date];
        NSDate *lastUpdatedDate = [ZBDatabaseManager lastUpdated];
        
        if (lastUpdatedDate != NULL) {
            NSCalendar *gregorian = [[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierGregorian];
            NSUInteger unitFlags = NSCalendarUnitMinute;
            NSDateComponents *components = [gregorian components:unitFlags fromDate:lastUpdatedDate toDate:currentDate options:0];
            
            needsUpdate = ([components minute] >= 30); // might need to be less
        } else {
            needsUpdate = YES;
        }
    }
    
    if (requested || needsUpdate) {
        [self checkForZebraRepo];
        [self bulkDatabaseStartedUpdate];
        self.downloadManager = [[ZBDownloadManager alloc] initWithDownloadDelegate:self sourceListPath:[ZBAppDelegate sourcesListPath]];
        [self bulkPostStatusUpdate:@"Updating Repositories\n" atLevel:ZBLogLevelInfo];
        [self.downloadManager downloadReposAndIgnoreCaching:!useCaching];
    } else {
        [self importLocalPackagesAndCheckForUpdates:YES sender:self];
    }
}

- (void)updateRepo:(ZBRepo *)repo useCaching:(BOOL)useCaching {
    if (databaseBeingUpdated)
        return;
    databaseBeingUpdated = YES;
    
    [self bulkDatabaseStartedUpdate];
    self.downloadManager = [[ZBDownloadManager alloc] initWithDownloadDelegate:self repo:repo];
    [self.downloadManager downloadReposAndIgnoreCaching:!useCaching];
}

- (void)updateRepoURLs:(NSArray <NSURL *> *)repoURLs useCaching:(BOOL)useCaching {
    if (databaseBeingUpdated)
        return;
    databaseBeingUpdated = YES;
    
    [self bulkDatabaseStartedUpdate];
    self.downloadManager = [[ZBDownloadManager alloc] initWithDownloadDelegate:self repoURLs:repoURLs];
    [self.downloadManager downloadReposAndIgnoreCaching:!useCaching];
}

- (void)setHaltDatabaseOperations:(BOOL)halt {
    haltdDatabaseOperations = halt;
}

- (void)parseRepos:(NSDictionary *)filenames {
    [[NSNotificationCenter defaultCenter] postNotificationName:@"disableCancelRefresh" object:nil];
    if (haltdDatabaseOperations) {
        CLS_LOG(@"Database operations halted.");
        NSLog(@"[Zebra] Database operations halted");
        [self bulkDatabaseCompletedUpdate:numberOfUpdates];
        return;
    }
    [self bulkPostStatusUpdate:@"Download Completed\n" atLevel:ZBLogLevelInfo];
    self.downloadManager = nil;
    NSArray *releaseFiles = filenames[@"release"];
    NSArray *packageFiles = filenames[@"packages"];
    
    [self bulkPostStatusUpdate:[NSString stringWithFormat:@"%d Release files need to be updated\n", (int)[releaseFiles count]] atLevel:ZBLogLevelInfo];
    [self bulkPostStatusUpdate:[NSString stringWithFormat:@"%d Package files need to be updated\n", (int)[packageFiles count]] atLevel:ZBLogLevelInfo];

    if ([self openDatabase] == SQLITE_OK) {
        for (NSString *releasePath in releaseFiles) {
            NSString *baseFileName = [[releasePath lastPathComponent] stringByReplacingOccurrencesOfString:@"_Release" withString:@""];
            
            int repoID = [self repoIDFromBaseFileName:baseFileName];
            if (repoID == -1) { // Repo does not exist in database, create it.
                repoID = [self nextRepoID];
                if (importRepoToDatabase([[ZBAppDelegate sourcesListPath] UTF8String], [releasePath UTF8String], database, repoID) != PARSEL_OK) {
                    [self bulkPostStatusUpdate:[NSString stringWithFormat:@"Error while opening file: %@\n", releasePath] atLevel:ZBLogLevelError];
                }
            } else {
                if (updateRepoInDatabase([[ZBAppDelegate sourcesListPath] UTF8String], [releasePath UTF8String], database, repoID) != PARSEL_OK) {
                    [self bulkPostStatusUpdate:[NSString stringWithFormat:@"Error while opening file: %@\n", releasePath] atLevel:ZBLogLevelError];
                }
            }
        }
        
        createTable(database, 1);
        sqlite3_exec(database, "CREATE TABLE PACKAGES_SNAPSHOT AS SELECT PACKAGE, VERSION, REPOID, LASTSEEN FROM PACKAGES WHERE REPOID > 0;", NULL, 0, NULL);
        sqlite3_exec(database, "CREATE INDEX tag_PACKAGEVERSION_SNAPSHOT ON PACKAGES_SNAPSHOT (PACKAGE, VERSION);", NULL, 0, NULL);
        sqlite3_int64 currentDate = (int)time(NULL);
        
        for (NSString *packagesPath in packageFiles) {
            NSString *baseFileName = [[packagesPath lastPathComponent] stringByReplacingOccurrencesOfString:@"_Packages" withString:@""];
            baseFileName = [baseFileName stringByReplacingOccurrencesOfString:@"_main_binary-iphoneos-arm" withString:@""];
            
            [self bulkSetRepo:baseFileName busy:YES];
            
            [self bulkPostStatusUpdate:[NSString stringWithFormat:@"Parsing %@\n", baseFileName] atLevel:ZBLogLevelDescript];
            
            int repoID = [self repoIDFromBaseFileName:baseFileName];
            if (repoID == -1) { // Repo does not exist in database, create it (this should never happen).
                NSLog(@"[Zebra] Repo for BFN %@ does not exist in the database.", baseFileName);
                repoID = [self nextRepoID];
                createDummyRepo([[ZBAppDelegate sourcesListPath] UTF8String], [packagesPath UTF8String], database, repoID); // For repos with no release file (notably junesiphone)
                if (updatePackagesInDatabase([packagesPath UTF8String], database, repoID, currentDate) != PARSEL_OK) {
                    [self bulkPostStatusUpdate:[NSString stringWithFormat:@"Error while opening file: %@\n", packagesPath] atLevel:ZBLogLevelError];
                }
            } else {
                if (updatePackagesInDatabase([packagesPath UTF8String], database, repoID, currentDate) != PARSEL_OK) {
                    [self bulkPostStatusUpdate:[NSString stringWithFormat:@"Error while opening file: %@\n", packagesPath] atLevel:ZBLogLevelError];
                }
            }
            
            [self bulkSetRepo:baseFileName busy:NO];
        }
        
        sqlite3_exec(database, "DROP TABLE PACKAGES_SNAPSHOT;", NULL, 0, NULL);
        
        [self bulkPostStatusUpdate:@"Done!\n" atLevel:ZBLogLevelInfo];
        
        [self importLocalPackagesAndCheckForUpdates:YES sender:self];
        [self updateLastUpdated];
        [self bulkDatabaseCompletedUpdate:numberOfUpdates];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"ZBDatabaseCompletedUpdate" object:nil];
        [self closeDatabase];
    } else {
        [self printDatabaseError];
    }
}

- (void)importLocalPackagesAndCheckForUpdates:(BOOL)checkForUpdates sender:(id)sender {
    if (haltdDatabaseOperations) {
        NSLog(@"[Zebra] Database operations halted");
        return;
    }
    
    BOOL needsDelegateStart = !([sender isKindOfClass:[ZBDatabaseManager class]]);
    if (needsDelegateStart) {
        [self bulkDatabaseStartedUpdate];
    }
    NSLog(@"[Zebra] Importing local packages");
    [self importLocalPackages];
    if (checkForUpdates) {
        [self checkForPackageUpdates];
    }
    if (needsDelegateStart) {
        [self bulkDatabaseCompletedUpdate:numberOfUpdates];
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:@"ZBDatabaseCompletedUpdate" object:nil];
    databaseBeingUpdated = NO;
}

- (void)importLocalPackages {
    if (haltdDatabaseOperations) {
        NSLog(@"[Zebra] Database operations halted");
        return;
    }
    
    NSString *installedPath;
    if ([ZBDevice needsSimulation]) { // If the target is a simlator, load a demo list of installed packages
        installedPath = [[NSBundle mainBundle] pathForResource:@"Installed" ofType:@"pack"];
    } else { // Otherwise, load the actual file
        installedPath = @"/var/lib/dpkg/status";
    }
    
    if ([self openDatabase] == SQLITE_OK) {
        // Delete packages from local repos (-1 and 0)
        char *sql = "DELETE FROM PACKAGES WHERE REPOID = 0";
        sqlite3_exec(database, sql, NULL, 0, NULL);
        char *negativeOne = "DELETE FROM PACKAGES WHERE REPOID = -1";
        sqlite3_exec(database, negativeOne, NULL, 0, NULL);
        
        // Import packages from the installedPath
        importPackagesToDatabase([installedPath UTF8String], database, 0);
        
        [self closeDatabase];
    } else {
        [self printDatabaseError];
    }
}

- (void)checkForPackageUpdates {
    if ([self openDatabase] == SQLITE_OK) {
        NSMutableArray *installedPackages = [NSMutableArray new];
        
        sqlite3_stmt *statement;
        if (sqlite3_prepare_v2(database, "SELECT * FROM PACKAGES WHERE REPOID = 0;", -1, &statement, nil) == SQLITE_OK) {
            while (sqlite3_step(statement) == SQLITE_ROW) {
                ZBPackage *package = [[ZBPackage alloc] initWithSQLiteStatement:statement];
                [installedPackages addObject:package];
            }
        } else {
            [self printDatabaseError];
        }
        sqlite3_finalize(statement);
        
        // Check for updates
        NSLog(@"[Zebra] Checking for updates...");
        NSMutableArray *found = [NSMutableArray new];
        
        createTable(database, 2);
        
        numberOfUpdates = 0;
        upgradePackageIDs = [NSMutableArray new];
        for (ZBPackage *package in installedPackages) {
            if ([found containsObject:package.identifier]) {
                ZBLog(@"[Zebra] I already checked %@, skipping", package.identifier);
                continue;
            }
            
            ZBPackage *topPackage = [self topVersionForPackage:package];
            NSComparisonResult compare = [package compare:topPackage];
            if (compare == NSOrderedAscending) {
                NSLog(@"[Zebra] Installed package %@ is less than top package %@, it needs an update", package, topPackage);
                
                BOOL ignoreUpdates = [topPackage ignoreUpdates];
                if (!ignoreUpdates) numberOfUpdates++;
                NSString *query = [NSString stringWithFormat:@"REPLACE INTO UPDATES(PACKAGE, VERSION, IGNORE) VALUES(\'%@\', \'%@\', %d);", [topPackage identifier], [topPackage version], ignoreUpdates ? 1 : 0];
                
                if (sqlite3_prepare_v2(database, [query UTF8String], -1, &statement, nil) == SQLITE_OK) {
                    while (sqlite3_step(statement) == SQLITE_ROW) {
                        break;
                    }
                } else {
                    [self printDatabaseError];
                }
                sqlite3_finalize(statement);
                
                [upgradePackageIDs addObject:[topPackage identifier]];
            } else if (compare == NSOrderedSame) {
                NSString *query;
                BOOL packageIgnoreUpdates = [package ignoreUpdates];
                if (packageIgnoreUpdates)
                    // This package has no update and the user actively ignores updates from it, we update the latest version here
                    query = [NSString stringWithFormat:@"REPLACE INTO UPDATES(PACKAGE, VERSION, IGNORE) VALUES(\'%@\', \'%@\', 1);", package.identifier, package.version];
                else
                    // This package has no update and the user does not ignore updates from it, having the record in the database is waste of space
                    query = [NSString stringWithFormat:@"DELETE FROM UPDATES WHERE PACKAGE = \'%@\';", package.identifier];
                if (sqlite3_prepare_v2(database, [query UTF8String], -1, &statement, nil) == SQLITE_OK) {
                    while (sqlite3_step(statement) == SQLITE_ROW) {
                        break;
                    }
                } else {
                    [self printDatabaseError];
                }
                sqlite3_finalize(statement);
            }
            [found addObject:package.identifier];
        }
        
        //In order to make this easy, we're going to check for "Essential" packages that aren't installed and mark them as updates
        NSMutableArray *essentials = [NSMutableArray new];
        sqlite3_stmt *essentialStatement; //v important statement
        if (sqlite3_prepare_v2(database, "SELECT PACKAGE, VERSION FROM PACKAGES WHERE REPOID > 0 AND ESSENTIAL = \'yes\' COLLATE NOCASE", -1, &essentialStatement, nil) == SQLITE_OK) {
            while (sqlite3_step(essentialStatement) == SQLITE_ROW) {
                const char *identifierChars = (const char *)sqlite3_column_text(essentialStatement, 0);
                const char *versionChars = (const char *)sqlite3_column_text(essentialStatement, 1);
                
                NSString *packageIdentifier = [NSString stringWithUTF8String:identifierChars];
                NSString *version = [NSString stringWithUTF8String:versionChars];
                
                if (![self packageIDIsInstalled:packageIdentifier version:NULL]) {
                    NSDictionary *essentialPackage = @{@"id": packageIdentifier, @"version": version};
                    [essentials addObject:essentialPackage];
                }
            }
        } else {
            [self printDatabaseError];
        }
        sqlite3_finalize(essentialStatement);
        
        for (NSDictionary *essentialPackage in essentials) {
            NSString *identifier = [essentialPackage objectForKey:@"id"];
            NSString *version = [essentialPackage objectForKey:@"version"];
            
            BOOL ignoreUpdates = [self areUpdatesIgnoredForPackageIdentifier:[essentialPackage objectForKey:@"id"]];
            if (!ignoreUpdates) numberOfUpdates++;
            NSString *query = [NSString stringWithFormat:@"REPLACE INTO UPDATES(PACKAGE, VERSION, IGNORE) VALUES(\'%@\', \'%@\', %d);", identifier, version, ignoreUpdates ? 1 : 0];
            
            if (sqlite3_prepare_v2(database, [query UTF8String], -1, &statement, nil) == SQLITE_OK) {
                while (sqlite3_step(statement) == SQLITE_ROW) {
                    break;
                }
            } else {
                [self printDatabaseError];
            }
            sqlite3_finalize(statement);
            
            [upgradePackageIDs addObject:identifier];
        }
        
        [self closeDatabase];
    } else {
        [self printDatabaseError];
    }
}

- (void)dropTables {
    if ([self openDatabase] == SQLITE_OK) {
        char *packDel = "DROP TABLE PACKAGES;";
        sqlite3_exec(database, packDel, NULL, 0, NULL);
        char *repoDel = "DROP TABLE REPOS;";
        sqlite3_exec(database, repoDel, NULL, 0, NULL);
        char *updatesDel = "DROP TABLE UPDATES;";
        sqlite3_exec(database, updatesDel, NULL, 0, NULL);
        
        [self closeDatabase];
    } else {
        [self printDatabaseError];
    }
}

- (void)updateLastUpdated {
    [[NSUserDefaults standardUserDefaults] setObject:[NSDate date] forKey:@"lastUpdatedDate"];
}

#pragma mark - Repo management

- (int)repoIDFromBaseFileName:(NSString *)bfn {
    if ([self openDatabase] == SQLITE_OK) {
        NSString *query = [NSString stringWithFormat:@"SELECT REPOID FROM REPOS WHERE BASEFILENAME = \'%@\'", bfn];
        
        sqlite3_stmt *statement;
        int repoID = -1;
        if (sqlite3_prepare_v2(database, [query UTF8String], -1, &statement, nil) == SQLITE_OK) {
            while (sqlite3_step(statement) == SQLITE_ROW) {
                repoID = sqlite3_column_int(statement, 0);
                break;
            }
        } else {
            [self printDatabaseError];
        }
        sqlite3_finalize(statement);
        
        [self closeDatabase];
        return repoID;
    }
    [self printDatabaseError];
    return -1;
}

- (int)repoIDFromBaseURL:(NSString *)baseURL {
    if ([self openDatabase] == SQLITE_OK) {
        NSString *query = [NSString stringWithFormat:@"SELECT REPOID FROM REPOS WHERE BASEURL = \'%@\'", baseURL];
        
        sqlite3_stmt *statement;
        int repoID = -1;
        if (sqlite3_prepare_v2(database, [query UTF8String], -1, &statement, nil) == SQLITE_OK) {
            while (sqlite3_step(statement) == SQLITE_ROW) {
                repoID = sqlite3_column_int(statement, 0);
                break;
            }
        } else {
            [self printDatabaseError];
        }
        sqlite3_finalize(statement);
        
        [self closeDatabase];
        return repoID;
    }
    [self printDatabaseError];
    return -1;
}

- (ZBRepo *)repoFromBaseURL:(NSString *)burl {
    NSRange dividerRange = [burl rangeOfString:@"://"];
    NSUInteger divide = NSMaxRange(dividerRange);
    NSString *baseURL = divide > [burl length] ? burl : [burl substringFromIndex:divide];
    
    if ([self openDatabase] == SQLITE_OK) {
        NSString *query = [NSString stringWithFormat:@"SELECT * FROM REPOS WHERE BASEURL = \'%@\'", baseURL];
        
        sqlite3_stmt *statement;
        ZBRepo *repo;
        if (sqlite3_prepare_v2(database, [query UTF8String], -1, &statement, nil) == SQLITE_OK) {
            while (sqlite3_step(statement) == SQLITE_ROW) {
                repo = [[ZBRepo alloc] initWithSQLiteStatement:statement];
                break;
            }
        } else {
            [self printDatabaseError];
        }
        sqlite3_finalize(statement);
        [self closeDatabase];
        
        return repo;
    }
    [self printDatabaseError];
    return NULL;
}

- (int)nextRepoID {
    if ([self openDatabase] == SQLITE_OK) {
        sqlite3_stmt *statement;
        int repoID = 0;
        if (sqlite3_prepare_v2(database, "SELECT REPOID FROM REPOS ORDER BY REPOID DESC LIMIT 1", -1, &statement, nil) == SQLITE_OK) {
            while (sqlite3_step(statement) == SQLITE_ROW) {
                repoID = sqlite3_column_int(statement, 0);
                break;
            }
        } else {
            [self printDatabaseError];
        }
        
        sqlite3_finalize(statement);
        
        [self closeDatabase];
        return repoID + 1;
    }
    [self printDatabaseError];
    return -1;
}

- (int)numberOfPackagesInRepo:(ZBRepo * _Nullable)repo section:(NSString * _Nullable)section {
    if ([self openDatabase] == SQLITE_OK) {
        int packages = 0;
        NSString *query;
        NSString *repoPart = repo ? [NSString stringWithFormat:@"REPOID = %d", [repo repoID]] : @"REPOID > 0";
        if (section != NULL) {
            query = [NSString stringWithFormat:@"SELECT COUNT(distinct package) FROM PACKAGES WHERE SECTION = \'%@\' AND %@", section, repoPart];
        } else {
            query = [NSString stringWithFormat:@"SELECT COUNT(distinct package) FROM PACKAGES WHERE %@", repoPart];
        }
        
        sqlite3_stmt *statement;
        if (sqlite3_prepare_v2(database, [query UTF8String], -1, &statement, nil) == SQLITE_OK) {
            while (sqlite3_step(statement) == SQLITE_ROW) {
                packages = sqlite3_column_int(statement, 0);
            }
        } else {
            [self printDatabaseError];
        }
        sqlite3_finalize(statement);
        
        [self closeDatabase];
        return packages;
    }
    [self printDatabaseError];
    return -1;
}

- (NSArray <ZBRepo *> *)repos {
    if ([self openDatabase] == SQLITE_OK) {
        NSMutableArray *sources = [NSMutableArray new];
        
        NSString *query = @"SELECT * FROM REPOS";
        sqlite3_stmt *statement;
        if (sqlite3_prepare_v2(database, [query UTF8String], -1, &statement, nil) == SQLITE_OK) {
            while (sqlite3_step(statement) == SQLITE_ROW) {
                ZBRepo *source = [[ZBRepo alloc] initWithSQLiteStatement:statement];
                [sources addObject:source];
            }
        } else {
            [self printDatabaseError];
        }
        sqlite3_finalize(statement);
        [self closeDatabase];
        
        return sources;
    }
    [self printDatabaseError];
    return NULL;
}

- (void)deleteRepo:(ZBRepo *)repo {
    if ([self openDatabase] == SQLITE_OK) {
        NSString *packageQuery = [NSString stringWithFormat:@"DELETE FROM PACKAGES WHERE REPOID = %d", [repo repoID]];
        NSString *repoQuery = [NSString stringWithFormat:@"DELETE FROM REPOS WHERE REPOID = %d", [repo repoID]];
        
        sqlite3_exec(database, "BEGIN TRANSACTION", NULL, NULL, NULL);
        sqlite3_exec(database, [packageQuery UTF8String], NULL, NULL, NULL);
        sqlite3_exec(database, [repoQuery UTF8String], NULL, NULL, NULL);
        sqlite3_exec(database, "COMMIT TRANSACTION", NULL, NULL, NULL);
        
        [self closeDatabase];
    } else {
        [self printDatabaseError];
    }
}

- (UIImage *)iconForRepo:(ZBRepo *)repo {
    if ([self openDatabase] == SQLITE_OK) {
        UIImage* icon = NULL;
        NSString* sqliteQuery = [NSString stringWithFormat:@"SELECT ICON FROM REPOS WHERE REPOID = %d;", [repo repoID]];
        sqlite3_stmt* statement;
        
        if (sqlite3_prepare_v2(database, [sqliteQuery UTF8String], -1, &statement, NULL) == SQLITE_OK) {
            if (sqlite3_step(statement) == SQLITE_ROW) {
                int length = sqlite3_column_bytes(statement, 0);
                NSData *data = [NSData dataWithBytes:sqlite3_column_blob(statement, 0) length:length];
                icon = [UIImage imageWithData:data];
            }
        }
        
        sqlite3_finalize(statement);
        [self closeDatabase];
        
        return icon;
    }
    [self printDatabaseError];
    return NULL;
}

- (void)cancelUpdates:(id <ZBDatabaseDelegate>)delegate {
    [self setDatabaseBeingUpdated:NO];
    [self setHaltDatabaseOperations:true];
    [self.downloadManager stopAllDownloads];
    [self bulkDatabaseCompletedUpdate:-1];
    [self removeDatabaseDelegate:delegate];
}

- (void)saveIcon:(UIImage *)icon forRepo:(ZBRepo *)repo {
    if ([self openDatabase] == SQLITE_OK) {
        const char* sqliteQuery = "UPDATE REPOS SET (ICON) = (?) WHERE REPOID = ?";
        sqlite3_stmt* statement;
        
        NSData *imgData = UIImagePNGRepresentation(icon);
        if (sqlite3_prepare_v2(database, sqliteQuery, -1, &statement, NULL) == SQLITE_OK) {
            sqlite3_bind_blob(statement, 1, [imgData bytes], (int)[imgData length], SQLITE_TRANSIENT);
            sqlite3_bind_int(statement, 2, [repo repoID]);
            sqlite3_step(statement);
        } else {
            NSLog(@"[Zebra] Failed to save icon in database: %s", sqlite3_errmsg(database));
        }
        
        sqlite3_finalize(statement);
        [self closeDatabase];
    }
    [self printDatabaseError];
}

- (NSDictionary *)sectionReadoutForRepo:(ZBRepo *)repo {
    if ([self openDatabase] == SQLITE_OK) {
        NSMutableDictionary *sectionReadout = [NSMutableDictionary new];
        
        NSString *query = [NSString stringWithFormat:@"SELECT SECTION, COUNT(distinct package) as SECTION_COUNT from packages WHERE repoID = %d GROUP BY SECTION ORDER BY SECTION", [repo repoID]];
        
        sqlite3_stmt *statement;
        if (sqlite3_prepare_v2(database, [query UTF8String], -1, &statement, nil) == SQLITE_OK) {
            while (sqlite3_step(statement) == SQLITE_ROW) {
                const char *sectionChars = (const char *)sqlite3_column_text(statement, 0);
                if (sectionChars != 0) {
                    NSString *section = [[NSString stringWithUTF8String:sectionChars] stringByReplacingOccurrencesOfString:@"_" withString:@" "];
                    [sectionReadout setObject:[NSNumber numberWithInt:sqlite3_column_int(statement, 1)] forKey:section];
                }
            }
        } else {
            [self printDatabaseError];
        }
        sqlite3_finalize(statement);
        
        [self closeDatabase];
        return sectionReadout;
    }
    [self printDatabaseError];
    return NULL;
}

#pragma mark - Package management

- (NSArray <ZBPackage *> *)packagesFromRepo:(ZBRepo * _Nullable)repo inSection:(NSString * _Nullable)section numberOfPackages:(int)limit startingAt:(int)start {
    if ([self openDatabase] == SQLITE_OK) {
        NSMutableArray *packages = [NSMutableArray new];
        NSString *query;
        
        if (section == NULL) {
            NSString *repoPart = repo ? [NSString stringWithFormat:@"WHERE REPOID = %d", [repo repoID]] : @"WHERE REPOID > 0";
            query = [NSString stringWithFormat:@"SELECT * FROM PACKAGES %@ ORDER BY LASTSEEN DESC LIMIT %d OFFSET %d", repoPart, limit, start];
        } else {
            NSString *repoPart = repo ? [NSString stringWithFormat:@"AND REPOID = %d", [repo repoID]] : @"AND REPOID > 0";
            query = [NSString stringWithFormat:@"SELECT * FROM PACKAGES WHERE SECTION = '\%@\' %@ LIMIT %d OFFSET %d", section, repoPart, limit, start];
        }
        
        sqlite3_stmt *statement;
        if (sqlite3_prepare_v2(database, [query UTF8String], -1, &statement, nil) == SQLITE_OK) {
            while (sqlite3_step(statement) == SQLITE_ROW) {
                ZBPackage *package = [[ZBPackage alloc] initWithSQLiteStatement:statement];
                
                [packages addObject:package];
            }
        } else {
            [self printDatabaseError];
        }
        sqlite3_finalize(statement);
        [self closeDatabase];
        
        return [self cleanUpDuplicatePackages:packages];
    }
    [self printDatabaseError];
    return NULL;
}

- (NSMutableArray <ZBPackage *> *)installedPackages:(BOOL)includeVirtualDependencies {
    if ([self openDatabase] == SQLITE_OK) {
        installedPackageIDs = [NSMutableArray new];
        NSMutableArray *installedPackages = [NSMutableArray new];
        
        NSString *query;
        if (includeVirtualDependencies) {
            query = @"SELECT * FROM PACKAGES WHERE REPOID < 1;";
        }
        else {
            query = @"SELECT * FROM PACKAGES WHERE REPOID = 0;";
        }
        
        sqlite3_stmt *statement;
        if (sqlite3_prepare_v2(database, [query UTF8String], -1, &statement, nil) == SQLITE_OK) {
            while (sqlite3_step(statement) == SQLITE_ROW) {
                const char *packageIDChars =        (const char *)sqlite3_column_text(statement, ZBPackageColumnPackage);
                const char *versionChars =          (const char *)sqlite3_column_text(statement, ZBPackageColumnVersion);
                NSString *packageID = [NSString stringWithUTF8String:packageIDChars];
                NSString *packageVersion = [NSString stringWithUTF8String:versionChars];
                ZBPackage *package = [self packageForID:packageID equalVersion:packageVersion];
                if (package) {
                    package.version = packageVersion;
                    [installedPackageIDs addObject:package.identifier];
                    [installedPackages addObject:package];
                }
            }
        } else {
            [self printDatabaseError];
        }
        sqlite3_finalize(statement);
        [self closeDatabase];
        
        return installedPackages;
    }
    [self printDatabaseError];
    return NULL;
}

- (NSDictionary <NSString *, NSArray <NSDictionary *> *> *)installedPackagesList {
    NSMutableArray *installedPackages = [NSMutableArray new];
    NSMutableArray *virtualPackages = [NSMutableArray new];
    
    for (ZBPackage *package in [self installedPackages:true]) {
        NSDictionary *installedPackage = @{@"identifier": [package identifier], @"version": [package version]};
        [installedPackages addObject:installedPackage];
        
        for (NSString *virtualPackageLine in [package provides]) {
            NSArray *comps = [ZBDependencyResolver separateVersionComparison:virtualPackageLine];
            NSDictionary *virtualPackage = @{@"identifier": comps[0], @"version": comps[2]};
            
            [virtualPackages addObject:virtualPackage];
        }
    }
    
    return @{@"installed": installedPackages, @"virtual": virtualPackages};
}

- (NSMutableArray <ZBPackage *> *)packagesWithIgnoredUpdates {
    if ([self openDatabase] == SQLITE_OK) {
        NSMutableArray *packagesWithIgnoredUpdates = [NSMutableArray new];
        NSString *query = @"SELECT * FROM UPDATES WHERE IGNORE = 1;";
        NSMutableArray *irrelevantPackages = [NSMutableArray new];
        
        sqlite3_stmt *statement;
        if (sqlite3_prepare_v2(database, [query UTF8String], -1, &statement, nil) == SQLITE_OK) {
            while (sqlite3_step(statement) == SQLITE_ROW) {
                const char *identifierChars = (const char *)sqlite3_column_text(statement, ZBUpdateColumnID);
                const char *versionChars = (const char *)sqlite3_column_text(statement, ZBUpdateColumnVersion);
                NSString *identifier = [NSString stringWithUTF8String:identifierChars];
                ZBPackage *package = nil;
                if (versionChars != 0) {
                    NSString *version = [NSString stringWithUTF8String:versionChars];
                    
                    package = [self packageForID:identifier equalVersion:version];
                    if (package != NULL) {
                        [packagesWithIgnoredUpdates addObject:package];
                    }
                }
                if (![self packageIDIsInstalled:identifier version:nil]) {
                    // We don't need ignored updates from packages we don't have them installed
                    [irrelevantPackages addObject:identifier];
                    if (package) {
                        [packagesWithIgnoredUpdates removeObject:package];
                    }
                }
            }
        } else {
            [self printDatabaseError];
        }
        sqlite3_finalize(statement);
        
        if (irrelevantPackages.count) {
            sqlite3_exec(database, [[NSString stringWithFormat:@"DELETE FROM UPDATES WHERE PACKAGE IN (%@)", [irrelevantPackages componentsJoinedByString:@", "]] UTF8String], NULL, 0, NULL);
        }
        
        [self closeDatabase];
        
        return packagesWithIgnoredUpdates;
    }
    [self printDatabaseError];
    return NULL;
}

- (NSMutableArray <ZBPackage *> *)packagesWithUpdates {
    if ([self openDatabase] == SQLITE_OK) {
        NSMutableArray *packagesWithUpdates = [NSMutableArray new];
        NSString *query = @"SELECT * FROM UPDATES WHERE IGNORE = 0;";
        
        sqlite3_stmt *statement;
        if (sqlite3_prepare_v2(database, [query UTF8String], -1, &statement, nil) == SQLITE_OK) {
            while (sqlite3_step(statement) == SQLITE_ROW) {
                const char *identifierChars = (const char *)sqlite3_column_text(statement, ZBUpdateColumnID);
                const char *versionChars = (const char *)sqlite3_column_text(statement, ZBUpdateColumnVersion);
                NSString *identifier = [NSString stringWithUTF8String:identifierChars];
                if (versionChars != 0) {
                    NSString *version = [NSString stringWithUTF8String:versionChars];
                    
                    ZBPackage *package = [self packageForID:identifier equalVersion:version];
                    if (package != NULL && [upgradePackageIDs containsObject:package.identifier]) {
                        [packagesWithUpdates addObject:package];
                    }
                } else if ([upgradePackageIDs containsObject:identifier]) {
                    [upgradePackageIDs removeObject:identifier];
                }
            }
        } else {
            [self printDatabaseError];
        }
        sqlite3_finalize(statement);
        
        [self closeDatabase];
        return packagesWithUpdates;
    }
    [self printDatabaseError];
    return NULL;
}

- (NSArray <ZBPackage *> *)searchForPackageName:(NSString *)name numberOfResults:(int)results {
    if ([self openDatabase] == SQLITE_OK) {
        NSMutableArray *searchResults = [NSMutableArray new];
        NSString *query;
        
        if (results && results != -1) {
            query = [NSString stringWithFormat:@"SELECT * FROM PACKAGES WHERE NAME LIKE \'%%%@\%%\' AND REPOID > -1 ORDER BY (CASE WHEN NAME = \'%@\' THEN 1 WHEN NAME LIKE \'%@%%\' THEN 2 ELSE 3 END) COLLATE NOCASE LIMIT %d", name, name, name, results];
        } else {
            query = [NSString stringWithFormat:@"SELECT * FROM PACKAGES WHERE (NAME LIKE \'%%%@\%%\') OR (SHORTDESCRIPTION LIKE \'%%%@\%%\') AND REPOID > -1 ORDER BY (CASE WHEN NAME = \'%@\' THEN 1 WHEN NAME LIKE \'%@%%\' THEN 2 ELSE 3 END) COLLATE NOCASE", name, name, name, name];
        }
        
        sqlite3_stmt *statement;
        if (sqlite3_prepare_v2(database, [query UTF8String], -1, &statement, nil) == SQLITE_OK) {
            while (sqlite3_step(statement) == SQLITE_ROW) {
                ZBPackage *package = [[ZBPackage alloc] initWithSQLiteStatement:statement];
                
                [searchResults addObject:package];
            }
        } else {
            [self printDatabaseError];
        }
        sqlite3_finalize(statement);
        [self closeDatabase];
        
        return [self cleanUpDuplicatePackages:searchResults];
    }
    [self printDatabaseError];
    return NULL;
}

- (NSArray <ZBPackage *> *)purchasedPackages:(NSArray <NSString *> *)requestedPackages {
    if ([self openDatabase] == SQLITE_OK) {
        NSMutableArray *packages = [NSMutableArray new];
        NSString *query = [NSString stringWithFormat:@"SELECT * FROM PACKAGES WHERE PACKAGE IN ('\%@') ORDER BY NAME COLLATE NOCASE ASC", [requestedPackages componentsJoinedByString:@"','"]];
        sqlite3_stmt *statement;
        if (sqlite3_prepare_v2(database, [query UTF8String], -1, &statement, nil) == SQLITE_OK) {
            while (sqlite3_step(statement) == SQLITE_ROW) {
                ZBPackage *package = [[ZBPackage alloc] initWithSQLiteStatement:statement];
                
                [packages addObject:package];
            }
        } else {
            [self printDatabaseError];
        }
        sqlite3_finalize(statement);
        [self closeDatabase];
        
        return [self cleanUpDuplicatePackages:packages];
    }
    [self printDatabaseError];
    return NULL;
}

#pragma mark - Package status

- (BOOL)packageIDHasUpdate:(NSString *)packageIdentifier {
    if ([upgradePackageIDs count] != 0) {
        return [upgradePackageIDs containsObject:packageIdentifier];
    } else {
        if ([self openDatabase] == SQLITE_OK) {
            NSString *query = [NSString stringWithFormat:@"SELECT PACKAGE FROM UPDATES WHERE PACKAGE = \'%@\' AND IGNORE = 0 LIMIT 1;", packageIdentifier];
            
            BOOL packageIsInstalled = NO;
            sqlite3_stmt *statement;
            if (sqlite3_prepare_v2(database, [query UTF8String], -1, &statement, nil) == SQLITE_OK) {
                while (sqlite3_step(statement) == SQLITE_ROW) {
                    packageIsInstalled = YES;
                    break;
                }
            } else {
                [self printDatabaseError];
            }
            sqlite3_finalize(statement);
            [self closeDatabase];
            
            return packageIsInstalled;
        }
        [self printDatabaseError];
        return NO;
    }
}

- (BOOL)packageHasUpdate:(ZBPackage *)package {
    return [self packageIDHasUpdate:package.identifier];
}

- (BOOL)packageIDIsInstalled:(NSString *)packageIdentifier version:(NSString *_Nullable)version {
    if (version == NULL && [installedPackageIDs count] != 0) {
        BOOL packageIsInstalled = [[installedPackageIDs copy] containsObject:packageIdentifier];
        ZBLog(@"[Zebra] [installedPackageIDs] Is %@ (version: %@) installed? : %d", packageIdentifier, version, packageIsInstalled);
        if (packageIsInstalled) {
            return packageIsInstalled;
        }
    }
    if ([self openDatabase] == SQLITE_OK) {
        NSString *query;
        
        if (version != NULL) {
            query = [NSString stringWithFormat:@"SELECT PACKAGE FROM PACKAGES WHERE PACKAGE = \'%@\' AND VERSION = \'%@\' AND REPOID < 1 LIMIT 1;", packageIdentifier, version];
        } else {
            query = [NSString stringWithFormat:@"SELECT PACKAGE FROM PACKAGES WHERE PACKAGE = \'%@\' AND REPOID < 1 LIMIT 1;", packageIdentifier];
        }
        
        BOOL packageIsInstalled = NO;
        sqlite3_stmt *statement;
        if (sqlite3_prepare_v2(database, [query UTF8String], -1, &statement, nil) == SQLITE_OK) {
            while (sqlite3_step(statement) == SQLITE_ROW) {
                packageIsInstalled = YES;
                break;
            }
        } else {
            [self printDatabaseError];
        }
        sqlite3_finalize(statement);
        [self closeDatabase];
        
        ZBLog(@"[Zebra] Is %@ (version: %@) installed? : %d", packageIdentifier, version, packageIsInstalled);
        return packageIsInstalled;
    }
    [self printDatabaseError];
    return NO;
}

- (BOOL)packageIsInstalled:(ZBPackage *)package versionStrict:(BOOL)strict {
    return [self packageIDIsInstalled:package.identifier version:strict ? package.version : NULL];
}

- (BOOL)packageIDIsAvailable:(NSString *)packageIdentifier version:(NSString *_Nullable)version {
    if ([self openDatabase] == SQLITE_OK) {
        NSString *query = [NSString stringWithFormat:@"SELECT PACKAGE FROM PACKAGES WHERE PACKAGE = \'%@\' AND REPOID > 0 LIMIT 1;", packageIdentifier];
        
        BOOL packageIsAvailable = NO;
        sqlite3_stmt *statement;
        if (sqlite3_prepare_v2(database, [query UTF8String], -1, &statement, nil) == SQLITE_OK) {
            while (sqlite3_step(statement) == SQLITE_ROW) {
                packageIsAvailable = YES;
                break;
            }
        } else {
            [self printDatabaseError];
        }
        sqlite3_finalize(statement);
        
        [self closeDatabase];
        return packageIsAvailable;
    }
    [self printDatabaseError];
    return NO;
}

- (BOOL)packageIsAvailable:(ZBPackage *)package versionStrict:(BOOL)strict {
    return [self packageIDIsAvailable:package.identifier version:strict ? package.version : NULL];
}

- (ZBPackage *)packageForID:(NSString *)identifier equalVersion:(NSString *)version {
    if ([self openDatabase] == SQLITE_OK) {
        NSString *query = [NSString stringWithFormat:@"SELECT * FROM PACKAGES WHERE PACKAGE = '\%@\' AND VERSION = \'%@\' LIMIT 1;", identifier, version];
        
        ZBPackage *package;
        sqlite3_stmt *statement;
        if (sqlite3_prepare_v2(database, [query UTF8String], -1, &statement, nil) == SQLITE_OK) {
            while (sqlite3_step(statement) == SQLITE_ROW) {
                package = [[ZBPackage alloc] initWithSQLiteStatement:statement];
                break;
            }
        } else {
            [self printDatabaseError];
        }
        sqlite3_finalize(statement);
        
        [self closeDatabase];
        return package;
    }
    [self printDatabaseError];
    return NULL;
}

- (BOOL)areUpdatesIgnoredForPackage:(ZBPackage *)package {
    return [self areUpdatesIgnoredForPackageIdentifier:[package identifier]];
}

- (BOOL)areUpdatesIgnoredForPackageIdentifier:(NSString *)identifier {
    if ([self openDatabase] == SQLITE_OK) {
        NSString *query = [NSString stringWithFormat:@"SELECT IGNORE FROM UPDATES WHERE PACKAGE = '\%@\' LIMIT 1;", identifier];
        
        BOOL ignored = NO;
        sqlite3_stmt *statement;
        if (sqlite3_prepare_v2(database, [query UTF8String], -1, &statement, nil) == SQLITE_OK) {
            while (sqlite3_step(statement) == SQLITE_ROW) {
                if (sqlite3_column_int(statement, 0) == 1)
                    ignored = YES;
                break;
            }
        } else {
            [self printDatabaseError];
        }
        sqlite3_finalize(statement);
        
        [self closeDatabase];
        return ignored;
    }
    [self printDatabaseError];
    return NO;
}

- (void)setUpdatesIgnored:(BOOL)ignore forPackage:(ZBPackage *)package {
    if ([self openDatabase] == SQLITE_OK) {
        NSString *query = [NSString stringWithFormat:@"REPLACE INTO UPDATES(PACKAGE, VERSION, IGNORE) VALUES(\'%@\', \'%@\', %d);", package.identifier, package.version, ignore ? 1 : 0];
        
        sqlite3_stmt *statement;
        if (sqlite3_prepare_v2(database, [query UTF8String], -1, &statement, nil) == SQLITE_OK) {
            while (sqlite3_step(statement) == SQLITE_ROW) {
                break;
            }
        } else {
            NSLog(@"[Zebra] Error preparing setting package ignore updates statement: %s", sqlite3_errmsg(database));
        }
        sqlite3_finalize(statement);
        
        [self closeDatabase];
    } else {
        [self printDatabaseError];
    }
}

#pragma mark - Package lookup

- (ZBPackage *)packageThatProvides:(NSString *)identifier thatSatisfiesComparison:(NSString *)comparison ofVersion:(NSString *)version {
    return [self packageThatProvides:identifier thatSatisfiesComparison:comparison ofVersion:version thatIsNot:NULL];
}

- (ZBPackage *)packageThatProvides:(NSString *)packageIdentifier thatSatisfiesComparison:(NSString *)comparison ofVersion:(NSString *)version thatIsNot:(ZBPackage *_Nullable)exclude {
    if ([self openDatabase] == SQLITE_OK) {
        const char *query;
        const char *firstSearchTerm = [[NSString stringWithFormat:@"%%, %@ (%%", packageIdentifier] UTF8String];
        const char *secondSearchTerm = [[NSString stringWithFormat:@"%%, %@, %%", packageIdentifier] UTF8String];
        const char *thirdSearchTerm = [[NSString stringWithFormat:@"%@ (%%", packageIdentifier] UTF8String];
        const char *fourthSearchTerm = [[NSString stringWithFormat:@"%@, %%", packageIdentifier] UTF8String];
        const char *fifthSearchTerm = [[NSString stringWithFormat:@"%%, %@", packageIdentifier] UTF8String];
        const char *sixthSearchTerm = [[NSString stringWithFormat:@"%%| %@", packageIdentifier] UTF8String];
        const char *seventhSearchTerm = [[NSString stringWithFormat:@"%%, %@ |%%", packageIdentifier] UTF8String];
        const char *eighthSearchTerm = [[NSString stringWithFormat:@"%@ |%%", packageIdentifier] UTF8String];
        
        if (exclude) {
            query = "SELECT * FROM PACKAGES WHERE PACKAGE != ? AND REPOID > 0 AND (PROVIDES LIKE ? OR PROVIDES LIKE ? OR PROVIDES LIKE ? OR PROVIDES LIKE ? OR PROVIDES LIKE ? OR PROVIDES LIKE ? OR PROVIDES LIKE ? OR PROVIDES LIKE ?) AND REPOID > 0 LIMIT 1;";
        }
        else {
            query = "SELECT * FROM PACKAGES WHERE REPOID > 0 AND (PROVIDES LIKE ? OR PROVIDES LIKE ? OR PROVIDES LIKE ? OR PROVIDES LIKE ? OR PROVIDES LIKE ? OR PROVIDES LIKE ? OR PROVIDES LIKE ? OR PROVIDES LIKE ?) LIMIT 1;";
        }
        
        NSMutableArray <ZBPackage *> *packages = [NSMutableArray new];
        sqlite3_stmt *statement;
        if (sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK) {
            if (exclude) {
                sqlite3_bind_text(statement, 1, [packageIdentifier UTF8String], -1, SQLITE_TRANSIENT);
            }
            sqlite3_bind_text(statement, exclude ? 2 : 1, firstSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, exclude ? 3 : 2, secondSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, exclude ? 4 : 3, thirdSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, exclude ? 5 : 4, fourthSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, exclude ? 6 : 5, fifthSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, exclude ? 7 : 6, sixthSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, exclude ? 8 : 7, seventhSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, exclude ? 9 : 8, eighthSearchTerm, -1, SQLITE_TRANSIENT);
            
            while (sqlite3_step(statement) == SQLITE_ROW) {
                const char *providesLine = (const char *)sqlite3_column_text(statement, ZBPackageColumnProvides);
                if (providesLine != 0) {
                    NSString *provides = [[NSString stringWithUTF8String:providesLine] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    NSArray *virtualPackages = [provides componentsSeparatedByString:@","];
                    
                    for (NSString *virtualPackage in virtualPackages) {
                        NSArray *versionComponents = [ZBDependencyResolver separateVersionComparison:virtualPackage];
                        if ([versionComponents[0] isEqualToString:packageIdentifier] &&
                            (![versionComponents[2] isEqualToString:@"0:0"] || [ZBDependencyResolver doesVersion:versionComponents[2] satisfyComparison:comparison ofVersion:version])) {
                            ZBPackage *package = [[ZBPackage alloc] initWithSQLiteStatement:statement];
                            [packages addObject:package];
                            break;
                        }
                    }
                }
            }
        } else {
            [self printDatabaseError];
            return NULL;
        }
        sqlite3_finalize(statement);
        
        [self closeDatabase];
        return packages[0] ? packages[0] : NULL; //Returns the first package in the array, we could use interactive dependency resolution in the future
    }
    [self printDatabaseError];
    return NULL;
}

- (ZBPackage *_Nullable)installedPackageThatProvides:(NSString *)identifier thatSatisfiesComparison:(NSString *)comparison ofVersion:(NSString *)version {
    return [self installedPackageThatProvides:identifier thatSatisfiesComparison:comparison ofVersion:version thatIsNot:NULL];
}

- (ZBPackage *_Nullable)installedPackageThatProvides:(NSString *)packageIdentifier thatSatisfiesComparison:(NSString *)comparison ofVersion:(NSString *)version thatIsNot:(ZBPackage *_Nullable)exclude {
    if ([self openDatabase] == SQLITE_OK) {
        const char *query;
        const char *firstSearchTerm = [[NSString stringWithFormat:@"%%, %@ (%%", packageIdentifier] UTF8String];
        const char *secondSearchTerm = [[NSString stringWithFormat:@"%%, %@, %%", packageIdentifier] UTF8String];
        const char *thirdSearchTerm = [[NSString stringWithFormat:@"%@ (%%", packageIdentifier] UTF8String];
        const char *fourthSearchTerm = [[NSString stringWithFormat:@"%@, %%", packageIdentifier] UTF8String];
        const char *fifthSearchTerm = [[NSString stringWithFormat:@"%%, %@", packageIdentifier] UTF8String];
        const char *sixthSearchTerm = [[NSString stringWithFormat:@"%%| %@", packageIdentifier] UTF8String];
        const char *seventhSearchTerm = [[NSString stringWithFormat:@"%%, %@ |%%", packageIdentifier] UTF8String];
        const char *eighthSearchTerm = [[NSString stringWithFormat:@"%@ |%%", packageIdentifier] UTF8String];
        
        if (exclude) {
            query = "SELECT * FROM PACKAGES WHERE PACKAGE != ? AND REPOID = 0 AND (PROVIDES LIKE ? OR PROVIDES LIKE ? OR PROVIDES LIKE ? OR PROVIDES LIKE ? OR PROVIDES LIKE ? OR PROVIDES LIKE ? OR PROVIDES LIKE ? OR PROVIDES LIKE ?) AND REPOID > 0 LIMIT 1;";
        }
        else {
            query = "SELECT * FROM PACKAGES WHERE REPOID = 0 AND (PROVIDES LIKE ? OR PROVIDES LIKE ? OR PROVIDES LIKE ? OR PROVIDES LIKE ? OR PROVIDES LIKE ? OR PROVIDES LIKE ? OR PROVIDES LIKE ? OR PROVIDES LIKE ?) LIMIT 1;";
        }
        
        NSMutableArray <ZBPackage *> *packages = [NSMutableArray new];
        sqlite3_stmt *statement;
        if (sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK) {
            if (exclude) {
                sqlite3_bind_text(statement, 1, [packageIdentifier UTF8String], -1, SQLITE_TRANSIENT);
            }
            sqlite3_bind_text(statement, exclude ? 2 : 1, firstSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, exclude ? 3 : 2, secondSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, exclude ? 4 : 3, thirdSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, exclude ? 5 : 4, fourthSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, exclude ? 6 : 5, fifthSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, exclude ? 7 : 6, sixthSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, exclude ? 8 : 7, seventhSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, exclude ? 9 : 8, eighthSearchTerm, -1, SQLITE_TRANSIENT);
            
            while (sqlite3_step(statement) == SQLITE_ROW) {
                ZBPackage *package = [[ZBPackage alloc] initWithSQLiteStatement:statement];
                [packages addObject:package];
            }
        } else {
            [self printDatabaseError];
            return NULL;
        }
        sqlite3_finalize(statement);
        
        for (ZBPackage *package in packages) {
            //If there is a comparison and a version then we return the first package that satisfies this comparison, otherwise we return the first package we see
            //(this also sets us up better later for interactive dependency resolution)
            if (comparison && version && [ZBDependencyResolver doesPackage:package satisfyComparison:comparison ofVersion:version]) {
                [self closeDatabase];
                return package;
            }
            else if (!comparison || !version) {
                [self closeDatabase];
                return package;
            }
        }
        
        [self closeDatabase];
        return NULL;
    }
    [self printDatabaseError];
    return NULL;
}

- (ZBPackage *)packageForIdentifier:(NSString *)identifier thatSatisfiesComparison:(NSString * _Nullable)comparison ofVersion:(NSString * _Nullable)version {
    return [self packageForIdentifier:identifier thatSatisfiesComparison:comparison ofVersion:version includeVirtualPackages:true];
}

- (ZBPackage *)packageForIdentifier:(NSString *)identifier thatSatisfiesComparison:(NSString * _Nullable)comparison ofVersion:(NSString * _Nullable)version includeVirtualPackages:(BOOL)checkVirtual {
    if ([self openDatabase] == SQLITE_OK) {
        NSString *query = [NSString stringWithFormat:@"SELECT * FROM PACKAGES WHERE PACKAGE = '\%@\' COLLATE NOCASE AND REPOID > 0 LIMIT 1;", identifier];
        
        ZBPackage *package;
        sqlite3_stmt *statement;
        if (sqlite3_prepare_v2(database, [query UTF8String], -1, &statement, nil) == SQLITE_OK) {
            while (sqlite3_step(statement) == SQLITE_ROW) {
                package = [[ZBPackage alloc] initWithSQLiteStatement:statement];
                break;
            }
        } else {
            [self printDatabaseError];
        }
        sqlite3_finalize(statement);
        
        // Only try to resolve "Provides" if we can't resolve the normal package.
        if (checkVirtual && package == NULL) {
            package = [self installedPackageThatProvides:identifier thatSatisfiesComparison:comparison ofVersion:version]; //there is a scenario here where two packages that provide a package could be found (ex: anemone, snowboard, and ithemer all provide winterboard) we need to ask the user which one to pick.
        }
        
        if (package != NULL) {
            NSArray *otherVersions = [self allVersionsForPackage:package];
            if (version != NULL && comparison != NULL) {
                if ([otherVersions count] > 1) {
                    for (ZBPackage *package in otherVersions) {
                        if ([ZBDependencyResolver doesPackage:package satisfyComparison:comparison ofVersion:version]) {
                            [self closeDatabase];
                            return package;
                        }
                    }
                    
                    [self closeDatabase];
                    return NULL;
                }
                [self closeDatabase];
                return [ZBDependencyResolver doesPackage:otherVersions[0] satisfyComparison:comparison ofVersion:version] ? otherVersions[0] : NULL;
            }
            else {
                return otherVersions[0];
            }
        }
        
        [self closeDatabase];
        return NULL;
    }
    [self printDatabaseError];
    return NULL;
}

- (ZBPackage *_Nullable)installedPackageForIdentifier:(NSString *)identifier thatSatisfiesComparison:(NSString * _Nullable)comparison ofVersion:(NSString * _Nullable)version {
    return [self installedPackageForIdentifier:identifier thatSatisfiesComparison:comparison ofVersion:version includeVirtualPackages:true thatIsNot:NULL];
}

- (ZBPackage *_Nullable)installedPackageForIdentifier:(NSString *)identifier thatSatisfiesComparison:(NSString * _Nullable)comparison ofVersion:(NSString * _Nullable)version includeVirtualPackages:(BOOL)checkVirtual {
    return [self installedPackageForIdentifier:identifier thatSatisfiesComparison:comparison ofVersion:version includeVirtualPackages:checkVirtual thatIsNot:NULL];
}

- (ZBPackage *_Nullable)installedPackageForIdentifier:(NSString *)identifier thatSatisfiesComparison:(NSString * _Nullable)comparison ofVersion:(NSString * _Nullable)version includeVirtualPackages:(BOOL)checkVirtual thatIsNot:(ZBPackage *_Nullable)exclude {
    if ([self openDatabase] == SQLITE_OK) {
        NSString *query;
        if (exclude) {
            query = [NSString stringWithFormat:@"SELECT * FROM PACKAGES WHERE PACKAGE = '\%@\' AND REPOID = 0 AND PACKAGE != '\%@\' LIMIT 1;", identifier, [exclude identifier]];
        }
        else {
            query = [NSString stringWithFormat:@"SELECT * FROM PACKAGES WHERE PACKAGE = '\%@\' AND REPOID = 0 LIMIT 1;", identifier];
        }
        
        ZBPackage *package;
        sqlite3_stmt *statement;
        if (sqlite3_prepare_v2(database, [query UTF8String], -1, &statement, nil) == SQLITE_OK) {
            while (sqlite3_step(statement) == SQLITE_ROW) {
                package = [[ZBPackage alloc] initWithSQLiteStatement:statement];
                break;
            }
        } else {
            [self printDatabaseError];
        }
        sqlite3_finalize(statement);
        
        // Only try to resolve "Provides" if we can't resolve the normal package.
        if (checkVirtual && package == NULL) {
            package = [self installedPackageThatProvides:identifier thatSatisfiesComparison:comparison ofVersion:version thatIsNot:exclude]; //there is a scenario here where two packages that provide a package could be found (ex: anemone, snowboard, and ithemer all provide winterboard) we need to ask the user which one to pick.
        }
        
        if (package != NULL) {
            if (version != NULL && comparison != NULL) {
                [self closeDatabase];
                return [ZBDependencyResolver doesPackage:package satisfyComparison:comparison ofVersion:version] ? package : NULL;
            }
            else {
                [self closeDatabase];
                return package;
            }
        }
        
        [self closeDatabase];
        return NULL;
    }
    [self printDatabaseError];
    return NULL;
}

- (NSArray *)allVersionsForPackage:(ZBPackage *)package {
    return [self allVersionsForPackageID:package.identifier inRepo:NULL];
}

- (NSArray *)allVersionsForPackageID:(NSString *)packageIdentifier {
    return [self allVersionsForPackageID:packageIdentifier inRepo:NULL];
}

- (NSArray *)allVersionsForPackage:(ZBPackage *)package inRepo:(ZBRepo *_Nullable)repo {
    return [self allVersionsForPackageID:package.identifier inRepo:repo];
}

- (NSArray *)allVersionsForPackageID:(NSString *)packageIdentifier inRepo:(ZBRepo *_Nullable)repo {
    if ([self openDatabase] == SQLITE_OK) {
        NSMutableArray *allVersions = [NSMutableArray new];
        
        NSString *query;
        sqlite3_stmt *statement;
        if (repo != NULL) {
            query = @"SELECT * FROM PACKAGES WHERE PACKAGE = ? AND REPOID = ?;";
        }
        else {
            query = @"SELECT * FROM PACKAGES WHERE PACKAGE = ?;";
        }
        
        if (sqlite3_prepare_v2(database, [query UTF8String], -1, &statement, nil) == SQLITE_OK) {
            sqlite3_bind_text(statement, 1, [packageIdentifier UTF8String], -1, SQLITE_TRANSIENT);
            if (repo != NULL) {
                sqlite3_bind_int(statement, 2, [repo repoID]);
            }
        }
        while (sqlite3_step(statement) == SQLITE_ROW) {
            ZBPackage *package = [[ZBPackage alloc] initWithSQLiteStatement:statement];
            
            [allVersions addObject:package];
        }
        sqlite3_finalize(statement);
        
        NSSortDescriptor *sort = [NSSortDescriptor sortDescriptorWithKey:@"self" ascending:NO];
        NSArray *sorted = [allVersions sortedArrayUsingDescriptors:@[sort]];
        [self closeDatabase];
        
        return sorted;
    }
    [self printDatabaseError];
    return NULL;
}

- (NSArray *)otherVersionsForPackage:(ZBPackage *)package {
    return [self otherVersionsForPackageID:package.identifier version:package.version];
}

- (NSArray *)otherVersionsForPackageID:(NSString *)packageIdentifier version:(NSString *)version {
    if ([self openDatabase] == SQLITE_OK) {
        NSMutableArray *otherVersions = [NSMutableArray new];
        
        sqlite3_stmt *statement;
        if (sqlite3_prepare_v2(database, "SELECT * FROM PACKAGES WHERE PACKAGE = ? AND VERSION != ?;", -1, &statement, nil) == SQLITE_OK) {
            sqlite3_bind_text(statement, 1, [packageIdentifier UTF8String], -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, 2, [version UTF8String], -1, SQLITE_TRANSIENT);
        }
        while (sqlite3_step(statement) == SQLITE_ROW) {
            int repoID = sqlite3_column_int(statement, ZBPackageColumnRepoID);
            if (repoID > 0) {
                ZBPackage *package = [[ZBPackage alloc] initWithSQLiteStatement:statement];
                
                [otherVersions addObject:package];
            }
        }
        sqlite3_finalize(statement);
        
        NSSortDescriptor *sort = [NSSortDescriptor sortDescriptorWithKey:@"self" ascending:NO];
        NSArray *sorted = [otherVersions sortedArrayUsingDescriptors:@[sort]];
        [self closeDatabase];
        
        return sorted;
    }
    [self printDatabaseError];
    return NULL;
}

- (NSArray *)packagesByAuthor:(NSString *)author {
    if ([self openDatabase] == SQLITE_OK) {
        NSMutableArray *packages = [NSMutableArray new];
        NSMutableArray *packageIdentifiers = [NSMutableArray new];
        
        sqlite3_stmt *statement;
        if (sqlite3_prepare_v2(database, "SELECT PACKAGE, REPOID FROM PACKAGES WHERE AUTHOR = ?;", -1, &statement, nil) == SQLITE_OK) {
            sqlite3_bind_text(statement, 1, [author UTF8String], -1, SQLITE_TRANSIENT);
        }
        while (sqlite3_step(statement) == SQLITE_ROW) {
            int repoID = sqlite3_column_int(statement, 1);
            
            if (repoID > 0) {
                const char *packageIDChars = (const char *)sqlite3_column_text(statement, 0);
                if (packageIDChars != 0) {
                    NSString *packageID = [NSString stringWithUTF8String:packageIDChars];
                    if (![packageIdentifiers containsObject:packageID]) {
                        [packageIdentifiers addObject:packageID];
                    }
                }
            }
        }
        sqlite3_finalize(statement);

        for (NSString *packageID in packageIdentifiers) {
            ZBPackage *package = [self topVersionForPackageID:packageID];
            if (package) {
                [packages addObject:[self topVersionForPackageID:packageID]];
            }
        }
        [self closeDatabase];
        
        return packages;
    }
    [self printDatabaseError];
    return NULL;
}

- (NSArray *)packagesWithReachableIcon:(int)limit excludeFrom:(NSArray <ZBRepo *> *_Nullable)blacklistedRepos {
    if ([self openDatabase] == SQLITE_OK) {
        NSMutableArray *packages = [NSMutableArray new];
        NSMutableArray *repoIDs = [@[[NSNumber numberWithInt:-1], [NSNumber numberWithInt:0]] mutableCopy];
        
        for (ZBRepo *repo in blacklistedRepos) {
            [repoIDs addObject:[NSNumber numberWithInt:[repo repoID]]];
        }
        NSString *excludeString = [NSString stringWithFormat:@"(%@)", [repoIDs componentsJoinedByString:@", "]];
        NSString *query = [NSString stringWithFormat:@"SELECT * FROM PACKAGES WHERE REPOID NOT IN %@ AND ICONURL IS NOT NULL ORDER BY RANDOM() LIMIT %d;", excludeString, limit];
        
        sqlite3_stmt *statement;
        if (sqlite3_prepare_v2(database, [query UTF8String], -1, &statement, nil) == SQLITE_OK) {
            while (sqlite3_step(statement) == SQLITE_ROW) {
                ZBPackage *package = [[ZBPackage alloc] initWithSQLiteStatement:statement];
                [packages addObject:package];
 
            }
        }
        return [self cleanUpDuplicatePackages:packages];
    }
    [self printDatabaseError];
    return NULL;
}


- (nullable ZBPackage *)topVersionForPackage:(ZBPackage *)package {
    return [self topVersionForPackage:package inRepo:NULL];
}

- (nullable ZBPackage *)topVersionForPackageID:(NSString *)packageIdentifier {
    return [self topVersionForPackageID:packageIdentifier inRepo:NULL];
}

- (nullable ZBPackage *)topVersionForPackage:(ZBPackage *)package inRepo:(ZBRepo *_Nullable)repo {
    return [self topVersionForPackageID:package.identifier inRepo:repo];
}

- (nullable ZBPackage *)topVersionForPackageID:(NSString *)packageIdentifier inRepo:(ZBRepo *_Nullable)repo {
    NSArray *allVersions = [self allVersionsForPackageID:packageIdentifier inRepo:repo];
    return allVersions.count ? allVersions[0] : nil;
}

- (NSArray <ZBPackage *> *)packagesThatDependOn:(ZBPackage *)package {
    return [self packagesThatDependOnPackageIdentifier:[package identifier] removedPackage:package];
}

- (NSArray <ZBPackage *> *)packagesThatDependOnPackageIdentifier:(NSString *)packageIdentifier removedPackage:(ZBPackage *)package {
    if ([self openDatabase] == SQLITE_OK) {
        NSMutableArray *packages = [NSMutableArray new];
        
        const char *firstSearchTerm = [[NSString stringWithFormat:@"%%, %@ (%%", packageIdentifier] UTF8String];
        const char *secondSearchTerm = [[NSString stringWithFormat:@"%%, %@, %%", packageIdentifier] UTF8String];
        const char *thirdSearchTerm = [[NSString stringWithFormat:@"%@ (%%", packageIdentifier] UTF8String];
        const char *fourthSearchTerm = [[NSString stringWithFormat:@"%@, %%", packageIdentifier] UTF8String];
        const char *fifthSearchTerm = [[NSString stringWithFormat:@"%%, %@", packageIdentifier] UTF8String];
        const char *sixthSearchTerm = [[NSString stringWithFormat:@"%%| %@", packageIdentifier] UTF8String];
        const char *seventhSearchTerm = [[NSString stringWithFormat:@"%%, %@ |%%", packageIdentifier] UTF8String];
        const char *eighthSearchTerm = [[NSString stringWithFormat:@"%@ |%%", packageIdentifier] UTF8String];
        
        const char *query = "SELECT * FROM PACKAGES WHERE (DEPENDS LIKE ? OR DEPENDS LIKE ? OR DEPENDS LIKE ? OR DEPENDS LIKE ? OR DEPENDS LIKE ? OR DEPENDS LIKE ? OR DEPENDS LIKE ? OR DEPENDS = ?) AND REPOID = 0;";
        sqlite3_stmt *statement;
        if (sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK) {
            sqlite3_bind_text(statement, 1, firstSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, 2, secondSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, 3, thirdSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, 4, fourthSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, 5, fifthSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, 6, sixthSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, 7, seventhSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, 8, eighthSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, 9, [packageIdentifier UTF8String], -1, SQLITE_TRANSIENT);
            
            while (sqlite3_step(statement) == SQLITE_ROW) {
                const char *dependsChars = (const char *)sqlite3_column_text(statement, ZBPackageColumnDepends);
                NSString *depends = dependsChars != 0 ? [NSString stringWithUTF8String:dependsChars] : NULL; //Depends shouldn't be NULL here but you know just in case because this can be weird
                NSArray *dependsOn = [depends componentsSeparatedByString:@", "];
                
                BOOL packageNeedsToBeRemoved = NO;
                for (NSString *dependsLine in dependsOn) {
                    NSError *error = NULL;
                    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:[NSString stringWithFormat:@"\\b%@\\b", [package identifier]] options:NSRegularExpressionCaseInsensitive error:&error];
                    if ([regex numberOfMatchesInString:dependsLine options:0 range:NSMakeRange(0, [dependsLine length])] && ![self willDependencyBeSatisfiedAfterQueueOperations:dependsLine]) { //Use regex to search with block words
                        packageNeedsToBeRemoved = YES;
                    }
                }

                if (packageNeedsToBeRemoved) {
                    ZBPackage *found = [[ZBPackage alloc] initWithSQLiteStatement:statement];
                    [found setRemovedBy:package];

                    [packages addObject:found];
                }
            }
        }
        sqlite3_finalize(statement);
        [self closeDatabase];
        
        for (NSString *provided in [package provides]) { //If the package is removed and there is no other package that provides this dependency, we have to remove those as well
            if ([provided containsString:packageIdentifier]) continue;
            if (![[package identifier] isEqualToString:packageIdentifier] && [[package provides] containsObject:provided]) continue;
            if (![self willDependencyBeSatisfiedAfterQueueOperations:provided]) {
                [packages addObjectsFromArray:[self packagesThatDependOnPackageIdentifier:provided removedPackage:package]];
            }
        }
        
        return [packages count] > 0 ? packages : NULL;
    }
    [self printDatabaseError];
    return NULL;
}

- (NSArray <ZBPackage *> *)packagesThatConflictWith:(ZBPackage *)package {
    if ([self openDatabase] == SQLITE_OK) {
        NSMutableArray *packages = [NSMutableArray new];
        
        const char *firstSearchTerm = [[NSString stringWithFormat:@"%%, %@ (%%", [package identifier]] UTF8String];
        const char *secondSearchTerm = [[NSString stringWithFormat:@"%%, %@, %%", [package identifier]] UTF8String];
        const char *thirdSearchTerm = [[NSString stringWithFormat:@"%@ (%%", [package identifier]] UTF8String];
        const char *fourthSearchTerm = [[NSString stringWithFormat:@"%@, %%", [package identifier]] UTF8String];
        const char *fifthSearchTerm = [[NSString stringWithFormat:@"%%, %@", [package identifier]] UTF8String];
        const char *sixthSearchTerm = [[NSString stringWithFormat:@"%%| %@", [package identifier]] UTF8String];
        const char *seventhSearchTerm = [[NSString stringWithFormat:@"%%, %@ |%%", [package identifier]] UTF8String];
        const char *eighthSearchTerm = [[NSString stringWithFormat:@"%@ |%%", [package identifier]] UTF8String];
        
        const char *query = "SELECT * FROM PACKAGES WHERE (CONFLICTS LIKE ? OR CONFLICTS LIKE ? OR CONFLICTS LIKE ? OR CONFLICTS LIKE ? OR CONFLICTS LIKE ? OR CONFLICTS LIKE ? OR CONFLICTS LIKE ? OR CONFLICTS LIKE ? OR CONFLICTS = ?) AND REPOID = 0;";
        sqlite3_stmt *statement;
        if (sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK) {
            sqlite3_bind_text(statement, 1, firstSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, 2, secondSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, 3, thirdSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, 4, fourthSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, 5, fifthSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, 6, sixthSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, 7, seventhSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, 8, eighthSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, 9, [[package identifier] UTF8String], -1, SQLITE_TRANSIENT);
            while (sqlite3_step(statement) == SQLITE_ROW) {
                ZBPackage *found = [[ZBPackage alloc] initWithSQLiteStatement:statement];
                [packages addObject:found];
            }
        }
        
        for (ZBPackage *conflictingPackage in [packages copy]) {
            for (NSString *conflict in [conflictingPackage conflictsWith]) {
                if (([conflict containsString:@"("] || [conflict containsString:@")"]) && [conflict containsString:[package identifier]]) {
                    NSArray *versionComparison = [ZBDependencyResolver separateVersionComparison:conflict];
                    if (![ZBDependencyResolver doesPackage:package satisfyComparison:versionComparison[1] ofVersion:versionComparison[2]]) {
                        [packages removeObject:conflictingPackage];
                    }
                }
            }
        }
        
        return [packages count] > 0 ? packages : NULL;
    }
    [self printDatabaseError];
    return NULL;
}

//- (BOOL)willDependency:(NSString *_Nonnull)dependency beSatisfiedAfterTheRemovalOf:(NSArray <ZBPackage *> *)packages {
//    NSMutableArray *array = [NSMutableArray new];
//    for (ZBPackage *package in packages) {
//        [array addObject:[NSString stringWithFormat:@"\'%@\'", [package identifier]]];
//    }
//    return [self willDependency:dependency beSatisfiedAfterTheRemovalOfPackageIdentifiers:array];
//}

- (BOOL)willDependencyBeSatisfiedAfterQueueOperations:(NSString *_Nonnull)dependency {
    if ([dependency containsString:@"|"]) {
        NSArray *components = [dependency componentsSeparatedByString:@"|"];
        for (NSString *dependency in components) {
            if ([self willDependencyBeSatisfiedAfterQueueOperations:[dependency stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]]) {
                return true;
            }
        }
        return false;
    }
    else if ([self openDatabase] == SQLITE_OK) {
        ZBQueue *queue = [ZBQueue sharedQueue];
        NSArray *addedPackages =   [queue packagesQueuedForAdddition]; //Packages that are being installed, upgraded, removed, downgraded, etc. (dependencies as well)
        NSArray *removedPackages = [queue packageIDsQueuedForRemoval]; //Just packageIDs that are queued for removal (conflicts as well)
        
        NSArray *versionComponents = [ZBDependencyResolver separateVersionComparison:dependency];
        NSString *packageIdentifier = versionComponents[0];
        BOOL needsVersionComparison = ![versionComponents[1] isEqualToString:@"<=>"] && ![versionComponents[2] isEqualToString:@"0:0"];
        
        NSString *excludeString = [self excludeStringFromArray:removedPackages];
        const char *firstSearchTerm = [[NSString stringWithFormat:@"%%, %@ (%%", packageIdentifier] UTF8String];
        const char *secondSearchTerm = [[NSString stringWithFormat:@"%%, %@, %%", packageIdentifier] UTF8String];
        const char *thirdSearchTerm = [[NSString stringWithFormat:@"%@ (%%", packageIdentifier] UTF8String];
        const char *fourthSearchTerm = [[NSString stringWithFormat:@"%@, %%", packageIdentifier] UTF8String];
        const char *fifthSearchTerm = [[NSString stringWithFormat:@"%%, %@", packageIdentifier] UTF8String];
        const char *sixthSearchTerm = [[NSString stringWithFormat:@"%%| %@", packageIdentifier] UTF8String];
        const char *seventhSearchTerm = [[NSString stringWithFormat:@"%%, %@ |%%", packageIdentifier] UTF8String];
        const char *eighthSearchTerm = [[NSString stringWithFormat:@"%@ |%%", packageIdentifier] UTF8String];
        
        NSString *query = [NSString stringWithFormat:@"SELECT VERSION FROM PACKAGES WHERE PACKAGE NOT IN %@ AND REPOID = 0 AND (PACKAGE = ? OR (PROVIDES LIKE ? OR PROVIDES LIKE ? OR PROVIDES LIKE ? OR PROVIDES LIKE ? OR PROVIDES LIKE ? OR PROVIDES LIKE ? OR PROVIDES LIKE ? OR PROVIDES LIKE ?)) LIMIT 1;", excludeString];
        
        BOOL found = false;
        sqlite3_stmt *statement;
        if (sqlite3_prepare_v2(database, [query UTF8String], -1, &statement, nil) == SQLITE_OK) {
            sqlite3_bind_text(statement, 1, [packageIdentifier UTF8String], -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, 2, firstSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, 3, secondSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, 4, thirdSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, 5, fourthSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, 6, fifthSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, 7, sixthSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, 8, seventhSearchTerm, -1, SQLITE_TRANSIENT);
            sqlite3_bind_text(statement, 9, eighthSearchTerm, -1, SQLITE_TRANSIENT);
            
            while (sqlite3_step(statement) == SQLITE_ROW) {
                if (needsVersionComparison) {
                    const char* foundVersion = (const char*)sqlite3_column_text(statement, 0);
                    
                    if (foundVersion != 0) {
                        if ([ZBDependencyResolver doesVersion:[NSString stringWithUTF8String:foundVersion] satisfyComparison:versionComponents[1] ofVersion:versionComponents[2]]) {
                            found = true;
                            break;
                        }
                    }
                }
                else {
                    found = true;
                    break;
                }
            }
            
            if (!found) { //Search the array of packages that are queued for installation to see if one of them satisfies the dependency
                for (NSDictionary *package in addedPackages) {
                    if ([[package objectForKey:@"identifier"] isEqualToString:packageIdentifier]) {
                        if (needsVersionComparison && [ZBDependencyResolver doesVersion:[package objectForKey:@"version"] satisfyComparison:versionComponents[1] ofVersion:versionComponents[2]]) {
                            return true;
                        }
                        else {
                            return true;
                        }
                    }
                }
                return false;
            }
            
            sqlite3_finalize(statement);
            [self closeDatabase];
            return found;
        }
        else {
            [self printDatabaseError];
            [self closeDatabase];
            return FALSE;
        }
        
    }
    else {
        [self printDatabaseError];
        return FALSE;
    }
}

#pragma mark - Hyena Delegate

- (void)predator:(nonnull ZBDownloadManager *)downloadManager finishedAllDownloads:(nonnull NSDictionary *)filenames {
    [self parseRepos:filenames];
}

- (void)predator:(nonnull ZBDownloadManager *)downloadManager startedDownloadForFile:(nonnull NSString *)filename {
    [self bulkSetRepo:filename busy:YES];
    [self bulkPostStatusUpdate:[NSString stringWithFormat:@"Downloading %@\n", filename] atLevel:ZBLogLevelDescript];
}

- (void)predator:(nonnull ZBDownloadManager *)downloadManager finishedDownloadForFile:(NSString *_Nullable)filename withError:(NSError * _Nullable)error {
    [self bulkSetRepo:filename busy:NO];
    if (error != NULL) {
        if (filename) {
            [self bulkPostStatusUpdate:[NSString stringWithFormat:@"%@ for %@\n", error.localizedDescription, filename] atLevel:ZBLogLevelError];
        } else {
            [self bulkPostStatusUpdate:[NSString stringWithFormat:@"%@\n", error.localizedDescription] atLevel:ZBLogLevelError];
        }
    } else if (filename) {
        [self bulkPostStatusUpdate:[NSString stringWithFormat:@"Done %@\n", filename] atLevel:ZBLogLevelDescript];
    }
}

- (void)postStatusUpdate:(NSString *)status atLevel:(ZBLogLevel)level {
    ZBLog(@"[Zebra] I'll forward your request... %@", status);
    [self bulkPostStatusUpdate:status atLevel:level];
}

#pragma mark - Helper methods

- (NSArray *)cleanUpDuplicatePackages:(NSArray <ZBPackage *> *)packageList {
    NSMutableDictionary *packageVersionDict = [[NSMutableDictionary alloc] init];
    NSMutableArray *results = [NSMutableArray array];
    
    for (ZBPackage *package in packageList) {
        ZBPackage *packageFromDict = packageVersionDict[package.identifier];
        if (packageFromDict == NULL) {
            packageVersionDict[package.identifier] = package;
            [results addObject:package];
            continue;
        }
        
        if ([package sameAs:packageFromDict]) {
            NSString *packageDictVersion = [packageFromDict version];
            NSString *packageVersion = package.version;
            int result = compare([packageVersion UTF8String], [packageDictVersion UTF8String]);
            
            if (result > 0) {
                NSUInteger index = [results indexOfObject:packageFromDict];
                packageVersionDict[package.identifier] = package;
                [results replaceObjectAtIndex:index withObject:package];
            }
        }
    }
    
    return results;
}

- (void)checkForZebraRepo {
    NSError *readError;
    NSString *repos = [NSString stringWithContentsOfFile:[ZBAppDelegate sourcesListPath] encoding:NSUTF8StringEncoding error:&readError];
    if (readError != nil) {
        NSLog(@"[Zebra] Error while reading source list");
    }

    if (![repos containsString:@"deb https://getzbra.com/repo/ ./"]) {
        NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:[ZBAppDelegate sourcesListPath]];
        [fileHandle seekToEndOfFile];
        [fileHandle writeData:[@"\ndeb https://getzbra.com/repo/ ./\n" dataUsingEncoding:NSUTF8StringEncoding]];
        [fileHandle closeFile];
    }
}

- (NSString *_Nullable)installedVersionForPackage:(ZBPackage *)package {
    if ([self openDatabase] == SQLITE_OK) {
        NSString *query = [NSString stringWithFormat:@"SELECT VERSION FROM PACKAGES WHERE PACKAGE = '%@' AND REPOID = 0", [package identifier]];
        
        NSString *version;
        sqlite3_stmt *statement;
        if (sqlite3_prepare_v2(database, [query UTF8String], -1, &statement, nil) == SQLITE_OK) {
            while (sqlite3_step(statement) == SQLITE_ROW) {
                const char *versionChars = (const char *)sqlite3_column_text(statement, 0);
                if (versionChars != 0) {
                    version = [NSString stringWithUTF8String:versionChars];
                }
                break;
            }
        } else {
            [self printDatabaseError];
        }
        sqlite3_finalize(statement);
        [self closeDatabase];
        
        return version;
    }
    
    [self printDatabaseError];
    [self closeDatabase];
    return NULL;
}

- (NSString *)excludeStringFromArray:(NSArray *)array {
    if ([array count]) {
        NSMutableString *result = [@"(" mutableCopy];
        [result appendString:[NSString stringWithFormat:@"\'%@\'", array[0]]];
        for (int i = 1; i < array.count; i++) {
            [result appendFormat:@", \'%@\'", array[i]];
        }
        [result appendString:@")"];
        
        return result;
    }
    return NULL;
}

@end
