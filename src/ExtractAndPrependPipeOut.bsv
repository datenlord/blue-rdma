import FIFOF :: *;
import GetPut :: *;
import PAClib :: *;
import Vector :: *;
import ClientServer :: *;

import DataTypes :: *;
import Headers :: *;
import PrimUtils :: *;
import Settings :: *;
import RdmaUtils :: *;

interface HeaderDataStreamAndMetaDataPipeOut;
    interface DataStreamPipeOut headerDataStream;
    interface PipeOut#(HeaderMetaData) headerMetaData;
endinterface

// If header is empty, then only output headerMetaData,
// and no headerDataStream
module mkHeader2DataStream#(
    Bool clearAll,
    PipeOut#(HeaderRDMA) headerPipeIn
)(HeaderDataStreamAndMetaDataPipeOut);
    FIFOF#(DataStream)   headerDataStreamOutQ <- mkFIFOF;
    FIFOF#(HeaderMetaData) headerMetaDataOutQ <- mkFIFOF;

    Reg#(HeaderRDMA) rdmaHeaderReg <- mkRegU;
    Reg#(Bool)      headerValidReg <- mkReg(False);


    // rule debug;
    //     if (!headerDataStreamOutQ.notFull) begin
    //         $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: mkHeader2DataStream headerDataStreamOutQ");
    //     end
    //     if (!headerMetaDataOutQ.notFull) begin
    //         $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: mkHeader2DataStream headerMetaDataOutQ");
    //     end
    // endrule

    (* no_implicit_conditions, fire_when_enabled *)
    rule resetAndClear if (clearAll);
        headerDataStreamOutQ.clear;
        headerMetaDataOutQ.clear;

        headerValidReg <= False;
    endrule

    // rule debug; if (!(
    //     headerDataStreamOutQ.notFull && headerMetaDataOutQ.notFull
    // ));
    //     $display(
    //         "time=%0t: mkHeader2DataStream debug", $time,
    //         ", headerDataStreamOutQ.notFull=", fshow(headerDataStreamOutQ.notFull),
    //         ", headerMetaDataOutQ.notFull=", fshow(headerMetaDataOutQ.notFull)
    //     );
    // endrule

    rule outputHeader if (!clearAll);
        let curHeader = headerValidReg ? rdmaHeaderReg : headerPipeIn.first;
        if (!headerValidReg) begin
            headerMetaDataOutQ.enq(curHeader.headerMetaData);
        end
        let remainingHeaderLen =
            curHeader.headerMetaData.headerLen - fromInteger(valueOf(DATA_BUS_BYTE_WIDTH));
        let remainingHeaderFragNum = curHeader.headerMetaData.headerFragNum - 1;

        HeaderData leftShiftHeaderData = truncate(curHeader.headerData << valueOf(DATA_BUS_WIDTH));
        HeaderByteNum leftShiftHeaderByteNum = curHeader.headerByteNum - fromInteger(valueOf(DATA_BUS_BYTE_WIDTH));

        let nextHeaderRDMA = HeaderRDMA {
            headerData     : leftShiftHeaderData,
            headerByteNum  : leftShiftHeaderByteNum,
            headerMetaData : HeaderMetaData {
                headerLen           : remainingHeaderLen,
                headerFragNum       : remainingHeaderFragNum,
                lastFragValidByteNum: curHeader.headerMetaData.lastFragValidByteNum,
                hasPayload          : curHeader.headerMetaData.hasPayload,
                isEmptyHeader       : curHeader.headerMetaData.isEmptyHeader,
                srcMacIpIdx         : 0
            }
        };

        Bool isFirst = !headerValidReg;
        Bool isLast  = curHeader.headerMetaData.isEmptyHeader || isZero(remainingHeaderFragNum);
        headerValidReg <= !isLast;
        if (isLast) begin
            headerPipeIn.deq;
        end
        else begin
            rdmaHeaderReg <= nextHeaderRDMA;
        end

        let dataStream = DataStream {
            data    : truncateLSB(curHeader.headerData),
            byteNum : isLast ? curHeader.headerMetaData.lastFragValidByteNum : fromInteger(valueOf(DATA_BUS_BYTE_WIDTH)),
            isFirst : isFirst,
            isLast  : isLast
        };

        // if it is an empty header, also output a beat of header stream to make downstream pipeline easy without blocking.
        headerDataStreamOutQ.enq(dataStream);

        let bth = extractBTH(curHeader.headerData);
        $display(
            "time=%0t: mkHeader2DataStream outputHeader", $time,
            ", start output packet, isEmptyHeader=", fshow(curHeader.headerMetaData.isEmptyHeader),
            ", remainingHeaderFragNum=", fshow(remainingHeaderFragNum),
            ", curHeader=", fshow(curHeader),
            ", bth.dqpn=%h", bth.dqpn,
            ", bth.opcode=", fshow(bth.opcode),
            ", bth.psn=%h", bth.psn
        );
    endrule

    interface headerDataStream = toPipeOut(headerDataStreamOutQ);
    interface headerMetaData   = toPipeOut(headerMetaDataOutQ);
