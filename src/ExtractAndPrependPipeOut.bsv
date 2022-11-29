import FIFOF :: *;
import PAClib :: *;
import Vector :: *;

import Assertions :: *;
import DataTypes :: *;
import Headers :: *;
import Settings :: *;
import Utils :: *;

interface HeaderDataStreamAndMetaDataPipeOut;
    interface DataStreamPipeOut headerDataStream;
    interface PipeOut#(HeaderMetaData) headerMetaData;
endinterface

module mkHeader2DataStream#(
    PipeOut#(RdmaHeader) headerPipeIn
)(HeaderDataStreamAndMetaDataPipeOut);
    FIFOF#(DataStream) headerDataStreamOutQ <- mkFIFOF;
    FIFOF#(HeaderMetaData) headerMetaDataOutQ <- mkFIFOF;
    Reg#(RdmaHeader) rdmaHeaderReg <- mkRegU;
    Reg#(Bool) headerValidReg <- mkReg(False);

    rule outputHeader;
        let curHeader = headerValidReg ? rdmaHeaderReg : headerPipeIn.first;
        if (!headerValidReg) begin
            headerMetaDataOutQ.enq(curHeader.headerMetaData);
        end
        let remainingHeaderLen =
            curHeader.headerMetaData.headerLen - fromInteger(valueOf(DATA_BUS_BYTE_WIDTH));
        let remainingHeaderFragNum = curHeader.headerMetaData.headerFragNum - 1;

        HeaderData leftShiftHeaderData = truncate(curHeader.headerData << valueOf(DATA_BUS_WIDTH));
        HeaderByteEn leftShiftHeaderByteEn =
            truncate(curHeader.headerByteEn << valueOf(DATA_BUS_BYTE_WIDTH));

        Bool isFirst = !headerValidReg;
        Bool isLast = False;
        if (isZero(remainingHeaderFragNum)) begin
            headerPipeIn.deq;
            headerValidReg <= False;
            isLast = True;
        end
        else begin
            headerValidReg <= True;

            rdmaHeaderReg <= RdmaHeader {
                headerData: leftShiftHeaderData,
                headerByteEn: leftShiftHeaderByteEn,
                headerMetaData: HeaderMetaData {
                    headerLen: remainingHeaderLen,
                    headerFragNum: remainingHeaderFragNum,
                    lastFragValidByteNum: curHeader.headerMetaData.lastFragValidByteNum,
                    hasPayload: curHeader.headerMetaData.hasPayload
                }
            };
        end

        let dataStream = DataStream {
            data: truncateLSB(curHeader.headerData),
            byteEn: truncateLSB(curHeader.headerByteEn),
            isFirst: isFirst,
            isLast: isLast
        };
        // $display(
        //     "time=%0d: dataStream.data=%h, dataStream.byteEn=%h, leftShiftHeaderData=%h, leftShiftHeaderByteEn=%h",
        //     $time, dataStream.data, dataStream.byteEn, leftShiftHeaderData, leftShiftHeaderByteEn
        // );
        headerDataStreamOutQ.enq(dataStream);
    endrule

    interface headerDataStream = convertFifo2PipeOut(headerDataStreamOutQ);
    interface headerMetaData = convertFifo2PipeOut(headerMetaDataOutQ);
endmodule

