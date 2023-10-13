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

function Maybe#(QPN) getMaybeDestQpnRQ(CntrlStatus cntrlStatus);
    return case (cntrlStatus.getTypeQP)
        IBV_QPT_RC      ,
        IBV_QPT_UC      ,
        IBV_QPT_XRC_RECV: tagged Valid cntrlStatus.comm.getDQPN;
        // IBV_QPT_XRC_SEND
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
    RdmaOpCode reqOpCode, RdmaReqStatus reqStatus, Bool isOnlyReadRespPkt
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
                RDMA_READ_REQUEST             : tagged Valid (isOnlyReadRespPkt ? RDMA_READ_RESPONSE_ONLY : RDMA_READ_RESPONSE_FIRST);
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

function Maybe#(AETH) genAethByReqStatus(RdmaReqStatus reqStatus, CntrlStatus cntrlStatus, MSN msn);
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
                value: cntrlStatus.comm.getMinRnrTimer,
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
    CntrlStatus cntrlStatus, PSN psn, MSN msn, Bool isOnlyReadRespPkt
);
    let maybeTrans  = qpType2TransType(cntrlStatus.getTypeQP);
    let maybeOpCode = genFirstOrOnlyRespRdmaOpCode(reqOpCode, reqStatus, isOnlyReadRespPkt);
    let maybeDQPN   = getMaybeDestQpnRQ(cntrlStatus);
    let maybeAETH   = genAethByReqStatus(reqStatus, cntrlStatus, msn);

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
            padCnt   : isOnlyReadRespPkt ? calcPadCnt(payloadLen) : 0,
            tver     : unpack(0),
            pkey     : cntrlStatus.comm.getPKEY,
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
    CntrlStatus cntrlStatus, PSN psn, MSN msn, Bool isLastRespPkt
);
    let maybeTrans  = qpType2TransType(cntrlStatus.getTypeQP);
    let maybeOpCode = genMiddleOrLastRespRdmaOpCode(reqStatus, isLastRespPkt);
    let maybeDQPN   = getMaybeDestQpnRQ(cntrlStatus);
    let maybeAETH   = genAethByReqStatus(reqStatus, cntrlStatus, msn);

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
            pkey     : cntrlStatus.comm.getPKEY,
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
    Bool hasReqStatusErr;
    Bool hasDmaReadRespErr;
    Bool hasErrRespGen;
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

typedef struct {
    Bool onlyPktCase;
    Bool firstPktCase;
    Bool midPktCase;
    Bool lastPktCase;
} EnoughDmaSpaceCheck deriving(Bits);

interface ReqHandleRQ;
    // interface PipeOut#(PayloadConReq) payloadConReqPipeOut;
    interface DataStreamPipeOut rdmaRespDataStreamPipeOut;
    interface PipeOut#(WorkCompGenReqRQ) workCompGenReqPipeOut;
    method Bool respHeaderOutNotEmpty();
endinterface

