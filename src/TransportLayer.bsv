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

// TODO: remove it
module mkSimExtractNormalReqResp#(
    MetaDataQPs qpMetaData,
    DataStreamPipeOut rdmaPktPipeIn
)(Vector#(MAX_QP, InputRdmaPktBuf));
    // Output FIFO for PipeOut
    Vector#(MAX_QP, FIFOF#(BTH))                         cnpOutVec <- replicateM(mkFIFOF);
    Vector#(MAX_QP, FIFOF#(DataStream))           reqPayloadOutVec <- replicateM(mkFIFOF);
    Vector#(MAX_QP, FIFOF#(RdmaPktMetaData))  reqPktMetaDataOutVec <- replicateM(mkFIFOF);
    Vector#(MAX_QP, FIFOF#(DataStream))          respPayloadOutVec <- replicateM(mkFIFOF);
    Vector#(MAX_QP, FIFOF#(RdmaPktMetaData)) respPktMetaDataOutVec <- replicateM(mkFIFOF);

    Reg#(RdmaHeader)  rdmaHeaderReg <- mkRegU;
    Reg#(PmtuFragNum) pktFragNumReg <- mkRegU;
    Reg#(PktLen)          pktLenReg <- mkRegU;
    Reg#(Bool)          pktValidReg <- mkRegU;

    let headerAndMetaDataAndPayloadPipeOut <- mkExtractHeaderFromRdmaPktPipeOut(
        rdmaPktPipeIn
    );
    let payloadPipeIn <- mkBuffer(headerAndMetaDataAndPayloadPipeOut.payload);
    let rdmaHeaderPipeOut <- mkDataStream2Header(
        headerAndMetaDataAndPayloadPipeOut.headerAndMetaData.headerDataStream,
        headerAndMetaDataAndPayloadPipeOut.headerAndMetaData.headerMetaData
    );

    rule extractHeader;
        let payloadFrag = payloadPipeIn.first;
        payloadPipeIn.deq;

        let rdmaHeader = rdmaHeaderReg;
        if (payloadFrag.isFirst) begin
            rdmaHeader = rdmaHeaderPipeOut.first;
            rdmaHeaderPipeOut.deq;
            rdmaHeaderReg <= rdmaHeader;
        end
        let bth    = extractBTH(rdmaHeader.headerData);
        let aeth   = extractAETH(rdmaHeader.headerData);
        let deth   = extractDETH(rdmaHeader.headerData);
        let xrceth = extractXRCETH(rdmaHeader.headerData);

        let isCNP          = isCongestionNotificationPkt(bth);
        let isRespPkt      = isRdmaRespOpCode(bth.opcode);
        let isRespPktOrCNP = isRespPkt || isCNP;

        let dqpn      = (bth.trans == TRANS_TYPE_XRC && !isRespPktOrCNP) ? xrceth.srqn : bth.dqpn;
        let bthPadCnt = bth.padCnt;
        let qpIndex   = getIndexQP(dqpn);

        let maybeHandlerPD = qpMetaData.getPD(dqpn);
        let qp = qpMetaData.getQueuePairByQPN(dqpn);
        let isResp = isRespPkt || isCNP;
        let cntrlStatus = isResp ? qp.statusSQ : qp.statusRQ;
        let isValidStateQP = cntrlStatus.comm.isNonErr || cntrlStatus.comm.isERR;
        $display(
            "time=%0t: extractHeader", $time,
            ", maybeHandlerPD=", fshow(maybeHandlerPD),
            ", isValidStateQP=", fshow(isValidStateQP),
            " should be valid, when dqpn=%h, bth.psn=%h, bth.opcode=",
            dqpn, bth.psn, fshow(bth.opcode)
        );
        immAssert(
            isValidStateQP,
            "isValidStateQP assertion @ mkSimExtractNormalReqResp",
            $format(
                "isValidStateQP=", fshow(isValidStateQP),
                " should be valid, when bth.trans=", fshow(bth.trans),
                " and dqpn=%h", dqpn
            )
        );
        // immAssert(
        //     isValid(maybeHandlerPD),
        //     "PD valid assertion @ mkSimExtractNormalReqResp",
        //     $format(
        //         "isValid(maybeHandlerPD)=", fshow(isValid(maybeHandlerPD)),
        //         " should be valid, when bth.trans=", fshow(bth.trans),
        //         " and dqpn=%h", dqpn
        //     )
        // );

        let isFirstOrMidPkt = isFirstOrMiddleRdmaOpCode(bth.opcode);
        let isLastPkt       = isLastRdmaOpCode(bth.opcode);

        let pktLen = pktLenReg;
        let pktFragNum = pktFragNumReg;
        let pktValid = False;

        let isByteEnAllOne = isAllOnesR(payloadFrag.byteEn);
        let payloadFragLen = calcFragByteNumFromByteEn(payloadFrag.byteEn);
        immAssert(
            isValid(payloadFragLen),
            "isValid(payloadFragLen) assertion @ mkSimExtractNormalReqResp",
            $format(
                "payloadFragLen=", fshow(payloadFragLen), " should be valid"
            )
        );

        let fragLen = unwrapMaybe(payloadFragLen);
        let isByteEnNonZero = !isZero(fragLen);
        ByteEnBitNum fragLenWithOutPad = fragLen - zeroExtend(bthPadCnt);
        PktLen fragLenExtWithOutPad = zeroExtend(fragLenWithOutPad);
        case ({ pack(payloadFrag.isFirst), pack(payloadFrag.isLast) })
            2'b11: begin // payloadFrag.isFirst && payloadFrag.isLast
                pktLen = fragLenExtWithOutPad;
                pktFragNum = 1;
                pktValid = (isFirstOrMidPkt ? False : (isLastPkt ? isByteEnNonZero : True));
            end
            2'b10: begin // payloadFrag.isFirst && !payloadFrag.isLast
                pktLen = fromInteger(valueOf(DATA_BUS_BYTE_WIDTH));
                pktFragNum = 1;
                pktValid = isByteEnAllOne;
            end
            2'b01: begin // !payloadFrag.isFirst && payloadFrag.islast
                pktLen = pktLenAddFragLen(pktLenReg, fragLenWithOutPad);
                // pktLen = pktLenReg + fragLenExtWithOutPad;
                pktFragNum = pktFragNumReg + 1;
                pktValid = pktValidReg;
            end
            2'b00: begin // !payloadFrag.isFirst && !payloadFrag.islast
                pktLen = pktLenAddBusByteWidth(pktLenReg);
                // pktLen = pktLenReg + fromInteger(valueOf(DATA_BUS_BYTE_WIDTH));
                pktFragNum = pktFragNumReg + 1;
                pktValid = pktValidReg && isByteEnAllOne;
            end
        endcase

        pktLenReg     <= pktLen;
        pktValidReg   <= pktValid;
        pktFragNumReg <= pktFragNum;

        let pktStatus = PKT_ST_VALID;
        if (!pktValid) begin
            // Invalid packet length
            pktStatus = PKT_ST_LEN_ERR;
        end
        immAssert(
            pktValid,
            "pktValid assertion @ mkSimExtractNormalReqResp",
            $format(
                "pktValid=", fshow(pktValid),
                " should be valid, when payloadFrag.isFirst=", fshow(payloadFrag.isFirst),
                ", payloadFrag.isLast=", fshow(payloadFrag.isLast),
                ", isFirstOrMidPkt=", fshow(isFirstOrMidPkt),
                ", isLastPkt=", fshow(isLastPkt),
                ", isByteEnNonZero=", fshow(isByteEnNonZero),
                ", isByteEnAllOne=", fshow(isByteEnAllOne),
                ", pktValidReg=", fshow(pktValidReg),
                ", bth.opcode=", fshow(bth.opcode),
                ", bth.psn=%h", bth.psn
            )
        );

        let isZeroPayloadLen = isZeroR(pktLen);
        let pktMetaData = RdmaPktMetaData {
            pktPayloadLen   : pktLen,
            pktFragNum      : (isZeroPayloadLen ? 0 : pktFragNum),
            isZeroPayloadLen: isZeroPayloadLen,
            pktHeader       : rdmaHeader,
            pdHandler       : unwrapMaybe(maybeHandlerPD),
            pktValid        : pktValid,
            pktStatus       : pktStatus
        };
        if (isValid(maybeHandlerPD)) begin
            let bthCheckResult = checkZeroFields4BTH(bth);
            let headerCheckResult =
                padCntCheckReqHeader(bth) || padCntCheckRespHeader(bth, aeth);
            immAssert(
                bthCheckResult && headerCheckResult,
                "bth valid assertion @ mkSimExtractNormalReqResp",
                $format(
                    "bth=", fshow(bth),
                    " should be valid, but bthCheckResult=", fshow(bthCheckResult),
                    " and headerCheckResult=", fshow(headerCheckResult)
                )
            );

            if (isCNP) begin
                cnpOutVec[qpIndex].enq(bth);
            end
            else if (isRespPkt) begin
                // Do not use rdmaHeader.headerMetaData.hasPayload here,
                // since it is only depend on RdamOpCode
                if (!isZeroPayloadLen) begin
                    respPayloadOutVec[qpIndex].enq(payloadFrag);
                end
                if (payloadFrag.isLast) begin
                    respPktMetaDataOutVec[qpIndex].enq(pktMetaData);
                end
            end
            else begin
                // Do not use rdmaHeader.headerMetaData.hasPayload here,
                // since it is only depend on RdamOpCode
                if (!isZeroPayloadLen) begin
                    reqPayloadOutVec[qpIndex].enq(payloadFrag);
                end
                if (payloadFrag.isLast) begin
                    reqPktMetaDataOutVec[qpIndex].enq(pktMetaData);
                end
            end
        end

        if (isZeroPayloadLen) begin
            immAssert(
                !rdmaHeader.headerMetaData.hasPayload,
                "hasPayload assertion @ mkSimExtractNormalReqResp",
                $format(
                    "hasPayload=", fshow(rdmaHeader.headerMetaData.hasPayload),
                    " should be false when isZeroPayloadLen=", fshow(isZeroPayloadLen)
                )
            );
        end

        if (bth.opcode == ACKNOWLEDGE) begin
            immAssert(
                isZeroPayloadLen && payloadFrag.isLast && payloadFrag.isFirst,
                "isZeroPayloadLen assertion @ mkSimExtractNormalReqResp",
                $format(
                    "isZeroPayloadLen=", fshow(isZeroPayloadLen),
                    ", payloadFrag.isFirst=", fshow(payloadFrag.isFirst),
                    ", payloadFrag.isLast=", fshow(payloadFrag.isLast),
                    " should all be true when bth.opcode=", fshow(bth.opcode)
                )
            );
        end
        $display(
            "time=%0t: mkSimExtractNormalReqResp recvPktFrag", $time,
            ", bth.opcode=", fshow(bth.opcode),
            ", bth.psn=%h, dqpn=%h, pktFragNum=%0d, pktLen=%0d",
            bth.psn, dqpn, pktFragNum, pktLen
            // ", bthPadCnt=%0d", bthPadCnt,
            // ", fragLen=%0d", fragLen,
            // ", payloadFrag.isFirst=", fshow(payloadFrag.isFirst),
            // ", payloadFrag.isLast=", fshow(payloadFrag.isLast),
            // ", fragLenWithOutPad=%0d", fragLenWithOutPad,
            // ", rdmaHeader=", fshow(rdmaHeader)
        );
    endrule

    function InputRdmaPktBuf genInputRdmaPktBuf(Integer idx);
        return interface InputRdmaPktBuf;
            interface reqPktPipeOut = interface RdmaPktMetaDataAndPayloadPipeOut;
                interface pktMetaData = toPipeOut(reqPktMetaDataOutVec[idx]);
                interface payload     = toPipeOut(reqPayloadOutVec[idx]);
            endinterface;

            interface respPktPipeOut = interface RdmaPktMetaDataAndPayloadPipeOut;
                interface pktMetaData = toPipeOut(respPktMetaDataOutVec[idx]);
                interface payload     = toPipeOut(respPayloadOutVec[idx]);
            endinterface;

            interface cnpPipeOut  = toPipeOut(cnpOutVec[idx]);
        endinterface;
    endfunction

    return map(genInputRdmaPktBuf, genVector);
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
