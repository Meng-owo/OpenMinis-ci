//
//  ThemeOffloadExtras+Commands.m
//  MinisApp
//
//  ObjC side of the extended `minis-theme` surface: argument parsing and
//  guest→host path resolution for avatars, row icons, per-page wallpapers
//  and single colour overrides. The work itself lives in
//  ThemeOffloadExtras.swift.
//

#import <Foundation/Foundation.h>
#import "NativeOffloadUtils.h"
#import "ThemeOffloadExtras.h"
#include "kernel/native_offload.h"

#if __has_include("Minis-Swift.h")
#import "Minis-Swift.h"
#else
@interface ThemeOffloadExtras : NSObject
+ (NSDictionary * _Nonnull)setAvatar:(NSString * _Nonnull)role hostPath:(NSString * _Nonnull)path;
+ (NSDictionary * _Nonnull)removeAvatar:(NSString * _Nonnull)role;
+ (NSDictionary * _Nonnull)setIcon:(NSString * _Nonnull)slot hostPath:(NSString * _Nonnull)path;
+ (NSDictionary * _Nonnull)removeIcon:(NSString * _Nonnull)slot;
+ (NSDictionary * _Nonnull)listIconSlots;
+ (NSDictionary * _Nonnull)setWallpaper:(NSString * _Nonnull)scope hostPath:(NSString * _Nonnull)path;
+ (NSDictionary * _Nonnull)removeWallpaper:(NSString * _Nonnull)scope;
+ (NSDictionary * _Nonnull)setColor:(NSString * _Nonnull)role hex:(NSString * _Nonnull)hex
                              scope:(NSString * _Nonnull)scope variant:(NSString * _Nonnull)variant;
+ (NSDictionary * _Nonnull)clearColor:(NSString * _Nonnull)role
                                scope:(NSString * _Nonnull)scope variant:(NSString * _Nonnull)variant;
@end
#endif

static NSString *const EXTRA_TOOL_NAME = @"minis-theme";

/// Mirrors ThemeOffload.m's emit_bridge. Kept here so the extended commands
/// do not need to reach back into that file's statics.
int theme_extra_emit(NSDictionary *raw, NSString *action,
                     int stdout_fd, BOOL compact, BOOL quiet) {
    if (![raw isKindOfClass:[NSDictionary class]]) {
        NSDictionary *err = noff_json_error(EXTRA_TOOL_NAME, action, NOFF_ERR_INTERNAL_ERROR,
                                            @"theme bridge returned nothing");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_ERROR;
    }
    id okVal = raw[@"ok"];
    BOOL ok = YES;
    if ([okVal isKindOfClass:[NSNumber class]]) ok = [okVal boolValue];
    if (!ok) {
        NSString *code = raw[@"error"] ?: NOFF_ERR_INVALID_ARGS;
        NSString *msg = raw[@"message"] ?: @"theme command failed";
        NSDictionary *err = noff_json_error(EXTRA_TOOL_NAME, action, code, msg);
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }
    NSMutableDictionary *payload = [raw mutableCopy];
    [payload removeObjectForKey:@"ok"];
    NSDictionary *result = noff_json_envelope(EXTRA_TOOL_NAME, action, payload);
    noff_emit_json(stdout_fd, result, compact, quiet);
    return NOFF_EXIT_SUCCESS;
}

/// Resolves `--file`/`--image` to a host path, answering the caller with an
/// error envelope when the path is missing or unmappable.
static NSString *_Nullable extra_host_path(NSString *guest, int stdout_fd,
                                           NSString *action, BOOL compact, BOOL quiet) {
    if (guest.length == 0) {
        NSDictionary *err = noff_json_error(EXTRA_TOOL_NAME, action, NOFF_ERR_INVALID_ARGS,
                                            @"--file <path> is required.");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return nil;
    }
    NSString *host = noff_resolve_host_path(guest);
    if (host.length == 0) {
        NSDictionary *err = noff_json_error(
            EXTRA_TOOL_NAME, action, NOFF_ERR_NO_DATA,
            [NSString stringWithFormat:@"Cannot resolve %@", guest]);
        noff_emit_json(stdout_fd, err, compact, quiet);
        return nil;
    }
    return host;
}

