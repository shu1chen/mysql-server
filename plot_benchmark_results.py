#!/usr/bin/env python3
"""
MySQL Benchmark Visualization: Community 8.4.8 vs ICX+LTO+HWPGO
Parses HammerDB log files and generates comparison charts.
"""

import re
import json
import os
import statistics
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.ticker as ticker
import numpy as np

# ─── Configuration ───────────────────────────────────────────────────────────
LOG_DIR = "/tmp"
CONFIGS = {
    "Community 8.4.8": {
        "prefix": "hammerdb_community",
        "color": "#8B8B8B",
        "accent": "#AAAAAA",
    },
    "ICX + LTO + HWPGO": {
        "prefix": "hammerdb_hwpgo",
        "color": "#0071C5",       # Intel blue
        "accent": "#00AEEF",
    },
}
TXN_TYPES = ["NEWORD", "PAYMENT", "DELIVERY", "SLEV", "OSTAT"]
TXN_LABELS = {
    "NEWORD": "New Order",
    "PAYMENT": "Payment",
    "DELIVERY": "Delivery",
    "SLEV": "Stock Level",
    "OSTAT": "Order Status",
}
OUTPUT_DIR = "/home/shuchen1/workspace/mysql/mysql-server"
_timestamp = __import__("datetime").datetime.now().strftime("%Y%m%d_%H%M%S")
OUTPUT_FILE = os.path.join(OUTPUT_DIR, f"benchmark_results_{_timestamp}.png")


# ─── Parsing ─────────────────────────────────────────────────────────────────
def parse_nopm_tpm(log_path):
    """Extract NOPM and TPM from a HammerDB log file."""
    nopm, tpm = None, None
    with open(log_path, "r") as f:
        for line in f:
            m = re.search(r"System achieved (\d+) NOPM from (\d+) MySQL TPM", line)
            if m:
                nopm, tpm = int(m.group(1)), int(m.group(2))
    return nopm, tpm


def parse_timing_json(log_path):
    """Extract timing JSON block from a HammerDB log file."""
    with open(log_path, "r") as f:
        content = f.read()
    # Find the JSON block after TRANSACTION RESPONSE TIMES
    m = re.search(r"TRANSACTION RESPONSE TIMES\s*\n(\{.+?\n\})", content, re.DOTALL)
    if m:
        try:
            return json.loads(m.group(1))
        except json.JSONDecodeError:
            pass
    return None


def load_timing_from_hammerdb():
    """Load timing data from HammerDB job database dump.

    Runs hammerdbcli to extract all job results and timing, then
    returns a dict mapping NOPM -> timing_dict for matching.
    """
    import subprocess
    hammerdb = "/home/shuchen1/workspace/mysql/HammerDB-5.0"
    tcl_script = os.path.join(LOG_DIR, "_dump_timing.tcl")
    dump_file = os.path.join(LOG_DIR, "_hammerdb_dump.txt")

    # Write TCL extraction script
    with open(tcl_script, "w") as f:
        f.write(
            'set alljobs [jobs joblist]\n'
            'set count [llength $alljobs]\n'
            'for {set i 0} {$i < $count} {incr i} {\n'
            '    set jid [lindex $alljobs $i]\n'
            '    puts "===RESULT:$jid==="\n'
            '    jobs $jid result\n'
            '    puts "===TIMING:$jid==="\n'
            '    jobs $jid timing\n'
            '}\n'
        )

    try:
        # Try pre-generated dump first (faster), fall back to live query
        if os.path.exists(dump_file) and os.path.getsize(dump_file) > 100:
            with open(dump_file) as f:
                raw = f.read()
        else:
            result = subprocess.run(
                [os.path.join(hammerdb, "hammerdbcli"), "auto", tcl_script],
                capture_output=True, text=True, timeout=60,
            )
            raw = result.stdout
            with open(dump_file, "w") as f:
                f.write(raw)
    except Exception as e:
        print(f"  Warning: Could not query HammerDB job database: {e}")
        return {}

    # Parse output: match NOPM values to timing data
    nopm_to_timing = {}
    current_jid = None
    current_nopm = None
    in_timing = False
    timing_lines = []

    for line in raw.splitlines():
        if line.startswith("===RESULT:"):
            current_nopm = None
            in_timing = False
            timing_lines = []
        elif line.startswith("===TIMING:"):
            in_timing = True
            timing_lines = []
            continue

        if not in_timing:
            m = re.search(r"System achieved (\d+) NOPM", line)
            if m:
                current_nopm = int(m.group(1))
        else:
            timing_lines.append(line)

    # Parse timing blocks by splitting on markers and extracting JSON
    # by brace-depth counting
    sections = re.split(r"(===(?:RESULT|TIMING):[^=]+=+)", raw)
    current_nopm = None
    for section in sections:
        # Check for NOPM in result sections
        m = re.search(r"System achieved (\d+) NOPM", section)
        if m:
            current_nopm = int(m.group(1))

        # Extract JSON by finding balanced braces
        if current_nopm and "{" in section and "avg_ms" in section:
            start = section.index("{")
            depth = 0
            end = start
            for j in range(start, len(section)):
                if section[j] == "{":
                    depth += 1
                elif section[j] == "}":
                    depth -= 1
                    if depth == 0:
                        end = j + 1
                        break
            try:
                timing = json.loads(section[start:end])
                if any("avg_ms" in v for v in timing.values()
                       if isinstance(v, dict)):
                    nopm_to_timing[current_nopm] = timing
            except (json.JSONDecodeError, ValueError):
                pass

    return nopm_to_timing


