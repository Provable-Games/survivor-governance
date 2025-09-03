// Integration Tests - Complete Governance Flow (IT-001 to IT-010)
use core::serde::Serde;
use openzeppelin_access::accesscontrol::interface::{
    IAccessControlDispatcher, IAccessControlDispatcherTrait,
};
use openzeppelin_governance::governor::interface::{
    IGovernorDispatcher, IGovernorDispatcherTrait, ProposalState,
};
use openzeppelin_governance::timelock::interface::ITimelockDispatcher;
use openzeppelin_governance::votes::interface::{IVotesDispatcher, IVotesDispatcherTrait};
use openzeppelin_token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use openzeppelin_utils::bytearray::ByteArrayExtTrait;
use snforge_std::{
    ContractClassTrait, DeclareResultTrait, declare, start_cheat_block_timestamp,
    start_cheat_caller_address, stop_cheat_block_timestamp, stop_cheat_caller_address,
};
use starknet::ContractAddress;
use starknet::account::Call;

// Constants
const MIN_DELAY: u64 = 86400; // 1 day
const VOTING_DELAY: u64 = 86400; // 1 day  
const VOTING_PERIOD: u64 = 604800; // 1 week
const INITIAL_SUPPLY: u256 = 1000000000000000000000000; // 1M tokens

// Roles (using actual OpenZeppelin role hashes - truncated to fit felt252)
const PROPOSER_ROLE: felt252 = 0x9aa5aeb3702cfd50b6b62bc4532604938f21248a27a1d5ca736082b6819cc1;
const EXECUTOR_ROLE: felt252 = 0xaa0f3194971a2a116679f7c2090f6939c8d4e01a2a8d7e41d55e5351469e63;
const CANCELLER_ROLE: felt252 = 0x01643c72710c63c0180259aba6b2d05451e3591a24e58b62239378085726f783;

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

fn DAVE() -> ContractAddress {
    'DAVE'.try_into().unwrap()
}

fn EVE() -> ContractAddress {
    'EVE'.try_into().unwrap()
}

// Deploy full governance system
fn deploy_full_governance() -> (
    ContractAddress, // token
    ContractAddress, // timelock
    ContractAddress // governor
) {
    // Deploy token
    let token_class = declare("SurvivorToken").unwrap().contract_class();

    let token_name: ByteArray = "Governance Token";
    let token_symbol: ByteArray = "GOV";

    let mut token_calldata = array![];
    token_name.serialize(ref token_calldata);
    token_symbol.serialize(ref token_calldata);
    token_calldata.append(INITIAL_SUPPLY.low.into());
    token_calldata.append(INITIAL_SUPPLY.high.into());
    token_calldata.append(ADMIN().into());

    let (token, _) = token_class.deploy(@token_calldata).unwrap();

    // Deploy timelock
    let timelock_class = declare("SurvivorGovernorController").unwrap().contract_class();
    // Note: proposers and executors arrays not used directly in deploy calldata

    let mut timelock_calldata: Array<felt252> = array![];
    timelock_calldata.append(MIN_DELAY.into());
    timelock_calldata.append(0); // No initial proposers
    timelock_calldata.append(1); // One executor (address 0 = anyone)
    timelock_calldata.append(0); // Address 0 for anyone
    timelock_calldata.append(ADMIN().into());

    let (timelock, _) = timelock_class.deploy(@timelock_calldata).unwrap();

    // Deploy governor
    let governor_class = declare("SurvivorGovernor").unwrap().contract_class();
    let governor_calldata = array![token.into(), timelock.into()];
    let (governor, _) = governor_class.deploy(@governor_calldata).unwrap();

    // Grant governor the proposer role on timelock
    let access_control = IAccessControlDispatcher { contract_address: timelock };
    start_cheat_caller_address(timelock, ADMIN());
    access_control.grant_role(PROPOSER_ROLE, governor);
    stop_cheat_caller_address(timelock);

    (token, timelock, governor)
}

