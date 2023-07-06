import BuildVector :: *;
import ClientServer :: *;
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
import SimExtractRdmaHeaderPayload :: *;
import Utils :: *;
import Utils4Test :: *;

typedef enum {
    TEST_TIMEOUT_CREATE_QP,
    TEST_TIMEOUT_INIT_QP,
    TEST_TIMEOUT_SET_QP_RTR,
    TEST_TIMEOUT_SET_QP_RTS,
    TEST_TIMEOUT_CHECK_QP_RTS,
    TEST_TIMEOUT_ERR_NOTIFY,
    TEST_TIMEOUT_DELETE_QP,
    TEST_TIMEOUT_CHECK_QP_DELETED,
    TEST_TIMEOUT_WAIT_RESET
} TestTimeOutErrState deriving(Bits, Eq, FShow);

(* synthesize *)
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
    // let dmaReadClt  <- mkDmaReadCltAribter(vec(sendSideQP.dmaReadClt4RQ, sendSideQP.dmaReadClt4SQ));
    // let dmaWriteClt <- mkDmaWriteCltAribter(vec(sendSideQP.dmaWriteClt4RQ, sendSideQP.dmaWriteClt4SQ));
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

    Reg#(TestTimeOutErrState) testStateReg <- mkReg(TEST_TIMEOUT_CREATE_QP);
    Reg#(Bool) firstWorkReqSavedReg <- mkRegU;
    Reg#(WorkReq) firstWorkReqReg <- mkRegU;

    let countDown <- mkCountDown(valueOf(TDiv#(MAX_CMP_CNT, 50)));

    rule createQP if (testStateReg == TEST_TIMEOUT_CREATE_QP);
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
        testStateReg <= TEST_TIMEOUT_INIT_QP;
        // $display("time=%0t:", $time, " create QP");
    endrule

    rule initQP if (testStateReg == TEST_TIMEOUT_INIT_QP);
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

        testStateReg <= TEST_TIMEOUT_SET_QP_RTR;
        // $display("time=%0t:", $time, " init QP");
    endrule

    rule setCntrlRTR if (testStateReg == TEST_TIMEOUT_SET_QP_RTR);
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

        testStateReg <= TEST_TIMEOUT_SET_QP_RTS;
        // $display("time=%0t:", $time, " set QP 2 RTR");
    endrule

    rule setCntrlRTS if (testStateReg == TEST_TIMEOUT_SET_QP_RTS);
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

        testStateReg <= TEST_TIMEOUT_CHECK_QP_RTS;
        firstWorkReqSavedReg <= False;
        // $display("time=%0t:", $time, " set QP 2 RTS");
    endrule

    rule checkStateRTS if (
        testStateReg == TEST_TIMEOUT_CHECK_QP_RTS
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

        testStateReg <= TEST_TIMEOUT_ERR_NOTIFY;
        // $display("time=%0t:", $time, " check QP in RTS state");
    endrule
/*
    rule compareWorkReq;
        let pktMetaData = reqPktMetaDataPipeOut.first;
        reqPktMetaDataPipeOut.deq;

        let bth = extractBTH(pktMetaData.pktHeader.headerData);
        let rdmaOpCode = bth.opcode;

        // let workReq4Ref = workReqPipeOut4Ref.first;
        // if (isLastOrOnlyRdmaOpCode(rdmaOpCode)) begin
        //     workReqPipeOut4Ref.deq;
        // end

        // immAssert(
        //     rdmaReqOpCodeMatchWorkReqOpCode(rdmaOpCode, workReq4Ref.opcode),
        //     "rdmaReqOpCodeMatchWorkReqOpCode assertion @ mkTestQueuePairTimeOutCase",
        //     $format(
        //         "RDMA request opcode=", fshow(rdmaOpCode),
        //         " should match workReqOpCode=", fshow(workReq4Ref.opcode)
        //     )
        // );

        $display(
            "time=%0t: rdmaOpCode=", $time, fshow(rdmaOpCode)
            // " not match WR=", fshow(workReq4Ref)
        );
        // countDown.decr;
    endrule

    // TODO: find out why workReqPipeOut4Ref size > MAX_QP_WR or flush this buffer will deadlock?
    rule passWorkReq if (
        sendSideQP.cntrlStatus.isRTS &&
        testStateReg != TEST_TIMEOUT_SET_QP_RTS
    );
        let workReq = workReqPipeOut.first;
        workReqPipeOut.deq;

        workReqQ.enq(workReq);
        if (!firstWorkReqSavedReg) begin
            firstWorkReqReg <= workReq;
            firstWorkReqSavedReg <= True;
        end
        $display("time=%0t:", $time, " save first WR");
    endrule
*/
    rule checkTimeOutErrWC if (
        // firstWorkReqSavedReg &&
        testStateReg == TEST_TIMEOUT_ERR_NOTIFY
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
                "timeOutErrWC=", fshow(timeOutErrWC),
                " not match expected status=", fshow(expectedWorkCompStatus)
            )
        );

        testStateReg <= TEST_TIMEOUT_DELETE_QP;
        // $display(
        //     "time=%0t: timeOutErrWC=", $time, fshow(timeOutErrWC)
        //     // " not match WR=", fshow(firstWorkReqReg)
        // );
    endrule

    rule deleteQP if (
        testStateReg == TEST_TIMEOUT_DELETE_QP
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

        testStateReg <= TEST_TIMEOUT_CHECK_QP_DELETED;
        // $display("time=%0t:", $time, " delete QP");
    endrule

    rule checkDeleteQP if (
        testStateReg == TEST_TIMEOUT_CHECK_QP_DELETED
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

        testStateReg <= TEST_TIMEOUT_WAIT_RESET;
        // $display("time=%0t:", $time, " check QP deleted");
    endrule

    rule waitResetQP if (
        testStateReg == TEST_TIMEOUT_WAIT_RESET &&
        sendSideQP.statusSQ.comm.isReset
    );
        testStateReg <= TEST_TIMEOUT_CREATE_QP;
        countDown.decr;
        // $display("time=%0t:", $time, " wait QP reset");
    endrule
endmodule

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
    // let dmaReadClt  <- mkDmaReadCltAribter(vec(sendSideQP.dmaReadClt4RQ, sendSideQP.dmaReadClt4SQ));
    // let dmaWriteClt <- mkDmaWriteCltAribter(vec(sendSideQP.dmaWriteClt4RQ, sendSideQP.dmaWriteClt4SQ));
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
                "timeOutErrWC=", fshow(timeOutErrWC),
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
    // let dmaReadClt  <- mkDmaReadCltAribter(vec(sendSideQP.dmaReadClt, recvSideQP.dmaReadClt));
    // let dmaWriteClt <- mkDmaWriteCltAribter(vec(sendSideQP.dmaWriteClt, recvSideQP.dmaWriteClt));
    // let dmaReadClt  <- mkDmaReadCltAribter(vec(sendSideQP.dmaReadClt4SQ, sendSideQP.dmaReadClt4RQ, recvSideQP.dmaReadClt4RQ, recvSideQP.dmaReadClt4SQ));
    // let dmaWriteClt <- mkDmaWriteCltAribter(vec(sendSideQP.dmaWriteClt4SQ, sendSideQP.dmaWriteClt4RQ, recvSideQP.dmaWriteClt4RQ, recvSideQP.dmaWriteClt4SQ));
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
                "WC=", fshow(workCompSQ), " not match expected status=", fshow(expectedWorkCompStatus)
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
                "WC=", fshow(workCompRQ), " not match expected status=", fshow(expectedWorkCompStatus)
            )
        );

        countDown.decr;
        // $display(
        //     "time=%0t: WC=", $time, fshow(workCompRQ), " not match RR=", fshow(recvReq4Ref)
        // );
    endrule
endmodule