module mkReqHandleRQ#(
    ContextRQ contextRQ,
    // DmaReadSrv dmaReadSrv,
    PayloadGenerator payloadGenerator,
    PermCheckSrv permCheckSrv,
    DupReadAtomicCache dupReadAtomicCache,
    RecvReqBuf recvReqBuf,
    PipeOut#(RdmaPktMetaData) pktMetaDataPipeIn,
    Put#(PayloadConReq) payloadConReqPort
)(ReqHandleRQ);
    // Output FIFO for PipeOut
    // FIFOF#(PayloadConReq)     payloadConReqOutQ <- mkFIFOF;
    // FIFOF#(PayloadGenReq)     payloadGenReqOutQ <- mkFIFOF;
    FIFOF#(WorkCompGenReqRQ) workCompGenReqOutQ <- mkFIFOF;
    FIFOF#(RdmaHeader)           respHeaderOutQ <- mkFIFOF;
    FIFOF#(PSN)                     psnRespOutQ <- mkFIFOF;

    // Pipeline FIFO
    // TODO: add more buffer after 0th stage
    FIFOF#(Tuple4#(RdmaPktMetaData, RdmaReqStatus, RdmaReqPktInfo, PSN)) supportedReqOpCodeCheckQ <- mkFIFOF;
    FIFOF#(Tuple3#(RdmaPktMetaData, RdmaReqStatus, RdmaReqPktInfo)) reqOpCodeSeqCheckQ <- mkFIFOF;
    FIFOF#(Tuple4#(RdmaPktMetaData, RdmaReqStatus, RdmaReqPktInfo, RdmaOpCode)) rnrCheckQ <- mkFIFOF;
    FIFOF#(Tuple5#(RdmaPktMetaData, RdmaReqStatus, RdmaReqPktInfo, RdmaOpCode, Maybe#(RecvReq))) rnrTriggerQ <- mkFIFOF;
    FIFOF#(Tuple4#(RdmaPktMetaData, RdmaReqStatus, RdmaReqPktInfo, Maybe#(RecvReq))) qpAccPermCheckQ <- mkFIFOF;
    FIFOF#(Tuple4#(RdmaPktMetaData, RdmaReqStatus, RdmaReqPktInfo, Maybe#(RecvReq))) reqPermInfoBuildQ <- mkFIFOF;
    FIFOF#(Tuple6#(RdmaPktMetaData, RdmaReqStatus, PermCheckReq, RdmaReqPktInfo, RETH, Maybe#(RecvReq))) reqPermQueryTmpQ <- mkFIFOF;
    FIFOF#(Tuple5#(RdmaPktMetaData, RdmaReqStatus, PermCheckReq, RdmaReqPktInfo, RETH)) reqPermQueryQ <- mkFIFOF;
    FIFOF#(Tuple6#(RdmaPktMetaData, RdmaReqStatus, PermCheckReq, RdmaReqPktInfo, RETH, Bool)) reqPermCheckQ <- mkFIFOF;
    FIFOF#(Tuple5#(RdmaPktMetaData, RdmaReqStatus, PermCheckReq, RdmaReqPktInfo, RETH)) readCacheInsertQ <- mkFIFOF;
    FIFOF#(Tuple5#(RdmaPktMetaData, RdmaReqStatus, PermCheckReq, RdmaReqPktInfo, RETH)) dupReadReqPermQueryQ <- mkFIFOF;
    FIFOF#(Tuple6#(RdmaPktMetaData, RdmaReqStatus, PermCheckReq, RdmaReqPktInfo, RETH, Bool)) dupReadReqPermCheckQ <- mkFIFOF;
    FIFOF#(Tuple5#(RdmaPktMetaData, RdmaReqStatus, PermCheckReq, RdmaReqPktInfo, DupReadReqStartState)) reqAddrCalcQ <- mkFIFOF;
    FIFOF#(Tuple6#(RdmaPktMetaData, RdmaReqStatus, PermCheckReq, RdmaReqPktInfo, DupReadReqStartState, ADDR)) reqRemainingLenCalcQ <- mkFIFOF;
    FIFOF#(Tuple8#(RdmaPktMetaData, RdmaReqStatus, PermCheckReq, RdmaReqPktInfo, DupReadReqStartState, ADDR, Length, Length)) reqEnoughDmaSpaceQ <- mkFIFOF;
    FIFOF#(Tuple8#(RdmaPktMetaData, RdmaReqStatus, PermCheckReq, RdmaReqPktInfo, DupReadReqStartState, ADDR, Length, EnoughDmaSpaceCheck)) reqTotalLenCalcQ <- mkFIFOF;
    // FIFOF#(Tuple6#(RdmaPktMetaData, RdmaReqStatus, PermCheckReq, RdmaReqPktInfo, DupReadReqStartState, ADDR)) reqLenCalcQ <- mkFIFOF;
    FIFOF#(Tuple6#(RdmaPktMetaData, RdmaReqStatus, PermCheckReq, RdmaReqPktInfo, ReqLenCheckResult, DupReadReqStartState)) reqLenCheckQ <- mkFIFOF;
    // FIFOF#(Tuple6#(RdmaPktMetaData, RdmaReqStatus, PermCheckReq, RdmaReqPktInfo, ADDR, DupReadReqStartState)) issueDmaReqQ <- mkFIFOF;
    FIFOF#(Tuple6#(RdmaPktMetaData, RdmaReqStatus, PermCheckReq, RdmaReqPktInfo, ADDR, DupReadReqStartState)) issuePayloadConReqQ <- mkFIFOF;
    FIFOF#(Tuple6#(RdmaPktMetaData, RdmaReqStatus, PermCheckReq, RdmaReqPktInfo, Bool, DupReadReqStartState)) issuePayloadGenReqQ <- mkFIFOF;
    FIFOF#(Tuple5#(RdmaPktMetaData, RdmaReqStatus, PermCheckReq, RdmaReqPktInfo, RespPktGenInfo)) issueAtomicReqQ <- mkFIFOF;
    FIFOF#(Tuple5#(RdmaPktMetaData, RdmaReqStatus, PermCheckReq, RdmaReqPktInfo, RespPktGenInfo)) respGenCheck4NormalCaseQ <- mkFIFOF;
    FIFOF#(Tuple5#(RdmaPktMetaData, RdmaReqStatus, PermCheckReq, RdmaReqPktInfo, RespPktGenInfo)) respGenCheck4OtherCasesQ <- mkFIFOF;
    FIFOF#(Tuple5#(RdmaPktMetaData, RdmaReqStatus, PermCheckReq, RdmaReqPktInfo, RespPktGenInfo)) respCountQ <- mkFIFOF;
    FIFOF#(Tuple6#(RdmaPktMetaData, RdmaReqStatus, PermCheckReq, RdmaReqPktInfo, RespPktGenInfo, RespPktSeqInfo)) respPsnAndMsnQ <- mkFIFOF;
    FIFOF#(Tuple6#(RdmaPktMetaData, RdmaReqStatus, PermCheckReq, RdmaReqPktInfo, RespPktGenInfo, RespPktHeaderInfo)) waitAtomicRespQ <- mkFIFOF;
    FIFOF#(Tuple6#(RdmaPktMetaData, RdmaReqStatus, PermCheckReq, RdmaReqPktInfo, RespPktGenInfo, RespPktHeaderInfo)) atomicCacheInsertQ <- mkFIFOF;
    FIFOF#(Tuple7#(RdmaPktMetaData, RdmaReqStatus, PermCheckReq, RdmaReqPktInfo, RespPktGenInfo, RespPktHeaderInfo, AtomicEth)) respCheckQ <- mkFIFOF;
    FIFOF#(Tuple7#(RdmaPktMetaData, RdmaReqStatus, PermCheckReq, RdmaReqPktInfo, RespPktGenInfo, RespPktHeaderInfo, AtomicEth)) dupAtomicReqPermQueryQ <- mkFIFOF;
    FIFOF#(Tuple6#(RdmaPktMetaData, RdmaReqStatus, PermCheckReq, RdmaReqPktInfo, RespPktGenInfo, RespPktHeaderInfo)) dupAtomicReqPermCheckQ <- mkFIFOF;
    FIFOF#(Tuple6#(RdmaPktMetaData, RdmaReqStatus, PermCheckReq, RdmaReqPktInfo, RespPktGenInfo, RespPktHeaderInfo)) respHeaderGenQ <- mkFIFOF;
    FIFOF#(Tuple7#(RdmaPktMetaData, RdmaReqStatus, PermCheckReq, RdmaReqPktInfo, RespPktGenInfo, RespPktHeaderInfo, Maybe#(RdmaHeader))) pendingRespQ <- mkFIFOF;
    FIFOF#(Tuple6#(RdmaPktMetaData, RdmaReqStatus, PermCheckReq, RdmaReqPktInfo, RespPktGenInfo, RespPktHeaderInfo)) workCompReqQ <- mkFIFOF;

    Reg#(Bool)      preStageIsZeroPmtuResidueReg <- mkRegU;
    Reg#(RdmaPktMetaData) preStagePktMetaDataReg <- mkRegU;
    Reg#(RdmaReqStatus)     preStageReqStatusReg <- mkRegU;
    Reg#(RdmaReqPktInfo)   preStageReqPktInfoReg <- mkRegU;
    Reg#(PreStageStateRQ)       preStageStateReg <- mkReg(RQ_PRE_BUILD_STAGE);

    // Reg#(Epoch) epochReg <- mkRegU;

    Reg#(RnrWaitCycleCnt)        rnrWaitCntReg <- mkRegU;
    Reg#(RnrTimer)              minRnrTimerReg <- mkRegU;
    Reg#(Bool)             isRnrWaitCntZeroReg <- mkRegU;
    // Reg#(Bool)             isRetryFlushDoneReg <- mkRegU;
    Reg#(RetryStateRQ) retryStateReg <- mkReg(RQ_NOT_RETRY);
    Reg#(Maybe#(RetryStateRQ)) retryStartReg[2] <- mkCReg(2, tagged Invalid);

    Reg#(Bool)      hasReqStatusErrReg <- mkReg(False);
    Reg#(Bool)    hasDmaReadRespErrReg <- mkReg(False);
    Reg#(Bool)        hasErrRespGenReg <- mkReg(False);
    Reg#(Bool) isFirstOrOnlyRespPktReg <- mkReg(True);

    // Reg#(Bool)  readRespErrNotifyReg <- mkReg(False);
    // Reg#(Bool)     hasErrOccurredReg <- mkReg(False);
    // Reg#(Bool) hasReqStatusErrReg[2] <- mkCReg(2, False);
    // Reg#(Bool)  readRespErrNotifyReg[2] <- mkCReg(2, False);

    // TODO: move the two counters into CntrlQP
    Count#(PendingReqCnt) coalesceWorkReqCnt <- mkCount(fromInteger(valueOf(TSub#(MAX_QP_WR, 1))));
    CountCF#(PendingReqCnt) pendingDestReadAtomicReqCnt <- mkCountCF(0);
    Reg#(Bool) isCoalesceWorkReqCntZeroReg <- mkReg(False);

    let cntrlStatus = contextRQ.statusRQ;

    let atomicSrv <- mkAtomicSrv(cntrlStatus);
    let rdmaRespPipeOut <- mkCombineHeaderAndPayload(
        cntrlStatus,
        toPipeOut(respHeaderOutQ),
        toPipeOut(psnRespOutQ),
        payloadGenerator.payloadDataStreamPipeOut
    );

    let hasErrHappened = hasReqStatusErrReg || hasDmaReadRespErrReg; // readRespErrNotifyReg;
    let inErrorState = (cntrlStatus.comm.isNonErr && hasErrHappened) || cntrlStatus.comm.isERR;

    function Epoch  getEpoch() = contextRQ.getEpoch;
    function Action incEpoch() = contextRQ.incEpoch;

    (* no_implicit_conditions, fire_when_enabled *)
    rule resetAndClear if (cntrlStatus.comm.isReset);
        // payloadConReqOutQ.clear;
        // payloadGenReqOutQ.clear;
        workCompGenReqOutQ.clear;
        respHeaderOutQ.clear;
        psnRespOutQ.clear;

        // clearRetryRelatedPipelineQ;
        supportedReqOpCodeCheckQ.clear;
        reqOpCodeSeqCheckQ.clear;
        rnrCheckQ.clear;
        rnrTriggerQ.clear;
        qpAccPermCheckQ.clear;
        reqPermInfoBuildQ.clear;
        reqPermQueryTmpQ.clear;
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
        issueAtomicReqQ.clear;
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
        retryStartReg[0]         <= tagged Invalid;
        preStageStateReg         <= RQ_PRE_BUILD_STAGE;
        hasReqStatusErrReg       <= False;
        hasDmaReadRespErrReg     <= False;
        hasErrRespGenReg         <= False;
        // hasErrOccurredReg        <= False;
        // readRespErrNotifyReg     <= False;
        isFirstOrOnlyRespPktReg  <= True;
        // hasReqStatusErrReg[0] <= False;
        // readRespErrNotifyReg[0]  <= False;

        coalesceWorkReqCnt          <= fromInteger(valueOf(TSub#(MAX_QP_WR, 1)));
        pendingDestReadAtomicReqCnt <= 0;
        isCoalesceWorkReqCntZeroReg <= False;

        // $display("time=%0t: reset and clear mkReqHandleRQ", $time);
    endrule

    // TODO: check preBuildReqInfo and preCalcReqInfo having negative impact on throughput,
    // since preBuildReqInfo and preCalcReqInfo is not pipelined.
    rule preBuildReqInfo if (
        cntrlStatus.comm.isNonErr              &&
        preStageStateReg == RQ_PRE_BUILD_STAGE &&
        !hasErrHappened
    );
        let curPktMetaData = pktMetaDataPipeIn.first;
        let curRdmaHeader  = curPktMetaData.pktHeader;

        let bth   = extractBTH(curRdmaHeader.headerData);
        let reth  = extractRETH(curRdmaHeader.headerData, bth.trans);
        let epoch = getEpoch;

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

        let expectedPSN  = contextRQ.getEPSN;
        let oldestPSN    = calcOldestValidPsn4RQ(expectedPSN);
        let isIllegalReq = !curPktMetaData.pktValid;
        let isExpected   = bth.psn == expectedPSN;
        let isDuplicated = psnInRangeExclusive(bth.psn, oldestPSN, expectedPSN);

        let { tmpRespPktNum, pmtuResidue } = truncateLenByPMTU(reth.dlen, cntrlStatus.comm.getPMTU);
        // let tmpRespPktNum = calcPktNumByLenOnly(reth.dlen, cntrlStatus.comm.getPMTU);
        // let { isOnlyRespPkt, tmpRespPktNum } = calcPktNumByLength(reth.dlen, cntrlStatus.comm.getPMTU);
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
            respPktNum      : isReadReq ? tmpRespPktNum : 1,
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
        //     "time=%0t: 0.1st pre-stage preBuildReqInfo", $time,
        //     ", bth.opcode=", fshow(bth.opcode),
        //     ", bth.trans=", fshow(bth.trans),
        //     ", bth.psn=%h, bth.dqpn=%h, reth.dlen=%0d", bth.psn, bth.dqpn, reth.dlen,
        //     ", ePSN=%h, epoch=%h", expectedPSN, epoch,
        //     ", curPktMetaData.pktStatus=", fshow(curPktMetaData.pktStatus),
        //     ", preStageStateReg=", fshow(preStageStateReg)
        // );
    endrule

    rule preCalcReqInfo if (
        cntrlStatus.comm.isNonErr             &&
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

        // let { isOnlyRespPkt, totalRespPktNum } = calcPktNumByLength(reth.dlen, cntrlStatus.comm.getPMTU);
        let totalRespPktNum = preStageIsZeroPmtuResidueReg ? reqPktInfo.respPktNum : reqPktInfo.respPktNum + 1;
        let isOnlyRespPkt = isLessOrEqOneR(totalRespPktNum);
        reqPktInfo.isOnlyRespPkt = reqPktInfo.isReadReq ? isOnlyRespPkt : True;
        reqPktInfo.respPktNum = reqPktInfo.isReadReq ? totalRespPktNum : 1;

        let isAccCheckPass = False;
        case ({ pack(isSendReq || isWriteReq), pack(isReadReq), pack(isAtomicReq) })
            3'b100: begin
                isAccCheckPass = containAccessTypeFlag(cntrlStatus.comm.getAccessFlags, IBV_ACCESS_REMOTE_WRITE);
            end
            3'b010: begin
                isAccCheckPass = containAccessTypeFlag(cntrlStatus.comm.getAccessFlags, IBV_ACCESS_REMOTE_READ);
            end
            3'b001: begin
                isAccCheckPass = containAccessTypeFlag(cntrlStatus.comm.getAccessFlags, IBV_ACCESS_REMOTE_ATOMIC);
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

            // $display(
            //     "time=%0t: found invalid request in 0.2nd pre-stage", $time,
            //     ", bth.opcode=", fshow(bth.opcode),
            //     ", bth.psn=%h", bth.psn,
            //     ", isAccCheckPass=", fshow(isAccCheckPass),
            //     ", reqStatus=", fshow(reqStatus)
            // );
        end
        reqPktInfo.isAccCheckPass = isAccCheckPass;

        preStageReqStatusReg  <= reqStatus;
        preStageReqPktInfoReg <= reqPktInfo;
        preStageStateReg      <= RQ_PRE_STAGE_DONE;
        // $display(
        //     "time=%0t: 0.2nd pre-stage preCalcReqInfo", $time,
        //     ", bth.opcode=", fshow(bth.opcode),
        //     ", bth.psn=%h, bth.dqpn=%h", bth.psn, bth.dqpn,
        //     ", totalRespPktNum=%0d", totalRespPktNum,
        //     ", isOnlyRespPkt=", fshow(isOnlyRespPkt),
        //     ", reqStatus=", fshow(reqStatus),
        //     ", preStageStateReg=", fshow(preStageStateReg)
        // );
    endrule

                        // buildPermCheckReq, \
    // TODO: add conflict_free attribute to preBuildReqInfo, preCalcReqInfo
    (* conflict_free = "checkEPSN, \
                        checkSupportedReqOpCode, \
                        checkNormalReqOpCodeSeq, \
                        checkRNR, \
                        triggerRNR, \
                        checkQpAccPermAndReadAtomicReqNum, \
                        buildPermCheckReq4SendWrite, \
                        buildPermCheckReq4ReadAtomic, \
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
                        issueAtomicReq, \
                        shouldGenResp4NormalCase, \
                        shouldGenResp4OtherCases, \
                        waitAtomicResp, \
                        insertIntoAtomicCache, \
                        queryPerm4DupAtomicReq, \
                        checkPerm4DupAtomicReq, \
                        countPendingResp, \
                        updateRespPsnAndMsn, \
                        checkReadResp, \
                        genRespHeader, \
                        genRespPkt, \
                        genWorkCompRQ, \
                        errFlushRecvReq, \
                        errFlushIncomingReq" *)
                        // retryStageRnrRetryFlush, \
                        // retryStageRnrWait, \
                        // retryStart, \
                        // retryDone, \
                        // retryFlush" *)
    rule checkEPSN if (
        cntrlStatus.comm.isNonErr && !hasErrHappened &&
        preStageStateReg == RQ_PRE_STAGE_DONE        &&
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
            bth.psn, reqPktInfo.respPktNum, reqPktInfo.isOnlyRespPkt, cntrlStatus.comm.getPMTU
        );

        let curEPSN = contextRQ.getEPSN;
        let nextEPSN = curEPSN;
        if (epoch == getEpoch) begin
            if (reqStatus == RDMA_REQ_ST_NORMAL) begin
                if (bth.trans != TRANS_TYPE_UD) begin
                    // ePSN check, no PSN check for UD
                    case ({ pack(isExpected), pack(isDuplicated) })
                        2'b10: begin
                            if (isReadReq) begin
                                nextEPSN = nextPktSeqNum;
                                // contextRQ.setEPSN(nextPktSeqNum);
                            end
                            else begin
                                nextEPSN = bth.psn + 1;
                                // contextRQ.setEPSN(bth.psn + 1);
                            end
                            reqStatus = RDMA_REQ_ST_NORMAL;
                        end
                        2'b01: begin
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
                ", getEpoch=", fshow(getEpoch)
            );
        end

        reqPktInfo.endPSN = endPktSeqNum;
        preStageStateReg <= RQ_PRE_BUILD_STAGE;
        contextRQ.setEPSN(nextEPSN);

        supportedReqOpCodeCheckQ.enq(tuple4(curPktMetaData, reqStatus, reqPktInfo, curEPSN));
        // $display(
        //     "time=%0t: 1st stage checkEPSN", $time,
        //     ", bth.opcode=", fshow(bth.opcode),
        //     ", bth.psn=%h, bth.dqpn=%h", bth.psn, bth.dqpn,
        //     ", epoch=%h, nextEPSN=%h", epoch, nextEPSN,
        //     ", reqPktInfo.respPktNum=%0d", reqPktInfo.respPktNum,
        //     ", isReadReq=", fshow(isReadReq),
        //     ", reqStatus=", fshow(reqStatus)
        // );
    endrule

    // This rule still runs at retry state
    rule checkSupportedReqOpCode if (cntrlStatus.comm.isNonErr || cntrlStatus.comm.isERR);
        let { pktMetaData, reqStatus, reqPktInfo, curEPSN } = supportedReqOpCodeCheckQ.first;
        supportedReqOpCodeCheckQ.deq;

        let bth   = reqPktInfo.bth;
        let epoch = reqPktInfo.epoch;

        let isSupportedReqOpCode = isSupportedReqOpCodeRQ(cntrlStatus.getTypeQP, bth.opcode);

        if (epoch == getEpoch) begin
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
                "time=%0t: epoch mismatch in 2nd stage", $time,
                ", epoch=", fshow(epoch),
                ", getEpoch=", fshow(getEpoch)
            );
        end

        reqOpCodeSeqCheckQ.enq(tuple3(pktMetaData, reqStatus, reqPktInfo));
        // $display(
        //     "time=%0t: 2nd stage checkSupportedReqOpCode", $time,
        //     ", bth.opcode=", fshow(bth.opcode),
        //     ", bth.psn=%h, bth.dqpn=%h, epoch=%h", bth.psn, bth.dqpn, epoch,
        //     ", isSupportedReqOpCode=", fshow(isSupportedReqOpCode),
        //     ", reqStatus=", fshow(reqStatus)
        // );
    endrule

    // This rule still runs at retry state
    rule checkNormalReqOpCodeSeq if (cntrlStatus.comm.isNonErr || cntrlStatus.comm.isERR);
        let { pktMetaData, reqStatus, reqPktInfo } = reqOpCodeSeqCheckQ.first;
        reqOpCodeSeqCheckQ.deq;

        let bth       = reqPktInfo.bth;
        let epoch     = reqPktInfo.epoch;
        let preOpCode = contextRQ.getPreReqOpCode;

        if (epoch == getEpoch) begin
            if (reqStatus == RDMA_REQ_ST_NORMAL && !hasErrHappened) begin
                let seqCheckResult = checkNormalReqOpCodeSeqRQ(preOpCode, bth.opcode);
                if (seqCheckResult) begin
                    contextRQ.setPreReqOpCode(bth.opcode);
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
                "time=%0t: epoch mismatch in 3rd stage", $time,
                ", epoch=", fshow(epoch),
                ", getEpoch=", fshow(getEpoch)
            );
        end

        rnrCheckQ.enq(tuple4(pktMetaData, reqStatus, reqPktInfo, preOpCode));
        // $display(
        //     "time=%0t: 3rd stage checkNormalReqOpCodeSeq", $time,
        //     ", bth.opcode=", fshow(bth.opcode),
        //     ", bth.psn=%h, bth.dqpn=%h, epoch=%h", bth.psn, bth.dqpn, epoch,
        //     ", preOpCode=", fshow(preOpCode),
        //     ", reqStatus=", fshow(reqStatus)
        // );
    endrule

    // This rule still runs at retry state
    rule checkRNR if (cntrlStatus.comm.isNonErr || cntrlStatus.comm.isERR);
        let { pktMetaData, reqStatus, reqPktInfo, preOpCode } = rnrCheckQ.first;
        rnrCheckQ.deq;

        let bth   = reqPktInfo.bth;
        let epoch = reqPktInfo.epoch;

        let isZeroPayloadLen = pktMetaData.isZeroPayloadLen;
        let isFirstOrOnlyPkt = reqPktInfo.isFirstOrOnlyPkt;
        let isSendReq        = reqPktInfo.isSendReq;
        let isWriteImmReq    = reqPktInfo.isWriteImmReq;
        let maybeRecvReq     = tagged Invalid;

        if (epoch == getEpoch) begin
            // Duplicate requests do not use PermCheckReq
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
                    contextRQ.restorePreReqOpCodeAndEPSN(preOpCode, bth.psn);
                end
            end
            else if (reqStatus == RDMA_REQ_ST_ERR_FLUSH_RR) begin
                if (recvReqBuf.notEmpty) begin
                    let recvReq = recvReqBuf.first;
                    recvReqBuf.deq;

                    maybeRecvReq = tagged Valid recvReq;
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
                "time=%0t: epoch mismatch in 4th stage", $time,
                ", epoch=", fshow(epoch),
                ", getEpoch=", fshow(getEpoch)
            );
        end

        if (reqStatus == RDMA_REQ_ST_RNR || reqStatus == RDMA_REQ_ST_SEQ_ERR) begin
            immAssert(
                retryStateReg == RQ_NOT_RETRY,
                "retryStateReg assertion @ mkReqHandleRQ",
                $format(
                    "retryStateReg=", fshow(retryStateReg),
                    " should be RQ_NOT_RETRY, when reqStatus=",
                    fshow(reqStatus)
                )
            );
        end

        rnrTriggerQ.enq(tuple5(
            pktMetaData, reqStatus, reqPktInfo, preOpCode, maybeRecvReq
        ));
        // $display(
        //     "time=%0t: 4th stage checkRNR", $time,
        //     ", maybeRecvReq=", fshow(maybeRecvReq),
        //     ", bth.opcode=", fshow(bth.opcode),
        //     ", bth.psn=%h, bth.dqpn=%h, epoch=%h", bth.psn, bth.dqpn, epoch,
        //     ", reqStatus=", fshow(reqStatus)
        // );
    endrule

    // This rule still runs at retry or error state
    rule triggerRNR if (cntrlStatus.comm.isNonErr || cntrlStatus.comm.isERR);
        let {
            pktMetaData, reqStatus, reqPktInfo, preOpCode, maybeRecvReq
        } = rnrTriggerQ.first;
        rnrTriggerQ.deq;

        let bth   = reqPktInfo.bth;
        let epoch = reqPktInfo.epoch;

        let retryStartState = tagged Invalid;
        if (epoch == getEpoch) begin
            // Trigger retry flush
            if (!hasErrHappened) begin
            // if (retryStateReg == RQ_NOT_RETRY && !hasErrHappened) begin
                if (reqStatus == RDMA_REQ_ST_RNR) begin
                    incEpoch;
                    // contextRQ.restorePreReqOpCode(preOpCode);
                    // contextRQ.restoreEPSN(bth.psn);
                    retryStartState = tagged Valid RQ_RNR_RETRY_FLUSH;
                    // retryStateReg <= RQ_RNR_RETRY_FLUSH;
                end
                else if (reqStatus == RDMA_REQ_ST_SEQ_ERR) begin
                    incEpoch;
                    retryStartState = tagged Valid RQ_SEQ_RETRY_FLUSH;
                    // retryStateReg <= RQ_SEQ_RETRY_FLUSH;
                end
            end
        end
        else begin
            reqStatus = RDMA_REQ_ST_DISCARD;

            $display(
                "time=%0t: epoch mismatch in 5th stage", $time,
                ", epoch=", fshow(epoch),
                ", getEpoch=", fshow(getEpoch)
            );
        end

        retryStartReg[0] <= retryStartState;
        minRnrTimerReg   <= cntrlStatus.comm.getMinRnrTimer;
        qpAccPermCheckQ.enq(tuple4(pktMetaData, reqStatus, reqPktInfo, maybeRecvReq));
        // $display(
        //     "time=%0t: 5th stage triggerRNR", $time,
        //     ", bth.opcode=", fshow(bth.opcode),
        //     ", bth.psn=%h, bth.dqpn=%h, epoch=%h", bth.psn, bth.dqpn, epoch,
        //     ", reqStatus=", fshow(reqStatus)
        // );
    endrule

    // This rule still runs at retry or error state
    rule checkQpAccPermAndReadAtomicReqNum if (cntrlStatus.comm.isNonErr || cntrlStatus.comm.isERR);
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
                    pendingDestReadAtomicReqCnt >= cntrlStatus.comm.getPendingDestReadAtomicReqNum
                ) begin
                    hasTooManyReadAtomicReqs = True;
                    reqStatus = getInvReqStatusByTransType(bth.trans);
                    immAssert(
                        reqStatus != RDMA_REQ_ST_UNKNOWN,
                        "reqStatus assertion @ mkReqHandleRQ",
                        $format(
                            "reqStatus=", fshow(reqStatus), " should not be unknown"
                        )
                    );

                    // $display(
                    //     "time=%0t: checkQpAccPermAndReadAtomicReqNum", $time,
                    //     ", pendingDestReadAtomicReqCnt=%0d", pendingDestReadAtomicReqCnt,
                    //     " must < cntrlStatus.comm.getPendingDestReadAtomicReqNum=%0d",
                    //     cntrlStatus.comm.getPendingDestReadAtomicReqNum,
                    //     ", when bth.psn=%h", bth.psn,
                    //     ", bth.opcode=", fshow(bth.opcode),
                    //     ", reqStatus=", fshow(reqStatus)
                    // );
                end
            end
        end

        reqPermInfoBuildQ.enq(tuple4(pktMetaData, reqStatus, reqPktInfo, maybeRecvReq));
        // $display(
        //     "time=%0t: 6th stage checkQpAccPermAndReadAtomicReqNum", $time,
        //     ", bth.opcode=", fshow(bth.opcode),
        //     ", bth.psn=%h", bth.psn,
        //     // ", isAccCheckPass=", fshow(isAccCheckPass),
        //     ", hasTooManyReadAtomicReqs=", fshow(hasTooManyReadAtomicReqs),
        //     ", reqStatus=", fshow(reqStatus)
        // );
    endrule

    // This rule still runs at retry or error state
    rule buildPermCheckReq4SendWrite if (cntrlStatus.comm.isNonErr || cntrlStatus.comm.isERR);
        let { pktMetaData, reqStatus, reqPktInfo, maybeRecvReq } = reqPermInfoBuildQ.first;
        reqPermInfoBuildQ.deq;

        let bth        = reqPktInfo.bth;
        let hasReth    = rdmaReqHasRETH(bth.opcode);
        let rdmaHeader = pktMetaData.pktHeader;
        let reth       = extractRETH(rdmaHeader.headerData, bth.trans);
        // let atomicEth  = extractAtomicEth(rdmaHeader.headerData, bth.trans);

        let isZeroPayloadLen = pktMetaData.isZeroPayloadLen;
        let isFirstOrOnlyPkt = reqPktInfo.isFirstOrOnlyPkt;
        let isSendReq        = reqPktInfo.isSendReq;
        let isWriteReq       = reqPktInfo.isWriteReq;
        // let isReadReq        = reqPktInfo.isReadReq;
        let isWriteImmReq    = reqPktInfo.isWriteImmReq;
        // let isAtomicReq      = reqPktInfo.isAtomicReq;

        let isZeroRethLen   = isZeroR(reth.dlen);
        let curPermCheckReq = PermCheckReq {
            wrID         : tagged Invalid,
            lkey         : dontCareValue,
            rkey         : dontCareValue,
            reqAddr      : dontCareValue,
            totalLen     : 0,
            pdHandler    : pktMetaData.pdHandler,
            isZeroDmaLen : True,
            accFlags     : enum2Flag(IBV_ACCESS_LOCAL_WRITE),
            localOrRmtKey: True
        };

        // Duplicate requests no use PermCheckReq except read
        let isNormalReq = reqStatus == RDMA_REQ_ST_NORMAL;
        let isDupReq    = reqStatus == RDMA_REQ_ST_DUP;
        if (!hasErrHappened) begin
            case ({
                pack(isSendReq   && isNormalReq),
                pack(isWriteReq  && isNormalReq)
                // pack(isReadReq   && (isNormalReq || isDupReq)),
                // pack(isAtomicReq && isNormalReq)
            })
                2'b10: begin // send
                    if (isFirstOrOnlyPkt) begin
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

                        curPermCheckReq.wrID          = tagged Valid recvReq.id;
                        curPermCheckReq.lkey          = recvReq.lkey;
                        curPermCheckReq.rkey          = dontCareValue;
                        curPermCheckReq.reqAddr       = recvReq.laddr;
                        curPermCheckReq.totalLen      = isZeroPayloadLen ? 0 : recvReq.len;
                        curPermCheckReq.pdHandler     = pktMetaData.pdHandler;
                        curPermCheckReq.isZeroDmaLen  = isZeroPayloadLen;
                        curPermCheckReq.accFlags      = enum2Flag(IBV_ACCESS_LOCAL_WRITE);
                        curPermCheckReq.localOrRmtKey = True;

                        contextRQ.setPermCheckReq(curPermCheckReq);
                    end
                    else begin
                        curPermCheckReq = contextRQ.getPermCheckReq;
                    end
                end
                2'b01: begin // write
                    if (isFirstOrOnlyPkt) begin
                        curPermCheckReq.wrID          = tagged Invalid;
                        curPermCheckReq.rkey          = reth.rkey;
                        curPermCheckReq.lkey          = dontCareValue;
                        curPermCheckReq.reqAddr       = reth.va;
                        curPermCheckReq.totalLen      = reth.dlen;
                        curPermCheckReq.pdHandler     = pktMetaData.pdHandler;
                        curPermCheckReq.isZeroDmaLen  = isZeroRethLen;
                        curPermCheckReq.accFlags      = enum2Flag(IBV_ACCESS_REMOTE_WRITE);
                        curPermCheckReq.localOrRmtKey = False;

                        contextRQ.setPermCheckReq(curPermCheckReq);
                    end
                    else begin
                        curPermCheckReq = contextRQ.getPermCheckReq;
                    end

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

                        curPermCheckReq.wrID = tagged Valid recvReq.id;
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
                default: begin end
            endcase
        end

        reqPermQueryTmpQ.enq(tuple6(
            pktMetaData, reqStatus, curPermCheckReq, reqPktInfo, reth, maybeRecvReq
        ));
        // $display(
        //     "time=%0t: 7th stage buildPermCheckReq4SendWrite", $time,
        //     ", bth.opcode=", fshow(bth.opcode),
        //     ", bth.psn=%h", bth.psn,
        //     ", reqStatus=", fshow(reqStatus),
        //     ", curPermCheckReq=", fshow(curPermCheckReq)
        // );
    endrule

    // This rule still runs at retry or error state
    rule buildPermCheckReq4ReadAtomic if (cntrlStatus.comm.isNonErr || cntrlStatus.comm.isERR);
        let {
            pktMetaData, reqStatus, curPermCheckReq, reqPktInfo, reth, maybeRecvReq
        } = reqPermQueryTmpQ.first;
        reqPermQueryTmpQ.deq;

        let bth        = reqPktInfo.bth;
        let hasReth    = rdmaReqHasRETH(bth.opcode);
        let rdmaHeader = pktMetaData.pktHeader;
        // let reth       = extractRETH(rdmaHeader.headerData, bth.trans);
        let atomicEth  = extractAtomicEth(rdmaHeader.headerData, bth.trans);

        let isZeroPayloadLen = pktMetaData.isZeroPayloadLen;
        let isFirstOrOnlyPkt = reqPktInfo.isFirstOrOnlyPkt;
        // let isSendReq        = reqPktInfo.isSendReq;
        // let isWriteReq       = reqPktInfo.isWriteReq;
        let isReadReq        = reqPktInfo.isReadReq;
        // let isWriteImmReq    = reqPktInfo.isWriteImmReq;
        let isAtomicReq      = reqPktInfo.isAtomicReq;
        let isZeroRethLen    = isZeroR(reth.dlen);

        // Duplicate requests no use PermCheckReq except read
        let isNormalReq = reqStatus == RDMA_REQ_ST_NORMAL;
        let isDupReq    = reqStatus == RDMA_REQ_ST_DUP;
        if (!hasErrHappened) begin
            case ({
                pack(isReadReq   && (isNormalReq || isDupReq)),
                pack(isAtomicReq && isNormalReq)
            })
                2'b10: begin // read
                    curPermCheckReq.wrID          = tagged Invalid;
                    curPermCheckReq.rkey          = reth.rkey;
                    curPermCheckReq.lkey          = dontCareValue;
                    curPermCheckReq.reqAddr       = reth.va;
                    curPermCheckReq.totalLen      = reth.dlen;
                    curPermCheckReq.pdHandler     = pktMetaData.pdHandler;
                    curPermCheckReq.isZeroDmaLen  = isZeroRethLen;
                    curPermCheckReq.accFlags      = enum2Flag(IBV_ACCESS_REMOTE_READ);
                    curPermCheckReq.localOrRmtKey = False;
                end
                2'b01: begin // atomic
                    curPermCheckReq.wrID          = tagged Invalid;
                    curPermCheckReq.rkey          = atomicEth.rkey;
                    curPermCheckReq.lkey          = dontCareValue;
                    curPermCheckReq.reqAddr       = atomicEth.va;
                    curPermCheckReq.totalLen      = fromInteger(valueOf(ATOMIC_WORK_REQ_LEN));
                    curPermCheckReq.pdHandler     = pktMetaData.pdHandler;
                    curPermCheckReq.isZeroDmaLen  = False;
                    curPermCheckReq.accFlags      = enum2Flag(IBV_ACCESS_REMOTE_ATOMIC);
                    curPermCheckReq.localOrRmtKey = False;
                end
                default: begin end
            endcase
        end

        // It is possible that !hasErrHappened && reqStatus == RDMA_REQ_ST_ERR_FLUSH_RR
        if (reqStatus == RDMA_REQ_ST_ERR_FLUSH_RR) begin
            if (maybeRecvReq matches tagged Valid .recvReq) begin
                curPermCheckReq.wrID     = tagged Valid recvReq.id;
                curPermCheckReq.lkey     = recvReq.lkey;
                curPermCheckReq.reqAddr  = recvReq.laddr;
                curPermCheckReq.totalLen = recvReq.len;
            end
        end

        reqPermQueryQ.enq(tuple5(
            pktMetaData, reqStatus, curPermCheckReq, reqPktInfo, reth
        ));
        // $display(
        //     "time=%0t: 8th stage buildPermCheckReq4ReadAtomic", $time,
        //     ", bth.opcode=", fshow(bth.opcode),
        //     ", bth.psn=%h", bth.psn,
        //     ", reqStatus=", fshow(reqStatus),
        //     ", curPermCheckReq=", fshow(curPermCheckReq)
        // );
    endrule
