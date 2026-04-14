# Building MySQL Server with Intel ICX Compiler

This guide covers building MySQL from source using the Intel oneAPI DPC++/C++ Compiler (icx/icpx) with LTO, and optionally with Hardware Profile-Guided Optimization (HWPGO).

## Prerequisites

### System Packages

```bash
sudo apt-get install bison pkg-config libncurses5-dev libssl-dev libaio-dev
```

### Intel oneAPI Compiler

Install the Intel oneAPI Base and HPC Toolkit. The scripts expect the compiler at `/opt/intel/oneapi/compiler/latest/`.

Load the environment before running any script:

```bash
source /opt/intel/oneapi/setvars.sh
```

### HammerDB (for benchmarking and HWPGO training)

Download and install HammerDB 5.0. The scripts expect it at `~/mysql/HammerDB-5.0/`.

### Linux perf (for HWPGO only)

```bash
sudo apt-get install linux-tools-$(uname -r)
```

## Source Patches

Before building, one patch is required in `CMakeLists.txt` line 632 to recognize the Intel compiler:

```cmake
# Change this:
IF(CMAKE_CXX_COMPILER_ID MATCHES "Clang")
# To this:
IF(CMAKE_CXX_COMPILER_ID MATCHES "Clang|IntelLLVM")
```

With LTO enabled, explicit template instantiations for `Dictionary_client::foreach` are also needed in `sql/dd/impl/cache/dictionary_client.cc` to avoid undefined symbol errors at link time. See the existing explicit instantiation block near line 2783 in that file.

## Scripts

### 1. `build_mysql_icx.sh` -- Build with ICX + LTO

Builds MySQL with the Intel compiler, Granite Rapids target optimizations (`-xGRANITERAPIDS`), LTO, and lld linker.

**Configuration** (edit at the top of the script):

| Variable    | Description                        | Default                              |
|-------------|------------------------------------|--------------------------------------|
| `SRCDIR`    | Path to mysql-server source        | `/home/shuchen1/mysql/mysql-server`  |
| `BUILDDIR`  | Build directory                    | `$SRCDIR/build_icx_gnr_lto`         |
| `INSTALLDIR`| Installation destination (DESTDIR) | `~/mysql/installation/mysql_icx_gnr_lto` |
| `ARCH_FLAGS`| Target architecture flags          | `-xGRANITERAPIDS`                    |
| `NPROC`     | Parallel build jobs                | `50`                                 |

**Usage:**

```bash
./build_mysql_icx.sh
```

The MySQL binaries will be installed at `$INSTALLDIR/usr/local/mysql/`.

### 2. `test_mysql_hammerdb.sh` -- Test the ICX build

Starts the MySQL server built by `build_mysql_icx.sh`, runs a HammerDB TPC-C benchmark, and reports TPM/NOPM.

**Configuration** (edit at the top of the script):

| Variable    | Description                        | Default                              |
|-------------|------------------------------------|--------------------------------------|
| `BASEDIR`   | MySQL installation base            | `$INSTALLDIR/usr/local/mysql`        |
| `DATADIR`   | MySQL data directory               | `~/mysql/data_icx_gnr_lto`          |
| `SOCKET`    | Unix socket path                   | `/tmp/mysql_icx.sock`                |
| `PORT`      | TCP port                           | `3307`                               |
| `WAREHOUSES`| TPC-C warehouses (data size)       | `16`                                 |
| `VU_TEST`   | Virtual users for benchmark        | `16`                                 |
| `RAMPUP`    | Warmup time in minutes             | `1`                                  |
| `DURATION`  | Test duration in minutes           | `3`                                  |

**Usage:**

```bash
./test_mysql_hammerdb.sh
```

Look for **NOPM** (New Orders Per Minute) in the output -- this is the standard TPC-C metric.

### 3. `build_mysql_icx_hwpgo.sh` -- Build with ICX + LTO + HWPGO

