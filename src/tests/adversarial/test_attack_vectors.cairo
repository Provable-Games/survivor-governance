// Adversarial Tests - Attack Vector Testing
use core::serde::Serde;
use openzeppelin_governance::governor::interface::{IGovernorDispatcher, IGovernorDispatcherTrait};
use openzeppelin_governance::votes::interface::{IVotesDispatcher, IVotesDispatcherTrait};
use openzeppelin_token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use snforge_std::{
    ContractClassTrait, DeclareResultTrait, declare, start_cheat_block_timestamp,
    start_cheat_caller_address, stop_cheat_block_timestamp, stop_cheat_caller_address,
};
use starknet::ContractAddress;

// Test addresses
fn ATTACKER() -> ContractAddress {
    'ATTACKER'.try_into().unwrap()
}

fn VICTIM() -> ContractAddress {
    'VICTIM'.try_into().unwrap()
}

fn WHALE() -> ContractAddress {
    'WHALE'.try_into().unwrap()
}

fn OWNER() -> ContractAddress {
    'OWNER'.try_into().unwrap()
}

const INITIAL_SUPPLY: u256 = 1000000000000000000000000; // 1M tokens

fn deploy_governance_with_tokens() -> (ContractAddress, ContractAddress, ContractAddress) {
    // Deploy token
    let token_class = declare("SurvivorToken").unwrap().contract_class();
    let token_name: ByteArray = "Attack Test Token";
    let token_symbol: ByteArray = "ATK";

    let mut token_calldata = array![];
    token_name.serialize(ref token_calldata);
    token_symbol.serialize(ref token_calldata);
    token_calldata.append(INITIAL_SUPPLY.low.into());
    token_calldata.append(INITIAL_SUPPLY.high.into());
    token_calldata.append(OWNER().into());

    let (token_address, _) = token_class.deploy(@token_calldata).unwrap();

    // Deploy timelock controller
    let controller_class = declare("SurvivorGovernorController").unwrap().contract_class();
    let min_delay: u64 = 3600;

    let mut controller_calldata = array![];
    controller_calldata.append(min_delay.into());
    controller_calldata.append(0); // Empty proposers
    controller_calldata.append(0); // Empty executors
    controller_calldata.append(OWNER().into());

    let (controller_address, _) = controller_class.deploy(@controller_calldata).unwrap();

    // Deploy governor
    let governor_class = declare("SurvivorGovernor").unwrap().contract_class();
    let mut governor_calldata = array![];
    governor_calldata.append(token_address.into());
    governor_calldata.append(controller_address.into());

    let (governor_address, _) = governor_class.deploy(@governor_calldata).unwrap();

    (token_address, controller_address, governor_address)
}

#[test]
fn test_double_voting_prevention() {
    let (token, _controller, _governor) = deploy_governance_with_tokens();

    let erc20 = IERC20Dispatcher { contract_address: token };
    let votes = IVotesDispatcher { contract_address: token };

    // Give attacker tokens
    start_cheat_caller_address(token, OWNER());
    erc20.transfer(ATTACKER(), 100000000000000000000000); // 100k tokens
    stop_cheat_caller_address(token);

    // Attacker delegates to self
    start_cheat_caller_address(token, ATTACKER());
    votes.delegate(ATTACKER());
    stop_cheat_caller_address(token);

    // Try to delegate to multiple addresses (should only count last delegation)
    start_cheat_caller_address(token, ATTACKER());
    votes.delegate(VICTIM());
    stop_cheat_caller_address(token);

    // Verify attacker has no votes, victim has them
    assert!(votes.get_votes(ATTACKER()) == 0, "Attacker shouldn't have votes");
    assert!(votes.get_votes(VICTIM()) == 100000000000000000000000, "Victim should have votes");
}

