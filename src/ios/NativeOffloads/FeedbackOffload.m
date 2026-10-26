//
//  FeedbackOffload.m
//  MinisApp
//
//  Native offload handler for `minis-feedback`.
//

#import <Foundation/Foundation.h>
#import "NativeOffloadUtils.h"
#include "kernel/native_offload.h"
#include <unistd.h>

#if __has_include("Minis-Swift.h")
#import "Minis-Swift.h"
#else
@interface FeedbackOffloadBridge : NSObject
+ (NSDictionary * _Nonnull)listFeedbackWithDays:(NSInteger)days limit:(NSInteger)limit;
+ (NSDictionary * _Nonnull)summaryFeedbackWithDays:(NSInteger)days;
@end
#endif

static NSString *const TOOL_NAME = @"minis-feedback";

static NSString *const HELP_TEXT =
    @"minis-feedback - Query and analyze user runtime feedback and critiques\n"
     "\n"
     "USAGE:\n"
     "  minis-feedback <command> [options]\n"
     "\n"
     "COMMANDS:\n"
     "  list         List recent feedback events (--days <N> --limit <N>)\n"
     "  summary      Aggregate feedback tags, praise/critique ratio and recent notes\n"
     "\n"
     "OPTIONS:\n"
     "  --days <N>   Only inspect feedback within last N days (default: 30)\n"
     "  --limit <N>  Max records to return (default: 50)\n"
     "  --help, -h   Show this help message\n"
     "  --compact    Minimize JSON output\n"
     "  -q, --quiet  Output only data field\n";

static int cmd_list(int argc, char **argv, int stdout_fd, BOOL compact, BOOL quiet) {
    NSString *daysRaw = noff_find_arg(argc, argv, "--days");
    NSString *limitRaw = noff_find_arg(argc, argv, "--limit");
    NSInteger days = daysRaw ? [daysRaw integerValue] : 30;
    NSInteger limit = limitRaw ? [limitRaw integerValue] : 50;

    NSDictionary *data = [FeedbackOffloadBridge listFeedbackWithDays:days limit:limit];
    NSDictionary *result = noff_json_envelope(TOOL_NAME, @"list", data);
    noff_emit_json(stdout_fd, result, compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

static int cmd_summary(int argc, char **argv, int stdout_fd, BOOL compact, BOOL quiet) {
    NSString *daysRaw = noff_find_arg(argc, argv, "--days");
    NSInteger days = daysRaw ? [daysRaw integerValue] : 30;

    NSDictionary *data = [FeedbackOffloadBridge summaryFeedbackWithDays:days];
    NSDictionary *result = noff_json_envelope(TOOL_NAME, @"summary", data);
    noff_emit_json(stdout_fd, result, compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

static int feedback_handler(int argc, char **argv, int stdin_fd, int stdout_fd, int stderr_fd) {
    if (noff_has_flag(argc, argv, "--help") || noff_has_flag(argc, argv, "-h")) {
        noff_emit_help(stderr_fd, HELP_TEXT);
        return NOFF_EXIT_SUCCESS;
    }

    BOOL compact = noff_has_flag(argc, argv, "--compact");
    BOOL quiet = noff_has_flag(argc, argv, "-q") || noff_has_flag(argc, argv, "--quiet");

    NSString *subcmd = noff_get_subcommand(argc, argv);
    if (!subcmd || [subcmd isEqualToString:@"list"]) {
        return cmd_list(argc, argv, stdout_fd, compact, quiet);
    } else if ([subcmd isEqualToString:@"summary"]) {
        return cmd_summary(argc, argv, stdout_fd, compact, quiet);
    }

    noff_emit_help(stderr_fd, HELP_TEXT);
    NSDictionary *err = noff_json_error(TOOL_NAME, subcmd, NOFF_ERR_INVALID_ARGS, @"Unknown command. Use --help.");
    noff_emit_json(stdout_fd, err, compact, quiet);
    return NOFF_EXIT_INVALID_ARGS;
}

void feedback_offload_register(void) {
    int err = native_offload_add_handler("minis-feedback", feedback_handler);
    if (err == 0) {
        noff_ensure_guest_stub("/usr/local/bin/minis-feedback");
        NSLog(@"NativeOffloads: minis-feedback handler registered");
    } else {
        NSLog(@"NativeOffloads: failed to register minis-feedback handler (err=%d)", err);
    }
}
