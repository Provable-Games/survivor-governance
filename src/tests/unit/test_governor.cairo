// Comprehensive Governor Unit Tests (SG-001 to SG-022)
use openzeppelin_governance::governor::interface::{
    IGovernorDispatcher, IGovernorDispatcherTrait, ProposalState
};
use openzeppelin_governance::votes::interface::{IVotesDispatcher, IVotesDispatcherTrait};
use openzeppelin_token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use snforge_std::{
    ContractClassTrait, DeclareResultTrait, declare, start_cheat_caller_address,
    stop_cheat_caller_address, start_cheat_block_timestamp, stop_cheat_block_timestamp,
    spy_events, EventSpyAssertionsTrait, EventSpyTrait
};
use starknet::{ContractAddress, contract_address_const, get_block_timestamp};
use core::serde::Serde;

// Test addresses
fn ADMIN() -> ContractAddress {
    contract_address_const::<'ADMIN'>()
}

fn PROPOSER() -> ContractAddress {
    contract_address_const::<'PROPOSER'>()
}

fn VOTER1() -> ContractAddress {
    contract_address_const::<'VOTER1'>()
}

fn VOTER2() -> ContractAddress {
    contract_address_const::<'VOTER2'>()
}

fn VOTER3() -> ContractAddress {
    contract_address_const::<'VOTER3'>()
}

fn TARGET() -> ContractAddress {
    contract_address_const::<'TARGET'>()
}

// Constants
const INITIAL_SUPPLY: u256 = 1000000000000000000000000; // 1M tokens
const VOTING_DELAY: u64 = 86400; // 1 day
const VOTING_PERIOD: u64 = 604800; // 1 week
const PROPOSAL_THRESHOLD: u256 = 10000000000000000000; // 10 tokens
const QUORUM_NUMERATOR: u256 = 40; // 4%

// Deploy helpers
fn deploy_token() -> ContractAddress {
    let class = declare("SurvivorToken").unwrap().contract_class();
    
    let token_name: ByteArray = "Test Token";
    let token_symbol: ByteArray = "TEST";
    
    let mut constructor_calldata = array![];
    token_name.serialize(ref constructor_calldata);
    token_symbol.serialize(ref constructor_calldata);
    constructor_calldata.append(INITIAL_SUPPLY.low.into());
    constructor_calldata.append(INITIAL_SUPPLY.high.into());
    constructor_calldata.append(ADMIN().into());
    
    let (address, _) = class.deploy(@constructor_calldata).unwrap();
    address
}

fn deploy_timelock() -> ContractAddress {
    let class = declare("SurvivorGovernorController").unwrap().contract_class();
    let min_delay: u64 = 86400;
    let proposers: Array<ContractAddress> = array![PROPOSER()];
    let executors: Array<ContractAddress> = array![contract_address_const::<0>()]; // Anyone can execute
    
    let mut calldata: Array<felt252> = array![];
    calldata.append(min_delay.into());
    calldata.append(proposers.len().into());
    calldata.append(PROPOSER().into());
    calldata.append(executors.len().into());
    calldata.append(contract_address_const::<0>().into());
    calldata.append(ADMIN().into());
    
    let (address, _) = class.deploy(@calldata).unwrap();
    address
}

fn deploy_governor(token: ContractAddress, timelock: ContractAddress) -> ContractAddress {
    let class = declare("SurvivorGovernor").unwrap().contract_class();
    let constructor_calldata = array![
        token.into(),
        timelock.into()
    ];
    let (address, _) = class.deploy(@constructor_calldata).unwrap();
    address
}

