# ConfirmFundsUnavailable
[Git Source](https://github.com/aegonmyy/meridian/blob/14eb4367d262c366b0c0301a0aed2d6e87141729/src/errors/spokeErrors.sol)

Thrown when a token-carrying retryConfirm's USDC is no longer held by the spoke

Can happen if deployIdle() redeployed the parked USDC before the retry landed —
see WI-2d race note in Spoke NatSpec.


```solidity
error ConfirmFundsUnavailable();
```

