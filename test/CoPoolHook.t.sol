// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

import {console} from "forge-std/console.sol";
import {CoPoolHook} from "../src/CoPoolHook.sol";

contract CoPoolHookTest is Test, Deployers {
    using CurrencyLibrary for Currency;

    CoPoolHook hook;

    MockERC20 bondToken;
    MockERC20 cpToken;
    Currency bondTokenCurrency;
    Currency cpTokenCurrency;

    function setUp() public {
        // Step 1 + 2
        // Deploy PoolManager and Router contracts
        deployFreshManagerAndRouters();

        // Deploy our TOKEN contract
        bondToken = new MockERC20("Test Bond Token", "TEST_BOND", 18);
        cpToken = new MockERC20("Test Counterparty Token", "TEST_CP", 18);
        bondTokenCurrency = Currency.wrap(address(bondToken));
        cpTokenCurrency = Currency.wrap(address(cpToken));

        // Mint a bunch of TOKEN to ourselves and to address(1)
        bondToken.mint(address(this), 1000 ether);
        bondToken.mint(address(1), 1000 ether);
        cpToken.mint(address(this), 1000 ether);
        cpToken.mint(address(1), 1000 ether);

        // Deploy our TOKEN contract
        uint160 flags = uint160(
            Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
                | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
        );

        address[] memory authorisedRouters = new address[](2);
        authorisedRouters[0] = address(swapRouter);
        authorisedRouters[1] = address(modifyLiquidityRouter);
        deployCodeTo("CoPoolHook.sol", abi.encode(manager, address(bondToken), authorisedRouters), address(flags));

        // Deploy our hook
        hook = CoPoolHook(address(flags));

        // Approve our TOKEN for spending on the swap router and modify liquidity router
        // These variables are coming from the `Deployers` contract
        // bondToken.approve(address(swapRouter), type(uint256).max);
        // bondToken.approve(address(modifyLiquidityRouter), type(uint256).max);
        bondToken.approve(address(hook), type(uint256).max); // bond to the hook

        cpToken.approve(address(swapRouter), type(uint256).max);
        cpToken.approve(address(modifyLiquidityRouter), type(uint256).max);

        // Initialize a pool
        (key,) = initPool(
            bondTokenCurrency, // Currency 0 = ETH
            cpTokenCurrency, // Currency 1 = TOKEN
            hook, // Hook Contract
            1, // Swap Fees - 1 bps
            SQRT_PRICE_1_1 // Initial Sqrt(P) value = 1
        );
    }

    function test_addLiquidity() public {
        // Start by bonding the bondToken

        hook.deposit(10 ether); // bond 1 ether of bondToken

        bytes memory hookData = hook.BOND;

        // Now we add liquidity in a single stake

        // Calculate the sqrt prices at the desired ticks
        // uint160 sqrtPriceAtTickLower = TickMath.getSqrtPriceAtTick(-60);
        // uint160 sqrtPriceAtTickUpper = TickMath.getSqrtPriceAtTick(60);

        // Calculate the amounts for liquidity, but set one to zero
        (uint256 amount0Delta, uint256 amount1Delta) =
            LiquidityAmounts.getAmountsForLiquidity(SQRT_PRICE_1_1, sqrtPriceAtTickLower, sqrtPriceAtTickUpper, 1 ether);

        console.log("amount0Delta:");
        console.log(amount0Delta);
        console.log("amount1Delta:");
        console.log(amount1Delta);

        modifyLiquidityRouter.modifyLiquidity{value: 0}(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 1 ether,
                salt: bytes32(123) // Arbitrary salt - however used in the protocol to identify the tokenId.
            }),
            hookData
        );

        // Assert that the amount staked is correct and that both tokens are equal in the pool.
    }
}
