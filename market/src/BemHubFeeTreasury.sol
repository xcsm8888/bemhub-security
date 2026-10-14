// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Ownable2Step, ReentrancyGuard, BemHubErrors } from "./BemHubBase.sol";

/**
 * @title BemHubFeeTreasury
 * @notice BEM Hub 自有市场的**唯一**手续费去向。市场成交时把平台费打进来，这里只累计、不 Swap。
 *
 * 明确不做的事（按指令）：
 * - 不自动 Swap BNB → BEM（滑点/MEV/Router 失败会拖垮正常成交）；
 * - 没有 `withdraw(to, amount)` 这种任意提款：只能 `distributeBNB()` 打给三个**已配置**的钱包，
 *   未配置就 revert。这样即使 owner 私钥泄露，也拿不到用户 escrow（这里本来也不放用户资金）。
 */
contract BemHubFeeTreasury is Ownable2Step, ReentrancyGuard {
    /// @dev 默认 50% 回购/销毁、20% Foundation、30% Operations（指令第三十二条）。
    uint16 public constant DEFAULT_BUYBACK_BPS = 5000;
    uint16 public constant DEFAULT_FOUNDATION_BPS = 2000;
    uint16 public constant DEFAULT_OPERATIONS_BPS = 3000;
    uint16 public constant BPS_DENOMINATOR = 10_000;

    address public buybackVault;
    address public foundationWallet;
    address public operationsWallet;
    uint16 public buybackBps = DEFAULT_BUYBACK_BPS;
    uint16 public foundationBps = DEFAULT_FOUNDATION_BPS;
    uint16 public operationsBps = DEFAULT_OPERATIONS_BPS;

    /// @notice 只有**白名单市场**的 depositFee 才计入这里；后台 Revenue 只能用这个数。
    uint256 public protocolFeeReceived;
    /// @notice 第三方强行转入（receive/自毁）单独统计，绝不计入平台收入。
    uint256 public externalDonation;
    /// @notice 只有这些市场能调用 depositFee。
    mapping(address => bool) public allowedMarket;

    event FeeReceived(address indexed from, uint256 amount, uint256 protocolTotal);
    event ExternalDonation(address indexed from, uint256 amount, uint256 donationTotal);
    event AllowedMarketUpdated(address indexed market, bool allowed);
    event SplitsUpdated(address buybackVault, address foundationWallet, address operationsWallet, uint16 buybackBps, uint16 foundationBps, uint16 operationsBps);
    event Distributed(address indexed wallet, uint256 amount);

    constructor(address initialOwner) Ownable2Step(initialOwner) {}

    /// @notice 仅白名单市场可调用；非授权地址一律 revert，避免污染平台收入口径。
    function depositFee() external payable {
        if (!allowedMarket[msg.sender]) revert BemHubErrors.MarketNotAllowed();
        if (msg.value == 0) revert BemHubErrors.InvalidAmount();
        protocolFeeReceived += msg.value;
        emit FeeReceived(msg.sender, msg.value, protocolFeeReceived);
    }

    /// @notice 第三方直接转账（或自毁强转）只记为捐赠，不进平台收入。
    receive() external payable {
        externalDonation += msg.value;
        emit ExternalDonation(msg.sender, msg.value, externalDonation);
    }

    function setAllowedMarket(address market, bool allowed) external onlyOwner {
        if (market == address(0)) revert BemHubErrors.ZeroAddress();
        allowedMarket[market] = allowed;
        emit AllowedMarketUpdated(market, allowed);
    }

    /// @notice 配置三个收款钱包与比例；比例之和必须正好 10000，否则拒绝。
    function setSplits(address buyback, address foundation, address operations, uint16 bpsBuyback, uint16 bpsFoundation, uint16 bpsOperations) external onlyOwner {
        if (bpsBuyback + bpsFoundation + bpsOperations != BPS_DENOMINATOR) revert BemHubErrors.InvalidSplit();
        buybackVault = buyback;
        foundationWallet = foundation;
        operationsWallet = operations;
        buybackBps = bpsBuyback;
        foundationBps = bpsFoundation;
        operationsBps = bpsOperations;
        emit SplitsUpdated(buyback, foundation, operations, bpsBuyback, bpsFoundation, bpsOperations);
    }

    /// @notice 把当前余额按比例分给三个已配置钱包。任一未配置则整体 revert（宁可不动，也不打错地址）。
    function distributeBNB() external onlyOwner nonReentrant {
        if (buybackVault == address(0) || foundationWallet == address(0) || operationsWallet == address(0)) {
            revert BemHubErrors.InvalidSplit();
        }
        uint256 balance = address(this).balance;
        if (balance == 0) revert BemHubErrors.InvalidAmount();
        uint256 toBuyback = (balance * buybackBps) / BPS_DENOMINATOR;
        uint256 toFoundation = (balance * foundationBps) / BPS_DENOMINATOR;
        // 余数全部给 operations，保证不留残额在本合约。
        uint256 toOperations = balance - toBuyback - toFoundation;
        _send(buybackVault, toBuyback);
        _send(foundationWallet, toFoundation);
        _send(operationsWallet, toOperations);
    }

    function _send(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok, ) = to.call{ value: amount }("");
        if (!ok) revert BemHubErrors.TransferFailed();
        emit Distributed(to, amount);
    }
}
