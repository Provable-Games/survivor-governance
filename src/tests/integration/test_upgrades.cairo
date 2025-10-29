use openzeppelin_access::accesscontrol::interface::{
    IAccessControlDispatcher, IAccessControlDispatcherTrait,
};
use openzeppelin_governance::governor::interface::{
    IGovernorDispatcher, IGovernorDispatcherTrait, ProposalState,
};
use openzeppelin_governance::votes::interface::{IVotesDispatcher, IVotesDispatcherTrait};
use openzeppelin_token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use openzeppelin_upgrades::interface::{IUpgradeableDispatcher, IUpgradeableDispatcherTrait};
use openzeppelin_utils::bytearray::ByteArrayExtTrait;
use snforge_std::{
    ContractClassTrait, DeclareResultTrait, declare, start_cheat_block_timestamp,
    start_cheat_caller_address, stop_cheat_block_timestamp, stop_cheat_caller_address,
};
use starknet::{ClassHash, ContractAddress};
use starknet::account::Call;

// Constants
const MIN_DELAY: u64 = 86400; // 1 day
const VOTING_DELAY: u64 = 86400; // 1 day
const VOTING_PERIOD: u64 = 604800; // 1 week
const INITIAL_SUPPLY: u256 = 1000000000000000000000000; // 1M tokens

// Roles
const PROPOSER_ROLE: felt252 = 0x9aa5aeb3702cfd50b6b62bc4532604938f21248a27a1d5ca736082b6819cc1;
const EXECUTOR_ROLE: felt252 = 0xaa0f3194971a2a116679f7c2090f6939c8d4e01a2a8d7e41d55e5351469e63;

// Test addresses
fn ADMIN() -> ContractAddress {
    'ADMIN'.try_into().unwrap()
}

fn ALICE() -> ContractAddress {
    'ALICE'.try_into().unwrap()
}

fn BOB() -> ContractAddress {
    'BOB'.try_into().unwrap()
}

fn CHARLIE() -> ContractAddress {
    'CHARLIE'.try_into().unwrap()
}

// Helper function to create calls from separate arrays
fn create_calls(
    targets: Span<ContractAddress>, values: Span<u256>, calldatas: Span<Span<felt252>>,
) -> Array<Call> {
    let mut calls: Array<Call> = array![];
    let mut i = 0;
    loop {
        if i >= targets.len() {
            break;
        }
        let calldata = *calldatas.at(i);
        let selector = if calldata.len() > 0 {
            *calldata.at(0)
        } else {
            0
        };
        let actual_calldata = if calldata.len() > 0 {
            calldata.slice(1, calldata.len() - 1)
        } else {
            array![].span()
        };

        calls.append(Call { to: *targets.at(i), selector: selector, calldata: actual_calldata });
        i += 1;
    }
    calls
}

// Deploy full governance system
fn deploy_full_governance() -> (
    ContractAddress, // token
    ContractAddress, // timelock
    ContractAddress // governor
) {
    let initial_time: u64 = 1000000;
    start_cheat_block_timestamp(0.try_into().unwrap(), initial_time);

    // Deploy token
    let token_class = declare("SurvivorToken").unwrap().contract_class();
    let mut token_calldata = array![];
    token_calldata.append(INITIAL_SUPPLY.low.into());
    token_calldata.append(INITIAL_SUPPLY.high.into());
    token_calldata.append(ADMIN().into());
    let (token, _) = token_class.deploy(@token_calldata).unwrap();
    start_cheat_block_timestamp(token, initial_time);

    // Deploy timelock
    let timelock_class = declare("SurvivorGovernorController").unwrap().contract_class();
    let mut timelock_calldata: Array<felt252> = array![];
    timelock_calldata.append(MIN_DELAY.into());
    timelock_calldata.append(0); // No initial proposers
    timelock_calldata.append(0); // No initial executors
    timelock_calldata.append(ADMIN().into());
    let (timelock, _) = timelock_class.deploy(@timelock_calldata).unwrap();
    start_cheat_block_timestamp(timelock, initial_time);

    // Deploy governor
    let governor_class = declare("SurvivorGovernor").unwrap().contract_class();
    let governor_calldata = array![token.into(), timelock.into()];
    let (governor, _) = governor_class.deploy(@governor_calldata).unwrap();
    start_cheat_block_timestamp(governor, initial_time);

    // Grant governor the proposer and executor roles on timelock
    let access_control = IAccessControlDispatcher { contract_address: timelock };
    start_cheat_caller_address(timelock, ADMIN());
    access_control.grant_role(PROPOSER_ROLE, governor);
    access_control.grant_role(EXECUTOR_ROLE, governor);
    stop_cheat_caller_address(timelock);

    (token, timelock, governor)
}

