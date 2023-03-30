//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.7;

import "hardhat/console.sol";

// ----------------------INTERFACE------------------------------

// Aave
// https://docs.aave.com/developers/the-core-protocol/lendingpool/ilendingpool

interface ILendingPool {
    /**
     * Function to liquidate a non-healthy position collateral-wise, with Health Factor below 1
     * - The caller (liquidator) covers `debtToCover` amount of debt of the user getting liquidated, and receives
     *   a proportionally amount of the `collateralAsset` plus a bonus to cover market risk
     * @param collateralAsset The address of the underlying asset used as collateral, to receive as result of theliquidation
     * @param debtAsset The address of the underlying borrowed asset to be repaid with the liquidation
     * @param user The address of the borrower getting liquidated
     * @param debtToCover The debt amount of borrowed `asset` the liquidator wants to cover
     * @param receiveAToken `true` if the liquidators wants to receive the collateral aTokens, `false` if he wants
     * to receive the underlying collateral asset directly
     **/
    function liquidationCall(
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover,
        bool receiveAToken
    ) external;

    /**
     * Returns the user account data across all the reserves
     * @param user The address of the user
     * @return totalCollateralETH the total collateral in ETH of the user
     * @return totalDebtETH the total debt in ETH of the user
     * @return availableBorrowsETH the borrowing power left of the user
     * @return currentLiquidationThreshold the liquidation threshold of the user
     * @return ltv the loan to value of the user
     * @return healthFactor the current health factor of the user
     **/
    function getUserAccountData(
        address user
    )
        external
        view
        returns (
            uint256 totalCollateralETH,
            uint256 totalDebtETH,
            uint256 availableBorrowsETH,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );
}

// UniswapV2

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IERC20.sol
// https://docs.uniswap.org/protocol/V2/reference/smart-contracts/Pair-ERC-20
interface IERC20 {
    // Returns the account balance of another account with address _owner.
    function balanceOf(address owner) external view returns (uint256);

    /**
     * Allows _spender to withdraw from your account multiple times, up to the _value amount.
     * If this function is called again it overwrites the current allowance with _value.
     * Lets msg.sender set their allowance for a spender.
     **/
    function approve(address spender, uint256 value) external; // return type is deleted to be compatible with USDT

    /**
     * Transfers _value amount of tokens to address _to, and MUST fire the Transfer event.
     * The function SHOULD throw if the message caller’s account balance does not have enough tokens to spend.
     * Lets msg.sender send pool tokens to an address.
     **/
    function transfer(address to, uint256 value) external returns (bool);
}

// https://github.com/Uniswap/v2-periphery/blob/master/contracts/interfaces/IWETH.sol
interface IWETH is IERC20 {
    // Convert the wrapped token back to Ether.
    function withdraw(uint256) external;
}

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IUniswapV2Callee.sol
// The flash loan liquidator we plan to implement this time should be a UniswapV2 Callee
interface IUniswapV2Callee {
    function uniswapV2Call(address sender, uint256 amount0, uint256 amount1, bytes calldata data) external;
}

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IUniswapV2Factory.sol
// https://docs.uniswap.org/protocol/V2/reference/smart-contracts/factory
interface IUniswapV2Factory {
    // Returns the address of the pair for tokenA and tokenB, if it has been created, else address(0).
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IUniswapV2Pair.sol
// https://docs.uniswap.org/protocol/V2/reference/smart-contracts/pair
interface IUniswapV2Pair {
    /**
     * Swaps tokens. For regular swaps, data.length must be 0.
     * Also see [Flash Swaps](https://docs.uniswap.org/protocol/V2/concepts/core-concepts/flash-swaps).
     **/
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;

    /**
     * Returns the reserves of token0 and token1 used to price trades and distribute liquidity.
     * See Pricing[https://docs.uniswap.org/protocol/V2/concepts/advanced-topics/pricing].
     * Also returns the block.timestamp (mod 2**32) of the last block during which an interaction occured for the pair.
     **/
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);

    function token0() external view returns (address);

    function token1() external view returns (address);
}

// ----------------------IMPLEMENTATION------------------------------

