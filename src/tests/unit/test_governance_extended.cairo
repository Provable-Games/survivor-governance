// Extended Governance Tests for Better Coverage
use core::serde::Serde;
use openzeppelin_governance::governor::interface::{IGovernorDispatcher, IGovernorDispatcherTrait};
use openzeppelin_governance::votes::interface::{IVotesDispatcher, IVotesDispatcherTrait};
use openzeppelin_token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use snforge_std::{
    ContractClassTrait, DeclareResultTrait, declare, start_cheat_caller_address,
    stop_cheat_caller_address,
};
use starknet::ContractAddress;

fn OWNER() -> ContractAddress {
    'OWNER'.try_into().unwrap()
}

fn PROPOSER() -> ContractAddress {
    'PROPOSER'.try_into().unwrap()
}

fn VOTER1() -> ContractAddress {
    'VOTER1'.try_into().unwrap()
}

fn VOTER2() -> ContractAddress {
    'VOTER2'.try_into().unwrap()
}

const INITIAL_SUPPLY: u256 = 1000000000000000000000000; // 1M tokens

fn deploy_full_governance() -> (ContractAddress, ContractAddress, ContractAddress) {
    // Deploy token
    let token_class = declare("SurvivorToken").unwrap().contract_class();

    let mut token_calldata = array![];
    token_calldata.append(INITIAL_SUPPLY.low.into());
    token_calldata.append(INITIAL_SUPPLY.high.into());
    token_calldata.append(OWNER().into());

    let (token_address, _) = token_class.deploy(@token_calldata).unwrap();

    // Deploy timelock controller
    let controller_class = declare("SurvivorGovernorController").unwrap().contract_class();
    let min_delay: u64 = 3600; // 1 hour

    let mut controller_calldata = array![];
    controller_calldata.append(min_delay.into());
    controller_calldata.append(0); // Empty proposers array
    controller_calldata.append(0); // Empty executors array
    controller_calldata.append(OWNER().into()); // Admin

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
fn test_governance_deployment_extended() {
    let (token, controller, governor) = deploy_full_governance();

    // Verify all contracts are deployed
    let zero_addr: ContractAddress = 0.try_into().unwrap();
    assert!(token != zero_addr, "Token not deployed");
    assert!(controller != zero_addr, "Controller not deployed");
    assert!(governor != zero_addr, "Governor not deployed");

    let gov = IGovernorDispatcher { contract_address: governor };

    // Check governance parameters
    assert!(gov.voting_delay() == 86400, "Wrong voting delay");
    assert!(gov.voting_period() == 604800, "Wrong voting period");
    assert!(gov.proposal_threshold() == 10, "Wrong proposal threshold");
}

#[test]
fn test_token_delegation_and_voting_power() {
    let (token, _controller, _governor) = deploy_full_governance();

    let erc20 = IERC20Dispatcher { contract_address: token };
    let votes = IVotesDispatcher { contract_address: token };

    // Transfer tokens to voters
    let transfer_amount = 100000000000000000000000; // 100k tokens
    start_cheat_caller_address(token, OWNER());
    erc20.transfer(VOTER1(), transfer_amount);
    erc20.transfer(VOTER2(), transfer_amount);
    stop_cheat_caller_address(token);

    // Check balances
    assert!(erc20.balance_of(VOTER1()) == transfer_amount, "Wrong VOTER1 balance");
    assert!(erc20.balance_of(VOTER2()) == transfer_amount, "Wrong VOTER2 balance");

    // Delegate voting power
    start_cheat_caller_address(token, VOTER1());
    votes.delegate(VOTER1());
    stop_cheat_caller_address(token);

    start_cheat_caller_address(token, VOTER2());
    votes.delegate(VOTER2());
    stop_cheat_caller_address(token);

    // Check voting power
    assert!(votes.get_votes(VOTER1()) == transfer_amount, "Wrong VOTER1 votes");
    assert!(votes.get_votes(VOTER2()) == transfer_amount, "Wrong VOTER2 votes");
}

#[test]
fn test_voting_power_transfer() {
    let (token, _controller, _governor) = deploy_full_governance();

    let erc20 = IERC20Dispatcher { contract_address: token };
    let votes = IVotesDispatcher { contract_address: token };

    // Setup initial delegation
    let initial_amount = 200000000000000000000000; // 200k tokens
    start_cheat_caller_address(token, OWNER());
    erc20.transfer(VOTER1(), initial_amount);
    stop_cheat_caller_address(token);

    start_cheat_caller_address(token, VOTER1());
    votes.delegate(VOTER1());
    stop_cheat_caller_address(token);

    assert!(votes.get_votes(VOTER1()) == initial_amount, "Initial votes wrong");

    // Transfer half to VOTER2
    let transfer_amount = 100000000000000000000000;
    start_cheat_caller_address(token, VOTER1());
    erc20.transfer(VOTER2(), transfer_amount);
    stop_cheat_caller_address(token);

    // VOTER1's voting power should decrease
    assert!(
        votes.get_votes(VOTER1()) == initial_amount - transfer_amount, "VOTER1 votes not updated",
    );

    // VOTER2 delegates to self
    start_cheat_caller_address(token, VOTER2());
    votes.delegate(VOTER2());
    stop_cheat_caller_address(token);

    assert!(votes.get_votes(VOTER2()) == transfer_amount, "VOTER2 votes wrong");
}

#[test]
fn test_delegation_chain() {
    let (token, _controller, _governor) = deploy_full_governance();

    let erc20 = IERC20Dispatcher { contract_address: token };
    let votes = IVotesDispatcher { contract_address: token };

    // Distribute tokens
    let amount = 100000000000000000000000; // 100k tokens each
    start_cheat_caller_address(token, OWNER());
    erc20.transfer(VOTER1(), amount);
    erc20.transfer(VOTER2(), amount);
    stop_cheat_caller_address(token);

    // VOTER1 delegates to VOTER2
    start_cheat_caller_address(token, VOTER1());
    votes.delegate(VOTER2());
    stop_cheat_caller_address(token);

    // VOTER2 delegates to self
    start_cheat_caller_address(token, VOTER2());
    votes.delegate(VOTER2());
    stop_cheat_caller_address(token);

    // VOTER2 should have combined voting power
    assert!(votes.get_votes(VOTER2()) == amount * 2, "Delegation chain failed");
    assert!(votes.get_votes(VOTER1()) == 0, "VOTER1 should have no votes");
}

#[test]
fn test_governance_name_and_version() {
    let (_token, _controller, governor) = deploy_full_governance();
    let gov = IGovernorDispatcher { contract_address: governor };

    // Check governance metadata
    assert!(gov.name() == 'SurvivorGovernor', "Wrong governor name");
    assert!(gov.version() == 'v1', "Wrong governor version");
}

#[test]
fn test_multiple_delegations() {
    let (token, _controller, _governor) = deploy_full_governance();

    let erc20 = IERC20Dispatcher { contract_address: token };
    let votes = IVotesDispatcher { contract_address: token };

    // Create more voters
    let voter3: ContractAddress = 'VOTER3'.try_into().unwrap();
    let voter4: ContractAddress = 'VOTER4'.try_into().unwrap();

    // Distribute tokens
    let amount = 50000000000000000000000; // 50k tokens each
    start_cheat_caller_address(token, OWNER());
    erc20.transfer(VOTER1(), amount);
    erc20.transfer(VOTER2(), amount);
    erc20.transfer(voter3, amount);
    erc20.transfer(voter4, amount);
    stop_cheat_caller_address(token);

    // Create delegation chain: VOTER1 -> VOTER2, voter3 -> VOTER2, voter4 -> VOTER2
    start_cheat_caller_address(token, VOTER1());
    votes.delegate(VOTER2());
    stop_cheat_caller_address(token);

    start_cheat_caller_address(token, voter3);
    votes.delegate(VOTER2());
    stop_cheat_caller_address(token);

    start_cheat_caller_address(token, voter4);
    votes.delegate(VOTER2());
    stop_cheat_caller_address(token);

    start_cheat_caller_address(token, VOTER2());
    votes.delegate(VOTER2());
    stop_cheat_caller_address(token);

    // VOTER2 should have all delegated votes
    assert!(votes.get_votes(VOTER2()) == amount * 4, "Multiple delegation failed");
}

#[test]
fn test_voting_power_with_no_delegation() {
    let (token, _controller, _governor) = deploy_full_governance();

    let erc20 = IERC20Dispatcher { contract_address: token };
    let votes = IVotesDispatcher { contract_address: token };

    // Transfer tokens without delegation
    let amount = 100000000000000000000000;
    start_cheat_caller_address(token, OWNER());
    erc20.transfer(VOTER1(), amount);
    stop_cheat_caller_address(token);

    // Should have no voting power without delegation
    assert!(votes.get_votes(VOTER1()) == 0, "Should have no votes without delegation");
    assert!(erc20.balance_of(VOTER1()) == amount, "Should have tokens");
}

#[test]
fn test_redelegation_updates_voting_power() {
    let (token, _controller, _governor) = deploy_full_governance();

    let erc20 = IERC20Dispatcher { contract_address: token };
    let votes = IVotesDispatcher { contract_address: token };

    // Setup
    let amount = 150000000000000000000000;
    start_cheat_caller_address(token, OWNER());
    erc20.transfer(VOTER1(), amount);
    stop_cheat_caller_address(token);

    // Initial delegation to self
    start_cheat_caller_address(token, VOTER1());
    votes.delegate(VOTER1());
    stop_cheat_caller_address(token);

    assert!(votes.get_votes(VOTER1()) == amount, "Initial delegation failed");

    // Redelegate to VOTER2
    start_cheat_caller_address(token, VOTER1());
    votes.delegate(VOTER2());
    stop_cheat_caller_address(token);

    // Voting power should move
    assert!(votes.get_votes(VOTER1()) == 0, "VOTER1 should have no votes");
    assert!(votes.get_votes(VOTER2()) == amount, "VOTER2 should have votes");
}
