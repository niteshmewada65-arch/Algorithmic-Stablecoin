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

    uint256 public targetPrice = 1e18;
    uint256 public rebaseThreshold = 0.05e18;
    uint256 public rebaseCooldown = 1 days;
    uint256 public burnPercent = 1;
    uint256 public devPercent = 1;
    uint256 public flashLoanFeeBps = 5;
    uint256 public rewardRate = 1e16;
    uint256 public proposalQuorum = 2;
    uint256 public maxSupply;
    uint256 public transferLimitBps = 1000;
    uint256 public manualPrice;
    uint256 public lastRebase;
    uint256 public accRewardPerToken;
    uint256 public lastRewardTime;
    uint256 public proposalCount;
    uint256 public rewardBoostMultiplier = 1e18;
    uint256 public rewardBoostEnd;

    bool public circuitBreaker;
    bool public useManualOracle;

    mapping(address => bool) public transferLimitExempt;
    mapping(address => bool) public isKYCed;
    mapping(address => bool) public bridgeApproved;

    struct StakeInfo { uint256 amount; uint256 rewardDebt; uint256 lastClaimed; }
    mapping(address => StakeInfo) public stakes;

    struct Proposal {
        string description; uint256 voteCount; uint256 createdAt;
        bool executed; address execTarget; uint256 execValue; bytes execData;
    }
    mapping(uint256 => Proposal) public proposals;
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    event Rebased(uint256 supplyDelta);
    event Staked(address indexed u, uint256 amt);
    event Claimed(address indexed u, uint256 r);
    event Unstaked(address indexed u, uint256 amt);
    event BridgeTransfer(address indexed u, uint256 amt, string chain);
    event KYCApproved(address indexed u);
    event KYCRevoked(address indexed u);
    event CircuitBreakerTriggered(bool s);
    event FeesUpdated(uint256 b, uint256 d);
    event FlashLoan(address indexed r, uint256 a, uint256 fee);
    event ProposalCreated(uint256 id, string desc);
    event Voted(uint256 id, address v);
    event ProposalExecuted(uint256 id);
    event TreasuryUpdated(address t);
    event Slashed(address indexed u, uint256 a);
    event ManualOracleSet(uint256 p, bool e);
    event TargetPriceUpdated(uint256 p);
    event RebaseThresholdUpdated(uint256 t);
    event MaxSupplyUpdated(uint256 m);
    event TransferLimitUpdated(uint256 bps);
    event TransferLimitExemptToggled(address a, bool e);
    event EmergencyWithdrawn(address to, uint256 a);
    event EmergencyERC20Withdrawn(address token, address to, uint256 a);
    event FlashLoanFeeUpdated(uint256 bps);
    event RewardBoostActivated(uint256 m, uint256 d);
    event RewardBoostEnded();

    modifier onlyKYCed() { require(isKYCed[msg.sender], "Not KYCed"); _; }
    modifier notPaused() { require(!circuitBreaker, "Paused"); _; }

    constructor(address _oracle, address _devFund) ERC20("Algorithmic Stablecoin", "ASTC") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(GOVERNANCE_ROLE, msg.sender);
        oracle = IOracle(_oracle);
        devFund = treasury = _devFund;
        lastRewardTime = block.timestamp;
        transferLimitExempt[msg.sender] = transferLimitExempt[address(this)] = transferLimitExempt[_devFund] = transferLimitExempt[treasury] = true;
    }

    // --- KYC ---
    function approveKYC(address u) external onlyRole(KYC_PROVIDER_ROLE) { isKYCed[u] = true; emit KYCApproved(u); }
    function revokeKYC(address u) external onlyRole(KYC_PROVIDER_ROLE) { isKYCed[u] = false; emit KYCRevoked(u); }

    // --- Rebase ---
    function _doRebase(uint256 price) internal {
        uint256 deviation = price > targetPrice ? price - targetPrice : targetPrice - price;
        require(deviation >= rebaseThreshold, "No significant deviation");
        uint256 delta = (totalSupply() * deviation) / targetPrice;
        if (price > targetPrice) {
            uint256 toMint = maxSupply > 0 ? Math.min(delta, maxSupply > totalSupply() ? maxSupply - totalSupply() : 0) : delta;
            if (toMint > 0) _mint(address(this), toMint);
        } else {
            uint256 burnAmt = Math.min(delta, balanceOf(address(this)));
            if (burnAmt > 0) _burn(address(this), burnAmt);
            uint256 rem = delta > burnAmt ? delta - burnAmt : 0;
            if (rem > 0) super._transfer(treasury, address(0), Math.min(rem, balanceOf(treasury)));
        }
        lastRebase = block.timestamp; emit Rebased(delta);
    }

    function rebase() external onlyRole(GOVERNANCE_ROLE) notPaused { require(block.timestamp >= lastRebase + rebaseCooldown, "Cooldown"); _doRebase(_getPrice()); }
    function manualRebase(uint256 p) external onlyRole(GOVERNANCE_ROLE) notPaused { require(block.timestamp >= lastRebase + rebaseCooldown, "Cooldown"); _doRebase(p); }

    // --- Staking ---
    function stake(uint256 a) external onlyKYCed notPaused nonReentrant {
        require(a > 0, "Invalid"); _updateRewards(msg.sender);
        _transfer(msg.sender, address(this), a); stakes[msg.sender].amount += a;
        emit Staked(msg.sender, a);
    }
    function unstake(uint256 a) external onlyKYCed notPaused nonReentrant {
        require(a > 0 && stakes[msg.sender].amount >= a, "Insufficient");
        _updateRewards(msg.sender); stakes[msg.sender].amount -= a;
        _transfer(address(this), msg.sender, a); emit Unstaked(msg.sender, a);
    }
    function claimRewards() external onlyKYCed notPaused nonReentrant {
        _updateRewards(msg.sender); uint256 r = stakes[msg.sender].rewardDebt;
        require(r > 0, "No rewards"); stakes[msg.sender].rewardDebt = 0;
        _mint(msg.sender, r); emit Claimed(msg.sender, r);
    }
    function _updateRewards(address u) internal {
        if (block.timestamp > lastRewardTime && totalStaked() > 0) {
            uint256 r = (block.timestamp - lastRewardTime) * rewardRate;
            if (block.timestamp <= rewardBoostEnd) r = (r * rewardBoostMultiplier) / 1e18;
            else if (rewardBoostMultiplier > 1e18) { rewardBoostMultiplier = 1e18; emit RewardBoostEnded(); }
            accRewardPerToken += (r * 1e18) / totalStaked(); lastRewardTime = block.timestamp;
        }
        uint256 earned = ((stakes[u].amount * accRewardPerToken) / 1e18) - stakes[u].rewardDebt;
        stakes[u].rewardDebt += earned; stakes[u].lastClaimed = block.timestamp;
    }
    function totalStaked() public view returns (uint256) { return balanceOf(address(this)); }
    function activateRewardBoost(uint256 m, uint256 d) external onlyRole(GOVERNANCE_ROLE) {
        require(m >= 1e18, "Invalid"); rewardBoostMultiplier = m; rewardBoostEnd = block.timestamp + d;
        emit RewardBoostActivated(m, d);
    }

    // --- Bridge ---
    function bridgeTransfer(uint256 a, string memory c) external onlyKYCed notPaused nonReentrant {
        require(a > 0 && balanceOf(msg.sender) >= a, "Invalid");
        _burn(msg.sender, a); emit BridgeTransfer(msg.sender, a, c);
    }
    function setBridge(address b, bool ok) external onlyRole(GOVERNANCE_ROLE) { bridgeApproved[b] = ok; }

    // --- Circuit Breaker ---
    function toggleCircuitBreaker(bool s) external onlyRole(GOVERNANCE_ROLE) { circuitBreaker = s; emit CircuitBreakerTriggered(s); }

    // --- Flash Loan ---
    function flashLoan(address r, uint256 a, bytes calldata data) external nonReentrant notPaused {
        require(r != address(0) && a > 0 && a <= balanceOf(address(this)), "Invalid loan");
        uint256 fee = (a * flashLoanFeeBps) / 1e4;
        _transfer(address(this), r, a); IFlashLoanReceiver(r).executeOperation(a, fee, data);
        require(balanceOf(address(this)) >= a + fee, "Not repaid");
        _transfer(r, address(this), a + fee); emit FlashLoan(r, a, fee);
    }
    function setFlashLoanFeeBps(uint256 bps) external onlyRole(GOVERNANCE_ROLE) { require(bps <= 1000, "Too high"); flashLoanFeeBps = bps; emit FlashLoanFeeUpdated(bps); }

    // --- Governance ---
    function createProposal(string memory d, address t, uint256 v, bytes memory data) external onlyRole(GOVERNANCE_ROLE) {
        proposals[proposalCount] = Proposal(d, 0, block.timestamp, false, t, v, data);
        emit ProposalCreated(proposalCount++, d);
    }
    function voteProposal(uint256 id) external onlyRole(GOVERNANCE_ROLE) {
        Proposal storage p = proposals[id]; require(!p.executed && !hasVoted[id][msg.sender], "Invalid");
        hasVoted[id][msg.sender] = true; p.voteCount++; emit Voted(id, msg.sender);
    }
    function executeProposal(uint256 id) external onlyRole(GOVERNANCE_ROLE) {
        Proposal storage p = proposals[id];
        require(!p.executed && block.timestamp >= p.createdAt + 3 days && p.voteCount >= proposalQuorum, "Cannot execute");
        p.executed = true; emit ProposalExecuted(id);
        if (p.execTarget != address(0)) { (bool ok, ) = p.execTarget.call{value: p.execValue}(p.execData); require(ok, "Exec failed"); }
    }

    // --- Admin ---
    function setOracle(address o) external onlyRole(GOVERNANCE_ROLE) { oracle = IOracle(o); }
    function setRewardRate(uint256 r) external onlyRole(GOVERNANCE_ROLE) { rewardRate = r; }
    function setFees(uint256 b, uint256 d) external onlyRole(GOVERNANCE_ROLE) { require(b <= 100 && d <= 100); burnPercent = b; devPercent = d; emit FeesUpdated(b, d); }
    function setDevFund(address d) external onlyRole(GOVERNANCE_ROLE) { devFund = d; }
    function setTreasury(address t) external onlyRole(GOVERNANCE_ROLE) { treasury = t; emit TreasuryUpdated(t); }
    function withdrawFromTreasury(address token, uint256 a) external onlyRole(GOVERNANCE_ROLE) { require(token != address(this)); IERC20(token).safeTransfer(msg.sender, a); }
    function slash(address u, uint256 a) external onlyRole(GOVERNANCE_ROLE) { uint256 bal = balanceOf(u); if (bal > 0) super._transfer(u, treasury, Math.min(bal, a)); emit Slashed(u, Math.min(bal, a)); }
    function setManualOracle(uint256 p, bool e) external onlyRole(GOVERNANCE_ROLE) { manualPrice = p; useManualOracle = e; emit ManualOracleSet(p, e); }
    function setTargetPrice(uint256 p) external onlyRole(GOVERNANCE_ROLE) { targetPrice = p; emit TargetPriceUpdated(p); }
    function setRebaseThreshold(uint256 t) external onlyRole(GOVERNANCE_ROLE) { rebaseThreshold = t; emit RebaseThresholdUpdated(t); }
    function setRebaseCooldown(uint256 c) external onlyRole(GOVERNANCE_ROLE) { rebaseCooldown = c; }
    function setProposalQuorum(uint256 q) external onlyRole(GOVERNANCE_ROLE) { proposalQuorum = q; }
    function setMaxSupply(uint256 m) external onlyRole(GOVERNANCE_ROLE) { maxSupply = m; emit MaxSupplyUpdated(m); }
    function setTransferLimitBps(uint256 bps) external onlyRole(GOVERNANCE_ROLE) { require(bps <= 1e4); transferLimitBps = bps; emit TransferLimitUpdated(bps); }
    function setTransferLimitExempt(address a, bool e) external onlyRole(GOVERNANCE_ROLE) { transferLimitExempt[a] = e; emit TransferLimitExemptToggled(a, e); }

    // --- ERC20 Override ---
    function _transfer(address f, address t, uint256 a) internal override {
        if (f == address(this) || t == address(this) || hasRole(GOVERNANCE_ROLE, f) || f == treasury) super._transfer(f, t, a);
        else {
            uint256 b = (a * burnPercent) / 100; uint256 d = (a * devPercent) / 100;
            if (b > 0) super._transfer(f, address(0), b);
            if (d > 0) super._transfer(f, devFund, d);
            super._transfer(f, t, a - b - d);
        }
    }
    function _beforeTokenTransfer(address f, address t, uint256 a) internal override {
        super._beforeTokenTransfer(f, t, a);
        if (transferLimitBps > 0 && f != address(0) && t != address(0) && !transferLimitExempt[f] && !transferLimitExempt[t])
            require(a <= (totalSupply() * transferLimitBps) / 1e4, "Limit exceeded");
        require(!circuitBreaker, "Paused");
    }

    function emergencyWithdrawETH(address payable to, uint256 a) external onlyRole(GOVERNANCE_ROLE) { require(a <= address(this).balance); to.transfer(a); emit EmergencyWithdrawn(to, a); }
    function emergencyWithdrawERC20(address token, address to, uint256 a) external onlyRole(GOVERNANCE_ROLE) { IERC20(token).safeTransfer(to, a); emit EmergencyERC20Withdrawn(token, to, a); }
    function recoverTokens(address token) external onlyRole(GOVERNANCE_ROLE) { require(token != address(this)); IERC20(token).safeTransfer(msg.sender, IERC20(token).balanceOf(address(this))); }

    function _getPrice() internal view returns (uint256) { return useManualOracle ? manualPrice : oracle.getPrice(); }

    receive() external payable {}
    fallback() external payable {}
}

