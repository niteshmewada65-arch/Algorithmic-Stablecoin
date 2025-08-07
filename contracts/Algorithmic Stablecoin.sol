// SPDX-License-Identifier: 
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

interface IOracle {
    function getPrice() external view returns (uint256);
}

interface IFlashLoanReceiver {
    function executeOperation(uint256 amount, uint256 fee, bytes calldata data) external;
}

contract AlgorithmicStablecoin is ERC20, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Roles
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant KYC_PROVIDER_ROLE = keccak256("KYC_PROVIDER_ROLE");

  
    uint256 public lastRebase;
    uint256 public rebaseCooldown = 1 days;
    IOracle public oracle;
    uint256 public targetPrice = 1e18;
    uint256 public rebaseThreshold = 0.05e18;


    struct StakeInfo {
        uint256 amount;
        uint256 rewardDebt;
        uint256 lastClaimed;
    }
    mapping(address => StakeInfo) public stakes;
    uint256 public accRewardPerToken;
    uint256 public lastRewardTime;
    uint256 public rewardRate = 1e16;

    // Circuit Breaker
    bool public circuitBreaker;

    // Bridge
    mapping(address => bool) public bridgeApproved;

    // Fees
    uint256 public burnPercent = 1;
    uint256 public devPercent = 1;
    address public devFund;

    // KYC
    mapping(address => bool) public isKYCed;

    // Flash Loan
    uint256 public flashLoanFeeBps = 5;

    // Governance Proposal Voting
    struct Proposal {
        string description;
        uint256 voteCount;
        uint256 createdAt;
        bool executed;
    }
    uint256 public constant VOTE_DURATION = 3 days;
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    uint256 public proposalCount;

    // Events
    event Rebased(uint256 supplyDelta);
    event Staked(address indexed user, uint256 amount);
    event Claimed(address indexed user, uint256 reward);
    event Unstaked(address indexed user, uint256 amount);
    event BridgeTransfer(address indexed user, uint256 amount, string targetChain);
    event KYCApproved(address indexed user);
    event CircuitBreakerTriggered(bool status);
    event FeesUpdated(uint256 burnPercent, uint256 devPercent);
    event FlashLoan(address indexed receiver, uint256 amount, uint256 fee);
    event ProposalCreated(uint256 indexed id, string description);
    event Voted(uint256 indexed id, address voter);
    event ProposalExecuted(uint256 indexed id);

    modifier onlyKYCed() {
        require(isKYCed[msg.sender], "Not KYCed");
        _;
    }

    modifier notPaused() {
        require(!circuitBreaker, "Circuit breaker active");
        _;
    }

    constructor(address _oracle, address _devFund) ERC20("Algorithmic Stablecoin", "ASTC") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(GOVERNANCE_ROLE, msg.sender);
        oracle = IOracle(_oracle);
        devFund = _devFund;
        lastRewardTime = block.timestamp;
    }

    // --- KYC ---
    function approveKYC(address user) external onlyRole(KYC_PROVIDER_ROLE) {
        isKYCed[user] = true;
        emit KYCApproved(user);
    }

    // --- Rebase ---
    function rebase() external onlyRole(GOVERNANCE_ROLE) notPaused {
        require(block.timestamp >= lastRebase + rebaseCooldown, "Cooldown");
        uint256 price = oracle.getPrice();
        uint256 deviation = Math.abs(int256(price) - int256(targetPrice));
        require(deviation >= int256(rebaseThreshold), "No significant deviation");

        uint256 supplyDelta = (totalSupply() * deviation) / targetPrice;
        if (price > targetPrice) {
            _mint(address(this), supplyDelta);
        } else {
            _burn(address(this), Math.min(supplyDelta, balanceOf(address(this))));
        }

        lastRebase = block.timestamp;
        emit Rebased(supplyDelta);
    }

    // --- Staking ---
    function stake(uint256 amount) external onlyKYCed notPaused nonReentrant {
        require(amount > 0, "Invalid amount");
        _updateRewards(msg.sender);
        _transfer(msg.sender, address(this), amount);
        stakes[msg.sender].amount += amount;
        emit Staked(msg.sender, amount);
    }

    function unstake(uint256 amount) external onlyKYCed notPaused nonReentrant {
        require(amount > 0 && stakes[msg.sender].amount >= amount, "Insufficient stake");
        _updateRewards(msg.sender);
        stakes[msg.sender].amount -= amount;
        _transfer(address(this), msg.sender, amount);
        emit Unstaked(msg.sender, amount);
    }

    function claimRewards() external onlyKYCed notPaused nonReentrant {
        _updateRewards(msg.sender);
        uint256 reward = stakes[msg.sender].rewardDebt;
        require(reward > 0, "No rewards");
        stakes[msg.sender].rewardDebt = 0;
        _mint(msg.sender, reward);
        emit Claimed(msg.sender, reward);
    }

    function _updateRewards(address user) internal {
        if (block.timestamp > lastRewardTime && totalStaked() > 0) {
            uint256 duration = block.timestamp - lastRewardTime;
            uint256 reward = duration * rewardRate;
            accRewardPerToken += (reward * 1e18) / totalStaked();
            lastRewardTime = block.timestamp;
        }
        uint256 userReward = ((stakes[user].amount * accRewardPerToken) / 1e18) - stakes[user].rewardDebt;
        stakes[user].rewardDebt += userReward;
        stakes[user].lastClaimed = block.timestamp;
    }

    function totalStaked() public view returns (uint256) {
        return balanceOf(address(this));
    }

    // --- Bridge ---
    function bridgeTransfer(uint256 amount, string memory targetChain) external onlyKYCed notPaused nonReentrant {
        require(amount > 0 && balanceOf(msg.sender) >= amount, "Invalid amount");
        _burn(msg.sender, amount);
        emit BridgeTransfer(msg.sender, amount, targetChain);
    }

    function setBridge(address bridge, bool approved) external onlyRole(GOVERNANCE_ROLE) {
        bridgeApproved[bridge] = approved;
    }

    // --- Circuit Breaker ---
    function toggleCircuitBreaker(bool state) external onlyRole(GOVERNANCE_ROLE) {
        circuitBreaker = state;
        emit CircuitBreakerTriggered(state);
    }

    // --- Flash Loan ---
    function flashLoan(address receiver, uint256 amount, bytes calldata data) external nonReentrant notPaused {
        require(receiver != address(0), "Invalid receiver");
        require(amount > 0 && amount <= balanceOf(address(this)), "Invalid loan amount");
        uint256 fee = (amount * flashLoanFeeBps) / 10_000;
        uint256 repayment = amount + fee;
        _transfer(address(this), receiver, amount);
        IFlashLoanReceiver(receiver).executeOperation(amount, fee, data);
        require(balanceOf(address(this)) >= repayment, "Flash loan not repaid");
        _transfer(receiver, address(this), repayment);
        emit FlashLoan(receiver, amount, fee);
    }

    function setFlashLoanFee(uint256 bps) external onlyRole(GOVERNANCE_ROLE) {
        require(bps <= 100, "Fee too high");
        flashLoanFeeBps = bps;
    }

    // --- Admin Config ---
    function setOracle(address _oracle) external onlyRole(GOVERNANCE_ROLE) {
        oracle = IOracle(_oracle);
    }

    function setRewardRate(uint256 rate) external onlyRole(GOVERNANCE_ROLE) {
        rewardRate = rate;
    }

    function setFees(uint256 _burn, uint256 _dev) external onlyRole(GOVERNANCE_ROLE) {
        require(_burn <= 100 && _dev <= 100, "Too high");
        burnPercent = _burn;
        devPercent = _dev;
        emit FeesUpdated(_burn, _dev);
    }

    function setDevFund(address _devFund) external onlyRole(GOVERNANCE_ROLE) {
        devFund = _devFund;
    }

    // --- Governance Proposal Voting ---
    function createProposal(string memory description) external onlyRole(GOVERNANCE_ROLE) {
        proposals[proposalCount] = Proposal({
            description: description,
            voteCount: 0,
            createdAt: block.timestamp,
            executed: false
        });
        emit ProposalCreated(proposalCount, description);
        proposalCount++;
    }

    function voteProposal(uint256 id) external onlyRole(GOVERNANCE_ROLE) {
        require(id < proposalCount, "Invalid proposal");
        Proposal storage p = proposals[id];
        require(!hasVoted[id][msg.sender], "Already voted");
        require(!p.executed, "Already executed");
        p.voteCount++;
        hasVoted[id][msg.sender] = true;
        emit Voted(id, msg.sender);
    }

    function executeProposal(uint256 id) external onlyRole(GOVERNANCE_ROLE) {
        require(id < proposalCount, "Invalid proposal");
        Proposal storage p = proposals[id];
        require(!p.executed, "Already executed");
        require(block.timestamp <= p.createdAt + VOTE_DURATION, "Voting expired");
        require(p.voteCount >= 2, "Not enough votes");
        p.executed = true;
        emit ProposalExecuted(id);
    }

    // --- ERC20 Override ---
    function _transfer(address from, address to, uint256 amount) internal override {
        if (from == address(this) || to == address(this) || hasRole(GOVERNANCE_ROLE, from)) {
            super._transfer(from, to, amount);
        } else {
            uint256 burnAmount = (amount * burnPercent) / 100;
            uint256 devAmount = (amount * devPercent) / 100;
            uint256 finalAmount = amount - burnAmount - devAmount;
            super._transfer(from, address(0), burnAmount);
            super._transfer(from, devFund, devAmount);
            super._transfer(from, to, finalAmount);
        }
    }

    // --- Recover Tokens ---
    function recoverTokens(address token) external onlyRole(GOVERNANCE_ROLE) {
        require(token != address(this), "Can't recover ASTC");
        uint256 bal = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(msg.sender, bal);
    }
}



