#[starknet::contract]
pub mod MockMalicious {
    use starknet::storage::{StoragePointerReadAccess, StoragePointerWriteAccess};
    use starknet::{ContractAddress, get_caller_address};

    #[storage]
    struct Storage {
        reentrancy_attempts: u32,
        target: ContractAddress,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        ReentrancyAttempted: ReentrancyAttempted,
        AttackExecuted: AttackExecuted,
    }

    #[derive(Drop, starknet::Event)]
    struct ReentrancyAttempted {
        attempt_number: u32,
        caller: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    struct AttackExecuted {
        attack_type: felt252,
        success: bool,
    }

    #[constructor]
    fn constructor(ref self: ContractState, target: ContractAddress) {
        self.target.write(target);
        self.reentrancy_attempts.write(0);
    }

    #[abi(embed_v0)]
    impl MockMaliciousImpl of super::IMockMalicious<ContractState> {
        fn attempt_reentrancy(ref self: ContractState) {
            let attempts = self.reentrancy_attempts.read();
            self.reentrancy_attempts.write(attempts + 1);

            self
                .emit(
                    ReentrancyAttempted {
                        attempt_number: attempts + 1, caller: get_caller_address(),
                    },
                );

            if attempts < 2 {
                panic!("Reentrancy protection should prevent this");
            }
        }

        fn gas_griefing_attack(ref self: ContractState, size: u32) {
            let mut data = array![];
            let mut i = 0;
            while i < size {
                let value: felt252 = i.into();
                data.append(value);
                i += 1;
            }

            self.emit(AttackExecuted { attack_type: 'GAS_GRIEFING', success: false });
        }

        fn attempt_double_vote(ref self: ContractState, proposal_id: felt252) {
            self.emit(AttackExecuted { attack_type: 'DOUBLE_VOTE', success: false });
        }

        fn flash_loan_attack(ref self: ContractState) {
            self.emit(AttackExecuted { attack_type: 'FLASH_LOAN', success: false });
        }

        fn front_run_proposal(ref self: ContractState, original_proposal: felt252) {
            self.emit(AttackExecuted { attack_type: 'FRONT_RUN', success: false });
        }
    }
}

#[starknet::interface]
pub trait IMockMalicious<TContractState> {
    fn attempt_reentrancy(ref self: TContractState);
    fn gas_griefing_attack(ref self: TContractState, size: u32);
    fn attempt_double_vote(ref self: TContractState, proposal_id: felt252);
    fn flash_loan_attack(ref self: TContractState);
    fn front_run_proposal(ref self: TContractState, original_proposal: felt252);
}
