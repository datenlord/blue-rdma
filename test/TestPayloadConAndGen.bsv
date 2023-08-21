import ClientServer :: *;
import FIFOF :: *;
import GetPut :: *;
import PAClib :: *;
import BuildVector :: *;
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
    let minPktLen = 2048;
    let maxPktLen = 8192;
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

    let dut <- mkAddrChunkSrv(clearReg);

    PipeOut#(ADDR)  startAddrPipeOut <- mkGenericRandomPipeOut;
    let totalLenPipeOut <- mkRandomLenPipeOut(minPktLen, maxPktLen);
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

        let totalLen = totalLenPipeOut.first;
        totalLenPipeOut.deq;

        let pmtu = pmtuPipeOut.first;
        pmtuPipeOut.deq;

        let { tmpPktNum, pmtuResidue } = truncateLenByPMTU(
            totalLen, pmtu
        );
        let totalPktNum = tmpPktNum + (isZero(pmtuResidue) ? 0 : 1);
        pktNumReg   <= totalPktNum;
        residueReg  <= pmtuResidue;
        nextAddrReg <= startAddr;
        busyReg <= True;

        let addrChunkReq = AddrChunkReq {
            startAddr: startAddr,
            totalLen : totalLen,
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
            dmaAddr: nextAddrReg,
            dmaLen : (isLast && !isZeroResidue) ? zeroExtend(residueReg) : pmtuLen,
            isFirst: isFirst,
            isLast : isLast
        };
        respQ.enq(addrChunkResp);
    endrule

    rule checkResp;
        let addrChunkResp <- dut.srvPort.response.get;
        let expectedResp = respQ.first;
        respQ.deq;

        let expectedTotalLen = totalLenReg + zeroExtend(addrChunkResp.dmaLen);
        if (addrChunkResp.isFirst) begin
            expectedTotalLen = zeroExtend(addrChunkResp.dmaLen);
        end
        totalLenReg <= expectedTotalLen;

        immAssert(
            addrChunkResp.dmaAddr == expectedResp.dmaAddr &&
            addrChunkResp.dmaLen == expectedResp.dmaLen   &&
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

module mkTestDmaReadCntrlNormalOrCancelCase#(Bool normalOrCancelCase)(Empty);
    let minPktLen = 2048;
    let maxPktLen = 8192;
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

    PipeOut#(Bool)  randomCancelPipeOut <- mkGenericRandomPipeOut;
    Reg#(Bool)   isFinalRespLastFragReg <- mkReg(False);

    PipeOut#(ADDR)  startAddrPipeOut <- mkGenericRandomPipeOut;
    let totalLenPipeOut <- mkRandomLenPipeOut(minPktLen, maxPktLen);
    let pmtuPipeOut <- mkRandomItemFromVec(pmtuVec);

    let simDmaReadSrv <- mkSimDmaReadSrv;
    let dut <- mkDmaReadCntrl2(clearReg, simDmaReadSrv);

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    rule clearAll if (clearReg);
        clearReg <= False;
        canceledReg <= False;
        remainingFragNumReg <= 0;
        isFinalRespLastFragReg <= False;
        totalFragNumQ.clear;

        $display("time=%0t: clearAll", $time);
    endrule

    rule issueReq if (!clearReg);
        let startAddr = startAddrPipeOut.first;
        startAddrPipeOut.deq;

        let totalLen = totalLenPipeOut.first;
        totalLenPipeOut.deq;

        let pmtu = pmtuPipeOut.first;
        pmtuPipeOut.deq;

        let totalPktNum = calcPktNumByLenOnly(totalLen, pmtu);
        let { totalFragNum, lastFragByteEn, lastFragValidByteNum } =
            calcTotalFragNumByLength(totalLen);
        totalFragNumQ.enq(totalFragNum);

        let dmaReadCntrlReq = DmaReadCntrlReq {
            dmaReadReq   : DmaReadReq {
                initiator: DMA_SRC_SQ_RD,
                sqpn     : getDefaultQPN,
                startAddr: startAddr,
                len      : totalLen,
                wrID     : dontCareValue
            },
            pmtu         : pmtu
        };

        dut.srvPort.request.put(dmaReadCntrlReq);
        countDown.decr;

        $display(
            "time=%0t: issueReq", $time,
            ", totalLen=%0d", totalLen,
            ", totalPktNum=%0d", totalPktNum,
            ", totalFragNum=%0d", totalFragNum
        );
    endrule

    rule checkResp if (!clearReg && !dut.dmaCntrl.isIdle);
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

        $display(
            "time=%0t: checkResp", $time,
            ", remainingFragNumReg=%0d", remainingFragNumReg,
            ", isFirst=", fshow(dmaReadCntrlResp.dmaReadResp.dataStream.isFirst),
            ", isLast=", fshow(dmaReadCntrlResp.dmaReadResp.dataStream.isLast),
            ", isOrigFirst=", fshow(dmaReadCntrlResp.isOrigFirst),
            ", isOrigLast=", fshow(dmaReadCntrlResp.isOrigLast)
        );
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
                dut.dmaCntrl.cancel;
                canceledReg <= True;
                $display("time=%0t: dmaCntrl.cancel", $time);
            end
        end
    endrule

    rule waitGracefulStop if (!clearReg && dut.dmaCntrl.isIdle);
        clearReg <= True;

        immAssert(
            isFinalRespLastFragReg,
            "isFinalRespLastFragReg assertion @ mkTestDmaReadCntrlNormalOrCancelCase",
            $format(
                "isFinalRespLastFragReg=", fshow(isFinalRespLastFragReg),
                " should be true, when dut.dmaCntrl.isIdle=", fshow(dut.dmaCntrl.isIdle)
            )
        );
        $display("time=%0t: dmaCntrl.isIdle", $time);
    endrule
endmodule

typedef enum {
    TEST_DMA_CNTRL_ISSUE_REQ,
    TEST_DMA_CNTRL_RUN_A_CYCLE,
    TEST_DMA_CNTRL_CANCEL,
    TEST_DMA_CNTRL_WAIT_IDLE
} TestDmaCntrlState deriving(Bits, Eq, FShow);

(* doc = "testcase" *)
module mkTestDmaReadCntrl(Empty);
    let minPktLen = 2048;
    let maxPktLen = 4096;
    let qpType = IBV_QPT_XRC_SEND;
    let pmtu = IBV_MTU_4096;

    let cntrl <- mkSimCntrl(qpType, pmtu);
    let cntrlStatus = cntrl.contextSQ.statusSQ;

    Vector#(1, PipeOut#(PktLen)) pktLenPipeOutVec <-
        mkRandomValueInRangePipeOut(minPktLen, maxPktLen);
    let pktLenPipeOut4Read = pktLenPipeOutVec[0];

    let simDmaReadSrv <- mkSimDmaReadSrv;
    let dmaReadCntrl <- mkDmaReadCntrl(cntrlStatus, simDmaReadSrv);

    Reg#(TestDmaCntrlState) stateReg <- mkReg(TEST_DMA_CNTRL_ISSUE_REQ);
    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    rule issueReadReq if (stateReg == TEST_DMA_CNTRL_ISSUE_REQ);
        let pktLen = pktLenPipeOut4Read.first;
        pktLenPipeOut4Read.deq;

        let dmaReadReq = DmaReadReq {
            initiator: DMA_SRC_SQ_RD,
            sqpn     : cntrlStatus.comm.getSQPN,
            startAddr: dontCareValue,
            len      : zeroExtend(pktLen),
            wrID     : dontCareValue
        };
        dmaReadCntrl.srvPort.request.put(dmaReadReq);
        stateReg <= TEST_DMA_CNTRL_RUN_A_CYCLE;
    endrule

    rule runOneCycle if (stateReg == TEST_DMA_CNTRL_RUN_A_CYCLE);
        stateReg <= TEST_DMA_CNTRL_CANCEL;
    endrule

    rule cancelReq if (stateReg == TEST_DMA_CNTRL_CANCEL);
        dmaReadCntrl.dmaCntrl.cancel;
        stateReg <= TEST_DMA_CNTRL_WAIT_IDLE;
    endrule

    rule waitIdle if (stateReg == TEST_DMA_CNTRL_WAIT_IDLE && dmaReadCntrl.dmaCntrl.isIdle);
        stateReg <= TEST_DMA_CNTRL_ISSUE_REQ;
        countDown.decr;
    endrule
endmodule

(* doc = "testcase" *)
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
                psn      : dontCareValue
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

(* doc = "testcase" *)
module mkTestPayloadConAndGenNormalCase(Empty);
    let minPktLen = 2048;
    let maxPktLen = 4096;
    let qpType = IBV_QPT_XRC_SEND;
    let pmtu = IBV_MTU_4096;

    // FIFOF#(PayloadGenReq) payloadGenReqQ <- mkFIFOF;
    // FIFOF#(PayloadConReq) payloadConReqQ <- mkFIFOF;
    FIFOF#(PSN) payloadConReqPsnQ <- mkFIFOF;

    let cntrl <- mkSimCntrl(qpType, pmtu);
    let cntrlStatus = cntrl.contextSQ.statusSQ;
    // let setExpectedPsnAsNextPSN = False;
    // let cntrl <- mkSimCntrlQP(qpType, pmtu, setExpectedPsnAsNextPSN);

    Vector#(2, PipeOut#(PktLen)) pktLenPipeOutVec <-
        mkRandomValueInRangePipeOut(minPktLen, maxPktLen);
    let pktLenPipeOut4Gen = pktLenPipeOutVec[0];
    let pktLenPipeOut4Con = pktLenPipeOutVec[1];

    let simDmaReadSrv <- mkSimDmaReadSrvAndDataStreamPipeOut;
    let simDmaReadSrvDataStreamPipeOut <- mkBufferN(2, simDmaReadSrv.dataStream);

    let dmaReadCntrl <- mkDmaReadCntrl(cntrlStatus, simDmaReadSrv.dmaReadSrv);
    let payloadGenerator <- mkPayloadGenerator(
        cntrlStatus,
        dmaReadCntrl
        // toPipeOut(payloadGenReqQ)
    );

    let simDmaWriteSrv <- mkSimDmaWriteSrvAndDataStreamPipeOut;
    let simDmaWriteSrvDataStreamPipeOut = simDmaWriteSrv.dataStream;
    let dmaWriteCntrl <- mkDmaWriteCntrl(cntrlStatus, simDmaWriteSrv.dmaWriteSrv);
    let payloadConsumer <- mkPayloadConsumer(
        cntrlStatus,
        dmaWriteCntrl,
        payloadGenerator.payloadDataStreamPipeOut
        // toPipeOut(payloadConReqQ)
    );

    // Reg#(PSN) npsnReg <- mkReg(0);
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
            addPadding   : False,
            segment      : False,
            pmtu         : pmtu,
            dmaReadReq   : DmaReadReq {
                initiator: DMA_SRC_SQ_RD,
                sqpn     : cntrlStatus.comm.getSQPN,
                startAddr: dontCareValue,
                len      : zeroExtend(pktLen),
                wrID     : dontCareValue
            }
        };
        payloadGenerator.srvPort.request.put(payloadGenReq);
        // payloadGenReqQ.enq(payloadGenReq);
    endrule

    rule recvPayloadGenResp if (cntrlStatus.comm.isRTS);
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
    endrule

    rule genPayloadConReq if (cntrlStatus.comm.isRTS);
        let pktLen = pktLenPipeOut4Con.first;
        pktLenPipeOut4Con.deq;

        let startPktSeqNum = cntrl.contextSQ.getNPSN;
        // let startPktSeqNum = npsnReg;
        let { isOnlyPkt, totalPktNum, nextPktSeqNum, endPktSeqNum } = calcPktNumNextAndEndPSN(
            startPktSeqNum,
            zeroExtend(pktLen),
            cntrlStatus.comm.getPMTU
        );
        cntrl.contextSQ.setNPSN(nextPktSeqNum);
        // npsnReg <= nextPktSeqNum;

        let { totalFragNum, lastFragByteEn, lastFragValidByteNum } =
            calcTotalFragNumByLength(zeroExtend(pktLen));

        let payloadConReq = PayloadConReq {
            fragNum      : truncate(totalFragNum),
            consumeInfo  : tagged SendWriteReqReadRespInfo DmaWriteMetaData {
                initiator: DMA_SRC_SQ_WR,
                sqpn     : cntrlStatus.comm.getSQPN,
                startAddr: dontCareValue,
                len      : pktLen,
                psn      : startPktSeqNum
            }
        };
        // payloadConReqQ.enq(payloadConReq);
        payloadConsumer.request.put(payloadConReq);
        payloadConReqPsnQ.enq(startPktSeqNum);
    endrule

    rule comparePayloadConResp;
        let payloadConResp <- payloadConsumer.response.get;
        // let payloadConResp = payloadConsumer.respPipeOut.first;
        // payloadConsumer.respPipeOut.deq;

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
    let minPktLen = 2048;
    let maxPktLen = 4096;
    let qpType = IBV_QPT_XRC_SEND;
    let pmtu = IBV_MTU_4096;

    let cntrl <- mkSimCntrl(qpType, pmtu);
    let cntrlStatus = cntrl.contextSQ.statusSQ;
    // let setExpectedPsnAsNextPSN = False;
    // let cntrl <- mkSimCntrlQP(qpType, pmtu, setExpectedPsnAsNextPSN);

    // FIFOF#(PayloadGenReq) payloadGenReqQ <- mkFIFOF;
    Vector#(1, PipeOut#(PktLen)) pktLenPipeOutVec <-
        mkRandomValueInRangePipeOut(minPktLen, maxPktLen);
    let pktLenPipeOut4Gen = pktLenPipeOutVec[0];

    let simDmaReadSrv <- mkSimDmaReadSrvAndDataStreamPipeOut;
    let simDmaReadSrvDataStreamPipeOut <- mkBufferN(2, simDmaReadSrv.dataStream);
    let pmtuPipeOut <- mkConstantPipeOut(pmtu);
    let segmentedPayloadPipeOut4Ref <- mkSegmentDataStreamByPmtuAndAddPadCnt(
        simDmaReadSrvDataStreamPipeOut, pmtuPipeOut
    );

    let dmaReadCntrl <- mkDmaReadCntrl(cntrlStatus, simDmaReadSrv.dmaReadSrv);
    let payloadGenerator <- mkPayloadGenerator(
        cntrlStatus,
        dmaReadCntrl
        // toPipeOut(payloadGenReqQ)
    );

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    // PipeOut need to handle:
    // - pktLenPipeOut4Gen
    // - payloadGenerator.payloadDataStreamPipeOut
    // - segmentedPayloadPipeOut4Ref

    rule genPayloadGenReq if (cntrlStatus.comm.isNonErr);
        let pktLen = pktLenPipeOut4Gen.first;
        pktLenPipeOut4Gen.deq;

        let payloadGenReq = PayloadGenReq {
            addPadding   : True,
            segment      : True,
            pmtu         : pmtu,
            dmaReadReq   : DmaReadReq {
                initiator: DMA_SRC_SQ_RD,
                sqpn     : cntrlStatus.comm.getSQPN,
                startAddr: dontCareValue,
                len      : zeroExtend(pktLen),
                wrID     : dontCareValue
            }
        };
        payloadGenerator.srvPort.request.put(payloadGenReq);
        // payloadGenReqQ.enq(payloadGenReq);
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
    endrule

    rule comparePayloadDataStream if (cntrlStatus.comm.isNonErr);
        let segmentedPayload = payloadGenerator.payloadDataStreamPipeOut.first;
        payloadGenerator.payloadDataStreamPipeOut.deq;
        let segmentedPayloadRef = segmentedPayloadPipeOut4Ref.first;
        segmentedPayloadPipeOut4Ref.deq;

        immAssert(
            segmentedPayload == segmentedPayloadRef,
            "segmentedPayload == segmentedPayloadRef assertion @ mkTestPayloadGenSegmentAndPaddingCase",
            $format(
                "segmentedPayload=", fshow(segmentedPayload),
                " should == segmentedPayloadRef=", fshow(segmentedPayloadRef)
            )
        );

        countDown.decr;
        // $display(
        //     "time=%0t:", $time,
        //     " segmentedPayload=", fshow(segmentedPayload),
        //     " should == segmentedPayloadRef=", fshow(segmentedPayloadRef)
        // );
    endrule
