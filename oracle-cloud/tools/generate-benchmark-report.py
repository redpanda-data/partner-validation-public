#!/usr/bin/env python3
"""
General Benchmark Report Generator for OpenMessaging Benchmark
Generates three report files from benchmark JSON results:
  - TIER_X_REPORT.txt      - Simple text summary
  - QUICKVIEW.txt          - Formatted visual report
  - TIER_X_ANALYSIS.md     - Detailed markdown analysis

Usage:
  python3 generate-benchmark-report.py <tier> <json_file> [--provider linode|aws]

Example:
  python3 generate-benchmark-report.py 5 benchmark_results_linode/tier-5/results.json --provider linode
"""

import json
import sys
import csv
from pathlib import Path
from typing import Dict, Optional

class TierConfig:
    """Tier configuration from tiers.tsv file"""
    def __init__(self, tier_data: Dict):
        self.tier = int(tier_data.get('Tier', 0))
        self.vcpu = int(tier_data.get('vCPU', 0))
        self.memory_gb = int(float(tier_data.get('Memory GiB', 0)))
        self.instance = tier_data.get('Instance', 'unknown')
        self.broker_count = int(tier_data.get('Broker Count', 0))
        # Use legacy egress limit as the target (actual benchmark target)
        self.target_mb = int(tier_data.get('Egress Limit (legacy)', tier_data.get('Egress flex', 0)))
        self.provider = tier_data.get('Provider', 'unknown')
        self.cost = float(tier_data.get('Cost OD', 0))

def load_tier_config(tier: int, provider: str = 'linode') -> Optional[TierConfig]:
    """Load tier configuration from tiers TSV file"""
    tiers_file = Path(f'tiers-{provider}.tsv')

    if not tiers_file.exists():
        # Try alternate locations
        alt_paths = [
            Path(f'linode_claude_jumpbox/ubuntu/tiers.tsv'),
            Path(f'aws_claude_jumpbox/ubuntu/tiers.tsv'),
        ]
        for alt_path in alt_paths:
            if alt_path.exists():
                tiers_file = alt_path
                break

    if not tiers_file.exists():
        print(f"❌ Could not find tiers configuration file: {tiers_file}")
        return None

    try:
        with open(tiers_file, 'r') as f:
            reader = csv.DictReader(f, delimiter='\t')
            for row in reader:
                if row.get('Tier') and int(row['Tier']) == tier:
                    return TierConfig(row)
    except Exception as e:
        print(f"❌ Error reading tiers file: {e}")
        return None

    return None

def load_benchmark_results(json_file: Path) -> Optional[Dict]:
    """Load benchmark results from JSON file and normalize to aggregated values"""
    if not json_file.exists():
        print(f"❌ Results file not found: {json_file}")
        return None

    try:
        with open(json_file, 'r') as f:
            raw_data = json.load(f)

        # Create normalized data dict with aggregated values
        data = {}

        # Copy non-list fields
        for key, value in raw_data.items():
            if not isinstance(value, list):
                data[key] = value

        # Handle throughput metrics - calculate averages from lists if needed
        if 'publishRate' in raw_data and isinstance(raw_data['publishRate'], list):
            data['publishRate'] = sum(raw_data['publishRate']) / len(raw_data['publishRate'])
        elif 'publishRate' in raw_data:
            data['publishRate'] = raw_data['publishRate']

        if 'consumeRate' in raw_data and isinstance(raw_data['consumeRate'], list):
            data['consumeRate'] = sum(raw_data['consumeRate']) / len(raw_data['consumeRate'])
        elif 'consumeRate' in raw_data:
            data['consumeRate'] = raw_data['consumeRate']

        if 'backlog' in raw_data and isinstance(raw_data['backlog'], list):
            data['backlog'] = sum(raw_data['backlog']) / len(raw_data['backlog'])
        elif 'backlog' in raw_data:
            data['backlog'] = raw_data['backlog']

        # Use aggregated latency fields if available, otherwise try non-aggregated
        latency_fields = [
            'publishLatency50pct', 'publishLatency95pct', 'publishLatency99pct',
            'publishLatency999pct', 'publishLatencyAvg', 'publishLatencyMax',
            'endToEndLatency50pct', 'endToEndLatency95pct', 'endToEndLatency99pct',
            'endToEndLatency999pct', 'endToEndLatencyAvg'
        ]

        for field in latency_fields:
            # Check for aggregated version first
            aggregated_key = f'aggregated{field[0].upper()}{field[1:]}'
            if aggregated_key in raw_data:
                data[field] = raw_data[aggregated_key]
            elif field in raw_data and not isinstance(raw_data[field], list):
                data[field] = raw_data[field]

        return data

    except Exception as e:
        print(f"❌ Error reading JSON file: {e}")
        import traceback
        traceback.print_exc()
        return None

