#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# =============================================================
#  BENCHMARK SETTINGS (shared by all bench scripts)
#  Adjust these to tune the workload. The bench scripts read
#  them via BENCH_* environment variables.
# =============================================================

# -- HammerDB workload --
export BENCH_WAREHOUSES=60       # TPC-C warehouses (data size; should be >= VU_TEST)
export BENCH_VU_BUILD=16         # Virtual users for schema build (parallel loading)
export BENCH_VU_TEST=60          # Virtual users during benchmark (concurrency)
export BENCH_RAMPUP=1            # Ramp-up time in minutes
export BENCH_DURATION=1          # Measurement duration in minutes
export BENCH_RUNS=5              # Number of benchmark runs per configuration

# -- CPU pinning --
export BENCH_CPUS="0-3"          # CPU cores for mysqld (via taskset)

# -- MySQL / InnoDB tuning --
export BENCH_BUFFER_POOL="8G"    # innodb-buffer-pool-size (must cover working set to stay CPU-bound)
export BENCH_REDO_LOG="2G"       # innodb-redo-log-capacity
export BENCH_FLUSH_METHOD="O_DIRECT"          # innodb-flush-method
export BENCH_FLUSH_LOG_AT_TRX="1"             # innodb-flush-log-at-trx-commit (1=safest, 2=faster)
export BENCH_MAX_CONNECTIONS="256"             # max-connections
export BENCH_TABLE_OPEN_CACHE="4000"           # table-open-cache

# -- Log file prefixes (bench scripts append _runN.log) --
LOG_DIR=/tmp
LOG_PREFIX_COMMUNITY=${LOG_DIR}/hammerdb_community
LOG_PREFIX_ICX=${LOG_DIR}/hammerdb_icx
LOG_PREFIX_HWPGO=${LOG_DIR}/hammerdb_hwpgo

# =============================================================
#  Run all three benchmarks sequentially
# =============================================================
echo "=============================================="
echo " MySQL HammerDB Benchmark Suite"
echo "=============================================="
echo ""
echo " Settings:"
echo "   Warehouses:          $BENCH_WAREHOUSES"
echo "   Virtual Users:       $BENCH_VU_TEST"
echo "   Ramp-up:             ${BENCH_RAMPUP} min"
echo "   Duration:            ${BENCH_DURATION} min"
echo "   Runs per config:     $BENCH_RUNS"
echo "   CPU cores:           $BENCH_CPUS"
echo "   Buffer Pool:         $BENCH_BUFFER_POOL"
echo "   Redo Log Capacity:   $BENCH_REDO_LOG"
echo "   Flush Method:        $BENCH_FLUSH_METHOD"
echo "   Flush Log at Commit: $BENCH_FLUSH_LOG_AT_TRX"
echo "   Max Connections:     $BENCH_MAX_CONNECTIONS"
echo "   Table Open Cache:    $BENCH_TABLE_OPEN_CACHE"
echo ""

echo ">>> [1/3] MySQL Community 8.4.8 ..."
echo ""
"$SCRIPT_DIR/bench_mysql_community.sh"
echo ""

echo ">>> [2/3] ICX + LTO ..."
echo ""
"$SCRIPT_DIR/bench_mysql_icx.sh"
echo ""

echo ">>> [3/3] ICX + LTO + HWPGO ..."
echo ""
"$SCRIPT_DIR/bench_mysql_icx_hwpgo.sh"
echo ""

# =============================================================
#  Helpers
# =============================================================
extract_nopm() {
    grep -oP 'System achieved \K[0-9]+(?= NOPM)' "$1" 2>/dev/null | tail -1
}

extract_tpm() {
    grep -oP 'from \K[0-9]+(?= MySQL TPM)' "$1" 2>/dev/null | tail -1
}

