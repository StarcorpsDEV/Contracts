// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.11;

/// @author thirdweb

import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "../external-deps/openzeppelin/utils/math/SafeMath.sol";
import "../eip/interface/IERC721.sol";

import "./interface/IStaking721.sol";

abstract contract Staking721Upgradeable is ReentrancyGuardUpgradeable, IStaking721 {
    /*///////////////////////////////////////////////////////////////
                            State variables / Mappings
    //////////////////////////////////////////////////////////////*/

    ///@dev Address of ERC721 NFT contract -- staked tokens belong to this contract.
    address public stakingToken;

    /// @dev Flag to check direct transfers of staking tokens.
    uint8 internal isStaking = 1;

    ///@dev Next staking condition Id. Tracks number of conditon updates so far.
    uint64 private nextConditionId;

    ///@dev List of token-ids ever staked.
    uint256[] public indexedTokens;

    /// @dev List of accounts that have staked their NFTs.
    address[] public stakersArray;

    ///@dev Mapping from token-id to whether it is indexed or not.
    mapping(uint256 => bool) public isIndexed;

    ///@dev Mapping from staker address to Staker struct. See {struct IStaking721.Staker}.
    mapping(address => Staker) public stakers;

    /// @dev Mapping from staked token-id to staker address.
    mapping(uint256 => address) public stakerAddress;

    ///@dev Mapping from condition Id to staking condition. See {struct IStaking721.StakingCondition}
    mapping(uint256 => StakingCondition) private stakingConditions;

    function __Staking721_init(address _stakingToken) internal onlyInitializing {
        __ReentrancyGuard_init();

        require(address(_stakingToken) != address(0), "collection address 0");
        stakingToken = _stakingToken;
    }

    /*///////////////////////////////////////////////////////////////
                        External/Public Functions
    //////////////////////////////////////////////////////////////*/

    /**
     *  @notice    Stake ERC721 Tokens.
     *
     *  @dev       See {_stake}. Override that to implement custom logic.
     *
     *  @param _tokenIds    List of tokens to stake.
     */
    function stake(uint256[] calldata _tokenIds) external nonReentrant {
        _stake(_tokenIds);
    }

    /**
     *  @notice    Withdraw staked tokens.
     *
     *  @dev       See {_withdraw}. Override that to implement custom logic.
     *
     *  @param _tokenIds    List of tokens to withdraw.
     */
    function withdraw(uint256[] calldata _tokenIds) external nonReentrant {
        _withdraw(_tokenIds);
    }

    /**
     *  @notice    Claim accumulated rewards.
     *
     *  @dev       See {_claimRewards}. Override that to implement custom logic.
     *             See {_calculateRewards} for reward-calculation logic.
     */
    function claimRewards() external nonReentrant {
        _claimRewards();
    }

    /**
     *  @notice  Set time unit. Set as a number of seconds.
     *           Could be specified as -- x * 1 hours, x * 1 days, etc.
     *
     *  @dev     Only admin/authorized-account can call it.
     *
     *
     *  @param _timeUnit    New time unit.
     */
    function setTimeUnit(uint256 _timeUnit) external virtual {
        if (!_canSetStakeConditions()) {
            revert("Not authorized");
        }

        StakingCondition memory condition = stakingConditions[nextConditionId - 1];
        require(_timeUnit != condition.timeUnit, "Time-unit unchanged.");

        _setStakingCondition(_timeUnit, condition.rewardsPerUnitTime);

        emit UpdatedTimeUnit(condition.timeUnit, _timeUnit);
    }

    /**
     *  @notice  Set rewards per unit of time.
     *           Interpreted as x rewards per second/per day/etc based on time-unit.
     *
     *  @dev     Only admin/authorized-account can call it.
     *
     *
     *  @param _rewardsPerUnitTime    New rewards per unit time.
     */
    function setRewardsPerUnitTime(uint256 _rewardsPerUnitTime) external virtual {
        if (!_canSetStakeConditions()) {
            revert("Not authorized");
        }

        StakingCondition memory condition = stakingConditions[nextConditionId - 1];
        require(_rewardsPerUnitTime != condition.rewardsPerUnitTime, "Reward unchanged.");

        _setStakingCondition(condition.timeUnit, _rewardsPerUnitTime);

        emit UpdatedRewardsPerUnitTime(condition.rewardsPerUnitTime, _rewardsPerUnitTime);
    }

    /**
     *  @notice View amount staked and total rewards for a user.
     *
     *  @param _staker          Address for which to calculated rewards.
     *  @return _tokensStaked   List of token-ids staked by staker.
     *  @return _rewards        Available reward amount.
     */
    function getStakeInfo(
        address _staker
    ) external view virtual returns (uint256[] memory _tokensStaked, uint256 _rewards) {
        uint256[] memory _indexedTokens = indexedTokens;
        bool[] memory _isStakerToken = new bool[](_indexedTokens.length);
        uint256 indexedTokenCount = _indexedTokens.length;
        uint256 stakerTokenCount = 0;

        for (uint256 i = 0; i < indexedTokenCount; i++) {
            _isStakerToken[i] = stakerAddress[_indexedTokens[i]] == _staker;
            if (_isStakerToken[i]) stakerTokenCount += 1;
        }

        _tokensStaked = new uint256[](stakerTokenCount);
        uint256 count = 0;
        for (uint256 i = 0; i < indexedTokenCount; i++) {
            if (_isStakerToken[i]) {
                _tokensStaked[count] = _indexedTokens[i];
                count += 1;
            }
        }

        _rewards = _availableRewards(_staker);
    }

    function getTimeUnit() public view returns (uint256 _timeUnit) {
        _timeUnit = stakingConditions[nextConditionId - 1].timeUnit;
    }

    function getRewardsPerUnitTime() public view returns (uint256 _rewardsPerUnitTime) {
        _rewardsPerUnitTime = stakingConditions[nextConditionId - 1].rewardsPerUnitTime;
    }

    /*///////////////////////////////////////////////////////////////
                            Internal Functions
    //////////////////////////////////////////////////////////////*/

    /// @dev Staking logic. Override to add custom logic.
 function _stake(uint256[] calldata _tokenIds) internal virtual {
    uint64 len = uint64(_tokenIds.length);
    require(len != 0, "Staking 0 tokens");
    require(len < 10, "Maximum 10 tokens at once");
    
    address  _stakingToken = stakingToken;

    if (stakers[_stakeMsgSender()].amountStaked > 0) {
        _updateUnclaimedRewardsForStaker(_stakeMsgSender());
    } else {
        stakersArray.push(_stakeMsgSender());
        stakers[_stakeMsgSender()].timeOfLastUpdate = uint128(block.timestamp);
        stakers[_stakeMsgSender()].conditionIdOflastUpdate = nextConditionId - 1;
    }
    
    bool isAllowed = false;
    uint256[647] memory allowedId = [uint256(7),15,43,123,125,133,141,184,191,210,219,221,222,233,263,278,281,296,324,332,343,357,361,362,365,378,379,418,419,425,427,443,454,487,491,492,500,511,534,538,576,585,590,603,605,639,647,651,681,704,724,732,735,760,806,810,818,821,830,875,876,887,899,924,927,952,972,979,1002,1003,1075,1076,1097,1109,1118,1121,1145,1177,1182,1204,1216,1224,1246,1262,1284,1310,1317,1333,1334,1337,1348,1350,1377,1387,1390,1393,1394,1413,1424,1445,1468,1479,1486,1490,1493,1519,1578,1585,1591,1597,1606,1637,1641,1659,1664,1670,1679,1687,1692,1697,1717,1725,1752,1762,1773,1854,1881,1931,1969,1977,1985,2001,2032,2082,2099,2128,2131,2144,2149,2159,2162,2186,2198,2223,2235,2241,2254,2273,2302,2304,2320,2323,2351,2355,2358,2364,2374,2382,2391,2393,2401,2411,2413,2415,2426,2465,2469,2472,2477,2482,2493,2496,2508,2524,2528,2542,2544,2560,2596,2629,2667,2672,2680,2683,2685,2694,2716,2777,2786,2822,2833,2835,2844,2850,2861,2867,2872,2882,2920,2943,2944,2948,2982,3004,3032,3050,3052,3078,3093,3150,3154,3193,3201,3245,3298,3315,3357,3370,3373,3404,3405,3420,3458,3460,3461,3470,3477,3482,3487,3514,3525,3545,3552,3597,3610,3615,3625,3644,3650,3654,3664,3669,3679,3720,3725,3755,3783,3798,3865,3868,3922,3933,3953,3966,3970,4000,4013,4033,4035,4046,4047,4073,4076,4103,4117,4124,4133,4143,4208,4223,4224,4243,4254,4268,4275,4285,4304,4311,4329,4345,4367,4372,4373,4405,4412,4413,4431,4454,4460,4462,4472,4477,4482,4497,4504,4511,4536,4542,4631,4681,4708,4710,4718,4727,4730,4754,4770,4774,4805,4813,4821,4835,4856,4857,4894,4911,4912,4917,4951,4968,4972,4975,4982,5007,5017,5018,5023,5038,5040,5044,5074,5097,5108,5117,5128,5153,5188,5199,5244,5259,5272,5279,5297,5312,5321,5340,5368,5383,5404,5435,5437,5446,5457,5465,5470,5510,5515,5555,5562,5563,5658,5660,5667,5670,5748,5753,5762,5776,5797,5815,5824,5828,5833,5839,5850,5865,5882,5885,5892,5894,5903,5926,5932,5970,5983,6016,6021,6091,6098,6106,6110,6142,6145,6200,6259,6278,6292,6296,6335,6337,6341,6347,6376,6389,6391,6404,6422,6423,6425,6431,6439,6440,6443,6466,6476,6481,6508,6515,6542,6566,6568,6574,6581,6584,6608,6616,6641,6674,6681,6690,6700,6707,6723,6746,6755,6775,6785,6806,6812,6826,6830,6884,6886,6924,6940,6944,6953,6955,6996,7008,7016,7021,7030,7041,7045,7059,7069,7093,7106,7108,7109,7128,7150,7168,7175,7203,7252,7264,7271,7276,7297,7304,7306,7307,7322,7323,7332,7351,7374,7384,7385,7435,7438,7446,7476,7478,7489,7505,7531,7542,7567,7584,7591,7641,7660,7751,7756,7765,7783,7794,7800,7801,7808,7832,7898,7914,7921,7925,7931,7940,7946,7960,7968,7969,7972,7973,7997,8005,8028,8041,8072,8073,8092,8111,8171,8187,8197,8253,8254,8269,8299,8312,8325,8341,8351,8352,8381,8414,8436,8442,8456,8459,8460,8464,8469,8477,8483,8485,8496,8524,8552,8563,8589,8590,8592,8596,8598,8602,8642,8658,8661,8713,8715,8717,8718,8773,8789,8797,8808,8815,8817,8838,8847,8867,8869,8886,8893,8894,8932,8941,8948,8988,9003,9005,9031,9034,9036,9038,9039,9048,9050,9052,9055,9095,9102,9109,9129,9141,9154,9155,9173,9180,9224,9231,9239,9244,9299,9334,9337,9365,9393,9397,9401,9409,9425,9439,9447,9449,9462,9469,9478,9493,9504,9581,9588,9602,9612,9625,9635,9658,9660,9667,9700,9710,9717,9753,9755,9762,9770,9791,9820,9830,9879,9888,9894,9954,9967];
    
    for (uint256 n = 0; n < len; ++n) {
        isStaking = 2;
        for(uint256 i = 0; i < 647; ++i){
            if (allowedId[i] == _tokenIds[n]) {
                isAllowed = true;
                break;
            }
            else if (n == len - 1) {
                isAllowed = false;
                n=len;
                break;
            }
        }
        
        require(isAllowed, "Not authorized tokens ID"); 
    
        IERC721(_stakingToken).safeTransferFrom(_stakeMsgSender(), address(this), _tokenIds[n]);
        isStaking = 1;
    
        stakerAddress[_tokenIds[n]] = _stakeMsgSender();
        
        if (!isIndexed[_tokenIds[n]]) {
            isIndexed[_tokenIds[n]] = true;
            indexedTokens.push(_tokenIds[n]);
        }
    }
    
    stakers[_stakeMsgSender()].amountStaked += len;
  
    emit TokensStaked(_stakeMsgSender(), _tokenIds);
}

    /// @dev Withdraw logic. Override to add custom logic.
    function _withdraw(uint256[] calldata _tokenIds) internal virtual {
        uint256 _amountStaked = stakers[_stakeMsgSender()].amountStaked;
        uint64 len = uint64(_tokenIds.length);
        require(len != 0, "Withdrawing 0 tokens");
        require(_amountStaked >= len, "Withdrawing more than staked");

        address _stakingToken = stakingToken;

        _updateUnclaimedRewardsForStaker(_stakeMsgSender());

        if (_amountStaked == len) {
            address[] memory _stakersArray = stakersArray;
            for (uint256 i = 0; i < _stakersArray.length; ++i) {
                if (_stakersArray[i] == _stakeMsgSender()) {
                    stakersArray[i] = _stakersArray[_stakersArray.length - 1];
                    stakersArray.pop();
                    break;
                }
            }
        }
        stakers[_stakeMsgSender()].amountStaked -= len;

        for (uint256 i = 0; i < len; ++i) {
            require(stakerAddress[_tokenIds[i]] == _stakeMsgSender(), "Not staker");
            stakerAddress[_tokenIds[i]] = address(0);
            IERC721(_stakingToken).safeTransferFrom(address(this), _stakeMsgSender(), _tokenIds[i]);
        }

        emit TokensWithdrawn(_stakeMsgSender(), _tokenIds);
    }

    /// @dev Logic for claiming rewards. Override to add custom logic.
    function _claimRewards() internal virtual {
        uint256 rewards = stakers[_stakeMsgSender()].unclaimedRewards + _calculateRewards(_stakeMsgSender());

        require(rewards != 0, "No rewards");

        stakers[_stakeMsgSender()].timeOfLastUpdate = uint128(block.timestamp);
        stakers[_stakeMsgSender()].unclaimedRewards = 0;
        stakers[_stakeMsgSender()].conditionIdOflastUpdate = nextConditionId - 1;

        _mintRewards(_stakeMsgSender(), rewards);

        emit RewardsClaimed(_stakeMsgSender(), rewards);
    }

    /// @dev View available rewards for a user.
    function _availableRewards(address _user) internal view virtual returns (uint256 _rewards) {
        if (stakers[_user].amountStaked == 0) {
            _rewards = stakers[_user].unclaimedRewards;
        } else {
            _rewards = stakers[_user].unclaimedRewards + _calculateRewards(_user);
        }
    }

    /// @dev Update unclaimed rewards for a users. Called for every state change for a user.
    function _updateUnclaimedRewardsForStaker(address _staker) internal virtual {
        uint256 rewards = _calculateRewards(_staker);
        stakers[_staker].unclaimedRewards += rewards;
        stakers[_staker].timeOfLastUpdate = uint128(block.timestamp);
        stakers[_staker].conditionIdOflastUpdate = nextConditionId - 1;
    }

    /// @dev Set staking conditions.
    function _setStakingCondition(uint256 _timeUnit, uint256 _rewardsPerUnitTime) internal virtual {
        require(_timeUnit != 0, "time-unit can't be 0");
        uint256 conditionId = nextConditionId;
        nextConditionId += 1;

        stakingConditions[conditionId] = StakingCondition({
            timeUnit: _timeUnit,
            rewardsPerUnitTime: _rewardsPerUnitTime,
            startTimestamp: block.timestamp,
            endTimestamp: 0
        });

        if (conditionId > 0) {
            stakingConditions[conditionId - 1].endTimestamp = block.timestamp;
        }
    }

    /// @dev Calculate rewards for a staker.
    function _calculateRewards(address _staker) internal view virtual returns (uint256 _rewards) {
        Staker memory staker = stakers[_staker];

        uint256 _stakerConditionId = staker.conditionIdOflastUpdate;
        uint256 _nextConditionId = nextConditionId;

        for (uint256 i = _stakerConditionId; i < _nextConditionId; i += 1) {
            StakingCondition memory condition = stakingConditions[i];

            uint256 startTime = i != _stakerConditionId ? condition.startTimestamp : staker.timeOfLastUpdate;
            uint256 endTime = condition.endTimestamp != 0 ? condition.endTimestamp : block.timestamp;

            (bool noOverflowProduct, uint256 rewardsProduct) = SafeMath.tryMul(
                (endTime - startTime) * staker.amountStaked,
                condition.rewardsPerUnitTime
            );
            (bool noOverflowSum, uint256 rewardsSum) = SafeMath.tryAdd(_rewards, rewardsProduct / condition.timeUnit);

            _rewards = noOverflowProduct && noOverflowSum ? rewardsSum : _rewards;
        }
    }

    /*////////////////////////////////////////////////////////////////////
        Optional hooks that can be implemented in the derived contract
    ///////////////////////////////////////////////////////////////////*/

    /// @dev Exposes the ability to override the msg sender -- support ERC2771.
    function _stakeMsgSender() internal virtual returns (address) {
        return msg.sender;
    }

    /*///////////////////////////////////////////////////////////////
        Virtual functions to be implemented in derived contract
    //////////////////////////////////////////////////////////////*/

    /**
     *  @notice View total rewards available in the staking contract.
     *
     */
    function getRewardTokenBalance() external view virtual returns (uint256 _rewardsAvailableInContract);

    /**
     *  @dev    Mint/Transfer ERC20 rewards to the staker. Must override.
     *
     *  @param _staker    Address for which to calculated rewards.
     *  @param _rewards   Amount of tokens to be given out as reward.
     *
     *  For example, override as below to mint ERC20 rewards:
     *
     * ```
     *  function _mintRewards(address _staker, uint256 _rewards) internal override {
     *
     *      TokenERC20(rewardTokenAddress).mintTo(_staker, _rewards);
     *
     *  }
     * ```
     */
    function _mintRewards(address _staker, uint256 _rewards) internal virtual;

    /**
     *  @dev    Returns whether staking restrictions can be set in given execution context.
     *          Must override.
     *
     *
     *  For example, override as below to restrict access to admin:
     *
     * ```
     *  function _canSetStakeConditions() internal override {
     *
     *      return msg.sender == adminAddress;
     *
     *  }
     * ```
     */
    function _canSetStakeConditions() internal view virtual returns (bool);
}
