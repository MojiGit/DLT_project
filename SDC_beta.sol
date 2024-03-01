// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

//the goal is to create a SC that simulates a perpetual forward contract on ETH/USD
//both parties must deposit the margin to enter the trade and it will be calculated every x time
//any of the parties can execute the contract at any moment, the SC must be able to calculate the result of the trade
//in case the margin of any of the parties reach 0 the SC should liquidate the position
//an oracle should provide the price - Chainlink for instance 
interface ERC20 {
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
    // Add other necessary ERC20 functions
}

contract forward {

    //to store the nominal size of the contrat ex 100k
    uint256 public nominal;
    //min margin deposit based on the nominal
    uint256 public minMargin;
    //strike price of the contract
    uint256 public strike;
    uint256 public currentPrice;

    ERC20 public token; //0x173889f1Cbb6526B5f6464596621F9C79eAe8E07


    string public asset;
    
    //1=true, 0=false
    mapping (address => bool) public position;
    //to identify the parties involve in the trade
    mapping (address => address) public parties;
    mapping (address => uint256) public margin;
    address[] public addresses;

    constructor (uint256 _nominal, uint256 _strike, string memory _asset, address _tokenAddress) {
        nominal = _nominal;
        token = ERC20(_tokenAddress);
        asset = _asset;
        strike = _strike;
        minMargin = (nominal * strike *(10**uint256(token.decimals()))) / 10 ;
    }

    function openLongTrade (address _conterParty, uint256 _tokenAmount) public {
        require(_tokenAmount >= minMargin, "Insufficient tokens sent");
        require(token.allowance(msg.sender, address(this)) >= _tokenAmount, "Insufficient allowance");
        require(token.transferFrom(msg.sender, address(this), _tokenAmount), "Token transfer failed");

        parties[msg.sender] = _conterParty; 
        margin[msg.sender] = _tokenAmount;
        position[msg.sender] = true;
    }

    function getContractTokenBalance() public view returns (uint256) {
        return token.balanceOf(address(this));
    }

    function openShortTrade (address _conterParty) payable public {
        require(parties[msg.sender] == address(0));
        require(msg.value >= minMargin);
        
        parties[msg.sender] = _conterParty; 
        margin[msg.sender] = msg.value;
        position[msg.sender] = false;
        addresses.push(msg.sender);
    }

    function matchTrade (address _conterParty) payable public {
        require(parties[_conterParty] == msg.sender);
        require(msg.value >= minMargin);

        margin[msg.sender] = msg.value;
        addresses.push(msg.sender);
        
        if (position[_conterParty] == true){
            position[msg.sender] = false;
        } else {
            position[msg.sender] = true;
        }    
    }

    function updatePrice(uint256 _price) public {
        currentPrice = _price;
    }

    //function calculateMargins() public {
    //    for (uint256 i = 0; i < addresses.length; i++) {
    //        if (position[addresses[i]] == true) {
    //            margin[addresses[i]] =  ;
    //        }
    //    }
    //}

}