const std = @import("std");
const constants = @import("./consants.zig");

const Suspense = @import("./Suspense.zig");

const Allocator = std.mem.Allocator;
const AnyReader = std.io.AnyReader;

const expect = std.testing.expect;

pub fn Ymlz(comptime Destination: type) type {
    const Value = union(enum) {
        Simple: []const u8,
        KV: struct { key: []const u8, value: []const u8 },
    };

    const Expression = struct {
        value: Value,
        raw: []const u8,
    };

    return struct {
        allocator: Allocator,
        reader: ?AnyReader,
        allocations: std.ArrayList([]const u8),
        suspense: Suspense,

        const Self = @This();

        const InternalRawContenxt = struct { current_index: usize = 0, buf: []const u8 };

        pub fn init(allocator: Allocator) !Self {
            return .{
                .allocator = allocator,
                .reader = null,
                .allocations = std.ArrayList([]const u8).init(allocator),
                .suspense = Suspense.init(allocator),
            };
        }

        pub fn deinit(self: *Self, st: anytype) void {
            defer self.allocations.deinit();

            for (self.allocations.items) |allocation| {
                self.allocator.free(allocation);
            }

            self.deinitRecursively(st, 0);

            self.suspense.deinit();
        }

        /// Uses absolute path for the yml file path. Can be used in conjunction
        /// such as `std.fs.cwd()` in order to create relative paths.
        /// See Github README for example.
        pub fn loadFile(self: *Self, yml_path: []const u8) !Destination {
            const file = try std.fs.openFileAbsolute(yml_path, .{ .mode = .read_only });
            defer file.close();
            const file_reader = file.reader();
            const any_reader: std.io.AnyReader = .{ .context = &file_reader.context, .readFn = fileRead };
            return self.loadReader(any_reader);
        }

        fn fileRead(context: *const anyopaque, buf: []u8) anyerror!usize {
            const file: *std.fs.File = @constCast(@alignCast(@ptrCast(context)));
            return std.fs.File.read(file.*, buf);
        }

        pub fn loadRaw(self: *Self, raw: []const u8) !Destination {
            const context: InternalRawContenxt = .{ .buf = raw };
            const any_reader: std.io.AnyReader = .{ .context = &context, .readFn = rawRead };
            return self.loadReader(any_reader);
        }

        fn rawRead(context: *const anyopaque, buf: []u8) anyerror!usize {
            var internal_raw_context: *InternalRawContenxt = @constCast(@alignCast(@ptrCast(context)));
            const source = internal_raw_context.buf[internal_raw_context.current_index..];
            const len = @min(buf.len, source.len);
            @memcpy(buf[0..len], source[0..len]);
            internal_raw_context.current_index += len;
            return len;
        }

        /// Allows passing a reader which will be used to parse your raw yml bytes.
        pub fn loadReader(self: *Self, reader: AnyReader) !Destination {
            if (@typeInfo(Destination) != .@"struct") {
                @panic("ymlz only able to load yml files into structs");
            }

            self.reader = reader;

            return parse(self, Destination, 0);
        }

        fn deinitRecursively(self: *Self, st: anytype, depth: usize) void {
            const destination_reflaction = @typeInfo(@TypeOf(st));

            if (destination_reflaction == .@"struct") {
                inline for (destination_reflaction.@"struct".fields) |field| {
                    const typeInfo = @typeInfo(field.type);
                    const actualTypeInfo = if (typeInfo == .optional) @typeInfo(typeInfo.optional.child) else typeInfo;

                    switch (actualTypeInfo) {
                        .pointer => {
                            if (actualTypeInfo.pointer.size == .slice and actualTypeInfo.pointer.child != u8) {
                                const child_type_info = @typeInfo(actualTypeInfo.pointer.child);

                                if (actualTypeInfo.pointer.size == .slice and child_type_info == .@"struct") {
                                    const inner = @field(st, field.name);

                                    if (typeInfo == .optional) {
                                        if (inner) |n| {
                                            for (n) |inner_st| {
                                                self.deinitRecursively(inner_st, depth + 1);
                                            }
                                        }
                                    } else {
                                        for (inner) |inner_st| {
                                            self.deinitRecursively(inner_st, depth + 1);
                                        }
                                    }
                                }

                                const container = @field(st, field.name);

                                if (typeInfo == .optional) {
                                    if (container) |c| {
                                        self.allocator.free(c);
                                    }
                                } else {
                                    self.allocator.free(container);
                                }
                            }
                        },
                        .@"struct" => {
                            const inner = @field(st, field.name);
                            self.deinitRecursively(inner, depth + 1);
                        },
                        else => continue,
                    }
                }
            }
        }

        fn isComment(self: *Self, line: []const u8) bool {
            _ = self;

            for (line) |char| {
                if (char == '#') {
                    return true;
                }

                if (char != ' ') {
                    return false;
                }
            }

            return false;
        }

        fn getIndentDepth(self: *Self, depth: usize) usize {
            _ = self;
            return constants.INDENT_SIZE * depth;
        }

        fn printFieldWithIdent(self: *Self, depth: usize, field_name: []const u8, raw_line: []const u8) void {
            _ = self;
            // std.debug.print("printFieldWithIdent:", .{});
            for (0..depth) |_| {
                std.debug.print(" ", .{});
            }

            std.debug.print("{s}\t{s}\n", .{ field_name, raw_line });
        }

        fn getFieldName(self: *Self, raw_line: []const u8, depth: usize) ?[]const u8 {
            const indent = self.getIndentDepth(depth);
            const line = raw_line[indent..];
            var splitted = std.mem.splitSequence(u8, line, ":");
            return splitted.next();
        }

        fn parse(self: *Self, comptime T: type, depth: usize) !T {
            var destination: T = undefined;
            const destination_reflaction = @typeInfo(@TypeOf(destination));
            var totalFieldsParsed: usize = 0;

            // Make sure nullify all optional fields first
            inline for (destination_reflaction.@"struct".fields) |field| {
                if (@typeInfo(field.type) == .optional) {
                    @field(destination, field.name) = null;
                }
            }

            while (totalFieldsParsed < destination_reflaction.@"struct".fields.len) {
                const raw_line = try self.readLine() orelse {
                    break;
                };

                const field_name = self.getFieldName(raw_line, depth) orelse {
                    @panic(("Failed to get field name from yml file."));
                };

                var is_field_parsed = false;

                inline for (destination_reflaction.@"struct".fields, 0..) |field, index| {
                    const type_info = @typeInfo(field.type);
                    const is_optional_field = type_info == .optional;

                    if (std.mem.eql(u8, field.name, field_name)) {
                        const actual_type_info = if (is_optional_field) @typeInfo(type_info.optional.child) else type_info;

                        try self.parseField(
                            actual_type_info,
                            &destination,
                            field,
                            raw_line,
                            depth,
                        );

                        is_field_parsed = true;
                    }

                    if (index == destination_reflaction.@"struct".fields.len - 1 and !is_field_parsed and is_optional_field) {
                        is_field_parsed = true;
                        try self.suspense.set(raw_line);
                    }
                }

                if (!is_field_parsed) {
                    @panic("No such field in given yml file.");
                } else {
                    totalFieldsParsed += 1;
                }
            }

            return destination;
        }

        inline fn parseField(
            self: *Self,
            actual_type_info: std.builtin.Type,
            destination: anytype,
            field: std.builtin.Type.StructField,
            raw_line: []const u8,
            depth: usize,
        ) !void {
            switch (actual_type_info) {
                .bool => {
                    @field(destination, field.name) = try self.parseBooleanExpression(raw_line, depth);
                },
                .int => {
                    @field(destination, field.name) = try self.parseNumericExpression(field.type, raw_line, depth);
                },
                .float => {
                    @field(destination, field.name) = try self.parseNumericExpression(field.type, raw_line, depth);
                },
                .pointer => {
                    if (actual_type_info.pointer.size == .slice and actual_type_info.pointer.child == u8) {
                        @field(destination, field.name) = try self.parseStringExpression(raw_line, depth, false);
                    } else if (actual_type_info.pointer.size == .slice and (actual_type_info.pointer.child == []const u8 or actual_type_info.pointer.child == []u8)) {
                        @field(destination, field.name) = try self.parseStringArrayExpression(actual_type_info.pointer.child, depth + 1);
                    } else if (actual_type_info.pointer.size == .slice and @typeInfo(actual_type_info.pointer.child) != .pointer) {
                        @field(destination, field.name) = try self.parseArrayExpression(actual_type_info.pointer.child, depth + 1);
                    } else {
                        @panic("unexpected pointer type recieved - " ++ @typeName(field.type) ++ "\n");
                    }
                },
                .@"struct" => {
                    const child_type = if (@typeInfo(field.type) == .optional)
                        @typeInfo(field.type).optional.child
                    else
                        field.type;
                    @field(destination, field.name) = try self.parse(child_type, depth + 1);
                },
                else => {
                    @panic("unexpected type recieved - " ++ @typeName(field.type) ++ "\n");
                },
            }
        }

        fn isOptionalFieldExists(self: *Self, lookup_key: []const u8, raw_line: []const u8, depth: usize) !bool {
            const indent_depth = self.getIndentDepth(depth);
            var split_iterator = std.mem.splitSequence(u8, raw_line[indent_depth..], ":");
            const key = split_iterator.next() orelse return false;
            return std.mem.eql(u8, key, lookup_key);
        }

        fn ignoreComment(self: *Self, line: []const u8) []const u8 {
            _ = self;

            var comment_index: usize = 0;

            for (line, 0..line.len) |c, i| {
                if (c == '#') {
                    comment_index = i;
                    break;
                }
            }

            if (comment_index == 0) {
                return line;
            }

            for (1..comment_index) |i| {
                const from_end = comment_index - i;

                if (line[from_end] != ' ') {
                    return line[0 .. from_end + 1];
                }
            }

            return line;
        }

        fn readRawLine(self: *Self) !?[]const u8 {
            if (self.suspense.get()) |s| {
                return s;
            }

            const reader = self.reader orelse return error.NoFileFound;
            const raw_line = try reader.readUntilDelimiterOrEofAlloc(
                self.allocator,
                '\n',
                constants.MAX_READ_SIZE,
            );

            if (raw_line) |line| {
                try self.allocations.append(line);
                return line;
            }

            return null;
        }

        fn readLine(self: *Self) !?[]const u8 {
            const raw_line = try self.readRawLine();

            if (raw_line) |line| {
                // TODO: What shoud really happen if a file has '---' which means a new document in the same file.
                if (self.isComment(line) or std.mem.eql(u8, "---", line)) {
                    // Skipping comments
                    return self.readLine();
                }

                return self.ignoreComment(line);
            }

            return null;
        }

        fn isArrayEntryOnlyChar(raw_line: []const u8) bool {
            // Trim whitespace to see if this is only the array start char
            var trimmed_line = std.mem.trimLeft(u8, raw_line, " ");
            trimmed_line = std.mem.trimRight(u8, trimmed_line, " ");
            return std.mem.eql(u8, trimmed_line, "-");
        }

        fn isNewExpression(self: *Self, raw_value_line: []const u8, depth: usize) bool {
            if (raw_value_line.len == 0) {
                return false;
            }

            const indent_depth = self.getIndentDepth(depth);

            for (0..indent_depth) |d| {
                if (raw_value_line[d] != ' ') {
                    return true;
                }
            }

            return false;
        }

        fn parseStringArrayExpression(self: *Self, comptime T: type, depth: usize) ![]T {
            var list = std.ArrayList(T).init(self.allocator);
            defer list.deinit();

            while (true) {
                const raw_value_line = try self.readLine() orelse break;

                if (self.isNewExpression(raw_value_line, depth)) {
                    try self.suspense.set(raw_value_line);
                    break;
                }

                const result = try self.parseStringExpression(raw_value_line, depth, false);

                try list.append(result);
            }

            return try list.toOwnedSlice();
        }

        fn parseArrayExpression(self: *Self, comptime T: type, depth: usize) ![]T {
            var list = std.ArrayList(T).init(self.allocator);
            defer list.deinit();

            while (true) {
                const raw_value_line = try self.readLine() orelse break;

                // If this is only the array entry char '-', just eat this line
                if (isArrayEntryOnlyChar(raw_value_line)) {
                    continue;
                }

                try self.suspense.set(raw_value_line);

                if (self.isNewExpression(raw_value_line, depth)) {
                    break;
                }

                const result = try self.parse(T, depth + 1);

                try list.append(result);
            }

            return try list.toOwnedSlice();
        }

        fn parseStringExpression(self: *Self, raw_line: []const u8, depth: usize, is_multiline: bool) ![]const u8 {
            const expression = try self.parseSimpleExpression(raw_line, depth, is_multiline);
            const value = self.getExpressionValueWithTrim(expression);

            if (value.len == 0) return value;

            switch (value[0]) {
                '|' => {
                    return self.parseMultilineString(depth + 1, true);
                },
                '>' => {
                    return self.parseMultilineString(depth + 1, false);
                },
                else => return value,
            }
        }

        fn parseMultilineString(self: *Self, depth: usize, preserve_new_line: bool) ![]const u8 {
            var list = std.ArrayList(u8).init(self.allocator);
            defer list.deinit();

            while (true) {
                const raw_value_line = try self.readRawLine() orelse break;

                if (self.isNewExpression(raw_value_line, depth)) {
                    try self.suspense.set(raw_value_line);
                    if (preserve_new_line)
                        _ = list.pop();
                    break;
                }

                const expression = try self.parseSimpleExpression(raw_value_line, depth, true);
                const value = self.getExpressionValue(expression);

                try list.appendSlice(value);

                if (preserve_new_line)
                    try list.append('\n');
            }

            const str = try list.toOwnedSlice();

            try self.allocations.append(str);

            return str;
        }

        fn getExpressionValueWithTrim(self: *Self, expression: Expression) []const u8 {
            return std.mem.trim(u8, self.getExpressionValue(expression), " ");
        }

        fn getExpressionValue(self: *Self, expression: Expression) []const u8 {
            _ = self;

            switch (expression.value) {
                .Simple => return expression.value.Simple,
                .KV => return expression.value.KV.value,
            }
        }

        fn parseBooleanExpression(self: *Self, raw_line: []const u8, depth: usize) !bool {
            const expression = try self.parseSimpleExpression(raw_line, depth, false);
            const value = self.getExpressionValueWithTrim(expression);

            const isBooleanTrue = std.mem.eql(u8, value, "True") or std.mem.eql(u8, value, "true") or std.mem.eql(u8, value, "On") or std.mem.eql(u8, value, "on");

            if (isBooleanTrue) {
                return true;
            }

            const isBooleanFalse = std.mem.eql(u8, value, "False") or std.mem.eql(u8, value, "false") or std.mem.eql(u8, value, "Off") or std.mem.eql(u8, value, "off");

            if (isBooleanFalse) {
                return false;
            }

            return error.NotBoolean;
        }

        fn parseNumericExpression(self: *Self, comptime T: type, raw_line: []const u8, depth: usize) !T {
            const expression = try self.parseSimpleExpression(raw_line, depth, false);
            const value = self.getExpressionValueWithTrim(expression);

            switch (@typeInfo(T)) {
                .int => {
                    return std.fmt.parseInt(T, value, 10);
                },
                .float => {
                    return std.fmt.parseFloat(T, value);
                },
                else => {
                    return error.UnrecognizedSimpleType;
                },
            }
        }

        fn withoutQuotes(self: *Self, line: []const u8) []const u8 {
            _ = self;

            if ((line[0] == '\'' or line[0] == '"') and (line[line.len - 1] == '\'' or line[line.len - 1] == '"')) {
                return line[1 .. line.len - 1];
            }

            return line;
        }

        fn parseSimpleExpression(self: *Self, raw_line: []const u8, depth: usize, is_multiline: bool) !Expression {
            const indent_depth = self.getIndentDepth(depth);

            if (raw_line.len < indent_depth) {
                return .{
                    .value = .{ .Simple = raw_line },
                    .raw = raw_line,
                };
            }

            // NOTE: Need to think about this a bit more, maybe there is a cleaner solution for this.
            if (is_multiline) {
                return .{
                    .value = .{ .Simple = raw_line[indent_depth..] },
                    .raw = raw_line,
                };
            }

            const line = raw_line[indent_depth..];

            if (line[0] == '-') {
                return .{
                    .value = .{ .Simple = self.withoutQuotes(line[2..]) },
                    .raw = raw_line,
                };
            }

            var tokens_iterator = std.mem.splitSequence(u8, line, ": ");

            const key = tokens_iterator.next() orelse return error.KeyNotFound;

            const value = tokens_iterator.next() orelse {
                return .{
                    .value = .{ .Simple = self.withoutQuotes(line) },
                    .raw = raw_line,
                };
            };

            return .{
                .value = .{ .KV = .{ .key = key, .value = self.withoutQuotes(value) } },
                .raw = raw_line,
            };
        }
    };
}

