#[cfg(test)]
mod test_multi_cycle_payout {
    use core::array::ArrayTrait;
    use core::traits::Into;
    use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use save_circle::contracts::Savecircle::SaveCircle;
    use save_circle::enums::Enums::{LockType, TimeUnit};
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

    fn setup_user_and_group(
        contract_address: ContractAddress,
        token_address: ContractAddress,
        owner: ContractAddress,
        user: ContractAddress,
        contribution_amount: u256,
        token_amount: u256,
    ) -> u256 {
        let dispatcher = IsavecircleDispatcher { contract_address };
        let token_dispatcher = IERC20Dispatcher { contract_address: token_address };

        // Owner grants admin role to user
        start_cheat_caller_address(contract_address, owner);
        dispatcher.add_admin(user);
        stop_cheat_caller_address(contract_address);

        // Register user
        start_cheat_caller_address(contract_address, user);
        dispatcher.register_user("TestUser", "avatar.png");

        // Create a group with the correct contribution amount
        let group_id = dispatcher
            .create_public_group(
                "Multi-Cycle Group",
                "Test multi-cycle payout behavior",
                4,
                contribution_amount,
                LockType::Progressive,
                1,
                TimeUnit::Days,
                false,
                0,
            );

        // Activate the group (creator can activate)
        dispatcher.activate_group(group_id);

        // Join the group
        dispatcher.join_group(group_id);
        stop_cheat_caller_address(contract_address);

        // Transfer tokens to user
        start_cheat_caller_address(token_address, owner);
        token_dispatcher.transfer(user, token_amount);
        stop_cheat_caller_address(token_address);

        // User approves contract to spend tokens
        start_cheat_caller_address(token_address, user);
        token_dispatcher.approve(contract_address, token_amount);
        stop_cheat_caller_address(token_address);

        group_id
    }

