pragma solidity >=0.5.15. <0.6.0;


import "tinlake-auth/auth.sol";
import "tinlake-math/math.sol";

interface ManagerLike {
    // collateral value locked in the vault
    function ink() external returns(uint);
    // collateral debt 
    function tab() external returns(uint);
    // 1 - collateralization buffer 
    function mat() external returns(uint);
    // put collateral into vault
    function join(uint amountDROP) external;
    // draw DAi from vault
    function draw(uint amountDAI) external;
    // repay vault debt
    function wipe(uint amountDAI) external;
    // remove collateral from vault
    function exit(uint amountDROP) external;
}

interface AssessorLike {
    function calcSeniorTokenPrice() external view returns(uint);
    function calcSeniorAssetValue(uint seniorDebt, uint seniorBalance) external pure returns(uint);
    function changeSeniorAsset(uint seniorRatio, uint seniorSupply, uint seniorRedeem) external;
    function seniorDebt() external returns(uint);
    function seniorBalance() external returns(uint);
}

interface CoordinatorLike {
    function calcSeniorAssetValue(uint seniorRedeem, uint seniorSupply, uint currSeniorAsset, uint reserve_, uint nav_) external pure returns(uint) ;
    function calcSeniorRatio(uint seniorAsset, uint NAV, uint reserve_) external pure returns(uint);
    function validate(uint seniorRedeem, uint juniorRedeem, uint seniorSupply, uint juniorSupply) external view returns(int);
    function submissionPeriod() external returns(bool);
}

interface ReserveLike {
    function totalBalance() external view returns(uint);
    function deposit(uint daiAmount) external;
    function payout(uint currencyAmount) external;
}

interface NAVFeedLike {
    function currentNAV() external view returns(uint);
}

interface TrancheLike {
    function mint(address usr, uint amount) external;
    function token() external returns(address);
}