test {
    _ = Suspense;
    _ = @import("tests.zig");
}

test "should be able to parse simple types" {
    const Subject = struct {
        first: i32,
        second: i64,
        name: []const u8,
        fourth: f32,
    };

    const yml_file_location = try std.fs.cwd().realpathAlloc(
        std.testing.allocator,
        "./resources/super_simple.yml",
    );
    defer std.testing.allocator.free(yml_file_location);

    var ymlz = try Ymlz(Subject).init(std.testing.allocator);
    const result = try ymlz.loadFile(yml_file_location);
    defer ymlz.deinit(result);

    try expect(result.first == 500);
    try expect(result.second == -3);
    try expect(std.mem.eql(u8, result.name, "just testing strings overhere"));
    try expect(result.fourth == 142.241);
}

test "should be able to parse array types" {
    const Subject = struct {
        first: i32,
        second: i64,
        name: []const u8,
        fourth: f32,
        foods: [][]const u8,
    };

    const yml_file_location = try std.fs.cwd().realpathAlloc(
        std.testing.allocator,
        "./resources/super_simple.yml",
    );
    defer std.testing.allocator.free(yml_file_location);

    var ymlz = try Ymlz(Subject).init(std.testing.allocator);
    const result = try ymlz.loadFile(yml_file_location);
    defer ymlz.deinit(result);

    try expect(result.foods.len == 4);
    try expect(std.mem.eql(u8, result.foods[0], "Apple"));
    try expect(std.mem.eql(u8, result.foods[1], "Orange"));
    try expect(std.mem.eql(u8, result.foods[2], "Strawberry"));
    try expect(std.mem.eql(u8, result.foods[3], "Mango"));
}