endmodule

// dataPipeIn must have multi-fragment data no more than HeaderByteNum
module mkDataStream2Header#(
    DataStreamPipeOut dataPipeIn, PipeOut#(HeaderMetaData) headerMetaDataPipeIn
)(PipeOut#(HeaderRDMA));
    FIFOF#(HeaderRDMA)                              headerOutQ <- mkFIFOF;
    Reg#(HeaderRDMA)                             rdmaHeaderReg <- mkRegU;
    Reg#(HeaderMetaData)                     headerMetaDataReg <- mkRegU;
    Reg#(HeaderByteNum)            headerInvalidFragByteNumReg <- mkRegU;
    Reg#(Bool)                                         busyReg <- mkReg(False);

    // rule debug if (!(
    //     dataPipeIn.notEmpty           &&
    //     headerMetaDataPipeIn.notEmpty &&
    //     headerOutQ.notFull
    // ));
    //     $display(
    //         "time=%0t: mkDataStream2Header debug", $time,
    //         ", dataPipeIn.notEmpty=", fshow(dataPipeIn.notEmpty),
    //         ", headerMetaDataPipeIn.notEmpty=", fshow(headerMetaDataPipeIn.notEmpty),
    //         ", headerOutQ.notFull=", fshow(headerOutQ.notFull)
    //     );
    // endrule

    rule popHeaderMetaData if (!busyReg);
        busyReg <= True;
        let headerMetaData = headerMetaDataPipeIn.first;
        headerMetaDataPipeIn.deq;
        headerMetaDataReg <= headerMetaData;

        immAssert(
            !isZero(headerMetaData.headerLen),
            "headerMetaData.headerLen non-zero assertion @ mkDataStream2Header",
            $format(
                "headerMetaData.headerLen=%h should not be zero",
                headerMetaData.headerLen
            )
        );

        let { headerInvalidFragByteNum, headerInvalidFragBitNum } =
            calcHeaderInvalidFragByteAndBitNum(headerMetaData.headerFragNum);
        headerInvalidFragByteNumReg <= headerInvalidFragByteNum;

        $display(
            "time=%0t: popHeaderMetaData @ mkDataStream2Header", $time,
            ", headerMetaData=", fshow(headerMetaData),
            ", headerInvalidFragByteNum=", fshow(headerInvalidFragByteNum),
            ", headerInvalidFragBitNum=", fshow(headerInvalidFragBitNum)
            );

    endrule

    rule accumulate if (busyReg);
        let curDataStreamFrag = dataPipeIn.first;
        dataPipeIn.deq;
        // $display(
        //     "time=%0t: curDataStreamFrag.data=%h, curDataStreamFrag.byteEn=%h, headerMetaDataReg=",
        //     $time, curDataStreamFrag.data, curDataStreamFrag.byteEn, fshow(headerMetaDataReg)
        // );

        let rdmaHeader = rdmaHeaderReg;
        let headerFragNum = rdmaHeaderReg.headerMetaData.headerFragNum;
        if (curDataStreamFrag.isFirst) begin
            rdmaHeader.headerData     = zeroExtend(curDataStreamFrag.data);
            rdmaHeader.headerByteNum   = zeroExtend(curDataStreamFrag.byteNum);
            rdmaHeader.headerMetaData = headerMetaDataReg;
            rdmaHeader.headerMetaData.headerFragNum = 1;
        end
        else begin
            rdmaHeader.headerData   = truncate({ rdmaHeader.headerData, curDataStreamFrag.data });
            rdmaHeader.headerByteNum = rdmaHeader.headerByteNum + zeroExtend(curDataStreamFrag.byteNum);
            rdmaHeader.headerMetaData.headerFragNum = rdmaHeaderReg.headerMetaData.headerFragNum + 1;
        end

        if (curDataStreamFrag.isLast) begin
            rdmaHeader.headerData    = rdmaHeader.headerData << getFragEnBitNumByByteEnNum(truncate(headerInvalidFragByteNumReg));
            let headerLastFragByteNum = rdmaHeader.headerMetaData.lastFragValidByteNum;
            headerOutQ.enq(rdmaHeader);
            busyReg <= False;

            // let { transType, rdmaOpCode } =
            //     extractTranTypeAndRdmaOpCode(rdmaHeader.headerData);
            // $display(
            //     "time=%0t: mkDataStream2Header", $time,
            //     ", rdmaOpCode=", fshow(rdmaOpCode),
            //     ", transType=", fshow(transType),
            //     ", rdmaHeader=", fshow(rdmaHeader)
            // );

            immAssert(
                headerLastFragByteNum == curDataStreamFrag.byteNum,
                "headerLastFragByteNum assertion @ mkDataStream2Header",
                $format(
                    "headerLastFragByteNum=%h should == curDataStreamFrag.byteNum=%h, headerLen=%0d",
                    headerLastFragByteNum, curDataStreamFrag.byteNum, rdmaHeader.headerMetaData.headerLen
                )
            );
            immAssert(
                rdmaHeader.headerMetaData.headerFragNum == headerMetaDataReg.headerFragNum,
                "headerMetaData.headerFragNum assertion @ mkDataStream2Header",
                $format(
                    "rdmaHeader.headerMetaData.headerFragNum=%h should == headerMetaDataReg.headerFragNum=%h when curDataStreamFrag.isLast=%b",
                    rdmaHeader.headerMetaData.headerFragNum, headerMetaDataReg.headerFragNum, curDataStreamFrag.isLast
                )
            );
        end
        else begin
            immAssert(
                curDataStreamFrag.byteNum == fromInteger(valueOf(DATA_BUS_BYTE_WIDTH)),
                "curDataStreamFrag.byteNum assertion @ mkDataStream2Header",
                $format("curDataStreamFrag.byteNum=%h should be all ones", curDataStreamFrag.byteNum)
            );
        end

        rdmaHeaderReg <= rdmaHeader;
    endrule

    return toPipeOut(headerOutQ);
endmodule

// TODO: maybe split this enum to send and receive?
typedef enum {
    STREAM_OUTPUT_IDLE,
    STREAM_OUTPUT_HEADER_OUTPUT,
    STREAM_OUTPUT_DATA_OUTPUT,
    STREAM_OUTPUT_HEADER_DATA_MIX_OUTPUT,
    STREAM_OUTPUT_EXTRA_LAST_FRAG_OUTPUT
} ExtractOrPrependHeaderStage deriving(Bits, Eq, FShow);

// headerPipeIn can not be empty, otherwise deadlock, i.e.:
//   * if isEmptyHeader is true, then must be a dummy beat in headerPipeIn
//   * if headerHasPayload is False, then dataPipeIn should not have beat for this packet
module mkPrependHeader2PipeOut#(
    Bool clearAll,
    DataStreamPipeOut headerPipeIn,
    PipeOut#(HeaderMetaData) headerMetaDataPipeIn,
    DataStreamPipeOut dataPipeIn,
    PipeOut#(PayloadMetaData) payloadMetaDataPipeIn
)(DataStreamPipeOut);
    FIFOF#(DataStream) dataStreamOutQ <- mkFIFOF;

    FIFOF#(Tuple5#(ByteEnBitNum, ByteEnBitNum, Bool, Bool, Bool)) calculatedMetasAfterHeaderRightShiftQ <- mkFIFOF;
    FIFOF#(DataStream) rightShiftedHeaderStreamQ <- mkFIFOF;

    // preDataStreamReg is right aligned
    Reg#(DataStream)                  preDataStreamReg <- mkRegU;
    Reg#(ExtractOrPrependHeaderStage) stageReg <- mkReg(STREAM_OUTPUT_IDLE);

    Reg#(ByteEnBitNum) headerLastFragValidByteNumReg <- mkRegU;
    Reg#(ByteEnBitNum) headerLastFragInvalidByteNumReg <- mkRegU;
    Reg#(Bool) headerHasPayloadReg <- mkRegU;
    Reg#(Bool) isEmptyHeaderReg <- mkRegU;
    Reg#(Bool) noExtraLastFragReg <- mkRegU;
    Reg#(Bool) isMixOutputHeaderOutputStageReg <- mkReg(True);

    rule debug;
        if (!dataStreamOutQ.notFull) begin
            $display("time=%0t: ", $time, "FULL_QUEUE_DETECTED: mkPrependHeader2PipeOut dataStreamOutQ");
        end
        // if (!dataPipeIn.notEmpty) begin
        //     $display("time=%0t: ", $time, "EMPTY_QUEUE_DETECTED: mkPrependHeader2PipeOut dataPipeIn");
        // end
    endrule


    // rule debug if (!dataStreamOutQ.notFull);
    //     $display(
    //         "time=%0t: mkPrependHeader2PipeOut debug", $time,
    //         ", dataStreamOutQ.notFull=", fshow(dataStreamOutQ.notFull)
    //     );
    // endrule

    (* no_implicit_conditions, fire_when_enabled *)
    rule resetAndClear if (clearAll);
        dataStreamOutQ.clear;
        stageReg <= STREAM_OUTPUT_IDLE;
        isMixOutputHeaderOutputStageReg <= True;
        // $display(
        //     "time=%0t: mkPrependHeader2PipeOut, resetAndClear", $time,
        //     ", sqpn=%h", cntrlStatus.comm.getSQPN
        // );
    endrule

    rule preCalculateHeaderMetaData if (!clearAll);
        let headerMetaData = headerMetaDataPipeIn.first;

        let headerFragNum = headerMetaData.headerFragNum;
        let headerLastFragValidByteNum = headerMetaData.lastFragValidByteNum;
        let headerLastFragInvalidByteNum = calcFragInvalidByteNum(headerLastFragValidByteNum);

        $display("time=%0t: mkPrependHeader2PipeOut preCalculateHeaderMetaData", $time,
                    ", headerLastFragValidByteNum=", fshow(headerLastFragValidByteNum),
                    ", headerLastFragInvalidByteNum=", fshow(headerLastFragInvalidByteNum));

        if (headerMetaData.isEmptyHeader) begin
            immAssert(
                isZero(headerLastFragValidByteNum),
                "empty header assertion @ mkPrependHeader2PipeOut",
                $format(
                    " headerLastFragValidByteNum=%0d", headerLastFragValidByteNum,
                    " should be zero when isEmptyHeader=",
                    fshow(headerMetaData.isEmptyHeader)
                )
            );
        end
        else begin
            immAssert(
                !isZero(headerMetaData.headerLen),
                "headerMetaData.headerLen non-zero assertion @ mkPrependHeader2PipeOut",
                $format(
                    "headerLen=%0d", headerMetaData.headerLen,
                    " should not be zero when isEmptyHeader=",
                    fshow(headerMetaData.isEmptyHeader)
                )
            );
        end

        let isEmptyHeader       = headerMetaData.isEmptyHeader;
        let headerHasPayload    = headerMetaData.hasPayload;
        
        let curHeaderDataStreamFrag = headerPipeIn.first;
        headerPipeIn.deq;

        let rightShiftHeaderLastFragData = curHeaderDataStreamFrag.data >> getFragEnBitNumByByteEnNum(zeroExtend(headerLastFragInvalidByteNum));
        let outputDataStream = curHeaderDataStreamFrag;

        let noExtraLastFrag = False;
        if (headerHasPayload) begin
            let dataMeta = payloadMetaDataPipeIn.first;
            payloadMetaDataPipeIn.deq;

            $display("time=%0t: mkPrependHeader2PipeOut preCalculateHeaderMetaData", $time,
                ", headerLastFragInvalidByteNum=", fshow(headerLastFragInvalidByteNum),
                ", dataMeta.lastFragValidByteNum=", fshow(dataMeta.lastFragValidByteNum)
                );

            let {tmpByteNum, isByteSumOverflow} = satAddTwoByteNum(headerLastFragValidByteNum, dataMeta.lastFragValidByteNum);

            if (!isByteSumOverflow) begin
                noExtraLastFrag = True;
            end
        end

        // For the first beat, pass the metadata to downstream.
        if (curHeaderDataStreamFrag.isFirst) begin
            calculatedMetasAfterHeaderRightShiftQ.enq(tuple5(headerLastFragValidByteNum,
                headerLastFragInvalidByteNum, headerHasPayload, isEmptyHeader, noExtraLastFrag));
            $display("time=%0t: mkPrependHeader2PipeOut preCalculateHeaderMetaData pass header at first beat", $time);
        end
        if (curHeaderDataStreamFrag.isLast) begin
            headerMetaDataPipeIn.deq;
            $display("time=%0t: mkPrependHeader2PipeOut preCalculateHeaderMetaData handle last beat", $time,
                ", non-shifted stream=", fshow(outputDataStream));
            if (headerHasPayload) begin
                outputDataStream.data = rightShiftHeaderLastFragData;
            end   
        end

        rightShiftedHeaderStreamQ.enq(outputDataStream);
        $display("time=%0t: mkPrependHeader2PipeOut preCalculateHeaderMetaData", $time,
                ", enqueue header to rightShiftedHeaderStreamQ, data=", fshow(outputDataStream));
        
    endrule

    function Action dispatchNextRule();
        action
            let nextState = ?;
            if (calculatedMetasAfterHeaderRightShiftQ.notEmpty) begin
                let {headerLastFragValidByteNum,
                    headerLastFragInvalidByteNum, headerHasPayload, isEmptyHeader, noExtraLastFrag} = calculatedMetasAfterHeaderRightShiftQ.first;
                calculatedMetasAfterHeaderRightShiftQ.deq;

                headerLastFragValidByteNumReg <= headerLastFragValidByteNum;
                headerLastFragInvalidByteNumReg <= headerLastFragInvalidByteNum;
                headerHasPayloadReg <= headerHasPayload;
                isEmptyHeaderReg <= isEmptyHeader;
                noExtraLastFragReg <= noExtraLastFrag;
                case ({pack(headerHasPayload), pack(isEmptyHeader)}) matches
                    'b00: begin
                        nextState = STREAM_OUTPUT_HEADER_OUTPUT;
                    end
                    'b01: begin
                        immAssert(False, "header and payload both empty @ mkPrependHeader2PipeOut",$format(""));
                    end
                    'b10: begin
                        nextState = STREAM_OUTPUT_HEADER_DATA_MIX_OUTPUT;
                    end
                    'b11: begin
                        nextState = STREAM_OUTPUT_DATA_OUTPUT;
                    end
                endcase
            end
            else begin
                nextState = STREAM_OUTPUT_IDLE;
            end

            stageReg <= nextState;
            if (stageReg != nextState) begin
                $display("time=%0t: mkPrependHeader2PipeOut dispatchNextRule", $time,
                        ", nextState=", fshow(nextState),
                        ", curState=", fshow(stageReg)
                );
            end
        endaction
    endfunction


    rule dispatchHandleRuleByMeta if (!clearAll && stageReg == STREAM_OUTPUT_IDLE);
        dispatchNextRule;
    endrule


    rule outputHeader if (!clearAll && stageReg == STREAM_OUTPUT_HEADER_OUTPUT);
        let headerFrag = rightShiftedHeaderStreamQ.first;
        rightShiftedHeaderStreamQ.deq;
        dataStreamOutQ.enq(headerFrag);
        if (headerFrag.isLast) begin
            dispatchNextRule;
        end

        $display("time=%0t: mkPrependHeader2PipeOut outputHeader", $time,
                     ", output stream=", fshow(headerFrag));
    endrule


    rule outputData if (!clearAll && stageReg == STREAM_OUTPUT_DATA_OUTPUT);
        let dataFrag = dataPipeIn.first;
        dataPipeIn.deq;
        dataStreamOutQ.enq(dataFrag);
        if (dataFrag.isLast) begin
            dispatchNextRule;
            rightShiftedHeaderStreamQ.deq; // deq fake header frag
        end
        $display("time=%0t: mkPrependHeader2PipeOut outputData", $time,
                     ", output stream=", fshow(dataFrag));
    endrule


    rule outputMixed if (!clearAll && stageReg == STREAM_OUTPUT_HEADER_DATA_MIX_OUTPUT);

        let firstDataStreamFrag = dataPipeIn.first;
        
        preDataStreamReg <= firstDataStreamFrag;
        let fragToOutput = ?;

        $display("time=%0t: mkPrependHeader2PipeOut outputMixed", $time,
            ", noExtraLastFragReg=", fshow(noExtraLastFragReg),
            ", isMixOutputHeaderOutputStageReg=", fshow(isMixOutputHeaderOutputStageReg)
        );

        if (isMixOutputHeaderOutputStageReg) begin
            let headerFrag = rightShiftedHeaderStreamQ.first;
            rightShiftedHeaderStreamQ.deq;
            if (headerFrag.isLast) begin
                if (!noExtraLastFragReg) begin
                    if (firstDataStreamFrag.isLast) begin
                        stageReg <= STREAM_OUTPUT_EXTRA_LAST_FRAG_OUTPUT;
                    end
                    else begin
                        isMixOutputHeaderOutputStageReg <= False;
                    end
                end
                else begin
                    dispatchNextRule;
                    $display("time=%0t: mkPrependHeader2PipeOut outputMixed 4444444444444444444", $time);
                end

                $display("time=%0t: mkPrependHeader2PipeOut outputMixed", $time,
                     ", headerFrag.data=", fshow(headerFrag.data),
                     ", firstDataStreamFrag.data=", fshow(firstDataStreamFrag.data),
                     ", headerFrag.byteNum=", fshow(headerFrag.byteNum),
                     ", firstDataStreamFrag.byteNum=", fshow(firstDataStreamFrag.byteNum),
                     ", headerLastFragValidByteNumReg=", fshow(headerLastFragValidByteNumReg)
                     );

                let tmpData = { headerFrag.data, firstDataStreamFrag.data } >> getFragEnBitNumByByteEnNum(zeroExtend(headerLastFragValidByteNumReg));
                let {tmpByteNum, isByteSumOverflow} = satAddTwoByteNum(headerLastFragValidByteNumReg, firstDataStreamFrag.byteNum);

                fragToOutput = DataStream {
                    data: truncate(tmpData),
                    byteNum: tmpByteNum,
                    isFirst: headerFrag.isFirst,
                    isLast: noExtraLastFragReg
                };
                dataPipeIn.deq;
            end
            else begin
                fragToOutput = headerFrag;
            end
        end
        else begin

            let tmpData = { preDataStreamReg.data, firstDataStreamFrag.data } >> getFragEnBitNumByByteEnNum(zeroExtend(headerLastFragValidByteNumReg));
            let {tmpByteNum, isByteSumOverflow} = satAddTwoByteNum(firstDataStreamFrag.byteNum, headerLastFragValidByteNumReg);

            fragToOutput = DataStream {
                data: truncate(tmpData),
                byteNum: tmpByteNum,
                isFirst: False,
                isLast: False
            };
            dataPipeIn.deq;

            if (firstDataStreamFrag.isLast) begin
                isMixOutputHeaderOutputStageReg <= True;
                fragToOutput.isLast = noExtraLastFragReg;
                if (noExtraLastFragReg) begin
                    dispatchNextRule;
                end
                else begin
                    stageReg <= STREAM_OUTPUT_EXTRA_LAST_FRAG_OUTPUT;
                end
            end
        end

        dataStreamOutQ.enq(fragToOutput);
        $display("time=%0t: mkPrependHeader2PipeOut outputMixed", $time,
                 ", isMixOutputHeaderOutputStageReg=", fshow(isMixOutputHeaderOutputStageReg),
                 ", noExtraLastFragReg=", fshow(noExtraLastFragReg),
                 ", output stream=", fshow(fragToOutput));
    endrule

    rule extraLastFrag if (!clearAll && stageReg == STREAM_OUTPUT_EXTRA_LAST_FRAG_OUTPUT);
        
        DATA leftShiftData = preDataStreamReg.data << getFragEnBitNumByByteEnNum(zeroExtend(headerLastFragInvalidByteNumReg));
        let leftShiftByteNum = preDataStreamReg.byteNum - headerLastFragInvalidByteNumReg;
        let extraLastDataStream = DataStream {
            data   : leftShiftData,
            byteNum : leftShiftByteNum,
            isFirst: False,
            isLast : True
        };
        dataStreamOutQ.enq(extraLastDataStream);
        dispatchNextRule;
        $display("time=%0t: mkPrependHeader2PipeOut extraLastFrag", $time,
                    ", preDataStreamReg.byteNum=", fshow(preDataStreamReg.byteNum),
                    ", headerLastFragInvalidByteNumReg=", fshow(headerLastFragInvalidByteNumReg),
                    ", output stream=", fshow(extraLastDataStream));
        
    endrule


    return toPipeOut(dataStreamOutQ);
