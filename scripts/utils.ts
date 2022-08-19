import * as fs from "fs";
import hre, { ethers, network } from "hardhat";
import { HardhatRuntimeEnvironment } from "hardhat/types";

export const wait = (ms: number) =>
  new Promise((resolve) => setTimeout(resolve, ms));

export default async function verifyContract(
  hre: HardhatRuntimeEnvironment,
  address: string,
  constructorArguments: any[]
) {
  try {
    // await wait(20 * 1000); // wait for 20s

    await hre.run("verify:verify", {
      address,
      constructorArguments,
    });
  } catch (error: any) {
    if (error.name !== "NomicLabsHardhatPluginError") {
      console.error(`- Error verifying: ${error.name}`);
      console.error(error);
    }
  }
}

export const saveABI = (
  key: string,
  abi: string,
  address: string,
  verified: boolean
) => {
  const filename = `./output/${network.name}.json`;

  let outputFile: any = {};
  if (fs.existsSync(filename)) {
    const data = fs.readFileSync(filename).toString();
    outputFile = data === "" ? {} : JSON.parse(data);
  }

  outputFile[key] = {
    abi,
    verified,
    address,
  };

  fs.writeFileSync(filename, JSON.stringify(outputFile, null, 2));
  console.log(`saved ${key}:${address} into ${network.name}.json`);
};

export const getOutputAddress = (key: string) => {
  const filename = `./output/${network.name}.json`;

  let outputFile: any = {};
  if (fs.existsSync(filename)) {
    const data = fs.readFileSync(filename).toString();
    outputFile = data === "" ? {} : JSON.parse(data);
  }

  if (!outputFile[key]) return;
  return outputFile[key].address;
};

export const deployOrLoad = async (
  key: string,
  contractName: string,
  args: any[]
) => {
  const addr = await getOutputAddress(key);
  if (addr) {
    console.log(`loading ${key} at ${addr}`);
    return await ethers.getContractAt(contractName, addr);
  }

  console.log(`deploying ${key}`);
  const factory = await ethers.getContractFactory(contractName);
  const instance = await factory.deploy(...args);
  await instance.deployed();
  console.log(
    `${instance.address} -> tx hash: ${instance.deployTransaction.hash}`
  );

  await saveABI(key, contractName, instance.address, false);
  return instance;
};

export const deployOrLoadAndVerify = async (
  key: string,
  contractName: string,
  args: any[],
  delay: number = 0
) => {
  const instance = await deployOrLoad(key, contractName, args);

  const filename = `./output/${network.name}.json`;
  if (fs.existsSync(filename)) {
    const data = fs.readFileSync(filename).toString();
    const outputFile = JSON.parse(data);

    if (!outputFile[key].verified) {
      await wait(delay);
      await verifyContract(hre, instance.address, args);
      await saveABI(key, contractName, instance.address, true);
    }
  }

  return instance;
};
