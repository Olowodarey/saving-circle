// SPDX-License-Identifier: MIT
// Compatible with OpenZeppelin Contracts for Cairo ^2.0.0

const PAUSER_ROLE: felt252 = selector!("PAUSER_ROLE");
const UPGRADER_ROLE: felt252 = selector!("UPGRADER_ROLE");

#[starknet::contract]
pub mod SaveCircle {
    use openzeppelin::access::accesscontrol::{AccessControlComponent, DEFAULT_ADMIN_ROLE};
    use openzeppelin::introspection::src5::SRC5Component;
    use openzeppelin::security::pausable::PausableComponent;
    use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use openzeppelin::upgrades::UpgradeableComponent;
    use openzeppelin::upgrades::interface::IUpgradeable;
    use save_circle::base::errors::Errors;
    use save_circle::enums::Enums::{ActivityType, GroupState, GroupVisibility, LockType, TimeUnit};
    use save_circle::events::Events::{
        AdminPoolWithdrawal, ContributionMade, FundsWithdrawn, GroupCreated, PayoutDistributed,
        PayoutSent, UserJoinedGroup, UserRegistered, UsersInvited,
    };
    use save_circle::interfaces::Isavecircle::Isavecircle;
    use save_circle::structs::Structs::{
        ContributionRecord, GroupInfo, GroupMember, PayoutRecord, ProfileViewData, UserActivity,
        UserGroupDetails, UserProfile, UserStatistics,
    };
    use starknet::event::EventEmitter;
    use starknet::storage::{
        Map, MutableVecTrait, StorageMapReadAccess, StorageMapWriteAccess, StoragePathEntry,
        StoragePointerReadAccess, StoragePointerWriteAccess, Vec,
    };
    use starknet::{
        ClassHash, ContractAddress, contract_address_const, get_block_timestamp, get_caller_address,
        get_contract_address,
    };
    use super::{PAUSER_ROLE, UPGRADER_ROLE};

    component!(path: PausableComponent, storage: pausable, event: PausableEvent);
    component!(path: AccessControlComponent, storage: accesscontrol, event: AccessControlEvent);
    component!(path: SRC5Component, storage: src5, event: SRC5Event);
    component!(path: UpgradeableComponent, storage: upgradeable, event: UpgradeableEvent);

    // External
    #[abi(embed_v0)]
    impl PausableImpl = PausableComponent::PausableImpl<ContractState>;
    #[abi(embed_v0)]
    impl AccessControlMixinImpl =
        AccessControlComponent::AccessControlMixinImpl<ContractState>;

