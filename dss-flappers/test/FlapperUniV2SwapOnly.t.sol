// SPDX-FileCopyrightText: © 2023 Dai Foundation <www.daifoundation.org>
// SPDX-License-Identifier: AGPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <http://www.gnu.org/licenses/>.

pragma solidity ^0.8.21;

import "dss-test/DssTest.sol";

import { DssInstance, MCD } from "dss-test/MCD.sol";
import { FlapperDeploy } from "deploy/FlapperDeploy.sol";
import { FlapperUniV2Config, FlapperInit } from "deploy/FlapperInit.sol";
import { FlapperUniV2SwapOnly } from "src/FlapperUniV2SwapOnly.sol";
import { SplitterMock } from "test/mocks/SplitterMock.sol";
import "./helpers/UniswapV2Library.sol";

interface ChainlogLike {
    function getAddress(bytes32) external view returns (address);
}

interface VatLike {
    function sin(address) external view returns (uint256);
    function dai(address) external view returns (uint256);
}

interface VowLike {
    function file(bytes32, address) external;
    function file(bytes32, uint256) external;
    function flap() external returns (uint256);
    function Sin() external view returns (uint256);
    function Ash() external view returns (uint256);
    function heal(uint256) external;
    function bump() external view returns (uint256);
    function hump() external view returns (uint256);
}

interface SpotterLike {
    function par() external view returns (uint256);
}

interface PairLike {
    function mint(address) external returns (uint256);
    function sync() external;
}

interface GemLike {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external;
    function transfer(address, uint256) external;
}

contract MockMedianizer {
    uint256 public price;
    mapping (address => uint256) public bud;

    function setPrice(uint256 price_) external {
        price = price_;
    }

    function kiss(address a) external {
        bud[a] = 1;
    }

    function read() external view returns (bytes32) {
        require(bud[msg.sender] == 1, "MockMedianizer/not-authorized");
        return bytes32(price);
    }
}

