// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

contract AlgorithmicStablecoin is ERC20, Ownable, ReentrancyGuard, Pausable {
    
    uint256 public constant TARGET_PRICE = 1e18;
    uint256 public PRICE_TOLERANCE = 5e16;
    uint256 public REBASE_RATE = 1e16;
    uint256 public MIN_REBASE_INTERVAL = 3600;

    uint256 public currentPrice;
    uint256 public lastRebaseTime;
    uint256 public totalRebases;

    mapping(address => bool) public blacklisted;

    uint256[] public priceHistory;
    uint8 public constant MAX_HISTORY = 10;

    event Rebase(uint256 indexed epoch, uint256 totalSupply, uint256 newPrice);
    event PriceUpdate(uint256 newPrice, uint256 timestamp);
    event Mint(address indexed to, uint256 amount);
    event Burn(address indexed from, uint256 amount);
    event Blacklisted(address indexed user, bool status);
    event RebaseParamsUpdated(uint256 newRate, uint256 newTolerance);
    event ManualRebase(uint256 newSupply, uint256 newPrice);

    modifier notBlacklisted(address user) {
        require(!blacklisted[user], "Address is blacklisted");
        _;
    }

    constructor() ERC20("Algorithmic Stablecoin", "ASTC") Ownable(msg.sender) {
        currentPrice = TARGET_PRICE;
        lastRebaseTime = block.timestamp;
        _mint(msg.sender, 1_000_000 * 10**decimals());
    }

    function rebase() external whenNotPaused nonReentrant returns (uint256) {
        require(block.timestamp >= lastRebaseTime + MIN_REBASE_INTERVAL, "Too soon since last rebase");

        uint256 priceDelta = _calculatePriceDelta();

        if (priceDelta <= PRICE_TOLERANCE) {
            return totalSupply();
        }

        uint256 newSupply;
        if (currentPrice > TARGET_PRICE + PRICE_TOLERANCE) {
            uint256 supplyIncrease = (totalSupply() * REBASE_RATE) / 1e18;
            newSupply = totalSupply() + supplyIncrease;
            _mint(address(this), supplyIncrease);
        } else {
            uint256 supplyDecrease = (totalSupply() * REBASE_RATE) / 1e18;
            newSupply = totalSupply() - supplyDecrease;
            _burn(address(this), supplyDecrease);
        }

        lastRebaseTime = block.timestamp;
        totalRebases++;
        emit Rebase(totalRebases, newSupply, currentPrice);
        return newSupply;
    }

    function updatePrice(uint256 _newPrice) external onlyOwner {
        require(_newPrice > 0, "Invalid price");
        currentPrice = _newPrice;

        // Store in history
        if (priceHistory.length >= MAX_HISTORY) {
            for (uint i = 0; i < MAX_HISTORY - 1; i++) {
                priceHistory[i] = priceHistory[i + 1];
            }
            priceHistory[MAX_HISTORY - 1] = _newPrice;
        } else {
            priceHistory.push(_newPrice);
        }

        emit PriceUpdate(_newPrice, block.timestamp);
    }

    function mint(address _to, uint256 _amount) external onlyOwner notBlacklisted(_to) {
        require(_to != address(0) && _amount > 0, "Invalid mint");
        _mint(_to, _amount);
        emit Mint(_to, _amount);
    }

    function burn(uint256 _amount) external notBlacklisted(msg.sender) {
        require(_amount > 0 && balanceOf(msg.sender) >= _amount, "Invalid burn");
        _burn(msg.sender, _amount);
        emit Burn(msg.sender, _amount);
    }

    function _calculatePriceDelta() internal view returns (uint256) {
        return currentPrice > TARGET_PRICE 
            ? currentPrice - TARGET_PRICE 
            : TARGET_PRICE - currentPrice;
    }

    function isRebaseNeeded() external view returns (bool) {
        if (block.timestamp < lastRebaseTime + MIN_REBASE_INTERVAL) return false;
        return _calculatePriceDelta() > PRICE_TOLERANCE;
    }

    function getContractInfo() external view returns (
        uint256 _currentPrice,
        uint256 _targetPrice,
        uint256 _totalSupply,
        uint256 _lastRebaseTime,
        uint256 _totalRebases,
        bool _rebaseNeeded
    ) {
        return (
            currentPrice,
            TARGET_PRICE,
            totalSupply(),
            lastRebaseTime,
            totalRebases,
            (block.timestamp >= lastRebaseTime + MIN_REBASE_INTERVAL) && 
            (_calculatePriceDelta() > PRICE_TOLERANCE)
        );
    }

    function getPriceHistory() external view returns (uint256[] memory) {
        return priceHistory;
    }

    function updateRebaseParams(uint256 _newRate, uint256 _newTolerance) external onlyOwner {
        require(_newRate <= 1e18 && _newTolerance <= 1e18, "Invalid parameters");
        REBASE_RATE = _newRate;
        PRICE_TOLERANCE = _newTolerance;
        emit RebaseParamsUpdated(_newRate, _newTolerance);
    }

    function setBlacklist(address user, bool value) external onlyOwner {
        blacklisted[user] = value;
        emit Blacklisted(user, value);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function manualRebase(bool increase) external onlyOwner whenNotPaused {
        uint256 amount = (totalSupply() * REBASE_RATE) / 1e18;
        if (increase) {
            _mint(address(this), amount);
        } else {
            _burn(address(this), amount);
        }
        totalRebases++;
        lastRebaseTime = block.timestamp;
        emit ManualRebase(totalSupply(), currentPrice);
    }

    function withdrawETH() external onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "No ETH to withdraw");
        (bool success, ) = payable(owner()).call{value: balance}("");
        require(success, "ETH withdrawal failed");
    }

    receive() external payable {}
}
