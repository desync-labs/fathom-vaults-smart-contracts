# Fathom Vaults

This repository contains the Smart Contracts for Fathom Vault, Factory, Strategy, and Accountant implementations.

[Factory](contracts/factory) - The base Factory where all Vaults will be deployed and used to configure protocol fees.

[Vault](contracts/vault) - The ERC4626-compliant Vault that will handle all logic associated with deposits, withdrawals, strategy management, profit reporting, etc.

[Strategy](contracts/strategy) - The Strategy implementations. Used to gain income for Vaults.

[Accountant](contracts/accountant) - The Accountant implementations for Vaults. Responsible for management, performance, and other fee accounting.

## Requirements

- Linux or macOS (Windows: Not tested)
- node v16.4.0
- npm v7.18.1
- solc 0.8.19 or later
- [Hardhat](https://hardhat.org/) installed globally

## Setup

Install Requirements.

Fork the repository and clone onto your local device 

```
git clone https://github.com/user/fathom-vaults-smart-contracts
cd fathom-vaults-smart-contracts
```

```
npm install
```

```
npm run test
```

## Inspiration

Fathom Vaults is inspired by Yearn Vaults V3 (https://github.com/yearn/yearn-vaults-v3) and is the indirect fork.
We learned from Yearn and rewrote in Solidity with modifications Vault, wrote from scratch Factory, and Accountant and some Strategies.

## Appendix
LiquidationStrategy's doc 2024.03.22
https://docs.google.com/document/d/1HeMJ1BcjRx6IoSP5rU6YZVeJxkp4c8wx2yElheZxoSQ/edit?usp=sharing