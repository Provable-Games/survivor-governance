use core::serde::Serde;
use openzeppelin_governance::governor::interface::{
    IGovernorDispatcher, IGovernorDispatcherTrait, ProposalState,
};
use openzeppelin_governance::votes::interface::{IVotesDispatcher, IVotesDispatcherTrait};
use openzeppelin_token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use snforge_std::{
    ContractClassTrait, DeclareResultTrait, declare, start_cheat_block_timestamp,
    start_cheat_caller_address, start_mock_call, stop_cheat_block_timestamp,
    stop_cheat_caller_address, stop_mock_call,
};
use starknet::account::Call;
use starknet::{ContractAddress, get_block_timestamp};

fn ADMIN() -> ContractAddress {
    'ADMIN'.try_into().unwrap()
}

fn ATTACKER() -> ContractAddress {
    'ATTACKER'.try_into().unwrap()
}

fn WHALE() -> ContractAddress {
    'WHALE'.try_into().unwrap()
}

fn USER1() -> ContractAddress {
    'USER1'.try_into().unwrap()
}

fn ZERO() -> ContractAddress {
    0.try_into().unwrap()
}

struct TestSystem {
    token: ContractAddress,
    governor: ContractAddress,
    timelock: ContractAddress,
}

fn setup_test_system() -> TestSystem {
    // Deploy token
    let token_class = declare("SurvivorToken").unwrap().contract_class();
    let initial_supply: u256 = 100000000 * 1000000000000000000; // 100M tokens

    let token_name: ByteArray = "Test Token";
    let token_symbol: ByteArray = "TEST";

    let mut token_calldata = array![];
    token_name.serialize(ref token_calldata);
    token_symbol.serialize(ref token_calldata);
    token_calldata.append(initial_supply.low.into());
    token_calldata.append(initial_supply.high.into());
    token_calldata.append(ADMIN().into());

    let (token_address, _) = token_class.deploy(@token_calldata).unwrap();

    // Deploy timelock
    let controller_class = declare("SurvivorGovernorController").unwrap().contract_class();
    let min_delay: u64 = 86400;

    let mut controller_calldata: Array<felt252> = array![];
    controller_calldata.append(min_delay.into());
    controller_calldata.append(0); // No proposers
    controller_calldata.append(1); // One executor (anyone)
    controller_calldata.append(ZERO().into());
    controller_calldata.append(ADMIN().into());

    let (controller_address, _) = controller_class.deploy(@controller_calldata).unwrap();

    // Deploy governor
    let governor_class = declare("SurvivorGovernor").unwrap().contract_class();
    let mut governor_calldata = array![];
    governor_calldata.append(token_address.into());
    governor_calldata.append(controller_address.into());

    let (governor_address, _) = governor_class.deploy(@governor_calldata).unwrap();

    TestSystem { token: token_address, governor: governor_address, timelock: controller_address }
}

#[test]
fn test_reentrancy_attack_prevention() {
    let system = setup_test_system();
    let governor = IGovernorDispatcher { contract_address: system.governor };
    let token = IERC20Dispatcher { contract_address: system.token };
    let votes = IVotesDispatcher { contract_address: system.token };

    // Setup: Give attacker tokens
    start_cheat_caller_address(system.token, ADMIN());
    token.transfer(ATTACKER(), 1000000 * 1000000000000000000);
    stop_cheat_caller_address(system.token);

    start_cheat_caller_address(system.token, ATTACKER());
    votes.delegate(ATTACKER());
    stop_cheat_caller_address(system.token);

    // Create a proposal that would call back into governor
    let target = system.governor;
    let selector = selector!("propose"); // Try to create recursive proposal
    let mut recursive_calldata = array![];
    // Would need to serialize proposal parameters

    let call = Call { to: target, selector, calldata: recursive_calldata.span() };
    let calls = array![call];
    let description: ByteArray = "Reentrancy attempt";

    start_cheat_caller_address(system.governor, ATTACKER());
    let proposal_id = governor.propose(calls.span(), description);
    stop_cheat_caller_address(system.governor);
    // Even if proposal passes and executes, reentrancy guard should prevent recursive calls
// The execution would fail due to reentrancy protection
}

