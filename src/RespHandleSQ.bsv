import FIFOF :: *;
import PAClib :: *;

import Assertions :: *;
import Controller :: *;
import DataTypes :: *;
import Headers :: *;
import InputPktHandle :: *;
// import PayloadConAndGen :: *;
import RetryHandleSQ :: *;
import ScanFIFOF :: *;
import Utils :: *;
// import WorkCompGen :: *;

typedef enum {
    SQ_HANDLE_RESP_HEADER,
    SQ_RETRY_FLUSH,
    SQ_ERROR_FLUSH,
    SQ_RETRY_FLUSH_AND_WAIT
} RespHandleState deriving(Bits, Eq);

typedef enum {
    WR_ACK_EXPLICIT_WHOLE,
    WR_ACK_EXPLICIT_PARTIAL,
    WR_ACK_COALESCE_NORMAL,
    WR_ACK_COALESCE_RETRY,
    WR_ACK_DUPLICATE,
    WR_ACK_GHOST,
    WR_ACK_ILLEGAL,
    WR_ACK_FLUSH
} WorkReqAckType deriving(Bits, Eq, FShow);

typedef enum {
    WR_ACT_BAD_RESP,
    WR_ACT_ERROR_RESP,
    WR_ACT_EXPLICIT_RESP,
    WR_ACT_COALESCE_RESP,
    WR_ACT_DUPLICATE_RESP,
    WR_ACT_GHOST_RESP,
    WR_ACT_ILLEGAL_RESP,
    WR_ACT_FLUSH_RESP,
    WR_ACT_EXPLICIT_RETRY,
    WR_ACT_IMPLICIT_RETRY,
    WR_ACT_RETRY_EXC,
    WR_ACT_UNKNOWN
} WorkReqAction deriving(Bits, Eq, FShow);

module mkConnectPendingWorkReqPipeOut2PendingWorkReqQ#(
    Controller cntrl, PipeOut#(PendingWorkReq) pipe, FIFOF#(PendingWorkReq) fifo
)(Empty);
    rule connect if (cntrl.isRTS);
        fifo.enq(pipe.first);
        pipe.deq;
    endrule
endmodule

interface RespHandleSQ;
    interface PipeOut#(PayloadConReq) payloadConReqPipeOut;
    interface PipeOut#(WorkCompGenReqSQ) workCompGenReqPipeOut;
    // method RespHandleState curState();
endinterface

