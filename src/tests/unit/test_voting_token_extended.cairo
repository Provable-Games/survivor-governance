use core::serde::Serde;
use openzeppelin_governance::votes::interface::{IVotesDispatcher, IVotesDispatcherTrait};
use openzeppelin_token::erc20::interface::{
    IERC20Dispatcher, IERC20DispatcherTrait, IERC20MetadataDispatcher,
    IERC20MetadataDispatcherTrait,
};
// use openzeppelin_utils::cryptography::nonces::interface::{INoncesDispatcher,
// INoncesDispatcherTrait};
use snforge_std::{
    ContractClassTrait, DeclareResultTrait, declare, start_cheat_block_timestamp,
    start_cheat_caller_address, stop_cheat_block_timestamp, stop_cheat_caller_address,
};
use starknet::ContractAddress;
// use survivor_governance::voting_token::VotingToken;

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

const INITIAL_SUPPLY: u256 = 1000000000000000000000000; // 1M tokens with 18 decimals

fn deploy_voting_token() -> ContractAddress {
    let class = declare("SurvivorToken").unwrap().contract_class();

    // Use string literals that will be auto-converted to ByteArray
    let token_name: ByteArray = "Survivor Coin";
    let token_symbol: ByteArray = "SURVIVOR";

    let mut calldata = array![];
    // Serialize ByteArray for token_name
    token_name.serialize(ref calldata);
    // Serialize ByteArray for token_symbol
    token_symbol.serialize(ref calldata);
    // initial_supply
    calldata.append(INITIAL_SUPPLY.low.into());
    calldata.append(INITIAL_SUPPLY.high.into());
    // recipient
    calldata.append(OWNER().into());

    let (address, _) = class.deploy(@calldata).unwrap();
    address
}

// VT-001: Test deployment parameters
#[test]
fn test_deployment_parameters() {
    let token_address = deploy_voting_token();
    let token = IERC20Dispatcher { contract_address: token_address };
    let metadata = IERC20MetadataDispatcher { contract_address: token_address };

    // Check name and symbol
    assert!(metadata.name() == "Survivor Coin", "Wrong token name");
    assert!(metadata.symbol() == "SURVIVOR", "Wrong token symbol");

    // Check decimals
    assert!(metadata.decimals() == 18, "Wrong decimals");

    // Check total supply
    assert!(token.total_supply() == INITIAL_SUPPLY, "Wrong total supply");

    // Check initial balance
    assert!(token.balance_of(OWNER()) == INITIAL_SUPPLY, "Wrong initial balance");
}

// VT-002: Test basic transfer
#[test]
fn test_transfer_basic() {
    let token_address = deploy_voting_token();
    let token = IERC20Dispatcher { contract_address: token_address };

    let transfer_amount: u256 = 1000000000000000000000; // 1000 tokens

    let initial_owner_balance = token.balance_of(OWNER());
    let initial_user1_balance = token.balance_of(USER1());

    // Perform transfer
    start_cheat_caller_address(token_address, OWNER());
    assert!(token.transfer(USER1(), transfer_amount), "Transfer failed");
    stop_cheat_caller_address(token_address);

    // Check balances updated correctly
    assert!(
        token.balance_of(OWNER()) == initial_owner_balance - transfer_amount,
        "Wrong owner balance after transfer",
    );
    assert!(
        token.balance_of(USER1()) == initial_user1_balance + transfer_amount,
        "Wrong recipient balance after transfer",
    );
}

// VT-003: Test transfer with insufficient balance
#[test]
#[should_panic(expected: ('ERC20: insufficient balance',))]
fn test_transfer_insufficient() {
    let token_address = deploy_voting_token();
    let token = IERC20Dispatcher { contract_address: token_address };

    let excessive_amount = INITIAL_SUPPLY + 1;

    start_cheat_caller_address(token_address, OWNER());
    token.transfer(USER1(), excessive_amount);
    stop_cheat_caller_address(token_address);
}