contract FlapperUniV2SwapOnlyTest is DssTest {
    using stdStorage for StdStorage;

    SplitterMock         public splitter;
    FlapperUniV2SwapOnly public flapper;
    FlapperUniV2SwapOnly public linkFlapper;
    MockMedianizer       public medianizer;
    MockMedianizer       public linkMedianizer;

    address     DAI_JOIN;
    address     SPOT;
    address     DAI;
    address     MKR;
    address     USDC;
    address     LINK;
    address     PAUSE_PROXY;
    VatLike     vat;
    VowLike     vow;
    SpotterLike spotter;

    address constant LOG                 = 0xdA0Ab1e0017DEbCd72Be8599041a2aa3bA7e740F;

    address constant UNIV2_FACTORY       = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
    address constant UNIV2_DAI_MKR_PAIR  = 0x517F9dD285e75b599234F7221227339478d0FcC8;
    address constant UNIV2_LINK_DAI_PAIR = 0x6D4fd456eDecA58Cf53A8b586cd50754547DBDB2;

    event Exec(uint256 lot, uint256 bought);

    function setUp() public {
        vm.createSelectFork(vm.envString("ETH_RPC_URL"));

        DAI_JOIN      = ChainlogLike(LOG).getAddress("MCD_JOIN_DAI");
        SPOT          = ChainlogLike(LOG).getAddress("MCD_SPOT");
        DAI           = ChainlogLike(LOG).getAddress("MCD_DAI");
        MKR           = ChainlogLike(LOG).getAddress("MCD_GOV");
        USDC          = ChainlogLike(LOG).getAddress("USDC");
        LINK          = ChainlogLike(LOG).getAddress("LINK");
        PAUSE_PROXY   = ChainlogLike(LOG).getAddress("MCD_PAUSE_PROXY");
        vat           = VatLike(ChainlogLike(LOG).getAddress("MCD_VAT"));
        vow           = VowLike(ChainlogLike(LOG).getAddress("MCD_VOW"));
        spotter       = SpotterLike(ChainlogLike(LOG).getAddress("MCD_SPOT"));

        splitter = new SplitterMock(DAI_JOIN);
        vm.startPrank(PAUSE_PROXY);
        vow.file("hump", 50_000_000 * RAD);
        vow.file("bump", 5707 * RAD);
        vow.file("flapper", address(splitter));
        vm.stopPrank();

        (flapper, medianizer) = setUpFlapper(MKR, UNIV2_DAI_MKR_PAIR, 727 * WAD) ;
        assertEq(flapper.daiFirst(), true);

        (linkFlapper, linkMedianizer) = setUpFlapper(LINK, UNIV2_LINK_DAI_PAIR, 654 * WAD / 100);
        assertEq(linkFlapper.daiFirst(), false);

        changeFlapper(address(flapper)); // Use MKR flapper by default

        // Create additional surplus if needed
        uint256 bumps = 2 * vow.bump(); // two kicks
        if (vat.dai(address(vow)) < vat.sin(address(vow)) + bumps + vow.hump()) {
            stdstore.target(address(vat)).sig("dai(address)").with_key(address(vow)).depth(0).checked_write(
                vat.sin(address(vow)) + bumps + vow.hump()
            );
        }

        // Heal if needed
        if (vat.sin(address(vow)) > vow.Sin() + vow.Ash()) {
            vow.heal(vat.sin(address(vow)) - vow.Sin() - vow.Ash());
        }
    }

    function setUpFlapper(address gem, address pair, uint256 price)
        internal
        returns (FlapperUniV2SwapOnly _flapper, MockMedianizer _medianizer)
    {
        _medianizer = new MockMedianizer();
        _medianizer.kiss(address(this));

        _flapper = FlapperUniV2SwapOnly(FlapperDeploy.deployFlapperUniV2({
            deployer: address(this),
            owner:    PAUSE_PROXY,
            spotter:  SPOT,
            dai:      DAI,
            gem:      gem,
            pair:     pair,
            receiver: PAUSE_PROXY,
            swapOnly: true
        }));

        // Note - this part emulates the spell initialization
        vm.startPrank(PAUSE_PROXY);
        FlapperUniV2Config memory cfg = FlapperUniV2Config({
            want:            WAD * 97 / 100,
            pip:             address(_medianizer),
            pair:            pair,
            dai:             DAI,
            splitter:        address(splitter),
            prevChainlogKey: bytes32(0),
            chainlogKey:     "MCD_FLAP_BURN"
        });
        DssInstance memory dss = MCD.loadFromChainlog(LOG);
        FlapperInit.initFlapperUniV2(dss, address(_flapper), cfg);
        FlapperInit.initDirectOracle(address(_flapper));
        vm.stopPrank();

        assertEq(dss.chainlog.getAddress("MCD_FLAP_BURN"), address(_flapper));

        // Add initial liquidity if needed
        (uint256 reserveDai, ) = UniswapV2Library.getReserves(UNIV2_FACTORY, DAI, gem);
        uint256 minimalDaiReserve = 280_000 * WAD;
        if (reserveDai < minimalDaiReserve) {
            _medianizer.setPrice(price);
            changeUniV2Price(price, gem, pair);
            (reserveDai, ) = UniswapV2Library.getReserves(UNIV2_FACTORY, DAI, gem);
            if(reserveDai < minimalDaiReserve) {
                topUpLiquidity(minimalDaiReserve - reserveDai, gem, pair);
            }
        } else {
            // If there is initial liquidity, then the oracle price should be set to the current price
            _medianizer.setPrice(uniV2DaiForGem(WAD, gem));
        }
    }

    function changeFlapper(address _flapper) internal {
        vm.prank(PAUSE_PROXY); splitter.file("flapper", address(_flapper));
    }

    function refAmountOut(uint256 amountIn, address pip) internal view returns (uint256) {
        return amountIn * WAD / (uint256(MockMedianizer(pip).read()) * RAY / spotter.par());
    }

    function uniV2GemForDai(uint256 amountIn, address gem) internal view returns (uint256 amountOut) {
        (uint256 reserveDai, uint256 reserveGem) = UniswapV2Library.getReserves(UNIV2_FACTORY, DAI, gem);
        amountOut = UniswapV2Library.getAmountOut(amountIn, reserveDai, reserveGem);
    }

    function uniV2DaiForGem(uint256 amountIn, address gem) internal view returns (uint256 amountOut) {
        (uint256 reserveDai, uint256 reserveGem) = UniswapV2Library.getReserves(UNIV2_FACTORY, DAI, gem);
        return UniswapV2Library.getAmountOut(amountIn, reserveGem, reserveDai);
    }

    function changeUniV2Price(uint256 daiForGem, address gem, address pair) internal {
        (uint256 reserveDai, uint256 reserveGem) = UniswapV2Library.getReserves(UNIV2_FACTORY, DAI, gem);
        uint256 currentDaiForGem = reserveDai * WAD / reserveGem;

        // neededReserveDai * WAD / neededReserveMkr = daiForGem;
        if (currentDaiForGem > daiForGem) {
            deal(gem, pair, reserveDai * WAD / daiForGem);
        } else {
            deal(DAI, pair, reserveGem * daiForGem / WAD);
        }
        PairLike(pair).sync();
    }

    function topUpLiquidity(uint256 daiAmt, address gem, address pair) internal {
        (uint256 reserveDai, uint256 reserveGem) = UniswapV2Library.getReserves(UNIV2_FACTORY, DAI, gem);
        uint256 gemAmt = UniswapV2Library.quote(daiAmt, reserveDai, reserveGem);

        deal(DAI, address(this), GemLike(DAI).balanceOf(address(this)) + daiAmt);
        deal(gem, address(this), GemLike(gem).balanceOf(address(this)) + gemAmt);

        GemLike(DAI).transfer(pair, daiAmt);
        GemLike(gem).transfer(pair, gemAmt);
        uint256 liquidity = PairLike(pair).mint(address(this));
        assertGt(liquidity, 0);
        assertGe(GemLike(pair).balanceOf(address(this)), liquidity);
    }

    function marginalWant(address gem, address pip) internal view returns (uint256) {
        uint256 wbump = vow.bump() / RAY;
        uint256 actual = uniV2GemForDai(wbump, gem);
        uint256 ref    = refAmountOut(wbump, pip);
        return actual * WAD / ref;
    }

    function doExec(address _flapper, address gem, address pair) internal {
        uint256 initialGem = GemLike(gem).balanceOf(address(PAUSE_PROXY));
        uint256 initialDaiVow = vat.dai(address(vow));
        uint256 initialReserveDai = GemLike(DAI).balanceOf(pair);
        uint256 initialReserveMkr = GemLike(gem).balanceOf(pair);

        vm.expectEmit(false, false, false, false); // only check event signature (topic 0)
        emit Exec(0, 0);
        vow.flap();

        assertGt(GemLike(gem).balanceOf(address(PAUSE_PROXY)), initialGem);
        assertGt(GemLike(DAI).balanceOf(pair), initialReserveDai);
        assertLt(GemLike(gem).balanceOf(pair), initialReserveMkr);
        assertEq(initialDaiVow - vat.dai(address(vow)), vow.bump());
        assertEq(GemLike(DAI).balanceOf(address(_flapper)), 0);
        assertEq(GemLike(gem).balanceOf(address(_flapper)), 0);
    }

    function testDefaultValues() public {
        FlapperUniV2SwapOnly f = new FlapperUniV2SwapOnly(DAI_JOIN, SPOT, MKR, UNIV2_DAI_MKR_PAIR, PAUSE_PROXY);
        assertEq(f.want(), WAD);
        assertEq(f.wards(address(this)), 1);
    }

    function testIllegalGemDecimals() public {
        vm.expectRevert("FlapperUniV2SwapOnly/gem-decimals-not-18");
        flapper = new FlapperUniV2SwapOnly(DAI_JOIN, SPOT, USDC, UNIV2_DAI_MKR_PAIR, PAUSE_PROXY);
    }

    function testAuth() public {
        checkAuth(address(flapper), "FlapperUniV2SwapOnly");
    }

    function testAuthModifiers() public virtual {
        assert(flapper.wards(address(this)) == 0);

        checkModifier(address(flapper), string(abi.encodePacked("FlapperUniV2SwapOnly", "/not-authorized")), [
            FlapperUniV2SwapOnly.exec.selector
        ]);
    }

    function testFileUint() public {
        checkFileUint(address(flapper), "FlapperUniV2SwapOnly", ["want"]);
    }

    function testFileAddress() public {
        checkFileAddress(address(flapper), "FlapperUniV2SwapOnly", ["pip"]);
    }

    function testExec() public {
        doExec(address(flapper), MKR, UNIV2_DAI_MKR_PAIR);
    }

    function testExecDaiSecond() public {
        changeFlapper(address(linkFlapper));
        doExec(address(linkFlapper), LINK, UNIV2_LINK_DAI_PAIR);
    }

    function testExecWantAllows() public {
        uint256 _marginalWant = marginalWant(MKR, address(medianizer));
        vm.prank(PAUSE_PROXY); flapper.file("want", _marginalWant * 99 / 100);
        doExec(address(flapper), MKR, UNIV2_DAI_MKR_PAIR);
    }

    function testExecWantBlocks() public {
        uint256 _marginalWant = marginalWant(MKR, address(medianizer));
        vm.prank(PAUSE_PROXY); flapper.file("want", _marginalWant * 101 / 100);
        vm.expectRevert("FlapperUniV2SwapOnly/insufficient-buy-amount");
        vow.flap();
    }

    function testExecDaiSecondWantBlocks() public {
        changeFlapper(address(linkFlapper));
        uint256 _marginalWant = marginalWant(LINK, address(linkMedianizer));
        vm.prank(PAUSE_PROXY); linkFlapper.file("want", _marginalWant * 101 / 100);
        vm.expectRevert("FlapperUniV2SwapOnly/insufficient-buy-amount");
        vow.flap();
    }

    function testExecDonationDai() public {
        deal(DAI, UNIV2_DAI_MKR_PAIR, GemLike(DAI).balanceOf(UNIV2_DAI_MKR_PAIR) * 1005 / 1000);
        // This will now sync the reserves before the swap
        doExec(address(flapper), MKR, UNIV2_DAI_MKR_PAIR);
    }

    function testExecDonationGem() public {
        deal(MKR, UNIV2_DAI_MKR_PAIR, GemLike(MKR).balanceOf(UNIV2_DAI_MKR_PAIR) * 1005 / 1000);
        // This will now sync the reserves before the swap
        doExec(address(flapper), MKR, UNIV2_DAI_MKR_PAIR);
    }
}