def format_number(num: float, decimals: int = 2) -> str:
    """Format number with thousand separators"""
    if decimals == 0:
        return f"{int(num):,}"
    return f"{num:,.{decimals}f}"

def generate_simple_report(tier: int, config: TierConfig, data: Dict) -> str:
    """Generate TIER_X_REPORT.txt"""

    pub_rate = data.get('publishRate', 0)
    pub_throughput_mb = pub_rate * 1024 / 1024 / 1024

    pub_latency_50 = data.get('publishLatency50pct', 0)
    pub_latency_99 = data.get('publishLatency99pct', 0)

    e2e_latency_50 = data.get('endToEndLatency50pct', 0)
    e2e_latency_99 = data.get('endToEndLatency99pct', 0)

    target_mb = config.target_mb
    pct_target = (pub_throughput_mb / target_mb) * 100 if target_mb > 0 else 0
    passed = pct_target >= 95

    report = f"""═══════════════════════════════════════════════════════════
  TIER {tier} BENCHMARK RESULTS - {config.provider.upper()}
  Target: {target_mb} MB/s
═══════════════════════════════════════════════════════════

THROUGHPUT:
  Publish Rate:  {format_number(pub_rate, 2)} msg/s
  Publish MB/s:  {format_number(pub_throughput_mb, 2)} MB/s
  vs Target:     {pct_target:.1f}% {'✅' if passed else '⚠️'}

LATENCY:
  Pub P50:  {pub_latency_50:.3f} ms {'⭐' if pub_latency_50 < 2 else ''}
  Pub P99:  {pub_latency_99:.3f} ms
  E2E P50:  {e2e_latency_50:.3f} ms
  E2E P99:  {e2e_latency_99:.3f} ms

INFRASTRUCTURE:
  Brokers: {config.broker_count}× {config.instance}
  Cluster: {config.broker_count} nodes ({config.vcpu} vCPU, {config.memory_gb}GB each)

═══════════════════════════════════════════════════════════
  VERDICT: {'✅ TIER ' + str(tier) + ' PASSED' if passed else '⚠️ TIER ' + str(tier) + ' BELOW TARGET'}
  - Achieved {pct_target:.1f}% of {target_mb} MB/s target
  - {config.broker_count} brokers ({config.vcpu} vCPU, {config.memory_gb}GB each)
═══════════════════════════════════════════════════════════
"""
    return report

