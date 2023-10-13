import ClientServer :: *;
import FIFOF :: *;
import GetPut :: *;
import PAClib :: *;

import Controller :: *;
import DataTypes :: *;
import Headers :: *;
import PrimUtils :: *;
import RetryHandleSQ :: *;
import SpecialFIFOF :: *;
import Utils :: *;

function Bool rdmaRespMatchWorkReq(RdmaOpCode opcode, WorkReqOpCode wrOpCode);
    return case (opcode)
        RDMA_READ_RESPONSE_FIRST ,
        RDMA_READ_RESPONSE_MIDDLE,
        RDMA_READ_RESPONSE_LAST  ,
        RDMA_READ_RESPONSE_ONLY  : (wrOpCode == IBV_WR_RDMA_READ);
        ATOMIC_ACKNOWLEDGE       : (wrOpCode == IBV_WR_ATOMIC_CMP_AND_SWP || wrOpCode == IBV_WR_ATOMIC_FETCH_AND_ADD);
        ACKNOWLEDGE              : True;
        default                  : False;
    endcase;
endfunction

typedef enum {
    SQ_HANDLE_RESP_HEADER,
    SQ_RETRY_FLUSH,
    SQ_ERROR_FLUSH
} RespHandleState deriving(Bits, Eq, FShow);

typedef enum {
    WR_ACK_EXPLICIT_WHOLE_NORMAL,
    WR_ACK_EXPLICIT_WHOLE_RETRY,
    WR_ACK_EXPLICIT_WHOLE_ERROR,
    WR_ACK_EXPLICIT_PARTIAL_NORMAL,
    WR_ACK_EXPLICIT_PARTIAL_RETRY,
    WR_ACK_EXPLICIT_PARTIAL_ERROR,
    WR_ACK_COALESCE_NORMAL,
    WR_ACK_COALESCE_RETRY,
    WR_ACK_DUPLICATE,
    WR_ACK_GHOST,
    WR_ACK_ILLEGAL,
    // WR_ACK_RETRY_FLUSH,
    WR_ACK_DISCARD,
    WR_ACK_ERR_FLUSH_WR,
    WR_ACK_TIMOUT_ERR,
    WR_ACK_UNKNOWN
} WorkReqAckType deriving(Bits, Eq, FShow);

typedef enum {
    SQ_ACT_BAD_RESP,
    SQ_ACT_COALESCE_RESP,
    SQ_ACT_ERROR_RESP,
    SQ_ACT_EXPLICIT_NORMAL_RESP,
    SQ_ACT_DISCARD_RESP,
    SQ_ACT_DUPLICATE_RESP,
    // SQ_ACT_GHOST_RESP,
    SQ_ACT_ILLEGAL_RESP,
    SQ_ACT_FLUSH_WR,
    SQ_ACT_TIMEOUT_ERR,
    SQ_ACT_EXPLICIT_RETRY,
    SQ_ACT_IMPLICIT_RETRY,
    SQ_ACT_LOCAL_ACC_ERR,
    SQ_ACT_LOCAL_LEN_ERR,
    SQ_ACT_UNKNOWN
} RespActionSQ deriving(Bits, Eq, FShow);

function RespActionSQ pktStatus2RespActionSQ(
    PktVeriStatus pktStatus
);
    return case (pktStatus)
        PKT_ST_VALID  : SQ_ACT_EXPLICIT_NORMAL_RESP;
        PKT_ST_LEN_ERR: SQ_ACT_ILLEGAL_RESP;
        // PKT_ST_DISCARD: SQ_ACT_DISCARD_RESP;
        default       : SQ_ACT_UNKNOWN;
    endcase;
endfunction

typedef enum {
    SQ_PRE_BUILD_STAGE,
    SQ_PRE_PROC_STAGE,
    SQ_PRE_STAGE_DONE
} PreStageStateSQ deriving(Bits, Eq, FShow);

typedef struct {
    BTH bth;
    AETH aeth;
    // Bool isZeroPayloadLen;
    Bool isFirstOrOnlyPkt;
    Bool isLastOrOnlyPkt;
    Bool isReadResp;
    Bool isAtomicResp;
    Bool hasLocalErr;
    Bool shouldDiscard;
    Bool genWorkComp;
} RespPktInfo deriving(Bits);

typedef struct {
    Bool isReadAtomicWR;
    Bool isMatchEndPSN;
    Bool isCoalesceResp;
    Bool isMatchStartPSN;
    Bool isPartialResp;
} RespAndWorkReqRelation deriving(Bits);

typedef struct {
    Bool   enoughDmaSpace;
    Bool   isLastPayloadLenZero;
    ADDR   nextReadRespWriteAddr;
    Length remainingReadRespLen;
} RespLenCheckResult deriving(Bits);

interface RespHandleSQ;
    // interface PipeOut#(PayloadConReq) payloadConReqPipeOut;
    interface PipeOut#(WorkCompGenReqSQ) workCompGenReqPipeOut;
endinterface

