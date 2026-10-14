// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { BemHubErrors } from "../src/BemHubBase.sol";
import { BemHubFeeTreasury } from "../src/BemHubFeeTreasury.sol";
import { BemHubCircuitMarket } from "../src/BemHubCircuitMarket.sol";
import { BemHubMaterialMarket } from "../src/BemHubMaterialMarket.sol";
import { MockERC721, MockERC1155 } from "./BemHubMarket.t.sol";

/// @notice Fuzz：费率方向、精确付款、部分成交记账、资金守恒。
contract BemHubFuzzTest is Test {
    BemHubFeeTreasury internal treasury;
    BemHubCircuitMarket internal circuit;
    BemHubMaterialMarket internal material;
    MockERC721 internal nft;
    MockERC1155 internal mat;

    address internal owner = address(0xA11CE);
    address internal seller = address(0x5E11E7);
    address internal buyer = address(0xB0B);
    uint256 internal constant NAND = 0;

    function setUp() public {
        treasury = new BemHubFeeTreasury(owner);
        circuit = new BemHubCircuitMarket(owner, address(treasury));
        material = new BemHubMaterialMarket(owner, address(treasury));
        nft = new MockERC721();
        mat = new MockERC1155();
        vm.deal(seller, 1_000_000 ether);
        vm.deal(buyer, 1_000_000 ether);
        vm.startPrank(owner);
        circuit.setAllowedCircuitContract(address(nft), true);
        material.setAllowedMaterialContract(address(mat), true);
        material.setAllowedMaterialId(address(mat), NAND, true);
        treasury.setAllowedMarket(address(circuit), true);
        treasury.setAllowedMarket(address(material), true);
        vm.stopPrank();
    }

    /// 费率公式必须恰好是 price × 1%（向下取整），且不超过 MAX_FEE_BPS 口径。
    function testFuzzTakerFeeIsExactlyOnePercent(uint96 priceSeed) public view {
        uint256 price = bound(uint256(priceSeed), 1, 1_000_000 ether);
        assertEq(circuit.calculateTakerFee(price), (price * 100) / 10_000);
        assertEq(material.calculateTakerFee(price), (price * 100) / 10_000);
        assertLe(circuit.calculateTakerFee(price), (price * 200) / 10_000, "fee must stay under governance cap");
    }

    /// 治理允许 0–200 bps：任意费率都只能按实际成交额计算，不能写死 1%。
    function testFuzzTakerFeeFormulaAcrossGovernanceRange(uint96 amountSeed, uint16 feeSeed) public {
        uint256 amount = bound(uint256(amountSeed), 1, 1_000_000 ether);
        uint16 feeBps = uint16(bound(uint256(feeSeed), 0, 200));
        vm.startPrank(owner);
        circuit.setTakerFeeBps(feeBps);
        material.setTakerFeeBps(feeBps);
        vm.stopPrank();
        assertEq(circuit.calculateTakerFee(amount), (amount * feeBps) / 10_000);
        assertEq(material.calculateTakerFee(amount), (amount * feeBps) / 10_000);
    }

    /// Circuit：任意价格下，买家付 price+fee、卖家收 price、Treasury 收 fee，三方总额守恒。
    function testFuzzCircuitPaymentConservation(uint96 priceSeed) public {
        uint256 price = bound(uint256(priceSeed), 1, 1_000 ether);
        nft.mint(seller, 1);
        vm.prank(seller);
        nft.setApprovalForAll(address(circuit), true);
        vm.prank(seller);
        uint256 orderId = circuit.createCircuitListing(address(nft), 1, price, 0);

        uint256 fee = circuit.calculateTakerFee(price);
        uint256 sellerBefore = seller.balance;
        uint256 buyerBefore = buyer.balance;

        vm.prank(buyer);
        circuit.fillCircuitListing{ value: price + fee }(orderId, price, 100, 0);

        assertEq(seller.balance - sellerBefore, price, "seller gets full price");
        assertEq(buyerBefore - buyer.balance, price + fee, "buyer pays price + 1%");
        assertEq(treasury.protocolFeeReceived(), fee, "treasury gets exactly 1%");
        assertEq(nft.ownerOf(1), buyer);
    }

    /// Material SELL：任意 单价×数量 与任意部分成交量，记账与守恒都必须成立。
    function testFuzzMaterialSellPartialFill(uint96 priceSeed, uint32 qtySeed, uint32 fillSeed) public {
        uint256 price = bound(uint256(priceSeed), 1, 1_000 ether);
        uint256 qty = bound(uint256(qtySeed), 1, 1_000);
        uint256 fill = bound(uint256(fillSeed), 1, qty);

        mat.mint(seller, NAND, qty);
        vm.startPrank(seller);
        mat.setApprovalForAll(address(material), true);
        uint256 orderId = material.createMaterialSell(address(mat), NAND, price, qty, 0);
        vm.stopPrank();

        uint256 value = price * fill;
        uint256 fee = material.calculateTakerFee(value);
        uint256 sellerBefore = seller.balance;

        vm.prank(buyer);
        material.fillMaterialOrder{ value: value + fee }(orderId, fill, price, 100, 0);

        assertEq(seller.balance - sellerBefore, value, "seller gets full trade value");
        assertEq(treasury.protocolFeeReceived(), fee);
        assertEq(mat.balanceOf(buyer, NAND), fill);
        assertEq(mat.balanceOf(seller, NAND), qty - fill);
        assertEq(material.getOrder(orderId).remainingQuantity, qty - fill, "remaining accounting");
    }

    /// Material BUY：Maker escrow 记账必须精确，Taker 卖家从成交额里承担 1%。
    function testFuzzMaterialBuyPartialFillEscrow(uint96 priceSeed, uint32 qtySeed, uint32 fillSeed) public {
        uint256 price = bound(uint256(priceSeed), 1, 1_000 ether);
        uint256 qty = bound(uint256(qtySeed), 1, 1_000);
        uint256 fill = bound(uint256(fillSeed), 1, qty);

        mat.mint(seller, NAND, qty);
        vm.prank(seller);
        mat.setApprovalForAll(address(material), true);

        uint256 escrow = price * qty;
        uint256 buyerBefore = buyer.balance;
        vm.prank(buyer);
        uint256 orderId = material.createMaterialBuy{ value: escrow }(address(mat), NAND, price, qty, 0);
        assertEq(buyerBefore - buyer.balance, escrow, "full escrow locked");
        assertEq(material.totalEscrowed(), escrow);

        uint256 value = price * fill;
        uint256 fee = material.calculateTakerFee(value);
        uint256 sellerBefore = seller.balance;

        vm.prank(seller);
        material.fillMaterialOrder(orderId, fill, price, 100, 0);

        assertEq(seller.balance - sellerBefore, value - fee, "taker seller bears 1%");
        assertEq(treasury.protocolFeeReceived(), fee);
        assertEq(material.totalEscrowed(), escrow - value, "escrow decrements by trade value only");
        assertEq(material.remainingEscrow(orderId), escrow - value);
        assertEq(mat.balanceOf(buyer, NAND), fill);
    }

    /// 精确付款：只要不是一分不差就必须 revert。
    function testFuzzExactPaymentIsEnforced(uint96 priceSeed, uint96 deltaSeed) public {
        uint256 price = bound(uint256(priceSeed), 1, 1_000 ether);
        nft.mint(seller, 2);
        vm.prank(seller);
        nft.setApprovalForAll(address(circuit), true);
        vm.prank(seller);
        uint256 orderId = circuit.createCircuitListing(address(nft), 2, price, 0);
        uint256 required = price + circuit.calculateTakerFee(price);

        uint256 delta = bound(uint256(deltaSeed), 1, 1 ether);
        if (required > delta) {
            vm.prank(buyer);
            vm.expectRevert(BemHubErrors.IncorrectPayment.selector);
            circuit.fillCircuitListing{ value: required - delta }(orderId, price, 100, 0);
        }
        vm.prank(buyer);
        vm.expectRevert(BemHubErrors.IncorrectPayment.selector);
        circuit.fillCircuitListing{ value: required + delta }(orderId, price, 100, 0);
    }
}
