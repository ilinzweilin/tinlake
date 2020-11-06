pragma solidity >=0.5.15. <0.6.0;


import "tinlake-auth/auth.sol";
import "tinlake-math/math.sol";


interface AssessorLike {
    function calcSeniorTokenPrice() external view returns(uint);
    function calcSeniorAssetValue(uint seniorDebt, uint seniorBalance) public pure returns(uint);
    function changeSeniorAsset(uint seniorRatio, uint seniorSupply, uint seniorRedeem) external;
}

interface CordinatorLike {
    function calcSeniorAssetValue(uint seniorRedeem, uint seniorSupply, uint currSeniorAsset, uint reserve_, uint nav_) public pure returns(uint) ;
    function calcSeniorRatio(uint seniorAsset, uint NAV, uint reserve_) public pure returns(uint);
}

interface ReserveLike {
    function totalBalance() external view returns(uint);
    function deposit(uint daiAmount) public;
    function payout(uint currencyAmount) public;
}

interface NAVFeedLike {
    // TODO: check what better to use approx NAV or current NAV
    function currentNAV() external view returns(uint);
}

interface TrancheLike {
    function mint(address usr, uint amount) public;
}

interface ERC20Like {
    function burn(address, uint) external;
}
  
contract Clerk is Auth, Math {

   
    // DAI to be paid back for outstanding clerk financed loans
    uint public expectedRevenue;
    // virtual DAI balance that was already added to the seniorAssetValue = virtual DAI balance
    uint public balanceDAI;
    // DAI that are drawn from the vault without accrued interest: required for mkr interest calculation
    uint public principalDAI;
    // DROP that are used as collatreal for already drawn DAI
    uint public collateralAtWork;


    address public mgr;
    address public dai;

    AssessorLike assessor;
    CoordinatorLike coordinator;
    ReserveLike reserve;
    NAVFeedLike nav;
    TrancheLike tranche;

    constructor(address mgr_, address dai_, address assessor_, address coordinator_, address reserve_, address nav_, address tranche_) {
        wards[msg.sender] = 1;
        dai = dai_;
        mgr = mgr_;

        assessor = AssessorLike(assessor_);
        coordinator = CoordinatorLike(coordinator_);
        reserve = ReserveLike(reserve_);
        nav = NAVFeedLike(nav_);
        tranche = TrancheLike(tranche_);
    }

    function join(uint amountDROP) public auth {
        // calculate DAI amount that can be minted considering current DROP token price
        uint amountDAI = rmul(amountDROP, assessor.calcSeniorTokenPrice());

        // TODO: check if the injected DAI liquidity could potentially violate the pool constraints

        // increase balanceDAI, so that the amount can be drawn
        balanceDAI = safeAdd(balanceDAI, amountDAI);
        
        // increase seniorAssetValue by amountDAI to keep the DROP token price constant 
        updateSeniorValue(amountDAI);
        
        // mint amountDROP & lock in vault
        tranche.mint(address(this), amountDROP);
        mgr.join(d);
    }

    function draw(uint amountDAI) public auth {
        // TODO: maybe find a better condition
        require(reserve.totalBalance() == 0, "Use DAI in reserves first");
        // make sure amountDAI does not exceed the virtual DAI balance
        require(safeAdd(principalDAI, amountDAI) <= balanceDAI, "Add amount to senior asset first");

        principalDAI = safeAdd(principalDAI, amountDAI);
        collateralAtWork = safeAdd(collateralAtWork, rdiv(amountDAI, assessor.calcSeniorTokenPrice()));

        drip();
        expectedRevenue = safeAdd(expectedRevenue, amountDAI);
        
        // draw dai and move to reserve
        mgr.draw(amountDAI);
        dai.approve(address(reserve), amountDAI);
        reserve.deposit(amountDAI);
    }

    function wipe(uint amountDAI) public auth {
        require(mgr.tab() > 0, "vault debt already repaid");

        drip();
        expectedRevenue = safeDiv(expectedRevenue, amountDAI);  

        // decrease the principal amount by amountDAI without accrued interest
        principalReturned = rdiv(amountDAI, safeAdd(ONE, tinlakeInterest);
        // decrease the collateral amount based on the principal returned and weighted DROP price
        collateralAtWork = safeSub(collateralAtWork, rdiv(principalReturned,  weightedDropPrice()));

        require(reserve.payout(amountDAI), "not enough funds in reserve");
        mgr.wipe(d);
    }

     // remove drop from mkr system
    function exit(uint drop) public auth {
        drip();
        require(expectedRevenue == 0);
        
        // TODO decrease: balanceDAI 
        updateSeniorValue(-drop);
        mgr.exit(drop);
        drop.burn(self, dropToBurn); // TODO: fix impl
    }

    // principal + DAI value of collateral that is not put to work should not exceed balanceDAI => blanceDAI is constant
    // burn DROP tokens worth of accrued tinlake interest to prevent senior dilution
    function rebalanceSenior() public {
        uint pice = senior.calcSeniorTokenPrice()
        // DROP currently not used as collateral
        uint unusedCollateral = safeSub(mgr.ink(), collateralAtWork);
        drip();
        uint currentBalanceDAI = safeSub(safeAdd(principalDAI, rmul(unusedCollateral, senior.calcSeniorTokenPrice(), profit());   // TODO: fix call: vat -> urn -> ink
        // TODO: maybe check with current debt
        uint balanceSurplusDAI = safeSub(currentBalanceDAI, balanceDAI);
        uint dropToBurn = rdiv(balanceSurplusDAI, dropPrice);

        mgr.exit(dropToBurn);
        drop.burn(self, dropToBurn); // TODO: fix impl
    }

    function rebalanceJunior() public {
        require(mgr.tab() == 0, "vault loan has to be paid back first");
        
        drip();
        uint profit = profit();
        require(profit > 0, "no profit to give to junior")
        
        uint expectedRevenue = sub(expectedRevenue, profit);
        updateSeniorValue(-profit);
    }


    // update revenue/losses of loans financed by the clerk
    function drip() public {
        expectedRevenue = rmul(expectedRevenue, tinlakeInterest());
    }
    
    function profit() public returns (uint) {
        drip();
        return safeSub(expectedRevenue - mgr.tab());
    }

    // returns the current rate for the accrued intrest on the DAI drawn from the vault
    function mkrInterest() public returns (uint) {
        // devide vault debt by principalDAI
        return safeDiv(mgr.tab(), pincipalDAI);
    }

    // returns the current senior rate for the accrued intrest on the DROP tokens locked in the vault
    function tinlakeInterest() public returns (uint) {
        return safeDiv(collateralAtWork, assessor.calcSeniorTokenPrice()), principalDAI);
    }
    
    // returns the weigthed price per DROP used as Collateral in the Vault
    function weightedDropPrice() public returns (uint) {
        return safeDiv(principalDAI, collateralAtWork);
    }

    function updateSeniorValue(int amount) internal  {
        uint redeem;
        uint supply;

        if (amount > 0) {
            redeem = 0;
            supply = amount;
        } else {
            redeem = amount;
            supply =  0;
        }

        uint currenNav = nav.currentNAV();
        uint newSeniorAsset = coordiator.calcSeniorAssetValue(redeem, supply,
            assessor.calcSeniorAssetValue(assessor.seniorDebt(), assessor.seniorBalance()), reserve.totalBalance(), currenNav);
        uint newSeniorRatio = coordinator.calcSeniorRatio(newSeniorAsset, currenNav, reserve.totalBalance());
        assessor.changeSeniorAsset(newSeniorRatio, supply, redeem);
    }
}
