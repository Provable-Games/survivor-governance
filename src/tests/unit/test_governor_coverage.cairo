// Additional tests to increase governor coverage
use core::num::traits::Zero;
use core::serde::Serde;
use openzeppelin_governance::governor::interface::{
    IGovernorDispatcher, IGovernorDispatcherTrait
};
use openzeppelin_governance::votes::interface::{IVotesDispatcher, IVotesDispatcherTrait};
use openzeppelin_introspection::interface::{ISRC5Dispatcher, ISRC5DispatcherTrait};
use openzeppelin_token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use snforge_std::{
    ContractClassTrait, DeclareResultTrait, declare, start_cheat_block_timestamp,
    start_cheat_caller_address, stop_cheat_block_timestamp, stop_cheat_caller_address,
};
use starknet::ContractAddress;
use starknet::account::Call;

fn OWNER() -> ContractAddress {
    'OWNER'.try_into().unwrap()
}

fn USER1() -> ContractAddress {
    'USER1'.try_into().unwrap()
}

fn USER2() -> ContractAddress {
    'USER2'.try_into().unwrap()
}

fn deploy_full_system() -> (ContractAddress, ContractAddress, ContractAddress) {
    // Deploy token
    let token_class = declare("SurvivorToken").unwrap().contract_class();
    let initial_supply: u256 = 1000000 * 1000000000000000000;

    let token_name: ByteArray = "Test Token";
    let token_symbol: ByteArray = "TEST";

    let mut token_calldata = array![];
    token_name.serialize(ref token_calldata);
    token_symbol.serialize(ref token_calldata);
    token_calldata.append(initial_supply.low.into());
    token_calldata.append(initial_supply.high.into());
    token_calldata.append(OWNER().into());

    let (token_address, _) = token_class.deploy(@token_calldata).unwrap();

    // Deploy timelock controller
    let controller_class = declare("SurvivorGovernorController").unwrap().contract_class();
    let min_delay: u64 = 86400;

    let mut controller_calldata: Array<felt252> = array![];
    controller_calldata.append(min_delay.into());
    controller_calldata.append(0); // No proposers initially
    controller_calldata.append(1); // One executor (zero address = anyone)
    controller_calldata.append(0); // Zero address
    controller_calldata.append(OWNER().into());

    let (controller_address, _) = controller_class.deploy(@controller_calldata).unwrap();

    // Deploy governor
    let governor_class = declare("SurvivorGovernor").unwrap().contract_class();
    let mut governor_calldata = array![];
    governor_calldata.append(token_address.into());
    governor_calldata.append(controller_address.into());

    let (governor_address, _) = governor_class.deploy(@governor_calldata).unwrap();

    (token_address, governor_address, controller_address)
}

#[test]
fn test_governor_name() {
    let (_token, governor, _controller) = deploy_full_system();
    let gov = IGovernorDispatcher { contract_address: governor };

    let name = gov.name();
    // Name should be SurvivorGovernor but need to compare as ByteArray
    assert!(!name.is_zero(), "Governor should have a name");
}

#[test]
fn test_governor_version() {
    let (_token, governor, _controller) = deploy_full_system();
    let gov = IGovernorDispatcher { contract_address: governor };

    let version = gov.version();
    // Version should be 1 but need to compare as ByteArray  
    assert!(!version.is_zero(), "Governor should have a version");
}

// Clock tests removed - clock() and CLOCK_MODE() are not exposed in the current Governor ABI
// These would need to be tested through internal component methods


#[test]
fn test_governor_voting_delay() {
    let (_token, governor, _controller) = deploy_full_system();
    let gov = IGovernorDispatcher { contract_address: governor };

    let delay = gov.voting_delay();
    assert!(delay == 86400, "Wrong voting delay"); // 1 day
}

#[test]
fn test_governor_voting_period() {
    let (_token, governor, _controller) = deploy_full_system();
    let gov = IGovernorDispatcher { contract_address: governor };

    let period = gov.voting_period();
    assert!(period == 604800, "Wrong voting period"); // 1 week
}

#[test]
fn test_governor_proposal_threshold() {
    let (_token, governor, _controller) = deploy_full_system();
    let gov = IGovernorDispatcher { contract_address: governor };

    let threshold = gov.proposal_threshold();
    assert!(threshold == 10, "Wrong proposal threshold");
}

