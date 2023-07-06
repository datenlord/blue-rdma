import ClientServer :: *;
import Cntrs :: *;
import Connectable :: *;
import FIFOF :: *;
import GetPut :: *;
import PAClib :: *;
import Vector :: *;

import Arbitration :: *;
import Controller :: *;
import DataTypes :: *;
import DupReadAtomicCache :: *;
import Headers :: *;
import PayloadConAndGen :: *;
import PrimUtils :: *;
import RetryHandleSQ :: *;
import ReqGenSQ :: *;
import ReqHandleRQ :: *;
import RespHandleSQ :: *;
import Settings :: *;
import SpecialFIFOF :: *;
import WorkCompGen :: *;
import Utils :: *;

typedef ServerProxy#(DmaReadReq, DmaReadResp)   DmaReadProxy;
typedef ServerProxy#(DmaWriteReq, DmaWriteResp) DmaWriteProxy;

typedef ServerProxy#(PermCheckReq, Bool) PermCheckProxy;
typedef Vector#(portSz, PermCheckClt) PermCheckCltVec#(numeric type portSz);

module mkPermCheckCltArbiter#(PermCheckCltVec#(portSz) permCheckCltVec)(PermCheckClt) provisos(
    Add#(1, anysize, portSz),
    Add#(TLog#(portSz), 1, TLog#(TAdd#(portSz, 1))) // portSz must be power of 2
);
    function Bool isPermCheckReqFinished(PermCheckReq req) = True;
    function Bool isPermCheckRespFinished(Bool resp) = True;

    let arbitratedClient <- mkClientArbiter(
        permCheckCltVec,
        isPermCheckReqFinished,
        isPermCheckRespFinished
    );
    return arbitratedClient;
endmodule

typedef Vector#(portSz, DmaReadClt) DmaReadCltVec#(numeric type portSz);
typedef Vector#(portSz, DmaWriteClt) DmaWriteCltVec#(numeric type portSz);

module mkDmaReadCltAribter#(DmaReadCltVec#(portSz) dmaReadCltVec)(DmaReadClt) provisos(
    Add#(1, anysize, portSz),
    Add#(TLog#(portSz), 1, TLog#(TAdd#(portSz, 1))) // portSz must be power of 2
);
    function Bool isDmaReadReqLastFrag(DmaReadReq req) = True;
    function Bool isDmaReadRespLastFrag(DmaReadResp resp) = resp.dataStream.isLast;

    let arbitratedClient <- mkClientArbiter(
        dmaReadCltVec,
        isDmaReadReqLastFrag,
        isDmaReadRespLastFrag
    );
    return arbitratedClient;
endmodule

module mkDmaWriteCltAribter#(DmaWriteCltVec#(portSz) dmaWriteCltVec)(DmaWriteClt) provisos(
    Add#(1, anysize, portSz),
    Add#(TLog#(portSz), 1, TLog#(TAdd#(portSz, 1))) // portSz must be power of 2
);
    function Bool isDmaWriteReqLastFrag(DmaWriteReq req) = req.dataStream.isLast;
    function Bool isDmaWriteRespLastFrag(DmaWriteResp resp) = True;

    let arbitratedClient <- mkClientArbiter(
        dmaWriteCltVec,
        isDmaWriteReqLastFrag,
        isDmaWriteRespLastFrag
    );
    return arbitratedClient;
endmodule

