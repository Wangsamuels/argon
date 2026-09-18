// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolAdapter} from "../interfaces/IPoolAdapter.sol";
import {INonfungiblePositionManager} from "../interfaces/INonfungiblePositionManager.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {SafeTransfer} from "../utils/SafeTransfer.sol";

/// @notice One adapter per Uniswap v3 pool. Vault is the only caller.
contract UniswapV3Adapter is IPoolAdapter {
    using SafeTransfer for address;

    address public immutable vault;
    address public immutable tokenA;
    address public immutable tokenB;
    uint24 public immutable fee;
    INonfungiblePositionManager public immutable npm;

    uint256 public positionId;
    uint256 public principalA;
    uint256 public principalB;

    error NotVault();
    error NotIn();
    error BadTicks();

    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault();
        _;
    }

    constructor(address vault_, address npm_, address tokenA_, address tokenB_, uint24 fee_) {
        vault = vault_;
        npm = INonfungiblePositionManager(npm_);
        tokenA = tokenA_;
        tokenB = tokenB_;
        fee = fee_;
        tokenA_.approve(npm_, type(uint256).max);
        tokenB_.approve(npm_, type(uint256).max);
    }

    function inPosition() public view returns (bool) {
        return positionId != 0;
    }

    function amounts() external view returns (uint256, uint256) {
        return (principalA, principalB);
    }

    function enter(int24 tickLower, int24 tickUpper, uint256 amountAMin, uint256 amountBMin) external onlyVault {
        if (tickLower >= tickUpper) revert BadTicks();
        tokenA.pull(vault, IERC20(tokenA).balanceOf(vault));
        tokenB.pull(vault, IERC20(tokenB).balanceOf(vault));
        uint256 balA = IERC20(tokenA).balanceOf(address(this));
        uint256 balB = IERC20(tokenB).balanceOf(address(this));
        if (positionId == 0) {
            positionId = _mint(tickLower, tickUpper, balA, balB, amountAMin, amountBMin);
        } else {
            _increase(balA, balB, amountAMin, amountBMin);
        }
        _returnDust();
        principalA = balA - IERC20(tokenA).balanceOf(address(this));
        principalB = balB - IERC20(tokenB).balanceOf(address(this));
    }

    function _mint(int24 tickLower, int24 tickUpper, uint256 balA, uint256 balB, uint256 minA, uint256 minB)
        internal
        returns (uint256 id)
    {
        (address token0, address token1, uint256 amount0, uint256 amount1, uint256 min0, uint256 min1) =
            _sort(balA, balB, minA, minB);
        (id,,,) = npm.mint(
            INonfungiblePositionManager.MintParams({
                token0: token0,
                token1: token1,
                fee: fee,
                tickLower: tickLower,
                tickUpper: tickUpper,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: min0,
                amount1Min: min1,
                recipient: address(this),
                deadline: block.timestamp
            })
        );
    }

    function _increase(uint256 balA, uint256 balB, uint256 minA, uint256 minB) internal {
        (,, uint256 amount0, uint256 amount1, uint256 min0, uint256 min1) = _sort(balA, balB, minA, minB);
        npm.increaseLiquidity(
            INonfungiblePositionManager.IncreaseLiquidityParams({
                tokenId: positionId,
                amount0Desired: amount0,
                amount1Desired: amount1,
                amount0Min: min0,
                amount1Min: min1,
                deadline: block.timestamp
            })
        );
    }

    function exit(uint256 amountAMin, uint256 amountBMin) external onlyVault {
        if (positionId == 0) revert NotIn();
        (,,,,,,, uint128 liquidity,,,,) = npm.positions(positionId);
        if (liquidity != 0) {
            (uint256 min0, uint256 min1) = _mins(amountAMin, amountBMin);
            npm.decreaseLiquidity(
                INonfungiblePositionManager.DecreaseLiquidityParams({
                    tokenId: positionId,
                    liquidity: liquidity,
                    amount0Min: min0,
                    amount1Min: min1,
                    deadline: block.timestamp
                })
            );
        }
        npm.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: positionId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        npm.burn(positionId);
        positionId = 0;
        principalA = 0;
        principalB = 0;
        _pushAll(vault);
    }

    function harvest() external onlyVault {
        if (positionId == 0) revert NotIn();
        npm.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: positionId,
                recipient: vault,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
    }

    function _sort(uint256 balA, uint256 balB, uint256 minA, uint256 minB)
        internal
        view
        returns (address token0, address token1, uint256 amount0, uint256 amount1, uint256 min0, uint256 min1)
    {
        if (tokenA < tokenB) {
            return (tokenA, tokenB, balA, balB, minA, minB);
        }
        return (tokenB, tokenA, balB, balA, minB, minA);
    }

    function _mins(uint256 minA, uint256 minB) internal view returns (uint256 min0, uint256 min1) {
        if (tokenA < tokenB) return (minA, minB);
        return (minB, minA);
    }

    function _returnDust() internal {
        uint256 a = IERC20(tokenA).balanceOf(address(this));
        uint256 b = IERC20(tokenB).balanceOf(address(this));
        if (a != 0) tokenA.push(vault, a);
        if (b != 0) tokenB.push(vault, b);
    }

    function _pushAll(address to) internal {
        uint256 a = IERC20(tokenA).balanceOf(address(this));
        uint256 b = IERC20(tokenB).balanceOf(address(this));
        if (a != 0) tokenA.push(to, a);
        if (b != 0) tokenB.push(to, b);
    }
}
