const Resources = @import("manager.zig").Manager;

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Null = 0xFFFFFFFF;

pub fn Cache(comptime T: type, comptime P: type) type {
    return struct {
        provider: P,
        resources: std.ArrayListUnmanaged(T) = .{},
        entries: std.StringHashMap(u32),

        const Self = @This();

        pub fn init(alloc: *Allocator, provider: P) Self {
            return .{
                .provider = provider,
                .entries = std.StringHashMap(u32).init(alloc),
            };
        }

        pub fn deinit(self: *Self, alloc: *Allocator) void {
            self.entries.deinit();

            for (self.resources.items) |*r| {
                r.deinit(alloc);
            }

            self.resources.deinit(alloc);

            self.provider.deinit(alloc);
        }

        pub fn loadFile(self: *Self, alloc: *Allocator, name: []const u8, resources: *Resources) !u32 {
            if (self.entries.get(name)) |entry| {
                return entry;
            }

            const item = try self.provider.loadFile(alloc, name, resources);

            try self.resources.append(alloc, item);

            const id = @intCast(u32, self.resources.items.len - 1);

            try self.entries.put(name, id);

            return id;
        }

        pub fn loadData(
            self: *Self,
            alloc: *Allocator,
            name: []const u8,
            data: usize,
            resources: *Resources,
        ) !u32 {
            const item = try self.provider.loadData(alloc, data, resources);

            var id: u32 = Null;
            if (self.entries.get(name)) |entry| {
                id = entry;
            }

            if (Null == id) {
                try self.resources.append(alloc, item);

                id = @intCast(u32, self.resources.items.len - 1);
            } else {
                self.resources.items[id] = item;
            }

            if (0 != name.len) {
                try self.entries.put(name, id);
            }

            return id;
        }

        pub fn get(self: Self, id: u32) ?*T {
            if (id < self.resources.items.len) {
                return &self.resources.items[id];
            }

            return null;
        }

        pub fn getByName(self: Self, name: []const u8) ?u32 {
            if (self.entries.get(name)) |entry| {
                return entry;
            }

            return null;
        }

        pub fn store(self: *Self, alloc: *Allocator, item: T) u32 {
            self.resources.append(alloc, item) catch {
                return Null;
            };

            return @intCast(u32, self.resources.items.len - 1);
        }
    };
}
