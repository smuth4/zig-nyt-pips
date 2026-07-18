# zig-nyt-pips

A small brute-forcer for the New York Times Pips puzzle: https://www.nytimes.com/games/pips

It's not nearly as efficient as it could be yet, as I'm mostly just having fun going through the optimization process.

# Requirements

- zig master (0.17.0-dev.1422+e863bf3be)

# Usage

First you'll have to download the puzzle data from the NYT API (which is free): https://www.nytimes.com/svc/pips/v1/2026-07-18.json

Then the binary can be run against it:
```shell
zig build
./zig-out/bin/zig_nyt_pips 2026-07-18.json
```