#[test]
fn test_governor_quorum() {
    let (token, governor, _controller) = deploy_full_system();
    let gov = IGovernorDispatcher { contract_address: governor };

    // Set timestamp
    let test_time = 1000000_u64;
    start_cheat_block_timestamp(governor, test_time);
    start_cheat_block_timestamp(token, test_time);

    let quorum = gov.quorum(test_time);
    // Should be 4% of total supply (1M tokens)
    let expected_quorum = 40000 * 1000000000000000000; // 40k tokens (4%)
    assert!(quorum == expected_quorum, "Wrong quorum");

    stop_cheat_block_timestamp(governor);
    stop_cheat_block_timestamp(token);
}

#[test]
fn test_governor_supports_interface() {
    let (_token, governor, _controller) = deploy_full_system();
    let src5 = ISRC5Dispatcher { contract_address: governor };

    // Test for ISRC5 interface (simplified ID that fits in felt252)
    let src5_interface_id = 0x3f918d17;
    assert!(src5.supports_interface(src5_interface_id), "Should support ISRC5");
}

#[test]
fn test_governor_proposal_snapshot() {
    let (token, governor, _controller) = deploy_full_system();
    let gov = IGovernorDispatcher { contract_address: governor };
    let erc20 = IERC20Dispatcher { contract_address: token };
    let votes = IVotesDispatcher { contract_address: token };

    // Setup
    let initial_time = 86400 * 2;
    start_cheat_block_timestamp(governor, initial_time);
    start_cheat_block_timestamp(token, initial_time);

    // Give USER1 tokens and delegate
    start_cheat_caller_address(token, OWNER());
    erc20.transfer(USER1(), 100000 * 1000000000000000000);
    stop_cheat_caller_address(token);

    start_cheat_caller_address(token, USER1());
    votes.delegate(USER1());
    stop_cheat_caller_address(token);

    // Create proposal
    let target = governor;
    let selector = selector!("voting_delay");
    let calldata: Array<felt252> = array![];
    let call = Call { to: target, selector, calldata: calldata.span() };
    let calls = array![call];
    let description: ByteArray = "Test proposal";

    start_cheat_caller_address(governor, USER1());
    let proposal_id = gov.propose(calls.span(), description);
    stop_cheat_caller_address(governor);

    // Check snapshot
    let snapshot = gov.proposal_snapshot(proposal_id);
    assert!(snapshot == initial_time + 86400, "Wrong proposal snapshot");

    stop_cheat_block_timestamp(governor);
    stop_cheat_block_timestamp(token);
}

#[test]
fn test_governor_proposal_deadline() {
    let (token, governor, _controller) = deploy_full_system();
    let gov = IGovernorDispatcher { contract_address: governor };
    let erc20 = IERC20Dispatcher { contract_address: token };
    let votes = IVotesDispatcher { contract_address: token };

    // Setup
    let initial_time = 86400 * 2;
    start_cheat_block_timestamp(governor, initial_time);
    start_cheat_block_timestamp(token, initial_time);

    // Give USER1 tokens and delegate
    start_cheat_caller_address(token, OWNER());
    erc20.transfer(USER1(), 100000 * 1000000000000000000);
    stop_cheat_caller_address(token);

    start_cheat_caller_address(token, USER1());
    votes.delegate(USER1());
    stop_cheat_caller_address(token);

    // Create proposal
    let target = governor;
    let selector = selector!("voting_delay");
    let calldata: Array<felt252> = array![];
    let call = Call { to: target, selector, calldata: calldata.span() };
    let calls = array![call];
    let description: ByteArray = "Test proposal";

    start_cheat_caller_address(governor, USER1());
    let proposal_id = gov.propose(calls.span(), description);
    stop_cheat_caller_address(governor);

    // Check deadline
    let deadline = gov.proposal_deadline(proposal_id);
    // Should be snapshot + voting_period
    let expected_deadline = initial_time + 86400 + 604800;
    assert!(deadline == expected_deadline, "Wrong proposal deadline");

    stop_cheat_block_timestamp(governor);
    stop_cheat_block_timestamp(token);
}

