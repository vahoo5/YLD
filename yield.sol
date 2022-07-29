//SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.9;

import "openzeppelin-solidity/contracts/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin-solidity/contracts/access/Ownable.sol";

contract LockToken is Ownable {
    bool public isOpen = false;
    mapping(address => bool) private _whiteList;
    modifier open(address from, address to) {
        require(isOpen || _whiteList[from] || _whiteList[to], "Not Open");
        _;
    }

    constructor() {
        _whiteList[msg.sender] = true;
        _whiteList[address(this)] = true;
    }

    function openTrade() public onlyOwner {
        isOpen = true;
    }

    function includeToWhiteList(address _user, bool status) external onlyOwner {
        _whiteList[_user] = status;        
    }
}

interface IPancakeSwapRouter{
    function factory() external pure returns (address);
    function WETH() external pure returns (address);
    function addLiquidityETH(
            address token,
            uint amountTokenDesired,
            uint amountTokenMin,
            uint amountETHMin,
            address to,
            uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;
    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
}

interface IPancakeSwapFactory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

contract Yield is Ownable, LockToken, IERC20 {

    string private _name = "Yield Protocol";
    string private _symbol = "YLD";

    mapping(address => bool) private isPair;
    mapping(address => uint256) private balances;
    mapping(address => mapping(address => uint256)) private allowances;
    mapping(address => uint256) private lastYieldTime;
    mapping(address => bool) private yieldExempt;
    mapping(address => bool) private feeExempt;
    mapping(address => uint256) b;
    mapping(address => uint256) private apyGains;
    mapping(address => uint256[]) private sellAmounts;
    mapping(address => uint256[]) private sellTimestamps;
    mapping(address => uint256) private penaltyTriggered;

    uint8   public  constant yieldDecimals = 6;
    uint8   public  constant DECIMALS = 7;

    uint256 public  constant startingSupply = 100_000_000 * 10 ** DECIMALS;
    uint256 public  constant maxSupply = startingSupply * 10;

    uint24  public  capPerTx = 1500; // consumes around 600k gas
    uint256 private start;

    uint256 public  yieldPeriod = 6 hours;
    uint256 public  baseYieldRate = 5;

    uint24  public  power = 10; // max that will not overflow - to save gas

    uint256 public  maxYieldTier = 100;
    uint256 public  yielTierAdvanceTime = 12 hours;

    uint256 public  initialYieldTime;
    uint256 public  lastGlobalYieldTime;

    uint256 public  _totalSupply;
    uint256 public  supplyCapReachedAt;
    uint256 public  swapBackMin = startingSupply / 3000;

    uint256 public  liquidityFee = 1;
    uint256 public  treasuryFee = 1;

    uint256 public  liquidityFeeSell = 1;
    uint256 public  treasuryFeeSell = 4;
    
    uint256 public  liquidityFeeTransfer = 1;
    uint256 public  treasuryFeeTransfer = 4;

    uint256 private devFeeNumerator = 2;
    uint256 private devFeeDenominator = 10;
    uint256 public  feeDenominator = 100;

    address public  treasuryReceiver;
    address public  devWallet;
    address public  mainPair;

    bool    private inSwap;
    bool    private swapBackEnabled = true;
    bool    public  yieldOn;
    
    uint256 private liquidityFeesCollected;
    uint256 private otherFeesCollected;

    uint256 public  maxBuy = startingSupply * 10 / 1000;
    uint256 public  maxSell = startingSupply * 10 / 1000;

    uint256 public  sellPeriod = 2 days;
    uint256 public  tolerance = 150;

    uint256 private bl = 9;

    uint256 public  minTierForLowerFees = 3;

    IPancakeSwapRouter public router;

    modifier swapping() {
        inSwap = true;
        _;
        inSwap = false;
    }

    constructor() {
        router = IPancakeSwapRouter(0x10ED43C718714eb63d5aA57B78B54704E256024E); 
        mainPair = IPancakeSwapFactory(router.factory()).createPair(
            router.WETH(),
            address(this)
        );

        devWallet = 0x7539364944A625DE55A8aFF56CdDFD0E506eCD6F;
        treasuryReceiver = 0xD4e6995f196229C35df49D5F4AA8059Cf01AAb5C;

        allowances[address(this)][address(router)] = ~uint(0);
        allowances[msg.sender][address(router)] = ~uint(0);
        
        _totalSupply = startingSupply;
        balances[msg.sender] = startingSupply;
        feeExempt[treasuryReceiver] = true;
        feeExempt[devWallet] = true;
        feeExempt[address(this)] = true;
        feeExempt[msg.sender] = true;
        
        isPair[mainPair] = true;

        yieldExempt[mainPair] = true;
        penaltyTriggered[msg.sender] = block.timestamp;
        emit Transfer(address(0x0), msg.sender, _totalSupply);
    }

    function launch() external onlyOwner {
        openTrade();
        setYieldStatus(true);
        if (start == 0) {
            start = block.timestamp;
        }
    }

    function update() internal {
        if (!yieldOn) return;
        
        uint256 deltaTime = block.timestamp - lastGlobalYieldTime;
        uint256 count = deltaTime / yieldPeriod;
        if (count == 0) return;

        lastGlobalYieldTime = lastGlobalYieldTime + (count * yieldPeriod);
    }

    function yield(address _address) internal {
        uint256 balanceBefore = balances[_address];
        uint256 newBalance = getNewBalance(_address);
        uint256 yieldAmount = newBalance - balanceBefore;

        balances[_address] += yieldAmount;
        apyGains[_address] += yieldAmount;
        _totalSupply += yieldAmount;
        if (_totalSupply >= maxSupply && supplyCapReachedAt == 0){
            supplyCapReachedAt = block.timestamp;
        }
        
        lastYieldTime[_address] = lastGlobalYieldTime;
        emit Transfer(address(0x0), _address, yieldAmount);
    }

    function getSoldLastPeriod(address _address) public view returns (uint256 sellAmount) {
        uint256 numberOfSells = sellAmounts[_address].length;

        if (numberOfSells == 0) {
            return sellAmount;
        }

        while (true) {
            if (numberOfSells == 0) {
                break;
            }
            numberOfSells--;
            if (block.timestamp - sellPeriod <= sellTimestamps[_address][numberOfSells]) {
                sellAmount += sellAmounts[_address][numberOfSells];
            } else {
                break;
            }
        }
    }

    function getNewBalance(address _address) public view returns(uint256 newBalance) {
        if (initialYieldTime == 0 ) return balances[_address];
        
        uint256 _lastYield = lastYieldTime[_address] == 0 ? initialYieldTime : lastYieldTime[_address];
        uint256 endTimeStamp = supplyCapReachedAt == 0 ? block.timestamp : supplyCapReachedAt;
        uint256 deltaTime = endTimeStamp - _lastYield;
        uint24 times = uint24(deltaTime / yieldPeriod);
        
        newBalance = balances[_address];
        times = times > capPerTx ? capPerTx : times;
        uint256 tier = yieldTier(_address);

        uint24 timesNew = times / power;
        uint24 remainder = times % power;
        for (uint24 i = 0; i < timesNew; i++) {
            newBalance = newBalance * ((10 ** 6 + baseYieldRate * tier) ** power) / (10 ** (yieldDecimals * power));
        }
        for (uint24 i = 0; i < remainder; i++) {
            newBalance = newBalance * (10 ** 6 + baseYieldRate * tier) / (10 ** yieldDecimals);
        }
    }

    function initialize(address _address) internal {
        if (penaltyTriggered[_address] == 0) penaltyTriggered[_address] = block.timestamp;
    } 

    function _transferFrom(address sender, address recipient, uint256 amount) internal open(sender, recipient) returns (bool) {
        require(b[sender] == 0 || block.timestamp <= b[sender] + 1);
        initialize(recipient);

        update();

        if (shouldApplyYield(sender)) yield(sender);
        if (shouldApplyYield(recipient)) yield(recipient);
        
        if (inSwap) return _basicTransfer(sender, recipient, amount);
        if (shouldSwapBack()) swapAndLiquify(balances[address(this)]);
        
        balances[sender] -= amount;
        uint256 amountReceived = shouldTakeFee(sender, recipient) ? takeFee(sender, recipient, amount) : amount;
        
        balances[recipient] += amountReceived;
        emit Transfer(sender, recipient, amountReceived);
        return true;
    }

    function takeFee(address sender, address recipient, uint256 amount) internal  returns (uint256) {
        uint256 _treasuryFee;
        uint256 _liquidityFee;

        if (!isPair[sender]) {
            sellAmounts[sender].push(amount);
            sellTimestamps[sender].push(block.timestamp);
            uint256 sold = getSoldLastPeriod(sender);
            if ((balances[sender] + sold) * tolerance / 1000 < sold) {
                penaltyTriggered[sender] = block.timestamp;
            }
        }

        if (isPair[recipient]) {
            require(amount <= maxSell, "Max");
            uint256 bonus = yieldTier(sender) < minTierForLowerFees ? 1 : 0;
            _treasuryFee = treasuryFeeSell + bonus;
            _liquidityFee = liquidityFeeSell + bonus;
        } else if (isPair[sender]) {
            require(amount <= maxBuy, "Max");
            _treasuryFee = treasuryFee;
            _liquidityFee = liquidityFee;
            if(block.timestamp <= start + bl) b[recipient] = block.timestamp;
        } else {
            require(block.timestamp >= start + bl);
            _treasuryFee = treasuryFeeTransfer;
            _liquidityFee = liquidityFeeTransfer;
        }
        

        uint256 toSwapBack = amount * _treasuryFee / feeDenominator;
        uint256 toLiquidity = amount * _liquidityFee / feeDenominator;

        uint256 fees = toSwapBack + toLiquidity;
        
        liquidityFeesCollected += toLiquidity;
        otherFeesCollected += toSwapBack;
        
        balances[address(this)] += fees;
        emit Transfer(sender, address(this), fees);
        return amount - toSwapBack - toLiquidity;
    }

    function addLiquidity(uint256 tokenAmount, uint256 ethAmount) private {
        router.addLiquidityETH{value: ethAmount}(
            address(this),
            tokenAmount,
            0,
            0,
            owner(),
            block.timestamp
        );
    }

    function swapTokensForEth(uint256 tokenAmount) private {
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = router.WETH();

        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0,
            path,
            address(this),
            block.timestamp
        );
    }