test "should be able to parse deeps/recursive structs" {
    const Subject = struct {
        first: i32,
        second: i64,
        name: []const u8,
        fourth: f32,
        foods: [][]const u8,
        inner: struct {
            sd: i32,
            k: u8,
            l: []const u8,
            another: struct {
                new: f32,
                stringed: []const u8,
            },
        },
    };

    const yml_file_location = try std.fs.cwd().realpathAlloc(
        std.testing.allocator,
        "./resources/super_simple.yml",
    );
    defer std.testing.allocator.free(yml_file_location);

    var ymlz = try Ymlz(Subject).init(std.testing.allocator);
    const result = try ymlz.loadFile(yml_file_location);
    defer ymlz.deinit(result);

    try expect(result.inner.sd == 12);
    try expect(result.inner.k == 2);
    try expect(std.mem.eql(u8, result.inner.l, "hello world"));
    try expect(result.inner.another.new == 1);
    try expect(std.mem.eql(u8, result.inner.another.stringed, "its just a string"));
}

test "should be able to parse booleans in all its forms" {
    const Subject = struct {
        first: bool,
        second: bool,
        third: bool,
        fourth: bool,
        fifth: bool,
        sixth: bool,
        seventh: bool,
        eighth: bool,
    };

    const yml_file_location = try std.fs.cwd().realpathAlloc(
        std.testing.allocator,
        "./resources/booleans.yml",
    );
    defer std.testing.allocator.free(yml_file_location);

    var ymlz = try Ymlz(Subject).init(std.testing.allocator);
    const result = try ymlz.loadFile(yml_file_location);
    defer ymlz.deinit(result);

    try expect(result.first == true);
    try expect(result.second == false);
    try expect(result.third == true);
    try expect(result.fourth == false);
    try expect(result.fifth == true);
    try expect(result.sixth == true);
    try expect(result.seventh == false);
    try expect(result.eighth == false);
}

