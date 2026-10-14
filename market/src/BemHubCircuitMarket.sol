// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Ownable2Step, ReentrancyGuard, IERC721Minimal, IBemHubFeeTreasury, BemHubErrors } from "./BemHubBase.sol";

/**
 * @title BemHubCircuitMarket
 * @notice BEM Hub 自有电路（矿机）市场 V1：**只做固定价挂卖**，Maker 0% / Taker 1%。
 *
 * 非托管：挂单期间 NFT **一直留在 Maker 钱包**，本合约只记录 Listing；
 * Maker 需要 `setApprovalForAll(market,true)` 或单 token `approve`。
 *
 * 手续费（与指令第一百七十三条第 1 条一致）：
 *   买家(Taker) 付 price + price×1%；卖家(Maker) 实收 price；Treasury 得 price×1%。
 *
 * 明确不做：Circuit 不支持部分成交（整枚 NFT 转移）；不自动 Swap BNB→BEM；
 * 不支持任意 NFT（只允许白名单资产）；没有 Admin 提款/提 NFT 的入口。
 */
contract BemHubCircuitMarket is Ownable2Step, ReentrancyGuard {
    uint16 public constant TAKER_FEE_BPS_DEFAULT = 100; // 1%
    uint16 public constant MAKER_FEE_BPS = 0; // 0%
    uint16 public constant MAX_FEE_BPS = 200; // 治理上限 2%
    uint16 public constant BPS_DENOMINATOR = 10_000;

    enum OrderStatus {
        NONE,
        OPEN,
        FILLED,
        CANCELLED,
        EXPIRED
    }

    struct CircuitOrder {
        uint256 id;
        address maker;
        address asset;
        uint256 tokenId;
        uint256 price;
        uint64 createdAt;
        uint64 expiresAt; // 0 = 永不过期
        OrderStatus status;
    }

    address public immutable feeTreasury;
    uint16 public takerFeeBps = TAKER_FEE_BPS_DEFAULT;

    bool public pausedNewOrders;
    bool public pausedFills;

    mapping(address => bool) public allowedCircuitContract;
    mapping(uint256 => CircuitOrder) private _orders;
    uint256 public nextOrderId = 1;
    /// @dev 同一 (asset, tokenId) 只允许一个 OPEN 挂单；0 表示没有。
    mapping(address => mapping(uint256 => uint256)) public activeListingOf;

    event CircuitOrderCreated(uint256 indexed orderId, address indexed maker, address indexed asset, uint256 tokenId, uint256 price, uint64 expiresAt);
    event CircuitOrderCancelled(uint256 indexed orderId, address indexed maker);
    /// @dev 过期与「挂单后 NFT 已不在 Maker 手上」都走这个事件，和主动取消区分开，
    ///      Indexer 才能把状态标成 expired 而不是 cancelled。
    event CircuitOrderExpired(uint256 indexed orderId, address indexed maker);
    event CircuitOrderFilled(uint256 indexed orderId, address indexed maker, address indexed taker, address asset, uint256 tokenId, uint256 price, uint256 fee);
    event FeeCollected(address indexed market, uint256 indexed orderId, address indexed payer, uint256 tradeValue, uint256 feeAmount);
    event TakerFeeUpdated(uint16 oldFeeBps, uint16 newFeeBps);
    event AllowedAssetUpdated(address indexed asset, bool allowed);
    event PauseUpdated(bool pausedNewOrders, bool pausedFills);

    constructor(address initialOwner, address treasury) Ownable2Step(initialOwner) {
        if (treasury == address(0)) revert BemHubErrors.InvalidAmount();
        feeTreasury = treasury;
    }

    // ---------- 视图 ----------

    function getOrder(uint256 orderId) external view returns (CircuitOrder memory) {
        return _orders[orderId];
    }

    /// @notice Taker 费 = amount × takerFeeBps / 10000（Solidity 整除，向下取整）。
    function calculateTakerFee(uint256 amount) public view returns (uint256) {
        return (amount * takerFeeBps) / BPS_DENOMINATOR;
    }

    // ---------- Maker：挂单 / 撤单 ----------

    /**
     * @notice 挂固定价卖单。NFT 不转入本合约。
     *
     * 创建时必须同时满足两件事：
     *  1. `ownerOf(tokenId) == msg.sender`（你确实是持有人）；
     *  2. `isApprovedForAll(msg.sender, this) || getApproved(tokenId) == this`（本合约确实能转移它）。
     *
     * 第 2 条是硬化点：只检查持有人，会允许创建**从诞生那一刻就无法成交**的挂单
     * （买家付了 Gas 才发现 revert）。链上直接拒绝，前端也就不会展示这种假挂单。
     */
    function createCircuitListing(address asset, uint256 tokenId, uint256 price, uint64 expiresAt) external returns (uint256 orderId) {
        if (pausedNewOrders) revert BemHubErrors.NewOrdersPaused();
        if (!allowedCircuitContract[asset]) revert BemHubErrors.NotAllowedAsset();
        if (price == 0) revert BemHubErrors.InvalidPrice();
        if (expiresAt != 0 && expiresAt <= block.timestamp) revert BemHubErrors.InvalidExpiry();
        if (activeListingOf[asset][tokenId] != 0) revert BemHubErrors.DuplicateActiveListing();
        IERC721Minimal nft = IERC721Minimal(asset);
        if (nft.ownerOf(tokenId) != msg.sender) revert BemHubErrors.NotOwnerOfNFT();
        if (!nft.isApprovedForAll(msg.sender, address(this)) && nft.getApproved(tokenId) != address(this)) {
            revert BemHubErrors.MarketNotApproved();
        }

        orderId = nextOrderId++;
        _orders[orderId] = CircuitOrder({
            id: orderId,
            maker: msg.sender,
            asset: asset,
            tokenId: tokenId,
            price: price,
            createdAt: uint64(block.timestamp),
            expiresAt: expiresAt,
            status: OrderStatus.OPEN
        });
        activeListingOf[asset][tokenId] = orderId;
        emit CircuitOrderCreated(orderId, msg.sender, asset, tokenId, price, expiresAt);
    }

    /// @notice Maker 随时撤单；未成交不收费，只付 Gas。**暂停期间也必须可用。**
    function cancelCircuitListing(uint256 orderId) external {
        CircuitOrder storage order = _orders[orderId];
        if (order.status != OrderStatus.OPEN) revert BemHubErrors.OrderNotOpen();
        if (order.maker != msg.sender) revert BemHubErrors.NotOrderMaker();
        order.status = OrderStatus.CANCELLED;
        if (activeListingOf[order.asset][order.tokenId] == orderId) activeListingOf[order.asset][order.tokenId] = 0;
        emit CircuitOrderCancelled(orderId, msg.sender);
    }

    // ---------- Taker：成交 ----------

    /**
     * @notice 吃单买走这枚电路。
     * @param expectedPrice 前端展示价，链上必须完全一致（防被临时改价夹住）
     * @param maxFeeBps     用户能接受的最高费率（Admin 突然调高费率会直接 revert）
     * @param deadline      交易过期时间（长时间 pending 后不再意外成交）
     */
    function fillCircuitListing(uint256 orderId, uint256 expectedPrice, uint16 maxFeeBps, uint256 deadline) external payable nonReentrant {
        if (pausedFills) revert BemHubErrors.FillsPaused();
        if (deadline != 0 && block.timestamp > deadline) revert BemHubErrors.PastDeadline();
        if (takerFeeBps > maxFeeBps) revert BemHubErrors.FeeTooHigh();

        CircuitOrder storage order = _orders[orderId];
        if (order.status != OrderStatus.OPEN) revert BemHubErrors.OrderNotOpen();
        if (order.maker == msg.sender) revert BemHubErrors.NotOrderMaker();
        // 过期只拒绝成交，**不改状态**：revert 会回滚一切，改状态等于白改。
        // 订单保持 OPEN，Maker 因此随时能 cancel（撤单不收费）。
        if (order.expiresAt != 0 && block.timestamp > order.expiresAt) revert BemHubErrors.OrderExpired();
        if (order.price != expectedPrice) revert BemHubErrors.PriceChanged();

        uint256 fee = calculateTakerFee(order.price);
        uint256 total = order.price + fee;
        // V1 要求精确付款：多一分少一分都拒绝，避免多余的外部退款调用。
        if (msg.value != total) revert BemHubErrors.IncorrectPayment();

        // 挂单后 NFT 可能已转走 / 撤销授权 / 被别的市场成交 —— 一律不能成交，绝不强行转移。
        IERC721Minimal nft = IERC721Minimal(order.asset);
        if (nft.ownerOf(order.tokenId) != order.maker) revert BemHubErrors.NotOwnerOfNFT();
        if (!nft.isApprovedForAll(order.maker, address(this)) && nft.getApproved(order.tokenId) != address(this)) {
            revert BemHubErrors.MarketNotApproved();
        }

        address maker = order.maker;
        address asset = order.asset;
        uint256 tokenId = order.tokenId;
        uint256 price = order.price;

        // CEI：先把本合约的状态全部改完，再做外部调用。
        order.status = OrderStatus.FILLED;
        activeListingOf[asset][tokenId] = 0;

        nft.safeTransferFrom(maker, msg.sender, tokenId);
        _send(maker, price); // 卖家实收完整挂单价
        _payFee(orderId, msg.sender, price, fee);

        emit CircuitOrderFilled(orderId, maker, msg.sender, asset, tokenId, price, fee);
    }

    /**
     * @notice 任何人可调用：清算**已经不可能成交**的失效挂单。
     *
     * 满足以下任意一条即可清算（A/B/C）：
     *  A. `expiresAt` 已过期；
     *  B. `ownerOf(tokenId) != maker`（NFT 已转走；`ownerOf` revert 即 NFT 已销毁/不存在，同样算失效）；
     *  C. Maker 已撤销授权：`!isApprovedForAll(maker, this) && getApproved(tokenId) != this`。
     *
     * 只能做两件事：把 status 置为 EXPIRED、释放 `activeListingOf` 占位。
     * **绝不**转移 NFT、**绝不**转移 BNB、**绝不**收费（本函数没有任何 transfer 调用）。
     *
     * 反过来：仍然有效的挂单无法被恶意清算 —— A/B/C 都不成立时直接 revert `NotExpirable`。
     */
    function expireCircuitListing(uint256 orderId) external {
        CircuitOrder storage order = _orders[orderId];
        if (order.status != OrderStatus.OPEN) revert BemHubErrors.OrderNotOpen();
        bool isExpired = order.expiresAt != 0 && block.timestamp > order.expiresAt;
        bool isStale = _isStaleListing(order.asset, order.tokenId, order.maker);
        if (!isExpired && !isStale) revert BemHubErrors.NotExpirable();
        order.status = OrderStatus.EXPIRED;
        if (activeListingOf[order.asset][order.tokenId] == orderId) activeListingOf[order.asset][order.tokenId] = 0;
        emit CircuitOrderExpired(orderId, order.maker);
    }

    /// @dev B + C 两条失效判据。所有外部读调用都容错：读不出来就按"失效"处理
    ///      （因为读不出来的挂单同样不可能成交），但绝不会因此误判一个正常挂单 ——
    ///      正常挂单的 `ownerOf` 必然可读且等于 maker、授权必然为真。
    function _isStaleListing(address asset, uint256 tokenId, address maker) private view returns (bool) {
        IERC721Minimal nft = IERC721Minimal(asset);
        // B：持有人已不是 maker（或 NFT 已销毁/不存在）。
        try nft.ownerOf(tokenId) returns (address currentOwner) {
            if (currentOwner != maker) return true;
        } catch {
            return true;
        }
        // C：授权已撤销。
        try nft.isApprovedForAll(maker, address(this)) returns (bool approvedForAll) {
            if (approvedForAll) return false;
        } catch {
            return true;
        }
        try nft.getApproved(tokenId) returns (address approved) {
            return approved != address(this);
        } catch {
            return true;
        }
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

    function setAllowedCircuitContract(address asset, bool allowed) external onlyOwner {
        allowedCircuitContract[asset] = allowed;
        emit AllowedAssetUpdated(asset, allowed);
    }

    /// @notice 只暂停「创建新订单」与「成交」；撤单与退款永远不受影响。
    function setPaused(bool newOrdersPaused, bool fillsPaused) external onlyOwner {
        pausedNewOrders = newOrdersPaused;
        pausedFills = fillsPaused;
        emit PauseUpdated(newOrdersPaused, fillsPaused);
    }
}
