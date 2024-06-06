// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IBurner } from "./interfaces/IBurner.sol";
import { ILocator } from "./interfaces/ILocator.sol";
import { IOracleReportSanityChecker } from "./interfaces/IOracleReportSanityChecker.sol";
import { IWithdrawVault } from "./interfaces/IWithdrawVault.sol";
import { IWithdrawQueueERC721 } from "./interfaces/IWithdrawQueueERC721.sol";
import { ICgUSD } from "./interfaces/ICgUSD.sol";
import { IPausable } from "./interfaces/IPausable.sol";
import { UnstructuredStorage } from "./lib/UnstructuredStorage.sol";
import { StToken } from "./StToken.sol";

contract CgUSD is StToken, Ownable, Initializable, ICgUSD, IPausable {
    using SafeERC20 for IERC20;
    using UnstructuredStorage for bytes32;

    address public asset;

    bytes32 internal constant LOCATOR_POSITION =
        0x1718d90604c88f478732e809519e74c5c9a3a2b5dc95162ccc63d61800e42625; // keccak256("cygnus.CgUSD.locator")

    bytes32 internal constant BUFFERED_ASSET_POSITION =
        0x0afc87acedeee8c4193ad63118c06a9f961d4d6f3e34515e102d41596851b1a6; // keccak256("cygnus.CgUSD.bufferedAsset");

    bytes32 internal constant INVESTED_ASSET_POSITION =
        0x2c852a3a34b8266c1f4cf623581e3b3686edf6412c376db5da52f02d19ef925b; // keccak256("cygnus.CgUSD.investedAsset");

    struct OracleReportedData {
        uint256 reportTimestamp;
        uint256 timeElapsed;
        uint256 newInvestedAssets;
        uint256 withdrawalVaultBalance;
        uint256 sharesRequestedToBurn;
        uint256[] withdrawalFinalizationBatches;
        uint256 simulatedShareRate;
    }

    struct OracleReportContracts {
        address accountingOracle;
        address oracleReportSanityChecker;
        address burner;
        address withdrawQueue;
        address withdrawVault;
    }

    struct OracleReportContext {
        uint256 preTotalPooledAssets;
        uint256 preTotalShares;
        uint256 assetsToLockOnWithdrawalQueue;
        uint256 sharesToBurnFromWithdrawalQueue;
        uint256 simulatedSharesToBurn;
        uint256 sharesToBurn;
    }

    event AssetsDistributed(
        uint256 indexed reportTimestamp,
        uint256 withdrawalsWithdrawn,
        uint256 postBufferedAssets,
        uint256 postInvestedAssets
    );

    event TokenRebased(
        uint256 indexed reportTimestamp,
        uint256 timeElapsed,
        uint256 preTotalShares,
        uint256 preTotalAssets,
        uint256 postTotalShares,
        uint256 postTotalAssets
    );

    event LocatorSet(address locator);

    event WithdrawalsReceived(uint256 amount);

    event Submitted(address indexed sender, uint256 amount, address referral);

    event Invested(uint256 amount, uint256 postBufferedAssets, uint256 postInvestedAssets);

    constructor(
        address _asset,
        address _owner
    ) Ownable(_owner) {
        asset = _asset;
    }

    function initialize(address _locator) external initializer {
        _bootstrapInitialHolder();

        LOCATOR_POSITION.setStorageAddress(_locator);
        _approve(
            ILocator(_locator).withdrawQueue(),
            ILocator(_locator).burner(),
            INFINITE_ALLOWANCE
        );

        emit LocatorSet(_locator);
    }

    function decimals() external view override returns (uint8) {
        return IERC20Metadata(asset).decimals();
    }

    function resume() external onlyOwner {
        _unpause();
    }

    function pause() external onlyOwner {
        _pause();
    }

    function _getTotalPooledAssets() internal view override returns (uint256) {
        return _getBufferedAssets() + _getInvestedAssets();
    }

    function getTotalAssets() external view returns (uint256, uint256) {
        return (_getBufferedAssets(), _getInvestedAssets());
    }

    function canDeposit() public view returns (bool) {
        return !_withdrawalQueue().isBunkerModeActive() && !paused();
    }

    function mint(address _referral, uint256 _assetsAmount)
        external
        returns (uint256 sharesAmount)
    {
        require((sharesAmount = previewDeposit(_assetsAmount)) != 0, "ZERO_SHARES");

        // TODO: check if oracle price deviated

        IERC20(asset).safeTransferFrom(msg.sender, address(this), _assetsAmount);

        _mintShares(msg.sender, sharesAmount);

        _setBufferedAssets(_getBufferedAssets() + _assetsAmount);
        emit Submitted(msg.sender, _assetsAmount, _referral);

        _emitTransferAfterMintingShares(msg.sender, sharesAmount);
    }

    function invest(address _to, uint256 _assetsAmount) external onlyOwner {
        require(canDeposit(), "CAN_NOT_INVEST");

        IERC20(asset).safeTransfer(_to, _assetsAmount);

        uint256 postBufferedAssets = _getBufferedAssets() - _assetsAmount;
        uint256 postInvestedAssets = _getInvestedAssets() + _assetsAmount;
        _setBufferedAssets(postBufferedAssets);
        _setInvestedAssets(postInvestedAssets);
        emit Invested(_assetsAmount, postBufferedAssets, postInvestedAssets);
    }

    function handleOracleReport(
        uint256 _reportTimestamp,
        uint256 _timeElapsed,
        uint256 _newInvestedAssets,
        uint256 _withdrawalVaultBalance,
        uint256 _sharesRequestedToBurn,
        uint256[] calldata _withdrawalFinalizationBatches,
        uint256 _simulatedShareRate
    ) external whenNotPaused returns (uint256[3] memory postRebaseAmounts) {
        return _handleOracleReport(
            OracleReportedData(
                _reportTimestamp,
                _timeElapsed,
                _newInvestedAssets,
                _withdrawalVaultBalance,
                _sharesRequestedToBurn,
                _withdrawalFinalizationBatches,
                _simulatedShareRate
            )
        );
    }

    function _handleOracleReport(OracleReportedData memory _reportedData) internal returns (uint256[3] memory) {
        OracleReportContracts memory contracts = _loadOracleReportContracts();

        require(msg.sender == contracts.accountingOracle, "APP_AUTH_FAILED");
        require(_reportedData.reportTimestamp <= block.timestamp, "INVALID_REPORT_TIMESTAMP");

        OracleReportContext memory reportContext;

        // Step 1.
        // Take a snapshot of the current (pre-) state
        reportContext.preTotalPooledAssets = _getTotalPooledAssets();
        reportContext.preTotalShares = _getTotalShares();

        // Step 2.
        // Pass the report data to sanity checker (reverts if malformed)
        _checkAccountingOracleReport(contracts, _reportedData);

        // Step 3.
        // Pre-calculate the ether to lock for withdrawal queue and shares to be burnt
        // due to withdrawal requests to finalize
        if (_reportedData.withdrawalFinalizationBatches.length != 0) {
            (
                reportContext.assetsToLockOnWithdrawalQueue,
                reportContext.sharesToBurnFromWithdrawalQueue
            ) = _calculateWithdrawals(contracts, _reportedData);

            if (reportContext.sharesToBurnFromWithdrawalQueue > 0) {
                IBurner(contracts.burner).requestBurnShares(
                    contracts.withdrawQueue,
                    reportContext.sharesToBurnFromWithdrawalQueue
                );
            }
        }

        // Step 4.
        // Pass the accounting values to sanity checker to smoothen positive token rebase

        uint256 withdrawals;
        (
            withdrawals, reportContext.simulatedSharesToBurn, reportContext.sharesToBurn
        ) = IOracleReportSanityChecker(contracts.oracleReportSanityChecker).smoothenTokenRebase(
            reportContext.preTotalPooledAssets,
            reportContext.preTotalShares,
            _reportedData.withdrawalVaultBalance,
            _reportedData.sharesRequestedToBurn,
            reportContext.assetsToLockOnWithdrawalQueue,
            reportContext.sharesToBurnFromWithdrawalQueue
        );

        // Step 5.
        // Invoke finalization of the withdrawal requests (send ether to withdrawal queue, assign shares to be burnt)
        _collectRewardsAndProcessWithdrawals(
            contracts,
            withdrawals,
            _reportedData.withdrawalFinalizationBatches,
            _reportedData.simulatedShareRate,
            reportContext.assetsToLockOnWithdrawalQueue
        );

        // Step 6.
        // Update invested assets
        _setInvestedAssets(_reportedData.newInvestedAssets);

        emit AssetsDistributed(
            _reportedData.reportTimestamp,
            withdrawals,
            _getBufferedAssets(),
            _getInvestedAssets()
        );

        // Step 7.
        // Burn the previously requested shares
        if (reportContext.sharesToBurn > 0) {
            IBurner(contracts.burner).commitSharesToBurn(reportContext.sharesToBurn);
            _burnShares(contracts.burner, reportContext.sharesToBurn);
        }

        // Step 8.
        // Complete token rebase (emit an event)
        (
            uint256 postTotalShares,
            uint256 postTotalPooledAssets
        ) = _completeTokenRebase(
            _reportedData,
            reportContext
        );

        // Step 9. Sanity check for the provided simulated share rate
        if (_reportedData.withdrawalFinalizationBatches.length != 0) {
            IOracleReportSanityChecker(contracts.oracleReportSanityChecker).checkSimulatedShareRate(
                postTotalPooledAssets,
                postTotalShares,
                reportContext.assetsToLockOnWithdrawalQueue,
                reportContext.sharesToBurn - reportContext.simulatedSharesToBurn,
                _reportedData.simulatedShareRate
            );
        }

        return [postTotalPooledAssets, postTotalShares, withdrawals];
    }

    function _collectRewardsAndProcessWithdrawals(
        OracleReportContracts memory _contracts,
        uint256 _withdrawalsToWithdraw,
        uint256[] memory _withdrawalFinalizationBatches,
        uint256 _simulatedShareRate,
        uint256 _assetsToLockOnWithdrawalQueue
    ) internal {
        // withdraw withdrawals and put them to the buffer
        if (_withdrawalsToWithdraw > 0) {
            IWithdrawVault(_contracts.withdrawVault).withdrawWithdrawals(_withdrawalsToWithdraw);
        }

        // finalize withdrawals (send ether, assign shares for burning)
        if (_assetsToLockOnWithdrawalQueue > 0) { // TODO
            IWithdrawQueueERC721 withdrawalQueue = IWithdrawQueueERC721(_contracts.withdrawQueue);
            IERC20(asset).safeTransfer(_contracts.withdrawQueue, _assetsToLockOnWithdrawalQueue);
            withdrawalQueue.finalize(
                _withdrawalFinalizationBatches[_withdrawalFinalizationBatches.length - 1],
                _simulatedShareRate,
                _assetsToLockOnWithdrawalQueue
            );
        }

        uint256 postBufferedAssets = _getBufferedAssets() + _withdrawalsToWithdraw - _assetsToLockOnWithdrawalQueue;

        _setBufferedAssets(postBufferedAssets);
    }

    function _calculateWithdrawals(
        OracleReportContracts memory _contracts,
        OracleReportedData memory _reportedData
    ) internal view returns (
        uint256 assetsToLock, uint256 sharesToBurn
    ) {
        IWithdrawQueueERC721 withdrawalQueue = IWithdrawQueueERC721(_contracts.withdrawQueue);

        //if (!withdrawalQueue.isPaused()) { TODO
        {
            IOracleReportSanityChecker(_contracts.oracleReportSanityChecker).checkWithdrawalQueueOracleReport(
                _reportedData.withdrawalFinalizationBatches[_reportedData.withdrawalFinalizationBatches.length - 1],
                _reportedData.reportTimestamp
            );

            (assetsToLock, sharesToBurn) = withdrawalQueue.prefinalize(
                _reportedData.withdrawalFinalizationBatches,
                _reportedData.simulatedShareRate
            );
        }
    }

    function _checkAccountingOracleReport(
        OracleReportContracts memory _contracts,
        OracleReportedData memory _reportedData
    ) internal view {
        IOracleReportSanityChecker(_contracts.oracleReportSanityChecker).checkAccountingOracleReport(
            _reportedData.timeElapsed,
            _reportedData.withdrawalVaultBalance,
            _reportedData.sharesRequestedToBurn
        );
    }

    function _completeTokenRebase(
        OracleReportedData memory _reportedData,
        OracleReportContext memory _reportContext
    ) internal returns (uint256 postTotalShares, uint256 postTotalPooledAssets) {
        postTotalShares = _getTotalShares();
        postTotalPooledAssets = _getTotalPooledAssets();

        emit TokenRebased(
            _reportedData.reportTimestamp,
            _reportedData.timeElapsed,
            _reportContext.preTotalShares,
            _reportContext.preTotalPooledAssets,
            postTotalShares,
            postTotalPooledAssets
        );
    }

    function _loadOracleReportContracts() internal view returns (OracleReportContracts memory ret) {
        (
            ret.accountingOracle,
            ret.oracleReportSanityChecker,
            ret.burner,
            ret.withdrawQueue,
            ret.withdrawVault
        ) = getLocator().oracleReportComponents();
    }

    function getLocator() public view returns (ILocator) {
        return ILocator(LOCATOR_POSITION.getStorageAddress());
    }

    function _withdrawalQueue() internal view returns (IWithdrawQueueERC721) {
        return IWithdrawQueueERC721(getLocator().withdrawQueue());
    }

    function _getBufferedAssets() internal view returns (uint256) {
        return BUFFERED_ASSET_POSITION.getStorageUint256();
    }

    function _setBufferedAssets(uint256 _newBufferedAssets) internal {
        BUFFERED_ASSET_POSITION.setStorageUint256(_newBufferedAssets);
    }

    function _getInvestedAssets() internal view returns (uint256) {
        return INVESTED_ASSET_POSITION.getStorageUint256();
    }

    function _setInvestedAssets(uint256 _newInvestedAssets) internal {
        INVESTED_ASSET_POSITION.setStorageUint256(_newInvestedAssets);
    }

    function _bootstrapInitialHolder() internal {
        uint256 balance = IERC20(asset).balanceOf(address(this));
        assert(balance != 0);

        if (_getTotalShares() == 0) {
            _setBufferedAssets(balance);
            emit Submitted(INITIAL_TOKEN_HOLDER, balance, address(0));
            _mintInitialShares(balance);
        }
    }
}