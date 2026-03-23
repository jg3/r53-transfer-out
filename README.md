# r53-transfer-out

Bulk-transfers Route 53 registered domains from one AWS account to another using the
[internal transfer API](https://docs.aws.amazon.com/Route53/latest/APIReference/API_domains_TransferDomainToAnotherAwsAccount.html).
The script handles pagination, exports DNS records from source hosted zones, captures
per-domain transfer passwords, and generates a ready-to-run companion script for the
target account that accepts every transfer, creates the hosted zones, restores all DNS
records, and updates the registered domain nameservers.

> ⚠️ **Warning — irreversible operation.**
> Initiating a domain transfer cannot be undone once accepted by the target account.
> Always run with `--dry-run` first.

---

## How it works

```
SOURCE account                              TARGET account
─────────────────────────────────────────   ──────────────────────────────────────────
1. List all registered domains
   (optional: filter with --select-domains)
2. Prompt "Type YES to proceed"
3. For each domain:
   a. transfer-domain-to-another-aws-account  ──►  pending acceptance
      capture Password + OperationId
   b. Export DNS records from hosted zone
      (all records except apex NS + SOA)
4. Write passwords + opids to
   ~/route53-domain-transfer-passwords-<ts>.txt
5. Generate ~/r53-accept-transfers-<ts>.sh   ──►  run in target account:
                                                   Phase 1 (per domain):
                                                     [1/3] accept transfer
                                                     [2/3] create hosted zone
                                                     [3/3] restore DNS records
                                                   Phase 2 (per domain):
                                                     poll transfer op → SUCCESSFUL
                                                     update-domain-nameservers
```

Route 53 Domains is a global service. All API calls are explicitly routed to `us-east-1`
regardless of the configured AWS CLI region.

---

## Prerequisites

No special prep is needed to run in Cloudshell as these are currently installed there by default.

| Requirement | Notes |
|-------------|-------|
| AWS CLI v2 | Must be configured with credentials for the **source** account |
| `python3` | Required for JSON parsing and DNS record batching |
| `jq` (optional) | Used instead of `python3` for some JSON lookups when available |
| Bash 4.0+ | `mapfile` and associative arrays are required |
| IAM permissions (source) | `route53domains:ListDomains`, `route53domains:TransferDomainToAnotherAwsAccount`, `route53domains:CancelDomainTransferToAnotherAwsAccount` *(if using `--cancel-pending`)*, `route53domains:GetOperationDetail`, `route53:ListHostedZonesByName`, `route53:ListResourceRecordSets`, `sts:GetCallerIdentity` |
| IAM permissions (target) | `route53domains:AcceptDomainTransferFromAnotherAwsAccount`, `route53domains:UpdateDomainNameservers`, `route53domains:GetOperationDetail`, `route53:CreateHostedZone`, `route53:ChangeResourceRecordSets`, `route53:ListResourceRecordSets` |

---

## Usage

```bash
bash r53-transfer-out.sh [OPTIONS]
```

### Options

| Option | Description |
|--------|-------------|
| `--target-account=<ID>` | 12-digit AWS account ID of the target account. Prompted interactively if omitted. |
| `--dry-run` | List domains and show the commands that would be run — no transfers are initiated and no passwords are generated. |
| `--no-target-script` | Skip generating the companion accept script. Useful when you only need the password file. |
| `--cancel-pending` | If a domain already has a transfer in progress, cancel it and retry. Default behaviour is to skip the domain and record it as a failure. Use this flag to recover from a previous run where the companion accept script failed (e.g. due to a corrupted password). |
| `--no-dns-export` | Skip exporting hosted zone DNS records. The companion script will accept transfers and create hosted zones but will not restore any DNS records. |
| `--select-domains` | Interactive mode: prompts `[Y/n]` for each domain found before initiating any transfers. |
| `--select-domains=d1.com,d2.com` | Restrict the run to a specific comma-separated list of domains. Any domain in the list not found in the account produces a warning. |
| `-h`, `--help` | Print usage and exit. |

### Exit codes

| Code | Meaning |
|------|---------|
| `0` | All transfers succeeded (or dry-run / no domains found). |
| `1` | Argument or preflight error. |
| `2` | At least one domain transfer failed. |

---

## Step-by-step workflow

### 1. Dry run from the source account

```bash
# In the source account (CloudShell or local terminal)
bash r53-transfer-out.sh --target-account=123456789012 --dry-run
```

Review the output to confirm every expected domain is listed. No API write calls are made.

### 2. (Optional) Select a subset of domains

```bash
# Interactive — prompts Y/n for each domain
bash r53-transfer-out.sh --target-account=123456789012 --select-domains

# Or supply an explicit list
bash r53-transfer-out.sh --target-account=123456789012 --select-domains=example.com,another.org
```

### 3. Initiate transfers and export DNS

```bash
bash r53-transfer-out.sh --target-account=123456789012
```

The script will:

1. List all registered domains (paginated).
2. Display source and target account IDs and prompt `Type YES to proceed`.
3. For each domain, call `transfer-domain-to-another-aws-account` and capture the `Password` and `OperationId`.
4. Export all DNS records from the corresponding public hosted zone in the source account (apex NS and SOA are excluded — Route 53 auto-generates these in the new zone). Alias records that point to AWS-managed resources trigger a warning.
5. Write a summary and all passwords/operation IDs to:
   ```
   ~/route53-domain-transfer-passwords-<YYYYMMDD-HHMMSS>.txt  (mode 600)
   ```
6. Generate and save the companion accept script to:
   ```
   ~/r53-accept-transfers-<YYYYMMDD-HHMMSS>.sh  (mode 700)
   ```

### 4. Accept transfers in the target account

👉 Copy `r53-accept-transfers-<ts>.sh` to the **target** account (e.g., via CloudShell upload)
and run it:

```bash
bash r53-accept-transfers-<YYYYMMDD-HHMMSS>.sh
```

The companion script runs in two phases:

**Phase 1** (repeated for each domain):
1. `[1/3]` Accepts the transfer using the embedded password.
2. `[2/3]` Creates a new public hosted zone; captures the Route 53-assigned NS records.
3. `[3/3]` Restores the DNS records exported from the source account (in batches of 500).

**Phase 2** (repeated for each domain):
- Polls `get-operation-detail` (every 30 s, up to 30 min) until the transfer operation reaches `SUCCESSFUL`.
- Calls `update-domain-nameservers` to point the registered domain at the new hosted zone's NS records.
- Prints the manual equivalent command in case a retry is needed later.

A final summary shows Phase 1 and Phase 2 success/failure counts.

> ⚠️ The companion script contains plaintext transfer passwords. Treat it with the same
> care as the password file — delete both once all transfers are complete.

---

## Output files

Both files are written atomically with restricted permissions before any content is added,
preventing exposure in the window between creation and a `chmod` call.

| File | Permissions | Contents |
|------|-------------|----------|
| `~/route53-domain-transfer-passwords-<ts>.txt` | `600` | Tab-separated table of domain names, transfer passwords, and operation IDs, plus a failures section if any domains failed. |
| `~/r53-accept-transfers-<ts>.sh` | `700` | Self-contained bash script for the target account. Embeds passwords (base64), operation IDs, and DNS records (base64 JSON). Only created when there is at least one successful transfer. |

---

## Safety features

- **Same-account guard** — aborts immediately if the source and target account IDs match.
- **Explicit confirmation** — requires typing `YES` (exact case) before any transfer is initiated.
- **Dry-run mode** — shows exactly which AWS CLI commands would be executed without calling any write APIs.
- **Domain selection** — `--select-domains` lets you process only a chosen subset, either interactively or via an explicit list, reducing blast radius.
- **Partial failure tolerance** — a failure on one domain is recorded and the script continues to the next; the exit code is `2` if any domain failed.
- **Cancel-and-retry** — `--cancel-pending` detects an in-progress transfer from a previous run, cancels it, polls for cancellation to complete, then retries automatically.
- **Alias record warnings** — any DNS alias record pointing to an AWS-managed resource (ELB, CloudFront, etc.) triggers a warning during export, since the target resource may not exist in the new account.
- **Rate limiting** — a 0.5-second pause between API calls to stay within Route 53 Domains rate limits.
- **Temp-file cleanup** — all internal temp files are registered in a cleanup array and removed on exit via `trap`.
- **Companion script is only created when needed** — `~/r53-accept-transfers-<ts>.sh` is not created if `--no-target-script`, `--dry-run`, or if no transfers succeeded, so no empty script files are left on disk.

---

## Troubleshooting

**"No registered domains found in this account"**
The AWS credentials in use do not have access to any Route 53 registered domains, or the
source account genuinely has none. Verify with:
```bash
aws route53domains --region us-east-1 list-domains
```

**"ERROR: Source and target account IDs are the same"**
The credentials resolve to the same account as the target. Check that you are authenticated
to the correct source account (`aws sts get-caller-identity`).

**Transfer initiated but Password not captured**
The API response did not include a `Password` field. The raw JSON is printed to the
terminal and the domain is added to the failures list. The transfer may still be in
a pending state in the console — check the Route 53 Domains operations log.

**"A transfer is already in progress — re-run with --cancel-pending"**
A previous run left a pending transfer. Pass `--cancel-pending` to cancel it, wait for
the cancellation to complete, and retry the transfer automatically.

**No public hosted zone found for a domain**
The source account does not have a Route 53 hosted zone matching the domain name. DNS
records will not be exported or restored. Create the zone manually in the target account
and populate records as needed.

**Alias records warning during DNS export**
An alias record (e.g., pointing at an ELB, CloudFront distribution, or S3 website) was
found in the source hosted zone. These records reference resources in the source account.
After the transfer, verify that equivalent resources exist in the target account and update
the alias targets accordingly.

**Companion script reports "You are not in the expected target account"**
The credentials active when running the accept script do not match the target account ID
embedded in the script. You can choose to continue (type `y`) or abort and switch accounts.

**Phase 2 nameserver update fails with "domain not found"**
The transfer operation has not completed yet. The companion script polls for up to 30 minutes.
If the transfer takes longer, rerun the nameserver update manually using the printed command:
```bash
aws route53domains update-domain-nameservers --region us-east-1 \
  --domain-name "example.com" \
  --nameservers '[{"Name":"ns-1234.awsdns-56.org"}, ...]'
```

---

## Security considerations

- Transfer passwords are generated by AWS and are single-use. They expire if not accepted promptly (typically within a few days).
- Both output files contain plaintext passwords. Store them securely and delete them once all transfers are accepted.
- DNS records are base64-encoded and embedded in the companion script; they are not encrypted. Apply the same handling requirements as the passwords.
- The script never logs passwords to any external system; all output goes to the local terminal and the `600`-permission file only.
- If you need to run this in a CI/CD context, pipe stdout to a secrets manager rather than relying on the local file.
