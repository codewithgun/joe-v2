// SPDX-License-Identifier: UNLICENSED

pragma solidity 0.8.10;

import "test/helpers/TestHelper.sol";
import "forge-std/console2.sol";

/**
 * Test scenarios:
 * 1. Receive
 * 2. Create LBPair
 * 3. Add Liquidity
 * 4. Add liquidity NATIVE
 * 5. Remove liquidity
 * 6. Remove liquidity NATIVE
 * 7. Sweep ERC20s
 * 8. Sweep LBToken
 */
contract LiquidityBinRouterTest is TestHelper {
    bool blockReceive;
    uint24 START_ID = 8394242; // Price of token X wei = 278.992493542163540409 of Y
    uint16 BIN_STEP = 10;

    function setUp() public override {
        super.setUp();

        factory.setPresetOpenState(DEFAULT_BIN_STEP, true);

        // Create necessary pairs
        router.createLBPair(wbtc, usdc, START_ID, DEFAULT_BIN_STEP);

        uint256 startingBalance = type(uint112).max;
        deal(address(usdc), address(this), startingBalance);
        deal(address(wbtc), address(this), startingBalance);
    }

    function test_AddLiquidityStuck() public {
        // When the active bin token ratio is super imbalance, if we deposit to the reserve with lesser token, the liquidty deposited will be stuck, or loss.
        uint256 amountXIn = 1e8; // 1 WBTC
        uint256 amountYIn = 1e6; // 1 USDC

        // Deposit only to the active id
        int256[] memory deltaIds = new int256[](1);
        deltaIds[0] = 0;

        uint256[] memory distributionX = new uint256[](1);
        distributionX[0] = 1e18;

        uint256[] memory distributionY = new uint256[](1);
        distributionY[0] = 1e18;

        ILBRouter.LiquidityParameters memory liquidityParameters = ILBRouter.LiquidityParameters({
            tokenX: wbtc,
            tokenY: usdc,
            binStep: BIN_STEP,
            amountX: amountXIn,
            amountY: amountYIn,
            amountXMin: 0,
            amountYMin: 0,
            activeIdDesired: START_ID,
            idSlippage: 0,
            deltaIds: deltaIds,
            distributionX: distributionX,
            distributionY: distributionY,
            to: DEV,
            refundTo: BOB,
            deadline: block.timestamp + 1000
        });

        // Add liquidity
        (
            uint256 amountXAdded,
            uint256 amountYAdded,
            uint256 amountXLeft,
            uint256 amountYLeft,
            uint256[] memory depositIds,
            uint256[] memory liquidityMinted
        ) = router.addLiquidity(liquidityParameters);
        console2.log("LiquidityMinted %s", liquidityMinted[0]);

        // Deposit small amount of USDC
        amountYIn = 100;

        // If the amountYIn > bin price, it will have out amount
        // amountYIn = 280;

        distributionX[0] = 0e18;

        liquidityParameters = ILBRouter.LiquidityParameters({
            tokenX: wbtc,
            tokenY: usdc,
            binStep: BIN_STEP,
            amountX: 0,
            amountY: amountYIn,
            amountXMin: 0,
            amountYMin: 0,
            activeIdDesired: START_ID,
            idSlippage: 0,
            deltaIds: deltaIds,
            distributionX: distributionX,
            distributionY: distributionY,
            to: DEV,
            refundTo: BOB,
            deadline: block.timestamp + 1000
        });

        (amountXAdded, amountYAdded, amountXLeft, amountYLeft, depositIds, liquidityMinted) =
            router.addLiquidity(liquidityParameters);

        console2.log("LiquidityMinted %s", liquidityMinted[0]);

        // Withdraw the small amount of USDC just deposited
        ILBPair pair = factory.getLBPairInformation(wbtc, usdc, BIN_STEP).LBPair;

        pair.approveForAll(address(router), true);

        // !! The USDC stuck !!
        (uint256 amountXOut, uint256 amountYOut) = router.removeLiquidity(
            wbtc, usdc, BIN_STEP, 0, 0, depositIds, liquidityMinted, address(this), block.timestamp
        );

        console2.log("amountXOut %s", amountXOut);
        console2.log("amountYOut %s", amountYOut);
    }

    receive() external payable {
        if (blockReceive) {
            revert("No receive function on the contract");
        }
    }
}
