// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDeltaLibrary, BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol"; // Import OpenZeppelin's Ownable
import {IERC20Minimal} from "v4-core/interfaces/external/IERC20Minimal.sol";

// ----------- Plan -----------
// The hook is designed for users to leverage their bonded asset as a counter-party with their asset to be deposited.
// 1. Accept a bonded token - the "why?" is irrelevant for now... It can be to secure some other aspect of the protocol.
// 2  Users can stake a single counterparty asset.
// 3. Protocol will co-pool that asset it owns (bonded) alongside the counter-party asset.

// Additionally, the protocol should allow boths assets to co-pool arbitrarily - ie. via single stake delegations.
// 1. Users can delegate their token to the hook
// 2. Hook will automatically co-pool the delegated token together as they're deposited independently.

// ----------- How it works -----------
// 1. Implement `afterAddLiquidity`
// 2. Implement `afterRemoveLiquidity`
// Within the above, the hook will re-balance the delta if the user provides hookData instruction to use their bonded asset.
//
contract CoPoolHook is BaseHook, Ownable {
    // Use CurrencyLibrary and BalanceDeltaLibrary
    // to add some helper functions over the Currency and BalanceDelta
    // data types
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    bool private bondCurrencyIsOne;
    address private bondCurrencyAddress;

    mapping(address => uint256) public bondBalanceOf;
    mapping(bytes => uint256) public bondOwed;
    mapping(address => bool) public authorisedRouters;

    // liquidity actions
    bytes constant BOND = hex"00";
    bytes constant DELEGATE = hex"01";

    error OnlyByPoolManager();
    error OnlyByAuthorisedRouter();

    // ? Ownership of bonded assets is correlated to the Salt for Uv4 PositionManager - and this logic is specific to the router.
    // Therefore, only routers that correlate ownership of receipt to the Salt can leverage the pool.
    // ie. PositionManager.sol from Uv4 Periphery has `salt` =  `bytes32(tokenId)`
    // Eventually, we can default to tx.origin, but for now we'll keep it as is.
    modifier onlyByAuthorisedRouter(address sender) {
        if (!authorisedRouters[sender]) revert OnlyByAuthorisedRouter();
        _;
    }

    // Initialize BaseHook and ERC20
    constructor(IPoolManager _manager, address _bondCurrencyAddress, address[] memory _authorisedRouters)
        BaseHook(_manager)
        Ownable(_msgSender())
    {
        // On deployment we determine the c
        bondCurrencyAddress = _bondCurrencyAddress;
        for (uint256 i = 0; i < _authorisedRouters.length; i++) {
            authorisedRouters[_authorisedRouters[i]] = true;
        }
    }

    function addAuthorisedRouter(address _router) external onlyOwner {
        authorisedRouters[_router] = true;
    }

    function removeAuthorisedRouter(address _router) external onlyOwner {
        authorisedRouters[_router] = false;
    }

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
        // We set the bond currency to be the token of the pool that matches address of bondCurrencyAddress
        if (Currency.unwrap(key.currency0) == bondCurrencyAddress) {
            bondCurrencyIsOne = false;
        } else if (Currency.unwrap(key.currency1) == bondCurrencyAddress) {
            bondCurrencyIsOne = true;
        } else {
            revert("Bond currency not found in pool");
        }

        return (this.afterInitialize.selector);
    }

    // Deposit the bond currency into the contract
    function deposit(uint256 amount) external {
        address sender = _msgSender();
        IERC20Minimal(bondCurrencyAddress).transferFrom(sender, address(this), amount);
        bondBalanceOf[sender] += amount;

        // Now that bonds have been deposited for some purpose, we can perform some other logic...
        // ie. In Surety Protocol, we unlock tokenised assets now that they're secured by a bonded asset.
    }

    // Withdraw the bond currency from the contract
    function withdraw(uint256 amount) external {
        address sender = _msgSender();
        if (bondBalanceOf[sender] > amount) {
            revert("Insufficient bond balance");
        }
        Currency.wrap(bondCurrencyAddress).transfer(sender, amount);
        bondBalanceOf[sender] -= amount;
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
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata hookData
    ) external override onlyPoolManager onlyByAuthorisedRouter(sender) returns (bytes4, BalanceDelta) {
        // Check hookData for instruction to use bond currency
        if (hookData.length == 0) {
            return (this.afterAddLiquidity.selector, delta);
        }

        // If so, re-balance the delta
        if (hookData.length == BOND.length && keccak256(hookData) == keccak256(BOND)) {
            // Validate that the user has enough available bonds to use.
            // The kicker is that the sender is the router, not the user.
            // Therefore, here we use the tx.origin.
            if (bondBalanceOf[tx.origin] > 0) {
                // tokenId is the sender + salt.
                bytes memory tokenId = abi.encodePacked(sender, params.salt);
                // Currency bondCurrency = bondCurrencyIsOne ? key.currency0 : key.currency1;

                // Determine how much non bond currency is being single staked
                // Then, use equivalent in bond currency to co-pool.
                uint256 difference;
                // Determine which token has the lesser delta
                int256 amount0 = delta.amount0();
                int256 amount1 = delta.amount1();
                if (bondCurrencyIsOne) {
                    require(amount0 > amount1, "The bond currency must be the token of lesser value");
                    difference = amount0 - amount1;
                    // TODO: The delta will not be equal. It's based on an algo for determining the value required of each token based on the existing pool.
                    delta = toBalanceDelta(amount0, amount1 + difference);
                } else {
                    require(amount1 > amount0, "The bond currency must be the token of lesser value");
                    difference = amount1 - amount0;
                    delta = toBalanceDelta(amount0 + difference, amount1);
                }

                require(bondBalanceOf[tx.origin] > difference, "User does not have enough bonds to co-pool");

                bondBalanceOf[tx.origin] -= difference;
                bondOwed[tokenId] += difference; // Bond that is owed by the user is relative to the token holder.
            }

            revert("User does not have enough bonds to co-pool");
        } else if (hookData.length == DELEGATE.length && keccak256(hookData) == keccak256(DELEGATE)) {
            // TODO: Implement
        }

        return (this.afterAddLiquidity.selector, delta);
    }

    /// @notice The hook called after liquidity is removed
    /// @param sender The initial msg.sender for the remove liquidity call
    /// @param key The key for the pool
    /// @param params The parameters for removing liquidity
    /// @param delta The caller's balance delta after removing liquidity; the sum of principal delta, fees accrued, and hook delta
    /// @param feesAccrued The fees accrued since the last time fees were collected from this position
    /// @param hookData Arbitrary data handed into the PoolManager by the liquidity provider to be be passed on to the hook
    /// @return bytes4 The function selector for the hook
    /// @return BalanceDelta The hook's delta in token0 and token1. Positive: the hook is owed/took currency, negative: the hook owes/sent currency
    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) external override onlyPoolManager onlyByAuthorisedRouter(sender) returns (bytes4, BalanceDelta) {
        // TODO: Implement

        return (this.afterRemoveLiquidity.selector, delta);
    }
}