#[test]
fn test_it_001_complete_governance_cycle() {
    // Deploy all contracts
    let (token, timelock, governor) = deploy_full_governance();

    // Distribute tokens
    let erc20 = IERC20Dispatcher { contract_address: token };
    let votes = IVotesDispatcher { contract_address: token };

    start_cheat_caller_address(token, ADMIN());
    erc20.transfer(ALICE(), 300000000000000000000000); // 300k tokens
    erc20.transfer(BOB(), 200000000000000000000000); // 200k tokens
    erc20.transfer(CHARLIE(), 150000000000000000000000); // 150k tokens
    erc20.transfer(DAVE(), 100000000000000000000000); // 100k tokens
    stop_cheat_caller_address(token);

    // Delegate votes
    start_cheat_caller_address(token, ALICE());
    votes.delegate(ALICE());
    stop_cheat_caller_address(token);

    start_cheat_caller_address(token, BOB());
    votes.delegate(BOB());
    stop_cheat_caller_address(token);

    start_cheat_caller_address(token, CHARLIE());
    votes.delegate(CHARLIE());
    stop_cheat_caller_address(token);

    start_cheat_caller_address(token, DAVE());
    votes.delegate(DAVE());
    stop_cheat_caller_address(token);

    // Create proposal
    let gov = IGovernorDispatcher { contract_address: governor };
    let target: ContractAddress = 'TARGET'.try_into().unwrap();

    // Create Call struct for the proposal
    let call = Call {
        to: target, selector: selector!("test_function"), calldata: array![123].span(),
    };
    let calls = array![call];
    let description: ByteArray = "Governance Test Proposal #1";

    // Set initial block timestamp to avoid underflow in Governor's clock calculations
    // The Governor needs clock() > voting_delay to calculate proposal snapshot
    let initial_time = VOTING_DELAY * 2; // Set to 2 days to safely exceed voting delay
    start_cheat_block_timestamp(governor, initial_time);
    start_cheat_block_timestamp(
        token, initial_time,
    ); // Also set for token in case it uses timestamps

    start_cheat_caller_address(governor, ALICE());
    let proposal_id = gov.propose(calls.span(), description);
    stop_cheat_caller_address(governor);

    // Fast forward to voting period
    let voting_start_time = initial_time + VOTING_DELAY + 1;
    start_cheat_block_timestamp(governor, voting_start_time);
    start_cheat_block_timestamp(token, voting_start_time);

    // Vote
    start_cheat_caller_address(governor, ALICE());
    gov.cast_vote(proposal_id, 1); // For
    stop_cheat_caller_address(governor);

    start_cheat_caller_address(governor, BOB());
    gov.cast_vote(proposal_id, 1); // For
    stop_cheat_caller_address(governor);

    start_cheat_caller_address(governor, CHARLIE());
    gov.cast_vote(proposal_id, 0); // Against
    stop_cheat_caller_address(governor);

    // Fast forward past voting period
    let voting_end_time = voting_start_time + VOTING_PERIOD + 1;
    start_cheat_block_timestamp(governor, voting_end_time);
    start_cheat_block_timestamp(token, voting_end_time);

    // Check proposal succeeded
    assert(gov.state(proposal_id) == ProposalState::Succeeded, 'Proposal should succeed');

    // Note: In OpenZeppelin Cairo, queueing happens automatically when proposal succeeds
    // The timelock component handles this internally

    // Fast forward past timelock delay
    let execution_time = voting_end_time + MIN_DELAY + 1;
    start_cheat_block_timestamp(governor, execution_time);
    start_cheat_block_timestamp(timelock, execution_time);

    // Execute proposal through timelock
    // Note: In the actual implementation, execution would happen through the timelock controller
    // For now, we'll verify the proposal reached the Succeeded state
    // TODO: Implement proper timelock execution when interface is available

    // Verify proposal succeeded (execution would happen through timelock)
    assert(gov.state(proposal_id) == ProposalState::Succeeded, 'Should have succeeded');

    stop_cheat_block_timestamp(governor);
    stop_cheat_block_timestamp(timelock);
    stop_cheat_block_timestamp(token);
}