test "should be able to parse multiline" {
    const Subject = struct {
        multiline: []const u8,
        second_multiline: []const u8,
    };

    const yml_file_location = try std.fs.cwd().realpathAlloc(
        std.testing.allocator,
        "./resources/multilines.yml",
    );
    defer std.testing.allocator.free(yml_file_location);

    var ymlz = try Ymlz(Subject).init(std.testing.allocator);
    const result = try ymlz.loadFile(yml_file_location);
    defer ymlz.deinit(result);

    try expect(std.mem.containsAtLeast(u8, result.multiline, 1, "asdoksad\n"));
    try expect(std.mem.containsAtLeast(u8, result.multiline, 1, "sdapdsadp\n"));
    try expect(std.mem.containsAtLeast(u8, result.multiline, 1, "sodksaodasd\n"));
    try expect(std.mem.containsAtLeast(u8, result.multiline, 1, "sdksdsodsokdsokd"));

    try expect(std.mem.eql(u8, result.second_multiline, "adsasdasdad  sdasadasdadasd"));
}

test "should be able to ignore single quotes and double quotes" {
    const Experiment = struct {
        one: []const u8,
        second: []const u8,
        three: []const u8,
    };

    const yml_file_location = try std.fs.cwd().realpathAlloc(
        std.testing.allocator,
        "./resources/quotes.yml",
    );
    defer std.testing.allocator.free(yml_file_location);

    var ymlz = try Ymlz(Experiment).init(std.testing.allocator);
    const result = try ymlz.loadFile(yml_file_location);
    defer ymlz.deinit(result);

    try expect(std.mem.containsAtLeast(u8, result.one, 1, "testing without quotes"));
    try expect(std.mem.containsAtLeast(u8, result.second, 1, "trying to see if it will break"));
    try expect(std.mem.containsAtLeast(u8, result.three, 1, "hello world"));
}

