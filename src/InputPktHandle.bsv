import FIFOF :: *;
import PAClib :: *;
import Vector :: *;

import Controller :: *;
import DataTypes :: *;
import ExtractAndPrependPipeOut :: *;
import Headers :: *;
import MetaData :: *;
import PrimUtils :: *;
import QueuePair :: *;
import Settings :: *;
import Utils :: *;

function Bool checkZeroFields4BTH(BTH bth);
    let bthRsvdCheck =
        isZero(pack(bth.tver))  &&
        isZero(pack(bth.fecn))  &&
        isZero(pack(bth.becn))  &&
        isZero(pack(bth.resv6)) &&
        isZero(pack(bth.resv7));
    return bthRsvdCheck;
endfunction

function Bool padCntCheckReqHeader(BTH bth);
    let zeroPadCntCheck = isZero(bth.padCnt);

    return case (bth.opcode)
        SEND_FIRST, SEND_MIDDLE            : zeroPadCntCheck;
        SEND_LAST, SEND_ONLY               ,
        SEND_LAST_WITH_IMMEDIATE           ,
        SEND_ONLY_WITH_IMMEDIATE           ,
        SEND_LAST_WITH_INVALIDATE          ,
        SEND_ONLY_WITH_INVALIDATE          : True;

        RDMA_WRITE_FIRST, RDMA_WRITE_MIDDLE: zeroPadCntCheck;
        RDMA_WRITE_LAST, RDMA_WRITE_ONLY   ,
        RDMA_WRITE_LAST_WITH_IMMEDIATE     ,
        RDMA_WRITE_ONLY_WITH_IMMEDIATE     : True;

        RDMA_READ_REQUEST                  ,
        COMPARE_SWAP                       ,
        FETCH_ADD                          : zeroPadCntCheck;

        default                            : False;
    endcase;
endfunction

// TODO: verify that read/atomic response can only have normal AETH code
function Bool padCntCheckRespHeader(BTH bth, AETH aeth);
    let zeroPadCntCheck = isZero(bth.padCnt);

    case (bth.opcode)
        RDMA_READ_RESPONSE_MIDDLE: return zeroPadCntCheck;
        RDMA_READ_RESPONSE_LAST  ,
        RDMA_READ_RESPONSE_ONLY  : return aeth.code == AETH_CODE_ACK;
        RDMA_READ_RESPONSE_FIRST ,
        ATOMIC_ACKNOWLEDGE       : return aeth.code == AETH_CODE_ACK && zeroPadCntCheck;
        ACKNOWLEDGE              : case (aeth.code)
            AETH_CODE_ACK,
            AETH_CODE_RNR: return zeroPadCntCheck;
            AETH_CODE_NAK: return case (aeth.value)
                zeroExtend(pack(AETH_NAK_SEQ_ERR)),
                zeroExtend(pack(AETH_NAK_INV_REQ)),
                zeroExtend(pack(AETH_NAK_RMT_ACC)),
                zeroExtend(pack(AETH_NAK_RMT_OP)) ,
                zeroExtend(pack(AETH_NAK_INV_RD)) : zeroPadCntCheck;
                default                           : False;
            endcase;
            // AETH_CODE_RSVD
            default: return False;
        endcase
        default: return False;
    endcase
endfunction

// TODO: check XRC domain match
function Bool validateHeader(TransType transType, QKEY qkey, CntrlStatus cntrlStatus, Bool isRespPkt);
    let transTypeMatch = transTypeMatchQpType(transType, cntrlStatus.getTypeQP, isRespPkt);
    let qpStateMatch = cntrlStatus.comm.isERR ||
        (isRespPkt ? cntrlStatus.comm.isRTS : cntrlStatus.comm.isNonErr);
    // UD has no responses
    let qKeyMatch = transType == TRANS_TYPE_UD ? qkey == cntrlStatus.comm.getQKEY : True;
    // TODO: verify RoCEv2 only use default PKEY
    // let pKeyMatch = isDefaultPKEY(cntrlStatus.comm.getPKEY);
    return transTypeMatch && qpStateMatch && qKeyMatch;
endfunction

interface HeaderAndMetaDataAndPayloadSeperateDataStreamPipeOut;
    interface HeaderDataStreamAndMetaDataPipeOut headerAndMetaData;
    interface DataStreamPipeOut payload;
endinterface

// After extract header from rdmaPktPipeIn,
// it outputs header DataStream and payload DataStream,
// and every header DataStream has corresponding payload DataStream,
// if header has no payload, then output empty payload DataStream.
// This module will not discard invalid packet.
module mkExtractHeaderFromRdmaPktPipeOut#(
    DataStreamPipeOut rdmaPktPipeIn
)(HeaderAndMetaDataAndPayloadSeperateDataStreamPipeOut);
    FIFOF#(HeaderMetaData) headerMetaDataInQ <- mkFIFOF;
    FIFOF#(DataStream) dataInQ <- mkFIFOF;

    Vector#(2, PipeOut#(HeaderMetaData)) headerMetaDataPipeOutVec <-
        mkForkVector(toPipeOut(headerMetaDataInQ));
    let headerMetaDataPipeIn = headerMetaDataPipeOutVec[0];
    let headerMetaDataPipeOut <- mkBuffer(headerMetaDataPipeOutVec[1]);
    let dataPipeIn = toPipeOut(dataInQ);
    let headerAndPayloadPipeOut <- mkExtractHeaderFromDataStreamPipeOut(
        dataPipeIn, headerMetaDataPipeIn
    );
