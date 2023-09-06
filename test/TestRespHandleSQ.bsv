import ClientServer :: *;
import Connectable :: *;
import FIFOF :: *;
import GetPut :: *;
import PAClib :: *;
import Vector :: *;
import Cntrs :: *;

import Headers :: *;
import Controller :: *;
import DataTypes :: *;
import ExtractAndPrependPipeOut::*;
import InputPktHandle :: *;
import MetaData :: *;
import PayloadConAndGen :: *;
import PrimUtils :: *;
import RespHandleSQ :: *;
import RetryHandleSQ :: *;
import SpecialFIFOF :: *;
import Settings :: *;
import SimDma :: *;
import SimExtractRdmaHeaderPayload :: *;
import SimGenRdmaReqResp :: *;
import Utils :: *;
import Utils4Test :: *;
import WorkCompGen :: *;

typedef enum {
    TEST_RESP_HANDLE_NORMAL_RESP,
    TEST_RESP_HANDLE_DUP_RESP,
    TEST_RESP_HANDLE_GHOST_RESP,
    TEST_RESP_HANDLE_ERROR_RESP,
    TEST_RESP_HANDLE_RETRY_LIMIT_EXC,
    TEST_RESP_HANDLE_TIMEOUT_ERR,
    TEST_RESP_HANDLE_PERM_CHECK_FAIL
} TestRespHandleRespType deriving(Bits, Eq);

module mkSimGenNormalOrErrOrRetryRdmaResp#(
    TestRespHandleRespType respType,
    CntrlStatus cntrlStatus,
    DmaReadSrv dmaReadSrv,
    PipeOut#(PendingWorkReq) pendingWorkReqPipeIn
)(DataStreamPipeOut);
    function DataStreamPipeOut muxDataStreamPipeOut(
        PipeOut#(Bool) selectPipeIn,
        DataStreamPipeOut pipeIn1,
        DataStreamPipeOut pipeIn2
    );
        DataStreamPipeOut resultPipeOut = interface PipeOut;
            method DataStream first();
                return selectPipeIn.first ? pipeIn1.first : pipeIn2.first;
            endmethod

            method Action deq();
                let sel = selectPipeIn.first;
                if (sel) begin
                    if (pipeIn1.first.isLast) begin
                        selectPipeIn.deq;
                    end
                end
                else begin
                    if (pipeIn2.first.isLast) begin
                        selectPipeIn.deq;
                    end
                end

                if (sel) begin
                    pipeIn1.deq;
                end
                else begin
                    pipeIn2.deq;
                end
                // $display("time=%0t: sel=", $time, fshow(sel));
            endmethod

            method Bool notEmpty();
                return selectPipeIn.first ? pipeIn1.notEmpty : pipeIn2.notEmpty;
            endmethod
        endinterface;

        return resultPipeOut;
    endfunction

    Vector#(2, PipeOut#(Bool)) selectPipeOutVec <- mkGenericRandomPipeOutVec;
    case (respType)
        TEST_RESP_HANDLE_NORMAL_RESP    ,
        TEST_RESP_HANDLE_DUP_RESP       ,
        TEST_RESP_HANDLE_GHOST_RESP     ,
        TEST_RESP_HANDLE_PERM_CHECK_FAIL: begin
            let rdmaNormalRespPipeOut <- mkSimGenRdmaRespDataStream(
                cntrlStatus, dmaReadSrv, pendingWorkReqPipeIn
            );
            return rdmaNormalRespPipeOut;
        end
        default: begin
            let selectPipeOut4WorkReqSel  = selectPipeOutVec[0];
            let selectPipeOut4RdmaRespSel = selectPipeOutVec[1];

            let {
                pendingWorkReqPipeOut4NormalRespGen,
                pendingWorkReqPipeOut4ErrRespGen
            } = deMuxPipeOutFunc(
                selectPipeOut4WorkReqSel, pendingWorkReqPipeIn
            );

            let rdmaNormalRespPipeOut <- mkSimGenRdmaRespDataStream(
                cntrlStatus, dmaReadSrv, pendingWorkReqPipeOut4NormalRespGen
            );
            let genAckType = case (respType)
                TEST_RESP_HANDLE_ERROR_RESP     : GEN_RDMA_RESP_ACK_ERROR;
                TEST_RESP_HANDLE_RETRY_LIMIT_EXC: GEN_RDMA_RESP_ACK_RNR;
                TEST_RESP_HANDLE_PERM_CHECK_FAIL: GEN_RDMA_RESP_ACK_NORMAL;
                default                         : GEN_RDMA_RESP_ACK_ERROR;
            endcase;
            let rdmaAbnormalRespAckPipeOut <- mkGenNormalOrErrOrRetryRdmaRespAck(
                cntrlStatus, genAckType, pendingWorkReqPipeOut4ErrRespGen
            );
            // muxPipeOutFunc cannot used here since EOP handle needed
            let rdmaRespDataStreamPipeOut = muxDataStreamPipeOut(
                selectPipeOut4RdmaRespSel,
                rdmaNormalRespPipeOut,
                rdmaAbnormalRespAckPipeOut
            );

            return rdmaRespDataStreamPipeOut;
        end
    endcase
endmodule

