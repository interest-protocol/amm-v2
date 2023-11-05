#[test_only]
module amm::stable_pair_tests {
  use std::vector;
  use std::option;
  use std::type_name::get;

  use sui::balance;
  use sui::test_utils::assert_eq;
  use sui::test_scenario::{Self as test, Scenario, next_tx, ctx};
  use sui::coin::{Self, mint_for_testing, burn_for_testing as burn, TreasuryCap};

  use suitears::math256::sqrt_down;
  use suitears::math64::{min, mul_div_down};
  use suitears::coin_decimals::CoinDecimals;

  use amm::stable_pair;
  use amm::stable_fees;
  use amm::stable_pair_math;
  use amm::curves::StablePair;
  use amm::usdt::USDT;
  use amm::usdc::USDC;
  use amm::lp_coin::LP_COIN;
  use amm::interest_pool::{Self, Pool};
  use amm::lp_coin_2::{Self, LP_COIN_2};
  use amm::amm_admin::Admin;
  use amm::test_utils::{people, scenario, mint, add_decimals, setup_dependencies};

  const USDC_DECIMALS: u8 = 6;
  const USDT_DECIMALS: u8 = 9;
  const MINIMUM_LIQUIDITY: u64 = 100;
  const INITIAL_FEE_PERCENT: u256 = 250000000000000; // 0.025%

  // * Success Cases

  #[test]
  fun initial_state() {
    let scenario = scenario();
    let (alice, _) = people();

    let test = &mut scenario;

    create_pool_(test);

    next_tx(test, alice);
    {
      let pool = test::take_shared<Pool<StablePair>>(test);

      let coins = interest_pool::view_coins(&pool);

      assert_eq(*vector::borrow(&coins, 0),get<USDC>());
      assert_eq(*vector::borrow(&coins, 1),get<USDT>());

      let (supply, balance_x, balance_y, admin_fee_balance_x, admin_fee_balance_y, decimals_x, decimals_y, seed_liquidity, fees) = stable_pair::view_state<USDC, USDT, LP_COIN>(&pool);

      let lp_coin_initial_user_balance = (sqrt_down(((add_decimals(100, 6) * add_decimals(100, 9)) as u256)) as u64);

      assert_eq(supply, lp_coin_initial_user_balance + seed_liquidity);
      assert_eq(balance_x, add_decimals(100, 6));
      assert_eq(balance_y, add_decimals(100, 9));
      assert_eq(admin_fee_balance_x, 0);
      assert_eq(admin_fee_balance_y, 0);
      assert_eq(decimals_x, add_decimals(1, 6));
      assert_eq(decimals_y, add_decimals(1, 9));
      assert_eq(seed_liquidity, MINIMUM_LIQUIDITY);

      let (fee_in, fee_out, fee_admin) = stable_fees::view(&fees);

      assert_eq(fee_in, INITIAL_FEE_PERCENT);
      assert_eq(fee_out, INITIAL_FEE_PERCENT);
      assert_eq(fee_admin, 0);


      test::return_shared(pool);
    };

    test::end(scenario);
  }

  #[test]
  fun swap_usdc() {
    let scenario = scenario();
    let (alice, _) = people();

    let test = &mut scenario;

    create_pool_(test);

    next_tx(test, alice);
    {
      let pool = test::take_shared<Pool<StablePair>>(test);

      let usdc_amount = 10000000; // 10

      let (_, balance_x, balance_y, _, _, decimals_x, decimals_y, _, fees) = stable_pair::view_state<USDC, USDT, LP_COIN>(&pool);

      let k = stable_pair_math::invariant_(balance_x, balance_y, decimals_x, decimals_y);

      let fee_in = stable_fees::calculate_fee_in_amount(&fees, usdc_amount);

      let amount_out = stable_pair_math::calculate_amount_out(k, usdc_amount - fee_in, balance_x, balance_y, decimals_x, decimals_y, true);

      let fee_out = stable_fees::calculate_fee_out_amount(&fees, amount_out);

      let coin_usdt = stable_pair::swap<USDC, USDT, LP_COIN>(
        &mut pool,
        mint<USDC>(10, 6, ctx(test)),
        0,
        ctx(test)
      );

      assert_eq(burn(coin_usdt), amount_out - fee_out);

      test::return_shared(pool);
    };
    test::end(scenario);  
  }

