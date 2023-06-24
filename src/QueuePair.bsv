import Arbitration :: *;
import ClientServer :: *;
import Cntrs :: *;
import Connectable :: *;
import FIFOF :: *;
import GetPut :: *;
import PAClib :: *;
import Vector :: *;

import Controller :: *;
import DataTypes :: *;
import DupReadAtomicCache :: *;
import InputPktHandle :: *;
import Headers :: *;
import MetaData :: *;
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

typedef Client#(DmaReadReq, DmaReadResp)        DmaReadClt;
typedef Client#(DmaWriteReq, DmaWriteResp)      DmaWriteClt;
typedef ServerProxy#(DmaReadReq, DmaReadResp)   DmaReadProxy;
typedef ServerProxy#(DmaWriteReq, DmaWriteResp) DmaWriteProxy;
typedef Client#(PermCheckInfo, Bool)            PermCheckClt;
typedef ServerProxy#(PermCheckInfo, Bool)       PermCheckProxy;

typedef Vector#(portSz, PermCheckClt) PermCheckCltVec#(numeric type portSz);

module mkPermCheckCltArbiter#(PermCheckCltVec#(portSz) permCheckCltVec)(PermCheckClt) provisos(
    Add#(1, anysize, portSz),
    Add#(TLog#(portSz), 1, TLog#(TAdd#(portSz, 1))) // portSz must be power of 2
);
    function Bool isPermCheckReqFinished(PermCheckInfo req) = True;
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
    PipeOut#(WorkReq) workReqPipeIn
)(PipeOut#(PendingWorkReq));
    FIFOF#(PendingWorkReq) newPendingWorkReqOutQ <- mkFIFOF;

    rule genPendingWR;
        let wr = workReqPipeIn.first;
        workReqPipeIn.deq;

        let newPendingWR = genNewPendingWorkReq(wr);
        newPendingWorkReqOutQ.enq(newPendingWR);
    endrule

    return convertFifo2PipeOut(newPendingWorkReqOutQ);
endmodule

interface SQ;
    interface DataStreamPipeOut rdmaReqDataStreamPipeOut;
    interface PipeOut#(WorkComp) workCompPipeOutSQ;
endinterface

module mkSQ#(
    Controller cntrl,
    DmaReadSrv dmaReadSrv,
    DmaWriteSrv dmaWriteSrv,
    PermCheckMR permCheckMR,
    PipeOut#(WorkReq) workReqPipeIn,
    RdmaPktMetaDataAndPayloadPipeOut respPktPipeOut,
    PipeOut#(WorkCompStatus) workCompStatusPipeInFromRQ
)(SQ);
    PendingWorkReqBuf pendingWorkReqBuf <- mkScanFIFOF;

    let retryHandler <- mkRetryHandleSQ(
        cntrl, pendingWorkReqBuf.fifof.notEmpty, pendingWorkReqBuf.scanCntrl
    );

    let newPendingWorkReqPiptOut <- mkNewPendingWorkReqPipeOut(workReqPipeIn);
    // let newPendingWorkReqPiptOut = genNewPendingWorkReqPipeOut(workReqPipeIn);
    let pendingWorkReqPipeOut <- mkPipeOutMux(
        pendingWorkReqBuf.scanCntrl.hasScanOut,
        pendingWorkReqBuf.scanPipeOut,
        newPendingWorkReqPiptOut
    );

    let reqGenSQ <- mkReqGenSQ(
        cntrl, dmaReadSrv, pendingWorkReqPipeOut, pendingWorkReqBuf.fifof.notEmpty
    );
    let pendingWorkReq2Q <- mkConnectPendingWorkReqPipeOut2PendingWorkReqQ(
        reqGenSQ.pendingWorkReqPipeOut, pendingWorkReqBuf.fifof
    );

    let respHandleSQ <- mkRespHandleSQ(
        cntrl,
        retryHandler,
        permCheckMR,
        convertFifo2PipeOut(pendingWorkReqBuf.fifof),
        respPktPipeOut.pktMetaData
    );

    let payloadConsumer <- mkPayloadConsumer(
        cntrl,
        respPktPipeOut.payload,
        dmaWriteSrv,
        respHandleSQ.payloadConReqPipeOut
    );

    let workCompPipeOut <- mkWorkCompGenSQ(
        cntrl,
        payloadConsumer.respPipeOut,
        reqGenSQ.workCompGenReqPipeOut,
        respHandleSQ.workCompGenReqPipeOut,
        workCompStatusPipeInFromRQ
    );

    interface rdmaReqDataStreamPipeOut = reqGenSQ.rdmaReqDataStreamPipeOut;
    interface workCompPipeOutSQ = workCompPipeOut;
endmodule

interface RQ;
    interface DataStreamPipeOut rdmaRespDataStreamPipeOut;
    interface PipeOut#(WorkComp) workCompPipeOutRQ;
    interface PipeOut#(WorkCompStatus) workCompStatusPipeOutRQ;
