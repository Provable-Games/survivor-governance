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
    ContractClassTrait, DeclareResultTrait, declare, start_cheat_block_timestamp,
    start_cheat_caller_address, stop_cheat_block_timestamp, stop_cheat_caller_address,
};
use starknet::account::Call;
use starknet::{ContractAddress, get_block_timestamp};

// Role constants
const PROPOSER_ROLE: felt252 = 0x9aa5aeb3702cfd50b6b62bc4532604938f21248a27a1d5ca736082b6819cc1;
const EXECUTOR_ROLE: felt252 = 0xaa0f3194971a2a116679f7c2090f6939c8d4e01a2a8d7e41d55e5351469e63;
const CANCELLER_ROLE: felt252 = 0x01643c72710c63c0180259aba6b2d05451e3591a24e58b62239378085726f783;
const DEFAULT_ADMIN_ROLE: felt252 = 0;

fn ADMIN() -> ContractAddress {
    'ADMIN'.try_into().unwrap()
}

fn USER1() -> ContractAddress {
    'USER1'.try_into().unwrap()
}

fn USER2() -> ContractAddress {
    'USER2'.try_into().unwrap()
}

fn USER3() -> ContractAddress {
    'USER3'.try_into().unwrap()
}

fn ATTACKER() -> ContractAddress {
    'ATTACKER'.try_into().unwrap()
}

fn ZERO() -> ContractAddress {
    0.try_into().unwrap()
}

#[derive(Drop)]
struct GovernanceSystem {
    token: ContractAddress,
    governor: ContractAddress,
    timelock: ContractAddress,
}

fn deploy_governance_system() -> GovernanceSystem {
    // Deploy token
    let token_class = declare("SurvivorToken").unwrap().contract_class();
    let initial_supply: u256 = 10000000 * 1000000000000000000; // 10M tokens

    let token_name: ByteArray = "Governance Token";
    let token_symbol: ByteArray = "GOV";

    let mut token_calldata = array![];
    token_name.serialize(ref token_calldata);
    token_symbol.serialize(ref token_calldata);
    token_calldata.append(initial_supply.low.into());
    token_calldata.append(initial_supply.high.into());
    token_calldata.append(ADMIN().into());

    let (token_address, _) = token_class.deploy(@token_calldata).unwrap();

    // Deploy timelock controller
    let controller_class = declare("SurvivorGovernorController").unwrap().contract_class();
    let min_delay: u64 = 86400; // 1 day

    let mut controller_calldata: Array<felt252> = array![];
    controller_calldata.append(min_delay.into());
    controller_calldata.append(0); // No proposers initially (governor will be added)
    controller_calldata.append(1); // One executor (zero address = anyone)
    controller_calldata.append(ZERO().into());
    controller_calldata.append(ADMIN().into());

    let (controller_address, _) = controller_class.deploy(@controller_calldata).unwrap();

    // Deploy governor
    let governor_class = declare("SurvivorGovernor").unwrap().contract_class();
    let mut governor_calldata = array![];
    governor_calldata.append(token_address.into());
    governor_calldata.append(controller_address.into());

    let (governor_address, _) = governor_class.deploy(@governor_calldata).unwrap();

    // Grant proposer role to governor
    let access_control = IAccessControlDispatcher { contract_address: controller_address };
    start_cheat_caller_address(controller_address, ADMIN());
    access_control.grant_role(PROPOSER_ROLE, governor_address);
    stop_cheat_caller_address(controller_address);

    GovernanceSystem {
        token: token_address, governor: governor_address, timelock: controller_address,
    }
}

fn distribute_tokens_and_delegate(system: @GovernanceSystem) {
    let token = IERC20Dispatcher { contract_address: *system.token };
    let votes = IVotesDispatcher { contract_address: *system.token };

    // Distribute tokens
    start_cheat_caller_address(*system.token, ADMIN());
    token.transfer(USER1(), 3000000 * 1000000000000000000); // 30% - Major holder
    token.transfer(USER2(), 2000000 * 1000000000000000000); // 20% - Medium holder
    token.transfer(USER3(), 500000 * 1000000000000000000); // 5% - Small holder
    token.transfer(ATTACKER(), 100000 * 1000000000000000000); // 1% - Potential attacker
    stop_cheat_caller_address(*system.token);

    // Delegate voting power
    let users = array![ADMIN(), USER1(), USER2(), USER3(), ATTACKER()];
    let mut i = 0_u32;
    while i < users.len() {
        let user = *users.at(i);
        start_cheat_caller_address(*system.token, user);
        votes.delegate(user);
        stop_cheat_caller_address(*system.token);
        i += 1;
    };
}

