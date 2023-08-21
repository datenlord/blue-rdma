import Arbitration :: *;
import BRAMFIFO :: *;
import ClientServer :: *;
import Connectable :: *;
import FIFOF :: *;
import GetPut :: *;
import PAClib :: *;
import Vector :: *;

import Controller :: *;
import DataTypes :: *;
import Headers :: *;
import PrimUtils :: *;
import Utils :: *;

typedef struct {
    ADDR   startAddr;
    Length totalLen;
    PMTU   pmtu;
} AddrChunkReq deriving(Bits, FShow);

typedef struct {
    ADDR   dmaAddr;
    PktLen dmaLen;
    Bool   isFirst;
    Bool   isLast;
    // Bool hasOffset;
} AddrChunkResp deriving(Bits, FShow);

// typedef Server#(AddrChunkReq, AddrChunkResp) AddrChunkSrv;
interface AddrChunkSrv;
    interface Server#(AddrChunkReq, AddrChunkResp) srvPort;
    method Bool isIdle();
endinterface

module mkAddrChunkSrv#(Bool clearAll)(AddrChunkSrv);
    FIFOF#(AddrChunkReq)   reqQ <- mkFIFOF;
    FIFOF#(AddrChunkResp) respQ <- mkFIFOF;

    Reg#(PktLen)   fullPktLenReg <- mkRegU;
    Reg#(PmtuResidue) residueReg <- mkRegU;
    Reg#(Bool)  isZeroResidueReg <- mkRegU;

    Reg#(PktNum)     pktNumReg <- mkRegU;
    Reg#(ADDR)      dmaAddrReg <- mkRegU;
    Reg#(PMTU)         pmtuReg <- mkRegU;
    Reg#(Bool)         busyReg <- mkReg(False);
    Reg#(Bool)      isFirstReg <- mkReg(False);

    rule resetAndClear if (clearAll);
        reqQ.clear;
        respQ.clear;
        busyReg <= False;
        isFirstReg <= False;
    endrule

    rule recvReq if (!clearAll && !busyReg);
        let addrChunkReq = reqQ.first;
        reqQ.deq;

        immAssert(
            !isZero(addrChunkReq.totalLen),
            "totalLen assertion @ mkAddrChunkSrv",
            $format(
                "totalLen=%0d cannot be zero", addrChunkReq.totalLen
            )
        );

        let { tmpPktNum, pmtuResidue } = truncateLenByPMTU(
            addrChunkReq.totalLen, addrChunkReq.pmtu
        );
        let isZeroResidue = isZeroR(pmtuResidue);
        let totalPktNum = tmpPktNum + (isZeroResidue ? 0 : 1);
        let pmtuLen = calcPmtuLen(addrChunkReq.pmtu);

        fullPktLenReg    <= pmtuLen;
        residueReg       <= pmtuResidue;
        isZeroResidueReg <= isZeroResidue;
        pktNumReg        <= totalPktNum;
        dmaAddrReg       <= addrChunkReq.startAddr;
        pmtuReg          <= addrChunkReq.pmtu;
        busyReg          <= True;
        isFirstReg       <= True;

        // $display(
        //     "time=%0t: recvReq", $time,
        //     ", totalPktNum=%0d", totalPktNum,
        //     ", pmtuResidue=%0d", pmtuResidue,
        //     ", addrChunkReq=", fshow(addrChunkReq)
        // );
    endrule

    rule genResp if (!clearAll && busyReg);
        let isLast = isLessOrEqOneR(pktNumReg);
        let oneAsPSN = 1;

        busyReg    <= !isLast;
        pktNumReg  <= pktNumReg - 1;
        isFirstReg <= False;
        dmaAddrReg <= addrAddPsnMultiplyPMTU(dmaAddrReg, oneAsPSN, pmtuReg);

        let addrChunkResp = AddrChunkResp {
            dmaAddr: dmaAddrReg,
            dmaLen : (isLast && !isZeroResidueReg) ? zeroExtend(residueReg) : fullPktLenReg,
            isFirst: isFirstReg,
            isLast : isLast
        };
        respQ.enq(addrChunkResp);

        // $display(
        //     "time=%0t: genResp", $time,
        //     ", pktNumReg=%0d", pktNumReg,
        //     ", dmaAddrReg=%h", dmaAddrReg,
        //     ", addrChunkResp=", fshow(addrChunkResp)
        // );
    endrule

    interface srvPort = toGPServer(reqQ, respQ);
    method Bool isIdle() = !busyReg && !reqQ.notEmpty && !respQ.notEmpty;
endmodule

typedef struct {
    DmaReadReq dmaReadReq;
    PMTU pmtu;
} DmaReadCntrlReq deriving(Bits, FShow);

typedef struct {
    DmaReadResp dmaReadResp;
    Bool isOrigFirst;
    Bool isOrigLast;
} DmaReadCntrlResp deriving(Bits, FShow);

typedef Server#(DmaReadCntrlReq, DmaReadCntrlResp) DmaCntrlReadSrv;

interface DmaCntrl;
    method Bool isIdle();
    method Action cancel();
endinterface

interface DmaReadCntrl2;
    interface DmaCntrlReadSrv srvPort;
    interface DmaCntrl dmaCntrl;
endinterface

module mkDmaReadCntrl2#(
    Bool clearAll,
    // CntrlStatus cntrlStatus,
    DmaReadSrv dmaReadSrv
)(DmaReadCntrl2);
    FIFOF#(DmaReadCntrlReq)   reqQ <- mkFIFOF;
    FIFOF#(DmaReadCntrlResp) respQ <- mkFIFOF;

    FIFOF#(DmaReadCntrlReq) pendingDmaCntrlReqQ <- mkFIFOF;
    FIFOF#(DmaReadReq)       pendingDmaReadReqQ <- mkFIFOF;
    FIFOF#(Bool)              firstDmaReqChunkQ <- mkFIFOF;
    FIFOF#(Bool)               lastDmaReqChunkQ <- mkFIFOF;

    let addrChunkSrv <- mkAddrChunkSrv(clearAll); // cntrlStatus.comm.isReset);

    Reg#(Bool) gracefulStopReg <- mkReg(False);
    Reg#(Bool)       cancelReg <- mkReg(False);

    rule resetAndClear if (clearAll); // if (cntrlStatus.comm.isReset);
        reqQ.clear;
        respQ.clear;

        pendingDmaCntrlReqQ.clear;
        pendingDmaReadReqQ.clear;
        firstDmaReqChunkQ.clear;
        lastDmaReqChunkQ.clear;

        cancelReg       <= False;
        gracefulStopReg <= False;
    endrule

    rule recvReq if (
        !clearAll && !cancelReg
        // (cntrlStatus.comm.isNonErr || cntrlStatus.comm.isERR) && !cancelReg
    );
        let dmaReadCntrlReq = reqQ.first;
        reqQ.deq;
        pendingDmaCntrlReqQ.enq(dmaReadCntrlReq);

        let addrChunkReq = AddrChunkReq {
            startAddr: dmaReadCntrlReq.dmaReadReq.startAddr,
            totalLen : dmaReadCntrlReq.dmaReadReq.len,
            pmtu     : dmaReadCntrlReq.pmtu
        };
        addrChunkSrv.srvPort.request.put(addrChunkReq);
    endrule

    rule issueDmaReq if (
        !clearAll && !cancelReg
        // (cntrlStatus.comm.isNonErr || cntrlStatus.comm.isERR) && !cancelReg
    );
        let addrChunkResp <- addrChunkSrv.srvPort.response.get;

        let pendingDmaReadCntrlReq = pendingDmaCntrlReqQ.first;

        let dmaReadReq       = pendingDmaReadCntrlReq.dmaReadReq;
        dmaReadReq.startAddr = addrChunkResp.dmaAddr;
        dmaReadReq.len       = zeroExtend(addrChunkResp.dmaLen);

        dmaReadSrv.request.put(dmaReadReq);
        pendingDmaReadReqQ.enq(dmaReadReq);

        let isFirstDmaReqChunk = addrChunkResp.isFirst;
        firstDmaReqChunkQ.enq(isFirstDmaReqChunk);
        let isLastDmaReqChunk = addrChunkResp.isLast;
        lastDmaReqChunkQ.enq(isLastDmaReqChunk);

        if (isLastDmaReqChunk) begin
            pendingDmaCntrlReqQ.deq;
        end
    endrule

    rule recvDmaResp if (!clearAll); // if (cntrlStatus.comm.isNonErr || cntrlStatus.comm.isERR);
        let dmaResp <- dmaReadSrv.response.get;

        let isFirstDmaReqChunk = firstDmaReqChunkQ.first;
        let isOrigFirst = dmaResp.dataStream.isFirst && isFirstDmaReqChunk;

        let isLastDmaReqChunk = lastDmaReqChunkQ.first;
        let isOrigLast = dmaResp.dataStream.isLast && isLastDmaReqChunk;

        let dmaReadCntrlResp = DmaReadCntrlResp {
            dmaReadResp: dmaResp,
            isOrigFirst: isOrigFirst,
            isOrigLast : isOrigLast
        };
        respQ.enq(dmaReadCntrlResp);

        if (dmaResp.dataStream.isLast) begin
            pendingDmaReadReqQ.deq;
            firstDmaReqChunkQ.deq;
            lastDmaReqChunkQ.deq;
        end
    endrule

    rule wait4GracefulStop if (
        cancelReg                    &&
        !gracefulStopReg             &&
        !respQ.notEmpty              &&
        !pendingDmaReadReqQ.notEmpty &&
        !clearAll
        // (cntrlStatus.comm.isNonErr || cntrlStatus.comm.isERR)
    );
        gracefulStopReg <= True;
        // $display(
        //     "time=%0t: DmaReadCntrl cancel read done", $time,
        //     ", sqpn=%h", cntrlStatus.comm.getSQPN,
        //     ", isSQ=", fshow(cntrlStatus.isSQ)
        // );
    endrule

    interface srvPort = toGPServer(reqQ, respQ);

    interface dmaCntrl = interface DmaCntrl;
        method Action cancel() if (!clearAll); // if (cntrlStatus.comm.isNonErr || cntrlStatus.comm.isERR);
            cancelReg       <= True;
            gracefulStopReg <= False;
        endmethod

        method Bool isIdle() = gracefulStopReg;
    endinterface;
