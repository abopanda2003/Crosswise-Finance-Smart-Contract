pragma solidity ^0.8.0;


enum SessionType {
    None,
    Transfer,
    Swap,
    AddLiquidity,
    RemoveLiquidity,
    EmergencyWithdraw,
    Deposit,
    Withdraw,
    WithdrawVest,
    EnterStaking,
    LeaveStaking,
    Earn
}

uint256 constant NumberSessionTypes = 12;

struct SessionParams {
    SessionType sessionType;
    uint256 originSession;
    uint256 lastOriginSession;
    bool isOriginAction;
}

struct FeeRates {
    uint256 developer;
    uint256 buyback;
    uint256 liquidity;
}
struct FeeStores {
    address developer;
    address buyback;
    address liquidity;
}

uint256 constant FeeMagnifierPower = 5;
uint256 constant FeeMagnifier = 10 ** FeeMagnifierPower;