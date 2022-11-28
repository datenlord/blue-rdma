import FIFOF :: *;
import PAClib :: *;

import Assertions :: *;
import DataTypes :: *;
import Headers :: *;
import Settings :: *;
import Utils :: *;

function Tuple2#(HeaderFragNum, ByteEnBitNum) calcHeaderFragNumAndLastFragByeEnBitNum(
    HeaderByteNum headerLen
);
    BusByteWidthMask busByteWidthMask = maxBound;
    HeaderFragNum headerFragNum = truncate(headerLen >> valueOf(DATA_BUS_BYTE_NUM_WIDTH));
    ByteEnBitNum headerLastFragByteEnBitNum = zeroExtend(truncate(headerLen) & busByteWidthMask);
    if (!isZero(headerLen)) begin
        if (isZero(headerLastFragByteEnBitNum)) begin
            headerLastFragByteEnBitNum = fromInteger(valueOf(DATA_BUS_BYTE_WIDTH));
        end
        else begin
            headerFragNum = headerFragNum + 1;
        end
    end
    return tuple2(headerFragNum, headerLastFragByteEnBitNum);
endfunction

function HeaderAndByteEn leftAlignHeaderData(
    HeaderAndByteEn rightAlignedHeaderAndByteEn
);
    Integer leftShiftByteAmt = 0;
    for (Integer idx = 1; idx < valueOf(MAX_HEADER_FRAG_NUM); idx = idx + 1) begin
        if (rightAlignedHeaderAndByteEn.headerFragNum == fromInteger(idx)) begin
            leftShiftByteAmt = (valueOf(MAX_HEADER_FRAG_NUM) - idx) * valueOf(DATA_BUS_BYTE_WIDTH);
        end
    end
    Integer leftShiftBitAmt = leftShiftByteAmt * 8;

    ByteEnBitNum lastFragInvalidByteNum =
        fromInteger(valueOf(DATA_BUS_BYTE_NUM_WIDTH)) - rightAlignedHeaderAndByteEn.lastFragValidByteNum;
    BusBitNum lastFragInvalidBitNum = zeroExtend(lastFragInvalidByteNum) << 3;
    
    return HeaderAndByteEn {
        headerData: truncate(rightAlignedHeaderAndByteEn.headerData << leftShiftBitAmt),
        headerByteEn: truncate(rightAlignedHeaderAndByteEn.headerByteEn << leftShiftByteAmt),
        headerFragNum: rightAlignedHeaderAndByteEn.headerFragNum,
        lastFragValidByteNum: rightAlignedHeaderAndByteEn.lastFragValidByteNum
    };
endfunction

