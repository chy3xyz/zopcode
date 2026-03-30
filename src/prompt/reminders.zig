const std = @import("std");

pub fn reminderForProfile(profile_id: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, profile_id, "plan")) return plan_reminder;
    if (std.mem.eql(u8, profile_id, "explore")) return explore_reminder;
    if (std.mem.eql(u8, profile_id, "oracle")) return oracle_reminder;
    return build_reminder;
}

const build_reminder =
    \\Execute only the work needed for the current implementation goal.
;

const plan_reminder =
    \\Planning reminder:
    \\Read before writing.
    \\Do not jump into implementation until the plan is coherent and the main risks are explicit.
;

const explore_reminder =
    \\Exploration reminder:
    \\Stay read-heavy, gather context first, and avoid speculative edits while investigating.
;

const oracle_reminder =
    \\Oracle reminder:
    \\Only emit the verification success signal when the task is truly complete.
    \\If the result is incomplete, explain what remains without approving it.
;