def collect_data():
    """Collect NOPM/TPM and latency data from all log files."""
    # First try to get timing from HammerDB job database
    print("  Querying HammerDB job database for timing data...")
    nopm_to_timing = load_timing_from_hammerdb()
    if nopm_to_timing:
        print(f"  Found timing data for {len(nopm_to_timing)} jobs")
    else:
        print("  No timing data from job database, will try log files")

    data = {}
    for label, cfg in CONFIGS.items():
        runs_nopm, runs_tpm = [], []
        runs_timing = []
        for i in range(1, 100):
            path = os.path.join(LOG_DIR, f"{cfg['prefix']}_run{i}.log")
            if not os.path.exists(path):
                break
            nopm, tpm = parse_nopm_tpm(path)
            if nopm is not None:
                runs_nopm.append(nopm)
                runs_tpm.append(tpm)
            # Try log file first, fall back to job database
            timing = parse_timing_json(path)
            if not timing and nopm in nopm_to_timing:
                timing = nopm_to_timing[nopm]
            if timing:
                runs_timing.append(timing)
        data[label] = {
            "nopm": runs_nopm,
            "tpm": runs_tpm,
            "timing": runs_timing,
            "color": cfg["color"],
            "accent": cfg["accent"],
        }
    return data


# ─── Plotting ────────────────────────────────────────────────────────────────
def setup_style():
    """Set up a clean, professional plotting style."""
    plt.rcParams.update({
        "font.family": "sans-serif",
        "font.sans-serif": ["DejaVu Sans", "Arial", "Helvetica"],
        "font.size": 11,
        "axes.titlesize": 14,
        "axes.titleweight": "bold",
        "axes.labelsize": 12,
        "axes.spines.top": False,
        "axes.spines.right": False,
        "figure.facecolor": "white",
        "axes.facecolor": "white",
        "axes.grid": True,
        "grid.alpha": 0.3,
        "grid.linestyle": "--",
    })


def add_value_labels(ax, bars, fmt="{:,.0f}", offset=0.01, fontsize=10):
    """Add value labels on top of bars."""
    ymax = ax.get_ylim()[1]
    for bar in bars:
        height = bar.get_height()
        ax.text(
            bar.get_x() + bar.get_width() / 2.0,
            height + ymax * offset,
            fmt.format(height),
            ha="center", va="bottom", fontsize=fontsize, fontweight="bold",
        )


def plot_throughput(ax, data):
    """Plot NOPM throughput comparison with individual run points."""
    labels = list(data.keys())
    avgs = [statistics.mean(data[l]["nopm"]) for l in labels]
    colors = [data[l]["color"] for l in labels]

    bars = ax.bar(labels, avgs, width=0.5, color=colors, edgecolor="white",
                  linewidth=1.5, zorder=3)

    # Overlay individual run points
    for i, label in enumerate(labels):
        runs = data[label]["nopm"]
        jitter = np.random.default_rng(42).uniform(-0.08, 0.08, len(runs))
        ax.scatter(
            [i + j for j in jitter], runs,
            color="white", edgecolors=data[label]["color"],
            s=40, zorder=4, linewidths=1.5, alpha=0.9,
        )

    add_value_labels(ax, bars)

    # Speedup annotation
    if len(avgs) == 2 and avgs[0] > 0:
        pct = (avgs[1] - avgs[0]) / avgs[0] * 100
        color = "#2E7D32" if pct > 0 else "#C62828"
        sign = "+" if pct > 0 else ""
        ax.annotate(
            f"{sign}{pct:.1f}%",
            xy=(1, avgs[1]), xytext=(1.35, avgs[1] * 0.92),
            fontsize=16, fontweight="bold", color=color,
            arrowprops=dict(arrowstyle="->", color=color, lw=2),
            bbox=dict(boxstyle="round,pad=0.3", facecolor=color, alpha=0.1,
                      edgecolor=color),
        )

    ax.set_ylabel("New Orders Per Minute (NOPM)")
    ax.set_title("Throughput (NOPM)")
    ax.yaxis.set_major_formatter(ticker.FuncFormatter(lambda x, p: f"{x:,.0f}"))
    ax.set_ylim(0, max(avgs) * 1.18)


