#!/usr/bin/env bash
# =============================================================================
# validate.sh - Input validation functions (production-grade)
# =============================================================================

# Valid Azure regions
VALID_REGIONS=(
  "eastus" "eastus2" "westus" "westus2" "westus3"
  "centralus" "northcentralus" "southcentralus"
  "northeurope" "westeurope" "uksouth" "ukwest"
  "eastasia" "southeastasia" "japaneast" "japanwest"
  "australiaeast" "australiasoutheast"
  "centralindia" "southindia" "westindia"
  "canadacentral" "canadaeast"
  "brazilsouth"
  "koreacentral" "koreasouth"
  "francecentral" "germanywestcentral"
  "norwayeast" "switzerlandnorth"
  "uaenorth"
)

# Valid VM sizes (common ones — format-validated separately)
VALID_VM_SIZES=(
  "Standard_B1s" "Standard_B1ms" "Standard_B2s" "Standard_B2ms"
  "Standard_B4ms" "Standard_B8ms"
  "Standard_D2s_v3" "Standard_D4s_v3" "Standard_D8s_v3" "Standard_D16s_v3"
  "Standard_D2as_v4" "Standard_D4as_v4" "Standard_D8as_v4"
  "Standard_E2s_v3" "Standard_E4s_v3" "Standard_E8s_v3"
  "Standard_F2s_v2" "Standard_F4s_v2" "Standard_F8s_v2"
)

# Azure reserved/blocked admin usernames
BLOCKED_USERNAMES=(
  "admin" "administrator" "root" "user" "test" "guest"
  "adm" "admin1" "admin2" "support" "oracle" "backup"
  "1" "123" "a" "actuser" "console" "david"
  "ftp" "john" "master" "operator" "owner" "postgres"
  "server" "sql" "support_388945a0" "sys" "user1" "user2"
  "user3" "user4" "user5"
)

# =============================================================================
# BASIC VALIDATORS
# =============================================================================

validate_project_name() {
  local name="$1"
  if [[ ! "$name" =~ ^[a-z0-9-]{3,24}$ ]]; then
    echo "ERROR: Project name must be 3-24 chars, lowercase alphanumeric and hyphens only."
    return 1
  fi
  if [[ "$name" =~ ^- ]] || [[ "$name" =~ -$ ]]; then
    echo "ERROR: Project name must not start or end with a hyphen."
    return 1
  fi
  return 0
}

validate_environment() {
  local env="$1"
  if [[ "$env" != "dev" && "$env" != "staging" && "$env" != "prod" ]]; then
    echo "ERROR: Environment must be 'dev', 'staging', or 'prod'."
    return 1
  fi
  return 0
}

validate_region() {
  local region="$1"
  for valid in "${VALID_REGIONS[@]}"; do
    if [[ "$region" == "$valid" ]]; then
      return 0
    fi
  done
  echo "ERROR: Invalid region '$region'."
  echo "  Valid regions include: eastus, westus2, northeurope, westeurope, centralindia, etc."
  return 1
}

validate_number() {
  local value="$1"
  local min="$2"
  local max="$3"
  local label="$4"
  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    echo "ERROR: $label must be a number."
    return 1
  fi
  if (( value < min || value > max )); then
    echo "ERROR: $label must be between $min and $max."
    return 1
  fi
  return 0
}

# =============================================================================
# VM SIZE VALIDATION
# =============================================================================

validate_vm_size() {
  local size="$1"

  # Strip trailing whitespace/commas/periods (common copy-paste mistakes)
  size=$(echo "$size" | sed 's/[,. ]*$//')

  # Check for trailing junk that wasn't stripped
  if [[ "$size" != "$1" ]]; then
    echo "CLEANED:$size"
    return 2  # special code: input was cleaned, caller should use cleaned value
  fi

  if [[ ! "$size" =~ ^Standard_ ]]; then
    echo "ERROR: VM size must start with 'Standard_' (e.g. Standard_B2s)."
    return 1
  fi

  if [[ ! "$size" =~ ^Standard_[A-Za-z0-9_]+$ ]]; then
    echo "ERROR: '$size' contains invalid characters. Only letters, numbers, underscores."
    return 1
  fi

  for valid in "${VALID_VM_SIZES[@]}"; do
    if [[ "$size" == "$valid" ]]; then
      return 0
    fi
  done
  echo "WARNING: '$size' is not in the common sizes list but may still be valid."
  return 0
}

# =============================================================================
# NETWORK VALIDATION
# =============================================================================