endmodule

interface DmaReadCntrl;
    interface DmaReadSrv srvPort;
    interface DmaCntrl dmaCntrl;
endinterface

module mkDmaReadCntrl#(
    CntrlStatus cntrlStatus,
    DmaReadSrv dmaReadSrv
)(DmaReadCntrl);
    FIFOF#(DmaReadReq)   dmaReqQ <- mkFIFOF;
    FIFOF#(DmaReadResp) dmaRespQ <- mkFIFOF;

    Reg#(DmaReadReq) pendingReqReg <- mkRegU;
    Reg#(Bool)      busyReg <- mkReg(False);
    Reg#(Bool) cancelReg[2] <- mkCReg(2, False);

    rule issueReq if (!cancelReg[1] && !busyReg);
        let dmaReq = dmaReqQ.first;
        dmaReqQ.deq;

        dmaReadSrv.request.put(dmaReq);
        pendingReqReg <= dmaReq;
        busyReg <= True;
    endrule

    rule recvResp if (!cancelReg[1] && busyReg);
        let dmaResp <- dmaReadSrv.response.get;
        dmaRespQ.enq(dmaResp);
        busyReg <= !dmaResp.dataStream.isLast;
    endrule

    rule discardResp if (cancelReg[1] && busyReg);
        let dmaResp <- dmaReadSrv.response.get;
        // $display(
        //     "time=%0t: DmaReadCntrl discard read response", $time,
        //     ", sqpn=%h", cntrlStatus.comm.getSQPN,
        //     ", isSQ=", fshow(cntrlStatus.isSQ)
        // );

        if (dmaResp.dataStream.isLast) begin
            busyReg <= False;
            cancelReg[1] <= False;

            // $display(
            //     "time=%0t: DmaReadCntrl cancel read done", $time,
            //     ", sqpn=%h", cntrlStatus.comm.getSQPN,
            //     ", isSQ=", fshow(cntrlStatus.isSQ)
            // );
        end
    endrule

    rule clearCancel if (cancelReg[1] && !busyReg);
        cancelReg[1] <= False;
        // $display(
        //     "time=%0t: DmaReadCntrl no read to cancel", $time,
        //     ", sqpn=%h", cntrlStatus.comm.getSQPN,
        //     ", isSQ=", fshow(cntrlStatus.isSQ)
        // );
    endrule

    rule clearQ if (cancelReg[1]);
        dmaReqQ.clear;
        dmaRespQ.clear;
    endrule

    interface srvPort = toGPServer(dmaReqQ, dmaRespQ);

    interface dmaCntrl = interface DmaCntrl;
        method Action cancel();
            cancelReg[0] <= True;
        endmethod

        method Bool isIdle() = !busyReg && !dmaReqQ.notEmpty && !dmaRespQ.notEmpty;
    endinterface;
endmodule

interface DmaWriteCntrl;
    interface DmaWriteSrv srvPort;
    interface DmaCntrl dmaCntrl;
endinterface

typedef enum {
    DMA_WRITE_CNTRL_IDLE,
    DMA_WRITE_CNTRL_SEND_REQ,
    DMA_WRITE_CNTRL_WAIT_RESP
} DmaWriteCntrlState deriving(Bits, Eq);

// TODO: merge DMA write control logic into DMAC
module mkDmaWriteCntrl#(
    CntrlStatus cntrlStatus,
    DmaWriteSrv dmaWriteSrv
)(DmaWriteCntrl);
    FIFOF#(DmaWriteReq)   dmaReqQ <- mkFIFOF;
    FIFOF#(DmaWriteResp) dmaRespQ <- mkFIFOF;

    Reg#(DmaWriteReq) preReqReg <- mkRegU;
    Reg#(DmaWriteCntrlState) stateReg <- mkReg(DMA_WRITE_CNTRL_IDLE);
    // Reg#(Bool)  sendReqReg <- mkReg(False);
    // Reg#(Bool) waitRespReg <- mkReg(False);
    Reg#(Bool) cancelReg[2] <- mkCReg(2, False);

    rule issueReq if (!cancelReg[1] && stateReg != DMA_WRITE_CNTRL_WAIT_RESP);
        let dmaReq = dmaReqQ.first;
        dmaReqQ.deq;

        dmaWriteSrv.request.put(dmaReq);
        preReqReg <= dmaReq;
        if (dmaReq.dataStream.isLast) begin
            stateReg <= DMA_WRITE_CNTRL_WAIT_RESP;
        end
        else begin
            stateReg <= DMA_WRITE_CNTRL_SEND_REQ;
        end
        // sendReqReg <= !dmaWriteReq.dataStream.isLast;
        // waitRespReg <= dmaWriteReq.dataStream.isLast;
    endrule

    rule recvResp if (!cancelReg[1] && stateReg == DMA_WRITE_CNTRL_WAIT_RESP);
        let dmaResp <- dmaWriteSrv.response.get;
        dmaRespQ.enq(dmaResp);
        stateReg <= DMA_WRITE_CNTRL_IDLE;
        // waitRespReg <= False;
    endrule

    rule cancelReq if (cancelReg[1] && stateReg == DMA_WRITE_CNTRL_SEND_REQ);
        let dmaReq = preReqReg;
        dmaReq.metaData.initiator =
            cntrlStatus.isSQ ? DMA_SRC_SQ_CANCEL : DMA_SRC_RQ_CANCEL;
        dmaReq.dataStream.isLast = True;
        dmaWriteSrv.request.put(dmaReq);
        stateReg <= DMA_WRITE_CNTRL_WAIT_RESP;

        // $display("time=%0t: DmaWriteCntrl cancel write request", $time);
    endrule

    rule discardResp if (cancelReg[1] && stateReg == DMA_WRITE_CNTRL_WAIT_RESP);
        let dmaResp <- dmaWriteSrv.response.get;
        stateReg <= DMA_WRITE_CNTRL_IDLE;
        cancelReg[1] <= False;

        // $display("time=%0t: DmaWriteCntrl cancel write done", $time);
    endrule

    rule clearCancel if (cancelReg[1] && stateReg == DMA_WRITE_CNTRL_IDLE);
        cancelReg[1] <= False;
        // $display("time=%0t: DmaWriteCntrl no write to cancel", $time);
    endrule

    rule clearQ if (cancelReg[1]);
        dmaReqQ.clear;
        dmaRespQ.clear;
    endrule

    interface srvPort = toGPServer(dmaReqQ, dmaRespQ);

    interface dmaCntrl = interface DmaCntrl;
        method Action cancel();
            cancelReg[0] <= True;
        endmethod

        method Bool isIdle() = stateReg == DMA_WRITE_CNTRL_IDLE && !dmaReqQ.notEmpty && !dmaRespQ.notEmpty;
    endinterface;
endmodule

interface BramPipe#(type anytype);
    interface PipeOut#(anytype) pipeOut;
    method Action clear();
    // method Bool notEmpty();
endinterface

module mkConnectBramQ2PipeOut#(FIFOF#(anytype) bramQ)(
    BramPipe#(anytype)
) provisos(Bits#(anytype, tSz));
    FIFOF#(anytype) postBramQ <- mkFIFOF;

    mkConnection(toPut(postBramQ), toGet(bramQ));

    // return toPipeOut(postBramQ);
    interface pipeOut = toPipeOut(postBramQ);
    method Action clear();
        postBramQ.clear;
    endmethod
    // method Bool notEmpty() = bramQ.notEmpty && postBramQ.notEmpty;
endmodule

module mkConnectPipeOut2BramQ#(
    PipeOut#(anytype) pipeIn, FIFOF#(anytype) bramQ
)(BramPipe#(anytype)) provisos(Bits#(anytype, tSz));
    FIFOF#(anytype) postBramQ <- mkFIFOF;

    mkConnection(toPut(bramQ), toGet(pipeIn));
    mkConnection(toPut(postBramQ), toGet(bramQ));

    // return toPipeOut(postBramQ);
    interface pipeOut = toPipeOut(postBramQ);
    method Action clear();
        postBramQ.clear;
    endmethod
    // method Bool notEmpty() = bramQ.notEmpty && postBramQ.notEmpty;
endmodule

function Bool isDiscardPayload(PayloadConInfo payloadConInfo);
    return case (payloadConInfo) matches
        tagged DiscardPayloadInfo .info: True;
        default                        : False;
    endcase;
endfunction

typedef enum {
    PAYLOAD_GEN_NORMAL,
    PAYLOAD_GEN_WAIT_LAST_FRAG,
    PAYLOAD_GEN_WAIT_GRACEFUL_STOP
    // PAYLOAD_GEN_ERR_FLUSH
} PayloadGenState deriving(Bits, Eq, FShow);

interface PayloadGenerator;
    interface Server#(PayloadGenReq, PayloadGenResp) srvPort;
    interface DataStreamPipeOut payloadDataStreamPipeOut;
endinterface

// As for segmented payload DataStream, each PayloadGenResp is sent
// at the last fragment of the segmented payload DataStream.
module mkPayloadGenerator2#(
    CntrlStatus cntrlStatus,
    DmaReadCntrl2 dmaReadCntrl
)(PayloadGenerator);
    FIFOF#(PayloadGenReq)   payloadGenReqQ <- mkFIFOF;
    FIFOF#(PayloadGenResp) payloadGenRespQ <- mkFIFOF;

    // Pipeline FIFO
    FIFOF#(Tuple3#(PayloadGenReq, ByteEn, PmtuFragNum)) pendingGenReqQ <- mkFIFOF;
    // FIFOF#(Tuple3#(Bool, Bool, PmtuFragNum)) pendingGenRespQ <- mkFIFOF;
    // FIFOF#(Tuple3#(DataStream, Bool, Bool)) payloadSegmentQ <- mkFIFOF;

    // TODO: check payloadOutQ buffer size is enough for DMA read delay?
    FIFOF#(DataStream) payloadBufQ <- mkSizedBRAMFIFOF(valueOf(DATA_STREAM_FRAG_BUF_SIZE));
    let bramQ2PipeOut <- mkConnectBramQ2PipeOut(payloadBufQ);
    let payloadBufPipeOut = bramQ2PipeOut.pipeOut;
    // let payloadBufPipeOut <- mkConnectBramQ2PipeOut(payloadBufQ);

    Reg#(PmtuFragNum) pmtuFragCntReg <- mkRegU;
    Reg#(Bool)     shouldSetFirstReg <- mkReg(False);
    Reg#(Bool)      isFragCntZeroReg <- mkReg(False);
    Reg#(Bool)      isNormalStateReg <- mkReg(True);

    rule resetAndClear if (cntrlStatus.comm.isReset);
        payloadGenReqQ.clear;
        payloadGenRespQ.clear;

        pendingGenReqQ.clear;
        // pendingGenRespQ.clear;
        // payloadSegmentQ.clear;
        payloadBufQ.clear;

        bramQ2PipeOut.clear;

        shouldSetFirstReg <= False;
        isFragCntZeroReg  <= False;
        isNormalStateReg  <= True;

        // $display(
        //     "time=%0t: reset and clear mkPayloadGenerator", $time,
        //     ", pendingGenReqQ.notEmpty=", fshow(pendingGenReqQ.notEmpty)
        // );
    endrule
