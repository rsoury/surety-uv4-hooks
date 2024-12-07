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
        uint160 flags = uint160(Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG);

        address hookAddress = address(flags);

        // deployCodeTo("CoPoolHook.sol", abi.encode(manager, address(bondToken), authorisedRouters), hookAddress);
        deployCodeTo("CoPoolHook.sol", abi.encode(manager, Currency.unwrap(token0), authorisedRouters), hookAddress);

        // Deploy our hook
        hook = CoPoolHook(hookAddress);

        // Initialize a pool
        (key,) = initPool(
            token0, // Currency 0 = Bond
            token1, // Currency 1 = Counterparty
            hook, // Hook Contract
            100, // Swap Fees - 1 bps -- fee / 100 * 2
            SQRT_PRICE_1_1 // Initial Sqrt(P) value = 1
        );

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

    // Here we unapprove the token0 from the sender, and leverage the token0 in hook.
    function test_addSingleToken0Liquidity() public {
        // Start by bonding the bondToken

        bytes action = hook.COPOOL();
        uint8 tokenSelection = 0;

        bytes memory hookData = abi.encode(action, tokenSelection);

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

        // Check the poolManager's balance of token0
        // Check the hook's delta of token0
    }
}
