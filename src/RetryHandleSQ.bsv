import FIFOF :: *;
import PAClib :: *;

import Assertions :: *;
import Controller :: *;
import DataTypes :: *;
import Headers :: *;
import ScanFIFOF :: *;
// import Settings :: *;
import Utils :: *;

interface RetryHandleSQ;
    method Bool retryExcLimit(RetryReason retryReason);
    method Bool isRetryErrState();
    method Bool isRetryDone();
    method Action resetRetryCnt();
    method Action notifyRetry(
        WorkReqID   wrID,
        PSN         retryStartPSN,
        RetryReason retryReason,
        RnrTimer    retryRnrTimer
    );
    interface PipeOut#(PendingWorkReq) pendingWorkReqPipeOut;
endinterface

typedef enum {
    RETRY_ST_RNR_WAIT,
    RETRY_ST_PARTIAL_RETRY_WR,
    RETRY_ST_FULL_RETRY_WR,
    RETRY_ST_RETRY_LIMIT_EXC,
    RETRY_ST_NOT_RETRY
} RetryHandleState deriving(Bits, Eq);

// TODO: handle RNR waiting
// TODO: implement timeout retry
module mkRetryHandleSQ#(
    Controller cntrl,
    PendingWorkReqBuf pendingWorkReqBuf
    // PipeOut#(WorkReq) workReqPipeIn
)(RetryHandleSQ);
    FIFOF#(PendingWorkReq) retryPendingWorkReqOutQ <- mkFIFOF;

    Reg#(WorkReqID) retryWorkReqIdReg <- mkRegU;
    Reg#(PSN)        retryStartPsnReg <- mkRegU;
    Reg#(PSN)              psnDiffReg <- mkRegU;
    Reg#(RetryReason)  retryReasonReg <- mkRegU;
    Reg#(RnrTimer)   retryRnrTimerReg <- mkRegU;
    Reg#(RetryCnt)          rnrCntReg <- mkRegU;
    Reg#(RetryCnt)        retryCntReg <- mkRegU;

    Reg#(RetryHandleState) retryHandleStateReg <- mkReg(RETRY_ST_NOT_RETRY);

    let notRetrying = retryHandleStateReg == RETRY_ST_NOT_RETRY;
    // let newPendingWorkReqPipeOut <- mkNewPendingWorkReqPipeOut(workReqPipeIn);
    // let retryPendingWorkReqPipeOut = scanQ2PipeOut(pendingWorkReqBuf.scanQ);
    let retryPendingWorkReqPipeOut = convertFifo2PipeOut(retryPendingWorkReqOutQ);
    // let resultPipeOut <- mkMuxPipeOut(
    //     notRetrying,
    //     newPendingWorkReqPipeOut,
    //     retryPendingWorkReqPipeOut
    // );

    function Bool retryCntExceedLimit(RetryReason retryReason);
        return case (retryReason)
            RETRY_REASON_RNR      : isZero(rnrCntReg);
            RETRY_REASON_SEQ_ERR  ,
            RETRY_REASON_IMPLICIT ,
            RETRY_REASON_TIME_OUT : isZero(retryCntReg);
            // RETRY_REASON_NOT_RETRY: False;
            default               : False;
        endcase;
    endfunction

    function Action decRetryCnt(RetryReason retryReason);
        action
            case (retryReason)
                RETRY_REASON_SEQ_ERR, RETRY_REASON_IMPLICIT, RETRY_REASON_TIME_OUT: begin
                    if (cntrl.getMaxRetryCnt != fromInteger(valueOf(INFINITE_RETRY))) begin
                        if (!isZero(retryCntReg)) begin
                            retryCntReg <= retryCntReg - 1;
                        end
                    end
                end
                RETRY_REASON_RNR: begin
                    if (cntrl.getMaxRnrCnt != fromInteger(valueOf(INFINITE_RETRY))) begin
                        if (!isZero(rnrCntReg)) begin
                            rnrCntReg <= rnrCntReg - 1;
                        end
                    end
                end
                default: begin end
            endcase
        endaction
    endfunction

    rule rnrWait if (cntrl.isRTS && retryHandleStateReg == RETRY_ST_RNR_WAIT);
        let curRetryWR = pendingWorkReqBuf.scanIfc.current;
        dynAssert(
            retryWorkReqIdReg == curRetryWR.wr.id,
            "retryWorkReqIdReg assertion @ mkRespHandleSQ",
            $format(
                "retryWorkReqIdReg=%h should == curRetryWR.wr.id=%h",
                retryWorkReqIdReg, curRetryWR.wr.id
            )
        );

        let startPSN = unwrapMaybe(curRetryWR.startPSN);
        let wrLen    = curRetryWR.wr.len;
        let laddr    = curRetryWR.wr.laddr;
        let raddr    = curRetryWR.wr.raddr;
        psnDiffReg  <= calcPsnDiff(retryStartPsnReg, startPSN);

        let rnrTimer = cntrl.getMinRnrTimer;
        if (retryReasonReg == RETRY_REASON_RNR) begin
            rnrTimer = retryRnrTimerReg > rnrTimer ? retryRnrTimerReg : rnrTimer;
        end
        // TODO: wait for RNR timer out
        retryHandleStateReg <= RETRY_ST_PARTIAL_RETRY_WR;
    endrule

    rule partialRetryWR if (cntrl.isRTS && retryHandleStateReg == RETRY_ST_PARTIAL_RETRY_WR);
        let curRetryWR = pendingWorkReqBuf.scanIfc.current;
        pendingWorkReqBuf.scanIfc.scanNext;

        let wrLen    = curRetryWR.wr.len;
        let laddr    = curRetryWR.wr.laddr;
        let raddr    = curRetryWR.wr.raddr;
        let retryWorkReqLen = lenSubtractPsnMultiplyPMTU(wrLen, psnDiffReg, cntrl.getPMTU);
        let retryWorkReqLocalAddr = addrAddPsnMultiplyPMTU(laddr, psnDiffReg, cntrl.getPMTU);
        let retryWorkReqRmtAddr = addrAddPsnMultiplyPMTU(raddr, psnDiffReg, cntrl.getPMTU);
        curRetryWR.startPSN = tagged Valid retryStartPsnReg;
        curRetryWR.wr.len = retryWorkReqLen;
        curRetryWR.wr.laddr = retryWorkReqLocalAddr;
        curRetryWR.wr.raddr = retryWorkReqRmtAddr;

        retryPendingWorkReqOutQ.enq(curRetryWR);
        retryHandleStateReg <= RETRY_ST_FULL_RETRY_WR;
    endrule

    rule fullRetryWR if (cntrl.isRTS && retryHandleStateReg == RETRY_ST_FULL_RETRY_WR);
        if (pendingWorkReqBuf.scanIfc.scanDone) begin
            retryHandleStateReg <= RETRY_ST_NOT_RETRY;
        end
        else begin
            let curRetryWR = pendingWorkReqBuf.scanIfc.current;
            pendingWorkReqBuf.scanIfc.scanNext;
            retryPendingWorkReqOutQ.enq(curRetryWR);
        end
    endrule

    method Bool retryExcLimit(RetryReason retryReason) = retryCntExceedLimit(retryReason);
    method Bool isRetryErrState() = retryHandleStateReg == RETRY_ST_RETRY_LIMIT_EXC;
    method Bool isRetryDone() = retryHandleStateReg == RETRY_ST_NOT_RETRY;

    method Action resetRetryCnt() if (cntrl.isRTS && notRetrying);
        retryCntReg <= cntrl.getMaxRetryCnt;
        rnrCntReg   <= cntrl.getMaxRnrCnt;
    endmethod

    method Action notifyRetry(
        WorkReqID   wrID,
        PSN         retryStartPSN,
        RetryReason retryReason,
        RnrTimer    retryRnrTimer
    ) if (cntrl.isRTS && notRetrying);
        if (retryCntExceedLimit(retryReason)) begin
            retryHandleStateReg <= RETRY_ST_RETRY_LIMIT_EXC;
        end
        else begin
            retryHandleStateReg <= RETRY_ST_RNR_WAIT;
            retryWorkReqIdReg   <= wrID;
            retryStartPsnReg    <= retryStartPSN;
            retryReasonReg      <= retryReason;
            retryRnrTimerReg    <= retryRnrTimer;
            pendingWorkReqBuf.scanIfc.scanStart;
            decRetryCnt(retryReason);
        end
    endmethod

    interface pendingWorkReqPipeOut = retryPendingWorkReqPipeOut;
    // interface pendingWorkReqPipeOut = resultPipeOut;
endmodule
