import FIFOF :: *;
import PAClib :: *;

import Assertions :: *;
import DataTypes :: *;
import Headers :: *;
import InputBuffer :: *;
import ScanFIFOF :: *;

typedef enum {
    SQ_HANDLE_RESP_HEADER,
    // SQ_READ_RESP_DMA_WRITE,
    SQ_RETRY_FLUSH,
    // SQ_RETRY_NOTIFY,
    SQ_ERROR_FLUSH
} RespHandleState deriving(Bits, Eq);

// function WorkComp genWorkCompFromWorkReq(
//     Controller cntrl,
//     WorkReq wr,
//     WorkCompStatus wcStatus
// );
//     let wcOpCode = workReqOpCode2WorkCompOpCode4SQ(wr.opcode);
//     let wcFlags = workReqOpCode2WorkCompFlags(wr.opcode);

//     let wc = WorkComp {
//         id      : wr.id,
//         opcode  : fromMaybe(?, wcOpCode),
//         flags   : wcFlags,
//         status  : wcStatus,
//         len     : wr.len,
//         pkey    : cntrl.pkey,
//         dqpn    : cntrl.dqpn,
//         sqpn    : cntrl.sqpn,
//         immDt   : wr.immDt,
//         rkey2Inv: wr.rkey2Inv
//     };
//     return wc;
// endfunction

typedef enum {
    WR_ACK_TYPE_EXPLICIT_WHOLE,
    WR_ACK_TYPE_EXPLICIT_PARTIAL,
    WR_ACK_TYPE_COALESCE_NORMAL,
    WR_ACK_TYPE_COALESCE_RETRY,
    WR_ACK_TYPE_DUPLICATE,
    WR_ACK_TYPE_UNKNOWN
} WorkReqAckType deriving(Bits, Eq, FShow);