  #[test]
  fun swap_usdt() {
    let scenario = scenario();
    let (alice, _) = people();

    let test = &mut scenario;

    create_pool_(test);

    next_tx(test, alice);
    {
      let pool = test::take_shared<Pool<StablePair>>(test);

      let usdt_amount = 25000000000; // 25

      let (_, balance_x, balance_y, _, _, decimals_x, decimals_y, _, fees) = stable_pair::view_state<USDC, USDT, LP_COIN>(&pool);

      let k = stable_pair_math::invariant_(balance_x, balance_y, decimals_x, decimals_y);

      let fee_in = stable_fees::calculate_fee_in_amount(&fees, usdt_amount);

      let amount_out = stable_pair_math::calculate_amount_out(k, usdt_amount - fee_in, balance_x, balance_y, decimals_x, decimals_y, false);

      let fee_out = stable_fees::calculate_fee_out_amount(&fees, amount_out);

      let coin_usdt = stable_pair::swap<USDT, USDC, LP_COIN>(
        &mut pool,
        mint<USDT>(25, 9, ctx(test)),
        0,
        ctx(test)
      );

      assert_eq(burn(coin_usdt), amount_out - fee_out);

      test::return_shared(pool);
    };
    test::end(scenario);  
  }

  #[test]
  fun add_liquidity() {
    let scenario = scenario();
    let (alice, _) = people();

    let test = &mut scenario;

    create_pool_(test);

    next_tx(test, alice);
    {
      let pool = test::take_shared<Pool<StablePair>>(test);

      let usdc_value = add_decimals(10, 6);
      let usdt_value = add_decimals(10, 9);

      let (supply, balance_x, balance_y, _, _, _, _, _, _) = stable_pair::view_state<USDC, USDT, LP_COIN>(&pool);

      let lp_coin_amount = min(
        mul_div_down(usdc_value, supply, balance_x),
        mul_div_down(usdt_value, supply, balance_y)
      );

      let (optimal_usdc, optimal_usdt) = stable_pair_math::calculate_optimal_add_liquidity(usdc_value, usdt_value, balance_x, balance_y);

      let (lp_coin, coin_usdc, coin_usdt) = stable_pair::add_liquidity<USDC, USDT, LP_COIN>(
        &mut pool,
        mint<USDC>(10, 6, ctx(test)),
        mint<USDT>(10, 9, ctx(test)),
        0,
        ctx(test)
      );

      assert_eq(burn(lp_coin), lp_coin_amount);
      assert_eq(burn(coin_usdc), usdc_value - optimal_usdc);
      assert_eq(burn(coin_usdt), usdt_value - optimal_usdt);

      test::return_shared(pool);
    };  

     next_tx(test, alice);
    {
      let pool = test::take_shared<Pool<StablePair>>(test);

      let usdc_value = add_decimals(15, 6);
      let usdt_value = add_decimals(10, 9);

      let (supply, balance_x, balance_y, _, _, _, _, _, _) = stable_pair::view_state<USDC, USDT, LP_COIN>(&pool);

      let (optimal_usdc, optimal_usdt) = stable_pair_math::calculate_optimal_add_liquidity(usdc_value, usdt_value, balance_x, balance_y);

      let lp_coin_amount = min(
        mul_div_down(optimal_usdc, supply, balance_x),
        mul_div_down(optimal_usdt, supply, balance_y)
      );


      let (lp_coin, coin_usdc, coin_usdt) = stable_pair::add_liquidity<USDC, USDT, LP_COIN>(
        &mut pool,
        mint<USDC>(15, 6, ctx(test)),
        mint<USDT>(10, 9, ctx(test)),
        0,
        ctx(test)
      );

      let (new_supply, new_balance_x, new_balance_y, _, _, _, _, _, _) = stable_pair::view_state<USDC, USDT, LP_COIN>(&pool);

      assert_eq(burn(lp_coin), lp_coin_amount);
      assert_eq(burn(coin_usdc), usdc_value - optimal_usdc);
      assert_eq(burn(coin_usdt), usdt_value - optimal_usdt);
      assert_eq(new_supply, supply + lp_coin_amount);
      assert_eq(new_balance_x, balance_x + optimal_usdc);
      assert_eq(new_balance_y, balance_y + optimal_usdt);

      test::return_shared(pool);
    };    

    test::end(scenario);  
  }

