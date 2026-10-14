// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title BEM Hub 自有交易协议 · 基础件
 * @notice 不引入外部依赖（本机/CI 离线都能编译复现）。语义与 OpenZeppelin 的
 *         Ownable2Step / ReentrancyGuard 对齐：两步转移所有权 + 非重入锁。
 *         后续若要换成 OZ 官方包，只需替换这两个抽象合约，市场合约不用改。
 */
abstract contract Ownable2Step {
    address public owner;
    address public pendingOwner;

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    error NotOwner();
    error NotPendingOwner();
    error ZeroOwner();

    constructor(address initialOwner) {
        if (initialOwner == address(0)) revert ZeroOwner();
        owner = initialOwner;
        emit OwnershipTransferred(address(0), initialOwner);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @notice 第一步：当前 owner 指定继任者（此时还没真正交接）。
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroOwner();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    /// @notice 第二步：继任者自己接受，避免转错地址后所有权永久丢失。
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        address previous = owner;
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnershipTransferred(previous, msg.sender);
    }
}

abstract contract ReentrancyGuard {
    uint256 private _lock = 1;
    error Reentrant();

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrant();
        _lock = 2;
        _;
        _lock = 1;
    }
}

/// @notice 只取我们真正用到的最小子集；Material 已链上确认为 ERC-1155。
interface IERC721Minimal {
    function ownerOf(uint256 tokenId) external view returns (address);
    function getApproved(uint256 tokenId) external view returns (address);
    function isApprovedForAll(address owner, address operator) external view returns (bool);
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
}

interface IERC1155Minimal {
    function balanceOf(address account, uint256 id) external view returns (uint256);
    function isApprovedForAll(address owner, address operator) external view returns (bool);
    function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes calldata data) external;
}

interface IBemHubFeeTreasury {
    /// @dev 只有白名单市场可以调用；普通地址直接转账不会被计入协议手续费。
    function depositFee() external payable;
}

/// @notice 统一的失败原因，便于前端与测试断言（不吞错误）。
library BemHubErrors {
    error NotAllowedAsset();
    error InvalidAmount();
    error InvalidPrice();
    error InvalidQuantity();
    error InvalidExpiry();
    error OrderNotOpen();
    error OrderExpired();
    error NotOrderMaker();
    error DuplicateActiveListing();
    error PriceChanged();
    error FeeTooHigh();
    error PastDeadline();
    error NotOwnerOfNFT();
    error MarketNotApproved();
    error InsufficientPayment();
    error InsufficientEscrow();
    error InsufficientBalance();
    error NewOrdersPaused();
    error FillsPaused();
    error TransferFailed();
    error FeeTooLarge();
    error InvalidSplit();
    error IncorrectPayment();
    error NotExpirable();
    error UnsupportedMaterialId();
    error MarketNotAllowed();
    error ZeroAddress();
}
