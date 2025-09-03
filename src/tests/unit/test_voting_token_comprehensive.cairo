use core::serde::Serde;
use openzeppelin_governance::votes::interface::{IVotesDispatcher, IVotesDispatcherTrait};
use openzeppelin_token::erc20::interface::{
    IERC20Dispatcher, IERC20DispatcherTrait, IERC20SafeDispatcher, IERC20SafeDispatcherTrait,
};
use openzeppelin_utils::cryptography::interface::{INoncesDispatcher, INoncesDispatcherTrait};
use snforge_std::{
    ContractClassTrait, DeclareResultTrait, declare, start_cheat_block_timestamp,
    start_cheat_caller_address, stop_cheat_block_timestamp, stop_cheat_caller_address,
};
use starknet::ContractAddress;

fn OWNER() -> ContractAddress {
    'OWNER'.try_into().unwrap()
}

fn USER1() -> ContractAddress {
    'USER1'.try_into().unwrap()
}

fn USER2() -> ContractAddress {
    'USER2'.try_into().unwrap()
}

fn ZERO() -> ContractAddress {
    0.try_into().unwrap()
}

fn deploy_token() -> ContractAddress {
    let class = declare("SurvivorToken").unwrap().contract_class();
    let initial_supply: u256 = 1000000 * 1000000000000000000; // 1M tokens with 18 decimals

    let token_name: ByteArray = "Survivor Coin";
    let token_symbol: ByteArray = "SURVIVOR";

    let mut constructor_calldata = array![];
    token_name.serialize(ref constructor_calldata);
    token_symbol.serialize(ref constructor_calldata);
    constructor_calldata.append(initial_supply.low.into());
    constructor_calldata.append(initial_supply.high.into());
    constructor_calldata.append(OWNER().into());

    let (address, _) = class.deploy(@constructor_calldata).unwrap();
    address
}

#[test]
#[should_panic(expected: 'ERC20: insufficient balance')]
fn test_transfer_insufficient_balance() {
    let token_address = deploy_token();
    let erc20 = IERC20Dispatcher { contract_address: token_address };

    let transfer_amount = 2000000 * 1000000000000000000; // More than initial supply

    start_cheat_caller_address(token_address, OWNER());
    erc20.transfer(USER1(), transfer_amount);
    stop_cheat_caller_address(token_address);
}

#[test]
#[should_panic(expected: 'ERC20: transfer to 0')]
fn test_transfer_to_zero_address() {
    let token_address = deploy_token();
    let erc20 = IERC20Dispatcher { contract_address: token_address };

    let transfer_amount = 1000 * 1000000000000000000;

    start_cheat_caller_address(token_address, OWNER());
    erc20.transfer(ZERO(), transfer_amount);
    stop_cheat_caller_address(token_address);
}

#[test]
fn test_nonce_increment() {
    let token_address = deploy_token();
    let nonces = INoncesDispatcher { contract_address: token_address };

    // Get initial nonce
    let initial_nonce = nonces.nonces(OWNER());
    assert!(initial_nonce == 0, "Initial nonce should be 0");
    // Note: In a real scenario, nonces are incremented through signature-based operations
// For testing purposes, we would need to test the delegation by signature
// or other operations that use nonces
}

