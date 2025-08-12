#[starknet::contract]
pub mod MockTimelock {
    use core::num::traits::Zero;
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use starknet::{ContractAddress, get_block_timestamp};

    #[storage]
    struct Storage {
        min_delay: u64,
        operations: Map<felt252, OperationState>,
    }

    #[derive(Drop, Serde, starknet::Store)]
    struct OperationState {
        ready_at: u64,
        done: bool,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        CallScheduled: CallScheduled,
        CallExecuted: CallExecuted,
        CallCancelled: CallCancelled,
    }

    #[derive(Drop, starknet::Event)]
    struct CallScheduled {
        #[key]
        id: felt252,
        index: felt252,
        target: ContractAddress,
        value: u256,
        predecessor: felt252,
        delay: u64,
    }

    #[derive(Drop, starknet::Event)]
    struct CallExecuted {
        #[key]
        id: felt252,
        index: felt252,
        target: ContractAddress,
        value: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct CallCancelled {
        #[key]
        id: felt252,
    }

    #[constructor]
    fn constructor(ref self: ContractState, min_delay: u64) {
        assert(min_delay > 0, 'Delay must be positive');
        self.min_delay.write(min_delay);
    }

    #[abi(embed_v0)]
    impl MockTimelockImpl of super::IMockTimelock<ContractState> {
        fn schedule(
            ref self: ContractState,
            target: ContractAddress,
            value: u256,
            data: Span<felt252>,
            predecessor: felt252,
            salt: felt252,
            delay: u64,
        ) -> felt252 {
            let min_delay = self.min_delay.read();
            assert(delay >= min_delay, 'Insufficient delay');

            let id = self.hash_operation(target, value, data, predecessor, salt);
            let current_state = self.operations.read(id);
            assert(current_state.ready_at.is_zero(), 'Already scheduled');

            let ready_at = get_block_timestamp() + delay;
            self.operations.write(id, OperationState { ready_at: ready_at, done: false });

            self
                .emit(
                    CallScheduled {
                        id: id,
                        index: 0,
                        target: target,
                        value: value,
                        predecessor: predecessor,
                        delay: delay,
                    },
                );

            id
        }

        fn execute(
            ref self: ContractState,
            target: ContractAddress,
            value: u256,
            data: Span<felt252>,
            predecessor: felt252,
            salt: felt252,
        ) {
            let id = self.hash_operation(target, value, data, predecessor, salt);
            let operation_state = self.operations.read(id);

            assert(!operation_state.ready_at.is_zero(), 'Not scheduled');
            assert(!operation_state.done, 'Already executed');
            assert(get_block_timestamp() >= operation_state.ready_at, 'Not ready');

            self
                .operations
                .write(id, OperationState { ready_at: operation_state.ready_at, done: true });

            self.emit(CallExecuted { id: id, index: 0, target: target, value: value });
        }

        fn cancel(ref self: ContractState, id: felt252) {
            let operation_state = self.operations.read(id);
            assert(!operation_state.ready_at.is_zero(), 'Not scheduled');
            assert(!operation_state.done, 'Already executed');

            self.operations.write(id, OperationState { ready_at: 0, done: false });

            self.emit(CallCancelled { id: id });
        }

        fn is_operation_pending(self: @ContractState, id: felt252) -> bool {
            let operation_state = self.operations.read(id);
            !operation_state.ready_at.is_zero() && !operation_state.done
        }

        fn is_operation_ready(self: @ContractState, id: felt252) -> bool {
            let operation_state = self.operations.read(id);
            !operation_state.ready_at.is_zero()
                && !operation_state.done
                && get_block_timestamp() >= operation_state.ready_at
        }

        fn is_operation_done(self: @ContractState, id: felt252) -> bool {
            self.operations.read(id).done
        }

        fn get_timestamp(self: @ContractState, id: felt252) -> u64 {
            self.operations.read(id).ready_at
        }

        fn get_min_delay(self: @ContractState) -> u64 {
            self.min_delay.read()
        }

        fn hash_operation(
            self: @ContractState,
            target: ContractAddress,
            value: u256,
            data: Span<felt252>,
            predecessor: felt252,
            salt: felt252,
        ) -> felt252 {
            let mut hash_data = array![];
            hash_data.append(target.into());
            hash_data.append(value.low.into());
            hash_data.append(value.high.into());
            hash_data.append(data.len().into());
            let mut i = 0;
            while i < data.len() {
                hash_data.append(*data.at(i));
                i += 1;
            }
            hash_data.append(predecessor);
            hash_data.append(salt);

            core::poseidon::poseidon_hash_span(hash_data.span())
        }
    }
}
use starknet::ContractAddress;

#[starknet::interface]
pub trait IMockTimelock<TContractState> {
    fn schedule(
        ref self: TContractState,
        target: ContractAddress,
        value: u256,
        data: Span<felt252>,
        predecessor: felt252,
        salt: felt252,
        delay: u64,
    ) -> felt252;

    fn execute(
        ref self: TContractState,
        target: ContractAddress,
        value: u256,
        data: Span<felt252>,
        predecessor: felt252,
        salt: felt252,
    );

    fn cancel(ref self: TContractState, id: felt252);
    fn is_operation_pending(self: @TContractState, id: felt252) -> bool;
    fn is_operation_ready(self: @TContractState, id: felt252) -> bool;
    fn is_operation_done(self: @TContractState, id: felt252) -> bool;
    fn get_timestamp(self: @TContractState, id: felt252) -> u64;
    fn get_min_delay(self: @TContractState) -> u64;
    fn hash_operation(
        self: @TContractState,
        target: ContractAddress,
        value: u256,
        data: Span<felt252>,
        predecessor: felt252,
        salt: felt252,
    ) -> felt252;
}
