#!/usr/bin/env python3
"""
FlashOrder – k6 Results Visualiser
────────────────────────────────────────────────────────────────────────────
Reads k6 JSON output files (produced with  k6 run --out json=results.json)
and generates a side-by-side comparison chart saved as results/comparison.png

Usage:
    python3 k6/generate-report.py \
        --microservices results/load-microservices.json \
        --monolith      results/load-monolith.json \
        --output        results/comparison.png

Requirements:
    pip install matplotlib numpy

Produces:
    • Bar charts for p50/p95/p99 latency
    • RPS comparison
    • Error rate comparison
    • Orders created timeline (if data is rich enough)
"""

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

try:
    import matplotlib
    matplotlib.use('Agg')   # non-interactive backend for servers / Docker
    import matplotlib.pyplot as plt
    import matplotlib.patches as mpatches
    import numpy as np
except ImportError:
    print("[ERROR] matplotlib / numpy not installed.")
    print("        Run:  pip install matplotlib numpy")
    sys.exit(1)


# ── Colours ──────────────────────────────────────────────────────────────────
COLOR_MS   = '#2196F3'   # blue   – microservices
COLOR_MONO = '#FF5722'   # red    – monolith
COLOR_OK   = '#4CAF50'
COLOR_WARN = '#FF9800'
COLOR_ERR  = '#F44336'


# ── k6 JSON parser ────────────────────────────────────────────────────────────

