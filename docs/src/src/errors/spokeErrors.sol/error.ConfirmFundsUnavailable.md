# ConfirmFundsUnavailable
[Git Source](https://github.com/aegonmyy/meridian/blob/93c662cb67fbace267d9454dbfc727c4ea6b0491/src/errors/spokeErrors.sol)

Thrown when a token-carrying retryConfirm's USDC is no longer held by the spoke

Can happen if deployIdle() redeployed the parked USDC before the retry landed —
see WI-2d race note in Spoke NatSpec.


```solidity
error ConfirmFundsUnavailable();
```