// dataPipeIn must have multi-fragment data no more than HeaderByteNum
module mkDataStream2Header#(
    DataStreamPipeOut dataPipeIn, PipeOut#(HeaderMetaData) headerMetaDataPipeIn
)(PipeOut#(RdmaHeader));
    FIFOF#(RdmaHeader) headerOutQ <- mkFIFOF;
    Reg#(RdmaHeader) rdmaHeaderReg <- mkRegU;
    Reg#(HeaderMetaData) headerMetaDataReg <- mkRegU;
    Reg#(HeaderByteNum) headerInvalidFragByteNumReg <- mkRegU;
    Reg#(HeaderBitNum) headerInvalidFragBitNumReg <- mkRegU;
    Reg#(Bool) busyReg <- mkReg(False);

    rule headerMetaDataPop if (!busyReg);
        busyReg <= True;
        let headerMetaData = headerMetaDataPipeIn.first;
        headerMetaDataPipeIn.deq;
        headerMetaDataReg <= headerMetaData;
        // $display("time=%0d: headerMetaData=", $time, fshow(headerMetaData));

        dynAssert(
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
        headerInvalidFragBitNumReg <= headerInvalidFragBitNum;
    endrule

    rule cumulate if (busyReg);
        let curDataStreamFrag = dataPipeIn.first;
        dataPipeIn.deq;
        // $display(
        //     "time=%0d: curDataStreamFrag.data=%h, curDataStreamFrag.byteEn=%h, headerMetaDataReg=",
        //     $time, curDataStreamFrag.data, curDataStreamFrag.byteEn, fshow(headerMetaDataReg)
        // );

        let rdmaHeader = rdmaHeaderReg;
        let headerFragNum = rdmaHeaderReg.headerMetaData.headerFragNum;
        if (curDataStreamFrag.isFirst) begin
            rdmaHeader.headerData = zeroExtend(curDataStreamFrag.data);
            rdmaHeader.headerByteEn = zeroExtend(curDataStreamFrag.byteEn);
            rdmaHeader.headerMetaData = headerMetaDataReg;
            rdmaHeader.headerMetaData.headerFragNum = 1;
        end
        else begin
            rdmaHeader.headerData = truncate({ rdmaHeader.headerData, curDataStreamFrag.data });
            rdmaHeader.headerByteEn = truncate({ rdmaHeader.headerByteEn, curDataStreamFrag.byteEn });
            rdmaHeader.headerMetaData.headerFragNum = rdmaHeaderReg.headerMetaData.headerFragNum + 1;
        end

        if (curDataStreamFrag.isLast) begin
            rdmaHeader.headerData = rdmaHeader.headerData << headerInvalidFragBitNumReg;
            rdmaHeader.headerByteEn = rdmaHeader.headerByteEn << headerInvalidFragByteNumReg;
            ByteEn headerLastFragByteEn = genByteEn(rdmaHeader.headerMetaData.lastFragValidByteNum);
            headerOutQ.enq(rdmaHeader);
            busyReg <= False;
            // $display("time=%0d: rdmaHeader=", $time, fshow(rdmaHeader));

            dynAssert(
                headerLastFragByteEn == curDataStreamFrag.byteEn,
                "headerLastFragByteEn assertion @ mkDataStream2Header",
                $format(
                    "headerLastFragByteEn=%h should == curDataStreamFrag.byteEn=%h, headerLen=%0d",
                    headerLastFragByteEn, curDataStreamFrag.byteEn, rdmaHeader.headerMetaData.headerLen
                )
            );
            dynAssert(
                rdmaHeader.headerMetaData.headerFragNum == headerMetaDataReg.headerFragNum,
                "headerMetaData.headerFragNum assertion @ mkDataStream2Header",
                $format(
                    "rdmaHeader.headerMetaData.headerFragNum=%h should == headerMetaDataReg.headerFragNum=%h when curDataStreamFrag.isLast=%b",
                    rdmaHeader.headerMetaData.headerFragNum, headerMetaDataReg.headerFragNum, curDataStreamFrag.isLast
                )
            );
        end
        else begin
            dynAssert(
                isAllOnes(curDataStreamFrag.byteEn),
                "curDataStreamFrag.byteEn assertion @ mkDataStream2Header",
                $format("curDataStreamFrag.byteEn=%h should be all ones", curDataStreamFrag.byteEn)
            );
        end

        rdmaHeaderReg <= rdmaHeader;
    endrule

    return convertFifo2PipeOut(headerOutQ);
endmodule

typedef enum {
    HeaderMetaDataPop,
    HeaderOut,
    DataOut,
    ExtraLastFrag
} PrependHeader2PipeOutStage deriving(Bits, Eq);

// Neither headerPipeIn nor dataPipeIn can be empty, otherwise deadlock.
// headerLen cannot be zero, but dataPipeIn can have empty DataStream.
// If header has no payload, then it will not dequeue dataPipeIn.
module mkPrependHeader2PipeOut#(
    DataStreamPipeOut headerPipeIn,
    PipeOut#(HeaderMetaData) headerMetaDataPipeIn,
    DataStreamPipeOut dataPipeIn
)(DataStreamPipeOut);
    FIFOF#(DataStream) dataStreamOutQ <- mkFIFOF;

    // preDataStreamReg is right aligned
    Reg#(DataStream) preDataStreamReg <- mkRegU;
    Reg#(HeaderFragNum) headerFragCntReg <- mkRegU;
    Reg#(BusBitNum) headerLastFragInvalidBitNumReg <- mkRegU;
    Reg#(ByteEnBitNum) headerLastFragInvalidByteNumReg <- mkRegU;
    Reg#(BusBitNum) headerLastFragValidBitNumReg <- mkRegU;
    Reg#(ByteEnBitNum) headerLastFragValidByteNumReg <- mkRegU;
    Reg#(Bool) headerHasPayloadReg <- mkRegU;
    Reg#(Bool) isFirstReg <- mkRegU;

    Reg#(PrependHeader2PipeOutStage) stageReg <- mkReg(HeaderMetaDataPop);

    rule popHeaderMetaData if (stageReg == HeaderMetaDataPop);
        let headerMetaData = headerMetaDataPipeIn.first;
        headerMetaDataPipeIn.deq;
        // $display("time=%0d: headerMetaData", $time, fshow(headerMetaData));
        dynAssert(
            !isZero(headerMetaData.headerLen),
            "headerMetaData.headerLen non-zero assertion @ mkPrependHeader2PipeOut",
            $format(
                "headerMetaData.headerLen=%h should not be zero",
                headerMetaData.headerLen
            )
        );

        let headerFragNum = headerMetaData.headerFragNum;
        let headerLastFragValidByteNum = headerMetaData.lastFragValidByteNum;
        let { headerLastFragValidBitNum, headerLastFragInvalidByteNum, headerLastFragInvalidBitNum } =
            calcFragBitNumAndByteNum(headerLastFragValidByteNum);

        headerLastFragValidByteNumReg <= headerLastFragValidByteNum;
        headerLastFragValidBitNumReg <= headerLastFragValidBitNum;
        headerLastFragInvalidByteNumReg <= headerLastFragInvalidByteNum;
        headerLastFragInvalidBitNumReg <= headerLastFragInvalidBitNum;

        headerFragCntReg <= headerFragNum - 1;
        headerHasPayloadReg <= headerMetaData.hasPayload;
        isFirstReg <= True;
        stageReg <= HeaderOut;
    endrule

    rule outputHeader if (stageReg == HeaderOut);
        let curHeaderDataStreamFrag = headerPipeIn.first;
        headerPipeIn.deq;
        // $display("time=%0d", $time, ": headerDataStream=", fshow(curHeaderDataStreamFrag));

        // One cycle delay when output the last fragment of header
        if (curHeaderDataStreamFrag.isLast) begin
            dynAssert(
                isZero(headerFragCntReg),
                "headerFragCntReg zero assertion @ mkPrependHeader2PipeOut",
                $format(
                    "headerFragCntReg=%h should be zero when curHeaderDataStreamFrag.isLast=%b",
                    headerFragCntReg, curHeaderDataStreamFrag.isLast
                )
            );

            let rightShiftHeaderLastFragData = curHeaderDataStreamFrag.data >> headerLastFragInvalidBitNumReg;
            let rightShiftHeaderLastFragByteEn = curHeaderDataStreamFrag.byteEn >> headerLastFragInvalidByteNumReg;
            let headerLastFragDataStream = DataStream {
                data: rightShiftHeaderLastFragData,
                byteEn: rightShiftHeaderLastFragByteEn,
                isFirst: curHeaderDataStreamFrag.isFirst,
                isLast: !headerHasPayloadReg
            };
            preDataStreamReg <= headerLastFragDataStream;
            // $display(
            //     "time=%0d", $time,
            //     ": headerHasPayloadReg=%b, headerLastFragValidByteNum=%0d, headerLastFragValidBitNum=%0d, headerLastFragInvalidByteNum=%0d, headerLastFragInvalidBitNum=%0d, headerLastFragDataStream=",
            //     headerHasPayloadReg, headerLastFragValidByteNumReg, headerLastFragValidBitNumReg,
            //     headerLastFragInvalidByteNumReg, headerLastFragInvalidBitNumReg, fshow(headerLastFragDataStream)
            // );

            stageReg <= headerHasPayloadReg ? DataOut : HeaderMetaDataPop;
            if (!headerHasPayloadReg) begin
                // Output headerLastFragDataStream if header has no payload
                dataStreamOutQ.enq(curHeaderDataStreamFrag);
            end
        end
        else begin
            isFirstReg <= False;
            headerFragCntReg <= headerFragCntReg - 1;
            dataStreamOutQ.enq(curHeaderDataStreamFrag);
        end
    endrule

    rule outputData if (stageReg == DataOut);
        let curDataStreamFrag = dataPipeIn.first;
        dataPipeIn.deq;

        preDataStreamReg <= curDataStreamFrag;
        isFirstReg <= False;

        // Check the last data fragment has less than headerLastFragInvalidByteNumReg valid bytes,
        // If no, then extra last fragment, otherwise none.
        ByteEn lastFragByteEn = truncate(curDataStreamFrag.byteEn << headerLastFragInvalidByteNumReg);
        Bool noExtraLastFrag = isZero(lastFragByteEn);

        let tmpData = { preDataStreamReg.data, curDataStreamFrag.data } >> headerLastFragValidBitNumReg;
        let tmpByteEn = { preDataStreamReg.byteEn, curDataStreamFrag.byteEn } >> headerLastFragValidByteNumReg;

        let outDataStream = DataStream {
            data: truncate(tmpData),
            byteEn: truncate(tmpByteEn),
            isFirst: isFirstReg,
            isLast: curDataStreamFrag.isLast && noExtraLastFrag
        };
        // $display(
        //     "time=%0d", $time,
        //     ", Prepend: headerLastFragInvalidByteNumReg=%0d, noExtraLastFrag=%b",
        //     headerLastFragInvalidByteNumReg, noExtraLastFrag,
        //     ", preDataStreamReg=", fshow(preDataStreamReg),
        //     ", curDataStreamFrag=", fshow(curDataStreamFrag),
        //     ", outDataStream=", fshow(outDataStream)
        // );
        dataStreamOutQ.enq(outDataStream);

        if (curDataStreamFrag.isLast) begin
            if (noExtraLastFrag) begin
                stageReg <= HeaderMetaDataPop;
            end
            else begin
                stageReg <= ExtraLastFrag;
            end
        end
    endrule

    rule extraLastFrag if (stageReg == ExtraLastFrag);
        DATA leftShiftData = truncate(preDataStreamReg.data << headerLastFragInvalidBitNumReg);
        ByteEn leftShiftByteEn = truncate(preDataStreamReg.byteEn << headerLastFragInvalidByteNumReg);
        let extraLastDataStream = DataStream {
            data: leftShiftData,
            byteEn: leftShiftByteEn,
            isFirst: False,
            isLast: True
        };

        dataStreamOutQ.enq(extraLastDataStream);
        stageReg <= HeaderMetaDataPop;
    endrule

    return convertFifo2PipeOut(dataStreamOutQ);
endmodule

interface HeaderAndPayloadSeperateDataStreamPipeOut;
    interface DataStreamPipeOut header;
    interface DataStreamPipeOut payload;
endinterface

typedef enum {
    HeaderMetaDataPop,
    HeaderOut,
    DataOut,
    ExtraLastFrag
} ExtractHeader4PipeOutStage deriving(Bits, Eq, FShow);

// Neither dataPipeIn nor headerMetaDataPipeIn can be empty, headerLen cannot be zero
// dataPipeIn could have data less than requested length from headerMetaDataPipeIn.
module mkExtractHeaderFromDataStreamPipeOut#(
    DataStreamPipeOut dataPipeIn, PipeOut#(HeaderMetaData) headerMetaDataPipeIn
)(HeaderAndPayloadSeperateDataStreamPipeOut);
    FIFOF#(DataStream) headerDataStreamOutQ <- mkFIFOF;
    FIFOF#(DataStream) payloadDataStreamOutQ <- mkFIFOF;

    Reg#(DataStream) preDataStreamReg <- mkRegU;
    Reg#(HeaderMetaData) headerMetaDataReg <- mkRegU;
    Reg#(ByteEn) headerLastFragByteEnReg <- mkRegU;
    Reg#(BusBitNum) headerLastFragInvalidBitNumReg <- mkRegU;
    Reg#(ByteEnBitNum) headerLastFragInvalidByteNumReg <- mkRegU;
    Reg#(BusBitNum) headerLastFragValidBitNumReg <- mkRegU;
    Reg#(ByteEnBitNum) headerLastFragValidByteNumReg <- mkRegU;
    Reg#(Bool) isFirstDataFragReg <- mkRegU;

    Reg#(ExtractHeader4PipeOutStage) stageReg <- mkReg(HeaderMetaDataPop);

    rule popHeaderMetaData if (stageReg == HeaderMetaDataPop);
        let headerMetaData = headerMetaDataPipeIn.first;
        headerMetaDataPipeIn.deq;
        // $display("time=%0d: headerMetaData=", $time, fshow(headerMetaData));
        dynAssert(
            !isZero(headerMetaData.headerLen),
            "headerMetaData.headerLen non-zero assertion @ mkExtractHeaderFromDataStreamPipeOut",
            $format(
                "headerMetaData.headerLen=%h should not be zero, headerMetaData=",
                headerMetaData.headerLen, fshow(headerMetaData)
            )
        );

        let headerFragNum = headerMetaData.headerFragNum;
        let headerLastFragValidByteNum = headerMetaData.lastFragValidByteNum;
        let { headerLastFragValidBitNum, headerLastFragInvalidByteNum, headerLastFragInvalidBitNum } =
            calcFragBitNumAndByteNum(headerLastFragValidByteNum);

        headerLastFragValidByteNumReg <= headerLastFragValidByteNum;
        headerLastFragValidBitNumReg <= headerLastFragValidBitNum;
        headerLastFragInvalidByteNumReg <= headerLastFragInvalidByteNum;
        headerLastFragInvalidBitNumReg <= headerLastFragInvalidBitNum;

        ByteEn headerLastFragByteEn = genByteEn(headerLastFragValidByteNum);
        headerLastFragByteEnReg <= headerLastFragByteEn;
        headerMetaData.headerFragNum = headerFragNum - 1;
        headerMetaDataReg <= headerMetaData;
        // $display(
        //     "time=%0d: headerMetaData=", $time, fshow(headerMetaData),
        //     ", headerLastFragByteEn=%h, headerLastFragValidByteNum=%0d, headerLastFragValidBitNum=%0d, headerLastFragInvalidByteNum=%0d, headerLastFragInvalidBitNum=%0d",
        //     reverseBits(headerLastFragByteEn), headerLastFragValidByteNum, headerLastFragValidBitNum, headerLastFragInvalidByteNum, headerLastFragInvalidBitNum
        // );
        stageReg <= HeaderOut;
    endrule

    rule outputHeader if (stageReg == HeaderOut);
        let curDataStreamFrag = dataPipeIn.first;
        dataPipeIn.deq;

        let headerMetaData = headerMetaDataReg;
        let headerFragNum = headerMetaData.headerFragNum;

        // Check dataPipeIn has more data after header
        Bool isHeaderLastFrag = isZero(headerFragNum);
        ByteEn tmpByteEn = truncate(curDataStreamFrag.byteEn << headerLastFragValidByteNumReg);
        Bool hasDataFragAfterHeader = !isZero(tmpByteEn) && isHeaderLastFrag;
        let outDataStream = curDataStreamFrag;

        if (curDataStreamFrag.isLast) begin // Might not have enough data for header
            outDataStream.byteEn = hasDataFragAfterHeader ?
                headerLastFragByteEnReg : curDataStreamFrag.byteEn;
            outDataStream.isLast = True;

            preDataStreamReg <= curDataStreamFrag;
            isFirstDataFragReg <= hasDataFragAfterHeader;
            stageReg <= (
                hasDataFragAfterHeader ? (
                    isHeaderLastFrag ?
                        ExtraLastFrag : // One one fragment of payload data
                        DataOut         // More than one fragments of payload data
                ) : HeaderMetaDataPop   // No payload data
            );

            if (!hasDataFragAfterHeader) begin
                // Put an empty DataStream into payloadDataStreamOutQ,
                // even if header has no payload or no enough data for header,
                // this is to align header and data, for easy handling.
                let emptyDataStream = DataStream {
                    data: 0,
                    byteEn: 0,
                    isFirst: True,
                    isLast: True
                };
                payloadDataStreamOutQ.enq(emptyDataStream);
            end
        end
        else if (isHeaderLastFrag) begin // Finish extracting header
            outDataStream.byteEn = headerLastFragByteEnReg;
            outDataStream.isLast = True;

            preDataStreamReg <= curDataStreamFrag;
            isFirstDataFragReg <= True;
            // No matter header has payload or not, since there exists data fragment
            // after header, so it must switch to DataOut stage.
            stageReg <= DataOut;
        end
        else begin
            headerMetaData.headerFragNum = headerFragNum - 1;
            headerMetaDataReg <= headerMetaData;
        end

        // $display(
        //     "time=%0d: ", $time,
        //     "header outDataStream=", fshow(outDataStream),
        //     ", curDataStreamFrag=", fshow(curDataStreamFrag),
        //     ", headerMetaData=", fshow(headerMetaData),
        //     ", stageReg=", fshow(stageReg)
        // );
        headerDataStreamOutQ.enq(outDataStream);

        // For debug only
        // if (curDataStreamFrag.isFirst) begin
        //     let bth = extractBTH2(curDataStreamFrag.data);
        //     $display("time=%0d: BTH=", $time, fshow(bth));
        // end
    endrule

    rule outputData if (stageReg == DataOut);
        let curDataStreamFrag = dataPipeIn.first;
        dataPipeIn.deq;

        preDataStreamReg <= curDataStreamFrag;
        isFirstDataFragReg <= False;

        ByteEn lastFragByteEn = truncate(curDataStreamFrag.byteEn << headerLastFragValidByteNumReg);
        Bool noExtraLastFrag = isZero(lastFragByteEn);
        let tmpData = { preDataStreamReg.data, curDataStreamFrag.data } >> headerLastFragInvalidBitNumReg;
        let tmpByteEn = { preDataStreamReg.byteEn, curDataStreamFrag.byteEn } >> headerLastFragInvalidByteNumReg;
        let outDataStream = DataStream {
            data: truncate(tmpData),
            byteEn: truncate(tmpByteEn),
            isFirst: isFirstDataFragReg,
            isLast: curDataStreamFrag.isLast && noExtraLastFrag
        };
        // $display(
        //     "time=%0d:", $time,
        //     " Extract: headerLastFragValidByteNumReg=%0d, headerLastFragInvalidByteNumReg=%0d, noExtraLastFrag=%b",
        //     headerLastFragValidByteNumReg, headerLastFragInvalidByteNumReg, noExtraLastFrag,
        //     ", preDataStreamReg=", fshow(preDataStreamReg),
        //     ", curDataStreamFrag=", fshow(curDataStreamFrag),
        //     ", outDataStream=", fshow(outDataStream)
        // );
        payloadDataStreamOutQ.enq(outDataStream);

        if (curDataStreamFrag.isLast) begin
            if (noExtraLastFrag) begin
                stageReg <= HeaderMetaDataPop;
            end
            else begin
                stageReg <= ExtraLastFrag;
            end
        end
    endrule

    rule extraLastFrag if (stageReg == ExtraLastFrag);
        DATA leftShiftData = truncate(preDataStreamReg.data << headerLastFragValidBitNumReg);
        ByteEn leftShiftByteEn = truncate(preDataStreamReg.byteEn << headerLastFragValidByteNumReg);
        let extraLastDataStream = DataStream {
            data: leftShiftData,
            byteEn: leftShiftByteEn,
            isFirst: isFirstDataFragReg,
            isLast: True
        };
        isFirstDataFragReg <= False;

        // $display("time=%0d: extraLastDataStream=", $time, fshow(extraLastDataStream));
        payloadDataStreamOutQ.enq(extraLastDataStream);
        stageReg <= HeaderMetaDataPop;
    endrule

    interface header = convertFifo2PipeOut(headerDataStreamOutQ);
    interface payload = convertFifo2PipeOut(payloadDataStreamOutQ);
endmodule
