const std = @import("std");

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

const RegionType = enum(u8) {
    equals = 5,
    sum = 4,
    greater = 3,
    unequal = 2,
    less = 1,
    empty = 0,
};

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
const GRID_SIZE = MAX_X * MAX_Y;

const PuzzleValidationError = error{
    TooManyDominoes,
    TooManyRegions,
    TooManyRegionIndices,
    CoordinateOutOfBounds,
    SolutionLengthMismatch,
};

fn validatePuzzle(puzzle: *const Puzzle) PuzzleValidationError!void {
    if (puzzle.dominoes.len > MAX_DOMINOES) return error.TooManyDominoes;
    if (puzzle.regions.len > MAX_REGIONS) return error.TooManyRegions;
    if (puzzle.solution.len != puzzle.dominoes.len) return error.SolutionLengthMismatch;

    for (puzzle.regions) |region| {
        if (region.indices.len > MAX_INDICES) return error.TooManyRegionIndices;
        for (region.indices) |coord| {
            if (coord[0] >= MAX_X or coord[1] >= MAX_Y) return error.CoordinateOutOfBounds;
        }
    }

    for (puzzle.solution) |placement| {
        for (placement) |coord| {
            if (coord[0] >= MAX_X or coord[1] >= MAX_Y) return error.CoordinateOutOfBounds;
        }
    }
}

test "validate puzzle limits" {
    var valid_indices = [_]Coordinate{.{ MAX_X - 1, MAX_Y - 1 }};
    var valid_regions = [_]Region{.{
        .indices = &valid_indices,
        .type = .empty,
    }};
    var puzzle = Puzzle{
        .regions = &valid_regions,
        .dominoes = &.{},
        .solution = &.{},
    };
    try validatePuzzle(&puzzle);

    var oversized_indices: [MAX_INDICES + 1]Coordinate = @splat(.{ 0, 0 });
    puzzle.regions[0].indices = &oversized_indices;
    try std.testing.expectError(error.TooManyRegionIndices, validatePuzzle(&puzzle));

    var out_of_bounds_indices = [_]Coordinate{.{ MAX_X, 0 }};
    puzzle.regions[0].indices = &out_of_bounds_indices;
    try std.testing.expectError(error.CoordinateOutOfBounds, validatePuzzle(&puzzle));

    var oversized_dominoes: [MAX_DOMINOES + 1]Domino = @splat(.{ 0, 0 });
    puzzle.regions = &valid_regions;
    puzzle.dominoes = &oversized_dominoes;
    try std.testing.expectError(error.TooManyDominoes, validatePuzzle(&puzzle));

    var oversized_regions: [MAX_REGIONS + 1]Region = undefined;
    for (&oversized_regions) |*region| {
        region.* = .{ .indices = &valid_indices, .type = .empty };
    }
    puzzle.regions = &oversized_regions;
    puzzle.dominoes = &.{};
    try std.testing.expectError(error.TooManyRegions, validatePuzzle(&puzzle));

    var one_domino = [_]Domino{.{ 0, 0 }};
    puzzle.regions = &valid_regions;
    puzzle.dominoes = &one_domino;
    try std.testing.expectError(error.SolutionLengthMismatch, validatePuzzle(&puzzle));
}

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
    locations: [MAX_Y * MAX_Y]u8 = @splat(InvalidLocation),
    // Running total for regions
    // =, >, <: running sum
    // equals: complicated, see addToRegionCache
    // empty: running count
    // notEquals: bitmap of set pips
    region_cache: [MAX_REGIONS]u8 = @splat(0),
    region_unfilled: [MAX_REGIONS]u8 = @splat(0),
    placed: [MAX_DOMINOES]PlacedDomino,
    placed_len: usize = 0, // Index of the domino to be worked next

    pub fn push(self: *SolverState, l1: Location, l2: Location) void {
        self.placed[self.placed_len] = PlacedDomino{ .l1 = l1, .l2 = l2 };
        self.placed_len += 1;
    }

    pub fn pop(self: *SolverState) PlacedDomino {
        self.placed_len -= 1;
        return self.placed[self.placed_len];
    }
};

