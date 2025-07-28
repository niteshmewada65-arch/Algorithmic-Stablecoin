// SPDX-License-Identifier:MIT

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

    // NEW FUNCTIONALITIES START HERE

    // 1. Staking Mechanism
    struct StakeInfo {
        uint256 amount;
        uint256 startTime;
        uint256 lastRewardTime;
        uint256 accumulatedRewards;
    }
    
    mapping(address => StakeInfo) public stakes;
    uint256 public stakingRewardRate = 5e16; // 5% annual
    uint256 public totalStaked;
    uint256 public stakingPool;
    uint256 public minStakingPeriod = 7 days;
    
    // 2. Price Oracle Integration
    struct PriceOracle {
        address oracle;
        uint256 weight;
        bool isActive;
    }
    
    mapping(address => PriceOracle) public priceOracles;
    address[] public oracleAddresses;
    uint256 public totalOracleWeight;
    bool public useOracles = false;
    
    // 3. Dynamic Fee Structure
    struct FeeConfig {
        uint256 baseFee;
        uint256 volumeFeeThreshold;
        uint256 discountRate;
        uint256 premiumRate;
    }
    
    FeeConfig public feeConfig = FeeConfig({
        baseFee: 2,
        volumeFeeThreshold: 10000 * 1e18,
        discountRate: 1,
        premiumRate: 3
    });
    
    mapping(address => uint256) public monthlyVolume;
    mapping(address => uint256) public lastVolumeReset;
    
    // 4. Governance Token Integration
    address public governanceToken;
    uint256 public proposalThreshold = 1000 * 1e18; // Min governance tokens to create proposal
    uint256 public votingPeriod = 3 days;
    
    struct Proposal {
        uint256 id;
        address proposer;
        string description;
        uint256 startTime;
        uint256 endTime;
        uint256 forVotes;
        uint256 againstVotes;
        bool executed;
        mapping(address => bool) hasVoted;
    }
    
    mapping(uint256 => Proposal) public proposals;
    uint256 public proposalCount;
    
    // 5. Liquidity Incentives
    mapping(address => bool) public liquidityProviders;
    mapping(address => uint256) public lpRewards;
    uint256 public lpRewardRate = 3e16; // 3% bonus
    
    // 6. Emergency Circuit Breaker
    uint256 public maxPriceDeviation = 2e17; // 20%
    bool public circuitBreakerActive = false;
    uint256 public circuitBreakerCooldown = 1 hours;
    uint256 public lastCircuitBreakerTime;
    
    // 7. Cross-chain Bridge Support
    mapping(uint256 => bool) public supportedChains;
    mapping(bytes32 => bool) public processedBridgeTransactions;
    address public bridgeOperator;
    
    // 8. Automated Market Maker Integration
    address public ammPair;
    uint256 public ammRebalanceThreshold = 1e17; // 10%
    bool public autoRebalanceEnabled = true;

    // NEW EVENTS
    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount, uint256 rewards);
    event StakingRewardsClaimed(address indexed user, uint256 amount);
    event OracleAdded(address indexed oracle, uint256 weight);
    event OracleRemoved(address indexed oracle);
    event PriceFromOracles(uint256 aggregatedPrice);
    event ProposalCreated(uint256 indexed proposalId, address indexed proposer);
    event ProposalExecuted(uint256 indexed proposalId);
    event VoteCasted(uint256 indexed proposalId, address indexed voter, bool support);
    event LiquidityProviderAdded(address indexed provider);
    event CircuitBreakerTriggered(uint256 priceDeviation);
    event BridgeTransfer(address indexed from, address indexed to, uint256 amount, uint256 targetChain);
    event AMMRebalance(uint256 oldPrice, uint256 newPrice);

    // Existing modifiers and events remain the same...
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

    modifier circuitBreakerCheck() {
        if (!circuitBreakerActive) {
            uint256 deviation = _calculatePriceDelta();
            if (deviation > maxPriceDeviation) {
                circuitBreakerActive = true;
                lastCircuitBreakerTime = block.timestamp;
                emit CircuitBreakerTriggered(deviation);
            }
        }
        require(!circuitBreakerActive || block.timestamp > lastCircuitBreakerTime + circuitBreakerCooldown, "Circuit breaker active");
        _;
    }

    constructor() ERC20("Algorithmic Stablecoin", "ASTC") Ownable(msg.sender) {
        currentPrice = TARGET_PRICE;
        lastRebaseTime = block.timestamp;
        _mint(msg.sender, 1_000_000 * 10**decimals());
        treasury = msg.sender;
        bridgeOperator = msg.sender;
    }

    // EXISTING FUNCTIONS (keeping all original functionality)
    
    function _transfer(address from, address to, uint256 amount) internal override notBlacklisted(from) notBlacklisted(to) notFrozen circuitBreakerCheck {
        // Update monthly volume for dynamic fees
        _updateMonthlyVolume(from, amount);
        
        uint256 dynamicFee = _calculateDynamicFee(from, amount);
        
        if (treasury != address(0) && dynamicFee > 0 && from != owner() && to != owner()) {
            uint256 fee = (amount * dynamicFee) / 100;
            super._transfer(from, treasury, fee);
            amount -= fee;
            
            // LP rewards
            if (liquidityProviders[from] || liquidityProviders[to]) {
                uint256 lpBonus = (fee * lpRewardRate) / 1e18;
                lpRewards[liquidityProviders[from] ? from : to] += lpBonus;
            }
        }
        super._transfer(from, to, amount);
    }

    function rebase() external whenNotPaused nonReentrant onlyRebaseManager circuitBreakerCheck returns (uint256) {
        require(!rebasePaused, "Rebase paused");
        require(block.timestamp >= lastRebaseTime + MIN_REBASE_INTERVAL, "Wait for interval");

        // Use oracle price if available
        if (useOracles && oracleAddresses.length > 0) {
            _updatePriceFromOracles();
        }

        uint256 priceDelta = _calculatePriceDelta();
        if (priceDelta <= PRICE_TOLERANCE) return totalSupply();

        uint256 newSupply;
        if (currentPrice > TARGET_PRICE + PRICE_TOLERANCE) {
            uint256 inc = (totalSupply() * REBASE_RATE) / 1e18;
            newSupply = totalSupply() + inc;
            _mint(address(this), inc);
            
            // Add to staking pool
            stakingPool += inc / 10; // 10% goes to staking rewards
        } else {
            uint256 dec = (totalSupply() * REBASE_RATE) / 1e18;
            newSupply = totalSupply() - dec;
            _burn(address(this), dec);
        }

        lastRebaseTime = block.timestamp;
        totalRebases++;
        
        // Trigger AMM rebalance if needed
        if (autoRebalanceEnabled && ammPair != address(0)) {
            _triggerAMMRebalance();
        }
        
        emit Rebase(totalRebases, newSupply, currentPrice);
        return newSupply;
    }

    // NEW FUNCTIONS START HERE

    // 1. STAKING FUNCTIONS
    function stake(uint256 amount) external notBlacklisted(msg.sender) {
        require(amount > 0, "Invalid amount");
        require(balanceOf(msg.sender) >= amount, "Insufficient balance");
        
        _claimStakingRewards(msg.sender);
        
        _transfer(msg.sender, address(this), amount);
        
        stakes[msg.sender].amount += amount;
        stakes[msg.sender].startTime = block.timestamp;
        stakes[msg.sender].lastRewardTime = block.timestamp;
        totalStaked += amount;
        
        emit Staked(msg.sender, amount);
    }
    
    function unstake(uint256 amount) external nonReentrant {
        require(stakes[msg.sender].amount >= amount, "Insufficient stake");
        require(block.timestamp >= stakes[msg.sender].startTime + minStakingPeriod, "Staking period not met");
        
        uint256 rewards = _claimStakingRewards(msg.sender);
        
        stakes[msg.sender].amount -= amount;
        totalStaked -= amount;
        
        _transfer(address(this), msg.sender, amount);
        
        emit Unstaked(msg.sender, amount, rewards);
    }
    
    function claimStakingRewards() external {
        _claimStakingRewards(msg.sender);
    }
    
    function _claimStakingRewards(address user) internal returns (uint256) {
        StakeInfo storage userStake = stakes[user];
        if (userStake.amount == 0) return 0;
        
        uint256 timeStaked = block.timestamp - userStake.lastRewardTime;
        uint256 rewards = (userStake.amount * stakingRewardRate * timeStaked) / (365 days * 1e18);
        
        if (rewards > 0 && stakingPool >= rewards) {
            stakingPool -= rewards;
            userStake.accumulatedRewards += rewards;
            userStake.lastRewardTime = block.timestamp;
            _mint(user, rewards);
            emit StakingRewardsClaimed(user, rewards);
        }
        
        return rewards;
    }
    
    // 2. ORACLE FUNCTIONS
    function addOracle(address oracle, uint256 weight) external onlyOwner {
        require(oracle != address(0), "Invalid oracle");
        require(!priceOracles[oracle].isActive, "Oracle already exists");
        
        priceOracles[oracle] = PriceOracle(oracle, weight, true);
        oracleAddresses.push(oracle);
        totalOracleWeight += weight;
        
        emit OracleAdded(oracle, weight);
    }
    
    function removeOracle(address oracle) external onlyOwner {
        require(priceOracles[oracle].isActive, "Oracle not active");
        
        totalOracleWeight -= priceOracles[oracle].weight;
        priceOracles[oracle].isActive = false;
        
        // Remove from array
        for (uint i = 0; i < oracleAddresses.length; i++) {
            if (oracleAddresses[i] == oracle) {
                oracleAddresses[i] = oracleAddresses[oracleAddresses.length - 1];
                oracleAddresses.pop();
                break;
            }
        }
        
        emit OracleRemoved(oracle);
    }
    
    function _updatePriceFromOracles() internal {
        uint256 weightedPrice = 0;
        uint256 totalWeight = 0;
        
        for (uint i = 0; i < oracleAddresses.length; i++) {
            address oracle = oracleAddresses[i];
            if (priceOracles[oracle].isActive) {
                // Assuming oracle has a getPrice() function
                (bool success, bytes memory data) = oracle.staticcall(abi.encodeWithSignature("getPrice()"));
                if (success && data.length >= 32) {
                    uint256 price = abi.decode(data, (uint256));
                    weightedPrice += price * priceOracles[oracle].weight;
                    totalWeight += priceOracles[oracle].weight;
                }
            }
        }
        
        if (totalWeight > 0) {
            currentPrice = weightedPrice / totalWeight;
            emit PriceFromOracles(currentPrice);
        }
    }
    
    // 3. DYNAMIC FEE FUNCTIONS
    function _updateMonthlyVolume(address user, uint256 amount) internal {
        if (block.timestamp > lastVolumeReset[user] + 30 days) {
            monthlyVolume[user] = 0;
            lastVolumeReset[user] = block.timestamp;
        }
        monthlyVolume[user] += amount;
    }
    
    function _calculateDynamicFee(address user, uint256 amount) internal view returns (uint256) {
        if (monthlyVolume[user] >= feeConfig.volumeFeeThreshold) {
            return feeConfig.discountRate; // Discount for high-volume users
        } else if (amount >= dailyMintLimit / 2) {
            return feeConfig.premiumRate; // Premium for large transactions
        }
        return feeConfig.baseFee;
    }
    
    // 4. GOVERNANCE FUNCTIONS
    function createProposal(string memory description) external returns (uint256) {
        require(governanceToken != address(0), "No governance token set");
        require(IERC20(governanceToken).balanceOf(msg.sender) >= proposalThreshold, "Insufficient governance tokens");
        
        proposalCount++;
        Proposal storage newProposal = proposals[proposalCount];
        newProposal.id = proposalCount;
        newProposal.proposer = msg.sender;
        newProposal.description = description;
        newProposal.startTime = block.timestamp;
        newProposal.endTime = block.timestamp + votingPeriod;
        
        emit ProposalCreated(proposalCount, msg.sender);
        return proposalCount;
    }
    
    function vote(uint256 proposalId, bool support) external {
        require(proposalId <= proposalCount && proposalId > 0, "Invalid proposal");
        Proposal storage proposal = proposals[proposalId];
        require(block.timestamp <= proposal.endTime, "Voting ended");
        require(!proposal.hasVoted[msg.sender], "Already voted");
        require(governanceToken != address(0), "No governance token");
        
        uint256 votingPower = IERC20(governanceToken).balanceOf(msg.sender);
        require(votingPower > 0, "No voting power");
        
        proposal.hasVoted[msg.sender] = true;
        
        if (support) {
            proposal.forVotes += votingPower;
        } else {
            proposal.againstVotes += votingPower;
        }
        
        emit VoteCasted(proposalId, msg.sender, support);
    }
    
    // 5. LIQUIDITY PROVIDER FUNCTIONS
    function addLiquidityProvider(address provider) external onlyOwner {
        liquidityProviders[provider] = true;
        emit LiquidityProviderAdded(provider);
    }
    
    function claimLPRewards() external {
        uint256 rewards = lpRewards[msg.sender];
        require(rewards > 0, "No rewards");
        
        lpRewards[msg.sender] = 0;
        _mint(msg.sender, rewards);
    }
    
    // 6. BRIDGE FUNCTIONS
    function bridgeTransfer(address to, uint256 amount, uint256 targetChain) external {
        require(supportedChains[targetChain], "Unsupported chain");
        require(balanceOf(msg.sender) >= amount, "Insufficient balance");
        
        _burn(msg.sender, amount);
        emit BridgeTransfer(msg.sender, to, amount, targetChain);
    }
    
    function completeBridgeTransfer(address to, uint256 amount, bytes32 txHash) external {
        require(msg.sender == bridgeOperator, "Not bridge operator");
        require(!processedBridgeTransactions[txHash], "Already processed");
        
        processedBridgeTransactions[txHash] = true;
        _mint(to, amount);
    }
    
    // 7. AMM INTEGRATION
    function _triggerAMMRebalance() internal {
        if (ammPair == address(0)) return;
        
        uint256 deviation = _calculatePriceDelta();
        if (deviation > ammRebalanceThreshold) {
            // Trigger rebalance logic here
            emit AMMRebalance(currentPrice - deviation, currentPrice);
        }
    }
    
    // ADMIN FUNCTIONS FOR NEW FEATURES
    function setStakingRewardRate(uint256 newRate) external onlyOwner {
        require(newRate <= 2e17, "Rate too high"); // Max 20%
        stakingRewardRate = newRate;
    }
    
    function setGovernanceToken(address token) external onlyOwner {
        governanceToken = token;
    }
    
    function setSupportedChain(uint256 chainId, bool supported) external onlyOwner {
        supportedChains[chainId] = supported;
    }
    
    function setBridgeOperator(address operator) external onlyOwner {
        bridgeOperator = operator;
    }
    
    function setAMMPair(address pair) external onlyOwner {
        ammPair = pair;
    }
    
    function toggleUseOracles(bool enabled) external onlyOwner {
        useOracles = enabled;
    }
    
    function resetCircuitBreaker() external onlyOwner {
        circuitBreakerActive = false;
    }

    // Keep all existing functions...
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
