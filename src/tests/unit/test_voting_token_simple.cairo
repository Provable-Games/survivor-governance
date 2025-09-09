use core::serde::Serde;
use openzeppelin_governance::votes::interface::{IVotesDispatcher, IVotesDispatcherTrait};
use openzeppelin_token::erc20::interface::{
    IERC20Dispatcher, IERC20DispatcherTrait, IERC20MetadataDispatcher,
    IERC20MetadataDispatcherTrait,
};
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

fn deploy_token() -> ContractAddress {
    let class = declare("SurvivorToken").unwrap().contract_class();
    let initial_supply: u256 = 1000000 * 1000000000000000000; // 1M tokens with 18 decimals

    let mut constructor_calldata = array![];
    // initial_supply
    constructor_calldata.append(initial_supply.low.into());
    constructor_calldata.append(initial_supply.high.into());
    // recipient
    constructor_calldata.append(OWNER().into());

    let (address, _) = class.deploy(@constructor_calldata).unwrap();
    address
}

#[test]
fn test_token_deployment() {
    let token_address = deploy_token();
    let token = IERC20Dispatcher { contract_address: token_address };
    let token_metadata = IERC20MetadataDispatcher { contract_address: token_address };

    assert!(token_metadata.name() == "Survivor Token", "Wrong name");
    assert!(token_metadata.symbol() == "SURVIVOR", "Wrong symbol");
    assert!(token_metadata.decimals() == 18, "Wrong decimals");
    assert!(token.total_supply() == 1000000 * 1000000000000000000, "Wrong total supply");
    assert!(token.balance_of(OWNER()) == 1000000 * 1000000000000000000, "Wrong initial balance");
}

#[test]
fn test_token_transfer() {
    let token_address = deploy_token();
    let erc20 = IERC20Dispatcher { contract_address: token_address };

    let transfer_amount = 1000 * 1000000000000000000;

    start_cheat_caller_address(token_address, OWNER());
    assert!(erc20.transfer(USER1(), transfer_amount), "Transfer failed");
    stop_cheat_caller_address(token_address);

    assert!(erc20.balance_of(USER1()) == transfer_amount, "Wrong USER1 balance");
    assert!(erc20.balance_of(OWNER()) == 999000 * 1000000000000000000, "Wrong OWNER balance");
}

#[test]
fn test_token_approve_and_transfer_from() {
    let token_address = deploy_token();
    let erc20 = IERC20Dispatcher { contract_address: token_address };

    let approve_amount = 5000 * 1000000000000000000;

    start_cheat_caller_address(token_address, OWNER());
    assert!(erc20.approve(USER1(), approve_amount), "Approve failed");
    stop_cheat_caller_address(token_address);

    assert!(erc20.allowance(OWNER(), USER1()) == approve_amount, "Wrong allowance");

    let transfer_amount = 3000 * 1000000000000000000;

    start_cheat_caller_address(token_address, USER1());
    assert!(erc20.transfer_from(OWNER(), USER2(), transfer_amount), "TransferFrom failed");
    stop_cheat_caller_address(token_address);

    assert!(erc20.balance_of(USER2()) == transfer_amount, "Wrong USER2 balance");
    assert!(erc20.balance_of(OWNER()) == 997000 * 1000000000000000000, "Wrong OWNER balance");
    assert!(
        erc20.allowance(OWNER(), USER1()) == 2000 * 1000000000000000000,
        "Wrong remaining allowance",
    );
}

#[test]
fn test_voting_power_delegation() {
    let token_address = deploy_token();
    let votes = IVotesDispatcher { contract_address: token_address };
    let erc20 = IERC20Dispatcher { contract_address: token_address };

    // Initially no voting power (tokens not delegated)
    assert!(votes.get_votes(OWNER()) == 0, "Should have no votes initially");

    // Delegate to self
    start_cheat_caller_address(token_address, OWNER());
    votes.delegate(OWNER());
    stop_cheat_caller_address(token_address);

    // Now should have voting power equal to balance
    assert!(votes.get_votes(OWNER()) == 1000000 * 1000000000000000000, "Wrong voting power");

    // Transfer some tokens
    start_cheat_caller_address(token_address, OWNER());
    erc20.transfer(USER1(), 100000 * 1000000000000000000);
    stop_cheat_caller_address(token_address);

    // Voting power should decrease
    assert!(
        votes.get_votes(OWNER()) == 900000 * 1000000000000000000, "Wrong voting power after xfer",
    );

    // USER1 delegates to themselves
    start_cheat_caller_address(token_address, USER1());
    votes.delegate(USER1());
    stop_cheat_caller_address(token_address);

    assert!(votes.get_votes(USER1()) == 100000 * 1000000000000000000, "Wrong USER1 voting power");
}

#[test]
fn test_voting_power_delegation_to_others() {
    let token_address = deploy_token();
    let votes = IVotesDispatcher { contract_address: token_address };
    let erc20 = IERC20Dispatcher { contract_address: token_address };

    // Transfer tokens to USER1
    start_cheat_caller_address(token_address, OWNER());
    erc20.transfer(USER1(), 200000 * 1000000000000000000);
    stop_cheat_caller_address(token_address);

    // USER1 delegates to USER2
    start_cheat_caller_address(token_address, USER1());
    votes.delegate(USER2());
    stop_cheat_caller_address(token_address);

    // USER2 should have USER1's voting power
    assert!(
        votes.get_votes(USER2()) == 200000 * 1000000000000000000, "Wrong delegated voting power",
    );
    assert!(votes.get_votes(USER1()) == 0, "USER1 should have no votes");

    // Check delegation is recorded
    assert!(votes.delegates(USER1()) == USER2(), "Wrong delegate");
}

#[test]
fn test_voting_checkpoints() {
    let token_address = deploy_token();
    let votes = IVotesDispatcher { contract_address: token_address };
    let erc20 = IERC20Dispatcher { contract_address: token_address };

    // Set initial timestamp
    start_cheat_block_timestamp(token_address, 1000);

    // Delegate at timestamp 1000
    start_cheat_caller_address(token_address, OWNER());
    votes.delegate(OWNER());
    stop_cheat_caller_address(token_address);

    let votes_at_1000 = votes.get_votes(OWNER());

    // Move forward in time
    stop_cheat_block_timestamp(token_address);
    start_cheat_block_timestamp(token_address, 2000);

    // Transfer some tokens
    start_cheat_caller_address(token_address, OWNER());
    erc20.transfer(USER1(), 100000 * 1000000000000000000);
    stop_cheat_caller_address(token_address);

    // Check current votes
    let current_votes = votes.get_votes(OWNER());
    assert!(current_votes == 900000 * 1000000000000000000, "Wrong current votes");

    // Check historical votes
    let past_votes = votes.get_past_votes(OWNER(), 1500);
    assert!(past_votes == votes_at_1000, "Wrong historical votes");

    stop_cheat_block_timestamp(token_address);
}
