# Algorithmic Stablecoin

## Project Description

The Algorithmic Stablecoin (ASTC) is a decentralized digital currency designed to maintain price stability around $1.00 USD through automated supply adjustments rather than collateral backing. This smart contract implements an algorithmic monetary policy that expands or contracts the token supply based on market price deviations from the target price.

Unlike traditional stablecoins that rely on reserves or collateral, this algorithmic approach uses economic incentives and supply mechanics to achieve price stability. When the price rises above the target, new tokens are minted to increase supply and reduce price pressure. When the price falls below the target, tokens are burned to decrease supply and create upward price pressure.

## Project Vision

Our vision is to create a truly decentralized, algorithmic stablecoin that operates without the need for centralized reserves, custodians, or collateral. By leveraging market forces and automated monetary policy, we aim to provide:

- **True Decentralization**: No central authority controls the money supply
- **Capital Efficiency**: No collateral requirements or reserves needed
- **Algorithmic Stability**: Automated price stabilization through supply adjustments
- **Transparency**: All monetary policy decisions are executed on-chain
- **Accessibility**: Equal access to stable value storage for all users

This project serves as a foundation for exploring advanced monetary policy mechanisms in the DeFi ecosystem and contributes to the evolution of decentralized financial infrastructure.

## Key Features

### 🎯 **Algorithmic Price Stabilization**
- Target price: $1.00 USD with 5% tolerance band
- Automated rebase mechanism triggers supply adjustments
- 1% supply change per rebase to maintain gradual adjustments

### ⚡ **Automated Rebasing**
- Smart contract automatically expands or contracts supply based on price
- Minimum 1-hour interval between rebases to prevent manipulation
- Price-driven monetary policy execution without human intervention

### 🛡️ **Security Features**
- Built on OpenZeppelin's audited contracts
- Reentrancy protection on critical functions
- Owner-controlled minting with proper access controls
- Emergency withdrawal mechanisms for contract safety

### 📊 **Real-time Monitoring**
- Current price tracking and historical rebase data
- Contract state information accessible via getter functions
- Event emission for all major contract interactions

### 🔧 **Core Functions**
1. **`rebase()`** - Adjusts token supply based on current market price
2. **`updatePrice(uint256 _newPrice)`** - Updates market price (oracle function)
3. **`mint(address _to, uint256 _amount)`** - Controlled token minting for liquidity

### 💰 **Token Economics**
- ERC-20 compliant with standard transfer functionality
- Initial supply: 1,000,000 ASTC tokens
- Supply adjusts dynamically based on price stability requirements
- Deflationary and inflationary mechanisms built-in

## Future Scope

### 🔮 **Phase 1: Oracle Integration**
- Integrate Chainlink Price Feeds for real-time price data
- Implement multiple price sources for enhanced accuracy
- Add price manipulation protection mechanisms

### 🌐 **Phase 2: Advanced Monetary Policy**
- Implement dynamic rebase rates based on volatility
- Add liquidity incentive mechanisms
- Develop multi-asset collateral support options

### 🏛️ **Phase 3: Governance & DAO**
- Transition to community governance model
- Implement proposal and voting mechanisms for parameter changes
- Add treasury management for protocol development

### 🔗 **Phase 4: Cross-Chain Expansion**
- Deploy on multiple blockchain networks
- Implement cross-chain bridge functionality
- Create unified liquidity pools across chains

### 📈 **Phase 5: DeFi Ecosystem Integration**
- Partner with major DeFi protocols for adoption
- Implement yield farming and staking mechanisms
- Add lending and borrowing protocol integration

### 🎯 **Phase 6: Stability Enhancements**
- Implement machine learning-based price prediction
- Add derivative products for additional stability
- Create insurance mechanisms for extreme market conditions

## Getting Started

### Prerequisites

```bash
node >= 16.0.0
npm >= 8.0.0
```

### Installation

```bash
# Clone the repository
git clone <repository-url>
cd algorithmic-stablecoin

# Install dependencies
npm install

# Create environment file
cp .env.example .env
# Edit .env with your private key and API keys
```

### Configuration

Edit `.env` file:
```bash
PRIVATE_KEY=your_private_key_without_0x_prefix
CORE_API_KEY=your_core_blockchain_api_key
REPORT_GAS=true
```

### Compilation

```bash
npm run compile
```

### Testing

```bash
npm run test
```

### Deployment

Deploy to Core Testnet 2:
```bash
npm run deploy
```

Deploy to local network:
```bash
npm run deploy:local
```

## Contract Information

- **Contract Name**: AlgorithmicStablecoin
- **Symbol**: ASTC
- **Decimals**: 18
- **Network**: Core Testnet 2
- **RPC URL**: https://rpc.test2.btcs.network
- **Chain ID**: 1115

## Core Functions Usage

### Rebase Supply
```javascript
await stablecoin.rebase();
```

### Update Price (Owner Only)
```javascript
await stablecoin.updatePrice(ethers.utils.parseEther("1.05")); // $1.05
```

### Check Contract State
```javascript
const info = await stablecoin.getContractInfo();
console.log("Current Price:", ethers.utils.formatEther(info._currentPrice));
```

## Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add some amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Disclaimer

This project is for educational and research purposes. Algorithmic stablecoins involve complex economic mechanisms and significant risks. Always conduct thorough testing and audits before using in production environments. The stability mechanisms may not perform as expected under all market conditions.

## Support

For support and questions:
- Create an issue in the GitHub repository
- Join our community discussions
- Check the documentation for detailed guides

---
0x79f90deb6b016bb817698aec09f11dd5d02910e47cb255b42769b7a0a4740964
![T_56](https://github.com/user-attachments/assets/6601058c-080a-482e-89dd-b56bf7a1b8d9)

**Built with ❤️!for the DeFi community**
