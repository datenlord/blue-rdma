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

(* synthesize *)
module mkTestPayloadConAndGenNormalCase(Empty);
    let minpktLen = 2048;
    let maxpktLen = 4096;
    let qpType = IBV_QPT_XRC_SEND;
    let pmtu = IBV_MTU_4096;

    FIFOF#(PayloadGenReq) payloadGenReqQ <- mkFIFOF;
    FIFOF#(PayloadConReq) payloadConReqQ <- mkFIFOF;
    FIFOF#(PSN) payloadConReqPsnQ <- mkFIFOF;

    let setExpectedPsnAsNextPSN = False;
    let cntrl <- mkSimController(qpType, pmtu, setExpectedPsnAsNextPSN);

    Vector#(2, PipeOut#(PktLen)) pktLenPipeOutVec <-
        mkRandomValueInRangePipeOut(minpktLen, maxpktLen);
    let pktLenPipeOut4Gen = pktLenPipeOutVec[0];
    let pktLenPipeOut4Con = pktLenPipeOutVec[1];

    let simDmaReadSrv <- mkSimDmaReadSrvAndDataStreamPipeOut;
    let simDmaReadSrvDataStreamPipeOut <- mkBufferN(2, simDmaReadSrv.dataStream);

    let payloadGenerator <- mkPayloadGenerator(
        cntrl, simDmaReadSrv.dmaReadSrv, convertFifo2PipeOut(payloadGenReqQ)
    );

    let simDmaWriteSrv <- mkSimDmaWriteSrvAndDataStreamPipeOut;
    let simDmaWriteSrvDataStreamPipeOut = simDmaWriteSrv.dataStream;
    let payloadConsumer <- mkPayloadConsumer(
        cntrl,
        payloadGenerator.payloadDataStreamPipeOut,
        simDmaWriteSrv.dmaWriteSrv,
        convertFifo2PipeOut(payloadConReqQ)
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

    rule genPayloadGenReq if (cntrl.isNonErr);
        let pktLen = pktLenPipeOut4Gen.first;
        pktLenPipeOut4Gen.deq;

        let payloadGenReq = PayloadGenReq {
            addPadding   : False,
            segment      : False,
            pmtu         : pmtu,
            dmaReadReq   : DmaReadReq {
                initiator: DMA_INIT_SQ_RD,
                sqpn     : cntrl.getSQPN,
                startAddr: dontCareValue,
                len      : zeroExtend(pktLen),
                wrID     : dontCareValue
            }
        };
        payloadGenReqQ.enq(payloadGenReq);
    endrule

    rule recvPayloadGenResp if (cntrl.isNonErr);
        let payloadGenResp = payloadGenerator.respPipeOut.first;
        payloadGenerator.respPipeOut.deq;

        immAssert(
            !payloadGenResp.isRespErr,
            "payloadGenResp error assertion @ mkTestPayloadConAndGenNormalCase",
            $format(
                "payloadGenResp.isRespErr=", fshow(payloadGenResp.isRespErr),
                " should be false"
            )
        );
    endrule

    rule genPayloadConReq if (cntrl.isNonErr);
        let pktLen = pktLenPipeOut4Con.first;
        pktLenPipeOut4Con.deq;

        let startPktSeqNum = cntrl.getNPSN;
        let { isOnlyPkt, totalPktNum, nextPktSeqNum, endPktSeqNum } = calcPktNumNextAndEndPSN(
            startPktSeqNum,
            zeroExtend(pktLen),
            cntrl.getPMTU
        );
        cntrl.setNPSN(nextPktSeqNum);

        let { totalFragNum, lastFragByteEn, lastFragValidByteNum } =
            calcTotalFragNumByLength(zeroExtend(pktLen));

        let payloadConReq = PayloadConReq {
            fragNum      : truncate(totalFragNum),
            consumeInfo  : tagged SendWriteReqReadRespInfo DmaWriteMetaData {
                initiator: DMA_INIT_SQ_WR,
                sqpn     : cntrl.getSQPN,
                startAddr: dontCareValue,
                len      : pktLen,
                psn      : startPktSeqNum
            }
        };
        payloadConReqQ.enq(payloadConReq);
        payloadConReqPsnQ.enq(startPktSeqNum);
    endrule

    rule comparePayloadConResp; // if (cntrl.isNonErr);
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

    let setExpectedPsnAsNextPSN = False;
    let cntrl <- mkSimController(qpType, pmtu, setExpectedPsnAsNextPSN);

    FIFOF#(PayloadGenReq) payloadGenReqQ <- mkFIFOF;
    Vector#(1, PipeOut#(PktLen)) pktLenPipeOutVec <-
        mkRandomValueInRangePipeOut(minpktLen, maxpktLen);
    let pktLenPipeOut4Gen = pktLenPipeOutVec[0];

    let simDmaReadSrv <- mkSimDmaReadSrvAndDataStreamPipeOut;
    let simDmaReadSrvDataStreamPipeOut <- mkBufferN(2, simDmaReadSrv.dataStream);
    let pmtuPipeOut <- mkConstantPipeOut(pmtu);
    let segmentedPayloadPipeOut4Ref <- mkSegmentDataStreamByPmtuAndAddPadCnt(
        simDmaReadSrvDataStreamPipeOut, pmtuPipeOut
    );

    let payloadGenerator <- mkPayloadGenerator(
        cntrl, simDmaReadSrv.dmaReadSrv, convertFifo2PipeOut(payloadGenReqQ)
    );

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    // PipeOut need to handle:
    // - pktLenPipeOut4Gen
    // - payloadGenerator.respPipeOut
    // - payloadGenerator.payloadDataStreamPipeOut
    // - segmentedPayloadPipeOut4Ref

    rule genPayloadGenReq if (cntrl.isNonErr);
        let pktLen = pktLenPipeOut4Gen.first;
        pktLenPipeOut4Gen.deq;

        let payloadGenReq = PayloadGenReq {
            addPadding   : True,
            segment      : True,
            pmtu         : pmtu,
            dmaReadReq   : DmaReadReq {
                initiator: DMA_INIT_SQ_RD,
                sqpn     : cntrl.getSQPN,
                startAddr: dontCareValue,
                len      : zeroExtend(pktLen),
                wrID     : dontCareValue
            }
        };
        payloadGenReqQ.enq(payloadGenReq);
    endrule

    rule recvPayloadGenResp if (cntrl.isNonErr);
        let payloadGenResp = payloadGenerator.respPipeOut.first;
        payloadGenerator.respPipeOut.deq;

        immAssert(
            !payloadGenResp.isRespErr,
            "payloadGenResp error assertion @ mkTestPayloadConAndGenNormalCase",
            $format(
                "payloadGenResp.isRespErr=", fshow(payloadGenResp.isRespErr),
                " should be false"
            )
        );
    endrule

    rule comparePayloadDataStream if (cntrl.isNonErr);
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
