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

pragma solidity >=0.4.23;

import "ds-test/test.sol";

import "../quant.sol";

contract Hevm {
    function warp(uint256) public;
}

contract QuantTest is DSTest {

    Quant quant;
    Hevm hevm;

    function setUp() public {
        hevm = Hevm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
        hevm.warp(1234567);
        quant = new Quant();
    }

    function testInitDebt() public {
        uint debt = 66 ether;
        quant.updateDebt(int(debt));
        assertEq(quant.debt(), debt);
    }

    function testIncreaseDebt() public {
        uint speed = uint(1000000003593629043335673583); // 12 % per year
        uint initialDebt = 66 ether;
        quant.file("itake", speed);
        quant.updateDebt(int(initialDebt));

        hevm.warp(now + 365 days); // 1 year passed 
        // debt after one year: 66 ether * 1,12 = 73.92 

        uint debt = 66 ether;
        quant.updateDebt(int(debt)); 
        assertEq(quant.debt(), 139.92 ether); // 73.92 + 66 = 139.92
    }

    function testDecreaseDebt() public {
        uint speed = uint(1000000003593629043335673583); // 12 % per year
        uint initialDebt = 66 ether;
        quant.file("itake", speed);
        quant.updateDebt(int(initialDebt));

        hevm.warp(now + 365 days); // 1 year passed
        // debt after one year: 66 ether * 1,12 = 73.92 

        int debt = -73.92 ether; 
        quant.updateDebt(debt);
        assertEq(quant.debt(), 0);
    }

    function testFileITake() public {
        uint speed = uint(1000000003593629043335673583);
        quant.file("itake", speed);
        (, uint speedNow, ) = quant.iTake();
        assertEq(speed, speedNow);
    }

    function testFailFileITakeWrongSelector() public {
        uint speed = uint(1000000003593629043335673583);
        quant.file("isupply", speed);
        (, uint speedNow, ) = quant.iTake();
        assertEq(speed, speedNow);
    }

    function testUpdateITake() public {
        uint debt = 100 ether;
        uint reserve = 300 ether;
        uint supplySpeed = 1000000001547125957863212450; // 5 % per year
                    
        quant.updateDebt(int(debt));
        quant.updateITake(supplySpeed, reserve); 
        // 0.05 * ((300 + 100) / 100) = 0.2
    
        (, uint speedNow, ) = quant.iTake();
        assertEq(speedNow, uint(1000000006188503831452849800));     
    }

    function testDrip() public {
        uint speed = uint(1000000003593629043335673583); // 12 % per year
        uint initialDebt = 66 ether;
        quant.file("itake", speed);
        quant.updateDebt(int(initialDebt));

        hevm.warp(now + 365 days); // 1 year passed 
        
        quant.drip();
        // debt after one year: 66 ether * 1,12 = 73.92 
        assertEq(quant.debt(), 73.92 ether);
    }

    // --- Math ---
    uint256 constant ONE = 10 ** 27;
    function rpow(uint x, uint n, uint base) internal pure returns (uint z) {
        assembly {
            switch x case 0 {switch n case 0 {z := base} default {z := 0}}
            default {
                switch mod(n, 2) case 0 { z := base } default { z := x }
                let half := div(base, 2)  // for rounding.
                for { n := div(n, 2) } n { n := div(n,2) } {
                let xx := mul(x, x)
                if iszero(eq(div(xx, x), x)) { revert(0,0) }
                let xxRound := add(xx, half)
                if lt(xxRound, xx) { revert(0,0) }
                x := div(xxRound, base)
                if mod(n,2) {
                    let zx := mul(z, x)
                    if and(iszero(iszero(x)), iszero(eq(div(zx, x), z))) { revert(0,0) }
                    let zxRound := add(zx, half)
                    if lt(zxRound, zx) { revert(0,0) }
                    z := div(zxRound, base)
                }
            }
            }
        }
    }

    function rmul(uint x, uint y) internal pure returns (uint z) {
        z = mul(x, y) / ONE;
    }

    function add(uint x, uint y) internal pure returns (uint z) {
        require((z = x + y) >= x);
    }

    function sub(uint x, uint y) internal pure returns (uint z) {
        require((z = x - y) <= x);
    }

    function mul(uint x, uint y) internal pure returns (uint z) {
        require(y == 0 || (z = x * y) / y == x);
    }
}