module mkRespHandleSQ#(
    Controller cntrl,
    PendingWorkReqBuf pendingWorkReqBuf,
    PipeOut#(RdmaPktMetaData) pktMetaDataPipeIn,
    // RdmaPktMetaDataAndPayloadPipeOut rdmaPktMetaDataAndPayloadPipeIn,
    PayloadConsumer payloadConsumer,
    WorkCompHandler workCompHandler
)(PipeOut#(WorkComp));
    // FIFOF#(WorkComp) workCompOutQ <- mkFIFOF;
    FIFOF#(Tuple5#(
        PendingWorkReq, RdmaPktMetaData, RdmaRespType, RetryReason, WorkReqAckType
    )) pendingRespQ <- mkFIFOF;
    FIFOF#(Tuple4#(
        PendingWorkReq, RdmaPktMetaData, Bool, Maybe#(WorkCompStatus)
    )) pendingDmaReqQ <- mkFIFOF;
    // FIFOF#(Tuple3#(PendingWorkReq, Bool, WorkCompFlags)) pendingWorkCompQ <-
    //     mkSizedFIFOF(valueOf(MAX_PENDING_REQ_NUM));

    Reg#(PSN)               retryStartPsnReg <- mkRegU;
    Reg#(WorkReqID)        retryWorkReqIdReg <- mkRegU;
    Reg#(RetryReason)         retryReasonReg <- mkRegU;
    Reg#(Length)     remainingReadRespLenReg <- mkRegU;
    Reg#(ADDR)      nextReadRespWriteAddrReg <- mkRegU;
    Reg#(PktNum)           readRespPktNumReg <- mkRegU; // TODO: remove it
    Reg#(RdmaOpCode)        preRdmaOpCodeReg <- mkReg(ACKNOWLEDGE);
    Reg#(RespHandleState) respHandleStateReg <- mkReg(SQ_HANDLE_RESP_HEADER);

    // TODO: check discard duplicate or ghost reponses has
    // no response from PayloadConsumer will not incur bugs.
    function Action discardPayloadReq(PmtuFragNum fragNum);
        action
            if (!isZero(fragNum)) begin
                let discardReq = PayloadConReq {
                    initiator       : PAYLOAD_INIT_SQ_DISCARD,
                    fragNum         : fragNum,
                    dmaWriteMetaData: tagged Invalid
                };
                payloadConsumer.request.put(discardReq);
            end
        endaction
    endfunction

    // Response handle pipeline first stage
    rule recvRespHeader if (
        cntrl.isRTRorRTS           &&
        pendingWorkReqBuf.fifoF.notEmpty &&
        respHandleStateReg == SQ_HANDLE_RESP_HEADER
    );
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
        PSN startPSN  = fromMaybe(?, curPendingWR.startPSN);
        PSN endPSN    = fromMaybe(?, curPendingWR.endPSN);
        PktNum pktNum = fromMaybe(?, curPendingWR.pktNum);
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

        if (!curPktMetaData.pktValid) begin // Discard invalid packet
            pktMetaDataPipeIn.deq;
            discardPayloadReq(curPktMetaData.pktFragNum);
        end
        else begin
            // This stage needs to do:
            // - dequeue pending WR when normal response;
            // - change to flush state if retry or error response
            let wrAckType = WR_ACK_TYPE_UNKNOWN;
            let shouldDeqPktMetaData = True
            let deqPendingWorkReqWithNormalResp = False;
            if (bth.opcode == endPSN) begin // Response to whole WR
                wrAckType = WR_ACK_TYPE_EXPLICIT_WHOLE;

                case (rdmaRespType)
                    RDMA_RESP_RETRY: begin
                        respHandleStateReg <= SQ_RETRY_FLUSH;
                        retryStartPsnReg   <= bth.psn;
                        retryWorkReqIdReg  <= curPendingWR.wr.id;
                        retryReasonReg     <= retryReason;
                    end
                    RDMA_RESP_ERROR: begin
                        respHandleStateReg <= SQ_ERROR_FLUSH;
                    end
                    RDMA_RESP_NORMAL: begin
                        deqPendingWorkReqWithNormalResp = True;
                    end
                    default: begin end
                endcase
            end
            else if (psnInRangeExclusive(bth.opcode, endPSN, nextPSN)) begin // Coalesce ACK
                shouldDeqPayload = False;

                if (isReadOrAtomicWorkReq(curPendingWR.wr.opcode)) begin // Implicit retry
                    wrAckType           = WR_ACK_TYPE_COALESCE_RETRY;
                    respHandleStateReg <= SQ_RETRY_FLUSH;
                    retryStartPsnReg   <= startPSN;
                    retryWorkReqIdReg  <= curPendingWR.wr.id;
                    retryReasonReg     <= RETRY_REASON_IMPLICIT;
                end
                else begin
                    wrAckType = WR_ACK_TYPE_COALESCE_NORMAL;
                    deqPendingWorkReqWithNormalResp = True;
                end
            end
            else if (bth.opcode == startPSN || psnInRangeExclusive(bth.opcode, startPSN, endPSN)) begin
                wrAckType = WR_ACK_TYPE_EXPLICIT_PARTIAL;

                case (rdmaRespType)
                    RDMA_RESP_RETRY: begin
                        respHandleStateReg <= SQ_RETRY_FLUSH;
                        retryStartPsnReg   <= bth.psn;
                        retryWorkReqIdReg  <= curPendingWR.wr.id;
                        retryReasonReg     <= retryReason;
                    end
                    RDMA_RESP_ERROR: begin
                        respHandleStateReg <= SQ_ERROR_FLUSH;
                    end
                    RDMA_RESP_NORMAL: begin end
                    default         : begin end
                endcase
            end
            else begin // Duplicated responses
                wrAckType = WR_ACK_TYPE_DUPLICATE;
                discardPayloadReq(curPktMetaData.pktFragNum);
            end

            dynAssert(
                wrAckType != WR_ACK_TYPE_UNKNOWN,
                "wrAckType assertion @ mkRespHandleSQ",
                $format("wrAckType=", fshow(wrAckType), " should not be unknown")
            );
            pendingRespQ.enq(tuple5(
                curPendingWR, curPktMetaData, rdmaRespType, retryReason, wrAckType
            ));
            if (shouldDeqPayload) begin
                pktMetaDataPipeIn.deq;
            end
            if (deqPendingWorkReqWithNormalResp) begin
                pendingWorkReqBuf.fifoF.deq;
                cntrl.resetRetryCnt;
            end
        end
    endrule

    // Response handle pipeline second stage
    rule handleRespByType if (cntrl.isRTRorRTS); // This rule still runs at retry state
        let { curPendingWR, curPktMetaData, rdmaRespType, retryReason, wrAckType } = pendingRespQ.first;
        pendingRespQ.deq;

        // let curRdmaHeader = curPktMetaData.pktHeader;
        // let bth           = extractBTH(curRdmaHeader.headerData);
        // let aeth          = extractAETH(curRdmaHeader.headerData);
        // let retryReason   = getRetryReasonFromAETH(aeth);

        let wcStatus = tagged Invalid;
        if (rdmaRespHasAETH(bth.opcode)) begin
            wcStatus = genWorkCompStatusFromAETH(aeth);
            dynAssert(
                isValid(wcStatus),
                "isValid(wcStatus) assertion @ handleRetryResp() in mkRespHandleSQ",
                $format("wcStatus=", fshow(wcStatus), " should be valid")
            );
        end
        // let wcRetryErrStatus = getErrWorkCompStatusFromRetryReason(retryReason);

        Bool isReadWR           = isReadWorkReq(curPendingWR.wr.opcode);
        Bool isAtomicWR         = isAtomicWorkReq(curPendingWR.wr.opcode);
        Bool respOpCodeSeqCheck = rdmaNormalRespOpCodeSeqCheck(preOpCodeReg, bth.opcode);
        Bool respMatchWorkReq   = rdmaRespMatchWorkReq(bth.opcode, curPendingWR.wr.opcode);

        let hasWorkComp = False;
        let deqPendingWorkReqWhenErr = False;
        let needDmaWrite = False;
        let isFinalRespNormal = False;
        case (wrAckType)
            WR_ACK_TYPE_EXPLICIT_WHOLE, WR_ACK_TYPE_EXPLICIT_PARTIAL: begin
                case (rdmaRespType)
                    RDMA_RESP_RETRY: begin
                        Bool isRetryExceed  = cntrl.retryExceedLimit(retryReason);
                        cntrl.decRetryCnt(retryReason);
                        if (isRetryExceed) begin
                            hasWorkComp = True;
                            deqPendingWorkReqWhenErr = True;
                        end
                    end
                    RDMA_RESP_ERROR: begin
                        hasWorkComp = True;
                        deqPendingWorkReqWhenErr = True;
                    end
                    RDMA_RESP_NORMAL: begin
                        // Only update pre-opcode when normal response
                        preRdmaOpCodeReg <= bth.opcode;

                        if (!respMatchWorkReq || !respOpCodeSeqCheck) begin
                            hasWorkComp = True;
                            deqPendingWorkReqWhenErr = True;
                            wcStatus = tagged Valid IBV_WC_BAD_RESP_ERR;
                        end
                        else begin
                            hasWorkComp = curPendingWR.wr.ackReq;
                            needDmaWrite = isReadWR || isAtomicWR;
                            isFinalRespNormal = True;
                        end
                    end
                    default: begin end
                endcase
            end
            WR_ACK_TYPE_COALESCE_NORMAL: begin
                hasWorkComp = curPendingWR.wr.ackReq;
                wcStatus = hasWorkComp ? (tagged Valid IBV_WC_SUCCESS) : (tagged Invalid);
                isFinalRespNormal = True;
            end
            WR_ACK_TYPE_COALESCE_RETRY: begin
                retryReason = RETRY_REASON_IMPLICIT;
                Bool isRetryExceed  = cntrl.retryExceedLimit(retryReason);
                cntrl.decRetryCnt(retryReason);
                if (isRetryExceed) begin
                    hasWorkComp = True;
                    wcStatus = tagged Valid IBV_WC_RETRY_EXC_ERR;
                end
            end
            WR_ACK_TYPE_DUPLICATE: begin
                // Discard duplicate responses
            end
            default: begin end
        endcase

        if (hasWorkComp || needDmaWrite) begin
            pendingDmaReqQ.enq(tuple4(
                curPendingWR, curPktMetaData, isFinalRespNormal, wcStatus
            ));
        end
    endrule

    // Response handle pipeline third stage
    rule genWorkCompAndInitDmaWrite if (cntrl.isRTRorRTS); // This rule still runs at retry state
        let { pendingWR, pktMetaData, isFinalRespNormal, wcStatus } = pendingDmaReqQ.first;
        pendingDmaReqQ.deq;

        let rdmaHeader       = pktMetaDataReg.pktHeader;
        let bth              = extractBTH(rdmaHeader.headerData);
        let atomicAckAeth    = extractAtomicAckEth(rdmaHeader.headerData);
        let pktPayloadLen    = pktMetaDataReg.pktPayloadLen - zeroExtend(bth.padCnt);
        let isReadWR         = isReadWorkReq(pendingWR.wr.opcode);
        let isZeroWorkReqLen = isZero(pendingWR.wr.len);
        let isNonZeroReadWR  = isReadWR && !isZeroWorkReqLen;
        let isAtomicWR       = isAtomicWorkReq(pendingWR.wr.opcode);
        let isFirstOrMidPkt  = isFirstOrMiddleRdmaOpCode(bth.opcode);
        let needWorkComp     = pendingWR.wr.ackReq;

        let wcWaitDmaResp = False;
        if (isFinalRespNormal) begin
            if (isNonZeroReadWR) begin
                let remainingReadRespLen  = remainingReadRespLenReg;
                let nextReadRespWriteAddr = nextReadRespWriteAddrReg;
                let readRespPktNum        = readRespPktNumReg;
                let oneAsPSN              = 1;

                case ( {
                    pack(isOnlyRdmaOpCode(bth.opcode)), pack(isFirstRdmaOpCode(bth.opcode)),
                    pack(isMiddleRdmaOpCode(bth.opcode)), pack(isLastRdmaOpCode(bth.opcode))
                } )
                    4'b1000: begin // isOnlyRdmaOpCode(bth.opcode)
                        remainingReadRespLen  = pendingWorkReqReg.wr.len - pktPayloadLen;
                        nextReadRespWriteAddr = pendingWorkReqReg.wr.laddr;
                        readRespPktNum        = 1;
                    end
                    4'b0100, 4'b0010: begin // isFirstOrMiddleRdmaOpCode(bth.opcode)
                        remainingReadRespLen  = lenSubtractPsnMultiplyPMTU(remainingReadRespLenReg, oneAsPSN, cntrl.getPMTU);
                        nextReadRespWriteAddr = addrAddPsnMultiplyPMTU(nextReadRespWriteAddrReg, oneAsPSN, cntrl.getPMTU);
                        readRespPktNum        = readRespPktNumReg + 1;
                    end
                    4'b0001: begin // isLastRdmaOpCode(bth.opcode)
                        remainingReadRespLen  = remainingReadRespLenReg - pktPayloadLen;
                        nextReadRespWriteAddr = nextReadRespWriteAddrReg + pktPayloadLen;
                        readRespPktNum        = readRespPktNumReg + 1;
                    end
                    default: begin end
                endcase
                remainingReadRespLenReg  <= remainingReadRespLen;
                nextReadRespWriteAddrReg <= nextReadRespWriteAddr;
                readRespPktNumReg        <= readRespPktNum;

                let initReadRespDmaWrite = True;
                if (isLastOrOnlyRdmaOpCode(bth.opcode)) begin
                    dynAssert(
                        ackWholeWR,
                        "ackWholeWR assertion @ mkRespHandleSQ",
                        $format(
                            "ackWholeWR=%b should be true when bth.opcode=",
                            ackWholeWR, fshow(bth.opcode),
                            " is last or only read response"
                        )
                    );

                    if (!isZero(remainingReadRespLen)) begin
                        // Read response length not match WR length
                        wcStatus = tagged Valid IBV_WC_LOC_LEN_ERR;
                        initReadRespDmaWrite = False;
                    end
                end

                let payloadConsumeReq = PayloadConReq {
                    initiator       : PAYLOAD_INIT_SQ_WR,
                    fragNum         : pktMetaData.pktFragNum,
                    dmaWriteMetaData: DmaWriteReq {
                        sqpn        : cntrl.getSQPN,
                        startAddr   : nextReadRespWriteAddr,
                        len         : pktPayloadLen,
                        inlineData  : tagged Invalid,
                        psn         : bth.opcode
                    }
                };
                if (initReadRespDmaWrite) begin
                    payloadConsumer.request.put(payloadConsumeReq);
                    wcWaitDmaResp = True;
                end
            end
            else if (isAtomicWR) begin
                let initiator = isAtomicWR ? PAYLOAD_INIT_SQ_ATOMIC : PAYLOAD_INIT_SQ_WR;
                let atomicWriteReq = PayloadConReq {
                    initiator         : initiator,
                    fragNum           : 0,
                    dmaWriteMetaData  : tagged Valid DmaWriteReq {
                        sqpn          : cntrl.getSQPN,
                        startAddr     : pendingWR.wr.laddr,
                        len           : pendingWR.wr.len,
                        data          : tagged Valid atomicAckAeth.orig,
                        psn           : bth.opcode
                    }
                };
                payloadConsumer.request.put(atomicWriteReq);
                wcWaitDmaResp = True;
            end
        end

        // No WC for the first and middle read response
        if (!(isReadWR && isFirstOrMidPkt)) begin
            dynAssert(
                isValid(wcStatus),
                "isValid(wcStatus) assertion @ mkRespHandleSQ",
                $format(
                    "wcStatus=", fshow(wcStatus), " should be valid"
                )
            );
            let wcs = fromMaybe(?, wcStatus);
            workCompHandler.submitFromRespHandleInSQ(pendingWR, wcWaitDmaResp, wcs);
            // pendingWorkCompQ.enq(tuple3(pendingWR, wcWaitDmaResp, wcs));
        end
    endrule
