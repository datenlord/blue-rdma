import ClientServer :: *;
import Cntrs :: *;
import FIFOF :: *;
import GetPut :: *;
import PAClib :: *;
import Vector :: *;

import Headers :: *;
import Controller :: *;
import DataTypes :: *;
import DupReadAtomicCache :: *;
import InputPktHandle :: *;
import MetaData :: *;
import PayloadConAndGen :: *;
import PrimUtils :: *;
import ReqHandleRQ :: *;
import SpecialFIFOF :: *;
import Settings :: *;
import SimDma :: *;
import SimExtractRdmaHeaderPayload :: *;
import SimGenRdmaReqResp :: *;
import Utils :: *;
import Utils4Test :: *;
import WorkCompGen :: *;

(* doc = "testcase" *)
module mkTestReqHandleTooManyReadAtomicReqCase(Empty);
    let qpType = IBV_QPT_RC;
    let pmtu = IBV_MTU_256;
    let minReadWorkReqLen = valueOf(TMul#(TMul#(3, DATA_BUS_BYTE_WIDTH), MAX_QP_DST_RD_ATOM));
    let maxReadWorkReqLen = valueOf(TMul#(TMul#(3, DATA_BUS_BYTE_WIDTH), MAX_QP_DST_RD_ATOM));

    let cntrl <- mkSimCntrl(qpType, pmtu);
    let cntrlStatus = cntrl.contextRQ.statusRQ;
    // let qpMetaData <- mkSimMetaData4SinigleQP(qpType, pmtu);
    // let qpIndex = getDefaultIndexQP;
    // let cntrl = qpMetaData.getCntrlByIndexQP(qpIndex);

    Vector#(1, PipeOut#(WorkReq)) readAtomicWorkReqPipeOutVec <- mkRandomReadWorkReq( // mkRandomReadOrAtomicWorkReq(
        fromInteger(minReadWorkReqLen), fromInteger(maxReadWorkReqLen)
    );
    let readAtomicWorkReqPipeOut = readAtomicWorkReqPipeOutVec[0];
    Vector#(2, PipeOut#(PendingWorkReq)) existingPendingWorkReqPipeOutVec <-
        mkExistingPendingWorkReqPipeOut(cntrl, readAtomicWorkReqPipeOut);
    let pendingWorkReqPipeOut4ReqGen = existingPendingWorkReqPipeOutVec[0];
    // Large buffer for pending WR to generate too many read/atomic requests
    let pendingWorkReqPipeOut4Resp  <- mkBufferN(
        valueOf(TMul#(MAX_QP_DST_RD_ATOM, 2)), existingPendingWorkReqPipeOutVec[1]
    );

    // Read response payload DataStream generation
    let simDmaReadSrv <- mkSimDmaReadSrv;

    // Generate RDMA requests
    let simReqGen <- mkSimGenRdmaReq(
        pendingWorkReqPipeOut4ReqGen, qpType, pmtu
    );
    let rdmaReqPipeOut = simReqGen.rdmaReqDataStreamPipeOut;
    // Add rule to check no pending WR output
    let addNoPendingWorkReqOutRule <- addRules(genEmptyPipeOutRule(
        simReqGen.pendingWorkReqPipeOut,
        "simReqGen.pendingWorkReqPipeOut empty assertion @ mkTestReqHandleTooManyReadAtomicReqCase"
    ));

    // Build RdmaPktMetaData and payload DataStream
    let pktMetaDataAndPayloadPipeOut <- mkSimExtractNormalHeaderPayload(
        rdmaReqPipeOut
    );
    // let isRespPktPipeIn = False;
    // let pktMetaDataAndPayloadPipeOut <- mkSimInputPktBuf4SingleQP(
    //     isRespPktPipeIn, rdmaReqPipeOut, qpMetaData
    // );
    let pktMetaDataPipeIn = pktMetaDataAndPayloadPipeOut.pktMetaData;

    // MR permission check
    let mrCheckPassOrFail = True;
    let permCheckSrv <- mkSimPermCheckSrv(mrCheckPassOrFail);

    // DupReadAtomicCache
    let dupReadAtomicCache <- mkDupReadAtomicCache(cntrlStatus.comm.getPMTU);

    FIFOF#(RecvReq) recvReqQ <- mkFIFOF;
    let recvReqBuf = toPipeOut(recvReqQ);

    // PayloadGenerator
    let dmaReadCntrl <- mkDmaReadCntrl(cntrlStatus, simDmaReadSrv);
    let payloadGenerator <- mkPayloadGenerator(
        cntrlStatus, dmaReadCntrl
    );

    // PayloadConsumer
    let simDmaWriteSrv <- mkSimDmaWriteSrv;
    let dmaWriteCntrl <- mkDmaWriteCntrl(cntrlStatus, simDmaWriteSrv);
    // let sendWriteReqPayloadPipeOut = simDmaWriteSrv.dataStream;
    let payloadConsumer <- mkPayloadConsumer(
        cntrlStatus,
        dmaWriteCntrl,
        pktMetaDataAndPayloadPipeOut.payload
        // dut.payloadConReqPipeOut
    );

    // DUT
    let dut <- mkReqHandleRQ(
        cntrl.contextRQ,
        payloadGenerator,
        permCheckSrv,
        dupReadAtomicCache,
        recvReqBuf,
        pktMetaDataPipeIn,
        payloadConsumer.request
    );
    // // Add rule to check no payloadConReq output
    // let addNoPayloadConReqOutRule <- addRules(genEmptyPipeOutRule(
    //     dut.payloadConReqPipeOut,
    //     "dut.payloadConReqPipeOut empty assertion @ mkTestReqHandleTooManyReadAtomicReqCase"
    // ));

    // WorkCompGenRQ
    // FIFOF#(PayloadConResp) payloadConRespQ <- mkFIFOF;
    let workCompGenRQ <- mkWorkCompGenRQ(
        cntrlStatus,
        payloadConsumer.response,
        // toPipeOut(payloadConRespQ),
        dut.workCompGenReqPipeOut
    );
    // Add rule to check no WC output
    let addNoWorkCompOutRule <- addRules(genEmptyPipeOutRule(
        workCompGenRQ.workCompPipeOut,
        "workCompGenRQ.workCompPipeOut empty assertion @ mkTestReqHandleTooManyReadAtomicReqCase"
    ));

    Reg#(Bool) errRespGenReg <- mkReg(False);

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    rule flushWorkReq if (errRespGenReg);
        pendingWorkReqPipeOut4Resp.deq;
        // $display(
        //     "time=%0t:", $time,
        //     " dut.rdmaRespDataStreamPipeOut.notEmpty=",
        //     fshow(dut.rdmaRespDataStreamPipeOut.notEmpty),
        //     // ", remainingDestReadAtomicReqCnt=%0d",
        //     // remainingDestReadAtomicReqCnt,
        //     ", errRespGenReg=", fshow(errRespGenReg)
        // );

        immAssert(
            !dut.rdmaRespDataStreamPipeOut.notEmpty,
            "dut.rdmaRespDataStreamPipeOut empty assertion @ mkTestReqHandleTooManyReadAtomicReqCase",
            $format(
                "dut.rdmaRespDataStreamPipeOut.notEmpty=",
                fshow(dut.rdmaRespDataStreamPipeOut.notEmpty),
                " should be false when errRespGenReg=",
                fshow(errRespGenReg)
            )
        );

        countDown.decr;
    endrule

    // mkSink(dut.rdmaRespDataStreamPipeOut);
    rule compareRespAndWorkReq if (!errRespGenReg);
        let rdmaRespDataStream = dut.rdmaRespDataStreamPipeOut.first;
        dut.rdmaRespDataStreamPipeOut.deq;

        let pendingWR = pendingWorkReqPipeOut4Resp.first;
        // $display(
        //     "time=%0t:", $time,
        //     " dut.rdmaRespDataStreamPipeOut.notEmpty=",
        //     fshow(dut.rdmaRespDataStreamPipeOut.notEmpty),
        //     // ", remainingDestReadAtomicReqCnt=%0d",
        //     // remainingDestReadAtomicReqCnt,
        //     ", errRespGenReg=", fshow(errRespGenReg)
        // );

        if (rdmaRespDataStream.isFirst) begin
            let bth = extractBTH(zeroExtendLSB(rdmaRespDataStream.data));
            let startPSN = unwrapMaybe(pendingWR.startPSN);
            let endPSN = unwrapMaybe(pendingWR.endPSN);

            if (bth.opcode == ACKNOWLEDGE) begin
            // if (isZero(remainingDestReadAtomicReqCnt)) begin
                pendingWorkReqPipeOut4Resp.deq;
                errRespGenReg <= True;

                immAssert(
                    bth.psn == startPSN,
                    "startPSN assertion @ mkTestReqHandleTooManyReadAtomicReqCase",
                    $format(
                        "bth.psn=%h should == startPSN=%h",
                        bth.psn, startPSN,
                        " when bth.opcode=", fshow(bth.opcode)
                    )
                );
                // immAssert(
                //     bth.opcode == ACKNOWLEDGE,
                //     "bth.opcode assertion @ mkTestReqHandleTooManyReadAtomicReqCase",
                //     $format(
                //         "bth.opcode=", fshow(bth.opcode),
                //         " should be ACKNOWLEDGE",
                //         " when remainingDestReadAtomicReqCnt=%0d",
                //         remainingDestReadAtomicReqCnt
                //     )
                // );
                let aeth = extractAETH(zeroExtendLSB(rdmaRespDataStream.data));
                immAssert(
                    aeth.code == AETH_CODE_NAK,
                    "aeth.code assertion @ mkTestReqHandleTooManyReadAtomicReqCase",
                    $format(
                        "aeth.code=", fshow(aeth.code), " should be NAK",
                        " when bth.opcode=", fshow(bth.opcode)
                    )
                );
                immAssert(
                    aeth.value == zeroExtend(pack(AETH_NAK_INV_REQ)),
                    "aeth.value assertion @ mkTestReqHandleTooManyReadAtomicReqCase",
                    $format(
                        "aeth.value=", fshow(aeth.value), " should be AETH_NAK_INV_REQ",
                        " when bth.opcode=", fshow(bth.opcode)
                    )
                );
                immAssert(
                    rdmaRespDataStream.isFirst && rdmaRespDataStream.isLast,
                    "rdmaRespDataStream single fragment assertion @ mkTestReqHandleTooManyReadAtomicReqCase",
                    $format(
                        "rdmaRespDataStream.isFirst=", fshow(rdmaRespDataStream.isFirst),
                        " and rdmaRespDataStream.isLast=", fshow(rdmaRespDataStream.isLast),
                        " should both be true when bth.opcode=", fshow(bth.opcode)
                    )
                );
            end
            else begin
                immAssert(
                    isReadRespRdmaOpCode(bth.opcode) || bth.opcode == ATOMIC_ACKNOWLEDGE,
                    "isReadRespRdmaOpCode assertion @ mkTestReqHandleTooManyReadAtomicReqCase",
                    $format(
                        "bth.opcode=", fshow(bth.opcode),
                        " should be read response or ATOMIC_ACKNOWLEDGE",
                        " when errRespGenReg=", fshow(errRespGenReg)
                    )
                );

                if (bth.psn == endPSN) begin
                    pendingWorkReqPipeOut4Resp.deq;
                    // remainingDestReadAtomicReqCnt.decr(1);
                end
            end
        end
    endrule
endmodule

(* doc = "testcase" *)
module mkTestReqHandleNoAckReqCase(Empty);
    let minPayloadLen = 1;
    let maxPayloadLen = 2048;
    let qpType = IBV_QPT_XRC_SEND;
    let pmtu = IBV_MTU_256;

    let cntrl <- mkSimCntrl(qpType, pmtu);
    let cntrlStatus = cntrl.contextRQ.statusRQ;
    // let qpMetaData <- mkSimMetaData4SinigleQP(qpType, pmtu);
    // let qpIndex = getDefaultIndexQP;
    // let cntrl = qpMetaData.getCntrlByIndexQP(qpIndex);

    // WorkReq generation
    Vector#(1, PipeOut#(WorkReq)) workReqPipeOutVec <- mkRandomSendOrWriteImmWorkReqWithNoAck(
        minPayloadLen, maxPayloadLen
    );
    let workReqPipeOut = workReqPipeOutVec[0];
    Vector#(3, PipeOut#(PendingWorkReq)) existingPendingWorkReqPipeOutVec <-
        mkExistingPendingWorkReqPipeOut(cntrl, workReqPipeOut);
    let normalPendingWorkReqPipeOut4ReqGen    = existingPendingWorkReqPipeOutVec[0];
    let normalPendingWorkReqPipeOut4WorkComp <- mkBufferN(8, existingPendingWorkReqPipeOutVec[1]);
    let normalPendingWorkReqPipeOut4Resp     <- mkBufferN(8, existingPendingWorkReqPipeOutVec[2]);

    // Read response payload DataStream generation
    let simDmaReadSrv <- mkSimDmaReadSrv;
    // TODO: check read response payload
    // let simDmaReadSrv <- mkSimDmaReadSrvAndDataStreamPipeOut;
    // let readRespPayloadPipeOutBuf <- mkBufferN(32, simDmaReadSrv.dataStream);
    // let pmtuPipeOut4ReadResp <- mkConstantPipeOut(pmtu);
    // let readRespPayloadPipeOut4Ref <- mkSegmentDataStreamByPmtuAndAddPadCnt(
    //     readRespPayloadPipeOutBuf, pmtuPipeOut4ReadResp
    // );

    // Generate RDMA requests
    let simReqGen <- mkSimGenRdmaReq(
        normalPendingWorkReqPipeOut4ReqGen, qpType, pmtu
    );
    let rdmaReqPipeOut = simReqGen.rdmaReqDataStreamPipeOut;
    // Add rule to check no pending WR output
    let addNoPendingWorkReqOutRule <- addRules(genEmptyPipeOutRule(
        simReqGen.pendingWorkReqPipeOut,
        "simReqGen.pendingWorkReqPipeOut empty assertion @ mkTestReqHandleNoAckReqCase"
    ));

    // Build RdmaPktMetaData and payload DataStream
    let pktMetaDataAndPayloadPipeOut <- mkSimExtractNormalHeaderPayload(
        rdmaReqPipeOut
    );
    // let isRespPktPipeIn = False;
    // let pktMetaDataAndPayloadPipeOut <- mkSimInputPktBuf4SingleQP(
    //     isRespPktPipeIn, rdmaReqPipeOut, qpMetaData
    // );
    let pktMetaDataPipeIn = pktMetaDataAndPayloadPipeOut.pktMetaData;

    // MR permission check
    let mrCheckPassOrFail = True;
    let permCheckSrv <- mkSimPermCheckSrv(mrCheckPassOrFail);

    // DupReadAtomicCache
    let dupReadAtomicCache <- mkDupReadAtomicCache(cntrlStatus.comm.getPMTU);

    // RecvReq
    Vector#(2, PipeOut#(RecvReq)) recvReqBufVec <- mkSimGenRecvReq;
    let recvReqBuf = recvReqBufVec[0];
    let recvReqBuf4Ref <- mkBufferN(8, recvReqBufVec[1]);
    Reg#(Bool) recvReqBufReadyReg <- mkReg(False);

    // PayloadGenerator
    let dmaReadCntrl <- mkDmaReadCntrl(cntrlStatus, simDmaReadSrv);
    let payloadGenerator <- mkPayloadGenerator(
        cntrlStatus, dmaReadCntrl
    );

    // PayloadConsumer
    let simDmaWriteSrv <- mkSimDmaWriteSrv;
    let dmaWriteCntrl <- mkDmaWriteCntrl(cntrlStatus, simDmaWriteSrv);
    // let sendWriteReqPayloadPipeOut = simDmaWriteSrv.dataStream;
    let payloadConsumer <- mkPayloadConsumer(
        cntrlStatus,
        dmaWriteCntrl,
        pktMetaDataAndPayloadPipeOut.payload
        // dut.payloadConReqPipeOut
    );

    // DUT
    let dut <- mkReqHandleRQ(
        cntrl.contextRQ,
        payloadGenerator,
        permCheckSrv,
        dupReadAtomicCache,
        recvReqBuf,
        pktMetaDataPipeIn,
        payloadConsumer.request
    );

    // WorkCompGenRQ
    // FIFOF#(WorkCompGenReqRQ) wcGenReqQ4ReqGenInRQ <- mkFIFOF;
    let workCompGenRQ <- mkWorkCompGenRQ(
        cntrlStatus,
        payloadConsumer.response,
        // payloadConsumer.respPipeOut,
        dut.workCompGenReqPipeOut
    );
    // let workCompPipeOut4WorkReq = workCompGenRQ.workCompPipeOut;
    Vector#(2, PipeOut#(WorkComp)) workCompPipeOutVec <-
        mkForkVector(workCompGenRQ.workCompPipeOut);
    let workCompPipeOut4RecvReq = workCompPipeOutVec[0];
    let workCompPipeOut4WorkReq = workCompPipeOutVec[1];

    Count#(MSN) msnCnt <- mkCount(0);
    Count#(PendingReqCnt) pendingWorkReqCnt <- mkCount(
        fromInteger(valueOf(TSub#(MAX_QP_WR, 1)))
    );

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    // PipeOut need to handle:
    // mkSink(normalPendingWorkReqPipeOut4WorkComp);
    // mkSink(workCompPipeOut4WorkReq);
    // mkSink(payloadConsumer.respPipeOut);
    // mkSink(dut.workCompGenReqPipeOut);
    // mkSink(normalPendingWorkReqPipeOut4Resp);
    // mkSink(dut.rdmaRespDataStreamPipeOut);

    rule checkRecvReqReady;
        if (recvReqBuf.notEmpty) begin
            recvReqBufReadyReg <= True;
        end

        if (recvReqBufReadyReg) begin
            immAssert(
                recvReqBuf.notEmpty,
                "recvReqBuf.notEmpty assertion @ mkTestReqHandleNoAckReqCase",
                $format(
                    "recvReqBuf.notEmpty=", fshow(recvReqBuf.notEmpty),
                    " should always be true"
                )
            );
        end
    endrule

    rule compareWorkCompWithRecvReq;
        let rr = recvReqBuf4Ref.first;
        recvReqBuf4Ref.deq;

        let wc = workCompPipeOut4RecvReq.first;
        workCompPipeOut4RecvReq.deq;

        immAssert(
            wc.id == rr.id,
            "WC ID assertion @ mkTestReqHandleNoAckReqCase",
            $format(
                "wc.id=%h should == rr.id=%h",
                wc.id, rr.id
            )
        );

        immAssert(
            wc.status == IBV_WC_SUCCESS,
            "WC status assertion @ mkTestReqHandleNoAckReqCase",
            $format(
                "wc.status=", fshow(wc.status),
                " should be success"
            )
        );
    endrule

    rule compareRespAndWorkReq;
        let pendingWR = normalPendingWorkReqPipeOut4Resp.first;
        normalPendingWorkReqPipeOut4Resp.deq;

        msnCnt.incr(1);
        // $display(
        //     "time=%0t:", $time,
        //     " dut.rdmaRespDataStreamPipeOut.notEmpty=",
        //     fshow(dut.rdmaRespDataStreamPipeOut.notEmpty),
        //     ", msnCnt=%0d, pendingWorkReqCnt=%0d",
        //     msnCnt, pendingWorkReqCnt
        // );

        countDown.decr;

        if (isZero(pendingWorkReqCnt)) begin
            let rdmaRespDataStream = dut.rdmaRespDataStreamPipeOut.first;
            dut.rdmaRespDataStreamPipeOut.deq;

            let bth = extractBTH(zeroExtendLSB(rdmaRespDataStream.data));
            let endPSN = unwrapMaybe(pendingWR.endPSN);
            immAssert(
                bth.psn == endPSN,
                "endPSN assertion @ mkTestReqHandleNoAckReqCase",
                $format(
                    "bth.psn=%h should == endPSN=%h",
                    bth.psn, endPSN
                )
            );
            immAssert(
                bth.opcode == ACKNOWLEDGE,
                "bth.opcode assertion @ mkTestReqHandleNoAckReqCase",
                $format(
                    "bth.opcode=", fshow(bth.opcode),
                    " should be ACKNOWLEDGE"
                )
            );
            immAssert(
                rdmaRespDataStream.isFirst && rdmaRespDataStream.isLast,
                "rdmaRespDataStream single fragment assertion @ mkTestReqHandleNoAckReqCase",
                $format(
                    "rdmaRespDataStream.isFirst=", fshow(rdmaRespDataStream.isFirst),
                    " and rdmaRespDataStream.isLast=", fshow(rdmaRespDataStream.isLast),
                    " should both be true when bth.psn=%h", bth.psn
                )
            );

            let aeth = extractAETH(zeroExtendLSB(rdmaRespDataStream.data));
            immAssert(
                aeth.code == AETH_CODE_ACK,
                "aeth.code assertion @ mkTestReqHandleNoAckReqCase",
                $format(
                    "aeth.code=", fshow(aeth.code), " should be normal ACK"
                )
            );

            let expectedMSN = msnCnt + 1;
            immAssert(
                aeth.msn == expectedMSN,
                "msn assertion @ mkTestReqHandleNoAckReqCase",
                $format(
                    "aeth.msn=%0d should == expected MSN=%0d",
                    aeth.msn, expectedMSN
                )
            );

            pendingWorkReqCnt <= cntrlStatus.comm.getPendingWorkReqNum - 1;
        end
        else begin
            pendingWorkReqCnt.decr(1);
        end
    endrule

    rule compareWorkComp;
        let pendingWR = normalPendingWorkReqPipeOut4WorkComp.first;
        normalPendingWorkReqPipeOut4WorkComp.deq;
        let wc = workCompPipeOut4WorkReq.first;
        workCompPipeOut4WorkReq.deq;

        immAssert(
            workReqNeedRecvReq(pendingWR.wr.opcode),
            "workReqNeedRecvReq assertion @ mkTestReqHandleNoAckReqCase",
            $format(
                "pendingWR.wr.opcode=", fshow(pendingWR.wr.opcode),
                " should need RecvReq"
            )
        );
        immAssert(
            workCompMatchWorkReqInRQ(wc, pendingWR.wr),
            "workCompMatchWorkReqInRQ assertion @ mkTestReqHandleNoAckReqCase",
            $format("WC=", fshow(wc), " not match WR=", fshow(pendingWR.wr))
        );
    endrule
endmodule

(* doc = "testcase" *)
module mkTestReqHandleNormalReqCase(Empty);
    let normalOrDupReq = True;
    let result <- mkTestReqHandleNormalAndDupReqCase(normalOrDupReq);
endmodule

(* doc = "testcase" *)
module mkTestReqHandleDupReqCase(Empty);
    let normalOrDupReq = False;
    let result <- mkTestReqHandleNormalAndDupReqCase(normalOrDupReq);
endmodule

module mkNonZeroSendWriteReqPayloadPipeOut#(
    PipeOut#(Bool) filterPipeIn,
    PipeOut#(PendingWorkReq) pendingWorkReqPipeOut,
    DataStreamPipeOut dataStreamPipeIn
)(DataStreamPipeOut);
    FIFOF#(DataStream) dataStreamOutQ <- mkFIFOF;

    rule filterDataStream;
        let select = filterPipeIn.first;
        let pendingWR = pendingWorkReqPipeOut.first;
        let isNonZeroSendWriteWR = workReqNeedDmaReadSQ(pendingWR.wr);

        if (isNonZeroSendWriteWR) begin
            let dataStream = dataStreamPipeIn.first;
            dataStreamPipeIn.deq;

            if (select) begin
                dataStreamOutQ.enq(dataStream);
            end

            if (dataStream.isLast) begin
                filterPipeIn.deq;
                pendingWorkReqPipeOut.deq;
            end
        end
        else begin
            filterPipeIn.deq;
            pendingWorkReqPipeOut.deq;
        end
    endrule

    return toPipeOut(dataStreamOutQ);
endmodule

module mkTestReqHandleNormalAndDupReqCase#(Bool normalOrDupReq)(Empty);
    let minPayloadLen = 1;
    let maxPayloadLen = 2048;
    let qpType = IBV_QPT_XRC_SEND;
    let pmtu = IBV_MTU_256;

    let cntrl <- mkSimCntrl(qpType, pmtu);
    let cntrlStatus = cntrl.contextRQ.statusRQ;

    // WorkReq generation
    Vector#(1, PipeOut#(WorkReq)) workReqPipeOutVec <- mkRandomWorkReq(
        minPayloadLen, maxPayloadLen
    );
    let workReqPipeOut = workReqPipeOutVec[0];
    Vector#(1, PipeOut#(PendingWorkReq)) existingPendingWorkReqPipeOutVec <-
        mkExistingPendingWorkReqPipeOut(cntrl, workReqPipeOut);
    let { normalOrDupReqSelPipeOut, normalOrDupPendingWorkReqPipeOut } <- mkGenNormalOrDupWorkReq(
        normalOrDupReq, existingPendingWorkReqPipeOutVec[0]
    );
    Vector#(3, PipeOut#(Bool)) normalOrDupReqSelPipeOutVec <-
        mkForkVector(normalOrDupReqSelPipeOut);
    let normalOrDupReqSelPipeOut4WorkComp <- mkBufferN(8, normalOrDupReqSelPipeOutVec[0]);
    let normalOrDupReqSelPipeOut4Resp <- mkBufferN(8, normalOrDupReqSelPipeOutVec[1]);
    let normalOrDupReqSelPipeOut4SendWriteReq <- mkBufferN(8, normalOrDupReqSelPipeOutVec[2]);
    Vector#(4, PipeOut#(PendingWorkReq)) normalOrDupPendingWorkReqPipeOutVec <-
        mkForkVector(normalOrDupPendingWorkReqPipeOut);
    let normalOrDupPendingWorkReqPipeOut4ReqGen = normalOrDupPendingWorkReqPipeOutVec[0];
    let normalOrDupPendingWorkReqPipeOut4WorkComp <- mkBufferN(8, normalOrDupPendingWorkReqPipeOutVec[1]);
    let normalOrDupPendingWorkReqPipeOut4Resp <- mkBufferN(8, normalOrDupPendingWorkReqPipeOutVec[2]);
    let normalOrDupPendingWorkReqPipeOut4SendWriteReq <- mkBufferN(8, normalOrDupPendingWorkReqPipeOutVec[3]);

    // Read response payload DataStream generation
    let simDmaReadSrv <- mkSimDmaReadSrv;
    // TODO: check read response payload
    // let simDmaReadSrv <- mkSimDmaReadSrvAndDataStreamPipeOut;
    // let readRespPayloadPipeOutBuf <- mkBufferN(32, simDmaReadSrv.dataStream);
    // let pmtuPipeOut4ReadResp <- mkConstantPipeOut(pmtu);
    // let readRespPayloadPipeOut4Ref <- mkSegmentDataStreamByPmtuAndAddPadCnt(
    //     readRespPayloadPipeOutBuf, pmtuPipeOut4ReadResp
    // );

    // Generate RDMA requests
    let simReqGen <- mkSimGenRdmaReqAndSendWritePayloadPipeOut(
        normalOrDupPendingWorkReqPipeOut4ReqGen, qpType, pmtu
    );
    let rdmaReqPipeOut = simReqGen.rdmaReqDataStreamPipeOut;
    // Add rule to check no pending WR output
    let addNoPendingWorkReqOutRule <- addRules(genEmptyPipeOutRule(
        simReqGen.pendingWorkReqPipeOut,
        "simReqGen.pendingWorkReqPipeOut empty assertion @ mkTestReqHandleNormalAndDupReqCase"
    ));
    // Segment send/write payload DMA read DataStream
    let normalSendWriteReqPayloadPipeOut <- mkNonZeroSendWriteReqPayloadPipeOut(
        normalOrDupReqSelPipeOut4SendWriteReq,
        normalOrDupPendingWorkReqPipeOut4SendWriteReq,
        simReqGen.sendWriteReqPayloadPipeOut
    );
    let sendWriteReqPayloadPipeOutBuf <- mkBufferN(1024, normalSendWriteReqPayloadPipeOut);
    let pmtuPipeOut4SendWriteReq <- mkConstantPipeOut(pmtu);
    let sendWriteReqPayloadPipeOut4Ref <- mkSegmentDataStreamByPmtuAndAddPadCnt(
        sendWriteReqPayloadPipeOutBuf, pmtuPipeOut4SendWriteReq
    );

    // Build RdmaPktMetaData and payload DataStream
    let pktMetaDataAndPayloadPipeOut <- mkSimExtractNormalHeaderPayload(
        rdmaReqPipeOut
    );
    // let isRespPktPipeIn = False;
    // let pktMetaDataAndPayloadPipeOut <- mkSimInputPktBuf4SingleQP(
    //     isRespPktPipeIn, rdmaReqPipeOut, qpMetaData
    // );
    let pktMetaDataPipeIn = pktMetaDataAndPayloadPipeOut.pktMetaData;

    // MR permission check
    let mrCheckPassOrFail = True;
    let permCheckSrv <- mkSimPermCheckSrv(mrCheckPassOrFail);

    // DupReadAtomicCache
    let dupReadAtomicCache <- mkDupReadAtomicCache(cntrlStatus.comm.getPMTU);

    // RecvReq
    Vector#(1, PipeOut#(RecvReq)) recvReqBufVec <- mkSimGenRecvReq;
    let recvReqBuf = recvReqBufVec[0];
    // let recvReqBuf4Ref <- mkBufferN(1024, recvReqBufVec[1]);

    // PayloadGenerator
    let dmaReadCntrl <- mkDmaReadCntrl(cntrlStatus, simDmaReadSrv);
    let payloadGenerator <- mkPayloadGenerator(
        cntrlStatus, dmaReadCntrl
    );

    // PayloadConsumer
    let simDmaWriteSrv <- mkSimDmaWriteSrvAndDataStreamPipeOut;
    let dmaWriteCntrl <- mkDmaWriteCntrl(cntrlStatus, simDmaWriteSrv.dmaWriteSrv);
    let sendWriteReqPayloadPipeOut = simDmaWriteSrv.dataStream;
    let payloadConsumer <- mkPayloadConsumer(
        cntrlStatus,
        dmaWriteCntrl,
        pktMetaDataAndPayloadPipeOut.payload
        // dut.payloadConReqPipeOut
    );

    // DUT
    let dut <- mkReqHandleRQ(
        cntrl.contextRQ,
        payloadGenerator,
        permCheckSrv,
        dupReadAtomicCache,
        recvReqBuf,
        pktMetaDataPipeIn,
        payloadConsumer.request
    );

    // WorkCompGenRQ
    // FIFOF#(WorkCompGenReqRQ) wcGenReqQ4ReqGenInRQ <- mkFIFOF;
    let workCompGenRQ <- mkWorkCompGenRQ(
        cntrlStatus,
        payloadConsumer.response,
        // payloadConsumer.respPipeOut,
        dut.workCompGenReqPipeOut
    );
    let workCompPipeOut4WorkReq = workCompGenRQ.workCompPipeOut;

    Count#(MSN)                 msnCnt <- mkCount(0);
    Reg#(Long) normalAtomicRespOrigReg <- mkRegU;

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    // mkSink(normalOrDupReqSelPipeOut4SendWriteReq);
    // mkSink(normalOrDupPendingWorkReqPipeOut4SendWriteReq);
    // mkSink(simReqGen.sendWriteReqPayloadPipeOut);
    // mkSink(pktMetaDataPipeIn);
    // mkSink(pktMetaDataAndPayloadPipeOut.payload);
    // mkSink(dut.payloadConReqPipeOut);
    // mkSink(dut.workCompGenReqPipeOut);
    // mkSink(payloadConsumer.respPipeOut);
    // PipeOut need to compare:
    // mkSink(sendWriteReqPayloadPipeOut4Ref);
    // mkSink(sendWriteReqPayloadPipeOut);
    // mkSink(normalOrDupReqSelPipeOut4WorkComp);
    // mkSink(normalOrDupPendingWorkReqPipeOut4WorkComp);
    // mkSink(workCompPipeOut4WorkReq);
    // mkSink(normalOrDupPendingWorkReqPipeOut4Resp);
    // mkSink(dut.rdmaRespDataStreamPipeOut);
    // mkSink(normalOrDupReqSelPipeOut4Resp);

    // rule show;
    //     let sendWritePayloadDataStreamRef = sendWriteReqPayloadPipeOut.first;
    //     sendWriteReqPayloadPipeOut.deq;

    //     $display(
    //         "time=%0t: sendWritePayloadDataStreamRef.isFirst=",
    //         $time, fshow(sendWritePayloadDataStreamRef.isFirst),
    //         ", sendWritePayloadDataStreamRef.isLast=",
    //         fshow(sendWritePayloadDataStreamRef.isLast),
    //         ", sendWritePayloadDataStreamRef.byteEn=%h",
    //         sendWritePayloadDataStreamRef.byteEn
    //     );
    // endrule

    // TODO: compare RR and WC
    // rule compareWorkCompWithRecvReq;
    //     let rr = recvReqBuf4Ref.first;
    //     recvReqBuf4Ref.deq;

    //     let wc = workCompPipeOut4RecvReq.first;
    //     workCompPipeOut4RecvReq.deq;

    //     immAssert(
    //         wc.id == rr.id,
    //         "WC ID assertion @ mkTestReqHandleNormalCase",
    //         $format(
    //             "wc.id=%h should == rr.id=%h",
    //             wc.id, rr.id
    //         )
    //     );

    //     immAssert(
    //         wc.status == IBV_WC_SUCCESS,
    //         "WC status assertion @ mkTestReqHandleNormalCase",
    //         $format(
    //             "wc.status=", fshow(wc.status),
    //             " should be success"
    //         )
    //     );
    // endrule

    rule compareSendWriteReqPayload;
        let sendWritePayloadDataStreamRef = sendWriteReqPayloadPipeOut4Ref.first;
        sendWriteReqPayloadPipeOut4Ref.deq;

        let sendWritePayloadDataStream = sendWriteReqPayloadPipeOut.first;
        sendWriteReqPayloadPipeOut.deq;

        immAssert(
            sendWritePayloadDataStream == sendWritePayloadDataStreamRef,
            "sendWritePayloadDataStream assertion @ mkTestReqHandleNormalCase",
            $format(
                "sendWritePayloadDataStream=",
                fshow(sendWritePayloadDataStream),
                " should == sendWritePayloadDataStreamRef=",
                fshow(sendWritePayloadDataStreamRef)
            )
        );

        countDown.decr;
        // $display(
        //     "time=%0t: sendWritePayloadDataStream=", $time,
        //     fshow(sendWritePayloadDataStream),
        //     " should == sendWritePayloadDataStreamRef=",
        //     fshow(sendWritePayloadDataStreamRef)
        // );
    endrule

    rule compareWorkCompWithPendingWorkReq;
        let pendingWR = normalOrDupPendingWorkReqPipeOut4WorkComp.first;
        normalOrDupPendingWorkReqPipeOut4WorkComp.deq;
        let isNormalReq = normalOrDupReqSelPipeOut4WorkComp.first;
        normalOrDupReqSelPipeOut4WorkComp.deq;

        // $display("time=%0t: pendingWR=", $time, fshow(pendingWR));

        if (isNormalReq && workReqNeedRecvReq(pendingWR.wr.opcode)) begin
            let wc = workCompPipeOut4WorkReq.first;
            workCompPipeOut4WorkReq.deq;

            immAssert(
                workCompMatchWorkReqInRQ(wc, pendingWR.wr),
                "workCompMatchWorkReqInRQ assertion @ mkTestReqHandleNormalAndDupReqCase",
                $format("WC=", fshow(wc), " not match WR=", fshow(pendingWR.wr))
            );
            // $display("time=%0t: WC=", $time, fshow(wc));

            if (workReqHasImmDt(pendingWR.wr.opcode)) begin
                immAssert(
                    isValid(wc.immDt) && isValid(pendingWR.wr.immDt) &&
                    !isValid(wc.rkey2Inv) && !isValid(pendingWR.wr.rkey2Inv),
                    "WC has ImmDT assertion @ mkTestReqHandleNormalAndDupReqCase",
                    $format(
                        "wc.immDt=", fshow(wc.immDt),
                        " should be valid, and wc.rkey2Inv=",
                        fshow(wc.rkey2Inv), " should be invalid"
                    )
                );

                let wrImmDt = unwrapMaybe(pendingWR.wr.immDt);
                let wcImmDt = unwrapMaybe(wc.immDt);
                immAssert(
                    wrImmDt == wcImmDt,
                    "wc.immDt equal assertion @ mkTestReqHandleNormalAndDupReqCase",
                    $format(
                        "wc.immDt=", fshow(wcImmDt),
                        " should == pendingWR.wr.immDt=",
                        fshow(wrImmDt)
                    )
                );
            end
            else if (workReqHasInv(pendingWR.wr.opcode)) begin
                immAssert(
                    !isValid(wc.immDt) && !isValid(pendingWR.wr.immDt) &&
                    isValid(wc.rkey2Inv) && isValid(pendingWR.wr.rkey2Inv),
                    "WC has IETH assertion @ mkTestReqHandleNormalAndDupReqCase",
                    $format(
                        "wc.rkey2Inv=", fshow(wc.rkey2Inv),
                        " should be valid, and wc.immDt=",
                        fshow(wc.immDt), " should be invalid"
                    )
                );
                immAssert(
                    unwrapMaybe(pendingWR.wr.rkey2Inv) == unwrapMaybe(wc.rkey2Inv),
                    "wc.rkey2Inv equal assertion @ mkTestReqHandleNormalAndDupReqCase",
                    $format(
                        "wc.rkey2Inv=", fshow(unwrapMaybe(wc.rkey2Inv)),
                        " should == pendingWR.wr.rkey2Inv=",
                        fshow(unwrapMaybe(pendingWR.wr.rkey2Inv))
                    )
                );
            end
            else begin
                immAssert(
                    !isValid(wc.immDt) &&
                    !isValid(wc.rkey2Inv),
                    "WC has no ImmDT or IETH assertion @ mkTestReqHandleNormalAndDupReqCase",
                    $format(
                        "both wc.immDt=", fshow(wc.immDt),
                        " and wc.rkey2Inv=", fshow(wc.rkey2Inv),
                        " should be invalid"
                    )
                );
            end
        end
    endrule

    rule compareRespAETH;
        let rdmaRespDataStream = dut.rdmaRespDataStreamPipeOut.first;
        dut.rdmaRespDataStreamPipeOut.deq;

        let pendingWR = normalOrDupPendingWorkReqPipeOut4Resp.first;
        let isNormalReq = normalOrDupReqSelPipeOut4Resp.first;
        let isAtomicWR = isAtomicWorkReq(pendingWR.wr.opcode);

        if (rdmaRespDataStream.isFirst) begin
            let bth = extractBTH(zeroExtendLSB(rdmaRespDataStream.data));
            let endPSN = unwrapMaybe(pendingWR.endPSN);

            if (bth.psn == endPSN) begin
                normalOrDupPendingWorkReqPipeOut4Resp.deq;
                normalOrDupReqSelPipeOut4Resp.deq;
            end

            if (rdmaRespHasAETH(bth.opcode)) begin
                let aeth = extractAETH(zeroExtendLSB(rdmaRespDataStream.data));
                immAssert(
                    aeth.code == AETH_CODE_ACK,
                    "aeth.code assertion @ mkTestReqHandleNormalAndDupReqCase",
                    $format(
                        "aeth.code=", fshow(aeth.code),
                        " should be normal ACK"
                    )
                );

                if (normalOrDupReq) begin
                    let expectedMSN = msnCnt;
                    if (isLastOrOnlyRdmaOpCode(bth.opcode)) begin
                        expectedMSN = msnCnt + 1;
                        msnCnt.incr(1);
                    end

                    immAssert(
                        aeth.msn == expectedMSN,
                        "msn assertion @ mkTestReqHandleNormalAndDupReqCase",
                        $format(
                            "aeth.msn=%0d should == expected MSN=%0d",
                            aeth.msn, expectedMSN
                        )
                    );
                end
                $display(
                    "time=%0t:", $time,
                    ", response bth=", fshow(bth),
                    ", aeth=", fshow(aeth)
                );
            end
            else begin
                $display(
                    "time=%0t:", $time,
                    ", response bth=", fshow(bth),
                    ", pendingWR=", fshow(pendingWR)
                );
            end

            if (isAtomicWR) begin
                let atomicAckEth = extractAtomicAckEth(zeroExtendLSB(rdmaRespDataStream.data));
                if (isNormalReq) begin
                    normalAtomicRespOrigReg <= atomicAckEth.orig;
                end
                else begin
                    immAssert(
                        atomicAckEth.orig == normalAtomicRespOrigReg,
                        "atomicAckEth.orig assertion @ mkTestReqHandleNormalAndDupReqCase",
                        $format(
                            "atomicAckEth.orig=%h", atomicAckEth.orig,
                            " should == normalAtomicRespOrigReg=%h", normalAtomicRespOrigReg
                        )
                    );
                    $display(
                        "time=%0t:", $time,
                        ", atomicAckEth.orig=%h", atomicAckEth.orig,
                        ", should == normalAtomicRespOrigReg=%h", normalAtomicRespOrigReg
                    );
                end
            end
        end
    endrule
