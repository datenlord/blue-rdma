import BuildVector :: *;
import ClientServer :: *;
import FIFOF :: *;
import GetPut :: *;
import PAClib :: *;
import Vector :: *;

import Headers :: *;
import Controller :: *;
import DataTypes :: *;
import MetaData :: *;
import PayloadGen :: *;
import PrimUtils :: *;
import Settings :: *;
import SimDma :: *;
import Utils :: *;
import Utils4Test :: *;

(* doc = "testcase" *)
module mkTestAddrChunkSrv(Empty);
    let minPayloadLen = 2048;
    let maxPayloadLen = 8192;
    let pmtuVec = vec(
        IBV_MTU_256,
        IBV_MTU_512,
        IBV_MTU_1024,
        IBV_MTU_2048,
        IBV_MTU_4096
    );
    FIFOF#(AddrChunkReq)   reqQ <- mkFIFOF;
    FIFOF#(AddrChunkResp) respQ <- mkFIFOF;
    FIFOF#(Length)    totalLenQ <- mkFIFOF;
    FIFOF#(PktMetaDataSGE) sgePktMetaDataRefQ <- mkFIFOF;

    Reg#(Bool) clearReg <- mkReg(True);
    let dut <- mkAddrChunkSrv(clearReg);

    PipeOut#(Tuple2#(Bool, Bool)) firstLastPipeOut <- mkGenericRandomPipeOut;
    PipeOut#(ADDR) startAddrPipeOut <- mkGenericRandomPipeOut;
    let payloadLenPipeOut <- mkRandomLenPipeOut(minPayloadLen, maxPayloadLen);
    let pmtuPipeOut <- mkRandomItemFromVec(pmtuVec);

    Reg#(PktLen)  firstPktLenReg <- mkRegU;
    Reg#(PktLen)   lastPktLenReg <- mkRegU;
    Reg#(PktLen)      pmtuLenReg <- mkRegU;
    Reg#(PMTU)           pmtuReg <- mkRegU;
    Reg#(Bool)        isFirstReg <- mkRegU;
    Reg#(PktNum)       pktNumReg <- mkRegU;
    Reg#(ADDR)       nextAddrReg <- mkRegU;
    Reg#(Length)     totalLenReg <- mkRegU;

    Reg#(PktNum) remainingPktNumReg <- mkReg(0);

    Reg#(Bool) busyReg <- mkReg(False);
    PSN oneAsPSN = 1;
    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    rule clearAll if (clearReg);
        clearReg <= False;
    endrule

    rule issueReq if (!clearReg && !busyReg);
        let startAddr = startAddrPipeOut.first;
        startAddrPipeOut.deq;

        let payloadLen = payloadLenPipeOut.first;
        payloadLenPipeOut.deq;

        let pmtu = pmtuPipeOut.first;
        pmtuPipeOut.deq;

        let { isOrigFirst, isOrigLast } = firstLastPipeOut.first;
        firstLastPipeOut.deq;

        let pmtuLen = calcPmtuLen(pmtu);
        let alignedAddr = alignAddrByPMTU(startAddr, pmtu);
        let invalidLen = startAddr - alignedAddr;
        let tmpFirstPktLen = pmtuLen - truncate(invalidLen);
        let totalLen = payloadLen + truncate(invalidLen);

        let totalPktNum = calcPktNumByLenOnly(totalLen, pmtu);
        let { tmpPktNum, pmtuResidue } = truncateLenByPMTU(
            totalLen, pmtu
        );
        let isOnlyPkt     = isLessOrEqOne(totalPktNum);
        let isZeroResidue = isZero(pmtuResidue);
        let firstPktLen = isOnlyPkt ? truncate(payloadLen) : tmpFirstPktLen;
        let lastPktLen  = isOnlyPkt ? truncate(payloadLen) : (
            isZeroResidue ? pmtuLen : zeroExtend(pmtuResidue)
        );

        pktNumReg <= totalPktNum;
        pmtuReg <= pmtu;
        pmtuLenReg <= pmtuLen;
        firstPktLenReg <= firstPktLen;
        lastPktLenReg <= lastPktLen;
        nextAddrReg <= alignedAddr;
        isFirstReg <= True;
        busyReg <= True;

        let addrChunkReq = AddrChunkReq {
            startAddr: startAddr,
            len      : payloadLen,
            pmtu     : pmtu,
            isFirst  : isOrigFirst,
            isLast   : isOrigLast
        };
        dut.srvPort.request.put(addrChunkReq);
        reqQ.enq(addrChunkReq);

        let sgePktMetaData = PktMetaDataSGE {
            firstPktLen: firstPktLen,
            lastPktLen : lastPktLen,
            sgePktNum  : totalPktNum,
            pmtu       : addrChunkReq.pmtu
        };
        sgePktMetaDataRefQ.enq(sgePktMetaData);

        countDown.decr;
        // $display(
        //     "time=%0t: issueReq", $time,
        //     ", startAddr=%h", startAddr,
        //     ", payloadLen=%0d", payloadLen,
        //     ", invalidLen=%0d", invalidLen,
        //     ", totalLen=%0d", totalLen,
        //     ", pmtuResidue=%0d", pmtuResidue,
        //     ", tmpFirstPktLen=%0d", tmpFirstPktLen,
        //     ", totalPktNum=%0d", totalPktNum,
        //     ", firstPktLen=%0d", firstPktLen,
        //     ", lastPktLen=%0d", lastPktLen,
        //     ", pmtuLen=%0d", pmtuLen,
        //     ", pmtu=", fshow(pmtu),
        //     ", isOnlyPkt=", fshow(isOnlyPkt)
        // );
    endrule

    rule expectedRespGen if (busyReg);
        let req = reqQ.first;

        isFirstReg  <= False;
        pktNumReg   <= pktNumReg - 1;
        nextAddrReg <= addrAddPsnMultiplyPMTU(nextAddrReg, oneAsPSN, pmtuReg);

        let isLast  = isLessOrEqOne(pktNumReg);
        if (isLast) begin
            reqQ.deq;
            totalLenQ.enq(req.len);
            busyReg <= False;
        end

        let chunkLen = isFirstReg ? firstPktLenReg : (isLast ? lastPktLenReg : pmtuLenReg);
        let curPktLastFragValidByteNum = calcLastFragValidByteNum(chunkLen);

        let addrChunkResp = AddrChunkResp {
            chunkAddr  : isFirstReg ? req.startAddr : nextAddrReg,
            chunkLen   : chunkLen,
            isFirst    : isFirstReg,
            isLast     : isLast,
            isOrigFirst: req.isFirst,
            isOrigLast : req.isLast
        };
        respQ.enq(addrChunkResp);

        // let sgePktMetaDataRef = PktMetaDataSGE {
        //     curPktLastFragValidByteNum: curPktLastFragValidByteNum,
        //     pktLen                    : chunkLen,
        //     pmtu                      : pmtuReg,
        //     isFirst                   : isFirstReg,
        //     isLast                    : isLast,
        //     isFirstSGE                : req.isFirst,
        //     isLastSGE                 : req.isLast
        // };
        // sgePktMetaDataRefQ.enq(sgePktMetaDataRef);
    endrule

    rule checkResp;
        let addrChunkResp <- dut.srvPort.response.get;
        let expectedResp = respQ.first;
        respQ.deq;

        let expectedTotalLen = totalLenReg + zeroExtend(addrChunkResp.chunkLen);
        if (addrChunkResp.isFirst) begin
            expectedTotalLen = zeroExtend(addrChunkResp.chunkLen);
        end
        totalLenReg <= expectedTotalLen;

        immAssert(
            addrChunkResp.chunkAddr == expectedResp.chunkAddr &&
            addrChunkResp.chunkLen == expectedResp.chunkLen   &&
            addrChunkResp.isFirst == expectedResp.isFirst &&
            addrChunkResp.isLast == expectedResp.isLast,
            "expected addrChunkResp assertion @ mkTestAddrChunkSrv",
            $format(
                "addrChunkResp=", fshow(addrChunkResp),
                " should match expectedResp=", fshow(expectedResp)
            )
        );

        if (addrChunkResp.isLast) begin
            let totalLen = totalLenQ.first;
            totalLenQ.deq;

            immAssert(
                totalLen == expectedTotalLen,
                "totalLen assertion @ mkTestAddrChunkSrv",
                $format(
                    "totalLen=%0d should == expectedTotalLen=%0d",
                    totalLen, expectedTotalLen
                )
            );
        end
        // $display("time=%0t: checkResp", $time);
    endrule

    rule checkPktMetaDataSGE;
        let sgePktMetaData = dut.sgePktMetaDataPipeOut.first;
        dut.sgePktMetaDataPipeOut.deq;
        let sgePktMetaDataRef = sgePktMetaDataRefQ.first;
        sgePktMetaDataRefQ.deq;

        immAssert(
            sgePktMetaData.firstPktLen == sgePktMetaDataRef.firstPktLen &&
            sgePktMetaData.lastPktLen == sgePktMetaDataRef.lastPktLen &&
            sgePktMetaData.sgePktNum == sgePktMetaDataRef.sgePktNum &&
            sgePktMetaData.pmtu == sgePktMetaDataRef.pmtu,
            "sgePktMetaData assertion @ mkTestAddrChunkSrv",
            $format(
                "sgePktMetaData.firstPktLen=%0d should == sgePktMetaDataRef.firstPktLen=%0d",
                sgePktMetaData.firstPktLen, sgePktMetaDataRef.firstPktLen,
                ", sgePktMetaData.lastPktLen=%0d should == sgePktMetaDataRef.lastPktLen=%0d",
                sgePktMetaData.lastPktLen, sgePktMetaDataRef.lastPktLen,
                ", sgePktMetaData.sgePktNum=%0d", sgePktMetaData.sgePktNum,
                " should == sgePktMetaDataRef.sgePktNum=%0d", sgePktMetaDataRef.sgePktNum,
                ", sgePktMetaData.pmtu=", fshow(sgePktMetaData.pmtu),
                " should == sgePktMetaData.pmtu=", fshow(sgePktMetaData.pmtu)
            )
        );
        // $display("time=%0t: checkPktMetaDataSGE", $time);
    endrule