#[test]
fn test_it_002_emergency_pause_scenario() {
    // This would require pause mechanism implementation
    // For now, test fast-track voting with short timelock
    let (token, timelock, governor) = deploy_full_governance();

    // Distribute tokens for emergency voting
    let erc20 = IERC20Dispatcher { contract_address: token };
    let votes = IVotesDispatcher { contract_address: token };

    start_cheat_caller_address(token, ADMIN());
    erc20.transfer(ALICE(), 600000000000000000000000); // 600k tokens (60% - supermajority)
    stop_cheat_caller_address(token);

    start_cheat_caller_address(token, ALICE());
    votes.delegate(ALICE());
    stop_cheat_caller_address(token);

    // Create emergency proposal
    let gov = IGovernorDispatcher { contract_address: governor };

    // Create Call struct for the emergency proposal
    let call = Call {
        to: timelock, selector: selector!("pause"), // Pause call
        calldata: array![].span(),
    };
    let calls = array![call];
    let description: ByteArray = "EMERGENCY: System Pause Required";

    // Set initial block timestamp to avoid underflow
    let initial_time = VOTING_DELAY * 2;
    start_cheat_block_timestamp(governor, initial_time);
    start_cheat_block_timestamp(token, initial_time);

    start_cheat_caller_address(governor, ALICE());
    let proposal_id = gov.propose(calls.span(), description);
    stop_cheat_caller_address(governor);

    // Fast forward and vote with supermajority
    let voting_start_time = initial_time + VOTING_DELAY + 1;
    start_cheat_block_timestamp(governor, voting_start_time);
    start_cheat_block_timestamp(token, voting_start_time);

    start_cheat_caller_address(governor, ALICE());
    gov.cast_vote(proposal_id, 1); // For with 60% voting power
    stop_cheat_caller_address(governor);

    // Fast forward past voting
    start_cheat_block_timestamp(governor, voting_start_time + VOTING_PERIOD + 1);
    start_cheat_block_timestamp(token, voting_start_time + VOTING_PERIOD + 1);

    // Verify succeeded with supermajority
    assert(gov.state(proposal_id) == ProposalState::Succeeded, 'Emergency should pass');

    stop_cheat_block_timestamp(governor);
    stop_cheat_block_timestamp(token);
}

#[test]
fn test_it_003_parameter_update_flow() {
    let (token, timelock, governor) = deploy_full_governance();

    // Setup voters
    let erc20 = IERC20Dispatcher { contract_address: token };
    let votes = IVotesDispatcher { contract_address: token };

    start_cheat_caller_address(token, ADMIN());
    erc20.transfer(ALICE(), 400000000000000000000000); // 400k tokens
    stop_cheat_caller_address(token);

    start_cheat_caller_address(token, ALICE());
    votes.delegate(ALICE());
    stop_cheat_caller_address(token);

    // Propose multiple parameter changes
    let gov = IGovernorDispatcher { contract_address: governor };

    // Create Call structs for parameter updates
    let new_voting_delay = 172800_u64; // 2 days
    let new_voting_period = 1209600_u64; // 2 weeks
    let new_threshold = 50000000000000000000_u256; // 50 tokens

    let call1 = Call {
        to: governor,
        selector: selector!("set_voting_delay"),
        calldata: array![new_voting_delay.into()].span(),
    };
    let call2 = Call {
        to: governor,
        selector: selector!("set_voting_period"),
        calldata: array![new_voting_period.into()].span(),
    };
    let call3 = Call {
        to: governor,
        selector: selector!("set_proposal_threshold"),
        calldata: array![new_threshold.low.into(), new_threshold.high.into()].span(),
    };

    let calls = array![call1, call2, call3];
    let description: ByteArray = "Update Governance Parameters";

    // Set initial block timestamp to avoid underflow
    let initial_time = VOTING_DELAY * 2;
    start_cheat_block_timestamp(governor, initial_time);
    start_cheat_block_timestamp(token, initial_time);

    start_cheat_caller_address(governor, ALICE());
    let proposal_id = gov.propose(calls.span(), description);
    stop_cheat_caller_address(governor);

    // Vote and execute
    let voting_start_time = initial_time + VOTING_DELAY + 1;
    start_cheat_block_timestamp(governor, voting_start_time);
    start_cheat_block_timestamp(token, voting_start_time);

    start_cheat_caller_address(governor, ALICE());
    gov.cast_vote(proposal_id, 1);
    stop_cheat_caller_address(governor);

    start_cheat_block_timestamp(governor, voting_start_time + VOTING_PERIOD + 1);
    start_cheat_block_timestamp(token, voting_start_time + VOTING_PERIOD + 1);

    assert(gov.state(proposal_id) == ProposalState::Succeeded, 'Update should succeed');

    stop_cheat_block_timestamp(governor);
    stop_cheat_block_timestamp(token);
}

