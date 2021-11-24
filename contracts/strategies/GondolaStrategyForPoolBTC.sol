// SPDX-License-Identifier: MIT
pragma solidity 0.7.3;

import "../YakStrategy.sol";
import "../interfaces/IGondolaChef.sol";
import "../interfaces/IRouter.sol";
import "../interfaces/IPair.sol";
import "../interfaces/IGondolaPool.sol";

/**
 * @notice StableSwap strategy for Gondola WBTC/zBTC
 */
contract GondolaStrategyForPoolBTC is YakStrategy {
  using SafeMath for uint;

  IRouter public router;
  IGondolaChef public stakingContract;
  IGondolaPool public poolContract;

  address private constant WAVAX = 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7;
  address private constant WBTC = 0x408D4cD0ADb7ceBd1F1A1C33A0Ba2098E1295bAB;
  address private constant ZBTC = 0xc4f4Ff34A2e2cF5e4c892476BB2D056871125452;
  address private constant ZERO = 0x008E26068B3EB40B443d3Ea88c1fF99B789c10F7;
  IRouter private constant PANGO_ROUTER = IRouter(0xE54Ca86531e17Ef3616d22Ca28b0D458b6C89106);
  IRouter private constant ZERO_ROUTER = IRouter(0x85995d5f8ee9645cA855e92de16FA62D26398060);

  uint public PID;

  constructor(
    string memory _name,
    address _depositToken, 
    address _rewardToken, 
    address _stakingContract,
    address _poolContract,
    address _timelock,
    uint _pid,
    uint _minTokensToReinvest,
    uint _adminFeeBips,
    uint _devFeeBips,
    uint _reinvestRewardBips
  ) {
    name = _name;
    depositToken = IPair(_depositToken);
    rewardToken = IERC20(_rewardToken);
    stakingContract = IGondolaChef(_stakingContract);
    poolContract = IGondolaPool(_poolContract);
    PID = _pid;
    devAddr = msg.sender;

    setAllowances();
    updateMinTokensToReinvest(_minTokensToReinvest);
    updateAdminFee(_adminFeeBips);
    updateDevFee(_devFeeBips);
    updateReinvestReward(_reinvestRewardBips);
    updateDepositsEnabled(true);
    transferOwnership(_timelock);

    emit Reinvest(0, 0);
  }

  /**
   * @notice Approve tokens for use in Strategy
   * @dev Restricted to avoid griefing attacks
   */
  function setAllowances() public override onlyOwner {
    depositToken.approve(address(stakingContract), MAX_UINT);
    rewardToken.approve(address(PANGO_ROUTER), MAX_UINT);
    rewardToken.approve(address(ZERO_ROUTER), MAX_UINT);
    IERC20(WBTC).approve(address(poolContract), MAX_UINT);
    IERC20(ZBTC).approve(address(poolContract), MAX_UINT);
  }

  /**
   * @notice Deposit tokens to receive receipt tokens
   * @param amount Amount of tokens to deposit
   */
  function deposit(uint amount) external override {
    _deposit(msg.sender, amount);
  }

  /**
   * @notice Deposit using Permit
   * @param amount Amount of tokens to deposit
   * @param deadline The time at which to expire the signature
   * @param v The recovery byte of the signature
   * @param r Half of the ECDSA signature pair
   * @param s Half of the ECDSA signature pair
   */
  function depositWithPermit(uint amount, uint deadline, uint8 v, bytes32 r, bytes32 s) external override {
    depositToken.permit(msg.sender, address(this), amount, deadline, v, r, s);
    _deposit(msg.sender, amount);
  }

  function depositFor(address account, uint amount) external override {
      _deposit(account, amount);
  }

  function _deposit(address account, uint amount) internal {
    require(DEPOSITS_ENABLED == true, "GondolaStrategyForStableSwap::_deposit");
    if (MAX_TOKENS_TO_DEPOSIT_WITHOUT_REINVEST > 0) {
        uint unclaimedRewards = checkReward();
        if (unclaimedRewards > MAX_TOKENS_TO_DEPOSIT_WITHOUT_REINVEST) {
            _reinvest(unclaimedRewards);
        }
    }
    require(depositToken.transferFrom(msg.sender, address(this), amount));
    _stakeDepositTokens(amount);
    _mint(account, getSharesForDepositTokens(amount));
    totalDeposits = totalDeposits.add(amount);
    emit Deposit(account, amount);
  }

  function withdraw(uint amount) external override {
    uint depositTokenAmount = getDepositTokensForShares(amount);
    if (depositTokenAmount > 0) {
      _withdrawDepositTokens(depositTokenAmount);
      require(depositToken.transfer(msg.sender, depositTokenAmount), "GondolaStrategyForStableSwap::withdraw");
      _burn(msg.sender, amount);
      totalDeposits = totalDeposits.sub(depositTokenAmount);
      emit Withdraw(msg.sender, depositTokenAmount);
    }
  }

  function _withdrawDepositTokens(uint amount) private {
    require(amount > 0, "GondolaStrategyForStableSwap::_withdrawDepositTokens");
    stakingContract.withdraw(PID, amount);
  }

  function reinvest() external override onlyEOA {
    uint unclaimedRewards = checkReward();
    require(unclaimedRewards >= MIN_TOKENS_TO_REINVEST, "GondolaStrategyForStableSwap::reinvest");
    _reinvest(unclaimedRewards);
  }

  /**
    * @notice Reinvest rewards from staking contract to deposit tokens
    * @dev Reverts if the expected amount of tokens are not returned from `stakingContract`
    * @param amount deposit tokens to reinvest
    */
  function _reinvest(uint amount) private {
    stakingContract.deposit(PID, 0);

    uint devFee = amount.mul(DEV_FEE_BIPS).div(BIPS_DIVISOR);
    if (devFee > 0) {
      require(rewardToken.transfer(devAddr, devFee), "GondolaStrategyForStableSwap::_reinvest, dev");
    }

    uint adminFee = amount.mul(ADMIN_FEE_BIPS).div(BIPS_DIVISOR);
    if (adminFee > 0) {
      require(rewardToken.transfer(owner(), adminFee), "GondolaStrategyForStableSwap::_reinvest, admin");
    }

    uint reinvestFee = amount.mul(REINVEST_REWARD_BIPS).div(BIPS_DIVISOR);
    if (reinvestFee > 0) {
      require(rewardToken.transfer(msg.sender, reinvestFee), "GondolaStrategyForStableSwap::_reinvest, reward");
    }

    uint depositTokenAmount = _convertRewardTokensToDepositTokens(
      amount.sub(devFee).sub(adminFee).sub(reinvestFee)
    );

    _stakeDepositTokens(depositTokenAmount);
    totalDeposits = totalDeposits.add(depositTokenAmount);

    emit Reinvest(totalDeposits, totalSupply);
  }
    
  function _stakeDepositTokens(uint amount) private {
    require(amount > 0, "GondolaStrategyForStableSwap::_stakeDepositTokens");
    stakingContract.deposit(PID, amount);
  }

  function checkReward() public override view returns (uint) {
    uint pendingReward = stakingContract.pendingGondola(PID, address(this));
    uint contractBalance = rewardToken.balanceOf(address(this));
    return pendingReward.add(contractBalance);
  }

  /**
    * @notice Converts reward tokens to deposit tokens
    * @dev Always converts through router; there are no price checks enabled
    * @return deposit tokens received
    */
  function _convertRewardTokensToDepositTokens(uint amount) private returns (uint) {
    require(amount > 0, "GondolaStrategyForStableSwap::_convertRewardTokensToDepositTokens");

    IRouter _router;
    uint[] memory liquidityAmounts = new uint[](2);
    address[] memory path = new address[](3);
    path[0] = address(rewardToken);

    // find route for bonus token
    if (poolContract.getTokenBalance(0) < poolContract.getTokenBalance(1)) {
      // convert to 0
      path[1] = WAVAX;
      path[2] = WBTC;
      _router = PANGO_ROUTER;
      uint[] memory amountsOutToken = _router.getAmountsOut(amount, path);
      uint amountOutToken = amountsOutToken[amountsOutToken.length - 1];
      _router.swapExactTokensForTokens(amount, amountOutToken, path, address(this), block.timestamp);
      liquidityAmounts[0] = amountOutToken;
    }
    else {
      // convert to 1
      path[1] = ZERO;
      path[2] = ZBTC;
      _router = ZERO_ROUTER;
      uint[] memory amountsOutToken = _router.getAmountsOut(amount, path);
      uint amountOutToken = amountsOutToken[amountsOutToken.length - 1];
      _router.swapExactTokensForTokens(amount, amountOutToken, path, address(this), block.timestamp);
      liquidityAmounts[1] = amountOutToken;
    }

    uint liquidity = poolContract.addLiquidity(liquidityAmounts, 0, block.timestamp);
    return liquidity;
  }

  /**
   * @notice Estimate recoverable balance
   * @return deposit tokens
   */
  function estimateDeployedBalance() external override view returns (uint) {
    (uint depositBalance, ) = stakingContract.userInfo(PID, address(this));
    return depositBalance;
  }

  function rescueDeployedFunds(uint minReturnAmountAccepted, bool disableDeposits) external override onlyOwner {
    uint balanceBefore = depositToken.balanceOf(address(this));
    stakingContract.emergencyWithdraw(PID);
    uint balanceAfter = depositToken.balanceOf(address(this));
    require(balanceAfter.sub(balanceBefore) >= minReturnAmountAccepted, "GondolaStrategyForStableSwap::rescueDeployedFunds");
    totalDeposits = balanceAfter;
    emit Reinvest(totalDeposits, totalSupply);
    if (DEPOSITS_ENABLED == true && disableDeposits == true) {
      updateDepositsEnabled(false);
    }
  }
}