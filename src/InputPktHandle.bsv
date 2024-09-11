import FIFOF :: *;
import PAClib :: *;
import Vector :: *;
import ClientServer :: *;
import GetPut :: *;
import BRAM :: *;

import DataTypes :: *;
import ExtractAndPrependPipeOut :: *;
import Headers :: *;
import MetaData :: *;
import PrimUtils :: *;
import Settings :: *;
import RdmaUtils :: *;

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
        SEND_MIDDLE            : zeroPadCntCheck;
        SEND_FIRST                         ,
        SEND_LAST, SEND_ONLY               ,
        SEND_LAST_WITH_IMMEDIATE           ,
        SEND_ONLY_WITH_IMMEDIATE           ,
        SEND_LAST_WITH_INVALIDATE          ,
        SEND_ONLY_WITH_INVALIDATE          : True;

        RDMA_WRITE_MIDDLE: zeroPadCntCheck ;
        RDMA_WRITE_FIRST                   ,
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
function Bool validateHeader(TransType transType, QKEY qkey, EntryCommonQPC qpcCommon);
    let transTypeMatch = transTypeMatchQpType(transType, qpcCommon.qpType, True);
    return transTypeMatch;
endfunction



interface HeaderAndMetaDataAndPayloadSeperateDataStreamPipeOut;
    interface HeaderDataStreamAndMetaDataPipeOut headerAndMetaData;
    interface DataStreamFragMetaPipeOut payloadStreamFragMetaPipeOut;
    interface RqDataStreamWithExtraInfoPipeIn rdmaPktPipeIn;
    interface Put#(InputStreamFragBufferIdx) payloadStreamFragStorageIdxIn;
    interface Get#(Tuple2#(InputStreamFragBufferIdx, DATA)) payloadStreamFragStorageDataOut;
endinterface

// After extract header from rdmaPktPipeIn,
// it outputs header DataStream and payload DataStream,
// and every header DataStream has corresponding payload DataStream,
// if header has no payload, then output empty payload DataStream.
// This module will not discard invalid packet.
(* synthesize *)
module mkExtractHeaderFromRdmaPktPipeOut(HeaderAndMetaDataAndPayloadSeperateDataStreamPipeOut);
    FIFOF#(RqDataStreamWithExtraInfo) rdmaPktPipeInQ <- mkFIFOF;

    FIFOF#(HeaderMetaData) headerMetaDataInQ <- mkFIFOF;
    FIFOF#(DataStream) dataInQ <- mkSizedFIFOF(3);
    

    Vector#(2, PipeOut#(HeaderMetaData)) headerMetaDataPipeOutVec <-
        mkForkVector(toPipeOut(headerMetaDataInQ));
    let headerMetaDataPipeIn = headerMetaDataPipeOutVec[0];
    let headerMetaDataPipeOut <- mkBuffer(headerMetaDataPipeOutVec[1]);
    let dataPipeIn = toPipeOut(dataInQ);
    let headerAndPayloadPipeOut <- mkExtractHeaderFromDataStreamPipeOut(
        dataPipeIn, headerMetaDataPipeIn
    );

    rule debug;
        if (!rdmaPktPipeInQ.notFull) begin
            $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: mkExtractHeaderFromRdmaPktPipeOut rdmaPktPipeInQ");
        end
        if (!headerMetaDataInQ.notFull) begin
            $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: mkExtractHeaderFromRdmaPktPipeOut headerMetaDataInQ");
        end
        if (!dataInQ.notFull) begin
            $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: mkExtractHeaderFromRdmaPktPipeOut dataInQ");
        end
       
    endrule

    rule extractHeader;
        let {rdmaPktDataStream, isEmptyHeader, srcMacIpIdx} = rdmaPktPipeInQ.first;
        rdmaPktPipeInQ.deq;
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

            let headerMetaData = genHeaderMetaData(headerLen, headerHasPayload, isEmptyHeader, srcMacIpIdx);
            headerMetaDataInQ.enq(headerMetaData);
            $display(
                "time=%0t: extractHeader", $time,
                ", headerLen=%0d", headerLen,
                ", rdmaOpCode=", fshow(rdmaOpCode),
                ", transType=", fshow(transType),
                ", rdmaPktDataStream=", fshow(rdmaPktDataStream),
                ", headerHasPayload=", fshow(headerHasPayload),
                ", headerMetaData=", fshow(headerMetaData)
            );
        end
        // $display("time=%0t: rdmaPktDataStream=", $time, fshow(rdmaPktDataStream));
    endrule

    interface headerAndMetaData = interface HeaderDataStreamAndMetaDataPipeOut;
        interface headerDataStream = headerAndPayloadPipeOut.header;
        interface headerMetaData = headerMetaDataPipeOut;
    endinterface;
    interface payloadStreamFragMetaPipeOut = headerAndPayloadPipeOut.payloadStreamFragMetaPipeOut;
    interface rdmaPktPipeIn = toPut(rdmaPktPipeInQ);
    interface payloadStreamFragStorageIdxIn = headerAndPayloadPipeOut.payloadStreamFragStorageIdxIn;
    interface payloadStreamFragStorageDataOut = headerAndPayloadPipeOut.payloadStreamFragStorageDataOut;
