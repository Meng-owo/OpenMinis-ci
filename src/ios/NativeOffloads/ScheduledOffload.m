//
//  ScheduledOffload.m
//  MinisApp
//
//  Native offload handler for `minis-scheduled` (T-p2-minis-scheduled).
//  Contract mirrors Android's ScheduledTaskOffloadHandler (list / create /
//  delete / enable / disable / run, same flags) plus the iOS-side additions
//  --trigger / --after / --interval / --count / --of and the
//  child-of-current target. Argument strings are handed to the Swift bridge
//  untouched; all validation lives there.
//

#import <Foundation/Foundation.h>
#import "NativeOffloadUtils.h"
#include "kernel/native_offload.h"
#include <unistd.h>

#if __has_include("Minis-Swift.h")
#import "Minis-Swift.h"
#else
@interface ScheduledOffloadBridge : NSObject
+ (NSDictionary * _Nonnull)createWithArgs:(NSDictionary * _Nonnull)args;
+ (NSDictionary * _Nonnull)list;
+ (NSDictionary * _Nonnull)deleteWithId:(NSString * _Nonnull)id;
+ (NSDictionary * _Nonnull)setEnabledWithId:(NSString * _Nonnull)id enabled:(BOOL)enabled;
+ (NSDictionary * _Nonnull)runWithId:(NSString * _Nonnull)id;
+ (NSDictionary * _Nonnull)runsWithId:(NSString * _Nonnull)id;
@end
#endif

static NSString *const TOOL_NAME = @"minis-scheduled";

static NSString *const HELP_TEXT =
    @"minis-scheduled - Schedule prompts to run later in Minis (best effort while the app is alive)\n"
     "\n"
     "USAGE:\n"
     "  minis-scheduled list\n"
     "  minis-scheduled runs --id <jobId|label>            # history of a task\n"
     "  minis-scheduled create --prompt \"...\" [--label L] [--target new|follow-up|rerun|child-of-current]\n"
     "                         [--trigger once|loop|cron|on-completion]\n"
     "                         [--after 30m]                          # once, relative\n"
     "                         [--interval 10m] [--count N]           # loop\n"
     "                         [--time HH:MM] [--repeat once|daily|weekdays|custom --days mon,tue,...]\n"
     "                         [--start YYYY-MM-DD] [--end YYYY-MM-DD] # cron window\n"
     "                         [--of <jobId>]                         # on-completion\n"
     "                         [--session <id>] [--message <id>] [--model <entry_id>] [--disabled]\n"
     "                         [--thinking off|low|medium|high|xhigh]\n"
     "                         [--command \"<shell>\" [--timeout N]]    # prefill: run BEFORE the model wakes\n"
     "                         [--tool shell_execute|sh|shell|bash] [--tool-args <json>]  # prefill (shell only)\n"
     "                         [--pulse]                              # autonomous heartbeat mode\n"
     "  minis-scheduled delete  --id <jobId|label>\n"
     "  minis-scheduled enable  --id <jobId|label>\n"
     "  minis-scheduled disable --id <jobId|label>\n"
     "  minis-scheduled run     --id <jobId|label>     # fire now, off-schedule\n"
     "\n"
     "PREFILL & PULSE:\n"
     "  --command/--tool  run the tool FIRST and hand the model the real output as already-run\n"
     "                    context; saves a whole model round-trip. Supported: shell_execute.\n"
     "  --pulse           wake the assistant with an autonomy heartbeat;  the assistant decides\n"
     "                    from the moment + context whether to speak or reply `<silent/>` to stay quiet.\n"
     "\n"
     "TRIGGER (inferred when --trigger is omitted: --after→once, --interval→loop, --time→cron, --of→on-completion):\n"
     "  once           fire once after --after <duration> (30m, 2h, 90s) or at the next --time HH:MM\n"
     "  loop           fire every --interval (>= 60s), --count N times (default: until deleted)\n"
     "  cron           fire at --time on --repeat daily (default) | weekdays | custom --days\n"
     "  on-completion  fire when job --of <jobId> finishes; {{result}} in --prompt is replaced by its result\n"
     "\n"
     "TARGET (default: follow-up IN THIS CHAT when run from a chat; new when no chat behind the command):\n"
     "  new              a new top-level chat, visible in the session list\n"
     "  follow-up        appended as a new turn to --session (default: the chat this command runs in)\n"
     "  rerun            re-run --session from user message --message\n"
     "  child-of-current a hidden helper session under the current chat; its final answer is\n"
     "                   posted back into the current chat when it finishes\n"
     "\n"
     "IMPORTANT: the timer runs inside the app process; it is armed as soon as Minis starts again.\n"
     "A task and its run history survive a restart, and a fire that came due while the app was not\n"
     "running is recorded as MISSED rather than silently skipped — so the list always tells the\n"
     "truth about what did and did not run. A reminder notification is registered as insurance and\n"
     "says the task was DUE, not that it ran. For execution that is guaranteed even while Minis stays\n"
     "closed, use an Apple Shortcuts automation instead.\n"
     "\n"
     "EXAMPLES:\n"
     "  minis-scheduled create --prompt \"Summarize this build result\" --command \"make status\" --label build-watch --target follow-up\n"
     "  minis-scheduled create --prompt \"Decide whether to speak\" --pulse --interval 2h --label pulse-check --target follow-up\n"
     "  minis-scheduled create --prompt \"Check the build status\" --interval 10m --count 6 --label build-watch --target follow-up\n"
     "  minis-scheduled create --prompt \"Remind me to drink water\" --after 30m\n"
     "  minis-scheduled create --prompt \"Morning summary of my notes\" --time 09:00 --repeat weekdays\n"
     "  minis-scheduled list\n"
     "  minis-scheduled runs --id build-watch\n"
     "  minis-scheduled export --id build-watch --export /var/minis/workspace/build-watch.json\n"
     "  minis-scheduled update --id build-watch --interval 5m --count 12\n"
     "  minis-scheduled update --id build-watch --prompt \"New instruction\" --time 09:00 --repeat weekdays\n"
     "  minis-scheduled delete --id build-watch\n";

