import ClientServer :: *;
import FIFOF :: *;

import DataTypes :: *;
import Headers :: *;
import Settings :: *;
import PrimUtils :: *;
import Utils :: *;

// TODO: support port_num
function FlagsType#(QpAttrMaskFlag) getReset2InitRequiredAttr();
    FlagsType#(QpAttrMaskFlag) requiredFlags =
        enum2Flag(IBV_QP_STATE)      |
        enum2Flag(IBV_QP_PKEY_INDEX) |
        // enum2Flag(IBV_QP_PORT)       |
        enum2Flag(IBV_QP_ACCESS_FLAGS);

    return requiredFlags;
endfunction

// TODO: support ah_attr
function FlagsType#(QpAttrMaskFlag) getInit2RtrRequiredAttr();
    FlagsType#(QpAttrMaskFlag) requiredFlags =
        enum2Flag(IBV_QP_STATE)              |
        // enum2Flag(IBV_QP_AV)                 |
        enum2Flag(IBV_QP_PATH_MTU)           |
        enum2Flag(IBV_QP_DEST_QPN)           |
        enum2Flag(IBV_QP_RQ_PSN)             |
        enum2Flag(IBV_QP_MAX_DEST_RD_ATOMIC) |
        enum2Flag(IBV_QP_MIN_RNR_TIMER);

    return requiredFlags;
endfunction

function FlagsType#(QpAttrMaskFlag) getRtr2RtsRequiredAttr();
    FlagsType#(QpAttrMaskFlag) requiredFlags =
        enum2Flag(IBV_QP_STATE)     |
        enum2Flag(IBV_QP_SQ_PSN)    |
        enum2Flag(IBV_QP_TIMEOUT)   |
        enum2Flag(IBV_QP_RETRY_CNT) |
        enum2Flag(IBV_QP_RNR_RETRY) |
        enum2Flag(IBV_QP_MAX_QP_RD_ATOMIC);

    return requiredFlags;
endfunction

function FlagsType#(QpAttrMaskFlag) getOnlyStateRequiredAttr();
    return enum2Flag(IBV_QP_STATE);
endfunction

typedef Bit#(1) Epoch;

typedef enum {
    REQ_QP_CREATE,
    REQ_QP_DESTROY,
    REQ_QP_MODIFY,
    REQ_QP_QUERY
} QpReqType deriving(Bits, Eq, FShow);

typedef struct {
    QpReqType                  qpReqType;
    HandlerPD                  pdHandler;
    QPN                        qpn;
    FlagsType#(QpAttrMaskFlag) qpAttrMask;
    AttrQP                     qpAttr;
    QpInitAttr                 qpInitAttr;
} ReqQP deriving(Bits, FShow);

typedef struct {
    Bool       successOrNot;
    QPN        qpn;
    HandlerPD  pdHandler;
    AttrQP     qpAttr;
    QpInitAttr qpInitAttr;
} RespQP deriving(Bits, FShow);

typedef Server#(ReqQP, RespQP) SrvPortQP;

interface CntrlCommStatus;
    // method StateQP getQPS();

    method Bool isCreate();
    method Bool isERR();
    method Bool isInit();
    method Bool isReset();
    method Bool isRTR();
    method Bool isRTS();
    method Bool isSQD();
    method Bool isNonErr();
    method Bool isUnknown();

    method Bool isRTR2RTS();
    method Bool isStableRTS();

    // method TypeQP getTypeQP();
    method FlagsType#(MemAccessTypeFlag) getAccessFlags();

    method RetryCnt     getMaxRnrCnt();
    method RetryCnt     getMaxRetryCnt();
    method RnrTimer     getMinRnrTimer();
    method TimeOutTimer getMaxTimeOut();

    method PendingReqCnt getPendingWorkReqNum();
    method PendingReqCnt getPendingRecvReqNum();
    method PendingReqCnt getPendingReadAtomicReqNum();
    method PendingReqCnt getPendingDestReadAtomicReqNum();
    method Bool getSigAll();

    method QPN  getSQPN();
    method QPN  getDQPN();
    method PKEY getPKEY();
    method QKEY getQKEY();
    method PMTU getPMTU();
endinterface

interface CntrlStatus;
    interface CntrlCommStatus comm;
    method TypeQP getTypeQP();
    method Bool isSQ();
    // method Bool isRQ();
endinterface

interface ContextSQ;
    interface CntrlStatus statusSQ;
    method PSN    getNPSN();
    method Action setNPSN(PSN psn);
endinterface