#[test]
fn test_complete_governance_cycle() {
    let system = deploy_governance_system();
    distribute_tokens_and_delegate(@system);

    let governor = IGovernorDispatcher { contract_address: system.governor };
    let timelock = ITimelockDispatcher { contract_address: system.timelock };

    // Step 1: Create proposal
    let target = system.timelock;
    let selector = selector!("update_delay");
    let new_delay: u64 = 172800; // 2 days
    let mut calldata = array![];
    calldata.append(new_delay.into());

    let call = Call { to: target, selector, calldata: calldata.span() };
    let calls = array![call];
    let description: ByteArray =
        "Proposal: Increase timelock delay to 2 days for enhanced security";

    // Set initial timestamp to avoid underflow
    let initial_time = 86400 * 2;
    start_cheat_block_timestamp(system.governor, initial_time);
    start_cheat_block_timestamp(system.token, initial_time);
    start_cheat_block_timestamp(system.timelock, initial_time);

    start_cheat_caller_address(system.governor, USER1());
    let proposal_id = governor.propose(calls.span(), description);
    stop_cheat_caller_address(system.governor);

    // Verify proposal created
    assert!(governor.state(proposal_id) == ProposalState::Pending, "Proposal not pending");

    // Step 2: Wait for voting to start
    start_cheat_block_timestamp(system.governor, initial_time + 86401); // Past voting delay
    start_cheat_block_timestamp(system.token, initial_time + 86401);

    assert!(governor.state(proposal_id) == ProposalState::Active, "Proposal not active");

    // Step 3: Cast votes
    start_cheat_caller_address(system.governor, USER1());
    governor.cast_vote_with_reason(proposal_id, 1, "Support: Improves security");
    stop_cheat_caller_address(system.governor);

    start_cheat_caller_address(system.governor, USER2());
    governor.cast_vote_with_reason(proposal_id, 1, "Support: Good for protocol");
    stop_cheat_caller_address(system.governor);

    start_cheat_caller_address(system.governor, USER3());
    governor.cast_vote_with_reason(proposal_id, 2, "Abstain: Need more info");
    stop_cheat_caller_address(system.governor);

    start_cheat_caller_address(system.governor, ATTACKER());
    governor.cast_vote_with_reason(proposal_id, 0, "Against: Too restrictive");
    stop_cheat_caller_address(system.governor);

    // Step 4: Wait for voting to end
    start_cheat_block_timestamp(system.governor, initial_time + 86401 + 604801);
    start_cheat_block_timestamp(system.token, initial_time + 86401 + 604801);

    // Verify proposal succeeded (majority voted for)
    assert!(governor.state(proposal_id) == ProposalState::Succeeded, "Proposal not succeeded");

    // Step 5: Queue proposal in timelock
    // Use a hash of the description (simplified for testing)
    let description_hash = 0x123456; // Simplified hash
    start_cheat_caller_address(system.governor, USER1());
    governor.queue(calls.span(), description_hash);
    stop_cheat_caller_address(system.governor);

    assert!(governor.state(proposal_id) == ProposalState::Queued, "Proposal not queued");

    // Step 6: Wait for timelock delay
    start_cheat_block_timestamp(system.governor, initial_time + 86401 + 604801 + 86401);
    start_cheat_block_timestamp(system.token, initial_time + 86401 + 604801 + 86401);
    start_cheat_block_timestamp(system.timelock, initial_time + 86401 + 604801 + 86401);

    // Step 7: Execute proposal
    start_cheat_caller_address(system.governor, USER2()); // Anyone can execute
    governor.execute(calls.span(), description_hash);
    stop_cheat_caller_address(system.governor);

    assert!(governor.state(proposal_id) == ProposalState::Executed, "Proposal not executed");

    stop_cheat_block_timestamp(system.governor);
    stop_cheat_block_timestamp(system.token);
    stop_cheat_block_timestamp(system.timelock);
}

