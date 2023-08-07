//! Contract to create markets.

// *************************************************************************
//                                  IMPORTS
// *************************************************************************

// Core lib imports.
use core::traits::Into;
use starknet::{ContractAddress, ClassHash};

// *************************************************************************
//                  Interface of the `MarketFactory` contract.
// *************************************************************************
#[starknet::interface]
trait IMarketFactory<TContractState> {
    /// Create a new market.
    /// # Arguments
    /// * `index_token` - The token used as the index of the market.
    /// * `long_token` - The token used as the long side of the market.
    /// * `short_token` - The token used as the short side of the market.
    /// * `market_type` - The type of the market.
    fn create_market(
        ref self: TContractState,
        index_token: ContractAddress,
        long_token: ContractAddress,
        short_token: ContractAddress,
        market_type: felt252,
    ) -> (ContractAddress, felt252);

    /// Update the class hash of the `MarketToken` contract to deploy when creating a new market.
    /// # Arguments
    /// * `market_token_class_hash` - The class hash of the `MarketToken` contract to deploy when creating a new market.
    fn update_market_token_class_hash(
        ref self: TContractState, market_token_class_hash: ClassHash,
    );
}

#[starknet::contract]
mod MarketFactory {
    // *************************************************************************
    //                               IMPORTS
    // *************************************************************************

    // Core lib imports.
    use core::result::ResultTrait;
    use starknet::{get_caller_address, ContractAddress, contract_address_const, ClassHash};
    use starknet::syscalls::deploy_syscall;
    use poseidon::poseidon_hash_span;
    use array::ArrayTrait;
    use traits::Into;
    use debug::PrintTrait;

    // Local imports.
    use gojo::role::role;
    use gojo::role::role_store::{IRoleStoreDispatcher, IRoleStoreDispatcherTrait};
    use gojo::data::data_store::{IDataStoreDispatcher, IDataStoreDispatcherTrait};
    use gojo::market::market::{Market, UniqueIdMarket};

    // *************************************************************************
    //                              STORAGE
    // *************************************************************************
    #[storage]
    struct Storage {
        /// Interface to interact with the data store contract.
        data_store: IDataStoreDispatcher,
        /// Interface to interact with the role store contract.
        role_store: IRoleStoreDispatcher,
        /// The class hash of the `MarketToken` contract to deploy when creating a new market.
        market_token_class_hash: ClassHash,
    }

    // *************************************************************************
    // EVENTS
    // *************************************************************************
    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        MarketCreated: MarketCreated,
        MarketTokenClassHashUpdated: MarketTokenClassHashUpdated,
    }

    #[derive(Drop, starknet::Event)]
    struct MarketCreated {
        creator: ContractAddress,
        market_token: ContractAddress,
        index_token: ContractAddress,
        long_token: ContractAddress,
        short_token: ContractAddress,
        market_type: felt252,
    }

    #[derive(Drop, starknet::Event)]
    struct MarketTokenClassHashUpdated {
        updated_by: ContractAddress,
        previous_value: ClassHash,
        new_value: ClassHash,
    }


    // *************************************************************************
    //                              CONSTRUCTOR
    // *************************************************************************

    /// Constructor of the contract.
    /// # Arguments
    /// * `data_store_adress` - The address of the data store contract.
    /// * `role_store_address` - The address of the role store contract.
    /// * `market_token_class_hash` - The class hash of the `MarketToken` contract to deploy when creating a new market.
    #[constructor]
    fn constructor(
        ref self: ContractState,
        data_store_adress: ContractAddress,
        role_store_address: ContractAddress,
        market_token_class_hash: ClassHash,
    ) {
        self.data_store.write(IDataStoreDispatcher { contract_address: data_store_adress });
        self.role_store.write(IRoleStoreDispatcher { contract_address: role_store_address });
        self.market_token_class_hash.write(market_token_class_hash);
    }


    // *************************************************************************
    //                          EXTERNAL FUNCTIONS
    // *************************************************************************
    #[external(v0)]
    impl MarketFactory of super::IMarketFactory<ContractState> {
        /// Create a new market.
        /// # Arguments
        /// * `index_token` - The token used as the index of the market.
        /// * `long_token` - The token used as the long side of the market.
        /// * `short_token` - The token used as the short side of the market.
        /// * `market_type` - The type of the market.
        fn create_market(
            ref self: ContractState,
            index_token: ContractAddress,
            long_token: ContractAddress,
            short_token: ContractAddress,
            market_type: felt252,
        ) -> (ContractAddress, felt252) {
            // Get the caller address.
            let caller_address = get_caller_address();
            // Check that the caller has the `MARKET_KEEPER` role.
            self.role_store.read().assert_only_role(caller_address, role::MARKET_KEEPER);

            // Compute the salt to use when deploying the `MarketToken` contract.
            let salt = self
                .compute_salt_for_deploy_market_token(
                    index_token, long_token, short_token, market_type,
                );

            // Deploy the `MarketToken` contract.
            // Contructor arguments: [role_store_address].
            let mut constructor_calldata = array![];
            constructor_calldata.append(self.role_store.read().contract_address.into());
            // Deploy the contract with the `deploy_syscall`.
            let (market_token_deployed_address, return_data) = deploy_syscall(
                self.market_token_class_hash.read(), salt, constructor_calldata.span(), false
            )
                .unwrap();

            // Create the market.
            let market = Market {
                market_token: market_token_deployed_address, index_token, long_token, short_token,
            };
            // Compute the key of the market.
            let market_key = market.unique_id(market_type);
            // Add the market to the data store.
            self.data_store.read().set_market(market_key, market);

            // Emit the event.
            self
                .emit(
                    MarketCreated {
                        creator: caller_address,
                        market_token: market_token_deployed_address,
                        index_token,
                        long_token,
                        short_token,
                        market_type,
                    }
                );

            // Return the market token address and the market key.
            (market_token_deployed_address, market_key)
        }

        /// Update the class hash of the `MarketToken` contract to deploy when creating a new market.
        /// # Arguments
        /// * `market_token_class_hash` - The class hash of the `MarketToken` contract to deploy when creating a new market.
        fn update_market_token_class_hash(
            ref self: ContractState, market_token_class_hash: ClassHash,
        ) {
            // Get the caller address.
            let caller_address = get_caller_address();
            // Check that the caller has the `MARKET_KEEPER` role.
            self.role_store.read().assert_only_role(caller_address, role::MARKET_KEEPER);

            let old_market_token_class_hash = self.market_token_class_hash.read();

            // Update the class hash.
            self.market_token_class_hash.write(market_token_class_hash);

            // Emit the event.
            self
                .emit(
                    MarketTokenClassHashUpdated {
                        updated_by: caller_address,
                        previous_value: old_market_token_class_hash,
                        new_value: market_token_class_hash,
                    }
                );
        }
    }

    // *************************************************************************
    //                          INTERNAL FUNCTIONS
    // *************************************************************************
    #[generate_trait]
    impl InternalImpl of InternalTrait {
        /// Compute a salt to use when deploying a new `MarketToken` contract.
        /// # Arguments
        /// * `market_type` - The type of the market.
        fn compute_salt_for_deploy_market_token(
            self: @ContractState,
            index_token: ContractAddress,
            long_token: ContractAddress,
            short_token: ContractAddress,
            market_type: felt252,
        ) -> felt252 {
            let mut data = array![];
            data.append('GOJO_MARKET');
            data.append(index_token.into());
            data.append(long_token.into());
            data.append(short_token.into());
            data.append(market_type);
            poseidon_hash_span(data.span())
        }
    }
}
