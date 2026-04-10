#!/usr/bin/env bash
# =============================================================================
#  Azure Infrastructure Provisioner - Interactive CLI (Production Grade)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
TFVARS_FILE="$PROJECT_DIR/terraform.tfvars"

LOG_DIR="$PROJECT_DIR/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/provision-$(date '+%Y%m%d-%H%M%S').log"

# Log to file without breaking interactive terminal — write key events, not tee
log() { echo "[$(date '+%H:%M:%S')] $*" >> "$LOG_FILE"; }
log "=== Azure Infra Provisioner started ==="
log "Project dir: $PROJECT_DIR"

source "$SCRIPT_DIR/validate.sh"
source "$SCRIPT_DIR/post_apply.sh"
source "$SCRIPT_DIR/pre_validate.sh"

# =============================================================================
# STATE FLAGS
# =============================================================================
APPLY_STARTED=false
SKIP_CHECKS=false

# Parse CLI args
for arg in "$@"; do
  case "$arg" in
    --skip-checks) SKIP_CHECKS=true ;;
  esac
done

# Module enable flags (user toggles these)
ENABLE_VMS="false"
ENABLE_NETWORK="true"     # always on (RG + VNet are foundational)
ENABLE_STORAGE="false"
ENABLE_KV="false"
ENABLE_LB="false"

# =============================================================================
# TRAP HANDLER
# =============================================================================
cleanup_on_exit() {
  local exit_code=$?
  stty echo 2>/dev/null || true

  if [[ "$APPLY_STARTED" == "true" && $exit_code -ne 0 ]]; then
    echo ""
    echo -e "${RED}${BOLD}  ╔═══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}${BOLD}  ║  INTERRUPTED during terraform apply!                     ║${NC}"
    echo -e "${RED}${BOLD}  ║  Resources may be partially created. Run:                ║${NC}"
    echo -e "${RED}${BOLD}  ║    ./scripts/destroy.sh                                  ║${NC}"
    echo -e "${RED}${BOLD}  ╚═══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${CYAN}Log:${NC} $LOG_FILE"
  elif [[ $exit_code -ne 0 ]]; then
    echo ""
    echo -e "  ${CYAN}Log:${NC} $LOG_FILE"
  fi
}
trap cleanup_on_exit EXIT
trap 'echo ""; echo -e "  ${YELLOW}⚠${NC}  Interrupted."; exit 130' INT TERM

# =============================================================================
# COLORS & UI PRIMITIVES
# =============================================================================
RED='\033[0;31m'    ; GREEN='\033[0;32m'
YELLOW='\033[1;33m' ; BLUE='\033[0;34m'
CYAN='\033[0;36m'   ; MAGENTA='\033[0;35m'
BOLD='\033[1m'      ; DIM='\033[2m'
NC='\033[0m'

STEP_NUM=0
TOTAL_STEPS=0

info()    { echo -e "  ${GREEN}✓${NC}  $1"; log "OK: $(echo "$1" | sed 's/\x1b\[[0-9;]*m//g')"; }
warn()    { echo -e "  ${YELLOW}⚠${NC}  $1"; log "WARN: $(echo "$1" | sed 's/\x1b\[[0-9;]*m//g')"; }
error()   { echo -e "  ${RED}✗${NC}  $1"; log "ERR: $(echo "$1" | sed 's/\x1b\[[0-9;]*m//g')"; }
prompt()  { echo -en "  ${CYAN}›${NC}  $1"; }
dimtext() { echo -e "  ${DIM}$1${NC}"; }

step_header() {
  STEP_NUM=$((STEP_NUM + 1))
  local title="$1"
  local subtitle="${2:-}"
  log "Step ${STEP_NUM}: $title"
  echo ""
  echo -e "  ${BLUE}┌─────────────────────────────────────────────────────────────┐${NC}"
  echo -e "  ${BLUE}│${NC}  ${BOLD}Step ${STEP_NUM}/${TOTAL_STEPS}${NC} ${DIM}·${NC} ${title}"
  if [[ -n "$subtitle" ]]; then
    echo -e "  ${BLUE}│${NC}  ${DIM}${subtitle}${NC}"
  fi
  echo -e "  ${BLUE}└─────────────────────────────────────────────────────────────┘${NC}"
  echo ""
}

divider() {
  echo -e "  ${DIM}─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─${NC}"
}

banner() {
  clear 2>/dev/null || true
  echo ""
  echo -e "  ${CYAN}${BOLD}╔═══════════════════════════════════════════════════════════╗${NC}"
  echo -e "  ${CYAN}${BOLD}║                                                           ║${NC}"
  echo -e "  ${CYAN}${BOLD}║${NC}     ${BOLD}Azure Infrastructure Provisioner${NC}                     ${CYAN}${BOLD}║${NC}"
  echo -e "  ${CYAN}${BOLD}║${NC}     ${DIM}Production-grade Terraform automation${NC}                ${CYAN}${BOLD}║${NC}"
  echo -e "  ${CYAN}${BOLD}║                                                           ║${NC}"
  echo -e "  ${CYAN}${BOLD}╚═══════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  ${DIM}Log: ${LOG_FILE}${NC}"
  echo ""
}

