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
    Add#(TLog#(portSz), 1, TLog#(TAdd#(1, portSz))) // portSz must be power of 2
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

typedef Vector#(portSz, DmaReadClt)   DmaReadCltVec#(numeric type portSz);
typedef Vector#(portSz, DmaWriteClt) DmaWriteCltVec#(numeric type portSz);

module mkDmaReadCltArbiter#(DmaReadCltVec#(portSz) dmaReadCltVec)(DmaReadClt) provisos(
    Add#(1, anysize, portSz),
    Add#(TLog#(portSz), 1, TLog#(TAdd#(1, portSz))) // portSz must be power of 2
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

module mkDmaWriteCltArbiter#(DmaWriteCltVec#(portSz) dmaWriteCltVec)(DmaWriteClt) provisos(
    Add#(1, anysize, portSz),
    Add#(TLog#(portSz), 1, TLog#(TAdd#(1, portSz))) // portSz must be power of 2
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

    rule flushWR if (cntrlStatus.comm.isERR);
        let wr = workReqPipeIn.first;
        workReqPipeIn.deq;
        let newPendingWR = genNewPendingWorkReq(wr);
        newPendingWorkReqOutQ.enq(newPendingWR);
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
    method Bool reqHeaderOutNotEmpty();
    method Bool pendingWorkReqNotEmpty();
    // method Bool notGracefulStop();
    // interface PipeOut#(WorkComp) workCompPipeOutSQ;
endinterface

module mkSQ#(
    ContextSQ contextSQ,
    PayloadGenerator payloadGenerator,
    // DmaReadCntrl dmaReadCntrl,
    DmaWriteCntrl dmaWriteCntrl,
    PermCheckSrv permCheckSrv,
    PipeOut#(WorkReq) workReqPipeIn,
    RdmaPktMetaDataAndPayloadPipeOut respPktPipeOut
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

    // let payloadGenerator <- mkPayloadGenerator(
    //     contextSQ.statusSQ, dmaReadCntrl
    // );
    let payloadConsumer <- mkPayloadConsumer(
        contextSQ.statusSQ,
        dmaWriteCntrl,
        respPktPipeOut.payload
        // respHandleSQ.payloadConReqPipeOut
    );

    let reqGenSQ <- mkReqGenSQ(
        contextSQ,
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
        respPktPipeOut.pktMetaData,
        payloadConsumer.request
    );

    let workCompGenSQ <- mkWorkCompGenSQ(
        contextSQ.statusSQ,
        payloadConsumer.response,
        // payloadConsumer.respPipeOut,
        reqGenSQ.workCompGenReqPipeOut,
        respHandleSQ.workCompGenReqPipeOut
        // workCompStatusPipeInFromRQ
    );

    (* no_implicit_conditions, fire_when_enabled *)
    rule resetAndClear if (contextSQ.statusSQ.comm.isReset);
        pendingWorkReqBuf.scanCntrl.clear;

        // $display("time=%0t: reset and clear mkSQ", $time);
    endrule
/*
    rule debug if (
        contextSQ.statusSQ.comm.isERR &&
        (
            reqGenSQ.reqHeaderOutNotEmpty    ||
            pendingWorkReqBuf.fifof.notEmpty ||
            workReqPipeIn.notEmpty
            // payloadGenerator.notGracefulStop
        )
    );
        $display(
            "time=%0t: mkSQ debug", $time,
            ", qpn=%h", contextSQ.statusSQ.comm.getSQPN,
            ", contextSQ.statusSQ.comm.isERR=", fshow(contextSQ.statusSQ.comm.isERR),
            ", workReqPipeIn.notEmpty=", fshow(workReqPipeIn.notEmpty),
            ", reqGenSQ.reqHeaderOutNotEmpty=", fshow(reqGenSQ.reqHeaderOutNotEmpty),
            ", pendingWorkReqBuf.size=%0d", pendingWorkReqBuf.size
            // ", payloadGenerator.notGracefulStop=", fshow(payloadGenerator.notGracefulStop)
        );
    endrule
*/
    interface rdmaReqDataStreamPipeOut = reqGenSQ.rdmaReqDataStreamPipeOut;
    interface workCompSQ = workCompGenSQ;
    method Bool reqHeaderOutNotEmpty() = reqGenSQ.reqHeaderOutNotEmpty;
    // method Bool notGracefulStop() = reqGenSQ.reqHeaderOutNotEmpty || payloadGenerator.notGracefulStop;
    method Bool pendingWorkReqNotEmpty() = pendingWorkReqBuf.fifof.notEmpty;
    // interface workCompPipeOutSQ = workCompPipeOut;
