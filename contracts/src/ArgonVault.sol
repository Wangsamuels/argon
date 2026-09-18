// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "./utils/Ownable.sol";
import {Pausable} from "./utils/Pausable.sol";
import {ReentrancyGuard} from "./utils/ReentrancyGuard.sol";
import {SafeTransfer} from "./utils/SafeTransfer.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {IWETH} from "./interfaces/IWETH.sol";
import {IInferenceRegistry} from "./interfaces/IInferenceRegistry.sol";
import {IPoolAdapter} from "./interfaces/IPoolAdapter.sol";
import {IEthUsdOracle} from "./interfaces/IEthUsdOracle.sol";
import {DualHorizonGate} from "./libraries/DualHorizonGate.sol";

/// @notice Shared LP vault. Same bytecode on Arbitrum (WETH/USDC) and Robinhood (WETH/USDG).
contract ArgonVault is Ownable, Pausable, ReentrancyGuard {
    using SafeTransfer for address;

    enum Action {
        HOLD,
        ENTER,
        EXIT
    }

    struct Pool {
        IPoolAdapter adapter;
        bool gated; // ETH dual-horizon gate (pools 1 and 4)
        bool exists;
        uint64 lastExitHourId;
        uint64 lastRebalanceHourId;
    }

    IInferenceRegistry public registry;
    IEthUsdOracle public oracle;
    address public keeper;
    address public immutable weth;
    address public immutable stable;
    uint8 public immutable stableDecimals;

    uint16 public gate1hBps = 100;
    uint16 public gate2hBps = 250;
    uint16 public gate8hBps = 200;
    uint64 public constant ENTER_COOLDOWN_HOURS = 2;

    uint256 public totalShares;
    mapping(address => uint256) public shareBalance;
    mapping(uint8 => Pool) public pools;

    error NotKeeper();
    error InvalidToken();
    error ZeroAmount();
    error ZeroShares();
    error InsufficientShares();
    error UnknownPool();
    error PoolNotGated();
    error Warmup();
    error StaleHour();
    error ActionMismatch(uint8 allowed, uint8 got);
    error Cooldown();
    error AlreadyRebalanced();
    error PoolConfigured();

    event KeeperSet(address indexed keeper);
    event RegistrySet(address indexed registry);
    event OracleSet(address indexed oracle);
    event GatesSet(uint16 gate1hBps, uint16 gate2hBps, uint16 gate8hBps);
    event PoolSet(uint8 indexed poolId, address adapter, bool gated);
    event Deposited(address indexed user, address indexed token, uint256 amount, uint256 shares);
    event Withdrawn(address indexed user, address indexed token, uint256 amount, uint256 shares);
    event Rebalanced(uint64 indexed hourId, uint8 indexed poolId, Action action, bytes32 forecastHash);

    modifier onlyKeeper() {
        if (msg.sender != keeper) revert NotKeeper();
        _;
    }

    constructor(
        address initialOwner,
        address keeper_,
        address registry_,
        address oracle_,
        address weth_,
        address stable_,
        uint8 stableDecimals_
    ) Ownable(initialOwner) {
        if (
            keeper_ == address(0) || registry_ == address(0) || oracle_ == address(0) || weth_ == address(0)
                || stable_ == address(0)
        ) {
            revert ZeroAddress();
        }
        keeper = keeper_;
        registry = IInferenceRegistry(registry_);
        oracle = IEthUsdOracle(oracle_);
        weth = weth_;
        stable = stable_;
        stableDecimals = stableDecimals_;
        emit KeeperSet(keeper_);
        emit RegistrySet(registry_);
        emit OracleSet(oracle_);
    }

    function setKeeper(address keeper_) external onlyOwner {
        if (keeper_ == address(0)) revert ZeroAddress();
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    function setRegistry(address registry_) external onlyOwner {
        if (registry_ == address(0)) revert ZeroAddress();
        registry = IInferenceRegistry(registry_);
        emit RegistrySet(registry_);
    }

    function setOracle(address oracle_) external onlyOwner {
        oracle = IEthUsdOracle(oracle_);
        emit OracleSet(oracle_);
    }

    function setGates(uint16 g1, uint16 g2, uint16 g8) external onlyOwner {
        gate1hBps = g1;
        gate2hBps = g2;
        gate8hBps = g8;
        emit GatesSet(g1, g2, g8);
    }

    function setPaused(bool v) external onlyOwner {
        _setPaused(v);
    }

    function setPool(uint8 poolId, address adapter, bool gated) external onlyOwner {
        if (adapter == address(0)) revert ZeroAddress();
        if (pools[poolId].exists) revert PoolConfigured();
        pools[poolId] = Pool({
            adapter: IPoolAdapter(adapter),
            gated: gated,
            exists: true,
            lastExitHourId: 0,
            lastRebalanceHourId: 0
        });
        address a = IPoolAdapter(adapter).tokenA();
        address b = IPoolAdapter(adapter).tokenB();
        a.approve(adapter, type(uint256).max);
        b.approve(adapter, type(uint256).max);
        emit PoolSet(poolId, adapter, gated);
    }

    function warmupComplete() public view returns (bool) {
        return registry.forecastCount() >= 9;
    }

    function poolStatus(uint8 poolId) external view returns (uint8) {
        Pool storage p = pools[poolId];
        if (!p.exists) revert UnknownPool();
        return p.adapter.inPosition() ? 1 : 0;
    }

    function idleBalance(address user, address token) external view returns (uint256) {
        uint256 supply = totalShares;
        if (supply == 0) return 0;
        return (IERC20(token).balanceOf(address(this)) * shareBalance[user]) / supply;
    }

    function depositETH() external payable whenNotPaused nonReentrant {
        if (msg.value == 0) revert ZeroAmount();
        IWETH(weth).deposit{value: msg.value}();
        _deposit(msg.sender, weth, msg.value);
    }

    function deposit(address token, uint256 amount) external whenNotPaused nonReentrant {
        if (token != weth && token != stable) revert InvalidToken();
        if (amount == 0) revert ZeroAmount();
        token.pull(msg.sender, amount);
        _deposit(msg.sender, token, amount);
    }

    function _deposit(address user, address token, uint256 amount) internal {
        uint256 usd8 = _usd8(token, amount);
        uint256 shares;
        uint256 supply = totalShares;
        if (supply == 0) {
            shares = usd8 * 1e10;
        } else {
            uint256 assets = _totalAssetsUsd8();
            // Pull already landed; price shares against the prior vault.
            if (assets > usd8) assets -= usd8;
            else assets = 0;
            if (assets == 0) shares = usd8 * 1e10;
            else shares = (usd8 * supply) / assets;
        }
        if (shares == 0) revert ZeroShares();
        shareBalance[user] += shares;
        totalShares += shares;
        emit Deposited(user, token, amount, shares);
    }

    /// @notice Burns `shares` and pays pro-rata WETH + stable. Flattens LP first if needed.
    function withdraw(uint256 shares) external nonReentrant {
        _withdraw(msg.sender, shares, false);
    }

    /// @notice Idle-or-flatten withdraw; allowed while keeper is paused.
    function emergencyWithdraw() external nonReentrant {
        uint256 shares = shareBalance[msg.sender];
        if (shares == 0) revert ZeroShares();
        _withdraw(msg.sender, shares, true);
    }

    function _withdraw(address user, uint256 shares, bool /* emergency */ ) internal {
        if (shares == 0) revert ZeroAmount();
        if (shareBalance[user] < shares) revert InsufficientShares();

        _flattenAll();

        uint256 supply = totalShares;
        uint256 wethBal = IERC20(weth).balanceOf(address(this));
        uint256 stableBal = IERC20(stable).balanceOf(address(this));
        uint256 wethOut = (wethBal * shares) / supply;
        uint256 stableOut = (stableBal * shares) / supply;

        shareBalance[user] -= shares;
        totalShares -= shares;

        if (wethOut != 0) weth.push(user, wethOut);
        if (stableOut != 0) stable.push(user, stableOut);
        emit Withdrawn(user, weth, wethOut, shares);
        emit Withdrawn(user, stable, stableOut, shares);
    }

    function rebalance(
        uint64 hourId,
        uint8 poolId,
        Action action,
        int24 tickLower,
        int24 tickUpper,
        uint256 amountAMin,
        uint256 amountBMin
    ) external onlyKeeper whenNotPaused nonReentrant {
        Pool storage p = pools[poolId];
        if (!p.exists) revert UnknownPool();
        if (!p.gated) revert PoolNotGated();
        if (p.lastRebalanceHourId == hourId) revert AlreadyRebalanced();
        if (hourId != registry.latestHourId()) revert StaleHour();

        IInferenceRegistry.Forecast memory f = registry.getForecast(hourId);
        bool inPool = p.adapter.inPosition();
        uint8 allowed =
            DualHorizonGate.allowedAction(f.pct1hBps, f.pct2hBps, f.pct8hBps, gate1hBps, gate2hBps, gate8hBps, inPool);

        if (action == Action.HOLD && allowed == DualHorizonGate.ENTER) {
            // keeper may skip a mint
        } else if (uint8(action) != allowed) {
            revert ActionMismatch(allowed, uint8(action));
        }

        if (action != Action.HOLD && !warmupComplete()) revert Warmup();

        if (action == Action.ENTER) {
            if (p.lastExitHourId != 0 && hourId < p.lastExitHourId + ENTER_COOLDOWN_HOURS) revert Cooldown();
            oracle.assertHealthy();
            p.adapter.enter(tickLower, tickUpper, amountAMin, amountBMin);
        } else if (action == Action.EXIT) {
            if (inPool) {
                p.adapter.exit(amountAMin, amountBMin);
                p.lastExitHourId = hourId;
            }
        } else {
            if (inPool) p.adapter.harvest();
        }

        p.lastRebalanceHourId = hourId;
        emit Rebalanced(hourId, poolId, action, f.forecastHash);
    }

    function _flattenAll() internal {
        // Iterate known ETH-gated pool ids used in v1: 1 (Arb) and 4 (Robinhood).
        _flatten(1);
        _flatten(4);
    }

    function _flatten(uint8 poolId) internal {
        Pool storage p = pools[poolId];
        if (p.exists && p.adapter.inPosition()) {
            p.adapter.exit(0, 0);
        }
    }

    function _totalAssetsUsd8() internal view returns (uint256) {
        uint256 usd = _usd8(weth, IERC20(weth).balanceOf(address(this)));
        usd += _usd8(stable, IERC20(stable).balanceOf(address(this)));
        usd += _adapterUsd8(1);
        usd += _adapterUsd8(4);
        return usd;
    }

    function _adapterUsd8(uint8 poolId) internal view returns (uint256) {
        Pool storage p = pools[poolId];
        if (!p.exists || !p.adapter.inPosition()) return 0;
        (uint256 a, uint256 b) = p.adapter.amounts();
        return _usd8(p.adapter.tokenA(), a) + _usd8(p.adapter.tokenB(), b);
    }

    function _usd8(address token, uint256 amount) internal view returns (uint256) {
        if (amount == 0) return 0;
        if (token == weth) {
            return (amount * oracle.ethUsd8()) / 1e18;
        }
        if (token == stable) {
            return (amount * 1e8) / (10 ** uint256(stableDecimals));
        }
        return 0;
    }

    receive() external payable {}
}
