// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * 安全审计新增文件（不是项目原有测试，不改动 src/ 下任何生产代码）。
 *
 * 动机：原 `BemHubInvariant.t.sol` 的 handler 只暴露三个入口
 * （createBuy / fillBuy / cancelBuy），也就是**只驱动 Material 的 BUY 侧**。
 * 以下路径在 invariant 层面完全没有被随机序列覆盖过：
 *   - Material SELL 的挂单 / 部分成交 / 撤单 / 过期
 *   - Material 过期清算（permissionless expireOrder）
 *   - Circuit 的全部路径（create / fill / cancel / permissionless expire）
 *   - 「同一份资产不能同时被两处花掉」这种跨路径守恒
 *
 * 本文件用混合随机序列去攻这些不变量：
 *   INV-A  Circuit 市场永远不留存 BNB（没有 escrow，就不该有余额）
 *   INV-B  Material 合约余额与 totalEscrowed 账本**完全相等**（不是 >=）
 *   INV-C  totalEscrowed == 所有 OPEN BUY 单剩余额度之和
 *   INV-D  不存在 OPEN 且 remaining == 0 的订单（两个市场、两侧）
 *   INV-E  Treasury 累计收入 == 所有成功 Fill 的手续费之和（挂单/撤单/过期不得产生收入）
 *   INV-F  NFT 总量守恒：6 枚 token 必须始终在 4 个已知 actor 之一手里
 *   INV-G  Material 单位守恒：4 个 actor 的 NAND 余额之和恒等于初始铸造量
 *
 * 运行：
 *   forge test --match-path test/AUDIT-AdversarialInvariant.t.sol
 * 建议抬高迭代（不要用默认值）：
 *   FOUNDRY_INVARIANT_RUNS=1500 FOUNDRY_INVARIANT_DEPTH=60 \
 *   FOUNDRY_INVARIANT_FAIL_ON_REVERT=true forge test --match-path test/AUDIT-AdversarialInvariant.t.sol
 */

import { Test } from "forge-std/Test.sol";
import { BemHubFeeTreasury } from "../src/BemHubFeeTreasury.sol";
import { BemHubCircuitMarket } from "../src/BemHubCircuitMarket.sol";
import { BemHubMaterialMarket } from "../src/BemHubMaterialMarket.sol";
import { MockERC721, MockERC1155 } from "./BemHubMarket.t.sol";

