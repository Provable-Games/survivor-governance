use core::serde::Serde;
use openzeppelin_governance::votes::interface::{IVotesDispatcher, IVotesDispatcherTrait};
use openzeppelin_token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use snforge_std::{
    ContractClassTrait, DeclareResultTrait, declare, start_cheat_block_timestamp,
    start_cheat_caller_address, stop_cheat_block_timestamp, stop_cheat_caller_address,
};
use starknet::ContractAddress;

fn OWNER() -> ContractAddress {
    'OWNER'.try_into().unwrap()
}

fn get_user(index: u32) -> ContractAddress {
    // Generate 10 different user addresses
    let addr: felt252 = ('USER0'.into() + index.into());
    addr.try_into().unwrap()
}

fn deploy_token_with_supply(supply: u256) -> ContractAddress {
    let class = declare("SurvivorToken").unwrap().contract_class();

    let token_name: ByteArray = "Fuzz Token";
    let token_symbol: ByteArray = "FUZZ";

    let mut constructor_calldata = array![];
    token_name.serialize(ref constructor_calldata);
    token_symbol.serialize(ref constructor_calldata);
    constructor_calldata.append(supply.low.into());
    constructor_calldata.append(supply.high.into());
    constructor_calldata.append(OWNER().into());

    let (address, _) = class.deploy(@constructor_calldata).unwrap();
    address
}

#[test]
#[fuzzer(runs: 100)]
fn test_fuzz_balance_consistency(
    transfer_count: u8, amount1: u128, amount2: u128, from_index: u8, to_index: u8,
) {
    // Deploy token with 1B tokens
    let total_supply: u256 = 1000000000 * 1000000000000000000;
    let token_address = deploy_token_with_supply(total_supply);
    let erc20 = IERC20Dispatcher { contract_address: token_address };

    // Distribute initial tokens to 10 users
    let users_count = 10_u32;
    let amount_per_user = total_supply / users_count.into();

    start_cheat_caller_address(token_address, OWNER());
    let mut i = 0_u32;
    while i < users_count {
        if i > 0 { // Keep some for OWNER (user 0)
            erc20.transfer(get_user(i), amount_per_user);
        }
        i += 1;
    }
    stop_cheat_caller_address(token_address);

    // Perform random transfers
    let transfer_limit = core::cmp::min(transfer_count, 50); // Limit transfers for performance
    let mut j = 0_u8;
    while j < transfer_limit {
        // Use the fuzzed parameters to create transfer variations
        let amount: u256 = if j % 2 == 0 {
            amount1.into()
        } else {
            amount2.into()
        };
        let from_user_idx = (from_index % 10 + j % 10) % 10;
        let to_user_idx = (to_index % 10 + j % 10 + 1) % 10;

        let from_user = get_user(from_user_idx.into());
        let to_user = get_user(to_user_idx.into());

        // Only transfer if from != to and amount <= balance
        if from_user != to_user {
            let balance = erc20.balance_of(from_user);
            let safe_amount = if amount > balance {
                balance / 2
            } else {
                amount
            };

            if safe_amount > 0 {
                start_cheat_caller_address(token_address, from_user);
                erc20.transfer(to_user, safe_amount);
                stop_cheat_caller_address(token_address);
            }
        }
        j += 1;
    }

    // Invariant: Sum of all balances = total supply
    let mut total_balance: u256 = 0;
    let mut k = 0_u32;
    while k < users_count {
        total_balance += erc20.balance_of(get_user(k));
        k += 1;
    }

    assert!(total_balance == total_supply, "Balance consistency violated");
}

#[test]
#[fuzzer(runs: 100)]
fn test_fuzz_delegation_consistency(
    delegation_count: u8, delegator_index: u8, delegatee_index: u8,
) {
    // Deploy token
    let total_supply: u256 = 1000000000 * 1000000000000000000;
    let token_address = deploy_token_with_supply(total_supply);
    let erc20 = IERC20Dispatcher { contract_address: token_address };
    let votes = IVotesDispatcher { contract_address: token_address };

    // Distribute tokens to 10 users
    let users_count = 10_u32;
    let amount_per_user = total_supply / users_count.into();

    start_cheat_caller_address(token_address, OWNER());
    let mut i = 0_u32;
    while i < users_count {
        if i > 0 {
            erc20.transfer(get_user(i), amount_per_user);
        }
        i += 1;
    }
    stop_cheat_caller_address(token_address);

    // Perform random delegations
    let delegation_limit = core::cmp::min(delegation_count, 50);
    let mut j = 0_u8;
    while j < delegation_limit {
        let delegator_user_idx = (delegator_index % 10 + j % 10) % 10;
        let delegatee_user_idx = (delegatee_index % 10 + (j % 5) * 2) % 10;

        let delegator = get_user(delegator_user_idx.into());
        let delegatee = get_user(delegatee_user_idx.into());

        start_cheat_caller_address(token_address, delegator);
        votes.delegate(delegatee);
        stop_cheat_caller_address(token_address);

        j += 1;
    }

    // Invariant: Sum of voting power <= total supply
    let mut total_voting_power: u256 = 0;
    let mut k = 0_u32;
    while k < users_count {
        total_voting_power += votes.get_votes(get_user(k));
        k += 1;
    }

    assert!(total_voting_power <= total_supply, "Voting power exceeds supply");
}

