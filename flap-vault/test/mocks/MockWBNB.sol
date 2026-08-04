// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @title MockWBNB
/// @notice Minimal, SafeERC20-compatible Wrapped BNB used by the StockpileVault
///         tests. `deposit()` credits `msg.value` of WBNB to the caller (1:1),
///         mirroring canonical WBNB. All ERC20 methods return a bool and revert
///         on failure so OpenZeppelin's `SafeERC20`/`forceApprove` are happy.
contract MockWBNB {
    string public name = "Wrapped BNB";
    string public symbol = "WBNB";
    uint8 public constant decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Deposit(address indexed dst, uint256 wad);

    /// @notice Wrap native BNB 1:1 into WBNB credited to the caller.
    function deposit() public payable {
        balanceOf[msg.sender] += msg.value;
        totalSupply += msg.value;
        emit Deposit(msg.sender, msg.value);
    }

    /// @notice Plain value transfers wrap as well (parity with canonical WBNB).
    receive() external payable {
        deposit();
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= value, "MockWBNB: insufficient allowance");
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - value;
        }
        _transfer(from, to, value);
        return true;
    }

    function _transfer(address from, address to, uint256 value) internal {
        require(balanceOf[from] >= value, "MockWBNB: insufficient balance");
        unchecked {
            balanceOf[from] -= value;
            balanceOf[to] += value;
        }
        emit Transfer(from, to, value);
    }
}
