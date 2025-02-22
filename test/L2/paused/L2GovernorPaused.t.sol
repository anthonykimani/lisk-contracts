// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.23;

import { IVotes } from "@openzeppelin-upgradeable/contracts/governance/extensions/GovernorVotesUpgradeable.sol";
import { OwnableUpgradeable } from "@openzeppelin-upgradeable/contracts/access/OwnableUpgradeable.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { TimelockControllerUpgradeable } from
    "@openzeppelin-upgradeable/contracts/governance/extensions/GovernorTimelockControlUpgradeable.sol";
import { ERC1155Holder } from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import { ERC721Holder } from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import { Test, console } from "forge-std/Test.sol";
import { L2Governor } from "src/L2/L2Governor.sol";
import { L2GovernorPaused } from "src/L2/paused/L2GovernorPaused.sol";
import { Utils } from "script/contracts/Utils.sol";
import { MockERC721 } from "test/mock/MockERC721.sol";
import { MockERC1155 } from "test/mock/MockERC1155.sol";

contract MockL2GovernorV2 is L2Governor {
    function version() public pure virtual override returns (string memory) {
        return "2.0.0";
    }
}

contract L2GovernorPausedTest is Test, ERC1155Holder, ERC721Holder {
    Utils public utils;
    L2Governor public l2GovernorImplementation;
    L2Governor public l2Governor;

    IVotes votingPower;
    address[] executors;
    TimelockController timelock;
    address initialOwner;

    function assertInitParamsEq() internal {
        assertEq(l2Governor.name(), "Lisk Governor");
        assertEq(l2Governor.votingDelay(), 0);
        assertEq(l2Governor.votingPeriod(), 604800);
        assertEq(l2Governor.proposalThreshold(), 300_000 * 10 ** 18);
        assertEq(l2Governor.timelock(), address(timelock));
        assertEq(l2Governor.quorum(0), 24_000_000 * 10 ** 18);
        assertEq(address(l2Governor.token()), address(votingPower));
        assertEq(l2Governor.owner(), initialOwner);
    }

    function setUp() public {
        utils = new Utils();

        // set initial values
        votingPower = IVotes(address(0x1));
        executors.push(address(0)); // executor array contains address(0) such that anyone can execute proposals
        timelock = new TimelockController(0, new address[](0), executors, address(this));
        initialOwner = address(this);

        console.log("L2GovernorTest address is: %s", address(this));

        // deploy L2Governor Implementation contract
        l2GovernorImplementation = new L2Governor();

        // deploy L2Governor contract via proxy and initialize it at the same time
        l2Governor = L2Governor(
            payable(
                address(
                    new ERC1967Proxy(
                        address(l2GovernorImplementation),
                        abi.encodeWithSelector(l2Governor.initialize.selector, votingPower, timelock, initialOwner)
                    )
                )
            )
        );

        assertInitParamsEq();
        assertEq(l2Governor.version(), "1.0.0");

        // assure that address(0) is in executors role
        assertEq(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)), true);

        // Upgrade from L2Governor to L2GovernorPaused, and call initializePaused
        L2GovernorPaused l2GovernorPausedImplementation = new L2GovernorPaused();
        l2Governor.upgradeToAndCall(
            address(l2GovernorPausedImplementation),
            abi.encodeWithSelector(l2GovernorPausedImplementation.initializePaused.selector)
        );
        assertEq(l2Governor.version(), "1.0.0-paused");

        // Ensure all other params are unchanged after paused contract update
        assertInitParamsEq();
    }

    function test_Cancel_Paused() public {
        vm.expectRevert(L2GovernorPaused.GovernorIsPaused.selector);
        l2Governor.cancel(new address[](1), new uint256[](1), new bytes[](1), 0);
    }

    function test_CastVote_Paused() public {
        vm.expectRevert(L2GovernorPaused.GovernorIsPaused.selector);
        l2Governor.castVote(0, 0);
    }

    function test_CastVoteBySig_Paused() public {
        vm.expectRevert(L2GovernorPaused.GovernorIsPaused.selector);
        l2Governor.castVoteBySig(0, 0, address(0), "");
    }

    function test_CastVoteWithReason_Paused() public {
        vm.expectRevert(L2GovernorPaused.GovernorIsPaused.selector);
        l2Governor.castVoteWithReason(0, 0, "");
    }

    function test_CastVoteWithReasonAndParams_Paused() public {
        vm.expectRevert(L2GovernorPaused.GovernorIsPaused.selector);
        l2Governor.castVoteWithReasonAndParams(0, 0, "", "");
    }

    function test_CastVoteWithReasonAndParamsBySig_Paused() public {
        vm.expectRevert(L2GovernorPaused.GovernorIsPaused.selector);
        l2Governor.castVoteWithReasonAndParamsBySig(0, 0, address(0), "", "", "");
    }

    function test_Execute_Paused() public {
        vm.expectRevert(L2GovernorPaused.GovernorIsPaused.selector);
        l2Governor.execute(new address[](1), new uint256[](1), new bytes[](1), 0);
    }

    function test_OnERC1155BatchReceived_Paused() public {
        MockERC1155 mockERC1155 = new MockERC1155();
        mockERC1155.mint(address(this), 0, 10, "");
        mockERC1155.mint(address(this), 1, 20, "");

        uint256[] memory ids = new uint256[](2);
        ids[0] = 0;
        ids[1] = 1;

        uint256[] memory values = new uint256[](2);
        values[0] = 10;
        values[1] = 20;

        vm.expectRevert(L2GovernorPaused.GovernorIsPaused.selector);
        mockERC1155.safeBatchTransferFrom(address(this), address(l2Governor), ids, values, "");
    }

    function test_OnERC1155Received_Paused() public {
        MockERC1155 mockERC1155 = new MockERC1155();
        mockERC1155.mint(address(this), 0, 10, "");

        vm.expectRevert(L2GovernorPaused.GovernorIsPaused.selector);
        mockERC1155.safeTransferFrom(address(this), address(l2Governor), 0, 10, "");
    }

    function test_OnERC721Received_Paused() public {
        MockERC721 mockERC721 = new MockERC721();
        mockERC721.mint(address(this), 0);

        vm.expectRevert(L2GovernorPaused.GovernorIsPaused.selector);
        mockERC721.safeTransferFrom(address(this), address(l2Governor), 0);
    }

    function test_Propose_Paused() public {
        vm.expectRevert(L2GovernorPaused.GovernorIsPaused.selector);
        l2Governor.propose(new address[](1), new uint256[](1), new bytes[](1), "");
    }

    function test_Queue_Paused() public {
        vm.expectRevert(L2GovernorPaused.GovernorIsPaused.selector);
        l2Governor.queue(new address[](1), new uint256[](1), new bytes[](1), "");
    }

    function test_Relay_Paused() public {
        vm.expectRevert(L2GovernorPaused.GovernorIsPaused.selector);
        l2Governor.relay(address(0), 0, "");
    }

    function test_SetProposalThreshold_Paused() public {
        vm.expectRevert(L2GovernorPaused.GovernorIsPaused.selector);
        l2Governor.setProposalThreshold(0);
    }

    function test_SetVotingDelay_Paused() public {
        vm.expectRevert(L2GovernorPaused.GovernorIsPaused.selector);
        l2Governor.setVotingDelay(0);
    }

    function test_SetVotingPeriod_Paused() public {
        vm.expectRevert(L2GovernorPaused.GovernorIsPaused.selector);
        l2Governor.setVotingPeriod(0);
    }

    function test_UpdateTimelock_Paused() public {
        vm.expectRevert(L2GovernorPaused.GovernorIsPaused.selector);
        l2Governor.updateTimelock(TimelockControllerUpgradeable(payable(address(0))));
    }

    function test_UpgradeToAndCall_CanUpgradeFromPausedContractToNewContract() public {
        MockL2GovernorV2 mockL2GovernorV2Implementation = new MockL2GovernorV2();

        // upgrade contract
        l2Governor.upgradeToAndCall(address(mockL2GovernorV2Implementation), "");

        // new version updated
        assertEq(l2Governor.version(), "2.0.0");

        // Ensure all other params are unchanged after non-paused contract update
        assertInitParamsEq();
    }
}