// VT-004: Test transfer to zero address
#[test]
#[should_panic(expected: ('ERC20: transfer to 0',))]
fn test_transfer_to_zero() {
    let token_address = deploy_voting_token();
    let token = IERC20Dispatcher { contract_address: token_address };

    let transfer_amount: u256 = 1000000000000000000000;

    start_cheat_caller_address(token_address, OWNER());
    token.transfer(ZERO(), transfer_amount);
    stop_cheat_caller_address(token_address);
}

// VT-005: Test approve and allowance
#[test]
fn test_approve_allowance() {
    let token_address = deploy_voting_token();
    let token = IERC20Dispatcher { contract_address: token_address };

    let approve_amount: u256 = 5000000000000000000000;

    // Initial allowance should be zero
    assert!(token.allowance(OWNER(), USER1()) == 0, "Initial allowance not zero");

    // Approve spending
    start_cheat_caller_address(token_address, OWNER());
    assert!(token.approve(USER1(), approve_amount), "Approve failed");
    stop_cheat_caller_address(token_address);

    // Check allowance set correctly
    assert!(token.allowance(OWNER(), USER1()) == approve_amount, "Wrong allowance");
}

// VT-006: Test transfer_from using allowance
#[test]
fn test_transfer_from() {
    let token_address = deploy_voting_token();
    let token = IERC20Dispatcher { contract_address: token_address };

    let approve_amount: u256 = 5000000000000000000000;
    let transfer_amount: u256 = 3000000000000000000000;

    // Setup: Owner approves USER1
    start_cheat_caller_address(token_address, OWNER());
    token.approve(USER1(), approve_amount);
    stop_cheat_caller_address(token_address);

    let initial_owner_balance = token.balance_of(OWNER());
    let initial_user2_balance = token.balance_of(USER2());

    // USER1 transfers from OWNER to USER2
    start_cheat_caller_address(token_address, USER1());
    assert!(token.transfer_from(OWNER(), USER2(), transfer_amount), "TransferFrom failed");
    stop_cheat_caller_address(token_address);

    // Check balances
    assert!(
        token.balance_of(OWNER()) == initial_owner_balance - transfer_amount, "Wrong owner balance",
    );
    assert!(
        token.balance_of(USER2()) == initial_user2_balance + transfer_amount,
        "Wrong recipient balance",
    );

    // Check remaining allowance
    assert!(
        token.allowance(OWNER(), USER1()) == approve_amount - transfer_amount,
        "Wrong remaining allowance",
    );
}

// VT-007: Test delegate to self
#[test]
fn test_delegate_self() {
    let token_address = deploy_voting_token();
    let votes = IVotesDispatcher { contract_address: token_address };
    let token = IERC20Dispatcher { contract_address: token_address };

    // Initially no voting power (not delegated)
    assert!(votes.get_votes(OWNER()) == 0, "Should have no votes initially");

    // Delegate to self
    start_cheat_caller_address(token_address, OWNER());
    votes.delegate(OWNER());
    stop_cheat_caller_address(token_address);

    // Now should have voting power equal to balance
    assert!(votes.get_votes(OWNER()) == token.balance_of(OWNER()), "Wrong voting power");

    // Check delegation is recorded
    assert!(votes.delegates(OWNER()) == OWNER(), "Wrong delegate");
}

// VT-008: Test delegate to another address
#[test]
fn test_delegate_other() {
    let token_address = deploy_voting_token();
    let votes = IVotesDispatcher { contract_address: token_address };
    let token = IERC20Dispatcher { contract_address: token_address };

    // Transfer tokens to USER1
    let transfer_amount: u256 = 200000000000000000000000;
    start_cheat_caller_address(token_address, OWNER());
    token.transfer(USER1(), transfer_amount);
    stop_cheat_caller_address(token_address);

    // USER1 delegates to USER2
    start_cheat_caller_address(token_address, USER1());
    votes.delegate(USER2());
    stop_cheat_caller_address(token_address);

    // USER2 should have USER1's voting power
    assert!(votes.get_votes(USER2()) == transfer_amount, "Wrong delegated voting power");
    assert!(votes.get_votes(USER1()) == 0, "Delegator should have no votes");

    // Check delegation is recorded
    assert!(votes.delegates(USER1()) == USER2(), "Wrong delegate");
}