#[test]
fn test_emergency_pause_scenario() {
    let system = deploy_governance_system();
    distribute_tokens_and_delegate(@system);

    let governor = IGovernorDispatcher { contract_address: system.governor };

    // Create emergency proposal (in real scenario, would pause critical functions)
    let target = system.governor;
    let selector = selector!("voting_delay"); // Simulate emergency action
    let calldata: Array<felt252> = array![];

    let call = Call { to: target, selector, calldata: calldata.span() };
    let calls = array![call];
    let description: ByteArray = "EMERGENCY: Critical vulnerability detected - pause operations";

    // Set initial timestamp to avoid underflow
    let initial_time = 86400 * 2; // Start at 2 days
    start_cheat_block_timestamp(system.governor, initial_time);
    start_cheat_block_timestamp(system.token, initial_time);

    // Major holders quickly coordinate
    start_cheat_caller_address(system.governor, USER1());
    let proposal_id = governor.propose(calls.span(), description);
    stop_cheat_caller_address(system.governor);

    // Fast forward to voting
    start_cheat_block_timestamp(system.governor, initial_time + 86401);
    start_cheat_block_timestamp(system.token, initial_time + 86401);

    // Major holders vote immediately
    start_cheat_caller_address(system.governor, USER1());
    governor.cast_vote(proposal_id, 1); // 30%
    stop_cheat_caller_address(system.governor);

    start_cheat_caller_address(system.governor, USER2());
    governor.cast_vote(proposal_id, 1); // 20%
    stop_cheat_caller_address(system.governor);

    start_cheat_caller_address(system.governor, ADMIN());
    governor.cast_vote(proposal_id, 1); // 44%
    stop_cheat_caller_address(system.governor);

    // Total: 94% support - well above quorum and majority

    // Fast forward to end of voting
    start_cheat_block_timestamp(system.governor, initial_time + 86401 + 604801);
    start_cheat_block_timestamp(system.token, initial_time + 86401 + 604801);

    assert!(governor.state(proposal_id) == ProposalState::Succeeded, "Emergency proposal failed");

    stop_cheat_block_timestamp(system.governor);
    stop_cheat_block_timestamp(system.token);
}

#[test]
fn test_parameter_update_flow() {
    let system = deploy_governance_system();
    distribute_tokens_and_delegate(@system);

    let governor = IGovernorDispatcher { contract_address: system.governor };

    // Create proposal to update multiple parameters
    // In real implementation, this would call setter functions
    let target = system.governor;
    let selector = selector!("voting_period");
    let calldata: Array<felt252> = array![];

    let call = Call { to: target, selector, calldata: calldata.span() };
    let calls = array![call];
    let description: ByteArray = "Update governance parameters for improved efficiency";

    // Set initial timestamp to avoid underflow
    let initial_time = 86400 * 2;
    start_cheat_block_timestamp(system.governor, initial_time);
    start_cheat_block_timestamp(system.token, initial_time);

    start_cheat_caller_address(system.governor, USER2());
    let proposal_id = governor.propose(calls.span(), description);
    stop_cheat_caller_address(system.governor);

    // Community discussion and voting
    start_cheat_block_timestamp(system.governor, initial_time + 86401);
    start_cheat_block_timestamp(system.token, initial_time + 86401);

    // Mixed opinions
    start_cheat_caller_address(system.governor, USER1());
    governor.cast_vote_with_reason(proposal_id, 1, "Good changes");
    stop_cheat_caller_address(system.governor);

    start_cheat_caller_address(system.governor, USER2());
    governor.cast_vote_with_reason(proposal_id, 1, "I proposed this");
    stop_cheat_caller_address(system.governor);

    start_cheat_caller_address(system.governor, USER3());
    governor.cast_vote_with_reason(proposal_id, 0, "Too many changes at once");
    stop_cheat_caller_address(system.governor);

    // Check if proposal passes
    start_cheat_block_timestamp(system.governor, initial_time + 86401 + 604801);
    start_cheat_block_timestamp(system.token, initial_time + 86401 + 604801);

    let final_state = governor.state(proposal_id);
    assert!(final_state == ProposalState::Succeeded, "Parameter update not approved");

    stop_cheat_block_timestamp(system.governor);
    stop_cheat_block_timestamp(system.token);
}