    #[test]
    fn test_multi_cycle_held_payout_then_distribution() {
        let (contract_address, owner, token_address) = setup();
        let dispatcher = IsavecircleDispatcher { contract_address };
        let token_dispatcher = IERC20Dispatcher { contract_address: token_address };

        // Setup users
        let user1: ContractAddress = contract_address_const::<2>();
        let user2: ContractAddress = contract_address_const::<3>();
        let user3: ContractAddress = contract_address_const::<4>();
        let user4: ContractAddress = contract_address_const::<5>();

        let contribution_amount = 1000_u256;
        let token_amount = 100000_u256;

        // Setup first user and group
        let group_id = setup_user_and_group(
            contract_address, token_address, owner, user1, contribution_amount, token_amount,
        );

        // Setup additional users and add them to the group
        start_cheat_caller_address(contract_address, user2);
        dispatcher.register_user("User2", "avatar2.png");
        dispatcher.join_group(group_id);
        stop_cheat_caller_address(contract_address);

        start_cheat_caller_address(contract_address, user3);
        dispatcher.register_user("User3", "avatar3.png");
        dispatcher.join_group(group_id);
        stop_cheat_caller_address(contract_address);

        start_cheat_caller_address(contract_address, user4);
        dispatcher.register_user("User4", "avatar4.png");
        dispatcher.join_group(group_id);
        stop_cheat_caller_address(contract_address);

        // Give tokens to additional users
        start_cheat_caller_address(token_address, owner);
        token_dispatcher.transfer(user2, token_amount);
        token_dispatcher.transfer(user3, token_amount);
        token_dispatcher.transfer(user4, token_amount);
        stop_cheat_caller_address(token_address);

        // Users approve contract to spend tokens
        start_cheat_caller_address(token_address, user2);
        token_dispatcher.approve(contract_address, token_amount);
        stop_cheat_caller_address(token_address);

        start_cheat_caller_address(token_address, user3);
        token_dispatcher.approve(contract_address, token_amount);
        stop_cheat_caller_address(token_address);

        start_cheat_caller_address(token_address, user4);
        token_dispatcher.approve(contract_address, token_amount);
        stop_cheat_caller_address(token_address);

        // === CYCLE 1: Lock small amounts (no one qualifies) ===
        let small_lock_amount = 1000_u256; // Not enough to qualify (need 5050)

        start_cheat_caller_address(contract_address, user1);
        dispatcher.lock_liquidity(token_address, small_lock_amount, group_id);
        stop_cheat_caller_address(contract_address);

        start_cheat_caller_address(contract_address, user2);
        dispatcher.lock_liquidity(token_address, small_lock_amount, group_id);
        stop_cheat_caller_address(contract_address);

        start_cheat_caller_address(contract_address, user3);
        dispatcher.lock_liquidity(token_address, small_lock_amount, group_id);
        stop_cheat_caller_address(contract_address);

        start_cheat_caller_address(contract_address, user4);
        dispatcher.lock_liquidity(token_address, small_lock_amount, group_id);
        stop_cheat_caller_address(contract_address);

        // All users contribute for cycle 1
        start_cheat_caller_address(contract_address, user1);
        dispatcher.contribute(group_id);
        stop_cheat_caller_address(contract_address);

        start_cheat_caller_address(contract_address, user2);
        dispatcher.contribute(group_id);
        stop_cheat_caller_address(contract_address);

        start_cheat_caller_address(contract_address, user3);
        dispatcher.contribute(group_id);
        stop_cheat_caller_address(contract_address);

        start_cheat_caller_address(contract_address, user4);
        dispatcher.contribute(group_id);
        stop_cheat_caller_address(contract_address);

        let cycle1_group_info = dispatcher.get_group_info(group_id);
        let cycle1_held_payouts = dispatcher.get_held_payouts(group_id);

        println!("=== CYCLE 1 BEFORE PAYOUT ===");
        println!("Current cycle: {}", cycle1_group_info.current_cycle);
        println!("Remaining pool: {}", cycle1_group_info.remaining_pool_amount);
        println!("Held payouts: {}", cycle1_held_payouts);

        // Try to distribute payout for cycle 1 - should hold payout
        start_cheat_caller_address(contract_address, owner);
        let cycle1_result = dispatcher.distribute_payout(group_id);
        stop_cheat_caller_address(contract_address);

        assert(cycle1_result, 'Cycle 1 payout should succeed');

        let after_cycle1_info = dispatcher.get_group_info(group_id);
        let after_cycle1_held_payouts = dispatcher.get_held_payouts(group_id);

        println!("=== CYCLE 1 AFTER PAYOUT ===");
        println!("Current cycle: {}", after_cycle1_info.current_cycle);
        println!("Remaining pool: {}", after_cycle1_info.remaining_pool_amount);
        println!("Held payouts: {}", after_cycle1_held_payouts);

        // Verify cycle 1 results
        assert(after_cycle1_info.current_cycle == 1, 'Should advance to cycle 1');
        assert(after_cycle1_info.remaining_pool_amount == 4000, 'Should hold 4000 tokens');
        assert(after_cycle1_held_payouts == 1, 'Should have 1 held payout');
        assert(after_cycle1_info.payout_order == 0, 'No one should be paid');

        // === CYCLE 2: User1 locks enough to qualify ===
        let qualifying_lock_amount = 6000_u256; // More than enough to qualify

        start_cheat_caller_address(contract_address, user1);
        dispatcher.lock_liquidity(token_address, qualifying_lock_amount, group_id);
        stop_cheat_caller_address(contract_address);

        // All users contribute for cycle 2
        start_cheat_caller_address(contract_address, user1);
        dispatcher.contribute(group_id);
        stop_cheat_caller_address(contract_address);

        start_cheat_caller_address(contract_address, user2);
        dispatcher.contribute(group_id);
        stop_cheat_caller_address(contract_address);

        start_cheat_caller_address(contract_address, user3);
        dispatcher.contribute(group_id);
        stop_cheat_caller_address(contract_address);

        start_cheat_caller_address(contract_address, user4);
        dispatcher.contribute(group_id);
        stop_cheat_caller_address(contract_address);

        let cycle2_group_info = dispatcher.get_group_info(group_id);
        let cycle2_held_payouts = dispatcher.get_held_payouts(group_id);

        println!("=== CYCLE 2 BEFORE PAYOUT ===");
        println!("Current cycle: {}", cycle2_group_info.current_cycle);
        println!("Remaining pool: {}", cycle2_group_info.remaining_pool_amount);
        println!("Held payouts: {}", cycle2_held_payouts);

        // Get user1's initial balance
        let user1_initial_balance = token_dispatcher.balance_of(user1);

        // Try to distribute payout for cycle 2 - should pay user1
        start_cheat_caller_address(contract_address, owner);
        let cycle2_result = dispatcher.distribute_payout(group_id);
        stop_cheat_caller_address(contract_address);

        assert(cycle2_result, 'Cycle 2 payout should succeed');

        let after_cycle2_info = dispatcher.get_group_info(group_id);
        let after_cycle2_held_payouts = dispatcher.get_held_payouts(group_id);

        println!("=== CYCLE 2 AFTER PAYOUT ===");
        println!("Current cycle: {}", after_cycle2_info.current_cycle);
        println!("Remaining pool: {}", after_cycle2_info.remaining_pool_amount);
        println!("Held payouts: {}", after_cycle2_held_payouts);
        println!("Payout order: {}", after_cycle2_info.payout_order);

        // Verify cycle 2 results
        assert(after_cycle2_info.current_cycle == 2, 'Should advance to cycle 2');
        assert(after_cycle2_info.payout_order == 1, 'User1 marked for payout');

        // User1 should be able to claim the payout (held payout + current cycle)
        start_cheat_caller_address(contract_address, user1);
        let claimed_amount = dispatcher.withdraw_payout();
        stop_cheat_caller_address(contract_address);

        let user1_final_balance = token_dispatcher.balance_of(user1);
        let actual_payout = user1_final_balance - user1_initial_balance;

        println!("=== PAYOUT CLAIMED ===");
        println!("Claimed amount: {}", claimed_amount);
        println!("Actual payout received: {}", actual_payout);

        // Expected payout: Full cycle amount (4000 tokens per recipient)
        let expected_cycle_payout = 4000_u256;
        assert(actual_payout == expected_cycle_payout, 'Should receive full cycle');
        assert(claimed_amount == expected_cycle_payout, 'Claimed amount matches');

        println!("Multi-cycle payout test passed!");
        println!("- Cycle 1: No eligible recipients, payout held");
        println!("- Cycle 2: User1 qualified and received ONE cycle's payout");
        println!("- Payout received: {} tokens (correct: one cycle's worth)", actual_payout);
        println!("- Remaining held payouts will be distributed in future cycles");
    }