Performs a Hardware Profile-Guided Optimization build in 3 phases that can be run independently:

| Phase  | Description |
|--------|-------------|
| phase1 | Build MySQL with `-fprofile-sample-generate` (adds DWARF debug info, no instrumentation penalty) |
| phase2 | Start MySQL under `perf record`, run a HammerDB TPC-C training workload to collect PMU samples (`branches` + `branch-misses`), and convert to two LLVM profiles: execution frequency (`mysqld.freq.prof`) and branch mispredictions (`mysqld.misp.prof`) |
| phase3 | Rebuild MySQL with `-fprofile-sample-use` and `-mllvm -unpredictable-hints-file` to apply both profiles |

**Configuration** (edit at the top of the script):

| Variable          | Description                          | Default                              |
|-------------------|--------------------------------------|--------------------------------------|
| `SRCDIR`          | Path to mysql-server source          | `/home/shuchen1/mysql/mysql-server`  |
| `BUILDDIR_PHASE1` | Phase 1 build directory              | `$SRCDIR/build_icx_gnr_lto_hwpgo_phase1` |
| `BUILDDIR_PHASE3` | Phase 3 build directory              | `$SRCDIR/build_icx_gnr_lto_hwpgo_phase3` |
| `INSTALLDIR_PHASE1`| Phase 1 installation (for training) | `~/mysql/installation/mysql_icx_gnr_lto_hwpgo_phase1` |
| `INSTALLDIR_FINAL`| Final HWPGO installation             | `~/mysql/installation/mysql_icx_gnr_lto_hwpgo` |
| `PROFILE_DIR`     | Where perf data and profiles are stored | `~/mysql/hwpgo_profiles`          |
| `ARCH_FLAGS`      | Target architecture flags            | `-xGRANITERAPIDS`                    |
| `WAREHOUSES`      | Training workload warehouses         | `16`                                 |
| `VU_TEST`         | Training workload virtual users      | `16`                                 |
| `RAMPUP`          | Training ramp-up minutes             | `1`                                  |
| `DURATION`        | Training duration minutes            | `3`                                  |
| `SAMPLE_PERIOD`   | Perf sampling period                 | `1000003`                            |

**Usage:**

```bash
# Run each phase independently:
./build_mysql_icx_hwpgo.sh phase1    # Build with debug info for profiling
./build_mysql_icx_hwpgo.sh phase2    # Collect profile + convert to LLVM profiles
./build_mysql_icx_hwpgo.sh phase3    # Rebuild with profile feedback

# Or run all phases sequentially:
./build_mysql_icx_hwpgo.sh all
```

Each phase validates its prerequisites (e.g. phase2 checks that the phase1 binary exists, phase3 checks that the profile files exist).

For a more representative profile, increase `WAREHOUSES` (e.g. 100), `VU_TEST` (e.g. 64), and `DURATION` (e.g. 5-10).

### 4. `test_mysql_hwpgo_hammerdb.sh` -- Test the HWPGO build

Starts the MySQL server built by `build_mysql_icx_hwpgo.sh`, runs a HammerDB TPC-C benchmark, and reports TPM/NOPM. Uses a separate data directory, socket, and port so it can coexist with the plain ICX test.

**Configuration** (edit at the top of the script):

| Variable    | Description                        | Default                              |
|-------------|------------------------------------|--------------------------------------|
| `INSTALLDIR`| HWPGO MySQL installation           | `~/mysql/installation/mysql_icx_gnr_lto_hwpgo` |
| `DATADIR`   | MySQL data directory               | `~/mysql/data_icx_gnr_lto_hwpgo`   |
| `SOCKET`    | Unix socket path                   | `/tmp/mysql_hwpgo_test.sock`         |
| `PORT`      | TCP port                           | `3309`                               |

**Usage:**

```bash
./test_mysql_hwpgo_hammerdb.sh
```