endmodule

interface RQ;
    interface DataStreamPipeOut rdmaRespDataStreamPipeOut;
    interface WorkCompGen workCompRQ;
    method Bool respHeaderOutNotEmpty();
    // method Bool notGracefulStop();
    // interface PipeOut#(WorkComp) workCompPipeOutRQ;
    // interface PipeOut#(WorkCompStatus) workCompStatusPipeOutRQ;
endinterface

module mkRQ#(
    ContextRQ contextRQ,
    PayloadGenerator payloadGenerator,
    // DmaReadCntrl dmaReadCntrl,
    DmaWriteCntrl dmaWriteCntrl,
    PermCheckSrv permCheckSrv,
    RecvReqBuf recvReqBuf,
    RdmaPktMetaDataAndPayloadPipeOut reqPktPipeIn
)(RQ);
    let dupReadAtomicCache <- mkDupReadAtomicCache(
        contextRQ.statusRQ.comm.getPMTU
    );

    // let payloadGenerator <- mkPayloadGenerator(
    //     contextRQ.statusRQ, dmaReadCntrl
    // );
    let payloadConsumer <- mkPayloadConsumer(
        contextRQ.statusRQ,
        dmaWriteCntrl,
        reqPktPipeIn.payload
        // reqHandlerRQ.payloadConReqPipeOut
    );

    let reqHandlerRQ <- mkReqHandleRQ(
        contextRQ,
        payloadGenerator,
        permCheckSrv,
        dupReadAtomicCache,
        recvReqBuf,
        reqPktPipeIn.pktMetaData,
        payloadConsumer.request
    );

    let workCompGenRQ <- mkWorkCompGenRQ(
        contextRQ.statusRQ,
        // payloadConsumer.respPipeOut,
        payloadConsumer.response,
        reqHandlerRQ.workCompGenReqPipeOut
    );

    (* no_implicit_conditions, fire_when_enabled *)
    rule resetAndClear if (contextRQ.statusRQ.comm.isReset);
        dupReadAtomicCache.clear;

        // $display("time=%0t: reset and clear mkRQ", $time);
    endrule

    interface rdmaRespDataStreamPipeOut = reqHandlerRQ.rdmaRespDataStreamPipeOut;
    interface workCompRQ = workCompGenRQ;
    method Bool respHeaderOutNotEmpty() = reqHandlerRQ.respHeaderOutNotEmpty;
    // method Bool notGracefulStop() = reqHandlerRQ.respHeaderOutNotEmpty || payloadGenerator.notGracefulStop;
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
    // interface DataStreamPipeOut  rdmaReqRespPipeOut;
    interface DataStreamPipeOut  rdmaReqPipeOut;
    interface DataStreamPipeOut  rdmaRespPipeOut;
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

    Reg#(Bool)  sqDmaReadCancelReg <- mkReg(False);
    Reg#(Bool)  rqDmaReadCancelReg <- mkReg(False);
    Reg#(Bool) sqDmaWriteCancelReg <- mkReg(False);
    Reg#(Bool) rqDmaWriteCancelReg <- mkReg(False);

    let cntrl <- mkCntrlQP;
    // let dmaArbiter <- mkDmaArbiter4QP;
    DmaReadProxy   dmaReadProxy4SQ   <- mkServerProxy;
    DmaWriteProxy  dmaWriteProxy4SQ  <- mkServerProxy;
    DmaReadProxy   dmaReadProxy4RQ   <- mkServerProxy;
    DmaWriteProxy  dmaWriteProxy4RQ  <- mkServerProxy;
    PermCheckProxy permCheckProxy4RQ <- mkServerProxy;
    PermCheckProxy permCheckProxy4SQ <- mkServerProxy;

    let dmaReadCntrl4RQ <- mkDmaReadCntrl(
        cntrl.contextRQ.statusRQ, dmaReadProxy4RQ.srvPort
    );
    let dmaWriteCntrl4RQ <- mkDmaWriteCntrl(
        cntrl.contextRQ.statusRQ, dmaWriteProxy4RQ.srvPort
    );
    let dmaReadCntrl4SQ <- mkDmaReadCntrl(
        cntrl.contextSQ.statusSQ, dmaReadProxy4SQ.srvPort
    );
    let dmaWriteCntrl4SQ <- mkDmaWriteCntrl(
        cntrl.contextSQ.statusSQ, dmaWriteProxy4SQ.srvPort
    );

    let payloadGenerator4RQ <- mkPayloadGenerator(
        cntrl.contextRQ.statusRQ, dmaReadCntrl4RQ
    );
    let payloadGenerator4SQ <- mkPayloadGenerator(
        cntrl.contextSQ.statusSQ, dmaReadCntrl4SQ
    );

    let reqPktPipe  <- mkRdmaPktMetaDataAndPayloadPipe;
    let respPktPipe <- mkRdmaPktMetaDataAndPayloadPipe;

    let rq <- mkRQ(
        cntrl.contextRQ,
        payloadGenerator4RQ,
        // dmaReadCntrl4RQ,
        dmaWriteCntrl4RQ,
        permCheckProxy4RQ.srvPort,
        recvReqBufPipeOut,
        reqPktPipe.pktPipeOut
    );

    let sq <- mkSQ(
        cntrl.contextSQ,
        payloadGenerator4SQ,
        // dmaReadCntrl4SQ,
        dmaWriteCntrl4SQ,
        permCheckProxy4SQ.srvPort,
        workReqBufPipeOut,
        respPktPipe.pktPipeOut
    );
    // let reqRespPipeOut <- mkFixedBinaryPipeOutArbiter(
    //     rq.rdmaRespDataStreamPipeOut, sq.rdmaReqDataStreamPipeOut
    // );

    (* no_implicit_conditions, fire_when_enabled *)
    rule resetAndClear if (cntrl.contextSQ.statusSQ.comm.isReset);
        recvReqQ.clear;
        workReqQ.clear;

        reqPktPipe.clear;
        respPktPipe.clear;

        sqDmaReadCancelReg  <= False;
        rqDmaReadCancelReg  <= False;
        sqDmaWriteCancelReg <= False;
        rqDmaWriteCancelReg <= False;
        // $display("time=%0t: reset and clear mkQueuePair", $time);
    endrule

    rule errTrigger if (
        cntrl.contextSQ.statusSQ.comm.isNonErr &&
        (rq.workCompRQ.hasErr || sq.workCompSQ.hasErr)
    );
        cntrl.setStateErr;
    endrule

    (* no_implicit_conditions, fire_when_enabled *)
    rule cancelDmaReadRQ if (
        !rqDmaReadCancelReg                 &&
        cntrl.contextSQ.statusSQ.comm.isERR &&
        !(rq.respHeaderOutNotEmpty && payloadGenerator4RQ.payloadNotEmpty)
    );
        dmaReadCntrl4RQ.dmaCntrl.cancel;
        rqDmaReadCancelReg <= True;

        // $display(
        //     "time=%0t: cancelDmaReadRQ", $time,
        //     ", dqpn=%h", cntrl.contextSQ.statusSQ.comm.getSQPN,
        //     ", workReqQ.notEmpty=", fshow(workReqQ.notEmpty),
        //     ", recvReqQ.notEmpty=", fshow(recvReqQ.notEmpty)
        // );
    endrule

    (* no_implicit_conditions, fire_when_enabled *)
    rule cancelDmaReadSQ if (
        !sqDmaReadCancelReg                 &&
        cntrl.contextSQ.statusSQ.comm.isERR &&
        !(sq.reqHeaderOutNotEmpty && payloadGenerator4SQ.payloadNotEmpty)
    );
        dmaReadCntrl4SQ.dmaCntrl.cancel;
        sqDmaReadCancelReg <= True;

        // $display(
        //     "time=%0t: cancelDmaReadSQ", $time,
        //     ", sqpn=%h", cntrl.contextSQ.statusSQ.comm.getSQPN,
        //     ", workReqQ.notEmpty=", fshow(workReqQ.notEmpty),
        //     ", recvReqQ.notEmpty=", fshow(recvReqQ.notEmpty)
        // );
    endrule

    (* no_implicit_conditions, fire_when_enabled *)
    rule cancelDmaWriteRQ if (cntrl.contextSQ.statusSQ.comm.isERR);
        // TODO: support graceful stop for DMA write
        dmaWriteCntrl4RQ.dmaCntrl.cancel;
        rqDmaWriteCancelReg <= True;
    endrule

    (* no_implicit_conditions, fire_when_enabled *)
    rule cancelDmaWriteSQ if (cntrl.contextSQ.statusSQ.comm.isERR);
        // TODO: support graceful stop for DMA write
        dmaWriteCntrl4SQ.dmaCntrl.cancel;
        sqDmaWriteCancelReg <= True;
    endrule

    // (* no_implicit_conditions, fire_when_enabled *)
    (* fire_when_enabled *)
    rule waitGracefulStop if (
        cntrl.contextSQ.statusSQ.comm.isERR &&
        !recvReqQ.notEmpty                  &&
        !workReqQ.notEmpty                  &&
        !sq.pendingWorkReqNotEmpty          &&
        rqDmaReadCancelReg                  &&
        rqDmaWriteCancelReg                 &&
        sqDmaReadCancelReg                  &&
        sqDmaWriteCancelReg                 &&
        dmaReadCntrl4RQ.dmaCntrl.isIdle     &&
        dmaWriteCntrl4RQ.dmaCntrl.isIdle    &&
        dmaReadCntrl4SQ.dmaCntrl.isIdle     &&
        dmaWriteCntrl4SQ.dmaCntrl.isIdle
    );
        // Notify controller when graceful stop
        cntrl.errFlushDone;
        // $display(
        //     "time=%0t: waitGracefulStop", $time,
        //     ", sqpn=%h", cntrl.contextSQ.statusSQ.comm.getSQPN,
        //     ", workReqQ.notEmpty=", fshow(workReqQ.notEmpty),
        //     ", recvReqQ.notEmpty=", fshow(recvReqQ.notEmpty)
        // );
    endrule