ask_yes_no() {
  local question="$1"
  local default="${2:-n}"
  local hint="y/N"
  [[ "$default" == "y" ]] && hint="Y/n"

  while true; do
    prompt "$question ${DIM}[$hint]${NC}: "
    read -r answer
    answer="${answer:-$default}"
    answer=$(echo "$answer" | tr '[:upper:]' '[:lower:]')
    case "$answer" in
      y|yes) return 0 ;;
      n|no)  return 1 ;;
      *)     error "Please enter 'y' or 'n'." ;;
    esac
  done
}

ask_choice() {
  local question="$1"
  shift
  local options=("$@")
  local i=1

  echo "" >/dev/tty
  for opt in "${options[@]}"; do
    echo -e "     ${BOLD}$i)${NC}  $opt" >/dev/tty
    ((i++))
  done
  echo "" >/dev/tty

  while true; do
    prompt "$question ${DIM}[1-${#options[@]}]${NC}: " >/dev/tty
    read -r choice </dev/tty
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#options[@]} )); then
      echo "${options[$((choice-1))]}"
      return 0
    fi
    error "Pick a number from 1 to ${#options[@]}." >/dev/tty
  done
}

# =============================================================================
# STEP 1: PRE-FLIGHT
# =============================================================================
preflight() {
  step_header "Pre-flight checks" "Verifying tools and Azure login"

  if command -v terraform &>/dev/null; then
    local tf_ver
    tf_ver=$(terraform version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
    info "Terraform ${BOLD}${tf_ver}${NC}"
  else
    error "Terraform not found — install from https://terraform.io"
    exit 1
  fi

  if command -v az &>/dev/null; then
    info "Azure CLI"
  else
    error "Azure CLI not found — install from https://aka.ms/installazurecli"
    exit 1
  fi

  if az account show &>/dev/null 2>&1; then
    local sub_name
    sub_name=$(az account show --query name -o tsv 2>/dev/null || echo "unknown")
    info "Azure subscription: ${BOLD}$sub_name${NC}"
  else
    warn "Not logged in — running 'az login'..."
    az login
  fi
}

# =============================================================================
# STEP 2: PROJECT SETUP
# =============================================================================
collect_global() {
  step_header "Project setup" "Name, environment, region, and tags"

  # Project name
  while true; do
    prompt "Project name ${DIM}(lowercase, 3-24 chars)${NC}: "
    read -r PROJECT_NAME
    if validate_project_name "$PROJECT_NAME" 2>/dev/null; then
      info "Project: ${BOLD}$PROJECT_NAME${NC}"
      break
    else
      error "Use 3-24 chars: lowercase letters, numbers, hyphens. No leading/trailing hyphen."
    fi
  done

  echo ""

  # Environment
  ENVIRONMENT=$(ask_choice "Environment:" "dev" "staging" "prod")
  info "Environment: ${BOLD}$ENVIRONMENT${NC}"

  echo ""

  # Region
  dimtext "Common: eastus, westus2, northeurope, westeurope, centralindia"
  dimtext "        southeastasia, uksouth, australiaeast, canadacentral"
  echo ""
  while true; do
    prompt "Azure region ${DIM}[eastus]${NC}: "
    read -r REGION
    REGION="${REGION:-eastus}"
    if validate_region "$REGION" 2>/dev/null; then
      info "Region: ${BOLD}$REGION${NC}"
      break
    else
      error "Invalid region."
    fi
  done

  echo ""
  divider
  echo ""

  # Tags
  dimtext "Custom tags are applied to every resource for billing/tracking."
  echo ""

  CUSTOM_TAG_KEYS=()
  CUSTOM_TAG_VALUES=()

  while true; do
    prompt "Add a tag? ${DIM}(name or Enter to skip)${NC}: "
    read -r tag_key
    [[ -z "$tag_key" ]] && break

    if ! validate_tag_key "$tag_key" 2>/dev/null; then
      error "Invalid tag name. No spaces — use hyphens or camelCase."
      continue
    fi

    prompt "  Value for '${BOLD}$tag_key${NC}': "
    read -r tag_value
    CUSTOM_TAG_KEYS+=("$tag_key")
    CUSTOM_TAG_VALUES+=("$tag_value")
    info "Tag: ${BOLD}$tag_key${NC} = $tag_value"
  done

  if [[ ${#CUSTOM_TAG_KEYS[@]} -eq 0 ]]; then
    dimtext "No custom tags (default tags still applied)."
  fi
}

# =============================================================================
# STEP 3: RESOURCE PICKER
# =============================================================================
collect_resource_selection() {
  step_header "Choose resources" "Select which Azure resources to provision"

  echo -e "  ${BOLD}Required${NC} ${DIM}(always created)${NC}"
  echo -e "     ${GREEN}●${NC}  Resource Group"
  echo -e "     ${GREEN}●${NC}  Virtual Network + Subnets"
  echo -e "     ${GREEN}●${NC}  Network Security Group"
  echo ""

  divider
  echo ""
  echo -e "  ${BOLD}Optional${NC} ${DIM}(choose what you need)${NC}"
  echo ""

  ask_yes_no "Create Virtual Machines?" "y" && ENABLE_VMS="true" || ENABLE_VMS="false"
  if [[ "$ENABLE_VMS" == "true" ]]; then
    echo -e "     ${GREEN}●${NC}  Virtual Machines"
  else
    echo -e "     ${DIM}○${NC}  ${DIM}Virtual Machines — skipped${NC}"
  fi

  ask_yes_no "Create a Storage Account?" "n" && ENABLE_STORAGE="true" || ENABLE_STORAGE="false"
  if [[ "$ENABLE_STORAGE" == "true" ]]; then
    echo -e "     ${GREEN}●${NC}  Storage Account"
  else
    echo -e "     ${DIM}○${NC}  ${DIM}Storage Account — skipped${NC}"
  fi

  ask_yes_no "Create a Key Vault?" "n" && ENABLE_KV="true" || ENABLE_KV="false"
  if [[ "$ENABLE_KV" == "true" ]]; then
    echo -e "     ${GREEN}●${NC}  Key Vault"
  else
    echo -e "     ${DIM}○${NC}  ${DIM}Key Vault — skipped${NC}"
  fi

  # LB only makes sense with 2+ VMs — defer to VM section
  ENABLE_LB="false"
  LB_SKU="Standard"

  echo ""
  divider

  # Count remaining steps dynamically
  local remaining=3  # network + review + terraform
  [[ "$ENABLE_VMS" == "true" ]] && ((remaining++))
  [[ "$ENABLE_STORAGE" == "true" ]] && ((remaining++))
  [[ "$ENABLE_KV" == "true" ]] && ((remaining++))
  TOTAL_STEPS=$((STEP_NUM + remaining))

  echo ""
  dimtext "Remaining steps: $remaining"
}

# =============================================================================
# STEP 4: NETWORK
# =============================================================================
collect_network() {
  step_header "Network configuration" "VNet, subnets, and firewall rules"

  # VNet
  while true; do
    prompt "VNet address space ${DIM}[10.0.0.0/16]${NC}: "
    read -r VNET_CIDR
    VNET_CIDR="${VNET_CIDR:-10.0.0.0/16}"
    if validate_cidr "$VNET_CIDR" 2>/dev/null; then
      info "VNet: ${BOLD}$VNET_CIDR${NC}"
      break
    else
      error "Invalid CIDR. Use format like 10.0.0.0/16"
    fi
  done

  echo ""

  # Subnets
  while true; do
    prompt "Number of subnets ${DIM}[1]${NC}: "
    read -r SUBNET_COUNT
    SUBNET_COUNT="${SUBNET_COUNT:-1}"
    if validate_number "$SUBNET_COUNT" 1 10 "Subnet count" 2>/dev/null; then
      break
    else
      error "Enter 1-10."
    fi
  done

  SUBNET_PREFIXES=()
  for ((i=1; i<=SUBNET_COUNT; i++)); do
    local default_prefix="10.0.${i}.0/24"
    while true; do
      prompt "  Subnet $i CIDR ${DIM}[$default_prefix]${NC}: "
      read -r prefix
      prefix="${prefix:-$default_prefix}"

      if ! validate_cidr "$prefix" 2>/dev/null; then
        error "Invalid CIDR format."
        continue
      fi
      if ! validate_subnet_within_vnet "$prefix" "$VNET_CIDR" 2>/dev/null; then
        error "Subnet not within VNet address space."
        continue
      fi
      if [[ ${#SUBNET_PREFIXES[@]} -gt 0 ]]; then
        if ! validate_subnet_no_overlap "$prefix" "${SUBNET_PREFIXES[@]}" 2>/dev/null; then
          error "Overlaps with an existing subnet."
          continue
        fi
      fi

      SUBNET_PREFIXES+=("$prefix")
      info "Subnet $i: ${BOLD}$prefix${NC}"
      break
    done
  done

  echo ""
  divider
  echo ""

  # NSG
  echo -e "  ${BOLD}Firewall rules${NC}"
  echo ""
  ask_yes_no "Allow SSH (port 22)?" "y" && ALLOW_SSH="true" || ALLOW_SSH="false"
  ask_yes_no "Allow HTTP (port 80)?" "n" && ALLOW_HTTP="true" || ALLOW_HTTP="false"
  ask_yes_no "Allow HTTPS (port 443)?" "n" && ALLOW_HTTPS="true" || ALLOW_HTTPS="false"

  echo ""
  echo -e "  ${DIM}Ports:  SSH=${ALLOW_SSH}  HTTP=${ALLOW_HTTP}  HTTPS=${ALLOW_HTTPS}${NC}"
}

# =============================================================================
# STEP 5: VIRTUAL MACHINES (only if enabled)
# =============================================================================
VM_COUNT=0
VM_SIZES=()
VM_OS_PUBLISHERS=()
VM_OS_OFFERS=()
VM_OS_SKUS=()
VM_DISK_TYPES=()
VM_DISK_SIZES=()
VM_AUTH_METHODS=()
VM_SSH_KEYS=()
VM_ADMIN_PASSWORDS=()
VM_ADMIN_USERNAMES=()
VM_PUBLIC_IPS=()
GENERATED_KEY_PATHS=()

collect_vm() {
  [[ "$ENABLE_VMS" != "true" ]] && return

  step_header "Virtual Machines" "Configure Linux VMs"

  while true; do
    prompt "Number of VMs ${DIM}[1]${NC}: "
    read -r VM_COUNT
    VM_COUNT="${VM_COUNT:-1}"
    if validate_number "$VM_COUNT" 1 50 "VM count" 2>/dev/null; then
      info "VM count: ${BOLD}$VM_COUNT${NC}"
      break
    else
      error "Enter 1-50."
    fi
  done

  for ((v=1; v<=VM_COUNT; v++)); do
    echo ""
    echo -e "  ${CYAN}${BOLD}── VM $v of $VM_COUNT ──${NC}"
    echo ""

    # Size
    dimtext "Sizes: Standard_B1s, Standard_B2s, Standard_D2s_v3, Standard_E2s_v3"
    while true; do
      prompt "VM size ${DIM}[Standard_B2s]${NC}: "
      read -r vm_size
      vm_size="${vm_size:-Standard_B2s}"
      # Strip trailing commas, periods, spaces (copy-paste mistakes)
      vm_size=$(echo "$vm_size" | sed 's/[,. ]*$//')

      local val_result
      val_result=$(validate_vm_size "$vm_size" 2>/dev/null) || true
      local val_exit=$?

      if [[ $val_exit -eq 0 ]]; then
        info "Size: ${BOLD}$vm_size${NC}"
        break
      else
        error "Invalid VM size '${vm_size}'. Check for typos — e.g. Standard_B2s, Standard_D2s_v3"
      fi
    done
    VM_SIZES+=("$vm_size")

    # OS
    local os_choice
    os_choice=$(ask_choice "OS image:" \
      "Ubuntu 22.04 LTS" \
      "Ubuntu 20.04 LTS" \
      "Debian 11" \
      "CentOS 7 (OpenLogic)" \
      "Custom")

    local os_pub os_off os_sk
    case "$os_choice" in
      "Ubuntu 22.04 LTS")   os_pub="Canonical"; os_off="0001-com-ubuntu-server-jammy"; os_sk="22_04-lts-gen2" ;;
      "Ubuntu 20.04 LTS")   os_pub="Canonical"; os_off="0001-com-ubuntu-server-focal"; os_sk="20_04-lts-gen2" ;;
      "Debian 11")          os_pub="Debian"; os_off="debian-11"; os_sk="11-gen2" ;;
      "CentOS 7 (OpenLogic)") os_pub="OpenLogic"; os_off="CentOS"; os_sk="7_9-gen2" ;;
      "Custom")
        prompt "  Publisher: "; read -r os_pub
        prompt "  Offer: "; read -r os_off
        prompt "  SKU: "; read -r os_sk ;;
    esac
    info "OS: ${BOLD}$os_pub${NC} / $os_off / $os_sk"
    VM_OS_PUBLISHERS+=("$os_pub"); VM_OS_OFFERS+=("$os_off"); VM_OS_SKUS+=("$os_sk")

    # Disk
    local disk_type
    disk_type=$(ask_choice "Disk type:" "Standard_LRS (HDD)" "StandardSSD_LRS (SSD)" "Premium_LRS (Premium SSD)")
    disk_type=$(echo "$disk_type" | awk '{print $1}')
    VM_DISK_TYPES+=("$disk_type")

    prompt "Disk size in GB ${DIM}[30]${NC}: "
    read -r disk_size
    disk_size="${disk_size:-30}"
    info "Disk: ${BOLD}${disk_size}GB${NC} ($disk_type)"
    VM_DISK_SIZES+=("$disk_size")

    # Auth
    echo ""
    local auth_method
    auth_method=$(ask_choice "Authentication:" "SSH Key (recommended)" "Password")
    VM_AUTH_METHODS+=("$auth_method")

    local ssh_key="" admin_pass=""

    if [[ "$auth_method" == "SSH Key (recommended)" ]]; then
      # Check for existing key first
      local default_key="$HOME/.ssh/id_rsa.pub"
      if [[ -f "$default_key" ]]; then
        info "Found existing key at $default_key"
        if ask_yes_no "Use this key?" "y"; then
          ssh_key=$(cat "$default_key")
        fi
      fi

      # If no key yet, offer choices
      if [[ -z "$ssh_key" ]]; then
        local key_choice
        key_choice=$(ask_choice "SSH key:" \
          "Generate new key pair (recommended)" \
          "Provide path to existing public key")

        if [[ "$key_choice" == "Generate new key pair (recommended)" ]]; then
          # Generate key pair in project's keys/ directory
          local keys_dir="$PROJECT_DIR/keys"
          mkdir -p "$keys_dir"
          local key_name="${PROJECT_NAME}-${ENVIRONMENT}-vm${v}"
          local key_path_priv="${keys_dir}/${key_name}"
          local key_path_pub="${keys_dir}/${key_name}.pub"

          # Generate without passphrase for automation
          ssh-keygen -t rsa -b 4096 -f "$key_path_priv" -N "" -C "${key_name}@azure-provisioner" -q
          ssh_key=$(cat "$key_path_pub")

          info "Key pair generated:"
          dimtext "  Private: ${key_path_priv}"
          dimtext "  Public:  ${key_path_pub}"
          warn "Keep the private key safe — you'll need it to SSH into the VM."

          # Track generated keys for later download/output
          GENERATED_KEY_PATHS+=("$key_path_priv")

        else
          # Provide path — loop until valid
          while true; do
            prompt "Path to SSH public key: "
            read -r key_path
            key_path="${key_path/#\~/$HOME}"

            if [[ -z "$key_path" ]]; then
              error "Path cannot be empty."
              continue
            fi

            if [[ ! -f "$key_path" ]]; then
              error "File not found: $key_path"
              warn "Check the path and try again."
              continue
            fi

            # Basic sanity check — should start with ssh-
            local key_content
            key_content=$(cat "$key_path")
            if [[ ! "$key_content" =~ ^ssh- ]]; then
              warn "This doesn't look like a public key (should start with 'ssh-rsa' or 'ssh-ed25519')."
              if ! ask_yes_no "Use it anyway?" "n"; then
                continue
              fi
            fi

            ssh_key="$key_content"
            info "SSH key loaded from $key_path"
            break
          done
        fi
      fi
    else
      warn "Password auth is not recommended for production."
      while true; do
        prompt "Password ${DIM}(min 12 chars, 3-of-4 complexity)${NC}: "
        read -rs admin_pass; echo ""
        if validate_password "$admin_pass" 2>/dev/null; then
          prompt "Confirm password: "
          read -rs admin_pass_confirm; echo ""
          if [[ "$admin_pass" == "$admin_pass_confirm" ]]; then
            info "Password set"
            break
          else
            error "Passwords don't match."
          fi
        else
          error "Need 12+ chars with 3 of: uppercase, lowercase, digit, special."
        fi
      done
    fi
    VM_SSH_KEYS+=("$ssh_key"); VM_ADMIN_PASSWORDS+=("$admin_pass")

    # Username
    while true; do
      prompt "Admin username ${DIM}[azureadmin]${NC}: "
      read -r admin_user
      admin_user="${admin_user:-azureadmin}"
      if validate_admin_username "$admin_user" 2>/dev/null; then
        info "Admin: ${BOLD}$admin_user${NC}"
        break
      else
        error "Blocked username. Try 'azureadmin', 'deployer', etc."
      fi
    done
    VM_ADMIN_USERNAMES+=("$admin_user")

    # Public IP
    ask_yes_no "Assign public IP?" "y" && VM_PUBLIC_IPS+=("true") || VM_PUBLIC_IPS+=("false")
  done

  # Offer LB for 2+ VMs
  if (( VM_COUNT > 1 )); then
    echo ""
    divider
    echo ""
    info "You have $VM_COUNT VMs — a load balancer can distribute traffic."
    ask_yes_no "Create a Load Balancer?" "n" && ENABLE_LB="true" || ENABLE_LB="false"
    if [[ "$ENABLE_LB" == "true" ]]; then
      LB_SKU=$(ask_choice "LB SKU:" "Standard" "Basic")
      info "Load Balancer: ${BOLD}$LB_SKU${NC}"
    fi
  fi
}

# =============================================================================
# STEP 6: STORAGE ACCOUNT (only if enabled)
# =============================================================================
STORAGE_TIER="Standard"
STORAGE_REPLICATION="LRS"
STORAGE_KIND="StorageV2"

collect_storage() {
  [[ "$ENABLE_STORAGE" != "true" ]] && return

  step_header "Storage Account" "Blob storage configuration"

  STORAGE_TIER=$(ask_choice "Tier:" "Standard" "Premium")
  STORAGE_REPLICATION=$(ask_choice "Replication:" "LRS (Local)" "GRS (Geo)" "ZRS (Zone)" "RAGRS (Read-Access Geo)")
  STORAGE_REPLICATION=$(echo "$STORAGE_REPLICATION" | awk '{print $1}')
  info "Storage: ${BOLD}$STORAGE_TIER / $STORAGE_REPLICATION${NC}"
}

# =============================================================================
# STEP 7: KEY VAULT (only if enabled)
# =============================================================================
KV_SKU="standard"

collect_keyvault() {
  [[ "$ENABLE_KV" != "true" ]] && return

  step_header "Key Vault" "Secrets and key management"

  KV_SKU=$(ask_choice "SKU:" "standard" "premium")
  info "Key Vault: ${BOLD}$KV_SKU${NC}"
}

# =============================================================================
# GENERATE TFVARS
# =============================================================================
generate_tfvars() {
  local subnet_list=""
  for prefix in "${SUBNET_PREFIXES[@]}"; do
    subnet_list+="  \"$prefix\",\n"
  done
  subnet_list=$(echo -e "$subnet_list" | sed '$ s/,$//')

  cat > "$TFVARS_FILE" <<EOF
# =============================================================================
# Auto-generated by Azure Infra Provisioner
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
# =============================================================================

project_name = "$PROJECT_NAME"
environment  = "$ENVIRONMENT"
region       = "$REGION"

tags = {
  GeneratedBy = "azure-infra-provisioner"
  GeneratedAt = "$(date '+%Y-%m-%d')"
EOF

  for ((i=0; i<${#CUSTOM_TAG_KEYS[@]}; i++)); do
    echo "  \"${CUSTOM_TAG_KEYS[$i]}\" = \"${CUSTOM_TAG_VALUES[$i]}\"" >> "$TFVARS_FILE"
  done

  cat >> "$TFVARS_FILE" <<EOF
}

vnet_address_space = ["$VNET_CIDR"]
subnet_count       = $SUBNET_COUNT
subnet_prefixes    = [
$(echo -e "$subnet_list")
]

allow_ssh   = $ALLOW_SSH
allow_http  = $ALLOW_HTTP
allow_https = $ALLOW_HTTPS

vm_count = $VM_COUNT
EOF

  # VM configs
  if [[ "$ENABLE_VMS" == "true" && $VM_COUNT -gt 0 ]]; then
    echo "" >> "$TFVARS_FILE"
    echo "vm_configs = [" >> "$TFVARS_FILE"
    for ((i=0; i<VM_COUNT; i++)); do
      cat >> "$TFVARS_FILE" <<EOF
  {
    vm_size          = "${VM_SIZES[$i]}"
    os_publisher     = "${VM_OS_PUBLISHERS[$i]}"
    os_offer         = "${VM_OS_OFFERS[$i]}"
    os_sku           = "${VM_OS_SKUS[$i]}"
    os_version       = "latest"
    disk_size_gb     = ${VM_DISK_SIZES[$i]}
    disk_type        = "${VM_DISK_TYPES[$i]}"
    admin_username   = "${VM_ADMIN_USERNAMES[$i]}"
    admin_password   = "${VM_ADMIN_PASSWORDS[$i]}"
    ssh_public_key   = "${VM_SSH_KEYS[$i]}"
    assign_public_ip = ${VM_PUBLIC_IPS[$i]}
  },
EOF
    done
    echo "]" >> "$TFVARS_FILE"
  else
    echo "" >> "$TFVARS_FILE"
    echo "vm_configs = []" >> "$TFVARS_FILE"
  fi

  cat >> "$TFVARS_FILE" <<EOF

enable_storage_account   = $ENABLE_STORAGE
storage_account_tier     = "$STORAGE_TIER"
storage_replication_type = "$STORAGE_REPLICATION"
storage_account_kind     = "$STORAGE_KIND"

enable_key_vault         = $ENABLE_KV
keyvault_sku             = "$KV_SKU"
keyvault_purge_on_destroy = true

enable_load_balancer     = $ENABLE_LB
lb_sku                   = "$LB_SKU"
EOF

  mkdir -p "$PROJECT_DIR/environments"
  local env_file="$PROJECT_DIR/environments/${PROJECT_NAME}-${ENVIRONMENT}-$(date +%Y%m%d-%H%M%S).tfvars"
  cp "$TFVARS_FILE" "$env_file"
}

# =============================================================================
# REVIEW
# =============================================================================
review() {
  step_header "Review" "Confirm your infrastructure before provisioning"

  local p="${PROJECT_NAME}-${ENVIRONMENT}"

  # ── PROJECT ──
  echo ""
  echo -e "  ${BOLD}${CYAN}PROJECT${NC}"
  echo -e "  ${DIM}──────────────────────────────────────────────────────${NC}"
  echo -e "    Name           ${BOLD}${PROJECT_NAME}${NC}"
  echo -e "    Environment    ${BOLD}${ENVIRONMENT}${NC}"
  echo -e "    Region         ${BOLD}${REGION}${NC}"
  echo ""
  echo -e "    ${DIM}Tags${NC}"
  echo -e "      GeneratedBy = azure-infra-provisioner"
  echo -e "      GeneratedAt = $(date '+%Y-%m-%d')"
  for ((i=0; i<${#CUSTOM_TAG_KEYS[@]}; i++)); do
    echo -e "      ${CUSTOM_TAG_KEYS[$i]} = ${CUSTOM_TAG_VALUES[$i]}"
  done

  # ── CORE RESOURCES ──
  echo ""
  echo -e "  ${BOLD}${CYAN}CORE RESOURCES${NC} ${DIM}(auto-created)${NC}"
  echo -e "  ${DIM}──────────────────────────────────────────────────────${NC}"
  echo -e "    ${GREEN}●${NC}  Resource Group    ${BOLD}${p}-rg${NC}"
  echo -e "    ${GREEN}●${NC}  VNet               ${BOLD}${p}-vnet${NC} ${DIM}(${VNET_CIDR})${NC}"
  for ((i=0; i<SUBNET_COUNT; i++)); do
    echo -e "    ${GREEN}●${NC}  Subnet $((i+1))           ${BOLD}${p}-subnet-$((i+1))${NC} ${DIM}(${SUBNET_PREFIXES[$i]})${NC}"
  done
  echo -e "    ${GREEN}●${NC}  NSG                ${BOLD}${p}-nsg${NC}"
  echo ""
  echo -en "    ${DIM}Firewall:${NC}  "
  [[ "$ALLOW_SSH" == "true" ]] && echo -en "${GREEN}SSH${NC}  " || echo -en "${DIM}SSH${NC}  "
  [[ "$ALLOW_HTTP" == "true" ]] && echo -en "${GREEN}HTTP${NC}  " || echo -en "${DIM}HTTP${NC}  "
  [[ "$ALLOW_HTTPS" == "true" ]] && echo -en "${GREEN}HTTPS${NC}" || echo -en "${DIM}HTTPS${NC}"
  echo ""

  # ── VMs ──
  if [[ "$ENABLE_VMS" == "true" && $VM_COUNT -gt 0 ]]; then
    echo ""
    echo -e "  ${BOLD}${CYAN}VIRTUAL MACHINES${NC} (${VM_COUNT})"
    echo -e "  ${DIM}──────────────────────────────────────────────────────${NC}"

    for ((i=0; i<VM_COUNT; i++)); do
      local vm_num=$((i+1))
      local auth_type="Password"
      [[ -n "${VM_SSH_KEYS[$i]}" ]] && auth_type="SSH Key"
      local subnet_idx=$(( i % SUBNET_COUNT ))

      echo ""
      echo -e "    ${CYAN}${BOLD}VM ${vm_num}${NC}  ${DIM}${p}-vm-${vm_num}${NC}"
      echo -e "    ├── Size         ${BOLD}${VM_SIZES[$i]}${NC}"
      echo -e "    ├── OS           ${VM_OS_PUBLISHERS[$i]} / ${VM_OS_SKUS[$i]}"
      echo -e "    ├── Disk         ${VM_DISK_SIZES[$i]}GB (${VM_DISK_TYPES[$i]})"
      echo -e "    ├── Auth         ${auth_type}"
      echo -e "    ├── Admin        ${VM_ADMIN_USERNAMES[$i]}"
      echo -e "    ├── NIC          ${p}-nic-${vm_num} → subnet-$((subnet_idx+1))"
      if [[ "${VM_PUBLIC_IPS[$i]}" == "true" ]]; then
        echo -e "    └── Public IP    ${p}-pip-${vm_num}"
      else
        echo -e "    └── Public IP    ${DIM}none${NC}"
      fi
    done
  fi

  # ── OPTIONAL RESOURCES ──
  echo ""
  echo -e "  ${BOLD}${CYAN}OPTIONAL RESOURCES${NC}"
  echo -e "  ${DIM}──────────────────────────────────────────────────────${NC}"

  if [[ "$ENABLE_STORAGE" == "true" ]]; then
    local sa_name
    sa_name=$(echo "${PROJECT_NAME}${ENVIRONMENT}sa" | tr -d '-' | cut -c1-24)
    echo -e "    ${GREEN}●${NC}  Storage          ${BOLD}${sa_name}${NC}"
    echo -e "                         ${DIM}${STORAGE_TIER} / ${STORAGE_REPLICATION} / ${STORAGE_KIND}${NC}"
  else
    echo -e "    ${DIM}○  Storage          not selected${NC}"
  fi

  if [[ "$ENABLE_KV" == "true" ]]; then
    local kv_name
    kv_name=$(echo "${p}-kv" | cut -c1-24)
    echo -e "    ${GREEN}●${NC}  Key Vault        ${BOLD}${kv_name}${NC} ${DIM}(${KV_SKU})${NC}"
  else
    echo -e "    ${DIM}○  Key Vault        not selected${NC}"
  fi

  if [[ "$ENABLE_LB" == "true" ]]; then
    echo -e "    ${GREEN}●${NC}  Load Balancer    ${BOLD}${p}-lb${NC} ${DIM}(${LB_SKU})${NC}"
  else
    echo -e "    ${DIM}○  Load Balancer    not selected${NC}"
  fi

  # ── TOTAL ──
  echo ""
  echo -e "  ${DIM}──────────────────────────────────────────────────────${NC}"
  local total=3
  total=$((total + SUBNET_COUNT))
  if [[ "$ENABLE_VMS" == "true" ]]; then
    total=$((total + VM_COUNT))
    total=$((total + VM_COUNT))
    for pip in "${VM_PUBLIC_IPS[@]+"${VM_PUBLIC_IPS[@]}"}"; do
      [[ "$pip" == "true" ]] && total=$((total + 1))
    done
  fi
  [[ "$ENABLE_STORAGE" == "true" ]] && total=$((total + 1))
  [[ "$ENABLE_KV" == "true" ]] && total=$((total + 1))
  [[ "$ENABLE_LB" == "true" ]] && total=$((total + 3))

  echo -e "  ${BOLD}Total resources: ~${total}${NC}"
  echo ""
}

# =============================================================================
# TERRAFORM EXECUTION
# =============================================================================
run_terraform() {
  step_header "Provisioning" "Terraform init → pre-check → plan → apply"

  cd "$PROJECT_DIR"

  info "Running terraform init..."
  terraform init -input=false 2>&1 | tee -a "$LOG_FILE"
  echo ""

  # Conflict detection
  local name_prefix="${PROJECT_NAME}-${ENVIRONMENT}"
  local rg_name="${name_prefix}-rg"

  if az group show --name "$rg_name" &>/dev/null 2>&1; then
    error "Resource group '${BOLD}$rg_name${NC}' already exists!"
    warn "Existing resources:"
    az resource list --resource-group "$rg_name" --query "[].{Name:name, Type:type}" -o table 2>/dev/null | sed 's/^/    /'
    echo ""
    error "Delete it first:  az group delete --name $rg_name --yes"
    error "Or use a different project name."
    exit 1
  fi
  info "No conflicts found"
  echo ""

  # Pre-validation (skip with --skip-checks flag)
  if [[ "$SKIP_CHECKS" == "true" ]]; then
    warn "Pre-validation skipped (--skip-checks). Failures will occur at apply time."
  else
    local unique_sizes=()
    for ((i=0; i<VM_COUNT; i++)); do
      local already=false
      for existing in "${unique_sizes[@]+"${unique_sizes[@]}"}"; do
        [[ "$existing" == "${VM_SIZES[$i]}" ]] && already=true && break
      done
      [[ "$already" == "false" ]] && unique_sizes+=("${VM_SIZES[$i]}")
    done

    if ! run_pre_validation \
      "$PROJECT_NAME" "$ENVIRONMENT" "$REGION" \
      "$ENABLE_KV" "$ENABLE_STORAGE" \
      "${unique_sizes[@]+"${unique_sizes[@]}"}"; then
      error "Pre-validation failed. Fix issues above and re-run."
      dimtext "Or re-run with: ./scripts/provision.sh --skip-checks"
      exit 1
    fi
  fi

  # Plan
  info "Running terraform plan..."
  echo ""
  terraform plan -var-file="$TFVARS_FILE" -out=tfplan
  echo ""

  # Apply
  if ask_yes_no "Apply this plan? ${BOLD}This creates real Azure resources.${NC}" "n"; then
    echo ""
    info "Running terraform apply..."
    APPLY_STARTED=true

    local apply_exit=0
    terraform apply tfplan || apply_exit=$?

    echo ""

    if [[ $apply_exit -ne 0 ]]; then
      # ─── PARTIAL FAILURE ───
      echo ""
      echo -e "  ${RED}${BOLD}╔═══════════════════════════════════════════════════════════╗${NC}"
      echo -e "  ${RED}${BOLD}║  Terraform apply FAILED (exit code: $apply_exit)${NC}"
      echo -e "  ${RED}${BOLD}╚═══════════════════════════════════════════════════════════╝${NC}"
      echo ""

      if az group show --name "$rg_name" &>/dev/null 2>&1; then
        local resource_count
        resource_count=$(az resource list --resource-group "$rg_name" --query "length([])" -o tsv 2>/dev/null || echo "0")

        if [[ "$resource_count" -gt 0 ]]; then
          warn "$resource_count orphaned resource(s) in '$rg_name':"
          az resource list --resource-group "$rg_name" \
            --query "[].{Name:name, Type:type}" -o table 2>/dev/null | sed 's/^/    /'
          echo ""

          if ask_yes_no "Auto-rollback? Destroy everything in '$rg_name'?" "n"; then
            echo ""
            warn "Rolling back..."
            if terraform destroy -var-file="$TFVARS_FILE" -auto-approve 2>/dev/null; then
              info "Rollback complete."
            else
              warn "Terraform destroy failed. Deleting resource group via CLI..."
              az group delete --name "$rg_name" --yes --no-wait 2>/dev/null || true
              rm -f terraform.tfstate terraform.tfstate.backup 2>/dev/null
              info "Resource group deletion initiated."
            fi
          else
            warn "Orphaned resources remain. Clean up with: ./scripts/destroy.sh"
          fi
        fi
      fi
      rm -f tfplan
      exit 1
    else
      # ─── SUCCESS ───
      terraform output
      echo ""
      run_post_apply "$PROJECT_NAME" "$ENVIRONMENT" "$PROJECT_DIR"

      # Show generated SSH keys if any
      if [[ ${#GENERATED_KEY_PATHS[@]} -gt 0 ]]; then
        echo ""
        echo -e "  ${BOLD}SSH KEYS${NC}"
        echo -e "  ┌──────────────────────────────────────────────────────────┐"
        echo -e "  │  Generated key pairs saved to: keys/                     │"
        for kp in "${GENERATED_KEY_PATHS[@]}"; do
          local kname
          kname=$(basename "$kp")
          printf "  │    %-54s│\n" "$kname (private)"
          printf "  │    %-54s│\n" "${kname}.pub (public)"
        done
        echo -e "  │                                                          │"
        echo -e "  │  ${YELLOW}⚠${NC}  Keep private keys safe. Do NOT commit to git.         │"
        echo -e "  └──────────────────────────────────────────────────────────┘"
        echo ""
        dimtext "SSH connection example:"
        local first_key="${GENERATED_KEY_PATHS[0]}"
        dimtext "  ssh -i ${first_key} <admin>@<public-ip>"
      fi
    fi
  else
    warn "Cancelled. Config saved — run terraform apply manually."
  fi

  rm -f tfplan
}

# =============================================================================
# MAIN
# =============================================================================
main() {
  banner

  # Count steps: preflight + project + picker + network + review + terraform = 6
  # Plus conditional: VMs, storage, keyvault
  TOTAL_STEPS=6

  preflight
  collect_global
  collect_resource_selection
  collect_network
  collect_vm
  collect_storage
  collect_keyvault
  generate_tfvars
  review

  if ask_yes_no "Proceed with Terraform?" "y"; then
    run_terraform
  else
    echo ""
    info "Config saved to: $TFVARS_FILE"
    dimtext "Run manually:"
    dimtext "  cd $PROJECT_DIR"
    dimtext "  terraform init && terraform plan -var-file=terraform.tfvars"
    echo ""
  fi
}

main "$@"
