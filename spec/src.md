好～下面把合约层两个文件逐一“拆成任务清单 + 函数级职责”，你按这个对照去写就不会走偏（不含实现代码）。

src/RWACoupon.sol（最简 ERC-20「收益券」）

目标

提供可被派发的 ERC-20 代币，遵循主流接口，支持铸造给发行方/金库后转入 Distributor。

依赖
	•	OpenZeppelin：ERC20、Ownable（可选 ERC20Permit，若你想加 permit）

存储（除父类外）
	•	无新增业务存储（保持轻量）

事件
	•	继承自 ERC20（Transfer / Approval）

错误（可选）
	•	MintToZeroAddress()、MintAmountZero()（如果你想更严格）

构造
	•	constructor(string name, string symbol, address owner)
	•	设置代币名称/符号、decimals=18（默认）
	•	将 owner 设为合约管理员（用于铸造）

外部/公开函数（签名级要求）
	•	function mint(address to, uint256 amount) external onlyOwner
	•	前置：to != address(0)，amount > 0
	•	后置：totalSupply 增加，balanceOf(to) 增加
	•	事件：Transfer(address(0), to, amount)
	•	（可选）function burn(uint256 amount) external
	•	允许用户自燃；真实业务一般不强制需要
	•	（可选）function burnFrom(address from, uint256 amount) external
	•	配合 allowance 走授权燃烧

安全/边界
	•	不需要重入保护（纯记账）
	•	不做复杂钩子，避免和派发流程相互影响
	•	如果引入 ERC20Permit，文档里标注签名有效期与 nonce 语义

⸻

src/RWACouponDistributor.sol（派发核心）

目标

基于「Merkle 白名单 + EIP-712 签名 + 位图防重复」，实现**按周（epoch）**派发收益券；兼容 EOA 与合约钱包（EIP-1271）。

依赖
	•	OpenZeppelin：MerkleProof、EIP712、SignatureChecker、ECDSA、SafeERC20、Ownable
	•	（可选）ReentrancyGuard：通常不是必需，但上链保守可加

常量 / Typehash
	•	string private constant NAME = "RWACouponDistributor";
	•	string private constant VERSION = "1";
	•	bytes32 private constant CLAIM_TYPEHASH = keccak256("Claim(address account,uint256 amount,uint256 epochId,uint256 nonce,uint256 deadline)");

存储
	•	IERC20 public coupon;
被派发的收益券代币
	•	mapping(uint256 => bytes32) public merkleRootByEpoch;
每周对应的 Merkle Root
	•	mapping(uint256 => mapping(uint256 => uint256)) private claimedBitMap;
位图：epochId -> wordIndex(=index/256) -> 256-bit word
	•	mapping(address => uint256) public nonces;
EIP-712 每账户的签名计数（用于「一次签名一次消费」）

事件
	•	event Claimed(uint256 indexed epochId, uint256 indexed index, address indexed account, uint256 amount);
	•	event MerkleRootUpdated(uint256 indexed epochId, bytes32 root);
	•	（可选）event Funded(uint256 amount);、event Swept(address token, address to, uint256 amount);

自定义错误
	•	error InvalidProof();
	•	error AlreadyClaimed();
	•	error InvalidSignature();
	•	error SignatureExpired();
	•	（可选）error ZeroAddress();、error NotEnoughFunds();

构造
	•	constructor(IERC20 _coupon, address _owner) EIP712(NAME, VERSION) Ownable(_owner)
	•	设定被派发代币、EIP-712 域、管理员

