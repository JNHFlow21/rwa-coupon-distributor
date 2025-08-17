// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {console2} from "forge-std/console2.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Merkle} from "murky/Merkle.sol";

/// @notice 读取 script/target/input.json → 生成 leaf/root/proofs → 写 script/target/output.json
/// 叶子算法（与合约完全一致）：
///   inner = keccak256(abi.encode(index, account, amount, epochId));
///   leaf  = keccak256(bytes.concat(inner));
contract MakeMerkle is Script {
    using stdJson for string;
    using Strings for uint256;

    string constant INPUT_PATH  = "/script/target/input.json";
    string constant OUTPUT_PATH = "/script/target/output.json";

    function run() external {
        string memory inPath  = string.concat(vm.projectRoot(), INPUT_PATH);
        string memory outPath = string.concat(vm.projectRoot(), OUTPUT_PATH);

        // 1) 读取 input.json
        string memory json = vm.readFile(inPath);

        // 校验 types 精确为 ["uint","address","uint","uint"]
        string[] memory typesArr = json.readStringArray(".types");
        require(typesArr.length == 4, "types length != 4");
        require(
            _eq(typesArr[0], "uint") &&
            _eq(typesArr[1], "address") &&
            _eq(typesArr[2], "uint") &&
            _eq(typesArr[3], "uint"),
            "types mismatch"
        );

        uint256 count = json.readUint(".count");
        require(count > 0, "empty list");

        // 2) 读每条记录
        address[] memory accounts = new address[](count);
        uint256[] memory indexes  = new uint256[](count);
        uint256[] memory amounts  = new uint256[](count);
        uint256[] memory epochs   = new uint256[](count);

        for (uint256 i = 0; i < count; i++) {
            string memory base = string.concat(".values.", vm.toString(i));
            string memory sIndex  = json.readString(string.concat(base, ".0"));
            string memory sAcct   = json.readString(string.concat(base, ".1"));
            string memory sAmount = json.readString(string.concat(base, ".2"));
            string memory sEpoch  = json.readString(string.concat(base, ".3"));

            indexes[i]  = vm.parseUint(sIndex);
            accounts[i] = vm.parseAddress(sAcct);
            amounts[i]  = vm.parseUint(sAmount);
            epochs[i]   = vm.parseUint(sEpoch);

            require(indexes[i] == i, "index must be sequential 0..count-1");
            require(amounts[i] > 0, "amount must be > 0");
        }

        // 3) 生成叶子（双哈希）
        bytes32[] memory leaves = new bytes32[](count);
        for (uint256 i = 0; i < count; i++) {
            bytes32 inner = keccak256(abi.encode(indexes[i], accounts[i], amounts[i], epochs[i]));
            leaves[i] = keccak256(bytes.concat(inner)); // 与合约保持一字不差
        }

        // 4) 构 root & 每条 proof
        Merkle m = new Merkle();
        bytes32 root = m.getRoot(leaves);

        // 5) 写 output.json（数组）
        string memory out = "[\n";
        for (uint256 i = 0; i < count; i++) {
            bytes32[] memory proof = m.getProof(leaves, i);

            // 仍沿用 input.json 中的原始字符串（避免前导零/精度格式化问题）
            string memory base = string.concat(".values.", vm.toString(i));
            string memory sIndex  = json.readString(string.concat(base, ".0"));
            string memory sAcct   = json.readString(string.concat(base, ".1"));
            string memory sAmount = json.readString(string.concat(base, ".2"));
            string memory sEpoch  = json.readString(string.concat(base, ".3"));

            string memory item = string.concat(
                "  {\n",
                '    "inputs": ["', sIndex, '","', sAcct, '","', sAmount, '","', sEpoch, '"],\n',
                '    "proof": ', _bytes32ArrayToJson(proof), ",\n",
                '    "root": "', _b32(root), '",\n',
                '    "leaf": "', _b32(leaves[i]), '"\n',
                "  }"
            );
            out = string.concat(out, item, i + 1 < count ? ",\n" : "\n");
        }
        out = string.concat(out, "]\n");

        string memory dir = string.concat(vm.projectRoot(), "/script/target");
        vm.createDir(dir, true);
        vm.writeFile(outPath, out);

        console2.log("output.json written to: %s", outPath);
        console2.log("   root = %s", _b32(root));
        console2.log("   entries = %s", count.toString());
    }

    // ===== helpers =====
    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function _b32(bytes32 v) internal pure returns (string memory) {
        return Strings.toHexString(uint256(v), 32); // 0x + 64 hex
    }

    function _bytes32ArrayToJson(bytes32[] memory arr) internal pure returns (string memory) {
        if (arr.length == 0) return "[]";
        string memory s = "[";
        for (uint256 i = 0; i < arr.length; i++) {
            s = string.concat(s, '"', Strings.toHexString(uint256(arr[i]), 32), '"', i + 1 < arr.length ? "," : "");
        }
        return string.concat(s, "]");
    }
}