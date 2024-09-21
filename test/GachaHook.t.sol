// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Foundry Cheatcode
import { Vm } from "forge-std/Vm.sol";
import { Test, console2 } from "forge-std/Test.sol";

// Helper Contract
import { Deployers } from "@uniswap/v4-core/test/utils/Deployers.sol";
import { PoolSwapTest } from "v4-core/test/PoolSwapTest.sol";

import { PoolManager } from "v4-core/PoolManager.sol";
import { IPoolManager } from "v4-core/interfaces/IPoolManager.sol";

import { Currency, CurrencyLibrary } from "v4-core/types/Currency.sol";
import { BalanceDelta, BalanceDeltaLibrary } from "v4-core/types/BalanceDelta.sol";
import { Hooks } from "v4-core/libraries/Hooks.sol";
import { TickMath } from "v4-core/libraries/TickMath.sol";
import { SqrtPriceMath } from "v4-core/libraries/SqrtPriceMath.sol";
import { LiquidityAmounts } from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import { VRFCoordinatorV2_5Mock } from "chainlink/contracts/src/v0.8/vrf/mocks/VRFCoordinatorV2_5Mock.sol";
import {
    CCIPLocalSimulator,
    IRouterClient,
    LinkToken,
    BurnMintERC677Helper
} from "@chainlink/local/src/ccip/CCIPLocalSimulator.sol";
import { Client } from "@chainlink/contracts-ccip/src/v0.8/ccip/libraries/Client.sol";

// Mock Token
import { MockERC20 } from "solmate/src/test/utils/mocks/MockERC20.sol";
import { MockERC721 } from "solmate/src/test/utils/mocks/MockERC721.sol";
import { Link } from "./Mocks/LinkToken.sol";

// Gacha Hook
import { GachaHook } from "../src/GachaHook.sol";
import { Config } from "./Helper/Config.t.sol";