  #[test]
  fun remove_liquidity() {
    let scenario = scenario();
    let (alice, _) = people();

    let test = &mut scenario;

    create_pool_(test);

    next_tx(test, alice);
    {
      let pool = test::take_shared<Pool<StablePair>>(test);

      let (supply, balance_x, balance_y, _, _, _, _, _, _) = stable_pair::view_state<USDC, USDT, LP_COIN>(&pool);

      let usdc_amount = mul_div_down(supply / 10, balance_x, supply);
      let usdt_amount = mul_div_down(supply / 10, balance_y, supply);

      let (coin_usdc, coin_usdt) = stable_pair::remove_liquidity<USDC, USDT, LP_COIN>(
        &mut pool,
        mint_for_testing(supply / 10, ctx(test)),
        0,
           0,
           ctx(test)
      );

      let (new_supply, new_balance_x, new_balance_y, _, _, _, _, _, _) = stable_pair::view_state<USDC, USDT, LP_COIN>(&pool);

      assert_eq(burn(coin_usdc), usdc_amount);
      assert_eq(burn(coin_usdt), usdt_amount);
      assert_eq(new_supply, supply - (supply / 10));
      assert_eq(new_balance_x, balance_x - usdc_amount);
      assert_eq(new_balance_y, balance_y - usdt_amount);

      test::return_shared(pool);
    };    
    test::end(scenario);  
  }

  #[test]
  fun fee_logic() {
    let scenario = scenario();
    let (alice, _) = people();

    let test = &mut scenario;

    create_pool_(test);

    next_tx(test, alice);
    {
      let pool = test::take_shared<Pool<StablePair>>(test);
      let admin_cap = test::take_from_sender<Admin>(test);
      
      let (_, _, _, _, _, _, _, _, fees) = stable_pair::view_state<USDC, USDT, LP_COIN>(&pool);     

      let (fee_in, fee_out, _) = stable_fees::view(&fees); 

      stable_pair::update_fee<USDC, USDT, LP_COIN>(
        &admin_cap,
        &mut pool,
        option::some(fee_in * 10),
        option::some(fee_out * 7),
        option::some(fee_in)
      );

      let (_, _, _, _, _, _, _, _, new_fees) = stable_pair::view_state<USDC, USDT, LP_COIN>(&pool);     

      let (new_fee_in, new_fee_out, new_fee_admin) = stable_fees::view(&new_fees); 

      assert_eq(new_fee_in, fee_in * 10);
      assert_eq(new_fee_out, fee_out * 7);
      assert_eq(new_fee_admin, fee_in);

      test::return_to_sender(test, admin_cap);
      test::return_shared(pool);
    };

    next_tx(test, alice);
    {
      let pool = test::take_shared<Pool<StablePair>>(test);
      let admin_cap = test::take_from_sender<Admin>(test);

      let (_, _, _, admin_balance_x, admin_balance_y, _, _, _, _) = stable_pair::view_state<USDC, USDT, LP_COIN>(&pool);

      assert_eq(admin_balance_x, 0);
      assert_eq(admin_balance_y, 0);

      burn(stable_pair::swap<USDC, USDT, LP_COIN>(
        &mut pool,
        mint<USDC>(10, 6, ctx(test)),
        0,
        ctx(test)
      ));


      burn(stable_pair::swap<USDC, USDT, LP_COIN>(
        &mut pool,
        mint<USDC>(10, 6, ctx(test)),
        0,
        ctx(test)
      ));

      let (_, _, _, admin_balance_x, admin_balance_y, _, _, _, _) = stable_pair::view_state<USDC, USDT, LP_COIN>(&pool);

      let (coin_usdc, coin_usdt) = stable_pair::take_fees<USDC, USDT, LP_COIN>(&admin_cap, &mut pool, ctx(test));

      assert_eq(admin_balance_x > 0, true);
      assert_eq(admin_balance_y > 0, true);
      assert_eq(burn(coin_usdc), admin_balance_x);
      assert_eq(burn(coin_usdt), admin_balance_y);

      test::return_to_sender(test, admin_cap);
      test::return_shared(pool);
    };

    test::end(scenario);  
  }

