import ClientServer :: *;
import Cntrs :: *;
import FIFOF :: *;
import GetPut :: *;
import PAClib :: *;

import Controller :: *;
import DataTypes :: *;
import DupReadAtomicCache :: *;
import ExtractAndPrependPipeOut :: *;
import Headers :: *;
import InputPktHandle :: *;
import MetaData :: *;
import PayloadConAndGen :: *;
import PrimUtils :: *;
import RetryHandleSQ :: *;
import SpecialFIFOF :: *;
import Settings :: *;
import Utils :: *;

typedef enum {
    RDMA_REQ_ST_NORMAL,
    RDMA_REQ_ST_SEQ_ERR,
    RDMA_REQ_ST_RNR,
    RDMA_REQ_ST_INV_REQ,
    RDMA_REQ_ST_INV_RD,
    RDMA_REQ_ST_RMT_ACC,
    RDMA_REQ_ST_RMT_OP,
    RDMA_REQ_ST_DUP,
    RDMA_REQ_ST_ERR_FLUSH_RR,
    RDMA_REQ_ST_DISCARD,
    RDMA_REQ_ST_UNKNOWN
} RdmaReqStatus deriving(Bits, Eq, FShow);

function Bool isErrReqStatus(RdmaReqStatus reqStatus);
    return case (reqStatus)
        RDMA_REQ_ST_INV_REQ,
        RDMA_REQ_ST_INV_RD ,
        RDMA_REQ_ST_RMT_ACC,
        RDMA_REQ_ST_RMT_OP : True;
        default            : False;
    endcase;
endfunction

function Bool isNormalOrErrorReqStatus(RdmaReqStatus reqStatus);
    return case (reqStatus)
        RDMA_REQ_ST_NORMAL ,
        RDMA_REQ_ST_INV_REQ,
        RDMA_REQ_ST_INV_RD ,
        RDMA_REQ_ST_RMT_ACC,
        RDMA_REQ_ST_RMT_OP : True;
        default            : False;
    endcase;
endfunction

function Maybe#(QPN) getMaybeDestQpnRQ(Controller cntrl);
    return case (cntrl.getQpType)
        IBV_QPT_RC      ,
        IBV_QPT_UC      ,
        IBV_QPT_XRC_SEND, // TODO: XRC RQ should have its own controller
        IBV_QPT_XRC_RECV: tagged Valid cntrl.getDQPN;
        // IBV_QPT_UD
        default: tagged Invalid;
    endcase;
endfunction

function Maybe#(WorkCompStatus) genWorkCompStatusFromReqStatusRQ(RdmaReqStatus reqStatus);
    return case (reqStatus)
        RDMA_REQ_ST_NORMAL      : tagged Valid IBV_WC_SUCCESS;
        RDMA_REQ_ST_INV_REQ     : tagged Valid IBV_WC_REM_INV_REQ_ERR;
        RDMA_REQ_ST_INV_RD      : tagged Valid IBV_WC_REM_INV_RD_REQ_ERR;
        RDMA_REQ_ST_RMT_ACC     : tagged Valid IBV_WC_REM_ACCESS_ERR;
        RDMA_REQ_ST_RMT_OP      : tagged Valid IBV_WC_REM_OP_ERR;
        RDMA_REQ_ST_ERR_FLUSH_RR: tagged Valid IBV_WC_WR_FLUSH_ERR;
        default                 : tagged Invalid;
    endcase;
endfunction

function Maybe#(RdmaOpCode) genFirstOrOnlyRespRdmaOpCode(
    RdmaOpCode reqOpCode, RdmaReqStatus reqStatus, Bool isOnlyRespPkt
);
    case (reqStatus)
        RDMA_REQ_ST_NORMAL,
        RDMA_REQ_ST_DUP   : begin
            return case (reqOpCode)
                SEND_FIRST                    ,
                SEND_MIDDLE                   ,
                SEND_LAST                     ,
                SEND_LAST_WITH_IMMEDIATE      ,
                SEND_ONLY                     ,
                SEND_ONLY_WITH_IMMEDIATE      ,
                SEND_LAST_WITH_INVALIDATE     ,
                SEND_ONLY_WITH_INVALIDATE     ,
                RDMA_WRITE_FIRST              ,
                RDMA_WRITE_MIDDLE             ,
                RDMA_WRITE_LAST               ,
                RDMA_WRITE_LAST_WITH_IMMEDIATE,
                RDMA_WRITE_ONLY               ,
                RDMA_WRITE_ONLY_WITH_IMMEDIATE: tagged Valid ACKNOWLEDGE;
                RDMA_READ_REQUEST             : tagged Valid (isOnlyRespPkt ? RDMA_READ_RESPONSE_ONLY : RDMA_READ_RESPONSE_FIRST);
                COMPARE_SWAP                  ,
                FETCH_ADD                     : tagged Valid ATOMIC_ACKNOWLEDGE;
                default                       : tagged Invalid;
            endcase;
        end
        RDMA_REQ_ST_SEQ_ERR,
        RDMA_REQ_ST_RNR    ,
        RDMA_REQ_ST_INV_REQ,
        RDMA_REQ_ST_INV_RD ,
        RDMA_REQ_ST_RMT_ACC,
        RDMA_REQ_ST_RMT_OP : begin
            return tagged Valid ACKNOWLEDGE;
        end
        default: return tagged Invalid;
    endcase
endfunction

function Maybe#(RdmaOpCode) genMiddleOrLastRespRdmaOpCode(RdmaReqStatus reqStatus, Bool isLastRespPkt);
    return case (reqStatus)
        RDMA_REQ_ST_NORMAL,
        RDMA_REQ_ST_DUP   : tagged Valid (isLastRespPkt ? RDMA_READ_RESPONSE_LAST : RDMA_READ_RESPONSE_MIDDLE);
        RDMA_REQ_ST_RMT_OP: tagged Valid ACKNOWLEDGE;
        default           : tagged Invalid;
    endcase;
endfunction

function Maybe#(AETH) genAethByReqStatus(RdmaReqStatus reqStatus, Controller cntrl, MSN msn);
    return case (reqStatus)
        RDMA_REQ_ST_NORMAL,
        RDMA_REQ_ST_DUP   : begin
            tagged Valid AETH {
                rsvd : unpack(0),
                code : AETH_CODE_ACK,
                value: pack(AETH_ACK_VALUE_INVALID_CREDIT_CNT),
                msn  : msn
            };
        end
        RDMA_REQ_ST_RNR: begin
            tagged Valid AETH {
                rsvd : unpack(0),
                code : AETH_CODE_RNR,
                value: cntrl.getMinRnrTimer,
                msn  : msn
            };
        end
        RDMA_REQ_ST_SEQ_ERR: begin
            tagged Valid AETH {
                rsvd : unpack(0),
                code : AETH_CODE_NAK,
                value: zeroExtend(pack(AETH_NAK_SEQ_ERR)),
                msn  : msn
            };
        end
        RDMA_REQ_ST_INV_REQ: begin
            tagged Valid AETH {
                rsvd : unpack(0),
                code : AETH_CODE_NAK,
                value: zeroExtend(pack(AETH_NAK_INV_REQ)),
                msn  : msn
            };
        end
        RDMA_REQ_ST_INV_RD: begin
            tagged Valid AETH {
                rsvd : unpack(0),
                code : AETH_CODE_NAK,
                value: zeroExtend(pack(AETH_NAK_INV_RD)),
                msn  : msn
            };
        end
        RDMA_REQ_ST_RMT_ACC: begin
            tagged Valid AETH {
                rsvd : unpack(0),
                code : AETH_CODE_NAK,
                value: zeroExtend(pack(AETH_NAK_RMT_ACC)),
                msn  : msn
            };
        end
        RDMA_REQ_ST_RMT_OP: begin
            tagged Valid AETH {
                rsvd : unpack(0),
                code : AETH_CODE_NAK,
                value: zeroExtend(pack(AETH_NAK_RMT_OP)),
                msn  : msn
            };
        end
        default: tagged Invalid;
    endcase;
endfunction

function Maybe#(RdmaHeader) genFirstOrOnlyRespHeader(
    RdmaOpCode reqOpCode, RdmaReqStatus reqStatus,
    Length payloadLen, Maybe#(Long) atomicOrigData,
    Controller cntrl, PSN psn, MSN msn, Bool isOnlyRespPkt
);
    let maybeTrans  = qpType2TransType(cntrl.getQpType);
    let maybeOpCode = genFirstOrOnlyRespRdmaOpCode(reqOpCode, reqStatus, isOnlyRespPkt);
    let maybeDQPN   = getMaybeDestQpnRQ(cntrl);
    let maybeAETH   = genAethByReqStatus(reqStatus, cntrl, msn);

    let maybeAtomicAckEth = case (atomicOrigData) matches
        tagged Valid .origData: tagged Valid AtomicAckEth { orig: origData };
        default               : tagged Invalid;
    endcase;

    if (
        maybeTrans  matches tagged Valid .trans  &&&
        maybeOpCode matches tagged Valid .opcode &&&
        maybeDQPN   matches tagged Valid .dqpn   &&&
        maybeAETH   matches tagged Valid .aeth
    ) begin
        let bth = BTH {
            trans    : trans,
            opcode   : opcode,
            solicited: False,
            migReq   : unpack(0),
            padCnt   : isOnlyRespPkt ? calcPadCnt(payloadLen) : 0,
            tver     : unpack(0),
            pkey     : cntrl.getPKEY,
            fecn     : unpack(0),
            becn     : unpack(0),
            resv6    : unpack(0),
            dqpn     : dqpn,
            ackReq   : False,
            resv7    : unpack(0),
            psn      : psn
        };

        return case (opcode)
            ACKNOWLEDGE: begin
                tagged Valid genRdmaHeader(
                    zeroExtendLSB({ pack(bth), pack(aeth) }),
                    fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(AETH_BYTE_WIDTH)),
                    False // hasPayload
                );
            end
            ATOMIC_ACKNOWLEDGE: begin
                tagged Valid genRdmaHeader(
                    zeroExtendLSB({ pack(bth), pack(aeth), pack(unwrapMaybe(maybeAtomicAckEth)) }),
                    fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(AETH_BYTE_WIDTH) + valueOf(ATOMIC_ACK_ETH_BYTE_WIDTH)),
                    False // hasPayload
                );
            end
            RDMA_READ_RESPONSE_FIRST,
            RDMA_READ_RESPONSE_ONLY : begin
                let hasPayload = !isZero(payloadLen);
                tagged Valid genRdmaHeader(
                    zeroExtendLSB({ pack(bth), pack(aeth) }),
                    fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(AETH_BYTE_WIDTH)),
                    hasPayload
                );
            end
            default: tagged Invalid;
        endcase;
    end
    else begin
        return tagged Invalid;
    end
endfunction

function Maybe#(RdmaHeader) genMiddleOrLastRespHeader(
    RdmaOpCode reqOpCode, RdmaReqStatus reqStatus, Length payloadLen,
    Controller cntrl, PSN psn, MSN msn, Bool isLastRespPkt
);
    let maybeTrans  = qpType2TransType(cntrl.getQpType);
    let maybeOpCode = genMiddleOrLastRespRdmaOpCode(reqStatus, isLastRespPkt);
    let maybeDQPN   = getMaybeDestQpnRQ(cntrl);
    let maybeAETH   = genAethByReqStatus(reqStatus, cntrl, msn);

    if (
        maybeTrans  matches tagged Valid .trans  &&&
        maybeOpCode matches tagged Valid .opcode &&&
        maybeDQPN   matches tagged Valid .dqpn   &&&
        maybeAETH   matches tagged Valid .aeth
    ) begin
        let bth = BTH {
            trans    : trans,
            opcode   : opcode,
            solicited: False,
            migReq   : unpack(0),
            padCnt   : isLastRespPkt ? calcPadCnt(payloadLen) : 0,
            tver     : unpack(0),
            pkey     : cntrl.getPKEY,
            fecn     : unpack(0),
            becn     : unpack(0),
            resv6    : unpack(0),
            dqpn     : dqpn,
            ackReq   : False,
            resv7    : unpack(0),
            psn      : psn
        };

        let hasPayload = True;
        return case (opcode)
            ACKNOWLEDGE: begin // Error response to middle or last read responses
                tagged Valid genRdmaHeader(
                    zeroExtendLSB({ pack(bth), pack(aeth) }),
                    fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(AETH_BYTE_WIDTH)),
                    False // hasPayload
                );
            end
            RDMA_READ_RESPONSE_LAST: begin
                tagged Valid genRdmaHeader(
                    zeroExtendLSB({ pack(bth), pack(aeth) }),
                    fromInteger(valueOf(BTH_BYTE_WIDTH) + valueOf(AETH_BYTE_WIDTH)),
                    hasPayload
                );
            end
            RDMA_READ_RESPONSE_MIDDLE: begin
                tagged Valid genRdmaHeader(
                    zeroExtendLSB(pack(bth)),
                    fromInteger(valueOf(BTH_BYTE_WIDTH)),
                    hasPayload
                );
            end
            default: tagged Invalid;
        endcase;
    end
    else begin
        return tagged Invalid;
    end
endfunction

function RdmaReqStatus getInvReqStatusByTransType(TransType transType);
    return case (transType)
        TRANS_TYPE_RC : RDMA_REQ_ST_INV_REQ;
        TRANS_TYPE_UC : RDMA_REQ_ST_DISCARD;
        TRANS_TYPE_RD : RDMA_REQ_ST_INV_RD ;
        TRANS_TYPE_UD : RDMA_REQ_ST_DISCARD;
        TRANS_TYPE_CNP: RDMA_REQ_ST_DISCARD;
        TRANS_TYPE_XRC: RDMA_REQ_ST_INV_RD ;
        default       : RDMA_REQ_ST_UNKNOWN;
    endcase;
endfunction

function RdmaReqStatus pktStatus2ReqStatusRQ(
    PktVeriStatus pktStatus, TransType transType
);
    return case (pktStatus)
        PKT_ST_VALID  : RDMA_REQ_ST_NORMAL;
        PKT_ST_LEN_ERR: getInvReqStatusByTransType(transType);
        // PKT_ST_DISCARD: RDMA_REQ_ST_DISCARD;
        default       : RDMA_REQ_ST_UNKNOWN;
    endcase;
endfunction

typedef enum {
    RQ_PRE_BUILD_STAGE,
    RQ_PRE_CALC_STAGE,
    RQ_PRE_STAGE_DONE,
    RQ_PRE_RETRY_FLUSH
} PreStageStateRQ deriving(Bits, Eq, FShow);

typedef enum {
    RQ_SEQ_RETRY_FLUSH,
    RQ_RNR_RETRY_FLUSH,
    RQ_RNR_WAIT,
    RQ_RNR_WAIT_DONE,
    RQ_NOT_RETRY
} RetryStateRQ deriving(Bits, Eq, FShow);

typedef struct {
    BTH    bth;
    Epoch  epoch;
    PktNum respPktNum;
    PSN    endPSN;
    Bool   isSendReq;
    Bool   isWriteReq;
    Bool   isWriteImmReq;
    Bool   isReadReq;
    Bool   isAtomicReq;
    // Bool   isZeroPayloadLen;
    Bool   isOnlyPkt;
    Bool   isFirstPkt;
    Bool   isMidPkt;
    Bool   isLastPkt;
    Bool   isFirstOrOnlyPkt;
    Bool   isLastOrOnlyPkt;
    Bool   isOnlyRespPkt;
    Bool   isExpected;
    Bool   isDuplicated;
    Bool   isAccCheckPass;
} RdmaReqPktInfo deriving(Bits);

typedef struct {
    Bool hasErrIncurred;
    Bool shouldGenResp;
    Bool expectReadRespPayload;
    Bool expectAtomicRespOrig;
    Bool expectDupAtomicCheckResp;
    Maybe#(Long) atomicAckOrig;
    DupReadReqStartState dupReadReqStartState;
} RespPktGenInfo deriving(Bits, FShow);

typedef struct {
    Bool isFirstOrOnlyRespPkt;
    Bool isLastOrOnlyRespPkt;
} RespPktSeqInfo deriving(Bits, FShow);

typedef struct {
    PSN psn;
    MSN msn;
    Bool isFirstOrOnlyRespPkt;
    Bool isLastOrOnlyRespPkt;
    // Bool isLastOrMidRespPkt;
} RespPktHeaderInfo deriving(Bits, FShow);

typedef struct {
    Bool   enoughDmaSpace;
    Bool   isLastPayloadLenZero;
    ADDR   curDmaWriteAddr;
    Length remainingDmaWriteLen;
    Length totalDmaWriteLen;
} ReqLenCheckResult deriving(Bits);

interface ReqHandleRQ;
    interface PipeOut#(PayloadConReq) payloadConReqPipeOut;
    interface DataStreamPipeOut rdmaRespDataStreamPipeOut;
    interface PipeOut#(WorkCompGenReqRQ) workCompGenReqPipeOut;
endinterface