contract AdversarialHandler is Test {
    BemHubCircuitMarket internal circuit;
    BemHubMaterialMarket internal material;
    MockERC721 internal nft;
    MockERC1155 internal mat;

    uint256 internal constant NAND = 0;
    uint256 internal constant TOKEN_COUNT = 6;
    uint256 internal constant NAND_PER_ACTOR = 1_000;
    uint256 internal constant MAX_ORDERS = 24;

    address[4] internal actors;

    uint256[] public circuitIds;
    uint256[] public sellIds;
    uint256[] public buyIds;

    /// @dev 由 handler 自己累计的「应当已收手续费」，用来钉住 Treasury 的收入口径。
    uint256 public expectedFees;

    constructor(BemHubCircuitMarket c, BemHubMaterialMarket m, MockERC721 n, MockERC1155 t) {
        circuit = c;
        material = m;
        nft = n;
        mat = t;
        actors = [address(0xB1), address(0xB2), address(0xC1), address(0xC2)];
        for (uint256 i = 0; i < TOKEN_COUNT; i += 1) nft.mint(actors[i % 2], i + 1);
        for (uint256 i = 0; i < 4; i += 1) mat.mint(actors[i], NAND, NAND_PER_ACTOR);
    }

    function _actor(uint256 seed) internal view returns (address) { return actors[seed % 4]; }
    function _expiry(uint32 seed) internal view returns (uint64) {
        // 一半永不过期，一半是未来有效期；过期路径由 expire 入口单独驱动。
        return seed % 2 == 0 ? 0 : uint64(block.timestamp + bound(uint256(seed), 1, 5_000));
    }

    // ---------- Circuit ----------

    function circuitCreate(uint256 actorSeed, uint256 tokenSeed, uint96 priceSeed, uint32 expireSeed) external {
        if (circuitIds.length >= MAX_ORDERS) return;
        address actor = _actor(actorSeed);
        uint256 tokenId = (tokenSeed % TOKEN_COUNT) + 1;
        if (nft.ownerOf(tokenId) != actor) return;
        if (circuit.activeListingOf(address(nft), tokenId) != 0) return;
        uint256 price = bound(uint256(priceSeed), 1, 10 ether);
        vm.prank(actor);
        circuitIds.push(circuit.createCircuitListing(address(nft), tokenId, price, _expiry(expireSeed)));
    }

    function circuitFill(uint256 orderSeed, uint256 actorSeed) external {
        if (circuitIds.length == 0) return;
        uint256 id = circuitIds[orderSeed % circuitIds.length];
        BemHubCircuitMarket.CircuitOrder memory o = circuit.getOrder(id);
        if (o.status != BemHubCircuitMarket.OrderStatus.OPEN) return;
        if (o.expiresAt != 0 && block.timestamp > o.expiresAt) return;
        address taker = _actor(actorSeed);
        if (taker == o.maker) return;
        uint256 fee = circuit.calculateTakerFee(o.price);
        // 必须留出 gas 余额：把余额刚好 deal 成付款额会让调用以 OutOfFunds 失败（测试脚手架问题，不是协议问题）。
        vm.deal(taker, o.price + fee + 1 ether);
        // 注意：maxFeeBps 必须**先**读进局部变量。若写成 fill{...}(..., circuit.takerFeeBps(), 0)，
        // 参数求值会先发起一次外部调用，把 vm.prank 消耗掉，导致真正调用者是 handler 自己。
        uint16 feeBps = circuit.takerFeeBps();
        vm.prank(taker);
        circuit.fillCircuitListing{ value: o.price + fee }(id, o.price, feeBps, 0);
        expectedFees += fee;
    }

    function circuitCancel(uint256 orderSeed) external {
        if (circuitIds.length == 0) return;
        uint256 id = circuitIds[orderSeed % circuitIds.length];
        BemHubCircuitMarket.CircuitOrder memory o = circuit.getOrder(id);
        if (o.status != BemHubCircuitMarket.OrderStatus.OPEN) return;
        vm.prank(o.maker);
        circuit.cancelCircuitListing(id);
    }

    /// @dev permissionless 清算：只在 A（过期）或 B（NFT 已不在 maker 手上）成立时才调用，避免误 revert。
    function circuitExpire(uint256 orderSeed) external {
        if (circuitIds.length == 0) return;
        uint256 id = circuitIds[orderSeed % circuitIds.length];
        BemHubCircuitMarket.CircuitOrder memory o = circuit.getOrder(id);
        if (o.status != BemHubCircuitMarket.OrderStatus.OPEN) return;
        bool expired = o.expiresAt != 0 && block.timestamp > o.expiresAt;
        bool stale = nft.ownerOf(o.tokenId) != o.maker;
        if (!expired && !stale) return;
        circuit.expireCircuitListing(id);
    }

    // ---------- Material SELL ----------

    function materialSell(uint256 actorSeed, uint96 priceSeed, uint32 qtySeed, uint32 expireSeed) external {
        if (sellIds.length >= MAX_ORDERS) return;
        address actor = _actor(actorSeed);
        uint256 qty = bound(uint256(qtySeed), 1, 50);
        if (mat.balanceOf(actor, NAND) < qty) return;
        uint256 price = bound(uint256(priceSeed), 1, 10 ether);
        vm.prank(actor);
        sellIds.push(material.createMaterialSell(address(mat), NAND, price, qty, _expiry(expireSeed)));
    }

    function materialFillSell(uint256 orderSeed, uint256 actorSeed, uint32 qtySeed) external {
        if (sellIds.length == 0) return;
        uint256 id = sellIds[orderSeed % sellIds.length];
        BemHubMaterialMarket.MaterialOrder memory o = material.getOrder(id);
        if (o.status != BemHubMaterialMarket.OrderStatus.OPEN) return;
        if (o.expiresAt != 0 && block.timestamp > o.expiresAt) return;
        address taker = _actor(actorSeed);
        if (taker == o.maker) return;
        // 卖家可能已经把同一批单位卖给了别人的买单 —— 余额不够就跳过，别把这个算成协议 revert。
        uint256 available = mat.balanceOf(o.maker, NAND);
        uint256 cap = o.remainingQuantity > 10 ? 10 : o.remainingQuantity;
        if (cap > available) cap = available;
        if (cap == 0) return;
        uint256 qty = bound(uint256(qtySeed), 1, cap);
        uint256 tradeValue = o.pricePerUnit * qty;
        uint256 fee = material.calculateTakerFee(tradeValue);
        vm.deal(taker, tradeValue + fee + 1 ether);
        uint16 feeBps = material.takerFeeBps();
        vm.prank(taker);
        material.fillMaterialOrder{ value: tradeValue + fee }(id, qty, o.pricePerUnit, feeBps, 0);
        expectedFees += fee;
    }

    function materialCancelSell(uint256 orderSeed) external {
        if (sellIds.length == 0) return;
        uint256 id = sellIds[orderSeed % sellIds.length];
        BemHubMaterialMarket.MaterialOrder memory o = material.getOrder(id);
        if (o.status != BemHubMaterialMarket.OrderStatus.OPEN) return;
        vm.prank(o.maker);
        material.cancelMaterialOrder(id);
    }

    // ---------- Material BUY ----------

    function materialBuy(uint256 actorSeed, uint96 priceSeed, uint32 qtySeed, uint32 expireSeed) external {
        if (buyIds.length >= MAX_ORDERS) return;
        address actor = _actor(actorSeed);
        uint256 price = bound(uint256(priceSeed), 1, 1 ether);
        uint256 qty = bound(uint256(qtySeed), 1, 20);
        vm.deal(actor, price * qty + 1 ether);
        vm.prank(actor);
        buyIds.push(material.createMaterialBuy{ value: price * qty }(address(mat), NAND, price, qty, _expiry(expireSeed)));
    }

    function materialFillBuy(uint256 orderSeed, uint256 actorSeed, uint32 qtySeed) external {
        if (buyIds.length == 0) return;
        uint256 id = buyIds[orderSeed % buyIds.length];
        BemHubMaterialMarket.MaterialOrder memory o = material.getOrder(id);
        if (o.status != BemHubMaterialMarket.OrderStatus.OPEN) return;
        if (o.expiresAt != 0 && block.timestamp > o.expiresAt) return;
        address taker = _actor(actorSeed);
        if (taker == o.maker) return;
        uint256 available = mat.balanceOf(taker, NAND);
        uint256 cap = o.remainingQuantity > 10 ? 10 : o.remainingQuantity;
        if (cap > available) cap = available;
        if (cap == 0) return;
        uint256 qty = bound(uint256(qtySeed), 1, cap);
        uint256 tradeValue = o.pricePerUnit * qty;
        uint256 fee = material.calculateTakerFee(tradeValue);
        uint16 feeBps = material.takerFeeBps();
        vm.prank(taker);
        material.fillMaterialOrder{ value: 0 }(id, qty, o.pricePerUnit, feeBps, 0);
        expectedFees += fee;
    }

    function materialCancelBuy(uint256 orderSeed) external {
        if (buyIds.length == 0) return;
        uint256 id = buyIds[orderSeed % buyIds.length];
        BemHubMaterialMarket.MaterialOrder memory o = material.getOrder(id);
        if (o.status != BemHubMaterialMarket.OrderStatus.OPEN) return;
        vm.prank(o.maker);
        material.cancelMaterialOrder(id);
    }

    function materialExpire(uint256 orderSeed) external {
        if (orderSeed % 2 == 0) {
            if (sellIds.length == 0) return;
            uint256 id = sellIds[orderSeed % sellIds.length];
            if (!_isExpirable(id)) return;
            material.expireOrder(id);
        } else {
            if (buyIds.length == 0) return;
            uint256 id = buyIds[orderSeed % buyIds.length];
            if (!_isExpirable(id)) return;
            material.expireOrder(id);
        }
    }

    function _isExpirable(uint256 orderId) private view returns (bool) {
        BemHubMaterialMarket.MaterialOrder memory o = material.getOrder(orderId);
        return o.status == BemHubMaterialMarket.OrderStatus.OPEN && o.expiresAt != 0 && block.timestamp > o.expiresAt;
    }

    // ---------- 给 invariant 用的读取器 ----------

    function openBuyEscrowSum() external view returns (uint256 sum) {
        for (uint256 i = 0; i < buyIds.length; i += 1) {
            BemHubMaterialMarket.MaterialOrder memory o = material.getOrder(buyIds[i]);
            if (o.status == BemHubMaterialMarket.OrderStatus.OPEN) sum += o.remainingQuantity * o.pricePerUnit;
        }
    }

    function hasOpenOrderWithZeroRemaining() external view returns (bool bad) {
        for (uint256 i = 0; i < buyIds.length; i += 1) {
            BemHubMaterialMarket.MaterialOrder memory o = material.getOrder(buyIds[i]);
            if (o.status == BemHubMaterialMarket.OrderStatus.OPEN && o.remainingQuantity == 0) return true;
        }
        for (uint256 i = 0; i < sellIds.length; i += 1) {
            BemHubMaterialMarket.MaterialOrder memory o = material.getOrder(sellIds[i]);
            if (o.status == BemHubMaterialMarket.OrderStatus.OPEN && o.remainingQuantity == 0) return true;
        }
        for (uint256 i = 0; i < circuitIds.length; i += 1) {
            BemHubCircuitMarket.CircuitOrder memory o = circuit.getOrder(circuitIds[i]);
            if (o.status == BemHubCircuitMarket.OrderStatus.OPEN && o.price == 0) return true;
        }
    }

    function actorCount() external view returns (uint256) { return actors.length; }
    function actorAt(uint256 i) external view returns (address) { return actors[i]; }
    function materialUnits() external view returns (uint256 sum) {
        for (uint256 i = 0; i < actors.length; i += 1) sum += mat.balanceOf(actors[i], NAND);
    }
    function nftOwnedByKnownActor(uint256 tokenId) external view returns (bool) {
        address owner = nft.ownerOf(tokenId);
        for (uint256 i = 0; i < actors.length; i += 1) if (owner == actors[i]) return true;
        return false;
    }
}

