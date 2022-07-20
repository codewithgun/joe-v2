// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.9;

import "./TestHelper.sol";

contract LiquidityBinPairOracleTest is TestHelper {
    function setUp() public {
        token6D = new ERC20MockDecimals(6);
        token18D = new ERC20MockDecimals(18);

        factory = new LBFactory(DEV);
        new LBFactoryHelper(factory);
        router = new LBRouter(ILBFactory(DEV), IJoeFactory(DEV), IWAVAX(DEV));

        pair = createLBPairDefaultFees(token6D, token18D);
    }

    function testVerifyOracleInitialParams() public {
        (
            uint256 oracleSampleLifetime,
            uint256 oracleSize,
            uint256 oracleActiveSize,
            uint256 oracleLastTimestamp,
            uint256 oracleId,
            uint256 min,
            uint256 max
        ) = pair.getOracleParameters();

        assertEq(oracleSampleLifetime, 240);
        assertEq(oracleSize, 2);
        assertEq(oracleActiveSize, 0);
        assertEq(oracleLastTimestamp, 0);
        assertEq(oracleId, 0);
        assertEq(min, 0);
        assertEq(max, 0);
    }

    function testIncreaseOracleLength() public {
        (
            uint256 oracleSampleLifetime,
            uint256 oracleSize,
            uint256 oracleActiveSize,
            uint256 oracleLastTimestamp,
            uint256 oracleId,
            uint256 min,
            uint256 max
        ) = pair.getOracleParameters();

        pair.increaseOracleLength(100);

        (
            uint256 newOracleSampleLifetime,
            uint256 newOracleSize,
            uint256 newOracleActiveSize,
            uint256 newOracleLastTimestamp,
            uint256 newOracleId,
            uint256 newMin,
            uint256 newMax
        ) = pair.getOracleParameters();

        assertEq(newOracleSampleLifetime, oracleSampleLifetime);
        assertEq(newOracleSize, oracleSize + 100);
        assertEq(newOracleActiveSize, oracleActiveSize);
        assertEq(newOracleLastTimestamp, oracleLastTimestamp);
        assertEq(newOracleId, oracleId);
        assertEq(newMin, min);
        assertEq(newMax, max);
    }

    function testOracleSampleFromWith2Samples() public {
        uint256 tokenAmount = 100e18;
        token18D.mint(address(pair), tokenAmount);

        uint256[] memory _ids = new uint256[](1);
        _ids[0] = ID_ONE;

        uint256[] memory _liquidities = new uint256[](1);
        _liquidities[0] = SCALE;

        pair.mint(_ids, new uint256[](1), _liquidities, DEV);

        token6D.mint(address(pair), 5e18);
        vm.prank(DEV);
        pair.swap(true, DEV);

        vm.warp(block.timestamp + 250);

        token6D.mint(address(pair), 5e18);
        vm.prank(DEV);
        pair.swap(true, DEV);

        uint256 _ago = 130;
        uint256 _time = block.timestamp - _ago;

        (uint256 cumulativeId, uint256 cumulativeAccumulator, uint256 cumulativeBinCrossed) = pair.getOracleSampleFrom(
            _ago
        );
        assertEq(cumulativeId / _time, ID_ONE);
        assertEq(cumulativeAccumulator, 0);
        assertEq(cumulativeBinCrossed, 0);
    }

    function testOracleSampleFromWith100Samples() public {
        uint256 amount1In = 101e18;
        (
            uint256[] memory _ids,
            uint256[] memory _distributionX,
            uint256[] memory _distributionY,
            uint256 amount0In
        ) = spreadLiquidity(amount1In * 2, ID_ONE, 99, 100);

        token6D.mint(address(pair), amount0In);
        token18D.mint(address(pair), amount1In);

        pair.mint(_ids, _distributionX, _distributionY, DEV);
        pair.increaseOracleLength(100);

        uint256 startTimestamp;

        for (uint256 i; i < 200; ++i) {
            if (i < 200) token6D.mint(address(pair), 1e18);
            else token18D.mint(address(pair), 1e18);

            vm.prank(DEV);
            vm.warp(1500 + 100 * i);
            pair.swap(true, DEV);

            if (i == 1) startTimestamp = block.timestamp;
        }

        (uint256 cId, uint256 cAcc, uint256 cBin) = pair.getOracleSampleFrom(0);

        for (uint256 i; i < 99; ++i) {
            uint256 _ago = ((block.timestamp - startTimestamp) * i) / 100;

            (uint256 cumulativeId, uint256 cumulativeAccumulator, uint256 cumulativeBinCrossed) = pair
                .getOracleSampleFrom(_ago);
            assertGe(cId, cumulativeId);
            assertGe(cAcc, cumulativeAccumulator);
            assertGe(cBin, cumulativeBinCrossed);

            (cId, cAcc, cBin) = (cumulativeId, cumulativeAccumulator, cumulativeBinCrossed);
        }
    }
}