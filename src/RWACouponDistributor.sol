// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/**
 * @title RWACouponDistributor
 * @notice 周度收益券派发核心合约：Merkle 白名单 + EIP-712 签名 + 位图防重复。
 * - 多周派发：epochId => merkleRoot
 * - 叶子：leaf = keccak256(bytes.concat(keccak256(abi.encode(index, account, amount, epochId))))
 * - 位图：claimedBitMap[epochId][wordIndex]，按 index 定位 bit
 * - 签名：Claim(account, amount, epochId, nonce, deadline)，兼容 EOA 与合约钱包（EIP-1271）
 * - 事件/错误/只读视图齐全；状态更新在转账之前；SafeERC20 处理不规范代币
 */
contract RWACouponDistributor is EIP712, Ownable {
    using SafeERC20 for IERC20;

    // ============ Errors ============
    error InvalidProof();
    error AlreadyClaimed();
    error InvalidSignature();
    error SignatureExpired();

    // ============ Events ============
    event Claimed(
        uint256 indexed epochId,
        uint256 indexed index,
        address indexed account,
        uint256 amount
    );
    event MerkleRootUpdated(uint256 indexed epochId, bytes32 root);

    // ============ Storage ============
    /// @notice 被派发的收益券 Token
    IERC20 public immutable coupon;

    /// @notice 每周（epochId）对应的 Merkle 根
    mapping(uint256 => bytes32) public merkleRootByEpoch;

    /// @notice 位图：epochId => (wordIndex => 256-bit word)
    mapping(uint256 => mapping(uint256 => uint256)) private claimedBitMap;

    /// @notice 每个 account 的 EIP-712 nonce（成功领取后自增，抵御重放）
    mapping(address => uint256) public nonces;

    /// @dev EIP-712 类型哈希：keccak256("Claim(address account,uint256 amount,uint256 epochId,uint256 nonce,uint256 deadline)")
    bytes32 private constant CLAIM_TYPEHASH =
        keccak256("Claim(address account,uint256 amount,uint256 epochId,uint256 nonce,uint256 deadline)");

    // ============ Constructor ============
    /**
     * @param _coupon 被派发的 ERC20 收益券
     * @param _owner  合约 owner（通常是多签/运营权限账户）
     * @notice 你在分发合约里写 EIP712("RWACouponDistributor","1")，等于把 EIP-712 的域名/版本交给基类：
     * 基类立刻把 name/version 紧凑存储、各自哈希；
     * 以 当前链 ID + 当前合约地址 计算出并缓存 Domain Separator；
     * 后续每次验签都用这个域（除非链 ID 或合约地址变化才重算）。
     * 你再写 Ownable(_owner)，初始化管理员；
     * 最后 coupon = _coupon 把发放代币定死。
     */
    constructor(IERC20 _coupon, address _owner)
        EIP712("RWACouponDistributor", "1")
        Ownable(_owner)
    {
        coupon = _coupon;
    }

    // ============ Admin ============
    /**
     * @notice 设置/更新某周的 merkleRoot（允许同一 epochId 重发快照；上链请保留审计轨迹）
     */
    function setMerkleRoot(uint256 epochId, bytes32 root) external onlyOwner {
        merkleRootByEpoch[epochId] = root;
        emit MerkleRootUpdated(epochId, root);
    }

    // ============ Claim ============
    /**
     * @notice 领取本周收益券（支持任意人代付 gas，凭 EIP-712 签名）
     * @param index    该账户在本周白名单中的索引（0..N-1）
     * @param account  收款账户（签名者）
     * @param amount   本周应领额度
     * @param epochId  周编号（如 202532）
     * @param proof    Merkle 证明
     * @param signature EIP-712 签名（由 account 产生，或其合约钱包返回 1271 magic value）
     * @param deadline 签名截止时间（Unix 时间戳，<= 则过期）
     */
    function claim(
        uint256 index,
        address account,
        uint256 amount,
        uint256 epochId,
        bytes32[] calldata proof,
        bytes calldata signature,
        uint256 deadline
    ) external {
        // 1) 过期检查（尽早失败，省 gas）
        if (block.timestamp > deadline) revert SignatureExpired();

        // 2) 重复领取检查（位图 O(1)）
        if (_isClaimed(epochId, index)) revert AlreadyClaimed();

        // 3) EIP-712 签名校验（EOA/EIP-1271 统一） 代表你愿意拿，不验证Merkel
        bytes32 digest = _hashClaim(account, amount, epochId, nonces[account], deadline);
        if (!SignatureChecker.isValidSignatureNow(account, digest, signature)) {
            revert InvalidSignature();
        }

        // 4) Merkle 证明校验（双哈希 + abi.encode） 代表你能拿这些额度
        bytes32 inner = keccak256(abi.encode(index, account, amount, epochId)); // 第一次hash
        // 外层仅包一段 bytes32，使用 bytes.concat/encodePacked 等价安全（无拼接歧义）
        bytes32 leaf = keccak256(bytes.concat(inner)); //第二次hash
        // 从leaf开始找于proof挨个合并，直到找到proof
        if (!MerkleProof.verify(proof, merkleRootByEpoch[epochId], leaf)) {
            revert InvalidProof();
        }

        // 5) 状态更新在转账之前（防重入）
        _setClaimed(epochId, index);
        unchecked {
            nonces[account] += 1;
        }

        // 6) 转账 & 事件
        coupon.safeTransfer(account, amount);
        emit Claimed(epochId, index, account, amount);
    }

    // ============ Views ============
    function isClaimed(uint256 epochId, uint256 index) external view returns (bool) {
        return _isClaimed(epochId, index);
    }

    // （可选）暴露 EIP-712 域分隔符，方便前端/脚本调试
    function eip712DomainSeparator() external view returns (bytes32) {
        // OpenZeppelin EIP712 提供 _domainSeparatorV4()
        return _domainSeparatorV4();
    }

    // ============ Internals ============
    /// @dev 生成 EIP-712 digest
    function _hashClaim(
        address account,
        uint256 amount,
        uint256 epochId,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(abi.encode(CLAIM_TYPEHASH, account, amount, epochId, nonce, deadline))
        );
    }

    /// @dev 位图读取
    function _isClaimed(uint256 epochId, uint256 index) internal view returns (bool) {
        uint256 wordIndex = index >> 8; // / 256
        uint256 bitIndex = index & 0xff; // % 256
        uint256 word = claimedBitMap[epochId][wordIndex];
        uint256 mask = (uint256(1) << bitIndex);
        return (word & mask) != 0;
    }

    /// @dev 位图置位
    function _setClaimed(uint256 epochId, uint256 index) internal {
        uint256 wordIndex = index >> 8; // / 256
        uint256 bitIndex = index & 0xff; // % 256
        claimedBitMap[epochId][wordIndex] |= (uint256(1) << bitIndex);
    }
}