// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import '@openzeppelin/contracts/access/AccessControl.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import './interfaces/IUniswapV2Factory.sol';
import './interfaces/IUniswapV2Router02.sol';

contract ERC20Fees is ERC20, Ownable, AccessControl {
  using SafeERC20 for IERC20;

  IUniswapV2Router02 public exchangeRouter;

  address public tokenPairAddress;

  mapping(address => bool) private _blacklist;
  mapping(address => bool) private _exemptFromFees;
  mapping(address => bool) public automatedMarketMakerPairs;

  address payable public royaltyFeeRecipient; // Address to which the ETH made from the fees are sent
  uint256 public royaltyFeeBalance = 0; // FEE TOKEN balance accumulated from royalty fees
  uint256 public liquidityFeeBalance = 0; // FEE TOKEN balance accumulated from liquidity fees
  uint256 public minimumRoyaltyFeeBalanceToSwap; // FEE TOKEN balance required to perform a swap
  uint256 public minimumLiquidityFeeBalanceToSwap; // FEE TOKEN balance required to add liquidity
  bool public swapEnabled = true;

  // Avoid having two swaps in the same block
  bool private _swappingRoyalty = false;
  bool private _swappingLiquidity = false;

  //  TWAP Period
  uint32 public constant TWAP_PERIOD = 10 minutes;


  uint256 public royaltySellingFee; // Fee going to royalties when selling the token (/1000)
  uint256 public liquidityBuyingFee; // Fee going to liquidity when buying the token (/1000)
  uint256 public liquiditySellingFee; // Fee going to liquidity when selling the token (/1000)

  // Used to avoid stack too deep errors
  struct FeeSetup {
    address royaltyFeeRecipient;
    uint256 royaltySellingFee;
    uint256 liquidityBuyingFee;
    uint256 liquiditySellingFee;
    uint256 minimumRoyaltyFeeBalanceToSwap;
    uint256 minimumLiquidityFeeBalanceToSwap;
  }

  /** Events Start*/

  event NewTokensMinted(
    address _minterAddress,
    uint256 _amount
  );

  event TokenBurned(
    address _address,
    uint256 _amountOfBurn
  );

  event Withdrawn (
    address _address,
    uint256 _withdrawAmount
  );

  event ERC20Withdrawn(
    address _erc20Address,
    uint256 _withdrawAmount
  );

  event ManualRoyaltySwapped(
    address _address
  );

  event ManualLiquify(
    address _address
  );

  event BlacklistAdded(
    address _address,
    bool _status
  );

  event SwapStatusToggled(
    bool _newStatus
  );

  event FeesExluded(
    address _account, 
    bool _state
  );

  event RoayltyRecipientAddressChanged(
    address _newAddress
  );

  event AutomatedMarketMakerPair(
    address _pair, 
    bool _value
  );

  event MinimumRoyaltyBalanceToSwap(
    uint256 _newMinimumRoyalty
  );

   event MinimumLiquidityFeeBalanceToSwap(
    uint256 _newMinimumRoyalty
  );

  event SetRoyaltySellingFee(
    uint256 _royaltySellingFee
  );

  event SetLiquidityBuyingFee(
    uint256 _liquidityBuyingFee
  );

  event SetLiquiditySellingFee(
    uint256 _liquiditySellingFee
  );

  /** Events End*/
  constructor(
    string memory _name,
    string memory _symbol,
    uint256 _initialSupply,
    address _defaultAdmin,
    address _exchangeRouter,
    FeeSetup memory _feeSetup
  ) payable ERC20(_name, _symbol) {
    require(_defaultAdmin != address(0), 'Default Admin address can not be null address');
    require(_exchangeRouter != address(0), 'Exchange Router address can not be null address');
    
    // Set up roles
    _setupRole(DEFAULT_ADMIN_ROLE, address(_defaultAdmin));


    // Set up token
    if(_initialSupply > 0) {
      _mint(address(_defaultAdmin), _initialSupply);
    }

    // Link to AMM
    exchangeRouter = IUniswapV2Router02(_exchangeRouter);
    tokenPairAddress = IUniswapV2Factory(exchangeRouter.factory()).createPair(address(this), exchangeRouter.WETH());
    _setAutomatedMarketMakerPair(address(tokenPairAddress), true);

    // Exempt some addresses from fees
    _exemptFromFees[msg.sender] = true;
    _exemptFromFees[_defaultAdmin] = true;
    _exemptFromFees[address(this)] = true;
    _exemptFromFees[address(0)] = true;

    
    // Set up fees
    royaltyFeeRecipient = payable(_feeSetup.royaltyFeeRecipient);
    royaltySellingFee = _feeSetup.royaltySellingFee;
    liquidityBuyingFee = _feeSetup.liquidityBuyingFee;
    liquiditySellingFee = _feeSetup.liquiditySellingFee;

    // Technical fee swapping thresholds
    minimumRoyaltyFeeBalanceToSwap = _feeSetup.minimumRoyaltyFeeBalanceToSwap;
    minimumLiquidityFeeBalanceToSwap = _feeSetup.minimumLiquidityFeeBalanceToSwap;
  }

  receive() external payable {}

  // Checks for blacklist status before allowing transfer
  function _beforeTokenTransfer(
    address _from,
    address _to,
    uint256 _amount
  ) internal virtual override(ERC20) {
    require(!isBlacklisted(_from), 'Token transfer refused. Sender is blacklisted');
    require(!isBlacklisted(_to), 'Token transfer refused. Recipient is blacklisted');
    super._beforeTokenTransfer(_from, _to, _amount);
  }

  // Collects relevant fees and performs a swap if needed
  function _transfer(
    address _from,
    address _to,
    uint256 _amount
  ) internal override {
    require(_from != address(0), 'Cannot transfer from the zero address');
    require(_amount > 0, 'Cannot transfer 0 tokens');
    uint256 royaltyFees = 0;
    uint256 liquidityFees = 0;

    // Take fees on buys and sells
    if (!_exemptFromFees[_from] && !_exemptFromFees[_to]) {
      // Selling
      if (automatedMarketMakerPairs[_to]) {
        uint256 totalFee = royaltySellingFee + liquiditySellingFee;
        require(totalFee <= 100_0, "Total fees exceed 100%");

        if (royaltySellingFee > 0) royaltyFees = (_amount * royaltySellingFee) / 100_0;
        if (liquiditySellingFee > 0) liquidityFees = (_amount * liquiditySellingFee) / 100_0;
        require(totalFee <= 10_0, "Fees exceed maximum limit");

      }
      // Buying
      else if (automatedMarketMakerPairs[_from]) {
        if (liquidityBuyingFee > 0) liquidityFees = (_amount * liquidityBuyingFee) / 100_0;
      }

      uint256 totalFees = royaltyFees + liquidityFees;

      // Send fees to the FEETOKEN contract
      if (totalFees > 0) {
        // Send FEETOKEN tokens to the contract
        super._transfer(_from, address(this), totalFees);

        // Keep track of the FEETOKEN that were sent
        royaltyFeeBalance += royaltyFees;
        liquidityFeeBalance += liquidityFees;
      }

      _amount -= totalFees;
    }

    // Swapping logic - only trigger on sell
    if (swapEnabled && automatedMarketMakerPairs[_to]) {
      // If the one of the fee balances is above a certain amount, process it
      // Do not process both in one transaction
      if (!_swappingRoyalty && !_swappingLiquidity && royaltyFeeBalance > minimumRoyaltyFeeBalanceToSwap) {
        // Forbid swapping royalty fees
        _swappingRoyalty = true;

        // Perform the swap
        _swapRoyaltyFeeBalance();

        // Allow swapping
        _swappingRoyalty = false;
      } else if (!_swappingRoyalty && !_swappingLiquidity && liquidityFeeBalance > minimumLiquidityFeeBalanceToSwap) {
        // Forbid swapping liquidity fees
        _swappingLiquidity = true;

        // Perform the swap
        _liquify();

        // Allow swapping
        _swappingLiquidity = false;
      }
    }

    super._transfer(_from, _to, _amount);
  }

  // Swaps liquidity fee balance for ETH and adds it to the WETH / TOKEN pool
  function _liquify() internal {
    require(liquidityFeeBalance > minimumLiquidityFeeBalanceToSwap, 'Not enough tokens to swap for adding liquidity');

    uint256 oldBalance = address(this).balance;

    // Sell half of the liquidity fee balance for ETH
    uint256 lowerHalf = liquidityFeeBalance / 2;
    uint256 upperHalf = liquidityFeeBalance - lowerHalf;

    // Swap
    _swapTokenForEth(lowerHalf);

    // Update liquidityFeeBalance
    liquidityFeeBalance = 0;

    // Add liquidity
    _addLiquidity(upperHalf, address(this).balance - oldBalance);
  }

  // Adds liquidity to the WETH / TOKEN pair on the AMM
  function _addLiquidity(uint256 _tokenAmount, uint256 _ethAmount) internal {
    _approve(address(this), address(exchangeRouter), _tokenAmount);

    // Add liquidity
    exchangeRouter.addLiquidityETH{value: _ethAmount}(
      address(this),
      _tokenAmount,
      0, // Slippage is unavoidable
      0, // Slippage is unavoidable
      address(0),
      block.timestamp
    );

  }

  function _createOrGetPair() internal returns (IUniswapV2Pair uniswapPair) {
        if (tokenPairAddress == address(0)) {
            tokenPairAddress = IUniswapV2Factory(exchangeRouter.factory()).createPair(address(this), exchangeRouter.WETH());
        }
        return IUniswapV2Pair(tokenPairAddress);
  }

  function _consult(uint256 amountIn) internal returns (uint256 amountOut) {
        IUniswapV2Pair uniswapPair = _createOrGetPair();
        (uint112 reserve0, uint112 reserve1, ) = uniswapPair.getReserves();
        uint256 reserveIn = address(this) == uniswapPair.token0() ? reserve0 : reserve1;
        uint256 reserveOut = address(this) == uniswapPair.token0() ? reserve1 : reserve0;
        amountOut = (amountIn * reserveOut) / reserveIn;
    }



  // Swaps royalty fee balance for ETH and sends it to the royalty fee recipient
  function _swapRoyaltyFeeBalance() internal {
    require(royaltyFeeBalance > minimumRoyaltyFeeBalanceToSwap, 'Not enough tokens to swap for royalty fee');

    uint256 oldBalance = address(this).balance;

    // Swap
    _swapTokenForEth(royaltyFeeBalance);

    // Update royaltyFeeBalance
    royaltyFeeBalance = 0;

    // Send ETH to royalty fee recipient
    uint256 toSend = address(this).balance - oldBalance;
    (bool success, ) = payable(royaltyFeeRecipient).call{value: toSend}("");
    require(success, 'Royalty Fee Recipient Transfer Failed');
  }

  // Swaps "_tokenAmount" for ETH
  function _swapTokenForEth(uint256 _tokenAmount) internal {
    // Define the path of the token and WETH in the Uniswap V2 router
    address[] memory path = new address[](2);
    path[0] = address(this);
    path[1] = exchangeRouter.WETH();

    // Approve the Uniswap V2 router to spend the token
    _approve(address(this), address(exchangeRouter), _tokenAmount);

    // Get the minimum amount of ETH based on TWAP
    uint256 _minAmountEth = _consult(_tokenAmount);

    exchangeRouter.swapExactTokensForETHSupportingFeeOnTransferTokens(
      _tokenAmount,
      _minAmountEth, // accept any amount of ETH
      path,
      address(this),
      block.timestamp
    );
  }

  // Set or unset an address as an automated market pair / removes
  function _setAutomatedMarketMakerPair(address _pair, bool _value) internal {
    automatedMarketMakerPairs[_pair] = _value;
  }

  // Returns true if "_user" is blacklisted
  function isBlacklisted(address _user) public view returns (bool) {
    return _blacklist[_user];
  }

  // Mint new tokens
  function mint(address _to, uint256 _amount) public onlyRole(DEFAULT_ADMIN_ROLE) {
    require(_to != address(0), 'Minter Address can not be null address');
    require(_amount > 0, 'Mintable tokens count must be greater than 0');

    _mint(_to, _amount);
    emit NewTokensMinted(_to, _amount);
  }

  // Burns tokens
  function burnTokens(address _from, uint256 _amount) public onlyRole(DEFAULT_ADMIN_ROLE) {
    require(_from != address(0), 'Minter Address can not be null address');
    require(_amount > 0, 'Mintable tokens count must be greater than 0');
    _burn(_from, _amount);
    emit TokenBurned(_from, _amount);
  }

  function withdraw(uint256 _amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
     //send deploy feee to ForkChain
      (bool success, ) = payable(msg.sender).call{value: _amount}("");
      require(success, "Transfer failed.");

      emit Withdrawn(msg.sender, _amount);
  }

  // Withdraws an amount of tokens stored on the contract
  function withdrawERC20(address _erc20, uint256 _amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(_erc20 != address(0), 'Minter Address can not be null address');
    require(_amount > 0, 'Mintable tokens count must be greater than 0');

   IERC20(_erc20).safeTransfer(msg.sender, _amount);

    emit ERC20Withdrawn(_erc20, _amount);
  }

  // Manually swaps the royalty fees
  function manualRoyaltyFeeSwap() external onlyRole(DEFAULT_ADMIN_ROLE) {
    // Forbid swapping royalty fees
    _swappingRoyalty = true;

    // Perform the swap
    _swapRoyaltyFeeBalance();

    // Allow swapping again
    _swappingRoyalty = false;

    emit ManualRoyaltySwapped(msg.sender);
  }

  // Manually add liquidity
  function manualLiquify() external onlyRole(DEFAULT_ADMIN_ROLE) {
    // Forbid swapping liquidity fees
    _swappingLiquidity = true;

    // Perform swap
    _liquify();

    // Allow swapping again
    _swappingLiquidity = false;

    emit ManualLiquify(msg.sender);
  }

  function blacklistAddress(address _user, bool _state) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(_user != address(0), 'User address cannot be the zero address');
    _blacklist[_user] = _state;
    emit BlacklistAdded(_user, _state);
  }

  function toggleSwapping() external onlyRole(DEFAULT_ADMIN_ROLE) {
    swapEnabled = !swapEnabled;
    emit SwapStatusToggled(swapEnabled);
  }

  function excludeFromFees(address _account, bool _state) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(_account != address(0), 'Account address can not be null address');
    _exemptFromFees[_account] = _state;
    emit FeesExluded(_account, _state);
  }

  function setRoyaltyFeeRecipient(address _royaltyFeeRecipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(_royaltyFeeRecipient != address(0), 'Royalty recipient address can not be null address');
    royaltyFeeRecipient = payable(_royaltyFeeRecipient);
    emit RoayltyRecipientAddressChanged(_royaltyFeeRecipient);
  }

  function setAutomatedMarketMakerPair(address _pair, bool _value) external onlyRole(DEFAULT_ADMIN_ROLE) {
    require(_pair != tokenPairAddress, 'The WETH / TOKEN pair cannot be removed from _automatedMarketMakerPairs');
    _setAutomatedMarketMakerPair(_pair, _value);
    emit AutomatedMarketMakerPair(_pair, _value);
  }

  function setMinimumRoyaltyFeeBalanceToSwap(uint256 _minimumRoyaltyFeeBalanceToSwap) external onlyRole(DEFAULT_ADMIN_ROLE) {
    minimumRoyaltyFeeBalanceToSwap = _minimumRoyaltyFeeBalanceToSwap;
    emit MinimumRoyaltyBalanceToSwap(_minimumRoyaltyFeeBalanceToSwap);
  }

  function setMinimumLiquidityFeeBalanceToSwap(uint256 _minimumLiquidityFeeBalanceToSwap) external onlyRole(DEFAULT_ADMIN_ROLE) {
    minimumLiquidityFeeBalanceToSwap = _minimumLiquidityFeeBalanceToSwap;
    emit MinimumLiquidityFeeBalanceToSwap(_minimumLiquidityFeeBalanceToSwap);
  }

  function setRoyaltySellingFee(uint256 _royaltySellingFee) external onlyRole(DEFAULT_ADMIN_ROLE) {
    royaltySellingFee = _royaltySellingFee;
    emit SetRoyaltySellingFee(_royaltySellingFee);
  }

  function setLiquidityBuyingFee(uint256 _liquidityBuyingFee) external onlyRole(DEFAULT_ADMIN_ROLE) {
    liquidityBuyingFee = _liquidityBuyingFee;
    emit SetLiquidityBuyingFee(_liquidityBuyingFee);
  }

  function setLiquiditySellingFee(uint256 _liquiditySellingFee) external onlyRole(DEFAULT_ADMIN_ROLE) {
    liquiditySellingFee = _liquiditySellingFee;
    emit SetLiquiditySellingFee(_liquiditySellingFee);
  }
}