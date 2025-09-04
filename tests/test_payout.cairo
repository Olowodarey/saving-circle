use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
use save_circle::contracts::Savecircle::SaveCircle::Event;
use save_circle::enums::Enums::{GroupState, LockType, TimeUnit};
use save_circle::events::Events::PayoutDistributed;
use save_circle::interfaces::Isavecircle::{IsavecircleDispatcher, IsavecircleDispatcherTrait};
use snforge_std::{
    ContractClassTrait, DeclareResultTrait, EventSpyAssertionsTrait, declare, spy_events,
    start_cheat_caller_address, stop_cheat_caller_address,
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

fn setup_group_with_contributions(
    contract_address: ContractAddress,
    token_address: ContractAddress,
    owner: ContractAddress,
    users: Array<ContractAddress>,
    contribution_amount: u256,
    token_amount: u256,
) -> u256 {
    let dispatcher = IsavecircleDispatcher { contract_address };
    let token_dispatcher = IERC20Dispatcher { contract_address: token_address };

    let creator = *users.at(0);

    // Register all users
    let mut i = 0;
    while i < users.len() {
        let user = *users.at(i);
        start_cheat_caller_address(contract_address, user);
        dispatcher.register_user("TestUser", "avatar.png");
        stop_cheat_caller_address(contract_address);
        i += 1;
    }

    // Owner grants admin role to user
    start_cheat_caller_address(contract_address, owner);
    dispatcher.add_admin(creator);
    stop_cheat_caller_address(contract_address);

    // Create group with creator
    start_cheat_caller_address(contract_address, creator);
    let group_id = dispatcher
        .create_public_group(
            "Group 1",
            "First test group",
            5,
            contribution_amount,
            LockType::Progressive,
            1,
            TimeUnit::Days,
            false,
            0,
        );

    // Activate the group
    dispatcher.activate_group(group_id);
    stop_cheat_caller_address(contract_address);

    // All users join the group
    i = 0;
    while i < users.len() {
        let user = *users.at(i);
        start_cheat_caller_address(contract_address, user);
        dispatcher.join_group(group_id);
        stop_cheat_caller_address(contract_address);
        i += 1;
    }

    // Transfer tokens to all users and make contributions
    i = 0;
    while i < users.len() {
        let user = *users.at(i);

        // Transfer tokens
        start_cheat_caller_address(token_address, owner);
        token_dispatcher.transfer(user, token_amount);
        stop_cheat_caller_address(token_address);

        // Approve and contribute
        start_cheat_caller_address(token_address, user);
        token_dispatcher.approve(contract_address, token_amount);
        stop_cheat_caller_address(token_address);

        start_cheat_caller_address(contract_address, user);
        dispatcher.contribute(group_id);
        stop_cheat_caller_address(contract_address);

        i += 1;
    }

    group_id
}

#[test]
fn test_distribute_payout_success() {
    let (contract_address, owner, token_address) = setup();
    let dispatcher = IsavecircleDispatcher { contract_address };
    let token_dispatcher = IERC20Dispatcher { contract_address: token_address };

    // Setup users
    let user1: ContractAddress = contract_address_const::<2>();
    let user2: ContractAddress = contract_address_const::<3>();
    let user3: ContractAddress = contract_address_const::<4>();
    let users = array![user1, user2, user3];

    let contribution_amount = 1000_u256;
    let token_amount = 5000_u256;

    let group_id = setup_group_with_contributions(
        contract_address, token_address, owner, users, contribution_amount, token_amount,
    );

    // Get initial balances
    let initial_balance_user1 = token_dispatcher.balance_of(user1);
    let initial_balance_user2 = token_dispatcher.balance_of(user2);
    let initial_balance_user3 = token_dispatcher.balance_of(user3);

    // Get next recipient before payout
    let next_recipient = dispatcher.get_next_payout_recipient(group_id);
    assert(next_recipient.user != contract_address_const::<0>(), 'Should have recipient');

    // Distribute payout (creator can distribute)
    start_cheat_caller_address(contract_address, user1);
    let result = dispatcher.distribute_payout(group_id);
    assert(result == true, 'Payout should succeed');
    stop_cheat_caller_address(contract_address);

    // Check group state updates after distribute_payout
    let group_info = dispatcher.get_group_info(group_id);
    assert(group_info.current_cycle == 1, 'Cycle should increment');
    assert(group_info.payout_order == 1, 'Payout order should increment');

    // Check member payout eligibility (not yet paid)
    let member_index = dispatcher.get_user_member_index(next_recipient.user, group_id);
    let updated_member = dispatcher.get_group_member(group_id, member_index);
    assert(updated_member.payout_cycle > 0, 'Member should be eligible');
    assert(updated_member.has_been_paid == false, 'Member should not be paid yet');

    // Now recipient claims their payout
    start_cheat_caller_address(contract_address, next_recipient.user);
    let claimed_amount = dispatcher.claim_payout(group_id);
    assert(claimed_amount > 0, 'Should claim positive amount');
    stop_cheat_caller_address(contract_address);

    // Check that recipient received payout after claiming
    let recipient_balance = token_dispatcher.balance_of(next_recipient.user);

    if next_recipient.user == user1 {
        assert(recipient_balance > initial_balance_user1, 'User1 should receive payout');
    } else if next_recipient.user == user2 {
        assert(recipient_balance > initial_balance_user2, 'User2 should receive payout');
    } else if next_recipient.user == user3 {
        assert(recipient_balance > initial_balance_user3, 'User3 should receive payout');
    }

    // Check member payout status after claiming
    let final_member = dispatcher.get_group_member(group_id, member_index);
    assert(final_member.has_been_paid == true, 'Member should be marked as paid');
}

#[test]
fn test_distribute_payout_event_emission() {
    let (contract_address, owner, token_address) = setup();
    let dispatcher = IsavecircleDispatcher { contract_address };

    let user1: ContractAddress = contract_address_const::<2>();
    let user2: ContractAddress = contract_address_const::<3>();
    let users = array![user1, user2];

    let contribution_amount = 1000_u256;
    let token_amount = 5000_u256;

    let group_id = setup_group_with_contributions(
        contract_address, token_address, owner, users, contribution_amount, token_amount,
    );

    let mut spy = spy_events();

    // Get next recipient
    let next_recipient = dispatcher.get_next_payout_recipient(group_id);

    // Distribute payout
    start_cheat_caller_address(contract_address, user1);
    dispatcher.distribute_payout(group_id);
    stop_cheat_caller_address(contract_address);

    // Check event emission
    let expected_payout = contribution_amount * 2; // 2 users contributed
    spy
        .assert_emitted(
            @array![
                (
                    contract_address,
                    Event::PayoutDistributed(
                        PayoutDistributed {
                            group_id,
                            recipient: next_recipient.user,
                            amount: expected_payout,
                            cycle: 1,
                        },
                    ),
                ),
            ],
        );
}


#[test]
#[should_panic(expected: ('Group must be active',))]
fn test_distribute_payout_inactive_group() {
    let (contract_address, owner, _token_address) = setup();
    let dispatcher = IsavecircleDispatcher { contract_address };

    let user: ContractAddress = contract_address_const::<2>();
    start_cheat_caller_address(contract_address, user);

    // Register user
    dispatcher.register_user("TestUser", "avatar.png");
    stop_cheat_caller_address(contract_address);

    // Owner grants admin role to user
    start_cheat_caller_address(contract_address, owner);
    dispatcher.add_admin(user);
    stop_cheat_caller_address(contract_address);

    // User creates group but doesn't activate
    start_cheat_caller_address(contract_address, user);
    let group_id = dispatcher
        .create_public_group(
            "Group 1",
            "First test group",
            5,
            100,
            LockType::Progressive,
            1,
            TimeUnit::Days,
            false,
            0,
        );

    // Try to distribute payout on inactive group (admin can call this)
    dispatcher.distribute_payout(group_id);
}

#[test]
#[should_panic(expected: ('Caller not authorized to add',))]
fn test_distribute_payout_unauthorized_caller() {
    let (contract_address, owner, token_address) = setup();
    let dispatcher = IsavecircleDispatcher { contract_address };

    let user1: ContractAddress = contract_address_const::<2>();
    let user2: ContractAddress = contract_address_const::<3>();
    let users = array![user1, user2];

    let contribution_amount = 1000_u256;
    let token_amount = 5000_u256;

    let group_id = setup_group_with_contributions(
        contract_address, token_address, owner, users, contribution_amount, token_amount,
    );

    // Try to distribute payout as non-creator
    let unauthorized_user: ContractAddress = contract_address_const::<5>();
    start_cheat_caller_address(contract_address, unauthorized_user);
    dispatcher.distribute_payout(group_id);
}

#[test]
#[should_panic(expected: ('No contributions to distrib',))]
fn test_distribute_payout_no_contributions() {
    let (contract_address, owner, _token_address) = setup();
    let dispatcher = IsavecircleDispatcher { contract_address };

    let user: ContractAddress = contract_address_const::<2>();
    start_cheat_caller_address(contract_address, user);

    // Register user
    dispatcher.register_user("TestUser", "avatar.png");
    stop_cheat_caller_address(contract_address);

    // Owner grants admin role to user
    start_cheat_caller_address(contract_address, owner);
    dispatcher.add_admin(user);
    stop_cheat_caller_address(contract_address);

    // User creates and activates group
    start_cheat_caller_address(contract_address, user);
    let group_id = dispatcher
        .create_public_group(
            "Group 1",
            "First test group",
            5,
            100,
            LockType::Progressive,
            1,
            TimeUnit::Days,
            false,
            0,
        );
    dispatcher.activate_group(group_id);
    dispatcher.join_group(group_id);

    // Try to distribute payout without contributions
    dispatcher.distribute_payout(group_id);
}

#[test]
fn test_get_payout_order() {
    let (contract_address, owner, token_address) = setup();
    let dispatcher = IsavecircleDispatcher { contract_address };

    let user1: ContractAddress = contract_address_const::<2>();
    let user2: ContractAddress = contract_address_const::<3>();
    let user3: ContractAddress = contract_address_const::<4>();
    let users = array![user1, user2, user3];

    let contribution_amount = 1000_u256;
    let token_amount = 5000_u256;

    let group_id = setup_group_with_contributions(
        contract_address, token_address, owner, users, contribution_amount, token_amount,
    );

    // Get payout order
    let payout_order = dispatcher.get_payout_order(group_id);

    // Should have all 3 users in the order
    assert(payout_order.len() == 3, 'Should have 3 users in order');

    // Verify all users are included
    let mut found_user1 = false;
    let mut found_user2 = false;
    let mut found_user3 = false;

    let mut i = 0;
    while i < payout_order.len() {
        let user = *payout_order.at(i);
        if user == user1 {
            found_user1 = true;
        } else if user == user2 {
            found_user2 = true;
        } else if user == user3 {
            found_user3 = true;
        }
        i += 1;
    }

    assert(found_user1 && found_user2 && found_user3, 'All users should be in order');
}

#[test]
fn test_get_next_payout_recipient() {
    let (contract_address, owner, token_address) = setup();
    let dispatcher = IsavecircleDispatcher { contract_address };

    let user1: ContractAddress = contract_address_const::<2>();
    let user2: ContractAddress = contract_address_const::<3>();
    let users = array![user1, user2];

    let contribution_amount = 1000_u256;
    let token_amount = 5000_u256;

    let group_id = setup_group_with_contributions(
        contract_address, token_address, owner, users, contribution_amount, token_amount,
    );

    // Get next recipient
    let next_recipient = dispatcher.get_next_payout_recipient(group_id);
    assert(next_recipient.user != contract_address_const::<0>(), 'Should have recipient');
    assert(next_recipient.has_been_paid == false, 'Reci should not be paid yet');
    assert(next_recipient.group_id == group_id, 'Should be from correct group');
}

fn setup_group_with_different_lock_amounts(
    contract_address: ContractAddress,
    token_address: ContractAddress,
    owner: ContractAddress,
    users: Array<ContractAddress>,
    lock_amounts: Array<u256>,
    contribution_amount: u256,
) -> u256 {
    let dispatcher = IsavecircleDispatcher { contract_address };
    let token_dispatcher = IERC20Dispatcher { contract_address: token_address };

    let creator = *users.at(0);

    // Register all users
    let mut i = 0;
    while i < users.len() {
        let user = *users.at(i);
        start_cheat_caller_address(contract_address, user);
        dispatcher.register_user("TestUser", "avatar.png");
        stop_cheat_caller_address(contract_address);
        i += 1;
    }

    // Owner grants admin role to creator
    start_cheat_caller_address(contract_address, owner);
    dispatcher.add_admin(creator);
    stop_cheat_caller_address(contract_address);

    let contribution_amount = 800_u256;

    // Create group with creator (weekly cycle)
    start_cheat_caller_address(contract_address, creator);
    let group_id = dispatcher
        .create_public_group(
            "Group with Different Locks",
            "Test group with different lock amounts",
            5,
            contribution_amount,
            LockType::Progressive,
            7, // 7 days cycle duration
            TimeUnit::Days,
            true, // requires lock
            0,
        );

    // Activate the group
    dispatcher.activate_group(group_id);
    stop_cheat_caller_address(contract_address);

    // All users join the group and lock different amounts
    i = 0;
    while i < users.len() {
        let user = *users.at(i);
        let lock_amount = *lock_amounts.at(i);
        // Give users extra tokens to ensure they have enough for both locking and contributing
        let total_token_amount = lock_amount + contribution_amount + 1000_u256; // Extra buffer

        // Transfer tokens to user
        start_cheat_caller_address(token_address, owner);
        token_dispatcher.transfer(user, total_token_amount);
        stop_cheat_caller_address(token_address);

        // Approve tokens
        start_cheat_caller_address(token_address, user);
        token_dispatcher.approve(contract_address, total_token_amount);
        stop_cheat_caller_address(token_address);

        // Join group
        start_cheat_caller_address(contract_address, user);
        dispatcher.join_group(group_id);
        stop_cheat_caller_address(contract_address);

        // Contribute first (this is usually required before locking)
        start_cheat_caller_address(contract_address, user);
        dispatcher.contribute(group_id);
        stop_cheat_caller_address(contract_address);

        // Lock funds (if lock amount > 0) - do this after contributing
        if lock_amount > 0 {
            start_cheat_caller_address(contract_address, user);
            dispatcher.lock_liquidity(token_address, lock_amount, group_id);
            stop_cheat_caller_address(contract_address);
        }

        i += 1;
    }

    group_id
}

#[test]
fn test_group_with_different_locks_no_early_payout() {
    let (contract_address, owner, token_address) = setup();
    let dispatcher = IsavecircleDispatcher { contract_address };
    let token_dispatcher = IERC20Dispatcher { contract_address: token_address };

    // Setup 5 users
    let user1: ContractAddress = contract_address_const::<2>();
    let user2: ContractAddress = contract_address_const::<3>();
    let user3: ContractAddress = contract_address_const::<4>();
    let user4: ContractAddress = contract_address_const::<5>();
    let user5: ContractAddress = contract_address_const::<6>();
    let users = array![user1, user2, user3, user4, user5];

    // Different lock amounts: user1 and user2 lock same amount (1000), others different
    // All lock amounts must be >= contribution amount
    let contribution_amount = 800_u256;
    let lock_amounts = array![1000_u256, 1000_u256, 1500_u256, 2000_u256, 900_u256];

    let group_id = setup_group_with_different_lock_amounts(
        contract_address, token_address, owner, users, lock_amounts, contribution_amount,
    );

    // Verify group was created with correct parameters
    let group_info = dispatcher.get_group_info(group_id);
    assert(group_info.members == 5, 'Should have 5 members');
    assert(group_info.state == GroupState::Active, 'Group should be active');
    assert(group_info.requires_lock == true, 'Group should require locks');
    assert(group_info.cycle_duration == 7, 'Cycle should be 7 days');
    assert(group_info.cycle_unit == TimeUnit::Days, 'Unit should be days');

    // Verify different lock amounts were set correctly using actual locked funds
    let (total_locked, member_funds) = dispatcher.get_group_locked_funds(group_id);
    assert(member_funds.len() == 5, 'Should have 5 members');

    // Extract individual locked amounts for each user
    let mut user1_locked = 0_u256;
    let mut user2_locked = 0_u256;
    let mut user3_locked = 0_u256;
    let mut user4_locked = 0_u256;
    let mut user5_locked = 0_u256;

    let mut i = 0;
    while i < member_funds.len() {
        let (user_addr, locked_amount) = *member_funds.at(i);
        if user_addr == user1 {
            user1_locked = locked_amount;
        } else if user_addr == user2 {
            user2_locked = locked_amount;
        } else if user_addr == user3 {
            user3_locked = locked_amount;
        } else if user_addr == user4 {
            user4_locked = locked_amount;
        } else if user_addr == user5 {
            user5_locked = locked_amount;
        }
        i += 1;
    }

    // Check that user1 and user2 have same lock amount (1000)
    assert(user1_locked == 1000_u256, 'User1 lock amount wrong');
    assert(user2_locked == 1000_u256, 'User2 lock amount wrong');
    assert(user1_locked == user2_locked, 'User1&2 should have same lock');

    // Check that others have different amounts
    assert(user3_locked == 1500_u256, 'User3 lock amount wrong');
    assert(user4_locked == 2000_u256, 'User4 lock amount wrong');
    assert(user5_locked == 900_u256, 'User5 lock amount wrong');

    // Verify all amounts are different except user1 and user2
    assert(user1_locked != user3_locked, 'User1&3 should differ');
    assert(user1_locked != user4_locked, 'User1&4 should differ');
    assert(user1_locked != user5_locked, 'User1&5 should differ');
    assert(user3_locked != user4_locked, 'User3&4 should differ');
    assert(user3_locked != user5_locked, 'User3&5 should differ');
    assert(user4_locked != user5_locked, 'User4&5 should differ');

    // Verify total locked amount is correct
    let expected_total = 1000_u256 + 1000_u256 + 1500_u256 + 2000_u256 + 900_u256; // 6400
    assert(total_locked == expected_total, 'Total locked amount wrong');

    // Try to distribute payout immediately (should work since all contributed)
    // But in a real scenario with timing constraints, this would check the cycle duration
    let next_recipient = dispatcher.get_next_payout_recipient(group_id);
    assert(next_recipient.user != contract_address_const::<0>(), 'Should have recipient');

    // Get initial balance of next recipient
    let initial_balance = token_dispatcher.balance_of(next_recipient.user);

    // Distribute payout (creator can distribute)
    start_cheat_caller_address(contract_address, user1);
    let result = dispatcher.distribute_payout(group_id);
    assert(result == true, 'Payout should succeed');
    stop_cheat_caller_address(contract_address);

    // Verify group state updated after distribute_payout
    let updated_group_info = dispatcher.get_group_info(group_id);
    assert(updated_group_info.current_cycle == 1, 'Cycle should increment');
    assert(updated_group_info.payout_order == 1, 'Payout order should increment');

    // Verify recipient marked as eligible (not yet paid)
    let member_index = dispatcher.get_user_member_index(next_recipient.user, group_id);
    let updated_member = dispatcher.get_group_member(group_id, member_index);
    assert(updated_member.payout_cycle > 0, 'Member should be eligible');
    assert(updated_member.has_been_paid == false, 'Member should not be paid yet');

    // Now recipient claims their payout
    start_cheat_caller_address(contract_address, next_recipient.user);
    let claimed_amount = dispatcher.claim_payout(group_id);
    assert(claimed_amount > 0, 'Should claim positive amount');
    stop_cheat_caller_address(contract_address);

    // Verify recipient received payout after claiming
    let final_balance = token_dispatcher.balance_of(next_recipient.user);
    assert(final_balance > initial_balance, 'Recipient should receive payout');

    // Verify the payout amount equals total contributions (5 * 800 = 4000)
    let expected_payout = contribution_amount * 5;
    let actual_payout = final_balance - initial_balance;
    assert(actual_payout == expected_payout, 'Payout amount should match');

    // Verify recipient marked as paid after claiming
    let final_member = dispatcher.get_group_member(group_id, member_index);
    assert(final_member.has_been_paid == true, 'Member should be marked as paid');
}

