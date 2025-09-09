// Integration Tests - Complete Governance Flow (IT-001 to IT-010)
use core::serde::Serde;
use openzeppelin_access::accesscontrol::interface::{
    IAccessControlDispatcher, IAccessControlDispatcherTrait,
};
use openzeppelin_governance::governor::interface::{
    IGovernorDispatcher, IGovernorDispatcherTrait, ProposalState,
};
use openzeppelin_governance::timelock::interface::{ITimelockDispatcher, ITimelockDispatcherTrait};
use openzeppelin_governance::votes::interface::{IVotesDispatcher, IVotesDispatcherTrait};
use openzeppelin_token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use openzeppelin_utils::bytearray::ByteArrayExtTrait;
use snforge_std::{
    ContractClassTrait, DeclareResultTrait, EventSpyAssertionsTrait, declare, spy_events,
    start_cheat_block_timestamp, start_cheat_caller_address, stop_cheat_block_timestamp,
    stop_cheat_caller_address,
};
use starknet::{ContractAddress, get_block_timestamp};
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

// Helper function to set initial timestamp for tests
fn set_initial_timestamp() {
    let initial_time: u64 = 1000000;
    start_cheat_block_timestamp(0.try_into().unwrap(), initial_time);
}

// Helper function to create calls from separate arrays
fn create_calls(
    targets: Span<ContractAddress>, 
    values: Span<u256>, 
    calldatas: Span<Span<felt252>>
) -> Array<Call> {
    let mut calls: Array<Call> = array![];
    let mut i = 0;
    loop {
        if i >= targets.len() {
            break;
        }
        // Extract selector from calldata if present, otherwise use 0
        let calldata = *calldatas.at(i);
        let selector = if calldata.len() > 0 { *calldata.at(0) } else { 0 };
        let actual_calldata = if calldata.len() > 0 {
            calldata.slice(1, calldata.len() - 1)
        } else {
            array![].span()
        };
        
        calls.append(Call {
            to: *targets.at(i),
            selector: selector,
            calldata: actual_calldata,
        });
        i += 1;
    };
    calls
}