  // * Error Cases

  #[test]
  #[expected_failure(abort_code = 8)]  
  fun create_pool_with_non_zero_supply() {
    let scenario = scenario();
    let (alice, _) = people();

    let test = &mut scenario;

    create_pool_(test);

    next_tx(test, alice);
    {
      lp_coin_2::init_for_testing(ctx(test));
    };

    next_tx(test, alice);
    {
      let coin_decimals = test::take_shared<CoinDecimals>(test);
      let lp_coin_cap = test::take_from_sender<TreasuryCap<LP_COIN_2>>(test);
      let supply = coin::treasury_into_supply(lp_coin_cap);
      burn(coin::from_balance(balance::increase_supply(&mut supply, 1), ctx(test)));

      burn(stable_pair::new(
        mint<USDC>(100, USDC_DECIMALS, ctx(test)),
        mint<USDT>(100, USDT_DECIMALS, ctx(test)),
        supply,
        &coin_decimals,
        ctx(test)
      ));

      test::return_shared(coin_decimals);
    };

    test::end(scenario); 
  }

  #[test]
  #[expected_failure(abort_code = 9)]  
  fun create_pool_with_zero_usdc() {
    let scenario = scenario();
    let (alice, _) = people();

    let test = &mut scenario;

    create_pool_(test);

    next_tx(test, alice);
    {
      lp_coin_2::init_for_testing(ctx(test));
    };

    next_tx(test, alice);
    {
      let coin_decimals = test::take_shared<CoinDecimals>(test);
      let lp_coin_cap = test::take_from_sender<TreasuryCap<LP_COIN_2>>(test);
      let supply = coin::treasury_into_supply(lp_coin_cap);

      burn(stable_pair::new(
        coin::zero<USDC>(ctx(test)),
        mint<USDT>(100, USDT_DECIMALS, ctx(test)),
        supply,
        &coin_decimals,
        ctx(test)
      ));
      
      test::return_shared(coin_decimals);
    };

    test::end(scenario); 
  }

  #[test]
  #[expected_failure(abort_code = 9)]  
  fun create_pool_with_zero_usdt() {
    let scenario = scenario();
    let (alice, _) = people();

    let test = &mut scenario;

    create_pool_(test);

    next_tx(test, alice);
    {
      lp_coin_2::init_for_testing(ctx(test));
    };

    next_tx(test, alice);
    {
      let coin_decimals = test::take_shared<CoinDecimals>(test);
      let lp_coin_cap = test::take_from_sender<TreasuryCap<LP_COIN_2>>(test);
      let supply = coin::treasury_into_supply(lp_coin_cap);

      burn(stable_pair::new(
        mint<USDC>(100, USDC_DECIMALS, ctx(test)),
        coin::zero<USDT>(ctx(test)),
        supply,
        &coin_decimals,
        ctx(test)
      ));
      
      test::return_shared(coin_decimals);
    };

    test::end(scenario); 
  }

