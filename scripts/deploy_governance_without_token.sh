#!/bin/bash

# Survivor Governance Contracts Deployment Script
# Deploys SurvivorToken, SurvivorGovernorController, and Governance contracts

set -euo pipefail

# ============================
# STARKLI VERSION CHECK
# ============================

STARKLI_VERSION=$(starkli --version | cut -d' ' -f1)
echo "Detected starkli version: $STARKLI_VERSION"

# Find .env relative to script location
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/../.env" ]; then
    set -a
    source "$SCRIPT_DIR/../.env"
    set +a
    echo "Loaded environment variables from $SCRIPT_DIR/../.env"
fi

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Check deployment environment
DEPLOY_TO_SLOT="${DEPLOY_TO_SLOT:-false}"

# Check if required environment variables are set
print_info "Checking environment variables..."

# Determine required vars based on deployment type
if [ "$DEPLOY_TO_SLOT" = "true" ]; then
    print_info "Deploying to Slot - reduced requirements"
    required_vars=("STARKNET_ACCOUNT" "STARKNET_RPC")
else
    required_vars=("STARKNET_NETWORK" "STARKNET_ACCOUNT" "STARKNET_RPC" "STARKNET_PK")
fi

missing_vars=()

# Debug output for environment variables
print_info "Environment variables loaded:"
echo "  DEPLOY_TO_SLOT: $DEPLOY_TO_SLOT"
echo "  STARKNET_NETWORK: ${STARKNET_NETWORK:-<not set>}"
echo "  STARKNET_ACCOUNT: ${STARKNET_ACCOUNT:-<not set>}"
echo "  STARKNET_RPC: ${STARKNET_RPC:-<not set>}"
echo "  STARKNET_PK: ${STARKNET_PK:+<set>}"

for var in "${required_vars[@]}"; do
    if [ -z "${!var:-}" ]; then
        missing_vars+=("$var")
    fi
done

