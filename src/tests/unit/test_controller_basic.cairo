// Basic controller tests to increase coverage
use snforge_std::{ContractClassTrait, DeclareResultTrait, declare};
use starknet::ContractAddress;

fn ADMIN() -> ContractAddress {
    'ADMIN'.try_into().unwrap()
}

fn PROPOSER() -> ContractAddress {
    'PROPOSER'.try_into().unwrap()
}

fn EXECUTOR() -> ContractAddress {
    'EXECUTOR'.try_into().unwrap()
}

// Test successful controller deployment
#[test]
fn test_controller_deployment() {
    let class = declare("SurvivorGovernorController").unwrap().contract_class();
    let min_delay: u64 = 86400;
    let _proposers = array![PROPOSER()];
    let _executors = array![EXECUTOR()];

    let mut calldata: Array<felt252> = array![];
    calldata.append(min_delay.into());
    calldata.append(1); // proposers length
    calldata.append(PROPOSER().into());
    calldata.append(1); // executors length  
    calldata.append(EXECUTOR().into());
    calldata.append(ADMIN().into());

    let (address, _) = class.deploy(@calldata).unwrap();
    assert!(address.into() != 0, "Controller not deployed");
}

// Test controller deployment with zero delay (should succeed)
#[test]
fn test_controller_zero_delay() {
    let class = declare("SurvivorGovernorController").unwrap().contract_class();
    let min_delay: u64 = 0;
    let _proposers = array![PROPOSER()];
    let _executors = array![EXECUTOR()];

    let mut calldata: Array<felt252> = array![];
    calldata.append(min_delay.into());
    calldata.append(1); // proposers length
    calldata.append(PROPOSER().into());
    calldata.append(1); // executors length
    calldata.append(EXECUTOR().into());
    calldata.append(ADMIN().into());

    let (address, _) = class.deploy(@calldata).unwrap();
    assert!(address.into() != 0, "Controller not deployed");
}

// Test controller deployment with multiple proposers
#[test]
fn test_controller_multiple_proposers() {
    let class = declare("SurvivorGovernorController").unwrap().contract_class();
    let min_delay: u64 = 3600;
    let _proposers = array![PROPOSER(), ADMIN()];
    let _executors = array![EXECUTOR()];

    let mut calldata: Array<felt252> = array![];
    calldata.append(min_delay.into());
    calldata.append(2); // proposers length
    calldata.append(PROPOSER().into());
    calldata.append(ADMIN().into());
    calldata.append(1); // executors length
    calldata.append(EXECUTOR().into());
    calldata.append(ADMIN().into());

    let (address, _) = class.deploy(@calldata).unwrap();
    assert!(address.into() != 0, "Controller not deployed");
}
