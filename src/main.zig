const std = @import("std");
const zig_nyt_pips = @import("zig_nyt_pips");

const c = @cImport({
    @cDefine("_XOPEN_SOURCE", "700");
    @cInclude("notcurses/notcurses.h");
});

const Coordinate = [2]u8;
const Domino = [2]u8;

const Orientation = enum { unplaced, right, up, left, down };

const RegionType = enum { sum, equals, notEquals, greater, less, empty };

const UnsetPip: i8 = 7; // Need a constant that's not 0-6 but also unsigned

// const NYTRegionType = enum {
//     empty,
//     greater,
//     sum,
//     equals,
//     less,
// };

const Region = struct {
    indices: []Coordinate,
    type: RegionType,
    target: u8 = 0,
};

// const NTYPuzzle = struct {
//     dominoes: []Domino,
//     regions: []NYTRegion,
//     placedDominoes: std.ArrayList(DominoPlace) = std.ArrayList(DominoPlace).empty,
// };

const NYTFormat = struct {
    printDate: []u8,
    editor: []u8,
    easy: Puzzle,
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
            .unplaced => self.c, // or handle differently if needed
        };
    }

    fn coords(self: DominoPlace) [2]Coordinate {
        std.debug.assert(self.o != .unplaced);
        return [2]Coordinate{ self.d, self.secondCoord() };
    }
};

fn areCoordinatesEqual(a: Coordinate, b: Coordinate) bool {
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

                if (!foundFirst and areCoordinatesEqual(coord, d.c)) {
                    std.debug.print("first\n", .{});
                    foundFirst = true;
                }
                if (!foundSecond and areCoordinatesEqual(coord, secondCoord)) {
                    std.debug.print("second\n", .{});
                    foundSecond = true;
                }
            }
        }
        if (foundFirst and foundSecond) return true;
        return false;
    }

    pub fn place(self: *Puzzle, i: usize, coord: Coordinate, o: Orientation) !void {
        const domino = DominoPlace{
            .d = self.dominoes[i],
            .c = coord,
            .o = o,
        };

        if (!self.isDominoPartOfSection(domino)) {
            return error.InvalidPlacement;
        }
        self.placedDominoes.appendAssumeCapacity(domino);
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

    pub fn validateSolution(self: *Puzzle, gpa: std.mem.Allocator) !bool {
        // Build the map
        var maxX: usize = 0;
        var maxY: usize = 0;
        for (self.regions) |region| {
            for (region.indices) |coord| {
                maxX = @max(coord[0], maxX);
                maxY = @max(coord[1], maxY);
            }
        }

        std.debug.print("map {} x {}\n", .{ maxX, maxY });
        var map = try Map.init(gpa, maxX, maxY);

        defer map.deinit(gpa);
        // Fill in with set dominoes
        for (self.placedDominoes.items) |domino| {
            if (!map.setIfUnset(domino.c[0], domino.c[1], domino.d[0])) {
                return false;
            }
            if (!map.setIfUnset(domino.secondCoord()[0], domino.secondCoord()[1], domino.d[1])) {
                return false;
            }
        }

        for (self.regions) |region| {
            // Validate the total pips against the section requirement
            switch (region.type) {
                .sum => {
                    std.debug.print("checking sum {}\n", .{region.target});
                    var sum: i32 = 0;
                    for (region.indices) |coord| {
                        sum += @intCast(map.at(coord[0], coord[1]).*);
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
                        sum += @intCast(map.at(coord[0], coord[1]).*);
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
                        sum += @intCast(map.at(coord[0], coord[1]).*);
                    }
                    if (sum >= region.target) {
                        std.debug.print("Section requirement not met: expected < {d}, got {d}\n", .{ region.target, sum });
                        return false;
                    }
                },
                .equals => {
                    std.debug.print("checking equal\n", .{});
                    const val = map.at(region.indices[0][0], region.indices[0][1]).*;
                    for (region.indices) |coord| {
                        if (map.at(coord[0], coord[1]).* != val) {
                            std.debug.print("Section requirement not met: expected = {d}, got {d}\n", .{ val, map.at(coord[0], coord[1]).* });
                            return false;
                        }
                    }
                },
                .notEquals => {
                    std.debug.print("checking not equal\n", .{});
                    var found: [7]bool = [_]bool{false} ** 7;
                    for (region.indices) |coord| {
                        const value = map.at(coord[0], coord[1]).*;
                        if (found[@intCast(value)]) {
                            std.debug.print("Section requirement not met: already found {}\n", .{value});
                            return false;
                        } else {
                            found[@intCast(value)] = true;
                        }
                    }
                },
                .empty => {
                    std.debug.print("checking empty\n", .{});
                    for (region.indices) |coord| {
                        if (map.at(coord[0], coord[1]).* == UnsetPip) {
                            return false;
                        }
                    }
                },
            }
        }
        return true;
    }

    pub fn draw(self: *Puzzle, plane: *c.ncplane) void {
        //const chan: c_uint = 0;
        //chan.rgb(100, 100, 100);
        var bg_palindex: c_uint = 0;
        _ = plane.set_fg_palindex(0);
        for (self.regions) |region| {
            if (region.type == .empty) {
                _ = plane.set_bg_palindex(15);
            } else {
                bg_palindex += 1;
                _ = plane.set_bg_palindex(bg_palindex);
            }
            for (region.indices) |coord| {
                _ = plane.putchar_yx(coord[0], coord[1], ' ');
                //var cell: c.nccell = undefined;
                //_ = c.ncplane_at_cursor_cell(plane, &cell);
                //_ = c.nccell_set_bg_rgb8(&cell, 0x99, 0x00, 0xCC);
                //cell.channels |= c.NCALPHA_OPAQUE;

                //_ = c.ncplane_putc(plane, &cell);
                //c.nccell_release(plane, &cell);
                //plane.set_bg_rgb(chan);
            }
        }
    }
};

pub fn main(init: std.process.Init) !void {
    // Prints to stderr, ignoring potential errors.
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

    try puzzle.place(0, Coordinate{ 0, 0 }, Orientation.right);
    _ = try puzzle.validateSolution(allocator);

    var nc = c.notcurses_init(null, null) orelse return error.UnexpectedError;
    defer _ = nc.stop();

    const stdplane = nc.notcurses_stdplane() orelse return error.UnexpectedError;

    puzzle.draw(stdplane);
    _ = c.notcurses_render(nc);
    init.io.sleep(.fromSeconds(15), .awake) catch {};
}
