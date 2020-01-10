// cerditline.sol
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

pragma solidity >=0.4.24;
pragma experimental ABIEncoderV2;

import "ds-note/note.sol";
import { PileLike } from "../pile.sol";

// CreditLine is an implementation of the Ceiling module that defines the max amoutn a user can borrow.
// Borrowers can always repay and borrow new money as long as the total borrowed amount stays under the defined line of credit. Accrued interst is considered.
contract CreditLine is DSNote {
    // --- Auth ---
    mapping (address => uint) public wards;
    function rely(address usr) public auth { wards[usr] = 1; }
    function deny(address usr) public auth { wards[usr] = 0; }
    modifier auth { require(wards[msg.sender] == 1); _; }

    // --- Data ---
    PileLike pile;  
    mapping (uint =>  uint) public values;

    constructor(address pile_) public {
        pile = PileLike(pile_);
        wards[msg.sender] = 1;
    }

    function ceiling(uint loan) public returns(uint) {
        return sub(values[loan], pile.debt(loan));
    }

    function depend(bytes32 what, address addr) public auth {
        if (what == "pile") { pile = PileLike(addr); }
        else revert();
    }

    function file(uint loan, uint creditLine) public auth {
        values[loan] = creditLine;
    }

    function borrow(uint loan, uint amount) public auth {
        require(values[loan] >= add(pile.debt(loan), amount));
    }

    function repay(uint loan, uint amount) public note auth {
    }

    function add(uint x, uint y) internal pure returns (uint z) {
        require((z = x + y) >= x);
    }

    function sub(uint x, uint y) internal pure returns (uint z) {
        require((z = x - y) <= x);
    }
}