endmodule

interface InputRdmaPktBuf;
    interface RdmaPktMetaDataAndQpcAndPayloadPipeOut reqPktPipeOut;
    
    interface DataStreamPipeIn headerDataStreamPipeIn;
    interface Put#(HeaderMetaData) headerMetaDataPipeIn;
    interface DataStreamFragMetaPipeIn payloadStreamFragMetaPipeIn;

    interface Client#(ReadReqCommonQPC, Maybe#(EntryCommonQPC)) qpcReadCommonClt;
endinterface

typedef struct {
    QPN dqpn;
    QKEY qkeyDETH;
    Bool isLastPkt;
    Bool isFirstOrMidPkt;
    Bool isLastOrOnlyPkt;
    Bool pktValid;
} HeaderValidateInfo deriving(Bits);

typedef struct {
    QPN  dqpn;
    PMTU pmtu;
    Bool isValidHeader;
    Bool isLastPkt;
    Bool isFirstOrMidPkt;
    Bool isLastOrOnlyPkt;
} ValidHeaderInfo deriving(Bits);

typedef struct {
    PAD         padCnt;
    HeaderRDMA  rdmaHeader;
    PktFragNum  pktFragNum;
    PktLen      pktLen;
    PMTU        pmtu;
    Bool        pktValid;
    Bool        isFirstOrMidPkt;
    Bool        isLastOrOnlyPkt;
    Bool        isMidPkt;
} PktLenCheckInfo deriving(Bits);




