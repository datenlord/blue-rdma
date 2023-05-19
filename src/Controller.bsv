import ClientServer :: *;
import FIFOF :: *;

import DataTypes :: *;
import Headers :: *;
import Settings :: *;
import PrimUtils :: *;
import Utils :: *;

typedef Bit#(1) Epoch;

typedef enum {
    REQ_QP_CREATE,
    REQ_QP_DESTROY,
    REQ_QP_MODIFY,
    REQ_QP_QUERY
} QpReqType deriving(Bits, Eq, FShow);

typedef struct {
    QpReqType       qpReqType;
    HandlerPD       pdHandler;
    QPN             qpn;
    QpAttrMaskFlag qpAttrMask;
    QpAttr          qpAttr;
    QpInitAttr      qpInitAttr;
} ReqQP deriving(Bits, FShow);

typedef struct {
    Bool       successOrNot;
    QPN        qpn;
    HandlerPD  pdHandler;
    QpAttr     qpAttr;
    QpInitAttr qpInitAttr;
} RespQP deriving(Bits, FShow);

typedef Server#(ReqQP, RespQP) SrvPortQP;

interface ContextRQ;
    method PermCheckInfo getPermCheckInfo();
    method Action        setPermCheckInfo(PermCheckInfo permCheckInfo);
    method Length        getTotalDmaWriteLen();
    method Action        setTotalDmaWriteLen(Length totalDmaWriteLen);
    method Length        getRemainingDmaWriteLen();
    method Action        setRemainingDmaWriteLen(Length remainingDmaWriteLen);
    method ADDR          getNextDmaWriteAddr();
    method Action        setNextDmaWriteAddr(ADDR nextDmaWriteAddr);
    method PktNum        getSendWriteReqPktNum();
    method Action        setSendWriteReqPktNum(PktNum sendWriteReqPktNum);
    method RdmaOpCode    getPreReqOpCode();
    method Action        setPreReqOpCode(RdmaOpCode preOpCode);
    // method PendingReqCnt getCoalesceWorkReqCnt();
    // method Action        setCoalesceWorkReqCnt(PendingReqCnt coalesceWorkReqCnt);
    // method PendingReqCnt getPendingDestReadAtomicReqCnt();
    // method Action        setPendingDestReadAtomicReqCnt(PendingReqCnt pendingDestReadAtomicReqCnt);
    method Epoch         getEpoch();
    method Action        incEpoch();
    method MSN           getMSN();
    method Action        setMSN(MSN msn);
    method Bool          getIsRespPktNumZero();
    method PktNum        getRespPktNum();
    method Action        setRespPktNum(PktNum respPktNum);
    method PSN           getCurRespPSN();
    method Action        setCurRespPSN(PSN curRespPsn);
    method PSN           getEPSN();
    method Action        setEPSN(PSN psn);
    method Action        restorePreReqOpCodeAndEPSN(RdmaOpCode preOpCode, PSN psn);
    // method Action        restorePreReqOpCode(RdmaOpCode preOpCode);
    // method Action        restoreEPSN(PSN psn);
endinterface

interface Controller;
    interface SrvPortQP srvPort;
    interface ContextRQ contextRQ;

    method Bool isERR();
    method Bool isInit();
    method Bool isReset();
    method Bool isRTR();
    method Bool isRTS();
    method Bool isNonErr();
    method Bool isSQD();

    method QpState getQPS();
    method Action setStateErr();
    method Action errFlushDone();

    method QpType getQpType();
    method FlagsType#(MemAccessTypeFlag) getAccessFlags();

    method RetryCnt getMaxRnrCnt();
    method RetryCnt getMaxRetryCnt();
    method TimeOutTimer getMaxTimeOut();
    method RnrTimer getMinRnrTimer();

    method PendingReqCnt getPendingWorkReqNum();
    method PendingReqCnt getPendingRecvReqNum();
    method PendingReqCnt getPendingReadAtomicReqNum();
    method PendingReqCnt getPendingDestReadAtomicReqNum();
    method Bool getSigAll();

    method QPN getSQPN();
    method QPN getDQPN();
    method PKEY getPKEY();
    method QKEY getQKEY();
    method PMTU getPMTU();
    method PSN getNPSN();
    method Action setNPSN(PSN psn);