static NSString *arg(int argc, char **argv, const char *name) {
    NSString *v = noff_find_arg(argc, argv, name);
    return (v && v.length > 0) ? v : nil;
}

static void put(NSMutableDictionary *d, NSString *key, NSString *v) {
    if (v) d[key] = v;
}

static int cmd_create(int argc, char **argv, int stdout_fd, int stderr_fd, BOOL compact, BOOL quiet) {
    NSMutableDictionary *args = [NSMutableDictionary dictionary];
    put(args, @"prompt",   arg(argc, argv, "--prompt")   ?: arg(argc, argv, "-p"));
    put(args, @"label",    arg(argc, argv, "--label")    ?: arg(argc, argv, "-l"));
    put(args, @"trigger",  arg(argc, argv, "--trigger"));
    put(args, @"after",    arg(argc, argv, "--after"));
    put(args, @"interval", arg(argc, argv, "--interval"));
    put(args, @"count",    arg(argc, argv, "--count"));
    put(args, @"time",     arg(argc, argv, "--time")     ?: arg(argc, argv, "-t"));
    put(args, @"repeat",   arg(argc, argv, "--repeat")   ?: arg(argc, argv, "-r"));
    put(args, @"days",     arg(argc, argv, "--days"));
    put(args, @"start",    arg(argc, argv, "--start"));
    put(args, @"end",      arg(argc, argv, "--end"));
    put(args, @"of",       arg(argc, argv, "--of"));
    put(args, @"target",   arg(argc, argv, "--target"));
    put(args, @"session",  arg(argc, argv, "--session"));
    put(args, @"message",  arg(argc, argv, "--message"));
    put(args, @"model",    arg(argc, argv, "--model")    ?: arg(argc, argv, "-m"));
    // [T-scheduled-thinking-level] Optional; absent leaves the level alone.
    put(args, @"thinking", arg(argc, argv, "--thinking"));
    // [T-scheduled-prefill-and-pulse] Prefill tool / shell command / proactive pulse
    put(args, @"command",  arg(argc, argv, "--command")  ?: arg(argc, argv, "-c") ?: arg(argc, argv, "--shell"));
    put(args, @"tool",     arg(argc, argv, "--tool"));
    put(args, @"toolArgs", arg(argc, argv, "--tool-args"));
    put(args, @"timeout",  arg(argc, argv, "--timeout"));
    if (noff_has_flag(argc, argv, "--pulse")) args[@"pulse"] = @YES;
    args[@"disabled"] = @(noff_has_flag(argc, argv, "--disabled"));

    NSDictionary *data = [ScheduledOffloadBridge createWithArgs:args];
    if ([data[@"ok"] isKindOfClass:[NSNumber class]] && ![data[@"ok"] boolValue]) {
        noff_emit_help(stderr_fd, HELP_TEXT);
        NSDictionary *err = noff_json_error(TOOL_NAME, @"create", NOFF_ERR_INVALID_ARGS,
                                             data[@"message"] ?: @"invalid arguments");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }
    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"create", data), compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