if [ ${#missing_vars[@]} -ne 0 ]; then
    print_error "The following required environment variables are not set:"
    for var in "${missing_vars[@]}"; do
        echo "  - $var"
    done
    echo "Please set these variables before running the script."
    exit 1
fi

# Check that private key is set (only for non-Slot deployments)
if [ "$DEPLOY_TO_SLOT" != "true" ]; then
    if [ -z "${STARKNET_PK:-}" ]; then
        print_error "STARKNET_PK environment variable is not set"
        exit 1
    fi
    print_warning "Using private key (insecure for production)"
fi

# ============================
# EXTRACT ACCOUNT ADDRESS
# ============================

# Extract the actual account address from the JSON file if STARKNET_ACCOUNT is a file path
if [ -f "$STARKNET_ACCOUNT" ]; then
    ACCOUNT_ADDRESS=$(cat "$STARKNET_ACCOUNT" | grep -o '"address"[[:space:]]*:[[:space:]]*"[^"]*"' | cut -d'"' -f4)
    if [ -z "$ACCOUNT_ADDRESS" ]; then
        print_error "Failed to extract address from account file: $STARKNET_ACCOUNT"
        exit 1
    fi
    print_info "Extracted account address: $ACCOUNT_ADDRESS"
else
    # If STARKNET_ACCOUNT is not a file, assume it's already an address
    ACCOUNT_ADDRESS="$STARKNET_ACCOUNT"
fi

# ============================
# CONFIGURATION PARAMETERS
# ============================

# SurvivorToken Address - must be provided
if [ -z "${VOTING_TOKEN_ADDRESS:-}" ]; then
    print_error "VOTING_TOKEN_ADDRESS must be set in the .env file"
    print_error "Please add: VOTING_TOKEN_ADDRESS=0x... (your SurvivorToken address)"
    exit 1
fi

# SurvivorGovernorController (Timelock) Parameters
MIN_DELAY="${MIN_DELAY:-3600}" # 1 hour in seconds
ADMIN="${ADMIN:-$ACCOUNT_ADDRESS}" # Default to deployer account address

# Governance Parameters
# These will be set after deploying SurvivorGovernorController

# ============================
# DISPLAY CONFIGURATION
# ============================

print_info "Deployment Configuration:"
echo "  Deployment Type: $(if [ "$DEPLOY_TO_SLOT" = "true" ]; then echo "Slot"; else echo "Standard"; fi)"
echo "  Network: ${STARKNET_NETWORK:-<not required for Slot>}"
echo "  Account: $STARKNET_ACCOUNT"
echo ""
echo "  SurvivorToken Address (Existing):"
echo "    Address: $VOTING_TOKEN_ADDRESS"
echo ""
echo "  SurvivorGovernorController Parameters:"
echo "    Min Delay: $MIN_DELAY seconds"
echo "    Admin: $ADMIN"
echo ""

# Confirm deployment
if [ "${SKIP_CONFIRMATION:-false}" != "true" ]; then
    read -p "Continue with deployment? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Deployment cancelled"
        exit 0
    fi
fi

# ============================
# BUILD CONTRACTS
# ============================

print_info "Building contracts..."
cd "$SCRIPT_DIR/.."
scarb build

if [ ! -f "target/release/survivor_governance_SurvivorGovernorController.contract_class.json" ]; then
    print_error "SurvivorGovernorController contract build failed or contract file not found"
    print_error "Expected: target/release/survivor_governance_SurvivorGovernorController.contract_class.json"
    echo "Available contract files:"
    ls -la target/release/*.contract_class.json 2>/dev/null || echo "No contract files found"
    exit 1
fi

if [ ! -f "target/release/survivor_governance_SurvivorGovernor.contract_class.json" ]; then
    print_error "SurvivorGovernor contract build failed or contract file not found"
    print_error "Expected: target/release/survivor_governance_SurvivorGovernor.contract_class.json"
    echo "Available contract files:"
    ls -la target/release/*.contract_class.json 2>/dev/null || echo "No contract files found"
    exit 1
fi

print_info "Using existing SurvivorToken at address: $VOTING_TOKEN_ADDRESS"

# ============================
# DECLARE AND DEPLOY GOVERNANCE CONTROLLER
# ============================

print_info "Declaring SurvivorGovernorController contract..."

# Build declare command based on deployment type
if [ "$DEPLOY_TO_SLOT" = "true" ]; then
    CONTROLLER_DECLARE_OUTPUT=$(starkli declare --account $STARKNET_ACCOUNT --rpc $STARKNET_RPC --watch target/release/survivor_governance_SurvivorGovernorController.contract_class.json 2>&1)
else
    CONTROLLER_DECLARE_OUTPUT=$(starkli declare --account $STARKNET_ACCOUNT --rpc $STARKNET_RPC --watch target/release/survivor_governance_SurvivorGovernorController.contract_class.json --private-key $STARKNET_PK 2>&1)
fi

# Extract class hash from output
CONTROLLER_CLASS_HASH=$(echo "$CONTROLLER_DECLARE_OUTPUT" | grep -oE '0x[0-9a-fA-F]+' | tail -1)

if [ -z "$CONTROLLER_CLASS_HASH" ]; then
    # Contract might already be declared, try to extract from error message
    if echo "$CONTROLLER_DECLARE_OUTPUT" | grep -q "already declared"; then
        CONTROLLER_CLASS_HASH=$(echo "$CONTROLLER_DECLARE_OUTPUT" | grep -oE 'class_hash: 0x[0-9a-fA-F]+' | grep -oE '0x[0-9a-fA-F]+')
        print_warning "SurvivorGovernorController contract already declared with class hash: $CONTROLLER_CLASS_HASH"
    else
        print_error "Failed to declare SurvivorGovernorController contract"
        echo "$CONTROLLER_DECLARE_OUTPUT"
        exit 1
    fi
else
    print_info "SurvivorGovernorController contract declared with class hash: $CONTROLLER_CLASS_HASH"
fi

# Deploy SurvivorGovernorController contract
print_info "Deploying SurvivorGovernorController contract..."

# SurvivorGovernorController constructor parameters:
# - min_delay: u64
# - proposers: Span<ContractAddress> (will be set to empty initially, SurvivorGovernor contract will be added later)
# - executors: Span<ContractAddress> (will be set to empty initially, allowing anyone to execute)
# - admin: ContractAddress

print_info "Controller min delay: $MIN_DELAY"
print_info "Controller admin: $ADMIN"

# For Span parameters, we need to pass: length followed by elements
# Empty Span is represented as: 0
PROPOSERS_SPAN="0"  # Empty array initially
EXECUTORS_SPAN="0"  # Empty array initially (allows anyone to execute)

if [ "$DEPLOY_TO_SLOT" = "true" ]; then
    CONTROLLER_ADDRESS=$(starkli deploy \
        --account $STARKNET_ACCOUNT \
        --rpc $STARKNET_RPC \
        --watch \
        $CONTROLLER_CLASS_HASH \
        $MIN_DELAY \
        $PROPOSERS_SPAN \
        $EXECUTORS_SPAN \
        $ADMIN \
        2>&1 | tee >(cat >&2) | grep -oE '0x[0-9a-fA-F]{64}' | tail -1)
else
    CONTROLLER_ADDRESS=$(starkli deploy \
        --account $STARKNET_ACCOUNT \
        --rpc $STARKNET_RPC \
        --private-key $STARKNET_PK \
        --watch \
        $CONTROLLER_CLASS_HASH \
        $MIN_DELAY \
        $PROPOSERS_SPAN \
        $EXECUTORS_SPAN \
        $ADMIN \
        2>&1 | tee >(cat >&2) | grep -oE '0x[0-9a-fA-F]{64}' | tail -1)
fi

if [ -z "$CONTROLLER_ADDRESS" ]; then
    print_error "Failed to deploy SurvivorGovernorController contract"
    exit 1
fi

print_info "SurvivorGovernorController contract deployed at address: $CONTROLLER_ADDRESS"

# ============================
# DECLARE AND DEPLOY GOVERNANCE
# ============================

print_info "Declaring SurvivorGovernor contract..."

# Build declare command based on deployment type
if [ "$DEPLOY_TO_SLOT" = "true" ]; then
    GOV_DECLARE_OUTPUT=$(starkli declare --account $STARKNET_ACCOUNT --rpc $STARKNET_RPC --watch target/release/survivor_governance_SurvivorGovernor.contract_class.json 2>&1)
else
    GOV_DECLARE_OUTPUT=$(starkli declare --account $STARKNET_ACCOUNT --rpc $STARKNET_RPC --watch target/release/survivor_governance_SurvivorGovernor.contract_class.json --private-key $STARKNET_PK 2>&1)
fi

# Extract class hash from output
GOV_CLASS_HASH=$(echo "$GOV_DECLARE_OUTPUT" | grep -oE '0x[0-9a-fA-F]+' | tail -1)

if [ -z "$GOV_CLASS_HASH" ]; then
    # Contract might already be declared, try to extract from error message
    if echo "$GOV_DECLARE_OUTPUT" | grep -q "already declared"; then
        GOV_CLASS_HASH=$(echo "$GOV_DECLARE_OUTPUT" | grep -oE 'class_hash: 0x[0-9a-fA-F]+' | grep -oE '0x[0-9a-fA-F]+')
        print_warning "SurvivorGovernor contract already declared with class hash: $GOV_CLASS_HASH"
    else
        print_error "Failed to declare SurvivorGovernor contract"
        echo "$GOV_DECLARE_OUTPUT"
        exit 1
    fi
else
    print_info "SurvivorGovernor contract declared with class hash: $GOV_CLASS_HASH"
fi

# Deploy SurvivorGovernor contract
print_info "Deploying SurvivorGovernor contract..."

# SurvivorGovernor constructor parameters:
# - votes_token: ContractAddress
# - timelock_controller: ContractAddress

print_info "SurvivorGovernor votes token: $VOTING_TOKEN_ADDRESS"
print_info "SurvivorGovernor timelock controller: $CONTROLLER_ADDRESS"

if [ "$DEPLOY_TO_SLOT" = "true" ]; then
    GOVERNANCE_ADDRESS=$(starkli deploy \
        --account $STARKNET_ACCOUNT \
        --rpc $STARKNET_RPC \
        --watch \
        $GOV_CLASS_HASH \
        $VOTING_TOKEN_ADDRESS \
        $CONTROLLER_ADDRESS \
        2>&1 | tee >(cat >&2) | grep -oE '0x[0-9a-fA-F]{64}' | tail -1)
else
    GOVERNANCE_ADDRESS=$(starkli deploy \
        --account $STARKNET_ACCOUNT \
        --rpc $STARKNET_RPC \
        --private-key $STARKNET_PK \
        --watch \
        $GOV_CLASS_HASH \
        $VOTING_TOKEN_ADDRESS \
        $CONTROLLER_ADDRESS \
        2>&1 | tee >(cat >&2) | grep -oE '0x[0-9a-fA-F]{64}' | tail -1)
fi

if [ -z "$GOVERNANCE_ADDRESS" ]; then
    print_error "Failed to deploy SurvivorGovernor contract"
    exit 1
fi

print_info "SurvivorGovernor contract deployed at address: $GOVERNANCE_ADDRESS"

# ============================
# CONFIGURE GOVERNANCE CONTROLLER
# ============================

print_info "Configuring SurvivorGovernorController to grant proposer role to SurvivorGovernor contract..."

# Grant PROPOSER_ROLE to the SurvivorGovernor contract
# The SurvivorGovernor contract needs to be able to propose executions to the timelock

if [ "$DEPLOY_TO_SLOT" = "true" ]; then
    starkli invoke \
        --account $STARKNET_ACCOUNT \
        --rpc $STARKNET_RPC \
        --watch \
        $CONTROLLER_ADDRESS \
        grant_role \
        0x9aa5aeb3702cfd50b6b62bc4532604938f21248a27a1d5ca736082b6819cc1 \
        $GOVERNANCE_ADDRESS \
        2>&1
else
    starkli invoke \
        --account $STARKNET_ACCOUNT \
        --rpc $STARKNET_RPC \
        --private-key $STARKNET_PK \
        --watch \
        $CONTROLLER_ADDRESS \
        grant_role \
        0x9aa5aeb3702cfd50b6b62bc4532604938f21248a27a1d5ca736082b6819cc1 \
        $GOVERNANCE_ADDRESS \
        2>&1
fi

print_info "Configuring SurvivorGovernorController to grant canceller role to SurvivorGovernor contract..."

# Grant CANCELLER_ROLE to the SurvivorGovernor contract
# The SurvivorGovernor contract needs to be able to cancel scheduled operations to the timelock

if [ "$DEPLOY_TO_SLOT" = "true" ]; then
    starkli invoke \
        --account $STARKNET_ACCOUNT \
        --rpc $STARKNET_RPC \
        --watch \
        $CONTROLLER_ADDRESS \
        grant_role \
        0x01643c72710c63c0180259aba6b2d05451e3591a24e58b62239378085726f783 \
        $GOVERNANCE_ADDRESS \
        2>&1
else
    starkli invoke \
        --account $STARKNET_ACCOUNT \
        --rpc $STARKNET_RPC \
        --private-key $STARKNET_PK \
        --watch \
        $CONTROLLER_ADDRESS \
        grant_role \
        0x01643c72710c63c0180259aba6b2d05451e3591a24e58b62239378085726f783 \
        $GOVERNANCE_ADDRESS \
        2>&1
fi

if [ $? -eq 0 ]; then
    print_info "Canceller role granted to SurvivorGovernor contract successfully"
else
    print_warning "Failed to grant canceller role to SurvivorGovernor contract - may need manual configuration"
fi

print_info "Configuring SurvivorGovernorController to grant executor role to SurvivorGovernor contract..."

# Grant EXECUTOR_ROLE to the SurvivorGovernor contract
# The SurvivorGovernor contract needs to be able to execute proposals to the timelock

if [ "$DEPLOY_TO_SLOT" = "true" ]; then
    starkli invoke \
        --account $STARKNET_ACCOUNT \
        --rpc $STARKNET_RPC \
        --watch \
        $CONTROLLER_ADDRESS \
        grant_role \
        0xaa0f3194971a2a116679f7c2090f6939c8d4e01a2a8d7e41d55e5351469e63 \
        $GOVERNANCE_ADDRESS \
        2>&1
else
    starkli invoke \
        --account $STARKNET_ACCOUNT \
        --rpc $STARKNET_RPC \
        --private-key $STARKNET_PK \
        --watch \
        $CONTROLLER_ADDRESS \
        grant_role \
        0xaa0f3194971a2a116679f7c2090f6939c8d4e01a2a8d7e41d55e5351469e63 \
        $GOVERNANCE_ADDRESS \
        2>&1
fi

if [ $? -eq 0 ]; then
    print_info "Executor role granted to SurvivorGovernor contract successfully"
else
    print_warning "Failed to grant executor role to SurvivorGovernor contract - may need manual configuration"
fi

print_info "Configuring SurvivorGovernorController to ronounce admin role to Account contract..."

# Renounce ADMIN role from the Account contract
# The Account contract needs to renounced from Admin to ensure the system is decentralized

if [ "$DEPLOY_TO_SLOT" = "true" ]; then
    starkli invoke \
        --account $STARKNET_ACCOUNT \
        --rpc $STARKNET_RPC \
        --watch \
        $CONTROLLER_ADDRESS \
        renounce_role \
        0 \
        $ACCOUNT_ADDRESS \
        2>&1
else
    starkli invoke \
        --account $STARKNET_ACCOUNT \
        --rpc $STARKNET_RPC \
        --private-key $STARKNET_PK \
        --watch \
        $CONTROLLER_ADDRESS \
        renounce_role \
        0 \
        $ACCOUNT_ADDRESS \
        2>&1
fi

if [ $? -eq 0 ]; then
    print_info "Admin role renounced from Account contract successfully"
else
    print_warning "Failed to renounce Admin role from Account contract - may need manual configuration"
fi

# ============================
# SAVE DEPLOYMENT INFO
# ============================

DEPLOYMENT_FILE="deployments/governance_$(date +%Y%m%d_%H%M%S).json"
mkdir -p deployments

cat > "$DEPLOYMENT_FILE" << EOF
{
  "network": "${STARKNET_NETWORK:-slot}",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "voting_token": {
    "address": "$VOTING_TOKEN_ADDRESS",
    "note": "Using existing SurvivorToken deployment"
  },
  "governance_controller": {
    "address": "$CONTROLLER_ADDRESS",
    "class_hash": "$CONTROLLER_CLASS_HASH",
    "parameters": {
      "min_delay": "$MIN_DELAY",
      "proposers": [],
      "executors": [],
      "admin": "$ADMIN"
    }
  },
  "survivor_governor": {
    "address": "$GOVERNANCE_ADDRESS",
    "class_hash": "$GOV_CLASS_HASH",
    "parameters": {
      "votes_token": "$VOTING_TOKEN_ADDRESS",
      "timelock_controller": "$CONTROLLER_ADDRESS"
    }
  }
}
EOF

print_info "Deployment info saved to: $DEPLOYMENT_FILE"

# ============================
# DEPLOYMENT SUMMARY
# ============================

echo
print_info "=== DEPLOYMENT SUCCESSFUL ==="
echo
echo "SurvivorToken Contract (Existing):"
echo "  Address: $VOTING_TOKEN_ADDRESS"
echo
echo "SurvivorGovernorController Contract:"
echo "  Address: $CONTROLLER_ADDRESS"
echo "  Class Hash: $CONTROLLER_CLASS_HASH"
echo "  Min Delay: $MIN_DELAY seconds"
echo "  Admin: $ADMIN"
echo
echo "SurvivorGovernor Contract:"
echo "  Address: $GOVERNANCE_ADDRESS"
echo "  Class Hash: $GOV_CLASS_HASH"
echo "  Votes Token: $VOTING_TOKEN_ADDRESS"
echo "  Timelock Controller: $CONTROLLER_ADDRESS"
echo

echo "Next steps:"
echo "1. Delegate voting power to enable participation in governance"
echo "2. Create your first proposal"
echo "3. Vote on proposals"
echo "4. Execute passed proposals after the timelock delay"
echo

echo "To interact with the contracts:"
echo "  export VOTING_TOKEN=$VOTING_TOKEN_ADDRESS"
echo "  export GOVERNANCE_CONTROLLER=$CONTROLLER_ADDRESS"
echo "  export GOVERNANCE=$GOVERNANCE_ADDRESS"
echo

echo "Example: Delegate voting power to yourself:"
if [ "$DEPLOY_TO_SLOT" = "true" ]; then
    echo "  starkli invoke --account \$STARKNET_ACCOUNT --watch \$VOTING_TOKEN delegate \\"
    echo "    \$STARKNET_ACCOUNT"
else
    echo "  starkli invoke --account \$STARKNET_ACCOUNT --watch \$VOTING_TOKEN delegate \\"
    echo "    \$STARKNET_ACCOUNT --private-key \$STARKNET_PK"
fi