test "should be able to parse arrays of T" {
    const Tutorial = struct {
        name: []const u8,
        type: []const u8,
        born: u64,
    };

    const Experiment = struct {
        name: []const u8,
        job: []const u8,
        skill: []const u8,
        employed: bool,
        foods: [][]const u8,
        languages: struct {
            perl: []const u8,
            python: []const u8,
            pascal: []const u8,
        },
        education: []const u8,
        tutorial: []Tutorial,
    };

    const yml_file_location = try std.fs.cwd().realpathAlloc(
        std.testing.allocator,
        "./resources/tutorial.yml",
    );
    defer std.testing.allocator.free(yml_file_location);

    var ymlz = try Ymlz(Experiment).init(std.testing.allocator);
    const result = try ymlz.loadFile(yml_file_location);
    defer ymlz.deinit(result);

    try expect(std.mem.eql(u8, result.name, "Martin D'vloper"));
    try expect(std.mem.eql(u8, result.job, "Developer"));
    try expect(std.mem.eql(u8, result.foods[0], "Apple"));
    try expect(std.mem.eql(u8, result.foods[3], "Mango"));

    try expect(std.mem.eql(u8, result.tutorial[0].name, "YAML Ain't Markup Language"));
    try expect(std.mem.eql(u8, result.tutorial[0].type, "awesome"));
    try expect(result.tutorial[0].born == 2001);

    try expect(std.mem.eql(u8, result.tutorial[1].name, "JavaScript Object Notation"));
    try expect(std.mem.eql(u8, result.tutorial[1].type, "great"));
    try expect(result.tutorial[1].born == 2001);

    try expect(std.mem.eql(u8, result.tutorial[2].name, "Extensible Markup Language"));
    try expect(std.mem.eql(u8, result.tutorial[2].type, "good"));
    try expect(result.tutorial[2].born == 1996);
}