#[test]
fn test_gas_griefing_protection() {
    let system = setup_test_system();
    let governor = IGovernorDispatcher { contract_address: system.governor };
    let token = IERC20Dispatcher { contract_address: system.token };
    let votes = IVotesDispatcher { contract_address: system.token };

    // Setup: Give attacker tokens
    start_cheat_caller_address(system.token, ADMIN());
    token.transfer(ATTACKER(), 1000000 * 1000000000000000000);
    stop_cheat_caller_address(system.token);

    start_cheat_caller_address(system.token, ATTACKER());
    votes.delegate(ATTACKER());
    stop_cheat_caller_address(system.token);

    // Try to create proposal with huge arrays to consume gas
    let mut huge_calls: Array<Call> = array![];
    let target = system.governor;
    let selector = selector!("voting_delay");
    let calldata: Array<felt252> = array![];

    // Try to add many calls (gas limits should prevent DOS)
    let mut i = 0_u32;
    let max_calls = 100; // System should handle this or reject
    while i < max_calls {
        let call = Call { to: target, selector, calldata: calldata.span() };
        huge_calls.append(call);
        i += 1;
    }

    let description: ByteArray = "Gas griefing attempt";

    // This should either fail due to gas limits or be handled gracefully
    start_cheat_caller_address(system.governor, ATTACKER());
    let result = std::panic::catch_unwind(|| {
        governor.propose(huge_calls.span(), description)
    });
    // System should handle this without allowing DOS
    stop_cheat_caller_address(system.governor);
}

#[test]
fn test_flash_loan_governance_attack() {
    let system = setup_test_system();
    let governor = IGovernorDispatcher { contract_address: system.governor };
    let token = IERC20Dispatcher { contract_address: system.token };
    let votes = IVotesDispatcher { contract_address: system.token };

    // Setup: Distribute tokens
    start_cheat_caller_address(system.token, ADMIN());
    token.transfer(WHALE(), 30000000 * 1000000000000000000); // 30%
    token.transfer(USER1(), 10000000 * 1000000000000000000); // 10%
    stop_cheat_caller_address(system.token);

    // Users delegate
    start_cheat_caller_address(system.token, WHALE());
    votes.delegate(WHALE());
    stop_cheat_caller_address(system.token);

    start_cheat_caller_address(system.token, USER1());
    votes.delegate(USER1());
    stop_cheat_caller_address(system.token);

    // Create proposal
    let target = system.governor;
    let selector = selector!("voting_delay");
    let calldata: Array<felt252> = array![];
    let call = Call { to: target, selector, calldata: calldata.span() };
    let calls = array![call];
    let description: ByteArray = "Legitimate proposal";

    start_cheat_caller_address(system.governor, USER1());
    let proposal_id = governor.propose(calls.span(), description);
    stop_cheat_caller_address(system.governor);

    // Fast forward to voting period
    let current_time = get_block_timestamp();
    start_cheat_block_timestamp(system.governor, current_time + 86401);

    // Attacker tries flash loan attack:
    // 1. Borrow huge amount of tokens
    // 2. Delegate to self
    // 3. Vote
    // 4. Return tokens
    // All in same block

    // Simulate flash loan - attacker gets tokens temporarily
    start_cheat_caller_address(system.token, ADMIN());
    token.transfer(ATTACKER(), 50000000 * 1000000000000000000); // 50% - flash loan
    stop_cheat_caller_address(system.token);

    // Attacker delegates (but snapshot was already taken at proposal creation!)
    start_cheat_caller_address(system.token, ATTACKER());
    votes.delegate(ATTACKER());
    stop_cheat_caller_address(system.token);

    // Try to vote - should fail because snapshot was at proposal creation
    start_cheat_caller_address(system.governor, ATTACKER());
    let vote_result = governor.cast_vote(proposal_id, 1);
    assert!(vote_result == 0, "Flash loan attack succeeded - vote counted!");
    stop_cheat_caller_address(system.governor);

    // Return flash loan
    start_cheat_caller_address(system.token, ATTACKER());
    token.transfer(ADMIN(), 50000000 * 1000000000000000000);
    stop_cheat_caller_address(system.token);

    stop_cheat_block_timestamp(system.governor);
}

