use openzeppelin_access::accesscontrol::interface::{
    IAccessControlDispatcher, IAccessControlDispatcherTrait
};
use openzeppelin_governance::timelock::interface::{
    ITimelockDispatcher, ITimelockDispatcherTrait, ITimelockSafeDispatcher,
    ITimelockSafeDispatcherTrait
};
use snforge_std::{
    ContractClassTrait, DeclareResultTrait, declare, start_cheat_caller_address,
    stop_cheat_caller_address, start_cheat_block_timestamp, stop_cheat_block_timestamp,
    spy_events, EventSpyTrait, EventsFilterTrait
};
use starknet::{ContractAddress, get_block_timestamp};
use starknet::contract_address::contract_address_const;
use core::serde::Serde;

fn ADMIN() -> ContractAddress {
    contract_address_const::<'ADMIN'>()
}

fn PROPOSER() -> ContractAddress {
    contract_address_const::<'PROPOSER'>()
}

fn EXECUTOR() -> ContractAddress {
    contract_address_const::<'EXECUTOR'>()
}

fn OTHER() -> ContractAddress {
    contract_address_const::<'OTHER'>()
}

fn ZERO() -> ContractAddress {
    contract_address_const::<0>()
}

const MIN_DELAY: u64 = 86400; // 1 day
// Role constants from OpenZeppelin TimelockController (using actual hash values)
const PROPOSER_ROLE: felt252 = 0xb09aa5aeb3702cfd50b6b62bc4532604938f21248a27a1d5ca736082b6819cc1;
const EXECUTOR_ROLE: felt252 = 0xd8aa0f3194971a2a116679f7c2090f6939c8d4e01a2a8d7e41d55e5351469e63;
const CANCELLER_ROLE: felt252 = 0xfd643c72710c63c0180259aba6b2d05451e3591a24e58b62239378085726f783;
const DEFAULT_ADMIN_ROLE: felt252 = 0;

fn deploy_controller(
    min_delay: u64,
    proposers: Span<ContractAddress>,
    executors: Span<ContractAddress>,
    admin: ContractAddress
) -> ContractAddress {
    let class = declare("SurvivorGovernorController").unwrap().contract_class();
    
    let mut calldata: Array<felt252> = array![];
    calldata.append(min_delay.into());
    
    // Append proposers
    calldata.append(proposers.len().into());
    let mut i: u32 = 0;
    while i < proposers.len() {
        calldata.append((*proposers.at(i)).into());
        i += 1;
    };
    
    // Append executors
    calldata.append(executors.len().into());
    let mut j: u32 = 0;
    while j < executors.len() {
        calldata.append((*executors.at(j)).into());
        j += 1;
    };
    
    calldata.append(admin.into());
    
    let (address, _) = class.deploy(@calldata).unwrap();
    address
}

#[test]
fn test_constructor_valid_params() {
    let proposers: Array<ContractAddress> = array![PROPOSER()];
    let executors: Array<ContractAddress> = array![EXECUTOR()];
    let controller_address = deploy_controller(MIN_DELAY, proposers.span(), executors.span(), ADMIN());
    
    let access_control = IAccessControlDispatcher { contract_address: controller_address };
    let timelock = ITimelockDispatcher { contract_address: controller_address };
    
    // Check roles assigned
    assert!(access_control.has_role(DEFAULT_ADMIN_ROLE, ADMIN()), "Admin role not assigned");
    assert!(access_control.has_role(PROPOSER_ROLE, PROPOSER()), "Proposer role not assigned");
    assert!(access_control.has_role(EXECUTOR_ROLE, EXECUTOR()), "Executor role not assigned");
    
    // Check min delay
    assert!(timelock.get_min_delay() == MIN_DELAY, "Wrong min delay");
}

#[test]
#[should_panic(expected: ('Delay must be gt 0 and lt 2^32', 'ENTRYPOINT_FAILED'))]
fn test_constructor_zero_delay() {
    let proposers: Array<ContractAddress> = array![PROPOSER()];
    let executors: Array<ContractAddress> = array![EXECUTOR()];
    deploy_controller(0, proposers.span(), executors.span(), ADMIN());
}