endmodule

interface HeaderAndPayloadSeperateDataStreamPipeOut;
    interface DataStreamPipeOut header;
    interface DataStreamFragMetaPipeOut payloadStreamFragMetaPipeOut;
    interface Put#(InputStreamFragBufferIdx) payloadStreamFragStorageIdxIn;
    interface Get#(Tuple2#(InputStreamFragBufferIdx, DATA)) payloadStreamFragStorageDataOut;
endinterface

// Neither dataPipeIn nor headerMetaDataPipeIn can be empty, headerLen cannot be zero
// dataPipeIn could have data less than requested length from headerMetaDataPipeIn.
module mkExtractHeaderFromDataStreamPipeOut#(
    DataStreamPipeOut dataPipeIn, PipeOut#(HeaderMetaData) headerMetaDataPipeIn
)(HeaderAndPayloadSeperateDataStreamPipeOut);

    FIFOF#(InputStreamFragBufferIdx) payloadStreamFragStorageIdxInQ <- mkFIFOF;
    FIFOF#(Tuple2#(InputStreamFragBufferIdx, DATA)) payloadStreamFragStorageDataOutQ <- mkFIFOF;

    
    FIFOF#(DataStream) headerDataStreamOutQ                     <- mkFIFOF;
    FIFOF#(DataStreamFragMetaData) payloadDataStreamFragOutQ    <- mkFIFOF;

    FIFOF#(Tuple3#(ByteEnBitNum, ByteEnBitNum, HeaderMetaData)) calculatedMetasQ <- mkFIFOF;

    Reg#(DataStream)                  preDataStreamReg <- mkRegU;
    Reg#(DataStream)                  curDataStreamReg <- mkRegU;
    Reg#(Bool)                      isFirstDataFragReg <- mkRegU;
    Reg#(HeaderFragNum)           headerFragCounterReg <- mkRegU;

    Reg#(ExtractOrPrependHeaderStage) stageReg <- mkReg(STREAM_OUTPUT_HEADER_OUTPUT);
