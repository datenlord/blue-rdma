import BuildVector :: *;
import ClientServer :: *;
import Cntrs :: *;
import FIFOF :: *;
import GetPut :: *;
import PAClib :: *;
import Vector :: *;

import Headers :: *;
import Controller :: *;
import DataTypes :: *;
import MetaData :: *;
import PayloadConAndGen :: *;
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
    Reg#(Bool) clearReg <- mkReg(True);

    let isSQ = True;
    let dut <- mkAddrChunkSrv(clearReg, isSQ);

    PipeOut#(ADDR)  startAddrPipeOut <- mkGenericRandomPipeOut;
    let payloadLenPipeOut <- mkRandomLenPipeOut(minPayloadLen, maxPayloadLen);
    let pmtuPipeOut <- mkRandomItemFromVec(pmtuVec);

    Reg#(PmtuResidue) residueReg <- mkRegU;
    Reg#(PktNum)       pktNumReg <- mkRegU;
    Reg#(ADDR)       nextAddrReg <- mkRegU;
    Reg#(Length)     totalLenReg <- mkRegU;

    Reg#(Bool) busyReg <- mkReg(False);
    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    rule clearAll if (clearReg);
        clearReg <= False;
    endrule

    rule issueReq if (!busyReg);
        let startAddr = startAddrPipeOut.first;
        startAddrPipeOut.deq;

        let payloadLen = payloadLenPipeOut.first;
        payloadLenPipeOut.deq;

        let pmtu = pmtuPipeOut.first;
        pmtuPipeOut.deq;

        // let totalPktNum = calcPktNumByLenOnly(payloadLen, pmtu);
        let { tmpPktNum, pmtuResidue } = truncateLenByPMTU(
            payloadLen, pmtu
        );
        let totalPktNum = tmpPktNum + (isZero(pmtuResidue) ? 0 : 1);
        pktNumReg   <= totalPktNum;
        residueReg  <= pmtuResidue;
        nextAddrReg <= startAddr;
        busyReg <= True;

        let addrChunkReq = AddrChunkReq {
            startAddr: startAddr,
            totalLen : payloadLen,
            pmtu     : pmtu
        };
        dut.srvPort.request.put(addrChunkReq);
        reqQ.enq(addrChunkReq);

        countDown.decr;
    endrule

    rule expectedRespGen if (busyReg);
        let req = reqQ.first;
        let pmtuLen = calcPmtuLen(req.pmtu);

        pktNumReg   <= pktNumReg - 1;
        nextAddrReg <= nextAddrReg + zeroExtend(pmtuLen);

        let isZeroResidue = isZero(residueReg);
        let isFirst = nextAddrReg == req.startAddr;
        let isLast  = isLessOrEqOne(pktNumReg);
        if (isLast) begin
            reqQ.deq;
            totalLenQ.enq(req.totalLen);
            busyReg <= False;
        end

        let addrChunkResp = AddrChunkResp {
            chunkAddr: nextAddrReg,
            chunkLen : (isLast && !isZeroResidue) ? zeroExtend(residueReg) : pmtuLen,
            isFirst  : isFirst,
            isLast   : isLast
        };
        respQ.enq(addrChunkResp);
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
    TEST_DMA_CNTRL_RESET,
    TEST_DMA_CNTRL_RUN,
    TEST_DMA_CNTRL_IDLE
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
    let unusedPMTU = IBV_MTU_256;
    let cntrl <- mkSimCntrlStateCycle(qpType, unusedPMTU);
    let cntrlStatus = cntrl.contextSQ.statusSQ;

    Reg#(Bool) canceledReg <- mkReg(False);
    Reg#(TotalFragNum) remainingFragNumReg <- mkReg(0);
    FIFOF#(TotalFragNum) totalFragNumQ <- mkFIFOF;

    PipeOut#(Bool) randomCancelPipeOut <- mkGenericRandomPipeOut;
    Reg#(Bool)  isFinalRespLastFragReg <- mkReg(False);

    PipeOut#(ADDR)  startAddrPipeOut <- mkGenericRandomPipeOut;
    let payloadLenPipeOut <- mkRandomLenPipeOut(minPayloadLen, maxPayloadLen);
    let pmtuPipeOut <- mkRandomItemFromVec(pmtuVec);

    let simDmaReadSrv <- mkSimDmaReadSrv;
    let dut <- mkDmaReadCntrl(cntrlStatus, simDmaReadSrv);

    Reg#(TestDmaCntrlState) stateReg <- mkReg(TEST_DMA_CNTRL_RESET);
    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    rule clearAll if (stateReg == TEST_DMA_CNTRL_RESET);
        canceledReg <= False;
        remainingFragNumReg <= 0;
        isFinalRespLastFragReg <= False;
        totalFragNumQ.clear;

        if (cntrlStatus.comm.isRTS) begin
            stateReg <= TEST_DMA_CNTRL_RUN;
            // $display("time=%0t: clearAll", $time);
        end
    endrule

    rule issueReq if (stateReg == TEST_DMA_CNTRL_RUN);
        let startAddr = startAddrPipeOut.first;
        startAddrPipeOut.deq;

        let payloadLen = payloadLenPipeOut.first;
        payloadLenPipeOut.deq;

        let pmtu = pmtuPipeOut.first;
        pmtuPipeOut.deq;

        let totalPktNum = calcPktNumByLenOnly(payloadLen, pmtu);
        let { totalFragNum, lastFragByteEn, lastFragValidByteNum } =
            calcTotalFragNumByLength(payloadLen);
        totalFragNumQ.enq(totalFragNum);

        let dmaReadCntrlReq = DmaReadCntrlReq {
            pmtu           : pmtu,
            dmaReadMetaData: DmaReadMetaData {
                initiator: DMA_SRC_RQ_RD,
                sqpn     : cntrlStatus.comm.getSQPN,
                startAddr: startAddr,
                len      : payloadLen,
                mrID     : dontCareValue
            }
        };

        dut.srvPort.request.put(dmaReadCntrlReq);
        countDown.decr;

        // $display(
        //     "time=%0t: issueReq", $time,
        //     ", payloadLen=%0d", payloadLen,
        //     ", totalPktNum=%0d", totalPktNum,
        //     ", totalFragNum=%0d", totalFragNum
        // );
    endrule

    rule checkResp if (stateReg == TEST_DMA_CNTRL_RUN && !dut.dmaCntrl.isIdle);
        let dmaReadCntrlResp <- dut.srvPort.response.get;
        isFinalRespLastFragReg <= dmaReadCntrlResp.dmaReadResp.dataStream.isLast;

        let totalFragNum = totalFragNumQ.first;
        if (!dmaReadCntrlResp.isOrigLast) begin
            if (dmaReadCntrlResp.isOrigFirst) begin
                remainingFragNumReg <= totalFragNum - 2;
            end
            else begin
                remainingFragNumReg <= remainingFragNumReg - 1;
            end
        end

        if (dmaReadCntrlResp.isOrigLast) begin
            totalFragNumQ.deq;

            immAssert(
                isZero(remainingFragNumReg),
                "remaining fragNum assertion @ mkTestDmaReadCntrlNormalOrCancelCase",
                $format(
                    "remainingFragNumReg=%0d should be zero when", remainingFragNumReg,
                    " isOrigLast=", fshow(dmaReadCntrlResp.isOrigLast),
                    " and isOrigFirst=", fshow(dmaReadCntrlResp.isOrigFirst)
                )
            );
        end

        if (!normalOrCancelCase) begin
            let shouldCancel = randomCancelPipeOut.first;
            randomCancelPipeOut.deq;

            if (shouldCancel && !canceledReg) begin
                cntrl.setStateErr;
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

        cntrl.errFlushDone;
        stateReg <= TEST_DMA_CNTRL_IDLE;
        // $display("time=%0t: dmaCntrl.isIdle", $time);
    endrule

    rule loop if (stateReg == TEST_DMA_CNTRL_IDLE);
        stateReg <= TEST_DMA_CNTRL_RESET;
    endrule