module mkReqHandleRQ#(
    Controller cntrl,
    DmaReadSrv dmaReadSrv,
    // PayloadGenerator payloadGenerator,
    PermCheckMR permCheckMR,
    DupReadAtomicCache dupReadAtomicCache,
    RecvReqBuf recvReqBuf,
    PipeOut#(RdmaPktMetaData) pktMetaDataPipeIn
)(ReqHandleRQ);
    // Output FIFO for PipeOut
    FIFOF#(PayloadConReq)     payloadConReqOutQ <- mkFIFOF;
    FIFOF#(PayloadGenReq)     payloadGenReqOutQ <- mkFIFOF;
    FIFOF#(WorkCompGenReqRQ) workCompGenReqOutQ <- mkFIFOF;
    FIFOF#(RdmaHeader)                  headerQ <- mkFIFOF;

    // Pipeline FIFO
    // TODO: add more buffer after 0th stage
    FIFOF#(Tuple4#(RdmaPktMetaData, RdmaReqStatus, RdmaReqPktInfo, PSN)) supportedReqOpCodeCheckQ <- mkFIFOF;
    // FIFOF#(Tuple3#(RdmaPktMetaData, RdmaReqStatus, RdmaReqPktInfo)) qpAccPermCheckQ <- mkFIFOF;
    FIFOF#(Tuple3#(RdmaPktMetaData, RdmaReqStatus, RdmaReqPktInfo)) reqOpCodeSeqCheckQ <- mkFIFOF;
    FIFOF#(Tuple4#(RdmaPktMetaData, RdmaReqStatus, RdmaReqPktInfo, RdmaOpCode)) rnrCheckQ <- mkFIFOF;
    FIFOF#(Tuple5#(RdmaPktMetaData, RdmaReqStatus, RdmaReqPktInfo, RdmaOpCode, Maybe#(RecvReq))) rnrTriggerQ <- mkFIFOF;
    FIFOF#(Tuple4#(RdmaPktMetaData, RdmaReqStatus, RdmaReqPktInfo, Maybe#(RecvReq))) qpAccPermCheckQ <- mkFIFOF;
    FIFOF#(Tuple4#(RdmaPktMetaData, RdmaReqStatus, RdmaReqPktInfo, Maybe#(RecvReq))) reqPermInfoBuildQ <- mkFIFOF;
    FIFOF#(Tuple5#(RdmaPktMetaData, RdmaReqStatus, PermCheckInfo, RdmaReqPktInfo, RETH)) reqPermQueryQ <- mkFIFOF;
    FIFOF#(Tuple6#(RdmaPktMetaData, RdmaReqStatus, PermCheckInfo, RdmaReqPktInfo, RETH, Bool)) reqPermCheckQ <- mkFIFOF;
    FIFOF#(Tuple5#(RdmaPktMetaData, RdmaReqStatus, PermCheckInfo, RdmaReqPktInfo, RETH)) readCacheInsertQ <- mkFIFOF;
    FIFOF#(Tuple5#(RdmaPktMetaData, RdmaReqStatus, PermCheckInfo, RdmaReqPktInfo, RETH)) dupReadReqPermQueryQ <- mkFIFOF;
    FIFOF#(Tuple6#(RdmaPktMetaData, RdmaReqStatus, PermCheckInfo, RdmaReqPktInfo, RETH, Bool)) dupReadReqPermCheckQ <- mkFIFOF;
    FIFOF#(Tuple5#(RdmaPktMetaData, RdmaReqStatus, PermCheckInfo, RdmaReqPktInfo, DupReadReqStartState)) reqAddrCalcQ <- mkFIFOF;
    FIFOF#(Tuple6#(RdmaPktMetaData, RdmaReqStatus, PermCheckInfo, RdmaReqPktInfo, DupReadReqStartState, ADDR)) reqRemainingLenCalcQ <- mkFIFOF;
    FIFOF#(Tuple8#(RdmaPktMetaData, RdmaReqStatus, PermCheckInfo, RdmaReqPktInfo, DupReadReqStartState, ADDR, Length, Length)) reqEnoughDmaSpaceQ <- mkFIFOF;
    FIFOF#(Tuple8#(RdmaPktMetaData, RdmaReqStatus, PermCheckInfo, RdmaReqPktInfo, DupReadReqStartState, ADDR, Length, Bool)) reqTotalLenCalcQ <- mkFIFOF;
    // FIFOF#(Tuple6#(RdmaPktMetaData, RdmaReqStatus, PermCheckInfo, RdmaReqPktInfo, DupReadReqStartState, ADDR)) reqLenCalcQ <- mkFIFOF;
    FIFOF#(Tuple6#(RdmaPktMetaData, RdmaReqStatus, PermCheckInfo, RdmaReqPktInfo, ReqLenCheckResult, DupReadReqStartState)) reqLenCheckQ <- mkFIFOF;
    // FIFOF#(Tuple6#(RdmaPktMetaData, RdmaReqStatus, PermCheckInfo, RdmaReqPktInfo, ADDR, DupReadReqStartState)) issueDmaReqQ <- mkFIFOF;
    FIFOF#(Tuple6#(RdmaPktMetaData, RdmaReqStatus, PermCheckInfo, RdmaReqPktInfo, ADDR, DupReadReqStartState)) issuePayloadConReqQ <- mkFIFOF;
    FIFOF#(Tuple6#(RdmaPktMetaData, RdmaReqStatus, PermCheckInfo, RdmaReqPktInfo, Bool, DupReadReqStartState)) issuePayloadGenReqQ <- mkFIFOF;
    // FIFOF#(Tuple5#(RdmaPktMetaData, RdmaReqStatus, PermCheckInfo, RdmaReqPktInfo, RespPktGenInfo)) respGenCheckQ <- mkFIFOF;
    FIFOF#(Tuple5#(RdmaPktMetaData, RdmaReqStatus, PermCheckInfo, RdmaReqPktInfo, RespPktGenInfo)) respGenCheck4NormalCaseQ <- mkFIFOF;
    FIFOF#(Tuple5#(RdmaPktMetaData, RdmaReqStatus, PermCheckInfo, RdmaReqPktInfo, RespPktGenInfo)) respGenCheck4OtherCasesQ <- mkFIFOF;
    FIFOF#(Tuple5#(RdmaPktMetaData, RdmaReqStatus, PermCheckInfo, RdmaReqPktInfo, RespPktGenInfo)) respCountQ <- mkFIFOF;
    FIFOF#(Tuple6#(RdmaPktMetaData, RdmaReqStatus, PermCheckInfo, RdmaReqPktInfo, RespPktGenInfo, RespPktSeqInfo)) respPsnAndMsnQ <- mkFIFOF;
    FIFOF#(Tuple6#(RdmaPktMetaData, RdmaReqStatus, PermCheckInfo, RdmaReqPktInfo, RespPktGenInfo, RespPktHeaderInfo)) waitAtomicRespQ <- mkFIFOF;
    FIFOF#(Tuple6#(RdmaPktMetaData, RdmaReqStatus, PermCheckInfo, RdmaReqPktInfo, RespPktGenInfo, RespPktHeaderInfo)) atomicCacheInsertQ <- mkFIFOF;
    FIFOF#(Tuple7#(RdmaPktMetaData, RdmaReqStatus, PermCheckInfo, RdmaReqPktInfo, RespPktGenInfo, RespPktHeaderInfo, AtomicEth)) respCheckQ <- mkFIFOF;
    FIFOF#(Tuple7#(RdmaPktMetaData, RdmaReqStatus, PermCheckInfo, RdmaReqPktInfo, RespPktGenInfo, RespPktHeaderInfo, AtomicEth)) dupAtomicReqPermQueryQ <- mkFIFOF;
    FIFOF#(Tuple6#(RdmaPktMetaData, RdmaReqStatus, PermCheckInfo, RdmaReqPktInfo, RespPktGenInfo, RespPktHeaderInfo)) dupAtomicReqPermCheckQ <- mkFIFOF;
    FIFOF#(Tuple6#(RdmaPktMetaData, RdmaReqStatus, PermCheckInfo, RdmaReqPktInfo, RespPktGenInfo, RespPktHeaderInfo)) respHeaderGenQ <- mkFIFOF;
    FIFOF#(Tuple7#(RdmaPktMetaData, RdmaReqStatus, PermCheckInfo, RdmaReqPktInfo, RespPktGenInfo, RespPktHeaderInfo, Maybe#(RdmaHeader))) pendingRespQ <- mkFIFOF;
    FIFOF#(Tuple6#(RdmaPktMetaData, RdmaReqStatus, PermCheckInfo, RdmaReqPktInfo, RespPktGenInfo, RespPktHeaderInfo)) workCompReqQ <- mkFIFOF;

    Reg#(Bool)      preStageIsZeroPmtuResidueReg <- mkRegU;
    Reg#(RdmaPktMetaData) preStagePktMetaDataReg <- mkRegU;
    Reg#(RdmaReqStatus)     preStageReqStatusReg <- mkRegU;
    Reg#(RdmaReqPktInfo)   preStageReqPktInfoReg <- mkRegU;
    Reg#(PreStageStateRQ)       preStageStateReg <- mkReg(RQ_PRE_BUILD_STAGE);

    Reg#(Epoch) epochReg <- mkRegU;

    Reg#(RnrWaitCycleCnt)        rnrWaitCntReg <- mkRegU;
    Reg#(RnrTimer)              minRnrTimerReg <- mkRegU;
    Reg#(Bool)             isRnrWaitCntZeroReg <- mkRegU;
    // Reg#(Bool)             isRetryFlushDoneReg <- mkRegU;
    Reg#(RetryStateRQ) retryStateReg <- mkReg(RQ_NOT_RETRY);
    // Reg#(Maybe#(RetryStateRQ)) retryStartStateReg[2] <- mkCReg(2, tagged Invalid);

    Reg#(Bool)        hasErrRespGenReg <- mkReg(False);
    Reg#(Bool)    hasDmaReadRespErrReg <- mkReg(False);
    Reg#(Bool) isFirstOrOnlyRespPktReg <- mkReg(True);

    // Reg#(Bool)     hasErrOccurredReg <- mkReg(False);
    Reg#(Bool) reqStatusErrNotifyReg <- mkReg(False);
    Reg#(Bool)  readRespErrNotifyReg <- mkReg(False);

    // Reg#(Bool) reqStatusErrNotifyReg[2] <- mkCReg(2, False);
    // Reg#(Bool)  readRespErrNotifyReg[2] <- mkCReg(2, False);

    // TODO: move the two counters into Controller
    Count#(PendingReqCnt) coalesceWorkReqCnt <- mkCount(fromInteger(valueOf(TSub#(MAX_QP_WR, 1))));
    CountCF#(PendingReqCnt) pendingDestReadAtomicReqCnt <- mkCountCF(0);
    Reg#(Bool) isCoalesceWorkReqCntZeroReg <- mkReg(False);

    let atomicSrv <- mkAtomicSrv(cntrl);
    let payloadGenerator <- mkPayloadGenerator(
        cntrl, dmaReadSrv, convertFifo2PipeOut(payloadGenReqOutQ)
    );
    let headerDataStreamAndMetaDataPipeOut <- mkHeader2DataStream(
        convertFifo2PipeOut(headerQ)
    );
    let rdmaRespPipeOut <- mkPrependHeader2PipeOut(
        headerDataStreamAndMetaDataPipeOut.headerDataStream,
        headerDataStreamAndMetaDataPipeOut.headerMetaData,
        payloadGenerator.payloadDataStreamPipeOut
    );

    function Bool hasErrHappened();
        return reqStatusErrNotifyReg || readRespErrNotifyReg;
    endfunction

    let inErrorState = (cntrl.isNonErr && hasErrHappened) || cntrl.isERR;

    function Action incEpoch();
        action
            epochReg <= ~epochReg;
        endaction
    endfunction