/*
    rule debugNotFull if (!(
        payloadGenRespQ.notFull &&
        pendingGenReqQ.notFull  &&
        pendingGenRespQ.notFull &&
        payloadSegmentQ.notFull &&
        payloadBufQ.notFull
    ));
        $display(
            "time=%0t: mkPayloadGenerator debugNotFull", $time,
            ", qpn=%h", cntrlStatus.comm.getSQPN,
            ", isSQ=", fshow(cntrlStatus.isSQ),
            ", payloadGenReqQ.notEmpty=", fshow(payloadGenReqQ.notEmpty),
            ", payloadGenRespQ.notFull=", fshow(payloadGenRespQ.notFull),
            ", pendingGenReqQ.notFull=", fshow(pendingGenReqQ.notFull),
            ", pendingGenRespQ.notFull=", fshow(pendingGenRespQ.notFull),
            ", payloadSegmentQ.notFull=", fshow(payloadSegmentQ.notFull),
            ", payloadBufQ.notFull=", fshow(payloadBufQ.notFull)
        );
    endrule

    rule debugNotEmpty if (!(
        payloadGenRespQ.notEmpty &&
        pendingGenReqQ.notEmpty  &&
        pendingGenRespQ.notEmpty &&
        payloadSegmentQ.notEmpty &&
        payloadBufQ.notEmpty
    ));
        $display(
            "time=%0t: mkPayloadGenerator debugNotEmpty", $time,
            ", qpn=%h", cntrlStatus.comm.getSQPN,
            ", isSQ=", fshow(cntrlStatus.isSQ),
            ", payloadGenReqQ.notEmpty=", fshow(payloadGenReqQ.notEmpty),
            ", payloadGenRespQ.notEmpty=", fshow(payloadGenRespQ.notEmpty),
            ", pendingGenReqQ.notEmpty=", fshow(pendingGenReqQ.notEmpty),
            ", pendingGenRespQ.notEmpty=", fshow(pendingGenRespQ.notEmpty),
            ", payloadSegmentQ.notEmpty=", fshow(payloadSegmentQ.notEmpty),
            ", payloadBufQ.notEmpty=", fshow(payloadBufQ.notEmpty)
        );
    endrule
*/
    rule recvPayloadGenReq if (cntrlStatus.comm.isNonErr && isNormalStateReg);
        let payloadGenReq = payloadGenReqQ.first;
        payloadGenReqQ.deq;
        immAssert(
            !isZero(payloadGenReq.dmaReadReq.len),
            "payloadGenReq.dmaReadReq.len assertion @ mkPayloadGenerator",
            $format(
                "payloadGenReq.dmaReadReq.len=%0d should not be zero",
                payloadGenReq.dmaReadReq.len
            )
        );

        let dmaLen = payloadGenReq.dmaReadReq.len;
        let padCnt = calcPadCnt(dmaLen);
        let lastFragValidByteNum = calcLastFragValidByteNum(dmaLen);
        let lastFragValidByteNumWithPadding = lastFragValidByteNum + zeroExtend(padCnt);
        let lastFragByteEnWithPadding = genByteEn(lastFragValidByteNumWithPadding);
        let pmtuFragNum = calcFragNumByPmtu(payloadGenReq.pmtu);
        immAssert(
            !isZero(lastFragValidByteNumWithPadding),
            "lastFragValidByteNumWithPadding assertion @ mkPayloadGenerator",
            $format(
                "lastFragValidByteNumWithPadding=%0d should not be zero",
                lastFragValidByteNumWithPadding,
                ", dmaLen=%0d, lastFragValidByteNum=%0d, padCnt=%0d",
                dmaLen, lastFragValidByteNum, padCnt
            )
        );

        pendingGenReqQ.enq(tuple3(payloadGenReq, lastFragByteEnWithPadding, pmtuFragNum));

        let dmaReadCntrlReq = DmaReadCntrlReq {
            dmaReadReq   : payloadGenReq.dmaReadReq,
            pmtu         : payloadGenReq.pmtu
        };
        dmaReadCntrl.srvPort.request.put(dmaReadCntrlReq);
        // $display(
        //     "time=%0t: recvPayloadGenReq, payloadGenReq=", $time, fshow(payloadGenReq)
        // );
    endrule

    rule lastFragAddPadding if (cntrlStatus.comm.isNonErr || cntrlStatus.comm.isERR);
        let dmaReadCntrlResp <- dmaReadCntrl.srvPort.response.get;
        let { payloadGenReq, lastFragByteEnWithPadding, pmtuFragNum } = pendingGenReqQ.first;

        let curData = dmaReadCntrlResp.dmaReadResp.dataStream;
        let isOrigFirstFrag = dmaReadCntrlResp.isOrigFirst;
        let isOrigLastFrag = dmaReadCntrlResp.isOrigLast;

        if (isOrigLastFrag) begin
            pendingGenReqQ.deq;

            if (payloadGenReq.addPadding) begin
                curData.byteEn = lastFragByteEnWithPadding;
            end
        end

        let hasDmaRespErr = dmaReadCntrlResp.dmaReadResp.isRespErr;
        isNormalStateReg <= !hasDmaRespErr;

        // Every segmented payload has a payloadGenResp
        // Must send payloadGenResp when curData.isLast,
        // so as to make sure no DMA response error
        if (curData.isLast || hasDmaRespErr) begin
            let payloadGenResp = PayloadGenResp {
                // initiator  : payloadGenReq.initiator,
                addPadding : payloadGenReq.addPadding,
                segment    : payloadGenReq.segment,
                isRespErr  : hasDmaRespErr
            };

            payloadGenRespQ.enq(payloadGenResp);
            // $display("time=%0t: payloadGenResp=", $time, fshow(payloadGenResp));
        end

        // payloadSegmentQ.enq(tuple3(curData, dmaReadResp.isRespErr, isOrigLastFrag));
        payloadBufQ.enq(curData);
        // $display(
        //     "time=%0t: lastFragAddPadding", $time,
        //     ", qpn=%h", cntrlStatus.comm.getSQPN,
        //     ", isSQ=", fshow(cntrlStatus.isSQ),
        //     ", payloadGenReq.addPadding=", fshow(payloadGenReq.addPadding),
        //     ", isOrigFirstFrag=", fshow(isOrigFirstFrag),
        //     ", isOrigLastFrag=", fshow(isOrigLastFrag),
        //     ", hasDmaRespErr=", fshow(hasDmaRespErr),
        //     ", dmaReadResp=", fshow(dmaReadResp)
        // );
    endrule

    interface srvPort = toGPServer(payloadGenReqQ, payloadGenRespQ);
    interface payloadDataStreamPipeOut = payloadBufPipeOut;
endmodule

// If segment payload DataStream, then PayloadGenResp is sent
// at the last fragment of the segmented payload DataStream.
// If not segment, then PayloadGenResp is sent at the first
// fragment of the payload DataStream.
// Flush DMA read responses when error
module mkPayloadGenerator#(
    CntrlStatus cntrlStatus,
    DmaReadCntrl dmaReadCntrl
)(PayloadGenerator);
    FIFOF#(PayloadGenReq)   payloadGenReqQ <- mkFIFOF;
    FIFOF#(PayloadGenResp) payloadGenRespQ <- mkFIFOF;

    // Pipeline FIFO
    FIFOF#(Tuple3#(PayloadGenReq, ByteEn, PmtuFragNum)) pendingGenReqQ <- mkFIFOF;
    FIFOF#(Tuple3#(Bool, Bool, PmtuFragNum)) pendingGenRespQ <- mkFIFOF;
    FIFOF#(Tuple3#(DataStream, Bool, Bool)) payloadSegmentQ <- mkFIFOF;
    // TODO: check payloadOutQ buffer size is enough for DMA read delay?
    FIFOF#(DataStream) payloadBufQ <- mkSizedBRAMFIFOF(valueOf(DATA_STREAM_FRAG_BUF_SIZE));
    let bramQ2PipeOut <- mkConnectBramQ2PipeOut(payloadBufQ);
    let payloadBufPipeOut = bramQ2PipeOut.pipeOut;
    // let payloadBufPipeOut <- mkConnectBramQ2PipeOut(payloadBufQ);

    Reg#(PmtuFragNum) pmtuFragCntReg <- mkRegU;
    Reg#(Bool)     shouldSetFirstReg <- mkReg(False);
    Reg#(Bool)      isFragCntZeroReg <- mkReg(False);
    Reg#(Bool)      isNormalStateReg <- mkReg(True);
    // Reg#(Bool)          cancelReg[2] <- mkCReg(2, False);

    let dmaReadSrv = dmaReadCntrl.srvPort;

    rule resetAndClear if (cntrlStatus.comm.isReset);
        payloadGenReqQ.clear;
        payloadGenRespQ.clear;

        pendingGenReqQ.clear;
        pendingGenRespQ.clear;
        payloadSegmentQ.clear;
        payloadBufQ.clear;

        bramQ2PipeOut.clear;

        shouldSetFirstReg <= False;
        isFragCntZeroReg  <= False;
        isNormalStateReg  <= True;
        // cancelReg[1]      <= False;

        // $display(
        //     "time=%0t: reset and clear mkPayloadGenerator", $time,
        //     ", pendingGenReqQ.notEmpty=", fshow(pendingGenReqQ.notEmpty)
        // );
    endrule