// VT-009: Test re-delegation
#[test]
fn test_redelegate() {
    let token_address = deploy_voting_token();
    let votes = IVotesDispatcher { contract_address: token_address };
    let token = IERC20Dispatcher { contract_address: token_address };

    // Transfer tokens to USER1
    let transfer_amount: u256 = 300000000000000000000000;
    start_cheat_caller_address(token_address, OWNER());
    token.transfer(USER1(), transfer_amount);
    stop_cheat_caller_address(token_address);

    // USER1 delegates to USER2
    start_cheat_caller_address(token_address, USER1());
    votes.delegate(USER2());

    // Verify initial delegation
    assert!(votes.get_votes(USER2()) == transfer_amount, "Initial delegation failed");
    assert!(votes.get_votes(USER3()) == 0, "USER3 should have no votes");

    // Re-delegate to USER3
    votes.delegate(USER3());
    stop_cheat_caller_address(token_address);

    // Verify voting power moved
    assert!(votes.get_votes(USER2()) == 0, "USER2 should have no votes");
    assert!(votes.get_votes(USER3()) == transfer_amount, "Re-delegation failed");
    assert!(votes.delegates(USER1()) == USER3(), "Wrong delegate after re-delegation");
}

// VT-010: Test votes after transfer
#[test]
fn test_votes_after_transfer() {
    let token_address = deploy_voting_token();
    let votes = IVotesDispatcher { contract_address: token_address };
    let token = IERC20Dispatcher { contract_address: token_address };

    // Setup: OWNER delegates to self, USER1 delegates to self
    start_cheat_caller_address(token_address, OWNER());
    votes.delegate(OWNER());
    stop_cheat_caller_address(token_address);

    // Transfer tokens to USER1
    let transfer_amount: u256 = 100000000000000000000000;
    start_cheat_caller_address(token_address, OWNER());
    token.transfer(USER1(), transfer_amount);
    stop_cheat_caller_address(token_address);

    // USER1 delegates to self
    start_cheat_caller_address(token_address, USER1());
    votes.delegate(USER1());
    stop_cheat_caller_address(token_address);

    // Check voting power updated correctly
    assert!(
        votes.get_votes(OWNER()) == INITIAL_SUPPLY - transfer_amount, "Wrong OWNER voting power",
    );
    assert!(votes.get_votes(USER1()) == transfer_amount, "Wrong USER1 voting power");

    // Transfer more tokens
    let second_transfer: u256 = 50000000000000000000000;
    start_cheat_caller_address(token_address, OWNER());
    token.transfer(USER1(), second_transfer);
    stop_cheat_caller_address(token_address);

    // Check voting power updated again
    assert!(
        votes.get_votes(OWNER()) == INITIAL_SUPPLY - transfer_amount - second_transfer,
        "Wrong OWNER voting power after second transfer",
    );
    assert!(
        votes.get_votes(USER1()) == transfer_amount + second_transfer,
        "Wrong USER1 voting power after second transfer",
    );
}