module mkNewPendingWorkReqPipeOut#(
    CntrlStatus cntrlStatus,
    Bool decrPendingReqCntPulse,
    PipeOut#(WorkReq) workReqPipeIn
)(PipeOut#(PendingWorkReq));
    FIFOF#(PendingWorkReq) newPendingWorkReqOutQ <- mkFIFOF;
    CountCF#(PendingReqCnt) pendingNewWorkReqCnt <- mkCountCF(0);

    (* no_implicit_conditions, fire_when_enabled *)
    rule resetAndClear if (cntrlStatus.comm.isReset);
        newPendingWorkReqOutQ.clear;
        pendingNewWorkReqCnt <= 0;

        // $display("time=%0t: reset and clear mkNewPendingWorkReqPipeOut", $time);
    endrule

    rule genPendingWR if (
        cntrlStatus.comm.isRTS &&
        // CountCF has delayed increment and decrement, so less than MAX - 1
        pendingNewWorkReqCnt < (cntrlStatus.comm.getPendingWorkReqNum - 1)
    );
        let wr = workReqPipeIn.first;
        workReqPipeIn.deq;

        pendingNewWorkReqCnt.incrOne;

        let newPendingWR = genNewPendingWorkReq(wr);
        newPendingWorkReqOutQ.enq(newPendingWR);
        // $display("time=%0t:", $time, " pendingNewWorkReqCnt incrOne");
    endrule

    rule decrPendingNewWorkReqCnt if (
        cntrlStatus.comm.isRTS && decrPendingReqCntPulse
    );
        immAssert(
            pendingNewWorkReqCnt > 0,
            "decrPendingNewWorkReqCnt assertion @ mkNewPendingWorkReqPipeOut",
            $format(
                "pendingNewWorkReqCnt=%0d", fshow(pendingNewWorkReqCnt),
                " should larger than zero when decrOne"
            )
        );
        pendingNewWorkReqCnt.decrOne;
        // $display("time=%0t:", $time, " pendingNewWorkReqCnt decrOne");
    endrule

    rule checkPendingNewWorkReqCnt;
        immAssert(
            fromInteger(valueOf(MAX_QP_WR)) >= pendingNewWorkReqCnt,
            "pendingNewWorkReqCnt assertion @ mkNewPendingWorkReqPipeOut",
            $format(
                "pendingNewWorkReqCnt=%0d", pendingNewWorkReqCnt,
                " should be less than MAX_QP_WR=%0d", valueOf(MAX_QP_WR)
            )
        );
        // $display("time=%0t:", $time, " pendingNewWorkReqCnt=%0d", pendingNewWorkReqCnt);
    endrule

    return toPipeOut(newPendingWorkReqOutQ);
endmodule

interface SQ;
    interface DataStreamPipeOut rdmaReqDataStreamPipeOut;
    interface WorkCompGen workCompSQ;
    // interface PipeOut#(WorkComp) workCompPipeOutSQ;
endinterface

module mkSQ#(
    ContextSQ contextSQ,
    DmaReadCntrl dmaReadCntrl,
    DmaWriteCntrl dmaWriteCntrl,
    // DmaReadSrv dmaReadSrv,
    // DmaWriteSrv dmaWriteSrv,
    PermCheckSrv permCheckSrv,
    PipeOut#(WorkReq) workReqPipeIn,
    RdmaPktMetaDataAndPayloadPipeOut respPktPipeOut
    // PipeOut#(WorkCompStatus) workCompStatusPipeInFromRQ
)(SQ);
    PendingWorkReqBuf pendingWorkReqBuf <- mkScanFIFOF;

    let retryHandler <- mkRetryHandleSQ(
        contextSQ.statusSQ, pendingWorkReqBuf.fifof.notEmpty, pendingWorkReqBuf.scanCntrl
    );

    let newPendingWorkReqPiptOut <- mkNewPendingWorkReqPipeOut(
        contextSQ.statusSQ, pendingWorkReqBuf.scanCntrl.deqPulse, workReqPipeIn
    );
    // TODO: add soft reset
    let pendingWorkReqPipeOut <- mkPipeOutMux(
        pendingWorkReqBuf.scanCntrl.hasScanOut,
        pendingWorkReqBuf.scanPipeOut,
        newPendingWorkReqPiptOut
    );

    let payloadGenerator <- mkPayloadGenerator(
        contextSQ.statusSQ, dmaReadCntrl
    );
    let reqGenSQ <- mkReqGenSQ(
        contextSQ,
        // dmaReadSrv,
        payloadGenerator,
        pendingWorkReqPipeOut,
        pendingWorkReqBuf.fifof.notEmpty
    );
    let pendingWorkReq2Q <- mkConnection(
        toGet(reqGenSQ.pendingWorkReqPipeOut), toPut(pendingWorkReqBuf.fifof)
    );

    let respHandleSQ <- mkRespHandleSQ(
        contextSQ,
        retryHandler,
        permCheckSrv,
        toPipeOut(pendingWorkReqBuf.fifof),
        respPktPipeOut.pktMetaData
    );

    let payloadConsumer <- mkPayloadConsumer(
        contextSQ.statusSQ,
        respPktPipeOut.payload,
        // dmaWriteSrv,
        dmaWriteCntrl,
        respHandleSQ.payloadConReqPipeOut
    );

    let workCompGenSQ <- mkWorkCompGenSQ(
        contextSQ.statusSQ,
        payloadConsumer.respPipeOut,
        reqGenSQ.workCompGenReqPipeOut,
        respHandleSQ.workCompGenReqPipeOut
        // workCompStatusPipeInFromRQ
    );

    (* no_implicit_conditions, fire_when_enabled *)
    rule resetAndClear if (contextSQ.statusSQ.comm.isReset);
        pendingWorkReqBuf.scanCntrl.clear;

        // $display("time=%0t: reset and clear mkSQ", $time);
    endrule

    interface rdmaReqDataStreamPipeOut = reqGenSQ.rdmaReqDataStreamPipeOut;
    interface workCompSQ = workCompGenSQ;
    // interface workCompPipeOutSQ = workCompPipeOut;
