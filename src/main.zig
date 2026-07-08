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

const PlacedDominoCoordinate = [2]Coordinate;

const Puzzle = struct {
    regions: []Region,
    dominoes: []Domino,
    solution: []PlacedDominoCoordinate,

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
    InvalidBranch, // Stop working this branch
    NotSolved, // Continue working this branch
    Solved, // Completely solved
    Halted, // Not yet solved but not invalid either
};

const SolverRegion = struct {
    indices: std.ArrayList(u8) = .empty, // Differs from JSON format here
    type: RegionType,
    target: u8 = 0,
};

const PlacedDomino = struct {
    l1: Location,
    l2: Location,
};

// Easily copyable (i.e. no pointers) state for multiprocessing
const SolverState = struct {
    locations: [MAX_Y * MAX_Y]u8 = [_]u8{InvalidLocation} ** (MAX_Y * MAX_Y),
    // Running total for regions
    // =, >, <: running sum
    // equals: complicated, see addToregioncache
    // empty: running count
    // notEquals: bitmap of set pips
    region_cache: [MAX_REGIONS]u8 = [_]u8{0} ** MAX_REGIONS,
    placed: [MAX_DOMINOES]PlacedDomino = undefined,
    index: usize = 0, // Index of the domino to be worked next

    pub fn push(self: *SolverState, l1: Location, l2: Location) void {
        self.placed[self.index] = PlacedDomino{ .l1 = l1, .l2 = l2 };
        self.index += 1;
    }

    pub fn pop(self: *SolverState) PlacedDomino {
        self.index -= 1;
        return self.placed[self.index + 1];
    }
};

const SolverOptions = struct {
    max_depth: ?usize = null,
    max_depth_states: ?*std.ArrayList(SolverState) = null,
    allocator: ?std.mem.Allocator = null,
};

