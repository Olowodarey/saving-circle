 use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use save_circle::contracts::Savecircle::SaveCircle;
use save_circle::enums::Enums::{GroupState, LockType, TimeUnit};
use save_circle::events::Events::{ContributionMade, FundsWithdrawn};
use save_circle::interfaces::Isavecircle::{IsavecircleDispatcher, IsavecircleDispatcherTrait};
use snforge_std::{
    ContractClassTrait, DeclareResultTrait, EventSpyAssertionsTrait, declare, spy_events,
    start_cheat_block_timestamp, start_cheat_caller_address, stop_cheat_block_timestamp,
    stop_cheat_caller_address,
};
use starknet::{ContractAddress, contract_address_const};

fn setup() -> (ContractAddress, ContractAddress, ContractAddress) {
    // create default admin address
    let owner: ContractAddress = contract_address_const::<1>();

    // Deploy mock token for payment
    let token_class = declare("MockToken").unwrap().contract_class();
    let (token_address, _) = token_class.deploy(@array![owner.into(), owner.into()]).unwrap();

    // deploy savecircle contract
    let declare_result = declare("SaveCircle");
    assert(declare_result.is_ok(), 'contract declaration failed');

    let contract_class = declare_result.unwrap().contract_class();
    let mut calldata = array![owner.into(), token_address.into()];

    let deploy_result = contract_class.deploy(@calldata);
    assert(deploy_result.is_ok(), 'contract deployment failed');

    let (contract_address, _) = deploy_result.unwrap();

    (contract_address, owner, token_address)
}

fn setup_user_and_group(
    contract_address: ContractAddress,
    token_address: ContractAddress,
    owner: ContractAddress,
    user: ContractAddress,
    contribution_amount: u256,
    token_amount: u256,
    cycle_unit: TimeUnit,
    cycle_duration: u64,
) -> u256 {
    let dispatcher = IsavecircleDispatcher { contract_address };
    let token_dispatcher = IERC20Dispatcher { contract_address: token_address };

    // Register user
    start_cheat_caller_address(contract_address, user);
    dispatcher.register_user("TestUser", "avatar.png");

    // Create a group
    start_cheat_caller_address(contract_address, owner);
    dispatcher.register_user("Owner", "owner.png");

    let group_id = dispatcher
        .create_public_group(
            "Test Group",
            "A test group for withdrawal testing",
            10,
            contribution_amount,
            LockType::None,
            cycle_duration,
            cycle_unit,
            false,
            0,
        );

    // Activate the group
    dispatcher.activate_group(group_id);

    // Join the group as user
    start_cheat_caller_address(contract_address, user);
    dispatcher.join_group(group_id);
    stop_cheat_caller_address(contract_address);

    // Transfer tokens to user for testing
    start_cheat_caller_address(token_address, owner);
    token_dispatcher.transfer(user, token_amount);
    stop_cheat_caller_address(token_address);

    // User approves contract to spend tokens
    start_cheat_caller_address(token_address, user);
    token_dispatcher.approve(contract_address, token_amount);
    stop_cheat_caller_address(token_address);

    // Lock liquidity for the user
    start_cheat_caller_address(contract_address, user);
    dispatcher.lock_liquidity(token_address, contribution_amount, group_id);
    stop_cheat_caller_address(contract_address);

    group_id
}


