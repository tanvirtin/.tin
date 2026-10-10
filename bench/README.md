# YAML Parser Benchmarks

This directory contains performance benchmarks for the project's YAML parser.

## Usage

Benchmark data lives in `bench/data/` (committed to the repo).

```bash
zig build bench -Doptimize=ReleaseFast
```

## Benchmarks

- **Large List (50k items):** Tests scanner and composer efficiency with sequences.
- **Large Map (50k keys):** Tests mapping lookup and allocation patterns.
- **Deeply Nested (1000 levels):** Tests recursion depth and stack usage.
- **Large Recipe (5k steps):** A realistic test case representing scaled-up project data.
- **Chaos:** Anchors, quotes, block scalars, flow collections, and complex keys.

## Metrics

- **Time (ms):** Average time taken to parse the entire file.
- **Throughput (MB/s):** Processing speed relative to file size.
- **TOTAL PERFORMANCE SCORE:** The sum of average execution times for all benchmarks in seconds. This is the primary metric for tracking performance improvements. **Lower is better.**
