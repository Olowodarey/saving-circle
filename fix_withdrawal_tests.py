#!/usr/bin/env python3
"""
Script to fix all failing withdrawal tests using the successful lock funds pattern
"""

def fix_withdrawal_tests():
    file_path = "/home/olowo/Desktop/savecircle/savecircle/tests/test_witdrawfromgroup.cairo"
    
    with open(file_path, 'r') as f:
        content = f.read()
    
    # Split content into lines for easier manipulation
    lines = content.split('\n')
    
    # Pattern to fix: Replace problematic token setup patterns with the working pattern
    # The working pattern is:
    # 1. start_cheat_caller_address(token_address, owner);
    # 2. token_dispatcher.transfer(user, token_amount);
    # 3. stop_cheat_caller_address(token_address);
    # 4. start_cheat_caller_address(token_address, user);
    # 5. token_dispatcher.approve(contract_address, token_amount);
    # 6. stop_cheat_caller_address(token_address);
    # 7. start_cheat_caller_address(contract_address, user);
    # 8. dispatcher.lock_liquidity(token_address, contribution_amount, group_id);
    # 9. stop_cheat_caller_address(contract_address);
    
    # Find and replace the old setup_user_and_group function with the working pattern
    for i, line in enumerate(lines):
        # Fix the setup_user_and_group function
        if "// Mint tokens to user and approve contract" in line:
            # Replace the old token setup with the working pattern
            j = i
            # Find the end of the token setup section
            while j < len(lines) and "group_id" not in lines[j]:
                j += 1
            
            # Replace the section with the working pattern
            new_section = [
                "    // Transfer tokens to user for testing",
                "    start_cheat_caller_address(token_address, owner);",
                "    token_dispatcher.transfer(user, token_amount);",
                "    stop_cheat_caller_address(token_address);",
                "",
                "    // User approves contract to spend tokens",
                "    start_cheat_caller_address(token_address, user);",
                "    token_dispatcher.approve(contract_address, token_amount);",
                "    stop_cheat_caller_address(token_address);",
                "",
                "    // Lock liquidity for the user",
                "    start_cheat_caller_address(contract_address, user);",
                "    dispatcher.lock_liquidity(token_address, contribution_amount, group_id);",
                "    stop_cheat_caller_address(contract_address);",
                ""
            ]
            
            # Replace the old section
            lines[i:j] = new_section
            break
    
    # Fix individual test functions that have their own token setup
    i = 0
    while i < len(lines):
        line = lines[i]
        
        # Look for patterns where we need to fix token setup for additional users
        if ("start_cheat_caller_address(token_address, owner);" in line and 
            i + 1 < len(lines) and "token_dispatcher.transfer(" in lines[i + 1]):
            
            # Find the user being transferred to
            transfer_line = lines[i + 1]
            if "user2" in transfer_line:
                user = "user2"
            elif "user3" in transfer_line:
                user = "user3"
            else:
                i += 1
                continue
            
            # Find the end of this user's setup
            j = i + 1
            while j < len(lines) and not ("dispatcher.lock_liquidity" in lines[j] or 
                                         "// Both users contribute" in lines[j] or
                                         "// Check individual locked balances" in lines[j]):
                j += 1
            
            # Replace with the working pattern
            new_section = [
                f"    // Setup tokens for {user}",
                "    start_cheat_caller_address(token_address, owner);",
                f"    token_dispatcher.transfer({user}, token_amount);",
                "    stop_cheat_caller_address(token_address);",
                "",
                f"    start_cheat_caller_address(token_address, {user});",
                "    token_dispatcher.approve(contract_address, token_amount);",
                "    stop_cheat_caller_address(token_address);",
                "",
                f"    start_cheat_caller_address(contract_address, {user});",
                "    dispatcher.lock_liquidity(token_address, contribution_amount, group_id);",
                "    stop_cheat_caller_address(contract_address);",
                ""
            ]
            
            # Replace the old section
            lines[i:j] = new_section
            i += len(new_section)
        else:
            i += 1
    
    # Write back the fixed content
    with open(file_path, 'w') as f:
        f.write('\n'.join(lines))
    
    print("Applied successful lock funds pattern to all failing withdrawal tests")
    print("Fixed token transfer, approval, and caller address management")

if __name__ == "__main__":
    fix_withdrawal_tests()