module mkRespHandleSQ#(
    Controller cntrl,
    PendingWorkReqBuf pendingWorkReqBuf,
    PipeOut#(RdmaPktMetaData) pktMetaDataPipeIn,
    RetryHandleSQ retryHandler
    // PayloadConsumer payloadConsumer,
    // WorkCompGen workCompGen
)(RespHandleSQ);
    FIFOF#(PayloadConReq)     payloadConReqOutQ <- mkFIFOF;
    FIFOF#(WorkCompGenReqSQ) workCompGenReqOutQ <- mkFIFOF;

    FIFOF#(Tuple6#(
        PendingWorkReq, RdmaPktMetaData, RdmaRespType,
        RetryReason, WorkReqAckType, WorkCompReqType
    )) pendingRespQ <- mkLFIFOF;
    FIFOF#(Tuple5#(
        PendingWorkReq, RdmaPktMetaData, WorkReqAction,
        Maybe#(WorkCompStatus), WorkCompReqType
    )) pendingDmaReqQ <- mkLFIFOF;

    Reg#(PSN)               retryStartPsnReg <- mkRegU;
    Reg#(WorkReqID)        retryWorkReqIdReg <- mkRegU;
    Reg#(RetryReason)         retryReasonReg <- mkRegU;
    Reg#(Maybe#(RnrTimer))  retryRnrTimerReg <- mkRegU;
    Reg#(Length)     remainingReadRespLenReg <- mkRegU;
    Reg#(ADDR)      nextReadRespWriteAddrReg <- mkRegU;
    Reg#(PktNum)           readRespPktNumReg <- mkRegU; // TODO: remove it
    Reg#(RdmaOpCode)        preRdmaOpCodeReg <- mkReg(ACKNOWLEDGE);
    Reg#(RespHandleState) respHandleStateReg <- mkReg(SQ_HANDLE_RESP_HEADER);

    // TODO: check discard duplicate or ghost reponses has
    // no response from PayloadConsumer will not incur bugs.
    function Action discardPayload(PmtuFragNum fragNum);
        action
            if (!isZero(fragNum)) begin
                let discardReq = PayloadConReq {
                    initiator  : PAYLOAD_INIT_SQ_DISCARD,
                    fragNum    : fragNum,
                    consumeInfo: tagged DiscardPayload
                };
                payloadConReqOutQ.enq(discardReq);
                // payloadConsumer.request(discardReq);
            end
        endaction
    endfunction

    // Response handle pipeline first stage
    rule recvRespHeader if (
        cntrl.isRTS                      &&
        // pendingWorkReqBuf.fifoF.notEmpty &&
        respHandleStateReg == SQ_HANDLE_RESP_HEADER
    ); // This rule will not run at retry state
        let curPktMetaData = pktMetaDataPipeIn.first;
        let curPendingWR   = pendingWorkReqBuf.fifoF.first;
        let curRdmaHeader  = curPktMetaData.pktHeader;

        BTH bth         = extractBTH(curRdmaHeader.headerData);
        let aeth        = extractAETH(curRdmaHeader.headerData);
        let retryReason = getRetryReasonFromAETH(aeth);
        dynAssert(
            isRdmaRespOpCode(bth.opcode),
            "isRdmaRespOpCode assertion @ mkRespHandleSQ",
            $format(
                "bth.opcode=", fshow(bth.opcode), " should be RDMA response"
            )
        );

        PSN nextPSN   = cntrl.getNPSN;
        PSN startPSN  = unwrapMaybe(curPendingWR.startPSN);
        PSN endPSN    = unwrapMaybe(curPendingWR.endPSN);
        PktNum pktNum = unwrapMaybe(curPendingWR.pktNum);
        dynAssert(
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

        let rdmaRespType = getRdmaRespType(bth.opcode, aeth);
        dynAssert(
            rdmaRespType != RDMA_RESP_UNKNOWN,
            "rdmaRespType assertion @ handleRetryResp() in mkRespHandleSQ",
            $format("rdmaRespType=", fshow(rdmaRespType), " should not be unknown")
        );

        let wrAckType = WR_ACK_FLUSH;
        let wcReqType = WC_REQ_TYPE_UNKNOWN;
        if (!pendingWorkReqBuf.fifoF.notEmpty) begin // Discard ghost response
            pktMetaDataPipeIn.deq;
            wrAckType = WR_ACK_GHOST;
            wcReqType = WC_REQ_TYPE_NO_WC;
        end
        else if (!curPktMetaData.pktValid) begin
            pktMetaDataPipeIn.deq;
            wrAckType = WR_ACK_ILLEGAL;
            wcReqType = WC_REQ_TYPE_ERR_FULL_ACK;
        end
        else begin
            // This stage needs to do:
            // - dequeue pending WR when normal response;
            // - change to flush state if retry or error response
            let shouldDeqPktMetaData = True;
            let deqPendingWorkReqWithNormalResp = False;
            if (bth.psn == endPSN) begin // Response to whole WR
                wrAckType = WR_ACK_EXPLICIT_WHOLE;

                case (rdmaRespType)
                    RDMA_RESP_RETRY: begin
                        wcReqType           = WC_REQ_TYPE_NO_WC;
                        respHandleStateReg <= SQ_RETRY_FLUSH;
                        retryStartPsnReg   <= bth.psn;
                        retryWorkReqIdReg  <= curPendingWR.wr.id;
                        retryReasonReg     <= retryReason;
                        retryRnrTimerReg   <= (retryReason == RETRY_REASON_RNR) ?
                            (tagged Valid aeth.value) : (tagged Invalid);
                    end
                    RDMA_RESP_ERROR: begin
                        wcReqType           = WC_REQ_TYPE_ERR_FULL_ACK;
                        respHandleStateReg <= SQ_ERROR_FLUSH;
                    end
                    RDMA_RESP_NORMAL: begin
                        wcReqType = WC_REQ_TYPE_SUC_FULL_ACK;
                        deqPendingWorkReqWithNormalResp = True;
                    end
                    default: begin end
                endcase
            end
            else if (psnInRangeExclusive(bth.psn, endPSN, nextPSN)) begin // Coalesce ACK
                shouldDeqPktMetaData = False;

                if (isReadOrAtomicWorkReq(curPendingWR.wr.opcode)) begin // Implicit retry
                    wrAckType           = WR_ACK_COALESCE_RETRY;
                    wcReqType           = WC_REQ_TYPE_NO_WC;
                    respHandleStateReg <= SQ_RETRY_FLUSH;
                    retryStartPsnReg   <= startPSN;
                    retryWorkReqIdReg  <= curPendingWR.wr.id;
                    retryReasonReg     <= RETRY_REASON_IMPLICIT;
                    retryRnrTimerReg   <= tagged Invalid;
                end
                else begin
                    wrAckType = WR_ACK_COALESCE_NORMAL;
                    wcReqType = WC_REQ_TYPE_SUC_FULL_ACK;
                    deqPendingWorkReqWithNormalResp = True;
                end
            end
            else if (bth.psn == startPSN || psnInRangeExclusive(bth.psn, startPSN, endPSN)) begin
                wrAckType = WR_ACK_EXPLICIT_PARTIAL;

                case (rdmaRespType)
                    RDMA_RESP_RETRY: begin
                        wcReqType           = WC_REQ_TYPE_NO_WC;
                        respHandleStateReg <= SQ_RETRY_FLUSH;
                        retryStartPsnReg   <= bth.psn;
                        retryWorkReqIdReg  <= curPendingWR.wr.id;
                        retryReasonReg     <= retryReason;
                    end
                    RDMA_RESP_ERROR: begin
                        // Explicit error responses will dequeue whole WR,
                        // no matter error reponses are full or partial ACK.
                        wcReqType        = WC_REQ_TYPE_ERR_FULL_ACK;
                        respHandleStateReg <= SQ_ERROR_FLUSH;
                    end
                    RDMA_RESP_NORMAL: begin
                        wcReqType = WC_REQ_TYPE_SUC_PARTIAL_ACK;
                    end
                    default         : begin end
                endcase
            end
            else begin // Duplicated responses
                wrAckType = WR_ACK_DUPLICATE;
                wcReqType = WC_REQ_TYPE_NO_WC;
            end

            if (shouldDeqPktMetaData) begin
                pktMetaDataPipeIn.deq;
            end
            if (deqPendingWorkReqWithNormalResp) begin
                pendingWorkReqBuf.fifoF.deq;
                retryHandler.resetRetryCnt;
            end

            if (isLastOrOnlyRdmaOpCode(bth.opcode)) begin
                dynAssert(
                    deqPendingWorkReqWithNormalResp,
                    "deqPendingWorkReqWithNormalResp assertion @ mkRespHandleSQ",
                    $format(
                        "deqPendingWorkReqWithNormalResp=", fshow(deqPendingWorkReqWithNormalResp),
                        " should be true when bth.opcode=", fshow(bth.opcode),
                        " is last or only read response"
                    )
                );
            end
        end

        dynAssert(
            wrAckType != WR_ACK_FLUSH && wcReqType != WC_REQ_TYPE_UNKNOWN,
            "wrAckType and wcReqType assertion @ mkRespHandleSQ",
            $format(
                "wrAckType=", fshow(wrAckType),
                ", and wcReqType=", fshow(wcReqType),
                " should not be unknown in rule recvRespHeader"
            )
        );
        pendingRespQ.enq(tuple6(
            curPendingWR, curPktMetaData, rdmaRespType, retryReason, wrAckType, wcReqType
        ));
    endrule

    // Response handle pipeline second stage
    rule handleRespByType if (cntrl.isRTS || cntrl.isERR); // This rule still runs at retry or error state
        let {
            curPendingWR, curPktMetaData, rdmaRespType, retryReason, wrAckType, wcReqType
        } = pendingRespQ.first;
        pendingRespQ.deq;

        let curRdmaHeader = curPktMetaData.pktHeader;
        let bth           = extractBTH(curRdmaHeader.headerData);
        let aeth          = extractAETH(curRdmaHeader.headerData);

        let wcStatus = tagged Invalid;
        if (rdmaRespHasAETH(bth.opcode)) begin
            wcStatus = genWorkCompStatusFromAETH(aeth);
            dynAssert(
                isValid(wcStatus),
                "isValid(wcStatus) assertion @ handleRetryResp() in mkRespHandleSQ",
                $format("wcStatus=", fshow(wcStatus), " should be valid")
            );
        end

        Bool isReadWR           = isReadWorkReq(curPendingWR.wr.opcode);
        Bool isAtomicWR         = isAtomicWorkReq(curPendingWR.wr.opcode);
        Bool respOpCodeSeqCheck = rdmaNormalRespOpCodeSeqCheck(preRdmaOpCodeReg, bth.opcode);
        Bool respMatchWorkReq   = rdmaRespMatchWorkReq(bth.opcode, curPendingWR.wr.opcode);

        let hasWorkComp = False;
        // TODO: handle extra dequeue pending WR
        let deqPendingWorkReqWhenErr = False;
        let needDmaWrite = False;
        let isFinalRespNormal = False;
        let shouldDiscardPayload = False;
        let wrAction = WR_ACT_UNKNOWN;
        case (wrAckType)
            WR_ACK_EXPLICIT_WHOLE, WR_ACK_EXPLICIT_PARTIAL: begin
                case (rdmaRespType)
                    RDMA_RESP_RETRY: begin
                        Bool isRetryExcErr = retryHandler.retryExcLimit(retryReason);
                        if (isRetryExcErr) begin
                            hasWorkComp  = True;
                            deqPendingWorkReqWhenErr = True;
                            wrAction     = WR_ACT_RETRY_EXC;
                            wcReqType    = WC_REQ_TYPE_ERR_PARTIAL_ACK;
                        end
                        else begin
                            wrAction = WR_ACT_EXPLICIT_RETRY;
                        end
                    end
                    RDMA_RESP_ERROR: begin
                        hasWorkComp = True;
                        deqPendingWorkReqWhenErr = True;
                        wrAction = WR_ACT_ERROR_RESP;
                    end
                    RDMA_RESP_NORMAL: begin
                        // Only update pre-opcode when normal response
                        preRdmaOpCodeReg <= bth.opcode;

                        if (!respMatchWorkReq || !respOpCodeSeqCheck) begin
                            hasWorkComp = True;
                            deqPendingWorkReqWhenErr = True;
                            wcStatus = tagged Valid IBV_WC_BAD_RESP_ERR;
                            wrAction = WR_ACT_BAD_RESP;
                            if (wrAckType == WR_ACK_EXPLICIT_PARTIAL) begin
                                wcReqType = WC_REQ_TYPE_ERR_PARTIAL_ACK;
                            end
                            else begin
                                wcReqType = WC_REQ_TYPE_ERR_FULL_ACK;
                            end
                        end
                        else begin
                            hasWorkComp  = workReqNeedWorkComp(curPendingWR.wr);
                            needDmaWrite = isReadWR || isAtomicWR;
                            isFinalRespNormal = True;
                            wrAction = WR_ACT_EXPLICIT_RESP;
                        end
                    end
                    default: begin end
                endcase
            end
            WR_ACK_COALESCE_NORMAL: begin
                hasWorkComp = workReqNeedWorkComp(curPendingWR.wr);
                wcStatus = hasWorkComp ? (tagged Valid IBV_WC_SUCCESS) : (tagged Invalid);
                isFinalRespNormal = True;
                wrAction = WR_ACT_COALESCE_RESP;
            end
            WR_ACK_COALESCE_RETRY: begin
                retryReason = RETRY_REASON_IMPLICIT;
                Bool isRetryExcErr  = retryHandler.retryExcLimit(retryReason);
                if (isRetryExcErr) begin
                    hasWorkComp = True;
                    wcStatus    = tagged Valid IBV_WC_RETRY_EXC_ERR;
                    wrAction    = WR_ACT_RETRY_EXC;
                    wcReqType   = WC_REQ_TYPE_ERR_PARTIAL_ACK;
                end
                else begin
                    wrAction = WR_ACT_IMPLICIT_RETRY;
                end
            end
            WR_ACK_DUPLICATE: begin
                // Discard duplicate responses
                shouldDiscardPayload = True;
                wrAction = WR_ACT_DUPLICATE_RESP;
            end
            WR_ACK_GHOST: begin
                // Discard ghost responses
                shouldDiscardPayload = True;
                wrAction = WR_ACT_GHOST_RESP;
            end
            WR_ACK_ILLEGAL: begin
                // Discard invalid responses
                shouldDiscardPayload = True;
                wcStatus = pktStatus2WorkCompStatusSQ(curPktMetaData.pktStatus);
                wrAction = WR_ACT_ILLEGAL_RESP;
            end
            WR_ACK_FLUSH: begin
                // Discard responses when retry or error flush
                shouldDiscardPayload = True;
                wrAction = WR_ACT_FLUSH_RESP;
            end
            default: begin end
        endcase

        dynAssert(
            wrAction != WR_ACT_UNKNOWN,
            "wrAction assertion @ mkRespHandleSQ",
            $format("wrAction=", fshow(wrAction), " should not be unknown")
        );
        // if (hasWorkComp || needDmaWrite || shouldDiscardPayload) begin
        pendingDmaReqQ.enq(tuple5(
            curPendingWR, curPktMetaData, wrAction, wcStatus, wcReqType
        ));
    endrule

    // Response handle pipeline third stage
    rule genWorkCompAndConsumePayload if (cntrl.isRTS || cntrl.isERR); // This rule still runs at retry or error state
        let {
            pendingWR, pktMetaData, wrAction, wcStatus, wcReqType
        } = pendingDmaReqQ.first;
        pendingDmaReqQ.deq;

        let rdmaHeader       = pktMetaData.pktHeader;
        let bth              = extractBTH(rdmaHeader.headerData);
        let atomicAckAeth    = extractAtomicAckEth(rdmaHeader.headerData);
        let pktPayloadLen    = pktMetaData.pktPayloadLen - zeroExtend(bth.padCnt);
        let isReadWR         = isReadWorkReq(pendingWR.wr.opcode);
        let isZeroWorkReqLen = isZero(pendingWR.wr.len);
        // let isNonZeroReadWR  = isReadWR && !isZeroWorkReqLen;
        let isAtomicWR       = isAtomicWorkReq(pendingWR.wr.opcode);
        // let isFirstOrMidPkt  = isFirstOrMiddleRdmaOpCode(bth.opcode);
        let isFirstPkt       = isFirstRdmaOpCode(bth.opcode);
        let isMidPkt         = isMiddleRdmaOpCode(bth.opcode);
        let isLastPkt        = isLastRdmaOpCode(bth.opcode);
        let isOnlyPkt        = isOnlyRdmaOpCode(bth.opcode);
        let needWorkComp     = workReqNeedWorkComp(pendingWR.wr);

        let genWorkComp   = False;
        let wcWaitDmaResp = False;
        case (wrAction)
            WR_ACT_BAD_RESP: begin
                genWorkComp = True;
            end
            WR_ACT_ERROR_RESP: begin
                genWorkComp = True;
            end
            WR_ACT_EXPLICIT_RESP: begin
                // No WC for the first and middle read response
                genWorkComp = needWorkComp && !(isFirstPkt || isMidPkt);

                if (isReadWR) begin
                    let remainingReadRespLen  = remainingReadRespLenReg;
                    let nextReadRespWriteAddr = nextReadRespWriteAddrReg;
                    let readRespPktNum        = readRespPktNumReg;
                    let oneAsPSN              = 1;

                    case ( { pack(isOnlyPkt), pack(isFirstPkt), pack(isMidPkt), pack(isLastPkt) } )
                        4'b1000: begin // isOnlyRdmaOpCode(bth.opcode)
                            remainingReadRespLen  = pendingWR.wr.len - zeroExtend(pktPayloadLen);
                            nextReadRespWriteAddr = pendingWR.wr.laddr;
                            readRespPktNum        = 1;
                        end
                        4'b0100, 4'b0010: begin // isFirstOrMiddleRdmaOpCode(bth.opcode)
                            remainingReadRespLen  = lenSubtractPsnMultiplyPMTU(remainingReadRespLenReg, oneAsPSN, cntrl.getPMTU);
                            nextReadRespWriteAddr = addrAddPsnMultiplyPMTU(nextReadRespWriteAddrReg, oneAsPSN, cntrl.getPMTU);
                            readRespPktNum        = readRespPktNumReg + 1;
                        end
                        4'b0001: begin // isLastRdmaOpCode(bth.opcode)
                            remainingReadRespLen  = lenSubtractPktLen(remainingReadRespLenReg, pktPayloadLen, cntrl.getPMTU);
                            // No need to calculate next DMA write address for last read responses
                            // nextReadRespWriteAddr = nextReadRespWriteAddrReg + zeroExtend(pktPayloadLen);
                            readRespPktNum        = readRespPktNumReg + 1;
                        end
                        default: begin end
                    endcase
                    remainingReadRespLenReg  <= remainingReadRespLen;
                    nextReadRespWriteAddrReg <= nextReadRespWriteAddr;
                    readRespPktNumReg        <= readRespPktNum;

                    let readRespLenMatch = True;
                    if ((isLastPkt || isOnlyPkt) && !isZero(remainingReadRespLen)) begin
                        // Read response length not match WR length
                        readRespLenMatch = False;
                        discardPayload(pktMetaData.pktFragNum);
                        wcStatus  = tagged Valid IBV_WC_LOC_LEN_ERR;
                        wcReqType = WC_REQ_TYPE_ERR_FULL_ACK;
                    end
                    else if (!isZeroWorkReqLen) begin
                        let payloadConReq = PayloadConReq {
                            initiator  : PAYLOAD_INIT_SQ_WR,
                            fragNum    : pktMetaData.pktFragNum,
                            consumeInfo: tagged ReadRespInfo DmaWriteMetaData {
                                sqpn        : cntrl.getSQPN,
                                startAddr   : nextReadRespWriteAddr,
                                len         : pktPayloadLen,
                                psn         : bth.psn
                            }
                        };
                        if (readRespLenMatch) begin
                            payloadConReqOutQ.enq(payloadConReq);
                            // payloadConsumer.request(payloadConReq);
                            wcWaitDmaResp = True;
                        end
                    end
                end
                else if (isAtomicWR) begin
                    let initiator = isAtomicWR ? PAYLOAD_INIT_SQ_ATOMIC : PAYLOAD_INIT_SQ_WR;
                    let atomicWriteReq = PayloadConReq {
                        initiator  : initiator,
                        fragNum    : 0,
                        consumeInfo: tagged AtomicRespInfoAndPayload tuple2(
                            DmaWriteMetaData {
                                sqpn     : cntrl.getSQPN,
                                startAddr: pendingWR.wr.laddr,
                                len      : truncate(pendingWR.wr.len),
                                psn      : bth.psn
                            },
                            atomicAckAeth.orig
                        )
                    };
                    payloadConReqOutQ.enq(atomicWriteReq);
                    // payloadConsumer.request(atomicWriteReq);
                    wcWaitDmaResp = True;
                end
            end
            WR_ACT_COALESCE_RESP: begin
                genWorkComp = needWorkComp;
            end
            WR_ACT_DUPLICATE_RESP: begin
                discardPayload(pktMetaData.pktFragNum);
            end
            WR_ACT_GHOST_RESP: begin
                discardPayload(pktMetaData.pktFragNum);
            end
            WR_ACT_ILLEGAL_RESP: begin
                genWorkComp = True;
                discardPayload(pktMetaData.pktFragNum);
            end
            WR_ACT_FLUSH_RESP: begin
                discardPayload(pktMetaData.pktFragNum);
            end
            WR_ACT_EXPLICIT_RETRY: begin end
            WR_ACT_IMPLICIT_RETRY: begin end
            WR_ACT_RETRY_EXC: begin
                genWorkComp = True;
            end
            default: begin end
        endcase

        if (genWorkComp) begin
            dynAssert(
                isValid(wcStatus),
                "isValid(wcStatus) assertion @ mkRespHandleSQ",
                $format(
                    "wcStatus=", fshow(wcStatus), " should be valid"
                )
            );
            let wcGenReq = WorkCompGenReqSQ {
                pendingWR: pendingWR,
                wcWaitDmaResp: wcWaitDmaResp,
                wcReqType: wcReqType,
                respPSN: bth.psn,
                wcStatus: unwrapMaybe(wcStatus)
            };
            workCompGenReqOutQ.enq(wcGenReq);
            // workCompGen.submitFromRespHandleInSQ(pendingWR, wcWaitDmaResp, wcs);
        end
    endrule

    // (* no_implicit_conditions, fire_when_enabled *)
    (* fire_when_enabled *)
    rule flushPktMetaDataAndPayload if (
        cntrl.isERR                          ||
        respHandleStateReg == SQ_ERROR_FLUSH || // Error flush
        respHandleStateReg == SQ_RETRY_FLUSH || // Retry flush
        respHandleStateReg == SQ_RETRY_FLUSH_AND_WAIT
    );
        if (pktMetaDataPipeIn.notEmpty) begin
            let pktMetaData = pktMetaDataPipeIn.first;
            pktMetaDataPipeIn.deq;

            PendingWorkReq emptyPendingWR = dontCareValue;
            let rdmaRespType = RDMA_RESP_UNKNOWN;
            let retryReason = RETRY_REASON_NOT_RETRY;
            let wrAckType = WR_ACK_FLUSH;
            let wcReqType = WC_REQ_TYPE_NO_WC;
            pendingRespQ.enq(tuple6(
                emptyPendingWR, pktMetaData, rdmaRespType,
                retryReason, wrAckType, wcReqType
            ));
        end
    endrule

    // (* no_implicit_conditions, fire_when_enabled *)
    (* fire_when_enabled *)
    rule retryNotify if (
        cntrl.isRTS && respHandleStateReg == SQ_RETRY_FLUSH
    );
        // When retry, the procedure is:
        // - retry flush incoming packets start;
        // - wait response handle pipeline empty;
        // - notify controller to start retry;
        // - recover from retry state by controller.

        // When retry then retry exceed limit error, the procedure is:
        // - retry flush incoming packets start;
        // - wait response handle pipeline empty;
        // - in the same cycle pipeline becomes empty, the controller enters error state;
        // - notify WC generator to start flush pending WR.

        // let respHandlePipelineEmpty = !(
        //     pendingRespQ.notEmpty ||
        //     pendingDmaReqQ.notEmpty
        // );
        if (cntrl.isRTS && respHandleStateReg == SQ_RETRY_FLUSH) begin
            // if (respHandlePipelineEmpty) begin
            retryHandler.notifyRetry(
                retryWorkReqIdReg,
                retryStartPsnReg,
                retryReasonReg,
                unwrapMaybe(retryRnrTimerReg)
            );
            // end

            respHandleStateReg <= SQ_RETRY_FLUSH_AND_WAIT;
        end

        // if (cntrl.isERR) begin // && respHandlePipelineEmpty
        //     // workCompGen.respHandlePipeEmptyInSQ;

        //     respHandleStateReg <= SQ_FLUSH_AND_WAIT;
        // end
    endrule

    // (* no_implicit_conditions, fire_when_enabled *)
    (* fire_when_enabled *)
    rule waitRetryDone if (
        cntrl.isRTS &&
        respHandleStateReg == SQ_RETRY_FLUSH_AND_WAIT
    );
        // Retry finished change state to normal handling
        if (retryHandler.isRetryDone) begin
            respHandleStateReg <= SQ_HANDLE_RESP_HEADER;
        end
    endrule

    interface payloadConReqPipeOut = convertFifo2PipeOut(payloadConReqOutQ);
    interface workCompGenReqPipeOut = convertFifo2PipeOut(workCompGenReqOutQ);
endmodule
