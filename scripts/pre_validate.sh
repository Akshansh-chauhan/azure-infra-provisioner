#!/usr/bin/env bash
# =============================================================================
#  pre_validate.sh - Pre-Apply Azure Availability Checks
# =============================================================================
#  Called AFTER user input is collected, BEFORE terraform plan/apply.
#  Catches issues that would cause partial failures:
#    1. VM SKU availability in the selected region
#    2. Key Vault name global collisions (active + soft-deleted)
#    3. Storage account name global collisions
# =============================================================================

set -uo pipefail

# Colors (safe to re-define — sourced scripts may not have them)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "  ${GREEN}✓${NC} $1"; }
warn()    { echo -e "  ${YELLOW}⚠${NC} $1"; }
error()   { echo -e "  ${RED}✗${NC} $1"; }
waiting() { echo -en "  ${CYAN}⏳${NC} $1"; }

section() {
  echo ""
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}  $1${NC}"
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}


# =============================================================================
# 1. CHECK VM SKU AVAILABILITY
# =============================================================================
# Checks if VM size is available. Only fails if blocked in ALL zones.
# If some zones are restricted, shows which zones ARE available.
# =============================================================================
check_vm_sku_availability() {
  local region="$1"
  shift
  local vm_sizes=("$@")

  local failures=0
  local checked=()

  for size in "${vm_sizes[@]}"; do
    # Skip duplicates
    local already_checked=false
    for c in "${checked[@]+"${checked[@]}"}"; do
      [[ "$c" == "$size" ]] && already_checked=true && break
    done
    [[ "$already_checked" == "true" ]] && continue
    checked+=("$size")

    waiting "Checking ${BOLD}${size}${NC} in ${BOLD}${region}${NC}..."

    local sku_info
    sku_info=$(az vm list-skus \
      --location "$region" \
      --size "$size" \
      --resource-type virtualMachines \
      --query "[0]" \
      -o json 2>/dev/null)

    echo ""

    if [[ -z "$sku_info" || "$sku_info" == "null" ]]; then
      error "'${size}' does not exist in '${region}'."
      failures=$((failures + 1))
      continue
    fi

    # Parse: get all supported zones and all blocked zones
    local result
    result=$(echo "$sku_info" | python3 -c "
import sys, json
data = json.load(sys.stdin)

# All zones this SKU supports in this region
all_zones = set()
for loc in data.get('locationInfo', []):
    for z in loc.get('zones', []):
        all_zones.add(z)

# Zones that are restricted
blocked_zones = set()
location_blocked = False

for r in data.get('restrictions', []):
    rtype = r.get('type', '')
    reason = r.get('reasonCode', '')
    if reason == 'NotAvailableForSubscription':
        if rtype == 'Location':
            location_blocked = True
        elif rtype == 'Zone':
            for z in r.get('restrictionInfo', {}).get('zones', []):
                blocked_zones.add(z)

if location_blocked:
    print('BLOCKED')
elif not all_zones:
    # No zone info = non-zonal region, no restrictions = available
    print('AVAILABLE:nozones')
else:
    available = sorted(all_zones - blocked_zones)
    if not available:
        print('ALL_ZONES_BLOCKED')
    elif blocked_zones:
        print(f'PARTIAL:{','.join(available)}')
    else:
        print(f'AVAILABLE:{','.join(sorted(all_zones))}')
" 2>/dev/null)

    if [[ "$result" == AVAILABLE* ]]; then
      local zones="${result#AVAILABLE:}"
      if [[ "$zones" == "nozones" ]]; then
        info "'${size}' is available in '${region}'."
      else
        info "'${size}' is available in '${region}' (zones: ${zones})."
      fi
    elif [[ "$result" == PARTIAL* ]]; then
      local avail_zones="${result#PARTIAL:}"
      warn "'${size}' — restricted in some zones, but available in zone(s): ${BOLD}${avail_zones}${NC}"
      warn "  Deployment will work — Azure uses an available zone."
      # NOT a failure
    elif [[ "$result" == "BLOCKED" || "$result" == "ALL_ZONES_BLOCKED" ]]; then
      error "'${size}' is fully blocked in '${region}' — no zones available."
      error "  Try a different size or region."
      failures=$((failures + 1))
    else
      warn "'${size}' — could not determine availability. Proceeding anyway."
    fi
  done

  return $failures
}


# =============================================================================
# 2. CHECK KEY VAULT NAME AVAILABILITY
# =============================================================================
# Key Vault names are globally unique. Even deleted vaults (soft-delete)
# block the name until purged. This checks both active and soft-deleted.
# =============================================================================
check_keyvault_name() {
  local kv_name="$1"

  waiting "Checking Key Vault name '${BOLD}${kv_name}${NC}' availability..."
  echo ""

  # Check for active vault with this name in current subscription
  local active_vault
  active_vault=$(az keyvault list --query "[?name=='${kv_name}'].name" -o tsv 2>/dev/null)

  if [[ -n "$active_vault" ]]; then
    error "Key Vault '${kv_name}' already exists as an active vault."
    error "  Use a different project name to generate a unique vault name,"
    error "  or delete the existing vault first."
    return 1
  fi

  # Check for soft-deleted vault
  local deleted_vault
  deleted_vault=$(az keyvault list-deleted \
    --query "[?name=='${kv_name}'].name" \
    -o tsv 2>/dev/null)

  if [[ -n "$deleted_vault" ]]; then
    error "Key Vault '${kv_name}' exists as a SOFT-DELETED vault."
    error "  It was previously deleted but not purged."
    echo ""
    warn "  Options:"
    echo "    1. Purge it:  az keyvault purge --name ${kv_name}"
    echo "    2. Recover it: az keyvault recover --name ${kv_name}"
    echo "    3. Use a different project name"
    echo ""

    # Offer to auto-purge
    if command -v ask_yes_no &>/dev/null; then
      if ask_yes_no "Purge the soft-deleted vault '${kv_name}' now?" "n"; then
        waiting "Purging '${kv_name}'..."
        if az keyvault purge --name "$kv_name" 2>/dev/null; then
          echo ""
          info "Vault '${kv_name}' purged successfully. Name is now available."
          return 0
        else
          echo ""
          error "Failed to purge. You may not have permission, or purge protection is enabled."
          return 1
        fi
      fi
    fi

    return 1
  fi

  info "Key Vault name '${kv_name}' is available."
  return 0
}


# =============================================================================
# 3. CHECK STORAGE ACCOUNT NAME AVAILABILITY
# =============================================================================
# Storage account names are also globally unique (3-24 chars, lowercase+numbers only).
# =============================================================================
check_storage_name() {
  local sa_name="$1"

  waiting "Checking Storage Account name '${BOLD}${sa_name}${NC}' availability..."
  echo ""

  local result
  result=$(az storage account check-name \
    --name "$sa_name" \
    --query "{available:nameAvailable, reason:reason, message:message}" \
    -o json 2>/dev/null)

  local available
  available=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('available', False))" 2>/dev/null)

  if [[ "$available" == "True" ]]; then
    info "Storage Account name '${sa_name}' is available."
    return 0
  else
    local message
    message=$(echo "$result" | python3 -c "import sys,json; print(json.load(sys.stdin).get('message', 'Name not available'))" 2>/dev/null)
    error "Storage Account name '${sa_name}' is NOT available."
    error "  $message"
    return 1
  fi
}