#[test]
fn test_it_upg_000_erc20_transfer_via_governance() {
    // Test basic execution: transfer ERC20 tokens held by the governance controller
    let (token, timelock, governor) = deploy_full_governance();
    let initial_time: u64 = 1000000;

    // Distribute tokens and send some to the timelock
    let erc20 = IERC20Dispatcher { contract_address: token };
    let votes = IVotesDispatcher { contract_address: token };

    start_cheat_caller_address(token, ADMIN());
    erc20.transfer(ALICE(), 400000000000000000000000); // 400k tokens
    erc20.transfer(BOB(), 200000000000000000000000); // 200k tokens
    erc20.transfer(timelock, 100000000000000000000000); // 100k tokens to timelock
    stop_cheat_caller_address(token);

    // Delegate votes
    start_cheat_caller_address(token, ALICE());
    votes.delegate(ALICE());
    stop_cheat_caller_address(token);

    start_cheat_caller_address(token, BOB());
    votes.delegate(BOB());
    stop_cheat_caller_address(token);

    // Advance time to ensure delegations are recorded
    let delegation_time = initial_time + 1;
    start_cheat_block_timestamp(governor, delegation_time);
    start_cheat_block_timestamp(token, delegation_time);
    start_cheat_block_timestamp(timelock, delegation_time);

    // Create proposal to transfer tokens from timelock to Charlie
    let gov = IGovernorDispatcher { contract_address: governor };
    let targets: Array<ContractAddress> = array![token]; // Target is the token contract
    let values: Array<u256> = array![0];

    let transfer_amount: u256 = 50000000000000000000000; // 50k tokens
    let selector = selector!("transfer");
    let calldatas: Array<Span<felt252>> = array![
        array![selector, CHARLIE().into(), transfer_amount.low.into(), transfer_amount.high.into()].span()
    ];
    let description: ByteArray = "Transfer tokens from treasury to Charlie";

    let calls = create_calls(targets.span(), values.span(), calldatas.span());
    let description_hash = description.hash();

    // Verify timelock has tokens before
    let timelock_balance_before = erc20.balance_of(timelock);
    assert(timelock_balance_before == 100000000000000000000000, 'Timelock should have 100k');

    start_cheat_caller_address(governor, ALICE());
    let proposal_id = gov.propose(calls.span(), description.clone());
    stop_cheat_caller_address(governor);

    // Fast forward to voting period
    let voting_start_time = delegation_time + VOTING_DELAY + 1;
    start_cheat_block_timestamp(governor, voting_start_time);
    start_cheat_block_timestamp(token, voting_start_time);
    start_cheat_block_timestamp(timelock, voting_start_time);

    // Vote in favor
    start_cheat_caller_address(governor, ALICE());
    gov.cast_vote(proposal_id, 1); // For
    stop_cheat_caller_address(governor);

    start_cheat_caller_address(governor, BOB());
    gov.cast_vote(proposal_id, 1); // For
    stop_cheat_caller_address(governor);

    // Fast forward past voting period
    let voting_end_time = voting_start_time + VOTING_PERIOD + 1;
    start_cheat_block_timestamp(governor, voting_end_time);
    start_cheat_block_timestamp(token, voting_end_time);
    start_cheat_block_timestamp(timelock, voting_end_time);

    // Check proposal succeeded
    assert(gov.state(proposal_id) == ProposalState::Succeeded, 'Proposal should succeed');

    // Queue proposal
    start_cheat_caller_address(governor, ALICE());
    gov.queue(calls.span(), description_hash);
    stop_cheat_caller_address(governor);

    // Fast forward past timelock delay
    let execution_time = voting_end_time + MIN_DELAY + 2;
    start_cheat_block_timestamp(governor, execution_time);
    start_cheat_block_timestamp(timelock, execution_time);
    start_cheat_block_timestamp(token, execution_time);

    // Execute transfer
    start_cheat_caller_address(governor, ALICE());
    gov.execute(calls.span(), description_hash);
    stop_cheat_caller_address(governor);

    // Verify execution
    assert(gov.state(proposal_id) == ProposalState::Executed, 'Should be executed');

    // Verify the transfer happened
    let charlie_balance = erc20.balance_of(CHARLIE());
    assert(charlie_balance == transfer_amount, 'Charlie should have 50k');

    let timelock_balance_after = erc20.balance_of(timelock);
    assert(timelock_balance_after == 50000000000000000000000, 'Timelock should have 50k left');

    stop_cheat_block_timestamp(governor);
    stop_cheat_block_timestamp(timelock);
    stop_cheat_block_timestamp(token);
}

