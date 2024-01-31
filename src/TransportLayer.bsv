import Connectable :: *;
import FIFOF :: *;
import GetPut :: *;
import PAClib :: *;
import Vector :: *;

import Arbitration :: *;
import Controller :: *;
import DataTypes :: *;
import ExtractAndPrependPipeOut :: *;
import Headers :: *;
import InputPktHandle :: *;
import MetaData :: *;
import PrimUtils :: *;
import QueuePair :: *;
import Settings :: *;
import Utils :: *;

// TODO: check QP state when dispatching WR and RR,
// and discard WR and RR when QP in abnormal state
module mkWorkReqAndRecvReqDispatcher#(
    PipeOut#(WorkReq) workReqPipeIn, PipeOut#(RecvReq) recvReqPipeIn
)(Tuple2#(Vector#(MAX_QP, PipeOut#(WorkReq)), Vector#(MAX_QP, PipeOut#(RecvReq))));
    Vector#(MAX_QP, FIFOF#(WorkReq)) workReqOutVec <- replicateM(mkFIFOF);
    Vector#(MAX_QP, FIFOF#(RecvReq)) recvReqOutVec <- replicateM(mkFIFOF);

    rule dispatchWorkReq;
        let wr = workReqPipeIn.first;
        workReqPipeIn.deq;

        let qpIndex = getIndexQP(wr.sqpn);
        workReqOutVec[qpIndex].enq(wr);
        // $display(
        //     "time=%0t:", $time,
        //     " dispatchWorkReq, qpIndex=%0d, sqpn=%h, wr.id=%h",
        //     qpIndex, wr.sqpn, wr.id
        // );
    endrule

    rule dispatchRecvReq;
        let rr = recvReqPipeIn.first;
        recvReqPipeIn.deq;

        let qpIndex = getIndexQP(rr.sqpn);
        recvReqOutVec[qpIndex].enq(rr);
        // $display(
        //     "time=%0t:", $time,
        //     " dispatchWorkReq, qpIndex=%0d, sqpn=%h, rr.id=%h",
        //     qpIndex, rr.sqpn, rr.id
        // );
    endrule

    return tuple2(
        map(toPipeOut, workReqOutVec),
        map(toPipeOut, recvReqOutVec)
    );
endmodule

interface TransportLayer;
    interface Put#(RecvReq) recvReqInput;
    interface Put#(WorkReq) workReqInput;
    interface Put#(DataStream) rdmaDataStreamInput;
    interface DataStreamPipeOut rdmaDataStreamPipeOut;
    interface PipeOut#(WorkComp) workCompPipeOutRQ;
    interface PipeOut#(WorkComp) workCompPipeOutSQ;
    interface MetaDataSrv srvPortMetaData;
    interface DmaReadClt  dmaReadClt;
    interface DmaWriteClt dmaWriteClt;

    // method Maybe#(HandlerPD) getPD(QPN qpn);
    // interface Vector#(MAX_QP, rdmaReqRespPipeOut) rdmaReqRespPipeOut;
    // interface Vector#(MAX_QP, RdmaPktMetaDataAndPayloadPipeIn) respPktPipeInVec;
endinterface

(* synthesize *)
module mkTransportLayer(TransportLayer) provisos(
    NumAlias#(TDiv#(MAX_QP, MAX_PD), qpPerPdNum),
    Add#(TMul#(qpPerPdNum, MAX_PD), 0, MAX_QP), // MAX_QP can be divided by MAX_PD
    NumAlias#(TDiv#(MAX_MR, MAX_PD), mrPerPdNum),
    Add#(TMul#(mrPerPdNum, MAX_PD), 0, MAX_MR) // MAX_MR can be divided by MAX_PD
);
    FIFOF#(DataStream) inputDataStreamQ <- mkFIFOF;
    let rdmaReqRespPipeIn = toPipeOut(inputDataStreamQ);

    FIFOF#(WorkReq) inputWorkReqQ <- mkFIFOF;
    FIFOF#(RecvReq) inputRecvReqQ <- mkFIFOF;

    let pdMetaData   <- mkMetaDataPDs;
    let permCheckSrv <- mkPermCheckSrv(pdMetaData);
    let qpMetaData   <- mkMetaDataQPs;
    let metaDataSrv  <- mkMetaDataSrv(pdMetaData, qpMetaData);

    let { workReqPipeOutVec, recvReqPipeOutVec } <- mkWorkReqAndRecvReqDispatcher(
        toPipeOut(inputWorkReqQ), toPipeOut(inputRecvReqQ)
    );

    // let pktMetaDataAndPayloadPipeOutVec <- mkSimExtractNormalReqResp(
    //     qpMetaData, rdmaReqRespPipeIn
    // );
    let headerAndMetaDataAndPayloadPipeOut <- mkExtractHeaderFromRdmaPktPipeOut(
        rdmaReqRespPipeIn
    );
    let pktMetaDataAndPayloadPipeOutVec <- mkInputRdmaPktBufAndHeaderValidation(
        headerAndMetaDataAndPayloadPipeOut, qpMetaData
    );

    // Vector#(MAX_QP, DataStreamPipeOut)    qpDataStreamPipeOutVec = newVector;
    Vector#(MAX_QP, PipeOut#(WorkComp)) qpRecvWorkCompPipeOutVec = newVector;
    Vector#(MAX_QP, PipeOut#(WorkComp)) qpSendWorkCompPipeOutVec = newVector;

    Vector#(TMul#(2, MAX_QP), DataStreamPipeOut) qpDataStreamPipeOutVec = newVector;
    Vector#(TMul#(2, MAX_QP), PermCheckClt) permCheckCltVec = newVector;
    Vector#(TMul#(2, MAX_QP), DmaReadClt)     dmaReadCltVec = newVector;
    Vector#(TMul#(2, MAX_QP), DmaWriteClt)   dmaWriteCltVec = newVector;

    for (Integer idx = 0; idx < valueOf(MAX_QP); idx = idx + 1) begin
        IndexQP qpIndex = fromInteger(idx);
        let qp = qpMetaData.getQueuePairByIndexQP(qpIndex);

        mkConnection(toGet(recvReqPipeOutVec[idx]), qp.recvReqIn);
        mkConnection(toGet(workReqPipeOutVec[idx]), qp.workReqIn);
        mkConnection(
            pktMetaDataAndPayloadPipeOutVec[idx].reqPktPipeOut,
            qp.reqPktPipeIn
        );
        mkConnection(
            pktMetaDataAndPayloadPipeOutVec[idx].respPktPipeOut,
            qp.respPktPipeIn
        );

        // qpDataStreamPipeOutVec[idx]   = qp.rdmaReqRespPipeOut;
        qpRecvWorkCompPipeOutVec[idx] = qp.workCompPipeOutRQ;
        qpSendWorkCompPipeOutVec[idx] = qp.workCompPipeOutSQ;

        let leftIdx = 2 * idx;
        let rightIdx = 2 * idx + 1;
        qpDataStreamPipeOutVec[leftIdx]  = qp.rdmaRespPipeOut;
        qpDataStreamPipeOutVec[rightIdx] = qp.rdmaReqPipeOut;
        permCheckCltVec[leftIdx]         = qp.permCheckClt4RQ;
        permCheckCltVec[rightIdx]        = qp.permCheckClt4SQ;
        dmaReadCltVec[leftIdx]           = qp.dmaReadClt4RQ;
        dmaReadCltVec[rightIdx]          = qp.dmaReadClt4SQ;
        dmaWriteCltVec[leftIdx]          = qp.dmaWriteClt4RQ;
        dmaWriteCltVec[rightIdx]         = qp.dmaWriteClt4SQ;

        // TODO: support CNP
        let addNoErrWorkCompOutRule <- addRules(genEmptyPipeOutRule(
            pktMetaDataAndPayloadPipeOutVec[idx].cnpPipeOut,
            "pktMetaDataAndPayloadPipeOutVec[" + integerToString(idx) +
            "].cnpPipeOut empty assertion @ mkTransportLayerRDMA"
        ));
    end

    let arbitratedPermCheckClt <- mkPermCheckCltArbiter(permCheckCltVec);
    let arbitratedDmaReadClt   <- mkDmaReadCltArbiter(dmaReadCltVec);
    let arbitratedDmaWriteClt  <- mkDmaWriteCltArbiter(dmaWriteCltVec);

    mkConnection(arbitratedPermCheckClt, permCheckSrv);

    function Bool isDataStreamFinished(DataStream ds) = ds.isLast;
    // TODO: connect to UDP
    let dataStreamPipeOut <- mkPipeOutArbiter(qpDataStreamPipeOutVec, isDataStreamFinished);

    function Bool isWorkCompFinished(WorkComp wc) = True;
    let recvWorkCompPipeOut <- mkPipeOutArbiter(qpRecvWorkCompPipeOutVec, isWorkCompFinished);
    let sendWorkCompPipeOut <- mkPipeOutArbiter(qpSendWorkCompPipeOutVec, isWorkCompFinished);
    // let workCompPipeOut <- mkFixedBinaryPipeOutArbiter(
    //     recvWorkCompPipeOut, sendWorkCompPipeOut
    // );

    interface rdmaDataStreamInput = toPut(inputDataStreamQ);
    interface workReqInput        = toPut(inputWorkReqQ);
    interface recvReqInput        = toPut(inputRecvReqQ);
    // interface srvWorkReqRecvReqWorkComp = toGPServer(inputWorkReqOrRecvReqQ, workCompPipeOut);
    interface rdmaDataStreamPipeOut = dataStreamPipeOut;
    interface workCompPipeOutRQ = recvWorkCompPipeOut;
    interface workCompPipeOutSQ = sendWorkCompPipeOut;

    interface srvPortMetaData = metaDataSrv;
    interface dmaReadClt  = arbitratedDmaReadClt;
    interface dmaWriteClt = arbitratedDmaWriteClt;

    // method Maybe#(HandlerPD) getPD(QPN qpn) = qpMetaData.getPD(qpn);
    // method Maybe#(MetaDataMRs) getMRs4PD(HandlerPD pdHandler) = pdMetaData.getMRs4PD(pdHandler);
endmodule