endmodule

interface RQ;
    interface DataStreamPipeOut rdmaRespDataStreamPipeOut;
    interface WorkCompGen workCompRQ;
    // interface PipeOut#(WorkComp) workCompPipeOutRQ;
    // interface PipeOut#(WorkCompStatus) workCompStatusPipeOutRQ;
endinterface

module mkRQ#(
    ContextRQ contextRQ,
    DmaReadCntrl dmaReadCntrl,
    DmaWriteCntrl dmaWriteCntrl,
    // DmaReadSrv dmaReadSrv,
    // DmaWriteSrv dmaWriteSrv,
    PermCheckSrv permCheckSrv,
    RecvReqBuf recvReqBuf,
    RdmaPktMetaDataAndPayloadPipeOut reqPktPipeIn
)(RQ);
    let dupReadAtomicCache <- mkDupReadAtomicCache(
        contextRQ.statusRQ.comm.getPMTU
    );

    let payloadGenerator <- mkPayloadGenerator(
        contextRQ.statusRQ, dmaReadCntrl
    );
    let reqHandlerRQ <- mkReqHandleRQ(
        contextRQ,
        // dmaReadSrv,
        payloadGenerator,
        permCheckSrv,
        dupReadAtomicCache,
        recvReqBuf,
        reqPktPipeIn.pktMetaData
    );

    let payloadConsumer <- mkPayloadConsumer(
        contextRQ.statusRQ,
        reqPktPipeIn.payload,
        // dmaWriteSrv,
        dmaWriteCntrl,
        reqHandlerRQ.payloadConReqPipeOut
    );

    let workCompGenRQ <- mkWorkCompGenRQ(
        contextRQ.statusRQ,
        payloadConsumer.respPipeOut,
        reqHandlerRQ.workCompGenReqPipeOut
    );

    (* no_implicit_conditions, fire_when_enabled *)
    rule resetAndClear if (contextRQ.statusRQ.comm.isReset);
        dupReadAtomicCache.clear;

        // $display("time=%0t: reset and clear mkRQ", $time);
    endrule

    interface rdmaRespDataStreamPipeOut = reqHandlerRQ.rdmaRespDataStreamPipeOut;
    interface workCompRQ = workCompGenRQ;
    // interface workCompPipeOutRQ = workCompGenRQ.workCompPipeOut;
    // interface workCompStatusPipeOutRQ = workCompGenRQ.workCompStatusPipeOutRQ;
endmodule

interface DmaArbiter4QP;
    interface DmaReadClt  dmaReadClt;
    interface DmaWriteClt dmaWriteClt;
    interface DmaReadSrv  dmaReadSrv4RQ;
    interface DmaWriteSrv dmaWriteSrv4RQ;
    interface DmaReadSrv  dmaReadSrv4SQ;
    interface DmaWriteSrv dmaWriteSrv4SQ;
