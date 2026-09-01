#import "DYLog.h"

#ifdef DEBUG

// A verbose pass dumps every recognised string, which is roughly a kilobyte
// every few seconds. Cap the file so it stays both usable and sendable: past the
// limit we keep the tail, because the interesting part of a field log is always
// what happened most recently.
static const unsigned long long kMaxLogBytes = 1500000ULL;
static const NSUInteger kKeepTailBytes = 512 * 1024;

// Douyin runs inside the App Store sandbox, so /var/mobile is almost never
// writable. Try the shared path first (handy on a jailbroken device with the
// app running unsandboxed), then fall back to the app's own directories, which
// always work.
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

// Every file operation funnels through this one queue. The OCR completion
// handler logs from the OCR queue while the engine and the panel log from the
// main thread, and neither NSFileHandle's seek-then-write nor NSDateFormatter is
// safe to touch from two threads at once. Serialising also keeps the file I/O
// off whatever thread happened to log.
static dispatch_queue_t DYLogQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("com.dyluckybag.log", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

void DYLogWrite(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSLog(@"[DYLuckyBag] %@", message);

    if (!DYLogFilePath()) {
        return;
    }

    // Stamp at call time, not at write time: the log queue can lag behind a
    // burst, and a timestamp taken on the queue would misreport when it happened.
    NSDate *now = [NSDate date];

    dispatch_async(DYLogQueue(), ^{
        static NSDateFormatter *formatter;
        static dispatch_once_t formatterToken;
        dispatch_once(&formatterToken, ^{
            formatter = [[NSDateFormatter alloc] init];
            formatter.dateFormat = @"HH:mm:ss.SSS";
        });

        NSString *line = [NSString stringWithFormat:@"%@ %@\n",
                          [formatter stringFromDate:now], message];
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        if (!data) {
            return;
        }

        NSString *path = DYLogFilePath();
        NSFileManager *files = NSFileManager.defaultManager;

        NSDictionary *attributes = [files attributesOfItemAtPath:path error:nil];
        unsigned long long size = [attributes fileSize];
        if (size > kMaxLogBytes) {
            NSFileHandle *reader = [NSFileHandle fileHandleForReadingAtPath:path];
            if (reader) {
                [reader seekToFileOffset:size - kKeepTailBytes];
                NSData *tail = [reader readDataToEndOfFile];
                [reader closeFile];
                NSMutableData *trimmed = [NSMutableData data];
                [trimmed appendData:[@"... (earlier lines dropped)\n"
                                     dataUsingEncoding:NSUTF8StringEncoding]];
                [trimmed appendData:tail];
                [trimmed writeToFile:path atomically:YES];
            } else {
                [files createFileAtPath:path contents:nil attributes:nil];
            }
        }

        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        if (handle) {
            [handle seekToEndOfFile];
            [handle writeData:data];
            [handle closeFile];
        } else {
            [files createFileAtPath:path contents:data attributes:nil];
        }
    });
}

#else

// Release builds compile logging out entirely. Emit one dummy symbol so this
// translation unit is not empty — an empty object file upsets some linkers and
// makes it look like the file was silently dropped from the build.
void DYLuckyBagLogCompiledOut(void) {}

#endif /* DEBUG */