validate_cidr() {
  local cidr="$1"
  if [[ ! "$cidr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$ ]]; then
    echo "ERROR: Invalid CIDR format. Expected format: x.x.x.x/xx"
    return 1
  fi

  local ip="${cidr%/*}"
  local mask="${cidr#*/}"
  IFS='.' read -r o1 o2 o3 o4 <<< "$ip"

  for octet in $o1 $o2 $o3 $o4; do
    if (( octet < 0 || octet > 255 )); then
      echo "ERROR: Invalid IP octet '$octet' in CIDR '$cidr'. Must be 0-255."
      return 1
    fi
  done

  if (( mask < 8 || mask > 30 )); then
    echo "ERROR: Subnet mask /$mask is out of range. Use /8 to /30."
    return 1
  fi

  return 0
}

cidr_to_range() {
  local cidr="$1"
  local ip="${cidr%/*}"
  local mask="${cidr#*/}"
  IFS='.' read -r o1 o2 o3 o4 <<< "$ip"

  local ip_int=$(( (o1 << 24) + (o2 << 16) + (o3 << 8) + o4 ))
  local host_bits=$(( 32 - mask ))
  local network_size=$(( 1 << host_bits ))
  local network_start=$(( ip_int & ~(network_size - 1) ))
  local network_end=$(( network_start + network_size - 1 ))

  echo "$network_start $network_end"
}

validate_subnet_no_overlap() {
  local new_cidr="$1"
  shift
  local existing_cidrs=("$@")

  local new_range
  new_range=$(cidr_to_range "$new_cidr")
  local new_start new_end
  read -r new_start new_end <<< "$new_range"

  for existing in "${existing_cidrs[@]}"; do
    local ex_range
    ex_range=$(cidr_to_range "$existing")
    local ex_start ex_end
    read -r ex_start ex_end <<< "$ex_range"

    if (( new_start <= ex_end && new_end >= ex_start )); then
      echo "ERROR: Subnet '$new_cidr' overlaps with existing subnet '$existing'."
      return 1
    fi
  done

  return 0
}

validate_subnet_within_vnet() {
  local subnet_cidr="$1"
  local vnet_cidr="$2"

  local sub_range vnet_range
  sub_range=$(cidr_to_range "$subnet_cidr")
  vnet_range=$(cidr_to_range "$vnet_cidr")
  local sub_start sub_end vnet_start vnet_end
  read -r sub_start sub_end <<< "$sub_range"
  read -r vnet_start vnet_end <<< "$vnet_range"

  if (( sub_start < vnet_start || sub_end > vnet_end )); then
    echo "ERROR: Subnet '$subnet_cidr' is not within VNet address space '$vnet_cidr'."
    return 1
  fi

  return 0
}

# =============================================================================
# TAG VALIDATION
# =============================================================================

validate_tag_key() {
  local key="$1"

  if [[ -z "$key" ]]; then
    echo "ERROR: Tag name cannot be empty."
    return 1
  fi

  if [[ "$key" =~ [[:space:]] ]]; then
    echo "ERROR: Tag name '$key' contains spaces."
    echo "  Use hyphens or underscores instead (e.g. 'ManagedBy', 'managed-by')."
    return 1
  fi

  if [[ ! "$key" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    echo "ERROR: Tag name '$key' contains invalid characters."
    echo "  Allowed: letters, numbers, hyphens, underscores, dots."
    return 1
  fi

  if [[ ${#key} -gt 128 ]]; then
    echo "ERROR: Tag name is too long (max 128 characters)."
    return 1
  fi

  return 0
}

# =============================================================================
# AUTHENTICATION VALIDATION
# =============================================================================

validate_password() {
  local pass="$1"

  if [[ ${#pass} -lt 12 ]]; then
    echo "ERROR: Password must be at least 12 characters."
    return 1
  fi

  if [[ ${#pass} -gt 123 ]]; then
    echo "ERROR: Password must be at most 123 characters."
    return 1
  fi

  local complexity=0
  [[ "$pass" =~ [A-Z] ]] && complexity=$((complexity + 1))
  [[ "$pass" =~ [a-z] ]] && complexity=$((complexity + 1))
  [[ "$pass" =~ [0-9] ]] && complexity=$((complexity + 1))
  [[ "$pass" =~ [^a-zA-Z0-9] ]] && complexity=$((complexity + 1))

  if (( complexity < 3 )); then
    echo "ERROR: Password must contain at least 3 of: uppercase, lowercase, digit, special character."
    return 1
  fi

  return 0
}

validate_admin_username() {
  local username="$1"

  if [[ -z "$username" ]]; then
    echo "ERROR: Admin username cannot be empty."
    return 1
  fi

  if [[ ${#username} -gt 64 ]]; then
    echo "ERROR: Admin username must be 1-64 characters."
    return 1
  fi

  if [[ "$username" =~ \.$ ]]; then
    echo "ERROR: Admin username must not end with a period."
    return 1
  fi

  local lower_user
  lower_user=$(echo "$username" | tr '[:upper:]' '[:lower:]')
  for blocked in "${BLOCKED_USERNAMES[@]}"; do
    if [[ "$lower_user" == "$blocked" ]]; then
      echo "ERROR: '$username' is a reserved/blocked admin username in Azure."
      echo "  Try something like 'azureadmin', 'deployer', or your team name."
      return 1
    fi
  done

  return 0
}

# =============================================================================
# YES/NO
# =============================================================================

validate_yes_no() {
  local input="$1"
  input=$(echo "$input" | tr '[:upper:]' '[:lower:]')
  if [[ "$input" == "y" || "$input" == "yes" ]]; then
    return 0
  elif [[ "$input" == "n" || "$input" == "no" ]]; then
    return 1
  else
    echo "ERROR: Please enter 'y' or 'n'."
    return 2
  fi
}

# =============================================================================
# HELPER
# =============================================================================

prompt_validated() {
  local prompt_text="$1"
  local validation_func="$2"
  shift 2
  local validation_args=("$@")
  local input

  while true; do
    read -rp "$prompt_text" input
    if $validation_func "$input" "${validation_args[@]}"; then
      echo "$input"
      return 0
    fi
  done
}