def plot_tpm(ax, data):
    """Plot TPM throughput comparison."""
    labels = list(data.keys())
    avgs = [statistics.mean(data[l]["tpm"]) for l in labels]
    colors = [data[l]["color"] for l in labels]

    bars = ax.bar(labels, avgs, width=0.5, color=colors, edgecolor="white",
                  linewidth=1.5, zorder=3)

    for i, label in enumerate(labels):
        runs = data[label]["tpm"]
        jitter = np.random.default_rng(42).uniform(-0.08, 0.08, len(runs))
        ax.scatter(
            [i + j for j in jitter], runs,
            color="white", edgecolors=data[label]["color"],
            s=40, zorder=4, linewidths=1.5, alpha=0.9,
        )

    add_value_labels(ax, bars)

    if len(avgs) == 2 and avgs[0] > 0:
        pct = (avgs[1] - avgs[0]) / avgs[0] * 100
        color = "#2E7D32" if pct > 0 else "#C62828"
        sign = "+" if pct > 0 else ""
        ax.annotate(
            f"{sign}{pct:.1f}%",
            xy=(1, avgs[1]), xytext=(1.35, avgs[1] * 0.92),
            fontsize=16, fontweight="bold", color=color,
            arrowprops=dict(arrowstyle="->", color=color, lw=2),
            bbox=dict(boxstyle="round,pad=0.3", facecolor=color, alpha=0.1,
                      edgecolor=color),
        )

    ax.set_ylabel("Transactions Per Minute (TPM)")
    ax.set_title("Throughput (TPM)")
    ax.yaxis.set_major_formatter(ticker.FuncFormatter(lambda x, p: f"{x:,.0f}"))
    ax.set_ylim(0, max(avgs) * 1.18)


def plot_latency_comparison(ax, data):
    """Plot latency comparison (avg ms) per transaction type."""
    labels = list(data.keys())
    # Use the last run's timing for each config
    timings = {}
    for label in labels:
        if data[label]["timing"]:
            timings[label] = data[label]["timing"][-1]
        else:
            timings[label] = None

    txn_types = [t for t in TXN_TYPES if all(
        timings.get(l) and t in timings[l] for l in labels
    )]
    if not txn_types:
        ax.text(0.5, 0.5, "No latency data available", transform=ax.transAxes,
                ha="center", va="center", fontsize=14, color="gray")
        ax.set_title("Avg Latency by Transaction Type")
        return

    x = np.arange(len(txn_types))
    width = 0.35

    for i, label in enumerate(labels):
        vals = [float(timings[label][t]["avg_ms"]) for t in txn_types]
        offset = (i - 0.5) * width
        bars = ax.bar(x + offset, vals, width * 0.9, label=label,
                      color=data[label]["color"], edgecolor="white",
                      linewidth=1, zorder=3)
        for bar, val in zip(bars, vals):
            ax.text(bar.get_x() + bar.get_width() / 2, bar.get_height() + 0.2,
                    f"{val:.1f}", ha="center", va="bottom", fontsize=8,
                    fontweight="bold")

    # Show improvement percentage above each pair
    if len(labels) == 2:
        for j, t in enumerate(txn_types):
            comm_val = float(timings[labels[0]][t]["avg_ms"])
            hwpgo_val = float(timings[labels[1]][t]["avg_ms"])
            if comm_val > 0:
                pct = (comm_val - hwpgo_val) / comm_val * 100
                if pct > 0:
                    ax.text(j, max(comm_val, hwpgo_val) + 1.2,
                            f"-{pct:.0f}%", ha="center", fontsize=9,
                            fontweight="bold", color="#2E7D32")

    ax.set_xticks(x)
    ax.set_xticklabels([TXN_LABELS.get(t, t) for t in txn_types])
    ax.set_ylabel("Avg Latency (ms)")
    ax.set_title("Avg Latency by Transaction Type (lower is better)")
    ax.legend(loc="upper right", framealpha=0.9)