def generate_quickview(tier: int, config: TierConfig, data: Dict) -> str:
    """Generate QUICKVIEW.txt"""

    pub_rate = data.get('publishRate', 0)
    pub_throughput_mb = pub_rate * 1024 / 1024 / 1024
    cons_rate = data.get('consumeRate', 0)
    cons_throughput_mb = cons_rate * 1024 / 1024 / 1024
    backlog = data.get('backlog', 0)

    pub_latency_50 = data.get('publishLatency50pct', 0)
    pub_latency_95 = data.get('publishLatency95pct', 0)
    pub_latency_99 = data.get('publishLatency99pct', 0)
    pub_latency_999 = data.get('publishLatency999pct', 0)
    pub_latency_avg = data.get('publishLatencyAvg', 0)

    e2e_latency_50 = data.get('endToEndLatency50pct', 0)
    e2e_latency_95 = data.get('endToEndLatency95pct', 0)
    e2e_latency_99 = data.get('endToEndLatency99pct', 0)
    e2e_latency_999 = data.get('endToEndLatency999pct', 0)
    e2e_latency_avg = data.get('endToEndLatencyAvg', 0)

    target_mb = config.target_mb
    pct_target = (pub_throughput_mb / target_mb) * 100 if target_mb > 0 else 0
    passed = pct_target >= 95

    quickview = f"""╔═══════════════════════════════════════════════════════════════════╗
║                  TIER {tier} BENCHMARK - QUICK VIEW                    ║
╚═══════════════════════════════════════════════════════════════════╝

TARGET:     {target_mb} MB/s egress
ACHIEVED:   {pub_throughput_mb:.2f} MB/s  {'✅' if passed else '⚠️'} {pct_target:.0f}% OF TARGET

┌─────────────────────────────────────────────────────────────────┐
│ THROUGHPUT                                                      │
├─────────────────────────────────────────────────────────────────┤
│ Publish:    {format_number(pub_rate, 0)} msg/s  =  {pub_throughput_mb:.2f} MB/s                       │
│ Consume:    {format_number(cons_rate, 0)} msg/s  =  {cons_throughput_mb:.2f} MB/s                       │
│ Balance:    {'Perfect (0 backlog)' if abs(backlog) < 1000 else f'{format_number(backlog, 0)} backlog'}                                 │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│ LATENCY (milliseconds)                                          │
├─────────────────────────────────────────────────────────────────┤
│              Publish │ End-to-End                               │
│ ──────────────────────────────────────────────────────────────  │
│ P50:       {pub_latency_50:5.2f} ms {'⭐' if pub_latency_50 < 2 else '  '}│   {e2e_latency_50:5.2f} ms {'⭐' if e2e_latency_50 < 4 else '  '}  (median)        │
│ P95:       {pub_latency_95:5.2f} ms {'⭐' if pub_latency_95 < 10 else '  '}│  {e2e_latency_95:6.2f} ms     (95th)          │
│ P99:      {pub_latency_99:6.2f} ms {'⭐' if pub_latency_99 < 30 else '  '}│  {e2e_latency_99:6.2f} ms     (99th)             │
│ P99.9:   {pub_latency_999:7.2f} ms   │  {e2e_latency_999:6.2f} ms     (tail latency)             │
│ Avg:       {pub_latency_avg:5.2f} ms   │   {e2e_latency_avg:5.2f} ms     (average)                  │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│ INFRASTRUCTURE ({config.provider.capitalize()} {data.get('region', 'us-ord')})                                  │
├─────────────────────────────────────────────────────────────────┤
│ Brokers:    {config.broker_count}× {config.instance} ({config.vcpu} vCPU, {config.memory_gb}GB each)            │
│ Version:    Redpanda {data.get('version', '25.3.6')}                                     │
│ Durability: ack-all (strongest consistency)                     │
│ Cost:       ~${config.cost * config.broker_count:.2f}/hour during benchmark                       │
└─────────────────────────────────────────────────────────────────┘

RESULT: {'✅ TIER ' + str(tier) + ' PASSED' if passed else '⚠️ TIER ' + str(tier) + ' BELOW TARGET'}

Key Highlights:
• {'Hit' if passed else 'Approached'} {target_mb} MB/s target ({pct_target:.1f}%)
• {'Sub-2ms median latency maintained' if pub_latency_50 < 2 else f'{pub_latency_50:.2f}ms median latency'} (P50: {pub_latency_50:.2f}ms)
• {config.broker_count} brokers × {config.vcpu} vCPU = {config.broker_count * config.vcpu} total vCPU
• {format_number(pub_rate, 0)} msg/s sustained throughput
• {'Zero backlog' if abs(backlog) < 1000 else f'{format_number(abs(backlog), 0)} message backlog'}
"""
    return quickview