endinterface

module mkRQ#(
    Controller cntrl,
    DmaReadSrv dmaReadSrv,
    DmaWriteSrv dmaWriteSrv,
    PermCheckMR permCheckMR,
    RecvReqBuf recvReqBuf,
    RdmaPktMetaDataAndPayloadPipeOut reqPktPipeIn
)(RQ);
    let dupReadAtomicCache <- mkDupReadAtomicCache(cntrl.getPMTU);

    let reqHandlerRQ <- mkReqHandleRQ(
        cntrl,
        dmaReadSrv,
        permCheckMR,
        dupReadAtomicCache,
        recvReqBuf,
        reqPktPipeIn.pktMetaData
    );

    let payloadConsumer <- mkPayloadConsumer(
        cntrl,
        reqPktPipeIn.payload,
        dmaWriteSrv,
        reqHandlerRQ.payloadConReqPipeOut
    );

    let workCompGenRQ <- mkWorkCompGenRQ(
        cntrl,
        payloadConsumer.respPipeOut,
        reqHandlerRQ.workCompGenReqPipeOut
    );

    interface rdmaRespDataStreamPipeOut = reqHandlerRQ.rdmaRespDataStreamPipeOut;
    interface workCompPipeOutRQ = workCompGenRQ.workCompPipeOut;
    interface workCompStatusPipeOutRQ = workCompGenRQ.workCompStatusPipeOutRQ;
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
            DMA_INIT_RQ_RD    ,
            DMA_INIT_RQ_WR    ,
            DMA_INIT_RQ_DUP_RD,
            DMA_INIT_RQ_ATOMIC: dmaReadRespQ4RQ.enq(dmaReadResp);
            default           : dmaReadRespQ4SQ.enq(dmaReadResp);
        endcase
    endrule

    rule recvDmaWriteResp;
        let dmaWriteResp = dmaWriteRespQ4Clt.first;
        dmaWriteRespQ4Clt.deq;
        case (dmaWriteResp.initiator)
            DMA_INIT_RQ_RD    ,
            DMA_INIT_RQ_WR    ,
            DMA_INIT_RQ_DUP_RD,
            DMA_INIT_RQ_ATOMIC: dmaWriteRespQ4RQ.enq(dmaWriteResp);
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
endinterface

module mkRdmaPktMetaDataAndPayloadPipe(RdmaPktMetaDataAndPayloadPipe);
    FIFOF#(RdmaPktMetaData) metaDataQ <- mkFIFOF;
    FIFOF#(DataStream)       payloadQ <- mkFIFOF;

    interface pktPipeOut = interface RdmaPktMetaDataAndPayloadPipeOut;
        interface pktMetaData = convertFifo2PipeOut(metaDataQ);
        interface payload = convertFifo2PipeOut(payloadQ);
    endinterface;

    interface pktPipeIn = interface RdmaPktMetaDataAndPayloadPipeIn;
        interface pktMetaData = toPut(metaDataQ);
        interface payload = toPut(payloadQ);
    endinterface;
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
    interface DataStreamPipeOut  rdmaReqRespPipeOut;
    interface PipeOut#(WorkComp) workCompPipeOutRQ;
    interface PipeOut#(WorkComp) workCompPipeOutSQ;
endinterface

(* synthesize *)
module mkQP(QueuePair);
    // TODO: change WR and RR queues to mkSizedFIFOF
    FIFOF#(RecvReq) recvReqQ <- mkFIFOF;
    FIFOF#(WorkReq) workReqQ <- mkFIFOF;
    let recvReqBufPipeOut = convertFifo2PipeOut(recvReqQ);
    let workReqBufPipeOut = convertFifo2PipeOut(workReqQ);

    let cntrl <- mkController;
    // let dmaArbiter <- mkDmaArbiter4QP;
    DmaReadProxy   dmaReadProxy4SQ   <- mkServerProxy;
    DmaWriteProxy  dmaWriteProxy4SQ  <- mkServerProxy;
    DmaReadProxy   dmaReadProxy4RQ   <- mkServerProxy;
    DmaWriteProxy  dmaWriteProxy4RQ  <- mkServerProxy;
    PermCheckProxy permCheckProxy4RQ <- mkServerProxy;
    PermCheckProxy permCheckProxy4SQ <- mkServerProxy;

    let reqPktPipe  <- mkRdmaPktMetaDataAndPayloadPipe;
    let respPktPipe <- mkRdmaPktMetaDataAndPayloadPipe;

    let rq <- mkRQ(
        cntrl,
        // dmaArbiter.dmaReadSrv4RQ,
        // dmaArbiter.dmaWriteSrv4RQ,
        dmaReadProxy4RQ.srvPort,
        dmaWriteProxy4RQ.srvPort,
        permCheckProxy4RQ.srvPort,
        recvReqBufPipeOut,
        reqPktPipe.pktPipeOut
    );

    let sq <- mkSQ(
        cntrl,
        // dmaArbiter.dmaReadSrv4SQ,
        // dmaArbiter.dmaWriteSrv4SQ,
        dmaReadProxy4SQ.srvPort,
        dmaWriteProxy4SQ.srvPort,
        permCheckProxy4SQ.srvPort,
        workReqBufPipeOut,
        respPktPipe.pktPipeOut,
        rq.workCompStatusPipeOutRQ
    );
    let reqRespPipeOut <- mkFixedBinaryPipeOutArbiter(
        rq.rdmaRespDataStreamPipeOut, sq.rdmaReqDataStreamPipeOut
    );

    // TODO: check error flush done
    rule errFlush if (cntrl.isERR);
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

    // method Controller getCntrl() = cntrl;
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

    interface rdmaReqRespPipeOut = reqRespPipeOut;
    interface workCompPipeOutRQ  = rq.workCompPipeOutRQ;
    interface workCompPipeOutSQ  = sq.workCompPipeOutSQ;