#[test]
fn test_failed_proposal_recovery() {
    let system = deploy_governance_system();
    distribute_tokens_and_delegate(@system);

    let governor = IGovernorDispatcher { contract_address: system.governor };

    // First proposal - will fail
    let target = system.governor;
    let selector = selector!("voting_delay");
    let calldata: Array<felt252> = array![];

    let call = Call { to: target, selector, calldata: calldata.span() };
    let calls = array![call];
    let description: ByteArray = "Controversial proposal";

    // Set initial timestamp to avoid underflow
    let initial_time = 86400 * 2;
    start_cheat_block_timestamp(system.governor, initial_time);
    start_cheat_block_timestamp(system.token, initial_time);

    start_cheat_caller_address(system.governor, USER1());
    let proposal_id_1 = governor.propose(calls.span(), description);
    stop_cheat_caller_address(system.governor);

    start_cheat_block_timestamp(system.governor, initial_time + 86401);
    start_cheat_block_timestamp(system.token, initial_time + 86401);

    // Majority votes against
    start_cheat_caller_address(system.governor, ADMIN());
    governor.cast_vote(proposal_id_1, 0); // 44% against
    stop_cheat_caller_address(system.governor);

    start_cheat_caller_address(system.governor, USER2());
    governor.cast_vote(proposal_id_1, 0); // 20% against
    stop_cheat_caller_address(system.governor);

    start_cheat_caller_address(system.governor, USER1());
    governor.cast_vote(proposal_id_1, 1); // 30% for
    stop_cheat_caller_address(system.governor);

    // Proposal fails
    start_cheat_block_timestamp(system.governor, initial_time + 86401 + 604801);
    start_cheat_block_timestamp(system.token, initial_time + 86401 + 604801);
    assert!(governor.state(proposal_id_1) == ProposalState::Defeated, "Should be defeated");

    // Second proposal - improved version
    let description2: ByteArray = "Improved proposal with community feedback";

    start_cheat_caller_address(system.governor, USER1());
    let proposal_id_2 = governor.propose(calls.span(), description2);
    stop_cheat_caller_address(system.governor);

    // This time it passes
    start_cheat_block_timestamp(system.governor, initial_time + 86401 + 604801 + 86401);
    start_cheat_block_timestamp(system.token, initial_time + 86401 + 604801 + 86401);

    start_cheat_caller_address(system.governor, USER1());
    governor.cast_vote(proposal_id_2, 1);
    stop_cheat_caller_address(system.governor);

    start_cheat_caller_address(system.governor, USER2());
    governor.cast_vote(proposal_id_2, 1);
    stop_cheat_caller_address(system.governor);

    start_cheat_caller_address(system.governor, ADMIN());
    governor.cast_vote(proposal_id_2, 1);
    stop_cheat_caller_address(system.governor);

    start_cheat_block_timestamp(system.governor, initial_time + 86401 + 604801 + 86401 + 604801);
    start_cheat_block_timestamp(system.token, initial_time + 86401 + 604801 + 86401 + 604801);
    assert!(
        governor.state(proposal_id_2) == ProposalState::Succeeded, "Improved proposal should pass",
    );

    stop_cheat_block_timestamp(system.governor);
    stop_cheat_block_timestamp(system.token);
}

#[test]
fn test_malicious_proposal_defense() {
    let system = deploy_governance_system();
    distribute_tokens_and_delegate(@system);

    let governor = IGovernorDispatcher { contract_address: system.governor };
    let votes = IVotesDispatcher { contract_address: system.token };

    // Attacker creates harmful proposal
    // (In reality would try to drain funds or break protocol)
    let target = system.timelock;
    let selector = selector!("grant_role");
    let mut calldata = array![];
    calldata.append(DEFAULT_ADMIN_ROLE); // Try to get admin role
    calldata.append(ATTACKER().into());

    let call = Call { to: target, selector, calldata: calldata.span() };
    let calls = array![call];
    let description: ByteArray = "Routine maintenance update"; // Deceptive description

    // Attacker needs tokens to propose
    // First, attacker buys more tokens (simulated by transfer)
    start_cheat_caller_address(system.token, ADMIN());
    let token = IERC20Dispatcher { contract_address: system.token };
    token.transfer(ATTACKER(), 10000 * 1000000000000000000); // Now has enough to propose
    stop_cheat_caller_address(system.token);

    start_cheat_caller_address(system.token, ATTACKER());
    votes.delegate(ATTACKER());
    stop_cheat_caller_address(system.token);

    // Set initial timestamp to avoid underflow
    let initial_time = 86400 * 2;
    start_cheat_block_timestamp(system.governor, initial_time);
    start_cheat_block_timestamp(system.token, initial_time);

    // Create malicious proposal
    start_cheat_caller_address(system.governor, ATTACKER());
    let proposal_id = governor.propose(calls.span(), description);
    stop_cheat_caller_address(system.governor);

    // Community detects and votes against
    start_cheat_block_timestamp(system.governor, initial_time + 86401);
    start_cheat_block_timestamp(system.token, initial_time + 86401);

    start_cheat_caller_address(system.governor, USER1());
    governor.cast_vote_with_reason(proposal_id, 0, "MALICIOUS: Do not approve!");
    stop_cheat_caller_address(system.governor);

    start_cheat_caller_address(system.governor, USER2());
    governor.cast_vote_with_reason(proposal_id, 0, "Security alert!");
    stop_cheat_caller_address(system.governor);

    start_cheat_caller_address(system.governor, ADMIN());
    governor.cast_vote_with_reason(proposal_id, 0, "Attempting to compromise protocol");
    stop_cheat_caller_address(system.governor);

    start_cheat_caller_address(system.governor, USER3());
    governor.cast_vote_with_reason(proposal_id, 0, "Voting against");
    stop_cheat_caller_address(system.governor);

    // Even if attacker votes for
    start_cheat_caller_address(system.governor, ATTACKER());
    governor.cast_vote(proposal_id, 1);
    stop_cheat_caller_address(system.governor);

    // Proposal is defeated
    start_cheat_block_timestamp(system.governor, initial_time + 86401 + 604801);
    start_cheat_block_timestamp(system.token, initial_time + 86401 + 604801);
    assert!(
        governor.state(proposal_id) == ProposalState::Defeated, "Malicious proposal not defeated",
    );

    // Even if it somehow passed, timelock gives time to respond
    // Admin could revoke roles, pause contracts, etc. during timelock period

    stop_cheat_block_timestamp(system.governor);
    stop_cheat_block_timestamp(system.token);
}

