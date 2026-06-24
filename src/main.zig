const std = @import("std");
const zig_nyt_pips = @import("zig_nyt_pips");

const c = @cImport({
    @cDefine("_XOPEN_SOURCE", "700");
    @cInclude("notcurses/notcurses.h");
});

const Coordinate = [2]u8;
const Domino = [2]u8;

const Orientation = enum { right, up, left, down };

const RegionType = enum { sum, equals, notEquals, greater, less, empty };

const UnsetPip: u8 = 7; // Need a constant that's not 0-6 but also unsigned

const Region = struct {
    indices: []Coordinate,
    type: RegionType,
    target: u8 = 0,
};

const NYTFormat = struct {
    printDate: []u8,
    editor: []u8,
    easy: Puzzle,
    medium: Puzzle,
};

const DominoPlace = struct {
    d: Domino,
    c: Coordinate,
    o: Orientation,

    fn secondCoord(self: DominoPlace) Coordinate {
        return switch (self.o) {
            .right => .{ self.c[0], self.c[1] + 1 },
            .left => .{ self.c[0], self.c[1] - 1 },
            .down => .{ self.c[0] + 1, self.c[1] },
            .up => .{ self.c[0] - 1, self.c[1] },
        };
    }

    fn isValid(self: DominoPlace) bool {
        switch (self.o) {
            .right, .down => return true,
            .left => return self.c[1] != 0,
            .up => return self.c[0] != 0,
        }
    }

    fn coords(self: DominoPlace) [2]Coordinate {
        return [2]Coordinate{ self.d, self.secondCoord() };
    }
};

fn coordEql(a: Coordinate, b: Coordinate) bool {
    return a[0] == b[0] and a[1] == b[1];
}

const Puzzle = struct {
    regions: []Region,
    dominoes: []Domino,
    placedDominoes: std.ArrayList(DominoPlace) = std.ArrayList(DominoPlace).empty,

    pub fn init(self: *Puzzle, gpa: std.mem.Allocator) !void {
        try self.placedDominoes.ensureTotalCapacity(gpa, self.dominoes.len);
    }

    pub fn deinit(self: *Puzzle, gpa: std.mem.Allocator) void {
        self.placedDominoes.deinit(gpa);
    }

    pub fn maxXY(self: *Puzzle) [2]usize {
        var maxX: usize = 0;
        var maxY: usize = 0;
        for (self.regions) |region| {
            for (region.indices) |coord| {
                maxX = @max(coord[0], maxX);
                maxY = @max(coord[1], maxY);
            }
        }
        return .{ maxX, maxY };
    }

    pub fn dominoAt(self: *Puzzle, coord: Coordinate) ?DominoPlace {
        for (self.placedDominoes.items) |p| {
            if (std.mem.eql(u8, &p.c, &coord)) return p.d;
        }
        return null;
    }

    pub fn pipAt(self: *Puzzle, coord: Coordinate) ?u8 {
        for (self.placedDominoes.items) |p| {
            if (std.mem.eql(u8, &p.c, &coord)) return p.d[0];
            if (std.mem.eql(u8, &p.c, &p.secondCoord())) return p.d[1];
        }
        return null;
    }

    pub fn sumRegion(self: *Puzzle, region: *const Region) i32 {
        var sum: i32 = 0;
        for (region.indices) |coord| {
            sum += @intCast(self.pipAt(coord) orelse 0);
        }
        return sum;
    }
};

// Can be bumped later
const MAX_DOMINOES = 32;
const MAX_INDICES = 16;

