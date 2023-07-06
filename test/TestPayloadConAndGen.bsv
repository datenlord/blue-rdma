import ClientServer :: *;
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

typedef enum {
    TEST_DMA_CNTRL_ISSUE_REQ,
    TEST_DMA_CNTRL_RUN_A_CYCLE,
    TEST_DMA_CNTRL_CANCEL,
    TEST_DMA_CNTRL_WAIT_IDLE
} TestDmaCntrlState deriving(Bits, Eq, FShow);

(* synthesize *)
module mkTestDmaReadCntrl(Empty);
    let minpktLen = 2048;
    let maxpktLen = 4096;
    let qpType = IBV_QPT_XRC_SEND;
    let pmtu = IBV_MTU_4096;

    let cntrl <- mkSimCntrl(qpType, pmtu);
    let cntrlStatus = cntrl.contextSQ.statusSQ;

    Vector#(1, PipeOut#(PktLen)) pktLenPipeOutVec <-
        mkRandomValueInRangePipeOut(minpktLen, maxpktLen);
    let pktLenPipeOut4Read = pktLenPipeOutVec[0];

    let simDmaReadSrv <- mkSimDmaReadSrv;
    let dmaReadCntrl <- mkDmaReadCntrl(simDmaReadSrv);

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

(* synthesize *)
module mkTestDmaWriteCntrl(Empty);
    let minpktLen = 2048;
    let maxpktLen = 4096;
    let qpType = IBV_QPT_XRC_SEND;
    let pmtu = IBV_MTU_4096;

    let cntrl <- mkSimCntrl(qpType, pmtu);
    let cntrlStatus = cntrl.contextSQ.statusSQ;

    Vector#(1, PipeOut#(PktLen)) pktLenPipeOutVec <-
        mkRandomValueInRangePipeOut(minpktLen, maxpktLen);
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

(* synthesize *)
module mkTestPayloadConAndGenNormalCase(Empty);
    let minpktLen = 2048;
    let maxpktLen = 4096;
    let qpType = IBV_QPT_XRC_SEND;
    let pmtu = IBV_MTU_4096;

    // FIFOF#(PayloadGenReq) payloadGenReqQ <- mkFIFOF;
    FIFOF#(PayloadConReq) payloadConReqQ <- mkFIFOF;
    FIFOF#(PSN) payloadConReqPsnQ <- mkFIFOF;

    let cntrl <- mkSimCntrl(qpType, pmtu);
    let cntrlStatus = cntrl.contextSQ.statusSQ;
    // let setExpectedPsnAsNextPSN = False;
    // let cntrl <- mkSimCntrlQP(qpType, pmtu, setExpectedPsnAsNextPSN);

    Vector#(2, PipeOut#(PktLen)) pktLenPipeOutVec <-
        mkRandomValueInRangePipeOut(minpktLen, maxpktLen);
    let pktLenPipeOut4Gen = pktLenPipeOutVec[0];
    let pktLenPipeOut4Con = pktLenPipeOutVec[1];

    let simDmaReadSrv <- mkSimDmaReadSrvAndDataStreamPipeOut;
    let simDmaReadSrvDataStreamPipeOut <- mkBufferN(2, simDmaReadSrv.dataStream);

    let dmaReadCntrl <- mkDmaReadCntrl(simDmaReadSrv.dmaReadSrv);
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
        payloadGenerator.payloadDataStreamPipeOut,
        dmaWriteCntrl,
        toPipeOut(payloadConReqQ)
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
        payloadConReqQ.enq(payloadConReq);
        payloadConReqPsnQ.enq(startPktSeqNum);
    endrule

    rule comparePayloadConResp;
        let payloadConResp = payloadConsumer.respPipeOut.first;
        payloadConsumer.respPipeOut.deq;

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

(* synthesize *)
module mkTestPayloadGenSegmentAndPaddingCase(Empty);
    let minpktLen = 2048;
    let maxpktLen = 4096;
    let qpType = IBV_QPT_XRC_SEND;
    let pmtu = IBV_MTU_4096;

    let cntrl <- mkSimCntrl(qpType, pmtu);
    let cntrlStatus = cntrl.contextSQ.statusSQ;
    // let setExpectedPsnAsNextPSN = False;
    // let cntrl <- mkSimCntrlQP(qpType, pmtu, setExpectedPsnAsNextPSN);

    // FIFOF#(PayloadGenReq) payloadGenReqQ <- mkFIFOF;
    Vector#(1, PipeOut#(PktLen)) pktLenPipeOutVec <-
        mkRandomValueInRangePipeOut(minpktLen, maxpktLen);
    let pktLenPipeOut4Gen = pktLenPipeOutVec[0];

    let simDmaReadSrv <- mkSimDmaReadSrvAndDataStreamPipeOut;
    let simDmaReadSrvDataStreamPipeOut <- mkBufferN(2, simDmaReadSrv.dataStream);
    let pmtuPipeOut <- mkConstantPipeOut(pmtu);
    let segmentedPayloadPipeOut4Ref <- mkSegmentDataStreamByPmtuAndAddPadCnt(
        simDmaReadSrvDataStreamPipeOut, pmtuPipeOut
    );

    let dmaReadCntrl <- mkDmaReadCntrl(simDmaReadSrv.dmaReadSrv);
    let payloadGenerator <- mkPayloadGenerator(
        cntrlStatus,
        dmaReadCntrl
        // toPipeOut(payloadGenReqQ)
    );

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    // PipeOut need to handle:
    // - pktLenPipeOut4Gen
    // - payloadGenerator.respPipeOut
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
