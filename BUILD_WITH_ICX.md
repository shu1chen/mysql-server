# Building MySQL Server with Intel ICX Compiler

This guide covers building MySQL from source using the Intel oneAPI DPC++/C++ Compiler (icx/icpx) with LTO, and optionally with Hardware Profile-Guided Optimization (HWPGO).

## Prerequisites

### System Packages

```bash
sudo apt-get install bison pkg-config libncurses5-dev libssl-dev libaio-dev
```

### Intel oneAPI Compiler

Install the Intel oneAPI Toolkit. The scripts expect the compiler at `/opt/intel/oneapi/compiler/latest/` and set `RPATH` to the oneAPI runtime libraries so the built MySQL binaries can find them at load time.

Load the environment before running any script:

```bash
source /opt/intel/oneapi/setvars.sh
```

### Boost

Boost sources are required by the MySQL build system. The scripts set `-DWITH_BOOST` and `-DDOWNLOAD_BOOST=1`, so cmake will download Boost automatically into the configured `BOOSTDIR` if it is not already present.

### HammerDB (for benchmarking and HWPGO training)

Download and install HammerDB 5.0. The scripts expect it at `~/workspace/mysql/HammerDB-5.0/`.

### Linux perf (for HWPGO only)

```bash
sudo apt-get install linux-tools-$(uname -r)
```

## Source Patches

With LTO enabled, explicit template instantiations for `Dictionary_client::foreach` are needed in `sql/dd/impl/cache/dictionary_client.cc` to avoid undefined symbol errors at link time. The following instantiations must be added to the explicit instantiation block near the end of that file (before the `@endcond` marker):

```cpp
template bool Dictionary_client::foreach<Schema>(
    const Object_key *,
    std::function<bool(std::unique_ptr<Schema> &)> const &) const;
template bool Dictionary_client::foreach<Table>(
    const Object_key *,
    std::function<bool(std::unique_ptr<Table> &)> const &) const;
template bool Dictionary_client::foreach<Tablespace>(
    const Object_key *,
    std::function<bool(std::unique_ptr<Tablespace> &)> const &) const;
template bool Dictionary_client::foreach<Event>(
    const Object_key *,
    std::function<bool(std::unique_ptr<Event> &)> const &) const;
template bool Dictionary_client::foreach<Routine>(
    const Object_key *,
    std::function<bool(std::unique_ptr<Routine> &)> const &) const;
template bool Dictionary_client::foreach<View>(
    const Object_key *,
    std::function<bool(std::unique_ptr<View> &)> const &) const;
```

## Scripts

### 1. `build_mysql_icx.sh` -- Build with ICX + LTO

Builds MySQL with the Intel compiler, `-O3 -xGRANITERAPIDS` optimizations, LTO, and lld linker. Uses `CMAKE_INSTALL_PREFIX` for installation and sets up oneAPI RPATH so the binaries find Intel runtime libraries at load time.

**Configuration** (edit at the top of the script):

| Variable     | Description                        | Default                              |
|--------------|------------------------------------|--------------------------------------|
| `SRCDIR`     | Path to mysql-server source        | `/home/shuchen1/workspace/mysql/mysql-server`  |
| `BUILDDIR`   | Build directory                    | `$SRCDIR/build_icx_gnr_lto`         |
| `INSTALLDIR` | Installation prefix                | `~/workspace/mysql/installation/mysql_icx_gnr_lto` |
| `BOOSTDIR`   | Boost source directory             | `~/workspace/mysql/boost`                      |
| `ARCH_FLAGS` | Target architecture flags          | `-xGRANITERAPIDS`                    |
| `ONEAPI_LIB` | oneAPI library paths for RPATH     | `/opt/intel/oneapi/compiler/latest/lib;/opt/intel/oneapi/latest/lib` |
| `NPROC`      | Parallel build jobs                | `50`                                 |

**Usage:**

```bash
./build_mysql_icx.sh
```

The MySQL binaries will be installed at `$INSTALLDIR/` (e.g. `$INSTALLDIR/bin/mysqld`).

### 2. `bench_mysql_icx.sh` -- Benchmark the ICX build

Starts the MySQL server built by `build_mysql_icx.sh`, pins it to a fixed set of CPU cores, runs a HammerDB TPC-C benchmark for N iterations, and reports per-run NOPM/TPM.

### 3. `build_mysql_icx_hwpgo.sh` -- Build with ICX + LTO + HWPGO

### 3. `build_mysql_icx_hwpgo.sh` -- Build with ICX + LTO + HWPGO

