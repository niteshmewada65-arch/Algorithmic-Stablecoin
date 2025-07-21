// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * @title AlgorithmicStablecoin
 * @dev An algorithmic stablecoin that maintains price stability through supply adjustments
 * Target price: $1.00 USD
 */
contract AlgorithmicStablecoin is ERC20, Ownable, ReentrancyGuard {
    
    // Price target in wei (1 USD = 1e18)
    uint256 public constant TARGET_PRICE = 1e18;
    
    // Price tolerance (5% = 5e16)
    uint256 public constant PRICE_TOLERANCE = 5e16;
    
    // Rebase rate (1% = 1e16)
    uint256 public constant REBASE_RATE = 1e16;
    
    // Minimum time between rebases (1 hour)
    uint256 public constant MIN_REBASE_INTERVAL = 3600;
    
    // Current market price (simulated oracle)
    uint256 public currentPrice;
    
    // Last rebase timestamp
    uint256 public lastRebaseTime;
    
    // Total rebases performed
    uint256 public totalRebases;
    
    // Events
    event Rebase(uint256 indexed epoch, uint256 totalSupply, uint256 newPrice);
    event PriceUpdate(uint256 newPrice, uint256 timestamp);
    event Mint(address indexed to, uint256 amount);
    event Burn(address indexed from, uint256 amount);
    
    constructor() ERC20("Algorithmic Stablecoin", "ASTC") Ownable(msg.sender) {
        currentPrice = TARGET_PRICE; // Start at $1.00
        lastRebaseTime = block.timestamp;
        _mint(msg.sender, 1000000 * 10**decimals()); // Initial supply: 1M tokens
    }
    
    /**
     * @dev Core Function 1: Rebase the token supply based on current price
     * Adjusts total supply to maintain price stability
     */
    function rebase() external nonReentrant returns (uint256) {
        require(
            block.timestamp >= lastRebaseTime + MIN_REBASE_INTERVAL,
            "Rebase: Too soon since last rebase"
        );
        
        uint256 priceDelta = _calculatePriceDelta();
        
        // Only rebase if price is outside tolerance
        if (priceDelta <= PRICE_TOLERANCE) {
            return totalSupply();
        }
        
        uint256 newSupply;
        
        if (currentPrice > TARGET_PRICE + PRICE_TOLERANCE) {
            // Price too high, increase supply (inflationary rebase)
            uint256 supplyIncrease = (totalSupply() * REBASE_RATE) / 1e18;
            newSupply = totalSupply() + supplyIncrease;
            _mint(address(this), supplyIncrease);
        } else if (currentPrice < TARGET_PRICE - PRICE_TOLERANCE) {
            // Price too low, decrease supply (deflationary rebase)
            uint256 supplyDecrease = (totalSupply() * REBASE_RATE) / 1e18;
            newSupply = totalSupply() - supplyDecrease;
            _burn(address(this), supplyDecrease);
        } else {
            return totalSupply();
        }
        
        lastRebaseTime = block.timestamp;
        totalRebases++;
        
        emit Rebase(totalRebases, newSupply, currentPrice);
        
        return newSupply;
    }
    
    /**
     * @dev Core Function 2: Update the current market price
     * In production, this would be called by a price oracle
     */
    function updatePrice(uint256 _newPrice) external onlyOwner {
        require(_newPrice > 0, "Price must be greater than 0");
        
        currentPrice = _newPrice;
        
        emit PriceUpdate(_newPrice, block.timestamp);
    }
    
    /**
     * @dev Core Function 3: Mint new tokens (controlled minting for liquidity)
     * Only owner can mint to prevent inflation attacks
     */
    function mint(address _to, uint256 _amount) external onlyOwner {
        require(_to != address(0), "Cannot mint to zero address");
        require(_amount > 0, "Amount must be greater than 0");
        
        _mint(_to, _amount);
        
        emit Mint(_to, _amount);
    }
    
    /**
     * @dev Burn tokens from caller's balance
     */
    function burn(uint256 _amount) external {
        require(_amount > 0, "Amount must be greater than 0");
        require(balanceOf(msg.sender) >= _amount, "Insufficient balance");
        
        _burn(msg.sender, _amount);
        
        emit Burn(msg.sender, _amount);
    }
    
    /**
     * @dev Calculate the absolute difference between current and target price
     */
    function _calculatePriceDelta() internal view returns (uint256) {
        if (currentPrice >= TARGET_PRICE) {
            return currentPrice - TARGET_PRICE;
        } else {
            return TARGET_PRICE - currentPrice;
        }
    }
    
    /**
     * @dev Check if rebase is needed
     */
    function isRebaseNeeded() external view returns (bool) {
        if (block.timestamp < lastRebaseTime + MIN_REBASE_INTERVAL) {
            return false;
        }
        
        uint256 priceDelta = _calculatePriceDelta();
        return priceDelta > PRICE_TOLERANCE;
    }
    
    /**
     * @dev Get contract information
     */
    function getContractInfo() external view returns (
        uint256 _currentPrice,
        uint256 _targetPrice,
        uint256 _totalSupply,
        uint256 _lastRebaseTime,
        uint256 _totalRebases,
        bool _rebaseNeeded
    ) {
        uint256 priceDelta = _calculatePriceDelta();
        bool rebaseNeeded = (block.timestamp >= lastRebaseTime + MIN_REBASE_INTERVAL) && 
                           (priceDelta > PRICE_TOLERANCE);
        
        return (
            currentPrice,
            TARGET_PRICE,
            totalSupply(),
            lastRebaseTime,
            totalRebases,
            rebaseNeeded
        );
    }
    
    /**
     * @dev Emergency function to withdraw any ETH sent to contract
     */
    function withdrawETH() external onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "No ETH to withdraw");
        
        (bool success, ) = payable(owner()).call{value: balance}("");
        require(success, "ETH withdrawal failed");
    }
    
    /**
     * @dev Allow contract to receive ETH
     */
    receive() external payable {}
}
