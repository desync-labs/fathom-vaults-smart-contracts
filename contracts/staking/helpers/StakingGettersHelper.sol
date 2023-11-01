// SPDX-License-Identifier: AGPL 3.0
// Copyright Fathom 2022
pragma solidity 0.8.16;

import "./IStakingHelper.sol";
import "./IStakingGetterHelper.sol";
import "../interfaces/IStakingGetter.sol";
import "../StakingStructs.sol";
import "../../common/access/AccessControl.sol";

// solhint-disable not-rely-on-time
contract StakingGettersHelper is IStakingGetterHelper, AccessControl {
    address private stakingContract;

    error LockOpenedError();
    error LockIdOutOfIndexError();
    error LockIdCantBeZeroError();
    error NoLockedPosition();

    constructor(address _stakingContract, address admin) {
        stakingContract = _stakingContract;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function getLocksLength(address account) external view override returns (uint256) {
        LockedBalance[] memory locks = getLockInfo(account);
        return locks.length;
    }

    function getWeight() external view override returns (Weight memory) {
        return _getWeight();
    }

    function getLock(address account) external view override returns (uint128, uint128, uint64, address, uint256) {
        LockedBalance[] memory locks = getLockInfo(account);
        return (locks[0].amountOfToken, locks[0].positionStreamShares, locks[0].end, locks[0].owner, locks[0].amountOfSharesToken);
    }

    function getUserTotalDeposit(address account) external view override returns (uint256) {
        LockedBalance[] memory locks = getLockInfo(account);
        return locks[0].amountOfToken;
    }

    function getStreamClaimableAmount(uint256 streamId, address account) external view override returns (uint256) {
        uint256 totalRewards = IStakingHelper(stakingContract).getStreamClaimableAmountPerLock(streamId, account);
        return totalRewards;
    }

    function getUserTotalShares(address account) external view override returns (uint256) {
        LockedBalance[] memory locks = getLockInfo(account);
        return locks[0].amountOfSharesToken;
    }

    function getFeesForEarlyUnlock(address account) external view override returns (uint256) {
        LockedBalance[] memory locks = getLockInfo(account);
        if (locks[0].end <= block.timestamp) {
            revert LockOpenedError();
        }

        uint256 amount = locks[0].amountOfToken;
        uint256 lockEnd = locks[0].end;
        uint256 weighingCoef = _weightedPenalty(lockEnd, block.timestamp);
        uint256 penalty = (weighingCoef * amount) / 100000;
        return penalty;
    }

    function getLockInfo(address account) public view override returns (LockedBalance[] memory) {
        LockedBalance[] memory locks = IStakingHelper(stakingContract).getAllLocks(account);
        // Ensure the user has a lock position
        if (locks.length == 0) {
            revert NoLockedPosition();
        }
        return locks;
    }

    function _weightedPenalty(uint256 lockEnd, uint256 timestamp) internal view returns (uint256) {
        Weight memory weight = _getWeight();
        uint256 maxLockPeriod = IStakingHelper(stakingContract).maxLockPeriod();
        uint256 slopeStart = lockEnd;
        if (timestamp >= slopeStart) return 0;
        uint256 remainingTime = slopeStart - timestamp;

        //why weight multiplier: Because if a person remaining time is less than 12 hours, the calculation
        //would only give minWeightPenalty, because 2900 * 12hours/4days = 0
        return (weight.penaltyWeightMultiplier *
            weight.minWeightPenalty +
            (weight.penaltyWeightMultiplier * (weight.maxWeightPenalty - weight.minWeightPenalty) * remainingTime) /
            maxLockPeriod);
    }

    function _getWeight() internal view returns (Weight memory) {
        return IStakingStorage(stakingContract).weight();
    }
}