/*
    rule debugNotFull if (!(
        payloadGenRespQ.notFull &&
        pendingGenReqQ.notFull  &&
        pendingGenRespQ.notFull &&
        payloadSegmentQ.notFull &&
        payloadBufQ.notFull
    ));
        $display(
            "time=%0t: mkPayloadGenerator debugNotFull", $time,
            ", qpn=%h", cntrlStatus.comm.getSQPN,
            ", isSQ=", fshow(cntrlStatus.isSQ),
            ", payloadGenReqQ.notEmpty=", fshow(payloadGenReqQ.notEmpty),
            ", payloadGenRespQ.notFull=", fshow(payloadGenRespQ.notFull),
            ", pendingGenReqQ.notFull=", fshow(pendingGenReqQ.notFull),
            ", pendingGenRespQ.notFull=", fshow(pendingGenRespQ.notFull),
            ", payloadSegmentQ.notFull=", fshow(payloadSegmentQ.notFull),
            ", payloadBufQ.notFull=", fshow(payloadBufQ.notFull)
        );
    endrule

    rule debugNotEmpty if (!(
        payloadGenRespQ.notEmpty &&
        pendingGenReqQ.notEmpty  &&
        pendingGenRespQ.notEmpty &&
        payloadSegmentQ.notEmpty &&
        payloadBufQ.notEmpty
    ));
        $display(
            "time=%0t: mkPayloadGenerator debugNotEmpty", $time,
            ", qpn=%h", cntrlStatus.comm.getSQPN,
            ", isSQ=", fshow(cntrlStatus.isSQ),
            ", payloadGenReqQ.notEmpty=", fshow(payloadGenReqQ.notEmpty),
            ", payloadGenRespQ.notEmpty=", fshow(payloadGenRespQ.notEmpty),
            ", pendingGenReqQ.notEmpty=", fshow(pendingGenReqQ.notEmpty),
            ", pendingGenRespQ.notEmpty=", fshow(pendingGenRespQ.notEmpty),
            ", payloadSegmentQ.notEmpty=", fshow(payloadSegmentQ.notEmpty),
            ", payloadBufQ.notEmpty=", fshow(payloadBufQ.notEmpty)
        );
    endrule
*/
    rule recvPayloadGenReq if (cntrlStatus.comm.isNonErr && isNormalStateReg);
        let payloadGenReq = payloadGenReqQ.first;
        payloadGenReqQ.deq;
        immAssert(
            !isZero(payloadGenReq.dmaReadReq.len),
            "payloadGenReq.dmaReadReq.len assertion @ mkPayloadGenerator",
            $format(
                "payloadGenReq.dmaReadReq.len=%0d should not be zero",
                payloadGenReq.dmaReadReq.len
            )
        );

        let dmaLen = payloadGenReq.dmaReadReq.len;
        let padCnt = calcPadCnt(dmaLen);
        let lastFragValidByteNum = calcLastFragValidByteNum(dmaLen);
        let lastFragValidByteNumWithPadding = lastFragValidByteNum + zeroExtend(padCnt);
        let lastFragByteEnWithPadding = genByteEn(lastFragValidByteNumWithPadding);
        let pmtuFragNum = calcFragNumByPmtu(payloadGenReq.pmtu);
        immAssert(
            !isZero(lastFragValidByteNumWithPadding),
            "lastFragValidByteNumWithPadding assertion @ mkPayloadGenerator",
            $format(
                "lastFragValidByteNumWithPadding=%0d should not be zero",
                lastFragValidByteNumWithPadding,
                ", dmaLen=%0d, lastFragValidByteNum=%0d, padCnt=%0d",
                dmaLen, lastFragValidByteNum, padCnt
            )
        );

        pendingGenReqQ.enq(tuple3(payloadGenReq, lastFragByteEnWithPadding, pmtuFragNum));
        dmaReadSrv.request.put(payloadGenReq.dmaReadReq);
        // $display(
        //     "time=%0t: recvPayloadGenReq, payloadGenReq=", $time, fshow(payloadGenReq)
        // );
    endrule

    rule lastFragAddPadding if (cntrlStatus.comm.isNonErr || cntrlStatus.comm.isERR);
        let dmaReadResp <- dmaReadSrv.response.get;
        let { payloadGenReq, lastFragByteEnWithPadding, pmtuFragNum } = pendingGenReqQ.first;

        let curData = dmaReadResp.dataStream;
        let isOrigFirstFrag = curData.isFirst;
        let isOrigLastFrag = curData.isLast;

        if (isOrigLastFrag) begin
            pendingGenReqQ.deq;

            if (payloadGenReq.addPadding) begin
                curData.byteEn = lastFragByteEnWithPadding;
            end
        end

        // TODO: how to notify DmaReadResp error ASAP?
        if (isOrigFirstFrag) begin
            pendingGenRespQ.enq(tuple3(
                payloadGenReq.segment,
                payloadGenReq.addPadding,
                pmtuFragNum
            ));
        end

        payloadSegmentQ.enq(tuple3(curData, dmaReadResp.isRespErr, isOrigLastFrag));
        // $display(
        //     "time=%0t: lastFragAddPadding", $time,
        //     ", qpn=%h", cntrlStatus.comm.getSQPN,
        //     ", isSQ=", fshow(cntrlStatus.isSQ),
        //     ", payloadGenReq.addPadding=", fshow(payloadGenReq.addPadding),
        //     ", isOrigFirstFrag=", fshow(isOrigFirstFrag),
        //     ", isOrigLastFrag=", fshow(isOrigLastFrag),
        //     ", dmaReadResp.isRespErr=", fshow(dmaReadResp.isRespErr),
        //     ", dmaReadResp=", fshow(dmaReadResp)
        // );
    endrule

    rule segmentPayload if (cntrlStatus.comm.isNonErr || cntrlStatus.comm.isERR);
        let { curData, hasDmaRespErr, isOrigLastFrag } = payloadSegmentQ.first;
        payloadSegmentQ.deq;

        let { shouldSegment, addPadding, pmtuFragNum } = pendingGenRespQ.first;
        if (isOrigLastFrag) begin
            pendingGenRespQ.deq;
            // $display(
            //     "time=%0t:", $time, " shouldSegment=", fshow(shouldSegment),
            //     ", pmtuFragNum=%h", pmtuFragNum
            // );
        end

        isNormalStateReg <= !hasDmaRespErr;

        if (shouldSegment) begin
            if (shouldSetFirstReg || curData.isFirst) begin
                curData.isFirst = True;
                shouldSetFirstReg <= False;

                // let nextPmtuFragCnt = pmtuFragNum - 2;
                pmtuFragCntReg   <= pmtuFragNum - 2;
                isFragCntZeroReg <= isTwo(pmtuFragNum);
            end
            else if (isFragCntZeroReg) begin
                curData.isLast = True;
                shouldSetFirstReg <= True;
            end
            else if (!curData.isLast) begin
                // let nextPmtuFragCnt = pmtuFragCntReg - 1;
                pmtuFragCntReg   <= pmtuFragCntReg - 1;
                isFragCntZeroReg <= isOne(pmtuFragCntReg);
            end
        end

        // Every segmented payload has a payloadGenResp
        // Must send payloadGenResp when curData.isLast,
        // so as to make sure no DMA response error
        if (curData.isLast || hasDmaRespErr) begin
            let payloadGenResp = PayloadGenResp {
                // initiator  : payloadGenReq.initiator,
                addPadding : addPadding,
                segment    : shouldSegment,
                isRespErr  : hasDmaRespErr
            };

            payloadGenRespQ.enq(payloadGenResp);
            // $display("time=%0t: payloadGenResp=", $time, fshow(payloadGenResp));
        end

        payloadBufQ.enq(curData);
        // $display(
        //     "time=%0t: segmentPayload", $time,
        //     ", qpn=%h", cntrlStatus.comm.getSQPN,
        //     ", isSQ=", fshow(cntrlStatus.isSQ),
        //     ", isOrigLastFrag=", fshow(isOrigLastFrag),
        //     ", curData.isFirst=", fshow(curData.isFirst),
        //     ", curData.isLast=", fshow(curData.isLast)
        // );
    endrule

    // rule flushDmaReadResp if (cntrlStatus.comm.isERR || (cntrlStatus.comm.isNonErr && !isNormalStateReg));
    //     let dmaReadResp <- dmaReadSrv.response.get;
    // endrule

    // rule flushReqQ if (cntrlStatus.comm.isERR || (cntrlStatus.comm.isNonErr && !isNormalStateReg));
    //     payloadGenReqQ.clear;
    //     // payloadGenReqQ.deq;
    // endrule

    // rule flushPipelineQ if (cntrlStatus.comm.isERR || (cntrlStatus.comm.isNonErr && !isNormalStateReg));
    //     pendingGenReqQ.clear;
    //     pendingGenRespQ.clear;
    //     payloadSegmentQ.clear;
    // endrule

    // rule flushRespQ if (cntrlStatus.comm.isERR);
    //     // Response related queues cannot be cleared once isNormalStateReg is False,
    //     // since some payload DataStream in payloadBufQ might be still under processing.
    //     payloadGenRespQ.clear;
    //     payloadBufQ.clear;
    // endrule

    // rule cancelPendingDmaReadReq if (cntrlStatus.comm.isERR && cancelReg[1]);
    //     // cancelReg[1] <= False;
    //     dmaReadCntrl.dmaCntrl.cancel;
    //     // $display("time=%0t: DmaReadCntrl cancel read", $time);
    // endrule

    interface srvPort = toGPServer(payloadGenReqQ, payloadGenRespQ);
    interface payloadDataStreamPipeOut = payloadBufPipeOut; // toPipeOut(payloadBufQ);
    // method Action cancel() begin
    //     // Once cancel, no more DMA read response to PayloadGenerator
    //     cancelReg[0] <= True;
    // end
