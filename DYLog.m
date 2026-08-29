#import "DYLog.h"

#ifdef DEBUG

// Douyin runs inside the App Store sandbox, so /var/mobile is almost never
// writable. Try the shared path first (handy on a jailbroken device with the
// app running unsandboxed), then fall back to the app's own temporary
// directory, which always works.
static NSString *DYLogFilePath(void) {
    static NSString *resolved;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray<NSString *> *candidates = @[
            @"/var/mobile/dyluckybag.log",
            [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/dyluckybag.log"],
            [NSTemporaryDirectory() stringByAppendingPathComponent:@"dyluckybag.log"],
        ];
        for (NSString *path in candidates) {
            if ([[NSData data] writeToFile:path atomically:YES]) {
                resolved = [path copy];
                break;
            }
        }
    });
    return resolved;
}

void DYLogWrite(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSLog(@"[DYLuckyBag] %@", message);

    NSString *path = DYLogFilePath();
    if (!path) {
        return;
    }

    static NSDateFormatter *formatter;
    static dispatch_once_t fmtToken;
    dispatch_once(&fmtToken, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"HH:mm:ss.SSS";
    });

    NSString *line = [NSString stringWithFormat:@"%@ %@\n",
                      [formatter stringFromDate:[NSDate date]], message];

    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (handle) {
        [handle seekToEndOfFile];
        [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [handle closeFile];
    } else {
        NSData *existing = [NSData dataWithContentsOfFile:path] ?: [NSData data];
        NSMutableData *appended = [existing mutableCopy];
        [appended appendData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [appended writeToFile:path atomically:YES];
    }
}

#else

// Release builds compile logging out entirely. Emit one dummy symbol so this
// translation unit is not empty — an empty object file upsets some linkers and
// makes it look like the file was silently dropped from the build.
void DYLuckyBagLogCompiledOut(void) {}

#endif /* DEBUG */
