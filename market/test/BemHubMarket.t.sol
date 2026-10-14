// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Test } from "forge-std/Test.sol";
import { BemHubErrors } from "../src/BemHubBase.sol";
import { BemHubFeeTreasury } from "../src/BemHubFeeTreasury.sol";
import { BemHubCircuitMarket } from "../src/BemHubCircuitMarket.sol";
import { BemHubMaterialMarket } from "../src/BemHubMaterialMarket.sol";

contract MockERC721 {
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => address) public getApproved;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    function mint(address to, uint256 id) external { ownerOf[id] = to; }
    function approve(address spender, uint256 id) external { getApproved[id] = spender; }
    function setApprovalForAll(address operator, bool ok) external { isApprovedForAll[msg.sender][operator] = ok; }
    function safeTransferFrom(address from, address to, uint256 id) external {
        require(ownerOf[id] == from, "not owner");
        require(msg.sender == from || isApprovedForAll[from][msg.sender] || getApproved[id] == msg.sender, "not approved");
        ownerOf[id] = to;
        getApproved[id] = address(0);
    }
}

/// @dev Material 已链上确认为 ERC-1155，故 mock 只提供 balanceOf / isApprovedForAll / safeTransferFrom。
contract MockERC1155 {
    mapping(uint256 => mapping(address => uint256)) internal _balance;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    function mint(address to, uint256 id, uint256 amount) external { _balance[id][to] += amount; }
    function setApprovalForAll(address operator, bool ok) external { isApprovedForAll[msg.sender][operator] = ok; }
    /// @dev ERC-1155 标准参数顺序是 (account, id)：必须显式实现，不能靠 public mapping 的自动 getter。
    function balanceOf(address account, uint256 id) external view returns (uint256) { return _balance[id][account]; }
    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes calldata) external {
        require(msg.sender == from || isApprovedForAll[from][msg.sender], "not approved");
        require(_balance[id][from] >= amount, "balance");
        _balance[id][from] -= amount;
        _balance[id][to] += amount;
    }
}

