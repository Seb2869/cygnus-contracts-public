// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { FixedPointMathLib } from "solmate/src/utils/FixedPointMathLib.sol";
import { UnstructuredStorage } from "./lib/UnstructuredStorage.sol";

abstract contract StToken is IERC20, Pausable {
    using FixedPointMathLib for uint256;
    using UnstructuredStorage for bytes32;

    address constant internal INITIAL_TOKEN_HOLDER = address(0xDEAD);
    uint256 constant internal INFINITE_ALLOWANCE = type(uint256).max;

    mapping (address => uint256) private shares;

    mapping (address => mapping (address => uint256)) private allowances;

    bytes32 internal constant TOTAL_SHARES_POSITION =
        0x83da5a14a875cd105129c6639940ca67c63bf644cb010f348eec1dbad1a679be; // keccak256('cygnus.StToken.totalShares')

    event TransferShares(
        address indexed from,
        address indexed to,
        uint256 sharesValue
    );

    event SharesBurnt(
        address indexed account,
        uint256 preRebaseTokenAmount,
        uint256 postRebaseTokenAmount,
        uint256 sharesAmount
    );

    function name() external pure returns (string memory) {
        return "Cygnus Global USD";
    }

    function symbol() external pure returns (string memory) {
        return "cgUSD";
    }

    function decimals() external view virtual returns (uint8);

    function totalSupply() external view returns (uint256) {
        return _getTotalPooledAssets();
    }

    function getTotalPooledAssets() external view returns (uint256) {
        return _getTotalPooledAssets();
    }

    function balanceOf(address _account) external view returns (uint256) {
        return convertToAssets(_sharesOf(_account));
    }

    function transfer(address _recipient, uint256 _amount) external returns (bool) {
        _transfer(msg.sender, _recipient, _amount);
        return true;
    }

    function allowance(address _owner, address _spender) external view returns (uint256) {
        return allowances[_owner][_spender];
    }

    function approve(address _spender, uint256 _amount) external returns (bool) {
        _approve(msg.sender, _spender, _amount);
        return true;
    }

    function transferFrom(address _sender, address _recipient, uint256 _amount) external returns (bool) {
        _spendAllowance(_sender, msg.sender, _amount);
        _transfer(_sender, _recipient, _amount);
        return true;
    }

    function increaseAllowance(address _spender, uint256 _addedValue) external returns (bool) {
        _approve(msg.sender, _spender, allowances[msg.sender][_spender] + _addedValue);
        return true;
    }

    function decreaseAllowance(address _spender, uint256 _subtractedValue) external returns (bool) {
        uint256 currentAllowance = allowances[msg.sender][_spender];
        require(currentAllowance >= _subtractedValue, "ALLOWANCE_BELOW_ZERO");
        _approve(msg.sender, _spender, currentAllowance - _subtractedValue);
        return true;
    }

    function getTotalShares() external view returns (uint256) {
        return _getTotalShares();
    }

    function sharesOf(address _account) external view returns (uint256) {
        return _sharesOf(_account);
    }

    function transferShares(address _recipient, uint256 _sharesAmount) external returns (uint256) {
        _transferShares(msg.sender, _recipient, _sharesAmount);
        uint256 tokensAmount = convertToAssets(_sharesAmount);
        _emitTransferEvents(msg.sender, _recipient, tokensAmount, _sharesAmount);
        return tokensAmount;
    }

    function transferSharesFrom(
        address _sender, address _recipient, uint256 _sharesAmount
    ) external returns (uint256) {
        uint256 tokensAmount = convertToAssets(_sharesAmount);
        _spendAllowance(_sender, msg.sender, tokensAmount);
        _transferShares(_sender, _recipient, _sharesAmount);
        _emitTransferEvents(_sender, _recipient, tokensAmount, _sharesAmount);
        return tokensAmount;
    }

    function _getTotalPooledAssets() internal view virtual returns (uint256);

    function _transfer(address _sender, address _recipient, uint256 _amount) internal {
        uint256 _sharesToTransfer = convertToShares(_amount);
        _transferShares(_sender, _recipient, _sharesToTransfer);
        _emitTransferEvents(_sender, _recipient, _amount, _sharesToTransfer);
    }

    function _approve(address _owner, address _spender, uint256 _amount) internal {
        require(_owner != address(0), "APPROVE_FROM_ZERO_ADDR");
        require(_spender != address(0), "APPROVE_TO_ZERO_ADDR");

        allowances[_owner][_spender] = _amount;
        emit Approval(_owner, _spender, _amount);
    }

    function _spendAllowance(address _owner, address _spender, uint256 _amount) internal {
        uint256 currentAllowance = allowances[_owner][_spender];
        if (currentAllowance != INFINITE_ALLOWANCE) {
            require(currentAllowance >= _amount, "ALLOWANCE_EXCEEDED");
            _approve(_owner, _spender, currentAllowance - _amount);
        }
    }

    function _getTotalShares() internal view returns (uint256) {
        return TOTAL_SHARES_POSITION.getStorageUint256();
    }

    function _sharesOf(address _account) internal view returns (uint256) {
        return shares[_account];
    }

    function _transferShares(address _sender, address _recipient, uint256 _sharesAmount) internal {
        _requireNotPaused();
        require(_sender != address(0), "TRANSFER_FROM_ZERO_ADDR");
        require(_recipient != address(0), "TRANSFER_TO_ZERO_ADDR");
        require(_recipient != address(this), "TRANSFER_TO_STETH_CONTRACT");

        uint256 currentSenderShares = shares[_sender];
        require(_sharesAmount <= currentSenderShares, "BALANCE_EXCEEDED");

        shares[_sender] = currentSenderShares - _sharesAmount;
        shares[_recipient] = shares[_recipient] + _sharesAmount;
    }

    function _mintShares(address _recipient, uint256 _sharesAmount) internal returns (uint256 newTotalShares) {
        require(_recipient != address(0), "MINT_TO_ZERO_ADDR");

        newTotalShares = _getTotalShares() + _sharesAmount;
        TOTAL_SHARES_POSITION.setStorageUint256(newTotalShares);

        shares[_recipient] = shares[_recipient] + _sharesAmount;
    }

    function _burnShares(address _account, uint256 _sharesAmount) internal returns (uint256 newTotalShares) {
        require(_account != address(0), "BURN_FROM_ZERO_ADDR");

        uint256 accountShares = shares[_account];
        require(_sharesAmount <= accountShares, "BALANCE_EXCEEDED");

        uint256 preRebaseTokenAmount = convertToAssets(_sharesAmount);

        newTotalShares = _getTotalShares() - _sharesAmount;
        TOTAL_SHARES_POSITION.setStorageUint256(newTotalShares);

        shares[_account] = accountShares - _sharesAmount;

        uint256 postRebaseTokenAmount = convertToAssets(_sharesAmount);

        emit SharesBurnt(_account, preRebaseTokenAmount, postRebaseTokenAmount, _sharesAmount);
    }

    function convertToShares(uint256 _assetsAmount) public view virtual returns (uint256) {
        return _assetsAmount.mulDivDown(_getTotalShares(), _getTotalPooledAssets());
    }

    function convertToAssets(uint256 _sharesAmount) public view virtual returns (uint256) {
        return _sharesAmount.mulDivDown(_getTotalPooledAssets(), _getTotalShares());
    }

    function _emitTransferEvents(address _from, address _to, uint _tokenAmount, uint256 _sharesAmount) internal {
        emit Transfer(_from, _to, _tokenAmount);
        emit TransferShares(_from, _to, _sharesAmount);
    }

    function _emitTransferAfterMintingShares(address _to, uint256 _sharesAmount) internal {
        _emitTransferEvents(address(0), _to, convertToAssets(_sharesAmount), _sharesAmount);
    }

    function _mintInitialShares(uint256 _sharesAmount) internal {
        _mintShares(INITIAL_TOKEN_HOLDER, _sharesAmount);
        _emitTransferAfterMintingShares(INITIAL_TOKEN_HOLDER, _sharesAmount);
    }

    function previewDeposit(uint256 _assetsAmount) public view virtual returns (uint256) {
        return convertToShares(_assetsAmount);
    }

    function previewMint(uint256 _sharesAmount) public view virtual returns (uint256) {
        return _sharesAmount.mulDivUp(_getTotalPooledAssets(), _getTotalShares());
    }

    function previewWithdraw(uint256 _assetsAmount) public view virtual returns (uint256) {
        return _assetsAmount.mulDivUp(_getTotalShares(), _getTotalPooledAssets());
    }

    function previewRedeem(uint256 _sharesAmount) public view virtual returns (uint256) {
        return convertToAssets(_sharesAmount);
    }
}