#[test]
fn test_multiple_users_lock_funds() {
    let (contract_address, owner, token_address) = setup();
    let dispatcher = IsavecircleDispatcher { contract_address };
    let token_dispatcher = IERC20Dispatcher { contract_address: token_address };

    let user1: ContractAddress = contract_address_const::<2>();
    let user2: ContractAddress = contract_address_const::<3>();
    let user3: ContractAddress = contract_address_const::<4>();
    let contribution_amount = 100_u256;
    let token_amount = 100000_u256;
    let total_lock_amount = 300_u256;

    // Setup first user and group
    let group_id = setup_user_and_group(
        contract_address,
        token_address,
        owner,
        user1,
        contribution_amount,
        token_amount,
        TimeUnit::Days,
        1,
    );

    // Setup second user
    start_cheat_caller_address(contract_address, user2);
    dispatcher.register_user("TestUser2", "avatar2.png");
    dispatcher.join_group(group_id);
    stop_cheat_caller_address(contract_address);

    // Transfer tokens to user2
    start_cheat_caller_address(token_address, owner);
    token_dispatcher.transfer(user2, token_amount);
    stop_cheat_caller_address(token_address);

    // User2 approves contract to spend tokens
    start_cheat_caller_address(token_address, user2);
    token_dispatcher.approve(contract_address, token_amount);
    stop_cheat_caller_address(token_address);

    // User2 locks liquidity
    start_cheat_caller_address(contract_address, user2);
    dispatcher.lock_liquidity(token_address, contribution_amount, group_id);
    stop_cheat_caller_address(contract_address);

    // Setup third user
    start_cheat_caller_address(contract_address, user3);
    dispatcher.register_user("TestUser3", "avatar3.png");
    dispatcher.join_group(group_id);
    stop_cheat_caller_address(contract_address);

    // Transfer tokens to user3
    start_cheat_caller_address(token_address, owner);
    token_dispatcher.transfer(user3, token_amount);
    stop_cheat_caller_address(token_address);

    // User3 approves contract to spend tokens
    start_cheat_caller_address(token_address, user3);
    token_dispatcher.approve(contract_address, token_amount);
    stop_cheat_caller_address(token_address);

    // User3 locks liquidity
    start_cheat_caller_address(contract_address, user3);
    dispatcher.lock_liquidity(token_address, contribution_amount, group_id);
    stop_cheat_caller_address(contract_address);

    // Check individual locked balances
    let user1_locked = dispatcher.get_locked_balance(user1);
    let user2_locked = dispatcher.get_locked_balance(user2);
    let user3_locked = dispatcher.get_locked_balance(user3);

    assert(user1_locked == contribution_amount, 'User1 locked amount wrong');
    assert(user2_locked == contribution_amount, 'User2 locked amount wrong');
    assert(user3_locked == contribution_amount, 'User3 locked amount wrong');

    // Check total group locked funds
    let (total_locked, member_funds) = dispatcher.get_group_locked_funds(group_id);
    assert(total_locked == total_lock_amount, 'Total locked incorrect');
    assert(member_funds.len() == 3, 'Should have 3 members');
}

// #[test]
// #[should_panic(expected: ('Group cycle must be complete',))]
// fn test_withdrawal_after_payout() {
//     let (contract_address, owner, token_address) = setup();
//     let dispatcher = IsavecircleDispatcher { contract_address };
//     let token_dispatcher = IERC20Dispatcher { contract_address: token_address };

//     let user1: ContractAddress = contract_address_const::<2>();
//     let user2: ContractAddress = contract_address_const::<3>();
//     let contribution_amount = 1000_u256;
//     let token_amount = 10000_u256;

//     // Setup users and group
//     let group_id = setup_user_and_group(
//         contract_address,
//         token_address,
//         owner,
//         user1,
//         contribution_amount,
//         token_amount,
//         TimeUnit::Days,
//         1,
//     );

//     // Add second user
//     start_cheat_caller_address(contract_address, user2);
//     dispatcher.register_user("TestUser2", "avatar2.png");
//     dispatcher.join_group(group_id);
//     stop_cheat_caller_address(contract_address);

//     // Transfer tokens to user2
//     start_cheat_caller_address(token_address, owner);
//     token_dispatcher.transfer(user2, token_amount);
//     stop_cheat_caller_address(token_address);

//     // User2 approves contract to spend tokens
//     start_cheat_caller_address(token_address, user2);
//     token_dispatcher.approve(contract_address, token_amount);
//     stop_cheat_caller_address(token_address);

//     // User2 locks liquidity
//     start_cheat_caller_address(contract_address, user2);
//     dispatcher.lock_liquidity(token_address, contribution_amount, group_id);
//     stop_cheat_caller_address(contract_address);

//     // Both users contribute
//     start_cheat_caller_address(contract_address, user1);
//     dispatcher.contribute(group_id);
//     start_cheat_caller_address(contract_address, user2);
//     dispatcher.contribute(group_id);

//     // Simulate payout distribution (owner distributes payout)
//     start_cheat_caller_address(contract_address, owner);
//     dispatcher.distribute_payout(group_id);

//     // Move time to end of cycle
//     let cycle_end_time = 1000_u64 + 86400 + 1; // 1 day + 1 second
//     start_cheat_block_timestamp(contract_address, cycle_end_time);