calc_avg() {
    # args: value1 value2 ... valueN
    local sum=0 count=0
    for v in "$@"; do
        if [[ "$v" =~ ^[0-9]+$ ]]; then
            sum=$((sum + v))
            count=$((count + 1))
        fi
    done
    if [ "$count" -gt 0 ]; then
        awk "BEGIN { printf \"%d\", $sum / $count }"
    else
        echo "N/A"
    fi
}

calc_min() {
    local min=""
    for v in "$@"; do
        if [[ "$v" =~ ^[0-9]+$ ]]; then
            if [ -z "$min" ] || [ "$v" -lt "$min" ]; then
                min=$v
            fi
        fi
    done
    echo "${min:-N/A}"
}

calc_max() {
    local max=""
    for v in "$@"; do
        if [[ "$v" =~ ^[0-9]+$ ]]; then
            if [ -z "$max" ] || [ "$v" -gt "$max" ]; then
                max=$v
            fi
        fi
    done
    echo "${max:-N/A}"
}

calc_speedup() {
    local baseline="$1"
    local value="$2"
    if [[ "$baseline" == "N/A" || "$value" == "N/A" || "$baseline" == "0" ]]; then
        echo "N/A"
    else
        awk "BEGIN { printf \"%.1f%%\", (($value - $baseline) / $baseline) * 100 }"
    fi
}

# =============================================================
#  Collect per-run results
# =============================================================
NOPM_COMMUNITY_RUNS=()
NOPM_ICX_RUNS=()
NOPM_HWPGO_RUNS=()
TPM_COMMUNITY_RUNS=()
TPM_ICX_RUNS=()
TPM_HWPGO_RUNS=()

for i in $(seq 1 "$BENCH_RUNS"); do
    NOPM_COMMUNITY_RUNS+=("$(extract_nopm "${LOG_PREFIX_COMMUNITY}_run${i}.log")")
    NOPM_ICX_RUNS+=("$(extract_nopm "${LOG_PREFIX_ICX}_run${i}.log")")
    NOPM_HWPGO_RUNS+=("$(extract_nopm "${LOG_PREFIX_HWPGO}_run${i}.log")")
    TPM_COMMUNITY_RUNS+=("$(extract_tpm "${LOG_PREFIX_COMMUNITY}_run${i}.log")")
    TPM_ICX_RUNS+=("$(extract_tpm "${LOG_PREFIX_ICX}_run${i}.log")")
    TPM_HWPGO_RUNS+=("$(extract_tpm "${LOG_PREFIX_HWPGO}_run${i}.log")")
done

# Averages
AVG_NOPM_COMMUNITY=$(calc_avg "${NOPM_COMMUNITY_RUNS[@]}")
AVG_NOPM_ICX=$(calc_avg "${NOPM_ICX_RUNS[@]}")
AVG_NOPM_HWPGO=$(calc_avg "${NOPM_HWPGO_RUNS[@]}")
AVG_TPM_COMMUNITY=$(calc_avg "${TPM_COMMUNITY_RUNS[@]}")
AVG_TPM_ICX=$(calc_avg "${TPM_ICX_RUNS[@]}")
AVG_TPM_HWPGO=$(calc_avg "${TPM_HWPGO_RUNS[@]}")

# Min / Max
MIN_NOPM_COMMUNITY=$(calc_min "${NOPM_COMMUNITY_RUNS[@]}")
MIN_NOPM_ICX=$(calc_min "${NOPM_ICX_RUNS[@]}")
MIN_NOPM_HWPGO=$(calc_min "${NOPM_HWPGO_RUNS[@]}")
MAX_NOPM_COMMUNITY=$(calc_max "${NOPM_COMMUNITY_RUNS[@]}")
MAX_NOPM_ICX=$(calc_max "${NOPM_ICX_RUNS[@]}")
MAX_NOPM_HWPGO=$(calc_max "${NOPM_HWPGO_RUNS[@]}")
MIN_TPM_COMMUNITY=$(calc_min "${TPM_COMMUNITY_RUNS[@]}")
MIN_TPM_ICX=$(calc_min "${TPM_ICX_RUNS[@]}")
MIN_TPM_HWPGO=$(calc_min "${TPM_HWPGO_RUNS[@]}")
MAX_TPM_COMMUNITY=$(calc_max "${TPM_COMMUNITY_RUNS[@]}")
MAX_TPM_ICX=$(calc_max "${TPM_ICX_RUNS[@]}")
MAX_TPM_HWPGO=$(calc_max "${TPM_HWPGO_RUNS[@]}")

