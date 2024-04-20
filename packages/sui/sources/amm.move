// Copyright (c) Tamago Blockchain Labs, Inc.
// SPDX-License-Identifier: MIT

// upgraded AMM from the previous version which was forked from OmniBTC
// this new version includes custom weight pools, enabling the bootstrapping of new pools with less capital
// and only permit whitelisted addresses to register new pools

module legato::amm {

    use std::vector;
    use std::string::{Self, String}; 
    use std::type_name::{get, into_string};
    use std::ascii::into_bytes;
    
    use sui::math;
    use sui::bag::{Self, Bag};
    use sui::object::{Self, ID, UID};
    use sui::balance::{ Self, Supply, Balance};
    // use sui::coin::{Self, Coin, value, split, destroy_zero};
    use sui::coin::{Self, Coin};
    use sui::tx_context::{ Self, TxContext};
    use sui::transfer;

    use legato::comparator; 
    use legato::weighted_math;

    // ======== Constants ========

    /// The max value that can be held in one of the Balances of
    /// a Pool. U64 MAX / FEE_SCALE
    const MAX_POOL_VALUE: u64 = {
        18446744073709551615 / 10000
    };
    /// Minimal liquidity.
    const MINIMAL_LIQUIDITY: u64 = 1000;
    /// Max u64 value.
    const U64_MAX: u64 = 18446744073709551615;
    /// Current fee is 1%
    const DEFAUTL_FEE_MULTIPLIER: u64 = 100;
    /// The integer scaling setting for fees calculation and weights
    const FEE_SCALE: u64 = 10000;

    // ======== Errors ========

    /// For when Coin is zero.
    const ERR_ZERO_AMOUNT: u64 = 200;
    /// For when someone tries to swap in an empty pool.
    const ERR_RESERVES_EMPTY: u64 = 201;
    /// For when someone attempts to add more liquidity than u128 Math allows.
    const ERR_POOL_FULL: u64 = 202;
    /// Insuficient amount in coin x reserves.
    const ERR_INSUFFICIENT_COIN_X: u64 = 203;
    /// Insuficient amount in coin y reserves.
    const ERR_INSUFFICIENT_COIN_Y: u64 = 204;
    /// Divide by zero while calling mul_div.
    const ERR_DIVIDE_BY_ZERO: u64 = 205;
    /// For when someone add liquidity with invalid parameters.
    const ERR_OVERLIMIT: u64 = 206;
    /// Amount out less than minimum.
    const ERR_COIN_OUT_NUM_LESS_THAN_EXPECTED_MINIMUM: u64 = 207;
    /// Liquid not enough.
    const ERR_LIQUID_NOT_ENOUGH: u64 = 208;
    /// Coin X is the same as Coin Y
    const ERR_THE_SAME_COIN: u64 = 209;
    /// Pool X-Y has registered
    const ERR_POOL_HAS_REGISTERED: u64 = 210;
    /// Pool X-Y not register
    const ERR_POOL_NOT_REGISTER: u64 = 211;
    /// Coin X and Coin Y order
    const ERR_MUST_BE_ORDER: u64 = 212;
    /// Overflow for u64
    const ERR_U64_OVERFLOW: u64 = 213;
    /// Incorrect swap
    const ERR_INCORRECT_SWAP: u64 = 214;
    /// Insufficient liquidity
    const ERR_INSUFFICIENT_LIQUIDITY_MINTED: u64 = 215;

    const ERR_NOT_FOUND: u64 = 216;
    const ERR_DUPLICATED_ENTRY: u64 = 217;
    const ERR_UNAUTHORISED: u64 = 218;
    const ERR_WEIGHTS_SUM: u64 = 219; 
    const ERR_DECIMALS: u64 = 220;
    const ERR_INVALID_FEE: u64 = 221;
    const ERR_EMERGENCY: u64 = 222;
    const ERR_NOT_REGISTERED: u64 = 223;

    // ======== Structs =========