//     // Complete the group cycle
//     let mut group_info = dispatcher.get_group_info(group_id);

//     let initial_balance = token_dispatcher.balance_of(user1);

//     start_cheat_caller_address(contract_address, user1);

//     let withdrawn_amount = dispatcher.withdraw_locked(group_id);

//     let final_balance = token_dispatcher.balance_of(user1);
//     assert(final_balance > initial_balance, 'Balance should increase');
//     assert(withdrawn_amount > 0, 'Should withdraw some amount');

//     stop_cheat_block_timestamp(contract_address);
// }

// #[test]
// fn test_contribution_deadline_tracking_daily() {
//     let (contract_address, owner, token_address) = setup();
//     let dispatcher = IsavecircleDispatcher { contract_address };
//     let token_dispatcher = IERC20Dispatcher { contract_address: token_address };

//     let user: ContractAddress = contract_address_const::<2>();
//     let contribution_amount = 1000_u256;
//     let token_amount = 10000_u256;

//     // Setup with daily contributions
//     let group_id = setup_user_and_group(
//         contract_address,
//         token_address,
//         owner,
//         user,
//         contribution_amount,
//         token_amount,
//         TimeUnit::Days,
//         1,
//     );

//     // Set initial timestamp
//     let initial_time = 1000_u64;
//     start_cheat_block_timestamp(contract_address, initial_time);

//     start_cheat_caller_address(contract_address, user);
//     dispatcher.contribute(group_id);

//     // Check deadline is set to 22 hours from now (22 * 3600 = 79200 seconds)
//     let deadline = dispatcher.get_contribution_deadline(group_id, user);
//     assert(deadline == initial_time + 93600, 'Daily deadline 22h');

//     // Check time until deadline
//     let time_until = dispatcher.get_time_until_deadline(group_id, user);
//     assert(time_until == 93600, 'Time until deadline wrong');

//     stop_cheat_block_timestamp(contract_address);
// }

#[test]
fn test_contribution_deadline_tracking_weekly() {
    let (contract_address, owner, token_address) = setup();
    let dispatcher = IsavecircleDispatcher { contract_address };
    let token_dispatcher = IERC20Dispatcher { contract_address: token_address };

    let user: ContractAddress = contract_address_const::<2>();
    let contribution_amount = 1000_u256;
    let token_amount = 10000_u256;

    // Setup with weekly contributions
    let group_id = setup_user_and_group(
        contract_address,
        token_address,
        owner,
        user,
        contribution_amount,
        token_amount,
        TimeUnit::Weeks,
        1,
    );

    let initial_time = 1000_u64;
    start_cheat_block_timestamp(contract_address, initial_time);

    start_cheat_caller_address(contract_address, user);
    dispatcher.contribute(group_id);

    // Check deadline is set to 6 days from now (7 * 86400 + 2 * 3600 = 622800 seconds)
    let deadline = dispatcher.get_contribution_deadline(group_id, user);
    assert(deadline == initial_time + 622800, 'Weekly deadline 6d');

    stop_cheat_block_timestamp(contract_address);
}

#[test]
fn test_contribution_deadline_tracking_monthly() {
    let (contract_address, owner, token_address) = setup();
    let dispatcher = IsavecircleDispatcher { contract_address };
    let token_dispatcher = IERC20Dispatcher { contract_address: token_address };

    let user: ContractAddress = contract_address_const::<2>();
    let contribution_amount = 1000_u256;
    let token_amount = 10000_u256;

    // Setup with monthly contributions
    let group_id = setup_user_and_group(
        contract_address,
        token_address,
        owner,
        user,
        contribution_amount,
        token_amount,
        TimeUnit::Months,
        1,
    );

    let initial_time = 1000_u64;
    start_cheat_block_timestamp(contract_address, initial_time);

    start_cheat_caller_address(contract_address, user);
    dispatcher.contribute(group_id);

    // Check deadline is set to 30 days + 24 hours from now (30 * 86400 + 24 * 3600 = 2678400
    // seconds)
    let deadline = dispatcher.get_contribution_deadline(group_id, user);
    assert(deadline == initial_time + 2678400, 'Monthly deadline 30d+24h');

    stop_cheat_block_timestamp(contract_address);
}

// #[test]
// fn test_missed_deadline_penalty() {
//     let (contract_address, owner, token_address) = setup();
//     let dispatcher = IsavecircleDispatcher { contract_address };
//     let token_dispatcher = IERC20Dispatcher { contract_address: token_address };