def plot_latency_percentiles(ax, data):
    """Plot P50/P95/P99 for the key NEWORD transaction."""
    labels = list(data.keys())
    timings = {}
    for label in labels:
        if data[label]["timing"]:
            timings[label] = data[label]["timing"][-1]
        else:
            timings[label] = None

    if not all(timings.get(l) and "NEWORD" in timings[l] for l in labels):
        ax.text(0.5, 0.5, "No latency data available", transform=ax.transAxes,
                ha="center", va="center", fontsize=14, color="gray")
        ax.set_title("New Order Latency Percentiles")
        return

    percentiles = ["p50_ms", "p95_ms", "p99_ms"]
    pct_labels = ["P50", "P95", "P99"]
    x = np.arange(len(percentiles))
    width = 0.35

    for i, label in enumerate(labels):
        vals = [float(timings[label]["NEWORD"][p]) for p in percentiles]
        offset = (i - 0.5) * width
        bars = ax.bar(x + offset, vals, width * 0.9, label=label,
                      color=data[label]["color"], edgecolor="white",
                      linewidth=1, zorder=3)
        for bar, val in zip(bars, vals):
            ax.text(bar.get_x() + bar.get_width() / 2, bar.get_height() + 0.15,
                    f"{val:.1f}", ha="center", va="bottom", fontsize=9,
                    fontweight="bold")

    # Show improvement percentage for each percentile
    if len(labels) == 2:
        for j, p in enumerate(percentiles):
            comm_val = float(timings[labels[0]]["NEWORD"][p])
            hwpgo_val = float(timings[labels[1]]["NEWORD"][p])
            if comm_val > 0:
                pct = (comm_val - hwpgo_val) / comm_val * 100
                if pct > 0:
                    ax.text(j, max(comm_val, hwpgo_val) + 1.0,
                            f"-{pct:.0f}%", ha="center", fontsize=11,
                            fontweight="bold", color="#2E7D32")

    ax.set_xticks(x)
    ax.set_xticklabels(pct_labels)
    ax.set_ylabel("Latency (ms)")
    ax.set_title("New Order Latency Percentiles (lower is better)")
    ax.legend(loc="upper left", framealpha=0.9)


def create_figure(data):
    """Create the full benchmark comparison figure."""
    setup_style()

    fig = plt.figure(figsize=(18, 14))
    fig.patch.set_facecolor("white")

    # Title
    fig.suptitle(
        "MySQL TPC-C Performance on Intel Granite Rapids\n"
        "Community 8.4.8 vs Intel Compiler Optimized (ICX + LTO + HWPGO)",
        fontsize=18, fontweight="bold", y=0.98,
    )

    # Subtitle with test config
    num_runs = len(list(data.values())[0]["nopm"])
    fig.text(
        0.5, 0.935,
        f"HammerDB TPC-C  |  60 Virtual Users  |  60 Warehouses  |"
        f"  4 CPU cores (taskset 0-3)  |  8 GB Buffer Pool  |  {num_runs} runs",
        ha="center", fontsize=10, color="#555555",
        bbox=dict(boxstyle="round,pad=0.4", facecolor="#F5F5F5",
                  edgecolor="#DDDDDD"),
    )

    gs = fig.add_gridspec(2, 2, hspace=0.35, wspace=0.3, top=0.90, bottom=0.06,
                          left=0.07, right=0.95)

    ax1 = fig.add_subplot(gs[0, 0])
    ax2 = fig.add_subplot(gs[0, 1])
    ax3 = fig.add_subplot(gs[1, 0])
    ax4 = fig.add_subplot(gs[1, 1])

    plot_throughput(ax1, data)
    plot_tpm(ax2, data)
    plot_latency_comparison(ax3, data)
    plot_latency_percentiles(ax4, data)

    return fig


# ─── Main ────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    print("Collecting benchmark data...")
    data = collect_data()

    for label, d in data.items():
        n = len(d["nopm"])
        if n == 0:
            print(f"  WARNING: No data found for {label}")
            continue
        avg_nopm = statistics.mean(d["nopm"])
        avg_tpm = statistics.mean(d["tpm"])
        print(f"  {label}: {n} runs, avg NOPM={avg_nopm:.0f}, avg TPM={avg_tpm:.0f}")

    print("\nGenerating charts...")
    fig = create_figure(data)
    fig.savefig(OUTPUT_FILE, dpi=150, bbox_inches="tight")
    print(f"Saved to {OUTPUT_FILE}")
