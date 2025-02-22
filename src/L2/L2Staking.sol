// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.23;

import { Initializable } from "@openzeppelin-upgradeable/contracts/proxy/utils/Initializable.sol";
import { Ownable2StepUpgradeable } from "@openzeppelin-upgradeable/contracts/access/Ownable2StepUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin-upgradeable/contracts/proxy/utils/UUPSUpgradeable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { IL2LockingPosition } from "../interfaces/L2/IL2LockingPosition.sol";
import { ISemver } from "../utils/ISemver.sol";

/// @title L2Staking
/// @notice This contract handles the staking functionality for the L2 network.
contract L2Staking is Initializable, Ownable2StepUpgradeable, UUPSUpgradeable, ISemver {
    /// @notice Minimum locking amount.
    uint256 public constant MIN_LOCKING_AMOUNT = 10 ** 16;

    /// @notice Minimum possible locking duration (in days).
    uint32 public constant MIN_LOCKING_DURATION = 14;

    /// @notice Maximum possible locking duration (in days).
    uint32 public constant MAX_LOCKING_DURATION = 730; // 2 years

    /// @notice Emergency locking duration to enable fast unlock option (in days).
    uint32 public constant FAST_UNLOCK_DURATION = 3;

    /// @notice Specifies the part of the locked amount that is subject to penalty in case of fast unlock.
    uint32 public constant PENALTY_DENOMINATOR = 2;

    /// @notice Mapping of addresses to boolean values indicating whether the address is allowed to create locking
    ///         positions.
    mapping(address => bool) public allowedCreators;

    /// @notice Whenever this variable is set to True, it is possible to fast unlock (i.e. 3 days of locking period)
    ///         without paying a penalty and then unlock all staked amounts.
    bool public emergencyExitEnabled;

    /// @notice  Address of the L2LiskToken contract.
    address public l2LiskTokenContract;

    /// @notice Address of the Locking Position contract.
    address public lockingPositionContract;

    /// @notice The treasury address of the Lisk DAO.
    address public daoTreasury;

    /// @notice Semantic version of the contract.
    string public version;

    /// @notice Emitted when the L2LiskToken contract address is changed.
    event LiskTokenContractAddressChanged(address indexed oldAddress, address indexed newAddress);

    /// @notice Emitted when the Locking Position contract address is changed.
    event LockingPositionContractAddressChanged(address indexed oldAddress, address indexed newAddress);

    /// @notice Emitted when the DAO Treasury address is changed.
    event DaoTreasuryAddressChanged(address indexed oldAddress, address indexed newAddress);

    /// @notice Emitted when a new creator is added.
    event AllowedCreatorAdded(address indexed creator);

    /// @notice Emitted when a creator is removed.
    event AllowedCreatorRemoved(address indexed creator);

    /// @notice Emitted when the EmergencyExitEnabled flag is changed.
    event EmergencyExitEnabledChanged(bool indexed oldEmergencyExitEnabled, bool indexed newEmergencyExitEnabled);

    /// @notice Emitted when a new amount is locked.
    event AmountLocked(uint256 indexed lockId, address indexed lockOwner, uint256 amount, uint256 lockingDuration);

    /// @notice Emitted when an amount is unlocked.
    event AmountUnlocked(uint256 indexed lockId);

    /// @notice Emitted when a fast unlock is initiated.
    event FastUnlockInitiated(uint256 indexed lockId, uint256 penalty);

    /// @notice Emitted when the locking amount is increased.
    event LockingAmountIncreased(uint256 indexed lockId, uint256 amountIncrease);

    /// @notice Emitted when the locking duration is extended.
    event LockingDurationExtended(uint256 indexed lockId, uint256 extendDays);

    /// @notice Emitted when the remaining locking duration is paused.
    event RemainingLockingDurationPaused(uint256 indexed lockId);

    /// @notice Emitted when the countdown of the remaining locking duration is resumed.
    event CountdownResumed(uint256 indexed lockId);

    /// @notice Disabling initializers on implementation contract to prevent misuse.
    constructor() {
        _disableInitializers();
    }

    /// @notice Setting global params.
    /// @param _l2LiskTokenContract The address of the L2LiskToken contract.
    function initialize(address _l2LiskTokenContract) public initializer {
        require(_l2LiskTokenContract != address(0), "L2Staking: LSK token contract address can not be zero");
        __Ownable2Step_init();
        __Ownable_init(msg.sender);
        __UUPSUpgradeable_init();
        l2LiskTokenContract = _l2LiskTokenContract;
        version = "1.0.0";
        emit LiskTokenContractAddressChanged(address(0), l2LiskTokenContract);
    }

    /// @notice Ensures that only the owner can authorize a contract upgrade. It reverts if called by any address other
    ///         than the contract owner.
    /// @param _newImplementation The address of the new contract implementation to which the proxy will be upgraded.
    function _authorizeUpgrade(address _newImplementation) internal virtual override onlyOwner { }

    /// @notice Returns the current day.
    /// @return The current day.
    function todayDay() internal view virtual returns (uint256) {
        return block.timestamp / 1 days;
    }

    /// @notice Returns whether the given locking position is null. Locking position is null if all its fields are
    ///         initialized to 0 or address(0).
    /// @param position Locking position to be checked.
    /// @return Whether the given locking position is null.
    function isLockingPositionNull(IL2LockingPosition.LockingPosition memory position)
        internal
        view
        virtual
        returns (bool)
    {
        // We are using == to compare with 0 because we want to check if the fields are initialized to 0 or address(0).
        // slither-disable-next-line incorrect-equality
        return position.creator == address(0) && position.amount == 0 && position.expDate == 0
            && position.pausedLockingDuration == 0;
    }

    /// @notice Returns whether the locking position can be modified by the caller. A position can only be modified by
    ///         the owner if the staking contract is the creator. If the position was not created by the staking
    ///         contract, it can only be modified by the creator.
    /// @param lockId The ID of the locking position.
    /// @param lock The locking position to be checked.
    /// @return Whether the locking position can be modified by the caller.
    function canLockingPositionBeModified(
        uint256 lockId,
        IL2LockingPosition.LockingPosition memory lock
    )
        internal
        view
        virtual
        returns (bool)
    {
        address ownerOfLock = (IL2LockingPosition(lockingPositionContract)).ownerOf(lockId);
        bool condition1 = allowedCreators[msg.sender] && lock.creator == msg.sender;
        bool condition2 = ownerOfLock == msg.sender && lock.creator == address(this);

        if (condition1 || condition2) {
            return true;
        }
        return false;
    }

    /// @notice Calculates the penalty for the given amount and remaining duration of the locking position.
    /// @param amount The amount for which the penalty is calculated.
    /// @param remainingDuration The remaining duration of the locking position.
    /// @return The penalty for the given amount and remaining duration.
    function calculatePenalty(uint256 amount, uint256 remainingDuration) internal view virtual returns (uint256) {
        if (emergencyExitEnabled) {
            return 0;
        }

        // initiateFastUnlock can only be called if remaining duration is more than FAST_UNLOCK_DURATION; so we can
        // safely assume that remainingDuration is greater than FAST_UNLOCK_DURATION.
        require(remainingDuration > FAST_UNLOCK_DURATION, "L2Staking: less than 3 days until unlock required");

        return (amount * (remainingDuration - FAST_UNLOCK_DURATION)) / (MAX_LOCKING_DURATION * PENALTY_DENOMINATOR);
    }

    /// @notice Returns the remaining locking duration for the given locking position.
    /// @param lock The locking position for which the remaining locking duration is returned.
    /// @return The remaining locking duration for the given locking position.
    function remainingLockingDuration(IL2LockingPosition.LockingPosition memory lock)
        internal
        view
        virtual
        returns (uint256)
    {
        if (lock.pausedLockingDuration == 0) {
            uint256 today = todayDay();
            if (lock.expDate <= today) {
                return 0;
            } else {
                return lock.expDate - today;
            }
        } else {
            return lock.pausedLockingDuration;
        }
    }

    /// @notice Initializes the L2LockingPosition contract address.
    /// @param _lockingPositionContract The address of the L2LockingPosition contract.
    function initializeLockingPosition(address _lockingPositionContract) public virtual onlyOwner {
        require(lockingPositionContract == address(0), "L2Staking: Locking Position contract is already initialized");
        require(_lockingPositionContract != address(0), "L2Staking: Locking Position contract address can not be zero");
        lockingPositionContract = _lockingPositionContract;
        emit LockingPositionContractAddressChanged(address(0), lockingPositionContract);
    }

    /// @notice Initializes the Lisk DAO Treasury address.
    /// @param _daoTreasury The treasury address of the Lisk DAO.
    function initializeDaoTreasury(address _daoTreasury) public virtual onlyOwner {
        require(daoTreasury == address(0), "L2Staking: Lisk DAO Treasury contract is already initialized");
        require(_daoTreasury != address(0), "L2Staking: Lisk DAO Treasury contract address can not be zero");
        daoTreasury = _daoTreasury;
        emit DaoTreasuryAddressChanged(address(0), daoTreasury);
    }

    /// @notice Adds a new creator to the list of allowed creators.
    /// @param newCreator The address of the new creator to be added.
    /// @dev Only the owner can call this function.
    function addCreator(address newCreator) public virtual onlyOwner {
        require(newCreator != address(0), "L2Staking: creator address can not be zero");
        require(newCreator != address(this), "L2Staking: Staking contract can not be added as a creator");
        allowedCreators[newCreator] = true;
        emit AllowedCreatorAdded(newCreator);
    }

    /// @notice Removes a creator from the list of allowed creators.
    /// @param creator The address of the creator to be removed.
    /// @dev Only the owner can call this function.
    function removeCreator(address creator) public virtual onlyOwner {
        require(creator != address(0), "L2Staking: creator address can not be zero");
        delete allowedCreators[creator];
        emit AllowedCreatorRemoved(creator);
    }

    /// @notice Sets the emergency exit enabled flag.
    /// @param _emergencyExitEnabled The new value of the emergency exit enabled flag.
    /// @dev Only the owner can call this function.
    function setEmergencyExitEnabled(bool _emergencyExitEnabled) public virtual onlyOwner {
        emergencyExitEnabled = _emergencyExitEnabled;
        emit EmergencyExitEnabledChanged(!emergencyExitEnabled, emergencyExitEnabled);
    }

    /// @notice Locks the given amount for the given owner for the given locking duration and creates a new locking
    ///         position and returns its ID.
    /// @param lockOwner The address of the owner for whom the amount is locked.
    /// @param amount The amount to be locked.
    /// @param lockingDuration The duration for which the amount is locked (in days).
    /// @return The ID of the newly created locking position.
    function lockAmount(address lockOwner, uint256 amount, uint256 lockingDuration) public virtual returns (uint256) {
        require(lockOwner != address(0), "L2Staking: lockOwner address can not be zero");
        require(
            amount >= MIN_LOCKING_AMOUNT,
            string.concat("L2Staking: amount should be greater than or equal to ", Strings.toString(MIN_LOCKING_AMOUNT))
        );
        require(
            lockingDuration >= MIN_LOCKING_DURATION,
            "L2Staking: lockingDuration should be at least MIN_LOCKING_DURATION"
        );
        require(
            lockingDuration <= MAX_LOCKING_DURATION,
            "L2Staking: lockingDuration can not be greater than MAX_LOCKING_DURATION"
        );

        address creator = address(0);
        if (allowedCreators[msg.sender]) {
            creator = msg.sender;
        } else {
            creator = address(this);
            require(
                msg.sender == lockOwner,
                "L2Staking: owner different than message sender, can not create locking position"
            );
        }

        // We assume that owner or creator has already approved the Staking contract to transfer the amount and in most
        // cases lockAmount will be called from a smart contract (creator).
        // slither-disable-next-line arbitrary-send-erc20
        bool success = IERC20(l2LiskTokenContract).transferFrom(msg.sender, address(this), amount);
        require(success, "L2Staking: LSK token transfer from owner or creator to Staking contract failed");

        uint256 lockId = (IL2LockingPosition(lockingPositionContract)).createLockingPosition(
            creator, lockOwner, amount, lockingDuration
        );

        emit AmountLocked(lockId, lockOwner, amount, lockingDuration);

        return lockId;
    }

    /// @notice Unlocks the given locking position and transfers the locked amount back to the owner.
    /// @param lockId The ID of the locking position to be unlocked.
    function unlock(uint256 lockId) public virtual {
        IL2LockingPosition.LockingPosition memory lock =
            (IL2LockingPosition(lockingPositionContract)).getLockingPosition(lockId);
        require(isLockingPositionNull(lock) == false, "L2Staking: locking position does not exist");
        require(canLockingPositionBeModified(lockId, lock), "L2Staking: only owner or creator can call this function");

        if (lock.expDate <= todayDay() && lock.pausedLockingDuration == 0) {
            // unlocking is valid
            address ownerOfLock = (IL2LockingPosition(lockingPositionContract)).ownerOf(lockId);
            bool success = IERC20(l2LiskTokenContract).transfer(ownerOfLock, lock.amount);
            require(success, "L2Staking: LSK token transfer from Staking contract to owner failed");
            (IL2LockingPosition(lockingPositionContract)).removeLockingPosition(lockId);
        } else {
            // stake did not expire
            revert("L2Staking: locking duration active, can not unlock");
        }

        emit AmountUnlocked(lockId);
    }

    /// @notice Initiates a fast unlock and apply a penalty to the locked amount. Sends the penalty amount to the Lisk
    ///         DAO Treasury or the creator of the locking position.
    /// @param lockId The ID of the locking position to be unlocked.
    /// @return The penalty amount applied to the locked amount.
    function initiateFastUnlock(uint256 lockId) public virtual returns (uint256) {
        IL2LockingPosition.LockingPosition memory lock =
            (IL2LockingPosition(lockingPositionContract)).getLockingPosition(lockId);
        require(isLockingPositionNull(lock) == false, "L2Staking: locking position does not exist");
        require(canLockingPositionBeModified(lockId, lock), "L2Staking: only owner or creator can call this function");
        require(remainingLockingDuration(lock) > FAST_UNLOCK_DURATION, "L2Staking: less than 3 days until unlock");

        // calculate penalty
        uint256 penalty = calculatePenalty(lock.amount, remainingLockingDuration(lock));

        uint256 amount = lock.amount - penalty;
        uint256 expDate = todayDay() + FAST_UNLOCK_DURATION;

        // update locking position
        (IL2LockingPosition(lockingPositionContract)).modifyLockingPosition(lockId, amount, expDate, 0);

        if (lock.creator == address(this)) {
            // send penalty amount to the Lisk DAO Treasury contract
            bool success = IERC20(l2LiskTokenContract).transfer(daoTreasury, penalty);
            require(success, "L2Staking: LSK token transfer from Staking contract to DAO failed");
        } else {
            // send penalty amount to the creator
            bool success = IERC20(l2LiskTokenContract).transfer(lock.creator, penalty);
            require(success, "L2Staking: LSK token transfer from Staking contract to creator failed");
        }

        emit FastUnlockInitiated(lockId, penalty);

        return penalty;
    }

    /// @notice Increases the amount of the given locking position.
    /// @param lockId The ID of the locking position to be increased.
    /// @param amountIncrease The amount by which the locking position is increased.
    function increaseLockingAmount(uint256 lockId, uint256 amountIncrease) public virtual {
        IL2LockingPosition.LockingPosition memory lock =
            (IL2LockingPosition(lockingPositionContract)).getLockingPosition(lockId);
        require(isLockingPositionNull(lock) == false, "L2Staking: locking position does not exist");
        require(canLockingPositionBeModified(lockId, lock), "L2Staking: only owner or creator can call this function");
        require(amountIncrease > 0, "L2Staking: increased amount should be greater than zero");
        require(
            remainingLockingDuration(lock) >= MIN_LOCKING_DURATION,
            "L2Staking: can not increase amount, less than minimum locking duration remaining"
        );

        // We assume that owner or creator has already approved the Staking contract to transfer the amount and in most
        // cases increaseLockingAmount will be called from a smart contract (creator).
        // slither-disable-next-line arbitrary-send-erc20
        bool success = IERC20(l2LiskTokenContract).transferFrom(msg.sender, address(this), amountIncrease);
        require(success, "L2Staking: LSK token transfer from owner or creator to Staking contract failed");

        // update locking position
        (IL2LockingPosition(lockingPositionContract)).modifyLockingPosition(
            lockId, lock.amount + amountIncrease, lock.expDate, lock.pausedLockingDuration
        );

        emit LockingAmountIncreased(lockId, amountIncrease);
    }

    /// @notice Extends the duration of the given locking position.
    /// @param lockId The ID of the locking position to be extended.
    /// @param extendDays The number of days by which the locking position is extended.
    function extendLockingDuration(uint256 lockId, uint256 extendDays) public virtual {
        IL2LockingPosition.LockingPosition memory lock =
            (IL2LockingPosition(lockingPositionContract)).getLockingPosition(lockId);
        require(isLockingPositionNull(lock) == false, "L2Staking: locking position does not exist");
        require(canLockingPositionBeModified(lockId, lock), "L2Staking: only owner or creator can call this function");
        require(extendDays > 0, "L2Staking: extendDays should be greater than zero");
        require(
            remainingLockingDuration(lock) + extendDays <= MAX_LOCKING_DURATION,
            "L2Staking: locking duration can not be extended to more than MAX_LOCKING_DURATION"
        );

        if (lock.pausedLockingDuration > 0) {
            // remaining duration is paused
            lock.pausedLockingDuration += extendDays;
        } else {
            // remaining duration not paused, if expired, assume expDate is today
            lock.expDate = Math.max(lock.expDate, todayDay()) + extendDays;
        }

        // update locking position
        (IL2LockingPosition(lockingPositionContract)).modifyLockingPosition(
            lockId, lock.amount, lock.expDate, lock.pausedLockingDuration
        );

        emit LockingDurationExtended(lockId, extendDays);
    }

    /// @notice Pauses the countdown of the remaining locking duration of the given locking position.
    /// @param lockId The ID of the locking position for which the remaining locking duration is paused.
    function pauseRemainingLockingDuration(uint256 lockId) public virtual {
        IL2LockingPosition.LockingPosition memory lock =
            (IL2LockingPosition(lockingPositionContract)).getLockingPosition(lockId);
        require(isLockingPositionNull(lock) == false, "L2Staking: locking position does not exist");
        require(canLockingPositionBeModified(lockId, lock), "L2Staking: only owner or creator can call this function");
        require(lock.pausedLockingDuration == 0, "L2Staking: remaining duration is already paused");

        uint256 today = todayDay();
        require(lock.expDate > today, "L2Staking: locking period has ended");

        // update locking position
        lock.pausedLockingDuration = lock.expDate - today;
        (IL2LockingPosition(lockingPositionContract)).modifyLockingPosition(
            lockId, lock.amount, lock.expDate, lock.pausedLockingDuration
        );

        emit RemainingLockingDurationPaused(lockId);
    }

    /// @notice Resumes the remaining locking duration of the given locking position.
    /// @param lockId The ID of the locking position for which the remaining locking duration is resumed.
    function resumeCountdown(uint256 lockId) public virtual {
        IL2LockingPosition.LockingPosition memory lock =
            (IL2LockingPosition(lockingPositionContract)).getLockingPosition(lockId);
        require(isLockingPositionNull(lock) == false, "L2Staking: locking position does not exist");
        require(canLockingPositionBeModified(lockId, lock), "L2Staking: only owner or creator can call this function");
        require(lock.pausedLockingDuration > 0, "L2Staking: countdown is not paused");

        // update locking position
        lock.expDate = todayDay() + lock.pausedLockingDuration;
        lock.pausedLockingDuration = 0;
        (IL2LockingPosition(lockingPositionContract)).modifyLockingPosition(
            lockId, lock.amount, lock.expDate, lock.pausedLockingDuration
        );

        emit CountdownResumed(lockId);
    }
}
