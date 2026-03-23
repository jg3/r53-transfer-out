#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: r53-transfer-out.sh [--target-account=123456789012] [--dry-run] [--no-target-script] [--cancel-pending] [--no-dns-export] [--select-domains[=d1.com,d2.com]]

Options:
  --target-account=<account ID>      12-digit AWS account ID to transfer domains to (skips prompt if valid)
  --dry-run                          Show what would happen without initiating any transfers
  --no-target-script                 Do not print/save the companion target-account accept script
  --cancel-pending                   If a domain already has a transfer in progress, cancel it and retry.
                                     Default behaviour (without this flag) is to skip the domain and record
                                     it as a failure. Use this flag to recover from a previous run where the
                                     companion accept script failed (e.g. due to a corrupted password).
  --no-dns-export                    Skip exporting hosted zone DNS records (companion script will not restore DNS)
  --select-domains[=d1.com,d2.com]   Restrict the transfer to specific domains only.
                                     Without a value: prompts [Y/n] interactively for each domain found.
                                     With a comma-separated list: only those domains are processed; any
                                     specified domain not found in the account produces a warning.
USAGE
}

TARGET_ACCOUNT_ID=""
DRY_RUN=0
NO_TARGET_SCRIPT=0
CANCEL_PENDING=0
NO_DNS_EXPORT=0
SELECT_DOMAINS=()
INTERACTIVE_SELECT=0

