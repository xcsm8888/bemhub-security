// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Ownable2Step, ReentrancyGuard, IERC1155Minimal, IBemHubFeeTreasury, BemHubErrors } from "./BemHubBase.sol";

/**
 * @title BemHubMaterialMarket
 * @notice BEM Hub 晶体管（Material）市场 V1：ERC-1155 双向订单簿 + 部分成交，Maker 0% / Taker 1%。
 *
 * 链上已确认三个 Material 合约都是 **ERC-1155**（supportsInterface(0xd9b67a26)=true），
 * 因此授权只用 `setApprovalForAll / isApprovedForAll`，**不存在 ERC-20 式 allowance**。
 *
 * 资金与资产：
 * - SELL 挂单：Material **留在 Maker 钱包**（非托管），成交时 maker → taker 直转；
 * - BUY  挂单：Maker 必须**全额 escrow BNB**（msg.value = pricePerUnit × quantity），
 *   部分成交后剩余额度继续锁定；撤单全额退还剩余 escrow，不收消费。
 *
 * 费率（指令第一百七十三条第 2、3 条）：
 * - SELL：买家(Taker) 付 tradeValue + 1%；卖家(Maker) 收 tradeValue；Treasury 收 1%；
 * - BUY ：卖家(Taker) 从成交额里承担 1%，实收 tradeValue − 1%；Treasury 收 1%。
 */