外部/公开函数（签名级要求）
	1.	管理员设置/更新本周 Root

	•	function setMerkleRoot(uint256 epochId, bytes32 root) external onlyOwner
	•	前置：root != bytes32(0)
	•	后置：merkleRootByEpoch[epochId] = root；emit MerkleRootUpdated(...)
	•	说明：允许更新根以修正名单（真实运营要配流程管控）

	2.	领取

	•	function claim(uint256 index, address account, uint256 amount, uint256 epochId, bytes32[] calldata proof, bytes calldata signature, uint256 deadline) external
	•	前置：
	•	block.timestamp <= deadline 否则 SignatureExpired
	•	!_isClaimed(epochId, index) 否则 AlreadyClaimed
	•	计算 EIP-712 digest = _hashClaim(account, amount, epochId, nonces[account], deadline)
	•	SignatureChecker.isValidSignatureNow(account, digest, signature) 为真，否则 InvalidSignature
	•	计算叶子：leaf = keccak256(bytes.concat(keccak256(abi.encode(index, account, amount, epochId))))
	•	MerkleProof.verify(proof, merkleRootByEpoch[epochId], leaf) 为真，否则 InvalidProof
	•	状态更新（先于转账）：
	•	_setClaimed(epochId, index)
	•	nonces[account] += 1
	•	动作：
	•	coupon.safeTransfer(account, amount)
	•	emit Claimed(epochId, index, account, amount)
	•	说明：
	•	调用者可以不是 account（支持 gas 代付），但签名主体必须是 account
	•	nonce 确保签名只可使用一次（即便其他链/合约想复用，域分隔也会阻断）

	3.	查询辅助（视图）

	•	function isClaimed(uint256 epochId, uint256 index) external view returns (bool)
	•	读取位图判断是否已领
	•	function getDigest(address account, uint256 amount, uint256 epochId, uint256 nonce, uint256 deadline) external view returns (bytes32)
	•	前端/脚本调试：给定参数返回 EIP-712 digest（便于比对签名）

	4.	资金运维（可选）

	•	function sweep(address token, address to, uint256 amount) external onlyOwner
	•	回收误转/剩余资金；主网使用时推荐

内部/私有函数（签名级要求）
	•	function _hashClaim(address account, uint256 amount, uint256 epochId, uint256 nonce, uint256 deadline) internal view returns (bytes32)
	•	structHash = keccak256(abi.encode(CLAIM_TYPEHASH, account, amount, epochId, nonce, deadline))
	•	return _hashTypedDataV4(structHash)
	•	function _isClaimed(uint256 epochId, uint256 index) internal view returns (bool)
	•	wordIndex = index >> 8，bitIndex = index & 255，位运算判断
	•	function _setClaimed(uint256 epochId, uint256 index) internal
	•	同上，置位 claimedBitMap
	•	（可选）function _verifyProof(uint256 epochId, bytes32 leaf, bytes32[] calldata proof) internal view returns (bool)

安全/一致性要求
	•	叶子构造一律双哈希：keccak256(bytes.concat(keccak256(abi.encode(...))))；严禁 abi.encodePacked 拼可变长，避免连接歧义
	•	顺序：状态更新（置位 + nonce++）先于 safeTransfer，规避潜在重入
	•	签名：用 SignatureChecker 以兼容 EOA/EIP-1271；域包含 chainId、verifyingContract，epochId 在载荷内，避免跨周/跨链/跨合约重放
	•	权限：仅 owner 可改 root / sweep
	•	资金：确保 Distributor 合约余额 ≥ 可领取总额；部署/充值脚本负责铸造并转入
	•	可观测性：每次更新 root、每次领取均发事件
	•	Gas：位图比 mapping(address=>bool) 更省；unchecked 自增 nonce 可选；局部缓存 merkleRoot、coupon 到栈中

失败场景（应返回的错误）
	•	错误签名 → InvalidSignature()
	•	过期签名 → SignatureExpired()
	•	错误证明/错字段/错 epoch → InvalidProof()
	•	重复领取（同 epoch 同 index）→ AlreadyClaimed()
	•	资金不足（转账失败）→ safeTransfer revert（或自行抛 NotEnoughFunds()）

⸻

到这一步，每个文件的“该做什么”已经精确到函数签名与前后置条件。你可以直接按这里的条目写接口与注释，然后再去实现。需要我把脚本与测试层也做同样粒度的“文件->函数->职责”清单吗？（GenerateInput / MakeMerkle / DeployAll / Claim / 测试用例表）