endinterface

module mkDmaArbiter4QP(DmaArbiter4QP);
    ServerProxy#(DmaReadReq, DmaReadResp)    dmaReadProxy <- mkServerProxy;
    ServerProxy#(DmaWriteReq, DmaWriteResp) dmaWriteProxy <- mkServerProxy;

    function Bool isDmaReadReqLastFrag(DmaReadReq req) = True;
    function Bool isDmaReadRespLastFrag(DmaReadResp resp) = resp.dataStream.isLast;

    Vector#(2, DmaReadSrv) dmaReadSrvVec <- mkServerArbiter(
        dmaReadProxy.srvPort,
        isDmaReadReqLastFrag,
        isDmaReadRespLastFrag
    );

    function Bool isDmaWriteReqLastFrag(DmaWriteReq req) = req.dataStream.isLast;
    function Bool isDmaWriteRespLastFrag(DmaWriteResp resp) = True;

    Vector#(2, DmaWriteSrv) dmaWriteSrvVec <- mkServerArbiter(
        dmaWriteProxy.srvPort,
        isDmaWriteReqLastFrag,
        isDmaWriteRespLastFrag
    );

    interface dmaReadClt     = dmaReadProxy.cltPort;
    interface dmaWriteClt    = dmaWriteProxy.cltPort;

    interface dmaReadSrv4RQ  = dmaReadSrvVec[0];
    interface dmaWriteSrv4RQ = dmaWriteSrvVec[0];
    interface dmaReadSrv4SQ  = dmaReadSrvVec[1];
    interface dmaWriteSrv4SQ = dmaWriteSrvVec[1];