    /// The Pool token that will be used to mark the pool share
    /// of a liquidity provider. The parameter `X` and `Y` is for the
    /// coin held in the pool.
    struct LP<phantom X, phantom Y> has drop, store {}

    /// The Basic Weighted Pool with fixed weights forked from Balancer V2 Lite
    struct Pool<phantom X, phantom Y> has store {
        global: ID,
        coin_x: Balance<X>,
        coin_y: Balance<Y>,
        weight_x: u64,
        weight_y: u64,
        scaling_factor_x: u64,
        scaling_factor_y: u64,
        lp_supply: Supply<LP<X, Y>>,
        min_liquidity: Balance<LP<X, Y>>,
    }


    // the global state of the AMM
    struct AMMGlobal has key {
        id: UID,
        has_paused: bool,
        pools: Bag,
        whitelist: vector<address>, // who can setup a new pool
        fee_multiplier: u64
    }

    struct AMMManagerCap has key {
        id: UID
    }

    // Initializes the AMM module
    fun init(ctx: &mut TxContext) {

        // Transfer ManagerCap to the deployer
        transfer::transfer(
            AMMManagerCap {id: object::new(ctx)},
            tx_context::sender(ctx)
        );

        // Create a new list for adding to the global state
        let whitelist_list = vector::empty<address>();
        vector::push_back<address>(&mut whitelist_list, tx_context::sender(ctx));
        
        // Initialize the global state
        let global = AMMGlobal {
            id: object::new(ctx),
            whitelist: whitelist_list,
            has_paused: false,
            pools: bag::new(ctx),
            fee_multiplier: DEFAUTL_FEE_MULTIPLIER
        };

        transfer::share_object(global)
    }

    // ======== Public Functions =========

    /// Entrypoint for the `add_liquidity` method.
    /// Sends `LP<X,Y>` to the transaction sender.
    public entry fun add_liquidity<X, Y>(
        global: &mut AMMGlobal,
        coin_x: Coin<X>,
        coin_x_min: u64,
        coin_y: Coin<Y>,
        coin_y_min: u64,
        ctx: &mut TxContext
    ) {
        assert!(!is_emergency(global), ERR_EMERGENCY);
        let is_order = is_order<X, Y>();

        assert!(!has_registered<X, Y>(global), ERR_NOT_REGISTERED);
        let pool = get_mut_pool<X, Y>(global, is_order);

        let (lp, _return_values) = add_liquidity_non_entry(
            pool,
            coin_x,
            coin_x_min,
            coin_y,
            coin_y_min,
            is_order,
            ctx
        );


        transfer::public_transfer(lp, tx_context::sender(ctx));
    }