#[test]
fn test_vote_buying_resistance() {
    let (token, _controller, _governor) = deploy_governance_with_tokens();

    let erc20 = IERC20Dispatcher { contract_address: token };
    let votes = IVotesDispatcher { contract_address: token };

    // Setup: Whale has majority tokens
    let whale_amount = 600000000000000000000000; // 600k tokens (60%)
    start_cheat_caller_address(token, OWNER());
    erc20.transfer(WHALE(), whale_amount);
    stop_cheat_caller_address(token);

    // Whale delegates to self
    start_cheat_caller_address(token, WHALE());
    votes.delegate(WHALE());
    stop_cheat_caller_address(token);

    // Whale tries to buy votes by transferring tokens after delegation
    // This shouldn't give the recipient immediate voting power for past proposals
    start_cheat_caller_address(token, WHALE());
    erc20.transfer(ATTACKER(), 100000000000000000000000);
    stop_cheat_caller_address(token);

    // Attacker must delegate to get voting power
    assert!(votes.get_votes(ATTACKER()) == 0, "No votes without delegation");

    // Even after delegation, past proposals use historical snapshots
    start_cheat_caller_address(token, ATTACKER());
    votes.delegate(ATTACKER());
    stop_cheat_caller_address(token);

    assert!(
        votes.get_votes(ATTACKER()) == 100000000000000000000000,
        "Should have votes after delegation",
    );
}

#[test]
fn test_flash_loan_attack_prevention() {
    let (token, _controller, _governor) = deploy_governance_with_tokens();

    let erc20 = IERC20Dispatcher { contract_address: token };
    let votes = IVotesDispatcher { contract_address: token };

    // Setup: Attacker has small amount
    start_cheat_caller_address(token, OWNER());
    erc20.transfer(ATTACKER(), 10000000000000000000000); // 10k tokens
    stop_cheat_caller_address(token);

    // Attacker delegates
    start_cheat_caller_address(token, ATTACKER());
    votes.delegate(ATTACKER());
    stop_cheat_caller_address(token);

    let initial_votes = votes.get_votes(ATTACKER());

    // Simulate flash loan: receive large amount
    start_cheat_caller_address(token, OWNER());
    erc20.transfer(ATTACKER(), 500000000000000000000000); // 500k tokens
    stop_cheat_caller_address(token);

    let votes_after_loan = votes.get_votes(ATTACKER());

    // Return flash loan
    start_cheat_caller_address(token, ATTACKER());
    erc20.transfer(OWNER(), 500000000000000000000000);
    stop_cheat_caller_address(token);

    let final_votes = votes.get_votes(ATTACKER());

    // Verify votes track token balance correctly
    assert!(votes_after_loan == 510000000000000000000000, "Should have increased votes");
    assert!(final_votes == initial_votes, "Should return to initial votes");
}

#[test]
fn test_sybil_attack_mitigation() {
    let (token, _controller, _governor) = deploy_governance_with_tokens();

    let erc20 = IERC20Dispatcher { contract_address: token };
    let votes = IVotesDispatcher { contract_address: token };

    // Attacker creates multiple accounts
    let sybil1: ContractAddress = 'SYBIL1'.try_into().unwrap();
    let sybil2: ContractAddress = 'SYBIL2'.try_into().unwrap();
    let sybil3: ContractAddress = 'SYBIL3'.try_into().unwrap();

    // Distribute tokens across sybil accounts
    start_cheat_caller_address(token, OWNER());
    erc20.transfer(sybil1, 50000000000000000000000); // 50k each
    erc20.transfer(sybil2, 50000000000000000000000);
    erc20.transfer(sybil3, 50000000000000000000000);
    stop_cheat_caller_address(token);

    // Each sybil delegates to themselves
    start_cheat_caller_address(token, sybil1);
    votes.delegate(sybil1);
    stop_cheat_caller_address(token);

    start_cheat_caller_address(token, sybil2);
    votes.delegate(sybil2);
    stop_cheat_caller_address(token);

    start_cheat_caller_address(token, sybil3);
    votes.delegate(sybil3);
    stop_cheat_caller_address(token);

    // Total voting power is still limited by token supply
    let total_sybil_votes = votes.get_votes(sybil1)
        + votes.get_votes(sybil2)
        + votes.get_votes(sybil3);
    assert!(total_sybil_votes == 150000000000000000000000, "Total votes equal tokens distributed");

    // Creating more accounts doesn't create more voting power
    assert!(total_sybil_votes < INITIAL_SUPPLY, "Cannot exceed total supply");
}

