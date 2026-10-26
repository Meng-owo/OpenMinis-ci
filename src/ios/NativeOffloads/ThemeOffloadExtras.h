//
//  ThemeOffloadExtras.h
//  MinisApp
//
//  Extended `minis-theme` subcommands. Split out of ThemeOffload.m so the
//  original file stays readable: each function parses its own argv slice and
//  returns a process exit code.
//

#ifndef ThemeOffloadExtras_h
#define ThemeOffloadExtras_h

#import <Foundation/Foundation.h>

/// Emits a bridge result and maps `ok` to a process exit code. Shared by
/// every extended command, and by ThemeOffload.m for its own handlers.
int theme_extra_emit(NSDictionary * _Nullable raw, NSString * _Nonnull action,
                     int stdout_fd, BOOL compact, BOOL quiet);

int theme_extra_avatar(int argc, char **argv, int stdout_fd, BOOL compact, BOOL quiet);
int theme_extra_icon(int argc, char **argv, int stdout_fd, BOOL compact, BOOL quiet);
int theme_extra_wallpaper(int argc, char **argv, int stdout_fd, BOOL compact, BOOL quiet);
int theme_extra_color(int argc, char **argv, int stdout_fd, BOOL compact, BOOL quiet);

#endif /* ThemeOffloadExtras_h */