test "solver state push and pop" {
    var state = SolverState{
        // SAFETY: will be filled in by push()s
        .placed = undefined,
    };
    state.push(3, 4);
    state.push(5, 6);

    try std.testing.expectEqual(@as(usize, 2), state.placed_len);
    try std.testing.expectEqual(PlacedDomino{ .l1 = 5, .l2 = 6 }, state.pop());
    try std.testing.expectEqual(PlacedDomino{ .l1 = 3, .l2 = 4 }, state.pop());
    try std.testing.expectEqual(@as(usize, 0), state.placed_len);
}

const SearchMode = enum {
    frontier,
    first_solution,
};

fn SearchContext(comptime mode: SearchMode) type {
    return switch (mode) {
        .frontier => struct {
            max_depth: usize,
            states: *std.ArrayList(SolverState),
            allocator: std.mem.Allocator,
        },
        .first_solution => struct {
            halt: *std.atomic.Value(bool),
        },
    };
}

const BranchResult = struct {
    status: SolutionStatus,
    duration_ms: i64,
};

const PuzzleOutput = struct {
    file: []const u8,
    date: []const u8,
    puzzle: []const u8,
    regions: usize,
    dominoes: usize,
    duration_ms: i64,
    branches: []const BranchResult,
};

const Solver = struct {
    puzzle: *Puzzle,
    stats: Stats = .{},
    regions: [MAX_REGIONS]SolverRegion,
    solution: [MAX_Y * MAX_Y]u8 = @splat(InvalidLocation),
    location_to_region_map: [MAX_Y * MAX_Y]usize,
    adjancency_map: [MAX_X * MAX_Y][4]Location,
    region_len: usize,

    const Stats = struct {};

    const InvalidRegion = MAX_REGIONS + 2;

    fn lessThan(context: void, a: Region, b: Region) std.math.Order {
        _ = context;
        return std.math.order(@backingInt(a.type), @backingInt(b.type));
    }

    pub fn init(gpa: std.mem.Allocator, puzzle: *Puzzle) error{OutOfMemory}!Solver {
        var s = Solver{
            .puzzle = puzzle,
            .region_len = puzzle.regions.len,
            // Fill in some reasonable defaults
            .regions = @splat(SolverRegion{ .type = .empty }),
            .location_to_region_map = @splat(InvalidRegion),
            .adjancency_map = @splat(@splat(InvalidLocation)),
        };

        // Prioritize filling certain region types based on the enum's value
        var region_queue: std.PriorityQueue(Region, void, lessThan) = .empty;
        defer region_queue.deinit(gpa);
        for (puzzle.regions) |region| {
            try region_queue.push(gpa, region);
        }

        var region_index: usize = 0;
        while (region_queue.pop()) |region| {
            var sr = SolverRegion{
                .type = region.type,
                .target = region.target,
            };
            try sr.indices.ensureTotalCapacity(gpa, region.indices.len);
            for (region.indices) |i| {
                const loc = coordToLoc(i);
                sr.indices.appendAssumeCapacity(loc);
                s.location_to_region_map[loc] = region_index;
            }
            s.regions[region_index] = sr;
            region_index += 1;
        }
        // Pre-compute adjacent locations
        for (0..GRID_SIZE) |location_usize| {
            const location: u8 = @truncate(location_usize);
            if (s.location_to_region_map[location] == InvalidRegion) continue;
            for (std.enums.values(Orientation), 0..) |orientation, orientation_index| {
                const location_2: Location = switch (orientation) {
                    .right => blk: {
                        if (location % MAX_X == MAX_X - 1) continue;
                        break :blk location + 1;
                    },
                    .left => blk: {
                        if (location % MAX_X == 0) continue;
                        break :blk location - 1;
                    },
                    .down => location + MAX_X,
                    .up => blk: {
                        if (location / MAX_X == 0) continue;
                        break :blk location - MAX_X;
                    },
                };
                if (s.location_to_region_map[location_2] == InvalidRegion) continue;
                s.adjancency_map[location][orientation_index] = location_2;
            }
        }
        for (0..puzzle.dominoes.len) |di| {
            s.solution[coordToLoc(puzzle.solution[di][0])] = puzzle.dominoes[di][0];
            s.solution[coordToLoc(puzzle.solution[di][1])] = puzzle.dominoes[di][1];
        }
        return s;
    }

    pub fn newState(self: *const Solver) SolverState {
        var state = SolverState{
            // SAFETY: will be filled in by push()s
            .placed = undefined,
        };
        for (0..self.region_len) |region_index| {
            const region = self.regions[region_index];
            state.region_unfilled[region_index] = @truncate(region.indices.items.len);
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

    pub fn addToRegionCache(self: *const Solver, state: *SolverState, region_index: usize, pip: u8) bool {
        const r = self.regions[region_index];
        switch (r.type) {
            .sum => {
                if (state.region_cache[region_index] + pip > r.target) return false;
                state.region_cache[region_index] += pip;
                state.region_unfilled[region_index] -= 1;
            },
            .less => {
                if (state.region_cache[region_index] + pip >= r.target) return false;
                state.region_cache[region_index] += pip;
                state.region_unfilled[region_index] -= 1;
            },
            .greater => {
                if (state.region_cache[region_index] + pip * (state.region_unfilled[region_index] * 6) < r.target) return false;
                state.region_cache[region_index] += pip;
                state.region_unfilled[region_index] -= 1;
            },
            .empty => {
                state.region_unfilled[region_index] -= 1;
            },
            .equals => {
                // Use the first 3 bits for the pip. The rest is a
                // running count so that we can know when to remove it
                // entirely.
                const cached_pip: u3 = @truncate(state.region_cache[region_index] >> 5);
                const cached_count: u5 = @truncate(state.region_cache[region_index]);
                if (cached_count == 0) {
                    state.region_cache[region_index] = (@as(u8, pip) << 5) | @as(u8, 1);
                    state.region_unfilled[region_index] -= 1;
                } else if (cached_pip != pip) {
                    return false;
                } else {
                    std.debug.assert(cached_count != 31); // Would corrupt the state if so
                    state.region_cache[region_index] += 1;
                    state.region_unfilled[region_index] -= 1;
                }
            },
            .unequal => {
                const bit_mask: u8 = (@as(u8, 1) << @truncate(pip));
                if (state.region_cache[region_index] & bit_mask == 0) {
                    state.region_cache[region_index] |= bit_mask;
                } else {
                    return false;
                }
                state.region_unfilled[region_index] -= 1;
                return true;
            },
        }
        return true;
    }

    pub fn removeFromRegionCache(self: *const Solver, state: *SolverState, region_index: usize, pip: u8) void {
        const r = self.regions[region_index];
        switch (r.type) {
            .sum, .less, .greater => {
                state.region_cache[region_index] -= pip;
                state.region_unfilled[region_index] += 1;
            },
            .empty => {
                state.region_unfilled[region_index] += 1;
            },
            .equals => {
                // Use the first 3 bits for the pip. The rest is a
                // running count so that we can know when to remove it
                // entirely.
                const cached_count: u5 = @truncate(state.region_cache[region_index]);
                if (cached_count == 1) {
                    state.region_cache[region_index] = 0;
                    state.region_unfilled[region_index] += 1;
                } else {
                    state.region_cache[region_index] -= 1;
                    state.region_unfilled[region_index] += 1;
                }
            },
            .unequal => {
                const bit_mask: u8 = (@as(u8, 1) << @truncate(pip));
                state.region_cache[region_index] &= ~bit_mask;
                state.region_unfilled[region_index] += 1;
            },
        }
    }

    pub fn addToCache(self: *const Solver, state: *SolverState, d: Domino, region_index_1: usize, region_index_2: usize) bool {
        if (!self.addToRegionCache(state, region_index_1, d[0])) return false;
        if (self.addToRegionCache(state, region_index_2, d[1])) {
            return true;
        }
        self.removeFromRegionCache(state, region_index_1, d[0]); // roll back first insert
        return false;
    }

    // Assumes that the removal is legit, and doesn't check status
    pub fn removeFromCache(self: *const Solver, state: *SolverState, d: Domino, region_index_1: usize, region_index_2: usize) void {
        self.removeFromRegionCache(state, region_index_1, d[0]);
        self.removeFromRegionCache(state, region_index_2, d[1]);
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

    pub fn generateFrontier(self: *const Solver, state: *SolverState, max_depth: usize, states: *std.ArrayList(SolverState), allocator: std.mem.Allocator) void {
        var context = SearchContext(.frontier){
            .max_depth = max_depth,
            .states = states,
            .allocator = allocator,
        };
        _ = self.search(state, .frontier, &context);
    }

    pub fn solveFirst(self: *const Solver, state: *SolverState, halt: *std.atomic.Value(bool)) SolutionStatus {
        var context = SearchContext(.first_solution){ .halt = halt };
        return self.search(state, .first_solution, &context);
    }

    fn search(self: *const Solver, state: *SolverState, comptime mode: SearchMode, context: *SearchContext(mode)) SolutionStatus {
        if (comptime mode == .first_solution) {
            if (context.halt.load(.acquire)) return .Halted;
        }

        const domino = self.puzzle.dominoes[state.placed_len];
        for (0..self.region_len) |region_index_1| {
            if (comptime mode == .first_solution) {
                if (context.halt.load(.acquire)) return .Halted;
            }
            const region = self.regions[region_index_1];
            for (region.indices.items) |location_1| {
                // Check l1 before calculating l2
                if (state.locations[location_1] != UnsetPip) continue;
                outer: for (std.enums.values(Orientation), 0..) |orientation, orientation_index| {

                    // Don't check twin pips twice
                    if (domino[0] == domino[1] and (orientation == .left or orientation == .up)) continue :outer;

                    const location_2: Location = self.adjancency_map[location_1][orientation_index];

                    if (location_2 == InvalidLocation) continue :outer;

                    if (state.locations[location_2] != UnsetPip) continue :outer;

                    const region_index_2 = self.location_to_region_map[location_2];
                    if (region_index_1 == region_index_2 and (orientation == .left or orientation == .up)) continue :outer;

                    if (!self.addToCache(state, domino, region_index_1, region_index_2)) continue :outer;

                    state.locations[location_1] = domino[0];
                    state.locations[location_2] = domino[1];

                    state.push(location_1, location_2);
                    const validated = self.validate(state);
                    switch (validated) {
                        .InvalidBranch => {
                            state.locations[location_1] = UnsetPip;
                            state.locations[location_2] = UnsetPip;
                            self.removeFromCache(state, domino, region_index_1, region_index_2);
                            _ = state.pop();
                            continue :outer;
                        },
                        .NotSolved => {
                            if (comptime mode == .frontier) {
                                if (state.placed_len == context.max_depth) {
                                    context.states.append(context.allocator, state.*) catch continue :outer;
                                    state.locations[location_1] = UnsetPip;
                                    state.locations[location_2] = UnsetPip;
                                    self.removeFromCache(state, domino, region_index_1, region_index_2);
                                    _ = state.pop();
                                    continue :outer;
                                }
                            }
                            switch (self.search(state, mode, context)) {
                                .Solved => return .Solved,
                                .InvalidBranch, .NotSolved => {
                                    state.locations[location_1] = UnsetPip;
                                    state.locations[location_2] = UnsetPip;
                                    self.removeFromCache(state, domino, region_index_1, region_index_2);
                                    _ = state.pop();
                                    continue :outer;
                                },
                                .Halted => {
                                    state.locations[location_1] = UnsetPip;
                                    state.locations[location_2] = UnsetPip;
                                    self.removeFromCache(state, domino, region_index_1, region_index_2);
                                    _ = state.pop();
                                    return .Halted;
                                },
                            }
                        },
                        .Solved => {
                            if (comptime mode == .first_solution) context.halt.store(true, .release);
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

    pub fn validate(self: *const Solver, state: *SolverState) SolutionStatus {
        if (state.placed_len == self.puzzle.dominoes.len) {
            for (0..self.region_len) |region_index| {
                const region = self.regions[region_index];
                switch (region.type) {
                    .empty => {
                        // If we're full, we can assume all pips are filled
                        std.debug.assert(state.region_unfilled[region_index] == 0);
                    },
                    .greater => {
                        if (state.region_cache[region_index] <= region.target) {
                            return .InvalidBranch;
                        }
                    },
                    .sum => {
                        if (state.region_cache[region_index] != region.target) {
                            return .InvalidBranch;
                        }
                    },
                    .less, .equals, .unequal => {
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

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var files = std.ArrayList([:0]const u8).empty;
    defer files.deinit(allocator);

    // easy, medium, hard
    var solve_select: [3]bool = .{ false, false, false };
    var multithreaded: bool = true;

    var args = init.minimal.args.iterate();
    _ = args.next(); // Skip $0
    while (args.next()) |arg| {
        if (arg[0] == '-' and arg[1] == '-') {
            if (std.mem.eql(u8, arg, "--easy")) {
                solve_select[0] = true;
            } else if (std.mem.eql(u8, arg, "--medium")) {
                solve_select[1] = true;
            } else if (std.mem.eql(u8, arg, "--hard")) {
                solve_select[2] = true;
            } else if (std.mem.eql(u8, arg, "--all")) {
                solve_select = .{ true, true, true };
            } else if (std.mem.eql(u8, arg, "--single")) {
                multithreaded = false;
            }
        } else {
            try files.append(allocator, arg);
        }
    }

    // Solve all when no flags
    if (!solve_select[0] and !solve_select[1] and !solve_select[2]) {
        solve_select = .{ true, true, true };
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

        try validatePuzzle(&parsed.value.easy);
        try validatePuzzle(&parsed.value.medium);
        try validatePuzzle(&parsed.value.hard);

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

            const start = std.Io.Clock.real.now(t_io.io());
            var solver = try Solver.init(allocator, &puzzle);
            defer solver.deinit(allocator);

            var sol_state = solver.newState();
            var states = std.ArrayList(SolverState).empty;
            defer states.deinit(allocator);

            var branch_results = std.ArrayList(BranchResult).empty;
            defer branch_results.deinit(allocator);

            if (multithreaded) {
                solver.generateFrontier(&sol_state, 1, &states, allocator);
                try branch_results.resize(allocator, states.items.len);
            } else {
                try states.append(allocator, sol_state);
                try branch_results.resize(allocator, 1);
            }

            var halt = std.atomic.Value(bool).init(false);
            for (states.items, branch_results.items) |*state, *result| {
                group.async(t_io.io(), solve, .{ t_io.io(), &solver, state, result, &halt });
            }
            try group.await(t_io.io());
            const end = std.Io.Clock.real.now(t_io.io());

            try std.json.Stringify.value(PuzzleOutput{
                .file = file,
                .date = parsed.value.printDate,
                .puzzle = puzzle_name,
                .regions = puzzle.regions.len,
                .dominoes = puzzle.dominoes.len,
                .duration_ms = start.durationTo(end).toMilliseconds(),
                .branches = branch_results.items,
            }, .{}, stdout);
            try stdout.writeByte('\n');
            try stdout.flush();
        }
    }
}

pub fn solve(io: std.Io, solver: *Solver, state: *SolverState, result: *BranchResult, halt: *std.atomic.Value(bool)) std.Io.Cancelable!void {
    const start = std.Io.Clock.real.now(io);
    const solution = solver.solveFirst(state, halt);
    const end = std.Io.Clock.real.now(io);

    result.* = .{
        .status = solution,
        .duration_ms = start.durationTo(end).toMilliseconds(),
    };
}
