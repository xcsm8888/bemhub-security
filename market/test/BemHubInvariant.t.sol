// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { BemHubFeeTreasury } from "../src/BemHubFeeTreasury.sol";
import { BemHubMaterialMarket } from "../src/BemHubMaterialMarket.sol";
import { MockERC1155 } from "./BemHubMarket.t.sol";

/// @notice 只做有界的创建/成交/撤单，供 invariant 随机驱动。
contract MaterialHandler is Test {
    BemHubMaterialMarket internal market;
    MockERC1155 internal mat;
    address internal maker;
    address internal taker;
    uint256 internal constant NAND = 0;
    uint256[] public buyIds;
    uint256 public expectedProtocolFees;

    constructor(BemHubMaterialMarket m, MockERC1155 token, address maker_, address taker_) {
        market = m;
        mat = token;
        maker = maker_;
        taker = taker_;
    }

    function createBuy(uint96 priceSeed, uint32 qtySeed) external {
        uint256 price = bound(uint256(priceSeed), 1, 1 ether);
        uint256 qty = bound(uint256(qtySeed), 1, 20);
        vm.deal(maker, 1_000 ether);
        vm.prank(maker);
        buyIds.push(market.createMaterialBuy{ value: price * qty }(address(mat), NAND, price, qty, 0));
    }

    function fillBuy(uint256 idxSeed, uint32 qtySeed) external {
        if (buyIds.length == 0) return;
        uint256 orderId = buyIds[idxSeed % buyIds.length];
        MaterialOrderView memory o = viewOrder(orderId);
        if (o.status != 1 || o.remaining == 0) return;
        uint256 qty = bound(uint256(qtySeed), 1, o.remaining > 5 ? 5 : o.remaining);
        vm.prank(taker);
        market.fillMaterialOrder(orderId, qty, o.price, 100, 0);
        expectedProtocolFees += (qty * o.price * market.takerFeeBps()) / 10_000;
    }

    function cancelBuy(uint256 idxSeed) external {
        if (buyIds.length == 0) return;
        uint256 orderId = buyIds[idxSeed % buyIds.length];
        MaterialOrderView memory o = viewOrder(orderId);
        if (o.status != 1) return;
        vm.prank(maker);
        market.cancelMaterialOrder(orderId);
    }

    struct MaterialOrderView {
        uint256 price;
        uint256 remaining;
        uint8 status;
    }

    function viewOrder(uint256 orderId) public view returns (MaterialOrderView memory out) {
        BemHubMaterialMarket.MaterialOrder memory o = market.getOrder(orderId);
        out = MaterialOrderView({ price: o.pricePerUnit, remaining: o.remainingQuantity, status: uint8(o.status) });
    }

    /// @notice 所有仍然 OPEN 的 BUY 单，其剩余 escrow 之和。
    function openBuyEscrowSum() external view returns (uint256 sum) {
        for (uint256 i = 0; i < buyIds.length; i += 1) {
            MaterialOrderView memory o = viewOrder(buyIds[i]);
            if (o.status == 1) sum += o.remaining * o.price;
        }
    }

    function buyIdCount() external view returns (uint256) {
        return buyIds.length;
    }
}

contract BemHubInvariantTest is Test {
    BemHubFeeTreasury internal treasury;
    BemHubMaterialMarket internal material;
    MockERC1155 internal mat;
    MaterialHandler internal handler;

    address internal owner = address(0xA11CE);
    address internal maker = address(0xB0B);
    address internal taker = address(0x5E11E7);
    uint256 internal constant NAND = 0;

    function setUp() public {
        treasury = new BemHubFeeTreasury(owner);
        material = new BemHubMaterialMarket(owner, address(treasury));
        mat = new MockERC1155();
        vm.startPrank(owner);
        material.setAllowedMaterialContract(address(mat), true);
        material.setAllowedMaterialId(address(mat), NAND, true);
        treasury.setAllowedMarket(address(material), true);
        vm.stopPrank();

        handler = new MaterialHandler(material, mat, maker, taker);
        // taker 需要真实持有 Material 才能吃 BUY 单
        mat.mint(taker, NAND, 1_000);
        vm.prank(taker);
        mat.setApprovalForAll(address(material), true);
        targetContract(address(handler));
    }

    /// 核心不变量：账本 totalEscrowed 必须等于全部 OPEN BUY 单剩余额度之和。
    function invariant_escrowLedgerMatchesOpenBuyOrders() public view {
        assertEq(material.totalEscrowed(), handler.openBuyEscrowSum(), "escrow ledger drift");
    }

    /// 合约余额必须始终覆盖应退 escrow（不能拿用户的钱去付别人）。
    function invariant_contractBalanceCoversEscrow() public view {
        assertGe(address(material).balance, material.totalEscrowed(), "balance below escrow");
    }

    /**
     * Treasury 账本一致性。
     *
     * ⚠ **这是测试模型下的不变量，不是链上恒等式。**
     * 真实链上 `selfdestruct` / 强制转账（forced BNB）可以绕开 `receive()`，
     * 因此 `balance == protocolFeeReceived + externalDonation` 在任意时刻都**不保证成立**
     * （余额可能凭空多出未记账的 BNB）。在本 mock 环境里没有强制转账路径，
     * 所以这里可以断言等号；文档与后台展示**不得**把它当作协议定义。
     *
     * 平台 Revenue 的权威来源始终是 `FeeCollected` 事件（`bemhub_fee_events` 表）；
     * Treasury 的实时余额只是"资产余额"，不等于累计 Revenue。
     */
    function invariant_treasuryAccountingConsistent() public view {
        assertEq(address(treasury).balance, treasury.protocolFeeReceived() + treasury.externalDonation());
    }

    /// 任意创建/撤单序列都不能增加收入；累计收入只能等于 Handler 成功 Fill 的手续费和。
    function invariant_protocolRevenueComesOnlyFromSuccessfulFills() public view {
        assertEq(treasury.protocolFeeReceived(), handler.expectedProtocolFees(), "non-fill path changed revenue");
    }

    /// 不能存在 remaining 为 0 却仍是 OPEN 的订单。
    function invariant_noOpenOrderWithZeroRemaining() public view {
        uint256 count = handler.buyIdCount();
        for (uint256 i = 0; i < count; i += 1) {
            MaterialHandler.MaterialOrderView memory o = handler.viewOrder(handler.buyIds(i));
            if (o.status == 1) assertGt(o.remaining, 0, "open order with zero remaining");
        }
    }
}
