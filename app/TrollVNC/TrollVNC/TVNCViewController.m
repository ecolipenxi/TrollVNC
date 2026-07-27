/*
 This file is part of TrollVNC
 Copyright (c) 2025 82Flex <82flex@gmail.com> and contributors

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License version 2
 as published by the Free Software Foundation.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with this program. If not, see <https://www.gnu.org/licenses/>.
*/

#import "TVNCViewController.h"
#import "GitHubReleaseUpdater.h"
#import "TVNCServiceCoordinator.h"

#import <UserNotifications/UserNotifications.h>

@interface TVLuaManagerViewController : UIViewController
@property(nonatomic, strong) UITextView *editor;
@property(nonatomic, strong) UITextView *statusView;
@property(nonatomic, strong) NSTimer *statusTimer;
@end

@implementation TVLuaManagerViewController

- (NSString *)scriptPath {
    NSString *documents = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [documents stringByAppendingPathComponent:@"automation.lua"];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Lua Agent";
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    self.editor = [[UITextView alloc] init];
    self.editor.translatesAutoresizingMaskIntoConstraints = NO;
    self.editor.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    self.editor.autocorrectionType = UITextAutocorrectionTypeNo;
    self.editor.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.editor.layer.borderWidth = 1;
    self.editor.layer.borderColor = UIColor.separatorColor.CGColor;
    self.editor.layer.cornerRadius = 8;

    self.statusView = [[UITextView alloc] init];
    self.statusView.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusView.editable = NO;
    self.statusView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    self.statusView.backgroundColor = UIColor.secondarySystemBackgroundColor;
    self.statusView.layer.cornerRadius = 8;
    self.statusView.text = @"Agent: connecting...";

    UIStackView *buttons = [[UIStackView alloc] init];
    buttons.translatesAutoresizingMaskIntoConstraints = NO;
    buttons.axis = UILayoutConstraintAxisHorizontal;
    buttons.distribution = UIStackViewDistributionFillEqually;
    buttons.spacing = 8;
    NSArray *items = @[
        @[@"Sample", NSStringFromSelector(@selector(loadSample))],
        @[@"Save", NSStringFromSelector(@selector(saveScript))],
        @[@"Run", NSStringFromSelector(@selector(runScript))],
        @[@"Stop", NSStringFromSelector(@selector(stopScript))]
    ];
    for (NSArray *item in items) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        [button setTitle:item[0] forState:UIControlStateNormal];
        button.backgroundColor = UIColor.tertiarySystemBackgroundColor;
        button.layer.cornerRadius = 7;
        [button addTarget:self action:NSSelectorFromString(item[1])
         forControlEvents:UIControlEventTouchUpInside];
        [buttons addArrangedSubview:button];
    }

    [self.view addSubview:self.editor];
    [self.view addSubview:buttons];
    [self.view addSubview:self.statusView];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.editor.topAnchor constraintEqualToAnchor:safe.topAnchor constant:10],
        [self.editor.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:10],
        [self.editor.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-10],
        [self.editor.heightAnchor constraintEqualToAnchor:safe.heightAnchor multiplier:0.52],
        [buttons.topAnchor constraintEqualToAnchor:self.editor.bottomAnchor constant:8],
        [buttons.leadingAnchor constraintEqualToAnchor:self.editor.leadingAnchor],
        [buttons.trailingAnchor constraintEqualToAnchor:self.editor.trailingAnchor],
        [buttons.heightAnchor constraintEqualToConstant:42],
        [self.statusView.topAnchor constraintEqualToAnchor:buttons.bottomAnchor constant:8],
        [self.statusView.leadingAnchor constraintEqualToAnchor:self.editor.leadingAnchor],
        [self.statusView.trailingAnchor constraintEqualToAnchor:self.editor.trailingAnchor],
        [self.statusView.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-10],
    ]];

    NSString *saved = [NSString stringWithContentsOfFile:self.scriptPath
                                                encoding:NSUTF8StringEncoding error:nil];
    if (saved.length) self.editor.text = saved;
    else [self loadSample];

    self.statusTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self
        selector:@selector(refreshStatus) userInfo:nil repeats:YES];
    [self refreshStatus];
}

- (void)dealloc {
    [self.statusTimer invalidate];
}

- (void)loadSample {
    self.editor.text =
        @"screen.init(0)\n"
         "nLog('Going Home')\n"
         "key.press('HOMEBUTTON')\n"
         "sys.msleep(1200)\n"
         "touch.on(650, 700):move(100, 700):off()\n"
         "sys.msleep(900)\n"
         "touch.on(100, 700):move(650, 700):off()\n"
         "nLog('Done')\n";
}

