# r53-transfer-out

Bulk-transfers all Route 53 registered domains from one AWS account to another using the
[internal transfer API](https://docs.aws.amazon.com/Route53/latest/APIReference/API_domains_TransferDomainToAnotherAwsAccount.html).
The script handles pagination, captures per-domain transfer passwords, and generates a
ready-to-run companion script for the target account to accept every transfer.

> **Warning — irreversible operation.**
> Initiating a domain transfer cannot be undone once accepted by the target account.
> Always run with `--dry-run` first.

---

## How it works

```
SOURCE account                          TARGET account
──────────────────────────────────      ──────────────────────────────────
1. List all registered domains
2. Prompt "Type YES to proceed"
3. For each domain:
   transfer-domain-to-another-aws-account  ──►  pending acceptance
   capture Password + OperationId
4. Write passwords to ~/route53-domain-transfer-passwords-<ts>.txt
5. Generate ~/r53-accept-transfers-<ts>.sh  ──►  run this in target account
                                                  accept-domain-transfer-from-another-aws-account
```

Route 53 Domains is a global service. All API calls are explicitly routed to `us-east-1`
regardless of the configured AWS CLI region.

---

## Prerequisites

| Requirement | Notes |
|-------------|-------|
| AWS CLI v2 | Must be configured with credentials for the **source** account |
| `jq` **or** `python3` | Used to parse API responses; `jq` is preferred when available |
| Bash 4.0+ | `mapfile` and associative arrays are required |
| IAM permissions (source) | `route53domains:ListDomains`, `route53domains:TransferDomainToAnotherAwsAccount`, `sts:GetCallerIdentity` |
| IAM permissions (target) | `route53domains:AcceptDomainTransferFromAnotherAwsAccount` |

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

Review the output to confirm every expected domain is listed.

### 2. Initiate transfers

```bash
bash r53-transfer-out.sh --target-account=123456789012
```

The script will:

1. List all registered domains (paginated).
2. Display source and target account IDs and prompt `Type YES to proceed`.
3. Call `transfer-domain-to-another-aws-account` for each domain.
4. Print each domain's `OperationId` and `Password` as it goes.
5. Write a summary and all passwords to:
   ```
   ~/route53-domain-transfer-passwords-<YYYYMMDD-HHMMSS>.txt  (mode 600)
   ```
6. Generate and save the companion accept script to:
   ```
   ~/r53-accept-transfers-<YYYYMMDD-HHMMSS>.sh  (mode 700)
   ```

### 3. Accept transfers in the target account

Copy `r53-accept-transfers-<ts>.sh` to the **target** account (e.g., via CloudShell upload)
and run it:

```bash
bash r53-accept-transfers-<YYYYMMDD-HHMMSS>.sh
```

The companion script verifies it is running in the expected account, then calls
`accept-domain-transfer-from-another-aws-account` for each domain using the embedded
passwords. It prints a final `Accepted / Failed` count.

> The companion script contains plaintext transfer passwords. Treat it with the same
> care as the password file — delete both once all transfers are complete.

---

## Output files

Both files are written atomically with restricted permissions before any content is added,
preventing exposure in the window between creation and a `chmod` call.

| File | Permissions | Contents |
|------|-------------|----------|
| `~/route53-domain-transfer-passwords-<ts>.txt` | `600` | Tab-separated table of domain names and transfer passwords, plus a failures section if any domains failed. |
| `~/r53-accept-transfers-<ts>.sh` | `700` | Self-contained bash script for the target account. Only created when there is at least one successful transfer. |

---

## Safety features

- **Same-account guard** — aborts immediately if the source and target account IDs match.
- **Explicit confirmation** — requires typing `YES` (exact case) before any transfer is initiated.
- **Dry-run mode** — shows exactly which AWS CLI commands would be executed without calling any write APIs.
- **Partial failure tolerance** — a failure on one domain is recorded in `FAIL_ROWS` and the script continues to the next domain; the exit code is `2` if any domain failed.
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

**Companion script reports "You are not in the expected target account"**
The credentials active when running the accept script do not match the target account ID
embedded in the script. You can choose to continue (type `y`) or abort and switch accounts.

---

## Security considerations

- Transfer passwords are generated by AWS and are single-use. They expire if not accepted promptly (typically within a few days).
- Both output files contain plaintext passwords. Store them securely and delete them once all transfers are accepted.
- The script never logs passwords to any external system; all output goes to the local terminal and the `600`-permission file only.
- If you need to run this in a CI/CD context, pipe stdout to a secrets manager rather than relying on the local file.