contract AuditAdversarialInvariantTest is Test {
    BemHubFeeTreasury internal treasury;
    BemHubCircuitMarket internal circuit;
    BemHubMaterialMarket internal material;
    MockERC721 internal nft;
    MockERC1155 internal mat;
    AdversarialHandler internal handler;

    address internal owner = address(0xA11CE);
    uint256 internal constant NAND = 0;
    uint256 internal constant TOKEN_COUNT = 6;
    uint256 internal constant NAND_PER_ACTOR = 1_000;

    function setUp() public {
        treasury = new BemHubFeeTreasury(owner);
        circuit = new BemHubCircuitMarket(owner, address(treasury));
        material = new BemHubMaterialMarket(owner, address(treasury));
        nft = new MockERC721();
        mat = new MockERC1155();

        vm.startPrank(owner);
        circuit.setAllowedCircuitContract(address(nft), true);
        material.setAllowedMaterialContract(address(mat), true);
        material.setAllowedMaterialId(address(mat), NAND, true);
        treasury.setAllowedMarket(address(circuit), true);
        treasury.setAllowedMarket(address(material), true);
        vm.stopPrank();

        handler = new AdversarialHandler(circuit, material, nft, mat);
        for (uint256 i = 0; i < 4; i += 1) {
            address actor = handler.actorAt(i);
            vm.startPrank(actor);
            nft.setApprovalForAll(address(circuit), true);
            mat.setApprovalForAll(address(material), true);
            vm.stopPrank();
        }
        targetContract(address(handler));
    }

    /// INV-A：Circuit 是纯非托管市场，任何序列之后都不该留下一分钱。
    function invariant_A_circuitMarketNeverHoldsBnb() public view {
        assertEq(address(circuit).balance, 0, "circuit market trapped BNB");
    }

    /// INV-B：Material 的余额必须与 escrow 账本**完全相等**（精确付款，不产生灰尘）。
    function invariant_B_materialBalanceExactlyMatchesEscrowLedger() public view {
        assertEq(address(material).balance, material.totalEscrowed(), "material balance != escrow ledger");
    }

    /// INV-C：账本必须等于所有 OPEN BUY 单的剩余额度之和。
    function invariant_C_escrowLedgerMatchesOpenBuys() public view {
        assertEq(material.totalEscrowed(), handler.openBuyEscrowSum(), "escrow ledger drift");
    }

    /// INV-D：不存在 OPEN 却已经没有剩余量的订单。
    function invariant_D_noOpenOrderWithZeroRemaining() public view {
        assertFalse(handler.hasOpenOrderWithZeroRemaining(), "open order with zero remaining");
    }

    /// INV-E：Treasury 累计收入只能来自成功 Fill，挂单/撤单/过期一律不得产生收入。
    function invariant_E_treasuryRevenueOnlyFromFills() public view {
        assertEq(treasury.protocolFeeReceived(), handler.expectedFees(), "non-fill path changed revenue");
    }

    /// INV-F：NFT 守恒 —— 每枚 token 必须始终在已知 actor 手里（没被凭空销毁/转出协议外）。
    function invariant_F_nftsAreConserved() public view {
        for (uint256 tokenId = 1; tokenId <= TOKEN_COUNT; tokenId += 1) {
            assertTrue(handler.nftOwnedByKnownActor(tokenId), "nft left the known actor set");
        }
    }

    /// INV-G：Material 单位守恒 —— 4 个 actor 的 NAND 余额之和恒等于初始铸造量。
    function invariant_G_materialUnitsAreConserved() public view {
        assertEq(handler.materialUnits(), 4 * NAND_PER_ACTOR, "material units not conserved");
    }
}
