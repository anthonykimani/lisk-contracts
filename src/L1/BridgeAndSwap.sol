// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.23;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface stETHInterface is IERC20 {
    function getCurrentStakeLimit() external returns (uint256);
}

interface WstETHInterface is IERC20 { }

interface OPBridgeInterface {
    function depositERC20To(address, address, address, uint256, uint32, bytes calldata) external;
}

contract BridgeAndSwap is ReentrancyGuard {
    address private immutable L1stETH_ADDRESS = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address private immutable L1BRIDGE_ADDRESS = 0x76943C0D61395d8F2edF9060e1533529cAe05dE6;
    address private immutable L1WstETH_ADDRESS = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address private immutable L2WstETH_ADDRESS = 0x1F32b1c2345538c0c6f582fCB022739c4A194Ebb;
    stETHInterface public stETH = stETHInterface(L1stETH_ADDRESS);
    WstETHInterface public WstETH = WstETHInterface(L1WstETH_ADDRESS);
    OPBridgeInterface public LidoBridge = OPBridgeInterface(L1BRIDGE_ADDRESS);

    enum StakingPool { Lido }

    function swap_and_bridge() public payable nonReentrant {
        uint256 current_stake_limit = stETH.getCurrentStakeLimit();
        require(msg.value <= current_stake_limit, "Current stake limit too small.");

        // Send ETH and mint wstETH for SwapAndBridge contract.
        (bool sent,) = address(WstETH).call{ value: msg.value }("");

        require(sent, "Failed to send Ether.");

        uint256 balance = WstETH.balanceOf(address(this));
        WstETH.approve(L1BRIDGE_ADDRESS, balance);

        //transfer tokens to user. This is for testing purposes.
        // WstETH.transfer(msg.sender, balance);

        // Bridge tokens to L2
        LidoBridge.depositERC20To(L1WstETH_ADDRESS, L2WstETH_ADDRESS, msg.sender, balance, 200000, "0x");
    }

    function balanceOf(address account) public view returns (uint256) {
        return WstETH.balanceOf(account);
    }

    function allowance(address owner, address spender) public view returns (uint256) {
        return WstETH.allowance(owner, spender);
    }
}
