# Survivor Governance

A decentralized governance system built on Starknet using Cairo smart contracts, implementing a complete DAO (Decentralized Autonomous Organization) framework with timelock controls and token-weighted voting.

## Overview

Survivor Governance provides a secure, transparent, and decentralized governance mechanism that allows token holders to:

- **Propose** governance changes through formal proposals
- **Vote** on proposals using token-weighted voting power
- **Delegate** voting power to trusted representatives
- **Execute** approved proposals through a secure timelock mechanism
- **Manage** protocol parameters through community consensus

## Architecture

The system consists of three core contracts:

### 1. SurvivorToken
An ERC20 governance token with voting capabilities:
- Standard ERC20 functionality (transfer, approve, allowance)
- Built-in voting power system with delegation
- Vote checkpointing to prevent manipulation
- SNIP12 signature support for gasless operations

### 2. SurvivorGovernorController
A timelock controller that enforces delays on proposal execution:
- Minimum 1-hour delay on all governance actions
- Role-based access control (proposers, executors, cancellers)
- Batch operation support for complex proposals
- Predecessor dependency chains for ordered execution

### 3. SurvivorGovernor
The main governance contract managing the proposal lifecycle:
- **Voting Delay**: 1 day before voting starts
- **Voting Period**: 1 week for community participation
- **Proposal Threshold**: 10 tokens minimum to create proposals
- **Quorum**: 20% of total supply must participate for validity

## Installation

### Prerequisites

- [Scarb](https://docs.swmansion.com/scarb/) - Cairo package manager
- [Starknet Foundry](https://foundry-rs.github.io/starknet-foundry/) - Testing framework
- Cairo 2024_07 or later

### Setup

1. Clone the repository:
```bash
git clone https://github.com/your-org/survivor-governance
cd survivor-governance
```

2. Install dependencies:
```bash
scarb build
```

3. Configure environment variables:
```bash
cp .env.example .env
# Edit .env with your configuration
```

## Building

Build the entire workspace:
```bash
scarb build
```

Build specific test packages:
```bash
cd packages/test_starknet && scarb build
cd packages/test_dojo && scarb build
```

## Testing

The project enforces **90% minimum test coverage** using cairo-coverage.

### Run all tests:
```bash
snforge test
```

### Run specific test:
```bash
snforge test <test_name>
```

### Generate coverage report:
```bash
snforge test --coverage
cairo-coverage
```

### Test categories:
- **Unit tests**: `tests/unit/` - Individual function testing
- **Integration tests**: `tests/integration/` - End-to-end governance flows
- **Fuzz tests**: `tests/fuzz/` - Property-based testing
- **Adversarial tests**: `tests/adversarial/` - Security testing

## Deployment

### Quick Deploy

Deploy the complete governance system:
```bash
./scripts/deploy_governance.sh
```

### Manual Deployment

1. Deploy SurvivorToken:
```bash
starkli deploy --watch survivor_token <initial_supply> <recipient>
```

2. Deploy SurvivorGovernorController:
```bash
starkli deploy --watch governor_controller <min_delay> <proposers> <executors> <admin>
```

3. Deploy SurvivorGovernor:
```bash
starkli deploy --watch governor <token_address> <timelock_address>
```

4. Configure roles and permissions as needed

### Current Deployments

**Sepolia Testnet:**
- Token: `0x059b1b29ae7bf93316893aa42e90aa36eca7cf02fe42d7acfafcf5660d0d5618`
- Controller: `0x01f2f61f104c4f393ced3bca7781a2cd5b15c5b4e4cf22b82653d27603172904`
- Governor: `0x001824a978e4e34efa3ee7cee323c80ad7a92299b308ef8c6fa9c279fac9d70f`

## Usage

### Creating a Proposal

```cairo
// Propose a parameter change
let proposal_id = governor.propose(
    array![target_contract],
    array![0], // values
    array![calldata],
    "Proposal: Update protocol parameter X"
);
```

### Voting on Proposals

```cairo
// Cast a vote (0=Against, 1=For, 2=Abstain)
governor.cast_vote(proposal_id, 1); // Vote For
```

### Delegating Voting Power

```cairo
// Delegate your voting power
token.delegate(delegate_address);
```

### Executing Approved Proposals

```cairo
// After timelock delay, execute the proposal
governor.execute(
    array![target_contract],
    array![0],
    array![calldata],
    description_hash
);
```

## Governance Parameters

| Parameter | Value | Description |
|-----------|-------|-------------|
| Voting Delay | 1 day | Time before voting starts after proposal creation |
| Voting Period | 1 week | Duration of the voting phase |
| Proposal Threshold | 10 tokens | Minimum tokens needed to create a proposal |
| Quorum | 20% | Minimum participation required for proposal validity |
| Timelock Delay | 1 hour | Minimum delay before executing approved proposals |

## Security Features

- **Snapshot-based voting**: Vote weights are locked at proposal creation
- **Timelock delays**: Provides reaction time for emergency situations
- **Role segregation**: Different entities can propose vs. execute
- **Delegation system**: Liquid democracy with security guarantees
- **Reentrancy protection**: Built into all OpenZeppelin components
- **90% test coverage**: Comprehensive testing requirement

## Development

### Code Style

The project uses:
- Component-based architecture with `#[starknet::component]`
- Storage isolation via `#[substorage(v0)]`
- SRC5 interface discovery for capability detection
- Extensive use of Option types for optional parameters

### Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Write tests (maintain 90% coverage)
4. Ensure all tests pass (`scarb test`)
5. Format code (`scarb fmt`)
6. Commit your changes
7. Push to the branch
8. Open a Pull Request

### Development Guidelines

See [CLAUDE.md](./CLAUDE.md) for detailed development instructions and best practices.

## Dependencies

- **Cairo**: 2024_07 Edition
- **Starknet**: 2.11.4
- **OpenZeppelin Cairo Contracts**: 2.0.0
  - Token components (ERC20, Votes)
  - Governance components (Governor, Timelock)
  - Access control and utilities

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Support

For issues, questions, or contributions:
- Open an issue on GitHub
- Join our Discord community
- Follow us on Twitter

## Acknowledgments

Built with:
- [OpenZeppelin Cairo Contracts](https://github.com/OpenZeppelin/cairo-contracts)
- [Starknet](https://starknet.io)
- [Scarb](https://docs.swmansion.com/scarb/)
- [Starknet Foundry](https://foundry-rs.github.io/starknet-foundry/)