endmodule

(* doc = "testcase" *)
module mkTestDmaReadCntrlNormalCase(Empty);
    let normalOrCancelCase = True;
    let result <- mkTestDmaReadCntrlNormalOrCancelCase(normalOrCancelCase);
endmodule

(* doc = "testcase" *)
module mkTestDmaReadCntrlCancelCase(Empty);
    let normalOrCancelCase = False;
    let result <- mkTestDmaReadCntrlNormalOrCancelCase(normalOrCancelCase);
endmodule

typedef enum {
    TEST_DMA_CNTRL_INIT,
    TEST_DMA_CNTRL_RUN,
    TEST_DMA_CNTRL_RESET
} TestDmaCntrlState deriving(Bits, Eq, FShow);

module mkTestDmaReadCntrlNormalOrCancelCase#(Bool normalOrCancelCase)(Empty);
    let minPayloadLen = 2048;
    let maxPayloadLen = 8192;
    let qpType = IBV_QPT_XRC_SEND;
    let pmtuVec = vec(
        IBV_MTU_256,
        IBV_MTU_512,
        IBV_MTU_1024,
        IBV_MTU_2048,
        IBV_MTU_4096
    );

    Reg#(Bool) clearReg <- mkReg(True);
    Reg#(Bool) canceledReg <- mkReg(False);
    Reg#(TotalFragNum) remainingFragNumReg <- mkReg(0);
    FIFOF#(TotalFragNum) totalFragNumQ <- mkFIFOF;

    PipeOut#(Bool) randomCancelPipeOut <- mkGenericRandomPipeOut;
    Reg#(Bool)  isFinalRespLastFragReg <- mkReg(False);

    PipeOut#(ADDR)  startAddrPipeOut <- mkGenericRandomPipeOut;
    let payloadLenPipeOut <- mkRandomLenPipeOut(minPayloadLen, maxPayloadLen);
    let pmtuPipeOut <- mkRandomItemFromVec(pmtuVec);

    let simDmaReadSrv <- mkSimDmaReadSrv;
    let dut <- mkDmaReadCntrl(clearReg, simDmaReadSrv);

    Reg#(TestDmaCntrlState) stateReg <- mkReg(TEST_DMA_CNTRL_INIT);
    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    mkSink(dut.sgePktMetaDataPipeOut);
    mkSink(dut.sglTotalPayloadLenMetaDataPipeOut);
    mkSink(dut.sgeMergedMetaDataPipeOut);

    rule clearAll if (stateReg == TEST_DMA_CNTRL_INIT);
        clearReg <= False;
        canceledReg <= False;
        remainingFragNumReg <= 0;
        isFinalRespLastFragReg <= False;
        totalFragNumQ.clear;

        stateReg <= TEST_DMA_CNTRL_RUN;
        // $display("time=%0t: clearAll", $time);
    endrule

    rule issueReq if (stateReg == TEST_DMA_CNTRL_RUN);
        let startAddr = startAddrPipeOut.first;
        startAddrPipeOut.deq;

        let payloadLen = payloadLenPipeOut.first;
        payloadLenPipeOut.deq;

        let pmtu = pmtuPipeOut.first;
        pmtuPipeOut.deq;

        let {
            pmtuLen, firstPktLen, lastPktLen, sgePktNum, secondChunkStartAddr //, isSinglePkt
        } = calcPktNumAndPktLenByAddrAndPMTU(startAddr, payloadLen, pmtu);
        let {
            firstPktFragNum, firstPktByteEn, firstPktFragValidByteNum
        } = calcTotalFragNumByLength(zeroExtend(firstPktLen));
        let midPktLen = payloadLen - zeroExtend(firstPktLen);
        if (isLessOrEqOne(sgePktNum)) begin
            lastPktLen = 0;
        end
        else begin
            midPktLen = payloadLen - zeroExtend(firstPktLen) - zeroExtend(lastPktLen);
        end
        let {
            lastPktFragNum, lastPktByteEn, lastPktFragValidByteNum
        } = calcTotalFragNumByLength(zeroExtend(lastPktLen));
        let {
            midPktFragNum, midPktByteEn, midPktFragValidByteNum
        } = calcTotalFragNumByLength(midPktLen);
        let totalFragNum = firstPktFragNum + midPktFragNum + lastPktFragNum;
        totalFragNumQ.enq(totalFragNum);

        let sge = ScatterGatherElem {
            laddr  : startAddr,
            len    : payloadLen,
            lkey   : dontCareValue,
            isFirst: True,
            isLast : True
        };
        let dummySGE = sge;
        // dummySGE.isFirst = False;
        // dummySGE.isLast = False;

        let sgl = vec(sge, dummySGE, dummySGE, dummySGE, dummySGE, dummySGE, dummySGE, dummySGE);

        let dmaReadCntrlReq = DmaReadCntrlReq {
            pmtu              : pmtu,
            sglDmaReadMetaData: DmaReadMetaDataSGL {
                sgl           : sgl,
                sqpn          : getDefaultQPN,
                wrID          : dontCareValue
                // initiator: DMA_SRC_RQ_RD,
                // startAddr: startAddr,
                // len      : payloadLen,
            }
        };

        dut.srvPort.request.put(dmaReadCntrlReq);
        countDown.decr;
        // $display(
        //     "time=%0t: issueReq", $time,
        //     ", startAddr=%h", startAddr,
        //     ", secondChunkStartAddr=%h", secondChunkStartAddr,
        //     ", payloadLen=%0d", payloadLen,
        //     ", pmtu=", fshow(pmtu),
        //     ", sgePktNum=%0d", sgePktNum,
        //     ", firstPktLen=%0d", firstPktLen,
        //     ", lastPktLen=%0d", lastPktLen,
        //     ", pmtuLen=%0d", pmtuLen,
        //     ", totalFragNum=%0d", totalFragNum,
        //     ", firstPktFragNum=%0d", firstPktFragNum,
        //     ", lastPktFragNum=%0d", lastPktFragNum,
        //     ", midPktLen=%0d", midPktLen
        //     // ", pmtuMask=%h", pmtuMask,
        //     // ", truncatedPktNum=%0d", truncatedPktNum,
        //     // ", addrLowPart=%0d", addrLowPart,
        //     // ", lenLowPart=%0d", lenLowPart,
        //     // ", tmpLastPktLen=%0d", tmpLastPktLen,
        //     // ", hasResidue=", fshow(hasResidue),
        //     // ", hasExtraPkt=", fshow(hasExtraPkt),
        //     // ", notFullPkt=", fshow(notFullPkt)
        // );
    endrule

    rule checkResp if (stateReg == TEST_DMA_CNTRL_RUN && !dut.dmaCntrl.isIdle);
        let dmaReadCntrlResp <- dut.srvPort.response.get;
        // let isOrigFirst = dmaReadCntrlResp.isOrigFirst;
        // let isOrigLast = dmaReadCntrlResp.isOrigLast;
        isFinalRespLastFragReg <= dmaReadCntrlResp.dmaReadResp.dataStream.isLast;

        let isFirstFrag = dmaReadCntrlResp.isOrigFirst && dmaReadCntrlResp.dmaReadResp.dataStream.isFirst;
        let isLastFrag  = dmaReadCntrlResp.isOrigLast && dmaReadCntrlResp.dmaReadResp.dataStream.isLast;

        let totalFragNum = totalFragNumQ.first;
        let remainingFragNum = remainingFragNumReg;
        if (!isLessOrEqOne(totalFragNum)) begin
            if (isFirstFrag) begin
                remainingFragNum = totalFragNum - 2;
            end
            else begin
                remainingFragNum = remainingFragNumReg - 1;
            end
        end
        remainingFragNumReg <= remainingFragNum;

        if (isLastFrag) begin
            totalFragNumQ.deq;

            immAssert(
                isZero(remainingFragNumReg),
                "remaining fragNum assertion @ mkTestDmaReadCntrlNormalOrCancelCase",
                $format(
                    "remainingFragNumReg=%0d should be zero when", remainingFragNumReg,
                    " isOrigFirst=", fshow(isFirstFrag),
                    " and isLastFrag=", fshow(isLastFrag)
                )
            );
        end

        if (!normalOrCancelCase) begin
            let shouldCancel = randomCancelPipeOut.first;
            randomCancelPipeOut.deq;

            if (shouldCancel && !canceledReg) begin
                dut.dmaCntrl.cancel;
                canceledReg <= True;
                // $display("time=%0t: dmaCntrl.cancel", $time);
            end
        end
        // $display(
        //     "time=%0t: checkResp", $time,
        //     ", remainingFragNumReg=%0d", remainingFragNumReg,
        //     ", isFirst=", fshow(dmaReadCntrlResp.dmaReadResp.dataStream.isFirst),
        //     ", isLast=", fshow(dmaReadCntrlResp.dmaReadResp.dataStream.isLast),
        //     ", isOrigFirst=", fshow(dmaReadCntrlResp.isOrigFirst),
        //     ", isOrigLast=", fshow(dmaReadCntrlResp.isOrigLast)
        // );
    endrule

    rule waitUntilGracefulStop if (stateReg == TEST_DMA_CNTRL_RUN && dut.dmaCntrl.isIdle);
        immAssert(
            isFinalRespLastFragReg,
            "isFinalRespLastFragReg assertion @ mkTestDmaReadCntrlNormalOrCancelCase",
            $format(
                "isFinalRespLastFragReg=", fshow(isFinalRespLastFragReg),
                " should be true, when dut.dmaCntrl.isIdle=", fshow(dut.dmaCntrl.isIdle)
            )
        );

        stateReg <= TEST_DMA_CNTRL_RESET;
        // $display("time=%0t: waitUntilGracefulStop, dmaCntrl.isIdle", $time);
    endrule

    rule loop if (stateReg == TEST_DMA_CNTRL_RESET);
        clearReg <= True;
        stateReg <= TEST_DMA_CNTRL_INIT;
    endrule
