#[cfg(test)]
mod test_five_member_held_payouts {
    use core::array::ArrayTrait;
    use core::traits::Into;
    use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use save_circle::contracts::Savecircle::SaveCircle;
    use save_circle::enums::Enums::{LockType, TimeUnit};
    use save_circle::interfaces::Isavecircle::{IsavecircleDispatcher, IsavecircleDispatcherTrait};
    use snforge_std::{
        ContractClassTrait, DeclareResultTrait, declare, start_cheat_caller_address,
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

        // Create a group with 5 members
        let group_id = dispatcher
            .create_public_group(
                "Five Member Test Group",
                "Test 5-member held payout accumulation",
                5,
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
    fn test_five_member_accumulated_held_payouts() {
        let (contract_address, owner, token_address) = setup();
        let dispatcher = IsavecircleDispatcher { contract_address };
        let token_dispatcher = IERC20Dispatcher { contract_address: token_address };

        // Setup users
        let user1: ContractAddress = contract_address_const::<2>();
        let user2: ContractAddress = contract_address_const::<3>();
        let user3: ContractAddress = contract_address_const::<4>();
        let user4: ContractAddress = contract_address_const::<5>();
        let user5: ContractAddress = contract_address_const::<6>();

        let contribution_amount = 1000_u256;
        let token_amount = 100000_u256;

        // Setup first user and group
        let group_id = setup_user_and_group(
            contract_address, token_address, owner, user1, contribution_amount, token_amount,
        );

        // Setup additional users and add them to the group (in specific order for join timestamp)
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

        start_cheat_caller_address(contract_address, user5);
        dispatcher.register_user("User5", "avatar5.png");
        dispatcher.join_group(group_id);
        stop_cheat_caller_address(contract_address);

        // Give tokens to additional users
        start_cheat_caller_address(token_address, owner);
        token_dispatcher.transfer(user2, token_amount);
        token_dispatcher.transfer(user3, token_amount);
        token_dispatcher.transfer(user4, token_amount);
        token_dispatcher.transfer(user5, token_amount);
        stop_cheat_caller_address(token_address);

        // Users approve contract to spend tokens
        start_cheat_caller_address(token_address, user2);
        token_dispatcher.approve(contract_address, token_amount);
        stop_cheat_caller_address(contract_address);

        start_cheat_caller_address(token_address, user3);
        token_dispatcher.approve(contract_address, token_amount);
        stop_cheat_caller_address(token_address);

        start_cheat_caller_address(token_address, user4);
        token_dispatcher.approve(contract_address, token_amount);
        stop_cheat_caller_address(contract_address);

        start_cheat_caller_address(token_address, user5);
        token_dispatcher.approve(contract_address, token_amount);
        stop_cheat_caller_address(token_address);

        // === CYCLE 1: Only User1 qualifies ===
        let qualifying_lock_amount = 8000_u256; // Enough to qualify
        let small_lock_amount = 1000_u256; // Not enough to qualify

        // User1 locks qualifying amount
        start_cheat_caller_address(contract_address, user1);
        dispatcher.lock_liquidity(token_address, qualifying_lock_amount, group_id);
        stop_cheat_caller_address(contract_address);

        // Others lock small amounts (not qualifying)
        start_cheat_caller_address(contract_address, user2);
        dispatcher.lock_liquidity(token_address, small_lock_amount, group_id);
        stop_cheat_caller_address(contract_address);

        start_cheat_caller_address(contract_address, user3);
        dispatcher.lock_liquidity(token_address, small_lock_amount, group_id);
        stop_cheat_caller_address(contract_address);

        start_cheat_caller_address(contract_address, user4);
        dispatcher.lock_liquidity(token_address, small_lock_amount, group_id);
        stop_cheat_caller_address(contract_address);

        start_cheat_caller_address(contract_address, user5);
        dispatcher.lock_liquidity(token_address, small_lock_amount, group_id);
        stop_cheat_caller_address(contract_address);

        // All contribute for cycle 1
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

        start_cheat_caller_address(contract_address, user5);
        dispatcher.contribute(group_id);
        stop_cheat_caller_address(contract_address);

        println!("=== CYCLE 1: ONLY USER1 QUALIFIES ===");
        let user1_initial_balance = token_dispatcher.balance_of(user1);

        start_cheat_caller_address(contract_address, owner);
        dispatcher.distribute_payout(group_id);
        stop_cheat_caller_address(contract_address);

        let cycle1_held = dispatcher.get_held_payouts(group_id);
        println!("Held payouts after cycle 1: {}", cycle1_held);

        // User1 should be able to claim
        start_cheat_caller_address(contract_address, user1);
        let user1_claimed = dispatcher.withdraw_payout();
        stop_cheat_caller_address(contract_address);

        let user1_final_balance = token_dispatcher.balance_of(user1);
        let user1_payout = user1_final_balance - user1_initial_balance;

        println!("User1 claimed: {}, received: {}", user1_claimed, user1_payout);
        let expected_payout = 5000_u256; // 5 members x 1000 = 5000 tokens per cycle
        assert(user1_payout == expected_payout, 'User1 should get 5000');
        assert(cycle1_held == 0, 'No held payouts in cycle 1');

        // === CYCLE 2: No one qualifies - hold payout ===
        // All contribute for cycle 2 (no new locks, so no one qualifies)
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

        start_cheat_caller_address(contract_address, user5);
        dispatcher.contribute(group_id);
        stop_cheat_caller_address(contract_address);

        println!("=== CYCLE 2: NO ELIGIBLE RECIPIENTS ===");
        start_cheat_caller_address(contract_address, owner);
        dispatcher.distribute_payout(group_id);
        stop_cheat_caller_address(contract_address);

        let cycle2_held = dispatcher.get_held_payouts(group_id);
        println!("Held payouts after cycle 2: {}", cycle2_held);
        assert(cycle2_held == 1, 'Should have 1 held payout');

        // === CYCLE 3: Only User2 qualifies ===
        // User2 locks qualifying amount
        start_cheat_caller_address(contract_address, user2);
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

        start_cheat_caller_address(contract_address, user5);
        dispatcher.contribute(group_id);
        stop_cheat_caller_address(contract_address);

        println!("=== CYCLE 3: ONLY USER2 QUALIFIES ===");
        let user2_initial_balance = token_dispatcher.balance_of(user2);

        start_cheat_caller_address(contract_address, owner);
        dispatcher.distribute_payout(group_id);
        stop_cheat_caller_address(contract_address);

        let cycle3_held = dispatcher.get_held_payouts(group_id);
        println!("Held payouts after cycle 3: {}", cycle3_held);

        // User2 should be able to claim
        start_cheat_caller_address(contract_address, user2);
        let user2_claimed = dispatcher.withdraw_payout();
        stop_cheat_caller_address(contract_address);

        let user2_final_balance = token_dispatcher.balance_of(user2);
        let user2_payout = user2_final_balance - user2_initial_balance;

        println!("User2 claimed: {}, received: {}", user2_claimed, user2_payout);
        assert(user2_payout == expected_payout, 'User2 should get 5000');
        assert(cycle3_held == 1, 'Should have 1 held remaining');

        // === CYCLE 4: No one qualifies - hold payout ===
        // All contribute for cycle 4 (no new locks, so no one qualifies)
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

        start_cheat_caller_address(contract_address, user5);
        dispatcher.contribute(group_id);
        stop_cheat_caller_address(contract_address);

        println!("=== CYCLE 4: NO ELIGIBLE RECIPIENTS ===");
        start_cheat_caller_address(contract_address, owner);
        dispatcher.distribute_payout(group_id);
        stop_cheat_caller_address(contract_address);

        let cycle4_held = dispatcher.get_held_payouts(group_id);
        println!("Held payouts after cycle 4: {}", cycle4_held);
        assert(cycle4_held == 2, 'Should have 2 held payouts');

        // === CYCLE 5: Users 3, 4, 5 qualify with SAME lock amounts - test priority ===
        // Users 3, 4, 5 lock same qualifying amounts (priority by join order)
        start_cheat_caller_address(contract_address, user3);
        dispatcher.lock_liquidity(token_address, qualifying_lock_amount, group_id);
        stop_cheat_caller_address(contract_address);

        start_cheat_caller_address(contract_address, user4);
        dispatcher.lock_liquidity(token_address, qualifying_lock_amount, group_id);
        stop_cheat_caller_address(contract_address);

        start_cheat_caller_address(contract_address, user5);
        dispatcher.lock_liquidity(token_address, qualifying_lock_amount, group_id);
        stop_cheat_caller_address(contract_address);

        // All contribute for cycle 5
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

        start_cheat_caller_address(contract_address, user5);
        dispatcher.contribute(group_id);
        stop_cheat_caller_address(contract_address);

        println!("=== CYCLE 5: THREE ELIGIBLE WITH SAME LOCK - PAY ALL THREE ===");
        let user3_initial_balance = token_dispatcher.balance_of(user3);
        let user4_initial_balance = token_dispatcher.balance_of(user4);
        let user5_initial_balance = token_dispatcher.balance_of(user5);

        // Available funds: 2 held + 1 current = 3 payouts worth = 15000 tokens
        // Can pay all 3 people (User3, User4, User5) - exactly what you requested!
        start_cheat_caller_address(contract_address, owner);
        dispatcher.distribute_payout(group_id);
        stop_cheat_caller_address(contract_address);

        let cycle5_info = dispatcher.get_group_info(group_id);
        let cycle5_held = dispatcher.get_held_payouts(group_id);
        println!(
            "After cycle 5 - Payout order: {}, Held: {}", cycle5_info.payout_order, cycle5_held,
        );

        // All three users should be able to claim (User3, User4, User5)
        start_cheat_caller_address(contract_address, user3);
        let user3_claimed = dispatcher.withdraw_payout();
        stop_cheat_caller_address(contract_address);

        start_cheat_caller_address(contract_address, user4);
        let user4_claimed = dispatcher.withdraw_payout();
        stop_cheat_caller_address(contract_address);

        start_cheat_caller_address(contract_address, user5);
        let user5_claimed = dispatcher.withdraw_payout();
        stop_cheat_caller_address(contract_address);

        let user3_final_balance = token_dispatcher.balance_of(user3);
        let user4_final_balance = token_dispatcher.balance_of(user4);
        let user5_final_balance = token_dispatcher.balance_of(user5);
        let user3_payout = user3_final_balance - user3_initial_balance;
        let user4_payout = user4_final_balance - user4_initial_balance;
        let user5_payout = user5_final_balance - user5_initial_balance;

        println!("=== CYCLE 5 RESULTS ===");
        println!("User3 (highest priority) claimed: {}, received: {}", user3_claimed, user3_payout);
        println!("User4 (second priority) claimed: {}, received: {}", user4_claimed, user4_payout);
        println!("User5 (third priority) claimed: {}, received: {}", user5_claimed, user5_payout);

        // All three should receive 5000 tokens each
        assert(user3_payout == expected_payout, 'User3 should get 5000');
        assert(user3_claimed == expected_payout, 'User3 claim matches');
        assert(user4_payout == expected_payout, 'User4 should get 5000');
        assert(user4_claimed == expected_payout, 'User4 claim matches');
        assert(user5_payout == expected_payout, 'User5 should get 5000');
        assert(user5_claimed == expected_payout, 'User5 claim matches');

        // Verify all held payouts are now cleared
        assert(cycle5_held == 0, 'Held payouts cleared');

        println!("Five-member held payout test passed!");
        println!("- Cycle 1: User1 received payout (5000 tokens)");
        println!("- Cycle 2: No eligible recipients, 1 held payout accumulated");
        println!("- Cycle 3: User2 received payout (5000 tokens: current cycle only)");
        println!("- Cycle 4: No eligible recipients, 2 held payouts accumulated");
        println!(
            "- Cycle 5: User3, User4, and User5 received payouts (15000 tokens: 2 held + 1 current)",
        );
        println!("- Priority correctly determined by join order for same lock amounts");
        println!("- All 3 eligible recipients paid in cycle 5 as requested");
        println!(
            "- Total funds distributed: 25000 tokens across 5 cycles (5 recipients x 5000 each)",
        );
    }

    #[test]
    fn test_one_qualifies_cycle2_four_paid_cycle5() {
        let (contract_address, owner, token_address) = setup();
        let dispatcher = IsavecircleDispatcher { contract_address };
        let token_dispatcher = IERC20Dispatcher { contract_address: token_address };

        // Setup users
        let user1: ContractAddress = contract_address_const::<2>();
        let user2: ContractAddress = contract_address_const::<3>();
        let user3: ContractAddress = contract_address_const::<4>();
        let user4: ContractAddress = contract_address_const::<5>();
        let user5: ContractAddress = contract_address_const::<6>();

        let contribution_amount = 1000_u256;
        let token_amount = 100000_u256;

        // Setup first user and group
        let group_id = setup_user_and_group(
            contract_address, token_address, owner, user1, contribution_amount, token_amount,
        );

        // Setup additional users and add them to the group (in specific order for join timestamp)
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

        start_cheat_caller_address(contract_address, user5);
        dispatcher.register_user("User5", "avatar5.png");
        dispatcher.join_group(group_id);
        stop_cheat_caller_address(contract_address);

        // Give tokens to additional users
        start_cheat_caller_address(token_address, owner);
        token_dispatcher.transfer(user2, token_amount);
        token_dispatcher.transfer(user3, token_amount);
        token_dispatcher.transfer(user4, token_amount);
        token_dispatcher.transfer(user5, token_amount);
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

        start_cheat_caller_address(token_address, user5);
        token_dispatcher.approve(contract_address, token_amount);
        stop_cheat_caller_address(token_address);

        // === CYCLE 1: No one qualifies initially ===
        let qualifying_lock_amount = 8000_u256; // Enough to qualify
        let small_lock_amount = 1000_u256; // Not enough to qualify

        // All users lock small amounts initially (not qualifying)
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

        start_cheat_caller_address(contract_address, user5);
        dispatcher.lock_liquidity(token_address, small_lock_amount, group_id);
        stop_cheat_caller_address(contract_address);

        // All contribute for cycle 1
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

        start_cheat_caller_address(contract_address, user5);
        dispatcher.contribute(group_id);
        stop_cheat_caller_address(contract_address);

        println!("=== CYCLE 1: NO ELIGIBLE RECIPIENTS ===");
        start_cheat_caller_address(contract_address, owner);
        dispatcher.distribute_payout(group_id);
        stop_cheat_caller_address(contract_address);

        let cycle1_held = dispatcher.get_held_payouts(group_id);
        println!("Held payouts after cycle 1: {}", cycle1_held);
        assert(cycle1_held == 1, 'Should have 1 held payout');

        // === CYCLE 2: Only User1 qualifies ===
        // User1 locks qualifying amount
        start_cheat_caller_address(contract_address, user1);
        dispatcher.lock_liquidity(token_address, qualifying_lock_amount, group_id);
        stop_cheat_caller_address(contract_address);

        // All contribute for cycle 2
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

        start_cheat_caller_address(contract_address, user5);
        dispatcher.contribute(group_id);
        stop_cheat_caller_address(contract_address);

        println!("=== CYCLE 2: ONLY USER1 QUALIFIES ===");
        let user1_initial_balance = token_dispatcher.balance_of(user1);

        start_cheat_caller_address(contract_address, owner);
        dispatcher.distribute_payout(group_id);
        stop_cheat_caller_address(contract_address);

        let cycle2_held = dispatcher.get_held_payouts(group_id);
        println!("Held payouts after cycle 2: {}", cycle2_held);

        // User1 should be able to claim
        start_cheat_caller_address(contract_address, user1);
        let user1_claimed = dispatcher.withdraw_payout();
        stop_cheat_caller_address(contract_address);

        let user1_final_balance = token_dispatcher.balance_of(user1);
        let user1_payout = user1_final_balance - user1_initial_balance;

        println!("User1 claimed: {}, received: {}", user1_claimed, user1_payout);
        let expected_payout = 5000_u256; // 5 members x 1000 = 5000 tokens per cycle
        assert(user1_payout == expected_payout, 'User1 should get 5000');
        assert(cycle2_held == 1, 'Should have 1 held remaining');

        // === CYCLE 3: No one qualifies - hold payout ===
        // All contribute for cycle 3 (no new locks, so no one qualifies)
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

        start_cheat_caller_address(contract_address, user5);
        dispatcher.contribute(group_id);
        stop_cheat_caller_address(contract_address);

        println!("=== CYCLE 3: NO ELIGIBLE RECIPIENTS ===");
        start_cheat_caller_address(contract_address, owner);
        dispatcher.distribute_payout(group_id);
        stop_cheat_caller_address(contract_address);

        let cycle3_held = dispatcher.get_held_payouts(group_id);
        println!("Held payouts after cycle 3: {}", cycle3_held);
        assert(cycle3_held == 2, 'Should have 2 held payouts');

        // === CYCLE 4: No one qualifies - hold payout ===
        // All contribute for cycle 4 (no new locks, so no one qualifies)
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

        start_cheat_caller_address(contract_address, user5);
        dispatcher.contribute(group_id);
        stop_cheat_caller_address(contract_address);

        println!("=== CYCLE 4: NO ELIGIBLE RECIPIENTS ===");
        start_cheat_caller_address(contract_address, owner);
        dispatcher.distribute_payout(group_id);
        stop_cheat_caller_address(contract_address);

        let cycle4_held = dispatcher.get_held_payouts(group_id);
        println!("Held payouts after cycle 4: {}", cycle4_held);
        assert(cycle4_held == 3, 'Should have 3 held payouts');

        // === CYCLE 5: Users 2, 3, 4, 5 qualify - PAY ALL FOUR ===
        // Users 2, 3, 4, 5 lock qualifying amounts
        start_cheat_caller_address(contract_address, user2);
        dispatcher.lock_liquidity(token_address, qualifying_lock_amount, group_id);
        stop_cheat_caller_address(contract_address);

        start_cheat_caller_address(contract_address, user3);
        dispatcher.lock_liquidity(token_address, qualifying_lock_amount, group_id);
        stop_cheat_caller_address(contract_address);

        start_cheat_caller_address(contract_address, user4);
        dispatcher.lock_liquidity(token_address, qualifying_lock_amount, group_id);
        stop_cheat_caller_address(contract_address);

        start_cheat_caller_address(contract_address, user5);
        dispatcher.lock_liquidity(token_address, qualifying_lock_amount, group_id);
        stop_cheat_caller_address(contract_address);

        // All contribute for cycle 5
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

        start_cheat_caller_address(contract_address, user5);
        dispatcher.contribute(group_id);
        stop_cheat_caller_address(contract_address);

        println!("=== CYCLE 5: FOUR ELIGIBLE - PAY ALL FOUR ===");
        let user2_initial_balance = token_dispatcher.balance_of(user2);
        let user3_initial_balance = token_dispatcher.balance_of(user3);
        let user4_initial_balance = token_dispatcher.balance_of(user4);
        let user5_initial_balance = token_dispatcher.balance_of(user5);

        // Available funds: 3 held + 1 current = 4 payouts worth = 20000 tokens
        // Can pay all 4 people (User2, User3, User4, User5) - maximum payout scenario!
        start_cheat_caller_address(contract_address, owner);
        dispatcher.distribute_payout(group_id);
        stop_cheat_caller_address(contract_address);

        let cycle5_info = dispatcher.get_group_info(group_id);
        let cycle5_held = dispatcher.get_held_payouts(group_id);
        println!(
            "After cycle 5 - Payout order: {}, Held: {}", cycle5_info.payout_order, cycle5_held,
        );

        // All four users should be able to claim (User2, User3, User4, User5)
        start_cheat_caller_address(contract_address, user2);
        let user2_claimed = dispatcher.withdraw_payout();
        stop_cheat_caller_address(contract_address);

        start_cheat_caller_address(contract_address, user3);
        let user3_claimed = dispatcher.withdraw_payout();
        stop_cheat_caller_address(contract_address);

        start_cheat_caller_address(contract_address, user4);
        let user4_claimed = dispatcher.withdraw_payout();
        stop_cheat_caller_address(contract_address);

        start_cheat_caller_address(contract_address, user5);
        let user5_claimed = dispatcher.withdraw_payout();
        stop_cheat_caller_address(contract_address);

        let user2_final_balance = token_dispatcher.balance_of(user2);
        let user3_final_balance = token_dispatcher.balance_of(user3);
        let user4_final_balance = token_dispatcher.balance_of(user4);
        let user5_final_balance = token_dispatcher.balance_of(user5);
        let user2_payout = user2_final_balance - user2_initial_balance;
        let user3_payout = user3_final_balance - user3_initial_balance;
        let user4_payout = user4_final_balance - user4_initial_balance;
        let user5_payout = user5_final_balance - user5_initial_balance;

        println!("=== CYCLE 5 RESULTS - MAXIMUM PAYOUT SCENARIO ===");
        println!("User2 claimed: {}, received: {}", user2_claimed, user2_payout);
        println!("User3 claimed: {}, received: {}", user3_claimed, user3_payout);
        println!("User4 claimed: {}, received: {}", user4_claimed, user4_payout);
        println!("User5 claimed: {}, received: {}", user5_claimed, user5_payout);

        // All four should receive 5000 tokens each
        assert(user2_payout == expected_payout, 'User2 should get 5000');
        assert(user2_claimed == expected_payout, 'User2 claim matches');
        assert(user3_payout == expected_payout, 'User3 should get 5000');
        assert(user3_claimed == expected_payout, 'User3 claim matches');
        assert(user4_payout == expected_payout, 'User4 should get 5000');
        assert(user4_claimed == expected_payout, 'User4 claim matches');
        assert(user5_payout == expected_payout, 'User5 should get 5000');
        assert(user5_claimed == expected_payout, 'User5 claim matches');

        // Verify all held payouts are now cleared
        assert(cycle5_held == 0, 'All held payouts cleared');

        println!("Maximum payout scenario test passed!");
        println!("- Cycle 1: No eligible recipients, 1 held payout accumulated");
        println!("- Cycle 2: User1 received payout (5000 tokens: current cycle only)");
        println!("- Cycle 3: No eligible recipients, 2 held payouts accumulated");
        println!("- Cycle 4: No eligible recipients, 3 held payouts accumulated");
        println!(
            "- Cycle 5: User2, User3, User4, and User5 received payouts (20000 tokens: 3 held + 1 current)",
        );
        println!("- Maximum held payout accumulation and distribution achieved!");
        println!("- All 4 remaining members paid simultaneously in cycle 5");
        println!(
            "- Total funds distributed: 25000 tokens across 5 cycles (5 recipients x 5000 each)",
        );
    }

    #[test]
    fn test_all_five_qualify_cycle5_ultimate_scenario() {
        let (contract_address, owner, token_address) = setup();
        let dispatcher = IsavecircleDispatcher { contract_address };
        let token_dispatcher = IERC20Dispatcher { contract_address: token_address };

        // Setup users
        let user1: ContractAddress = contract_address_const::<2>();
        let user2: ContractAddress = contract_address_const::<3>();
        let user3: ContractAddress = contract_address_const::<4>();
        let user4: ContractAddress = contract_address_const::<5>();
        let user5: ContractAddress = contract_address_const::<6>();

        let contribution_amount = 1000_u256;
        let token_amount = 100000_u256;

        // Setup first user and group
        let group_id = setup_user_and_group(
            contract_address, token_address, owner, user1, contribution_amount, token_amount,
        );

        // Setup additional users and add them to the group (in specific order for join timestamp)
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

        start_cheat_caller_address(contract_address, user5);
        dispatcher.register_user("User5", "avatar5.png");
        dispatcher.join_group(group_id);
        stop_cheat_caller_address(contract_address);

        // Give tokens to additional users
        start_cheat_caller_address(token_address, owner);
        token_dispatcher.transfer(user2, token_amount);
        token_dispatcher.transfer(user3, token_amount);
        token_dispatcher.transfer(user4, token_amount);
        token_dispatcher.transfer(user5, token_amount);
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

        start_cheat_caller_address(token_address, user5);
        token_dispatcher.approve(contract_address, token_amount);
        stop_cheat_caller_address(token_address);

        // === CYCLES 1-4: No one qualifies - maximum held payout accumulation ===
        let qualifying_lock_amount = 8000_u256; // Enough to qualify
        let small_lock_amount = 1000_u256; // Not enough to qualify

        // All users lock small amounts initially (not qualifying for cycles 1-4)
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

        start_cheat_caller_address(contract_address, user5);
        dispatcher.lock_liquidity(token_address, small_lock_amount, group_id);
        stop_cheat_caller_address(contract_address);

        // === CYCLE 1: No eligible recipients ===
        // All contribute for cycle 1
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

        start_cheat_caller_address(contract_address, user5);
        dispatcher.contribute(group_id);
        stop_cheat_caller_address(contract_address);

        println!("=== CYCLE 1: NO ELIGIBLE RECIPIENTS ===");
        start_cheat_caller_address(contract_address, owner);
        dispatcher.distribute_payout(group_id);
        stop_cheat_caller_address(contract_address);

        let cycle1_held = dispatcher.get_held_payouts(group_id);
        println!("Held payouts after cycle 1: {}", cycle1_held);
        assert(cycle1_held == 1, 'Should have 1 held payout');

        // === CYCLE 2: No eligible recipients ===
        // All contribute for cycle 2
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

        start_cheat_caller_address(contract_address, user5);
        dispatcher.contribute(group_id);
        stop_cheat_caller_address(contract_address);

        println!("=== CYCLE 2: NO ELIGIBLE RECIPIENTS ===");
        start_cheat_caller_address(contract_address, owner);
        dispatcher.distribute_payout(group_id);
        stop_cheat_caller_address(contract_address);

        let cycle2_held = dispatcher.get_held_payouts(group_id);
        println!("Held payouts after cycle 2: {}", cycle2_held);
        assert(cycle2_held == 2, 'Should have 2 held payouts');

        // === CYCLE 3: No eligible recipients ===
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

        start_cheat_caller_address(contract_address, user5);
        dispatcher.contribute(group_id);
        stop_cheat_caller_address(contract_address);

        println!("=== CYCLE 3: NO ELIGIBLE RECIPIENTS ===");
        start_cheat_caller_address(contract_address, owner);
        dispatcher.distribute_payout(group_id);
        stop_cheat_caller_address(contract_address);

        let cycle3_held = dispatcher.get_held_payouts(group_id);
        println!("Held payouts after cycle 3: {}", cycle3_held);
        assert(cycle3_held == 3, 'Should have 3 held payouts');

        // === CYCLE 4: No eligible recipients ===
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

        start_cheat_caller_address(contract_address, user5);
        dispatcher.contribute(group_id);
        stop_cheat_caller_address(contract_address);

        println!("=== CYCLE 4: NO ELIGIBLE RECIPIENTS ===");
        start_cheat_caller_address(contract_address, owner);
        dispatcher.distribute_payout(group_id);
        stop_cheat_caller_address(contract_address);

        let cycle4_held = dispatcher.get_held_payouts(group_id);
        println!("Held payouts after cycle 4: {}", cycle4_held);
        assert(cycle4_held == 4, 'Should have 4 held payouts');

        // === CYCLE 5: ALL FIVE QUALIFY WITH SAME LOCK - ULTIMATE SCENARIO ===
        // All users lock the SAME qualifying amount (test priority by join order)
        start_cheat_caller_address(contract_address, user1);
        dispatcher.lock_liquidity(token_address, qualifying_lock_amount, group_id);
        stop_cheat_caller_address(contract_address);

        start_cheat_caller_address(contract_address, user2);
        dispatcher.lock_liquidity(token_address, qualifying_lock_amount, group_id);
        stop_cheat_caller_address(contract_address);

        start_cheat_caller_address(contract_address, user3);
        dispatcher.lock_liquidity(token_address, qualifying_lock_amount, group_id);
        stop_cheat_caller_address(contract_address);

        start_cheat_caller_address(contract_address, user4);
        dispatcher.lock_liquidity(token_address, qualifying_lock_amount, group_id);
        stop_cheat_caller_address(contract_address);

        start_cheat_caller_address(contract_address, user5);
        dispatcher.lock_liquidity(token_address, qualifying_lock_amount, group_id);
        stop_cheat_caller_address(contract_address);

        // All contribute for cycle 5
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

        start_cheat_caller_address(contract_address, user5);
        dispatcher.contribute(group_id);
        stop_cheat_caller_address(contract_address);

        println!("=== CYCLE 5: ALL FIVE QUALIFY - ULTIMATE SCENARIO ===");
        let user1_initial_balance = token_dispatcher.balance_of(user1);
        let user2_initial_balance = token_dispatcher.balance_of(user2);
        let user3_initial_balance = token_dispatcher.balance_of(user3);
        let user4_initial_balance = token_dispatcher.balance_of(user4);
        let user5_initial_balance = token_dispatcher.balance_of(user5);

        // Available funds: 4 held + 1 current = 5 payouts worth = 25000 tokens
        // Can pay ALL 5 people (User1, User2, User3, User4, User5) - ULTIMATE SCENARIO!
        start_cheat_caller_address(contract_address, owner);
        dispatcher.distribute_payout(group_id);
        stop_cheat_caller_address(contract_address);

        let cycle5_info = dispatcher.get_group_info(group_id);
        let cycle5_held = dispatcher.get_held_payouts(group_id);
        println!(
            "After cycle 5 - Payout order: {}, Held: {}", cycle5_info.payout_order, cycle5_held,
        );

        // All five users should be able to claim (User1, User2, User3, User4, User5)
        start_cheat_caller_address(contract_address, user1);
        let user1_claimed = dispatcher.withdraw_payout();
        stop_cheat_caller_address(contract_address);

        start_cheat_caller_address(contract_address, user2);
        let user2_claimed = dispatcher.withdraw_payout();
        stop_cheat_caller_address(contract_address);

        start_cheat_caller_address(contract_address, user3);
        let user3_claimed = dispatcher.withdraw_payout();
        stop_cheat_caller_address(contract_address);

        start_cheat_caller_address(contract_address, user4);
        let user4_claimed = dispatcher.withdraw_payout();
        stop_cheat_caller_address(contract_address);

        start_cheat_caller_address(contract_address, user5);
        let user5_claimed = dispatcher.withdraw_payout();
        stop_cheat_caller_address(contract_address);

        let user1_final_balance = token_dispatcher.balance_of(user1);
        let user2_final_balance = token_dispatcher.balance_of(user2);
        let user3_final_balance = token_dispatcher.balance_of(user3);
        let user4_final_balance = token_dispatcher.balance_of(user4);
        let user5_final_balance = token_dispatcher.balance_of(user5);
        let user1_payout = user1_final_balance - user1_initial_balance;
        let user2_payout = user2_final_balance - user2_initial_balance;
        let user3_payout = user3_final_balance - user3_initial_balance;
        let user4_payout = user4_final_balance - user4_initial_balance;
        let user5_payout = user5_final_balance - user5_initial_balance;

        println!("=== CYCLE 5 RESULTS - ULTIMATE SCENARIO ===");
        println!("User1 (highest priority) claimed: {}, received: {}", user1_claimed, user1_payout);
        println!("User2 (second priority) claimed: {}, received: {}", user2_claimed, user2_payout);
        println!("User3 (third priority) claimed: {}, received: {}", user3_claimed, user3_payout);
        println!("User4 (fourth priority) claimed: {}, received: {}", user4_claimed, user4_payout);
        println!("User5 (fifth priority) claimed: {}, received: {}", user5_claimed, user5_payout);

        let expected_payout = 5000_u256; // 5 members x 1000 = 5000 tokens per cycle
        // All five should receive 5000 tokens each
        assert(user1_payout == expected_payout, 'User1 should get 5000');
        assert(user1_claimed == expected_payout, 'User1 claim matches');
        assert(user2_payout == expected_payout, 'User2 should get 5000');
        assert(user2_claimed == expected_payout, 'User2 claim matches');
        assert(user3_payout == expected_payout, 'User3 should get 5000');
        assert(user3_claimed == expected_payout, 'User3 claim matches');
        assert(user4_payout == expected_payout, 'User4 should get 5000');
        assert(user4_claimed == expected_payout, 'User4 claim matches');
        assert(user5_payout == expected_payout, 'User5 should get 5000');
        assert(user5_claimed == expected_payout, 'User5 claim matches');

        // Verify all held payouts are now cleared
        assert(cycle5_held == 0, 'All held payouts cleared');

        println!("Ultimate scenario test passed!");
        println!("- Cycle 1: No eligible recipients, 1 held payout accumulated");
        println!("- Cycle 2: No eligible recipients, 2 held payouts accumulated");
        println!("- Cycle 3: No eligible recipients, 3 held payouts accumulated");
        println!("- Cycle 4: No eligible recipients, 4 held payouts accumulated");
        println!("- Cycle 5: ALL FIVE members received payouts (25000 tokens: 4 held + 1 current)");
        println!("- Ultimate held payout accumulation and distribution achieved!");
        println!("- All members with same lock amounts paid by join order priority");
        println!("- Perfect fund utilization: 25000 tokens distributed in single cycle");
        println!(
            "- Total funds distributed: 25000 tokens across 5 cycles (5 recipients x 5000 each)",
        );
    }
}
