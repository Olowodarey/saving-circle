#[cfg(test)]
mod test_no_eligible_payout {
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
                "Group 1",
                "First test group",
                5,
                contribution_amount, // Use the passed contribution_amount
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
    fn test_no_eligible_recipients_holds_payout() {
        let (contract_address, owner, token_address) = setup();
        let dispatcher = IsavecircleDispatcher { contract_address };
        let token_dispatcher = IERC20Dispatcher { contract_address: token_address };

        // Setup users with small locked amounts (won't qualify for payout)
        let user1: ContractAddress = contract_address_const::<2>();
        let user2: ContractAddress = contract_address_const::<3>();
        let user3: ContractAddress = contract_address_const::<4>();
        let user4: ContractAddress = contract_address_const::<5>();
        
        let contribution_amount = 1000_u256;
        let token_amount = 100000_u256;

        // Setup first user and group using the helper function
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

        // Users approve contract to spend tokens (need enough for contributions + locking)
        let total_needed = token_amount; // Already large enough for all operations
        
        start_cheat_caller_address(token_address, user2);
        token_dispatcher.approve(contract_address, total_needed);
        stop_cheat_caller_address(token_address);

        start_cheat_caller_address(token_address, user3);
        token_dispatcher.approve(contract_address, total_needed);
        stop_cheat_caller_address(token_address);

        start_cheat_caller_address(token_address, user4);
        token_dispatcher.approve(contract_address, total_needed);
        stop_cheat_caller_address(token_address);

        // Lock small amounts (not enough to qualify for payout)
        // With our restrictive qualification logic requiring 5 cycles worth (5050 tokens),
        // locking only 1000 tokens won't qualify anyone (need 5050)
        let lock_amount = 1000_u256;

        // User1 locks liquidity (already has approval from setup_user_and_group)
        start_cheat_caller_address(contract_address, user1);
        dispatcher.lock_liquidity(token_address, lock_amount, group_id);
        stop_cheat_caller_address(contract_address);

        // User2 locks liquidity
        start_cheat_caller_address(contract_address, user2);
        dispatcher.lock_liquidity(token_address, lock_amount, group_id);
        stop_cheat_caller_address(contract_address);

        // User3 locks liquidity
        start_cheat_caller_address(contract_address, user3);
        dispatcher.lock_liquidity(token_address, lock_amount, group_id);
        stop_cheat_caller_address(contract_address);

        // User4 locks liquidity
        start_cheat_caller_address(contract_address, user4);
        dispatcher.lock_liquidity(token_address, lock_amount, group_id);
        stop_cheat_caller_address(contract_address);

        // Calculate expected amounts (1% insurance fee)
        let _insurance_fee = (contribution_amount * 100) / 10000;
        let _total_payment = contribution_amount + _insurance_fee;

        // All users contribute for the current cycle
        start_cheat_caller_address(contract_address, user1);
        let result1 = dispatcher.contribute(group_id);
        assert(result1 == true, 'User1 contrib should succeed');
        stop_cheat_caller_address(contract_address);

        start_cheat_caller_address(contract_address, user2);
        let result2 = dispatcher.contribute(group_id);
        assert(result2 == true, 'User2 contrib should succeed');
        stop_cheat_caller_address(contract_address);

        start_cheat_caller_address(contract_address, user3);
        let result3 = dispatcher.contribute(group_id);
        assert(result3 == true, 'User3 contrib should succeed');
        stop_cheat_caller_address(contract_address);

        start_cheat_caller_address(contract_address, user4);
        let result4 = dispatcher.contribute(group_id);
        assert(result4 == true, 'User4 contrib should succeed');
        stop_cheat_caller_address(contract_address);

        let initial_group_info = dispatcher.get_group_info(group_id);
        let initial_held_payouts = dispatcher.get_held_payouts(group_id);

        // Try to distribute payout - should hold payout and advance cycle since no one qualifies
        start_cheat_caller_address(contract_address, owner);
        let payout_result = dispatcher.distribute_payout(group_id);
        stop_cheat_caller_address(contract_address);

        assert(payout_result, 'Payout distri should succeed');

        let updated_group_info = dispatcher.get_group_info(group_id);
        let updated_held_payouts = dispatcher.get_held_payouts(group_id);

        // Verify cycle advanced (no eligible recipients, so cycle moves forward)
        assert(updated_group_info.current_cycle == 1, 'Cycle should advance to 1');
        
        // Verify payout was held (added to remaining pool)
        let expected_payout = contribution_amount * 4; // 4 users * 1000 each = 4000
        assert(updated_group_info.remaining_pool_amount == expected_payout, 'Payout held in pool');
        
        // Verify no one was marked for payout (payout_order should remain 0)
        assert(updated_group_info.payout_order == 0, 'No payout marked');
        
        // Verify held payouts counter increased
        assert(updated_held_payouts == initial_held_payouts + 1, 'Held payouts increased');

        println!("No eligible recipients test passed!");
        println!("- Cycle advanced from {} to {}", initial_group_info.current_cycle, updated_group_info.current_cycle);
        println!("- Payout held in remaining pool: {} tokens", updated_group_info.remaining_pool_amount);
        println!("- No recipients marked for payout (payout_order: {})", updated_group_info.payout_order);
        println!("- Held payouts count: {}", updated_held_payouts);
    }
}
