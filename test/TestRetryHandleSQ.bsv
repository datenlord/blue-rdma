import ClientServer :: *;
import Cntrs :: *;
import Connectable :: *;
import FIFOF :: *;
import GetPut :: *;
import PAClib :: *;
import Vector :: *;

import Controller :: *;
import DataTypes :: *;
import Headers :: *;
import MetaData :: *;
import PrimUtils :: *;
import RetryHandleSQ :: *;
import SpecialFIFOF :: *;
import Settings :: *;
import Utils :: *;
import Utils4Test :: *;

typedef enum {
    TEST_RETRY_TRIGGER_REQ,
    TEST_RETRY_TRIGGER_RESP,
    TEST_RETRY_TIMEOUT_NOTIFY,
    TEST_RETRY_WAIT_UNTIL_START,
    TEST_RETRY_STARTED,
    TEST_RETRY_RESTART_REQ,
    TEST_RETRY_RESTART_RESP,
    TEST_RETRY_WAIT_UNTIL_RESTART,
    TEST_RETRY_RESTARTED
    // TEST_RETRY_DONE
} TestRetryHandlerState deriving(Bits, Eq, FShow);

typedef enum {
    TEST_RETRY_CASE_SEQ_ERR,        // Partial retry
    TEST_RETRY_CASE_IMPLICIT_RETRY, // Full retry
    TEST_RETRY_CASE_RNR,            // Full retry
    TEST_RETRY_CASE_TIMEOUT,        // Full retry
    TEST_RETRY_CASE_NESTED_RETRY   // Partial retry
    // TEST_RETRY_CASE_EXC_LIMIT_ERR   // Partial retry
} TestRetryCase deriving(Bits, Eq, FShow);

(* synthesize *)
module mkTestRetryHandleSeqErrCase(Empty);
    let retryCase = TEST_RETRY_CASE_SEQ_ERR;
    let result <- mkTestRetryHandleSQ(retryCase);
endmodule

(* synthesize *)
module mkTestRetryHandleImplicitRetryCase(Empty);
    let retryCase = TEST_RETRY_CASE_IMPLICIT_RETRY;
    let result <- mkTestRetryHandleSQ(retryCase);
endmodule

(* synthesize *)
module mkTestRetryHandleRnrCase(Empty);
    let retryCase = TEST_RETRY_CASE_RNR;
    let result <- mkTestRetryHandleSQ(retryCase);
endmodule

(* synthesize *)
module mkTestRetryHandleTimeOutCase(Empty);
    let retryCase = TEST_RETRY_CASE_TIMEOUT;
    let result <- mkTestRetryHandleSQ(retryCase);
endmodule

(* synthesize *)
module mkTestRetryHandleNestedRetryCase(Empty);
    let retryCase = TEST_RETRY_CASE_NESTED_RETRY;
    let result <- mkTestRetryHandleSQ(retryCase);
endmodule