contract TestGachaHook is Test, Deployers {
    using CurrencyLibrary for Currency;

    /*//////////////////////////////////////////////////////////////
                                 USER
    //////////////////////////////////////////////////////////////*/

    address caller;
    address user;
    address vrfAdmin;

    address alice;
    address bob;

    /*//////////////////////////////////////////////////////////////
                                 TOKEN
    //////////////////////////////////////////////////////////////*/

    MockERC721 nft;

    Currency ethCurrency = Currency.wrap(address(0));
    Currency tokenCurrency;

    /*//////////////////////////////////////////////////////////////
                               CONTRACT
    //////////////////////////////////////////////////////////////*/
    GachaHook hook;
    CCIPLocalSimulator public ccipLocalSimulator;
    IRouterClient router;
    BurnMintERC677Helper ccipBnMToken;
    LinkToken linkToken;

    /*//////////////////////////////////////////////////////////////
                            CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    Config internal helperConfig;
    Config.NetworkConfig internal config;
    uint64 destinationChainSelector;

    /*//////////////////////////////////////////////////////////////
                              CONSTANT
    //////////////////////////////////////////////////////////////*/

    uint256[10] INIT_NFT_IDS = [100, 101, 102, 103, 104, 105, 106, 107, 108, 109];
    uint160 public constant SQRT_PRICE_1E6_1 = 79_228_162_514_264_337_593_543_950_336_000;

    int24 TICK_SPACING = 60;
    int24 TICK_AT_SQRT_PRICE_1E6_1 = TickMath.getTickAtSqrtPrice(SQRT_PRICE_1E6_1) / TICK_SPACING * TICK_SPACING;

    uint256 internal constant PRIVATE_KEY = 0xabc123abc123abc123abc123abc123abc123abc123abc123abc123abc123abc1;
    uint256 internal constant INITIAL_BALANCE = 100 ether;

    /*//////////////////////////////////////////////////////////////
                                EVENT
    //////////////////////////////////////////////////////////////*/
    event FractionalizeNFT(address indexed originalOwner, uint256 indexed tokenId);

    function setUp() public {
        // User Account Setup
        caller = vm.addr(PRIVATE_KEY);
        vm.deal(caller, INITIAL_BALANCE);

        vrfAdmin = address(this);
        vm.deal(vrfAdmin, INITIAL_BALANCE);

        user = makeAddr("user");
        vm.deal(user, INITIAL_BALANCE);

        alice = makeAddr("alice");
        vm.deal(alice, INITIAL_BALANCE);

        bob = makeAddr("bob");
        vm.deal(bob, INITIAL_BALANCE);

        // Pool Manager & Router Seployment
        deployFreshManagerAndRouters();

        // Chainlink VRF Service Creation
        helperConfig = new Config();
        config = helperConfig.getConfig();

        // NFT Contract Creation
        nft = new MockERC721("Test NFT", "NFT");

        // CCIP Configuration
        ccipLocalSimulator = new CCIPLocalSimulator();

        (uint64 chainSelector, IRouterClient sourceRouter,,,, BurnMintERC677Helper ccipBnM,) =
            ccipLocalSimulator.configuration();

        router = sourceRouter;
        destinationChainSelector = chainSelector;
        ccipBnMToken = ccipBnM;
        linkToken = LinkToken(config.link);

        // Hook Address Configuration
        uint160 flags = uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG);

        // Hook Construction Parameter
        string memory name_ = "GachaTest NFT";
        string memory symbol_ = "gNFT";
        address vrfCoordinator = config.vrfCoordinatorV2_5;
        bytes32 gasLane = config.gasLane;
        uint256 subscriptionId = config.subscriptionId;
        uint32 callbackGasLimit = config.callbackGasLimit;
        address link = config.link;

        bytes memory initData = // solhint-disable-next-line
        abi.encode(
            manager,
            address(nft),
            name_,
            symbol_,
            vrfCoordinator,
            gasLane,
            subscriptionId,
            callbackGasLimit,
            address(router)
        );

        deployCodeTo("GachaHook.sol", initData, address(flags));

        // Hook Deployment
        hook = GachaHook(address(flags));
        tokenCurrency = Currency.wrap(address(hook)); // Currency 1 = Hook

        // VRF Configuration
        Link(link).mint(address(this), 100 ether);
        VRFCoordinatorV2_5Mock(vrfCoordinator).addConsumer(subscriptionId, address(hook));
        VRFCoordinatorV2_5Mock(vrfCoordinator).fundSubscription(config.subscriptionId, 100 ether);

        // Approve Hook Token
        vm.startPrank(caller);
        hook.approve(address(swapRouter), type(uint256).max); // For swap router
        hook.approve(address(modifyLiquidityRouter), type(uint256).max); // For modify liquidiy router
        vm.stopPrank();

        vm.startPrank(user);
        hook.approve(address(swapRouter), type(uint256).max);
        hook.approve(address(modifyLiquidityRouter), type(uint256).max);
        vm.stopPrank();

        // Pool Initialization
        (key,) = initPool(
            ethCurrency, // Currency 0 = ETH
            tokenCurrency, // Currency 1 = HOOK TOKEN
            hook, // Hook Contract
            3000, // Swap Fees
            TICK_SPACING, // Tick Spacing
            SQRT_PRICE_1E6_1,
            ZERO_BYTES // No additional `initData`
        );

        // Contract Labeling
        vm.label(address(hook), "GachaHook");
        vm.label(address(manager), "PoolManager");
        vm.label(address(swapRouter), "SwapRouter");
        vm.label(address(modifyLiquidityRouter), "ModifyLiquidityRouter");
        vm.label(address(nft), "NFT");
        vm.label(address(link), "LinkToken");
        vm.label(address(vrfCoordinator), "VRFCoordinatorV2_5");
        vm.label(address(ccipLocalSimulator), "CCIP");
        vm.label(address(router), "Router");
        vm.label(address(ccipBnMToken), "CCIP Token");
    }
}