contract LiquidationOperator is IUniswapV2Callee {
    uint8 public constant health_factor_decimals = 18;

    // TODO: define constants used in the contract including ERC-20 tokens, Uniswap Pairs, Aave lending pools, etc. */
    //    *** Your code here ***
    uint constant healthFactorDecimals = 18;

    IWETH constant WETH = IWETH(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IUniswapV2Factory constant uniswapV2Factory = IUniswapV2Factory(0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f);
    ILendingPool constant lendingPool = ILendingPool(0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9);

    event Liquidate(
        address indexed liquidationTarget,
        address indexed debtAsset,
        address indexed collateralAsset,
        uint256 profit,
        address liquidator
    );

    // END TODO

    // some helper function, it is totally fine if you can finish the lab without using these function
    // https://github.com/Uniswap/v2-periphery/blob/master/contracts/libraries/UniswapV2Library.sol
    // given an input amount of an asset and pair reserves, returns the maximum output amount of the other asset
    // safe mul is not necessary since https://docs.soliditylang.org/en/v0.8.9/080-breaking-changes.html
    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountOut) {
        require(amountIn > 0, "UniswapV2Library: INSUFFICIENT_INPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "UniswapV2Library: INSUFFICIENT_LIQUIDITY");
        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 1000 + amountInWithFee;
        amountOut = numerator / denominator;
    }

    // some helper function, it is totally fine if you can finish the lab without using these function
    // given an output amount of an asset and pair reserves, returns a required input amount of the other asset
    // safe mul is not necessary since https://docs.soliditylang.org/en/v0.8.9/080-breaking-changes.html
    function getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountIn) {
        require(amountOut > 0, "UniswapV2Library: INSUFFICIENT_OUTPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "UniswapV2Library: INSUFFICIENT_LIQUIDITY");
        uint256 numerator = reserveIn * amountOut * 1000;
        uint256 denominator = (reserveOut - amountOut) * 997;
        amountIn = (numerator / denominator) + 1;
    }

    constructor() {
        // TODO: (optional) initialize your contract
        //   *** Your code here ***
        // END TODO
    }

    // TODO: add a `receive` function so that you can withdraw your WETH
    //   *** Your code here ***
    receive() external payable {}

    // END TODO

    // required by the testing script, entry for your liquidation call
    function operate(
        address liquidationTarget,
        address debtAsset,
        address collateralAsset,
        uint256 debtAmount
    ) external {
        // TODO: implement your liquidation logic

        // 0. security checks and initializing variables
        //    *** Your code here ***

        // 1. get the target user account data & make sure it is liquidatable
        //    *** Your code here ***
        (, , , , , uint256 healthFactor) = lendingPool.getUserAccountData(liquidationTarget);

        console.log("\n\tHealth factor: %s", healthFactor);

        require(healthFactor < (10 ** healthFactorDecimals), "Health factor of total loans must be below 1");

        // 2. call flash swap to liquidate the target user
        // based on https://etherscan.io/tx/0xac7df37a43fab1b130318bbb761861b8357650db2e2c6493b73d6da3d9581077
        // we know that the target user borrowed USDT with WBTC as collateral
        // we should borrow USDT, liquidate the target user and get the WBTC, then swap WBTC to repay uniswap
        // (please feel free to develop other workflows as long as they liquidate the target user successfully)
        //    *** Your code here ***
        bytes memory data = abi.encode(liquidationTarget, debtAsset, collateralAsset);
        IUniswapV2Pair pair = IUniswapV2Pair(uniswapV2Factory.getPair(debtAsset, address(WETH)));
        console.log("\tPair address: %s\n", address(pair));
        if (pair.token0() == debtAsset) {
            pair.swap(debtAmount, 0, address(this), data);
        } else {
            pair.swap(0, debtAmount, address(this), data);
        }

        // 3. Convert the profit into ETH and send back to sender
        //    *** Your code here ***
        uint256 balance = WETH.balanceOf(address(this));
        WETH.withdraw(balance);
        payable(msg.sender).transfer(address(this).balance);

        emit Liquidate(liquidationTarget, debtAsset, collateralAsset, address(this).balance, msg.sender);
        // END TODO
    }

    // required by the swap
    function uniswapV2Call(address, uint256 amount0, uint256 amount1, bytes calldata data) external override {
        // TODO: implement your liquidation logic

        // 2.0. security checks and initializing variables
        //    *** Your code here ***
        address token0 = IUniswapV2Pair(msg.sender).token0(); // fetch the address of token0
        address token1 = IUniswapV2Pair(msg.sender).token1(); // fetch the address of token1
        require(msg.sender == uniswapV2Factory.getPair(token0, token1), "Sender must be V2 pair"); // ensure that msg.sender is a V2 pair

        (address liquidationTarget, address debtAsset, address collateralAsset) = abi.decode(
            data,
            (address, address, address)
        );

        // 2.1 liquidate the target user
        //    *** Your code here ***
        uint256 debtToCover;
        if (token0 == debtAsset) {
            debtToCover = amount0;
        } else {
            debtToCover = amount1;
        }
        IERC20(debtAsset).approve(address(lendingPool), debtToCover);
        console.log(
            "\tCollateral: %s\n\tDebt: %s\n\tLiquidation target: %s",
            collateralAsset,
            debtAsset,
            liquidationTarget
        );
        console.log("\tDebt to cover: %s\n", debtToCover);
        console.log("\tBalance collateral asset (before): %s", IERC20(collateralAsset).balanceOf(address(this)));
        console.log("\tBalance debt asset (before): %s", IERC20(debtAsset).balanceOf(address(this)));
        lendingPool.liquidationCall(collateralAsset, debtAsset, liquidationTarget, debtToCover, false);
        console.log("\tBalance collateral asset (after): %s", IERC20(collateralAsset).balanceOf(address(this)));
        console.log("\tBalance debt asset (after): %s\n", IERC20(debtAsset).balanceOf(address(this)));

        // 2.2 swap WBTC for other things or repay directly
        //    *** Your code here ***
        if (collateralAsset != address(WETH)) {
            IUniswapV2Pair pair1 = IUniswapV2Pair(uniswapV2Factory.getPair(collateralAsset, address(WETH)));
            (uint256 token0Pool1Reserve, uint256 token1Pool1Reserve, ) = pair1.getReserves();

            uint256 collateralAmount = IERC20(collateralAsset).balanceOf(address(this));
            IERC20(collateralAsset).transfer(address(pair1), collateralAmount);

            uint256 amountOut = getAmountOut(collateralAmount, token0Pool1Reserve, token1Pool1Reserve);
            pair1.swap(0, amountOut, address(this), "");
        }

        // 2.3 repay
        //    *** Your code here ***
        IUniswapV2Pair pair0 = IUniswapV2Pair(uniswapV2Factory.getPair(debtAsset, address(WETH)));
        (uint256 token0Pool0Reserve, uint256 token1Pool0Reserve, ) = pair0.getReserves();

        uint256 repayAmount;
        if (token0 == debtAsset) {
            repayAmount = getAmountIn(debtToCover, token1Pool0Reserve, token0Pool0Reserve);
        } else {
            repayAmount = getAmountIn(debtToCover, token0Pool0Reserve, token1Pool0Reserve);
        }
        console.log("\tRepay amount: %s", repayAmount);
        WETH.transfer(address(pair0), repayAmount);
        // END TODO
    }
}