endmodule

typedef Server#(PayloadConReq, PayloadConResp) PayloadConsumer;

// Flush DMA write responses when error
module mkPayloadConsumer#(
    CntrlStatus cntrlStatus,
    // DmaWriteSrv dmaWriteSrv,
    DmaWriteCntrl dmaWriteCntrl,
    DataStreamPipeOut payloadPipeIn
    // PipeOut#(PayloadConReq) payloadConReqPipeIn
)(PayloadConsumer);
    FIFOF#(PayloadConReq)   payloadConReqQ <- mkFIFOF;
    FIFOF#(PayloadConResp) payloadConRespQ <- mkFIFOF;

    // Pipeline FIFO
    FIFOF#(Tuple3#(PayloadConReq, Bool, Bool))        countReqFragQ <- mkFIFOF;
    FIFOF#(Tuple4#(PayloadConReq, Bool, Bool, Bool)) pendingConReqQ <- mkFIFOF;
    FIFOF#(PayloadConReq)                               genConRespQ <- mkFIFOF;
    FIFOF#(Tuple2#(PayloadConReq, DataStream))       pendingDmaReqQ <- mkFIFOF;

    // TODO: check payloadOutQ buffer size is enough for DMA write delay?
    FIFOF#(DataStream) payloadBufQ <- mkSizedBRAMFIFOF(valueOf(DATA_STREAM_FRAG_BUF_SIZE));
    let pipeOut2Bram <- mkConnectPipeOut2BramQ(payloadPipeIn, payloadBufQ);
    let payloadBufPipeOut = pipeOut2Bram.pipeOut;
    // let payloadBufPipeOut <- mkConnectPipeOut2BramQ(payloadPipeIn, payloadBufQ);

    Reg#(PmtuFragNum) remainingFragNumReg <- mkRegU;
    Reg#(Bool)  isRemainingFragNumZeroReg <- mkReg(False);
    Reg#(Bool)       isFirstOrOnlyFragReg <- mkReg(True);
    // Reg#(Bool)               cancelReg[2] <- mkCReg(2, False);
    // Reg#(Bool) busyReg <- mkReg(False);
    let dmaWriteSrv = dmaWriteCntrl.srvPort;

    rule resetAndClear if (cntrlStatus.comm.isReset);
        payloadConReqQ.clear;
        payloadConRespQ.clear;

        countReqFragQ.clear;
        pendingConReqQ.clear;
        genConRespQ.clear;
        pendingDmaReqQ.clear;
        payloadBufQ.clear;

        pipeOut2Bram.clear;
        // busyReg <= False;
        isFirstOrOnlyFragReg      <= True;
        isRemainingFragNumZeroReg <= False;
        // cancelReg[1]              <= False;

        // $display(
        //     "time=%0t: reset and clear mkPayloadConsumer", $time,
        //     ", genConRespQ.notEmpty=", fshow(genConRespQ.notEmpty)
        // );
    endrule

    function Action checkIsOnlyPayloadFragment(
        DataStream payload, PayloadConInfo consumeInfo
    );
        action
            immAssert(
                payload.isFirst && payload.isLast,
                "only payload assertion @ mkPayloadConsumer",
                $format(
                    "payload.isFirst=", fshow(payload.isFirst),
                    "and payload.isLast=", fshow(payload.isLast),
                    " should be true when consumeInfo=",
                    fshow(consumeInfo)
                )
            );
        endaction
    endfunction

    rule recvReq if (cntrlStatus.comm.isNonErr || cntrlStatus.comm.isERR);
        let consumeReq = payloadConReqQ.first;
        payloadConReqQ.deq;

        let isDiscardReq = False;
        case (consumeReq.consumeInfo) matches
            tagged DiscardPayloadInfo .discardInfo: begin
                isDiscardReq = True;

                immAssert(
                    !isZero(consumeReq.fragNum),
                    "consumeReq.fragNum assertion @ mkPayloadConsumer",
                    $format(
                        "consumeReq.fragNum=%h should not be zero when consumeInfo is DiscardPayload",
                        consumeReq.fragNum
                    )
                );
            end
            tagged AtomicRespInfoAndPayload .atomicRespInfo: begin
                immAssert(
                    atomicRespInfo.atomicRespDmaWriteMetaData.len == fromInteger(valueOf(ATOMIC_WORK_REQ_LEN)),
                    "atomicRespInfo.atomicRespDmaWriteMetaData.len assertion @ mkPayloadConsumer",
                    $format(
                        "atomicRespDmaWriteMetaData.len=%h should be %h when consumeInfo is AtomicRespInfoAndPayload",
                        atomicRespInfo.atomicRespDmaWriteMetaData.len, valueOf(ATOMIC_WORK_REQ_LEN)
                    )
                );
            end
            tagged SendWriteReqReadRespInfo .sendWriteReqReadRespInfo    : begin
                immAssert(
                    !isZero(consumeReq.fragNum),
                    "consumeReq.fragNum assertion @ mkPayloadConsumer",
                    $format(
                        "consumeReq.fragNum=%h should not be zero when consumeInfo is SendWriteReqReadRespInfo",
                        consumeReq.fragNum
                    )
                );
            end
            default: begin
                immFail(
                    "unreachible case @ mkPayloadConsumer",
                    $format("consumeReq.consumeInfo=", fshow(consumeReq.consumeInfo))
                );
            end
        endcase

        let isFragNumLessOrEqOne = isLessOrEqOne(consumeReq.fragNum);
        countReqFragQ.enq(tuple3(consumeReq, isFragNumLessOrEqOne, isDiscardReq));
        // $display(
        //     "time=%0t: PayloadConsumer recvReq", $time,
        //     ", qpn=%h", cntrlStatus.comm.getSQPN,
        //     ", isSQ=", fshow(cntrlStatus.isSQ),
        //     ", consumeReq=", fshow(consumeReq)
        // );
    endrule

    rule countReqFrag if (cntrlStatus.comm.isNonErr || cntrlStatus.comm.isERR);
        let { consumeReq, isFragNumLessOrEqOne, isDiscardReq } = countReqFragQ.first;

        let isLastReqFrag = isFragNumLessOrEqOne ? True : isRemainingFragNumZeroReg;

        if (isDiscardReq) begin
            countReqFragQ.deq;
        end
        else begin
            if (isLastReqFrag) begin
                countReqFragQ.deq;
                isFirstOrOnlyFragReg      <= True;
                isRemainingFragNumZeroReg <= False;
            end
            else begin
                if (isFirstOrOnlyFragReg) begin
                    remainingFragNumReg       <= consumeReq.fragNum - 2;
                    isRemainingFragNumZeroReg <= isTwo(consumeReq.fragNum);
                    isFirstOrOnlyFragReg      <= False;
                end
                else begin
                    remainingFragNumReg       <= remainingFragNumReg - 1;
                    isRemainingFragNumZeroReg <= isOne(remainingFragNumReg);
                end
            end
        end

        pendingConReqQ.enq(tuple4(
            consumeReq, isFragNumLessOrEqOne, isFirstOrOnlyFragReg, isLastReqFrag
        ));
        // $display(
        //     "time=%0t: countReqFrag", $time,
        //     ", consumeReq.fragNum=%0d", consumeReq.fragNum,
        //     ", remainingFragNumReg=%0d", remainingFragNumReg,
        //     ", isRemainingFragNumZeroReg=", fshow(isRemainingFragNumZeroReg),
        //     ", isFirstOrOnlyFragReg=", fshow(isFirstOrOnlyFragReg),
        //     ", isLastReqFrag=", fshow(isLastReqFrag)
        // );
    endrule

    rule consumePayload if (cntrlStatus.comm.isNonErr || cntrlStatus.comm.isERR);
        let {
            consumeReq, isFragNumLessOrEqOne, isFirstOrOnlyFrag, isLastReqFrag
        } = pendingConReqQ.first;
        let shouldDeqConReq = True;
        // pendingConReqQ.deq;

        case (consumeReq.consumeInfo) matches
            tagged DiscardPayloadInfo .discardInfo: begin
                let payload = payloadBufPipeOut.first;
                payloadBufPipeOut.deq;

                shouldDeqConReq = payload.isLast;

                // if (isFragNumLessOrEqOne) begin
                //     checkIsOnlyPayloadFragment(payload, consumeReq.consumeInfo);
                // end

                // if (isFirstOrOnlyFrag) begin
                //     immAssert(
                //         payload.isFirst,
                //         "first payload assertion @ mkPayloadConsumer",
                //         $format(
                //             "payload.isFirst=", fshow(payload.isFirst),
                //             " should be true when isFirstOrOnlyFrag=", fshow(isFirstOrOnlyFrag),
                //             " and consumeReq=", fshow(consumeReq)
                //         )
                //     );
                // end

                // if (isLastReqFrag) begin
                //     immAssert(
                //         payload.isLast,
                //         "last payload assertion @ mkPayloadConsumer",
                //         $format(
                //             "payload.isLast=", fshow(payload.isLast),
                //             " should be true when isLastReqFrag=", fshow(isLastReqFrag),
                //             " for discard consumeReq=", fshow(consumeReq.consumeInfo)
                //         )
                //     );

                //     // $display("time=%0t: consumePayload, discard payload done", $time);
                // end
            end
            tagged AtomicRespInfoAndPayload .atomicRespInfo: begin
                genConRespQ.enq(consumeReq);

                immAssert(
                    isFragNumLessOrEqOne && isFirstOrOnlyFrag && isLastReqFrag,
                    "only frag assertion @ mkPayloadConsumer",
                    $format(
                        "isFragNumLessOrEqOne=", fshow(isFragNumLessOrEqOne),
                        ", isFirstOrOnlyFrag=", fshow(isFirstOrOnlyFrag),
                        ", isLastReqFrag=", fshow(isLastReqFrag),
                        " should be all true when atomic consumeReq=",
                        fshow(consumeReq)
                    )
                );

                let payload = dontCareValue;
                pendingDmaReqQ.enq(tuple2(consumeReq, payload));
            end
            tagged SendWriteReqReadRespInfo .sendWriteReqReadRespInfo: begin
                let payload = payloadBufPipeOut.first;
                payloadBufPipeOut.deq;
                if (isFragNumLessOrEqOne) begin
                    checkIsOnlyPayloadFragment(payload, consumeReq.consumeInfo);
                    // $display(
                    //     "time=%0t: single packet response consumeReq.fragNum=%0d",
                    //     $time, consumeReq.fragNum
                    // );
                end
                // $display(
                //     "time=%0t: SendWriteReqReadRespInfo", $time,
                //     ", consumeReq=", fshow(consumeReq),
                //     ", isFirstOrOnlyFrag=", fshow(isFirstOrOnlyFrag),
                //     ", isLastReqFrag=", fshow(isLastReqFrag),
                //     ", payload.isFirst=", fshow(payload.isFirst),
                //     ", payload.isLast=", fshow(payload.isLast)
                // );

                if (isFirstOrOnlyFrag) begin
                    immAssert(
                        payload.isFirst,
                        "first payload assertion @ mkPayloadConsumer",
                        $format(
                            "payload.isFirst=", fshow(payload.isFirst),
                            " should be true when isFirstOrOnlyFrag=", fshow(isFirstOrOnlyFrag),
                            " for consumeReq=", fshow(consumeReq)
                        )
                    );
                end
                else begin
                    immAssert(
                        !payload.isFirst,
                        "first payload assertion @ mkPayloadConsumer",
                        $format(
                            "payload.isFirst=", fshow(payload.isFirst),
                            " should be false when isFirstOrOnlyFrag=", fshow(isFirstOrOnlyFrag),
                            " for consumeReq=", fshow(consumeReq)
                        )
                    );
                end

                if (isLastReqFrag) begin
                    immAssert(
                        payload.isLast,
                        "last payload assertion @ mkPayloadConsumer",
                        $format(
                            "payload.isLast=", fshow(payload.isLast),
                            " should be true when isLastReqFrag=", fshow(isLastReqFrag),
                            " for consumeReq=", fshow(consumeReq)
                        )
                    );

                    genConRespQ.enq(consumeReq);
                end
                else begin
                    immAssert(
                        !payload.isLast,
                        "last payload assertion @ mkPayloadConsumer",
                        $format(
                            "payload.isLast=", fshow(payload.isLast),
                            " should be false when isLastReqFrag=", fshow(isLastReqFrag),
                            " for consumeReq=", fshow(consumeReq)
                        )
                    );
                end

                // if (!isFirstOrOnlyFrag && !isLastReqFrag) begin
                //     immAssert(
                //         !payload.isFirst && !payload.isLast,
                //         "first and last payload assertion @ mkPayloadConsumer",
                //         $format(
                //             "payload.isFirst=", fshow(payload.isFirst),
                //             " and payload.isLast=", fshow(payload.isLast),
                //             " should both be false when isFirstOrOnlyFrag=", fshow(isFirstOrOnlyFrag),
                //             " and isLastReqFrag=", fshow(isLastReqFrag),
                //             " for consumeReq=", fshow(consumeReq)
                //         )
                //     );
                // end

                pendingDmaReqQ.enq(tuple2(consumeReq, payload));
            end
            default: begin
                immFail(
                    "unreachible case @ mkPayloadConsumer",
                    $format("consumeReq.consumeInfo=", fshow(consumeReq.consumeInfo))
                );
            end
        endcase

        if (shouldDeqConReq) begin
            pendingConReqQ.deq;
        end
    endrule

    rule issueDmaReq if (cntrlStatus.comm.isNonErr);
        let { consumeReq, payload } = pendingDmaReqQ.first;
        pendingDmaReqQ.deq;

        case (consumeReq.consumeInfo) matches
            tagged SendWriteReqReadRespInfo .sendWriteReqReadRespInfo: begin
                let dmaWriteReq = DmaWriteReq {
                    metaData  : sendWriteReqReadRespInfo,
                    dataStream: payload
                };
                // $display("time=%0t: dmaWriteReq=", $time, fshow(dmaWriteReq));
                dmaWriteSrv.request.put(dmaWriteReq);
            end
            tagged AtomicRespInfoAndPayload .atomicRespInfo: begin
                // let { atomicRespDmaWriteMetaData, atomicRespPayload } = atomicRespInfo;
                let dmaWriteReq = DmaWriteReq {
                    metaData   : atomicRespInfo.atomicRespDmaWriteMetaData,
                    dataStream : DataStream {
                        data   : zeroExtendLSB(atomicRespInfo.atomicRespPayload),
                        byteEn : genByteEn(fromInteger(valueOf(ATOMIC_WORK_REQ_LEN))),
                        isFirst: True,
                        isLast : True
                    }
                };
                dmaWriteSrv.request.put(dmaWriteReq);
            end
            default: begin
                immAssert(
                    isDiscardPayload(consumeReq.consumeInfo),
                    "isDiscardPayload assertion @ mkPayloadConsumer",
                    $format(
                        "consumeReq.consumeInfo=", fshow(consumeReq.consumeInfo),
                        " should be DiscardPayload"
                    )
                );
            end
        endcase
    endrule

    rule genConResp if (cntrlStatus.comm.isNonErr);
        let dmaWriteResp <- dmaWriteSrv.response.get;
        let consumeReq = genConRespQ.first;
        genConRespQ.deq;

        case (consumeReq.consumeInfo) matches
            tagged SendWriteReqReadRespInfo .sendWriteReqReadRespInfo: begin
                let consumeResp = PayloadConResp {
                    dmaWriteResp : DmaWriteResp {
                        initiator: sendWriteReqReadRespInfo.initiator,
                        isRespErr: dmaWriteResp.isRespErr,
                        sqpn     : sendWriteReqReadRespInfo.sqpn,
                        psn      : sendWriteReqReadRespInfo.psn
                    }
                };
                payloadConRespQ.enq(consumeResp);

                immAssert(
                    dmaWriteResp.sqpn == sendWriteReqReadRespInfo.sqpn &&
                    dmaWriteResp.psn  == sendWriteReqReadRespInfo.psn,
                    "dmaWriteResp SQPN and PSN assertion @ mkPayloadConsumer",
                    $format(
                        "dmaWriteResp.sqpn=%h should == sendWriteReqReadRespInfo.sqpn=%h",
                        dmaWriteResp.sqpn, sendWriteReqReadRespInfo.sqpn,
                        ", and dmaWriteResp.psn=%h should == sendWriteReqReadRespInfo.psn=%h",
                        dmaWriteResp.psn, sendWriteReqReadRespInfo.psn
                    )
                );
            end
            tagged AtomicRespInfoAndPayload .atomicRespInfo: begin
                // let { atomicRespDmaWriteMetaData, atomicRespPayload } = atomicRespInfo;
                let consumeResp = PayloadConResp {
                    dmaWriteResp : DmaWriteResp {
                        initiator: atomicRespInfo.atomicRespDmaWriteMetaData.initiator,
                        isRespErr: dmaWriteResp.isRespErr,
                        sqpn     : atomicRespInfo.atomicRespDmaWriteMetaData.sqpn,
                        psn      : atomicRespInfo.atomicRespDmaWriteMetaData.psn
                    }
                };
                // $display("time=%0t: consumeResp=", $time, fshow(consumeResp));
                payloadConRespQ.enq(consumeResp);

                immAssert(
                    dmaWriteResp.sqpn == atomicRespInfo.atomicRespDmaWriteMetaData.sqpn &&
                    dmaWriteResp.psn  == atomicRespInfo.atomicRespDmaWriteMetaData.psn,
                    "dmaWriteResp SQPN and PSN assertion @ ",
                    $format(
                        "dmaWriteResp.sqpn=%h should == atomicRespInfo.atomicRespDmaWriteMetaData.sqpn=%h",
                        dmaWriteResp.sqpn, atomicRespInfo.atomicRespDmaWriteMetaData.sqpn,
                        ", and dmaWriteResp.psn=%h should == atomicRespInfo.atomicRespDmaWriteMetaData.psn=%h",
                        dmaWriteResp.psn, atomicRespInfo.atomicRespDmaWriteMetaData.psn
                    )
                );
            end
            default: begin
                immFail(
                    "unreachible case @ mkPayloadConsumer",
                    $format("consumeReq.consumeInfo=", fshow(consumeReq.consumeInfo))
                );
            end
        endcase
        // $display(
        //     "time=%0t: genConResp", $time,
        //     ", dmaWriteResp=", fshow(dmaWriteResp),
        //     ", consumeReq=", fshow(consumeReq)
        // );
    endrule

    // TODO: safe error flush that finish pending requests before flush
    // When error, continue send DMA write requests,
    // so as to flush payload data properly later.
    // But discard DMA write responses when error.
    rule flushDmaWriteResp if (cntrlStatus.comm.isERR);
        let dmaWriteResp <- dmaWriteSrv.response.get;
    endrule

    // rule flushPayloadBufPipeOut if (cntrlStatus.comm.isERR);
    //     payloadBufPipeOut.deq;
    // endrule

    rule flushPipelineQ if (cntrlStatus.comm.isERR);
        payloadBufQ.clear;
        pendingConReqQ.clear;
        pendingDmaReqQ.clear;
    endrule

    rule flushPayloadConResp if (cntrlStatus.comm.isERR);
        payloadConRespQ.clear;
    endrule

    // rule cancelPendingDmaWriteReq if (cntrlStatus.comm.isERR && cancelReg[1]);
    //     dmaWriteCntrl.dmaCntrl.cancel;
    //     cancelReg[1] <= False;
    //     // $display("time=%0t: DmaWriteCntrl cancel write", $time);
    // endrule

    return toGPServer(payloadConReqQ, payloadConRespQ);