// VT-011: Test get_past_votes
#[test]
fn test_get_past_votes() {
    let token_address = deploy_voting_token();
    let votes = IVotesDispatcher { contract_address: token_address };
    let token = IERC20Dispatcher { contract_address: token_address };

    // Set initial timestamp
    let initial_time: u64 = 1000;
    start_cheat_block_timestamp(token_address, initial_time);

    // OWNER delegates to self at timestamp 1000
    start_cheat_caller_address(token_address, OWNER());
    votes.delegate(OWNER());
    stop_cheat_caller_address(token_address);

    let votes_at_1000 = votes.get_votes(OWNER());

    // Move forward in time
    stop_cheat_block_timestamp(token_address);
    let later_time: u64 = 2000;
    start_cheat_block_timestamp(token_address, later_time);

    // Transfer some tokens
    let transfer_amount: u256 = 100000000000000000000000;
    start_cheat_caller_address(token_address, OWNER());
    token.transfer(USER1(), transfer_amount);
    stop_cheat_caller_address(token_address);

    // Check current votes
    let current_votes = votes.get_votes(OWNER());
    assert!(current_votes == INITIAL_SUPPLY - transfer_amount, "Wrong current votes");

    // Check historical votes (should be unchanged)
    let past_votes = votes.get_past_votes(OWNER(), initial_time + 500);
    assert!(past_votes == votes_at_1000, "Wrong historical votes");

    stop_cheat_block_timestamp(token_address);
}

// VT-012: Test nonce increment
// #[test]
// fn test_nonce_increment() {
//     let token_address = deploy_voting_token();
//     // Commented out as INoncesDispatcher is not available
//     // let nonces = INoncesDispatcher { contract_address: token_address };
//
//     // Initial nonce should be 0
//     // let initial_nonce = nonces.nonces(OWNER());
//     // assert!(initial_nonce == 0, "Initial nonce not zero");
//
//     // Note: Actual nonce increment would happen through delegation by signature
//     // which requires more complex setup with signature verification
//     // For this test, we verify the nonce interface is available
// }

// VT-013: Test voting checkpoints
#[test]
fn test_voting_checkpoints() {
    let token_address = deploy_voting_token();
    let votes = IVotesDispatcher { contract_address: token_address };
    let token = IERC20Dispatcher { contract_address: token_address };

    // Set up timestamps for checkpoints
    let time1: u64 = 1000;
    let time2: u64 = 2000;
    let time3: u64 = 3000;

    // Checkpoint 1: Initial delegation
    start_cheat_block_timestamp(token_address, time1);
    start_cheat_caller_address(token_address, OWNER());
    votes.delegate(OWNER());
    let checkpoint1_votes = votes.get_votes(OWNER());
    stop_cheat_caller_address(token_address);
    stop_cheat_block_timestamp(token_address);

    // Checkpoint 2: After first transfer
    start_cheat_block_timestamp(token_address, time2);
    start_cheat_caller_address(token_address, OWNER());
    token.transfer(USER1(), 100000000000000000000000);
    let checkpoint2_votes = votes.get_votes(OWNER());
    stop_cheat_caller_address(token_address);
    stop_cheat_block_timestamp(token_address);

    // Checkpoint 3: After second transfer
    start_cheat_block_timestamp(token_address, time3);
    start_cheat_caller_address(token_address, OWNER());
    token.transfer(USER2(), 50000000000000000000000);
    let checkpoint3_votes = votes.get_votes(OWNER());
    stop_cheat_caller_address(token_address);
    stop_cheat_block_timestamp(token_address);

    // Verify checkpoints are recorded correctly
    assert!(checkpoint1_votes == INITIAL_SUPPLY, "Wrong checkpoint 1");
    assert!(checkpoint2_votes == INITIAL_SUPPLY - 100000000000000000000000, "Wrong checkpoint 2");
    assert!(checkpoint3_votes == INITIAL_SUPPLY - 150000000000000000000000, "Wrong checkpoint 3");

    // Verify historical queries work
    let query_time: u64 = 4000;
    start_cheat_block_timestamp(token_address, query_time);

    assert!(votes.get_past_votes(OWNER(), time1 + 100) == checkpoint1_votes, "Wrong past votes 1");
    assert!(votes.get_past_votes(OWNER(), time2 + 100) == checkpoint2_votes, "Wrong past votes 2");
    assert!(votes.get_past_votes(OWNER(), time3 + 100) == checkpoint3_votes, "Wrong past votes 3");

    stop_cheat_block_timestamp(token_address);
}
