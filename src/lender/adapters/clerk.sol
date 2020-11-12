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
   
    // virtual DAI balance that was already added to the seniorAssetValue = virtual DAI balance
    uint public balanceDAI;
    // DROP that are used as collatreal for already drawn DAI
    uint public collateralAtWork;
    // Profit from the DROP interest accruel that can be trasferred to the junior tranche
    uint profitJunior; // I don't even think we need to track this value. It is bascially the DAI balance of the contract

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
        validate(amountDAI);
        // increase balanceDAI, so that the amount can be drawn
        balanceDAI = safeAdd(balanceDAI, amountDAI);
        // increase seniorAssetValue by amountDAI to keep the DROP token price constant 
        updateSeniorValue(amountDAI);
        
        // mint amountDROP & lock in vault
        tranche.mint(address(this), amountDROP);
        mgr.join(amountDROP);
    }

    function draw(uint amountDAI) public auth {
        // TODO: maybe find a better condition
        require(reserve.totalBalance() == 0, "Use DAI in reserve first");
        // make sure amountDAI does not exceed the virtual DAI balance
        require(safeAdd(mgr.tab(), amountDAI) <= balanceDAI, "Add amount to senior asset first");

        collateralAtWork = safeAdd(collateralAtWork, rdiv(amountDAI, assessor.calcSeniorTokenPrice()));

        // draw dai and move to reserve
        mgr.draw(amountDAI);
        dai.approve(address(reserve), amountDAI);
        reserve.deposit(amountDAI);
    }

   
    function wipe(uint amountDAI) public auth {
        // I think we need to use this condition here instead: require(mgr.tab() > 0, "vault debt already repaid");
        require(collateralAtWork > 0, "no collateralAtWork left");
        uint amountDROP = rdiv(amountDAI, assessor.calcSeniorTokenPrice());
        require(collateralAtWork >= amountDROP, "DAI amount too high");

        collateralAtWork = safeSub(collateralAtWork, amountDROP);
        // payVault should be max debtVault, the rest goes towards junior profit
        uint payVault = amountDAI;
        if (amountDAI > mgr.tab()) {
            payVault = mgr.tab();
            profitJunior = safeAdd(safeSub(amountDAI, mgr.tab()));
        }

        require(reserve.payout(amountDAI), "not enough funds in reserve");
        mgr.wipe(payVault);
        // todo: we could call rebalance junior here if profitJunior > 0
    }

     // remove drop from mkr system
    function exit(uint amountDROP) public auth {
        require(mgr.tab() == 0, "vault debt has to be repaid first");
        uint amountDAI = rmul(amountDROP, assessor.calcSeniorTokenPrice());
        require(amountDAI <= balanceDAI, "DROP amount too high");

        balanceDAI = safeSub(balanceDAI, amountDAI);
        updateSeniorValue(-amountDAI);
        mgr.exit(amountDROP);
        drop.burn(address(this), amountDROP); // TODO: fix impl
    }

    function rebalanceJunior() public {
        require(mgr.tab() == 0, "vault loan has to be paid back first");
        require(profitJunior > 0, "no profit to give to junior")

        // transfer entire junior profit if possible 
        uint payJunior = profitJunior;
        if (dai.balanceOf(address(this)) < profitJunior) {
            payJunior = dai.balanceOf(address(this));
        }

        uint profitJunior = safeSub(profitJunior, payJunior);
        updateSeniorValue(-payJunior);
    }

    // principal + DAI value of collateral that is not put to work should not exceed balanceDAI => blanceDAI is constant
    // balanceDAI =  mgr.tab() + (mgr.ink() - collateralAtWork) * senior.calcSeniorTokenPrice()
    // burn DROP tokens worth of accrued tinlake interest to prevent senior dilution
    function rebalanceSenior() public {
        // todo: discuss if it should be allowed to burn if mgr.debt() > balance, but there is still unused collateral
        uint priceDROP = senior.calcSeniorTokenPrice()

        // max unused DROP amount considering current drop price
        unusedCollateralGoal;
        if (balanceDAI > mgr.tab()) {
            unusedCollateralGoal = rdiv(safeSub(balanceDAI, mgr.tab()), priceDROP);
        }
        uint burnAmount = safeSub(safeSub(mgr.ink(), collateralAtWork), unusedCollateralGoal); // TODO: fix mgr.ink
    
        mgr.exit(burnAmount);
        drop.burn(address(this), burnAmount); // TODO: fix impl
    }

    // TODO: implement
    function validate() internal {
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
