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

    fn isDominoPartOfSection(self: *Puzzle, d: DominoPlace) bool {
        // Calculate the second coordinate based on orientation
        const secondCoord = d.secondCoord();
        std.debug.print("d: {d}, {d}\n", .{ d.c[0], d.c[1] });
        std.debug.print("d2: {d}, {d}\n", .{ secondCoord[0], secondCoord[1] });

        var foundFirst = false;
        var foundSecond = false;
        for (self.regions) |region| {
            // Check if both coordinates of the domino are in the section
            for (region.indices) |coord| {
                std.debug.print("s: {d}, {d}\n", .{ coord[0], coord[1] });

                if (!foundFirst and coordEql(coord, d.c)) {
                    std.debug.print("first\n", .{});
                    foundFirst = true;
                }
                if (!foundSecond and coordEql(coord, secondCoord)) {
                    std.debug.print("second\n", .{});
                    foundSecond = true;
                }
            }
        }
        if (foundFirst and foundSecond) return true;
        return false;
    }

    pub fn init(self: *Puzzle, gpa: std.mem.Allocator) !void {
        try self.placedDominoes.ensureTotalCapacity(gpa, self.dominoes.len);
    }

    pub fn deinit(self: *Puzzle, gpa: std.mem.Allocator) void {
        self.placedDominoes.deinit(gpa);
    }

    const Map = struct {
        const KeyType = u8;
        map: std.ArrayList(KeyType),
        maxX: usize = 0,
        maxY: usize = 0,
        pub fn deinit(self: *Map, gpa: std.mem.Allocator) void {
            self.map.deinit(gpa);
        }

        pub fn init(gpa: std.mem.Allocator, maxX: usize, maxY: usize) !Map {
            var m = Map{
                .map = try std.ArrayList(KeyType).initCapacity(gpa, (maxX + 1) * (maxY + 1)),
                .maxX = maxX,
                .maxY = maxY,
            };
            //try m.map.initCapacity(gpa, (maxX + 1) * (maxY + 1));
            try m.map.appendNTimes(gpa, UnsetPip, (maxX + 1) * (maxY + 1));
            return m;
        }

        pub fn setIfUnset(self: *Map, x: usize, y: usize, value: KeyType) bool {
            const val = self.at(x, y);
            if (val.* == UnsetPip) {
                std.debug.print("setting {}x{} to {}\n", .{ x, y, value });
                val.* = value;
                return true;
            }
            std.debug.print("Overlap at {}x{} (set to {})", .{ x, y, val.* });
            return false;
        }

        pub fn at(self: *Map, x: usize, y: usize) *KeyType {
            std.debug.print("fetching {}x{} (i {})\n", .{ x, y, (y * (self.maxX + 1)) + x });
            return &self.map.items[(y * (self.maxX + 1)) + x];
        }
    };

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

    pub fn validateSolution(self: *Puzzle) bool {
        // Pre-check for invariants

        for (self.regions) |region| {
            // Validate the total pips against the section requirement
            switch (region.type) {
                .sum => { // TODO only fail if greater, move final check to endstep
                    std.debug.print("checking sum {}\n", .{region.target});
                    var sum: i32 = 0;
                    for (region.indices) |coord| {
                        sum += @intCast(self.pipAt(coord));
                    }
                    if (sum != region.target) {
                        std.debug.print("Section requirement not met: expected = {d}, got {d}\n", .{ region.target, sum });
                        return false;
                    }
                },
                .greater => {
                    std.debug.print("checking sum greaterThan {}\n", .{region.target});
                    var sum: i32 = 0;
                    for (region.indices) |coord| {
                        sum += @intCast(self.pipAt(coord));
                    }
                    if (sum <= region.target) {
                        std.debug.print("Section requirement not met: expected > {d}, got {d}\n", .{ region.target, sum });
                        return false;
                    }
                },
                .less => {
                    std.debug.print("checking sum lessThan {}\n", .{region.target});
                    var sum: usize = 0;
                    for (region.indices) |coord| {
                        sum += @intCast(self.pipAt(coord));
                    }
                    if (sum >= region.target) {
                        std.debug.print("Section requirement not met: expected < {d}, got {d}\n", .{ region.target, sum });
                        return false;
                    }
                },
                .equals => {
                    // std.debug.print("checking equal\n", .{});
                    // const val = self.dominoAt(region.indices[0], region.indices[0]) orelse continue;
                    // for (region.indices) |coord| {
                    //     if (self.pipAt(coord[0], coord[1]).* != val) {
                    //         std.debug.print("Section requirement not met: expected = {d}, got {d}\n", .{ val, self.pipAt(coord[0], coord[1]).* });
                    //         return false;
                    //     }
                    // }
                },
                .notEquals => {
                    std.debug.print("checking not equal\n", .{});
                    var found: [7]bool = [_]bool{false} ** 7;
                    for (region.indices) |coord| {
                        const value = self.pipAt(coord);
                        if (found[@intCast(value)]) {
                            std.debug.print("Section requirement not met: already found {}\n", .{value});
                            return false;
                        } else {
                            found[@intCast(value)] = true;
                        }
                    }
                },
                .empty => { // TODO: Move this to the very end, it should be the last invariant
                    // std.debug.print("checking empty\n", .{});
                    // for (region.indices) |coord| {
                    //     if (map.at(coord[0], coord[1]).* == UnsetPip) {
                    //         return false;
                    //     }
                    // }
                },
            }
        }
        return true;
    }
};

