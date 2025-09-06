#[cfg(test)]
mod test_5_cycle_held_payouts {
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

    #[test]
    fn test_complete_5_cycle_with_different_locks_and_withdrawals() {
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

        // Test parameters for held payout accumulation scenario
        let contribution_amount = 1000_u256; // Base contribution amount
        let insurance_rate = 100_u256; // 1% = 100 basis points
        // Lock amounts that DON'T qualify initially (need 5050+ tokens to qualify)
        let initial_lock_amounts = array![1200_u256, 1200_u256, 1500_u256, 2000_u256, 1800_u256]; // Below qualification threshold
        let qualifying_lock_amount = 8000_u256; // Enough to qualify later
        let total_token_per_user = 50000_u256; // Enough for all cycles + locks
        
        // Calculate expected amounts
        let insurance_fee_per_contribution = (contribution_amount * insurance_rate) / 10000; // 1% fee = 10 tokens
        let total_user_pays = contribution_amount + insurance_fee_per_contribution; // 1010 tokens
        let expected_payout_per_cycle = contribution_amount * 5; // 5000 tokens per cycle
        
        println!("Starting 5-Cycle Held Payout Test:");
        println!("- Base contribution per user: {} tokens", contribution_amount);
        println!("- Insurance fee per contribution: {} tokens (1%)", insurance_fee_per_contribution);
        println!("- Total user pays: {} tokens", total_user_pays);
        println!("- Expected payout per cycle: {} tokens", expected_payout_per_cycle);
        println!("- Initial locks (non-qualifying): {:?}", initial_lock_amounts);
        println!("- Qualifying lock amount: {} tokens", qualifying_lock_amount);

        // Register all users
        let mut i = 0;
        while i < users.len() {
            let user = *users.at(i);
            start_cheat_caller_address(contract_address, owner);
            dispatcher.add_admin(user);
            stop_cheat_caller_address(contract_address);

            start_cheat_caller_address(contract_address, user);
            dispatcher.register_user("TestUser", "avatar.png");
            stop_cheat_caller_address(contract_address);
            i += 1;
        }

        // Create group with first user
        start_cheat_caller_address(contract_address, user1);
        let group_id = dispatcher
            .create_public_group(
                "5-Cycle Test Group",
                "Test 5-cycle held payout accumulation",
                5,
                contribution_amount,
                LockType::Progressive,
                1, // 1 day cycle for testing
                TimeUnit::Days,
                true, // requires lock
                0, // min_reputation_score
            );

        // Activate the group
        dispatcher.activate_group(group_id);
        stop_cheat_caller_address(contract_address);

        // All users join and lock funds with initial NON-QUALIFYING amounts
        i = 0;
        while i < users.len() {
            let user = *users.at(i);
            let lock_amount = *initial_lock_amounts.at(i);

            // Transfer tokens to user
            start_cheat_caller_address(token_address, owner);
            token_dispatcher.transfer(user, total_token_per_user);
            stop_cheat_caller_address(token_address);

            // Approve tokens
            start_cheat_caller_address(token_address, user);
            token_dispatcher.approve(contract_address, total_token_per_user);
            stop_cheat_caller_address(token_address);

            // Join group
            start_cheat_caller_address(contract_address, user);
            dispatcher.join_group(group_id);
            stop_cheat_caller_address(contract_address);

            // Lock funds
            start_cheat_caller_address(contract_address, user);
            dispatcher.lock_liquidity(token_address, lock_amount, group_id);
            stop_cheat_caller_address(contract_address);

            println!("User{} locked {} tokens (NON-QUALIFYING)", i + 1, lock_amount);
            i += 1;
        }

        // Verify initial lock amounts (non-qualifying)
        let (total_locked, member_funds) = dispatcher.get_group_locked_funds(group_id);
        assert(member_funds.len() == 5, 'Shld have 5 members with locks');
        assert(total_locked == 7700_u256, 'Total locked should be 7700');
        println!("Initial lock verification passed - all amounts are NON-QUALIFYING");
        println!("Total initial locked: {} tokens", total_locked);

        // Get payout order before starting cycles
        let payout_order = dispatcher.get_payout_order(group_id);
        assert(payout_order.len() == 5, 'Payout order should = 5 users');
        
        // === CYCLE 1: No one qualifies - hold payout ===
        println!("\n=== CYCLE 1: NO ELIGIBLE RECIPIENTS ===");
        
        // All users contribute for cycle 1
        i = 0;
        while i < users.len() {
            let user = *users.at(i);
            start_cheat_caller_address(contract_address, user);
            dispatcher.contribute(group_id);
            stop_cheat_caller_address(contract_address);
            i += 1;
        }
        println!("All 5 users contributed {} tokens each", total_user_pays);
        
        // Distribute payout - should hold since no one qualifies
        start_cheat_caller_address(contract_address, owner);
        dispatcher.distribute_payout(group_id);
        stop_cheat_caller_address(contract_address);
        
        let cycle1_held = dispatcher.get_held_payouts(group_id);
        let cycle1_info = dispatcher.get_group_info(group_id);
        println!("Held payouts after cycle 1: {}", cycle1_held);
        println!("Current cycle after cycle 1: {}", cycle1_info.current_cycle);
        assert(cycle1_held == 1, 'Should have 1 held payout');
        assert(cycle1_info.current_cycle == 1, 'Should be in cycle 1');
        
        // === CYCLE 2: User1 qualifies and gets payout ===
        println!("\n=== CYCLE 2: USER1 QUALIFIES ===");
        
        // User1 locks qualifying amount
        start_cheat_caller_address(contract_address, user1);
        dispatcher.lock_liquidity(token_address, qualifying_lock_amount, group_id);
        stop_cheat_caller_address(contract_address);
        println!("User1 locked additional {} tokens (now qualifying)", qualifying_lock_amount);
        
        // All users contribute for cycle 2
        i = 0;
        while i < users.len() {
            let user = *users.at(i);
            start_cheat_caller_address(contract_address, user);
            dispatcher.contribute(group_id);
            stop_cheat_caller_address(contract_address);
            i += 1;
        }
        println!("All 5 users contributed {} tokens each", total_user_pays);
        
        let user1_initial_balance = token_dispatcher.balance_of(user1);
        
        // Distribute payout - User1 should get it
        start_cheat_caller_address(contract_address, owner);
        dispatcher.distribute_payout(group_id);
        stop_cheat_caller_address(contract_address);
        
        let cycle2_held = dispatcher.get_held_payouts(group_id);
        let cycle2_info = dispatcher.get_group_info(group_id);
        println!("Held payouts after cycle 2: {}", cycle2_held);
        println!("Current cycle after cycle 2: {}", cycle2_info.current_cycle);
        
        // User1 should be able to claim
        start_cheat_caller_address(contract_address, user1);
        let user1_claimed = dispatcher.claim_payout(group_id);
        stop_cheat_caller_address(contract_address);
        
        let user1_final_balance = token_dispatcher.balance_of(user1);
        let user1_payout = user1_final_balance - user1_initial_balance;
        
        println!("User1 claimed: {}, received: {}", user1_claimed, user1_payout);
        assert(user1_payout == expected_payout_per_cycle, 'User1 should get 5000');
        assert(cycle2_held == 1, 'Should have 1 held remaining');
        assert(cycle2_info.current_cycle == 2, 'Should be in cycle 2');
        
        // === CYCLE 3: No one qualifies - hold payout ===
        println!("\n=== CYCLE 3: NO ELIGIBLE RECIPIENTS ===");
        
        // All users contribute for cycle 3 (no new locks, so no one qualifies)
        i = 0;
        while i < users.len() {
            let user = *users.at(i);
            start_cheat_caller_address(contract_address, user);
            dispatcher.contribute(group_id);
            stop_cheat_caller_address(contract_address);
            i += 1;
        }
        println!("All 5 users contributed {} tokens each", total_user_pays);
        
        // Distribute payout - should hold since no one qualifies
        start_cheat_caller_address(contract_address, owner);
        dispatcher.distribute_payout(group_id);
        stop_cheat_caller_address(contract_address);
        
        let cycle3_held = dispatcher.get_held_payouts(group_id);
        let cycle3_info = dispatcher.get_group_info(group_id);
        println!("Held payouts after cycle 3: {}", cycle3_held);
        println!("Current cycle after cycle 3: {}", cycle3_info.current_cycle);
        assert(cycle3_held == 2, 'Should have 2 held payouts');
        assert(cycle3_info.current_cycle == 3, 'Should be in cycle 3');
        
        // === CYCLE 4: User2 and User3 qualify - pay both ===
        println!("\n=== CYCLE 4: USER2 AND USER3 QUALIFY ===");
        
        // User2 and User3 lock qualifying amounts
        start_cheat_caller_address(contract_address, user2);
        dispatcher.lock_liquidity(token_address, qualifying_lock_amount, group_id);
        stop_cheat_caller_address(contract_address);
        println!("User2 locked additional {} tokens (now qualifying)", qualifying_lock_amount);
        
        start_cheat_caller_address(contract_address, user3);
        dispatcher.lock_liquidity(token_address, qualifying_lock_amount, group_id);
        stop_cheat_caller_address(contract_address);
        println!("User3 locked additional {} tokens (now qualifying)", qualifying_lock_amount);
        
        // All users contribute for cycle 4
        i = 0;
        while i < users.len() {
            let user = *users.at(i);
            start_cheat_caller_address(contract_address, user);
            dispatcher.contribute(group_id);
            stop_cheat_caller_address(contract_address);
            i += 1;
        }
        println!("All 5 users contributed {} tokens each", total_user_pays);
        
        let user2_initial_balance = token_dispatcher.balance_of(user2);
        let user3_initial_balance = token_dispatcher.balance_of(user3);
        
        // Available funds: 2 held + 1 current = 3 payouts worth = 15000 tokens
        // Can pay both User2 and User3 (2 people)
        start_cheat_caller_address(contract_address, owner);
        dispatcher.distribute_payout(group_id);
        stop_cheat_caller_address(contract_address);
        
        let cycle4_held = dispatcher.get_held_payouts(group_id);
        let cycle4_info = dispatcher.get_group_info(group_id);
        println!("Held payouts after cycle 4: {}", cycle4_held);
        println!("Current cycle after cycle 4: {}", cycle4_info.current_cycle);
        
        // Both users should be able to claim
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
        
        println!("User2 claimed: {}, received: {}", user2_claimed, user2_payout);
        println!("User3 claimed: {}, received: {}", user3_claimed, user3_payout);
        assert(user2_payout == expected_payout_per_cycle, 'User2 should get 5000');
        assert(user3_payout == expected_payout_per_cycle, 'User3 should get 5000');
        assert(cycle4_held == 1, 'Should have 1 held remaining');
        assert(cycle4_info.current_cycle == 4, 'Should be in cycle 4');
        
        // === CYCLE 5: User4 and User5 qualify - pay both with held payout ===
        println!("\n=== CYCLE 5: USER4 AND USER5 QUALIFY ===");
        
        // User4 and User5 lock qualifying amounts
        start_cheat_caller_address(contract_address, user4);
        dispatcher.lock_liquidity(token_address, qualifying_lock_amount, group_id);
        stop_cheat_caller_address(contract_address);
        println!("User4 locked additional {} tokens (now qualifying)", qualifying_lock_amount);
        
        start_cheat_caller_address(contract_address, user5);
        dispatcher.lock_liquidity(token_address, qualifying_lock_amount, group_id);
        stop_cheat_caller_address(contract_address);
        println!("User5 locked additional {} tokens (now qualifying)", qualifying_lock_amount);
        
        // All users contribute for cycle 5
        i = 0;
        while i < users.len() {
            let user = *users.at(i);
            start_cheat_caller_address(contract_address, user);
            dispatcher.contribute(group_id);
            stop_cheat_caller_address(contract_address);
            i += 1;
        }
        println!("All 5 users contributed {} tokens each", total_user_pays);
        
        let user4_initial_balance = token_dispatcher.balance_of(user4);
        let user5_initial_balance = token_dispatcher.balance_of(user5);
        
        // Available funds: 1 held + 1 current = 2 payouts worth = 10000 tokens
        // Can pay both User4 and User5 (2 people)
        start_cheat_caller_address(contract_address, owner);
        dispatcher.distribute_payout(group_id);
        stop_cheat_caller_address(contract_address);
        
        let cycle5_held = dispatcher.get_held_payouts(group_id);
        let cycle5_info = dispatcher.get_group_info(group_id);
        println!("Held payouts after cycle 5: {}", cycle5_held);
        println!("Current cycle after cycle 5: {}", cycle5_info.current_cycle);
        
        // Both users should be able to claim
        start_cheat_caller_address(contract_address, user4);
        let user4_claimed = dispatcher.claim_payout(group_id);
        stop_cheat_caller_address(contract_address);
        
        start_cheat_caller_address(contract_address, user5);
        let user5_claimed = dispatcher.claim_payout(group_id);
        stop_cheat_caller_address(contract_address);
        
        let user4_final_balance = token_dispatcher.balance_of(user4);
        let user5_final_balance = token_dispatcher.balance_of(user5);
        let user4_payout = user4_final_balance - user4_initial_balance;
        let user5_payout = user5_final_balance - user5_initial_balance;
        
        println!("User4 claimed: {}, received: {}", user4_claimed, user4_payout);
        println!("User5 claimed: {}, received: {}", user5_claimed, user5_payout);
        assert(user4_payout == expected_payout_per_cycle, 'User4 should get 5000');
        assert(user5_payout == expected_payout_per_cycle, 'User5 should get 5000');
        assert(cycle5_held == 0, 'All held payouts cleared');
        assert(cycle5_info.current_cycle == 5, 'Should be in cycle 5');
        
        // === FINAL VERIFICATION ===
        println!("\n=== FINAL VERIFICATION ===");
        
        // Verify all users have been paid
        let mut paid_count = 0;
        i = 0;
        while i < users.len() {
            let member = dispatcher.get_group_member(group_id, i);
            if member.has_been_paid {
                paid_count += 1;
                println!("User{} has been paid: {}", i + 1, member.has_been_paid);
            }
            i += 1;
        }
        assert(paid_count == 5, 'All 5 users should be paid');
        
        // Verify final group state
        let final_info = dispatcher.get_group_info(group_id);
        let final_held = dispatcher.get_held_payouts(group_id);
        println!("Final group state:");
        println!("- Current cycle: {}", final_info.current_cycle);
        println!("- Held payouts: {}", final_held);
        println!("- Payout order: {}", final_info.payout_order);
        
        assert(final_held == 0, 'No held payouts remaining');
        assert(final_info.current_cycle == 5, 'Should be in cycle 5');
        
        println!("\n5-Cycle Held Payout Test PASSED!");
        println!("Summary:");
        println!("- Cycle 1: No eligible recipients, 1 held payout accumulated");
        println!("- Cycle 2: User1 received payout (5000 tokens: current cycle only)");
        println!("- Cycle 3: No eligible recipients, 2 held payouts accumulated");
        println!("- Cycle 4: User2 and User3 received payouts (10000 tokens: 2 held + 1 current)");
        println!("- Cycle 5: User4 and User5 received payouts (10000 tokens: 1 held + 1 current)");
        println!("- All held payouts distributed efficiently");
        println!("- Total funds distributed: 25000 tokens across 5 cycles (5 recipients x 5000 each)");
        println!("- Perfect fund utilization with held payout accumulation and distribution");
    }
}
