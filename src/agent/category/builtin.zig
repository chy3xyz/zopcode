const provider = @import("../../provider/root.zig");
const types = @import("types.zig");

const quick_fallbacks = [_]provider.ModelRef{
    .{ .provider_id = "anthropic", .model_id = "claude-sonnet-4-5" },
};

const deep_fallbacks = [_]provider.ModelRef{
    .{ .provider_id = "anthropic", .model_id = "claude-sonnet-4-5" },
};

const visual_fallbacks = [_]provider.ModelRef{
    .{ .provider_id = "anthropic", .model_id = "claude-sonnet-4-5" },
};

const ultrabrain_fallbacks = [_]provider.ModelRef{
    .{ .provider_id = "anthropic", .model_id = "claude-sonnet-4-5" },
};

const defaults = [_]types.CategoryPolicy{
    .{
        .id = .quick,
        .description = "Low-latency or low-cost task routing",
        .preferred_model = .{ .provider_id = "anthropic", .model_id = "claude-haiku-4-5" },
        .variant = "fast",
        .prompt_append = "Optimize for speed and keep the response concise.",
        .fallback_chain = quick_fallbacks[0..],
    },
    .{
        .id = .deep,
        .description = "Higher-analysis task routing",
        .preferred_model = .{ .provider_id = "anthropic", .model_id = "claude-sonnet-4-5" },
        .variant = "deep",
        .prompt_append = "Prefer deeper analysis and make tradeoffs explicit.",
        .fallback_chain = deep_fallbacks[0..],
    },
    .{
        .id = .visual,
        .description = "UI and multimodal-oriented task routing",
        .preferred_model = .{ .provider_id = "openai", .model_id = "gpt-5" },
        .variant = "vision",
        .prompt_append = "Pay attention to visual detail, interface behavior, and presentation quality.",
        .fallback_chain = visual_fallbacks[0..],
    },
    .{
        .id = .ultrabrain,
        .description = "Strongest-reasoning task routing",
        .preferred_model = .{ .provider_id = "openai", .model_id = "gpt-5" },
        .variant = "xhigh",
        .prompt_append = "Maximize reasoning depth, surface assumptions, and verify hard constraints.",
        .fallback_chain = ultrabrain_fallbacks[0..],
    },
};

pub fn all() []const types.CategoryPolicy {
    return defaults[0..];
}