endmodule

typedef union tagged {
    WorkReq WR;
    RecvReq RR;
} WorkReqOrRecvReq deriving(Bits);

// TODO: check QP state when dispatching WR and RR
module mkWorkReqAndRecvReqDispatcher#(
    PipeOut#(WorkReqOrRecvReq) workReqOrRecvReqPipeIn
)(Tuple2#(Vector#(MAX_QP, PipeOut#(WorkReq)), Vector#(MAX_QP, PipeOut#(RecvReq))));
    Vector#(MAX_QP, FIFOF#(WorkReq)) workReqOutVec <- replicateM(mkFIFOF);
    Vector#(MAX_QP, FIFOF#(RecvReq)) recvReqOutVec <- replicateM(mkFIFOF);

    rule dispatchWorkReqOrRecvReq;
        case (workReqOrRecvReqPipeIn.first) matches
            tagged WR .wr: begin
                let qpIndex = getIndexQP(wr.sqpn);
                workReqOutVec[qpIndex].enq(wr);
            end
            tagged RR .rr: begin
                let qpIndex = getIndexQP(rr.sqpn);
                recvReqOutVec[qpIndex].enq(rr);
            end
        endcase
        workReqOrRecvReqPipeIn.deq;
    endrule

    return tuple2(
        map(convertFifo2PipeOut, workReqOutVec),
        map(convertFifo2PipeOut, recvReqOutVec)
    );
endmodule
/*
interface TransportLayerRDMA;
    interface Put#(DataStream) rdmaDataStreamInput;
    interface DataStreamPipeOut rdmaDataStreamPipeOut;
    interface Server#(WorkReqOrRecvReq, WorkComp) srvWorkReqRecvReqWorkComp;
    interface MetaDataSrv srvMetaData;
endinterface

(* synthesize *)
module mkTransportLayerRDMA(TransportLayerRDMA);
    FIFOF#(DataStream) inputDataStreamQ <- mkFIFOF;
    let rdmaReqRespPipeIn = convertFifo2PipeOut(inputDataStreamQ);

    FIFOF#(WorkReqOrRecvReq) inputWorkReqOrRecvReqQ <- mkFIFOF;

    let pdMetaData  <- mkMetaDataPDs;
    let permCheckMR <- mkPermCheckMR(pdMetaData);
    let qpMetaData  <- mkMetaDataQPs;
    let metaDataSrv <- mkMetaDataSrv(pdMetaData, qpMetaData);

    // let qpInitAttr = QpInitAttr {
    //     qpType  : IBV_QPT_RC,
    //     sqSigAll: False
    // };
    // let qpAttrPipeOut <- mkQpAttrPipeOut;
    // let initMetaData <- mkInitMetaData(metaDataSrv, qpInitAttr, qpAttrPipeOut);

    let { workReqPipeOutVec, recvPipeOutVec } <- mkWorkReqAndRecvReqDispatcher(
        convertFifo2PipeOut(inputWorkReqOrRecvReqQ)
    );

    PermCheckArbiter#(TMul#(2, MAX_QP)) permCheckArbiter <- mkPermCheckAribter(permCheckMR);

    let headerAndMetaDataAndPayloadPipeOut <- mkExtractHeaderFromRdmaPktPipeOut(
        rdmaReqRespPipeIn
    );
    let pktMetaDataAndPayloadPipeOutVec <- mkInputRdmaPktBufAndHeaderValidation(
        headerAndMetaDataAndPayloadPipeOut, qpMetaData
    );

    let dmaReadSrv  <- mkDmaReadSrv;
    let dmaWriteSrv <- mkDmaWriteSrv;
    DmaReadSrvArbiter#(MAX_QP)   dmaReadSrvVec <- mkDmaReadAribter(dmaReadSrv);
    DmaWriteSrvArbiter#(MAX_QP) dmaWriteSrvVec <- mkDmaWriteAribter(dmaWriteSrv);

    Vector#(MAX_QP, DataStreamPipeOut)    qpDataStreamPipeOutVec = newVector;
    Vector#(MAX_QP, PipeOut#(WorkComp)) qpRecvWorkCompPipeOutVec = newVector;
    Vector#(MAX_QP, PipeOut#(WorkComp)) qpSendWorkCompPipeOutVec = newVector;

    for (Integer idx = 0; idx < valueOf(MAX_QP); idx = idx + 1) begin
        let permCheck4RQ = permCheckArbiter[2 * idx];
        let permCheck4SQ = permCheckArbiter[2 * idx + 1];

        IndexQP qpIndex = fromInteger(idx);
        let cntrl = qpMetaData.getCntrlByIndexQP(qpIndex);
        let qp <- mkQP(
            cntrl,
            recvPipeOutVec[qpIndex],
            workReqPipeOutVec[qpIndex],
            dmaReadSrvVec[qpIndex],
            dmaWriteSrvVec[qpIndex],
            permCheck4RQ,
            permCheck4SQ,
            pktMetaDataAndPayloadPipeOutVec[idx].reqPktPipeOut,
            pktMetaDataAndPayloadPipeOutVec[idx].respPktPipeOut
        );
        qpDataStreamPipeOutVec[idx] = qp.rdmaReqRespPipeOut;

        // TODO: support CNP
        let addNoErrWorkCompOutRule <- addRules(genEmptyPipeOutRule(
            pktMetaDataAndPayloadPipeOutVec[idx].cnpPipeOut,
            "pktMetaDataAndPayloadPipeOutVec[" + integerToString(idx) +
            "].cnpPipeOut empty assertion @ mkTransportLayerRDMA"
        ));
        // TODO: support CQ
        qpRecvWorkCompPipeOutVec[idx] = qp.workCompPipeOutRQ;
        qpSendWorkCompPipeOutVec[idx] = qp.workCompPipeOutSQ;
    end

    function Bool isDataStreamFinished(DataStream ds) = ds.isLast;
    // TODO: connect to UDP
    let dataStreamPipeOut <- mkPipeOutArbiter(qpDataStreamPipeOutVec, isDataStreamFinished);

    function Bool isWorkCompFinished(WorkComp wc) = True;
    let recvWorkCompPipeOut <- mkPipeOutArbiter(qpRecvWorkCompPipeOutVec, isWorkCompFinished);
    let sendWorkCompPipeOut <- mkPipeOutArbiter(qpSendWorkCompPipeOutVec, isWorkCompFinished);
    let workCompPipeOut <- mkFixedBinaryPipeOutArbiter(
        recvWorkCompPipeOut, sendWorkCompPipeOut
    );

    interface rdmaDataStreamInput   = toPut(inputDataStreamQ);
    interface rdmaDataStreamPipeOut = dataStreamPipeOut;
    interface srvWorkReqRecvReqWorkComp = toGPServer(inputWorkReqOrRecvReqQ, workCompPipeOut);
    interface srvMetaData = metaDataSrv;
endmodule
*/
typedef enum {
    META_DATA_ALLOC_PD,
    META_DATA_CREATE_QP,
    META_DATA_INIT_QP,
    META_DATA_SET_QP_RTR,
    META_DATA_SET_QP_RTS,
    META_DATA_NO_OP
} InitMetaDataState deriving(Bits, Eq, FShow);

module mkInitMetaData#(
    MetaDataSrv metaDataSrv, QpInitAttr qpInitAttr, PipeOut#(AttrQP) qpAttrPipeIn
)(Empty);
    let pdNum = valueOf(MAX_PD);
    let qpNum = valueOf(MAX_QP);
    let qpPerPD = valueOf(TDiv#(MAX_QP, MAX_PD));

    FIFOF#(HandlerPD) pdHandlerQ4Fill <- mkSizedFIFOF(pdNum);
    FIFOF#(QPN)             qpnQ4Init <- mkSizedFIFOF(qpNum);
    FIFOF#(QPN)           qpnQ4Modify <- mkSizedFIFOF(qpNum);

    Count#(Bit#(TLog#(MAX_PD)))                  pdKeyCnt <- mkCount(fromInteger(pdNum - 1));
    Count#(Bit#(TLog#(TAdd#(1, MAX_PD))))        pdReqCnt <- mkCount(fromInteger(pdNum));
    Count#(Bit#(TLog#(MAX_PD)))                 pdRespCnt <- mkCount(fromInteger(pdNum - 1));
    Count#(Bit#(TLog#(TAdd#(1, MAX_QP))))        qpReqCnt <- mkCount(fromInteger(qpNum));
    Count#(Bit#(TLog#(MAX_QP)))                 qpRespCnt <- mkCount(fromInteger(qpNum - 1));
    Count#(Bit#(TLog#(TDiv#(MAX_QP, MAX_PD)))) qpPerPdCnt <- mkCount(fromInteger(qpPerPD - 1));

    Reg#(InitMetaDataState) initMetaDataStateReg <- mkReg(META_DATA_ALLOC_PD);
    // Reg#(Bool)   pdInitDoneReg <- mkReg(False);
    // Reg#(Bool) qpCreateDoneReg <- mkReg(False);
    // Reg#(Bool)   qpInitDoneReg <- mkReg(False);
    // Reg#(Bool) qpModifyDoneReg <- mkReg(False);

    Vector#(MAX_QP, Reg#(Bool)) qpModifyDoneRegVec <- replicateM(mkReg(False));

    // rule reqAllocPDs if (!isZero(pdReqCnt) && !pdInitDoneReg);
    rule reqAllocPDs if (
        !isZero(pdReqCnt) && initMetaDataStateReg == META_DATA_ALLOC_PD
    );
        pdReqCnt.decr(1);

        KeyPD pdKey = zeroExtend(pdKeyCnt);
        pdKeyCnt.incr(1);

        let allocReqPD = ReqPD {
            allocOrNot: True,
            pdKey     : pdKey,
            pdHandler : dontCareValue
        };
        metaDataSrv.request.put(tagged Req4PD allocReqPD);
    endrule

    // rule respAllocPDs if (!pdInitDoneReg);
    rule respAllocPDs if (initMetaDataStateReg == META_DATA_ALLOC_PD);
        if (isZero(pdRespCnt)) begin
            // pdInitDoneReg <= True;
            initMetaDataStateReg <= META_DATA_CREATE_QP;
        end
        else begin
            pdRespCnt.decr(1);
        end

        let maybeAllocRespPD <- metaDataSrv.response.get;
        if (maybeAllocRespPD matches tagged Resp4PD .allocRespPD) begin
            immAssert(
                allocRespPD.successOrNot,
                "allocRespPD.successOrNot assertion @ mkInitMetaData",
                $format(
                    "allocRespPD.successOrNot=", fshow(allocRespPD.successOrNot),
                    " should be true when pdRespCnt=%0d", pdRespCnt
                )
            );
            pdHandlerQ4Fill.enq(allocRespPD.pdHandler);
        end
        else begin
            immFail(
                "maybeAllocRespPD assertion @ mkInitMetaData",
                $format(
                    "maybeAllocRespPD=", fshow(maybeAllocRespPD),
                    " should be Resp4PD"
                )
            );
        end
    endrule

    // rule reqCreateQPs if (!isZero(qpReqCnt) && pdInitDoneReg && !qpCreateDoneReg);
    rule reqCreateQPs if (
        !isZero(qpReqCnt) && initMetaDataStateReg == META_DATA_CREATE_QP
    );
        qpReqCnt.decr(1);

        if (isZero(qpPerPdCnt)) begin
            qpPerPdCnt <= fromInteger(qpPerPD - 1);
            pdHandlerQ4Fill.deq;
        end
        else begin
            qpPerPdCnt.decr(1);
        end

        let pdHandler = pdHandlerQ4Fill.first;

        let createReqQP = ReqQP {
            qpReqType   : REQ_QP_CREATE,
            pdHandler   : pdHandler,
            qpn         : dontCareValue,
            qpAttrMask  : dontCareValue,
            qpAttr      : dontCareValue,
            qpInitAttr  : qpInitAttr
        };
        metaDataSrv.request.put(tagged Req4QP createReqQP);
    endrule

    // rule respCreateQPs if (pdInitDoneReg && !qpCreateDoneReg);
    rule respCreateQPs if (initMetaDataStateReg == META_DATA_CREATE_QP);
        if (isZero(qpRespCnt)) begin
            qpReqCnt  <= fromInteger(qpNum);
            qpRespCnt <= fromInteger(qpNum - 1);
            // qpCreateDoneReg <= True;
            initMetaDataStateReg <= META_DATA_INIT_QP;
        end
        else begin
            qpRespCnt.decr(1);
        end

        let maybeCreateRespQP <- metaDataSrv.response.get;
        if (maybeCreateRespQP matches tagged Resp4QP .createRespQP) begin
            immAssert(
                createRespQP.successOrNot,
                "createRespQP.successOrNot assertion @ mkInitMetaData",
                $format(
                    "createRespQP.successOrNot=", fshow(createRespQP.successOrNot),
                    " should be true when qpRespCnt=%0d", qpRespCnt
                )
            );

            let qpn = createRespQP.qpn;
            qpnQ4Init.enq(qpn);
            // $display(
            //     "time=%0t: createRespQP=", $time, fshow(createRespQP),
            //     " should be success, and qpn=%h, qpRespCnt=%h",
            //     qpn, qpRespCnt
            // );
        end
        else begin
            immFail(
                "maybeCreateRespQP assertion @ mkInitMetaData",
                $format(
                    "maybeCreateRespQP=", fshow(maybeCreateRespQP),
                    " should be Resp4QP"
                )
            );
        end
    endrule

    // rule reqInitQPs if (
    //     !isZero(qpReqCnt) &&
    //     pdInitDoneReg     &&
    //     qpCreateDoneReg   &&
    //     !qpInitDoneReg
    // );
    rule reqInitQPs if (
        !isZero(qpReqCnt) && initMetaDataStateReg == META_DATA_INIT_QP
    );
        qpReqCnt.decr(1);

        let qpn = qpnQ4Init.first;
        qpnQ4Init.deq;

        let qpAttr = qpAttrPipeIn.first;
        qpAttr.qpState = IBV_QPS_INIT;
        let initReqQP = ReqQP {
            qpReqType   : REQ_QP_MODIFY,
            pdHandler   : dontCareValue,
            qpn         : qpn,
            qpAttrMask  : getReset2InitRequiredAttr,
            qpAttr      : qpAttr,
            qpInitAttr  : dontCareValue
        };
        metaDataSrv.request.put(tagged Req4QP initReqQP);
    endrule

    // rule respInitQPs if (pdInitDoneReg && qpCreateDoneReg && !qpInitDoneReg);
    rule respInitQPs if (initMetaDataStateReg == META_DATA_INIT_QP);
        if (isZero(qpRespCnt)) begin
            qpReqCnt  <= fromInteger(qpNum);
            qpRespCnt <= fromInteger(qpNum - 1);
            // qpInitDoneReg <= True;
            initMetaDataStateReg <= META_DATA_SET_QP_RTR;
        end
        else begin
            qpRespCnt.decr(1);
        end

        let maybeInitRespQP <- metaDataSrv.response.get;
        if (maybeInitRespQP matches tagged Resp4QP .initRespQP) begin
            immAssert(
                initRespQP.successOrNot,
                "initRespQP.successOrNot assertion @ mkInitMetaData",
                $format(
                    "initRespQP.successOrNot=", fshow(initRespQP.successOrNot),
                    " should be true when qpRespCnt=%0d", qpRespCnt
                )
            );

            let qpn = initRespQP.qpn;
            qpnQ4Modify.enq(qpn);
            // $display(
            //     "time=%0t: initRespQP=", $time, fshow(initRespQP),
            //     " should be success, and qpn=%h, qpRespCnt=%h",
            //     $time, qpn, qpRespCnt
            // );
        end
        else begin
            immFail(
                "maybeInitRespQP assertion @ mkInitMetaData",
                $format(
                    "maybeInitRespQP=", fshow(maybeInitRespQP),
                    " should be Resp4QP"
                )
            );
        end
    endrule

    // rule reqModifyQPs if (
    //     !isZero(qpReqCnt) &&
    //     pdInitDoneReg     &&
    //     qpCreateDoneReg   &&
    //     qpInitDoneReg     &&
    //     !qpModifyDoneReg
    // );
    rule reqRtrQPs if (
        !isZero(qpReqCnt) && initMetaDataStateReg == META_DATA_SET_QP_RTR
    );
        qpReqCnt.decr(1);

        let qpn = qpnQ4Modify.first;
        qpnQ4Modify.deq;

        let qpAttr = qpAttrPipeIn.first;
        qpAttrPipeIn.deq;

        qpAttr.qpState = IBV_QPS_RTR;
        let setRtrReqQP = ReqQP {
            qpReqType   : REQ_QP_MODIFY,
            pdHandler   : dontCareValue,
            qpn         : qpn,
            qpAttrMask  : getInit2RtrRequiredAttr,
            qpAttr      : qpAttr,
            qpInitAttr  : dontCareValue
        };
        metaDataSrv.request.put(tagged Req4QP setRtrReqQP);
    endrule

    // rule respModifyQPs if (
    //     pdInitDoneReg   &&
    //     qpCreateDoneReg &&
    //     qpInitDoneReg   &&
    //     !qpModifyDoneReg
    // );
    rule respRtrQPs if (initMetaDataStateReg == META_DATA_SET_QP_RTR);
        if (isZero(qpRespCnt)) begin
            // qpModifyDoneReg <= True;
            initMetaDataStateReg <= META_DATA_SET_QP_RTS;
        end
        else begin
            qpRespCnt.decr(1);
        end

        let maybeModifyRespQP <- metaDataSrv.response.get;
        if (maybeModifyRespQP matches tagged Resp4QP .setRtrRespQP) begin
            immAssert(
                setRtrRespQP.successOrNot,
                "setRtrRespQP.successOrNot assertion @ mkInitMetaData",
                $format(
                    "setRtrRespQP.successOrNot=", fshow(setRtrRespQP.successOrNot),
                    " should be true when qpRespCnt=%0d", qpRespCnt,
                    ", setRtrRespQP=", fshow(setRtrRespQP)
                )
            );
            // $display(
            //     "time=%0t: setRtrRespQP=", $time, fshow(setRtrRespQP),
            //     " should be success, and setRtrRespQP.qpn=%h, qpRespCnt=%h",
            //     $time, setRtrRespQP.qpn, qpRespCnt
            // );
        end
        else begin
            immFail(
                "maybeModifyRespQP assertion @ mkInitMetaData",
                $format(
                    "maybeModifyRespQP=", fshow(maybeModifyRespQP),
                    " should be Resp4QP"
                )
            );
        end
    endrule

    // rule reqModifyQPs if (
    //     !isZero(qpReqCnt) &&
    //     pdInitDoneReg     &&
    //     qpCreateDoneReg   &&
    //     qpInitDoneReg     &&
    //     !qpModifyDoneReg
    // );
    rule reqRtsQPs if (
        !isZero(qpReqCnt) && initMetaDataStateReg == META_DATA_SET_QP_RTS
    );
        qpReqCnt.decr(1);

        let qpn = qpnQ4Modify.first;
        qpnQ4Modify.deq;

        let qpAttr = qpAttrPipeIn.first;
        qpAttrPipeIn.deq;

        qpAttr.qpState = IBV_QPS_RTS;
        let setRtsReqQP = ReqQP {
            qpReqType   : REQ_QP_MODIFY,
            pdHandler   : dontCareValue,
            qpn         : qpn,
            qpAttrMask  : getRtr2RtsRequiredAttr,
            qpAttr      : qpAttr,
            qpInitAttr  : dontCareValue
        };
        metaDataSrv.request.put(tagged Req4QP setRtsReqQP);
    endrule

    // rule respModifyQPs if (
    //     pdInitDoneReg   &&
    //     qpCreateDoneReg &&
    //     qpInitDoneReg   &&
    //     !qpModifyDoneReg
    // );
    rule respRtsQPs if (initMetaDataStateReg == META_DATA_SET_QP_RTS);
        if (isZero(qpRespCnt)) begin
            // qpModifyDoneReg <= True;
            initMetaDataStateReg <= META_DATA_NO_OP;
        end
        else begin
            qpRespCnt.decr(1);
        end

        let maybeModifyRespQP <- metaDataSrv.response.get;
        if (maybeModifyRespQP matches tagged Resp4QP .setRtsRespQP) begin
            immAssert(
                setRtsRespQP.successOrNot,
                "setRtsRespQP.successOrNot assertion @ mkInitMetaData",
                $format(
                    "setRtsRespQP.successOrNot=", fshow(setRtsRespQP.successOrNot),
                    " should be true when qpRespCnt=%0d", qpRespCnt,
                    ", setRtsRespQP=", fshow(setRtsRespQP)
                )
            );
            // $display(
            //     "time=%0t: setRtsRespQP=", $time, fshow(setRtsRespQP),
            //     " should be success, and setRtsRespQP.qpn=%h, qpRespCnt=%h",
            //     $time, setRtsRespQP.qpn, qpRespCnt
            // );
        end
        else begin
            immFail(
                "maybeModifyRespQP assertion @ mkInitMetaData",
                $format(
                    "maybeModifyRespQP=", fshow(maybeModifyRespQP),
                    " should be Resp4QP"
                )
            );
        end
    endrule
endmodule

// TODO: connect to DMA IP

// This function should be used in simulation only
function Tuple3#(TotalFragNum, ByteEn, ByteEnBitNum) calcTotalFragNumByLength(Length dmaLen);
    Bit#(DATA_BUS_BYTE_NUM_WIDTH) lastFragByteNumResidue = truncate(dmaLen);
    Bit#(TSub#(RDMA_MAX_LEN_WIDTH, DATA_BUS_BYTE_NUM_WIDTH)) truncatedLen = truncateLSB(dmaLen);
    let lastFragEmpty = isZero(lastFragByteNumResidue);
    TotalFragNum fragNum = zeroExtend(truncatedLen + zeroExtend(pack(!lastFragEmpty)));

    // let shiftAmt = valueOf(TLog#(DATA_BUS_BYTE_WIDTH));
    // TotalFragNum fragNum = truncate(dmaLen >> shiftAmt);
    // BusByteWidthMask busByteWidthMask = maxBound;
    // let lastFragSize = truncate(dmaLen) & busByteWidthMask;
    // Bool lastFragEmpty = isZero(lastFragSize);
    // if (!lastFragEmpty) begin
    //     fragNum = fragNum + 1;
    // end

    ByteEnBitNum lastFragValidByteNum = lastFragEmpty ?
        fromInteger(valueOf(DATA_BUS_BYTE_WIDTH)) :
        zeroExtend(lastFragByteNumResidue);
    ByteEn lastFragByteEn = genByteEn(lastFragValidByteNum);
    return tuple3(fragNum, lastFragByteEn, lastFragValidByteNum);
endfunction

module mkDmaReadSrv(DmaReadSrv);
    FIFOF#(DmaReadReq) dmaReadReqQ <- mkFIFOF;
    FIFOF#(DmaReadResp) dmaReadRespQ <- mkFIFOF;

    Reg#(TotalFragNum) totalFragCntReg <- mkRegU;
    Reg#(Bool) busyReg <- mkReg(False);
    Reg#(Bool) isFirstReg <- mkRegU;
    Reg#(ByteEn) lastFragByteEnReg <- mkRegU;
    Reg#(BusBitNum) lastFragInvalidBitNumReg <- mkRegU;
    Reg#(DmaReadReq) curReqReg <- mkRegU;

    Bool isFragCntZero = isZero(totalFragCntReg);

    rule acceptReq if (!busyReg);
        let curReq = dmaReadReqQ.first;
        dmaReadReqQ.deq;

        let isZeroLen = isZero(curReq.len);
        immAssert(
            !isZeroLen,
            "dmaReadReq.len non-zero assrtion",
            $format("curReq.len=%h should not be zero", curReq.len)
        );

        let { totalFragCnt, lastFragByteEn, lastFragValidByteNum } =
            calcTotalFragNumByLength(curReq.len);
        let { lastFragValidBitNum, lastFragInvalidByteNum, lastFragInvalidBitNum } =
            calcFragBitNumAndByteNum(lastFragValidByteNum);

        totalFragCntReg <= isZeroLen ? 0 : totalFragCnt - 1;
        lastFragByteEnReg <= lastFragByteEn;
        lastFragInvalidBitNumReg <= lastFragInvalidBitNum;

        immAssert(
            !isZero(lastFragByteEn),
            "lastFragByteEn non-zero assertion",
            $format(
                "lastFragByteEn=%h should not have zero ByteEn, curReq.len=%h",
                lastFragByteEn, curReq.len
            )
        );

        curReqReg <= curReq;
        busyReg <= True;
        isFirstReg <= True;

        // $display(
        //     "time=%0t: curReq.len=%0d, totalFragCnt=%0d",
        //     $time, curReq.len, totalFragCnt
        // );
    endrule

    rule genResp if (busyReg);
        totalFragCntReg <= totalFragCntReg - 1;
        DataStream dataStream = dontCareValue;
        dataStream.isFirst = isFirstReg;
        isFirstReg <= False;
        dataStream.isLast = isFragCntZero;
        dataStream.byteEn = maxBound;

        if (isFragCntZero) begin
            busyReg <= False;
            dataStream.byteEn = lastFragByteEnReg;
            DATA tmpData = dataStream.data >> lastFragInvalidBitNumReg;
            dataStream.data = truncate(tmpData << lastFragInvalidBitNumReg);
        end

        let resp = DmaReadResp {
            initiator : curReqReg.initiator,
            sqpn      : curReqReg.sqpn,
            wrID      : curReqReg.wrID,
            isRespErr : False,
            dataStream: dataStream
        };
        dmaReadRespQ.enq(resp);

        immAssert(
            !isZero(dataStream.byteEn),
            "dmaReadResp.data.byteEn non-zero assertion",
            $format("dmaReadResp.data should not have zero ByteEn, ", fshow(dataStream))
        );
        // $display(
        //     "time=%0t: mkSimDmaReadSrvAndReqRespPipeOut response, totalFragNum=%h, dataStream=",
        //     $time, totalFragCntReg, fshow(dataStream)
        // );
    endrule

    return toGPServer(dmaReadReqQ, dmaReadRespQ);
endmodule

module mkDmaWriteSrv(DmaWriteSrv);
    FIFOF#(DmaWriteReq) dmaWriteReqQ <- mkFIFOF;
    FIFOF#(DmaWriteResp) dmaWriteRespQ <- mkFIFOF;

    function Action genDmaWriteResp(DmaWriteMetaData metaData);
        action
            let dmaWriteResp = DmaWriteResp {
                initiator: metaData.initiator,
                sqpn     : metaData.sqpn,
                psn      : metaData.psn,
                isRespErr: False
            };
            // $display("time=%0t: dmaWriteResp=", $time, fshow(dmaWriteResp));

            dmaWriteRespQ.enq(dmaWriteResp);
        endaction
    endfunction

    rule write;
        let dmaWriteReq = dmaWriteReqQ.first;
        dmaWriteReqQ.deq;

        // $display("time=%0t: dmaWriteReq=", $time, fshow(dmaWriteReq));

        if (dmaWriteReq.dataStream.isLast) begin
            genDmaWriteResp(dmaWriteReq.metaData);
        end
    endrule

    return toGPServer(dmaWriteReqQ, dmaWriteRespQ);
endmodule