    /// Add liquidity to the `Pool`. Sender needs to provide both
    /// `Coin<X>` and `Coin<Y>`, and in exchange he gets `Coin<LP>` -
    /// liquidity provider tokens.
    public fun add_liquidity_non_entry<X,Y>(
        pool: &mut Pool<X, Y>,
        coin_x: Coin<X>,
        coin_x_min: u64,
        coin_y: Coin<Y>,
        coin_y_min: u64,
        is_order: bool,
        ctx: &mut TxContext
    ): (Coin<LP<X, Y>>, vector<u64>) {
        assert!(is_order, ERR_MUST_BE_ORDER);

        let coin_x_value = coin::value(&coin_x);
        let coin_y_value = coin::value(&coin_y);

        assert!(coin_x_value > 0 && coin_y_value > 0, ERR_ZERO_AMOUNT);

        let coin_x_balance = coin::into_balance(coin_x);
        let coin_y_balance = coin::into_balance(coin_y);

        let (coin_x_reserve, coin_y_reserve, lp_supply) = get_reserves_size(pool);

        let (optimal_coin_x, optimal_coin_y) = calc_optimal_coin_values(
            pool,
            coin_x_value,
            coin_y_value,
            coin_x_min,
            coin_y_min,
            coin_x_reserve,
            coin_y_reserve
        );

        let provided_liq = if (0 == lp_supply) {

            let initial_liq = weighted_math::compute_initial_lp( pool.weight_x, pool.weight_y, pool.scaling_factor_x, pool.scaling_factor_y ,optimal_coin_x, optimal_coin_y );
            assert!(initial_liq > MINIMAL_LIQUIDITY, ERR_LIQUID_NOT_ENOUGH);

            let minimal_liquidity = balance::increase_supply(
                &mut pool.lp_supply,
                MINIMAL_LIQUIDITY
            );
            balance::join(&mut pool.min_liquidity, minimal_liquidity);

            initial_liq - MINIMAL_LIQUIDITY
        } else {
            let x_liq = weighted_math::compute_derive_lp( lp_supply, optimal_coin_x, pool.weight_x, pool.weight_y, pool.scaling_factor_x, coin_x_reserve );
            let y_liq = weighted_math::compute_derive_lp( lp_supply, optimal_coin_y, pool.weight_y, pool.weight_x, pool.scaling_factor_y, coin_y_reserve );

            if (x_liq < y_liq) {
                assert!(x_liq < (U64_MAX as u128), ERR_U64_OVERFLOW);
                (x_liq as u64)
            } else {
                assert!(y_liq < (U64_MAX as u128), ERR_U64_OVERFLOW);
                (y_liq as u64)
            }
        };
 
        assert!(provided_liq > 0, ERR_INSUFFICIENT_LIQUIDITY_MINTED);

        if (optimal_coin_x < coin_x_value) {
            transfer::public_transfer(
                coin::from_balance(balance::split(&mut coin_x_balance, coin_x_value - optimal_coin_x), ctx),
                tx_context::sender(ctx)
            )
        };
        if (optimal_coin_y < coin_y_value) {
            transfer::public_transfer(
                coin::from_balance(balance::split(&mut coin_y_balance, coin_y_value - optimal_coin_y), ctx),
                tx_context::sender(ctx)
            )
        };

        let coin_x_amount = balance::join(&mut pool.coin_x, coin_x_balance);
        let coin_y_amount = balance::join(&mut pool.coin_y, coin_y_balance);

        assert!(coin_x_amount < MAX_POOL_VALUE, ERR_POOL_FULL);
        assert!(coin_y_amount < MAX_POOL_VALUE, ERR_POOL_FULL);

        let balance = balance::increase_supply(&mut pool.lp_supply, provided_liq);

        let return_values = vector::empty<u64>();
        vector::push_back(&mut return_values, coin_x_value);
        vector::push_back(&mut return_values, coin_y_value);
        vector::push_back(&mut return_values, provided_liq);

        (coin::from_balance(balance, ctx), return_values)
    }

    // Registers a new liquidity pool with custom weights (only whitelist)
    public entry fun register_pool<X, Y>(
        global: &mut AMMGlobal,
        weight_x: u64,
        weight_y: u64,
        decimal_x: u8,
        decimal_y: u8,
        ctx: &mut TxContext
    ) {
        let is_order = is_order<X, Y>();
        assert!(is_order, ERR_MUST_BE_ORDER);

        // Check if authorized to register
        check_whitelist(global, tx_context::sender(ctx));

        // Check if the pool already exists
        let lp_name = generate_lp_name<X, Y>();
        let has_registered = bag::contains_with_type<String, Pool<X, Y>>(&global.pools, lp_name);
        assert!(!has_registered, ERR_POOL_HAS_REGISTERED);

        // Ensure that the normalized weights sum up to 100%
        assert!( weight_x+weight_y == 10000, ERR_WEIGHTS_SUM);
        
        // Ensure decimals are correct
        assert!( decimal_x >= 0 && decimal_x <= 9, ERR_DECIMALS);
        assert!( decimal_y >= 0 && decimal_y <= 9, ERR_DECIMALS);

        let lp_supply = balance::create_supply(LP<X, Y> {});
        let new_pool = Pool {
            global: object::uid_to_inner(&global.id),
            coin_x: balance::zero<X>(),
            coin_y: balance::zero<Y>(),
            lp_supply,
            min_liquidity: balance::zero<LP<X, Y>>(),
            weight_x,
            weight_y,
            scaling_factor_x: compute_scaling_factor(decimal_x),
            scaling_factor_y: compute_scaling_factor(decimal_y)
        };

        bag::add(&mut global.pools, lp_name, new_pool);

        // TODO: emit event
        
    }

