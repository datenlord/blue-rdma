import DataTypes :: *;
import Headers :: *;
import Settings :: *;
import Utils :: *;

interface Controller;
    method Action initialize(
        QpType        qpType,
        RetryCnt      maxRnrCnt,
        RetryCnt      maxRetryCnt,
        TimeOutTimer  maxTimeOut,
        RnrTimer      minRnrTimer,
        PendingReqCnt pendingWorkReqNum,
        PendingReqCnt pendingRecvReqNum,
        Bool          sigAll,
        QPN           sqpn,
        QPN           dqpn,
        PKEY          pkey,
        QKEY          qkey,
        PMTU          pmtu,
        PSN           npsn,
        PSN           epsn
    );

    method Bool isErr();
    method Bool isInit();
    method Bool isRTR();
    method Bool isRTRorRTS();

    method QpState getQPS();
    // method Action setQPS(QpState qps);
    method Action setStateReset();
    // method Action setStateInit();
    method Action setStateRTR();
    method Action setStateRTS();
    method Action setStateSQD();
    method Action setStateErr();

    method QpType getQpType();
    // method Action setQpType(QpType qpType);

    method Bool retryExceedLimit(RetryReason retryReason);
    method Action decRetryCnt(RetryReason retryReason);
    method Action resetRetryCnt();
    method Bool getRetryPulse();
    method Action setRetryPulse(
        WorkReqID wrID,
        PSN retryStartPSN,
        Length retryWorkReqLen,
        ADDR retryWorkReqAddr,
        RetryReason retryReason
    );
    method Action setErrFlushDone();

    method PendingReqCnt getPendingWorkReqNum();
    // method Action setPendingWorkReqNum(PendingReqCnt cnt);
    method PendingReqCnt getPendingRecvReqNum();
    // method Action setPendingRecvReqNum(PendingReqCnt cnt);
    // method PendingReqCnt getPendingReadAtomicReqnumList();
    method Bool getSigAll();
    // method Action setSigAll(Bool segAll);

    method QPN getSQPN();
    // method Action setSQPN(QPN sqpn);
    method QPN getDQPN();
    // method Action setDQPN(QPN dqpn);
    method PKEY getPKEY();
    // method Action setPKEY(PKEY pkey);
    method QKEY getQKEY();
    // method Action setQKEY(QKEY qkey);
    method PMTU getPMTU();
    // method Action setPMTU(PMTU pmtu);
    method PSN getNPSN();
    method Action setNPSN(PSN psn);
    method PSN getEPSN();
    method Action setEPSN(PSN psn);
endinterface