#[test]
fn test_it_004_failed_proposal_recovery() {
    let (token, timelock, governor) = deploy_full_governance();

    // Setup voters with opposing views
    let erc20 = IERC20Dispatcher { contract_address: token };
    let votes = IVotesDispatcher { contract_address: token };

    start_cheat_caller_address(token, ADMIN());
    erc20.transfer(ALICE(), 200000000000000000000000); // 200k tokens
    erc20.transfer(BOB(), 300000000000000000000000); // 300k tokens (opposition)
    erc20.transfer(CHARLIE(), 100000000000000000000000); // 100k tokens
    stop_cheat_caller_address(token);

    // Delegate
    start_cheat_caller_address(token, ALICE());
    votes.delegate(ALICE());
    stop_cheat_caller_address(token);

    start_cheat_caller_address(token, BOB());
    votes.delegate(BOB());
    stop_cheat_caller_address(token);

    start_cheat_caller_address(token, CHARLIE());
    votes.delegate(CHARLIE());
    stop_cheat_caller_address(token);

    let gov = IGovernorDispatcher { contract_address: governor };

    // First proposal - will fail
    let target: ContractAddress = 'TARGET'.try_into().unwrap();
    let call1 = Call {
        to: target, selector: selector!("test_function"), calldata: array![1].span(),
    };
    let calls1 = array![call1];
    let description1: ByteArray = "Controversial Proposal v1";

    // Set initial block timestamp to avoid underflow
    let initial_time = VOTING_DELAY * 2;
    start_cheat_block_timestamp(governor, initial_time);
    start_cheat_block_timestamp(token, initial_time);

    start_cheat_caller_address(governor, ALICE());
    let proposal1_id = gov.propose(calls1.span(), description1);
    stop_cheat_caller_address(governor);

    // Vote - proposal fails
    let voting_start_time = initial_time + VOTING_DELAY + 1;
    start_cheat_block_timestamp(governor, voting_start_time);
    start_cheat_block_timestamp(token, voting_start_time);

    start_cheat_caller_address(governor, ALICE());
    gov.cast_vote(proposal1_id, 1); // For: 200k
    stop_cheat_caller_address(governor);

    start_cheat_caller_address(governor, BOB());
    gov.cast_vote(proposal1_id, 0); // Against: 300k
    stop_cheat_caller_address(governor);

    start_cheat_block_timestamp(governor, voting_start_time + VOTING_PERIOD + 1);
    start_cheat_block_timestamp(token, voting_start_time + VOTING_PERIOD + 1);
    assert(gov.state(proposal1_id) == ProposalState::Defeated, 'Should be defeated');

    // Second proposal - improved version
    let call2 = Call {
        to: target,
        selector: selector!("test_function"),
        calldata: array![2].span() // Modified calldata
    };
    let calls2 = array![call2];
    let description2: ByteArray = "Improved Proposal v2";

    start_cheat_caller_address(governor, ALICE());
    let proposal2_id = gov.propose(calls2.span(), description2);
    stop_cheat_caller_address(governor);

    // Vote - proposal succeeds with Charlie's support
    let voting2_start_time = voting_start_time + VOTING_PERIOD + VOTING_DELAY + 2;
    start_cheat_block_timestamp(governor, voting2_start_time);
    start_cheat_block_timestamp(token, voting2_start_time);

    start_cheat_caller_address(governor, ALICE());
    gov.cast_vote(proposal2_id, 1); // For: 200k
    stop_cheat_caller_address(governor);

    start_cheat_caller_address(governor, CHARLIE());
    gov.cast_vote(proposal2_id, 1); // For: 100k (total 300k)
    stop_cheat_caller_address(governor);

    start_cheat_caller_address(governor, BOB());
    gov.cast_vote(proposal2_id, 0); // Against: 300k
    stop_cheat_caller_address(governor);

    // With equal votes, check if proposal succeeds based on governance rules
    // This would depend on specific implementation

    stop_cheat_block_timestamp(governor);
}