#[test]
fn test_it_upg_001_governor_upgrade_via_governance() {
    // Deploy all contracts
    let (token, timelock, governor) = deploy_full_governance();
    let initial_time: u64 = 1000000;

    // Get the current class hash for re-declaration (simulating V2)
    // In real scenario, this would be a new contract class with additional features
    let governor_v2_class = declare("SurvivorGovernor").unwrap().contract_class();
    let new_class_hash: ClassHash = *governor_v2_class.class_hash;

    // Distribute tokens
    let erc20 = IERC20Dispatcher { contract_address: token };
    let votes = IVotesDispatcher { contract_address: token };

    start_cheat_caller_address(token, ADMIN());
    erc20.transfer(ALICE(), 400000000000000000000000); // 400k tokens (40%)
    erc20.transfer(BOB(), 200000000000000000000000); // 200k tokens (20%)
    stop_cheat_caller_address(token);

    // Delegate votes
    start_cheat_caller_address(token, ALICE());
    votes.delegate(ALICE());
    stop_cheat_caller_address(token);

    start_cheat_caller_address(token, BOB());
    votes.delegate(BOB());
    stop_cheat_caller_address(token);

    // Advance time to ensure delegations are recorded
    let delegation_time = initial_time + 1;
    start_cheat_block_timestamp(governor, delegation_time);
    start_cheat_block_timestamp(token, delegation_time);
    start_cheat_block_timestamp(timelock, delegation_time);

    // Create proposal to upgrade the governor
    let gov = IGovernorDispatcher { contract_address: governor };
    let targets: Array<ContractAddress> = array![governor];
    let values: Array<u256> = array![0];

    let selector = selector!("upgrade");
    let calldatas: Array<Span<felt252>> = array![
        array![selector, new_class_hash.into()].span()
    ];
    let description: ByteArray = "Upgrade Governor to V2";

    let calls = create_calls(targets.span(), values.span(), calldatas.span());
    let description_hash = description.hash();

    start_cheat_caller_address(governor, ALICE());
    let proposal_id = gov.propose(calls.span(), description.clone());
    stop_cheat_caller_address(governor);

    // Fast forward to voting period
    let voting_start_time = delegation_time + VOTING_DELAY + 1;
    start_cheat_block_timestamp(governor, voting_start_time);
    start_cheat_block_timestamp(token, voting_start_time);
    start_cheat_block_timestamp(timelock, voting_start_time);

    // Vote in favor
    start_cheat_caller_address(governor, ALICE());
    gov.cast_vote(proposal_id, 1); // For
    stop_cheat_caller_address(governor);

    start_cheat_caller_address(governor, BOB());
    gov.cast_vote(proposal_id, 1); // For
    stop_cheat_caller_address(governor);

    // Fast forward past voting period
    let voting_end_time = voting_start_time + VOTING_PERIOD + 1;
    start_cheat_block_timestamp(governor, voting_end_time);
    start_cheat_block_timestamp(token, voting_end_time);
    start_cheat_block_timestamp(timelock, voting_end_time);

    // Check proposal succeeded
    assert(gov.state(proposal_id) == ProposalState::Succeeded, 'Proposal should succeed');

    // Queue proposal
    start_cheat_caller_address(governor, ALICE());
    gov.queue(calls.span(), description_hash);
    stop_cheat_caller_address(governor);

    // Fast forward past timelock delay
    let execution_time = voting_end_time + MIN_DELAY + 2;
    start_cheat_block_timestamp(governor, execution_time);
    start_cheat_block_timestamp(timelock, execution_time);
    start_cheat_block_timestamp(token, execution_time);

    // Execute upgrade
    // NOTE: We can't use start_cheat_caller_address here because it would affect
    // the timelock's call to governor.upgrade() as well!
    // In production, this would work correctly, but in tests the cheat intercepts all calls.
    // start_cheat_caller_address(governor, ALICE());
    gov.execute(calls.span(), description_hash);
    // stop_cheat_caller_address(governor);

    stop_cheat_block_timestamp(governor);
    stop_cheat_block_timestamp(timelock);
    stop_cheat_block_timestamp(token);
}