    public fun global_id<X, Y>(pool: &Pool<X, Y>): ID {
        pool.global
    }

    public fun id<X, Y>(global: &AMMGlobal): ID {
        object::uid_to_inner(&global.id)
    }

    public fun get_mut_pool<X, Y>(
        global: &mut AMMGlobal,
        is_order: bool,
    ): &mut Pool<X, Y> {
        assert!(is_order, ERR_MUST_BE_ORDER);

        let lp_name = generate_lp_name<X, Y>();
        let has_registered = bag::contains_with_type<String, Pool<X, Y>>(&global.pools, lp_name);
        assert!(has_registered, ERR_POOL_NOT_REGISTER);

        bag::borrow_mut<String, Pool<X, Y>>(&mut global.pools, lp_name)
    }

    public fun balance_x<X,Y>(pool: &Pool<X, Y>): u64 {
        balance::value<X>(&pool.coin_x)
    }

    public fun balance_y<X,Y>(pool: &Pool<X, Y>): u64 {
        balance::value<Y>(&pool.coin_y)
    }

    public fun has_registered<X, Y>(global: &AMMGlobal): bool {
        let lp_name = generate_lp_name<X, Y>();
        bag::contains_with_type<String, Pool<X, Y>>(&global.pools, lp_name)
    }

    public fun generate_lp_name<X, Y>(): String {
        let lp_name = string::utf8(b"");
        string::append_utf8(&mut lp_name, b"LP-");

        if (is_order<X, Y>()) {
            string::append_utf8(&mut lp_name, into_bytes(into_string(get<X>())));
            string::append_utf8(&mut lp_name, b"-");
            string::append_utf8(&mut lp_name, into_bytes(into_string(get<Y>())));
        } else {
            string::append_utf8(&mut lp_name, into_bytes(into_string(get<Y>())));
            string::append_utf8(&mut lp_name, b"-");
            string::append_utf8(&mut lp_name, into_bytes(into_string(get<X>())));
        };

        lp_name
    }

    public fun is_order<X, Y>(): bool {
        let comp = comparator::compare(&get<X>(), &get<Y>());
        assert!(!comparator::is_equal(&comp), ERR_THE_SAME_COIN);

        if (comparator::is_smaller_than(&comp)) {
            true
        } else {
            false
        }
    }

    public fun is_emergency(global: &AMMGlobal): bool {
        global.has_paused
    }

    /// Calculate amounts needed for adding new liquidity for both `X` and `Y`.
    /// Returns both `X` and `Y` coins amounts.
    public fun calc_optimal_coin_values<X,Y>(
        pool: &Pool<X, Y>,
        coin_x_desired: u64,
        coin_y_desired: u64,
        coin_x_min: u64,
        coin_y_min: u64,
        coin_x_reserve: u64,
        coin_y_reserve: u64
    ): (u64, u64) {

        if (coin_x_reserve == 0 && coin_y_reserve == 0) {
            return (coin_x_desired, coin_y_desired)
        } else { 

            let coin_y_returned = weighted_math::get_optimal_value(
                coin_x_desired,
                coin_x_reserve,
                pool.weight_x,
                pool.scaling_factor_x,
                coin_y_reserve,
                pool.weight_y,
                pool.scaling_factor_y
            );

            if (coin_y_returned <= coin_y_desired) {
                assert!(coin_y_returned >= coin_y_min, ERR_INSUFFICIENT_COIN_Y);
                return (coin_x_desired, coin_y_returned)
            } else {

                let coin_x_returned = weighted_math::get_optimal_value(
                    coin_y_desired,
                    coin_y_reserve,
                    pool.weight_y,
                    pool.scaling_factor_y,
                    coin_x_reserve,
                    pool.weight_x,
                    pool.scaling_factor_x
                );

                assert!(coin_x_returned <= coin_x_desired, ERR_OVERLIMIT);
                assert!(coin_x_returned >= coin_x_min, ERR_INSUFFICIENT_COIN_X);
                return (coin_x_returned, coin_y_desired) 
            } 
        }
    }