endmodule

typedef enum {
    REQ_HANDLE_ERROR_RESP,
    REQ_HANDLE_PERM_CHECK_FAIL,
    REQ_HANDLE_DMA_READ_ERR
} ReqHandleErrType deriving(Bits, Eq);

(* doc = "testcase" *)
module mkTestReqHandleReqErrCase(Empty);
    let errType = REQ_HANDLE_ERROR_RESP;
    let result <- mkTestReqHandleAbnormalCase(errType);
endmodule

(* doc = "testcase" *)
module mkTestReqHandlePermCheckFailCase(Empty);
    let errType = REQ_HANDLE_PERM_CHECK_FAIL;
    let result <- mkTestReqHandleAbnormalCase(errType);
endmodule

(* doc = "testcase" *)
module mkTestReqHandleDmaReadErrCase(Empty);
    let errType = REQ_HANDLE_DMA_READ_ERR;
    let result <- mkTestReqHandleAbnormalCase(errType);
endmodule

module mkTestReqHandleAbnormalCase#(ReqHandleErrType errType)(Empty);
    function Bool isIllegalAtomicWorkReq(WorkReq wr);
        let isAtomicWR = isAtomicWorkReq(wr.opcode);
        let isAlignedAddr = isAlignedAtomicAddr(wr.raddr);
        return isAtomicWR && !isAlignedAddr;
    endfunction

    let minPayloadLen = 1;
    let maxPayloadLen = 31;
    let minReadWorkReqLen = 1024;
    let maxReadWorkReqLen = 2048;
    let qpType = IBV_QPT_XRC_SEND;
    let pmtu = IBV_MTU_256;

    let cntrl <- mkSimCntrl(qpType, pmtu);
    let cntrlStatus = cntrl.contextRQ.statusRQ;
    // let qpMetaData <- mkSimMetaData4SinigleQP(qpType, pmtu);
    // let qpIndex = getDefaultIndexQP;
    // let cntrl = qpMetaData.getCntrlByIndexQP(qpIndex);

    // WorkReq generation
    Vector#(1, PipeOut#(Bool)) selectPipeOutVec <- mkGenericRandomPipeOutVec;
    let selectPipeOut4WorkReqGen = selectPipeOutVec[0];
    Vector#(1, PipeOut#(WorkReq)) normalWorkReqPipeOutVec <- mkRandomWorkReq(
        minPayloadLen, maxPayloadLen
    );
    Vector#(1, PipeOut#(WorkReq)) readAtomicWorkReqPipeOutVec <- mkRandomReadOrAtomicWorkReq(
        minReadWorkReqLen, maxReadWorkReqLen
    );
    let readAtomicWorkReqPipeOut = readAtomicWorkReqPipeOutVec[0];
    let illegalAtomicWorkReqPipeOut <- mkGenIllegalAtomicWorkReq;
    let workReqPipeOut = case (errType)
        REQ_HANDLE_PERM_CHECK_FAIL: normalWorkReqPipeOutVec[0];
        REQ_HANDLE_DMA_READ_ERR   : readAtomicWorkReqPipeOut;
        default                   : muxPipeOutFunc(
            selectPipeOut4WorkReqGen,
            normalWorkReqPipeOutVec[0],
            illegalAtomicWorkReqPipeOut
        );
    endcase;
    // Pending WR generation
    Vector#(2, PipeOut#(PendingWorkReq)) existingPendingWorkReqPipeOutVec <-
        mkExistingPendingWorkReqPipeOut(cntrl, workReqPipeOut);
    let pendingWorkReqPipeOut4Req = existingPendingWorkReqPipeOutVec[0];
    let pendingWorkReqPipeOut4Resp <- mkBufferN(32, existingPendingWorkReqPipeOutVec[1]);

    // Read response payload DataStream generation
    let hasDmaReadRespErr = errType == REQ_HANDLE_DMA_READ_ERR;
    let minErrLen = 512;
    let maxErrLen = 1024;
    let simDmaReadSrv <- mkSimDmaReadSrvWithErr(hasDmaReadRespErr, minErrLen, maxErrLen);

    // Generate RDMA requests
    let simReqGen <- mkSimGenRdmaReq(
        pendingWorkReqPipeOut4Req, qpType, pmtu
    );
    let rdmaReqPipeOut = simReqGen.rdmaReqDataStreamPipeOut;
    // Add rule to check no pending WR output
    let addNoPendingWorkReqOutRule <- addRules(genEmptyPipeOutRule(
        simReqGen.pendingWorkReqPipeOut,
        "simReqGen.pendingWorkReqPipeOut empty assertion @ mkTestReqHandleAbnormalCase"
    ));

    // Build RdmaPktMetaData and payload DataStream
    let pktMetaDataAndPayloadPipeOut <- mkSimExtractNormalHeaderPayload(
        rdmaReqPipeOut
    );
    // let isRespPktPipeIn = False;
    // let pktMetaDataAndPayloadPipeOut <- mkSimInputPktBuf4SingleQP(
    //     isRespPktPipeIn, rdmaReqPipeOut, qpMetaData
    // );
    let pktMetaDataPipeIn = pktMetaDataAndPayloadPipeOut.pktMetaData;

    // MR permission check
    let mrCheckPassOrFail = !(errType == REQ_HANDLE_PERM_CHECK_FAIL);
    let permCheckSrv <- mkSimPermCheckSrv(mrCheckPassOrFail);

    // DupReadAtomicCache
    let dupReadAtomicCache <- mkDupReadAtomicCache(cntrlStatus.comm.getPMTU);

    // RecvReq
    Vector#(2, PipeOut#(RecvReq)) recvReqBufVec <- mkSimGenRecvReq;
    let recvReqBuf = recvReqBufVec[0];
    let recvReqBuf4Ref <- mkBufferN(32, recvReqBufVec[1]);

    // PayloadGenerator
    let dmaReadCntrl <- mkDmaReadCntrl(cntrlStatus, simDmaReadSrv);
    let payloadGenerator <- mkPayloadGenerator(
        cntrlStatus, dmaReadCntrl
    );

    // PayloadConsumer
    let simDmaWriteSrv <- mkSimDmaWriteSrv;
    let dmaWriteCntrl <- mkDmaWriteCntrl(cntrlStatus, simDmaWriteSrv);
    let payloadConsumer <- mkPayloadConsumer(
        cntrlStatus,
        dmaWriteCntrl,
        pktMetaDataAndPayloadPipeOut.payload
        // dut.payloadConReqPipeOut
    );

    // DUT
    let dut <- mkReqHandleRQ(
        cntrl.contextRQ,
        payloadGenerator,
        permCheckSrv,
        dupReadAtomicCache,
        recvReqBuf,
        pktMetaDataPipeIn,
        payloadConsumer.request
    );

    // WorkCompGenRQ
    let workCompGenRQ <- mkWorkCompGenRQ(
        cntrlStatus,
        payloadConsumer.response,
        // payloadConsumer.respPipeOut,
        dut.workCompGenReqPipeOut
    );
    let workCompPipeOut4WorkReq = workCompGenRQ.workCompPipeOut;

    Reg#(Bool) firstErrRdmaRespGenReg <- mkReg(False);
    Reg#(Bool) firstErrWorkCompGenReg <- mkReg(False);

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    // mkSink(pendingWorkReqPipeOut4Resp);
    // mkSink(selectPipeOut4Resp);
    // mkSink(dut.rdmaRespDataStreamPipeOut);
    // mkSink(pendingWorkReqPipeOut4WorkComp);
    // mkSink(selectPipeOut4WorkComp);
    // mkSink(workCompPipeOut4WorkReq);

    // TODO: check workCompGenRQ.wcStatusQ4SQ has exact one error WC status

    rule checkNoMoreRespAfterFatalErr if (firstErrRdmaRespGenReg);
        immAssert(
            !dut.rdmaRespDataStreamPipeOut.notEmpty,
            "dut.rdmaRespDataStreamPipeOut.notEmpty assertion @ mkTestReqHandleAbnormalCase",
            $format(
                "dut.rdmaRespDataStreamPipeOut.notEmpty=",
                fshow(dut.rdmaRespDataStreamPipeOut.notEmpty),
                " should be false, when firstErrRdmaRespGenReg=",
                fshow(firstErrRdmaRespGenReg)
            )
        );
    endrule

    rule checkWorkCompGenHasErr if (firstErrWorkCompGenReg);
        immAssert(
            workCompGenRQ.hasErr,
            "workCompGenRQ.hasErr assertion @ mkTestReqHandleAbnormalCase",
            $format(
                "workCompGenRQ.hasErr=",
                fshow(workCompGenRQ.hasErr),
                " should be true, when firstErrWorkCompGenReg=",
                fshow(firstErrWorkCompGenReg)
            )
        );
    endrule

    rule flushPendingWorkReqAfterFatalErr if (firstErrRdmaRespGenReg);
        pendingWorkReqPipeOut4Resp.deq;
        // $display(
        //     "time=%0t:", $time,
        //     " flush pendingWR after fatal error response"
        // );

        countDown.decr;
    endrule

    rule compareRespBeforeFatalErr if (!firstErrRdmaRespGenReg);
        let pendingWR = pendingWorkReqPipeOut4Resp.first;

        // if (firstErrRdmaRespGenReg) begin
        //     pendingWorkReqPipeOut4Resp.deq;

        //     immAssert(
        //         !dut.rdmaRespDataStreamPipeOut.notEmpty,
        //         "dut.rdmaRespDataStreamPipeOut.notEmpty assertion @ mkTestReqHandleAbnormalCase",
        //         $format(
        //             "dut.rdmaRespDataStreamPipeOut.notEmpty=",
        //             fshow(dut.rdmaRespDataStreamPipeOut.notEmpty),
        //             " should be false, when firstErrRdmaRespGenReg=",
        //             fshow(firstErrRdmaRespGenReg)
        //         )
        //     );
        // end
        // else begin
        let rdmaRespDataStream = dut.rdmaRespDataStreamPipeOut.first;
        dut.rdmaRespDataStreamPipeOut.deq;

        if (rdmaRespDataStream.isFirst) begin
            let bth = extractBTH(zeroExtendLSB(rdmaRespDataStream.data));
            let endPSN = unwrapMaybe(pendingWR.endPSN);

            // Each WR set AckReq
            if (bth.psn == endPSN) begin
                pendingWorkReqPipeOut4Resp.deq;
            end

            if (rdmaRespHasAETH(bth.opcode)) begin
                let aeth = extractAETH(zeroExtendLSB(rdmaRespDataStream.data));
                if (aeth.code != AETH_CODE_ACK) begin
                    firstErrRdmaRespGenReg <= True;

                    immAssert(
                        rdmaRespDataStream.isLast,
                        "rdmaRespDataStream.isLast assertion @ mkTestReqHandleAbnormalCase",
                        $format(
                            "rdmaRespDataStream.isLast=", fshow(rdmaRespDataStream.isLast),
                            " should be true, when pendingWR.wr.opcode=", fshow(pendingWR.wr.opcode)
                        )
                    );

                    case (errType)
                        REQ_HANDLE_PERM_CHECK_FAIL: begin
                            immAssert(
                                aeth.code == AETH_CODE_NAK && aeth.value == zeroExtend(pack(AETH_NAK_RMT_ACC)),
                                "aeth.code assertion @ mkTestReqHandleAbnormalCase",
                                $format(
                                    "aeth.code=", fshow(aeth.code),
                                    " and aeth.value=", fshow(aeth.value),
                                    " should be AETH_NAK_RMT_ACC"
                                )
                            );
                        end
                        REQ_HANDLE_DMA_READ_ERR: begin
                            immAssert(
                                aeth.code == AETH_CODE_NAK && aeth.value == zeroExtend(pack(AETH_NAK_RMT_OP)),
                                "aeth.code assertion @ mkTestReqHandleAbnormalCase",
                                $format(
                                    "aeth.code=", fshow(aeth.code),
                                    " and aeth.value=", fshow(aeth.value),
                                    " should be AETH_NAK_RMT_OP"
                                )
                            );
                        end
                        default: begin
                            immAssert(
                                aeth.code == AETH_CODE_NAK && aeth.value == zeroExtend(pack(AETH_NAK_INV_RD)),
                                "aeth.code assertion @ mkTestReqHandleAbnormalCase",
                                $format(
                                    "aeth.code=", fshow(aeth.code),
                                    " and aeth.value=", fshow(aeth.value),
                                    " should be AETH_NAK_INV_RD"
                                )
                            );
                        end
                    endcase
                end
                // $display(
                //     "time=%0t: response bth=", $time, fshow(bth),
                //     ", aeth=", fshow(aeth)
                // );
            end
            // $display(
            //     "time=%0t: response bth=", $time, fshow(bth)
            // );
        end
    endrule

    rule compareWorkComp;
        let workComp = workCompPipeOut4WorkReq.first;
        workCompPipeOut4WorkReq.deq;

        let recvReq = recvReqBuf4Ref.first;
        recvReqBuf4Ref.deq;

        if (firstErrWorkCompGenReg) begin
            immAssert(
                workComp.status == IBV_WC_WR_FLUSH_ERR,
                "WC status assertion @ mkTestReqHandleAbnormalCase",
                $format(
                    "workComp.status=", fshow(workComp.status),
                    " should be IBV_WC_WR_FLUSH_ERR, when firstErrWorkCompGenReg=",
                    fshow(firstErrWorkCompGenReg)
                )
            );
        end
        else if (workComp.status != IBV_WC_SUCCESS) begin
            firstErrWorkCompGenReg <= True;
        end

        immAssert(
            workComp.id == recvReq.id,
            "WC ID assertion @ mkTestReqHandleAbnormalCase",
            $format(
                "workComp.id=%h should == recvReq.id=%h, when firstErrWorkCompGenReg=",
                workComp.id, recvReq.id, fshow(firstErrWorkCompGenReg)
            )
        );
        // $display("time=%0t: WC status=", $time, fshow(workComp.status));
    endrule
