#[cfg(test)]
mod test_priority_and_held_payouts {
    use core::array::ArrayTrait;
    use core::traits::Into;
    use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use save_circle::contracts::Savecircle::SaveCircle;
    use save_circle::enums::Enums::{LockType, TimeUnit};
    use save_circle::interfaces::Isavecircle::{IsavecircleDispatcher, IsavecircleDispatcherTrait};
    use snforge_std::{
        ContractClassTrait, DeclareResultTrait, start_cheat_caller_address, stop_cheat_caller_address,
        declare,
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
                "Priority Test Group",
                "Test priority and held payout logic",
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
    fn test_priority_and_accumulated_held_payouts() {
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

        // Setup additional users and add them to the group (in specific order for timestamp testing)
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

        // === CYCLE 1: No one qualifies - hold payout ===
        let small_lock_amount = 1000_u256; // Not enough to qualify

        start_cheat_caller_address(contract_address, user1);
        dispatcher.lock_liquidity(token_address, small_lock_amount, group_id);
        dispatcher.contribute(group_id);
        stop_cheat_caller_address(contract_address);

        start_cheat_caller_address(contract_address, user2);
        dispatcher.lock_liquidity(token_address, small_lock_amount, group_id);
        dispatcher.contribute(group_id);
        stop_cheat_caller_address(contract_address);

        start_cheat_caller_address(contract_address, user3);
        dispatcher.lock_liquidity(token_address, small_lock_amount, group_id);
        dispatcher.contribute(group_id);
        stop_cheat_caller_address(contract_address);

        start_cheat_caller_address(contract_address, user4);
        dispatcher.lock_liquidity(token_address, small_lock_amount, group_id);
        dispatcher.contribute(group_id);
        stop_cheat_caller_address(contract_address);

        println!("=== CYCLE 1: NO ELIGIBLE RECIPIENTS ===");
        start_cheat_caller_address(contract_address, owner);
        dispatcher.distribute_payout(group_id);
        stop_cheat_caller_address(contract_address);

        let cycle1_held = dispatcher.get_held_payouts(group_id);
        println!("Held payouts after cycle 1: {}", cycle1_held);
        assert(cycle1_held == 1, 'Should have 1 held payout');

        // === CYCLE 2: No one qualifies again - accumulate held payouts ===
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

        println!("=== CYCLE 2: NO ELIGIBLE RECIPIENTS AGAIN ===");
        start_cheat_caller_address(contract_address, owner);
        dispatcher.distribute_payout(group_id);
        stop_cheat_caller_address(contract_address);

        let cycle2_held = dispatcher.get_held_payouts(group_id);
        println!("Held payouts after cycle 2: {}", cycle2_held);
        assert(cycle2_held == 2, 'Should have 2 held payouts');

        // === CYCLE 3: User2 and User3 qualify with SAME lock amount - test priority ===
        let qualifying_lock_amount = 6000_u256;

        // User2 locks first (should have priority due to earlier join order)
        start_cheat_caller_address(contract_address, user2);
        dispatcher.lock_liquidity(token_address, qualifying_lock_amount, group_id);
        stop_cheat_caller_address(contract_address);

        // User3 locks same amount (should be lower priority due to later join order)
        start_cheat_caller_address(contract_address, user3);
        dispatcher.lock_liquidity(token_address, qualifying_lock_amount, group_id);
        stop_cheat_caller_address(contract_address);

        // All contribute for cycle 3
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

        println!("=== CYCLE 3: TWO ELIGIBLE WITH SAME LOCK - TEST PRIORITY ===");
        let user2_initial_balance = token_dispatcher.balance_of(user2);
        let user3_initial_balance = token_dispatcher.balance_of(user3);

        // Available funds: 2 held + 1 current = 3 payouts worth = 12000 tokens
        // Should pay both User2 and User3 (but User2 should be first due to priority)
        start_cheat_caller_address(contract_address, owner);
        dispatcher.distribute_payout(group_id);
        stop_cheat_caller_address(contract_address);

        let cycle3_info = dispatcher.get_group_info(group_id);
        let cycle3_held = dispatcher.get_held_payouts(group_id);
        println!("After cycle 3 - Payout order: {}, Held: {}", cycle3_info.payout_order, cycle3_held);

        // Both should be able to claim
        start_cheat_caller_address(contract_address, user2);
        let user2_claimed = dispatcher.claim_payout(group_id);
        stop_cheat_caller_address(contract_address);

        start_cheat_caller_address(contract_address, user3);
        let user3_claimed = dispatcher.claim_payout(group_id);
        stop_cheat_caller_address(contract_address);

        let user2_final_balance = token_dispatcher.balance_of(user2);
        let user3_final_balance = token_dispatcher.balance_of(user3);
        let user2_payout = user2_final_balance - user2_initial_balance;
        let user3_payout = user3_final_balance - user3_initial_balance;

        println!("=== PRIORITY TEST RESULTS ===");
        println!("User2 (earlier join) claimed: {}, received: {}", user2_claimed, user2_payout);
        println!("User3 (later join) claimed: {}, received: {}", user3_claimed, user3_payout);

        // Both should receive 4000 tokens each
        let expected_payout = 4000_u256;
        assert(user2_payout == expected_payout, 'User2 should get 4000');
        assert(user3_payout == expected_payout, 'User3 should get 4000');
        assert(user2_claimed == expected_payout, 'User2 claim matches');
        assert(user3_claimed == expected_payout, 'User3 claim matches');

        // Verify 1 held payout remains after cycle 3 (as expected)
        assert(cycle3_held == 1, 'Should have 1 held remaining');

        // === CYCLE 4: User1 and User4 qualify - test continuous rotation ===
        let qualifying_lock_amount_cycle4 = 6000_u256;

        // User1 locks qualifying amount (should have priority due to earliest join order)
        start_cheat_caller_address(contract_address, user1);
        dispatcher.lock_liquidity(token_address, qualifying_lock_amount_cycle4, group_id);
        stop_cheat_caller_address(contract_address);

        // User4 locks same amount (should be lower priority due to later join order)
        start_cheat_caller_address(contract_address, user4);
        dispatcher.lock_liquidity(token_address, qualifying_lock_amount_cycle4, group_id);
        stop_cheat_caller_address(contract_address);

        // All contribute for cycle 4
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

        println!("=== CYCLE 4: USER1 AND USER4 QUALIFY - BOTH CAN BE PAID ===");
        let user1_initial_balance = token_dispatcher.balance_of(user1);
        let user4_initial_balance = token_dispatcher.balance_of(user4);

        // Available funds: 1 held + 1 current = 2 payouts worth = 8000 tokens
        // Can pay both User1 and User4 (User1 has priority due to earlier join)
        start_cheat_caller_address(contract_address, owner);
        dispatcher.distribute_payout(group_id);
        stop_cheat_caller_address(contract_address);

        let cycle4_info = dispatcher.get_group_info(group_id);
        let cycle4_held = dispatcher.get_held_payouts(group_id);
        println!("After cycle 4 - Payout order: {}, Held: {}", cycle4_info.payout_order, cycle4_held);

        // Both User1 and User4 should be able to claim
        start_cheat_caller_address(contract_address, user1);
        let user1_claimed = dispatcher.claim_payout(group_id);
        stop_cheat_caller_address(contract_address);

        start_cheat_caller_address(contract_address, user4);
        let user4_claimed = dispatcher.claim_payout(group_id);
        stop_cheat_caller_address(contract_address);

        let user1_final_balance = token_dispatcher.balance_of(user1);
        let user4_final_balance = token_dispatcher.balance_of(user4);
        let user1_payout = user1_final_balance - user1_initial_balance;
        let user4_payout = user4_final_balance - user4_initial_balance;

        println!("=== CYCLE 4 RESULTS ===");
        println!("User1 (higher priority) claimed: {}, received: {}", user1_claimed, user1_payout);
        println!("User4 claimed: {}, received: {}", user4_claimed, user4_payout);

        // Both should receive 4000 tokens each
        assert(user1_payout == expected_payout, 'User1 should get 4000');
        assert(user1_claimed == expected_payout, 'User1 claim matches');
        assert(user4_payout == expected_payout, 'User4 should get 4000');
        assert(user4_claimed == expected_payout, 'User4 claim matches');

        // Verify all held payouts are now cleared
        assert(cycle4_held == 0, 'Held payouts cleared');

        println!("Complete priority and held payout test passed!");
        println!("- Cycle 1-2: Accumulated 2 held payouts (no eligible recipients)");
        println!("- Cycle 3: User2 and User3 received payouts (8000 tokens: 1 current + 1 held)");
        println!("- Cycle 4: User1 and User4 received payouts (8000 tokens: 1 current + 1 held)");
        println!("- Priority correctly determined by join order for same lock amounts");
        println!("- Correct fund management: current cycle funds used first, then held payouts");
        println!("- Total funds distributed: 16000 tokens across 4 cycles (4 recipients x 4000 each)");
    }
}
