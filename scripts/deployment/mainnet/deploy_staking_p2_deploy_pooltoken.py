from brownie import (
    accounts,
    accounts,
    AdminUpgradeabilityProxy,
    Contract,
    PoolToken
)

from .staking_config import (
    MAHA_ADDRESS,
    ARTH_ADDRESS,
    USDC_ADDRESS,
    PROXY_ADMIN,
    SCLP_ADDRESS,
    save_abi,
    save_output,
    repeat
)

DEPLOYER = accounts.load('0')
print('Deployer is ', DEPLOYER)
CONFS = 1


def main():
    output_file = {}
    deployer = accounts.at(DEPLOYER)

    output_file["MahaToken"] = {
        "abi": "IERC20",
        "address": MAHA_ADDRESS
    }

    output_file["ARTH"] = {
        "abi": "IERC20",
        "address": ARTH_ADDRESS
    }

    output_file["USDC"] = {
        "abi": "IERC20",
        "address": USDC_ADDRESS
    }

    output_file["SCLP"] = {
        "abi": "IERC20",
        "address": SCLP_ADDRESS
    }

    pool_token = repeat(
        PoolToken.deploy,
        {"from": deployer, "required_confs": CONFS}
    )

    print("instance deployed", pool_token.address)

    proxy = repeat(
        AdminUpgradeabilityProxy.deploy,
        pool_token,
        PROXY_ADMIN,
        bytes(),
        {"from": deployer, "required_confs": CONFS}
    )

    print("proxy deployed", pool_token.address)

    output_file["PoolToken"] = {
        "abi": "IERC20",
        "address": pool_token.address
    }

    instance = Contract.from_abi('PoolToken', proxy, pool_token.abi)
    repeat(
        instance.initialize,
        "PoolToken",
        "MAHAX-PL",
        [ARTH_ADDRESS, USDC_ADDRESS, MAHA_ADDRESS, SCLP_ADDRESS],
        deployer,
        deployer,
        {"from": deployer, "required_confs": CONFS}
    )

    save_output(output_file, 'PoolToken')
