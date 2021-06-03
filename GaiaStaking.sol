//SPDX-License-Identifier: MIT
pragma solidity ^0.8.1;

import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";


contract GaiaLPStaking is ERC20, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    struct StratCandidate {
        address implementation;
        uint proposedTime;
    }
    
    // Info of each user.
    struct UserInfo {
        uint256 amount;     // How many want tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        bool inBlackList;
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 lpToken;           // Address of want token contract.
        uint256 lastRewardBlock;  // Last block number that Gaia distribution occurs.
        uint256 accGaiaPerShare; // Accumulated Gaia per share, times 1e12. See below.
    }

    uint256 public rewardPerBlock; // Gaia tokens created per block 0.00002
    uint256 public startBlock;
    uint256 public bonusEndBlock;
    mapping (address => UserInfo) public userInfo;
    
    uint256 public totalAllocPoint = 0; // Total allocation points. Must be the sum of all allocation points in all pools.

    // The last proposed strategy to switch to.
    StratCandidate public stratCandidate; 
    // The strategy currently in use by the vault.
    address public strategy;
    // The token the vault accepts and looks to maximize.
    // The token the vault
    IERC20 public rewardToken;
    // The minimum time it has to pass before a strat candidate can be approved.
    uint256 public immutable approvalDelay;

    event NewStratCandidate(address implementation);
    event UpgradeStrat(address implementation);
    PoolInfo[] public poolInfo;
    /**
     * @dev Sets the value of {token} to the token that the vault will
     * hold as underlying value. It initializes the vault's own 'moo' token.
     * This token is minted when someone does a deposit. It is burned in order
     * to withdraw the corresponding portion of the underlying assets.
     * @param _token the token to maximize.
     * @param _name the name of the vault token.
     * @param _symbol the symbol of the vault token.
     * @param _approvalDelay the delay before a new strat can be approved.
     */
    constructor (
        address _token, 
        address _rewardToken,
        string memory _name, 
        string memory _symbol, 
        uint256 _startBlock,
        uint256 _bonusEndBlock,
        uint256 _approvalDelay,
        uint256 _rewardPerBlock
    ) public ERC20(
        string(_name),
        string(_symbol)
    ) {
        strategy = address(0);
        rewardToken = IERC20(_rewardToken);
        startBlock = _startBlock;
        bonusEndBlock = _bonusEndBlock;
        approvalDelay = _approvalDelay;
        rewardPerBlock = _rewardPerBlock;
        
        poolInfo.push(PoolInfo({
            lpToken: IERC20(_token),
            lastRewardBlock: startBlock,
            accGaiaPerShare: 0
        }));

    }

    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        if (_to <= bonusEndBlock) {
            return _to.sub(_from);
        } else if (_from >= bonusEndBlock) {
            return 0;
        } else {
            return bonusEndBlock.sub(_from);
        }
    }
    
    // View function to see pending Reward on frontend.
    function pendingReward(address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[0];
        UserInfo storage user = userInfo[_user];
        uint256 accGaiaPerShare = pool.accGaiaPerShare;
        uint256 lpSupply = balance();
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
            uint256 GaiaReward = multiplier.mul(rewardPerBlock);
            accGaiaPerShare = accGaiaPerShare.add(GaiaReward.mul(1e12).div(lpSupply));
        }
        return user.amount.mul(accGaiaPerShare).div(1e12).sub(user.rewardDebt);
    }
    
    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = balance();
        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 GaiaReward = multiplier.mul(rewardPerBlock);
        pool.accGaiaPerShare = pool.accGaiaPerShare.add(GaiaReward.mul(1e12).div(lpSupply));
        pool.lastRewardBlock = block.number;
    }
    
    /**
     * @dev It calculates the total underlying value of {token} held by the system.
     * It takes into account the vault contract balance, the strategy contract balance
     *  and the balance deployed in other contracts as part of the strategy.
     */
    function balance() public view returns (uint) {
        PoolInfo storage pool = poolInfo[0];
        return pool.lpToken.balanceOf(address(this)).add(IStrategy(strategy).balanceOf());
    }

    /**
     * @dev Custom logic in here for how much the vault allows to be borrowed.
     * We return 100% of tokens for now. Under certain conditions we might
     * want to keep some of the system funds at hand in the vault, instead
     * of putting them to work.
     */
    function available() public view returns (uint256) {
        PoolInfo storage pool = poolInfo[0];
        return pool.lpToken.balanceOf(address(this));
    }

    /**
     * @dev Function for various UIs to display the current value of one of our yield tokens.
     * Returns an uint256 with 18 decimals of how much underlying asset one vault share represents.
     */
    function getPricePerFullShare() public view returns (uint256) {
        return balance().mul(1e18).div(totalSupply());
    }

    /**
     * @dev A helper function to call deposit() with all the sender's funds.
     */
    function depositAll() external {
        PoolInfo storage pool = poolInfo[0];
        deposit(pool.lpToken.balanceOf(msg.sender));
    }

    /**
     * @dev The entrypoint of funds into the system. People deposit with this function
     * into the vault. The vault is then in charge of sending funds into the strategy.
     */
    function deposit(uint _amount) public nonReentrant {
        require(_amount > 0, "Amount should be bigger than 0!");
        PoolInfo storage pool = poolInfo[0];
        UserInfo storage user = userInfo[msg.sender];
        
        updatePool(0);
        uint256 _pool = balance();
        if (user.amount > 0) {
            uint256 pending = user.amount.mul(pool.accGaiaPerShare).div(1e12).sub(user.rewardDebt);
            if(pending > 0) {
                rewardToken.safeTransfer(address(msg.sender), pending);
            }
        }
        
        pool.lpToken.safeTransferFrom(msg.sender, address(this), _amount);
        earn();
        uint256 _after = balance();
        _amount = _after.sub(_pool); // Additional check for deflationary tokens
        uint256 shares = 0;
        if (totalSupply() == 0) {
            shares = _amount;
        } else {
            shares = (_amount.mul(totalSupply())).div(_pool);
        }
        user.amount = user.amount.add(_amount);
        user.rewardDebt = user.amount.mul(pool.accGaiaPerShare).div(1e12);

        _mint(msg.sender, shares);
    }
    
    function safeTransferReward(address to, uint256 value) internal {
        (bool success, ) = to.call{gas: 23000, value: value}("");
        // (bool success,) = to.call{value:value}(new bytes(0));
        require(success, 'TransferHelper: ETH_TRANSFER_FAILED');
    }

    /**
     * @dev Function to send funds into the strategy and put them to work. It's primarily called
     * by the vault's deposit() function.
     */
    function earn() public {
        PoolInfo storage pool = poolInfo[0];
        uint _bal = available();
        pool.lpToken.safeTransfer(strategy, _bal);
        IStrategy(strategy).deposit();
    }

    /**
     * @dev A helper function to call withdraw() with all the sender's funds.
     */
    function withdrawAll() external {
        withdraw(balanceOf(msg.sender));
    }

    /**
     * @dev Function to exit the system. The vault will withdraw the required tokens
     * from the strategy and pay up the token holder. A proportional number of IOU
     * tokens are burned in the process.
     */
    function withdraw(uint256 _shares) public {
        PoolInfo storage pool = poolInfo[0];
        UserInfo storage user = userInfo[msg.sender];
        require(_shares >= 0, "withdraw: not good");
        updatePool(0);

        harvest();
        uint256 pending = user.amount.mul(pool.accGaiaPerShare).div(1e12).sub(user.rewardDebt);
        if(pending > 0) {
            rewardToken.safeTransfer(address(msg.sender), pending);
        }
        
        uint256 r = (balance().mul(_shares)).div(totalSupply());
        _burn(msg.sender, _shares);

        uint b = pool.lpToken.balanceOf(address(this));
        if (b < r) {
            uint _withdraw = r.sub(b);
            IStrategy(strategy).withdraw(_withdraw);
            uint _after = pool.lpToken.balanceOf(address(this));
            uint _diff = _after.sub(b);
            if (_diff < _withdraw) {
                r = b.add(_diff);
            }
        }

        pool.lpToken.safeTransfer(msg.sender, r);

        user.rewardDebt = user.amount.mul(pool.accGaiaPerShare).div(1e12);
    }
    
    function harvest() public {
        PoolInfo storage pool = poolInfo[0];

        uint256 totalShareAmount = balanceOf(msg.sender);
        require(totalShareAmount >= 0, "harvest: not good");
        
        UserInfo storage user = userInfo[msg.sender];
        earn();
        uint256 _pool = balance();
        
        uint256 rewardAsGaia = (_pool.mul(totalShareAmount)).div(totalSupply()) - user.amount;

        uint256 b = pool.lpToken.balanceOf(address(this));
        if (b < rewardAsGaia) {
            uint _withdraw = rewardAsGaia.sub(b);
            IStrategy(strategy).withdraw(_withdraw);
        }
        
        uint256 burnTokenAmount = balanceOf(msg.sender) - user.amount.mul(totalSupply()).div(balance());
        _burn(msg.sender, burnTokenAmount);
        
        IUniswapRouter(unirouter).swapExactTokensForTokens(rewardAsGaia, 0, cakeToGaiaRoute, msg.sender, now.add(600));        
    }
    
    function initStrat(address _implementation) public onlyOwner {
        require(strategy == address(0), "not initial strategy");
        strategy = _implementation;
    }

    /** 
     * @dev Sets the candidate for the new strat to use with this vault.
     * @param _implementation The address of the candidate strategy.  
     */
    function proposeStrat(address _implementation) public onlyOwner {
        stratCandidate = StratCandidate({ 
            implementation: _implementation,
            proposedTime: block.timestamp
         });

        emit NewStratCandidate(_implementation);
    }

    /** 
     * @dev It switches the active strat for the strat candidate. After upgrading, the 
     * candidate implementation is set to the 0x00 address, and proposedTime to a time 
     * happening in +100 years for safety. 
     */

    function upgradeStrat() public onlyOwner {
        require(stratCandidate.implementation != address(0), "There is no candidate");
        require(stratCandidate.proposedTime.add(approvalDelay) < block.timestamp, "Delay has not passed");
        
        emit UpgradeStrat(stratCandidate.implementation);

        IStrategy(strategy).retireStrat();
        strategy = stratCandidate.implementation;
        stratCandidate.implementation = address(0);
        stratCandidate.proposedTime = 5000000000;
        
        earn();
    }
    
    receive() external payable {}
}