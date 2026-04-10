#!/usr/bin/env bash
# =============================================================================
#  Destroy script - Tears down all provisioned infrastructure (hardened)
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

echo ""
echo -e "${RED}${BOLD}  ╔═══════════════════════════════════════════════╗${NC}"
echo -e "${RED}${BOLD}  ║   DESTROY - This will DELETE all resources!   ║${NC}"
echo -e "${RED}${BOLD}  ╚═══════════════════════════════════════════════╝${NC}"
echo ""

cd "$PROJECT_DIR"

# Check if terraform.tfvars exists
if [[ ! -f "terraform.tfvars" ]]; then
  echo -e "  ${YELLOW}⚠${NC} No terraform.tfvars found."
  echo ""

  # Check if state file exists
  if [[ -f "terraform.tfstate" ]]; then
    echo -e "  ${CYAN}?${NC} State file exists but tfvars is missing."
    echo "    This can happen after a partial failure or manual cleanup."
    echo ""

    # Try to find the RG name from state
    local_rg=$(terraform state list 2>/dev/null | head -1 || echo "")
    if [[ -n "$local_rg" ]]; then
      echo -e "  ${YELLOW}Resources in state:${NC}"
      terraform state list 2>/dev/null | sed 's/^/    /'
      echo ""
      echo -e "  ${RED}${BOLD}Cannot destroy without terraform.tfvars.${NC}"
      echo ""
      echo "  Options:"
      echo "    1. Find your tfvars backup in environments/ and copy it:"
      echo "       cp environments/<your-backup>.tfvars terraform.tfvars"
      echo "    2. Delete the resource group directly via Azure CLI:"
      echo "       az group delete --name <your-rg-name> --yes"
      echo ""
    fi
  else
    echo "  No state file found either. Nothing to destroy."
  fi
  exit 0
fi

# Extract project name from tfvars
PROJECT_NAME=$(grep 'project_name' terraform.tfvars 2>/dev/null | awk -F'"' '{print $2}')
ENVIRONMENT=$(grep 'environment' terraform.tfvars 2>/dev/null | awk -F'"' '{print $2}')
RG_NAME="${PROJECT_NAME}-${ENVIRONMENT}-rg"

if [[ -z "$PROJECT_NAME" ]]; then
  echo -e "  ${RED}✗${NC} Could not extract project name from terraform.tfvars."
  exit 1
fi

# Show what will be destroyed
echo -e "${YELLOW}Project:${NC} $PROJECT_NAME"
echo -e "${YELLOW}Environment:${NC} $ENVIRONMENT"
echo -e "${YELLOW}Resource Group:${NC} $RG_NAME"
echo ""

# Check if state exists
if terraform state list &>/dev/null 2>&1; then
  echo -e "${YELLOW}Resources that will be destroyed:${NC}"
  echo ""
  terraform state list 2>/dev/null | sed 's/^/    /'
else
  echo "  No terraform state found."
  echo ""

  # Check Azure directly
  if az group show --name "$RG_NAME" &>/dev/null 2>&1; then
    echo -e "  ${YELLOW}⚠${NC} Resource group '${RG_NAME}' exists in Azure but has no local state."
    echo ""
    echo -e "${YELLOW}Resources in Azure:${NC}"
    az resource list --resource-group "$RG_NAME" \
      --query "[].{Name:name, Type:type}" -o table 2>/dev/null | sed 's/^/    /'
    echo ""
    echo -e "  To delete via Azure CLI:"
    echo "    az group delete --name $RG_NAME --yes"
  else
    echo "  Resource group '${RG_NAME}' not found in Azure either. Nothing to destroy."
  fi
  exit 0
fi

echo ""
echo -e "${RED}${BOLD}This action is IRREVERSIBLE.${NC}"
echo ""

read -rp "  Type the project name to confirm destruction: " confirmation

if [[ "$confirmation" != "$PROJECT_NAME" ]]; then
  echo ""
  echo -e "  ${GREEN}Destruction cancelled.${NC} (Expected: $PROJECT_NAME)"
  exit 0
fi

echo ""

# Second confirmation for prod
if [[ "$ENVIRONMENT" == "prod" ]]; then
  echo -e "  ${RED}${BOLD}⚠  WARNING: You are destroying a PRODUCTION environment!${NC}"
  read -rp "  Type 'DESTROY PROD' to confirm: " prod_confirm
  if [[ "$prod_confirm" != "DESTROY PROD" ]]; then
    echo ""
    echo -e "  ${GREEN}Destruction cancelled.${NC}"
    exit 0
  fi
  echo ""
fi

echo -e "${YELLOW}Running terraform destroy...${NC}"
echo ""

if terraform destroy -var-file=terraform.tfvars -auto-approve; then
  echo ""
  echo -e "${GREEN}${BOLD}All resources have been destroyed.${NC}"
else
  echo ""
  echo -e "${YELLOW}⚠${NC} Terraform destroy encountered errors."
  echo ""
  echo "  Falling back to Azure CLI resource group deletion..."
  if az group delete --name "$RG_NAME" --yes --no-wait 2>/dev/null; then
    echo -e "  ${GREEN}✓${NC} Resource group '${RG_NAME}' deletion initiated."
    echo "    Azure will delete all resources asynchronously."
    rm -f terraform.tfstate terraform.tfstate.backup 2>/dev/null
  else
    echo -e "  ${RED}✗${NC} Could not delete resource group. Clean up manually:"
    echo "    az group delete --name $RG_NAME --yes"
  fi
fi

echo ""
echo -e "${CYAN}Tip:${NC} Check environments/ for saved configuration backups."
