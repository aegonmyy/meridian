# SpokeVault
[Git Source](https://github.com/aegonmyy/meridian/blob/14eb4367d262c366b0c0301a0aed2d6e87141729/src/Spoke.sol)

**Inherits:**
[SpokeAdminModule](/src/spoke/SpokeAdminModule.sol/abstract.SpokeAdminModule.md), [SpokeHandlersModule](/src/spoke/SpokeHandlersModule.sol/abstract.SpokeHandlersModule.md), [SpokeConfirmsModule](/src/spoke/SpokeConfirmsModule.sol/abstract.SpokeConfirmsModule.md)

**Title:**
SpokeVault

Receives CCIP instructions from the HubVault and manages capital deployment
into yield protocols (Aave, Compound, Morpho) on a single L2 chain.

Deployed once per supported L2 chain (Arbitrum, Base, Optimism).
Only the HubVault on Ethereum can send instructions to this contract via CCIP —
all other senders are rejected. Users never interact with this contract directly.
Capital flow: Hub sends DEPOSIT → spoke deploys into adapters → spoke reports balance back.
Four inbound message types: DEPOSIT, REBALANCE, REPORT_BALANCE, WITHDRAW_AMOUNT.
Four outbound message types: CONFIRM_RECEIPT, CONFIRM_REBALANCE, REPORT_BALANCE, CONFIRM_WITHDRAWAL.

R-7 (final step) of the Spoke modularization: all logic now lives in the three
sibling modules — SpokeAdminModule (adapter registry, Hub rotation, idle
redeployment), SpokeHandlersModule (CCIP inbound entry point + message handlers),
SpokeConfirmsModule (outbound confirm/report dispatch + retry queue). All state,
structs, events, and cross-module hook declarations live in SpokeStorage
(src/spoke/SpokeStorage.sol), which every module inherits directly (sibling
inheritance — no module inherits another). This file is now constructor-forwarding
only, composing the three modules into the deployed contract.


## Functions
### constructor

Deploys the SpokeVault with initial chain and protocol configuration — forwards to SpokeStorage


```solidity
constructor(address _hub, address _asset, address _router, address _owner, address _link, uint64 _hubSelector)
    SpokeStorage(_hub, _asset, _router, _owner, _link, _hubSelector);
```

### _ccipReceive


```solidity
function _ccipReceive(Client.Any2EVMMessage memory message) internal override(CCIPReceiver, SpokeHandlersModule);
```