# Speedups (based on averages)
NOPM_ICX_SPEEDUP=$(calc_speedup "$AVG_NOPM_COMMUNITY" "$AVG_NOPM_ICX")
NOPM_HWPGO_SPEEDUP=$(calc_speedup "$AVG_NOPM_COMMUNITY" "$AVG_NOPM_HWPGO")
TPM_ICX_SPEEDUP=$(calc_speedup "$AVG_TPM_COMMUNITY" "$AVG_TPM_ICX")
TPM_HWPGO_SPEEDUP=$(calc_speedup "$AVG_TPM_COMMUNITY" "$AVG_TPM_HWPGO")

# =============================================================
#  Print configuration
# =============================================================
echo ""
echo "=============================================="
echo " BENCHMARK CONFIGURATION"
echo "=============================================="
echo ""
echo " HammerDB:                          MySQL Server:"
echo "   Benchmark:     TPC-C               CPU cores:          $BENCH_CPUS (taskset)"
echo "   Warehouses:    $BENCH_WAREHOUSES                  Buffer Pool:        $BENCH_BUFFER_POOL"
echo "   Virtual Users: $BENCH_VU_TEST                  Redo Log:           $BENCH_REDO_LOG"
echo "   Ramp-up:       ${BENCH_RAMPUP} min               Flush Method:       $BENCH_FLUSH_METHOD"
echo "   Duration:      ${BENCH_DURATION} min               Flush at Commit:    $BENCH_FLUSH_LOG_AT_TRX"
echo "   Runs:          $BENCH_RUNS                    Max Connections:    $BENCH_MAX_CONNECTIONS"
echo "                                      Table Open Cache:   $BENCH_TABLE_OPEN_CACHE"
echo ""

# =============================================================
#  Print per-run details
# =============================================================
echo "=============================================="
echo " PER-RUN RESULTS"
echo "=============================================="
echo ""
printf "%-6s  %15s %15s %15s  |  %15s %15s %15s\n" \
       "Run" "Community NOPM" "ICX NOPM" "HWPGO NOPM" "Community TPM" "ICX TPM" "HWPGO TPM"
printf "%-6s  %15s %15s %15s  |  %15s %15s %15s\n" \
       "---" "----------" "--------" "----------" "----------" "-------" "---------"
for i in $(seq 1 "$BENCH_RUNS"); do
    idx=$((i - 1))
    printf "%-6s  %15s %15s %15s  |  %15s %15s %15s\n" \
           "  $i" \
           "${NOPM_COMMUNITY_RUNS[$idx]:-N/A}" "${NOPM_ICX_RUNS[$idx]:-N/A}" "${NOPM_HWPGO_RUNS[$idx]:-N/A}" \
           "${TPM_COMMUNITY_RUNS[$idx]:-N/A}" "${TPM_ICX_RUNS[$idx]:-N/A}" "${TPM_HWPGO_RUNS[$idx]:-N/A}"
done
echo ""

