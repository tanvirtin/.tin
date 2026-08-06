# YAML Parser Benchmarks

This directory contains performance benchmarks for the project's YAML parser.

## Usage

### 1. Generate Benchmark Data
Before running benchmarks, you need to generate the synthetic test files:
```bash
zig run bench/generate_data.zig
```

### 2. Run Benchmarks
Run the suite using the Zig build system. It is recommended to use `ReleaseFast` for representative results:
```bash
zig build bench -Doptimize=ReleaseFast
```

## Benchmarks

- **Large List (10k items):** Tests scanner and composer efficiency with sequences.
- **Large Map (10k keys):** Tests mapping lookup and allocation patterns.
- **Deeply Nested (500 levels):** Tests recursion depth and stack usage.
- **Large Recipe (1k steps):** A realistic test case representing scaled-up project data.

## Metrics

- **Time (ms):** Average time taken to parse the entire file.
- **Throughput (MB/s):** Processing speed relative to file size.
- **TOTAL PERFORMANCE SCORE:** The sum of average execution times for all benchmarks in seconds. This is the primary metric for tracking performance improvements. **Lower is better.**