endmodule

(* doc = "testcase" *)
module mkTestMergeNormalPayloadEachSGE(Empty);
    let minPayloadLen = 2048;
    let maxPayloadLen = 8192;
    let result <- mkTestMergeNormalOrSmallPayloadEachSGE(minPayloadLen, maxPayloadLen);
endmodule

(* doc = "testcase" *)
module mkTestMergeSmallPayloadEachSGE(Empty);
    let minPayloadLen = 1;
    let maxPayloadLen = 7;
    let result <- mkTestMergeNormalOrSmallPayloadEachSGE(minPayloadLen, maxPayloadLen);
endmodule

typedef enum {
    TEST_MERGE_EACH_SGE_INIT,
    TEST_MERGE_EACH_SGE_PREPARE,
    TEST_MERGE_EACH_SGE_ISSUE,
    TEST_MERGE_EACH_SGE_RUN
} TestMergePayloadStateSGE deriving(Bits, Eq, FShow);

module mkTestMergeNormalOrSmallPayloadEachSGE#(
    // Both min and max are inclusive
    Length minPayloadLen, Length maxPayloadLen
)(Empty);
    let qpType = IBV_QPT_XRC_SEND;
    let pmtuVec = vec(
        IBV_MTU_256,
        IBV_MTU_512,
        IBV_MTU_1024,
        IBV_MTU_2048,
        IBV_MTU_4096
    );

    Reg#(Bool) clearReg <- mkReg(True);
    Reg#(TotalFragNum) remainingFragNumReg <- mkReg(0);
    Reg#(IdxSGL) sglIdxReg <- mkReg(0);
    Reg#(Length) totalLenReg <- mkRegU;

    Vector#(MAX_SGE, Reg#(ScatterGatherElem)) sglRegVec <- replicateM(mkRegU);
    FIFOF#(DataStream) sgePayloadOutQ <- mkFIFOF;
    FIFOF#(Tuple2#(TotalFragNum, ByteEn)) sgeRefQ <- mkSizedFIFOF(valueOf(MAX_SGE));

    PipeOut#(ADDR)  startAddrPipeOut <- mkGenericRandomPipeOut;
    let payloadLenPipeOut <- mkRandomLenPipeOut(minPayloadLen, maxPayloadLen);
    let pmtuPipeOut <- mkRandomItemFromVec(pmtuVec);

    let simDmaReadSrv <- mkSimDmaReadSrv;
    let dmaReadCntrl <- mkDmaReadCntrl(clearReg, simDmaReadSrv);

    let dut <- mkMergePayloadEachSGE(
        clearReg, dmaReadCntrl.sgePktMetaDataPipeOut, toPipeOut(sgePayloadOutQ)
    );

    Reg#(TestMergePayloadStateSGE) stateReg <- mkReg(TEST_MERGE_EACH_SGE_INIT);
    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    // mkSink(dut.sgePktMetaDataPipeOut);
    mkSink(dmaReadCntrl.sglTotalPayloadLenMetaDataPipeOut);
    mkSink(dmaReadCntrl.sgeMergedMetaDataPipeOut);

    rule clearAll if (stateReg == TEST_MERGE_EACH_SGE_INIT);
        clearReg <= False;
        sglIdxReg <= 0;
        remainingFragNumReg <= 0;

        stateReg <= TEST_MERGE_EACH_SGE_PREPARE;
        // $display("time=%0t: clearAll", $time);
    endrule

    rule genSGE if (stateReg == TEST_MERGE_EACH_SGE_PREPARE);
        let startAddr = startAddrPipeOut.first;
        startAddrPipeOut.deq;

        let payloadLen = payloadLenPipeOut.first;
        payloadLenPipeOut.deq;

        let isFirst = isZero(sglIdxReg);
        let isLast = isAllOnesR(sglIdxReg);
        let sge = ScatterGatherElem {
            laddr  : startAddr,
            len    : payloadLen,
            lkey   : dontCareValue,
            isFirst: isFirst,
            isLast : isLast
        };
        sglRegVec[sglIdxReg] <= sge;

        let totalLen = totalLenReg;
        if (isFirst) begin
            totalLen = payloadLen;
        end
        else begin
            totalLen = totalLenReg + payloadLen;
        end
        totalLenReg <= totalLen;

        if (isLast) begin
            sglIdxReg <= 0;
            stateReg <= TEST_MERGE_EACH_SGE_ISSUE;
        end
        else begin
            sglIdxReg <= sglIdxReg + 1;
        end

        let {
            sgeFragNum, lastFragByteEn, lastFragValidByteNum
        } = calcTotalFragNumByLength(payloadLen);
        sgeRefQ.enq(tuple2(sgeFragNum, lastFragByteEn));

        countDown.decr;
        // $display(
        //     "time=%0t: genSGE", $time,
        //     ", sglIdxReg=%0d", sglIdxReg,
        //     ", startAddr=%h", startAddr,
        //     ", payloadLen=%0d", payloadLen,
        //     ", totalLen=%0d", totalLen,
        //     ", sgeFragNum=%0d", sgeFragNum,
        //     ", lastFragValidByteNum=%0d", lastFragValidByteNum
        // );
    endrule

    rule issueDmaReadCntrlReq if (stateReg == TEST_MERGE_EACH_SGE_ISSUE);
        let sgl = readVReg(sglRegVec);
        let pmtu = pmtuPipeOut.first;
        pmtuPipeOut.deq;

        let dmaReadCntrlReq = DmaReadCntrlReq {
            pmtu              : pmtu,
            sglDmaReadMetaData: DmaReadMetaDataSGL {
                sgl           : sgl,
                sqpn          : getDefaultQPN,
                wrID          : dontCareValue
                // initiator: DMA_SRC_RQ_RD,
                // startAddr: startAddr,
                // len      : payloadLen,
            }
        };

        dmaReadCntrl.srvPort.request.put(dmaReadCntrlReq);
        stateReg <= TEST_MERGE_EACH_SGE_RUN;
        // $display(
        //     "time=%0t: issueDmaReadCntrlReq", $time,
        //     ", pmtu=", fshow(pmtu)
        // );
        // for (Integer idx = 0; idx < valueOf(MAX_SGE); idx = idx + 1) begin
        //     let sge = sglRegVec[idx];
        //     let {
        //         pmtuLen, firstPktLen, lastPktLen, sgePktNum, secondChunkStartAddr //, isSinglePkt
        //     } = calcPktNumAndPktLenByAddrAndPMTU(sge.laddr, sge.len, pmtu);
        //     let firstPktFragNum = calcFragNumByPktLen(firstPktLen);
        //     let lastPktFragNum = calcFragNumByPktLen(lastPktLen);

        //     $display(
        //         "time=%0t: issueDmaReadCntrlReq", $time,
        //         ", SGE idx=%0d", idx,
        //         ", sge.laddr=%h", sge.laddr,
        //         ", sgePktNum=%0d", sgePktNum,
        //         ", firstPktLen=%0d", firstPktLen,
        //         ", lastPktLen=%0d", lastPktLen,
        //         ", pmtuLen=%0d", pmtuLen,
        //         ", firstPktFragNum=%0d", firstPktFragNum,
        //         ", lastPktFragNum=%0d", lastPktFragNum
        //     );
        // end
    endrule

    rule recvDmaReadCntrlResp;
        let dmaReadCntrlResp <- dmaReadCntrl.srvPort.response.get;
        sgePayloadOutQ.enq(dmaReadCntrlResp.dmaReadResp.dataStream);
    endrule

    rule checkMergedPayloadSGE if (stateReg == TEST_MERGE_EACH_SGE_RUN);
        let { sgeFragNum, lastFragByteEn } = sgeRefQ.first;
        // let {
        //     sgeFragNum, lastFragByteEn, lastFragValidByteNum
        // } = calcTotalFragNumByLength(refSGE.len);

        let payloadFrag = dut.first;
        dut.deq;
        if (!payloadFrag.isLast) begin
            if (payloadFrag.isFirst) begin
                remainingFragNumReg <= sgeFragNum - 2;
            end
            else begin
                remainingFragNumReg <= remainingFragNumReg - 1;
            end
        end

        if (isZero(remainingFragNumReg)) begin
            immAssert(
                payloadFrag.isFirst || payloadFrag.isLast,
                "payloadFrag isFirst isLast assertion @ mkTestMergeNormalOrSmallPayloadEachSGE",
                $format(
                    "payloadFrag.isFirst=", fshow(payloadFrag.isFirst),
                    " or payloadFrag.isLast=", fshow(payloadFrag.isLast),
                    " should be true when remainingFragNumReg=%0d",
                    remainingFragNumReg
                )
            );
        end

        if (payloadFrag.isFirst) begin
            immAssert(
                isZero(remainingFragNumReg),
                "remainingFragNumReg assertion @ mkTestMergeNormalOrSmallPayloadEachSGE",
                $format(
                    "remainingFragNumReg=%0d", remainingFragNumReg,
                    " should be zero when payloadFrag.isFirst=",
                    fshow(payloadFrag.isFirst)
                )
            );
        end

        if (payloadFrag.isLast) begin
            sgeRefQ.deq;

            if (isAllOnesR(sglIdxReg)) begin
                sglIdxReg <= 0;
                stateReg <= TEST_MERGE_EACH_SGE_INIT;
            end
            else begin
                sglIdxReg <= sglIdxReg + 1;
            end

            immAssert(
                isZero(remainingFragNumReg),
                "remainingFragNumReg assertion @ mkTestMergeNormalOrSmallPayloadEachSGE",
                $format(
                    "remainingFragNumReg=%0d", remainingFragNumReg,
                    " should be zero when payloadFrag.isLast=",
                    fshow(payloadFrag.isLast)
                )
            );
            immAssert(
                payloadFrag.byteEn == lastFragByteEn,
                "lastFragByteEn assertion @ mkTestMergeNormalOrSmallPayloadEachSGE",
                $format(
                    "payloadFrag.byteEn=%h", payloadFrag.byteEn,
                    " should == lastFragByteEn=%h", lastFragByteEn,
                    ", when payloadFrag.isLast=", fshow(payloadFrag.isLast)
                )
            );
        end
        else begin
            immAssert(
                isAllOnesR(payloadFrag.byteEn),
                "payloadFrag.byteEn assertion @ mkTestMergeNormalOrSmallPayloadEachSGE",
                $format(
                    "payloadFrag.byteEn=%h", payloadFrag.byteEn,
                    " should be all ones when payloadFrag.isLast=",
                    fshow(payloadFrag.isLast)
                )
            );
        end
        // $display(
        //     "time=%0t: checkMergedPayloadSGE", $time,
        //     ", refSGE.len=%0d", refSGE.len,
        //     ", sgeFragNum=%0d", sgeFragNum,
        //     ", lastFragValidByteNum=%0d", lastFragValidByteNum,
        //     ", lastFragByteEn=%h", lastFragByteEn,
        //     ", remainingFragNumReg=%0d", remainingFragNumReg,
        //     ", payloadFrag.isFirst=", fshow(payloadFrag.isFirst),
        //     ", payloadFrag.isLast=", fshow(payloadFrag.isLast),
        //     ", payloadFrag.byteEn=%h", payloadFrag.byteEn
        // );
    endrule
