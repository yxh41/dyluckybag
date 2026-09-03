#import "DYConfig.h"
#import "DYEngine.h"
#import "DYPanel.h"
#import "DYLog.h"
#import "DYCrashLog.h"
#import <UIKit/UIKit.h>

// This file deliberately contains NO %hook blocks.
//
// Every other Douyin tweak breaks when the app updates because it hooks a class
// that gets renamed. This one hooks nothing: it waits for the app to finish
// launching, then drives itself entirely from screen capture + OCR. The only
// Objective-C runtime dependency is UIKit itself.

static void DYStartServices(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        DYLog(@"starting services in %@", NSBundle.mainBundle.bundleIdentifier);
        [[DYEngine shared] start];
        [[DYPanel shared] show];
        // Keep the panel counters fresh even when the panel is collapsed.
        [[DYPanel shared] refresh];
        DYLog(@"services started");
    });
}

%ctor {
    // Install crash diagnostics before anything else: a signal handler catches
    // the low-level fault class (@try/@catch cannot) and records a breadcrumb to
    // dyluckybag_crash.log so we no longer depend on digging up the system report.
    DYCrashLogInstall();

    DYLog(@"tweak loaded into %@ (v%@)", NSBundle.mainBundle.bundleIdentifier,
          [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"]);

    // Preferred path: start once the app has finished launching, plus a small
    // grace period so the live room UI has actually been laid out.
    [[NSNotificationCenter defaultCenter]
     addObserverForName:UIApplicationDidFinishLaunchingNotification
                 object:nil
                  queue:[NSOperationQueue mainQueue]
             usingBlock:^(NSNotification *note) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            DYStartServices();
        });
    }];

    // Fallback: if the notification already fired before the tweak was loaded
    // (or the app never posts it), start on a fixed delay anyway.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        DYStartServices();
    });

    DYLog(@"ctor complete");
}
