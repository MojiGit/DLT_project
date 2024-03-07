// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/* 
Contract description:
This is a smart derivative contract. Works as a future contract over an specific asset 
limitation:
-> only 2 parties involve
-> users cannot take more than one position
-> users cannot leverage in more than one contract
*/


//importing chainlink oracle
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
/* documentation: https://docs.chain.link/data-feeds/using-data-feeds#solidity
list of data feeds: https://docs.chain.link/data-feeds/price-feeds/addresses?network=ethereum&page=1&search=eth+%2F+u */

//importing the ERC20 function we are going to use 
interface ERC20 {
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function decimals() external view returns (uint8);
}

contract forward{
    
    ERC20 public token; //0x5fC6Cb2887a180aeC1e3391A0750307311B9Fad7
    AggregatorV3Interface internal dataFeed; // ETH/USD: 0x694AA1769357215DE4FAC081bf1f309aDC325306

    //To store the decimal of the tokens we are going to manage 
    uint256 public decimals;
    //nominal value of the contract ex. 10ETH
    uint256 public nominal;
    //initial margin required from the parties to keep their position 
    uint256 public initialMargin;    
    //strike of the contract
    uint256 public strike;  
    //just for reference the memo of the subjacent asset
    string public memo; 

    constructor (address _USDaddress, address _oracleAddress, uint256 _nominal, uint256 _strike, string memory _memo){
        //assigning the token that will be deposit as guarantee
        token = ERC20(_USDaddress);
        //getting the number of decimals from the ERC20 token
        decimals = uint256(token.decimals());
        //assigning the price provider *should match with the memo
        dataFeed = AggregatorV3Interface(_oracleAddress);

        nominal = _nominal;
        strike = _strike * 10**decimals;
        memo = _memo;

        //10% of the total exposure of the contract
        initialMargin = (nominal * strike * 10**decimals) / 10;
    }
    
    //store the long position address
    address public long;
    //store the short position address
    address public short;

    mapping (address => uint256) public upperBand;
    mapping (address => uint256) public lowerBand;

    //this function is to open a long order in the book
    function createLongOrder(uint256 _upperBand, uint256 _lowwerBand) public {
        require(msg.sender != short);
        require(long == address(0));
        require(token.allowance(msg.sender, address(this)) >= initialMargin, "Insufficient allowance");

        upperBand[msg.sender] = _upperBand;
        lowerBand[msg.sender] = _lowwerBand;
        long = msg.sender;
    }

    //similar to previous function, but to create a short order 
    function createShortOrder(uint256 _upperBand, uint256 _lowwerBand) public{
        require(msg.sender != long);
        require(short == address(0));
        require(token.allowance(msg.sender, address(this)) >= initialMargin, "Insufficient allowance");
        
        upperBand[msg.sender] = _upperBand;
        lowerBand[msg.sender] = _lowwerBand;
        short = msg.sender;
    }
    
    mapping (address => address) public parties;
    mapping (address => uint256) public margin;


    //given an open order, someone can match it and be the counter party 
    function matchContract(address _address) public {
        require(msg.sender != _address);
        //check the address have an open order
        require(_address == long || _address == short);
        //check there is no counterparty 
        require(parties[_address] == address(0));
        require(token.allowance(msg.sender, address(this)) >= initialMargin, "Insufficient allowance");
        require(token.allowance(_address, address(this)) >= initialMargin, "Insufficient allowance");

        getSpotPrice();
        if(lowerBand[_address] < spotPrice  && spotPrice < upperBand[_address]){
            //transfering the initial margin to the SDC
            token.transferFrom(_address, address(this), initialMargin);
            token.transferFrom(msg.sender, address(this), initialMargin);
            //updating the book
            parties[msg.sender] = _address;
            parties[_address] = msg.sender;
        
            //updating the deposit value for the parties
            margin[msg.sender] = margin[_address] = initialMargin;

            //assigning a position to the msg.sender according to the party they matched
            (long == _address? short = msg.sender: long = msg.sender);
        } 
    }

    //store the spotprice that is going to be used to calculate the P&L of the contract
    uint256 public spotPrice;

    function dailyLiquidation() public {
//----------------> pensar en los require
        getSpotPrice();
        uint256 variableMargin;

        if(spotPrice > strike){
            //significa que short debe pagar a long
            variableMargin = (spotPrice - strike) * nominal;
            token.transferFrom(short, long, variableMargin);                      
        } else if (spotPrice < strike){
            variableMargin = (strike - spotPrice) * nominal;
            token.transferFrom(long, short, variableMargin);
        } // que pasa si spot igual a strike ?
//----------------> falta agregar maturity del contrato
//----------------> que pasa si una de las partes no tiene suficientes tokens ? deberia de entonces usarse el Margin, como checkeo eso ?
    }
    
    function increaseDeposit(uint256 _deposit) public {
        require(parties[msg.sender] != address(0));
        require(token.allowance(msg.sender, address(this)) >= _deposit, "Insufficient allowance");
        require(token.transferFrom(msg.sender, address(this), _deposit));

        margin[msg.sender] += _deposit;
    }

    function liquidateContract() public {
        require(parties[msg.sender] != address(0));

        address counterparty = parties[msg.sender];

        token.transfer(msg.sender, uint256(margin[msg.sender]));
        token.transfer(counterparty, uint256(margin[counterparty]));
        
        delete margin[msg.sender]; 
        delete margin[counterparty];
        delete parties[msg.sender];
        delete parties[counterparty];
        long = address(0);
        short = address(0);

    }

    function getSpotPrice() public {
        (   /* uint80 roundID */,
            int256 answer,
            /*uint startedAt*/,
            /*uint timeStamp*/,
            /*uint80 answeredInRound*/
        ) = dataFeed.latestRoundData();
        //the price given by chainlink comes with 8 decimals, but we are managing everything with 18
        spotPrice = uint256(answer * 10**10);
    }

    function getContractBalance() public view returns (uint256) {
        return token.balanceOf(address(this));
    }

    //this function is to delete an open order
    function deleteOrder() public {
        require(msg.sender == long || msg.sender == short);
        (msg.sender == long? long = address(0): short = address(0));
    }

}