- (void)saveScript {
    NSError *error = nil;
    [self.editor.text writeToFile:self.scriptPath atomically:YES
                         encoding:NSUTF8StringEncoding error:&error];
    self.statusView.text = error ? error.localizedDescription : @"Saved automation.lua";
}

- (void)requestPath:(NSString *)path method:(NSString *)method
               body:(NSData *)body completion:(void (^)(NSData *, NSError *))completion {
    NSURL *url = [NSURL URLWithString:
        [NSString stringWithFormat:@"http://127.0.0.1:46952%@", path]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = method;
    request.HTTPBody = body;
    request.timeoutInterval = 5;
    [request setValue:@"text/plain; charset=utf-8" forHTTPHeaderField:@"Content-Type"];
    [[NSURLSession.sharedSession dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(data, error);
            });
        }] resume];
}

- (void)runScript {
    [self saveScript];
    NSData *body = [self.editor.text dataUsingEncoding:NSUTF8StringEncoding];
    [self requestPath:@"/spawn" method:@"POST" body:body
        completion:^(NSData *data, NSError *error) {
            self.statusView.text = error.localizedDescription ?:
                [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        }];
}

- (void)stopScript {
    [self requestPath:@"/recycle" method:@"POST" body:nil
        completion:^(NSData *data, NSError *error) {
            self.statusView.text = error.localizedDescription ?:
                [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        }];
}

- (void)refreshStatus {
    [self requestPath:@"/status" method:@"GET" body:nil
        completion:^(NSData *data, NSError *error) {
            if (error) {
                self.statusView.text = [@"Agent offline: "
                    stringByAppendingString:error.localizedDescription];
                return;
            }
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSDictionary *status = json[@"data"];
            if (![status isKindOfClass:NSDictionary.class]) return;
            NSMutableString *text = [NSMutableString stringWithFormat:@"Running: %@\n",
                                     [status[@"running"] boolValue] ? @"YES" : @"NO"];
            NSString *lastError = status[@"last_error"];
            if (lastError.length) [text appendFormat:@"Error: %@\n", lastError];
            NSArray *logs = status[@"logs"];
            if (logs.count) [text appendFormat:@"\n%@", [logs componentsJoinedByString:@"\n"]];
            self.statusView.text = text;
        }];
}

@end

@interface TVNCViewController ()

@property(nonatomic, weak) UIAlertController *alertController;
@property(nonatomic, strong) NSTimer *checkTimer;
@property(nonatomic, strong) NSBundle *localizationBundle;

@end

@implementation TVNCViewController {
    BOOL _isAlertPresented;
    BOOL _hasManagedConfiguration;
}

- (void)installLuaButton {
    UIViewController *root = self.topViewController;
    if (!root || root.navigationItem.rightBarButtonItem) return;
    root.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"Lua"
            style:UIBarButtonItemStylePlain target:self action:@selector(openLuaManager)];
}

- (void)openLuaManager {
    TVLuaManagerViewController *controller = [[TVLuaManagerViewController alloc] init];
    [self pushViewController:controller animated:YES];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self installLuaButton];

    NSBundle *resBundle = [NSBundle bundleWithPath:[[NSBundle mainBundle] pathForResource:@"TrollVNCPrefs"
                                                                                   ofType:@"bundle"]];
    self.localizationBundle = resBundle ?: [NSBundle mainBundle];

    NSString *presetPath = [resBundle pathForResource:@"Managed" ofType:@"plist"];
    if (presetPath) {
        NSDictionary *presetDict = [NSDictionary dictionaryWithContentsOfFile:presetPath];
        if (presetDict) {
            _hasManagedConfiguration = YES;
        }
    }

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(serviceStatusDidChange:)
                                                 name:TVNCServiceStatusDidChangeNotification
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(releaseUpdaterDidFindUpdate:)
                                                 name:GitHubReleaseUpdaterDidFindUpdateNotification
                                               object:nil];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self installLuaButton];

    if (_isAlertPresented) {
        return;
    }

    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    [center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *_Nonnull settings) {
        if (settings.authorizationStatus == UNAuthorizationStatusNotDetermined) {
            [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound |
                                                     UNAuthorizationOptionBadge)
                                  completionHandler:^(BOOL granted, NSError *_Nullable error) {
                                      // No UI changes needed here; could log if desired.
                                      (void)granted;
                                      (void)error;
                                  }];
        }
    }];

    if ([[TVNCServiceCoordinator sharedCoordinator] isServiceRunning]) {
        [self presentNewVersionAlertIfNeeded];
        _isAlertPresented = YES;
        return;
    }

    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:NSLocalizedStringFromTableInBundle(@"Launching", @"Localizable",
                                                                                       self.localizationBundle, nil)
                                            message:nil
                                     preferredStyle:UIAlertControllerStyleAlert];

    [self presentViewController:alert animated:YES completion:nil];

    self.alertController = alert;
    self.checkTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                       target:self
                                                     selector:@selector(checkServiceStatus:)
                                                     userInfo:nil
                                                      repeats:YES];

    _isAlertPresented = YES;
}