#[test]
fn test_delegation_power_shift() {
    let system = deploy_governance_system();
    distribute_tokens_and_delegate(@system);

    let governor = IGovernorDispatcher { contract_address: system.governor };
    let votes = IVotesDispatcher { contract_address: system.token };

    // Create proposal
    let target = system.governor;
    let selector = selector!("voting_delay");
    let calldata: Array<felt252> = array![];

    let call = Call { to: target, selector, calldata: calldata.span() };
    let calls = array![call];
    let description: ByteArray = "Test delegation dynamics";

    // Set initial timestamp to avoid underflow
    let initial_time = 86400 * 2;
    start_cheat_block_timestamp(system.governor, initial_time);
    start_cheat_block_timestamp(system.token, initial_time);

    start_cheat_caller_address(system.governor, USER1());
    let proposal_id = governor.propose(calls.span(), description);
    stop_cheat_caller_address(system.governor);

    // Start voting
    start_cheat_block_timestamp(system.governor, initial_time + 86401);
    start_cheat_block_timestamp(system.token, initial_time + 86401);

    // USER1 votes with their power
    start_cheat_caller_address(system.governor, USER1());
    governor.cast_vote(proposal_id, 1); // 30% for
    stop_cheat_caller_address(system.governor);

    // USER2 delegates to USER3 mid-voting
    // Note: This won't affect current proposal (snapshot already taken)
    start_cheat_caller_address(system.token, USER2());
    votes.delegate(USER3());
    stop_cheat_caller_address(system.token);

    // USER3 now has their own + USER2's power for future proposals
    let user3_power = votes.get_votes(USER3());
    assert!(user3_power == 2500000 * 1000000000000000000, "Delegation not reflected");

    // For current proposal, USER2's voting power was already snapshot
    // They cannot vote again after delegating mid-voting

    stop_cheat_block_timestamp(system.governor);
    stop_cheat_block_timestamp(system.token);
}