//     let user: ContractAddress = contract_address_const::<2>();
//     let contribution_amount = 1000_u256;
//     let token_amount = 20000_u256; // More tokens for penalty

//     let group_id = setup_user_and_group(
//         contract_address,
//         token_address,
//         owner,
//         user,
//         contribution_amount,
//         token_amount,
//         TimeUnit::Days,
//         1,
//     );

//     // Set initial timestamp
//     let initial_time = 1000_u64;
//     start_cheat_block_timestamp(contract_address, initial_time);

//     start_cheat_caller_address(contract_address, user);
//     dispatcher.contribute(group_id);

//     // Move time forward past the deadline (26 hours + 1 hour = 27 hours)
//     let late_time = initial_time + 97200; // 27 hours
//     start_cheat_block_timestamp(contract_address, late_time);

//     // Check that deadline has passed
//     let time_until = dispatcher.get_time_until_deadline(group_id, user);
//     assert(time_until == 0, 'Deadline should have passed');

//     // Make another contribution (should apply penalty)
//     let balance_before = token_dispatcher.balance_of(user);
//     dispatcher.contribute(group_id);
//     let balance_after = token_dispatcher.balance_of(user);

//     // Calculate expected penalty (5% of contribution amount)
//     let expected_penalty = (contribution_amount * 500) / 10000; // 5%
//     let expected_total_payment = contribution_amount
//         + (contribution_amount / 100)
//         + expected_penalty; // contribution + 1% insurance + 5% penalty

//     assert(
//         balance_before - balance_after == expected_total_payment, 'Penalty not applied correctly',
//     );

//     // Check penalty is tracked
//     let tracked_penalty = dispatcher.get_missed_deadline_penalty(group_id, user);
//     assert(tracked_penalty == expected_penalty, 'Penalty not tracked correctly');

//     stop_cheat_block_timestamp(contract_address);
// }

#[test]
fn test_get_group_locked_funds() {
    let (contract_address, owner, token_address) = setup();
    let dispatcher = IsavecircleDispatcher { contract_address };
    let token_dispatcher = IERC20Dispatcher { contract_address: token_address };

    let user1: ContractAddress = contract_address_const::<2>();
    let user2: ContractAddress = contract_address_const::<3>();
    let contribution_amount = 1000_u256;
    let token_amount = 10000_u256;

    // Setup first user and group
    let group_id = setup_user_and_group(
        contract_address,
        token_address,
        owner,
        user1,
        contribution_amount,
        token_amount,
        TimeUnit::Days,
        1,
    );

    // Setup second user
    start_cheat_caller_address(contract_address, user2);
    dispatcher.register_user("TestUser2", "avatar2.png");
    dispatcher.join_group(group_id);
    stop_cheat_caller_address(contract_address);

    // Transfer tokens to user2
    start_cheat_caller_address(token_address, owner);
    token_dispatcher.transfer(user2, token_amount);
    stop_cheat_caller_address(token_address);

    // User2 approves contract to spend tokens
    start_cheat_caller_address(token_address, user2);
    token_dispatcher.approve(contract_address, token_amount);
    stop_cheat_caller_address(token_address);

    // User2 locks liquidity
    start_cheat_caller_address(contract_address, user2);
    dispatcher.lock_liquidity(token_address, contribution_amount, group_id);
    stop_cheat_caller_address(contract_address);

    // Both users contribute
    start_cheat_caller_address(contract_address, user1);
    dispatcher.contribute(group_id);

    start_cheat_caller_address(contract_address, user2);
    dispatcher.contribute(group_id);

    // Check group locked funds
    let (total_locked, member_funds) = dispatcher.get_group_locked_funds(group_id);

    assert(total_locked == contribution_amount * 2, 'Total locked funds incorrect');
    assert(member_funds.len() == 2, 'Should have 2 members');

    // Verify individual member funds
    let (member1_addr, member1_amount) = *member_funds.at(0);
    let (member2_addr, member2_amount) = *member_funds.at(1);

    assert(member1_amount == contribution_amount, 'Member 1 amount incorrect');
    assert(member2_amount == contribution_amount, 'Member 2 amount incorrect');
}

