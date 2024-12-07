// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDeltaLibrary, BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {console} from "forge-std/console.sol";
import {SignedMath} from "@openzeppelin/contracts/utils/math/SignedMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {LiquidityAmounts} from "./libraries/LiquidityAmounts.sol";

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

contract CoPoolHook is BaseHook {
    // Use CurrencyLibrary and BalanceDeltaLibrary
    // to add some helper functions over the Currency and BalanceDelta
    // data types
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    // poolManager exists from BaseHook

    // liquidity actions
    bytes public constant COPOOL = hex"00";

    int256 public deltaOfToken0;
    int256 public deltaOfToken1;

    mapping(bytes => int256) public token0DeltaFor;
    mapping(bytes => int256) public token1DeltaFor;

    error OnlyByPoolManager();

    // Initialize BaseHook and ERC20
    constructor(IPoolManager _manager) BaseHook(_manager) {}

    // Set up hook permissions to return `true`
    // for the two hook functions we are using
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: true,
            afterRemoveLiquidityReturnDelta: false
        });
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
            require(tokenSelection == 0 || tokenSelection == 1, "Invalid token selection");

            // Now we check if the Hook has pending counterparty tokens to match with the selected token deposit.
            // If not, we take from the PoolManager until a match is found.
            // If there are pending counterparty tokens, we match the deposit with the counterparty tokens.

            // ? For a deposit, the caller delta will be negative indicating that the caller is in a deficit relative to the pool
            int256 amount0 = delta.amount0();
            int256 amount1 = delta.amount1();

            bytes memory callerId = abi.encodePacked(sender, params.salt);

            if (tokenSelection == 0) {
                // token0DeltaFor[callerId] += amount0; // this negative value means that the caller is in a deficit position relative to the hook

                // The more negative the deltaOfToken0, the more deficit the callers are to the hook. Therefore, the hook has more token than amount1
                if (deltaOfToken1 <= amount1) {
                    // We can match the deposit
                    // Settle the amount0 from the hook to the poolManager
                    deltaOfToken0 -= amount0; // negative minus negative is positive
                    _settle(key.currency0, poolManager, address(this), SignedMath.abs(amount0));
                } else {
                    // match amount is what is whatever is available.
                    int256 matchDelta = deltaOfToken1;
                    int256 newDelta1 = amount1 - matchDelta;
                    deltaOfToken1 -= matchDelta;

                    // adding liquidity means that the deltas are negative.
                    if (matchDelta < 0) {
                        _settle(key.currency1, poolManager, address(this), SignedMath.abs(matchDelta));
                    }

                    // Now account for the new delta0 relative to newDelta1, and deduct from the original amount1. The difference is what the hook takes.
                    // This should allow for the LP to provide some token0 liquidity to match the remaining token1, that was not covered in a match by the Hook.
                    PoolId poolId = key.toId();
                    uint256 liquidity = StateLibrary.getLiquidity(manager, poolId);
                    (, int24 tick,,) = StateLibrary.getSlot0(manager, poolId);
                    uint160 sqrtPriceAX96 = TickMath.getSqrtRatioAtTick(tick + params.tickLower);
                    uint160 sqrtPriceBX96 = TickMath.getSqrtRatioAtTick(tick + params.tickUpper);
                    uint256 newAmount0 =
                        LiquidityAmounts.getAmount0ForLiquidity(sqrtPriceAX96, sqrtPriceBX96, liquidity);
                    int256 newDelta0 = -int256(newAmount0);

                    BalanceDelta newDelta = toBalanceDelta(newDelta0, newDelta1);
                    // _take(key.currency1, poolManager, address(this), SignedMath.abs(newDelta1));
                }

                if (pendingBalanceOfToken1 >= amount1) {
                    // We can match the deposit.
                    uint256 matchAmount = SignedMath.abs(delta.amount1());
                    _settle(key.currency1, poolManager, address(this), matchAmount);
                    pendingBalanceOfToken1 -= matchAmount;
                    usedBalanceOfToken1 += matchAmount;
                } else {
                    // match amount is what is whatever is available.
                    uint256 matchAmount = pendingBalanceOfToken1;
                    uint256 newDelta = amount1 + matchAmount;
                    // We now need to recalculate the delta for the difference to determine what token1 needs to be taken and held.

                    // _take(key.currency1, poolManager, address(this), takeAmount);
                }
            } else {
                // Else 1
            }

            // if (bondBalanceOf[tx.origin] > 0) {
            //     // tokenId is the sender + salt.
            //     bytes memory tokenId = abi.encodePacked(sender, params.salt);
            //     // Currency bondCurrency = bondCurrencyIsOne ? key.currency0 : key.currency1;

            //     // Determine how much non bond currency is being single staked
            //     // Then, use equivalent in bond currency to co-pool.
            //     uint256 difference;
            //     // Determine which token has the lesser delta

            // console.log("amount0:");
            // console.log(amount0);
            // console.log("amount1:");
            // console.log(amount1);

            //     // if (bondCurrencyIsOne) {
            //     //     require(amount0 > amount1, "The bond currency must be the token of lesser value");
            //     //     difference = amount0 - amount1;
            //     //     // TODO: The delta will not be equal. It's based on an algo for determining the value required of each token based on the existing pool.
            //     //     delta = toBalanceDelta(amount0, amount1 + difference);
            //     // } else {
            //     //     require(amount1 > amount0, "The bond currency must be the token of lesser value");
            //     //     difference = amount1 - amount0;
            //     //     delta = toBalanceDelta(amount0 + difference, amount1);
            //     // }

            //     // require(bondBalanceOf[tx.origin] > difference, "User does not have enough bonds to co-pool");

            //     // bondBalanceOf[tx.origin] -= difference;
            //     // bondOwed[tokenId] += difference; // Bond that is owed by the user is relative to the token holder.
            // } else {
            //     revert("User does not have enough bonds to co-pool");
            // }

            // In this case, the hook is covering the bond currency delta.
            // We send a negative delta for the bond currency because the hook is now in a deficit position relative to the pool.
            // ----- This will actually balance out the caller delta.
            // We also need to settle the hook's currency to the the poolManager
            _settle(key.currency0, poolManager, address(this), SignedMath.abs(delta.amount0()));
            return (this.afterAddLiquidity.selector, toBalanceDelta(delta.amount0(), 0));
        }

        return (this.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    // /// @notice The hook called after liquidity is removed
    // /// @param sender The initial msg.sender for the remove liquidity call
    // /// @param key The key for the pool
    // /// @param params The parameters for removing liquidity
    // /// @param delta The caller's balance delta after removing liquidity; the sum of principal delta, fees accrued, and hook delta
    // /// @param feesAccrued The fees accrued since the last time fees were collected from this position
    // /// @param hookData Arbitrary data handed into the PoolManager by the liquidity provider to be be passed on to the hook
    // /// @return bytes4 The function selector for the hook
    // /// @return BalanceDelta The hook's delta in token0 and token1. Positive: the hook is owed/took currency, negative: the hook owes/sent currency
    // function afterRemoveLiquidity(
    //     address sender,
    //     PoolKey calldata key,
    //     IPoolManager.ModifyLiquidityParams calldata params,
    //     BalanceDelta delta,
    //     BalanceDelta feesAccrued,
    //     bytes calldata hookData
    // ) external override onlyPoolManager onlyByAuthorisedRouter(sender) returns (bytes4, BalanceDelta) {
    //     // TODO: Implement

    //     return (this.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    // }

    /// @notice Settle (pay) a currency to the PoolManager
    /// @param currency Currency to settle
    /// @param manager IPoolManager to settle to
    /// @param payer Address of the payer, the token sender
    /// @param amount Amount to send
    // Adopted from: https://github.com/Uniswap/v4-core/blob/182712cf7146f31cd5c969749bbe3a188f030d1a/test/utils/CurrencySettler.sol#L19
    function _settle(Currency currency, IPoolManager manager, address payer, uint256 amount) internal {
        // for native currencies or burns, calling sync is not required
        // short circuit for ERC-6909 burns to support ERC-6909-wrapped native tokens
        if (currency.isAddressZero()) {
            manager.settle{value: amount}();
        } else {
            manager.sync(currency);
            if (payer != address(this)) {
                IERC20Minimal(Currency.unwrap(currency)).transferFrom(payer, address(manager), amount);
            } else {
                IERC20Minimal(Currency.unwrap(currency)).transfer(address(manager), amount);
            }
            manager.settle();
        }
    }

    /// @notice Take (receive) a currency from the PoolManager
    /// @param currency Currency to take
    /// @param manager IPoolManager to take from
    /// @param recipient Address of the recipient, the token receiver
    /// @param amount Amount to receive
    // Adopted from: https://github.com/Uniswap/v4-core/blob/182712cf7146f31cd5c969749bbe3a188f030d1a/test/utils/CurrencySettler.sol#L19
    function _take(Currency currency, IPoolManager manager, address recipient, uint256 amount) internal {
        manager.take(currency, recipient, amount);
    }
}
