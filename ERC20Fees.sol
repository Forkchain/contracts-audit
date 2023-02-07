// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import '@openzeppelin/contracts/access/AccessControl.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import './interfaces/IUniswapV2Factory.sol';
import './interfaces/IUniswapV2Router02.sol';

contract ERC20Fees is ERC20, Ownable, AccessControl {
  bytes32 public constant DAO = keccak256('DAO');

  IUniswapV2Router02 public exchangeRouter;

  address public tokenDAO;
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
  bool private swappingRoyalty = false;
  bool private swappingLiquidity = false;

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

  event DAOBurned(
    address _daoAddress,
    uint256 _amountOfBurn
  );

  event DAOWithdrawn (
    address _daoAddress,
    uint256 _withdrawAmount
  );

  event DAOERC20Withdrawn(
    address _erc20Address,
    uint256 _withdrawAmount
  );

  event DAOManualRoyaltySwapped(
    address _daoAddress
  );

  event DAOManualLiquify(
    address _daoAddress
  );

  event DAOChanged(
    address _newDAOAddress
  );

  event DAORevoked (
    address _revokeDAOAddress
  );

  event BlacklistDAO(
    address _daoAddress,
    bool _status
  );

  event DAOSwapStatusToggled(
    bool _newStatus
  );

  event DAOFeesExluded(
    address _account, 
    bool _state
  );

  event RoayltyRecipientAddressChanged(
    address _newAddress
  );

  event AutomatedMarketMakerPairDAO(
    address _pair, 
    bool _value
  );

  event MinimumRoyaltyBalanceToSwapDAOChanged(
    uint256 _newMinimumRoyalty
  );

   event MinimumLiquidityFeeBalanceToSwapDAOChanged(
    uint256 _newMinimumRoyalty
  );

  event SetRoyaltySellingFeeDAO(
    uint256 _royaltySellingFee
  );

  event SetLiquidityBuyingFeeDAO(
    uint256 _liquidityBuyingFee
  );

  event SetLiquiditySellingFeeDAO(
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
    _setupRole(DAO, address(_defaultAdmin));

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
        if (royaltySellingFee > 0) royaltyFees = (_amount * royaltySellingFee) / 1000;
        if (liquiditySellingFee > 0) liquidityFees = (_amount * liquiditySellingFee) / 1000;
      }
      // Buying
      else if (automatedMarketMakerPairs[_from]) {
        if (liquidityBuyingFee > 0) liquidityFees = (_amount * liquidityBuyingFee) / 1000;
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
      if (!swappingRoyalty && !swappingLiquidity && royaltyFeeBalance > minimumRoyaltyFeeBalanceToSwap) {
        // Forbid swapping royalty fees
        swappingRoyalty = true;

        // Perform the swap
        _swapRoyaltyFeeBalance();

        // Allow swapping
        swappingRoyalty = false;
      } else if (!swappingRoyalty && !swappingLiquidity && liquidityFeeBalance > minimumLiquidityFeeBalanceToSwap) {
        // Forbid swapping liquidity fees
        swappingLiquidity = true;

        // Perform the swap
        _liquify();

        // Allow swapping
        swappingLiquidity = false;
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
    address[] memory path = new address[](2);
    path[0] = address(this);
    path[1] = exchangeRouter.WETH();

    _approve(address(this), address(exchangeRouter), _tokenAmount);

    exchangeRouter.swapExactTokensForETHSupportingFeeOnTransferTokens(
      _tokenAmount,
      0, // accept any amount of ETH
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
  function _mintTo(address _to, uint256 _amount) public onlyRole(DAO) {
    require(_to != address(0), 'Minter Address can not be null address');
    require(_amount > 0, 'Mintable tokens count must be greater than 0');

    _mint(_to, _amount);
    emit NewTokensMinted(_to, _amount);
  }

  // Burns tokens
  function burnDAO(address _from, uint256 _amount) public onlyRole(DAO) {
    require(_from != address(0), 'Minter Address can not be null address');
    require(_amount > 0, 'Mintable tokens count must be greater than 0');
    _burn(_from, _amount);
    emit DAOBurned(_from, _amount);
  }

  function withdrawDAO(uint256 _amount) external onlyRole(DAO) {
     //send deploy feee to ForkChain
      (bool success, ) = payable(msg.sender).call{value: _amount}("");
      require(success, "Transfer failed.");

      emit DAOWithdrawn(msg.sender, _amount);
  }

  // Withdraws an amount of tokens stored on the contract
  function withdrawERC20DAO(address _erc20, uint256 _amount) external onlyRole(DAO) {
    require(_erc20 != address(0), 'Minter Address can not be null address');
    require(_amount > 0, 'Mintable tokens count must be greater than 0');

    bool success = IERC20(_erc20).transfer(msg.sender, _amount);
    require(success, "Transfer failed.");

    emit DAOERC20Withdrawn(_erc20, _amount);
  }

  // Manually swaps the royalty fees
  function manualRoyaltyFeeSwapDAO() external onlyRole(DAO) {
    // Forbid swapping royalty fees
    swappingRoyalty = true;

    // Perform the swap
    _swapRoyaltyFeeBalance();

    // Allow swapping again
    swappingRoyalty = false;

    emit DAOManualRoyaltySwapped(msg.sender);
  }

  // Manually add liquidity
  function manualLiquifyDAO() external onlyRole(DAO) {
    // Forbid swapping liquidity fees
    swappingLiquidity = true;

    // Perform swap
    _liquify();

    // Allow swapping again
    swappingLiquidity = false;

    emit DAOManualLiquify(msg.sender);
  }

  function changeDAO(address _newDAO) external onlyRole(DAO) {
    require(_newDAO != address(0), 'New DAO address cannot be the zero address');
    revokeRole(DAO, tokenDAO);
    tokenDAO = _newDAO;
    grantRole(DAO, _newDAO);

    emit DAOChanged(_newDAO);
  }

  function revokeDAO(address _daoToRevoke) external onlyRole(DAO) {
    require(_daoToRevoke != address(0), 'Revoking DAO address cannot be the zero address');
    revokeRole(DAO, _daoToRevoke);
    emit DAORevoked(_daoToRevoke);
  }

  function blacklistDAO(address _user, bool _state) external onlyRole(DAO) {
    require(_user != address(0), 'User address cannot be the zero address');
    _blacklist[_user] = _state;
    emit BlacklistDAO(_user, _state);
  }

  function toggleSwappingDAO() external onlyRole(DAO) {
    swapEnabled = !swapEnabled;
    emit DAOSwapStatusToggled(swapEnabled);
  }

  function excludeFromFeesDAO(address _account, bool _state) external onlyRole(DAO) {
    require(_account != address(0), 'Account address can not be null address');
    _exemptFromFees[_account] = _state;
    emit DAOFeesExluded(_account, _state);
  }

  function setRoyaltyFeeRecipientDAO(address _royaltyFeeRecipient) external onlyRole(DAO) {
    require(_royaltyFeeRecipient != address(0), 'Royalty recipient address can not be null address');
    royaltyFeeRecipient = payable(_royaltyFeeRecipient);
    emit RoayltyRecipientAddressChanged(_royaltyFeeRecipient);
  }

  function setAutomatedMarketMakerPairDAO(address _pair, bool _value) external onlyRole(DAO) {
    require(_pair != tokenPairAddress, 'The WETH / TOKEN pair cannot be removed from _automatedMarketMakerPairs');
    _setAutomatedMarketMakerPair(_pair, _value);
    emit AutomatedMarketMakerPairDAO(_pair, _value);
  }

  function setMinimumRoyaltyFeeBalanceToSwapDAO(uint256 _minimumRoyaltyFeeBalanceToSwap) external onlyRole(DAO) {
    minimumRoyaltyFeeBalanceToSwap = _minimumRoyaltyFeeBalanceToSwap;
    emit MinimumRoyaltyBalanceToSwapDAOChanged(_minimumRoyaltyFeeBalanceToSwap);
  }

  function setMinimumLiquidityFeeBalanceToSwapDAO(uint256 _minimumLiquidityFeeBalanceToSwap) external onlyRole(DAO) {
    minimumLiquidityFeeBalanceToSwap = _minimumLiquidityFeeBalanceToSwap;
    emit MinimumLiquidityFeeBalanceToSwapDAOChanged(_minimumLiquidityFeeBalanceToSwap);
  }

  function setRoyaltySellingFeeDAO(uint256 _royaltySellingFee) external onlyRole(DAO) {
    royaltySellingFee = _royaltySellingFee;
    emit SetRoyaltySellingFeeDAO(_royaltySellingFee);
  }

  function setLiquidityBuyingFeeDAO(uint256 _liquidityBuyingFee) external onlyRole(DAO) {
    liquidityBuyingFee = _liquidityBuyingFee;
    emit SetLiquidityBuyingFeeDAO(_liquidityBuyingFee);
  }

  function setLiquiditySellingFeeDAO(uint256 _liquiditySellingFee) external onlyRole(DAO) {
    liquiditySellingFee = _liquiditySellingFee;
    emit SetLiquiditySellingFeeDAO(_liquiditySellingFee);
  }
}