endmodule

(* doc = "testcase" *)
module mkTestMergeNormalPayloadAllSGE(Empty);
    let minPayloadLen = 2048;
    let maxPayloadLen = 8192;
    let result <- mkTestMergeNormalOrSmallPayloadAllSGE(minPayloadLen, maxPayloadLen);
endmodule

(* doc = "testcase" *)
module mkTestMergeSmallPayloadAllSGE(Empty);
    let minPayloadLen = 1;
    let maxPayloadLen = 7;
    let result <- mkTestMergeNormalOrSmallPayloadAllSGE(minPayloadLen, maxPayloadLen);
endmodule

typedef enum {
    TEST_MERGE_ALL_SGE_INIT,
    TEST_MERGE_ALL_SGE_PREPARE,
    TEST_MERGE_ALL_SGE_ISSUE,
    TEST_MERGE_ALL_SGE_RUN
} TestMergePayloadStateSGL deriving(Bits, Eq, FShow);

module mkTestMergeNormalOrSmallPayloadAllSGE#(
    // Both min and max are inclusive
    Length minPayloadLen, Length maxPayloadLen
)(Empty);
    let qpType = IBV_QPT_XRC_SEND;
    let pmtuVec = vec(
        IBV_MTU_256,
        IBV_MTU_512,
        IBV_MTU_1024,
        IBV_MTU_2048,
        IBV_MTU_4096
    );

    Reg#(Bool) clearReg <- mkReg(True);
    Reg#(TotalFragNum) remainingFragNumReg <- mkReg(0);
    Reg#(IdxSGL) sglIdxReg <- mkReg(0);
    Reg#(Length) totalLenReg <- mkRegU;

    Vector#(MAX_SGE, Reg#(ScatterGatherElem)) sglRegVec <- replicateM(mkRegU);
    FIFOF#(DataStream) sgePayloadOutQ <- mkFIFOF;
    FIFOF#(Tuple2#(TotalFragNum, ByteEn)) sglRefQ <- mkFIFOF;

    PipeOut#(ADDR)  startAddrPipeOut <- mkGenericRandomPipeOut;
    let payloadLenPipeOut <- mkRandomLenPipeOut(minPayloadLen, maxPayloadLen);
    let pmtuPipeOut <- mkRandomItemFromVec(pmtuVec);

    let simDmaReadSrv <- mkSimDmaReadSrv;
    let dmaReadCntrl <- mkDmaReadCntrl(clearReg, simDmaReadSrv);

    let sgeMergedPayloadPipeOut <- mkMergePayloadEachSGE(
        clearReg, dmaReadCntrl.sgePktMetaDataPipeOut, toPipeOut(sgePayloadOutQ)
    );

    let dut <- mkMergePayloadAllSGE(
        clearReg, dmaReadCntrl.sgeMergedMetaDataPipeOut, sgeMergedPayloadPipeOut
    );

    Reg#(TestMergePayloadStateSGL) stateReg <- mkReg(TEST_MERGE_ALL_SGE_INIT);
    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    // mkSink(dmaReadCntrl.sgePktMetaDataPipeOut);
    // mkSink(dmaReadCntrl.sgeMergedMetaDataPipeOut);
    mkSink(dmaReadCntrl.sglTotalPayloadLenMetaDataPipeOut);

    rule clearAll if (stateReg == TEST_MERGE_ALL_SGE_INIT);
        clearReg <= False;
        sglIdxReg <= 0;
        remainingFragNumReg <= 0;

        stateReg <= TEST_MERGE_ALL_SGE_PREPARE;
        // $display("time=%0t: clearAll", $time);
    endrule

    rule genSGE if (stateReg == TEST_MERGE_ALL_SGE_PREPARE);
        let startAddr = startAddrPipeOut.first;
        startAddrPipeOut.deq;

        let payloadLen = payloadLenPipeOut.first;
        payloadLenPipeOut.deq;

        let isFirst = isZero(sglIdxReg);
        let isLast = isAllOnesR(sglIdxReg);
        let sge = ScatterGatherElem {
            laddr  : startAddr,
            len    : payloadLen,
            lkey   : dontCareValue,
            isFirst: isFirst,
            isLast : isLast
        };
        sglRegVec[sglIdxReg] <= sge;

        let totalLen = totalLenReg;
        if (isFirst) begin
            totalLen = payloadLen;
        end
        else begin
            totalLen = totalLenReg + payloadLen;
        end
        totalLenReg <= totalLen;

        if (isLast) begin
            sglIdxReg <= 0;
            stateReg <= TEST_MERGE_ALL_SGE_ISSUE;
        end
        else begin
            sglIdxReg <= sglIdxReg + 1;
        end

        let {
            sgeFragNum, sgeLastFragByteEn, sgeLastFragValidByteNum
        } = calcTotalFragNumByLength(payloadLen);
        countDown.decr;
        // $display(
        //     "time=%0t: genSGE", $time,
        //     ", sglIdxReg=%0d", sglIdxReg,
        //     ", startAddr=%h", startAddr,
        //     ", payloadLen=%0d", payloadLen,
        //     ", sgeFragNum=%0d", sgeFragNum,
        //     ", sgeLastFragByteEn=%h", sgeLastFragByteEn,
        //     ", sgeLastFragValidByteNum=%0d", sgeLastFragValidByteNum
        // );
    endrule

    rule issueDmaReadCntrlReq if (stateReg == TEST_MERGE_ALL_SGE_ISSUE);
        let sgl = readVReg(sglRegVec);
        let pmtu = pmtuPipeOut.first;
        pmtuPipeOut.deq;

        let dmaReadCntrlReq = DmaReadCntrlReq {
            pmtu              : pmtu,
            sglDmaReadMetaData: DmaReadMetaDataSGL {
                sgl           : sgl,
                sqpn          : getDefaultQPN,
                wrID          : dontCareValue
                // initiator: DMA_SRC_RQ_RD,
                // startAddr: startAddr,
                // len      : payloadLen,
            }
        };

        dmaReadCntrl.srvPort.request.put(dmaReadCntrlReq);

        stateReg <= TEST_MERGE_ALL_SGE_RUN;
        let {
            sglFragNum, sglLastFragByteEn, sglLastFragValidByteNum
        } = calcTotalFragNumByLength(totalLenReg);
        sglRefQ.enq(tuple2(sglFragNum, sglLastFragByteEn));
        // $display(
        //     "time=%0t: issueDmaReadCntrlReq", $time,
        //     ", pmtu=", fshow(pmtu),
        //     ", totalLenReg=%0d", totalLenReg,
        //     ", sglFragNum=%0d", sglFragNum,
        //     ", sglLastFragByteEn=%h", sglLastFragByteEn,
        //     ", sglLastFragValidByteNum=%0d", sglLastFragValidByteNum
        // );
        // for (Integer idx = 0; idx < valueOf(MAX_SGE); idx = idx + 1) begin
        //     let sge = sglRegVec[idx];
        //     let {
        //         pmtuLen, sgeFirstPktLen, sgeLastPktLen, sgePktNum, secondChunkStartAddr //, isSinglePkt
        //     } = calcPktNumAndPktLenByAddrAndPMTU(sge.laddr, sge.len, pmtu);
        //     let sgeFirstPktFragNum = calcFragNumByPktLen(sgeFirstPktLen);
        //     let sgeLastPktFragNum = calcFragNumByPktLen(sgeLastPktLen);

        //     $display(
        //         "time=%0t: issueDmaReadCntrlReq", $time,
        //         ", SGE idx=%0d", idx,
        //         ", sge.laddr=%h", sge.laddr,
        //         ", sgePktNum=%0d", sgePktNum,
        //         ", sgeFirstPktLen=%0d", sgeFirstPktLen,
        //         ", sgeLastPktLen=%0d", sgeLastPktLen,
        //         ", pmtuLen=%0d", pmtuLen,
        //         ", sgeFirstPktFragNum=%0d", sgeFirstPktFragNum,
        //         ", sgeLastPktFragNum=%0d", sgeLastPktFragNum
        //     );
        // end
    endrule

    rule recvDmaReadCntrlResp;
        let dmaReadCntrlResp <- dmaReadCntrl.srvPort.response.get;
        sgePayloadOutQ.enq(dmaReadCntrlResp.dmaReadResp.dataStream);
        // $display(
        //     "time=%0t: recvDmaReadCntrlResp", $time,
        //     ", dmaReadCntrlResp=", fshow(dmaReadCntrlResp)
        // );
    endrule

    rule checkMergedPayloadSGL if (stateReg == TEST_MERGE_ALL_SGE_RUN);
        let { sglFragNum, sglLastFragByteEn } = sglRefQ.first;

        let payloadFrag = dut.first;
        dut.deq;
        if (!payloadFrag.isLast) begin
            if (payloadFrag.isFirst) begin
                remainingFragNumReg <= sglFragNum - 2;
            end
            else begin
                remainingFragNumReg <= remainingFragNumReg - 1;
            end
        end

        if (isZero(remainingFragNumReg)) begin
            immAssert(
                payloadFrag.isFirst || payloadFrag.isLast,
                "payloadFrag isFirst isLast assertion @ mkTestMergeNormalOrSmallPayloadAllSGE",
                $format(
                    "payloadFrag.isFirst=", fshow(payloadFrag.isFirst),
                    " or payloadFrag.isLast=", fshow(payloadFrag.isLast),
                    " should be true when remainingFragNumReg=%0d",
                    remainingFragNumReg
                )
            );
        end

        if (payloadFrag.isFirst) begin
            immAssert(
                isZero(remainingFragNumReg),
                "remainingFragNumReg assertion @ mkTestMergeNormalOrSmallPayloadAllSGE",
                $format(
                    "remainingFragNumReg=%0d", remainingFragNumReg,
                    " should be zero when payloadFrag.isFirst=",
                    fshow(payloadFrag.isFirst)
                )
            );
        end

        if (payloadFrag.isLast) begin
            sglRefQ.deq;
            stateReg <= TEST_MERGE_ALL_SGE_INIT;

            immAssert(
                isZero(remainingFragNumReg),
                "remainingFragNumReg assertion @ mkTestMergeNormalOrSmallPayloadAllSGE",
                $format(
                    "remainingFragNumReg=%0d", remainingFragNumReg,
                    " should be zero when payloadFrag.isLast=",
                    fshow(payloadFrag.isLast)
                )
            );
            immAssert(
                payloadFrag.byteEn == sglLastFragByteEn,
                "sglLastFragByteEn assertion @ mkTestMergeNormalOrSmallPayloadAllSGE",
                $format(
                    "payloadFrag.byteEn=%h", payloadFrag.byteEn,
                    " should == sglLastFragByteEn=%h", sglLastFragByteEn,
                    ", when payloadFrag.isLast=", fshow(payloadFrag.isLast)
                )
            );
        end
        else begin
            immAssert(
                isAllOnesR(payloadFrag.byteEn),
                "payloadFrag.byteEn assertion @ mkTestMergeNormalOrSmallPayloadAllSGE",
                $format(
                    "payloadFrag.byteEn=%h", payloadFrag.byteEn,
                    " should be all ones when payloadFrag.isLast=",
                    fshow(payloadFrag.isLast)
                )
            );
        end
        // $display(
        //     "time=%0t: checkMergedPayloadSGL", $time,
        //     ", sglFragNum=%0d", sglFragNum,
        //     // ", lastFragValidByteNum=%0d", lastFragValidByteNum,
        //     ", sglLastFragByteEn=%h", sglLastFragByteEn,
        //     ", remainingFragNumReg=%0d", remainingFragNumReg,
        //     ", payloadFrag.isFirst=", fshow(payloadFrag.isFirst),
        //     ", payloadFrag.isLast=", fshow(payloadFrag.isLast),
        //     ", payloadFrag.byteEn=%h", payloadFrag.byteEn
        // );
    endrule