for arg in "$@"; do
  case "$arg" in
    --target-account=*)
      TARGET_ACCOUNT_ID="${arg#*=}"
      ;;
    --dry-run)
      DRY_RUN=1
      ;;
    --no-target-script)
      NO_TARGET_SCRIPT=1
      ;;
    --cancel-pending)
      CANCEL_PENDING=1
      ;;
    --no-dns-export)
      NO_DNS_EXPORT=1
      ;;
    --select-domains)
      if [[ ${#SELECT_DOMAINS[@]} -gt 0 ]]; then
        echo "ERROR: --select-domains with a domain list and --select-domains (interactive) cannot be combined."
        exit 1
      fi
      INTERACTIVE_SELECT=1
      ;;
    --select-domains=*)
      if [[ $INTERACTIVE_SELECT -eq 1 ]]; then
        echo "ERROR: --select-domains with a domain list and --select-domains (interactive) cannot be combined."
        exit 1
      fi
      val="${arg#*=}"
      if [[ -z "$val" ]]; then
        INTERACTIVE_SELECT=1
      else
        IFS=',' read -ra _SD_PARSED <<< "$val"
        SELECT_DOMAINS+=("${_SD_PARSED[@]}")
        unset _SD_PARSED
      fi
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: Unknown argument: $arg"
      usage
      exit 1
      ;;
  esac
done

command -v aws >/dev/null 2>&1 || { echo "ERROR: aws CLI not found."; exit 1; }
command -v jq >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1 || \
  { echo "ERROR: neither jq nor python3 found; one is required."; exit 1; }

# Prompt if target account not provided
if [[ -z "${TARGET_ACCOUNT_ID}" ]]; then
  read -r -p "Enter the TARGET AWS Account ID (12 digits): " TARGET_ACCOUNT_ID
fi
TARGET_ACCOUNT_ID="$(echo "$TARGET_ACCOUNT_ID" | tr -d '[:space:]')"

if [[ ! "$TARGET_ACCOUNT_ID" =~ ^[0-9]{12}$ ]]; then
  echo "ERROR: Account ID must be exactly 12 digits."
  exit 1
fi

# Route 53 Domains is a global service; region is shown for informational purposes only.
REGION="$(aws configure get region || true)"
REGION="${REGION:-us-east-1}"

TS="$(date +%Y%m%d-%H%M%S)"
OUTFILE="$HOME/route53-domain-transfer-passwords-$TS.txt"
TARGET_SCRIPT_FILE="$HOME/r53-accept-transfers-$TS.sh"

SOURCE_ACCT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"

# Issue 12: Guard against transferring to the same account
if [[ -n "$SOURCE_ACCT" && "$SOURCE_ACCT" == "$TARGET_ACCOUNT_ID" ]]; then
  echo "ERROR: Source and target account IDs are the same ($SOURCE_ACCT). Aborting."
  exit 1
fi

echo "Source AWS Account (caller identity): ${SOURCE_ACCT:-<unknown>}"
echo "Target AWS Account: $TARGET_ACCOUNT_ID"
echo "AWS CLI region: ${REGION} (informational only; Route 53 Domains is a global service)"
echo "Dry-run: $([[ $DRY_RUN -eq 1 ]] && echo yes || echo no)"
echo "DNS export: $([[ $NO_DNS_EXPORT -eq 1 ]] && echo no || echo yes)"
echo

# Pre-create OUTFILE atomically with restricted permissions (no TOCTOU window).
# TARGET_SCRIPT_FILE is created with the same approach only when it will actually
# be written, further below, so it never exists as an empty orphan file.
(umask 177; : > "$OUTFILE")

echo "Listing Route 53 registered domains..."

# Temp-file registry; all entries are removed by the EXIT trap.
TMPFILES=()
cleanup() { [[ ${#TMPFILES[@]} -gt 0 ]] && rm -f "${TMPFILES[@]}"; }
trap cleanup EXIT

LIST_ERR="$(mktemp)"; TMPFILES+=("$LIST_ERR")
PY_ERR="$(mktemp)";   TMPFILES+=("$PY_ERR")
ERR_TMP="$(mktemp)";  TMPFILES+=("$ERR_TMP")

# Issues 1+3+4: Paginated JSON listing with separate stderr; one domain per line via python3.
# The AWS CLI does not auto-paginate list-domains, so we iterate using NextPageMarker.
ALL_DOMAINS=()
NEXT_TOKEN=""
while true; do
  CMD=(aws route53domains --region us-east-1 list-domains --output json)
  [[ -n "$NEXT_TOKEN" ]] && CMD+=(--starting-token "$NEXT_TOKEN")
  PAGE="$("${CMD[@]}" 2>"$LIST_ERR")" || {
    echo "ERROR: Failed to list domains:"
    cat "$LIST_ERR"
    exit 1
  }
  mapfile -t PAGE_DOMAINS < <(
    echo "$PAGE" | python3 -c \
      "import json,sys; [print(d['DomainName']) for d in json.load(sys.stdin).get('Domains',[])]" \
      2>"$PY_ERR"
  ) || true
  # || true prevents set -e from aborting on process-substitution exit codes (bash-version-
  # dependent). Checking the error file directly is the only reliable way to surface Python
  # failures, because mapfile itself returns 0 when it reads an empty stream.
  [[ -s "$PY_ERR" ]] && { echo "WARNING: python3 JSON parse failed:"; cat "$PY_ERR"; }
  [[ ${#PAGE_DOMAINS[@]} -gt 0 ]] && ALL_DOMAINS+=("${PAGE_DOMAINS[@]}")
  if command -v jq >/dev/null 2>&1; then
    NEXT_TOKEN="$(echo "$PAGE" | jq -r '.NextPageMarker // empty' 2>/dev/null)" || NEXT_TOKEN=""
  else
    NEXT_TOKEN="$(echo "$PAGE" | python3 -c \
      "import json,sys; print(json.load(sys.stdin).get('NextPageMarker',''))" 2>/dev/null)" || NEXT_TOKEN=""
  fi
  [[ -z "$NEXT_TOKEN" ]] && break
done

if [[ ${#ALL_DOMAINS[@]} -eq 0 ]]; then
  echo "No registered domains found in this account."
  exit 0
fi

echo "Found ${#ALL_DOMAINS[@]} domain(s)."
echo

# Filter domains when --select-domains is provided.
if [[ ${#SELECT_DOMAINS[@]} -gt 0 ]]; then
  FILTERED=()
  declare -A _SEEN_SD=()
  for sd in "${SELECT_DOMAINS[@]}"; do
    sd="$(echo "$sd" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"; [[ -z "$sd" ]] && continue
    if [[ -n "${_SEEN_SD[$sd]+x}" ]]; then
      echo "WARNING: '$sd' specified more than once in --select-domains; ignoring duplicate."
      continue
    fi
    _SEEN_SD[$sd]=1
    found=0
    for d in "${ALL_DOMAINS[@]}"; do
      d_lower="$(echo "$d" | tr '[:upper:]' '[:lower:]')"
      [[ "$d_lower" == "$sd" ]] && { FILTERED+=("$d"); found=1; break; }
    done
    [[ $found -eq 0 ]] && echo "WARNING: '$sd' not found in account; skipping."
  done
  unset _SEEN_SD
  ALL_DOMAINS=("${FILTERED[@]}")
  echo "Selected ${#ALL_DOMAINS[@]} domain(s) from --select-domains list."
  echo
elif [[ $INTERACTIVE_SELECT -eq 1 ]]; then
  echo "Interactive domain selection (--select-domains):"
  FILTERED=()
  for d in "${ALL_DOMAINS[@]}"; do
    [[ -z "$d" ]] && continue
    read -r -p "  Include '$d' in transfer? [Y/n]: " ans
    ans="${ans:-Y}"
    [[ "$ans" =~ ^[Yy]$ ]] && FILTERED+=("$d")
  done
  ALL_DOMAINS=("${FILTERED[@]}")
  echo
  echo "Selected ${#ALL_DOMAINS[@]} domain(s)."
  echo
fi

if [[ ${#ALL_DOMAINS[@]} -eq 0 ]]; then
  echo "No domains selected for transfer."
  exit 0
fi

SUCCESS_ROWS=()    # "domain<TAB>password<TAB>opid"
FAIL_ROWS=()       # "domain<TAB>error"
DRY_RUN_ROWS=()    # "domain<TAB>DRY-RUN note" (issue 9)

echo "Initiating internal transfers and capturing per-domain Password..."
echo "NOTE: Passwords are sensitive. Treat screen output and saved files as confidential."
echo

# Issue 10: Require explicit confirmation before initiating irreversible bulk transfers.
if [[ $DRY_RUN -eq 0 ]]; then
  echo "About to initiate transfer of ${#ALL_DOMAINS[@]} domain(s) to account $TARGET_ACCOUNT_ID."
  read -r -p "Type YES to proceed: " CONFIRM
  [[ "$CONFIRM" == "YES" ]] || { echo "Aborted."; exit 0; }
  echo
fi

for DOMAIN in "${ALL_DOMAINS[@]}"; do
  [[ -z "$DOMAIN" ]] && continue

  echo "----"
  echo "Domain: $DOMAIN"

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "DRY-RUN: would call: aws route53domains --region us-east-1 transfer-domain-to-another-aws-account --domain-name \"$DOMAIN\" --account-id \"$TARGET_ACCOUNT_ID\""
    # Issue 9: Track dry-run entries separately so they do not appear under Failures
    DRY_RUN_ROWS+=("$DOMAIN"$'\t'"DRY-RUN (no transfer initiated; no password generated)")
    continue
  fi

  RESP="$(aws route53domains --region us-east-1 transfer-domain-to-another-aws-account \
            --domain-name "$DOMAIN" \
            --account-id "$TARGET_ACCOUNT_ID" \
            --output json 2>"$ERR_TMP")" || {
    # If a prior transfer is still pending, behaviour depends on --cancel-pending.
    if grep -qi "operation in progress" "$ERR_TMP" 2>/dev/null && [[ $CANCEL_PENDING -eq 1 ]]; then
      echo "Pending transfer detected for $DOMAIN; cancelling (--cancel-pending)..."

      # Three possible outcomes from the cancel call:
      #   (A) Success        → got OperationId; poll it, then retry transfer
      #   (B) Already cancelled → a prior run's cancel is still processing; skip to retry loop
      #   (C) Other error    → give up on this domain
      CANCEL_OPID=""
      CANCEL_EC=0
      CANCEL_OUT="$(aws route53domains --region us-east-1 \
        cancel-domain-transfer-to-another-aws-account \
        --domain-name "$DOMAIN" --output json 2>"$ERR_TMP")" || CANCEL_EC=$?

      if [[ $CANCEL_EC -eq 0 ]]; then
        # (A) Parse OperationId and poll until the cancellation completes
        if command -v jq >/dev/null 2>&1; then
          CANCEL_OPID="$(echo "$CANCEL_OUT" | jq -r '.OperationId // empty' 2>/dev/null)" || CANCEL_OPID=""
        else
          CANCEL_OPID="$(echo "$CANCEL_OUT" | python3 -c \
            'import json,sys; print(json.load(sys.stdin).get("OperationId",""))' 2>/dev/null)" || CANCEL_OPID=""
        fi
        if [[ -n "$CANCEL_OPID" ]]; then
          echo "Cancel submitted (OperationId: $CANCEL_OPID). Polling for completion..."
          MAX_WAIT=120; WAITED=0; POLL_INTERVAL=5; CANCEL_STATUS=""
          while [[ $WAITED -lt $MAX_WAIT ]]; do
            sleep $POLL_INTERVAL
            WAITED=$((WAITED + POLL_INTERVAL))
            OP_RESP="$(aws route53domains --region us-east-1 get-operation-detail \
              --operation-id "$CANCEL_OPID" --output json 2>/dev/null)" || { CANCEL_STATUS="ERROR"; break; }
            if command -v jq >/dev/null 2>&1; then
              CANCEL_STATUS="$(echo "$OP_RESP" | jq -r '.Status // empty' 2>/dev/null)" || CANCEL_STATUS=""
            else
              CANCEL_STATUS="$(echo "$OP_RESP" | python3 -c \
                'import json,sys; print(json.load(sys.stdin).get("Status",""))' 2>/dev/null)" || CANCEL_STATUS=""
            fi
            echo "  Cancel status: ${CANCEL_STATUS:-unknown} (${WAITED}s elapsed)"
            [[ "$CANCEL_STATUS" == "SUCCESSFUL" || "$CANCEL_STATUS" == "FAILED" || "$CANCEL_STATUS" == "ERROR" ]] && break
          done
          [[ "$CANCEL_STATUS" != "SUCCESSFUL" ]] && \
            echo "WARNING: Cancel ended with status '${CANCEL_STATUS:-unknown}'; retry may still fail."
        else
          echo "WARNING: Could not parse OperationId from cancel response; retrying transfer directly."
        fi
      elif grep -qi "already been cancelled" "$ERR_TMP" 2>/dev/null; then
        # (B) A previous run already issued the cancel; it is still being processed asynchronously.
        # Skip the cancel step and fall through to the transfer retry loop below.
        echo "Transfer was already cancelled from a previous run; waiting for operation to clear..."
      else
        # (C) Unexpected error from the cancel call; give up on this domain
        echo "ERROR: Failed to cancel pending transfer for $DOMAIN:"
        cat "$ERR_TMP"
        ERR_ONE_LINE="$(tr '\n' ' ' <"$ERR_TMP" | sed 's/[[:space:]]\+/ /g' | cut -c1-240)"
        FAIL_ROWS+=("$DOMAIN"$'\t'"Cancel failed: $ERR_ONE_LINE")
        sleep 0.5
        continue
      fi

      # Retry the transfer, polling if still blocked by a lingering async operation.
      # This handles both case (A) where the cancel OperationId poll may have hit its
      # timeout and case (B) where no OperationId was available to poll.
      echo "Retrying transfer for $DOMAIN..."
      MAX_WAIT=120; WAITED=0; POLL_INTERVAL=10; TRANSFER_OK=0
      while [[ $WAITED -le $MAX_WAIT ]]; do
        TRANSFER_EC=0
        RESP="$(aws route53domains --region us-east-1 transfer-domain-to-another-aws-account \
                  --domain-name "$DOMAIN" --account-id "$TARGET_ACCOUNT_ID" \
                  --output json 2>"$ERR_TMP")" || TRANSFER_EC=$?
        if [[ $TRANSFER_EC -eq 0 ]]; then
          TRANSFER_OK=1; break
        fi
        grep -qi "operation in progress" "$ERR_TMP" 2>/dev/null || break  # non-retriable error
        [[ $WAITED -ge $MAX_WAIT ]] && break
        sleep $POLL_INTERVAL
        WAITED=$((WAITED + POLL_INTERVAL))
        echo "  Transfer still blocked, retrying... (${WAITED}s elapsed)"
      done
      if [[ $TRANSFER_OK -eq 0 ]]; then
        echo "ERROR initiating transfer for $DOMAIN (after cancel+retry):"
        cat "$ERR_TMP"
        ERR_ONE_LINE="$(tr '\n' ' ' <"$ERR_TMP" | sed 's/[[:space:]]\+/ /g' | cut -c1-240)"
        FAIL_ROWS+=("$DOMAIN"$'\t'"$ERR_ONE_LINE")
        sleep 0.5
        continue
      fi
    else
      if grep -qi "operation in progress" "$ERR_TMP" 2>/dev/null; then
        echo "NOTE: A transfer is already in progress for $DOMAIN. Re-run with --cancel-pending to cancel and retry."
      fi
      echo "ERROR initiating transfer for $DOMAIN:"
      cat "$ERR_TMP"
      ERR_ONE_LINE="$(tr '\n' ' ' <"$ERR_TMP" | sed 's/[[:space:]]\+/ /g' | cut -c1-240)"
      FAIL_ROWS+=("$DOMAIN"$'\t'"$ERR_ONE_LINE")
      sleep 0.5
      continue
    fi
  }

  # Issues 5+6: Parse Password/OperationId with piped one-liners and explicit fallback guards.
  # The former heredoc+herestring pattern (python3 - <<'PY' ... <<<"$RESP") has undefined
  # behaviour when both stdin sources conflict; the || guards prevent set -e from aborting
  # the whole script if parsing unexpectedly fails for a single domain.
  PASSWORD=""
  OPID=""

  if command -v jq >/dev/null 2>&1; then
    PASSWORD="$(echo "$RESP" | jq -r '.Password // empty' 2>/dev/null)" || PASSWORD=""
    OPID="$(echo    "$RESP" | jq -r '.OperationId // empty' 2>/dev/null)" || OPID=""
  else
    PASSWORD="$(echo "$RESP" | python3 -c \
      'import json,sys
try:
  j=json.load(sys.stdin); print(j.get("Password",""))
except Exception:
  print("")')" || PASSWORD=""
    OPID="$(echo "$RESP" | python3 -c \
      'import json,sys
try:
  j=json.load(sys.stdin); print(j.get("OperationId",""))
except Exception:
  print("")')" || OPID=""
  fi

  if [[ -z "$PASSWORD" ]]; then
    echo "WARNING: Transfer initiated but Password not captured."
    echo "Raw response:"
    echo "$RESP"
    FAIL_ROWS+=("$DOMAIN"$'\t'"Transfer started but Password not captured; check response/logs.")
    sleep 0.5
    continue
  fi

  echo "OperationId: ${OPID:-<none>}"
  echo "Password:    $PASSWORD"
  SUCCESS_ROWS+=("$DOMAIN"$'\t'"$PASSWORD"$'\t'"${OPID}")
  sleep 0.5
done

FINAL_EXIT=0
[[ ${#FAIL_ROWS[@]} -gt 0 ]] && FINAL_EXIT=2

echo
echo "==================== Summary ===================="
echo "Successful transfers: ${#SUCCESS_ROWS[@]}"
echo "Failed transfers:     ${#FAIL_ROWS[@]}"
[[ $DRY_RUN -eq 1 ]] && echo "Dry-run domains:      ${#DRY_RUN_ROWS[@]}"
echo

# Issue 7: tee writes into the already-chmod 600 file, preserving its permissions.
# Issue 11: printf instead of echo -e for reliable tab expansion across platforms.
{
  echo "Route 53 internal domain transfer passwords (SOURCE -> TARGET)"
  echo "Timestamp: $TS"
  echo "SourceAccountId: ${SOURCE_ACCT:-unknown}"
  echo "TargetAccountId: $TARGET_ACCOUNT_ID"
  echo "DryRun: $DRY_RUN"
  echo "DNSExport: $([[ $NO_DNS_EXPORT -eq 1 ]] && echo disabled || echo enabled)"
  echo
  printf "DOMAIN\tPASSWORD\tOPERATION_ID\n"
  printf -- "------\t--------\t------------\n"
  for row in "${SUCCESS_ROWS[@]}"; do
    printf "%s\n" "$row"
  done
  echo
  if [[ ${#FAIL_ROWS[@]} -gt 0 ]]; then
    echo "Failures / Notes:"
    printf "DOMAIN\tERROR\n"
    printf -- "------\t-----\n"
    for row in "${FAIL_ROWS[@]}"; do
      printf "%s\n" "$row"
    done
    echo
  fi
  # Issue 9: Dry-run entries printed under their own heading, not mixed into failures
  if [[ ${#DRY_RUN_ROWS[@]} -gt 0 ]]; then
    echo "Dry-run (no action taken):"
    printf "DOMAIN\tNOTE\n"
    printf -- "------\t----\n"
    for row in "${DRY_RUN_ROWS[@]}"; do
      printf "%s\n" "$row"
    done
  fi
} | tee "$OUTFILE"

echo
echo "Saved: $OUTFILE"

# Generate companion target script unless suppressed or dry-run
if [[ $NO_TARGET_SCRIPT -eq 1 ]]; then
  echo "Skipping companion target-account script due to --no-target-script."
  exit $FINAL_EXIT
fi

if [[ $DRY_RUN -eq 1 ]]; then
  echo "Dry-run enabled: not generating companion target-account script (no passwords exist)."
  exit $FINAL_EXIT
fi

if [[ ${#SUCCESS_ROWS[@]} -eq 0 ]]; then
  echo "No successful transfers; not generating companion target-account script."
  exit $FINAL_EXIT
fi

# ---------------------------------------------------------------------------
# DNS record export — for each successfully transferred domain, find its
# public hosted zone in Route 53 and capture all records except the apex NS
# and SOA (which Route 53 auto-generates for the new zone in the target account).
# ---------------------------------------------------------------------------
EMBED_DNS_RECORDS_B64=()   # parallel to EMBED_DOMAINS / EMBED_PASSWORDS_B64

if [[ $NO_DNS_EXPORT -eq 0 ]]; then
  echo
  echo "Exporting DNS records from source hosted zones..."
  DNS_ERR="$(mktemp)"; TMPFILES+=("$DNS_ERR")

  for row in "${SUCCESS_ROWS[@]}"; do
    DOMAIN="${row%%$'\t'*}"

    echo "  DNS export: $DOMAIN"

    # Find the public hosted zone ID for this domain name.
    # list-hosted-zones-by-name returns zones whose name >= the given name;
    # we pick the first one whose name matches exactly (trailing dot form).
    ZONE_RESP="$(aws route53 list-hosted-zones-by-name \
                   --dns-name "$DOMAIN" \
                   --max-items 10 \
                   --output json 2>"$DNS_ERR")" || {
      echo "  WARNING: Could not list hosted zones for $DOMAIN (skipping DNS export):"
      cat "$DNS_ERR"
      EMBED_DNS_RECORDS_B64+=('""')
      continue
    }

    ZONE_ID="$(echo "$ZONE_RESP" | python3 -c "
import json, sys
data = json.load(sys.stdin)
domain_dot = sys.argv[1] + '.'
for z in data.get('HostedZones', []):
    if z['Name'] == domain_dot and not z['Config']['PrivateZone']:
        # Strip /hostedzone/ prefix
        print(z['Id'].split('/')[-1])
        break
" "$DOMAIN" 2>/dev/null)" || ZONE_ID=""

    if [[ -z "$ZONE_ID" ]]; then
      echo "  WARNING: No public hosted zone found for $DOMAIN — DNS records will not be migrated."
      EMBED_DNS_RECORDS_B64+=('""')
      continue
    fi

    echo "    Found zone: $ZONE_ID"

    # Paginate list-resource-record-sets to collect all records.
    ALL_RECORDS_JSON="[]"
    RR_NEXT_NAME=""
    RR_NEXT_TYPE=""
    while true; do
      # AWS CLI pagination for list-resource-record-sets uses --start-record-name /
      # --start-record-type, not --starting-token.
      if [[ -n "$RR_NEXT_NAME" ]]; then
        RR_CMD=(aws route53 list-resource-record-sets
                 --hosted-zone-id "$ZONE_ID"
                 --max-items 300
                 --start-record-name "$RR_NEXT_NAME"
                 --start-record-type "$RR_NEXT_TYPE"
                 --output json)
      else
        RR_CMD=(aws route53 list-resource-record-sets
                 --hosted-zone-id "$ZONE_ID"
                 --max-items 300
                 --output json)
      fi

      RR_PAGE="$("${RR_CMD[@]}" 2>"$DNS_ERR")" || {
        echo "  WARNING: Failed to list records for $DOMAIN (zone $ZONE_ID); partial or no data:"
        cat "$DNS_ERR"
        break
      }

      # Merge this page into ALL_RECORDS_JSON and check for more pages.
      MERGE_RESULT="$(echo "$RR_PAGE" | python3 -c "
import json, sys
page = json.load(sys.stdin)
existing = json.loads(sys.argv[1])
existing.extend(page.get('ResourceRecordSets', []))
print(json.dumps(existing))
# Pagination tokens
is_trunc = page.get('IsTruncated', False)
next_name = page.get('NextRecordName', '')
next_type = page.get('NextRecordType', '')
print(str(is_trunc))
print(next_name)
print(next_type)
" "$ALL_RECORDS_JSON" 2>/dev/null)"

      ALL_RECORDS_JSON="$(echo "$MERGE_RESULT" | head -1)"
      IS_TRUNC="$(echo "$MERGE_RESULT" | sed -n '2p')"
      RR_NEXT_NAME="$(echo "$MERGE_RESULT" | sed -n '3p')"
      RR_NEXT_TYPE="$(echo "$MERGE_RESULT" | sed -n '4p')"

      # Guard against a silent Python parse failure: MERGE_RESULT empty means
      # json.loads() failed (e.g. malformed AWS response). Break with a warning
      # so the partial records collected so far are still exported.
      if [[ -z "$ALL_RECORDS_JSON" ]]; then
        echo "  WARNING: DNS record merge failed for $DOMAIN (malformed response page); exporting partial records."
        ALL_RECORDS_JSON="[]"
        break
      fi

      [[ "$IS_TRUNC" != "True" ]] && break
    done

    # Filter out apex NS and SOA records; warn about alias records pointing to
    # AWS-managed resources that will need to be recreated in the target account.
    FILTERED_JSON="$(echo "$ALL_RECORDS_JSON" | python3 -c "
import json, sys
records = json.load(sys.stdin)
domain_dot = sys.argv[1] + '.'
kept = []
alias_warnings = []
for r in records:
    rtype = r.get('Type', '')
    rname = r.get('Name', '')
    # Exclude apex NS and SOA — Route 53 auto-generates these for the new zone.
    if rname == domain_dot and rtype in ('NS', 'SOA'):
        continue
    # Warn about alias records; they may reference resources in the source account.
    if 'AliasTarget' in r:
        alias_warnings.append(rname + ' ' + rtype + ' -> ' + r['AliasTarget'].get('DNSName','?'))
    kept.append(r)
if alias_warnings:
    print('ALIAS_WARNINGS:' + '|'.join(alias_warnings), file=sys.stderr)
print(json.dumps(kept))
" "$DOMAIN" 2>"$DNS_ERR")" || FILTERED_JSON="[]"

    if [[ -s "$DNS_ERR" ]]; then
      while IFS= read -r warn_line; do
        if [[ "$warn_line" == ALIAS_WARNINGS:* ]]; then
          IFS='|' read -ra ALIASES <<< "${warn_line#ALIAS_WARNINGS:}"
          for alias_entry in "${ALIASES[@]}"; do
            echo "  WARNING: Alias record in $DOMAIN points to AWS resource — verify it exists in target account: $alias_entry"
          done
        else
          echo "  WARNING (DNS filter): $warn_line"
        fi
      done < "$DNS_ERR"
    fi

    RECORD_COUNT="$(echo "$FILTERED_JSON" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null)" || RECORD_COUNT="?"
    echo "    Exporting $RECORD_COUNT record(s) (apex NS and SOA excluded)."

    # Base64-encode the filtered JSON for safe embedding in the companion script.
    RECORDS_B64="$(echo "$FILTERED_JSON" | base64 | tr -d '\n')"
    EMBED_DNS_RECORDS_B64+=("\"${RECORDS_B64}\"")
  done
else
  # No DNS export requested; populate with empty placeholders so the parallel
  # array stays aligned with EMBED_DOMAINS / EMBED_PASSWORDS_B64.
  for row in "${SUCCESS_ROWS[@]}"; do
    EMBED_DNS_RECORDS_B64+=('""')
  done
  echo "DNS export skipped (--no-dns-export)."
fi

# Create the companion script file atomically with restricted permissions only at this
# point, after all early exits. This guarantees the file never exists as an empty orphan.
(umask 077; : > "$TARGET_SCRIPT_FILE")

# Build parallel arrays: domain names, base64-encoded passwords, operation IDs,
# and base64-encoded DNS record JSON.
# Base64 uses only printable ASCII (A-Z, a-z, 0-9, +, /, =), which is safe in double-quoted
# bash strings and survives clipboard, CloudShell browser upload, and cloud sync unchanged.
EMBED_DOMAINS=()
EMBED_PASSWORDS_B64=()
EMBED_OPIDS=()
for row in "${SUCCESS_ROWS[@]}"; do
  domain="${row%%$'\t'*}"
  rest="${row#*$'\t'}"
  pass="${rest%%$'\t'*}"
  opid="${rest#*$'\t'}"
  domain_esc="${domain//\\/\\\\}"; domain_esc="${domain_esc//\"/\\\"}"
  opid_esc="${opid//\\/\\\\}";     opid_esc="${opid_esc//\"/\\\"}"
  pass_b64="$(printf '%s' "$pass" | base64 | tr -d '\n')"
  EMBED_DOMAINS+=("\"${domain_esc}\"")
  EMBED_PASSWORDS_B64+=("\"${pass_b64}\"")
  EMBED_OPIDS+=("\"${opid_esc}\"")
done

# tee writes into the atomically-created 700-permission TARGET_SCRIPT_FILE, preserving its permissions.
{
  cat <<'HEADER'
#!/usr/bin/env bash
set -euo pipefail

# Companion script generated by r53-transfer-out.sh
# Purpose: run in the TARGET AWS account CloudShell to accept Route 53 domain
#          transfers, create hosted zones, restore DNS records, and update
#          the registered domain nameservers.
#
# IMPORTANT: This script contains transfer passwords. Handle securely.
HEADER

  echo "# SourceAccountId: ${SOURCE_ACCT:-unknown}"
  echo "# TargetAccountId: $TARGET_ACCOUNT_ID"
  echo "# Generated: $TS"
  echo "# DNSExport: $([[ $NO_DNS_EXPORT -eq 1 ]] && echo disabled || echo enabled)"
  echo

  cat <<'FUNCS'
command -v aws     >/dev/null 2>&1 || { echo "ERROR: aws CLI not found."; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 not found."; exit 1; }

CALLER_ACCT="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"
echo "Running in AWS Account: ${CALLER_ACCT:-<unknown>}"
FUNCS

  echo "echo \"Expected TARGET account: $TARGET_ACCOUNT_ID\""
  echo "if [[ -n \"\$CALLER_ACCT\" && \"\$CALLER_ACCT\" != \"$TARGET_ACCOUNT_ID\" ]]; then"
  echo "  echo \"WARNING: You are not in the expected target account. Continue? (y/N)\""
  echo "  read -r ans"
  echo "  [[ \"\$ans\" =~ ^[Yy]$ ]] || exit 1"
  echo "fi"
  echo

  echo "DOMAINS=("
  for d in "${EMBED_DOMAINS[@]}"; do
    echo "  $d"
  done
  echo ")"
  echo

  echo "PASSWORDS_B64=("
  for p in "${EMBED_PASSWORDS_B64[@]}"; do
    echo "  $p"
  done
  echo ")"
  echo

  echo "OPIDS=("
  for o in "${EMBED_OPIDS[@]}"; do
    echo "  $o"
  done
  echo ")"
  echo

  echo "DNS_RECORDS_B64=("
  for dr in "${EMBED_DNS_RECORDS_B64[@]}"; do
    echo "  $dr"
  done
  echo ")"
  echo

  # -------------------------------------------------------------------------
  # Phase 1: accept transfers, create hosted zones, import DNS records
  # -------------------------------------------------------------------------
  cat <<'PHASE1_START'
SUCCESS=0
FAIL=0

# NEW_ZONE_IDS and NEW_ZONE_NS are populated during Phase 1 and consumed in Phase 2.
NEW_ZONE_IDS=()   # hosted zone ID (without /hostedzone/ prefix) for each domain
NEW_ZONE_NS=()    # space-separated NS values for each domain

for i in "${!DOMAINS[@]}"; do
  DOMAIN="${DOMAINS[$i]}"
  PASSWORD="$(printf '%s' "${PASSWORDS_B64[$i]}" | base64 -d)"
  echo "----"
  echo "Domain: $DOMAIN"

  # ------------------------------------------------------------------
  # Step 1: Accept the domain transfer from the source account.
  # ------------------------------------------------------------------
  echo "  [1/3] Accepting domain transfer..."
  ACCEPT_RESP="$(aws route53domains --region us-east-1 \
    accept-domain-transfer-from-another-aws-account \
    --domain-name "$DOMAIN" \
    --password "$PASSWORD" \
    --output json 2>&1)" || {
    echo "  ERROR accepting transfer for $DOMAIN:"
    echo "  $ACCEPT_RESP"
    FAIL=$((FAIL+1))
    NEW_ZONE_IDS+=("")
    NEW_ZONE_NS+=("")
    continue
  }
  echo "  Accepted. Response: $ACCEPT_RESP"

  # ------------------------------------------------------------------
  # Step 2: Create a new hosted zone in this (target) account.
  # The zone gets brand-new NS records assigned by Route 53.
  # ------------------------------------------------------------------
  echo "  [2/3] Creating hosted zone..."
  CALLER_REF="transfer-${DOMAIN}-$(date +%s)"
  CREATE_RESP="$(aws route53 create-hosted-zone \
    --name "$DOMAIN" \
    --caller-reference "$CALLER_REF" \
    --output json 2>&1)" || {
    echo "  ERROR creating hosted zone for $DOMAIN:"
    echo "  $CREATE_RESP"
    FAIL=$((FAIL+1))
    NEW_ZONE_IDS+=("")
    NEW_ZONE_NS+=("")
    continue
  }

  NEW_ZONE_FULL_ID="$(echo "$CREATE_RESP" | python3 -c \
    "import json,sys; print(json.load(sys.stdin)['HostedZone']['Id'])" 2>/dev/null)" || NEW_ZONE_FULL_ID=""
  NEW_ZONE_ID="${NEW_ZONE_FULL_ID##*/hostedzone/}"
  NEW_ZONE_ID="${NEW_ZONE_ID##*/}"   # strip /hostedzone/ prefix robustly

  if [[ -z "$NEW_ZONE_ID" ]]; then
    echo "  ERROR: Could not parse new hosted zone ID from response."
    echo "  $CREATE_RESP"
    FAIL=$((FAIL+1))
    NEW_ZONE_IDS+=("")
    NEW_ZONE_NS+=("")
    continue
  fi

  echo "  New hosted zone ID: $NEW_ZONE_ID"

  # Retrieve the NS records Route 53 assigned to the new zone.
  NS_RESP="$(aws route53 list-resource-record-sets \
    --hosted-zone-id "$NEW_ZONE_ID" \
    --query "ResourceRecordSets[?Type=='NS'].ResourceRecords[].Value" \
    --output text 2>/dev/null)" || NS_RESP=""

  NEW_ZONE_IDS+=("$NEW_ZONE_ID")
  NEW_ZONE_NS+=("$NS_RESP")

  echo "  New zone nameservers: $NS_RESP"

  # ------------------------------------------------------------------
  # Step 3: Restore DNS records exported from the source account.
  # ------------------------------------------------------------------
  DNS_B64="${DNS_RECORDS_B64[$i]}"
  if [[ -z "$DNS_B64" ]]; then
    echo "  [3/3] No DNS records to restore (export was skipped or zone not found in source)."
    SUCCESS=$((SUCCESS+1))
    continue
  fi

  echo "  [3/3] Restoring DNS records..."
  DNS_JSON="$(printf '%s' "$DNS_B64" | base64 -d 2>/dev/null)" || DNS_JSON="[]"

  RECORD_COUNT="$(echo "$DNS_JSON" | python3 -c \
    "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null)" || RECORD_COUNT=0

  if [[ "$RECORD_COUNT" -eq 0 ]]; then
    echo "  No records to restore."
    SUCCESS=$((SUCCESS+1))
    continue
  fi

  echo "  Restoring $RECORD_COUNT record(s) in batches of 500..."

  # python3 builds and applies batches of up to 500 CREATE changes.
  python3 - "$DNS_JSON" "$NEW_ZONE_ID" <<'PYEOF' && PY_STATUS=0 || PY_STATUS=$?
import json, sys, subprocess, math

records = json.loads(sys.argv[1])
zone_id = sys.argv[2]
batch_size = 500

def apply_batch(changes, zone_id):
    change_batch = {"Comment": "Restored by r53-transfer-out companion script", "Changes": changes}
    result = subprocess.run(
        ["aws", "route53", "change-resource-record-sets",
         "--hosted-zone-id", zone_id,
         "--change-batch", json.dumps(change_batch),
         "--output", "json"],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        print(f"  ERROR applying batch: {result.stderr.strip()}", file=sys.stderr)
        return False
    resp = json.loads(result.stdout)
    status = resp.get("ChangeInfo", {}).get("Status", "?")
    change_id = resp.get("ChangeInfo", {}).get("Id", "?")
    print(f"  Batch applied — ChangeId: {change_id}  Status: {status}")
    return True

total_batches = math.ceil(len(records) / batch_size)
failed_batches = 0
for batch_num in range(total_batches):
    chunk = records[batch_num * batch_size : (batch_num + 1) * batch_size]
    changes = [{"Action": "CREATE", "ResourceRecordSet": r} for r in chunk]
    print(f"  Applying batch {batch_num + 1}/{total_batches} ({len(changes)} records)...")
    if not apply_batch(changes, zone_id):
        failed_batches += 1

if failed_batches:
    print(f"  WARNING: {failed_batches} batch(es) failed. Some records may be missing.")
    sys.exit(1)
else:
    print(f"  All {len(records)} record(s) restored successfully.")
PYEOF
  if [[ $PY_STATUS -ne 0 ]]; then
    echo "  WARNING: DNS record restore encountered errors for $DOMAIN."
    FAIL=$((FAIL+1))
  else
    SUCCESS=$((SUCCESS+1))
  fi

done

PHASE1_START

  # -------------------------------------------------------------------------
  # Phase 2: poll for domain transfer completion, then update nameservers
  # -------------------------------------------------------------------------
  cat <<'PHASE2'

echo
echo "==================== Phase 2: Updating domain nameservers ===================="
echo "Polling for domain transfer operations to complete (timeout: 30 min per domain)..."
echo "Note: transfers can take several minutes. The script will wait and retry."
echo

NS_SUCCESS=0
NS_FAIL=0

for i in "${!DOMAINS[@]}"; do
  DOMAIN="${DOMAINS[$i]}"
  OPID="${OPIDS[$i]}"
  ZONE_ID="${NEW_ZONE_IDS[$i]:-}"
  ZONE_NS="${NEW_ZONE_NS[$i]:-}"

  echo "----"
  echo "Domain: $DOMAIN"

  if [[ -z "$ZONE_ID" ]]; then
    echo "  Skipping nameserver update — no hosted zone was created for this domain."
    NS_FAIL=$((NS_FAIL+1))
    continue
  fi

  if [[ -z "$OPID" ]]; then
    echo "  WARNING: No OperationId recorded for this domain — skipping transfer poll."
    echo "  Attempting nameserver update directly..."
  else
    # Poll operation status until SUCCESSFUL, FAILED, or timeout (30 min).
    TIMEOUT_SECS=1800
    SLEEP_SECS=30
    ELAPSED=0
    OP_STATUS="UNKNOWN"
    echo "  Polling transfer OperationId: $OPID"
    while [[ $ELAPSED -lt $TIMEOUT_SECS ]]; do
      OP_RESP="$(aws route53domains --region us-east-1 get-operation-detail \
        --operation-id "$OPID" --output json 2>/dev/null)" || OP_RESP="{}"
      OP_STATUS="$(echo "$OP_RESP" | python3 -c \
        "import json,sys; print(json.load(sys.stdin).get('Status','UNKNOWN'))" 2>/dev/null)" || OP_STATUS="UNKNOWN"

      echo "  Status: $OP_STATUS (elapsed: ${ELAPSED}s)"

      if [[ "$OP_STATUS" == "SUCCESSFUL" ]]; then
        break
      elif [[ "$OP_STATUS" == "FAILED" || "$OP_STATUS" == "ERROR" ]]; then
        break
      fi

      sleep "$SLEEP_SECS"
      ELAPSED=$((ELAPSED + SLEEP_SECS))
    done

    if [[ "$OP_STATUS" != "SUCCESSFUL" ]]; then
      echo "  WARNING: Transfer operation did not complete successfully (status: $OP_STATUS)."
      echo "  The nameserver update below may fail if the domain is not yet in this account."
      echo "  You can retry manually once the transfer completes:"
    fi
  fi

  # Build the nameservers JSON array from the space-separated NS list.
  if [[ -z "$ZONE_NS" ]]; then
    echo "  WARNING: No nameserver values found for zone $ZONE_ID — fetching now..."
    ZONE_NS="$(aws route53 list-resource-record-sets \
      --hosted-zone-id "$ZONE_ID" \
      --query "ResourceRecordSets[?Type=='NS'].ResourceRecords[].Value" \
      --output text 2>/dev/null)" || ZONE_NS=""
  fi

  if [[ -z "$ZONE_NS" ]]; then
    echo "  ERROR: Cannot determine nameservers for zone $ZONE_ID. Skipping nameserver update."
    echo "  Manual command once you know the NS values:"
    echo "    aws route53domains update-domain-nameservers --region us-east-1 \\"
    echo "      --domain-name \"$DOMAIN\" \\"
    echo "      --nameservers '[{\"Name\":\"ns-?.awsdns-?.net\"}, ...]'"
    NS_FAIL=$((NS_FAIL+1))
    continue
  fi

  # Convert whitespace-separated NS list to JSON array of {Name: ...} objects.
  NS_JSON="$(echo "$ZONE_NS" | python3 -c "
import sys, json
# Strip trailing dots that Route 53 sometimes appends.
vals = [v.rstrip('.') for v in sys.stdin.read().split() if v]
print(json.dumps([{'Name': v} for v in vals]))
" 2>/dev/null)" || NS_JSON="[]"

  echo "  Updating domain nameservers to: $ZONE_NS"
  echo "  Manual equivalent:"
  echo "    aws route53domains update-domain-nameservers --region us-east-1 \\"
  echo "      --domain-name \"$DOMAIN\" --nameservers '$NS_JSON'"

  NS_RESP="$(aws route53domains --region us-east-1 update-domain-nameservers \
    --domain-name "$DOMAIN" \
    --nameservers "$NS_JSON" \
    --output json 2>&1)" || {
    echo "  ERROR updating nameservers for $DOMAIN:"
    echo "  $NS_RESP"
    echo "  Retry the manual command above once the domain transfer has completed."
    NS_FAIL=$((NS_FAIL+1))
    continue
  }

  echo "  Nameservers updated successfully. Response: $NS_RESP"
  NS_SUCCESS=$((NS_SUCCESS+1))
done

echo
echo "==================== Final Summary ===================="
echo "Phase 1 (accept + zone create + DNS restore):"
echo "  Succeeded: $SUCCESS    Failed: $FAIL"
echo "Phase 2 (nameserver updates):"
echo "  Succeeded: $NS_SUCCESS    Failed/Skipped: $NS_FAIL"
PHASE2

} | tee "$TARGET_SCRIPT_FILE"

echo
echo "Companion target-account script saved: $TARGET_SCRIPT_FILE"
echo "You can copy/paste the printed script above into the target account CloudShell, or upload and run:"
echo "  bash \"$TARGET_SCRIPT_FILE\""

exit $FINAL_EXIT