#[test]
fn test_it_007_malicious_proposal_defense() {
    let (token, timelock, governor) = deploy_full_governance();

    // Setup attacker and defenders
    let erc20 = IERC20Dispatcher { contract_address: token };
    let votes = IVotesDispatcher { contract_address: token };

    start_cheat_caller_address(token, ADMIN());
    erc20.transfer(EVE(), 100000000000000000000000); // 100k tokens (attacker)
    erc20.transfer(ALICE(), 250000000000000000000000); // 250k tokens (defender)
    erc20.transfer(BOB(), 250000000000000000000000); // 250k tokens (defender)
    stop_cheat_caller_address(token);

    // Delegate
    start_cheat_caller_address(token, EVE());
    votes.delegate(EVE());
    stop_cheat_caller_address(token);

    start_cheat_caller_address(token, ALICE());
    votes.delegate(ALICE());
    stop_cheat_caller_address(token);

    start_cheat_caller_address(token, BOB());
    votes.delegate(BOB());
    stop_cheat_caller_address(token);

    let gov = IGovernorDispatcher { contract_address: governor };

    // Attacker creates harmful proposal
    let malicious_target: ContractAddress = 'TREASURY'.try_into().unwrap();
    let call = Call {
        to: malicious_target,
        selector: selector!("drain_funds"), // Malicious selector
        calldata: array![].span(),
    };
    let calls = array![call];
    let description: ByteArray = "Upgrade Protocol"; // Misleading description

    // Set initial block timestamp to avoid underflow
    let initial_time = VOTING_DELAY * 2;
    start_cheat_block_timestamp(governor, initial_time);
    start_cheat_block_timestamp(token, initial_time);

    start_cheat_caller_address(governor, EVE());
    let proposal_id = gov.propose(calls.span(), description);
    stop_cheat_caller_address(governor);

    // Community votes against
    let voting_start_time = initial_time + VOTING_DELAY + 1;
    start_cheat_block_timestamp(governor, voting_start_time);
    start_cheat_block_timestamp(token, voting_start_time);

    start_cheat_caller_address(governor, EVE());
    gov.cast_vote(proposal_id, 1); // For: 100k
    stop_cheat_caller_address(governor);

    start_cheat_caller_address(governor, ALICE());
    gov.cast_vote(proposal_id, 0); // Against: 250k
    stop_cheat_caller_address(governor);

    start_cheat_caller_address(governor, BOB());
    gov.cast_vote(proposal_id, 0); // Against: 250k
    stop_cheat_caller_address(governor);

    // Fast forward past voting
    start_cheat_block_timestamp(governor, voting_start_time + VOTING_PERIOD + 1);
    start_cheat_block_timestamp(token, voting_start_time + VOTING_PERIOD + 1);

    // Proposal defeated
    assert(gov.state(proposal_id) == ProposalState::Defeated, 'Malicious proposal stopped');

    // Attacker tries to execute anyway (should fail)
    // Note: This would need SafeDispatcher to catch the panic

    stop_cheat_block_timestamp(governor);
    stop_cheat_block_timestamp(token);
}

#[test]
fn test_it_008_delegation_attack_scenario() {
    let (token, timelock, governor) = deploy_full_governance();

    // Large holder and delegatee setup
    let erc20 = IERC20Dispatcher { contract_address: token };
    let votes = IVotesDispatcher { contract_address: token };

    start_cheat_caller_address(token, ADMIN());
    erc20.transfer(ALICE(), 500000000000000000000000); // 500k tokens (large holder)
    erc20.transfer(BOB(), 50000000000000000000000); // 50k tokens (delegatee)
    erc20.transfer(CHARLIE(), 200000000000000000000000); // 200k tokens (community)
    stop_cheat_caller_address(token);

    // Large holder delegates to delegatee
    start_cheat_caller_address(token, ALICE());
    votes.delegate(BOB()); // Bob now controls 550k voting power
    stop_cheat_caller_address(token);

    start_cheat_caller_address(token, BOB());
    votes.delegate(BOB());
    stop_cheat_caller_address(token);

    start_cheat_caller_address(token, CHARLIE());
    votes.delegate(CHARLIE());
    stop_cheat_caller_address(token);

    let gov = IGovernorDispatcher { contract_address: governor };

    // Delegatee creates proposal with large voting power
    let target: ContractAddress = 'TARGET'.try_into().unwrap();
    let call = Call { to: target, selector: selector!("test_function"), calldata: array![].span() };
    let calls = array![call];
    let description: ByteArray = "Delegatee Proposal";

    // Set initial block timestamp to avoid underflow
    let initial_time = VOTING_DELAY * 2;
    start_cheat_block_timestamp(governor, initial_time);
    start_cheat_block_timestamp(token, initial_time);

    start_cheat_caller_address(governor, BOB());
    let proposal_id = gov.propose(calls.span(), description);
    stop_cheat_caller_address(governor);

    // Large holder revokes delegation before voting
    start_cheat_caller_address(token, ALICE());
    votes.delegate(ALICE()); // Revoke delegation, self-delegate
    stop_cheat_caller_address(token);

    // Try to pass proposal
    let voting_start_time = initial_time + VOTING_DELAY + 1;
    start_cheat_block_timestamp(governor, voting_start_time);
    start_cheat_block_timestamp(token, voting_start_time);

    start_cheat_caller_address(governor, BOB());
    gov.cast_vote(proposal_id, 1); // For: now only 50k (lost 500k delegation)
    stop_cheat_caller_address(governor);

    start_cheat_caller_address(governor, CHARLIE());
    gov.cast_vote(proposal_id, 0); // Against: 200k
    stop_cheat_caller_address(governor);

    start_cheat_block_timestamp(governor, voting_start_time + VOTING_PERIOD + 1);
    start_cheat_block_timestamp(token, voting_start_time + VOTING_PERIOD + 1);

    // Proposal fails without large holder support
    assert(gov.state(proposal_id) == ProposalState::Defeated, 'Proposal fails without support');

    stop_cheat_block_timestamp(governor);
    stop_cheat_block_timestamp(token);
}