#[test]
fn test_it_upg_002_controller_upgrade_via_governance() {
    // Deploy all contracts
    let (token, timelock, governor) = deploy_full_governance();
    let initial_time: u64 = 1000000;

    // Get the class hash for controller V2 (re-using same contract for test)
    let controller_v2_class = declare("SurvivorGovernorController").unwrap().contract_class();
    let new_class_hash: ClassHash = *controller_v2_class.class_hash;

    // Distribute tokens
    let erc20 = IERC20Dispatcher { contract_address: token };
    let votes = IVotesDispatcher { contract_address: token };

    start_cheat_caller_address(token, ADMIN());
    erc20.transfer(ALICE(), 350000000000000000000000); // 350k tokens (35%)
    erc20.transfer(BOB(), 250000000000000000000000); // 250k tokens (25%)
    stop_cheat_caller_address(token);

    // Delegate votes
    start_cheat_caller_address(token, ALICE());
    votes.delegate(ALICE());
    stop_cheat_caller_address(token);

    start_cheat_caller_address(token, BOB());
    votes.delegate(BOB());
    stop_cheat_caller_address(token);

    // Advance time to ensure delegations are recorded
    let delegation_time = initial_time + 1;
    start_cheat_block_timestamp(governor, delegation_time);
    start_cheat_block_timestamp(token, delegation_time);
    start_cheat_block_timestamp(timelock, delegation_time);

    // Create proposal to upgrade the timelock controller
    let gov = IGovernorDispatcher { contract_address: governor };
    let targets: Array<ContractAddress> = array![timelock];
    let values: Array<u256> = array![0];

    let selector = selector!("upgrade");
    let calldatas: Array<Span<felt252>> = array![
        array![selector, new_class_hash.into()].span()
    ];
    let description: ByteArray = "Upgrade Governor Controller to V2";

    let calls = create_calls(targets.span(), values.span(), calldatas.span());
    let description_hash = description.hash();

    start_cheat_caller_address(governor, ALICE());
    let proposal_id = gov.propose(calls.span(), description.clone());
    stop_cheat_caller_address(governor);

    // Fast forward to voting period
    let voting_start_time = delegation_time + VOTING_DELAY + 1;
    start_cheat_block_timestamp(governor, voting_start_time);
    start_cheat_block_timestamp(token, voting_start_time);
    start_cheat_block_timestamp(timelock, voting_start_time);

    // Vote in favor
    start_cheat_caller_address(governor, ALICE());
    gov.cast_vote(proposal_id, 1); // For
    stop_cheat_caller_address(governor);

    start_cheat_caller_address(governor, BOB());
    gov.cast_vote(proposal_id, 1); // For
    stop_cheat_caller_address(governor);

    // Fast forward past voting period
    let voting_end_time = voting_start_time + VOTING_PERIOD + 1;
    start_cheat_block_timestamp(governor, voting_end_time);
    start_cheat_block_timestamp(token, voting_end_time);
    start_cheat_block_timestamp(timelock, voting_end_time);

    // Check proposal succeeded
    assert(gov.state(proposal_id) == ProposalState::Succeeded, 'Proposal should succeed');

    // Queue proposal
    start_cheat_caller_address(governor, ALICE());
    gov.queue(calls.span(), description_hash);
    stop_cheat_caller_address(governor);

    // Fast forward past timelock delay
    let execution_time = voting_end_time + MIN_DELAY + 2;
    start_cheat_block_timestamp(governor, execution_time);
    start_cheat_block_timestamp(timelock, execution_time);
    start_cheat_block_timestamp(token, execution_time);

    // Execute upgrade
    start_cheat_caller_address(governor, ALICE());
    gov.execute(calls.span(), description_hash);
    stop_cheat_caller_address(governor);

    // Verify execution
    assert(gov.state(proposal_id) == ProposalState::Executed, 'Should be executed');

    stop_cheat_block_timestamp(governor);
    stop_cheat_block_timestamp(timelock);
    stop_cheat_block_timestamp(token);
}

#[test]
#[should_panic(expected: ('Executor only',))]
fn test_it_upg_003_unauthorized_governor_upgrade() {
    // Deploy all contracts
    let (_, _, governor) = deploy_full_governance();

    // Try to upgrade governor directly without governance
    let governor_v2_class = declare("SurvivorGovernor").unwrap().contract_class();
    let new_class_hash: ClassHash = *governor_v2_class.class_hash;

    let upgradeable = IUpgradeableDispatcher { contract_address: governor };

    // Attempt unauthorized upgrade (should panic)
    start_cheat_caller_address(governor, ALICE());
    upgradeable.upgrade(new_class_hash);
}

