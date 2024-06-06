// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { Auth, Authority } from "solmate/src/auth/Auth.sol";
import { UnstructuredStorage } from "./lib/UnstructuredStorage.sol";
import { WithdrawQueueBase } from "./WithdrawQueueBase.sol";
import { IStToken } from "./interfaces/IStToken.sol";
import { IPausable } from "./interfaces/IPausable.sol";
import { IWstToken } from "./interfaces/IWstToken.sol";
import { ICgUSD } from "./interfaces/ICgUSD.sol";
import { IWithdrawQueue } from "./interfaces/IWithdrawQueue.sol";

abstract contract WithdrawQueue is WithdrawQueueBase, Pausable, Auth, IWithdrawQueue, IPausable {
    using UnstructuredStorage for bytes32;
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.UintSet;

    bytes32 internal constant BUNKER_MODE_SINCE_TIMESTAMP_POSITION =
        0x89ce48c0306492efdd7bb7ccb170a36cae1b05351529f64921b452a7f9d682f6; // keccak256("cygnus.WithdrawalQueue.bunkerModeSinceTimestamp");

    uint256 public constant BUNKER_MODE_DISABLED_TIMESTAMP = type(uint256).max;

    uint256 public constant MIN_STETH_WITHDRAWAL_AMOUNT = 100;

    uint256 public constant MAX_STETH_WITHDRAWAL_AMOUNT = 1e24;

    address public immutable stToken;

    address public immutable wstToken;

    address public immutable underlyingToken;

    event InitializedV1();
    event BunkerModeEnabled(uint256 _sinceTimestamp);
    event BunkerModeDisabled();
    event WithdrawSettingChanged(address _collector, uint256 _rate);

    error AdminZeroAddress();
    error RequestAmountTooSmall(uint256 _amountOfAssets);
    error RequestAmountTooLarge(uint256 _amountOfAssets);
    error InvalidReportTimestamp();
    error RequestIdsNotSorted();
    error ZeroRecipient();
    error ArraysLengthMismatch(uint256 _firstArrayLength, uint256 _secondArrayLength);

    constructor(
        address _wstToken,
        address _owner,
        address _authority
    ) Auth(_owner, Authority(_authority)) {
        wstToken = _wstToken;
        stToken = IWstToken(_wstToken).stToken();
        underlyingToken = ICgUSD(stToken).asset();
        _initialize();
    }

    function resume() external requiresAuth {
        _unpause();
    }

    function pause() external requiresAuth {
        _pause();
    }

    function setWithdraw(address _collector, uint256 _rate) external requiresAuth {
        _setWithdrawFeeRate(_rate);
        _setTaxCollectorAddress(_collector);
        emit WithdrawSettingChanged(_collector, _rate);
    }

    function requestWithdrawals(uint256[] calldata _amounts, address _owner)
        public
        whenNotPaused
        returns (uint256[] memory requestIds)
    {
        if (_owner == address(0)) _owner = msg.sender;
        requestIds = new uint256[](_amounts.length);
        for (uint256 i = 0; i < _amounts.length; ++i) {
            _checkWithdrawalRequestAmount(_amounts[i]);
            requestIds[i] = _requestWithdrawal(_amounts[i], _owner);
        }
    }

    function requestWithdrawalsWstToken(uint256[] calldata _amounts, address _owner)
        public
        whenNotPaused
        returns (uint256[] memory requestIds)
    {
        if (_owner == address(0)) _owner = msg.sender;
        requestIds = new uint256[](_amounts.length);
        for (uint256 i = 0; i < _amounts.length; ++i) {
            requestIds[i] = _requestWithdrawalWstToken(_amounts[i], _owner);
        }
    }

    function requestWithdrawalsWithPermit(uint256[] calldata _amounts, address _owner, PermitInput calldata _permit)
        external
        returns (uint256[] memory requestIds)
    {
        IERC20Permit(stToken).permit(msg.sender, address(this), _permit.value, _permit.deadline, _permit.v, _permit.r, _permit.s);
        return requestWithdrawals(_amounts, _owner);
    }

    function requestWithdrawalsWstTokenWithPermit(
        uint256[] calldata _amounts,
        address _owner,
        PermitInput calldata _permit
    ) external returns (uint256[] memory requestIds) {
        IERC20Permit(wstToken).permit(msg.sender, address(this), _permit.value, _permit.deadline, _permit.v, _permit.r, _permit.s);
        return requestWithdrawalsWstToken(_amounts, _owner);
    }

    function getWithdrawalRequests(address _owner) external view returns (uint256[] memory requestsIds) {
        return _getRequestsByOwner()[_owner].values();
    }

    function getWithdrawalStatus(uint256[] calldata _requestIds)
        external
        view
        returns (WithdrawalRequestStatus[] memory statuses)
    {
        statuses = new WithdrawalRequestStatus[](_requestIds.length);
        for (uint256 i = 0; i < _requestIds.length; ++i) {
            statuses[i] = _getStatus(_requestIds[i]);
        }
    }

    function getClaimableAssets(uint256[] calldata _requestIds, uint256[] calldata _hints)
        external
        view
        returns (uint256[] memory claimable)
    {
        claimable = new uint256[](_requestIds.length);
        for (uint256 i = 0; i < _requestIds.length; ++i) {
            claimable[i] = _getClaimableAssets(_requestIds[i], _hints[i]);
        }
    }

    function claimWithdrawalsTo(uint256[] calldata _requestIds, uint256[] calldata _hints, address _recipient)
        external
    {
        if (_recipient == address(0)) revert ZeroRecipient();
        if (_requestIds.length != _hints.length) {
            revert ArraysLengthMismatch(_requestIds.length, _hints.length);
        }

        for (uint256 i = 0; i < _requestIds.length; ++i) {
            _claim(_requestIds[i], _hints[i], _recipient);
            _emitTransfer(msg.sender, address(0), _requestIds[i]);
        }
    }

    function claimWithdrawals(uint256[] calldata _requestIds, uint256[] calldata _hints) external {
        if (_requestIds.length != _hints.length) {
            revert ArraysLengthMismatch(_requestIds.length, _hints.length);
        }

        for (uint256 i = 0; i < _requestIds.length; ++i) {
            _claim(_requestIds[i], _hints[i], msg.sender);
            _emitTransfer(msg.sender, address(0), _requestIds[i]);
        }
    }

    function claimWithdrawal(uint256 _requestId) external {
        _claim(_requestId, _findCheckpointHint(_requestId, 1, getLastCheckpointIndex()), msg.sender);
        _emitTransfer(msg.sender, address(0), _requestId);
    }

    function findCheckpointHints(uint256[] calldata _requestIds, uint256 _firstIndex, uint256 _lastIndex)
        external
        view
        returns (uint256[] memory hintIds)
    {
        hintIds = new uint256[](_requestIds.length);
        uint256 prevRequestId = 0;
        for (uint256 i = 0; i < _requestIds.length; ++i) {
            if (_requestIds[i] < prevRequestId) revert RequestIdsNotSorted();
            hintIds[i] = _findCheckpointHint(_requestIds[i], _firstIndex, _lastIndex);
            _firstIndex = hintIds[i];
            prevRequestId = _requestIds[i];
        }
    }

    function onOracleReport(bool _isBunkerModeNow, uint256 _bunkerStartTimestamp, uint256 _currentReportTimestamp)
        external
        requiresAuth
    {
        if (_bunkerStartTimestamp >= block.timestamp) revert InvalidReportTimestamp();
        if (_currentReportTimestamp >= block.timestamp) revert InvalidReportTimestamp();

        _setLastReportTimestamp(_currentReportTimestamp);

        bool isBunkerModeWasSetBefore = isBunkerModeActive();

        if (_isBunkerModeNow != isBunkerModeWasSetBefore) {
            // write previous timestamp to enable bunker or max uint to disable
            if (_isBunkerModeNow) {
                BUNKER_MODE_SINCE_TIMESTAMP_POSITION.setStorageUint256(_bunkerStartTimestamp);

                emit BunkerModeEnabled(_bunkerStartTimestamp);
            } else {
                BUNKER_MODE_SINCE_TIMESTAMP_POSITION.setStorageUint256(BUNKER_MODE_DISABLED_TIMESTAMP);

                emit BunkerModeDisabled();
            }
        }
    }

    function isBunkerModeActive() public view returns (bool) {
        return bunkerModeSinceTimestamp() < BUNKER_MODE_DISABLED_TIMESTAMP;
    }

    function bunkerModeSinceTimestamp() public view returns (uint256) {
        return BUNKER_MODE_SINCE_TIMESTAMP_POSITION.getStorageUint256();
    }

    function _emitTransfer(address from, address to, uint256 _requestId) internal virtual;

    function _initialize() internal {
        _initializeQueue();
        _pause();

        BUNKER_MODE_SINCE_TIMESTAMP_POSITION.setStorageUint256(BUNKER_MODE_DISABLED_TIMESTAMP);

        emit InitializedV1();
    }

    function _requestWithdrawal(uint256 _amountOfAssets, address _owner) internal returns (uint256 requestId) {
        IERC20(stToken).safeTransferFrom(msg.sender, address(this), _amountOfAssets);

        uint256 amountOfShares = IStToken(stToken).convertToShares(_amountOfAssets);

        requestId = _enqueue(uint128(_amountOfAssets), uint128(amountOfShares), _owner);

        _emitTransfer(address(0), _owner, requestId);
    }

    function _requestWithdrawalWstToken(uint256 _amountOfWstToken, address _owner) internal returns (uint256 requestId) {
        IERC20(wstToken).safeTransferFrom(msg.sender, address(this), _amountOfWstToken);

        uint256 amountOfAssets = IWstToken(wstToken).unwrap(_amountOfWstToken);
        _checkWithdrawalRequestAmount(amountOfAssets);

        uint256 amountOfShares = IStToken(stToken).convertToShares(amountOfAssets);

        requestId = _enqueue(uint128(amountOfAssets), uint128(amountOfShares), _owner);

        _emitTransfer(address(0), _owner, requestId);
    }

    function _checkWithdrawalRequestAmount(uint256 _amountOfAssets) internal pure {
        if (_amountOfAssets < MIN_STETH_WITHDRAWAL_AMOUNT) {
            revert RequestAmountTooSmall(_amountOfAssets);
        }
        if (_amountOfAssets > MAX_STETH_WITHDRAWAL_AMOUNT) {
            revert RequestAmountTooLarge(_amountOfAssets);
        }
    }

    function _getClaimableAssets(uint256 _requestId, uint256 _hint) internal view returns (uint256) {
        if (_requestId == 0 || _requestId > getLastRequestId()) revert InvalidRequestId(_requestId);

        if (_requestId > getLastFinalizedRequestId()) return 0;

        WithdrawalRequest storage request = _getQueue()[_requestId];
        if (request.claimed) return 0;

        return _calculateClaimableAssets(request, _requestId, _hint);
    }

    function sendValue(address _recipient, uint256 _amount) internal override {
        if (IERC20(underlyingToken).balanceOf(address(this)) < _amount) revert NotEnoughEther();

        IERC20(underlyingToken).safeTransfer(_recipient, _amount);
    }
}