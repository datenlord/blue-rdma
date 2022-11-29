import CompletionBuffer :: *;
import FIFOF :: *;
import PAClib :: *;
import Printf :: *;
import Vector :: *;

import Controller :: *;
import ScanFIFO :: *;
import Settings :: *;
import Utils :: *;

// interface PipeOut #(type anytype);
//     method anytype first();
//     method Action deq();
//     method Bool notEmpty();
// endinterface

module mkWorkReqHandler#(
    Controller cntlr,
    FIFOF#(WorkReq) workReqQ
)(PipeOut#(WorkReq));
    ScanFIFO#(MAX_PENDING_REQ_NUM, WorkReq) pendingQ <- mkScanFIFO;
    Reg#(PendingReqCnt) pendingReqCnt <- mkReg(0);
    Bool isScanMode = !pendingQ.scanDone;
    Bool retryPulse = cntlr.getRetryPulse;

    function Bool checkPendingReqNum();
        return pendingReqCnt < cntlr.getPendingReqNumLimit;
    endfunction

    rule enq if (!isScanMode && checkPendingReqNum);
        let wr = workReqQ.first;
        workReqQ.deq;
        let startPSN = cntlr.getNPSN;
        wr.startPSN = startPSN;
        let { isOnlyReqPkt, pktNum, nextPSN, endPSN } = calcPktNumNextAndEndPSN(startPSN, wr.len, cntlr.getPMTU);
        cntlr.setNPSN(nextPSN);
        wr.endPSN = endPSN;
        pendingQ.enq(wr);
        pendingReqCnt <= pendingReqCnt + 1;
    endrule

    rule retryStart if (retryPulse);
        if (!pendingQ.notEmpty) begin
            $display("pendingQ.notEmpty=%b, cannot start scan", pending.notEmpty);
        end
        else begin
            pendingQ.scanStart;
        end
    endrule

    method WorkReq first();
        if (isScanMode) begin
            return pendingQ.scanCurrent;
        end
        else begin
            return pendingQ.first;
        end
    endmethod
    method Action deq();
        if (isScanMode) begin
            pendingQ.scanNext;
        end
        else begin
            pendingQ.deq;
            pendingReqCnt <= pendingReqCnt - 1;
        end
    endmethod
    method Bool notEmpty() = pendingQ.notEmpty;
endmodule

module mkRdmaReqHandler#(
    Controller cntlr,
    PipeOut#(WorkReq) workReqQ,
    DmaReadSrv dmaReadSrv
)(PipeOut#(RdmaReq));
    CompletionBuffer#(MAX_PENDING_REQ_NUM, RdmaReq) cbuff <- mkCompletionBuffer;
    Vector#(MAX_PENDING_REQ_NUM, Reg#(WorkReq)) wrbuff <- replicateM(mkRegU);
    FIFOF#(RdmaReq) rdmaReqQ <- mkFIFOF;

    rule sendDmaReadReq if (cntlr.isRTS);
        let token <- cbuff.reserve.get;
        let wr = workReqQ.first;
        workReqQ.deq;
        wrbuff[token] <= wr;
        let dmaReadReq = DmaReadReq {
            initiator: PAYLOAD_INIT_SQ_RD,
            sqpn: cntlr.getSQPN,
            startAddr: wr.startAddr,
            len: wr.len,
            token: token
        };
        dmaReadSrv.request.put(dmaReadReq);
    endrule

    rule recvDmaReadResp if (cntlr.isRTS);
        let dmaReadResp <- dmaReadSrv.response.get;
        let token = dmaReadResp.token;
        let wr = wrbuff[token];
        let rdmaReq = RdmaReq {
            // TODO: set RdmaOpCode accordingly
            opcode: SEND_FIRST,
            psn: wr.startPSN
        };
        cbuff.complete.put(tuple2(token, rdmaReq));
    endrule

    rule seqOutRdmaReq if (cntlr.isRTS);
        let rdmaReq <- cbuff.drain.get;
        rdmaReqQ.enq(rdmaReq);
    endrule

    method RdmaReq first() if (cntlr.isRTS) = rdmaReqQ.first;
    method Action deq() if (cntlr.isRTS) = rdmaReqQ.deq;
    method Bool notEmpty() if (cntlr.isRTS) = rdmaReqQ.notEmpty;
endmodule

module mkRdmaRespHandler#(
    Controller cntlr,
    PipeOut#(WorkReq) workReqQ,
    PipeOut#(RdmaResp) rdmaRespQ,
    DmaWriteSrv dmaWriteSrv
)(PipeOut#(WorkComp));
    typedef enum {
        RESP_NORMAL,
        RESP_RETRY,
        RESP_ERR
    } RespStatus derive(Bits, Eq);

    CompletionBuffer#(MAX_PENDING_REQ_NUM, WorkComp) cbuff <- mkCompletionBuffer;
    // Vector#(MAX_PENDING_REQ_NUM, Reg#(WorkReq)) wcbuff <- replicateM(mkRegU);
    FIFOF#(
        MAX_PENDING_REQ_NUM,
        Tuple3#(PendingReqToken, WorkComp, Bool)
    ) pendingWorkCompQ <- mkSizedFIFOF;
    FIFOF#(MAX_PENDING_REQ_NUM, RdmaREsp) validRdmaRespQ <- mkSizedFIFOF;
    FIFOF#(Tuple3#(RdmaResp, WorkReq, Maybe#(PendingReqToken))) dmaWriteReqQ <- mkFIFOF;
    FIFOF#(WorkComp) workCompQ <- mkFIFOF;
    Reg#(RespStatus) status <- mkReg(RESP_NORMAL);

    rule retryFlushRdmaResp if (status == RESP_RETRY);
        if (rdmaRespQ.notEmpty) begin
            rdmaRespQ.deq;
        end
        else begin
            cntlr.setRetryPulse;
            validRdmaRespQ.clear;
            status <= RESP_NORMAL;
        end
    endrule

    rule errFlushRdmaResp if (status == RESP_ERR);
        rdmaRespQ.deq;
    endrule

    rule errFlushWorkReq if (status == RESP_ERR)
        let wr = workReqQ.first;
        workReqQ.deq;
        if (wr.ackreq) begin
            let token <- cbuff.reserve.get;
            let wc = WorkComp { id: wr.id, status: WR_FLUSH_ERR };
            let needWaitForDmaWriteResp = False;
            pendingWorkCompQ.enq(tuple3(token, wc, needWaitForDmaWriteResp));
        end
    endrule

    // RDMA response handler pipeline
    rule verifyRdmaResp if (status == RESP_NORMAL);
        // TODO: verify RDMA response
        let resp = respQ.first;
        respQ.deq;
        validRdmaRespQ.enq();
    endrule

    rule ackRdmaRespAndWorkReq if (status == RESP_NORMAL);
        let resp = validRdmaRespQ.first;
        Bool canDeqResp = False;

        // TODO: verify ghost ACK will not incur bugs here
        if (workReqQ.notEmpty) begin
            let wr = workReqQ.first;
            let maybeToken = tagged Invalid;
            let mustExplicitAck = workReqMustExplicitAck(wr.opcode);
            let normalRdmaResp = isNormalRdmaResp(resp);
            let retryRdmaResp = isRetryRdmaResp(resp);
            let errRdmaResp = isErrRdmaResp(resp);

            Bool coalesce = False;
            Bool canDeqWR = False;
            Bool respMatchWorkReqStart = wr.startPSN == resp.psn;
            Bool respMatchWorkReqEnd = wr.endPSN == resp.psn;

            if (
                respMatchWorkReqStart || respMatchWorkReqEnd ||
                psnInRangeExclusive(resp.psn, wr.startPSN, wr.endPSN)
            ) begin
                canDeqWR = errRdmaResp || (normalRdmaResp && respMatchWorkReqEnd)
                canDeqResp = True;

                // TODO: for read WR, it's error NAK if regular response not read response
                if (retryRdmaResp) begin
                    status <= RESP_EXPLICIT_RETRY;
                end
                else if (errRdmaResp) begin
                    status <= RESP_ERR;
                end
            end
            // if (wr.endPSN == resp.psn) begin
            //     canDeqWR = normalRdmaResp || errRdmaResp;
            //     canDeqResp = True;

            //     if (retryRdmaResp) begin
            //         status <= RESP_EXPLICIT_RETRY;
            //     end
            //     else if (errRdmaResp) begin
            //         status <= RESP_ERR;
            //     end
            // end
            // else if (
            //     wr.startPSN == resp.psn ||
            //     psnInRangeExclusive(resp.psn, wr.startPSN, wr.endPSN)
            // ) begin
            //     canDeqWR = errRdmaResp;
            //     canDeqResp = True;

            //     if (retryRdmaResp) begin
            //         status <= RESP_EXPLICIT_RETRY;
            //     end
            //     else if (errRdmaResp) begin
            //         status <= RESP_ERR;
            //     end
            // end
            else if (psnInRangeExclusive(resp.psn, wr.endPSN, cntlr.getNPSN)) begin
                coalesce = True;
                if (mustExplicitAck) begin
                    // Implicit retry
                    status <= RESP_IMPLICIT_RETRY;
                end
                else begin
                    canDeqWR = True;
                end
            end
            // Ghost ACK
            else begin
                $display(
                    "Ghost ACK received: PSN=%h, nPSN=%h",
                    resp.psn, cntlr.getNPSN
                );
            end

            if (canDeqWR) begin
                workReqQ.deq;
                let needWorkComp = workReqNeedWorkComp(wr);
                if (errRdmaResp) begin
                    let token <- cbuff.reserve.get;
                    maybeToken = tagged Valid token;
                    let needWaitForDmaWriteResp = False;
                    // TODO: set WC error status accordingly
                    let wc = WorkComp { id: wr.id, status: REM_INV_REQ_ERR };
                    pendingWorkCompQ.enq(tuple3(token, wc, needWaitForDmaWriteResp));
                end
                else if (needWorkComp) begin
                    let token <- cbuff.reserve.get;
                    maybeToken = tagged Valid token;
                    let needWaitForDmaWriteResp = mustExplicitAck;

                    let wc = WorkComp { id: wr.id, status: SUCCESS };
                    pendingWorkCompQ.enq(tuple3(token, wc, needWaitForDmaWriteResp));
                end
            end

            if (canDeqResp && mustExplicitAck) begin
                dmaWriteReqQ.enq(Tuple3(resp, wr, maybeToken));
            end
        end
        else begin
            canDeqResp = True;
            $display("No pending WorkReq, ghost ACK received: PSN=%h", resp.psn);
        end

        if (canDeqResp) begin
            validRdmaRespQ.deq;
        end
    endrule

    rule sendDmaWriteReq;
        let { resp, wr, maybeToken } = dmaWriteReqQ.first;
        dmaWriteReqQ.deq;
        let dmaWriteReq = DmaWriteReq {
            initiator: PAYLOAD_INIT_SQ_WR,
            sqpn: cntlr.getSQPN,
            // TODO: set startAddr and len according to RDMA response
            startAddr: wr.startAddr,
            len: wr.len,
            maybeToken: maybeToken
        };
        dmaWriteSrv.request.put(dmaWriteReq);
    endrule

    rule waitDmaWriteResp;
        let { token, wc, needWaitForDmaWriteResp } = pendingWorkCompQ.first;
        pendingWorkCompQ.deq;

        if (needWaitForDmaWriteResp) begin
            let dmaWriteResp <- dmaWriteSrv.response.get;
            dynamicAssert(
                token == dmaWriteResp.token,
                sprintf(
                    "DmaWriteResp token=%h not match WC token=%h",
                    dmaWriteResp.token, token
                )
            );
            cbuff.complete.put(tuple2(token, wc));
        end
        else begin
            cbuff.complete.put(tuple2(token, wc));
        end
    endrule

    rule seqOutWorkComp;
        let wc <- cbuff.drain.get;
        workCompQ.enq(wc);
    endrule

    method WorkReq first() = workCompQ.first;
    method Action deq() = workCompQ.deq;
    method Bool notEmpty() = workCompQ.notEmpty;
endmodule

module mkSQ#(FIFOF#(WorkReq) workReqQ, Bool isRetry, Bool isErr)(PipeOut#(WorkComp));

    method Action deq() = workCompQ.deq;
    method WorkComp first() = workCompQ.first;
    method Bool notEmpty() = workCompQ.notEmpty;
endmodule
