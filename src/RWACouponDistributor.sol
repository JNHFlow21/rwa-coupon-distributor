// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./RWACoupon.sol";

contract RWACouponDistributor is Ownable {
    RWACoupon public coupon;

    constructor(address _coupon) Ownable(msg.sender) {}
}