// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDeltaLibrary, BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {console} from "forge-std/console.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {Context} from "@openzeppelin/contracts/utils/Context.sol";

/*
    Plan for Arbitrary Hook Integration with Uniswap Pool:

    1. **Deposit Mechanism**:
       - Allow deposits of either token in the pool.
       - As a counter-party token enters, it is matched with excess from the other side.
       - Utilize the LP (Liquidity Provider) paradigm as the deposit mechanism.
       - Facilitate deposits through LP deposits. If no counter-party exists, the Hook will `take` from the PoolManager until a match is found.

    2. **Integration Requirements**:
       - A unique identifier (sender + salt) is will identify the delta LP position.

    3. **Surety Protocol (Bonds) Integration**:
       - A separate contract will manage the unlocking of SRF tokens and bond the stablecoin, holding the receipt for managing the modifyLiquidity of the Bond.
       - Bond Management will be handled by the default Router.
       - The CoPool Hook is a separate concern. Bond Management can actually integrate with UniswapV4’s default `PositionManager.sol` router.
       - When a user deposits their SRF, it pools against any bond deposited as a single stake.
       - Bonds deposited are held by the BondManager (Unlocker) Contract, allowing it to remove Bond for swap and SRF burn.

    4. **Automated JIT Rebalancing**:
       - The Hook will facilitate the injection of capital it holds during a Swap, enabling automated Just-In-Time (JIT) rebalancing.
       - hookData will be used to determine the purpose of the liquidity addition.
       - If the purpose is automated, the hook will JIT rebalance the delta.
*/