interface ERC20Like {
    function burn(address, uint) external;
    function balanceOf(address) external view returns (uint);
    function transferFrom(address, address, uint) external returns (bool);
    function approve(address usr, uint amount) external;
}

  
contract Clerk is Auth, Math {
   
    // max amount of DAI that can be brawn from MKR
    uint public creditLine;
    // remaing amount of DAI that can be brrowed from MKR
    uint creditLeft;

    AssessorLike assessor;
    CoordinatorLike coordinator;
    ReserveLike reserve;
    NAVFeedLike nav;
    TrancheLike tranche;
    ManagerLike mgr;
    ERC20Like dai;
    ERC20Like collateral;

    // adapter function scan only be active if the tinlake pool is not in submission state
    modifier active() { (coordinator.submissionPeriod() == false); _; }

    constructor(address mgr_, address dai_, address assessor_, address coordinator_, address reserve_, address nav_, address tranche_) {
        wards[msg.sender] = 1;

        mgr =  ManagerLike(mgr);
        assessor = AssessorLike(assessor_);
        coordinator = CoordinatorLike(coordinator_);
        reserve = ReserveLike(reserve_);
        nav = NAVFeedLike(nav_);
        tranche = TrancheLike(tranche_);
        collateral = ERC20Like(tranche.token());
        dai =  ERC20Like(dai_);
    }

    // increase MKR creadit line by amountDAI
    function raise(uint amountDAI) public auth active {
        // add extra collateral buffer on top of DAI amount
        amountDAIBuffered = rdiv(amountDAI, mgr.mat());
        // calculate DROP amount considering current DROP token price
        uint amountDROP = rdiv(amountDAIBuffered, assessor.calcSeniorTokenPrice());
        // check if the new creditline would break the pool constraints
        validate(amountDAIBuffered);
        // increase MKR crediline by amountDAI
        creditLine = safeAdd(creditLine, amountDAI);
        remainingCredit = safeAdd(remainingCredit, amountDAI);
        // increase seniorAssetValue by amountDAIBufferedto keep the DROP token price constant 
        updateSeniorValue(int(amountDAIBuffered));
        // mint amountDROP & store in clerk
        tranche.mint(address(this), amountDROP);
    }

    // join collateral & draw DAI from vault
    function draw(uint amountDAI) public auth active {
        // make sure amountDAI and vault debt do not exceed the credit line normalized by the collateral buffer ratio
        require(safeAdd(mgr.tab(), amountDAI) <= rmul(creditLine, mgr.mat()), "rise credit line first");
    
        // compute collateral amount required to draw the DAI
        // collateral buffer needs to be added to the DAI amount
        uint requiredCollateral = rdiv(safeDiv(amountDAI, mgr.mat()), assessor.calcSeniorTokenPrice());

        // theoretically not possible, that clerk has not enough collateral as it would require the drop price to decrease
        // which would already trigger soft liquidation by the manager
        // so condition was only added to catch possible rounding errors 
        require((collateral.balanceOf(address(this)) >= requiredCollateral), "clerk does not have enough collateral");

        // put collateral into the vault
        mgr.join(requiredCollateral);
        // draw dai and move to reserve
        mgr.draw(amountDAI);
        dai.approve(address(reserve), amountDAI);
        reserve.deposit(amountDAI);
    }

    // repay vault debt 
    function wipe(uint amountDAI) public auth active {
        require((mgr.tab() > 0), "vault debt already repqaid");

        uint payVault = amountDAI;
        // repay max vault debt
        if (amountDAI > mgr.tab()) {
            payVault = mgr.tab();
        }

        // drop amount to wipe including the collateral buffer 
        uint amountDROP = rdiv(rdiv(payVault, assessor.calcSeniorTokenPrice()), mgr.mat());
        // transfer DAI from reserve and wipe the vault debt
        reserve.payout(payVault);
        mgr.wipe(payVault); 
        // remove collateral for the repaid drop amount
        mgr.exit(amountDROP); // todo: if we store collateralAtWork variable, we can call exit only once in harvest
        // call harvest to grant profits to junior
        harvest();        
    }

    // give profit to junior tranche
    function harvest() public active {
        require((mgr.ink() > 0), "no profit to harvest");

        // calc normalized collateral value dinomintaed in DAI
        uint amountDAI = rmul(rmul(mgr.ink(), assessor.calcSeniorTokenPrice()), mgr.mat());
        // substract remaining vault debt inclusing collateral buffer from the collateral value in the vault denomintaed in DAI
        uint profit = safeSub(amountDAI, mgr.tab());
        // move profit towards junior tranche
        updateSeniorValue(int(-profit));
        // remove collateral from the vault that has already been moved to junior
        mgr.exit(rdiv(profit, assessor.calcSeniorTokenPrice()));
    }

    // decrease Maker credit Line by burning the drop and decreasing the SeniorAssetValue
    function sink(uint amountDROP) public auth active {
        require(mgr.tab() == 0);
        // make sure senior is rebalanced
        rebalance();
        // calc amount that the creditline should be decreased by
        uint amountDAI = rmul(amountDROP, assessor.calcSeniorTokenPrice());
        require(amountDAI <= creditLine, "DROP amount too high");

        creditLine = safeSub(creditLine, amountDAI);
        updateSeniorValue(int(-amountDAI));
        collateral.burn(address(this), amountDROP); // TODO: fix impl
    }

    // prevent senior dilution by burning DROP worth the accrued interest of unused collateral
    function rebalance() public active {
        // remaining DAI value incl. collateralization ratio that still can be drawn
        uint remainingBalance = 0;
        // vault debt normalized by the extra collateralization ratio
        uint tabNorm = rdiv(mgr.tab(), mgr.mat());
        if (creditLine > tabNorm) {
             remainingBalance = safeSub(creditLine, tabNorm);
        }
        // burnamount = difference between drop held by clerk and the collateral required to cover the remaining balance
        uint burnAmount = safeDiv(collateral.balanceOf(address(this)), rdiv(remainingBalance, assessor.calcSeniorTokenPrice()));
        collateral.burn(address(this), burnAmount); 
    }

    // checks if the Maker credit line increase could violate the pool constraints
    function validate(uint amountDAI) internal {
        require((coordinator.validate(0, 0, amountDAI, 0) == 0), "supply not possible, pool constraints violated");
    }
    
    function updateSeniorValue(int amount) internal  {
        uint redeem;
        uint supply;

        if (amount > 0) {
            redeem = 0;
            supply = uint(amount);
        } else {
            redeem = uint(amount*-1);
            supply =  0;
        }

        uint currenNav = nav.currentNAV();
        uint newSeniorAsset = coordinator.calcSeniorAssetValue(redeem, supply,
            assessor.calcSeniorAssetValue(assessor.seniorDebt(), assessor.seniorBalance()), reserve.totalBalance(), currenNav);
        uint newSeniorRatio = coordinator.calcSeniorRatio(newSeniorAsset, currenNav, reserve.totalBalance());
        assessor.changeSeniorAsset(newSeniorRatio, supply, redeem);
    }

    function juniorProfit() public view returns(uint) {

    }

    function seniorProfit() public view returns(uint) {
   
    }