    /// Get most used values in a handy way:
    /// - amount of Coin<X>
    /// - amount of Coin<Y>
    /// - total supply of LP<X,Y>
    public fun get_reserves_size<X, Y>(pool: &Pool<X, Y>): (u64, u64, u64) {
        (
            balance::value(&pool.coin_x),
            balance::value(&pool.coin_y),
            balance::supply_value(&pool.lp_supply)
        )
    }

    // ======== Only Governance =========

    public entry fun pause(global: &mut AMMGlobal, _manager_cap: &mut AMMManagerCap) {
        global.has_paused = true
    }

    public entry fun resume( global: &mut AMMGlobal, _manager_cap: &mut AMMManagerCap) {
        global.has_paused = false
    }

    // ensure that the new fee is within the range of 0.1% to 10%
    public entry fun update_fee(global: &mut AMMGlobal, _manager_cap: &mut AMMManagerCap, new_fee: u64) {
        assert!( new_fee >= 10 && new_fee < 1000 ,ERR_INVALID_FEE);
        global.fee_multiplier = new_fee
    }

    // add whitelist
    public entry fun add_whitelist(global: &mut AMMGlobal,  _manager_cap: &mut AMMManagerCap, user: address) {
        assert!(!vector::contains(&global.whitelist, &user),ERR_DUPLICATED_ENTRY);
        vector::push_back<address>(&mut global.whitelist, user);
    }

    // remove whitelist
    public entry fun remove_whitelist(global: &mut AMMGlobal,  _manager_cap: &mut AMMManagerCap, user: address) {
        let (contained, index) = vector::index_of<address>(&global.whitelist, &user);
        assert!(contained,ERR_NOT_FOUND);
        vector::remove<address>(&mut global.whitelist, index);
    }

    // ======== Internal Functions =========

    fun check_whitelist(global: &AMMGlobal, sender: address) {
        let (contained, _) = vector::index_of<address>(&global.whitelist, &sender);
        assert!(contained,ERR_UNAUTHORISED);
    }

    fun compute_scaling_factor(decimal: u8): u64 { 
        math::pow(10, 9-decimal)
    }

    // ======== Test-related Functions =========

    #[test_only]
    public fun test_init(ctx: &mut TxContext) {
        init(ctx);
    }

    #[test_only]
    public fun add_liquidity_for_testing<X, Y>(
        global: &mut AMMGlobal,
        coin_x: Coin<X>,
        coin_y: Coin<Y>,
        weight_x: u64,
        weight_y: u64,
        decimal_x: u8,
        decimal_y: u8,
        ctx: &mut TxContext
    ): (Coin<LP<X, Y>>, vector<u64>) {
        let is_order = is_order<X, Y>();
        if (!has_registered<X, Y>(global)) {
            register_pool<X, Y>(global, weight_x, weight_y, decimal_x, decimal_y, ctx)
        };
        let pool = get_mut_pool<X, Y>(global, is_order);

        add_liquidity_non_entry(
            pool,
            coin_x,
            1,
            coin_y,
            1,
            is_order,
            ctx
        )
    }

    #[test_only]
    public fun get_mut_pool_for_testing<X, Y>(
        global: &mut AMMGlobal
    ): &mut Pool<X, Y> {
        get_mut_pool<X, Y>(global, is_order<X, Y>())
    }

}