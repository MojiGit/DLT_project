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

contract SmartForwardContract{
    
    ERC20 public token; //0x5fC6Cb2887a180aeC1e3391A0750307311B9Fad7
    AggregatorV3Interface internal dataFeed; // ETH/USD: 0x694AA1769357215DE4FAC081bf1f309aDC325306

    //nominal value of the contract ex. 10ETH
    uint256 public nominal;
    //initial margin required from the parties to keep their position 
    uint256 public initialMargin;    
    //strike of the contract
    uint256 public strike;  
    //contract maturity
    uint256 public maturityDate;
    uint256 public maturity;
    //just for reference the memo of the subjacent asset
    string public memo; 
    //to chekc if the contract is in use or not
    bool public available;
    //define the owner of the contract
    address public owner;

    constructor (address _USDaddress, address _oracleAddress, uint256 _nominal, uint256 _strike, string memory _memo, uint256 _maturityMins){
        //assigning the token that will be deposit as guarantee
        token = ERC20(_USDaddress);
        //assigning the price provider *should match with the memo
        dataFeed = AggregatorV3Interface(_oracleAddress);

        nominal = _nominal;
        strike = _strike * 10**uint256(token.decimals());
        memo = _memo;
        owner = msg.sender;
        available = true;
        maturity = _maturityMins * 1 minutes;

        //after this date the contract will be liquidated
        maturityDate = block.timestamp + maturity;
        //10% of the total exposure of the contract
        initialMargin = (nominal * strike) / 10;
    }

    //check the sender has enough allowance
    modifier checkAvailability {
        require(available == true, "contract is not available");
        _;
    }
    modifier checkAlowance {
        require(token.allowance(msg.sender, address(this)) >= initialMargin, "Insufficient allowance");
        _;
    }
    //check the address has a counterparty assigned
    modifier checkCounterparty {
        require(parties[msg.sender] != address(0), "yo need to have a party");
        _;
    }
    
    //store the long position address
    address public long;
    //store the short position address
    address public short;
    //store the expiration time for the orders
    mapping (address => uint256) public OrderExpirationDate;

    //open long order
    function createLongOrder(uint256 _timeMins) public checkAlowance checkAvailability{
        require(msg.sender != short, "short order open"); // sender cannot have an opposite order
        require(long == address(0) || block.timestamp >= OrderExpirationDate[long], "existing open order"); // the order book should be available

        if(short != address(0)){
            matchContract(short);//if is already an opposite orden then do instamatch
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
            matchContract(long);
        }else{
            OrderExpirationDate[msg.sender] = block.timestamp + _timeMins * 1 minutes;
            short = msg.sender;
        }
    }
    
    //this mapping is to relate the parties between them
    mapping (address => address) public parties;
    //relate the addresses with its margin
    mapping (address => uint256) public IM;


    //given an open order, someone can match it and be the counter party 
    function matchContract(address _address) public checkAlowance checkAvailability{
        require(msg.sender != _address, "you cannot match your own order");
        //check the address have an open order
        require(_address == long || _address == short, "the address is not in the book");
        //checking again that _address has allowance
        require(token.allowance(_address, address(this)) >= initialMargin, "Insufficient allowance"); //-----> this may create problems in case of instamatch

        if(block.timestamp < OrderExpirationDate[_address]){
            //transfering the initial margin to the SDC
            token.transferFrom(_address, address(this), initialMargin);
            token.transferFrom(msg.sender, address(this), initialMargin);
            //updating the book
            parties[msg.sender] = _address;
            parties[_address] = msg.sender;
            //updating the deposit value for the parties
            IM[msg.sender] = IM[_address] = initialMargin;
            //assigning a position to the msg.sender according to the party they matched
            (long == _address? short = msg.sender: long = msg.sender);
            available = false;
        } else {
            //if the timestamp is higher than the expiration date then we delete the order
            expireOrder(_address);
        }
    }

    //stores the spotprice that is going to be used to calculate the P&L of the contract
    uint256 public spotPrice;
    //stores the variable margin
    int256 public variableMargin;

    function VariableMarginLiquidation() public {
        require(available == false, "There is not trade to evaluate");

        int256 change;
        int256 previousVm = variableMargin;
        //update the spot price
        spotPrice = getSpotPrice();
        //calculate the variable margin < long perspective>
        variableMargin = (int256(spotPrice) - int256(strike)) * int256(nominal);
        //delta of the variable margin
        change = variableMargin - previousVm;

        /* if change > 0 means that the new VM is bigger than in the pass because of an increase in the spot price
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

    //liquidate a contract before maturity
    function manualLiquidation() public checkCounterparty{
        automaticLiquidation(msg.sender);
    }

    //in case of default we have to adjust the margins before the liquidation
    function adjustMargins(address _address, uint256 _default) private {
        if(IM[_address] > _default){ // check that the IM is enough to cover the loss
            IM[_address] -= _default;
            IM[parties[_address]] += _default;
        }else{ // if not the counterparty gets all the IM
            IM[parties[_address]] += IM[_address];
            IM[_address] = 0;
        }
    }

    //in case of maturity or default
    function automaticLiquidation(address _address) private {
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

    //call the oracle for the price feed
    function getSpotPrice() public view returns (uint256) {
        (   /* uint80 roundID */,
            int256 answer,
            /*uint startedAt*/,
            /*uint timeStamp*/,
            /*uint80 answeredInRound*/
        ) = dataFeed.latestRoundData();
        //the price given by chainlink comes with 8 decimals, but we are managing everything with 18
        return  uint256(answer * 10**10);
    }

    //just to check the tokens in the SDC
    function getContractBalance() public view returns (uint256) {
        return token.balanceOf(address(this));
    }

    //incase one of the parties wants to increase their initial margin
    function increaseMargin(uint256 _deposit) public checkCounterparty {
        require(token.allowance(msg.sender, address(this)) >= _deposit, "Insufficient allowance");
        require(token.transferFrom(msg.sender, address(this), _deposit));

        IM[msg.sender] += _deposit;
    }

    //delete an open order manually
    function deleteOrder() public checkAvailability{
        require(msg.sender == long || msg.sender == short);
        (msg.sender == long? long = address(0): short = address(0));
    }

    //delete an expired order
    function expireOrder(address _address) private {
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