    #[test]
    fn test_multi_recipient_payout_distribution() {
        let (contract_address, owner, token_address) = setup();
        let dispatcher = IsavecircleDispatcher { contract_address };
        let token_dispatcher = IERC20Dispatcher { contract_address: token_address };

        // Setup users
        let user1: ContractAddress = contract_address_const::<2>();
        let user2: ContractAddress = contract_address_const::<3>();
        let user3: ContractAddress = contract_address_const::<4>();
        let user4: ContractAddress = contract_address_const::<5>();

        let contribution_amount = 1000_u256;
        let token_amount = 100000_u256;

        // Setup first user and group
        let group_id = setup_user_and_group(
            contract_address, token_address, owner, user1, contribution_amount, token_amount,
        );

        // Setup additional users and add them to the group
        start_cheat_caller_address(contract_address, user2);
        dispatcher.register_user("User2", "avatar2.png");
        dispatcher.join_group(group_id);
        stop_cheat_caller_address(contract_address);

        start_cheat_caller_address(contract_address, user3);
        dispatcher.register_user("User3", "avatar3.png");
        dispatcher.join_group(group_id);
        stop_cheat_caller_address(contract_address);

        start_cheat_caller_address(contract_address, user4);
        dispatcher.register_user("User4", "avatar4.png");
        dispatcher.join_group(group_id);
        stop_cheat_caller_address(contract_address);

        // Give tokens to additional users
        start_cheat_caller_address(token_address, owner);
        token_dispatcher.transfer(user2, token_amount);
        token_dispatcher.transfer(user3, token_amount);
        token_dispatcher.transfer(user4, token_amount);
        stop_cheat_caller_address(token_address);

        // Users approve contract to spend tokens
        start_cheat_caller_address(token_address, user2);
        token_dispatcher.approve(contract_address, token_amount);
        stop_cheat_caller_address(token_address);

        start_cheat_caller_address(token_address, user3);
        token_dispatcher.approve(contract_address, token_amount);
        stop_cheat_caller_address(token_address);

        start_cheat_caller_address(token_address, user4);
        token_dispatcher.approve(contract_address, token_amount);
        stop_cheat_caller_address(token_address);

        // === CYCLE 1: Lock small amounts (no one qualifies) ===
        let small_lock_amount = 1000_u256; // Not enough to qualify (need 5050)

        start_cheat_caller_address(contract_address, user1);
        dispatcher.lock_liquidity(token_address, small_lock_amount, group_id);
        stop_cheat_caller_address(contract_address);

        start_cheat_caller_address(contract_address, user2);
        dispatcher.lock_liquidity(token_address, small_lock_amount, group_id);
        stop_cheat_caller_address(contract_address);

        start_cheat_caller_address(contract_address, user3);
        dispatcher.lock_liquidity(token_address, small_lock_amount, group_id);
        stop_cheat_caller_address(contract_address);

        start_cheat_caller_address(contract_address, user4);
        dispatcher.lock_liquidity(token_address, small_lock_amount, group_id);
        stop_cheat_caller_address(contract_address);

        // All users contribute for cycle 1
        start_cheat_caller_address(contract_address, user1);
        dispatcher.contribute(group_id);
        stop_cheat_caller_address(contract_address);

        start_cheat_caller_address(contract_address, user2);
        dispatcher.contribute(group_id);
        stop_cheat_caller_address(contract_address);

        start_cheat_caller_address(contract_address, user3);
        dispatcher.contribute(group_id);
        stop_cheat_caller_address(contract_address);

        start_cheat_caller_address(contract_address, user4);
        dispatcher.contribute(group_id);
        stop_cheat_caller_address(contract_address);

        println!("=== CYCLE 1: NO ELIGIBLE RECIPIENTS ===");
        let cycle1_info_before = dispatcher.get_group_info(group_id);
        println!(
            "Before payout - Current cycle: {}, Pool: {}",
            cycle1_info_before.current_cycle,
            cycle1_info_before.remaining_pool_amount,
        );

        // Distribute payout for cycle 1 - should hold payout
        start_cheat_caller_address(contract_address, owner);
        let cycle1_result = dispatcher.distribute_payout(group_id);
        stop_cheat_caller_address(contract_address);

        assert(cycle1_result, 'Cycle 1 payout should succeed');

        let cycle1_info_after = dispatcher.get_group_info(group_id);
        let cycle1_held_payouts = dispatcher.get_held_payouts(group_id);
        println!(
            "After payout - Current cycle: {}, Pool: {}, Held: {}",
            cycle1_info_after.current_cycle,
            cycle1_info_after.remaining_pool_amount,
            cycle1_held_payouts,
        );

        assert(cycle1_info_after.current_cycle == 1, 'Should advance to cycle 1');
        assert(cycle1_info_after.remaining_pool_amount == 4000, 'Should hold 4000 tokens');
        assert(cycle1_held_payouts == 1, 'Should have 1 held payout');

        // === CYCLE 2: User1 and User2 lock enough to qualify ===
        let qualifying_lock_amount = 6000_u256; // More than enough to qualify

        start_cheat_caller_address(contract_address, user1);
        dispatcher.lock_liquidity(token_address, qualifying_lock_amount, group_id);
        stop_cheat_caller_address(contract_address);

        start_cheat_caller_address(contract_address, user2);
        dispatcher.lock_liquidity(token_address, qualifying_lock_amount, group_id);
        stop_cheat_caller_address(contract_address);

        // All users contribute for cycle 2
        start_cheat_caller_address(contract_address, user1);
        dispatcher.contribute(group_id);
        stop_cheat_caller_address(contract_address);

        start_cheat_caller_address(contract_address, user2);
        dispatcher.contribute(group_id);
        stop_cheat_caller_address(contract_address);

        start_cheat_caller_address(contract_address, user3);
        dispatcher.contribute(group_id);
        stop_cheat_caller_address(contract_address);

        start_cheat_caller_address(contract_address, user4);
        dispatcher.contribute(group_id);
        stop_cheat_caller_address(contract_address);

        println!("=== CYCLE 2: TWO ELIGIBLE RECIPIENTS ===");
        let cycle2_info_before = dispatcher.get_group_info(group_id);
        println!(
            "Before payout - Current cycle: {}, Pool: {}",
            cycle2_info_before.current_cycle,
            cycle2_info_before.remaining_pool_amount,
        );

        // Get initial balances
        let user1_initial_balance = token_dispatcher.balance_of(user1);
        let user2_initial_balance = token_dispatcher.balance_of(user2);

        // Distribute payout for cycle 2 - should pay both user1 and user2
        start_cheat_caller_address(contract_address, owner);
        let cycle2_result = dispatcher.distribute_payout(group_id);
        stop_cheat_caller_address(contract_address);

        assert(cycle2_result, 'Cycle 2 payout should succeed');

        let cycle2_info_after = dispatcher.get_group_info(group_id);
        let cycle2_held_payouts = dispatcher.get_held_payouts(group_id);
        println!(
            "After payout - Current cycle: {}, Pool: {}, Held: {}, Payout order: {}",
            cycle2_info_after.current_cycle,
            cycle2_info_after.remaining_pool_amount,
            cycle2_held_payouts,
            cycle2_info_after.payout_order,
        );

        assert(cycle2_info_after.current_cycle == 2, 'Should advance to cycle 2');
        assert(cycle2_info_after.payout_order == 2, 'Two users marked for payout');

        // Both users should be able to claim their payouts
        start_cheat_caller_address(contract_address, user1);
        let user1_claimed = dispatcher.withdraw_payout();
        stop_cheat_caller_address(contract_address);

        start_cheat_caller_address(contract_address, user2);
        let user2_claimed = dispatcher.withdraw_payout();
        stop_cheat_caller_address(contract_address);

        let user1_final_balance = token_dispatcher.balance_of(user1);
        let user2_final_balance = token_dispatcher.balance_of(user2);
        let user1_payout = user1_final_balance - user1_initial_balance;
        let user2_payout = user2_final_balance - user2_initial_balance;

        println!("=== PAYOUTS CLAIMED ===");
        println!("User1 claimed: {}, received: {}", user1_claimed, user1_payout);
        println!("User2 claimed: {}, received: {}", user2_claimed, user2_payout);

        // Each user should receive the full cycle amount (4000 tokens)
        let expected_cycle_payout = 4000_u256;
        assert(user1_payout == expected_cycle_payout, 'User1 should get full cycle');
        assert(user2_payout == expected_cycle_payout, 'User2 should get full cycle');
        assert(user1_claimed == expected_cycle_payout, 'User1 claim matches');
        assert(user2_claimed == expected_cycle_payout, 'User2 claim matches');

        // === CYCLE 3: All users qualify ===
        start_cheat_caller_address(contract_address, user3);
        dispatcher.lock_liquidity(token_address, qualifying_lock_amount, group_id);
        stop_cheat_caller_address(contract_address);

        start_cheat_caller_address(contract_address, user4);
        dispatcher.lock_liquidity(token_address, qualifying_lock_amount, group_id);
        stop_cheat_caller_address(contract_address);

        // All users contribute for cycle 3
        start_cheat_caller_address(contract_address, user1);
        dispatcher.contribute(group_id);
        stop_cheat_caller_address(contract_address);

        start_cheat_caller_address(contract_address, user2);
        dispatcher.contribute(group_id);
        stop_cheat_caller_address(contract_address);

        start_cheat_caller_address(contract_address, user3);
        dispatcher.contribute(group_id);
        stop_cheat_caller_address(contract_address);

        start_cheat_caller_address(contract_address, user4);
        dispatcher.contribute(group_id);
        stop_cheat_caller_address(contract_address);

        println!("=== CYCLE 3: ONLY ONE PERSON CAN BE PAID (4000 AVAILABLE) ===");
        let cycle3_info_before = dispatcher.get_group_info(group_id);
        let cycle3_held_before = dispatcher.get_held_payouts(group_id);
        println!(
            "Before payout - Current cycle: {}, Pool: {}, Held: {}",
            cycle3_info_before.current_cycle,
            cycle3_info_before.remaining_pool_amount,
            cycle3_held_before,
        );

        // Get initial balances for cycle 3
        let user3_initial_balance = token_dispatcher.balance_of(user3);
        let user4_initial_balance = token_dispatcher.balance_of(user4);

        // Distribute payout for cycle 3 - should pay only ONE person (4000 tokens available)
        start_cheat_caller_address(contract_address, owner);
        let cycle3_result = dispatcher.distribute_payout(group_id);
        stop_cheat_caller_address(contract_address);

        assert(cycle3_result, 'Cycle 3 payout should succeed');

        let cycle3_info_after = dispatcher.get_group_info(group_id);
        let cycle3_held_after = dispatcher.get_held_payouts(group_id);
        println!(
            "After payout - Current cycle: {}, Pool: {}, Held: {}, Payout order: {}",
            cycle3_info_after.current_cycle,
            cycle3_info_after.remaining_pool_amount,
            cycle3_held_after,
            cycle3_info_after.payout_order,
        );

        assert(cycle3_info_after.current_cycle == 3, 'Should advance to cycle 3');
        assert(cycle3_info_after.payout_order == 3, 'Only one more person paid');

        // Only User3 should be able to claim payout (first eligible)
        start_cheat_caller_address(contract_address, user3);
        let user3_claimed = dispatcher.withdraw_payout();
        stop_cheat_caller_address(contract_address);

        let user3_final_balance = token_dispatcher.balance_of(user3);
        let user3_payout = user3_final_balance - user3_initial_balance;

        println!("=== CYCLE 3 PAYOUT CLAIMED ===");
        println!("User3 claimed: {}, received: {}", user3_claimed, user3_payout);

        // User3 should receive the full cycle amount (4000 tokens)
        assert(user3_payout == expected_cycle_payout, 'User3 should get full cycle');
        assert(user3_claimed == expected_cycle_payout, 'User3 claim matches');

        // User4 should NOT be able to claim yet (no payout available)
        let user4_final_balance = token_dispatcher.balance_of(user4);
        let user4_payout = user4_final_balance - user4_initial_balance;
        assert(user4_payout == 0, 'User4 should not get payout yet');

        // === CYCLE 4: USER4 SHOULD GET FINAL PAYOUT ===
        // All users contribute for cycle 4
        start_cheat_caller_address(contract_address, user1);
        dispatcher.contribute(group_id);
        stop_cheat_caller_address(contract_address);

        start_cheat_caller_address(contract_address, user2);
        dispatcher.contribute(group_id);
        stop_cheat_caller_address(contract_address);

        start_cheat_caller_address(contract_address, user3);
        dispatcher.contribute(group_id);
        stop_cheat_caller_address(contract_address);

        start_cheat_caller_address(contract_address, user4);
        dispatcher.contribute(group_id);
        stop_cheat_caller_address(contract_address);

        println!("=== CYCLE 4: USER4 GETS FINAL PAYOUT ===");
        let cycle4_info_before = dispatcher.get_group_info(group_id);
        println!(
            "Before payout - Current cycle: {}, Pool: {}",
            cycle4_info_before.current_cycle,
            cycle4_info_before.remaining_pool_amount,
        );

        // Get User4's balance before cycle 4 payout
        let user4_balance_before_cycle4 = token_dispatcher.balance_of(user4);

        // Distribute payout for cycle 4 - should pay User4
        start_cheat_caller_address(contract_address, owner);
        let cycle4_result = dispatcher.distribute_payout(group_id);
        stop_cheat_caller_address(contract_address);

        assert(cycle4_result, 'Cycle 4 payout should succeed');

        let cycle4_info_after = dispatcher.get_group_info(group_id);
        println!(
            "After payout - Current cycle: {}, Pool: {}, Payout order: {}",
            cycle4_info_after.current_cycle,
            cycle4_info_after.remaining_pool_amount,
            cycle4_info_after.payout_order,
        );

        assert(cycle4_info_after.payout_order == 4, 'All 4 users should be paid');

        // User4 should be able to claim payout
        start_cheat_caller_address(contract_address, user4);
        let user4_claimed = dispatcher.withdraw_payout();
        stop_cheat_caller_address(contract_address);

        let user4_balance_after_cycle4 = token_dispatcher.balance_of(user4);
        let user4_payout = user4_balance_after_cycle4 - user4_balance_before_cycle4;

        println!("=== CYCLE 4 PAYOUT CLAIMED ===");
        println!("User4 claimed: {}, received: {}", user4_claimed, user4_payout);

        // User4 should receive the full cycle amount (4000 tokens)
        assert(user4_payout == expected_cycle_payout, 'User4 should get full cycle');
        assert(user4_claimed == expected_cycle_payout, 'User4 claim matches');

        println!("=== FINAL VERIFICATION: COMPLETE ROTATION ACHIEVED ===");
        println!("User1 total payout: {}", user1_payout);
        println!("User2 total payout: {}", user2_payout);
        println!("User3 total payout: {}", user3_payout);
        println!("User4 total payout: {}", user4_payout);

        // Verify each user received exactly one full cycle payout
        assert(user1_payout == expected_cycle_payout, 'User1 got full cycle');
        assert(user2_payout == expected_cycle_payout, 'User2 got full cycle');
        assert(user3_payout == expected_cycle_payout, 'User3 got full cycle');
        assert(user4_payout == expected_cycle_payout, 'User4 got full cycle');

        println!("Complete payout rotation test passed!");
        println!("- Cycle 1: No eligible recipients, payout held (4000 tokens)");
        println!("- Cycle 2: User1 and User2 received payouts (8000 tokens available)");
        println!("- Cycle 3: User3 received payout (4000 tokens available, User4 waits)");
        println!("- Cycle 4: User4 received final payout (4000 tokens available)");
        println!(
            "- Each user received exactly {} tokens (full cycle amount)", expected_cycle_payout,
        );
        println!("- Correct savings circle logic: pay based on available funds!");
    }
}