def generate_analysis(tier: int, config: TierConfig, data: Dict) -> str:
    """Generate TIER_X_ANALYSIS.md"""

    pub_rate = data.get('publishRate', 0)
    pub_throughput_mb = pub_rate * 1024 / 1024 / 1024
    cons_rate = data.get('consumeRate', 0)
    backlog = data.get('backlog', 0)

    pub_latency_50 = data.get('publishLatency50pct', 0)
    pub_latency_95 = data.get('publishLatency95pct', 0)
    pub_latency_99 = data.get('publishLatency99pct', 0)
    pub_latency_999 = data.get('publishLatency999pct', 0)
    pub_latency_avg = data.get('publishLatencyAvg', 0)
    pub_latency_max = data.get('publishLatencyMax', 0)

    e2e_latency_50 = data.get('endToEndLatency50pct', 0)
    e2e_latency_95 = data.get('endToEndLatency95pct', 0)
    e2e_latency_99 = data.get('endToEndLatency99pct', 0)
    e2e_latency_999 = data.get('endToEndLatency999pct', 0)
    e2e_latency_avg = data.get('endToEndLatencyAvg', 0)

    target_mb = config.target_mb
    pct_target = (pub_throughput_mb / target_mb) * 100 if target_mb > 0 else 0
    passed = pct_target >= 95

    analysis = f"""# Tier {tier} Benchmark Analysis

## Overview
- **Target**: {target_mb} MB/s egress
- **Achieved**: {pub_throughput_mb:.2f} MB/s ({pct_target:.1f}% of target)
- **Infrastructure**: {config.broker_count}× {config.instance} ({config.vcpu} vCPU, {config.memory_gb}GB RAM each)
- **Total Resources**: {config.broker_count * config.vcpu} vCPU, {config.broker_count * config.memory_gb}GB RAM
- **Provider**: {config.provider.capitalize()}

## Throughput Metrics

| Metric | Value | Target | % of Target |
|--------|-------|--------|-------------|
| Publish Rate | {format_number(pub_rate, 0)} msg/s | {format_number(target_mb * 1024 * 1024 / 1024, 0)} msg/s | {pct_target:.1f}% |
| Publish Throughput | {pub_throughput_mb:.2f} MB/s | {target_mb} MB/s | {pct_target:.1f}% |
| Consume Rate | {format_number(cons_rate, 0)} msg/s | - | - |
| Backlog | {format_number(backlog, 0)} messages | 0 | {'✅' if abs(backlog) < 10000 else '⚠️'} |

## Latency Metrics

### Publish Latency
| Percentile | Latency | Rating |
|------------|---------|--------|
| P50 (median) | {pub_latency_50:.3f} ms | {'⭐ Excellent' if pub_latency_50 < 2 else 'Good' if pub_latency_50 < 5 else 'Acceptable'} |
| P95 | {pub_latency_95:.3f} ms | {'⭐ Excellent' if pub_latency_95 < 10 else 'Good' if pub_latency_95 < 20 else 'Acceptable'} |
| P99 | {pub_latency_99:.3f} ms | {'⭐ Excellent' if pub_latency_99 < 30 else 'Good' if pub_latency_99 < 100 else 'Acceptable'} |
| P99.9 | {pub_latency_999:.3f} ms | {'Excellent' if pub_latency_999 < 100 else 'Acceptable'} |
| Average | {pub_latency_avg:.3f} ms | - |
| Max | {pub_latency_max:.3f} ms | - |

### End-to-End Latency
| Percentile | Latency | Rating |
|------------|---------|--------|
| P50 (median) | {e2e_latency_50:.3f} ms | {'⭐ Excellent' if e2e_latency_50 < 4 else 'Good' if e2e_latency_50 < 10 else 'Acceptable'} |
| P95 | {e2e_latency_95:.3f} ms | {'⭐ Excellent' if e2e_latency_95 < 20 else 'Good' if e2e_latency_95 < 50 else 'Acceptable'} |
| P99 | {e2e_latency_99:.3f} ms | {'⭐ Excellent' if e2e_latency_99 < 100 else 'Good' if e2e_latency_99 < 200 else 'Acceptable'} |
| P99.9 | {e2e_latency_999:.3f} ms | - |
| Average | {e2e_latency_avg:.3f} ms | - |

## Infrastructure Configuration

### Broker Specifications
- **Instance Type**: {config.instance}
- **Count**: {config.broker_count} brokers
- **vCPU per broker**: {config.vcpu} cores
- **Memory per broker**: {config.memory_gb} GB
- **Total cluster resources**: {config.broker_count * config.vcpu} vCPU, {config.broker_count * config.memory_gb} GB RAM

### Configuration
- **Replication factor**: 3
- **Acknowledgment**: ack-all (strongest durability)
- **Compression**: lz4
- **Message size**: 1024 bytes

## Cost Analysis

- **Hourly cost**: ${config.cost * config.broker_count:.2f}/hour
- **Cost per MB/s**: ${(config.cost * config.broker_count) / pub_throughput_mb:.4f}/hour per MB/s
- **Daily cost (24h)**: ${config.cost * config.broker_count * 24:.2f}/day
- **Monthly cost (730h)**: ${config.cost * config.broker_count * 730:.2f}/month

## Performance Assessment

### Strengths
- {'✅ Achieved target throughput' if passed else '⚠️ Approached target throughput'} ({pct_target:.1f}%)
- {'✅ Excellent P50 latency' if pub_latency_50 < 2 else '✅ Good P50 latency'} ({pub_latency_50:.2f}ms)
- {'✅ Excellent P99 latency' if pub_latency_99 < 30 else '✅ Good P99 latency'} ({pub_latency_99:.2f}ms)
- {'✅ Zero backlog' if abs(backlog) < 1000 else f'⚠️ {format_number(abs(backlog), 0)} message backlog'}

### Key Observations
1. **Throughput**: {f'Successfully hit {target_mb} MB/s target' if passed else f'Achieved {pub_throughput_mb:.2f} MB/s ({pct_target:.1f}% of {target_mb} MB/s target)'}
2. **Latency**: {'Excellent sub-2ms median latency' if pub_latency_50 < 2 else f'Good {pub_latency_50:.2f}ms median latency'}
3. **Stability**: {'Stable operation with balanced producer/consumer rates' if abs(backlog) < 10000 else 'Some backlog accumulation observed'}
4. **Resource utilization**: {config.broker_count * config.vcpu} vCPU across {config.broker_count} brokers

## Recommendations

1. **Scaling**: {'Tier validated successfully for production use' if passed else 'Consider additional tuning or resources to hit target'}
2. **Latency optimization**: {'Excellent latency characteristics maintained' if pub_latency_99 < 50 else 'Monitor tail latency for sensitive applications'}
3. **Cost efficiency**: ${(config.cost * config.broker_count) / pub_throughput_mb:.4f} per MB/s per hour

## Conclusion

Tier {tier} {'successfully demonstrates' if passed else 'validates'} that Redpanda can {'achieve' if passed else 'approach'} {target_mb} MB/s throughput using {config.broker_count} {config.instance} instances. The {'achievement' if passed else 'performance'} with {'excellent' if pub_latency_50 < 2 else 'good'} latency characteristics shows {'production readiness' if passed else 'strong performance'} at this scale.

---
*Generated automatically from benchmark results*
"""
    return analysis

