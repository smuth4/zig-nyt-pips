const std = @import("std");
const zig_nyt_pips = @import("zig_nyt_pips");

const Coordinate = [2]u8;
const Location = u8;

pub fn coordToLoc(coord: Coordinate) Location {
    return coord[0] + (coord[1] * MAX_X);
}
pub fn locToCoord(location: Location) Coordinate {
    return .{ location % MAX_X, location / MAX_X };
}

test "coord loc switch" {
    const coord = Coordinate{ 3, 4 };
    std.debug.assert(coord[0] == locToCoord(coordToLoc(coord))[0]);
    std.debug.assert(coord[1] == locToCoord(coordToLoc(coord))[1]);
}

const Domino = [2]u8;

const Orientation = enum { right, up, left, down };

const RegionType = enum { sum, equals, notEquals, greater, less, empty };

// Need some constants that aren't 0-6 but still u8
const UnsetPip: u8 = 7;
const InvalidLocation: u8 = 8;

const SolverError = error{
    InvalidDomino,
};

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
const MAX_REGIONS = 32;
const MAX_X = 16;
const MAX_Y = 16;

const SolutionStatus = enum {
    InvalidBranch,
    NotSolved,
    Solved,
};

const SolverRegion = struct {
    indices: std.ArrayList(u8) = .empty, // Differs from JSON format here
    type: RegionType,
    target: u8 = 0,
    // Running total for regions
    // =, >, <: running sum
    // equals: complicated, see addToregioncache
    // empty: running count
    // notEquals: bitmap of set pips
    cache: u8 = 0,
};

