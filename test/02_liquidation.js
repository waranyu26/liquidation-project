const { expect } = require("chai");
const { network, ethers } = require("hardhat");
const { BigNumber, utils } = require("ethers");
const { writeFile } = require('fs');

describe("Liquidation - with USDC/WETH", function () {
  const liquidationTarget = "0x63f6037d3e9d51ad865056BF7792029803b6eEfD";
  const debtAsset = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"; // USDC
  const collateralAsset = "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2"; // WETH
  const useETHPair = true; // use USDC/WETH pair
  const debtAmount = "8128956343";

  it("test", async function () {
    await network.provider.request({
      method: "hardhat_reset",
      params: [{
        forking: {
          jsonRpcUrl: process.env.ALCHE_API,
          blockNumber: 11946808 - 1,
        }
      }]
    });

    const gasPrice = 0;

    const accounts = await ethers.getSigners();
    const liquidator = accounts[0].address;

    const beforeLiquidationBalance = BigNumber.from(await hre.network.provider.request({
      method: "eth_getBalance",
      params: [liquidator],
    }));

    const LiquidationOperator = await ethers.getContractFactory("LiquidationOperator");
    const liquidationOperator = await LiquidationOperator.deploy(overrides = { gasPrice: gasPrice });
    await liquidationOperator.deployed();

    const liquidationTx = await liquidationOperator.operate(liquidationTarget, debtAsset, collateralAsset, debtAmount, useETHPair, overrides = { gasPrice: gasPrice });
    const liquidationReceipt = await liquidationTx.wait();

    const liquidationEvents = liquidationReceipt.logs.filter(
      v => v && v.topics && v.address === '0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9' && Array.isArray(v.topics) &&
        v.topics.length > 3 && v.topics[0] === '0xe413a321e8681d831f4dbccbca790d2952b56f977908e45be37335533e005286')

    const expectedLiquidationEvents = liquidationReceipt.logs.filter(v => v.topics[3] === '0x00000000000000000000000063f6037d3e9d51ad865056bf7792029803b6eefd');

    expect(expectedLiquidationEvents.length, "no expected liquidation").to.be.above(0);
    expect(liquidationEvents.length, "unexpected liquidation").to.be.equal(expectedLiquidationEvents.length);

    const afterLiquidationBalance = BigNumber.from(await hre.network.provider.request({
      method: "eth_getBalance",
      params: [liquidator],
    }));

    const profit = afterLiquidationBalance.sub(beforeLiquidationBalance);
    console.log("\nProfit", utils.formatEther(profit), "ETH\n");

    expect(profit.gt(BigNumber.from(0)), "not profitable").to.be.true;
    // writeFile('profit.txt', String(utils.formatEther(profit)), function (err) { console.log("failed to write profit.txt: %s", err) });
  });
});