Performs a Hardware Profile-Guided Optimization build in 5 phases that can be run independently. The process collects execution frequency profiles, branch misprediction hints, and MIR-level machine profiles with call graph ordering to maximize the benefit of profile feedback.

| Phase  | Description |
|--------|-------------|
| phase1 | Build ICX base with LTO + `-fprofile-sample-generate` (adds pseudo-probes for profiling, no instrumentation penalty) |
| phase2 | Start the Phase 1 MySQL server, attach `perf record` with PMU events (`BR_INST_RETIRED.NEAR_TAKEN:uppp` + `BR_MISP_RETIRED.ALL_BRANCHES:upp`), run a HammerDB TPC-C training workload, then convert to two LLVM profiles: execution frequency (`mysqld.freq.prof`) and branch mispredictions (`mysqld.misp.prof`) |
| phase3 | Build ICX MIR base with LTO + `-fprofile-sample-use` (freq profile), `-mllvm -unpredictable-hints-file` (mispredict profile), and `-mllvm -machine-pseudo-probe-for-profiling=pre-ra` |
| phase4 | Start the Phase 3 MIR MySQL server, attach `perf record` with `BR_INST_RETIRED.NEAR_TAKEN:uppp`, run a HammerDB TPC-C training workload, then generate a MIR profile (`mysqld.mir.prof`) and call graph (`mysql.mir.cg`) |
| phase5 | Build final ICX MIR HWPGO with LTO + all profiles + MIR machine profile + call graph ordering + `-ffunction-sections` |

**Configuration** (edit at the top of the script):

| Variable           | Description                          | Default                              |
|--------------------|--------------------------------------|--------------------------------------|
| `SRCDIR`           | Path to mysql-server source          | `/home/shuchen1/workspace/mysql/mysql-server`  |
| `BOOSTDIR`         | Boost source directory               | `~/workspace/mysql/boost`                      |
| `BUILDDIR_PHASE1`  | Phase 1 build directory              | `$SRCDIR/build_icx_gnr_lto_hwpgo_phase1` |
| `INSTALLDIR_PHASE1`| Phase 1 installation (for profiling) | `~/workspace/mysql/installation/mysql_icx_gnr_lto_hwpgo_phase1` |
| `BUILDDIR_PHASE3`  | Phase 3 (MIR) build directory        | `$SRCDIR/build_icx_gnr_lto_hwpgo_mir` |
| `INSTALLDIR_PHASE3`| Phase 3 (MIR) installation           | `~/workspace/mysql/installation/mysql_icx_gnr_lto_hwpgo_mir` |
| `BUILDDIR_PHASE5`  | Phase 5 (final) build directory      | `$SRCDIR/build_icx_gnr_lto_hwpgo_final` |
| `INSTALLDIR_FINAL` | Final HWPGO installation             | `~/workspace/mysql/installation/mysql_icx_gnr_lto_hwpgo` |
| `PROFILE_DIR`      | Where perf data and profiles are stored | `~/workspace/mysql/hwpgo_profiles`          |
| `ARCH_FLAGS`       | Target architecture flags            | `-xGRANITERAPIDS`                    |
| `ONEAPI_LIB`       | oneAPI library paths for RPATH       | `/opt/intel/oneapi/compiler/latest/lib;/opt/intel/oneapi/latest/lib` |
| `LLVM_PROFGEN`     | Path to llvm-profgen tool            | `/opt/intel/oneapi/compiler/latest/bin/compiler/llvm-profgen` |
| `WAREHOUSES`       | Training workload warehouses         | `60`                                 |
| `VU_TEST`          | Training workload virtual users      | `60`                                 |
| `RAMPUP`           | Training ramp-up minutes             | `1`                                  |
| `DURATION`         | Training duration minutes            | `3`                                  |
| `SAMPLE_PERIOD`    | Perf sampling period                 | `1000003`                            |

**Profiles generated:**

| File              | Phase | Description |
|-------------------|-------|-------------|
| `mysqld.freq.prof`| 2     | Execution frequency profile from `BR_INST_RETIRED.NEAR_TAKEN:uppp` |
| `mysqld.misp.prof`| 2     | Branch misprediction hints from `BR_MISP_RETIRED.ALL_BRANCHES:upp` |
| `mysqld.mir.prof` | 4     | MIR-level machine sample profile |
| `mysql.mir.cg`    | 4     | Call graph for function ordering via `--call-graph-ordering-file` |

**Usage:**

