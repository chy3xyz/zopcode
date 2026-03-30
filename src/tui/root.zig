const std = @import("std");

pub const MODULE_NAME = "tui";

pub const model = @import("model.zig");
pub const render = @import("render.zig");
pub const terminal = @import("terminal.zig");

pub const TerminalViewModel = model.TerminalViewModel;
pub const TerminalApp = terminal.TerminalApp;
pub const TerminalOptions = terminal.TerminalOptions;
pub const runLocal = terminal.runLocal;
pub const runAttached = terminal.runAttached;

pub const ModuleStage = enum {
    mvp,
};

pub const MODULE_STAGE: ModuleStage = .mvp;

test "tui scaffold exports are stable" {
    var vm = try model.TerminalViewModel.init(std.testing.allocator, 1);
    defer vm.deinit();
    try std.testing.expectEqualStrings("tui", MODULE_NAME);
    try std.testing.expectEqualStrings("idle", vm.status);
}