- (void)checkServiceStatus:(NSTimer *)timer {
    [self reloadWithCoordinator:[TVNCServiceCoordinator sharedCoordinator]];
}

- (void)serviceStatusDidChange:(NSNotification *)aNoti {
    TVNCServiceCoordinator *coordinator = (TVNCServiceCoordinator *)aNoti.object;
    [self reloadWithCoordinator:coordinator];
}

- (void)reloadWithCoordinator:(TVNCServiceCoordinator *)coordinator {
    if (![coordinator isServiceRunning]) {
        return;
    }

    [self.alertController dismissViewControllerAnimated:YES completion:nil];
    self.alertController = nil;

    [self.checkTimer invalidate];
    self.checkTimer = nil;
}

- (void)releaseUpdaterDidFindUpdate:(NSNotification *)aNoti {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self presentNewVersionAlertIfNeeded];
    });
}

- (void)presentNewVersionAlertIfNeeded {
    if (self.presentedViewController || _hasManagedConfiguration) {
        return;
    }

    GitHubReleaseUpdater *updater = [GitHubReleaseUpdater shared];
    if (![updater hasNewerVersionInCache]) {
        return;
    }

    GHReleaseInfo *releaseInfo = [updater cachedLatestRelease];
    if (!releaseInfo) {
        return;
    }

    NSString *releaseVersion = releaseInfo.versionString;
    NSString *alertTitle =
        NSLocalizedStringFromTableInBundle(@"New Version Available", @"Localizable", self.localizationBundle, nil);
    NSString *alertMessage =
        [NSString stringWithFormat:NSLocalizedStringFromTableInBundle(
                                       @"A new version %@ is available! You’re currently using v%@.", @"Localizable",
                                       self.localizationBundle, nil),
                                   releaseVersion, [[GitHubReleaseUpdater shared] currentVersion]];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:alertTitle
                                                                   message:alertMessage
                                                            preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction
                         actionWithTitle:NSLocalizedStringFromTableInBundle(@"Skip This Version", @"Localizable",
                                                                            self.localizationBundle, nil)
                                   style:UIAlertActionStyleDefault
                                 handler:^(UIAlertAction *_Nonnull action) {
                                     GitHubReleaseUpdater *updater = [GitHubReleaseUpdater shared];
                                     [updater skipVersion:releaseVersion];
                                 }]];

    [alert addAction:[UIAlertAction
                         actionWithTitle:NSLocalizedStringFromTableInBundle(@"Pause Auto Update", @"Localizable",
                                                                            self.localizationBundle, nil)
                                   style:UIAlertActionStyleDefault
                                 handler:^(UIAlertAction *_Nonnull action) {
                                     GitHubReleaseUpdater *updater = [GitHubReleaseUpdater shared];
                                     [updater skipVersion:releaseVersion];
                                     [updater pauseFor:60 * 60 * 24 * 14]; // pause auto update for 14 days
                                 }]];

    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedStringFromTableInBundle(@"Later", @"Localizable",
                                                                                       self.localizationBundle, nil)
                                              style:UIAlertActionStyleCancel
                                            handler:^(UIAlertAction *_Nonnull action){
                                            }]];

    [alert addAction:[UIAlertAction actionWithTitle:NSLocalizedStringFromTableInBundle(@"Upgrade Now", @"Localizable",
                                                                                       self.localizationBundle, nil)
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *_Nonnull action) {
                                                NSString *pageURLString = releaseInfo.htmlURL;
                                                if (!pageURLString) {
                                                    return;
                                                }

                                                NSURL *pageURL = [NSURL URLWithString:pageURLString];
                                                if (!pageURL) {
                                                    return;
                                                }

                                                if (![[UIApplication sharedApplication] canOpenURL:pageURL]) {
                                                    return;
                                                }

                                                [[UIApplication sharedApplication] openURL:pageURL
                                                    options:@{}
                                                    completionHandler:^(BOOL succeed) {
                                                        if (succeed) {
                                                            [[GitHubReleaseUpdater shared] clearSkippedVersion];
                                                        }
                                                    }];
                                            }]];

    [self presentViewController:alert animated:YES completion:nil];
}

@end