endinterface

module mkController(Controller);
    FIFOF#(ReqQP)   reqQ <- mkFIFOF;
    FIFOF#(RespQP) respQ <- mkFIFOF;

    // QP Attributes related
    Reg#(QpState) stateReg <- mkReg(IBV_QPS_RESET);
    Reg#(QpType) qpTypeReg <- mkRegU;

    Reg#(RetryCnt)      maxRnrCntReg <- mkRegU;
    Reg#(RetryCnt)    maxRetryCntReg <- mkRegU;
    Reg#(TimeOutTimer) maxTimeOutReg <- mkRegU;
    Reg#(RnrTimer)    minRnrTimerReg <- mkRegU;

    Reg#(Bool)   errFlushDoneReg <- mkRegU;
    Reg#(Bool) setStateErrReg[2] <- mkCReg(2, False);

    Reg#(Maybe#(QpState)) nextStateReg[2] <- mkCReg(2, tagged Invalid);

    // TODO: support QP access check
    Reg#(FlagsType#(MemAccessTypeFlag)) qpAccessFlagsReg <- mkRegU;
    // TODO: support max WR/RR pending number check
    Reg#(PendingReqCnt) pendingWorkReqNumReg <- mkRegU;
    Reg#(PendingReqCnt) pendingRecvReqNumReg <- mkRegU;
    // TODO: support max read/atomic pending requests check
    Reg#(PendingReqCnt)     pendingReadAtomicReqNumReg <- mkRegU;
    Reg#(PendingReqCnt) pendingDestReadAtomicReqNumReg <- mkRegU;
    // TODO: support SG
    Reg#(ScatterGatherElemCnt) sendScatterGatherElemCntReg <- mkRegU;
    Reg#(ScatterGatherElemCnt) recvScatterGatherElemCntReg <- mkRegU;
    // TODO: support inline data
    Reg#(InlineDataSize)       inlineDataSizeReg <- mkRegU;

    Reg#(Bool) sqSigAllReg <- mkRegU;
    Reg#(QPN) sqpnReg <- mkRegU;
    Reg#(QPN) dqpnReg <- mkRegU;

    Reg#(PKEY) pkeyReg <- mkRegU;
    Reg#(QKEY) qkeyReg <- mkRegU;
    Reg#(PMTU) pmtuReg <- mkRegU;
    Reg#(PSN)  npsnReg <- mkRegU;
    // End QP attributes related

    Bool inited = stateReg != IBV_QPS_RESET;

    // ContextRQ related
    Reg#(PermCheckInfo) permCheckInfoReg <- mkRegU;
    Reg#(Length)     totalDmaWriteLenReg <- mkRegU;
    Reg#(Length) remainingDmaWriteLenReg <- mkRegU;
    Reg#(ADDR)       nextDmaWriteAddrReg <- mkRegU;
    Reg#(PktNum)   sendWriteReqPktNumReg <- mkRegU; // TODO: remove it
    Reg#(RdmaOpCode)  preReqOpCodeReg[2] <- mkCReg(2, SEND_ONLY);

    // Reg#(PendingReqCnt) coalesceWorkReqCntReg <- mkRegU;
    // Reg#(PendingReqCnt) pendingDestReadAtomicReqCntReg <- mkRegU;

    Reg#(Epoch) epochReg <- mkReg(0);
    Reg#(MSN)     msnReg <- mkReg(0);

    Reg#(Bool) isRespPktNumZeroReg <- mkRegU;
    Reg#(PktNum)     respPktNumReg <- mkRegU;
    Reg#(PSN)        curRespPsnReg <- mkRegU;
    Reg#(PSN)           epsnReg[2] <- mkCRegU(2);

    FIFOF#(Tuple2#(RdmaOpCode, PSN)) restoreQ <- mkFIFOF;
    // End ContextRQ related

    (* no_implicit_conditions, fire_when_enabled *)
    rule resetAndClear if (stateReg == IBV_QPS_RESET);
        preReqOpCodeReg[0] <= SEND_ONLY;
        epochReg <= 0;
        msnReg   <= 0;
        restoreQ.clear;
    endrule

    (* fire_when_enabled *)
    rule restore if (stateReg == IBV_QPS_RTR || stateReg == IBV_QPS_RTS || stateReg == IBV_QPS_SQD);
        let { preOpCode, epsn } = restoreQ.first;
        restoreQ.deq;

        preReqOpCodeReg[1] <= preOpCode;
        epsnReg[1] <= epsn;
    endrule

    (* no_implicit_conditions, fire_when_enabled *)
    rule canonicalize;
        immAssert(
            stateReg != IBV_QPS_UNKNOWN,
            "unknown state assertion @ mkController",
            $format("stateReg=", fshow(stateReg), " should not be IBV_QPS_UNKNOWN")
        );

        let nextState = stateReg;
        if (nextStateReg[1] matches tagged Valid .setState) begin
            nextState = setState;
        end
        // IBV_QPS_RESET has higher priority than IBV_QPS_ERR,
        // IBV_QPS_ERR has higher priority than other states.
        if (nextState != IBV_QPS_RESET && setStateErrReg[1]) begin
            nextState = IBV_QPS_ERR;
        end

        stateReg <= nextState;
        nextStateReg[1] <= tagged Invalid;
        setStateErrReg[1] <= False;
        // $display("time=%0t:", $time, " sqpnReg=%h, stateReg=", sqpnReg, fshow(stateReg));
    endrule

    // TODO: support full functionality of modify_qp()
    rule handleSrvPort4NonErrState if (
        stateReg == IBV_QPS_RTS ||
        stateReg == IBV_QPS_RTR ||
        stateReg == IBV_QPS_SQD
    );
        let qpReq = reqQ.first;
        reqQ.deq;

        let qpResp = RespQP {
            successOrNot: False,
            qpn         : qpReq.qpn,
            pdHandler   : qpReq.pdHandler,
            qpAttr      : qpReq.qpAttr,
            qpInitAttr  : qpReq.qpInitAttr
        };

        if (qpReq.qpReqType == REQ_QP_MODIFY) begin
            immAssert(
                qpReq.qpn == sqpnReg,
                "SQPN assertion @ mkController",
                $format("qpReq.qpn=%h should == sqpnReg=%h", qpReq.qpn, sqpnReg)
            );
            nextStateReg[0] <= tagged Valid qpReq.qpAttr.qpState;
            qpResp.successOrNot = True;
        end
        else begin
            immFail(
                "modifyNonErrState @ mkController",
                $format(
                    "qpReq.qpReqType=", fshow(qpReq.qpReqType),
                    " should be REQ_QP_MODIFY, when stateReg=", fshow(stateReg),
                    " sqpnReg=%h, qpReq=", sqpnReg, fshow(qpReq)
                )
            );
        end
        respQ.enq(qpResp);
    endrule

    rule handleSrvPort4AbnormalState if (
        stateReg == IBV_QPS_RESET ||
        stateReg == IBV_QPS_INIT  ||
        stateReg == IBV_QPS_ERR   ||
        stateReg == IBV_QPS_SQE
    );
        let qpReq = reqQ.first;
        reqQ.deq;

        let qpResp = RespQP {
            successOrNot: False,
            qpn         : qpReq.qpn,
            pdHandler   : qpReq.pdHandler,
            qpAttr      : qpReq.qpAttr,
            qpInitAttr  : qpReq.qpInitAttr
        };

        if (qpReq.qpReqType != REQ_QP_CREATE) begin
            immAssert(
                qpReq.qpn == sqpnReg,
                "SQPN assertion @ mkController",
                $format("qpReq.qpn=%h should == sqpnReg=%h", qpReq.qpn, sqpnReg)
            );
        end

        case (qpReq.qpReqType)
            REQ_QP_CREATE: begin
                sqpnReg                        <= qpReq.qpn;
                qpTypeReg                      <= qpReq.qpInitAttr.qpType;
                sqSigAllReg                    <= qpReq.qpInitAttr.sqSigAll;

                qpResp.successOrNot             = True;
                qpResp.qpAttr.curQpState        = stateReg;
                qpResp.qpAttr.sqDraining        = stateReg == IBV_QPS_SQD;
            end
            REQ_QP_DESTROY: begin
                nextStateReg[0]                <= tagged Valid IBV_QPS_RESET;

                qpResp.successOrNot             = True;
                qpResp.qpAttr.curQpState        = stateReg;
                qpResp.qpAttr.sqDraining        = stateReg == IBV_QPS_SQD;
            end
            REQ_QP_MODIFY: begin
                // TODO: modify QP by QpAttrMaskFlag
                nextStateReg[0]                <= tagged Valid qpReq.qpAttr.qpState;
                // qpTypeReg                      <= qpType;
                maxRnrCntReg                   <= qpReq.qpAttr.rnrRetry;
                maxRetryCntReg                 <= qpReq.qpAttr.retryCnt;
                maxTimeOutReg                  <= qpReq.qpAttr.timeout;
                minRnrTimerReg                 <= qpReq.qpAttr.minRnrTimer;
                // errFlushDoneReg                <= True;
                qpAccessFlagsReg               <= qpReq.qpAttr.qpAccessFlags;
                pendingWorkReqNumReg           <= qpReq.qpAttr.cap.maxSendWR;
                pendingRecvReqNumReg           <= qpReq.qpAttr.cap.maxRecvWR;
                pendingReadAtomicReqNumReg     <= qpReq.qpAttr.maxReadAtomic;
                pendingDestReadAtomicReqNumReg <= qpReq.qpAttr.maxDestReadAtomic;
                // coalesceWorkReqCntReg           <= qpReq.qpAttr.cap.maxSendWR;
                // pendingDestReadAtomicReqCntReg <= qpReq.qpAttr.maxDestReadAtomic;
                // sqSigAllReg                    <= sqSigAll;
                dqpnReg                        <= qpReq.qpAttr.dqpn;
                pkeyReg                        <= qpReq.qpAttr.pkeyIndex;
                qkeyReg                        <= qpReq.qpAttr.qkey;
                pmtuReg                        <= qpReq.qpAttr.pmtu;
                npsnReg                        <= qpReq.qpAttr.sqPSN;
                epsnReg[0]                     <= qpReq.qpAttr.rqPSN;

                qpResp.successOrNot             = True;
                qpResp.qpAttr.curQpState        = stateReg;
                qpResp.qpAttr.sqDraining        = stateReg == IBV_QPS_SQD;
            end
            REQ_QP_QUERY : begin
                qpResp.qpAttr.curQpState        = stateReg;
                qpResp.qpAttr.pmtu              = pmtuReg;
                qpResp.qpAttr.qkey              = qkeyReg;
                qpResp.qpAttr.rqPSN             = epsnReg[0];
                qpResp.qpAttr.sqPSN             = npsnReg;
                qpResp.qpAttr.dqpn              = dqpnReg;
                qpResp.qpAttr.qpAccessFlags     = qpAccessFlagsReg;
                qpResp.qpAttr.cap.maxSendWR     = pendingWorkReqNumReg;
                qpResp.qpAttr.cap.maxRecvWR     = pendingRecvReqNumReg;
                qpResp.qpAttr.cap.maxSendSGE    = sendScatterGatherElemCntReg;
                qpResp.qpAttr.cap.maxRecvSGE    = recvScatterGatherElemCntReg;
                qpResp.qpAttr.cap.maxInlineData = inlineDataSizeReg;
                qpResp.qpAttr.pkeyIndex         = pkeyReg;
                qpResp.qpAttr.sqDraining        = stateReg == IBV_QPS_SQD;
                qpResp.qpAttr.maxReadAtomic     = pendingReadAtomicReqNumReg;
                qpResp.qpAttr.maxDestReadAtomic = pendingDestReadAtomicReqNumReg;
                qpResp.qpAttr.minRnrTimer       = minRnrTimerReg;
                qpResp.qpAttr.timeout           = maxTimeOutReg;
                qpResp.qpAttr.retryCnt          = maxRetryCntReg;
                qpResp.qpAttr.rnrRetry          = maxRnrCntReg;

                qpResp.qpInitAttr.qpType        = qpTypeReg;
                qpResp.qpInitAttr.sqSigAll      = sqSigAllReg;

                qpResp.successOrNot = True;
            end
            default: begin
                immFail(
                    "unreachible case @ mkController",
                    $format(
                        "request QPN=%h", qpReq.qpn,
                        "qpReqType=", fshow(qpReq.qpReqType)
                    )
                );
            end
        endcase

        // $display(
        //     "time=%0t: controller receives qpReq=", $time, fshow(qpReq),
        //     " and generates qpResp=", fshow(qpResp)
        // );
        respQ.enq(qpResp);
    endrule

    method Bool isERR()    = stateReg == IBV_QPS_ERR;
    method Bool isInit()   = stateReg == IBV_QPS_INIT;
    method Bool isNonErr() = stateReg == IBV_QPS_RTR || stateReg == IBV_QPS_RTS || stateReg == IBV_QPS_SQD;
    method Bool isReset()  = stateReg == IBV_QPS_RESET;
    method Bool isRTR()    = stateReg == IBV_QPS_RTR;
    method Bool isRTS()    = stateReg == IBV_QPS_RTS;
    method Bool isSQD()    = stateReg == IBV_QPS_SQD;

    method QpState getQPS() = stateReg;

    // method Action setStateReset() if (inited && stateReg == IBV_QPS_ERR && errFlushDoneReg);
    //     stateReg <= IBV_QPS_RESET;
    // endmethod
    // method Action setStateInit();
    // method Action setStateRTR() if (inited && stateReg == IBV_QPS_INIT);
    //     stateReg <= IBV_QPS_RTR;
    // endmethod
    // method Action setStateRTS() if (inited && stateReg == IBV_QPS_RTR);
    //     stateReg <= IBV_QPS_RTS;
    // endmethod
    // method Action setStateSQD() if (inited && stateReg == IBV_QPS_RTS);
    //     stateReg <= IBV_QPS_SQD;
    // endmethod
    method Action setStateErr() if (inited);
        // stateReg <= IBV_QPS_ERR;
        setStateErrReg[0] <= True;
        errFlushDoneReg <= False;
    endmethod
    method Action errFlushDone if (inited && stateReg == IBV_QPS_ERR && !errFlushDoneReg);
        errFlushDoneReg <= True;
    endmethod

    method QpType getQpType() if (inited) = qpTypeReg;
    method FlagsType#(MemAccessTypeFlag) getAccessFlags() if (inited) = qpAccessFlagsReg;

    method RetryCnt      getMaxRnrCnt() if (inited) = maxRnrCntReg;
    method RetryCnt    getMaxRetryCnt() if (inited) = maxRetryCntReg;
    method TimeOutTimer getMaxTimeOut() if (inited) = maxTimeOutReg;
    method RnrTimer    getMinRnrTimer() if (inited) = minRnrTimerReg;

    method PendingReqCnt getPendingWorkReqNum() if (inited) = pendingWorkReqNumReg;
    method PendingReqCnt getPendingRecvReqNum() if (inited) = pendingRecvReqNumReg;
    method PendingReqCnt     getPendingReadAtomicReqNum() if (inited) = pendingReadAtomicReqNumReg;
    method PendingReqCnt getPendingDestReadAtomicReqNum() if (inited) = pendingDestReadAtomicReqNumReg;

    method Bool getSigAll() if (inited) = sqSigAllReg;
    method PSN  getSQPN()   if (inited) = sqpnReg;
    method PSN  getDQPN()   if (inited) = dqpnReg;
    method PKEY getPKEY()   if (inited) = pkeyReg;
    method QKEY getQKEY()   if (inited) = qkeyReg;
    method PMTU getPMTU()   if (inited) = pmtuReg;
    method PSN  getNPSN()   if (inited) = npsnReg;

    method Action setNPSN(PSN psn);
        npsnReg <= psn;
    endmethod

    interface srvPort = toGPServer(reqQ, respQ);

    interface contextRQ = interface ContextRQ;
        method PermCheckInfo getPermCheckInfo() if (inited) = permCheckInfoReg;
        method Action        setPermCheckInfo(PermCheckInfo permCheckInfo) if (inited);
            permCheckInfoReg <= permCheckInfo;
        endmethod

        method Length getTotalDmaWriteLen() if (inited) = totalDmaWriteLenReg;
        method Action setTotalDmaWriteLen(Length totalDmaWriteLen) if (inited);
            totalDmaWriteLenReg <= totalDmaWriteLen;
        endmethod

        method Length getRemainingDmaWriteLen() if (inited) = remainingDmaWriteLenReg;
        method Action setRemainingDmaWriteLen(Length remainingDmaWriteLen) if (inited);
            remainingDmaWriteLenReg <= remainingDmaWriteLen;
        endmethod

        method ADDR   getNextDmaWriteAddr() if (inited) = nextDmaWriteAddrReg;
        method Action setNextDmaWriteAddr(ADDR nextDmaWriteAddr) if (inited);
            nextDmaWriteAddrReg <= nextDmaWriteAddr;
        endmethod

        method PktNum getSendWriteReqPktNum() if (inited) = sendWriteReqPktNumReg;
        method Action setSendWriteReqPktNum(PktNum sendWriteReqPktNum) if (inited);
            sendWriteReqPktNumReg <= sendWriteReqPktNum;
        endmethod

        method RdmaOpCode getPreReqOpCode() if (inited) = preReqOpCodeReg[0];
        method Action     setPreReqOpCode(RdmaOpCode preOpCode) if (inited);
            preReqOpCodeReg[0] <= preOpCode;
        endmethod
        // method Action     restorePreReqOpCode(RdmaOpCode preOpCode) if (inited);
        //     preReqOpCodeReg[1] <= preOpCode;
        // endmethod

        // method PendingReqCnt getCoalesceWorkReqCnt() if (inited) = coalesceWorkReqCntReg;
        // method Action        setCoalesceWorkReqCnt(PendingReqCnt coalesceWorkReqCnt) if (inited);
        //     coalesceWorkReqCntReg <= coalesceWorkReqCnt;
        // endmethod
        // method PendingReqCnt getPendingDestReadAtomicReqCnt() if (inited) = pendingDestReadAtomicReqCntReg;
        // method Action        setPendingDestReadAtomicReqCnt(
        //     PendingReqCnt pendingDestReadAtomicReqCnt
        // ) if (inited);
        //     pendingDestReadAtomicReqCntReg <= pendingDestReadAtomicReqCnt;
        // endmethod
        method Epoch  getEpoch() = epochReg; // TODO: add inited condition
        // method Epoch  getEpoch() if (inited) = epochReg;
        method Action incEpoch() if (inited);
            epochReg <= ~epochReg;
        endmethod

        method MSN    getMSN() if (inited) = msnReg;
        method Action setMSN(MSN msn) if (inited);
            msnReg <= msn;
        endmethod

        method Bool getIsRespPktNumZero() if (inited) = isRespPktNumZeroReg;
        method PktNum getRespPktNum() if (inited) = respPktNumReg;
        method Action setRespPktNum(PktNum respPktNum) if (inited);
            respPktNumReg <= respPktNum;
            isRespPktNumZeroReg <= isZero(respPktNum);
        endmethod

        method PSN    getCurRespPSN() if (inited) = curRespPsnReg;
        method Action setCurRespPSN(PSN curRespPsn) if (inited);
            curRespPsnReg <= curRespPsn;
        endmethod

        method PSN    getEPSN() if (inited) = epsnReg[0];
        method Action setEPSN(PSN psn) if (inited);
            epsnReg[0] <= psn;
        endmethod
        // method Action restoreEPSN(PSN psn) if (inited);
        //     epsnReg[1] <= psn;
        // endmethod

        method Action restorePreReqOpCodeAndEPSN(
            RdmaOpCode preOpCode, PSN psn
        ) if (inited);
            restoreQ.enq(tuple2(preOpCode, psn));
        endmethod
    endinterface;
endmodule