/*
    // Response handle pipeline fourth stage
    rule outputWorkComp if (cntrl.isRTRorRTS); // This rule still runs at retry state
        let { pendingWR, wcWaitDmaResp, wcStatus } = pendingWorkCompQ.first;
        let workComp = genWorkCompFromWorkReq(cntrl, pendingWR.wr, wcStatus);

        // Change to error state if error WC or CQ full
        if (wcStatus != IBV_WC_SUCCESS || !workCompOutQ.notFull) begin
            cntrl.setStateErr;

            if (!workCompOutQ.notFull) begin
                // TODO: async event to report CQ full
            end

            dynAssert(
                !wcWaitDmaResp,
                "wcWaitDmaResp assertion @ mkRespHandleSQ",
                $format(
                    "wcWaitDmaResp=", fshow(wcWaitDmaResp),
                    " should be false when wcStatus=", fshow(wcStatus)
                )
            );
        end

        let endPSN = fromMaybe(?, pendingWR.endPSN);
        if (wcWaitDmaResp) begin
            // TODO: report error if waiting too long for DMA write response
            let payloadConsumeResp <- payloadConsumer.response.get;
            if (payloadConsumeResp.dmaWriteResp.psn == endPSN) begin
                pendingWorkCompQ.deq;
                workCompOutQ.enq(workComp);
            end
        end
        else begin
            pendingWorkCompQ.deq;
            workCompOutQ.enq(workComp);
        end
    endrule

    rule flushPendingWorkReq if (cntrl.isERR);
        let pendingWR = pendingWorkReqBuf.fifoF.first;
        pendingWorkReqBuf.fifoF.deq;

        let wcWaitDmaResp = False;
        pendingWorkCompQ.enq(tuple3(pendingWR, wcWaitDmaResp, IBV_WC_WR_FLUSH_ERR));

        respHandleStateReg <= RecvRespHeader;
        respHeaderQ.clear;
    endrule
*/
    rule flushPktMetaData if (
        cntrl.isERR || respHandleStateReg == SQ_ERROR_FLUSH || // Error flush
        respHandleStateReg == SQ_RETRY_FLUSH                || // Retry flush
        !pendingWorkReqBuf.fifoF.notEmpty                      // Discard ghost responses
    );
        if (pktMetaDataPipeIn.notEmpty) begin
            pktMetaDataPipeIn.deq;
        end

        let allPipeEmpty = !(
            pktMetaDataPipeIn.notEmpty ||
            pendingRespQ.notEmpty ||
            pendingDmaReqQ.notEmpty
            // pendingWorkCompQ.notEmpty
        );
        if (cntrl.isERR && allPipeEmpty) begin
            workCompHandler.respHandlePipeEmptyInSQ;
        end

        // TODO: handle RNR waiting
        if (
            cntrl.isRTRorRTS &&
            respHandleStateReg == SQ_RETRY_FLUSH
        ) begin
            let curPendingWR = pendingWorkReqBuf.fifoF.first;
            dynAssert(
                retryWorkReqIdReg == curPendingWR.wr.id,
                "retryWorkReqIdReg assertion @ mkRespHandleSQ",
                $format(
                    "retryWorkReqIdReg=%h should == curPendingWR.wr.id=%h",
                    retryWorkReqIdReg, curPendingWR.wr.id
                )
            );

            let startPSN = fromMaybe(?, curPendingWR.startPSN);
            let wrLen = curPendingWR.wr.len;
            let laddr = curPendingWR.wr.laddr;
            let psnDiff = psnDiff(retryStartPsnReg, startPSN);
            let retryWorkReqLen = lenSubtractPsnMultiplyPMTU(wrLen, psnDiff, cntrl.getPMTU);
            let retryWorkReqAddr = addrAddPsnMultiplyPMTU(laddr, psnDiff, cntrl.getPMTU);

            // All pending responses handled, then retry flush finishes,
            // change state to normal handling
            if (allPipeEmpty) begin
                cntrl.setRetryPulse(
                    retryWorkReqIdReg,
                    retryStartPsnReg,
                    retryWorkReqLen,
                    retryWorkReqAddr,
                    retryReasonReg
                );
                respHandleStateReg <= SQ_HANDLE_RESP_HEADER;
            end
        end
    endrule

    return convertFifo2PipeOut(workCompOutQ);
endmodule
