// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.23;

import { Script, console2 } from "forge-std/Script.sol";
import { Vm } from "forge-std/Vm.sol";
import { SwapAndBridge } from "src/L1/SwapAndBridge.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IL2CrossDomainMessenger - L2 Cross Domain Messenger interface
/// @notice This contract is used to relay messages from L1 to L2 network.
interface IL2CrossDomainMessenger {
    /// @notice Sends a message to the target contract on L2 network.
    /// @param _nonce Unique nonce for the message.
    /// @param _sender Address of the sender on L1 network.
    /// @param _target Address of the target contract on L2 network.
    /// @param _value Amount of Ether to be sent to the target contract on L2 network.
    /// @param _minGasLimit Minimum gas limit for the message on L2 network.
    /// @param _message Message to be sent to the target contract on L2 network.
    function relayMessage(
        uint256 _nonce,
        address _sender,
        address _target,
        uint256 _value,
        uint256 _minGasLimit,
        bytes calldata _message
    )
        external;
}

/// @title IWrappedETH - Wrapped Ether Token interface
/// @notice This contract is used to wrap the a LST.
interface IWrappedETH is IERC20 {
    receive() external payable;
}

// event SentMessage(address indexed target, address sender, bytes message, uint256 messageNonce, uint256 gasLimit);
event SentMessage(address indexed target, bytes data);