// [AUD-11] Edit a task in place: same flags as create, and only the ones given
// are applied. The id is required (it is what identifies the task; --label
// names the NEW label here, as it does on create).
static int cmd_update(int argc, char **argv, int stdout_fd, int stderr_fd, BOOL compact, BOOL quiet) {
    NSMutableDictionary *args = [NSMutableDictionary dictionary];
    NSString *jobId = arg(argc, argv, "--id");
    if (!jobId) {
        NSArray *pos = noff_positional_args(argc, argv);
        if (pos.count >= 2) jobId = pos[1];   // `minis-scheduled update <id> …`
    }
    if (!jobId) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"update", NOFF_ERR_INVALID_ARGS, @"--id <jobId|label> required");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }
    args[@"id"] = jobId;
    put(args, @"prompt",   arg(argc, argv, "--prompt")   ?: arg(argc, argv, "-p"));
    put(args, @"title",    arg(argc, argv, "--title"));
    put(args, @"label",    arg(argc, argv, "--label")    ?: arg(argc, argv, "-l"));
    put(args, @"trigger",  arg(argc, argv, "--trigger"));
    put(args, @"after",    arg(argc, argv, "--after"));
    put(args, @"interval", arg(argc, argv, "--interval"));
    put(args, @"count",    arg(argc, argv, "--count"));
    put(args, @"time",     arg(argc, argv, "--time")     ?: arg(argc, argv, "-t"));
    put(args, @"repeat",   arg(argc, argv, "--repeat")   ?: arg(argc, argv, "-r"));
    put(args, @"days",     arg(argc, argv, "--days"));
    put(args, @"start",    arg(argc, argv, "--start"));
    put(args, @"end",      arg(argc, argv, "--end"));
    put(args, @"of",       arg(argc, argv, "--of"));
    put(args, @"target",   arg(argc, argv, "--target"));
    put(args, @"session",  arg(argc, argv, "--session"));
    put(args, @"message",  arg(argc, argv, "--message"));
    put(args, @"model",    arg(argc, argv, "--model")    ?: arg(argc, argv, "-m"));
    put(args, @"thinking", arg(argc, argv, "--thinking"));
    NSDictionary *data = [ScheduledOffloadBridge updateWithArgs:args];
    if ([data[@"ok"] isKindOfClass:[NSNumber class]] && ![data[@"ok"] boolValue]) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"update", NOFF_ERR_INVALID_ARGS,
                                             data[@"message"] ?: @"invalid arguments");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }
    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"update", data), compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

// [AUD-11] Dump one task's run history to a file the caller names.
static int cmd_export(int argc, char **argv, int stdout_fd, int stderr_fd, BOOL compact, BOOL quiet) {
    NSString *jobId = arg(argc, argv, "--id") ?: arg(argc, argv, "--label");
    if (!jobId) {
        NSArray *pos = noff_positional_args(argc, argv);
        if (pos.count >= 2) jobId = pos[1];
    }
    NSString *path = arg(argc, argv, "--export") ?: arg(argc, argv, "--out") ?: arg(argc, argv, "--path");
    if (!jobId || !path) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"export", NOFF_ERR_INVALID_ARGS,
                                             @"--id <jobId|label> and --export <path> required");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }
    NSDictionary *data = [ScheduledOffloadBridge exportRunsWithId:jobId path:path];
    if ([data[@"ok"] isKindOfClass:[NSNumber class]] && ![data[@"ok"] boolValue]) {
        NSDictionary *err = noff_json_error(TOOL_NAME, @"export", NOFF_ERR_INVALID_ARGS,
                                             data[@"message"] ?: @"failed");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }
    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"export", data), compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

