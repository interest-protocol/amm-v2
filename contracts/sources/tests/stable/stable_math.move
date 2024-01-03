#[test_only]
module amm::stable_math_tests {

  use sui::clock;
  use sui::tx_context;
  use sui::test_utils::assert_eq; 

  use amm::stable_math::{a};

  #[test]
  fun test_a() {
    let c = clock::create_for_testing(&mut tx_context::dummy());

    clock::set_for_testing(&mut c, 50);

    // t1 > current_time
    // A0 > A1
    assert_eq(
      a(20, 10, 15, 100, &c),
      18
    );
    
    // t1 > current_time
    // A0 > A1
    assert_eq(
      a(37, 10, 45, 100, &c),
      40
    );

    assert_eq(
      a(0, 0, 0, 0, &c),
      0
    );

    clock::set_for_testing(&mut c, 100);

    // current_time > t1
    assert_eq(
      a(0, 0, 15, 99, &c),
      15
    );

    clock::destroy_for_testing(c);
  }
}