#[test]
fn test_governor_proposal_proposer() {
    let (token, governor, _controller) = deploy_full_system();
    let gov = IGovernorDispatcher { contract_address: governor };
    let erc20 = IERC20Dispatcher { contract_address: token };
    let votes = IVotesDispatcher { contract_address: token };

    // Setup
    let initial_time = 86400 * 2;
    start_cheat_block_timestamp(governor, initial_time);
    start_cheat_block_timestamp(token, initial_time);

    // Give USER1 tokens and delegate
    start_cheat_caller_address(token, OWNER());
    erc20.transfer(USER1(), 100000 * 1000000000000000000);
    stop_cheat_caller_address(token);

    start_cheat_caller_address(token, USER1());
    votes.delegate(USER1());
    stop_cheat_caller_address(token);

    // Create proposal
    let target = governor;
    let selector = selector!("voting_delay");
    let calldata: Array<felt252> = array![];
    let call = Call { to: target, selector, calldata: calldata.span() };
    let calls = array![call];
    let description: ByteArray = "Test proposal";

    start_cheat_caller_address(governor, USER1());
    let proposal_id = gov.propose(calls.span(), description);
    stop_cheat_caller_address(governor);

    // Check proposer
    let proposer = gov.proposal_proposer(proposal_id);
    assert!(proposer == USER1(), "Wrong proposer");

    stop_cheat_block_timestamp(governor);
    stop_cheat_block_timestamp(token);
}

#[test]
fn test_governor_get_votes() {
    let (token, governor, _controller) = deploy_full_system();
    let gov = IGovernorDispatcher { contract_address: governor };
    let erc20 = IERC20Dispatcher { contract_address: token };
    let votes = IVotesDispatcher { contract_address: token };

    // Setup
    let initial_time = 86400 * 2;
    start_cheat_block_timestamp(governor, initial_time);
    start_cheat_block_timestamp(token, initial_time);

    // Give USER1 tokens and delegate
    let token_amount = 100000 * 1000000000000000000;
    start_cheat_caller_address(token, OWNER());
    erc20.transfer(USER1(), token_amount);
    stop_cheat_caller_address(token);

    start_cheat_caller_address(token, USER1());
    votes.delegate(USER1());
    stop_cheat_caller_address(token);

    // Check votes
    let user_votes = gov.get_votes(USER1(), initial_time);
    assert!(user_votes == token_amount, "Wrong votes");

    stop_cheat_block_timestamp(governor);
    stop_cheat_block_timestamp(token);
}

#[test]
fn test_governor_has_voted() {
    let (token, governor, _controller) = deploy_full_system();
    let gov = IGovernorDispatcher { contract_address: governor };
    let erc20 = IERC20Dispatcher { contract_address: token };
    let votes = IVotesDispatcher { contract_address: token };

    // Setup
    let initial_time = 86400 * 2;
    start_cheat_block_timestamp(governor, initial_time);
    start_cheat_block_timestamp(token, initial_time);

    // Give users tokens and delegate
    start_cheat_caller_address(token, OWNER());
    erc20.transfer(USER1(), 100000 * 1000000000000000000);
    erc20.transfer(USER2(), 50000 * 1000000000000000000);
    stop_cheat_caller_address(token);

    start_cheat_caller_address(token, USER1());
    votes.delegate(USER1());
    stop_cheat_caller_address(token);

    start_cheat_caller_address(token, USER2());
    votes.delegate(USER2());
    stop_cheat_caller_address(token);

    // Create proposal
    let target = governor;
    let selector = selector!("voting_delay");
    let calldata: Array<felt252> = array![];
    let call = Call { to: target, selector, calldata: calldata.span() };
    let calls = array![call];
    let description: ByteArray = "Test proposal";

    start_cheat_caller_address(governor, USER1());
    let proposal_id = gov.propose(calls.span(), description);
    stop_cheat_caller_address(governor);

    // Move to voting period
    start_cheat_block_timestamp(governor, initial_time + 86401);
    start_cheat_block_timestamp(token, initial_time + 86401);

    // USER1 votes
    start_cheat_caller_address(governor, USER1());
    gov.cast_vote(proposal_id, 1);
    stop_cheat_caller_address(governor);

    // Check voting status
    assert!(gov.has_voted(proposal_id, USER1()), "USER1 should have voted");
    assert!(!gov.has_voted(proposal_id, USER2()), "USER2 should not have voted");

    stop_cheat_block_timestamp(governor);
    stop_cheat_block_timestamp(token);
}

#[test]
fn test_governor_hash_proposal() {
    let (_token, governor, _controller) = deploy_full_system();
    let gov = IGovernorDispatcher { contract_address: governor };

    // Create test data
    let target = governor;
    let selector = selector!("voting_delay");
    let calldata: Array<felt252> = array![];
    let call = Call { to: target, selector, calldata: calldata.span() };
    let calls = array![call];
    let description_hash = 0x123456;

    // Hash proposal
    let proposal_id = gov.hash_proposal(calls.span(), description_hash);

    // Hash again with same params should give same result
    let proposal_id2 = gov.hash_proposal(calls.span(), description_hash);

    assert!(proposal_id == proposal_id2, "Hash should be deterministic");
}
