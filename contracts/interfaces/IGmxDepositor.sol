// SPDX-License-Identifier: MIT
pragma solidity 0.7.3;

interface IGmxDepositor {
    function execute(
        address to,
        uint256 value,
        bytes calldata data
    ) external returns (bool, bytes memory);

    function setGmxProxy(address _proxy) external;
}
