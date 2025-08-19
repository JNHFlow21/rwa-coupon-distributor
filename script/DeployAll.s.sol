// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {RWACoupon} from "src/RWACoupon.sol";
import {RWACouponDistributor} from "src/RWACouponDistributor.sol";

import {HelperConfig, ChainConfig} from "./HelperConfig.s.sol";

contract DeployAll is Script {
    using stdJson for string;
    using Strings for uint256;

    string constant INPUT_PATH  = "/script/target/input.json";
    string constant OUTPUT_PATH = "/script/target/output.json";

    HelperConfig helper = new HelperConfig();
    ChainConfig cfg = helper.getActiveChainConfig();


    function run() external {
        uint256 pk = cfg.deployerPrivateKey;
        address owner = vm.addr(pk);

        // 读取 input/output
        string memory inputPath  = string.concat(vm.projectRoot(), INPUT_PATH);
        string memory outputPath = string.concat(vm.projectRoot(), OUTPUT_PATH);
        string memory inJson  = vm.readFile(inputPath);
        string memory outJson = vm.readFile(outputPath);

        // epochId：来自 input.json（任意一项的 "3"）
        uint256 count = inJson.readUint(".count");
        require(count > 0, "empty list");
        string memory epochStr = inJson.readString(".values.0.3");
        uint256 epochId = vm.parseUint(epochStr);

        // root：来自 output.json 第一项
        bytes32 root = outJson.readBytes32("[0].root");

        // 计算本周总额（给 Distributor 充值）
        uint256 total;
        for (uint256 i = 0; i < count; i++) {
            string memory sAmount = inJson.readString(string.concat(".values.", vm.toString(i), ".2"));
            total += vm.parseUint(sAmount);
        }

        vm.startBroadcast(pk);

        // 1) 部署 Token（名字/符号可自定）
        RWACoupon coupon = new RWACoupon();
        // 2) 部署 Distributor（owner 建议多签/运营地址，这里先用当前 signer）
        RWACouponDistributor distributor = new RWACouponDistributor(IERC20(address(coupon)), owner);

        // 3) mint + transfer 到 Distributor
        coupon.mint(owner, total);
        require(coupon.transfer(address(distributor), total), "transfer to distributor failed");

        // 4) 设置本周 root
        distributor.setMerkleRoot(epochId, root);

        vm.stopBroadcast();

        // 打印关键信息
        console2.log(" Deployed:");
        console2.log("  coupon        :", address(coupon));
        console2.log("  distributor   :", address(distributor));
        console2.log("  owner         :", owner);
        console2.log("  epochId       :", epochId);
        console2.log("  root          :", vm.toString(root));
        console2.log("  total funded  :", total.toString());
    }
}