endmodule
/*
module mkDmaArbiter4QP(DmaArbiter4QP);
    FIFOF#(DmaReadReq)     dmaReadReqQ4Clt <- mkFIFOF;
    FIFOF#(DmaReadResp)   dmaReadRespQ4Clt <- mkFIFOF;
    FIFOF#(DmaWriteReq)   dmaWriteReqQ4Clt <- mkFIFOF;
    FIFOF#(DmaWriteResp) dmaWriteRespQ4Clt <- mkFIFOF;

    FIFOF#(DmaReadReq)     dmaReadReqQ4RQ <- mkFIFOF;
    FIFOF#(DmaReadResp)   dmaReadRespQ4RQ <- mkFIFOF;
    FIFOF#(DmaWriteReq)   dmaWriteReqQ4RQ <- mkFIFOF;
    FIFOF#(DmaWriteResp) dmaWriteRespQ4RQ <- mkFIFOF;

    FIFOF#(DmaReadReq)     dmaReadReqQ4SQ <- mkFIFOF;
    FIFOF#(DmaReadResp)   dmaReadRespQ4SQ <- mkFIFOF;
    FIFOF#(DmaWriteReq)   dmaWriteReqQ4SQ <- mkFIFOF;
    FIFOF#(DmaWriteResp) dmaWriteRespQ4SQ <- mkFIFOF;

    // RQ has higher priority than SQ when issueing DMA requests
    // and receiving DMA responses.
    rule issueDmaReadReq;
        if (dmaReadReqQ4RQ.notEmpty) begin
            let rqDmaReadReq = dmaReadReqQ4RQ.first;
            dmaReadReqQ4RQ.deq;
            dmaReadReqQ4Clt.enq(rqDmaReadReq);
        end
        else if (dmaReadReqQ4SQ.notEmpty) begin
            let sqDmaReadReq = dmaReadReqQ4SQ.first;
            dmaReadReqQ4SQ.deq;
            dmaReadReqQ4Clt.enq(sqDmaReadReq);
        end
    endrule

    rule issueDmaWriteReq;
        if (dmaWriteReqQ4RQ.notEmpty) begin
            let rqDmaWriteReq = dmaWriteReqQ4RQ.first;
            dmaWriteReqQ4RQ.deq;
            dmaWriteReqQ4Clt.enq(rqDmaWriteReq);
        end
        else if (dmaWriteReqQ4SQ.notEmpty) begin
            let sqDmaWriteReq = dmaWriteReqQ4SQ.first;
            dmaWriteReqQ4SQ.deq;
            dmaWriteReqQ4Clt.enq(sqDmaWriteReq);
        end
    endrule

    rule recvDmaReadResp;
        let dmaReadResp = dmaReadRespQ4Clt.first;
        dmaReadRespQ4Clt.deq;
        case (dmaReadResp.initiator)
            DMA_SRC_RQ_RD    ,
            DMA_SRC_RQ_WR    ,
            DMA_SRC_RQ_DUP_RD,
            DMA_SRC_RQ_ATOMIC: dmaReadRespQ4RQ.enq(dmaReadResp);
            default           : dmaReadRespQ4SQ.enq(dmaReadResp);
        endcase
    endrule

    rule recvDmaWriteResp;
        let dmaWriteResp = dmaWriteRespQ4Clt.first;
        dmaWriteRespQ4Clt.deq;
        case (dmaWriteResp.initiator)
            DMA_SRC_RQ_RD    ,
            DMA_SRC_RQ_WR    ,
            DMA_SRC_RQ_DUP_RD,
            DMA_SRC_RQ_ATOMIC: dmaWriteRespQ4RQ.enq(dmaWriteResp);
            default           : dmaWriteRespQ4SQ.enq(dmaWriteResp);
        endcase
    endrule

    interface dmaReadClt     = toGPClient(dmaReadReqQ4Clt,  dmaReadRespQ4Clt);
    interface dmaWriteClt    = toGPClient(dmaWriteReqQ4Clt, dmaWriteRespQ4Clt);

    interface dmaReadSrv4RQ  = toGPServer(dmaReadReqQ4RQ,  dmaReadRespQ4RQ);
    interface dmaWriteSrv4RQ = toGPServer(dmaWriteReqQ4RQ, dmaWriteRespQ4RQ);
    interface dmaReadSrv4SQ  = toGPServer(dmaReadReqQ4SQ,  dmaReadRespQ4SQ);
    interface dmaWriteSrv4SQ = toGPServer(dmaWriteReqQ4SQ, dmaWriteRespQ4SQ);
endmodule
*/
interface RdmaPktMetaDataAndPayloadPipeIn;
    interface Put#(RdmaPktMetaData) pktMetaData;
    interface Put#(DataStream) payload;
endinterface

instance Connectable#(
    RdmaPktMetaDataAndPayloadPipeOut, RdmaPktMetaDataAndPayloadPipeIn
);
    module mkConnection#(
        RdmaPktMetaDataAndPayloadPipeOut pipeOut,
        RdmaPktMetaDataAndPayloadPipeIn pipeIn
    )(Empty);
        mkConnection(toGet(pipeOut.pktMetaData), pipeIn.pktMetaData);
        mkConnection(toGet(pipeOut.payload), pipeIn.payload);
        // rule pktMetaDataPipe;
        //     let pktMetaData = pipeOut.pktMetaData.first;
        //     pipeOut.pktMetaData.deq;
        //     pipeIn.pktMetaData.put(pktMetaData);
        //     // $display("time=%0t:", $time, " mkConnection, pktMetaData=", fshow(pktMetaData));
        // endrule

        // rule payloadPipe;
        //     let payload = pipeOut.payload.first;
        //     pipeOut.payload.deq;
        //     pipeIn.payload.put(payload);
        //     // $display("time=%0t:", $time, " mkConnection, payload=", fshow(payload));
        // endrule
    endmodule
endinstance

interface RdmaPktMetaDataAndPayloadPipe;
    interface RdmaPktMetaDataAndPayloadPipeOut pktPipeOut;
    interface RdmaPktMetaDataAndPayloadPipeIn  pktPipeIn;
    method Action clear();
endinterface

