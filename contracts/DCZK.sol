/// DCZK.sol -- dCZK Decentralized Stablecoin

pragma solidity ^0.5.16;

contract IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

contract Vat {
    function hope(address) external;
}

contract DaiJoin {
    function join(address, uint) external;
    function exit(address, uint) external;
}

contract Pot {
    function chi() external view returns (uint256);
    function rho() external view returns (uint256);
    function dsr() external view returns (uint256);
    function pie(address) external view returns (uint256);
    function drip() external returns (uint256);
    function join(uint256) external;
    function exit(uint256) external;
}

contract UniswapFactoryInterface {
    function getExchange(address token) external view returns (address exchange);
}

contract UniswapExchangeInterface {
    function getEthToTokenInputPrice(uint256 eth_sold) external view returns (uint256 tokens_bought);
    function ethToTokenSwapInput(uint256 min_tokens, uint256 deadline) external payable returns (uint256  tokens_bought);
    function tokenToEthTransferInput(uint256 tokens_sold, uint256 min_eth, uint256 deadline, address recipient) external returns (uint256  eth_bought);
}

contract IOracle {
    function value() external view returns (uint256);
}

contract DCZK is IERC20 {

    // --- ERC20 Events ---
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // --- Other events ---
    event TransferPrincipal(address indexed from, address indexed to, uint256 principal, uint256 value);
    event Mint(address indexed to, uint256 amount, uint256 principal);
    event Burn(address indexed burner, uint256 amount, uint256 principal);
    event Buy(address indexed buyer, uint256 dczk, uint256 dai);
    event Sell(address indexed seller, uint256 dczk, uint256 dai);
    event AddLiquidity(uint256 rate, uint256 amount);
    event BuyWithEther(address indexed buyer, uint256 dczk, uint256 dai, uint256 eth);
    event SellForEther(address indexed seller, uint256 dczk, uint256 dai, uint256 eth);
    event Cast(uint8 key, bytes32 val);

    // --- ERC20 basic vars ---
    string public constant name     = "dCZK Test v0.3";
    string public constant symbol   = "dCZK03";
    uint8  public constant decimals = 18;
    mapping (address => uint256)private _balances;
    mapping (address => mapping (address => uint256)) private _allowances;
    uint256 private _totalSupply;

    // --- DAO access ---
    address public dao;

    // --- DAO governed parameters ---
    address public oracle;    // oracle contract address
    uint256 public cap;       // maximal supply
    uint256 public fee;       // buy() fee
    address public unifa;     // uniswap factory contract
    uint256 public unisl;     // uniswap slippage
    uint256 public unidl;     // uniswap deadline

    // --- Maker DAI ---
    IERC20  public dai;

    // --- DEX ---
    uint256 public maxRate;
    uint256 public volume;
    struct Thread {
        uint next;
        uint amount;
    }
    mapping(uint => Thread) public txs;

    // --- Maker DSR ---
    Vat     public vat;
    DaiJoin public daiJoin;
    Pot     public pot;

    // --- Local savings rate ---
    uint256 public lrho;
    uint256 public lchi;

    // --- Uniswap ---
    UniswapFactoryInterface  public uniswapFactory;
    UniswapExchangeInterface public daiExchange;


    // --- Init ---
    constructor (address _oracle) public {
        
        // core
        dai = IERC20(0x4F96Fe3b7A6Cf9725f59d353F723c1bDb64CA6Aa);
        dao = 0x89188bE35B16AF852dC0A4a9e47e0cA871fadf9a;

        // default dao controlled parameters
        oracle = _oracle;
        cap    = 1000000000000000000000000;
        fee    = 400;           // 0.25%
        unifa  = 0xD3E51Ef092B2845f10401a0159B2B96e8B6c3D30;
        unisl  = 40;            // uniswap slippage - 2.5%
        unidl  = 900 * 60;      // uniswap deadline - 15 minutes

        // DSR - DAI Savings Rate
        daiJoin = DaiJoin(0x5AA71a3ae1C0bd6ac27A1f28e1415fFFB6F15B8c);
        vat = Vat(0xbA987bDB501d131f766fEe8180Da5d81b34b69d9);
        pot = Pot(0xEA190DBDC7adF265260ec4dA6e9675Fd4f5A78bb);

        vat.hope(address(daiJoin));
        vat.hope(address(pot));

        // Uniswap
        uniswapFactory = UniswapFactoryInterface(unifa);
        daiExchange = UniswapExchangeInterface(uniswapFactory.getExchange(address(dai)));

        dai.approve(address(daiJoin), uint256(-1));

        // first drip
        _drip();
    }

    // --- Math ---
    // Taken from official DSR contract:
    // https://github.com/makerdao/dss/blob/master/src/pot.sol

    uint constant RAY = 10 ** 27;
    function rpow(uint x, uint n, uint base) internal pure returns (uint z) {
        assembly {
            switch x case 0 {switch n case 0 {z := base} default {z := 0}}
            default {
                switch mod(n, 2) case 0 { z := base } default { z := x }
                let half := div(base, 2)  // for rounding.
                for { n := div(n, 2) } n { n := div(n,2) } { // solium-disable-line
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

    function add(uint x, uint y) internal pure returns (uint z) {
        require((z = x + y) >= x);
    }

    function sub(uint x, uint y) internal pure returns (uint z) {
        return sub(x, y, "SafeMath: subtraction overflow");
    }

    function sub(uint x, uint y, string memory err) internal pure returns (uint z) {
        require((z = x - y) <= x, err);
    }

    function mul(uint x, uint y) internal pure returns (uint z) {
        require(y == 0 || (z = x * y) / y == x);
    }

    function rmul(uint x, uint y) internal pure returns (uint z) {
        // always rounds down
        z = mul(x, y) / RAY;
    }

    function rdiv(uint x, uint y) internal pure returns (uint z) {
        // always rounds down
        z = mul(x, RAY) / y;
    }

    function rdivup(uint x, uint y) internal pure returns (uint z) {
        // always rounds up
        z = add(mul(x, RAY), sub(y, 1)) / y;
    }

    // --- ERC20 Token ---

    function totalSupply() public view returns (uint256) {
        return rmul(_chi(), _totalSupply);
    }

    function balanceOf(address account) public view returns (uint) {
        return rmul(_chi(), _balances[account]);
    }

    function transfer(address recipient, uint256 amount) public returns (bool) {
        _transfer(msg.sender, recipient, amount);
        return true;
    }

    function allowance(address owner, address spender) public view returns (uint256) {
        return _allowances[owner][spender];
    }

    function approve(address spender, uint256 amount) public returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) public returns (bool) {
        _transfer(sender, recipient, amount);
        _approve(sender, msg.sender, sub(_allowances[sender][msg.sender], amount, "ERC20: transfer amount exceeds allowance"));
        return true;
    }

    function increaseAllowance(address spender, uint256 addedValue) public returns (bool) {
        _approve(msg.sender, spender, add(_allowances[msg.sender][spender], addedValue));
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue) public returns (bool) {
        _approve(msg.sender, spender, sub(_allowances[msg.sender][spender], subtractedValue, "ERC20: decreased allowance below zero"));
        return true;
    }

    function _transfer(address sender, address recipient, uint256 amount) private {
        require(sender != address(0), "ERC20: transfer from the zero address");
        require(recipient != address(0), "ERC20: transfer to the zero address");

        uint pie = rdiv(amount, _chi());

        _balances[sender] = sub(_balances[sender], pie, "ERC20: transfer amount exceeds balance");
        _balances[recipient] = add(_balances[recipient], pie);

        emit Transfer(sender, recipient, amount);
        emit TransferPrincipal(sender, recipient, pie, amount);
    }

    function _approve(address owner, address spender, uint256 amount) private {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _allowances[owner][spender] = amount;
        emit Approval(owner, spender, amount);
    }

    // --- Principal balances ---

    function principalBalanceOf(address account) public view returns (uint) {
        return _balances[account];
    }

    function principalTotalSupply() public view returns (uint256) {
        return _totalSupply;
    }

    // --- DSR (DAI Savings rate) integration ---

    function _chi() internal view returns (uint) {
        return rmul(rpow(pot.dsr(), now - pot.rho(), RAY), pot.chi());
    }

    function _drip() internal {
        require(now >= lrho, "dczk/invalid-now");
        uint tmp = _chi();
        uint chi_ = sub(tmp, lchi);
        lchi = tmp;
        lrho = now;
        uint amount = rmul(chi_, principalPotSupply());
        if (amount > 0) {
          _addLiquidity(amount);
          emit AddLiquidity(rate(), amount);
        }
    }

    function potDrip() public view returns (uint) {
        return rmul(sub(_chi(), lchi), principalPotSupply());
    }

    function potSupply() public view returns (uint256) {
        return rmul(_chi(), pot.pie(address(this)));
    }

    function principalPotSupply() public view returns (uint256) {
        return pot.pie(address(this));
    }

    // --- Minting and burning (internal) ---

    function _mint(address dst, uint256 czk, uint256 _dai) private {
        require(dst != address(0), "ERC20: mint to the zero address");
        
        uint256 chi = (now > pot.rho()) ? pot.drip() : pot.chi();

        uint pie = rdiv(_dai, chi);
        daiJoin.join(address(this), _dai);
        pot.join(pie);
        uint spie = rdiv(czk, chi);

        _totalSupply = add(_totalSupply, spie);
        _balances[dst] = add(_balances[dst], spie);

        require(rmul(chi, _totalSupply) <= cap, "dczk/cap-reached");

        emit Transfer(address(0), dst, czk);
        emit TransferPrincipal(address(0), dst, spie, czk);
        emit Mint(dst, czk, spie);
    }

    function _burn(address src, uint256 czk, uint256 _dai, address dst) private {
        require(src != address(0), "ERC20: burn from the zero address");
        require(balanceOf(src) >= czk, "dczk/insufficient-balance");

        uint chi = (now > pot.rho()) ? pot.drip() : pot.chi();
        uint spie = rdivup(czk, chi);

        _balances[src] = sub(_balances[src], spie, "ERC20: burn amount exceeds balance");
        _totalSupply = sub(_totalSupply, spie);
        emit Transfer(src, address(0), czk);
        emit Burn(src, czk, spie);

        uint pie = rdivup(_dai, chi);
        if (pie != 0) {
            pot.exit(pie);
            daiJoin.exit(dst, rmul(chi, pie));
        }
        if (dst != address(this)) {
            _approve(src, dst, sub(_allowances[src][address(this)], czk, "ERC20: burn amount exceeds allowance"));
        }
        emit TransferPrincipal(src, address(0), spie, czk);
    }

    // --- DEX Decentralized exchange ---

    function _addLiquidity(uint256 amount) internal {
        uint256 _rate = rate();
        if (txs[_rate].amount == 0 && maxRate != 0) {
            uint currentRate = maxRate;
            uint prevRate = 0;
            while (currentRate >= _rate){
                prevRate = currentRate;
                if (txs[currentRate].next != 0) {
                    currentRate = txs[currentRate].next;
                } else {
                    currentRate = 0;
                }
            }
            if (currentRate != _rate) {
                if (prevRate == 0) {
                    txs[_rate].next = maxRate;
                    maxRate = _rate;
                } else {
                    txs[prevRate].next = _rate;
                    txs[_rate].next = currentRate;
                }
            }
        }
        if (maxRate < _rate) {
            maxRate = _rate;
        }
        txs[_rate].amount += amount;
    }

    function _buyAndMint(uint256 amount) private returns(uint256 converted) {
        require(rate() != 0, "rate cannot be 0");

        // calculate fee - 0.25%
        uint _fee = amount / fee;
        uint rest = amount - _fee;
        // TODO - do something with the fee - now its freezed on contract forever

        // add liquidity to dex
        _addLiquidity(rest);

        // convert to stablecoin amount
        converted = (rest * rate()) / 10 ** 18;

        // save amount to total volume
        volume += converted;

        // mint tokens
        _mint(address(msg.sender), converted, rest);

        emit Buy(msg.sender, converted, rest);
    }

    function _sell(uint256 amount) private returns(uint256 deposit) {
        require(maxRate != 0, "max_rate cannot be 0");
        require(allowance(msg.sender, address(this)) >= amount, "czk/insufficient-allowance");
        _drip();

        // update total volume
        volume += amount;

        // calculate rate & deposit
        uint _amount = amount;
        deposit = 0;
        uint currentRate = maxRate;
        while (_amount > 0) {
            uint full = (txs[currentRate].amount * currentRate) / 10 ** 18;
            if (full > _amount) {
                uint partialAmount = _amount * 10 ** 18 / currentRate;
                txs[currentRate].amount -= partialAmount;
                deposit += partialAmount;
                _amount = 0;
            } else {
                _amount -= full;
                deposit += txs[currentRate].amount;
                txs[currentRate].amount = 0;
                maxRate = txs[currentRate].next;
            }
            if (txs[currentRate].next != 0) {
                currentRate = txs[currentRate].next;
            }
        }
        emit Sell(msg.sender, amount, deposit);
    }

    function getThreads() public view returns(uint[] memory rates, uint[] memory amounts) {
        uint len = 0;
        if (maxRate != 0) {
            len += 1;
            uint currentRate = maxRate;
            while (txs[currentRate].next != 0) {
                len += 1;
                currentRate = txs[currentRate].next;
            }
            currentRate = maxRate;
            rates = new uint[](len);
            amounts = new uint[](len);
            amounts[0] = txs[currentRate].amount;
            rates[0] = currentRate;
            len = 0;
            while (txs[currentRate].next != 0 && len > 9) {
                len += 1;
                currentRate = txs[currentRate].next;
                rates[len] = currentRate;
                amounts[len] = txs[currentRate].amount;
            }
        }
    }

    function buy(uint256 amount) external {
        require(dai.allowance(msg.sender, address(this)) >= amount, "dczk/insufficient-allowance");
        dai.transferFrom(msg.sender, address(this), amount);
        _buyAndMint(amount);
    }

    function sell(uint256 amount) external {
        uint256 deposit = _sell(amount);
        _burn(msg.sender, amount, deposit, msg.sender);
    }

    // --- Uniswap Integration ---

    function buyWithEther(uint256 minTokens) external payable returns(uint256 converted) {
        uint256 deposit = daiExchange.ethToTokenSwapInput.value(msg.value)(minTokens, now + unidl);
        converted = _buyAndMint(deposit);
        emit BuyWithEther(msg.sender, converted, deposit, uint256(msg.value));
    }

    function sellForEther(uint256 amount, uint256 minEth) external returns(uint256 eth) {
        uint256 deposit = _sell(amount);
        _burn(msg.sender, amount, deposit, address(this));
        dai.approve(address(daiExchange), deposit);
        eth = daiExchange.tokenToEthTransferInput(deposit, minEth, now + unidl, msg.sender);
        emit SellForEther(msg.sender, amount, deposit, eth);
    }

    function() external payable {
        require(msg.data.length == 0);
        uint256 price = daiExchange.getEthToTokenInputPrice(msg.value);
        this.buyWithEther(sub(price, price / unisl));
    }

    // --- Oracle ---

    function rate() public view returns(uint256) {
      return IOracle(oracle).value();
    }

    function collect() external {
      require(msg.sender == oracle, "dczk/permission-denied");
      uint256 fees = dai.balanceOf(address(this));
      dai.transfer(msg.sender, fees);
    }

    // --- DAO governance ---
    //
    //  uint256 -> bytes32 : web3.utils.padLeft(web3.utils.numberToHex(wei), 64)
    //  address -> bytes32 : web3.utils.padLeft(address, 64)

    function cast(uint8 key, bytes32 val) external returns(bool) {
        require(msg.sender == dao, "dczk/permission-denied");
        require(key <= 5, 'dczk/invalid-key');
        if (key == 0) oracle = address(uint160(uint256(val)));
        if (key == 1) cap    = uint256(val);
        if (key == 2) fee    = uint256(val);
        if (key == 3) unifa  = address(uint160(uint256(val)));
        if (key == 4) unisl  = uint256(val);
        if (key == 5) unidl  = uint256(val);
        emit Cast(key, val);
        return true;
    }
}