// This module will discard:
// - invalid packet that header is without payload but packet has payload;
// TODO: check write requests have non-zero RETH.dlen but without payload
// TODO: check remote XRC domain and XRCETH valid?
// TODO: reset mkInputRdmaPktBufAndHeaderValidation when error or retry?
(* synthesize *)
module mkInputRdmaPktBufAndHeaderValidation(InputRdmaPktBuf);
    // Output FIFO for PipeOut
    FIFOF#(DataStreamFragMetaData)   reqPayloadFragMetaOutQ <- mkFIFOF;
    FIFOF#(RdmaPktMetaDataAndQPC)  reqPktMetaDataAndQpcOutQ <- mkFIFOF;

    // Pipeline buffers
    FIFOF#(Tuple4#(HeaderRDMA, Bool, Bool, Bool))                                                     rdmaHeaderRecvQ <- mkFIFOF;
    FIFOF#(DataStreamFragMetaData)                                                               payloadFragMetaRecvQ <- mkFIFOF;

    FIFOF#(Tuple2#(HeaderRDMA, Bool))                                                             rdmaHeaderPreCheckQ <- mkFIFOF;
    FIFOF#(DataStreamFragMetaData)                                                           payloadFragMetaPreCheckQ <- mkFIFOF;

    FIFOF#(Tuple2#(HeaderRDMA, HeaderValidateInfo))                                             rdmaHeaderValidationQ <- mkSizedFIFOF(valueOf(QPC_QUERY_RESP_MAX_DELAY));
    FIFOF#(DataStreamFragMetaData)                                                         payloadFragMetaValidationQ <- mkSizedFIFOF(valueOf(QPC_QUERY_RESP_MAX_DELAY));

    FIFOF#(Tuple3#(HeaderRDMA, Maybe#(EntryCommonQPC), ValidHeaderInfo))                       rdmaHeaderFragLenCalcQ <- mkFIFOF;
    FIFOF#(DataStreamFragMetaData)                                                        payloadFragMetaFragLenCalcQ <- mkFIFOF;

    FIFOF#(Tuple3#(HeaderRDMA, Maybe#(EntryCommonQPC), ValidHeaderInfo))                        rdmaHeaderPktLenCalcQ <- mkFIFOF;
    FIFOF#(Tuple5#(DataStreamFragMetaData, ByteEnBitNum, ByteEnBitNum, Bool, Bool))                payloadPktLenCalcQ <- mkFIFOF;

    FIFOF#(Tuple2#(PktLenCheckInfo, Maybe#(EntryCommonQPC)))                                rdmaHeaderPktLenPreCheckQ <- mkFIFOF;
    FIFOF#(DataStreamFragMetaData)                                                     payloadFragMetaPktLenPreCheckQ <- mkFIFOF;

    FIFOF#(Tuple5#(PktLenCheckInfo, Maybe#(EntryCommonQPC), Bool, Bool, Bool))                 rdmaHeaderPktLenCheckQ <- mkFIFOF;
    FIFOF#(DataStreamFragMetaData)                                                        payloadFragMetaPktLenCheckQ <- mkFIFOF;


    Reg#(PAD)          bthPadCntReg <- mkRegU;
    Reg#(PktFragNum)  pktFragNumReg <- mkRegU;
    Reg#(PktLen)          pktLenReg <- mkRegU;
    Reg#(Bool)          pktValidReg <- mkRegU;

    FIFOF#(DataStreamFragMetaData) payloadStreamFragMetaPipeInQ <- mkFIFOF;
    FIFOF#(DataStream) headerDataStreamQ                        <- mkFIFOF;
    let headerMetaDataQ                                         <- mkFIFOF;

    let rdmaHeaderPipeOut <- mkDataStream2Header(
        toPipeOut(headerDataStreamQ),
        toPipeOut(headerMetaDataQ)
    );

    BypassClient#(ReadReqCommonQPC, Maybe#(EntryCommonQPC)) qpcReadCommonCltInst <- mkBypassClient("qpcReadCommonCltInst");

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


    rule debug;
        if (!rdmaHeaderRecvQ.notFull) begin
            $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: rdmaHeaderRecvQ");
        end
        if (!payloadFragMetaRecvQ.notFull) begin
            $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: payloadFragMetaRecvQ");
        end
        if (!rdmaHeaderPreCheckQ.notFull) begin
            $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: rdmaHeaderPreCheckQ");
        end
        if (!payloadFragMetaPreCheckQ.notFull) begin
            $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: payloadFragMetaPreCheckQ");
        end
        if (!rdmaHeaderValidationQ.notFull) begin
            $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: rdmaHeaderValidationQ");
        end
        if (!payloadFragMetaValidationQ.notFull) begin
            $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: payloadFragMetaValidationQ");
        end
        if (!rdmaHeaderFragLenCalcQ.notFull) begin
            $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: rdmaHeaderFragLenCalcQ");
        end
        if (!rdmaHeaderPktLenCalcQ.notFull) begin
            $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: rdmaHeaderPktLenCalcQ");
        end
        if (!payloadPktLenCalcQ.notFull) begin
            $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: payloadPktLenCalcQ");
        end
        if (!rdmaHeaderPktLenPreCheckQ.notFull) begin
            $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: rdmaHeaderPktLenPreCheckQ");
        end
        if (!payloadFragMetaPktLenPreCheckQ.notFull) begin
            $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: payloadFragMetaPktLenPreCheckQ");
        end
        if (!rdmaHeaderPktLenCheckQ.notFull) begin
            $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: rdmaHeaderPktLenCheckQ");
        end
        if (!payloadFragMetaPktLenCheckQ.notFull) begin
            $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: payloadFragMetaPktLenCheckQ");
        end
    endrule


    (* conflict_free = "recvPktFrag, \
                        preCheckHeader, \
                        prepareValidation, \
                        checkMetaDataQP, \
                        calcFraglen, \
                        calcPktLen, \
                        preCheckPktLen, \
                        checkPktLen" *)
    rule recvPktFrag;
        let payloadFragMeta = payloadStreamFragMetaPipeInQ.first;
        payloadStreamFragMetaPipeInQ.deq;
        let payloadHasSingleFrag = payloadFragMeta.isFirst && payloadFragMeta.isLast;
        let fragHasNoData = payloadFragMeta.isEmpty;    // TODO: check is this check necessary?

        if (payloadFragMeta.isFirst) begin
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
            rdmaHeaderRecvQ.enq(tuple4(
                rdmaHeader, bthCheckResult, headerCheckResult, nonPayloadHeaderShouldHaveNoPayload
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

        payloadFragMetaRecvQ.enq(payloadFragMeta);
        $display(
            "time=%0t: 1st stage recvPktFrag", $time
            // ", bth=", fshow(bth), ", aeth=", fshow(aeth)
        );
    endrule

    rule preCheckHeader;
        let streamFragMeta = payloadFragMetaRecvQ.first;
        payloadFragMetaRecvQ.deq;
        

        if (streamFragMeta.isFirst) begin
            let {
                rdmaHeader, bthCheckResult, headerCheckResult, nonPayloadHeaderShouldHaveNoPayload
            } = rdmaHeaderRecvQ.first;
            rdmaHeaderRecvQ.deq;

            let bth = extractBTH(rdmaHeader.headerData);
            $display("bthCheckResult=", bthCheckResult, "headerCheckResult=", headerCheckResult, "nonPayloadHeaderShouldHaveNoPayload=", nonPayloadHeaderShouldHaveNoPayload);
            let pktValid = True;
            if (rdmaHeader.headerMetaData.isEmptyHeader || (bthCheckResult && headerCheckResult && nonPayloadHeaderShouldHaveNoPayload)) begin
                pktValid = True;
                // $display(
                //     "time=%0t: bth=", $time, fshow(bth),
                //     ", headerMetaData=", fshow(rdmaHeader.headerMetaData),
                //     "\ntime=%0t: streamFragMeta=", $time, fshow(streamFragMeta)
                // );
            end
            else begin
                pktValid = False;
                if (!streamFragMeta.isLast) begin
                    $warning(
                        "time=%0t: InputRdmaPktBuf preCheckHeader", $time,
                        ", discard invalid RDMA packet of multi-fragment payload"
                    );
                end
                else begin
                    $warning(
                        "time=%0t: InputRdmaPktBuf preCheckHeader", $time,
                        ", discard invalid RDMA packet of single-fragment payload"
                    );
                end

            end

            rdmaHeaderPreCheckQ.enq(tuple2(rdmaHeader, pktValid));
        end

        payloadFragMetaPreCheckQ.enq(streamFragMeta);
        // $display("time=%0t: streamFragMeta=", $time, fshow(streamFragMeta));

        $display(
            "time=%0t: 2nd-1 stage preCheckHeader", $time
            // ", bthCheckResult=", fshow(bthCheckResult),
            // ", headerCheckResult=", fshow(headerCheckResult),
            // ", nonPayloadHeaderShouldHaveNoPayload=",
            // fshow(nonPayloadHeaderShouldHaveNoPayload),
            // ", bth=", fshow(bth)
        );
    endrule

    rule prepareValidation;
        let streamFragMeta = payloadFragMetaPreCheckQ.first;
        payloadFragMetaPreCheckQ.deq;

        if (streamFragMeta.isFirst) begin
            let {rdmaHeader, pktValid} = rdmaHeaderPreCheckQ.first;
            rdmaHeaderPreCheckQ.deq;

            let bth    = extractBTH(rdmaHeader.headerData);
            let deth   = extractDETH(rdmaHeader.headerData);
            let xrceth = extractXRCETH(rdmaHeader.headerData);

            let isLastPkt       = isLastRdmaOpCode(bth.opcode);
            let isFirstOrMidPkt = isFirstOrMiddleRdmaOpCode(bth.opcode);
            let isLastOrOnlyPkt = isLastOrOnlyRdmaOpCode(bth.opcode);
            let dqpn            = bth.dqpn;
        

            let headerValidateInfo = HeaderValidateInfo {
                dqpn           : dqpn,
                qkeyDETH       : deth.qkey,
                isLastPkt      : isLastPkt,
                isFirstOrMidPkt: isFirstOrMidPkt,
                isLastOrOnlyPkt: isLastOrOnlyPkt,
                pktValid       : pktValid
            };
            rdmaHeaderValidationQ.enq(tuple2(rdmaHeader, headerValidateInfo));
      
            if (!rdmaHeader.headerMetaData.isEmptyHeader) begin
                // for emptyHeader case (RawPacket), the QPN is a fake one, no need to query
                qpcReadCommonCltInst.putReq(ReadReqCommonQPC{qpn: dqpn});
            end
        end

        // Notice: this fifo should be large enough to wait qpcReadCommonCltInst's response
        payloadFragMetaValidationQ.enq(streamFragMeta);
        $display("time=%0t: 3rd stage prepareValidation", $time);
    endrule

    rule checkMetaDataQP;
        let streamFragMeta = payloadFragMetaValidationQ.first;
        payloadFragMetaValidationQ.deq;

        if (streamFragMeta.isFirst) begin
            let { rdmaHeader, headerValidateInfo } = rdmaHeaderValidationQ.first;
            rdmaHeaderValidationQ.deq;

            let bth    = extractBTH(rdmaHeader.headerData);
            let isLastPkt       = headerValidateInfo.isLastPkt;
            let isFirstOrMidPkt = headerValidateInfo.isFirstOrMidPkt;
            let isLastOrOnlyPkt = headerValidateInfo.isLastOrOnlyPkt;
            let isValidHeader = False;
            PMTU pmtu = IBV_MTU_256;
            let qpcCommonMaybe = tagged Invalid;
            if (!rdmaHeader.headerMetaData.isEmptyHeader) begin
                qpcCommonMaybe <- qpcReadCommonCltInst.getResp;
                if (qpcCommonMaybe matches tagged Valid .qpcCommon) begin
                    isValidHeader = validateHeader(
                        bth.trans,
                        headerValidateInfo.qkeyDETH,
                        qpcCommon
                    );
                    pmtu = qpcCommon.pmtu;
                end
                // $display(
                //     "time=%0t: checkMetaDataQP", $time,
                //     ", dqpn=%h", headerValidateInfo.dqpn,
                //     ", bth.dqpn=%h", bth.dqpn,
                //     ", bth.psn=%h", bth.psn,
                //     ", bth.opcode=", fshow(bth.opcode)
                // );
            end
            else begin
                isValidHeader = True;
            end

            let validHeaderInfo = ValidHeaderInfo {
                dqpn           : headerValidateInfo.dqpn,
                pmtu           : pmtu,
                isValidHeader  : isValidHeader && headerValidateInfo.pktValid,
                isLastPkt      : isLastPkt,
                isFirstOrMidPkt: isFirstOrMidPkt,
                isLastOrOnlyPkt: isLastOrOnlyPkt
            };
            rdmaHeaderFragLenCalcQ.enq(tuple3(rdmaHeader, qpcCommonMaybe, validHeaderInfo));
        end

        payloadFragMetaFragLenCalcQ.enq(streamFragMeta);
        $display("time=%0t: 4th stage checkMetaDataQP", $time);
    endrule

    rule calcFraglen;
        let streamFragMeta = payloadFragMetaFragLenCalcQ.first;
        payloadFragMetaFragLenCalcQ.deq;

        let bthPadCnt = bthPadCntReg;
        let { rdmaHeader, qpcCommonMaybe, validHeaderInfo } = rdmaHeaderFragLenCalcQ.first;

        if (streamFragMeta.isFirst) begin
            
            let bth       = extractBTH(rdmaHeader.headerData);
            bthPadCnt     = bth.padCnt;
            bthPadCntReg <= bthPadCnt;

            rdmaHeaderPktLenCalcQ.enq(tuple3(rdmaHeader, qpcCommonMaybe, validHeaderInfo));

            // $display(
            //     "time=%0t: streamFragMeta.byteEn=%h, streamFragMeta.isFirst=",
            //     $time, streamFragMeta.byteEn, fshow(streamFragMeta.isFirst),
            //     ", streamFragMeta.isLast=", streamFragMeta.isLast, ", bth.psn=%h", bth.psn,
            //     ", bth.opcode=", fshow(bth.opcode), ", bth.padCnt=%h", bth.padCnt
            // );
        end

        if (streamFragMeta.isLast) begin
            rdmaHeaderFragLenCalcQ.deq;
        end
        
        let isRawPacket = rdmaHeader.headerMetaData.isEmptyHeader;


        // TODO: should move the following commented out length calc and check logic to the very begining
        // of packet receive flow.

        // let payloadFragLen = calcFragByteNumFromByteEnLeftAlign(streamFragMeta.byteEn);
        // immAssert(
        //     isValid(payloadFragLen),
        //     "isValid(payloadFragLen) assertion @ mkInputRdmaPktBufAndHeaderValidation",
        //     $format(
        //         "payloadFragLen=", fshow(payloadFragLen), " should be valid"
        //     )
        // );

        ByteEnBitNum fragLen = zeroExtend(streamFragMeta.byteNum);
        let isByteEnNonZero = !streamFragMeta.isEmpty;
        let isByteEnAllOne  = streamFragMeta.byteNum == fromInteger(valueOf(DATA_BUS_BYTE_WIDTH));
        ByteEnBitNum fragLenWithOutPad = fragLen - zeroExtend(bthPadCnt);

        payloadPktLenCalcQ.enq(tuple5(
            streamFragMeta, fragLen, fragLenWithOutPad, isByteEnNonZero, isByteEnAllOne
        ));
        $display("time=%0t: 5th stage calcFraglen", $time, 
            ", streamFragMeta=", fshow(streamFragMeta),
            ", ");
    endrule

    rule calcPktLen;
        let {
            streamFragMeta, fragLen, fragLenWithOutPad, isByteEnNonZero, isByteEnAllOne
        } = payloadPktLenCalcQ.first;
        payloadPktLenCalcQ.deq;

        let { rdmaHeader, qpcCommonMaybe, validHeaderInfo } = rdmaHeaderPktLenCalcQ.first;

        let bth             = extractBTH(rdmaHeader.headerData);
        let pmtu            = validHeaderInfo.pmtu;

        let isLastPkt       = validHeaderInfo.isLastPkt;
        let isFirstOrMidPkt = validHeaderInfo.isFirstOrMidPkt;
        let isLastOrOnlyPkt = validHeaderInfo.isLastOrOnlyPkt;
        let isMidPkt        = isMiddleRdmaOpCode(bth.opcode);

        let pktLen = pktLenReg;
        let pktFragNum = pktFragNumReg;
        let pktValid = False;

        // PktLen fragLenExt = zeroExtend(fragLen);
        PktLen fragLenExtWithOutPad = zeroExtend(fragLenWithOutPad);
        case ({ pack(streamFragMeta.isFirst), pack(streamFragMeta.isLast) })
            2'b11: begin // streamFragMeta.isFirst && streamFragMeta.isLast
                pktLen = fragLenExtWithOutPad;
                pktFragNum = 1;
                pktValid = (isFirstOrMidPkt ? False : (isLastPkt ? isByteEnNonZero : True));
            end
            2'b10: begin // streamFragMeta.isFirst && !streamFragMeta.isLast
                pktLen = fromInteger(valueOf(DATA_BUS_BYTE_WIDTH));
                pktFragNum = 1;
                pktValid = isByteEnAllOne;
            end
            2'b01: begin // !streamFragMeta.isFirst && streamFragMeta.islast
                pktLen = pktLenAddFragLen(pktLenReg, fragLenWithOutPad);
                // pktLen = pktLenReg + fragLenExtWithOutPad;
                pktFragNum = pktFragNumReg + 1;
                pktValid = pktValidReg;
            end
            2'b00: begin // !streamFragMeta.isFirst && !streamFragMeta.islast
                pktLen = pktLenAddBusByteWidth(pktLenReg);
                // pktLen = pktLenReg + fromInteger(valueOf(DATA_BUS_BYTE_WIDTH));
                pktFragNum = pktFragNumReg + 1;
                pktValid = pktValidReg && isByteEnAllOne;
            end
        endcase

        pktLenReg     <= pktLen;
        pktValidReg   <= pktValid;
        pktFragNumReg <= pktFragNum;

        if (streamFragMeta.isLast) begin
            rdmaHeaderPktLenCalcQ.deq;

            pktValid = pktValid && validHeaderInfo.isValidHeader;
            let pktLenCheckInfo = PktLenCheckInfo {
                padCnt         : bth.padCnt,
                rdmaHeader     : rdmaHeader,
                pktFragNum     : pktFragNum,
                pktLen         : pktLen,
                pmtu           : pmtu,
                pktValid       : pktValid,
                isFirstOrMidPkt: isFirstOrMidPkt,
                isLastOrOnlyPkt: isLastOrOnlyPkt,
                isMidPkt       : isMidPkt
            };
            rdmaHeaderPktLenPreCheckQ.enq(tuple2(pktLenCheckInfo, qpcCommonMaybe));
        end
        payloadFragMetaPktLenPreCheckQ.enq(streamFragMeta);
        $display(
            "time=%0t: 6th stage calcPktLen", $time,
            ", pktLen=%0d, pktFragNum=%0d", pktLen, pktFragNum,
            ", isByteEnAllOne=", fshow(isByteEnAllOne),
            ", pktValid=", fshow(pktValid),
            ", DATA_STREAM_FRAG_BUF_SIZE=%0d", valueOf(DATA_STREAM_FRAG_BUF_SIZE),
            ", PKT_META_DATA_BUF_SIZE=%0d", valueOf(PKT_META_DATA_BUF_SIZE),
            ", streamFragMeta.byteNum=%h" , streamFragMeta.byteNum,
            ", streamFragMeta.isFirst=", fshow(streamFragMeta.isFirst),
            ", streamFragMeta.isLast=", fshow(streamFragMeta.isLast),
            ", bth.psn=%h", bth.psn,
            ", bth.opcode=", fshow(bth.opcode),
            ", bth.padCnt=%h", bth.padCnt
        );
    endrule

    rule preCheckPktLen;
        let streamFragMeta = payloadFragMetaPktLenPreCheckQ.first;
        payloadFragMetaPktLenPreCheckQ.deq;

        if (streamFragMeta.isLast) begin
            let { pktLenCheckInfo, qpcCommonMaybe } = rdmaHeaderPktLenPreCheckQ.first;
            rdmaHeaderPktLenPreCheckQ.deq;

            let pktLen = pktLenCheckInfo.pktLen;
            let pmtu   = pktLenCheckInfo.pmtu;

            let isZeroPayloadLen = isZeroR(pktLen);
            let isPktLenEqPMTU   = pktLenEqPMTU(pktLen, pmtu);
            let isPktLenGtPMTU   = pktLenGtPMTU(pktLen, pmtu);

            rdmaHeaderPktLenCheckQ.enq(tuple5(
                pktLenCheckInfo, qpcCommonMaybe, isZeroPayloadLen, isPktLenEqPMTU, isPktLenGtPMTU
            ));
        end

        payloadFragMetaPktLenCheckQ.enq(streamFragMeta);
        $display("time=%0t: 7th stage preCheckPktLen", $time);
    endrule

    rule checkPktLen;
        let streamFragMeta = payloadFragMetaPktLenCheckQ.first;
        payloadFragMetaPktLenCheckQ.deq;

        if (streamFragMeta.isLast) begin
            let { pktLenCheckInfo, qpcCommonMaybe, isZeroPayloadLen, isPktLenEqPMTU, isPktLenGtPMTU } = rdmaHeaderPktLenCheckQ.first;
            rdmaHeaderPktLenCheckQ.deq;
            let rdmaHeader      = pktLenCheckInfo.rdmaHeader;
            let pktFragNum      = pktLenCheckInfo.pktFragNum;
            let pktLen          = pktLenCheckInfo.pktLen;
            let pmtu            = pktLenCheckInfo.pmtu;
            let pktValid        = pktLenCheckInfo.pktValid;
            let isFirstOrMidPkt = pktLenCheckInfo.isFirstOrMidPkt;
            let isLastOrOnlyPkt = pktLenCheckInfo.isLastOrOnlyPkt;
            let isMidPkt        = pktLenCheckInfo.isMidPkt;
            
            let pktStatus       = PKT_ST_VALID;

            // fix byteNum to prevent dma write access touch unrelated bytes.
            streamFragMeta.byteNum = streamFragMeta.byteNum - zeroExtend(pktLenCheckInfo.padCnt);

            if (!rdmaHeader.headerMetaData.isEmptyHeader) begin
                if (pktValid) begin
                    pktValid =  (isFirstOrMidPkt && !isPktLenGtPMTU) ||
                        (isMidPkt && isPktLenEqPMTU) ||
                        (isLastOrOnlyPkt && !isPktLenGtPMTU);
                end

                if (!pktValid) begin
                    // Invalid packet length
                    pktStatus = PKT_ST_LEN_ERR;
                end
            end

            let pktMetaDataAndQpc = DataTypes::RdmaPktMetaDataAndQPC{
                metadata: RdmaPktMetaData {
                    pktPayloadLen   : pktLen,
                    pktFragNum      : (isZeroPayloadLen ? 0 : pktFragNum),
                    isZeroPayloadLen: isZeroPayloadLen,
                    pktHeader       : rdmaHeader,
                    pktValid        : pktValid,
                    pktStatus       : pktStatus
                },
                qpc: fromMaybe(?, qpcCommonMaybe)
            };

            reqPktMetaDataAndQpcOutQ.enq(pktMetaDataAndQpc);

            if (!isZeroPayloadLen) begin
                reqPayloadFragMetaOutQ.enq(streamFragMeta);
            end

            $display(
                "time=%0t: 8th stage checkPktLen", $time,
                ", bth.padCnt=%h", pktLenCheckInfo.padCnt,
                ", pktLen=%0d", pktLenCheckInfo.pktLen,
                ", pmtu=", fshow(pktLenCheckInfo.pmtu),
                ", isFirstOrMidPkt=", fshow(isFirstOrMidPkt),
                ", isPktLenEqPMTU=", fshow(isPktLenEqPMTU),
                ", isLastOrOnlyPkt=", fshow(isLastOrOnlyPkt),
                ", isPktLenGtPMTU=", fshow(isPktLenGtPMTU),
                ", pktValid=", fshow(pktValid),
                ", pktMetaDataAndQpc=", fshow(pktMetaDataAndQpc)
            );
        end
        else begin
            reqPayloadFragMetaOutQ.enq(streamFragMeta);
        end
    endrule


    return interface InputRdmaPktBuf;
        interface reqPktPipeOut = interface RdmaPktMetaDataAndQpcAndPayloadPipeOut;
            interface pktMetaData                       = toPipeOut(reqPktMetaDataAndQpcOutQ);
            interface payloadStreamFragMetaPipeOut      = toPipeOut(reqPayloadFragMetaOutQ);
        endinterface;


        interface qpcReadCommonClt = qpcReadCommonCltInst.clt;
        interface payloadStreamFragMetaPipeIn = toPut(payloadStreamFragMetaPipeInQ);
        
        interface headerDataStreamPipeIn = toPut(headerDataStreamQ);
        interface headerMetaDataPipeIn = toPut(headerMetaDataQ);
        
    endinterface;

endmodule


interface RawPacketFakeHeaderStreamInsert;
    interface PipeOut#(RqDataStreamWithExtraInfo)  streamPipeOut;
    interface Put#(RawPacketReceiveMeta) rawPacketReceiveConfigIn;
endinterface



typedef 32 FAKE_HEADER_BYTE_LENGTH_FOR_RAW_PACKET;
typedef enum {
    RawPacketFakeHeaderStreamInsertStateNormal = 0,
    RawPacketFakeHeaderStreamInsertStateExtraBeat = 1
} RawPacketFakeHeaderStreamInsertState deriving(Bits, FShow, Eq);

module mkRawPacketFakeHeaderStreamInsert#(PipeOut#(RqDataStreamWithExtraInfo) streamPipeIn)(RawPacketFakeHeaderStreamInsert);
    Reg#(RawPacketFakeHeaderStreamInsertState) stateReg <- mkReg(RawPacketFakeHeaderStreamInsertStateNormal);
    Reg#(Bool) isInsertingFakeHeaderReg                 <- mkReg(True);
    Reg#(ADDR) rawPacketWriteBaseAddrReg                <- mkRegU;
    Reg#(RKEY) rawPacketWriteMrKeyReg                   <- mkRegU;
    Reg#(RawPacketRecvBufIndex) rawPacketBufferIndexReg <- mkReg(0);

    Reg#(RqDataStreamWithExtraInfo) previousFragReg     <- mkRegU;

    FIFOF#(RqDataStreamWithExtraInfo) outQ              <- mkFIFOF;

    rule forwardNormalFragOrInsertFakeHeaderFrag if (stateReg == RawPacketFakeHeaderStreamInsertStateNormal);
        let curFrag = streamPipeIn.first;
        let {stream, isRawPacket, srcMacIpIdx} = curFrag;
        streamPipeIn.deq;
        if (!isRawPacket) begin
            outQ.enq(streamPipeIn.first);
        end 
        else begin
            let writeAddr = addrAddPsnMultiplyPMTU(rawPacketWriteBaseAddrReg, zeroExtend(pack(rawPacketBufferIndexReg)), IBV_MTU_4096);
            if (isInsertingFakeHeaderReg) begin 
                rawPacketBufferIndexReg <= rawPacketBufferIndexReg + 1;
            end
            let insertStreamFrag = genFakeHeaderSingleBeatStreamForRawPacketReceiveProcessingRightAlign(writeAddr, rawPacketWriteMrKeyReg);

            let shiftCnt = ?;
            case (valueOf(DATA_BUS_WIDTH))
                256: shiftCnt = 0;
                512: shiftCnt = 1;
                default: begin
                    $display("Not supported");
                    $finish;
                end
            endcase
            
            let streamToModify = stream;
            let prevStreamByteNum = isInsertingFakeHeaderReg ? fromInteger(valueOf(FAKE_HEADER_BYTE_LENGTH_FOR_RAW_PACKET)) : tpl_1(previousFragReg).byteNum;
            streamToModify.byteNum = prevStreamByteNum + stream.byteNum - fromInteger(valueOf(DATA_BUS_BYTE_WIDTH));
            let modifiedFrag = tuple3(streamToModify, isRawPacket, srcMacIpIdx);
            previousFragReg <= modifiedFrag;

            let prevFrag = isInsertingFakeHeaderReg ? tuple3(insertStreamFrag, isRawPacket, srcMacIpIdx) : previousFragReg;
            let prevStream = tpl_1(prevFrag);
            let tmpData = {prevStream.data, stream.data} << (shiftCnt * valueOf(FAKE_HEADER_BYTE_LENGTH_FOR_RAW_PACKET) * valueOf(BYTE_WIDTH));
            let {tmpByteNum, isByteSumOverflow} = satAddTwoByteNum(prevStream.byteNum, stream.byteNum);

            if (isByteSumOverflow) begin
                if (stream.isLast) begin
                    stateReg <= RawPacketFakeHeaderStreamInsertStateExtraBeat;
                    isInsertingFakeHeaderReg <= True; 
                end
                else begin
                    isInsertingFakeHeaderReg <= False;
                end
            end
            else begin
                isInsertingFakeHeaderReg <= True;
                immAssert(
                    stream.isLast,
                    "frag isLast assertion @ mkRawPacketFakeHeaderStreamInsert",
                    $format("should be last packet")
                );
            end

            let outStream = DataStream {
                data: truncateLSB(tmpData),
                byteNum: tmpByteNum,
                isFirst: isInsertingFakeHeaderReg,
                isLast: !isByteSumOverflow
            };
            outQ.enq(tuple3(outStream, True, srcMacIpIdx));

            $display(
                "time=%0t: ", $time, 
                ", insert rawpacket fake header, output stream = ", fshow(outStream),
                ", input stream = ", fshow(stream),
                ", prevStream = ", fshow(prevStream) 
            );

        end
    endrule

    rule forwardRawPacketFrag if (stateReg == RawPacketFakeHeaderStreamInsertStateExtraBeat);
        stateReg <= RawPacketFakeHeaderStreamInsertStateNormal;

        let shiftCnt = ?;
        case (valueOf(DATA_BUS_WIDTH))
            256: shiftCnt = 0;
            512: shiftCnt = 1;
            default: begin
                $display("Not supported");
                $finish;
            end
        endcase

        let prevStream  = tpl_1(previousFragReg);
        let srcMacIpIdx = tpl_3(previousFragReg);
        let tmpData = prevStream.data << (shiftCnt * valueOf(FAKE_HEADER_BYTE_LENGTH_FOR_RAW_PACKET) * valueOf(BYTE_WIDTH));
        let tmpByteNum = prevStream.byteNum;

        let outStream = DataStream {
            data: truncateLSB(tmpData),
            byteNum: tmpByteNum,
            isFirst: False,
            isLast: True
        };

        outQ.enq(tuple3(outStream, True, srcMacIpIdx));
        $display("time=%0t: ", $time, " insert rawpacket fake header extra beat, output stream = ", fshow(outStream));
    endrule

    interface Put rawPacketReceiveConfigIn;
        method Action put(RawPacketReceiveMeta meta);
            rawPacketWriteBaseAddrReg   <= meta.writeBaseAddr;
            rawPacketWriteMrKeyReg      <= meta.writeMrKey;
        endmethod
    endinterface

    interface streamPipeOut = toPipeOut(outQ);
endmodule