/*
    function Action clearRetryRelatedPipelineQ();
        action
            supportedReqOpCodeCheckQ.clear;
            // qpAccPermCheckQ.clear;
            reqOpCodeSeqCheckQ.clear;
            rnrCheckQ.clear;
            // rnrTriggerQ.clear;
        endaction
    endfunction

    function Bool isRetryFlushDone();
        let reqPktInfo = preStageReqPktInfoReg;
        let epoch      = reqPktInfo.epoch;
        let isExpected = reqPktInfo.isExpected;

        let retryFlushDone =
            isExpected && epoch == epochReg && (
            retryStateReg == RQ_RNR_WAIT_DONE ||
            retryStateReg == RQ_SEQ_RETRY_FLUSH
        );
        return retryFlushDone;
    endfunction
*/
    (* no_implicit_conditions, fire_when_enabled *)
    rule resetAndClear if (cntrl.isReset);
        payloadConReqOutQ.clear;
        payloadGenReqOutQ.clear;
        // atomicOpReqQ.clear;
        workCompGenReqOutQ.clear;
        headerQ.clear;

        // clearRetryRelatedPipelineQ;
        supportedReqOpCodeCheckQ.clear;
        reqOpCodeSeqCheckQ.clear;
        rnrCheckQ.clear;
        rnrTriggerQ.clear;
        qpAccPermCheckQ.clear;
        reqPermInfoBuildQ.clear;
        reqPermQueryQ.clear;
        reqPermCheckQ.clear;
        readCacheInsertQ.clear;
        dupReadReqPermQueryQ.clear;
        dupReadReqPermCheckQ.clear;
        reqAddrCalcQ.clear;
        reqRemainingLenCalcQ.clear;
        reqEnoughDmaSpaceQ.clear;
        reqTotalLenCalcQ.clear;
        // reqLenCalcQ.clear;
        reqLenCheckQ.clear;
        // issueDmaReqQ.clear;
        issuePayloadConReqQ.clear;
        issuePayloadGenReqQ.clear;
        // respGenCheckQ.clear;
        respGenCheck4NormalCaseQ.clear;
        respGenCheck4OtherCasesQ.clear;
        respCountQ.clear;
        respPsnAndMsnQ.clear;
        waitAtomicRespQ.clear;
        atomicCacheInsertQ.clear;
        dupAtomicReqPermQueryQ.clear;
        dupAtomicReqPermCheckQ.clear;
        respCheckQ.clear;
        respHeaderGenQ.clear;
        pendingRespQ.clear;
        workCompReqQ.clear;

        retryStateReg            <= RQ_NOT_RETRY;
        // retryStartStateReg[0]    <= tagged Invalid;
        preStageStateReg         <= RQ_PRE_BUILD_STAGE;
        hasErrRespGenReg         <= False;
        hasDmaReadRespErrReg     <= False;
        // hasErrOccurredReg        <= False;
        reqStatusErrNotifyReg    <= False;
        readRespErrNotifyReg     <= False;
        isFirstOrOnlyRespPktReg  <= True;
        // reqStatusErrNotifyReg[0] <= False;
        // readRespErrNotifyReg[0]  <= False;

        coalesceWorkReqCnt          <= fromInteger(valueOf(TSub#(MAX_QP_WR, 1)));
        pendingDestReadAtomicReqCnt <= 0;
        isCoalesceWorkReqCntZeroReg <= False;
        // $display("time=%0t: reset and clear retry handler", $time);
    endrule

    // TODO: check preBuildReqInfo and preCalcReqInfo having negative impact on throughput,
    // since preBuildReqInfo and preCalcReqInfo is not pipelined.
    rule preBuildReqInfo if (
        cntrl.isNonErr                         &&
        preStageStateReg == RQ_PRE_BUILD_STAGE &&
        !hasErrHappened
    );
        let curPktMetaData = pktMetaDataPipeIn.first;
        let curRdmaHeader  = curPktMetaData.pktHeader;

        let bth   = extractBTH(curRdmaHeader.headerData);
        let reth  = extractRETH(curRdmaHeader.headerData, bth.trans);
        let epoch = epochReg;

        let isSendReq        = isSendReqRdmaOpCode(bth.opcode);
        let isWriteReq       = isWriteReqRdmaOpCode(bth.opcode);
        let isWriteImmReq    = isWriteImmReqRdmaOpCode(bth.opcode);
        let isReadReq        = isReadReqRdmaOpCode(bth.opcode);
        let isAtomicReq      = isAtomicReqRdmaOpCode(bth.opcode);
        let isFirstOrOnlyPkt = isFirstOrOnlyRdmaOpCode(bth.opcode);
        let isLastOrOnlyPkt  = isLastOrOnlyRdmaOpCode(bth.opcode);
        // let isZeroPayloadLen = isZero(curPktMetaData.pktPayloadLen);

        let isOnlyPkt  = isOnlyRdmaOpCode(bth.opcode);
        let isFirstPkt = isFirstRdmaOpCode(bth.opcode);
        let isMidPkt   = isMiddleRdmaOpCode(bth.opcode);
        let isLastPkt  = isLastRdmaOpCode(bth.opcode);

        let expectedPSN  = cntrl.contextRQ.getEPSN;
        let oldestPSN    = calcOldestValidPsn4RQ(expectedPSN);
        let isIllegalReq = !curPktMetaData.pktValid;
        let isExpected   = bth.psn == expectedPSN;
        let isDuplicated = psnInRangeExclusive(bth.psn, oldestPSN, expectedPSN);

        let { totalRespPktNum, pmtuResidue } = truncateLenByPMTU(reth.dlen, cntrl.getPMTU);
        // let totalRespPktNum = calcPktNumByLenOnly(reth.dlen, cntrl.getPMTU);
        // let { isOnlyRespPkt, totalRespPktNum } = calcPktNumByLength(reth.dlen, cntrl.getPMTU);
        // let reqStatus = pktStatus2ReqStatusRQ(curPktMetaData.pktStatus, bth.trans);

        immAssert(
            isSendReq || isWriteReq || isReadReq || isAtomicReq,
            "illegal request type assertion @ mkReqHandleRQ",
            $format(
                "isSendReq=", fshow(isSendReq),
                ", isWriteReq=", fshow(isWriteReq),
                ", isReadReq=", fshow(isReadReq),
                ", isAtomicReq=", fshow(isAtomicReq),
                ", bth.opcode=%h", bth.opcode
            )
        );
        immAssert(
            isOnlyPkt || isFirstPkt || isMidPkt || isLastPkt,
            "illegal request type assertion @ mkReqHandleRQ",
            $format(
                "isOnlyPkt=", fshow(isOnlyPkt),
                ", isFirstPkt=", fshow(isFirstPkt),
                ", isMidPkt=", fshow(isMidPkt),
                ", isLastPkt=", fshow(isLastPkt),
                ", bth.opcode=%h", bth.opcode
            )
        );

        let reqPktInfo = RdmaReqPktInfo {
            bth             : bth,
            epoch           : epoch,
            respPktNum      : isReadReq ? totalRespPktNum : 1,
            endPSN          : dontCareValue,
            isSendReq       : isSendReq,
            isWriteReq      : isWriteReq,
            isWriteImmReq   : isWriteImmReq,
            isReadReq       : isReadReq,
            isAtomicReq     : isAtomicReq,
            // isZeroPayloadLen: isZeroPayloadLen,
            isOnlyPkt       : isOnlyPkt,
            isFirstPkt      : isFirstPkt,
            isMidPkt        : isMidPkt,
            isLastPkt       : isLastPkt,
            isFirstOrOnlyPkt: isFirstOrOnlyPkt,
            isLastOrOnlyPkt : isLastOrOnlyPkt,
            isOnlyRespPkt   : dontCareValue, // isReadReq ? isOnlyRespPkt : True,
            isExpected      : isExpected,
            isDuplicated    : isDuplicated,
            isAccCheckPass : dontCareValue
        };

        preStageIsZeroPmtuResidueReg <= isZero(pmtuResidue);
        preStagePktMetaDataReg <= curPktMetaData;
        preStageReqPktInfoReg  <= reqPktInfo;
        preStageStateReg       <= RQ_PRE_CALC_STAGE;
        // $display(
        //     "time=%0t:", $time,
        //     " 0.1st pre-stage, bth.opcode=", fshow(bth.opcode),
        //     ", bth.psn=%h, ePSN=%h, epoch=%h", bth.psn, expectedPSN, epoch,
        //     // ", reqStatus=", fshow(reqStatus),
        //     ", preStageStateReg=", fshow(preStageStateReg)
        // );
    endrule

    rule preCalcReqInfo if (
        cntrl.isNonErr                        &&
        preStageStateReg == RQ_PRE_CALC_STAGE &&
        !hasErrHappened
    );
        let curPktMetaData = preStagePktMetaDataReg;
        let curRdmaHeader  = curPktMetaData.pktHeader;
        let reqPktInfo     = preStageReqPktInfoReg;

        let bth         = reqPktInfo.bth;
        let isSendReq   = reqPktInfo.isSendReq;
        let isWriteReq  = reqPktInfo.isWriteReq;
        let isReadReq   = reqPktInfo.isReadReq;
        let isAtomicReq = reqPktInfo.isAtomicReq;

        // let { isOnlyRespPkt, totalRespPktNum } = calcPktNumByLength(reth.dlen, cntrl.getPMTU);
        let totalRespPktNum = preStageIsZeroPmtuResidueReg ? reqPktInfo.respPktNum : reqPktInfo.respPktNum + 1;
        let isOnlyRespPkt = isLessOrEqOne(totalRespPktNum);
        reqPktInfo.isOnlyRespPkt = reqPktInfo.isReadReq ? isOnlyRespPkt : True;
        reqPktInfo.respPktNum = reqPktInfo.isReadReq ? totalRespPktNum : 1;

        let isAccCheckPass = False;
        case ({ pack(isSendReq || isWriteReq), pack(isReadReq), pack(isAtomicReq) })
            3'b100: begin
                isAccCheckPass = containAccessTypeFlag(cntrl.getAccessFlags, IBV_ACCESS_REMOTE_WRITE);
            end
            3'b010: begin
                isAccCheckPass = containAccessTypeFlag(cntrl.getAccessFlags, IBV_ACCESS_REMOTE_READ);
            end
            3'b001: begin
                isAccCheckPass = containAccessTypeFlag(cntrl.getAccessFlags, IBV_ACCESS_REMOTE_ATOMIC);
            end
            default: begin
                immFail(
                    "unreachible case @ mkReqHandleRQ",
                    $format(
                        "isSendReq=", fshow(isSendReq),
                        ", isWriteReq=", fshow(isWriteReq),
                        ", isReadReq=", fshow(isReadReq),
                        ", isAtomicReq=", fshow(isAtomicReq)
                    )
                );
            end
        endcase

        let reqStatus = pktStatus2ReqStatusRQ(curPktMetaData.pktStatus, bth.trans);
        immAssert(
            reqStatus != RDMA_REQ_ST_UNKNOWN,
            "reqStatus assertion @ mkReqHandleRQ",
            $format(
                "reqStatus=", fshow(reqStatus), " should not be unknown"
            )
        );
        if (reqStatus == RDMA_REQ_ST_NORMAL && !isAccCheckPass) begin
            reqStatus = getInvReqStatusByTransType(bth.trans);
            immAssert(
                reqStatus != RDMA_REQ_ST_UNKNOWN,
                "reqStatus assertion @ mkReqHandleRQ",
                $format(
                    "reqStatus=", fshow(reqStatus), " should not be unknown"
                )
            );

            $display(
                "time=%0t: found invalid request in 0.2nd pre-stage", $time,
                ", bth.opcode=", fshow(bth.opcode),
                ", bth.psn=%h", bth.psn,
                ", isAccCheckPass=", fshow(isAccCheckPass),
                ", reqStatus=", fshow(reqStatus)
            );
        end
        reqPktInfo.isAccCheckPass = isAccCheckPass;

        preStageReqStatusReg  <= reqStatus;
        preStageReqPktInfoReg <= reqPktInfo;
        preStageStateReg      <= RQ_PRE_STAGE_DONE;
        // $display(
        //     "time=%0t:", $time,
        //     " 0.2nd pre-stage, bth.opcode=", fshow(bth.opcode),
        //     ", bth.psn=%h", bth.psn,
        //     ", reqStatus=", fshow(reqStatus),
        //     ", preStageStateReg=", fshow(preStageStateReg)
        // );
    endrule

                        // errFlushPipelineQ, \
                        // retryStart, canonicalize, \
    // TODO: add conflict_free attribute to preBuildReqInfo, preCalcReqInfo
    (* conflict_free = "checkEPSN, \
                        checkSupportedReqOpCode, \
                        checkNormalReqOpCodeSeq, \
                        checkRNR, \
                        triggerRNR, \
                        checkQpAccPermAndReadAtomicReqNum, \
                        buildPermCheckInfo, \
                        queryPerm4NormalReq, \
                        checkPerm4NormalReq, \
                        insertIntoReadCache, \
                        queryPerm4DupReadReq, \
                        checkPerm4DupReadReq, \
                        calcNormalSendWriteReqDmaAddr, \
                        calcNormalSendWriteReqDmaRemainingLen, \
                        calcNormalSendWriteReqEnoughDmaSpace, \
                        calcNormalSendWriteReqDmaTotalLen, \
                        checkReqLen, \
                        issuePayloadConReqOrDiscard, \
                        issuePayloadGenReq, \
                        shouldGenResp4NormalCase, \
                        shouldGenResp4OtherCases, \
                        waitAtomicResp, \
                        insertIntoAtomicCache, \
                        queryPerm4DupAtomicReq, \
                        checkPerm4DupAtomicReq, \
                        countPendingResp, \
                        updateRespPsnAndMsn, \
                        checkPendingResp, \
                        genRespHeader, \
                        genRespPkt, \
                        genWorkCompReq, \
                        errFlushRecvReq, \
                        errFlushIncomingReq, \
                        retryStageRnrRetryFlush, \
                        retryStageRnrWait, \
                        retryDone, \
                        retryFlush" *)
    rule checkEPSN if (
        cntrl.isNonErr   && !hasErrHappened   &&
        preStageStateReg == RQ_PRE_STAGE_DONE &&
        retryStateReg    == RQ_NOT_RETRY
    );
        let reqStatus  = preStageReqStatusReg;
        let reqPktInfo = preStageReqPktInfoReg;

        let curPktMetaData = preStagePktMetaDataReg;
        let curRdmaHeader  = curPktMetaData.pktHeader;
        pktMetaDataPipeIn.deq;

        let bth            = reqPktInfo.bth;
        let epoch          = reqPktInfo.epoch;
        let isReadReq      = reqPktInfo.isReadReq;
        let isExpected     = reqPktInfo.isExpected;
        let isDuplicated   = reqPktInfo.isDuplicated;
        let isAccCheckPass = reqPktInfo.isAccCheckPass;

        // reqPktInfo.isOnlyRespPkt = isLessOrEqOne(reqPktInfo.respPktNum);
        let { nextPktSeqNum, endPktSeqNum } = calcNextAndEndPSN(
            bth.psn, reqPktInfo.respPktNum, reqPktInfo.isOnlyRespPkt, cntrl.getPMTU
        );

        let curEPSN = cntrl.contextRQ.getEPSN;
        let nextEPSN = curEPSN;
        if (epoch == epochReg) begin
            if (reqStatus == RDMA_REQ_ST_NORMAL) begin
                if (bth.trans != TRANS_TYPE_UD) begin
                    // ePSN check, no PSN check for UD
                    case ({ pack(isExpected), pack(isDuplicated) })
                        2'b10: begin
                            if (isReadReq) begin
                                nextEPSN = nextPktSeqNum;
                                // cntrl.contextRQ.setEPSN(nextPktSeqNum);
                            end
                            else begin
                                nextEPSN = bth.psn + 1;
                                // cntrl.contextRQ.setEPSN(bth.psn + 1);
                            end
                            reqStatus = RDMA_REQ_ST_NORMAL;
                            cntrl.contextRQ.setEPSN(nextEPSN);
                        end
                        2'b01: begin
                            // if (isReadReq) begin
                            //     endPSN = endPktSeqNum;
                            // end
                            reqStatus = RDMA_REQ_ST_DUP;
                        end
                        default: begin
                            reqStatus = RDMA_REQ_ST_SEQ_ERR;
                        end
                    endcase
                end
            end
        end
        else begin
            reqStatus = RDMA_REQ_ST_DISCARD;

            $display(
                "time=%0t: epoch mismatch in 1st stage, epoch=", $time, fshow(epoch),
                ", epochReg=", fshow(epochReg)
            );
        end

        reqPktInfo.endPSN = endPktSeqNum;
        preStageStateReg <= RQ_PRE_BUILD_STAGE;

        supportedReqOpCodeCheckQ.enq(tuple4(curPktMetaData, reqStatus, reqPktInfo, curEPSN));
        // $display(
        //     "time=%0t: 1st stage, bth.opcode=", $time, fshow(bth.opcode),
        //     ", bth.psn=%h, epoch=%h", bth.psn, epoch,
        //     ", reqStatus=", fshow(reqStatus)
        // );
    endrule

    // This rule still runs at retry state
    rule checkSupportedReqOpCode if (cntrl.isNonErr || cntrl.isERR);
        let { pktMetaData, reqStatus, reqPktInfo, curEPSN } = supportedReqOpCodeCheckQ.first;
        supportedReqOpCodeCheckQ.deq;

        let bth   = reqPktInfo.bth;
        let epoch = reqPktInfo.epoch;

        let isSupportedReqOpCode = isSupportedReqOpCodeRQ(cntrl.getQpType, bth.opcode);

        if (epoch == epochReg) begin
            if (!hasErrHappened) begin
                if (reqStatus == RDMA_REQ_ST_SEQ_ERR) begin
                    // Update bth.psn to ePSN when SEQ ERR to facilitate NAK generation
                    reqPktInfo.bth.psn = curEPSN;
                end
                else if (!isSupportedReqOpCode) begin
                    if (reqStatus == RDMA_REQ_ST_NORMAL) begin
                        reqStatus = getInvReqStatusByTransType(bth.trans);
                        immAssert(
                            reqStatus != RDMA_REQ_ST_UNKNOWN,
                            "reqStatus assertion @ mkReqHandleRQ",
                            $format(
                                "reqStatus=", fshow(reqStatus), " should not be unknown"
                            )
                        );
                    end
                    else if (reqStatus == RDMA_REQ_ST_DUP) begin
                        reqStatus = RDMA_REQ_ST_DISCARD;
                    end
                end
            end
        end
        else begin
            reqStatus = RDMA_REQ_ST_DISCARD;

            $display(
                "time=%0t: epoch mismatch in 2nd stage, epoch=", $time, fshow(epoch),
                ", epochReg=", fshow(epochReg)
            );
        end

        // qpAccPermCheckQ.enq(tuple3(pktMetaData, reqStatus, reqPktInfo));
        reqOpCodeSeqCheckQ.enq(tuple3(pktMetaData, reqStatus, reqPktInfo));
        // $display(
        //     "time=%0t: 2nd stage, bth.opcode=", $time, fshow(bth.opcode),
        //     ", bth.psn=%h, epoch=%h", bth.psn, epoch,
        //     ", isSupportedReqOpCode=", fshow(isSupportedReqOpCode),
        //     ", reqStatus=", fshow(reqStatus)
        // );
    endrule

    // This rule still runs at retry state
    rule checkNormalReqOpCodeSeq if (cntrl.isNonErr || cntrl.isERR);
        let { pktMetaData, reqStatus, reqPktInfo } = reqOpCodeSeqCheckQ.first;
        reqOpCodeSeqCheckQ.deq;

        let bth       = reqPktInfo.bth;
        let epoch     = reqPktInfo.epoch;
        let preOpCode = cntrl.contextRQ.getPreReqOpCode;

        if (epoch == epochReg) begin
            if (reqStatus == RDMA_REQ_ST_NORMAL && !hasErrHappened) begin
                let seqCheckResult = checkNormalReqOpCodeSeqRQ(preOpCode, bth.opcode);
                if (seqCheckResult) begin
                    cntrl.contextRQ.setPreReqOpCode(bth.opcode);
                end
                else begin
                    reqStatus = getInvReqStatusByTransType(bth.trans);
                    immAssert(
                        reqStatus != RDMA_REQ_ST_UNKNOWN,
                        "reqStatus assertion @ mkReqHandleRQ",
                        $format(
                            "reqStatus=", fshow(reqStatus), " should not be unknown"
                        )
                    );
                end
            end
        end
        else begin
            reqStatus = RDMA_REQ_ST_DISCARD;

            $display(
                "time=%0t: epoch mismatch in 4th stage, epoch=", $time, fshow(epoch),
                ", epochReg=", fshow(epochReg)
            );
        end

        rnrCheckQ.enq(tuple4(pktMetaData, reqStatus, reqPktInfo, preOpCode));
        // $display(
        //     "time=%0t: 3rd stage, bth.opcode=", $time, fshow(bth.opcode),
        //     ", bth.psn=%h, epoch=%h", bth.psn, epoch,
        //     ", preOpCode=", fshow(preOpCode),
        //     ", reqStatus=", fshow(reqStatus)
        // );
    endrule

    // This rule still runs at retry state
    rule checkRNR if (cntrl.isNonErr || cntrl.isERR);
        let { pktMetaData, reqStatus, reqPktInfo, preOpCode } = rnrCheckQ.first;
        rnrCheckQ.deq;

        let bth   = reqPktInfo.bth;
        let epoch = reqPktInfo.epoch;

        let isZeroPayloadLen = pktMetaData.isZeroPayloadLen;
        let isFirstOrOnlyPkt = reqPktInfo.isFirstOrOnlyPkt;
        let isSendReq        = reqPktInfo.isSendReq;
        let isWriteImmReq    = reqPktInfo.isWriteImmReq;
        let maybeRecvReq     = tagged Invalid;

        if (epoch == epochReg) begin
            // Duplicate requests do not use PermCheckInfo
            if (
                reqStatus == RDMA_REQ_ST_NORMAL && !hasErrHappened &&
                ((isFirstOrOnlyPkt && isSendReq) || isWriteImmReq)
            ) begin
                if (recvReqBuf.notEmpty) begin
                    let recvReq = recvReqBuf.first;
                    recvReqBuf.deq;

                    maybeRecvReq = tagged Valid recvReq;

                    if (isZeroPayloadLen) begin
                        immAssert(
                            isOnlyRdmaOpCode(bth.opcode),
                            "isOnlyRdmaOpCode assertion @ mkReqHandleRQ",
                            $format(
                                "bth.opcode=", fshow(bth.opcode),
                                " should be only request packet"
                            )
                        );
                    end
                end
                else begin
                    reqStatus = RDMA_REQ_ST_RNR;
                end
            end
        end
        else begin
            reqStatus = RDMA_REQ_ST_DISCARD;

            let isMaybeRecReqValid = isValid(maybeRecvReq);
            immAssert(
                !isMaybeRecReqValid,
                "isMaybeRecReqValid assertion @ mkReqHandleRQ",
                $format(
                    "isMaybeRecReqValid=", fshow(isMaybeRecReqValid),
                    " should be false when epoch mismatch"
                )
            );

            $display(
                "time=%0t: epoch mismatch in 5th stage, epoch=", $time, fshow(epoch),
                ", epochReg=", fshow(epochReg)
            );
        end

        minRnrTimerReg <= cntrl.getMinRnrTimer;
        rnrTriggerQ.enq(tuple5(
            pktMetaData, reqStatus, reqPktInfo, preOpCode, maybeRecvReq
        ));
        // $display(
        //     "time=%0t: 4th stage, bth.opcode=", $time, fshow(bth.opcode),
        //     ", bth.psn=%h, epoch=%h", bth.psn, epoch,
        //     ", reqStatus=", fshow(reqStatus)
        // );
    endrule

    // This rule still runs at retry or error state
    rule triggerRNR if (cntrl.isNonErr || cntrl.isERR);
        let {
            pktMetaData, reqStatus, reqPktInfo, preOpCode, maybeRecvReq
        } = rnrTriggerQ.first;
        rnrTriggerQ.deq;

        let bth   = reqPktInfo.bth;
        let epoch = reqPktInfo.epoch;
        if (epoch == epochReg) begin
            // Trigger retry flush
            if (retryStateReg == RQ_NOT_RETRY && !hasErrHappened) begin
                // let nextRetryState = retryStateReg;

                if (reqStatus == RDMA_REQ_ST_RNR) begin
                    incEpoch;
                    cntrl.contextRQ.restorePreReqOpCode(preOpCode);
                    cntrl.contextRQ.restoreEPSN(bth.psn);

                    retryStateReg <= RQ_RNR_RETRY_FLUSH;
                end
                else if (reqStatus == RDMA_REQ_ST_SEQ_ERR) begin
                    incEpoch;

                    retryStateReg <= RQ_SEQ_RETRY_FLUSH;
                end

                // retryStateReg <= nextRetryState;
            end
        end
        else begin
            reqStatus = RDMA_REQ_ST_DISCARD;

            $display(
                "time=%0t: epoch mismatch in 6th stage, epoch=", $time, fshow(epoch),
                ", epochReg=", fshow(epochReg)
            );
        end

        // reqPermInfoBuildQ.enq(tuple4(pktMetaData, reqStatus, reqPktInfo, maybeRecvReq));
        qpAccPermCheckQ.enq(tuple4(pktMetaData, reqStatus, reqPktInfo, maybeRecvReq));
        // $display(
        //     "time=%0t: 5th stage, bth.opcode=", $time, fshow(bth.opcode),
        //     ", bth.psn=%h, epoch=%h", bth.psn, epoch,
        //     ", reqStatus=", fshow(reqStatus)
        // );
    endrule

    // This rule still runs at retry or error state
    rule checkQpAccPermAndReadAtomicReqNum if (cntrl.isNonErr || cntrl.isERR);
        let { pktMetaData, reqStatus, reqPktInfo, maybeRecvReq } = qpAccPermCheckQ.first;
        qpAccPermCheckQ.deq;

        let bth         = reqPktInfo.bth;
        let isReadReq   = reqPktInfo.isReadReq;
        let isAtomicReq = reqPktInfo.isAtomicReq;
        // let epoch          = reqPktInfo.epoch;
        // let isAccCheckPass = reqPktInfo.isAccCheckPass;

        let hasTooManyReadAtomicReqs = False;
        if (reqStatus == RDMA_REQ_ST_NORMAL && !hasErrHappened) begin
            if (isReadReq || isAtomicReq) begin
                pendingDestReadAtomicReqCnt.incrOne;

                if (
                    pendingDestReadAtomicReqCnt >= cntrl.getPendingDestReadAtomicReqNum
                ) begin
                    hasTooManyReadAtomicReqs = True;
                    $display(
                        "time=%0t:", $time,
                        " pendingDestReadAtomicReqCnt=%0d", pendingDestReadAtomicReqCnt,
                        " must < cntrl.getPendingDestReadAtomicReqNum=%0d",
                        cntrl.getPendingDestReadAtomicReqNum,
                        " when bth.psn=%h", bth.psn,
                        ", bth.opcode=", fshow(bth.opcode),
                        ", reqStatus=", fshow(reqStatus)
                    );

                    reqStatus = getInvReqStatusByTransType(bth.trans);
                    immAssert(
                        reqStatus != RDMA_REQ_ST_UNKNOWN,
                        "reqStatus assertion @ mkReqHandleRQ",
                        $format(
                            "reqStatus=", fshow(reqStatus), " should not be unknown"
                        )
                    );
                end
            end
        end

        reqPermInfoBuildQ.enq(tuple4(pktMetaData, reqStatus, reqPktInfo, maybeRecvReq));
        // $display(
        //     "time=%0t: 6th stage, bth.opcode=", $time, fshow(bth.opcode),
        //     ", bth.psn=%h", bth.psn,
        //     // ", isAccCheckPass=", fshow(isAccCheckPass),
        //     ", hasTooManyReadAtomicReqs=", fshow(hasTooManyReadAtomicReqs),
        //     ", reqStatus=", fshow(reqStatus)
        // );
    endrule

    // This rule still runs at retry or error state
    rule buildPermCheckInfo if (cntrl.isNonErr || cntrl.isERR);
        let { pktMetaData, reqStatus, reqPktInfo, maybeRecvReq } = reqPermInfoBuildQ.first;
        reqPermInfoBuildQ.deq;

        let bth        = reqPktInfo.bth;
        let hasReth    = rdmaReqHasRETH(bth.opcode);
        let rdmaHeader = pktMetaData.pktHeader;
        let reth       = extractRETH(rdmaHeader.headerData, bth.trans);
        let atomicEth  = extractAtomicEth(rdmaHeader.headerData, bth.trans);

        let isZeroPayloadLen = pktMetaData.isZeroPayloadLen;
        let isFirstOrOnlyPkt = reqPktInfo.isFirstOrOnlyPkt;
        let isSendReq        = reqPktInfo.isSendReq;
        let isWriteReq       = reqPktInfo.isWriteReq;
        let isReadReq        = reqPktInfo.isReadReq;
        let isWriteImmReq    = reqPktInfo.isWriteImmReq;
        let isAtomicReq      = reqPktInfo.isAtomicReq;

        let curPermCheckInfo = cntrl.contextRQ.getPermCheckInfo;
        // Duplicate requests no use PermCheckInfo
        if (reqStatus == RDMA_REQ_ST_NORMAL && !hasErrHappened) begin
            case ({ pack(isFirstOrOnlyPkt && isSendReq), pack(hasReth), pack(isAtomicReq) })
                3'b100: begin // send
                    let recvReq = unwrapMaybe(maybeRecvReq);
                    immAssert(
                        isValid(maybeRecvReq),
                        "maybeRecvReq assertion @ mkReqHandleRQ",
                        $format(
                            "maybeRecvReq=", fshow(maybeRecvReq),
                            " should be valid when isFirstOrOnlyPkt=", fshow(isFirstOrOnlyPkt),
                            " and isSendReq=", fshow(isSendReq)
                        )
                    );

                    curPermCheckInfo.wrID          = tagged Valid recvReq.id;
                    curPermCheckInfo.lkey          = recvReq.lkey;
                    curPermCheckInfo.rkey          = dontCareValue;
                    curPermCheckInfo.reqAddr       = recvReq.laddr;
                    curPermCheckInfo.totalLen      = isZeroPayloadLen ? 0 : recvReq.len;
                    curPermCheckInfo.pdHandler     = pktMetaData.pdHandler;
                    curPermCheckInfo.isZeroDmaLen  = isZeroPayloadLen;
                    curPermCheckInfo.accFlags      = toFlag(IBV_ACCESS_LOCAL_WRITE);
                    curPermCheckInfo.localOrRmtKey = True;
                end
                3'b010: begin // read and write
                    curPermCheckInfo.wrID          = tagged Invalid;
                    curPermCheckInfo.rkey          = reth.rkey;
                    curPermCheckInfo.lkey          = dontCareValue;
                    curPermCheckInfo.reqAddr       = reth.va;
                    curPermCheckInfo.totalLen      = reth.dlen;
                    curPermCheckInfo.pdHandler     = pktMetaData.pdHandler;
                    curPermCheckInfo.isZeroDmaLen  = isZero(reth.dlen);
                    curPermCheckInfo.accFlags      = toFlag(isReadReq ? IBV_ACCESS_REMOTE_READ : IBV_ACCESS_REMOTE_WRITE);
                    curPermCheckInfo.localOrRmtKey = False;

                    if (isWriteImmReq) begin
                        immAssert(
                            isValid(maybeRecvReq),
                            "maybeRecvReq assertion @ mkReqHandleRQ",
                            $format(
                                "maybeRecvReq=", fshow(maybeRecvReq),
                                " should be valid when isWriteImmReq=", fshow(isWriteImmReq)
                            )
                        );
                    end
                    else begin
                        immAssert(
                            !isValid(maybeRecvReq),
                            "maybeRecvReq assertion @ mkReqHandleRQ",
                            $format(
                                "maybeRecvReq=", fshow(maybeRecvReq),
                                " should be invalid when bth.opcode=", fshow(bth.opcode)
                            )
                        );
                    end
                end
                3'b001: begin // atomic
                    immAssert(
                        !isValid(maybeRecvReq),
                        "maybeRecvReq assertion @ mkReqHandleRQ",
                        $format(
                            "maybeRecvReq=", fshow(maybeRecvReq),
                            " should be invalid when bth.opcode=", fshow(bth.opcode)
                        )
                    );

                    curPermCheckInfo.wrID          = tagged Invalid;
                    curPermCheckInfo.rkey          = atomicEth.rkey;
                    curPermCheckInfo.lkey          = dontCareValue;
                    curPermCheckInfo.reqAddr       = atomicEth.va;
                    curPermCheckInfo.totalLen      = fromInteger(valueOf(ATOMIC_WORK_REQ_LEN));
                    curPermCheckInfo.pdHandler     = pktMetaData.pdHandler;
                    curPermCheckInfo.isZeroDmaLen  = False;
                    curPermCheckInfo.accFlags      = toFlag(IBV_ACCESS_REMOTE_ATOMIC);
                    curPermCheckInfo.localOrRmtKey = False;
                end
                default: begin
                    immAssert(
                        (isSendReq || isWriteReq) && !isFirstOrOnlyPkt,
                        "unreachible case @ mkReqHandleRQ",
                        $format(
                            "bth.opcode=", fshow(bth.opcode),
                            ", hasReth=", fshow(hasReth),
                            ", isSendReq=", fshow(isSendReq),
                            ", isWriteReq=", fshow(isWriteReq),
                            ", isReadReq=", fshow(isReadReq),
                            ", isAtomicReq=", fshow(isAtomicReq),
                            ", isFirstOrOnlyPkt=", fshow(isFirstOrOnlyPkt)
                        )
                    );

                    if (isWriteImmReq) begin
                        immAssert(
                            isValid(maybeRecvReq),
                            "maybeRecvReq assertion @ mkReqHandleRQ",
                            $format(
                                "maybeRecvReq=", fshow(maybeRecvReq),
                                " should be valid when isWriteImmReq=", fshow(isWriteImmReq)
                            )
                        );
                    end
                    else begin
                        immAssert(
                            !isValid(maybeRecvReq),
                            "maybeRecvReq assertion @ mkReqHandleRQ",
                            $format(
                                "maybeRecvReq=", fshow(maybeRecvReq),
                                " should be invalid when bth.opcode=", fshow(bth.opcode)
                            )
                        );
                    end
                end
            endcase

            if (isWriteImmReq) begin
                let recvReq = unwrapMaybe(maybeRecvReq);
                immAssert(
                    isValid(maybeRecvReq),
                    "maybeRecvReq assertion @ mkReqHandleRQ",
                    $format(
                        "maybeRecvReq=", fshow(maybeRecvReq),
                        " should be valid when isWriteImmReq=", fshow(isWriteImmReq)
                    )
                );

                curPermCheckInfo.wrID = tagged Valid recvReq.id;
            end
            cntrl.contextRQ.setPermCheckInfo(curPermCheckInfo);
        end

        reqPermQueryQ.enq(tuple5(
            pktMetaData, reqStatus, curPermCheckInfo, reqPktInfo, reth
        ));
        // $display(
        //     "time=%0t: 7th stage, bth.opcode=", $time, fshow(bth.opcode),
        //     ", bth.psn=%h", bth.psn, ", reqStatus=", fshow(reqStatus)
        // );
    endrule

    // This rule still runs at retry or error state
    rule queryPerm4NormalReq if (cntrl.isNonErr || cntrl.isERR);
        let {
            pktMetaData, reqStatus, permCheckInfo, reqPktInfo, reth
        } = reqPermQueryQ.first;
        reqPermQueryQ.deq;

        let bth = reqPktInfo.bth;

        let expectPermCheckResp = False;
        if (
            reqPktInfo.isFirstOrOnlyPkt && !hasErrHappened &&
            reqStatus == RDMA_REQ_ST_NORMAL && !permCheckInfo.isZeroDmaLen
        ) begin
            permCheckMR.request.put(permCheckInfo);
            expectPermCheckResp = True;
        end

        reqPermCheckQ.enq(tuple6(
            pktMetaData, reqStatus, permCheckInfo, reqPktInfo, reth, expectPermCheckResp
        ));
        // $display(
        //     "time=%0t: 8th stage, bth.opcode=", $time, fshow(bth.opcode),
        //     ", bth.psn=%h", bth.psn, ", reqStatus=", fshow(reqStatus)
        // );
    endrule

    // This rule still runs at retry or error state
    rule checkPerm4NormalReq if (cntrl.isNonErr || cntrl.isERR);
        let {
            pktMetaData, reqStatus, permCheckInfo, reqPktInfo, reth, expectPermCheckResp
        } = reqPermCheckQ.first;
        reqPermCheckQ.deq;

        let bth         = reqPktInfo.bth;
        let rdmaHeader  = pktMetaData.pktHeader;
        let isAtomicReq = reqPktInfo.isAtomicReq;
        let atomicEth   = extractAtomicEth(rdmaHeader.headerData, bth.trans);

        let isZeroDmaLen     = permCheckInfo.isZeroDmaLen;
        let isFirstOrOnlyPkt = reqPktInfo.isFirstOrOnlyPkt;

        let expectDupReadCheckResp = False;
        if (expectPermCheckResp) begin
            immAssert(
                reqStatus == RDMA_REQ_ST_NORMAL,
                "reqStatus normal assertion @ mkReqHandleRQ",
                $format(
                    "reqStatus=", fshow(reqStatus),
                    " should be RDMA_REQ_ST_NORMAL, when expectPermCheckResp=",
                    fshow(expectPermCheckResp)
                )
            );

            let mrCheckResult <- permCheckMR.response.get;
            if (mrCheckResult) begin
                // if (isReadReq) begin
                //     let readCacheItem = ReadCacheItem {
                //         startPSN: bth.psn,
                //         endPSN  : reqPktInfo.endPSN,
                //         reth    : reth
                //     };
                //     dupReadAtomicCache.insertRead(readCacheItem);
                // end
                // else
                if (isAtomicReq) begin
                    let isAligned = isAlignedAtomicAddr(atomicEth.va);
                    if (!isAligned) begin
                        reqStatus = getInvReqStatusByTransType(bth.trans);
                        immAssert(
                            reqStatus != RDMA_REQ_ST_UNKNOWN,
                            "reqStatus assertion @ mkReqHandleRQ",
                            $format(
                                "reqStatus=", fshow(reqStatus), " should not be unknown"
                            )
                        );
                        $display(
                            "time=%0d:", $time,
                            " un-aligned atomicEth.va=%h", atomicEth.va
                        );
                    end
                    // $display("time=%0t: atomicEth.va=%h", $time, atomicEth.va);
                end
            end
            else begin
                reqStatus = RDMA_REQ_ST_RMT_ACC;
            end
        end

        // dupReadReqPermQueryQ.enq(tuple5(
        readCacheInsertQ.enq(tuple5(
            pktMetaData, reqStatus, permCheckInfo, reqPktInfo, reth
        ));
        // $display(
        //     "time=%0t: 9th stage, bth.opcode=", $time, fshow(bth.opcode),
        //     ", bth.psn=%h", bth.psn, ", reqStatus=", fshow(reqStatus)
        // );
    endrule

    // This rule still runs at retry or error state
    rule insertIntoReadCache if (cntrl.isNonErr || cntrl.isERR);
        let {
            pktMetaData, reqStatus, permCheckInfo, reqPktInfo, reth
        } = readCacheInsertQ.first;
        readCacheInsertQ.deq;

        let bth        = reqPktInfo.bth;
        let rdmaHeader = pktMetaData.pktHeader;
        let isReadReq  = reqPktInfo.isReadReq;

        let readCacheItem = ReadCacheItem {
            startPSN: bth.psn,
            endPSN  : reqPktInfo.endPSN,
            reth    : reth
        };
        if (
            reqStatus == RDMA_REQ_ST_NORMAL && isReadReq &&
            reqPktInfo.isFirstOrOnlyPkt && !hasErrHappened
        ) begin
            dupReadAtomicCache.insertRead(readCacheItem);
        end

        dupReadReqPermQueryQ.enq(tuple5(
            pktMetaData, reqStatus, permCheckInfo, reqPktInfo, reth
        ));
        // $display(
        //     "time=%0t: 10th stage, bth.opcode=", $time, fshow(bth.opcode),
        //     ", bth.psn=%h", bth.psn, ", reqStatus=", fshow(reqStatus)
        // );
    endrule

    // This rule still runs at retry or error state
    rule queryPerm4DupReadReq if (cntrl.isNonErr || cntrl.isERR);
        let {
            pktMetaData, reqStatus, permCheckInfo, reqPktInfo, reth
        } = dupReadReqPermQueryQ.first;
        dupReadReqPermQueryQ.deq;

        let bth        = reqPktInfo.bth;
        let rdmaHeader = pktMetaData.pktHeader;
        let isReadReq  = reqPktInfo.isReadReq;

        let readCacheItem = ReadCacheItem {
            startPSN: bth.psn,
            endPSN  : reqPktInfo.endPSN,
            reth    : reth
        };
        let expectDupReadCheckResp = False;
        if (
            reqStatus == RDMA_REQ_ST_DUP && isReadReq &&
            reqPktInfo.isFirstOrOnlyPkt && !hasErrHappened
        ) begin
            dupReadAtomicCache.searchReadReq(readCacheItem);
            expectDupReadCheckResp = True;
        end

        dupReadReqPermCheckQ.enq(tuple6(
            pktMetaData, reqStatus, permCheckInfo, reqPktInfo, reth, expectDupReadCheckResp
        ));
        // $display(
        //     "time=%0t: 11th stage, bth.opcode=", $time, fshow(bth.opcode),
        //     ", bth.psn=%h", bth.psn, ", reqStatus=", fshow(reqStatus)
        // );
    endrule

    // This rule still runs at retry or error state
    rule checkPerm4DupReadReq if (cntrl.isNonErr || cntrl.isERR);
        let {
            pktMetaData, reqStatus, permCheckInfo, reqPktInfo, reth, expectDupReadCheckResp
        } = dupReadReqPermCheckQ.first;
        dupReadReqPermCheckQ.deq;

        let bth        = reqPktInfo.bth;
        let rdmaHeader = pktMetaData.pktHeader;

        let dupReadReqStartState = DUP_READ_REQ_START_FROM_FIRST;
        if (expectDupReadCheckResp) begin
            immAssert(
                reqStatus == RDMA_REQ_ST_DUP,
                "reqStatus dup assertion @ mkReqHandleRQ",
                $format(
                    "reqStatus=", fshow(reqStatus),
                    " should be RDMA_REQ_ST_DUP, when expectDupReadCheckResp=",
                    fshow(expectDupReadCheckResp)
                )
            );
            immAssert(
                reqPktInfo.isReadReq,
                "isReadReq assertion @ mkReqHandleRQ",
                $format(
                    "bth.opcode=", fshow(bth.opcode),
                    " should be read request, when expectDupReadCheckResp=",
                    fshow(expectDupReadCheckResp)
                )
            );

            let maybeSearchResult <- dupReadAtomicCache.searchReadResp;
            if (maybeSearchResult matches tagged Valid .searchResult) begin
                let {
                    origReadCacheItem, verifiedDupReadAddr, dupReadReqStart
                } = searchResult;
                permCheckInfo.reqAddr = verifiedDupReadAddr;
                dupReadReqStartState  = dupReadReqStart;

                immAssert(
                    permCheckInfo.reqAddr == reth.va,
                    "permCheckInfo.reqAddr assertion @ mkReqHandleRQ",
                    $format(
                        "permCheckInfo.reqAddr=%h should == reth.va=%h",
                        permCheckInfo.reqAddr, reth.va,
                        " when reqStatus=", fshow(reqStatus),
                        " and expectDupReadCheckResp=", fshow(expectDupReadCheckResp)
                    )
                );
            end
            else begin
                // Discard duplicate requests with error
                reqStatus = RDMA_REQ_ST_DISCARD;
            end
        end

        reqAddrCalcQ.enq(tuple5(
            pktMetaData, reqStatus, permCheckInfo, reqPktInfo, dupReadReqStartState
        ));
        // $display(
        //     "time=%0t: 12th stage, bth.opcode=", $time, fshow(bth.opcode),
        //     ", bth.psn=%h", bth.psn, ", reqStatus=", fshow(reqStatus)
        // );
    endrule

    // This rule still runs at retry or error state
    rule calcNormalSendWriteReqDmaAddr if (cntrl.isNonErr || cntrl.isERR);
        let {
            pktMetaData, reqStatus, permCheckInfo, reqPktInfo, dupReadReqStartState
        } = reqAddrCalcQ.first;
        reqAddrCalcQ.deq;

        let bth        = reqPktInfo.bth;
        let rdmaHeader = pktMetaData.pktHeader;
        let isSendReq  = reqPktInfo.isSendReq;
        let isWriteReq = reqPktInfo.isWriteReq;
        let isOnlyPkt  = reqPktInfo.isOnlyPkt;
        let isFirstPkt = reqPktInfo.isFirstPkt;
        let isMidPkt   = reqPktInfo.isMidPkt;
        let isLastPkt  = reqPktInfo.isLastPkt;

        let curDmaWriteAddr    = permCheckInfo.reqAddr;
        let nextDmaWriteAddr   = cntrl.contextRQ.getNextDmaWriteAddr;
        let sendWriteReqPktNum = cntrl.contextRQ.getSendWriteReqPktNum;
        let oneAsPSN           = 1;

        if (isSendReq || isWriteReq) begin
            case ( { pack(isOnlyPkt), pack(isFirstPkt), pack(isMidPkt), pack(isLastPkt) } )
                4'b1000: begin // isOnlyRdmaOpCode(bth.opcode)
                    // No need to calculate next DMA write address for only send/write responses
                    nextDmaWriteAddr   = permCheckInfo.reqAddr;
                    sendWriteReqPktNum = 1;
                end
                4'b0100: begin // isFirstRdmaOpCode(bth.opcode)
                    nextDmaWriteAddr   = addrAddPsnMultiplyPMTU(permCheckInfo.reqAddr, oneAsPSN, cntrl.getPMTU);
                    sendWriteReqPktNum = 1;
                end
                4'b0010: begin // isMiddleRdmaOpCode(bth.opcode)
                    curDmaWriteAddr    = cntrl.contextRQ.getNextDmaWriteAddr;
                    nextDmaWriteAddr   = addrAddPsnMultiplyPMTU(cntrl.contextRQ.getNextDmaWriteAddr, oneAsPSN, cntrl.getPMTU);
                    sendWriteReqPktNum = cntrl.contextRQ.getSendWriteReqPktNum + 1;
                end
                4'b0001: begin // isLastRdmaOpCode(bth.opcode)
                    curDmaWriteAddr    = cntrl.contextRQ.getNextDmaWriteAddr;
                    // No need to calculate next DMA write address for last send/write responses
                    nextDmaWriteAddr   = permCheckInfo.reqAddr;
                    sendWriteReqPktNum = cntrl.contextRQ.getSendWriteReqPktNum + 1;
                end
                default: begin
                    immFail(
                        "unreachible case @ mkReqHandleRQ",
                        $format(
                            "isOnlyPkt=", fshow(isOnlyPkt),
                            ", isFirstPkt=", fshow(isFirstPkt),
                            ", isMidPkt=", fshow(isMidPkt),
                            ", isLastPkt=", fshow(isLastPkt)
                        )
                    );
                end
            endcase

            if (reqStatus == RDMA_REQ_ST_NORMAL && !hasErrHappened) begin
                cntrl.contextRQ.setNextDmaWriteAddr(nextDmaWriteAddr);
                cntrl.contextRQ.setSendWriteReqPktNum(sendWriteReqPktNum);
                // $display(
                //     "time=%0t: nextDmaWriteAddr=%h, sendWriteReqPktNum=%0d",
                //     $time, nextDmaWriteAddr, sendWriteReqPktNum
                // );
            end
        end

        reqRemainingLenCalcQ.enq(tuple6(
            pktMetaData, reqStatus, permCheckInfo,
            reqPktInfo, dupReadReqStartState, curDmaWriteAddr
        ));
        // $display(
        //     "time=%0t: 13th stage, bth.opcode=", $time, fshow(bth.opcode),
        //     ", bth.psn=%h", bth.psn, ", reqStatus=", fshow(reqStatus)
        // );
    endrule

    // This rule still runs at retry or error state
    rule calcNormalSendWriteReqDmaRemainingLen if (cntrl.isNonErr || cntrl.isERR);
        let {
            pktMetaData, reqStatus, permCheckInfo,
            reqPktInfo, dupReadReqStartState, curDmaWriteAddr
        } = reqRemainingLenCalcQ.first;
        reqRemainingLenCalcQ.deq;

        let bth        = reqPktInfo.bth;
        let rdmaHeader = pktMetaData.pktHeader;
        let isSendReq  = reqPktInfo.isSendReq;
        let isWriteReq = reqPktInfo.isWriteReq;
        let isOnlyPkt  = reqPktInfo.isOnlyPkt;
        let isFirstPkt = reqPktInfo.isFirstPkt;
        let isMidPkt   = reqPktInfo.isMidPkt;
        let isLastPkt  = reqPktInfo.isLastPkt;

        let remainingDmaWriteLen = cntrl.contextRQ.getRemainingDmaWriteLen;
        let pktPayloadLen        = pktMetaData.pktPayloadLen;
        // let enoughDmaSpace       = False;
        let oneAsPSN             = 1;

        if (isSendReq || isWriteReq) begin
            case ( { pack(isOnlyPkt), pack(isFirstPkt), pack(isMidPkt), pack(isLastPkt) } )
                4'b1000: begin // isOnlyRdmaOpCode(bth.opcode)
                    // Exact remaining length is not necessory, zero or non-zero is enough
                    remainingDmaWriteLen = lenSubtractPktLen(permCheckInfo.totalLen, pktPayloadLen, cntrl.getPMTU);
                    // enoughDmaSpace       = lenGtEqPktLen(permCheckInfo.totalLen, pktPayloadLen, cntrl.getPMTU);
                end
                4'b0100: begin // isFirstRdmaOpCode(bth.opcode)
                    remainingDmaWriteLen = lenSubtractPsnMultiplyPMTU(permCheckInfo.totalLen, oneAsPSN, cntrl.getPMTU);
                    // enoughDmaSpace       = lenGtEqPMTU(permCheckInfo.totalLen, cntrl.getPMTU);
                end
                4'b0010: begin // isMiddleRdmaOpCode(bth.opcode)
                    remainingDmaWriteLen = lenSubtractPsnMultiplyPMTU(cntrl.contextRQ.getRemainingDmaWriteLen, oneAsPSN, cntrl.getPMTU);
                    // enoughDmaSpace       = lenGtEqPMTU(cntrl.contextRQ.getRemainingDmaWriteLen, cntrl.getPMTU);
                end
                4'b0001: begin // isLastRdmaOpCode(bth.opcode)
                    // Exact remaining length is not necessory, zero or non-zero is enough
                    remainingDmaWriteLen = lenSubtractPktLen(cntrl.contextRQ.getRemainingDmaWriteLen, pktPayloadLen, cntrl.getPMTU);
                    // enoughDmaSpace       = lenGtEqPktLen(cntrl.contextRQ.getRemainingDmaWriteLen, pktPayloadLen, cntrl.getPMTU);
                end
                default: begin
                    immFail(
                        "unreachible case @ mkReqHandleRQ",
                        $format(
                            "isOnlyPkt=", fshow(isOnlyPkt),
                            ", isFirstPkt=", fshow(isFirstPkt),
                            ", isMidPkt=", fshow(isMidPkt),
                            ", isLastPkt=", fshow(isLastPkt)
                        )
                    );
                end
            endcase

            if (reqStatus == RDMA_REQ_ST_NORMAL && !hasErrHappened) begin
                cntrl.contextRQ.setRemainingDmaWriteLen(remainingDmaWriteLen);
                // $display(
                //     "time=%0t: remainingDmaWriteLen=%h, enoughDmaSpace=",
                //     $time, remainingDmaWriteLen, fshow(enoughDmaSpace)
                // );
            end
        end

        // reqTotalLenCalcQ.enq(tuple8(
        reqEnoughDmaSpaceQ.enq(tuple8(
            pktMetaData, reqStatus, permCheckInfo, reqPktInfo, dupReadReqStartState,
            curDmaWriteAddr, remainingDmaWriteLen, cntrl.contextRQ.getRemainingDmaWriteLen
        ));
        // $display(
        //     "time=%0t: 14th stage, bth.opcode=", $time, fshow(bth.opcode),
        //     ", bth.psn=%h", bth.psn, ", reqStatus=", fshow(reqStatus)
        // );
    endrule

    // This rule still runs at retry or error state
    rule calcNormalSendWriteReqEnoughDmaSpace if (cntrl.isNonErr || cntrl.isERR);
        let {
            pktMetaData, reqStatus, permCheckInfo, reqPktInfo, dupReadReqStartState,
            curDmaWriteAddr, remainingDmaWriteLen, preRemainingDmaWriteLen
        } = reqEnoughDmaSpaceQ.first;
        reqEnoughDmaSpaceQ.deq;

        let bth        = reqPktInfo.bth;
        let rdmaHeader = pktMetaData.pktHeader;
        let isSendReq  = reqPktInfo.isSendReq;
        let isWriteReq = reqPktInfo.isWriteReq;
        let isOnlyPkt  = reqPktInfo.isOnlyPkt;
        let isFirstPkt = reqPktInfo.isFirstPkt;
        let isMidPkt   = reqPktInfo.isMidPkt;
        let isLastPkt  = reqPktInfo.isLastPkt;

        let pktPayloadLen  = pktMetaData.pktPayloadLen;
        let enoughDmaSpace = False;

        if (isSendReq || isWriteReq) begin
            case ( { pack(isOnlyPkt), pack(isFirstPkt), pack(isMidPkt), pack(isLastPkt) } )
                4'b1000: begin // isOnlyRdmaOpCode(bth.opcode)
                    enoughDmaSpace = lenGtEqPktLen(permCheckInfo.totalLen, pktPayloadLen, cntrl.getPMTU);
                end
                4'b0100: begin // isFirstRdmaOpCode(bth.opcode)
                    enoughDmaSpace = lenGtEqPMTU(permCheckInfo.totalLen, cntrl.getPMTU);
                end
                4'b0010: begin // isMiddleRdmaOpCode(bth.opcode)
                    enoughDmaSpace = lenGtEqPMTU(preRemainingDmaWriteLen, cntrl.getPMTU);
                end
                4'b0001: begin // isLastRdmaOpCode(bth.opcode)
                    enoughDmaSpace = lenGtEqPktLen(preRemainingDmaWriteLen, pktPayloadLen, cntrl.getPMTU);
                end
                default: begin
                    immFail(
                        "unreachible case @ mkReqHandleRQ",
                        $format(
                            "isOnlyPkt=", fshow(isOnlyPkt),
                            ", isFirstPkt=", fshow(isFirstPkt),
                            ", isMidPkt=", fshow(isMidPkt),
                            ", isLastPkt=", fshow(isLastPkt)
                        )
                    );
                end
            endcase
        end

        reqTotalLenCalcQ.enq(tuple8(
            pktMetaData, reqStatus, permCheckInfo, reqPktInfo, dupReadReqStartState,
            curDmaWriteAddr, remainingDmaWriteLen, enoughDmaSpace
        ));
        // $display(
        //     "time=%0t: 15th stage, bth.opcode=", $time, fshow(bth.opcode),
        //     ", bth.psn=%h", bth.psn, ", reqStatus=", fshow(reqStatus)
        // );
    endrule

    // This rule still runs at retry or error state
    rule calcNormalSendWriteReqDmaTotalLen if (cntrl.isNonErr || cntrl.isERR);
        let {
            pktMetaData, reqStatus, permCheckInfo, reqPktInfo, dupReadReqStartState,
            curDmaWriteAddr, remainingDmaWriteLen, enoughDmaSpace // preRemainingDmaWriteLen
        } = reqTotalLenCalcQ.first;
        reqTotalLenCalcQ.deq;

        let bth        = reqPktInfo.bth;
        let rdmaHeader = pktMetaData.pktHeader;
        let isSendReq  = reqPktInfo.isSendReq;
        let isWriteReq = reqPktInfo.isWriteReq;
        let isOnlyPkt  = reqPktInfo.isOnlyPkt;
        let isFirstPkt = reqPktInfo.isFirstPkt;
        let isMidPkt   = reqPktInfo.isMidPkt;
        let isLastPkt  = reqPktInfo.isLastPkt;

        Length totalDmaWriteLen  = cntrl.contextRQ.getTotalDmaWriteLen;
        let pktPayloadLen        = pktMetaData.pktPayloadLen;
        // let enoughDmaSpace       = False;
        let isLastPayloadLenZero = False;
        let oneAsPSN             = 1;

        if (isSendReq || isWriteReq) begin
            case ( { pack(isOnlyPkt), pack(isFirstPkt), pack(isMidPkt), pack(isLastPkt) } )
                4'b1000: begin // isOnlyRdmaOpCode(bth.opcode)
                    totalDmaWriteLen     = zeroExtend(pktPayloadLen);
                    // enoughDmaSpace       = lenGtEqPktLen(permCheckInfo.totalLen, pktPayloadLen, cntrl.getPMTU);
                end
                4'b0100: begin // isFirstRdmaOpCode(bth.opcode)
                    totalDmaWriteLen     = lenAddPsnMultiplyPMTU(0, oneAsPSN, cntrl.getPMTU);
                    // enoughDmaSpace       = lenGtEqPMTU(permCheckInfo.totalLen, cntrl.getPMTU);
                end
                4'b0010: begin // isMiddleRdmaOpCode(bth.opcode)
                    totalDmaWriteLen     = lenAddPsnMultiplyPMTU(cntrl.contextRQ.getTotalDmaWriteLen, oneAsPSN, cntrl.getPMTU);
                    // enoughDmaSpace       = lenGtEqPMTU(preRemainingDmaWriteLen, cntrl.getPMTU);
                end
                4'b0001: begin // isLastRdmaOpCode(bth.opcode)
                    totalDmaWriteLen     = lenAddPktLen(cntrl.contextRQ.getTotalDmaWriteLen, pktPayloadLen, cntrl.getPMTU);
                    // enoughDmaSpace       = lenGtEqPktLen(preRemainingDmaWriteLen, pktPayloadLen, cntrl.getPMTU);
                    isLastPayloadLenZero = pktMetaData.isZeroPayloadLen;
                end
                default: begin
                    immFail(
                        "unreachible case @ mkReqHandleRQ",
                        $format(
                            "isOnlyPkt=", fshow(isOnlyPkt),
                            ", isFirstPkt=", fshow(isFirstPkt),
                            ", isMidPkt=", fshow(isMidPkt),
                            ", isLastPkt=", fshow(isLastPkt)
                        )
                    );
                end
            endcase

            if (reqStatus == RDMA_REQ_ST_NORMAL && !hasErrHappened) begin
                cntrl.contextRQ.setTotalDmaWriteLen(totalDmaWriteLen);
                // $display(
                //     "time=%0t: totalDmaWriteLen=%h, enoughDmaSpace=",
                //     $time, totalDmaWriteLen, fshow(enoughDmaSpace)
                // );
            end
        end

        let reqLenCheckResult = ReqLenCheckResult {
            enoughDmaSpace      : enoughDmaSpace,
            isLastPayloadLenZero: isLastPayloadLenZero,
            curDmaWriteAddr     : curDmaWriteAddr,
            remainingDmaWriteLen: remainingDmaWriteLen,
            totalDmaWriteLen    : totalDmaWriteLen
        };
        reqLenCheckQ.enq(tuple6(
            pktMetaData, reqStatus, permCheckInfo,
            reqPktInfo, reqLenCheckResult, dupReadReqStartState
        ));
        // $display(
        //     "time=%0t: 16th stage, bth.opcode=", $time, fshow(bth.opcode),
        //     ", bth.psn=%h", bth.psn, ", reqStatus=", fshow(reqStatus)
        // );
    endrule

    // This rule still runs at retry or error state
    rule checkReqLen if (cntrl.isNonErr || cntrl.isERR);
        let {
            pktMetaData, reqStatus, permCheckInfo,
            reqPktInfo, reqLenCheckResult, dupReadReqStartState
        } = reqLenCheckQ.first;
        reqLenCheckQ.deq;

        let enoughDmaSpace       = reqLenCheckResult.enoughDmaSpace;
        let isLastPayloadLenZero = reqLenCheckResult.isLastPayloadLenZero;
        let curDmaWriteAddr      = reqLenCheckResult.curDmaWriteAddr;
        let remainingDmaWriteLen = reqLenCheckResult.remainingDmaWriteLen;
        let totalDmaWriteLen     = reqLenCheckResult.totalDmaWriteLen;

        let bth        = reqPktInfo.bth;
        let isSendReq  = reqPktInfo.isSendReq;
        let isWriteReq = reqPktInfo.isWriteReq;
        let isOnlyPkt  = reqPktInfo.isOnlyPkt;
        let isLastPkt  = reqPktInfo.isLastPkt;

        if (isSendReq || isWriteReq) begin
            if (reqStatus == RDMA_REQ_ST_NORMAL && !hasErrHappened) begin
                let noRemainingDmaWrite = isZero(remainingDmaWriteLen);
                let writeReqLenMatch = (isWriteReq && (isLastPkt || isOnlyPkt)) ?
                    noRemainingDmaWrite : True;
                if (!enoughDmaSpace || !writeReqLenMatch || isLastPayloadLenZero) begin
                    // Write request length not match RETH length,
                    // or RecvReq has not enough space,
                    // or last packet has no payload
                    reqStatus = getInvReqStatusByTransType(bth.trans);
                    immAssert(
                        reqStatus != RDMA_REQ_ST_UNKNOWN,
                        "reqStatus assertion @ mkReqHandleRQ",
                        $format(
                            "reqStatus=", fshow(reqStatus), " should not be unknown"
                        )
                    );
                    $display(
                        "time=%0t:", $time,
                        " bth.opcode=", fshow(bth.opcode), ", bth.psn=%h", bth.psn,
                        ", permCheckInfo.totalLen=%0d", permCheckInfo.totalLen,
                        ", remainingDmaWriteLen=%0d", remainingDmaWriteLen,
                        ", totalDmaWriteLen=%0d", totalDmaWriteLen,
                        ", noRemainingDmaWrite=", fshow(noRemainingDmaWrite),
                        ", writeReqLenMatch=", fshow(writeReqLenMatch),
                        ", enoughDmaSpace=", fshow(enoughDmaSpace),
                        ", isLastPayloadLenZero=", fshow(isLastPayloadLenZero),
                        ", reqStatus=", fshow(reqStatus)
                    );
                end
                else if (isSendReq && (isLastPkt || isOnlyPkt)) begin
                    // Update send request total length
                    permCheckInfo.totalLen = totalDmaWriteLen;
                end
            end
        end

        issuePayloadConReqQ.enq(tuple6(
            pktMetaData, reqStatus, permCheckInfo,
            reqPktInfo, curDmaWriteAddr, dupReadReqStartState
        ));
        // $display(
        //     "time=%0t: 17th stage, bth.opcode=", $time, fshow(bth.opcode),
        //     ", bth.psn=%h", bth.psn, ", reqStatus=", fshow(reqStatus)
        // );
    endrule

    // This rule still runs at retry or error state
    rule issuePayloadConReqOrDiscard if (cntrl.isNonErr || cntrl.isERR);
        let {
            pktMetaData, reqStatus, permCheckInfo,
            reqPktInfo, curDmaWriteAddr, dupReadReqStartState
        } = issuePayloadConReqQ.first;
        issuePayloadConReqQ.deq;

        let bth              = reqPktInfo.bth;
        let isSendReq        = reqPktInfo.isSendReq;
        let isWriteReq       = reqPktInfo.isWriteReq;
        let isZeroDmaLen     = permCheckInfo.isZeroDmaLen;
        let isZeroPayloadLen = pktMetaData.isZeroPayloadLen;

        if (reqStatus == RDMA_REQ_ST_NORMAL && !hasErrHappened) begin
            if ((isSendReq || isWriteReq) && !isZeroDmaLen) begin
                let payloadConReq = PayloadConReq {
                    fragNum      : pktMetaData.pktFragNum,
                    consumeInfo  : tagged SendWriteReqReadRespInfo DmaWriteMetaData {
                        initiator: DMA_INIT_RQ_WR,
                        sqpn     : cntrl.getSQPN,
                        startAddr: curDmaWriteAddr,
                        len      : pktMetaData.pktPayloadLen,
                        psn      : bth.psn
                    }
                };
                payloadConReqOutQ.enq(payloadConReq);
            end
        end
        // if (reqStatus != RDMA_REQ_ST_NORMAL || hasErrHappened) begin
        else if (!isZeroPayloadLen) begin
            // Discard request payload if duplicate, error or flushing
            let initiator = DMA_INIT_RQ_DISCARD;
            genDiscardPayloadReq(
                pktMetaData.pktFragNum, initiator, cntrl.getSQPN,
                curDmaWriteAddr, pktMetaData.pktPayloadLen, bth.psn,
                payloadConReqOutQ
            );
        end

        // Set internal error state if any error request status,
        // and no more DMA requests after first error.
        let hasErrIncurred = hasErrHappened;
        if (isErrReqStatus(reqStatus) && !hasErrHappened) begin
            hasErrIncurred         = True;
            reqStatusErrNotifyReg <= True;
            $display(
                "time=%0t:", $time,
                " set reqStatusErrNotifyReg",
                ", reqStatus=", fshow(reqStatus)
            );
        end

        issuePayloadGenReqQ.enq(tuple6(
            pktMetaData, reqStatus, permCheckInfo, reqPktInfo,
            hasErrIncurred, dupReadReqStartState
        ));
        // $display(
        //     "time=%0t: 18th stage, bth.opcode=", $time, fshow(bth.opcode),
        //     ", bth.psn=%h", bth.psn, ", reqStatus=", fshow(reqStatus)
        // );
    endrule

    // This rule still runs at retry or error state
    rule issuePayloadGenReq if (cntrl.isNonErr || cntrl.isERR);
        let {
            pktMetaData, reqStatus, permCheckInfo, reqPktInfo, hasErrIncurred, dupReadReqStartState
        } = issuePayloadGenReqQ.first;
        issuePayloadGenReqQ.deq;

        let bth        = reqPktInfo.bth;
        let rdmaHeader = pktMetaData.pktHeader;
        let atomicEth  = extractAtomicEth(rdmaHeader.headerData, bth.trans);

        // let isSendReq    = reqPktInfo.isSendReq;
        // let isWriteReq   = reqPktInfo.isWriteReq;
        let isReadReq    = reqPktInfo.isReadReq;
        let isAtomicReq  = reqPktInfo.isAtomicReq;
        let isZeroDmaLen = permCheckInfo.isZeroDmaLen;

        let expectReadRespPayload = False;
        let expectAtomicRespOrig  = False;
        if (!hasErrIncurred) begin
            if (
                !isZeroDmaLen && isReadReq &&
                (reqStatus == RDMA_REQ_ST_NORMAL || reqStatus == RDMA_REQ_ST_DUP)
            ) begin
                let payloadGenReq = PayloadGenReq {
                    addPadding   : True,
                    segment      : True,
                    pmtu         : cntrl.getPMTU,
                    dmaReadReq   : DmaReadReq {
                        initiator: DMA_INIT_RQ_RD,
                        sqpn     : cntrl.getSQPN,
                        startAddr: permCheckInfo.reqAddr, // reth.va
                        len      : permCheckInfo.totalLen, // reth.dlen
                        wrID     : dontCareValue
                    }
                };
                payloadGenReqOutQ.enq(payloadGenReq);
                expectReadRespPayload = True;
            end
            else if (reqStatus == RDMA_REQ_ST_NORMAL && isAtomicReq) begin
                let atomicOpReq = AtomicOpReq {
                    initiator    : DMA_INIT_RQ_ATOMIC,
                    casOrFetchAdd: bth.opcode == COMPARE_SWAP,
                    startAddr    : atomicEth.va,
                    compData     : atomicEth.comp,
                    swapData     : atomicEth.swap,
                    sqpn         : cntrl.getSQPN,
                    psn          : bth.psn
                };
                // atomicOpReqQ.enq(atomicOpReq);
                atomicSrv.request.put(atomicOpReq);
                expectAtomicRespOrig = True;
            end
        end

        let respPktGenInfo = RespPktGenInfo {
            hasErrIncurred          : hasErrIncurred,
            shouldGenResp           : False,
            expectReadRespPayload   : expectReadRespPayload,
            expectAtomicRespOrig    : expectAtomicRespOrig,
            expectDupAtomicCheckResp: False,
            atomicAckOrig           : tagged Invalid,
            dupReadReqStartState    : dupReadReqStartState
        };
        respGenCheck4NormalCaseQ.enq(tuple5(
            pktMetaData, reqStatus, permCheckInfo, reqPktInfo, respPktGenInfo
        ));
        // $display(
        //     "time=%0t: 19th stage, bth.opcode=", $time, fshow(bth.opcode),
        //     ", bth.psn=%h", bth.psn, ", reqStatus=", fshow(reqStatus),
        //     ", expectReadRespPayload=", fshow(expectReadRespPayload),
        //     ", expectAtomicRespOrig=", fshow(expectAtomicRespOrig)
        // );
    endrule

    // This rule still runs at retry or error state
    rule shouldGenResp4NormalCase if (cntrl.isNonErr || cntrl.isERR);
        let {
            pktMetaData, reqStatus, permCheckInfo, reqPktInfo, respPktGenInfo
        } = respGenCheck4NormalCaseQ.first;
        respGenCheck4NormalCaseQ.deq;

        let bth = reqPktInfo.bth;

        let isSendReq       = reqPktInfo.isSendReq;
        let isWriteReq      = reqPktInfo.isWriteReq;
        let isReadReq       = reqPktInfo.isReadReq;
        let isAtomicReq     = reqPktInfo.isAtomicReq;
        let isLastOrOnlyPkt = reqPktInfo.isLastOrOnlyPkt;
        let hasErrIncurred  = respPktGenInfo.hasErrIncurred;

        let shouldGenResp = False;
        // let shouldDiscard = False;
        let qpHasResp     = qpNeedGenResp(bth.trans);

        let reloadPendingWorkReqCnt   = False;
        let decrPendingWorkReqCnt     = False;
        let shouldGenRespEvenNoAckReq = isLastOrOnlyPkt && isCoalesceWorkReqCntZeroReg;
        if (reqStatus == RDMA_REQ_ST_NORMAL) begin
            case ({ pack(isSendReq), pack(isWriteReq), pack(isReadReq), pack(isAtomicReq) })
                4'b1000, 4'b0100: begin // Send/Write requests
                    if (bth.ackReq || shouldGenRespEvenNoAckReq) begin
                        shouldGenResp = qpHasResp;
                        reloadPendingWorkReqCnt = True;
                    end
                    else begin
                        decrPendingWorkReqCnt = isLastOrOnlyPkt;
                    end
                end
                4'b0010: begin // Read requests
                    shouldGenResp = qpHasResp;
                    reloadPendingWorkReqCnt = True;
                end
                4'b0001: begin // Atomic requests
                    if (respPktGenInfo.expectAtomicRespOrig) begin
                        shouldGenResp = qpHasResp;
                        reloadPendingWorkReqCnt = True;
                    end
                end
                default: begin
                    immFail(
                        "unreachible case @ mkReqHandleRQ",
                        $format(
                            "isSendReq=", fshow(isSendReq),
                            ", isWriteReq=", fshow(isWriteReq),
                            ", isReadReq=", fshow(isReadReq),
                            ", isAtomicReq=", fshow(isAtomicReq)
                        )
                    );
                end
            endcase

            if (qpHasResp && !hasErrIncurred) begin
                // The counter will record how many normal send/write requests
                // without AckReq, and if more than MAX_QP_WR consecutive send/write requests
                // without AckReq, enforce a response to avoid SQ deadlock.
                if (reloadPendingWorkReqCnt) begin
                    coalesceWorkReqCnt <= cntrl.getPendingWorkReqNum - 1;
                    // cntrl.contextRQ.setPendingWorkReqCnt(cntrl.getPendingWorkReqNum - 1);
                    isCoalesceWorkReqCntZeroReg <= isOne(cntrl.getPendingWorkReqNum);
                end
                else if (decrPendingWorkReqCnt) begin
                    coalesceWorkReqCnt.decr(1);
                    // cntrl.contextRQ.setPendingWorkReqCnt(cntrl.contextRQ.getPendingWorkReqCnt - 1);
                    isCoalesceWorkReqCntZeroReg <= isOne(coalesceWorkReqCnt);
                end
                // $display(
                //     "time=%0t:", $time, " bth.ackReq=", fshow(bth.ackReq),
                //     ", coalesceWorkReqCnt=%0d", coalesceWorkReqCnt,
                //     ", reloadPendingWorkReqCnt=", fshow(reloadPendingWorkReqCnt),
                //     ", decrPendingWorkReqCnt=", fshow(decrPendingWorkReqCnt)
                // );
            end
        end

        // Even no response generated for some requests,
        // they might need to wait for DMA write responses,
        // so still need send to next stage
        respPktGenInfo.shouldGenResp = shouldGenResp;

        respGenCheck4OtherCasesQ.enq(tuple5(
            pktMetaData, reqStatus, permCheckInfo, reqPktInfo, respPktGenInfo
        ));
        // $display(
        //     "time=%0t: 20th stage, bth.opcode=", $time, fshow(bth.opcode),
        //     ", bth.psn=%h", bth.psn, ", bth.ackReq=", fshow(bth.ackReq),
        //     // ", shouldDiscard=", fshow(shouldDiscard),
        //     ", shouldGenResp=", fshow(shouldGenResp),
        //     ", reqStatus=", fshow(reqStatus)
        // );
    endrule

    // This rule still runs at retry or error state
    rule shouldGenResp4OtherCases if (cntrl.isNonErr || cntrl.isERR);
        let {
            pktMetaData, reqStatus, permCheckInfo, reqPktInfo, respPktGenInfo
        } = respGenCheck4OtherCasesQ.first;
        respGenCheck4OtherCasesQ.deq;

        let bth = reqPktInfo.bth;
        // let rdmaHeader = pktMetaData.pktHeader;

        let isSendReq       = reqPktInfo.isSendReq;
        let isWriteReq      = reqPktInfo.isWriteReq;
        let isReadReq       = reqPktInfo.isReadReq;
        let isAtomicReq     = reqPktInfo.isAtomicReq;
        let isLastOrOnlyPkt = reqPktInfo.isLastOrOnlyPkt;
        // let hasErrIncurred = respPktGenInfo.hasErrIncurred;

        let shouldGenResp = False;
        let shouldDiscard = False;
        let qpHasResp     = qpNeedGenResp(bth.trans);

        case (reqStatus)
            RDMA_REQ_ST_NORMAL: begin
                shouldGenResp = respPktGenInfo.shouldGenResp;
            end
            RDMA_REQ_ST_DUP: begin
                case ({ pack(isSendReq), pack(isWriteReq), pack(isReadReq), pack(isAtomicReq) })
                    4'b1000, 4'b0100: begin // Duplicate send/Write requests
                        if (bth.ackReq || isLastOrOnlyPkt) begin
                            // Must generate responses for duplicate send/write requests
                            // when last or only packets
                            shouldGenResp = qpHasResp;
                        end
                    end
                    4'b0010: begin // Duplicate read requests
                        shouldGenResp = qpHasResp;
                    end
                    4'b0001: begin // Duplicate atomic requests
                        // Duplicate atomic requests will be checked in later stages
                    end
                    default: begin
                        immFail(
                            "unreachible case @ mkReqHandleRQ",
                            $format(
                                "isSendReq=", fshow(isSendReq),
                                ", isWriteReq=", fshow(isWriteReq),
                                ", isReadReq=", fshow(isReadReq),
                                ", isAtomicReq=", fshow(isAtomicReq)
                            )
                        );
                    end
                endcase
            end
            RDMA_REQ_ST_SEQ_ERR,
            RDMA_REQ_ST_RNR    ,
            RDMA_REQ_ST_INV_REQ,
            RDMA_REQ_ST_INV_RD ,
            RDMA_REQ_ST_RMT_ACC,
            RDMA_REQ_ST_RMT_OP : begin
                shouldGenResp = qpHasResp;
            end
            RDMA_REQ_ST_DISCARD     ,
            RDMA_REQ_ST_ERR_FLUSH_RR: begin
                shouldDiscard = True;
            end
            default: begin
                immFail(
                    "unreachible case @ mkReqHandleRQ",
                    $format("reqStatus=", fshow(reqStatus))
                );
            end
        endcase

        // Set shouldGenResp even when hasErrIncurred
        respPktGenInfo.shouldGenResp = shouldGenResp;

        respCountQ.enq(tuple5(
            pktMetaData, reqStatus, permCheckInfo, reqPktInfo, respPktGenInfo
        ));
        // $display(
        //     "time=%0t: 21st stage, bth.opcode=", $time, fshow(bth.opcode),
        //     ", bth.psn=%h", bth.psn, ", bth.ackReq=", fshow(bth.ackReq),
        //     ", shouldDiscard=", fshow(shouldDiscard),
        //     ", shouldGenResp=", fshow(shouldGenResp),
        //     ", reqStatus=", fshow(reqStatus)
        // );
    endrule

    // This rule still runs at retry or error state
    rule countPendingResp if (cntrl.isNonErr || cntrl.isERR);
        let {
            pktMetaData, reqStatus, permCheckInfo, reqPktInfo, respPktGenInfo
        } = respCountQ.first;

        let bth = reqPktInfo.bth;

        let remainingRespPktNum  = cntrl.contextRQ.getRespPktNum;
        // let isFirstOrOnlyRespPkt = isFirstOrOnlyRespPktReg || hasErrRespGenReg;
        // let isLastOrOnlyRespPkt  = isLastOrOnlyRespPkt || hasErrRespGenReg;
        let isFirstOrOnlyRespPkt = isFirstOrOnlyRespPktReg;
        let isLastOrOnlyRespPkt  = reqPktInfo.isOnlyRespPkt ||
            (!isFirstOrOnlyRespPktReg && cntrl.contextRQ.getIsRespPktNumZero);
        // If hasErrRespGenReg, no need to count response packets
        isFirstOrOnlyRespPktReg <= isLastOrOnlyRespPkt || hasErrRespGenReg;

        if (hasErrRespGenReg) begin
            // No responses after error response
            respCountQ.deq;
        end
        else begin
            if (isLastOrOnlyRespPkt) begin
                respCountQ.deq;
            end

            if (isFirstOrOnlyRespPkt) begin
                // Current cycle output first/only packet,
                // so the remaining pktNum = totalPktNum - 2
                if (reqPktInfo.isOnlyRespPkt) begin
                    remainingRespPktNum = 0;
                end
                else begin
                    remainingRespPktNum = reqPktInfo.respPktNum - 2;
                end
                cntrl.contextRQ.setRespPktNum(remainingRespPktNum);
            end
            else if (!isLastOrOnlyRespPkt) begin
                cntrl.contextRQ.setRespPktNum(remainingRespPktNum - 1);
            end
        end

        let respPktSeqInfo = RespPktSeqInfo {
            isFirstOrOnlyRespPkt: isFirstOrOnlyRespPkt,
            isLastOrOnlyRespPkt : isLastOrOnlyRespPkt
        };
        respPsnAndMsnQ.enq(tuple6(
            pktMetaData, reqStatus, permCheckInfo, reqPktInfo, respPktGenInfo, respPktSeqInfo
        ));
        // $display(
        //     "time=%0t: 22nd stage, bth.opcode=", $time, fshow(bth.opcode),
        //     ", bth.psn=%h", bth.psn, ", bth.ackReq=", fshow(bth.ackReq),
        //     ", isOnlyRespPkt=", fshow(reqPktInfo.isOnlyRespPkt),
        //     ", shouldGenResp=", fshow(respPktGenInfo.shouldGenResp),
        //     ", hasErrRespGenReg=", fshow(hasErrRespGenReg),
        //     // ", isFirstOrOnlyRespPktReg=", fshow(isFirstOrOnlyRespPktReg),
        //     ", isFirstOrOnlyRespPkt=", fshow(isFirstOrOnlyRespPkt),
        //     ", isLastOrOnlyRespPkt=", fshow(isLastOrOnlyRespPkt),
        //     ", reqStatus=", fshow(reqStatus),
        //     ", reqPktInfo.respPktNum=%0d", reqPktInfo.respPktNum,
        //     ", remainingRespPktNum=%0d", remainingRespPktNum,
        //     ", respPktSeqInfo=", fshow(respPktSeqInfo)
        // );
    endrule

    // This rule still runs at retry or error state
    rule updateRespPsnAndMsn if (cntrl.isNonErr || cntrl.isERR);
        let {
            pktMetaData, reqStatus, permCheckInfo, reqPktInfo, respPktGenInfo, respPktSeqInfo
        } = respPsnAndMsnQ.first;
        respPsnAndMsnQ.deq;

        let bth       = reqPktInfo.bth;
        let isReadReq = reqPktInfo.isReadReq;

        let isLastOrOnlyReqPkt   = reqPktInfo.isLastOrOnlyPkt;
        let isFirstOrOnlyRespPkt = respPktSeqInfo.isFirstOrOnlyRespPkt;
        let isLastOrOnlyRespPkt  = respPktSeqInfo.isLastOrOnlyRespPkt;

        let respPSN = isFirstOrOnlyRespPkt ? bth.psn : cntrl.contextRQ.getCurRespPSN;
        let msn     = cntrl.contextRQ.getMSN;

        if (!hasErrRespGenReg) begin
            cntrl.contextRQ.setCurRespPSN(respPSN + 1);

            if (reqStatus == RDMA_REQ_ST_NORMAL && isLastOrOnlyReqPkt && isLastOrOnlyRespPkt) begin
                msn = msn + 1;
                cntrl.contextRQ.setMSN(msn);
            end

            if (
                reqStatus == RDMA_REQ_ST_DUP        &&
                respPktGenInfo.dupReadReqStartState == DUP_READ_REQ_START_FROM_MIDDLE
            ) begin
                immAssert(
                    isReadReq,
                    "isReadReq assertion @ mkReqHandleRQ",
                    $format(
                        "isReadReq=", fshow(isReadReq),
                        " should be duplicate read request when dupReadReqStartState=",
                        fshow(respPktGenInfo.dupReadReqStartState)
                    )
                );

                isFirstOrOnlyRespPkt = False;
            end
        end

        let respPktHeaderInfo = RespPktHeaderInfo {
            psn                 : respPSN,
            msn                 : msn,
            isFirstOrOnlyRespPkt: isFirstOrOnlyRespPkt,
            isLastOrOnlyRespPkt : isLastOrOnlyRespPkt
        };
        // respCheckQ.enq(tuple6(
        waitAtomicRespQ.enq(tuple6(
            pktMetaData, reqStatus, permCheckInfo,
            reqPktInfo, respPktGenInfo, respPktHeaderInfo
        ));
        // $display(
        //     "time=%0t: 23rd stage, bth.opcode=", $time, fshow(bth.opcode),
        //     ", bth.psn=%h", bth.psn, ", bth.ackReq=", fshow(bth.ackReq),
        //     ", isOnlyRespPkt=", fshow(reqPktInfo.isOnlyRespPkt),
        //     ", shouldGenResp=", fshow(respPktGenInfo.shouldGenResp),
        //     ", hasErrRespGenReg=", fshow(hasErrRespGenReg),
        //     ", isFirstOrOnlyRespPkt=", fshow(isFirstOrOnlyRespPkt),
        //     ", isLastOrOnlyRespPkt=", fshow(isLastOrOnlyRespPkt),
        //     ", reqStatus=", fshow(reqStatus),
        //     ", reqPktInfo.respPktNum=%0d", reqPktInfo.respPktNum,
        //     // ", remainingRespPktNum=%0d", remainingRespPktNum,
        //     ", respPktHeaderInfo=", fshow(respPktHeaderInfo)
        // );
    endrule

    // This rule still runs at retry or error state
    rule waitAtomicResp if (cntrl.isNonErr || cntrl.isERR);
        let {
            pktMetaData, reqStatus, permCheckInfo,
            reqPktInfo, respPktGenInfo, respPktHeaderInfo
        } = waitAtomicRespQ.first;
        waitAtomicRespQ.deq;

        let bth           = reqPktInfo.bth;
        let isAtomicReq   = reqPktInfo.isAtomicReq;
        let atomicAckOrig = tagged Invalid;

        if (respPktGenInfo.expectAtomicRespOrig) begin
            immAssert(
                reqStatus == RDMA_REQ_ST_NORMAL,
                "reqStatus normal assertion @ ReqHandleRQ",
                $format(
                    "reqStatus=", fshow(RDMA_REQ_ST_NORMAL),
                    " should be RDMA_REQ_ST_NORMAL when expectAtomicRespOrig=",
                    fshow(respPktGenInfo.expectAtomicRespOrig)
                )
            );
            immAssert(
                isAtomicReq,
                "isAtomicReq assertion @ ReqHandleRQ",
                $format(
                    "isAtomicReq=", fshow(isAtomicReq),
                    " should be true when expectAtomicRespOrig=",
                    fshow(respPktGenInfo.expectAtomicRespOrig),
                    " but bth.opcode=", fshow(bth.opcode)
                )
            );

            let atomicOpResp <- atomicSrv.response.get;
            atomicAckOrig = tagged Valid atomicOpResp.original;
        end

        respPktGenInfo.atomicAckOrig = atomicAckOrig;

        atomicCacheInsertQ.enq(tuple6(
            pktMetaData, reqStatus, permCheckInfo,
            reqPktInfo, respPktGenInfo, respPktHeaderInfo
        ));
        // $display(
        //     "time=%0t: 24th stage, bth.opcode=", $time, fshow(bth.opcode),
        //     ", bth.psn=%h", bth.psn,
        //     ", expectAtomicRespOrig=", fshow(respPktGenInfo.expectAtomicRespOrig),
        //     ", isAtomicReq=", fshow(isAtomicReq),
        //     ", reqStatus=", fshow(reqStatus)
        // );
    endrule

    rule insertIntoAtomicCache if (cntrl.isNonErr || cntrl.isERR);
        let {
            pktMetaData, reqStatus, permCheckInfo,
            reqPktInfo, respPktGenInfo, respPktHeaderInfo
        } = atomicCacheInsertQ.first;
        atomicCacheInsertQ.deq;

        let bth         = reqPktInfo.bth;
        let rdmaHeader  = pktMetaData.pktHeader;
        let atomicEth   = extractAtomicEth(rdmaHeader.headerData, bth.trans);
        let isAtomicReq = reqPktInfo.isAtomicReq;

        let hasErrIncurred = respPktGenInfo.hasErrIncurred;
        if (reqStatus == RDMA_REQ_ST_NORMAL && isAtomicReq && !hasErrIncurred) begin
            immAssert(
                isValid(respPktGenInfo.atomicAckOrig),
                "atomicAckOrig assertion @ mkReqHandleRQ",
                $format(
                    "respPktGenInfo.atomicAckOrig=", fshow(respPktGenInfo.atomicAckOrig),
                    " should be valid"
                )
            );
            let atomicCacheItem = AtomicCacheItem {
                atomicPSN   : bth.psn,
                atomicOpCode: bth.opcode,
                atomicEth   : atomicEth,
                atomicAckEth: AtomicAckEth {
                    orig    : unwrapMaybe(respPktGenInfo.atomicAckOrig)
                }
            };
            dupReadAtomicCache.insertAtomic(atomicCacheItem);
        end

        // dupAtomicReqPermQueryQ.enq(tuple6(
        respCheckQ.enq(tuple7(
            pktMetaData, reqStatus, permCheckInfo, reqPktInfo,
            respPktGenInfo, respPktHeaderInfo, atomicEth
        ));
        // $display(
        //     "time=%0t: 25th stage, bth.opcode=", $time, fshow(bth.opcode),
        //     ", bth.psn=%h", bth.psn, ", reqStatus=", fshow(reqStatus)
        // );
    endrule

    // This rule still runs at retry or error state
    rule checkPendingResp if (cntrl.isNonErr || cntrl.isERR);
        let {
            pktMetaData, reqStatus, permCheckInfo, reqPktInfo,
            respPktGenInfo, respPktHeaderInfo, atomicEth
        } = respCheckQ.first;
        respCheckQ.deq;

        let bth                      = reqPktInfo.bth;
        let isReadReq                = reqPktInfo.isReadReq;
        let hasDmaReadRespErr        = hasDmaReadRespErrReg;
        let hasErrIncurred           = respPktGenInfo.hasErrIncurred;
        let expectReadRespPayload    = respPktGenInfo.expectReadRespPayload;
        let expectAtomicRespOrig     = respPktGenInfo.expectAtomicRespOrig;
        let expectDupAtomicCheckResp = respPktGenInfo.expectDupAtomicCheckResp;

        if (!hasErrRespGenReg) begin
            if (hasDmaReadRespErr) begin
                // This case means previous duplicate operation had DMA read response error,
                // But no error responses for duplicate requests.
                // So it needs to generate an error response here.
                if (isNormalOrErrorReqStatus(reqStatus)) begin
                    reqStatus = RDMA_REQ_ST_RMT_OP;
                    respPktGenInfo.shouldGenResp = True;
                end
                else if (reqStatus == RDMA_REQ_ST_DUP) begin
                    reqStatus = RDMA_REQ_ST_DISCARD;
                    respPktGenInfo.shouldGenResp = False;
                end
            end
            else if (expectReadRespPayload) begin
                immAssert(
                    reqStatus == RDMA_REQ_ST_NORMAL || reqStatus == RDMA_REQ_ST_DUP,
                    "reqStatus normal dup assertion @ ReqHandleRQ",
                    $format(
                        "reqStatus=", fshow(RDMA_REQ_ST_NORMAL),
                        " should be RDMA_REQ_ST_NORMAL or RDMA_REQ_ST_DUP when expectReadRespPayload=",
                        fshow(expectReadRespPayload)
                    )
                );
                immAssert(
                    isReadReq,
                    "isReadReq assertion @ ReqHandleRQ",
                    $format(
                        "isReadReq=", fshow(isReadReq),
                        " should be true when expectReadRespPayload=",
                        fshow(expectReadRespPayload),
                        " but bth.opcode=", fshow(bth.opcode)
                    )
                );

                let payloadGenResp = payloadGenerator.respPipeOut.first;
                payloadGenerator.respPipeOut.deq;

                if (payloadGenResp.isRespErr) begin
                    hasDmaReadRespErr = True;

                    // Only change to error state when normal read requests have response error,
                    // but if duplicate read requests have response error, it will postpone
                    // the error response generation to next normal or error request.
                    if (reqStatus == RDMA_REQ_ST_NORMAL) begin
                        reqStatus = RDMA_REQ_ST_RMT_OP;
                        readRespErrNotifyReg <= True;
                        $display(
                            "time=%0t:", $time,
                            " set readRespErrNotifyReg",
                            ", hasDmaReadRespErr=", fshow(hasDmaReadRespErr),
                            ", reqStatus=", fshow(reqStatus)
                        );
                    end
                    else begin
                        // Can not change to error state if duplicate read request have
                        // error read response
                        reqStatus = RDMA_REQ_ST_DISCARD;
                        respPktGenInfo.shouldGenResp = False;
                    end
                end
            end
        end

        let errReqStatus = isErrReqStatus(reqStatus);
        if (hasErrRespGenReg || errReqStatus) begin
            immAssert(
                hasDmaReadRespErr || (
                    !expectReadRespPayload &&
                    !expectAtomicRespOrig  &&
                    !expectDupAtomicCheckResp
                ),
                "respPktGenInfo assertion @ mkReqHandleRQ",
                $format(
                    "bth.psn=%h", bth.psn, ", bth.opcode=", fshow(bth.opcode),
                    ", expectReadRespPayload=", fshow(expectReadRespPayload),
                    ", expectAtomicRespOrig=", fshow(expectAtomicRespOrig),
                    ", expectDupAtomicCheckResp=", fshow(expectDupAtomicCheckResp),
                    ", all should be false when errReqStatus=", fshow(errReqStatus),
                    ", hasDmaReadRespErr=", fshow(hasDmaReadRespErr),
                    ", hasErrRespGenReg=", fshow(hasErrRespGenReg),
                    ", hasErrIncurred=", fshow(hasErrIncurred),
                    ", reqStatus=", fshow(reqStatus)
                )
            );
        end

        hasDmaReadRespErrReg <= hasDmaReadRespErr;
        dupAtomicReqPermQueryQ.enq(tuple7(
            pktMetaData, reqStatus, permCheckInfo, reqPktInfo, respPktGenInfo, respPktHeaderInfo, atomicEth
        ));
        // $display(
        //     "time=%0t: 26th stage, bth.opcode=", $time, fshow(bth.opcode),
        //     ", bth.psn=%h", bth.psn, ", bth.ackReq=", fshow(bth.ackReq),
        //     ", respPSN=%h", respPktHeaderInfo.psn,
        //     ", shouldGenResp=", fshow(respPktGenInfo.shouldGenResp),
        //     ", hasErrRespGenReg=", fshow(hasErrRespGenReg),
        //     ", hasDmaReadRespErr=", fshow(hasDmaReadRespErr),
        //     ", reqStatus=", fshow(reqStatus)
        // );
    endrule

    // This rule still runs at retry or error state
    rule queryPerm4DupAtomicReq if (cntrl.isNonErr || cntrl.isERR);
        let {
            pktMetaData, reqStatus, permCheckInfo, reqPktInfo, respPktGenInfo, respPktHeaderInfo, atomicEth
        } = dupAtomicReqPermQueryQ.first;
        dupAtomicReqPermQueryQ.deq;

        let bth         = reqPktInfo.bth;
        let isAtomicReq = reqPktInfo.isAtomicReq;

        let expectDupAtomicCheckResp = False;
        let hasErrIncurred = respPktGenInfo.hasErrIncurred;
        if (reqStatus == RDMA_REQ_ST_DUP && isAtomicReq && !hasErrIncurred) begin
            let atomicCacheItem = AtomicCacheItem {
                atomicPSN   : bth.psn,
                atomicOpCode: bth.opcode,
                atomicEth   : atomicEth,
                atomicAckEth: dontCareValue
            };
            dupReadAtomicCache.searchAtomicReq(atomicCacheItem);
            expectDupAtomicCheckResp = True;
        end

        respPktGenInfo.expectDupAtomicCheckResp = expectDupAtomicCheckResp;
        dupAtomicReqPermCheckQ.enq(tuple6(
            pktMetaData, reqStatus, permCheckInfo, reqPktInfo, respPktGenInfo, respPktHeaderInfo
        ));
        // $display(
        //     "time=%0t: 27th stage, bth.opcode=", $time, fshow(bth.opcode),
        //     ", bth.psn=%h", bth.psn, ", reqStatus=", fshow(reqStatus),
        //     ", respPSN=%h", respPktHeaderInfo.psn,
        //     ", expectDupAtomicCheckResp=", fshow(expectDupAtomicCheckResp),
        //     ", hasErrIncurred=", fshow(hasErrIncurred)
        // );
    endrule

    // This rule still runs at retry or error state
    rule checkPerm4DupAtomicReq if (cntrl.isNonErr || cntrl.isERR);
        let {
            pktMetaData, reqStatus, permCheckInfo, reqPktInfo, respPktGenInfo, respPktHeaderInfo
        } = dupAtomicReqPermCheckQ.first;
        dupAtomicReqPermCheckQ.deq;

        let bth         = reqPktInfo.bth;
        let isAtomicReq = reqPktInfo.isAtomicReq;

        // let hasErrIncurred = respPktGenInfo.hasErrIncurred;
        let expectDupAtomicCheckResp = respPktGenInfo.expectDupAtomicCheckResp;
        if (expectDupAtomicCheckResp) begin
            immAssert(
                reqStatus == RDMA_REQ_ST_DUP,
                "reqStatus dup assertion @ mkReqHandleRQ",
                $format(
                    "reqStatus=", fshow(reqStatus),
                    " should be RDMA_REQ_ST_DUP"
                )
            );
            immAssert(
                isAtomicReq,
                "isAtomicReq dup assertion @ mkReqHandleRQ",
                $format(
                    "isAtomicReq=", fshow(isAtomicReq),
                    " should be true but bth.opcode",
                    fshow(bth.opcode)
                )
            );

            let searchResult <- dupReadAtomicCache.searchAtomicResp;
            if (searchResult matches tagged Valid .atomicCache) begin
                respPktGenInfo.atomicAckOrig = tagged Valid atomicCache.atomicAckEth.orig;
                respPktGenInfo.shouldGenResp = qpNeedGenResp(bth.trans);
            end
            else begin
                // Discard duplicate requests with error
                reqStatus = RDMA_REQ_ST_DISCARD;
            end
        end

        respHeaderGenQ.enq(tuple6(
            pktMetaData, reqStatus, permCheckInfo, reqPktInfo, respPktGenInfo, respPktHeaderInfo
        ));
        // $display(
        //     "time=%0t: 28th stage, bth.opcode=", $time, fshow(bth.opcode),
        //     ", bth.psn=%h", bth.psn, ", reqStatus=", fshow(reqStatus),
        //     ", respPSN=%h", respPktHeaderInfo.psn,
        //     ", expectDupAtomicCheckResp=", fshow(expectDupAtomicCheckResp),
        //     ", hasErrIncurred=", fshow(respPktGenInfo.hasErrIncurred)
        // );
    endrule

    // This rule still runs at retry or error state
    rule genRespHeader if (cntrl.isNonErr || cntrl.isERR);
        let {
            pktMetaData, reqStatus, permCheckInfo, reqPktInfo, respPktGenInfo, respPktHeaderInfo
        } = respHeaderGenQ.first;
        respHeaderGenQ.deq;

        let bth = reqPktInfo.bth;
        let psn = respPktHeaderInfo.psn;
        let msn = respPktHeaderInfo.msn;

        let maybeHeader = dontCareValue;
        if (respPktHeaderInfo.isFirstOrOnlyRespPkt) begin
            let maybeFirstOrOnlyHeader = genFirstOrOnlyRespHeader(
                bth.opcode, reqStatus, permCheckInfo.totalLen, respPktGenInfo.atomicAckOrig,
                cntrl, psn, msn, reqPktInfo.isOnlyRespPkt
            );
            maybeHeader = maybeFirstOrOnlyHeader;
        end
        else begin
            let maybeMiddleOrLastHeader = genMiddleOrLastRespHeader(
                bth.opcode, reqStatus, permCheckInfo.totalLen,
                cntrl, psn, msn, respPktHeaderInfo.isLastOrOnlyRespPkt
            );
            maybeHeader = maybeMiddleOrLastHeader;
        end

        pendingRespQ.enq(tuple7(
            pktMetaData, reqStatus, permCheckInfo, reqPktInfo,
            respPktGenInfo, respPktHeaderInfo, maybeHeader
        ));
        // $display(
        //     "time=%0t: 29th stage, bth.opcode=", $time, fshow(bth.opcode),
        //     ", bth.psn=%h", bth.psn, ", bth.ackReq=", fshow(bth.ackReq),
        //     ", respPSN=%h", respPktHeaderInfo.psn,
        //     ", isOnlyRespPkt=", fshow(reqPktInfo.isOnlyRespPkt),
        //     ", shouldGenResp=", fshow(respPktGenInfo.shouldGenResp),
        //     // ", hasErrRespGenReg=", fshow(hasErrRespGenReg),
        //     // ", hasDmaReadRespErr=", fshow(hasDmaReadRespErr),
        //     ", reqStatus=", fshow(reqStatus)
        // );
    endrule

    // This rule still runs at retry or error state
    rule genRespPkt if (cntrl.isNonErr || cntrl.isERR);
        let {
            pktMetaData, reqStatus, permCheckInfo, reqPktInfo,
            respPktGenInfo, respPktHeaderInfo, maybeHeader
        } = pendingRespQ.first;
        pendingRespQ.deq;

        let bth = reqPktInfo.bth;
        let psn = respPktHeaderInfo.psn;
        let msn = respPktHeaderInfo.msn;

        if (!hasErrRespGenReg) begin
            // It is possible that maybeFirstOrOnlyHeader is valid
            // but no need to generate responses
            if (respPktHeaderInfo.isFirstOrOnlyRespPkt) begin
                let maybeFirstOrOnlyHeader = maybeHeader;
                // let maybeFirstOrOnlyHeader = genFirstOrOnlyRespHeader(
                //     bth.opcode, reqStatus, permCheckInfo.totalLen, respPktGenInfo.atomicAckOrig,
                //     cntrl, psn, msn, reqPktInfo.isOnlyRespPkt
                // );
                if (respPktGenInfo.shouldGenResp) begin
                    immAssert(
                        isValid(maybeFirstOrOnlyHeader),
                        "maybeFirstOrOnlyHeader assertion @ mkReqHandleRQ",
                        $format(
                            "maybeFirstOrOnlyHeader=", fshow(maybeFirstOrOnlyHeader),
                            " must be valid when shouldGenResp=",
                            fshow(respPktGenInfo.shouldGenResp),
                            ", bth.opcode=", fshow(bth.opcode),
                            ", bth.psn=%h, msn=%h", bth.psn, msn,
                            ", reqStatus=", fshow(reqStatus)
                        )
                    );

                    if (maybeFirstOrOnlyHeader matches tagged Valid .firstOrOnlyHeader) begin
                        headerQ.enq(firstOrOnlyHeader);
                        // $display("time=%0t: generate first or only response header", $time);
                    end
                end

                if (
                    reqPktInfo.isAtomicReq           &&
                    (reqStatus == RDMA_REQ_ST_NORMAL || reqStatus == RDMA_REQ_ST_DUP)
                ) begin
                    immAssert(
                        isValid(respPktGenInfo.atomicAckOrig),
                        "atomicAckOrig assertion @ mkReqHandleRQ",
                        $format(
                            "atomicAckOrig=", fshow(respPktGenInfo.atomicAckOrig),
                            " should be valid when isAtomicReq=", fshow(reqPktInfo.isAtomicReq),
                            ", reqStatus=", fshow(reqStatus),
                            " and shouldGenResp=", fshow(respPktGenInfo.shouldGenResp)
                        )
                    );
                end
            end
            else begin
                immAssert(
                    reqStatus == RDMA_REQ_ST_NORMAL ||
                    reqStatus == RDMA_REQ_ST_DUP    ||
                    reqStatus == RDMA_REQ_ST_RMT_OP,
                    "reqStatus assertion @ mkReqHandleRQ",
                    $format(
                        "reqStatus=", fshow(reqStatus),
                        " must be normal or duplicate when isFirstOrOnlyRespPkt=",
                        fshow(respPktHeaderInfo.isFirstOrOnlyRespPkt)
                    )
                );
                immAssert(
                    respPktGenInfo.shouldGenResp,
                    "shouldGenResp assertion @ mkReqHandleRQ",
                    $format(
                        "shouldGenResp=", fshow(respPktGenInfo.shouldGenResp),
                        " must be true when isFirstOrOnlyRespPkt=",
                        fshow(respPktHeaderInfo.isFirstOrOnlyRespPkt)
                    )
                );
                immAssert(
                    respPktGenInfo.expectReadRespPayload,
                    "expectReadRespPayload assertion @ mkReqHandleRQ",
                    $format(
                        "expectReadRespPayload=", fshow(respPktGenInfo.expectReadRespPayload),
                        " must be true when isFirstOrOnlyRespPkt=",
                        fshow(respPktHeaderInfo.isFirstOrOnlyRespPkt),
                        ", bth.psn=%h", bth.psn
                    )
                );
                immAssert(
                    bth.opcode == RDMA_READ_REQUEST,
                    "bth.opcode assertion @ mkReqHandleRQ",
                    $format(
                        "bth.opcode=", fshow(bth.opcode),
                        " must be read request when isFirstOrOnlyRespPkt=",
                        fshow(respPktHeaderInfo.isFirstOrOnlyRespPkt)
                    )
                );

                let maybeMiddleOrLastHeader = maybeHeader;
                // let maybeMiddleOrLastHeader = genMiddleOrLastRespHeader(
                //     bth.opcode, reqStatus, permCheckInfo.totalLen,
                //     cntrl, psn, msn, respPktHeaderInfo.isLastOrOnlyRespPkt
                // );
                if (
                    reqStatus == RDMA_REQ_ST_NORMAL ||
                    reqStatus == RDMA_REQ_ST_DUP    ||
                    reqStatus == RDMA_REQ_ST_RMT_OP // For read response error
                ) begin
                    immAssert(
                        isValid(maybeMiddleOrLastHeader),
                        "maybeMiddleOrLastHeader assertion @ mkReqHandleRQ",
                        $format(
                            "maybeMiddleOrLastHeader=", fshow(maybeMiddleOrLastHeader),
                            " must be valid when reqStatus=", fshow(reqStatus)
                        )
                    );
                end
                if (respPktGenInfo.shouldGenResp) begin
                    if (maybeMiddleOrLastHeader matches tagged Valid .middleOrLastHeader) begin
                        headerQ.enq(middleOrLastHeader);
                        // $display("time=%0t: generate middle or last response header", $time);
                    end
                end
            end
        end

        let errReqStatus = isErrReqStatus(reqStatus);
        if (errReqStatus) begin
            hasErrRespGenReg <= True;
            // if (!hasErrRespGenReg) begin
            //     $display("time=%0t: first fatal error response, reqStatus=", $time, fshow(reqStatus));
            // end
        end
        workCompReqQ.enq(tuple6(
            pktMetaData, reqStatus, permCheckInfo, reqPktInfo, respPktGenInfo, respPktHeaderInfo
        ));
        // $display(
        //     "time=%0t: 30th stage, bth.opcode=", $time, fshow(bth.opcode),
        //     ", bth.psn=%h", bth.psn, ", bth.ackReq=", fshow(bth.ackReq),
        //     ", respPSN=%h", respPktHeaderInfo.psn,
        //     ", isOnlyRespPkt=", fshow(reqPktInfo.isOnlyRespPkt),
        //     ", shouldGenResp=", fshow(respPktGenInfo.shouldGenResp),
        //     ", hasErrRespGenReg=", fshow(hasErrRespGenReg),
        //     // ", hasDmaReadRespErr=", fshow(hasDmaReadRespErr),
        //     ", reqStatus=", fshow(reqStatus)
        // );
    endrule

    // This rule still runs at retry or error state
    rule genWorkCompReq if (cntrl.isNonErr || cntrl.isERR);
        let {
            pktMetaData, reqStatus, permCheckInfo, reqPktInfo, respPktGenInfo, respPktHeaderInfo
        } = workCompReqQ.first;
        workCompReqQ.deq;

        let rdmaHeader   = pktMetaData.pktHeader;
        let bth          = reqPktInfo.bth;
        let isReadReq    = reqPktInfo.isReadReq;
        let isAtomicReq  = reqPktInfo.isAtomicReq ;
        let immDt        = extractImmDt(rdmaHeader.headerData, bth.opcode, bth.trans);
        let ieth         = extractIETH(rdmaHeader.headerData, bth.trans);
        let hasImmDt     = rdmaReqHasImmDt(bth.opcode);
        let hasIETH      = rdmaReqHasIETH(bth.opcode);
        let isZeroDmaLen = permCheckInfo.isZeroDmaLen;

        let hasErrIncurred = respPktGenInfo.hasErrIncurred;
        let isFirstOrOnlyRespPkt = respPktHeaderInfo.isFirstOrOnlyRespPkt;

        if (reqStatus == RDMA_REQ_ST_NORMAL && !hasErrIncurred) begin
            if ((isReadReq && isFirstOrOnlyRespPkt) || isAtomicReq) begin
                immAssert(
                    respPktHeaderInfo.psn == bth.psn,
                    "respPktHeaderInfo.psn assertion @ mkReqHandleRQ",
                    $format(
                        "respPktHeaderInfo.psn=%h should == bth.psn=%h",
                        respPktHeaderInfo.psn, bth.psn,
                        " when request bth.opcode=", fshow(bth.opcode),
                        " isFirstOrOnlyRespPkt=", fshow(isFirstOrOnlyRespPkt)
                    )
                );

                if (pendingDestReadAtomicReqCnt > 0) begin
                    pendingDestReadAtomicReqCnt.decrOne;
                    // $display(
                    //     "time=%0t:", $time,
                    //     " decrease pendingDestReadAtomicReqCnt=%0d", pendingDestReadAtomicReqCnt,
                    //     ", bth.opcode=", fshow(bth.opcode),
                    //     ", bth.psn=%h", bth.psn
                    // );
                end
                else begin
                    immFail(
                        "pendingDestReadAtomicReqCnt assertion @ mkReqHandleRQ",
                        $format(
                            "pendingDestReadAtomicReqCnt=%0d", pendingDestReadAtomicReqCnt,
                            " must > 0 when bth.psn=%h", bth.psn,
                            ", bth.opcode=", fshow(bth.opcode),
                            ", reqStatus=", fshow(reqStatus)
                        )
                    );
                end
            end
        end

        let maybeWorkCompStatus = genWorkCompStatusFromReqStatusRQ(reqStatus);
        if (maybeWorkCompStatus matches tagged Valid .workCompStatus) begin
            let workCompReq = WorkCompGenReqRQ {
                rrID        : permCheckInfo.wrID,
                len         : permCheckInfo.totalLen,
                sqpn        : cntrl.getSQPN,
                reqPSN      : bth.psn,
                isZeroDmaLen: isZeroDmaLen,
                wcStatus    : workCompStatus,
                reqOpCode   : bth.opcode,
                immDt       : hasImmDt ? (tagged Valid immDt.data) : (tagged Invalid),
                rkey2Inv    : hasIETH  ? (tagged Valid ieth.rkey)  : (tagged Invalid)
            };

            // Wait for send/write request DMA write responses and generate WC if needed
            workCompGenReqOutQ.enq(workCompReq);
        end
        // $display(
        //     "time=%0t: 31st stage, bth.opcode=", $time, fshow(bth.opcode),
        //     ", bth.psn=%h", bth.psn, ", bth.ackReq=", fshow(bth.ackReq),
        //     ", immDt=%h, ieth=%h", immDt, ieth,
        //     ", hasImmDt=", fshow(hasImmDt),
        //     ", hasIETH=", fshow(hasIETH),
        //     ", reqStatus=", fshow(reqStatus)
        // );
    endrule
/*
    (* no_implicit_conditions, fire_when_enabled *)
    rule canonicalize if (
        cntrl.isNonErr && (reqStatusErrNotifyReg[1] || readRespErrNotifyReg[1])
    );
        hasErrOccurredReg        <= True;
        reqStatusErrNotifyReg[1] <= False;
        readRespErrNotifyReg[1]  <= False;
        $display(
            "time=%0t:", $time,
            " set hasErrOccurredReg to True when reqStatusErrNotifyReg[1]=",
            fshow(reqStatusErrNotifyReg[1]),
            " and readRespErrNotifyReg[1]=",
            fshow(readRespErrNotifyReg[1])
        );
    endrule

    (* no_implicit_conditions, fire_when_enabled *)
    rule errFlushPipelineQ if (inErrorState);
        clearRetryRelatedPipelineQ;
    endrule
*/
    (* fire_when_enabled *)
    rule errFlushRecvReq if (inErrorState && recvReqBuf.notEmpty);
        let recvReq = recvReqBuf.first;
        recvReqBuf.deq;
        let maybeRecvReq = tagged Valid recvReq;

        let pktMetaData = RdmaPktMetaData {
            pktPayloadLen   : 0,
            pktFragNum      : 0,
            isZeroPayloadLen: True,
            pktHeader       : dontCareValue,
            pdHandler       : dontCareValue,
            pktValid        : False,
            pktStatus       : dontCareValue
            // pktStatus    : PKT_ST_DISCARD
        };
        let reqStatus   = RDMA_REQ_ST_ERR_FLUSH_RR;
        let maybeTrans  = qpType2TransType(cntrl.getQpType);

        let bth = BTH {
            trans    : unwrapMaybe(maybeTrans),
            opcode   : SEND_ONLY,
            solicited: False,
            migReq   : unpack(0),
            padCnt   : 0,
            tver     : unpack(0),
            pkey     : cntrl.getPKEY,
            fecn     : unpack(0),
            becn     : unpack(0),
            resv6    : unpack(0),
            dqpn     : dontCareValue,
            ackReq   : False,
            resv7    : unpack(0),
            psn      : dontCareValue
        };
        let reqPktInfo = RdmaReqPktInfo {
            bth             : dontCareValue,
            epoch           : epochReg,
            respPktNum      : 0,
            endPSN          : dontCareValue,
            isSendReq       : True,
            isWriteReq      : False,
            isWriteImmReq   : False,
            isReadReq       : False,
            isAtomicReq     : False,
            // isZeroPayloadLen: True,
            isOnlyPkt       : True,
            isFirstPkt      : False,
            isMidPkt        : False,
            isLastPkt       : False,
            isFirstOrOnlyPkt: True,
            isLastOrOnlyPkt : True,
            isOnlyRespPkt   : True,
            isDuplicated    : False,
            isExpected      : False,
            isAccCheckPass  : False
        };

        let curEPSN = cntrl.contextRQ.getEPSN;
        supportedReqOpCodeCheckQ.enq(tuple4(
            pktMetaData, reqStatus, reqPktInfo, curEPSN
        ));
        // let preOpCode = SEND_ONLY;
        // rnrTriggerQ.enq(tuple5(
        //     pktMetaData, reqStatus, reqPktInfo, preOpCode, maybeRecvReq
        // ));
        $display(
            "time=%0t:", $time,
            " 1st error flush RR stage, bth.opcode=", fshow(bth.opcode),
            ", bth.psn=%h", bth.psn, ", bth.ackReq=", fshow(bth.ackReq),
            ", reqStatus=", fshow(reqStatus)
        );
    endrule

    (* fire_when_enabled *)
    rule errFlushIncomingReq if (
        inErrorState && !recvReqBuf.notEmpty && pktMetaDataPipeIn.notEmpty
    );
        let curPktMetaData = pktMetaDataPipeIn.first;
        pktMetaDataPipeIn.deq;

        let maybeRecvReq  = tagged Invalid;
        let curRdmaHeader = curPktMetaData.pktHeader;
        let bth           = extractBTH(curRdmaHeader.headerData);
        let reqStatus     = RDMA_REQ_ST_DISCARD;
/*
        let isSendReq        = isSendReqRdmaOpCode(bth.opcode);
        let isWriteReq       = isWriteReqRdmaOpCode(bth.opcode);
        let isWriteImmReq    = isWriteImmReqRdmaOpCode(bth.opcode);
        let isReadReq        = isReadReqRdmaOpCode(bth.opcode);
        let isAtomicReq      = isAtomicReqRdmaOpCode(bth.opcode);
        let isFirstOrOnlyPkt = isFirstOrOnlyRdmaOpCode(bth.opcode);
        let isLastOrOnlyPkt  = isLastOrOnlyRdmaOpCode(bth.opcode);
        // let isZeroPayloadLen = isZero(curPktMetaData.pktPayloadLen);

        let isOnlyPkt  = isOnlyRdmaOpCode(bth.opcode);
        let isFirstPkt = isFirstRdmaOpCode(bth.opcode);
        let isMidPkt   = isMiddleRdmaOpCode(bth.opcode);
        let isLastPkt  = isLastRdmaOpCode(bth.opcode);

        let reqPktInfo = RdmaReqPktInfo {
            bth             : bth,
            epoch           : epochReg,
            respPktNum      : 0,
            endPSN          : dontCareValue,
            isSendReq       : isSendReq,
            isWriteReq      : isWriteReq,
            isWriteImmReq   : isWriteImmReq,
            isReadReq       : isReadReq,
            isAtomicReq     : isAtomicReq,
            // isZeroPayloadLen: isZeroPayloadLen,
            isOnlyPkt       : isOnlyPkt,
            isFirstPkt      : isFirstPkt,
            isMidPkt        : isMidPkt,
            isLastPkt       : isLastPkt,
            isFirstOrOnlyPkt: isFirstOrOnlyPkt,
            isLastOrOnlyPkt : isLastOrOnlyPkt,
            isOnlyRespPkt   : True,
            isDuplicated    : False,
            isExpected      : False,
            isAccCheckPass  : False
        };
*/
        let reqPktInfo = RdmaReqPktInfo {
            bth             : bth,
            epoch           : epochReg,
            respPktNum      : 0,
            endPSN          : dontCareValue,
            isSendReq       : True,
            isWriteReq      : False,
            isWriteImmReq   : False,
            isReadReq       : False,
            isAtomicReq     : False,
            // isZeroPayloadLen: isZeroPayloadLen,
            isOnlyPkt       : True,
            isFirstPkt      : False,
            isMidPkt        : False,
            isLastPkt       : False,
            isFirstOrOnlyPkt: True,
            isLastOrOnlyPkt : True,
            isOnlyRespPkt   : True,
            isDuplicated    : False,
            isExpected      : False,
            isAccCheckPass  : False
        };

        let curEPSN = bth.psn;
        supportedReqOpCodeCheckQ.enq(tuple4(
            curPktMetaData, reqStatus, reqPktInfo, curEPSN
        ));
        // let preOpCode = SEND_ONLY;
        // rnrTriggerQ.enq(tuple5(
        //     curPktMetaData, reqStatus, reqPktInfo, preOpCode, maybeRecvReq
        // ));
        $display(
            "time=%0t:", $time,
            " 1st error flush incoming request stage, bth.opcode=", fshow(bth.opcode),
            ", bth.psn=%h", bth.psn, ", bth.ackReq=", fshow(bth.ackReq),
            ", reqStatus=", fshow(reqStatus)
        );
    endrule

    (* no_implicit_conditions, fire_when_enabled *)
    rule retryStageRnrRetryFlush if (
        cntrl.isNonErr && !hasErrHappened && retryStateReg == RQ_RNR_RETRY_FLUSH
    );
        retryStateReg <= RQ_RNR_WAIT;
        rnrWaitCntReg <= fromInteger(getRnrTimeOutValue(minRnrTimerReg));
        isRnrWaitCntZeroReg <= False;
    endrule

    (* no_implicit_conditions, fire_when_enabled *)
    rule retryStageRnrWait if (
        cntrl.isNonErr && !hasErrHappened && retryStateReg == RQ_RNR_WAIT
    );
        if (isRnrWaitCntZeroReg) begin
            retryStateReg <= RQ_RNR_WAIT_DONE;
        end
        else begin
            rnrWaitCntReg <= rnrWaitCntReg - 1;
            isRnrWaitCntZeroReg <= isOne(rnrWaitCntReg);
        end
    endrule
/*
    (* no_implicit_conditions, fire_when_enabled *)
    rule retryStart if (
        cntrl.isNonErr && retryStateReg == RQ_NOT_RETRY && !hasErrHappened
    );
        if (retryStartStateReg[1] matches tagged Valid .retryStartState) begin
            retryStateReg <= retryStartState;
        end
    endrule
*/
    (* no_implicit_conditions, fire_when_enabled *)
    rule retryDone if (
        cntrl.isNonErr && !hasErrHappened && preStageStateReg == RQ_PRE_CALC_STAGE &&
        (retryStateReg == RQ_RNR_WAIT_DONE || retryStateReg == RQ_SEQ_RETRY_FLUSH)
    );
        let reqPktInfo = preStageReqPktInfoReg;
        let epoch      = reqPktInfo.epoch;
        let isExpected = reqPktInfo.isExpected;

        let retryFlushDone =
            isExpected && epoch == epochReg && (
            retryStateReg == RQ_RNR_WAIT_DONE ||
            retryStateReg == RQ_SEQ_RETRY_FLUSH
        );
        // If retry done, then next stage is RQ_PRE_STAGE_DONE aka RQ pipeline 1st stage
        if (retryFlushDone) begin
            retryStateReg <= RQ_NOT_RETRY;
            // retryStartStateReg[1] <= tagged Invalid;
        end
        // $display(
        //     "time=%0t:", $time,
        //     ", retryFlushDone=", fshow(retryFlushDone),
        //     ", retryStateReg=", fshow(retryStateReg)
        // );
    endrule

    (* fire_when_enabled *)
    rule retryFlush if (
        cntrl.isNonErr && preStageStateReg == RQ_PRE_STAGE_DONE &&
        retryStateReg != RQ_NOT_RETRY && !hasErrHappened
    );
        let reqStatus  = preStageReqStatusReg;
        let reqPktInfo = preStageReqPktInfoReg;

        let bth            = reqPktInfo.bth;
        let curPktMetaData = preStagePktMetaDataReg;

        // $display(
        //     "time=%0t:", $time,
        //     // " isRetryFlushDoneReg=", fshow(isRetryFlushDoneReg),
        //     ", isRetryFlushDone=", fshow(isRetryFlushDone),
        //     ", bth.psn=%h", bth.psn,
        //     ", ePSN=%h", cntrl.contextRQ.getEPSN
        // );

        // if (!isRetryFlushDone) begin
        preStageStateReg <= RQ_PRE_BUILD_STAGE;
        reqStatus = RDMA_REQ_ST_DISCARD;
        pktMetaDataPipeIn.deq;

        // let maybeRecvReq = tagged Invalid;
        // reqPermInfoBuildQ.enq(tuple4(
        let curEPSN = cntrl.contextRQ.getEPSN;
        supportedReqOpCodeCheckQ.enq(tuple4(
            curPktMetaData, reqStatus, reqPktInfo, curEPSN
        ));
        // end
        // $display(
        //     "time=%0t: 1st retry flush stage, bth.opcode=", $time, fshow(bth.opcode),
        //     ", bth.psn=%h", bth.psn, ", bth.ackReq=", fshow(bth.ackReq),
        //     ", reqStatus=", fshow(reqStatus)
        // );
    endrule

    interface payloadConReqPipeOut      = convertFifo2PipeOut(payloadConReqOutQ);
    // interface payloadGenReqPipeOut      = convertFifo2PipeOut(payloadGenReqOutQ);
    interface rdmaRespDataStreamPipeOut = rdmaRespPipeOut;
    interface workCompGenReqPipeOut     = convertFifo2PipeOut(workCompGenReqOutQ);
endmodule
