好的！下面是一份完整可执行的需求文档（不含实现代码），你在 forge init 之后照着做就能把 Demo 跑通、测试齐全、结构清晰。

项目名

rwa-coupon-distributor

一句话目标

实现一个贴近真实 RWA/DeFi 的“周度收益券派发”系统：
通过 Merkle 白名单 + EIP-712 签名 + 位图防重复 派发 ERC-20「收益券」给通过 KYC 的投资者，覆盖 生成输入→构树与证明→部署与充值→签名→脚本化领取→测试 全流程。

⸻

一、功能范围（Scope）
	1.	合约层

	•	RWACoupon：最简 ERC-20，用作被派发的“收益券”。
	•	RWACouponDistributor：派发核心，支持：
	•	多周派发：epochId → merkleRoot；
	•	叶子：leaf = keccak256(bytes.concat(keccak256(abi.encode(index, account, amount, epochId))))（双哈希，防第二原像）；
	•	位图按 index 防重复：claimedBitMap[epochId][index]；
	•	EIP-712 签名（account, amount, epochId, nonce, deadline），SignatureChecker 验证，兼容 EOA & 合约钱包（EIP-1271）；
	•	事件日志、只读视图、管理员设置 merkleRoot。

	2.	脚本层（Foundry / Node 可选）

	•	生成周度白名单 input.json；
	•	用 Murky 生成 output.json（root / proofs / inputs）；
	•	部署 Token + Distributor、设置 root、给 Distributor 充值；
	•	生成 EIP-712 签名（前端或 Node/脚本）；
	•	读取 output.json 和离线签名，一键 claim。

	3.	测试层

	•	成功路径 + 失败路径（错误 proof、重复领取、过期签名、错误签名、错误 epoch、篡改 amount/account 等）；
	•	Fuzz（扰动 proof / 字段）、EIP-1271（合约钱包签名）；
	•	Gas snapshot（可选）。

⸻

二、项目结构（建议目录）

rwa-coupon-distributor/
├─ foundry.toml
├─ lib/                         # remappings 依赖
├─ src/
│  ├─ RWACoupon.sol             # ERC20 收益券
│  └─ RWACouponDistributor.sol  # Merkle + EIP712 + 位图
├─ script/
│  ├─ GenerateInput.s.sol       # 产出 input.json（周度白名单）
│  ├─ MakeMerkle.s.sol          # 产出 output.json（root/proofs）
│  ├─ DeployAll.s.sol           # 部署 Token/Distributor + 设置 root + 充值
│  ├─ Claim.s.sol               # 使用 proof+signature 发起 claim
│  └─ SignClaims.ts             # （可选）批量生成 EIP-712 离线签名
├─ script/target/
│  ├─ input.json
│  └─ output.json
├─ test/
│  ├─ Distributor.t.sol         # 单测 + fuzz
│  └─ EIP1271Mock.sol           # 合约钱包签名模拟
└─ README.md


⸻

三、依赖与环境
	•	Solidity ^0.8.24
	•	OpenZeppelin：openzeppelin-contracts >= 5.x（ECDSA、SignatureChecker、EIP712、ERC20、Ownable、SafeERC20）
	•	Murky（Merkle 工具）
	•	foundry-devops（DevOpsTools，可选）
	•	Node（若用 SignClaims.ts 生成 EIP-712 签名）

安装（参考）
	•	forge install OpenZeppelin/openzeppelin-contracts
	•	forge install dmfxyz/murky
	•	forge install Cyfrin/foundry-devops（可选）

⸻

四、数据与文件格式

4.1 input.json（脚本生成，供造树）

{
  "types": ["uint","address","uint","uint"],
  "count": <N>,
  "values": {
    "0": { "0": "<index>", "1": "<account>", "2": "<amount>", "3": "<epochId>" },
    "1": { "0": "...",     "1": "...",       "2": "...",      "3": "..."       }
  }
}

	•	index：0..N-1（位图定位）
	•	account：投资者地址
	•	amount：本周应领额度（整型，18 位精度）
	•	epochId：周编号（例如 2025_32，用整数，比如 202532）

4.2 output.json（脚本生成，供领取）

数组，每个元素：

{
  "inputs": ["<index>","<account>","<amount>","<epochId>"],
  "proof": ["0x...","0x..."],
  "root": "0x<merkleRoot>",
  "leaf": "0x<leaf>"
}


⸻

五、合约设计（文件级与函数级需求）

5.1 src/RWACoupon.sol

目的：最简 ERC-20，用作被派发的收益券。
要求
	•	名称/符号可配置（如 RWA Coupon, RWAC），18 位；
	•	初始不铸币，由脚本铸给发行人，再转入 Distributor；
	•	事件与权限按 OZ 标准（Ownable 可选）。