/*
    rule debug if (!(
        rdmaPktPipeIn.notEmpty    &&
        headerMetaDataInQ.notFull &&
        dataInQ.notFull
    ));
        $display(
            "time=%0t: mkExtractHeaderFromRdmaPktPipeOut debug", $time,
            ", rdmaPktPipeIn.notFull=", fshow(rdmaPktPipeIn.notEmpty),
            ", headerMetaDataInQ.notFull=", fshow(headerMetaDataInQ.notFull),
            ", dataInQ.notFull=", fshow(dataInQ.notFull)
        );
    endrule
*/
    rule extractHeader;
        let rdmaPktDataStream = rdmaPktPipeIn.first;
        rdmaPktPipeIn.deq;
        dataInQ.enq(rdmaPktDataStream);

        if (rdmaPktDataStream.isFirst) begin
            let { transType, rdmaOpCode } =
                extractTranTypeAndRdmaOpCode(rdmaPktDataStream.data);

            let headerHasPayload = rdmaOpCodeHasPayload(rdmaOpCode);
            HeaderByteNum headerLen = fromInteger(
                calcHeaderLenByTransTypeAndRdmaOpCode(transType, rdmaOpCode)
            );
            immAssert(
                !isZero(headerLen),
                "!isZero(headerLen) assertion @ mkExtractHeaderFromRdmaPktPipeOut",
                $format(
                    "headerLen=%0d should not be zero, transType=",
                    headerLen, fshow(transType),
                    ", rdmaOpCode=", fshow(rdmaOpCode)
                )
            );

            let headerMetaData = genHeaderMetaData(headerLen, headerHasPayload);
            headerMetaDataInQ.enq(headerMetaData);
            // $display(
            //     "time=%0t: extractHeader", $time,
            //     ", headerLen=%0d, transType=", headerLen, fshow(transType),
            //     ", rdmaOpCode=", fshow(rdmaOpCode),
            //     ", rdmaPktDataStream=", fshow(rdmaPktDataStream),
            //     ", headerHasPayload=", fshow(headerHasPayload),
            //     ", headerMetaData=", fshow(headerMetaData)
            // );
        end
        // $display("time=%0t: rdmaPktDataStream=", $time, fshow(rdmaPktDataStream));
    endrule

    interface headerAndMetaData = interface HeaderDataStreamAndMetaDataPipeOut;
        interface headerDataStream = headerAndPayloadPipeOut.header;
        interface headerMetaData = headerMetaDataPipeOut;
    endinterface;
    interface payload = headerAndPayloadPipeOut.payload;
endmodule

interface InputRdmaPktBuf;
    interface RdmaPktMetaDataAndPayloadPipeOut reqPktPipeOut;
    interface RdmaPktMetaDataAndPayloadPipeOut respPktPipeOut;
    interface PipeOut#(BTH) cnpPipeOut;
endinterface

typedef enum {
    RDMA_PKT_BUT_ST_PRE_CHECK_FRAG,
    RDMA_PKT_BUF_ST_DISCARD_FRAG
} RdmaPktBufState deriving(Bits, Eq);

typedef struct {
    Maybe#(HandlerPD) maybePdHandler;
    QPN dqpn;
    QKEY qkeyDETH;
    Bool isCNP;
    Bool isRespPkt;
    Bool isLastPkt;
    Bool isFirstOrMidPkt;
    Bool isLastOrOnlyPkt;
} HeaderValidateInfo deriving(Bits);

typedef struct {
    HandlerPD pdHandler;
    QPN  dqpn;
    PMTU pmtu;
    Bool isValidHeader;
    Bool isCNP;
    Bool isRespPkt;
    Bool isLastPkt;
    Bool isFirstOrMidPkt;
    Bool isLastOrOnlyPkt;
} ValidHeaderInfo deriving(Bits);

typedef struct {
    TransType   trans;  // TODO: remove this field
    RdmaOpCode  opcode; // TODO: remove this field
    PAD         padCnt; // TODO: remove this field
    PSN         psn;    // TODO: remove this field
    QPN         dqpn;   // TODO: remvoe this field
    RdmaHeader  rdmaHeader;
    HandlerPD   pdHandler;
    PktFragNum  pktFragNum;
    PktLen      pktLen;
    PMTU        pmtu;
    Bool        pktValid;
    Bool        isFirstOrMidPkt;
    Bool        isLastOrOnlyPkt;
} PktLenCheckInfo deriving(Bits);

