// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/access/AccessControlEnumerable.sol";

contract SimpleToken is
    ERC20,
    Pausable,
    ERC20Burnable,
    AccessControlEnumerable
{
    bytes32 internal constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 internal constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /// @dev Returns the URI for contract metadata.
    string public contractURI;

    constructor(
        string memory _name,
        string memory _symbol,
        uint256 _initialSupply,
        address _defaultAdmin
    ) ERC20(_name, _symbol) payable {
        require(_defaultAdmin != address(0), 'Default Admin address can not be null address');

        _setupRole(DEFAULT_ADMIN_ROLE, _defaultAdmin);
        _setupRole(MINTER_ROLE, _defaultAdmin);
        _setupRole(PAUSER_ROLE, _defaultAdmin);
        if (_initialSupply > 0) _mint(_defaultAdmin, _initialSupply);
    }


    /**  EVENTS START */
    event ContractPaused(
        bool isPaused,
        address pauserAddress
    );
    event TokenMinted(
      address minter,
      uint256 amount  
    );

    event ContractURIChanged (
        string newURI
    );
    /**  EVENTS END */

    function pause() public onlyRole(PAUSER_ROLE) {
        _pause();
        emit ContractPaused(true, msg.sender);
    }

    function unpause() public onlyRole(PAUSER_ROLE) {
        _unpause();
         emit ContractPaused(false, msg.sender);
    }

    function _mintTo(address _to, uint256 _amount)
        public
        onlyRole(MINTER_ROLE)
    {
        require(_to != address(0), 'Minter address can not be null address');
        require(_amount > 0, 'Amount of mintable tokens can not be equal to 0');
        _mint(_to, _amount);
        emit TokenMinted(_to, _amount);
    }

    function _beforeTokenTransfer(
        address _from,
        address _to,
        uint256 _amount
    ) internal override whenNotPaused {
        super._beforeTokenTransfer(_from, _to, _amount);
    }

    // Set contract URI contract metadata.
    function setContractURI(string calldata _uri)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        contractURI = _uri;
        emit ContractURIChanged(_uri);
    }
}