static int cmd_with_id(NSString *action, int argc, char **argv, int stdout_fd, int stderr_fd,
                       BOOL compact, BOOL quiet) {
    NSString *jobId = arg(argc, argv, "--id") ?: arg(argc, argv, "--label");
    if (!jobId) {
        NSArray *pos = noff_positional_args(argc, argv);
        if (pos.count >= 2) jobId = pos[1];   // `minis-scheduled delete <id>`
    }
    if (!jobId) {
        NSDictionary *err = noff_json_error(TOOL_NAME, action, NOFF_ERR_INVALID_ARGS, @"--id <jobId|label> required");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }
    NSDictionary *data;
    if ([action isEqualToString:@"delete"])       data = [ScheduledOffloadBridge deleteWithId:jobId];
    else if ([action isEqualToString:@"enable"])  data = [ScheduledOffloadBridge setEnabledWithId:jobId enabled:YES];
    else if ([action isEqualToString:@"disable"]) data = [ScheduledOffloadBridge setEnabledWithId:jobId enabled:NO];
    else if ([action isEqualToString:@"runs"])    data = [ScheduledOffloadBridge runsWithId:jobId];
    else                                          data = [ScheduledOffloadBridge runWithId:jobId];
    if ([data[@"ok"] isKindOfClass:[NSNumber class]] && ![data[@"ok"] boolValue]) {
        NSDictionary *err = noff_json_error(TOOL_NAME, action, NOFF_ERR_INVALID_ARGS,
                                             data[@"message"] ?: @"failed");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }
    noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, action, data), compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

static int scheduled_handler(int argc, char **argv, int stdin_fd, int stdout_fd, int stderr_fd) {
    if (noff_has_flag(argc, argv, "--help") || noff_has_flag(argc, argv, "-h")) {
        noff_emit_help(stderr_fd, HELP_TEXT);
        return NOFF_EXIT_SUCCESS;
    }
    BOOL compact = noff_has_flag(argc, argv, "--compact");
    BOOL quiet = noff_has_flag(argc, argv, "-q") || noff_has_flag(argc, argv, "--quiet");
    NSString *sub = noff_get_subcommand(argc, argv) ?: @"list";

    if ([sub isEqualToString:@"list"]) {
        noff_emit_json(stdout_fd, noff_json_envelope(TOOL_NAME, @"list", [ScheduledOffloadBridge list]), compact, quiet);
        return NOFF_EXIT_SUCCESS;
    }
    if ([sub isEqualToString:@"create"] || [sub isEqualToString:@"add"]) {
        return cmd_create(argc, argv, stdout_fd, stderr_fd, compact, quiet);
    }
    if ([sub isEqualToString:@"delete"] || [sub isEqualToString:@"remove"] || [sub isEqualToString:@"rm"] || [sub isEqualToString:@"cancel"]) {
        return cmd_with_id(@"delete", argc, argv, stdout_fd, stderr_fd, compact, quiet);
    }
    if ([sub isEqualToString:@"enable"])  return cmd_with_id(@"enable", argc, argv, stdout_fd, stderr_fd, compact, quiet);
    if ([sub isEqualToString:@"disable"]) return cmd_with_id(@"disable", argc, argv, stdout_fd, stderr_fd, compact, quiet);
    if ([sub isEqualToString:@"run"])     return cmd_with_id(@"run", argc, argv, stdout_fd, stderr_fd, compact, quiet);
    if ([sub isEqualToString:@"runs"] || [sub isEqualToString:@"history"]) {
        return cmd_with_id(@"runs", argc, argv, stdout_fd, stderr_fd, compact, quiet);
    }
    if ([sub isEqualToString:@"update"] || [sub isEqualToString:@"edit"]) {
        return cmd_update(argc, argv, stdout_fd, stderr_fd, compact, quiet);
    }
    if ([sub isEqualToString:@"export"]) {
        return cmd_export(argc, argv, stdout_fd, stderr_fd, compact, quiet);
    }

    noff_emit_help(stderr_fd, HELP_TEXT);
    NSDictionary *err = noff_json_error(TOOL_NAME, sub, NOFF_ERR_INVALID_ARGS,
                                         [NSString stringWithFormat:@"Unknown command '%@'. Valid: list, runs, export, create, update, delete, enable, disable, run.", sub]);
    noff_emit_json(stdout_fd, err, compact, quiet);
    return NOFF_EXIT_INVALID_ARGS;
}

void scheduled_offload_register(void) {
    int err = native_offload_add_handler("minis-scheduled", scheduled_handler);
    if (err == 0) {
        noff_ensure_guest_stub("/usr/local/bin/minis-scheduled");
        NSLog(@"NativeOffloads: minis-scheduled handler registered");
    } else {
        NSLog(@"NativeOffloads: failed to register minis-scheduled handler (err=%d)", err);
    }
}