// This module will discard:
// - invalid packet that header is without payload but packet has payload;
// TODO: check write requests have non-zero RETH.dlen but without payload
// TODO: check remote XRC domain and XRCETH valid?
// TODO: reset mkInputRdmaPktBufAndHeaderValidation when error or retry?
module mkInputRdmaPktBufAndHeaderValidation#(
    // Only output payload when packet has non-zero payload,
    // otherwise output packet header/metadata only,
    // namely header and payload are not one-to-one mapping,
    // and packet header/metadata is aligned to the last fragment of payload.
    HeaderAndMetaDataAndPayloadSeperateDataStreamPipeOut pipeIn,
    MetaDataQPs qpMetaData
)(Vector#(MAX_QP, InputRdmaPktBuf));
    // Output FIFO for PipeOut
    Vector#(MAX_QP, FIFOF#(BTH))                         cnpOutVec <- replicateM(mkFIFOF);
    Vector#(MAX_QP, FIFOF#(DataStream))           reqPayloadOutVec <- replicateM(mkFIFOF);
    Vector#(MAX_QP, FIFOF#(RdmaPktMetaData))  reqPktMetaDataOutVec <- replicateM(mkFIFOF);
    Vector#(MAX_QP, FIFOF#(DataStream))          respPayloadOutVec <- replicateM(mkFIFOF);
    Vector#(MAX_QP, FIFOF#(RdmaPktMetaData)) respPktMetaDataOutVec <- replicateM(mkFIFOF);

    // Pipeline buffers
    FIFOF#(Tuple5#(RdmaHeader, BTH, Bool, Bool, Bool))                     rdmaHeaderRecvQ <- mkFIFOF;
    FIFOF#(DataStream)                                                        payloadRecvQ <- mkFIFOF;
    FIFOF#(Tuple2#(RdmaHeader, BTH))                                   rdmaHeaderPreCheckQ <- mkFIFOF;
    FIFOF#(DataStream)                                                    payloadPreCheckQ <- mkFIFOF;
    FIFOF#(Tuple3#(RdmaHeader, BTH, HeaderValidateInfo))             rdmaHeaderValidationQ <- mkFIFOF;
    FIFOF#(DataStream)                                                  payloadValidationQ <- mkFIFOF;
    FIFOF#(Tuple3#(RdmaHeader, BTH, ValidHeaderInfo))                    rdmaHeaderFilterQ <- mkFIFOF;
    FIFOF#(DataStream)                                                      payloadFilterQ <- mkFIFOF;
    FIFOF#(Tuple3#(RdmaHeader, BTH, ValidHeaderInfo))               rdmaHeaderFragLenCalcQ <- mkFIFOF;
    FIFOF#(DataStream)                                                 payloadFragLenCalcQ <- mkFIFOF;
    FIFOF#(Tuple3#(RdmaHeader, BTH, ValidHeaderInfo))                rdmaHeaderPktLenCalcQ <- mkFIFOF;
    FIFOF#(Tuple5#(DataStream, ByteEnBitNum, ByteEnBitNum, Bool, Bool)) payloadPktLenCalcQ <- mkFIFOF;
    FIFOF#(PktLenCheckInfo)                                      rdmaHeaderPktLenPreCheckQ <- mkFIFOF;
    FIFOF#(Tuple3#(DataStream, IndexQP, Bool))                      payloadPktLenPreCheckQ <- mkFIFOF;
    FIFOF#(Tuple4#(PktLenCheckInfo, Bool, Bool, Bool))              rdmaHeaderPktLenCheckQ <- mkFIFOF;
    FIFOF#(Tuple3#(DataStream, IndexQP, Bool))                         payloadPktLenCheckQ <- mkFIFOF;
    FIFOF#(Tuple3#(RdmaPktMetaData, IndexQP, Bool))                      rdmaHeaderOutputQ <- mkFIFOF;
    FIFOF#(Tuple3#(DataStream, IndexQP, Bool))                              payloadOutputQ <- mkFIFOF;

    Reg#(Bool)        isValidPktReg <- mkRegU;
    Reg#(PAD)          bthPadCntReg <- mkRegU;
    Reg#(PktFragNum)  pktFragNumReg <- mkRegU;
    Reg#(PktLen)          pktLenReg <- mkRegU;
    Reg#(Bool)          pktValidReg <- mkRegU;

    Reg#(RdmaPktBufState) pktBufStateReg <- mkReg(RDMA_PKT_BUT_ST_PRE_CHECK_FRAG);

    let payloadPipeIn <- mkBuffer(pipeIn.payload);
    let rdmaHeaderPipeOut <- mkDataStream2Header(
        pipeIn.headerAndMetaData.headerDataStream,
        pipeIn.headerAndMetaData.headerMetaData
    );

    function Bool fifofNotEmpty(FIFOF#(anytype) fifof) = fifof.notEmpty;
    function Bool fifofNotFull(FIFOF#(anytype) fifof) = fifof.notFull;
    function Bool fifofVecAll(
        function Bool mapFunc(FIFOF#(anytype) fifof),
        Vector#(vSz, FIFOF#(anytype)) fifofVec
    ) provisos(Add#(1, anysize, vSz));
        let fifofMapVec = map(mapFunc, fifofVec);
        let result = fold(\&& , fifofMapVec);
        return result;
    endfunction
/*
    rule debug if (!(
        payloadPipeIn.notEmpty                 &&
        rdmaHeaderPipeOut.notEmpty             &&
        fifofVecAll(fifofNotFull, cnpOutVec)             &&
        fifofVecAll(fifofNotFull, reqPayloadOutVec)      &&
        fifofVecAll(fifofNotFull, reqPktMetaDataOutVec)  &&
        fifofVecAll(fifofNotFull, respPayloadOutVec)     &&
        fifofVecAll(fifofNotFull, respPktMetaDataOutVec) &&
        rdmaHeaderRecvQ.notFull                &&
        payloadRecvQ.notFull                   &&
        rdmaHeaderPreCheckQ.notFull            &&
        payloadPreCheckQ.notFull               &&
        rdmaHeaderValidationQ.notFull          &&
        payloadValidationQ.notFull             &&
        rdmaHeaderFilterQ.notFull              &&
        payloadFilterQ.notFull                 &&
        rdmaHeaderFragLenCalcQ.notFull         &&
        payloadFragLenCalcQ.notFull            &&
        rdmaHeaderPktLenCalcQ.notFull          &&
        payloadPktLenCalcQ.notFull             &&
        rdmaHeaderPktLenPreCheckQ.notFull      &&
        payloadPktLenPreCheckQ.notFull         &&
        rdmaHeaderPktLenCheckQ.notFull         &&
        payloadPktLenCheckQ.notFull            &&
        rdmaHeaderOutputQ.notFull              &&
        payloadOutputQ.notFull
    ));
        $display(
            "time=%0t: mkInputRdmaPktBufAndHeaderValidation debug", $time,
            ", payloadPipeIn.notEmpty=", fshow(payloadPipeIn.notEmpty),
            ", rdmaHeaderPipeOut.notEmpty=", fshow(rdmaHeaderPipeOut.notEmpty),
            // ", cnpOutVec[0].notFull=", fshow(cnpOutVec[0].notFull),
            // ", reqPayloadOutVec[0].notFull=", fshow(reqPayloadOutVec[0].notFull),
            // ", reqPktMetaDataOutVec[0].notFull=", fshow(reqPktMetaDataOutVec[0].notFull),
            // ", respPayloadOutVec[0].notFull=", fshow(respPayloadOutVec[0].notFull),
            // ", respPktMetaDataOutVec[0].notFull=", fshow(respPktMetaDataOutVec[0].notFull),
            ", rdmaHeaderRecvQ.notFull=", fshow(rdmaHeaderRecvQ.notFull),
            ", payloadRecvQ.notFull=", fshow(payloadRecvQ.notFull),
            ", rdmaHeaderPreCheckQ.notFull=", fshow(rdmaHeaderPreCheckQ.notFull),
            ", payloadPreCheckQ.notFull=", fshow(payloadPreCheckQ.notFull),
            ", rdmaHeaderValidationQ.notFull=", fshow(rdmaHeaderValidationQ.notFull),
            ", payloadValidationQ.notFull=", fshow(payloadValidationQ.notFull),
            ", rdmaHeaderFilterQ.notFull=", fshow(rdmaHeaderFilterQ.notFull),
            ", payloadFilterQ.notFull=", fshow(payloadFilterQ.notFull),
            ", rdmaHeaderFragLenCalcQ.notFull=", fshow(rdmaHeaderFragLenCalcQ.notFull),
            ", payloadFragLenCalcQ.notFull=", fshow(payloadFragLenCalcQ.notFull),
            ", rdmaHeaderPktLenCalcQ.notFull=", fshow(rdmaHeaderPktLenCalcQ.notFull),
            ", payloadPktLenCalcQ.notFull=", fshow(payloadPktLenCalcQ.notFull),
            ", rdmaHeaderPktLenPreCheckQ.notFull=", fshow(rdmaHeaderPktLenPreCheckQ.notFull),
            ", payloadPktLenPreCheckQ.notFull=", fshow(payloadPktLenPreCheckQ.notFull),
            ", rdmaHeaderPktLenCheckQ.notFull=", fshow(rdmaHeaderPktLenCheckQ.notFull),
            ", payloadPktLenCheckQ.notFull=", fshow(payloadPktLenCheckQ.notFull),
            ", rdmaHeaderOutputQ.notFull=", fshow(rdmaHeaderOutputQ.notFull),
            ", payloadOutputQ.notFull=", fshow(payloadOutputQ.notFull)
        );
        for (Integer idx = 0; idx < valueOf(MAX_QP); idx = idx + 1) begin
            $display(
                ", cnpOutVec[%0d].notFull=", idx, fshow(cnpOutVec[idx].notFull),
                ", reqPayloadOutVec[%0d].notFull=", idx, fshow(reqPayloadOutVec[idx].notFull),
                ", reqPktMetaDataOutVec[%0d].notFull=", idx, fshow(reqPktMetaDataOutVec[idx].notFull),
                ", respPayloadOutVec[%0d].notFull=", idx, fshow(respPayloadOutVec[idx].notFull),
                ", respPktMetaDataOutVec[%0d].notFull=", idx, fshow(respPktMetaDataOutVec[idx].notFull),
                ", cnpOutVec[%0d].notEmpty=", idx, fshow(cnpOutVec[idx].notEmpty),
                ", reqPayloadOutVec[%0d].notEmpty=", idx, fshow(reqPayloadOutVec[idx].notEmpty),
                ", reqPktMetaDataOutVec[%0d].notEmpty=", idx, fshow(reqPktMetaDataOutVec[idx].notEmpty),
                ", respPayloadOutVec[%0d].notEmpty=", idx, fshow(respPayloadOutVec[idx].notEmpty),
                ", respPktMetaDataOutVec[%0d].notEmpty=", idx, fshow(respPktMetaDataOutVec[idx].notEmpty)
            );
        end
    endrule
*/
    (* conflict_free = "recvPktFrag, \
                        preCheckHeader, \
                        discardInvalidFrag, \
                        prepareValidation, \
                        checkMetaDataQP, \
                        discardInvalidHeaderPkt, \
                        calcFraglen, \
                        calcPktLen, \
                        preCheckPktLen, \
                        checkPktLen, \
                        outputPayload, \
                        outputHeaderMetaData" *)
    rule recvPktFrag;
        let payloadFrag = payloadPipeIn.first;
        payloadPipeIn.deq;
        let payloadHasSingleFrag = payloadFrag.isFirst && payloadFrag.isLast;
        let fragHasNoData = isZero(payloadFrag.byteEn);

        if (payloadFrag.isFirst) begin
            let rdmaHeader = rdmaHeaderPipeOut.first;
            let bth        = extractBTH(rdmaHeader.headerData);
            let aeth       = extractAETH(rdmaHeader.headerData);

            let bthCheckResult = checkZeroFields4BTH(bth);
            let headerCheckResult =
                padCntCheckReqHeader(bth) || padCntCheckRespHeader(bth, aeth);
            // Discard packet that should not have payload
            let nonPayloadHeaderShouldHaveNoPayload =
                rdmaHeader.headerMetaData.hasPayload ?
                    True : (payloadHasSingleFrag && fragHasNoData);

            rdmaHeaderPipeOut.deq;
            rdmaHeaderRecvQ.enq(tuple5(
                rdmaHeader, bth, bthCheckResult, headerCheckResult, nonPayloadHeaderShouldHaveNoPayload
            ));
            // $display(
            //     "time=%0t: recvPktFrag", $time,
            //     ", bthCheckResult=", fshow(bthCheckResult),
            //     ", headerCheckResult=", fshow(headerCheckResult),
            //     ", nonPayloadHeaderShouldHaveNoPayload=",
            //     fshow(nonPayloadHeaderShouldHaveNoPayload),
            //     ", bth=", fshow(bth), ", aeth=", fshow(aeth)
            // );
        end

        payloadRecvQ.enq(payloadFrag);
        // $display(
        //     "time=%0t: 1st stage recvPktFrag", $time
        //     // ", bth=", fshow(bth), ", aeth=", fshow(aeth)
        // );
    endrule

    rule preCheckHeader if (pktBufStateReg == RDMA_PKT_BUT_ST_PRE_CHECK_FRAG);
        let payloadFrag = payloadRecvQ.first;
        payloadRecvQ.deq;

        if (payloadFrag.isFirst) begin
            let {
                rdmaHeader, bth, bthCheckResult, headerCheckResult, nonPayloadHeaderShouldHaveNoPayload
            } = rdmaHeaderRecvQ.first;
            rdmaHeaderRecvQ.deq;

            if (bthCheckResult && headerCheckResult && nonPayloadHeaderShouldHaveNoPayload) begin
                // Packet header is valid
                rdmaHeaderPreCheckQ.enq(tuple2(rdmaHeader, bth));
                payloadPreCheckQ.enq(payloadFrag);

                // $display(
                //     "time=%0t: bth=", $time, fshow(bth),
                //     ", headerMetaData=", fshow(rdmaHeader.headerMetaData),
                //     "\ntime=%0t: payloadFrag=", $time, fshow(payloadFrag)
                // );
            end
            else begin
                if (!payloadFrag.isLast) begin
                    $warning(
                        "time=%0t: InputRdmaPktBuf preCheckHeader", $time,
                        ", discard invalid RDMA packet of multi-fragment payload"
                    );
                    pktBufStateReg <= RDMA_PKT_BUF_ST_DISCARD_FRAG;
                end
                else begin
                    $warning(
                        "time=%0t: InputRdmaPktBuf preCheckHeader", $time,
                        ", discard invalid RDMA packet of single-fragment payload"
                    );
                end
            end
        end
        else begin
            payloadPreCheckQ.enq(payloadFrag);
            // $display("time=%0t: payloadFrag=", $time, fshow(payloadFrag));
        end
        // $display(
        //     "time=%0t: 2nd-1 stage preCheckHeader", $time
        //     // ", bthCheckResult=", fshow(bthCheckResult),
        //     // ", headerCheckResult=", fshow(headerCheckResult),
        //     // ", nonPayloadHeaderShouldHaveNoPayload=",
        //     // fshow(nonPayloadHeaderShouldHaveNoPayload),
        //     // ", bth=", fshow(bth)
        // );
    endrule

    rule discardInvalidFrag if (pktBufStateReg == RDMA_PKT_BUF_ST_DISCARD_FRAG);
        let payload = payloadPipeIn.first;
        payloadPipeIn.deq;
        if (payload.isLast) begin
            pktBufStateReg <= RDMA_PKT_BUT_ST_PRE_CHECK_FRAG;
        end
        // $display("time=%0t: 2nd-2 stage discardInvalidFrag", $time);
    endrule

    rule prepareValidation;
        let payloadFrag = payloadPreCheckQ.first;
        payloadPreCheckQ.deq;

        if (payloadFrag.isFirst) begin
            let { rdmaHeader, bth } = rdmaHeaderPreCheckQ.first;
            rdmaHeaderPreCheckQ.deq;

            let isCNP  = isCongestionNotificationPkt(bth);
            let deth   = extractDETH(rdmaHeader.headerData);
            let xrceth = extractXRCETH(rdmaHeader.headerData);

            let isRespPkt       = isRdmaRespOpCode(bth.opcode);
            let isLastPkt       = isLastRdmaOpCode(bth.opcode);
            let isFirstOrMidPkt = isFirstOrMiddleRdmaOpCode(bth.opcode);
            let isLastOrOnlyPkt = isLastOrOnlyRdmaOpCode(bth.opcode);
            // CNP is also RDMA response
            let isRespPktOrCNP = isRespPkt || isCNP;
            // If XRC requests, DQPN is defined in XRCETH, otherwise in BTH
            let dqpn = (bth.trans == TRANS_TYPE_XRC && !isRespPktOrCNP) ? xrceth.srqn : bth.dqpn;
            let maybePdHandler = qpMetaData.getPD(dqpn);

            let headerValidateInfo = HeaderValidateInfo {
                maybePdHandler : maybePdHandler,
                dqpn           : dqpn,
                qkeyDETH       : deth.qkey,
                isCNP          : isCNP,
                isRespPkt      : isRespPkt,
                isLastPkt      : isLastPkt,
                isFirstOrMidPkt: isFirstOrMidPkt,
                isLastOrOnlyPkt: isLastOrOnlyPkt
            };
            rdmaHeaderValidationQ.enq(tuple3(rdmaHeader, bth, headerValidateInfo));
        end

        payloadValidationQ.enq(payloadFrag);
        // $display("time=%0t: 3rd stage prepareValidation", $time);
    endrule

    rule checkMetaDataQP;
        let payloadFrag = payloadValidationQ.first;
        payloadValidationQ.deq;

        if (payloadFrag.isFirst) begin
            let { rdmaHeader, bth, headerValidateInfo } = rdmaHeaderValidationQ.first;
            rdmaHeaderValidationQ.deq;

            let isCNP           = headerValidateInfo.isCNP;
            let isRespPkt       = headerValidateInfo.isRespPkt;
            let isLastPkt       = headerValidateInfo.isLastPkt;
            let isFirstOrMidPkt = headerValidateInfo.isFirstOrMidPkt;
            let isLastOrOnlyPkt = headerValidateInfo.isLastOrOnlyPkt;

            let qp = qpMetaData.getQueuePairByQPN(headerValidateInfo.dqpn);
            let isResp = isRespPkt || isCNP;
            let cntrlStatus = isResp ? qp.statusSQ : qp.statusRQ;

            let isValidHeader = False;
            let pdHandler = dontCareValue;
            if (headerValidateInfo.maybePdHandler matches tagged Valid .pdh) begin
                pdHandler = pdh;
                isValidHeader = validateHeader(
                    bth.trans,
                    headerValidateInfo.qkeyDETH,
                    cntrlStatus,
                    isResp
                );
            end
            // $display(
            //     "time=%0t: checkMetaDataQP", $time,
            //     ", pdHandler=%h", pdHandler,
            //     ", dqpn=%h", headerValidateInfo.dqpn,
            //     ", bth.dqpn=%h", bth.dqpn,
            //     ", bth.psn=%h", bth.psn,
            //     ", bth.opcode=", fshow(bth.opcode),
            //     ", qp.statusRQ.comm.isERR=", fshow(qp.statusRQ.comm.isERR)
            // );

            // let transTypeMatch = transTypeMatchQpType(bth.trans, cntrlStatus.getTypeQP, isRespPkt);
            // let qpStateMatch = isRespPkt ? cntrlStatus.comm.isRTS : cntrlStatus.comm.isNonErr;
            // immAssert(
            //     cntrlStatus.comm.isNonErr && isValidHeader,
            //     "isNonErr and isValidHeader assertion @ mkInputRdmaPktBufAndHeaderValidation",
            //     $format(
            //         "cntrlStatus.comm.isNonErr=", fshow(cntrlStatus.comm.isNonErr),
            //         " and isValidHeader=", fshow(isValidHeader),
            //         " should both be true, when bth.trans=", fshow(bth.trans),
            //         ", pdHandle=", fshow(pdHandler),
            //         ", bth.trans=", fshow(bth.trans),
            //         ", cntrlStatus.getTypeQP=", fshow(cntrlStatus.getTypeQP),
            //         // ", transTypeMatch=", fshow(transTypeMatch),
            //         // ", qpStateMatch=", fshow(qpStateMatch),
            //         ", qkey=%h, isResp=", headerValidateInfo.qkeyDETH, fshow(isResp)
            //     )
            // );

            let validHeaderInfo = ValidHeaderInfo {
                pdHandler      : pdHandler,
                dqpn           : headerValidateInfo.dqpn,
                pmtu           : qp.statusSQ.comm.getPMTU,
                isValidHeader  : isValidHeader,
                isCNP          : isCNP,
                isRespPkt      : isRespPkt,
                isLastPkt      : isLastPkt,
                isFirstOrMidPkt: isFirstOrMidPkt,
                isLastOrOnlyPkt: isLastOrOnlyPkt
            };
            rdmaHeaderFilterQ.enq(tuple3(rdmaHeader, bth, validHeaderInfo));
        end

        payloadFilterQ.enq(payloadFrag);
        // $display("time=%0t: 4th stage checkMetaDataQP", $time);
    endrule

    rule discardInvalidHeaderPkt;
        let payloadFrag = payloadFilterQ.first;
        payloadFilterQ.deq;

        let isValidPkt = isValidPktReg;

        if (payloadFrag.isFirst) begin
            let { rdmaHeader, bth, validHeaderInfo } = rdmaHeaderFilterQ.first;
            rdmaHeaderFilterQ.deq;

            let isValidHeader = validHeaderInfo.isValidHeader;
            let isCNP = validHeaderInfo.isCNP;
            if (isValidHeader) begin
                if (!isCNP) begin
                    rdmaHeaderFragLenCalcQ.enq(tuple3(rdmaHeader, bth, validHeaderInfo));
                end
                else begin
                    let qpIndex = getIndexQP(bth.dqpn);
                    cnpOutVec[qpIndex].enq(bth);
                end
            end
            // else begin
            //     $display(
            //         "time=%0t: found invalid header", $time,
            //         ", isValidHeader=", fshow(isValidHeader)
            //     );
            // end

            isValidPkt = isValidHeader && !isCNP;
            isValidPktReg <= isValidPkt;
        end

        // immAssert(
        //     isValidPkt,
        //     "isValidPkt assertion @ mkInputRdmaPktBufAndHeaderValidation",
        //     $format(
        //         "isValidPkt=", fshow(isValidPkt),
        //         " should be true"
        //     )
        // );

        if (isValidPkt) begin
            payloadFragLenCalcQ.enq(payloadFrag);
        end
        // $display(
        //     "time=%0t: 5th stage discardInvalidHeaderPkt", $time,
        //     ", isValidPkt=", fshow(isValidPkt)
        // );
    endrule

    rule calcFraglen;
        let payloadFrag = payloadFragLenCalcQ.first;
        payloadFragLenCalcQ.deq;

        let bthPadCnt = bthPadCntReg;
        if (payloadFrag.isFirst) begin
            let { rdmaHeader, bth, validHeaderInfo } = rdmaHeaderFragLenCalcQ.first;
            rdmaHeaderFragLenCalcQ.deq;

            bthPadCnt = bth.padCnt;
            bthPadCntReg <= bthPadCnt;

            rdmaHeaderPktLenCalcQ.enq(tuple3(rdmaHeader, bth, validHeaderInfo));

            // $display(
            //     "time=%0t: payloadFrag.byteEn=%h, payloadFrag.isFirst=",
            //     $time, payloadFrag.byteEn, fshow(payloadFrag.isFirst),
            //     ", payloadFrag.isLast=", payloadFrag.isLast, ", bth.psn=%h", bth.psn,
            //     ", bth.opcode=", fshow(bth.opcode), ", bth.padCnt=%h", bth.padCnt,
            //     ", payloadFrag.data=%h", payloadFrag.data
            // );
        end

        let payloadFragLen = calcFragByteNumFromByteEn(payloadFrag.byteEn);
        immAssert(
            isValid(payloadFragLen),
            "isValid(payloadFragLen) assertion @ mkInputRdmaPktBufAndHeaderValidation",
            $format(
                "payloadFragLen=", fshow(payloadFragLen), " should be valid"
            )
        );
        let fragLen         = unwrapMaybe(payloadFragLen);
        let isByteEnNonZero = !isZeroR(fragLen);
        let isByteEnAllOne  = isAllOnesR(payloadFrag.byteEn);
        ByteEnBitNum fragLenWithOutPad = fragLen - zeroExtend(bthPadCnt);

        payloadPktLenCalcQ.enq(tuple5(
            payloadFrag, fragLen, fragLenWithOutPad, isByteEnNonZero, isByteEnAllOne
        ));
        // $display("time=%0t: 6th stage calcFraglen", $time);
    endrule

    rule calcPktLen;
        let {
            payloadFrag, fragLen, fragLenWithOutPad, isByteEnNonZero, isByteEnAllOne
        } = payloadPktLenCalcQ.first;
        payloadPktLenCalcQ.deq;

        let { rdmaHeader, bth, validHeaderInfo } = rdmaHeaderPktLenCalcQ.first;

        let pdHandler       = validHeaderInfo.pdHandler;
        let pmtu            = validHeaderInfo.pmtu;
        let qpIndex         = getIndexQP(validHeaderInfo.dqpn);
        let isRespPkt       = validHeaderInfo.isRespPkt;
        let isLastPkt       = validHeaderInfo.isLastPkt;
        let isFirstOrMidPkt = validHeaderInfo.isFirstOrMidPkt;
        let isLastOrOnlyPkt = validHeaderInfo.isLastOrOnlyPkt;

        let pktLen = pktLenReg;
        let pktFragNum = pktFragNumReg;
        let pktValid = False;

        // PktLen fragLenExt = zeroExtend(fragLen);
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

        if (payloadFrag.isLast) begin
            rdmaHeaderPktLenCalcQ.deq;

            let pktLenCheckInfo = PktLenCheckInfo {
                trans          : bth.trans,
                opcode         : bth.opcode,
                padCnt         : bth.padCnt,
                psn            : bth.psn,
                dqpn           : validHeaderInfo.dqpn,
                rdmaHeader     : rdmaHeader,
                pdHandler      : pdHandler,
                pktFragNum     : pktFragNum,
                pktLen         : pktLen,
                pmtu           : pmtu,
                pktValid       : pktValid,
                isFirstOrMidPkt: isFirstOrMidPkt,
                isLastOrOnlyPkt: isLastOrOnlyPkt
            };
            rdmaHeaderPktLenPreCheckQ.enq(pktLenCheckInfo);
        end
        payloadPktLenPreCheckQ.enq(tuple3(payloadFrag, qpIndex, isRespPkt));
        // $display(
        //     "time=%0t: 7th stage calcPktLen", $time,
        //     ", pktLen=%0d, pktFragNum=%0d", pktLen, pktFragNum,
        //     ", isByteEnAllOne=", fshow(isByteEnAllOne),
        //     ", pktValid=", fshow(pktValid),
        //     // ", payloadOutQ.notFull=", fshow(payloadOutQ.notFull),
        //     // ", pktMetaDataOutQ.notFull=", fshow(pktMetaDataOutQ.notFull),
        //     ", DATA_STREAM_FRAG_BUF_SIZE=%0d", valueOf(DATA_STREAM_FRAG_BUF_SIZE),
        //     ", PKT_META_DATA_BUF_SIZE=%0d", valueOf(PKT_META_DATA_BUF_SIZE),
        //     ", payloadFrag.byteEn=%h" , payloadFrag.byteEn,
        //     ", payloadFrag.isFirst=", fshow(payloadFrag.isFirst),
        //     ", payloadFrag.isLast=", fshow(payloadFrag.isLast),
        //     ", bth.psn=%h", bth.psn,
        //     ", bth.opcode=", fshow(bth.opcode),
        //     ", bth.padCnt=%h", bth.padCnt
        //     // ", payloadFrag.data=%h", payloadFrag.data
        // );
    endrule

    rule preCheckPktLen;
        let { payloadFrag, qpIndex, isRespPkt } = payloadPktLenPreCheckQ.first;
        payloadPktLenPreCheckQ.deq;

        if (payloadFrag.isLast) begin
            let pktLenCheckInfo = rdmaHeaderPktLenPreCheckQ.first;
            rdmaHeaderPktLenPreCheckQ.deq;

            let pktLen = pktLenCheckInfo.pktLen;
            let pmtu   = pktLenCheckInfo.pmtu;

            let isZeroPayloadLen = isZeroR(pktLen);
            let isPktLenEqPMTU   = pktLenEqPMTU(pktLen, pmtu);
            let isPktLenGtPMTU   = pktLenGtPMTU(pktLen, pmtu);

            rdmaHeaderPktLenCheckQ.enq(tuple4(
                pktLenCheckInfo, isZeroPayloadLen, isPktLenEqPMTU, isPktLenGtPMTU
            ));
        end

        payloadPktLenCheckQ.enq(tuple3(payloadFrag, qpIndex, isRespPkt));
        // $display("time=%0t: 8th stage preCheckPktLen", $time);
    endrule

    rule checkPktLen;
        let { payloadFrag, qpIndex, isRespPkt } = payloadPktLenCheckQ.first;
        payloadPktLenCheckQ.deq;

        if (payloadFrag.isLast) begin
            let {
                pktLenCheckInfo, isZeroPayloadLen, isPktLenEqPMTU, isPktLenGtPMTU
            } = rdmaHeaderPktLenCheckQ.first;
            rdmaHeaderPktLenCheckQ.deq;

            let rdmaHeader      = pktLenCheckInfo.rdmaHeader;
            let pdHandler       = pktLenCheckInfo.pdHandler;
            let pktFragNum      = pktLenCheckInfo.pktFragNum;
            let pktLen          = pktLenCheckInfo.pktLen;
            let pmtu            = pktLenCheckInfo.pmtu;
            let pktValid        = pktLenCheckInfo.pktValid;
            let isFirstOrMidPkt = pktLenCheckInfo.isFirstOrMidPkt;
            let isLastOrOnlyPkt = pktLenCheckInfo.isLastOrOnlyPkt;

            // fix byteEN to prevent dma write access touch unrelated bytes.
            payloadFrag.byteEn = payloadFrag.byteEn << pktLenCheckInfo.padCnt;

            if (!isZeroPayloadLen) begin
                payloadOutputQ.enq(tuple3(payloadFrag, qpIndex, isRespPkt));
                // $display("time=%0t: payloadFrag=", $time, fshow(payloadFrag));
            end
            else begin
                // Discard zero length payload no matter packet has payload or not
                $info(
                    "time=%0t: InputRdmaPktBuf checkPktLen", $time,
                    ", discard zero-length payload for RDMA packet"
                );
            end

            if (pktValid) begin
                pktValid = (isFirstOrMidPkt && isPktLenEqPMTU) ||
                    (isLastOrOnlyPkt && !isPktLenGtPMTU);

                // $display(
                //     "time=%0t: checkPktLen", $time,
                //     ", bth.trans=", fshow(pktLenCheckInfo.trans),
                //     ", bth.dqpn=%h", pktLenCheckInfo.dqpn,
                //     ", bth.psn=%h", pktLenCheckInfo.psn,
                //     ", bth.opcode=", fshow(pktLenCheckInfo.opcode),
                //     ", bth.padCnt=%h", pktLenCheckInfo.padCnt,
                //     ", pktLen=%0d", pktLen,
                //     ", pmtu=", fshow(pmtu),
                //     ", isFirstOrMidPkt=", fshow(isFirstOrMidPkt),
                //     ", isPktLenEqPMTU=", fshow(isPktLenEqPMTU),
                //     ", isLastOrOnlyPkt=", fshow(isLastOrOnlyPkt),
                //     ", isPktLenGtPMTU=", fshow(isPktLenGtPMTU),
                //     ", pktValid=", fshow(pktValid)
                // );
            end

            let pktStatus = PKT_ST_VALID;
            if (!pktValid) begin
                // Invalid packet length
                pktStatus = PKT_ST_LEN_ERR;
            end
            let pktMetaData = RdmaPktMetaData {
                pktPayloadLen   : pktLen,
                pktFragNum      : (isZeroPayloadLen ? 0 : pktFragNum),
                isZeroPayloadLen: isZeroPayloadLen,
                pktHeader       : rdmaHeader,
                pdHandler       : pdHandler,
                pktValid        : pktValid,
                pktStatus       : pktStatus
            };

            rdmaHeaderOutputQ.enq(tuple3(pktMetaData, qpIndex, isRespPkt));
            // $display(
            //     "time=%0t:", $time, " pktMetaData=", fshow(pktMetaData)
            //     // "time=%0t: bth=", $time, fshow(bth), ", pktMetaData=", fshow(pktMetaData)
            // );
        end
        else begin
            payloadOutputQ.enq(tuple3(payloadFrag, qpIndex, isRespPkt));
            // $display("time=%0t: payloadFrag=", $time, fshow(payloadFrag));
        end
        // $display("time=%0t: 9th stage checkPktLen", $time);
    endrule

    rule outputPayload;
        let { payloadFrag, qpIndex, isRespPkt } = payloadOutputQ.first;
        payloadOutputQ.deq;

        if (isRespPkt) begin
            respPayloadOutVec[qpIndex].enq(payloadFrag);
        end
        else begin
            reqPayloadOutVec[qpIndex].enq(payloadFrag);
        end
        // $display(
        //     "time=%0t: 10th stage outputPayload", $time,
        //     ", qpIndex=%0d, isRespPkt=", qpIndex, fshow(isRespPkt)
        // );
    endrule

    rule outputHeaderMetaData;
        let { pktMetaData, qpIndex, isRespPkt } = rdmaHeaderOutputQ.first;
        rdmaHeaderOutputQ.deq;

        if (isRespPkt) begin
            respPktMetaDataOutVec[qpIndex].enq(pktMetaData);
        end
        else begin
            reqPktMetaDataOutVec[qpIndex].enq(pktMetaData);
        end
        // $display("time=%0t: final stage outputHeaderMetaData", $time);
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
