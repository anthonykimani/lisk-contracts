// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.23;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Script, console2 } from "forge-std/Script.sol";
import { stdJson } from "forge-std/StdJson.sol";
import { L2Claim, ED25519Signature, MultisigKeys } from "src/L2/L2Claim.sol";
import { Signature, MerkleTreeLeaf, MerkleLeaves } from "test/L2/L2Claim.t.sol";
import "script/contracts/Utils.sol";

/// @title L2ClaimTokensScript - L2 Claim Lisk tokens script
/// @notice This contract is used to claim L2 Lisk tokens from the L2 Claim contract for a demonstration purpose. This
/// contract works independently without interacting with previously-deployed contracts and only works when `NETWORK` is
/// set as `devnet`.
contract L2ClaimTokensScript is Script {
    using stdJson for string;

    /// @notice Utils contract which provides functions to read and write JSON files containing L1 and L2 addresses.
    Utils internal utils;

    /// @notice LSK Token in L2.
    IERC20 internal lsk;

    /// @notice L2Claim Contract, with address pointing to Proxy.
    L2Claim internal l2Claim;

    /// @notice signatures.json in string format.
    string public signatureJson;

    /// @notice merkle-leaves.json in string format.
    string public merkleLeavesJson;

    /// @notice The destination address for claims as `address(uint160(uint256(keccak256("foundry default caller"))))`
    ///         and `nonce=2`.
    address public constant destination = address(0x34A1D3fff3958843C43aD80F30b94c510645C316);

    /// @notice 1 Beddows in LSK Chain = 10 * 10 Beddows in L2 Chain
    uint256 public constant MULTIPLIER = 10 ** 10;

    function getSignature(uint256 _index) internal view returns (Signature memory) {
        return abi.decode(signatureJson.parseRaw(string(abi.encodePacked(".[", vm.toString(_index), "]"))), (Signature));
    }

    function getMerkleLeaves() internal view returns (MerkleLeaves memory) {
        return abi.decode(merkleLeavesJson.parseRaw("."), (MerkleLeaves));
    }

    function setUp() public {
        utils = new Utils();

        Utils.L2AddressesConfig memory l2AddressesConfig = utils.readL2AddressesFile();
        lsk = IERC20(l2AddressesConfig.L2LiskToken);
        l2Claim = L2Claim(l2AddressesConfig.L2ClaimContract);

        // Get Merkle Root from /devnet/merkle-root.json
        Utils.MerkleRoot memory merkleRoot = utils.readMerkleRootFile("merkle-root.json");
        console2.log("MerkleRoot: %s", vm.toString(merkleRoot.merkleRoot));

        // Read devnet Json files
        string memory rootPath = string.concat(vm.projectRoot(), "/script/data/devnet");
        signatureJson = vm.readFile(string.concat(rootPath, "/signatures.json"));
        merkleLeavesJson = vm.readFile(string.concat(rootPath, "/merkle-leaves.json"));
    }

    /// @notice This function submit request to `claimRegularAccount` and `claimMultisigAccount` once to demonstrate
    /// claiming process of both regular account and multisig account
    function run() public {
        uint256 previousBalance = lsk.balanceOf(destination);
        console2.log("Destination LSK Balance before Claim:", previousBalance, "Beddows");

        // Claiming Regular Account
        MerkleTreeLeaf memory regularAccountLeaf = getMerkleLeaves().leaves[0];
        Signature memory regularAccountSignature = getSignature(0);
        console2.log(
            "Claiming Regular Account: id=0, LSK address(hex)=%s, Balance (Old Beddows): %s",
            vm.toString(abi.encodePacked(bytes20(regularAccountLeaf.b32Address << 96))),
            regularAccountLeaf.balanceBeddows
        );
        l2Claim.claimRegularAccount(
            regularAccountLeaf.proof,
            regularAccountSignature.sigs[0].pubKey,
            regularAccountLeaf.balanceBeddows,
            destination,
            ED25519Signature(regularAccountSignature.sigs[0].r, regularAccountSignature.sigs[0].s)
        );
        assert(previousBalance + regularAccountLeaf.balanceBeddows * MULTIPLIER == lsk.balanceOf(destination));
        console2.log("Destination LSK Balance After Regular Account Claim: %s Beddows", lsk.balanceOf(destination));

        // Claiming Multisig Account
        uint256 multisigAccountIndex = 0;
        MerkleTreeLeaf memory multisigAccountLeaf = getMerkleLeaves().leaves[multisigAccountIndex];

        // A non-hardcode way to get the first Multisig Account from Merkle Tree
        while (multisigAccountLeaf.numberOfSignatures == 0) {
            multisigAccountIndex++;
            multisigAccountLeaf = getMerkleLeaves().leaves[multisigAccountIndex];
        }
        Signature memory multisigAccountSignature = getSignature(multisigAccountIndex);

        console2.log(
            "Claiming Multisig Account: id=%s, LSK address(hex)=%s, Balance (Old Beddows): %s",
            multisigAccountIndex,
            vm.toString(abi.encodePacked(bytes20(multisigAccountLeaf.b32Address << 96))),
            multisigAccountLeaf.balanceBeddows
        );

        // Gather just-right amount of signatures from signatures.json
        ED25519Signature[] memory ed25519Signatures = new ED25519Signature[](multisigAccountLeaf.numberOfSignatures);
        for (uint256 i; i < multisigAccountLeaf.numberOfSignatures; i++) {
            ed25519Signatures[i] =
                ED25519Signature(multisigAccountSignature.sigs[i].r, multisigAccountSignature.sigs[i].s);
        }

        previousBalance = lsk.balanceOf(destination);
        l2Claim.claimMultisigAccount(
            multisigAccountLeaf.proof,
            bytes20(multisigAccountLeaf.b32Address << 96),
            multisigAccountLeaf.balanceBeddows,
            MultisigKeys(multisigAccountLeaf.mandatoryKeys, multisigAccountLeaf.optionalKeys),
            destination,
            ed25519Signatures
        );
        assert(previousBalance + multisigAccountLeaf.balanceBeddows * MULTIPLIER == lsk.balanceOf(destination));
        console2.log("Destination LSK Balance After Multisig Account Claim: %s Beddows", lsk.balanceOf(destination));
    }
}