```bash
# Run each phase independently:
./build_mysql_icx_hwpgo.sh phase1    # Build ICX base for profiling
./build_mysql_icx_hwpgo.sh phase2    # Profile ICX base -> freq + misp profiles
./build_mysql_icx_hwpgo.sh phase3    # Build MIR base with freq + misp profiles
./build_mysql_icx_hwpgo.sh phase4    # Profile MIR base -> MIR profile + call graph
./build_mysql_icx_hwpgo.sh phase5    # Build final HWPGO with all profiles

# Or run all phases sequentially:
./build_mysql_icx_hwpgo.sh all
```

Each phase validates its prerequisites (e.g. phase2 checks that the phase1 binary exists, phase5 checks that all four profile files exist).

For a more representative profile, increase `WAREHOUSES` (e.g. 100), `VU_TEST` (e.g. 64), and `DURATION` (e.g. 5-10).

### 4. `bench_mysql_icx_hwpgo.sh` -- Benchmark the HWPGO build

Starts the MySQL server built by `build_mysql_icx_hwpgo.sh` and runs the same benchmark.

### 5. `bench_mysql_community.sh` -- Benchmark MySQL Community 8.4.8

Starts the MySQL Community 8.4.8 binary (pre-built, not compiled from source) as a baseline.

### 6. `run_all_benchmarks.sh` -- Run all benchmarks and compare

Runs all three benchmark scripts sequentially (Community baseline, ICX, HWPGO), each for N iterations, and prints a comparison summary with avg/min/max NOPM/TPM, percentage speedup vs baseline, and latency profiles.

All benchmark settings are centralized in `run_all_benchmarks.sh` and passed to the bench scripts via `BENCH_*` environment variables. Each bench script also has standalone defaults so it can be run independently.

**Benchmark settings** (edit at the top of `run_all_benchmarks.sh`):

| Environment Variable       | Description                          | Default      |
|----------------------------|--------------------------------------|--------------|
| `BENCH_WAREHOUSES`         | TPC-C warehouses (should be >= VU_TEST) | `60`      |
| `BENCH_VU_BUILD`           | Virtual users for schema build       | `16`         |
| `BENCH_VU_TEST`            | Virtual users during benchmark       | `60`         |
| `BENCH_RAMPUP`             | Ramp-up time in minutes              | `1`          |
| `BENCH_DURATION`           | Measurement duration in minutes      | `1`          |
| `BENCH_RUNS`               | Number of benchmark runs per config  | `5`          |
| `BENCH_CPUS`               | CPU cores for mysqld (via taskset)   | `0-3`        |
| `BENCH_BUFFER_POOL`        | `innodb-buffer-pool-size`            | `8G`         |
| `BENCH_REDO_LOG`           | `innodb-redo-log-capacity`           | `2G`         |
| `BENCH_FLUSH_METHOD`       | `innodb-flush-method`                | `O_DIRECT`   |
| `BENCH_FLUSH_LOG_AT_TRX`   | `innodb-flush-log-at-trx-commit`     | `1`          |
| `BENCH_MAX_CONNECTIONS`    | `max-connections`                    | `256`        |
| `BENCH_TABLE_OPEN_CACHE`   | `table-open-cache`                   | `4000`       |

**Key settings that affect performance:**

- **`BENCH_BUFFER_POOL`** — most impactful; when large enough to hold the TPC-C working set in memory, the workload becomes CPU-bound, which is where compiler optimizations (LTO, HWPGO) show the greatest benefit
- **`BENCH_VU_TEST`** — drives concurrency; more virtual users means more contention and CPU scheduling pressure
- **`BENCH_CPUS`** — constraining CPU cores amplifies per-core efficiency differences between builds
- **`BENCH_FLUSH_LOG_AT_TRX`** — `1` = fsync every commit (I/O-bound); `2` = async flush (more CPU-bound, better for showing compiler speedup)
- **`BENCH_WAREHOUSES`** — data size; must be >= `VU_TEST` to avoid hot-spot lock contention

**Usage:**

```bash
# Run the full benchmark suite (all 3 configs x 5 runs each)
./run_all_benchmarks.sh

# Or run an individual benchmark standalone
./bench_mysql_community.sh
./bench_mysql_icx.sh
./bench_mysql_icx_hwpgo.sh

# Override settings for a quick single-run test
BENCH_RUNS=1 BENCH_VU_TEST=16 BENCH_WAREHOUSES=16 ./run_all_benchmarks.sh
```

Results logs are saved to `/tmp/hammerdb_{community,icx,hwpgo}_run{1..N}.log`.
