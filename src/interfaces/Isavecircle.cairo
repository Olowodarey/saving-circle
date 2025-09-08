use save_circle::enums::Enums::{LockType, TimeUnit};
use save_circle::structs::Structs::{
    GroupInfo, GroupMember, ProfileViewData, UserActivity, UserGroupDetails, UserProfile,
    UserStatistics,
};
use starknet::ContractAddress;

#[starknet::interface]
pub trait Isavecircle<TContractState> {
    fn register_user(ref self: TContractState, name: ByteArray, avatar: ByteArray) -> bool;

    fn get_user_profile_view_data(
        self: @TContractState, user_address: ContractAddress,
    ) -> ProfileViewData;

    fn create_public_group(
        ref self: TContractState,
        name: ByteArray,
        description: ByteArray,
        member_limit: u32,
        contribution_amount: u256,
        lock_type: LockType,
        cycle_duration: u64,
        cycle_unit: TimeUnit,
        requires_lock: bool,
        min_reputation_score: u32,
    ) -> u256;

    fn get_group_info(self: @TContractState, group_id: u256) -> GroupInfo;

    fn create_private_group(
        ref self: TContractState,
        name: ByteArray,
        description: ByteArray,
        member_limit: u32,
        contribution_amount: u256,
        cycle_duration: u64,
        cycle_unit: TimeUnit,
        invited_members: Array<ContractAddress>,
        requires_lock: bool,
        lock_type: LockType,
        min_reputation_score: u32,
    ) -> u256;

    fn get_user_profile(self: @TContractState, user_address: ContractAddress) -> UserProfile;

    fn join_group(ref self: TContractState, group_id: u256) -> u32;

    fn get_group_member(self: @TContractState, group_id: u256, member_index: u32) -> GroupMember;

    fn get_user_member_index(self: @TContractState, user: ContractAddress, group_id: u256) -> u32;

    fn get_user_joined_groups(
        self: @TContractState, user_address: ContractAddress,
    ) -> Array<UserGroupDetails>;



    fn get_user_statistics(self: @TContractState, user_address: ContractAddress) -> UserStatistics;

    fn is_group_member(self: @TContractState, group_id: u256, user: ContractAddress) -> bool;

    fn lock_liquidity(
        ref self: TContractState, token_address: ContractAddress, amount: u256, group_id: u256,
    ) -> bool;
    fn get_locked_balance(self: @TContractState, user: ContractAddress) -> u256;
    // Withdrawal functions - only callable at end of cycle
    fn withdraw_locked(ref self: TContractState, group_id: u256) -> u256;
    fn has_completed_circle(self: @TContractState, user: ContractAddress, group_id: u256) -> bool;
    fn contribute(ref self: TContractState, group_id: u256) -> bool;

    fn get_insurance_pool_balance(self: @TContractState, group_id: u256) -> u256;
    // fn get_protocol_treasury(self: @TContractState) -> u256;
    fn activate_group(ref self: TContractState, group_id: u256) -> bool;
    fn distribute_payout(ref self: TContractState, group_id: u256) -> bool;
    fn withdraw_payout(ref self: TContractState) -> u256;
    fn get_pending_payout(self: @TContractState, user_address: ContractAddress) -> u256;
    fn get_user_withdrawal_info(self: @TContractState, user_address: ContractAddress) -> (u256, u256, u256);
    fn get_next_payout_recipient(self: @TContractState, group_id: u256) -> GroupMember;
    fn get_payout_order(self: @TContractState, group_id: u256) -> Array<ContractAddress>;
    fn admin_withdraw_from_pool(
        ref self: TContractState, group_id: u256, amount: u256, recipient: ContractAddress,
    ) -> bool;


    fn get_group_locked_funds(
        self: @TContractState, group_id: u256,
    ) -> (u256, Array<(ContractAddress, u256)>);
    fn get_cycle_contributors(
        self: @TContractState, group_id: u256, cycle: u64,
    ) -> (u256, Array<(ContractAddress, u256)>);
    fn get_contribution_deadline(
        self: @TContractState, group_id: u256, user: ContractAddress,
    ) -> u64;
 

    fn get_deadline_info(
        self: @TContractState, group_id: u256, user: ContractAddress,
    ) -> (u64, u64, u256, bool);
    fn track_missed_deadline_penalty(
        ref self: TContractState, group_id: u256, user: ContractAddress, penalty_amount: u256,
    ) -> bool;
    fn check_and_apply_deadline_penalty(
        ref self: TContractState, group_id: u256, user: ContractAddress,
    ) -> u256;

    // Admin functions for group management
    fn remove_member_from_group(
        ref self: TContractState, group_id: u256, member_address: ContractAddress,
    ) -> bool;
    fn add_admin(ref self: TContractState, new_admin: ContractAddress) -> bool;
    fn admin_contribute_from_lock(
        ref self: TContractState, group_id: u256, user: ContractAddress,
    ) -> bool;
    
    // Cycle tracking getter functions
    fn get_current_cycle(self: @TContractState, group_id: u256) -> u64;
    fn get_current_cycle_contributors(self: @TContractState, group_id: u256) -> Array<ContractAddress>;
    fn get_group_total_contributions(
        self: @TContractState, group_id: u256,
    ) -> (u256, u256, Array<(ContractAddress, u256)>);
    fn get_held_payouts(self: @TContractState, group_id: u256) -> u32;
    
    // Final pool distribution function
    fn distribute_final_pool(ref self: TContractState, group_id: u256) -> bool;
    
    // Admin function to mark group as completed (enables lock withdrawals)
    fn mark_group_completed(ref self: TContractState, group_id: u256) -> bool;
    
    // Check if admin has marked group as completed
    fn is_group_admin_completed(self: @TContractState, group_id: u256) -> bool;
}