module mkTestRetryHandleSQ#(TestRetryCase retryCase)(Empty);
    let minPayloadLen = 1024;
    let maxPayloadLen = 4096;
    let qpType = IBV_QPT_XRC_SEND;
    let pmtu = IBV_MTU_256;

    let cntrl <- mkSimCntrl(qpType, pmtu);
    let cntrlStatus = cntrl.contextSQ.statusSQ;
    // let qpMetaData <- mkSimMetaData4SinigleQP(qpType, pmtu);
    // let qpIndex = getDefaultIndexQP;
    // let cntrl = qpMetaData.getCntrlByIndexQP(qpIndex);

    PendingWorkReqBuf pendingWorkReqBuf <- mkScanFIFOF;
    let retryWorkReqPipeOut = pendingWorkReqBuf.scanPipeOut;

    Vector#(1, PipeOut#(WorkReq)) workReqPipeOutVec <- mkRandomWorkReq(
        minPayloadLen, maxPayloadLen
    );
    Vector#(2, PipeOut#(PendingWorkReq)) existingPendingWorkReqPipeOutVec <-
        mkExistingPendingWorkReqPipeOut(cntrl, workReqPipeOutVec[0]);
    let pendingWorkReqPipeOut4PendingQ = existingPendingWorkReqPipeOutVec[0];
    let pendingWorkReqPipeOut4RetryWR <- mkBufferN(
        valueOf(MAX_QP_WR), existingPendingWorkReqPipeOutVec[1]
    );
    let pendingWorkReq2Q <- mkConnection(
        toGet(pendingWorkReqPipeOut4PendingQ), toPut(pendingWorkReqBuf.fifof)
    );

    // DUT
    let dut <- mkRetryHandleSQ(
        cntrlStatus, pendingWorkReqBuf.fifof.notEmpty, pendingWorkReqBuf.scanCntrl
    );

    Reg#(Bool) isPartialRetryWorkReqReg <- mkRegU;
    Reg#(TestRetryHandlerState) retryHandleTestStateReg <- mkReg(TEST_RETRY_TRIGGER_REQ);

    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    function RetryReason testRetryCase2RetryReason(TestRetryCase retryCase);
        return case (retryCase)
            TEST_RETRY_CASE_IMPLICIT_RETRY: RETRY_REASON_IMPLICIT;
            TEST_RETRY_CASE_RNR           : RETRY_REASON_RNR;
            TEST_RETRY_CASE_TIMEOUT       : RETRY_REASON_TIMEOUT;
            TEST_RETRY_CASE_SEQ_ERR       ,
            TEST_RETRY_CASE_NESTED_RETRY  : RETRY_REASON_SEQ_ERR;
            // TEST_RETRY_CASE_EXC_LIMIT_ERR
            default                       : RETRY_REASON_NOT_RETRY;
        endcase;
    endfunction

    rule triggerRetry if (
        cntrlStatus.comm.isRTS                        &&
        !pendingWorkReqBuf.fifof.notFull &&
        retryHandleTestStateReg == TEST_RETRY_TRIGGER_REQ
    );
        let firstRetryWR = pendingWorkReqBuf.fifof.first;
        let wrStartPSN = unwrapMaybe(firstRetryWR.startPSN);
        let wrEndPSN = unwrapMaybe(firstRetryWR.endPSN);

        let retryReason = testRetryCase2RetryReason(retryCase);
        immAssert(
            retryReason != RETRY_REASON_NOT_RETRY,
            "retryReason assertion @ mkTestRetryHandleSQ",
            $format(
                "retryReason=", fshow(retryReason),
                " and retryCase=", fshow(retryCase)
            )
        );

        let isPartialRetry = retryReason == RETRY_REASON_SEQ_ERR;
        // If partial retry, then retry from wrEndPSN
        let retryStartPSN = isPartialRetry ? wrEndPSN : wrStartPSN;
        let retryRnrTimer = retryCase == TEST_RETRY_CASE_RNR ?
            tagged Valid cntrlStatus.comm.getMinRnrTimer : tagged Invalid;

        isPartialRetryWorkReqReg <= isPartialRetry;
        if (retryCase != TEST_RETRY_CASE_TIMEOUT) begin
            let retryReq = RetryReq {
                wrID         : firstRetryWR.wr.id,
                retryStartPSN: retryStartPSN,
                retryReason  : retryReason,
                retryRnrTimer: retryRnrTimer
            };
            dut.srvPort.request.put(retryReq);
            retryHandleTestStateReg <= TEST_RETRY_TRIGGER_RESP;
        end
        else begin
            retryHandleTestStateReg <= TEST_RETRY_TIMEOUT_NOTIFY;
        end
        // $display("time=%0t: triggerRetry", $time);
    endrule

    rule recvRetryResp if (
        cntrlStatus.comm.isRTS &&
        retryHandleTestStateReg == TEST_RETRY_TRIGGER_RESP
    );
        let retryResp <- dut.srvPort.response.get;
        immAssert(
            retryResp == RETRY_HANDLER_RECV_RETRY_REQ,
            "retryResp assertion @ mkTestRetryHandleSQ",
            $format(
                "retryResp=", fshow(retryResp),
                " should be RETRY_HANDLER_RECV_RETRY_REQ"
            )
        );

        retryHandleTestStateReg <= TEST_RETRY_WAIT_UNTIL_START;
    endrule

    rule recvTimeOutNotification if (
        cntrlStatus.comm.isRTS &&
        retryHandleTestStateReg == TEST_RETRY_TIMEOUT_NOTIFY
    );
        let timeOutNotification <- dut.notifyTimeOut2SQ;
        immAssert(
            timeOutNotification == RETRY_HANDLER_TIMEOUT_RETRY,
            "timeOutNotification assertion @ mkTestRetryHandleSQ",
            $format(
                "timeOutNotification=", fshow(timeOutNotification),
                " should be RETRY_HANDLER_TIMEOUT_RETRY"
            )
        );

        retryHandleTestStateReg <= TEST_RETRY_WAIT_UNTIL_START;
    endrule

    rule waitUtilRetryStart if (
        cntrlStatus.comm.isRTS && dut.isRetrying &&
        retryHandleTestStateReg == TEST_RETRY_WAIT_UNTIL_START
    );
        if (
            retryCase == TEST_RETRY_CASE_NESTED_RETRY
        ) begin
            retryHandleTestStateReg <= TEST_RETRY_RESTART_REQ;
        end
        else begin
            retryHandleTestStateReg <= TEST_RETRY_STARTED;
        end
        // $display("time=%0t: waitUtilRetryStart", $time);
    endrule

    rule triggerRetryRestart if (
        cntrlStatus.comm.isRTS && dut.isRetrying &&
        retryHandleTestStateReg == TEST_RETRY_RESTART_REQ
    );
        let firstRetryWR = retryWorkReqPipeOut.first;
        retryWorkReqPipeOut.deq;

        let wrStartPSN = unwrapMaybe(firstRetryWR.startPSN);
        let wrEndPSN = unwrapMaybe(firstRetryWR.endPSN);

        let retryReason = testRetryCase2RetryReason(retryCase);
        let isPartialRetry = retryReason == RETRY_REASON_SEQ_ERR;
        // If partial retry, then retry from wrEndPSN
        let retryStartPSN = isPartialRetry ? wrEndPSN : wrStartPSN;
        let retryRnrTimer = tagged Invalid;

        let retryReq = RetryReq {
            wrID         : firstRetryWR.wr.id,
            retryStartPSN: retryStartPSN,
            retryReason  : retryReason,
            retryRnrTimer: retryRnrTimer
        };
        dut.srvPort.request.put(retryReq);
        retryHandleTestStateReg <= TEST_RETRY_RESTART_RESP;
        // $display(
        //     "time=%0t:", $time,
        //     " retryRestart firstRetryWR.wr.id=%h", firstRetryWR.wr.id
        // );
    endrule

    rule recvRetryRestartResp if (
        cntrlStatus.comm.isRTS &&
        retryHandleTestStateReg == TEST_RETRY_RESTART_RESP
    );
        let retryRestartResp <- dut.srvPort.response.get;
        immAssert(
            retryRestartResp == RETRY_HANDLER_RECV_RETRY_REQ,
            "retryRestartResp assertion @ mkTestRetryHandleSQ",
            $format(
                "retryRestartResp=", fshow(retryRestartResp),
                " should be RETRY_HANDLER_RECV_RETRY_REQ"
            )
        );

        retryHandleTestStateReg <= TEST_RETRY_WAIT_UNTIL_RESTART;
    endrule

    rule waitUtilRetryRestart if (
        cntrlStatus.comm.isRTS && dut.isRetrying &&
        retryHandleTestStateReg == TEST_RETRY_WAIT_UNTIL_RESTART
    );
        retryHandleTestStateReg <= TEST_RETRY_RESTARTED;
        // $display("time=%0t: retryWait4Restart", $time);
    endrule

    rule compare if (
        cntrlStatus.comm.isRTS && (
            retryHandleTestStateReg == TEST_RETRY_STARTED ||
            retryHandleTestStateReg == TEST_RETRY_RESTARTED
        )
    );
        let retryWR = retryWorkReqPipeOut.first;
        retryWorkReqPipeOut.deq;

        let refRetryWR = pendingWorkReqPipeOut4RetryWR.first;
        pendingWorkReqPipeOut4RetryWR.deq;

        let startPSN = unwrapMaybe(retryWR.startPSN);
        let endPSN = unwrapMaybe(retryWR.endPSN);
        let refStartPSN = unwrapMaybe(refRetryWR.startPSN);
        let refEndPSN = unwrapMaybe(refRetryWR.endPSN);

        immAssert(
            retryWR.wr.id == refRetryWR.wr.id,
            "retryWR ID assertion @ mkTestRetryHandleSQ",
            $format(
                "retryWR.wr.id=%h == refRetryWR.wr.id=%h",
                retryWR.wr.id, refRetryWR.wr.id,
                ", retryWR=", fshow(retryWR),
                ", refRetryWR=", fshow(refRetryWR)
            )
        );

        immAssert(
            retryWR.wr.id == refRetryWR.wr.id,
            "retryWR ID assertion @ mkTestRetryHandleSQ",
            $format(
                "retryWR.wr.id=%h == refRetryWR.wr.id=%h",
                retryWR.wr.id, refRetryWR.wr.id,
                ", retryWR=", fshow(retryWR),
                ", refRetryWR=", fshow(refRetryWR)
            )
        );

        if (isPartialRetryWorkReqReg) begin
            immAssert(
                startPSN == refEndPSN && endPSN == refEndPSN,
                "retryWR partial retry PSN assertion @ mkTestRetryHandleSQ",
                $format(
                    "startPSN=%h should == refEndPSN=%h",
                    startPSN, refEndPSN,
                    ", endPSN=%h should == refEndPSN=%h",
                    endPSN, refEndPSN,
                    ", when isPartialRetryWorkReqReg=",
                    fshow(isPartialRetryWorkReqReg)
                )
            );
            isPartialRetryWorkReqReg <= False;
        end
        else begin
            immAssert(
                startPSN == refStartPSN && endPSN == refEndPSN,
                "retryWR PSN assertion @ mkTestRetryHandleSQ",
                $format(
                    "startPSN=%h should == refStartPSN=%h",
                    startPSN, refStartPSN,
                    ", endPSN=%h should == refEndPSN=%h",
                    endPSN, refEndPSN
                )
            );
        end

        countDown.decr;
        // $display(
        //     "time=%0t: compare", $time,
        //     " retryWR.wr.id=%h == refRetryWR.wr.id=%h",
        //     retryWR.wr.id, refRetryWR.wr.id,
        //     ", retryHandleTestStateReg=", fshow(retryHandleTestStateReg)
        //     // ", retryWR=", fshow(retryWR),
        //     // ", refRetryWR=", fshow(refRetryWR)
        // );
    endrule

    rule retryDone if (
        cntrlStatus.comm.isRTS && dut.isRetryDone && (
            retryHandleTestStateReg == TEST_RETRY_STARTED ||
            retryHandleTestStateReg == TEST_RETRY_RESTARTED
        )
    );
        retryHandleTestStateReg <= TEST_RETRY_TRIGGER_REQ;
        pendingWorkReqBuf.fifof.clear;
        dut.resetRetryCntAndTimeOutBySQ(RETRY_HANDLER_RESET_RETRY_CNT_AND_TIMEOUT);
        // $display("time=%0t: retryDone", $time);
    endrule
