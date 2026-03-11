#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: r53-transfer-out.sh [--target-account=123456789012] [--dry-run] [--no-target-script]

Options:
  --target-account=<account ID>  12-digit AWS account ID to transfer domains to (skips prompt if valid)
  --dry-run                      Show what would happen without initiating any transfers
  --no-target-script             Do not print/save the companion target-account accept script
USAGE
}

TARGET_ACCOUNT_ID=""
DRY_RUN=0
NO_TARGET_SCRIPT=0

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

SUCCESS_ROWS=()    # "domain<TAB>password"
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
    echo "ERROR initiating transfer for $DOMAIN:"
    cat "$ERR_TMP"
    ERR_ONE_LINE="$(tr '\n' ' ' <"$ERR_TMP" | sed 's/[[:space:]]\+/ /g' | cut -c1-240)"
    FAIL_ROWS+=("$DOMAIN"$'\t'"$ERR_ONE_LINE")
    sleep 0.5
    continue
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
  SUCCESS_ROWS+=("$DOMAIN"$'\t'"$PASSWORD")
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
  echo
  printf "DOMAIN\tPASSWORD\n"
  printf -- "------\t--------\n"
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

# Create the companion script file atomically with restricted permissions only at this
# point, after all early exits. This guarantees the file never exists as an empty orphan.
(umask 077; : > "$TARGET_SCRIPT_FILE")

# Build parallel arrays: domain names and base64-encoded passwords.
# Base64 uses only printable ASCII (A-Z, a-z, 0-9, +, /, =), which is safe in double-quoted
# bash strings and survives clipboard, CloudShell browser upload, and cloud sync unchanged.
# This replaces the former SOH-delimiter approach: SOH (\x01) is a non-printable control
# character silently stripped by many transfer paths, causing "Password is incorrect" errors.
# Base64 also sidesteps incomplete escaping — no shell-special characters ($, `, !) can
# appear in base64 output, so no per-character escaping of passwords is needed.
EMBED_DOMAINS=()
EMBED_PASSWORDS_B64=()
for row in "${SUCCESS_ROWS[@]}"; do
  domain="${row%%$'\t'*}"
  pass="${row#*$'\t'}"
  domain_esc="${domain//\\/\\\\}"; domain_esc="${domain_esc//\"/\\\"}"
  # tr -d '\n' strips GNU base64 line-wrap newlines portably on both Linux and macOS.
  pass_b64="$(printf '%s' "$pass" | base64 | tr -d '\n')"
  EMBED_DOMAINS+=("\"${domain_esc}\"")
  EMBED_PASSWORDS_B64+=("\"${pass_b64}\"")
done

# tee writes into the atomically-created 700-permission TARGET_SCRIPT_FILE, preserving its permissions.
{
  echo "#!/usr/bin/env bash"
  echo "set -euo pipefail"
  echo
  echo "# Companion script generated by r53-transfer-out.sh"
  echo "# Purpose: run in the TARGET AWS account CloudShell to accept Route 53 domain transfers."
  echo "# SourceAccountId: ${SOURCE_ACCT:-unknown}"
  echo "# TargetAccountId: $TARGET_ACCOUNT_ID"
  echo "# Generated: $TS"
  echo "#"
  echo "# IMPORTANT: This script contains transfer passwords. Handle securely."
  echo
  echo "command -v aws >/dev/null 2>&1 || { echo \"ERROR: aws CLI not found.\"; exit 1; }"
  echo
  echo "CALLER_ACCT=\"\$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)\""
  echo "echo \"Running in AWS Account: \${CALLER_ACCT:-<unknown>}\""
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
  echo "SUCCESS=0"
  echo "FAIL=0"
  echo
  echo "for i in \"\${!DOMAINS[@]}\"; do"
  echo "  DOMAIN=\"\${DOMAINS[\$i]}\""
  echo "  PASSWORD=\"\$(printf '%s' \"\${PASSWORDS_B64[\$i]}\" | base64 -d)\""
  echo "  echo \"----\""
  echo "  echo \"Accepting transfer for: \$DOMAIN\""
  echo "  RESP=\"\$(aws route53domains --region us-east-1 accept-domain-transfer-from-another-aws-account \\"
  echo "            --domain-name \"\$DOMAIN\" \\"
  echo "            --password \"\$PASSWORD\" \\"
  echo "            --output json 2>&1)\" || {"
  echo "    echo \"ERROR accepting transfer for \$DOMAIN:\""
  echo "    echo \"\$RESP\""
  echo "    FAIL=\$((FAIL+1))"
  echo "    continue"
  echo "  }"
  echo "  echo \"Accepted. Response:\""
  echo "  echo \"\$RESP\""
  echo "  SUCCESS=\$((SUCCESS+1))"
  echo "done"
  echo
  echo "echo"
  echo "echo \"Done. Accepted: \$SUCCESS  Failed: \$FAIL\""
} | tee "$TARGET_SCRIPT_FILE"

echo
echo "Companion target-account script saved: $TARGET_SCRIPT_FILE"
echo "You can copy/paste the printed script above into the target account CloudShell, or upload and run:"
echo "  bash \"$TARGET_SCRIPT_FILE\""

exit $FINAL_EXIT