// #[test]
// fn test_time_progression_and_multiple_contributions() {
//     let (contract_address, owner, token_address) = setup();
//     let dispatcher = IsavecircleDispatcher { contract_address };
//     let token_dispatcher = IERC20Dispatcher { contract_address: token_address };

//     let user: ContractAddress = contract_address_const::<2>();
//     let contribution_amount = 1000_u256;
//     let token_amount = 50000_u256; // Enough for multiple contributions

//     let group_id = setup_user_and_group(
//         contract_address,
//         token_address,
//         owner,
//         user,
//         contribution_amount,
//         token_amount,
//         TimeUnit::Days,
//         1,
//     );

//     let initial_time = 1000_u64;
//     start_cheat_block_timestamp(contract_address, initial_time);

//     start_cheat_caller_address(contract_address, user);

//     // First contribution
//     dispatcher.contribute(group_id);
//     let first_deadline = dispatcher.get_contribution_deadline(group_id, user);

//     // Move time forward 20 hours (within deadline)
//     let second_time = initial_time + 72000; // 20 hours
//     start_cheat_block_timestamp(contract_address, second_time);

//     // Second contribution (on time)
//     dispatcher.contribute(group_id);
//     let second_deadline = dispatcher.get_contribution_deadline(group_id, user);

//     // Verify new deadline is set
//     assert(second_deadline > first_deadline, 'New deadline should be later');
//     assert(
//         second_deadline == second_time + 93600, 'Second deadline incorrect',
//     ); // 26 hours from second contribution

//     // Check no penalty accumulated
//     let penalty = dispatcher.get_missed_deadline_penalty(group_id, user);
//     assert(penalty == 0, 'No penalty on-time');

//     stop_cheat_block_timestamp(contract_address);
// }

#[test]
fn test_contribution_and_lock_tracking() {
    let (contract_address, owner, token_address) = setup();
    let dispatcher = IsavecircleDispatcher { contract_address };
    let token_dispatcher = IERC20Dispatcher { contract_address: token_address };

    let user1: ContractAddress = contract_address_const::<2>();
    let user2: ContractAddress = contract_address_const::<3>();
    let contribution_amount = 1000_u256;
    let token_amount = 10000_u256;

    // Setup users and group
    let group_id = setup_user_and_group(
        contract_address,
        token_address,
        owner,
        user1,
        contribution_amount,
        token_amount,
        TimeUnit::Days,
        1,
    );

    // Add second user
    start_cheat_caller_address(contract_address, user2);
    dispatcher.register_user("TestUser2", "avatar2.png");
    dispatcher.join_group(group_id);
    stop_cheat_caller_address(contract_address);

    // Transfer tokens to user2
    start_cheat_caller_address(token_address, owner);
    token_dispatcher.transfer(user2, token_amount);
    stop_cheat_caller_address(token_address);

    // User2 approves contract to spend tokens
    start_cheat_caller_address(token_address, user2);
    token_dispatcher.approve(contract_address, token_amount);
    stop_cheat_caller_address(token_address);

    // User2 locks liquidity
    start_cheat_caller_address(contract_address, user2);
    dispatcher.lock_liquidity(token_address, contribution_amount, group_id);
    stop_cheat_caller_address(contract_address);

    // Check locked funds before contributions
    let (total_before, _) = dispatcher.get_group_locked_funds(group_id);
    assert(total_before == contribution_amount * 2, 'Initial lock incorrect');

    // Users make contributions
    start_cheat_caller_address(contract_address, user1);
    dispatcher.contribute(group_id);

    start_cheat_caller_address(contract_address, user2);
    dispatcher.contribute(group_id);

    // Check that locked funds are still tracked correctly after contributions
    let (total_after, member_funds) = dispatcher.get_group_locked_funds(group_id);
    assert(total_after == contribution_amount * 2, 'Lock after contrib incorrect');
    assert(member_funds.len() == 2, 'Should have 2 members');

    // Verify individual member data
    let member1 = dispatcher.get_group_member(group_id, 0);
    let member2 = dispatcher.get_group_member(group_id, 1);

    assert(member1.contribution_count == 1, 'User1 contrib count wrong');
    assert(member2.contribution_count == 1, 'User2 contrib count wrong');
    assert(member1.total_contributed == contribution_amount, 'User1 total wrong');
    assert(member2.total_contributed == contribution_amount, 'User2 total wrong');
}