/// @title TestDivaBridgingL1Script
/// @notice This contract is used to test bridging Diva tokens from L1 to L2 network.
///         This contract runs the L1 part of it, by sending ETH to the SwapAndBridge contract and checking that the
///         correct events are emitted.
contract TestDivaBridgingL1Script is Script {
    // SwapAndBridge contract
    SwapAndBridge swapAndBridgeDiva;

    // The L1 Diva LST token
    IWrappedETH l1WdivETH;

    // Address used for E2E tests
    address constant testAccount = address(0xc0ffee);

    // The test value to be bridged
    uint256 constant TEST_AMOUNT = 500 ether;

    // L1 address of the Diva bridge (this is the Lisk standard bridge)
    address constant L1_DIVA_BRIDGE_ADDR = 0x1Fb30e446eA791cd1f011675E5F3f5311b70faF5;

    // L1 address of the Diva token
    address constant L1_DIVA_TOKEN_ADDR = 0x91701E62B2DA59224e92C42a970d7901d02C2F24;

    // L2 address of the Diva bridge (this is the standard bridge for Op chains)
    address constant L2_DIVA_BRIDGE_ADDR = 0x4200000000000000000000000000000000000010;

    // L2 address of the Diva token (from previous deployment)
    address constant L2_DIVA_TOKEN_ADDR = 0x0164b1BF8683794d53b75fA6Ae7944C5e59E91d4;

    function getSlice(uint256 begin, uint256 end, bytes memory text) private pure returns (bytes memory) {
        bytes memory a = new bytes(end - begin + 1);
        for (uint256 i = 0; i <= end - begin; i++) {
            a[i] = bytes(text)[i + begin - 1];
        }
        return a;
    }

    function setUp() public {
        swapAndBridgeDiva = new SwapAndBridge(L1_DIVA_BRIDGE_ADDR, L1_DIVA_TOKEN_ADDR, L2_DIVA_TOKEN_ADDR);
        l1WdivETH = IWrappedETH(payable(L1_DIVA_TOKEN_ADDR));
        vm.deal(testAccount, 500000 ether);
    }

    function run() public {
        console2.log("Token holder address: %s", testAccount);
        console2.log("Transferring ETH tokens from L1 to wdivETH on L2 network...");

        vm.recordLogs();

        // Test bridging for Diva
        vm.startPrank(testAccount);
        (bool sent, bytes memory sendData) = address(swapAndBridgeDiva).call{ value: TEST_AMOUNT }("");
        if (!sent) {
            assembly {
                let revertStringLength := mload(sendData)
                let revertStringPtr := add(sendData, 0x20)
                revert(revertStringPtr, revertStringLength)
            }
        }
        require(sent == true, "Failed to send Ether.");
        vm.stopPrank();

        Vm.Log[] memory entries = vm.getRecordedLogs();
        require(entries.length == 9, "Invalid number of logs");

        // entries[0] is the mint event, transferring from 0 to l1WdivETH contract
        // Transfer(address indexed from, address indexed to, uint256 value)
        require(entries[0].topics.length == 3, "Transfer: Invalid number of topics");
        require(
            entries[0].topics[0] == keccak256("Transfer(address,address,uint256)"), "Transfer: Invalid default topic"
        );
        require(entries[0].topics[1] == bytes32(0), "Transfer: Invalid from address topic");
        require(
            entries[0].topics[2] == bytes32(uint256(uint160(address(l1WdivETH)))), "Transfer: Invalid to address topic"
        );
        uint256 mintedAmount = uint256(bytes32(entries[0].data));
        require(mintedAmount == TEST_AMOUNT, "Transfer: Invalid amount");
        // entries[2] is the approve event
        // Approval(address indexed owner, address indexed spender, uint256 value)
        require(entries[2].topics.length == 3, "Approval: Invalid number of topics");
        require(
            entries[2].topics[0] == keccak256("Approval(address,address,uint256)"), "Approval: Invalid default topic"
        );
        require(
            entries[2].topics[1] == bytes32(uint256(uint160(address(swapAndBridgeDiva)))),
            "Approval: Invalid owner address topic"
        );
        require(
            entries[2].topics[2] == bytes32(uint256(uint160(L1_DIVA_BRIDGE_ADDR))),
            "Approval: Invalid spender address topic"
        );

        // entries[3] is the transfer event from swapAndBridge to L1_DIVA_BRIDGE_ADDR
        // Transfer(address indexed from, address indexed to, uint256 value)
        require(entries[3].topics.length == 3, "Transfer: Invalid number of topics");
        require(
            entries[3].topics[0] == keccak256("Transfer(address,address,uint256)"), "Transfer: Invalid default topic"
        );
        require(
            entries[3].topics[1] == bytes32(uint256(uint160(address(swapAndBridgeDiva)))),
            "Transfer: Invalid from address topic"
        );
        require(
            entries[3].topics[2] == bytes32(uint256(uint160(L1_DIVA_BRIDGE_ADDR))), "Transfer: Invalid to address topic"
        );

        // entries[7] is the SentMessage event
        // SentMessage(address indexed target, address sender, bytes message, uint256 messageNonce, uint256 gasLimit)
        require(entries[8].topics.length == 2, "SentMessage: Invalid number of topics");
        require(
            entries[7].topics[0] == keccak256("SentMessage(address,address,bytes,uint256,uint256)"),
            "SentMessage: Invalid default topic"
        );

        require(
            entries[7].topics[1] == bytes32(uint256(uint160(L2_DIVA_BRIDGE_ADDR))),
            "SentMessage: Invalid target address topic"
        );

        (address sender, bytes memory message, uint256 messageNonce, uint256 gasLimit) =
            abi.decode(entries[7].data, (address, bytes, uint256, uint256));
        require(sender == L1_DIVA_BRIDGE_ADDR, "SentMessage: Invalid sender address");
        require(
            gasLimit == swapAndBridgeDiva.MIN_DEPOSIT_GAS(),
            "SentMessage: Invalid gas limit, not matching contract MIN_DEPOSIT_GAS"
        );

        // The message is encoded in a weird way: bytes 4 is packed, the addresses are not
        // Hence, we slice the message to remove the bytes4 selector.
        bytes memory selectorBytes = getSlice(1, 5, message);
        require(
            bytes4(selectorBytes)
                == bytes4(keccak256("finalizeBridgeERC20(address,address,address,address,uint256,bytes)")),
            "SentMessage: Invalid selector"
        );

        bytes memory slicedMessage = getSlice(5, message.length, message);
        (address localToken, address remoteToken, address from, address to, uint256 amount, bytes memory extraData) =
            abi.decode(slicedMessage, (address, address, address, address, uint256, bytes));

        require(remoteToken == L1_DIVA_TOKEN_ADDR, "SentMessage: Invalid L1 token address");
        require(localToken == L2_DIVA_TOKEN_ADDR, "SentMessage: Invalid L2 token address");
        require(from == address(swapAndBridgeDiva), "SentMessage: Invalid sender address");
        require(to == testAccount, "SentMessage: Invalid recipient address");
        require(amount == TEST_AMOUNT, "SentMessage: Invalid amount");
        require(extraData.length == 2, "SentMessage: Invalid extra data");

        vm.serializeAddress("", "sender", sender);
        vm.serializeAddress("", "target", L2_DIVA_BRIDGE_ADDR);
        vm.serializeBytes("", "message", message);
        vm.serializeUint("", "messageNonce", messageNonce);

        bytes memory data = abi.encode(sender, L2_DIVA_BRIDGE_ADDR, message, messageNonce, gasLimit);

        string memory dataPath = string.concat(vm.projectRoot(), "/script/swap_and_bridge/example/message.data");
        vm.writeFileBinary(dataPath, data);
        console2.log("Transfer completed. Data saved to", dataPath);
    }
}