/*
    // This rule still runs at retry or error state
    rule buildPermCheckReq if (cntrlStatus.comm.isNonErr || cntrlStatus.comm.isERR);
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

        let isZeroRethLen   = isZeroR(reth.dlen);
        let curPermCheckReq = PermCheckReq {
            wrID         : tagged Invalid,
            lkey         : dontCareValue,
            rkey         : dontCareValue,
            reqAddr      : dontCareValue,
            totalLen     : 0,
            pdHandler    : pktMetaData.pdHandler,
            isZeroDmaLen : True,
            accFlags     : enum2Flag(IBV_ACCESS_LOCAL_WRITE),
            localOrRmtKey: True
        };

        // Duplicate requests no use PermCheckReq except read
        let isNormalReq = reqStatus == RDMA_REQ_ST_NORMAL;
        let isDupReq    = reqStatus == RDMA_REQ_ST_DUP;
        if (!hasErrHappened) begin
            case ({
                pack(isSendReq   && isNormalReq),
                pack(isWriteReq  && isNormalReq),
                pack(isReadReq   && (isNormalReq || isDupReq)),
                pack(isAtomicReq && isNormalReq)
            })
                4'b1000: begin // send
                    if (isFirstOrOnlyPkt) begin
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

                        curPermCheckReq.wrID          = tagged Valid recvReq.id;
                        curPermCheckReq.lkey          = recvReq.lkey;
                        curPermCheckReq.rkey          = dontCareValue;
                        curPermCheckReq.reqAddr       = recvReq.laddr;
                        curPermCheckReq.totalLen      = isZeroPayloadLen ? 0 : recvReq.len;
                        curPermCheckReq.pdHandler     = pktMetaData.pdHandler;
                        curPermCheckReq.isZeroDmaLen  = isZeroPayloadLen;
                        curPermCheckReq.accFlags      = enum2Flag(IBV_ACCESS_LOCAL_WRITE);
                        curPermCheckReq.localOrRmtKey = True;

                        contextRQ.setPermCheckReq(curPermCheckReq);
                    end
                    else begin
                        curPermCheckReq = contextRQ.getPermCheckReq;
                    end
                end
                4'b0100: begin // write
                    if (isFirstOrOnlyPkt) begin
                        curPermCheckReq.wrID          = tagged Invalid;
                        curPermCheckReq.rkey          = reth.rkey;
                        curPermCheckReq.lkey          = dontCareValue;
                        curPermCheckReq.reqAddr       = reth.va;
                        curPermCheckReq.totalLen      = reth.dlen;
                        curPermCheckReq.pdHandler     = pktMetaData.pdHandler;
                        curPermCheckReq.isZeroDmaLen  = isZeroRethLen;
                        curPermCheckReq.accFlags      = enum2Flag(IBV_ACCESS_REMOTE_WRITE);
                        curPermCheckReq.localOrRmtKey = False;

                        contextRQ.setPermCheckReq(curPermCheckReq);
                    end
                    else begin
                        curPermCheckReq = contextRQ.getPermCheckReq;
                    end

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

                        curPermCheckReq.wrID = tagged Valid recvReq.id;
                    end
                    // if (isWriteImmReq) begin
                    //     immAssert(
                    //         isValid(maybeRecvReq),
                    //         "maybeRecvReq assertion @ mkReqHandleRQ",
                    //         $format(
                    //             "maybeRecvReq=", fshow(maybeRecvReq),
                    //             " should be valid when isWriteImmReq=", fshow(isWriteImmReq)
                    //         )
                    //     );
                    // end
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
                4'b0010: begin // read
                    immAssert(
                        !isValid(maybeRecvReq),
                        "maybeRecvReq assertion @ mkReqHandleRQ",
                        $format(
                            "maybeRecvReq=", fshow(maybeRecvReq),
                            " should be invalid when bth.opcode=", fshow(bth.opcode)
                        )
                    );

                    curPermCheckReq.wrID          = tagged Invalid;
                    curPermCheckReq.rkey          = reth.rkey;
                    curPermCheckReq.lkey          = dontCareValue;
                    curPermCheckReq.reqAddr       = reth.va;
                    curPermCheckReq.totalLen      = reth.dlen;
                    curPermCheckReq.pdHandler     = pktMetaData.pdHandler;
                    curPermCheckReq.isZeroDmaLen  = isZeroRethLen;
                    curPermCheckReq.accFlags      = enum2Flag(IBV_ACCESS_REMOTE_READ);
                    curPermCheckReq.localOrRmtKey = False;
                end
                4'b0001: begin // atomic
                    immAssert(
                        !isValid(maybeRecvReq),
                        "maybeRecvReq assertion @ mkReqHandleRQ",
                        $format(
                            "maybeRecvReq=", fshow(maybeRecvReq),
                            " should be invalid when bth.opcode=", fshow(bth.opcode)
                        )
                    );

                    curPermCheckReq.wrID          = tagged Invalid;
                    curPermCheckReq.rkey          = atomicEth.rkey;
                    curPermCheckReq.lkey          = dontCareValue;
                    curPermCheckReq.reqAddr       = atomicEth.va;
                    curPermCheckReq.totalLen      = fromInteger(valueOf(ATOMIC_WORK_REQ_LEN));
                    curPermCheckReq.pdHandler     = pktMetaData.pdHandler;
                    curPermCheckReq.isZeroDmaLen  = False;
                    curPermCheckReq.accFlags      = enum2Flag(IBV_ACCESS_REMOTE_ATOMIC);
                    curPermCheckReq.localOrRmtKey = False;
                end
                default: begin
                    if (reqStatus == RDMA_REQ_ST_ERR_FLUSH_RR) begin
                        if (maybeRecvReq matches tagged Valid .recvReq) begin
                            curPermCheckReq.wrID     = tagged Valid recvReq.id;
                            curPermCheckReq.lkey     = recvReq.lkey;
                            curPermCheckReq.reqAddr  = recvReq.laddr;
                            curPermCheckReq.totalLen = recvReq.len;
                        end
                    end
                    // immAssert(
                    //     (isSendReq || isWriteReq) && !isFirstOrOnlyPkt,
                    //     "unreachible case @ mkReqHandleRQ",
                    //     $format(
                    //         "bth.opcode=", fshow(bth.opcode),
                    //         ", hasReth=", fshow(hasReth),
                    //         ", isSendReq=", fshow(isSendReq),
                    //         ", isWriteReq=", fshow(isWriteReq),
                    //         ", isReadReq=", fshow(isReadReq),
                    //         ", isAtomicReq=", fshow(isAtomicReq),
                    //         ", isFirstOrOnlyPkt=", fshow(isFirstOrOnlyPkt)
                    //     )
                    // );

                    // if (isWriteImmReq) begin
                    //     immAssert(
                    //         isValid(maybeRecvReq),
                    //         "maybeRecvReq assertion @ mkReqHandleRQ",
                    //         $format(
                    //             "maybeRecvReq=", fshow(maybeRecvReq),
                    //             " should be valid when isWriteImmReq=", fshow(isWriteImmReq)
                    //         )
                    //     );
                    // end
                    // else begin
                    //     immAssert(
                    //         !isValid(maybeRecvReq),
                    //         "maybeRecvReq assertion @ mkReqHandleRQ",
                    //         $format(
                    //             "maybeRecvReq=", fshow(maybeRecvReq),
                    //             " should be invalid when bth.opcode=", fshow(bth.opcode)
                    //         )
                    //     );
                    // end
                end
            endcase
        end
        // else begin
        //     curPermCheckReq.wrID          = tagged Invalid;
        //     curPermCheckReq.lkey          = dontCareValue;
        //     curPermCheckReq.rkey          = dontCareValue;
        //     curPermCheckReq.reqAddr       = dontCareValue;
        //     curPermCheckReq.totalLen      = 0;
        //     curPermCheckReq.pdHandler     = pktMetaData.pdHandler;
        //     curPermCheckReq.isZeroDmaLen  = True;
        //     curPermCheckReq.accFlags      = enum2Flag(IBV_ACCESS_LOCAL_WRITE);
        //     curPermCheckReq.localOrRmtKey = True;

        //     if (reqStatus == RDMA_REQ_ST_ERR_FLUSH_RR) begin
        //         if (maybeRecvReq matches tagged Valid .recvReq) begin
        //             curPermCheckReq.wrID     = tagged Valid recvReq.id;
        //             curPermCheckReq.lkey     = recvReq.lkey;
        //             curPermCheckReq.reqAddr  = recvReq.laddr;
        //             curPermCheckReq.totalLen = recvReq.len;
        //         end
        //     end
        // end

        reqPermQueryQ.enq(tuple5(
            pktMetaData, reqStatus, curPermCheckReq, reqPktInfo, reth
        ));
        // $display(
        //     "time=%0t: 7th stage buildPermCheckReq", $time,
        //     ", bth.opcode=", fshow(bth.opcode),
        //     ", bth.psn=%h", bth.psn,
        //     ", reqStatus=", fshow(reqStatus),
        //     ", curPermCheckReq=", fshow(curPermCheckReq)
        // );
    endrule
*/
    // This rule still runs at retry or error state
    rule queryPerm4NormalReq if (cntrlStatus.comm.isNonErr || cntrlStatus.comm.isERR);
        let {
            pktMetaData, reqStatus, permCheckReq, reqPktInfo, reth
        } = reqPermQueryQ.first;
        reqPermQueryQ.deq;

        let bth = reqPktInfo.bth;

        let expectPermCheckResp = False;
        if (
            reqPktInfo.isFirstOrOnlyPkt && !hasErrHappened &&
            reqStatus == RDMA_REQ_ST_NORMAL && !permCheckReq.isZeroDmaLen
        ) begin
            permCheckSrv.request.put(permCheckReq);
            expectPermCheckResp = True;
        end

        reqPermCheckQ.enq(tuple6(
            pktMetaData, reqStatus, permCheckReq, reqPktInfo, reth, expectPermCheckResp
        ));
        // $display(
        //     "time=%0t: 9th stage queryPerm4NormalReq", $time,
        //     ", bth.opcode=", fshow(bth.opcode),
        //     ", bth.psn=%h", bth.psn,
        //     ", reqStatus=", fshow(reqStatus)
        // );
    endrule

    // This rule still runs at retry or error state
    rule checkPerm4NormalReq if (cntrlStatus.comm.isNonErr || cntrlStatus.comm.isERR);
        let {
            pktMetaData, reqStatus, permCheckReq, reqPktInfo, reth, expectPermCheckResp
        } = reqPermCheckQ.first;
        reqPermCheckQ.deq;

        let bth         = reqPktInfo.bth;
        let rdmaHeader  = pktMetaData.pktHeader;
        let isAtomicReq = reqPktInfo.isAtomicReq;
        let atomicEth   = extractAtomicEth(rdmaHeader.headerData, bth.trans);

        let isZeroDmaLen     = permCheckReq.isZeroDmaLen;
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

            let mrCheckResult <- permCheckSrv.response.get;
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
                        // $display(
                        //     "time=%0d: checkPerm4NormalReq", $time,
                        //     ", un-aligned atomicEth.va=%h", atomicEth.va
                        // );
                    end
                    // $display(
                    //     "time=%0t checkPerm4NormalReq", $time,
                    //     ", atomicEth.va=%h", atomicEth.va
                    // );
                end
            end
            else begin
                reqStatus = RDMA_REQ_ST_RMT_ACC;
            end
        end

        readCacheInsertQ.enq(tuple5(
            pktMetaData, reqStatus, permCheckReq, reqPktInfo, reth
        ));
        // $display(
        //     "time=%0t: 10th stage checkPerm4NormalReq", $time,
        //     ", bth.opcode=", fshow(bth.opcode),
        //     ", bth.psn=%h", bth.psn,
        //     ", reqStatus=", fshow(reqStatus)
        // );
    endrule

    // This rule still runs at retry or error state
    rule insertIntoReadCache if (cntrlStatus.comm.isNonErr || cntrlStatus.comm.isERR);
        let {
            pktMetaData, reqStatus, permCheckReq, reqPktInfo, reth
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
            pktMetaData, reqStatus, permCheckReq, reqPktInfo, reth
        ));
        // $display(
        //     "time=%0t: 11th stage insertIntoReadCache", $time,
        //     ", bth.opcode=", fshow(bth.opcode),
        //     ", bth.psn=%h", bth.psn,
        //     ", reqStatus=", fshow(reqStatus)
        // );
    endrule

    // This rule still runs at retry or error state
    rule queryPerm4DupReadReq if (cntrlStatus.comm.isNonErr || cntrlStatus.comm.isERR);
        let {
            pktMetaData, reqStatus, permCheckReq, reqPktInfo, reth
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
            pktMetaData, reqStatus, permCheckReq, reqPktInfo, reth, expectDupReadCheckResp
        ));
        // $display(
        //     "time=%0t: 12th stage queryPerm4DupReadReq", $time,
        //     ", bth.opcode=", fshow(bth.opcode),
        //     ", bth.psn=%h", bth.psn,
        //     ", reqStatus=", fshow(reqStatus)
        // );
    endrule

    // This rule still runs at retry or error state
    rule checkPerm4DupReadReq if (cntrlStatus.comm.isNonErr || cntrlStatus.comm.isERR);
        let {
            pktMetaData, reqStatus, permCheckReq, reqPktInfo, reth, expectDupReadCheckResp
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
                permCheckReq.reqAddr = verifiedDupReadAddr;
                dupReadReqStartState  = dupReadReqStart;

                immAssert(
                    permCheckReq.reqAddr == reth.va,
                    "permCheckReq.reqAddr assertion @ mkReqHandleRQ",
                    $format(
                        "permCheckReq.reqAddr=%h should == reth.va=%h",
                        permCheckReq.reqAddr, reth.va,
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
            pktMetaData, reqStatus, permCheckReq, reqPktInfo, dupReadReqStartState
        ));
        // $display(
        //     "time=%0t: 13th stage checkPerm4DupReadReq", $time,
        //     ", bth.opcode=", fshow(bth.opcode),
        //     ", bth.psn=%h", bth.psn,
        //     ", reqStatus=", fshow(reqStatus)
        // );
    endrule

    // This rule still runs at retry or error state
    rule calcNormalSendWriteReqDmaAddr if (cntrlStatus.comm.isNonErr || cntrlStatus.comm.isERR);
        let {
            pktMetaData, reqStatus, permCheckReq, reqPktInfo, dupReadReqStartState
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

        let curDmaWriteAddr    = permCheckReq.reqAddr;
        let nextDmaWriteAddr   = contextRQ.getNextDmaWriteAddr;
        let sendWriteReqPktNum = contextRQ.getSendWriteReqPktNum;
        let oneAsPSN           = 1;

        if (isSendReq || isWriteReq) begin
            case ( { pack(isOnlyPkt), pack(isFirstPkt), pack(isMidPkt), pack(isLastPkt) } )
                4'b1000: begin // isOnlyRdmaOpCode(bth.opcode)
                    // No need to calculate next DMA write address for only send/write responses
                    nextDmaWriteAddr   = permCheckReq.reqAddr;
                    sendWriteReqPktNum = 1;
                end
                4'b0100: begin // isFirstRdmaOpCode(bth.opcode)
                    nextDmaWriteAddr   = addrAddPsnMultiplyPMTU(permCheckReq.reqAddr, oneAsPSN, cntrlStatus.comm.getPMTU);
                    sendWriteReqPktNum = 1;
                end
                4'b0010: begin // isMiddleRdmaOpCode(bth.opcode)
                    curDmaWriteAddr    = contextRQ.getNextDmaWriteAddr;
                    nextDmaWriteAddr   = addrAddPsnMultiplyPMTU(contextRQ.getNextDmaWriteAddr, oneAsPSN, cntrlStatus.comm.getPMTU);
                    sendWriteReqPktNum = contextRQ.getSendWriteReqPktNum + 1;
                end
                4'b0001: begin // isLastRdmaOpCode(bth.opcode)
                    curDmaWriteAddr    = contextRQ.getNextDmaWriteAddr;
                    // No need to calculate next DMA write address for last send/write responses
                    nextDmaWriteAddr   = permCheckReq.reqAddr;
                    sendWriteReqPktNum = contextRQ.getSendWriteReqPktNum + 1;
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
                contextRQ.setNextDmaWriteAddr(nextDmaWriteAddr);
                contextRQ.setSendWriteReqPktNum(sendWriteReqPktNum);
                // $display(
                //     "time=%0t: nextDmaWriteAddr=%h, sendWriteReqPktNum=%0d",
                //     $time, nextDmaWriteAddr, sendWriteReqPktNum
                // );
            end
        end

        reqRemainingLenCalcQ.enq(tuple6(
            pktMetaData, reqStatus, permCheckReq,
            reqPktInfo, dupReadReqStartState, curDmaWriteAddr
        ));
        // $display(
        //     "time=%0t: 14th stage calcNormalSendWriteReqDmaAddr", $time,
        //     ", bth.opcode=", fshow(bth.opcode),
        //     ", bth.psn=%h", bth.psn,
        //     ", reqStatus=", fshow(reqStatus)
        // );
    endrule

    // This rule still runs at retry or error state
    rule calcNormalSendWriteReqDmaRemainingLen if (cntrlStatus.comm.isNonErr || cntrlStatus.comm.isERR);
        let {
            pktMetaData, reqStatus, permCheckReq,
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

        let remainingDmaWriteLen = contextRQ.getRemainingDmaWriteLen;
        let pktPayloadLen        = pktMetaData.pktPayloadLen;
        // let enoughDmaSpace       = False;
        let oneAsPSN             = 1;

        if (isSendReq || isWriteReq) begin
            case ( { pack(isOnlyPkt), pack(isFirstPkt), pack(isMidPkt), pack(isLastPkt) } )
                4'b1000: begin // isOnlyRdmaOpCode(bth.opcode)
                    // Exact remaining length is not necessory, zero or non-zero is enough
                    remainingDmaWriteLen = lenSubtractPktLen(permCheckReq.totalLen, pktPayloadLen, cntrlStatus.comm.getPMTU);
                end
                4'b0100: begin // isFirstRdmaOpCode(bth.opcode)
                    remainingDmaWriteLen = lenSubtractPsnMultiplyPMTU(permCheckReq.totalLen, oneAsPSN, cntrlStatus.comm.getPMTU);
                end
                4'b0010: begin // isMiddleRdmaOpCode(bth.opcode)
                    remainingDmaWriteLen = lenSubtractPsnMultiplyPMTU(contextRQ.getRemainingDmaWriteLen, oneAsPSN, cntrlStatus.comm.getPMTU);
                end
                4'b0001: begin // isLastRdmaOpCode(bth.opcode)
                    // Exact remaining length is not necessory, zero or non-zero is enough
                    remainingDmaWriteLen = lenSubtractPktLen(contextRQ.getRemainingDmaWriteLen, pktPayloadLen, cntrlStatus.comm.getPMTU);
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
                contextRQ.setRemainingDmaWriteLen(remainingDmaWriteLen);
                // $display(
                //     "time=%0t: remainingDmaWriteLen=%h, enoughDmaSpace=",
                //     $time, remainingDmaWriteLen, fshow(enoughDmaSpace)
                // );
            end
        end

        // reqTotalLenCalcQ.enq(tuple8(
        reqEnoughDmaSpaceQ.enq(tuple8(
            pktMetaData, reqStatus, permCheckReq, reqPktInfo, dupReadReqStartState,
            curDmaWriteAddr, remainingDmaWriteLen, contextRQ.getRemainingDmaWriteLen
        ));
        // $display(
        //     "time=%0t: 15th stage calcNormalSendWriteReqDmaRemainingLen", $time,
        //     ", bth.opcode=", fshow(bth.opcode),
        //     ", bth.psn=%h", bth.psn,
        //     ", reqStatus=", fshow(reqStatus)
        // );
    endrule

    // This rule still runs at retry or error state
    rule calcNormalSendWriteReqEnoughDmaSpace if (cntrlStatus.comm.isNonErr || cntrlStatus.comm.isERR);
        let {
            pktMetaData, reqStatus, permCheckReq, reqPktInfo, dupReadReqStartState,
            curDmaWriteAddr, remainingDmaWriteLen, preRemainingDmaWriteLen
        } = reqEnoughDmaSpaceQ.first;
        reqEnoughDmaSpaceQ.deq;

        let bth        = reqPktInfo.bth;
        let rdmaHeader = pktMetaData.pktHeader;
        let isSendReq  = reqPktInfo.isSendReq;
        let isWriteReq = reqPktInfo.isWriteReq;
        let isOnlyPkt  = reqPktInfo.isOnlyPkt;
        let isFirstPkt = reqPktInfo.isFirstPkt;
        // let isMidPkt   = reqPktInfo.isMidPkt;
        // let isLastPkt  = reqPktInfo.isLastPkt;
        let pktPayloadLen = pktMetaData.pktPayloadLen;

        let lastOrOnlyPktHasEnoughDmaSpace = lenGtEqPktLen(
            isOnlyPkt ? permCheckReq.totalLen : preRemainingDmaWriteLen,
            pktPayloadLen,
            cntrlStatus.comm.getPMTU
        );
        let firstOrMidPktHasEnoughDmaSpace = lenGtEqPMTU(
            isFirstPkt ? permCheckReq.totalLen : preRemainingDmaWriteLen,
            cntrlStatus.comm.getPMTU
        );
        // midPktCase   = lenGtEqPMTU(preRemainingDmaWriteLen, cntrlStatus.comm.getPMTU),
        // lastPktCase  = lenGtEqPktLen(preRemainingDmaWriteLen, pktPayloadLen, cntrlStatus.comm.getPMTU)

        let enoughDmaSpaceCheck = EnoughDmaSpaceCheck {
            onlyPktCase : False,
            firstPktCase: False,
            midPktCase  : False,
            lastPktCase : False
        };

        if (isSendReq || isWriteReq) begin
            enoughDmaSpaceCheck.onlyPktCase  = lastOrOnlyPktHasEnoughDmaSpace;
            enoughDmaSpaceCheck.firstPktCase = firstOrMidPktHasEnoughDmaSpace;
            enoughDmaSpaceCheck.midPktCase   = firstOrMidPktHasEnoughDmaSpace;
            enoughDmaSpaceCheck.lastPktCase  = lastOrOnlyPktHasEnoughDmaSpace;
        end

        reqTotalLenCalcQ.enq(tuple8(
            pktMetaData, reqStatus, permCheckReq, reqPktInfo, dupReadReqStartState,
            curDmaWriteAddr, remainingDmaWriteLen, enoughDmaSpaceCheck
        ));
        // $display(
        //     "time=%0t: 16th stage calcNormalSendWriteReqEnoughDmaSpace", $time,
        //     ", bth.opcode=", fshow(bth.opcode),
        //     ", bth.psn=%h", bth.psn,
        //     ", reqStatus=", fshow(reqStatus)
        // );
    endrule

    // This rule still runs at retry or error state
    rule calcNormalSendWriteReqDmaTotalLen if (cntrlStatus.comm.isNonErr || cntrlStatus.comm.isERR);
        let {
            pktMetaData, reqStatus, permCheckReq, reqPktInfo, dupReadReqStartState,
            curDmaWriteAddr, remainingDmaWriteLen, enoughDmaSpaceCheck
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

        Length totalDmaWriteLen  = contextRQ.getTotalDmaWriteLen;
        let pktPayloadLen        = pktMetaData.pktPayloadLen;
        let enoughDmaSpace       = False;
        let isLastPayloadLenZero = False;
        let oneAsPSN             = 1;

        if (isSendReq || isWriteReq) begin
            case ( { pack(isOnlyPkt), pack(isFirstPkt), pack(isMidPkt), pack(isLastPkt) } )
                4'b1000: begin // isOnlyRdmaOpCode(bth.opcode)
                    totalDmaWriteLen     = zeroExtend(pktPayloadLen);
                    enoughDmaSpace       = enoughDmaSpaceCheck.lastPktCase;
                end
                4'b0100: begin // isFirstRdmaOpCode(bth.opcode)
                    // totalDmaWriteLen     = lenAddPsnMultiplyPMTU(0, oneAsPSN, cntrlStatus.comm.getPMTU);
                    totalDmaWriteLen     = zeroExtend(calcPmtuLen(cntrlStatus.comm.getPMTU));
                    enoughDmaSpace       = enoughDmaSpaceCheck.midPktCase;
                end
                4'b0010: begin // isMiddleRdmaOpCode(bth.opcode)
                    totalDmaWriteLen     = lenAddPsnMultiplyPMTU(contextRQ.getTotalDmaWriteLen, oneAsPSN, cntrlStatus.comm.getPMTU);
                    enoughDmaSpace       = enoughDmaSpaceCheck.firstPktCase;
                end
                4'b0001: begin // isLastRdmaOpCode(bth.opcode)
                    totalDmaWriteLen     = lenAddPktLen(contextRQ.getTotalDmaWriteLen, pktPayloadLen, cntrlStatus.comm.getPMTU);
                    enoughDmaSpace       = enoughDmaSpaceCheck.onlyPktCase;
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
                contextRQ.setTotalDmaWriteLen(totalDmaWriteLen);
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
            pktMetaData, reqStatus, permCheckReq,
            reqPktInfo, reqLenCheckResult, dupReadReqStartState
        ));
        // $display(
        //     "time=%0t: 17th stage calcNormalSendWriteReqDmaTotalLen", $time,
        //     ", bth.opcode=", fshow(bth.opcode),
        //     ", bth.psn=%h", bth.psn,
        //     ", reqStatus=", fshow(reqStatus)
        // );
    endrule

    // This rule still runs at retry or error state
    rule checkReqLen if (cntrlStatus.comm.isNonErr || cntrlStatus.comm.isERR);
        let {
            pktMetaData, reqStatus, permCheckReq,
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
                    // $display(
                    //     "time=%0t:", $time,
                    //     " bth.opcode=", fshow(bth.opcode), ", bth.psn=%h", bth.psn,
                    //     ", permCheckReq.totalLen=%0d", permCheckReq.totalLen,
                    //     ", remainingDmaWriteLen=%0d", remainingDmaWriteLen,
                    //     ", totalDmaWriteLen=%0d", totalDmaWriteLen,
                    //     ", noRemainingDmaWrite=", fshow(noRemainingDmaWrite),
                    //     ", writeReqLenMatch=", fshow(writeReqLenMatch),
                    //     ", enoughDmaSpace=", fshow(enoughDmaSpace),
                    //     ", isLastPayloadLenZero=", fshow(isLastPayloadLenZero),
                    //     ", reqStatus=", fshow(reqStatus)
                    // );
                end
                else if (isSendReq && (isLastPkt || isOnlyPkt)) begin
                    // Update send request total length
                    permCheckReq.totalLen = totalDmaWriteLen;
                end
            end
        end

        issuePayloadConReqQ.enq(tuple6(
            pktMetaData, reqStatus, permCheckReq,
            reqPktInfo, curDmaWriteAddr, dupReadReqStartState
        ));
        // $display(
        //     "time=%0t: 18th stage checkReqLen", $time,
        //     ", bth.opcode=", fshow(bth.opcode),
        //     ", bth.psn=%h", bth.psn,
        //     ", reqStatus=", fshow(reqStatus)
        // );
    endrule

    // This rule still runs at retry or error state
    rule issuePayloadConReqOrDiscard if (cntrlStatus.comm.isNonErr || cntrlStatus.comm.isERR);
        let {
            pktMetaData, reqStatus, permCheckReq,
            reqPktInfo, curDmaWriteAddr, dupReadReqStartState
        } = issuePayloadConReqQ.first;
        issuePayloadConReqQ.deq;

        let bth              = reqPktInfo.bth;
        let isSendReq        = reqPktInfo.isSendReq;
        let isWriteReq       = reqPktInfo.isWriteReq;
        let isZeroDmaLen     = permCheckReq.isZeroDmaLen;
        let isZeroPayloadLen = pktMetaData.isZeroPayloadLen;

        if (reqStatus == RDMA_REQ_ST_NORMAL && !hasErrHappened) begin
        // if (reqStatus == RDMA_REQ_ST_NORMAL && !hasReqStatusErrReg) begin
            if ((isSendReq || isWriteReq) && !isZeroDmaLen) begin
                let payloadConReq = PayloadConReq {
                    fragNum      : pktMetaData.pktFragNum,
                    consumeInfo  : tagged SendWriteReqReadRespInfo DmaWriteMetaData {
                        initiator: DMA_SRC_RQ_WR,
                        sqpn     : cntrlStatus.comm.getSQPN,
                        startAddr: curDmaWriteAddr,
                        len      : pktMetaData.pktPayloadLen,
                        psn      : bth.psn,
                        mrID     : rkey2IndexMR(permCheckReq.rkey)
                    }
                };
                // payloadConReqOutQ.enq(payloadConReq);
                payloadConReqPort.put(payloadConReq);
            end
        end
        // if (reqStatus != RDMA_REQ_ST_NORMAL || hasErrHappened) begin
        else if (!isZeroPayloadLen) begin
            // Discard request payload if duplicate, error or flushing
            let initiator = DMA_SRC_RQ_DISCARD;
            let payloadDiscardReq <- genDiscardPayloadReq(
                pktMetaData.pktFragNum, initiator, cntrlStatus.comm.getSQPN,
                curDmaWriteAddr, pktMetaData.pktPayloadLen, bth.psn,
                rkey2IndexMR(permCheckReq.rkey)
            );
            // payloadConReqOutQ.enq(payloadDiscardReq);
            payloadConReqPort.put(payloadDiscardReq);
            // $display(
            //     "time=%0t:", $time,
            //     " issuePayloadConReqOrDiscard discard payload",
            //     ", bth.opcode=", fshow(bth.opcode),
            //     ", bth.psn=%h", bth.psn,
            //     ", dqpn=%h", cntrlStatus.comm.getSQPN,
            //     ", pktFragNum=%0d", pktMetaData.pktFragNum,
            //     ", pktPayloadLen=%0d", pktMetaData.pktPayloadLen
            // );
        end

        // Set internal error state if any error request status,
        // and no more DMA requests after first error.
        let hasReqStatusErr = hasReqStatusErrReg;
        // if (isErrReqStatus(reqStatus) && !hasErrHappened) begin
        if (isErrReqStatus(reqStatus)) begin
            hasReqStatusErr = True;

            if (!hasReqStatusErrReg) begin
                $display(
                    "time=%0t: set hasReqStatusErrReg", $time,
                    ", dqpn=%h", cntrlStatus.comm.getSQPN,
                    ", reqStatus=", fshow(reqStatus),
                    ", bth.psn=%h", bth.psn
                );
            end
        end
        hasReqStatusErrReg <= hasReqStatusErr;

        issuePayloadGenReqQ.enq(tuple6(
            pktMetaData, reqStatus, permCheckReq, reqPktInfo,
            hasReqStatusErr, dupReadReqStartState
        ));
        // $display(
        //     "time=%0t: 19th stage issuePayloadConReqOrDiscard", $time,
        //     ", bth.opcode=", fshow(bth.opcode),
        //     ", bth.psn=%h", bth.psn,
        //     ", hasReqStatusErr=", fshow(hasReqStatusErr),
        //     ", reqStatus=", fshow(reqStatus)
        // );
    endrule

    // This rule still runs at retry or error state
    rule issuePayloadGenReq if (cntrlStatus.comm.isNonErr || cntrlStatus.comm.isERR);
        let {
            pktMetaData, reqStatus, permCheckReq, reqPktInfo, hasReqStatusErr, dupReadReqStartState
        } = issuePayloadGenReqQ.first;
        issuePayloadGenReqQ.deq;

        let bth          = reqPktInfo.bth;
        let isReadReq    = reqPktInfo.isReadReq;
        let isZeroDmaLen = permCheckReq.isZeroDmaLen;

        let expectReadRespPayload = False;
        if (!hasReqStatusErr && !hasDmaReadRespErrReg) begin
            if (
                !isZeroDmaLen && isReadReq &&
                (reqStatus == RDMA_REQ_ST_NORMAL || reqStatus == RDMA_REQ_ST_DUP)
            ) begin
                let payloadGenReq = PayloadGenReq {
                    // segment      : True,
                    addPadding     : True,
                    pmtu           : cntrlStatus.comm.getPMTU,
                    dmaReadMetaData: DmaReadMetaData {
                        initiator: DMA_SRC_RQ_RD,
                        sqpn     : cntrlStatus.comm.getSQPN,
                        startAddr: permCheckReq.reqAddr, // reth.va
                        len      : permCheckReq.totalLen, // reth.dlen
                        mrID     : rkey2IndexMR(permCheckReq.rkey)
                    }
                };

                payloadGenerator.srvPort.request.put(payloadGenReq);
                expectReadRespPayload = True;
                // $display(
                //     "time=%0t: issuePayloadGenReq", $time,
                //     ", payloadGenReq=", fshow(payloadGenReq)
                // );
            end
        end

        let respPktGenInfo = RespPktGenInfo {
            hasReqStatusErr         : hasReqStatusErr, // hasErrHappened, //
            hasDmaReadRespErr       : hasDmaReadRespErrReg, // False,
            hasErrRespGen           : False,
            shouldGenResp           : False,
            expectReadRespPayload   : expectReadRespPayload,
            expectAtomicRespOrig    : False,
            expectDupAtomicCheckResp: False,
            atomicAckOrig           : tagged Invalid,
            dupReadReqStartState    : dupReadReqStartState
        };
        issueAtomicReqQ.enq(tuple5(
            pktMetaData, reqStatus, permCheckReq, reqPktInfo, respPktGenInfo
        ));
        // $display(
        //     "time=%0t: 20th stage issuePayloadGenReq", $time,
        //     ", bth.opcode=", fshow(bth.opcode),
        //     ", bth.psn=%h", bth.psn,
        //     ", reqStatus=", fshow(reqStatus),
        //     ", isZeroDmaLen=", fshow(isZeroDmaLen),
        //     ", expectReadRespPayload=", fshow(expectReadRespPayload),
        //     // ", expectAtomicRespOrig=", fshow(expectAtomicRespOrig),
        //     ", hasErrHappened=", fshow(hasErrHappened),
        //     ", hasReqStatusErr=", fshow(hasReqStatusErr),
        //     ", hasDmaReadRespErrReg=", fshow(hasDmaReadRespErrReg)
        // );
    endrule

    // This rule still runs at retry or error state
    rule issueAtomicReq if (cntrlStatus.comm.isNonErr || cntrlStatus.comm.isERR);
        let {
            pktMetaData, reqStatus, permCheckReq, reqPktInfo, respPktGenInfo
        } = issueAtomicReqQ.first;
        issueAtomicReqQ.deq;

        let bth             = reqPktInfo.bth;
        let rdmaHeader      = pktMetaData.pktHeader;
        let atomicEth       = extractAtomicEth(rdmaHeader.headerData, bth.trans);
        let isAtomicReq     = reqPktInfo.isAtomicReq;
        let hasReqStatusErr = respPktGenInfo.hasReqStatusErr;

        let expectAtomicRespOrig  = False;
        if (!hasReqStatusErr && !hasDmaReadRespErrReg) begin
            if (reqStatus == RDMA_REQ_ST_NORMAL && isAtomicReq) begin
                let atomicOpReq = AtomicOpReq {
                    initiator    : DMA_SRC_RQ_ATOMIC,
                    casOrFetchAdd: bth.opcode == COMPARE_SWAP,
                    startAddr    : atomicEth.va,
                    compData     : atomicEth.comp,
                    swapData     : atomicEth.swap,
                    sqpn         : cntrlStatus.comm.getSQPN,
                    psn          : bth.psn
                };

                atomicSrv.request.put(atomicOpReq);
                expectAtomicRespOrig = True;
            end
        end

        respPktGenInfo.hasDmaReadRespErr = hasDmaReadRespErrReg;
        respPktGenInfo.expectAtomicRespOrig = expectAtomicRespOrig;
        respGenCheck4NormalCaseQ.enq(tuple5(
            pktMetaData, reqStatus, permCheckReq, reqPktInfo, respPktGenInfo
        ));
        // $display(
        //     "time=%0t: 21th stage issueAtomicReq", $time,
        //     ", bth.opcode=", fshow(bth.opcode),
        //     ", bth.psn=%h", bth.psn,
        //     ", reqStatus=", fshow(reqStatus),
        //     ", expectAtomicRespOrig=", fshow(expectAtomicRespOrig),
        //     // ", hasErrHappened=", fshow(hasErrHappened),
        //     ", hasReqStatusErr=", fshow(hasReqStatusErr),
        //     ", hasDmaReadRespErrReg=", fshow(hasDmaReadRespErrReg)
        // );
    endrule

    // This rule still runs at retry or error state
    rule shouldGenResp4NormalCase if (cntrlStatus.comm.isNonErr || cntrlStatus.comm.isERR);
        let {
            pktMetaData, reqStatus, permCheckReq, reqPktInfo, respPktGenInfo
        } = respGenCheck4NormalCaseQ.first;
        respGenCheck4NormalCaseQ.deq;

        let bth = reqPktInfo.bth;

        let isSendReq       = reqPktInfo.isSendReq;
        let isWriteReq      = reqPktInfo.isWriteReq;
        let isReadReq       = reqPktInfo.isReadReq;
        let isAtomicReq     = reqPktInfo.isAtomicReq;
        let isLastOrOnlyPkt = reqPktInfo.isLastOrOnlyPkt;
        let hasReqStatusErr = respPktGenInfo.hasReqStatusErr;

        // let shouldDiscard = False;
        let shouldGenResp = False;
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

            if (qpHasResp && !hasReqStatusErr) begin
                // The counter will record how many normal send/write requests
                // without AckReq, and if more than MAX_QP_WR consecutive send/write requests
                // without AckReq, enforce a response to avoid SQ deadlock.
                if (reloadPendingWorkReqCnt) begin
                    coalesceWorkReqCnt <= cntrlStatus.comm.getPendingWorkReqNum - 1;
                    // contextRQ.setPendingWorkReqCnt(cntrlStatus.comm.getPendingWorkReqNum - 1);
                    isCoalesceWorkReqCntZeroReg <= isOne(cntrlStatus.comm.getPendingWorkReqNum);
                end
                else if (decrPendingWorkReqCnt) begin
                    coalesceWorkReqCnt.decr(1);
                    // contextRQ.setPendingWorkReqCnt(contextRQ.getPendingWorkReqCnt - 1);
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
            pktMetaData, reqStatus, permCheckReq, reqPktInfo, respPktGenInfo
        ));
        // $display(
        //     "time=%0t: 22st stage shouldGenResp4NormalCase", $time,
        //     ", bth.opcode=", fshow(bth.opcode),
        //     ", bth.psn=%h", bth.psn,
        //     ", bth.ackReq=", fshow(bth.ackReq),
        //     // ", shouldDiscard=", fshow(shouldDiscard),
        //     ", shouldGenResp=", fshow(shouldGenResp),
        //     ", reqStatus=", fshow(reqStatus)
        // );
    endrule

    // This rule still runs at retry or error state
    rule shouldGenResp4OtherCases if (cntrlStatus.comm.isNonErr || cntrlStatus.comm.isERR);
        let {
            pktMetaData, reqStatus, permCheckReq, reqPktInfo, respPktGenInfo
        } = respGenCheck4OtherCasesQ.first;
        respGenCheck4OtherCasesQ.deq;

        let bth = reqPktInfo.bth;
        // let rdmaHeader = pktMetaData.pktHeader;

        let isSendReq       = reqPktInfo.isSendReq;
        let isWriteReq      = reqPktInfo.isWriteReq;
        let isReadReq       = reqPktInfo.isReadReq;
        let isAtomicReq     = reqPktInfo.isAtomicReq;
        let isLastOrOnlyPkt = reqPktInfo.isLastOrOnlyPkt;
        // let hasReqStatusErr = respPktGenInfo.hasReqStatusErr;

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

        // Set shouldGenResp even when hasReqStatusErr
        respPktGenInfo.shouldGenResp = shouldGenResp;

        respCountQ.enq(tuple5(
            pktMetaData, reqStatus, permCheckReq, reqPktInfo, respPktGenInfo
        ));
        // $display(
        //     "time=%0t: 23nd stage shouldGenResp4OtherCases", $time,
        //     ", bth.opcode=", fshow(bth.opcode),
        //     ", bth.psn=%h", bth.psn,
        //     ", bth.ackReq=", fshow(bth.ackReq),
        //     ", shouldDiscard=", fshow(shouldDiscard),
        //     ", shouldGenResp=", fshow(shouldGenResp),
        //     ", reqStatus=", fshow(reqStatus)
        // );
    endrule

    // This rule still runs at retry or error state
    rule countPendingResp if (cntrlStatus.comm.isNonErr || cntrlStatus.comm.isERR);
        let {
            pktMetaData, reqStatus, permCheckReq, reqPktInfo, respPktGenInfo
        } = respCountQ.first;

        let bth = reqPktInfo.bth;

        let remainingRespPktNum  = contextRQ.getRespPktNum;
        // let isFirstOrOnlyRespPkt = isFirstOrOnlyRespPktReg || hasErrRespGenReg;
        // let isLastOrOnlyRespPkt  = isLastOrOnlyRespPkt || hasErrRespGenReg;
        let isFirstOrOnlyRespPkt = isFirstOrOnlyRespPktReg;
        let isLastOrOnlyRespPkt  = reqPktInfo.isOnlyRespPkt ||
            (!isFirstOrOnlyRespPktReg && contextRQ.getIsRespPktNumZero);
        // If hasErrRespGenReg, no need to count response packets
        isFirstOrOnlyRespPktReg <= isLastOrOnlyRespPkt || hasErrRespGenReg;

        if (
            !(reqStatus == RDMA_REQ_ST_NORMAL || reqStatus == RDMA_REQ_ST_DUP) ||
            hasErrRespGenReg
        ) begin
            // No responses after error response
            // Error responses have single packet
            isFirstOrOnlyRespPkt = True;
            isLastOrOnlyRespPkt  = True;
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
                contextRQ.setRespPktNum(remainingRespPktNum);
            end
            else if (!isLastOrOnlyRespPkt) begin
                contextRQ.setRespPktNum(remainingRespPktNum - 1);
            end
        end

        let respPktSeqInfo = RespPktSeqInfo {
            isFirstOrOnlyRespPkt: isFirstOrOnlyRespPkt,
            isLastOrOnlyRespPkt : isLastOrOnlyRespPkt
        };
        respPsnAndMsnQ.enq(tuple6(
            pktMetaData, reqStatus, permCheckReq, reqPktInfo, respPktGenInfo, respPktSeqInfo
        ));
        // $display(
        //     "time=%0t: 24rd stage countPendingResp", $time,
        //     ", bth.opcode=", fshow(bth.opcode),
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
    rule updateRespPsnAndMsn if (cntrlStatus.comm.isNonErr || cntrlStatus.comm.isERR);
        let {
            pktMetaData, reqStatus, permCheckReq, reqPktInfo, respPktGenInfo, respPktSeqInfo
        } = respPsnAndMsnQ.first;
        respPsnAndMsnQ.deq;

        let bth       = reqPktInfo.bth;
        let isReadReq = reqPktInfo.isReadReq;

        let isLastOrOnlyReqPkt   = reqPktInfo.isLastOrOnlyPkt;
        let isFirstOrOnlyRespPkt = respPktSeqInfo.isFirstOrOnlyRespPkt;
        let isLastOrOnlyRespPkt  = respPktSeqInfo.isLastOrOnlyRespPkt;

        let respPSN = isFirstOrOnlyRespPkt ? bth.psn : contextRQ.getCurRespPSN;
        let msn     = contextRQ.getMSN;

        if (!hasErrRespGenReg) begin
            contextRQ.setCurRespPSN(respPSN + 1);

            if (reqStatus == RDMA_REQ_ST_NORMAL && isLastOrOnlyReqPkt && isLastOrOnlyRespPkt) begin
                msn = msn + 1;
                contextRQ.setMSN(msn);
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
            pktMetaData, reqStatus, permCheckReq,
            reqPktInfo, respPktGenInfo, respPktHeaderInfo
        ));
        // $display(
        //     "time=%0t: 25th stage updateRespPsnAndMsn", $time,
        //     ", bth.opcode=", fshow(bth.opcode),
        //     ", bth.psn=%h", bth.psn,
        //     ", bth.ackReq=", fshow(bth.ackReq),
        //     ", respPSN=%h", respPSN,
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
    rule waitAtomicResp if (cntrlStatus.comm.isNonErr || cntrlStatus.comm.isERR);
        let {
            pktMetaData, reqStatus, permCheckReq,
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
            pktMetaData, reqStatus, permCheckReq,
            reqPktInfo, respPktGenInfo, respPktHeaderInfo
        ));
        // $display(
        //     "time=%0t: 26th stage waitAtomicResp", $time,
        //     ", bth.opcode=", fshow(bth.opcode),
        //     ", bth.psn=%h", bth.psn,
        //     ", respPSN=%h", respPktHeaderInfo.psn,
        //     ", expectAtomicRespOrig=", fshow(respPktGenInfo.expectAtomicRespOrig),
        //     ", isAtomicReq=", fshow(isAtomicReq),
        //     ", reqStatus=", fshow(reqStatus)
        // );
    endrule

    // This rule still runs at retry or error state
    rule insertIntoAtomicCache if (cntrlStatus.comm.isNonErr || cntrlStatus.comm.isERR);
        let {
            pktMetaData, reqStatus, permCheckReq,
            reqPktInfo, respPktGenInfo, respPktHeaderInfo
        } = atomicCacheInsertQ.first;
        atomicCacheInsertQ.deq;

        let bth         = reqPktInfo.bth;
        let rdmaHeader  = pktMetaData.pktHeader;
        let atomicEth   = extractAtomicEth(rdmaHeader.headerData, bth.trans);
        let isAtomicReq = reqPktInfo.isAtomicReq;

        // let hasReqStatusErr = respPktGenInfo.hasReqStatusErr;
        // if (reqStatus == RDMA_REQ_ST_NORMAL && isAtomicReq && !hasReqStatusErr) begin
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
            pktMetaData, reqStatus, permCheckReq, reqPktInfo,
            respPktGenInfo, respPktHeaderInfo, atomicEth
        ));
        // $display(
        //     "time=%0t: 27th stage insertIntoAtomicCache", $time,
        //     ", bth.opcode=", fshow(bth.opcode),
        //     ", bth.psn=%h", bth.psn,
        //     ", respPSN=%h", respPktHeaderInfo.psn,
        //     ", reqStatus=", fshow(reqStatus)
        // );
    endrule

    // This rule still runs at retry or error state
    rule checkReadResp if (cntrlStatus.comm.isNonErr || cntrlStatus.comm.isERR);
        let {
            pktMetaData, reqStatus, permCheckReq, reqPktInfo,
            respPktGenInfo, respPktHeaderInfo, atomicEth
        } = respCheckQ.first;
        respCheckQ.deq;

        let bth               = reqPktInfo.bth;
        let isReadReq         = reqPktInfo.isReadReq;
        let hasDmaReadRespErr = respPktGenInfo.hasDmaReadRespErr;
        // let hasDmaReadRespErr = hasDmaReadRespErrReg;

        let expectReadRespPayload = respPktGenInfo.expectReadRespPayload;
        immAssert(
            !expectReadRespPayload || !hasDmaReadRespErr,
            "expectReadRespPayload assertion @ mkReqHandleRQ",
            $format(
                "hasDmaReadRespErr=", fshow(hasDmaReadRespErr),
                " must be false when expectReadRespPayload=",
                fshow(expectReadRespPayload)
            )
        );
        // if (!hasErrRespGenReg) begin
        //     if (hasDmaReadRespErr) begin
        //         // This case means previous duplicate operation had DMA read response error,
        //         // But no error responses for duplicate requests.
        //         // So it needs to generate an error response here.
        //         if (isNormalOrErrorReqStatus(reqStatus)) begin
        //             reqStatus = RDMA_REQ_ST_RMT_OP;
        //             respPktGenInfo.shouldGenResp = True;
        //         end
        //         else if (reqStatus == RDMA_REQ_ST_DUP) begin
        //             reqStatus = RDMA_REQ_ST_DISCARD;
        //             respPktGenInfo.shouldGenResp = False;
        //         end
        //     end
        //     else if (expectReadRespPayload) begin
        if (!hasDmaReadRespErrReg) begin
            if (expectReadRespPayload) begin
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
                    isReadReq && respPktGenInfo.shouldGenResp,
                    "isReadReq assertion @ ReqHandleRQ",
                    $format(
                        "isReadReq=", fshow(isReadReq),
                        " and respPktGenInfo.shouldGenResp=",
                        fshow(respPktGenInfo.shouldGenResp),
                        " should both be true when expectReadRespPayload=",
                        fshow(expectReadRespPayload),
                        " but bth.opcode=", fshow(bth.opcode)
                    )
                );

                let payloadGenResp <- payloadGenerator.srvPort.response.get;

                if (payloadGenResp.isRespErr) begin
                    hasDmaReadRespErr     = True;
                    hasDmaReadRespErrReg <= hasDmaReadRespErr;
                    // readRespErrNotifyReg <= hasDmaReadRespErr;
                    respPktGenInfo.expectReadRespPayload = False;
                    $display(
                        "time=%0t: set hasDmaReadRespErrReg", $time,
                        ", dqpn=%h", cntrlStatus.comm.getSQPN,
                        ", hasDmaReadRespErr=", fshow(hasDmaReadRespErr),
                        ", reqStatus=", fshow(reqStatus)
                    );
                end
            end
        end

        // TODO: set reqStatus to error status
        // Set hasDmaReadRespErr when DMA read response error occurred
        respPktGenInfo.hasDmaReadRespErr = hasDmaReadRespErr;

        dupAtomicReqPermQueryQ.enq(tuple7(
            pktMetaData, reqStatus, permCheckReq, reqPktInfo,
            respPktGenInfo, respPktHeaderInfo, atomicEth
        ));
        // $display(
        //     "time=%0t: 28th stage checkReadResp", $time,
        //     ", bth.opcode=", fshow(bth.opcode),
        //     ", bth.psn=%h", bth.psn,
        //     ", bth.ackReq=", fshow(bth.ackReq),
        //     ", respPSN=%h", respPktHeaderInfo.psn,
        //     ", shouldGenResp=", fshow(respPktGenInfo.shouldGenResp),
        //     ", expectReadRespPayload=", fshow(expectReadRespPayload),
        //     ", hasDmaReadRespErr=", fshow(hasDmaReadRespErr),
        //     ", reqStatus=", fshow(reqStatus)
        // );
    endrule

    // This rule still runs at retry or error state
    rule queryPerm4DupAtomicReq if (cntrlStatus.comm.isNonErr || cntrlStatus.comm.isERR);
        let {
            pktMetaData, reqStatus, permCheckReq, reqPktInfo, respPktGenInfo, respPktHeaderInfo, atomicEth
        } = dupAtomicReqPermQueryQ.first;
        dupAtomicReqPermQueryQ.deq;

        let bth         = reqPktInfo.bth;
        let isAtomicReq = reqPktInfo.isAtomicReq;

        let expectDupAtomicCheckResp = False;
        let hasReqStatusErr   = respPktGenInfo.hasReqStatusErr;
        let hasDmaReadRespErr = respPktGenInfo.hasDmaReadRespErr;
        if (reqStatus == RDMA_REQ_ST_DUP && isAtomicReq && !hasReqStatusErr && !hasDmaReadRespErr) begin
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
            pktMetaData, reqStatus, permCheckReq, reqPktInfo, respPktGenInfo, respPktHeaderInfo
        ));
        // $display(
        //     "time=%0t: 29th stage queryPerm4DupAtomicReq", $time,
        //     ", bth.opcode=", fshow(bth.opcode),
        //     ", bth.psn=%h", bth.psn,
        //     ", respPSN=%h", respPktHeaderInfo.psn,
        //     ", reqStatus=", fshow(reqStatus),
        //     ", expectDupAtomicCheckResp=", fshow(expectDupAtomicCheckResp),
        //     ", hasReqStatusErr=", fshow(hasReqStatusErr)
        // );
    endrule

    // This rule still runs at retry or error state
    rule checkPerm4DupAtomicReq if (cntrlStatus.comm.isNonErr || cntrlStatus.comm.isERR);
        let {
            pktMetaData, reqStatus, permCheckReq, reqPktInfo, respPktGenInfo, respPktHeaderInfo
        } = dupAtomicReqPermCheckQ.first;
        dupAtomicReqPermCheckQ.deq;

        let bth         = reqPktInfo.bth;
        let isAtomicReq = reqPktInfo.isAtomicReq;

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
            pktMetaData, reqStatus, permCheckReq, reqPktInfo, respPktGenInfo, respPktHeaderInfo
        ));
        // $display(
        //     "time=%0t: 30th stage checkPerm4DupAtomicReq", $time,
        //     ", bth.opcode=", fshow(bth.opcode),
        //     ", bth.psn=%h", bth.psn,
        //     ", respPSN=%h", respPktHeaderInfo.psn,
        //     ", reqStatus=", fshow(reqStatus),
        //     ", expectDupAtomicCheckResp=", fshow(expectDupAtomicCheckResp),
        //     ", hasReqStatusErr=", fshow(respPktGenInfo.hasReqStatusErr)
        // );
    endrule

    // This rule still runs at retry or error state
    rule genRespHeader if (cntrlStatus.comm.isNonErr || cntrlStatus.comm.isERR);
        let {
            pktMetaData, reqStatus, permCheckReq, reqPktInfo, respPktGenInfo, respPktHeaderInfo
        } = respHeaderGenQ.first;
        respHeaderGenQ.deq;

        let bth = reqPktInfo.bth;
        let psn = respPktHeaderInfo.psn;
        let msn = respPktHeaderInfo.msn;

        let hasErrRespGen            = hasErrRespGenReg;
        let hasReqStatusErr          = respPktGenInfo.hasReqStatusErr;
        let hasDmaReadRespErr        = respPktGenInfo.hasDmaReadRespErr;
        let expectReadRespPayload    = respPktGenInfo.expectReadRespPayload;
        let expectAtomicRespOrig     = respPktGenInfo.expectAtomicRespOrig;
        let expectDupAtomicCheckResp = respPktGenInfo.expectDupAtomicCheckResp;

        let maybeHeader = tagged Invalid;
        if (hasErrRespGen) begin
            respPktGenInfo.shouldGenResp = False;
        end
        else begin
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

            if (respPktHeaderInfo.isFirstOrOnlyRespPkt) begin
                let isOnlyReadRespPkt = reqPktInfo.isOnlyRespPkt && reqPktInfo.isReadReq;
                let maybeFirstOrOnlyHeader = genFirstOrOnlyRespHeader(
                    bth.opcode, reqStatus, permCheckReq.totalLen, respPktGenInfo.atomicAckOrig,
                    cntrlStatus, psn, msn, isOnlyReadRespPkt
                );
                maybeHeader = maybeFirstOrOnlyHeader;
            end
            else begin
                let maybeMiddleOrLastHeader = genMiddleOrLastRespHeader(
                    bth.opcode, reqStatus, permCheckReq.totalLen,
                    cntrlStatus, psn, msn, respPktHeaderInfo.isLastOrOnlyRespPkt
                );
                maybeHeader = maybeMiddleOrLastHeader;
            end
        end

        let errReqStatus = isErrReqStatus(reqStatus);
        if (errReqStatus) begin
            // Note that hasErrRespGen != hasReqStatusErr || hasDmaReadRespErr
            hasErrRespGen = True;
            if (!hasErrRespGenReg) begin
                $display(
                    "time=%0t: first fatal error response generated", $time,
                    ", dqpn=%h", cntrlStatus.comm.getSQPN,
                    ", reqStatus=", fshow(reqStatus)
                );
            end
        end
        hasErrRespGenReg <= hasErrRespGen;
        respPktGenInfo.hasErrRespGen = hasErrRespGen;

        if (hasReqStatusErr || hasDmaReadRespErr) begin
            immAssert(
                !expectReadRespPayload &&
                !expectAtomicRespOrig  &&
                !expectDupAtomicCheckResp,
                "hasReqStatusErr or hasDmaReadRespErr assertion @ mkReqHandleRQ",
                $format(
                    "bth.psn=%h", bth.psn, ", bth.opcode=", fshow(bth.opcode),
                    ", expectReadRespPayload=", fshow(expectReadRespPayload),
                    ", expectAtomicRespOrig=", fshow(expectAtomicRespOrig),
                    ", expectDupAtomicCheckResp=", fshow(expectDupAtomicCheckResp),
                    ", all should be false when hasReqStatusErr=", fshow(hasReqStatusErr),
                    ", hasDmaReadRespErr=", fshow(hasDmaReadRespErr),
                    ", hasErrRespGen=", fshow(hasErrRespGen),
                    ", reqStatus=", fshow(reqStatus)
                )
            );
        end
        immAssert(
            !hasErrRespGenReg || !respPktGenInfo.shouldGenResp,
            "shouldGenResp assertion @ mkReqHandleRQ",
            $format(
                "shouldGenResp=", fshow(respPktGenInfo.shouldGenResp),
                " must be false when reqStatus=", fshow(reqStatus),
                ", hasErrRespGenReg=", fshow(hasErrRespGenReg),
                ", hasReqStatusErr=", fshow(hasReqStatusErr),
                " and hasDmaReadRespErr=", fshow(hasDmaReadRespErr)
            )
        );

        pendingRespQ.enq(tuple7(
            pktMetaData, reqStatus, permCheckReq, reqPktInfo,
            respPktGenInfo, respPktHeaderInfo, maybeHeader
        ));
        // $display(
        //     "time=%0t: 31th stage genRespHeader", $time,
        //     ", bth.opcode=", fshow(bth.opcode),
        //     ", bth.psn=%h", bth.psn, ", bth.ackReq=", fshow(bth.ackReq),
        //     ", respPSN=%h", respPktHeaderInfo.psn,
        //     ", isOnlyRespPkt=", fshow(reqPktInfo.isOnlyRespPkt),
        //     ", shouldGenResp=", fshow(respPktGenInfo.shouldGenResp),
        //     ", hasDmaReadRespErr=", fshow(hasDmaReadRespErr),
        //     ", hasErrRespGen=", fshow(hasErrRespGen),
        //     ", hasReqStatusErr=", fshow(hasReqStatusErr),
        //     ", reqStatus=", fshow(reqStatus)
        // );
    endrule

    // This rule still runs at retry or error state
    rule genRespPkt if (cntrlStatus.comm.isNonErr || cntrlStatus.comm.isERR);
        let {
            pktMetaData, reqStatus, permCheckReq, reqPktInfo,
            respPktGenInfo, respPktHeaderInfo, maybeHeader
        } = pendingRespQ.first;
        pendingRespQ.deq;

        let bth     = reqPktInfo.bth;
        let respPSN = respPktHeaderInfo.psn;
        let msn     = respPktHeaderInfo.msn;

        let hasReqStatusErr   = respPktGenInfo.hasReqStatusErr;
        let hasDmaReadRespErr = respPktGenInfo.hasDmaReadRespErr;
        let hasErrRespGen     = respPktGenInfo.hasErrRespGen;
        let isZeroDmaLen      = permCheckReq.isZeroDmaLen;
        // It's possible that hasDmaReadRespErr && !hasErrRespGen,
        // as for error duplicate read response
        let hasErrIncurred = hasReqStatusErr || hasDmaReadRespErr; // || hasErrRespGen;

        // It is possible that maybeFirstOrOnlyHeader is valid
        // but no need to generate responses
        if (respPktHeaderInfo.isFirstOrOnlyRespPkt) begin
            let maybeFirstOrOnlyHeader = maybeHeader;
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
                    respHeaderOutQ.enq(firstOrOnlyHeader);
                    psnRespOutQ.enq(respPSN);
                    // $display(
                    //     "time=%0t: generate first or only response header", $time,
                    //     ", bth.psn=%h", bth.psn, ", bth.ackReq=", fshow(bth.ackReq),
                    //     ", respPSN=%h", respPSN,
                    //     ", isOnlyRespPkt=", fshow(reqPktInfo.isOnlyRespPkt),
                    //     ", hasReqStatusErr=", fshow(hasReqStatusErr),
                    //     ", hasDmaReadRespErr=", fshow(hasDmaReadRespErr),
                    //     ", hasErrRespGen=", fshow(hasErrRespGen),
                    //     ", reqStatus=", fshow(reqStatus),
                    //     ", firstOrOnlyHeader=", fshow(firstOrOnlyHeader)
                    // );
                end
            end

            if (
                reqPktInfo.isAtomicReq           &&
                (reqStatus == RDMA_REQ_ST_NORMAL || reqStatus == RDMA_REQ_ST_DUP)
            ) begin
                immAssert(
                    hasErrIncurred || isValid(respPktGenInfo.atomicAckOrig),
                    "atomicAckOrig assertion @ mkReqHandleRQ",
                    $format(
                        "atomicAckOrig=", fshow(respPktGenInfo.atomicAckOrig),
                        " should be valid when bth.psn=%h", bth.psn,
                        ", bth.opcode=", fshow(bth.opcode),
                        ", isAtomicReq=", fshow(reqPktInfo.isAtomicReq),
                        ", reqStatus=", fshow(reqStatus),
                        ", shouldGenResp=", fshow(respPktGenInfo.shouldGenResp),
                        ", hasErrRespGen=", fshow(hasErrRespGen),
                        ", hasReqStatusErr=", fshow(hasReqStatusErr),
                        ", hasDmaReadRespErr=", fshow(hasDmaReadRespErr)
                    )
                );
            end
        end
        else begin // middle/last responses
            immAssert(
                hasErrRespGen || respPktGenInfo.shouldGenResp,
                "shouldGenResp assertion @ mkReqHandleRQ",
                $format(
                    "shouldGenResp=", fshow(respPktGenInfo.shouldGenResp),
                    " must be true when isFirstOrOnlyRespPkt=",
                    fshow(respPktHeaderInfo.isFirstOrOnlyRespPkt),
                    " and hasErrRespGen=", fshow(hasErrRespGen)
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
            immAssert(
                (!(hasErrIncurred || isZeroDmaLen) && respPktGenInfo.expectReadRespPayload) ||
                ((hasErrIncurred || isZeroDmaLen) && !respPktGenInfo.expectReadRespPayload),
                "expectReadRespPayload assertion @ mkReqHandleRQ",
                $format(
                    "expectReadRespPayload=", fshow(respPktGenInfo.expectReadRespPayload),
                    " must be true when isFirstOrOnlyRespPkt=",
                    fshow(respPktHeaderInfo.isFirstOrOnlyRespPkt),
                    ", bth.psn=%h", bth.psn,
                    ", isZeroDmaLen=", fshow(isZeroDmaLen),
                    ", hasErrIncurred=", fshow(hasErrIncurred),
                    ", hasErrRespGen=", fshow(hasErrRespGen),
                    ", hasReqStatusErr=", fshow(hasReqStatusErr),
                    ", hasDmaReadRespErr=", fshow(hasDmaReadRespErr)
                )
            );

            let maybeMiddleOrLastHeader = maybeHeader;
            immAssert(
                hasErrRespGen || isValid(maybeMiddleOrLastHeader),
                "maybeMiddleOrLastHeader assertion @ mkReqHandleRQ",
                $format(
                    "maybeMiddleOrLastHeader=", fshow(maybeMiddleOrLastHeader),
                    " must be valid when reqStatus=", fshow(reqStatus),
                    ", hasErrRespGen=", fshow(hasErrRespGen),
                    ", hasReqStatusErr=", fshow(hasReqStatusErr),
                    ", hasDmaReadRespErr=", fshow(hasDmaReadRespErr)
                )
            );

            if (respPktGenInfo.shouldGenResp) begin
                immAssert(
                    reqStatus == RDMA_REQ_ST_NORMAL ||
                    reqStatus == RDMA_REQ_ST_DUP    ||
                    reqStatus == RDMA_REQ_ST_RMT_OP,
                    "reqStatus assertion @ mkReqHandleRQ",
                    $format(
                        "reqStatus=", fshow(reqStatus),
                        " must be normal or duplicate when isFirstOrOnlyRespPkt=",
                        fshow(respPktHeaderInfo.isFirstOrOnlyRespPkt),
                        ", bth.psn=%h and respPSN=%h", bth.psn, respPSN
                    )
                );

                if (maybeMiddleOrLastHeader matches tagged Valid .middleOrLastHeader) begin
                    respHeaderOutQ.enq(middleOrLastHeader);
                    psnRespOutQ.enq(respPSN);
                    // $display(
                    //     "time=%0t: generate middle or last response header", $time,
                    //     ", respPSN=%h", respPSN,
                    //     ", reqStatus=", fshow(reqStatus),
                    //     ", middleOrLastHeader=", fshow(middleOrLastHeader)
                    // );
                end
            end
        end

        workCompReqQ.enq(tuple6(
            pktMetaData, reqStatus, permCheckReq, reqPktInfo, respPktGenInfo, respPktHeaderInfo
        ));
        // $display(
        //     "time=%0t: 32st stage genRespPkt", $time,
        //     ", bth.opcode=", fshow(bth.opcode),
        //     ", bth.psn=%h", bth.psn,
        //     ", bth.ackReq=", fshow(bth.ackReq),
        //     ", respPSN=%h", respPSN,
        //     ", isOnlyRespPkt=", fshow(reqPktInfo.isOnlyRespPkt),
        //     ", shouldGenResp=", fshow(respPktGenInfo.shouldGenResp),
        //     ", hasReqStatusErr=", fshow(hasReqStatusErr),
        //     ", hasDmaReadRespErr=", fshow(hasDmaReadRespErr),
        //     ", hasErrRespGen=", fshow(hasErrRespGen),
        //     ", reqStatus=", fshow(reqStatus)
        // );
    endrule

    // This rule still runs at retry or error state
    rule genWorkCompRQ if (cntrlStatus.comm.isNonErr || cntrlStatus.comm.isERR);
        let {
            pktMetaData, reqStatus, permCheckReq, reqPktInfo, respPktGenInfo, respPktHeaderInfo
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
        let isZeroDmaLen = permCheckReq.isZeroDmaLen;

        let hasErrRespGen = respPktGenInfo.hasErrRespGen;
        let isFirstOrOnlyRespPkt = respPktHeaderInfo.isFirstOrOnlyRespPkt;
        let respPSN = respPktHeaderInfo.psn;

        if (reqStatus == RDMA_REQ_ST_NORMAL && !hasErrRespGen) begin
            if ((isReadReq && isFirstOrOnlyRespPkt) || isAtomicReq) begin
                immAssert(
                    respPSN == bth.psn,
                    "respPSN assertion @ mkReqHandleRQ",
                    $format(
                        "respPSN=%h should == bth.psn=%h", respPSN, bth.psn,
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
                rrID        : permCheckReq.wrID,
                len         : permCheckReq.totalLen,
                // sqpn        : cntrlStatus.comm.getSQPN,
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
        //     "time=%0t: 33nd stage genWorkCompRQ", $time,
        //     ", rr.id=", fshow(permCheckReq.wrID),
        //     ", bth.opcode=", fshow(bth.opcode),
        //     ", bth.psn=%h", bth.psn,
        //     ", bth.ackReq=", fshow(bth.ackReq),
        //     ", respPSN=%h", respPSN,
        //     ", immDt=%h, ieth=%h", immDt, ieth,
        //     ", hasImmDt=", fshow(hasImmDt),
        //     ", hasIETH=", fshow(hasIETH),
        //     ", reqStatus=", fshow(reqStatus)
        // );
    endrule

    (* fire_when_enabled *)
    rule errFlushRecvReq if (
        // inErrorState && recvReqBuf.notEmpty && !pktMetaDataPipeIn.notEmpty
        inErrorState && !pktMetaDataPipeIn.notEmpty
    );
        // TODO: generate WC for flushed RR
        let recvReq = recvReqBuf.first;
        // recvReqBuf.deq;
        // let maybeRecvReq = tagged Valid recvReq;

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
        let maybeTrans  = qpType2TransType(cntrlStatus.getTypeQP);

        let bth = BTH {
            trans    : unwrapMaybe(maybeTrans),
            opcode   : SEND_ONLY,
            solicited: False,
            migReq   : unpack(0),
            padCnt   : 0,
            tver     : unpack(0),
            pkey     : cntrlStatus.comm.getPKEY,
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
            epoch           : getEpoch,
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

        let curEPSN = contextRQ.getEPSN;
        supportedReqOpCodeCheckQ.enq(tuple4(
            pktMetaData, reqStatus, reqPktInfo, curEPSN
        ));
        // $display(
        //     "time=%0t: 1st error flush RR stage", $time,
        //     ", bth.opcode=", fshow(bth.opcode),
        //     ", bth.psn=%h", bth.psn,
        //     ", bth.ackReq=", fshow(bth.ackReq),
        //     ", reqStatus=", fshow(reqStatus)
        // );
    endrule

    (* fire_when_enabled *)
    rule errFlushIncomingReq if (
        inErrorState && pktMetaDataPipeIn.notEmpty
        // inErrorState && !recvReqBuf.notEmpty && pktMetaDataPipeIn.notEmpty
    );
        let curPktMetaData = pktMetaDataPipeIn.first;
        pktMetaDataPipeIn.deq;

        let maybeRecvReq  = tagged Invalid;
        let curRdmaHeader = curPktMetaData.pktHeader;
        let bth           = extractBTH(curRdmaHeader.headerData);
        let reqStatus     = RDMA_REQ_ST_DISCARD;

        let reqPktInfo = RdmaReqPktInfo {
            bth             : bth,
            epoch           : getEpoch,
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
        // $display(
        //     "time=%0t: 1st error flush incoming request stage", $time,
        //     ", bth.opcode=", fshow(bth.opcode),
        //     ", bth.psn=%h", bth.psn,
        //     ", dqpn=%h", cntrlStatus.comm.getSQPN,
        //     ", bth.ackReq=", fshow(bth.ackReq),
        //     ", reqStatus=", fshow(reqStatus)
        // );
    endrule

    (* conflict_free = "retryStageRnrRetryFlush, \
                        retryStageRnrWait, \
                        retryStart, \
                        retryDone, \
                        retryFlush" *)
    (* no_implicit_conditions, fire_when_enabled *)
    rule retryStageRnrRetryFlush if (
        cntrlStatus.comm.isNonErr && !hasErrHappened && retryStateReg == RQ_RNR_RETRY_FLUSH
    );
        retryStateReg <= RQ_RNR_WAIT;
        rnrWaitCntReg <= fromInteger(getRnrTimeOutValue(minRnrTimerReg));
        isRnrWaitCntZeroReg <= False;
    endrule

    (* no_implicit_conditions, fire_when_enabled *)
    rule retryStageRnrWait if (
        cntrlStatus.comm.isNonErr && !hasErrHappened && retryStateReg == RQ_RNR_WAIT
    );
        if (isRnrWaitCntZeroReg) begin
            retryStateReg <= RQ_RNR_WAIT_DONE;
        end
        else begin
            rnrWaitCntReg <= rnrWaitCntReg - 1;
            isRnrWaitCntZeroReg <= isOne(rnrWaitCntReg);
        end
    endrule

    (* no_implicit_conditions, fire_when_enabled *)
    rule retryStart if (
        retryStartReg[1] matches tagged Valid .retryStartState &&&
        cntrlStatus.comm.isNonErr &&& retryStateReg == RQ_NOT_RETRY &&& !hasErrHappened
    );
        retryStateReg    <= retryStartState;
        retryStartReg[1] <= tagged Invalid;
    endrule

    (* no_implicit_conditions, fire_when_enabled *)
    rule retryDone if (
        cntrlStatus.comm.isNonErr && !hasErrHappened && preStageStateReg == RQ_PRE_CALC_STAGE &&
        (retryStateReg == RQ_RNR_WAIT_DONE || retryStateReg == RQ_SEQ_RETRY_FLUSH)
    );
        let reqPktInfo = preStageReqPktInfoReg;
        let epoch      = reqPktInfo.epoch;
        let isExpected = reqPktInfo.isExpected;

        let retryFlushDone = isExpected && epoch == getEpoch;

        // If retry done, then next stage is RQ_PRE_STAGE_DONE aka RQ pipeline 1st stage
        if (retryFlushDone) begin
            retryStateReg    <= RQ_NOT_RETRY;
        end
        // $display(
        //     "time=%0t: retry done", $time,
        //     ", retryFlushDone=", fshow(retryFlushDone),
        //     ", retryStateReg=", fshow(retryStateReg)
        // );
    endrule

    (* fire_when_enabled *)
    rule retryFlush if (
        cntrlStatus.comm.isNonErr && preStageStateReg == RQ_PRE_STAGE_DONE &&
        retryStateReg != RQ_NOT_RETRY && !hasErrHappened
    );
        let reqPktInfo  = preStageReqPktInfoReg;
        let pktMetaData = preStagePktMetaDataReg;
        let bth         = reqPktInfo.bth;

        // $display(
        //     "time=%0t:", $time,
        //     // " isRetryFlushDoneReg=", fshow(isRetryFlushDoneReg),
        //     ", isRetryFlushDone=", fshow(isRetryFlushDone),
        //     ", bth.psn=%h", bth.psn,
        //     ", ePSN=%h", contextRQ.getEPSN
        // );

        preStageStateReg <= RQ_PRE_BUILD_STAGE;
        pktMetaDataPipeIn.deq;

        let reqStatus = RDMA_REQ_ST_DISCARD;
        let curEPSN = contextRQ.getEPSN; // bth.psn;
        supportedReqOpCodeCheckQ.enq(tuple4(
            pktMetaData, reqStatus, reqPktInfo, curEPSN
        ));
        // $display(
        //     "time=%0t: 1st retry flush stage", $time,
        //     ", bth.opcode=", fshow(bth.opcode),
        //     ", bth.psn=%h", bth.psn,
        //     ", bth.ackReq=", fshow(bth.ackReq),
        //     ", reqStatus=", fshow(reqStatus)
        // );
    endrule

    interface rdmaRespDataStreamPipeOut = rdmaRespPipeOut;
    interface workCompGenReqPipeOut     = toPipeOut(workCompGenReqOutQ);
    method Bool respHeaderOutNotEmpty() = psnRespOutQ.notEmpty;
endmodule