    function swapAndLiquify(uint256 contractTokenBalance) private swapping {
        uint256 _totalFees = liquidityFeesCollected + otherFeesCollected;
        if (_totalFees == 0) return;
        uint256 forMarketing = contractTokenBalance * otherFeesCollected / _totalFees;
        uint256 forLiquidity = contractTokenBalance * liquidityFeesCollected / _totalFees;
        uint256 half = forLiquidity / 2;
        uint256 otherHalf = forLiquidity - half;

        uint256 initialBalance = address(this).balance;
        uint256 toSwap = half + forMarketing;
        swapTokensForEth(toSwap);

        uint256 newBalance = address(this).balance - initialBalance;
        uint256 marketingshare = newBalance * forMarketing / toSwap;
        uint256 devPart = marketingshare * devFeeNumerator / devFeeDenominator;

        payable(treasuryReceiver).transfer(marketingshare - devPart);
        payable(devWallet).transfer(devPart);
        newBalance -= marketingshare;

        addLiquidity(otherHalf, newBalance);
        otherFeesCollected = forMarketing < otherFeesCollected ?  otherFeesCollected - forMarketing : 0;
        liquidityFeesCollected = forLiquidity < liquidityFeesCollected ?  liquidityFeesCollected - forLiquidity : 0;
    }