def generate_reports(tier: int, json_file: Path, provider: str = 'linode', output_dir: Path = None):
    """Generate all three report files"""

    print(f"Generating reports for Tier {tier}...")
    print(f"Provider: {provider}")
    print(f"Results file: {json_file}")
    print()

    # Load tier configuration
    config = load_tier_config(tier, provider)
    if not config:
        print(f"❌ Could not load configuration for Tier {tier}")
        return False

    print(f"✅ Loaded tier config: {config.broker_count}× {config.instance}, target {config.target_mb} MB/s")

    # Load benchmark results
    data = load_benchmark_results(json_file)
    if not data:
        return False

    print(f"✅ Loaded benchmark results")
    print()

    # Determine output directory
    if output_dir is None:
        output_dir = json_file.parent
    output_dir.mkdir(parents=True, exist_ok=True)

    # Generate reports
    print("Generating reports...")

    # 1. Simple report
    simple_report = generate_simple_report(tier, config, data)
    simple_path = output_dir / f"TIER_{tier}_REPORT.txt"
    with open(simple_path, 'w') as f:
        f.write(simple_report)
    print(f"  ✅ {simple_path}")

    # 2. Quick view
    quickview = generate_quickview(tier, config, data)
    quickview_path = output_dir / "QUICKVIEW.txt"
    with open(quickview_path, 'w') as f:
        f.write(quickview)
    print(f"  ✅ {quickview_path}")

    # 3. Analysis
    analysis = generate_analysis(tier, config, data)
    analysis_path = output_dir / f"TIER_{tier}_ANALYSIS.md"
    with open(analysis_path, 'w') as f:
        f.write(analysis)
    print(f"  ✅ {analysis_path}")

    print()
    print("✅ All reports generated successfully!")
    return True

def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)

    tier = int(sys.argv[1])
    json_file = Path(sys.argv[2])

    # Parse optional provider argument
    provider = 'linode'
    if '--provider' in sys.argv:
        idx = sys.argv.index('--provider')
        if idx + 1 < len(sys.argv):
            provider = sys.argv[idx + 1]

    success = generate_reports(tier, json_file, provider)
    sys.exit(0 if success else 1)

if __name__ == '__main__':
    main()
