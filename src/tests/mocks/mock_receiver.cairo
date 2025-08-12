#[starknet::contract]
pub mod MockReceiver {
    use starknet::ContractAddress;
    use starknet::storage::{
        MutableVecTrait, StoragePointerReadAccess, StoragePointerWriteAccess, Vec,
    };

    #[storage]
    struct Storage {
        last_sender: ContractAddress,
        last_value: u256,
        last_data: Vec<felt252>,
        call_count: u32,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        CallReceived: CallReceived,
    }

    #[derive(Drop, starknet::Event)]
    struct CallReceived {
        sender: ContractAddress,
        value: u256,
        call_number: u32,
    }

    #[constructor]
    fn constructor(ref self: ContractState) {
        self.call_count.write(0);
    }

    #[abi(embed_v0)]
    impl MockReceiverImpl of super::IMockReceiver<ContractState> {
        fn receive_call(ref self: ContractState, value: u256, data: Span<felt252>) {
            let sender = starknet::get_caller_address();
            let call_count = self.call_count.read() + 1;

            self.last_sender.write(sender);
            self.last_value.write(value);

            // Clear previous data and write new data
            let mut i = 0;
            while i < data.len() {
                self.last_data.push(*data.at(i));
                i += 1;
            }
            self.call_count.write(call_count);

            self.emit(CallReceived { sender: sender, value: value, call_number: call_count });
        }

        fn receive_and_revert(ref self: ContractState, should_revert: bool) {
            if should_revert {
                panic!("Receiver reverting as requested");
            }
            let call_count = self.call_count.read() + 1;
            self.call_count.write(call_count);
        }

        fn receive_and_callback(
            ref self: ContractState, callback_target: ContractAddress, callback_data: Span<felt252>,
        ) {
            let call_count = self.call_count.read() + 1;
            self.call_count.write(call_count);

            panic!("Callback not implemented for simplicity");
        }

        fn get_last_call(self: @ContractState) -> (ContractAddress, u256, u32) {
            (self.last_sender.read(), self.last_value.read(), self.call_count.read())
        }

        fn get_call_count(self: @ContractState) -> u32 {
            self.call_count.read()
        }
    }
}
use starknet::ContractAddress;

#[starknet::interface]
pub trait IMockReceiver<TContractState> {
    fn receive_call(ref self: TContractState, value: u256, data: Span<felt252>);
    fn receive_and_revert(ref self: TContractState, should_revert: bool);
    fn receive_and_callback(
        ref self: TContractState, callback_target: ContractAddress, callback_data: Span<felt252>,
    );
    fn get_last_call(self: @TContractState) -> (ContractAddress, u256, u32);
    fn get_call_count(self: @TContractState) -> u32;
}