endmodule

(* doc = "testcase" *)
module mkTestDmaWriteCntrlNormalCase(Empty);
    let normalOrCancelCase = True;
    let result <- mkTestDmaWriteCntrlNormalOrCancelCase(normalOrCancelCase);
endmodule

(* doc = "testcase" *)
module mkTestDmaWriteCntrlCancelCase(Empty);
    let normalOrCancelCase = False;
    let result <- mkTestDmaWriteCntrlNormalOrCancelCase(normalOrCancelCase);
endmodule

module mkTestDmaWriteCntrlNormalOrCancelCase#(Bool normalOrCancelCase)(Empty);
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
    let unusedPMTU = IBV_MTU_256;
    let cntrl <- mkSimCntrlStateCycle(qpType, unusedPMTU);
    let cntrlStatus = cntrl.contextSQ.statusSQ;

    Reg#(Bool) canceledReg <- mkReg(False);
    Reg#(PSN) psnReg <- mkReg(0);
    Reg#(Bool) isFirstFragReg <- mkReg(True);
    Reg#(TotalFragNum) remainingTotalFragNumReg <- mkReg(0);
    Reg#(PktFragNum) remainingPktFragNumReg <- mkReg(0);
    FIFOF#(Tuple3#(TotalFragNum, ByteEn, PktFragNum)) pendingReqStatsQ <- mkFIFOF;

    PipeOut#(Bool) randomCancelPipeOut <- mkGenericRandomPipeOut;
    Reg#(Bool)   isFinalReqLastFragReg <- mkReg(False);

    // PipeOut#(ADDR)  startAddrPipeOut <- mkGenericRandomPipeOut;
    let payloadLenPipeOut <- mkRandomLenPipeOut(minPayloadLen, maxPayloadLen);
    let pmtuPipeOut <- mkRandomItemFromVec(pmtuVec);

    let simDmaWriteSrv <- mkSimDmaWriteSrvAndDataStreamPipeOut;
    let dut <- mkDmaWriteCntrl(cntrlStatus, simDmaWriteSrv.dmaWriteSrv);

    Reg#(TestDmaCntrlState) stateReg <- mkReg(TEST_DMA_CNTRL_RESET);
    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    rule clearAll if (stateReg == TEST_DMA_CNTRL_RESET);
        canceledReg <= False;
        psnReg <= 0;
        isFirstFragReg <= True;
        remainingTotalFragNumReg <= 0;
        remainingPktFragNumReg <= 0;
        isFinalReqLastFragReg <= False;
        pendingReqStatsQ.clear;

        if (cntrlStatus.comm.isRTS) begin
            stateReg <= TEST_DMA_CNTRL_RUN;
            // $display("time=%0t: clearAll", $time);
        end
    endrule

    rule prepareReq if (stateReg == TEST_DMA_CNTRL_RUN);
        // let startAddr = startAddrPipeOut.first;
        // startAddrPipeOut.deq;
        let payloadLen = payloadLenPipeOut.first;
        payloadLenPipeOut.deq;

        let pmtu = pmtuPipeOut.first;
        pmtuPipeOut.deq;

        let totalPktNum = calcPktNumByLenOnly(payloadLen, pmtu);
        let { totalFragNum, lastFragByteEn, lastFragValidByteNum } =
            calcTotalFragNumByLength(payloadLen);
        let pktFragNum = calcFragNumByPmtu(pmtu);
        pendingReqStatsQ.enq(tuple3(totalFragNum, lastFragByteEn, pktFragNum));
        // $display(
        //     "time=%0t: issueReq", $time,
        //     ", payloadLen=%0d", payloadLen,
        //     ", totalPktNum=%0d", totalPktNum,
        //     ", totalFragNum=%0d", totalFragNum,
        //     ", pktFragNum=%0d", pktFragNum
        // );
    endrule

    rule genReq if (stateReg == TEST_DMA_CNTRL_RUN);
        let { totalFragNum, lastFragByteEn, pktFragNum } = pendingReqStatsQ.first;
        let isOrigFirst = isZero(remainingTotalFragNumReg);
        let isFinalFrag = isOne(totalFragNum) || isOne(remainingTotalFragNumReg);
        if (isFinalFrag) begin
            pendingReqStatsQ.deq;
            remainingTotalFragNumReg <= 0;
        end
        else begin
            if (isZero(remainingTotalFragNumReg)) begin
                remainingTotalFragNumReg <= totalFragNum - 1;

                immAssert(
                    !isLessOrEqOne(totalFragNum),
                    "totalFragNum assertion @ mkTestDmaWriteCntrlNormalOrCancelCase",
                    $format(
                        "totalFragNum=%0d should > 1", totalFragNum
                    )
                );
            end
            else begin
                remainingTotalFragNumReg <= remainingTotalFragNumReg - 1;
            end
        end

        let isLastFrag = isFinalFrag || isOne(remainingPktFragNumReg);
        if (isLastFrag) begin
            isFirstFragReg <= True;
            psnReg <= psnReg + 1;
        end
        else begin
            isFirstFragReg <= False;
        end

        if (isFirstFragReg) begin
            remainingPktFragNumReg <= pktFragNum - 1;
        end
        else begin
            remainingPktFragNumReg <= remainingPktFragNumReg - 1;
        end

        let dmaWriteReq = DmaWriteReq {
            metaData     : DmaWriteMetaData {
                initiator: DMA_SRC_RQ_WR,
                sqpn     : cntrlStatus.comm.getSQPN,
                startAddr: dontCareValue,
                len      : dontCareValue,
                psn      : psnReg,
                mrID     : dontCareValue
            },
            dataStream : DataStream {
                data   : dontCareValue,
                byteEn : isLastFrag ? lastFragByteEn : maxBound,
                isFirst: isFirstFragReg,
                isLast : isLastFrag
            }
        };

        dut.srvPort.request.put(dmaWriteReq);

        // $display(
        //     "time=%0t: genReq", $time,
        //     ", remainingTotalFragNumReg=%0d", remainingTotalFragNumReg,
        //     ", remainingPktFragNumReg=%0d", remainingPktFragNumReg,
        //     ", isFirst=", fshow(isFirstFragReg),
        //     ", isLast=", fshow(isLastFrag),
        //     ", isOrigFirst=", fshow(isOrigFirst),
        //     ", isFinalFrag=", fshow(isFinalFrag)
        // );
    endrule

    rule discardReq if (stateReg == TEST_DMA_CNTRL_RUN);
        let dmaWriteReqDataStream = simDmaWriteSrv.dataStream.first;
        simDmaWriteSrv.dataStream.deq;
        isFinalReqLastFragReg <= dmaWriteReqDataStream.isLast;
        // $display(
        //     "time=%0t: discardReq", $time,
        //     ", dmaWriteReqDataStream.isLast=", fshow(dmaWriteReqDataStream.isLast)
        // );
    endrule

    rule checkReq if (stateReg == TEST_DMA_CNTRL_IDLE);
        immAssert(
            isFinalReqLastFragReg,
            "isFinalReqLastFragReg assertion @ mkTestDmaWriteCntrlNormalOrCancelCase",
            $format(
                "isFinalReqLastFragReg=", fshow(isFinalReqLastFragReg),
                " should be true, when canceledReg=", fshow(canceledReg),
                " and dut.dmaCntrl.isIdle=", fshow(dut.dmaCntrl.isIdle)
            )
        );
    endrule

    rule checkResp if (stateReg == TEST_DMA_CNTRL_RUN && !dut.dmaCntrl.isIdle);
        let dmaWriteResp <- dut.srvPort.response.get;
        countDown.decr;

        if (!normalOrCancelCase) begin
            let shouldCancel = randomCancelPipeOut.first;
            randomCancelPipeOut.deq;

            if (shouldCancel && !canceledReg) begin
                cntrl.setStateErr;
                dut.dmaCntrl.cancel;
                canceledReg <= True;
                // $display("time=%0t: dmaCntrl.cancel", $time);
            end
        end
    endrule

    rule waitUntilGracefulStop if (stateReg == TEST_DMA_CNTRL_RUN && dut.dmaCntrl.isIdle);
        cntrl.errFlushDone;
        stateReg <= TEST_DMA_CNTRL_IDLE;
        // $display("time=%0t: dmaCntrl.isIdle", $time);
    endrule

    rule loop if (stateReg == TEST_DMA_CNTRL_IDLE);
        // clearReg <= True;
        stateReg <= TEST_DMA_CNTRL_RESET;
    endrule
