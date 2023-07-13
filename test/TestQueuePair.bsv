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
    NumAlias#(TAdd#(1, TLog#(MAX_CMP_CNT)), cntSz)
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

(* synthesize *)
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
    NumAlias#(TAdd#(1, TLog#(MAX_CMP_CNT)), cntSz)
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
            wrID     : dontCareValue
        };

        reqQ.enq(dmaReadReq);
        reqCnt.decr(1);
        $display("time=%0t: issued one request, reqCnt=%0d", $time, reqCnt);
    endrule

    rule recvResp if (!isZero(respCnt));
        let dmaReadResp = respQ.first;
        respQ.deq;

        if (dmaReadResp.dataStream.isLast) begin
            respCnt.decr(1);
            $display("time=%0t: received whole response, respCnt=%0d", $time, respCnt);
        end
    endrule

    interface cltPort = toGPClient(reqQ, respQ);
    method Bool done() = isZero(reqCnt) && isZero(respCnt);
endmodule

(* synthesize *)
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

typedef enum {
    TEST_RESET_CREATE_QP,
    TEST_RESET_INIT_QP,
    TEST_RESET_SET_QP_RTR,
    TEST_RESET_SET_QP_RTS,
    TEST_RESET_CHECK_QP_RTS,
    TEST_RESET_ERR_NOTIFY,
    TEST_RESET_DELETE_QP,
    TEST_RESET_CHECK_QP_DELETED,
    TEST_RESET_WAIT_RESET
} TestErrResetState deriving(Bits, Eq, FShow);