/// @title TestDivaBridgingL2Script
/// @notice This contract is used to test bridging Diva tokens from L1 to L2 network.
///         This contract runs the L2 part of it, by relaying the message that was emitted on the L1.
contract TestDivaBridgingL2Script is Script {
    // The L2 crossi domain messenger contract
    IL2CrossDomainMessenger l2Messenger;

    // The L2 Diva LST token
    IWrappedETH l2WdivETH;

    // Address used for E2E tests
    address testAccount;

    // The test value to be bridged
    uint256 constant TEST_AMOUNT = 500 ether;

    // L2 Cross Domain Messenger address
    address constant L2_CROSS_DOMAIN_MESSENGER_ADDR = 0x4200000000000000000000000000000000000007;

    // L2 sequencer address (this is the Lisk Sepolia Sequencer address)
    address constant SEQUENCER_ADDR = 0x968924E6234f7733eCA4E9a76804fD1afA1a4B3D;

    // L2 address of the Diva token (from previous deployment)
    address constant L2_DIVA_TOKEN_ADDR = 0x0164b1BF8683794d53b75fA6Ae7944C5e59E91d4;

    function setUp() public {
        l2Messenger = IL2CrossDomainMessenger(L2_CROSS_DOMAIN_MESSENGER_ADDR);
        l2WdivETH = IWrappedETH(payable(L2_DIVA_TOKEN_ADDR));
        testAccount = address(0xc0ffee);
    }

    function run() public {
        string memory dataPath = string.concat(vm.projectRoot(), "/script/swap_and_bridge/example/message.data");
        bytes memory data = vm.readFileBinary(dataPath);
        (address payable sender, address payable target, bytes memory message, uint256 messageNonce, uint256 gasLimit) =
            abi.decode(data, (address, address, bytes, uint256, uint256));
        vm.removeFile(dataPath);

        uint256 balanceBefore = l2WdivETH.balanceOf(testAccount);

        vm.startBroadcast(SEQUENCER_ADDR);
        console2.log("Relaying message to L2 network...");
        l2Messenger.relayMessage(messageNonce, sender, target, 0, gasLimit, message);
        vm.stopPrank();

        uint256 balanceAfter = l2WdivETH.balanceOf(testAccount);
        console2.log("balanceBefore: %d", balanceBefore);
        console2.log("balanceAfter: %d", balanceAfter);
        require(balanceAfter - balanceBefore == TEST_AMOUNT, "Invalid new balance.");
    }
}