contract BemHubMaterialMarket is Ownable2Step, ReentrancyGuard {
    uint16 public constant TAKER_FEE_BPS_DEFAULT = 100;
    uint16 public constant MAKER_FEE_BPS = 0;
    uint16 public constant MAX_FEE_BPS = 200;
    uint16 public constant BPS_DENOMINATOR = 10_000;

    enum Side {
        SELL,
        BUY
    }

    enum OrderStatus {
        NONE,
        OPEN,
        FILLED,
        CANCELLED,
        EXPIRED
    }

    struct MaterialOrder {
        uint256 id;
        address maker;
        address material;
        uint256 materialId;
        Side side;
        uint256 pricePerUnit; // wei / 单位
        uint256 originalQuantity;
        uint256 remainingQuantity;
        uint64 createdAt;
        uint64 expiresAt; // 0 = 永不过期
        OrderStatus status;
    }

    address public immutable feeTreasury;
    uint16 public takerFeeBps = TAKER_FEE_BPS_DEFAULT;

    bool public pausedNewOrders;
    bool public pausedFills;

    mapping(address => bool) public allowedMaterialContract;
    /// @dev 只允许明确的 (合约, tokenId) 组合：V1 只有 tokenId 0=NAND / 1=LATCH。
    /// 不能因为整个 ERC-1155 合约在白名单里，日后新增 id 就自动可交易。
    mapping(address => mapping(uint256 => bool)) public allowedMaterialId;
    mapping(uint256 => MaterialOrder) private _orders;
    uint256 public nextOrderId = 1;
    /// @dev 只为 BUY 单记账本合约代管的 BNB，便于审计与不变式测试。
    uint256 public totalEscrowed;

    /// @dev 带上 expiresAt：Indexer 必须能**直接从事件**写入有效期，不靠链下补读、不猜。
    event MaterialOrderCreated(uint256 indexed orderId, address indexed maker, address indexed material, uint256 materialId, Side side, uint256 price, uint256 quantity, uint64 expiresAt);
    /// @dev 只有 Maker 主动撤单发这个事件。
    event MaterialOrderCancelled(uint256 indexed orderId, address indexed maker, uint256 refunded);
    /// @dev 只有过期清算（permissionless）发这个事件。
    ///     拆成两个独立事件的原因：原来 cancel 与 expire 共用 MaterialOrderCancelled，
    ///     Indexer 仅凭链上事件**无法区分** CANCELLED 与 EXPIRED，账目口径必然含混。
    event MaterialOrderExpired(uint256 indexed orderId, address indexed maker, uint256 refunded);
    event MaterialOrderFilled(uint256 indexed orderId, address indexed maker, address indexed taker, Side side, uint256 fillQuantity, uint256 price, uint256 tradeValue, uint256 fee, uint256 remainingQuantity);
    event FeeCollected(address indexed market, uint256 indexed orderId, address indexed payer, uint256 tradeValue, uint256 feeAmount);
    event TakerFeeUpdated(uint16 oldFeeBps, uint16 newFeeBps);
    event AllowedAssetUpdated(address indexed asset, bool allowed);
    event PauseUpdated(bool pausedNewOrders, bool pausedFills);

    constructor(address initialOwner, address treasury) Ownable2Step(initialOwner) {
        if (treasury == address(0)) revert BemHubErrors.InvalidAmount();
        feeTreasury = treasury;
    }

    function getOrder(uint256 orderId) external view returns (MaterialOrder memory) {
        return _orders[orderId];
    }

    function calculateTakerFee(uint256 amount) public view returns (uint256) {
        return (amount * takerFeeBps) / BPS_DENOMINATOR;
    }

    /// @notice BUY 单剩余 escrow（撤单退款金额）。
    function remainingEscrow(uint256 orderId) external view returns (uint256) {
        MaterialOrder storage order = _orders[orderId];
        if (order.side != Side.BUY || order.status != OrderStatus.OPEN) return 0;
        return order.remainingQuantity * order.pricePerUnit;
    }

    // ---------- Maker：挂单 ----------

    /// @notice 挂卖单：资产留在 Maker 钱包，只校验余额与操作员授权。
    function createMaterialSell(address material, uint256 materialId, uint256 pricePerUnit, uint256 quantity, uint64 expiresAt) external returns (uint256 orderId) {
        _checkCommon(material, materialId, pricePerUnit, quantity, expiresAt);
        if (IERC1155Minimal(material).balanceOf(msg.sender, materialId) < quantity) revert BemHubErrors.InsufficientBalance();
        if (!IERC1155Minimal(material).isApprovedForAll(msg.sender, address(this))) revert BemHubErrors.MarketNotApproved();
        orderId = _create(material, materialId, Side.SELL, pricePerUnit, quantity, expiresAt, 0);
    }

    /// @notice 挂买单：必须全额 escrow BNB，不允许只记一条没有资金保证的买单。
    function createMaterialBuy(address material, uint256 materialId, uint256 pricePerUnit, uint256 quantity, uint64 expiresAt) external payable returns (uint256 orderId) {
        _checkCommon(material, materialId, pricePerUnit, quantity, expiresAt);
        uint256 need = pricePerUnit * quantity;
        if (msg.value != need) revert BemHubErrors.InsufficientEscrow();
        totalEscrowed += need;
        orderId = _create(material, materialId, Side.BUY, pricePerUnit, quantity, expiresAt, need);
    }

    function _checkCommon(address material, uint256 materialId, uint256 pricePerUnit, uint256 quantity, uint64 expiresAt) private view {
        if (pausedNewOrders) revert BemHubErrors.NewOrdersPaused();
        if (!allowedMaterialContract[material]) revert BemHubErrors.NotAllowedAsset();
        if (!allowedMaterialId[material][materialId]) revert BemHubErrors.UnsupportedMaterialId();
        if (pricePerUnit == 0) revert BemHubErrors.InvalidPrice();
        if (quantity == 0) revert BemHubErrors.InvalidQuantity();
        if (expiresAt != 0 && expiresAt <= block.timestamp) revert BemHubErrors.InvalidExpiry();
    }

    function _create(address material, uint256 materialId, Side side, uint256 pricePerUnit, uint256 quantity, uint64 expiresAt, uint256 escrow) private returns (uint256 orderId) {
        orderId = nextOrderId++;
        _orders[orderId] = MaterialOrder({
            id: orderId,
            maker: msg.sender,
            material: material,
            materialId: materialId,
            side: side,
            pricePerUnit: pricePerUnit,
            originalQuantity: quantity,
            remainingQuantity: quantity,
            createdAt: uint64(block.timestamp),
            expiresAt: expiresAt,
            status: OrderStatus.OPEN
        });
        emit MaterialOrderCreated(orderId, msg.sender, material, materialId, side, pricePerUnit, quantity, expiresAt);
        escrow; // escrow 已在调用方记账（BUY 时）
    }

    /// @notice Maker 撤单：**BUY 必须全额退还剩余 escrow**，平台不收取消费。暂停期间也可用。
    function cancelMaterialOrder(uint256 orderId) external nonReentrant {
        MaterialOrder storage order = _orders[orderId];
        if (order.status != OrderStatus.OPEN) revert BemHubErrors.OrderNotOpen();
        if (order.maker != msg.sender) revert BemHubErrors.NotOrderMaker();

        uint256 refund = 0;
        if (order.side == Side.BUY) {
            refund = order.remainingQuantity * order.pricePerUnit;
            order.remainingQuantity = 0;
            totalEscrowed -= refund;
        }
        order.status = OrderStatus.CANCELLED;
        emit MaterialOrderCancelled(orderId, msg.sender, refund);
        if (refund > 0) _send(msg.sender, refund);
    }

    // ---------- Taker：成交（支持部分成交） ----------

    /**
     * @notice 吃单成交任意一侧。
     * @param quantity      本次成交数量（≤ remaining）
     * @param expectedPrice 前端展示单价，链上必须完全一致
     * @param maxFeeBps     用户能接受的最高费率
     * @param deadline      交易过期时间
     */
    function fillMaterialOrder(uint256 orderId, uint256 quantity, uint256 expectedPrice, uint16 maxFeeBps, uint256 deadline) external payable nonReentrant {
        if (pausedFills) revert BemHubErrors.FillsPaused();
        if (deadline != 0 && block.timestamp > deadline) revert BemHubErrors.PastDeadline();
        if (takerFeeBps > maxFeeBps) revert BemHubErrors.FeeTooHigh();

        MaterialOrder storage order = _orders[orderId];
        if (order.status != OrderStatus.OPEN) revert BemHubErrors.OrderNotOpen();
        if (order.maker == msg.sender) revert BemHubErrors.NotOrderMaker();
        // 过期只拒绝成交，不改状态：revert 会连退款一起回滚，那 escrow 就永远取不回了。
        // 订单保持 OPEN，Maker 随时能 cancel 全额取回；也允许任何人调用 expireOrder 帮忙清理。
        if (order.expiresAt != 0 && block.timestamp > order.expiresAt) revert BemHubErrors.OrderExpired();
        if (order.pricePerUnit != expectedPrice) revert BemHubErrors.PriceChanged();
        if (quantity == 0 || quantity > order.remainingQuantity) revert BemHubErrors.InvalidQuantity();

        uint256 tradeValue = order.pricePerUnit * quantity;
        uint256 fee = calculateTakerFee(tradeValue);
        address maker = order.maker;
        address material = order.material;
        uint256 materialId = order.materialId;
        Side side = order.side;

        // CEI：先改状态与账本
        order.remainingQuantity -= quantity;
        if (order.remainingQuantity == 0) order.status = OrderStatus.FILLED;

        if (side == Side.SELL) {
            // Maker=卖家（资产在 maker 钱包），Taker=买家额外付 1%
            // V1 精确付款：多一分少一分都拒绝，无外部退款调用。
            if (msg.value != tradeValue + fee) revert BemHubErrors.IncorrectPayment();
            // 挂单后可能已转走资产或撤销授权 —— 由 safeTransferFrom 直接 revert，不会被成交。
            IERC1155Minimal(material).safeTransferFrom(maker, msg.sender, materialId, quantity, "");
            _send(maker, tradeValue);
            _payFee(orderId, msg.sender, tradeValue, fee);
        } else {
            // Maker=买家（资金已 escrow），Taker=卖家从成交额承担 1%
            if (msg.value != 0) revert BemHubErrors.IncorrectPayment();
            totalEscrowed -= tradeValue;
            IERC1155Minimal(material).safeTransferFrom(msg.sender, maker, materialId, quantity, "");
            _send(msg.sender, tradeValue - fee);
            _payFee(orderId, msg.sender, tradeValue, fee);
        }

        emit MaterialOrderFilled(orderId, maker, msg.sender, side, quantity, order.pricePerUnit, tradeValue, fee, order.remainingQuantity);
    }

    /// @notice 任何人可调用：把已过期订单标记为 EXPIRED，并把剩余 escrow 退回 Maker（只退给 maker，别人拿不走）。
    function expireOrder(uint256 orderId) external nonReentrant {
        MaterialOrder storage order = _orders[orderId];
        if (order.status != OrderStatus.OPEN) revert BemHubErrors.OrderNotOpen();
        if (order.expiresAt == 0 || block.timestamp <= order.expiresAt) revert BemHubErrors.InvalidExpiry();
        _expire(order);
    }

    function _expire(MaterialOrder storage order) private {
        uint256 refund = 0;
        if (order.side == Side.BUY) {
            refund = order.remainingQuantity * order.pricePerUnit;
            order.remainingQuantity = 0;
            totalEscrowed -= refund;
        }
        order.status = OrderStatus.EXPIRED;
        // 过期只发 MaterialOrderExpired：与主动撤单彻底分开。
        emit MaterialOrderExpired(order.id, order.maker, refund);
        if (refund > 0) _send(order.maker, refund);
    }

    function _payFee(uint256 orderId, address payer, uint256 tradeValue, uint256 fee) private {
        if (fee == 0) return;
        IBemHubFeeTreasury(feeTreasury).depositFee{ value: fee }();
        emit FeeCollected(address(this), orderId, payer, tradeValue, fee);
    }

    function _send(address to, uint256 amount) private {
        (bool ok, ) = to.call{ value: amount }("");
        if (!ok) revert BemHubErrors.TransferFailed();
    }

    // ---------- 治理 ----------

    function setTakerFeeBps(uint16 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_FEE_BPS) revert BemHubErrors.FeeTooLarge();
        uint16 old = takerFeeBps;
        takerFeeBps = newFeeBps;
        emit TakerFeeUpdated(old, newFeeBps);
    }

    function setAllowedMaterialContract(address material, bool allowed) external onlyOwner {
        allowedMaterialContract[material] = allowed;
        emit AllowedAssetUpdated(material, allowed);
    }

    /// @notice 逐个开放 (合约, tokenId)。V1 只开放每个材料的 0(NAND) / 1(LATCH)。
    function setAllowedMaterialId(address material, uint256 materialId, bool allowed) external onlyOwner {
        allowedMaterialId[material][materialId] = allowed;
        emit AllowedAssetUpdated(material, allowed);
    }

    function setPaused(bool newOrdersPaused, bool fillsPaused) external onlyOwner {
        pausedNewOrders = newOrdersPaused;
        pausedFills = fillsPaused;
        emit PauseUpdated(newOrdersPaused, fillsPaused);
    }
}
