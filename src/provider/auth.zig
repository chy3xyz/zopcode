const std = @import("std");
const framework = @import("framework");

pub fn loadAnthropicApiKey(allocator: std.mem.Allocator) !?[]u8 {
    return std.process.getEnvVarOwned(allocator, "ANTHROPIC_API_KEY") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => err,
    };
}

pub fn loadOpenAIApiKey(allocator: std.mem.Allocator) !?[]u8 {
    return std.process.getEnvVarOwned(allocator, "OPENAI_API_KEY") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => null,
        else => err,
    };
}

pub const ProviderAuthStatus = struct {
    provider_id: []const u8,
    has_api_key: bool,

    pub fn clone(self: ProviderAuthStatus, allocator: std.mem.Allocator) !ProviderAuthStatus {
        return .{
            .provider_id = try allocator.dupe(u8, self.provider_id),
            .has_api_key = self.has_api_key,
        };
    }

    pub fn deinit(self: *ProviderAuthStatus, allocator: std.mem.Allocator) void {
        allocator.free(self.provider_id);
    }
};

const PersistedRecord = struct {
    provider_id: []const u8,
    api_key: []const u8,
};

const PersistedDocument = struct {
    items: []PersistedRecord,
};

pub const ProviderAuthRuntime = struct {
    allocator: std.mem.Allocator,
    logger: ?*framework.Logger,
    store_path: []u8,
    records: std.StringHashMapUnmanaged([]u8) = .empty,
    mutex: std.Thread.Mutex = .{},

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, logger: ?*framework.Logger, store_path: []const u8) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .logger = logger,
            .store_path = try allocator.dupe(u8, store_path),
        };
        errdefer allocator.free(self.store_path);
        try self.load();
        return self;
    }

    pub fn deinit(self: *Self) void {
        var iterator = self.records.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.records.deinit(self.allocator);
        self.allocator.free(self.store_path);
    }

    pub fn setApiKey(self: *Self, provider_id: []const u8, api_key: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.records.getPtr(provider_id)) |existing| {
            self.allocator.free(existing.*);
            existing.* = try self.allocator.dupe(u8, api_key);
        } else {
            try self.records.put(self.allocator, try self.allocator.dupe(u8, provider_id), try self.allocator.dupe(u8, api_key));
        }
        try self.saveLocked();
    }

    pub fn seedApiKeyIfMissing(self: *Self, provider_id: []const u8, api_key: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.records.contains(provider_id)) return;
        try self.records.put(self.allocator, try self.allocator.dupe(u8, provider_id), try self.allocator.dupe(u8, api_key));
        try self.saveLocked();
    }

    pub fn getApiKeyDup(self: *Self, allocator: std.mem.Allocator, provider_id: []const u8) !?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const existing = self.records.get(provider_id) orelse return null;
        return try allocator.dupe(u8, existing);
    }

    pub fn hasApiKey(self: *Self, provider_id: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.records.contains(provider_id);
    }

    pub fn remove(self: *Self, provider_id: []const u8) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.records.fetchRemove(provider_id)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value);
            try self.saveLocked();
            return true;
        }
        return false;
    }

    pub fn list(self: *Self, allocator: std.mem.Allocator) ![]ProviderAuthStatus {
        self.mutex.lock();
        defer self.mutex.unlock();

        var items: std.ArrayListUnmanaged(ProviderAuthStatus) = .empty;
        errdefer {
            for (items.items) |*item| item.deinit(allocator);
            items.deinit(allocator);
        }

        var iterator = self.records.iterator();
        while (iterator.next()) |entry| {
            try items.append(allocator, .{
                .provider_id = try allocator.dupe(u8, entry.key_ptr.*),
                .has_api_key = true,
            });
        }
        return try items.toOwnedSlice(allocator);
    }

    fn load(self: *Self) !void {
        const file = std.fs.cwd().openFile(self.store_path, .{ .mode = .read_only }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer file.close();

        const bytes = try file.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(bytes);
        if (bytes.len == 0) return;

        const parsed = try std.json.parseFromSlice(PersistedDocument, self.allocator, bytes, .{});
        defer parsed.deinit();

        for (parsed.value.items) |item| {
            try self.records.put(self.allocator, try self.allocator.dupe(u8, item.provider_id), try self.allocator.dupe(u8, item.api_key));
        }
    }

    fn saveLocked(self: *Self) !void {
        const parent = std.fs.path.dirname(self.store_path);
        if (parent) |dir_path| try std.fs.cwd().makePath(dir_path);

        var items = try self.allocator.alloc(PersistedRecord, self.records.count());
        defer {
            for (items) |item| {
                self.allocator.free(item.provider_id);
                self.allocator.free(item.api_key);
            }
            self.allocator.free(items);
        }

        var index: usize = 0;
        var iterator = self.records.iterator();
        while (iterator.next()) |entry| : (index += 1) {
            items[index] = .{
                .provider_id = try self.allocator.dupe(u8, entry.key_ptr.*),
                .api_key = try self.allocator.dupe(u8, entry.value_ptr.*),
            };
        }

        var buffer: std.ArrayListUnmanaged(u8) = .empty;
        defer buffer.deinit(self.allocator);
        const writer = buffer.writer(self.allocator);
        try writer.print("{f}", .{std.json.fmt(PersistedDocument{ .items = items }, .{})});

        var file = try std.fs.cwd().createFile(self.store_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(buffer.items);
    }
};

test "missing anthropic api key returns null" {
    const key = try loadAnthropicApiKey(std.testing.allocator);
    defer if (key) |owned| std.testing.allocator.free(owned);
}

test "missing openai api key returns null" {
    const key = try loadOpenAIApiKey(std.testing.allocator);
    defer if (key) |owned| std.testing.allocator.free(owned);
}

test "provider auth runtime persists and removes api keys" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const root_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root_path);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "provider-auth.json" });
    defer std.testing.allocator.free(store_path);

    var runtime = try ProviderAuthRuntime.init(std.testing.allocator, null, store_path);
    defer {
        runtime.deinit();
        std.testing.allocator.destroy(runtime);
    }

    try runtime.setApiKey("anthropic", "secret-key");
    try std.testing.expect(runtime.hasApiKey("anthropic"));

    const loaded = try runtime.getApiKeyDup(std.testing.allocator, "anthropic");
    defer if (loaded) |value| std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("secret-key", loaded.?);

    var reloaded = try ProviderAuthRuntime.init(std.testing.allocator, null, store_path);
    defer {
        reloaded.deinit();
        std.testing.allocator.destroy(reloaded);
    }
    try std.testing.expect(reloaded.hasApiKey("anthropic"));

    try std.testing.expect(try reloaded.remove("anthropic"));
    try std.testing.expect(!reloaded.hasApiKey("anthropic"));
}