endmodule
/*
interface PayloadConsumer;
    interface PipeOut#(PayloadConResp) respPipeOut;
    // method Action cancel();
endinterface

// Flush DMA write responses when error
module mkPayloadConsumer#(
    CntrlStatus cntrlStatus,
    DataStreamPipeOut payloadPipeIn,
    // DmaWriteSrv dmaWriteSrv,
    DmaWriteCntrl dmaWriteCntrl,
    PipeOut#(PayloadConReq) payloadConReqPipeIn
)(PayloadConsumer);
    // FIFOF#(PayloadConReq)   payloadConReqPipeIn <- mkFIFOF;
    FIFOF#(PayloadConResp) payloadConRespQ <- mkFIFOF;

    // Pipeline FIFO
    FIFOF#(Tuple3#(PayloadConReq, Bool, Bool))        countReqFragQ <- mkFIFOF;
    FIFOF#(Tuple4#(PayloadConReq, Bool, Bool, Bool)) pendingConReqQ <- mkFIFOF;
    FIFOF#(PayloadConReq)                               genConRespQ <- mkFIFOF;
    FIFOF#(Tuple2#(PayloadConReq, DataStream))       pendingDmaReqQ <- mkFIFOF;

    // TODO: check payloadOutQ buffer size is enough for DMA write delay?
    FIFOF#(DataStream) payloadBufQ <- mkSizedBRAMFIFOF(valueOf(DATA_STREAM_FRAG_BUF_SIZE));
    let pipeOut2Bram <- mkConnectPipeOut2BramQ(payloadPipeIn, payloadBufQ);
    let payloadBufPipeOut = pipeOut2Bram.pipeOut;
    // let payloadBufPipeOut <- mkConnectPipeOut2BramQ(payloadPipeIn, payloadBufQ);

    Reg#(PmtuFragNum) remainingFragNumReg <- mkRegU;
    Reg#(Bool)  isRemainingFragNumZeroReg <- mkReg(False);
    Reg#(Bool)       isFirstOrOnlyFragReg <- mkReg(True);
    // Reg#(Bool)               cancelReg[2] <- mkCReg(2, False);
    // Reg#(Bool) busyReg <- mkReg(False);
    let dmaWriteSrv = dmaWriteCntrl.srvPort;

    rule resetAndClear if (cntrlStatus.comm.isReset);
        // payloadConReqPipeIn.clear;
        payloadConRespQ.clear;

        countReqFragQ.clear;
        pendingConReqQ.clear;
        genConRespQ.clear;
        pendingDmaReqQ.clear;
        payloadBufQ.clear;

        pipeOut2Bram.clear;
        // busyReg <= False;
        isFirstOrOnlyFragReg      <= True;
        isRemainingFragNumZeroReg <= False;
        // cancelReg[1]              <= False;

        // $display(
        //     "time=%0t: reset and clear mkPayloadConsumer", $time,
        //     ", genConRespQ.notEmpty=", fshow(genConRespQ.notEmpty)
        // );
    endrule

    function Action checkIsOnlyPayloadFragment(
        DataStream payload, PayloadConInfo consumeInfo
    );
        action
            immAssert(
                payload.isFirst && payload.isLast,
                "only payload assertion @ mkPayloadConsumer",
                $format(
                    "payload.isFirst=", fshow(payload.isFirst),
                    "and payload.isLast=", fshow(payload.isLast),
                    " should be true when consumeInfo=",
                    fshow(consumeInfo)
                )
            );
        endaction
    endfunction

    rule recvReq if (cntrlStatus.comm.isNonErr || cntrlStatus.comm.isERR);
        let consumeReq = payloadConReqPipeIn.first;
        payloadConReqPipeIn.deq;

        let isDiscardReq = False;
        case (consumeReq.consumeInfo) matches
            tagged DiscardPayloadInfo .discardInfo: begin
                isDiscardReq = True;

                immAssert(
                    !isZero(consumeReq.fragNum),
                    "consumeReq.fragNum assertion @ mkPayloadConsumer",
                    $format(
                        "consumeReq.fragNum=%h should not be zero when consumeInfo is DiscardPayload",
                        consumeReq.fragNum
                    )
                );
            end
            tagged AtomicRespInfoAndPayload .atomicRespInfo: begin
                immAssert(
                    atomicRespInfo.atomicRespDmaWriteMetaData.len == fromInteger(valueOf(ATOMIC_WORK_REQ_LEN)),
                    "atomicRespInfo.atomicRespDmaWriteMetaData.len assertion @ mkPayloadConsumer",
                    $format(
                        "atomicRespDmaWriteMetaData.len=%h should be %h when consumeInfo is AtomicRespInfoAndPayload",
                        atomicRespInfo.atomicRespDmaWriteMetaData.len, valueOf(ATOMIC_WORK_REQ_LEN)
                    )
                );
            end
            tagged SendWriteReqReadRespInfo .sendWriteReqReadRespInfo    : begin
                immAssert(
                    !isZero(consumeReq.fragNum),
                    "consumeReq.fragNum assertion @ mkPayloadConsumer",
                    $format(
                        "consumeReq.fragNum=%h should not be zero when consumeInfo is SendWriteReqReadRespInfo",
                        consumeReq.fragNum
                    )
                );
            end
            default: begin
                immFail(
                    "unreachible case @ mkPayloadConsumer",
                    $format("consumeReq.consumeInfo=", fshow(consumeReq.consumeInfo))
                );
            end
        endcase

        let isFragNumLessOrEqOne = isLessOrEqOne(consumeReq.fragNum);
        countReqFragQ.enq(tuple3(consumeReq, isFragNumLessOrEqOne, isDiscardReq));
        // $display(
        //     "time=%0t: PayloadConsumer recvReq", $time,
        //     ", qpn=%h", cntrlStatus.comm.getSQPN,
        //     ", isSQ=", fshow(cntrlStatus.isSQ),
        //     ", consumeReq=", fshow(consumeReq)
        // );
    endrule

    rule countReqFrag if (cntrlStatus.comm.isNonErr || cntrlStatus.comm.isERR);
        let { consumeReq, isFragNumLessOrEqOne, isDiscardReq } = countReqFragQ.first;

        let isLastReqFrag = isFragNumLessOrEqOne ? True : isRemainingFragNumZeroReg;

        if (isDiscardReq) begin
            countReqFragQ.deq;
        end
        else begin
            if (isLastReqFrag) begin
                countReqFragQ.deq;
                isFirstOrOnlyFragReg      <= True;
                isRemainingFragNumZeroReg <= False;
            end
            else begin
                if (isFirstOrOnlyFragReg) begin
                    remainingFragNumReg       <= consumeReq.fragNum - 2;
                    isRemainingFragNumZeroReg <= isTwo(consumeReq.fragNum);
                    isFirstOrOnlyFragReg      <= False;
                end
                else begin
                    remainingFragNumReg       <= remainingFragNumReg - 1;
                    isRemainingFragNumZeroReg <= isOne(remainingFragNumReg);
                end
            end
        end

        pendingConReqQ.enq(tuple4(
            consumeReq, isFragNumLessOrEqOne, isFirstOrOnlyFragReg, isLastReqFrag
        ));
        // $display(
        //     "time=%0t: countReqFrag", $time,
        //     ", consumeReq.fragNum=%0d", consumeReq.fragNum,
        //     ", remainingFragNumReg=%0d", remainingFragNumReg,
        //     ", isRemainingFragNumZeroReg=", fshow(isRemainingFragNumZeroReg),
        //     ", isFirstOrOnlyFragReg=", fshow(isFirstOrOnlyFragReg),
        //     ", isLastReqFrag=", fshow(isLastReqFrag)
        // );
    endrule

    rule consumePayload if (cntrlStatus.comm.isNonErr || cntrlStatus.comm.isERR);
        let {
            consumeReq, isFragNumLessOrEqOne, isFirstOrOnlyFrag, isLastReqFrag
        } = pendingConReqQ.first;
        let shouldDeqConReq = True;
        // pendingConReqQ.deq;

        case (consumeReq.consumeInfo) matches
            tagged DiscardPayloadInfo .discardInfo: begin
                let payload = payloadBufPipeOut.first;
                payloadBufPipeOut.deq;

                shouldDeqConReq = payload.isLast;

                // if (isFragNumLessOrEqOne) begin
                //     checkIsOnlyPayloadFragment(payload, consumeReq.consumeInfo);
                // end

                // if (isFirstOrOnlyFrag) begin
                //     immAssert(
                //         payload.isFirst,
                //         "first payload assertion @ mkPayloadConsumer",
                //         $format(
                //             "payload.isFirst=", fshow(payload.isFirst),
                //             " should be true when isFirstOrOnlyFrag=", fshow(isFirstOrOnlyFrag),
                //             " and consumeReq=", fshow(consumeReq)
                //         )
                //     );
                // end

                // if (isLastReqFrag) begin
                //     immAssert(
                //         payload.isLast,
                //         "last payload assertion @ mkPayloadConsumer",
                //         $format(
                //             "payload.isLast=", fshow(payload.isLast),
                //             " should be true when isLastReqFrag=", fshow(isLastReqFrag),
                //             " for discard consumeReq=", fshow(consumeReq.consumeInfo)
                //         )
                //     );

                //     // $display("time=%0t: consumePayload, discard payload done", $time);
                // end
            end
            tagged AtomicRespInfoAndPayload .atomicRespInfo: begin
                genConRespQ.enq(consumeReq);

                immAssert(
                    isFragNumLessOrEqOne && isFirstOrOnlyFrag && isLastReqFrag,
                    "only frag assertion @ mkPayloadConsumer",
                    $format(
                        "isFragNumLessOrEqOne=", fshow(isFragNumLessOrEqOne),
                        ", isFirstOrOnlyFrag=", fshow(isFirstOrOnlyFrag),
                        ", isLastReqFrag=", fshow(isLastReqFrag),
                        " should be all true when atomic consumeReq=",
                        fshow(consumeReq)
                    )
                );

                let payload = dontCareValue;
                pendingDmaReqQ.enq(tuple2(consumeReq, payload));
            end
            tagged SendWriteReqReadRespInfo .sendWriteReqReadRespInfo: begin
                let payload = payloadBufPipeOut.first;
                payloadBufPipeOut.deq;
                if (isFragNumLessOrEqOne) begin
                    checkIsOnlyPayloadFragment(payload, consumeReq.consumeInfo);
                    // $display(
                    //     "time=%0t: single packet response consumeReq.fragNum=%0d",
                    //     $time, consumeReq.fragNum
                    // );
                end
                // $display(
                //     "time=%0t: SendWriteReqReadRespInfo", $time,
                //     ", consumeReq=", fshow(consumeReq),
                //     ", isFirstOrOnlyFrag=", fshow(isFirstOrOnlyFrag),
                //     ", isLastReqFrag=", fshow(isLastReqFrag),
                //     ", payload.isFirst=", fshow(payload.isFirst),
                //     ", payload.isLast=", fshow(payload.isLast)
                // );

                if (isFirstOrOnlyFrag) begin
                    immAssert(
                        payload.isFirst,
                        "first payload assertion @ mkPayloadConsumer",
                        $format(
                            "payload.isFirst=", fshow(payload.isFirst),
                            " should be true when isFirstOrOnlyFrag=", fshow(isFirstOrOnlyFrag),
                            " for consumeReq=", fshow(consumeReq)
                        )
                    );
                end
                else begin
                    immAssert(
                        !payload.isFirst,
                        "first payload assertion @ mkPayloadConsumer",
                        $format(
                            "payload.isFirst=", fshow(payload.isFirst),
                            " should be false when isFirstOrOnlyFrag=", fshow(isFirstOrOnlyFrag),
                            " for consumeReq=", fshow(consumeReq)
                        )
                    );
                end

                if (isLastReqFrag) begin
                    immAssert(
                        payload.isLast,
                        "last payload assertion @ mkPayloadConsumer",
                        $format(
                            "payload.isLast=", fshow(payload.isLast),
                            " should be true when isLastReqFrag=", fshow(isLastReqFrag),
                            " for consumeReq=", fshow(consumeReq)
                        )
                    );

                    genConRespQ.enq(consumeReq);
                end
                else begin
                    immAssert(
                        !payload.isLast,
                        "last payload assertion @ mkPayloadConsumer",
                        $format(
                            "payload.isLast=", fshow(payload.isLast),
                            " should be false when isLastReqFrag=", fshow(isLastReqFrag),
                            " for consumeReq=", fshow(consumeReq)
                        )
                    );
                end

                // if (!isFirstOrOnlyFrag && !isLastReqFrag) begin
                //     immAssert(
                //         !payload.isFirst && !payload.isLast,
                //         "first and last payload assertion @ mkPayloadConsumer",
                //         $format(
                //             "payload.isFirst=", fshow(payload.isFirst),
                //             " and payload.isLast=", fshow(payload.isLast),
                //             " should both be false when isFirstOrOnlyFrag=", fshow(isFirstOrOnlyFrag),
                //             " and isLastReqFrag=", fshow(isLastReqFrag),
                //             " for consumeReq=", fshow(consumeReq)
                //         )
                //     );
                // end

                pendingDmaReqQ.enq(tuple2(consumeReq, payload));
            end
            default: begin
                immFail(
                    "unreachible case @ mkPayloadConsumer",
                    $format("consumeReq.consumeInfo=", fshow(consumeReq.consumeInfo))
                );
            end
        endcase

        if (shouldDeqConReq) begin
            pendingConReqQ.deq;
        end
    endrule

    rule issueDmaReq if (cntrlStatus.comm.isNonErr);
        let { consumeReq, payload } = pendingDmaReqQ.first;
        pendingDmaReqQ.deq;

        case (consumeReq.consumeInfo) matches
            tagged SendWriteReqReadRespInfo .sendWriteReqReadRespInfo: begin
                let dmaWriteReq = DmaWriteReq {
                    metaData  : sendWriteReqReadRespInfo,
                    dataStream: payload
                };
                // $display("time=%0t: dmaWriteReq=", $time, fshow(dmaWriteReq));
                dmaWriteSrv.request.put(dmaWriteReq);
            end
            tagged AtomicRespInfoAndPayload .atomicRespInfo: begin
                // let { atomicRespDmaWriteMetaData, atomicRespPayload } = atomicRespInfo;
                let dmaWriteReq = DmaWriteReq {
                    metaData   : atomicRespInfo.atomicRespDmaWriteMetaData,
                    dataStream : DataStream {
                        data   : zeroExtendLSB(atomicRespInfo.atomicRespPayload),
                        byteEn : genByteEn(fromInteger(valueOf(ATOMIC_WORK_REQ_LEN))),
                        isFirst: True,
                        isLast : True
                    }
                };
                dmaWriteSrv.request.put(dmaWriteReq);
            end
            default: begin
                immAssert(
                    isDiscardPayload(consumeReq.consumeInfo),
                    "isDiscardPayload assertion @ mkPayloadConsumer",
                    $format(
                        "consumeReq.consumeInfo=", fshow(consumeReq.consumeInfo),
                        " should be DiscardPayload"
                    )
                );
            end
        endcase
    endrule

    rule genConResp if (cntrlStatus.comm.isNonErr);
        let dmaWriteResp <- dmaWriteSrv.response.get;
        let consumeReq = genConRespQ.first;
        genConRespQ.deq;

        case (consumeReq.consumeInfo) matches
            tagged SendWriteReqReadRespInfo .sendWriteReqReadRespInfo: begin
                let consumeResp = PayloadConResp {
                    dmaWriteResp : DmaWriteResp {
                        initiator: sendWriteReqReadRespInfo.initiator,
                        isRespErr: dmaWriteResp.isRespErr,
                        sqpn     : sendWriteReqReadRespInfo.sqpn,
                        psn      : sendWriteReqReadRespInfo.psn
                    }
                };
                payloadConRespQ.enq(consumeResp);

                immAssert(
                    dmaWriteResp.sqpn == sendWriteReqReadRespInfo.sqpn &&
                    dmaWriteResp.psn  == sendWriteReqReadRespInfo.psn,
                    "dmaWriteResp SQPN and PSN assertion @ mkPayloadConsumer",
                    $format(
                        "dmaWriteResp.sqpn=%h should == sendWriteReqReadRespInfo.sqpn=%h",
                        dmaWriteResp.sqpn, sendWriteReqReadRespInfo.sqpn,
                        ", and dmaWriteResp.psn=%h should == sendWriteReqReadRespInfo.psn=%h",
                        dmaWriteResp.psn, sendWriteReqReadRespInfo.psn
                    )
                );
            end
            tagged AtomicRespInfoAndPayload .atomicRespInfo: begin
                // let { atomicRespDmaWriteMetaData, atomicRespPayload } = atomicRespInfo;
                let consumeResp = PayloadConResp {
                    dmaWriteResp : DmaWriteResp {
                        initiator: atomicRespInfo.atomicRespDmaWriteMetaData.initiator,
                        isRespErr: dmaWriteResp.isRespErr,
                        sqpn     : atomicRespInfo.atomicRespDmaWriteMetaData.sqpn,
                        psn      : atomicRespInfo.atomicRespDmaWriteMetaData.psn
                    }
                };
                // $display("time=%0t: consumeResp=", $time, fshow(consumeResp));
                payloadConRespQ.enq(consumeResp);

                immAssert(
                    dmaWriteResp.sqpn == atomicRespInfo.atomicRespDmaWriteMetaData.sqpn &&
                    dmaWriteResp.psn  == atomicRespInfo.atomicRespDmaWriteMetaData.psn,
                    "dmaWriteResp SQPN and PSN assertion @ ",
                    $format(
                        "dmaWriteResp.sqpn=%h should == atomicRespInfo.atomicRespDmaWriteMetaData.sqpn=%h",
                        dmaWriteResp.sqpn, atomicRespInfo.atomicRespDmaWriteMetaData.sqpn,
                        ", and dmaWriteResp.psn=%h should == atomicRespInfo.atomicRespDmaWriteMetaData.psn=%h",
                        dmaWriteResp.psn, atomicRespInfo.atomicRespDmaWriteMetaData.psn
                    )
                );
            end
            default: begin
                immFail(
                    "unreachible case @ mkPayloadConsumer",
                    $format("consumeReq.consumeInfo=", fshow(consumeReq.consumeInfo))
                );
            end
        endcase
        // $display(
        //     "time=%0t: genConResp", $time,
        //     ", dmaWriteResp=", fshow(dmaWriteResp),
        //     ", consumeReq=", fshow(consumeReq)
        // );
    endrule

    // TODO: safe error flush that finish pending requests before flush
    // When error, continue send DMA write requests,
    // so as to flush payload data properly later.
    // But discard DMA write responses when error.
    rule flushDmaWriteResp if (cntrlStatus.comm.isERR);
        let dmaWriteResp <- dmaWriteSrv.response.get;
    endrule

    // rule flushPayloadBufPipeOut if (cntrlStatus.comm.isERR);
    //     payloadBufPipeOut.deq;
    // endrule

    rule flushPipelineQ if (cntrlStatus.comm.isERR);
        payloadBufQ.clear;
        pendingConReqQ.clear;
        pendingDmaReqQ.clear;
    endrule

    rule flushPayloadConResp if (cntrlStatus.comm.isERR);
        payloadConRespQ.clear;
    endrule

    // rule cancelPendingDmaWriteReq if (cntrlStatus.comm.isERR && cancelReg[1]);
    //     dmaWriteCntrl.dmaCntrl.cancel;
    //     cancelReg[1] <= False;
    //     // $display("time=%0t: DmaWriteCntrl cancel write", $time);
    // endrule

    // return toGPServer(payloadConReqPipeIn, payloadConRespQ);
    interface respPipeOut = toPipeOut(payloadConRespQ);
endmodule
*/
// TODO: add atomic support
typedef Server#(AtomicOpReq, AtomicOpResp) AtomicSrv;
// Atomic operation will not generate error
module mkAtomicSrv#(CntrlStatus cntrlStatus)(AtomicSrv);
    FIFOF#(AtomicOpReq)   atomicOpReqQ <- mkFIFOF;
    FIFOF#(AtomicOpResp) atomicOpRespQ <- mkFIFOF;

    rule genResp;
        let atomicOpReq = atomicOpReqQ.first;
        atomicOpReqQ.deq;
        // TODO: implement atomic operations
        let atomicOpResp = AtomicOpResp {
            initiator: atomicOpReq.initiator,
            original : atomicOpReq.compData,
            sqpn     : atomicOpReq.sqpn,
            psn      : atomicOpReq.psn
        };
        atomicOpRespQ.enq(atomicOpResp);
    endrule

    return toGPServer(atomicOpReqQ, atomicOpRespQ);
endmodule
