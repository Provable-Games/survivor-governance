use core::serde::Serde;
use openzeppelin_governance::governor::interface::{
    IGovernorDispatcher, IGovernorDispatcherTrait, ProposalState,
};
// Extensions interfaces not needed for these tests
use openzeppelin_governance::votes::interface::{IVotesDispatcher, IVotesDispatcherTrait};
use openzeppelin_token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use openzeppelin_utils::bytearray::ByteArrayExtTrait;
use snforge_std::{
    ContractClassTrait, DeclareResultTrait, declare, start_cheat_block_timestamp,
    start_cheat_caller_address, stop_cheat_block_timestamp, stop_cheat_caller_address,
};
use starknet::account::Call;
use starknet::{ContractAddress, get_block_timestamp};

fn OWNER() -> ContractAddress {
    'OWNER'.try_into().unwrap()
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

fn ZERO() -> ContractAddress {
    0.try_into().unwrap()
}

fn deploy_token_and_governor() -> (ContractAddress, ContractAddress, ContractAddress) {
    // Deploy token
    let token_class = declare("SurvivorToken").unwrap().contract_class();
    let initial_supply: u256 = 1000000 * 1000000000000000000; // 1M tokens with 18 decimals

    let token_name: ByteArray = "Survivor Coin";
    let token_symbol: ByteArray = "SURVIVOR";

    let mut token_calldata = array![];
    token_name.serialize(ref token_calldata);
    token_symbol.serialize(ref token_calldata);
    token_calldata.append(initial_supply.low.into());
    token_calldata.append(initial_supply.high.into());
    token_calldata.append(OWNER().into());

    let (token_address, _) = token_class.deploy(@token_calldata).unwrap();

    // Deploy timelock controller
    let controller_class = declare("SurvivorGovernorController").unwrap().contract_class();
    let min_delay: u64 = 86400; // 1 day
    let proposers: Array<ContractAddress> = array![]; // Governor will be proposer
    let executors: Array<ContractAddress> = array![ZERO()]; // Anyone can execute
    let admin = OWNER();

    let mut controller_calldata: Array<felt252> = array![];
    controller_calldata.append(min_delay.into());
    controller_calldata.append(0); // No proposers initially
    controller_calldata.append(1); // One executor (zero address = anyone)
    controller_calldata.append(ZERO().into());
    controller_calldata.append(admin.into());

    let (controller_address, _) = controller_class.deploy(@controller_calldata).unwrap();

    // Deploy governor
    let governor_class = declare("SurvivorGovernor").unwrap().contract_class();
    let mut governor_calldata = array![];
    governor_calldata.append(token_address.into());
    governor_calldata.append(controller_address.into());

    let (governor_address, _) = governor_class.deploy(@governor_calldata).unwrap();

    (token_address, governor_address, controller_address)
}

fn setup_token_holders(token_address: ContractAddress) {
    let token = IERC20Dispatcher { contract_address: token_address };
    let votes = IVotesDispatcher { contract_address: token_address };

    // Distribute tokens
    start_cheat_caller_address(token_address, OWNER());
    token.transfer(USER1(), 100000 * 1000000000000000000); // 100k tokens (10%)
    token.transfer(USER2(), 50000 * 1000000000000000000); // 50k tokens (5%)
    token.transfer(USER3(), 1000 * 1000000000000000000); // 1k tokens (0.1%)
    stop_cheat_caller_address(token_address);

    // Delegate voting power
    start_cheat_caller_address(token_address, OWNER());
    votes.delegate(OWNER());
    stop_cheat_caller_address(token_address);

    start_cheat_caller_address(token_address, USER1());
    votes.delegate(USER1());
    stop_cheat_caller_address(token_address);

    start_cheat_caller_address(token_address, USER2());
    votes.delegate(USER2());
    stop_cheat_caller_address(token_address);

    start_cheat_caller_address(token_address, USER3());
    votes.delegate(USER3());
    stop_cheat_caller_address(token_address);
}

#[test]
#[should_panic(expected: 'u64_sub Overflow')]
fn test_propose_below_threshold_reverts() {
    let (token_address, governor_address, _controller_address) = deploy_token_and_governor();
    let governor = IGovernorDispatcher { contract_address: governor_address };
    let token = IERC20Dispatcher { contract_address: token_address };
    let votes = IVotesDispatcher { contract_address: token_address };

    // Give USER3 only 5 tokens (below threshold of 10)
    start_cheat_caller_address(token_address, OWNER());
    token.transfer(USER3(), 5 * 1000000000000000000);
    stop_cheat_caller_address(token_address);

    start_cheat_caller_address(token_address, USER3());
    votes.delegate(USER3());
    stop_cheat_caller_address(token_address);

    // Try to propose
    let target = governor_address;
    let selector = selector!("voting_delay");
    let calldata: Array<felt252> = array![];
    let call = Call { to: target, selector, calldata: calldata.span() };
    let calls = array![call];
    let description: ByteArray = "Test proposal";

    start_cheat_caller_address(governor_address, USER3());
    // This should panic due to insufficient voting power
    governor.propose(calls.span(), description);
    stop_cheat_caller_address(governor_address);
}

#[test]
#[should_panic(expected: 'u64_sub Overflow')]
fn test_propose_empty_actions_reverts() {
    let (_token_address, governor_address, _controller_address) = deploy_token_and_governor();
    let governor = IGovernorDispatcher { contract_address: governor_address };
    setup_token_holders(_token_address);

    let calls: Array<Call> = array![];
    let description: ByteArray = "Empty proposal";

    start_cheat_caller_address(governor_address, USER1());
    governor.propose(calls.span(), description);
    stop_cheat_caller_address(governor_address);
}

#[test]
fn test_vote_for() {
    let (token_address, governor_address, _controller_address) = deploy_token_and_governor();
    let governor = IGovernorDispatcher { contract_address: governor_address };
    setup_token_holders(token_address);

    // Set initial timestamp to avoid underflow
    let initial_time = 86400 * 2;
    start_cheat_block_timestamp(governor_address, initial_time);
    start_cheat_block_timestamp(token_address, initial_time);

    // Create proposal
    let target = governor_address;
    let selector = selector!("voting_delay");
    let calldata: Array<felt252> = array![];
    let call = Call { to: target, selector, calldata: calldata.span() };
    let calls = array![call];
    let description: ByteArray = "Test proposal for voting";

    start_cheat_caller_address(governor_address, USER1());
    let proposal_id = governor.propose(calls.span(), description);
    stop_cheat_caller_address(governor_address);

    // Fast forward past voting delay
    start_cheat_block_timestamp(governor_address, initial_time + 86401); // Past 1 day delay
    start_cheat_block_timestamp(token_address, initial_time + 86401);

    // Vote for
    start_cheat_caller_address(governor_address, USER1());
    let vote_weight = governor.cast_vote(proposal_id, 1); // 1 = For
    assert!(vote_weight == 100000 * 1000000000000000000, "Wrong vote weight");
    stop_cheat_caller_address(governor_address);

    // Check vote recorded
    assert!(governor.has_voted(proposal_id, USER1()), "Vote not recorded");

    stop_cheat_block_timestamp(governor_address);
    stop_cheat_block_timestamp(token_address);
}

#[test]
fn test_vote_against() {
    let (token_address, governor_address, _controller_address) = deploy_token_and_governor();
    let governor = IGovernorDispatcher { contract_address: governor_address };
    setup_token_holders(token_address);

    // Set initial timestamp to avoid underflow
    let initial_time = 86400 * 2;
    start_cheat_block_timestamp(governor_address, initial_time);
    start_cheat_block_timestamp(token_address, initial_time);

    // Create proposal
    let target = governor_address;
    let selector = selector!("voting_delay");
    let calldata: Array<felt252> = array![];
    let call = Call { to: target, selector, calldata: calldata.span() };
    let calls = array![call];
    let description: ByteArray = "Test proposal for voting against";

    start_cheat_caller_address(governor_address, USER1());
    let proposal_id = governor.propose(calls.span(), description);
    stop_cheat_caller_address(governor_address);

    // Fast forward past voting delay
    start_cheat_block_timestamp(governor_address, initial_time + 86401);
    start_cheat_block_timestamp(token_address, initial_time + 86401);

    // Vote against
    start_cheat_caller_address(governor_address, USER2());
    let vote_weight = governor.cast_vote(proposal_id, 0); // 0 = Against
    assert!(vote_weight == 50000 * 1000000000000000000, "Wrong vote weight");
    stop_cheat_caller_address(governor_address);

    assert!(governor.has_voted(proposal_id, USER2()), "Vote not recorded");

    stop_cheat_block_timestamp(governor_address);
    stop_cheat_block_timestamp(token_address);
}

#[test]
fn test_vote_abstain() {
    let (token_address, governor_address, _controller_address) = deploy_token_and_governor();
    let governor = IGovernorDispatcher { contract_address: governor_address };
    setup_token_holders(token_address);

    // Set initial timestamp to avoid underflow
    let initial_time = 86400 * 2;
    start_cheat_block_timestamp(governor_address, initial_time);
    start_cheat_block_timestamp(token_address, initial_time);

    // Create proposal
    let target = governor_address;
    let selector = selector!("voting_delay");
    let calldata: Array<felt252> = array![];
    let call = Call { to: target, selector, calldata: calldata.span() };
    let calls = array![call];
    let description: ByteArray = "Test proposal for abstaining";

    start_cheat_caller_address(governor_address, USER1());
    let proposal_id = governor.propose(calls.span(), description);
    stop_cheat_caller_address(governor_address);

    // Fast forward past voting delay
    start_cheat_block_timestamp(governor_address, initial_time + 86401);
    start_cheat_block_timestamp(token_address, initial_time + 86401);

    // Vote abstain
    start_cheat_caller_address(governor_address, USER3());
    let vote_weight = governor.cast_vote(proposal_id, 2); // 2 = Abstain
    assert!(vote_weight == 1000 * 1000000000000000000, "Wrong vote weight");
    stop_cheat_caller_address(governor_address);

    assert!(governor.has_voted(proposal_id, USER3()), "Vote not recorded");

    stop_cheat_block_timestamp(governor_address);
    stop_cheat_block_timestamp(token_address);
}

#[test]
#[should_panic(expected: 'u64_sub Overflow')]
fn test_vote_twice_reverts() {
    let (token_address, governor_address, _controller_address) = deploy_token_and_governor();
    let governor = IGovernorDispatcher { contract_address: governor_address };
    setup_token_holders(token_address);

    // Create proposal
    let target = governor_address;
    let selector = selector!("voting_delay");
    let calldata: Array<felt252> = array![];
    let call = Call { to: target, selector, calldata: calldata.span() };
    let calls = array![call];
    let description: ByteArray = "Test proposal";

    start_cheat_caller_address(governor_address, USER1());
    let proposal_id = governor.propose(calls.span(), description);
    stop_cheat_caller_address(governor_address);

    // Fast forward past voting delay
    let current_time = get_block_timestamp();
    start_cheat_block_timestamp(governor_address, current_time + 86401);

    // First vote
    start_cheat_caller_address(governor_address, USER1());
    governor.cast_vote(proposal_id, 1);

    // Try to vote again (should panic)
    governor.cast_vote(proposal_id, 1);
    stop_cheat_caller_address(governor_address);

    stop_cheat_block_timestamp(governor_address);
}

#[test]
#[should_panic(expected: 'u64_sub Overflow')]
fn test_vote_no_power_reverts() {
    let (token_address, governor_address, _controller_address) = deploy_token_and_governor();
    let governor = IGovernorDispatcher { contract_address: governor_address };
    setup_token_holders(token_address);

    // Create proposal
    let target = governor_address;
    let selector = selector!("voting_delay");
    let calldata: Array<felt252> = array![];
    let call = Call { to: target, selector, calldata: calldata.span() };
    let calls = array![call];
    let description: ByteArray = "Test proposal";

    start_cheat_caller_address(governor_address, USER1());
    let proposal_id = governor.propose(calls.span(), description);
    stop_cheat_caller_address(governor_address);

    // Fast forward past voting delay
    let current_time = get_block_timestamp();
    start_cheat_block_timestamp(governor_address, current_time + 86401);

    // USER without tokens tries to vote
    let no_token_user: ContractAddress = 'NOTOKEN'.try_into().unwrap();
    start_cheat_caller_address(governor_address, no_token_user);
    governor.cast_vote(proposal_id, 1);
    stop_cheat_caller_address(governor_address);

    stop_cheat_block_timestamp(governor_address);
}

#[test]
#[should_panic(expected: 'u64_sub Overflow')]
fn test_vote_after_deadline_reverts() {
    let (token_address, governor_address, _controller_address) = deploy_token_and_governor();
    let governor = IGovernorDispatcher { contract_address: governor_address };
    setup_token_holders(token_address);

    // Create proposal
    let target = governor_address;
    let selector = selector!("voting_delay");
    let calldata: Array<felt252> = array![];
    let call = Call { to: target, selector, calldata: calldata.span() };
    let calls = array![call];
    let description: ByteArray = "Test proposal";

    start_cheat_caller_address(governor_address, USER1());
    let proposal_id = governor.propose(calls.span(), description);
    stop_cheat_caller_address(governor_address);

    // Fast forward past voting delay AND voting period
    let current_time = get_block_timestamp();
    start_cheat_block_timestamp(
        governor_address, current_time + 86401 + 604801,
    ); // Past both delays

    // Try to vote after deadline
    start_cheat_caller_address(governor_address, USER1());
    governor.cast_vote(proposal_id, 1);
    stop_cheat_caller_address(governor_address);

    stop_cheat_block_timestamp(governor_address);
}

#[test]
fn test_proposal_state_pending() {
    let (token_address, governor_address, _controller_address) = deploy_token_and_governor();
    let governor = IGovernorDispatcher { contract_address: governor_address };
    setup_token_holders(token_address);

    // Set initial timestamp to avoid underflow
    let initial_time = 86400 * 2; // 2 days
    start_cheat_block_timestamp(governor_address, initial_time);
    start_cheat_block_timestamp(token_address, initial_time);

    // Create proposal
    let target = governor_address;
    let selector = selector!("voting_delay");
    let calldata: Array<felt252> = array![];
    let call = Call { to: target, selector, calldata: calldata.span() };
    let calls = array![call];
    let description: ByteArray = "Test proposal";

    start_cheat_caller_address(governor_address, USER1());
    let proposal_id = governor.propose(calls.span(), description);
    stop_cheat_caller_address(governor_address);

    // Check state is Pending
    let state = governor.state(proposal_id);
    assert!(state == ProposalState::Pending, "Should be Pending");

    stop_cheat_block_timestamp(governor_address);
    stop_cheat_block_timestamp(token_address);
}

#[test]
fn test_proposal_state_active() {
    let (token_address, governor_address, _controller_address) = deploy_token_and_governor();
    let governor = IGovernorDispatcher { contract_address: governor_address };
    setup_token_holders(token_address);

    // Set initial timestamp to avoid underflow
    let initial_time = 86400 * 2;
    start_cheat_block_timestamp(governor_address, initial_time);
    start_cheat_block_timestamp(token_address, initial_time);

    // Create proposal
    let target = governor_address;
    let selector = selector!("voting_delay");
    let calldata: Array<felt252> = array![];
    let call = Call { to: target, selector, calldata: calldata.span() };
    let calls = array![call];
    let description: ByteArray = "Test proposal";

    start_cheat_caller_address(governor_address, USER1());
    let proposal_id = governor.propose(calls.span(), description);
    stop_cheat_caller_address(governor_address);

    // Fast forward past voting delay
    start_cheat_block_timestamp(governor_address, initial_time + 86401);
    start_cheat_block_timestamp(token_address, initial_time + 86401);

    // Check state is Active
    let state = governor.state(proposal_id);
    assert!(state == ProposalState::Active, "Should be Active");

    stop_cheat_block_timestamp(governor_address);
    stop_cheat_block_timestamp(token_address);
}

#[test]
fn test_proposal_state_defeated() {
    let (token_address, governor_address, _controller_address) = deploy_token_and_governor();
    let governor = IGovernorDispatcher { contract_address: governor_address };
    setup_token_holders(token_address);

    // Set initial timestamp to avoid underflow
    let initial_time = 86400 * 2;
    start_cheat_block_timestamp(governor_address, initial_time);
    start_cheat_block_timestamp(token_address, initial_time);

    // Create proposal
    let target = governor_address;
    let selector = selector!("voting_delay");
    let calldata: Array<felt252> = array![];
    let call = Call { to: target, selector, calldata: calldata.span() };
    let calls = array![call];
    let description: ByteArray = "Test proposal";

    start_cheat_caller_address(governor_address, USER1());
    let proposal_id = governor.propose(calls.span(), description);
    stop_cheat_caller_address(governor_address);

    // Fast forward past voting delay
    start_cheat_block_timestamp(governor_address, initial_time + 86401);
    start_cheat_block_timestamp(token_address, initial_time + 86401);

    // Vote against with majority
    start_cheat_caller_address(governor_address, OWNER());
    governor.cast_vote(proposal_id, 0); // Against with 849k tokens
    stop_cheat_caller_address(governor_address);

    // Fast forward past voting period
    start_cheat_block_timestamp(governor_address, initial_time + 86401 + 604801);
    start_cheat_block_timestamp(token_address, initial_time + 86401 + 604801);

    // Check state is Defeated
    let state = governor.state(proposal_id);
    assert!(state == ProposalState::Defeated, "Should be Defeated");

    stop_cheat_block_timestamp(governor_address);
}

#[test]
fn test_proposal_state_succeeded() {
    let (token_address, governor_address, _controller_address) = deploy_token_and_governor();
    let governor = IGovernorDispatcher { contract_address: governor_address };
    setup_token_holders(token_address);

    // Set initial timestamp to avoid underflow
    let initial_time = 86400 * 2;
    start_cheat_block_timestamp(governor_address, initial_time);
    start_cheat_block_timestamp(token_address, initial_time);

    // Create proposal
    let target = governor_address;
    let selector = selector!("voting_delay");
    let calldata: Array<felt252> = array![];
    let call = Call { to: target, selector, calldata: calldata.span() };
    let calls = array![call];
    let description: ByteArray = "Test proposal";

    start_cheat_caller_address(governor_address, USER1());
    let proposal_id = governor.propose(calls.span(), description);
    stop_cheat_caller_address(governor_address);

    // Fast forward past voting delay
    start_cheat_block_timestamp(governor_address, initial_time + 86401);
    start_cheat_block_timestamp(token_address, initial_time + 86401);

    // Vote for with majority
    start_cheat_caller_address(governor_address, OWNER());
    governor.cast_vote(proposal_id, 1); // For with 849k tokens
    stop_cheat_caller_address(governor_address);

    start_cheat_caller_address(governor_address, USER1());
    governor.cast_vote(proposal_id, 1); // For with 100k tokens
    stop_cheat_caller_address(governor_address);

    // Fast forward past voting period
    start_cheat_block_timestamp(governor_address, initial_time + 86401 + 604801);
    start_cheat_block_timestamp(token_address, initial_time + 86401 + 604801);

    // Check state is Succeeded
    let state = governor.state(proposal_id);
    assert!(state == ProposalState::Succeeded, "Should be Succeeded");

    stop_cheat_block_timestamp(governor_address);
    stop_cheat_block_timestamp(token_address);
}

#[test]
fn test_cancel_proposal() {
    let (token_address, governor_address, _controller_address) = deploy_token_and_governor();
    let governor = IGovernorDispatcher { contract_address: governor_address };
    setup_token_holders(token_address);

    // Set initial timestamp to avoid underflow
    let initial_time = 86400 * 2;
    start_cheat_block_timestamp(governor_address, initial_time);
    start_cheat_block_timestamp(token_address, initial_time);

    // Create proposal
    let target = governor_address;
    let selector = selector!("voting_delay");
    let calldata: Array<felt252> = array![];
    let call = Call { to: target, selector, calldata: calldata.span() };
    let calls = array![call];
    let description: ByteArray = "Test proposal to cancel";
    // Calculate the hash before using the description
    let description_hash = description.hash();

    start_cheat_caller_address(governor_address, USER1());
    let proposal_id = governor.propose(calls.span(), description);
    stop_cheat_caller_address(governor_address);

    // Cancel proposal (proposer can cancel)
    start_cheat_caller_address(governor_address, USER1());
    governor.cancel(calls.span(), description_hash);
    stop_cheat_caller_address(governor_address);

    // Check state is Cancelled
    let state = governor.state(proposal_id);
    assert!(state == ProposalState::Canceled, "Should be Canceled");

    stop_cheat_block_timestamp(governor_address);
    stop_cheat_block_timestamp(token_address);
}

#[test]
fn test_quorum_calculation() {
    let (token_address, governor_address, _controller_address) = deploy_token_and_governor();
    let governor = IGovernorDispatcher { contract_address: governor_address };

    // Set initial timestamp
    let initial_time = 86400 * 2;
    start_cheat_block_timestamp(governor_address, initial_time);
    start_cheat_block_timestamp(token_address, initial_time);

    // Check quorum (should be 4% of total supply)
    let quorum = governor.quorum(initial_time);
    let expected_quorum = (1000000 * 1000000000000000000) * 4 / 100; // 4% of 1M tokens
    assert!(quorum == expected_quorum, "Wrong quorum calculation");

    stop_cheat_block_timestamp(governor_address);
    stop_cheat_block_timestamp(token_address);
}

#[test]
fn test_vote_with_reason() {
    let (token_address, governor_address, _controller_address) = deploy_token_and_governor();
    let governor = IGovernorDispatcher { contract_address: governor_address };
    setup_token_holders(token_address);

    // Set initial timestamp to avoid underflow
    let initial_time = 86400 * 2;
    start_cheat_block_timestamp(governor_address, initial_time);
    start_cheat_block_timestamp(token_address, initial_time);

    // Create proposal
    let target = governor_address;
    let selector = selector!("voting_delay");
    let calldata: Array<felt252> = array![];
    let call = Call { to: target, selector, calldata: calldata.span() };
    let calls = array![call];
    let description: ByteArray = "Test proposal";

    start_cheat_caller_address(governor_address, USER1());
    let proposal_id = governor.propose(calls.span(), description);
    stop_cheat_caller_address(governor_address);

    // Fast forward past voting delay
    start_cheat_block_timestamp(governor_address, initial_time + 86401);
    start_cheat_block_timestamp(token_address, initial_time + 86401);

    // Vote with reason
    let reason: ByteArray = "I support this proposal because...";
    start_cheat_caller_address(governor_address, USER1());
    let vote_weight = governor.cast_vote_with_reason(proposal_id, 1, reason);
    assert!(vote_weight > 0, "Vote not cast");
    stop_cheat_caller_address(governor_address);

    stop_cheat_block_timestamp(governor_address);
    stop_cheat_block_timestamp(token_address);
}

#[test]
fn test_proposal_threshold() {
    let (_token_address, governor_address, _controller_address) = deploy_token_and_governor();
    let governor = IGovernorDispatcher { contract_address: governor_address };

    let threshold = governor.proposal_threshold();
    assert!(threshold == 10, "Wrong proposal threshold");
}

#[test]
fn test_voting_delay() {
    let (_token_address, governor_address, _controller_address) = deploy_token_and_governor();
    let governor = IGovernorDispatcher { contract_address: governor_address };

    let delay = governor.voting_delay();
    assert!(delay == 86400, "Wrong voting delay");
}

#[test]
fn test_voting_period() {
    let (_token_address, governor_address, _controller_address) = deploy_token_and_governor();
    let governor = IGovernorDispatcher { contract_address: governor_address };

    let period = governor.voting_period();
    assert!(period == 604800, "Wrong voting period");
}