def parse_k6_json(filepath: str) -> Dict[str, Any]:
    """
    k6 --out json produces one JSON object per line (NDJSON).
    We collect all metric_sample points and summarise them.
    """
    if not Path(filepath).exists():
        raise FileNotFoundError(f"Results file not found: {filepath}")

    durations: List[float] = []
    http_reqs: int = 0
    errors: int = 0
    start_ts: Optional[float] = None
    end_ts: Optional[float] = None

    with open(filepath, 'r', encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue

            if obj.get('type') != 'Point':
                continue

            metric = obj.get('metric', '')
            ts     = obj.get('data', {}).get('time')
            value  = obj.get('data', {}).get('value', 0)

            if ts:
                epoch = _parse_ts(ts)
                if start_ts is None or epoch < start_ts:
                    start_ts = epoch
                if end_ts is None or epoch > end_ts:
                    end_ts = epoch

            if metric == 'http_req_duration':
                durations.append(float(value))
            elif metric == 'http_reqs':
                http_reqs += int(value)
            elif metric in ('http_req_failed', 'error_rate'):
                errors += int(value)

    if not durations:
        raise ValueError(f"No http_req_duration samples found in {filepath}. "
                         "Did you use  k6 run --out json=<file>?")

    arr       = np.array(durations)
    total_sec = max((end_ts - start_ts) if (start_ts and end_ts) else 1, 1)
    rps       = http_reqs / total_sec
    err_pct   = (errors / max(http_reqs, 1)) * 100

    return {
        'p50':        float(np.percentile(arr, 50)),
        'p95':        float(np.percentile(arr, 95)),
        'p99':        float(np.percentile(arr, 99)),
        'max':        float(arr.max()),
        'mean':       float(arr.mean()),
        'rps':        round(rps, 2),
        'total_reqs': http_reqs,
        'error_pct':  round(err_pct, 2),
        'samples':    len(durations),
        'durations':  durations,
    }


def _parse_ts(ts_str: str) -> float:
    """Parse RFC3339 timestamp to epoch float (basic)."""
    import datetime
    try:
        dt = datetime.datetime.fromisoformat(ts_str.replace('Z', '+00:00'))
        return dt.timestamp()
    except Exception:
        return 0.0


# ── Chart builders ────────────────────────────────────────────────────────────

def build_comparison_chart(
    ms:     Dict[str, Any],
    mono:   Dict[str, Any],
    output: str,
) -> None:
    fig = plt.figure(figsize=(18, 12))
    fig.patch.set_facecolor('#1a1a2e')

    title_style = dict(color='white', fontsize=13, fontweight='bold', pad=12)
    ax_style    = dict(facecolor='#16213e')
    tick_style  = dict(colors='#aaaacc', labelsize=10)

    def style_ax(ax, title):
        ax.set_facecolor('#16213e')
        ax.set_title(title, **title_style)
        ax.tick_params(axis='both', **tick_style)
        for spine in ax.spines.values():
            spine.set_edgecolor('#333355')
        ax.yaxis.label.set_color('#aaaacc')
        ax.xaxis.label.set_color('#aaaacc')

    # ── 1. Latency comparison (p50 / p95 / p99) ──────────────────────────────
    ax1 = fig.add_subplot(2, 3, 1)
    labels = ['p50', 'p95', 'p99']
    ms_vals   = [ms['p50'],   ms['p95'],   ms['p99']]
    mono_vals = [mono['p50'], mono['p95'], mono['p99']]

    x    = np.arange(len(labels))
    w    = 0.35
    b1   = ax1.bar(x - w/2, ms_vals,   w, label='Microservices', color=COLOR_MS,   alpha=0.85)
    b2   = ax1.bar(x + w/2, mono_vals, w, label='Monolith',       color=COLOR_MONO, alpha=0.85)

    ax1.bar_label(b1, fmt='%.0f ms', padding=3, color='white', fontsize=8)
    ax1.bar_label(b2, fmt='%.0f ms', padding=3, color='white', fontsize=8)
    ax1.set_xticks(x)
    ax1.set_xticklabels(labels)
    ax1.set_ylabel('Latency (ms)')
    ax1.legend(facecolor='#0f3460', labelcolor='white', fontsize=9)
    style_ax(ax1, 'Latency Percentiles')

    # ── 2. RPS comparison ─────────────────────────────────────────────────────
    ax2 = fig.add_subplot(2, 3, 2)
    rps_vals = [ms['rps'], mono['rps']]
    bars = ax2.bar(['Microservices', 'Monolith'], rps_vals,
                   color=[COLOR_MS, COLOR_MONO], alpha=0.85, width=0.5)
    ax2.bar_label(bars, fmt='%.1f rps', padding=3, color='white', fontsize=9)
    ax2.set_ylabel('Requests / second')
    style_ax(ax2, 'Throughput (RPS)')

    # ── 3. Error rate comparison ──────────────────────────────────────────────
    ax3 = fig.add_subplot(2, 3, 3)
    err_vals = [ms['error_pct'], mono['error_pct']]
    colors   = [COLOR_OK if v < 1 else (COLOR_WARN if v < 5 else COLOR_ERR)
                for v in err_vals]
    bars = ax3.bar(['Microservices', 'Monolith'], err_vals,
                   color=colors, alpha=0.85, width=0.5)
    ax3.bar_label(bars, fmt='%.2f %%', padding=3, color='white', fontsize=9)
    ax3.set_ylabel('Error Rate (%)')
    ax3.axhline(y=5, color=COLOR_WARN, linestyle='--', alpha=0.6, label='5 % threshold')
    ax3.legend(facecolor='#0f3460', labelcolor='white', fontsize=9)
    style_ax(ax3, 'Error Rate')

    # ── 4. Latency distribution histogram (microservices) ────────────────────
    ax4 = fig.add_subplot(2, 3, 4)
    ax4.hist(ms['durations'], bins=50, color=COLOR_MS, alpha=0.75, edgecolor='#0d47a1')
    ax4.axvline(ms['p95'], color='yellow', linestyle='--', linewidth=1.5,
                label=f"p95={ms['p95']:.0f}ms")
    ax4.set_xlabel('Latency (ms)')
    ax4.set_ylabel('Count')
    ax4.legend(facecolor='#0f3460', labelcolor='white', fontsize=9)
    style_ax(ax4, 'Microservices – Latency Distribution')

    # ── 5. Latency distribution histogram (monolith) ─────────────────────────
    ax5 = fig.add_subplot(2, 3, 5)
    ax5.hist(mono['durations'], bins=50, color=COLOR_MONO, alpha=0.75, edgecolor='#b71c1c')
    ax5.axvline(mono['p95'], color='yellow', linestyle='--', linewidth=1.5,
                label=f"p95={mono['p95']:.0f}ms")
    ax5.set_xlabel('Latency (ms)')
    ax5.set_ylabel('Count')
    ax5.legend(facecolor='#0f3460', labelcolor='white', fontsize=9)
    style_ax(ax5, 'Monolith – Latency Distribution')

    # ── 6. Summary table ─────────────────────────────────────────────────────
    ax6 = fig.add_subplot(2, 3, 6)
    ax6.axis('off')

    def delta(ms_v, mono_v, lower_is_better=True):
        if mono_v == 0:
            return '—'
        pct = ((ms_v - mono_v) / mono_v) * 100
        arrow = '▼' if (pct < 0) == lower_is_better else '▲'
        color_code = '✓' if (pct < 0) == lower_is_better else '✗'
        return f"{color_code} {abs(pct):.1f}%"

    rows = [
        ['Metric',       'Microservices',             'Monolith',                'Δ'],
        ['RPS',          f"{ms['rps']:.1f}",          f"{mono['rps']:.1f}",      delta(ms['rps'], mono['rps'], lower_is_better=False)],
        ['p50 latency',  f"{ms['p50']:.0f} ms",       f"{mono['p50']:.0f} ms",   delta(ms['p50'], mono['p50'])],
        ['p95 latency',  f"{ms['p95']:.0f} ms",       f"{mono['p95']:.0f} ms",   delta(ms['p95'], mono['p95'])],
        ['p99 latency',  f"{ms['p99']:.0f} ms",       f"{mono['p99']:.0f} ms",   delta(ms['p99'], mono['p99'])],
        ['Error rate',   f"{ms['error_pct']:.2f}%",   f"{mono['error_pct']:.2f}%", delta(ms['error_pct'], mono['error_pct'])],
        ['Total reqs',   str(ms['total_reqs']),        str(mono['total_reqs']),   ''],
    ]

    table = ax6.table(
        cellText=rows[1:],
        colLabels=rows[0],
        cellLoc='center',
        loc='center',
    )
    table.auto_set_font_size(False)
    table.set_fontsize(9)
    table.scale(1.2, 1.8)

    # Style table
    for (row, col), cell in table.get_celld().items():
        if row == 0:
            cell.set_facecolor('#0f3460')
            cell.set_text_props(color='white', fontweight='bold')
        else:
            cell.set_facecolor('#16213e' if row % 2 == 0 else '#1a1a2e')
            cell.set_text_props(color='#ccccdd')
        cell.set_edgecolor('#333355')

    style_ax(ax6, 'Summary Comparison')

    # ── Overall title ─────────────────────────────────────────────────────────
    fig.suptitle(
        'FlashOrder Platform – Microservices vs Monolith\nPerformance Comparison',
        color='white', fontsize=16, fontweight='bold', y=0.98,
    )

    plt.tight_layout(rect=[0, 0, 1, 0.95])

    # Ensure output dir exists
    out_path = Path(output)
    out_path.parent.mkdir(parents=True, exist_ok=True)

    plt.savefig(str(out_path), dpi=150, bbox_inches='tight',
                facecolor=fig.get_facecolor())
    plt.close()
    print(f"[✓] Chart saved → {out_path.resolve()}")


# ── ASCII table (printed to stdout) ───────────────────────────────────────────

def print_ascii_table(ms: Dict[str, Any], mono: Dict[str, Any]) -> None:
    W = 62
    print()
    print('╔' + '═' * W + '╗')
    print('║' + '  FlashOrder – Performance Comparison'.center(W) + '║')
    print('╠' + '═' * 20 + '╦' + '═' * 20 + '╦' + '═' * 20 + '╣')
    print('║' + '  Metric'.ljust(20) + '║' + '  Microservices'.ljust(20) + '║' + '  Monolith'.ljust(20) + '║')
    print('╠' + '═' * 20 + '╬' + '═' * 20 + '╬' + '═' * 20 + '╣')

    rows = [
        ('RPS',           f"{ms['rps']:.2f}",           f"{mono['rps']:.2f}"),
        ('p50 latency',   f"{ms['p50']:.1f} ms",        f"{mono['p50']:.1f} ms"),
        ('p95 latency',   f"{ms['p95']:.1f} ms",        f"{mono['p95']:.1f} ms"),
        ('p99 latency',   f"{ms['p99']:.1f} ms",        f"{mono['p99']:.1f} ms"),
        ('Max latency',   f"{ms['max']:.1f} ms",        f"{mono['max']:.1f} ms"),
        ('Error rate',    f"{ms['error_pct']:.2f} %",   f"{mono['error_pct']:.2f} %"),
        ('Total requests', str(ms['total_reqs']),        str(mono['total_reqs'])),
    ]
    for label, ms_v, mono_v in rows:
        print(f"║  {label:<18}║  {ms_v:<18}║  {mono_v:<18}║")

    print('╚' + '═' * 20 + '╩' + '═' * 20 + '╩' + '═' * 20 + '╝')
    print()


# ── CLI ───────────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(
        description='Generate FlashOrder comparison chart from k6 JSON outputs'
    )
    parser.add_argument(
        '--microservices', '-m',
        default='results/load-microservices.json',
        help='Path to k6 JSON output for microservices (default: results/load-microservices.json)',
    )
    parser.add_argument(
        '--monolith', '-n',
        default='results/load-monolith.json',
        help='Path to k6 JSON output for monolith (default: results/load-monolith.json)',
    )
    parser.add_argument(
        '--output', '-o',
        default='results/comparison.png',
        help='Output PNG path (default: results/comparison.png)',
    )
    parser.add_argument(
        '--ascii-only', '-a',
        action='store_true',
        help='Print ASCII table only, skip chart generation',
    )
    args = parser.parse_args()

    print(f"\n[FlashOrder Report Generator]")
    print(f"  Microservices : {args.microservices}")
    print(f"  Monolith      : {args.monolith}")

    try:
        ms_data   = parse_k6_json(args.microservices)
        mono_data = parse_k6_json(args.monolith)
    except (FileNotFoundError, ValueError) as e:
        print(f"\n[ERROR] {e}")
        sys.exit(1)

    print_ascii_table(ms_data, mono_data)

    if not args.ascii_only:
        build_comparison_chart(ms_data, mono_data, args.output)


if __name__ == '__main__':
    main()