endmodule
/*
typedef enum {
    TEST_DMA_CNTRL_ISSUE_REQ,
    TEST_DMA_CNTRL_RUN_A_CYCLE,
    TEST_DMA_CNTRL_CANCEL,
    TEST_DMA_CNTRL_WAIT_IDLE
} TestDmaCntrlState deriving(Bits, Eq, FShow);

module mkTestDmaWriteCntrl(Empty);
    let minPktLen = 2048;
    let maxPktLen = 4096;
    let qpType = IBV_QPT_XRC_SEND;
    let pmtu = IBV_MTU_4096;

    let cntrl <- mkSimCntrl(qpType, pmtu);
    let cntrlStatus = cntrl.contextSQ.statusSQ;

    Vector#(1, PipeOut#(PktLen)) pktLenPipeOutVec <-
        mkRandomValueInRangePipeOut(minPktLen, maxPktLen);
    let pktLenPipeOut4Write = pktLenPipeOutVec[0];

    let simDmaWriteSrv <- mkSimDmaWriteSrv;
    let dmaWriteCntrl <- mkDmaWriteCntrl(cntrlStatus, simDmaWriteSrv);

    Reg#(DmaWriteReq) preWriteReqReg <- mkRegU;
    Reg#(TestDmaCntrlState) stateReg <- mkReg(TEST_DMA_CNTRL_ISSUE_REQ);
    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    rule issueWriteReq if (stateReg == TEST_DMA_CNTRL_ISSUE_REQ);
        let pktLen = pktLenPipeOut4Write.first;
        pktLenPipeOut4Write.deq;

        let dmaWriteReq = DmaWriteReq {
            metaData  : DmaWriteMetaData {
                initiator: DMA_SRC_SQ_CANCEL,
                sqpn     : cntrlStatus.comm.getSQPN,
                startAddr: dontCareValue,
                len      : pktLen,
                psn      : dontCareValue,
                mrID     : dontCareValue
            },
            dataStream: DataStream {
                data: dontCareValue,
                byteEn: maxBound,
                isFirst: True,
                isLast: False
            }
        };
        dmaWriteCntrl.srvPort.request.put(dmaWriteReq);
        preWriteReqReg <= dmaWriteReq;
        stateReg <= TEST_DMA_CNTRL_RUN_A_CYCLE;
    endrule

    rule runOneCycle if (stateReg == TEST_DMA_CNTRL_RUN_A_CYCLE);
        immAssert(
            preWriteReqReg.dataStream.isFirst && !preWriteReqReg.dataStream.isLast,
            "preWriteReqReg assertion @ mkTestDmaWriteCntrl",
            $format(
                "preWriteReqReg.dataStream.isFirst=",
                fshow(preWriteReqReg.dataStream.isFirst),
                " should be true, and preWriteReqReg.dataStream.isLast=",
                fshow(preWriteReqReg.dataStream.isLast),
                " should be false"
            )
        );

        let dmaWriteReq = preWriteReqReg;
        dmaWriteReq.dataStream.isFirst = False;

        dmaWriteCntrl.srvPort.request.put(dmaWriteReq);
        stateReg <= TEST_DMA_CNTRL_CANCEL;
    endrule

    rule cancelReq if (stateReg == TEST_DMA_CNTRL_CANCEL);
        dmaWriteCntrl.dmaCntrl.cancel;
        stateReg <= TEST_DMA_CNTRL_WAIT_IDLE;
    endrule

    rule waitIdle if (stateReg == TEST_DMA_CNTRL_WAIT_IDLE && dmaWriteCntrl.dmaCntrl.isIdle);
        stateReg <= TEST_DMA_CNTRL_ISSUE_REQ;
        countDown.decr;
    endrule
endmodule
*/
(* doc = "testcase" *)
module mkTestPayloadConAndGenNormalCase(Empty);
    let minPktLen = 2048;
    let maxPktLen = 4096;
    let qpType = IBV_QPT_XRC_SEND;
    let pmtu = IBV_MTU_4096;

    FIFOF#(PSN) payloadConReqPsnQ <- mkFIFOF;

    let cntrl <- mkSimCntrl(qpType, pmtu);
    let cntrlStatus = cntrl.contextSQ.statusSQ;

    Vector#(2, PipeOut#(PktLen)) pktLenPipeOutVec <-
        mkRandomValueInRangePipeOut(minPktLen, maxPktLen);
    let pktLenPipeOut4Gen = pktLenPipeOutVec[0];
    let pktLenPipeOut4Con = pktLenPipeOutVec[1];

    let simDmaReadSrv <- mkSimDmaReadSrvAndDataStreamPipeOut;
    let simDmaReadSrvDataStreamPipeOut <- mkBufferN(2, simDmaReadSrv.dataStream);

    let dmaReadCntrl <- mkDmaReadCntrl(
        cntrlStatus, simDmaReadSrv.dmaReadSrv
    );
    let payloadGenerator <- mkPayloadGenerator(
        cntrlStatus, dmaReadCntrl
    );

    let simDmaWriteSrv <- mkSimDmaWriteSrvAndDataStreamPipeOut;
    let simDmaWriteSrvDataStreamPipeOut = simDmaWriteSrv.dataStream;
    let dmaWriteCntrl <- mkDmaWriteCntrl(cntrlStatus, simDmaWriteSrv.dmaWriteSrv);
    let payloadConsumer <- mkPayloadConsumer(
        cntrlStatus,
        dmaWriteCntrl,
        payloadGenerator.payloadDataStreamPipeOut
    );

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    // PipeOut need to handle:
    // - pktLenPipeOut4Gen
    // - pktLenPipeOut4Con
    // - payloadGenerator.respPipeOut
    // - payloadGenerator.payloadDataStreamPipeOut
    // - simDmaReadSrvDataStreamPipeOut
    // - simDmaWriteSrvDataStreamPipeOut
    // - payloadConsumer.respPipeOut

    rule genPayloadGenReq if (cntrlStatus.comm.isRTS);
        let pktLen = pktLenPipeOut4Gen.first;
        pktLenPipeOut4Gen.deq;

        let payloadGenReq = PayloadGenReq {
            // segment      : False,
            addPadding     : False,
            pmtu           : pmtu,
            dmaReadMetaData: DmaReadMetaData {
                initiator: DMA_SRC_SQ_RD,
                sqpn     : cntrlStatus.comm.getSQPN,
                startAddr: dontCareValue,
                len      : zeroExtend(pktLen),
                mrID     : dontCareValue
            }
        };
        payloadGenerator.srvPort.request.put(payloadGenReq);
    endrule

    rule recvPayloadGenResp if (cntrlStatus.comm.isRTS);
        let payloadGenResp <- payloadGenerator.srvPort.response.get;
        immAssert(
            !payloadGenResp.isRespErr,
            "payloadGenResp error assertion @ mkTestPayloadConAndGenNormalCase",
            $format(
                "payloadGenResp.isRespErr=", fshow(payloadGenResp.isRespErr),
                " should be false"
            )
        );
    endrule

    rule genPayloadConReq if (cntrlStatus.comm.isRTS);
        let pktLen = pktLenPipeOut4Con.first;
        pktLenPipeOut4Con.deq;

        let startPktSeqNum = cntrl.contextSQ.getNPSN;
        let { isOnlyPkt, totalPktNum, nextPktSeqNum, endPktSeqNum } = calcPktNumNextAndEndPSN(
            startPktSeqNum,
            zeroExtend(pktLen),
            cntrlStatus.comm.getPMTU
        );
        cntrl.contextSQ.setNPSN(nextPktSeqNum);

        let { totalFragNum, lastFragByteEn, lastFragValidByteNum } =
            calcTotalFragNumByLength(zeroExtend(pktLen));

        let payloadConReq = PayloadConReq {
            fragNum      : truncate(totalFragNum),
            consumeInfo  : tagged SendWriteReqReadRespInfo DmaWriteMetaData {
                initiator: DMA_SRC_SQ_WR,
                sqpn     : cntrlStatus.comm.getSQPN,
                startAddr: dontCareValue,
                len      : pktLen,
                psn      : startPktSeqNum,
                mrID     : dontCareValue
            }
        };
        payloadConsumer.request.put(payloadConReq);
        payloadConReqPsnQ.enq(startPktSeqNum);
    endrule

    rule comparePayloadConResp;
        let payloadConResp <- payloadConsumer.response.get;

        let expectedPSN = payloadConReqPsnQ.first;
        payloadConReqPsnQ.deq;

        immAssert(
            payloadConResp.dmaWriteResp.psn == expectedPSN,
            "payloadConResp PSN assertion @ mkTestPayloadConAndGenNormalCase",
            $format(
                "payloadConResp.dmaWriteResp.psn=%h should == expectedPSN=%h",
                payloadConResp.dmaWriteResp.psn, expectedPSN
            )
        );
        // $display(
        //     "time=%0t: payloadConResp.dmaWriteResp.psn=%h should == expectedPSN=%h",
        //     $time, payloadConResp.dmaWriteResp.psn, expectedPSN
        // );
    endrule

    rule comparePayloadDataStream;
        let dmaReadPayload = simDmaReadSrvDataStreamPipeOut.first;
        simDmaReadSrvDataStreamPipeOut.deq;
        let dmaWritePayload = simDmaWriteSrvDataStreamPipeOut.first;
        simDmaWriteSrvDataStreamPipeOut.deq;

        immAssert(
            dmaReadPayload == dmaWritePayload,
            "dmaReadPayload == dmaWritePayload assertion @ mkTestPayloadConAndGenNormalCase",
            $format(
                "dmaReadPayload=", fshow(dmaReadPayload),
                " should == dmaWritePayload=", fshow(dmaWritePayload)
            )
        );

        // $display(
        //     "time=%0t:", $time,
        //     " dmaReadPayload=", fshow(dmaReadPayload),
        //     " should == dmaWritePayload=", fshow(dmaWritePayload)
        // );
        countDown.decr;
    endrule
