pragma solidity >=0.5.15 <0.6.0;

import "tinlake-math/math.sol";
import "tinlake-auth/auth.sol";

contract ERC20Like {
  function balanceOf(address) public view returns (uint);
  function transferFrom(address,address,uint) public returns (bool);
  function mint(address, uint) public;
  function burn(address, uint) public;
  function totalSupply() public view returns (uint);
}

contract ShelfLike {
    function balanceRequest() public returns (bool requestWant, uint amount);
}

contract Reserve is Math, Auth {
    ERC20Like public currency;
    ShelfLike public shelf;

    bool public poolActive;
    uint256 public currencyAvailable;



    address self;

    constructor(address currency_) public {
        wards[msg.sender] = 1;
        currency = ERC20Like(currency_);
        poolActive = true;
        self = address(this);
    }

    function depend(bytes32 contractName, address addr) public auth {
        if (contractName == "shelf") { shelf = ShelfLike(addr); }
        else if (contractName == "currency") { currency = ERC20Like(addr); }
        else revert();
    }

    function activatePool(bool active) public auth {
        poolActive = active;
    }

    function updateMaxCurrency(uint currencyAmount) public auth {
        currencyAvailable = currencyAmount;
    }

    function balance() public{
        require(poolActive, "pool-not-active");

        (bool requestWant, uint currencyAmount) = shelf.balanceRequest();
        if (requestWant) {
            require(currencyAvailable >= currencyAmount, "not-enough-currency-reserve");
            require(currency.transferFrom(self, address(shelf), currencyAmount), "currency-transfer-from-reserve-failed");
            currencyAvailable = safeSub(currencyAvailable, currencyAmount);
            return;
        }
         require(currency.transferFrom(address(shelf), self, currencyAmount), "currency-transfer-from-shelf-failed");
    }
}	