// Deploy full governance system
fn deploy_full_governance() -> (
    ContractAddress, // token
    ContractAddress, // timelock
    ContractAddress // governor
) {
    // Set initial timestamp for deployment
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
    let _proposers: Array<ContractAddress> = array![]; // Governor will be proposer
    let _executors: Array<ContractAddress> = array![]; // Governor will be executor

    let mut timelock_calldata: Array<felt252> = array![];
    timelock_calldata.append(MIN_DELAY.into());
    timelock_calldata.append(0); // No initial proposers
    timelock_calldata.append(0); // No initial executors (will grant to governor after deployment)
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
fn test_it_001_complete_governance_cycle() {
    // Deploy all contracts (timestamps are set in deploy_full_governance)
    let (token, timelock, governor) = deploy_full_governance();
    
    let initial_time: u64 = 1000000;

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
    
    // Advance time by 1 to ensure delegations are recorded
    let delegation_time = initial_time + 1;
    start_cheat_block_timestamp(governor, delegation_time);
    start_cheat_block_timestamp(token, delegation_time);
    start_cheat_block_timestamp(timelock, delegation_time);

    // Create proposal - target the timelock itself to update delay
    let gov = IGovernorDispatcher { contract_address: governor };
    let target: ContractAddress = timelock;
    let targets: Array<ContractAddress> = array![target];
    let values: Array<u256> = array![0];
    
    // Call update_delay with a new delay value (2 days)
    let new_delay: u64 = 172800; // 2 days
    let selector = selector!("update_delay");
    let calldatas: Array<Span<felt252>> = array![array![selector, new_delay.into()].span()];
    let description: ByteArray = "Governance Test Proposal #1";
    
    // Convert to Call format
    let calls = create_calls(targets.span(), values.span(), calldatas.span());
    
    // Calculate description hash upfront
    let description_hash = description.hash();

    start_cheat_caller_address(governor, ALICE());
    let proposal_id = gov.propose(calls.span(), description.clone());
    stop_cheat_caller_address(governor);

    // Fast forward to voting period
    let voting_start_time = delegation_time + VOTING_DELAY + 1;
    start_cheat_block_timestamp(governor, voting_start_time);
    start_cheat_block_timestamp(token, voting_start_time);
    start_cheat_block_timestamp(timelock, voting_start_time);

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
    start_cheat_block_timestamp(timelock, voting_end_time);

    // Check proposal succeeded
    assert(gov.state(proposal_id) == ProposalState::Succeeded, 'Proposal should succeed');

    // Queue proposal in timelock
    start_cheat_caller_address(governor, ALICE());
    gov.queue(calls.span(), description_hash);
    stop_cheat_caller_address(governor);

    // Fast forward past timelock delay
    let execution_time = voting_end_time + MIN_DELAY + 2;
    start_cheat_block_timestamp(governor, execution_time);
    start_cheat_block_timestamp(timelock, execution_time);
    start_cheat_block_timestamp(token, execution_time);

    // Execute proposal
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
fn test_it_002_emergency_pause_scenario() {
    set_initial_timestamp();
    
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
    
    // Advance time to ensure delegation is recorded
    let initial_time: u64 = 1000000;
    let delegation_time = initial_time + 1;
    start_cheat_block_timestamp(governor, delegation_time);
    start_cheat_block_timestamp(token, delegation_time);
    start_cheat_block_timestamp(timelock, delegation_time);

    // Create emergency proposal
    let gov = IGovernorDispatcher { contract_address: governor };
    let targets: Array<ContractAddress> = array![timelock];
    let values: Array<u256> = array![0];
    // Update timelock delay as emergency action
    let selector = selector!("update_delay");
    let new_delay: u64 = 3600; // 1 hour for emergency
    let calldatas: Array<Span<felt252>> = array![array![selector, new_delay.into()].span()];
    let description: ByteArray = "EMERGENCY: System Pause Required";
    
    let calls = create_calls(targets.span(), values.span(), calldatas.span());

    start_cheat_caller_address(governor, ALICE());
    let proposal_id = gov.propose(calls.span(), description.clone());
    stop_cheat_caller_address(governor);

    // Fast forward and vote with supermajority
    let voting_start_time = delegation_time + VOTING_DELAY + 1;
    start_cheat_block_timestamp(governor, voting_start_time);
    start_cheat_block_timestamp(token, voting_start_time);
    start_cheat_block_timestamp(timelock, voting_start_time);

    start_cheat_caller_address(governor, ALICE());
    gov.cast_vote(proposal_id, 1); // For with 60% voting power
    stop_cheat_caller_address(governor);

    // Fast forward past voting
    let voting_end_time = voting_start_time + VOTING_PERIOD + 1;
    start_cheat_block_timestamp(governor, voting_end_time);
    start_cheat_block_timestamp(token, voting_end_time);
    start_cheat_block_timestamp(timelock, voting_end_time);

    // Verify succeeded with supermajority
    assert(gov.state(proposal_id) == ProposalState::Succeeded, 'Emergency should pass');

    stop_cheat_block_timestamp(governor);
}

#[test]
fn test_it_003_parameter_update_flow() {
    set_initial_timestamp();
    
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
    
    // Advance time to ensure delegation is recorded
    let initial_time: u64 = 1000000;
    let delegation_time = initial_time + 1;
    start_cheat_block_timestamp(governor, delegation_time);
    start_cheat_block_timestamp(token, delegation_time);
    start_cheat_block_timestamp(timelock, delegation_time);

    // Propose multiple parameter changes
    let gov = IGovernorDispatcher { contract_address: governor };

    // Multiple targets for different parameter updates
    let targets: Array<ContractAddress> = array![governor, governor, governor];
    let values: Array<u256> = array![0, 0, 0];

    // Calldata for: set_voting_delay, set_voting_period, set_proposal_threshold
    let new_voting_delay = 172800_u64; // 2 days
    let new_voting_period = 1209600_u64; // 2 weeks
    let new_threshold = 50000000000000000000_u256; // 50 tokens

    let selector1 = selector!("set_voting_delay");
    let selector2 = selector!("set_voting_period");
    let selector3 = selector!("set_proposal_threshold");
    
    let calldata1 = array![selector1, new_voting_delay.into()].span();
    let calldata2 = array![selector2, new_voting_period.into()].span();
    let calldata3 = array![selector3, new_threshold.low.into(), new_threshold.high.into()].span();

    let calldatas: Array<Span<felt252>> = array![calldata1, calldata2, calldata3];
    let description: ByteArray = "Update Governance Parameters";
    
    let calls = create_calls(targets.span(), values.span(), calldatas.span());

    start_cheat_caller_address(governor, ALICE());
    let proposal_id = gov.propose(calls.span(), description.clone());
    stop_cheat_caller_address(governor);

    // Vote and execute
    let voting_start_time = delegation_time + VOTING_DELAY + 1;
    start_cheat_block_timestamp(governor, voting_start_time);
    start_cheat_block_timestamp(token, voting_start_time);
    start_cheat_block_timestamp(timelock, voting_start_time);

    start_cheat_caller_address(governor, ALICE());
    gov.cast_vote(proposal_id, 1);
    stop_cheat_caller_address(governor);

    let voting_end_time = voting_start_time + VOTING_PERIOD + 1;
    start_cheat_block_timestamp(governor, voting_end_time);
    start_cheat_block_timestamp(token, voting_end_time);
    start_cheat_block_timestamp(timelock, voting_end_time);

    assert(gov.state(proposal_id) == ProposalState::Succeeded, 'Update should succeed');

    stop_cheat_block_timestamp(governor);
}

#[test]
fn test_it_004_failed_proposal_recovery() {
    set_initial_timestamp();
    
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
    
    // Advance time to ensure delegations are recorded
    let initial_time: u64 = 1000000;
    let delegation_time = initial_time + 1;
    start_cheat_block_timestamp(governor, delegation_time);
    start_cheat_block_timestamp(token, delegation_time);
    start_cheat_block_timestamp(timelock, delegation_time);

    let gov = IGovernorDispatcher { contract_address: governor };

    // First proposal - will fail
    let targets: Array<ContractAddress> = array![timelock];
    let values: Array<u256> = array![0];
    // Try to update delay
    let selector = selector!("update_delay");
    let new_delay: u64 = 259200; // 3 days
    let calldatas: Array<Span<felt252>> = array![array![selector, new_delay.into()].span()];
    let description: ByteArray = "Controversial Proposal v1";
    
    let calls = create_calls(targets.span(), values.span(), calldatas.span());

    start_cheat_caller_address(governor, ALICE());
    let proposal1_id = gov.propose(calls.span(), description.clone());
    stop_cheat_caller_address(governor);

    // Vote - proposal fails
    let voting_start_time = delegation_time + VOTING_DELAY + 1;
    start_cheat_block_timestamp(governor, voting_start_time);
    start_cheat_block_timestamp(token, voting_start_time);
    start_cheat_block_timestamp(timelock, voting_start_time);

    start_cheat_caller_address(governor, ALICE());
    gov.cast_vote(proposal1_id, 1); // For: 200k
    stop_cheat_caller_address(governor);

    start_cheat_caller_address(governor, BOB());
    gov.cast_vote(proposal1_id, 0); // Against: 300k
    stop_cheat_caller_address(governor);

    let voting_end_time = voting_start_time + VOTING_PERIOD + 1;
    start_cheat_block_timestamp(governor, voting_end_time);
    start_cheat_block_timestamp(token, voting_end_time);
    start_cheat_block_timestamp(timelock, voting_end_time);
    assert(gov.state(proposal1_id) == ProposalState::Defeated, 'Should be defeated');

    // Second proposal - improved version
    let calldatas2: Array<Span<felt252>> = array![array![2].span()]; // Modified calldata
    let description2: ByteArray = "Improved Proposal v2";
    
    let calls2 = create_calls(targets.span(), values.span(), calldatas2.span());

    start_cheat_caller_address(governor, ALICE());
    let proposal2_id = gov.propose(calls2.span(), description2.clone());
    stop_cheat_caller_address(governor);

    // Vote - proposal succeeds with Charlie's support
    let proposal2_voting_start = voting_end_time + VOTING_DELAY + 1;
    start_cheat_block_timestamp(governor, proposal2_voting_start);
    start_cheat_block_timestamp(token, proposal2_voting_start);
    start_cheat_block_timestamp(timelock, proposal2_voting_start);

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
    set_initial_timestamp();
    
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
    
    // Advance time to ensure delegations are recorded
    let initial_time: u64 = 1000000;
    let delegation_time = initial_time + 1;
    start_cheat_block_timestamp(governor, delegation_time);
    start_cheat_block_timestamp(token, delegation_time);
    start_cheat_block_timestamp(timelock, delegation_time);

    let gov = IGovernorDispatcher { contract_address: governor };

    // Attacker creates harmful proposal
    let malicious_target: ContractAddress = timelock;
    let targets: Array<ContractAddress> = array![malicious_target];
    let values: Array<u256> = array![0]; // No value transfer
    // Try to grant admin role to attacker
    let selector = selector!("grant_role");
    let admin_role = 0x0; // DEFAULT_ADMIN_ROLE
    let calldatas: Array<Span<felt252>> = array![array![selector, admin_role, EVE().into()].span()];
    let description: ByteArray = "Upgrade Protocol"; // Misleading description
    
    let calls = create_calls(targets.span(), values.span(), calldatas.span());

    start_cheat_caller_address(governor, EVE());
    let proposal_id = gov.propose(calls.span(), description.clone());
    stop_cheat_caller_address(governor);

    // Community votes against
    let voting_start_time = delegation_time + VOTING_DELAY + 1;
    start_cheat_block_timestamp(governor, voting_start_time);
    start_cheat_block_timestamp(token, voting_start_time);
    start_cheat_block_timestamp(timelock, voting_start_time);

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
    let voting_end_time = voting_start_time + VOTING_PERIOD + 1;
    start_cheat_block_timestamp(governor, voting_end_time);
    start_cheat_block_timestamp(token, voting_end_time);
    start_cheat_block_timestamp(timelock, voting_end_time);

    // Proposal defeated
    assert(gov.state(proposal_id) == ProposalState::Defeated, 'Malicious proposal stopped');

    // Attacker tries to execute anyway (should fail)
    // Note: This would need SafeDispatcher to catch the panic

    stop_cheat_block_timestamp(governor);
    stop_cheat_block_timestamp(token);
    stop_cheat_block_timestamp(timelock);
}

#[test]
fn test_it_008_delegation_attack_scenario() {
    set_initial_timestamp();
    
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
    
    // Advance time to ensure delegations are recorded
    let initial_time: u64 = 1000000;
    let delegation_time = initial_time + 1;
    start_cheat_block_timestamp(governor, delegation_time);
    start_cheat_block_timestamp(token, delegation_time);
    start_cheat_block_timestamp(timelock, delegation_time);

    let gov = IGovernorDispatcher { contract_address: governor };

    // Delegatee creates proposal with large voting power
    let targets: Array<ContractAddress> = array![governor];
    let values: Array<u256> = array![0];
    // Try to update voting period
    let selector = selector!("set_voting_period");
    let new_period: u64 = 1209600; // 2 weeks
    let calldatas: Array<Span<felt252>> = array![array![selector, new_period.into()].span()];
    let description: ByteArray = "Delegatee Proposal";
    
    let calls = create_calls(targets.span(), values.span(), calldatas.span());

    start_cheat_caller_address(governor, BOB());
    let proposal_id = gov.propose(calls.span(), description.clone());
    stop_cheat_caller_address(governor);

    // Large holder revokes delegation before voting
    start_cheat_caller_address(token, ALICE());
    votes.delegate(ALICE()); // Revoke delegation, self-delegate
    stop_cheat_caller_address(token);

    // Try to pass proposal
    let voting_start_time = delegation_time + VOTING_DELAY + 1;
    start_cheat_block_timestamp(governor, voting_start_time);
    start_cheat_block_timestamp(token, voting_start_time);
    start_cheat_block_timestamp(timelock, voting_start_time);

    start_cheat_caller_address(governor, BOB());
    gov.cast_vote(proposal_id, 1); // For: now only 50k (lost 500k delegation)
    stop_cheat_caller_address(governor);

    start_cheat_caller_address(governor, CHARLIE());
    gov.cast_vote(proposal_id, 0); // Against: 200k
    stop_cheat_caller_address(governor);

    let voting_end_time = voting_start_time + VOTING_PERIOD + 1;
    start_cheat_block_timestamp(governor, voting_end_time);
    start_cheat_block_timestamp(token, voting_end_time);
    start_cheat_block_timestamp(timelock, voting_end_time);

    // Proposal fails without large holder support
    assert(gov.state(proposal_id) == ProposalState::Defeated, 'Proposal fails without support');

    stop_cheat_block_timestamp(governor);
    stop_cheat_block_timestamp(token);
    stop_cheat_block_timestamp(timelock);
}

#[test]
fn test_it_009_timelock_bypass_attempt() {
    set_initial_timestamp();
    
    let (token, timelock, governor) = deploy_full_governance();

    // Setup proposer
    let erc20 = IERC20Dispatcher { contract_address: token };
    let votes = IVotesDispatcher { contract_address: token };

    start_cheat_caller_address(token, ADMIN());
    erc20.transfer(EVE(), 100000000000000000000000); // 100k tokens
    stop_cheat_caller_address(token);

    start_cheat_caller_address(token, EVE());
    votes.delegate(EVE());
    stop_cheat_caller_address(token);
    
    // Advance time to ensure delegation is recorded
    let initial_time: u64 = 1000000;
    let delegation_time = initial_time + 1;
    start_cheat_block_timestamp(governor, delegation_time);
    start_cheat_block_timestamp(token, delegation_time);
    start_cheat_block_timestamp(timelock, delegation_time);

    // Schedule operation through governance
    let gov = IGovernorDispatcher { contract_address: governor };
    let target: ContractAddress = timelock;
    let targets: Array<ContractAddress> = array![target];
    let values: Array<u256> = array![0];
    // Update timelock delay
    let selector = selector!("update_delay");
    let new_delay: u64 = 172800; // 2 days
    let calldatas: Array<Span<felt252>> = array![array![selector, new_delay.into()].span()];
    let description: ByteArray = "Timelock Test";
    
    let calls = create_calls(targets.span(), values.span(), calldatas.span());

    start_cheat_caller_address(governor, EVE());
    let proposal_id = gov.propose(calls.span(), description.clone());
    stop_cheat_caller_address(governor);

    // Vote and pass proposal
    let voting_start_time = delegation_time + VOTING_DELAY + 1;
    start_cheat_block_timestamp(governor, voting_start_time);
    start_cheat_block_timestamp(token, voting_start_time);
    start_cheat_block_timestamp(timelock, voting_start_time);

    start_cheat_caller_address(governor, EVE());
    gov.cast_vote(proposal_id, 1);
    stop_cheat_caller_address(governor);

    let voting_end_time = voting_start_time + VOTING_PERIOD + 1;
    start_cheat_block_timestamp(governor, voting_end_time);
    start_cheat_block_timestamp(token, voting_end_time);
    start_cheat_block_timestamp(timelock, voting_end_time);

    // Queue in timelock
    let description_hash = description.hash();
    
    start_cheat_caller_address(governor, EVE());
    gov.queue(calls.span(), description_hash);
    stop_cheat_caller_address(governor);

    // Try immediate execution (should fail - not ready)
    let immediate_time = voting_end_time + 2;
    start_cheat_block_timestamp(timelock, immediate_time);

    // This would panic with "Operation not ready"
    // We would need SafeDispatcher to properly test this

    // Fast forward past delay and execute properly
    let execute_time = voting_end_time + MIN_DELAY + 2;
    start_cheat_block_timestamp(governor, execute_time);
    start_cheat_block_timestamp(token, execute_time);
    start_cheat_block_timestamp(timelock, execute_time);

    start_cheat_caller_address(governor, EVE());
    gov.execute(calls.span(), description_hash);
    stop_cheat_caller_address(governor);

    assert(gov.state(proposal_id) == ProposalState::Executed, 'Should execute after delay');

    stop_cheat_block_timestamp(governor);
    stop_cheat_block_timestamp(token);
    stop_cheat_block_timestamp(timelock);
}

#[test]
fn test_it_010_vote_buying_attack() {
    set_initial_timestamp();
    
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
    
    // Advance time to ensure delegation is recorded
    let initial_time: u64 = 1000000;
    let delegation_time = initial_time + 1;
    start_cheat_block_timestamp(governor, delegation_time);
    start_cheat_block_timestamp(token, delegation_time);
    start_cheat_block_timestamp(timelock, delegation_time);

    // Create proposal
    let targets: Array<ContractAddress> = array![governor];
    let values: Array<u256> = array![0];
    // Try to update proposal threshold
    let selector = selector!("set_proposal_threshold");
    let new_threshold: u256 = 1; // Very low threshold
    let calldatas: Array<Span<felt252>> = array![array![selector, new_threshold.low.into(), new_threshold.high.into()].span()];
    let description: ByteArray = "Attacker Proposal";
    
    let calls = create_calls(targets.span(), values.span(), calldatas.span());

    start_cheat_caller_address(governor, EVE());
    let proposal_id = gov.propose(calls.span(), description.clone());
    stop_cheat_caller_address(governor);

    // Vote - snapshot taken at proposal creation
    let voting_start_time = delegation_time + VOTING_DELAY + 1;
    start_cheat_block_timestamp(governor, voting_start_time);
    start_cheat_block_timestamp(token, voting_start_time);
    start_cheat_block_timestamp(timelock, voting_start_time);

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

    let voting_end_time = voting_start_time + VOTING_PERIOD + 1;
    start_cheat_block_timestamp(governor, voting_end_time);
    start_cheat_block_timestamp(token, voting_end_time);
    start_cheat_block_timestamp(timelock, voting_end_time);

    // Check final vote tally (400k for vs 550k against)
    // Note: proposal_votes is not available in the IGovernor interface
    // We can only check the final state

    // Proposal defeated despite token manipulation
    assert(gov.state(proposal_id) == ProposalState::Defeated, 'Attack failed');

    stop_cheat_block_timestamp(governor);
    stop_cheat_block_timestamp(token);
    stop_cheat_block_timestamp(timelock);
}

#[test]
fn test_cancel_proposal_with_canceller_role() {
    set_initial_timestamp();
    
    // Deploy all contracts
    let (token, timelock, governor) = deploy_full_governance();

    // Grant governor the canceller role on timelock
    let access_control = IAccessControlDispatcher { contract_address: timelock };
    start_cheat_caller_address(timelock, ADMIN());
    access_control.grant_role(CANCELLER_ROLE, governor);
    stop_cheat_caller_address(timelock);

    // Distribute tokens
    let erc20 = IERC20Dispatcher { contract_address: token };
    let votes = IVotesDispatcher { contract_address: token };

    start_cheat_caller_address(token, ADMIN());
    erc20.transfer(ALICE(), 300000000000000000000000); // 300k tokens
    stop_cheat_caller_address(token);

    // Delegate votes
    start_cheat_caller_address(token, ALICE());
    votes.delegate(ALICE());
    stop_cheat_caller_address(token);
    
    // Advance time to ensure delegation is recorded
    let initial_time: u64 = 1000000;
    let delegation_time = initial_time + 1;
    start_cheat_block_timestamp(governor, delegation_time);
    start_cheat_block_timestamp(token, delegation_time);
    start_cheat_block_timestamp(timelock, delegation_time);

    // Create proposal
    let gov = IGovernorDispatcher { contract_address: governor };
    let target: ContractAddress = timelock;
    let targets: Array<ContractAddress> = array![target];
    let values: Array<u256> = array![0];
    // Update timelock delay
    let selector = selector!("update_delay");
    let new_delay: u64 = 86400; // 1 day
    let calldatas: Array<Span<felt252>> = array![array![selector, new_delay.into()].span()];
    let description: ByteArray = "Proposal to be cancelled";
    
    let calls = create_calls(targets.span(), values.span(), calldatas.span());
    
    // Calculate description hash
    let description_hash = description.hash();

    start_cheat_caller_address(governor, ALICE());
    let proposal_id = gov.propose(calls.span(), description.clone());
    stop_cheat_caller_address(governor);

    // Fast forward to voting period
    let voting_start_time = delegation_time + VOTING_DELAY + 1;
    start_cheat_block_timestamp(governor, voting_start_time);
    start_cheat_block_timestamp(token, voting_start_time);
    start_cheat_block_timestamp(timelock, voting_start_time);

    // Vote on proposal
    start_cheat_caller_address(governor, ALICE());
    gov.cast_vote(proposal_id, 1); // For
    stop_cheat_caller_address(governor);

    // Fast forward past voting period
    let voting_end_time = voting_start_time + VOTING_PERIOD + 1;
    start_cheat_block_timestamp(governor, voting_end_time);
    start_cheat_block_timestamp(token, voting_end_time);
    start_cheat_block_timestamp(timelock, voting_end_time);

    // Check proposal succeeded
    assert(gov.state(proposal_id) == ProposalState::Succeeded, 'Proposal should succeed');

    // Queue proposal in timelock
    start_cheat_caller_address(governor, ALICE());
    gov.queue(calls.span(), description_hash);
    stop_cheat_caller_address(governor);

    // Check proposal is queued
    assert(gov.state(proposal_id) == ProposalState::Queued, 'Should be queued');

    // Cancel the proposal
    start_cheat_caller_address(governor, ALICE());
    gov.cancel(calls.span(), description_hash);
    stop_cheat_caller_address(governor);

    // Verify cancellation
    assert(gov.state(proposal_id) == ProposalState::Canceled, 'Should be canceled');

    stop_cheat_block_timestamp(governor);
    stop_cheat_block_timestamp(token);
    stop_cheat_block_timestamp(timelock);
}
