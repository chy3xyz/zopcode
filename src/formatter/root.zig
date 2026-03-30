const std = @import("std");

pub const MODULE_NAME = "formatter";

pub const runtime = @import("runtime.zig");

pub const FormatterRuntime = runtime.FormatterRuntime;
pub const FormatterInfo = runtime.FormatterInfo;
pub const FormatResult = runtime.FormatResult;
pub const FormatterRuntimeDependencies = runtime.Dependencies;
pub const FormatterExecutor = runtime.CommandExecutor;

test "formatter module exports are available" {
    try std.testing.expectEqualStrings("formatter", MODULE_NAME);
}