endmodule

typedef enum {
    TEST_RETRY_ERR_EXC_TIMEOUT_LIMIT, // Full retry
    TEST_RETRY_ERR_EXC_RETRY_LIMIT    // Partial retry
} TestRetryErrCase deriving(Bits, Eq, FShow);

(* synthesize *)
module mkTestRetryHandleExcRetryLimitErrCase(Empty);
    let retryErrCase = TEST_RETRY_ERR_EXC_RETRY_LIMIT;
    let result <- mkTestRetryHandleRetryErrCase(retryErrCase);
endmodule

(* synthesize *)
module mkTestRetryHandleExcTimeOutLimitErrCase(Empty);
    let retryErrCase = TEST_RETRY_ERR_EXC_TIMEOUT_LIMIT;
    let result <- mkTestRetryHandleRetryErrCase(retryErrCase);
endmodule

typedef enum {
    TEST_RETRY_TRIGGER_REQ,
    TEST_RETRY_TRIGGER_RESP,
    TEST_RETRY_TIMEOUT_NOTIFY,
    TEST_RETRY_DECR_RETRY_CNT,
    TEST_RETRY_STARTED,
    TEST_RETRY_SET_QP_ERR,
    TEST_RETRY_SET_ERR_FLUSH_DONE
} TestRetryErrState deriving(Bits, Eq, FShow);

