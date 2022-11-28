import ClientServer :: *;
import FIFOF :: *;
import GetPut :: *;
import PAClib :: *;
import Randomizable :: *;
import Vector :: *;

import Assertions :: *;
import DataTypes :: *;
import Headers :: *;
import Settings :: *;
import TestSettings :: *;
import Utils :: *;

// interface Server#(type req_type, type resp_type);
//     interface Put#(req_type) request;
//     interface Get#(resp_type) response;
// endinterface: Server

module mkSimDmaReadSrv(Server#(DmaReadReq, DmaReadResp));
    FIFOF#(DmaReadReq) dmaReadReqQ <- mkFIFOF;
    FIFOF#(DmaReadResp) dmaReadRespQ <- mkFIFOF;
    Reg#(FragNum) totalFragCntReg <- mkRegU;
    Randomize#(DataStream) randomDataStream <- mkGenericRandomizer;
    Reg#(Bool) initializedReg <- mkReg(False);
    Reg#(Bool) busyReg <- mkReg(False);
    Reg#(Bool) isFirstReg <- mkRegU;
    Reg#(ByteEn) lastFragByteEnReg <- mkRegU;
    Reg#(BusBitNum) lastFragInvalidBitNumReg <- mkRegU;
    Reg#(DmaReadReq) curReqReg <- mkRegU;

    Bool isFragCntZero = isZero(totalFragCntReg);

    rule init if (!initializedReg);
        randomDataStream.cntrl.init;
        initializedReg <= True;
    endrule

    rule acceptReq if (!busyReg && initializedReg);
        let curReq = dmaReadReqQ.first;
        dmaReadReqQ.deq;

        let isZeroLen = isZero(curReq.len);
        dynAssert(
            !isZeroLen,
            "dmaReadReq.len non-zero assrtion",
            $format("curReq.len=%h should not be zero", curReq.len)
        );

        let { totalFragCnt, lastFragByteEn, lastFragValidByteNum } = calcFragNumByLength(curReq.len);
        let { lastFragValidBitNum, lastFragInvalidByteNum, lastFragInvalidBitNum } =
            calcFragBitByteNum(lastFragValidByteNum);

        totalFragCntReg <= isZeroLen ? 0 : totalFragCnt - 1;
        lastFragByteEnReg <= lastFragByteEn;
        lastFragInvalidBitNumReg <= lastFragInvalidBitNum;

        dynAssert(
            !isZero(lastFragByteEn),
            "lastFragByteEn non-zero assertion",
            $format("lastFragByteEn=%h should not have zero ByteEn, curReq.len=%h", lastFragByteEn, curReq.len)
        );

        curReqReg <= curReq;
        busyReg <= True;
        isFirstReg <= True;
    endrule

    rule returnResp if (busyReg && initializedReg);
        totalFragCntReg <= totalFragCntReg - 1;
        let data <- randomDataStream.next;
        data.isFirst = isFirstReg;
        isFirstReg <= False;
        data.isLast = isFragCntZero;
        data.byteEn = maxBound;

        if (isFragCntZero) begin
            busyReg <= False;
            data.byteEn = lastFragByteEnReg;
            DATA tmpData = data.data >> lastFragInvalidBitNumReg;
            data.data = truncate(tmpData << lastFragInvalidBitNumReg);
        end

        let resp = DmaReadResp {
            initiator: curReqReg.initiator,
            sqpn: curReqReg.sqpn,
            token: curReqReg.token,
            data: data
        };
        dmaReadRespQ.enq(resp);

        dynAssert(
            !isZero(data.byteEn),
            "dmaReadResp.data.byteEn non-zero assertion",
            $format("dmaReadResp.data should not have zero ByteEn", fshow(data))
        );

        // $display(
        //     "Before segment: time=%0d, totalFragNum=%h, isFirst=%b, isLast=%b, byteEn=%h",
        //     $time, totalFragCntReg, data.isFirst, data.isLast, data.byteEn
        // );
    endrule

    interface request = toPut(dmaReadReqQ);
    interface response = toGet(dmaReadRespQ);
endmodule

module mkFixedLenSimDataStreamPipeOut#(
    PipeOut#(Length) dmaLenPipeOut
)(Vector#(vsize, PipeOut#(DataStream)));
    let simDmaSrv <- mkSimDmaReadSrv;
    let dataStreamPipeOut <- mkDataStreamPipeOutFromDmaReadResp(simDmaSrv.response);
    Vector#(vsize, PipeOut#(DataStream)) dataStreamPipeOutVec <- mkForkVector(dataStreamPipeOut);
    let countDown <- mkCountDown;

    rule sendDmaReq;
        let dmaLength = dmaLenPipeOut.first;
        dmaLenPipeOut.deq;

        let dmaReq = DmaReadReq {
            initiator: ?,
            sqpn: ?,
            startAddr: ?,
            len: dmaLength,
            token: ?
        };
        simDmaSrv.request.put(dmaReq);
        // $display("time=%0d: dmaLength=%0d", $time, dmaLength);
    endrule

    return dataStreamPipeOutVec;
endmodule

// typedef Vector#(vsize, PipeOut#(DataStream)) SimDataStreamPipeOut#(type numeric vsize);
module mkRandomLenSimDataStreamPipeOut#(
    Length minDataStreamLength, Length maxDataStreamLength
)(Vector#(vsize, PipeOut#(DataStream)));
    let dmaLenPipeOut <- mkRandomLenPipeOut(minDataStreamLength, maxDataStreamLength);
    Vector#(vsize, PipeOut#(DataStream)) simDataStreamPipeOut <-
        mkFixedLenSimDataStreamPipeOut(dmaLenPipeOut);

    return simDataStreamPipeOut;
endmodule

(* synthesize *)
module mkTestFixedLenSimDataStreamPipeOut(Empty);
    let minDmaLength = 1;
    let maxDmaLength = 125;

    let dmaLenPipeOut <- mkRandomLenPipeOut(minDmaLength, maxDmaLength);
    let { dmaLenPipeOut4Gen, dmaLenPipeOut4Ref } <- mkForkAndBufferRight(dmaLenPipeOut);
    Vector#(1, PipeOut#(DataStream)) simDataStreamPipeOutVec <-
        mkFixedLenSimDataStreamPipeOut(dmaLenPipeOut4Gen);
    Reg#(Length) refDmaLenReg <- mkRegU;
    Reg#(Length) totalDmaLenReg <- mkRegU;

    rule compare;
        let curDataStreamFrag = simDataStreamPipeOutVec[0].first;
        simDataStreamPipeOutVec[0].deq;

        let curLength = calcByteEnBitNum(curDataStreamFrag.byteEn);

        let totalDmaLen = totalDmaLenReg;
        let refDmaLen = refDmaLenReg;
        if (curDataStreamFrag.isFirst) begin
            refDmaLen = dmaLenPipeOut4Ref.first;
            dmaLenPipeOut4Ref.deq;
            refDmaLenReg <= refDmaLen;
            
            totalDmaLen = zeroExtend(curLength);
            totalDmaLenReg <= zeroExtend(curLength);
        end
        else begin
            totalDmaLen = totalDmaLenReg + zeroExtend(curLength);
            totalDmaLenReg <= totalDmaLen;
        end

        if (curDataStreamFrag.isLast) begin
            dynAssert(
                totalDmaLen == refDmaLen,
                "dataStream length assertion @ mkTestFixedLenSimDataStreamPipeOut",
                $format("totalDmaLen=%0d should == refDmaLen=%0d", totalDmaLen, refDmaLen)
            );
        end
    endrule
endmodule