module mkHeader2DataStream#(
    PipeOut#(HeaderAndByteEn) headerPipeIn
)(PipeOut#(DataStream));
    FIFOF#(DataStream) dataOutQ <- mkFIFOF;
    Reg#(HeaderAndByteEn) headerAndByteEnReg <- mkRegU;
    Reg#(Bool) headerValidReg <- mkReg(False);

    rule outputHeader;
        let curHeader = headerValidReg ? headerAndByteEnReg : headerPipeIn.first;
        let remainingHeaderFragNum = curHeader.headerFragNum - 1;

        HeaderData leftShiftHeaderData = truncate(curHeader.headerData << valueOf(DATA_BUS_WIDTH));
        HeaderByteEn leftShiftHeaderByteEn = truncate(curHeader.headerByteEn << valueOf(DATA_BUS_BYTE_WIDTH));

        Bool isFirst = !headerValidReg;
        Bool isLast = False;
        if (isZero(remainingHeaderFragNum)) begin
            headerPipeIn.deq;
            headerValidReg <= False;
            isLast = True;
        end
        else begin
            headerValidReg <= True;

            headerAndByteEnReg <= HeaderAndByteEn {
                headerData: leftShiftHeaderData,
                headerByteEn: leftShiftHeaderByteEn,
                headerFragNum: remainingHeaderFragNum,
                lastFragValidByteNum: curHeader.lastFragValidByteNum
            };
        end

        let dataStream = DataStream {
            data: truncateLSB(curHeader.headerData),
            byteEn: truncateLSB(curHeader.headerByteEn),
            isFirst: isFirst,
            isLast: isLast
        };
        // $display(
        //     "dataStream.data=%h, dataStream.byteEn=%h, leftShiftHeaderData=%h, leftShiftHeaderByteEn=%h",
        //     dataStream.data, dataStream.byteEn, leftShiftHeaderData, leftShiftHeaderByteEn
        // );
        dataOutQ.enq(dataStream);
    endrule

    return convertFifo2PipeOut(dataOutQ);
    // method DataStream first() = dataOutQ.first;
    // method Action deq() = dataOutQ.deq;
    // method Bool notEmpty() = dataOutQ.notEmpty;
endmodule

// dataPipeIn must have multi-fragment data no more than HeaderByteNum
module mkDataStream2Header#(
    PipeOut#(DataStream) dataPipeIn, PipeOut#(HeaderByteNum) headerLenPipeIn
)(PipeOut#(HeaderAndByteEn));
    FIFOF#(HeaderAndByteEn) headerOutQ <- mkFIFOF;
    Reg#(HeaderAndByteEn) headerAndByteEnReg <- mkRegU;
    Reg#(HeaderByteNum) headerLenReg <- mkRegU;
    Reg#(HeaderFragNum) headerFragCntReg <- mkRegU;
    Reg#(ByteEnBitNum) headerLastFragValidByteNumReg <- mkRegU;
    Reg#(Bool) busyReg <- mkReg(False);

    rule headerLenPop if (!busyReg);
        busyReg <= True;
        let headerLen = headerLenPipeIn.first;
        headerLenPipeIn.deq;
        headerLenReg <= headerLen;

        dynAssert(
            !isZero(headerLen),
            "headerLen non-zero assertion @ mkDataStream2Header",
            $format("headerLen=%h should not be zero", headerLen)
        );

        let { headerFragNum, headerLastFragValidByteNum } =
            calcHeaderFragNumAndLastFragByeEnBitNum(headerLen);

        headerFragCntReg <= headerFragNum - 1;
        headerLastFragValidByteNumReg <= headerLastFragValidByteNum;
    endrule

    rule cumulate if (busyReg);
        let curDataStreamFrag = dataPipeIn.first;
        dataPipeIn.deq;

        let headerAndByteEn = headerAndByteEnReg;
        let headerFragNum = headerAndByteEnReg.headerFragNum;
        if (curDataStreamFrag.isFirst) begin
            headerAndByteEn.headerData = zeroExtend(curDataStreamFrag.data);
            headerAndByteEn.headerByteEn = zeroExtend(curDataStreamFrag.byteEn);
            headerAndByteEn.headerFragNum = 1;
        end
        else begin
            headerAndByteEn.headerData = truncate({ headerAndByteEn.headerData, curDataStreamFrag.data });
            headerAndByteEn.headerByteEn = truncate({ headerAndByteEn.headerByteEn, curDataStreamFrag.byteEn });
            headerAndByteEn.headerFragNum = headerAndByteEnReg.headerFragNum + 1;
        end

        if (curDataStreamFrag.isLast) begin
            ByteEn headerLastFragByteEn = (1 << headerLastFragValidByteNumReg) - 1;
            headerLastFragByteEn = reverseBits(headerLastFragByteEn);
            headerAndByteEn.lastFragValidByteNum = headerLastFragValidByteNumReg;
            headerOutQ.enq(headerAndByteEn);

            dynAssert(
                headerLastFragByteEn == curDataStreamFrag.byteEn,
                "headerLastFragByteEn assertion @ mkDataStream2Header",
                $format(
                    "headerLastFragByteEn=%h should == curDataStreamFrag.byteEn=%h",
                    headerLastFragByteEn, curDataStreamFrag.byteEn
                )
            );
            dynAssert(
                isZero(headerFragCntReg),
                "headerFragCntReg assertion @ mkDataStream2Header",
                $format(
                    "headerFragCntReg=%h should be zero when curDataStreamFrag.isLast=%b",
                    headerFragCntReg, curDataStreamFrag.isLast
                )
            );
        end
        else begin
            headerFragCntReg <= headerFragCntReg - 1;
            dynAssert(
                isAllOnes(curDataStreamFrag.byteEn),
                "curDataStreamFrag.byteEn assertion @ mkDataStream2Header",
                $format("curDataStreamFrag.byteEn=%h should be all ones", curDataStreamFrag.byteEn)
            );
        end

        // $display(
        //     "headerAndByteEn.headerData=%h, headerAndByteEn.headerByteEn=%h",
        //     headerAndByteEn.headerData, headerAndByteEn.headerByteEn
        // );  
        headerAndByteEnReg <= headerAndByteEn;
    endrule

    return convertFifo2PipeOut(headerOutQ);
    // method HeaderAndByteEn first() = headerOutQ.first;
    // method Action deq() = headerOutQ.deq;
    // method Bool notEmpty() = headerOutQ.notEmpty;
endmodule

typedef enum { HeaderLenPop, HeaderOut, DataOut, ExtraLastFrag } PrependHeader2PipeOutStage deriving(Bits, Eq);
module mkPrependHeader2PipeOut#(
    // Neither headerPipeIn nor dataPipeIn can be empty, headerLen cannot be zero
    PipeOut#(DataStream) headerPipeIn, PipeOut#(HeaderByteNum) headerLenPipeIn, PipeOut#(DataStream) dataPipeIn
)(PipeOut#(DataStream));
    FIFOF#(DataStream) outQ <- mkFIFOF;

    // preDataStreamReg is right aligned
    Reg#(DataStream) preDataStreamReg <- mkRegU;
    Reg#(HeaderFragNum) headerFragCntReg <- mkRegU;
    Reg#(BusBitNum) headerLastFragInvalidBitNumReg <- mkRegU;
    Reg#(ByteEnBitNum) headerLastFragInvalidByteNumReg <- mkRegU;
    Reg#(BusBitNum) headerLastFragValidBitNumReg <- mkRegU;
    Reg#(ByteEnBitNum) headerLastFragValidByteNumReg <- mkRegU;
    Reg#(Bool) isFirstReg <- mkRegU;

    Reg#(PrependHeader2PipeOutStage) stageReg <- mkReg(HeaderLenPop);

    rule popHeaderLen if (stageReg == HeaderLenPop);
        let headerLen = headerLenPipeIn.first;
        headerLenPipeIn.deq;
        // $display("time=%0d: headerLen=%0d", $time, headerLen);
        dynAssert(
            !isZero(headerLen),
            "headerLen non-zero assertion @ mkPrependHeader2PipeOut",
            $format("headerLen=%h should not be zero", headerLen)
        );

        let { headerFragNum, headerLastFragValidByteNum } =
            calcHeaderFragNumAndLastFragByeEnBitNum(headerLen);
        let { headerLastFragValidBitNum, headerLastFragInvalidByteNum, headerLastFragInvalidBitNum } =
            calcFragBitByteNum(headerLastFragValidByteNum);

        headerLastFragValidByteNumReg <= headerLastFragValidByteNum;
        headerLastFragValidBitNumReg <= headerLastFragValidBitNum;
        headerLastFragInvalidByteNumReg <= headerLastFragInvalidByteNum;
        headerLastFragInvalidBitNumReg <= headerLastFragInvalidBitNum;

        headerFragCntReg <= headerFragNum - 1;
        isFirstReg <= True;
        stageReg <= HeaderOut;
    endrule

    rule outputHeader if (stageReg == HeaderOut);
        let curDataStreamFrag = headerPipeIn.first;
        headerPipeIn.deq;
        // $display("time=%0d", $time, ": headerDataStream=", fshow(curDataStreamFrag));

        // One cycle delay when output the last fragment of header
        if (curDataStreamFrag.isLast) begin
            dynAssert(
                isZero(headerFragCntReg),
                "headerFragCntReg zero assertion @ mkPrependHeader2PipeOut",
                $format(
                    "headerFragCntReg=%h should be zero when curDataStreamFrag.isLast=%b",
                    headerFragCntReg, curDataStreamFrag.isLast
                )
            );

            let rightShiftHeaderLastFragData = curDataStreamFrag.data >> headerLastFragInvalidBitNumReg;
            let rightShiftHeaderLastFragByteEn = curDataStreamFrag.byteEn >> headerLastFragInvalidByteNumReg;
            let headerLastFragDataStream = DataStream {
                data: rightShiftHeaderLastFragData,
                byteEn: rightShiftHeaderLastFragByteEn,
                isFirst: curDataStreamFrag.isFirst,
                isLast: False
            };
            preDataStreamReg <= headerLastFragDataStream;
            // $display(
            //     "time=%0d", $time,
            //     ":, headerLastFragValidByteNum=%0d, headerLastFragValidBitNum=%0d, headerLastFragInvalidBitNum=%0d, headerLastFragInvalidByteNum=%0d, headerLastFragDataStream=",
            //     headerLastFragValidByteNumReg, headerLastFragValidBitNumReg, headerLastFragInvalidBitNumReg, headerLastFragInvalidByteNumReg, fshow(headerLastFragDataStream)
            // );

            stageReg <= DataOut;
        end
        else begin
            isFirstReg <= False;
            headerFragCntReg <= headerFragCntReg - 1;
            outQ.enq(curDataStreamFrag);
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
        outQ.enq(outDataStream);

        if (curDataStreamFrag.isLast) begin
            if (noExtraLastFrag) begin
                stageReg <= HeaderLenPop;
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

        outQ.enq(extraLastDataStream);
        stageReg <= HeaderLenPop;
    endrule

    method DataStream first() = outQ.first;
    method Action deq() = outQ.deq;
    method Bool notEmpty() = outQ.notEmpty;
endmodule

interface SeperatePipeOut;
    interface PipeOut#(DataStream) header;
    interface PipeOut#(DataStream) data;
endinterface

typedef enum { HeaderLenPop, HeaderOut, DataOut, ExtraLastFrag } ExtractHeader4PipeOutStage deriving(Bits, Eq);
module mkExtractHeader4PipeOut#(
    // Neither dataPipeIn nor headerLenPipeIn can be empty, headerLen cannot be zero
    // dataPipeIn could have data less than requested length from headerLenPipeIn
    PipeOut#(DataStream) dataPipeIn, PipeOut#(HeaderByteNum) headerLenPipeIn
)(SeperatePipeOut);
    FIFOF#(DataStream) headerOutQ <- mkFIFOF;
    FIFOF#(DataStream) dataOutQ <- mkFIFOF;

    Reg#(DataStream) preDataStreamReg <- mkRegU;
    Reg#(HeaderFragNum) headerFragCntReg <- mkRegU;
    Reg#(ByteEn) headerLastFragByteEnReg <- mkRegU;
    Reg#(BusBitNum) headerLastFragInvalidBitNumReg <- mkRegU;
    Reg#(ByteEnBitNum) headerLastFragInvalidByteNumReg <- mkRegU;
    Reg#(BusBitNum) headerLastFragValidBitNumReg <- mkRegU;
    Reg#(ByteEnBitNum) headerLastFragValidByteNumReg <- mkRegU;
    Reg#(Bool) isFirstDataFragReg <- mkRegU;

    Reg#(ExtractHeader4PipeOutStage) stageReg <- mkReg(HeaderLenPop);

    rule popHeaderLen if (stageReg == HeaderLenPop);
        let headerLen = headerLenPipeIn.first;
        headerLenPipeIn.deq;
        // $display("time=%0d: headerLen=%0d", $time, headerLen);
        dynAssert(
            !isZero(headerLen),
            "headerLen non-zero assertion @ mkExtractHeader4PipeOut",
            $format("headerLen=%h should not be zero", headerLen)
        );

        let { headerFragNum, headerLastFragValidByteNum } =
            calcHeaderFragNumAndLastFragByeEnBitNum(headerLen);
        let { headerLastFragValidBitNum, headerLastFragInvalidByteNum, headerLastFragInvalidBitNum } =
            calcFragBitByteNum(headerLastFragValidByteNum);

        headerLastFragValidByteNumReg <= headerLastFragValidByteNum;
        headerLastFragValidBitNumReg <= headerLastFragValidBitNum;
        headerLastFragInvalidByteNumReg <= headerLastFragInvalidByteNum;
        headerLastFragInvalidBitNumReg <= headerLastFragInvalidBitNum;

        headerFragCntReg <= headerFragNum - 1;

        ByteEn headerLastFragByteEn = (1 << headerLastFragValidByteNum) - 1;
        headerLastFragByteEnReg <= reverseBits(headerLastFragByteEn);
        // $display(
        //     "time=%0d: headerLen=%0d, headerFragNum=%0d, headerLastFragByteEn=%h, headerLastFragValidByteNum=%0d, headerLastFragValidBitNum=%0d, headerLastFragInvalidByteNum=%0d, headerLastFragInvalidBitNum=%0d",
        //     $time, headerLen, headerFragNum, reverseBits(headerLastFragByteEn), headerLastFragValidByteNum, headerLastFragValidBitNum, headerLastFragInvalidByteNum, headerLastFragInvalidBitNum
        // );
        stageReg <= HeaderOut;
    endrule

    rule outputHeader if (stageReg == HeaderOut);
        let curDataStreamFrag = dataPipeIn.first;
        dataPipeIn.deq;

        // Check dataPipeIn has more data after header
        ByteEn tmpByteEn = truncate(curDataStreamFrag.byteEn << headerLastFragValidByteNumReg);
        Bool isHeaderLastFrag = isZero(headerFragCntReg);
        Bool hasDataFragAfterHeader = !isZero(tmpByteEn) && isHeaderLastFrag;
        let outDataStream = curDataStreamFrag;

        if (curDataStreamFrag.isLast) begin // Might not enough data for header
            outDataStream.byteEn = hasDataFragAfterHeader ? headerLastFragByteEnReg : curDataStreamFrag.byteEn;
            outDataStream.isLast = True;

            preDataStreamReg <= curDataStreamFrag;
            isFirstDataFragReg <= hasDataFragAfterHeader;
            stageReg <= hasDataFragAfterHeader ? DataOut : HeaderLenPop;
        end
        else if (isHeaderLastFrag) begin // Finish extracting header
            outDataStream.byteEn = headerLastFragByteEnReg;
            outDataStream.isLast = True;

            preDataStreamReg <= curDataStreamFrag;
            isFirstDataFragReg <= True;
            stageReg <= DataOut;
        end
        else begin
            headerFragCntReg <= headerFragCntReg - 1;
        end

        // $display("time=%0d: ", $time, "header outDataStream=", fshow(outDataStream), ", curDataStreamFrag=", fshow(curDataStreamFrag));
        headerOutQ.enq(outDataStream);
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
        //     "time=%0d", $time,
        //     ", Extract: headerLastFragValidByteNumReg=%0d, headerLastFragInvalidByteNumReg=%0d, noExtraLastFrag=%b",
        //     headerLastFragValidByteNumReg, headerLastFragInvalidByteNumReg, noExtraLastFrag,
        //     ", preDataStreamReg=", fshow(preDataStreamReg),
        //     ", curDataStreamFrag=", fshow(curDataStreamFrag),
        //     ", outDataStream=", fshow(outDataStream)
        // );
        dataOutQ.enq(outDataStream);

        if (curDataStreamFrag.isLast) begin
            if (noExtraLastFrag) begin
                stageReg <= HeaderLenPop;
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
            isFirst: False,
            isLast: True
        };

        dataOutQ.enq(extraLastDataStream);
        stageReg <= HeaderLenPop;
    endrule

    interface header = interface PipeOut#(DataStream);
        method DataStream first() = headerOutQ.first;
        method Action deq() = headerOutQ.deq;
        method Bool notEmpty() = headerOutQ.notEmpty;
    endinterface;
    interface data = interface PipeOut#(DataStream);
        method DataStream first() = dataOutQ.first;
        method Action deq() = dataOutQ.deq;
        method Bool notEmpty() = dataOutQ.notEmpty;
    endinterface;
endmodule