module mkTestRetryHandleRetryErrCase#(TestRetryErrCase retryErrCase)(Empty);
    let minPayloadLen = 1024;
    let maxPayloadLen = 4096;
    let qpType = IBV_QPT_XRC_SEND;
    let pmtu = IBV_MTU_256;

    let cntrl <- mkCntrlQP;
    let cntrlStatus = cntrl.contextSQ.statusSQ;
    // Cycle QP state
    let setExpectedPsnAsNextPSN = True;
    let setZero2ExpectedPsnAndNextPSN = True;
    let qpDestroyWhenErr = True;
    let cntrlStateCycle <- mkCntrlStateCycle(
        cntrl.srvPort,
        cntrlStatus,
        getDefaultQPN,
        qpType,
        pmtu,
        setExpectedPsnAsNextPSN,
        setZero2ExpectedPsnAndNextPSN,
        qpDestroyWhenErr
    );

    PendingWorkReqBuf pendingWorkReqBuf <- mkScanFIFOF;
    let retryWorkReqPipeOut = pendingWorkReqBuf.scanPipeOut;

    Vector#(1, PipeOut#(WorkReq)) workReqPipeOutVec <- mkRandomWorkReq(
        minPayloadLen, maxPayloadLen
    );
    Vector#(1, PipeOut#(PendingWorkReq)) existingPendingWorkReqPipeOutVec <-
        mkExistingPendingWorkReqPipeOut(cntrl, workReqPipeOutVec[0]);
    let pendingWorkReqPipeOut4PendingQ = existingPendingWorkReqPipeOutVec[0];
    let pendingWorkReq2Q <- mkConnection(
        toGet(pendingWorkReqPipeOut4PendingQ), toPut(pendingWorkReqBuf.fifof)
    );

    // DUT
    let dut <- mkRetryHandleSQ(
        cntrlStatus, pendingWorkReqBuf.fifof.notEmpty, pendingWorkReqBuf.scanCntrl
    );

    Reg#(TestRetryErrState) retryHandleTestStateReg <- mkReg(TEST_RETRY_TRIGGER_REQ);

    Count#(RetryCnt) maxRetryCnt <- mkCount(0);
    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    rule setMaxRetryCnt if (cntrlStatus.comm.isRTR2RTS);
        maxRetryCnt <= cntrlStatus.comm.getMaxRetryCnt; // - 1;
        // $display(
        //     "time=%0t: setMaxRetryCnt", $time,
        //     ", cntrlStatus.comm.getMaxRetryCnt=%0d", cntrlStatus.comm.getMaxRetryCnt
        // );
    endrule

    rule triggerRetry if (
        cntrlStatus.comm.isStableRTS && // pendingWorkReqBuf.fifof.notEmpty &&
        retryHandleTestStateReg == TEST_RETRY_TRIGGER_REQ
    );
        let firstRetryWR = pendingWorkReqBuf.fifof.first;
        let wrStartPSN = unwrapMaybe(firstRetryWR.startPSN);
        let wrEndPSN = unwrapMaybe(firstRetryWR.endPSN);

        if (retryErrCase != TEST_RETRY_ERR_EXC_TIMEOUT_LIMIT) begin
            let retryReason = RETRY_REASON_SEQ_ERR;
            let isPartialRetry = retryReason == RETRY_REASON_SEQ_ERR;
            // If partial retry, then retry from wrEndPSN
            let retryStartPSN = isPartialRetry ? wrEndPSN : wrStartPSN;
            let retryRnrTimer = retryReason == RETRY_REASON_RNR ?
                tagged Valid cntrlStatus.comm.getMinRnrTimer : tagged Invalid;

            let retryReq = RetryReq {
                wrID         : firstRetryWR.wr.id,
                retryStartPSN: retryStartPSN,
                retryReason  : retryReason,
                retryRnrTimer: retryRnrTimer
            };
            dut.srvPort.request.put(retryReq);
            retryHandleTestStateReg <= TEST_RETRY_TRIGGER_RESP;
        end
        else begin
            retryHandleTestStateReg <= TEST_RETRY_TIMEOUT_NOTIFY;
        end

        // $display(
        //     "time=%0t: triggerRetry", $time, ", maxRetryCnt=%0d", maxRetryCnt
        // );
    endrule

    rule recvRetryResp if (
        cntrlStatus.comm.isStableRTS &&
        retryHandleTestStateReg == TEST_RETRY_TRIGGER_RESP
    );
        let retryResp <- dut.srvPort.response.get;

        if (isZero(maxRetryCnt)) begin
            immAssert(
                retryResp == RETRY_HANDLER_RETRY_LIMIT_EXC,
                "retryResp assertion @ mkTestRetryHandleRetryErrCase",
                $format(
                    "retryResp=", fshow(retryResp),
                    " should be RETRY_HANDLER_RETRY_LIMIT_EXC"
                )
            );
        end
        else begin
            immAssert(
                retryResp == RETRY_HANDLER_RECV_RETRY_REQ,
                "retryResp assertion @ mkTestRetryHandleRetryErrCase",
                $format(
                    "retryResp=", fshow(retryResp),
                    " should be RETRY_HANDLER_RECV_RETRY_REQ"
                )
            );
        end

        retryHandleTestStateReg <= TEST_RETRY_DECR_RETRY_CNT;
    endrule

    rule recvTimeOutNotification if (
        cntrlStatus.comm.isStableRTS &&
        retryHandleTestStateReg == TEST_RETRY_TIMEOUT_NOTIFY
    );
        let timeOutNotification <- dut.notifyTimeOut2SQ;

        if (isZero(maxRetryCnt)) begin
            immAssert(
                timeOutNotification == RETRY_HANDLER_TIMEOUT_ERR,
                "timeOutNotification assertion @ mkTestRetryHandleSQ",
                $format(
                    "timeOutNotification=", fshow(timeOutNotification),
                    " should be RETRY_HANDLER_TIMEOUT_ERR"
                )
            );
        end
        else begin
            immAssert(
                timeOutNotification == RETRY_HANDLER_TIMEOUT_RETRY,
                "timeOutNotification assertion @ mkTestRetryHandleSQ",
                $format(
                    "timeOutNotification=", fshow(timeOutNotification),
                    " should be RETRY_HANDLER_TIMEOUT_RETRY"
                )
            );
        end

        retryHandleTestStateReg <= TEST_RETRY_DECR_RETRY_CNT;
        // $display("time=%0t: recvTimeOutNotification", $time);
    endrule

    rule decrRetryCnt if (
        cntrlStatus.comm.isStableRTS &&
        (dut.isRetrying || dut.hasRetryErr) &&
        retryHandleTestStateReg == TEST_RETRY_DECR_RETRY_CNT
    );
        // let nextRetryHandleTestState = TEST_RETRY_STARTED;
        if (isZero(maxRetryCnt)) begin
            // nextRetryHandleTestState = TEST_RETRY_SET_QP_ERR;
            retryHandleTestStateReg <= TEST_RETRY_SET_QP_ERR;
        end
        else begin
            maxRetryCnt.decr(1);
            retryHandleTestStateReg <= TEST_RETRY_STARTED;
        end
        // retryHandleTestStateReg <= nextRetryHandleTestState;

        // $display(
        //     "time=%0t: decrRetryCnt", $time,
        //     ", maxRetryCnt=%0d", maxRetryCnt,
        //     // ", nextRetryHandleTestState=", fshow(nextRetryHandleTestState),
        //     ", dut.hasRetryErr=", fshow(dut.hasRetryErr)
        // );
    endrule

    rule retryDone if (
        cntrlStatus.comm.isStableRTS && dut.isRetryDone &&
        retryHandleTestStateReg == TEST_RETRY_STARTED
    );
        retryHandleTestStateReg <= TEST_RETRY_TRIGGER_REQ;
        pendingWorkReqBuf.fifof.clear;
        // $display("time=%0t: retryDone", $time);
    endrule

    rule drainRetryWR if (
        cntrlStatus.comm.isStableRTS &&
        retryHandleTestStateReg == TEST_RETRY_STARTED
    );
        let retryWR = retryWorkReqPipeOut.first;
        retryWorkReqPipeOut.deq;

        countDown.decr;
        // $display(
        //     "time=%0t: compare", $time,
        //     " retryWR.wr.id=%h == refRetryWR.wr.id=%h",
        //     retryWR.wr.id, refRetryWR.wr.id,
        //     ", retryHandleTestStateReg=", fshow(retryHandleTestStateReg)
        //     // ", retryWR=", fshow(retryWR),
        //     // ", refRetryWR=", fshow(refRetryWR)
        // );
    endrule

    rule setCntrlErr if (
        cntrlStatus.comm.isStableRTS &&
        retryHandleTestStateReg == TEST_RETRY_SET_QP_ERR
    );
        immAssert(
            dut.hasRetryErr,
            "hasRetryErr assertion @ mkTestRetryHandlerSQ",
            $format(
                "dut.hasRetryErr=", fshow(dut.hasRetryErr),
                " should be true"
            )
        );
        cntrl.setStateErr;
        // let qpAttr = qpAttrPipeOut.first;
        // qpAttr.qpState = IBV_QPS_ERR;
        // let modifyReqQP = ReqQP {
        //     qpReqType   : REQ_QP_MODIFY,
        //     pdHandler   : dontCareValue,
        //     qpn         : getDefaultQPN,
        //     qpAttrMask  : dontCareValue,
        //     qpAttr      : qpAttr,
        //     qpInitAttr  : dontCareValue
        // };
        // cntrl.srvPort.request.put(modifyReqQP);

        retryHandleTestStateReg <= TEST_RETRY_SET_ERR_FLUSH_DONE;
        // $display("time=%0t:", $time, " set QP 2 ERR");
    endrule

    rule setErrFlushDone if (
        cntrlStatus.comm.isERR &&
        retryHandleTestStateReg == TEST_RETRY_SET_ERR_FLUSH_DONE
    );
        immAssert(
            dut.hasRetryErr,
            "hasRetryErr assertion @ mkTestRetryHandlerSQ",
            $format(
                "dut.hasRetryErr=", fshow(dut.hasRetryErr),
                " should be true"
            )
        );
        cntrl.errFlushDone;

        retryHandleTestStateReg <= TEST_RETRY_TRIGGER_REQ;
        // $display("time=%0t:", $time, " set QP error flush done");
    endrule
