// Additional governor tests to increase coverage
use core::serde::Serde;
use snforge_std::{ContractClassTrait, DeclareResultTrait, declare};
use starknet::ContractAddress;

fn ADMIN() -> ContractAddress {
    'ADMIN'.try_into().unwrap()
}

fn deploy_token() -> ContractAddress {
    let class = declare("SurvivorToken").unwrap().contract_class();

    let initial_supply: u256 = 1000000000000000000000000; // 1M tokens

    let mut constructor_calldata = array![];
    constructor_calldata.append(initial_supply.low.into());
    constructor_calldata.append(initial_supply.high.into());
    constructor_calldata.append(ADMIN().into());

    let (address, _) = class.deploy(@constructor_calldata).unwrap();
    address
}

fn deploy_timelock() -> ContractAddress {
    let class = declare("SurvivorGovernorController").unwrap().contract_class();
    let min_delay: u64 = 86400;

    let mut calldata: Array<felt252> = array![];
    calldata.append(min_delay.into());
    calldata.append(0); // No proposers initially
    calldata.append(1); // One executor (address 0 = anyone)
    calldata.append(0); // Address 0 for anyone can execute
    calldata.append(ADMIN().into());

    let (address, _) = class.deploy(@calldata).unwrap();
    address
}

// Test governor deployment with real dependencies
#[test]
fn test_governor_deployment_with_dependencies() {
    let token = deploy_token();
    let timelock = deploy_timelock();

    let governor_class = declare("SurvivorGovernor").unwrap().contract_class();
    let governor_calldata = array![token.into(), timelock.into()];
    let (governor, _) = governor_class.deploy(@governor_calldata).unwrap();

    assert!(governor.into() != 0, "Governor not deployed");
}

// Test governor deployment with different config
#[test]
fn test_governor_deployment_alternative_config() {
    // Deploy token with different recipient
    let token_class = declare("SurvivorToken").unwrap().contract_class();

    let initial_supply: u256 = 500000000000000000000000; // 500k tokens

    let mut constructor_calldata = array![];
    constructor_calldata.append(initial_supply.low.into());
    constructor_calldata.append(initial_supply.high.into());
    constructor_calldata.append(ADMIN().into());

    let (token, _) = token_class.deploy(@constructor_calldata).unwrap();

    // Deploy timelock with different delay
    let timelock_class = declare("SurvivorGovernorController").unwrap().contract_class();
    let min_delay: u64 = 7200; // 2 hours

    let mut timelock_calldata: Array<felt252> = array![];
    timelock_calldata.append(min_delay.into());
    timelock_calldata.append(0); // No proposers initially
    timelock_calldata.append(1); // One executor
    timelock_calldata.append(0); // Anyone can execute
    timelock_calldata.append(ADMIN().into());

    let (timelock, _) = timelock_class.deploy(@timelock_calldata).unwrap();

    // Deploy governor with different config
    let governor_class = declare("SurvivorGovernor").unwrap().contract_class();
    let governor_calldata = array![token.into(), timelock.into()];
    let (governor, _) = governor_class.deploy(@governor_calldata).unwrap();

    assert!(governor.into() != 0, "Governor not deployed");
    assert!(token.into() != 0, "Token not deployed");
    assert!(timelock.into() != 0, "Timelock not deployed");
}