  #[test]
  #[expected_failure(abort_code = 11)]  
  fun swap_usdt_high_min_amount() {
    let scenario = scenario();
    let (alice, _) = people();

    let test = &mut scenario;

    create_pool_(test);

    next_tx(test, alice);
    {

      let pool = test::take_shared<Pool<StablePair>>(test);

      let usdt_amount = 25000000000; // 25

      let (_, balance_x, balance_y, _, _, decimals_x, decimals_y, _, fees) = stable_pair::view_state<USDC, USDT, LP_COIN>(&pool);

      let k = stable_pair_math::invariant_(balance_x, balance_y, decimals_x, decimals_y);

      let fee_in = stable_fees::calculate_fee_in_amount(&fees, usdt_amount);

      let amount_out = stable_pair_math::calculate_amount_out(k, usdt_amount - fee_in, balance_x, balance_y, decimals_x, decimals_y, false);

      burn(stable_pair::swap<USDT, USDC, LP_COIN>(
        &mut pool,
        mint<USDT>(25, 9, ctx(test)),
        amount_out, // too high because we did not remove the fee_out
        ctx(test)
      ));

      test::return_shared(pool);
    };
    test::end(scenario); 
  }

  #[test]
  #[expected_failure(abort_code = 13)]  
  fun add_liquidity_with_zero_usdc() {
    let scenario = scenario();
    let (alice, _) = people();

    let test = &mut scenario;

    create_pool_(test);

    next_tx(test, alice);
    {
     let pool = test::take_shared<Pool<StablePair>>(test);


      let (lp_coin, coin_usdc, coin_usdt) = stable_pair::add_liquidity<USDC, USDT, LP_COIN>(
        &mut pool,
        coin::zero<USDC>(ctx(test)),
        mint<USDT>(10, 9, ctx(test)),
        0,
        ctx(test)
      );

      burn(lp_coin);
      burn(coin_usdc);
      burn(coin_usdt);
      test::return_shared(pool);      
    };
    test::end(scenario); 
  }

  #[test]
  #[expected_failure(abort_code = 13)]  
  fun add_liquidity_with_zero_usdt() {
    let scenario = scenario();
    let (alice, _) = people();

    let test = &mut scenario;

    create_pool_(test);

    next_tx(test, alice);
    {
     let pool = test::take_shared<Pool<StablePair>>(test);


      let (lp_coin, coin_usdc, coin_usdt) = stable_pair::add_liquidity<USDC, USDT, LP_COIN>(
        &mut pool,
        mint<USDC>(15, 6, ctx(test)),
        coin::zero<USDT>(ctx(test)),
        0,
        ctx(test)
      );

      burn(lp_coin);
      burn(coin_usdc);
      burn(coin_usdt);
      test::return_shared(pool);      
    };
    test::end(scenario); 
  }

  #[test]
  #[expected_failure(abort_code = 11)] 
  fun add_liquidity_slippage() {
        let scenario = scenario();
    let (alice, _) = people();

    let test = &mut scenario;

    create_pool_(test);

    next_tx(test, alice);
    {
      let pool = test::take_shared<Pool<StablePair>>(test);

      let usdc_value = add_decimals(10, 6);
      let usdt_value = add_decimals(10, 9);

      let (supply, balance_x, balance_y, _, _, _, _, _, _) = stable_pair::view_state<USDC, USDT, LP_COIN>(&pool);

      let lp_coin_amount = min(
        mul_div_down(usdc_value, supply, balance_x),
        mul_div_down(usdt_value, supply, balance_y)
      );

      let (lp_coin, coin_usdc, coin_usdt) = stable_pair::add_liquidity<USDC, USDT, LP_COIN>(
        &mut pool,
        mint<USDC>(10, 6, ctx(test)),
        mint<USDT>(10, 9, ctx(test)),
        lp_coin_amount + 1,
        ctx(test)
      );

      burn(lp_coin);
      burn(coin_usdc);
      burn(coin_usdt);

      test::return_shared(pool);
    };  

    test::end(scenario); 
  }