const Solver = struct {
    puzzle: *Puzzle,
    plane: ?*c.ncplane,
    nc: ?*c.notcurses, // If null, no UI
    io: std.Io,
    stats: Stats = .{},
    last_failure: []const u8 = "",
    last_failure_buf: [128]u8 = undefined,
    placedDominoes: [MAX_DOMINOES]DominoPlace = undefined,
    indices: [MAX_INDICES]Coordinate,
    pipCache: [MAX_INDICES]u8 = undefined,

    const Stats = struct {
        waits: usize = 0,
    };

    pub fn init(puzzle: *Puzzle, plane: ?*c.ncplane, nc: ?*c.notcurses, io: std.Io) Solver {
        var indices: [MAX_INDICES]Coordinate = undefined;
        var ic: usize = 0;
        for (puzzle.regions) |region| {
            for (region.indices) |i| {
                indices[ic] = i;
                ic += 1;
            }
        }

        return .{
            .puzzle = puzzle,
            .plane = plane,
            .nc = nc,
            .io = io,
            .indices = indices,
        };
    }

    pub fn solve(self: *Solver, gpa: std.mem.Allocator, index: usize) !bool {
        // TODO move this out of recursion
        var coords = std.ArrayList(Coordinate).empty;
        defer coords.deinit(gpa);
        for (self.puzzle.regions) |region| {
            for (region.indices) |i| {
                try coords.append(gpa, i);
            }
        }

        for (coords.items) |coord| {
            inline for (std.meta.fields(Orientation)) |field| {
                const orientation = @field(Orientation, field.name);
                const dp = DominoPlace{
                    .c = coord,
                    .d = self.puzzle.dominoes[index],
                    .o = orientation,
                };
                if (self.canPlace(dp)) {
                    try self.puzzle.placedDominoes.append(gpa, dp);
                    const validated = self.validate();
                    if (self.nc) |_| {
                        self.draw();
                        _ = c.notcurses_render(self.nc);
                        //_ = self.waitFor(&[_]u32{'e'});
                    } else {
                        std.debug.print("Placed domino {d}:{d} at {d}x{d}, {s}{s}\n", .{
                            dp.d[0],
                            dp.d[1],
                            dp.c[0],
                            dp.c[1],
                            if (validated) "success" else "error: ",
                            self.last_failure,
                        });
                    }

                    if (validated) {
                        _ = self.waitFor(&[_]u32{'e'});
                        return true;
                    }

                    if (index == self.puzzle.dominoes.len - 1) {
                        _ = self.puzzle.placedDominoes.pop();
                        return false;
                    }

                    if (try self.solve(gpa, index + 1)) return true;

                    _ = self.puzzle.placedDominoes.pop();
                }
            }
        }
        return false;
    }

    pub fn waitFor(self: *Solver, allowed: []const u32) u32 {
        var ninput: c.ncinput = undefined;
        while (true) {
            _ = c.notcurses_get_blocking(self.nc, &ninput);
            if (std.mem.findScalar(u32, allowed, ninput.id)) |_| {
                if (ninput.evtype != c.NCTYPE_PRESS) continue;
                self.stats.waits += 1;
                return ninput.id;
            }
        }
    }

    fn errMsg(self: *Solver, comptime fmt: []const u8, args: anytype) void {
        self.last_failure = std.fmt.bufPrint(&self.last_failure_buf, fmt, args) catch "format error";
    }

    fn canPlace(self: *Solver, dp: DominoPlace) bool {
        if (!dp.isValid()) return false;
        for (self.puzzle.placedDominoes.items) |d| {
            if (coordEql(d.c, dp.c) or coordEql(d.secondCoord(), dp.c) or coordEql(d.c, dp.secondCoord()) or coordEql(d.secondCoord(), dp.secondCoord())) return false;
        }
        // maybe just check secondCoord
        var matchedFirst = false;
        var matchedSecond = false;
        for (self.puzzle.regions) |region| {
            for (region.indices) |i| {
                if (coordEql(i, dp.c)) matchedFirst = true;
                if (coordEql(i, dp.secondCoord())) matchedSecond = true;
            }
        }
        if (!(matchedFirst and matchedSecond)) return false;
        return true;
    }

    pub fn validate(self: *Solver) bool {
        // Check invariants first
        for (self.puzzle.regions) |region| {
            switch (region.type) {
                .empty, .greater => {},
                .sum => {
                    const s = self.puzzle.sumRegion(&region);
                    if (s > region.target) {
                        self.errMsg("target ={d} fails, found {d}", .{ region.target, s });
                        return false;
                    }
                },
                .less => {
                    const s = self.puzzle.sumRegion(&region);
                    if (s > region.target) {
                        self.errMsg("target <{d} fails, found {d}", .{ region.target, s });
                        return false;
                    }
                },
                .equals => {
                    var firstFoundPip: u8 = UnsetPip;
                    for (region.indices) |i| {
                        const d = self.puzzle.pipAt(i) orelse continue;
                        if (firstFoundPip == UnsetPip) {
                            firstFoundPip = d;
                        } else if (d != firstFoundPip) {
                            self.errMsg("target = fails, found {d} then {d}", .{ firstFoundPip, d });
                            return false;
                        }
                    }
                },
                .notEquals => {
                    var found: [7]bool = [_]bool{false} ** 7;
                    for (region.indices) |coord| {
                        const value = self.puzzle.pipAt(coord) orelse continue;
                        if (found[@intCast(value)]) {
                            self.errMsg("target != fails, already found {d}\n", .{value});
                            return false;
                        } else {
                            found[@intCast(value)] = true;
                        }
                    }
                },
            }
        }
        self.errMsg("valid but not full", .{});
        return false;
    }

    pub fn drawLegend(self: *const Solver, plane: *c.ncplane) void {
        var bg_palindex: c_uint = 0;
        _ = plane.set_fg_palindex(0);
        for (self.puzzle.regions) |region| {
            if (region.type == .empty) continue;
            bg_palindex += 1;
            const y_index: c_int = @as(c_int, @intCast(bg_palindex));
            _ = plane.set_bg_palindex(bg_palindex);
            _ = plane.putchar_yx(y_index, 2, ' ');
            _ = plane.set_bg_default();
            _ = plane.set_fg_default();
            var buf: [4]u8 = undefined;
            const str = switch (region.type) {
                .empty => "",
                .equals => "=",
                .notEquals => "!=",
                .sum => std.fmt.bufPrintZ(&buf, "={d}", .{region.target}) catch "=format error",
                .greater => std.fmt.bufPrintZ(&buf, ">{d}", .{region.target}) catch ">format error",
                .less => std.fmt.bufPrintZ(&buf, "<{d}", .{region.target}) catch "<format error",
            };
            _ = plane.putstr_yx(y_index, 4, str.ptr);
        }
        _ = plane.cursor_move_yx(0, 0);
        _ = plane.rounded_box(0, 0, bg_palindex + 1, 10, 0);
    }

    pub fn draw(self: *const Solver) void {
        _ = self.nc orelse return;
        const plane = self.plane orelse return;
        var bg_palindex: c_uint = 0;
        _ = plane.set_fg_palindex(0);
        for (self.puzzle.regions) |region| {
            if (region.type == .empty) {
                _ = plane.set_bg_palindex(15);
            } else {
                bg_palindex += 1;
                _ = plane.set_bg_palindex(bg_palindex);
            }
            for (region.indices) |coord| {
                var pip: u8 = ' ';
                for (self.puzzle.placedDominoes.items) |p| {
                    if (std.mem.eql(u8, &p.c, &coord)) {
                        pip = p.d[0] + '0';
                        break;
                    }
                    if (std.mem.eql(u8, &p.secondCoord(), &coord)) {
                        pip = p.d[1] + '0';
                        break;
                    }
                }
                _ = plane.putchar_yx(coord[0], coord[1], pip);
            }
        }
        _ = plane.putstr_yx(10, 10, self.last_failure.ptr);
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args = init.minimal.args.iterate();
    _ = args.next();

    var fh = try std.Io.Dir.cwd().openFile(init.io, args.next().?, .{});
    defer fh.close(init.io);

    var enable_tui = true;
    if (args.next()) |arg| {
        enable_tui = !std.mem.eql(u8, arg, "--batch");
    }

    var buf: [1024]u8 = undefined;
    var freader = fh.reader(init.io, &buf);
    var jallocator = std.heap.ArenaAllocator.init(allocator);
    var scanner = std.json.Scanner.Reader.init(jallocator.allocator(), &freader.interface);
    defer jallocator.deinit();

    var parsed = try std.json.parseFromTokenSource(NYTFormat, allocator, &scanner, .{
        .ignore_unknown_fields = true, // Safeguard against unexpected API fields
    });
    defer parsed.deinit();

    var puzzle = parsed.value.easy;
    try puzzle.init(allocator);
    defer puzzle.deinit(allocator);

    var nc: ?*c.notcurses = null;
    var stdplane: ?*c.ncplane = null;
    if (enable_tui) {
        nc = c.notcurses_init(null, null) orelse return error.UnexpectedError;

        stdplane = nc.?.notcurses_stdplane() orelse return error.UnexpectedError;
    }

    var solver = Solver.init(&puzzle, stdplane, nc, init.io);
    _ = try solver.solve(allocator, 0);
    //solver.draw();
    // const legendOpts = c.ncplane_options{
    //     .y = 0,
    //     .x = 8,
    //     .rows = 16,
    //     .cols = 16,
    //     .userptr = null,
    //     .name = "legend",
    //     .resizecb = null,
    //     .flags = 0,
    // };
    // const legendPlane = stdplane.create(&legendOpts).?;
    // solver.drawLegend(legendPlane);
    if (enable_tui) {
        _ = nc.?.stop();
    }
    std.debug.print("waits={}", .{solver.stats.waits});
}