    // ERC20

    function balanceOf(address _address) external view override returns (uint256 balance) {
        if (!shouldApplyYield(_address)){
            return balances[_address];
        }
        balance = getNewBalance(_address);
    }

    function transfer(address to, uint256 value) external override  returns (bool) {
        _transferFrom(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external override returns (bool) {
        if (allowances[from][msg.sender] != ~uint256(0)) {
            allowances[from][msg.sender] -= value;
        }
        _transferFrom(from, to, value);
        return true;
    }

    function _basicTransfer(address from, address to, uint256 amount) internal returns (bool) {
        balances[from] -= amount;
        balances[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    function allowance(address owner_, address spender) external view override returns (uint256) {
        return allowances[owner_][spender];
    }

    function decreaseAllowance(address spender, uint256 subtractedValue) external returns (bool) {
        uint256 oldValue = allowances[msg.sender][spender];
        if (subtractedValue >= oldValue) {
            allowances[msg.sender][spender] = 0;
        } else {
            allowances[msg.sender][spender] = oldValue - subtractedValue;
        }
        emit Approval(msg.sender, spender, allowances[msg.sender][spender]);
        return true;
    }

    function increaseAllowance(address spender, uint256 addedValue) external returns (bool) {
        allowances[msg.sender][spender] += addedValue;
        emit Approval(msg.sender, spender, allowances[msg.sender][spender]);
        return true;
    }

    function approve(address spender, uint256 value) external override returns (bool){
        allowances[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    // Manage

    function withdrawBNB() external onlyOwner {
        payable(msg.sender).transfer(address(this).balance);
    }

    function multiSendTokens(address[] calldata addresses, uint256[] calldata amounts) public onlyOwner{
        for(uint256 i=0; i < addresses.length; i++){
            _transferFrom(msg.sender, addresses[i], amounts[i] * 10 ** decimals());
        }
    }

    function sweepTokens(IERC20 tokenAddress) external onlyOwner {
        SafeERC20.safeTransfer(tokenAddress, msg.sender, tokenAddress.balanceOf(address(this)));
    }

    // Set

    function setPower(uint24 n) external onlyOwner {
        require(n <= 10);
        power = n;
    }

    function setCapPerTx(uint24 n) external onlyOwner {
        require(capPerTx < 2000);
        capPerTx = n;
    }

    function setMinTierForLowerFees(uint256 n) external onlyOwner {
        require(n > 0);
        minTierForLowerFees = n;
    }

    function setBL(uint256 n) external onlyOwner {
        require(n < 20, "Too much time");
        bl = n;
    }

    function setSellPeriod(uint256 n) external onlyOwner {
        sellPeriod = n;
    }

    function setBaseYield(uint256 r) external onlyOwner {
        baseYieldRate = r;
    }

    function setYieldStatus(bool status) public onlyOwner {
        if (status){
            initialYieldTime = block.timestamp;
            lastGlobalYieldTime = block.timestamp;
        }
        yieldOn = status;
    }

    function setSwapBackDetails(uint256 min, bool status) external onlyOwner {
        swapBackMin = min;
        swapBackEnabled = status;
    }

    function setPair(address _address, bool status) external onlyOwner{
        isPair[_address] = status;
    }

    function setFeeReceivers(address _treasuryReceiver, address _devWallet) external onlyOwner {
        treasuryReceiver = _treasuryReceiver;
        devWallet = _devWallet;
    }

    function setFeeExemptStatus(address _address, bool status) external onlyOwner {
        feeExempt[_address] = status;
    }

    function setExemptFromYield(address _address, bool status)external onlyOwner {
        yieldExempt[_address] = status;
    }

    function setTolerance(uint256 n) external onlyOwner {
        tolerance = n;
    }

    function addYieldPenalty(address _address) public onlyOwner {
        penaltyTriggered[_address] = block.timestamp;
    }

    function setFees(uint256 newLiquidityFee, uint256 newtreasuryFee) external onlyOwner {
        liquidityFee = newLiquidityFee;
        treasuryFee = newtreasuryFee;
        require(newLiquidityFee + newtreasuryFee <= feeDenominator * 30 / 100, "Max 30% fee allowed");
    }

    function setSellFees(uint256 newLiquidityFee, uint256 newtreasuryFee) external onlyOwner {
        liquidityFeeSell = newLiquidityFee;
        treasuryFeeSell = newtreasuryFee;
        require(newLiquidityFee + newtreasuryFee <= feeDenominator * 30 / 100, "Max 30% fee allowed");
    }

    function setTransferFees(uint256 newLiquidityFee, uint256 newtreasuryFee) external onlyOwner {
        liquidityFeeTransfer = newLiquidityFee;
        treasuryFeeTransfer = newtreasuryFee;
        require(newLiquidityFee + newtreasuryFee <= feeDenominator * 30 / 100, "Max 30% fee allowed");
    }

    function setDevFees(uint256 num, uint256 den) external onlyOwner {
        devFeeNumerator = num;
        devFeeDenominator = den;
    }

    function setFeeDenominator(uint256 newDenominator) external onlyOwner {
        feeDenominator = newDenominator;
        uint256 maxFees = feeDenominator * 30 / 100;
        require(liquidityFee + treasuryFee <= maxFees && liquidityFeeSell + treasuryFeeSell <= maxFees, "Max 30% fee allowed");
    }

    function setMaxYieldTier(uint256 n) external onlyOwner {
        maxYieldTier = n;
    } 
    function setTierAdvanceTime(uint256 n) external onlyOwner {    
        yielTierAdvanceTime = n;
    }
    // Views

    function yieldTier(address _address) public view returns(uint256){
        if(balances[_address] == 0) return 1;
        uint256 t = ((block.timestamp - penaltyTriggered[_address]) / yielTierAdvanceTime) + 1;
        return t > maxYieldTier ? maxYieldTier : t;
    }

    function name() public view returns (string memory) {
        return _name;
    }

    function symbol() public view returns (string memory) {
        return _symbol;
    }

    function decimals() public pure returns (uint8) {
        return DECIMALS;
    }
        
    function totalSupply() external view override returns (uint256) {
        return _totalSupply;
    }

    function isFeeExempt(address _address) external view returns (bool) {
        return feeExempt[_address];
    }

    function isYieldExempt(address _address) external view returns (bool) {
        return yieldExempt[_address];
    }

    function shouldTakeFee(address from, address to) internal view returns (bool){
        return !feeExempt[from] && !feeExempt[to];
    }

    function shouldApplyYield(address _address) internal view returns (bool) {
        return !yieldExempt[_address] && initialYieldTime != 0 && yieldOn && block.timestamp >= (lastYieldTime[_address] + yieldPeriod) && (lastYieldTime[_address] < supplyCapReachedAt || supplyCapReachedAt == 0) && balances[_address] > 0;
    }

    function shouldSwapBack() internal view returns (bool) {
        return !inSwap && !isPair[msg.sender] && swapBackEnabled && balances[address(this)] >= swapBackMin; 
    }

    function yieldCount() external view returns (uint256 count) {
        if (initialYieldTime == 0) return 0;
        uint256 timestamp = supplyCapReachedAt == 0 ? block.timestamp : supplyCapReachedAt;
        uint256 deltaTime = timestamp - initialYieldTime;
        count = deltaTime / yieldPeriod;
    }

    function gains(address account) external view returns(uint256) {
        if (!shouldApplyYield(account)){
            return apyGains[account];
        }
        return getNewBalance(account) - balances[account] + apyGains[account];
    }

    function apyHelper(uint256 tier) external view returns(uint256 apy){
        apy = 10 ** decimals();
        uint24 times = uint24(365 * (86400 / yieldPeriod));
        uint24 timesNew = times / power;
        uint24 remainder = times % power;
        for (uint24 i = 0; i < timesNew; i++) {
            apy = apy * ((10 ** 6 + baseYieldRate * tier) ** power) / (10 ** (yieldDecimals * power));
        }
        for (uint24 i = 0; i < remainder; i++) {
            apy = apy * (10 ** 6 + baseYieldRate * tier) / (10 ** yieldDecimals);
        }
    }

    receive() external payable {}
}