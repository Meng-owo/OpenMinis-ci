//
//  TTSOffload.m
//  MinisApp
//
//  Native offload handler for `minis-tts`.
//

#import <Foundation/Foundation.h>
#import "NativeOffloadUtils.h"
#include "kernel/native_offload.h"
#include <unistd.h>

#if __has_include("Minis-Swift.h")
#import "Minis-Swift.h"
#else
@interface TTSOffloadBridge : NSObject
+ (NSDictionary * _Nonnull)listServices;
+ (NSDictionary * _Nonnull)getStatus;
@end
#endif

static NSString *const TOOL_NAME = @"minis-tts";

static NSString *const HELP_TEXT =
    @"minis-tts - Inspect voice services, audio groups and TTS capabilities\n"
     "\n"
     "USAGE:\n"
     "  minis-tts <command> [options]\n"
     "\n"
     "COMMANDS:\n"
     "  list         List configured TTS services, voice names and groups\n"
     "  status       Check if voice reply is available and active engine\n"
     "\n"
     "OPTIONS:\n"
     "  --help, -h   Show this help message\n"
     "  --compact    Minimize JSON output\n"
     "  -q, --quiet  Output only data field\n";

static int cmd_list(int argc, char **argv, int stdout_fd, BOOL compact, BOOL quiet) {
    NSDictionary *data = [TTSOffloadBridge listServices];
    NSDictionary *result = noff_json_envelope(TOOL_NAME, @"list", data);
    noff_emit_json(stdout_fd, result, compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

static int cmd_status(int argc, char **argv, int stdout_fd, BOOL compact, BOOL quiet) {
    NSDictionary *data = [TTSOffloadBridge getStatus];
    NSDictionary *result = noff_json_envelope(TOOL_NAME, @"status", data);
    noff_emit_json(stdout_fd, result, compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

static int tts_handler(int argc, char **argv, int stdin_fd, int stdout_fd, int stderr_fd) {
    if (noff_has_flag(argc, argv, "--help") || noff_has_flag(argc, argv, "-h")) {
        noff_emit_help(stderr_fd, HELP_TEXT);
        return NOFF_EXIT_SUCCESS;
    }

    BOOL compact = noff_has_flag(argc, argv, "--compact");
    BOOL quiet = noff_has_flag(argc, argv, "-q") || noff_has_flag(argc, argv, "--quiet");

    NSString *subcmd = noff_get_subcommand(argc, argv);
    if (!subcmd || [subcmd isEqualToString:@"list"]) {
        return cmd_list(argc, argv, stdout_fd, compact, quiet);
    } else if ([subcmd isEqualToString:@"status"]) {
        return cmd_status(argc, argv, stdout_fd, compact, quiet);
    }

    noff_emit_help(stderr_fd, HELP_TEXT);
    NSDictionary *err = noff_json_error(TOOL_NAME, subcmd, NOFF_ERR_INVALID_ARGS, @"Unknown command. Use --help.");
    noff_emit_json(stdout_fd, err, compact, quiet);
    return NOFF_EXIT_INVALID_ARGS;
}

void tts_offload_register(void) {
    int err = native_offload_add_handler("minis-tts", tts_handler);
    if (err == 0) {
        noff_ensure_guest_stub("/usr/local/bin/minis-tts");
        NSLog(@"NativeOffloads: minis-tts handler registered");
    } else {
        NSLog(@"NativeOffloads: failed to register minis-tts handler (err=%d)", err);
    }
}