  #[test]
  #[expected_failure(abort_code = 14)] 
  fun remove_liquidity_zero_lp_coin() {
    let scenario = scenario();
    let (alice, _) = people();

    let test = &mut scenario;

    create_pool_(test);

    next_tx(test, alice);
    {
      let pool = test::take_shared<Pool<StablePair>>(test);

      let (coin_usdc, coin_usdt) = stable_pair::remove_liquidity<USDC, USDT, LP_COIN>(
        &mut pool,
        coin::zero(ctx(test)),
        0,
           0,
           ctx(test)
      );

      burn(coin_usdc);
      burn(coin_usdt);

      test::return_shared(pool);
    };    
    test::end(scenario);  
  }

  #[test]
  #[expected_failure(abort_code = 11)] 
  fun remove_liquidity_usdc_slippage() {
    let scenario = scenario();
    let (alice, _) = people();

    let test = &mut scenario;

    create_pool_(test);

    next_tx(test, alice);
    {
      let pool = test::take_shared<Pool<StablePair>>(test);

      let (supply, balance_x, _, _, _, _, _, _, _) = stable_pair::view_state<USDC, USDT, LP_COIN>(&pool);

      let usdc_amount = mul_div_down(supply / 10, balance_x, supply);

      let (coin_usdc, coin_usdt) = stable_pair::remove_liquidity<USDC, USDT, LP_COIN>(
        &mut pool,
        mint_for_testing(supply / 10, ctx(test)),
        usdc_amount + 1,
           0,
           ctx(test)
      );

      burn(coin_usdc);
      burn(coin_usdt);

      test::return_shared(pool);
    };    
    test::end(scenario);  
  }

  #[test]
  #[expected_failure(abort_code = 11)] 
  fun remove_liquidity_usdt_slippage() {
    let scenario = scenario();
    let (alice, _) = people();

    let test = &mut scenario;

    create_pool_(test);

    next_tx(test, alice);
    {
      let pool = test::take_shared<Pool<StablePair>>(test);

      let (supply, _, balance_y, _, _, _, _, _, _) = stable_pair::view_state<USDC, USDT, LP_COIN>(&pool);

      let usdt_amount = mul_div_down(supply / 10, balance_y, supply);

      let (coin_usdc, coin_usdt) = stable_pair::remove_liquidity<USDC, USDT, LP_COIN>(
        &mut pool,
        mint_for_testing(supply / 10, ctx(test)),
        0,
           usdt_amount + 1,
           ctx(test)
      );

      burn(coin_usdc);
      burn(coin_usdt);

      test::return_shared(pool);
    };    
    test::end(scenario);  
  }

  // Set up

  fun create_pool_(test: &mut Scenario) {
    let (alice, _) = people();

    setup_dependencies(test);

    next_tx(test, alice);
    {
      let coin_decimals = test::take_shared<CoinDecimals>(test);
      let lp_coin_cap = test::take_from_sender<TreasuryCap<LP_COIN>>(test);

      let lp_coin = stable_pair::new(
        mint<USDC>(100, USDC_DECIMALS, ctx(test)),
        mint<USDT>(100, USDT_DECIMALS, ctx(test)),
        coin::treasury_into_supply(lp_coin_cap),
        &coin_decimals,
        ctx(test)
      );

       let lp_coin_initial_user_balance = (sqrt_down(((add_decimals(100, 6) * add_decimals(100, 9)) as u256)) as u64);

      assert_eq(burn(lp_coin), lp_coin_initial_user_balance);

      test::return_shared(coin_decimals);
    };
  }
}