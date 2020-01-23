// Copyright (C) 2019 Centrifuge

// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

pragma solidity >=0.5.12;

import "../../system.sol";
import "../../users/borrower.sol";

contract BalanceTest is SystemTest {

    Borrower borrower;
    address borrower_;
    
    SwitchableDistributor distributor;
        
    function setUp() public {
        baseSetup();
        distributor = SwitchableDistributor(address(lenderDeployer.distributor()));
        // setup users
        borrower = new Borrower(address(shelf), address(distributor), currency_, address(pile));
        borrower = new Borrower(address(shelf), address(distributor), currency_, address(pile));
        borrower_ = address(borrower);
    }
    
    function balanceTake() public {
        uint initialCurrencyBalance = currency.balanceOf(address(shelf));
        uint takeAmount = currency.balanceOf(address(junior));
        borrower.balance();
        assertPostConditionTake(takeAmount, initialCurrencyBalance);
    }

    function balanceGive() public {
        uint initialCurrencyBalance = currency.balanceOf(address(shelf));
        uint giveAmount = currency.balanceOf(address(junior));
        borrower.balance();
        assertPostConditionGive(giveAmount, initialCurrencyBalance);
    }

    function assertPreConditionTake(uint takeAmount) public {
        // assert: borrowFromTranches is active
        assert(distributor.borrowFromTranches());
        // assert: junior has enough capital
        assert(currency.balanceOf(address(junior)) == takeAmount);
    }

    function assertPostConditionTake(uint takeAmount, uint initialCurrencyBalance) public {
        // assert: takeAmount > 0
        assert(takeAmount > 0);
        // assert: all funds transferred from tranche reserve
        assertEq(currency.balanceOf(address(junior)), 0);
        // assert: junior received funds
        assertEq(currency.balanceOf(address(shelf)), add(initialCurrencyBalance, takeAmount));
    }

    function assertPreConditionGive(uint giveAmount) public {
        // assert: borrowFromTranches is inactive
        assert(!distributor.borrowFromTranches());
        // assert: shelf has funds
        assert(currency.balanceOf(address(shelf)) == giveAmount);
    }

    function assertPostConditionGive(uint giveAmount, uint initialJuniorBalance) public {
        // assert: giveAmount > 0
        assert(giveAmount > 0);
        // assert: all funds transferred from shelf
        assertEq(currency.balanceOf(address(shelf)), 0);
        // assert: all funds transferred from shelf
        assertEq(currency.balanceOf(address(junior)), add(initialJuniorBalance, giveAmount));
    }

    function testBalanceTake() public {
        uint takeAmount = 100 ether;
        // supply junior tranche with funds
        supplyFunds(takeAmount, address(junior));
        assertPreConditionTake(takeAmount);
        // take money from tranche and transfer into shelf
        balanceTake();
    }

    function testFailBalanceTakeNoFundsAvailable() public {
        // junior tranche not supplied with capital
        balanceTake();
    }

    function testFailBalanceTakeInactive() public {
        uint takeAmount = 100 ether;
        // supply junior tranche with funds
        supplyFunds(takeAmount, address(junior));
        distributor.file("borrowFromTranches", false);
        balanceTake();
    }

    function testBalanceGive() public {
        uint giveAmount = 100 ether;
        // supply shelf tranche with funds
        supplyFunds(giveAmount, address(junior));
        // deactivate borrow from tranches
        distributor.file("borrowFromTranches", false);
        // take money from shelf and transfer into shelf
        balanceGive();
    }

    function testFailBalanceGiveShelfHasNoFunds() public {
        distributor.file("borrowFromTranches", false);
        // do not supply shelf with funds
        balanceGive();
    }

    function testFailBalanceGiveInactive() public {
         uint giveAmount = 100 ether;
        // supply shelf tranche with funds
        supplyFunds(giveAmount, address(junior));
        // do not deactivate borrow
        // take money from shelf and transfer into shelf
        balanceGive();
    }

    // Helper to supply shelf or tranches with currency without using supply or repay, since these functions are usign balance internally.
    function supplyFunds(uint amount, address addr) public {
        currency.mint(address(addr), amount);
    }
}