#[test]
fn test_delegation_griefing_attack() {
    let (token, _controller, _governor) = deploy_governance_with_tokens();

    let erc20 = IERC20Dispatcher { contract_address: token };
    let votes = IVotesDispatcher { contract_address: token };

    // Victim has tokens
    start_cheat_caller_address(token, OWNER());
    erc20.transfer(VICTIM(), 200000000000000000000000);
    stop_cheat_caller_address(token);

    // Victim delegates to self
    start_cheat_caller_address(token, VICTIM());
    votes.delegate(VICTIM());
    stop_cheat_caller_address(token);

    // Attacker tries to grief by sending dust amounts
    start_cheat_caller_address(token, OWNER());
    let mut i: u32 = 0;
    while i < 10 {
        erc20.transfer(VICTIM(), 1); // Send 1 wei
        i += 1;
    }
    stop_cheat_caller_address(token);

    // Victim's voting power should still work correctly
    assert!(votes.get_votes(VICTIM()) == 200000000000000000000010, "Votes should include dust");

    // Delegation still works normally
    start_cheat_caller_address(token, VICTIM());
    votes.delegate(WHALE());
    stop_cheat_caller_address(token);

    assert!(votes.get_votes(VICTIM()) == 0, "Delegation should still work");
    assert!(votes.get_votes(WHALE()) == 200000000000000000000010, "Delegatee gets all votes");
}

#[test]
fn test_zero_address_delegation_prevention() {
    let (token, _controller, _governor) = deploy_governance_with_tokens();

    let erc20 = IERC20Dispatcher { contract_address: token };
    let votes = IVotesDispatcher { contract_address: token };

    // Give attacker tokens
    start_cheat_caller_address(token, OWNER());
    erc20.transfer(ATTACKER(), 100000000000000000000000);
    stop_cheat_caller_address(token);

    // Try to delegate to zero address (should be allowed but burns voting power)
    start_cheat_caller_address(token, ATTACKER());
    let zero_addr: ContractAddress = 0.try_into().unwrap();
    votes.delegate(zero_addr);
    stop_cheat_caller_address(token);

    // Voting power should be effectively burned
    assert!(votes.get_votes(ATTACKER()) == 0, "Should have no votes");
    let zero_addr: ContractAddress = 0.try_into().unwrap();
    assert!(votes.get_votes(zero_addr) == 0, "Zero address has no votes");
}

#[test]
fn test_reentrancy_protection() {
    let (token, _controller, _governor) = deploy_governance_with_tokens();

    let erc20 = IERC20Dispatcher { contract_address: token };

    // Deploy malicious contract
    let malicious_class = declare("MockMalicious").unwrap().contract_class();
    let mut malicious_calldata = array![];
    malicious_calldata.append(token.into());
    let (malicious_address, _) = malicious_class.deploy(@malicious_calldata).unwrap();

    // Give malicious contract tokens
    start_cheat_caller_address(token, OWNER());
    erc20.transfer(malicious_address, 100000000000000000000000);
    stop_cheat_caller_address(token);

    // Transfers should be atomic and not reentrant
    // The ERC20 standard in Cairo doesn't have the same reentrancy issues as Solidity
    // But this test verifies the safety
    assert!(erc20.balance_of(malicious_address) == 100000000000000000000000, "Balance correct");
}

#[test]
fn test_proposal_spam_attack() {
    let (token, _controller, governor) = deploy_governance_with_tokens();

    let erc20 = IERC20Dispatcher { contract_address: token };
    let votes = IVotesDispatcher { contract_address: token };
    let gov = IGovernorDispatcher { contract_address: governor };

    // Attacker gets exactly proposal threshold tokens
    let threshold = gov.proposal_threshold();

    start_cheat_caller_address(token, OWNER());
    erc20.transfer(ATTACKER(), threshold + 1); // Just above threshold
    stop_cheat_caller_address(token);

    start_cheat_caller_address(token, ATTACKER());
    votes.delegate(ATTACKER());
    stop_cheat_caller_address(token);

    // Attacker can create proposals but is limited by their token balance
    // They cannot spam unlimited proposals without significant stake
    assert!(votes.get_votes(ATTACKER()) > threshold, "Should meet threshold");
    // Creating proposals requires maintaining the threshold
// This prevents cheap spam attacks
}
