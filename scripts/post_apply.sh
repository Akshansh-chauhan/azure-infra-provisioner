#!/usr/bin/env bash
# =============================================================================
#  post_apply.sh - Post-Apply Verification & Detailed CSV Export
# =============================================================================
#  Called after terraform apply succeeds. This script:
#    1. Reads terraform outputs to discover what was provisioned
#    2. Polls Azure to verify each resource is in ProvisioningState=Succeeded
#    3. Waits for VMs to reach PowerState/running
#    4. Generates a detailed, business-grade CSV with full resource metadata
# =============================================================================

set -uo pipefail

# =============================================================================
# COLORS (inherited from provision.sh, but defined here for standalone use)
# =============================================================================
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
# CONFIGURATION
# =============================================================================
MAX_POLL_ATTEMPTS=30        # Max polling iterations
POLL_INTERVAL_SECONDS=10    # Seconds between each poll
VM_BOOT_TIMEOUT=180         # Max seconds to wait for VM PowerState/running

# =============================================================================
# 1. VERIFY RESOURCES EXIST AND ARE HEALTHY
# =============================================================================
verify_resources() {
  local rg_name="$1"
  local project_name="$2"
  local environment="$3"

  section "Post-Apply Verification"
  echo ""
  echo -e "  Verifying all resources in resource group: ${BOLD}${rg_name}${NC}"
  echo ""

  # -------------------------------------------------------------------------
  # Step 1: Wait for the Resource Group itself to show ProvisioningState
  # -------------------------------------------------------------------------
  waiting "Checking resource group '${rg_name}'..."
  local rg_state
  rg_state=$(az group show --name "$rg_name" --query "properties.provisioningState" -o tsv 2>/dev/null)
  if [[ "$rg_state" == "Succeeded" ]]; then
    echo ""
    info "Resource group '${rg_name}' — Provisioning state: ${GREEN}Succeeded${NC}"
  else
    echo ""
    error "Resource group '${rg_name}' — Provisioning state: ${rg_state:-NOT FOUND}"
    error "Cannot proceed without a healthy resource group."
    return 1
  fi

  # -------------------------------------------------------------------------
  # Step 2: List all resources in the RG and poll until all are Succeeded
  # -------------------------------------------------------------------------
  echo ""
  waiting "Discovering resources in '${rg_name}'...\n"

  local attempt=0
  local all_succeeded=false

  while [[ $attempt -lt $MAX_POLL_ATTEMPTS ]]; do
    attempt=$((attempt + 1))

    # Fetch all resources with their provisioning state
    local resource_json
    resource_json=$(az resource list \
      --resource-group "$rg_name" \
      --query "[].{name:name, type:type, provisioningState:provisioningState, location:location}" \
      -o json 2>/dev/null)

    local total_count
    total_count=$(echo "$resource_json" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

    if [[ "$total_count" -eq 0 ]]; then
      if [[ $attempt -lt 5 ]]; then
        echo -e "  ${CYAN}⏳${NC} Attempt $attempt/$MAX_POLL_ATTEMPTS — Resources still being registered, waiting ${POLL_INTERVAL_SECONDS}s..."
        sleep "$POLL_INTERVAL_SECONDS"
        continue
      else
        error "No resources found in '$rg_name' after $attempt attempts."
        return 1
      fi
    fi

    # Count how many are in non-Succeeded states
    local pending_count
    pending_count=$(echo "$resource_json" | python3 -c "
import sys, json
resources = json.load(sys.stdin)
pending = [r for r in resources if r.get('provisioningState','') != 'Succeeded']
print(len(pending))
" 2>/dev/null || echo "0")

    local succeeded_count=$((total_count - pending_count))

    if [[ "$pending_count" -eq 0 ]]; then
      all_succeeded=true
      echo ""
      info "All ${total_count} resources — Provisioning state: ${GREEN}Succeeded${NC}"
      break
    else
      echo -e "  ${CYAN}⏳${NC} Attempt $attempt/$MAX_POLL_ATTEMPTS — ${succeeded_count}/${total_count} resources succeeded, ${pending_count} still provisioning... (waiting ${POLL_INTERVAL_SECONDS}s)"
      sleep "$POLL_INTERVAL_SECONDS"
    fi
  done

  if [[ "$all_succeeded" != "true" ]]; then
    echo ""
    warn "Some resources did not reach 'Succeeded' state within the timeout."
    warn "Listing current states:"
    az resource list --resource-group "$rg_name" \
      --query "[?provisioningState!='Succeeded'].{Name:name, Type:type, State:provisioningState}" \
      -o table 2>/dev/null | sed 's/^/    /'
    echo ""
    warn "Proceeding with CSV generation anyway (will note states in the report)."
  fi

  # -------------------------------------------------------------------------
  # Step 3: VM-specific — wait for PowerState/running
  # -------------------------------------------------------------------------
  echo ""
  waiting "Checking VM power states...\n"

  local vm_names
  vm_names=$(az vm list --resource-group "$rg_name" --query "[].name" -o tsv 2>/dev/null)

  if [[ -n "$vm_names" ]]; then
    local vm_start_time=$SECONDS
    local all_vms_running=false

    while [[ $(( SECONDS - vm_start_time )) -lt $VM_BOOT_TIMEOUT ]]; do
      all_vms_running=true

      while IFS= read -r vm_name; do
        local power_state
        power_state=$(az vm get-instance-view \
          --resource-group "$rg_name" \
          --name "$vm_name" \
          --query "instanceView.statuses[?starts_with(code,'PowerState/')].displayStatus" \
          -o tsv 2>/dev/null)

        if [[ "$power_state" == "VM running" ]]; then
          info "VM '${vm_name}' — Power state: ${GREEN}Running${NC}"
        else
          echo -e "  ${CYAN}⏳${NC} VM '${vm_name}' — Power state: ${power_state:-Pending} (waiting...)"
          all_vms_running=false
        fi
      done <<< "$vm_names"

      if [[ "$all_vms_running" == "true" ]]; then
        break
      fi

      echo -e "  ${CYAN}⏳${NC} Waiting ${POLL_INTERVAL_SECONDS}s for VMs to boot..."
      sleep "$POLL_INTERVAL_SECONDS"
    done

    if [[ "$all_vms_running" != "true" ]]; then
      warn "Some VMs did not reach 'Running' state within ${VM_BOOT_TIMEOUT}s timeout."
      warn "They may still be booting. Check the Azure portal for details."
    else
      echo ""
      info "All VMs confirmed running."
    fi
  else
    info "No VMs found in this resource group (skipping power state check)."
  fi

  echo ""
  info "Resource verification complete."
  return 0
}


# =============================================================================
# 2. GENERATE DETAILED BUSINESS-GRADE CSV
# =============================================================================
generate_csv() {
  local rg_name="$1"
  local project_name="$2"
  local environment="$3"
  local output_dir="$4"

  section "Generating Detailed Resource Report (CSV)"
  echo ""

  local timestamp
  timestamp=$(date '+%Y%m%d-%H%M%S')
  local csv_file="${output_dir}/${project_name}-${environment}-resources-${timestamp}.csv"

  # -------------------------------------------------------------------------
  # CSV Header — business-grade columns
  # -------------------------------------------------------------------------
  cat > "$csv_file" <<'HEADER'
"Resource Name","Resource Type","Resource Group","Location","Provisioning State","SKU / VM Size","OS Publisher","OS Offer","OS SKU","OS Version","Admin Username","Private IP","Public IP","FQDN","Disk Size (GB)","Disk Type","Storage Tier","Replication Type","Key Vault SKU","LB SKU","Subnet","VNet","Address Space","NSG Rules","Tags","Resource ID","Created By","Environment","Project","Report Generated At"
HEADER

  # -------------------------------------------------------------------------
  # Fetch all resources in the RG
  # -------------------------------------------------------------------------
  local resources_json
  resources_json=$(az resource list --resource-group "$rg_name" -o json 2>/dev/null)

  local resource_count
  resource_count=$(echo "$resources_json" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

  info "Found ${resource_count} resources to export."
  echo ""

  # -------------------------------------------------------------------------
  # Iterate each resource and collect detailed metadata
  # -------------------------------------------------------------------------
  echo "$resources_json" | python3 -c "
import sys, json, subprocess, csv, io

resources = json.load(sys.stdin)
rg_name = '${rg_name}'
project_name = '${project_name}'
environment = '${environment}'
report_time = '$(date '+%Y-%m-%d %H:%M:%S %Z')'

def run_az(cmd):
    try:
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=30)
        return result.stdout.strip()
    except:
        return ''

def safe_json(s):
    try:
        return json.loads(s) if s else {}
    except:
        return {}

rows = []

for r in resources:
    name = r.get('name', '')
    rtype = r.get('type', '')
    location = r.get('location', '')
    prov_state = r.get('provisioningState', '')
    rid = r.get('id', '')
    tags = r.get('tags', {})
    tags_str = '; '.join(f'{k}={v}' for k, v in (tags or {}).items())

    # Default fields
    sku = os_pub = os_offer = os_sku = os_ver = admin_user = ''
    priv_ip = pub_ip = fqdn = disk_size = disk_type = ''
    stor_tier = repl_type = kv_sku = lb_sku = ''
    subnet = vnet = addr_space = nsg_rules = ''

    # ---------------------------------------------------------------
    # VM details
    # ---------------------------------------------------------------
    if 'Microsoft.Compute/virtualMachines' in rtype:
        vm_json = safe_json(run_az(
            f'az vm show -g {rg_name} -n {name} -o json 2>/dev/null'))
        if vm_json:
            sku = vm_json.get('hardwareProfile', {}).get('vmSize', '')
            sr = vm_json.get('storageProfile', {}).get('imageReference', {})
            os_pub = sr.get('publisher', '')
            os_offer = sr.get('offer', '')
            os_sku = sr.get('sku', '')
            os_ver = sr.get('exactVersion', sr.get('version', ''))
            admin_user = vm_json.get('osProfile', {}).get('adminUsername', '')
            osd = vm_json.get('storageProfile', {}).get('osDisk', {})
            disk_size = str(osd.get('diskSizeGb', ''))
            disk_type = osd.get('managedDisk', {}).get('storageAccountType', '')

    # ---------------------------------------------------------------
    # NIC details (private IP, public IP, subnet)
    # ---------------------------------------------------------------
    elif 'Microsoft.Network/networkInterfaces' in rtype:
        nic_json = safe_json(run_az(
            f'az network nic show -g {rg_name} -n {name} -o json 2>/dev/null'))
        if nic_json:
            ipconfigs = nic_json.get('ipConfigurations', [])
            if ipconfigs:
                ipc = ipconfigs[0]
                priv_ip = ipc.get('privateIpAddress', '')
                subnet_id = ipc.get('subnet', {}).get('id', '')
                if subnet_id:
                    parts = subnet_id.split('/')
                    subnet = parts[-1] if parts else ''
                    vnet = parts[-3] if len(parts) >= 3 else ''
                pip_ref = ipc.get('publicIpAddress', {})
                if pip_ref and pip_ref.get('id'):
                    pip_name = pip_ref['id'].split('/')[-1]
                    pip_json = safe_json(run_az(
                        f'az network public-ip show -g {rg_name} -n {pip_name} -o json 2>/dev/null'))
                    pub_ip = pip_json.get('ipAddress', '')
                    fqdn = pip_json.get('dnsSettings', {}).get('fqdn', '') if pip_json.get('dnsSettings') else ''

    # ---------------------------------------------------------------
    # Public IP standalone
    # ---------------------------------------------------------------
    elif 'Microsoft.Network/publicIPAddresses' in rtype:
        pip_json = safe_json(run_az(
            f'az network public-ip show -g {rg_name} -n {name} -o json 2>/dev/null'))
        if pip_json:
            pub_ip = pip_json.get('ipAddress', '')
            sku = pip_json.get('sku', {}).get('name', '')
            fqdn = pip_json.get('dnsSettings', {}).get('fqdn', '') if pip_json.get('dnsSettings') else ''

    # ---------------------------------------------------------------
    # Virtual Network
    # ---------------------------------------------------------------
    elif 'Microsoft.Network/virtualNetworks' in rtype:
        vnet_json = safe_json(run_az(
            f'az network vnet show -g {rg_name} -n {name} -o json 2>/dev/null'))
        if vnet_json:
            addr_space = ', '.join(vnet_json.get('addressSpace', {}).get('addressPrefixes', []))
            subs = vnet_json.get('subnets', [])
            subnet = '; '.join(f\"{s.get('name', '')}={s.get('addressPrefix', '')}\" for s in subs)

    # ---------------------------------------------------------------
    # NSG
    # ---------------------------------------------------------------
    elif 'Microsoft.Network/networkSecurityGroups' in rtype:
        nsg_json = safe_json(run_az(
            f'az network nsg show -g {rg_name} -n {name} -o json 2>/dev/null'))
        if nsg_json:
            rules = nsg_json.get('securityRules', [])
            nsg_rules = '; '.join(
                f\"{rule.get('name', '')}:{rule.get('direction', '')}:{rule.get('access', '')}:{rule.get('destinationPortRange', '')}\"
                for rule in rules
            )

    # ---------------------------------------------------------------
    # Storage Account
    # ---------------------------------------------------------------
    elif 'Microsoft.Storage/storageAccounts' in rtype:
        sa_json = safe_json(run_az(
            f'az storage account show -g {rg_name} -n {name} -o json 2>/dev/null'))
        if sa_json:
            stor_tier = sa_json.get('sku', {}).get('tier', '')
            repl_type = sa_json.get('sku', {}).get('name', '')
            sku = sa_json.get('kind', '')

    # ---------------------------------------------------------------
    # Key Vault
    # ---------------------------------------------------------------
    elif 'Microsoft.KeyVault/vaults' in rtype:
        kv_json = safe_json(run_az(
            f'az keyvault show -n {name} -o json 2>/dev/null'))
        if kv_json:
            kv_sku = kv_json.get('properties', {}).get('sku', {}).get('name', '')
            fqdn = kv_json.get('properties', {}).get('vaultUri', '')

    # ---------------------------------------------------------------
    # Load Balancer
    # ---------------------------------------------------------------
    elif 'Microsoft.Network/loadBalancers' in rtype:
        lb_json = safe_json(run_az(
            f'az network lb show -g {rg_name} -n {name} -o json 2>/dev/null'))
        if lb_json:
            lb_sku = lb_json.get('sku', {}).get('name', '')
            fips = lb_json.get('frontendIpConfigurations', [])
            if fips:
                pip_ref = fips[0].get('publicIpAddress', {})
                if pip_ref and pip_ref.get('id'):
                    pip_name = pip_ref['id'].split('/')[-1]
                    pip_j = safe_json(run_az(
                        f'az network public-ip show -g {rg_name} -n {pip_name} -o json 2>/dev/null'))
                    pub_ip = pip_j.get('ipAddress', '')

    # ---------------------------------------------------------------
    # Build the CSV row
    # ---------------------------------------------------------------
    rows.append([
        name, rtype, rg_name, location, prov_state,
        sku, os_pub, os_offer, os_sku, os_ver, admin_user,
        priv_ip, pub_ip, fqdn, disk_size, disk_type,
        stor_tier, repl_type, kv_sku, lb_sku,
        subnet, vnet, addr_space, nsg_rules,
        tags_str, rid,
        tags.get('ManagedBy', 'terraform'), environment, project_name,
        report_time
    ])

# Write rows
output = io.StringIO()
writer = csv.writer(output, quoting=csv.QUOTE_ALL)
for row in rows:
    writer.writerow(row)

print(output.getvalue(), end='')
" >> "$csv_file"

  local row_count
  row_count=$(tail -n +2 "$csv_file" | grep -c '.' || echo "0")

  echo ""
  info "CSV report generated: ${BOLD}${csv_file}${NC}"
  info "Total resources documented: ${row_count}"
  echo ""

  # -------------------------------------------------------------------------
  # Print a summary table to the terminal
  # -------------------------------------------------------------------------
  section "Resource Summary"
  echo ""
  printf "  ${BOLD}%-35s %-40s %-12s${NC}\n" "RESOURCE NAME" "TYPE" "STATE"
  echo "  ─────────────────────────────────── ──────────────────────────────────────── ────────────"

  az resource list --resource-group "$rg_name" \
    --query "[].{Name:name, Type:type, State:provisioningState}" \
    -o json 2>/dev/null | python3 -c "
import sys, json
resources = json.load(sys.stdin)
for r in resources:
    name = r.get('Name', '')[:34]
    rtype = r.get('Type', '').replace('Microsoft.', '')[:39]
    state = r.get('State', '')
    icon = '✓' if state == 'Succeeded' else '⚠'
    color = '\033[0;32m' if state == 'Succeeded' else '\033[1;33m'
    print(f'  {color}{icon}\033[0m {name:<35s} {rtype:<40s} {state:<12s}')
"

  echo ""
  echo -e "  ${BOLD}CSV file saved to:${NC}"
  echo -e "  ${CYAN}${csv_file}${NC}"
  echo ""

  # Return the CSV path for the caller
  echo "$csv_file"
}


# =============================================================================
# 3. MAIN ENTRY POINT
# =============================================================================
run_post_apply() {
  local project_name="$1"
  local environment="$2"
  local project_dir="$3"

  local rg_name="${project_name}-${environment}-rg"
  local output_dir="${project_dir}/reports"
  mkdir -p "$output_dir"

  # Step 1: Verify all resources
  verify_resources "$rg_name" "$project_name" "$environment"
  local verify_exit=$?

  # Step 2: Generate CSV (even if verification had warnings)
  local csv_path
  csv_path=$(generate_csv "$rg_name" "$project_name" "$environment" "$output_dir")

  # Step 3: Final status
  section "Deployment Complete"
  echo ""
  if [[ $verify_exit -eq 0 ]]; then
    info "All resources verified and running."
  else
    warn "Some resources may still be initializing. Check the CSV for current states."
  fi
  info "Detailed CSV report: ${BOLD}$(echo "$csv_path" | tail -1)${NC}"
  info "Run 'terraform output' for quick reference."
  echo ""

  return $verify_exit
}

# Allow sourcing or direct execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [[ $# -lt 3 ]]; then
    echo "Usage: $0 <project_name> <environment> <project_dir>"
    exit 1
  fi
  run_post_apply "$1" "$2" "$3"
fi
