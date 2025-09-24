// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IOracle { function getPrice() external view returns (uint256); }
interface IFlashLoanReceiver { function executeOperation(uint256 amount, uint256 fee, bytes calldata data) external; }

contract AlgorithmicStablecoin is ERC20, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant GOVERNANCE_ROLE = keccak256("GOVERNANCE_ROLE");
    bytes32 public constant KYC_PROVIDER_ROLE = keccak256("KYC_PROVIDER_ROLE");

    IOracle public oracle;
    address public devFund;
    address public treasury;

    // Configurable params
    uint256 public targetPrice = 1e18;
    uint256 public rebaseThreshold = 0.05e18;
    uint256 public rebaseCooldown = 1 days;
    uint256 public burnPercent = 1;
    uint256 public devPercent = 1;
    uint256 public flashLoanFeeBps = 5;
    uint256 public rewardRate = 1e16;
    uint256 public proposalQuorum = 2;

    // New: max supply cap (0 means no cap)
    uint256 public maxSupply;

    // Transfer limit (anti-whale): percentage (bps style: e.g., 100 = 1%)
    // For simplicity store in basis points of total supply (10000 = 100%)
    uint256 public transferLimitBps = 1000; // default 10% of total supply per tx (adjustable)
    mapping(address => bool) public transferLimitExempt;

    // State vars
    bool public circuitBreaker;
    bool public useManualOracle;
    uint256 public manualPrice;
    uint256 public lastRebase;
    uint256 public accRewardPerToken;
    uint256 public lastRewardTime;
    uint256 public proposalCount;

    mapping(address => bool) public isKYCed;
    mapping(address => bool) public bridgeApproved;

    struct StakeInfo { uint256 amount; uint256 rewardDebt; uint256 lastClaimed; }
    mapping(address => StakeInfo) public stakes;

    struct Proposal {
        string description;
        uint256 voteCount;
        uint256 createdAt;
        bool executed;
        address execTarget;
        uint256 execValue;
        bytes execData;
    }
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    // Events (added some new events)
    event Rebased(uint256 supplyDelta);
    event Staked(address indexed user, uint256 amount);
    event Claimed(address indexed user, uint256 reward);
    event Unstaked(address indexed user, uint256 amount);
    event BridgeTransfer(address indexed user, uint256 amount, string targetChain);
    event KYCApproved(address indexed user);
    event KYCRevoked(address indexed user);
    event CircuitBreakerTriggered(bool status);
    event FeesUpdated(uint256 burnPercent, uint256 devPercent);
    event FlashLoan(address indexed receiver, uint256 amount, uint256 fee);
    event ProposalCreated(uint256 indexed id, string description);
    event Voted(uint256 indexed id, address voter);
    event ProposalExecuted(uint256 indexed id);
    event TreasuryUpdated(address indexed treasury);
    event Slashed(address indexed user, uint256 amount);
    event ManualOracleSet(uint256 price, bool enabled);
    event TargetPriceUpdated(uint256 price);
    event RebaseThresholdUpdated(uint256 threshold);

    // New events
    event MaxSupplyUpdated(uint256 newMaxSupply);
    event TransferLimitUpdated(uint256 newLimitBps);
    event TransferLimitExemptToggled(address account, bool exempt);
    event EmergencyWithdrawn(address indexed to, uint256 amount);
    event EmergencyERC20Withdrawn(address indexed token, address indexed to, uint256 amount);
    event FlashLoanFeeUpdated(uint256 newBps);

    modifier onlyKYCed() { require(isKYCed[msg.sender], "Not KYCed"); _; }
    modifier notPaused() { require(!circuitBreaker, "Circuit breaker active"); _; }

    constructor(address _oracle, address _devFund) ERC20("Algorithmic Stablecoin", "ASTC") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(GOVERNANCE_ROLE, msg.sender);
        oracle = IOracle(_oracle);
        devFund = treasury = _devFund;
        lastRewardTime = block.timestamp;

        // Exempt important addresses from transfer limits by default
        transferLimitExempt[msg.sender] = true;
        transferLimitExempt[address(this)] = true;
        transferLimitExempt[devFund] = true;
        transferLimitExempt[treasury] = true;
    }

    // --- KYC ---
    function approveKYC(address u) external onlyRole(KYC_PROVIDER_ROLE) { isKYCed[u] = true; emit KYCApproved(u); }
    function revokeKYC(address u) external onlyRole(KYC_PROVIDER_ROLE) { isKYCed[u] = false; emit KYCRevoked(u); }

    // --- Rebase ---
    function _doRebase(uint256 price) internal {
        // safer deviation calculation
        uint256 deviation = price > targetPrice ? price - targetPrice : targetPrice - price;
        require(deviation >= rebaseThreshold, "No significant deviation");

        // supplyDelta = totalSupply * (deviation / targetPrice)
        uint256 supplyDelta = (totalSupply() * deviation) / targetPrice;

        if (price > targetPrice) {
            // mint to contract (or to treasury) but respect maxSupply if set
            if (maxSupply > 0) {
                uint256 available = maxSupply > totalSupply() ? maxSupply - totalSupply() : 0;
                uint256 toMint = supplyDelta <= available ? supplyDelta : available;
                if (toMint > 0) _mint(address(this), toMint);
            } else {
                _mint(address(this), supplyDelta);
            }
        } else {
            // deflation path: burn from contract then from treasury if needed
            uint256 toBurn = Math.min(supplyDelta, balanceOf(address(this)));
            if (toBurn > 0) _burn(address(this), toBurn);
            uint256 remaining = supplyDelta > toBurn ? supplyDelta - toBurn : 0;
            if (remaining > 0) {
                uint256 treasuryBal = balanceOf(treasury);
                uint256 burnFromTreasury = Math.min(remaining, treasuryBal);
                if (burnFromTreasury > 0) super._transfer(treasury, address(0), burnFromTreasury);
            }
        }

        lastRebase = block.timestamp;
        emit Rebased(supplyDelta);
    }

    function rebase() external onlyRole(GOVERNANCE_ROLE) notPaused {
        require(block.timestamp >= lastRebase + rebaseCooldown, "Cooldown");
        _doRebase(_getPrice());
    }
    function manualRebase(uint256 priceOverride) external onlyRole(GOVERNANCE_ROLE) notPaused {
        require(block.timestamp >= lastRebase + rebaseCooldown, "Cooldown");
        _doRebase(priceOverride);
    }

    // --- Staking ---
    function stake(uint256 a) external onlyKYCed notPaused nonReentrant {
        require(a > 0, "Invalid amount");
        _updateRewards(msg.sender);
        _transfer(msg.sender, address(this), a);
        stakes[msg.sender].amount += a;
        emit Staked(msg.sender, a);
    }
    function unstake(uint256 a) external onlyKYCed notPaused nonReentrant {
        require(a > 0 && stakes[msg.sender].amount >= a, "Insufficient stake");
        _updateRewards(msg.sender);
        stakes[msg.sender].amount -= a;
        _transfer(address(this), msg.sender, a);
        emit Unstaked(msg.sender, a);
    }
    function claimRewards() external onlyKYCed notPaused nonReentrant {
        _updateRewards(msg.sender);
        uint256 r = stakes[msg.sender].rewardDebt;
        require(r > 0, "No rewards");
        stakes[msg.sender].rewardDebt = 0;
        _mint(msg.sender, r);
        emit Claimed(msg.sender, r);
    }
    function _updateRewards(address u) internal {
        if (block.timestamp > lastRewardTime && totalStaked() > 0) {
            uint256 reward = (block.timestamp - lastRewardTime) * rewardRate;
            accRewardPerToken += (reward * 1e18) / totalStaked();
            lastRewardTime = block.timestamp;
        }
        uint256 earned = ((stakes[u].amount * accRewardPerToken) / 1e18) - stakes[u].rewardDebt;
        stakes[u].rewardDebt += earned;
        stakes[u].lastClaimed = block.timestamp;
    }
    function totalStaked() public view returns (uint256) { return balanceOf(address(this)); }

    // --- Bridge ---
    function bridgeTransfer(uint256 a, string memory chain) external onlyKYCed notPaused nonReentrant {
        require(a > 0 && balanceOf(msg.sender) >= a, "Invalid amount");
        _burn(msg.sender, a);
        emit BridgeTransfer(msg.sender, a, chain);
    }
    function setBridge(address b, bool ok) external onlyRole(GOVERNANCE_ROLE) { bridgeApproved[b] = ok; }

    // --- Circuit Breaker ---
    function toggleCircuitBreaker(bool s) external onlyRole(GOVERNANCE_ROLE) { circuitBreaker = s; emit CircuitBreakerTriggered(s); }

    // --- Flash Loan ---
    function flashLoan(address r, uint256 a, bytes calldata data) external nonReentrant notPaused {
        require(r != address(0) && a > 0 && a <= balanceOf(address(this)), "Invalid loan");
        uint256 fee = (a * flashLoanFeeBps) / 10_000;
        uint256 repayment = a + fee;
        _transfer(address(this), r, a);
        IFlashLoanReceiver(r).executeOperation(a, fee, data);
        require(balanceOf(address(this)) >= repayment, "Not repaid");
        _transfer(r, address(this), repayment);
        emit FlashLoan(r, a, fee);
    }

    function setFlashLoanFeeBps(uint256 bps) external onlyRole(GOVERNANCE_ROLE) {
        require(bps <= 1000, "Too high"); // max 10%
        flashLoanFeeBps = bps;
        emit FlashLoanFeeUpdated(bps);
    }

    // --- Governance ---
    function createProposal(string memory d, address t, uint256 v, bytes memory data) external onlyRole(GOVERNANCE_ROLE) {
        proposals[proposalCount] = Proposal(d, 0, block.timestamp, false, t, v, data);
        emit ProposalCreated(proposalCount++, d);
    }
    function voteProposal(uint256 id) external onlyRole(GOVERNANCE_ROLE) {
        Proposal storage p = proposals[id];
        require(!p.executed && !hasVoted[id][msg.sender], "Invalid vote");
        hasVoted[id][msg.sender] = true;
        p.voteCount++;
        emit Voted(id, msg.sender);
    }
    function executeProposal(uint256 id) external onlyRole(GOVERNANCE_ROLE) {
        Proposal storage p = proposals[id];
        require(!p.executed && block.timestamp >= p.createdAt + 3 days && p.voteCount >= proposalQuorum, "Cannot execute");
        p.executed = true;
        emit ProposalExecuted(id);
        if (p.execTarget != address(0)) {
            (bool ok, ) = p.execTarget.call{value: p.execValue}(p.execData);
            require(ok, "Exec failed");
        }
    }

    // --- Admin Config ---
    function setOracle(address o) external onlyRole(GOVERNANCE_ROLE) { oracle = IOracle(o); }
    function setRewardRate(uint256 r) external onlyRole(GOVERNANCE_ROLE) { rewardRate = r; }
    function setFees(uint256 b, uint256 d) external onlyRole(GOVERNANCE_ROLE) { require(b <= 100 && d <= 100, "Too high"); burnPercent=b; devPercent=d; emit FeesUpdated(b,d); }
    function setDevFund(address d) external onlyRole(GOVERNANCE_ROLE) { devFund = d; }
    function setTreasury(address t) external onlyRole(GOVERNANCE_ROLE) { treasury = t; emit TreasuryUpdated(t); }
    function withdrawFromTreasury(address token, uint256 a) external onlyRole(GOVERNANCE_ROLE) { require(token != address(this)); IERC20(token).safeTransfer(msg.sender, a); }
    function slash(address u, uint256 a) external onlyRole(GOVERNANCE_ROLE) {
        uint256 bal = balanceOf(u);
        if (bal > 0) super._transfer(u, treasury, Math.min(bal, a));
        emit Slashed(u, Math.min(bal, a));
    }
    function setManualOracle(uint256 p, bool e) external onlyRole(GOVERNANCE_ROLE) { manualPrice=p; useManualOracle=e; emit ManualOracleSet(p,e); }
    function setTargetPrice(uint256 p) external onlyRole(GOVERNANCE_ROLE) { targetPrice=p; emit TargetPriceUpdated(p); }
    function setRebaseThreshold(uint256 t) external onlyRole(GOVERNANCE_ROLE) { rebaseThreshold=t; emit RebaseThresholdUpdated(t); }
    function setRebaseCooldown(uint256 c) external onlyRole(GOVERNANCE_ROLE) { rebaseCooldown=c; }
    function setProposalQuorum(uint256 q) external onlyRole(GOVERNANCE_ROLE) { proposalQuorum=q; }

    // --- New: Max Supply ---
    function setMaxSupply(uint256 _max) external onlyRole(GOVERNANCE_ROLE) {
        maxSupply = _max;
        emit MaxSupplyUpdated(_max);
    }

    // --- New: Transfer limit (anti-whale) ---
    // transferLimitBps is basis points of totalSupply allowed per txn (10000 == 100%)
    function setTransferLimitBps(uint256 bps) external onlyRole(GOVERNANCE_ROLE) {
        require(bps <= 10000, "bps>10000");
        transferLimitBps = bps;
        emit TransferLimitUpdated(bps);
    }
    function setTransferLimitExempt(address account, bool exempt) external onlyRole(GOVERNANCE_ROLE) {
        transferLimitExempt[account] = exempt;
        emit TransferLimitExemptToggled(account, exempt);
    }

    // --- ERC20 Override (transfer tax + anti-whale via _beforeTokenTransfer) ---
    function _transfer(address f, address t, uint256 a) internal override {
        if (f == address(this) || t == address(this) || hasRole(GOVERNANCE_ROLE, f) || f == treasury) 
            super._transfer(f, t, a);
        else {
            uint256 b = (a * burnPercent) / 100;
            uint256 d = (a * devPercent) / 100;
            if (b > 0) super._transfer(f, address(0), b);
            if (d > 0) super._transfer(f, devFund, d);
            super._transfer(f, t, a - b - d);
        }
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override {
        super._beforeTokenTransfer(from, to, amount);

        // if transferLimitBps == 0 -> disabled
        if (transferLimitBps > 0 && from != address(0) && to != address(0)) {
            if (!transferLimitExempt[from] && !transferLimitExempt[to]) {
                uint256 maxAllowed = (totalSupply() * transferLimitBps) / 10000;
                require(amount <= maxAllowed, "Transfer exceeds per-tx limit");
            }
        }

        // circuit breaker
        require(!circuitBreaker, "Transfers paused by circuit breaker");
    }

    // --- Recovery / Emergency functions ---
    function emergencyWithdrawETH(address payable to, uint256 amount) external onlyRole(GOVERNANCE_ROLE) {
        require(amount <= address(this).balance, "Insufficient ETH");
        to.transfer(amount);
        emit EmergencyWithdrawn(to, amount);
    }
    function emergencyWithdrawERC20(address token, address to, uint256 amount) external onlyRole(GOVERNANCE_ROLE) {
        IERC20(token).safeTransfer(to, amount);
        emit EmergencyERC20Withdrawn(token, to, amount);
    }

    function recoverTokens(address token) external onlyRole(GOVERNANCE_ROLE) {
        require(token != address(this));
        IERC20(token).safeTransfer(msg.sender, IERC20(token).balanceOf(address(this)));
    }

    function _getPrice() internal view returns (uint256) { return useManualOracle ? manualPrice : oracle.getPrice(); }

    receive() external payable {}
    fallback() external payable {}
}