module mkRespHandleSQ#(
    ContextSQ contextSQ,
    RetryHandleSQ retryHandler,
    PermCheckSrv permCheckSrv,
    PipeOut#(PendingWorkReq) pendingWorkReqPipeIn,
    PipeOut#(RdmaPktMetaData) pktMetaDataPipeIn,
    Put#(PayloadConReq) payloadConReqPort
)(RespHandleSQ);
    // Output FIFO for PipeOut
    // FIFOF#(PayloadConReq)     payloadConReqOutQ <- mkFIFOF;
    FIFOF#(WorkCompGenReqSQ) workCompGenReqOutQ <- mkFIFOF;

    // Pipeline FiFO
    // TODO: add more buffer after 0th stage
    FIFOF#(Tuple6#(PendingWorkReq, RdmaPktMetaData, RespPktInfo, ResetRetryCntAndTimeOutReq, WorkCompReqType, WorkReqAckType)) incomingRespQ <- mkFIFOF;
    FIFOF#(Tuple6#(PendingWorkReq, RdmaPktMetaData, RespPktInfo, RespActionSQ, WorkCompReqType, WorkReqAckType)) pendingRespQ <- mkFIFOF;
    FIFOF#(Tuple5#(PendingWorkReq, RdmaPktMetaData, RespPktInfo, RespActionSQ, WorkCompReqType)) pendingPermQueryQ <- mkFIFOF;
    FIFOF#(Tuple6#(PendingWorkReq, RdmaPktMetaData, RespPktInfo, RespActionSQ, WorkCompReqType, Bool)) pendingRetryCheckQ <- mkFIFOF;
    FIFOF#(Tuple7#(PendingWorkReq, RdmaPktMetaData, RespPktInfo, RespActionSQ, Maybe#(WorkCompStatus), WorkCompReqType, Bool)) pendingPermCheckQ <- mkFIFOF;
    FIFOF#(Tuple6#(PendingWorkReq, RdmaPktMetaData, RespPktInfo, RespActionSQ, Maybe#(WorkCompStatus), WorkCompReqType)) pendingAddrCalcQ <- mkFIFOF;
    FIFOF#(Tuple7#(PendingWorkReq, RdmaPktMetaData, RespPktInfo, RespActionSQ, Maybe#(WorkCompStatus), WorkCompReqType, ADDR)) pendingLenCalcQ <- mkFIFOF;
    FIFOF#(Tuple8#(PendingWorkReq, RdmaPktMetaData, RespPktInfo, RespActionSQ, Maybe#(WorkCompStatus), WorkCompReqType, RespLenCheckResult, Length)) pendingSpaceCalcQ <- mkFIFOF;
    FIFOF#(Tuple7#(PendingWorkReq, RdmaPktMetaData, RespPktInfo, RespActionSQ, Maybe#(WorkCompStatus), WorkCompReqType, RespLenCheckResult)) pendingLenCheckQ <- mkFIFOF;
    FIFOF#(Tuple7#(PendingWorkReq, RdmaPktMetaData, RespPktInfo, RespActionSQ, Maybe#(WorkCompStatus), WorkCompReqType, ADDR)) pendingDmaReqQ <- mkFIFOF;
    FIFOF#(Tuple2#(RespPktInfo, WorkCompGenReqSQ)) pendingWorkCompQ <- mkFIFOF;

    Reg#(RespAndWorkReqRelation) preStageRespAndWorkReqRelationReg <- mkRegU;
    Reg#(RdmaPktMetaData)      preStagePktMetaDataReg <- mkRegU;
    Reg#(RespPktInfo)           preStageReqPktInfoReg <- mkRegU;
    Reg#(RdmaRespType)            preStageRespTypeReg <- mkRegU;
    Reg#(Bool)              preStageDeqPktMetaDataReg <- mkRegU;
    Reg#(Bool)           preStageDeqPendingWorkReqReg <- mkRegU;
    Reg#(WorkReqAckType)    preStageWorkReqAckTypeReg <- mkRegU;
    Reg#(WorkCompReqType)  preStageWorkCompReqTypeReg <- mkRegU;
    Reg#(ResetRetryCntAndTimeOutReq) retryResetReqReg <- mkRegU;
    Reg#(PreStageStateSQ)            preStageStateReg <- mkReg(SQ_PRE_BUILD_STAGE);

    Reg#(RdmaOpCode)    preRdmaOpCodeReg <- mkReg(ACKNOWLEDGE);
    Reg#(Length) remainingReadRespLenReg <- mkRegU;
    Reg#(ADDR)  nextReadRespWriteAddrReg <- mkRegU;
    Reg#(PktNum)       readRespPktNumReg <- mkRegU; // TODO: remove it

    Reg#(Bool)    recvErrRespReg <- mkReg(False);
    Reg#(Bool)  recvRetryRespReg <- mkReg(False);
    Reg#(Bool) hasInternalErrReg[2] <- mkCReg(2, False);
    Reg#(Bool)  hasTimeOutErrReg[2] <- mkCReg(2, False);

    Reg#(Bool) errOccurredReg <- mkReg(False);
    Reg#(Bool)  retryFlushReg <- mkReg(False);

    let cntrlStatus = contextSQ.statusSQ;

    (* no_implicit_conditions, fire_when_enabled *)
    rule resetAndClear if (cntrlStatus.comm.isReset);
        // payloadConReqOutQ.clear;
        workCompGenReqOutQ.clear;

        incomingRespQ.clear;
        pendingRespQ.clear;
        pendingPermQueryQ.clear;
        pendingRetryCheckQ.clear;
        pendingPermCheckQ.clear;
        pendingAddrCalcQ.clear;
        pendingLenCalcQ.clear;
        pendingSpaceCalcQ.clear;
        pendingLenCheckQ.clear;
        pendingDmaReqQ.clear;
        pendingWorkCompQ.clear;

        preStageStateReg     <= SQ_PRE_BUILD_STAGE;
        preRdmaOpCodeReg     <= ACKNOWLEDGE;
        recvErrRespReg       <= False;
        recvRetryRespReg     <= False;
        hasInternalErrReg[0] <= False;
        hasTimeOutErrReg[0]  <= False;
        errOccurredReg       <= False;
        retryFlushReg        <= False;

        // $display("time=%0t: reset and clear mkRespHandleSQ", $time);
    endrule

    let inNormalState = !retryFlushReg && !errOccurredReg && !recvErrRespReg;
    let inRetryState = retryFlushReg && !errOccurredReg && !recvErrRespReg;
    // Error state must include controller error state
    let inErrState = errOccurredReg || cntrlStatus.comm.isERR;
    let inErrStateAlt = (cntrlStatus.comm.isRTS && (recvErrRespReg || errOccurredReg)) || cntrlStatus.comm.isERR;

    // TODO: check preBuildRespInfo having negative impact on throughput,
    // since preBuildRespInfo is not pipelined.
    rule preBuildRespInfo if (
        cntrlStatus.comm.isRTS && pendingWorkReqPipeIn.notEmpty &&
        preStageStateReg == SQ_PRE_BUILD_STAGE && inNormalState
    ); // This rule will not run at retry or error state
        let curPktMetaData = pktMetaDataPipeIn.first;
        let curRdmaHeader  = curPktMetaData.pktHeader;

        let bth  = extractBTH(curRdmaHeader.headerData);
        let aeth = extractAETH(curRdmaHeader.headerData);
        immAssert(
            isRdmaRespOpCode(bth.opcode),
            "isRdmaRespOpCode assertion @ mkRespHandleSQ",
            $format(
                "bth.opcode=", fshow(bth.opcode), " should be RDMA response"
            )
        );
        // $display(
        //     "time=%0t: curPendingWR=", $time, fshow(curPendingWR),
        //     ", curPktMetaData=", fshow(curPktMetaData),
        //     ", bth=", fshow(bth)
        // );

        let rdmaRespType = getRdmaRespType(bth.opcode, aeth);
        immAssert(
            rdmaRespType != RDMA_RESP_UNKNOWN,
            "rdmaRespType assertion @ handleRetryResp() in mkRespHandleSQ",
            $format("rdmaRespType=", fshow(rdmaRespType), " should not be unknown")
        );

        let respPktInfo = RespPktInfo {
            bth             : bth,
            aeth            : aeth,
            // isZeroPayloadLen: isZero(curPktMetaData.pktPayloadLen),
            isFirstOrOnlyPkt: isFirstOrOnlyRdmaOpCode(bth.opcode),
            isLastOrOnlyPkt : isLastOrOnlyRdmaOpCode(bth.opcode),
            isReadResp      : isReadRespRdmaOpCode(bth.opcode),
            isAtomicResp    : isAtomicRespRdmaOpCode(bth.opcode),
            hasLocalErr     : False,
            shouldDiscard   : False,
            genWorkComp     : False // Altered in later stage
        };

        let curPendingWR = pendingWorkReqPipeIn.first;
        let isReadAtomicWR = isReadOrAtomicWorkReq(curPendingWR.wr.opcode);

        let nextPSN  = contextSQ.getNPSN;
        let startPSN = unwrapMaybe(curPendingWR.startPSN);
        let endPSN   = unwrapMaybe(curPendingWR.endPSN);
        let pktNum   = unwrapMaybe(curPendingWR.pktNum);
        immAssert(
            isValid(curPendingWR.startPSN) &&
            isValid(curPendingWR.endPSN) &&
            isValid(curPendingWR.pktNum) &&
            isValid(curPendingWR.isOnlyReqPkt),
            "curPendingWR assertion @ mkRespHandleSQ",
            $format(
                "curPendingWR should have valid PSN and PktNum, curPendingWR=",
                fshow(curPendingWR)
            )
        );

        let isIllegalResp   = !curPktMetaData.pktValid;
        let isMatchEndPSN   = bth.psn == endPSN;
        let isCoalesceResp  = psnInRangeExclusive(bth.psn, endPSN, nextPSN);
        let isMatchStartPSN = bth.psn == startPSN;
        let isPartialResp   = psnInRangeExclusive(bth.psn, startPSN, endPSN);

        let respAndWorkReqRelation = RespAndWorkReqRelation {
            isReadAtomicWR : isReadAtomicWR,
            isMatchEndPSN  : isMatchEndPSN,
            isCoalesceResp : isCoalesceResp,
            isMatchStartPSN: isMatchStartPSN,
            isPartialResp  : isPartialResp
        };

        preStageRespAndWorkReqRelationReg <= respAndWorkReqRelation;
        preStageReqPktInfoReg  <= respPktInfo;
        preStageRespTypeReg    <= rdmaRespType;
        preStagePktMetaDataReg <= curPktMetaData;
        preStageStateReg       <= SQ_PRE_PROC_STAGE;
        // $display(
        //     "time=%0t: 0th-1 pre-stage,", $time,
        //     " preStageStateReg =", fshow(preStageStateReg),
        //     // " enablePreCalcInfoReg=", fshow(enablePreCalcInfoReg),
        //     ", bth.psn=%h, nextPSN=%h", bth.psn, nextPSN,
        //     ", bth.opcode=", fshow(bth.opcode),
        //     ", aeth.code=", fshow(aeth.code),
        //     // ", curPendingWR=", fshow(curPendingWR),
        //     ", curPendingWR.wr.opcode=", fshow(curPendingWR.wr.opcode),
        //     ", isIllegalResp=", fshow(isIllegalResp),
        //     ", isMatchEndPSN=", fshow(isMatchEndPSN),
        //     ", isCoalesceResp=", fshow(isCoalesceResp),
        //     ", isMatchStartPSN=", fshow(isMatchStartPSN),
        //     ", isPartialResp=", fshow(isPartialResp),
        //     ", rdmaRespType=", fshow(rdmaRespType),
        //     // ", retryReason=", fshow(retryReason),
        //     // ", wrAckType=", fshow(wrAckType),
        //     // ", wcReqType=", fshow(wcReqType),
        //     ", wr.id=%h", curPendingWR.wr.id
        // );
    endrule

    rule preProcRespInfo if (
        cntrlStatus.comm.isRTS && pendingWorkReqPipeIn.notEmpty &&
        preStageStateReg == SQ_PRE_PROC_STAGE && inNormalState
    ); // This rule will not run at retry or error state
        let respAndWorkReqRelation = preStageRespAndWorkReqRelationReg;
        let respPktInfo  = preStageReqPktInfoReg;
        let rdmaRespType = preStageRespTypeReg;

        let curPktMetaData = preStagePktMetaDataReg; // pktMetaDataPipeIn.first;
        let curPendingWR   = pendingWorkReqPipeIn.first;

        let deqPktMetaData    = True;
        let deqPendingWorkReq = False;

        let wrAckType = WR_ACK_UNKNOWN;
        let wcReqType = WC_REQ_TYPE_UNKNOWN;

        let isIllegalResp   = !curPktMetaData.pktValid;
        let isMatchEndPSN   = respAndWorkReqRelation.isMatchEndPSN;
        let isCoalesceResp  = respAndWorkReqRelation.isCoalesceResp;
        let isMatchStartPSN = respAndWorkReqRelation.isMatchStartPSN;
        let isPartialResp   = respAndWorkReqRelation.isPartialResp;
        let isReadAtomicWR  = respAndWorkReqRelation.isReadAtomicWR;

        if (isIllegalResp) begin
            wrAckType = WR_ACK_ILLEGAL;
            wcReqType = WC_REQ_TYPE_FULL_ACK;
        end
        else begin
            case ({
                pack(isMatchEndPSN), pack(isCoalesceResp),
                pack(isMatchStartPSN), pack(isPartialResp)
            })
                4'b1000, 4'b1010: begin // Response to whole WR, multi-or-single packets
                    case (rdmaRespType)
                        RDMA_RESP_RETRY: begin
                            wrAckType = WR_ACK_EXPLICIT_WHOLE_RETRY;
                            wcReqType = WC_REQ_TYPE_NO_WC;
                        end
                        RDMA_RESP_ERROR: begin
                            wrAckType         = WR_ACK_EXPLICIT_WHOLE_ERROR;
                            wcReqType         = WC_REQ_TYPE_FULL_ACK;
                            deqPendingWorkReq = True;
                        end
                        RDMA_RESP_NORMAL: begin
                            wrAckType = WR_ACK_EXPLICIT_WHOLE_NORMAL;
                            wcReqType = WC_REQ_TYPE_FULL_ACK;
                            deqPendingWorkReq = True;
                        end
                        default: begin
                            immFail(
                                "unreachible case @ mkRespHandleSQ",
                                $format("rdmaRespType=", fshow(rdmaRespType))
                            );
                        end
                    endcase
                end
                4'b0100: begin // Coalesce ACK
                    deqPktMetaData = False;

                    if (isReadAtomicWR) begin // Implicit retry
                        wrAckType = WR_ACK_COALESCE_RETRY;
                        wcReqType = WC_REQ_TYPE_NO_WC;
                    end
                    else begin
                        wrAckType = WR_ACK_COALESCE_NORMAL;
                        wcReqType = WC_REQ_TYPE_FULL_ACK;
                        deqPendingWorkReq = True;
                    end
                end
                4'b0010, 4'b0001: begin // Partial ACK
                    case (rdmaRespType)
                        RDMA_RESP_RETRY: begin
                            wrAckType = WR_ACK_EXPLICIT_PARTIAL_RETRY;
                            wcReqType = WC_REQ_TYPE_NO_WC;
                        end
                        RDMA_RESP_ERROR: begin
                            wrAckType         = WR_ACK_EXPLICIT_PARTIAL_ERROR;
                            // Explicit error responses will dequeue whole WR,
                            // no matter error reponses are full or partial ACK.
                            wcReqType         = WC_REQ_TYPE_FULL_ACK;
                            deqPendingWorkReq = True;
                        end
                        RDMA_RESP_NORMAL: begin
                            wrAckType = WR_ACK_EXPLICIT_PARTIAL_NORMAL;
                            wcReqType = WC_REQ_TYPE_PARTIAL_ACK;
                        end
                        default: begin
                            immFail(
                                "unreachible case @ mkRespHandleSQ",
                                $format("rdmaRespType=", fshow(rdmaRespType))
                            );
                        end
                    endcase
                end
                default: begin // Duplicated responses
                    wrAckType = WR_ACK_DUPLICATE;
                    wcReqType = WC_REQ_TYPE_NO_WC;
                end
            endcase
        end

        immAssert(
            wrAckType != WR_ACK_UNKNOWN && wcReqType != WC_REQ_TYPE_UNKNOWN,
            "wrAckType and wcReqType assertion @ mkRespHandleSQ",
            $format(
                "wrAckType=", fshow(wrAckType),
                ", and wcReqType=", fshow(wcReqType),
                " should not be unknown"
            )
        );
        immAssert(
            deqPktMetaData || deqPendingWorkReq,
            "deqPktMetaData and deqPendingWorkReq assertion @ mkRespHandleSQ",
            $format(
                "deqPktMetaData=", fshow(deqPktMetaData),
                ", and deqPendingWorkReq=", fshow(deqPendingWorkReq),
                " should have at least one be true"
            )
        );

        retryResetReqReg <= deqPendingWorkReq ?
            RETRY_HANDLER_RESET_RETRY_CNT_AND_TIMEOUT :
            RETRY_HANDLER_RESET_TIMEOUT;

        preStageStateReg             <= SQ_PRE_STAGE_DONE;
        preStageDeqPktMetaDataReg    <= deqPktMetaData;
        preStageDeqPendingWorkReqReg <= deqPendingWorkReq;
        preStageWorkReqAckTypeReg    <= wrAckType;
        preStageWorkCompReqTypeReg   <= wcReqType;
        // $display(
        //     "time=%0t: 0th-2 pre-stage,", $time,
        //     " preStageStateReg=", fshow(preStageStateReg),
        //     // " enablePreCalcInfoReg=", fshow(enablePreCalcInfoReg),
        //     ", bth.psn=%h", respPktInfo.bth.psn,
        //     ", bth.opcode=", fshow(respPktInfo.bth.opcode),
        //     ", aeth.code=", fshow(respPktInfo.aeth.code),
        //     // ", curPendingWR=", fshow(curPendingWR),
        //     ", curPendingWR.wr.opcode=", fshow(curPendingWR.wr.opcode),
        //     ", isIllegalResp=", fshow(isIllegalResp),
        //     ", isMatchEndPSN=", fshow(isMatchEndPSN),
        //     ", isCoalesceResp=", fshow(isCoalesceResp),
        //     ", isMatchStartPSN=", fshow(isMatchStartPSN),
        //     ", isPartialResp=", fshow(isPartialResp),
        //     ", rdmaRespType=", fshow(rdmaRespType),
        //     // ", retryReason=", fshow(retryReason),
        //     ", wrAckType=", fshow(wrAckType),
        //     // ", respAction=", fshow(respAction),
        //     ", wcReqType=", fshow(wcReqType),
        //     ", wr.id=%h", curPendingWR.wr.id
        // );
    endrule

                        // errFlushPktMetaDataAndPayload, \
    // TODO: add conflict_free attribute to canonicalize
    (* conflict_free = "preBuildRespInfo, \
                        preProcRespInfo, \
                        deqPktMetaDataOrWorkReq, \
                        recvRespHeader, \
                        handleRespByType, \
                        queryPerm4NormalReadAtomicResp, \
                        checkRetryErr, \
                        checkPerm4NormalReadAtomicResp, \
                        calcReadRespAddr, \
                        calcReadRespLen, \
                        calcEnoughDmaSpace, \
                        checkReadRespLen, \
                        issueDmaReq, \
                        genWorkCompSQ, \
                        discardGhostResp, \
                        checkTimeOutErr, \
                        errFlushWorkReq, \
                        errFlushIncomingResp, \
                        (retryFlushDone, retryFlushPktMetaDataAndPayload)" *)
    rule deqPktMetaDataOrWorkReq if (
        cntrlStatus.comm.isRTS && pendingWorkReqPipeIn.notEmpty &&
        preStageStateReg == SQ_PRE_STAGE_DONE && inNormalState
    ); // This rule will not run at retry or error state
        let respPktInfo  = preStageReqPktInfoReg;
        let rdmaRespType = preStageRespTypeReg;

        let curPendingWR   = pendingWorkReqPipeIn.first;
        let curPktMetaData = preStagePktMetaDataReg;

        let deqPktMetaData    = preStageDeqPktMetaDataReg;
        let deqPendingWorkReq = preStageDeqPendingWorkReqReg;

        let wrAckType = preStageWorkReqAckTypeReg;
        let wcReqType = preStageWorkCompReqTypeReg;

        if (deqPktMetaData) begin
            pktMetaDataPipeIn.deq;
        end

        // Do not dequeue when triggering retry in the 2nd stage
        if (deqPendingWorkReq) begin
            pendingWorkReqPipeIn.deq;
            // $display(
            //     "time=%0t:", $time, " dequeue wr.id=%h", curPendingWR.wr.id
            // );
        end

        if (
            wrAckType != WR_ACK_DUPLICATE && !recvRetryRespReg && !recvErrRespReg &&
            (
                (rdmaRespType == RDMA_RESP_NORMAL && respPktInfo.isLastOrOnlyPkt) ||
                rdmaRespType == RDMA_RESP_ERROR
            )
        ) begin
            immAssert(
                deqPendingWorkReq,
                "deqPendingWorkReq assertion @ mkRespHandleSQ",
                $format(
                    "deqPendingWorkReq=", fshow(deqPendingWorkReq),
                    " should be true when rdmaRespType=", fshow(rdmaRespType),
                    ", recvRetryRespReg=", fshow(recvRetryRespReg),
                    ", recvErrRespReg=", fshow(recvErrRespReg),
                    ", and bth.psn=%h", respPktInfo.bth.psn,
                    ", bth.opcode=", fshow(respPktInfo.bth.opcode),
                    " is the last or only response, AETH=", fshow(respPktInfo.aeth),
                    ", pending WR=", fshow(curPendingWR)
                )
            );
        end

        preStageStateReg <= SQ_PRE_BUILD_STAGE;
        incomingRespQ.enq(tuple6(
            curPendingWR, curPktMetaData, respPktInfo, retryResetReqReg, wcReqType, wrAckType
        ));
        // $display(
        //     "time=%0t: 1st stage deqPktMetaDataOrWorkReq", $time,
        //     ", qpn=%h", contextSQ.statusSQ.comm.getSQPN,
        //     ", preStageStateReg=", fshow(preStageStateReg),
        //     ", bth.psn=%h", respPktInfo.bth.psn,
        //     ", bth.opcode=", fshow(respPktInfo.bth.opcode),
        //     ", aeth.code=", fshow(respPktInfo.aeth.code),
        //     ", deqPendingWorkReq=", fshow(deqPendingWorkReq),
        //     ", wr.id=%h", curPendingWR.wr.id,
        //     ", wr.opcode=", fshow(curPendingWR.wr.opcode),
        //     ", rdmaRespType=", fshow(rdmaRespType),
        //     ", wcReqType=", fshow(wcReqType)
        // );
    endrule

    rule recvRespHeader if (cntrlStatus.comm.isRTS || cntrlStatus.comm.isERR); // This rule still runs at retry or error state
        let {
            pendingWR, pktMetaData, respPktInfo, retryResetReq, wcReqType, wrAckType
        } = incomingRespQ.first;
        incomingRespQ.deq;

        if (cntrlStatus.comm.isStableRTS) begin
            // Only reset retry and timeout counter when isStableRTS
            retryHandler.resetRetryCntAndTimeOutBySQ(retryResetReq);
        end

        let respAction = SQ_ACT_UNKNOWN;
        case (wrAckType)
            WR_ACK_EXPLICIT_WHOLE_NORMAL, WR_ACK_EXPLICIT_PARTIAL_NORMAL: begin
                respAction = SQ_ACT_EXPLICIT_NORMAL_RESP;
            end
            WR_ACK_EXPLICIT_WHOLE_RETRY, WR_ACK_EXPLICIT_PARTIAL_RETRY: begin
                respAction = SQ_ACT_EXPLICIT_RETRY;
                recvRetryRespReg <= True;
                retryFlushReg    <= True;
            end
            WR_ACK_EXPLICIT_WHOLE_ERROR, WR_ACK_EXPLICIT_PARTIAL_ERROR: begin
                respAction = SQ_ACT_ERROR_RESP;
                recvErrRespReg <= True;
            end
            WR_ACK_COALESCE_NORMAL: begin
                respAction = SQ_ACT_COALESCE_RESP;
            end
            WR_ACK_COALESCE_RETRY: begin
                respAction = SQ_ACT_IMPLICIT_RETRY;
                recvRetryRespReg <= True;
                retryFlushReg    <= True;
            end
            WR_ACK_DUPLICATE: begin
                respAction = SQ_ACT_DUPLICATE_RESP;
            end
            WR_ACK_DISCARD,
            WR_ACK_GHOST  : begin
                respAction = SQ_ACT_DISCARD_RESP;
            end
            WR_ACK_ILLEGAL: begin
                respAction = pktStatus2RespActionSQ(pktMetaData.pktStatus);
                immAssert(
                    respAction != SQ_ACT_UNKNOWN,
                    "respAction assertion @ mkRespHandleSQ",
                    $format(
                        "respAction=", fshow(respAction),
                        " should not be unknown when pktStatus=",
                        fshow(pktMetaData.pktStatus)
                    )
                );

                recvErrRespReg <= True;
            end
            WR_ACK_ERR_FLUSH_WR: begin
                respAction = SQ_ACT_FLUSH_WR;
            end
            WR_ACK_TIMOUT_ERR: begin
                respAction = SQ_ACT_TIMEOUT_ERR;
            end
            default: begin
                immFail(
                    "unreachible case @ mkRespHandleSQ",
                    $format("wrAckType=", fshow(wrAckType))
                );
            end
        endcase

        if (inRetryState) begin
            immAssert(
                respAction == SQ_ACT_DISCARD_RESP,
                "respAction retry flush assertion @ mkRespHandleSQ",
                $format(
                    "respAction=", fshow(respAction),
                    " should be SQ_ACT_DISCARD_RESP when inRetryState=",
                    fshow(inRetryState)
                )
            );
        end
        // else if (inErrState) begin
        //     immAssert(
        //         respAction == SQ_ACT_DISCARD_RESP || respAction == SQ_ACT_FLUSH_WR,
        //         "respAction error flush assertion @ mkRespHandleSQ",
        //         $format(
        //             "respAction=", fshow(respAction),
        //             " should be SQ_ACT_FLUSH_WR or SQ_ACT_DISCARD_RESP when inErrState=",
        //             fshow(inErrState)
        //         )
        //     );
        // end
        else begin
            immAssert(
                respAction != SQ_ACT_UNKNOWN,
                "respAction assertion @ mkRespHandleSQ",
                $format("respAction=", fshow(respAction), " should not be unknown")
            );
        end

        pendingRespQ.enq(tuple6(
            pendingWR, pktMetaData, respPktInfo, respAction, wcReqType, wrAckType
        ));
        // $display(
        //     "time=%0t: 2nd stage,", $time,
        //     // " preStageStateReg=", fshow(preStageStateReg),
        //     ", bth.psn=%h", respPktInfo.bth.psn,
        //     ", bth.opcode=", fshow(respPktInfo.bth.opcode),
        //     ", aeth.code=", fshow(respPktInfo.aeth.code),
        //     ", WR opcode=", fshow(pendingWR.wr.opcode),
        //     // ", rdmaRespType=", fshow(rdmaRespType),
        //     ", respAction=", fshow(respAction),
        //     ", wcReqType=", fshow(wcReqType),
        //     ", wr.id=%h", pendingWR.wr.id
        // );
    endrule

    rule handleRespByType if (cntrlStatus.comm.isRTS || cntrlStatus.comm.isERR); // This rule still runs at retry or error state
        let {
            pendingWR, pktMetaData, respPktInfo, respAction, wcReqType, wrAckType
        } = pendingRespQ.first;
        pendingRespQ.deq;

        let bth              = respPktInfo.bth;
        let aeth             = respPktInfo.aeth;
        let isFirstOrOnlyPkt = respPktInfo.isFirstOrOnlyPkt;
        let isReadResp       = respPktInfo.isReadResp;
        let isAtomicResp     = respPktInfo.isAtomicResp;
        let isZeroPayloadLen = pktMetaData.isZeroPayloadLen;

        let respOpCodeSeqCheck = checkNormalRespOpCodeSeqSQ(preRdmaOpCodeReg, bth.opcode);
        let respMatchWorkReq   = rdmaRespMatchWorkReq(bth.opcode, pendingWR.wr.opcode);

        // let respAction = SQ_ACT_UNKNOWN;
        case (respAction)
            SQ_ACT_EXPLICIT_NORMAL_RESP: begin
                // Only update pre-opcode when normal response
                if (!inErrState) begin
                    preRdmaOpCodeReg <= bth.opcode;
                end

                if (!respMatchWorkReq || !respOpCodeSeqCheck) begin
                    respAction = SQ_ACT_BAD_RESP;
                    recvErrRespReg <= True;

                    respPktInfo.hasLocalErr = True;
                    if (wrAckType == WR_ACK_EXPLICIT_PARTIAL_NORMAL) begin
                        wcReqType = WC_REQ_TYPE_PARTIAL_ACK;
                    end
                    else begin
                        wcReqType = WC_REQ_TYPE_FULL_ACK;
                    end
                end
            end
            SQ_ACT_EXPLICIT_RETRY, SQ_ACT_IMPLICIT_RETRY: begin
                let retryReason = respAction == SQ_ACT_IMPLICIT_RETRY ?
                    RETRY_REASON_IMPLICIT : getRetryReasonFromAETH(aeth);
                let rnrTimer = (retryReason == RETRY_REASON_RNR) ?
                        (tagged Valid aeth.value) : (tagged Invalid);
                let retryReq = RetryReq {
                    wrID         : pendingWR.wr.id,
                    retryStartPSN: bth.psn,
                    retryReason  : retryReason,
                    retryRnrTimer: rnrTimer
                };
                retryHandler.srvPort.request.put(retryReq);
            end
            SQ_ACT_ERROR_RESP,
            SQ_ACT_COALESCE_RESP,
            SQ_ACT_DUPLICATE_RESP,
            SQ_ACT_DISCARD_RESP,
            SQ_ACT_ILLEGAL_RESP,
            SQ_ACT_FLUSH_WR,
            SQ_ACT_TIMEOUT_ERR: begin end
            default: begin
                immFail(
                    "unreachible case @ mkRespHandleSQ",
                    $format("respAction=", fshow(respAction))
                );
            end
        endcase

        immAssert(
            respAction != SQ_ACT_UNKNOWN,
            "respAction assertion @ mkRespHandleSQ",
            $format("respAction=", fshow(respAction), " should not be unknown")
        );
        pendingPermQueryQ.enq(tuple5(
            pendingWR, pktMetaData, respPktInfo, respAction, wcReqType
        ));
        // $display(
        //     "time=%0t: 3rd stage, bth.psn=%h", $time, bth.psn,
        //     ", bth.opcode=", fshow(bth.opcode),
        //     ", respAction=", fshow(respAction),
        //     ", wcReqType=", fshow(wcReqType),
        //     ", wr.id=%h", pendingWR.wr.id
        // );
    endrule

    rule queryPerm4NormalReadAtomicResp if (cntrlStatus.comm.isRTS || cntrlStatus.comm.isERR); // This rule still runs at retry or error state
        let {
            pendingWR, pktMetaData, respPktInfo, respAction, wcReqType
        } = pendingPermQueryQ.first;
        pendingPermQueryQ.deq;

        let isFirstOrOnlyPkt = respPktInfo.isFirstOrOnlyPkt;
        let isReadResp       = respPktInfo.isReadResp;
        let isAtomicResp     = respPktInfo.isAtomicResp;
        let isZeroPayloadLen = pktMetaData.isZeroPayloadLen;

        let expectPermCheckResp = False;
        if (respAction == SQ_ACT_EXPLICIT_NORMAL_RESP) begin
            if (
                isFirstOrOnlyPkt && !inErrState &&
                ((isReadResp && !isZeroPayloadLen) || isAtomicResp)
            ) begin
                let permCheckReq = PermCheckReq {
                    wrID         : tagged Valid pendingWR.wr.id,
                    lkey         : pendingWR.wr.lkey,
                    rkey         : dontCareValue,
                    reqAddr      : pendingWR.wr.laddr,
                    totalLen     : pendingWR.wr.len,
                    pdHandler    : pktMetaData.pdHandler,
                    isZeroDmaLen : isAtomicResp ? False : isZeroPayloadLen,
                    accFlags     : enum2Flag(IBV_ACCESS_LOCAL_WRITE),
                    localOrRmtKey: True
                };
                permCheckSrv.request.put(permCheckReq);
                expectPermCheckResp = True;
            end
        end

        pendingRetryCheckQ.enq(tuple6(
            pendingWR, pktMetaData, respPktInfo, respAction, wcReqType, expectPermCheckResp
        ));
        // $display(
        //     "time=%0t: 4th stage, bth.psn=%h", $time, respPktInfo.bth.psn,
        //     ", respAction=", fshow(respAction),
        //     ", wcReqType=", fshow(wcReqType),
        //     ", expectPermCheckResp=", fshow(expectPermCheckResp),
        //     ", wr.id=%h", pendingWR.wr.id
        // );
    endrule

    rule checkRetryErr if (cntrlStatus.comm.isRTS || cntrlStatus.comm.isERR); // This rule still runs at retry or error state
        let {
            pendingWR, pktMetaData, respPktInfo, respAction, wcReqType, expectPermCheckResp
        } = pendingRetryCheckQ.first;
        pendingRetryCheckQ.deq;

        let bth  = respPktInfo.bth;
        let aeth = respPktInfo.aeth;

        let isLastOrOnlyPkt = respPktInfo.isLastOrOnlyPkt;
        let needWorkComp    = workReqNeedWorkCompSQ(pendingWR.wr);
        let wcStatus        = tagged Invalid;
        case (respAction)
            SQ_ACT_BAD_RESP: begin
                respPktInfo.genWorkComp = True;
                // Discard bad response payload
                respPktInfo.shouldDiscard = True;
                wcStatus = tagged Valid IBV_WC_BAD_RESP_ERR;
            end
            SQ_ACT_ERROR_RESP: begin
                respPktInfo.genWorkComp = True;

                immAssert(
                    rdmaRespHasAETH(bth.opcode),
                    "rdmaRespHasAETH assertion @ mkRespHandleSQ",
                    $format(
                        "rdmaRespHasAETH=", fshow(rdmaRespHasAETH(bth.opcode)),
                        " should be true"
                    )
                );
                wcStatus = genErrWorkCompStatusFromAethSQ(aeth);
                immAssert(
                    isValid(wcStatus),
                    "isValid(wcStatus) assertion @ mkRespHandleSQ",
                    $format(
                        "wcStatus=", fshow(wcStatus),
                        " should be valid after call genErrWorkCompStatusFromAethSQ(aeth=",
                        fshow(aeth), ")"
                    )
                );
            end
            SQ_ACT_EXPLICIT_NORMAL_RESP: begin
                if (needWorkComp && isLastOrOnlyPkt) begin
                    respPktInfo.genWorkComp = True;

                    // If need WC and no valid WC status yet,
                    // then WC status is success.
                    if (!isValid(wcStatus)) begin
                        wcStatus = tagged Valid IBV_WC_SUCCESS;
                    end
                end
            end
            SQ_ACT_COALESCE_RESP: begin
                respPktInfo.genWorkComp = needWorkComp;
                wcStatus = needWorkComp ? (tagged Valid IBV_WC_SUCCESS) : (tagged Invalid);
            end
            SQ_ACT_DUPLICATE_RESP: begin
                // Discard duplicate response payload
                respPktInfo.shouldDiscard = True;
            end
            // SQ_ACT_GHOST_RESP: begin
            //     // Discard ghost response payload
            //     respPktInfo.shouldDiscard = True;
            // end
            SQ_ACT_ILLEGAL_RESP: begin
                respPktInfo.genWorkComp   = True;
                // Discard illegal response payload
                respPktInfo.shouldDiscard = True;
                wcStatus = pktStatus2WorkCompStatusSQ(pktMetaData.pktStatus);
                immAssert(
                    isValid(wcStatus),
                    "isValid(wcStatus) assertion @ mkRespHandleSQ",
                    $format(
                        "wcStatus=", fshow(wcStatus),
                        " should be valid after call pktStatus2WorkCompStatusSQ(pktStatus=",
                        fshow(pktMetaData.pktStatus), ")"
                    )
                );
            end
            SQ_ACT_DISCARD_RESP: begin
                // Discard response payload when retry or error flush
                respPktInfo.shouldDiscard = True;
            end
            SQ_ACT_FLUSH_WR: begin
                // Generate WC for flushed WR
                respPktInfo.genWorkComp = True;
                wcStatus = tagged Valid IBV_WC_WR_FLUSH_ERR;
            end
            SQ_ACT_EXPLICIT_RETRY, SQ_ACT_IMPLICIT_RETRY: begin
                let retryResp  <- retryHandler.srvPort.response.get;
                let hasRetryErr = retryResp == RETRY_HANDLER_RETRY_LIMIT_EXC;
                // let hasRetryErr = retryHandler.hasRetryErr;
                if (hasRetryErr) begin
                    wcStatus  = tagged Valid IBV_WC_RETRY_EXC_ERR;
                    wcReqType = WC_REQ_TYPE_PARTIAL_ACK;
                    respPktInfo.genWorkComp = True;
                end

                // Discard implicite retry response payload
                respPktInfo.shouldDiscard = True;
            end
            SQ_ACT_TIMEOUT_ERR: begin
                // Generate WC for timeout WR
                respPktInfo.genWorkComp = True;
                wcStatus = tagged Valid IBV_WC_RESP_TIMEOUT_ERR;
            end
            default: begin
                immFail(
                    "unreachible case @ mkRespHandleSQ",
                    $format("respAction=", fshow(respAction))
                );
            end
        endcase

        pendingPermCheckQ.enq(tuple7(
            pendingWR, pktMetaData, respPktInfo, respAction, wcStatus, wcReqType, expectPermCheckResp
        ));
        // $display(
        //     "time=%0t: 5th stage, bth.psn=%h", $time, bth.psn,
        //     ", bth.opcode=", fshow(bth.opcode),
        //     ", respAction=", fshow(respAction),
        //     ", wcStatus=", fshow(wcStatus),
        //     ", wcReqType=", fshow(wcReqType),
        //     ", wr.id=%h", pendingWR.wr.id
        // );
    endrule

    rule checkPerm4NormalReadAtomicResp if (cntrlStatus.comm.isRTS || cntrlStatus.comm.isERR); // This rule still runs at retry or error state
        let {
            pendingWR, pktMetaData, respPktInfo, respAction, wcStatus, wcReqType, expectPermCheckResp
        } = pendingPermCheckQ.first;
        pendingPermCheckQ.deq;

        let bth  = respPktInfo.bth;
        // let aeth = respPktInfo.aeth;

        if (respAction == SQ_ACT_EXPLICIT_NORMAL_RESP) begin
            if (isValid(wcStatus)) begin
                let wcs = unwrapMaybe(wcStatus);
                immAssert(
                    wcs == IBV_WC_SUCCESS,
                    "wcs assertion @ mkRespHandleSQ",
                    $format("wcStatus=", fshow(wcStatus), " should be valid and IBV_WC_SUCCESS")
                );
            end

            if (expectPermCheckResp) begin
                let mrCheckResult <- permCheckSrv.response.get;
                if (!mrCheckResult) begin
                    wcStatus   = tagged Valid IBV_WC_LOC_ACCESS_ERR;
                    respAction = SQ_ACT_LOCAL_ACC_ERR;
                    respPktInfo.genWorkComp   = True;
                    respPktInfo.hasLocalErr   = True;
                    // Discard read response payload
                    respPktInfo.shouldDiscard = True;
                end
            end
        end

        // pendingLenCalcQ.enq(tuple6(
        pendingAddrCalcQ.enq(tuple6(
            pendingWR, pktMetaData, respPktInfo, respAction, wcStatus, wcReqType
        ));
        // $display(
        //     "time=%0t: 6th stage, bth.psn=%h", $time, bth.psn,
        //     ", bth.opcode=", fshow(bth.opcode),
        //     ", respAction=", fshow(respAction),
        //     ", wcStatus=", fshow(wcStatus),
        //     ", wcReqType=", fshow(wcReqType),
        //     ", wr.id=%h", pendingWR.wr.id
        // );
    endrule

    rule calcReadRespAddr if (cntrlStatus.comm.isRTS || cntrlStatus.comm.isERR); // This rule still runs at retry or error state
        let {
            pendingWR, pktMetaData, respPktInfo, respAction, wcStatus, wcReqType
        } = pendingAddrCalcQ.first;
        pendingAddrCalcQ.deq;

        let bth           = respPktInfo.bth;
        let isReadResp    = respPktInfo.isReadResp;
        let isFirstPkt    = isFirstRdmaOpCode(bth.opcode);
        let isMidPkt      = isMiddleRdmaOpCode(bth.opcode);
        let isLastPkt     = isLastRdmaOpCode(bth.opcode);
        let isOnlyPkt     = isOnlyRdmaOpCode(bth.opcode);

        let nextReadRespWriteAddr = nextReadRespWriteAddrReg;
        let readRespPktNum        = readRespPktNumReg;
        let oneAsPSN              = 1;

        if (isReadResp) begin
            case ( { pack(isOnlyPkt), pack(isFirstPkt), pack(isMidPkt), pack(isLastPkt) } )
                4'b1000: begin // isOnlyRdmaOpCode(bth.opcode)
                    nextReadRespWriteAddr = pendingWR.wr.laddr;
                    readRespPktNum        = 1;
                end
                4'b0100: begin // isFirstRdmaOpCode(bth.opcode)
                    nextReadRespWriteAddr = addrAddPsnMultiplyPMTU(pendingWR.wr.laddr, oneAsPSN, cntrlStatus.comm.getPMTU);
                    readRespPktNum        = readRespPktNumReg + 1;
                end
                4'b0010: begin // isMiddleRdmaOpCode(bth.opcode)
                    nextReadRespWriteAddr = addrAddPsnMultiplyPMTU(nextReadRespWriteAddrReg, oneAsPSN, cntrlStatus.comm.getPMTU);
                    readRespPktNum        = readRespPktNumReg + 1;
                end
                4'b0001: begin // isLastRdmaOpCode(bth.opcode)
                    // No need to calculate next DMA write address for last read responses
                    // nextReadRespWriteAddr = nextReadRespWriteAddrReg + zeroExtend(pktPayloadLen);
                    readRespPktNum        = readRespPktNumReg + 1;
                end
                default: begin
                    immFail(
                        "unreachible case @ mkRespHandleSQ",
                        $format(
                            "isOnlyPkt=", fshow(isOnlyPkt),
                            "isFirstPkt=", fshow(isFirstPkt),
                            "isMidPkt=", fshow(isMidPkt),
                            "isLastPkt=", fshow(isLastPkt)
                        )
                    );
                end
            endcase

            if (respAction == SQ_ACT_EXPLICIT_NORMAL_RESP && !inErrState) begin
                nextReadRespWriteAddrReg <= nextReadRespWriteAddr;
                readRespPktNumReg        <= readRespPktNum;
            end
        end

        pendingLenCalcQ.enq(tuple7(
            pendingWR, pktMetaData, respPktInfo, respAction,
            wcStatus, wcReqType, nextReadRespWriteAddr
        ));
        // $display(
        //     "time=%0t: 7th stage, bth.psn=%h", $time, bth.psn,
        //     ", bth.opcode=", fshow(bth.opcode),
        //     ", respAction=", fshow(respAction),
        //     ", wcStatus=", fshow(wcStatus),
        //     ", wcReqType=", fshow(wcReqType),
        //     ", nextReadRespWriteAddr=", fshow(nextReadRespWriteAddr),
        //     ", readRespPktNum=%0d", readRespPktNum,
        //     ", wr.id=%h", pendingWR.wr.id
        // );
    endrule

    rule calcReadRespLen if (cntrlStatus.comm.isRTS || cntrlStatus.comm.isERR); // This rule still runs at retry or error state
        let {
            pendingWR, pktMetaData, respPktInfo, respAction,
            wcStatus, wcReqType, nextReadRespWriteAddr
        } = pendingLenCalcQ.first;
        pendingLenCalcQ.deq;

        let bth           = respPktInfo.bth;
        let isReadResp    = respPktInfo.isReadResp;
        let pktPayloadLen = pktMetaData.pktPayloadLen;
        let isFirstPkt    = isFirstRdmaOpCode(bth.opcode);
        let isMidPkt      = isMiddleRdmaOpCode(bth.opcode);
        let isLastPkt     = isLastRdmaOpCode(bth.opcode);
        let isOnlyPkt     = isOnlyRdmaOpCode(bth.opcode);

        let remainingReadRespLen  = remainingReadRespLenReg;
        let oneAsPSN              = 1;

        if (isReadResp) begin
            case ( { pack(isOnlyPkt), pack(isFirstPkt), pack(isMidPkt), pack(isLastPkt) } )
                4'b1000: begin // isOnlyRdmaOpCode(bth.opcode)
                    remainingReadRespLen = pendingWR.wr.len - zeroExtend(pktPayloadLen);
                end
                4'b0100: begin // isFirstRdmaOpCode(bth.opcode)
                    remainingReadRespLen = lenSubtractPsnMultiplyPMTU(pendingWR.wr.len, oneAsPSN, cntrlStatus.comm.getPMTU);
                end
                4'b0010: begin // isMiddleRdmaOpCode(bth.opcode)
                    remainingReadRespLen = lenSubtractPsnMultiplyPMTU(remainingReadRespLenReg, oneAsPSN, cntrlStatus.comm.getPMTU);
                end
                4'b0001: begin // isLastRdmaOpCode(bth.opcode)
                    remainingReadRespLen = lenSubtractPktLen(remainingReadRespLenReg, pktPayloadLen, cntrlStatus.comm.getPMTU);
                end
                default: begin
                    immFail(
                        "unreachible case @ mkRespHandleSQ",
                        $format(
                            "isOnlyPkt=", fshow(isOnlyPkt),
                            "isFirstPkt=", fshow(isFirstPkt),
                            "isMidPkt=", fshow(isMidPkt),
                            "isLastPkt=", fshow(isLastPkt)
                        )
                    );
                end
            endcase

            if (respAction == SQ_ACT_EXPLICIT_NORMAL_RESP && !inErrState) begin
                remainingReadRespLenReg <= remainingReadRespLen;
            end
        end

        let respLenCheckResult = RespLenCheckResult {
            enoughDmaSpace       : False,
            isLastPayloadLenZero : True,
            nextReadRespWriteAddr: nextReadRespWriteAddr,
            remainingReadRespLen : remainingReadRespLen
        };
        pendingSpaceCalcQ.enq(tuple8(
            pendingWR, pktMetaData, respPktInfo, respAction, wcStatus,
            wcReqType, respLenCheckResult, remainingReadRespLenReg
        ));
        // $display(
        //     "time=%0t: 8th stage, bth.psn=%h", $time, bth.psn,
        //     ", bth.opcode=", fshow(bth.opcode),
        //     ", respAction=", fshow(respAction),
        //     ", wcStatus=", fshow(wcStatus),
        //     ", wcReqType=", fshow(wcReqType),
        //     ", nextReadRespWriteAddr=", fshow(nextReadRespWriteAddr),
        //     ", readRespPktNum=%0d", readRespPktNum,
        //     ", wr.id=%h", pendingWR.wr.id
        // );
    endrule

    rule calcEnoughDmaSpace if (cntrlStatus.comm.isRTS || cntrlStatus.comm.isERR); // This rule still runs at retry or error state
        let {
            pendingWR, pktMetaData, respPktInfo, respAction, wcStatus,
            wcReqType, respLenCheckResult, preRemainingDmaWriteLen
        } = pendingSpaceCalcQ.first;
        pendingSpaceCalcQ.deq;

        let bth           = respPktInfo.bth;
        let isReadResp    = respPktInfo.isReadResp;
        let pktPayloadLen = pktMetaData.pktPayloadLen;
        let isFirstPkt    = isFirstRdmaOpCode(bth.opcode);
        let isMidPkt      = isMiddleRdmaOpCode(bth.opcode);
        let isLastPkt     = isLastRdmaOpCode(bth.opcode);
        let isOnlyPkt     = isOnlyRdmaOpCode(bth.opcode);
        Length pmtuLen    = zeroExtend(calcPmtuLen(cntrlStatus.comm.getPMTU));

        let enoughDmaSpace        = True;
        let isLastPayloadLenZero  = False;

        if (isReadResp) begin
            case ( { pack(isOnlyPkt), pack(isFirstPkt), pack(isMidPkt), pack(isLastPkt) } )
                4'b1000: begin // isOnlyRdmaOpCode(bth.opcode)
                    // Just truncate the total length and then compare with the payload length
                    enoughDmaSpace       = lenGtEqPktLen(pendingWR.wr.len, pktPayloadLen, cntrlStatus.comm.getPMTU);
                    if (respAction == SQ_ACT_EXPLICIT_NORMAL_RESP && !inErrState) begin
                        immAssert(
                            pmtuLen >= pendingWR.wr.len,
                            "enoughDmaSpace for only packets @ mkRespHandleSQ",
                            $format(
                                "pendingWR.wr.len=%0d should not larger than pmtuLen=%0d, when isOnlyPkt=",
                                pendingWR.wr.len, pmtuLen, fshow(isOnlyPkt)
                            )
                        );
                    end
                end
                4'b0100: begin // isFirstRdmaOpCode(bth.opcode)
                    enoughDmaSpace       = lenGtEqPMTU(pendingWR.wr.len, cntrlStatus.comm.getPMTU);
                end
                4'b0010: begin // isMiddleRdmaOpCode(bth.opcode)
                    enoughDmaSpace       = lenGtEqPMTU(preRemainingDmaWriteLen, cntrlStatus.comm.getPMTU);
                end
                4'b0001: begin // isLastRdmaOpCode(bth.opcode)
                    // Just truncate the remaining DMA length and then compare with the payload length
                    enoughDmaSpace       = lenGtEqPktLen(preRemainingDmaWriteLen, pktPayloadLen, cntrlStatus.comm.getPMTU);
                    isLastPayloadLenZero = pktMetaData.isZeroPayloadLen;
                    if (respAction == SQ_ACT_EXPLICIT_NORMAL_RESP && !inErrState) begin
                        immAssert(
                            pmtuLen >= preRemainingDmaWriteLen,
                            "enoughDmaSpace for last packets @ mkRespHandleSQ",
                            $format(
                                "preRemainingDmaWriteLen=%0d should not larger than pmtuLen=%0d, when isLastPkt=",
                                preRemainingDmaWriteLen, pmtuLen, fshow(isLastPkt)
                            )
                        );
                    end
                end
                default: begin
                    immFail(
                        "unreachible case @ mkRespHandleSQ",
                        $format(
                            "isOnlyPkt=", fshow(isOnlyPkt),
                            "isFirstPkt=", fshow(isFirstPkt),
                            "isMidPkt=", fshow(isMidPkt),
                            "isLastPkt=", fshow(isLastPkt)
                        )
                    );
                end
            endcase
        end

        // let respLenCheckResult = RespLenCheckResult {
        //     enoughDmaSpace       : enoughDmaSpace,
        //     isLastPayloadLenZero : isLastPayloadLenZero,
        //     nextReadRespWriteAddr: nextReadRespWriteAddr,
        //     remainingReadRespLen : remainingReadRespLen
        // };
        respLenCheckResult.enoughDmaSpace = enoughDmaSpace;
        respLenCheckResult.isLastPayloadLenZero = isLastPayloadLenZero;
        pendingLenCheckQ.enq(tuple7(
            pendingWR, pktMetaData, respPktInfo, respAction,
            wcStatus, wcReqType, respLenCheckResult
        ));
        // $display(
        //     "time=%0t: 9th stage, bth.psn=%h", $time, bth.psn,
        //     ", bth.opcode=", fshow(bth.opcode),
        //     ", respAction=", fshow(respAction),
        //     ", wcStatus=", fshow(wcStatus),
        //     ", wcReqType=", fshow(wcReqType),
        //     ", nextReadRespWriteAddr=", fshow(nextReadRespWriteAddr),
        //     ", readRespPktNum=%0d", readRespPktNum,
        //     ", wr.id=%h", pendingWR.wr.id
        // );
    endrule

    rule checkReadRespLen if (cntrlStatus.comm.isRTS || cntrlStatus.comm.isERR); // This rule still runs at retry or error state
        let {
            pendingWR, pktMetaData, respPktInfo, respAction,
            wcStatus, wcReqType, respLenCheckResult
        } = pendingLenCheckQ.first;
        pendingLenCheckQ.deq;

        let bth             = respPktInfo.bth;
        let isReadResp      = respPktInfo.isReadResp;
        let isLastOrOnlyPkt = respPktInfo.isLastOrOnlyPkt;

        let enoughDmaSpace        = respLenCheckResult.enoughDmaSpace;
        let isLastPayloadLenZero  = respLenCheckResult.isLastPayloadLenZero;
        let nextReadRespWriteAddr = respLenCheckResult.nextReadRespWriteAddr;
        let remainingReadRespLen  = respLenCheckResult.remainingReadRespLen;

        if (isReadResp && respAction == SQ_ACT_EXPLICIT_NORMAL_RESP && !inErrState) begin
            let readRespLenMatch = isLastOrOnlyPkt ? isZero(remainingReadRespLen) : True;
            if (!enoughDmaSpace || !readRespLenMatch || isLastPayloadLenZero) begin
                // Read response length not match WR length
                respAction = SQ_ACT_LOCAL_LEN_ERR;
                wcStatus   = tagged Valid IBV_WC_LOC_LEN_ERR;
                wcReqType  = isLastOrOnlyPkt ? WC_REQ_TYPE_FULL_ACK : WC_REQ_TYPE_PARTIAL_ACK;
                respPktInfo.genWorkComp   = True;
                respPktInfo.hasLocalErr   = True;
                // Discard read response payload when length error
                respPktInfo.shouldDiscard = True;
            end
        end

        pendingDmaReqQ.enq(tuple7(
            pendingWR, pktMetaData, respPktInfo, respAction,
            wcStatus, wcReqType, nextReadRespWriteAddr
        ));
        // $display(
        //     "time=%0t: 10th stage, bth.psn=%h", $time, bth.psn,
        //     ", bth.opcode=", fshow(bth.opcode),
        //     ", respAction=", fshow(respAction),
        //     ", enoughDmaSpace=", fshow(enoughDmaSpace),
        //     ", isLastPayloadLenZero=", fshow(isLastPayloadLenZero),
        //     ", remainingReadRespLen=%h", remainingReadRespLen,
        //     ", nextReadRespWriteAddr=%h", nextReadRespWriteAddr
        // );
    endrule

    rule issueDmaReq if (cntrlStatus.comm.isRTS || cntrlStatus.comm.isERR); // This rule still runs at retry or error state
        let {
            pendingWR, pktMetaData, respPktInfo, respAction,
            wcStatus, wcReqType, nextReadRespWriteAddr
        } = pendingDmaReqQ.first;
        pendingDmaReqQ.deq;

        let rdmaHeader       = pktMetaData.pktHeader;
        let atomicAckAeth    = extractAtomicAckEth(rdmaHeader.headerData);
        let genWorkComp      = respPktInfo.genWorkComp;
        let shouldDiscard    = respPktInfo.shouldDiscard;
        let hasLocalErr      = respPktInfo.hasLocalErr;
        let bth              = respPktInfo.bth;
        let isReadResp       = respPktInfo.isReadResp;
        let isAtomicResp     = respPktInfo.isAtomicResp;
        let isZeroPayloadLen = pktMetaData.isZeroPayloadLen;

        let wcWaitDmaResp = False;
        if (respAction == SQ_ACT_EXPLICIT_NORMAL_RESP) begin
            if (!inErrState) begin
                if (isReadResp && !isZeroPayloadLen) begin
                    let payloadConReq = PayloadConReq {
                        fragNum      : pktMetaData.pktFragNum,
                        consumeInfo  : tagged SendWriteReqReadRespInfo DmaWriteMetaData {
                            initiator: DMA_SRC_SQ_WR,
                            sqpn     : cntrlStatus.comm.getSQPN,
                            startAddr: nextReadRespWriteAddr,
                            len      : pktMetaData.pktPayloadLen,
                            psn      : bth.psn,
                            mrID     : wr2IndexMR(pendingWR.wr)
                        }
                    };
                    // payloadConReqOutQ.enq(payloadConReq);
                    payloadConReqPort.put(payloadConReq);
                    wcWaitDmaResp = True;
                    // $display(
                    //     "time=%0t: 11th stage read response, bth.psn=%h", $time, bth.psn,
                    //     ", bth.opcode=", fshow(bth.opcode),
                    //     ", respAction=", fshow(respAction),
                    //     // ", wcReqType=", fshow(wcReqType),
                    //     // ", wcStatus=", fshow(wcStatus),
                    //     // ", genWorkComp=", fshow(genWorkComp),
                    //     // ", wcWaitDmaResp=", fshow(wcWaitDmaResp),
                    //     ", wr.id=%h, WR len=%0d, pktPayloadLen=%0d",
                    //     pendingWR.wr.id, pendingWR.wr.len, pktMetaData.pktPayloadLen
                    // );
                end
                else if (isAtomicResp) begin
                    let atomicWriteReq = PayloadConReq {
                        fragNum    : 0,
                        consumeInfo: tagged AtomicRespInfoAndPayload {
                            atomicRespDmaWriteMetaData: DmaWriteMetaData {
                                initiator: DMA_SRC_SQ_ATOMIC,
                                sqpn     : cntrlStatus.comm.getSQPN,
                                startAddr: pendingWR.wr.laddr,
                                len      : truncate(pendingWR.wr.len),
                                psn      : bth.psn,
                                mrID     : wr2IndexMR(pendingWR.wr)
                            },
                            atomicRespPayload: atomicAckAeth.orig
                        }
                    };
                    // payloadConReqOutQ.enq(atomicWriteReq);
                    payloadConReqPort.put(atomicWriteReq);
                    wcWaitDmaResp = True;
                end
            end
        end
        else if ((shouldDiscard || inErrState) && !isZeroPayloadLen) begin
            let initiator = DMA_SRC_SQ_DISCARD;
            let payloadDiscardReq <- genDiscardPayloadReq(
                pktMetaData.pktFragNum, initiator, cntrlStatus.comm.getSQPN,
                nextReadRespWriteAddr, pktMetaData.pktPayloadLen, bth.psn,
                wr2IndexMR(pendingWR.wr)
            );
            // payloadConReqOutQ.enq(payloadDiscardReq);
            payloadConReqPort.put(payloadDiscardReq);
        end

        immAssert(
            !hasLocalErr || genWorkComp,
            "hasLocalErr -> genWorkComp assertion @ mkRespHandleSQ",
            $format(
                "genWorkComp=", fshow(genWorkComp),
                " should be true when hasLocalErr=", fshow(hasLocalErr),
                ", respAction=", fshow(respAction)
            )
        );
        immAssert(
            !genWorkComp || isValid(wcStatus),
            "genWorkComp -> isValid(wcStatus) assertion @ mkRespHandleSQ",
            $format(
                "wcStatus=", fshow(wcStatus),
                " should be valid when genWorkComp=", fshow(genWorkComp),
                ", respAction=", fshow(respAction)
            )
        );
        immAssert(
            !(wcWaitDmaResp && !genWorkComp) || !isValid(wcStatus),
            "(wcWaitDmaResp && !genWorkComp) -> !isValid(wcStatus) assertion @ mkRespHandleSQ",
            $format(
                "wcStatus=", fshow(wcStatus),
                " should be invalid when wcWaitDmaResp=", fshow(wcWaitDmaResp),
                " and genWorkComp=", fshow(genWorkComp),
                ", respAction=", fshow(respAction)
            )
        );

        if (wcStatus matches tagged Valid .wcs &&& wcs != IBV_WC_SUCCESS) begin
            // errOccurredReg <= True;
            hasInternalErrReg[0] <= True;
            // $display(
            //     "time=%0t: hasInternalErrReg[0]=", $time, fshow(hasInternalErrReg[0]),
            //     ", wcStatus=", fshow(wcStatus)
            // );

            immAssert(
                genWorkComp,
                "genWorkComp assertion @ mkRespHandleSQ",
                $format(
                    "genWorkComp=", fshow(genWorkComp),
                    " should be true when wcStatus=", fshow(wcs)
                )
            );
        end

        let workCompGenReq = WorkCompGenReqSQ {
            wr           : pendingWR.wr,
            wcWaitDmaResp: wcWaitDmaResp,
            wcReqType    : wcReqType,
            triggerPSN   : bth.psn,
            wcStatus     : unwrapMaybeWithDefault(wcStatus, IBV_WC_SUCCESS)
        };
        pendingWorkCompQ.enq(tuple2(respPktInfo, workCompGenReq));
        // $display(
        //     "time=%0t: 11th stage, bth.psn=%h", $time, bth.psn,
        //     ", bth.opcode=", fshow(bth.opcode),
        //     ", respAction=", fshow(respAction),
        //     ", wcReqType=", fshow(wcReqType),
        //     ", wcStatus=", fshow(wcStatus),
        //     ", genWorkComp=", fshow(genWorkComp),
        //     ", wcWaitDmaResp=", fshow(wcWaitDmaResp),
        //     ", wr.id=%h", pendingWR.wr.id
        // );
    endrule

    rule genWorkCompSQ if (cntrlStatus.comm.isRTS || cntrlStatus.comm.isERR); // This rule still runs at retry or error state
        let { respPktInfo, workCompGenReq } = pendingWorkCompQ.first;
        pendingWorkCompQ.deq;

        let bth           = respPktInfo.bth;
        let genWorkComp   = respPktInfo.genWorkComp;
        let hasLocalErr   = respPktInfo.hasLocalErr;
        let wcWaitDmaResp = workCompGenReq.wcWaitDmaResp;
        let wcStatus      = workCompGenReq.wcStatus;
        let wcReqType     = workCompGenReq.wcReqType;

        immAssert(
            !hasLocalErr || genWorkComp,
            "hasLocalErr -> genWorkComp assertion @ mkRespHandleSQ",
            $format(
                "genWorkComp=", fshow(genWorkComp),
                " should be true when hasLocalErr=", fshow(hasLocalErr)
                // ", respAction=", fshow(respAction)
            )
        );

        if (genWorkComp || wcWaitDmaResp) begin
            // Wait for read/atomic response DMA write and generate WC for WR if needed
            workCompGenReqOutQ.enq(workCompGenReq);
            // $display(
            //     "time=%0t: workCompGenReq=", $time, fshow(workCompGenReq),
            //     ", wcStatus=", fshow(wcStatus)
            // );
        end

        // $display(
        //     "time=%0t: 12th stage, bth.psn=%h", $time, bth.psn,
        //     ", bth.opcode=", fshow(bth.opcode),
        //     // ", respAction=", fshow(respAction),
        //     ", wcReqType=", fshow(wcReqType),
        //     ", wcStatus=", fshow(wcStatus),
        //     ", genWorkComp=", fshow(genWorkComp),
        //     ", wcWaitDmaResp=", fshow(wcWaitDmaResp),
        //     ", wr.id=%h", workCompGenReq.wr.id
        // );
    endrule

    // (* no_implicit_conditions, fire_when_enabled *)
    (* fire_when_enabled *)
    rule discardGhostResp if (
        cntrlStatus.comm.isRTS && inNormalState &&
        pktMetaDataPipeIn.notEmpty   &&
        !pendingWorkReqPipeIn.notEmpty
    ); // Ghost responses
        let pktMetaData = pktMetaDataPipeIn.first;
        pktMetaDataPipeIn.deq;

        PendingWorkReq emptyPendingWR = dontCareValue;

        let rdmaHeader  = pktMetaData.pktHeader;
        let bth         = extractBTH(rdmaHeader.headerData);
        // let aeth        = extractAETH(rdmaHeader.headerData);
        let respPktInfo = RespPktInfo {
            bth             : bth,
            aeth            : dontCareValue, // aeth,
            // isZeroPayloadLen: isZero(pktMetaData.pktPayloadLen),
            isFirstOrOnlyPkt: True, // isFirstOrOnlyRdmaOpCode(bth.opcode),
            isLastOrOnlyPkt : True, // isLastOrOnlyRdmaOpCode(bth.opcode),
            isReadResp      : False, // isReadRespRdmaOpCode(bth.opcode),
            isAtomicResp    : False, // isAtomicRespRdmaOpCode(bth.opcode),
            hasLocalErr     : False,
            shouldDiscard   : True,
            genWorkComp     : False
        };
        // let rdmaRespType = RDMA_RESP_UNKNOWN;
        // let retryReason  = RETRY_REASON_NOT_RETRY;
        // let respAction   = SQ_ACT_DISCARD_RESP;
        let retryResetReq = RETRY_HANDLER_RESET_TIMEOUT;
        let wcReqType     = WC_REQ_TYPE_NO_WC;
        let wrAckType     = WR_ACK_GHOST;
        incomingRespQ.enq(tuple6(
            emptyPendingWR, pktMetaData, respPktInfo, retryResetReq, wcReqType, wrAckType
        ));

        // $display(
        //     "time=%0t: 1st ghost discard stage, bth.psn=%h", $time, bth.psn,
        //     ", bth.opcode=", fshow(bth.opcode),
        //     // ", rdmaRespType=", fshow(rdmaRespType),
        //     // ", retryReason=", fshow(retryReason),
        //     ", wrAckType=", fshow(wrAckType),
        //     ", wcReqType=", fshow(wcReqType)
        // );
    endrule

    (* fire_when_enabled *)
    rule checkTimeOutErr if (cntrlStatus.comm.isRTS && inNormalState);
        // Support timeout retry error
        let timeOutNotification <- retryHandler.notifyTimeOut2SQ;
        let hasTimeOutErr = timeOutNotification == RETRY_HANDLER_TIMEOUT_ERR;

        // No need to change to SQ_RETRY_FLUSH state if timeout retry,
        // since no responses to flush when timeout.
        if (hasTimeOutErr) begin
            hasTimeOutErrReg[0] <= True;
        end

        // $display(
        //     "time=%0t:", $time,
        //     " checkTimeOutErr, timeOutNotification=", fshow(timeOutNotification),
        //     ", hasTimeOutErr=", fshow(hasTimeOutErr),
        //     ", cntrlStatus.comm.isStableRTS=", fshow(cntrlStatus.comm.isStableRTS)
        // );
    endrule

    (* no_implicit_conditions, fire_when_enabled *)
    rule canonicalize if (
        cntrlStatus.comm.isRTS && (hasInternalErrReg[1] || hasTimeOutErrReg[1])
    );
        // hasTimeOutErrReg[1] is set to False in errFlushPktMetaDataAndPayload
        errOccurredReg       <= True;
        hasInternalErrReg[1] <= False;
        // $display(
        //     "time=%0t:", $time,
        //     " set errOccurredReg to True when hasInternalErrReg[1]=",
        //     fshow(hasInternalErrReg[1]),
        //     " and hasTimeOutErrReg[1]=",
        //     fshow(hasTimeOutErrReg[1])
        // );
    endrule

    (* fire_when_enabled *)
    rule errFlushWorkReq if (inErrStateAlt && pendingWorkReqPipeIn.notEmpty);
        let retryResetReq = RETRY_HANDLER_RESET_TIMEOUT;

        let pendingWR = pendingWorkReqPipeIn.first;
        pendingWorkReqPipeIn.deq;

        let respPktInfo = RespPktInfo {
            bth             : dontCareValue,
            aeth            : dontCareValue,
            // isZeroPayloadLen: True,
            isFirstOrOnlyPkt: True,
            isLastOrOnlyPkt : True,
            isReadResp      : False,
            isAtomicResp    : False,
            hasLocalErr     : True,
            shouldDiscard   : True,
            genWorkComp     : True
        };
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

        // let rdmaRespType = RDMA_RESP_UNKNOWN;
        // let retryReason  = RETRY_REASON_NOT_RETRY;
        // let respAction = hasTimeOutErrReg[0] ? SQ_ACT_TIMEOUT_ERR : SQ_ACT_FLUSH_WR;
        let wcReqType = WC_REQ_TYPE_FULL_ACK;
        let wrAckType = hasTimeOutErrReg[0] ? WR_ACK_TIMOUT_ERR : WR_ACK_ERR_FLUSH_WR;
        hasTimeOutErrReg[0] <= False;
        incomingRespQ.enq(tuple6(
            pendingWR, pktMetaData, respPktInfo, retryResetReq, wcReqType, wrAckType
        ));
        // $display(
        //     "time=%0t: 1st error flush WR stage", $time,
        //     ", pendingWR=", fshow(pendingWR),
        //     // ", rdmaRespType=", fshow(rdmaRespType),
        //     // ", retryReason=", fshow(retryReason),
        //     // ", respAction=", fshow(respAction),
        //     ", wrAckType=", fshow(wrAckType),
        //     ", wcReqType=", fshow(wcReqType),
        //     // ", cntrlStatus.comm.isERR=", fshow(cntrlStatus.comm.isERR),
        //     // ", respHandleStateReg=", fshow(respHandleStateReg)
        //     ", inErrStateAlt=", fshow(inErrStateAlt)
        // );
    endrule

    (* fire_when_enabled *)
    rule errFlushIncomingResp if (inErrStateAlt && !pendingWorkReqPipeIn.notEmpty);
        let retryResetReq = RETRY_HANDLER_RESET_TIMEOUT;

        let pktMetaData = pktMetaDataPipeIn.first;
        pktMetaDataPipeIn.deq;

        PendingWorkReq emptyPendingWR = dontCareValue;

        let rdmaHeader  = pktMetaData.pktHeader;
        let bth         = extractBTH(rdmaHeader.headerData);
        let aeth        = extractAETH(rdmaHeader.headerData);
        let respPktInfo = RespPktInfo {
            bth             : bth,
            aeth            : aeth,
            // isZeroPayloadLen: isZero(pktMetaData.pktPayloadLen),
            isFirstOrOnlyPkt: isFirstOrOnlyRdmaOpCode(bth.opcode),
            isLastOrOnlyPkt : isLastOrOnlyRdmaOpCode(bth.opcode),
            isReadResp      : isReadRespRdmaOpCode(bth.opcode),
            isAtomicResp    : isAtomicRespRdmaOpCode(bth.opcode),
            hasLocalErr     : False,
            shouldDiscard   : True,
            genWorkComp     : False
        };
        // let rdmaRespType = RDMA_RESP_UNKNOWN;
        // let retryReason  = RETRY_REASON_NOT_RETRY;
        // let wrAckType    = pendingWorkReqPipeIn.notEmpty ?
        //     WR_ACK_DISCARD : WR_ACK_GHOST;
        // let respAction = SQ_ACT_DISCARD_RESP;
        let wcReqType = WC_REQ_TYPE_NO_WC;
        let wrAckType = WR_ACK_DISCARD;
        incomingRespQ.enq(tuple6(
            emptyPendingWR, pktMetaData, respPktInfo, retryResetReq, wcReqType, wrAckType
        ));
        // $display(
        //     "time=%0t: 1st error flush incoming response stage", $time,
        //     ", bth.psn=%h, bth.opcode=", bth.psn, fshow(bth.opcode),
        //     // ", rdmaRespType=", fshow(rdmaRespType),
        //     // ", retryReason=", fshow(retryReason),
        //     // ", respAction=", fshow(respAction),
        //     ", wrAckType=", fshow(wrAckType),
        //     ", wcReqType=", fshow(wcReqType),
        //     ", inErrStateAlt=", fshow(inErrStateAlt)
        // );
    endrule

    (* no_implicit_conditions, fire_when_enabled *)
    rule retryFlushDone if (cntrlStatus.comm.isRTS && inRetryState);
        immAssert(
            pendingWorkReqPipeIn.notEmpty,
            "pendingWR notEmpty assertion @ mkRespHandleSQ",
            $format(
                "pendingWorkReqPipeIn.notEmpty=", fshow(pendingWorkReqPipeIn.notEmpty),
                " should be true, when cntrlStatus.comm.isRTS=", fshow(cntrlStatus.comm.isRTS),
                ", inRetryState=", fshow(inRetryState),
                ", retryFlushReg=", fshow(retryFlushReg),
                ", errOccurredReg=", fshow(errOccurredReg)
            )
        );

        if (retryHandler.isRetrying) begin
            retryFlushReg    <= False;
            recvRetryRespReg <= False;
            // respHandleStateReg <= SQ_HANDLE_RESP_HEADER;

            // $display(
            //     "time=%0t:", $time,
            //     " retry flush done, pendingWorkReqPipeIn.notEmpty=",
            //     fshow(pendingWorkReqPipeIn.notEmpty)
            // );
        end
    endrule

    // (* no_implicit_conditions, fire_when_enabled *)
    (* fire_when_enabled *)
    rule retryFlushPktMetaDataAndPayload if (cntrlStatus.comm.isRTS && inRetryState);
        preStageStateReg <= SQ_PRE_BUILD_STAGE;

        if (pktMetaDataPipeIn.notEmpty) begin
            let pktMetaData = pktMetaDataPipeIn.first;
            pktMetaDataPipeIn.deq;

            let rdmaHeader  = pktMetaData.pktHeader;
            let bth         = extractBTH(rdmaHeader.headerData);
            let aeth        = extractAETH(rdmaHeader.headerData);
            let respPktInfo = RespPktInfo {
                bth             : bth,
                aeth            : aeth,
                // isZeroPayloadLen: isZero(pktMetaData.pktPayloadLen),
                isFirstOrOnlyPkt: isFirstOrOnlyRdmaOpCode(bth.opcode),
                isLastOrOnlyPkt : isLastOrOnlyRdmaOpCode(bth.opcode),
                isReadResp      : isReadRespRdmaOpCode(bth.opcode),
                isAtomicResp    : isAtomicRespRdmaOpCode(bth.opcode),
                hasLocalErr     : False,
                shouldDiscard   : True,
                genWorkComp     : False
            };
            // let rdmaRespType = RDMA_RESP_UNKNOWN;
            // let retryReason = RETRY_REASON_NOT_RETRY;
            // let respAction = SQ_ACT_DISCARD_RESP;
            let retryResetReq = RETRY_HANDLER_RESET_TIMEOUT;
            let wcReqType     = WC_REQ_TYPE_NO_WC;
            let wrAckType     = WR_ACK_DISCARD;
            PendingWorkReq pendingWR = dontCareValue;
            incomingRespQ.enq(tuple6(
                pendingWR, pktMetaData, respPktInfo, retryResetReq, wcReqType, wrAckType
            ));
            // $display(
            //     "time=%0t: 1st retry flush stage, bth.psn=%h", $time, bth.psn,
            //     ", bth.opcode=", fshow(bth.opcode),
            //     // ", wr.id=%h", pendingWR.wr.id,
            //     // ", rdmaRespType=", fshow(rdmaRespType),
            //     // ", retryReason=", fshow(retryReason),
            //     // ", respAction=", fshow(respAction),
            //     ", wrAckType=", fshow(wrAckType),
            //     ", wcReqType=", fshow(wcReqType)
            // );
        end
        // $display("time=%0t: retryFlushPktMetaDataAndPayload", $time);
    endrule

    // interface payloadConReqPipeOut  = toPipeOut(payloadConReqOutQ);
    interface workCompGenReqPipeOut = toPipeOut(workCompGenReqOutQ);
endmodule