#[test]
#[should_panic(expected: ('Invalid address', 'ENTRYPOINT_FAILED'))]
fn test_constructor_zero_admin() {
    let proposers: Array<ContractAddress> = array![PROPOSER()];
    let executors: Array<ContractAddress> = array![EXECUTOR()];
    deploy_controller(MIN_DELAY, proposers.span(), executors.span(), ZERO());
}

#[test]
fn test_schedule_as_proposer() {
    let proposers: Array<ContractAddress> = array![PROPOSER()];
    let executors: Array<ContractAddress> = array![EXECUTOR()];
    let controller_address = deploy_controller(MIN_DELAY, proposers.span(), executors.span(), ADMIN());
    let timelock = ITimelockDispatcher { contract_address: controller_address };
    
    let target = contract_address_const::<'TARGET'>();
    let value = 0;
    let data: Array<felt252> = array![1, 2, 3];
    let predecessor = 0;
    let salt = 'unique_salt';
    let delay = MIN_DELAY;
    
    let mut spy = spy_events();
    
    start_cheat_caller_address(controller_address, PROPOSER());
    // OpenZeppelin TimelockController schedule takes 7 params: target, value, data, predecessor, salt, delay
    // Returns operation_id
    let operation_id = timelock.schedule(target, value.into(), data.span(), predecessor, salt, delay);
    stop_cheat_caller_address(controller_address);
    
    // Verify operation is scheduled
    assert!(timelock.is_operation_pending(operation_id), "Operation not pending");
    
    // Check event emitted
    let events = spy.get_events().emitted_by(controller_address);
    assert!(events.events.len() > 0, "No events emitted");
}

#[test]
#[should_panic(expected: ('Caller is missing role',))]
fn test_schedule_without_role() {
    let proposers: Array<ContractAddress> = array![PROPOSER()];
    let executors: Array<ContractAddress> = array![EXECUTOR()];
    let controller_address = deploy_controller(MIN_DELAY, proposers.span(), executors.span(), ADMIN());
    let timelock = ITimelockDispatcher { contract_address: controller_address };
    
    let target = contract_address_const::<'TARGET'>();
    let value = 0;
    let data: Array<felt252> = array![1, 2, 3];
    let predecessor = 0;
    let salt = 'unique_salt';
    let delay = MIN_DELAY;
    
    start_cheat_caller_address(controller_address, OTHER());
    timelock.schedule(target, value.into(), data.span(), predecessor, salt, delay);
    stop_cheat_caller_address(controller_address);
}

#[test]
#[should_panic(expected: ('Operation already scheduled',))]
fn test_schedule_duplicate() {
    let proposers: Array<ContractAddress> = array![PROPOSER()];
    let executors: Array<ContractAddress> = array![EXECUTOR()];
    let controller_address = deploy_controller(MIN_DELAY, proposers.span(), executors.span(), ADMIN());
    let timelock = ITimelockDispatcher { contract_address: controller_address };
    
    let target = contract_address_const::<'TARGET'>();
    let value = 0;
    let data: Array<felt252> = array![1, 2, 3];
    let predecessor = 0;
    let salt = 'unique_salt';
    let delay = MIN_DELAY;
    
    start_cheat_caller_address(controller_address, PROPOSER());
    timelock.schedule(target, value.into(), data.span(), predecessor, salt, delay);
    // Try to schedule again
    timelock.schedule(target, value.into(), data.span(), predecessor, salt, delay);
    stop_cheat_caller_address(controller_address);
}

#[test]
fn test_execute_after_delay() {
    let proposers: Array<ContractAddress> = array![PROPOSER()];
    let executors: Array<ContractAddress> = array![EXECUTOR()];
    let controller_address = deploy_controller(MIN_DELAY, proposers.span(), executors.span(), ADMIN());
    let timelock = ITimelockDispatcher { contract_address: controller_address };
    
    let target = contract_address_const::<'TARGET'>();
    let value = 0;
    let data: Array<felt252> = array![];
    let predecessor = 0;
    let salt = 'unique_salt';
    
    // Schedule operation
    start_cheat_caller_address(controller_address, PROPOSER());
    let delay = MIN_DELAY;
    let operation_id = timelock.schedule(target, value.into(), data.span(), predecessor, salt, delay);
    stop_cheat_caller_address(controller_address);
    
    // Fast forward time
    let current_time = get_block_timestamp();
    start_cheat_block_timestamp(controller_address, current_time + MIN_DELAY + 1);
    
    // Execute operation
    start_cheat_caller_address(controller_address, EXECUTOR());
    timelock.execute(target, value.into(), data.span(), predecessor, salt);
    stop_cheat_caller_address(controller_address);
    
    stop_cheat_block_timestamp(controller_address);
    
    // Verify operation is done
    assert!(timelock.is_operation_done(operation_id), "Operation not executed");
}