test "should be able to parse arrays and arrays in arrays" {
    const ImageSamplerPairs = struct {
        slot: u32,
        name: []const u8,
        image_name: []const u8,
        sampler_name: []const u8,
    };

    const Sampler = struct {
        slot: u32,
        name: []const u8,
        sampler_type: []const u8,
    };

    const Image = struct {
        slot: u64,
        name: []const u8,
        multisampled: bool,
        type: []const u8,
        sample_type: []const u8,
    };

    const Uniform = struct {
        name: []const u8,
        type: []const u8,
        array_count: i32,
        offset: usize,
    };

    const UniformBlock = struct {
        slot: u64,
        size: u64,
        struct_name: []const u8,
        inst_name: []const u8,
        uniforms: []Uniform,
    };

    const Input = struct {
        slot: u64,
        name: []const u8,
        sem_name: []const u8,
        sem_index: usize,
    };

    const Details = struct {
        path: []const u8,
        is_binary: bool,
        entry_point: []const u8,
        inputs: []Input,
        outputs: []Input,
        uniform_blocks: []UniformBlock,
        images: ?[]Image,
        samplers: ?[]Sampler,
        image_sampler_pairs: ?[]ImageSamplerPairs,
    };

    const Program = struct {
        name: []const u8,
        vs: Details,
        fs: Details,
    };

    const Shader = struct {
        slang: []const u8,
        programs: []Program,
    };

    const Experiment = struct {
        shaders: []Shader,
    };

    const yml_path = try std.fs.cwd().realpathAlloc(
        std.testing.allocator,
        "./resources/shader.yml",
    );
    defer std.testing.allocator.free(yml_path);

    var ymlz = try Ymlz(Experiment).init(std.testing.allocator);
    const result = try ymlz.loadFile(yml_path);
    defer ymlz.deinit(result);

    try expect(std.mem.eql(u8, result.shaders[0].programs[0].fs.uniform_blocks[0].uniforms[0].name, "u_color_override"));
    try expect(std.mem.eql(u8, result.shaders[0].slang, "glsl430"));
    try expect(result.shaders[0].programs[0].vs.images == null);
    try expect(result.shaders[0].programs[0].fs.images != null);
    try expect(result.shaders[0].programs[0].fs.images.?[0].slot == 0);
    try expect(std.mem.eql(u8, result.shaders[0].programs[0].fs.images.?[0].sample_type, "float"));
    try expect(std.mem.eql(u8, result.shaders[6].slang, "wgsl"));
    try expect(std.mem.eql(u8, result.shaders[6].programs[0].name, "default"));
    try expect(result.shaders[6].programs[0].vs.image_sampler_pairs == null);
    try expect(result.shaders[6].programs[0].fs.image_sampler_pairs.?[0].slot == 0);
    try expect(result.shaders[6].programs[0].fs.image_sampler_pairs != null);
    try expect(std.mem.eql(u8, result.shaders[6].programs[0].fs.image_sampler_pairs.?[0].sampler_name, "smp"));
}