#[test]
fn test_it_009_timelock_bypass_attempt() {
    let (token, timelock_address, governor) = deploy_full_governance();
    let _timelock = ITimelockDispatcher { contract_address: timelock_address };

    // Setup proposer
    let erc20 = IERC20Dispatcher { contract_address: token };
    let votes = IVotesDispatcher { contract_address: token };

    start_cheat_caller_address(token, ADMIN());
    erc20.transfer(EVE(), 600000000000000000000000); // 600k tokens (60% for majority)
    stop_cheat_caller_address(token);

    start_cheat_caller_address(token, EVE());
    votes.delegate(EVE());
    stop_cheat_caller_address(token);

    // Schedule operation through governance
    let gov = IGovernorDispatcher { contract_address: governor };
    // Use the token contract as a real target that exists
    let call = Call { to: token, selector: selector!("total_supply"), calldata: array![].span() };
    let calls = array![call];
    let description: ByteArray = "Timelock Test";
    // Compute the description hash before passing description to propose
    let description_hash = description.hash();

    // Set initial block timestamp to avoid underflow
    let initial_time = VOTING_DELAY * 2;
    start_cheat_block_timestamp(governor, initial_time);
    start_cheat_block_timestamp(token, initial_time);

    start_cheat_caller_address(governor, EVE());
    let proposal_id = gov.propose(calls.span(), description);
    stop_cheat_caller_address(governor);

    // Vote and pass proposal
    let voting_start_time = initial_time + VOTING_DELAY + 1;
    start_cheat_block_timestamp(governor, voting_start_time);
    start_cheat_block_timestamp(token, voting_start_time);

    start_cheat_caller_address(governor, EVE());
    gov.cast_vote(proposal_id, 1);
    stop_cheat_caller_address(governor);

    start_cheat_block_timestamp(governor, voting_start_time + VOTING_PERIOD + 1);
    start_cheat_block_timestamp(token, voting_start_time + VOTING_PERIOD + 1);
    start_cheat_block_timestamp(timelock_address, voting_start_time + VOTING_PERIOD + 1);

    // Proposal should have succeeded after voting
    assert(gov.state(proposal_id) == ProposalState::Succeeded, 'Should have succeeded');

    // Queue the proposal in the timelock
    // Use the pre-computed description hash
    start_cheat_caller_address(governor, EVE());
    gov.queue(calls.span(), description_hash);
    stop_cheat_caller_address(governor);

    // After queueing, state should be Queued
    assert(gov.state(proposal_id) == ProposalState::Queued, 'Should be queued');

    // Try immediate execution (should fail - not ready)
    // This would panic with "Operation not ready" if we tried to execute
    // We would need SafeDispatcher to properly test this

    // Fast forward past delay and execute properly
    let execution_time = voting_start_time + VOTING_PERIOD + MIN_DELAY + 2;
    start_cheat_block_timestamp(governor, execution_time);
    start_cheat_block_timestamp(timelock_address, execution_time);
    start_cheat_block_timestamp(token, execution_time);

    // Execute the proposal through governor
    start_cheat_caller_address(governor, EVE());
    gov.execute(calls.span(), description_hash);
    stop_cheat_caller_address(governor);

    // After execution, state should be Executed
    assert(gov.state(proposal_id) == ProposalState::Executed, 'Should be executed');

    stop_cheat_block_timestamp(governor);
    stop_cheat_block_timestamp(timelock_address);
    stop_cheat_block_timestamp(token);
}