endmodule

(* doc = "testcase" *)
module mkTestPayloadGenSegmentAndPaddingCase(Empty);
    let minPktLen = 1;
    let maxPktLen = 4096;
    let qpType = IBV_QPT_XRC_SEND;
    let pmtu = IBV_MTU_256;

    let cntrl <- mkSimCntrl(qpType, pmtu);
    let cntrlStatus = cntrl.contextSQ.statusSQ;

    let payloadLenPipeOut <- mkRandomLenPipeOut(minPktLen, maxPktLen);

    let simDmaReadSrv <- mkSimDmaReadSrvAndDataStreamPipeOut;
    let dataStreamWithPaddingPipeOut <- mkDataStreamAddPadding(
        simDmaReadSrv.dataStream
    );
    let segmentedPayloadPipeOut4Ref <- mkBufferN(2, dataStreamWithPaddingPipeOut);

    let dmaReadCntrl <- mkDmaReadCntrl(
        cntrlStatus, simDmaReadSrv.dmaReadSrv
    );
    let payloadGenerator <- mkPayloadGenerator(
        cntrlStatus, dmaReadCntrl
    );

    FIFOF#(Tuple6#(TotalFragNum, ByteEn, PktFragNum, PktNum, Bool, Bool)) payloadStatsQ <- mkFIFOF;
    Count#(TotalFragNum) remainingTotalFragCnt <- mkCount(0);
    Count#(PktFragNum) remainingPktFragCnt <- mkCount(0);
    Count#(PktNum) remainingPktCnt <- mkCount(0);
    Reg#(Bool) isNextPayloadGenReq <- mkReg(True);

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    // PipeOut need to handle:
    // - payloadLenPipeOut
    // - payloadGenerator.payloadDataStreamPipeOut
    // - segmentedPayloadPipeOut4Ref

    rule genPayloadGenReq if (cntrlStatus.comm.isNonErr);
        let payloadLen = payloadLenPipeOut.first;
        payloadLenPipeOut.deq;

        let payloadGenReq = PayloadGenReq {
            // segment      : True,
            addPadding     : True,
            pmtu           : pmtu,
            dmaReadMetaData: DmaReadMetaData {
                initiator: DMA_SRC_SQ_RD,
                sqpn     : cntrlStatus.comm.getSQPN,
                startAddr: dontCareValue,
                len      : payloadLen,
                mrID     : dontCareValue
            }
        };
        payloadGenerator.srvPort.request.put(payloadGenReq);

        let maxPktFragNum = calcFragNumByPmtu(pmtu);
        let { totalFragNum, lastFragByteEn, lastFragValidByteNum } =
            calcTotalFragNumByLength(payloadLen);
        let lastFragByteEnWithPadding = addPadding2LastFragByteEn(lastFragByteEn);
        let isOnlyFrag = isLessOrEqOne(totalFragNum);
        let { isOnlyPkt, pktNum } = calcPktNumByLength(payloadLen, pmtu);
        payloadStatsQ.enq(tuple6(
            totalFragNum, lastFragByteEnWithPadding, maxPktFragNum, pktNum, isOnlyPkt, isOnlyFrag
        ));
    endrule

    rule recvPayloadGenResp if (cntrlStatus.comm.isNonErr);
        let payloadGenResp <- payloadGenerator.srvPort.response.get;
        // let payloadGenResp = payloadGenerator.respPipeOut.first;
        // payloadGenerator.respPipeOut.deq;
        immAssert(
            !payloadGenResp.isRespErr,
            "payloadGenResp error assertion @ mkTestPayloadConAndGenNormalCase",
            $format(
                "payloadGenResp.isRespErr=", fshow(payloadGenResp.isRespErr),
                " should be false"
            )
        );
        countDown.decr;
    endrule

    rule comparePayloadDataStream if (cntrlStatus.comm.isNonErr);
        let segmentedPayload = payloadGenerator.payloadDataStreamPipeOut.first;
        payloadGenerator.payloadDataStreamPipeOut.deq;
        let segmentedPayloadRef = segmentedPayloadPipeOut4Ref.first;
        segmentedPayloadPipeOut4Ref.deq;

        let {
            totalFragNum, lastFragByteEnWithPadding, maxPktFragNum, pktNum, isOnlyPkt, isOnlyFrag
        } = payloadStatsQ.first;

        immAssert(
            segmentedPayload == segmentedPayloadRef,
            "segmentedPayload == segmentedPayloadRef assertion @ mkTestPayloadGenSegmentAndPaddingCase",
            $format(
                "segmentedPayload=", fshow(segmentedPayload),
                " should == segmentedPayloadRef=", fshow(segmentedPayloadRef)
            )
        );

        if (isNextPayloadGenReq) begin
            remainingTotalFragCnt <= totalFragNum - 1;
            remainingPktFragCnt <= maxPktFragNum - 1;
            remainingPktCnt <= pktNum;
        end
        else begin
            remainingTotalFragCnt.decr(1);

            if (segmentedPayload.isLast) begin
                remainingPktCnt.decr(1);
                remainingPktFragCnt <= maxPktFragNum;

                if (!isLessOrEqOne(remainingPktCnt)) begin
                    immAssert(
                        isOne(remainingPktFragCnt),
                        "remainingPktFragCnt assertion @ mkTestPayloadGenSegmentAndPaddingCase",
                        $format(
                            "remainingPktFragCnt=%0d", remainingPktFragCnt,
                            " should be one, when remainingPktCnt=%0d", remainingPktCnt,
                            " and segmentedPayload.isLast=", fshow(segmentedPayload.isLast)
                        )
                    );
                end
            end
            else begin
                remainingPktFragCnt.decr(1);
            end
        end

        if (isOnlyFrag || isOne(remainingTotalFragCnt)) begin
            payloadStatsQ.deq;
            isNextPayloadGenReq <= True;

            immAssert(
                segmentedPayload.isLast,
                "segmentedPayload.isLast assertion @ mkTestPayloadGenSegmentAndPaddingCase",
                $format(
                    "segmentedPayload.isLast=", fshow(segmentedPayload.isLast),
                    " should be true, when isOnlyFrag=", fshow(isOnlyFrag),
                    " or remainingTotalFragCnt=%0d", remainingTotalFragCnt
                )
            );
            immAssert(
                lastFragByteEnWithPadding == segmentedPayload.byteEn,
                "lastFragByteEnWithPadding assertion @ mkTestPayloadGenSegmentAndPaddingCase",
                $format(
                    "lastFragByteEnWithPadding=%h should == segmentedPayload.byteEn=%h",
                    lastFragByteEnWithPadding, segmentedPayload.byteEn,
                    ", when isOnlyFrag=", fshow(isOnlyFrag),
                    " or remainingTotalFragCnt=%0d", remainingTotalFragCnt
                )
            );

            if (isOnlyFrag) begin
                immAssert(
                    isOne(pktNum) && isOne(totalFragNum),
                    "pktNum and totalFragNum assertion @ mkTestPayloadGenSegmentAndPaddingCase",
                    $format(
                        "pktNum=%0d and totalFragNum=%0d", pktNum, totalFragNum,
                        " should both be one, when isOnlyFrag=", fshow(isOnlyFrag)
                    )
                );
            end
            else begin
                immAssert(
                    isOne(remainingPktCnt),
                    "remainingPktCnt assertion @ mkTestPayloadGenSegmentAndPaddingCase",
                    $format(
                        "remainingPktCnt=%0d", remainingPktCnt,
                        " should be one, when remainingTotalFragCnt=%0d", remainingTotalFragCnt
                    )
                );
            end
        end
        else begin
            isNextPayloadGenReq <= False;
        end

        // $display(
        //     "time=%0t: comparePayloadDataStream", $time,
        //     ", maxPktFragNum=%0d", maxPktFragNum,
        //     ", totalFragNum=%0d", totalFragNum,
        //     ", pktNum=%0d", pktNum,
        //     ", lastFragByteEnWithPadding=%h", lastFragByteEnWithPadding,
        //     ", isOnlyFrag=", fshow(isOnlyFrag),
        //     ", isOnlyPkt=", fshow(isOnlyPkt),
        //     ", isNextPayloadGenReq=", fshow(isNextPayloadGenReq),
        //     ", remainingTotalFragCnt=%0d", remainingTotalFragCnt,
        //     ", remainingPktFragCnt=%0d", remainingPktFragCnt,
        //     ", remainingPktCnt=%0d", remainingPktCnt,
        //     ", segmentedPayload.isFirst=", fshow(segmentedPayload.isFirst),
        //     ", segmentedPayload.isLast=", fshow(segmentedPayload.isLast)
        //     // ", segmentedPayload=", fshow(segmentedPayload),
        //     // " should == segmentedPayloadRef=", fshow(segmentedPayloadRef)
        // );
    endrule
endmodule
