// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ERC20 {
    function transferFrom(address from, address to, uint256 value) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
    function decimals() external view returns (uint8);
}

contract forward{
    
    ERC20 public token; //0x5fC6Cb2887a180aeC1e3391A0750307311B9Fad7
    uint256 public decimals;

    uint256 public nominal;
    uint256 public minMargin;
    
    uint256 public strike;
    uint256 public currentPrice;

    string public asset; 

    mapping (address => address) public parties;
    mapping (address => int256) public margin;
    mapping (address => uint256) public deposit;
    mapping (address => int256) public profit;

    mapping (address => bool) public long;
    mapping (address => bool) public short;

    constructor (address _tokenAddress, uint256 _nominal, uint256 _strike, string memory _asset){
        token = ERC20(_tokenAddress);

        nominal = _nominal;
        strike = _strike;
        asset = _asset;

        decimals = 10**uint256(token.decimals());

        minMargin = (nominal * strike * decimals) / 10;
    }

    function openLongContract(uint256 _margin) public{
        require(long[msg.sender] == false);
        require(_margin >= minMargin, "Need to stake more tokens");
        require(token.allowance(msg.sender, address(this)) >= _margin, "Insufficient allowance");
        require(token.transferFrom(msg.sender, address(this), _margin));

        deposit[msg.sender] = _margin;
        long[msg.sender] = true;
    }

    function openShortContract(uint256 _margin) public{
        require(short[msg.sender] == false);
        require(_margin >= minMargin, "Need to stake more tokens");
        require(token.allowance(msg.sender, address(this)) >= _margin, "Insufficient allowance");
        require(token.transferFrom(msg.sender, address(this), _margin));

        deposit[msg.sender] = _margin;
        short[msg.sender] = true;
    }

    function matchContract(address _address, uint256 _margin) public {
        require(parties[_address] == address(0));
        require(_margin >= minMargin, "Need to stake more tokens");
        require(token.allowance(msg.sender, address(this)) >= _margin, "Insufficient allowance");
        require(token.transferFrom(msg.sender, address(this), _margin));       

        parties[msg.sender] = _address;
        parties[_address] = msg.sender;

        deposit[msg.sender] = _margin;

        if (long[_address] == true) {
            short[msg.sender] = true;
        } else {
            long[msg.sender] = true;
        }
    }

    function updateMargin(address _address) public {
        require(parties[_address] != address(0));

        address counterParty;
        counterParty = parties[_address];

        if (long[_address] == true) {
            profit[_address] = int256((currentPrice - strike) * nominal) * int256(decimals);
            margin[_address] = int256(deposit[_address]) + profit[_address];

            profit[counterParty] = -profit[_address];
            margin[counterParty] = int256(deposit[counterParty]) + profit[counterParty];
        } else if (short[_address] == true) {
            profit[_address] = int256((strike - currentPrice) * nominal) * int256(decimals);
            margin[_address] = int256(deposit[_address]) + profit[_address];

            profit[counterParty] = -profit[_address];
            margin[counterParty] = int256(deposit[counterParty]) + profit[counterParty];
        }

    }

    function increaseDeposit(uint256 _deposit) public {
        require(parties[msg.sender] != address(0));
        require(token.allowance(msg.sender, address(this)) >= _deposit, "Insufficient allowance");
        require(token.transferFrom(msg.sender, address(this), _deposit));

        deposit[msg.sender] += _deposit;
    }

    function liquidateContract(address _address) public {
        require(parties[_address] != address(0));

        address counterParty;
        counterParty = parties[_address];

        token.transfer(_address, uint256(margin[_address]));
        token.transfer(counterParty, uint256(margin[counterParty]));

        margin[_address] = margin[counterParty] = 0;
        parties[_address] = parties[counterParty] = address(0);
        deposit[_address] = deposit[counterParty] = 0;
        long[_address] = long[counterParty] = false;
        short[_address] = short[counterParty] = false;

    }

    function updatePrice(uint256 _price) public {
        currentPrice = _price;
    }
}