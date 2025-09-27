// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IOracle { function getPrice() external view returns (uint256); }

contract AlgorithmicStablecoin is ERC20, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Roles
    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    // Tokenomics
    uint256 public rewardRate; 
    uint256 public lastRewardTime;
    uint256 public accRewardPerToken;
    uint256 public rewardBoostMultiplier = 1e18;
    uint256 public rewardBoostEnd;
    uint256 public halvingInterval = 30 days;

    // Governance
    struct Proposal {
        uint256 id;
        address proposer;
        string description;
        uint256 voteCount;
        bool executed;
        uint256 createdAt;
        address execTarget;
        uint256 execValue;
        bytes execData;
    }
    mapping(uint256 => Proposal) public proposals;
    uint256 public proposalCount;
    uint256 public proposalQuorum = 1;
    uint256 public governanceDelay = 1 days;

    // Staking
    struct StakeInfo {
        uint256 amount;
        uint256 rewardDebt;
        uint256 lastClaimed;
    }
    mapping(address => StakeInfo) public stakes;

    // Security & Controls
    bool public circuitBreaker;
    mapping(address => bool) public blacklisted;

    // Transfer Limit
    uint256 public transferLimitBps;
    mapping(address => bool) public transferLimitExempt;

    // Oracle
    IOracle public priceOracle;

    // Events
    event ProposalCreated(uint256 indexed id, address indexed proposer, string description);
    event ProposalExecuted(uint256 indexed id);
    event GovernanceDelayUpdated(uint256 newDelay);
    event CircuitBreakerTriggered(bool active);
    event BlacklistUpdated(address account, bool status);
    event HalvingIntervalUpdated(uint256 newInterval);
    event RewardBoostEnded();

    constructor(address oracle) ERC20("Algorithmic Stablecoin", "ASTC") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(GOVERNANCE_ROLE, msg.sender);
        priceOracle = IOracle(oracle);
    }

    // ------------------------ GOVERNANCE ------------------------

    function createProposal(string memory desc, address target, uint256 value, bytes memory data) external onlyRole(GOVERNANCE_ROLE) {
        proposalCount++;
        proposals[proposalCount] = Proposal(proposalCount, msg.sender, desc, 0, false, block.timestamp, target, value, data);
        emit ProposalCreated(proposalCount, msg.sender, desc);
    }

    function voteProposal(uint256 id) external {
        Proposal storage p = proposals[id];
        require(!p.executed, "Executed");
        p.voteCount++;
    }

    function executeProposal(uint256 id) external onlyRole(GOVERNANCE_ROLE) {
        Proposal storage p = proposals[id];
        require(!p.executed, "Executed");
        require(block.timestamp >= p.createdAt + governanceDelay, "Timelock active");
        require(p.voteCount >= proposalQuorum, "Not enough votes");
        p.executed = true;
        emit ProposalExecuted(id);
        if (p.execTarget != address(0)) {
            (bool ok, ) = p.execTarget.call{value: p.execValue}(p.execData);
            require(ok, "Exec failed");
        }
    }

    function setGovernanceDelay(uint256 d) external onlyRole(GOVERNANCE_ROLE) {
        require(d <= 7 days, "Delay too long");
        governanceDelay = d;
        emit GovernanceDelayUpdated(d);
    }

    function setBlacklist(address account, bool status) external onlyRole(GOVERNANCE_ROLE) {
        blacklisted[account] = status;
        emit BlacklistUpdated(account, status);
    }

    // ------------------------ GUARDIAN ------------------------

    function emergencyPause() external onlyRole(GUARDIAN_ROLE) {
        circuitBreaker = true;
        emit CircuitBreakerTriggered(true);
    }

    function emergencyUnpause() external onlyRole(GOVERNANCE_ROLE) {
        circuitBreaker = false;
        emit CircuitBreakerTriggered(false);
    }

    // ------------------------ STAKING ------------------------

    function stake(uint256 amount) external nonReentrant {
        require(amount > 0, "Zero amount");
        _updateRewards(msg.sender);
        _transfer(msg.sender, address(this), amount);
        stakes[msg.sender].amount += amount;
    }

    function unstake(uint256 amount) external nonReentrant {
        require(stakes[msg.sender].amount >= amount, "Not enough staked");
        _updateRewards(msg.sender);
        stakes[msg.sender].amount -= amount;
        _transfer(address(this), msg.sender, amount);
    }

    function claimRewards() external nonReentrant {
        _updateRewards(msg.sender);
        uint256 reward = stakes[msg.sender].rewardDebt;
        require(reward > 0, "No rewards");
        stakes[msg.sender].rewardDebt = 0;
        _mint(msg.sender, reward);
    }

    function _updateRewards(address u) internal {
        if (block.timestamp > lastRewardTime && totalStaked() > 0) {
            uint256 elapsed = block.timestamp - lastRewardTime;
            uint256 halvingCount = elapsed / halvingInterval;
            if (halvingCount > 0) rewardRate = rewardRate >> halvingCount;
            uint256 r = elapsed * rewardRate;
            if (block.timestamp <= rewardBoostEnd) r = (r * rewardBoostMultiplier) / 1e18;
            else if (rewardBoostMultiplier > 1e18) { rewardBoostMultiplier = 1e18; emit RewardBoostEnded(); }
            accRewardPerToken += (r * 1e18) / totalStaked();
            lastRewardTime = block.timestamp;
        }
        uint256 earned = ((stakes[u].amount * accRewardPerToken) / 1e18) - stakes[u].rewardDebt;
        stakes[u].rewardDebt += earned; stakes[u].lastClaimed = block.timestamp;
    }

    function totalStaked() public view returns (uint256) {
        return balanceOf(address(this));
    }

    function setHalvingInterval(uint256 i) external onlyRole(GOVERNANCE_ROLE) {
        require(i >= 7 days, "Too short");
        halvingInterval = i;
        emit HalvingIntervalUpdated(i);
    }

    // ------------------------ TRANSFER HOOK ------------------------

    function _beforeTokenTransfer(address f, address t, uint256 a) internal override {
        require(!blacklisted[f] && !blacklisted[t], "Blacklisted");
        require(!circuitBreaker, "Paused");
        if (transferLimitBps > 0 && f != address(0) && t != address(0) && !transferLimitExempt[f] && !transferLimitExempt[t])
            require(a <= (totalSupply() * transferLimitBps) / 1e4, "Limit exceeded");
        super._beforeTokenTransfer(f, t, a);
    }
}