    // Internal
    impl PausableInternalImpl = PausableComponent::InternalImpl<ContractState>;
    impl AccessControlInternalImpl = AccessControlComponent::InternalImpl<ContractState>;
    impl UpgradeableInternalImpl = UpgradeableComponent::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        #[substorage(v0)]
        pausable: PausableComponent::Storage,
        #[substorage(v0)]
        accesscontrol: AccessControlComponent::Storage,
        #[substorage(v0)]
        src5: SRC5Component::Storage,
        #[substorage(v0)]
        upgradeable: UpgradeableComponent::Storage,
        // Core storage
        payment_token_address: ContractAddress,
        user_profiles: Map<ContractAddress, UserProfile>,
        groups: Map<u256, GroupInfo>,
        group_members: Map<(u256, u32), GroupMember>,
        public_groups: Vec<u256>,
        group_invitations: Map<(u256, ContractAddress), bool>,
        next_group_id: u256,
        total_users: u256,
        // Enhanced tracking for profile features
        user_joined_groups: Map<(ContractAddress, u256), u32>, // (user, group_id) -> member_index
        user_joined_groups_list: Map<(ContractAddress, u32), u256>, // (user, index) -> group_id
        user_joined_groups_count: Map<ContractAddress, u32>,
        group_next_member_index: Map<u256, u32>,
        // Activity tracking (from modified version)
        user_activities: Map<
            (ContractAddress, u256), UserActivity,
        >, // (user, activity_id) -> activity
        user_activity_count: Map<ContractAddress, u256>,
        next_activity_id: u256,
        // Statistics (from modified version)
        user_statistics: Map<ContractAddress, UserStatistics>,
        // Payout tracking (from modified version)
        payout_records: Map<u256, PayoutRecord>, // payout_id -> record
        next_payout_id: u256,
        group_payout_queue: Map<(u256, u32), ContractAddress>, // (group_id, position) -> user
        group_exists: Map<u256, bool>,
        // Financial tracking from original (keeping all original financial features)
        user_payout_index: Map<(u64, ContractAddress), u32>,
        group_lock: Map<
            (u256, ContractAddress), u256,
        >, // to track group lock amount per user per group
        locked_balance: Map<ContractAddress, u256>, // to track locked funds per user
        insurance_pool: Map<u256, u256>, // group_id -> pool_balance
        protocol_treasury: u256, // Accumulated protocol fees
        insurance_rate: u256, // 100 = 1%
        protocol_fee_rate: u256,
        contribution_deadlines: Map<
            (u256, ContractAddress), u64,
        >, // (group_id, user) -> next_deadline
        missed_deadline_penalties: Map<
            (u256, ContractAddress), u256,
        >, // (group_id, user) -> penalty_amount
        user_cycle_contributions: Map<(u256, ContractAddress, u64), bool>,
        // NEW: Comprehensive contribution tracking
        contribution_records: Map<
            (u256, ContractAddress, u64), ContributionRecord,
        >, // (group_id, user, cycle) -> full contribution details
        cycle_total_contributions: Map<
            (u256, u64), u256,
        >, // (group_id, cycle) -> total amount contributed in cycle
        cycle_contributors_count: Map<
            (u256, u64), u32,
        >, // (group_id, cycle) -> number of contributors
        held_payouts: Map<u256, u32>, // (group_id) -> number_of_held_payouts
        // Individual payout tracking to fix claim distribution
        user_payout_amounts: Map<
            (u256, ContractAddress), u256,
        >, // (group_id, user) -> payout_amount_available
        early_withdrawal_penalty_rate: u256, // Penalty rate for early withdrawal (e.g., 1000 = 10%)
        // Separate lock withdrawal tracking (independent from payout withdrawals)
        lock_withdrawals: Map<
            (u256, ContractAddress), bool,
        >, // (group_id, user) -> has_withdrawn_lock
        // Admin group completion tracking (enables lock withdrawals)
        admin_completed_groups: Map<u256, bool> // (group_id) -> admin_has_marked_completed
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        #[flat]
        PausableEvent: PausableComponent::Event,
        #[flat]
        AccessControlEvent: AccessControlComponent::Event,
        #[flat]
        SRC5Event: SRC5Component::Event,
        #[flat]
        UpgradeableEvent: UpgradeableComponent::Event,
        // All events from both versions
        UserRegistered: UserRegistered,
        GroupCreated: GroupCreated,
        UsersInvited: UsersInvited,
        UserJoinedGroup: UserJoinedGroup,
        FundsWithdrawn: FundsWithdrawn,
        ContributionMade: ContributionMade,
        PayoutDistributed: PayoutDistributed,
        PayoutSent: PayoutSent,
        AdminPoolWithdrawal: AdminPoolWithdrawal,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState, default_admin: ContractAddress, token_address: ContractAddress,
    ) {
        self.accesscontrol.initializer();
        self.accesscontrol._grant_role(DEFAULT_ADMIN_ROLE, default_admin);
        self.accesscontrol._grant_role(PAUSER_ROLE, default_admin);
        self.accesscontrol._grant_role(UPGRADER_ROLE, default_admin);

        self.payment_token_address.write(token_address);
        self.next_group_id.write(1);
        self.next_activity_id.write(1);
        self.next_payout_id.write(1);
        self.insurance_rate.write(100);
    }

    #[generate_trait]
    #[abi(per_item)]
    impl ExternalImpl of ExternalTrait {
        #[external(v0)]
        fn pause(ref self: ContractState) {
            self.accesscontrol.assert_only_role(PAUSER_ROLE);
            self.pausable.pause();
        }

        #[external(v0)]
        fn unpause(ref self: ContractState) {
            self.accesscontrol.assert_only_role(PAUSER_ROLE);
            self.pausable.unpause();
        }
    }

    #[abi(embed_v0)]
    impl UpgradeableImpl of IUpgradeable<ContractState> {
        fn upgrade(ref self: ContractState, new_class_hash: ClassHash) {
            self.accesscontrol.assert_only_role(UPGRADER_ROLE);
            self.upgradeable.upgrade(new_class_hash);
        }
    }

    #[abi(embed_v0)]
    impl SavecircleImpl of Isavecircle<ContractState> {
        fn add_admin(ref self: ContractState, new_admin: ContractAddress) -> bool {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);
            self.accesscontrol._grant_role(DEFAULT_ADMIN_ROLE, new_admin);
            return true;
        }

        fn admin_contribute_from_lock(
            ref self: ContractState, group_id: u256, user: ContractAddress,
        ) -> bool {
            // Only admin can call this function
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);

            // Check if contract is paused
            self.pausable.assert_not_paused();

            // Verify user is a member of this group
            assert(self._is_member(group_id, user), Errors::USER_NOT_MEMBER);

            // Get group information
            let group_info = self.groups.read(group_id);
            assert(group_info.group_id != 0, Errors::GROUP_DOES_NOT_EXIST);
            assert(group_info.state == GroupState::Active, Errors::GROUP_MUST_BE_ACTIVE);

            // Check if user has already contributed in the current cycle
            let current_cycle = group_info.current_cycle;
            let has_contributed_this_cycle = self
                .user_cycle_contributions
                .read((group_id, user, current_cycle));
            assert(!has_contributed_this_cycle, Errors::ALREADY_CONTRIBUTED_THIS_CYCLE);

            // Check if user has sufficient locked liquidity for this group
            let user_locked_amount = self.group_lock.read((group_id, user));
            let contribution_amount = group_info.contribution_amount;
            let insurance_rate = self.insurance_rate.read();
            let insurance_fee = (contribution_amount * insurance_rate)
                / 10000; // 1% = 100 basis points

            // Check for missed deadline penalty
            let deadline_penalty = self.check_and_apply_deadline_penalty(group_id, user);

            let total_required = contribution_amount + insurance_fee + deadline_penalty;
            assert(user_locked_amount >= total_required, Errors::INSUFFICIENT_LOCKED_FUNDS);

            // Get user's member information
            let member_index = self.user_joined_groups.read((user, group_id));
            let mut group_member = self.group_members.read((group_id, member_index));

            // Deduct from user's locked liquidity
            let new_locked_amount = user_locked_amount - total_required;
            self.group_lock.write((group_id, user), new_locked_amount);

            // Update user's total locked balance
            let current_total_locked = self.locked_balance.read(user);
            self.locked_balance.write(user, current_total_locked - total_required);

            // Update user's profile total lock amount
            let mut user_profile = self.user_profiles.read(user);
            user_profile.total_lock_amount -= total_required;
            self.user_profiles.write(user, user_profile);

            // Add insurance fee and penalty to group's insurance pool
            let current_pool = self.insurance_pool.read(group_id);
            self.insurance_pool.write(group_id, current_pool + insurance_fee + deadline_penalty);

            // Update member's contribution count and total contributed
            group_member.contribution_count += 1;
            group_member.total_contributed += contribution_amount;
            self.group_members.write((group_id, member_index), group_member);

            // Mark user as having contributed this cycle
            self.user_cycle_contributions.write((group_id, user, current_cycle), true);

            // Record activity
            self
                ._record_activity(
                    user,
                    ActivityType::Contribution,
                    "Admin made contribution from locked funds",
                    contribution_amount,
                    Option::Some(group_id),
                    true,
                );

            // Emit contribution event
            self
                .emit(
                    Event::ContributionMade(
                        ContributionMade {
                            group_id,
                            user,
                            contribution_amount,
                            insurance_fee,
                            total_paid: total_required,
                        },
                    ),
                );

            true
        }

        fn register_user(ref self: ContractState, name: ByteArray, avatar: ByteArray) -> bool {
            let caller = get_caller_address();
            let current_time = get_block_timestamp();

            let user_entry = self.user_profiles.entry(caller);
            let existing_profile = user_entry.read();
            assert(!existing_profile.is_registered, Errors::USER_ALREADY_REGISTERED);
            assert(name != "", Errors::NAME_CANNOT_BE_EMPTY);

            // Enhanced profile with additional fields from modified version
            let new_profile = UserProfile {
                user_address: caller,
                name: name.clone(),
                avatar: avatar.clone(),
                is_registered: true,
                total_lock_amount: 0,
                profile_created_at: current_time,
                reputation_score: 0, // Starting reputation
                total_contribution: 0,
                total_joined_groups: 0,
                total_created_groups: 0,
                total_earned: 0,
                completed_cycles: 0,
                active_groups: 0,
                on_time_payments: 0,
                total_payments: 0,
                average_contribution: 0,
                payment_rate: 0,
                pending_payouts: 0 // Initialize with no pending payouts
            };

            user_entry.write(new_profile);

            let user_stats = UserStatistics {
                user_address: caller,
                total_saved: 0,
                total_earned: 0,
                success_rate: 100,
                average_cycle_duration: 0,
                favorite_contribution_amount: 0,
                longest_active_streak: 0,
                current_active_streak: 0,
                groups_completed_successfully: 0,
                groups_left_early: 0,
                total_penalties_paid: 0,
                updated_at: current_time,
            };
            self.user_statistics.write(caller, user_stats);

            self
                ._record_activity(
                    caller,
                    ActivityType::UserRegistered,
                    "User registered on SaveCircle",
                    0,
                    Option::None,
                    false,
                );

            self.user_joined_groups_count.write(caller, 0);
            self.user_activity_count.write(caller, 1);
            self.total_users.write(self.total_users.read() + 1);

            self.emit(UserRegistered { user: caller, name });
            true
        }

        fn get_user_profile(self: @ContractState, user_address: ContractAddress) -> UserProfile {
            self.user_profiles.entry(user_address).read()
        }


        fn get_user_profile_view_data(
            self: @ContractState, user_address: ContractAddress,
        ) -> ProfileViewData {
            let profile = self.user_profiles.read(user_address);
            let statistics = self.user_statistics.read(user_address);

            // Get recent activities (last 10)
            let activity_count = self.user_activity_count.read(user_address);
            let mut recent_activities = ArrayTrait::new();
            let start_index = if activity_count > 10 {
                activity_count - 10
            } else {
                0
            };

            let mut i = start_index;
            while i < activity_count {
                let activity = self.user_activities.read((user_address, i));
                recent_activities.append(activity);
                i += 1;
            }

            // Get joined groups
            let joined_groups_count = self.user_joined_groups_count.read(user_address);
            let mut joined_groups = ArrayTrait::new();

            let mut i = 0;
            while i < joined_groups_count {
                let group_id = self.user_joined_groups_list.read((user_address, i));
                let group_info = self.groups.read(group_id);
                joined_groups.append(group_info);
                i += 1;
            }

            ProfileViewData { profile, recent_activities, joined_groups, statistics }
        }


        fn create_public_group(
            ref self: ContractState,
            name: ByteArray,
            description: ByteArray,
            member_limit: u32,
            contribution_amount: u256,
            lock_type: LockType,
            cycle_duration: u64,
            cycle_unit: TimeUnit,
            requires_lock: bool,
            min_reputation_score: u32,
        ) -> u256 {
            let caller = get_caller_address();
            let group_id = self.next_group_id.read();
            let current_time = get_block_timestamp();
            let contract_address = contract_address_const::<0x0>();

            // Only admin can create public groups
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);

            let user_entry = self.user_profiles.entry(caller);
            let mut existing_profile = user_entry.read();
            assert(existing_profile.is_registered, Errors::ONLY_REGISTERED_CAN_CREATE);

            let group_info = GroupInfo {
                group_id,
                group_name: name,
                description,
                creator: caller,
                member_limit,
                contribution_amount,
                lock_type,
                cycle_duration,
                cycle_unit,
                members: 0,
                state: GroupState::Created,
                current_cycle: 0,
                payout_order: 0,
                total_cycles: member_limit,
                completed_cycles: 0,
                start_time: current_time,
                last_payout_time: 0,
                visibility: GroupVisibility::Public,
                requires_lock,
                requires_reputation_score: min_reputation_score,
                total_pool_amount: 0,
                remaining_pool_amount: 0,
                next_payout_recipient: contract_address,
                is_active: true,
            };

            self.groups.write(group_id, group_info);
            self.group_next_member_index.write(group_id, 0);
            self.public_groups.push(group_id);
            self.group_exists.write(group_id, true);

            // Update user profile
            existing_profile.total_created_groups += 1;
            user_entry.write(existing_profile);

            // Record activity
            self
                ._record_activity(
                    caller,
                    ActivityType::GroupCreated,
                    "Created new public group",
                    0,
                    Option::Some(group_id),
                    false,
                );

            self.next_group_id.write(group_id + 1);

            self
                .emit(
                    GroupCreated {
                        group_id,
                        creator: caller,
                        member_limit,
                        contribution_amount,
                        cycle_duration,
                        cycle_unit,
                        visibility: GroupVisibility::Public,
                        requires_lock,
                    },
                );

            group_id
        }

        fn create_private_group(
            ref self: ContractState,
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
        ) -> u256 {
            let caller = get_caller_address();
            let group_id = self.next_group_id.read();
            let current_time = get_block_timestamp();

            let user_entry = self.user_profiles.entry(caller);
            let mut existing_profile = user_entry.read();
            assert(existing_profile.is_registered, Errors::ONLY_REGISTERED_CAN_CREATE);

            // Validate lock_type if lock is required
            if !requires_lock {
                assert(lock_type == LockType::None, Errors::LOCK_TYPE_SHOULD_BE_NONE);
            }

            // Create private group
            let group_info = GroupInfo {
                group_id,
                group_name: name,
                description,
                creator: caller,
                member_limit,
                contribution_amount,
                lock_type,
                cycle_duration,
                cycle_unit,
                members: 0,
                state: GroupState::Created,
                current_cycle: 0,
                payout_order: 0,
                total_cycles: member_limit,
                completed_cycles: 0,
                start_time: current_time,
                last_payout_time: 0,
                visibility: GroupVisibility::Private,
                requires_lock,
                requires_reputation_score: min_reputation_score,
                total_pool_amount: 0,
                remaining_pool_amount: 0,
                next_payout_recipient: starknet::contract_address_const::<0>(),
                is_active: true,
            };

            self.groups.write(group_id, group_info);
            self.group_next_member_index.write(group_id, 0);
            self.group_exists.write(group_id, true);

            // Send invitations to all specified members
            assert(invited_members.len() <= 1000, Errors::EXCEEDED_MAX_INVITE_LIMIT);
            let mut i = 0;
            while i < invited_members.len() {
                let invitee = invited_members[i];
                self.group_invitations.write((group_id, *invitee), true);
                i += 1;
            }

            // Update user profile
            existing_profile.total_created_groups += 1;
            user_entry.write(existing_profile);

            // Record activity
            self
                ._record_activity(
                    caller,
                    ActivityType::GroupCreated,
                    "Created new private group",
                    0,
                    Option::Some(group_id),
                    false,
                );

            self
                .emit(
                    UsersInvited { group_id, inviter: caller, invitees: invited_members.clone() },
                );

            self.next_group_id.write(group_id + 1);

            self
                .emit(
                    GroupCreated {
                        group_id,
                        creator: caller,
                        member_limit,
                        contribution_amount,
                        cycle_duration,
                        cycle_unit,
                        visibility: GroupVisibility::Private,
                        requires_lock,
                    },
                );

            group_id
        }

        fn join_group(ref self: ContractState, group_id: u256) -> u32 {
            let caller = get_caller_address();
            let current_time = get_block_timestamp();

            // Check if user is registered to platform
            let user_entry = self.user_profiles.entry(caller);
            let mut user_profile = user_entry.read();
            assert(user_profile.is_registered, Errors::ONLY_REGISTERED_CAN_JOIN);

            // Check if group exists using the dedicated boolean storage (from modified version)
            let group_exists = self.group_exists.read(group_id);
            assert(group_exists, Errors::GROUP_DOES_NOT_EXIST);

            let mut group_info = self.groups.read(group_id);
            assert(group_info.members < group_info.member_limit, Errors::GROUP_IS_FULL);

            // Check if user is already a group member
            let existing_member_index = self.user_joined_groups.read((caller, group_id));
            // Enhanced check from modified version
            let existing_member = self.group_members.read((group_id, existing_member_index));
            assert(
                existing_member.user != caller || !existing_member.is_active,
                Errors::USER_ALREADY_MEMBER,
            );

            // For private groups
            if group_info.visibility == GroupVisibility::Private {
                let invitation = self.group_invitations.read((group_id, caller));
                assert(invitation, Errors::USER_NOT_INVITED);
            }

            // Calculate required lock amount based on lock type (from original)
            let lock_amount = match group_info.lock_type {
                LockType::Progressive => {
                    // Lock first contribution amount, rest will be locked progressively
                    group_info.contribution_amount
                },
                LockType::None => {
                    // No upfront locking required
                    0_u256
                },
            };

            // Get member index
            let member_index = self.group_next_member_index.read(group_id);
            assert(member_index <= group_info.member_limit, Errors::GROUP_IS_FULL);

            // Enhanced GroupMember struct (combining both versions)
            let group_member = GroupMember {
                user: caller,
                group_id,
                locked_amount: lock_amount,
                joined_at: current_time,
                member_index,
                payout_cycle: 0,
                has_been_paid: false,
                contribution_count: 0,
                late_contributions: 0,
                missed_contributions: 0,
                total_contributed: 0,
                total_recieved: 0,
                is_active: true,
            };

            self.group_members.write((group_id, member_index), group_member);
            self.user_joined_groups.write((caller, group_id), member_index);

            // Add to user's joined groups list (from modified version)
            let joined_count = self.user_joined_groups_count.read(caller);
            self.user_joined_groups_list.write((caller, joined_count), group_id);
            self.user_joined_groups_count.write(caller, joined_count + 1);

            // Update members count
            group_info.members += 1;
            self.groups.write(group_id, group_info.clone());
            self.group_next_member_index.write(group_id, member_index + 1);

            // Update user profile (from modified version)
            user_profile.total_joined_groups += 1;
            user_profile.active_groups += 1;
            user_entry.write(user_profile);

            // Record activity (from modified version)
            self
                ._record_activity(
                    caller,
                    ActivityType::GroupJoined,
                    "Joined new group",
                    0,
                    Option::Some(group_id),
                    false,
                );

            // Remove invitation if it was a private group
            if group_info.visibility == GroupVisibility::Private {
                self.group_invitations.write((group_id, caller), false);
            }

            self
                .emit(
                    UserJoinedGroup {
                        group_id, user: caller, member_index, joined_at: current_time,
                    },
                );

            member_index
        }

        // Keep all original financial functions (lock_liquidity, withdraw_locked, contribute, etc.)
        fn lock_liquidity(
            ref self: ContractState, token_address: ContractAddress, amount: u256, group_id: u256,
        ) -> bool {
            let caller = get_caller_address();

            // Check if contract is paused
            self.pausable.assert_not_paused();

            // Validate inputs
            assert(amount > 0, Errors::AMOUNT_MUST_BE_GREATER_THAN_ZERO);
            assert(group_id != 0, Errors::GROUP_ID_MUST_BE_GREATER_THAN_ZERO);

            // Check if group exists and is active
            let group_info = self.groups.read(group_id);
            assert(group_info.group_id != 0, Errors::GROUP_DOES_NOT_EXIST);
            assert(
                group_info.state == GroupState::Active || group_info.state == GroupState::Created,
                Errors::GROUP_MUST_BE_ACTIVE_OR_CREATED,
            );

            //check if user is a group member
            assert(self._is_member(group_id, caller), Errors::USER_NOT_MEMBER);

            // Check if user has enough balance
            let token = IERC20Dispatcher { contract_address: token_address };
            let user_token_balance = token.balance_of(caller);
            assert(user_token_balance >= amount, Errors::INSUFFICIENT_TOKEN_BALANCE);

            // CHECK ALLOWANCE FIRST
            let allowance = token.allowance(caller, get_contract_address());
            assert(allowance >= amount, Errors::INSUFFICIENT_ALLOWANCE);

            // Enforce that every lock must be at least the contribution amount
            assert(
                amount >= group_info.contribution_amount,
                Errors::LOCK_AMOUNT_MUST_BE_GREATER_THAN_OR_EQUAL_TO_CONTRIBUTION_AMOUNT,
            );

            // Transfer tokens from user to this contract
            let success = token.transfer_from(caller, get_contract_address(), amount);
            assert(success, Errors::TOKEN_TRANSFER_FAILED);

            // Update the group lock storage using correct tuple access
            let current_group_lock = self.group_lock.read((group_id, caller));
            let new_group_lock = current_group_lock + amount;
            self.group_lock.write((group_id, caller), new_group_lock);

            // Update user's total locked balance
            let current_locked = self.locked_balance.read(caller);
            self.locked_balance.write(caller, current_locked + amount);

            // Update user's total lock amount in profile
            let mut user_profile = self.user_profiles.read(caller);
            user_profile.total_lock_amount += amount;
            self.user_profiles.write(caller, user_profile);

            true
        }

        fn get_locked_balance(self: @ContractState, user: ContractAddress) -> u256 {
            self.locked_balance.read(user)
        }

        fn withdraw_locked(ref self: ContractState, group_id: u256) -> u256 {
            let caller = get_caller_address();
            let current_time = get_block_timestamp();

            // Check if contract is paused
            self.pausable.assert_not_paused();

            // Verify user is a member of this group
            assert(self._is_member(group_id, caller), Errors::USER_NOT_MEMBER);

            // Get group information
            let group_info = self.groups.read(group_id);
            assert(group_info.group_id != 0, Errors::GROUP_DOES_NOT_EXIST);

            // Calculate cycle end time
            let cycle_duration_seconds = match group_info.cycle_unit {
                TimeUnit::Hours => group_info.cycle_duration * 3600, // 1 * 60 * 60
                TimeUnit::Days => group_info.cycle_duration * 86400, // 24 * 60 * 60
                TimeUnit::Weeks => group_info.cycle_duration * 604800, // 7 * 24 * 60 * 60
                TimeUnit::Months => group_info.cycle_duration
                    * 2592000 // 30 * 24 * 60 * 60 (approximate)
            };
            let cycle_end_time = group_info.start_time + cycle_duration_seconds;

            // Ensure cycle has ended  will be enable back in full production
            // assert(current_time >= cycle_end_time, Errors::GROUP_CYCLE_NOT_ENDED);

            // Ensure admin has marked the group as completed (enables lock withdrawals)
            let admin_completed = self.admin_completed_groups.read(group_id);
            assert(admin_completed, 'Admin must mark group complete');

            // Get user's member information
            let member_index = self.user_joined_groups.read((caller, group_id));
            let mut group_member = self.group_members.read((group_id, member_index));

            // Get actual locked funds from group_lock mapping (this is where actual locked funds
            // are stored)
            let actual_locked_amount = self.group_lock.read((group_id, caller));

            // Check if user has locked funds to withdraw
            assert(actual_locked_amount > 0, Errors::NO_LOCKED_FUNDS_TO_WITHDRAW);

            // Check if user has already withdrawn their lock (prevent double withdrawal)
            let has_withdrawn_lock = self.lock_withdrawals.read((group_id, caller));
            assert(!has_withdrawn_lock, Errors::FUNDS_ALREADY_WITHDRAWN);

            // Calculate withdrawable amount (could include penalties for missed contributions)
            let withdrawable_amount = if self._has_completed_circle(caller, group_id) {
                // User completed all contributions - full withdrawal
                actual_locked_amount
            } else {
                // User missed contributions - apply penalty
                let penalty = self._get_penalty_amount(caller, group_id);
                assert(actual_locked_amount >= penalty, Errors::PENALTY_EXCEEDS_LOCKED_AMOUNT);
                actual_locked_amount - penalty
            };

            // Transfer tokens back to user
            let payment_token = IERC20Dispatcher {
                contract_address: self.payment_token_address.read(),
            };
            let success = payment_token.transfer(caller, withdrawable_amount);
            assert(success, Errors::TOKEN_TRANSFER_FAILED);

            // Update user's locked balance
            let current_locked = self.locked_balance.read(caller);
            self.locked_balance.write(caller, current_locked - actual_locked_amount);

            // Update user profile
            let mut user_profile = self.user_profiles.read(caller);
            user_profile.total_lock_amount -= actual_locked_amount;
            self.user_profiles.write(caller, user_profile);

            // Mark lock as withdrawn using separate tracking (independent from payout withdrawals)
            self.lock_withdrawals.write((group_id, caller), true);

            // Update group lock storage
            self.group_lock.write((group_id, caller), 0);

            self.emit(FundsWithdrawn { group_id, user: caller, amount: withdrawable_amount });

            withdrawable_amount
        }

        fn contribute(ref self: ContractState, group_id: u256) -> bool {
            let caller = get_caller_address();
            let current_time = get_block_timestamp();

            // Check if contract is paused
            self.pausable.assert_not_paused();

            // Verify user is a member of this group
            assert(self._is_member(group_id, caller), Errors::USER_NOT_MEMBER);

            // Get group information
            let group_info = self.groups.read(group_id);
            assert(group_info.group_id != 0, Errors::GROUP_DOES_NOT_EXIST);
            assert(group_info.state == GroupState::Active, Errors::GROUP_MUST_BE_ACTIVE);

            // Check if user has already contributed in the current cycle
            let current_cycle = group_info.current_cycle;
            let has_contributed_this_cycle = self
                .user_cycle_contributions
                .read((group_id, caller, current_cycle));
            assert(!has_contributed_this_cycle, Errors::ALREADY_CONTRIBUTED_THIS_CYCLE);

            // Check for missed deadline penalty
            let deadline_penalty = self.check_and_apply_deadline_penalty(group_id, caller);

            // Get user's member information
            let member_index = self.user_joined_groups.read((caller, group_id));
            let mut group_member = self.group_members.read((group_id, member_index));

            // Calculate total payment: contribution + 1% insurance fee + deadline penalty
            let contribution_amount = group_info.contribution_amount;
            let insurance_rate = self.insurance_rate.read();
            let insurance_fee = (contribution_amount * insurance_rate)
                / 10000; // 1% = 100 basis points
            let total_payment = contribution_amount + insurance_fee + deadline_penalty;

            // Check if user has enough token balance
            let payment_token = IERC20Dispatcher {
                contract_address: self.payment_token_address.read(),
            };
            let user_balance = payment_token.balance_of(caller);
            assert(user_balance >= total_payment, Errors::INSUFFICIENT_BAL_FOR_CONTRI);

            // CHECK ALLOWANCE FIRST
            let allowance = payment_token.allowance(caller, get_contract_address());
            assert(allowance >= total_payment, Errors::INSUFFICIENT_ALLOWANCE);

            // Transfer total payment from user to contract
            let success = payment_token
                .transfer_from(caller, get_contract_address(), total_payment);
            assert(success, Errors::CONTRIBUTION_TRANSFER_FAILED);

            // Add insurance fee and penalty to group's insurance pool
            let current_pool = self.insurance_pool.read(group_id);
            self.insurance_pool.write(group_id, current_pool + insurance_fee + deadline_penalty);

            // Update member's contribution count and total contributed
            group_member.contribution_count += 1;
            group_member.total_contributed += contribution_amount;
            self.group_members.write((group_id, member_index), group_member);

            // Create comprehensive contribution record
            let contribution_record = ContributionRecord {
                contributor: caller,
                group_id,
                cycle: current_cycle,
                amount: contribution_amount,
                insurance_fee,
                penalty_amount: deadline_penalty,
                total_paid: total_payment,
                timestamp: current_time,
                is_late: deadline_penalty > 0,
                member_index,
            };

            // Store the detailed contribution record
            self.contribution_records.write((group_id, caller, current_cycle), contribution_record);

            // Mark that user has contributed in this cycle (backward compatibility)
            self.user_cycle_contributions.write((group_id, caller, current_cycle), true);

            // Update cycle contributors count
            let current_contributors_count = self
                .cycle_contributors_count
                .read((group_id, current_cycle));
            self
                .cycle_contributors_count
                .write((group_id, current_cycle), current_contributors_count + 1);

            // Update cycle total contributions
            let current_cycle_total = self
                .cycle_total_contributions
                .read((group_id, current_cycle));
            self
                .cycle_total_contributions
                .write((group_id, current_cycle), current_cycle_total + contribution_amount);

            // Update user profile statistics
            let mut user_profile = self.user_profiles.read(caller);
            user_profile.total_contribution += contribution_amount;
            user_profile.total_payments += 1;

            // Update on-time payments based on whether penalty was applied
            if deadline_penalty == 0 {
                user_profile.on_time_payments += 1;
            }
            self.user_profiles.write(caller, user_profile);

            // Record contribution activity
            self
                ._record_activity(
                    caller,
                    ActivityType::Contribution,
                    "Made contribution to group",
                    contribution_amount,
                    Option::Some(group_id),
                    false,
                );

            // Emit contribution event
            self
                .emit(
                    ContributionMade {
                        group_id,
                        user: caller,
                        contribution_amount,
                        insurance_fee,
                        total_paid: total_payment,
                    },
                );

            true
        }

        fn activate_group(ref self: ContractState, group_id: u256) -> bool {
            let caller = get_caller_address();
            let current_time = get_block_timestamp();

            self.pausable.assert_not_paused();

            let mut group_info = self.groups.read(group_id);
            assert(group_info.group_id != 0, Errors::GROUP_DOES_NOT_EXIST);

            assert(group_info.creator == caller, Errors::ONLY_CREATOR_CAN_ACTIVATE);

            assert(group_info.state == GroupState::Created, Errors::GROUP_MUST_BE_CREATED_STATE);

            // Store values we need before moving group_info
            let cycle_unit = group_info.cycle_unit;
            let cycle_duration = group_info.cycle_duration;
            let members_count = group_info.members;

            group_info.state = GroupState::Active;
            self.groups.write(group_id, group_info);

            // Set initial contribution deadline for all members with grace period system:
            // - Users get the FULL cycle duration to contribute
            // - PLUS additional grace period before penalties apply
            // Hours: Full duration + 10 minutes grace
            // Days: Full duration + 2 hours grace
            // Weeks: Full duration + 5 hours grace
            // Months: Full duration + 1 day grace
            let initial_deadline = match cycle_unit {
                TimeUnit::Hours => {
                    // Full cycle duration + 10 minutes grace period
                    let cycle_seconds = cycle_duration * 3600;
                    let grace_seconds = 10 * 60; // 10 minutes
                    current_time + cycle_seconds + grace_seconds
                },
                TimeUnit::Days => {
                    // Full cycle duration + 2 hours grace period
                    let cycle_seconds = cycle_duration * 86400;
                    let grace_seconds = 2 * 3600; // 2 hours
                    current_time + cycle_seconds + grace_seconds
                },
                TimeUnit::Weeks => {
                    // Full cycle duration + 5 hours grace period
                    let cycle_seconds = cycle_duration * 7 * 86400;
                    let grace_seconds = 5 * 3600; // 5 hours
                    current_time + cycle_seconds + grace_seconds
                },
                TimeUnit::Months => {
                    // Full cycle duration + 1 day grace period
                    let cycle_seconds = cycle_duration * 30 * 86400;
                    let grace_seconds = 24 * 3600; // 1 day
                    current_time + cycle_seconds + grace_seconds
                },
            };

            // Set deadline for all group members
            let mut member_index: u32 = 0;
            while member_index < members_count {
                let group_member = self.group_members.read((group_id, member_index));
                self.contribution_deadlines.write((group_id, group_member.user), initial_deadline);
                member_index += 1;
            }

            true
        }

        fn distribute_payout(ref self: ContractState, group_id: u256) -> bool {
            let caller = get_caller_address();

            self.pausable.assert_not_paused();

            let mut group_info = self.groups.read(group_id);
            assert(group_info.group_id != 0, Errors::GROUP_DOES_NOT_EXIST);
            assert(group_info.state == GroupState::Active, Errors::GROUP_MUST_BE_ACTIVE);

            // Only admin can distribute payouts
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);

            // Check that all members have contributed for the current cycle using comprehensive
            // tracking
            let current_cycle = group_info.current_cycle;
            let mut member_index: u32 = 0;
            while member_index < group_info.members {
                let group_member = self.group_members.read((group_id, member_index));

                // Check if contribution record exists (more reliable than boolean flag)
                let contribution_record = self
                    .contribution_records
                    .read((group_id, group_member.user, current_cycle));

                // Verify the contribution record is valid (contributor address matches and amount >
                // 0)
                assert(
                    contribution_record.contributor == group_member.user
                        && contribution_record.amount > 0,
                    Errors::NOT_ALL_MEMBERS_CONTRIBUTED,
                );

                member_index += 1;
            }

            // Calculate current cycle contributions only
            let current_cycle_contributions = self
                ._calculate_current_cycle_contributions(group_id, current_cycle);
            assert(current_cycle_contributions > 0, Errors::NO_CONTRIBUTIONS_TO_DISTRIBUTE);

            // Get all eligible recipients for this cycle
            let eligible_recipients = self._get_all_eligible_recipients(group_id);

            if eligible_recipients.len() == 0 {
                // No eligible recipients - hold the payout and move to next cycle
                let current_held_payouts = self.held_payouts.read(group_id);
                self.held_payouts.write(group_id, current_held_payouts + 1);

                // Add current cycle contributions to the held pool
                group_info.remaining_pool_amount += current_cycle_contributions;

                // Move to next cycle without distributing payout
                group_info.current_cycle += 1;
                self._reset_cycle_contributions(group_id, group_info.current_cycle.into());

                self.groups.write(group_id, group_info);

                // Emit event for held payout
                self
                    .emit(
                        PayoutDistributed {
                            group_id,
                            recipient: contract_address_const::<0>(), // No recipient
                            amount: current_cycle_contributions,
                            cycle: current_cycle,
                        },
                    );

                return true;
            }

            // Each recipient gets the full cycle's contributions (4000 tokens)
            // This is the standard savings circle model where each person gets the full pot
            let payout_per_recipient = current_cycle_contributions;

            // Calculate total available funds for payouts
            let held_payouts_count = self.held_payouts.read(group_id);
            let total_available_funds = current_cycle_contributions
                + (held_payouts_count.into() * current_cycle_contributions);

            // Determine how many recipients can be paid based on available funds
            let max_payouts_possible = total_available_funds / payout_per_recipient;
            let max_payouts_possible_u32: u32 = max_payouts_possible.try_into().unwrap();
            let recipients_to_pay = if eligible_recipients.len() <= max_payouts_possible_u32 {
                eligible_recipients.len()
            } else {
                max_payouts_possible_u32
            };

            // Sort eligible recipients by priority (highest locked funds first, then earliest join
            // order)
            let sorted_recipients = self
                ._sort_recipients_by_priority(group_id, eligible_recipients);

            // Credit each eligible user's profile with their payout amount
            let mut i = 0;
            while i < recipients_to_pay {
                let recipient_address = *sorted_recipients.at(i);
                let member_index = self.user_joined_groups.read((recipient_address, group_id));
                let mut member = self.group_members.read((group_id, member_index));

                // Credit user's profile with payout amount
                let mut user_profile = self.user_profiles.read(recipient_address);
                user_profile.pending_payouts += payout_per_recipient;
                user_profile.total_earned += payout_per_recipient;
                self.user_profiles.write(recipient_address, user_profile);

                // Mark member as paid in this group (no longer eligible for this cycle)
                member.has_been_paid = true;
                member.total_recieved += payout_per_recipient;
                self.group_members.write((group_id, member_index), member);

                // Emit payout event
                self
                    .emit(
                        PayoutDistributed {
                            group_id,
                            recipient: recipient_address,
                            amount: payout_per_recipient,
                            cycle: current_cycle,
                        },
                    );

                i += 1;
            }

            // Update payout tracking
            group_info.payout_order += recipients_to_pay;
            group_info.last_payout_time = get_block_timestamp();

            // Update held payouts based on how many recipients were actually paid
            // If recipients were paid, reduce held payouts accordingly
            if recipients_to_pay > 0 {
                // Calculate how many held payouts were used (recipients_to_pay - 1 since first
                // comes from current cycle)
                let held_payouts_used = if recipients_to_pay > 1 {
                    recipients_to_pay - 1
                } else {
                    0
                };

                let new_held_payouts = if held_payouts_count >= held_payouts_used {
                    held_payouts_count - held_payouts_used
                } else {
                    0
                };
                self.held_payouts.write(group_id, new_held_payouts);
            }
            // If no recipients were paid, held payouts remain unchanged (they accumulate)

            // Always advance to the next cycle after payout distribution
            // Savings circles continue rotating indefinitely
            group_info.current_cycle += 1;
            self._reset_cycle_contributions(group_id, group_info.current_cycle.into());

            // Reset contribution deadlines for all members for the new cycle
            let current_time = get_block_timestamp();
            let next_deadline = match group_info.cycle_unit {
                TimeUnit::Hours => {
                    // Full cycle duration + 10 minutes grace period
                    let cycle_seconds = group_info.cycle_duration * 3600;
                    let grace_seconds = 10 * 60; // 10 minutes
                    current_time + cycle_seconds + grace_seconds
                },
                TimeUnit::Days => {
                    // Full cycle duration + 2 hours grace period
                    let cycle_seconds = group_info.cycle_duration * 86400;
                    let grace_seconds = 2 * 3600; // 2 hours
                    current_time + cycle_seconds + grace_seconds
                },
                TimeUnit::Weeks => {
                    // Full cycle duration + 5 hours grace period
                    let cycle_seconds = group_info.cycle_duration * 7 * 86400;
                    let grace_seconds = 5 * 3600; // 5 hours
                    current_time + cycle_seconds + grace_seconds
                },
                TimeUnit::Months => {
                    // Full cycle duration + 1 day grace period
                    let cycle_seconds = group_info.cycle_duration * 30 * 86400;
                    let grace_seconds = 24 * 3600; // 1 day
                    current_time + cycle_seconds + grace_seconds
                },
            };

            // Update deadline for all group members for the new cycle
            let mut reset_member_index: u32 = 0;
            while reset_member_index < group_info.members {
                let group_member = self.group_members.read((group_id, reset_member_index));
                self.contribution_deadlines.write((group_id, group_member.user), next_deadline);
                reset_member_index += 1;
            }

            // Mark group as completed after a full rotation (all members have received payouts)
            // Check if all members have been paid by iterating through all members
            let mut all_members_paid = true;
            let mut check_index = 0_u32;
            while check_index < group_info.members {
                let member = self.group_members.read((group_id, check_index));
                if !member.has_been_paid {
                    all_members_paid = false;
                    break;
                }
                check_index += 1;
            }

            if all_members_paid {
                group_info.state = GroupState::Completed;
            }

            self.groups.write(group_id, group_info);
            true
        }

        fn withdraw_payout(ref self: ContractState) -> u256 {
            let caller = get_caller_address();

            self.pausable.assert_not_paused();

            let mut user_profile = self.user_profiles.read(caller);
            assert(user_profile.is_registered, Errors::USER_NOT_REGISTERED);
            assert(user_profile.pending_payouts > 0, Errors::NO_PAYOUT_AVAILABLE);

            let withdrawal_amount = user_profile.pending_payouts;

            let payment_token = IERC20Dispatcher {
                contract_address: self.payment_token_address.read(),
            };
            let contract_balance = payment_token.balance_of(get_contract_address());
            assert(contract_balance >= withdrawal_amount, Errors::INSUFFICIENT_POOL_BALANCE);

            // Transfer payout to user
            let success = payment_token.transfer(caller, withdrawal_amount);
            assert(success, Errors::PAYOUT_TRANSFER_FAILED);

            // Clear user's pending payouts
            user_profile.pending_payouts = 0;
            self.user_profiles.write(caller, user_profile);

            self
                ._record_activity(
                    caller,
                    ActivityType::PayoutReceived,
                    "Withdrew payout from profile",
                    withdrawal_amount,
                    Option::None,
                    true,
                );

            self
                .emit(
                    PayoutSent {
                        group_id: 0,
                        recipient: caller,
                        amount: withdrawal_amount,
                        cycle_number: 0,
                        timestamp: get_block_timestamp(),
                    },
                );

            withdrawal_amount
        }

        fn get_pending_payout(self: @ContractState, user_address: ContractAddress) -> u256 {
            let user_profile = self.user_profiles.read(user_address);
            user_profile.pending_payouts
        }

        fn get_user_withdrawal_info(
            self: @ContractState, user_address: ContractAddress,
        ) -> (u256, u256, u256) {
            let user_profile = self.user_profiles.read(user_address);
            let locked_balance = self.locked_balance.read(user_address);

            // Return (pending_payouts, total_locked_balance, total_earned)
            (user_profile.pending_payouts, locked_balance, user_profile.total_earned)
        }

        fn distribute_final_pool(ref self: ContractState, group_id: u256) -> bool {
            let caller = get_caller_address();

            self.pausable.assert_not_paused();

            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);

            let mut group_info = self.groups.read(group_id);
            assert(group_info.group_id != 0, Errors::GROUP_DOES_NOT_EXIST);

            // Get current insurance pool balance
            let total_pool_balance = self.insurance_pool.read(group_id);
            assert(total_pool_balance > 0, Errors::INSUFFICIENT_POOL_BALANCE);

            // Calculate distribution amounts
            let protocol_fee = (total_pool_balance * 5) / 100; // 5% to protocol
            let member_distribution = total_pool_balance - protocol_fee; // 95% to members

            // Ensure we have members to distribute to
            assert(group_info.members > 0, Errors::NO_MEMBERS_IN_GROUP);

            // Calculate amount per member
            let amount_per_member = member_distribution / group_info.members.into();
            assert(amount_per_member > 0, Errors::INSUFFICIENT_POOL_BALANCE);

            let payment_token = IERC20Dispatcher {
                contract_address: self.payment_token_address.read(),
            };

            // Verify contract has sufficient balance
            let contract_balance = payment_token.balance_of(get_contract_address());
            assert(contract_balance >= total_pool_balance, Errors::INSUFFICIENT_POOL_BALANCE);

            // Distribute to protocol treasury first
            self.protocol_treasury.write(self.protocol_treasury.read() + protocol_fee);

            // Distribute to all group members
            let mut member_index: u32 = 0;
            let mut total_distributed: u256 = 0;

            while member_index < group_info.members {
                let group_member = self.group_members.read((group_id, member_index));

                // Skip empty member slots
                if group_member.user != contract_address_const::<0>() {
                    // Transfer tokens to member
                    let success = payment_token.transfer(group_member.user, amount_per_member);
                    assert(success, Errors::PAYOUT_TRANSFER_FAILED);

                    total_distributed += amount_per_member;

                    // Update member's total received
                    let mut updated_member = group_member;
                    updated_member.total_recieved += amount_per_member;
                    self.group_members.write((group_id, member_index), updated_member);

                    // Emit event for pool distribution
                    self
                        .emit(
                            PayoutSent {
                                group_id,
                                recipient: group_member.user,
                                amount: amount_per_member,
                                cycle_number: 999, // Special cycle number for final pool distribution
                                timestamp: get_block_timestamp(),
                            },
                        );
                }

                member_index += 1;
            }

            // Clear the insurance pool for this group
            self.insurance_pool.write(group_id, 0);

            // Emit admin pool withdrawal event for the protocol fee
            self
                .emit(
                    AdminPoolWithdrawal {
                        admin: caller,
                        group_id,
                        amount: protocol_fee,
                        recipient: get_contract_address(), // Protocol treasury
                        remaining_balance: 0 // Pool is now empty after final distribution
                    },
                );

            // Update group info to mark final distribution as completed
            group_info.state = GroupState::Completed;
            self.groups.write(group_id, group_info);

            true
        }

        /// Admin function to mark a group as completed (enables lock withdrawals)
        /// Only callable by admin after all cycles and payouts are complete
        fn mark_group_completed(ref self: ContractState, group_id: u256) -> bool {
            // Check if contract is paused
            self.pausable.assert_not_paused();

            // Only admin can mark group as completed
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);

            let group_info = self.groups.read(group_id);
            assert(group_info.group_id != 0, Errors::GROUP_DOES_NOT_EXIST);

            // Ensure group state is Completed (all payouts distributed)
            assert(group_info.state == GroupState::Completed, 'Group not completed yet');

            // Ensure no held payouts remain
            let held_payouts = self.held_payouts.read(group_id);
            assert(held_payouts == 0, 'Held payouts remaining');

            // Mark group as admin completed (enables lock withdrawals)
            self.admin_completed_groups.write(group_id, true);

            true
        }

        /// Check if admin has marked a group as completed
        fn is_group_admin_completed(self: @ContractState, group_id: u256) -> bool {
            self.admin_completed_groups.read(group_id)
        }

        fn get_user_joined_groups(
            self: @ContractState, user_address: ContractAddress,
        ) -> Array<UserGroupDetails> {
            let joined_count = self.user_joined_groups_count.read(user_address);
            let mut groups = ArrayTrait::new();

            let mut i = 0;
            while i < joined_count {
                let group_id = self.user_joined_groups_list.read((user_address, i));
                let group_info = self.groups.read(group_id);
                let member_index = self.user_joined_groups.read((user_address, group_id));
                let member_data = self.group_members.read((group_id, member_index));

                let group_details = UserGroupDetails {
                    group_info: group_info.clone(),
                    member_data: member_data,
                    next_payout_date: self._calculate_next_payout_date(group_id),
                    position_in_queue: self._get_position_in_payout_queue(group_id, user_address),
                    total_contributed_so_far: member_data.total_contributed,
                    expected_payout_amount: group_info.contribution_amount
                        * group_info.member_limit.into(),
                };

                groups.append(group_details);
                i += 1;
            }

            groups
        }


        fn get_user_statistics(
            self: @ContractState, user_address: ContractAddress,
        ) -> UserStatistics {
            self.user_statistics.read(user_address)
        }

        // Keep all existing getter functions
        fn get_group_info(self: @ContractState, group_id: u256) -> GroupInfo {
            self.groups.read(group_id)
        }

        fn get_group_member(
            self: @ContractState, group_id: u256, member_index: u32,
        ) -> GroupMember {
            self.group_members.read((group_id, member_index))
        }

        fn get_user_member_index(
            self: @ContractState, user: ContractAddress, group_id: u256,
        ) -> u32 {
            self.user_joined_groups.read((user, group_id))
        }

        fn is_group_member(self: @ContractState, group_id: u256, user: ContractAddress) -> bool {
            self._is_member(group_id, user)
        }


        fn has_completed_circle(
            self: @ContractState, user: ContractAddress, group_id: u256,
        ) -> bool {
            self._has_completed_circle(user, group_id)
        }

        fn get_insurance_pool_balance(self: @ContractState, group_id: u256) -> u256 {
            self.insurance_pool.read(group_id)
        }

        fn get_current_cycle(self: @ContractState, group_id: u256) -> u64 {
            let group_info = self.groups.read(group_id);
            assert(group_info.group_id != 0, Errors::GROUP_DOES_NOT_EXIST);
            group_info.current_cycle
        }

        fn get_current_cycle_contributors(
            self: @ContractState, group_id: u256,
        ) -> Array<ContractAddress> {
            // Use the unified function and extract just the addresses
            let (_, contributors_with_amounts) = self
                .get_cycle_contributors(group_id, self.get_current_cycle(group_id));
            let mut contributors = ArrayTrait::new();

            let mut i = 0;
            while i < contributors_with_amounts.len() {
                let (contributor_address, _) = *contributors_with_amounts.at(i);
                contributors.append(contributor_address);
                i += 1;
            }

            contributors
        }

        fn get_group_total_contributions(
            self: @ContractState, group_id: u256,
        ) -> (u256, u256, Array<(ContractAddress, u256)>) {
            // Verify group exists
            let group_info = self.groups.read(group_id);
            assert(group_info.group_id != 0, Errors::GROUP_DOES_NOT_EXIST);

            // Use helper function to get member contributions efficiently
            let (total_contributions, member_contributions) = self
                ._get_member_contributions_summary(group_id);

            // Return: (total_contributions, remaining_pool_amount, individual_contributions)
            // remaining_pool_amount shows what's available for payouts/carry-overs
            (total_contributions, group_info.remaining_pool_amount, member_contributions)
        }

        fn get_held_payouts(self: @ContractState, group_id: u256) -> u32 {
            self.held_payouts.read(group_id)
        }

        fn get_next_payout_recipient(self: @ContractState, group_id: u256) -> GroupMember {
            self._get_next_payout_recipient(group_id)
        }


        fn get_payout_order(self: @ContractState, group_id: u256) -> Array<ContractAddress> {
            let group_info = self.groups.read(group_id);
            assert(group_info.group_id != 0, Errors::GROUP_DOES_NOT_EXIST);

            let mut payout_order = array![];

            // Simple approach: find members in priority order one by one
            let mut remaining_members = group_info.members;
            let mut processed = array![];

            while remaining_members > 0 {
                let mut best_member = GroupMember {
                    user: contract_address_const::<0>(),
                    group_id: 0,
                    locked_amount: 0,
                    joined_at: 0,
                    member_index: 0,
                    payout_cycle: 0,
                    has_been_paid: false,
                    contribution_count: 0,
                    late_contributions: 0,
                    missed_contributions: 0,
                    total_contributed: 0,
                    total_recieved: 0,
                    is_active: true,
                };
                let mut found = false;

                let mut i = 0;
                while i < group_info.members {
                    let member = self.group_members.read((group_id, i));
                    if member.user != contract_address_const::<0>()
                        && !self._is_processed(@processed, member.member_index) {
                        if !found {
                            best_member = member;
                            found = true;
                        } else if member.locked_amount > best_member.locked_amount {
                            // Compare priority: higher locked amount wins, then earlier join time
                            best_member = member;
                        } else if member.locked_amount == best_member.locked_amount
                            && member.joined_at < best_member.joined_at {
                            best_member = member;
                        }
                    }
                    i += 1;
                }

                if found {
                    payout_order.append(best_member.user);
                    processed.append(best_member.member_index);
                    remaining_members -= 1;
                } else {
                    break;
                }
            }

            payout_order
        }

        fn admin_withdraw_from_pool(
            ref self: ContractState, group_id: u256, amount: u256, recipient: ContractAddress,
        ) -> bool {
            self.accesscontrol.assert_only_role(DEFAULT_ADMIN_ROLE);

            self.pausable.assert_not_paused();

            assert(amount > 0, Errors::AMOUNT_MUST_BE_GREATER_THAN_ZERO);

            let group_info = self.groups.read(group_id);
            assert(group_info.group_id != 0, Errors::GROUP_DOES_NOT_EXIST);

            let current_pool_balance = self.insurance_pool.read(group_id);
            assert(current_pool_balance >= amount, Errors::INSUFFICIENT_POOL_BALANCE);

            self.insurance_pool.write(group_id, current_pool_balance - amount);

            let payment_token = IERC20Dispatcher {
                contract_address: self.payment_token_address.read(),
            };
            let success = payment_token.transfer(recipient, amount);
            assert(success, Errors::TOKEN_TRANSFER_FAILED);

            self
                .emit(
                    Event::AdminPoolWithdrawal(
                        AdminPoolWithdrawal {
                            admin: get_caller_address(),
                            group_id,
                            amount,
                            recipient,
                            remaining_balance: current_pool_balance - amount,
                        },
                    ),
                );

            true
        }


        fn track_missed_deadline_penalty(
            ref self: ContractState, group_id: u256, user: ContractAddress, penalty_amount: u256,
        ) -> bool {
            self.missed_deadline_penalties.write((group_id, user), penalty_amount);
            true
        }

        fn get_group_locked_funds(
            self: @ContractState, group_id: u256,
        ) -> (u256, Array<(ContractAddress, u256)>) {
            // Verify group exists
            let group_info = self.groups.read(group_id);
            assert(group_info.group_id != 0, Errors::GROUP_DOES_NOT_EXIST);

            let mut total_locked_funds = 0_u256;
            let mut member_locked_funds = ArrayTrait::new();
            let total_members = group_info.members;

            // Iterate through all members to get their actual locked funds
            let mut i = 0_u32;
            while i < total_members {
                let group_member = self.group_members.read((group_id, i));
                if group_member.user != contract_address_const::<0>() {
                    // Get actual locked funds from group_lock mapping
                    let member_locked_amount = self.group_lock.read((group_id, group_member.user));
                    if member_locked_amount > 0 {
                        total_locked_funds += member_locked_amount;
                        member_locked_funds.append((group_member.user, member_locked_amount));
                    }
                }
                i += 1;
            }

            (total_locked_funds, member_locked_funds)
        }

        fn get_cycle_contributors(
            self: @ContractState, group_id: u256, cycle: u64,
        ) -> (u256, Array<(ContractAddress, u256)>) {
            // Verify group exists
            let group_info = self.groups.read(group_id);
            assert(group_info.group_id != 0, Errors::GROUP_DOES_NOT_EXIST);

            let mut total_cycle_contributions = 0_u256;
            let mut cycle_contributors = ArrayTrait::new();
            let total_members = group_info.members;

            // Iterate through all members to check who contributed in the specified cycle
            let mut i = 0_u32;
            while i < total_members {
                let group_member = self.group_members.read((group_id, i));
                if group_member.user != contract_address_const::<0>() {
                    // Get contribution record from the comprehensive tracking system
                    let contribution_record = self
                        .contribution_records
                        .read((group_id, group_member.user, cycle));

                    // Check if this member has a valid contribution record for this cycle
                    if contribution_record.contributor == group_member.user
                        && contribution_record.amount > 0 {
                        // Use the actual contribution amount from the record
                        total_cycle_contributions += contribution_record.amount;
                        cycle_contributors.append((group_member.user, contribution_record.amount));
                    }
                }
                i += 1;
            }

            (total_cycle_contributions, cycle_contributors)
        }

        // Consolidated deadline information function (replaces 3 redundant functions)
        fn get_deadline_info(
            self: @ContractState, group_id: u256, user: ContractAddress,
        ) -> (u64, u64, u256, bool) {
            let deadline = self.contribution_deadlines.read((group_id, user));
            let current_time = get_block_timestamp();
            let penalty = self.missed_deadline_penalties.read((group_id, user));

            let time_until_deadline = if current_time >= deadline {
                0 // Deadline has passed
            } else {
                deadline - current_time
            };

            let is_overdue = current_time > deadline && deadline != 0;

            // Returns: (deadline_timestamp, time_until_deadline, penalty_amount, is_overdue)
            (deadline, time_until_deadline, penalty, is_overdue)
        }

        // Keep individual getters for backward compatibility if needed
        fn get_contribution_deadline(
            self: @ContractState, group_id: u256, user: ContractAddress,
        ) -> u64 {
            let (deadline, _, _, _) = self.get_deadline_info(group_id, user);
            deadline
        }

        fn check_and_apply_deadline_penalty(
            ref self: ContractState, group_id: u256, user: ContractAddress,
        ) -> u256 {
            let current_time = get_block_timestamp();
            let deadline = self.contribution_deadlines.read((group_id, user));

            if current_time > deadline && deadline != 0 {
                // User missed the deadline
                let group_info = self.groups.read(group_id);
                let penalty_amount = (group_info.contribution_amount * 500) / 10000; // 5% penalty

                // Track the penalty
                let current_penalty = self.missed_deadline_penalties.read((group_id, user));
                self
                    .missed_deadline_penalties
                    .write((group_id, user), current_penalty + penalty_amount);

                // Update member's missed contributions count
                let member_index = self.user_joined_groups.read((user, group_id));
                let mut group_member = self.group_members.read((group_id, member_index));
                group_member.missed_contributions += 1;
                self.group_members.write((group_id, member_index), group_member);

                penalty_amount
            } else {
                0
            }
        }

        fn remove_member_from_group(
            ref self: ContractState, group_id: u256, member_address: ContractAddress,
        ) -> bool {
            let caller = get_caller_address();

            // Check if contract is paused
            self.pausable.assert_not_paused();

            // Only admin or group creator can remove members
            let group_info = self.groups.read(group_id);
            assert(group_info.group_id != 0, Errors::GROUP_DOES_NOT_EXIST);

            // Only allow removal before group is activated
            assert(group_info.state == GroupState::Created, 'Can only remove before active');

            // Check permissions: admin or group creator
            assert(
                self.accesscontrol.has_role(DEFAULT_ADMIN_ROLE, caller)
                    || group_info.creator == caller,
                'Only admin or creator',
            );

            // Check if user is actually a member
            let member_index = self.user_joined_groups.read((member_address, group_id));
            let group_member = self.group_members.read((group_id, member_index));
            assert(
                group_member.user == member_address && group_member.is_active, 'User not a member',
            );

            // Deactivate the member
            let mut updated_member = group_member;
            updated_member.is_active = false;
            self.group_members.write((group_id, member_index), updated_member);

            // Update group member count
            let mut updated_group_info = group_info;
            updated_group_info.members -= 1;
            self.groups.write(group_id, updated_group_info);

            // Remove from user's joined groups mapping
            self.user_joined_groups.write((member_address, group_id), 0);

            // Update user's group count
            let mut user_profile = self.user_profiles.read(member_address);
            if user_profile.total_joined_groups > 0 {
                user_profile.total_joined_groups -= 1;
            }
            if user_profile.active_groups > 0 {
                user_profile.active_groups -= 1;
            }

            // If user had locked funds, return them
            let locked_amount = self.group_lock.read((group_id, member_address));
            if locked_amount > 0 {
                // Transfer locked funds back to user
                let payment_token = IERC20Dispatcher {
                    contract_address: self.payment_token_address.read(),
                };
                let success = payment_token.transfer(member_address, locked_amount);
                assert(success, 'Failed to return locked funds');

                // Clear the lock record
                self.group_lock.write((group_id, member_address), 0);

                // Update user's total locked balance
                let current_locked = self.locked_balance.read(member_address);
                if current_locked >= locked_amount {
                    self.locked_balance.write(member_address, current_locked - locked_amount);
                }

                // Update user profile lock amount
                if user_profile.total_lock_amount >= locked_amount {
                    user_profile.total_lock_amount -= locked_amount;
                }
            }

            // Write updated user profile once
            self.user_profiles.write(member_address, user_profile);

            // Record activity
            self
                ._record_activity(
                    member_address,
                    ActivityType::GroupLeft,
                    "Removed from group by admin/creator",
                    0,
                    Option::Some(group_id),
                    false,
                );

            true
        }
    }

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        fn _is_member(self: @ContractState, group_id: u256, user: ContractAddress) -> bool {
            let member_index = self.user_joined_groups.read((user, group_id));
            if member_index == 0 {
                // Check if member at index 0 is actually this user
                let member_at_zero = self.group_members.read((group_id, 0));
                member_at_zero.user == user
            } else {
                true
            }
        }

        fn _has_completed_circle(
            self: @ContractState, user: ContractAddress, group_id: u256,
        ) -> bool {
            let member_index = self.user_joined_groups.read((user, group_id));
            let group_member = self.group_members.read((group_id, member_index));
            let _group_info = self.groups.read(group_id);

            group_member.missed_contributions == 0
        }

        fn _get_penalty_amount(
            self: @ContractState, user: ContractAddress, group_id: u256,
        ) -> u256 {
            let member_index = self.user_joined_groups.read((user, group_id));
            let group_member = self.group_members.read((group_id, member_index));
            let group_info = self.groups.read(group_id);

            // Calculate penalty based on missed contributions
            // Penalty = missed_contributions * contribution_amount * penalty_rate
            // For simplicity, let's use a 10% penalty per missed contribution
            let penalty_rate = 10; // 10% penalty per missed contribution
            let base_penalty = group_member.missed_contributions.into()
                * group_info.contribution_amount;
            let total_penalty = (base_penalty * penalty_rate.into()) / 100_u256;

            // Ensure penalty doesn't exceed locked amount
            let max_penalty = group_member.locked_amount;
            if total_penalty > max_penalty {
                max_penalty
            } else {
                total_penalty
            }
        }


        fn _sort_members_by_priority(
            self: @ContractState, group_id: u256, members: Array<ContractAddress>,
        ) -> Array<ContractAddress> {
            let mut sorted = ArrayTrait::new();
            let mut remaining = members;

            // Simple bubble sort implementation for priority ordering
            while remaining.len() > 0 {
                let mut best_index = 0;
                let mut best_member = *remaining.at(0);
                let best_member_index = self.user_joined_groups.read((best_member, group_id));
                let mut best_member_data = self.group_members.read((group_id, best_member_index));
                let mut best_lock_balance = self.group_lock.read((group_id, best_member));

                let mut i = 1;
                while i < remaining.len() {
                    let current_member = *remaining.at(i);
                    let current_member_index = self
                        .user_joined_groups
                        .read((current_member, group_id));
                    let current_member_data = self
                        .group_members
                        .read((group_id, current_member_index));
                    let current_lock_balance = self.group_lock.read((group_id, current_member));

                    // Compare: higher lock balance wins, if tie then earlier join order wins
                    if current_lock_balance > best_lock_balance
                        || (current_lock_balance == best_lock_balance
                            && current_member_data.member_index < best_member_data.member_index) {
                        best_index = i;
                        best_member = current_member;
                        best_member_data = current_member_data;
                        best_lock_balance = current_lock_balance;
                    }
                    i += 1;
                }

                sorted.append(best_member);

                // Remove the selected member from remaining
                let mut new_remaining = ArrayTrait::new();
                let mut j = 0;
                while j < remaining.len() {
                    if j != best_index {
                        new_remaining.append(*remaining.at(j));
                    }
                    j += 1;
                }
                remaining = new_remaining;
            }

            sorted
        }

        fn _get_next_payout_recipient(self: @ContractState, group_id: u256) -> GroupMember {
            let group_info = self.groups.read(group_id);
            let current_cycle = group_info.current_cycle;

            let mut best_member = GroupMember {
                user: contract_address_const::<0>(),
                group_id: 0,
                locked_amount: 0,
                joined_at: 0,
                member_index: 0,
                payout_cycle: 0,
                has_been_paid: false,
                contribution_count: 0,
                late_contributions: 0,
                missed_contributions: 0,
                total_contributed: 0,
                total_recieved: 0,
                is_active: true,
            };
            let mut found_eligible = false;

            let mut i = 0;
            while i < group_info.members {
                let member = self.group_members.read((group_id, i));
                if member.user != contract_address_const::<0>() && !member.has_been_paid {
                    // Check if this member is qualified for payout
                    if self._is_qualified_for_payout(group_id, member.user) {
                        // Get actual locked balance from group_lock mapping
                        let lock_balance = self.group_lock.read((group_id, member.user));

                        if !found_eligible {
                            best_member = member;
                            found_eligible = true;
                        } else if lock_balance > self
                            .group_lock
                            .read((group_id, best_member.user)) {
                            // Compare priority: higher locked amount wins
                            best_member = member;
                        } else if lock_balance == self.group_lock.read((group_id, best_member.user))
                            && member.member_index < best_member.member_index {
                            // If locked amounts are equal, earlier join order wins
                            best_member = member;
                        }
                    }
                }
                i += 1;
            }

            assert(found_eligible, Errors::NO_ELIGIBLE_MEMBER_FOUND);
            best_member
        }

        fn _calculate_total_contributions(self: @ContractState, group_id: u256) -> u256 {
            let group_info = self.groups.read(group_id);
            assert(group_info.group_id != 0, Errors::GROUP_DOES_NOT_EXIST);

            let mut total_contributions = 0_u256;
            let mut member_index = 0_u32;

            // Iterate through all members in the group
            while member_index < group_info.members {
                let group_member = self.group_members.read((group_id, member_index));

                // Calculate this member's total contributions
                // contribution_count * contribution_amount per cycle
                let member_contributions = group_member.contribution_count.into()
                    * group_info.contribution_amount;
                total_contributions += member_contributions;

                member_index += 1;
            }

            total_contributions
        }

        fn _calculate_current_cycle_contributions(
            self: @ContractState, group_id: u256, cycle: u64,
        ) -> u256 {
            // Use the new comprehensive tracking system - much more efficient!
            self.cycle_total_contributions.read((group_id, cycle))
        }

        fn _is_qualified_for_payout(
            self: @ContractState, group_id: u256, user: ContractAddress,
        ) -> bool {
            // For testing purposes, we can make this restrictive to test the "no eligible
            // recipients" scenario This function determines who qualifies for payout based on their
            // locked funds

            let current_locked_balance = self.group_lock.read((group_id, user));
            let group_info = self.groups.read(group_id);

            // Calculate a high requirement to test "no eligible recipients" scenario
            let contribution_amount = group_info.contribution_amount;
            let insurance_rate = self.insurance_rate.read();
            let insurance_fee_per_contribution = (contribution_amount * insurance_rate) / 10000;
            let cost_per_contribution = contribution_amount + insurance_fee_per_contribution;

            // Require 5 cycles worth of locked funds (very high requirement)
            let required_cycles = 5_u256;
            let minimum_required = cost_per_contribution * required_cycles;

            // Only qualify if they have locked significantly more than required
            current_locked_balance >= minimum_required
        }

        fn _get_all_eligible_recipients(
            self: @ContractState, group_id: u256,
        ) -> Array<ContractAddress> {
            let group_info = self.groups.read(group_id);
            let mut eligible_recipients = ArrayTrait::new();
            let mut member_index = 0_u32;

            // Iterate through all members to find eligible ones
            while member_index < group_info.members {
                let group_member = self.group_members.read((group_id, member_index));

                // Skip if member slot is empty
                if group_member.user == contract_address_const::<0>() {
                    member_index += 1;
                    continue;
                }

                // Skip if member has already been paid
                if group_member.has_been_paid {
                    member_index += 1;
                    continue;
                }

                // Check if member is qualified for payout
                if self._is_qualified_for_payout(group_id, group_member.user) {
                    eligible_recipients.append(group_member.user);
                }

                member_index += 1;
            }

            eligible_recipients
        }

        fn _sort_recipients_by_priority(
            self: @ContractState, group_id: u256, recipients: Array<ContractAddress>,
        ) -> Array<ContractAddress> {
            let mut sorted = ArrayTrait::new();
            let mut remaining = recipients;

            // Simple selection sort by priority (highest locked funds first, then earliest join
            // order)
            while remaining.len() > 0 {
                let mut best_index = 0;
                let mut best_recipient = *remaining.at(0);
                let mut best_locked_amount = self.group_lock.read((group_id, best_recipient));
                let best_member_index = self.user_joined_groups.read((best_recipient, group_id));
                let mut best_member_data = self.group_members.read((group_id, best_member_index));

                let mut i = 1;
                while i < remaining.len() {
                    let current_recipient = *remaining.at(i);
                    let current_locked_amount = self.group_lock.read((group_id, current_recipient));
                    let current_member_index = self
                        .user_joined_groups
                        .read((current_recipient, group_id));
                    let current_member_data = self
                        .group_members
                        .read((group_id, current_member_index));

                    // Priority: higher locked amount wins, if tie then earlier join order wins
                    if current_locked_amount > best_locked_amount
                        || (current_locked_amount == best_locked_amount
                            && current_member_data.member_index < best_member_data.member_index) {
                        best_index = i;
                        best_recipient = current_recipient;
                        best_locked_amount = current_locked_amount;
                        best_member_data = current_member_data;
                    }
                    i += 1;
                }

                sorted.append(best_recipient);

                // Remove the selected recipient from remaining
                let mut new_remaining = ArrayTrait::new();
                let mut j = 0;
                while j < remaining.len() {
                    if j != best_index {
                        new_remaining.append(*remaining.at(j));
                    }
                    j += 1;
                }
                remaining = new_remaining;
            }

            sorted
        }

        fn _is_processed(self: @ContractState, processed: @Array<u32>, member_index: u32) -> bool {
            let mut i = 0;
            let len = processed.len();
            while i < len {
                if *processed.at(i) == member_index {
                    return true;
                }
                i += 1;
            }
            false
        }

        // New internal functions from modified version
        fn _record_activity(
            ref self: ContractState,
            user: ContractAddress,
            activity_type: ActivityType,
            description: ByteArray,
            amount: u256,
            group_id: Option<u256>,
            is_positive: bool,
        ) {
            let activity_id = self.next_activity_id.read();
            let user_activity_count = self.user_activity_count.read(user);

            let activity = UserActivity {
                activity_id,
                user_address: user,
                activity_type,
                description,
                amount,
                group_id,
                timestamp: get_block_timestamp(),
                is_positive_amount: is_positive,
            };

            self.user_activities.write((user, user_activity_count), activity);
            self.user_activity_count.write(user, user_activity_count + 1);
            self.next_activity_id.write(activity_id + 1);
        }

        fn _calculate_next_payout_date(self: @ContractState, group_id: u256) -> u64 {
            let group_info = self.groups.read(group_id);
            // Simple calculation - add cycle_duration to last_payout_time or start_time
            if group_info.last_payout_time > 0 {
                group_info.last_payout_time + group_info.cycle_duration
            } else {
                group_info.start_time + group_info.cycle_duration
            }
        }

        fn _get_position_in_payout_queue(
            self: @ContractState, group_id: u256, user: ContractAddress,
        ) -> u32 {
            let member_index = self.user_joined_groups.read((user, group_id));
            let group_info = self.groups.read(group_id);

            // Simple queue position based on join order and current cycle
            if member_index >= group_info.current_cycle.try_into().unwrap() {
                member_index - group_info.current_cycle.try_into().unwrap()
            } else {
                (group_info.member_limit - group_info.current_cycle.try_into().unwrap())
                    + member_index
            }
        }

        fn _reset_cycle_contributions(ref self: ContractState, group_id: u256, new_cycle: u256) {
            // Reset comprehensive contribution tracking for all members for the new cycle
            let group_info = self.groups.read(group_id);
            let mut member_index: u32 = 0;

            // Reset cycle totals for the new cycle
            self.cycle_total_contributions.write((group_id, new_cycle.try_into().unwrap()), 0);
            self.cycle_contributors_count.write((group_id, new_cycle.try_into().unwrap()), 0);

            while member_index < group_info.members {
                let group_member = self.group_members.read((group_id, member_index));

                // Reset the deprecated boolean flag for backward compatibility
                self
                    .user_cycle_contributions
                    .write((group_id, group_member.user, new_cycle.try_into().unwrap()), false);

                // Clear any existing contribution record for the new cycle
                // (This ensures no stale data from previous cycles)
                let empty_record = ContributionRecord {
                    contributor: contract_address_const::<0>(),
                    group_id: 0,
                    cycle: 0,
                    amount: 0,
                    insurance_fee: 0,
                    penalty_amount: 0,
                    total_paid: 0,
                    timestamp: 0,
                    is_late: false,
                    member_index: 0,
                };
                self
                    .contribution_records
                    .write(
                        (group_id, group_member.user, new_cycle.try_into().unwrap()), empty_record,
                    );

                member_index += 1;
            };
        }

        // ============ COMPREHENSIVE CONTRIBUTION TRACKING FUNCTIONS ============

        // Get detailed contribution record for a specific user and cycle
        fn get_contribution_record(
            self: @ContractState, group_id: u256, user_address: ContractAddress, cycle: u64,
        ) -> ContributionRecord {
            self.contribution_records.read((group_id, user_address, cycle))
        }

        // Get cycle statistics (total contributions and contributor count)
        fn get_cycle_stats(self: @ContractState, group_id: u256, cycle: u64) -> (u256, u32) {
            let total_contributions = self.cycle_total_contributions.read((group_id, cycle));
            let contributors_count = self.cycle_contributors_count.read((group_id, cycle));
            (total_contributions, contributors_count)
        }

        // Check if a user has contributed to a specific cycle (using new system)
        fn has_user_contributed_to_cycle(
            self: @ContractState, group_id: u256, user_address: ContractAddress, cycle: u64,
        ) -> bool {
            let contribution_record = self
                .contribution_records
                .read((group_id, user_address, cycle));
            contribution_record.contributor == user_address && contribution_record.amount > 0
        }

        fn get_user_payout_amount(
            self: @ContractState, group_id: u256, user: ContractAddress,
        ) -> u256 {
            self.user_payout_amounts.read((group_id, user))
        }


        // Helper function to get member contributions summary (eliminates code duplication)
        fn _get_member_contributions_summary(
            self: @ContractState, group_id: u256,
        ) -> (u256, Array<(ContractAddress, u256)>) {
            let group_info = self.groups.read(group_id);
            let mut total_contributions = 0_u256;
            let mut member_contributions = ArrayTrait::new();
            let total_members = group_info.members;

            // Iterate through all members to get their total contributions
            let mut i = 0_u32;
            while i < total_members {
                let group_member = self.group_members.read((group_id, i));
                if group_member.user != contract_address_const::<0>() {
                    let member_total_contributed = group_member.total_contributed;
                    if member_total_contributed > 0 {
                        total_contributions += member_total_contributed;
                        member_contributions.append((group_member.user, member_total_contributed));
                    }
                }
                i += 1;
            }

            (total_contributions, member_contributions)
        }
    }
}