endmodule

typedef enum {
    TEST_REQ_HANDLE_RETRY_REQ_GEN,
    TEST_REQ_HANDLE_RETRY_RESP_CHECK,
    TEST_REQ_HANDLE_RETRY_RNR_WAIT,
    TEST_REQ_HANDLE_RETRY_REQ_AGAIN,
    TEST_REQ_HANDLE_RETRY_CLEAR,
    TEST_REQ_HANDLE_RETRY_DONE_CHECK
} TestReqHandleRetryState deriving(Bits, Eq, FShow);

(* doc = "testcase" *)
module mkTestReqHandleRnrCase(Empty);
    let rnrOrSeqErr = True;
    let result <- mkTestReqHandleRetryCase(rnrOrSeqErr);
endmodule

(* doc = "testcase" *)
module mkTestReqHandleSeqErrCase(Empty);
    let rnrOrSeqErr = False;
    let result <- mkTestReqHandleRetryCase(rnrOrSeqErr);
endmodule

module mkTestReqHandleRetryCase#(Bool rnrOrSeqErr)(Empty);
    // Retry case need multi-packet requests, at least two packets
    let minPayloadLen = 512;
    let maxPayloadLen = 1024;
    let qpType = IBV_QPT_XRC_SEND;
    let pmtu = IBV_MTU_256;

    let cntrl <- mkSimCntrl(qpType, pmtu);
    let cntrlStatus = cntrl.contextRQ.statusRQ;
    // let qpMetaData <- mkSimMetaData4SinigleQP(qpType, pmtu);
    // let qpIndex = getDefaultIndexQP;
    // let cntrl = qpMetaData.getCntrlByIndexQP(qpIndex);

    // WorkReq generation
    Vector#(1, PipeOut#(Bool)) selectPipeOutVec <- mkGenericRandomPipeOutVec;
    let selectPipeOut4WorkReqGen = selectPipeOutVec[0];
    Vector#(1, PipeOut#(WorkReq)) sendWorkReqPipeOutVec <- mkRandomSendWorkReq(
        minPayloadLen, maxPayloadLen
    );
    let workReqPipeOut = sendWorkReqPipeOutVec[0];

    // Pending WR generation
    Vector#(1, PipeOut#(PendingWorkReq)) existingPendingWorkReqPipeOutVec <-
        mkExistingPendingWorkReqPipeOut(cntrl, workReqPipeOut);
    let pendingWorkReqPipeOut = existingPendingWorkReqPipeOutVec[0];
    FIFOF#(PendingWorkReq)  origPendingWorkReqQ <- mkFIFOF;
    FIFOF#(PendingWorkReq) retryPendingWorkReqQ <- mkFIFOF;

    // Read response payload DataStream generation
    let simDmaReadSrv <- mkSimDmaReadSrv;

    // Generate RDMA requests
    let simReqGen <- mkSimGenRdmaReq(
        toPipeOut(origPendingWorkReqQ), qpType, pmtu
    );
    let rdmaReqPipeOut = simReqGen.rdmaReqDataStreamPipeOut;
    // Add rule to check no pending WR output
    let addNoPendingWorkReqOutRule <- addRules(genEmptyPipeOutRule(
        simReqGen.pendingWorkReqPipeOut,
        "simReqGen.pendingWorkReqPipeOut empty assertion @ mkTestReqHandleRetryCase"
    )
    );
    FIFOF#(DataStream) rdmaReqDataStreamQ <- mkFIFOF;

    // Build RdmaPktMetaData and payload DataStream
    let pktMetaDataAndPayloadPipeOut <- mkSimExtractNormalHeaderPayload(
        toPipeOut(rdmaReqDataStreamQ)
    );
    // let isRespPktPipeIn = False;
    // let pktMetaDataAndPayloadPipeOut <- mkSimInputPktBuf4SingleQP(
    //     isRespPktPipeIn, toPipeOut(rdmaReqDataStreamQ), qpMetaData
    // );
    let pktMetaDataPipeIn = pktMetaDataAndPayloadPipeOut.pktMetaData;

    // MR permission check
    let mrCheckPassOrFail = True;
    let permCheckSrv <- mkSimPermCheckSrv(mrCheckPassOrFail);

    // DupReadAtomicCache
    let dupReadAtomicCache <- mkDupReadAtomicCache(cntrlStatus.comm.getPMTU);

    // RecvReq
    Vector#(1, PipeOut#(RecvReq)) recvReqBufVec <- mkSimGenRecvReq;
    let recvReqPipeOut = recvReqBufVec[0];
    FIFOF#(RecvReq) recvReqQ4Retry <- mkFIFOF;
    FIFOF#(RecvReq)   recvReqQ4Cmp <- mkFIFOF;

    // PayloadGenerator
    let dmaReadCntrl <- mkDmaReadCntrl(cntrlStatus, simDmaReadSrv);
    let payloadGenerator <- mkPayloadGenerator(
        cntrlStatus, dmaReadCntrl
    );

    // PayloadConsumer
    let simDmaWriteSrv <- mkSimDmaWriteSrv;
    let dmaWriteCntrl <- mkDmaWriteCntrl(cntrlStatus, simDmaWriteSrv);
    let payloadConsumer <- mkPayloadConsumer(
        cntrlStatus,
        dmaWriteCntrl,
        pktMetaDataAndPayloadPipeOut.payload
        // dut.payloadConReqPipeOut
    );

    // DUT
    let dut <- mkReqHandleRQ(
        cntrl.contextRQ,
        payloadGenerator,
        permCheckSrv,
        dupReadAtomicCache,
        toPipeOut(recvReqQ4Retry),
        pktMetaDataPipeIn,
        payloadConsumer.request
    );

    // WorkCompGenRQ
    let workCompGenRQ <- mkWorkCompGenRQ(
        cntrlStatus,
        payloadConsumer.response,
        // payloadConsumer.respPipeOut,
        dut.workCompGenReqPipeOut
    );
    let workCompPipeOut4RecvReq = workCompGenRQ.workCompPipeOut;

    Reg#(RnrWaitCycleCnt)      rnrTestWaitCntReg <- mkRegU;
    Reg#(Bool)             discardFirstReqPktReg <- mkReg(False);
    Reg#(TestReqHandleRetryState) retryTestState <- mkReg(TEST_REQ_HANDLE_RETRY_REQ_GEN);

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    // mkSink(pendingWorkReqPipeOut4Resp);
    // mkSink(selectPipeOut4Resp);
    // mkSink(dut.rdmaRespDataStreamPipeOut);
    // mkSink(pendingWorkReqPipeOut4WorkComp);
    // mkSink(selectPipeOut4WorkComp);
    // mkSink(workCompPipeOut4WorkReq);

    rule noErrWorkComp;
        // let hasWorkCompErrStatusRQ = workCompGenRQ.workCompStatusPipeOutRQ.notEmpty;
        // Check workCompGenRQ.wcStatusQ4SQ has no error WC status
        immAssert(
            !workCompGenRQ.hasErr,
            "workCompGenRQ.hasErr assertion @ mkTestReqHandleRetryCase",
            $format(
                "workCompGenRQ.hasErr=", fshow(workCompGenRQ.hasErr),
                " should be false"
            )
        );
    endrule

    rule genWorkReq if (retryTestState == TEST_REQ_HANDLE_RETRY_REQ_GEN);
        let pendingWR = pendingWorkReqPipeOut.first;
        pendingWorkReqPipeOut.deq;

        let startPSN = unwrapMaybe(pendingWR.startPSN);
        let endPSN   = unwrapMaybe(pendingWR.endPSN);
        immAssert(
            startPSN != endPSN,
            "Pending WR PSN assertion @ mkTestReqHandleRetryCase",
            $format(
                "startPSN=%h should != endPSN=%h",
                startPSN, endPSN
            )
        );

        origPendingWorkReqQ.enq(pendingWR);
        retryPendingWorkReqQ.enq(pendingWR);

        discardFirstReqPktReg <= !rnrOrSeqErr;
        retryTestState <= TEST_REQ_HANDLE_RETRY_RESP_CHECK;
        // $display("time=%0t: retryTestState=", $time, fshow(retryTestState));
    endrule

    rule filterReqPkt4SeqErr if (retryTestState != TEST_REQ_HANDLE_RETRY_REQ_GEN);
        let rdmaReqDataStream = rdmaReqPipeOut.first;
        rdmaReqPipeOut.deq;

        if (discardFirstReqPktReg) begin
            // Discard first request packet to generate SEQ ERR
            discardFirstReqPktReg <= !rdmaReqDataStream.isLast;
        end
        else begin
            rdmaReqDataStreamQ.enq(rdmaReqDataStream);
        end
    endrule

    rule checkRetryResp if (retryTestState == TEST_REQ_HANDLE_RETRY_RESP_CHECK);
        let pendingWR = retryPendingWorkReqQ.first;
        let startPSN = unwrapMaybe(pendingWR.startPSN);

        let rdmaRespDataStream = dut.rdmaRespDataStreamPipeOut.first;
        dut.rdmaRespDataStreamPipeOut.deq;

        let bth = extractBTH(zeroExtendLSB(rdmaRespDataStream.data));
        immAssert(
            bth.psn == startPSN,
            "bth.psn assertion @ mkTestReqHandleRetryCase",
            $format(
                "bth.psn=%h should == startPSN=%h",
                bth.psn, startPSN
            )
        );

        immAssert(
            rdmaRespDataStream.isFirst && rdmaRespDataStream.isLast,
            "rdmaRespDataStream assertion @ mkTestReqHandleRetryCase",
            $format(
                "rdmaRespDataStream.isFirst=", fshow(rdmaRespDataStream.isFirst),
                ", rdmaRespDataStream.isLast=", fshow(rdmaRespDataStream.isLast),
                " should both be true, when bth.opcode=", fshow(bth.opcode)
            )
        );

        let hasAETH = rdmaRespHasAETH(bth.opcode);
        immAssert(
            hasAETH,
            "hasAETH assertion @ mkTestReqHandleRetryCase",
            $format(
                "hasAETH=", fshow(hasAETH),
                " should be true, when retryTestState=", fshow(retryTestState),
                " and bth.opcode=", fshow(bth.opcode)
            )
        );

        let aeth = extractAETH(zeroExtendLSB(rdmaRespDataStream.data));
        if (rnrOrSeqErr) begin
            rnrTestWaitCntReg <= fromInteger(getRnrTimeOutValue(aeth.value));
            retryTestState    <= TEST_REQ_HANDLE_RETRY_RNR_WAIT;

            immAssert(
                aeth.code == AETH_CODE_RNR,
                "aeth.code assertion @ mkTestReqHandleRetryCase",
                $format(
                    "aeth.code=", fshow(aeth.code),
                    " should be AETH_CODE_RNR"
                )
            );
        end
        else begin
            retryTestState <= TEST_REQ_HANDLE_RETRY_REQ_AGAIN;

            immAssert(
                aeth.code == AETH_CODE_NAK && aeth.value == zeroExtend(pack(AETH_NAK_SEQ_ERR)),
                "aeth.code assertion @ mkTestReqHandleRetryCase",
                $format(
                    "aeth.code=", fshow(aeth.code),
                    " should be AETH_CODE_NAK",
                    ", and aeth.value=", fshow(aeth.value),
                    " should be AETH_NAK_SEQ_ERR"
                )
            );
        end

        // $display(
        //     "time=%0t:", $time,
        //     " retryTestState=", fshow(retryTestState),
        //     ", response bth=", fshow(bth),
        //     ", aeth=", fshow(aeth)
        // );
    endrule

    rule waitRnrTimer if (retryTestState == TEST_REQ_HANDLE_RETRY_RNR_WAIT);
        if (isZero(rnrTestWaitCntReg)) begin
            retryTestState <= TEST_REQ_HANDLE_RETRY_REQ_AGAIN;
        end
        else begin
            rnrTestWaitCntReg <= rnrTestWaitCntReg - 1;
        end
        // $display("time=%0t: retryTestState=", $time, fshow(retryTestState));
    endrule

    rule retryReq if (retryTestState == TEST_REQ_HANDLE_RETRY_REQ_AGAIN);
        let pendingWR = retryPendingWorkReqQ.first;
        origPendingWorkReqQ.enq(pendingWR);

        let recvReq = recvReqPipeOut.first;
        recvReqPipeOut.deq;
        recvReqQ4Retry.enq(recvReq);
        recvReqQ4Cmp.enq(recvReq);

        retryTestState <= TEST_REQ_HANDLE_RETRY_CLEAR;
        // $display("time=%0t: retryTestState=", $time, fshow(retryTestState));
    endrule

    rule retryClear if (retryTestState == TEST_REQ_HANDLE_RETRY_CLEAR);
        let pendingWR = retryPendingWorkReqQ.first;
        retryPendingWorkReqQ.deq;
        let endPSN = unwrapMaybe(pendingWR.endPSN);

        let rdmaRespDataStream = dut.rdmaRespDataStreamPipeOut.first;
        dut.rdmaRespDataStreamPipeOut.deq;

        let bth = extractBTH(zeroExtendLSB(rdmaRespDataStream.data));
        let hasAETH = rdmaRespHasAETH(bth.opcode);
        let aeth = extractAETH(zeroExtendLSB(rdmaRespDataStream.data));

        immAssert(
            bth.psn == endPSN,
            "bth.psn assertion @ mkTestReqHandleRetryCase",
            $format(
                "bth.psn=%h should == endPSN=%h",
                bth.psn, endPSN
            )
        );

        immAssert(
            rdmaRespDataStream.isFirst && rdmaRespDataStream.isLast,
            "rdmaRespDataStream assertion @ mkTestReqHandleRetryCase",
            $format(
                "rdmaRespDataStream.isFirst=", fshow(rdmaRespDataStream.isFirst),
                ", rdmaRespDataStream.isLast=", fshow(rdmaRespDataStream.isLast),
                " should both be true, when bth.opcode=", fshow(bth.opcode)
            )
        );

        immAssert(
            hasAETH,
            "hasAETH assertion @ mkTestReqHandleRetryCase",
            $format(
                "hasAETH=", fshow(hasAETH),
                " should be true, when retryTestState=", fshow(retryTestState),
                " and bth.opcode=", fshow(bth.opcode)
            )
        );

        immAssert(
            aeth.code == AETH_CODE_ACK,
            "aeth.code assertion @ mkTestReqHandleRetryCase",
            $format(
                "aeth.code=", fshow(aeth.code),
                " should be AETH_CODE_ACK"
            )
        );

        retryTestState <= TEST_REQ_HANDLE_RETRY_DONE_CHECK;

        countDown.decr;
        // $display(
        //     "time=%0t:", $time,
        //     " retryTestState=", fshow(retryTestState),
        //     ", response bth=", fshow(bth),
        //     ", aeth=", fshow(aeth)
        // );
    endrule

    rule cmpWorkComp if (retryTestState == TEST_REQ_HANDLE_RETRY_DONE_CHECK);
        let workComp = workCompPipeOut4RecvReq.first;
        workCompPipeOut4RecvReq.deq;

        let recvReq = recvReqQ4Cmp.first;
        recvReqQ4Cmp.deq;

        immAssert(
            workComp.id == recvReq.id,
            "WC ID assertion @ mkTestReqHandleRetryCase",
            $format(
                "workComp.id=%h should == recvReq.id=%h",
                workComp.id, recvReq.id
            )
        );

        retryTestState <= TEST_REQ_HANDLE_RETRY_REQ_GEN;
        // $display("time=%0t: retryTestState=", $time, fshow(retryTestState));
    endrule
endmodule