module mkRdmaPktMetaDataAndPayloadPipe(RdmaPktMetaDataAndPayloadPipe);
    FIFOF#(RdmaPktMetaData) metaDataQ <- mkFIFOF;
    FIFOF#(DataStream)       payloadQ <- mkFIFOF;

    interface pktPipeOut = interface RdmaPktMetaDataAndPayloadPipeOut;
        interface pktMetaData = toPipeOut(metaDataQ);
        interface payload = toPipeOut(payloadQ);
    endinterface;

    interface pktPipeIn = interface RdmaPktMetaDataAndPayloadPipeIn;
        interface pktMetaData = toPut(metaDataQ);
        interface payload = toPut(payloadQ);
    endinterface;

    method Action clear();
        metaDataQ.clear;
        payloadQ.clear;
    endmethod
endmodule

interface QueuePair;
    // Input
    interface SrvPortQP     srvPortQP;
    interface Put#(RecvReq) recvReqIn;
    interface Put#(WorkReq) workReqIn;
    // interface DmaReadClt    dmaReadClt;
    // interface DmaWriteClt   dmaWriteClt;
    interface DmaReadClt    dmaReadClt4RQ;
    interface DmaWriteClt   dmaWriteClt4RQ;
    interface DmaReadClt    dmaReadClt4SQ;
    interface DmaWriteClt   dmaWriteClt4SQ;
    interface PermCheckClt  permCheckClt4RQ;
    interface PermCheckClt  permCheckClt4SQ;
    interface RdmaPktMetaDataAndPayloadPipeIn reqPktPipeIn;
    interface RdmaPktMetaDataAndPayloadPipeIn respPktPipeIn;
    // Output
    interface CntrlStatus        statusSQ;
    interface CntrlStatus        statusRQ;
    interface DataStreamPipeOut  rdmaReqRespPipeOut;
    interface PipeOut#(WorkComp) workCompPipeOutRQ;
    interface PipeOut#(WorkComp) workCompPipeOutSQ;
endinterface