endmodule

(* doc = "testcase" *)
module mkTestPayloadConAndGenNormalCase2(Empty);
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

    let dmaReadCntrl <- mkDmaReadCntrl2(
        cntrlStatus.comm.isReset, simDmaReadSrv.dmaReadSrv
    );
    let payloadGenerator <- mkPayloadGenerator2(
        cntrlStatus,
        dmaReadCntrl
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
            addPadding   : False,
            segment      : False,
            pmtu         : pmtu,
            dmaReadReq   : DmaReadReq {
                initiator: DMA_SRC_SQ_RD,
                sqpn     : cntrlStatus.comm.getSQPN,
                startAddr: dontCareValue,
                len      : zeroExtend(pktLen),
                wrID     : dontCareValue
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
                psn      : startPktSeqNum
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
module mkTestPayloadGenSegmentAndPaddingCase2(Empty);
    let minPktLen = 2048;
    let maxPktLen = 4096;
    let qpType = IBV_QPT_XRC_SEND;
    let pmtu = IBV_MTU_4096;

    let cntrl <- mkSimCntrl(qpType, pmtu);
    let cntrlStatus = cntrl.contextSQ.statusSQ;

    Vector#(1, PipeOut#(PktLen)) pktLenPipeOutVec <-
        mkRandomValueInRangePipeOut(minPktLen, maxPktLen);
    let pktLenPipeOut4Gen = pktLenPipeOutVec[0];

    let simDmaReadSrv <- mkSimDmaReadSrvAndDataStreamPipeOut;
    let simDmaReadSrvDataStreamPipeOut <- mkBufferN(2, simDmaReadSrv.dataStream);
    let pmtuPipeOut <- mkConstantPipeOut(pmtu);
    let segmentedPayloadPipeOut4Ref <- mkSegmentDataStreamByPmtuAndAddPadCnt(
        simDmaReadSrvDataStreamPipeOut, pmtuPipeOut
    );

    let dmaReadCntrl <- mkDmaReadCntrl2(
        cntrlStatus.comm.isReset, simDmaReadSrv.dmaReadSrv
    );
    let payloadGenerator <- mkPayloadGenerator2(
        cntrlStatus,
        dmaReadCntrl
    );

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    // PipeOut need to handle:
    // - pktLenPipeOut4Gen
    // - payloadGenerator.payloadDataStreamPipeOut
    // - segmentedPayloadPipeOut4Ref

    rule genPayloadGenReq if (cntrlStatus.comm.isNonErr);
        let pktLen = pktLenPipeOut4Gen.first;
        pktLenPipeOut4Gen.deq;

        let payloadGenReq = PayloadGenReq {
            addPadding   : True,
            segment      : True,
            pmtu         : pmtu,
            dmaReadReq   : DmaReadReq {
                initiator: DMA_SRC_SQ_RD,
                sqpn     : cntrlStatus.comm.getSQPN,
                startAddr: dontCareValue,
                len      : zeroExtend(pktLen),
                wrID     : dontCareValue
            }
        };
        payloadGenerator.srvPort.request.put(payloadGenReq);
        // payloadGenReqQ.enq(payloadGenReq);
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
    endrule

    rule comparePayloadDataStream if (cntrlStatus.comm.isNonErr);
        let segmentedPayload = payloadGenerator.payloadDataStreamPipeOut.first;
        payloadGenerator.payloadDataStreamPipeOut.deq;
        let segmentedPayloadRef = segmentedPayloadPipeOut4Ref.first;
        segmentedPayloadPipeOut4Ref.deq;

        immAssert(
            segmentedPayload == segmentedPayloadRef,
            "segmentedPayload == segmentedPayloadRef assertion @ mkTestPayloadGenSegmentAndPaddingCase",
            $format(
                "segmentedPayload=", fshow(segmentedPayload),
                " should == segmentedPayloadRef=", fshow(segmentedPayloadRef)
            )
        );

        countDown.decr;
        // $display(
        //     "time=%0t:", $time,
        //     " segmentedPayload=", fshow(segmentedPayload),
        //     " should == segmentedPayloadRef=", fshow(segmentedPayloadRef)
        // );
    endrule
endmodule