test "should be able to to skip optional fields if non-existent in the parsed file" {
    const Subject = struct {
        first: i32,
        second: ?i64,
        name: []const u8,
        fourth: f32,
        foods: ?[][]const u8,
        more_foods: ?[][]const u8,
        inner: struct {
            abcd: i32,
            k: u32,
            l: []const u8,
            another: struct {
                new: i8,
                stringed: []const u8,
            },
        },
    };

    const yml_file_location = try std.fs.cwd().realpathAlloc(
        std.testing.allocator,
        "./resources/super_simple_with_optional.yml",
    );
    defer std.testing.allocator.free(yml_file_location);

    var ymlz = try Ymlz(Subject).init(std.testing.allocator);
    const result = try ymlz.loadFile(yml_file_location);
    defer ymlz.deinit(result);

    try expect(result.first == 500);
    try expect(result.second == null);
    try expect(std.mem.eql(u8, result.name, "just testing strings overhere"));
    try expect(result.fourth == 142.241);

    const foods = result.foods.?;
    try expect(foods.len == 4);
    try expect(std.mem.eql(u8, foods[0], "Apple"));
    try expect(std.mem.eql(u8, foods[1], "Orange"));
    try expect(std.mem.eql(u8, foods[2], "Strawberry"));
    try expect(std.mem.eql(u8, foods[3], "Mango"));

    try expect(result.more_foods == null);

    try expect(result.inner.abcd == 12);
    try expect(std.mem.eql(u8, result.inner.another.stringed, "its just a string"));
}
