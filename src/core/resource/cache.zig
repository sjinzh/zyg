const Resources = @import("manager.zig").Manager;
const Variants = @import("base").memory.VariantMap;

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Null = 0xFFFFFFFF;

pub fn Cache(comptime T: type, comptime P: type) type {
    const Key = struct {
        name: []const u8,
        options: Variants,

        const Self = @This();

        pub fn clone(self: Self, alloc: *Allocator) !Self {
            var tmp_name = try alloc.alloc(u8, self.name.len);
            std.mem.copy(u8, tmp_name, self.name);
            return Self{ .name = tmp_name, .options = try self.options.clone(alloc) };
        }

        pub fn deinit(self: *Self, alloc: *Allocator) void {
            self.options.deinit(alloc);
            alloc.free(self.name);
        }
    };

    const KeyContext = struct {
        const Self = @This();

        pub fn hash(self: Self, k: Key) u64 {
            _ = self;
            var hasher = std.hash.Wyhash.init(0);

            hasher.update(k.name);

            var iter = k.options.map.iterator();
            while (iter.next()) |entry| {
                hasher.update(entry.key_ptr.*);
                hasher.update(std.mem.asBytes(entry.value_ptr));
            }

            const h = hasher.final();

            return h;
        }

        pub fn eql(self: Self, a: Key, b: Key) bool {
            _ = self;

            if (!std.mem.eql(u8, a.name, b.name)) {
                return false;
            }

            if (a.options.map.count() != b.options.map.count()) {
                return false;
            }

            var a_iter = a.options.map.iterator();
            var b_iter = b.options.map.iterator();
            while (a_iter.next()) |a_entry| {
                if (b_iter.next()) |b_entry| {
                    if (!std.mem.eql(u8, a_entry.key_ptr.*, b_entry.key_ptr.*)) {
                        return false;
                    }

                    if (!std.mem.eql(
                        u8,
                        std.mem.asBytes(a_entry.value_ptr),
                        std.mem.asBytes(b_entry.value_ptr),
                    )) {
                        return false;
                    }
                } else {
                    return false;
                }
            }

            return true;
        }
    };

    const HashMap = std.HashMapUnmanaged(Key, u32, KeyContext, 80);

    return struct {
        provider: P,
        resources: std.ArrayListUnmanaged(T) = .{},
        entries: HashMap = .{},

        const Self = @This();

        pub fn init(provider: P) Self {
            return .{ .provider = provider };
        }

        pub fn deinit(self: *Self, alloc: *Allocator) void {
            var iter = self.entries.iterator();
            while (iter.next()) |entry| {
                entry.key_ptr.deinit(alloc);
            }

            self.entries.deinit(alloc);

            for (self.resources.items) |*r| {
                r.deinit(alloc);
            }

            self.resources.deinit(alloc);

            self.provider.deinit(alloc);
        }

        pub fn loadFile(
            self: *Self,
            alloc: *Allocator,
            name: []const u8,
            options: Variants,
            resources: *Resources,
        ) !u32 {
            const key = Key{ .name = name, .options = options };
            if (self.entries.get(key)) |entry| {
                return entry;
            }

            const item = self.provider.loadFile(alloc, name, options, resources) catch |e| {
                std.debug.print("Cannot load file \"{s}\": {}\n", .{ name, e });
                return e;
            };

            try self.resources.append(alloc, item);

            const id = @intCast(u32, self.resources.items.len - 1);

            try self.entries.put(alloc, try key.clone(alloc), id);

            return id;
        }

        pub fn loadData(
            self: *Self,
            alloc: *Allocator,
            name: []const u8,
            data: usize,
            options: Variants,
            resources: *Resources,
        ) !u32 {
            const item = try self.provider.loadData(alloc, data, options, resources);

            var id: u32 = Null;

            const key = Key{ .name = name, .options = options };
            if (self.entries.get(key)) |entry| {
                id = entry;
            }

            if (Null == id) {
                try self.resources.append(alloc, item);

                id = @intCast(u32, self.resources.items.len - 1);
            } else {
                self.resources.items[id] = item;
            }

            if (0 != name.len) {
                try self.entries.put(alloc, try key.clone(alloc), id);
            }

            return id;
        }

        pub fn get(self: Self, id: u32) ?*T {
            if (id < self.resources.items.len) {
                return &self.resources.items[id];
            }

            return null;
        }

        pub fn getByName(self: Self, name: []const u8, options: Variants) ?u32 {
            const key = Key{ .name = name, .options = options };
            if (self.entries.get(key)) |entry| {
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
