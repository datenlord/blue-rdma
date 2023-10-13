import BuildVector :: *;
import ClientServer :: *;
import Cntrs :: *;
import Connectable :: *;
import FIFOF :: *;
import GetPut :: *;
import PAClib :: *;
import Vector :: *;

import Controller :: *;
import DataTypes :: *;
import ExtractAndPrependPipeOut :: *;
import Headers :: *;
import PrimUtils :: *;
import QueuePair :: *;
import Settings :: *;
import SimDma :: *;
import SimGenRdmaReqResp :: *;
import SimExtractRdmaHeaderPayload :: *;
import Utils :: *;
import Utils4Test :: *;

interface SimPermCheckClt;
    interface PermCheckClt cltPort;
    method Bool done();
endinterface

module mkSimPermCheckClt(SimPermCheckClt) provisos(
    NumAlias#(TLog#(TAdd#(1, MAX_CMP_CNT)), cntSz)
);
    FIFOF#(PermCheckReq) reqQ <- mkFIFOF;
    FIFOF#(Bool) respQ <- mkFIFOF;
    Count#(Bit#(cntSz))  reqCnt <- mkCount(fromInteger(valueOf(MAX_CMP_CNT)));
    Count#(Bit#(cntSz)) respCnt <- mkCount(fromInteger(valueOf(MAX_CMP_CNT)));

    rule issueReq if (!isZero(reqCnt));
        let permCheckReq = PermCheckReq {
            wrID         : tagged Invalid,
            lkey         : dontCareValue,
            rkey         : dontCareValue,
            localOrRmtKey: True,
            reqAddr      : dontCareValue,
            totalLen     : dontCareValue,
            pdHandler    : dontCareValue,
            isZeroDmaLen : False,
            accFlags     : dontCareValue
        };

        reqQ.enq(permCheckReq);
        reqCnt.decr(1);
        // $display("time=%0t: issued one request, reqCnt=%0d", $time, reqCnt);
    endrule

    rule recvResp if (!isZero(respCnt));
        respQ.deq;
        respCnt.decr(1);
        // $display("time=%0t: received one response, respCnt=%0d", $time, respCnt);
    endrule

    interface cltPort = toGPClient(reqQ, respQ);
    method Bool done() = isZero(reqCnt) && isZero(respCnt);
endmodule

(* doc = "testcase" *)
module mkTestPermCheckCltArbiter(Empty);
    function Bool isCltDone(SimPermCheckClt simPermCheckClt) = simPermCheckClt.done;
    function PermCheckClt getPermCheckClt(SimPermCheckClt simPermCheckClt) = simPermCheckClt.cltPort;

    Vector#(TWO, SimPermCheckClt) simPermCheckCltVec <- replicateM(mkSimPermCheckClt);
    let permCheckCltVec = map(getPermCheckClt, simPermCheckCltVec);
    let permCheckClt <- mkPermCheckCltArbiter(permCheckCltVec);
    let simPermCheckCltDoneVec = map(isCltDone, simPermCheckCltVec);
    let allDone = fold(\&& , simPermCheckCltDoneVec);

    let mrCheckPassOrFail = True;
    let permCheckSrv <- mkSimPermCheckSrv(mrCheckPassOrFail);

    mkConnection(permCheckClt, permCheckSrv);

    rule checkDone if (allDone);
        // for (Integer idx = 0; idx < valueOf(TWO); idx = idx + 1) begin
        //     $display(
        //         "time=%0t:", $time,
        //         " simPermCheckClt idx=%0d", idx,
        //         ", done=", fshow(simPermCheckCltDoneVec[idx])
        //     );
        // end
        normalExit;
    endrule
endmodule

interface SimDmaReadClt;
    interface DmaReadClt cltPort;
    method Bool done();
endinterface