# =============================================================
#  Print summary comparison
# =============================================================
echo "=============================================="
echo " THROUGHPUT COMPARISON  (${BENCH_RUNS} runs)"
echo "=============================================="
echo ""
printf "%-28s %15s %15s %15s\n" "" "Community 8.4.8" "ICX+LTO" "ICX+LTO+HWPGO"
printf "%-28s %15s %15s %15s\n" "" "------------" "-------" "-------------"
printf "%-28s %15s %15s %15s\n" "NOPM avg" "$AVG_NOPM_COMMUNITY" "$AVG_NOPM_ICX" "$AVG_NOPM_HWPGO"
printf "%-28s %15s %15s %15s\n" "NOPM min" "$MIN_NOPM_COMMUNITY" "$MIN_NOPM_ICX" "$MIN_NOPM_HWPGO"
printf "%-28s %15s %15s %15s\n" "NOPM max" "$MAX_NOPM_COMMUNITY" "$MAX_NOPM_ICX" "$MAX_NOPM_HWPGO"
printf "%-28s %15s %15s %15s\n" "TPM  avg" "$AVG_TPM_COMMUNITY" "$AVG_TPM_ICX" "$AVG_TPM_HWPGO"
printf "%-28s %15s %15s %15s\n" "TPM  min" "$MIN_TPM_COMMUNITY" "$MIN_TPM_ICX" "$MIN_TPM_HWPGO"
printf "%-28s %15s %15s %15s\n" "TPM  max" "$MAX_TPM_COMMUNITY" "$MAX_TPM_ICX" "$MAX_TPM_HWPGO"
echo ""
printf "%-28s %15s %15s %15s\n" "NOPM vs Community (avg)" "--" "$NOPM_ICX_SPEEDUP" "$NOPM_HWPGO_SPEEDUP"
printf "%-28s %15s %15s %15s\n" "TPM  vs Community (avg)" "--" "$TPM_ICX_SPEEDUP" "$TPM_HWPGO_SPEEDUP"
echo ""

# =============================================================
#  Print latency comparison (last run of each)
# =============================================================
extract_latency_field() {
    # Usage: extract_latency_field <logfile> <txn_type> <field>
    # e.g. extract_latency_field log.txt NEWORD p50_ms
    local logfile="$1" txn="$2" field="$3"
    grep -A 2 "\"$txn\"" "$logfile" 2>/dev/null | grep -oP "\"$field\":\s*\"?\K[0-9.]+" | head -1
}

echo "=============================================="
echo " LATENCY COMPARISON (ms, last run)"
echo "=============================================="
echo ""

LAST_LOG_COMMUNITY="${LOG_PREFIX_COMMUNITY}_run${BENCH_RUNS}.log"
LAST_LOG_ICX="${LOG_PREFIX_ICX}_run${BENCH_RUNS}.log"
LAST_LOG_HWPGO="${LOG_PREFIX_HWPGO}_run${BENCH_RUNS}.log"

for TXN in NEWORD PAYMENT DELIVERY SLEV OSTAT; do
    echo "  $TXN:"
    printf "    %-10s %15s %15s %15s\n" "" "Community" "ICX+LTO" "ICX+LTO+HWPGO"
    for METRIC in avg_ms p50_ms p95_ms p99_ms; do
        V_COMM=$(extract_latency_field "$LAST_LOG_COMMUNITY" "$TXN" "$METRIC")
        V_ICX=$(extract_latency_field "$LAST_LOG_ICX" "$TXN" "$METRIC")
        V_HWPGO=$(extract_latency_field "$LAST_LOG_HWPGO" "$TXN" "$METRIC")
        printf "    %-10s %15s %15s %15s\n" "$METRIC" "${V_COMM:-N/A}" "${V_ICX:-N/A}" "${V_HWPGO:-N/A}"
    done
    echo ""
done

echo ""
echo "=============================================="
echo " Log files: ${LOG_PREFIX_COMMUNITY}_run{1..${BENCH_RUNS}}.log"
echo "            ${LOG_PREFIX_ICX}_run{1..${BENCH_RUNS}}.log"
echo "            ${LOG_PREFIX_HWPGO}_run{1..${BENCH_RUNS}}.log"
echo "=============================================="

# =============================================================
#  Generate comparison chart
# =============================================================
PLOT_SCRIPT="$SCRIPT_DIR/plot_benchmark_results.py"
if [ -f "$PLOT_SCRIPT" ]; then
    echo ""
    echo "Generating benchmark comparison chart..."
    python3 "$PLOT_SCRIPT" && echo "Chart saved." || echo "Warning: chart generation failed"
fi