interface ContextRQ;
    interface CntrlStatus statusRQ;

    method PermCheckReq getPermCheckReq();
    method Action       setPermCheckReq(PermCheckReq permCheckReq);
    method Length       getTotalDmaWriteLen();
    method Action       setTotalDmaWriteLen(Length totalDmaWriteLen);
    method Length       getRemainingDmaWriteLen();
    method Action       setRemainingDmaWriteLen(Length remainingDmaWriteLen);
    method ADDR         getNextDmaWriteAddr();
    method Action       setNextDmaWriteAddr(ADDR nextDmaWriteAddr);
    method PktNum       getSendWriteReqPktNum();
    method Action       setSendWriteReqPktNum(PktNum sendWriteReqPktNum);
    method RdmaOpCode   getPreReqOpCode();
    method Action       setPreReqOpCode(RdmaOpCode preOpCode);
    // method PendingReqCnt getCoalesceWorkReqCnt();
    // method Action        setCoalesceWorkReqCnt(PendingReqCnt coalesceWorkReqCnt);
    // method PendingReqCnt getPendingDestReadAtomicReqCnt();
    // method Action        setPendingDestReadAtomicReqCnt(PendingReqCnt pendingDestReadAtomicReqCnt);
    method Epoch        getEpoch();
    method Action       incEpoch();
    method MSN          getMSN();
    method Action       setMSN(MSN msn);
    method Bool         getIsRespPktNumZero();
    method PktNum       getRespPktNum();
    method Action       setRespPktNum(PktNum respPktNum);
    method PSN          getCurRespPSN();
    method Action       setCurRespPSN(PSN curRespPsn);
    method PSN          getEPSN();
    method Action       setEPSN(PSN psn);
    method Action       restorePreReqOpCodeAndEPSN(RdmaOpCode preOpCode, PSN psn);
endinterface

interface CntrlQP;
    interface SrvPortQP srvPort;
    interface ContextSQ contextSQ;
    interface ContextRQ contextRQ;

    method Action setStateErr();
    method Action errFlushDone();
    // method Action setStateReset();

    // method StateQP getQPS();
    // method Bool isERR();
    // method Bool isInit();
    // method Bool isReset();
    // method Bool isRTR();
    // method Bool isRTS();
    // method Bool isNonErr();
    // method Bool isSQD();

    // method Bool isRTR2RTS();
    // method Bool isStableRTS();

    // method TypeQP getTypeQP();
    // method FlagsType#(MemAccessTypeFlag) getAccessFlags();

    // method RetryCnt     getMaxRnrCnt();
    // method RetryCnt     getMaxRetryCnt();
    // method RnrTimer     getMinRnrTimer();
    // method TimeOutTimer getMaxTimeOut();

    // method PendingReqCnt getPendingWorkReqNum();
    // method PendingReqCnt getPendingRecvReqNum();
    // method PendingReqCnt getPendingReadAtomicReqNum();
    // method PendingReqCnt getPendingDestReadAtomicReqNum();
    // method Bool getSigAll();

    // method QPN  getSQPN();
    // method QPN  getDQPN();
    // method PKEY getPKEY();
    // method QKEY getQKEY();
    // method PMTU getPMTU();
    // method PSN  getNPSN();

    // method Action setNPSN(PSN psn);
endinterface

// Support required attributes only when modifying QP.
// TODO: support optional attributes when modifying QP.
module mkCntrlQP(CntrlQP);
    FIFOF#(ReqQP)   reqQ <- mkFIFOF;
    FIFOF#(RespQP) respQ <- mkFIFOF;

    // QP Attributes related
    Reg#(StateQP) preStateReg <- mkReg(IBV_QPS_UNKNOWN);
    // IBV_QPS_UNKNOWN means QP is deleted, whereas
    // IBV_QPS_RESET means QP is not deleted but in reset state.
    Reg#(StateQP)    stateReg <- mkReg(IBV_QPS_RESET);

    Reg#(TypeQP) sqTypeReg <- mkRegU;
    Reg#(TypeQP) rqTypeReg <- mkRegU;

    Reg#(RetryCnt)      maxRnrCntReg <- mkRegU;
    Reg#(RetryCnt)    maxRetryCntReg <- mkRegU;
    Reg#(TimeOutTimer) maxTimeOutReg <- mkRegU;
    Reg#(RnrTimer)    minRnrTimerReg <- mkRegU;

    Reg#(Bool)     errFlushDoneReg <- mkRegU;
    Reg#(Bool)   setStateErrReg[2] <- mkCReg(2, False);
    Reg#(Bool)     qpDestroyReg[2] <- mkCReg(2, False);
    // Reg#(Bool) setStateResetReg[2] <- mkCReg(2, False);

    Reg#(Maybe#(StateQP)) nextStateReg[2] <- mkCReg(2, tagged Invalid);

    // TODO: support QP access check
    Reg#(FlagsType#(MemAccessTypeFlag)) qpAccessFlagsReg <- mkRegU;
    // TODO: support max WR/RR pending number check
    Reg#(PendingReqCnt) pendingWorkReqNumReg <- mkReg(fromInteger(valueOf(MAX_QP_WR)));
    Reg#(PendingReqCnt) pendingRecvReqNumReg <- mkReg(fromInteger(valueOf(MAX_QP_WR)));
    // TODO: support max read/atomic pending requests check
    Reg#(PendingReqCnt)     pendingReadAtomicReqNumReg <- mkRegU;
    Reg#(PendingReqCnt) pendingDestReadAtomicReqNumReg <- mkRegU;
    // TODO: support SG
    Reg#(ScatterGatherElemCnt) sendScatterGatherElemCntReg <- mkRegU;
    Reg#(ScatterGatherElemCnt) recvScatterGatherElemCntReg <- mkRegU;
    // TODO: support inline data
    Reg#(InlineDataSize)       inlineDataSizeReg <- mkRegU;

    Reg#(Bool) sqSigAllReg <- mkRegU;

    Reg#(QPN)  sqpnReg <- mkRegU;
    Reg#(QPN)  dqpnReg <- mkRegU;
    Reg#(PKEY) pkeyReg <- mkRegU;
    Reg#(QKEY) qkeyReg <- mkRegU;
    Reg#(PMTU) pmtuReg <- mkRegU;
    Reg#(PSN)  npsnReg <- mkRegU;
    // End QP attributes related

    Bool inited = stateReg != IBV_QPS_RESET && stateReg != IBV_QPS_UNKNOWN;

    // ContextRQ related
    Reg#(PermCheckReq)   permCheckReqReg <- mkRegU;
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
        pendingWorkReqNumReg <= fromInteger(valueOf(MAX_QP_WR));
        pendingRecvReqNumReg <= fromInteger(valueOf(MAX_QP_WR));
        preReqOpCodeReg[0] <= SEND_ONLY;
        epochReg <= 0;
        msnReg   <= 0;
        restoreQ.clear;
        // respQ.clear; // Do not clear respQ because of create and destroy QP responses

        // $display("time=%0t: reset and clear mkCntrlQP", $time);
    endrule