contract CoPoolHook is BaseHook, Context {
    // Use CurrencyLibrary and BalanceDeltaLibrary
    // to add some helper functions over the Currency and BalanceDelta
    // data types
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    // poolManager exists from BaseHook

    // liquidity actions
    bytes public constant COPOOL = hex"00";

    Currency private token0;
    Currency private token1;

    int256 public deltaOfToken0;
    int256 public deltaOfToken1;

    mapping(bytes => int128) public token0DeltaFor;
    mapping(bytes => int128) public token1DeltaFor;

    mapping(address => uint256) public token0BalanceOf;
    mapping(address => uint256) public token1BalanceOf;

    error OnlyByPoolManager();
    error InvalidTokenSelection();

    // Initialize BaseHook and ERC20
    constructor(IPoolManager _manager) BaseHook(_manager) {}

    // Set up hook permissions to return `true`
    // for the two hook functions we are using
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: true,
            afterRemoveLiquidity: true,
            beforeSwap: false,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: true,
            afterRemoveLiquidityReturnDelta: true
        });
    }

    /// @notice The hook called after the state of a pool is initialized
    /// -param sender The initial msg.sender for the initialize call
    /// @param key The key for the pool being initialized
    /// -param sqrtPriceX96 The sqrt(price) of the pool as a Q64.96
    /// -param tick The current tick after the state of a pool is initialized
    /// @return bytes4 The function selector for the hook
    function afterInitialize(address, PoolKey calldata key, uint160, int24)
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        token0 = key.currency0;
        token1 = key.currency1;

        return this.afterInitialize.selector;
    }

    // We still require a direct deposit mechanism.
    // This way there is a counter-party token to match with the LP modifyPosition.
    function deposit(uint256 amount, bool isZero) external {
        address sender = _msgSender();
        IERC20Minimal(Currency.unwrap(isZero ? token0 : token1)).transferFrom(sender, address(this), amount);
        if (isZero) {
            token0BalanceOf[sender] += amount;
            deltaOfToken0 -= int256(amount);
        } else {
            token1BalanceOf[sender] += amount;
            deltaOfToken1 -= int256(amount);
        }
    }

    // Withdraw the bond currency from the contract
    function withdraw(uint256 amount, bool isZero) external {
        address sender = _msgSender();
        int256 amountInt = int256(amount);
        if (isZero) {
            require(token0BalanceOf[sender] >= amount, "Insufficient balance for token0");
            // How much of token0 is in the CoPool?
            if (amountInt + deltaOfToken0 > 0) {
                // There is not enough liquid token0 to satisfy the withdrawal
                // TODO: How do we handle this?
                // Burn the co-pools to satisfy the withdrawal.
                require(amountInt + deltaOfToken0 <= 0, "Insufficient liquidity in CoPool");
            }

            token0.transfer(sender, amount);
            token0BalanceOf[sender] -= amount;
            deltaOfToken0 += amountInt;
        } else {
            require(token1BalanceOf[sender] >= amount, "Insufficient balance for token1");
            if (amountInt + deltaOfToken1 > 0) {
                // There is not enough liquid token1 to satisfy the withdrawal
                // TODO: How do we handle this?
                require(amountInt + deltaOfToken1 <= 0, "Insufficient liquidity in CoPool");
            }

            token1.transfer(sender, amount);
            token1BalanceOf[sender] -= amount;
            deltaOfToken1 += amountInt;
        }
    }

    /// @notice The hook called after liquidity is added
    /// @param sender The initial msg.sender for the add liquidity call
    /// -param key The key for the pool
    /// @param params The parameters for adding liquidity
    /// @param delta The caller's balance delta after adding liquidity; the sum of principal delta, fees accrued, and hook delta
    /// -param feesAccrued The fees accrued since the last time fees were collected from this position
    /// @param hookData Arbitrary data handed into the PoolManager by the liquidity provider to be passed on to the hook
    /// @return bytes4 The function selector for the hook
    /// @return BalanceDelta The hook's delta in token0 and token1. Positive: the hook is owed/took currency, negative: the hook owes/sent currency
    function afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, BalanceDelta) {
        // Check hookData for instruction to use bond currency
        if (hookData.length == 0) {
            return (this.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
        }

        // Decode the hookData
        (bytes memory identifier, uint8 tokenSelection) = abi.decode(hookData, (bytes, uint8));

        // If so, re-balance the delta
        if (identifier.length == COPOOL.length && keccak256(identifier) == keccak256(COPOOL)) {
            // Extract the token selection for single stake from hookData. The value should be 0 or 1.
            if (tokenSelection != 0 && tokenSelection != 1) {
                revert InvalidTokenSelection();
            }

            // Now we check if the Hook has pending counterparty tokens to match with the selected token deposit.
            // If not, we take from the PoolManager until a match is found.
            // If there are pending counterparty tokens, we match the deposit with the counterparty tokens.

            // ? For a deposit, the caller delta will be negative indicating that the caller is in a deficit relative to the pool
            int128 amount0 = delta.amount0();
            int128 amount1 = delta.amount1();

            // Manage ownership - ie. Who is creating the CoPool position?
            // ! If the Router does not specify a salt that identifies the position, then the hook assumes the router manages the position.
            // ie. On withdrawal, the hook uses the salt in callerId to determine deficits relative to the LP position.
            bytes memory callerId = abi.encodePacked(sender, params.salt);

            BalanceDelta hookDelta;

            if (tokenSelection == 0) {
                // Here, we're now matching what token1 is available since token0 is being deposited.

                // The more negative the deltaOfToken0, the more deficit the callers are to the hook. Therefore, the hook has more token than amount1
                int128 newDelta1;
                if (deltaOfToken1 <= amount1) {
                    // We can match the deposit
                    // Settle the amount0 from the hook to the poolManager
                    deltaOfToken1 -= amount1; // negative minus negative is positive
                    // ^ We're removing the delta of the amount1 from the hook's token1 delta - as it's being matched.

                    newDelta1 = amount1;
                } else {
                    // match amount is what is whatever is available.
                    newDelta1 = int128(deltaOfToken1);
                    deltaOfToken1 = 0;
                }
                // We add the amount1 to caller's delta. This way we know how much the caller position is made of the Hook's funds
                // ie. the deficit relative to the Hook
                token1DeltaFor[callerId] += newDelta1;

                if (newDelta1 < 0) {
                    _settle(key.currency1, SignedMath.abs(newDelta1));
                }
                hookDelta = toBalanceDelta(0, newDelta1);
            } else {
                // Else tokenSelection = 1

                int128 newDelta0;
                if (deltaOfToken0 <= amount0) {
                    // We can match the deposit
                    // Settle the amount0 from the hook to the poolManager
                    deltaOfToken0 -= amount0; // negative minus negative is positive
                    newDelta0 = amount0;
                } else {
                    // match amount is what is whatever is available.
                    // ! This could break in an edge case because of varying data types.
                    newDelta0 = int128(deltaOfToken0);
                    deltaOfToken0 = 0;
                }
                // We add the amount0 to caller's delta. This way we know how much the caller is in a deficit relative to the Hook - ie. how much of the LP is theirs.
                token0DeltaFor[callerId] += newDelta0;

                if (newDelta0 < 0) {
                    _settle(key.currency0, SignedMath.abs(newDelta0));
                }
                hookDelta = toBalanceDelta(newDelta0, 0);
            }

            // eg. Hook delta is negative as the hook is now in a deficit position relative to the pool.
            // ----- This will actually balance out the caller delta.
            return (this.afterAddLiquidity.selector, hookDelta);
        }

        return (this.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    /// @notice The hook called after liquidity is removed
    /// @param sender The initial msg.sender for the remove liquidity call
    /// @param key The key for the pool
    /// @param params The parameters for removing liquidity
    /// @param delta The caller's balance delta after removing liquidity; the sum of principal delta, fees accrued, and hook delta
    /// -param feesAccrued The fees accrued since the last time fees were collected from this position
    /// @param hookData Arbitrary data handed into the PoolManager by the liquidity provider to be be passed on to the hook
    /// @return bytes4 The function selector for the hook
    /// @return BalanceDelta The hook's delta in token0 and token1. Positive: the hook is owed/took currency, negative: the hook owes/sent currency
    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, BalanceDelta) {
        // Check hookData for instruction to use bond currency
        if (hookData.length == 0) {
            return (this.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
        }

        // Decode the hookData
        (bytes memory identifier, uint8 tokenSelection) = abi.decode(hookData, (bytes, uint8));

        // If so, re-balance the delta
        if (identifier.length == COPOOL.length && keccak256(identifier) == keccak256(COPOOL)) {
            // Extract the token selection for single stake from hookData. The value should be 0 or 1.
            if (tokenSelection != 0 && tokenSelection != 1) {
                revert InvalidTokenSelection();
            }

            // ? For a withdraw, the caller delta will be positive indicating that the caller is expecting funds from the pool
            int128 amount0 = delta.amount0();
            int128 amount1 = delta.amount1();

            // Identify the caller's position
            bytes memory callerId = abi.encodePacked(sender, params.salt);

            BalanceDelta hookDelta;

            if (tokenSelection == 0) {
                // Here, we're now determining how much of the counter-party asset (token1) in the co-pool is taken back by the Hook.

                int128 newDelta1 = removeCoPool(amount1, true, callerId);
                // Hook is accepting back what was originally in a deficit.
                // A positive delta means the hook is owed the asset.
                if (newDelta1 > 0) {
                    _take(key.currency1, SignedMath.abs(newDelta1));
                }
                hookDelta = toBalanceDelta(0, newDelta1);
            } else {
                // Else tokenSelection = 1

                int128 newDelta0 = removeCoPool(amount0, false, callerId);
                // Hook is accepting back what was originally in a deficit.
                // A positive delta means the hook is owed the asset.
                if (newDelta0 > 0) {
                    _take(key.currency0, SignedMath.abs(newDelta0));
                }
                hookDelta = toBalanceDelta(newDelta0, 0);
            }

            // eg. Hook delta is positive as the hooks is in arrears relative to the manager. The Hook owes the manager.
            return (this.afterRemoveLiquidity.selector, hookDelta);
        }

        return (this.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function removeCoPool(int128 amount, bool forZeroTokenSelection, bytes memory callerId)
        internal
        returns (int128 delta)
    {
        if (forZeroTokenSelection) {
            int128 token1Diff = amount + token1DeltaFor[callerId];
            if (token1Diff >= 0) {
                // The caller is withdrawing more than their deficit - ie. +1000 (withdraw 1000) + -500 (deficit of 500) = +500
                // The entire deficit is settled
                delta = -token1DeltaFor[callerId];
                token1DeltaFor[callerId] = 0;
                deltaOfToken1 -= delta; // We add what's taken by the the hook to the total delta of token1
            } else {
                // The caller is withdrawing less than their deficit
                // - ie. +200 (withdraw 200) + -500 (deficit of 500) = -300
                delta = amount; // amount1 is positive for withdraw
                token1DeltaFor[callerId] = token1Diff; // The new caller delta is the difference between what was taken and what was in a deficit
                deltaOfToken1 -= delta; // We add what's taken by the the hook to the total delta of token1
            }
        } else {
            int128 token0Diff = amount + token0DeltaFor[callerId];
            if (token0Diff >= 0) {
                // The caller is withdrawing more than their deficit - ie. +1000 (withdraw 1000) + -500 (deficit of 500) = +500
                // The entire deficit is settled
                delta = -token0DeltaFor[callerId];
                token0DeltaFor[callerId] = 0;
                deltaOfToken0 -= delta; // We add what's taken by the the hook to the total delta of token0
            } else {
                // The caller is withdrawing less than their deficit
                // - ie. +200 (withdraw 200) + -500 (deficit of 500) = -300
                delta = amount; // amount0 is positive for withdraw
                token0DeltaFor[callerId] = token0Diff; // The new caller delta is the difference between what was taken and what was in a deficit
                deltaOfToken0 -= delta; // We add what's taken by the the hook to the total delta of token0
            }
        }
    }

    // Adopted from: https://github.com/Uniswap/v4-core/blob/182712cf7146f31cd5c969749bbe3a188f030d1a/test/utils/CurrencySettler.sol#L19
    /// @notice Settle (pay) a currency to the PoolManager
    /// @param currency Currency to settle
    /// @param amount Amount to send
    function _settle(Currency currency, uint256 amount) internal {
        // for native currencies or burns, calling sync is not required
        if (currency.isAddressZero()) {
            poolManager.settle{value: amount}();
        } else {
            poolManager.sync(currency);
            IERC20Minimal(Currency.unwrap(currency)).transfer(address(poolManager), amount);
            poolManager.settle();
        }
    }

    // Adopted from: https://github.com/Uniswap/v4-core/blob/182712cf7146f31cd5c969749bbe3a188f030d1a/test/utils/CurrencySettler.sol#L19
    /// @notice Take (receive) a currency from the PoolManager
    /// @param currency Currency to take
    /// @param amount Amount to receive
    function _take(Currency currency, uint256 amount) internal {
        poolManager.take(currency, address(this), amount);
    }
}
