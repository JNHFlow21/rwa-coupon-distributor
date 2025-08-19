// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

/// 生成本周白名单 input.json（与 §4.1 完全一致）
contract GenerateInput is Script {
    using Strings for uint256;

    // ===== 根据你当周实际情况修改 =====
    uint256 private constant EPOCH_ID = 202532; // 例如 2025年第32周 → 202532
    uint256 private constant AMOUNT = 25 ether; // 统一金额（18位）

    // 建议用 address[]，更安全
    address[] private whitelist = new address[](4);

    string private constant REL_PATH = "/script/target/input.json";

    function run() public {
        // 1) 白名单（替换成真实地址）
        whitelist[0] = 0x6CA6d1e2D5347Bfab1d91e883F1915560e09129D;
        whitelist[1] = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;
        whitelist[2] = 0x2ea3970Ed82D5b30be821FAAD4a731D35964F7dd;
        whitelist[3] = 0xf6dBa02C01AF48Cf926579F77C9f874Ca640D91D;

        // 2) 生成 JSON
        string memory json = _createJSON(whitelist, AMOUNT, EPOCH_ID);

        // 3) 写文件（确保目录存在）
        string memory dir = string.concat(vm.projectRoot(), "/script/target");
        string memory path = string.concat(vm.projectRoot(), REL_PATH);
        vm.createDir(dir, true);
        vm.writeFile(path, json);

        console2.log("input.json written to: %s", path);
        console2.log("   count = %s, epochId = %s", Strings.toString(whitelist.length), Strings.toString(EPOCH_ID));
    }

    function _createJSON(address[] memory addrs, uint256 amount, uint256 epochId)
        internal
        pure
        returns (string memory json)
    {
        json = string.concat(
            "{\n",
            '  "types": ["uint","address","uint","uint"],\n',
            '  "count": ',
            Strings.toString(addrs.length),
            ",\n",
            '  "values": {\n'
        );

        for (uint256 i = 0; i < addrs.length; i++) {
            json = string.concat(
                json,
                '    "',
                Strings.toString(i),
                '": { ',
                '"0": "',
                Strings.toString(i),
                '", ',
                '"1": "',
                Strings.toHexString(uint160(addrs[i]), 20),
                '", ',
                '"2": "',
                Strings.toString(amount),
                '", ',
                '"3": "',
                Strings.toString(epochId),
                '" ',
                "}"
            );
            if (i + 1 < addrs.length) json = string.concat(json, ",");
            json = string.concat(json, "\n");
        }

        json = string.concat(json, "  }\n}\n");
        return json;
    }
}