# =============================================================================
# 4. MAIN: RUN ALL PRE-VALIDATION CHECKS
# =============================================================================
run_pre_validation() {
  local project_name="$1"
  local environment="$2"
  local region="$3"
  local enable_kv="$4"
  local enable_storage="$5"
  shift 5
  local vm_sizes=("$@")

  section "Pre-Apply Validation (Azure Availability Checks)"
  echo ""
  echo -e "  Verifying that your chosen resources are actually available"
  echo -e "  in ${BOLD}${region}${NC} before spending time on terraform apply."
  echo ""

  local total_failures=0

  # ── VM SKU availability ──
  if [[ ${#vm_sizes[@]} -gt 0 ]]; then
    check_vm_sku_availability "$region" "${vm_sizes[@]}"
    total_failures=$((total_failures + $?))
  fi

  echo ""

  # ── Key Vault name check ──
  if [[ "$enable_kv" == "true" ]]; then
    local kv_name
    kv_name=$(echo "${project_name}-${environment}-kv" | cut -c1-24)
    check_keyvault_name "$kv_name"
    total_failures=$((total_failures + $?))
  else
    info "Key Vault: skipped (not enabled)."
  fi

  echo ""

  # ── Storage Account name check ──
  if [[ "$enable_storage" == "true" ]]; then
    local sa_name
    sa_name=$(echo "${project_name}${environment}sa" | tr -d '-' | cut -c1-24)
    check_storage_name "$sa_name"
    total_failures=$((total_failures + $?))
  else
    info "Storage Account: skipped (not enabled)."
  fi

  echo ""

  # ── Summary ──
  if [[ $total_failures -gt 0 ]]; then
    echo ""
    error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    error "  ${total_failures} pre-validation check(s) FAILED."
    error "  Terraform will NOT be run — fix the issues above first."
    error "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    warn "  Common fixes:"
    echo "    • VM SKU unavailable → pick a different size or region"
    echo "    • Key Vault name taken → use a more unique project name"
    echo "    • Storage name taken → use a more unique project name"
    echo ""
    return 1
  else
    echo ""
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    info "  All pre-validation checks PASSED. Safe to proceed."
    info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    return 0
  fi
}

# Allow standalone execution for testing
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [[ $# -lt 5 ]]; then
    echo "Usage: $0 <project_name> <environment> <region> <enable_kv> <enable_storage> [vm_sizes...]"
    echo "Example: $0 myapp dev eastus true true Standard_B2s Standard_D2s_v3"
    exit 1
  fi
  run_pre_validation "$@"
fi
