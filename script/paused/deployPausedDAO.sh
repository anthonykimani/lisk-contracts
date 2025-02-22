#!/usr/bin/env bash

echo "Instructing the shell to exit immediately if any command returns a non-zero exit status..."
set -e
echo "Done."

echo "Navigating to the root directory of the project..."
cd ../../
echo "Done."

echo "Setting environment variables..."
source .env
echo "Done."

echo "Creating $NETWORK directory inside deployment directory..."
if [ -z "$NETWORK" ]
then
      echo "NETWORK variable inside .env file is not set. Please set NETWORK environment variable."
      exit 1
else
      if [ -d "deployment/$NETWORK" ]
      then
            echo "Directory deployment/$NETWORK already exists."
      else
            mkdir deployment/$NETWORK
      fi
fi
echo "Done."

echo "Cleaning up the build artifacts to be able to deploy the contract..."
forge clean
echo "Done."

echo "Deploying and if enabled verifying L2GovernorPaused smart contract..."
if [ -z "$CONTRACT_VERIFIER" ]
then
      forge script --rpc-url="$L2_RPC_URL" --broadcast -vvvv script/contracts/L2/paused/L2GovernorPaused.s.sol:L2GovernorPausedScript
else
      if [ $CONTRACT_VERIFIER = "blockscout" ]
      then
            forge script --rpc-url="$L2_RPC_URL" --broadcast --verify --verifier blockscout --verifier-url $L2_VERIFIER_URL -vvvv script/contracts/L2/paused/L2GovernorPaused.s.sol:L2GovernorPausedScript
      fi
      if [ $CONTRACT_VERIFIER = "etherscan" ]
      then
            forge script --rpc-url="$L2_RPC_URL" --broadcast --verify --verifier etherscan --etherscan-api-key="$L2_ETHERSCAN_API_KEY" -vvvv script/contracts/L2/paused/L2GovernorPaused.s.sol:L2GovernorPausedScript
      fi
fi
echo "Done."

echo "Cleaning up the build artifacts to be able to deploy the contract..."
forge clean
echo "Done."

echo "Deploying and if enabled verifying L2VotingPowerPaused smart contract..."
if [ -z "$CONTRACT_VERIFIER" ]
then
      forge script --rpc-url="$L2_RPC_URL" --broadcast -vvvv script/contracts/L2/paused/L2VotingPowerPaused.s.sol:L2VotingPowerPausedScript
else
      if [ $CONTRACT_VERIFIER = "blockscout" ]
      then
            forge script --rpc-url="$L2_RPC_URL" --broadcast --verify --verifier blockscout --verifier-url $L2_VERIFIER_URL -vvvv script/contracts/L2/paused/L2VotingPowerPaused.s.sol:L2VotingPowerPausedScript
      fi
      if [ $CONTRACT_VERIFIER = "etherscan" ]
      then
            forge script --rpc-url="$L2_RPC_URL" --broadcast --verify --verifier etherscan --etherscan-api-key="$L2_ETHERSCAN_API_KEY" -vvvv script/contracts/L2/paused/L2VotingPowerPaused.s.sol:L2VotingPowerPausedScript
      fi
fi
echo "Done."