endmodule
/*
typedef enum {
    TEST_RETRY_CREATE_QP,
    TEST_RETRY_INIT_QP,
    TEST_RETRY_SET_QP_RTR,
    TEST_RETRY_SET_QP_RTS,
    TEST_RETRY_CHECK_QP_STATE,
    TEST_RETRY_TRIGGER_REQ,
    TEST_RETRY_TRIGGER_RESP,
    TEST_RETRY_TIMEOUT_NOTIFY,
    TEST_RETRY_DECR_RETRY_CNT,
    TEST_RETRY_STARTED,
    TEST_RETRY_SET_QP_ERR,
    TEST_RETRY_DESTROY_QP,
    TEST_RETRY_SET_ERR_FLUSH_DONE,
    TEST_RETRY_RESET_QP
} TestRetryErrState deriving(Bits, Eq, FShow);

module mkTestRetryHandleRetryErrCase#(TestRetryErrCase retryErrCase)(Empty);
    let minPayloadLen = 1024;
    let maxPayloadLen = 4096;
    let qpType = IBV_QPT_XRC_SEND;
    let pmtu = IBV_MTU_256;

    let cntrl <- mkCntrlQP;
    let cntrlStatus = cntrl.contextSQ.statusSQ;

    PendingWorkReqBuf pendingWorkReqBuf <- mkScanFIFOF;
    let retryWorkReqPipeOut = pendingWorkReqBuf.scanPipeOut;

    Vector#(1, PipeOut#(WorkReq)) workReqPipeOutVec <- mkRandomWorkReq(
        minPayloadLen, maxPayloadLen
    );
    Vector#(1, PipeOut#(PendingWorkReq)) existingPendingWorkReqPipeOutVec <-
        mkExistingPendingWorkReqPipeOut(cntrl, workReqPipeOutVec[0]);
    let pendingWorkReqPipeOut4PendingQ = existingPendingWorkReqPipeOutVec[0];
    let pendingWorkReq2Q <- mkConnection(
        toGet(pendingWorkReqPipeOut4PendingQ), toPut(pendingWorkReqBuf.fifof)
    );

    // DUT
    let dut <- mkRetryHandleSQ(
        cntrlStatus, pendingWorkReqBuf.fifof.notEmpty, pendingWorkReqBuf.scanCntrl
    );

    Reg#(TestRetryErrState) retryHandleTestStateReg <- mkReg(TEST_RETRY_CREATE_QP);

    Count#(RetryCnt) maxRetryCnt <- mkCount(0);
    let countDown <- mkCountDown(valueOf(MAX_CMP_CNT));

    // For controller initialization
    let qpAttrPipeOut <- mkQpAttrPipeOut;

    rule createQP if (retryHandleTestStateReg == TEST_RETRY_CREATE_QP);
        immAssert(
            cntrlStatus.comm.isReset,
            "cntrl state assertion @ mkTestRetryHandleRetryErrCase",
            $format(
                "cntrlStatus.comm.isReset=", fshow(cntrlStatus.comm.isReset),
                " should be true"
            )
        );

        let qpInitAttr = QpInitAttr {
            qpType  : qpType,
            sqSigAll: False
        };

        let qpCreateReq = ReqQP {
            qpReqType : REQ_QP_CREATE,
            pdHandler : dontCareValue,
            qpn       : getDefaultQPN,
            qpAttrMask: dontCareValue,
            qpAttr    : dontCareValue,
            qpInitAttr: qpInitAttr
        };

        cntrl.srvPort.request.put(qpCreateReq);
        retryHandleTestStateReg <= TEST_RETRY_INIT_QP;
        // $display("time=%0t:", $time, " create QP");
    endrule

    rule initQP if (retryHandleTestStateReg == TEST_RETRY_INIT_QP);
        let qpCreateResp <- cntrl.srvPort.response.get;
        immAssert(
            qpCreateResp.successOrNot,
            "qpCreateResp.successOrNot assertion @ mkTestRetryHandleRetryErrCase",
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
            qpInitAttr: dontCareValue
        };
        cntrl.srvPort.request.put(modifyReqQP);

        retryHandleTestStateReg <= TEST_RETRY_SET_QP_RTR;
        // $display("time=%0t:", $time, " init QP");
    endrule

    rule setCntrlRTR if (retryHandleTestStateReg == TEST_RETRY_SET_QP_RTR);
        let qpInitResp <- cntrl.srvPort.response.get;
        immAssert(
            qpInitResp.successOrNot,
            "qpInitResp.successOrNot assertion @ mkTestRetryHandleRetryErrCase",
            $format(
                "qpInitResp.successOrNot=", fshow(qpInitResp.successOrNot),
                " should be true when qpInitResp=", fshow(qpInitResp)
            )
        );

        let qpAttr = qpAttrPipeOut.first;
        qpAttr.qpState = IBV_QPS_RTR;
        let modifyReqQP = ReqQP {
            qpReqType : REQ_QP_MODIFY,
            pdHandler : dontCareValue,
            qpn       : getDefaultQPN,
            qpAttrMask: getInit2RtrRequiredAttr,
            qpAttr    : qpAttr,
            qpInitAttr: dontCareValue
        };
        cntrl.srvPort.request.put(modifyReqQP);

        retryHandleTestStateReg <= TEST_RETRY_SET_QP_RTS;
        // $display("time=%0t:", $time, " set QP 2 RTR");
    endrule

    rule setCntrlRTS if (retryHandleTestStateReg == TEST_RETRY_SET_QP_RTS);
        let qpRtrResp <- cntrl.srvPort.response.get;
        immAssert(
            qpRtrResp.successOrNot,
            "qpRtrResp.successOrNot assertion @ mkTestRetryHandleRetryErrCase",
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
            qpInitAttr: dontCareValue
        };
        cntrl.srvPort.request.put(modifyReqQP);

        retryHandleTestStateReg <= TEST_RETRY_CHECK_QP_STATE;
        // $display("time=%0t:", $time, " set QP 2 RTS");
    endrule

    rule checkStateQP if (
        retryHandleTestStateReg == TEST_RETRY_CHECK_QP_STATE
    );
        let qpRtsResp <- cntrl.srvPort.response.get;
        immAssert(
            qpRtsResp.successOrNot,
            "qpRtsResp.successOrNot assertion @ mkTestRetryHandleRetryErrCase",
            $format(
                "qpRtsResp.successOrNot=", fshow(qpRtsResp.successOrNot),
                " should be true when qpRtsResp=", fshow(qpRtsResp)
            )
        );

        immAssert(
            cntrlStatus.comm.isRTS,
            "cntrlStatus.comm.isRTS assertion @ mkTestRetryHandleRetryErrCase",
            $format(
                "cntrlStatus.comm.isRTS=", fshow(cntrlStatus.comm.isRTS),
                " should be true when qpRtsResp=", fshow(qpRtsResp)
            )
        );
        immAssert(
            !dut.hasRetryErr,
            "hasRetryErr assertion @ mkTestRetryHandleRetryErrCase",
            $format(
                "dut.hasRetryErr=", fshow(dut.hasRetryErr),
                " should be false"
            )
        );

        retryHandleTestStateReg <= TEST_RETRY_TRIGGER_REQ;
        maxRetryCnt <= cntrlStatus.comm.getMaxRetryCnt; // - 1;
        // $display(
        //     "time=%0t:", $time, " check QP state",
        //     ", pendingWorkReqBuf.fifof.notEmpty=", fshow(pendingWorkReqBuf.fifof.notEmpty)
        // );
    endrule

    rule triggerRetry if (
        cntrlStatus.comm.isRTS && // pendingWorkReqBuf.fifof.notEmpty &&
        retryHandleTestStateReg == TEST_RETRY_TRIGGER_REQ
    );
        let firstRetryWR = pendingWorkReqBuf.fifof.first;
        let wrStartPSN = unwrapMaybe(firstRetryWR.startPSN);
        let wrEndPSN = unwrapMaybe(firstRetryWR.endPSN);

        if (retryErrCase != TEST_RETRY_ERR_EXC_TIMEOUT_LIMIT) begin
            let retryReason = RETRY_REASON_SEQ_ERR;
            let isPartialRetry = retryReason == RETRY_REASON_SEQ_ERR;
            // If partial retry, then retry from wrEndPSN
            let retryStartPSN = isPartialRetry ? wrEndPSN : wrStartPSN;
            let retryRnrTimer = retryReason == RETRY_REASON_RNR ?
                tagged Valid cntrlStatus.comm.getMinRnrTimer : tagged Invalid;

            let retryReq = RetryReq {
                wrID         : firstRetryWR.wr.id,
                retryStartPSN: retryStartPSN,
                retryReason  : retryReason,
                retryRnrTimer: retryRnrTimer
            };
            dut.srvPort.request.put(retryReq);
            retryHandleTestStateReg <= TEST_RETRY_TRIGGER_RESP;
        end
        else begin
            retryHandleTestStateReg <= TEST_RETRY_TIMEOUT_NOTIFY;
        end
        // $display(
        //     "time=%0t: triggerRetry", $time, ", maxRetryCnt=%0d", maxRetryCnt
        // );
    endrule

    rule recvRetryResp if (
        cntrlStatus.comm.isRTS &&
        retryHandleTestStateReg == TEST_RETRY_TRIGGER_RESP
    );
        let retryResp <- dut.srvPort.response.get;

        if (isZero(maxRetryCnt)) begin
            immAssert(
                retryResp == RETRY_HANDLER_RETRY_LIMIT_EXC,
                "retryResp assertion @ mkTestRetryHandleRetryErrCase",
                $format(
                    "retryResp=", fshow(retryResp),
                    " should be RETRY_HANDLER_RETRY_LIMIT_EXC"
                )
            );
        end
        else begin
            immAssert(
                retryResp == RETRY_HANDLER_RECV_RETRY_REQ,
                "retryResp assertion @ mkTestRetryHandleRetryErrCase",
                $format(
                    "retryResp=", fshow(retryResp),
                    " should be RETRY_HANDLER_RECV_RETRY_REQ"
                )
            );
        end

        retryHandleTestStateReg <= TEST_RETRY_DECR_RETRY_CNT;
    endrule

    rule recvTimeOutNotification if (
        cntrlStatus.comm.isRTS &&
        retryHandleTestStateReg == TEST_RETRY_TIMEOUT_NOTIFY
    );
        let timeOutNotification <- dut.notifyTimeOut2SQ;

        if (isZero(maxRetryCnt)) begin
            immAssert(
                timeOutNotification == RETRY_HANDLER_TIMEOUT_ERR,
                "timeOutNotification assertion @ mkTestRetryHandleSQ",
                $format(
                    "timeOutNotification=", fshow(timeOutNotification),
                    " should be RETRY_HANDLER_TIMEOUT_ERR"
                )
            );
        end
        else begin
            immAssert(
                timeOutNotification == RETRY_HANDLER_TIMEOUT_RETRY,
                "timeOutNotification assertion @ mkTestRetryHandleSQ",
                $format(
                    "timeOutNotification=", fshow(timeOutNotification),
                    " should be RETRY_HANDLER_TIMEOUT_RETRY"
                )
            );
        end

        retryHandleTestStateReg <= TEST_RETRY_DECR_RETRY_CNT;
        // $display("time=%0t: recvTimeOutNotification", $time);
    endrule

    rule decrRetryCnt if (
        (dut.isRetrying || dut.hasRetryErr) &&
        retryHandleTestStateReg == TEST_RETRY_DECR_RETRY_CNT
    );
        TestRetryErrState nextRetryHandleTestState = TEST_RETRY_STARTED;
        if (isZero(maxRetryCnt)) begin
            nextRetryHandleTestState = TEST_RETRY_SET_QP_ERR;
            // retryHandleTestStateReg <= TEST_RETRY_SET_QP_ERR;
        end
        else begin
            maxRetryCnt.decr(1);
            // retryHandleTestStateReg <= TEST_RETRY_STARTED;
        end

        retryHandleTestStateReg <= nextRetryHandleTestState;
        // $display(
        //     "time=%0t: decrRetryCnt", $time,
        //     ", maxRetryCnt=%0d", maxRetryCnt,
        //     ", nextRetryHandleTestState=", fshow(nextRetryHandleTestState),
        //     ", dut.hasRetryErr=", fshow(dut.hasRetryErr)
        // );
    endrule

    rule retryDone if (
        cntrlStatus.comm.isRTS && dut.isRetryDone &&
        retryHandleTestStateReg == TEST_RETRY_STARTED
    );
        retryHandleTestStateReg <= TEST_RETRY_TRIGGER_REQ;
        pendingWorkReqBuf.fifof.clear;
        // $display("time=%0t: retryDone", $time);
    endrule

    rule drainRetryWR if (
        cntrlStatus.comm.isRTS &&
        retryHandleTestStateReg == TEST_RETRY_STARTED
    );
        let retryWR = retryWorkReqPipeOut.first;
        retryWorkReqPipeOut.deq;

        countDown.decr;
        // $display(
        //     "time=%0t: compare", $time,
        //     " retryWR.wr.id=%h == refRetryWR.wr.id=%h",
        //     retryWR.wr.id, refRetryWR.wr.id,
        //     ", retryHandleTestStateReg=", fshow(retryHandleTestStateReg)
        //     // ", retryWR=", fshow(retryWR),
        //     // ", refRetryWR=", fshow(refRetryWR)
        // );
    endrule

    rule setCntrlErr if (
        retryHandleTestStateReg == TEST_RETRY_SET_QP_ERR
    );
        immAssert(
            dut.hasRetryErr,
            "hasRetryErr assertion @ mkTestRetryHandlerSQ",
            $format(
                "dut.hasRetryErr=", fshow(dut.hasRetryErr),
                " should be true"
            )
        );
        cntrl.setStateErr;
        // let qpAttr = qpAttrPipeOut.first;
        // qpAttr.qpState = IBV_QPS_ERR;
        // let modifyReqQP = ReqQP {
        //     qpReqType   : REQ_QP_MODIFY,
        //     pdHandler   : dontCareValue,
        //     qpn         : getDefaultQPN,
        //     qpAttrMask  : dontCareValue,
        //     qpAttr      : qpAttr,
        //     qpInitAttr  : dontCareValue
        // };
        // cntrl.srvPort.request.put(modifyReqQP);

        retryHandleTestStateReg <= TEST_RETRY_DESTROY_QP;
        // $display("time=%0t:", $time, " set QP 2 ERR");
    endrule

    rule destroyQP if (
        retryHandleTestStateReg == TEST_RETRY_DESTROY_QP
    );
        immAssert(
            cntrlStatus.comm.isERR,
            "cntrlStatus.comm.isERR assertion @ mkTestRetryHandleRetryErrCase",
            $format(
                "cntrlStatus.comm.isERR=", fshow(cntrlStatus.comm.isERR), " should be true"
                // " when qpModifyResp=", fshow(qpModifyResp)
            )
        );

        let qpAttr = qpAttrPipeOut.first;
        qpAttr.qpState = IBV_QPS_UNKNOWN;
        let destroyReqQP = ReqQP {
            qpReqType   : REQ_QP_DESTROY,
            pdHandler   : dontCareValue,
            qpn         : getDefaultQPN,
            qpAttrMask  : dontCareValue,
            qpAttr      : qpAttr,
            qpInitAttr  : dontCareValue
        };
        cntrl.srvPort.request.put(destroyReqQP);

        retryHandleTestStateReg <= TEST_RETRY_SET_ERR_FLUSH_DONE;
        // $display("time=%0t:", $time, " destroy QP");
    endrule

    rule setErrFlushDone if (
        retryHandleTestStateReg == TEST_RETRY_SET_ERR_FLUSH_DONE
    );
        immAssert(
            dut.hasRetryErr,
            "hasRetryErr assertion @ mkTestRetryHandlerSQ",
            $format(
                "dut.hasRetryErr=", fshow(dut.hasRetryErr),
                " should be true"
            )
        );
        cntrl.errFlushDone;

        retryHandleTestStateReg <= TEST_RETRY_RESET_QP;
        // $display("time=%0t:", $time, " set QP 2 ERR");
    endrule

    rule checkDestroyResp if (
        retryHandleTestStateReg == TEST_RETRY_RESET_QP
    );
        let qpDestroyResp <- cntrl.srvPort.response.get;
        immAssert(
            qpDestroyResp.successOrNot,
            "qpDestroyResp.successOrNot assertion @ mkTestRetryHandleRetryErrCase",
            $format(
                "qpDestroyResp.successOrNot=", fshow(qpDestroyResp.successOrNot),
                " should be true when qpDestroyResp=", fshow(qpDestroyResp)
            )
        );

        immAssert(
            cntrlStatus.comm.isReset,
            "cntrlStatus.comm.isReset assertion @ mkTestRetryHandleRetryErrCase",
            $format(
                "cntrlStatus.comm.isReset=", fshow(cntrlStatus.comm.isReset), " should be true"
                // " when qpModifyResp=", fshow(qpModifyResp)
            )
        );

        retryHandleTestStateReg <= TEST_RETRY_CREATE_QP;
        // $display("time=%0t:", $time, " check destroy QP response");
    endrule
endmodule
*/