const Solver = struct {
    puzzle: *Puzzle,
    io: std.Io,
    stats: Stats = .{},
    last_failure: []const u8 = "",
    last_failure_buf: [128]u8 = undefined,
    locations: [MAX_Y * MAX_Y]u8 = [_]u8{InvalidLocation} ** (MAX_Y * MAX_Y),
    regions: std.ArrayList(SolverRegion) = std.ArrayList(SolverRegion).empty,
    fast: bool = true,

    const Stats = struct {};

    pub fn init(gpa: std.mem.Allocator, puzzle: *Puzzle, io: std.Io) error{OutOfMemory}!Solver {
        var s = Solver{
            .puzzle = puzzle,
            .io = io,
        };
        try s.regions.ensureTotalCapacity(gpa, puzzle.regions.len);
        for (puzzle.regions) |region| {
            var sr = SolverRegion{
                .type = region.type,
                .target = region.target,
            };
            try sr.indices.ensureTotalCapacity(gpa, region.indices.len);
            for (region.indices) |i| {
                s.setLoc(coordToLoc(i), UnsetPip);
                sr.indices.appendAssumeCapacity(coordToLoc(i));
            }
            s.regions.appendAssumeCapacity(sr);
        }
        return s;
    }

    pub fn deinit(self: *Solver, gpa: std.mem.Allocator) void {
        for (self.regions.items) |*r| {
            r.indices.deinit(gpa);
        }
        self.regions.deinit(gpa);
    }

    pub fn getLoc(self: *const Solver, loc: Location) u8 {
        return self.locations[loc];
    }

    pub fn setLoc(self: *Solver, loc: Location, i: u8) void {
        self.locations[loc] = i;
    }

    pub fn addToRegionCache(_: *Solver, r: *SolverRegion, pip: u8) bool {
        switch (r.type) {
            .sum => {
                if (r.cache + pip > r.target) return false;
                r.cache += pip;
            },
            .less => {
                if (r.cache + pip >= r.target) return false;
                r.cache += pip;
            },
            .greater => {
                r.cache += pip;
            },
            .empty => {
                r.cache += 1;
            },
            .equals => {
                // Use the first 3 bits for the pip. The rest is a
                // running count so that we can know when to remove it
                // entirely.
                const cpip: u3 = @truncate(r.cache >> 5);
                const count: u5 = @truncate(r.cache);
                if (count == 0) {
                    r.cache = (@as(u8, pip) << 5) | @as(u8, 1);
                } else if (cpip != pip) {
                    return false;
                } else {
                    std.debug.assert(count != 31); // Would corrupt the state if so
                    r.cache += 1;
                }
            },
            //     .notEquals => {
            //         std.debug.print("add notEquals\n", .{});
            //         const mask = @as(u8, 1) << @truncate(pip);
            //         if (r.cache & mask != 0) return false;
            //         r.cache |= mask;
            //     },
            else => {
                return true;
            },
        }
        return true;
    }

    pub fn removeFromRegionCache(_: *Solver, r: *SolverRegion, pip: u8) void {
        switch (r.type) {
            .sum, .less, .greater => {
                r.cache -= pip;
            },
            .empty => {
                r.cache -= 1;
            },
            .equals => {
                // Use the first 3 bits for the pip. The rest is a
                // running count so that we can know when to remove it
                // entirely.
                const count: u5 = @truncate(r.cache);
                if (count == 1) {
                    r.cache = 0;
                } else {
                    r.cache -= 1;
                }
            },
            //     .notEquals => {
            //         const mask = @as(u8, 1) << @truncate(pip);
            //         r.cache &= ~mask;
            //     },
            else => {},
        }
    }

    // Bit of a funky signature, we know the region for l1 directly, but have to scan for l2
    pub fn addToCache(self: *Solver, d: Domino, r1: *SolverRegion, l2: Location) bool {
        for (self.regions.items) |*region| {
            for (region.indices.items) |location| {
                if (l2 == location) {
                    if (!self.addToRegionCache(r1, d[0])) return false;
                    if (self.addToRegionCache(region, d[1])) {
                        return true;
                    } else {
                        self.removeFromRegionCache(r1, d[0]); // roll back first insert
                        return false;
                    }
                }
            }
        }
        //self.removeFromRegionCache(r1, d[0]); // roll back first insert
        return false;
    }

    // Assumes that the removal is legit, and doesn't check status
    pub fn removeFromCache(self: *Solver, d: Domino, r1: *SolverRegion, l2: Location) void {
        for (self.regions.items) |*region| {
            for (region.indices.items) |location| {
                if (l2 == location) {
                    self.removeFromRegionCache(r1, d[0]);
                    return self.removeFromRegionCache(region, d[1]);
                }
            }
        }
    }

    // Build N number of valid states as a copy of this fresh state
    // pub fn generateFrontier(self: *Solver, gpa: std.mem.Allocator, num: usize) !std.ArrayList(Solver) {
    //     var states = try std.ArrayList(Solver).initCapacity(gpa, num);
    //     var depth: usize = 0;
    //     var index: usize = 0;
    //     for (self.regions.items) |*region| {
    //         for (region.indices.items) |location| {
    //             const domino = self.puzzle.dominoes[index];
    //             outer: for (std.enums.values(Orientation)) |orientation| {
    //                 if (num >= depth) return states;
    //                 const l2: Location = switch (orientation) {
    //                     .right => location + 1,
    //                     .left => blk: {
    //                         if (location % MAX_X == 0) continue :outer;
    //                         break :blk location - 1;
    //                     },
    //                     .down => location + MAX_X,
    //                     .up => blk: {
    //                         if (location / MAX_X == 0) continue :outer;
    //                         break :blk location - MAX_X;
    //                     },
    //                 };
    //                 if (self.getLoc(location) != UnsetPip or self.getLoc(l2) != UnsetPip) continue :outer;
    //                 if (!self.addToCache(domino, region, l2)) {
    //                     continue :outer;
    //                 }
    //                 self.setLoc(location, domino[0]);
    //                 self.setLoc(l2, domino[1]);
    //             }
    //         }
    //     }
    // }

    pub fn solve(self: *Solver, index: usize) !SolutionStatus {
        const domino = self.puzzle.dominoes[index];
        for (self.regions.items) |*region| {
            for (region.indices.items) |location| {
                outer: for (std.enums.values(Orientation)) |orientation| {
                    const l2: Location = switch (orientation) {
                        .right => location + 1,
                        .left => blk: {
                            if (location % MAX_X == 0) continue :outer;
                            break :blk location - 1;
                        },
                        .down => location + MAX_X,
                        .up => blk: {
                            if (location / MAX_X == 0) continue :outer;
                            break :blk location - MAX_X;
                        },
                    };
                    if (self.getLoc(location) != UnsetPip or self.getLoc(l2) != UnsetPip) continue :outer;
                    if (!self.addToCache(domino, region, l2)) {
                        continue :outer;
                    }
                    self.setLoc(location, domino[0]);
                    self.setLoc(l2, domino[1]);

                    const validated = self.validate(index);
                    if (!self.fast) {
                        // std.debug.print("Placed domino {d}:{d} at {d}x{d}, {s}{s}\n", .{
                        //     dp.domino[0],
                        //     dp.domino[1],
                        //     dp.coord[0],
                        //     dp.coord[1],
                        //     switch (validated) {
                        //         .Solved => "finished",
                        //         .InvalidBranch => "invalid: ",
                        //         .NotSolved => "continuing",
                        //     },
                        //     if (validated == .InvalidBranch) self.last_failure else "",
                        // });
                    }

                    switch (validated) {
                        .InvalidBranch => {
                            self.setLoc(location, UnsetPip);
                            self.setLoc(l2, UnsetPip);
                            self.removeFromCache(domino, region, l2);
                            continue :outer;
                        },
                        .NotSolved => {
                            switch (try self.solve(index + 1)) {
                                .Solved => return .Solved,
                                .InvalidBranch, .NotSolved => {
                                    self.setLoc(location, UnsetPip);
                                    self.setLoc(l2, UnsetPip);
                                    self.removeFromCache(domino, region, l2);
                                    continue :outer;
                                },
                            }
                        },
                        .Solved => {
                            return .Solved;
                        },
                    }
                }
            }
        }
        return .InvalidBranch;
    }

    pub fn sumRegion(self: *const Solver, region: *const SolverRegion) u8 {
        var sum: u8 = 0;
        for (region.indices.items) |location| {
            const value = self.getLoc(location);
            if (value <= 6) {
                sum += value;
            }
        }
        return sum;
    }

    fn errMsg(self: *Solver, comptime fmt: []const u8, args: anytype) void {
        if (!self.fast) {
            self.last_failure = std.fmt.bufPrint(&self.last_failure_buf, fmt, args) catch "format error";
        }
    }

    pub fn validate(self: *Solver, index: usize) SolutionStatus {
        if (index + 1 == self.puzzle.dominoes.len) {
            for (self.regions.items) |region| {
                switch (region.type) {
                    .empty => {
                        // If we're full, we can assume all pips are filled
                        std.debug.assert(region.cache == region.indices.items.len);
                    },
                    .greater => {
                        if (region.cache <= region.target) {
                            self.errMsg("target >{d} fails, found {d}", .{ region.target, region.cache });
                            return .InvalidBranch;
                        }
                    },
                    .sum => {
                        if (region.cache != region.target) {
                            self.errMsg("target ={d} fails, found {d}", .{ region.target, region.cache });
                            return .InvalidBranch;
                        }
                    },
                    .less => {
                        // We can assume the invariant was never hit
                    },
                    .equals => {
                        // We can assume the invariant was never hit
                    },
                    .notEquals => {
                        // We can assume the invariant was never hit
                    },
                }
            }
            return .Solved;
        } else {
            // Check invariants
            for (self.regions.items) |region| {
                switch (region.type) {
                    .empty, .greater => {},
                    .sum => {},
                    .less => {},
                    .equals => {
                        // var firstFoundPip: u8 = UnsetPip;
                        // for (region.indices.items) |i| {
                        //     const d = self.getLoc(i);
                        //     if (d >= 6) continue;
                        //     if (firstFoundPip == UnsetPip) {
                        //         firstFoundPip = d;
                        //     } else if (d != firstFoundPip) {
                        //         self.errMsg("target = fails early, found {d} then {d}", .{ firstFoundPip, d });
                        //         return .InvalidBranch;
                        //     }
                        // }
                    },
                    .notEquals => {
                        // var found: [7]bool = [_]bool{false} ** 7;
                        // for (region.indices.items) |i| {
                        //     const value = self.getLoc(i);
                        //     if (value > 6) continue;
                        //     if (found[@intCast(value)]) {
                        //         self.errMsg("target != fails early, already found {d}\n", .{value});
                        //         return .InvalidBranch;
                        //     } else {
                        //         found[@intCast(value)] = true;
                        //     }
                        // }
                    },
                }
            }
            self.errMsg("valid but not full", .{});
            return .NotSolved;
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var files = std.ArrayList([:0]const u8).empty;
    defer files.deinit(allocator);

    // easy, medium, hard
    var solve: [3]bool = .{false} ** 3;

    var args = init.minimal.args.iterate();
    _ = args.next(); // Skip $0
    while (args.next()) |arg| {
        if (arg[0] == '-' and arg[1] == '-') {
            if (std.mem.eql(u8, arg, "--batch")) {
                // noop, legacy flag
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

            var solver = try Solver.init(allocator, &puzzle, init.io);
            defer solver.deinit(allocator);

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
}