/*
    rule debug if (
        cntrl.contextRQ.statusRQ.comm.isERR &&
        cntrl.contextSQ.statusSQ.comm.isERR &&
        !(
            !recvReqQ.notEmpty               &&
            !workReqQ.notEmpty               &&
            !rq.respHeaderOutNotEmpty        &&
            !sq.reqHeaderOutNotEmpty         &&
            !sq.pendingWorkReqNotEmpty       &&
            rqDmaReadCancelReg               &&
            rqDmaWriteCancelReg              &&
            sqDmaReadCancelReg               &&
            sqDmaWriteCancelReg              &&
            dmaReadCntrl4RQ.dmaCntrl.isIdle  &&
            dmaWriteCntrl4RQ.dmaCntrl.isIdle &&
            dmaReadCntrl4SQ.dmaCntrl.isIdle  &&
            dmaWriteCntrl4SQ.dmaCntrl.isIdle
        )
    );
        $display(
            "time=%0t: mkQP debug", $time,
            ", qpn=%h", cntrl.contextSQ.statusSQ.comm.getSQPN,
            ", cntrl.contextRQ.statusRQ.comm.isERR=", fshow(cntrl.contextRQ.statusRQ.comm.isERR),
            ", cntrl.contextSQ.statusSQ.comm.isERR=", fshow(cntrl.contextSQ.statusSQ.comm.isERR),
            ", recvReqQ.notEmpty=", fshow(recvReqQ.notEmpty),
            ", workReqQ.notEmpty=", fshow(workReqQ.notEmpty),
            ", rq.respHeaderOutNotEmpty=", fshow(rq.respHeaderOutNotEmpty),
            ", sq.reqHeaderOutNotEmpty=", fshow(sq.reqHeaderOutNotEmpty),
            ", sq.pendingWorkReqNotEmpty=", fshow(sq.pendingWorkReqNotEmpty),
            ", rqDmaReadCancelReg=", fshow(rqDmaReadCancelReg),
            ", rqDmaWriteCancelReg=", fshow(rqDmaWriteCancelReg),
            ", sqDmaReadCancelReg=", fshow(sqDmaReadCancelReg),
            ", sqDmaWriteCancelReg=", fshow(sqDmaWriteCancelReg),
            ", dmaReadCntrl4RQ.dmaCntrl.isIdle=", fshow(dmaReadCntrl4RQ.dmaCntrl.isIdle),
            ", dmaWriteCntrl4RQ.dmaCntrl.isIdle=", fshow(dmaWriteCntrl4RQ.dmaCntrl.isIdle),
            ", dmaReadCntrl4SQ.dmaCntrl.isIdle=", fshow(dmaReadCntrl4SQ.dmaCntrl.isIdle),
            ", dmaWriteCntrl4SQ.dmaCntrl.isIdle=", fshow(dmaWriteCntrl4SQ.dmaCntrl.isIdle)
        );
    endrule
*/
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
    // interface rdmaReqRespPipeOut = reqRespPipeOut;
    interface rdmaRespPipeOut    = rq.rdmaRespDataStreamPipeOut;
    interface rdmaReqPipeOut     = sq.rdmaReqDataStreamPipeOut;
    interface workCompPipeOutRQ  = rq.workCompRQ.workCompPipeOut;
    interface workCompPipeOutSQ  = sq.workCompSQ.workCompPipeOut;
endmodule
