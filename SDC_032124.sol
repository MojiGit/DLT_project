// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/* 
Contract description:
This is a smart derivative contract. Works as a future contract over an specific asset 
limitation:
-> only 2 parties involve
-> users cannot take more than one position
-> users cannot leverage in more than one contract
*/

//importing chainlink oracle
//import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
/* documentation: https://docs.chain.link/data-feeds/using-data-feeds#solidity
list of data feeds: https://docs.chain.link/data-feeds/price-feeds/addresses?network=ethereum&page=1&search=eth+%2F+u */
interface AggregatorV3Interface {
  function latestRoundData() external view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

//importing the ERC20 functions
interface ERC20 {
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function decimals() external view returns (uint8);
}

contract SmartForwardContract{
    
    ERC20 public token; //0x5fC6Cb2887a180aeC1e3391A0750307311B9Fad7
    AggregatorV3Interface internal dataFeed; // ETH/USD: 0x694AA1769357215DE4FAC081bf1f309aDC325306

    uint256 public nominal; //nominal value of the contract ex. 10ETH
    uint256 public initialMargin; //initial margin required from the parties to open the trade    
    uint256 public strike;  
    uint256 public maturityDate;
    uint256 public maturity;
    string public memo; //just for reference the memo of the subjacent asset 
    bool public available; //to check if the contract is in use or not
    address public owner; //define the owner of the contract

    constructor (address _USDaddress, address _oracleAddress, uint256 _nominal, uint256 _strike, string memory _memo, uint256 _maturityMins){
        
        token = ERC20(_USDaddress);//defining the token that will be deposit as collateral
        dataFeed = AggregatorV3Interface(_oracleAddress); //defining the price feeder

        nominal = _nominal;
        strike = _strike * 10**uint256(token.decimals()); //adding 18 decimals to the strike
        memo = _memo;
        owner = msg.sender;
        available = true;
        maturity = _maturityMins * 1 minutes; //for testing pouposes minutes are enough
        maturityDate = block.timestamp + maturity; //after this date the contract will be liquidated
        initialMargin = (nominal * strike) / 10; //10% of the total exposure of the contract
    }
    
    modifier checkAvailability {//checking if the contract is availanle
        require(available == true, "contract is not available");
        _;
    }
    
    modifier checkAlowance { //checking sender's allowance
        require(token.allowance(msg.sender, address(this)) >= initialMargin, "Insufficient allowance");
        _;
    }
    
    modifier checkCounterparty {//check the sender is already in a trade
        require(parties[msg.sender] != address(0), "yo need to have a party");
        _;
    }
    
    address public long; //store the address of the long position
    address public short; //store the address of the short position
    mapping (address => uint256) public OrderExpirationDate;//store the expiration date of the unmatch orders

    //function use to create a new order. Long position
    function createLongOrder(uint256 _timeMins) public checkAlowance checkAvailability{
        require(msg.sender != short, "short order open"); // sender can not have a long and short position at the same time
        require(long == address(0) || block.timestamp >= OrderExpirationDate[long], "existing open order"); // the order book should be available or the existing order must be expired

        if(short != address(0)){ //if is already a short orden then do matching
            matchOpenOrder(short);
        }else{//ordewise create the order
            OrderExpirationDate[msg.sender] = block.timestamp +  _timeMins * 1 minutes;
            long = msg.sender;
        }
    }

    //similar to previous function, but to create a short order 
    function createShortOrder(uint256 _timeMins) public checkAlowance checkAvailability{
        require(msg.sender != long, "long order open");
        require(short == address(0) || block.timestamp >= OrderExpirationDate[short],"existing open order");

        if(long != address(0)){
            matchOpenOrder(long);
        }else{
            OrderExpirationDate[msg.sender] = block.timestamp + _timeMins * 1 minutes;
            short = msg.sender;
        }
    }
    
    mapping (address => address) public parties; //this mapping is to relate the parties between them
    mapping (address => uint256) public IM; //relate the addresses with its initial margin

    /*This function receive as input an address that must be related with an open order
    and will create the trade between the given address and the sender; the sender take the opposite
    position */
    function matchOpenOrder(address _address) public checkAlowance checkAvailability{
        require(msg.sender != _address, "you cannot match your own order");
        require(_address == long || _address == short, "the address is not in the book"); //check the address have an open order 
        require(token.allowance(_address, address(this)) >= initialMargin, "Insufficient allowance"); //checking again that _address has allowance-----> this may create problems in case of instamatch

        if(block.timestamp < OrderExpirationDate[_address]){
            //transfering the initial margin to the SDC
            token.transferFrom(_address, address(this), initialMargin);
            token.transferFrom(msg.sender, address(this), initialMargin);
            //updating the book
            parties[msg.sender] = _address;
            parties[_address] = msg.sender;
            IM[msg.sender] = IM[_address] = initialMargin;//updating the initial margin of the parties
            (long == _address? short = msg.sender: long = msg.sender);//assigning a position to the msg.sender according to the party they matched
            available = false; //after a matching the contract is not available anymore 
        } else {//if the timestamp is higher than the expiration date of the order then we delete the order
            expireOrder(_address);
        }
    }

    uint256 public spotPrice; //stores the spotprice that is going to be used to calculate the Variable margin and liquidation of the contract
    int256 public variableMargin; //stores the variable margin

    function VariableMarginLiquidation() public {
        require(available == false, "There is not trade to evaluate"); //must be an existing trade

        int256 previousVm = variableMargin; // to store the initial value of the variable margin
        int256 change; // to store the change of the variable margin
        spotPrice = getSpotPrice();//update the spot price
        //calculate the variable margin < long perspective>
        variableMargin = (int256(spotPrice) - int256(strike)) * int256(nominal);
        change = variableMargin - previousVm;

        /* if change > 0 means that the new VM is bigger because of an increase in the spot price
        then the short position must compensate the long position
        the compensation is just the difference between the previous margin and the new one
        */
        if(change > 0){transferVariableMargin(short, uint256(change));} else {transferVariableMargin(long, uint256(-change));}    
    }

    function transferVariableMargin(address _address, uint256 _changeVm) private {
        if(token.allowance(_address, address(this)) > uint(_changeVm)){ //check if the party have enough funds to pay the margin
            token.transferFrom(_address, parties[_address], _changeVm); // transfer the funds
            if(block.timestamp >= maturityDate){automaticLiquidation(_address);} // the contract is liquidated if reach maturity 
        }else{ // the party default
            adjustMargins(_address, _changeVm); //if the party doesn't have enough funds the VM is taken from the IM
            automaticLiquidation(_address); // the contract is liquidated
        }
    }

    function manualLiquidation() public checkCounterparty{ //liquidate a contract before maturity
        VariableMarginLiquidation(); 
        automaticLiquidation(msg.sender);
    } // this function need to be test

    function adjustMargins(address _address, uint256 _default) private { //in case of default we have to adjust the margins before the liquidation
        if(IM[_address] > _default){ // check that the IM is enough to cover the loss
            IM[_address] -= _default;
            IM[parties[_address]] += _default;
        }else{ // if not the counterparty gets all the IM
            IM[parties[_address]] += IM[_address];
            IM[_address] = 0;
        }
    }

    function automaticLiquidation(address _address) private { //in case of maturity or default
        address counterparty = parties[_address];
        //transfering the initial margin to the parties
        token.transfer(_address, uint256(IM[_address]));
        token.transfer(counterparty, uint256(IM[counterparty]));
        //deleting the parties info
        delete IM[_address]; 
        delete IM[counterparty];
        delete parties[_address];
        delete parties[counterparty];
        long = address(0);
        short = address(0);
        variableMargin = 0;
        maturityDate = block.timestamp + maturity;
        available = true;
    }

    function getSpotPrice() public view returns (uint256) {//calls the oracle for the price feed
        (   /* uint80 roundID */,
            int256 answer,
            /*uint startedAt*/,
            /*uint timeStamp*/,
            /*uint80 answeredInRound*/
        ) = dataFeed.latestRoundData();
        //the price given by chainlink comes with 8 decimals, but we are managing everything with 18; this need to be check in case of changing the feed provider
        return  uint256(answer * 10**10);
    }

    function getContractBalance() public view returns (uint256) {//just to check the tokens deposits in the SDC
        return token.balanceOf(address(this));
    }

    //in the case one of the parties wants to increase their initial margin
    function increaseMargin(uint256 _deposit) public checkCounterparty {
        require(token.allowance(msg.sender, address(this)) >= _deposit, "Insufficient allowance");
        require(token.transferFrom(msg.sender, address(this), _deposit));

        IM[msg.sender] += _deposit;
    }
    
    function deleteOrder() public checkAvailability{ //delete an open and unmatched order manualy
        require(msg.sender == long || msg.sender == short);
        (msg.sender == long? long = address(0): short = address(0));
    }

    function expireOrder(address _address) private { //delete an expired order
        (_address == long? long = address(0): short = address(0));
    }

    //in case i want to change things without deploying another contract
    function recycle( uint256 _strike, uint256 _maturityMins) public checkAvailability {
        require(msg.sender == owner, "you are not allow");

        strike = _strike * 10**uint256(token.decimals());
        maturity = _maturityMins * 1 minutes;
        initialMargin = (nominal * strike) / 10;
    }

}