/*
    function Action debugShowRegs();
        action
            $display(
                "time=%0t: mkCntrlQP internal registers", $time,
                ", preStateReg=", fshow(preStateReg),
                ", stateReg=", fshow(stateReg),
                ", sqTypeReg=", fshow(sqTypeReg),
                ", rqTypeReg=", fshow(rqTypeReg),
                ", maxRnrCntReg=", fshow(maxRnrCntReg),
                ", maxRetryCntReg=", fshow(maxRetryCntReg),
                ", maxTimeOutReg=", fshow(maxTimeOutReg),
                ", minRnrTimerReg=", fshow(minRnrTimerReg),
                ", errFlushDoneReg=", fshow(errFlushDoneReg),
                ", setStateErrReg[1]=", fshow(setStateErrReg[1]),
                ", qpDestroyReg[1]=", fshow(qpDestroyReg[1]),
                ", nextStateReg[1]=", fshow(nextStateReg[1]),
                ", qpAccessFlagsReg=", fshow(qpAccessFlagsReg),
                ", pendingWorkReqNumReg=", fshow(pendingWorkReqNumReg),
                ", pendingRecvReqNumReg=", fshow(pendingRecvReqNumReg),
                ", pendingReadAtomicReqNumReg=", fshow(pendingReadAtomicReqNumReg),
                ", pendingDestReadAtomicReqNumReg=", fshow(pendingDestReadAtomicReqNumReg),
                ", sendScatterGatherElemCntReg=", fshow(sendScatterGatherElemCntReg),
                ", recvScatterGatherElemCntReg=", fshow(recvScatterGatherElemCntReg),
                ", inlineDataSizeReg=", fshow(inlineDataSizeReg),
                ", sqSigAllReg=", fshow(sqSigAllReg),
                ", sqpnReg=", fshow(sqpnReg),
                ", dqpnReg=", fshow(dqpnReg),
                ", pkeyReg=", fshow(pkeyReg),
                ", qkeyReg=", fshow(qkeyReg),
                ", pmtuReg=", fshow(pmtuReg),
                ", npsnReg=", fshow(npsnReg),
                ", permCheckReqReg=", fshow(permCheckReqReg),
                ", totalDmaWriteLenReg=", fshow(totalDmaWriteLenReg),
                ", remainingDmaWriteLenReg=", fshow(remainingDmaWriteLenReg),
                ", nextDmaWriteAddrReg=", fshow(nextDmaWriteAddrReg),
                ", sendWriteReqPktNumReg=", fshow(sendWriteReqPktNumReg),
                ", preReqOpCodeReg[1]=", fshow(preReqOpCodeReg[1]),
                ", epochReg=", fshow(epochReg),
                ", msnReg=", fshow(msnReg),
                ", isRespPktNumZeroReg=", fshow(isRespPktNumZeroReg),
                ", respPktNumReg=", fshow(respPktNumReg),
                ", curRespPsnReg=", fshow(curRespPsnReg),
                ", epsnReg[1]=", fshow(epsnReg[1])
            );
        endaction
    endfunction

    rule debug if (preStateReg == IBV_QPS_RTR && stateReg == IBV_QPS_RTS);
        debugShowRegs;
        // $display("time=%0t:", $time, " cntrl.stateReg=", fshow(stateReg));
    endrule
*/
    // qpAttr set when Reset 2 INIT
    function AttrQP queryReset2InitAttr(AttrQP qpAttr);
        qpAttr.curQpState    = stateReg;
        qpAttr.qpAccessFlags = qpAccessFlagsReg;
        qpAttr.pkeyIndex     = pkeyReg;

        return qpAttr;
    endfunction

    // qpAttr set when INIT 2 RTR
    function AttrQP queryInit2RtrAttr(AttrQP qpAttr);
        qpAttr.pmtu              = pmtuReg;
        qpAttr.dqpn              = dqpnReg;
        qpAttr.rqPSN             = epsnReg[0];
        qpAttr.maxDestReadAtomic = pendingDestReadAtomicReqNumReg;
        qpAttr.minRnrTimer       = minRnrTimerReg;

        return qpAttr;
    endfunction

    // qpAttr set when RTR 2 RTS
    function AttrQP queryRtr2RtsAttr(AttrQP qpAttr);
        qpAttr.sqPSN         = npsnReg;
        qpAttr.timeout       = maxTimeOutReg;
        qpAttr.retryCnt      = maxRetryCntReg;
        qpAttr.rnrRetry      = maxRnrCntReg;
        qpAttr.maxReadAtomic = pendingReadAtomicReqNumReg;

        return qpAttr;
    endfunction

    (* no_implicit_conditions, fire_when_enabled *)
    rule updatePreState;
        preStateReg <= stateReg;
    endrule

    rule restore if (
        stateReg == IBV_QPS_RTR ||
        stateReg == IBV_QPS_RTS ||
        stateReg == IBV_QPS_SQD
    );
        let { preOpCode, epsn } = restoreQ.first;
        restoreQ.deq;

        preReqOpCodeReg[1] <= preOpCode;
        epsnReg[1] <= epsn;
    endrule

    rule onReset if (stateReg == IBV_QPS_RESET);
        let qpReq = reqQ.first;
        reqQ.deq;

        let successOrNot = qpReq.qpReqType == REQ_QP_CREATE;
        let qpResp = RespQP {
            successOrNot: successOrNot,
            qpn         : qpReq.qpn,
            pdHandler   : qpReq.pdHandler,
            qpAttr      : qpReq.qpAttr,
            qpInitAttr  : qpReq.qpInitAttr
        };

        if (successOrNot) begin
            nextStateReg[0] <= tagged Valid IBV_QPS_CREATE;
            // nextStateReg[0] <= tagged Valid IBV_QPS_RESET;
        end

        sqpnReg     <= qpReq.qpn;
        sqTypeReg   <= qpReq.qpInitAttr.qpType == IBV_QPT_XRC_RECV ? IBV_QPT_XRC_SEND : qpReq.qpInitAttr.qpType;
        rqTypeReg   <= qpReq.qpInitAttr.qpType == IBV_QPT_XRC_SEND ? IBV_QPT_XRC_RECV : qpReq.qpInitAttr.qpType;
        sqSigAllReg <= qpReq.qpInitAttr.sqSigAll;

        respQ.enq(qpResp);
        // $display(
        //     "time=%0t: onReset", $time,
        //     ", qpReq.qpn=%h", qpReq.qpn,
        //     ", successOrNot=", fshow(qpResp.successOrNot)
        // );
    endrule

    rule onCreate if (stateReg == IBV_QPS_CREATE);
        let qpReq = reqQ.first;
        reqQ.deq;

        let qpResp = RespQP {
            successOrNot: True,
            qpn         : qpReq.qpn,
            pdHandler   : qpReq.pdHandler,
            qpAttr      : qpReq.qpAttr,
            qpInitAttr  : qpReq.qpInitAttr
        };

        case (qpReq.qpReqType)
            // REQ_QP_CREATE: begin
            //     qpResp.successOrNot = stateReg == IBV_QPS_UNKNOWN;

            //     if (qpResp.successOrNot) begin
            //         nextStateReg[0] <= tagged Valid IBV_QPS_RESET;
            //     end
            //     sqpnReg     <= qpReq.qpn;
            //     sqTypeReg   <= qpReq.qpInitAttr.qpType;
            //     sqSigAllReg <= qpReq.qpInitAttr.sqSigAll;
            // end
            REQ_QP_DESTROY: begin
                // nextStateReg[0] <= tagged Valid IBV_QPS_UNKNOWN;
                immFail(
                    "no QP destroy on create @ mkCntrlQP",
                    $format(
                        "request QPN=%h", qpReq.qpn,
                        ", qpReqType=", fshow(qpReq.qpReqType)
                    )
                );
            end
            REQ_QP_MODIFY: begin
                qpResp.successOrNot =
                    // stateReg == IBV_QPS_RESET             &&
                    qpReq.qpAttr.qpState == IBV_QPS_INIT &&
                    containFlags(qpReq.qpAttrMask, getReset2InitRequiredAttr);

                if (qpResp.successOrNot) begin
                    nextStateReg[0]  <= tagged Valid qpReq.qpAttr.qpState;
                end
                qpAccessFlagsReg <= qpReq.qpAttr.qpAccessFlags;
                pkeyReg          <= qpReq.qpAttr.pkeyIndex;
            end
            REQ_QP_QUERY: begin
                qpResp.qpAttr.curQpState = stateReg;
            end
            default: begin
                immFail(
                    "unreachible case @ mkCntrlQP",
                    $format(
                        "request QPN=%h", qpReq.qpn,
                        ", qpReqType=", fshow(qpReq.qpReqType)
                    )
                );
            end
        endcase

        respQ.enq(qpResp);
        // $display(
        //     "time=%0t: onCreate", $time,
        //     ", qpReq.qpn=%h", qpReq.qpn,
        //     ", qpReq.qpAttr.qpState=", fshow(qpReq.qpAttr.qpState),
        //     ", qpReq.qpAttrMask=", fshow(qpReq.qpAttrMask),
        //     ", getReset2InitRequiredAttr=", fshow(getReset2InitRequiredAttr),
        //     ", successOrNot=", fshow(qpResp.successOrNot)
        // );
    endrule

    rule onINIT if (stateReg == IBV_QPS_INIT);
        let qpReq = reqQ.first;
        reqQ.deq;

        let qpResp = RespQP {
            successOrNot: True,
            qpn         : qpReq.qpn,
            pdHandler   : qpReq.pdHandler,
            qpAttr      : qpReq.qpAttr,
            qpInitAttr  : qpReq.qpInitAttr
        };

        case (qpReq.qpReqType)
            REQ_QP_DESTROY: begin
                // nextStateReg[0] <= tagged Valid IBV_QPS_UNKNOWN;
                immFail(
                    "no QP destroy on init @ mkCntrlQP",
                    $format(
                        "request QPN=%h", qpReq.qpn,
                        ", qpReqType=", fshow(qpReq.qpReqType)
                    )
                );
            end
            REQ_QP_MODIFY: begin
                qpResp.successOrNot =
                    qpReq.qpAttr.qpState == IBV_QPS_RTR &&
                    containFlags(qpReq.qpAttrMask, getInit2RtrRequiredAttr);

                if (qpResp.successOrNot) begin
                    nextStateReg[0]  <= tagged Valid qpReq.qpAttr.qpState;
                end
                pmtuReg                        <= qpReq.qpAttr.pmtu;
                dqpnReg                        <= qpReq.qpAttr.dqpn;
                epsnReg[0]                     <= qpReq.qpAttr.rqPSN;
                pendingDestReadAtomicReqNumReg <= qpReq.qpAttr.maxDestReadAtomic;
                minRnrTimerReg                 <= qpReq.qpAttr.minRnrTimer;
            end
            REQ_QP_QUERY : begin
                qpResp.qpAttr.curQpState    = stateReg;
                qpResp.qpAttr.qpAccessFlags = qpAccessFlagsReg;
                qpResp.qpAttr.pkeyIndex     = pkeyReg;
            end
            default: begin
                immFail(
                    "unreachible case @ mkCntrlQP",
                    $format(
                        "request QPN=%h", qpReq.qpn,
                        ", qpReqType=", fshow(qpReq.qpReqType)
                    )
                );
            end
        endcase

        respQ.enq(qpResp);
        // $display(
        //     "time=%0t: onINIT", $time,
        //     ", qpReq.qpn=%h", qpReq.qpn,
        //     ", qpReq.qpAttr.qpState=", fshow(qpReq.qpAttr.qpState),
        //     ", qpReq.qpAttrMask=", fshow(qpReq.qpAttrMask),
        //     ", getInit2RtrRequiredAttr=", fshow(getInit2RtrRequiredAttr),
        //     ", successOrNot=", fshow(qpResp.successOrNot)
        // );
    endrule

    rule onRTR if (stateReg == IBV_QPS_RTR);
        let qpReq = reqQ.first;
        reqQ.deq;

        let qpResp = RespQP {
            successOrNot: True,
            qpn         : qpReq.qpn,
            pdHandler   : qpReq.pdHandler,
            qpAttr      : qpReq.qpAttr,
            qpInitAttr  : qpReq.qpInitAttr
        };

        case (qpReq.qpReqType)
            REQ_QP_DESTROY: begin
                // nextStateReg[0] <= tagged Valid IBV_QPS_UNKNOWN;
                immFail(
                    "no QP destroy on RTR @ mkCntrlQP",
                    $format(
                        "request QPN=%h", qpReq.qpn,
                        ", qpReqType=", fshow(qpReq.qpReqType)
                    )
                );
            end
            REQ_QP_MODIFY: begin
                qpResp.successOrNot = (
                        qpReq.qpAttr.qpState == IBV_QPS_ERR &&
                        containFlags(qpReq.qpAttrMask, getOnlyStateRequiredAttr)
                    ) || (
                        qpReq.qpAttr.qpState == IBV_QPS_RTS &&
                        containFlags(qpReq.qpAttrMask, getRtr2RtsRequiredAttr)
                    );

                if (qpResp.successOrNot) begin
                    nextStateReg[0]  <= tagged Valid qpReq.qpAttr.qpState;
                end
                npsnReg                    <= qpReq.qpAttr.sqPSN;
                maxTimeOutReg              <= qpReq.qpAttr.timeout;
                maxRetryCntReg             <= qpReq.qpAttr.retryCnt;
                maxRnrCntReg               <= qpReq.qpAttr.rnrRetry;
                pendingReadAtomicReqNumReg <= qpReq.qpAttr.maxReadAtomic;
            end
            REQ_QP_QUERY : begin
                // qpAttr set when Reset 2 INIT
                qpResp.qpAttr.curQpState    = stateReg;
                qpResp.qpAttr.qpAccessFlags = qpAccessFlagsReg;
                qpResp.qpAttr.pkeyIndex     = pkeyReg;
                // qpAttr set when INIT 2 RTR
                qpReq.qpAttr.pmtu              = pmtuReg;
                qpReq.qpAttr.dqpn              = dqpnReg;
                qpReq.qpAttr.rqPSN             = epsnReg[0];
                qpReq.qpAttr.maxDestReadAtomic = pendingDestReadAtomicReqNumReg;
                qpReq.qpAttr.minRnrTimer       = minRnrTimerReg;
            end
            default: begin
                immFail(
                    "unreachible case @ mkCntrlQP",
                    $format(
                        "request QPN=%h", qpReq.qpn,
                        ", qpReqType=", fshow(qpReq.qpReqType)
                    )
                );
            end
        endcase

        respQ.enq(qpResp);
        // $display(
        //     "time=%0t: onRTR", $time,
        //     ", qpReq.qpn=%h", qpReq.qpn,
        //     ", qpReq.qpAttr.qpState=", fshow(qpReq.qpAttr.qpState),
        //     ", qpReq.qpAttrMask=", fshow(qpReq.qpAttrMask),
        //     ", getRtr2RtsRequiredAttr=", fshow(getRtr2RtsRequiredAttr),
        //     ", successOrNot=", fshow(qpResp.successOrNot)
        // );
    endrule

    rule onRTS if (stateReg == IBV_QPS_RTS);
        let qpReq = reqQ.first;
        reqQ.deq;

        let qpResp = RespQP {
            successOrNot: True,
            qpn         : qpReq.qpn,
            pdHandler   : qpReq.pdHandler,
            qpAttr      : qpReq.qpAttr,
            qpInitAttr  : qpReq.qpInitAttr
        };

        case (qpReq.qpReqType)
            REQ_QP_DESTROY: begin
                // nextStateReg[0] <= tagged Valid IBV_QPS_UNKNOWN;
                immFail(
                    "no QP destroy on RTS @ mkCntrlQP",
                    $format(
                        "request QPN=%h", qpReq.qpn,
                        ", qpReqType=", fshow(qpReq.qpReqType)
                    )
                );
            end
            REQ_QP_MODIFY: begin
                qpResp.successOrNot = (
                        qpReq.qpAttr.qpState == IBV_QPS_SQD ||
                        qpReq.qpAttr.qpState == IBV_QPS_ERR
                    ) && containFlags(qpReq.qpAttrMask, getOnlyStateRequiredAttr);

                if (qpResp.successOrNot) begin
                    nextStateReg[0]  <= tagged Valid qpReq.qpAttr.qpState;
                end
            end
            REQ_QP_QUERY : begin
                // qpAttr set when Reset 2 INIT
                qpResp.qpAttr.curQpState    = stateReg;
                qpResp.qpAttr.qpAccessFlags = qpAccessFlagsReg;
                qpResp.qpAttr.pkeyIndex     = pkeyReg;
                // qpAttr set when INIT 2 RTR
                qpReq.qpAttr.pmtu              = pmtuReg;
                qpReq.qpAttr.dqpn              = dqpnReg;
                qpReq.qpAttr.rqPSN             = epsnReg[0];
                qpReq.qpAttr.maxDestReadAtomic = pendingDestReadAtomicReqNumReg;
                qpReq.qpAttr.minRnrTimer       = minRnrTimerReg;
                // qpAttr set when RTR 2 RTS
                qpResp.qpAttr.sqPSN         = npsnReg;
                qpResp.qpAttr.timeout       = maxTimeOutReg;
                qpResp.qpAttr.retryCnt      = maxRetryCntReg;
                qpResp.qpAttr.rnrRetry      = maxRnrCntReg;
                qpResp.qpAttr.maxReadAtomic = pendingReadAtomicReqNumReg;
            end
            default: begin
                immFail(
                    "unreachible case @ mkCntrlQP",
                    $format(
                        "request QPN=%h", qpReq.qpn,
                        ", qpReqType=", fshow(qpReq.qpReqType)
                    )
                );
            end
        endcase

        respQ.enq(qpResp);
        // $display(
        //     "time=%0t: onRTS", $time,
        //     ", qpReq.qpn=%h", qpReq.qpn,
        //     ", successOrNot=", fshow(qpResp.successOrNot)
        // );
    endrule

    rule onSQD if (stateReg == IBV_QPS_SQD);
        let qpReq = reqQ.first;
        reqQ.deq;

        let qpResp = RespQP {
            successOrNot: True,
            qpn         : qpReq.qpn,
            pdHandler   : qpReq.pdHandler,
            qpAttr      : qpReq.qpAttr,
            qpInitAttr  : qpReq.qpInitAttr
        };

        case (qpReq.qpReqType)
            REQ_QP_DESTROY: begin
                // nextStateReg[0] <= tagged Valid IBV_QPS_UNKNOWN;
                immFail(
                    "no QP destroy on SQD @ mkCntrlQP",
                    $format(
                        "request QPN=%h", qpReq.qpn,
                        ", qpReqType=", fshow(qpReq.qpReqType)
                    )
                );
            end
            REQ_QP_MODIFY: begin
                qpResp.successOrNot = (
                        qpReq.qpAttr.qpState == IBV_QPS_ERR ||
                        qpReq.qpAttr.qpState == IBV_QPS_RTS
                    ) && containFlags(qpReq.qpAttrMask, getOnlyStateRequiredAttr);

                if (qpResp.successOrNot) begin
                    nextStateReg[0]  <= tagged Valid qpReq.qpAttr.qpState;
                end
            end
            REQ_QP_QUERY : begin
                // qpAttr set when Reset 2 INIT
                qpResp.qpAttr.curQpState    = stateReg;
                qpResp.qpAttr.qpAccessFlags = qpAccessFlagsReg;
                qpResp.qpAttr.pkeyIndex     = pkeyReg;
                // qpAttr set when INIT 2 RTR
                qpReq.qpAttr.pmtu              = pmtuReg;
                qpReq.qpAttr.dqpn              = dqpnReg;
                qpReq.qpAttr.rqPSN             = epsnReg[0];
                qpReq.qpAttr.maxDestReadAtomic = pendingDestReadAtomicReqNumReg;
                qpReq.qpAttr.minRnrTimer       = minRnrTimerReg;
                // qpAttr set when RTR 2 RTS
                qpResp.qpAttr.sqPSN         = npsnReg;
                qpResp.qpAttr.timeout       = maxTimeOutReg;
                qpResp.qpAttr.retryCnt      = maxRetryCntReg;
                qpResp.qpAttr.rnrRetry      = maxRnrCntReg;
                qpResp.qpAttr.maxReadAtomic = pendingReadAtomicReqNumReg;
            end
            default: begin
                immFail(
                    "unreachible case @ mkCntrlQP",
                    $format(
                        "request QPN=%h", qpReq.qpn,
                        ", qpReqType=", fshow(qpReq.qpReqType)
                    )
                );
            end
        endcase

        respQ.enq(qpResp);
        // $display(
        //     "time=%0t: onSQD", $time,
        //     ", qpReq.qpn=%h", qpReq.qpn,
        //     ", successOrNot=", fshow(qpResp.successOrNot)
        // );
    endrule

    rule onERR if (stateReg == IBV_QPS_ERR && errFlushDoneReg);
        let qpReq = reqQ.first;
        reqQ.deq;

        let qpResp = RespQP {
            successOrNot: True,
            qpn         : qpReq.qpn,
            pdHandler   : qpReq.pdHandler,
            qpAttr      : qpReq.qpAttr,
            qpInitAttr  : qpReq.qpInitAttr
        };

        case (qpReq.qpReqType)
            REQ_QP_DESTROY: begin
                // TODO: only destroy QP when error, this is too rigid
                // nextStateReg[0] <= tagged Valid IBV_QPS_UNKNOWN;
                nextStateReg[0] <= tagged Valid IBV_QPS_RESET;
            end
            REQ_QP_MODIFY: begin
                qpResp.successOrNot =
                    qpReq.qpAttr.qpState == IBV_QPS_RESET &&
                    containFlags(qpReq.qpAttrMask, getOnlyStateRequiredAttr);

                if (qpResp.successOrNot) begin
                    nextStateReg[0]  <= tagged Valid qpReq.qpAttr.qpState;
                end
            end
            REQ_QP_QUERY : begin
                qpResp.qpAttr.curQpState = stateReg;
            end
            default: begin
                immFail(
                    "unreachible case @ mkCntrlQP",
                    $format(
                        "request QPN=%h", qpReq.qpn,
                        ", qpReqType=", fshow(qpReq.qpReqType)
                    )
                );
            end
        endcase

        respQ.enq(qpResp);
        // $display(
        //     "time=%0t: onERR", $time,
        //     ", qpReq.qpn=%h", qpReq.qpn,
        //     // ", qpReq=", fshow(qpReq),
        //     // ", qpResp=", fshow(qpResp),
        //     ", successOrNot=", fshow(qpResp.successOrNot)
        // );
    endrule

    (* no_implicit_conditions, fire_when_enabled *)
    rule canonicalize;
        let nextState = stateReg;
        if (nextStateReg[1] matches tagged Valid .setState) begin
            nextState = setState;
            // $display(
            //     "time=%0t: Controller set next state", $time,
            //     // ", sqpnReg=%h", sqpnReg,
            //     ", stateReg=", fshow(stateReg),
            //     ", nextState=", fshow(nextState)
            // );
        end
