# Benchmark Report Generator

Automated report generation tool for OpenMessaging Benchmark results.

## Overview

`generate-benchmark-report.py` generates three formatted reports from benchmark JSON results:

1. **TIER_X_REPORT.txt** - Simple text summary for quick reference
2. **QUICKVIEW.txt** - Formatted visual report with comparisons
3. **TIER_X_ANALYSIS.md** - Detailed markdown analysis for documentation

## Usage

```bash
python3 generate-benchmark-report.py <tier> <json_file> [--provider linode|aws]
```

### Examples

```bash
# Generate Tier 4 reports (Linode)
python3 generate-benchmark-report.py 4 \
  benchmark_results_linode/tier-4/workload-tier-4-Redpanda-2026-02-05-02-20-01.json \
  --provider linode

# Generate Tier 5 reports (AWS)
python3 generate-benchmark-report.py 5 \
  benchmark_results_aws/tier-5/results.json \
  --provider aws

# Using without provider flag (defaults to linode)
python3 generate-benchmark-report.py 3 results/tier-3-results.json
```

## Requirements

- **Python 3.6+**
- **Tier configuration file**: `tiers-{provider}.tsv` must exist in the repository root
- **Benchmark results**: JSON file from OpenMessaging Benchmark

## Configuration Files

The tool reads tier configuration from TSV files:

- `tiers-linode.tsv` - Linode instance configurations
- `tiers-aws.tsv` - AWS instance configurations

These files contain:
- Instance types
- vCPU and memory specifications
- Broker counts
- Target throughput
- Cost per hour

## Generated Reports

### TIER_X_REPORT.txt

Simple text format with key metrics:
- Throughput (publish rate, MB/s, % of target)
- Latency (P50, P99 for publish and end-to-end)
- Infrastructure summary
- Pass/fail verdict

### QUICKVIEW.txt

Formatted visual report with:
- Box-drawing characters for visual appeal
- Throughput breakdown
- Detailed latency percentiles table
- Infrastructure specifications
- Key highlights and scaling insights
- Emoji indicators (⭐ for excellent, ✅ for pass, ⚠️ for warnings)

### TIER_X_ANALYSIS.md

Comprehensive markdown analysis:
- Overview and objectives
- Throughput metrics table
- Latency percentiles with ratings
- Infrastructure configuration details
- Cost analysis (hourly, daily, monthly)
- Performance assessment
- Key observations
- Recommendations
- Conclusion

## How It Works

1. **Loads tier configuration** from `tiers-{provider}.tsv`
2. **Parses JSON results** from benchmark output
3. **Normalizes data**:
   - Calculates averages from time-series data
   - Extracts aggregated metrics
   - Handles both list and single-value fields
4. **Generates reports** using templates with calculated metrics
5. **Saves to disk** in the same directory as the JSON file

## Automation Integration

The tool is designed to be called from automation scripts:

```bash
# In your benchmark automation
python3 generate-benchmark-report.py $TIER $RESULTS_JSON --provider $PROVIDER

# Check exit code
if [ $? -eq 0 ]; then
    echo "Reports generated successfully"
else
    echo "Report generation failed"
fi
```

## Customization

To customize report templates:

1. Edit the functions in `generate-benchmark-report.py`:
   - `generate_simple_report()` - Simple text report
   - `generate_quickview()` - Visual report
   - `generate_analysis()` - Markdown analysis

2. Modify rating thresholds:
   - P50 < 2ms = Excellent
   - P95 < 10ms = Excellent
   - P99 < 30ms = Excellent
   - Adjust these in the rating logic

3. Update cost calculations:
   - Costs are read from the TSV `Cost OD` column
   - Daily = hourly × 24
   - Monthly = hourly × 730

## Troubleshooting

### "Could not find tiers configuration file"

The tool looks for `tiers-{provider}.tsv` in:
1. Repository root
2. `linode_claude_jumpbox/ubuntu/`
3. `aws_claude_jumpbox/ubuntu/`

Ensure your tier configuration file exists in one of these locations.

### "Results file not found"

Check that:
- The JSON file path is correct
- The file has `.json` extension
- You have read permissions

### Wrong target throughput

The tool uses the "Egress Limit (legacy)" column from the TSV as the target.
If this doesn't match your benchmark, update the TSV file or modify the TierConfig class.

### "TypeError: unsupported operand"

This usually means the JSON structure doesn't match expectations. The tool expects:
- `publishRate`, `consumeRate`, `backlog` as lists or single values
- `aggregatedPublishLatency*` fields for latency metrics

Check your JSON structure matches OpenMessaging Benchmark output format.

## Example Workflow

```bash
# 1. Run benchmark
cd /opt/benchmark
bin/benchmark --drivers driver-redpanda/config.yaml \
               --workers-file workers.yaml \
               workloads/workload-tier-5.yaml

# 2. Results saved as: workload-tier-5-Redpanda-2026-02-05-16-00-00.json

# 3. Generate reports
python3 /path/to/generate-benchmark-report.py 5 \
        workload-tier-5-Redpanda-2026-02-05-16-00-00.json \
        --provider linode

# 4. View reports
cat QUICKVIEW.txt
cat TIER_5_ANALYSIS.md
```

## Contributing

To add support for new report formats:

1. Add a new generator function (e.g., `generate_html_report()`)
2. Call it from the `generate_reports()` function
3. Save output to the results directory

## License

Part of the OpenMessaging Benchmark infrastructure for Redpanda partner validation.