fn setup_governance() -> (ContractAddress, ContractAddress, ContractAddress) {
    let token = deploy_token();
    let timelock = deploy_timelock();
    let governor = deploy_governor(token, timelock);
    
    // Distribute tokens to voters
    let erc20 = IERC20Dispatcher { contract_address: token };
    let votes = IVotesDispatcher { contract_address: token };
    
    start_cheat_caller_address(token, ADMIN());
    erc20.transfer(PROPOSER(), 100000000000000000000000); // 100k tokens
    erc20.transfer(VOTER1(), 200000000000000000000000); // 200k tokens
    erc20.transfer(VOTER2(), 150000000000000000000000); // 150k tokens
    erc20.transfer(VOTER3(), 50000000000000000000000); // 50k tokens
    stop_cheat_caller_address(token);
    
    // Delegate voting power to self
    start_cheat_caller_address(token, PROPOSER());
    votes.delegate(PROPOSER());
    stop_cheat_caller_address(token);
    
    start_cheat_caller_address(token, VOTER1());
    votes.delegate(VOTER1());
    stop_cheat_caller_address(token);
    
    start_cheat_caller_address(token, VOTER2());
    votes.delegate(VOTER2());
    stop_cheat_caller_address(token);
    
    start_cheat_caller_address(token, VOTER3());
    votes.delegate(VOTER3());
    stop_cheat_caller_address(token);
    
    (token, timelock, governor)
}

// Test cases according to test plan

#[test]
fn test_sg_001_deployment() {
    let token = deploy_token();
    let timelock = deploy_timelock();
    let governor_address = deploy_governor(token, timelock);
    let governor = IGovernorDispatcher { contract_address: governor_address };
    
    assert(governor.name() == "Survivor Governor", 'Wrong name');
    assert(governor.version() == "1", 'Wrong version');
    assert(governor.voting_delay() == VOTING_DELAY, 'Wrong voting delay');
    assert(governor.voting_period() == VOTING_PERIOD, 'Wrong voting period');
    assert(governor.proposal_threshold() == PROPOSAL_THRESHOLD, 'Wrong threshold');
}

#[test]
fn test_sg_002_propose_valid() {
    let (token, timelock, governor_address) = setup_governance();
    let governor = IGovernorDispatcher { contract_address: governor_address };
    
    let targets: Array<ContractAddress> = array![TARGET()];
    let values: Array<u256> = array![0];
    let calldatas: Array<Span<felt252>> = array![array![1, 2, 3].span()];
    let description: ByteArray = "Test Proposal #1";
    
    let mut spy = spy_events();
    
    start_cheat_caller_address(governor_address, PROPOSER());
    let proposal_id = governor.propose(targets.span(), values.span(), calldatas.span(), description);
    stop_cheat_caller_address(governor_address);
    
    assert(proposal_id != 0, 'Invalid proposal ID');
    assert(governor.state(proposal_id) == ProposalState::Pending, 'Should be pending');
    
    // Verify event emitted
    let events = spy.get_events().emitted_by(governor_address);
    assert(events.events.len() > 0, 'ProposalCreated not emitted');
}

#[test]
#[should_panic(expected: ('Governor: below threshold',))]
fn test_sg_003_propose_below_threshold() {
    let (token, timelock, governor_address) = setup_governance();
    let governor = IGovernorDispatcher { contract_address: governor_address };
    
    let targets: Array<ContractAddress> = array![TARGET()];
    let values: Array<u256> = array![0];
    let calldatas: Array<Span<felt252>> = array![array![].span()];
    let description: ByteArray = "Test Proposal";
    
    // Try to propose with account that has no tokens
    start_cheat_caller_address(governor_address, contract_address_const::<'NO_TOKENS'>());
    governor.propose(targets.span(), values.span(), calldatas.span(), description);
    stop_cheat_caller_address(governor_address);
}

#[test]
#[should_panic(expected: ('Governor: empty proposal',))]
fn test_sg_004_propose_empty_actions() {
    let (token, timelock, governor_address) = setup_governance();
    let governor = IGovernorDispatcher { contract_address: governor_address };
    
    let targets: Array<ContractAddress> = array![];
    let values: Array<u256> = array![];
    let calldatas: Array<Span<felt252>> = array![];
    let description: ByteArray = "Empty Proposal";
    
    start_cheat_caller_address(governor_address, PROPOSER());
    governor.propose(targets.span(), values.span(), calldatas.span(), description);
    stop_cheat_caller_address(governor_address);
}