(* synthesize *)
module mkQP(QueuePair);
    // TODO: change WR and RR queues to mkSizedFIFOF
    FIFOF#(RecvReq) recvReqQ <- mkSizedFIFOF(valueOf(MAX_QP_WR));
    FIFOF#(WorkReq) workReqQ <- mkFIFOF;
    let recvReqBufPipeOut = toPipeOut(recvReqQ);
    let workReqBufPipeOut = toPipeOut(workReqQ);

    let cntrl <- mkCntrlQP;
    // let dmaArbiter <- mkDmaArbiter4QP;
    DmaReadProxy   dmaReadProxy4SQ   <- mkServerProxy;
    DmaWriteProxy  dmaWriteProxy4SQ  <- mkServerProxy;
    DmaReadProxy   dmaReadProxy4RQ   <- mkServerProxy;
    DmaWriteProxy  dmaWriteProxy4RQ  <- mkServerProxy;
    PermCheckProxy permCheckProxy4RQ <- mkServerProxy;
    PermCheckProxy permCheckProxy4SQ <- mkServerProxy;

    let dmaReadCntrl4RQ <- mkDmaReadCntrl(dmaReadProxy4RQ.srvPort);
    let dmaWriteCntrl4RQ <- mkDmaWriteCntrl(
        cntrl.contextRQ.statusRQ, dmaWriteProxy4RQ.srvPort
    );
    let dmaReadCntrl4SQ <- mkDmaReadCntrl(dmaReadProxy4SQ.srvPort);
    let dmaWriteCntrl4SQ <- mkDmaWriteCntrl(
        cntrl.contextSQ.statusSQ, dmaWriteProxy4SQ.srvPort
    );

    let reqPktPipe  <- mkRdmaPktMetaDataAndPayloadPipe;
    let respPktPipe <- mkRdmaPktMetaDataAndPayloadPipe;

    let rq <- mkRQ(
        cntrl.contextRQ,
        // dmaArbiter.dmaReadSrv4RQ,
        // dmaArbiter.dmaWriteSrv4RQ,
        dmaReadCntrl4RQ,
        dmaWriteCntrl4RQ,
        // dmaReadProxy4RQ.srvPort,
        // dmaWriteProxy4RQ.srvPort,
        permCheckProxy4RQ.srvPort,
        recvReqBufPipeOut,
        reqPktPipe.pktPipeOut
    );

    let sq <- mkSQ(
        cntrl.contextSQ,
        // dmaArbiter.dmaReadSrv4SQ,
        // dmaArbiter.dmaWriteSrv4SQ,
        dmaReadCntrl4SQ,
        dmaWriteCntrl4SQ,
        // dmaReadProxy4SQ.srvPort,
        // dmaWriteProxy4SQ.srvPort,
        permCheckProxy4SQ.srvPort,
        workReqBufPipeOut,
        respPktPipe.pktPipeOut
        // rq.workCompStatusPipeOutRQ
    );
    let reqRespPipeOut <- mkFixedBinaryPipeOutArbiter(
        rq.rdmaRespDataStreamPipeOut, sq.rdmaReqDataStreamPipeOut
    );

    (* no_implicit_conditions, fire_when_enabled *)
    rule resetAndClear if (cntrl.contextSQ.statusSQ.comm.isReset);
        recvReqQ.clear;
        workReqQ.clear;

        reqPktPipe.clear;
        respPktPipe.clear;

        // $display("time=%0t: reset and clear mkQueuePair", $time);
    endrule

    rule errTrigger if (
        cntrl.contextSQ.statusSQ.comm.isNonErr &&
        (rq.workCompRQ.hasErr || sq.workCompSQ.hasErr)
    );
        cntrl.setStateErr;
    endrule

    // TODO: check error flush done
    rule errFlush if (cntrl.contextSQ.statusSQ.comm.isERR);
        // TODO: if pending WR queue is empty, then error flush is done
        if (!workReqQ.notEmpty && !recvReqQ.notEmpty) begin
            // Notify controller when flush done
            cntrl.errFlushDone;
            $display(
                "time=%0t:", $time,
                " error flush done, workReqQ.notEmpty=", fshow(workReqQ.notEmpty),
                ", recvReqQ.notEmpty=", fshow(recvReqQ.notEmpty)
            );
        end
    endrule

    rule resetQP if (
        cntrl.contextSQ.statusSQ.comm.isUnknown &&
        cntrl.contextRQ.statusRQ.comm.isUnknown &&
        dmaReadCntrl4RQ.dmaCntrl.isIdle         &&
        dmaWriteCntrl4RQ.dmaCntrl.isIdle        &&
        dmaReadCntrl4SQ.dmaCntrl.isIdle         &&
        dmaWriteCntrl4SQ.dmaCntrl.isIdle
    );
        cntrl.setStateReset;
    endrule

    interface srvPortQP       = cntrl.srvPort;
    interface recvReqIn       = toPut(recvReqQ);
    interface workReqIn       = toPut(workReqQ);
    // interface dmaReadClt      = dmaArbiter.dmaReadClt;
    // interface dmaWriteClt     = dmaArbiter.dmaWriteClt;
    interface dmaReadClt4RQ   = dmaReadProxy4RQ.cltPort;
    interface dmaWriteClt4RQ  = dmaWriteProxy4RQ.cltPort;
    interface dmaReadClt4SQ   = dmaReadProxy4SQ.cltPort;
    interface dmaWriteClt4SQ  = dmaWriteProxy4SQ.cltPort;
    interface permCheckClt4RQ = permCheckProxy4RQ.cltPort;
    interface permCheckClt4SQ = permCheckProxy4SQ.cltPort;
    interface reqPktPipeIn    = reqPktPipe.pktPipeIn;
    interface respPktPipeIn   = respPktPipe.pktPipeIn;

    interface statusSQ           = cntrl.contextSQ.statusSQ;
    interface statusRQ           = cntrl.contextRQ.statusRQ;
    interface rdmaReqRespPipeOut = reqRespPipeOut;
    interface workCompPipeOutRQ  = rq.workCompRQ.workCompPipeOut;
    interface workCompPipeOutSQ  = sq.workCompSQ.workCompPipeOut;
endmodule
