# HUB
[Git Source](https://github.com/aegonmyy/meridian/blob/14eb4367d262c366b0c0301a0aed2d6e87141729/src/Hub.sol)

**Inherits:**
[HubAdminModule](/src/hub/HubAdminModule.sol/abstract.HubAdminModule.md), [HubMessagingModule](/src/hub/HubMessagingModule.sol/abstract.HubMessagingModule.md), [HubWithdrawalModule](/src/hub/HubWithdrawalModule.sol/abstract.HubWithdrawalModule.md)

**Title:**
HubVault

ERC4626 vault on Ethereum — entry point for all user deposits and withdrawals.
Users deposit USDC here and receive vault shares representing their proportional
ownership of all protocol-managed capital across all chains.

Inherits ERC4626, CCIPReceiver, and Ownable. Delegates capital deployment to
spoke vaults on L2s via Chainlink CCIP. Share price reflects total managed assets
across all spokes including yield accrued on deployed capital.
Only the Rebalancer contract can move capital between hub and spokes.
Withdrawals are asynchronous when capital is deployed — three paths exist:
Path 1 (sync): idle covers withdrawal and all spoke reports are fresh.
Path 2 (async): idle covers withdrawal but spoke reports are stale — refreshes first.
Path 3 (async): idle insufficient — recalls shortfall from best spoke via CCIP.

R-4 (final step) of the Hub modularization: all logic now lives in the three sibling
modules — HubAdminModule (spoke registry, misc admin, quarantine resolution),
HubMessagingModule (CCIP dispatch + inbound callbacks), HubWithdrawalModule
(ERC4626 deposit/withdraw overrides, the WI-4 three-path withdrawal engine, and
share-price accounting). All state, structs, events, and cross-module hook
declarations live in HubStorage (src/hub/HubStorage.sol), which every module
inherits directly (sibling inheritance — no module inherits another). This file is
now constructor-forwarding only, composing the three modules into the deployed
contract.


## Functions
### constructor

Deploys HubVault with core configuration — forwards to HubStorage


```solidity
constructor(
    string memory _name,
    string memory _symbol,
    address _router,
    address _owner,
    address _link,
    address _asset,
    address _rebalancer
) HubStorage(_name, _symbol, _router, _owner, _link, _asset, _rebalancer);
```

### _deposit


```solidity
function _deposit(address caller, address receiver, uint256 assets, uint256 shares)
    internal
    override(ERC4626, HubWithdrawalModule);
```

### _withdraw


```solidity
function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
    internal
    override(ERC4626, HubWithdrawalModule);
```

### totalAssets


```solidity
function totalAssets() public view override(ERC4626, HubWithdrawalModule) returns (uint256);
```