int theme_extra_avatar(int argc, char **argv, int stdout_fd, BOOL compact, BOOL quiet) {
    NSString *role = noff_find_arg(argc, argv, "--role") ?: @"user";
    BOOL remove = noff_has_flag(argc, argv, "--remove");
    NSDictionary *raw;
    if (remove) {
        raw = [ThemeOffloadExtras removeAvatar:role];
    } else {
        NSString *host = extra_host_path(noff_find_arg(argc, argv, "--file"),
                                         stdout_fd, @"avatar", compact, quiet);
        if (!host) return NOFF_EXIT_INVALID_ARGS;
        raw = [ThemeOffloadExtras setAvatar:role hostPath:host];
    }
    return theme_extra_emit(raw, @"avatar", stdout_fd, compact, quiet);
}

int theme_extra_icon(int argc, char **argv, int stdout_fd, BOOL compact, BOOL quiet) {
    if (noff_has_flag(argc, argv, "--list")) {
        return theme_extra_emit([ThemeOffloadExtras listIconSlots], @"icon",
                                stdout_fd, compact, quiet);
    }
    NSString *slot = noff_find_arg(argc, argv, "--slot");
    if (slot.length == 0) {
        NSDictionary *err = noff_json_error(EXTRA_TOOL_NAME, @"icon", NOFF_ERR_INVALID_ARGS,
                                            @"--slot <name> is required. Use `minis-theme icon --list`.");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }
    NSDictionary *raw;
    if (noff_has_flag(argc, argv, "--remove")) {
        raw = [ThemeOffloadExtras removeIcon:slot];
    } else {
        NSString *host = extra_host_path(noff_find_arg(argc, argv, "--file"),
                                         stdout_fd, @"icon", compact, quiet);
        if (!host) return NOFF_EXIT_INVALID_ARGS;
        raw = [ThemeOffloadExtras setIcon:slot hostPath:host];
    }
    return theme_extra_emit(raw, @"icon", stdout_fd, compact, quiet);
}

int theme_extra_wallpaper(int argc, char **argv, int stdout_fd, BOOL compact, BOOL quiet) {
    NSString *scope = noff_find_arg(argc, argv, "--scope") ?: @"global";
    NSDictionary *raw;
    if (noff_has_flag(argc, argv, "--remove")) {
        raw = [ThemeOffloadExtras removeWallpaper:scope];
    } else {
        NSString *host = extra_host_path(noff_find_arg(argc, argv, "--file"),
                                         stdout_fd, @"wallpaper", compact, quiet);
        if (!host) return NOFF_EXIT_INVALID_ARGS;
        raw = [ThemeOffloadExtras setWallpaper:scope hostPath:host];
    }
    return theme_extra_emit(raw, @"wallpaper", stdout_fd, compact, quiet);
}

int theme_extra_color(int argc, char **argv, int stdout_fd, BOOL compact, BOOL quiet) {
    NSString *scope = noff_find_arg(argc, argv, "--scope") ?: @"global";
    // [T-theme-color-read] `--list` 是读，不需要 --role。放在最前面，
    // 否则下面那条 --role 必填会把它挡掉。
    if (noff_has_flag(argc, argv, "--list")) {
        return theme_extra_emit([ThemeOffloadExtras listColors:scope], @"color",
                                stdout_fd, compact, quiet);
    }
    NSString *role = noff_find_arg(argc, argv, "--role");
    if (role.length == 0) {
        NSDictionary *err = noff_json_error(
            EXTRA_TOOL_NAME, @"color", NOFF_ERR_INVALID_ARGS,
            @"--role <role> is required (canvas, surface, accent, …). Use `minis-theme color --list` to see them all with their current values.");
        noff_emit_json(stdout_fd, err, compact, quiet);
        return NOFF_EXIT_INVALID_ARGS;
    }
    NSString *variant = noff_find_arg(argc, argv, "--variant") ?: @"light";
    NSDictionary *raw;
    if (noff_has_flag(argc, argv, "--clear")) {
        raw = [ThemeOffloadExtras clearColor:role scope:scope variant:variant];
    } else {
        NSString *hex = noff_find_arg(argc, argv, "--hex");
        if (hex.length == 0) {
            NSDictionary *err = noff_json_error(
                EXTRA_TOOL_NAME, @"color", NOFF_ERR_INVALID_ARGS,
                @"--hex <RRGGBB> is required unless --clear is passed.");
            noff_emit_json(stdout_fd, err, compact, quiet);
            return NOFF_EXIT_INVALID_ARGS;
        }
        raw = [ThemeOffloadExtras setColor:role hex:hex scope:scope variant:variant];
    }
    return theme_extra_emit(raw, @"color", stdout_fd, compact, quiet);
}