对外函数（示例）
	•	constructor(string name, string symbol, address owner)
	•	mint(address to, uint256 amount)（仅 owner）
	•	其余继承自 ERC-20。

5.2 src/RWACouponDistributor.sol

目的：Merkle + EIP-712 + 位图防重复的派发核心。
状态
	•	IERC20 public coupon;
	•	mapping(uint256 => bytes32) public merkleRootByEpoch; // 每周 root
	•	mapping(uint256 => mapping(uint256 => uint256)) private claimedBitMap;
	•	mapping(address => uint256) public nonces; // EIP-712 per-account nonce
	•	bytes32 private constant CLAIM_TYPEHASH; // keccak256(“Claim(address account,uint256 amount,uint256 epochId,uint256 nonce,uint256 deadline)”)

事件
	•	event Claimed(uint256 indexed epochId, uint256 indexed index, address indexed account, uint256 amount);
	•	event MerkleRootUpdated(uint256 indexed epochId, bytes32 root);

错误
	•	InvalidProof() / AlreadyClaimed() / InvalidSignature() / SignatureExpired()

构造
	•	constructor(IERC20 _coupon, address _owner)
初始化 EIP-712 域：name="RWACouponDistributor", version="1"

外部/公开函数
	1.	setMerkleRoot(uint256 epochId, bytes32 root) external onlyOwner
设置/更新本周 root（允许重发快照；上线建议谨慎变更并公告）
	2.	claim(uint256 index, address account, uint256 amount, uint256 epochId, bytes32[] calldata proof, bytes calldata signature, uint256 deadline) external
	•	require !expired（block.timestamp <= deadline）
	•	require !claimed（位图检查）
	•	构造 EIP-712 digest(account, amount, epochId, nonces[account], deadline)
用 SignatureChecker.isValidSignatureNow(account, digest, signature) 验签
	•	计算叶子：keccak256(bytes.concat(keccak256(abi.encode(index, account, amount, epochId))))
	•	MerkleProof.verify(proof, merkleRootByEpoch[epochId], leaf) 通过
	•	更新状态：位图置位、nonces[account]++
	•	coupon.safeTransfer(account, amount) & emit Claimed(...)
	3.	只读辅助（可选）
	•	function isClaimed(uint256 epochId, uint256 index) external view returns (bool)
	•	function merkleRoot(uint256 epochId) external view returns (bytes32)（已由 public 映射提供）

内部函数
	•	_hashClaim(...) view returns (bytes32)：EIP-712 digest 生成
	•	_isClaimed/_setClaimed：位图读写（index→word/bit）

安全要求
	•	双哈希叶子防 second-preimage；
	•	abi.encode（非 encodePacked）防拼接歧义；
	•	SignatureChecker 兼容 EOA / EIP-1271；
	•	状态更新在转账前；
	•	SafeERC20 处理不规范 ERC-20；
	•	可选 nonReentrant（正常不需要，但可加）。

⸻

六、脚本设计（文件级与函数级需求）

6.1 script/GenerateInput.s.sol

目标：把本周投资者列表写成 input.json。
输入来源：脚本硬编码 / 读取 CSV（加分项）
输出：见 §4.1

核心函数
	•	run()：组装 types/count/values，写入 script/target/input.json
	•	工具函数：字符串拼接、数值转字符串等

6.2 script/MakeMerkle.s.sol

目标：读取 input.json → 生成 leafs、root、每个索引的 proof[] → 写 output.json。
关键：leaf = keccak256(bytes.concat(keccak256(abi.encode(index, account, amount, epochId))))（和合约保持一致）

核心函数
	•	run()：循环读取 values[i]，构造 data[]（bytes32 格式），abi.encode(data)→keccak256→bytes.concat→再 keccak256，得到 leafs[i]；用 Murky getRoot/getProof 生成整棵树结果并写文件。

6.3 script/DeployAll.s.sol

目标：部署合约，设置 root，充值。
步骤
	•	vm.startBroadcast()；部署 RWACoupon、RWACouponDistributor；
	•	从 output.json 读 root 与 epochId（或参数传入）；
	•	coupon.mint(owner, total) 并 coupon.transfer(distributor, total)；
	•	distributor.setMerkleRoot(epochId, root)；
	•	vm.stopBroadcast()；
	•	打印地址与关键信息（供后续签名和 claim 脚本使用）。

6.4 script/SignClaims.ts（可选）

目标：平台侧批量离线生成 EIP-712 签名（或由用户前端自签）。
要点
	•	Domain：{ name: "RWACouponDistributor", version: "1", chainId, verifyingContract }
	•	Types：Claim(account,address),(amount,uint256),(epochId,uint256),(nonce,uint256),(deadline,uint256)
	•	Value：从链上读取 nonces[account]，设定统一 deadline，签名后写入本地 CSV/JSON：
{ account, amount, epochId, nonce, deadline, signature }