module mkController(Controller);
    Reg#(QpState) stateReg <- mkReg(IBV_QPS_RESET);
    Reg#(QpType) qpTypeReg <- mkRegU;

    Reg#(RetryCnt)         rnrCntReg <- mkRegU;
    Reg#(RetryCnt)       retryCntReg <- mkRegU;
    Reg#(RetryCnt)      maxRnrCntReg <- mkRegU;
    Reg#(RetryCnt)    maxRetryCntReg <- mkRegU;
    Reg#(TimeOutTimer) maxTimeOutReg <- mkRegU;
    Reg#(RnrTimer)    minRnrTimerReg <- mkRegU;

    Reg#(Bool)          retryPulseReg <- mkRegU;
    Reg#(WorkReqID) retryWorkReqIdReg <- mkRegU;
    Reg#(PSN)        retryStartPsnReg <- mkRegU;
    Reg#(Length)   retryWorkReqLenReg <- mkRegU;
    Reg#(ADDR)    retryWorkReqAddrReg <- mkRegU;
    Reg#(RetryReason)  retryReasonReg <- mkRegU;
    Reg#(Bool)        errFlushDoneReg <- mkRegU;

    Reg#(PendingReqCnt) pendingWorkReqNumReg <- mkRegU;
    Reg#(PendingReqCnt) pendingRecvReqNumReg <- mkRegU;
    Reg#(Bool) sigAllReg <- mkRegU;
    // Reg#(PendingReqCnt) pendingReadAtomicReqNumList <- mkRegU;
    Reg#(QPN) sqpnReg <- mkRegU;
    Reg#(QPN) dqpnReg <- mkRegU;

    Reg#(PKEY) pkeyReg <- mkRegU;
    Reg#(QKEY) qkeyReg <- mkRegU;
    Reg#(PMTU) pmtuReg <- mkRegU;
    Reg#(PSN)  npsnReg <- mkRegU;
    Reg#(PSN)  epsnReg <- mkRegU;

    Bool qpInitialized = stateReg != IBV_QPS_RESET;

    rule clearRetryPulse if (qpInitialized && retryPulseReg);
        retryPulseReg <= False;
    endrule

    method Action initialize(
        QpType qpType,
        RetryCnt      maxRnrCnt,
        RetryCnt      maxRetryCnt,
        TimeOutTimer  maxTimeOut,
        RnrTimer      minRnrTimer,
        PendingReqCnt pendingWorkReqNum,
        PendingReqCnt pendingRecvReqNum,
        Bool          sigAll,
        QPN           sqpn,
        QPN           dqpn,
        PKEY          pkey,
        QKEY          qkey,
        PMTU          pmtu,
        PSN           npsn,
        PSN           epsn
    ) if (!qpInitialized);
        stateReg             <= IBV_QPS_INIT;

        qpTypeReg            <= qpType;
        rnrCntReg            <= maxRnrCnt;
        retryCntReg          <= maxRetryCnt;
        maxRnrCntReg         <= maxRnrCnt;
        maxRetryCntReg       <= maxRetryCnt;
        maxTimeOutReg        <= maxTimeOut;
        minRnrTimerReg       <= minRnrTimer;
        retryPulseReg        <= False;
        errFlushDoneReg      <= False;
        pendingWorkReqNumReg <= pendingWorkReqNum;
        pendingRecvReqNumReg <= pendingRecvReqNum;
        sigAllReg            <= sigAll;
        sqpnReg              <= sqpn;
        dqpnReg              <= dqpn;
        pkeyReg              <= pkey;
        qkeyReg              <= qkey;
        pmtuReg              <= pmtu;
        npsnReg              <= npsn;
        epsnReg              <= epsn;
    endmethod

    method Bool isErr()      if (qpInitialized) = stateReg == IBV_QPS_ERR;
    method Bool isInit()     if (qpInitialized) = stateReg == IBV_QPS_INIT;
    method Bool isRTR()      if (qpInitialized) = stateReg == IBV_QPS_RTR;
    method Bool isRTRorRTS() if (qpInitialized) = stateReg == IBV_QPS_RTR || stateReg == IBV_QPS_RTS;

    method QpState getQPS() = stateReg;
    // method Action setQPS(QpState qps) if (qpInitialized);
    //     stateReg <= qps;
    // endmethod

    method Action setStateReset() if (qpInitialized && stateReg == IBV_QPS_ERR && errFlushDoneReg);
        stateReg <= IBV_QPS_RESET;
        // errFlushDoneReg <= False;
    endmethod
    // method Action setStateInit();
    method Action setStateRTR() if (qpInitialized && stateReg == IBV_QPS_INIT);
        stateReg <= IBV_QPS_RTR;
    endmethod
    method Action setStateRTS() if (qpInitialized && stateReg == IBV_QPS_RTR);
        stateReg <= IBV_QPS_RTS;
    endmethod
    method Action setStateSQD() if (qpInitialized && stateReg == IBV_QPS_RTS);
        stateReg <= IBV_QPS_SQD;
    endmethod
    method Action setStateErr() if (qpInitialized);
        stateReg <= IBV_QPS_ERR;
    endmethod
    method QpType getQpType() if (qpInitialized) = qpTypeReg;
    // method Action setQpType(QpType qpType);
    //     qpTypeReg <= qpType;
    // endmethod

    method Bool retryExceedLimit(RetryReason retryReason) if (qpInitialized);
        return case (retryReason)
            RETRY_REASON_RNR      : isZero(rnrCntReg);
            RETRY_REASON_SEQ_ERR  ,
            RETRY_REASON_IMPLICIT ,
            RETRY_REASON_TIME_OUT : isZero(retryCntReg);
            // RETRY_REASON_NOT_RETRY: False;
            default               : False;
        endcase;
    endmethod
    method Action decRetryCnt(RetryReason retryReason) if (qpInitialized);
        case (retryReason)
            RETRY_REASON_SEQ_ERR, RETRY_REASON_IMPLICIT, RETRY_REASON_TIME_OUT:
                if (maxRetryCntReg != fromInteger(valueOf(INFINITE_RETRY))) begin
                    if (!isZero(retryCntReg)) begin
                        retryCntReg <= retryCntReg - 1;
                    end
                end
            RETRY_REASON_RNR:
                if (maxRnrCntReg != fromInteger(valueOf(INFINITE_RETRY))) begin
                    if (!isZero(rnrCntReg)) begin
                        rnrCntReg <= rnrCntReg - 1;
                    end
                end
            default: begin end
        endcase
    endmethod
    method Action resetRetryCnt() if (qpInitialized);
        retryCntReg <= maxRetryCntReg;
        rnrCntReg   <= maxRnrCntReg;
    endmethod

    method Bool getRetryPulse() if (qpInitialized) = retryPulseReg;
    method Action setRetryPulse(
        WorkReqID   wrID,
        PSN         retryStartPSN,
        Length      retryWorkReqLen,
        ADDR        retryWorkReqAddr,
        RetryReason retryReason
    ) if (qpInitialized && !retryPulseReg);
        retryPulseReg       <= True;
        retryWorkReqIdReg   <= wrID;
        retryStartPsnReg    <= retryStartPSN;
        retryWorkReqLenReg  <= retryWorkReqLen;
        retryWorkReqAddrReg <= retryWorkReqAddr;
        retryReasonReg      <= retryReason;
    endmethod
    method Action setErrFlushDone if (qpInitialized && stateReg == IBV_QPS_ERR && !errFlushDoneReg);
        errFlushDoneReg <= True;
    endmethod

    method PendingReqCnt getPendingWorkReqNum() if (qpInitialized) = pendingWorkReqNumReg;
    // method Action setPendingWorkReqNum(PendingReqCnt cnt);
    //     pendingWorkReqNumReg <= cnt;
    // endmethod
    method PendingReqCnt getPendingRecvReqNum() if (qpInitialized) = pendingRecvReqNumReg;
    // method Action setPendingRecvReqNum(PendingReqCnt cnt);
    //     pendingRecvReqNumReg <= cnt;
    // endmethod

    method Bool getSigAll() if (qpInitialized) = sigAllReg;
    // method Action setSigAll(Bool sigAll);
    //     sigAllReg <= sigAll;
    // endmethod

    method PSN getSQPN() if (qpInitialized) = sqpnReg;
    // method Action setSQPN(PSN sqpn);
    //     sqpnReg <= sqpn;
    // endmethod
    method PSN getDQPN() if (qpInitialized) = dqpnReg;
    // method Action setDQPN(PSN dqpn);
    //     dqpnReg <= dqpn;
    // endmethod

    method PKEY getPKEY() if (qpInitialized) = pkeyReg;
    // method Action setPKEY(PKEY pkey);
    //     pkeyReg <= pkey;
    // endmethod
    method QKEY getQKEY() if (qpInitialized) = qkeyReg;
    // method Action setQKEY(QKEY qkey);
    //     qkeyReg <= qkey;
    // endmethod
    method PMTU getPMTU() if (qpInitialized) = pmtuReg;
    // method Action setPMTU(PMTU pmtu);
    //     pmtuReg <= pmtu;
    // endmethod
    method PSN getNPSN() if (qpInitialized) = npsnReg;
    method Action setNPSN(PSN psn);
        npsnReg <= psn;
    endmethod
    method PSN getEPSN() if (qpInitialized) = epsnReg;
    method Action setEPSN(PSN psn);
        epsnReg <= psn;
    endmethod
endmodule
