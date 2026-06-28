const std = @import("std");
const zig_nyt_pips = @import("zig_nyt_pips");

const c = @cImport({
    @cDefine("_XOPEN_SOURCE", "700");
    @cInclude("notcurses/notcurses.h");
});

const Coordinate = [2]u8;
pub fn coordToLoc(coord: Coordinate) u8 {
    return coord[0] + (coord[1] * MAX_X);
}
const Domino = [2]u8;

const Orientation = enum { right, up, left, down };

const RegionType = enum { sum, equals, notEquals, greater, less, empty };

// Need some constants that aren't 0-6 but still u8
const UnsetPip: u8 = 7;
const InvalidLocation: u8 = 8;

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
    hard: Puzzle,
};

const DominoPlace = struct {
    domino: Domino,
    coord: Coordinate,
    orientation: Orientation,

    fn secondCoord(self: DominoPlace) Coordinate {
        return switch (self.orientation) {
            .right => .{ self.coord[0], self.coord[1] + 1 },
            .left => .{ self.coord[0], self.coord[1] - 1 },
            .down => .{ self.coord[0] + 1, self.coord[1] },
            .up => .{ self.coord[0] - 1, self.coord[1] },
        };
    }

    fn isValid(self: DominoPlace) bool {
        switch (self.orientation) {
            .right, .down => return true,
            .left => return self.coord[1] != 0,
            .up => return self.coord[0] != 0,
        }
    }
};

const Puzzle = struct {
    regions: []Region,
    dominoes: []Domino,

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
};

// Can be bumped later
const MAX_DOMINOES = 32;
const MAX_INDICES = 16;
const MAX_X = 16;
const MAX_Y = 16;

const SolutionStatus = enum {
    InvalidBranch,
    NotSolved,
    Solved,
};