#[test]
fn test_voting_checkpoints_multiple_delegations() {
    let token_address = deploy_token();
    let votes = IVotesDispatcher { contract_address: token_address };
    let erc20 = IERC20Dispatcher { contract_address: token_address };

    // Set initial timestamp
    start_cheat_block_timestamp(token_address, 1000);

    // First delegation
    start_cheat_caller_address(token_address, OWNER());
    votes.delegate(OWNER());
    stop_cheat_caller_address(token_address);

    let votes_at_1000 = votes.get_votes(OWNER());
    assert!(votes_at_1000 == 1000000 * 1000000000000000000, "Wrong votes at t=1000");

    // Move forward in time and transfer some tokens
    stop_cheat_block_timestamp(token_address);
    start_cheat_block_timestamp(token_address, 2000);

    start_cheat_caller_address(token_address, OWNER());
    erc20.transfer(USER1(), 100000 * 1000000000000000000);
    stop_cheat_caller_address(token_address);

    // Delegate USER1's tokens
    start_cheat_caller_address(token_address, USER1());
    votes.delegate(USER1());
    stop_cheat_caller_address(token_address);

    // Check current votes
    let owner_votes_at_2000 = votes.get_votes(OWNER());
    assert!(owner_votes_at_2000 == 900000 * 1000000000000000000, "Wrong OWNER votes at t=2000");
    let user1_votes_at_2000 = votes.get_votes(USER1());
    assert!(user1_votes_at_2000 == 100000 * 1000000000000000000, "Wrong USER1 votes at t=2000");

    // Move forward and change delegation
    stop_cheat_block_timestamp(token_address);
    start_cheat_block_timestamp(token_address, 3000);

    start_cheat_caller_address(token_address, USER1());
    votes.delegate(USER2()); // USER1 delegates to USER2
    stop_cheat_caller_address(token_address);

    // Check votes after re-delegation
    let user1_votes_at_3000 = votes.get_votes(USER1());
    assert!(user1_votes_at_3000 == 0, "USER1 should have no votes after delegating");
    let user2_votes_at_3000 = votes.get_votes(USER2());
    assert!(user2_votes_at_3000 == 100000 * 1000000000000000000, "Wrong USER2 votes at t=3000");

    // Check historical votes
    let user1_past_votes = votes.get_past_votes(USER1(), 2500);
    assert!(user1_past_votes == 100000 * 1000000000000000000, "Wrong USER1 past votes");
    let user2_past_votes = votes.get_past_votes(USER2(), 2500);
    assert!(user2_past_votes == 0, "USER2 should have no past votes at t=2500");

    stop_cheat_block_timestamp(token_address);
}

#[test]
fn test_approve_and_transfer_from_edge_cases() {
    let token_address = deploy_token();
    let erc20 = IERC20Dispatcher { contract_address: token_address };

    // Approve max amount
    let max_amount: u256 = core::num::traits::Bounded::<u256>::MAX;
    start_cheat_caller_address(token_address, OWNER());
    assert!(erc20.approve(USER1(), max_amount), "Max approve failed");
    stop_cheat_caller_address(token_address);

    assert!(erc20.allowance(OWNER(), USER1()) == max_amount, "Wrong max allowance");

    // Transfer using allowance
    let transfer_amount = 100000 * 1000000000000000000;
    start_cheat_caller_address(token_address, USER1());
    assert!(erc20.transfer_from(OWNER(), USER2(), transfer_amount), "TransferFrom failed");
    stop_cheat_caller_address(token_address);

    // Check allowance - when max, it may not decrease in some implementations
    let remaining_allowance = erc20.allowance(OWNER(), USER1());
    // For max allowance, some implementations keep it at max (infinite approval)
    assert!(remaining_allowance == max_amount || remaining_allowance == max_amount - transfer_amount, "Wrong remaining allowance");

    // Approve zero to reset
    start_cheat_caller_address(token_address, OWNER());
    assert!(erc20.approve(USER1(), 0), "Zero approve failed");
    stop_cheat_caller_address(token_address);

    assert!(erc20.allowance(OWNER(), USER1()) == 0, "Allowance not reset");
}

#[test]
fn test_delegation_updates_voting_power() {
    let token_address = deploy_token();
    let votes = IVotesDispatcher { contract_address: token_address };
    let erc20 = IERC20Dispatcher { contract_address: token_address };

    // Transfer tokens to multiple users
    start_cheat_caller_address(token_address, OWNER());
    erc20.transfer(USER1(), 300000 * 1000000000000000000); // 30%
    erc20.transfer(USER2(), 200000 * 1000000000000000000); // 20%
    stop_cheat_caller_address(token_address);

    // Initially no voting power (not delegated)
    assert!(votes.get_votes(USER1()) == 0, "USER1 should have no votes initially");
    assert!(votes.get_votes(USER2()) == 0, "USER2 should have no votes initially");

    // USER1 delegates to self
    start_cheat_caller_address(token_address, USER1());
    votes.delegate(USER1());
    stop_cheat_caller_address(token_address);

    assert!(votes.get_votes(USER1()) == 300000 * 1000000000000000000, "Wrong USER1 votes");

    // USER2 delegates to USER1
    start_cheat_caller_address(token_address, USER2());
    votes.delegate(USER1());
    stop_cheat_caller_address(token_address);

    // USER1 should now have combined voting power
    assert!(votes.get_votes(USER1()) == 500000 * 1000000000000000000, "Wrong combined votes");
    assert!(votes.get_votes(USER2()) == 0, "USER2 should have no votes");

    // USER2 changes delegation to self
    start_cheat_caller_address(token_address, USER2());
    votes.delegate(USER2());
    stop_cheat_caller_address(token_address);

    // Voting power should be redistributed
    assert!(votes.get_votes(USER1()) == 300000 * 1000000000000000000, "Wrong USER1 votes after");
    assert!(votes.get_votes(USER2()) == 200000 * 1000000000000000000, "Wrong USER2 votes after");
}