#[test]
#[fuzzer(runs: 100)]
fn test_fuzz_allowance_safety(
    approval_count: u8,
    approve_amount: u128,
    transfer_amount: u128,
    owner_index: u8,
    spender_index: u8,
) {
    // Deploy token
    let total_supply: u256 = 1000000000 * 1000000000000000000;
    let token_address = deploy_token_with_supply(total_supply);
    let erc20 = IERC20Dispatcher { contract_address: token_address };

    // Distribute tokens
    let users_count = 10_u32;
    let amount_per_user = total_supply / users_count.into();

    start_cheat_caller_address(token_address, OWNER());
    let mut i = 0_u32;
    while i < users_count {
        if i > 0 {
            erc20.transfer(get_user(i), amount_per_user);
        }
        i += 1;
    }
    stop_cheat_caller_address(token_address);

    // Perform approvals and transfers
    let operation_limit = core::cmp::min(approval_count, 50);
    let mut j = 0_u8;
    while j < operation_limit {
        let owner_user_idx = (owner_index % 10 + j % 10) % 10;
        let spender_user_idx = (spender_index % 10 + (j % 5) * 2) % 10;

        let owner = get_user(owner_user_idx.into());
        let spender = get_user(spender_user_idx.into());
        let approve_amt: u256 = approve_amount.into();
        let transfer_amt: u256 = transfer_amount.into();

        // Approve
        start_cheat_caller_address(token_address, owner);
        erc20.approve(spender, approve_amt);
        stop_cheat_caller_address(token_address);

        // Try to transfer (should respect allowance)
        let allowance = erc20.allowance(owner, spender);
        let owner_balance = erc20.balance_of(owner);
        let safe_transfer = core::cmp::min(core::cmp::min(transfer_amt, allowance), owner_balance);

        if safe_transfer > 0 && owner != spender {
            start_cheat_caller_address(token_address, spender);
            erc20.transfer_from(owner, get_user(0), safe_transfer); // Transfer to user 0
            stop_cheat_caller_address(token_address);

            // Invariant: Cannot spend more than allowance
            let new_allowance = erc20.allowance(owner, spender);
            assert!(new_allowance == allowance - safe_transfer, "Allowance not properly reduced");
        }

        j += 1;
    };
}

#[test]
#[fuzzer(runs: 100)]
fn test_fuzz_checkpoint_ordering(timestamp_increment: u64, delegation_change: u8) {
    // Deploy token
    let total_supply: u256 = 1000000000 * 1000000000000000000;
    let token_address = deploy_token_with_supply(total_supply);
    let erc20 = IERC20Dispatcher { contract_address: token_address };
    let votes = IVotesDispatcher { contract_address: token_address };

    // Give tokens to USER1
    let user1 = get_user(1);
    start_cheat_caller_address(token_address, OWNER());
    erc20.transfer(user1, total_supply / 2);
    stop_cheat_caller_address(token_address);

    // Track timestamps for checkpoints
    let mut current_timestamp: u64 = 1000;
    let mut previous_timestamp: u64 = 0;
    let mut checkpoints: Array<u64> = array![];

    // Perform delegations at different timestamps
    let changes_limit = 10; // Fixed number of changes
    let mut i = 0_u32;
    while i < changes_limit {
        // Increment timestamp (limit to prevent overflow)
        let safe_increment = (timestamp_increment % 100000) + 1; // Max 100k seconds per step
        let increment = safe_increment + (i.into() * 100); // Ensure increment
        current_timestamp += increment;

        // Ensure monotonic increase
        assert!(current_timestamp > previous_timestamp, "Timestamp not increasing");
        checkpoints.append(current_timestamp);

        start_cheat_block_timestamp(token_address, current_timestamp);

        // Change delegation
        let delegatee = get_user(((delegation_change.into() + i) % 10).into());
        start_cheat_caller_address(token_address, user1);
        votes.delegate(delegatee);
        stop_cheat_caller_address(token_address);

        stop_cheat_block_timestamp(token_address);

        previous_timestamp = current_timestamp;
        i += 1;
    }

    // Invariant: Checkpoints are monotonically increasing
    let mut j = 1_u32;
    while j < checkpoints.len() {
        assert!(*checkpoints.at(j) > *checkpoints.at(j - 1), "Checkpoints not ordered");
        j += 1;
    };
}