const Solver = struct {
    puzzle: *Puzzle,
    io: std.Io,
    stats: Stats = .{},
    last_failure: []const u8 = "",
    last_failure_buf: [128]u8 = undefined,
    regions: [MAX_REGIONS]SolverRegion = undefined,
    solution: [MAX_Y * MAX_Y]u8 = [_]u8{InvalidLocation} ** (MAX_Y * MAX_Y),
    location_to_region_map: [MAX_Y * MAX_Y]usize = undefined,
    region_len: usize,
    fast: bool = true,

    const Stats = struct {};

    pub fn init(gpa: std.mem.Allocator, puzzle: *Puzzle, io: std.Io) error{OutOfMemory}!Solver {
        var s = Solver{
            .puzzle = puzzle,
            .io = io,
            .region_len = puzzle.regions.len,
        };
        for (puzzle.regions, 0..) |region, region_index| {
            var sr = SolverRegion{
                .type = region.type,
                .target = region.target,
            };
            try sr.indices.ensureTotalCapacity(gpa, region.indices.len);
            for (region.indices) |i| {
                sr.indices.appendAssumeCapacity(coordToLoc(i));
                s.location_to_region_map[coordToLoc(i)] = region_index;
            }
            s.regions[region_index] = sr;
        }
        for (0..puzzle.dominoes.len) |di| {
            s.solution[coordToLoc(puzzle.solution[di][0])] = puzzle.dominoes[di][0];
            s.solution[coordToLoc(puzzle.solution[di][1])] = puzzle.dominoes[di][1];
        }
        return s;
    }

    pub fn newState(self: *const Solver) SolverState {
        var state = SolverState{};
        for (0..self.region_len) |region_index| {
            const region = self.regions[region_index];
            for (region.indices.items) |i| {
                state.locations[i] = UnsetPip;
            }
        }
        return state;
    }

    pub fn deinit(self: *Solver, gpa: std.mem.Allocator) void {
        for (0..self.region_len) |region_index| {
            self.regions[region_index].indices.deinit(gpa);
        }
    }

    pub fn addToRegionCache(self: *const Solver, state: *SolverState, ri: usize, pip: u8) bool {
        const r = self.regions[ri];
        switch (r.type) {
            .sum => {
                if (state.region_cache[ri] + pip > r.target) return false;
                state.region_cache[ri] += pip;
            },
            .less => {
                if (state.region_cache[ri] + pip >= r.target) return false;
                state.region_cache[ri] += pip;
            },
            .greater => {
                state.region_cache[ri] += pip;
            },
            .empty => {
                state.region_cache[ri] += 1;
            },
            .equals => {
                // Use the first 3 bits for the pip. The rest is a
                // running count so that we can know when to remove it
                // entirely.
                const cpip: u3 = @truncate(state.region_cache[ri] >> 5);
                const count: u5 = @truncate(state.region_cache[ri]);
                if (count == 0) {
                    state.region_cache[ri] = (@as(u8, pip) << 5) | @as(u8, 1);
                } else if (cpip != pip) {
                    return false;
                } else {
                    std.debug.assert(count != 31); // Would corrupt the state if so
                    state.region_cache[ri] += 1;
                }
            },
            .notEquals => {
                return true;
            },
        }
        return true;
    }

    pub fn removeFromRegionCache(self: *const Solver, state: *SolverState, ri: usize, pip: u8) void {
        const r = self.regions[ri];
        switch (r.type) {
            .sum, .less, .greater => {
                state.region_cache[ri] -= pip;
            },
            .empty => {
                state.region_cache[ri] -= 1;
            },
            .equals => {
                // Use the first 3 bits for the pip. The rest is a
                // running count so that we can know when to remove it
                // entirely.
                const count: u5 = @truncate(state.region_cache[ri]);
                if (count == 1) {
                    state.region_cache[ri] = 0;
                } else {
                    state.region_cache[ri] -= 1;
                }
            },
            .notEquals => {},
        }
    }

    // Bit of a funky signature, we know the region for l1 directly, but have to scan for l2
    pub fn addToCache(self: *const Solver, state: *SolverState, d: Domino, ri1: usize, l2: Location) bool {
        if (!self.addToRegionCache(state, ri1, d[0])) return false;
        if (self.addToRegionCache(state, self.location_to_region_map[l2], d[1])) {
            return true;
        }
        self.removeFromRegionCache(state, ri1, d[0]); // roll back first insert
        return false;
    }

    // Assumes that the removal is legit, and doesn't check status
    pub fn removeFromCache(self: *const Solver, state: *SolverState, d: Domino, ri1: usize, l2: Location) void {
        self.removeFromRegionCache(state, ri1, d[0]);
        self.removeFromRegionCache(state, self.location_to_region_map[l2], d[1]);
    }

    pub fn printDominos(_: *const Solver, state: *const SolverState) void {
        std.debug.print("s: ", .{});
        for (0..state.locations.len) |i| {
            if (state.locations[i] != InvalidLocation and state.locations[i] != UnsetPip) {
                std.debug.print("{d}={d},", .{ i, state.locations[i] });
            }
        }
        std.debug.print("\n", .{});
    }

    pub fn printSolution(self: *const Solver) void {
        std.debug.print("e: ", .{});
        for (0..self.solution.len) |i| {
            if (self.solution[i] != InvalidLocation and self.solution[i] != UnsetPip) {
                std.debug.print("{d}={d},", .{ i, self.solution[i] });
            }
        }
        std.debug.print("\n", .{});
    }

    pub fn checkSolution(self: *const Solver, state: *const SolverState) bool {
        for (0..self.solution.len) |i| {
            if (self.solution[i] != state.locations[i]) return false;
        }
        return true;
    }

    pub fn solve(self: *Solver, state: *SolverState, options: *const SolverOptions) !SolutionStatus {
        const domino = self.puzzle.dominoes[state.index];
        for (0..self.region_len) |region_index| {
            const region = self.regions[region_index];
            for (region.indices.items) |l1| {
                outer: for (std.enums.values(Orientation)) |orientation| {
                    // Don't check twin pips twice
                    if (domino[0] == domino[1] and (orientation == .left or orientation == .up)) continue :outer;
                    const l2: Location = switch (orientation) {
                        .right => l1 + 1,
                        .left => blk: {
                            if (l1 % MAX_X == 0) continue :outer;
                            break :blk l1 - 1;
                        },
                        .down => l1 + MAX_X,
                        .up => blk: {
                            if (l1 / MAX_X == 0) continue :outer;
                            break :blk l1 - MAX_X;
                        },
                    };

                    if (state.locations[l1] != UnsetPip or state.locations[l2] != UnsetPip) continue :outer;
                    if (!self.addToCache(state, domino, region_index, l2)) {
                        continue :outer;
                    }
                    state.locations[l1] = domino[0];
                    state.locations[l2] = domino[1];

                    const validated = self.validate(state);

                    state.push(l1, l2);
                    switch (validated) {
                        .InvalidBranch => {
                            state.locations[l1] = UnsetPip;
                            state.locations[l2] = UnsetPip;
                            self.removeFromCache(state, domino, region_index, l2);
                            _ = state.pop();
                            continue :outer;
                        },
                        .NotSolved => {
                            if (options.max_depth) |max_depth| {
                                if (state.index == max_depth) {
                                    try options.max_depth_states.?.append(options.allocator.?, state.*);
                                    state.locations[l1] = UnsetPip;
                                    state.locations[l2] = UnsetPip;
                                    self.removeFromCache(state, domino, region_index, l2);
                                    _ = state.pop();
                                    continue :outer;
                                }
                            }
                            switch (try self.solve(state, options)) {
                                .Solved => return .Solved,
                                .InvalidBranch, .NotSolved, .Halted => {
                                    state.locations[l1] = UnsetPip;
                                    state.locations[l2] = UnsetPip;
                                    self.removeFromCache(state, domino, region_index, l2);
                                    _ = state.pop();
                                    continue :outer;
                                },
                            }
                        },
                        .Solved => {
                            return .Solved;
                        },
                        .Halted => {
                            unreachable;
                        },
                    }
                }
            }
        }
        return .InvalidBranch;
    }

    fn errMsg(self: *Solver, comptime fmt: []const u8, args: anytype) void {
        if (!self.fast) {
            self.last_failure = std.fmt.bufPrint(&self.last_failure_buf, fmt, args) catch "format error";
        }
    }

    pub fn validate(self: *Solver, state: *SolverState) SolutionStatus {
        if (state.index + 1 == self.puzzle.dominoes.len) {
            for (0..self.region_len) |region_index| {
                const region = self.regions[region_index];
                switch (region.type) {
                    .empty => {
                        // If we're full, we can assume all pips are filled
                        std.debug.assert(state.region_cache[region_index] == region.indices.items.len);
                    },
                    .greater => {
                        if (state.region_cache[region_index] <= region.target) {
                            self.errMsg("target >{d} fails, found {d}", .{ region.target, state.region_cache[region_index] });
                            return .InvalidBranch;
                        }
                    },
                    .sum => {
                        if (state.region_cache[region_index] != region.target) {
                            self.errMsg("target ={d} fails, found {d}", .{ region.target, state.region_cache[region_index] });
                            return .InvalidBranch;
                        }
                    },
                    .less, .equals, .notEquals => {
                        // We can assume the invariant was never hit
                    },
                }
            }
            return .Solved;
        } else {
            return .NotSolved;
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var files = std.ArrayList([:0]const u8).empty;
    defer files.deinit(allocator);

    // easy, medium, hard
    var solve_select: [3]bool = .{false} ** 3;

    var args = init.minimal.args.iterate();
    _ = args.next(); // Skip $0
    while (args.next()) |arg| {
        if (arg[0] == '-' and arg[1] == '-') {
            if (std.mem.eql(u8, arg, "--batch")) {
                // noop, legacy flag
            } else if (std.mem.eql(u8, arg, "--easy")) {
                solve_select[0] = true;
            } else if (std.mem.eql(u8, arg, "--medium")) {
                solve_select[1] = true;
            } else if (std.mem.eql(u8, arg, "--hard")) {
                solve_select[2] = true;
            } else if (std.mem.eql(u8, arg, "--all")) {
                solve_select = .{true} ** 3;
            }
        } else {
            try files.append(allocator, arg);
        }
    }

    // Solve all when no flags
    if (!solve_select[0] and !solve_select[1] and !solve_select[2]) {
        solve_select = .{true} ** 3;
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

        var t_io = std.Io.Threaded.init(allocator, .{});
        defer t_io.deinit();

        var group = std.Io.Group.init;

        for (solve_select, 0..) |s, i| {
            if (!s) continue;
            var puzzle = switch (i) {
                0 => parsed.value.easy,
                1 => parsed.value.medium,
                2 => parsed.value.hard,
                else => parsed.value.easy,
            };
            const puzzle_name = switch (i) {
                0 => "easy",
                1 => "medium",
                2 => "hard",
                else => "what",
            };

            var solver = try Solver.init(allocator, &puzzle, init.io);
            defer solver.deinit(allocator);

            var sol_state = solver.newState();
            var states = std.ArrayList(SolverState).empty;
            defer states.deinit(allocator);
            _ = try solver.solve(&sol_state, &.{
                .max_depth = 1,
                .max_depth_states = &states,
                .allocator = allocator,
            });
            std.debug.print("{s}: {d} regions, {d} dominoes\n", .{ puzzle_name, puzzle.regions.len, puzzle.dominoes.len });
            for (states.items) |*state| {
                solver.printDominos(state);
                group.async(t_io.io(), solve, .{ t_io.io(), puzzle_name, &solver, state });
                // try solve(t_io.io(), puzzle_name, &solver, state);
            }
            try group.await(t_io.io());
        }
    }
}

pub fn solve(io: std.Io, name: [:0]const u8, solver: *Solver, state: *SolverState) std.Io.Cancelable!void {
    const start = std.Io.Clock.real.now(io);
    const solution = solver.solve(state, &.{}) catch return std.Io.Cancelable.Canceled;
    // Capture end time
    const end = std.Io.Clock.real.now(io);

    // Calculate duration
    const duration = start.durationTo(end);
    std.debug.print("{s} puzzle {s} in {d}ms\n", .{
        name,
        @tagName(solution),
        duration.toMilliseconds(),
    });
    solver.printDominos(state);
    solver.printSolution();
}