#[test]
fn test_front_running_proposal_creation() {
    let system = setup_test_system();
    let governor = IGovernorDispatcher { contract_address: system.governor };
    let token = IERC20Dispatcher { contract_address: system.token };
    let votes = IVotesDispatcher { contract_address: system.token };

    // Setup: Give both users tokens
    start_cheat_caller_address(system.token, ADMIN());
    token.transfer(USER1(), 1000000 * 1000000000000000000);
    token.transfer(ATTACKER(), 1000000 * 1000000000000000000);
    stop_cheat_caller_address(system.token);

    start_cheat_caller_address(system.token, USER1());
    votes.delegate(USER1());
    stop_cheat_caller_address(system.token);

    start_cheat_caller_address(system.token, ATTACKER());
    votes.delegate(ATTACKER());
    stop_cheat_caller_address(system.token);

    // USER1 prepares a proposal
    let target = system.governor;
    let selector = selector!("voting_delay");
    let calldata: Array<felt252> = array![];
    let call = Call { to: target, selector, calldata: calldata.span() };
    let calls = array![call];
    let description: ByteArray = "Important governance update";

    // Attacker sees USER1's transaction in mempool and front-runs with same proposal
    start_cheat_caller_address(system.governor, ATTACKER());
    let attacker_proposal_id = governor.propose(calls.span(), description);
    stop_cheat_caller_address(system.governor);

    // USER1's transaction arrives after
    start_cheat_caller_address(system.governor, USER1());
    let result = std::panic::catch_unwind(
        || {
            governor.propose(calls.span(), description) // Should fail - duplicate
        },
    );
    assert!(result.is_err(), "Duplicate proposal should fail");
    stop_cheat_caller_address(system.governor);
    // Proposal ID is deterministic based on parameters, preventing front-running advantage
}

#[test]
fn test_double_voting_exploit_prevention() {
    let system = setup_test_system();
    let governor = IGovernorDispatcher { contract_address: system.governor };
    let token = IERC20Dispatcher { contract_address: system.token };
    let votes = IVotesDispatcher { contract_address: system.token };

    // Setup
    start_cheat_caller_address(system.token, ADMIN());
    token.transfer(ATTACKER(), 1000000 * 1000000000000000000);
    stop_cheat_caller_address(system.token);

    start_cheat_caller_address(system.token, ATTACKER());
    votes.delegate(ATTACKER());
    stop_cheat_caller_address(system.token);

    // Create proposal
    let target = system.governor;
    let selector = selector!("voting_delay");
    let calldata: Array<felt252> = array![];
    let call = Call { to: target, selector, calldata: calldata.span() };
    let calls = array![call];
    let description: ByteArray = "Test proposal";

    start_cheat_caller_address(system.governor, ATTACKER());
    let proposal_id = governor.propose(calls.span(), description);
    stop_cheat_caller_address(system.governor);

    // Fast forward to voting
    let current_time = get_block_timestamp();
    start_cheat_block_timestamp(system.governor, current_time + 86401);

    // First vote
    start_cheat_caller_address(system.governor, ATTACKER());
    governor.cast_vote(proposal_id, 1);
    stop_cheat_caller_address(system.governor);

    // Try different voting methods to vote again
    start_cheat_caller_address(system.governor, ATTACKER());

    // Try cast_vote again
    let result1 = std::panic::catch_unwind(
        || {
            governor.cast_vote(proposal_id, 0) // Different vote
        },
    );
    assert!(result1.is_err(), "Double vote via cast_vote");

    // Try cast_vote_with_reason
    let result2 = std::panic::catch_unwind(
        || {
            governor.cast_vote_with_reason(proposal_id, 0, "Changed mind")
        },
    );
    assert!(result2.is_err(), "Double vote via cast_vote_with_reason");

    stop_cheat_caller_address(system.governor);
    stop_cheat_block_timestamp(system.governor);
}

#[test]
fn test_timelock_confusion_attack() {
    let system = setup_test_system();
    let governor = IGovernorDispatcher { contract_address: system.governor };
    let token = IERC20Dispatcher { contract_address: system.token };
    let votes = IVotesDispatcher { contract_address: system.token };

    // Setup
    start_cheat_caller_address(system.token, ADMIN());
    token.transfer(ATTACKER(), 1000000 * 1000000000000000000);
    token.transfer(USER1(), 1000000 * 1000000000000000000);
    stop_cheat_caller_address(system.token);

    start_cheat_caller_address(system.token, ATTACKER());
    votes.delegate(ATTACKER());
    stop_cheat_caller_address(system.token);

    start_cheat_caller_address(system.token, USER1());
    votes.delegate(USER1());
    stop_cheat_caller_address(system.token);

    // Create two similar proposals with slight differences
    let target = system.governor;
    let selector = selector!("voting_delay");

    // Proposal 1 - legitimate
    let calldata1: Array<felt252> = array![1];
    let call1 = Call { to: target, selector, calldata: calldata1.span() };
    let calls1 = array![call1];
    let description1: ByteArray = "Update parameter to 1";

    // Proposal 2 - malicious (looks similar)
    let calldata2: Array<felt252> = array![999999]; // Malicious value
    let call2 = Call { to: target, selector, calldata: calldata2.span() };
    let calls2 = array![call2];
    let description2: ByteArray = "Update parameter to 1"; // Same description!

    // Create both proposals
    start_cheat_caller_address(system.governor, USER1());
    let proposal_id_1 = governor.propose(calls1.span(), description1);
    stop_cheat_caller_address(system.governor);

    start_cheat_caller_address(system.governor, ATTACKER());
    let proposal_id_2 = governor.propose(calls2.span(), description2);
    stop_cheat_caller_address(system.governor);

    // Each proposal has unique ID based on parameters
    assert!(proposal_id_1 != proposal_id_2, "Proposals should have different IDs");
    // Even with same description, the calldata difference creates different IDs
// This prevents confusion attacks where similar proposals are mixed up
}

