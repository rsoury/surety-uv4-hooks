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

    // MockERC20 bondToken;
    // MockERC20 cpToken;
    // Currency bondTokenCurrency;
    // Currency cpTokenCurrency;

    Currency token0;
    Currency token1;

    function setUp() public {
        // Step 1 + 2
        // Deploy PoolManager and Router contracts
        deployFreshManagerAndRouters();

        (token0, token1) = deployMintAndApprove2Currencies();

        // Deploy our TOKEN contract
        // uint160 flags = uint160(
        //     Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
        //         | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
        // );
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG
        );

        address hookAddress = address(flags);

        address[] memory authorisedRouters = new address[](2);
        authorisedRouters[0] = address(swapRouter);
        authorisedRouters[1] = address(modifyLiquidityRouter);
        // deployCodeTo("CoPoolHook.sol", abi.encode(manager, address(bondToken), authorisedRouters), hookAddress);
        deployCodeTo("CoPoolHook.sol", abi.encode(manager, Currency.unwrap(token0), authorisedRouters), hookAddress);

        // Deploy our hook
        hook = CoPoolHook(hookAddress);

        MockERC20(Currency.unwrap(token0)).approve(address(hook), type(uint256).max);

        // Remove approval for token0 -- giving it over to Hook
        MockERC20(Currency.unwrap(token0)).approve(address(swapRouter), 0);
        MockERC20(Currency.unwrap(token0)).approve(address(modifyLiquidityRouter), 0);

        // Initialize a pool
        (key,) = initPool(
            token0, // Currency 0 = Bond
            token1, // Currency 1 = Counterparty
            hook, // Hook Contract
            100, // Swap Fees - 1 bps -- fee / 100 * 2
            SQRT_PRICE_1_1 // Initial Sqrt(P) value = 1
        );
        // (key,) = initPool(
        //     bondTokenCurrency, // Currency 0 = Bond
        //     cpTokenCurrency, // Currency 1 = Counterparty
        //     hook, // Hook Contract
        //     100, // Swap Fees - 1 bps -- fee / 100 * 2
        //     SQRT_PRICE_1_1 // Initial Sqrt(P) value = 1
        // );

        // Add initial liquidity to the pool

        // Some liquidity from -60 to +60 tick range
        // uint256 tokenId1 = 120;
        // uint256 tokenId2 = 121;
        // uint256 tokenId3 = 122;
        // modifyLiquidityRouter.modifyLiquidity(
        //     key,
        //     IPoolManager.ModifyLiquidityParams({
        //         tickLower: -60,
        //         tickUpper: 60,
        //         liquidityDelta: 10 ether,
        //         salt: bytes32(0)
        //     }),
        //     ZERO_BYTES
        // );
        // // Some liquidity from -120 to +120 tick range
        // modifyLiquidityRouter.modifyLiquidity(
        //     key,
        //     IPoolManager.ModifyLiquidityParams({
        //         tickLower: -120,
        //         tickUpper: 120,
        //         liquidityDelta: 10 ether,
        //         salt: bytes32(0)
        //     }),
        //     ZERO_BYTES
        // );
        // // some liquidity for full range
        // modifyLiquidityRouter.modifyLiquidity(
        //     key,
        //     IPoolManager.ModifyLiquidityParams({
        //         tickLower: TickMath.minUsableTick(60),
        //         tickUpper: TickMath.maxUsableTick(60),
        //         liquidityDelta: 10 ether,
        //         salt: bytes32(0)
        //     }),
        //     ZERO_BYTES
        // );
    }

    function test_addLiquidity() public {
        // Start by bonding the bondToken

        // MockERC20(Currency.unwrap(token0)).mint(address(tx.origin), 10 ether);

        hook.deposit(10 ether); // bond 1 ether of bondToken

        bytes memory hookData = hook.BOND();

        // // Now we add liquidity in a single stake

        // // Calculate the sqrt prices at the desired ticks
        // uint160 sqrtPriceAtTickLower = TickMath.getSqrtPriceAtTick(-60);
        // uint160 sqrtPriceAtTickUpper = TickMath.getSqrtPriceAtTick(60);

        // // Calculate the amounts for liquidity, but set one to zero
        // (uint256 amount0Delta, uint256 amount1Delta) =
        //     LiquidityAmounts.getAmountsForLiquidity(SQRT_PRICE_1_1, sqrtPriceAtTickLower, sqrtPriceAtTickUpper, 1 ether);

        // console.log("amount0Delta:");
        // console.log(amount0Delta);
        // console.log("amount1Delta:");
        // console.log(amount1Delta);

        uint256 tokenId = 123;
        modifyLiquidityRouter.modifyLiquidity{value: 0}(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 1 ether,
                salt: bytes32(tokenId) // Arbitrary salt - however used in the protocol to identify the tokenId.
            }),
            hookData
        );

        // Assert that the amount staked is correct and that both tokens are equal in the pool.
    }
}
