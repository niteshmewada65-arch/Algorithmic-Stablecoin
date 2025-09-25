// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

contract RentalAgreement is ReentrancyGuard, Pausable {
    address public admin;
    uint256 public totalPlatformFees;

    constructor() {
        admin = msg.sender;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "Not admin");
        _;
    }

    struct Agreement {
        address tenant;
        address landlord;
        uint256 monthlyRent;
        uint256 agreementEnd;
        uint256 lastRentPayment;
        uint256 totalRentPaid;
        uint256 earlyTerminationFee;
        uint256 gracePeriodDays;
        bool isActive;
        bool autoRenewal;
        uint256 lateFeesOwed;
        uint256 securityDeposit;
    }

    struct MaintenanceRequest {
        uint256 agreementId;
        bool isApproved;
        address assignedContractor;
        uint256 estimatedCost;
        bool landlordFunded;
    }

    struct EmergencyMaintenance {
        uint256 agreementId;
        address raisedBy;
        string description;
        uint256 timestamp;
        bool resolved;
    }

    struct Dispute {
        uint256 agreementId;
        address raisedBy;
        string reason;
        bool resolved;
        string resolutionNote;
    }

    struct PaymentRecord {
        uint256 agreementId;
        uint256 amount;
        uint256 timestamp;
    }

    mapping(uint256 => Agreement) public agreements;
    mapping(address => uint256) public userEscrowBalance;
    mapping(address => string) public userKYCHash;
    mapping(address => uint8[]) public contractorRatings;
    mapping(address => string[]) public contractorSkills;
    mapping(address => bool) public verifiedContractors;
    mapping(uint256 => uint256) public pendingRentChanges;
    mapping(uint256 => bool) public agreementLocked;
    mapping(address => bool) public blacklistedUsers;
    mapping(address => PaymentRecord[]) public userPayments;

    EmergencyMaintenance[] public emergencyRequests;
    MaintenanceRequest[] public maintenanceRequests;
    Dispute[] public disputes;

    uint256 constant SECONDS_IN_MONTH = 30 days;
    uint256 constant LATE_FEE_PERCENTAGE = 5;
    uint256 constant MAX_LATE_FEE_MULTIPLIER = 10;
    uint256 constant PLATFORM_FEE_PERCENTAGE = 2;

    modifier agreementExists(uint256 _agreementId) {
        require(agreements[_agreementId].tenant != address(0), "Invalid agreement");
        _;
    }

    modifier onlyTenant(uint256 _agreementId) {
        require(msg.sender == agreements[_agreementId].tenant, "Not tenant");
        _;
    }

    modifier onlyAgreementParties(uint256 _agreementId) {
        Agreement memory a = agreements[_agreementId];
        require(msg.sender == a.tenant || msg.sender == a.landlord, "Not party");
        _;
    }

    modifier notBlacklisted() {
        require(!blacklistedUsers[msg.sender], "User blacklisted");
        _;
    }

    // ------------------- Events -------------------
    event AgreementTerminated(uint256 agreementId, address by, uint256 time);
    event AutoPaymentSetup(uint256 agreementId, address by, bool status);
    event UserVerified(address user, uint256 score);
    event ContractorVerified(address contractor, string[] skills);
    event RentPaid(uint256 agreementId, address tenant, uint256 rent, uint256 lateFee, uint256 time);
    event DocumentAccessRequested(uint256 indexed agreementId, address indexed requester, string documentType);
    event AgreementRenewed(uint256 indexed agreementId, address renewedBy, uint256 newEndDate);
    event AgreementRenewalRequested(uint256 agreementId, address requestedBy, uint256 requestedTill);
    event AgreementRenewalRejected(uint256 agreementId, address rejectedBy);
    event RentChangeProposed(uint256 indexed agreementId, address proposedBy, uint256 newRent);
    event RentChangeAccepted(uint256 indexed agreementId, uint256 newRent);
    event EmergencyMaintenanceRaised(uint256 requestId, uint256 agreementId, address tenant, string description);
    event EmergencyMaintenanceResolved(uint256 requestId);
    event ContractorRated(address contractor, uint8 rating);
    event AgreementLocked(uint256 indexed agreementId, bool isLocked);
    event EscrowWithdrawn(address user, uint256 amount);
    event EmergencyPaused();
    event EmergencyResumed();
    event SecurityDepositAdded(uint256 agreementId, address landlord, uint256 amount);
    event DisputeRaised(uint256 disputeId, uint256 agreementId, address by, string reason);
    event DisputeResolved(uint256 disputeId, string resolutionNote);
    event SecurityDepositRefunded(uint256 agreementId, address tenant, uint256 amount);
    event UserBlacklisted(address user, bool status);
    event PlatformFeesWithdrawn(address admin, uint256 amount);
    event PartialRentPaid(uint256 agreementId, address tenant, uint256 amount);

    // ------------------- Core Functions -------------------

    function acceptRentChange(uint256 _agreementId)
        external nonReentrant whenNotPaused agreementExists(_agreementId) onlyTenant(_agreementId)
    {
        uint256 newRent = pendingRentChanges[_agreementId];
        require(newRent > 0, "No proposed rent change");
        agreements[_agreementId].monthlyRent = newRent;
        delete pendingRentChanges[_agreementId];
        emit RentChangeAccepted(_agreementId, newRent);
    }

    function withdrawEscrow() external nonReentrant whenNotPaused {
        require(userEscrowBalance[msg.sender] > 0, "No balance to withdraw");
        require(!_hasActiveAgreement(msg.sender), "Active agreement exists");

        uint256 balance = userEscrowBalance[msg.sender];
        userEscrowBalance[msg.sender] = 0;
        payable(msg.sender).transfer(balance);
        emit EscrowWithdrawn(msg.sender, balance);
    }

    function depositSecurity(uint256 _agreementId) external payable whenNotPaused {
        Agreement storage a = agreements[_agreementId];
        require(msg.sender == a.landlord, "Only landlord");
        require(msg.value > 0, "No deposit amount");

        a.securityDeposit += msg.value;
        emit SecurityDepositAdded(_agreementId, msg.sender, msg.value);
    }

    function resolveEmergency(uint256 _requestId) external onlyAdmin {
        EmergencyMaintenance storage request = emergencyRequests[_requestId];
        require(!request.resolved, "Already resolved");
        request.resolved = true;
        emit EmergencyMaintenanceResolved(_requestId);
    }

    function emergencyPause() external onlyAdmin { _pause(); emit EmergencyPaused(); }
    function resume() external onlyAdmin { _unpause(); emit EmergencyResumed(); }

    // ------------------- New Functionalities -------------------

    // ✅ Early Termination
    function terminateAgreementEarly(uint256 _agreementId)
        external nonReentrant whenNotPaused onlyTenant(_agreementId)
    {
        Agreement storage a = agreements[_agreementId];
        require(a.isActive, "Agreement not active");

        uint256 fee = a.earlyTerminationFee;
        require(userEscrowBalance[msg.sender] >= fee, "Insufficient escrow");

        userEscrowBalance[msg.sender] -= fee;
        totalPlatformFees += fee;

        a.isActive = false;
        emit AgreementTerminated(_agreementId, msg.sender, block.timestamp);
    }

    // ✅ Partial Rent Payment
    function payPartialRent(uint256 _agreementId) external payable whenNotPaused onlyTenant(_agreementId) {
        require(msg.value > 0, "No payment");
        Agreement storage a = agreements[_agreementId];
        require(a.isActive, "Agreement not active");

        a.totalRentPaid += msg.value;
        userPayments[msg.sender].push(PaymentRecord(_agreementId, msg.value, block.timestamp));
        emit PartialRentPaid(_agreementId, msg.sender, msg.value);
    }

    // ✅ Maintenance Funding
    function fundMaintenance(uint256 _requestId) external payable {
        MaintenanceRequest storage req = maintenanceRequests[_requestId];
        require(msg.sender == agreements[req.agreementId].landlord, "Only landlord can fund");
        require(!req.landlordFunded, "Already funded");
        require(msg.value >= req.estimatedCost, "Insufficient funds");

        req.landlordFunded = true;
    }

    // ✅ Security Deposit Refund
    function refundSecurityDeposit(uint256 _agreementId) external onlyAdmin {
        Agreement storage a = agreements[_agreementId];
        require(!a.isActive, "Agreement still active");
        require(a.securityDeposit > 0, "No deposit");

        uint256 refund = a.securityDeposit;
        a.securityDeposit = 0;
        payable(a.tenant).transfer(refund);
        emit SecurityDepositRefunded(_agreementId, a.tenant, refund);
    }

    // ✅ Blacklist Management
    function blacklistUser(address _user, bool _status) external onlyAdmin {
        blacklistedUsers[_user] = _status;
        emit UserBlacklisted(_user, _status);
    }

    // ✅ Withdraw Platform Fees
    function withdrawPlatformFees() external onlyAdmin {
        uint256 amount = totalPlatformFees;
        totalPlatformFees = 0;
        payable(admin).transfer(amount);
        emit PlatformFeesWithdrawn(admin, amount);
    }

    // ✅ Payment History
    function getUserPaymentHistory(address _user) external view returns (PaymentRecord[] memory) {
        return userPayments[_user];
    }

    // ✅ Agreement Renewal Request & Approval
    function requestAgreementRenewal(uint256 _agreementId, uint256 _extendMonths)
        external whenNotPaused onlyTenant(_agreementId)
    {
        Agreement storage a = agreements[_agreementId];
        require(a.isActive, "Agreement not active");
        require(_extendMonths > 0, "Invalid extension");

        uint256 requestedTill = a.agreementEnd + (_extendMonths * SECONDS_IN_MONTH);
        emit AgreementRenewalRequested(_agreementId, msg.sender, requestedTill);
    }

    function approveAgreementRenewal(uint256 _agreementId, uint256 _extendMonths)
        external whenNotPaused onlyAgreementParties(_agreementId)
    {
        Agreement storage a = agreements[_agreementId];
        require(a.isActive, "Agreement not active");
        require(_extendMonths > 0, "Invalid extension");

        a.agreementEnd += _extendMonths * SECONDS_IN_MONTH;
        emit AgreementRenewed(_agreementId, msg.sender, a.agreementEnd);
    }

    function rejectAgreementRenewal(uint256 _agreementId)
        external whenNotPaused onlyAgreementParties(_agreementId)
    {
        Agreement memory a = agreements[_agreementId];
        require(a.isActive, "Agreement not active");
        emit AgreementRenewalRejected(_agreementId, msg.sender);
    }

    // ✅ NEW FUNCTIONALITY: Dispute Resolution System
    function raiseDispute(uint256 _agreementId, string calldata _reason)
        external whenNotPaused onlyAgreementParties(_agreementId)
    {
        disputes.push(Dispute({
            agreementId: _agreementId,
            raisedBy: msg.sender,
            reason: _reason,
            resolved: false,
            resolutionNote: ""
        }));
        emit DisputeRaised(disputes.length - 1, _agreementId, msg.sender, _reason);
    }

    function resolveDispute(uint256 _disputeId, string calldata _resolutionNote)
        external onlyAdmin
    {
        Dispute storage d = disputes[_disputeId];
        require(!d.resolved, "Dispute already resolved");

        d.resolved = true;
        d.resolutionNote = _resolutionNote;
        emit DisputeResolved(_disputeId, _resolutionNote);
    }

    // ------------------- Internal Helpers -------------------
    function _hasActiveAgreement(address _user) internal view returns (bool) {
        for (uint i = 0; i < 100; i++)
            if (agreements[i].tenant == _user && agreements[i].isActive) return true;
        return false;
    }

    function _hasTenantWorkedWithContractor(address _tenant, address _contractor) internal view returns (bool) {
        for (uint i = 0; i < maintenanceRequests.length; i++)
            if (maintenanceRequests[i].assignedContractor == _contractor &&
                agreements[maintenanceRequests[i].agreementId].tenant == _tenant) return true;
        return false;
    }
}