/*
    rule debug if (!(
        headerDataStreamOutQ.notFull && payloadDataStreamFragPreOutQ.notFull
    ));
        $display(
            "time=%0t: mkExtractHeaderFromDataStreamPipeOut debug", $time,
            ", headerDataStreamOutQ.notFull=", fshow(headerDataStreamOutQ.notFull),
            ", payloadDataStreamFragPreOutQ.notFull=", fshow(payloadDataStreamFragPreOutQ.notFull)
        );
    endrule
*/
    rule preCalculateHeaderMetaData;
        let headerMetaData = headerMetaDataPipeIn.first;
        headerMetaDataPipeIn.deq;
        immAssert(
            !isZero(headerMetaData.headerLen),
            "headerMetaData.headerLen non-zero assertion @ mkExtractHeaderFromDataStreamPipeOut",
            $format(
                "headerMetaData.headerLen=%h should not be zero, headerMetaData=",
                headerMetaData.headerLen, fshow(headerMetaData)
            )
        );

        let headerFragNum = headerMetaData.headerFragNum;
        let headerLastFragValidByteNum = headerMetaData.lastFragValidByteNum;
        let headerLastFragInvalidByteNum = calcFragInvalidByteNum(headerLastFragValidByteNum);


        calculatedMetasQ.enq(tuple3(
            headerLastFragValidByteNum, headerLastFragInvalidByteNum, headerMetaData));

        $display(
            "time=%0t: preCalculateHeaderMetaData @ mkExtractHeaderFromDataStreamPipeOut", $time,
            ", headerMetaData=", fshow(headerMetaData),
            ", headerLastFragValidByteNum=%0d", headerLastFragValidByteNum,
            ", headerLastFragInvalidByteNum=%0d", headerLastFragInvalidByteNum,
            ", stageReg=", fshow(stageReg)
        );
    endrule

    
    
    // this rule is a big one since it has to handle some different case to achieve fully-pipeline
    // Note: we don't need to care isEmptyHeader, since there is a module already inserted a fake stream beta into the 
    //       original input data stream, which makes the rawPacket stream looks like a WriteOnlyWithImmediate packet.
    //       so we can handle it as a normal packet.
    // 1. if header is not last beat, then simply output Header, and decrease header counter
    // 2. if header is last beat, and no Data, then output Header with right byteEn, output a fake Data beat with
    //    byteEn=0, and move to handle next packet.
    // 3. if header is last beat, and Data also is last beat, then output Header with right byteEn,
    //    and output data as well. then move on to handle next packet.
    // 4. if header is last beat, but Data has extra beat, then only output Header and jump to STREAM_OUTPUT_DATA_OUTPUT
    rule outputHeader if (stageReg == STREAM_OUTPUT_HEADER_OUTPUT);

        let {headerLastFragValidByteNum, headerLastFragInvalidByteNum, headerMetaData} = calculatedMetasQ.first;

        let inDataStreamFrag = dataPipeIn.first;
        dataPipeIn.deq;

        let curHeaderFragCounter = headerFragCounterReg;
        if (inDataStreamFrag.isFirst) begin
            headerFragCounterReg <= headerMetaData.headerFragNum-1;
            curHeaderFragCounter = headerMetaData.headerFragNum;
        end
        else begin
            headerFragCounterReg <= curHeaderFragCounter - 1;
        end

        let byteEnAdjustedFragForLastHeader = inDataStreamFrag;
        byteEnAdjustedFragForLastHeader.byteNum = headerLastFragValidByteNum;
        byteEnAdjustedFragForLastHeader.isLast = True;

        // This is a tricky one. Since the Header at most will be 2, so the LSB can be used to distinguish 1 or 2.
        // The logic level here is high enough, if we compare the two bits, EDA tool will give warning.
        // But this rule is hard to split into two rules.
        let isHeaderLastBeat = curHeaderFragCounter[0] == 1;

        let leftShiftedPayloadData = inDataStreamFrag.data << getFragEnBitNumByByteEnNum(zeroExtend(headerLastFragValidByteNum));
        let leftShiftedPayloadByteNum = inDataStreamFrag.byteNum - headerLastFragValidByteNum;

        if (!isHeaderLastBeat) begin // case 1
            immAssert(
                !inDataStreamFrag.isLast,
                "last header beat assertion @ mkExtractHeaderFromDataStreamPipeOut",
                $format("should not be last beat", fshow(inDataStreamFrag))
            );
            headerDataStreamOutQ.enq(inDataStreamFrag);

            $display(
                "time=%0t:", $time,
                " outputHeader case 1",
                ", inDataStreamFrag=", fshow(inDataStreamFrag)
            );
        end
        else begin  // isHeaderLastBeat=True, include case 2,3,4

            // both case 2,3,4 need output header with adjusted byteEN.
            headerDataStreamOutQ.enq(byteEnAdjustedFragForLastHeader);
            $display(
                "time=%0t:", $time,
                " outputHeader case 2,3,4",
                ", byteEnAdjustedFragForLastHeader=", fshow(byteEnAdjustedFragForLastHeader),
                ", inDataStreamFrag=", fshow(inDataStreamFrag)
            );

            if (!headerMetaData.hasPayload) begin  // case 2
                immAssert(
                    inDataStreamFrag.isLast,
                    "last header beat assertion @ mkExtractHeaderFromDataStreamPipeOut",
                    $format("should be last beat", fshow(inDataStreamFrag))
                );

                // inject zero-sized payload stream, to make following pipeline not deadlock.
                let outDataStreamFragMeta = DataStreamFragMetaData {
                    bufIdx : ?,
                    byteNum : 0,
                    isFirst: True,
                    isLast : True,
                    isEmpty: True
                };
                payloadDataStreamFragOutQ.enq(outDataStreamFragMeta);
                

                calculatedMetasQ.deq;  // move on to next packet

                $display(
                    "time=%0t:", $time,
                    " outputHeader case 2",
                    ", outDataStreamFragMeta=", fshow(outDataStreamFragMeta)
                );

            end
            else if (inDataStreamFrag.isLast) begin // case 3, has payload, but all payload is included in this beat
                immAssert(
                    !isZeroR(leftShiftedPayloadByteNum),
                    "last header beat assertion @ mkExtractHeaderFromDataStreamPipeOut",
                    $format("should be last beat", fshow(inDataStreamFrag))
                );

                payloadStreamFragStorageIdxInQ.deq;
                let bufIdx = payloadStreamFragStorageIdxInQ.first;
                let outDataStreamFragMeta = DataStreamFragMetaData {
                    bufIdx : bufIdx,
                    byteNum : leftShiftedPayloadByteNum,
                    isFirst: True,
                    isLast : True,
                    isEmpty: False
                };
                payloadDataStreamFragOutQ.enq(outDataStreamFragMeta);
                payloadStreamFragStorageDataOutQ.enq(tuple2(bufIdx, leftShiftedPayloadData));

                calculatedMetasQ.deq;  // move on to next packet

                $display(
                    "time=%0t:", $time,
                    " outputHeader case 3",
                    ", outDataStreamFragMeta=", fshow(outDataStreamFragMeta)
                );
            end
            else begin
                stageReg <= STREAM_OUTPUT_DATA_OUTPUT;
                preDataStreamReg <= inDataStreamFrag;
                isFirstDataFragReg <= True;
                $display(
                    "time=%0t:", $time,
                    " outputHeader case 4"
                );
            end
        end
    endrule

    rule outputData if (stageReg == STREAM_OUTPUT_DATA_OUTPUT);

        let {headerLastFragValidByteNum, headerLastFragInvalidByteNum, headerMetaData} = calculatedMetasQ.first;

        let curDataStreamFrag = dataPipeIn.first;
        dataPipeIn.deq;
        preDataStreamReg   <= curDataStreamFrag;

        isFirstDataFragReg <= False;
        
        let outData   = { preDataStreamReg.data, curDataStreamFrag.data } >> getFragEnBitNumByByteEnNum(zeroExtend(headerLastFragInvalidByteNum));
        let {outByteNum, isByteSumOverflow} = satAddTwoByteNum(curDataStreamFrag.byteNum, headerLastFragInvalidByteNum);
        let noExtraLastFrag = !isByteSumOverflow;

        let isLast = curDataStreamFrag.isLast && noExtraLastFrag;

        payloadStreamFragStorageIdxInQ.deq;
        let bufIdx = payloadStreamFragStorageIdxInQ.first;
        let outDataStream = DataStreamFragMetaData {
            bufIdx : bufIdx,
            byteNum : outByteNum,
            isFirst: isFirstDataFragReg,
            isLast : isLast,
            isEmpty: False
        };
        $display(
            "time=%0t:", $time,
            " extract headerLastFragValidByteNum=%0d", headerLastFragValidByteNum,
            ", headerLastFragInvalidByteNum=%0d", headerLastFragInvalidByteNum,
            ", noExtraLastFrag=", fshow(noExtraLastFrag),
            ", preDataStreamReg=", fshow(preDataStreamReg),
            ", curDataStreamFrag=", fshow(curDataStreamFrag),
            ", outDataStream=", fshow(outDataStream),
            ", stageReg=", fshow(stageReg)
        );
        
        payloadDataStreamFragOutQ.enq(outDataStream);
        payloadStreamFragStorageDataOutQ.enq(tuple2(bufIdx, truncate(outData)));

        if (curDataStreamFrag.isLast) begin
            if (noExtraLastFrag) begin
                stageReg <= STREAM_OUTPUT_HEADER_OUTPUT;
                calculatedMetasQ.deq;  // move on to next packet
            end
            else begin
                stageReg <= STREAM_OUTPUT_EXTRA_LAST_FRAG_OUTPUT;
            end
        end
    endrule

    rule extraLastFrag if (stageReg == STREAM_OUTPUT_EXTRA_LAST_FRAG_OUTPUT);
        let {headerLastFragValidByteNum, headerLastFragInvalidByteNum, headerMetaData} = calculatedMetasQ.first;

        DATA leftShiftData      = truncate(preDataStreamReg.data << getFragEnBitNumByByteEnNum(zeroExtend(headerLastFragValidByteNum)));
        let leftShiftByteNum    = preDataStreamReg.byteNum - headerLastFragInvalidByteNum;

        payloadStreamFragStorageIdxInQ.deq;
        let bufIdx = payloadStreamFragStorageIdxInQ.first;
        let extraLastDataStream = DataStreamFragMetaData {
            bufIdx : bufIdx,
            byteNum: leftShiftByteNum,
            isFirst: False,
            isLast: True,
            isEmpty: False
        };

        $display("time=%0t: extraLastDataStream=", $time, fshow(extraLastDataStream));

        payloadDataStreamFragOutQ.enq(extraLastDataStream);
        payloadStreamFragStorageDataOutQ.enq(tuple2(bufIdx, leftShiftData));

        stageReg <= STREAM_OUTPUT_HEADER_OUTPUT;
        calculatedMetasQ.deq;  // move on to next packet
    endrule

    interface header = toPipeOut(headerDataStreamOutQ);
    interface payloadStreamFragMetaPipeOut = toPipeOut(payloadDataStreamFragOutQ);
    
    interface payloadStreamFragStorageIdxIn   = toPut(payloadStreamFragStorageIdxInQ);
    interface payloadStreamFragStorageDataOut = toGet(payloadStreamFragStorageDataOutQ);
endmodule