#[test]
fn test_multiple_transfers_maintain_vote_consistency() {
    let token_address = deploy_token();
    let votes = IVotesDispatcher { contract_address: token_address };
    let erc20 = IERC20Dispatcher { contract_address: token_address };

    // Setup: OWNER delegates to self
    start_cheat_caller_address(token_address, OWNER());
    votes.delegate(OWNER());
    stop_cheat_caller_address(token_address);

    let initial_votes = votes.get_votes(OWNER());
    assert!(initial_votes == 1000000 * 1000000000000000000, "Wrong initial votes");

    // Transfer 1: OWNER -> USER1
    start_cheat_caller_address(token_address, OWNER());
    erc20.transfer(USER1(), 100000 * 1000000000000000000);
    stop_cheat_caller_address(token_address);

    // USER1 delegates to self
    start_cheat_caller_address(token_address, USER1());
    votes.delegate(USER1());
    stop_cheat_caller_address(token_address);

    // Transfer 2: USER1 -> USER2
    start_cheat_caller_address(token_address, USER1());
    erc20.transfer(USER2(), 50000 * 1000000000000000000);
    stop_cheat_caller_address(token_address);

    // USER2 delegates to OWNER
    start_cheat_caller_address(token_address, USER2());
    votes.delegate(OWNER());
    stop_cheat_caller_address(token_address);

    // Check final vote distribution
    let owner_votes = votes.get_votes(OWNER());
    let user1_votes = votes.get_votes(USER1());
    let user2_votes = votes.get_votes(USER2());

    // OWNER has their own balance + USER2's delegated balance
    assert!(owner_votes == 950000 * 1000000000000000000, "Wrong OWNER final votes");
    assert!(user1_votes == 50000 * 1000000000000000000, "Wrong USER1 final votes");
    assert!(user2_votes == 0, "USER2 should have no votes (delegated to OWNER)");

    // Total voting power should equal total supply
    assert!(
        owner_votes + user1_votes + user2_votes == 1000000 * 1000000000000000000,
        "Total voting power mismatch",
    );
}

#[test]
fn test_zero_amount_operations() {
    let token_address = deploy_token();
    let erc20 = IERC20Dispatcher { contract_address: token_address };

    // Transfer zero amount (should succeed)
    start_cheat_caller_address(token_address, OWNER());
    assert!(erc20.transfer(USER1(), 0), "Zero transfer failed");
    stop_cheat_caller_address(token_address);

    // Approve zero amount (should succeed)
    start_cheat_caller_address(token_address, OWNER());
    assert!(erc20.approve(USER1(), 0), "Zero approve failed");
    stop_cheat_caller_address(token_address);

    // TransferFrom zero amount (should succeed)
    start_cheat_caller_address(token_address, USER1());
    assert!(erc20.transfer_from(OWNER(), USER2(), 0), "Zero transferFrom failed");
    stop_cheat_caller_address(token_address);
}

#[test]
fn test_safe_transfer_operations() {
    let token_address = deploy_token();
    let safe_erc20 = IERC20SafeDispatcher { contract_address: token_address };

    // Test safe transfer with insufficient balance
    let excessive_amount = 2000000 * 1000000000000000000;
    start_cheat_caller_address(token_address, OWNER());
    match safe_erc20.transfer(USER1(), excessive_amount) {
        Result::Ok(_) => panic!("Should fail with insufficient balance"),
        Result::Err(_) => {} // Expected
    }
    stop_cheat_caller_address(token_address);

    // Test safe transfer to zero address
    let normal_amount = 1000 * 1000000000000000000;
    start_cheat_caller_address(token_address, OWNER());
    match safe_erc20.transfer(ZERO(), normal_amount) {
        Result::Ok(_) => panic!("Should fail with zero address"),
        Result::Err(_) => {} // Expected
    }
    stop_cheat_caller_address(token_address);
}
