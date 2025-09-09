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

- **Voting Delay**: 3600 (1 hour before voting starts)
- **Voting Period**: 432000 (5 days for community participation)
- **Proposal Threshold**: 50000000000000000000000 (50k tokens minimum to create proposals, 18 decimals)
- **Quorum**: 30% of total supply must participate for validity

## Installation

### Prerequisites

- [Scarb](https://docs.swmansion.com/scarb/) - Cairo package manager
- [Starknet Foundry](https://foundry-rs.github.io/starknet-foundry/) - Testing framework
- Starknet 2.11.4

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

## Governance Parameters

| Parameter          | Value                      | Description                                          |
| ------------------ | -------------------------- | ---------------------------------------------------- |
| Voting Delay       | 3600 (1 hour)             | Time before voting starts after proposal creation    |
| Voting Period      | 432000 (5 days)           | Duration of the voting phase                         |
| Proposal Threshold | 50k tokens (18 decimals)  | Minimum tokens needed to create a proposal           |
| Quorum             | 30%                       | Minimum participation required for proposal validity |
| Timelock Delay     | 1 hour                    | Minimum delay before executing approved proposals    |

## Dependencies

- **Cairo**: 2024_07 Edition
- **Starknet**: 2.11.4
- **OpenZeppelin Cairo Contracts**: 2.0.0
  - Token components (ERC20, Votes)
  - Governance components (Governor, Timelock)
  - Access control and utilities

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

Built with:

- [OpenZeppelin Cairo Contracts](https://github.com/OpenZeppelin/cairo-contracts)
- [Starknet](https://starknet.io)
- [Scarb](https://docs.swmansion.com/scarb/)
- [Starknet Foundry](https://foundry-rs.github.io/starknet-foundry/)