6.5 script/Claim.s.sol

目标：脚本化领取。
输入：output.json 的 proof、account/amount/epochId/index，以及离线 signature。
流程
	•	vm.startBroadcast()；
	•	distributor.claim(index, account, amount, epochId, proof, signature, deadline)；
	•	vm.stopBroadcast()；
	•	打印余额变动、事件日志。

⸻

七、测试设计（Test Plan）

7.1 用例列表

成功路径
	•	T-01：正确 proof + signature，能领取到 amount，事件正确，nonces[account]++，位图置位。

失败路径
	•	T-02：重复领取 → AlreadyClaimed
	•	T-03：错误 proof（改 1 个字节）→ InvalidProof
	•	T-04：篡改 amount/account/epochId/index 任一字段 → InvalidProof 或 InvalidSignature
	•	T-05：签名过期（deadline < now）→ SignatureExpired
	•	T-06：错误签名（换 signer 或换 digest）→ InvalidSignature
	•	T-07：错误 epochId（root 不匹配）→ InvalidProof
	•	T-08：proof 顺序打乱 → InvalidProof

兼容 & 安全
	•	T-09：EIP-1271 Mock 合约钱包领取成功
	•	T-10：Fuzz 随机扰动 proof / 随机更改字段均失败
	•	T-11：Gas snapshot（可选）

7.2 断言要点
	•	余额变化：coupon.balanceOf(account) 恰增 amount
	•	nonces[account] 自增 1
	•	isClaimed(epochId, index) == true
	•	事件 Claimed(epochId, index, account, amount) 发出一次

⸻

八、工作流（你现在要做什么）
	1.	初始化与依赖
	•	forge init rwa-coupon-distributor
	•	安装依赖（OZ、Murky、foundry-devops 可选），写 remappings.txt
	•	forge build
	2.	定义数据
	•	收集本周白名单（index/account/amount/epochId）
	•	运行 GenerateInput.s.sol 生成 input.json
	3.	生成 Merkle
	•	运行 MakeMerkle.s.sol 生成 output.json（拿到 root）
	4.	实现合约（按本需求文档）
	•	RWACoupon、RWACouponDistributor
	•	forge build & forge fmt & forge snapshot（可选）
	5.	部署与充值
	•	填 output.json 的 root / epochId 到 DeployAll.s.sol（或读取文件）
	•	forge script ...DeployAll.s.sol --rpc-url ... --broadcast
	6.	生成签名
	•	方案 A：让用户在前端 _signTypedData（推荐真实场景）
	•	方案 B：离线批量签（SignClaims.ts），生成 {account, amount, epochId, nonce, deadline, signature}
	7.	发起领取
	•	Claim.s.sol 读取 proof + signature 调 claim
	•	验证余额与事件
	8.	测试
	•	完成 Distributor.t.sol 与 EIP1271Mock.sol
	•	forge test -vvv
	9.	文档化
	•	README：项目简介、命令说明、数据格式、注意事项
	•	记录一次完整跑通流程（含截图/日志）

⸻

九、非功能性要求（NFR）
	•	一致性：脚本与合约的 leaf 构造必须完全一致（双哈希 + abi.encode 顺序、类型、字节宽度）。
	•	安全性：
	•	不使用 abi.encodePacked 拼可变长；
	•	使用 SignatureChecker 兼容 EIP-1271；
	•	状态更新在转账前；
	•	仅 owner 可 setMerkleRoot；
	•	建议运营侧变更 root 需留审计轨迹（事件日志/PR 审核）。
	•	可移植性：合约不依赖链特性，直接可部署到以太坊/zkSync 等 EVM 链。
	•	可观测性：核心流程都有事件；脚本打印关键地址/参数。

⸻

十、验收标准（Definition of Done）
	•	✅ forge test 全绿，覆盖成功与失败路径、EIP-1271 与 fuzz；
	•	✅ 在本地 Anvil：完成生成→构树→部署→签名→领取闭环；
	•	✅ README 详细说明数据格式与脚本命令；
	•	✅ output.json 中任意条目可被脚本化成功领取；
	•	✅ Gas 不出现异常（单次领取在合理范围）。

⸻

十一、可选拓展（做完再加）
	•	批量领取：一次交易提交多条 Claim 节省 gas；
	•	多 Token：按 epochId 指定不同发放 Token（多产品线）；
	•	前端 Demo：纯前端 _signTypedData + 上传 proof，一键领取；
	•	L2 演练：zkSync Testnet（Type-113 交易），脚本保持不变。

⸻

需要我把 README 的命令章节也写好（含一条龙命令顺序与参数占位），或者把 SignClaims.ts 的输入输出字段模板再细化一下吗？我可以直接给你“复制即用”的文档片段。