(* doc = "testcase" *)
module mkTestRespHandleNormalRespCase(Empty);
    let respType = TEST_RESP_HANDLE_NORMAL_RESP;
    let result <- mkTestRespHandleNormalOrDupOrGhostRespCase(respType);
endmodule

(* doc = "testcase" *)
module mkTestRespHandleDupRespCase(Empty);
    let respType = TEST_RESP_HANDLE_DUP_RESP;
    let result <- mkTestRespHandleNormalOrDupOrGhostRespCase(respType);
endmodule

(* doc = "testcase" *)
module mkTestRespHandleGhostRespCase(Empty);
    let respType = TEST_RESP_HANDLE_GHOST_RESP;
    let result <- mkTestRespHandleNormalOrDupOrGhostRespCase(respType);
endmodule

module mkTestRespHandleNormalOrDupOrGhostRespCase#(
    TestRespHandleRespType respType
)(Empty);
    let minDmaLength = 1;
    let maxDmaLength = 2048;
    let qpType = IBV_QPT_XRC_SEND;
    let pmtu = IBV_MTU_256;

    let cntrl <- mkSimCntrl(qpType, pmtu);
    let cntrlStatus = cntrl.contextSQ.statusSQ;
    // let qpMetaData <- mkSimMetaData4SinigleQP(qpType, pmtu);
    // let qpIndex = getDefaultIndexQP;
    // let cntrl = qpMetaData.getCntrlByIndexQP(qpIndex);

    // WorkReq generation
    PendingWorkReqBuf pendingWorkReqBuf <- mkScanFIFOF;
    Vector#(1, PipeOut#(WorkReq)) workReqPipeOutVec <-
        mkRandomWorkReq(minDmaLength, maxDmaLength);
    Vector#(3, PipeOut#(PendingWorkReq)) existingPendingWorkReqPipeOutVec <-
        mkExistingPendingWorkReqPipeOut(cntrl, workReqPipeOutVec[0]);
    let pendingWorkReqPipeOut4PendingQ = existingPendingWorkReqPipeOutVec[0];
    let pendingWorkReqPipeOut4WorkComp <- mkBufferN(8, existingPendingWorkReqPipeOutVec[1]);
    if (respType == TEST_RESP_HANDLE_GHOST_RESP) begin
        let sinkPendingWorkReq4PendingQ <- mkSink(pendingWorkReqPipeOut4PendingQ);
    end
    else begin
        // Only put normal WR in pending WR buffer
        let pendingWorkReq2Q <- mkConnection(
            toGet(pendingWorkReqPipeOut4PendingQ), toPut(pendingWorkReqBuf.fifof)
        );
    end
    // Generate normal WR when TEST_RESP_HANDLE_NORMAL_RESP and TEST_RESP_HANDLE_GHOST_RESP
    let normalOrDupReq = respType == TEST_RESP_HANDLE_DUP_RESP ? False : True;
    let { normalOrDupReqSelPipeOut, normalOrDupPendingWorkReqPipeOut } <- mkGenNormalOrDupWorkReq(
        normalOrDupReq, existingPendingWorkReqPipeOutVec[2]
    );
    let normalOrDupReqSelPipeOut4ReadResp <- mkBufferN(8, normalOrDupReqSelPipeOut);
    Vector#(2, PipeOut#(PendingWorkReq)) normalOrDupPendingWorkReqPipeOutVec <-
        mkForkVector(normalOrDupPendingWorkReqPipeOut);
    let pendingWorkReqPipeOut4RespGen  = normalOrDupPendingWorkReqPipeOutVec[0];
    let pendingWorkReqPipeOut4ReadResp <- mkBufferN(8, normalOrDupPendingWorkReqPipeOutVec[1]);

    // Only select read response payload for normal WR
    let simDmaReadSrv <- mkSimDmaReadSrvAndDataStreamPipeOut;
    let readRespPayloadPipeOutBuf <- mkBufferN(32, simDmaReadSrv.dataStream);
    // let pmtuPipeOut <- mkConstantPipeOut(cntrlStatus.comm.getPMTU);
    // let readRespPayloadPipeOut4Ref <- mkSegmentDataStreamByPmtuAndAddPadCnt(
    //     readRespPayloadPipeOutBuf, pmtuPipeOut
    // );
    let readRespPayloadPipeOut4Ref <- mkDataStreamAddPadCnt(
        readRespPayloadPipeOutBuf
    );
    // Generate RDMA responses
    let rdmaRespDataStreamPipeOut <- mkSimGenNormalOrErrOrRetryRdmaResp(
        respType, cntrlStatus, simDmaReadSrv.dmaReadSrv, pendingWorkReqPipeOut4RespGen
    );
    // Build RdmaPktMetaData and payload DataStream
    let pktMetaDataAndPayloadPipeOut <- mkSimExtractNormalHeaderPayload(
        rdmaRespDataStreamPipeOut
    );
    // let isRespPktPipeIn = True;
    // let pktMetaDataAndPayloadPipeOut <- mkSimInputPktBuf4SingleQP(
    //     isRespPktPipeIn, rdmaRespDataStreamPipeOut, qpMetaData
    // );

    Vector#(2, PipeOut#(RdmaPktMetaData)) pktMetaDataPipeOutVec <-
        mkForkVector(pktMetaDataAndPayloadPipeOut.pktMetaData);
    let pktMetaDataPipeOut4RespHandle = pktMetaDataPipeOutVec[0];
    let pktMetaDataPipeOut4ReadResp <- mkBufferN(8, pktMetaDataPipeOutVec[1]);
    // Retry handler
    let retryHandler <- mkRetryHandleSQ(
        cntrlStatus, pendingWorkReqBuf.fifof.notEmpty, pendingWorkReqBuf.scanCntrl
    );

    // MR permission check
    let mrCheckPassOrFail = True;
    let permCheckSrv <- mkSimPermCheckSrv(mrCheckPassOrFail);

    // PayloadConsumer
    let simDmaWriteSrv <- mkSimDmaWriteSrvAndDataStreamPipeOut;
    let readAtomicRespPayloadPipeOut = simDmaWriteSrv.dataStream;
    let dmaWriteCntrl <- mkDmaWriteCntrl(cntrlStatus, simDmaWriteSrv.dmaWriteSrv);
    let payloadConsumer <- mkPayloadConsumer(
        cntrlStatus,
        dmaWriteCntrl,
        pktMetaDataAndPayloadPipeOut.payload
        // dut.payloadConReqPipeOut
    );

    // DUT
    let dut <- mkRespHandleSQ(
        cntrl.contextSQ,
        retryHandler,
        permCheckSrv,
        toPipeOut(pendingWorkReqBuf.fifof),
        pktMetaDataPipeOut4RespHandle,
        payloadConsumer.request
    );

    // WorkCompGenSQ
    FIFOF#(WorkCompGenReqSQ) wcGenReqQ4ReqGenInSQ <- mkFIFOF;
    // FIFOF#(WorkCompStatus) workCompStatusQFromRQ <- mkFIFOF;
    let workCompGenSQ <- mkWorkCompGenSQ(
        cntrlStatus,
        payloadConsumer.response,
        // payloadConsumer.respPipeOut,
        toPipeOut(wcGenReqQ4ReqGenInSQ),
        dut.workCompGenReqPipeOut
        // toPipeOut(workCompStatusQFromRQ)
    );
    let workCompPipeOut = workCompGenSQ.workCompPipeOut;

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    // PipeOut need to handle:
    // - pendingWorkReqPipeOut4WorkComp
    // - pendingWorkReqPipeOut4RespGen
    // - pendingWorkReqPipeOut4PendingQ
    // - toPipeOut(pendingWorkReqBuf.fifof)
    // - readRespPayloadPipeOut4Ref
    // - rdmaRespDataStreamPipeOut
    // - normalOrDupReqSelPipeOut4ReadResp
    // - headerAndMetaDataAndPayloadPipeOut.headerAndMetaData.headerDataStream
    // - headerAndMetaDataAndPayloadPipeOut.headerAndMetaData.headerMetaData
    // - headerAndMetaDataAndPayloadPipeOut.payload
    // - pktMetaDataPipeOut4RespHandle // pktMetaDataAndPayloadPipeOut.pktMetaData
    // - pktMetaDataPipeOut4ReadResp
    // - pendingWorkReqPipeOut4ReadResp
    // - pktMetaDataAndPayloadPipeOut.payload
    // - dut.payloadConReqPipeOut
    // - dut.workCompGenReqPipeOut
    // - readAtomicRespPayloadPipeOut
    // - payloadConsumer.respPipeOut
    // - workCompPipeOut

    // rule showPendingWorkReqCnt;
    //     let pendingWorkReqCnt = pendingWorkReqBuf.size;
    //     $display(
    //         "time=%0t:", $time,
    //         " pendingWorkReqCnt=%0d", pendingWorkReqCnt
    //     );
    // endrule

    // mkSink(pendingWorkReqPipeOut4WorkComp);
    // mkSink(workCompPipeOut);
    rule compareWorkReqAndWorkComp;
        let pendingWR = pendingWorkReqPipeOut4WorkComp.first;
        pendingWorkReqPipeOut4WorkComp.deq;

        if (
            respType != TEST_RESP_HANDLE_GHOST_RESP &&
            workReqNeedWorkCompSQ(pendingWR.wr)
        ) begin
            let workComp = workCompPipeOut.first;
            workCompPipeOut.deq;

            immAssert(
                workCompMatchWorkReqInSQ(workComp, pendingWR.wr),
                "workCompMatchWorkReqInSQ assertion @ mkTestRespHandleSQ",
                $format("WC=", fshow(workComp), " not match WR=", fshow(pendingWR.wr))
            );
            // $display(
            //     "time=%0t: WC=", $time, fshow(workComp), " match WR=", fshow(pendingWR.wr)
            // );
        end
        // $display(
        //     "time=%0t:", $time, ", pendingWR.wr.id=%h", pendingWR.wr.id
        // );
    endrule

    // mkSink(pktMetaDataPipeOut4ReadResp);
    // mkSink(pendingWorkReqPipeOut4ReadResp);
    // mkSink(normalOrDupReqSelPipeOut4ReadResp);
    // mkSink(readAtomicRespPayloadPipeOut);
    // mkSink(readRespPayloadPipeOut4Ref);
    rule compareReadRespPayloadDataStream;
        let pktMetaData = pktMetaDataPipeOut4ReadResp.first;
        let bth = extractBTH(pktMetaData.pktHeader.headerData);

        let pendingWR = pendingWorkReqPipeOut4ReadResp.first;
        let endPSN = unwrapMaybe(pendingWR.endPSN);
        let isNormalWorkReq =
            normalOrDupReqSelPipeOut4ReadResp.first &&
            respType != TEST_RESP_HANDLE_GHOST_RESP;

        let isRespPktEnd = False;
        if (workReqNeedDmaWriteSQ(pendingWR.wr)) begin
            if (isReadRespRdmaOpCode(bth.opcode)) begin // Read responses with non-zero payload
                let refDataStream = readRespPayloadPipeOut4Ref.first;
                readRespPayloadPipeOut4Ref.deq;

                if (isNormalWorkReq) begin
                    let payloadDataStream = readAtomicRespPayloadPipeOut.first;
                    readAtomicRespPayloadPipeOut.deq;

                    immAssert(
                        payloadDataStream == refDataStream,
                        "payloadDataStream assertion @ mkTestRespHandleNormalCase",
                        $format(
                            "payloadDataStream=", fshow(payloadDataStream),
                            " should == refDataStream=", fshow(refDataStream)
                        )
                    );
                end

                if (refDataStream.isLast) begin
                    isRespPktEnd = True;
                end
            end
            else begin // Atomic responses
                isRespPktEnd = True;

                if (isNormalWorkReq) begin
                    // One fragment DMA write when handle atomic responses
                    readAtomicRespPayloadPipeOut.deq;
                end
            end
        end
        else begin
            // No DMA read or write when handle send/write/zero-length read responses
            isRespPktEnd = True;
        end

        if (isRespPktEnd) begin
            pktMetaDataPipeOut4ReadResp.deq;
            if (bth.psn == endPSN) begin
                pendingWorkReqPipeOut4ReadResp.deq;
                normalOrDupReqSelPipeOut4ReadResp.deq;
            end
        end

        countDown.decr;
        // $display("time=%0t: respHeader=", $time, fshow(respHeader));
    endrule