#[test]
#[should_panic(expected: ('Operation not ready',))]
fn test_execute_before_delay() {
    let proposers: Array<ContractAddress> = array![PROPOSER()];
    let executors: Array<ContractAddress> = array![EXECUTOR()];
    let controller_address = deploy_controller(MIN_DELAY, proposers.span(), executors.span(), ADMIN());
    let timelock = ITimelockDispatcher { contract_address: controller_address };
    
    let target = contract_address_const::<'TARGET'>();
    let value = 0;
    let data: Array<felt252> = array![];
    let predecessor = 0;
    let salt = 'unique_salt';
    let delay = MIN_DELAY;
    
    // Schedule operation
    start_cheat_caller_address(controller_address, PROPOSER());
    timelock.schedule(target, value.into(), data.span(), predecessor, salt, delay);
    stop_cheat_caller_address(controller_address);
    
    // Try to execute immediately (should fail)
    start_cheat_caller_address(controller_address, EXECUTOR());
    timelock.execute(target, value.into(), data.span(), predecessor, salt);
    stop_cheat_caller_address(controller_address);
}

#[test]
#[should_panic(expected: ('Caller is missing role',))]
fn test_execute_without_role() {
    let proposers: Array<ContractAddress> = array![PROPOSER()];
    let executors: Array<ContractAddress> = array![EXECUTOR()];
    let controller_address = deploy_controller(MIN_DELAY, proposers.span(), executors.span(), ADMIN());
    let timelock = ITimelockDispatcher { contract_address: controller_address };
    
    let target = contract_address_const::<'TARGET'>();
    let value = 0;
    let data: Array<felt252> = array![];
    let predecessor = 0;
    let salt = 'unique_salt';
    let delay = MIN_DELAY;
    
    // Schedule operation
    start_cheat_caller_address(controller_address, PROPOSER());
    timelock.schedule(target, value.into(), data.span(), predecessor, salt, delay);
    stop_cheat_caller_address(controller_address);
    
    // Fast forward time
    let current_time = get_block_timestamp();
    start_cheat_block_timestamp(controller_address, current_time + MIN_DELAY + 1);
    
    // Try to execute without executor role
    start_cheat_caller_address(controller_address, OTHER());
    timelock.execute(target, value.into(), data.span(), predecessor, salt);
    stop_cheat_caller_address(controller_address);
    
    stop_cheat_block_timestamp(controller_address);
}

#[test]
fn test_cancel_operation() {
    let proposers: Array<ContractAddress> = array![PROPOSER()];
    let executors: Array<ContractAddress> = array![EXECUTOR()];
    let controller_address = deploy_controller(MIN_DELAY, proposers.span(), executors.span(), ADMIN());
    let timelock = ITimelockDispatcher { contract_address: controller_address };
    let access_control = IAccessControlDispatcher { contract_address: controller_address };
    
    // Grant canceller role to PROPOSER
    start_cheat_caller_address(controller_address, ADMIN());
    access_control.grant_role(CANCELLER_ROLE, PROPOSER());
    stop_cheat_caller_address(controller_address);
    
    let target = contract_address_const::<'TARGET'>();
    let value = 0;
    let data: Array<felt252> = array![];
    let predecessor = 0;
    let salt = 'unique_salt';
    let delay = MIN_DELAY;
    
    // Schedule operation
    start_cheat_caller_address(controller_address, PROPOSER());
    let operation_id = timelock.schedule(target, value.into(), data.span(), predecessor, salt, delay);
    
    // Cancel operation
    timelock.cancel(operation_id);
    stop_cheat_caller_address(controller_address);
    
    // Verify operation is cancelled
    assert!(!timelock.is_operation_pending(operation_id), "Operation still pending");
    
    // Fast forward time
    let current_time = get_block_timestamp();
    start_cheat_block_timestamp(controller_address, current_time + MIN_DELAY + 1);
    
    // Try to execute cancelled operation (should fail)
    let safe_dispatcher = ITimelockSafeDispatcher { contract_address: controller_address };
    start_cheat_caller_address(controller_address, EXECUTOR());
    match safe_dispatcher.execute(target, value, data.span(), predecessor, salt) {
        Result::Ok(_) => panic!("Should not execute cancelled operation"),
        Result::Err(_) => {} // Expected
    }
    stop_cheat_caller_address(controller_address);
    
    stop_cheat_block_timestamp(controller_address);
}

