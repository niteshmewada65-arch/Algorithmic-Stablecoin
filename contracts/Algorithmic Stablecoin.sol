// SPDX-License-Identifier:
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
    mapping(address => bool) public hasVoted;
    mapping(address => bool) public rebaseManagers;

    mapping(address => uint256) public dailyMinted;
    mapping(address => uint256) public dailyBurned;
    mapping(address => uint256) public lastMintTimestamp;
    mapping(address => uint256) public lastBurnTimestamp;

    uint256 public voteCount;
    uint256 public newProposedRate;

    uint256 public newFeeProposal;
    uint256 public feeVoteCount;

    uint256[] public priceHistory;
    uint8 public constant MAX_HISTORY = 10;

    uint256 public dailyMintLimit = 1000 * 1e18;
    uint256 public dailyBurnLimit = 1000 * 1e18;

    address public treasury;
    uint256 public transactionFee = 2; // 2%
    bool public transfersFrozen = false;
    bool public rebasePaused = false;

    event Rebase(uint256 indexed epoch, uint256 totalSupply, uint256 newPrice);
    event PriceUpdate(uint256 newPrice, uint256 timestamp);
    event Mint(address indexed to, uint256 amount);
    event Burn(address indexed from, uint256 amount);
    event Blacklisted(address indexed user, bool status);
    event RebaseParamsUpdated(uint256 newRate, uint256 newTolerance);
    event ManualRebase(uint256 newSupply, uint256 newPrice);
    event TreasuryUpdated(address indexed newTreasury);
    event TokenRecovered(address indexed token, uint256 amount);
    event VoteCast(address indexed voter, uint256 proposedRate);
    event TransfersFrozen(bool status);
    event RebasePaused(bool status);

    modifier notBlacklisted(address user) {
        require(!blacklisted[user], "Blacklisted");
        _;
    }

    modifier notFrozen() {
        require(!transfersFrozen, "Transfers frozen");
        _;
    }

    modifier withinDailyLimit(uint256 amount, bool isMint) {
        if (isMint) {
            if (block.timestamp > lastMintTimestamp[msg.sender] + 1 days) {
                dailyMinted[msg.sender] = 0;
                lastMintTimestamp[msg.sender] = block.timestamp;
            }
            require(dailyMinted[msg.sender] + amount <= dailyMintLimit, "Mint limit");
            dailyMinted[msg.sender] += amount;
        } else {
            if (block.timestamp > lastBurnTimestamp[msg.sender] + 1 days) {
                dailyBurned[msg.sender] = 0;
                lastBurnTimestamp[msg.sender] = block.timestamp;
            }
            require(dailyBurned[msg.sender] + amount <= dailyBurnLimit, "Burn limit");
            dailyBurned[msg.sender] += amount;
        }
        _;
    }

    modifier onlyRebaseManager() {
        require(rebaseManagers[msg.sender] || msg.sender == owner(), "Not rebase manager");
        _;
    }

    constructor() ERC20("Algorithmic Stablecoin", "ASTC") Ownable(msg.sender) {
        currentPrice = TARGET_PRICE;
        lastRebaseTime = block.timestamp;
        _mint(msg.sender, 1_000_000 * 10**decimals());
        treasury = msg.sender;
    }

    function _transfer(address from, address to, uint256 amount) internal override notBlacklisted(from) notBlacklisted(to) notFrozen {
        if (treasury != address(0) && transactionFee > 0 && from != owner() && to != owner()) {
            uint256 fee = (amount * transactionFee) / 100;
            super._transfer(from, treasury, fee);
            amount -= fee;
        }
        super._transfer(from, to, amount);
    }

    function rebase() external whenNotPaused nonReentrant onlyRebaseManager returns (uint256) {
        require(!rebasePaused, "Rebase paused");
        require(block.timestamp >= lastRebaseTime + MIN_REBASE_INTERVAL, "Wait for interval");

        uint256 priceDelta = _calculatePriceDelta();
        if (priceDelta <= PRICE_TOLERANCE) return totalSupply();

        uint256 newSupply;
        if (currentPrice > TARGET_PRICE + PRICE_TOLERANCE) {
            uint256 inc = (totalSupply() * REBASE_RATE) / 1e18;
            newSupply = totalSupply() + inc;
            _mint(address(this), inc);
        } else {
            uint256 dec = (totalSupply() * REBASE_RATE) / 1e18;
            newSupply = totalSupply() - dec;
            _burn(address(this), dec);
        }

        lastRebaseTime = block.timestamp;
        totalRebases++;
        emit Rebase(totalRebases, newSupply, currentPrice);
        return newSupply;
    }

    function updatePrice(uint256 _newPrice) external onlyOwner {
        require(_newPrice > 0, "Invalid price");
        currentPrice = _newPrice;
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

    function mint(address _to, uint256 _amount) external onlyOwner notBlacklisted(_to) withinDailyLimit(_amount, true) {
        require(_to != address(0) && _amount > 0, "Invalid mint");
        _mint(_to, _amount);
        emit Mint(_to, _amount);
    }

    function burn(uint256 _amount) external notBlacklisted(msg.sender) withinDailyLimit(_amount, false) {
        require(_amount > 0 && balanceOf(msg.sender) >= _amount, "Invalid burn");
        _burn(msg.sender, _amount);
        emit Burn(msg.sender, _amount);
    }

    function _calculatePriceDelta() internal view returns (uint256) {
        return currentPrice > TARGET_PRICE ? currentPrice - TARGET_PRICE : TARGET_PRICE - currentPrice;
    }

    function isRebaseNeeded() external view returns (bool) {
        return block.timestamp >= lastRebaseTime + MIN_REBASE_INTERVAL && _calculatePriceDelta() > PRICE_TOLERANCE;
    }

    function getContractInfo() external view returns (uint256, uint256, uint256, uint256, uint256, bool) {
        return (currentPrice, TARGET_PRICE, totalSupply(), lastRebaseTime, totalRebases,
                block.timestamp >= lastRebaseTime + MIN_REBASE_INTERVAL && _calculatePriceDelta() > PRICE_TOLERANCE);
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

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function manualRebase(bool increase) external onlyOwner whenNotPaused {
        require(!rebasePaused, "Rebase paused");
        uint256 amount = (totalSupply() * REBASE_RATE) / 1e18;
        increase ? _mint(address(this), amount) : _burn(address(this), amount);
        totalRebases++;
        lastRebaseTime = block.timestamp;
        emit ManualRebase(totalSupply(), currentPrice);
    }

    function withdrawETH() external onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "No ETH");
        (bool success, ) = payable(owner()).call{value: balance}("");
        require(success, "ETH withdrawal failed");
    }

    function setTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "Invalid treasury");
        treasury = _treasury;
        emit TreasuryUpdated(_treasury);
    }

    function setTransactionFee(uint256 feePercent) external onlyOwner {
        require(feePercent <= 10, "Fee too high");
        transactionFee = feePercent;
    }

    function recoverTokens(address tokenAddress, uint256 amount) external onlyOwner {
        require(tokenAddress != address(this), "Can't recover ASTC");
        IERC20(tokenAddress).transfer(owner(), amount);
        emit TokenRecovered(tokenAddress, amount);
    }

    function emergencyTokenRecovery(address token, address to, uint256 amount) external onlyOwner {
        require(to != address(0) && token != address(this), "Invalid recovery");
        IERC20(token).transfer(to, amount);
        emit TokenRecovered(token, amount);
    }

    function voteNewRebaseRate(uint256 proposedRate) external {
        require(!hasVoted[msg.sender], "Already voted");
        require(proposedRate <= 1e18, "Too high");
        newProposedRate += proposedRate;
        voteCount++;
        hasVoted[msg.sender] = true;
        emit VoteCast(msg.sender, proposedRate);
    }

    function finalizeRebaseVote() external onlyOwner {
        require(voteCount > 0, "No votes");
        REBASE_RATE = newProposedRate / voteCount;
        newProposedRate = 0;
        voteCount = 0;
    }

    function voteTransactionFee(uint256 proposedFee) external {
        require(!hasVoted[msg.sender], "Already voted");
        require(proposedFee <= 10, "Too high");
        newFeeProposal += proposedFee;
        feeVoteCount++;
        hasVoted[msg.sender] = true;
    }

    function finalizeFeeVote() external onlyOwner {
        require(feeVoteCount > 0, "No votes");
        transactionFee = newFeeProposal / feeVoteCount;
        newFeeProposal = 0;
        feeVoteCount = 0;
    }

    function freezeTransfers(bool status) external onlyOwner {
        transfersFrozen = status;
        emit TransfersFrozen(status);
    }

    function toggleRebasePause(bool status) external onlyOwner {
        rebasePaused = status;
        emit RebasePaused(status);
    }

    function setRebaseManager(address manager, bool status) external onlyOwner {
        rebaseManagers[manager] = status;
    }

    receive() external payable {}
}
