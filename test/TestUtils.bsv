import ClientServer :: *;
import GetPut :: *;
import PAClib :: *;
import Randomizable :: *;
import Vector :: *;

import Headers :: *;
import DataTypes :: *;
import PrimUtils :: *;
import Settings :: *;
import SimDma :: *;
import Utils :: *;
import Utils4Test :: *;
/*
module mkTestSegmentDataStream(Empty);
    let minDmaLen = 1;
    let maxDmaLen = 10000;
    let pmtu = IBV_MTU_256;

    Vector#(2, DataStreamPipeOut) dataStreamPipeOutVec <-
        mkRandomPktLenDataStreamPipeOut(minDmaLen, maxDmaLen);
    let pmtuPipeOut <- mkConstantPipeOut(pmtu);
    let pmtuSegPipeOut <- mkSegmentDataStreamByPmtu(
        dataStreamPipeOutVec[0], pmtuPipeOut
    );
    let refDataStreamPipeOut <- mkBuffer_n(2, dataStreamPipeOutVec[1]);
    Reg#(PktFragNum) pmtuFragCntReg <- mkRegU;

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    rule segment;
        let refDataStream = refDataStreamPipeOut.first;
        refDataStreamPipeOut.deq;

        let maxPktFragNum = calcFragNumByPmtu(pmtu);
        if (refDataStream.isLast) begin
            pmtuFragCntReg <= 0;
        end
        else if (refDataStream.isFirst) begin
            pmtuFragCntReg <= 1;
        end
        else if (pmtuFragCntReg == maxPktFragNum - 1) begin
            refDataStream.isLast = True;
            pmtuFragCntReg <= 0;
        end
        else begin
            pmtuFragCntReg <= pmtuFragCntReg + 1;
        end

        if (isZero(pmtuFragCntReg)) begin
            refDataStream.isFirst = True;
        end

        let segDataStream = pmtuSegPipeOut.first;
        pmtuSegPipeOut.deq;

        immAssert(
            segDataStream == refDataStream,
            "segDataStream assertion @ mkTestSegmentDataStream",
            $format(
                "maxPktFragNum=%0d, pmtuFragCntReg=%0d",
                maxPktFragNum, pmtuFragCntReg,
                ", segDataStream=", fshow(segDataStream),
                " should == refDataStream=", fshow(refDataStream)
            )
        );

        countDown.decr;
        // $display(
        //     "maxPktFragNum=%0d, pmtuFragCntReg=%0d",
        //     maxPktFragNum, pmtuFragCntReg,
        //     ", segDataStream=", fshow(segDataStream),
        //     " should == refDataStream=", fshow(refDataStream)
        // );
    endrule
endmodule
*/
(* doc = "testcase" *)
module mkTestPsnFunc(Empty);
    let maxCycles = 100;

    Randomize#(PSN) randomPSN <- mkGenericRandomizer;
    Randomize#(Length) randomLength <- mkGenericRandomizer;
    Reg#(Bool) initializedReg <- mkReg(False);

    // Finish simulation after MAX_CMP_CNT comparisons
    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    function Action testPSN(PSN startPSN, Length len, PMTU pmtu);
        action
            let { isOnlyPkt, pktNum, nextPSN, endPSN } = calcPktNumNextAndEndPSN(
                startPSN, len, pmtu
            );
            PktNum halfPktNum = pktNum >> 1;
            PSN midPSN = truncate(zeroExtend(startPSN) + halfPktNum);
            let psnInRangeExcl = psnInRangeExclusive(midPSN, startPSN, endPSN);

            $display(
                "time=%0t: startPSN=%h, len=%h, pktNum=%h, endPSN=%h, nextPSN=%h, midPSN=%h",
                $time, startPSN, len, pktNum, endPSN, nextPSN, midPSN
            );

            if (pktNum > 2) begin
                immAssert(
                    psnInRangeExcl,
                    "psnInRangeExcl assertion @ mkTestPsnFunc",
                    $format(
                        "startPSN=%h < midPSN=%h < endPSN=%h when len=%h and pktNum=%h > 2",
                        startPSN, midPSN, endPSN, len, pktNum
                    )
                );
            end
            else begin
                immAssert(
                    midPSN == startPSN || midPSN == endPSN,
                    "midPSN assertion @ mkTestPsnFunc",
                    $format(
                        "midPSN=%h == startPSN=%h or midPSN=%h == endPSN=%h when len=%h and pktNum=%h <= 2",
                        midPSN, startPSN, midPSN, endPSN, len, pktNum
                    )
                );
            end
            immAssert(
                |len == |pktNum,
                "len and pktNum assertion @ mkTestPsnFunc",
                $format("|len=%b == |pktNum=%b",|len, |pktNum)
            );

            immAssert(
                nextPSN == endPSN + 1,
                "nextPSN and endPSN assertion @ mkTestPsnFunc",
                $format("nextPSN=%h == endPSN=%h + 1", nextPSN, endPSN)
            );
        endaction
    endfunction

    rule init if (!initializedReg);
        randomPSN.cntrl.init;
        randomLength.cntrl.init;
        initializedReg <= True;
    endrule

    rule testRandomPSN if (initializedReg);
        let pmtu = IBV_MTU_1024;

        PSN startPSN <- randomPSN.next;
        Length len <- randomLength.next;

        testPSN(startPSN, len, pmtu);

        countDown.decr;
    endrule

    rule testZeroLen if (initializedReg);
        let pmtu = IBV_MTU_4096;

        PSN startPSN <- randomPSN.next;
        Length len = 0;

        testPSN(startPSN, len, pmtu);
        noAction;
    endrule

    rule testMaxLen if (initializedReg);
        let pmtu = IBV_MTU_256;

        PSN startPSN <- randomPSN.next;
        Length len = fromInteger(valueOf(RDMA_MAX_LEN));

        testPSN(startPSN, len, pmtu);
        noAction;
    endrule

    rule testMaxPSN if (initializedReg);
        let pmtu = IBV_MTU_256;

        PSN startPSN = maxBound;
        Length len <- randomLength.next;

        testPSN(startPSN, len, pmtu);
        noAction;
    endrule
endmodule