contract BemHubMarketTest is Test {
    BemHubFeeTreasury internal treasury;
    BemHubCircuitMarket internal circuit;
    BemHubMaterialMarket internal material;
    MockERC721 internal nft;
    MockERC1155 internal mat;

    address internal owner = address(0xA11CE);
    address internal seller = address(0x5E11E7);
    address internal buyer = address(0xB0B);
    uint256 internal constant NAND = 0;
    uint256 internal constant LATCH = 1;

    function setUp() public {
        treasury = new BemHubFeeTreasury(owner);
        circuit = new BemHubCircuitMarket(owner, address(treasury));
        material = new BemHubMaterialMarket(owner, address(treasury));
        nft = new MockERC721();
        mat = new MockERC1155();
        vm.deal(seller, 1_000 ether);
        vm.deal(buyer, 1_000 ether);
        vm.startPrank(owner);
        circuit.setAllowedCircuitContract(address(nft), true);
        material.setAllowedMaterialContract(address(mat), true);
        material.setAllowedMaterialId(address(mat), NAND, true);
        material.setAllowedMaterialId(address(mat), LATCH, true);
        // Treasury 只认白名单市场的协议费
        treasury.setAllowedMarket(address(circuit), true);
        treasury.setAllowedMarket(address(material), true);
        vm.stopPrank();
    }

    // ---------- 费率常量 ----------

    function testFeeModelConstants() public view {
        assertEq(circuit.MAKER_FEE_BPS(), 0, "maker must be 0%");
        assertEq(circuit.TAKER_FEE_BPS_DEFAULT(), 100, "taker default 1%");
        assertEq(circuit.MAX_FEE_BPS(), 200, "max fee bps is 2%");
        assertEq(material.takerFeeBps(), 100);
        assertEq(circuit.calculateTakerFee(1 ether), 0.01 ether);
    }

    // ---------- Circuit：固定价挂卖，买卖双方与 Treasury 各拿多少 ----------

    function testCircuitSellMakerGetsFullPriceBuyerPaysOnePercent() public {
        nft.mint(seller, 1);
        vm.prank(seller);
        nft.setApprovalForAll(address(circuit), true);
        vm.prank(seller);
        uint256 orderId = circuit.createCircuitListing(address(nft), 1, 1 ether, 0);

        // 挂单期间 NFT 仍在卖家钱包（非托管）
        assertEq(nft.ownerOf(1), seller);

        uint256 sellerBefore = seller.balance;
        vm.prank(buyer);
        circuit.fillCircuitListing{ value: 1.01 ether }(orderId, 1 ether, 100, 0);

        assertEq(nft.ownerOf(1), buyer, "nft moved to buyer");
        assertEq(seller.balance, sellerBefore + 1 ether, "seller receives full listing price");
        assertEq(address(treasury).balance, 0.01 ether, "treasury collects 1%");
    }

    function testCircuitRequiresExactPayment() public {
        nft.mint(seller, 2);
        vm.prank(seller);
        nft.setApprovalForAll(address(circuit), true);
        vm.prank(seller);
        uint256 orderId = circuit.createCircuitListing(address(nft), 2, 1 ether, 0);

        vm.prank(buyer);
        vm.expectRevert(BemHubErrors.IncorrectPayment.selector);
        circuit.fillCircuitListing{ value: 1.01 ether - 1 }(orderId, 1 ether, 100, 0);
        vm.prank(buyer);
        vm.expectRevert(BemHubErrors.IncorrectPayment.selector);
        circuit.fillCircuitListing{ value: 1.01 ether + 1 }(orderId, 1 ether, 100, 0);
        vm.prank(buyer);
        circuit.fillCircuitListing{ value: 1.01 ether }(orderId, 1 ether, 100, 0);
        assertEq(nft.ownerOf(2), buyer, "exact value succeeds");
    }

    function testCircuitDuplicateListingBlocked() public {
        nft.mint(seller, 3);
        vm.startPrank(seller);
        nft.setApprovalForAll(address(circuit), true);
        circuit.createCircuitListing(address(nft), 3, 1 ether, 0);
        vm.expectRevert(BemHubErrors.DuplicateActiveListing.selector);
        circuit.createCircuitListing(address(nft), 3, 2 ether, 0);
        vm.stopPrank();
    }

    function testCircuitCannotListSomeoneElsesNFT() public {
        nft.mint(seller, 4);
        vm.prank(buyer);
        vm.expectRevert(BemHubErrors.NotOwnerOfNFT.selector);
        circuit.createCircuitListing(address(nft), 4, 1 ether, 0);
    }

    function testCircuitStaleOwnershipBlocksFill() public {
        nft.mint(seller, 5);
        vm.startPrank(seller);
        nft.setApprovalForAll(address(circuit), true);
        uint256 orderId = circuit.createCircuitListing(address(nft), 5, 1 ether, 0);
        nft.safeTransferFrom(seller, buyer, 5); // 挂单后转走
        vm.stopPrank();
        vm.prank(buyer);
        vm.expectRevert(BemHubErrors.NotOwnerOfNFT.selector);
        circuit.fillCircuitListing{ value: 1.01 ether }(orderId, 1 ether, 100, 0);
    }

    function testCircuitStaleApprovalBlocksFill() public {
        nft.mint(seller, 6);
        vm.startPrank(seller);
        nft.setApprovalForAll(address(circuit), true);
        uint256 orderId = circuit.createCircuitListing(address(nft), 6, 1 ether, 0);
        nft.setApprovalForAll(address(circuit), false); // 撤销授权
        vm.stopPrank();
        vm.prank(buyer);
        vm.expectRevert(BemHubErrors.MarketNotApproved.selector);
        circuit.fillCircuitListing{ value: 1.01 ether }(orderId, 1 ether, 100, 0);
    }

    function testCircuitPriceAndFeeProtection() public {
        nft.mint(seller, 7);
        vm.startPrank(seller);
        nft.setApprovalForAll(address(circuit), true);
        uint256 orderId = circuit.createCircuitListing(address(nft), 7, 1 ether, 0);
        vm.stopPrank();

        vm.prank(buyer);
        vm.expectRevert(BemHubErrors.PriceChanged.selector);
        circuit.fillCircuitListing{ value: 1.01 ether }(orderId, 1.5 ether, 100, 0);

        vm.prank(buyer);
        vm.expectRevert(BemHubErrors.IncorrectPayment.selector);
        circuit.fillCircuitListing{ value: 1 ether }(orderId, 1 ether, 100, 0);

        // Admin 把费率提到 2% 后，签名时 maxFeeBps=100 的用户交易必须失败
        vm.prank(owner);
        circuit.setTakerFeeBps(200);
        vm.prank(buyer);
        vm.expectRevert(BemHubErrors.FeeTooHigh.selector);
        circuit.fillCircuitListing{ value: 1.02 ether }(orderId, 1 ether, 100, 0);
    }

    function testCircuitAdminCannotExceedFeeCap() public {
        vm.prank(owner);
        vm.expectRevert(BemHubErrors.FeeTooLarge.selector);
        circuit.setTakerFeeBps(201);
    }

    function testCircuitCancelIsFreeAndOnlyMaker() public {
        nft.mint(seller, 8);
        vm.startPrank(seller);
        nft.setApprovalForAll(address(circuit), true);
        uint256 orderId = circuit.createCircuitListing(address(nft), 8, 1 ether, 0);
        vm.stopPrank();

        vm.prank(buyer);
        vm.expectRevert(BemHubErrors.NotOrderMaker.selector);
        circuit.cancelCircuitListing(orderId);

        uint256 before = seller.balance;
        vm.prank(seller);
        circuit.cancelCircuitListing(orderId);
        assertEq(seller.balance, before, "cancel is free (gas only)");
        assertEq(circuit.activeListingOf(address(nft), 8), 0, "listing slot released after cancel");
    }

    function testCircuitRejectsUnlistedAsset() public {
        MockERC721 other = new MockERC721();
        other.mint(seller, 1);
        vm.prank(seller);
        vm.expectRevert(BemHubErrors.NotAllowedAsset.selector);
        circuit.createCircuitListing(address(other), 1, 1 ether, 0);
    }

    // ---------- Material SELL：卖家拿全额，买家额外付 1% ----------

    function testMaterialSellPartialFill() public {
        mat.mint(seller, NAND, 100);
        vm.startPrank(seller);
        mat.setApprovalForAll(address(material), true);
        uint256 orderId = material.createMaterialSell(address(mat), NAND, 0.04 ether, 100, 0);
        vm.stopPrank();
        // 挂单期间资产仍在卖家钱包
        assertEq(mat.balanceOf(seller, NAND), 100);

        uint256 sellerBefore = seller.balance;
        vm.prank(buyer);
        material.fillMaterialOrder{ value: 20 * 0.04 ether + (20 * 0.04 ether) / 100 }(orderId, 20, 0.04 ether, 100, 0);

        assertEq(mat.balanceOf(buyer, NAND), 20, "buyer received 20");
        assertEq(mat.balanceOf(seller, NAND), 80, "seller keeps 80");
        assertEq(seller.balance, sellerBefore + 20 * 0.04 ether, "seller receives full trade value");
        assertEq(address(treasury).balance, (20 * 0.04 ether) / 100, "treasury collects 1%");
        assertEq(material.getOrder(orderId).remainingQuantity, 80);
    }

    // ---------- Material BUY：escrow，卖家承担 1% ----------

    function testMaterialBuyPartialFillThenCancelRefundsEscrow() public {
        mat.mint(seller, LATCH, 100);
        vm.prank(seller);
        mat.setApprovalForAll(address(material), true);

        uint256 escrow = 100 * 0.04 ether;
        vm.prank(buyer);
        uint256 orderId = material.createMaterialBuy{ value: escrow }(address(mat), LATCH, 0.04 ether, 100, 0);
        assertEq(material.totalEscrowed(), escrow);

        uint256 sellerBefore = seller.balance;
        uint256 value = 30 * 0.04 ether;
        vm.prank(seller);
        material.fillMaterialOrder(orderId, 30, 0.04 ether, 100, 0);

        assertEq(mat.balanceOf(buyer, LATCH), 30, "maker buyer received 30");
        assertEq(seller.balance, sellerBefore + value - value / 100, "taker seller receives value minus 1%");
        assertEq(address(treasury).balance, value / 100, "treasury collects 1%");
        assertEq(material.remainingEscrow(orderId), 70 * 0.04 ether);

        // 撤单：剩余 escrow 必须全额退回，且不收消费
        uint256 buyerBefore = buyer.balance;
        vm.prank(buyer);
        material.cancelMaterialOrder(orderId);
        assertEq(buyer.balance, buyerBefore + 70 * 0.04 ether, "remaining escrow fully refunded");
        assertEq(material.totalEscrowed(), 0);
    }

    function testMaterialBuyRequiresFullEscrow() public {
        vm.prank(buyer);
        vm.expectRevert(BemHubErrors.InsufficientEscrow.selector);
        material.createMaterialBuy{ value: 1 ether }(address(mat), NAND, 0.04 ether, 100, 0);
    }

    function testMaterialSellRequiresApprovalAndBalance() public {
        mat.mint(seller, NAND, 10);
        vm.prank(seller);
        vm.expectRevert(BemHubErrors.MarketNotApproved.selector);
        material.createMaterialSell(address(mat), NAND, 0.04 ether, 10, 0);

        vm.prank(seller);
        mat.setApprovalForAll(address(material), true);
        vm.prank(seller);
        vm.expectRevert(BemHubErrors.InsufficientBalance.selector);
        material.createMaterialSell(address(mat), NAND, 0.04 ether, 11, 0);
    }

    function testMaterialPriceAndQuantityProtection() public {
        mat.mint(seller, NAND, 100);
        vm.startPrank(seller);
        mat.setApprovalForAll(address(material), true);
        uint256 orderId = material.createMaterialSell(address(mat), NAND, 0.04 ether, 100, 0);
        vm.stopPrank();

        vm.prank(buyer);
        vm.expectRevert(BemHubErrors.PriceChanged.selector);
        material.fillMaterialOrder{ value: 1 ether }(orderId, 10, 0.05 ether, 100, 0);

        vm.prank(buyer);
        vm.expectRevert(BemHubErrors.InvalidQuantity.selector);
        material.fillMaterialOrder{ value: 1 ether }(orderId, 101, 0.04 ether, 100, 0);
    }

    // ---------- Pause：能停下单与成交，但绝不能拦住撤单/退款 ----------

    function testPauseBlocksNewOrdersAndFillsButNotCancelOrRefund() public {
        mat.mint(seller, NAND, 100);
        vm.prank(seller);
        mat.setApprovalForAll(address(material), true);
        vm.prank(buyer);
        uint256 buyId = material.createMaterialBuy{ value: 100 * 0.04 ether }(address(mat), NAND, 0.04 ether, 100, 0);
        vm.prank(seller);
        uint256 sellId = material.createMaterialSell(address(mat), NAND, 0.04 ether, 100, 0);

        vm.prank(owner);
        material.setPaused(true, true);
        vm.prank(owner);
        circuit.setPaused(true, true);

        vm.prank(seller);
        vm.expectRevert(BemHubErrors.NewOrdersPaused.selector);
        material.createMaterialSell(address(mat), NAND, 0.04 ether, 1, 0);

        vm.prank(buyer);
        vm.expectRevert(BemHubErrors.FillsPaused.selector);
        material.fillMaterialOrder{ value: 0.04 ether + 0.0004 ether }(sellId, 1, 0.04 ether, 100, 0);

        // 暂停期间仍必须可以撤单与取回 escrow
        uint256 buyerBefore = buyer.balance;
        vm.prank(buyer);
        material.cancelMaterialOrder(buyId);
        assertEq(buyer.balance, buyerBefore + 100 * 0.04 ether, "escrow withdrawable while paused");

        vm.prank(seller);
        material.cancelMaterialOrder(sellId);
        assertEq(uint8(material.getOrder(sellId).status), uint8(BemHubMaterialMarket.OrderStatus.CANCELLED));
    }

    function testExpiryRefundsBuyEscrow() public {
        vm.prank(buyer);
        uint256 orderId = material.createMaterialBuy{ value: 10 * 0.04 ether }(address(mat), NAND, 0.04 ether, 10, uint64(block.timestamp + 100));
        vm.warp(block.timestamp + 101);
        uint256 before = buyer.balance;
        // 必须由第三方吃单：maker 自己吃自己的单会被 NotOrderMaker 拒绝
        vm.prank(address(0x7A4E7));
        vm.expectRevert(BemHubErrors.OrderExpired.selector);
        material.fillMaterialOrder(orderId, 1, 0.04 ether, 100, 0);
        assertEq(buyer.balance, before, "failed fill must not move funds");
        vm.prank(buyer);
        material.cancelMaterialOrder(orderId);
        assertEq(buyer.balance, before + 10 * 0.04 ether, "maker can always recover escrow");
        assertEq(material.totalEscrowed(), 0);
    }

    // ---------- Treasury ----------

    function testTreasuryNeverSwapsAndOnlyDistributesToConfiguredWallets() public {
        vm.deal(address(treasury), 1 ether);
        vm.prank(owner);
        vm.expectRevert(BemHubErrors.InvalidSplit.selector);
        treasury.distributeBNB(); // 未配置钱包时不允许打款

        address b = address(0xBB01);
        address f = address(0xFF01);
        address o = address(0x0101);
        vm.prank(owner);
        treasury.setSplits(b, f, o, 5000, 2000, 3000);
        vm.prank(owner);
        treasury.distributeBNB();
        assertEq(b.balance, 0.5 ether);
        assertEq(f.balance, 0.2 ether);
        assertEq(o.balance, 0.3 ether);
        assertEq(address(treasury).balance, 0, "treasury fully distributed");
    }

    function testTreasurySplitMustSumTo10000() public {
        vm.prank(owner);
        vm.expectRevert(BemHubErrors.InvalidSplit.selector);
        treasury.setSplits(address(1), address(2), address(3), 5000, 2000, 1000);
    }

    // ---------- 治理边界 ----------

    function testOnlyOwnerCanGovernAndNoAdminWithdrawOfUserFunds() public {
        vm.prank(buyer);
        vm.expectRevert();
        circuit.setTakerFeeBps(100);
        vm.prank(buyer);
        vm.expectRevert();
        material.setPaused(true, true);
        // 合约里根本不存在提款/提 NFT/delegatecall 入口：
        // 管理员能做的只有费率(<=2%)、白名单、Pause。
    }

    // ---------- 修正 1：Treasury 只收白名单市场的协议费 ----------

    function testTreasuryRejectsUnauthorizedDepositAndSeparatesDonations() public {
        address stranger = address(0xDEAD);
        vm.deal(stranger, 5 ether);

        vm.prank(stranger);
        vm.expectRevert(BemHubErrors.MarketNotAllowed.selector);
        treasury.depositFee{ value: 1 ether }();

        vm.deal(address(circuit), 1 ether);
        vm.deal(address(material), 1 ether);
        vm.prank(address(circuit));
        treasury.depositFee{ value: 0.3 ether }();
        vm.prank(address(material));
        treasury.depositFee{ value: 0.2 ether }();
        assertEq(treasury.protocolFeeReceived(), 0.5 ether, "only markets feed protocol revenue");
        assertEq(treasury.externalDonation(), 0);

        vm.prank(stranger);
        (bool ok, ) = address(treasury).call{ value: 1 ether }("");
        assertTrue(ok);
        assertEq(treasury.protocolFeeReceived(), 0.5 ether, "third-party transfer cannot pollute revenue");
        assertEq(treasury.externalDonation(), 1 ether, "counted as donation only");
    }

    function testRealTradeFeeLandsInProtocolRevenue() public {
        nft.mint(seller, 9);
        vm.startPrank(seller);
        nft.setApprovalForAll(address(circuit), true);
        uint256 orderId = circuit.createCircuitListing(address(nft), 9, 1 ether, 0);
        vm.stopPrank();
        vm.prank(buyer);
        circuit.fillCircuitListing{ value: 1.01 ether }(orderId, 1 ether, 100, 0);
        assertEq(treasury.protocolFeeReceived(), 0.01 ether);
        // ⚠ 测试模型下的不变量：真实链上 forced BNB（selfdestruct）可以让余额多出未记账的部分，
        //    所以这不是协议定义。平台 Revenue 只认 FeeCollected 事件。
        assertEq(address(treasury).balance, treasury.protocolFeeReceived() + treasury.externalDonation());
    }

    // ---------- 修正 2：Material ID 白名单 ----------

    function testMaterialIdWhitelist() public {
        mat.mint(seller, NAND, 5);
        mat.mint(seller, LATCH, 5);
        mat.mint(seller, 2, 5);
        vm.startPrank(seller);
        mat.setApprovalForAll(address(material), true);
        material.createMaterialSell(address(mat), NAND, 0.04 ether, 1, 0);
        material.createMaterialSell(address(mat), LATCH, 0.04 ether, 1, 0);
        vm.expectRevert(BemHubErrors.UnsupportedMaterialId.selector);
        material.createMaterialSell(address(mat), 2, 0.04 ether, 1, 0);
        vm.stopPrank();
    }

    // ---------- 修正 3：Material SELL 精确付款 ----------

    function testMaterialSellRequiresExactPayment() public {
        mat.mint(seller, NAND, 100);
        vm.startPrank(seller);
        mat.setApprovalForAll(address(material), true);
        uint256 orderId = material.createMaterialSell(address(mat), NAND, 0.04 ether, 100, 0);
        vm.stopPrank();
        uint256 exact = 10 * 0.04 ether + (10 * 0.04 ether) / 100;

        vm.prank(buyer);
        vm.expectRevert(BemHubErrors.IncorrectPayment.selector);
        material.fillMaterialOrder{ value: exact - 1 }(orderId, 10, 0.04 ether, 100, 0);
        vm.prank(buyer);
        vm.expectRevert(BemHubErrors.IncorrectPayment.selector);
        material.fillMaterialOrder{ value: exact + 1 }(orderId, 10, 0.04 ether, 100, 0);
        vm.prank(buyer);
        material.fillMaterialOrder{ value: exact }(orderId, 10, 0.04 ether, 100, 0);
        assertEq(mat.balanceOf(buyer, NAND), 10);
    }

    function testMaterialBuyTakerMustSendNoBnb() public {
        mat.mint(seller, NAND, 10);
        vm.prank(seller);
        mat.setApprovalForAll(address(material), true);
        vm.prank(buyer);
        uint256 orderId = material.createMaterialBuy{ value: 10 * 0.04 ether }(address(mat), NAND, 0.04 ether, 10, 0);
        vm.prank(seller);
        vm.expectRevert(BemHubErrors.IncorrectPayment.selector);
        material.fillMaterialOrder{ value: 1 }(orderId, 1, 0.04 ether, 100, 0);
    }

    // ---------- 修正 4：Circuit permissionless 失效清算 ----------

    function testCircuitPermissionlessExpiryReleasesSlot() public {
        nft.mint(seller, 10);
        vm.startPrank(seller);
        nft.setApprovalForAll(address(circuit), true);
        uint256 orderId = circuit.createCircuitListing(address(nft), 10, 1 ether, uint64(block.timestamp + 100));
        vm.stopPrank();

        vm.prank(buyer);
        vm.expectRevert(BemHubErrors.NotExpirable.selector);
        circuit.expireCircuitListing(orderId);

        vm.warp(block.timestamp + 101);
        vm.prank(buyer);
        circuit.expireCircuitListing(orderId);
        assertEq(circuit.activeListingOf(address(nft), 10), 0, "slot released");
        assertEq(nft.ownerOf(10), seller, "NFT untouched");
    }

    function testCircuitStaleListingReleasableWhenNftMoved() public {
        nft.mint(seller, 11);
        vm.startPrank(seller);
        nft.setApprovalForAll(address(circuit), true);
        uint256 orderId = circuit.createCircuitListing(address(nft), 11, 1 ether, 0);
        nft.safeTransferFrom(seller, buyer, 11);
        vm.stopPrank();

        vm.prank(buyer);
        vm.expectRevert(BemHubErrors.DuplicateActiveListing.selector);
        circuit.createCircuitListing(address(nft), 11, 2 ether, 0);

        vm.prank(address(0xDEAD));
        circuit.expireCircuitListing(orderId);

        // 新持有人要重新挂单，同样必须先授权（创建时校验授权，见硬化第 2 条）。
        vm.startPrank(buyer);
        nft.setApprovalForAll(address(circuit), true);
        circuit.createCircuitListing(address(nft), 11, 2 ether, 0);
        vm.stopPrank();
        assertEq(circuit.activeListingOf(address(nft), 11) != 0, true, "new owner can list now");
    }

    // ---------- 硬化 2：Circuit 创建挂单必须已授权（否则拒绝创建"注定无法成交"的挂单）----------

    function testCircuitCreateRequiresApproval() public {
        nft.mint(seller, 100);

        // 只有持有人、没有授权 → 直接拒绝创建
        vm.prank(seller);
        vm.expectRevert(BemHubErrors.MarketNotApproved.selector);
        circuit.createCircuitListing(address(nft), 100, 1 ether, 0);

        // 授权给了别人（不是本市场）→ 仍然拒绝
        vm.startPrank(seller);
        nft.setApprovalForAll(address(0xBEEF), true);
        vm.expectRevert(BemHubErrors.MarketNotApproved.selector);
        circuit.createCircuitListing(address(nft), 100, 1 ether, 0);
        vm.stopPrank();

        // setApprovalForAll 给本市场 → 允许
        vm.startPrank(seller);
        nft.setApprovalForAll(address(circuit), true);
        uint256 orderId = circuit.createCircuitListing(address(nft), 100, 1 ether, 0);
        assertGt(orderId, 0);
        vm.stopPrank();
    }

    function testCircuitCreateAllowsSingleTokenApprove() public {
        nft.mint(seller, 101);
        vm.startPrank(seller);
        nft.setApprovalForAll(address(circuit), false);
        nft.approve(address(circuit), 101); // 单枚 approve 也是合法授权路径
        uint256 orderId = circuit.createCircuitListing(address(nft), 101, 1 ether, 0);
        vm.stopPrank();
        assertGt(orderId, 0, "single-token approve is accepted");
    }

    // ---------- 硬化 3：Circuit 失效清算三种情形 + 恶意清算防护 ----------

    /// @dev 事件在测试里本地声明只是为了 expectEmit：签名一旦改动，topic 不匹配，测试立刻失败。
    event MaterialOrderCreated(uint256 indexed orderId, address indexed maker, address indexed material, uint256 materialId, uint8 side, uint256 price, uint256 quantity, uint64 expiresAt);
    event MaterialOrderCancelled(uint256 indexed orderId, address indexed maker, uint256 refunded);
    event MaterialOrderExpired(uint256 indexed orderId, address indexed maker, uint256 refunded);

    /// A：已过期 → 可清算，且 NFT / BNB / 手续费一分不动。
    function testExpireCleanupWhenExpiredMovesNothing() public {
        nft.mint(seller, 200);
        vm.startPrank(seller);
        nft.setApprovalForAll(address(circuit), true);
        uint256 orderId = circuit.createCircuitListing(address(nft), 200, 1 ether, uint64(block.timestamp + 10));
        vm.stopPrank();
        vm.warp(block.timestamp + 11);

        uint256 nftOwnerBefore = uint256(uint160(nft.ownerOf(200)));
        uint256 sellerBefore = seller.balance;
        uint256 treasuryBefore = treasury.protocolFeeReceived();
        uint256 contractBefore = address(circuit).balance;

        vm.prank(address(0xDEAD)); // 任何人都能清算
        circuit.expireCircuitListing(orderId);

        assertEq(uint8(circuit.getOrder(orderId).status), uint8(BemHubCircuitMarket.OrderStatus.EXPIRED));
        assertEq(circuit.activeListingOf(address(nft), 200), 0, "slot released");
        assertEq(uint256(uint160(nft.ownerOf(200))), nftOwnerBefore, "NFT untouched");
        assertEq(seller.balance, sellerBefore, "no BNB moved to seller");
        assertEq(treasury.protocolFeeReceived(), treasuryBefore, "no fee charged");
        assertEq(address(circuit).balance, contractBefore, "no BNB left in / taken by market");
    }

    /// B：NFT 已被转走 → 可清算。
    function testExpireCleanupWhenOwnershipChanged() public {
        nft.mint(seller, 201);
        vm.startPrank(seller);
        nft.setApprovalForAll(address(circuit), true);
        uint256 orderId = circuit.createCircuitListing(address(nft), 201, 1 ether, 0);
        nft.safeTransferFrom(seller, buyer, 201);
        vm.stopPrank();

        vm.prank(address(0xDEAD));
        circuit.expireCircuitListing(orderId);
        assertEq(uint8(circuit.getOrder(orderId).status), uint8(BemHubCircuitMarket.OrderStatus.EXPIRED));
        assertEq(circuit.activeListingOf(address(nft), 201), 0, "slot released");
        assertEq(nft.ownerOf(201), buyer, "NFT stays with its new owner");
    }

    /// C：Maker 撤销授权 → 可清算。
    function testExpireCleanupWhenApprovalRevoked() public {
        nft.mint(seller, 202);
        vm.startPrank(seller);
        nft.setApprovalForAll(address(circuit), true);
        uint256 orderId = circuit.createCircuitListing(address(nft), 202, 1 ether, 0);
        nft.setApprovalForAll(address(circuit), false);
        vm.stopPrank();

        vm.prank(address(0xDEAD));
        circuit.expireCircuitListing(orderId);
        assertEq(uint8(circuit.getOrder(orderId).status), uint8(BemHubCircuitMarket.OrderStatus.EXPIRED));
        assertEq(circuit.activeListingOf(address(nft), 202), 0, "slot released");
        assertEq(nft.ownerOf(202), seller, "NFT untouched");
    }

    /// 单枚 approve 被撤销（getApproved 清空）也属于 C。
    function testExpireCleanupWhenSingleApproveRevoked() public {
        nft.mint(seller, 203);
        vm.startPrank(seller);
        nft.approve(address(circuit), 203);
        uint256 orderId = circuit.createCircuitListing(address(nft), 203, 1 ether, 0);
        nft.approve(address(0), 203); // 撤销单枚授权
        vm.stopPrank();

        vm.prank(address(0xDEAD));
        circuit.expireCircuitListing(orderId);
        assertEq(uint8(circuit.getOrder(orderId).status), uint8(BemHubCircuitMarket.OrderStatus.EXPIRED));
    }

    /// 仍然有效的挂单**不能**被恶意清算：授权在、持有人对、没过期 → 一律 revert。
    function testValidListingCannotBeMaliciouslyExpired() public {
        nft.mint(seller, 204);
        vm.startPrank(seller);
        nft.setApprovalForAll(address(circuit), true);
        // 有效期设在很久以后：A 不成立
        uint256 orderId = circuit.createCircuitListing(address(nft), 204, 1 ether, uint64(block.timestamp + 365 days));
        vm.stopPrank();

        vm.prank(address(0xDEAD));
        vm.expectRevert(BemHubErrors.NotExpirable.selector);
        circuit.expireCircuitListing(orderId);

        // 状态与占位都没变，买家仍能按原价成交
        assertEq(uint8(circuit.getOrder(orderId).status), uint8(BemHubCircuitMarket.OrderStatus.OPEN));
        assertEq(circuit.activeListingOf(address(nft), 204), orderId);
        vm.prank(buyer);
        circuit.fillCircuitListing{ value: 1.01 ether }(orderId, 1 ether, 100, 0);
        assertEq(nft.ownerOf(204), buyer, "valid listing stays fillable");
    }

    // ---------- 硬化 1：Material 事件完整性（expiresAt + Expired/Cancelled 分离）----------

    function testMaterialCreatedCarriesExpiry() public {
        mat.mint(seller, NAND, 10);
        uint64 expiry = uint64(block.timestamp + 3 days);
        vm.startPrank(seller);
        mat.setApprovalForAll(address(material), true);
        vm.expectEmit(true, true, true, true, address(material));
        emit MaterialOrderCreated(1, seller, address(mat), NAND, uint8(BemHubMaterialMarket.Side.SELL), 0.04 ether, 10, expiry);
        uint256 orderId = material.createMaterialSell(address(mat), NAND, 0.04 ether, 10, expiry);
        vm.stopPrank();
        assertEq(material.getOrder(orderId).expiresAt, expiry, "on-chain order keeps the expiry");
    }

    function testMaterialCreatedZeroExpiryMeansNeverExpires() public {
        mat.mint(seller, NAND, 10);
        vm.startPrank(seller);
        mat.setApprovalForAll(address(material), true);
        vm.expectEmit(true, true, true, true, address(material));
        emit MaterialOrderCreated(1, seller, address(mat), NAND, uint8(BemHubMaterialMarket.Side.SELL), 0.04 ether, 10, 0);
        material.createMaterialSell(address(mat), NAND, 0.04 ether, 10, 0);
        vm.stopPrank();
    }

    /// 主动撤单只发 MaterialOrderCancelled，**不发** MaterialOrderExpired。
    function testMaterialCancelEmitsCancelledOnly() public {
        mat.mint(seller, NAND, 10);
        vm.startPrank(seller);
        mat.setApprovalForAll(address(material), true);
        uint256 orderId = material.createMaterialSell(address(mat), NAND, 0.04 ether, 10, 0);
        vm.expectEmit(true, true, false, true, address(material));
        emit MaterialOrderCancelled(orderId, seller, 0);
        material.cancelMaterialOrder(orderId);
        vm.stopPrank();
        assertEq(uint8(material.getOrder(orderId).status), uint8(BemHubMaterialMarket.OrderStatus.CANCELLED));
    }

    /// 过期清算只发 MaterialOrderExpired，并原额退回剩余 escrow。
    function testMaterialExpireEmitsExpiredOnlyAndRefunds() public {
        vm.deal(buyer, 10 ether);
        vm.prank(buyer);
        uint256 orderId = material.createMaterialBuy{ value: 10 * 0.04 ether }(address(mat), NAND, 0.04 ether, 10, uint64(block.timestamp + 10));

        vm.warp(block.timestamp + 11);
        uint256 buyerBefore = buyer.balance;

        // 任何人都可以代调用，但钱只回挂单人
        vm.expectEmit(true, true, false, true, address(material));
        emit MaterialOrderExpired(orderId, buyer, 10 * 0.04 ether);
        vm.prank(address(0xDEAD));
        material.expireOrder(orderId);

        assertEq(uint8(material.getOrder(orderId).status), uint8(BemHubMaterialMarket.OrderStatus.EXPIRED));
        assertEq(material.getOrder(orderId).remainingQuantity, 0, "remaining escrow zeroed");
        assertEq(material.totalEscrowed(), 0);
        assertEq(buyer.balance - buyerBefore, 10 * 0.04 ether, "refund went to the maker");
    }

    /// 过期单不能再成交；也不能被"撤单"接口改成 CANCELLED。
    function testExpiredOrderCannotBeFilledOrCancelled() public {
        vm.deal(buyer, 10 ether);
        vm.prank(buyer);
        uint256 orderId = material.createMaterialBuy{ value: 0.04 ether }(address(mat), NAND, 0.04 ether, 1, uint64(block.timestamp + 10));
        vm.warp(block.timestamp + 11);

        mat.mint(seller, NAND, 1);
        vm.prank(seller);
        vm.expectRevert(BemHubErrors.OrderExpired.selector);
        material.fillMaterialOrder(orderId, 1, 0.04 ether, 100, 0);

        vm.prank(address(0xDEAD));
        material.expireOrder(orderId);
        vm.prank(buyer);
        vm.expectRevert(BemHubErrors.OrderNotOpen.selector);
        material.cancelMaterialOrder(orderId);
        assertEq(uint8(material.getOrder(orderId).status), uint8(BemHubMaterialMarket.OrderStatus.EXPIRED));
    }
}