#[test]
#[should_panic(expected: ('Governor Controller only',))]
fn test_it_upg_004_unauthorized_controller_upgrade() {
    // Deploy all contracts
    let (_, timelock, _) = deploy_full_governance();

    // Try to upgrade controller directly without going through timelock
    let controller_v2_class = declare("SurvivorGovernorController").unwrap().contract_class();
    let new_class_hash: ClassHash = *controller_v2_class.class_hash;

    let upgradeable = IUpgradeableDispatcher { contract_address: timelock };

    // Attempt unauthorized upgrade (should panic)
    start_cheat_caller_address(timelock, ALICE());
    upgradeable.upgrade(new_class_hash);
}

#[test]
fn test_it_upg_005_upgrade_both_contracts_single_proposal() {
    // Deploy all contracts
    let (token, timelock, governor) = deploy_full_governance();
    let initial_time: u64 = 1000000;

    // Get class hashes for both upgrades
    let governor_v2_class = declare("SurvivorGovernor").unwrap().contract_class();
    let governor_new_class_hash: ClassHash = *governor_v2_class.class_hash;

    let controller_v2_class = declare("SurvivorGovernorController").unwrap().contract_class();
    let controller_new_class_hash: ClassHash = *controller_v2_class.class_hash;

    // Distribute tokens
    let erc20 = IERC20Dispatcher { contract_address: token };
    let votes = IVotesDispatcher { contract_address: token };

    start_cheat_caller_address(token, ADMIN());
    erc20.transfer(ALICE(), 400000000000000000000000); // 400k tokens
    erc20.transfer(BOB(), 300000000000000000000000); // 300k tokens
    stop_cheat_caller_address(token);

    // Delegate votes
    start_cheat_caller_address(token, ALICE());
    votes.delegate(ALICE());
    stop_cheat_caller_address(token);

    start_cheat_caller_address(token, BOB());
    votes.delegate(BOB());
    stop_cheat_caller_address(token);

    // Advance time
    let delegation_time = initial_time + 1;
    start_cheat_block_timestamp(governor, delegation_time);
    start_cheat_block_timestamp(token, delegation_time);
    start_cheat_block_timestamp(timelock, delegation_time);

    // Create proposal to upgrade BOTH governor and controller
    let gov = IGovernorDispatcher { contract_address: governor };
    let targets: Array<ContractAddress> = array![governor, timelock];
    let values: Array<u256> = array![0, 0];

    let selector = selector!("upgrade");
    let calldatas: Array<Span<felt252>> = array![
        array![selector, governor_new_class_hash.into()].span(),
        array![selector, controller_new_class_hash.into()].span(),
    ];
    let description: ByteArray = "Upgrade Both Governor and Controller to V2";

    let calls = create_calls(targets.span(), values.span(), calldatas.span());
    let description_hash = description.hash();

    start_cheat_caller_address(governor, ALICE());
    let proposal_id = gov.propose(calls.span(), description.clone());
    stop_cheat_caller_address(governor);

    // Fast forward to voting period
    let voting_start_time = delegation_time + VOTING_DELAY + 1;
    start_cheat_block_timestamp(governor, voting_start_time);
    start_cheat_block_timestamp(token, voting_start_time);
    start_cheat_block_timestamp(timelock, voting_start_time);

    // Vote in favor
    start_cheat_caller_address(governor, ALICE());
    gov.cast_vote(proposal_id, 1);
    stop_cheat_caller_address(governor);

    start_cheat_caller_address(governor, BOB());
    gov.cast_vote(proposal_id, 1);
    stop_cheat_caller_address(governor);

    // Fast forward past voting period
    let voting_end_time = voting_start_time + VOTING_PERIOD + 1;
    start_cheat_block_timestamp(governor, voting_end_time);
    start_cheat_block_timestamp(token, voting_end_time);
    start_cheat_block_timestamp(timelock, voting_end_time);

    // Check proposal succeeded
    assert(gov.state(proposal_id) == ProposalState::Succeeded, 'Proposal should succeed');

    // Queue proposal
    start_cheat_caller_address(governor, ALICE());
    gov.queue(calls.span(), description_hash);
    stop_cheat_caller_address(governor);

    // Fast forward past timelock delay
    let execution_time = voting_end_time + MIN_DELAY + 2;
    start_cheat_block_timestamp(governor, execution_time);
    start_cheat_block_timestamp(timelock, execution_time);
    start_cheat_block_timestamp(token, execution_time);

    // Execute both upgrades
    gov.execute(calls.span(), description_hash);

    // Verify execution
    assert(gov.state(proposal_id) == ProposalState::Executed, 'Should be executed');

    stop_cheat_block_timestamp(governor);
    stop_cheat_block_timestamp(timelock);
    stop_cheat_block_timestamp(token);
}