module mkSimDmaReadClt(SimDmaReadClt) provisos(
    NumAlias#(TLog#(TAdd#(1, MAX_CMP_CNT)), cntSz)
);
    FIFOF#(DmaReadReq)   reqQ <- mkFIFOF;
    FIFOF#(DmaReadResp) respQ <- mkFIFOF;
    Count#(Bit#(cntSz))  reqCnt <- mkCount(fromInteger(valueOf(MAX_CMP_CNT)));
    Count#(Bit#(cntSz)) respCnt <- mkCount(fromInteger(valueOf(MAX_CMP_CNT)));

    rule issueReq if (!isZero(reqCnt));
        let dmaReadReq = DmaReadReq {
            initiator: DMA_SRC_SQ_RD,
            sqpn     : dontCareValue,
            startAddr: dontCareValue,
            len      : 1025,
            mrID     : dontCareValue
        };

        reqQ.enq(dmaReadReq);
        reqCnt.decr(1);
        // $display("time=%0t: issued one request, reqCnt=%0d", $time, reqCnt);
    endrule

    rule recvResp if (!isZero(respCnt));
        let dmaReadResp = respQ.first;
        respQ.deq;

        if (dmaReadResp.dataStream.isLast) begin
            respCnt.decr(1);
            // $display("time=%0t: received whole response, respCnt=%0d", $time, respCnt);
        end
    endrule

    interface cltPort = toGPClient(reqQ, respQ);
    method Bool done() = isZero(reqCnt) && isZero(respCnt);
endmodule

(* doc = "testcase" *)
module mkTestDmaReadCltArbiter(Empty);
    function Bool isCltDone(SimDmaReadClt simDmaReadClt) = simDmaReadClt.done;
    function DmaReadClt getDmaReadClt(SimDmaReadClt simDmaReadClt) = simDmaReadClt.cltPort;

    Vector#(FOUR, SimDmaReadClt) simDmaReadCltVec <- replicateM(mkSimDmaReadClt);
    let dmaReadCltVec = map(getDmaReadClt, simDmaReadCltVec);
    let dmaReadClt <- mkDmaReadCltArbiter(dmaReadCltVec);
    let simDmaReadCltDoneVec = map(isCltDone, simDmaReadCltVec);
    let allDone = fold(\&& , simDmaReadCltDoneVec);

    let dmaReadSrv <- mkSimDmaReadSrv;

    mkConnection(dmaReadClt, dmaReadSrv);

    rule checkDone if (allDone);
        normalExit;
    endrule
endmodule