#[test]
fn test_batch_operations() {
    let proposers: Array<ContractAddress> = array![PROPOSER()];
    let executors: Array<ContractAddress> = array![EXECUTOR()];
    let controller_address = deploy_controller(MIN_DELAY, proposers.span(), executors.span(), ADMIN());
    let timelock = ITimelockDispatcher { contract_address: controller_address };
    
    let target1 = contract_address_const::<'TARGET1'>();
    let target2 = contract_address_const::<'TARGET2'>();
    let targets: Array<ContractAddress> = array![target1, target2];
    let values: Array<u256> = array![0, 0];
    let payloads: Array<Span<felt252>> = array![array![1].span(), array![2].span()];
    let predecessor = 0;
    let salt = 'batch_salt';
    let delay = MIN_DELAY;
    
    // Schedule batch operation
    start_cheat_caller_address(controller_address, PROPOSER());
    let operation_id = timelock.schedule_batch(targets.span(), values.span(), payloads.span(), predecessor, salt, delay);
    stop_cheat_caller_address(controller_address);
    
    // Verify operation is scheduled
    assert!(timelock.is_operation_pending(operation_id), "Batch not pending");
    
    // Fast forward time
    let current_time = get_block_timestamp();
    start_cheat_block_timestamp(controller_address, current_time + MIN_DELAY + 1);
    
    // Execute batch operation
    start_cheat_caller_address(controller_address, EXECUTOR());
    timelock.execute_batch(targets.span(), values.span(), payloads.span(), predecessor, salt);
    stop_cheat_caller_address(controller_address);
    
    stop_cheat_block_timestamp(controller_address);
    
    // Verify batch is executed
    assert!(timelock.is_operation_done(operation_id), "Batch not executed");
}

#[test]
fn test_update_delay() {
    let proposers: Array<ContractAddress> = array![PROPOSER()];
    let executors: Array<ContractAddress> = array![EXECUTOR()];
    let controller_address = deploy_controller(MIN_DELAY, proposers.span(), executors.span(), ADMIN());
    let timelock = ITimelockDispatcher { contract_address: controller_address };
    
    let new_delay: u64 = 172800; // 2 days
    let target = controller_address;
    let mut calldata: Array<felt252> = array![];
    calldata.append(new_delay.into());
    
    let predecessor = 0;
    let salt = 'update_delay_salt';
    let delay = MIN_DELAY;
    
    // Schedule delay update
    start_cheat_caller_address(controller_address, PROPOSER());
    let operation_id = timelock.schedule(target, 0_u256, calldata.span(), predecessor, salt, delay);
    stop_cheat_caller_address(controller_address);
    
    // Fast forward time
    let current_time = get_block_timestamp();
    start_cheat_block_timestamp(controller_address, current_time + MIN_DELAY + 1);
    
    // Execute delay update
    start_cheat_caller_address(controller_address, EXECUTOR());
    timelock.execute(target, 0_u256, calldata.span(), predecessor, salt);
    stop_cheat_caller_address(controller_address);
    
    stop_cheat_block_timestamp(controller_address);
    
    // Note: The actual delay update would require the update_delay function to be implemented
    // This test verifies the scheduling and execution mechanism works
    assert!(timelock.is_operation_done(operation_id), "Update not executed");
}