const Solver = struct {
    puzzle: *Puzzle,
    plane: ?*c.ncplane,
    legendplane: ?*c.ncplane,
    nc: ?*c.notcurses, // If null, no UI
    io: std.Io,
    stats: Stats = .{},
    last_failure: []const u8 = "",
    last_failure_buf: [128]u8 = undefined,
    locations: [MAX_Y * MAX_Y]u8 = [_]u8{InvalidLocation} ** (MAX_Y * MAX_Y),
    fast: bool = true,

    const Stats = struct {};

    pub fn init(puzzle: *Puzzle, plane: ?*c.ncplane, nc: ?*c.notcurses, io: std.Io) Solver {
        var legendplane: ?*c.ncplane = null;
        if (nc) |_| {
            const legendOpts = c.ncplane_options{
                .y = 0,
                .x = 8,
                .rows = 16,
                .cols = 16,
                .userptr = null,
                .name = "legend",
                .resizecb = null,
                .flags = 0,
            };
            legendplane = plane.?.create(&legendOpts).?;
        }

        var s = Solver{
            .puzzle = puzzle,
            .plane = plane,
            .nc = nc,
            .io = io,
            .legendplane = legendplane,
        };
        for (puzzle.regions) |region| {
            for (region.indices) |i| {
                s.setLoc(i, UnsetPip);
            }
        }
        return s;
    }

    pub fn setLoc(self: *Solver, coord: Coordinate, i: u8) void {
        self.locations[coordToLoc(coord)] = i;
    }

    pub fn getLoc(self: *const Solver, coord: Coordinate) u8 {
        return self.locations[coordToLoc(coord)];
    }

    // If possible to place, return true, else false
    pub fn placeDomino(self: *Solver, dp: DominoPlace) bool {
        if (!dp.isValid() or self.getLoc(dp.coord) != UnsetPip or self.getLoc(dp.secondCoord()) != UnsetPip) return false;

        self.setLoc(dp.coord, dp.domino[0]);
        self.setLoc(dp.secondCoord(), dp.domino[1]);
        return true;
    }

    pub fn removeDomino(self: *Solver, dp: DominoPlace) void {
        self.setLoc(dp.coord, UnsetPip);
        self.setLoc(dp.secondCoord(), UnsetPip);
    }

    pub fn solve(self: *Solver, index: usize) !SolutionStatus {
        const domino = self.puzzle.dominoes[index];
        for (self.puzzle.regions) |region| {
            for (region.indices) |coord| {
                outer: for (std.enums.values(Orientation)) |orientation| {
                    const dp = DominoPlace{
                        .coord = coord,
                        .domino = domino,
                        .orientation = orientation,
                    };
                    if (self.placeDomino(dp)) {
                        const validated = self.validate(index);
                        if (self.nc) |_| {
                            self.draw();
                            _ = c.notcurses_render(self.nc);
                            //_ = self.waitFor(&[_]u32{'e'});
                        } else if (!self.fast) {
                            std.debug.print("Placed domino {d}:{d} at {d}x{d}, {s}{s}\n", .{
                                dp.domino[0],
                                dp.domino[1],
                                dp.coord[0],
                                dp.coord[1],
                                switch (validated) {
                                    .Solved => "finished",
                                    .InvalidBranch => "invalid: ",
                                    .NotSolved => "continuing",
                                },
                                if (validated == .InvalidBranch) self.last_failure else "",
                            });
                        }

                        switch (validated) {
                            .InvalidBranch => {
                                self.removeDomino(dp);
                                continue :outer;
                            },
                            .NotSolved => {
                                switch (try self.solve(index + 1)) {
                                    .Solved => return .Solved,
                                    .InvalidBranch, .NotSolved => {
                                        self.removeDomino(dp);
                                        continue :outer;
                                    },
                                }
                            },
                            .Solved => {
                                if (self.nc) |_| {
                                    _ = self.waitFor(&[_]u32{'e'});
                                }
                                return .Solved;
                            },
                        }
                    }
                }
            }
        }
        return .InvalidBranch;
    }

    pub fn sumRegion(self: *const Solver, region: *const Region) u8 {
        var sum: u8 = 0;
        for (region.indices) |coord| {
            const value = self.getLoc(coord);
            if (value <= 6) {
                sum += value;
            }
        }
        return sum;
    }

    pub fn waitFor(self: *Solver, allowed: []const u32) u32 {
        var ninput: c.ncinput = undefined;
        while (true) {
            _ = c.notcurses_get_blocking(self.nc, &ninput);
            if (std.mem.findScalar(u32, allowed, ninput.id)) |_| {
                if (ninput.evtype != c.NCTYPE_PRESS) continue;
                return ninput.id;
            }
        }
    }

    fn errMsg(self: *Solver, comptime fmt: []const u8, args: anytype) void {
        if (!self.fast) {
            self.last_failure = std.fmt.bufPrint(&self.last_failure_buf, fmt, args) catch "format error";
        }
    }

    pub fn validate(self: *Solver, index: usize) SolutionStatus {
        if (index + 1 == self.puzzle.dominoes.len) {
            for (self.puzzle.regions) |region| {
                switch (region.type) {
                    .empty => {
                        for (region.indices) |coord| {
                            if (self.getLoc(coord) == UnsetPip) {
                                self.errMsg("empty pip not filled", .{});
                                return .InvalidBranch;
                            }
                        }
                    },
                    .greater => {
                        const s = self.sumRegion(&region);
                        if (s <= region.target) {
                            self.errMsg("target >{d} fails, found {d}", .{ region.target, s });
                            return .InvalidBranch;
                        }
                    },
                    .sum => {
                        const s = self.sumRegion(&region);
                        if (s != region.target) {
                            self.errMsg("target ={d} fails, found {d}", .{ region.target, s });
                            return .InvalidBranch;
                        }
                    },
                    .less => {
                        const s = self.sumRegion(&region);
                        if (s >= region.target) {
                            self.errMsg("target <{d} fails, found {d}", .{ region.target, s });
                            return .InvalidBranch;
                        }
                    },
                    .equals => {
                        var firstFoundPip: u8 = UnsetPip;
                        for (region.indices) |i| {
                            const d = self.getLoc(i);
                            if (d == UnsetPip) continue;
                            if (firstFoundPip == UnsetPip) {
                                firstFoundPip = d;
                            } else if (d != firstFoundPip) {
                                self.errMsg("target = fails, found {d} then {d}", .{ firstFoundPip, d });
                                return .InvalidBranch;
                            }
                        }
                    },
                    .notEquals => {
                        var found: [7]bool = [_]bool{false} ** 7;
                        for (region.indices) |coord| {
                            const value = self.getLoc(coord);
                            if (value > 6) continue;
                            if (found[@intCast(value)]) {
                                self.errMsg("target != fails, already found {d}\n", .{value});
                                return .InvalidBranch;
                            } else {
                                found[@intCast(value)] = true;
                            }
                        }
                    },
                }
            }
            return .Solved;
        } else {
            // Check invariants
            for (self.puzzle.regions) |region| {
                switch (region.type) {
                    .empty, .greater => {},
                    .sum => {
                        const s = self.sumRegion(&region);
                        if (s > region.target) {
                            self.errMsg("target ={d} fails early, found {d}", .{ region.target, s });
                            return .InvalidBranch;
                        }
                    },
                    .less => {
                        const s = self.sumRegion(&region);
                        if (s > region.target) {
                            self.errMsg("target <{d} fails early, found {d}", .{ region.target, s });
                            return .InvalidBranch;
                        }
                    },
                    .equals => {
                        var firstFoundPip: u8 = UnsetPip;
                        for (region.indices) |i| {
                            const d = self.getLoc(i);
                            if (d >= 6) continue;
                            if (firstFoundPip == UnsetPip) {
                                firstFoundPip = d;
                            } else if (d != firstFoundPip) {
                                self.errMsg("target = fails early, found {d} then {d}", .{ firstFoundPip, d });
                                return .InvalidBranch;
                            }
                        }
                    },
                    .notEquals => {
                        var found: [7]bool = [_]bool{false} ** 7;
                        for (region.indices) |coord| {
                            const value = self.getLoc(coord);
                            if (value > 6) continue;
                            if (found[@intCast(value)]) {
                                self.errMsg("target != fails early, already found {d}\n", .{value});
                                return .InvalidBranch;
                            } else {
                                found[@intCast(value)] = true;
                            }
                        }
                    },
                }
            }
            self.errMsg("valid but not full", .{});
            return .NotSolved;
        }
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
        _ = self.nc orelse return; // noop on batch

        const plane = self.plane orelse return;
        var bg_palindex: c_uint = 0;
        _ = plane.set_fg_palindex(0);
        self.drawLegend(self.legendplane.?);
        for (self.puzzle.regions) |region| {
            if (region.type == .empty) {
                _ = plane.set_bg_palindex(15);
            } else {
                bg_palindex += 1;
                _ = plane.set_bg_palindex(bg_palindex);
            }
            for (region.indices) |coord| {
                var pip: u8 = ' ';
                const value = self.getLoc(coord);
                if (value <= 6) {
                    pip = value + '0';
                }
                _ = plane.putchar_yx(coord[0], coord[1], pip);
            }
        }
        _ = plane.putstr_yx(10, 10, self.last_failure.ptr);
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var files = std.ArrayList([:0]const u8).empty;
    defer files.deinit(allocator);

    var enable_tui = true;
    // easy, medium, hard
    var solve: [3]bool = .{false} ** 3;

    var args = init.minimal.args.iterate();
    _ = args.next(); // Skip $0
    while (args.next()) |arg| {
        if (arg[0] == '-' and arg[1] == '-') {
            if (std.mem.eql(u8, arg, "--batch")) {
                enable_tui = false;
            } else if (std.mem.eql(u8, arg, "--easy")) {
                solve[0] = true;
            } else if (std.mem.eql(u8, arg, "--medium")) {
                solve[1] = true;
            } else if (std.mem.eql(u8, arg, "--hard")) {
                solve[2] = true;
            } else if (std.mem.eql(u8, arg, "--all")) {
                solve = .{true} ** 3;
            }
        } else {
            try files.append(allocator, arg);
        }
    }

    // Solve all when no flags
    if (!solve[0] and !solve[1] and !solve[2]) {
        solve = .{true} ** 3;
    }

    var buf: [1024]u8 = undefined;
    var jallocator = std.heap.ArenaAllocator.init(allocator);
    defer jallocator.deinit();

    var nc: ?*c.notcurses = null;
    var stdplane: ?*c.ncplane = null;
    if (enable_tui) {
        nc = c.notcurses_init(null, null) orelse return error.UnexpectedError;

        stdplane = nc.?.notcurses_stdplane() orelse return error.UnexpectedError;
    }

    for (files.items) |file| {
        var fh = try std.Io.Dir.cwd().openFile(init.io, file, .{});
        defer fh.close(init.io);

        var freader = fh.reader(init.io, &buf);
        var scanner = std.json.Scanner.Reader.init(jallocator.allocator(), &freader.interface);
        defer scanner.deinit();

        var parsed = try std.json.parseFromTokenSource(NYTFormat, allocator, &scanner, .{
            .ignore_unknown_fields = true, // Safeguard against unexpected API fields
        });
        defer parsed.deinit();

        for (solve, 0..) |s, i| {
            if (!s) continue;
            var puzzle = switch (i) {
                0 => parsed.value.easy,
                1 => parsed.value.medium,
                2 => parsed.value.hard,
                else => parsed.value.easy,
            };

            var solver = Solver.init(&puzzle, stdplane, nc, init.io);
            const start = std.Io.Clock.real.now(init.io);
            const solution = try solver.solve(0);
            // Capture end time
            const end = std.Io.Clock.real.now(init.io);

            // Calculate duration
            const duration = start.durationTo(end);
            std.debug.print("{s}: {s} puzzle {s} in {d}ms\n", .{
                std.fs.path.basename(file),
                switch (i) {
                    0 => "easy",
                    1 => "medium",
                    2 => "hard",
                    else => "other",
                },
                @tagName(solution),
                duration.toMilliseconds(),
            });
        }
    }
    if (enable_tui) {
        _ = nc.?.stop();
    }
}