endmodule

(* doc = "testcase" *)
module mkTestAdjustNormalPayloadSegmentCase(Empty);
    let minPayloadLen = 2048;
    let maxPayloadLen = 8192;
    let result <- mkTestAdjustNormalOrSmallPayloadSegment(minPayloadLen, maxPayloadLen);
endmodule

(* doc = "testcase" *)
module mkTestAdjustSmallPayloadSegmentCase(Empty);
    let minPayloadLen = 1;
    let maxPayloadLen = 7;
    let result <- mkTestAdjustNormalOrSmallPayloadSegment(minPayloadLen, maxPayloadLen);
endmodule

typedef enum {
    TEST_ADJUST_PAYLOAD_INIT,
    TEST_ADJUST_PAYLOAD_PREPARE,
    TEST_ADJUST_PAYLOAD_ISSUE,
    TEST_ADJUST_PAYLOAD_RECV,
    TEST_ADJUST_PAYLOAD_RUN
} TestAdjustPayloadState deriving(Bits, Eq, FShow);

module mkTestAdjustNormalOrSmallPayloadSegment#(
    // Both min and max are inclusive
    Length minPayloadLen, Length maxPayloadLen
)(Empty);
    let qpType = IBV_QPT_XRC_SEND;
    let pmtuVec = vec(
        IBV_MTU_256,
        IBV_MTU_512,
        IBV_MTU_1024,
        IBV_MTU_2048,
        IBV_MTU_4096
    );

    Reg#(Bool) clearReg <- mkReg(True);
    Reg#(Bool) isFirstPktReg <- mkRegU;
    Reg#(PktNum) remainingPktNumReg <- mkRegU;
    Reg#(PktFragNum) remainingFragNumReg <- mkReg(0);
    Reg#(IdxSGL) sglIdxReg <- mkReg(0);

    Vector#(MAX_SGE, Reg#(ScatterGatherElem)) sglRegVec <- replicateM(mkRegU);
    FIFOF#(DataStream) sgePayloadOutQ <- mkFIFOF;
    FIFOF#(PMTU) pmtuQ <- mkFIFOF;
    FIFOF#(AdjustedTotalPayloadMetaData) adjustedTotalPayloadMetaDataQ <- mkFIFOF;
    FIFOF#(Tuple3#(AdjustedTotalPayloadMetaData, PktFragNum, ByteEnBitNum)) adjustedTotalPayloadMetaDataRefQ <- mkFIFOF;

    PipeOut#(ADDR) remoteAddrPipeOut <- mkGenericRandomPipeOut;
    PipeOut#(ADDR)  localAddrPipeOut <- mkGenericRandomPipeOut;
    let payloadLenPipeOut <- mkRandomLenPipeOut(minPayloadLen, maxPayloadLen);
    let pmtuPipeOut <- mkRandomItemFromVec(pmtuVec);

    let simDmaReadSrv <- mkSimDmaReadSrv;
    let dmaReadCntrl <- mkDmaReadCntrl(clearReg, simDmaReadSrv);

    let sgeMergedPayloadPipeOut <- mkMergePayloadEachSGE(
        clearReg, dmaReadCntrl.sgePktMetaDataPipeOut, toPipeOut(sgePayloadOutQ)
    );
    let sglMergedPayloadPipeOut <- mkMergePayloadAllSGE(
        clearReg, dmaReadCntrl.sgeMergedMetaDataPipeOut, sgeMergedPayloadPipeOut
    );
    let dut <- mkAdjustPayloadSegment(
        clearReg, toPipeOut(adjustedTotalPayloadMetaDataQ), sglMergedPayloadPipeOut
    );

    Reg#(TestAdjustPayloadState) stateReg <- mkReg(TEST_ADJUST_PAYLOAD_INIT);
    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    // mkSink(dmaReadCntrl.sgePktMetaDataPipeOut);
    // mkSink(dmaReadCntrl.sgeMergedMetaDataPipeOut);
    // mkSink(dmaReadCntrl.totalPayloadMetaDataPipeOut);

    rule clearAll if (stateReg == TEST_ADJUST_PAYLOAD_INIT);
        clearReg <= False;
        sglIdxReg <= 0;
        remainingFragNumReg <= 0;

        stateReg <= TEST_ADJUST_PAYLOAD_PREPARE;
        // $display("time=%0t: clearAll", $time);
    endrule

    rule genSGE if (stateReg == TEST_ADJUST_PAYLOAD_PREPARE);
        let localAddr = localAddrPipeOut.first;
        localAddrPipeOut.deq;

        let payloadLen = payloadLenPipeOut.first;
        payloadLenPipeOut.deq;

        let isFirst = isZero(sglIdxReg);
        let isLast = isAllOnesR(sglIdxReg);
        let sge = ScatterGatherElem {
            laddr  : localAddr,
            len    : payloadLen,
            lkey   : dontCareValue,
            isFirst: isFirst,
            isLast : isLast
        };
        sglRegVec[sglIdxReg] <= sge;

        if (isLast) begin
            sglIdxReg <= 0;
            stateReg <= TEST_ADJUST_PAYLOAD_ISSUE;
        end
        else begin
            sglIdxReg <= sglIdxReg + 1;
        end

        let {
            sgeFragNum, sgeLastFragByteEn, sgeLastFragValidByteNum
        } = calcTotalFragNumByLength(payloadLen);
        countDown.decr;
        // $display(
        //     "time=%0t: genSGE", $time,
        //     ", sglIdxReg=%0d", sglIdxReg,
        //     ", localAddr=%h", localAddr,
        //     ", payloadLen=%0d", payloadLen,
        //     ", sgeFragNum=%0d", sgeFragNum,
        //     ", sgeLastFragByteEn=%h", sgeLastFragByteEn,
        //     ", sgeLastFragValidByteNum=%0d", sgeLastFragValidByteNum
        // );
    endrule

    rule issueDmaReadCntrlReq if (stateReg == TEST_ADJUST_PAYLOAD_ISSUE);
        let sgl = readVReg(sglRegVec);
        let pmtu = pmtuPipeOut.first;
        pmtuPipeOut.deq;
        pmtuQ.enq(pmtu);

        let dmaReadCntrlReq = DmaReadCntrlReq {
            pmtu              : pmtu,
            sglDmaReadMetaData: DmaReadMetaDataSGL {
                sgl           : sgl,
                sqpn          : getDefaultQPN,
                wrID          : dontCareValue
                // initiator: DMA_SRC_RQ_RD,
                // startAddr: startAddr,
                // len      : payloadLen,
            }
        };
        dmaReadCntrl.srvPort.request.put(dmaReadCntrlReq);

        stateReg <= TEST_ADJUST_PAYLOAD_RECV;
        for (Integer idx = 0; idx < valueOf(MAX_SGE); idx = idx + 1) begin
            let sge = sglRegVec[idx];
            let {
                pmtuLen, sgeFirstPktLen, sgeLastPktLen, sgePktNum, secondChunkStartAddr //, isSinglePkt
            } = calcPktNumAndPktLenByAddrAndPMTU(sge.laddr, sge.len, pmtu);
            let sgeFirstPktFragNum = calcFragNumByPktLen(sgeFirstPktLen);
            let sgeLastPktFragNum = calcFragNumByPktLen(sgeLastPktLen);

            // $display(
            //     "time=%0t: issueDmaReadCntrlReq", $time,
            //     ", SGE idx=%0d", idx,
            //     ", sge.laddr=%h", sge.laddr,
            //     ", sgePktNum=%0d", sgePktNum,
            //     ", sgeFirstPktLen=%0d", sgeFirstPktLen,
            //     ", sgeLastPktLen=%0d", sgeLastPktLen,
            //     ", pmtuLen=%0d", pmtuLen,
            //     ", sgeFirstPktFragNum=%0d", sgeFirstPktFragNum,
            //     ", sgeLastPktFragNum=%0d", sgeLastPktFragNum
            // );
        end
    endrule

    rule recvDmaReadCntrlResp;
        let dmaReadCntrlResp <- dmaReadCntrl.srvPort.response.get;
        sgePayloadOutQ.enq(dmaReadCntrlResp.dmaReadResp.dataStream);
    endrule

    rule adjustTotalPayloadMetaData if (stateReg == TEST_ADJUST_PAYLOAD_RECV);
        let remoteAddr = remoteAddrPipeOut.first;
        remoteAddrPipeOut.deq;

        let pmtu = pmtuQ.first;
        pmtuQ.deq;

        let totalPayloadMetaData = dmaReadCntrl.sglTotalPayloadLenMetaDataPipeOut.first;
        dmaReadCntrl.sglTotalPayloadLenMetaDataPipeOut.deq;
        let totalLen = totalPayloadMetaData.totalLen;

        let {
            pmtuLen, firstPktLen, lastPktLen, totalPktNum, secondChunkStartAddr //, isSinglePkt
        } = calcPktNumAndPktLenByAddrAndPMTU(
            remoteAddr, totalLen, pmtu
        );
        remainingPktNumReg <= totalPktNum - 1;
        isFirstPktReg <= True;

        let origLastFragValidByteNum = calcLastFragValidByteNum(totalLen);
        let origPktNum = calcPktNumByLenOnly(totalLen, pmtu);

        let firstPktLastFragValidByteNum = calcLastFragValidByteNum(firstPktLen);
        let lastPktLastFragValidByteNum  = calcLastFragValidByteNum(lastPktLen);
        let firstPktFragNum = calcFragNumByPktLen(firstPktLen);
        let lastPktFragNum  = calcFragNumByPktLen(lastPktLen);

        let adjustedTotalPayloadMetaData = AdjustedTotalPayloadMetaData {
            firstPktLen                  : firstPktLen,
            firstPktFragNum              : firstPktFragNum,
            firstPktLastFragValidByteNum : firstPktLastFragValidByteNum,
            // firstPktPadCnt               : firstPktPadCnt,
            // lastPktLen                   : lastPktLen,
            // lastPktFragNum               : lastPktFragNum,
            // lastPktLastFragValidByteNum  : lastPktLastFragValidByteNum,
            // lastPktPadCnt                : lastPktPadCnt,
            origLastFragValidByteNum     : origLastFragValidByteNum,
            adjustedPktNum               : totalPktNum,
            origPktNum                   : origPktNum,
            pmtu                         : pmtu
            // totalLen                     : totalLen
        };
        adjustedTotalPayloadMetaDataQ.enq(adjustedTotalPayloadMetaData);
        adjustedTotalPayloadMetaDataRefQ.enq(tuple3(
            adjustedTotalPayloadMetaData, lastPktFragNum, lastPktLastFragValidByteNum
        ));

        stateReg <= TEST_ADJUST_PAYLOAD_RUN;
        // $display(
        //     "time=%0t: adjustTotalPayloadMetaData", $time,
        //     ", pmtu=", fshow(pmtu),
        //     ", totalLen=%0d", totalLen,
        //     ", firstPktLen=%0d", firstPktLen,
        //     ", lastPktLen=%0d", lastPktLen,
        //     ", pmtuLen=%0d", pmtuLen,
        //     ", totalPktNum=%0d", totalPktNum,
        //     ", firstPktFragNum=%0d", firstPktFragNum,
        //     ", lastPktFragNum=%0d", lastPktFragNum,
        //     ", firstPktLastFragValidByteNum=%0d", firstPktLastFragValidByteNum,
        //     ", lastPktLastFragValidByteNum=%0d", lastPktLastFragValidByteNum,
        //     ", remoteAddr=%h", remoteAddr,
        //     ", secondChunkStartAddr=%h", secondChunkStartAddr
        // );
    endrule

    rule checkAdjustedPayloadSegment if (stateReg == TEST_ADJUST_PAYLOAD_RUN);
        let {
            adjustedTotalPayloadMetaData, lastPktFragNum, lastPktLastFragValidByteNum
        } = adjustedTotalPayloadMetaDataRefQ.first;

        let firstPktLen     = adjustedTotalPayloadMetaData.firstPktLen;
        let firstPktFragNum = adjustedTotalPayloadMetaData.firstPktFragNum;
        // let lastPktLen      = adjustedTotalPayloadMetaData.lastPktLen;
        // let lastPktFragNum  = adjustedTotalPayloadMetaData.lastPktFragNum;
        // let pktNum          = adjustedTotalPayloadMetaData.pktNum;
        let pmtu            = adjustedTotalPayloadMetaData.pmtu;
        let firstPktLastFragValidByteNum = adjustedTotalPayloadMetaData.firstPktLastFragValidByteNum;
        // let lastPktLastFragValidByteNum  = adjustedTotalPayloadMetaData.lastPktLastFragValidByteNum;

        let firstPktLastFragByteEn = genByteEn(firstPktLastFragValidByteNum);
        let lastPktLastFragByteEn  = genByteEn(lastPktLastFragValidByteNum);

        let pmtuFragNum = calcFragNumByPMTU(pmtu);
        let payloadFrag = dut.first;
        dut.deq;

        let isLastPkt = isZero(remainingPktNumReg);
        if (payloadFrag.isLast) begin
            isFirstPktReg <= isLastPkt;

            if (isLastPkt) begin
                adjustedTotalPayloadMetaDataRefQ.deq;
                stateReg <= TEST_ADJUST_PAYLOAD_INIT;
            end
            else begin
                remainingPktNumReg <= remainingPktNumReg - 1;
            end
        end
        else begin
            let remainingFragNum = remainingFragNumReg;
            if (payloadFrag.isFirst) begin
                if (isFirstPktReg) begin
                    remainingFragNum = firstPktFragNum - 2;
                end
                else if (isLastPkt) begin
                    remainingFragNum = lastPktFragNum - 2;
                end
                else begin
                    remainingFragNum = pmtuFragNum - 2;
                end
            end
            else begin
                remainingFragNum = remainingFragNumReg - 1;
            end
            remainingFragNumReg <= remainingFragNum;
            // $display(
            //     "time=%0t: checkAdjustedPayloadSegment", $time,
            //     ", remainingFragNum=%0d", remainingFragNum
            // );
        end

        if (isZero(remainingFragNumReg)) begin
            immAssert(
                payloadFrag.isFirst || payloadFrag.isLast,
                "payloadFrag isFirst isLast assertion @ mkTestAdjustNormalOrSmallPayloadSegment",
                $format(
                    "payloadFrag.isFirst=", fshow(payloadFrag.isFirst),
                    " or payloadFrag.isLast=", fshow(payloadFrag.isLast),
                    " should be true when remainingFragNumReg=%0d",
                    remainingFragNumReg
                )
            );
        end

        if (payloadFrag.isFirst) begin
            immAssert(
                isZero(remainingFragNumReg),
                "remainingFragNumReg assertion @ mkTestAdjustNormalOrSmallPayloadSegment",
                $format(
                    "remainingFragNumReg=%0d", remainingFragNumReg,
                    " should be zero when payloadFrag.isFirst=",
                    fshow(payloadFrag.isFirst)
                )
            );
        end

        ByteEn expectedLastFragByteEn = maxBound;
        if (payloadFrag.isLast) begin
            if (isFirstPktReg) begin
                expectedLastFragByteEn = firstPktLastFragByteEn;
            end
            else if (isLastPkt) begin
                expectedLastFragByteEn = lastPktLastFragByteEn;
            end
            immAssert(
                payloadFrag.byteEn == expectedLastFragByteEn,
                "payloadFrag.byteEn assertion @ mkTestAdjustNormalOrSmallPayloadSegment",
                $format(
                    "payloadFrag.byteEn=%h", payloadFrag.byteEn,
                    " should == expectedLastFragByteEn=%h", expectedLastFragByteEn,
                    ", when payloadFrag.isLast=", fshow(payloadFrag.isLast),
                    ", isFirstPktReg=", fshow(isFirstPktReg),
                    ", isLastPkt=", fshow(isLastPkt)
                )
            );

            immAssert(
                isZero(remainingFragNumReg),
                "remainingFragNumReg assertion @ mkTestAdjustNormalOrSmallPayloadSegment",
                $format(
                    "remainingFragNumReg=%0d", remainingFragNumReg,
                    " should be zero when payloadFrag.isLast=",
                    fshow(payloadFrag.isLast)
                )
            );
        end
        else begin
            immAssert(
                isAllOnesR(payloadFrag.byteEn),
                "payloadFrag.byteEn assertion @ mkTestAdjustNormalOrSmallPayloadSegment",
                $format(
                    "payloadFrag.byteEn=%h", payloadFrag.byteEn,
                    " should be all ones when payloadFrag.isLast=",
                    fshow(payloadFrag.isLast)
                )
            );
        end
        // $display(
        //     "time=%0t: checkAdjustedPayloadSegment", $time,
        //     ", isFirstPktReg=", fshow(isFirstPktReg),
        //     ", isLastPkt=", fshow(isLastPkt),
        //     ", remainingPktNumReg=%0d", remainingPktNumReg,
        //     ", remainingFragNumReg=%0d", remainingFragNumReg,
        //     ", pmtuFragNum=%0d", pmtuFragNum,
        //     ", firstPktFragNum=%0d", firstPktFragNum,
        //     ", firstPktLastFragValidByteNum=%0d", firstPktLastFragValidByteNum,
        //     ", firstPktLastFragByteEn=%h", firstPktLastFragByteEn,
        //     ", lastPktFragNum=%0d", lastPktFragNum,
        //     ", lastPktLastFragValidByteNum=%0d", lastPktLastFragValidByteNum,
        //     ", lastPktLastFragByteEn=%h", lastPktLastFragByteEn,
        //     ", payloadFrag.isFirst=", fshow(payloadFrag.isFirst),
        //     ", payloadFrag.isLast=", fshow(payloadFrag.isLast),
        //     ", payloadFrag.byteEn=%h", payloadFrag.byteEn
        // );
    endrule
