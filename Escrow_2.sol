// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract escrow {
    //defining the users that can interact with the contract
    address public owner;
    address public mod;

    //list use to validate the parties
    mapping(address => uint256) public value;
    mapping(address => address) public counterparty;

    //defining the variables used for the arbitrage
    bool public arbitrage;
    uint256 public commission;
    uint256 public creationTime;

    modifier notPartie {
        //checkt that the sender is not the owner or the counterparty
        require(msg.sender != owner && msg.sender != counterparty[owner], "You are not allowed");
        _;
    }

    modifier onlyPartie {
        //check that the sender is one of the parties involved
        require(msg.sender == owner || msg.sender == counterparty[owner], "You are not allowed");
        _;
    }

    modifier afterCooldown{
        //must wait some time before asking for a mod
        require(block.timestamp > creationTime + 5 minutes, "You have to wait for the cooldown");
        _;
    }

    modifier allowedToRelease {    
        //the tokens can only be release by the owner or a mod
        require(msg.sender == owner || msg.sender == mod, "You are not allowed");
        _;
    }

    modifier allowedToCancel {
        //only the counterparty or the mod can cancel the transaction
        require(msg.sender == counterparty[owner] || msg.sender == mod, "You are not allowed");
        _;
    }

    function lockEth(address _towho) public payable {
        //must be something store in the contract
        require(msg.value > 0, "You must lock some ETH");

        //updating the variables with the info of the owner and counterparty
        owner = msg.sender;
        counterparty[msg.sender] = _towho;
        value[msg.sender] = msg.value;

        creationTime = block.timestamp;
    }

    function release() public allowedToRelease {
        //we check in the mapping who is the counterparty and the value stored in the contract
        //then the transfer is done
        if (arbitrage == true) {
            payable(counterparty[owner]).transfer(value[owner] - (value[owner] * commission)/ 100);
            payable (mod).transfer((value[owner] * commission) / 100);
            value[owner] = 0;
            mod = owner = address(0);
        } else {
            payable(counterparty[owner]).transfer(value[owner]);
            value[owner] = 0;
            owner = address(0);
        }                    
    }

    function cancel() public allowedToCancel {        
        //funds are return to the owner of the contract
        if (arbitrage == true){
            //in case a mod is involved they must pay a fee
            payable(owner).transfer(value[owner] - (value[owner] * commission)/ 100);
            payable(mod).transfer((value[owner] * commission) / 100);
            //restart the variables 
            value[owner] = 0;
            mod = owner = address(0);
        } else {
            payable(owner).transfer(value[owner]);
            //restart the variables 
            value[owner] = 0;
            owner = address(0);
        }
    }

    function callMod(uint256 _commission) public onlyPartie afterCooldown{
        //whoever call the mod should offer a commission for its services
        require(_commission > 0 && _commission < 10, "Commission cannot be more than 10%");

        //assigning the values to the mod variables
        commission = _commission;
        arbitrage = true;
    }

    function propouseMod() public notPartie {
        //mod can only apply if the parties ask for him
        require(arbitrage == true, "The parties haven't request a mod");

        mod = msg.sender;
    }
}