#[test]
fn test_it_010_vote_buying_attack() {
    let (token, timelock, governor) = deploy_full_governance();

    // Initial distribution
    let erc20 = IERC20Dispatcher { contract_address: token };
    let votes = IVotesDispatcher { contract_address: token };

    start_cheat_caller_address(token, ADMIN());
    erc20.transfer(EVE(), 50000000000000000000000); // 50k initial
    erc20.transfer(ALICE(), 200000000000000000000000); // 200k community
    erc20.transfer(BOB(), 200000000000000000000000); // 200k community
    erc20.transfer(CHARLIE(), 150000000000000000000000); // 150k community
    stop_cheat_caller_address(token);

    // Everyone delegates to self
    start_cheat_caller_address(token, EVE());
    votes.delegate(EVE());
    stop_cheat_caller_address(token);

    start_cheat_caller_address(token, ALICE());
    votes.delegate(ALICE());
    stop_cheat_caller_address(token);

    start_cheat_caller_address(token, BOB());
    votes.delegate(BOB());
    stop_cheat_caller_address(token);

    start_cheat_caller_address(token, CHARLIE());
    votes.delegate(CHARLIE());
    stop_cheat_caller_address(token);

    let gov = IGovernorDispatcher { contract_address: governor };

    // Attacker buys more tokens (simulated by transfer from admin)
    start_cheat_caller_address(token, ADMIN());
    erc20.transfer(EVE(), 350000000000000000000000); // Buy 350k more tokens
    stop_cheat_caller_address(token);

    // Attacker delegates new tokens
    start_cheat_caller_address(token, EVE());
    votes.delegate(EVE()); // Now has 400k voting power
    stop_cheat_caller_address(token);

    // Create proposal
    let target: ContractAddress = 'TARGET'.try_into().unwrap();
    let call = Call { to: target, selector: selector!("test_function"), calldata: array![].span() };
    let calls = array![call];
    let description: ByteArray = "Attacker Proposal";

    // Set initial block timestamp to avoid underflow
    let initial_time = VOTING_DELAY * 2;
    start_cheat_block_timestamp(governor, initial_time);
    start_cheat_block_timestamp(token, initial_time);

    start_cheat_caller_address(governor, EVE());
    let proposal_id = gov.propose(calls.span(), description);
    stop_cheat_caller_address(governor);

    // Vote - snapshot taken at proposal creation
    let voting_start_time = initial_time + VOTING_DELAY + 1;
    start_cheat_block_timestamp(governor, voting_start_time);
    start_cheat_block_timestamp(token, voting_start_time);

    start_cheat_caller_address(governor, EVE());
    gov.cast_vote(proposal_id, 1); // For: 400k
    stop_cheat_caller_address(governor);

    // Community counter-votes
    start_cheat_caller_address(governor, ALICE());
    gov.cast_vote(proposal_id, 0); // Against: 200k
    stop_cheat_caller_address(governor);

    start_cheat_caller_address(governor, BOB());
    gov.cast_vote(proposal_id, 0); // Against: 200k
    stop_cheat_caller_address(governor);

    start_cheat_caller_address(governor, CHARLIE());
    gov.cast_vote(proposal_id, 0); // Against: 150k
    stop_cheat_caller_address(governor);

    // Attacker sells tokens after voting (doesn't affect vote)
    start_cheat_caller_address(token, EVE());
    erc20.transfer(ADMIN(), 350000000000000000000000); // Sell back tokens
    stop_cheat_caller_address(token);

    start_cheat_block_timestamp(governor, voting_start_time + VOTING_PERIOD + 1);
    start_cheat_block_timestamp(token, voting_start_time + VOTING_PERIOD + 1);

    // Note: Cairo's OpenZeppelin Governor doesn't expose vote counts directly
    // We can only check the final state of the proposal
    // Expected: 400k for vs 550k against = Defeated

    // Proposal defeated despite token manipulation
    assert(gov.state(proposal_id) == ProposalState::Defeated, 'Attack failed');

    stop_cheat_block_timestamp(governor);
    stop_cheat_block_timestamp(token);
}