endmodule

(* doc = "testcase" *)
module mkTestRespHandleRespErrCase(Empty);
    let respType = TEST_RESP_HANDLE_ERROR_RESP;
    let result <- mkTestRespHandleAbnormalCase(respType);
endmodule

(* doc = "testcase" *)
module mkTestRespHandleRetryErrCase(Empty);
    let respType = TEST_RESP_HANDLE_RETRY_LIMIT_EXC;
    let result <- mkTestRespHandleAbnormalCase(respType);
endmodule

(* doc = "testcase" *)
module mkTestRespHandleTimeOutErrCase(Empty);
    let respType = TEST_RESP_HANDLE_TIMEOUT_ERR;
    let result <- mkTestRespHandleAbnormalCase(respType);
endmodule

(* doc = "testcase" *)
module mkTestRespHandlePermCheckFailCase(Empty);
    let respType = TEST_RESP_HANDLE_PERM_CHECK_FAIL;
    let result <- mkTestRespHandleAbnormalCase(respType);
endmodule

module mkPipeConnector#(Bool passOrDiscard, PipeOut#(anytype) pipeIn)(
    PipeOut#(anytype)
) provisos(Bits#(anytype, tSz));
    function Bool filterFunc(anytype inputVal) = passOrDiscard;

    let resultPipeOut <- mkPipeFilter(filterFunc, pipeIn);
    return resultPipeOut;
    // FIFOF#(anytype) emptyQ <- mkFIFOF;
    // mkSink(passOrDiscard ? toPipeOut(emptyQ) : pipeIn);
    // return passOrDiscard ? pipeIn : toPipeOut(emptyQ);
endmodule

module mkTestRespHandleAbnormalCase#(TestRespHandleRespType respType)(Empty);
    let minDmaLength = 1;
    let maxDmaLength = 31;
    let qpType = IBV_QPT_XRC_SEND;
    let pmtu = IBV_MTU_256;

    let cntrl <- mkSimCntrl(qpType, pmtu);
    let cntrlStatus = cntrl.contextSQ.statusSQ;
    // let qpMetaData <- mkSimMetaData4SinigleQP(qpType, pmtu);
    // let qpIndex = getDefaultIndexQP;
    // let cntrl = qpMetaData.getCntrlByIndexQP(qpIndex);

    // WorkReq generation
    PendingWorkReqBuf pendingWorkReqBuf <- mkScanFIFOF;
    Vector#(1, PipeOut#(WorkReq)) workReqPipeOutVec <-
        mkRandomWorkReq(minDmaLength, maxDmaLength);
    let workReqPipeOut = workReqPipeOutVec[0];
    Vector#(3, PipeOut#(PendingWorkReq)) existingPendingWorkReqPipeOutVec <-
        mkExistingPendingWorkReqPipeOut(cntrl, workReqPipeOut);
    let pendingWorkReqPipeOut4RespGen = existingPendingWorkReqPipeOutVec[0];
    let pendingWorkReqPipeOut4WorkComp <- mkBufferN(32, existingPendingWorkReqPipeOutVec[1]);
    let pendingWorkReqPipeOut4PendingQ = existingPendingWorkReqPipeOutVec[2];
    let pendingWorkReq2Q <- mkConnection(
        toGet(pendingWorkReqPipeOut4PendingQ), toPut(pendingWorkReqBuf.fifof)
    );
    // Payload DataStream generation
    let simDmaReadSrv <- mkSimDmaReadSrv;
    // Generate RDMA responses
    let rdmaRespDataStreamPipeOut <- mkSimGenNormalOrErrOrRetryRdmaResp(
        respType, cntrlStatus, simDmaReadSrv, pendingWorkReqPipeOut4RespGen
    );

    // Build RdmaPktMetaData and payload DataStream
    let pktMetaDataAndPayloadPipeOut <- mkSimExtractNormalHeaderPayload(
        rdmaRespDataStreamPipeOut
    );
    // let isRespPktPipeIn = True;
    // let pktMetaDataAndPayloadPipeOut <- mkSimInputPktBuf4SingleQP(
    //     isRespPktPipeIn, rdmaRespDataStreamPipeOut, qpMetaData
    // );

    // Discard responses if timeout case
    let passOrDiscard = respType != TEST_RESP_HANDLE_TIMEOUT_ERR;
    let pktMetaDataOrEmptyPipeOut <- mkPipeConnector(
        passOrDiscard, pktMetaDataAndPayloadPipeOut.pktMetaData
    );
    let payloadOrEmptyPipeOut <- mkPipeConnector(
        passOrDiscard, pktMetaDataAndPayloadPipeOut.payload
    );
    // Retry handler
    let retryLimitExcOrTimeOutErr = respType != TEST_RESP_HANDLE_TIMEOUT_ERR;
    let retryHandler <- mkSimRetryHandleErr(retryLimitExcOrTimeOutErr);

    // MR permission check
    let mrCheckPassOrFail = !(respType == TEST_RESP_HANDLE_PERM_CHECK_FAIL);
    let permCheckSrv <- mkSimPermCheckSrv(mrCheckPassOrFail);

    // PayloadConsumer
    let simDmaWriteSrv <- mkSimDmaWriteSrv;
    let dmaWriteCntrl <- mkDmaWriteCntrl(cntrlStatus, simDmaWriteSrv);
    let payloadConsumer <- mkPayloadConsumer(
        cntrlStatus,
        dmaWriteCntrl,
        payloadOrEmptyPipeOut
        // dut.payloadConReqPipeOut
    );

    // DUT
    let dut <- mkRespHandleSQ(
        cntrl.contextSQ,
        retryHandler,
        permCheckSrv,
        toPipeOut(pendingWorkReqBuf.fifof),
        pktMetaDataOrEmptyPipeOut,
        payloadConsumer.request
    );

    // WorkCompGenSQ
    FIFOF#(WorkCompGenReqSQ) wcGenReqQ4ReqGenInSQ <- mkFIFOF;
    // FIFOF#(WorkCompStatus) workCompStatusQFromRQ <- mkFIFOF;
    // This controller will be set to error state,
    // since it cannot generate WR when error state,
    // so use a dedicated controller for WC.
    // let cntrl4WorkComp <- mkSimCntrl(qpType, pmtu);
    // let setExpectedPsnAsNextPSN = False;
    // let cntrl4WorkComp <- mkSimCntrlQP(qpType, pmtu, setExpectedPsnAsNextPSN);
    let workCompGenSQ <- mkWorkCompGenSQ(
        cntrlStatus,
        payloadConsumer.response,
        // payloadConsumer.respPipeOut,
        toPipeOut(wcGenReqQ4ReqGenInSQ),
        dut.workCompGenReqPipeOut
        // toPipeOut(workCompStatusQFromRQ)
    );
    let workCompPipeOut = workCompGenSQ.workCompPipeOut;

    Reg#(Bool) firstErrWorkCompGenReg <- mkReg(False);

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    // mkSink(pendingWorkReqPipeOut4PendingQ);
    // mkSink(toPipeOut(pendingWorkReqBuf.fifof));
    // mkSink(rdmaRespDataStreamPipeOut);
    // mkSink(pktMetaDataOrEmptyPipeOut);
    // mkSink(payloadOrEmptyPipeOut);
    // mkSink(dut.payloadConReqPipeOut);
    // mkSink(dut.workCompGenReqPipeOut);
    // mkSink(payloadConsumer.respPipeOut);
    // mkSink(selectPipeOut4WorkComp);
    // mkSink(pendingWorkReqPipeOut4WorkComp);
    // mkSink(workCompPipeOut);

    rule compareWorkReqAndWorkComp;
        let pendingWR = pendingWorkReqPipeOut4WorkComp.first;
        pendingWorkReqPipeOut4WorkComp.deq;

        if (workReqNeedWorkCompSQ(pendingWR.wr)) begin
            let workComp = workCompPipeOut.first;
            workCompPipeOut.deq;

            if (workComp.status != IBV_WC_SUCCESS && !firstErrWorkCompGenReg) begin
                firstErrWorkCompGenReg <= True;

                let expectedWorkCompStatus = case (respType)
                    TEST_RESP_HANDLE_ERROR_RESP     : IBV_WC_REM_OP_ERR;
                    TEST_RESP_HANDLE_RETRY_LIMIT_EXC: IBV_WC_RETRY_EXC_ERR;
                    TEST_RESP_HANDLE_TIMEOUT_ERR   : IBV_WC_RESP_TIMEOUT_ERR;
                    TEST_RESP_HANDLE_PERM_CHECK_FAIL: IBV_WC_LOC_ACCESS_ERR;
                    default                         : IBV_WC_SUCCESS;
                endcase;

                immAssert(
                    workComp.status == expectedWorkCompStatus,
                    "workComp.status assertion @ mkTestRespHandleSQ",
                    $format(
                        "workComp.status=", fshow(workComp.status),
                        " should == expectedWorkCompStatus=", fshow(expectedWorkCompStatus)
                    )
                );
            end

            immAssert(
                workCompMatchWorkReqInSQ(workComp, pendingWR.wr),
                "workCompMatchWorkReqInSQ assertion @ mkTestRespHandleAbnormalCase",
                $format("WC=", fshow(workComp), " not match WR=", fshow(pendingWR.wr))
            );
            // $display(
            //     "time=%0t: WC=", $time, fshow(workComp), " not match WR=", fshow(pendingWR.wr)
            // );
        end

        countDown.decr;
    endrule
endmodule

(* doc = "testcase" *)
module mkTestRespHandleRnrCase(Empty);
    let rnrOrSeqErr = True;
    let nestedRetry = False;
    let result <- mkTestRespHandleRetryCase(rnrOrSeqErr, nestedRetry);
endmodule

(* doc = "testcase" *)
module mkTestRespHandleSeqErrCase(Empty);
    let rnrOrSeqErr = False;
    let nestedRetry = False;
    let result <- mkTestRespHandleRetryCase(rnrOrSeqErr, nestedRetry);
endmodule

(* doc = "testcase" *)
module mkTestRespHandleNestedRetryCase(Empty);
    let rnrOrSeqErr = False;
    let nestedRetry = True;
    let result <- mkTestRespHandleRetryCase(rnrOrSeqErr, nestedRetry);
endmodule

typedef enum {
    TEST_RESP_HANDLE_RETRY_RESP_GEN,
    TEST_RESP_HANDLE_FOLLOWING_RESP_GEN,
    TEST_RESP_HANDLE_FOLLOWING_WR_GEN,
    TEST_RESP_HANDLE_RETRY_RESP_GEN_AGAIN,
    TEST_RESP_HANDLE_WAIT_RETRY_RESTART,
    TEST_RESP_HANDLE_NORMAL_RESP_GEN,
    TEST_RESP_HANDLE_FOLLOWING_NORMAL_RESP_GEN
} TestRespHandleRetryState deriving(Bits, Eq);

typedef 3 FollowingAckNum;

module mkTestRespHandleRetryCase#(Bool rnrOrSeqErr, Bool nestedRetry)(Empty);
    // Retry case need multi-packet requests, at least two packets
    let minDmaLength = 512;
    let maxDmaLength = 1024;
    let qpType = IBV_QPT_RC;
    let pmtu = IBV_MTU_256;

    let cntrl <- mkSimCntrl(qpType, pmtu);
    let cntrlStatus = cntrl.contextSQ.statusSQ;
    // let qpMetaData <- mkSimMetaData4SinigleQP(qpType, pmtu);
    // let qpIndex = getDefaultIndexQP;
    // let cntrl = qpMetaData.getCntrlByIndexQP(qpIndex);

    // WorkReq generation
    PendingWorkReqBuf pendingWorkReqBuf <- mkScanFIFOF;
    let retryWorkReqPipeOut = pendingWorkReqBuf.scanPipeOut;

    Vector#(1, PipeOut#(WorkReq)) sendWorkReqPipeOutVec <- mkRandomSendWorkReq(
        minDmaLength, maxDmaLength
    );
    let workReqPipeOut = sendWorkReqPipeOutVec[0];

    Vector#(2, PipeOut#(PendingWorkReq)) existingPendingWorkReqPipeOutVec <-
        mkExistingPendingWorkReqPipeOut(cntrl, workReqPipeOut);
    let pendingWorkReqPipeOut4RespGen = existingPendingWorkReqPipeOutVec[0];
    let pendingWorkReqPipeOut4WorkComp <- mkBufferN(32, existingPendingWorkReqPipeOutVec[1]);

    // Generate RDMA responses
    FIFOF#(PendingWorkReq) pendingWorkReqQ4NormalResp <- mkFIFOF;
    let normalAckType = GEN_RDMA_RESP_ACK_NORMAL;
    let rdmaRespNormalAckPipeOut <- mkGenNormalOrErrOrRetryRdmaRespAck(
        cntrlStatus, normalAckType, toPipeOut(pendingWorkReqQ4NormalResp)
    );
    FIFOF#(PendingWorkReq) pendingWorkReqQ4RetryResp <- mkFIFOF;
    let retryAckType = rnrOrSeqErr ? GEN_RDMA_RESP_ACK_RNR : GEN_RDMA_RESP_ACK_SEQ_ERR;
    let rdmaRespRetryAckPipeOut <- mkGenNormalOrErrOrRetryRdmaRespAck(
        cntrlStatus, retryAckType, toPipeOut(pendingWorkReqQ4RetryResp)
    );

    // Response ACK generation pattern:
    // - False to generate retry ACK
    // - True to generate normal ACK
    FIFOF#(Bool) retryRespAckPatternQ <- mkFIFOF;
    let rdmaRespDataStreamPipeOut = muxPipeOutFunc(
        toPipeOut(retryRespAckPatternQ),
        rdmaRespNormalAckPipeOut,
        rdmaRespRetryAckPipeOut
    );

    // Build RdmaPktMetaData and payload DataStream
    let pktMetaDataAndPayloadPipeOut <- mkSimExtractNormalHeaderPayload(
        rdmaRespDataStreamPipeOut
    );
    // let isRespPktPipeIn = True;
    // let pktMetaDataAndPayloadPipeOut <- mkSimInputPktBuf4SingleQP(
    //     isRespPktPipeIn, rdmaRespDataStreamPipeOut, qpMetaData
    // );
    // Retry handler
    let retryHandler <- mkRetryHandleSQ(
        cntrlStatus, pendingWorkReqBuf.fifof.notEmpty, pendingWorkReqBuf.scanCntrl
    );

    // MR permission check
    let mrCheckPassOrFail = True;
    let permCheckSrv <- mkSimPermCheckSrv(mrCheckPassOrFail);

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
    let dut <- mkRespHandleSQ(
        cntrl.contextSQ,
        retryHandler,
        permCheckSrv,
        toPipeOut(pendingWorkReqBuf.fifof),
        pktMetaDataAndPayloadPipeOut.pktMetaData,
        payloadConsumer.request
    );

    // WorkCompGenSQ
    FIFOF#(WorkCompGenReqSQ) wcGenReqQ4ReqGenInSQ <- mkFIFOF;
    // FIFOF#(WorkCompStatus) workCompStatusQFromRQ <- mkFIFOF;
    let workCompGenSQ <- mkWorkCompGenSQ(
        cntrlStatus,
        payloadConsumer.response,
        // payloadConsumer.respPipeOut,
        toPipeOut(wcGenReqQ4ReqGenInSQ),
        dut.workCompGenReqPipeOut
        // toPipeOut(workCompStatusQFromRQ)
    );
    let workCompPipeOut = workCompGenSQ.workCompPipeOut;

    Count#(Bit#(TLog#(FollowingAckNum))) followingAckCnt <- mkCount(0);
    FIFOF#(PendingWorkReq) pendingWorkReqQ4Retry <- mkSizedFIFOF(valueOf(FollowingAckNum));
    Reg#(WorkReqID) retryWorkReqIdReg <- mkRegU;

    Reg#(TestRespHandleRetryState) retryTestState <- mkReg(TEST_RESP_HANDLE_RETRY_RESP_GEN);

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    // mkSink(pendingWorkReqPipeOut4PendingQ);
    // mkSink(toPipeOut(pendingWorkReqBuf.fifof));
    // mkSink(rdmaRespDataStreamPipeOut);
    // mkSink(pktMetaDataAndPayloadPipeOut.pktMetaData);
    // mkSink(pktMetaDataAndPayloadPipeOut.payload);
    // mkSink(dut.payloadConReqPipeOut);
    // mkSink(dut.workCompGenReqPipeOut);
    // mkSink(payloadConsumer.respPipeOut);
    // mkSink(selectPipeOut4WorkComp);
    // mkSink(pendingWorkReqPipeOut4WorkComp);
    // mkSink(workCompPipeOut);

    function Action genRetryResp4WR(PendingWorkReq pendingWR);
        action
            pendingWorkReqQ4RetryResp.enq(pendingWR);
            let isNormalResp = False;
            retryRespAckPatternQ.enq(isNormalResp);
        endaction
    endfunction

    function Action genNormalResp4WR(PendingWorkReq pendingWR);
        action
            pendingWorkReqQ4NormalResp.enq(pendingWR);
            let isNormalResp = True;
            retryRespAckPatternQ.enq(isNormalResp);
        endaction
    endfunction

    rule genRetryResp if (retryTestState == TEST_RESP_HANDLE_RETRY_RESP_GEN);
        let pendingWR = pendingWorkReqPipeOut4RespGen.first;
        pendingWorkReqPipeOut4RespGen.deq;

        retryWorkReqIdReg <= pendingWR.wr.id;
        genRetryResp4WR(pendingWR);
        pendingWorkReqBuf.fifof.enq(pendingWR);

        retryTestState  <= TEST_RESP_HANDLE_FOLLOWING_RESP_GEN;
        // $display(
        //     "time=%0t:", $time, " retry response for WR=", fshow(pendingWR)
        // );
    endrule

    rule genFollowingResp4Flush if (
        retryTestState == TEST_RESP_HANDLE_FOLLOWING_RESP_GEN
    );
        let pendingWR = pendingWorkReqPipeOut4RespGen.first;
        pendingWorkReqPipeOut4RespGen.deq;

        genNormalResp4WR(pendingWR);
        pendingWorkReqBuf.fifof.enq(pendingWR);

        retryTestState  <= TEST_RESP_HANDLE_FOLLOWING_WR_GEN;
        // FollowingAckNum - 2 because previous stage generate a response
        // to be flushed
        followingAckCnt <= fromInteger(valueOf(FollowingAckNum) - 2);
        // $display(
        //     "time=%0t:", $time,
        //     " normal response to be flushed for following WR=", fshow(pendingWR)
        // );
    endrule

    rule genFollowingWR if (
        retryTestState == TEST_RESP_HANDLE_FOLLOWING_WR_GEN
    );
        let pendingWR = pendingWorkReqPipeOut4RespGen.first;
        pendingWorkReqPipeOut4RespGen.deq;

        pendingWorkReqBuf.fifof.enq(pendingWR);

        if (isZero(followingAckCnt)) begin
            retryTestState <= nestedRetry ?
                TEST_RESP_HANDLE_RETRY_RESP_GEN_AGAIN :
                TEST_RESP_HANDLE_NORMAL_RESP_GEN;
        end
        else begin
            followingAckCnt.decr(1);
        end
        // $display(
        //     "time=%0t:", $time,
        //     " other following WR=", fshow(pendingWR)
        // );
    endrule

    rule genNestedRetryResp if (
        retryTestState == TEST_RESP_HANDLE_RETRY_RESP_GEN_AGAIN
    );
        let retryRestartWR = retryWorkReqPipeOut.first;
        retryWorkReqPipeOut.deq;

        let workReqID = retryRestartWR.wr.id;
        immAssert(
            retryWorkReqIdReg == workReqID,
            "retryWorkReqIdReg assertion @ mkTestRespHandleRetryCase",
            $format(
                "retryWorkReqIdReg=%h should == workReqID=%h",
                retryWorkReqIdReg, workReqID
            )
        );

        genRetryResp4WR(retryRestartWR);

        retryTestState <= TEST_RESP_HANDLE_WAIT_RETRY_RESTART;
        // $display(
        //     "time=%0t:", $time,
        //     " retry response again for WR=%h", retryRestartWR.wr.id
        // );
    endrule

    rule waitRetryRestart if (retryTestState == TEST_RESP_HANDLE_WAIT_RETRY_RESTART);
        let retryPendingWR = retryWorkReqPipeOut.first;
        let workReqID = retryPendingWR.wr.id;

        if (workReqID == retryWorkReqIdReg) begin
            // $display(
            //     "time=%0t:", $time,
            //     " retry restart for WR=%h", retryWorkReqIdReg
            // );
            retryTestState <= TEST_RESP_HANDLE_NORMAL_RESP_GEN;
        end
        else begin
            // $display(
            //     "time=%0t:", $time,
            //     " wait retry restart for wr.id=%h", retryWorkReqIdReg,
            //     ", but current wr.id=%h", workReqID
            // );
        end
    endrule

    rule genNormalResp if (retryTestState == TEST_RESP_HANDLE_NORMAL_RESP_GEN);
        let retryPendingWR = retryWorkReqPipeOut.first;
        retryWorkReqPipeOut.deq;

        let workReqID = retryPendingWR.wr.id;
        immAssert(
            retryWorkReqIdReg == workReqID,
            "retryWorkReqIdReg assertion @ mkTestRespHandleRetryCase",
            $format(
                "retryWorkReqIdReg=%h should == workReqID=%h",
                retryWorkReqIdReg, workReqID
            )
        );

        genNormalResp4WR(retryPendingWR);

        retryTestState  <= TEST_RESP_HANDLE_FOLLOWING_NORMAL_RESP_GEN;
        followingAckCnt <= fromInteger(valueOf(FollowingAckNum) - 1);
        // $display(
        //     "time=%0t:", $time, " normal response for WR=%h", retryPendingWR.wr.id
        // );
    endrule

    rule genFollowingNormaResp if (
        retryTestState == TEST_RESP_HANDLE_FOLLOWING_NORMAL_RESP_GEN
    );
        let followingPendingWR = retryWorkReqPipeOut.first;
        retryWorkReqPipeOut.deq;

        genNormalResp4WR(followingPendingWR);

        if (isZero(followingAckCnt)) begin
            retryTestState <= TEST_RESP_HANDLE_RETRY_RESP_GEN;
        end
        else begin
            followingAckCnt.decr(1);
        end
        // $display(
        //     "time=%0t:", $time,
        //     " normal response for following WR=%h", followingPendingWR.wr.id
        // );
    endrule

    rule compareWorkCompWithPendingWorkReq;
        let pendingWR = pendingWorkReqPipeOut4WorkComp.first;
        pendingWorkReqPipeOut4WorkComp.deq;

        if (workReqNeedWorkCompSQ(pendingWR.wr)) begin
            let workComp = workCompPipeOut.first;
            workCompPipeOut.deq;

            immAssert(
                workComp.status == IBV_WC_SUCCESS,
                "workComp.status assertion @ mkTestRespHandleRetryCase",
                $format(
                    "workComp.status=", fshow(workComp.status),
                    " should == IBV_WC_SUCCESS")
            );

            immAssert(
                workCompMatchWorkReqInSQ(workComp, pendingWR.wr),
                "workCompMatchWorkReqInSQ assertion @ mkTestRespHandleRetryCase",
                $format("WC=", fshow(workComp), " not match WR=", fshow(pendingWR.wr))
            );
            // $display(
            //     "time=%0t: WC=", $time, fshow(workComp), " v.s. WR=", fshow(pendingWR.wr)
            // );
        end
        countDown.decr;
    endrule
endmodule
