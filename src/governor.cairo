#[starknet::contract]
pub mod SurvivorGovernor {
    use openzeppelin_governance::governor::GovernorComponent::InternalTrait as GovernorInternalTrait;
    use openzeppelin_governance::governor::extensions::GovernorSettingsComponent::InternalTrait as GovernorSettingsInternalTrait;
    use openzeppelin_governance::governor::extensions::GovernorTimelockExecutionComponent::InternalTrait as GovernorTimelockExecutionInternalTrait;
    use openzeppelin_governance::governor::extensions::GovernorVotesQuorumFractionComponent::InternalTrait;
    use openzeppelin_governance::governor::extensions::{
        GovernorCountingSimpleComponent, GovernorSettingsComponent,
        GovernorTimelockExecutionComponent, GovernorVotesQuorumFractionComponent,
    };
    use openzeppelin_governance::governor::{DefaultConfig, GovernorComponent};
    use openzeppelin_introspection::src5::SRC5Component;
    use openzeppelin_utils::cryptography::snip12::SNIP12Metadata;
    use starknet::ContractAddress;

    pub const VOTING_DELAY: u64 = 3600; // 1 hour
    pub const VOTING_PERIOD: u64 = 432000; // 5 days
    pub const PROPOSAL_THRESHOLD: u256 = 50000000000000000000000; // 50k tokens 18 decimals
    pub const QUORUM_NUMERATOR: u256 = 300; // 30%

    component!(path: GovernorComponent, storage: governor, event: GovernorEvent);
    component!(
        path: GovernorVotesQuorumFractionComponent,
        storage: governor_votes,
        event: GovernorVotesEvent,
    );
    component!(
        path: GovernorSettingsComponent, storage: governor_settings, event: GovernorSettingsEvent,
    );
    component!(
        path: GovernorCountingSimpleComponent,
        storage: governor_counting_simple,
        event: GovernorCountingSimpleEvent,
    );
    component!(
        path: GovernorTimelockExecutionComponent,
        storage: governor_timelock_execution,
        event: GovernorTimelockExecutionEvent,
    );
    component!(path: SRC5Component, storage: src5, event: SRC5Event);

    // Governor
    #[abi(embed_v0)]
    impl GovernorImpl = GovernorComponent::GovernorImpl<ContractState>;

    // Extensions external
    #[abi(embed_v0)]
    impl QuorumFractionImpl =
        GovernorVotesQuorumFractionComponent::QuorumFractionImpl<ContractState>;
    #[abi(embed_v0)]
    impl GovernorSettingsAdminImpl =
        GovernorSettingsComponent::GovernorSettingsAdminImpl<ContractState>;
    #[abi(embed_v0)]
    impl TimelockedImpl =
        GovernorTimelockExecutionComponent::TimelockedImpl<ContractState>;

    // Extensions internal
    impl GovernorQuorumImpl = GovernorVotesQuorumFractionComponent::GovernorQuorum<ContractState>;
    impl GovernorVotesImpl = GovernorVotesQuorumFractionComponent::GovernorVotes<ContractState>;
    impl GovernorSettingsImpl = GovernorSettingsComponent::GovernorSettings<ContractState>;
    impl GovernorCountingSimpleImpl =
        GovernorCountingSimpleComponent::GovernorCounting<ContractState>;
    impl GovernorTimelockExecutionImpl =
        GovernorTimelockExecutionComponent::GovernorExecution<ContractState>;

    // SRC5
    #[abi(embed_v0)]
    impl SRC5Impl = SRC5Component::SRC5Impl<ContractState>;

    #[storage]
    struct Storage {
        #[substorage(v0)]
        pub governor: GovernorComponent::Storage,
        #[substorage(v0)]
        pub governor_votes: GovernorVotesQuorumFractionComponent::Storage,
        #[substorage(v0)]
        pub governor_settings: GovernorSettingsComponent::Storage,
        #[substorage(v0)]
        pub governor_counting_simple: GovernorCountingSimpleComponent::Storage,
        #[substorage(v0)]
        pub governor_timelock_execution: GovernorTimelockExecutionComponent::Storage,
        #[substorage(v0)]
        pub src5: SRC5Component::Storage,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        GovernorEvent: GovernorComponent::Event,
        #[flat]
        GovernorVotesEvent: GovernorVotesQuorumFractionComponent::Event,
        #[flat]
        GovernorSettingsEvent: GovernorSettingsComponent::Event,
        #[flat]
        GovernorCountingSimpleEvent: GovernorCountingSimpleComponent::Event,
        #[flat]
        GovernorTimelockExecutionEvent: GovernorTimelockExecutionComponent::Event,
        #[flat]
        SRC5Event: SRC5Component::Event,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState, votes_token: ContractAddress, timelock_controller: ContractAddress,
    ) {
        self.governor.initializer();
        self.governor_votes.initializer(votes_token, QUORUM_NUMERATOR);
        self.governor_settings.initializer(VOTING_DELAY, VOTING_PERIOD, PROPOSAL_THRESHOLD);
        self.governor_timelock_execution.initializer(timelock_controller);
    }

    //
    // SNIP12 Metadata
    //

    pub impl SNIP12MetadataImpl of SNIP12Metadata {
        fn name() -> felt252 {
            'SurvivorGovernor'
        }

        fn version() -> felt252 {
            'v1'
        }
    }
}
