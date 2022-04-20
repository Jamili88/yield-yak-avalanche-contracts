// SPDX-License-Identifier: MIT
pragma solidity 0.7.3;

import "./interfaces/IPlatypusVoter.sol";
import "./interfaces/IJoeVoter.sol";
import "./interfaces/IBoosterFeeCollector.sol";
import "./lib/Ownable.sol";
import "./lib/ERC20.sol";
import "./lib/SafeERC20.sol";
import "./lib/SafeMath.sol";

contract BoosterFeeCollector is Ownable, IBoosterFeeCollector {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    uint256 internal constant BIPS_DIVISOR = 10000;

    IERC20 public constant PTP = IERC20(0x22d4002028f537599bE9f666d1c4Fa138522f9c8);
    IERC20 public constant JOE = IERC20(0x6e84a6216eA6dACC71eE8E6b0a5B7322EEbC0fDd);
    IPlatypusVoter public constant yyPTP = IPlatypusVoter(0x40089e90156Fc6F994cc0eC86dbe84634A1C156F);
    IJoeVoter public constant yyJOE = IJoeVoter(0xe7462905B79370389e8180E300F58f63D35B725F);

    mapping(address => uint256) public boostFeeBips;
    address public boosterFeeReceiver;
    bool paused = false;

    event Paused(bool paused);
    event BoostFeeReceiverUpdated(address oldValue, address newValue);
    event BoostFeeUpdated(address strategy, uint256 oldValue, uint256 newValue);

    constructor(address _boosterFeeReceiver) {
        boosterFeeReceiver = _boosterFeeReceiver;
    }

    function setBoostFee(address _strategy, uint256 _boostFeeBips) external override onlyOwner {
        require(_boostFeeBips <= BIPS_DIVISOR, "BoosterFeeCollector::Chosen boost fee too high");
        emit BoostFeeUpdated(_strategy, boostFeeBips[_strategy], _boostFeeBips);
        boostFeeBips[_strategy] = _boostFeeBips;
    }

    function setBoosterFeeReceiver(address _boosterFeeReceiver) external override onlyOwner {
        emit BoostFeeReceiverUpdated(boosterFeeReceiver, _boosterFeeReceiver);
        boosterFeeReceiver = _boosterFeeReceiver;
    }

    function setPaused(bool _paused) external override onlyOwner {
        paused = _paused;
        emit Paused(_paused);
    }

    function calculateBoostFee(address _strategy, uint256 _amount) external view override returns (uint256) {
        if (paused) return 0;
        uint256 boostFee = boostFeeBips[_strategy];
        return _amount.mul(boostFee).div(BIPS_DIVISOR);
    }

    function compound() external override {
        uint256 amount;
        if (yyPTP.depositsEnabled()) {
            amount = PTP.balanceOf(address(this));
            PTP.approve(address(yyPTP), amount);
            yyPTP.deposit(amount);
            IERC20(address(yyPTP)).safeTransfer(boosterFeeReceiver, amount);
        }

        if (yyJOE.depositsEnabled()) {
            amount = JOE.balanceOf(address(this));
            JOE.approve(address(yyJOE), amount);
            yyJOE.deposit(amount);
            IERC20(address(yyJOE)).safeTransfer(boosterFeeReceiver, amount);
        }
    }
}
