// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {DeployRaffle} from "../../script/DeployRaffle.s.sol";
import {Raffle} from "../../src/Raffle.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {Test, console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {VRFCoordinatorV2Mock} from "@chainlink/contracts/src/v0.8/mocks/VRFCoordinatorV2Mock.sol";

contract RaffleTest is Test {
    // ------- EVENTS --------
    event EnteredRaffle(address indexed player);

    Raffle raffle;
    HelperConfig helperConfig;

    uint256 entranceFee;
    uint256 interval;
    address vrfCoordinator;
    bytes32 gasLane;
    uint64 subscriptionId;
    uint32 callbackGasLimit;
    address link;

    address public PLAYER = makeAddr("player");
    uint256 public constant STARTING_USER_BALANCE = 10 ether;

    function setUp() external {
        DeployRaffle deployer = new DeployRaffle();
        (raffle, helperConfig) = deployer.run();
        (
            entranceFee,
            interval,
            vrfCoordinator,
            gasLane,
            subscriptionId,
            callbackGasLimit,
            link
        ) = helperConfig.activeNetworkConfig();
        vm.deal(PLAYER, STARTING_USER_BALANCE);
    }

    function testRaffleInitializesInOpenState() public view {
        assert(raffle.getRaffleState() == Raffle.RaffleState.OPEN);
    }

    function testRaffleRevertsWhenYouDontPayEnough() public {
        // Arrange
        vm.prank(PLAYER);
        // Act/ Revert
        vm.expectRevert(Raffle.Raffle__NotEnoughEthSent.selector);
        raffle.enterRaffle();
    }

    function testRaffleRecordsPlayerWhenTheyEnter() public {
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
        address recordedPlayer = raffle.getPlayer(0);
        assert(PLAYER == recordedPlayer);
    }

    function testEventEntrance() public {
        vm.prank(PLAYER);
        vm.expectEmit(true, false, false, false, address(raffle));
        emit EnteredRaffle(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
    }

    modifier enteredRaffleandTimePassed() {
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
        vm.roll(block.number + 2);
        _;
    }

    function testCantEnterWhenRaffleIsCalculating()
        public
        enteredRaffleandTimePassed
    {
        raffle.performUpkeep("");

        vm.expectRevert(Raffle.Raffle__RaffleNotOpen.selector);
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
    }

    ////////////////////
    // checkUpKeep    //
    ///////////////////
    function testCheckUpkeepReturnsFalseIfItHasnoBalance() public {
        // Arrange
        vm.roll(block.number + 5);

        // Act
        (bool upkeepNeded, ) = raffle.checkUpkeep("");
        // Assert
        assert(!upkeepNeded);
    }

    function testCheckUpkeepRetunsFalseIFRaffleIsnotOpen()
        public
        enteredRaffleandTimePassed
    {
        // Arrange
        raffle.performUpkeep("");

        // Act
        (bool upkeepNeded, ) = raffle.checkUpkeep("");
        // Assert
        assert(upkeepNeded == false);
    }

    function testCheckUpkeepReturnsFalseIfEnoughTimeHasntPassed() public {
        // Arrange - All variables are true except timeHasPassed
        vm.prank(PLAYER);
        raffle.enterRaffle{value: entranceFee}();
        raffle.performUpkeep("");

        // Act
        (bool upkeepNeded, ) = raffle.checkUpkeep("");
        // Assert
        assert(upkeepNeded == false);
    }

    function testCheckUpkeepReturnsTrueIfParametersAreGood()
        public
        enteredRaffleandTimePassed
    {
        // Act
        (bool upkeepNeded, ) = raffle.checkUpkeep("");
        // Assert
        assert(upkeepNeded == true);
    }

    ////////////////////
    // performUpKeep    //
    ///////////////////
    function testPerformUpkeepCanOnlyRunIfCheckUpkeepIsTrue()
        public
        enteredRaffleandTimePassed
    {
        // Act/ Assert
        raffle.performUpkeep("");
    }

    function testPerformUpkeepRevertsIfCheckUpkeepIsFalse() public {
        // Arrange
        uint256 currentBalance = 0;
        uint256 numPlayers = 0;
        uint256 raffleState = 0;

        // Act/ Assert
        vm.expectRevert(
            abi.encodeWithSelector(
                Raffle.Raffle__UpkeepNotNeeded.selector,
                currentBalance,
                numPlayers,
                raffleState
            )
        );
        raffle.performUpkeep("");
    }

    function testPerformUpkeepUpdatesRaffleStateAndEmitRequestId()
        public
        enteredRaffleandTimePassed
    {
        // Act
        vm.recordLogs();
        raffle.performUpkeep("");
        Vm.Log[] memory entries = vm.getRecordedLogs();
        // @note The reason why we get the second element from the array is that the first event is the one made by Chainlink VrfCoordinator. The second one is ours. In the topics, the first element is the event itself and the second element is the indexed parameter
        bytes32 requestId = entries[1].topics[1];

        Raffle.RaffleState rstate = raffle.getRaffleState();

        assert(uint256(requestId) > 0);
        assert(uint256(rstate) == 1);
    }

    /////////////////////////
    // fulfillRandomWords  //
    ////////////////////////

    modifier skipFork() {
        if (block.chainid != 31337) {
            return;
        }
        _;
    }

    function testFulfillRandomWordsCanOnlyBeCalledAfterPerformUpkeep(
        uint256 requestId
    ) public enteredRaffleandTimePassed skipFork {
        // Arrange
        vm.expectRevert("nonexistent request");
        VRFCoordinatorV2Mock(vrfCoordinator).fulfillRandomWords(
            requestId,
            address(0)
        );
    }

    function testFulfillRandomWordsPicksaWinnerResetsandSendMoney()
        public
        enteredRaffleandTimePassed
        skipFork
    {
        // Arrange
        uint256 additionalEntrants = 5;
        uint256 startingIndex = 1;
        for (
            uint256 i = startingIndex;
            i < additionalEntrants + startingIndex;
            i++
        ) {
            address player = address(uint160(i));
            hoax(player, STARTING_USER_BALANCE);
            raffle.enterRaffle{value: entranceFee}();
        }

        uint256 prize = entranceFee * (additionalEntrants + 1);

        // Act
        vm.recordLogs();
        raffle.performUpkeep("");
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 requestId = entries[1].topics[1];
        uint256 previousTimestamp = raffle.getLastTimestamp();
        // Pretend to be chainlink vrf to get random and pick winner
        VRFCoordinatorV2Mock(vrfCoordinator).fulfillRandomWords(
            uint256(requestId),
            address(0)
        );

        // Assert
        assert(uint256(raffle.getRaffleState()) == 0);
        assert(raffle.getRecentWinner() != address(0));
        assert(raffle.getPlayersLength() == 0);
        assert(previousTimestamp < raffle.getLastTimestamp());
        assert(
            raffle.getRecentWinner().balance ==
                STARTING_USER_BALANCE + prize - entranceFee
        );
    }
}