/*
        // IBV_QPS_UNKNOWN and IBV_QPS_RESET has higher priority than IBV_QPS_ERR,
        // IBV_QPS_ERR has higher priority than other states.
        if (stateReg == IBV_QPS_UNKNOWN && setStateResetReg[1]) begin
            nextState = IBV_QPS_RESET;
            // $display(
            //     "time=%0t: Controller reset", $time,
            //     // ", sqpnReg=%h", sqpnReg,
            //     ", stateReg=", fshow(stateReg),
            //     ", nextState=", fshow(nextState)
            // );

            // After destroy QP, clear reqQ and respQ
            reqQ.clear;
            // TODO: check destroy QP response is consumed before clear
            respQ.clear;
        end
        else if (nextState != IBV_QPS_UNKNOWN && setStateErrReg[1]) begin
            nextState = IBV_QPS_ERR;
            // $display(
            //     "time=%0t: Controller set error state", $time,
            //     // ", sqpnReg=%h", sqpnReg,
            //     ", stateReg=", fshow(stateReg),
            //     ", nextState=", fshow(nextState)
            // );
        end
*/
        if (setStateErrReg[1]) begin
            nextState = IBV_QPS_ERR;
            // TODO: never clear reqQ and respQ
            // reqQ.clear;
            // respQ.clear;
            immAssert(
                stateReg != IBV_QPS_UNKNOWN && stateReg != IBV_QPS_RESET,
                "set state error assertion @ mkCntrlQP",
                $format(
                    "stateReg=", fshow(stateReg),
                    " should not be IBV_QPS_UNKNOWN or IBV_QPS_RESET"
                )
            );
        end

        stateReg          <= nextState;
        nextStateReg[1]   <= tagged Invalid;
        setStateErrReg[1] <= False;
        // setStateResetReg[1] <= False;
    endrule

    function getCntrlCommStatus();
        // interface cntrlCommStatus = interface CntrlCommStatus;
        // method StateQP getQPS() = stateReg;
        let ret = interface CntrlCommStatus;
            method Bool isCreate()  = stateReg == IBV_QPS_CREATE;
            method Bool isERR()     = stateReg == IBV_QPS_ERR;
            method Bool isInit()    = stateReg == IBV_QPS_INIT;
            method Bool isNonErr()  = stateReg == IBV_QPS_RTR || stateReg == IBV_QPS_RTS || stateReg == IBV_QPS_SQD;
            method Bool isReset()   = stateReg == IBV_QPS_RESET; // stateReg == IBV_QPS_UNKNOWN ||
            method Bool isRTR()     = stateReg == IBV_QPS_RTR;
            method Bool isRTS()     = stateReg == IBV_QPS_RTS;
            method Bool isSQD()     = stateReg == IBV_QPS_SQD;
            method Bool isUnknown() = stateReg == IBV_QPS_UNKNOWN;

            method Bool   isRTR2RTS() = preStateReg == IBV_QPS_RTR && stateReg == IBV_QPS_RTS;
            method Bool isStableRTS() = preStateReg == IBV_QPS_RTS && stateReg == IBV_QPS_RTS;

            // method TypeQP getTypeQP() if (inited) = sqTypeReg;
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
        endinterface;
        return ret;
    endfunction

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
    // method Action setStateReset() if (stateReg == IBV_QPS_UNKNOWN);
    //     setStateResetReg[0] <= True;
    // endmethod

    interface srvPort = toGPServer(reqQ, respQ);

    interface contextSQ = interface ContextSQ;
        interface statusSQ = interface CntrlStatus;
            interface comm = getCntrlCommStatus;
            method TypeQP getTypeQP() = sqTypeReg;
            method Bool isSQ() = True;
            // method Bool isRQ() = False;
        endinterface;

        method PSN    getNPSN() if (inited) = npsnReg;

        method Action setNPSN(PSN psn) if (inited);
            npsnReg <= psn;
        endmethod
    endinterface;

    interface contextRQ = interface ContextRQ;
        interface statusRQ = interface CntrlStatus;
            interface comm = getCntrlCommStatus;
            method TypeQP getTypeQP() = rqTypeReg;
            method Bool isSQ() = False;
            // method Bool isRQ() = True;
        endinterface;

        method PermCheckReq getPermCheckReq() if (inited) = permCheckReqReg;
        method Action        setPermCheckReq(PermCheckReq permCheckReq) if (inited);
            permCheckReqReg <= permCheckReq;
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