#[test]
fn test_timelock_bypass_prevention() {
    let system = deploy_governance_system();
    distribute_tokens_and_delegate(@system);

    let governor = IGovernorDispatcher { contract_address: system.governor };
    let timelock = ITimelockDispatcher { contract_address: system.timelock };

    // Create and pass proposal
    let target = system.timelock;
    let selector = selector!("update_delay");
    let new_delay: u64 = 1; // Try to set minimal delay
    let mut calldata = array![];
    calldata.append(new_delay.into());

    let call = Call { to: target, selector, calldata: calldata.span() };
    let calls = array![call];
    let description: ByteArray = "Reduce timelock for efficiency";
    // Compute the hash before using the description
    let description_hash = description.hash();

    // Set initial timestamp to avoid underflow
    let initial_time = 86400 * 2;
    start_cheat_block_timestamp(system.governor, initial_time);
    start_cheat_block_timestamp(system.token, initial_time);
    start_cheat_block_timestamp(system.timelock, initial_time);

    start_cheat_caller_address(system.governor, USER1());
    let proposal_id = governor.propose(calls.span(), description);
    stop_cheat_caller_address(system.governor);

    // Fast track voting
    start_cheat_block_timestamp(system.governor, initial_time + 86401);
    start_cheat_block_timestamp(system.token, initial_time + 86401);

    // Get it passed
    start_cheat_caller_address(system.governor, USER1());
    governor.cast_vote(proposal_id, 1);
    stop_cheat_caller_address(system.governor);

    start_cheat_caller_address(system.governor, USER2());
    governor.cast_vote(proposal_id, 1);
    stop_cheat_caller_address(system.governor);

    start_cheat_block_timestamp(system.governor, initial_time + 86401 + 604801);
    start_cheat_block_timestamp(system.token, initial_time + 86401 + 604801);
    start_cheat_block_timestamp(system.timelock, initial_time + 86401 + 604801);
    assert!(governor.state(proposal_id) == ProposalState::Succeeded, "Proposal didn't pass");

    // Queue in timelock (using the actual description hash)
    start_cheat_caller_address(system.governor, USER1());
    governor.queue(calls.span(), description_hash);
    stop_cheat_caller_address(system.governor);

    assert(governor.state(proposal_id) == ProposalState::Queued, 'Should be queued');

    // Now wait for timelock delay and execute successfully
    let execution_time = initial_time + 86401 + 604801 + 86400 + 1; // After min delay
    start_cheat_block_timestamp(system.governor, execution_time);
    start_cheat_block_timestamp(system.token, execution_time);
    start_cheat_block_timestamp(system.timelock, execution_time);

    // Now execution should succeed
    start_cheat_caller_address(system.governor, USER1());
    governor.execute(calls.span(), description_hash);
    stop_cheat_caller_address(system.governor);

    assert(governor.state(proposal_id) == ProposalState::Executed, 'Should be executed');

    stop_cheat_block_timestamp(system.governor);
    stop_cheat_block_timestamp(system.token);
    stop_cheat_block_timestamp(system.timelock);
}

#[test]
#[should_panic(expected: 'Timelock: expected Ready op')]
fn test_timelock_immediate_execution_fails() {
    let system = deploy_governance_system();
    distribute_tokens_and_delegate(@system);

    let governor = IGovernorDispatcher { contract_address: system.governor };

    // Create and pass proposal
    let target = system.timelock;
    let selector = selector!("update_delay");
    let new_delay: u64 = 1; // Try to set minimal delay
    let mut calldata = array![];
    calldata.append(new_delay.into());

    let call = Call { to: target, selector, calldata: calldata.span() };
    let calls = array![call];
    let description: ByteArray = "Reduce timelock for efficiency";
    let description_hash = description.hash();

    // Set initial timestamp to avoid underflow
    let initial_time = 86400 * 2;
    start_cheat_block_timestamp(system.governor, initial_time);
    start_cheat_block_timestamp(system.token, initial_time);
    start_cheat_block_timestamp(system.timelock, initial_time);

    start_cheat_caller_address(system.governor, USER1());
    let proposal_id = governor.propose(calls.span(), description);
    stop_cheat_caller_address(system.governor);

    // Fast track voting
    start_cheat_block_timestamp(system.governor, initial_time + 86401);
    start_cheat_block_timestamp(system.token, initial_time + 86401);

    // Get it passed
    start_cheat_caller_address(system.governor, USER1());
    governor.cast_vote(proposal_id, 1);
    stop_cheat_caller_address(system.governor);

    start_cheat_caller_address(system.governor, USER2());
    governor.cast_vote(proposal_id, 1);
    stop_cheat_caller_address(system.governor);

    start_cheat_block_timestamp(system.governor, initial_time + 86401 + 604801);
    start_cheat_block_timestamp(system.token, initial_time + 86401 + 604801);
    start_cheat_block_timestamp(system.timelock, initial_time + 86401 + 604801);

    // Queue in timelock
    start_cheat_caller_address(system.governor, USER1());
    governor.queue(calls.span(), description_hash);
    stop_cheat_caller_address(system.governor);

    // Try to execute immediately - this should panic with 'Operation not ready'
    start_cheat_caller_address(system.governor, USER1());
    governor.execute(calls.span(), description_hash);
    stop_cheat_caller_address(system.governor);
}