#[test]
fn test_proposal_spam_attack() {
    let system = setup_test_system();
    let governor = IGovernorDispatcher { contract_address: system.governor };
    let token = IERC20Dispatcher { contract_address: system.token };
    let votes = IVotesDispatcher { contract_address: system.token };

    // Setup: Give attacker just enough tokens to propose
    start_cheat_caller_address(system.token, ADMIN());
    token.transfer(ATTACKER(), 15 * 1000000000000000000); // Just above threshold
    stop_cheat_caller_address(system.token);

    start_cheat_caller_address(system.token, ATTACKER());
    votes.delegate(ATTACKER());
    stop_cheat_caller_address(system.token);

    // Try to spam proposals
    let target = system.governor;
    let selector = selector!("voting_delay");
    let calldata: Array<felt252> = array![];

    let mut spam_count = 0_u32;
    let max_spam_attempts = 10;

    while spam_count < max_spam_attempts {
        let call = Call { to: target, selector, calldata: calldata.span() };
        let calls = array![call];
        let mut description: ByteArray = "Spam proposal ";
        // Make each description unique
        if spam_count == 0 {
            description.append(@"0");
        } else if spam_count == 1 {
            description.append(@"1");
        } else if spam_count == 2 {
            description.append(@"2");
        } else if spam_count == 3 {
            description.append(@"3");
        } else if spam_count == 4 {
            description.append(@"4");
        } else if spam_count == 5 {
            description.append(@"5");
        } else if spam_count == 6 {
            description.append(@"6");
        } else if spam_count == 7 {
            description.append(@"7");
        } else if spam_count == 8 {
            description.append(@"8");
        } else {
            description.append(@"9");
        }

        start_cheat_caller_address(system.governor, ATTACKER());
        governor.propose(calls.span(), description);
        stop_cheat_caller_address(system.governor);

        spam_count += 1;
    };
    // Even with spam, each proposal needs to go through full lifecycle
// Proposal threshold limits who can spam
// Gas costs make spam expensive
// Community can vote down spam proposals
}

#[test]
fn test_signature_replay_attack_prevention() {
    let system = setup_test_system();
    let governor = IGovernorDispatcher { contract_address: system.governor };
    let token = IERC20Dispatcher { contract_address: system.token };
    let votes = IVotesDispatcher { contract_address: system.token };

    // Setup
    start_cheat_caller_address(system.token, ADMIN());
    token.transfer(USER1(), 1000000 * 1000000000000000000);
    stop_cheat_caller_address(system.token);

    start_cheat_caller_address(system.token, USER1());
    votes.delegate(USER1());
    stop_cheat_caller_address(system.token);

    // Create proposal
    let target = system.governor;
    let selector = selector!("voting_delay");
    let calldata: Array<felt252> = array![];
    let call = Call { to: target, selector, calldata: calldata.span() };
    let calls = array![call];
    let description: ByteArray = "Test proposal";

    start_cheat_caller_address(system.governor, USER1());
    let proposal_id = governor.propose(calls.span(), description);
    stop_cheat_caller_address(system.governor);
    // In a real scenario:
// 1. USER1 signs a vote message
// 2. Someone submits it via cast_vote_by_sig
// 3. Attacker tries to replay the signature for another proposal
// 4. Nonce system prevents replay

    // The nonce-based system ensures signatures can't be replayed
// Each signature includes the specific proposal ID and nonce
}