endmodule

(* doc = "testcase" *)
module mkTestPayloadGenNormalCase(Empty);
    let minPayloadLen = 2048;
    let maxPayloadLen = 8192;
    let result <- mkTestNormalOrSmallPayloadGen(minPayloadLen, maxPayloadLen);
endmodule

(* doc = "testcase" *)
module mkTestPayloadGenSmallCase(Empty);
    let minPayloadLen = 1;
    let maxPayloadLen = 7;
    let result <- mkTestNormalOrSmallPayloadGen(minPayloadLen, maxPayloadLen);
endmodule

(* doc = "testcase" *)
module mkTestPayloadGenZeroCase(Empty);
    let minPayloadLen = 0;
    let maxPayloadLen = 0;
    let result <- mkTestNormalOrSmallPayloadGen(minPayloadLen, maxPayloadLen);
endmodule

module mkTestNormalOrSmallPayloadGen#(
    // Both min and max are inclusive
    Length minPayloadLen, Length maxPayloadLen
)(Empty);
    let qpType = IBV_QPT_XRC_SEND;
    let pmtuVec = vec(
        IBV_MTU_256,
        IBV_MTU_512,
        IBV_MTU_1024,
        IBV_MTU_2048,
        IBV_MTU_4096
    );

    Reg#(Bool) clearReg <- mkReg(True);
    Reg#(IdxSGL) sglIdxReg <- mkReg(0);
    Reg#(Length) totalLenReg <- mkRegU;
    Vector#(MAX_SGE, Reg#(ScatterGatherElem)) sglRegVec <- replicateM(mkRegU);

    PipeOut#(ADDR) remoteAddrPipeOut <- mkGenericRandomPipeOut;
    PipeOut#(ADDR)  localAddrPipeOut <- mkGenericRandomPipeOut;
    let payloadLenPipeOut <- mkRandomLenPipeOut(minPayloadLen, maxPayloadLen);
    let pmtuPipeOut <- mkRandomItemFromVec(pmtuVec);

    let simDmaReadSrv <- mkSimDmaReadSrv;
    let dmaReadCntrl <- mkDmaReadCntrl(clearReg, simDmaReadSrv);

    let shouldAddPadding = False;
    let dut <- mkPayloadGenerator(clearReg, shouldAddPadding, dmaReadCntrl);

    Reg#(PayloadGenRespSG) payloadGenRespReg <- mkRegU;
    Reg#(Bool)                isFirstFragReg <- mkRegU;
    Reg#(PktNum)          remainingPktNumReg <- mkRegU; // TODO: remove it
    Reg#(PktFragNum)     remainingFragNumReg <- mkRegU;
    Reg#(PktFragNum)      firstPktFragNumReg <- mkRegU;
    Reg#(PktFragNum)       lastPktFragNumReg <- mkRegU;
    Reg#(PktFragNum)          pmtuFragNumReg <- mkRegU;
    Reg#(TestAdjustPayloadState)    stateReg <- mkReg(TEST_ADJUST_PAYLOAD_INIT);
    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    rule clearAll if (stateReg == TEST_ADJUST_PAYLOAD_INIT);
        clearReg <= False;
        sglIdxReg <= 0;

        stateReg <= TEST_ADJUST_PAYLOAD_PREPARE;
        // $display("time=%0t: clearAll", $time);
    endrule

    rule genSGE if (stateReg == TEST_ADJUST_PAYLOAD_PREPARE);
        let localAddr = localAddrPipeOut.first;
        localAddrPipeOut.deq;

        let payloadLen = payloadLenPipeOut.first;
        payloadLenPipeOut.deq;

        let isFirst = isZero(sglIdxReg);
        let isLast = isAllOnesR(sglIdxReg);
        let sge = ScatterGatherElem {
            laddr  : localAddr,
            len    : payloadLen,
            lkey   : dontCareValue,
            isFirst: isFirst,
            isLast : isLast
        };
        sglRegVec[sglIdxReg] <= sge;

        let totalLen = totalLenReg;
        if (isFirst) begin
            totalLen = payloadLen;
        end
        else begin
            totalLen = totalLenReg + payloadLen;
        end
        totalLenReg <= totalLen;

        if (isLast) begin
            sglIdxReg <= 0;
            stateReg <= TEST_ADJUST_PAYLOAD_ISSUE;
        end
        else begin
            sglIdxReg <= sglIdxReg + 1;
        end

        let {
            sgeFragNum, sgeLastFragByteEn, sgeLastFragValidByteNum
        } = calcTotalFragNumByLength(payloadLen);
        countDown.decr;
        // $display(
        //     "time=%0t: genSGE", $time,
        //     ", sglIdxReg=%0d", sglIdxReg,
        //     ", localAddr=%h", localAddr,
        //     ", payloadLen=%0d", payloadLen,
        //     ", sgeFragNum=%0d", sgeFragNum,
        //     ", sgeLastFragByteEn=%h", sgeLastFragByteEn,
        //     ", sgeLastFragValidByteNum=%0d", sgeLastFragValidByteNum
        // );
    endrule

    rule issuePayloadGenReq if (stateReg == TEST_ADJUST_PAYLOAD_ISSUE);
        let sgl = readVReg(sglRegVec);

        let pmtu = pmtuPipeOut.first;
        pmtuPipeOut.deq;
        let remoteAddr = remoteAddrPipeOut.first;
        remoteAddrPipeOut.deq;

        let payloadGenReq = PayloadGenReqSG {
            wrID : dontCareValue,
            sqpn : getDefaultQPN,
            sgl  : sgl,
            raddr: remoteAddr,
            pmtu : pmtu
        };
        dut.srvPort.request.put(payloadGenReq);

        let {
            pmtuLen, firstPktLen, lastPktLen, totalPktNum, secondChunkStartAddr //, isSinglePkt
        } = calcPktNumAndPktLenByAddrAndPMTU(remoteAddr, totalLenReg, pmtu);
        let firstPktFragNum = calcFragNumByPktLen(firstPktLen);
        let lastPktFragNum  = calcFragNumByPktLen(lastPktLen);
        let pmtuFragNum     = calcFragNumByPktLen(pmtuLen);

        firstPktFragNumReg  <= firstPktFragNum;
        lastPktFragNumReg   <= lastPktFragNum;
        pmtuFragNumReg      <= pmtuFragNum;
        remainingPktNumReg  <= totalPktNum - 1;
        remainingFragNumReg <= firstPktFragNum - 1;
        isFirstFragReg      <= True;
        // $display(
        //     "time=%0t: issueDmaReadCntrlReq", $time,
        //     ", pmtu=", fshow(pmtu),
        //     ", totalLenReg=%0d", totalLenReg,
        //     ", totalPktNum=%0d", totalPktNum,
        //     ", firstPktLen=%0d", firstPktLen,
        //     ", lastPktLen=%0d", lastPktLen,
        //     ", firstPktFragNum=%0d", firstPktFragNum,
        //     ", lastPktFragNum=%0d", lastPktFragNum,
        //     ", pmtuFragNum=%0d", pmtuFragNum,
        //     ", remoteAddr=%h", remoteAddr
        // );

        stateReg <= TEST_ADJUST_PAYLOAD_RUN;
        for (Integer idx = 0; idx < valueOf(MAX_SGE); idx = idx + 1) begin
            let sge = sglRegVec[idx];
            let {
                pmtuPktLen, sgeFirstPktLen, sgeLastPktLen, sgePktNum, sgeSecondChunkStartAddr //, isSinglePkt
            } = calcPktNumAndPktLenByAddrAndPMTU(sge.laddr, sge.len, pmtu);
            let sgeFirstPktFragNum = calcFragNumByPktLen(sgeFirstPktLen);
            let sgeLastPktFragNum = calcFragNumByPktLen(sgeLastPktLen);

            // $display(
            //     "time=%0t: issuePayloadGenReq", $time,
            //     ", SGE idx=%0d", idx,
            //     ", sge.laddr=%h", sge.laddr,
            //     ", sgePktNum=%0d", sgePktNum,
            //     ", sgeFirstPktLen=%0d", sgeFirstPktLen,
            //     ", sgeLastPktLen=%0d", sgeLastPktLen,
            //     ", pmtuPktLen=%0d", pmtuPktLen,
            //     ", sgeFirstPktFragNum=%0d", sgeFirstPktFragNum,
            //     ", sgeLastPktFragNum=%0d", sgeLastPktFragNum
            // );
        end
    endrule

    rule checkResp if (stateReg == TEST_ADJUST_PAYLOAD_RUN);
        let payloadGenResp = payloadGenRespReg;
        let isFirstFrag = isFirstFragReg;

        if (isFirstFrag) begin
            payloadGenResp <- dut.srvPort.response.get;
            payloadGenRespReg <= payloadGenResp;
        end
        let isFirstPkt = payloadGenResp.isFirst;
        let isLastPkt  = payloadGenResp.isLast;

        if (payloadGenResp.isZeroPayloadLen) begin
            stateReg <= TEST_ADJUST_PAYLOAD_INIT;
            isFirstFrag = True;
        end
        else begin
            let remainingPktNum  = remainingPktNumReg;
            let remainingFragNum = remainingFragNumReg;

            let isSecondLastPkt = isOne(remainingPktNumReg);

            let payloadFrag = dut.payloadDataStreamPipeOut.first;
            dut.payloadDataStreamPipeOut.deq;
            let isFirstPktLastFrag = payloadFrag.isLast && isFirstPkt;
            let isLastPktLastFrag  = payloadFrag.isLast && isLastPkt;
            isFirstFrag            = payloadFrag.isLast;

            if (payloadFrag.isLast) begin
                if (isLastPkt) begin
                    stateReg <= TEST_ADJUST_PAYLOAD_INIT;
                end
                else begin
                    remainingPktNum  = remainingPktNumReg - 1;

                    if (isSecondLastPkt) begin
                        remainingFragNum = lastPktFragNumReg - 1;
                    end
                    else begin
                        remainingFragNum = pmtuFragNumReg - 1;
                    end
                end

                immAssert(
                    isZero(remainingFragNumReg),
                    "remainingFragNumReg assertion @ mkTestNormalOrSmallPayloadGen",
                    $format(
                        "remainingFragNumReg=%h", remainingFragNumReg,
                        " should be zero when payloadFrag.isLast=",
                        fshow(payloadFrag.isLast)
                    )
                );
            end
            else begin
                remainingFragNum = remainingFragNumReg - 1;
            end
            remainingPktNumReg  <= remainingPktNum;
            remainingFragNumReg <= remainingFragNum;
            // $display(
            //     "time=%0t: checkResp, each payload fragment", $time,
            //     ", isFirstFragReg=", fshow(isFirstFragReg),
            //     ", isFirstPktLastFrag=", fshow(isFirstPktLastFrag),
            //     ", isLastPktLastFrag=", fshow(isLastPktLastFrag),
            //     ", isFirstPkt=", fshow(isFirstPkt),
            //     ", isLastPkt=", fshow(isLastPkt),
            //     ", remainingPktNumReg=%0d", remainingPktNumReg,
            //     ", remainingFragNumReg=%0d", remainingFragNumReg,
            //     ", payloadFrag.isFirst=", fshow(payloadFrag.isFirst),
            //     ", payloadFrag.isLast=", fshow(payloadFrag.isLast)
            // );
        end
        isFirstFragReg <= isFirstFrag;

        // $display(
        //     "time=%0t: checkResp", $time,
        //     ", isZeroPayloadLen=", fshow(payloadGenResp.isZeroPayloadLen)
        // );
    endrule
endmodule
