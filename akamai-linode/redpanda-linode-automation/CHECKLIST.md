# Pre-Flight Checklist

Use this checklist before running the deployment.

## ✅ Prerequisites Installed

Check that you have all required tools:

```bash
# Check versions
terraform --version    # Need >= 1.0
kubectl version --client  # Need >= 1.27
helm version          # Need >= 3.10
jq --version          # Any version

# If any are missing, install them:
# macOS: brew install terraform kubectl helm jq
# Linux: See respective installation docs
```

- [ ] terraform installed
- [ ] kubectl installed
- [ ] helm installed
- [ ] jq installed

## ✅ Configuration Ready

- [ ] config.sh file exists (created from config.example.sh)
- [ ] LINODE_TOKEN is set in config.sh
- [ ] TOKEN is valid and has full access
- [ ] Configuration values reviewed (cluster name, region, node type)

## ✅ Linode Account Ready

- [ ] Linode account is active
- [ ] API token has full permissions
- [ ] Account has sufficient quota for:
  - 3 Linodes (Dedicated 16GB)
  - 3 Volumes (50GB each)
  - 1 Object Storage bucket
  - 1 LKE cluster

**Note**: New accounts may need quota increase. If deployment fails with "quota exceeded", open a support ticket at https://cloud.linode.com/support

## ✅ Local Environment

- [ ] Internet connection is stable (deployment takes ~40 minutes)
- [ ] Sufficient disk space (~1GB for reports and logs)
- [ ] Terminal window can stay open for 40+ minutes

## ✅ Understanding

- [ ] I understand this will create billable resources (~$0.84/hr)
- [ ] I know how to run cleanup.sh when done
- [ ] I have reviewed QUICKSTART.md
- [ ] I'm ready to monitor the deployment process

## ✅ Optional (Recommended)

- [ ] Read ARCHITECTURE.md to understand what gets deployed
- [ ] Have Linode Cloud Manager open in browser: https://cloud.linode.com
- [ ] Have a second terminal window ready for ad-hoc checks
- [ ] Know where reports will be saved (./reports/)

---

## When All Checks Pass

Run the deployment:

```bash
./deploy-and-validate.sh
```

## During Deployment

Monitor for:
- ✓ Green checkmarks = Success
- ✗ Red X marks = Failures
- ⚠ Yellow warnings = Non-critical issues

## After Deployment

1. Review reports:
   ```bash
   cat reports/validation-report-*.txt
   ```

2. Access cluster:
   ```bash
   export KUBECONFIG=~/.kube/redpanda-linode-kubeconfig
   kubectl get pods -n redpanda
   ```

3. View Redpanda Console:
   ```bash
   kubectl port-forward svc/redpanda-console -n redpanda 8080:8080
   # Visit http://localhost:8080
   ```

4. **Don't forget to cleanup when done!**
   ```bash
   ./cleanup.sh
   ```

---

## Troubleshooting Quick Reference

| Issue | Solution |
|-------|----------|
| **"command not found: terraform"** | Install Terraform: `brew install terraform` |
| **"quota exceeded"** | Open support ticket to increase quota |
| **"pods stuck in Pending"** | Wait 2-3 minutes for volume provisioning |
| **Deployment fails** | Check full log in `reports/validation-full-*.log` |
| **Can't access cluster** | Verify kubeconfig: `export KUBECONFIG=~/.kube/redpanda-linode-kubeconfig` |

For detailed troubleshooting, see **QUICKSTART.md**.

---

**All checks passed? Great! Run:**

```bash
./deploy-and-validate.sh
```

**Estimated time: 40 minutes**
**Cost: ~$1.68 for 2-hour test**