// Can be bumped later
const MAX_DOMINOES = 32;
const MAX_INDICES = 8;

const Solver = struct {
    puzzle: *Puzzle,
    plane: ?*c.ncplane,
    last_failure: []const u8 = "",
    last_failure_buf: [128]u8 = undefined,
    nc: *c.notcurses,
    io: std.Io,
    stats: Stats = .{},
    placedDominoes: [MAX_DOMINOES]DominoPlace = undefined,
    pipCache: [MAX_INDICES]u8 = undefined,

    const Stats = struct {
        waits: usize = 0,
    };

    pub fn init(puzzle: *Puzzle, plane: *c.ncplane, nc: *c.notcurses, io: std.Io) Solver {
        return .{
            .puzzle = puzzle,
            .plane = plane,
            .nc = nc,
            .io = io,
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

        //if (index == self.puzzle.dominoes.len) return true; // Done!

        //var ninput: c.ncinput = undefined;
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
                    self.draw();
                    _ = c.notcurses_render(self.nc);
                    _ = self.waitFor(&[_]u32{'e'});

                    if (validated) {
                        return true;
                    }

                    if (try self.solve(gpa, index + 1)) return true;

                    _ = self.puzzle.placedDominoes.pop();
                    //std.debug.print("key {d}", .{self.waitFor(&[_]u32{'e'})});
                }
                //_ = c.notcurses_get_blocking(self.nc, &ninput);
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
                            std.debug.print("Section requirement not met: already found {}\n", .{value});
                            return false;
                        } else {
                            found[@intCast(value)] = true;
                        }
                    }
                },
            }
        }
        // Good idea below, but we already know if the map is filled based on if all dominoes are placed
        // If not yet full, no errors but not validated
        // for (self.puzzle.regions) |region| {
        //     for (region.indices) |i| {
        //         var found = false;
        //         for (self.puzzle.placedDominoes.items) |dp| {
        //             if (coordEql(dp.c, i) or coordEql(dp.secondCoord(), i)) {
        //                 found = true;
        //                 break;
        //             }
        //         }
        //         if (!found) {
        //             self.errMsg("not full", .{});
        //             return false;
        //         }
        //     }
        // }

        // If full, check all regions exactly
        self.errMsg("fin", .{});
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
        // Draw errMsg
        _ = plane.putstr_yx(10, 10, self.last_failure.ptr);
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args = init.minimal.args.iterate();
    _ = args.next();

    var fh = try std.Io.Dir.cwd().openFile(init.io, args.next().?, .{});
    defer fh.close(init.io);
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

    //try puzzle.place(0, Coordinate{ 0, 0 }, Orientation.right);

    var nc = c.notcurses_init(null, null) orelse return error.UnexpectedError;

    const stdplane = nc.notcurses_stdplane() orelse return error.UnexpectedError;

    var solver = Solver{
        .puzzle = &puzzle,
        .plane = stdplane,
        .nc = nc,
        .io = init.io,
    };
    _ = try solver.solve(allocator, 0);
    solver.draw();
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
    const legendPlane = stdplane.create(&legendOpts).?;
    solver.drawLegend(legendPlane);
    _ = c.notcurses_render(nc);
    _ = nc.stop();
    std.debug.print("waits={}", .{solver.stats.waits});
}
