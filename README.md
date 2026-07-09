# Redpanda Partner Validation

This repository contains validation tests and certification materials for Redpanda's cloud platform partnerships.

## Overview

Redpanda is a streaming data platform for developers. This repository provides automated validation scripts and tests to verify Redpanda deployments across various cloud provider platforms.

## Service Provider Partners

- **Akamai/Linode** - Validation scripts for Redpanda on Linode Kubernetes Engine (LKE)
- **Oracle Cloud (OCI)** - Full benchmark package for Redpanda on OKE: Terraform, Helm values, workloads from 60 MB/s to 4 GB/s, runbooks, and published results (July 2026 campaign — 4 GB/s blended production workload sustained)

## Repository Structure

```
├── akamai-linode/     # Akamai/Linode validation scripts and tests
├── oracle-cloud/      # OCI/OKE benchmark package: infra, workloads, runbooks, results
├── .gitignore         # Security-focused gitignore for credentials
└── LICENSE            # MIT License
```

## Quick Start

Each partner directory contains specific validation scripts and documentation:

```bash
cd akamai-linode/
# Follow the partner-specific README for setup and execution
```

## Requirements

- Cloud provider account with appropriate credentials
- Kubernetes cluster access
- Required CLI tools (kubectl, terraform, etc.)

## Security

This repository is designed to prevent accidental commits of sensitive data. The `.gitignore` file blocks:
- API keys and credentials
- Kubeconfig files
- Terraform state files
- SSL certificates and private keys
- Environment files

Always review your changes before committing to ensure no sensitive data is included.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines on contributing to this project.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Support

For issues or questions:
- Open an issue in this repository