(* synthesize *)
module mkTestQueuePairReqErrResetCase(Empty);
    // let minPayloadLen = 1;
    // let maxPayloadLen = 2048;
    let qpType = IBV_QPT_RC;
    let pmtu = IBV_MTU_256;

    let qpInitAttr = QpInitAttr {
        qpType  : qpType,
        sqSigAll: False
    };

    let recvSideQP <- mkQP;

    // WorkReq
    let illegalAtomicWorkReqPipeOut <- mkGenIllegalAtomicWorkReq;
    // Pending WR generation
    let pendingWorkReqPipeOut4Req =
        genFixedPsnPendingWorkReqPipeOut(illegalAtomicWorkReqPipeOut);
    // Vector#(1, PipeOut#(PendingWorkReq)) existingPendingWorkReqPipeOutVec <-
    //     mkExistingPendingWorkReqPipeOut(cntrl, workReqPipeOut);
    // let pendingWorkReqPipeOut4Req = existingPendingWorkReqPipeOutVec[0];
    // let pendingWorkReqPipeOut4Resp <- mkBufferN(32, existingPendingWorkReqPipeOutVec[1]);

    // FIFOF#(WorkReq) emptyWorkReqQ <- mkFIFOF;
    // mkConnection(toGet(emptyWorkReqQ), recvSideQP.workReqIn);
    // // RecvReq
    // FIFOF#(RecvReq) emptyRecvReqQ <- mkFIFOF;
    // mkConnection(toGet(emptyRecvReqQ), recvSideQP.recvReqIn);

    // DMA
    // let dmaReadClt  <- mkDmaReadCltArbiter(vec(sendSideQP.dmaReadClt4RQ, sendSideQP.dmaReadClt4SQ));
    // let dmaWriteClt <- mkDmaWriteCltArbiter(vec(sendSideQP.dmaWriteClt4RQ, sendSideQP.dmaWriteClt4SQ));
    // let simDmaReadSrv  <- mkSimDmaReadSrv;
    // let simDmaWriteSrv <- mkSimDmaWriteSrv;
    // mkConnection(dmaReadClt, simDmaReadSrv);
    // mkConnection(dmaWriteClt, simDmaWriteSrv);
    Vector#(2, DmaReadClt)  dmaReadCltVec  = vec(recvSideQP.dmaReadClt4SQ, recvSideQP.dmaReadClt4RQ);
    Vector#(2, DmaWriteClt) dmaWriteCltVec = vec(recvSideQP.dmaWriteClt4SQ, recvSideQP.dmaWriteClt4RQ);
    Vector#(2, DmaReadSrv)  simDmaReadSrvVec  <- replicateM(mkSimDmaReadSrv);
    Vector#(2, DmaWriteSrv) simDmaWriteSrvVec <- replicateM(mkSimDmaWriteSrv);
    for (Integer idx = 0; idx < 2; idx = idx + 1) begin
        mkConnection(dmaReadCltVec[idx], simDmaReadSrvVec[idx]);
        mkConnection(dmaWriteCltVec[idx], simDmaWriteSrvVec[idx]);
    end

    // MR permission check
    let mrCheckPassOrFail = True;
    Vector#(2, PermCheckSrv) simPermCheckVec <- replicateM(mkSimPermCheckSrv(mrCheckPassOrFail));
    Vector#(2, PermCheckClt) permCheckCltVec = vec(
        recvSideQP.permCheckClt4RQ, recvSideQP.permCheckClt4SQ
    );
    for (Integer idx = 0; idx < 2; idx = idx + 1) begin
        mkConnection(permCheckCltVec[idx], simPermCheckVec[idx]);
    end
    // let simPermCheckSrv <- mkSimPermCheckSrv(mrCheckPassOrFail);
    // let permCheckClt <- mkPermCheckCltArbiter(vec(
    //     sendSideQP.permCheckClt4RQ, sendSideQP.permCheckClt4SQ
    // ));
    // mkConnection(permCheckClt, simPermCheckSrv);

    // Generate RDMA requests
    let simReqGen <- mkSimGenRdmaReq(
        pendingWorkReqPipeOut4Req, qpType, pmtu
    );
    let rdmaReqPipeOut = simReqGen.rdmaReqDataStreamPipeOut;
    let newPendingWorkReqSink <- mkSink(simReqGen.pendingWorkReqPipeOut);
    // // Add rule to check no pending WR output
    // let addNoPendingWorkReqOutRule <- addRules(genEmptyPipeOutRule(
    //     simReqGen.pendingWorkReqPipeOut,
    //     "simReqGen.pendingWorkReqPipeOut empty assertion @ mkTestQueuePairReqErrResetCase"
    // ));

    // Extract RDMA request metadata and payload
    let reqPktMetaDataAndPayloadPipeOut <- mkSimExtractNormalHeaderPayload(rdmaReqPipeOut);
    mkConnection(reqPktMetaDataAndPayloadPipeOut, recvSideQP.reqPktPipeIn);
    let rdmaRespPipeOut = recvSideQP.rdmaReqRespPipeOut;

    // Empty pipe check
    let addSendQNoWorkCompOutRule <- addRules(genEmptyPipeOutRule(
        recvSideQP.workCompPipeOutRQ,
        "recvSideQP.workCompPipeOutRQ empty assertion @ mkTestQueuePairReqErrResetCase"
    ));
    let addRecvQNoWorkCompOutRule <- addRules(genEmptyPipeOutRule(
        recvSideQP.workCompPipeOutSQ,
        "recvSideQP.workCompPipeOutSQ empty assertion @ mkTestQueuePairReqErrResetCase"
    ));

    // For controller initialization
    let qpAttrPipeOut <- mkQpAttrPipeOut;

    Reg#(TestErrResetState) testStateReg <- mkReg(TEST_RESET_CREATE_QP);
    Reg#(Bool) firstWorkReqSavedReg <- mkRegU;
    Reg#(WorkReq) firstWorkReqReg <- mkRegU;

    let countDown <- mkCountDown(valueOf(TDiv#(MAX_CMP_CNT, 50)));

    rule createQP if (testStateReg == TEST_RESET_CREATE_QP);
        immAssert(
            recvSideQP.statusSQ.comm.isReset,
            "recvSideQP state assertion @ mkTestQueuePairReqErrResetCase",
            $format(
                "recvSideQP.statusSQ.comm.isReset=", fshow(recvSideQP.statusSQ.comm.isReset),
                " should be true"
            )
        );

        let qpCreateReq = ReqQP {
            qpReqType : REQ_QP_CREATE,
            pdHandler : dontCareValue,
            qpn       : getDefaultQPN,
            qpAttrMask: dontCareValue,
            qpAttr    : dontCareValue,
            qpInitAttr: qpInitAttr
        };

        recvSideQP.srvPortQP.request.put(qpCreateReq);
        testStateReg <= TEST_RESET_INIT_QP;
        $display("time=%0t:", $time, " create QP");
    endrule

    rule initQP if (testStateReg == TEST_RESET_INIT_QP);
        let qpCreateResp <- recvSideQP.srvPortQP.response.get;
        immAssert(
            qpCreateResp.successOrNot,
            "qpCreateResp.successOrNot assertion @ mkTestQueuePairReqErrResetCase",
            $format(
                "qpCreateResp.successOrNot=", fshow(qpCreateResp.successOrNot),
                " should be true when qpCreateResp=", fshow(qpCreateResp)
            )
        );

        let qpAttr = qpAttrPipeOut.first;
        qpAttr.qpState = IBV_QPS_INIT;
        let modifyReqQP = ReqQP {
            qpReqType : REQ_QP_MODIFY,
            pdHandler : dontCareValue,
            qpn       : getDefaultQPN,
            qpAttrMask: getReset2InitRequiredAttr,
            qpAttr    : qpAttr,
            qpInitAttr: qpInitAttr
        };
        recvSideQP.srvPortQP.request.put(modifyReqQP);

        testStateReg <= TEST_RESET_SET_QP_RTR;
        $display("time=%0t:", $time, " init QP");
    endrule

    rule setCntrlRTR if (testStateReg == TEST_RESET_SET_QP_RTR);
        let qpInitResp <- recvSideQP.srvPortQP.response.get;
        immAssert(
            qpInitResp.successOrNot,
            "qpInitResp.successOrNot assertion @ mkTestQueuePairReqErrResetCase",
            $format(
                "qpInitResp.successOrNot=", fshow(qpInitResp.successOrNot),
                " should be true when qpInitResp=", fshow(qpInitResp)
            )
        );

        let qpAttr = qpAttrPipeOut.first;
        qpAttr.qpState = IBV_QPS_RTR;
        qpAttr.pmtu = pmtu;
        let modifyReqQP = ReqQP {
            qpReqType : REQ_QP_MODIFY,
            pdHandler : dontCareValue,
            qpn       : getDefaultQPN,
            qpAttrMask: getInit2RtrRequiredAttr,
            qpAttr    : qpAttr,
            qpInitAttr: qpInitAttr
        };
        recvSideQP.srvPortQP.request.put(modifyReqQP);

        testStateReg <= TEST_RESET_SET_QP_RTS;
        $display("time=%0t:", $time, " set QP 2 RTR");
    endrule

    rule setCntrlRTS if (testStateReg == TEST_RESET_SET_QP_RTS);
        let qpRtrResp <- recvSideQP.srvPortQP.response.get;
        immAssert(
            qpRtrResp.successOrNot,
            "qpRtrResp.successOrNot assertion @ mkTestQueuePairReqErrResetCase",
            $format(
                "qpRtrResp.successOrNot=", fshow(qpRtrResp.successOrNot),
                " should be true when qpRtrResp=", fshow(qpRtrResp)
            )
        );

        let qpAttr = qpAttrPipeOut.first;
        qpAttr.qpState = IBV_QPS_RTS;
        let modifyReqQP = ReqQP {
            qpReqType : REQ_QP_MODIFY,
            pdHandler : dontCareValue,
            qpn       : getDefaultQPN,
            qpAttrMask: getRtr2RtsRequiredAttr,
            qpAttr    : qpAttr,
            qpInitAttr: qpInitAttr
        };
        recvSideQP.srvPortQP.request.put(modifyReqQP);

        testStateReg <= TEST_RESET_CHECK_QP_RTS;
        firstWorkReqSavedReg <= False;
        $display("time=%0t:", $time, " set QP 2 RTS");
    endrule

    rule checkStateRTS if (
        testStateReg == TEST_RESET_CHECK_QP_RTS
    );
        let qpRtsResp <- recvSideQP.srvPortQP.response.get;
        immAssert(
            qpRtsResp.successOrNot,
            "qpRtsResp.successOrNot assertion @ mkTestQueuePairReqErrResetCase",
            $format(
                "qpRtsResp.successOrNot=", fshow(qpRtsResp.successOrNot),
                " should be true when qpRtsResp=", fshow(qpRtsResp)
            )
        );

        immAssert(
            recvSideQP.statusSQ.comm.isRTS,
            "recvSideQP.statusSQ.comm.isRTS assertion @ mkTestQueuePairReqErrResetCase",
            $format(
                "recvSideQP.statusSQ.comm.isRTS=", fshow(recvSideQP.statusSQ.comm.isRTS),
                " should be true when qpRtsResp=", fshow(qpRtsResp)
            )
        );

        testStateReg <= TEST_RESET_ERR_NOTIFY;
        $display("time=%0t:", $time, " check QP in RTS state");
    endrule

    rule checkErrResp if (
        // firstWorkReqSavedReg &&
        testStateReg == TEST_RESET_ERR_NOTIFY
    );
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

        testStateReg <= TEST_RESET_DELETE_QP;
        $display(
            "time=%0t: checkErrResp", $time,
            ", rdmaOpCode=", fshow(rdmaOpCode),
            ", aeth.code=", fshow(aeth.code)
        );
    endrule

    rule deleteQP if (
        testStateReg == TEST_RESET_DELETE_QP &&
        recvSideQP.statusSQ.comm.isERR
    );
        // immAssert(
        //     recvSideQP.statusSQ.comm.isERR,
        //     "recvSideQP.statusSQ.comm.isERR assertion @ mkTestQueuePairReqErrResetCase",
        //     $format(
        //         "recvSideQP.statusSQ.comm.isERR=", fshow(recvSideQP.statusSQ.comm.isERR), " should be true"
        //         // " when qpModifyResp=", fshow(qpModifyResp)
        //     )
        // );

        let qpAttr = qpAttrPipeOut.first;
        // qpAttr.qpState = IBV_QPS_UNKNOWN;
        let deleteReqQP = ReqQP {
            qpReqType   : REQ_QP_DESTROY,
            pdHandler   : dontCareValue,
            qpn         : getDefaultQPN,
            qpAttrMask  : dontCareValue,
            qpAttr      : qpAttr,
            qpInitAttr  : qpInitAttr
        };
        recvSideQP.srvPortQP.request.put(deleteReqQP);

        testStateReg <= TEST_RESET_CHECK_QP_DELETED;
        $display("time=%0t:", $time, " delete QP");
    endrule

    rule checkDeleteQP if (
        testStateReg == TEST_RESET_CHECK_QP_DELETED
    );
        let qpDeleteResp <- recvSideQP.srvPortQP.response.get;
        immAssert(
            qpDeleteResp.successOrNot,
            "qpDeleteResp.successOrNot assertion @ mkTestQueuePairReqErrResetCase",
            $format(
                "qpDeleteResp.successOrNot=", fshow(qpDeleteResp.successOrNot),
                " should be true when qpDeleteResp=", fshow(qpDeleteResp)
            )
        );

        immAssert(
            recvSideQP.statusSQ.comm.isUnknown,
            "recvSideQP.statusSQ.comm.isUnknown assertion @ mkTestQueuePairReqErrResetCase",
            $format(
                "recvSideQP.statusSQ.comm.isUnknown=", fshow(recvSideQP.statusSQ.comm.isUnknown),
                " should be true when qpDeleteResp=", fshow(qpDeleteResp)
            )
        );

        testStateReg <= TEST_RESET_WAIT_RESET;
        $display("time=%0t:", $time, " check QP deleted");
    endrule

    rule waitResetQP if (
        testStateReg == TEST_RESET_WAIT_RESET &&
        recvSideQP.statusSQ.comm.isReset
    );
        testStateReg <= TEST_RESET_CREATE_QP;
        countDown.decr;
        $display("time=%0t:", $time, " wait QP reset");
    endrule
endmodule

typedef enum {
    TEST_QP_RESP_ERR_RESET,
    TEST_QP_TIMEOUT_ERR_RESET
} TestErrResetTypeQP deriving(Bits, Eq);

(* synthesize *)
module mkTestQueuePairRespErrResetCase(Empty);
    let errType = TEST_QP_RESP_ERR_RESET;
    let result <- mkTestQueuePairResetCase(errType);
endmodule

(* synthesize *)
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

    // WorkReq
    let illegalAtomicWorkReqPipeOut <- mkGenIllegalAtomicWorkReq;
    mkConnection(toGet(illegalAtomicWorkReqPipeOut), sendSideQP.workReqIn);

    // RecvReq
    FIFOF#(RecvReq) emptyRecvReqQ <- mkFIFOF;
    mkConnection(toGet(emptyRecvReqQ), sendSideQP.recvReqIn);

    // DMA
    // let dmaReadClt  <- mkDmaReadCltArbiter(vec(sendSideQP.dmaReadClt4RQ, sendSideQP.dmaReadClt4SQ));
    // let dmaWriteClt <- mkDmaWriteCltArbiter(vec(sendSideQP.dmaWriteClt4RQ, sendSideQP.dmaWriteClt4SQ));
    // let simDmaReadSrv  <- mkSimDmaReadSrv;
    // let simDmaWriteSrv <- mkSimDmaWriteSrv;
    // mkConnection(dmaReadClt, simDmaReadSrv);
    // mkConnection(dmaWriteClt, simDmaWriteSrv);
    Vector#(2, DmaReadClt)  dmaReadCltVec  = vec(sendSideQP.dmaReadClt4SQ, sendSideQP.dmaReadClt4RQ);
    Vector#(2, DmaWriteClt) dmaWriteCltVec = vec(sendSideQP.dmaWriteClt4SQ, sendSideQP.dmaWriteClt4RQ);
    Vector#(2, DmaReadSrv)  simDmaReadSrvVec  <- replicateM(mkSimDmaReadSrv);
    Vector#(2, DmaWriteSrv) simDmaWriteSrvVec <- replicateM(mkSimDmaWriteSrv);
    for (Integer idx = 0; idx < 2; idx = idx + 1) begin
        mkConnection(dmaReadCltVec[idx], simDmaReadSrvVec[idx]);
        mkConnection(dmaWriteCltVec[idx], simDmaWriteSrvVec[idx]);
    end

    // MR permission check
    let mrCheckPassOrFail = True;
    Vector#(2, PermCheckSrv) simPermCheckVec <- replicateM(mkSimPermCheckSrv(mrCheckPassOrFail));
    Vector#(2, PermCheckClt) permCheckCltVec = vec(
        sendSideQP.permCheckClt4RQ, sendSideQP.permCheckClt4SQ
    );
    for (Integer idx = 0; idx < 2; idx = idx + 1) begin
        mkConnection(permCheckCltVec[idx], simPermCheckVec[idx]);
    end
    // let simPermCheckSrv <- mkSimPermCheckSrv(mrCheckPassOrFail);
    // let permCheckClt <- mkPermCheckCltArbiter(vec(
    //     sendSideQP.permCheckClt4RQ, sendSideQP.permCheckClt4SQ
    // ));
    // mkConnection(permCheckClt, simPermCheckSrv);

    mkSink(sendSideQP.rdmaReqRespPipeOut);

    // Extract RDMA response metadata and payload
    if (errType != TEST_QP_TIMEOUT_ERR_RESET) begin
        let genAckType = GEN_RDMA_RESP_ACK_ERROR;
        let rdmaErrRespPipeOut <- mkGenFixedPsnRdmaRespAck(sendSideQP.statusSQ, genAckType);
        let respPktMetaDataAndPayloadPipeOut <- mkSimExtractNormalHeaderPayload(rdmaErrRespPipeOut);
        mkConnection(respPktMetaDataAndPayloadPipeOut, sendSideQP.respPktPipeIn);
        // let respPktMetaDataPipeOut = respPktMetaDataAndPayloadPipeOut.pktMetaData;
        let addRespNoPayloadRule <- addRules(genEmptyPipeOutRule(
            respPktMetaDataAndPayloadPipeOut.payload,
            "respPktMetaDataAndPayloadPipeOut.payload empty assertion @ mkTestQueuePairResetCase"
        ));
    end

    // Empty pipe check
    let addSendQNoWorkCompOutRule <- addRules(genEmptyPipeOutRule(
        sendSideQP.workCompPipeOutRQ,
        "sendSideQP.workCompPipeOutRQ empty assertion @ mkTestQueuePairResetCase"
    ));
    // let addRecvQNoWorkCompOutRule <- addRules(genEmptyPipeOutRule(
    //     sendSideQP.workCompPipeOutSQ,
    //     "sendSideQP.workCompPipeOutSQ empty assertion @ mkTestQueuePairResetCase"
    // ));

    // For controller initialization
    let qpAttrPipeOut <- mkQpAttrPipeOut;

    Reg#(TestErrResetState) testStateReg <- mkReg(TEST_RESET_CREATE_QP);
    Reg#(Bool) firstWorkReqSavedReg <- mkRegU;
    Reg#(WorkReq) firstWorkReqReg <- mkRegU;

    let countDown <- mkCountDown(valueOf(TDiv#(MAX_CMP_CNT, 50)));

    rule createQP if (testStateReg == TEST_RESET_CREATE_QP);
        immAssert(
            sendSideQP.statusSQ.comm.isReset,
            "sendSideQP state assertion @ mkTestQueuePairResetCase",
            $format(
                "sendSideQP.statusSQ.comm.isReset=", fshow(sendSideQP.statusSQ.comm.isReset),
                " should be true"
            )
        );

        let qpCreateReq = ReqQP {
            qpReqType : REQ_QP_CREATE,
            pdHandler : dontCareValue,
            qpn       : getDefaultQPN,
            qpAttrMask: dontCareValue,
            qpAttr    : dontCareValue,
            qpInitAttr: qpInitAttr
        };

        sendSideQP.srvPortQP.request.put(qpCreateReq);
        testStateReg <= TEST_RESET_INIT_QP;
        // $display("time=%0t:", $time, " create QP");
    endrule

    rule initQP if (testStateReg == TEST_RESET_INIT_QP);
        let qpCreateResp <- sendSideQP.srvPortQP.response.get;
        immAssert(
            qpCreateResp.successOrNot,
            "qpCreateResp.successOrNot assertion @ mkTestQueuePairResetCase",
            $format(
                "qpCreateResp.successOrNot=", fshow(qpCreateResp.successOrNot),
                " should be true when qpCreateResp=", fshow(qpCreateResp)
            )
        );

        let qpAttr = qpAttrPipeOut.first;
        qpAttr.qpState = IBV_QPS_INIT;
        let modifyReqQP = ReqQP {
            qpReqType : REQ_QP_MODIFY,
            pdHandler : dontCareValue,
            qpn       : getDefaultQPN,
            qpAttrMask: getReset2InitRequiredAttr,
            qpAttr    : qpAttr,
            qpInitAttr: qpInitAttr
        };
        sendSideQP.srvPortQP.request.put(modifyReqQP);

        testStateReg <= TEST_RESET_SET_QP_RTR;
        // $display("time=%0t:", $time, " init QP");
    endrule

    rule setCntrlRTR if (testStateReg == TEST_RESET_SET_QP_RTR);
        let qpInitResp <- sendSideQP.srvPortQP.response.get;
        immAssert(
            qpInitResp.successOrNot,
            "qpInitResp.successOrNot assertion @ mkTestQueuePairResetCase",
            $format(
                "qpInitResp.successOrNot=", fshow(qpInitResp.successOrNot),
                " should be true when qpInitResp=", fshow(qpInitResp)
            )
        );

        let qpAttr = qpAttrPipeOut.first;
        qpAttr.qpState = IBV_QPS_RTR;
        qpAttr.pmtu = pmtu;
        let modifyReqQP = ReqQP {
            qpReqType : REQ_QP_MODIFY,
            pdHandler : dontCareValue,
            qpn       : getDefaultQPN,
            qpAttrMask: getInit2RtrRequiredAttr,
            qpAttr    : qpAttr,
            qpInitAttr: qpInitAttr
        };
        sendSideQP.srvPortQP.request.put(modifyReqQP);

        testStateReg <= TEST_RESET_SET_QP_RTS;
        // $display("time=%0t:", $time, " set QP 2 RTR");
    endrule

    rule setCntrlRTS if (testStateReg == TEST_RESET_SET_QP_RTS);
        let qpRtrResp <- sendSideQP.srvPortQP.response.get;
        immAssert(
            qpRtrResp.successOrNot,
            "qpRtrResp.successOrNot assertion @ mkTestQueuePairResetCase",
            $format(
                "qpRtrResp.successOrNot=", fshow(qpRtrResp.successOrNot),
                " should be true when qpRtrResp=", fshow(qpRtrResp)
            )
        );

        let qpAttr = qpAttrPipeOut.first;
        qpAttr.qpState = IBV_QPS_RTS;
        let modifyReqQP = ReqQP {
            qpReqType : REQ_QP_MODIFY,
            pdHandler : dontCareValue,
            qpn       : getDefaultQPN,
            qpAttrMask: getRtr2RtsRequiredAttr,
            qpAttr    : qpAttr,
            qpInitAttr: qpInitAttr
        };
        sendSideQP.srvPortQP.request.put(modifyReqQP);

        testStateReg <= TEST_RESET_CHECK_QP_RTS;
        firstWorkReqSavedReg <= False;
        // $display("time=%0t:", $time, " set QP 2 RTS");
    endrule

    rule checkStateRTS if (
        testStateReg == TEST_RESET_CHECK_QP_RTS
    );
        let qpRtsResp <- sendSideQP.srvPortQP.response.get;
        immAssert(
            qpRtsResp.successOrNot,
            "qpRtsResp.successOrNot assertion @ mkTestQueuePairResetCase",
            $format(
                "qpRtsResp.successOrNot=", fshow(qpRtsResp.successOrNot),
                " should be true when qpRtsResp=", fshow(qpRtsResp)
            )
        );

        immAssert(
            sendSideQP.statusSQ.comm.isRTS,
            "sendSideQP.statusSQ.comm.isRTS assertion @ mkTestQueuePairResetCase",
            $format(
                "sendSideQP.statusSQ.comm.isRTS=", fshow(sendSideQP.statusSQ.comm.isRTS),
                " should be true when qpRtsResp=", fshow(qpRtsResp)
            )
        );
        // immAssert(
        //     !dut.hasRetryErr,
        //     "hasRetryErr assertion @ mkTestQueuePairResetCase",
        //     $format(
        //         "dut.hasRetryErr=", fshow(dut.hasRetryErr),
        //         " should be false"
        //     )
        // );

        testStateReg <= TEST_RESET_ERR_NOTIFY;
        // $display("time=%0t:", $time, " check QP in RTS state");
    endrule

    rule checkErrWorkComp if (
        testStateReg == TEST_RESET_ERR_NOTIFY
    );
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

        let expectedWorkCompStatus = case (errType)
            TEST_QP_RESP_ERR_RESET   : IBV_WC_REM_OP_ERR;
            TEST_QP_TIMEOUT_ERR_RESET: IBV_WC_RESP_TIMEOUT_ERR;
            default                  : IBV_WC_SUCCESS;
        endcase;

        immAssert(
            errWorkComp.status == expectedWorkCompStatus,
            "errWorkComp.status assertion @ mkTestQueuePairResetCase",
            $format(
                "errWorkComp.status=", fshow(errWorkComp.status),
                " not match expected status=", fshow(expectedWorkCompStatus)
            )
        );

        testStateReg <= TEST_RESET_DELETE_QP;
        // $display(
        //     "time=%0t: errWorkComp=", $time, fshow(errWorkComp)
        //     // " not match WR=", fshow(firstWorkReqReg)
        // );
    endrule

    rule deleteQP if (
        testStateReg == TEST_RESET_DELETE_QP
    );
        // let qpModifyResp <- sendSideQP.srvPortQP.response.get;
        // immAssert(
        //     qpModifyResp.successOrNot,
        //     "qpModifyResp.successOrNot assertion @ mkTestQueuePairResetCase",
        //     $format(
        //         "qpModifyResp.successOrNot=", fshow(qpModifyResp.successOrNot),
        //         " should be true when qpModifyResp=", fshow(qpModifyResp)
        //     )
        // );

        immAssert(
            sendSideQP.statusSQ.comm.isERR,
            "sendSideQP.statusSQ.comm.isERR assertion @ mkTestQueuePairResetCase",
            $format(
                "sendSideQP.statusSQ.comm.isERR=", fshow(sendSideQP.statusSQ.comm.isERR), " should be true"
                // " when qpModifyResp=", fshow(qpModifyResp)
            )
        );

        let qpAttr = qpAttrPipeOut.first;
        // qpAttr.qpState = IBV_QPS_UNKNOWN;
        let deleteReqQP = ReqQP {
            qpReqType   : REQ_QP_DESTROY,
            pdHandler   : dontCareValue,
            qpn         : getDefaultQPN,
            qpAttrMask  : dontCareValue,
            qpAttr      : qpAttr,
            qpInitAttr  : qpInitAttr
        };
        sendSideQP.srvPortQP.request.put(deleteReqQP);

        testStateReg <= TEST_RESET_CHECK_QP_DELETED;
        // $display("time=%0t:", $time, " delete QP");
    endrule

    rule checkDeleteQP if (
        testStateReg == TEST_RESET_CHECK_QP_DELETED
    );
        let qpDeleteResp <- sendSideQP.srvPortQP.response.get;
        immAssert(
            qpDeleteResp.successOrNot,
            "qpDeleteResp.successOrNot assertion @ mkTestQueuePairResetCase",
            $format(
                "qpDeleteResp.successOrNot=", fshow(qpDeleteResp.successOrNot),
                " should be true when qpDeleteResp=", fshow(qpDeleteResp)
            )
        );

        immAssert(
            sendSideQP.statusSQ.comm.isUnknown,
            "sendSideQP.statusSQ.comm.isUnknown assertion @ mkTestQueuePairResetCase",
            $format(
                "sendSideQP.statusSQ.comm.isUnknown=", fshow(sendSideQP.statusSQ.comm.isUnknown),
                " should be true when qpDeleteResp=", fshow(qpDeleteResp)
            )
        );

        testStateReg <= TEST_RESET_WAIT_RESET;
        // $display("time=%0t:", $time, " check QP deleted");
    endrule

    rule waitResetQP if (
        testStateReg == TEST_RESET_WAIT_RESET &&
        sendSideQP.statusSQ.comm.isReset
    );
        testStateReg <= TEST_RESET_CREATE_QP;
        countDown.decr;
        // $display("time=%0t:", $time, " wait QP reset");
    endrule
endmodule
/*
module mkTestQueuePairRespErrResetCase(Empty);
    let minPayloadLen = 1;
    let maxPayloadLen = 2048;
    let qpType = IBV_QPT_RC;
    let pmtu = IBV_MTU_256;

    let qpInitAttr = QpInitAttr {
        qpType  : qpType,
        sqSigAll: False
    };

    let sendSideQP <- mkQP;

    // WorkReq
    let illegalAtomicWorkReqPipeOut <- mkGenIllegalAtomicWorkReq;
    mkConnection(toGet(illegalAtomicWorkReqPipeOut), sendSideQP.workReqIn);

    // RecvReq
    FIFOF#(RecvReq) emptyRecvReqQ <- mkFIFOF;
    mkConnection(toGet(emptyRecvReqQ), sendSideQP.recvReqIn);

    // DMA
    // let dmaReadClt  <- mkDmaReadCltArbiter(vec(sendSideQP.dmaReadClt4RQ, sendSideQP.dmaReadClt4SQ));
    // let dmaWriteClt <- mkDmaWriteCltArbiter(vec(sendSideQP.dmaWriteClt4RQ, sendSideQP.dmaWriteClt4SQ));
    // let simDmaReadSrv  <- mkSimDmaReadSrv;
    // let simDmaWriteSrv <- mkSimDmaWriteSrv;
    // mkConnection(dmaReadClt, simDmaReadSrv);
    // mkConnection(dmaWriteClt, simDmaWriteSrv);
    Vector#(2, DmaReadClt)  dmaReadCltVec  = vec(sendSideQP.dmaReadClt4SQ, sendSideQP.dmaReadClt4RQ);
    Vector#(2, DmaWriteClt) dmaWriteCltVec = vec(sendSideQP.dmaWriteClt4SQ, sendSideQP.dmaWriteClt4RQ);
    Vector#(2, DmaReadSrv)  simDmaReadSrvVec  <- replicateM(mkSimDmaReadSrv);
    Vector#(2, DmaWriteSrv) simDmaWriteSrvVec <- replicateM(mkSimDmaWriteSrv);
    for (Integer idx = 0; idx < 2; idx = idx + 1) begin
        mkConnection(dmaReadCltVec[idx], simDmaReadSrvVec[idx]);
        mkConnection(dmaWriteCltVec[idx], simDmaWriteSrvVec[idx]);
    end

    // MR permission check
    let mrCheckPassOrFail = True;
    Vector#(2, PermCheckSrv) simPermCheckVec <- replicateM(mkSimPermCheckSrv(mrCheckPassOrFail));
    Vector#(2, PermCheckClt) permCheckCltVec = vec(
        sendSideQP.permCheckClt4RQ, sendSideQP.permCheckClt4SQ
    );
    for (Integer idx = 0; idx < 2; idx = idx + 1) begin
        mkConnection(permCheckCltVec[idx], simPermCheckVec[idx]);
    end
    // let simPermCheckSrv <- mkSimPermCheckSrv(mrCheckPassOrFail);
    // let permCheckClt <- mkPermCheckCltArbiter(vec(
    //     sendSideQP.permCheckClt4RQ, sendSideQP.permCheckClt4SQ
    // ));
    // mkConnection(permCheckClt, simPermCheckSrv);

    mkSink(sendSideQP.rdmaReqRespPipeOut);
    // Extract RDMA response metadata and payload
    let genAckType = GEN_RDMA_RESP_ACK_ERROR;
    let rdmaErrRespPipeOut <- mkGenFixedPsnRdmaRespAck(sendSideQP.statusSQ, genAckType);
    let respPktMetaDataAndPayloadPipeOut <- mkSimExtractNormalHeaderPayload(rdmaErrRespPipeOut);
    mkConnection(respPktMetaDataAndPayloadPipeOut, sendSideQP.respPktPipeIn);
    // let respPktMetaDataPipeOut = respPktMetaDataAndPayloadPipeOut.pktMetaData;
    let addRespNoPayloadRule <- addRules(genEmptyPipeOutRule(
        respPktMetaDataAndPayloadPipeOut.payload,
        "respPktMetaDataAndPayloadPipeOut.payload empty assertion @ mkTestQueuePairRespErrResetCase"
    ));

    // Empty pipe check
    let addSendQNoWorkCompOutRule <- addRules(genEmptyPipeOutRule(
        sendSideQP.workCompPipeOutRQ,
        "sendSideQP.workCompPipeOutRQ empty assertion @ mkTestQueuePairRespErrResetCase"
    ));
    // let addRecvQNoWorkCompOutRule <- addRules(genEmptyPipeOutRule(
    //     sendSideQP.workCompPipeOutSQ,
    //     "sendSideQP.workCompPipeOutSQ empty assertion @ mkTestQueuePairRespErrResetCase"
    // ));

    // For controller initialization
    let qpAttrPipeOut <- mkQpAttrPipeOut;

    Reg#(TestErrResetState) testStateReg <- mkReg(TEST_RESET_CREATE_QP);
    Reg#(Bool) firstWorkReqSavedReg <- mkRegU;
    Reg#(WorkReq) firstWorkReqReg <- mkRegU;

    let countDown <- mkCountDown(valueOf(TDiv#(MAX_CMP_CNT, 50)));

    rule createQP if (testStateReg == TEST_RESET_CREATE_QP);
        immAssert(
            sendSideQP.statusSQ.comm.isReset,
            "sendSideQP state assertion @ mkTestQueuePairRespErrResetCase",
            $format(
                "sendSideQP.statusSQ.comm.isReset=", fshow(sendSideQP.statusSQ.comm.isReset),
                " should be true"
            )
        );

        let qpCreateReq = ReqQP {
            qpReqType : REQ_QP_CREATE,
            pdHandler : dontCareValue,
            qpn       : getDefaultQPN,
            qpAttrMask: dontCareValue,
            qpAttr    : dontCareValue,
            qpInitAttr: qpInitAttr
        };

        sendSideQP.srvPortQP.request.put(qpCreateReq);
        testStateReg <= TEST_RESET_INIT_QP;
        // $display("time=%0t:", $time, " create QP");
    endrule

    rule initQP if (testStateReg == TEST_RESET_INIT_QP);
        let qpCreateResp <- sendSideQP.srvPortQP.response.get;
        immAssert(
            qpCreateResp.successOrNot,
            "qpCreateResp.successOrNot assertion @ mkTestQueuePairRespErrResetCase",
            $format(
                "qpCreateResp.successOrNot=", fshow(qpCreateResp.successOrNot),
                " should be true when qpCreateResp=", fshow(qpCreateResp)
            )
        );

        let qpAttr = qpAttrPipeOut.first;
        qpAttr.qpState = IBV_QPS_INIT;
        let modifyReqQP = ReqQP {
            qpReqType : REQ_QP_MODIFY,
            pdHandler : dontCareValue,
            qpn       : getDefaultQPN,
            qpAttrMask: getReset2InitRequiredAttr,
            qpAttr    : qpAttr,
            qpInitAttr: qpInitAttr
        };
        sendSideQP.srvPortQP.request.put(modifyReqQP);

        testStateReg <= TEST_RESET_SET_QP_RTR;
        // $display("time=%0t:", $time, " init QP");
    endrule

    rule setCntrlRTR if (testStateReg == TEST_RESET_SET_QP_RTR);
        let qpInitResp <- sendSideQP.srvPortQP.response.get;
        immAssert(
            qpInitResp.successOrNot,
            "qpInitResp.successOrNot assertion @ mkTestQueuePairRespErrResetCase",
            $format(
                "qpInitResp.successOrNot=", fshow(qpInitResp.successOrNot),
                " should be true when qpInitResp=", fshow(qpInitResp)
            )
        );

        let qpAttr = qpAttrPipeOut.first;
        qpAttr.qpState = IBV_QPS_RTR;
        qpAttr.pmtu = pmtu;
        let modifyReqQP = ReqQP {
            qpReqType : REQ_QP_MODIFY,
            pdHandler : dontCareValue,
            qpn       : getDefaultQPN,
            qpAttrMask: getInit2RtrRequiredAttr,
            qpAttr    : qpAttr,
            qpInitAttr: qpInitAttr
        };
        sendSideQP.srvPortQP.request.put(modifyReqQP);

        testStateReg <= TEST_RESET_SET_QP_RTS;
        // $display("time=%0t:", $time, " set QP 2 RTR");
    endrule

    rule setCntrlRTS if (testStateReg == TEST_RESET_SET_QP_RTS);
        let qpRtrResp <- sendSideQP.srvPortQP.response.get;
        immAssert(
            qpRtrResp.successOrNot,
            "qpRtrResp.successOrNot assertion @ mkTestQueuePairRespErrResetCase",
            $format(
                "qpRtrResp.successOrNot=", fshow(qpRtrResp.successOrNot),
                " should be true when qpRtrResp=", fshow(qpRtrResp)
            )
        );

        let qpAttr = qpAttrPipeOut.first;
        qpAttr.qpState = IBV_QPS_RTS;
        let modifyReqQP = ReqQP {
            qpReqType : REQ_QP_MODIFY,
            pdHandler : dontCareValue,
            qpn       : getDefaultQPN,
            qpAttrMask: getRtr2RtsRequiredAttr,
            qpAttr    : qpAttr,
            qpInitAttr: qpInitAttr
        };
        sendSideQP.srvPortQP.request.put(modifyReqQP);

        testStateReg <= TEST_RESET_CHECK_QP_RTS;
        firstWorkReqSavedReg <= False;
        // $display("time=%0t:", $time, " set QP 2 RTS");
    endrule

    rule checkStateRTS if (
        testStateReg == TEST_RESET_CHECK_QP_RTS
    );
        let qpRtsResp <- sendSideQP.srvPortQP.response.get;
        immAssert(
            qpRtsResp.successOrNot,
            "qpRtsResp.successOrNot assertion @ mkTestQueuePairRespErrResetCase",
            $format(
                "qpRtsResp.successOrNot=", fshow(qpRtsResp.successOrNot),
                " should be true when qpRtsResp=", fshow(qpRtsResp)
            )
        );

        immAssert(
            sendSideQP.statusSQ.comm.isRTS,
            "sendSideQP.statusSQ.comm.isRTS assertion @ mkTestQueuePairRespErrResetCase",
            $format(
                "sendSideQP.statusSQ.comm.isRTS=", fshow(sendSideQP.statusSQ.comm.isRTS),
                " should be true when qpRtsResp=", fshow(qpRtsResp)
            )
        );
        // immAssert(
        //     !dut.hasRetryErr,
        //     "hasRetryErr assertion @ mkTestQueuePairRespErrResetCase",
        //     $format(
        //         "dut.hasRetryErr=", fshow(dut.hasRetryErr),
        //         " should be false"
        //     )
        // );

        testStateReg <= TEST_RESET_ERR_NOTIFY;
        // $display("time=%0t:", $time, " check QP in RTS state");
    endrule

    rule checkRespErrWC if (
        testStateReg == TEST_RESET_ERR_NOTIFY
    );
        let respErrWC = sendSideQP.workCompPipeOutSQ.first;
        sendSideQP.workCompPipeOutSQ.deq;

        // immAssert(
        //     workCompMatchWorkReqInSQ(timeOutErrWC, firstWorkReqReg),
        //     "workCompMatchWorkReqInSQ assertion @ mkTestQueuePairRespErrResetCase",
        //     $format(
        //         "timeOutErrWC=", fshow(timeOutErrWC),
        //         " not match WR=", fshow(firstWorkReqReg)
        //     )
        // );

        let expectedWorkCompStatus = IBV_WC_REM_OP_ERR;
        immAssert(
            respErrWC.status == expectedWorkCompStatus,
            "workCompSQ.status assertion @ mkTestQueuePairTimeOutErrCase",
            $format(
                "respErrWC.status=", fshow(respErrWC.status),
                " not match expected status=", fshow(expectedWorkCompStatus)
            )
        );

        testStateReg <= TEST_RESET_DELETE_QP;
        $display(
            "time=%0t: respErrWC=", $time, fshow(respErrWC)
            // " not match WR=", fshow(firstWorkReqReg)
        );
    endrule

    rule deleteQP if (
        testStateReg == TEST_RESET_DELETE_QP
    );
        // let qpModifyResp <- sendSideQP.srvPortQP.response.get;
        // immAssert(
        //     qpModifyResp.successOrNot,
        //     "qpModifyResp.successOrNot assertion @ mkTestQueuePairRespErrResetCase",
        //     $format(
        //         "qpModifyResp.successOrNot=", fshow(qpModifyResp.successOrNot),
        //         " should be true when qpModifyResp=", fshow(qpModifyResp)
        //     )
        // );

        immAssert(
            sendSideQP.statusSQ.comm.isERR,
            "sendSideQP.statusSQ.comm.isERR assertion @ mkTestQueuePairRespErrResetCase",
            $format(
                "sendSideQP.statusSQ.comm.isERR=", fshow(sendSideQP.statusSQ.comm.isERR), " should be true"
                // " when qpModifyResp=", fshow(qpModifyResp)
            )
        );

        let qpAttr = qpAttrPipeOut.first;
        // qpAttr.qpState = IBV_QPS_UNKNOWN;
        let deleteReqQP = ReqQP {
            qpReqType   : REQ_QP_DESTROY,
            pdHandler   : dontCareValue,
            qpn         : getDefaultQPN,
            qpAttrMask  : dontCareValue,
            qpAttr      : qpAttr,
            qpInitAttr  : qpInitAttr
        };
        sendSideQP.srvPortQP.request.put(deleteReqQP);

        testStateReg <= TEST_RESET_CHECK_QP_DELETED;
        $display("time=%0t:", $time, " delete QP");
    endrule

    rule checkDeleteQP if (
        testStateReg == TEST_RESET_CHECK_QP_DELETED
    );
        let qpDeleteResp <- sendSideQP.srvPortQP.response.get;
        immAssert(
            qpDeleteResp.successOrNot,
            "qpDeleteResp.successOrNot assertion @ mkTestQueuePairRespErrResetCase",
            $format(
                "qpDeleteResp.successOrNot=", fshow(qpDeleteResp.successOrNot),
                " should be true when qpDeleteResp=", fshow(qpDeleteResp)
            )
        );

        immAssert(
            sendSideQP.statusSQ.comm.isUnknown,
            "sendSideQP.statusSQ.comm.isUnknown assertion @ mkTestQueuePairRespErrResetCase",
            $format(
                "sendSideQP.statusSQ.comm.isUnknown=", fshow(sendSideQP.statusSQ.comm.isUnknown),
                " should be true when qpDeleteResp=", fshow(qpDeleteResp)
            )
        );

        testStateReg <= TEST_RESET_WAIT_RESET;
        $display("time=%0t:", $time, " check QP deleted");
    endrule

    rule waitResetQP if (
        testStateReg == TEST_RESET_WAIT_RESET &&
        sendSideQP.statusSQ.comm.isReset
    );
        testStateReg <= TEST_RESET_CREATE_QP;
        countDown.decr;
        $display("time=%0t:", $time, " wait QP reset");
    endrule
endmodule

module mkTestQueuePairTimeOutErrResetCase(Empty);
    let minPayloadLen = 1;
    let maxPayloadLen = 2048;
    let qpType = IBV_QPT_RC;
    let pmtu = IBV_MTU_256;

    let qpInitAttr = QpInitAttr {
        qpType  : qpType,
        sqSigAll: False
    };

    let sendSideQP <- mkQP;

    // // Set QP to RTS
    // let setExpectedPsnAsNextPSN = True;
    // let setZero2ExpectedPsnAndNextPSN = True;
    // let setSendQ2RTS <- mkChange2CntrlStateRTS(
    //     sendSideQP.srvPortQP, qpType, pmtu,
    //     setExpectedPsnAsNextPSN, setZero2ExpectedPsnAndNextPSN
    // );

    // WorkReq
    Vector#(1, PipeOut#(WorkReq)) workReqPipeOutVec <-
        mkRandomWorkReq(minPayloadLen, maxPayloadLen);
    let workReqPipeOut = workReqPipeOutVec[0];
    // FIFOF#(WorkReq) workReqQ <- mkFIFOF;
    // mkConnection(toGet(workReqQ), sendSideQP.workReqIn);
    // let workReqPipeOut4Ref <- mkBufferN(valueOf(MAX_QP_WR), workReqPipeOutVec[1]);
    mkConnection(toGet(workReqPipeOut), sendSideQP.workReqIn);

    // RecvReq
    FIFOF#(RecvReq) emptyRecvReqQ <- mkFIFOF;
    mkConnection(toGet(emptyRecvReqQ), sendSideQP.recvReqIn);

    // DMA
    // let dmaReadClt  <- mkDmaReadCltArbiter(vec(sendSideQP.dmaReadClt4RQ, sendSideQP.dmaReadClt4SQ));
    // let dmaWriteClt <- mkDmaWriteCltArbiter(vec(sendSideQP.dmaWriteClt4RQ, sendSideQP.dmaWriteClt4SQ));
    // let simDmaReadSrv  <- mkSimDmaReadSrv;
    // let simDmaWriteSrv <- mkSimDmaWriteSrv;
    // mkConnection(dmaReadClt, simDmaReadSrv);
    // mkConnection(dmaWriteClt, simDmaWriteSrv);
    Vector#(2, DmaReadClt)  dmaReadCltVec  = vec(sendSideQP.dmaReadClt4SQ, sendSideQP.dmaReadClt4RQ);
    Vector#(2, DmaWriteClt) dmaWriteCltVec = vec(sendSideQP.dmaWriteClt4SQ, sendSideQP.dmaWriteClt4RQ);
    Vector#(2, DmaReadSrv)  simDmaReadSrvVec  <- replicateM(mkSimDmaReadSrv);
    Vector#(2, DmaWriteSrv) simDmaWriteSrvVec <- replicateM(mkSimDmaWriteSrv);
    for (Integer idx = 0; idx < 2; idx = idx + 1) begin
        mkConnection(dmaReadCltVec[idx], simDmaReadSrvVec[idx]);
        mkConnection(dmaWriteCltVec[idx], simDmaWriteSrvVec[idx]);
    end

    // MR permission check
    let mrCheckPassOrFail = True;
    Vector#(2, PermCheckSrv) simPermCheckVec <- replicateM(mkSimPermCheckSrv(mrCheckPassOrFail));
    Vector#(2, PermCheckClt) permCheckCltVec = vec(
        sendSideQP.permCheckClt4RQ, sendSideQP.permCheckClt4SQ
    );
    for (Integer idx = 0; idx < 2; idx = idx + 1) begin
        mkConnection(permCheckCltVec[idx], simPermCheckVec[idx]);
    end
    // let simPermCheckSrv <- mkSimPermCheckSrv(mrCheckPassOrFail);
    // let permCheckClt <- mkPermCheckCltArbiter(vec(
    //     sendSideQP.permCheckClt4RQ, sendSideQP.permCheckClt4SQ
    // ));
    // mkConnection(permCheckClt, simPermCheckSrv);

    mkSink(sendSideQP.rdmaReqRespPipeOut);
    // // Extract RDMA request metadata and payload
    // let reqPktMetaDataAndPayloadPipeOut <- mkSimExtractNormalHeaderPayload(sendSideQP.rdmaReqRespPipeOut);
    // let reqPayloadSink <- mkSink(reqPktMetaDataAndPayloadPipeOut.payload);
    // let reqPktMetaDataPipeOut = reqPktMetaDataAndPayloadPipeOut.pktMetaData;
    // let reqPktMetaDataSink <- mkSink(reqPktMetaDataPipeOut);

    // Empty pipe check
    let addSendQNoWorkCompOutRule <- addRules(genEmptyPipeOutRule(
        sendSideQP.workCompPipeOutRQ,
        "sendSideQP.workCompPipeOutRQ empty assertion @ mkTestQueuePairTimeOutCase"
    ));
    // let addRecvQNoWorkCompOutRule <- addRules(genEmptyPipeOutRule(
    //     sendSideQP.workCompPipeOutSQ,
    //     "sendSideQP.workCompPipeOutSQ empty assertion @ mkTestQueuePairTimeOutCase"
    // ));

    // For controller initialization
    let qpAttrPipeOut <- mkQpAttrPipeOut;

    Reg#(TestErrResetState) testStateReg <- mkReg(TEST_RESET_CREATE_QP);
    Reg#(Bool) firstWorkReqSavedReg <- mkRegU;
    Reg#(WorkReq) firstWorkReqReg <- mkRegU;

    let countDown <- mkCountDown(valueOf(TDiv#(MAX_CMP_CNT, 50)));

    rule createQP if (testStateReg == TEST_RESET_CREATE_QP);
        immAssert(
            sendSideQP.statusSQ.comm.isReset,
            "sendSideQP state assertion @ mkTestQueuePairTimeOutErrResetCase",
            $format(
                "sendSideQP.statusSQ.comm.isReset=", fshow(sendSideQP.statusSQ.comm.isReset),
                " should be true"
            )
        );

        let qpCreateReq = ReqQP {
            qpReqType : REQ_QP_CREATE,
            pdHandler : dontCareValue,
            qpn       : getDefaultQPN,
            qpAttrMask: dontCareValue,
            qpAttr    : dontCareValue,
            qpInitAttr: qpInitAttr
        };

        sendSideQP.srvPortQP.request.put(qpCreateReq);
        testStateReg <= TEST_RESET_INIT_QP;
        // $display("time=%0t:", $time, " create QP");
    endrule

    rule initQP if (testStateReg == TEST_RESET_INIT_QP);
        let qpCreateResp <- sendSideQP.srvPortQP.response.get;
        immAssert(
            qpCreateResp.successOrNot,
            "qpCreateResp.successOrNot assertion @ mkTestQueuePairTimeOutErrResetCase",
            $format(
                "qpCreateResp.successOrNot=", fshow(qpCreateResp.successOrNot),
                " should be true when qpCreateResp=", fshow(qpCreateResp)
            )
        );

        let qpAttr = qpAttrPipeOut.first;
        qpAttr.qpState = IBV_QPS_INIT;
        let modifyReqQP = ReqQP {
            qpReqType : REQ_QP_MODIFY,
            pdHandler : dontCareValue,
            qpn       : getDefaultQPN,
            qpAttrMask: getReset2InitRequiredAttr,
            qpAttr    : qpAttr,
            qpInitAttr: qpInitAttr
        };
        sendSideQP.srvPortQP.request.put(modifyReqQP);

        testStateReg <= TEST_RESET_SET_QP_RTR;
        // $display("time=%0t:", $time, " init QP");
    endrule

    rule setCntrlRTR if (testStateReg == TEST_RESET_SET_QP_RTR);
        let qpInitResp <- sendSideQP.srvPortQP.response.get;
        immAssert(
            qpInitResp.successOrNot,
            "qpInitResp.successOrNot assertion @ mkTestQueuePairTimeOutErrResetCase",
            $format(
                "qpInitResp.successOrNot=", fshow(qpInitResp.successOrNot),
                " should be true when qpInitResp=", fshow(qpInitResp)
            )
        );

        let qpAttr = qpAttrPipeOut.first;
        qpAttr.qpState = IBV_QPS_RTR;
        qpAttr.pmtu = pmtu;
        let modifyReqQP = ReqQP {
            qpReqType : REQ_QP_MODIFY,
            pdHandler : dontCareValue,
            qpn       : getDefaultQPN,
            qpAttrMask: getInit2RtrRequiredAttr,
            qpAttr    : qpAttr,
            qpInitAttr: qpInitAttr
        };
        sendSideQP.srvPortQP.request.put(modifyReqQP);

        testStateReg <= TEST_RESET_SET_QP_RTS;
        // $display("time=%0t:", $time, " set QP 2 RTR");
    endrule

    rule setCntrlRTS if (testStateReg == TEST_RESET_SET_QP_RTS);
        let qpRtrResp <- sendSideQP.srvPortQP.response.get;
        immAssert(
            qpRtrResp.successOrNot,
            "qpRtrResp.successOrNot assertion @ mkTestQueuePairTimeOutErrResetCase",
            $format(
                "qpRtrResp.successOrNot=", fshow(qpRtrResp.successOrNot),
                " should be true when qpRtrResp=", fshow(qpRtrResp)
            )
        );

        let qpAttr = qpAttrPipeOut.first;
        qpAttr.qpState = IBV_QPS_RTS;
        let modifyReqQP = ReqQP {
            qpReqType : REQ_QP_MODIFY,
            pdHandler : dontCareValue,
            qpn       : getDefaultQPN,
            qpAttrMask: getRtr2RtsRequiredAttr,
            qpAttr    : qpAttr,
            qpInitAttr: qpInitAttr
        };
        sendSideQP.srvPortQP.request.put(modifyReqQP);

        testStateReg <= TEST_RESET_CHECK_QP_RTS;
        firstWorkReqSavedReg <= False;
        // $display("time=%0t:", $time, " set QP 2 RTS");
    endrule

    rule checkStateRTS if (
        testStateReg == TEST_RESET_CHECK_QP_RTS
    );
        let qpRtsResp <- sendSideQP.srvPortQP.response.get;
        immAssert(
            qpRtsResp.successOrNot,
            "qpRtsResp.successOrNot assertion @ mkTestQueuePairTimeOutErrResetCase",
            $format(
                "qpRtsResp.successOrNot=", fshow(qpRtsResp.successOrNot),
                " should be true when qpRtsResp=", fshow(qpRtsResp)
            )
        );

        immAssert(
            sendSideQP.statusSQ.comm.isRTS,
            "sendSideQP.statusSQ.comm.isRTS assertion @ mkTestQueuePairTimeOutErrResetCase",
            $format(
                "sendSideQP.statusSQ.comm.isRTS=", fshow(sendSideQP.statusSQ.comm.isRTS),
                " should be true when qpRtsResp=", fshow(qpRtsResp)
            )
        );
        // immAssert(
        //     !dut.hasRetryErr,
        //     "hasRetryErr assertion @ mkTestQueuePairTimeOutErrResetCase",
        //     $format(
        //         "dut.hasRetryErr=", fshow(dut.hasRetryErr),
        //         " should be false"
        //     )
        // );

        testStateReg <= TEST_RESET_ERR_NOTIFY;
        // $display("time=%0t:", $time, " check QP in RTS state");
    endrule

    rule checkTimeOutErrWC if (
        // firstWorkReqSavedReg &&
        testStateReg == TEST_RESET_ERR_NOTIFY
    );
        let timeOutErrWC = sendSideQP.workCompPipeOutSQ.first;
        sendSideQP.workCompPipeOutSQ.deq;

        // immAssert(
        //     workCompMatchWorkReqInSQ(timeOutErrWC, firstWorkReqReg),
        //     "workCompMatchWorkReqInSQ assertion @ mkTestQueuePairTimeOutErrCase",
        //     $format(
        //         "timeOutErrWC=", fshow(timeOutErrWC),
        //         " not match WR=", fshow(firstWorkReqReg)
        //     )
        // );

        let expectedWorkCompStatus = IBV_WC_RESP_TIMEOUT_ERR;
        immAssert(
            timeOutErrWC.status == expectedWorkCompStatus,
            "workCompSQ.status assertion @ mkTestQueuePairTimeOutErrCase",
            $format(
                "timeOutErrWC.status=", fshow(timeOutErrWC.status),
                " not match expected status=", fshow(expectedWorkCompStatus)
            )
        );

        testStateReg <= TEST_RESET_DELETE_QP;
        // $display(
        //     "time=%0t: timeOutErrWC=", $time, fshow(timeOutErrWC)
        //     // " not match WR=", fshow(firstWorkReqReg)
        // );
    endrule

    rule deleteQP if (
        testStateReg == TEST_RESET_DELETE_QP
    );
        // let qpModifyResp <- sendSideQP.srvPortQP.response.get;
        // immAssert(
        //     qpModifyResp.successOrNot,
        //     "qpModifyResp.successOrNot assertion @ mkTestQueuePairTimeOutErrResetCase",
        //     $format(
        //         "qpModifyResp.successOrNot=", fshow(qpModifyResp.successOrNot),
        //         " should be true when qpModifyResp=", fshow(qpModifyResp)
        //     )
        // );

        immAssert(
            sendSideQP.statusSQ.comm.isERR,
            "sendSideQP.statusSQ.comm.isERR assertion @ mkTestQueuePairTimeOutErrResetCase",
            $format(
                "sendSideQP.statusSQ.comm.isERR=", fshow(sendSideQP.statusSQ.comm.isERR), " should be true"
                // " when qpModifyResp=", fshow(qpModifyResp)
            )
        );

        let qpAttr = qpAttrPipeOut.first;
        // qpAttr.qpState = IBV_QPS_UNKNOWN;
        let deleteReqQP = ReqQP {
            qpReqType   : REQ_QP_DESTROY,
            pdHandler   : dontCareValue,
            qpn         : getDefaultQPN,
            qpAttrMask  : dontCareValue,
            qpAttr      : qpAttr,
            qpInitAttr  : qpInitAttr
        };
        sendSideQP.srvPortQP.request.put(deleteReqQP);

        testStateReg <= TEST_RESET_CHECK_QP_DELETED;
        // $display("time=%0t:", $time, " delete QP");
    endrule

    rule checkDeleteQP if (
        testStateReg == TEST_RESET_CHECK_QP_DELETED
    );
        let qpDeleteResp <- sendSideQP.srvPortQP.response.get;
        immAssert(
            qpDeleteResp.successOrNot,
            "qpDeleteResp.successOrNot assertion @ mkTestQueuePairTimeOutErrResetCase",
            $format(
                "qpDeleteResp.successOrNot=", fshow(qpDeleteResp.successOrNot),
                " should be true when qpDeleteResp=", fshow(qpDeleteResp)
            )
        );

        immAssert(
            sendSideQP.statusSQ.comm.isUnknown,
            "sendSideQP.statusSQ.comm.isUnknown assertion @ mkTestQueuePairTimeOutErrResetCase",
            $format(
                "sendSideQP.statusSQ.comm.isUnknown=", fshow(sendSideQP.statusSQ.comm.isUnknown),
                " should be true when qpDeleteResp=", fshow(qpDeleteResp)
            )
        );

        testStateReg <= TEST_RESET_WAIT_RESET;
        // $display("time=%0t:", $time, " check QP deleted");
    endrule

    rule waitResetQP if (
        testStateReg == TEST_RESET_WAIT_RESET &&
        sendSideQP.statusSQ.comm.isReset
    );
        testStateReg <= TEST_RESET_CREATE_QP;
        countDown.decr;
        // $display("time=%0t:", $time, " wait QP reset");
    endrule
endmodule
*/
(* synthesize *)
module mkTestQueuePairTimeOutErrCase(Empty);
    let minPayloadLen = 1;
    let maxPayloadLen = 2048;
    let qpType = IBV_QPT_RC;
    let pmtu = IBV_MTU_256;

    let sendSideQP <- mkQP;

    // Set QP to RTS
    let setExpectedPsnAsNextPSN = True;
    let setZero2ExpectedPsnAndNextPSN = True;
    let setSendQ2RTS <- mkChange2CntrlStateRTS(
        sendSideQP.srvPortQP, qpType, pmtu,
        setExpectedPsnAsNextPSN, setZero2ExpectedPsnAndNextPSN
    );

    // WorkReq
    Vector#(2, PipeOut#(WorkReq)) workReqPipeOutVec <-
        mkRandomWorkReq(minPayloadLen, maxPayloadLen);
    let workReqPipeOut = workReqPipeOutVec[0];
    let workReqPipeOut4Ref <- mkBufferN(valueOf(MAX_QP_WR), workReqPipeOutVec[1]);
    mkConnection(toGet(workReqPipeOut), sendSideQP.workReqIn);

    // RecvReq
    FIFOF#(RecvReq) emptyRecvReqQ <- mkFIFOF;
    mkConnection(toGet(emptyRecvReqQ), sendSideQP.recvReqIn);

    // DMA
    // let dmaReadClt  <- mkDmaReadCltArbiter(vec(sendSideQP.dmaReadClt4RQ, sendSideQP.dmaReadClt4SQ));
    // let dmaWriteClt <- mkDmaWriteCltArbiter(vec(sendSideQP.dmaWriteClt4RQ, sendSideQP.dmaWriteClt4SQ));
    // let simDmaReadSrv  <- mkSimDmaReadSrv;
    // let simDmaWriteSrv <- mkSimDmaWriteSrv;
    // mkConnection(dmaReadClt, simDmaReadSrv);
    // mkConnection(dmaWriteClt, simDmaWriteSrv);
    Vector#(2, DmaReadClt)  dmaReadCltVec  = vec(sendSideQP.dmaReadClt4SQ, sendSideQP.dmaReadClt4RQ);
    Vector#(2, DmaWriteClt) dmaWriteCltVec = vec(sendSideQP.dmaWriteClt4SQ, sendSideQP.dmaWriteClt4RQ);
    Vector#(2, DmaReadSrv)  simDmaReadSrvVec  <- replicateM(mkSimDmaReadSrv);
    Vector#(2, DmaWriteSrv) simDmaWriteSrvVec <- replicateM(mkSimDmaWriteSrv);
    for (Integer idx = 0; idx < 2; idx = idx + 1) begin
        mkConnection(dmaReadCltVec[idx], simDmaReadSrvVec[idx]);
        mkConnection(dmaWriteCltVec[idx], simDmaWriteSrvVec[idx]);
    end

    // MR permission check
    let mrCheckPassOrFail = True;
    let simPermCheckSrv <- mkSimPermCheckSrv(mrCheckPassOrFail);
    let permCheckClt <- mkPermCheckCltArbiter(vec(
        sendSideQP.permCheckClt4RQ, sendSideQP.permCheckClt4SQ
    ));
    mkConnection(permCheckClt, simPermCheckSrv);

    // Extract RDMA request metadata and payload
    let reqPktMetaDataAndPayloadPipeOut <- mkSimExtractNormalHeaderPayload(sendSideQP.rdmaReqRespPipeOut);
    let reqPayloadSink <- mkSink(reqPktMetaDataAndPayloadPipeOut.payload);
    let reqPktMetaDataPipeOut = reqPktMetaDataAndPayloadPipeOut.pktMetaData;
    let reqPktMetaDataSink <- mkSink(reqPktMetaDataPipeOut);

    // Empty pipe check
    let addSendQNoWorkCompOutRule <- addRules(genEmptyPipeOutRule(
        sendSideQP.workCompPipeOutRQ,
        "sendSideQP.workCompPipeOutRQ empty assertion @ mkTestQueuePairTimeOutCase"
    ));
    // let addRecvQNoWorkCompOutRule <- addRules(genEmptyPipeOutRule(
    //     sendSideQP.workCompPipeOutSQ,
    //     "sendSideQP.workCompPipeOutSQ empty assertion @ mkTestQueuePairTimeOutCase"
    // ));

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

(* synthesize *)
module mkTestQueuePairNormalCase(Empty);
    let minPayloadLen = 1;
    let maxPayloadLen = 2048;
    let qpType = IBV_QPT_RC;
    let pmtu = IBV_MTU_256;

    let sendSideQP <- mkQP;
    let recvSideQP <- mkQP;

    // Set QP to RTS
    let setExpectedPsnAsNextPSN = True;
    let setZero2ExpectedPsnAndNextPSN = True;
    let setSendQ2RTS <- mkChange2CntrlStateRTS(
        sendSideQP.srvPortQP, qpType, pmtu,
        setExpectedPsnAsNextPSN, setZero2ExpectedPsnAndNextPSN
    );
    let setRecvQ2RTS <- mkChange2CntrlStateRTS(
        recvSideQP.srvPortQP, qpType, pmtu,
        setExpectedPsnAsNextPSN, setZero2ExpectedPsnAndNextPSN
    );

    // WorkReq
    Vector#(2, PipeOut#(WorkReq)) workReqPipeOutVec <-
        mkRandomWorkReq(minPayloadLen, maxPayloadLen);
    let workReqPipeOut = workReqPipeOutVec[0];
    let workReqPipeOut4Ref <- mkBufferN(8, workReqPipeOutVec[1]);
    mkConnection(toGet(workReqPipeOut), sendSideQP.workReqIn);
    FIFOF#(WorkReq) emptyWorkReqQ <- mkFIFOF;
    mkConnection(toGet(emptyWorkReqQ), recvSideQP.workReqIn);

    // RecvReq
    Vector#(2, PipeOut#(RecvReq)) recvReqBufVec <- mkSimGenRecvReq;
    let recvReqPipeOut = recvReqBufVec[0];
    let recvReqPipeOut4Ref <- mkBufferN(valueOf(MAX_QP_WR), recvReqBufVec[1]);
    mkConnection(toGet(recvReqPipeOut), recvSideQP.recvReqIn);
    FIFOF#(RecvReq) emptyRecvReqQ <- mkFIFOF;
    mkConnection(toGet(emptyRecvReqQ), sendSideQP.recvReqIn);

    // DMA
    // let dmaReadClt  <- mkDmaReadCltArbiter(vec(sendSideQP.dmaReadClt, recvSideQP.dmaReadClt));
    // let dmaWriteClt <- mkDmaWriteCltArbiter(vec(sendSideQP.dmaWriteClt, recvSideQP.dmaWriteClt));
    // let dmaReadClt  <- mkDmaReadCltArbiter(vec(sendSideQP.dmaReadClt4SQ, sendSideQP.dmaReadClt4RQ, recvSideQP.dmaReadClt4RQ, recvSideQP.dmaReadClt4SQ));
    // let dmaWriteClt <- mkDmaWriteCltArbiter(vec(sendSideQP.dmaWriteClt4SQ, sendSideQP.dmaWriteClt4RQ, recvSideQP.dmaWriteClt4RQ, recvSideQP.dmaWriteClt4SQ));
    // let simDmaReadSrv  <- mkSimDmaReadSrv;
    // let simDmaWriteSrv <- mkSimDmaWriteSrv;
    // mkConnection(dmaReadClt, simDmaReadSrv);
    // mkConnection(dmaWriteClt, simDmaWriteSrv);
    Vector#(4, DmaReadClt)  dmaReadCltVec  = vec(sendSideQP.dmaReadClt4SQ, sendSideQP.dmaReadClt4RQ, recvSideQP.dmaReadClt4SQ, recvSideQP.dmaReadClt4RQ);
    Vector#(4, DmaWriteClt) dmaWriteCltVec = vec(sendSideQP.dmaWriteClt4SQ, sendSideQP.dmaWriteClt4RQ, recvSideQP.dmaWriteClt4SQ, recvSideQP.dmaWriteClt4RQ);
    Vector#(4, DmaReadSrv)  simDmaReadSrvVec  <- replicateM(mkSimDmaReadSrv);
    Vector#(4, DmaWriteSrv) simDmaWriteSrvVec <- replicateM(mkSimDmaWriteSrv);
    for (Integer idx = 0; idx < 4; idx = idx + 1) begin
        mkConnection(dmaReadCltVec[idx], simDmaReadSrvVec[idx]);
        mkConnection(dmaWriteCltVec[idx], simDmaWriteSrvVec[idx]);
    end

    // MR permission check
    let mrCheckPassOrFail = True;
    // let simPermCheckSrv <- mkSimPermCheckSrv(mrCheckPassOrFail);
    // let permCheckClt <- mkPermCheckCltArbiter(vec(
    //     sendSideQP.permCheckClt4RQ, sendSideQP.permCheckClt4SQ, recvSideQP.permCheckClt4RQ, recvSideQP.permCheckClt4SQ
    // ));
    // mkConnection(permCheckClt, simPermCheckSrv);
    Vector#(4, PermCheckSrv) simPermCheckVec <- replicateM(mkSimPermCheckSrv(mrCheckPassOrFail));
    Vector#(4, PermCheckClt) permCheckCltVec = vec(
        sendSideQP.permCheckClt4RQ, sendSideQP.permCheckClt4SQ, recvSideQP.permCheckClt4RQ, recvSideQP.permCheckClt4SQ
    );
    for (Integer idx = 0; idx < 4; idx = idx + 1) begin
        mkConnection(permCheckCltVec[idx], simPermCheckVec[idx]);
    end

    let reqPktMetaDataAndPayloadPipeOut  <- mkSimExtractNormalHeaderPayload(sendSideQP.rdmaReqRespPipeOut);
    let respPktMetaDataAndPayloadPipeOut <- mkSimExtractNormalHeaderPayload(recvSideQP.rdmaReqRespPipeOut);

    // // Build RdmaPktMetaData and payload DataStream for requests
    // let spMetaData <- mkSimMetaData4SinigleQP(qpType, pmtu);
    // let isRespPkt4SQ = False;
    // let reqPktMetaDataAndPayloadPipeOut <- mkSimInputPktBuf4SingleQP(
    //     isRespPkt4SQ, sendSideQP.rdmaReqRespPipeOut, spMetaData
    // );
    // // Build RdmaPktMetaData and payload DataStream for responses
    // let rpMetaData <- mkSimMetaData4SinigleQP(qpType, pmtu);
    // let isRespPkt2SQ = True;
    // let respPktMetaDataAndPayloadPipeOut <- mkSimInputPktBuf4SingleQP(
    //     isRespPkt2SQ, recvSideQP.rdmaReqRespPipeOut, rpMetaData
    // );
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