(* doc = "testcase" *)
module mkTestQueuePairReqErrResetCase(Empty);
    let qpType = IBV_QPT_RC;
    let pmtu = IBV_MTU_256;

    let qpInitAttr = QpInitAttr {
        qpType  : qpType,
        sqSigAll: False
    };

    let recvSideQP <- mkQP;

    // Cycle QP state
    let setExpectedPsnAsNextPSN = True;
    let setZero2ExpectedPsnAndNextPSN = True;
    let qpDestroyWhenErr = True;
    let cntrlStateCycle <- mkCntrlStateCycle(
        recvSideQP.srvPortQP,
        recvSideQP.statusSQ,
        getDefaultQPN,
        qpType,
        pmtu,
        setExpectedPsnAsNextPSN,
        setZero2ExpectedPsnAndNextPSN,
        qpDestroyWhenErr
    );

    // WorkReq
    let illegalAtomicWorkReqPipeOut <- mkGenIllegalAtomicWorkReq;
    // Pending WR generation
    let pendingWorkReqPipeOut4Req =
        genFixedPsnPendingWorkReqPipeOut(illegalAtomicWorkReqPipeOut);

    // DMA
    let dmaReadClt  <- mkDmaReadCltArbiter(vec(recvSideQP.dmaReadClt4RQ, recvSideQP.dmaReadClt4SQ));
    let dmaWriteClt <- mkDmaWriteCltArbiter(vec(recvSideQP.dmaWriteClt4RQ, recvSideQP.dmaWriteClt4SQ));
    let simDmaReadSrv  <- mkSimDmaReadSrv;
    let simDmaWriteSrv <- mkSimDmaWriteSrv;
    mkConnection(dmaReadClt, simDmaReadSrv);
    mkConnection(dmaWriteClt, simDmaWriteSrv);

    // MR permission check
    let mrCheckPassOrFail = True;
    let simPermCheckSrv <- mkSimPermCheckSrv(mrCheckPassOrFail);
    let permCheckClt <- mkPermCheckCltArbiter(vec(
        recvSideQP.permCheckClt4RQ, recvSideQP.permCheckClt4SQ
    ));
    mkConnection(permCheckClt, simPermCheckSrv);

    // Generate RDMA requests
    let simReqGen <- mkSimGenRdmaReq(
        pendingWorkReqPipeOut4Req, qpType, pmtu
    );
    let rdmaReqPipeOut = simReqGen.rdmaReqDataStreamPipeOut;
    mkSink(simReqGen.pendingWorkReqPipeOut);

    // Extract RDMA request metadata and payload
    let reqPktMetaDataAndPayloadPipeOut <- mkSimExtractNormalHeaderPayload(rdmaReqPipeOut);
    mkConnection(reqPktMetaDataAndPayloadPipeOut, recvSideQP.reqPktPipeIn);
    let rdmaRespPipeOut = recvSideQP.rdmaRespPipeOut;
    let recvSideNoReqOutRule <- addRules(genEmptyPipeOutRule(
        recvSideQP.rdmaReqPipeOut,
        "recvSideQP.rdmaReqPipeOut empty assertion @ mkTestQueuePairReqErrResetCase"
    ));

    // Empty pipe check
    let sendSideNoWorkCompOutRule4RQ <- addRules(genEmptyPipeOutRule(
        recvSideQP.workCompPipeOutRQ,
        "recvSideQP.workCompPipeOutRQ empty assertion @ mkTestQueuePairReqErrResetCase"
    ));
    let recvQNoWorkCompOutRule4SQ <- addRules(genEmptyPipeOutRule(
        recvSideQP.workCompPipeOutSQ,
        "recvSideQP.workCompPipeOutSQ empty assertion @ mkTestQueuePairReqErrResetCase"
    ));

    let countDown <- mkCountDown(valueOf(TDiv#(MAX_CMP_CNT, 10)));

    rule checkErrResp;
        let rdmaErrRespDataStream = rdmaRespPipeOut.first;
        rdmaRespPipeOut.deq;

        immAssert(
            rdmaErrRespDataStream.isFirst && rdmaErrRespDataStream.isLast,
            "single fragment assertion @ mkTestQueuePairReqErrResetCase",
            $format(
                "rdmaErrRespDataStream.isFirst=", fshow(rdmaErrRespDataStream.isFirst),
                " rdmaErrRespDataStream.isLast=", fshow(rdmaErrRespDataStream.isLast),
                " should both be true"
            )
        );

        let bth = extractBTH(zeroExtendLSB(rdmaErrRespDataStream.data));
        let aeth = extractAETH(zeroExtendLSB(rdmaErrRespDataStream.data));
        let rdmaOpCode = bth.opcode;

        // let workReq4Ref = pendingWorkReqPipeOut4Resp.first;
        // if (isLastOrOnlyRdmaOpCode(rdmaOpCode)) begin
        //     pendingWorkReqPipeOut4Resp.deq;
        // end

        // immAssert(
        //     rdmaReqOpCodeMatchWorkReqOpCode(rdmaOpCode, workReq4Ref.opcode),
        //     "rdmaReqOpCodeMatchWorkReqOpCode assertion @ mkTestQueuePairReqErrResetCase",
        //     $format(
        //         "RDMA request opcode=", fshow(rdmaOpCode),
        //         " should match workReqOpCode=", fshow(workReq4Ref.opcode)
        //     )
        // );

        immAssert(
            aeth.code == AETH_CODE_NAK && aeth.value == zeroExtend(pack(AETH_NAK_INV_REQ)),
            "aeth.code assertion @ mkTestQueuePairReqErrResetCase",
            $format(
                "aeth.code=", fshow(aeth.code),
                " should be AETH_CODE_NAK",
                ", and aeth.value=", fshow(aeth.value),
                " should be AETH_NAK_INV_REQ"
            )
        );

        // testStateReg <= TEST_RESET_DELETE_QP;
        countDown.decr;
        // $display(
        //     "time=%0t: checkErrResp", $time,
        //     ", rdmaOpCode=", fshow(rdmaOpCode),
        //     ", aeth.code=", fshow(aeth.code)
        // );
    endrule
endmodule

typedef enum {
    TEST_QP_RESP_ERR_RESET,
    TEST_QP_TIMEOUT_ERR_RESET
} TestErrResetTypeQP deriving(Bits, Eq);

(* doc = "testcase" *)
module mkTestQueuePairRespErrResetCase(Empty);
    let errType = TEST_QP_RESP_ERR_RESET;
    let result <- mkTestQueuePairResetCase(errType);
endmodule

(* doc = "testcase" *)
module mkTestQueuePairTimeOutErrResetCase(Empty);
    let errType = TEST_QP_TIMEOUT_ERR_RESET;
    let result <- mkTestQueuePairResetCase(errType);
endmodule

module mkTestQueuePairResetCase#(TestErrResetTypeQP errType)(Empty);
    let minPayloadLen = 1;
    let maxPayloadLen = 2048;
    let qpType = IBV_QPT_RC;
    let pmtu = IBV_MTU_256;

    let qpInitAttr = QpInitAttr {
        qpType  : qpType,
        sqSigAll: False
    };

    let sendSideQP <- mkQP;

    // Cycle QP state
    let setExpectedPsnAsNextPSN = True;
    let setZero2ExpectedPsnAndNextPSN = True;
    let qpDestroyWhenErr = True;
    let cntrlStateCycle <- mkCntrlStateCycle(
        sendSideQP.srvPortQP,
        sendSideQP.statusSQ,
        getDefaultQPN,
        qpType,
        pmtu,
        setExpectedPsnAsNextPSN,
        setZero2ExpectedPsnAndNextPSN,
        qpDestroyWhenErr
    );

    // WorkReq
    let illegalAtomicWorkReqPipeOut <- mkGenIllegalAtomicWorkReq;
    mkConnectionWhen(
        toGet(illegalAtomicWorkReqPipeOut),
        sendSideQP.workReqIn,
        sendSideQP.statusSQ.comm.isNonErr
    );
    // mkConnection(toGet(illegalAtomicWorkReqPipeOut), sendSideQP.workReqIn);

    // RecvReq
    FIFOF#(RecvReq) emptyRecvReqQ <- mkFIFOF;
    mkConnection(toGet(emptyRecvReqQ), sendSideQP.recvReqIn);

    // DMA
    let dmaReadClt  <- mkDmaReadCltArbiter(vec(sendSideQP.dmaReadClt4RQ, sendSideQP.dmaReadClt4SQ));
    let dmaWriteClt <- mkDmaWriteCltArbiter(vec(sendSideQP.dmaWriteClt4RQ, sendSideQP.dmaWriteClt4SQ));
    let simDmaReadSrv  <- mkSimDmaReadSrv;
    let simDmaWriteSrv <- mkSimDmaWriteSrv;
    mkConnection(dmaReadClt, simDmaReadSrv);
    mkConnection(dmaWriteClt, simDmaWriteSrv);

    // MR permission check
    let mrCheckPassOrFail = True;
    let simPermCheckSrv <- mkSimPermCheckSrv(mrCheckPassOrFail);
    let permCheckClt <- mkPermCheckCltArbiter(vec(
        sendSideQP.permCheckClt4RQ, sendSideQP.permCheckClt4SQ
    ));
    mkConnection(permCheckClt, simPermCheckSrv);

    mkSink(sendSideQP.rdmaReqPipeOut);
    let sendSideNoRespOutRule <- addRules(genEmptyPipeOutRule(
        sendSideQP.rdmaRespPipeOut,
        "sendSideQP.rdmaRespPipeOut empty assertion @ mkTestQueuePairResetCase"
    ));

    // Extract RDMA response metadata and payload
    if (errType != TEST_QP_TIMEOUT_ERR_RESET) begin
        let genAckType = GEN_RDMA_RESP_ACK_ERROR;
        let rdmaErrRespPipeOut <- mkGenFixedPsnRdmaRespAck(sendSideQP.statusSQ, genAckType);
        let respPktMetaDataAndPayloadPipeOut <- mkSimExtractNormalHeaderPayload(rdmaErrRespPipeOut);
        mkConnection(respPktMetaDataAndPayloadPipeOut, sendSideQP.respPktPipeIn);
        // let respPktMetaDataPipeOut = respPktMetaDataAndPayloadPipeOut.pktMetaData;
        let respNoPayloadRule <- addRules(genEmptyPipeOutRule(
            respPktMetaDataAndPayloadPipeOut.payload,
            "respPktMetaDataAndPayloadPipeOut.payload empty assertion @ mkTestQueuePairResetCase"
        ));
    end

    // Empty pipe check
    let sendSideNoWorkCompOutRule4RQ <- addRules(genEmptyPipeOutRule(
        sendSideQP.workCompPipeOutRQ,
        "sendSideQP.workCompPipeOutRQ empty assertion @ mkTestQueuePairResetCase"
    ));

    Reg#(Bool) firstErrWorkCompCheckedReg <- mkRegU;

    let countDown <- mkCountDown(valueOf(TDiv#(MAX_CMP_CNT, 10)));

    rule resetCSR if (sendSideQP.statusSQ.comm.isReset);
        firstErrWorkCompCheckedReg <= False;
    endrule

    rule checkErrWorkComp if (!sendSideQP.statusSQ.comm.isReset);
        let errWorkComp = sendSideQP.workCompPipeOutSQ.first;
        sendSideQP.workCompPipeOutSQ.deq;

        // immAssert(
        //     workCompMatchWorkReqInSQ(timeOutErrWC, firstWorkReqReg),
        //     "workCompMatchWorkReqInSQ assertion @ mkTestQueuePairResetCase",
        //     $format(
        //         "timeOutErrWC=", fshow(timeOutErrWC),
        //         " not match WR=", fshow(firstWorkReqReg)
        //     )
        // );

        let expectedWorkCompStatus = IBV_WC_WR_FLUSH_ERR;
        if (!firstErrWorkCompCheckedReg) begin
            expectedWorkCompStatus = case (errType)
                TEST_QP_RESP_ERR_RESET   : IBV_WC_REM_OP_ERR;
                TEST_QP_TIMEOUT_ERR_RESET: IBV_WC_RESP_TIMEOUT_ERR;
                default                  : IBV_WC_SUCCESS;
            endcase;
            firstErrWorkCompCheckedReg <= True;
        end
        immAssert(
            errWorkComp.status == expectedWorkCompStatus,
            "errWorkComp.status assertion @ mkTestQueuePairResetCase",
            $format(
                "errWorkComp.status=", fshow(errWorkComp.status),
                " not match expected status=", fshow(expectedWorkCompStatus)
            )
        );

        countDown.decr;
        // $display(
        //     "time=%0t: errWorkComp=", $time, fshow(errWorkComp)
        //     // " not match WR=", fshow(firstWorkReqReg)
        // );
    endrule
endmodule

(* doc = "testcase" *)
module mkTestQueuePairTimeOutErrCase(Empty);
    let minPayloadLen = 1;
    let maxPayloadLen = 2048;
    let qpType = IBV_QPT_RC;
    let pmtu = IBV_MTU_256;

    let sendSideQP <- mkQP;

    // Set QP to RTS
    let setSendQ2RTS <- mkChangeCntrlState2RTS(
        sendSideQP.srvPortQP,
        sendSideQP.statusSQ,
        getDefaultQPN,
        qpType,
        pmtu
    );

    // WorkReq
    Vector#(2, PipeOut#(WorkReq)) workReqPipeOutVec <-
        mkRandomWorkReq(minPayloadLen, maxPayloadLen);
    let workReqPipeOut = workReqPipeOutVec[0];
    let workReqPipeOut4Ref <- mkBufferN(valueOf(MAX_QP_WR), workReqPipeOutVec[1]);
    mkConnectionWhen(
        toGet(workReqPipeOut),
        sendSideQP.workReqIn,
        sendSideQP.statusSQ.comm.isNonErr
    );
    // mkConnection(toGet(workReqPipeOut), sendSideQP.workReqIn);

    // RecvReq
    FIFOF#(RecvReq) emptyRecvReqQ <- mkFIFOF;
    mkConnection(toGet(emptyRecvReqQ), sendSideQP.recvReqIn);

    // DMA
    let dmaReadClt  <- mkDmaReadCltArbiter(vec(sendSideQP.dmaReadClt4RQ, sendSideQP.dmaReadClt4SQ));
    let dmaWriteClt <- mkDmaWriteCltArbiter(vec(sendSideQP.dmaWriteClt4RQ, sendSideQP.dmaWriteClt4SQ));
    let simDmaReadSrv  <- mkSimDmaReadSrv;
    let simDmaWriteSrv <- mkSimDmaWriteSrv;
    mkConnection(dmaReadClt, simDmaReadSrv);
    mkConnection(dmaWriteClt, simDmaWriteSrv);
    // Vector#(2, DmaReadClt)  dmaReadCltVec  = vec(sendSideQP.dmaReadClt4SQ, sendSideQP.dmaReadClt4RQ);
    // Vector#(2, DmaWriteClt) dmaWriteCltVec = vec(sendSideQP.dmaWriteClt4SQ, sendSideQP.dmaWriteClt4RQ);
    // Vector#(2, DmaReadSrv)  simDmaReadSrvVec  <- replicateM(mkSimDmaReadSrv);
    // Vector#(2, DmaWriteSrv) simDmaWriteSrvVec <- replicateM(mkSimDmaWriteSrv);
    // for (Integer idx = 0; idx < 2; idx = idx + 1) begin
    //     mkConnection(dmaReadCltVec[idx], simDmaReadSrvVec[idx]);
    //     mkConnection(dmaWriteCltVec[idx], simDmaWriteSrvVec[idx]);
    // end

    // MR permission check
    let mrCheckPassOrFail = True;
    let simPermCheckSrv <- mkSimPermCheckSrv(mrCheckPassOrFail);
    let permCheckClt <- mkPermCheckCltArbiter(vec(
        sendSideQP.permCheckClt4RQ, sendSideQP.permCheckClt4SQ
    ));
    mkConnection(permCheckClt, simPermCheckSrv);

    // Extract RDMA request metadata and payload
    let reqPktMetaDataAndPayloadPipeOut <- mkSimExtractNormalHeaderPayload(sendSideQP.rdmaReqPipeOut);
    let sendSideNoRespOutRule <- addRules(genEmptyPipeOutRule(
        sendSideQP.rdmaRespPipeOut,
        "sendSideQP.rdmaRespPipeOut empty assertion @ mkTestQueuePairTimeOutCase"
    ));
    mkSink(reqPktMetaDataAndPayloadPipeOut.payload);
    let reqPktMetaDataPipeOut = reqPktMetaDataAndPayloadPipeOut.pktMetaData;
    mkSink(reqPktMetaDataPipeOut);

    // Empty pipe check
    let sendSideNoWorkCompOutRule4RQ <- addRules(genEmptyPipeOutRule(
        sendSideQP.workCompPipeOutRQ,
        "sendSideQP.workCompPipeOutRQ empty assertion @ mkTestQueuePairTimeOutCase"
    ));

    Reg#(Bool) firstWorkReqSavedReg <- mkReg(False);
    Reg#(WorkReq) firstWorkReqReg <- mkRegU;
    // Count#(Bit#(TLog#(DEFAULT_RETRY_NUM))) retryCnt <- mkCount();
    // let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    // rule compareWorkReq;
    //     let pktMetaData = reqPktMetaDataPipeOut.first;
    //     reqPktMetaDataPipeOut.deq;

    //     let bth = extractBTH(pktMetaData.pktHeader.headerData);
    //     let rdmaOpCode = bth.opcode;

    //     // let workReq4Ref = workReqPipeOut4Ref.first;
    //     // if (isLastOrOnlyRdmaOpCode(rdmaOpCode)) begin
    //     //     workReqPipeOut4Ref.deq;
    //     // end

    //     // immAssert(
    //     //     rdmaReqOpCodeMatchWorkReqOpCode(rdmaOpCode, workReq4Ref.opcode),
    //     //     "rdmaReqOpCodeMatchWorkReqOpCode assertion @ mkTestQueuePairTimeOutCase",
    //     //     $format(
    //     //         "RDMA request opcode=", fshow(rdmaOpCode),
    //     //         " should match workReqOpCode=", fshow(workReq4Ref.opcode)
    //     //     )
    //     // );

    //     $display(
    //         "time=%0t: rdmaOpCode=", $time, fshow(rdmaOpCode)
    //         // " not match WR=", fshow(workReq4Ref)
    //     );
    //     // countDown.decr;
    // endrule

    // TODO: find out why workReqPipeOut4Ref size > MAX_QP_WR or flush this buffer will deadlock?
    rule saveFirstWorkReq if (!firstWorkReqSavedReg);
        let workReq4Ref = workReqPipeOut4Ref.first;
        workReqPipeOut4Ref.deq;

        if (!firstWorkReqSavedReg) begin
            firstWorkReqReg <= workReq4Ref;
            firstWorkReqSavedReg <= True;
        end
    endrule

    rule checkTimeOutErrWC if (firstWorkReqSavedReg);
        let timeOutErrWC = sendSideQP.workCompPipeOutSQ.first;
        sendSideQP.workCompPipeOutSQ.deq;

        immAssert(
            workCompMatchWorkReqInSQ(timeOutErrWC, firstWorkReqReg),
            "workCompMatchWorkReqInSQ assertion @ mkTestQueuePairTimeOutErrCase",
            $format(
                "timeOutErrWC=", fshow(timeOutErrWC),
                " not match WR=", fshow(firstWorkReqReg)
            )
        );

        let expectedWorkCompStatus = IBV_WC_RESP_TIMEOUT_ERR;
        immAssert(
            timeOutErrWC.status == expectedWorkCompStatus,
            "workCompSQ.status assertion @ mkTestQueuePairTimeOutErrCase",
            $format(
                "timeOutErrWC.status=", fshow(timeOutErrWC.status),
                " not match expected status=", fshow(expectedWorkCompStatus)
            )
        );

        // $display(
        //     "time=%0t: timeOutErrWC=", $time, fshow(timeOutErrWC),
        //     " not match WR=", fshow(firstWorkReqReg)
        // );
        normalExit;
    endrule
endmodule

(* doc = "testcase" *)
module mkTestQueuePairNormalCase(Empty);
    let minPayloadLen = 1;
    let maxPayloadLen = 2048;
    let qpType = IBV_QPT_RC;
    let pmtu = IBV_MTU_256;

    let sendSideQP <- mkQP;
    let recvSideQP <- mkQP;

    // Set QP to RTS
    let setSendQ2RTS <- mkChangeCntrlState2RTS(
        sendSideQP.srvPortQP,
        sendSideQP.statusSQ,
        getDefaultQPN,
        qpType,
        pmtu
    );
    let setRecvQ2RTS <- mkChangeCntrlState2RTS(
        recvSideQP.srvPortQP,
        recvSideQP.statusRQ,
        getDefaultQPN,
        qpType,
        pmtu
    );

    // WorkReq
    Vector#(2, PipeOut#(WorkReq)) workReqPipeOutVec <-
        mkRandomWorkReq(minPayloadLen, maxPayloadLen);
    let workReqPipeOut = workReqPipeOutVec[0];
    let workReqPipeOut4Ref <- mkBufferN(8, workReqPipeOutVec[1]);
    mkConnectionWhen(
        toGet(workReqPipeOut),
        sendSideQP.workReqIn,
        sendSideQP.statusSQ.comm.isNonErr
    );
    // mkConnection(toGet(workReqPipeOut), sendSideQP.workReqIn);
    FIFOF#(WorkReq) emptyWorkReqQ <- mkFIFOF;
    mkConnection(toGet(emptyWorkReqQ), recvSideQP.workReqIn);

    // RecvReq
    Vector#(2, PipeOut#(RecvReq)) recvReqBufVec <- mkSimGenRecvReq;
    let recvReqPipeOut = recvReqBufVec[0];
    let recvReqPipeOut4Ref <- mkBufferN(valueOf(MAX_QP_WR), recvReqBufVec[1]);
    mkConnectionWhen(
        toGet(recvReqPipeOut),
        recvSideQP.recvReqIn,
        sendSideQP.statusRQ.comm.isNonErr
    );
    // mkConnection(toGet(recvReqPipeOut), recvSideQP.recvReqIn);
    FIFOF#(RecvReq) emptyRecvReqQ <- mkFIFOF;
    mkConnection(toGet(emptyRecvReqQ), sendSideQP.recvReqIn);

    // DMA
    // let dmaReadClt  <- mkDmaReadCltArbiter(vec(sendSideQP.dmaReadClt, recvSideQP.dmaReadClt));
    // let dmaWriteClt <- mkDmaWriteCltArbiter(vec(sendSideQP.dmaWriteClt, recvSideQP.dmaWriteClt));
    let dmaReadClt  <- mkDmaReadCltArbiter(vec(sendSideQP.dmaReadClt4SQ, sendSideQP.dmaReadClt4RQ, recvSideQP.dmaReadClt4RQ, recvSideQP.dmaReadClt4SQ));
    let dmaWriteClt <- mkDmaWriteCltArbiter(vec(sendSideQP.dmaWriteClt4SQ, sendSideQP.dmaWriteClt4RQ, recvSideQP.dmaWriteClt4RQ, recvSideQP.dmaWriteClt4SQ));
    let simDmaReadSrv  <- mkSimDmaReadSrv;
    let simDmaWriteSrv <- mkSimDmaWriteSrv;
    mkConnection(dmaReadClt, simDmaReadSrv);
    mkConnection(dmaWriteClt, simDmaWriteSrv);

    // MR permission check
    let mrCheckPassOrFail = True;
    let simPermCheckSrv <- mkSimPermCheckSrv(mrCheckPassOrFail);
    let permCheckClt <- mkPermCheckCltArbiter(vec(
        sendSideQP.permCheckClt4RQ, sendSideQP.permCheckClt4SQ, recvSideQP.permCheckClt4RQ, recvSideQP.permCheckClt4SQ
    ));
    mkConnection(permCheckClt, simPermCheckSrv);
    // Vector#(4, PermCheckSrv) simPermCheckVec <- replicateM(mkSimPermCheckSrv(mrCheckPassOrFail));
    // Vector#(4, PermCheckClt) permCheckCltVec = vec(
    //     sendSideQP.permCheckClt4RQ, sendSideQP.permCheckClt4SQ, recvSideQP.permCheckClt4RQ, recvSideQP.permCheckClt4SQ
    // );
    // for (Integer idx = 0; idx < 4; idx = idx + 1) begin
    //     mkConnection(permCheckCltVec[idx], simPermCheckVec[idx]);
    // end

    let reqPktMetaDataAndPayloadPipeOut  <- mkSimExtractNormalHeaderPayload(sendSideQP.rdmaReqPipeOut);
    let sendSideNoRespOutRule <- addRules(genEmptyPipeOutRule(
        sendSideQP.rdmaRespPipeOut,
        "sendSideQP.rdmaRespPipeOut empty assertion @ mkTestQueuePairTimeOutCase"
    ));
    let respPktMetaDataAndPayloadPipeOut <- mkSimExtractNormalHeaderPayload(recvSideQP.rdmaRespPipeOut);
    let recvSideNoReqOutRule <- addRules(genEmptyPipeOutRule(
        recvSideQP.rdmaReqPipeOut,
        "recvSideQP.rdmaReqPipeOut empty assertion @ mkTestQueuePairNormalCase"
    ));

    // Connect SQ and RQ
    mkConnection(reqPktMetaDataAndPayloadPipeOut, recvSideQP.reqPktPipeIn);
    mkConnection(respPktMetaDataAndPayloadPipeOut, sendSideQP.respPktPipeIn);

    // Empty pipe check
    let addSendQNoWorkCompOutRule <- addRules(genEmptyPipeOutRule(
        sendSideQP.workCompPipeOutRQ,
        "sendSideQP.workCompPipeOutRQ empty assertion @ mkTestQueuePairNormalCase"
    ));
    let addRecvQNoWorkCompOutRule <- addRules(genEmptyPipeOutRule(
        recvSideQP.workCompPipeOutSQ,
        "recvSideQP.workCompPipeOutSQ empty assertion @ mkTestQueuePairNormalCase"
    ));

    // mkSink(sendSideQP.workCompPipeOutSQ);
    // mkSink(workReqPipeOut4Ref);
    // mkSink(recvSideQP.workCompPipeOutRQ);
    // mkSink(recvReqPipeOut4Ref);

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    rule compareWorkComp4SQ;
        let workReq4Ref = workReqPipeOut4Ref.first;
        workReqPipeOut4Ref.deq;

        let workCompSQ = sendSideQP.workCompPipeOutSQ.first;
        sendSideQP.workCompPipeOutSQ.deq;

        immAssert(
            workCompMatchWorkReqInSQ(workCompSQ, workReq4Ref),
            "workCompMatchWorkReqInSQ assertion @ mkTestQueuePairNormalCase",
            $format("WC=", fshow(workCompSQ), " not match WR=", fshow(workReq4Ref))
        );

        let expectedWorkCompStatus = IBV_WC_SUCCESS;
        immAssert(
            workCompSQ.status == expectedWorkCompStatus,
            "workCompSQ.status assertion @ mkTestQueuePairNormalCase",
            $format(
                "workCompSQ.status=", fshow(workCompSQ.status),
                " not match expected status=", fshow(expectedWorkCompStatus)
            )
        );

        // $display(
        //     "time=%0t: WC=", $time, fshow(workCompSQ), " not match WR=", fshow(workReq4Ref)
        // );
    endrule

    rule compareWorkComp4RQ;
        let recvReq4Ref = recvReqPipeOut4Ref.first;
        recvReqPipeOut4Ref.deq;

        let workCompRQ = recvSideQP.workCompPipeOutRQ.first;
        recvSideQP.workCompPipeOutRQ.deq;

        immAssert(
            workCompRQ.id == recvReq4Ref.id,
            "workCompRQ.id assertion @ mkTestQueuePairNormalCase",
            $format(
                "WC ID=", fshow(workCompRQ.id),
                " not match expected recvReqID=", fshow(recvReq4Ref.id))
        );

        let expectedWorkCompStatus = IBV_WC_SUCCESS;
        immAssert(
            workCompRQ.status == expectedWorkCompStatus,
            "workCompRQ.status assertion @ mkTestQueuePairNormalCase",
            $format(
                "workCompRQ.status=", fshow(workCompRQ.status),
                " not match expected status=", fshow(expectedWorkCompStatus)
            )
        );

        countDown.decr;
        // $display(
        //     "time=%0t: WC=", $time, fshow(workCompRQ), " not match RR=", fshow(recvReq4Ref)
        // );
    endrule
endmodule
